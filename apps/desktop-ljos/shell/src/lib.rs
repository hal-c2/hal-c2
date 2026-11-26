//! The HAL-C2 desktop shell on Ljós: desktop-qt's native `HalC2.Shell`
//! module (`Shell`, `Theme`, `Runtime`) and the controllers behind it, for
//! the bricks in packages/qml.

pub mod assets;
pub mod attachment_files;
pub mod bridge;
pub mod browser;
pub mod cache;
pub mod clock;
pub mod code_highlighter;
pub mod commands;
pub mod composer_model;
pub mod controller;
pub mod controllers;
pub mod desktop_host;
pub mod desktop_update;
pub mod device;
pub mod device_screen;
pub mod environment_settings;
pub mod folders;
pub mod highlighter;
pub mod json;
pub mod keybindings;
pub mod local_transcriber;
#[cfg(target_os = "macos")]
pub mod macos_window;
pub mod mc;
pub mod mc_launcher;
pub mod project;
pub mod provider;
pub mod provider_updates;
// The desktop's notification service is D-Bus's; elsewhere system
// notifications stay quiet (desktop-qt's need HAL_C2_HAS_DBUS too).
#[cfg(all(unix, not(target_os = "macos")))]
pub mod notifications;
pub mod page_input;
pub mod platform_window;
pub mod preview_automation;
pub mod qml;
pub mod qr;
pub mod runtime;
pub mod saved_environments;
pub mod schedule;
pub mod scripted_run;
#[cfg(all(unix, not(target_os = "macos")))]
pub mod secret_service;
pub mod session;
pub mod settings_page;
pub mod sidebar_model;
pub mod single_instance;
pub mod snap_shot;
pub mod storage;
pub mod store;
pub mod streams;
pub mod terminal;
pub mod theme;
pub mod this_machine;
pub mod thread_view;
pub mod time_zone;
pub mod window_mc;

use std::path::{Path, PathBuf};
use std::rc::Rc;

use ljos::prelude::{Engine, Version};

/// The module's import name.
pub const MODULE: &str = "HalC2.Shell";

/// The shell's QML as build.rs compiled it, with its sources: what the app
/// runs (`App::source`), and what the user's files in the config dir are
/// compiled against (`App::user_qml`).
pub fn pack() -> ljos::MapSource {
    ljos::include_qml!("qml.pack")
}

/// The user's `<config>` over the pack, as a release lays it (`App::user_qml`):
/// its `qml` as modules on the import path, `shell.qml` what Main.qml's
/// ShellLoader shows, and the MC's plugins in the cache loaded beside them.
/// hal-c2 reads `theme.json` itself (src/theme.rs). None without a config
/// dir.
pub fn user_qml(launch: &Launch) -> Option<ljos::UserQml> {
    let config = launch.config_dir.clone()?;
    let mut user = ljos::UserQml::dir(config).modules("qml").theme(false);
    if let Some(cache) = &launch.cache_dir {
        user = user.loads_from(cache.join("mc-plugins"));
    }
    Some(user)
}

/// The key of every QML file build.rs found, compiled or not.
pub const QML_FILES: &[&str] = include!(concat!(env!("OUT_DIR"), "/qml_files.rs"));

/// The QML files `pack` does not run, each with why: a release's
/// `--check`. A pack holds only the files that compiled and says nothing
/// of the rest, so a file build.rs found and the pack lacks did not.
pub fn unpacked(pack: &ljos::MapSource) -> Vec<(String, String)> {
    let mut failed: Vec<(String, String)> = pack
        .failures()
        .map(|(key, why)| (key.to_owned(), why.to_owned()))
        .collect();
    let packed: std::collections::HashSet<&str> = pack.keys().collect();
    for key in QML_FILES {
        if !packed.contains(key) && !failed.iter().any(|(k, _)| k == key) {
            failed.push((
                (*key).to_owned(),
                "not in the pack: it did not compile when the app was built".to_owned(),
            ));
        }
    }
    failed.sort();
    failed
}

