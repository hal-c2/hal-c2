//! `sourceControlSettings`, desktop-qt's SourceControlSettingsController:
//! Settings → Source Control. The repository defaults, the version control
//! and hosting tools the MC finds (`server.discoverSourceControl`), Git's
//! background fetch interval, and how source control text is written. The
//! settings rows follow the settings scope (`SettingsScope`), a project's as
//! its overrides; discovery scans the scope's first connected environment,
//! which names itself when several are selected.
//!
//! Publishes `sourceControlSettings`: {open, projectScope,
//! discovery: {status: none | loading | ready | error, scanning, message, and
//! what shows instead of the tools (title and detail, "" while they show),
//! suffix (" · <environment>" when several are selected), versionControl and
//! providers: [{kind, label, version, comingSoon, available, enabled,
//! authLabel ("" for a version control tool), authWarning, summary,
//! hasAccount, account (only while revealed), revealed, git}]},
//! fetchInterval: {seconds, preset, custom, mixed, environmentWide},
//! autoPull, templates: {value, mixed, overridden},
//! mergeMethod: {value: last | merge | squash | rebase, mixed, overridden},
//! writingStyle: {mode, mixed, description, instructions, instructionsMixed,
//! dirty, overridden}, writerModel: {available, on, mixed, key, canEnable,
//! overridden, models: [{key, label, reason}]}}.
//!
//! Actions (`sourceControlSettings.`): `scan`, `reveal {kind, revealed}`,
//! `fetchInterval {seconds}`, `resetFetchInterval`, `autoPull {enabled}`,
//! `mergeMethod {method}`, `writingMode {mode}`, `instructions {text}` (with
//! the style mixed, sets custom instructions everywhere), `templates
//! {enabled}`, `writerModel {enabled}`, `pickWriterModel {key}` ("instance:
//! model"), and `reset {key}`: at a project scope the override goes,
//! otherwise the environment default comes back.

use std::collections::{BTreeSet, HashMap};
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::background_activity::{base_of, preset_fetch};
use crate::controllers::settings::Map;
use crate::controllers::settings_scope::SettingsScope;
use crate::controllers::toasts::Toasts;
use crate::environment_settings::Reading;
use crate::json::Json;
use crate::mc::{Mc, McError};
use crate::settings_page;

const KEY: &str = "sourceControlSettings";
const SECTION: &str = "/settings/source-control";
const FETCH: &str = "automaticGitFetchInterval";
const STYLE: &str = "sourceControlWritingStyle";
const WRITER: &str = "sourceControlWriterModelSelection";
const WRITER_TITLE: &str = "Source control writer model not saved";

fn at<'a>(object: &'a Json, key: &str) -> &'a str {
    settings_page::text(object, key)
}

fn flag_or(object: &Json, key: &str, default: bool) -> bool {
    object.get(key).and_then(Json::as_bool).unwrap_or(default)
}

/// An Option from the wire: {_tag: "Some", value} or {_tag: "None"}; a bare
/// value is taken as is.
fn option(value: Option<&Json>) -> String {
    match value {
        Some(object) if object.is_object() => {
            if object.get("_tag").and_then(Json::as_str) == Some("Some") {
                at(object, "value").trim().to_owned()
            } else {
                String::new()
            }
        }
        Some(Json::String(s)) => s.trim().to_owned(),
        _ => String::new(),
    }
}

fn fetch_seconds(settings: &Map) -> i64 {
    let activity = settings
        .get("backgroundActivity")
        .and_then(Json::as_object)
        .cloned()
        .unwrap_or_default();
    let overrides = activity
        .get("overrides")
        .and_then(Json::as_object)
        .cloned()
        .unwrap_or_default();
    if activity.get("profile").and_then(Json::as_str) == Some("custom")
        && let Some(ms) = overrides.get(FETCH).and_then(Json::as_f64)
    {
        return (ms / 1000.0).round() as i64;
    }
    preset_fetch(base_of(&activity))
}

