//! The HAL-C2 desktop shell on Ljós: desktop-qt's native `HalC2.Shell`
//! module (`Shell`, `Theme`, `Runtime`) and the controllers behind it, for
//! the bricks in apps/desktop-qt/qml.

pub mod bridge;
pub mod cache;
pub mod commands;
pub mod controller;
pub mod controllers;
pub mod device_screen;
pub mod environment_settings;
pub mod folders;
pub mod highlighter;
pub mod json;
pub mod keybindings;
pub mod local_transcriber;
pub mod mc;
pub mod project;
pub mod provider;
// The desktop's notification service is D-Bus's; elsewhere system
// notifications stay quiet (desktop-qt's need HAL_C2_HAS_DBUS too).
#[cfg(all(unix, not(target_os = "macos")))]
pub mod notifications;
pub mod platform_window;
pub mod qml;
pub mod qr;
pub mod runtime;
pub mod scripted_run;
pub mod session;
pub mod settings_page;
pub mod sidebar_model;
pub mod single_instance;
pub mod storage;
pub mod store;
pub mod terminal;
pub mod theme;
pub mod thread_view;

use std::path::PathBuf;
use std::rc::Rc;

use ljos::prelude::{Engine, Version};

/// The module's import name.
pub const MODULE: &str = "HalC2.Shell";

/// Registers the native half of `HalC2.Shell` and makes its singletons, so
/// `Shell.state` holds its keys before any QML reads it. The rest of the
/// module is QML (qml/HalC2/Shell); a qmldir naming those files beside
/// these types is one module to the bricks.
///
/// For `App::register`, which also runs it on the engine that compiles the
/// QML, so what depends on the launch (config dir, MC) is given afterwards,
/// by [`start`].
pub fn register(engine: &Engine) {
    let v = Version::new(1, 0);
    engine.register_singleton::<bridge::ShellBridge>(MODULE, v);
    engine.register_singleton::<theme::ThemeStore>(MODULE, v);
    engine.register_singleton::<runtime::ShellRuntime>(MODULE, v);
    folders::register(engine);
    highlighter::register(engine);
    device_screen::register(engine);
    local_transcriber::register(engine);
    terminal::register(engine);
    engine.register_singleton::<controllers::settings::SettingsObject>(MODULE, v);
    engine.register_singleton::<controllers::keybindings::KeybindingsObject>(MODULE, v);
    engine.register_singleton::<controllers::mc_plugin::McPluginsObject>(MODULE, v);
    thread_view::register(engine, v);
    bridge::Bridge::of(engine);
}

/// What the shell is launched with: main.cpp's options, and the MC
/// host/main.ts hands over (`{origin, token}`; the token stays with the
/// connection).
#[derive(Clone, Debug, Default)]
pub struct Launch {
    /// Where `theme.json` and the user's shell are; none reads nothing.
    pub config_dir: Option<PathBuf>,
    /// The MC's origin, for what depends on where it is (local folders).
    pub mc_origin: Option<String>,
    /// Local folders may be imported from a remote MC too.
    pub allow_local_folder_import: bool,
    /// The third-party license manifest the Open source licenses page reads.
    pub licenses_manifest: Option<PathBuf>,
    /// Why the shell could not load what it was asked to, for `Runtime`.
    pub last_error: String,
    /// Where the client cache keeps what the MC last sent
    /// ([`storage::StoragePaths::cache`]); none keeps nothing.
    pub cache_dir: Option<PathBuf>,
    /// Where the session an in-app pairing makes and the shell's drafts
    /// (`shell-drafts.json`) are kept ([`storage::StoragePaths::data`]);
    /// none keeps nothing.
    pub data_dir: Option<PathBuf>,
}

/// Where [`open`] keeps the session it is given.
#[derive(Default)]
struct Kept(std::cell::RefCell<Option<PathBuf>>);

/// Connects to the MC `session` names, as NativeShell::open does: its rows
/// (what the cache kept of it) show while the socket opens, and the session
/// is kept for the next start. The shell's drafts, rows and route stay as
/// they are. An error says why the connection could not be opened; nothing
/// has changed then.
///
/// TODO(port): NativeShell::open on a shell that started without an MC: the
/// store is installed over the MC the shell starts with, so it cannot be
/// opened later.
pub fn open(engine: &Engine, session: &session::Session) -> Result<(), String> {
    let mc = controller::mc(engine).ok_or("the shell is not started")?;
    mc.open(&session.origin, &session.token)?;
    bridge::Bridge::of(engine).set_mc_origin(engine, &session.origin);
    store::open(engine, &session.origin);
    if let Some(dir) = engine.extension::<Kept>().0.borrow().as_deref() {
        // Not being able to keep it only loses the next start's reconnect.
        let _ = session::save(dir, session);
    }
    Ok(())
}

/// Gives the registered module what the launch says, then starts the
/// controllers over `mc`. Before the root is made: what the bricks bind on
/// first is published by then. Without an MC they activate at once; with
/// one, the shell store subscribes to it and they activate on its first
/// snapshot, previewing what the cache kept until then.
pub fn start(engine: &Engine, launch: &Launch, mc: Rc<dyn mc::Mc>) {
    let bridge = bridge::Bridge::of(engine);
    if let Some(origin) = &launch.mc_origin {
        bridge.set_mc_origin(engine, origin);
    }
    // main.cpp: a shell with no MC to ask imports from this machine.
    bridge.set_local_folder_import_enabled(
        engine,
        launch.mc_origin.is_none() || launch.allow_local_folder_import,
    );
    *engine.extension::<Kept>().0.borrow_mut() = launch.data_dir.clone();
    theme::install(engine, launch.config_dir.clone());
    runtime::install(engine, launch.config_dir.as_deref(), &launch.last_error);
    if let Some(manifest) = &launch.licenses_manifest {
        controllers::licenses::set_manifest_path(engine, manifest);
    }
    controllers::plugin::install(engine, launch.config_dir.clone());
    if let Some(cache) = &launch.cache_dir {
        controllers::mc_plugin::set_cache_dir(engine, cache.join("mc-plugins"));
    }
    controllers::drafts::set_path(
        engine,
        launch
            .data_dir
            .as_ref()
            .map(|dir| dir.join("shell-drafts.json")),
    );
    controller::start(engine, mc.clone(), controllers::registrations());
    controllers::settings::Settings::of(engine).set_device_path(
        engine,
        launch
            .config_dir
            .as_ref()
            .map(|dir| dir.join("preferences.json")),
    );
    match &launch.mc_origin {
        Some(origin) => {
            // NativeShell: what the cache kept of this MC shows while the
            // socket opens; the controllers activate on its first snapshot.
            let cache = launch
                .cache_dir
                .as_deref()
                .map(|dir| Rc::new(cache::LocalCache::open(Some(dir))));
            store::install(engine, &mc, cache);
            store::on_changed(engine, update);
            store::open(engine, origin);
        }
        // No MC to wait for: what the shell shows is all there is.
        None => {
            engine.extension::<Active>().0.set(true);
            controller::activate(engine);
            run_when_active(engine);
        }
    }
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