/// Registers the native half of `HalC2.Shell` and makes its singletons, so
/// `Shell.state` holds its keys before any QML reads it. The rest of the
/// module is QML (qml/HalC2/Shell); a qmldir naming those files beside
/// these types is one module to the bricks.
///
/// For `App::register`, which also runs it on the engine that compiles the
/// QML, so what depends on the launch (config dir, MC) is given afterwards,
/// by [`start`].
///
/// Also gives the engine the checkout's bindings and handlers as build.rs
/// compiled them: a file runs that code while it is as built, and
/// dynamically once a user's file replaces it (`--qml-dir` too).
pub fn register(engine: &Engine) {
    if let Err(e) = engine.register_compiled(ljos::include_compiled!("qml.rs")) {
        engine.warn(e.to_string());
    }
    let v = Version::new(1, 0);
    engine.register_singleton::<bridge::ShellBridge>(MODULE, v);
    engine.register_singleton::<theme::ThemeStore>(MODULE, v);
    theme::tokens::register(engine);
    engine.register_singleton::<runtime::ShellRuntime>(MODULE, v);
    folders::register(engine);
    highlighter::register(engine);
    code_highlighter::register(engine);
    browser::register(engine);
    // Qt.labs.lottieqt, for a user shell's LottieAnimation (the dashboard
    // example's cat); the bricks have none of their own.
    ljos_lottie::register(engine);
    device::register(engine);
    device_screen::register(engine);
    local_transcriber::register(engine);
    terminal::register(engine);
    engine.register_singleton::<controllers::settings::SettingsObject>(MODULE, v);
    engine.register_singleton::<controllers::keybindings::KeybindingsObject>(MODULE, v);
    engine.register_singleton::<controllers::space::SpacesObject>(MODULE, v);
    controllers::space::register(engine);
    engine.register_singleton::<controllers::mc_plugin::McPluginsObject>(MODULE, v);
    engine.register_singleton::<controllers::mermaid::DiagramsObject>(MODULE, v);
    engine.register_singleton::<controllers::threads::ThreadsObject>(MODULE, v);
    engine.register_singleton::<controllers::panel::PanelObject>(MODULE, v);
    engine.register_singleton::<controllers::terminals::TerminalsObject>(MODULE, v);
    engine.register_singleton::<controllers::theme::ThemesObject>(MODULE, v);
    engine.register_singleton::<controllers::onboarding::OnboardingObject>(MODULE, v);
    engine.register_singleton::<controllers::palette::PaletteObject>(MODULE, v);
    engine
        .register_singleton::<controllers::preview_automation::PreviewAutomationObject>(MODULE, v);
    thread_view::register(engine);
    bridge::Bridge::of(engine);
}

/// Gives `scope` the bridge's own `T` ([`bridge::Bridge::in_scope`]).
fn give<T: ljos::prelude::QmlSingleton + Default>(
    engine: &Engine,
    bridge: bridge::Bridge,
    scope: ljos::prelude::WindowScope,
) {
    let given = bridge
        .singleton::<T>(engine)
        .and_then(|obj| engine.set_singleton_in::<T>(scope, obj));
    if let Err(e) = given {
        eprintln!(
            "hal-c2-shell: a window's {}: {e}",
            std::any::type_name::<T>()
        );
    }
}

/// Every type that is one for each window, as desktop-qt's engine per
/// window has its own of each: the window's bridge gives its root them.
pub(crate) const WINDOW_SINGLETONS: &[fn(&Engine, bridge::Bridge, ljos::prelude::WindowScope)] = &[
    give::<bridge::ShellBridge>,
    give::<controllers::keybindings::KeybindingsObject>,
    give::<controllers::space::SpacesObject>,
    give::<controllers::threads::ThreadsObject>,
    give::<controllers::panel::PanelObject>,
    give::<controllers::terminals::TerminalsObject>,
    give::<controllers::theme::ThemesObject>,
    give::<controllers::onboarding::OnboardingObject>,
    give::<controllers::palette::PaletteObject>,
];

