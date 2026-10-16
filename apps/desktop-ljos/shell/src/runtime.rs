//! `Runtime` in `HalC2.Shell`, desktop-qt's ShellRuntime as the bricks see
//! it: where the shell's files are and whether the user's own shell loaded.
//!
//! The shell here loads the built-in bricks only: no user `shell.qml`, no
//! hot reload, so `reload()` does nothing yet.

use std::path::Path;

use ljos::prelude::{Atom, Cx, Engine, QmlObject, qml_impl};
use ljos_engine::qml_singleton;

#[derive(Debug, QmlObject)]
// Not `uncreatable`: Ljós then cannot make the singleton either
// (meta.create is gone), and `engine.singleton` fails.
#[qml(module = "HalC2.Shell", name = "Runtime")]
#[qml_singleton]
pub struct ShellRuntime {
    #[qml(constant, readonly)]
    config_dir: Atom,
    #[qml(constant, readonly)]
    user_shell_path: Atom,
    #[qml(notify, readonly)]
    using_user_shell: bool,
    #[qml(notify, readonly)]
    last_error: Atom,
    #[qml(notify, readonly)]
    generation: i32,
    #[qml(constant, readonly)]
    hot_reload_enabled: bool,
    #[qml(constant, readonly)]
    app_version: Atom,
}

impl Default for ShellRuntime {
    fn default() -> Self {
        ShellRuntime {
            config_dir: Atom::from(""),
            user_shell_path: Atom::from(""),
            using_user_shell: false,
            last_error: Atom::from(""),
            generation: 1,
            hot_reload_enabled: false,
            app_version: Atom::from(env!("CARGO_PKG_VERSION")),
        }
    }
}

#[qml_impl]
impl ShellRuntime {
    #[qml(invokable)]
    fn reload(&self) {}
}

/// Gives the engine's `Runtime` the config dir, and why the shell could not
/// load what it was asked to (`last_error`), if it could not.
pub fn install(engine: &Engine, config_dir: Option<&Path>, last_error: &str) {
    let obj = engine
        .singleton::<ShellRuntime>()
        .expect("HalC2.Shell is registered");
    let cx = Cx::new(engine, obj);
    if let Some(dir) = config_dir {
        let _ = cx.set(
            ShellRuntime::CONFIG_DIR,
            Atom::from(dir.to_string_lossy().as_ref()),
        );
        let user_shell = dir.join("shell.qml");
        let _ = cx.set(
            ShellRuntime::USER_SHELL_PATH,
            Atom::from(user_shell.to_string_lossy().as_ref()),
        );
    }
    let _ = cx.set(ShellRuntime::LAST_ERROR, Atom::from(last_error));
}
