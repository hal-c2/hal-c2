//! `projectSettings`, desktop-qt's ProjectSettingsController: Settings →
//! Project. The picked logical project's name and icon, which every checkout
//! in the scope takes (`project.update` on each, in turn), its checkouts and
//! removing them ([`projects::ask_to_remove`] asks first), and how new
//! threads start: the model, permissions, workspace and worktree submodules,
//! as the project's overrides or, with no project picked, the environments'
//! defaults (kept off General, whose page holds only this device's settings).
//!
//! Publishes `projectSettings`: {open, status (pick | empty | missing |
//! checkout-missing | ready), message (what shows instead of the project),
//! name, icon: {label, emoji, custom}, checkouts: [{key, environment, path}]
//! (listed when there are several), note (where its other settings are),
//! removal: {title, description, button}, available (an environment is
//! connected), and each default (model, permissions, workspace, submodules):
//! {value, label, mixed, resettable}, the model's also {automatic, none (no
//! providers), models: [{key, label}], inheritance (while inspected):
//! {layers: [{key, label, value, effective}], overridingProjects:
//! [{projectId, environmentId, title, value}]}}, and the others' {options:
//! [{value, label, description}]}}.
//!
//! Actions (`projectSettings.`): `rename {title}`, `icon {emoji | icon |
//! faviconPath}` (without one, back to automatic), `remove {key}` (one
//! checkout, else every checkout in the scope), `model {key}` ("" for
//! automatic), `permissions {value}`, `workspace {value}`, `submodules
//! {value}`, `reset {key}` (model | permissions | workspace | submodules),
//! `inspect {key}` ("model" shows where the default model comes from,
//! anything else hides it), `clearOverride {environmentId, projectId}` (a
//! project's model override, from the environment's view).

use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::projects;
use crate::controllers::settings::Map;
use crate::controllers::settings_scope::SettingsScope;
use crate::controllers::sidebar;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;
use crate::mc::Mc;
use crate::settings_page;
use crate::sidebar_model::Project;
use crate::store;

const KEY: &str = "projectSettings";
const SECTION: &str = "/settings/projects";
const MODEL: &str = "defaultModelSelection";

struct Pick {
    value: &'static str,
    label: &'static str,
    description: &'static str,
}

/// A default a row edits: its settings key, its choices, and what applies
/// when the environment leaves it unset (null for the file-backed ones).
struct Choice {
    name: &'static str,
    key: &'static str,
    built_in: &'static str,
    options: &'static [Pick],
}

const CHOICES: &[Choice] = &[
    Choice {
        name: "permissions",
        key: "defaultRuntimeMode",
        built_in: "full-access",
        options: &[
            Pick {
                value: "approval-required",
                label: "Supervised",
                description: "Ask before commands and file changes.",
            },
            Pick {
                value: "auto-accept-edits",
                label: "Auto-accept edits",
                description: "Auto-approve edits, ask before other actions.",
            },
            Pick {
                value: "auto",
                label: "Auto",
                description: "Supported providers approve routine actions; others still ask.",
            },
            Pick {
                value: "full-access",
                label: "Full access",
                description: "Allow commands and edits without prompts.",
            },
        ],
    },
    Choice {
        name: "workspace",
        key: "defaultThreadEnvMode",
        built_in: "local",
        options: &[
            Pick {
                value: "local",
                label: "Current checkout",
                description: "",
            },
            Pick {
                value: "worktree",
                label: "New worktree",
                description: "",
            },
        ],
    },
    Choice {
        name: "submodules",
        key: "worktreeSubmodules",
        built_in: "recursive",
        options: &[
            Pick {
                value: "recursive",
                label: "Recursive",
                description: "",
            },
            Pick {
                value: "top-level",
                label: "Top level only",
                description: "",
            },
            Pick {
                value: "none",
                label: "Skip",
                description: "",
            },
        ],
    },
];

fn choice(name: &str) -> Option<&'static Choice> {
    CHOICES.iter().find(|c| c.name == name)
}

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    settings_page::text(object, key)
}

/// The project's value of `key` (its override), else the environment's.
fn effective(settings: &Map, project_id: &str, key: &str) -> Option<Json> {
    if !project_id.is_empty()
        && let Some(own) = SettingsScope::override_of(settings, project_id, key)
    {
        return Some(own);
    }
    settings.get(key).cloned()
}

