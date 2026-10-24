//! `providerSettings`, desktop-qt's ProviderSettingsController: Settings →
//! Providers. One environment's providers at a time (this machine unless
//! another is chosen), as its `config` shape lists them, with each one's
//! sign-in, models, version advisory and configuration, the add-provider
//! wizard ([`instances`], [`registry`]), a registry agent's sessions and model
//! providers ([`acp`]) and a runtime the MC installs itself ([`runtime`]).
//! Settings writes go to the shown environment through `EnvironmentSettings`;
//! nothing is followed while the section is closed.
//!
//! Publishes `providerSettings`: {open, environmentId, environments [{id,
//! label, local, online}], status (none | offline | loading | ready), title,
//! description, refreshing, checkedAt (ISO, "" for never), providers [entry],
//! health (null | {seconds, defaultSeconds, step}), hubs (null | [{id, label,
//! description}]), wizard (null | see [`instances`])}.
//!
//! An entry: {instanceId, driver, name, version, enabled, installed, status,
//! headline, detail, email, models [{slug, name, labels, favorite, hidden}],
//! modelCount, modelSummary, modelFilter, advisory (null | {title, detail,
//! updateCommand, targetVersion, strong}), canUpdate, installLabel, updating,
//! account (null | {description, canSignIn, signInLabel, canCancel,
//! canSignOut, url, userCode, error, methods [{id, name}], terminal (null |
//! {key, output, offset}), credentials [{name, label, secret}],
//! acceptsCallback, docsUrl}), urlAuth (null | {message, url}), acp, runtime,
//! and the configuration [`instances`] adds.
//!
//! Actions: `providerSettings.environment {id}`, `.refresh`, `.enable
//! {instanceId, enabled}`, `.filterModels {instanceId, query}`, `.modelHidden
//! {instanceId, slug, hidden}`, `.modelMove {instanceId, slug, by}` (this
//! device's picker), `.healthInterval {seconds}`, `.resetHealthInterval`,
//! `.addHub {url, key, label}`, `.removeHub {id}`; sign-in: `.signIn
//! {instanceId, methodId?}`, `.signInTerminal {instanceId, data, columns?,
//! rows?}`, `.signInCredentials {instanceId, values}`, `.signInCallback
//! {instanceId, url}`, `.copySignInLink`, `.openSignIn`, `.cancelSignIn`,
//! `.openDocs`, `.continueUrlAuth`, `.signOut` (asks first); versions:
//! `.update`, `.install` (the recommended version), `.copyUpdateCommand`; and
//! those of the submodules.

mod acp;
mod instances;
mod registry;
mod runtime;

use std::cell::RefCell;
use std::collections::{HashMap, HashSet, VecDeque};
use std::rc::Rc;

use chrono::{DateTime, Local, NaiveDateTime, Utc};
use ljos::prelude::Engine;
use serde_json::{Map, json};

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me, Window};
use crate::controllers::menus::{Answer, Menus};
use crate::controllers::navigation::{Navigation, PROVIDERS_SECTION, Route, at_section};
use crate::controllers::settings::Settings;
use crate::controllers::terminals;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::environment_settings::{EnvironmentSettings, Outcome};
use crate::json::Json;
use crate::mc::{Frame, Mc, McError, SubId};
use crate::provider::drivers;
use crate::store;

const KEY: &str = "providerSettings";
const REGISTRY: &str = "acpRegistry";
const HEALTH_KEY: &str = "providerHealthRefreshInterval";
const SIGN_IN_FAILED: &str = "Provider sign-in failed. Try again.";

static NULL: Json = Json::Null;

// ---- JSON as the C++ reads it ------------------------------------------

/// `value[key]`, or null.
fn at<'a>(value: &'a Json, key: &str) -> &'a Json {
    value.get(key).unwrap_or(&NULL)
}

/// The string at `key`, "" for anything else (QJsonValue::toString).
fn str_at<'a>(value: &'a Json, key: &str) -> &'a str {
    at(value, key).as_str().unwrap_or_default()
}

/// The string at `key`, trimmed.
fn text(value: &Json, key: &str) -> String {
    str_at(value, key).trim().to_owned()
}

fn bool_at(value: &Json, key: &str) -> bool {
    at(value, key).as_bool().unwrap_or(false)
}

/// The array at `key`, empty for anything else.
fn array_at<'a>(value: &'a Json, key: &str) -> &'a [Json] {
    at(value, key)
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
}

/// No object, or an empty one (QJsonObject::isEmpty after toObject).
fn empty(value: &Json) -> bool {
    value.as_object().is_none_or(Map::is_empty)
}

/// The object at `key`, or an empty one.
fn object_at(value: &Json, key: &str) -> Map<String, Json> {
    at(value, key).as_object().cloned().unwrap_or_default()
}

/// A number as QVariant(double).toString writes it.
fn number_text(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 {
        format!("{}", n as i64)
    } else {
        format!("{n}")
    }
}

/// A payload value as QVariant::toString reads it.
fn input_string(payload: &Json, key: &str) -> String {
    match at(payload, key) {
        Json::String(s) => s.clone(),
        Json::Number(n) => n.as_f64().map(number_text).unwrap_or_default(),
        Json::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

/// A payload value as QVariant::toBool reads it.
fn input_bool(payload: &Json, key: &str) -> bool {
    match at(payload, key) {
        Json::Bool(b) => *b,
        Json::Number(n) => n.as_f64().is_some_and(|n| n != 0.0),
        Json::String(s) => !s.is_empty() && s != "0" && !s.eq_ignore_ascii_case("false"),
        _ => false,
    }
}

/// A payload value as QVariant::toDouble reads it.
fn input_number(payload: &Json, key: &str) -> f64 {
    match at(payload, key) {
        Json::Number(n) => n.as_f64().unwrap_or(0.0),
        Json::String(s) => s.trim().parse().unwrap_or(0.0),
        Json::Bool(b) => f64::from(u8::from(*b)),
        _ => 0.0,
    }
}

/// A payload value as QVariant::toInt reads it (rounded).
fn input_int(payload: &Json, key: &str) -> i64 {
    let n = input_number(payload, key).round();
    if n.is_finite() {
        n.clamp(i32::MIN as f64, i32::MAX as f64) as i64
    } else {
        0
    }
}

fn has(payload: &Json, key: &str) -> bool {
    payload.get(key).is_some()
}

/// A URL's scheme in lower case, "" without one.
fn scheme(url: &str) -> String {
    let Some((scheme, _)) = url.split_once(':') else {
        return String::new();
    };
    let mut chars = scheme.chars();
    let valid = chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    if valid {
        scheme.to_ascii_lowercase()
    } else {
        String::new()
    }
}

/// A URL's authority (QUrl::authority): user info, host (lower case) and
/// port; "" without one.
fn authority(url: &str) -> String {
    if scheme(url).is_empty() {
        return String::new();
    }
    let Some((_, rest)) = url.split_once("://") else {
        return String::new();
    };
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..end];
    match authority.rsplit_once('@') {
        Some((user, host)) => format!("{user}@{}", host.to_lowercase()),
        None => authority.to_lowercase(),
    }
}

fn http(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://")
}

// ---- what the page shows of a provider ---------------------------------

/// A hub's settings key, stable per hub (AddUsageLimitSourceDialog's
/// sourceIdFromUrl): its host with dots and dashes kept, anything else folded
/// to a dash.
fn hub_id(url: &str) -> String {
    let host = match authority(url) {
        a if a.is_empty() => url.to_owned(),
        a => a,
    };
    let mut slug = String::new();
    let mut run = false;
    for c in host.to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '-' {
            slug.push(c);
            run = false;
        } else if !run {
            // A run of anything else is one dash.
            slug.push('-');
            run = true;
        }
    }
    let slug = slug.trim_matches('-');
    format!("cliproxy-{}", if slug.is_empty() { "hub" } else { slug })
}

/// The MC's background activity presets' provider health intervals
/// (HalC2.BackgroundPolicy), in seconds.
fn preset_health_seconds(profile: &str) -> i64 {
    match profile {
        "performance" => 60,
        "battery-saver" => 900,
        _ => 300,
    }
}

/// The preset a `backgroundActivity` builds on: its profile, or for a custom
/// one the profile it started from.
fn base_profile(activity: &Json) -> &'static str {
    let profile = str_at(activity, "profile");
    let base = if profile == "custom" {
        str_at(activity, "baseProfile")
    } else {
        profile
    };
    match base {
        "performance" => "performance",
        "battery-saver" => "battery-saver",
        _ => "balanced",
    }
}

/// The provider health interval the MC uses, in seconds
/// (BackgroundPolicy.settings).
fn health_seconds(settings: &Json) -> i64 {
    let activity = at(settings, "backgroundActivity");
    if str_at(activity, "profile") == "custom"
        && let Some(ms) = at(at(activity, "overrides"), HEALTH_KEY).as_f64()
    {
        return (ms / 1000.0) as i64;
    }
    preset_health_seconds(base_profile(activity))
}