/// What the shell is launched with: main.cpp's options, and the MC
/// the desktop host hands over (`{origin, token}`; the token stays
/// with the connection).
#[derive(Clone, Debug, Default)]
pub struct Launch {
    /// Where `theme.json` and the user's shell are; none reads nothing.
    pub config_dir: Option<PathBuf>,
    /// The MC's origin, for what depends on where it is (local folders).
    pub mc_origin: Option<String>,
    /// Without an origin: the desktop host names the MC later ([`attach`]),
    /// as desktop-qt's BackendProcess does. Until then the shell store
    /// waits over the cache and the controllers stay inactive, so nothing
    /// shows the shell disconnected while the MC starts.
    pub hosted: bool,
    /// Local folders may be imported from a remote MC too.
    pub allow_local_folder_import: bool,
    /// The third-party license manifest the Open source licenses page reads.
    pub licenses_manifest: Option<PathBuf>,
    /// Where the client cache keeps what the MC last sent
    /// ([`storage::StoragePaths::cache`]); none keeps nothing.
    pub cache_dir: Option<PathBuf>,
    /// Where the session an in-app pairing makes and the shell's drafts
    /// (`shell-drafts.json`) are kept ([`storage::StoragePaths::data`]);
    /// none keeps nothing.
    pub data_dir: Option<PathBuf>,
    /// Where the windows' own state is kept: each thread's right panel
    /// (`shell-panel.json`), the terminals drawer's height and per-thread
    /// state (`shell-terminals.json`), and which windows are open
    /// (`shell-windows.json`) ([`storage::StoragePaths::state`]; a window
    /// other than the first keeps its own under `shell-windows/<id>`);
    /// none keeps nothing.
    pub state_dir: Option<PathBuf>,
    /// The pages' browser profile, by its storage name; none names it for
    /// the home ([`browser::storage_name`] of `data_dir`). A process that
    /// starts many homes (the features runner) shares one: the engine keeps
    /// every profile it has opened until it exits.
    pub browser_storage: Option<String>,
}

/// What [`open`] needs of the launch, for a shell that started without an
/// MC: where the client cache is and whether local folders stay importable.
#[derive(Default)]
struct Kept {
    cache_dir: std::cell::RefCell<Option<PathBuf>>,
    allow_local_folder_import: std::cell::Cell<bool>,
    opened: std::cell::RefCell<Vec<OpenedListener>>,
}

/// What [`on_opened`] keeps.
type OpenedListener = Rc<dyn Fn(&Engine, &session::Session)>;

/// Calls `f` with each session [`open`] connects with, once it has (as
/// NativeShell::opened): a host that keeps the session for the next start
/// (the phone) hears of one bought by pairing again (ConnectionHealth)
/// as of its own.
pub fn on_opened(engine: &Engine, f: impl Fn(&Engine, &session::Session) + 'static) {
    engine
        .extension::<Kept>()
        .opened
        .borrow_mut()
        .push(Rc::new(f));
}

