//! The controllers ported so far, each a desktop-qt NativeController.

pub mod client_activity;
pub mod keybindings;
pub mod layout;
pub mod menus;
pub mod navigation;
pub mod quit;
pub mod settings;
pub mod settings_scope;
pub mod theme;
pub mod toasts;

use crate::controller::{Registration, Scope};

/// Every controller the shell runs, as NativeControllerRegistrar lists them.
pub fn registrations() -> Vec<Registration> {
    vec![
        Registration::new::<client_activity::ClientActivity>("clientActivity", &[], Scope::Window),
        Registration::new::<keybindings::KeybindingController>("keybindings", &[], Scope::Window),
        Registration::new::<layout::Layout>("layout", &["layout"], Scope::Window),
        Registration::new::<menus::Menus>("menus", &["menu", "confirmation"], Scope::Window),
        Registration::new::<navigation::Navigation>("navigation", &["route"], Scope::Window),
        Registration::new::<quit::QuitController>("quit", &["quitHint"], Scope::Shared),
        Registration::new::<settings::SettingsController>("settings", &[], Scope::Shared),
        Registration::new::<settings_scope::SettingsScopeController>(
            "settingsScope",
            &["settingsScope"],
            Scope::Window,
        ),
        Registration::new::<theme::Themes>("theme", &["theme"], Scope::Window),
        Registration::new::<toasts::Toasts>("toasts", &["toasts"], Scope::Window),
    ]
}