/// `settings` with the health interval overridden (`seconds`) or back to its
/// preset (none): a custom profile on the current base, keeping the overrides
/// a custom profile had.
fn with_health_seconds(settings: Json, seconds: Option<i64>) -> Json {
    let activity = at(&settings, "backgroundActivity").clone();
    let mut overrides = if str_at(&activity, "profile") == "custom" {
        object_at(&activity, "overrides")
    } else {
        Map::new()
    };
    match seconds {
        Some(seconds) => overrides.insert(HEALTH_KEY.into(), json!(seconds * 1000)),
        None => overrides.remove(HEALTH_KEY),
    };
    let mut root = settings.as_object().cloned().unwrap_or_default();
    root.insert(
        "backgroundActivity".into(),
        json!({
            "schemaVersion": 1,
            "profile": "custom",
            "baseProfile": base_profile(&activity),
            "overrides": overrides,
        }),
    );
    Json::Object(root)
}

/// getProviderVersionLabel: bare versions get a `v`; Antigravity's release
/// tag shows as its date and candidate.
pub fn version_label(version: &str) -> String {
    // An MC that has not launched the agent says "unknown"; that is no version.
    if version.is_empty() || version == "unknown" {
        return String::new();
    }
    if let Some(label) = antigravity_label(version) {
        return label;
    }
    if version.chars().next().is_some_and(|c| c.is_ascii_digit()) {
        format!("v{version}")
    } else {
        version.to_owned()
    }
}

/// `agy_acp_server_YYYYMMDD_N[_candidate]` as "YYYY-MM-DD[ candidate]".
fn antigravity_label(version: &str) -> Option<String> {
    let rest = version.strip_prefix("agy_acp_server_")?;
    let date = rest.get(..8)?;
    if !date.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let rest = rest[8..].strip_prefix('_')?;
    let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
    if digits == 0 {
        return None;
    }
    let candidate = match &rest[digits..] {
        "" => "",
        tail => {
            let word = tail.strip_prefix('_')?;
            // \w+: letters, digits and underscores.
            if word.is_empty() || !word.chars().all(|c| c.is_alphanumeric() || c == '_') {
                return None;
            }
            word
        }
    };
    let mut label = format!("{}-{}-{}", &date[..4], &date[4..6], &date[6..]);
    if !candidate.is_empty() {
        label.push(' ');
        label.push_str(candidate);
    }
    Some(label)
}

/// getProviderSummary: the line under a provider's name, as (headline,
/// detail).
pub fn summary(provider: &Json) -> (String, String) {
    let auth = at(provider, "auth");
    let message = text(provider, "message");
    let status = str_at(provider, "status");
    let auth_status = str_at(auth, "status");
    let auth_label = match text(auth, "label") {
        label if label.is_empty() => text(auth, "type"),
        label => label,
    };
    let or = |fallback: &str| {
        if message.is_empty() {
            fallback.to_owned()
        } else {
            message.clone()
        }
    };
    let labelled = |head: &str| {
        if auth_label.is_empty() {
            head.to_owned()
        } else {
            format!("{head} · {auth_label}")
        }
    };
    if !bool_at(provider, "enabled") || status == "disabled" {
        return (
            "Disabled".into(),
            or("This provider is installed but disabled for new sessions in HAL-C2."),
        );
    }
    if !bool_at(provider, "installed") {
        return ("Not found".into(), or("CLI not detected on PATH."));
    }
    if auth_status == "unauthenticated" {
        return (labelled("Not authenticated"), message);
    }
    if status == "warning" {
        return (
            "Needs attention".into(),
            or("The provider is installed, but the server could not fully verify it."),
        );
    }
    if status == "error" {
        return (
            "Unavailable".into(),
            or("The provider failed its startup checks."),
        );
    }
    if auth_status == "authenticated" {
        return (labelled("Authenticated"), message);
    }
    ("Available".into(), message)
}

/// getProviderVersionAdvisoryPresentation: a version outside the supported
/// range first, else an update, else null.
fn advisory(provider: &Json) -> Json {
    let version = at(provider, "versionAdvisory");
    let compatibility = at(provider, "compatibilityAdvisory");
    let latest_status = str_at(compatibility, "latestVersionStatus");
    let latest_incompatible = latest_status == "broken" || latest_status == "unsupported";
    let update_command = match at(version, "updateCommand") {
        Json::String(command) => Json::String(command.clone()),
        _ => Json::Null,
    };
    let status = str_at(compatibility, "status");
    let title = match status {
        "graceful" => Some("Limited support"),
        "unsupported" => Some("Unsupported version"),
        "broken" => Some("Known broken version"),
        _ => None,
    };
    // A disabled provider's version does not matter until it is turned on.
    if bool_at(provider, "enabled")
        && let Some(title) = title
    {
        let target = text(compatibility, "recommendedVersion");
        let recommendation = if target.is_empty() {
            text(compatibility, "recommendedRange")
        } else {
            version_label(&target)
        };
        let mut detail = text(compatibility, "message");
        if detail.is_empty() {
            detail = if recommendation.is_empty() {
                "Update for full support.".into()
            } else {
                format!("Use {recommendation} for full support.")
            };
        }
        return json!({
            "title": title,
            "detail": detail,
            "updateCommand": if !target.is_empty() || latest_incompatible { Json::Null } else { update_command },
            "targetVersion": if target.is_empty() { Json::Null } else { Json::String(target) },
            "strong": status != "graceful",
        });
    }
    let version_status = str_at(version, "status");
    if empty(version)
        || version_status == "current"
        || version_status == "unknown"
        || latest_incompatible
    {
        return Json::Null;
    }
    let latest = version_label(&text(version, "latestVersion"));
    // The title already says "Update available"; the detail only adds what to install.
    let mut detail = strip_update_title(&text(version, "message")).to_owned();
    if detail.is_empty() {
        detail = if latest.is_empty() {
            "Install the latest provider version.".into()
        } else {
            format!("Install {latest}.")
        };
    }
    json!({
        "title": "Update available",
        "detail": detail,
        "updateCommand": update_command,
        "targetVersion": Json::Null,
        "strong": false,
    })
}

/// `message` without a leading "Update available", its "." or ":" and the
/// space after (case-insensitive).
fn strip_update_title(message: &str) -> &str {
    const TITLE: &str = "update available";
    match message.get(..TITLE.len()) {
        Some(head) if head.eq_ignore_ascii_case(TITLE) => {
            let rest = &message[TITLE.len()..];
            let rest = rest
                .strip_prefix('.')
                .or_else(|| rest.strip_prefix(':'))
                .unwrap_or(rest);
            rest.trim_start()
        }
        _ => message,
    }
}

/// isProviderSettingsUpdateCandidate: the environment can run the update
/// itself.
fn updatable(provider: &Json) -> bool {
    let version = at(provider, "versionAdvisory");
    let latest_status = str_at(at(provider, "compatibilityAdvisory"), "latestVersionStatus");
    bool_at(provider, "enabled")
        && latest_status != "broken"
        && latest_status != "unsupported"
        && str_at(version, "status") == "behind_latest"
        && bool_at(version, "canUpdate")
        && at(version, "updateCommand").is_string()
}

/// The recommended version the environment can install in place of the one
/// it has (ProviderSettingsPanel onInstallRecommended), or empty.
fn installable(provider: &Json) -> String {
    let compatibility = at(provider, "compatibilityAdvisory");
    let target = text(compatibility, "recommendedVersion");
    if target.is_empty()
        || text(compatibility, "message").is_empty()
        || !bool_at(at(provider, "versionAdvisory"), "canInstallVersion")
    {
        return String::new();
    }
    if str_at(&advisory(provider), "targetVersion") == target {
        target
    } else {
        String::new()
    }
}

/// Whether the provider has an Account section.
fn signs_in(provider: &Json) -> bool {
    bool_at(at(provider, "setup"), "canAuthenticate")
        || (str_at(provider, "driver") == REGISTRY && bool_at(provider, "installed"))
}

/// The labels of what a model can do, from its option descriptors.
fn model_labels(model: &Json) -> Vec<&'static str> {
    let (mut fast, mut thinking, mut reasoning) = (false, false, false);
    for descriptor in array_at(at(model, "capabilities"), "optionDescriptors") {
        let id = str_at(descriptor, "id");
        let select = str_at(descriptor, "type") == "select";
        if id == "fastMode" {
            fast = true;
        }
        if id == "serviceTier" && select {
            fast = fast
                || array_at(descriptor, "options")
                    .iter()
                    .any(|o| str_at(o, "id") == "fast" || str_at(o, "label") == "Fast");
        }
        if id == "thinking" {
            thinking = true;
        }
        if select && matches!(id, "reasoningEffort" | "effort" | "reasoning" | "variant") {
            reasoning = true;
        }
    }
    let mut labels = Vec::new();
    if fast {
        labels.push("Fast mode");
    }
    if thinking {
        labels.push("Thinking");
    }
    if reasoning {
        labels.push("Reasoning");
    }
    labels
}

