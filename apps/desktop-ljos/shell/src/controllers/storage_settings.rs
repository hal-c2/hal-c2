//! `storageSettings`, desktop-qt's StorageSettingsController: Settings →
//! Storage, the cleanup rules the MC sweeps by (HalC2.StorageCleanup),
//! across the settings scope. At a project scope only the worktree rules
//! show, as the project's `worktreeCleanup` override: inherited, off, or its
//! own rules.
//!
//! Publishes `storageSettings`: {status: ready | loading | unsupported,
//! notice (why nothing shows), eligible [{id, label}] (environments that can
//! show it), projectScope, mode: {value: inherit | off | custom, mixed},
//! worktrees and artifacts: [{key, title, description, days (a retention in
//! days rather than a switch), value (bool, or days and null for off),
//! mixed}] (worktrees empty while a project inherits or is off)}.
//!
//! Actions: `storageSettings.set {key, value}` (a days rule takes a number
//! of days, or null to turn it off), `storageSettings.mode {mode}`.

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::controllers::settings::Map;
use crate::controllers::settings_scope::SettingsScope;
use crate::json::Json;
use crate::settings_page;

const KEY: &str = "storageSettings";
const POLICY: &str = "worktreeCleanup";
const STORAGE: &str = "storageCleanup";

struct Rule {
    key: &'static str,
    title: &'static str,
    description: &'static str,
    /// A retention in days rather than a switch.
    days: bool,
    worktree: bool,
}

const RULES: [Rule; 6] = [
    Rule {
        key: "worktreeOnDelete",
        title: "Delete worktrees with deleted threads",
        description: "Remove unused worktrees when active or archived threads are deleted. Worktrees with local changes are kept.",
        days: false,
        worktree: true,
    },
    Rule {
        key: "worktreeAfterDays",
        title: "Delete inactive worktrees",
        description: "Remove worktrees after their threads have been inactive for this many days. Branches and thread history are kept.",
        days: true,
        worktree: true,
    },
    Rule {
        key: "worktreeOnMerge",
        title: "Delete merged worktrees",
        description: "Remove worktrees whose pull request is merged and whose commits are included in the default branch.",
        days: false,
        worktree: true,
    },
    Rule {
        key: "worktreeUnchanged",
        title: "Delete unchanged worktrees",
        description: "Remove worktrees with no commits beyond the default branch.",
        days: false,
        worktree: true,
    },
    Rule {
        key: "browserArtifactsAfterDays",
        title: "Delete old browser artifacts",
        description: "Delete saved browser captures after this many days. Older capture links will no longer open.",
        days: true,
        worktree: false,
    },
    Rule {
        key: "logsAfterDays",
        title: "Delete old rotated logs",
        description: "Delete inactive rotated log files after this many days. Current logs are kept.",
        days: true,
        worktree: false,
    },
];

fn find(key: &str) -> Option<&'static Rule> {
    RULES.iter().find(|r| r.key == key)
}

fn object(settings: &Map, key: &str) -> Map {
    settings
        .get(key)
        .and_then(Json::as_object)
        .cloned()
        .unwrap_or_default()
}

/// The project's `worktreeCleanup` mode: inherit, off or custom.
fn mode(settings: &Map, project_id: &str) -> &'static str {
    let policy = SettingsScope::override_of(settings, project_id, POLICY);
    match policy
        .as_ref()
        .and_then(|p| p.get("mode"))
        .and_then(Json::as_str)
    {
        Some("off") => "off",
        Some("custom") => "custom",
        _ => "inherit",
    }
}

/// resolveWorktreeCleanup: the rules a project (or, with none, the
/// environment) sweeps worktrees by, each with its default.
fn worktree_rules(settings: &Map, project_id: &str) -> Map {
    let mut policy = object(settings, POLICY);
    if !project_id.is_empty() && mode(settings, project_id) != "inherit" {
        policy = SettingsScope::override_of(settings, project_id, POLICY)
            .and_then(|p| p.as_object().cloned())
            .unwrap_or_default();
    }
    let source = match policy.get("mode").and_then(Json::as_str) {
        Some("custom") => object(&policy, "rules"),
        Some("off") => Map::new(),
        _ => object(settings, STORAGE),
    };
    RULES
        .iter()
        .filter(|r| r.worktree)
        .map(|r| {
            let value = source.get(r.key);
            let value = if r.days {
                value
                    .filter(|v| v.is_number())
                    .cloned()
                    .unwrap_or(Json::Null)
            } else {
                Json::Bool(value.and_then(Json::as_bool).unwrap_or(false))
            };
            (r.key.to_owned(), value)
        })
        .collect()
}

pub struct StorageSettings {
    bridge: Bridge,
    me: Me<StorageSettings>,
    active: bool,
}

