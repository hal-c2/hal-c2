//! The HAL-C2 phone shell on Ljós: mobile-qt's `HalC2.Mobile`
//! (`MobileShell.qml`) over desktop-ljos's `HalC2.Shell`, as mobile-qt is
//! desktop-qt's shell with another root (docs/internals/mobile-qt.md).
//!
//! Everything the desktop already has in Rust is reused as it is: the MC
//! client (`hal_c2_mc`), the controllers behind `Shell.state`, the Theme
//! and Runtime singletons and the Terminal item, started by
//! [`hal_c2_shell::start_with`]. This crate adds only what is the
//! phone's alone: its controllers ([`pairing`], [`scanner`],
//! [`notifications`], [`maintenance`], [`mobile_terminal`], [`layout`],
//! [`resume`]), its QML entry (`qml/Main.qml`) and the QML stubs in
//! `qml/HalC2/Shell` for the two C++ types the phone's screens name
//! (`TerminalEvents`, `TurnAgents`, #1624).

pub mod layout;
pub mod maintenance;
pub mod mobile_terminal;
pub mod notifications;
pub mod pairing;
pub mod resume;
pub mod scanner;

use std::path::{Path, PathBuf};

use hal_c2_shell::controller::{Registration, Scope};
use hal_c2_shell::qml::Roots;
use ljos::prelude::Engine;

/// The QML roots in this checkout: the bricks (desktop-qt's, until they
/// move), this app's entry and stubs, and the phone's own screens
/// (mobile-qt's `HalC2.Mobile`, read where they live so both clients show
/// the same files).
pub fn roots() -> Roots {
    let apps = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("mobile-ljos is in apps/");
    roots_at(apps)
}

/// [`roots`] under an `apps/` directory, for tests.
pub fn roots_at(apps: &Path) -> Roots {
    Roots {
        bricks: apps.join("desktop-qt/qml"),
        shell: apps.join("mobile-ljos/qml"),
        extra: vec![apps.join("mobile-qt/qml")],
        user: None,
    }
}

/// Registers `HalC2.Shell` as the desktop shell does; the phone's own
/// types are QML (qml/HalC2/Shell) beside them, one module to the bricks.
pub fn register(engine: &Engine) {
    hal_c2_shell::register(engine);
}

/// The phone's controllers beside the shell's, for
/// [`hal_c2_shell::start_with`]: name order is build, activation and
/// action order, as the shell's own.
pub fn registrations() -> Vec<Registration> {
    vec![
        Registration::new::<layout::MobileLayout>("mobileLayout", &[], Scope::Window),
        Registration::new::<maintenance::Maintenance>(
            "maintenance",
            &["maintenance"],
            Scope::Shared,
        ),
        Registration::new::<mobile_terminal::MobileTerminal>(
            "mobileTerminal",
            &["mobileTerminal"],
            Scope::Window,
        ),
        Registration::new::<notifications::Notifications>(
            "notifications",
            &["notifications"],
            Scope::Shared,
        ),
        Registration::new::<pairing::Pairing>("pairing", &["pairing"], Scope::Shared),
        Registration::new::<scanner::Scanner>("scanner", &["scanner"], Scope::Shared),
    ]
}

/// What an MC lists this device as (Pairing::thisDevice off Android): the
/// machine's name, a phone, and its OS. On a host build the window's size
/// says phone or tablet, not the device, so it says mobile; the Android
/// build (H2) asks the system, as mobile-qt does over JNI.
pub fn device() -> hal_c2_mc::pairing::Client {
    let model = hal_c2_shell::this_machine::host_name().unwrap_or_default();
    hal_c2_mc::pairing::Client {
        label: if model.trim().is_empty() {
            "HAL-C2 mobile".into()
        } else {
            format!("HAL-C2 on {}", model.trim())
        },
        device_type: "mobile".into(),
        os: match std::env::consts::OS {
            "linux" => "Linux",
            "macos" => "macOS",
            "windows" => "Windows",
            other => other,
        }
        .into(),
    }
}

/// The app is set up over `data` (the home's data directory, pairing.json
/// and the terminal's text size) and `config` (terminal.json's home, as
/// MobileApp keeps it in the shell's config). Before
/// [`hal_c2_shell::start_with`].
pub fn install(engine: &Engine, data: Option<PathBuf>, config: Option<PathBuf>) {
    pairing::set_path(engine, data.map(|dir| dir.join("pairing.json")));
    mobile_terminal::set_store_path(engine, config.map(|dir| dir.join("terminal.json")));
    pairing::set_device(engine, device());
}

/// Opens the environment the phone remembers, if it has one
/// (MobileApp::start). After [`hal_c2_shell::start_with`], before the root.
pub fn start(engine: &Engine) {
    pairing::start(engine);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_roots_name_the_bricks_the_entry_and_the_phone_qml() {
        let roots = roots_at(Path::new("/apps"));
        assert_eq!(roots.bricks, PathBuf::from("/apps/desktop-qt/qml"));
        assert_eq!(roots.shell, PathBuf::from("/apps/mobile-ljos/qml"));
        assert_eq!(roots.extra, [PathBuf::from("/apps/mobile-qt/qml")]);
    }

    #[test]
    fn the_device_is_a_phone_with_this_machines_name() {
        let device = device();
        assert_eq!(device.device_type, "mobile");
        assert!(device.label.starts_with("HAL-C2"), "{}", device.label);
        assert!(!device.os.is_empty());
    }
}