/// A custom profile on the current base, keeping a custom profile's other
/// overrides.
fn with_fetch_seconds(mut settings: Map, seconds: Option<i64>) -> Map {
    let activity = settings
        .get("backgroundActivity")
        .and_then(Json::as_object)
        .cloned()
        .unwrap_or_default();
    let mut overrides = if activity.get("profile").and_then(Json::as_str) == Some("custom") {
        activity
            .get("overrides")
            .and_then(Json::as_object)
            .cloned()
            .unwrap_or_default()
    } else {
        Map::new()
    };
    match seconds {
        Some(seconds) => {
            overrides.insert(FETCH.into(), json!(seconds * 1000));
        }
        None => {
            overrides.remove(FETCH);
        }
    }
    settings.insert(
        "backgroundActivity".into(),
        json!({
            "schemaVersion": 1,
            "profile": "custom",
            "baseProfile": base_of(&activity),
            "overrides": overrides,
        }),
    );
    settings
}

/// The defaults a document leaves out (ServerSettings).
fn fallback(key: &str) -> Json {
    match key {
        "defaultAutoPull" => json!(false),
        STYLE => json!({
            "mode": "repo_conventions",
            "customInstructions": "",
            "followChangeRequestTemplates": true,
        }),
        _ => Json::Null,
    }
}

/// A key's value for the project (its override), or the environment's.
fn effective(settings: &Map, project_id: &str, key: &str) -> Json {
    let mut value = settings.get(key).cloned();
    if !project_id.is_empty()
        && let Some(own) = SettingsScope::override_of(settings, project_id, key)
    {
        value = Some(own);
    }
    if key == STYLE {
        let mut style = fallback(STYLE).as_object().cloned().unwrap_or_default();
        if let Some(set) = value.as_ref().and_then(Json::as_object) {
            for (k, v) in set {
                style.insert(k.clone(), v.clone());
            }
        }
        return Json::Object(style);
    }
    match value {
        None | Some(Json::Null) => fallback(key),
        Some(value) => value,
    }
}

struct Mode {
    id: &'static str,
    description: &'static str,
}

const MODES: [Mode; 3] = [
    Mode {
        id: "repo_conventions",
        description: "In each project, matches recent change descriptions and change request titles.",
    },
    Mode {
        id: "conventional_commits",
        description: "Use Conventional Commit prefixes and keep change request text concise.",
    },
    Mode {
        id: "custom",
        description: "Use your instructions for change descriptions and change requests in every project.",
    },
];

fn provider_name(entry: &Json) -> &str {
    match at(entry, "displayName") {
        "" => at(entry, "instanceId"),
        name => name,
    }
}

/// Why a provider's models cannot write source control text, "" when they
/// can.
fn provider_problem(entry: &Json) -> String {
    let name = provider_name(entry);
    if !flag_or(entry, "enabled", true) {
        return format!("{name} is turned off.");
    }
    if !flag_or(entry, "installed", true) || at(entry, "availability") == "unavailable" {
        return format!("{name} is not available.");
    }
    if entry
        .get("auth")
        .is_some_and(|auth| at(auth, "status") == "unauthenticated")
    {
        return format!("{name} is not signed in.");
    }
    String::new()
}

fn key_of(selection: &Json) -> String {
    match selection.as_object() {
        Some(o) if !o.is_empty() => {
            format!("{}:{}", at(selection, "instanceId"), at(selection, "model"))
        }
        _ => String::new(),
    }
}

