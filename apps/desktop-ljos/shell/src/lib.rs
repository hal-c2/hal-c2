//! The HAL-C2 desktop shell on Ljós: desktop-qt's native `HalC2.Shell`
//! module (`Shell`, `Theme`, `Runtime`) and the controllers behind it, for
//! the bricks in apps/desktop-qt/qml.

pub mod bridge;
pub mod cache;
pub mod controller;
pub mod controllers;
pub mod json;
pub mod mc;
pub mod qml;
pub mod render;
pub mod runtime;
pub mod storage;
pub mod theme;

use std::path::PathBuf;
use std::rc::Rc;

use ljos::prelude::Engine;
use ljos_engine::Version;

/// The module's import name.
pub const MODULE: &str = "HalC2.Shell";

/// Registers the native half of `HalC2.Shell` and makes its singletons, so
/// `Shell.state` holds its keys before any QML reads it. The rest of the
/// module is QML (qml/HalC2/Shell); a qmldir naming those files beside
/// these types is one module to the bricks.
///
/// An `App::register` function: Ljós takes a plain `fn`, so what depends on
/// the launch (config dir, MC) is given afterwards, by `theme::install`,
/// `runtime::install` and `controller::start`.
pub fn register(engine: &Engine) {
    let v = Version::new(1, 0);
    engine.register_singleton::<bridge::ShellBridge>(MODULE, v);
    engine.register_singleton::<theme::ThemeStore>(MODULE, v);
    engine.register_singleton::<runtime::ShellRuntime>(MODULE, v);
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
    /// Why the shell could not load what it was asked to, for `Runtime`.
    pub last_error: String,
}

/// Gives the registered module what the launch says, then starts and
/// activates the controllers over `mc`. Before the root is made: what the
/// bricks bind on first is published by then.
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
    theme::install(engine, launch.config_dir.clone());
    runtime::install(engine, launch.config_dir.as_deref(), &launch.last_error);
    controller::start(engine, mc, controllers::registrations());
    // desktop-qt activates on the store's first snapshot; there is no store
    // yet, so at once.
    controller::activate(engine);
}
