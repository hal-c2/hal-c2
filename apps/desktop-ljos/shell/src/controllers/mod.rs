//! The controllers ported so far, each a desktop-qt NativeController.

pub mod alerts;
pub mod background_activity;
pub mod client_activity;
pub mod cluster;
pub mod diagnostics;
pub mod folders;
pub mod keybindings;
pub mod layout;
pub mod licenses;
pub mod load_balancing;
pub mod menus;
pub mod navigation;
pub mod quit;
pub mod scheduled_tasks;
pub mod settings;
pub mod settings_scope;
pub mod sidebar_seam;
pub mod slack_settings;
pub mod source_control_settings;
pub mod stage;
pub mod storage_settings;
pub mod text_generation;
pub mod theme;
pub mod toasts;
pub mod usage_prices;

use crate::controller::{Registration, Scope};

/// Every controller the shell runs, as NativeControllerRegistrar lists them.
pub fn registrations() -> Vec<Registration> {
    vec![
        Registration::new::<alerts::AlertController>("alerts", &[], Scope::Shared),
        Registration::new::<background_activity::BackgroundActivity>(
            "backgroundActivity",
            &["backgroundActivity"],
            Scope::Window,
        ),
        Registration::new::<client_activity::ClientActivity>("clientActivity", &[], Scope::Window),
        Registration::new::<cluster::Cluster>("cluster", &["cluster"], Scope::Window),
        Registration::new::<diagnostics::Diagnostics>(
            "diagnostics",
            &["diagnostics"],
            Scope::Window,
        ),
        Registration::new::<folders::Folders>("folders", &["folders"], Scope::Window),
        Registration::new::<keybindings::KeybindingController>("keybindings", &[], Scope::Window),
        Registration::new::<layout::Layout>("layout", &["layout"], Scope::Window),
        Registration::new::<licenses::Licenses>("licenses", &["licenses"], Scope::Window),
        Registration::new::<load_balancing::LoadBalancing>(
            "loadBalancing",
            &["loadBalancing"],
            Scope::Window,
        ),
        Registration::new::<menus::Menus>("menus", &["menu", "confirmation"], Scope::Window),
        Registration::new::<navigation::Navigation>("navigation", &["route"], Scope::Window),
        Registration::new::<quit::QuitController>("quit", &["quitHint"], Scope::Shared),
        Registration::new::<scheduled_tasks::ScheduledTasks>(
            "scheduledTasks",
            &["scheduledTasks"],
            Scope::Window,
        ),
        Registration::new::<settings::SettingsController>("settings", &[], Scope::Shared),
        Registration::new::<settings_scope::SettingsScopeController>(
            "settingsScope",
            &["settingsScope"],
            Scope::Window,
        ),
        Registration::new::<sidebar_seam::SidebarSeam>("sidebar", &["sidebar"], Scope::Window),
        Registration::new::<slack_settings::SlackSettings>(
            "slackSettings",
            &["slackSettings"],
            Scope::Window,
        ),
        Registration::new::<source_control_settings::SourceControlSettings>(
            "sourceControlSettings",
            &["sourceControlSettings"],
            Scope::Window,
        ),
        Registration::new::<stage::Stage>("stage", &["stage"], Scope::Window),
        Registration::new::<storage_settings::StorageSettings>(
            "storageSettings",
            &["storageSettings"],
            Scope::Window,
        ),
        Registration::new::<text_generation::TextGeneration>(
            "textGeneration",
            &["textGeneration"],
            Scope::Window,
        ),
        Registration::new::<theme::Themes>("theme", &["theme"], Scope::Window),
        Registration::new::<toasts::Toasts>("toasts", &["toasts"], Scope::Window),
        Registration::new::<usage_prices::UsagePrices>(
            "usagePrices",
            &["usagePrices"],
            Scope::Window,
        ),
    ]
}