fn models_of(entry: &Json) -> &[Json] {
    entry
        .get("models")
        .and_then(Json::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
}

#[derive(Default)]
struct Discovery {
    result: Json,
    error: String,
    loaded: bool,
    scanning: bool,
    seq: u64,
}

pub struct SourceControlSettings {
    bridge: Bridge,
    me: Me<SourceControlSettings>,
    mc: Rc<dyn Mc>,
    active: bool,
    open: bool,
    discovery: HashMap<String, Discovery>,
    /// Environments scanned since the section opened.
    scanned: BTreeSet<String>,
    /// The hosts whose signed-in account is shown.
    revealed: BTreeSet<String>,
}

impl Controller for SourceControlSettings {
    fn new(init: Init<'_, Self>) -> Self {
        SourceControlSettings {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            open: false,
            discovery: HashMap::new(),
            scanned: BTreeSet::new(),
            revealed: BTreeSet::new(),
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
                if open == c.open {
                    return;
                }
                c.open = open;
                c.scanned.clear();
                c.follow(engine);
            });
        });
        let me = self.me.clone();
        SettingsScope::of(engine).on_changed(move |engine| {
            me.run(engine, |c, engine| c.follow(engine));
        });
        let route = self.bridge.published(engine, "route").unwrap_or(Json::Null);
        if settings_page::shows(&route, &[SECTION]) {
            self.open = true;
            self.follow(engine);
        } else {
            self.publish(engine);
        }
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        let Some(name) = action
            .strip_prefix(KEY)
            .and_then(|rest| rest.strip_prefix('.'))
            .filter(|_| self.active)
        else {
            return false;
        };
        let scope = SettingsScope::of(engine);
        match name {
            "scan" => self.scan(engine),
            "reveal" => {
                let kind = settings_page::text(payload, "kind").to_owned();
                if settings_page::flag(payload.get("revealed")) {
                    self.revealed.insert(kind);
                } else {
                    self.revealed.remove(&kind);
                }
                self.publish(engine);
            }
            "fetchInterval" | "resetFetchInterval" => {
                // Background activity is the environment's; a project cannot
                // override it.
                if scope.project_scope() {
                    return true;
                }
                let seconds = (name == "fetchInterval")
                    .then(|| settings_page::int(payload.get("seconds")).max(0));
                scope.write(
                    engine,
                    move |settings, _| with_fetch_seconds(settings, seconds),
                    "",
                );
            }
            "autoPull" => {
                let enabled = settings_page::flag(payload.get("enabled"));
                self.set(engine, "defaultAutoPull", move |_| json!(enabled), "");
            }
            "mergeMethod" => {
                let method = settings_page::text(payload, "method").to_owned();
                let known = matches!(method.as_str(), "merge" | "squash" | "rebase");
                self.set(
                    engine,
                    "pullRequestMergeMethod",
                    move |_| if known { json!(method) } else { Json::Null },
                    "",
                );
            }
            "writingMode" => {
                let mode = settings_page::text(payload, "mode").to_owned();
                if !MODES.iter().any(|m| m.id == mode) {
                    return true;
                }
                self.set_style(engine, json!({"mode": mode}));
            }
            "instructions" => {
                let text = settings_page::text(payload, "text").trim().to_owned();
                let reading = scope.read(|settings, project_id| {
                    let style = effective(settings, project_id, STYLE);
                    Some(json!([style.get("mode"), style.get("customInstructions")]))
                });
                // Instructions for all: the one style every selected
                // environment takes.
                let mut patch = json!({"customInstructions": text});
                if reading.mixed {
                    patch["mode"] = json!("custom");
                }
                self.set_style(engine, patch);
            }
            "templates" => {
                let enabled = settings_page::flag(payload.get("enabled"));
                self.set_style(engine, json!({"followChangeRequestTemplates": enabled}));
            }
            "writerModel" => {
                if !settings_page::flag(payload.get("enabled")) {
                    self.set(engine, WRITER, |_| Json::Null, "");
                } else {
                    let key = self.default_writer(engine);
                    if !key.is_empty() {
                        self.pick_writer(engine, &key);
                    }
                }
            }
            "pickWriterModel" => self.pick_writer(engine, settings_page::text(payload, "key")),
            "reset" => self.reset(engine, settings_page::text(payload, "key")),
            _ => {}
        }
        true
    }
}

impl SourceControlSettings {
    /// The environment discovery scans: the scope's first connected one.
    fn scanned_environment(&self, engine: &Engine) -> String {
        SettingsScope::of(engine)
            .targets()
            .into_iter()
            .next()
            .unwrap_or_default()
    }