/// The latest valid ISO time among the providers' `checkedAt`.
fn latest_check(providers: &[Json]) -> Option<DateTime<Utc>> {
    providers
        .iter()
        .filter_map(|p| parse_time(str_at(p, "checkedAt")))
        .max()
}

/// An ISO time as Qt::ISODateWithMs reads one: with an offset, else local.
fn parse_time(value: &str) -> Option<DateTime<Utc>> {
    if value.is_empty() {
        return None;
    }
    if let Ok(at) = DateTime::parse_from_rfc3339(value) {
        return Some(at.with_timezone(&Utc));
    }
    let naive = NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M:%S%.f")
        .or_else(|_| NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M"))
        .ok()?;
    naive
        .and_local_timezone(Local)
        .earliest()
        .map(|at| at.with_timezone(&Utc))
}

// ---- the controller ----------------------------------------------------

/// A finished settings save, with whether it saved.
type Saved = Box<dyn FnOnce(&mut ProviderSettings, &Engine, bool)>;

/// A registry agent's sessions and model providers as last listed from the
/// chosen project, the next page's cursor, and what runs ("" for nothing).
#[derive(Clone, Default)]
struct Acp {
    project_id: String,
    sessions: Option<Vec<Json>>,
    next_cursor: String,
    providers: Option<Vec<Json>>,
    busy: String,
}

/// The add-provider wizard while it shows: the chosen driver, what was
/// entered for each driver (label, accentColor, instanceId when typed) and its
/// config, the step (Provider, Identity, Config), whether moving on was tried
/// (which shows the id's error), and whether it is saving. Its ACP Registry
/// search: the query, the agents found (none before the first answer), the
/// search in flight, why it failed, the agent being prepared, the one chosen
/// ({id, name, version}), and whether one is entered by hand.
struct Wizard {
    /// A new one with each wizard opened.
    id: u64,
    driver: String,
    identity: HashMap<String, Map<String, Json>>,
    config: HashMap<String, Map<String, Json>>,
    step: i64,
    attempted: bool,
    saving: bool,
    query: String,
    agents: Option<Vec<Json>>,
    generation: u64,
    searching: bool,
    registry_error: String,
    preparing: String,
    selected: Map<String, Json>,
    manual: bool,
}

impl Wizard {
    fn new(id: u64) -> Wizard {
        Wizard {
            id,
            driver: "codex".into(),
            identity: HashMap::new(),
            config: HashMap::new(),
            step: 0,
            attempted: false,
            saving: false,
            query: String::new(),
            agents: None,
            generation: 0,
            searching: false,
            registry_error: String::new(),
            preparing: String::new(),
            selected: Map::new(),
            manual: false,
        }
    }
}

pub struct ProviderSettings {
    bridge: Bridge,
    me: Me<ProviderSettings>,
    mc: Rc<dyn Mc>,
    active: bool,
    open: bool,
    /// The environment the user chose; empty for this machine.
    environment: String,
    /// The followed environment.
    followed: String,
    /// Which following an answer belongs to: a new one with each unfollow,
    /// so an answer from before a switch away and back is dropped.
    following: u64,
    /// The followed environment's settings document and config frames.
    scope: EnvironmentSettings,
    /// The providers its `config` shape brought.
    providers: Option<Vec<Json>>,
    /// Each signing-in provider's `providerAuth` shape and its last state.
    auth: HashMap<String, SubId>,
    auth_state: HashMap<String, Json>,
    /// Each managed runtime's `providerInstall` shape, its last state, and
    /// why the last call about it failed.
    install: HashMap<String, SubId>,
    install_state: HashMap<String, Json>,
    install_error: HashMap<String, String>,
    /// Why the last sign-in call failed, by instance.
    auth_error: HashMap<String, String>,
    busy: HashSet<String>,
    /// Input for each login terminal, sent one request at a time.
    terminal_queue: HashMap<String, VecDeque<Json>>,
    terminal_sending: HashSet<String>,
    updating: HashSet<String>,
    acp: HashMap<String, Acp>,
    wizard: Option<Wizard>,
    wizards: u64,
    /// Variable rows being edited that cannot be saved yet (a blank or
    /// invalid name), by instance.
    variables: HashMap<String, Vec<Json>>,
    /// The custom model being edited ({slug, name, options}), and why the
    /// last custom model change was refused, by instance.
    model_draft: HashMap<String, Json>,
    model_error: HashMap<String, String>,
    /// What the user typed over each instance's models list.
    model_filter: HashMap<String, String>,
    refreshing: i32,
}

impl Controller for ProviderSettings {
    fn new(init: Init<'_, Self>) -> Self {
        let scope = EnvironmentSettings::new(init.mc.clone());
        let me = init.me.clone();
        scope.on_frame(move |engine, _, frame: &Frame| {
            let providers = match frame.get("t").and_then(Json::as_str) {
                Some("config") => frame.get("config").map(|c| array_at(c, "providers")),
                Some("config.providers") => frame
                    .get("providers")
                    .and_then(Json::as_array)
                    .map(Vec::as_slice)
                    .or(Some(&[])),
                _ => None,
            };
            let Some(providers) = providers.map(<[Json]>::to_vec) else {
                return;
            };
            me.run(engine, |c, engine| {
                c.providers = Some(providers);
                c.follow_auth(engine);
                c.follow_runtime(engine);
                c.publish(engine);
            });
        });
        let me = init.me.clone();
        scope.on_changed(move |engine| me.run(engine, |c, engine| c.publish(engine)));
        ProviderSettings {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            open: false,
            environment: String::new(),
            followed: String::new(),
            following: 0,
            scope,
            providers: None,
            auth: HashMap::new(),
            auth_state: HashMap::new(),
            install: HashMap::new(),
            install_state: HashMap::new(),
            install_error: HashMap::new(),
            auth_error: HashMap::new(),
            busy: HashSet::new(),
            terminal_queue: HashMap::new(),
            terminal_sending: HashSet::new(),
            updating: HashSet::new(),
            acp: HashMap::new(),
            wizard: None,
            wizards: 0,
            variables: HashMap::new(),
            model_draft: HashMap::new(),
            model_error: HashMap::new(),
            model_filter: HashMap::new(),
            refreshing: 0,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let open = at_section(route, PROVIDERS_SECTION);
            me.run(engine, |c, engine| c.set_open(engine, open));
        });
        // An environment that comes, goes, or drops changes what can be shown.
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| {
                if c.open {
                    c.update(engine);
                }
            });
        });
        let me = self.me.clone();
        Settings::of(engine).on_device_changed(move |engine| {
            me.run(engine, |c, engine| {
                if c.open {
                    c.publish(engine);
                }
            });
        });
        let route = self.bridge.published(engine, "route");
        self.set_open(
            engine,
            route.is_some_and(|r| at_section(&r, PROVIDERS_SECTION)),
        );
        self.publish(engine);
    }

    fn attach(&mut self, engine: &Engine, _window: &Window) {
        Commands::of(engine).add(
            engine,
            "providers.open",
            "Open provider settings",
            |engine| {
                controller::with::<Navigation, _>(engine, |n, engine| {
                    n.open(engine, Route::Settings(PROVIDERS_SECTION.into()));
                });
            },
        );
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("providerSettings.") {
            return false;
        }
        let instance_id = str_at(payload, "instanceId").to_owned();
        let entry = self.provider(&instance_id);
        let auth = self
            .auth_state
            .get(&instance_id)
            .cloned()
            .unwrap_or_default();
        match action {
            // Which models this device's picker offers, and in what order: its
            // own preference (providerModelPreferences), whoever may change the
            // environment.
            "providerSettings.modelHidden" | "providerSettings.modelMove" => {
                self.model_preference(engine, action, &instance_id, &entry, payload);
                return true;
            }
            "providerSettings.environment" => {
                self.environment = str_at(payload, "id").to_owned();
                self.update(engine);
                return true;
            }
            "providerSettings.filterModels" => {
                // The models whose name or id has the typed text.
                self.model_filter
                    .insert(instance_id, input_string(payload, "query"));
                self.publish(engine);
                return true;
            }
            "providerSettings.refresh" => {
                self.refresh(engine);
                return true;
            }
            "providerSettings.healthInterval" => {
                let seconds = input_number(payload, "seconds").round().max(0.0) as i64;
                self.save(
                    engine,
                    move |settings, _| with_health_seconds(settings, Some(seconds)),
                    None,
                    "",
                );
                return true;
            }
            "providerSettings.resetHealthInterval" => {
                self.save(
                    engine,
                    |settings, _| with_health_seconds(settings, None),
                    None,
                    "",
                );
                return true;
            }
            "providerSettings.addHub" => {
                self.add_hub(engine, payload);
                return true;
            }
            "providerSettings.removeHub" => {
                let id = input_string(payload, "id");
                self.save(
                    engine,
                    move |settings, _| {
                        let mut hubs = object_at(&settings, "usageLimitSources");
                        hubs.remove(&id);
                        let mut root = settings.as_object().cloned().unwrap_or_default();
                        root.insert("usageLimitSources".into(), Json::Object(hubs));
                        Json::Object(root)
                    },
                    None,
                    "",
                );
                return true;
            }
            _ => {}
        }
        if self.handle_instance(engine, action, payload)
            || self.handle_registry(engine, action, payload)
            || self.handle_acp(engine, action, payload)
            || self.handle_runtime(engine, action, payload)
        {
            return true;
        }
        if action == "providerSettings.enable" {
            // Also an instance the environment has yet to list.
            if !self.driver_of(&instance_id).is_empty() {
                self.set_enabled(engine, &instance_id, input_bool(payload, "enabled"));
            }
            return true;
        }
        if empty(&entry) {
            return true;
        }
        match action {
            "providerSettings.signIn" => {
                let mut start = json!({"instanceId": instance_id});
                // A method the environment offers; otherwise the provider's default.
                let method_id = input_string(payload, "methodId");
                if !method_id.is_empty()
                    && array_at(&auth, "methods")
                        .iter()
                        .any(|m| str_at(m, "id") == method_id)
                {
                    start["methodId"] = Json::String(method_id);
                }
                self.call(
                    engine,
                    &instance_id,
                    "provider.auth.start",
                    start,
                    SIGN_IN_FAILED,
                );
            }
            "providerSettings.signInTerminal" => {
                self.sign_in_terminal(&instance_id, &auth, payload);
            }
            "providerSettings.signInCredentials" => {
                let interaction = at(&auth, "interaction");
                if str_at(interaction, "type") != "credentials" {
                    return true;
                }
                let mut values = Map::new();
                for field in array_at(interaction, "fields") {
                    let name = str_at(field, "name");
                    if let Some(given) = at(payload, "values").get(name) {
                        values.insert(
                            name.to_owned(),
                            Json::String(input_string(&json!({"v": given}), "v")),
                        );
                    }
                }
                let mut respond = Map::new();
                respond.insert("instanceId".into(), Json::String(instance_id.clone()));
                insert_defined(&mut respond, "flowId", at(&auth, "flowId"));
                insert_defined(&mut respond, "interactionId", at(interaction, "id"));
                respond.insert(
                    "response".into(),
                    json!({"type": "credentials", "values": values}),
                );
                self.call(
                    engine,
                    &instance_id,
                    "provider.auth.respond",
                    Json::Object(respond),
                    SIGN_IN_FAILED,
                );
            }
            "providerSettings.signInCallback" => {
                // The final localhost address, pasted when its page did not load.
                let url = input_string(payload, "url").trim().to_owned();
                let flow_id = str_at(&auth, "flowId").to_owned();
                if url.is_empty() || flow_id.is_empty() {
                    return true;
                }
                self.call(
                    engine,
                    &instance_id,
                    "provider.auth.complete",
                    json!({"instanceId": instance_id, "flowId": flow_id, "callbackUrl": url}),
                    SIGN_IN_FAILED,
                );
            }
            "providerSettings.copySignInLink" => {
                let interaction = at(&auth, "interaction");
                let kind = str_at(interaction, "type");
                let url = sign_in_url(&auth);
                if url.is_empty() {
                    return true;
                }
                if !self.bridge.copy_to_clipboard(engine, &url) {
                    self.auth_error.insert(
                        instance_id.clone(),
                        "Could not copy the sign-in link.".to_owned(),
                    );
                } else if kind == "browser" && bool_at(interaction, "requiresConsent") {
                    // The link only works once the environment records consent.
                    let respond = consent(&instance_id, &auth);
                    self.call(
                        engine,
                        &instance_id,
                        "provider.auth.respond",
                        respond,
                        "Could not copy the sign-in link.",
                    );
                    return true;
                }
                self.publish(engine);
            }
            "providerSettings.openDocs" => {
                let url = str_at(at(&entry, "setup"), "documentationUrl");
                if http(url) {
                    self.bridge.open_external(engine, url);
                }
            }
            "providerSettings.cancelSignIn" => {
                let flow_id = str_at(&auth, "flowId").to_owned();
                if !flow_id.is_empty() {
                    self.call(
                        engine,
                        &instance_id,
                        "provider.auth.cancel",
                        json!({"instanceId": instance_id, "flowId": flow_id}),
                        SIGN_IN_FAILED,
                    );
                }
            }
            "providerSettings.openSignIn" => self.open_sign_in(engine, &instance_id, &auth),
            "providerSettings.continueUrlAuth" => {
                self.continue_url_auth(engine, &instance_id, &entry);
            }
            "providerSettings.signOut" => self.sign_out(engine, &instance_id, &entry),
            "providerSettings.update" | "providerSettings.install" => {
                self.update_provider(
                    engine,
                    &instance_id,
                    &entry,
                    action == "providerSettings.install",
                );
            }
            "providerSettings.copyUpdateCommand" => {
                let command = str_at(&advisory(&entry), "updateCommand").to_owned();
                if command.is_empty() {
                    return true;
                }
                if self.bridge.copy_to_clipboard(engine, &command) {
                    toast(
                        engine,
                        "success",
                        "Update command copied",
                        "Run it in a terminal when ready.",
                    );
                } else {
                    toast_error(engine, "Could not copy the update command", "");
                }
            }
            _ => {}
        }
        true
    }
}

