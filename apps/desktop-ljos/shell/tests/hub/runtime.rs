//! `Runtime` (src/runtime.rs), desktop-qt's ShellRuntime: the user's
//! `<config>/shell.qml` in place of the built-in shell, the fallback when
//! it does not load, `<config>/qml` on the import path, and the shell made
//! again as its files change.

use std::path::Path;
use std::sync::mpsc;

use hal_c2_shell::Launch;
use hal_c2_shell::qml::{self, Roots};
use hal_c2_shell::runtime::{self, ShellRuntime};
use ljos::prelude::{ObjectId, Value};
use tempfile::TempDir;

use crate::Hub;

const BUILT_IN: &str = "import QtQuick\nWindow { objectName: \"built-in\" }\n";

/// A shell whose built-in QML is `app/Main.qml` and whose config dir is
/// `config/`, both in a new temporary directory, not yet open.
fn hub() -> (Hub, TempDir) {
    let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    std::fs::create_dir(dir.path().join("app")).unwrap();
    std::fs::create_dir(dir.path().join("config")).unwrap();
    write(&dir.path().join("app/Main.qml"), BUILT_IN);
    let config = dir.path().join("config");
    let hub = Hub::with(Launch {
        config_dir: Some(config.clone()),
        qml: Some(roots(&dir)),
        ..Launch::default()
    });
    (hub, dir)
}

fn roots(dir: &TempDir) -> Roots {
    Roots::one(dir.path().join("app")).with_user(dir.path().join("config"))
}

/// Compiles the QML as the app does at start-up, then makes the first
/// generation as the host does for its root.
fn open(hub: &Hub, dir: &TempDir, watch: bool) -> ObjectId {
    let compiled = qml::compile(&roots(dir)).unwrap();
    hub.engine.set_component_source(compiled.source);
    runtime::open(&hub.engine, watch).unwrap()
}

/// Writes `text` to `path` in one step, as an editor saving does: a reload
/// never reads it half written.
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

/// The `objectName` of the window shown.
fn shown(hub: &Hub) -> String {
    let window = runtime::window(&hub.engine).expect("a window");
    hub.engine
        .to_js_string(&hub.engine.read_by_name(window, "objectName"))
        .to_string()
}

#[test]
fn without_a_user_shell_the_built_in_one_is_the_first_generation() {
    let (hub, dir) = hub();
    let root = open(&hub, &dir, false);
    assert_eq!(runtime::window(&hub.engine), Some(root));
    assert_eq!(shown(&hub), "built-in");
    assert_eq!(read(&hub, "usingUserShell"), "false");
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
    open(&hub, &dir, false);
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
    open(&hub, &dir, false);
    assert_eq!(shown(&hub), "built-in");
    assert_eq!(read(&hub, "usingUserShell"), "false");
    assert!(read(&hub, "lastError").contains("Nonsense"));
    assert_eq!(generation(&hub), 1);
}

#[test]
fn a_user_shell_that_is_not_a_window_falls_back() {
    let (hub, dir) = hub();
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nItem {}\n",
    );
    open(&hub, &dir, false);
    assert_eq!(shown(&hub), "built-in");
    assert!(
        read(&hub, "lastError").contains("Shell root must be a Window"),
        "{}",
        read(&hub, "lastError")
    );
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
    open(&hub, &dir, false);
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
fn reload_makes_the_next_generation_of_what_the_files_say_now() {
    let (hub, dir) = hub();
    let first = open(&hub, &dir, false);
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { objectName: \"mine\" }\n",
    );
    // As the error overlay's "Reload" does.
    let obj = hub.engine.singleton::<ShellRuntime>().unwrap();
    crate::common::call(&hub.engine, obj, "reload", &[]);
    assert_eq!(generation(&hub), 2);
    assert_eq!(shown(&hub), "mine");
    assert_eq!(read(&hub, "usingUserShell"), "true");
    // The host's root stays, hidden: it cannot be replaced.
    assert!(hub.engine.is_alive(first));
    assert!(matches!(
        hub.engine.read_by_name(first, "visible"),
        Value::Bool(false)
    ));

    let second = runtime::window(&hub.engine).unwrap();
    std::fs::remove_file(dir.path().join("config/shell.qml")).unwrap();
    runtime::reload(&hub.engine);
    assert_eq!(generation(&hub), 3);
    assert_eq!(shown(&hub), "built-in");
    assert_eq!(read(&hub, "usingUserShell"), "false");
    hub.advance(1);
    assert!(!hub.engine.is_alive(second));
}