fn key_of(selection: &Json) -> String {
    match selection.as_object() {
        Some(o) if !o.is_empty() => format!(
            "{}:{}",
            text(selection, "instanceId"),
            text(selection, "model")
        ),
        _ => String::new(),
    }
}

fn provider_name(entry: &Json) -> &str {
    match text(entry, "displayName") {
        "" => text(entry, "instanceId"),
        name => name,
    }
}

/// The providers a new thread can start with.
fn usable(providers: Vec<Json>) -> Vec<Json> {
    providers
        .into_iter()
        .filter(|p| {
            p.get("enabled").and_then(Json::as_bool).unwrap_or(true)
                && p.get("installed").and_then(Json::as_bool).unwrap_or(true)
                && text(p, "availability") != "unavailable"
        })
        .collect()
}

fn offers(providers: Vec<Json>, instance_id: &str, model: &str) -> bool {
    usable(providers).iter().any(|p| {
        text(p, "instanceId") == instance_id
            && p.get("models")
                .and_then(Json::as_array)
                .is_some_and(|models| models.iter().any(|m| text(m, "slug") == model))
    })
}

/// What the icon row says: the chosen icon, the chosen file, or Automatic.
fn icon_label(row: &Json) -> String {
    let icon = row.get("projectIcon").cloned().unwrap_or(Json::Null);
    let monogram = match text(&icon, "monogramText") {
        "" => text(&icon, "text"),
        shown => shown,
    };
    if text(&icon, "kind") == "emoji" {
        return text(&icon, "emoji").to_owned();
    }
    if !monogram.is_empty() {
        return format!("{monogram} · {}", text(&icon, "color"));
    }
    if text(&icon, "kind") == "lucide" {
        return format!("{} · {}", text(&icon, "name"), text(&icon, "color"));
    }
    match text(row, "faviconPath") {
        "" => "Automatic".to_owned(),
        path => path.to_owned(),
    }
}

/// What the removal button reads and asks, from how many of the project's
/// checkouts lie in the scope (`count`) and whether others lie outside it.
fn removal(others: bool, count: usize) -> Json {
    if others {
        return json!({
            "title": "Remove checkout",
            "description": "Deletes the selected machine's checkout entries and their threads. Other machines and files on disk are not touched.",
            "button": "Remove checkout",
        });
    }
    if count > 1 {
        return json!({
            "title": "Remove this project everywhere",
            "description": format!("Deletes all {count} checkout entries and their threads on every machine. Files on disk are not touched."),
            "button": "Remove all entries",
        });
    }
    json!({
        "title": "Remove project",
        "description": "Deletes the project entry and its threads. Files on disk are not touched.",
        "button": "Remove project",
    })
}

pub struct ProjectSettings {
    bridge: Bridge,
    me: Me<ProjectSettings>,
    mc: Rc<dyn Mc>,
    active: bool,
    open: bool,
    /// The default whose inheritance is shown ("model"), or none.
    inspecting: String,
}