    fn follow(&mut self, engine: &Engine) {
        let environment = self.scanned_environment(engine);
        if self.open && !environment.is_empty() && !self.scanned.contains(&environment) {
            self.scan(engine);
        }
        self.publish(engine);
    }

    fn scan(&mut self, engine: &Engine) {
        let environment = self.scanned_environment(engine);
        if !self.open || environment.is_empty() {
            return;
        }
        self.scanned.insert(environment.clone());
        let discovery = self.discovery.entry(environment.clone()).or_default();
        discovery.scanning = true;
        discovery.seq += 1;
        let seq = discovery.seq;
        let me = self.me.clone();
        let id = environment.clone();
        self.mc.call(
            &environment,
            "server.discoverSourceControl",
            json!({}),
            Box::new(move |engine: &Engine, result: Result<Json, McError>| {
                me.run(engine, |c, engine| {
                    let discovery = c.discovery.entry(id).or_default();
                    if discovery.seq != seq {
                        return;
                    }
                    discovery.scanning = false;
                    // A failed scan says so rather than showing what an
                    // older one found.
                    match result {
                        Err(e) => {
                            discovery.error = if e.message.is_empty() {
                                "The scan failed.".into()
                            } else {
                                e.message
                            };
                            discovery.result = Json::Null;
                            discovery.loaded = false;
                        }
                        Ok(result) => {
                            discovery.error.clear();
                            discovery.result = result;
                            discovery.loaded = true;
                        }
                    }
                    c.publish(engine);
                });
            }),
        );
        self.publish(engine);
    }

    /// Writes `key` for the scope: a project's override, or the
    /// environment's value.
    fn set(
        &self,
        engine: &Engine,
        key: &str,
        next: impl Fn(&Json) -> Json + 'static,
        failure_title: &str,
    ) {
        let key = key.to_owned();
        SettingsScope::of(engine).write(
            engine,
            move |mut settings, project_id| {
                let value = next(&effective(&settings, project_id, &key));
                if !project_id.is_empty() {
                    return SettingsScope::with_override(settings, project_id, &key, Some(value));
                }
                settings.insert(key.clone(), value);
                settings
            },
            failure_title,
        );
    }

    /// The writing style is one object; a change keeps its other fields as
    /// each environment (or project) has them.
    fn set_style(&self, engine: &Engine, patch: Json) {
        self.set(
            engine,
            STYLE,
            move |current| {
                let mut style = current.as_object().cloned().unwrap_or_default();
                if let Some(patch) = patch.as_object() {
                    for (k, v) in patch {
                        style.insert(k.clone(), v.clone());
                    }
                }
                Json::Object(style)
            },
            "",
        );
    }

    fn reset(&self, engine: &Engine, key: &str) {
        let known = [
            "defaultAutoPull",
            "pullRequestMergeMethod",
            STYLE,
            "followChangeRequestTemplates",
            WRITER,
        ];
        if !known.contains(&key) {
            return;
        }
        let key = key.to_owned();
        SettingsScope::of(engine).write(
            engine,
            move |mut settings, project_id| {
                let templates = key == "followChangeRequestTemplates";
                if !project_id.is_empty() {
                    // Templates live in the style object; the override goes
                    // with it.
                    let target = if templates { STYLE } else { key.as_str() };
                    return SettingsScope::with_override(settings, project_id, target, None);
                }
                if key == STYLE || templates {
                    let mut style = effective(&settings, "", STYLE)
                        .as_object()
                        .cloned()
                        .unwrap_or_default();
                    let defaults = fallback(STYLE);
                    let fields: &[&str] = if key == STYLE {
                        &["mode", "customInstructions"]
                    } else {
                        &["followChangeRequestTemplates"]
                    };
                    for field in fields {
                        style.insert(
                            (*field).to_owned(),
                            defaults.get(*field).cloned().unwrap_or(Json::Null),
                        );
                    }
                    settings.insert(STYLE.into(), Json::Object(style));
                } else {
                    settings.insert(key.clone(), fallback(&key));
                }
                settings
            },
            "",
        );
    }