/// Inserts `value` unless it is null (an undefined QJsonValue drops the key).
fn insert_defined(map: &mut Map<String, Json>, key: &str, value: &Json) {
    if !value.is_null() {
        map.insert(key.into(), value.clone());
    }
}

/// The sign-in's page: a browser or device code interaction's, else the
/// state's authorization URL.
fn sign_in_url(auth: &Json) -> String {
    let interaction = at(auth, "interaction");
    match str_at(interaction, "type") {
        "browser" | "deviceCode" => str_at(interaction, "url").to_owned(),
        _ => str_at(auth, "authorizationUrl").to_owned(),
    }
}

/// The browser interaction's consent.
fn consent(instance_id: &str, auth: &Json) -> Json {
    let mut respond = Map::new();
    respond.insert("instanceId".into(), Json::String(instance_id.into()));
    insert_defined(&mut respond, "flowId", at(auth, "flowId"));
    insert_defined(
        &mut respond,
        "interactionId",
        at(at(auth, "interaction"), "id"),
    );
    respond.insert(
        "response".into(),
        json!({"type": "browser", "action": "accept"}),
    );
    Json::Object(respond)
}

fn toast(engine: &Engine, kind: &str, title: &str, description: &str) {
    controller::with::<Toasts, _>(engine, |toasts, engine| {
        toasts.show(engine, kind, title, description, None, DEFAULT_TIMEOUT_MS);
    });
}

fn toast_error(engine: &Engine, title: &str, description: &str) {
    controller::with::<Toasts, _>(engine, |toasts, engine| {
        toasts.error(engine, title, description);
    });
}

/// Asks first; `yes` runs on the controller once the user agrees.
fn confirm(
    engine: &Engine,
    me: &Me<ProviderSettings>,
    title: &str,
    description: &str,
    button: &str,
    yes: impl Fn(&mut ProviderSettings, &Engine) + 'static,
) {
    let me = me.clone();
    let yes = Rc::new(yes);
    let accepted: Answer = Rc::new(move |engine: &Engine| {
        let yes = yes.clone();
        me.run(engine, move |c, engine| yes(c, engine));
    });
    controller::with::<Menus, _>(engine, |menus, engine| {
        menus.confirm(
            engine,
            title,
            description,
            button,
            true,
            Some(accepted),
            None,
        );
    });
}

fn error_text(error: &McError, fallback: &str) -> String {
    if error.message.is_empty() {
        fallback.to_owned()
    } else {
        error.message.clone()
    }
}

impl ProviderSettings {
    fn set_open(&mut self, engine: &Engine, open: bool) {
        if open == self.open {
            return;
        }
        self.open = open;
        if open {
            self.update(engine);
        } else {
            // Nothing is followed for a section nobody sees.
            self.unfollow();
            self.publish(engine);
        }
    }

    /// Follows the chosen environment while it can answer.
    fn update(&mut self, engine: &Engine) {
        if !self.open {
            return;
        }
        let environment = self.chosen(engine);
        if !environment.is_empty() && store::with(engine, |s| s.environment_online(&environment)) {
            self.follow(engine, &environment);
        } else {
            self.unfollow();
        }
        self.publish(engine);
    }

    fn follow(&mut self, engine: &Engine, environment: &str) {
        if self.followed == environment {
            self.follow_auth(engine);
            self.follow_runtime(engine);
            return;
        }
        self.unfollow();
        self.followed = environment.to_owned();
        self.scope.set_targets(&[environment.to_owned()]);
    }

