//! `Runtime` (src/runtime.rs), desktop-qt's ShellRuntime, over the
//! `ShellLoader` each window's root is: the user's `<config>/shell.qml` in
//! place of the built-in shell, the fallback when it does not load,
//! `<config>/qml` on the import path, and every window's shell made again
//! in its own scope. A save applied while the app runs is Ljós's user QML
//! (`App::user_qml`), which features/desktop/user-shell.feature drives.

use std::num::NonZeroU32;
use std::path::Path;

use hal_c2_shell::Launch;
use hal_c2_shell::platform_window;
use hal_c2_shell::qml::Roots;
use hal_c2_shell::runtime::{self, ShellRuntime};
use ljos::prelude::{ObjectId, Platform, Value};
use ljos::window::raw_window_handle::{
    DisplayHandle, HandleError, HasDisplayHandle, HasWindowHandle, RawDisplayHandle,
    RawWindowHandle, WindowHandle, XcbDisplayHandle, XcbWindowHandle,
};
use tempfile::TempDir;

use crate::Hub;
use crate::common::compile_roots;

/// Each window's root, as qml/Main.qml is, with `Builtin.qml` for the
/// built-in shell.
const MAIN_QML: &str =
    "import Ljos.Blocks\nShellLoader { source: \"shell.qml\"; fallback: \"Builtin.qml\" }\n";

const BUILT_IN: &str = "import QtQuick\nWindow { objectName: \"built-in\" }\n";

/// A shell whose QML is `app/` (its root `app/Main.qml`, the built-in
/// shell `app/Builtin.qml`) and whose config dir is `config/`, both in a
/// new temporary directory, not yet open.
fn hub() -> (Hub, TempDir) {
    let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    for sub in ["app", "config", "state"] {
        std::fs::create_dir(dir.path().join(sub)).unwrap();
    }
    write(&dir.path().join("app/Main.qml"), MAIN_QML);
    write(&dir.path().join("app/Builtin.qml"), BUILT_IN);
    let hub = Hub::with(Launch {
        config_dir: Some(dir.path().join("config")),
        state_dir: Some(dir.path().join("state")),
        ..Launch::default()
    })
    .hosted();
    (hub, dir)
}

fn roots(dir: &TempDir) -> Roots {
    Roots::one(dir.path().join("app")).with_user(dir.path().join("config"))
}

/// Compiles what the files say now, as a `--qml-dir` run does, for the
/// loaders to make their shells from.
fn compile(hub: &Hub, dir: &TempDir) {
    hub.engine
        .set_component_source(compile_roots(&roots(dir)).source);
}

/// Compiles the QML, then makes the first window's loader as the app does
/// for its host.
fn open(hub: &Hub, dir: &TempDir) -> ObjectId {
    compile(hub, dir);
    runtime::open(&hub.engine).unwrap()
}

/// Writes `text` to `path` in one step, as an editor saving does.
fn write(path: &Path, text: &str) {
    let part = path.with_extension("part");
    std::fs::write(&part, text).unwrap();
    std::fs::rename(&part, path).unwrap();
}

fn read(hub: &Hub, name: &str) -> String {
    let obj = hub.engine.singleton::<ShellRuntime>().unwrap();
    hub.engine
        .to_js_string(&hub.engine.read_by_name(obj, name))
        .to_string()
}

fn generation(hub: &Hub) -> i32 {
    read(hub, "generation").parse().unwrap()
}

/// The `objectName` of the shell the first window shows.
fn shown(hub: &Hub) -> String {
    let window = runtime::window(&hub.engine).expect("a shell");
    hub.engine
        .to_js_string(&hub.engine.read_by_name(window, "objectName"))
        .to_string()
}

#[test]
fn without_a_user_shell_the_built_in_one_is_shown() {
    let (hub, dir) = hub();
    let loader = open(&hub, &dir);
    assert_eq!(runtime::loader_of(&hub.engine, "main"), Some(loader));
    assert_eq!(shown(&hub), "built-in");
    assert_eq!(read(&hub, "usingUserShell"), "false");
    // No `shell.qml` is no error.
    assert_eq!(read(&hub, "lastError"), "");
    assert_eq!(generation(&hub), 1);
    let config = dir.path().join("config");
    assert_eq!(read(&hub, "configDir"), config.to_string_lossy());
    assert_eq!(
        read(&hub, "userShellPath"),
        config.join("shell.qml").to_string_lossy()
    );
}