#[test]
fn when_neither_shell_loads_the_window_shown_stays() {
    let (hub, dir) = hub();
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { objectName: \"mine\" }\n",
    );
    let root = open(&hub, &dir, false);
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { Nonsense {} }\n",
    );
    write(
        &dir.path().join("app/Main.qml"),
        "import QtQuick\nWindow { AlsoNonsense {} }\n",
    );
    runtime::reload(&hub.engine);
    assert_eq!(runtime::window(&hub.engine), Some(root));
    assert_eq!(generation(&hub), 1);
    assert_eq!(read(&hub, "usingUserShell"), "true");
    let error = read(&hub, "lastError");
    assert!(
        error.contains("Nonsense") && error.contains("AlsoNonsense"),
        "{error}"
    );

    // Fixed, the next reload clears it.
    write(&dir.path().join("app/Main.qml"), BUILT_IN);
    runtime::reload(&hub.engine);
    assert_eq!(generation(&hub), 2);
    assert_eq!(shown(&hub), "built-in");
    assert!(read(&hub, "lastError").contains("Nonsense"));
}

#[test]
fn editing_a_followed_file_makes_the_next_generation() {
    let (hub, dir) = hub();
    let (wake, woken) = mpsc::channel();
    runtime::set_wake(&hub.engine, move || {
        let _ = wake.send(());
    });
    open(&hub, &dir, true);
    assert_eq!(read(&hub, "hotReloadEnabled"), "true");
    assert_eq!(generation(&hub), 1);

    // A user shell made after the start.
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { objectName: \"mine\" }\n",
    );
    followed(&hub, &woken, |hub| shown(hub) == "mine");
    assert_eq!(read(&hub, "usingUserShell"), "true");
    let after_shell = generation(&hub);
    assert!(after_shell >= 2);

    // A brick the built-in shell is made of.
    std::fs::remove_file(dir.path().join("config/shell.qml")).unwrap();
    write(
        &dir.path().join("app/Main.qml"),
        "import QtQuick\nWindow { objectName: \"edited\" }\n",
    );
    followed(&hub, &woken, |hub| shown(hub) == "edited");
    assert!(generation(&hub) > after_shell);
    assert_eq!(read(&hub, "usingUserShell"), "false");
}

#[test]
fn a_shell_opened_without_following_does_not_reload() {
    let (hub, dir) = hub();
    open(&hub, &dir, false);
    assert_eq!(read(&hub, "hotReloadEnabled"), "false");
}

/// Waits for the watcher to see the change, then runs the debounce out on
/// the virtual clock, as the shell's loop and its timer do, until `until`.
fn followed(hub: &Hub, woken: &mpsc::Receiver<()>, until: impl Fn(&Hub) -> bool) {
    while !until(hub) {
        woken.recv().expect("the watcher wakes the shell");
        runtime::deliver(&hub.engine);
        hub.advance(120);
    }
}

#[test]
fn a_reloaded_shell_is_the_window_that_closes_and_reopens() {
    let (hub, dir) = hub();
    let first = open(&hub, &dir, false);
    write(
        &dir.path().join("config/shell.qml"),
        "import QtQuick\nWindow { objectName: \"mine\" }\n",
    );
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
    hub.advance(0);
    assert_eq!(engine.quit_requested(), !cfg!(target_os = "macos"));

    // A click on the Dock icon with no window shown brings back the shell
    // shown, not the host's first root.
    let app = engine.singleton::<ljos::prelude::Application>().unwrap();
    engine
        .emit_by_name(app, "reopened", &[Value::Bool(false)])
        .unwrap();
    assert!(matches!(
        engine.read_by_name(mine, "visible"),
        Value::Bool(true)
    ));
    assert!(matches!(
        engine.read_by_name(first, "visible"),
        Value::Bool(false)
    ));
}