    /// The providers of the first target that can write text.
    fn writers(&self, engine: &Engine) -> Vec<Json> {
        SettingsScope::of(engine)
            .providers(&self.scanned_environment(engine))
            .into_iter()
            .filter(|p| p.get("supportsTextGeneration") != Some(&Json::Bool(false)))
            .collect()
    }

    /// What a model cannot be picked for across the scope, "" when it can:
    /// every target must offer it from a usable provider.
    fn writer_problem(&self, engine: &Engine, key: &str) -> String {
        let Some((instance_id, slug)) = key.split_once(':').filter(|(i, _)| !i.is_empty()) else {
            return "Choose a model.".into();
        };
        let scope = SettingsScope::of(engine);
        let first = self.scanned_environment(engine);
        for environment in scope.targets() {
            let mut offered = false;
            for entry in scope.providers(&environment) {
                if at(&entry, "instanceId") != instance_id {
                    continue;
                }
                let problem = provider_problem(&entry);
                if !problem.is_empty() {
                    return if environment == first {
                        problem
                    } else {
                        unavailable_on(engine, &environment)
                    };
                }
                offered = offered || models_of(&entry).iter().any(|m| at(m, "slug") == slug);
            }
            if !offered {
                return unavailable_on(engine, &environment);
            }
        }
        String::new()
    }

    fn pick_writer(&self, engine: &Engine, key: &str) {
        let problem = self.writer_problem(engine, key);
        if !problem.is_empty() {
            controller::with::<Toasts, _>(engine, |toasts, engine| {
                toasts.error(engine, WRITER_TITLE, &problem);
            });
            return;
        }
        let (instance_id, model) = key.split_once(':').unwrap_or_default();
        let selection = json!({"instanceId": instance_id, "model": model});
        self.set(engine, WRITER, move |_| selection.clone(), WRITER_TITLE);
    }

    /// Turning the writer model on starts from the text generation model, or
    /// the first provider's default.
    fn default_writer(&self, engine: &Engine) -> String {
        let settings = SettingsScope::of(engine)
            .settings(&self.scanned_environment(engine))
            .unwrap_or_default();
        let configured = settings
            .get("textGenerationModelSelection")
            .map(key_of)
            .unwrap_or_default();
        if !configured.is_empty() && self.writer_problem(engine, &configured).is_empty() {
            return configured;
        }
        let mut first = String::new();
        for entry in self.writers(engine) {
            if !provider_problem(&entry).is_empty() {
                continue;
            }
            for model in models_of(&entry) {
                let key = format!("{}:{}", at(&entry, "instanceId"), at(model, "slug"));
                if flag_or(model, "isDefault", false) {
                    return key;
                }
                if first.is_empty() {
                    first = key;
                }
            }
        }
        first
    }

    fn item(&self, item: &Json, provider: bool) -> Json {
        let kind = at(item, "kind");
        let label = at(item, "label");
        let hint = at(item, "installHint");
        let available = at(item, "status") == "available";
        let coming_soon = !provider && !flag_or(item, "implemented", true);
        let auth = item.get("auth").cloned().unwrap_or(Json::Null);
        let auth_status = at(&auth, "status");
        let account = option(auth.get("account"));
        let auth_label = if !provider {
            ""
        } else {
            match auth_status {
                "authenticated" => "Authenticated",
                "unauthenticated" => "Not authenticated",
                _ => "Status unknown",
            }
        };
        let summary = if coming_soon {
            format!("Support for {label} is coming soon.")
        } else if !available {
            format!("Not available on this server: {hint}")
        } else if provider && auth_status == "authenticated" {
            "Authenticated".to_owned()
        } else if provider && at(item, "executable").is_empty() {
            format!("Available. {hint}")
        } else if provider && auth_status == "unauthenticated" {
            format!(
                "{label} is not authenticated on this server. Sign in or configure credentials using the {} tool on the server host to enable change request features.",
                at(item, "executable")
            )
        } else if provider {
            let detail = option(auth.get("detail"));
            let shown = if detail.is_empty() {
                hint
            } else {
                detail.as_str()
            };
            format!("Could not verify {label}. {shown}")
        } else {
            "Available".to_owned()
        };
        let shown = available && auth_status == "authenticated" && !account.is_empty();
        let revealed = shown && self.revealed.contains(kind);
        json!({
            "kind": kind,
            "label": label,
            "version": option(item.get("version")),
            "comingSoon": coming_soon,
            "available": available,
            "enabled": if provider { available && auth_status == "authenticated" } else { available && !coming_soon },
            "authLabel": auth_label,
            "authWarning": provider && auth_status == "unauthenticated",
            "summary": summary,
            "hasAccount": shown,
            "revealed": revealed,
            "account": if revealed { account } else { String::new() },
            "git": !provider && kind == "git",
        })
    }

