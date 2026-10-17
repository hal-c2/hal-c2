//! The controllers ported so far, each a desktop-qt NativeController.

pub mod alerts;
pub mod archived_threads;
pub mod client_activity;
pub mod connection_health;
pub mod connections;
pub mod device_settings;
pub mod keybindings;
pub mod layout;
pub mod licenses;
pub mod mc_plugin;
pub mod menus;
pub mod navigation;
pub mod plugin;
pub mod provider_update_notice;
pub mod pull_request_list;
pub mod quit;
pub mod settings;
pub mod settings_scope;
pub mod sidebar_seam;
pub mod theme;
pub mod toasts;
pub mod usage;
pub mod usage_prices;

use crate::controller::{Registration, Scope};

/// Every controller the shell runs, as NativeControllerRegistrar lists them.
pub fn registrations() -> Vec<Registration> {
    vec![
        Registration::new::<alerts::AlertController>("alerts", &[], Scope::Shared),
        Registration::new::<archived_threads::ArchivedThreads>(
            "archivedThreads",
            &["archivedThreads"],
            Scope::Window,
        ),
        Registration::new::<client_activity::ClientActivity>("clientActivity", &[], Scope::Window),
        Registration::new::<connection_health::ConnectionHealth>(
            "connectionHealth",
            &["connection"],
            Scope::Shared,
        ),
        Registration::new::<connections::Connections>(
            "connections",
            &["connections"],
            Scope::Window,
        ),
        Registration::new::<device_settings::DeviceSettings>(
            "deviceSettings",
            &["deviceSettings"],
            Scope::Window,
        ),
        Registration::new::<keybindings::KeybindingController>("keybindings", &[], Scope::Window),
        Registration::new::<layout::Layout>("layout", &["layout"], Scope::Window),
        Registration::new::<licenses::Licenses>("licenses", &["licenses"], Scope::Window),
        Registration::new::<mc_plugin::McPlugin>("mcPlugins", &["mcPlugins"], Scope::Shared),
        Registration::new::<menus::Menus>("menus", &["menu", "confirmation"], Scope::Window),
        Registration::new::<navigation::Navigation>("navigation", &["route"], Scope::Window),
        Registration::new::<plugin::Plugin>("plugins", &["plugins"], Scope::Shared),
        Registration::new::<provider_update_notice::ProviderUpdateNotice>(
            "providerUpdateNotice",
            &[],
            Scope::Shared,
        ),
        Registration::new::<pull_request_list::PullRequestList>(
            "pullRequestList",
            &["pullRequestList"],
            Scope::Window,
        ),
        Registration::new::<quit::QuitController>("quit", &["quitHint"], Scope::Shared),
        Registration::new::<settings::SettingsController>("settings", &[], Scope::Shared),
        Registration::new::<settings_scope::SettingsScopeController>(
            "settingsScope",
            &["settingsScope"],
            Scope::Window,
        ),
        Registration::new::<sidebar_seam::SidebarSeam>("sidebar", &["sidebar"], Scope::Window),
        Registration::new::<theme::Themes>("theme", &["theme"], Scope::Window),
        Registration::new::<toasts::Toasts>("toasts", &["toasts"], Scope::Window),
        Registration::new::<usage::Usage>("usage", &["usage"], Scope::Window),
        Registration::new::<usage_prices::UsagePrices>(
            "usagePrices",
            &["usagePrices"],
            Scope::Window,
        ),
    ]
}