/// Connects to the MC `session` names, as NativeShell::open does: the MC
/// the desktop host started or paired with (BackendProcess::ready), or one
/// paired in the app. Its rows (what the cache kept of it) show while the
/// socket opens. The shell's drafts, rows and route stay as they are. A
/// shell that started without an MC gets its shell store here, over the
/// cache, as one started with an MC does; its controllers are active
/// already and follow the MC's rows as they come. An error says why the
/// connection could not be opened; nothing has changed then. Nothing is
/// kept for the next start here: the host names its MC again, in-app
/// pairings are kept by the saved environments, and a host that keeps
/// its session itself hears of it ([`on_opened`]).
///
/// A controller may call it from its own callback (an in-app pairing): the
/// store's listeners hear of the change once no controller is running.
pub fn open(engine: &Engine, session: &session::Session) -> Result<(), String> {
    let mc = controller::mc(engine).ok_or("the shell is not started")?;
    // A session that names its environment opens at an MC that must serve
    // it (mobile-qt's Pairing::start): whichever answers at the address now
    // is not taken for the one paired with.
    if session.environment_id.is_empty() {
        mc.open(&session.origin, &session.token)?;
    } else {
        mc.open_expecting(&session.origin, &session.token, &session.environment_id)?;
    }
    // NativeShell::opened: the MC on this machine needs no network, one on
    // another does. ConnectionHealth's own pairing, which is running
    // already, says so itself.
    controller::with::<controllers::connection_health::ConnectionHealth, _>(engine, |c, engine| {
        c.network_changed(engine)
    });
    let bridge = bridge::Bridge::of(engine);
    bridge.set_mc_origin(engine, &session.origin);
    let kept = engine.extension::<Kept>();
    if !has_mc(engine) {
        // main.cpp: only a shell with no MC to ask imports from this
        // machine unless told.
        bridge.set_local_folder_import_enabled(engine, kept.allow_local_folder_import.get());
        let cache = kept
            .cache_dir
            .borrow()
            .as_deref()
            .map(|dir| Rc::new(cache::LocalCache::open(Some(dir))));
        store::install(engine, &mc, cache);
        start_saved_environments(engine);
    }
    let origin = session.origin.clone();
    bridge.defer(engine, move |engine| store::open(engine, &origin));
    let listeners = kept.opened.borrow().clone();
    for listener in listeners {
        listener(engine, session);
    }
    Ok(())
}

/// Leaves the MC, as NativeShell::close does: the connection closes, and
/// what was held and kept of it goes, its threads and the drafts. `done`
/// hears false when the cache could not be emptied (see [`store::clear`]).
pub fn close(engine: &Engine, done: impl FnOnce(&Engine, bool) + 'static) {
    if let Some(mc) = controller::mc(engine) {
        mc.close();
    }
    // Every draft is one of its machines', listed or not. They go after its
    // rows, so a window that showed either lands on neither.
    let drafts = controllers::drafts::all(engine);
    store::clear(engine, done);
    for draft in drafts {
        controllers::drafts::remove(engine, &draft.id);
    }
    bridge::Bridge::of(engine).set_mc_origin(engine, "");
}

/// NativeShell::setStoreDirs: the environments paired beside the shell's MC
/// connect once the store is there, before that MC's first snapshot, so
/// it lists what each link serves and that snapshot takes none of their
/// cached MCs for its own.
fn start_saved_environments(engine: &Engine) {
    controller::with::<controllers::saved_environments::SavedEnvironments, _>(
        engine,
        |c, engine| c.start(engine),
    );
}

/// Whether the shell follows an MC: it started with one, or was
/// [`open`]ed at one since.
pub fn has_mc(engine: &Engine) -> bool {
    store::get(engine).is_some()
}

/// Gives the registered module what the launch says, then starts the
/// controllers over `mc`. Before the root is made: what the bricks bind on
/// first is published by then. Without an MC they activate at once; with
/// one, the shell store subscribes to it and they activate on its first
/// snapshot, previewing what the cache kept until then.
pub fn start(engine: &Engine, launch: &Launch, mc: Rc<dyn mc::Mc>) {
    start_with(engine, launch, mc, Vec::new());
}