    fn discovery_state(&self, engine: &Engine) -> Json {
        let environment = self.scanned_environment(engine);
        if environment.is_empty() {
            return json!({
                "status": "none",
                "title": "Connect an environment to inspect its version control tools and hosting integrations.",
            });
        }
        let none = Discovery::default();
        let discovery = self.discovery.get(&environment).unwrap_or(&none);
        let list = |key: &str, provider: bool| -> Vec<Json> {
            discovery
                .result
                .get(key)
                .and_then(Json::as_array)
                .map(|items| items.iter().map(|i| self.item(i, provider)).collect())
                .unwrap_or_default()
        };
        let version_control = list("versionControlSystems", false);
        let providers = list("sourceControlProviders", true);
        let status = if discovery.loaded {
            "ready"
        } else if discovery.error.is_empty() {
            "loading"
        } else {
            "error"
        };
        // What shows instead of the tools, when they do not.
        let (title, detail) = match status {
            "loading" => ("Scanning the server environment…", discovery.error.as_str()),
            "error" => (
                "Could not scan the server environment",
                discovery.error.as_str(),
            ),
            _ if version_control.is_empty() && providers.is_empty() => (
                "Nothing detected yet",
                "Install Git on the server, add optional hosting integrations or credentials your workspace needs, then rescan.",
            ),
            _ => ("", ""),
        };
        let detail = if status == "loading" { "" } else { detail };
        let scope = SettingsScope::of(engine);
        json!({
            "status": status,
            "title": title,
            "detail": detail,
            "scanning": discovery.scanning,
            "message": discovery.error,
            "suffix": if scope.targets().len() > 1 {
                format!(" · {}", scope.label(engine, &environment))
            } else {
                String::new()
            },
            "versionControl": version_control,
            "providers": providers,
        })
    }

    /// Whether the project scope's checkouts override `key`.
    fn overridden(&self, engine: &Engine, key: &str) -> bool {
        let scope = SettingsScope::of(engine);
        if !scope.project_scope() {
            return false;
        }
        let key = key.to_owned();
        let reading = scope.read(move |settings, project_id| {
            Some(json!(
                SettingsScope::override_of(settings, project_id, &key).is_some()
            ))
        });
        reading.mixed || reading.value.and_then(|v| v.as_bool()).unwrap_or(false)
    }

    fn row(&self, engine: &Engine, key: &str) -> Json {
        let scope = SettingsScope::of(engine);
        let owned = key.to_owned();
        let reading =
            scope.read(move |settings, project_id| Some(effective(settings, project_id, &owned)));
        json!({
            "value": reading.value.unwrap_or_else(|| fallback(key)),
            "mixed": reading.mixed,
            "overridden": self.overridden(engine, key),
        })
    }

    fn style_field(&self, engine: &Engine, field: &'static str) -> Reading {
        SettingsScope::of(engine).read(move |settings, project_id| {
            effective(settings, project_id, STYLE).get(field).cloned()
        })
    }