    fn unfollow(&mut self) {
        self.scope.set_targets(&[]);
        self.followed.clear();
        self.following += 1;
        self.providers = None;
        for (_, id) in self.auth.drain() {
            self.mc.unsubscribe(id);
        }
        self.unfollow_runtime();
        self.auth_state.clear();
        self.auth_error.clear();
        self.busy.clear();
        self.terminal_queue.clear();
        self.wizard = None;
        self.variables.clear();
        self.model_draft.clear();
        self.model_error.clear();
        self.acp.clear();
    }

    /// The instances among the providers `wanted` keeps, on the MC serving
    /// the followed environment ("" for none).
    fn wanted(&self, engine: &Engine, keep: fn(&Json) -> bool) -> (String, Vec<String>) {
        let mc = store::with(engine, |s| s.mc_serving(&self.followed));
        let mut wanted = Vec::new();
        if !mc.is_empty()
            && let Some(providers) = &self.providers
        {
            for provider in providers.iter().filter(|p| keep(p)) {
                let id = str_at(provider, "instanceId").to_owned();
                if !wanted.contains(&id) {
                    wanted.push(id);
                }
            }
        }
        (mc, wanted)
    }

    /// Follows the sign-in of each provider that signs in from HAL-C2, on the
    /// MC serving the environment (the shape is MC-addressed).
    fn follow_auth(&mut self, engine: &Engine) {
        let (mc, wanted) = self.wanted(engine, signs_in);
        let dropped: Vec<String> = self
            .auth
            .keys()
            .filter(|id| !wanted.contains(id))
            .cloned()
            .collect();
        for id in dropped {
            if let Some(sub) = self.auth.remove(&id) {
                self.mc.unsubscribe(sub);
            }
            self.auth_state.remove(&id);
        }
        for id in wanted {
            if self.auth.contains_key(&id) {
                continue;
            }
            let me = self.me.clone();
            let instance_id = id.clone();
            let sub = self.mc.subscribe(
                json!({"type": "providerAuth", "mc": mc, "instanceId": id}),
                Box::new(move |engine, frame| {
                    if frame.get("t").and_then(Json::as_str) != Some("providerAuth") {
                        return;
                    }
                    let state = frame
                        .get("state")
                        .filter(|s| s.is_object())
                        .cloned()
                        .unwrap_or_else(|| json!({}));
                    let instance_id = instance_id.clone();
                    me.run(engine, move |c, engine| {
                        c.auth_state.insert(instance_id, state);
                        c.publish(engine);
                    });
                }),
                None,
            );
            self.auth.insert(id, sub);
        }
    }

    /// The chosen environment, or this machine; one that went away falls back
    /// to this machine until it comes back.
    fn chosen(&self, engine: &Engine) -> String {
        let environments = store::with(engine, |s| s.environments());
        if !self.environment.is_empty() && environments.contains(&self.environment) {
            return self.environment.clone();
        }
        let local = self.mc.environment();
        if environments.contains(&local) {
            local
        } else {
            String::new()
        }
    }

    fn label(&self, engine: &Engine, environment: &str) -> String {
        let label = store::with(engine, |s| {
            s.environment(environment)
                .get("label")
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        });
        if !label.is_empty() {
            label
        } else if environment == self.mc.environment() {
            "This machine".into()
        } else {
            environment.to_owned()
        }
    }

    /// The listed provider with this instance id, or null.
    fn provider(&self, instance_id: &str) -> Json {
        if instance_id.is_empty() {
            return Json::Null;
        }
        self.providers
            .iter()
            .flatten()
            .find(|p| str_at(p, "instanceId") == instance_id)
            .cloned()
            .unwrap_or(Json::Null)
    }

    /// The shown environment's settings document, once it has answered.
    fn shown_settings(&self) -> Option<Json> {
        if self.followed.is_empty() {
            return None;
        }
        self.scope.settings(&self.followed)
    }