impl Controller for StorageSettings {
    fn new(init: Init<'_, Self>) -> Self {
        StorageSettings {
            bridge: init.bridge,
            me: init.me,
            active: false,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        SettingsScope::of(engine).on_changed(move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("storageSettings.") {
            return false;
        }
        let scope = SettingsScope::of(engine);
        match action {
            "storageSettings.set" => {
                let key = settings_page::text(payload, "key").to_owned();
                let Some(rule) = find(&key) else {
                    return true;
                };
                let value = payload.get("value");
                let value = if rule.days {
                    match value {
                        Some(Json::Number(n)) => {
                            let days = n.as_f64().map_or(1, |f| f.round() as i64);
                            json!(days.clamp(1, 3650))
                        }
                        _ => Json::Null,
                    }
                } else {
                    Json::Bool(settings_page::flag(value))
                };
                if scope.project_scope() {
                    if !rule.worktree {
                        return true;
                    }
                    scope.write(
                        engine,
                        move |settings, project_id| {
                            let mut rules = worktree_rules(&settings, project_id);
                            rules.insert(key.clone(), value.clone());
                            SettingsScope::with_override(
                                settings,
                                project_id,
                                POLICY,
                                Some(json!({"mode": "custom", "rules": rules})),
                            )
                        },
                        "",
                    );
                } else {
                    scope.write(
                        engine,
                        move |mut settings, _| {
                            let mut storage = object(&settings, STORAGE);
                            storage.insert(key.clone(), value.clone());
                            settings.insert(STORAGE.into(), Json::Object(storage));
                            settings
                        },
                        "",
                    );
                }
            }
            "storageSettings.mode" => {
                let mode = settings_page::text(payload, "mode").to_owned();
                if !scope.project_scope() {
                    return true;
                }
                scope.write(
                    engine,
                    move |settings, project_id| {
                        let value = match mode.as_str() {
                            "off" => Some(json!({"mode": "off"})),
                            // Custom rules start from the ones the project had.
                            "custom" => Some(json!({
                                "mode": "custom",
                                "rules": worktree_rules(&settings, project_id),
                            })),
                            _ => None,
                        };
                        SettingsScope::with_override(settings, project_id, POLICY, value)
                    },
                    "",
                );
            }
            _ => {}
        }
        true
    }
}

impl StorageSettings {
    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let scope = SettingsScope::of(engine);
        let project = scope.project_scope();
        let lacking = scope.lacking(if project {
            "projectWorktreeCleanup"
        } else {
            "storageCleanup"
        });
        let reading = scope.read(|settings, _| Some(Json::Object(settings.clone())));
        let (status, notice, eligible) = if !lacking.is_empty() {
            let eligible: Vec<Json> = if project {
                Vec::new()
            } else {
                scope
                    .targets()
                    .into_iter()
                    .filter(|id| !lacking.contains(id))
                    .map(|id| json!({"label": scope.label(engine, &id), "id": id}))
                    .collect()
            };
            let notice = if project {
                "Update the selected machines to configure project worktree cleanup."
            } else {
                "Update the selected environments to use storage cleanup, or choose a machine that supports it."
            };
            ("unsupported", Some(notice), Some(eligible))
        } else if reading.known == 0 {
            ("loading", None, None)
        } else {
            ("ready", None, None)
        };
        let mode_reading =
            scope.read(|settings, project_id| Some(json!(mode(settings, project_id))));
        let mode_value = mode_reading
            .value
            .as_ref()
            .and_then(Json::as_str)
            .unwrap_or("inherit")
            .to_owned();
        let show_worktrees = !project || (!mode_reading.mixed && mode_value == "custom");
        let mut worktrees = Vec::new();
        let mut artifacts = Vec::new();
        for rule in &RULES {
            if if rule.worktree {
                !show_worktrees
            } else {
                project
            } {
                continue;
            }
            let key = rule.key;
            let value = scope.read(move |settings, project_id| {
                if find(key).is_some_and(|r| r.worktree) {
                    return worktree_rules(settings, project_id).get(key).cloned();
                }
                Some(
                    object(settings, STORAGE)
                        .get(key)
                        .filter(|v| v.is_number())
                        .cloned()
                        .unwrap_or(Json::Null),
                )
            });
            let row = json!({
                "key": rule.key,
                "title": rule.title,
                "description": rule.description,
                "days": rule.days,
                "value": value.value.unwrap_or(Json::Null),
                "mixed": value.mixed,
            });
            if rule.worktree {
                worktrees.push(row);
            } else {
                artifacts.push(row);
            }
        }
        let mut state = Map::new();
        state.insert("projectScope".into(), json!(project));
        state.insert("status".into(), json!(status));
        if let Some(notice) = notice {
            state.insert("notice".into(), json!(notice));
        }
        if let Some(eligible) = eligible {
            state.insert("eligible".into(), json!(eligible));
        }
        state.insert(
            "mode".into(),
            json!({"value": mode_value, "mixed": mode_reading.mixed}),
        );
        state.insert("worktrees".into(), json!(worktrees));
        state.insert("artifacts".into(), json!(artifacts));
        self.bridge.publish(engine, KEY, Json::Object(state));
    }
}