    fn writer_model(&self, engine: &Engine) -> Json {
        let scope = SettingsScope::of(engine);
        let reading =
            scope.read(|settings, project_id| Some(effective(settings, project_id, WRITER)));
        let key = key_of(reading.value.as_ref().unwrap_or(&Json::Null));
        let mut models = Vec::new();
        let mut kept = key.is_empty();
        for entry in self.writers(engine) {
            for slug in models_of(&entry) {
                if flag_or(slug, "isLegacy", false) {
                    continue;
                }
                let model_key = format!("{}:{}", at(&entry, "instanceId"), at(slug, "slug"));
                let name = match at(slug, "name") {
                    "" => at(slug, "slug"),
                    name => name,
                };
                models.push(json!({
                    "key": model_key,
                    "label": format!("{} · {name}", provider_name(&entry)),
                    "reason": self.writer_problem(engine, &model_key),
                }));
                kept = kept || model_key == key;
            }
        }
        if !kept {
            models.push(json!({
                "key": key,
                "label": format!("{key} (Unavailable)"),
                "reason": self.writer_problem(engine, &key),
            }));
        }
        json!({
            "available": !scope.targets().is_empty(),
            "on": reading.mixed || !key.is_empty(),
            "mixed": reading.mixed,
            "key": if reading.mixed { String::new() } else { key },
            "canEnable": !self.default_writer(engine).is_empty(),
            "overridden": self.overridden(engine, WRITER),
            "models": models,
        })
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
        let project = scope.project_scope();
        let fetch = scope.read(|settings, _| Some(json!(fetch_seconds(settings))));
        let preset = scope.read(|settings, _| {
            let activity = settings
                .get("backgroundActivity")
                .and_then(Json::as_object)
                .cloned()
                .unwrap_or_default();
            Some(json!(preset_fetch(base_of(&activity))))
        });
        let seconds = fetch.value.as_ref().and_then(Json::as_i64).unwrap_or(30);
        let preset_seconds = preset.value.as_ref().and_then(Json::as_i64).unwrap_or(30);

        let mut merge = self.row(engine, "pullRequestMergeMethod");
        if merge["value"].is_null() {
            merge["value"] = json!("last");
        }

        let mode = self.style_field(engine, "mode");
        let instructions = self.style_field(engine, "customInstructions");
        let templates = self.style_field(engine, "followChangeRequestTemplates");
        let mode_id = mode
            .value
            .as_ref()
            .and_then(Json::as_str)
            .unwrap_or("repo_conventions")
            .to_owned();
        let description = MODES
            .iter()
            .find(|m| m.id == mode_id)
            .map_or("", |m| m.description);
        let instruction_text = instructions
            .value
            .as_ref()
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned();
        let style_mixed = mode.mixed || instructions.mixed;
        let style_overridden = self.overridden(engine, STYLE);

        self.bridge.publish(
            engine,
            KEY,
            json!({
                "open": true,
                "projectScope": project,
                "discovery": self.discovery_state(engine),
                "fetchInterval": {
                    "seconds": seconds,
                    "preset": preset_seconds,
                    "custom": fetch.mixed || preset.mixed || seconds != preset_seconds,
                    "mixed": fetch.mixed,
                    "environmentWide": project,
                },
                "autoPull": self.row(engine, "defaultAutoPull"),
                "mergeMethod": merge,
                "writingStyle": {
                    "mode": if mode.mixed { String::new() } else { mode_id.clone() },
                    "mixed": style_mixed,
                    "description": description,
                    "instructions": instruction_text,
                    "instructionsMixed": instructions.mixed,
                    "dirty": style_mixed
                        || mode_id != "repo_conventions"
                        || !instruction_text.is_empty()
                        || style_overridden,
                    "overridden": style_overridden,
                },
                "templates": {
                    "value": templates.value.as_ref().and_then(Json::as_bool).unwrap_or(true),
                    "mixed": templates.mixed,
                    "overridden": style_overridden,
                },
                "writerModel": self.writer_model(engine),
            }),
        );
    }
}

fn unavailable_on(engine: &Engine, environment: &str) -> String {
    format!(
        "This model is unavailable on {}. Select that environment to choose its model separately.",
        SettingsScope::of(engine).label(engine, environment)
    )
}