#[test]
fn the_users_shell_qml_replaces_the_built_in_shell() {
    let (hub, dir) = hub();
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { objectName: \"mine\" }\n",
    );
    open(&hub, &dir);
    assert_eq!(shown(&hub), "mine");
    assert_eq!(read(&hub, "usingUserShell"), "true");
    assert_eq!(read(&hub, "lastError"), "");
    assert_eq!(generation(&hub), 1);
}

#[test]
fn a_user_shell_that_does_not_load_falls_back_and_says_why() {
    let (hub, dir) = hub();
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { Nonsense {} }\n",
    );
    open(&hub, &dir);
    assert_eq!(shown(&hub), "built-in");
    assert_eq!(read(&hub, "usingUserShell"), "false");
    assert!(
        read(&hub, "lastError").contains("Nonsense"),
        "{}",
        read(&hub, "lastError")
    );
    assert_eq!(generation(&hub), 1);
}

#[test]
fn a_user_shell_that_is_an_item_is_shown_as_the_loader_shows_one() {
    let (hub, dir) = hub();
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nItem { objectName: \"mine\" }\n",
    );
    open(&hub, &dir);
    assert_eq!(shown(&hub), "mine");
    assert_eq!(read(&hub, "usingUserShell"), "true");
    assert_eq!(read(&hub, "lastError"), "");
}

#[test]
fn a_module_in_the_config_qml_dir_is_importable() {
    let (hub, dir) = hub();
    let module = dir.path().join("config/qml/Mine");
    std::fs::create_dir_all(&module).unwrap();
    write(&module.join("qmldir"), "module Mine\nBadge 1.0 Badge.qml\n");
    write(
        &module.join("Badge.qml"),
        "import QtQuick\nItem { objectName: \"badge\" }\n",
    );
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nimport Mine\nWindow { objectName: \"mine\"; Badge {} }\n",
    );
    open(&hub, &dir);
    assert_eq!(read(&hub, "lastError"), "");
    assert_eq!(shown(&hub), "mine");
    let window = runtime::window(&hub.engine).unwrap();
    let names: Vec<String> = hub
        .engine
        .children(window)
        .into_iter()
        .map(|c| {
            hub.engine
                .to_js_string(&hub.engine.read_by_name(c, "objectName"))
                .to_string()
        })
        .collect();
    assert!(names.contains(&"badge".to_owned()), "{names:?}");
}

#[test]
fn reload_shows_what_the_files_say_now() {
    let (hub, dir) = hub();
    let loader = open(&hub, &dir);
    let first = runtime::window(&hub.engine).unwrap();
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { objectName: \"mine\" }\n",
    );
    compile(&hub, &dir);
    // As the error overlay's "Reload" does.
    let obj = hub.engine.singleton::<ShellRuntime>().unwrap();
    let before = generation(&hub);
    crate::common::call(&hub.engine, obj, "reload", &[]);
    // Made once: the built-in shell is not made on the way.
    assert_eq!(generation(&hub), before + 1);
    assert_eq!(shown(&hub), "mine");
    assert_eq!(read(&hub, "usingUserShell"), "true");
    // The same loader shows it; no host shows the one it let go of, so it
    // goes.
    assert_eq!(runtime::loader_of(&hub.engine, "main"), Some(loader));
    hub.advance(1);
    assert!(!hub.engine.is_alive(first));

    let second = runtime::window(&hub.engine).unwrap();
    let before = generation(&hub);
    std::fs::remove_file(dir.path().join("config/shell.qml")).unwrap();
    compile(&hub, &dir);
    runtime::reload(&hub.engine);
    assert!(generation(&hub) > before);
    assert_eq!(shown(&hub), "built-in");
    assert_eq!(read(&hub, "usingUserShell"), "false");
    assert_eq!(read(&hub, "lastError"), "");
    hub.advance(1);
    assert!(!hub.engine.is_alive(second));

    // And a reload after one: the source spelled as before still loads.
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { objectName: \"again\" }\n",
    );
    compile(&hub, &dir);
    let before = generation(&hub);
    runtime::reload(&hub.engine);
    assert_eq!(generation(&hub), before + 1);
    assert_eq!(shown(&hub), "again");
}