impl Controller for ProjectSettings {
    fn new(init: Init<'_, Self>) -> Self {
        ProjectSettings {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            open: false,
            inspecting: String::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let open = settings_page::shows(route, &[SECTION]);
            me.run(engine, |c, engine| {
                if open != c.open {
                    c.open = open;
                    c.publish(engine);
                }
            });
        });
        let me = self.me.clone();
        SettingsScope::of(engine).on_changed(move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
        // Names, icons and checkouts arrive as rows. The sidebar groups them
        // from the same change, so this waits for it.
        let (me, bridge) = (self.me.clone(), self.bridge);
        store::on_changed(engine, move |engine| {
            let me = me.clone();
            bridge.defer(engine, move |engine| {
                me.run(engine, |c, engine| c.publish(engine));
            });
        });
        let me = self.me.clone();
        sidebar::on_grouped(engine, move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
        let route = self.bridge.published(engine, "route").unwrap_or(Json::Null);
        self.open = settings_page::shows(&route, &[SECTION]);
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        let Some(name) = action
            .strip_prefix(KEY)
            .and_then(|rest| rest.strip_prefix('.'))
        else {
            return false;
        };
        if !self.active {
            return false;
        }
        if !self.open {
            return true;
        }
        match name {
            "rename" => self.rename(engine, text(payload, "title").trim()),
            "icon" => self.set_icon(engine, payload),
            "remove" => self.remove(engine, text(payload, "key")),
            "model" => self.set_model(engine, text(payload, "key")),
            "reset" => self.reset(engine, text(payload, "key")),
            "inspect" => {
                // Where a default comes from ("model"); anything else closes it.
                self.inspecting = if text(payload, "key") == "model" {
                    "model".into()
                } else {
                    String::new()
                };
                self.publish(engine);
            }
            "clearOverride" => self.clear_override(engine, payload),
            other => {
                if let Some(choice) = choice(other) {
                    let value = text(payload, "value");
                    if choice.options.iter().any(|o| o.value == value) {
                        self.set(engine, choice.key, Some(Json::from(value)), "");
                    }
                }
            }
        }
        true
    }
}

impl ProjectSettings {
    /// The picked project's checkouts in the scope, and whether others lie
    /// outside it; none when no project is picked or it is gone.
    fn members(&self, engine: &Engine) -> (Vec<Project>, bool) {
        let scope = SettingsScope::of(engine);
        let Some(group) = sidebar::group(engine, &scope.project_key()) else {
            return (Vec::new(), false);
        };
        let environment = scope.environment_filter();
        let result: Vec<Project> = group
            .members
            .iter()
            .filter(|m| environment.is_empty() || m.environment_id == environment)
            .cloned()
            .collect();
        let others = result.len() < group.members.len();
        (result, others)
    }

    fn display_name(&self, engine: &Engine) -> String {
        let scope = SettingsScope::of(engine);
        sidebar::group(engine, &scope.project_key())
            .and_then(|g| {
                g.summary
                    .get("displayName")
                    .and_then(Json::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_default()
    }

    fn rename(&self, engine: &Engine, title: &str) {
        if title.is_empty() {
            controller::with::<Toasts, _>(engine, |toasts, engine| {
                toasts.show(
                    engine,
                    "warning",
                    "Project title cannot be empty",
                    "",
                    None,
                    DEFAULT_TIMEOUT_MS,
                );
            });
            self.publish(engine);
            return;
        }
        let (checkouts, _) = self.members(engine);
        if checkouts.iter().all(|m| m.title == title) {
            return;
        }
        let mut fields = Map::new();
        fields.insert("title".into(), title.into());
        self.update(engine, fields, "Failed to rename project");
    }

    /// An emoji typed here, an icon as the picker made it (IdentityController),
    /// or an image file of the project; none of them is back to automatic.
    fn set_icon(&self, engine: &Engine, payload: &Json) {
        let emoji = text(payload, "emoji").trim();
        let picked = payload
            .get("icon")
            .filter(|icon| icon.as_object().is_some_and(|o| !o.is_empty()));
        let image = text(payload, "faviconPath").trim();
        let icon = match picked {
            Some(icon) => icon.clone(),
            None if emoji.is_empty() => Json::Null,
            None => json!({"kind": "emoji", "emoji": emoji}),
        };
        let mut fields = Map::new();
        fields.insert("projectIcon".into(), icon);
        fields.insert(
            "faviconPath".into(),
            if image.is_empty() {
                Json::Null
            } else {
                image.into()
            },
        );
        self.update(engine, fields, "Failed to update project icon");
    }

    /// A name or icon is each checkout's own field, so it goes to every one;
    /// one on an environment that is not connected stops it before it starts.
    fn update(&self, engine: &Engine, fields: Map, failure_title: &str) {
        let (checkouts, _) = self.members(engine);
        if checkouts.is_empty() {
            return;
        }
        let scope = SettingsScope::of(engine);
        for member in &checkouts {
            if store::with(engine, |s| s.environment_online(&member.environment_id)) {
                continue;
            }
            let description = format!(
                "Connect {} and try again.",
                scope.label(engine, &member.environment_id)
            );
            controller::with::<Toasts, _>(engine, |toasts, engine| {
                toasts.error(engine, failure_title, &description);
            });
            self.publish(engine);
            return;
        }
        let several = checkouts.len() > 1;
        self.send(engine, checkouts, fields, failure_title.to_owned(), several);
    }

    /// `project.update` on the first of `rest`, then on the others in turn.
    fn send(
        &self,
        _engine: &Engine,
        mut rest: Vec<Project>,
        fields: Map,
        failure_title: String,
        several: bool,
    ) {
        if rest.is_empty() {
            return;
        }
        let member = rest.remove(0);
        let mut command = fields.clone();
        command.insert("type".into(), "project.update".into());
        command.insert("projectId".into(), member.id.clone().into());
        let me = self.me.clone();
        let environment_id = member.environment_id.clone();
        self.mc.call(
            &environment_id,
            "projects.mutate",
            Json::Object(command),
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| match result {
                    Err(error) => {
                        // Earlier checkouts took it; say where it stopped.
                        let title = if several {
                            format!(
                                "{failure_title} on {}",
                                SettingsScope::of(engine).label(engine, &member.environment_id)
                            )
                        } else {
                            failure_title
                        };
                        controller::with::<Toasts, _>(engine, |toasts, engine| {
                            toasts.error(engine, &title, &error.message);
                        });
                        c.publish(engine);
                    }
                    Ok(_) => c.send(engine, rest, fields, failure_title, several),
                });
            }),
        );
    }

