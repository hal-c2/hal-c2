//! The controllers ported so far, each a desktop-qt NativeController.

pub mod alerts;
pub mod archived_threads;
pub mod background_activity;
pub mod client_activity;
pub mod cluster;
pub mod connection_health;
pub mod connections;
pub mod device_settings;
pub mod diagnostics;
pub mod drafts;
pub mod folders;
pub mod git;
pub mod keybindings;
pub mod layout;
pub mod licenses;
pub mod limit_recovery;
pub mod load_balancing;
pub mod mc_plugin;
pub mod menus;
pub mod navigation;
pub mod panel;
pub mod plan;
pub mod plugin;
pub mod project_actions;
pub mod project_clone;
pub mod project_settings;
pub mod projects;
pub mod provider_settings;
pub mod provider_update_notice;
pub mod pull_request_list;
pub mod pull_request_thread;
pub mod quit;
pub mod rewind;
pub mod scheduled_tasks;
pub mod settings;
pub mod settings_scope;
pub mod sidebar;
pub mod slack_settings;
pub mod source_control_settings;
pub mod stage;
pub mod storage_settings;
pub mod terminals;
pub mod text_generation;
pub mod theme;
pub mod thread_lineage;
pub mod thread_menu;
pub mod threads;
pub mod toasts;
pub mod usage;
pub mod usage_prices;
pub mod workspace;
pub mod worktree_setup;

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
        Registration::new::<background_activity::BackgroundActivity>(
            "backgroundActivity",
            &["backgroundActivity"],
            Scope::Window,
        ),
        Registration::new::<client_activity::ClientActivity>("clientActivity", &[], Scope::Window),
        Registration::new::<cluster::Cluster>("cluster", &["cluster"], Scope::Window),
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
        Registration::new::<diagnostics::Diagnostics>(
            "diagnostics",
            &["diagnostics"],
            Scope::Window,
        ),
        Registration::new::<drafts::DraftController>("drafts", &["landing"], Scope::Window),
        Registration::new::<folders::Folders>("folders", &["folders"], Scope::Window),
        Registration::new::<git::Git>("git", &["git"], Scope::Window),
        Registration::new::<keybindings::KeybindingController>("keybindings", &[], Scope::Window),
        Registration::new::<layout::Layout>("layout", &["layout"], Scope::Window),
        Registration::new::<licenses::Licenses>("licenses", &["licenses"], Scope::Window),
        Registration::new::<limit_recovery::LimitRecovery>(
            "limitRecovery",
            &["limitRecovery"],
            Scope::Window,
        ),
        Registration::new::<load_balancing::LoadBalancing>(
            "loadBalancing",
            &["loadBalancing"],
            Scope::Window,
        ),
        Registration::new::<mc_plugin::McPlugin>("mcPlugins", &["mcPlugins"], Scope::Shared),
        Registration::new::<menus::Menus>("menus", &["menu", "confirmation"], Scope::Window),
        Registration::new::<navigation::Navigation>("navigation", &["route"], Scope::Window),
        Registration::new::<panel::RightPanel>("panel", &["panel"], Scope::Window),
        Registration::new::<plan::Plan>("plan", &[], Scope::Window),
        Registration::new::<plugin::Plugin>("plugins", &["plugins"], Scope::Shared),
        Registration::new::<project_actions::ProjectActions>(
            "projectActions",
            &["projectActions"],
            Scope::Window,
        ),
        Registration::new::<project_clone::ProjectClone>("projectClones", &[], Scope::Window),
        Registration::new::<project_settings::ProjectSettings>(
            "projectSettings",
            &["projectSettings"],
            Scope::Window,
        ),
        Registration::new::<projects::Projects>("projects", &["projectRemoval"], Scope::Window),
        Registration::new::<provider_settings::ProviderSettings>(
            "providerSettings",
            &["providerSettings"],
            Scope::Window,
        ),
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
        Registration::new::<pull_request_thread::PullRequestThread>(
            "pullRequestThread",
            &["pullRequestThread"],
            Scope::Window,
        ),
        Registration::new::<quit::QuitController>("quit", &["quitHint"], Scope::Shared),
        Registration::new::<rewind::Rewind>("rewind", &["rewind"], Scope::Window),
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
        Registration::new::<sidebar::Sidebar>(
            "sidebar",
            &["sidebar", "customSnooze"],
            Scope::Window,
        ),
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
        Registration::new::<terminals::Terminals>("terminals", &[], Scope::Window),
        Registration::new::<text_generation::TextGeneration>(
            "textGeneration",
            &["textGeneration"],
            Scope::Window,
        ),
        Registration::new::<theme::Themes>("theme", &["theme"], Scope::Window),
        Registration::new::<thread_lineage::ThreadLineage>(
            "threadLineage",
            &["lineage"],
            Scope::Window,
        ),
        Registration::new::<thread_menu::ThreadMenu>("threadMenu", &[], Scope::Window),
        Registration::new::<threads::ThreadStore>("threads", &[], Scope::Window),
        Registration::new::<toasts::Toasts>("toasts", &["toasts"], Scope::Window),
        Registration::new::<usage::Usage>("usage", &["usage"], Scope::Window),
        Registration::new::<usage_prices::UsagePrices>(
            "usagePrices",
            &["usagePrices"],
            Scope::Window,
        ),
        Registration::new::<workspace::Workspace>("workspace", &["workspace"], Scope::Window),
        Registration::new::<worktree_setup::WorktreeSetup>(
            "worktreeSetup",
            &["worktreeSetup"],
            Scope::Window,
        ),
    ]
}