#[test]
fn when_neither_shell_loads_both_are_said_until_one_is_fixed() {
    let (hub, dir) = hub();
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { objectName: \"mine\" }\n",
    );
    open(&hub, &dir);
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { Nonsense {} }\n",
    );
    write(
        &dir.path().join("app/Builtin.qml"),
        "import QtQuick\nWindow { AlsoNonsense {} }\n",
    );
    compile(&hub, &dir);
    runtime::reload(&hub.engine);
    assert_eq!(runtime::window(&hub.engine), None);
    assert_eq!(read(&hub, "usingUserShell"), "false");
    let error = read(&hub, "lastError");
    assert!(
        error.contains("Nonsense") && error.contains("AlsoNonsense"),
        "{error}"
    );

    // Fixed, the next reload shows it, and the user's still says why not.
    write(&dir.path().join("app/Builtin.qml"), BUILT_IN);
    compile(&hub, &dir);
    runtime::reload(&hub.engine);
    assert_eq!(shown(&hub), "built-in");
    let error = read(&hub, "lastError");
    assert!(
        error.contains("Nonsense") && !error.contains("AlsoNonsense"),
        "{error}"
    );
}

#[test]
fn hot_reload_is_on_once_the_app_says_it_follows_the_files() {
    let (hub, dir) = hub();
    open(&hub, &dir);
    assert_eq!(read(&hub, "hotReloadEnabled"), "false");
    runtime::set_hot_reload_enabled(&hub.engine, true);
    assert_eq!(read(&hub, "hotReloadEnabled"), "true");
}

#[test]
fn a_reloaded_shell_is_the_window_that_closes_and_reopens() {
    let (hub, dir) = hub();
    open(&hub, &dir);
    let first = runtime::window(&hub.engine).unwrap();
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { objectName: \"mine\" }\n",
    );
    compile(&hub, &dir);
    runtime::reload(&hub.engine);
    let mine = runtime::window(&hub.engine).unwrap();
    let engine = &hub.engine;

    // The user closes it: `closing`, then hidden.
    engine
        .emit_by_name(mine, "closing", &[Value::Null])
        .unwrap();
    engine
        .write_by_name(mine, "visible", Value::Bool(false))
        .unwrap();
    hub.advance(1);
    assert_eq!(engine.quit_requested(), !cfg!(target_os = "macos"));
    assert!(!engine.is_alive(first));

    // A click on the Dock icon with no window shown brings back the shell
    // shown now.
    let app = engine.singleton::<ljos::prelude::Application>().unwrap();
    engine
        .emit_by_name(app, "reopened", &[Value::Bool(false)])
        .unwrap();
    assert!(matches!(
        engine.read_by_name(mine, "visible"),
        Value::Bool(true)
    ));
}

/// A window as a host hands it over, of an X server that is not there: the
/// shell's hooks never use the handles.
struct Opened;

impl HasWindowHandle for Opened {
    fn window_handle(&self) -> Result<WindowHandle<'_>, HandleError> {
        let id = NonZeroU32::new(7).expect("not zero");
        let raw = RawWindowHandle::Xcb(XcbWindowHandle::new(id));
        // SAFETY: the handle names no live window, and nothing uses it.
        Ok(unsafe { WindowHandle::borrow_raw(raw) })
    }
}

impl HasDisplayHandle for Opened {
    fn display_handle(&self) -> Result<DisplayHandle<'_>, HandleError> {
        let raw = RawDisplayHandle::Xcb(XcbDisplayHandle::new(None, 0));
        // SAFETY: as for the window handle.
        Ok(unsafe { DisplayHandle::borrow_raw(raw) })
    }
}

#[test]
fn a_reloaded_shell_keeps_the_backdrop_of_the_window_it_takes() {
    let (hub, dir) = hub();
    open(&hub, &dir);
    let first = runtime::window(&hub.engine).unwrap();
    let engine = &hub.engine;
    // A blurred theme, and the host opening the shell's window.
    platform_window::apply_window_blur(engine, true, false);
    Platform::of(engine).native_window_opened(engine, Some(first), &Opened);
    let backdrop = |window| engine.read_by_name(window, "backdrop").to_number();
    assert_eq!(backdrop(first), 1.0, "Window.BlurBackdrop");

    // The next shell takes that platform window, which the host does not
    // open again: without the backdrop the host would take it away and
    // the theme's own window would show nothing behind it.
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { objectName: \"mine\" }\n",
    );
    compile(&hub, &dir);
    runtime::reload(engine);
    let mine = runtime::window(engine).unwrap();
    assert_eq!(shown(&hub), "mine");
    assert_eq!(backdrop(mine), 1.0);
    hub.advance(1);
    assert!(!engine.is_alive(first));
    // And the theme's next backdrop reaches it.
    platform_window::apply_window_blur(engine, true, true);
    assert_eq!(backdrop(mine), 2.0, "Window.GlassBackdrop");
}