    fn remove(&self, engine: &Engine, key: &str) {
        let (checkouts, others) = self.members(engine);
        let mut title = self.display_name(engine);
        let mut keys = Vec::new();
        for member in &checkouts {
            if !key.is_empty() && member.key() != key {
                continue;
            }
            keys.push(member.key());
            if !key.is_empty() {
                title = member.title.clone();
            }
        }
        if keys.is_empty() {
            return;
        }
        let whole = keys.len() == checkouts.len();
        let kind = if others || !whole {
            "checkout"
        } else {
            "project"
        };
        projects::ask_to_remove(engine, keys, kind, &title);
    }

    /// Writes `key` for the scope: the project's override, or the
    /// environments' value.
    fn set(&self, engine: &Engine, key: &'static str, value: Option<Json>, failure_title: &str) {
        SettingsScope::of(engine).write(
            engine,
            move |mut settings, project_id| {
                if !project_id.is_empty() {
                    return SettingsScope::with_override(settings, project_id, key, value.clone());
                }
                settings.insert(key.into(), value.clone().unwrap_or(Json::Null));
                settings
            },
            failure_title,
        );
    }

    /// A model every selected environment can start threads with, or
    /// automatic.
    fn set_model(&self, engine: &Engine, key: &str) {
        if key.is_empty() {
            self.set(engine, MODEL, Some(Json::Null), "");
            return;
        }
        let Some((instance_id, model)) = key.split_once(':').filter(|(i, _)| !i.is_empty()) else {
            return;
        };
        let scope = SettingsScope::of(engine);
        for environment in scope.targets() {
            if offers(scope.providers(&environment), instance_id, model) {
                continue;
            }
            let description = format!(
                "This model is unavailable on {}. Select that environment to choose its model separately.",
                scope.label(engine, &environment)
            );
            controller::with::<Toasts, _>(engine, |toasts, engine| {
                toasts.error(engine, "Default model not saved", &description);
            });
            self.publish(engine);
            return;
        }
        self.set(
            engine,
            MODEL,
            Some(json!({"instanceId": instance_id, "model": model})),
            "",
        );
    }

    fn reset(&self, engine: &Engine, name: &str) {
        let (key, value) = if name == "model" {
            (MODEL, Json::Null)
        } else if let Some(choice) = choice(name) {
            // The permissions have a default of their own; the others defer
            // to the checkout's hal-c2.json when unset.
            (
                choice.key,
                if name == "permissions" {
                    choice.built_in.into()
                } else {
                    Json::Null
                },
            )
        } else {
            return;
        };
        SettingsScope::of(engine).write(
            engine,
            move |mut settings, project_id| {
                if !project_id.is_empty() {
                    return SettingsScope::with_override(settings, project_id, key, None);
                }
                settings.insert(key.into(), value.clone());
                settings
            },
            "",
        );
    }

