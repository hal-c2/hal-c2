//! The controllers ported so far, each a desktop-qt NativeController.

pub mod alerts;
pub mod client_activity;
pub mod drafts;
pub mod keybindings;
pub mod layout;
pub mod licenses;
pub mod menus;
pub mod navigation;
pub mod quit;
pub mod settings;
pub mod settings_scope;
pub mod sidebar;
pub mod theme;
pub mod thread_menu;
pub mod toasts;
pub mod usage_prices;

use crate::controller::{Registration, Scope};

/// Every controller the shell runs, as NativeControllerRegistrar lists them.
pub fn registrations() -> Vec<Registration> {
    vec![
        Registration::new::<alerts::AlertController>("alerts", &[], Scope::Shared),
        Registration::new::<client_activity::ClientActivity>("clientActivity", &[], Scope::Window),
        Registration::new::<drafts::DraftController>("drafts", &["landing"], Scope::Window),
        Registration::new::<keybindings::KeybindingController>("keybindings", &[], Scope::Window),
        Registration::new::<layout::Layout>("layout", &["layout"], Scope::Window),
        Registration::new::<licenses::Licenses>("licenses", &["licenses"], Scope::Window),
        Registration::new::<menus::Menus>("menus", &["menu", "confirmation"], Scope::Window),
        Registration::new::<navigation::Navigation>("navigation", &["route"], Scope::Window),
        Registration::new::<quit::QuitController>("quit", &["quitHint"], Scope::Shared),
        Registration::new::<settings::SettingsController>("settings", &[], Scope::Shared),
        Registration::new::<settings_scope::SettingsScopeController>(
            "settingsScope",
            &["settingsScope"],
            Scope::Window,
        ),
        Registration::new::<sidebar::Sidebar>(
            "sidebar",
            &["sidebar", "customSnooze"],
            Scope::Window,
        ),
        Registration::new::<theme::Themes>("theme", &["theme"], Scope::Window),
        Registration::new::<thread_menu::ThreadMenu>("threadMenu", &[], Scope::Window),
        Registration::new::<toasts::Toasts>("toasts", &["toasts"], Scope::Window),
        Registration::new::<usage_prices::UsagePrices>(
            "usagePrices",
            &["usagePrices"],
            Scope::Window,
        ),
    ]
}