    fn refresh(&mut self, engine: &Engine) {
        if self.followed.is_empty() {
            return;
        }
        self.refreshing += 1;
        self.publish(engine);
        let me = self.me.clone();
        self.mc.call(
            &self.followed,
            "server.refreshProviders",
            json!({"refreshModels": true}),
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    c.refreshing -= 1;
                    if let Err(error) = result {
                        toast_error(engine, "Could not refresh providers", &error.message);
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    fn add_hub(&mut self, engine: &Engine, payload: &Json) {
        let url = input_string(payload, "url").trim().to_owned();
        let key = input_string(payload, "key").trim().to_owned();
        let name = input_string(payload, "label").trim().to_owned();
        if url.is_empty() || key.is_empty() {
            return;
        }
        // The MC moves the key to its secret store; settings keep a marker.
        let mut hub =
            json!({"kind": "cliproxy", "url": url, "managementKey": key, "enabled": true});
        if !name.is_empty() {
            hub["label"] = Json::String(name);
        }
        let id = hub_id(&url);
        self.save(
            engine,
            move |settings, _| {
                let mut hubs = object_at(&settings, "usageLimitSources");
                hubs.insert(id.clone(), hub.clone());
                let mut root = settings.as_object().cloned().unwrap_or_default();
                root.insert("usageLimitSources".into(), Json::Object(hubs));
                Json::Object(root)
            },
            None,
            "",
        );
    }

    fn model_preference(
        &mut self,
        engine: &Engine,
        action: &str,
        instance_id: &str,
        entry: &Json,
        payload: &Json,
    ) {
        let slug = input_string(payload, "slug");
        if instance_id.is_empty() || slug.is_empty() {
            return;
        }
        let settings = Settings::of(engine);
        let mut preferences = settings
            .device_value("providerModelPreferences")
            .and_then(|p| p.as_object().cloned())
            .unwrap_or_default();
        let mut preference = preferences
            .get(instance_id)
            .and_then(Json::as_object)
            .cloned()
            .unwrap_or_default();
        if action == "providerSettings.modelHidden" {
            let mut hidden: Vec<Json> = preference
                .get("hiddenModels")
                .and_then(Json::as_array)
                .cloned()
                .unwrap_or_default();
            hidden.retain(|h| h.as_str() != Some(slug.as_str()));
            if input_bool(payload, "hidden") {
                hidden.push(Json::String(slug));
            }
            preference.insert("hiddenModels".into(), Json::Array(hidden));
        } else {
            // The whole order as the page shows it, with this model moved `by` places.
            let (models, _, _) = self.models(engine, entry);
            let mut order: Vec<String> = models
                .iter()
                .map(|m| str_at(m, "slug").to_owned())
                .collect();
            let Some(from) = order.iter().position(|s| *s == slug) else {
                return;
            };
            let last = order.len() as i64 - 1;
            let to = (from as i64 + input_int(payload, "by")).clamp(0, last) as usize;
            if to == from {
                return;
            }
            let moved = order.remove(from);
            order.insert(to, moved);
            preference.insert("modelOrder".into(), json!(order));
        }
        preferences.insert(instance_id.to_owned(), Json::Object(preference));
        settings.write_device(
            engine,
            "providerModelPreferences",
            Json::Object(preferences),
        );
        self.publish(engine);
    }

    fn sign_in_terminal(&mut self, instance_id: &str, auth: &Json, payload: &Json) {
        // Keystrokes and sizes for the agent's login terminal, in order, at
        // most 4096 characters a request (ProviderAuthenticationSection).
        let interaction = at(auth, "interaction");
        let flow_id = str_at(auth, "flowId");
        if str_at(interaction, "type") != "terminal" || flow_id.is_empty() {
            return;
        }
        let data: Vec<char> = input_string(payload, "data").chars().collect();
        let mut response = Map::new();
        response.insert("type".into(), json!("terminal"));
        if has(payload, "columns") {
            response.insert(
                "size".into(),
                json!({"cols": input_int(payload, "columns"), "rows": input_int(payload, "rows")}),
            );
        }
        // Characters rather than desktop-qt's UTF-16 units, so a chunk never
        // splits a character.
        let chunks: Vec<String> = if data.is_empty() {
            vec![String::new()]
        } else {
            data.chunks(4096).map(|c| c.iter().collect()).collect()
        };
        let queue = self
            .terminal_queue
            .entry(instance_id.to_owned())
            .or_default();
        for chunk in chunks {
            let mut response = response.clone();
            response.insert("data".into(), Json::String(chunk));
            let mut item = Map::new();
            item.insert("instanceId".into(), Json::String(instance_id.into()));
            item.insert("flowId".into(), Json::String(flow_id.into()));
            insert_defined(&mut item, "interactionId", at(interaction, "id"));
            item.insert("response".into(), Json::Object(response));
            queue.push_back(Json::Object(item));
        }
        self.send_terminal(instance_id);
    }

    fn send_terminal(&mut self, instance_id: &str) {
        if self.terminal_sending.contains(instance_id) || self.followed.is_empty() {
            return;
        }
        let Some(next) = self
            .terminal_queue
            .entry(instance_id.to_owned())
            .or_default()
            .pop_front()
        else {
            return;
        };
        self.terminal_sending.insert(instance_id.to_owned());
        let environment = self.followed.clone();
        let me = self.me.clone();
        let id = instance_id.to_owned();
        self.mc.call(
            &environment.clone(),
            "provider.auth.respond",
            next,
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    c.terminal_sending.remove(&id);
                    if c.followed != environment {
                        return;
                    }
                    if result.is_err() {
                        c.terminal_queue.remove(&id);
                        c.auth_error.insert(
                            id,
                            "The provider sign-in terminal is no longer available.".into(),
                        );
                        c.publish(engine);
                        return;
                    }
                    c.send_terminal(&id);
                });
            }),
        );
    }

    fn open_sign_in(&mut self, engine: &Engine, instance_id: &str, auth: &Json) {
        let interaction = at(auth, "interaction");
        let url = sign_in_url(auth);
        if url.is_empty() {
            return;
        }
        if str_at(interaction, "type") != "browser" || !bool_at(interaction, "requiresConsent") {
            self.bridge.open_external(engine, &url);
            return;
        }
        // The environment records consent before its provider's page opens here.
        let following = self.following;
        self.busy.insert(instance_id.to_owned());
        self.publish(engine);
        let me = self.me.clone();
        let id = instance_id.to_owned();
        self.mc.call(
            &self.followed,
            "provider.auth.respond",
            consent(instance_id, auth),
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    // The answer may come after the user moved on.
                    if c.following != following {
                        return;
                    }
                    c.busy.remove(&id);
                    match result {
                        Err(error) => {
                            c.auth_error.insert(id, error.message);
                        }
                        Ok(_) => c.bridge.open_external(engine, &url),
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    /// A sign-in page the agent asked for outside a sign-in: it opens here
    /// and the environment tells the agent it was opened.
    fn continue_url_auth(&mut self, engine: &Engine, instance_id: &str, entry: &Json) {
        let pending = at(at(entry, "auth"), "action");
        let url = str_at(pending, "url");
        let elicitation_id = str_at(pending, "elicitationId");
        if elicitation_id.is_empty() || !http(url) {
            return;
        }
        self.bridge.open_external(engine, url);
        self.mc.call(
            &self.followed,
            "server.acceptAcpRegistryUrlAuth",
            json!({"instanceId": instance_id, "elicitationId": elicitation_id}),
            Box::new(move |engine, result| match result {
                Err(error) => toast_error(
                    engine,
                    "Could not continue authentication",
                    &error_text(&error, "The authentication request expired."),
                ),
                Ok(result) if !bool_at(&result, "accepted") => toast(
                    engine,
                    "warning",
                    "Authentication request expired",
                    "Refresh the provider and start the authentication flow again.",
                ),
                Ok(_) => {}
            }),
        );
    }

    fn sign_out(&mut self, engine: &Engine, instance_id: &str, entry: &Json) {
        let name = match text(entry, "displayName") {
            name if name.is_empty() => str_at(entry, "driver").to_owned(),
            name => name,
        };
        let environment = self.followed.clone();
        let description = format!(
            "Sign out of {name} on {}? This stops running threads that share this sign-in. Thread history is kept.",
            self.label(engine, &environment)
        );
        let id = instance_id.to_owned();
        confirm(
            engine,
            &self.me,
            "Sign out?",
            &description,
            "Sign out",
            move |c, engine| {
                // The answer may come after the user moved on.
                if c.followed != environment {
                    return;
                }
                c.call(
                    engine,
                    &id,
                    "provider.auth.logout",
                    json!({"instanceId": id}),
                    "Could not sign out.",
                );
            },
        );
    }

    /// `.update`, or `.install` with the recommended version in place of the
    /// latest.
    fn update_provider(&mut self, engine: &Engine, instance_id: &str, entry: &Json, install: bool) {
        let target = if install {
            installable(entry)
        } else {
            String::new()
        };
        let allowed = if install {
            !target.is_empty()
        } else {
            updatable(entry)
        };
        if self.updating.contains(instance_id) || !allowed {
            return;
        }
        let driver = str_at(entry, "driver").to_owned();
        let name = match text(entry, "displayName") {
            name if name.is_empty() => driver.clone(),
            name => name,
        };
        let mut request = json!({"provider": driver, "instanceId": instance_id});
        if install {
            request["targetVersion"] = Json::String(target);
        }
        self.updating.insert(instance_id.to_owned());
        self.publish(engine);
        let me = self.me.clone();
        let id = instance_id.to_owned();
        self.mc.call(
            &self.followed,
            "server.updateProvider",
            request,
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    c.updating.remove(&id);
                    if let Err(error) = result {
                        toast_error(
                            engine,
                            &format!("Could not update {name}"),
                            &error_text(
                                &error,
                                "The provider update command could not be started.",
                            ),
                        );
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    /// Turns an instance on or off where the MC reads it: its
    /// providerInstances entry when it has one, and a built-in driver's
    /// `providers` entry.
    fn set_enabled(&mut self, engine: &Engine, instance_id: &str, enabled: bool) {
        let driver = self.driver_of(instance_id);
        let id = instance_id.to_owned();
        self.save(
            engine,
            move |settings, _| {
                let mut root = settings.as_object().cloned().unwrap_or_default();
                let mut instances = object_at(&settings, "providerInstances");
                let listed = instances.contains_key(&id);
                if let Some(Json::Object(instance)) = instances.get_mut(&id) {
                    instance.insert("enabled".into(), Json::Bool(enabled));
                } else if listed {
                    instances.insert(id.clone(), json!({"enabled": enabled}));
                }
                if listed {
                    root.insert("providerInstances".into(), Json::Object(instances));
                }
                if !listed || id == driver {
                    let mut providers = object_at(&settings, "providers");
                    let mut entry = object_at(&Json::Object(providers.clone()), &id);
                    entry.insert("enabled".into(), Json::Bool(enabled));
                    providers.insert(id.clone(), Json::Object(entry));
                    root.insert("providers".into(), Json::Object(providers));
                }
                Json::Object(root)
            },
            None,
            "",
        );
    }

    /// Changes the shown environment's settings; `done` hears whether it
    /// saved, after a failure has been toasted (`failure` its title, empty
    /// for the general one).
    fn save(
        &mut self,
        engine: &Engine,
        edit: impl Fn(Json, &str) -> Json + 'static,
        done: Option<Saved>,
        failure: &str,
    ) {
        let slot = Rc::new(RefCell::new(done));
        let later = slot.clone();
        let me = self.me.clone();
        let title = failure.to_owned();
        let result = self.scope.change(Rc::new(edit), move |engine, outcome| {
            let done = later.borrow_mut().take();
            me.run(engine, move |c, engine| {
                c.saved(engine, &outcome, done, &title)
            });
        });
        // Nothing could be written: it ends now, as desktop-qt's does.
        if let Err(outcome) = result {
            let done = slot.borrow_mut().take();
            self.saved(engine, &outcome, done, failure);
        }
    }

    fn saved(&mut self, engine: &Engine, outcome: &Outcome, done: Option<Saved>, failure: &str) {
        if let Some(why) = outcome.failed.values().next() {
            let title = if failure.is_empty() {
                "Could not save provider settings"
            } else {
                failure
            };
            let why = if why.is_empty() {
                "The settings update failed."
            } else {
                why
            };
            toast_error(engine, title, why);
        }
        if let Some(done) = done {
            done(self, engine, outcome.failed.is_empty());
        }
    }

    /// A sign-in call for one instance at a time; its failure shows on the
    /// card.
    fn call(
        &mut self,
        engine: &Engine,
        instance_id: &str,
        method: &str,
        payload: Json,
        failure: &str,
    ) {
        if self.busy.contains(instance_id) || self.followed.is_empty() {
            return;
        }
        self.busy.insert(instance_id.to_owned());
        self.auth_error.remove(instance_id);
        self.publish(engine);
        let following = self.following;
        let me = self.me.clone();
        let id = instance_id.to_owned();
        let failure = failure.to_owned();
        self.mc.call(
            &self.followed,
            method,
            payload,
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    if c.following != following {
                        return;
                    }
                    c.busy.remove(&id);
                    if let Err(error) = result {
                        c.auth_error.insert(id, error_text(&error, &failure));
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    /// The models list: what each can do, this device's favourites and
    /// hidden ones, and the filter typed over it; with how many are
    /// favourites and hidden.
    fn models(&self, engine: &Engine, provider: &Json) -> (Vec<Json>, usize, usize) {
        let instance_id = str_at(provider, "instanceId");
        let device = Json::Object(Settings::of(engine).device());
        let preference = at(at(&device, "providerModelPreferences"), instance_id);
        let order = array_at(preference, "modelOrder");
        let favorites: HashSet<&str> = array_at(&device, "favorites")
            .iter()
            .filter(|f| str_at(f, "provider") == instance_id)
            .map(|f| str_at(f, "model"))
            .collect();
        let hidden: HashSet<&str> = array_at(preference, "hiddenModels")
            .iter()
            .map(|h| h.as_str().unwrap_or_default())
            .collect();
        let filter = self
            .model_filter
            .get(instance_id)
            .map(|f| f.trim().to_lowercase())
            .unwrap_or_default();
        let (mut favorite_count, mut hidden_count) = (0, 0);
        let mut models = Vec::new();
        for model in array_at(provider, "models") {
            let slug = str_at(model, "slug");
            let name = str_at(model, "name");
            let is_favorite = favorites.contains(slug);
            let is_hidden = hidden.contains(slug);
            favorite_count += usize::from(is_favorite);
            hidden_count += usize::from(is_hidden);
            if !filter.is_empty()
                && !slug.to_lowercase().contains(&filter)
                && !name.to_lowercase().contains(&filter)
            {
                continue;
            }
            models.push(json!({
                "slug": slug,
                "name": name,
                "labels": model_labels(model),
                "favorite": is_favorite,
                "hidden": is_hidden,
            }));
        }
        // In this device's order (providerModelPreferences.modelOrder).
        let rank = |model: &Json| {
            order
                .iter()
                .position(|o| o.as_str() == Some(str_at(model, "slug")))
                .unwrap_or(usize::MAX)
        };
        models.sort_by_key(rank);
        (models, favorite_count, hidden_count)
    }

    fn entry(&self, engine: &Engine, provider: &Json) -> Map<String, Json> {
        let instance_id = str_at(provider, "instanceId");
        let driver = str_at(provider, "driver");
        let auth = at(provider, "auth");
        let (headline, detail) = summary(provider);
        let (models, favorite_count, hidden_count) = self.models(engine, provider);
        let reported = array_at(provider, "models").len();
        let mut model_summary = if reported == 1 {
            "1 model".to_owned()
        } else {
            format!("{reported} models")
        };
        if favorite_count > 0 {
            model_summary += &format!(
                " · {favorite_count} favorite{}",
                if favorite_count == 1 { "" } else { "s" }
            );
        }
        if hidden_count > 0 {
            model_summary += &format!(" · {hidden_count} hidden");
        }
        let update_status = str_at(at(provider, "updateState"), "status");
        let updating = self.updating.contains(instance_id)
            || update_status == "queued"
            || update_status == "running";
        let name = match text(provider, "displayName") {
            name if !name.is_empty() => name,
            _ => drivers::find(driver)
                .map(|d| d.label.to_owned())
                .unwrap_or_else(|| driver.to_owned()),
        };
        let installable = installable(provider);
        let mut result = json!({
            "instanceId": instance_id,
            "driver": driver,
            "name": name,
            "version": version_label(&text(provider, "version")),
            "enabled": bool_at(provider, "enabled"),
            "installed": bool_at(provider, "installed"),
            "status": str_at(provider, "status"),
            "headline": headline,
            "detail": detail,
            "email": text(auth, "email"),
            "models": models,
            "modelCount": reported,
            "modelSummary": model_summary,
            "modelFilter": self.model_filter.get(instance_id).cloned().unwrap_or_default(),
            "advisory": advisory(provider),
            "canUpdate": updatable(provider),
            "installLabel": if installable.is_empty() { String::new() } else { format!("Install {}", version_label(&installable)) },
            "updating": updating,
            "account": Json::Null,
        });
        let Json::Object(result) = &mut result else {
            unreachable!("json! of an object")
        };
        self.configuration(result, instance_id, driver);
        result.insert("acp".into(), self.acp_entry(engine, provider));
        result.insert("runtime".into(), self.runtime_entry(provider));
        // A sign-in page the agent is waiting on (server.acceptAcpRegistryUrlAuth).
        let url_auth = at(auth, "action");
        result.insert(
            "urlAuth".into(),
            if str_at(url_auth, "elicitationId").is_empty() {
                Json::Null
            } else {
                json!({"message": str_at(url_auth, "message"), "url": str_at(url_auth, "url")})
            },
        );
        if signs_in(provider) {
            let account = self.account(engine, provider, result);
            result.insert("account".into(), account);
        }
        std::mem::take(result)
    }

    /// ProviderAuthenticationSection.
    fn account(&self, engine: &Engine, provider: &Json, result: &Map<String, Json>) -> Json {
        let instance_id = str_at(provider, "instanceId");
        let driver = str_at(provider, "driver");
        let auth = at(provider, "auth");
        let known = self.auth_state.contains_key(instance_id);
        let state = self.auth_state.get(instance_id).unwrap_or(&NULL);
        let phase = str_at(state, "phase");
        let interaction = at(state, "interaction");
        let interaction_type = str_at(interaction, "type");
        let active = matches!(phase, "starting" | "waiting" | "verifying");
        let auth_status = str_at(auth, "status");
        let signed_in =
            auth_status == "authenticated" || (auth_status == "unknown" && phase == "succeeded");
        let registry = driver == REGISTRY;
        let discovering =
            registry && known && !active && !signed_in && state.get("methods").is_none();
        let setup = at(provider, "setup");
        let external_setup = !active
            && !signed_in
            && ((setup.get("canAuthenticate").is_some() && !bool_at(setup, "canAuthenticate"))
                || (registry
                    && state
                        .get("methods")
                        .and_then(Json::as_array)
                        .is_some_and(Vec::is_empty)));
        // The MC refuses a browser sign-in while Cursor carries its own API key.
        let api_key = driver == "cursor"
            && result
                .get("secrets")
                .and_then(Json::as_array)
                .is_some_and(|secrets| {
                    secrets
                        .iter()
                        .any(|s| str_at(s, "name") == "CURSOR_API_KEY" && bool_at(s, "stored"))
                });
        let description = if api_key && !active {
            "Using CURSOR_API_KEY. Remove it from this provider's environment to use browser sign-in.".to_owned()
        } else if active {
            match (phase, interaction_type) {
                ("starting", _) => "Starting sign-in…",
                ("verifying", _) => "Checking your account…",
                (_, "terminal") if terminals::supported(engine) => "Complete sign-in in the terminal below.",
                (_, "terminal") => {
                    "This sign-in continues in a terminal, which this build of HAL-C2 does not have. Cancel it and sign in from HAL-C2 on a computer."
                }
                (_, "credentials") => "Enter your credentials below.",
                _ => "Finish signing in in your browser.",
            }
            .to_owned()
        } else if signed_in {
            "Signed in.".to_owned()
        } else if discovering {
            "Discovering sign-in methods…".to_owned()
        } else if external_setup {
            "No in-app sign-in advertised. Follow the provider's docs to finish setup.".to_owned()
        } else {
            format!("Sign in on {}.", self.label(engine, &self.followed))
        };
        let busy = self.busy.contains(instance_id);
        let can_logout = match auth.get("canLogout") {
            Some(value) => value.as_bool().unwrap_or(false),
            None => bool_at(setup, "canAuthenticate"),
        };
        let url = match interaction_type {
            "browser" | "deviceCode" => str_at(interaction, "url"),
            _ => str_at(state, "authorizationUrl"),
        };
        // The methods to choose from, when there is a choice.
        let offered = array_at(state, "methods");
        let methods: Vec<Json> = if !active && offered.len() > 1 {
            offered
                .iter()
                .map(|m| json!({"id": str_at(m, "id"), "name": str_at(m, "name")}))
                .collect()
        } else {
            Vec::new()
        };
        // The agent's login terminal: its latest output and how far it has come.
        let terminal = if active && interaction_type == "terminal" && terminals::supported(engine) {
            let output = str_at(interaction, "output");
            let offset = at(interaction, "outputOffset")
                .as_f64()
                .unwrap_or(output.encode_utf16().count() as f64);
            json!({
                "key": format!("{}:{}", str_at(state, "flowId"), str_at(interaction, "id")),
                "output": output,
                "offset": offset,
            })
        } else {
            Json::Null
        };
        let credentials: Vec<Json> = if active && interaction_type == "credentials" {
            array_at(interaction, "fields")
                .iter()
                .map(|f| {
                    json!({"name": str_at(f, "name"), "label": str_at(f, "label"), "secret": bool_at(f, "secret")})
                })
                .collect()
        } else {
            Vec::new()
        };
        let mut error = self
            .auth_error
            .get(instance_id)
            .cloned()
            .unwrap_or_default();
        if error.is_empty() && phase == "failed" {
            error = str_at(state, "message").to_owned();
        }
        let can_authenticate = setup
            .get("canAuthenticate")
            .is_none_or(|c| c.as_bool().unwrap_or(false));
        json!({
            "description": description,
            "canSignIn": known && !busy && !active && !discovering && !external_setup && !api_key
                && can_authenticate && bool_at(provider, "enabled") && bool_at(provider, "installed"),
            "signInLabel": if signed_in {
                "Change account"
            } else if phase == "failed" || phase == "cancelled" {
                "Retry sign-in"
            } else {
                "Sign in"
            },
            "canCancel": !busy && active && !str_at(state, "flowId").is_empty(),
            "canSignOut": known && !busy && !active && signed_in && can_logout,
            "url": if active { url } else { "" },
            "userCode": if interaction_type == "deviceCode" { str_at(interaction, "userCode") } else { "" },
            "error": error,
            "methods": methods,
            "terminal": terminal,
            "credentials": credentials,
            "acceptsCallback": active && !url.is_empty() && if interaction_type == "browser" {
                bool_at(interaction, "acceptsCallback")
            } else {
                empty(interaction)
            },
            "docsUrl": if external_setup { str_at(setup, "documentationUrl") } else { "" },
        })
    }

    /// The provider health check row: the interval the MC uses and its
    /// preset.
    fn health(&self) -> Json {
        let Some(settings) = self.shown_settings().filter(|_| self.open) else {
            return Json::Null;
        };
        json!({
            "seconds": health_seconds(&settings),
            "defaultSeconds": preset_health_seconds(base_profile(at(&settings, "backgroundActivity"))),
            "step": 30,
        })
    }

    /// The environment's usage-limit hubs, named by their label or else the
    /// host the MC names them by.
    fn hubs(&self) -> Json {
        let Some(settings) = self.shown_settings().filter(|_| self.open) else {
            return Json::Null;
        };
        let hubs: Vec<Json> = object_at(&settings, "usageLimitSources")
            .iter()
            .map(|(id, hub)| {
                let url = str_at(hub, "url");
                let mut name = str_at(hub, "label").trim().to_owned();
                if name.is_empty() {
                    name = authority(url);
                }
                if name.is_empty() {
                    name = url.to_owned();
                }
                let mut description = vec!["CLI Proxy"];
                if !at(hub, "enabled").as_bool().unwrap_or(true) {
                    description.push("Disabled");
                }
                if name != url {
                    description.push(url);
                }
                json!({"id": id, "label": name, "description": description.join(" · ")})
            })
            .collect();
        Json::Array(hubs)
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let local = self.mc.environment();
        let mut ids = store::with(engine, |s| s.environments());
        // An environment several cluster MCs serve.
        let mut seen = HashSet::new();
        ids.retain(|id| seen.insert(id.clone()));
        // This machine first, the others by name.
        let labels: HashMap<String, String> = ids
            .iter()
            .map(|id| (id.clone(), self.label(engine, id).to_lowercase()))
            .collect();
        ids.sort_by(|a, b| {
            (*b == local)
                .cmp(&(*a == local))
                .then_with(|| crate::sidebar_model::locale_compare(&labels[a], &labels[b]))
        });
        let environments: Vec<Json> = ids
            .iter()
            .map(|id| {
                json!({
                    "id": id,
                    "label": self.label(engine, id),
                    "local": *id == local,
                    "online": store::with(engine, |s| s.environment_online(id)),
                })
            })
            .collect();
        let environment = self.chosen(engine);
        let (status, title, description) = if environment.is_empty() {
            (
                "none",
                "No connected devices".to_owned(),
                "Connect an execution environment before configuring providers.".to_owned(),
            )
        } else if !store::with(engine, |s| s.environment_online(&environment)) {
            (
                "offline",
                "Could not connect to this device".to_owned(),
                "Reconnect this device to set up its provider, or select another device."
                    .to_owned(),
            )
        } else {
            match &self.providers {
                None => (
                    "loading",
                    "Loading provider settings".to_owned(),
                    format!(
                        "Waiting for {}'s configuration.",
                        self.label(engine, &environment)
                    ),
                ),
                Some(providers) if providers.is_empty() => (
                    "ready",
                    "No providers".to_owned(),
                    format!("{} reports no providers.", self.label(engine, &environment)),
                ),
                Some(_) => ("ready", String::new(), String::new()),
            }
        };
        let ready = status == "ready";
        let mut providers = Vec::new();
        if self.open
            && ready
            && let Some(listed) = &self.providers
        {
            providers.extend(listed.iter().map(|p| Json::Object(self.entry(engine, p))));
            providers.extend(self.pending_entries(engine));
        }
        // When the environment last checked its providers: the latest of their checks.
        let checked_at = match &self.providers {
            Some(listed) if ready => latest_check(listed)
                .map(|at| at.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string())
                .unwrap_or_default(),
            _ => String::new(),
        };
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "open": self.open,
                "environmentId": environment,
                "environments": environments,
                "status": status,
                "title": title,
                "description": description,
                "refreshing": self.refreshing > 0,
                "checkedAt": checked_at,
                "providers": providers,
                "health": self.health(),
                "hubs": self.hubs(),
                "wizard": self.wizard_entry(),
            }),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_labels() {
        assert_eq!(version_label(""), "");
        assert_eq!(version_label("unknown"), "");
        assert_eq!(version_label("1.2.3"), "v1.2.3");
        assert_eq!(version_label("v1.2.3"), "v1.2.3");
        assert_eq!(version_label("agy_acp_server_20260102_7"), "2026-01-02");
        assert_eq!(
            version_label("agy_acp_server_20260102_7_rc1"),
            "2026-01-02 rc1"
        );
        assert_eq!(
            version_label("agy_acp_server_2026010_7"),
            "agy_acp_server_2026010_7"
        );
    }

    #[test]
    fn hub_ids() {
        assert_eq!(
            hub_id("https://Hub.Example.com:8317/x"),
            "cliproxy-hub.example.com-8317"
        );
        assert_eq!(hub_id("not a url"), "cliproxy-not-a-url");
        assert_eq!(hub_id("http://user@h_o_st/"), "cliproxy-user-h-o-st");
        assert_eq!(hub_id("://"), "cliproxy-hub");
    }

    #[test]
    fn health_intervals() {
        assert_eq!(health_seconds(&json!({})), 300);
        let custom = json!({"backgroundActivity": {"profile": "custom", "baseProfile": "performance", "overrides": {HEALTH_KEY: 120_000}}});
        assert_eq!(health_seconds(&custom), 120);
        let reset = with_health_seconds(custom, None);
        assert_eq!(health_seconds(&reset), 60);
        let set = with_health_seconds(
            json!({"backgroundActivity": {"profile": "battery-saver"}}),
            Some(45),
        );
        assert_eq!(
            set["backgroundActivity"],
            json!({"schemaVersion": 1, "profile": "custom", "baseProfile": "battery-saver", "overrides": {HEALTH_KEY: 45_000}})
        );
    }

    #[test]
    fn summaries() {
        let p = json!({"enabled": true, "installed": true, "auth": {"status": "authenticated", "type": "apiKey"}});
        assert_eq!(summary(&p).0, "Authenticated · apiKey");
        let p = json!({"enabled": false, "installed": true});
        assert_eq!(
            summary(&p),
            (
                "Disabled".into(),
                "This provider is installed but disabled for new sessions in HAL-C2.".into()
            )
        );
        let p =
            json!({"enabled": true, "installed": true, "status": "warning", "message": " Odd "});
        assert_eq!(summary(&p), ("Needs attention".into(), "Odd".into()));
    }

    #[test]
    fn advisories() {
        let behind = json!({"enabled": true, "versionAdvisory": {"status": "behind_latest", "latestVersion": "2.0.0", "message": "Update available: run it", "updateCommand": "npm i -g x", "canUpdate": true}});
        let a = advisory(&behind);
        assert_eq!(a["title"], "Update available");
        assert_eq!(a["detail"], "run it");
        assert_eq!(a["updateCommand"], "npm i -g x");
        assert!(updatable(&behind));
        let graceful = json!({"enabled": true, "compatibilityAdvisory": {"status": "graceful", "recommendedVersion": "1.5.0", "message": "Old"}, "versionAdvisory": {"canInstallVersion": true, "updateCommand": "x"}});
        let a = advisory(&graceful);
        assert_eq!(a["title"], "Limited support");
        assert_eq!(a["targetVersion"], "1.5.0");
        assert_eq!(a["updateCommand"], Json::Null);
        assert_eq!(a["strong"], false);
        assert_eq!(installable(&graceful), "1.5.0");
        let current = json!({"enabled": true, "versionAdvisory": {"status": "current"}});
        assert_eq!(advisory(&current), Json::Null);
    }

    #[test]
    fn check_times() {
        let providers = [
            json!({"checkedAt": "2026-01-02T03:04:05.678Z"}),
            json!({"checkedAt": "2026-01-02T05:04:05+01:00"}),
            json!({"checkedAt": "garbage"}),
        ];
        let latest = latest_check(&providers).unwrap();
        assert_eq!(
            latest.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string(),
            "2026-01-02T04:04:05.000Z"
        );
    }

    #[test]
    fn inputs_read_as_qvariant_does() {
        let p = json!({"n": 2.6, "s": "7", "b": "false", "t": 1});
        assert_eq!(input_int(&p, "n"), 3);
        assert_eq!(input_int(&p, "s"), 7);
        assert!(!input_bool(&p, "b"));
        assert!(input_bool(&p, "t"));
        assert_eq!(input_string(&p, "t"), "1");
        assert_eq!(input_string(&p, "n"), "2.6");
    }
}