    /// One project's override of the default model, from the environment's
    /// view.
    fn clear_override(&self, engine: &Engine, payload: &Json) {
        let project_id = text(payload, "projectId").to_owned();
        let environment_id = text(payload, "environmentId");
        let scope = SettingsScope::of(engine);
        if project_id.is_empty()
            || scope.project_scope()
            || !scope.targets().iter().any(|t| t == environment_id)
        {
            return;
        }
        let held = scope.settings(environment_id).unwrap_or_default();
        scope.write(
            engine,
            move |settings, _| {
                // Only the environment that holds it.
                if settings != held {
                    return settings;
                }
                SettingsScope::with_override(settings, &project_id, MODEL, None)
            },
            "",
        );
    }

    /// Whether the row has something to reset: a project's override, or an
    /// environment value off its default.
    fn resettable(&self, engine: &Engine, key: &'static str, fallback: Json) -> bool {
        let reading = SettingsScope::of(engine).read(move |settings, project_id| {
            Some(Json::Bool(if !project_id.is_empty() {
                SettingsScope::override_of(settings, project_id, key).is_some()
            } else {
                settings
                    .get(key)
                    .is_some_and(|v| !v.is_null() && *v != fallback)
            }))
        });
        reading.mixed || reading.value == Some(Json::Bool(true))
    }