#[test]
fn an_edited_brick_runs_dynamically_after_a_reload_and_the_rest_compiled() {
    let bricks = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    copy_dir(&Roots::checkout().bricks, bricks.path());
    let roots = Roots {
        bricks: bricks.path().to_path_buf(),
        ..Roots::checkout()
    };
    let hub = Hub::new().hosted();
    hub.engine
        .set_component_source(compile_roots(&roots).source);
    runtime::open(&hub.engine).unwrap();
    let url = |key: &str| hub.engine.component_source().unwrap().url(key);
    let compiled = |key: &str| hub.engine.aot_file(&url(key));
    assert_eq!(compiled("HalC2/Bricks/ShellWindow"), Some(true));

    let edited = bricks.path().join("HalC2/Bricks/ShellWindow.qml");
    let text = std::fs::read_to_string(&edited).unwrap();
    write(&edited, &(text + "\n// Edited.\n"));
    hub.engine
        .set_component_source(compile_roots(&roots).source);
    runtime::reload(&hub.engine);
    assert!(generation(&hub) > 1);
    assert_eq!(compiled("HalC2/Bricks/ShellWindow"), Some(false));
    assert_eq!(compiled("HalC2/Bricks/DefaultLayout"), Some(true));
}

fn copy_dir(from: &Path, to: &Path) {
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let (from, to) = (entry.path(), to.join(entry.file_name()));
        if from.is_dir() {
            std::fs::create_dir_all(&to).unwrap();
            copy_dir(&from, &to);
        } else {
            std::fs::copy(&from, &to).unwrap();
        }
    }
}

/// A built-in shell whose root says which `Shell` it reads.
const READS_SHELL: &str = "import QtQuick\nimport HalC2.Shell\nWindow { objectName: \"built-in\"; property var shell: Shell }\n";

/// [`hub`] with [`READS_SHELL`] open, and `window.new` showing roots as the
/// app's opener does.
fn opening() -> (Hub, TempDir) {
    let (hub, dir) = hub();
    write(&dir.path().join("app/Builtin.qml"), READS_SHELL);
    open(&hub, &dir);
    hal_c2_shell::controller::set_window_opener(&hub.engine, runtime::open_window);
    (hub, dir)
}

/// The `Shell` root `root` reads.
fn shell_of(hub: &Hub, root: ObjectId) -> ObjectId {
    match hub.engine.read_by_name(root, "shell") {
        Value::Object(obj) => obj,
        other => panic!("shell: {other:?}"),
    }
}

fn bridge_of(hub: &Hub, id: &str) -> ObjectId {
    hal_c2_shell::controller::window_bridge(&hub.engine, id)
        .expect("the window is open")
        .object()
}

/// What the shell came back as in the user's dark circle: after the user's
/// `shell.qml` went, the built-in shell of a window read no `Shell`, as it
/// was made outside its window's scope.
#[test]
fn each_windows_shell_made_again_reads_its_own_shell() {
    use hal_c2_shell::controller::{self, MAIN};
    let (hub, dir) = opening();
    let engine = &hub.engine;
    controller::open_window(engine, Some("two")).expect("the shell is started");
    let (main, two) = (
        runtime::root_of(engine, MAIN).expect("the first shell"),
        runtime::root_of(engine, "two").expect("the opener made a shell"),
    );
    assert_ne!(main, two);
    assert_eq!(shell_of(&hub, main), bridge_of(&hub, MAIN));
    assert_eq!(shell_of(&hub, two), bridge_of(&hub, "two"));

    // The user's shell comes and goes.
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { objectName: \"mine\" }\n",
    );
    compile(&hub, &dir);
    runtime::reload(engine);
    assert_eq!(shown(&hub), "mine");
    std::fs::remove_file(dir.path().join("config/shell.qml")).unwrap();
    compile(&hub, &dir);
    runtime::reload(engine);

    let (main2, two2) = (
        runtime::root_of(engine, MAIN).unwrap(),
        runtime::root_of(engine, "two").unwrap(),
    );
    assert!(main2 != main && two2 != two && main2 != two2);
    assert_eq!(shell_of(&hub, main2), bridge_of(&hub, MAIN));
    assert_eq!(shell_of(&hub, two2), bridge_of(&hub, "two"));
    hub.advance(1);
    assert!(!engine.is_alive(main) && !engine.is_alive(two));

    // Closing a window other than the host's view lets its shell go.
    controller::close_window(engine, "two");
    hub.advance(1);
    engine.process_deferred_deletes();
    assert_eq!(runtime::root_of(engine, "two"), None);
    assert!(!engine.is_alive(two2));
    assert!(engine.is_alive(main2));
}