/// [`start`] with controllers of the app's own beside the shell's (the
/// phone's, in apps/mobile-ljos): built, activated and offered actions in
/// name order with the rest, their state keys declared the same way.
pub fn start_with(
    engine: &Engine,
    launch: &Launch,
    mc: Rc<dyn mc::Mc>,
    extra: Vec<controller::Registration>,
) {
    let bridge = bridge::Bridge::of(engine);
    if let Some(origin) = &launch.mc_origin {
        bridge.set_mc_origin(engine, origin);
    }
    // main.cpp: a shell with no MC to ask imports from this machine.
    bridge.set_local_folder_import_enabled(
        engine,
        launch.mc_origin.is_none() || launch.allow_local_folder_import,
    );
    let kept = engine.extension::<Kept>();
    *kept.cache_dir.borrow_mut() = launch.cache_dir.clone();
    kept.allow_local_folder_import
        .set(launch.allow_local_folder_import);
    assets::install(engine);
    platform_window::install(engine);
    #[cfg(target_os = "macos")]
    macos_window::install(engine);
    theme::install(engine, launch.config_dir.clone());
    runtime::install(engine, launch.config_dir.as_deref());
    if let Some(manifest) = &launch.licenses_manifest {
        controllers::licenses::set_manifest_path(engine, manifest);
    }
    controllers::plugin::install(engine, launch.config_dir.clone());
    if let Some(cache) = &launch.cache_dir {
        controllers::mc_plugin::set_cache_dir(engine, cache.join("mc-plugins"));
        controllers::desktop_update::set_cache_dir(engine, cache.join("updates"));
    }
    controllers::drafts::set_path(
        engine,
        launch
            .data_dir
            .as_ref()
            .map(|dir| dir.join("shell-drafts.json")),
    );
    controllers::saved_environments::set_data_dir(engine, launch.data_dir.clone());
    controllers::composer::set_store_path(
        engine,
        launch
            .data_dir
            .as_ref()
            .map(|dir| dir.join("shell-composer.json")),
    );
    // Each window keeps its panel and terminals under its own directory
    // of this one (ShellWindows::windowDir).
    controller::set_state_dir(engine, launch.state_dir.clone());
    let mut registrations = controllers::registrations();
    registrations.extend(extra);
    controller::start(engine, mc.clone(), registrations);
    controllers::settings::Settings::of(engine).set_device_path(
        engine,
        launch
            .config_dir
            .as_ref()
            .map(|dir| dir.join("preferences.json")),
    );
    if let (Some(data), Some(cache)) = (&launch.data_dir, &launch.cache_dir) {
        let name = launch
            .browser_storage
            .clone()
            .unwrap_or_else(|| browser::storage_name(data));
        browser::set_profile(engine, &name, data, cache);
    }
    browser::start(engine);
    conceal_on_hold(engine);
    if launch.mc_origin.is_some() || launch.hosted {
        // NativeShell: what the cache kept of this MC shows while the
        // socket opens; the controllers activate on its first snapshot. A
        // hosted shell's MC is opened once the host names it ([`attach`]).
        let cache = launch
            .cache_dir
            .as_deref()
            .map(|dir| Rc::new(cache::LocalCache::open(Some(dir))));
        store::install(engine, &mc, cache);
        store::on_changed(engine, update);
        start_saved_environments(engine);
        if let Some(origin) = &launch.mc_origin {
            store::open(engine, origin);
        }
    } else {
        // No MC to wait for: what the shell shows is all there is.
        engine.extension::<Active>().0.set(true);
        controller::activate(engine);
        run_when_active(engine);
    }
}

/// main.cpp: a finished quit hold hides the window while the key is let
/// go (QuitController's `concealRequested`).
fn conceal_on_hold(engine: &Engine) {
    controller::with::<controllers::quit::QuitController, _>(engine, |quit, _| {
        quit.on_conceal(|engine| {
            if let Some(window) = runtime::window(engine) {
                let _ = engine.invoke_by_name(window, "hide", &[]);
            }
        })
    });
}

/// The folders a launch names (`hal-c2-ljos ~/code/api`), as absolute
/// paths, and the rest of what it passed, which is the desktop host's
/// (main.cpp's positional arguments).
pub fn launch_folders(arguments: &[String]) -> (Vec<String>, Vec<String>) {
    let (folders, rest): (Vec<&String>, Vec<&String>) =
        arguments.iter().partition(|a| Path::new(a).is_dir());
    let folders = folders
        .into_iter()
        .map(|f| {
            std::path::absolute(f)
                .unwrap_or_else(|_| PathBuf::from(f))
                .to_string_lossy()
                .into_owned()
        })
        .collect();
    (folders, rest.into_iter().cloned().collect())
}