    fn choice_row(&self, engine: &Engine, choice: &'static Choice) -> Json {
        let scope = SettingsScope::of(engine);
        let targets = scope.targets();
        let reading = scope.read(|settings, project_id| {
            Some(match effective(settings, project_id, choice.key) {
                Some(value) if value.is_string() => value,
                _ => choice.built_in.into(),
            })
        });
        let value = if reading.mixed || targets.is_empty() {
            String::new()
        } else {
            reading
                .value
                .as_ref()
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let mut label = if targets.is_empty() {
            "Unavailable"
        } else {
            "Mixed"
        };
        let options: Vec<Json> = choice
            .options
            .iter()
            .map(|option| {
                if option.value == value {
                    label = option.label;
                }
                json!({"value": option.value, "label": option.label, "description": option.description})
            })
            .collect();
        let fallback = if choice.name == "permissions" {
            choice.built_in.into()
        } else {
            Json::Null
        };
        json!({
            "value": value,
            "label": label,
            "mixed": reading.mixed,
            "resettable": self.resettable(engine, choice.key, fallback),
            "options": options,
        })
    }

    fn model_row(&self, engine: &Engine) -> Json {
        let scope = SettingsScope::of(engine);
        let reading = scope.read(|settings, project_id| {
            Some(match effective(settings, project_id, MODEL) {
                Some(value) if value.is_object() => value,
                _ => Json::Null,
            })
        });
        let targets = scope.targets();
        let key = if reading.mixed {
            String::new()
        } else {
            key_of(reading.value.as_ref().unwrap_or(&Json::Null))
        };
        let mut models: Vec<Json> = Vec::new();
        let mut label = if targets.is_empty() {
            "Unavailable".to_owned()
        } else if reading.mixed {
            "Mixed".to_owned()
        } else {
            "Automatic".to_owned()
        };
        if let Some(first) = targets.first() {
            for entry in usable(scope.providers(first)) {
                let slugs = entry
                    .get("models")
                    .and_then(Json::as_array)
                    .map(Vec::as_slice)
                    .unwrap_or_default();
                for model in slugs {
                    if model
                        .get("isLegacy")
                        .and_then(Json::as_bool)
                        .unwrap_or(false)
                    {
                        continue;
                    }
                    let model_key =
                        format!("{}:{}", text(&entry, "instanceId"), text(model, "slug"));
                    let shown = format!(
                        "{} · {}",
                        provider_name(&entry),
                        match text(model, "name") {
                            "" => text(model, "slug"),
                            name => name,
                        }
                    );
                    if model_key == key {
                        label = shown.clone();
                    }
                    models.push(json!({"key": model_key, "label": shown}));
                }
            }
        }
        // A model no provider offers now still names itself.
        if !key.is_empty() && label == "Automatic" {
            label = format!("{key} (Unavailable)");
        }
        let mut row = json!({
            "value": key,
            "label": label,
            "mixed": reading.mixed,
            "automatic": !reading.mixed && key.is_empty(),
            "none": !targets.is_empty() && models.is_empty(),
            "resettable": self.resettable(engine, MODEL, Json::Null),
            "models": models,
        });
        if self.inspecting == "model"
            && let Some(first) = targets.first()
        {
            row["inheritance"] = self.model_inheritance(engine, first, &models);
        }
        row
    }

    /// Where the first selected environment's default model comes from (the
    /// layers it resolves through, top down, the first one set being in
    /// effect), and from an environment's view, the projects that override
    /// it.
    fn model_inheritance(&self, engine: &Engine, environment_id: &str, models: &[Json]) -> Json {
        let scope = SettingsScope::of(engine);
        let settings = scope.settings(environment_id).unwrap_or_default();
        let named = |value: &Json| {
            let key = key_of(value);
            models
                .iter()
                .find(|m| text(m, "key") == key)
                .map_or(key.clone(), |m| text(m, "label").to_owned())
        };
        let project_id = scope.project_on(environment_id);
        let own = if project_id.is_empty() {
            None
        } else {
            SettingsScope::override_of(&settings, &project_id, MODEL)
        };
        let project_set = own.as_ref().is_some_and(Json::is_object);
        let environment_set = settings.get(MODEL).is_some_and(Json::is_object);
        let inherits = "Inherits";
        let layer = |key: &str, label: &str, value: &str, effective: bool| json!({"key": key, "label": label, "value": value, "effective": effective});
        let mut layers = Vec::new();
        if !project_id.is_empty() {
            let value = match &own {
                Some(own) if project_set => named(own),
                _ => inherits.to_owned(),
            };
            layers.push(layer("project", "Project", &value, project_set));
        }
        let value = match settings.get(MODEL) {
            Some(value) if environment_set => named(value),
            _ => inherits.to_owned(),
        };
        layers.push(layer(
            "environment",
            &scope.label(engine, environment_id),
            &value,
            !project_set && environment_set,
        ));
        // The checkout's hal-c2.json names no model: the layer is there, and
        // inherits.
        if !project_id.is_empty() {
            layers.push(layer("hal-c2.json", "hal-c2.json", inherits, false));
        }
        layers.push(layer(
            "built-in",
            "Default",
            "Automatic",
            !project_set && !environment_set,
        ));
        let mut overriding = Vec::new();
        if project_id.is_empty()
            && let Some(overrides) = settings
                .get("projectSettingsOverrides")
                .and_then(Json::as_object)
        {
            // QJsonObject's order: by key.
            let mut ids: Vec<&String> = overrides.keys().collect();
            ids.sort();
            for id in ids {
                let Some(value) = overrides[id].get(MODEL).filter(|v| v.is_object()) else {
                    continue;
                };
                let title = store::with(engine, |s| {
                    s.project_row(environment_id, id)
                        .and_then(|row| row.get("title"))
                        .and_then(Json::as_str)
                        .map(str::to_owned)
                })
                .filter(|t| !t.is_empty())
                .unwrap_or_else(|| id.clone());
                overriding.push(json!({
                    "projectId": id,
                    "environmentId": environment_id,
                    "title": title,
                    "value": named(value),
                }));
            }
        }
        json!({"layers": layers, "overridingProjects": overriding})
    }

    /// What shows in place of the project, "" when it shows.
    fn status(&self, engine: &Engine, checkouts: &[Project]) -> (&'static str, &'static str) {
        let scope = SettingsScope::of(engine);
        if !scope.project_scope() {
            if sidebar::groups(engine).is_empty() {
                return (
                    "empty",
                    "Add a project from the sidebar to configure it here.",
                );
            }
            return (
                "pick",
                "Choose a project to manage its name, icon, checkouts and actions.",
            );
        }
        if sidebar::group(engine, &scope.project_key()).is_none() {
            return ("missing", "This project is no longer available.");
        }
        if checkouts.is_empty() {
            return (
                "checkout-missing",
                "This checkout is no longer available in the selected project and environment.",
            );
        }
        ("ready", "")
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        if !self.open {
            self.bridge.publish(engine, KEY, json!({"open": false}));
            return;
        }
        let scope = SettingsScope::of(engine);
        let (checkouts, others) = self.members(engine);
        let (state, message) = self.status(engine, &checkouts);
        let mut published = json!({
            "open": true,
            "status": state,
            "message": message,
            "available": !scope.targets().is_empty(),
            "model": self.model_row(engine),
        });
        for choice in CHOICES {
            published[choice.name] = self.choice_row(engine, choice);
        }
        if state == "ready" {
            published["note"] = "Can't find a setting? Keep this project picked above and hop to any other settings page.".into();
            // The icon of the first checkout whose environment is connected.
            let representative = checkouts
                .iter()
                .find(|m| store::with(engine, |s| s.environment_online(&m.environment_id)))
                .unwrap_or(&checkouts[0]);
            let row = Json::Object(
                store::with(engine, |s| {
                    s.project_row(&representative.environment_id, &representative.id)
                        .cloned()
                })
                .unwrap_or_default(),
            );
            let mut custom = false;
            let mut listed = Vec::new();
            for member in &checkouts {
                let own = Json::Object(
                    store::with(engine, |s| {
                        s.project_row(&member.environment_id, &member.id).cloned()
                    })
                    .unwrap_or_default(),
                );
                custom = custom
                    || own.get("projectIcon").is_some_and(|icon| !icon.is_null())
                    || !text(&own, "faviconPath").is_empty();
                listed.push(json!({
                    "key": member.key(),
                    "environment": scope.label(engine, &member.environment_id),
                    "path": member.workspace_root,
                }));
            }
            let icon = row.get("projectIcon").cloned().unwrap_or(Json::Null);
            published["name"] = self.display_name(engine).into();
            published["icon"] = json!({
                "label": icon_label(&row),
                "emoji": text(&icon, "emoji"),
                "custom": custom,
            });
            published["checkouts"] = Json::Array(listed);
            published["removal"] = removal(others, checkouts.len());
        }
        self.bridge.publish(engine, KEY, published);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_icon_row_names_what_is_chosen() {
        let row = |icon: Json, favicon: &str| json!({"projectIcon": icon, "faviconPath": favicon});
        assert_eq!(
            icon_label(&row(json!({"kind": "emoji", "emoji": "x"}), "")),
            "x"
        );
        assert_eq!(
            icon_label(&row(json!({"monogramText": "AB", "color": "red"}), "")),
            "AB · red"
        );
        assert_eq!(
            icon_label(&row(
                json!({"kind": "lucide", "name": "rocket", "color": "blue"}),
                ""
            )),
            "rocket · blue"
        );
        assert_eq!(icon_label(&row(Json::Null, "/a.png")), "/a.png");
        assert_eq!(icon_label(&row(Json::Null, "")), "Automatic");
    }

    #[test]
    fn removal_follows_what_lies_in_the_scope() {
        assert_eq!(removal(true, 1)["button"], "Remove checkout");
        assert_eq!(removal(false, 3)["button"], "Remove all entries");
        assert!(
            removal(false, 3)["description"]
                .as_str()
                .is_some_and(|d| d.contains("all 3 checkout entries"))
        );
        assert_eq!(removal(false, 1)["title"], "Remove project");
    }

    #[test]
    fn a_projects_value_wins_over_the_environments() {
        let settings = json!({
            "defaultRuntimeMode": "auto",
            "projectSettingsOverrides": {"p1": {"defaultRuntimeMode": "full-access"}},
        });
        let Json::Object(settings) = settings else {
            unreachable!()
        };
        assert_eq!(
            effective(&settings, "p1", "defaultRuntimeMode"),
            Some(json!("full-access"))
        );
        assert_eq!(
            effective(&settings, "p2", "defaultRuntimeMode"),
            Some(json!("auto"))
        );
        assert_eq!(
            effective(&settings, "", "defaultRuntimeMode"),
            Some(json!("auto"))
        );
    }

    #[test]
    fn a_model_no_provider_offers_is_not_usable() {
        let providers = vec![
            json!({"instanceId": "a", "models": [{"slug": "m"}]}),
            json!({"instanceId": "b", "enabled": false, "models": [{"slug": "m"}]}),
            json!({"instanceId": "c", "availability": "unavailable", "models": [{"slug": "m"}]}),
        ];
        assert!(offers(providers.clone(), "a", "m"));
        assert!(!offers(providers.clone(), "b", "m"));
        assert!(!offers(providers.clone(), "c", "m"));
        assert!(!offers(providers, "a", "n"));
    }
}