#[test]
fn closing_the_hosts_view_only_hides_it() {
    use hal_c2_shell::controller::{self, MAIN};
    let (hub, _dir) = opening();
    let engine = &hub.engine;
    let main = runtime::window(engine).unwrap();
    let loader = runtime::loader_of(engine, MAIN).unwrap();
    controller::open_window(engine, Some("two")).unwrap();

    controller::close_window(engine, MAIN);
    hub.advance(1);
    engine.process_deferred_deletes();

    assert_eq!(controller::windows(engine), vec!["two"]);
    assert_eq!(runtime::root_of(engine, MAIN), None);
    assert!(engine.is_alive(main), "the host's view stays, hidden");
    assert!(engine.is_alive(loader));
    assert!(runtime::root_of(engine, "two").is_some());
}

/// The root of each window, qml/Main.qml, no longer compiles: no loader,
/// so no shell, can be made for a window.
const BROKEN_MAIN: &str = "import Ljos.Blocks\nShellLoader { Nonsense {} }\n";

#[test]
fn a_window_no_shell_can_be_made_for_is_closed_and_not_saved() {
    use hal_c2_shell::controller::{self, MAIN};
    let (hub, dir) = hub();
    open(&hub, &dir);
    controller::set_window_opener(&hub.engine, runtime::open_window);
    write(&dir.path().join("app/Main.qml"), BROKEN_MAIN);
    compile(&hub, &dir);

    controller::open_window(&hub.engine, Some("two"));
    hub.advance(1);
    hub.engine.process_deferred_deletes();

    assert_eq!(controller::windows(&hub.engine), vec![MAIN]);
    assert_eq!(runtime::root_of(&hub.engine, "two"), None);
    assert!(!hub.engine.quit_requested());
    let saved = std::fs::read_to_string(dir.path().join("state/shell-windows.json")).unwrap();
    assert!(!saved.contains("two"), "{saved}");
}

#[test]
fn a_saved_window_no_shell_can_be_made_for_at_restore_keeps_its_saved_state() {
    use hal_c2_shell::controller::{self, MAIN};
    let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    for sub in ["app", "config", "state"] {
        std::fs::create_dir(dir.path().join(sub)).unwrap();
    }
    let state = dir.path().join("state");
    let two = state.join("shell-windows/two");
    std::fs::create_dir_all(&two).unwrap();
    let route = r#"{"kind":"settings","section":"general"}"#;
    std::fs::write(two.join("shell-route.json"), route).unwrap();
    std::fs::write(
        state.join("shell-windows.json"),
        r#"{"open":["main","two"]}"#,
    )
    .unwrap();
    write(&dir.path().join("app/Main.qml"), MAIN_QML);
    write(&dir.path().join("app/Builtin.qml"), BUILT_IN);
    let hub = Hub::with(Launch {
        config_dir: Some(dir.path().join("config")),
        state_dir: Some(state.clone()),
        ..Launch::default()
    })
    .hosted();
    open(&hub, &dir);
    controller::set_window_opener(&hub.engine, runtime::open_window);
    // The windows' root broke after the first window started.
    write(&dir.path().join("app/Main.qml"), BROKEN_MAIN);
    compile(&hub, &dir);

    controller::restore_windows(&hub.engine);
    hub.advance(1);
    hub.engine.process_deferred_deletes();

    assert_eq!(controller::windows(&hub.engine), vec![MAIN]);
    assert_eq!(runtime::root_of(&hub.engine, "two"), None);
    assert_eq!(
        std::fs::read_to_string(two.join("shell-route.json")).unwrap(),
        route
    );
    let saved = std::fs::read_to_string(state.join("shell-windows.json")).unwrap();
    assert!(saved.contains("two"), "{saved}");

    // A window opened and closed since keeps it saved too.
    controller::open_window(&hub.engine, Some("three"));
    hub.advance(1);
    let saved = std::fs::read_to_string(state.join("shell-windows.json")).unwrap();
    assert!(saved.contains("two") && !saved.contains("three"), "{saved}");

    // Once the first window shows another shell, it comes back as it was
    // saved.
    write(&dir.path().join("app/Main.qml"), MAIN_QML);
    compile(&hub, &dir);
    runtime::reload(&hub.engine);
    hub.advance(1);
    assert!(runtime::root_of(&hub.engine, "two").is_some());
    assert_eq!(controller::windows(&hub.engine), vec![MAIN, "two"]);
    assert!(two.join("shell-route.json").exists());

    // Closed once shown, it goes with its files, as any window does.
    controller::close_window(&hub.engine, "two");
    hub.advance(1);
    hub.engine.process_deferred_deletes();
    let saved = std::fs::read_to_string(state.join("shell-windows.json")).unwrap();
    assert!(!saved.contains("two"), "{saved}");
    assert!(!two.exists());
}