/// What the window does with the folders a launch named: adds each as a
/// project, or finds it, and starts a thread there; then comes to the
/// front (main.cpp's `launch`).
pub fn open_folders(engine: &Engine, folders: &[String]) {
    // desktop-qt hands them to the first window's bridge; once that window
    // has closed, to the oldest one open, where desktop-qt would lose them.
    let bridge = controller::windows(engine)
        .first()
        .and_then(|id| controller::window_bridge(engine, id))
        .unwrap_or_else(|| bridge::Bridge::of(engine));
    for folder in folders {
        bridge.dispatch(
            engine,
            "project.launch",
            serde_json::json!({"path": folder}),
        );
    }
    bridge.window_command(engine, "raise");
}

/// Whether the controllers are active, once the store first synchronized,
/// and what waits for that.
#[derive(Default)]
struct Active(std::cell::Cell<bool>, std::cell::RefCell<Vec<Waiting>>);

type Waiting = Box<dyn FnOnce(&Engine)>;

/// NativeShell::update: until the MC's first snapshot, the windows preview
/// what the cache kept; on it, the controllers activate, once.
fn update(engine: &Engine) {
    let active = engine.extension::<Active>();
    if active.0.get() {
        return;
    }
    let (synchronized, previewing) = store::with(engine, |s| (s.synchronized(), s.previewing()));
    if !synchronized {
        if previewing {
            controller::preview(engine);
        }
        return;
    }
    active.0.set(true);
    controller::activate(engine);
    run_when_active(engine);
}

/// Runs what [`when_active`] kept, in the order it came.
fn run_when_active(engine: &Engine) {
    let waiting = std::mem::take(&mut *engine.extension::<Active>().1.borrow_mut());
    for f in waiting {
        f(engine);
    }
}

/// Runs `f` once the controllers are active: now when they are, else on the
/// MC's first snapshot (at once without an MC). The scripted run's steps
/// wait for it, as ScriptedRun waits for the shell to show the MC's state.
pub fn when_active(engine: &Engine, f: impl FnOnce(&Engine) + 'static) {
    if active(engine) {
        f(engine);
    } else {
        engine
            .extension::<Active>()
            .1
            .borrow_mut()
            .push(Box::new(f));
    }
}

/// Whether the controllers are active: at once without an MC, else once its
/// first snapshot is in.
pub fn active(engine: &Engine) -> bool {
    engine.extension::<Active>().0.get()
}

#[cfg(test)]
mod launch_tests {
    use super::launch_folders;

    #[test]
    fn a_launch_names_folders_as_absolute_paths_and_passes_the_rest_on() {
        let here = std::env::current_dir().unwrap();
        let (folders, rest) = launch_folders(&[
            "src".into(),
            "--mc-port=1".into(),
            "no-such-folder".into(),
            here.to_string_lossy().into_owned(),
        ]);
        assert_eq!(
            folders,
            [here.join("src"), here.clone()].map(|p| p.to_string_lossy().into_owned())
        );
        assert_eq!(rest, ["--mc-port=1", "no-such-folder"]);
    }
}

#[cfg(test)]
mod pack_tests {
    use super::{QML_FILES, pack, unpacked};

    #[test]
    fn the_pack_holds_every_qml_file() {
        assert!(QML_FILES.contains(&"Main"), "{QML_FILES:?}");
        assert_eq!(unpacked(&pack()), Vec::<(String, String)>::new());
    }

    #[test]
    fn a_file_the_pack_lacks_did_not_compile() {
        let missing = unpacked(&ljos::MapSource::new());
        assert_eq!(missing.len(), QML_FILES.len());
        assert!(
            missing
                .iter()
                .any(|(key, why)| key == "Main" && why.contains("did not compile")),
            "{missing:?}"
        );
    }
}
