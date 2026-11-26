//! `maintenance`, mobile-qt's Maintenance: the phone's care of the
//! environments it reaches (upstream T3 Code's environment detail
//! screen, and the TUI's Updates page): each machine's HAL-C2
//! version against this app's and the newest release on the channel
//! it follows, the update to that version, and the enabled
//! providers on it with their updates. Only while the phone is
//! connected and its session may operate
//! (`orchestration:operate`); otherwise it says why. The desktop's
//! ServerUpdates is the same machines and paths for its own page;
//! the phone's adds the release index, the providers and the
//! reconnect watch, as its C++ had them.
//!
//! Publishes `maintenance`:
//!   {appVersion,
//!    machines: [{environmentId, label, version, online, local, blocked,
//!                path: update | desktop | desktop-manual | command,
//!                target, command, updating, outcome, release,
//!                providers: [...], providersError}],
//!    updatable, groups: [{driver, name, count}], confirm, message}
//!
//! Actions: `maintenance.open`, `maintenance.close`,
//! `maintenance.check {environment}`, `maintenance.update
//! {environment}`, `maintenance.updateAll`, `maintenance.confirm`,
//! `maintenance.cancel`, `maintenance.copyCommand {environment}`,
//! `maintenance.refreshProviders {environment}`,
//! `maintenance.updateProvider {environment, instanceId}` and
//! `maintenance.updateProviders {driver}`.
//!
//! [`Core`] is the state the published view is built from, with no
//! engine in it; the controller owns the session and release reads,
//! the update calls and the reconnect watch.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::Arc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller::{self, Controller, Init, Me};
use hal_c2_shell::controllers::connection_health::{ConnectionHealth, server_behind};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Mc, SubId};
use hal_c2_shell::schedule::{self, Held};
use hal_c2_shell::store;
use ljos::prelude::Engine;
use serde_json::{Map, json};

const KEY: &str = "maintenance";
const OPERATE: &str = "orchestration:operate";
const RELEASE_INDEX: &str =
    "https://api.github.com/repos/hal-c2/hal-c2/releases?per_page=100&page=";
const TAG_PREFIX: &str = "mc-v";
const PAGE_SIZE: usize = 100;
const RECONNECT_DEADLINE_MS: u64 = 180_000;

/// What a machine's host lets the phone do about a server behind it
/// (apps/tui updatePath).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Path {
    Update,
    Desktop,
    DesktopManual,
    Command,
}

impl Path {
    pub fn name(self) -> &'static str {
        match self {
            Path::Update => "update",
            Path::Desktop => "desktop",
            Path::DesktopManual => "desktop-manual",
            Path::Command => "command",
        }
    }
}

pub fn path_of(capabilities: &Map<String, Json>) -> Path {
    let Some(self_update) = capabilities.get("serverSelfUpdate").and_then(Json::as_str) else {
        return Path::Command;
    };
    if self_update != "desktop-managed" {
        return Path::Update;
    }
    if capabilities
        .get("desktopAppUpdate")
        .and_then(Json::as_bool)
        .unwrap_or(false)
    {
        Path::Desktop
    } else {
        Path::DesktopManual
    }
}

/// The channel a HAL-C2 version is on: "nightly", "preview" or
/// "stable" (`<base>-(nightly|preview).<yyyymmdd>.<n>`).
pub fn channel_of(version: &str) -> &'static str {
    let version = version.trim();
    for channel in ["nightly", "preview"] {
        let Some((base, dated)) = version.split_once(&format!("-{channel}.")) else {
            continue;
        };
        if base.is_empty() || base.contains(['-', '+']) {
            continue;
        }
        let mut parts = dated.splitn(2, '.');
        let date = parts.next().unwrap_or_default();
        let n = parts.next().unwrap_or_default();
        if date.len() == 8
            && date.bytes().all(|b| b.is_ascii_digit())
            && !n.is_empty()
            && n.bytes().all(|b| b.is_ascii_digit())
            && parts.next().is_none()
        {
            return if channel == "nightly" {
                "nightly"
            } else {
                "preview"
            };
        }
    }
    "stable"
}

/// The newest release of the index page on `channel` (tags
/// `mc-v<version>`, drafts skipped), or nothing when the page has none.
pub fn newest_on(releases: &[Json], channel: &str) -> Option<String> {
    for release in releases {
        if release
            .get("draft")
            .and_then(Json::as_bool)
            .unwrap_or(false)
        {
            continue;
        }
        let tag = release
            .get("tag_name")
            .and_then(Json::as_str)
            .unwrap_or_default();
        let Some(version) = tag.strip_prefix(TAG_PREFIX) else {
            continue;
        };
        if channel_of(version) == channel {
            return Some(version.to_owned());
        }
    }
    None
}

fn text_at(object: &Map<String, Json>, path: &str) -> String {
    let mut value = object as &Map<String, Json>;
    let mut parts = path.split('.');
    let last = parts.next_back().unwrap_or_default();
    for part in parts {
        let Some(next) = value.get(part).and_then(Json::as_object) else {
            return String::new();
        };
        value = next;
    }
    value
        .get(last)
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn provider_updating(provider: &Map<String, Json>) -> bool {
    matches!(
        text_at(provider, "updateState.status").as_str(),
        "queued" | "running"
    )
}

/// A provider the phone offers to update
/// (canUpdateEnvironmentProvider): installed, available, behind a
/// latest release that works, updatable by its MC, and not already
/// updating.
pub fn can_update_provider(provider: &Map<String, Json>) -> bool {
    let compatibility = text_at(provider, "compatibilityAdvisory.latestVersionStatus");
    let advisory = provider
        .get("versionAdvisory")
        .and_then(Json::as_object)
        .cloned()
        .unwrap_or_default();
    provider
        .get("installed")
        .and_then(Json::as_bool)
        .unwrap_or(true)
        && provider.get("availability").and_then(Json::as_str) != Some("unavailable")
        && advisory.get("status").and_then(Json::as_str) == Some("behind_latest")
        && advisory
            .get("canUpdate")
            .and_then(Json::as_bool)
            .unwrap_or(false)
        && !advisory
            .get("latestVersion")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .is_empty()
        && compatibility != "broken"
        && compatibility != "unsupported"
        && !provider_updating(provider)
}

/// What a finished provider update came to (apps/tui providerOutcome).
pub fn provider_outcome(provider: &Map<String, Json>) -> String {
    let state = provider
        .get("updateState")
        .and_then(Json::as_object)
        .cloned()
        .unwrap_or_default();
    match state.get("status").and_then(Json::as_str) {
        Some("succeeded") => "Updated".into(),
        Some("unchanged") => "Already up to date".into(),
        _ => {
            let message = state
                .get("message")
                .and_then(Json::as_str)
                .unwrap_or_default();
            format!(
                "Failed: {}",
                if message.is_empty() {
                    "the update did not finish."
                } else {
                    message
                }
            )
        }
    }
}

/// packages/contracts PROVIDER_DISPLAY_NAMES.
pub fn provider_name(provider: &Map<String, Json>) -> String {
    let shown = provider
        .get("displayName")
        .and_then(Json::as_str)
        .unwrap_or_default();
    if !shown.is_empty() {
        return shown.to_owned();
    }
    let driver = provider
        .get("driver")
        .and_then(Json::as_str)
        .unwrap_or_default();
    match driver {
        "antigravity" => "Antigravity",
        "codex" => "Codex",
        "claudeAgent" => "Claude",
        "cursor" => "Cursor",
        "grok" => "Grok",
        "acpRegistry" => "ACP Registry",
        "pi" => "Pi",
        "muse" => "Muse Code",
        "opencode" => "OpenCode",
        other => return other.to_owned(),
    }
    .to_owned()
}

fn update_command(version: &str) -> String {
    format!("npx hal-c2@{version}")
}

fn provider_key(environment_id: &str, instance_id: &str) -> String {
    format!("{environment_id}\n{instance_id}")
}

/// One machine the phone reaches, as the store and client say it is.
#[derive(Clone, Debug, Default)]
pub struct Machine {
    pub environment_id: String,
    pub label: String,
    pub version: String,
    pub online: bool,
    pub local: bool,
    pub capabilities: Map<String, Json>,
}

#[derive(Clone, Debug, Default)]
pub struct Release {
    pub checking: bool,
    pub text: String,
    pub available: String,
}

#[derive(Clone, Debug, Default)]
pub struct Outcome {
    pub ok: bool,
    pub text: String,
}

/// The session's word on operating: unknown until read, then may or
/// may not.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Session {
    #[default]
    Unknown,
    Reading,
    May,
    MayNot,
    Failed,
}

/// What a server update the MC answered waits on: its deadline's
/// run, and its config subscription.
struct Waiting {
    run: u64,
    timer: Held,
    subscription: Option<SubId>,
}

/// Maintenance's state over the machines: what each check, update
/// and provider read last said. The published view is built from it
/// and the machines the store has now.
#[derive(Default)]
pub struct Core {
    pub session: Session,
    /// The session read in flight: a read answers only while it is
    /// still this one (see [`Core::forget_session`]).
    pub session_read: u64,
    /// Other machines' providers, as `server.refreshProviders` last
    /// answered.
    pub providers: HashMap<String, Vec<Json>>,
    pub provider_errors: HashMap<String, String>,
    pub releases: HashMap<String, Release>,
    /// Server updates running, by environment, and the version each left.
    pub updating: HashMap<String, String>,
    /// Server updates the MC answered, until the machine is back on
    /// another version.
    pub reconnecting: HashMap<String, String>,
    /// Machines it stopped waiting for, by the version they left.
    pub gave_up_on: HashMap<String, String>,
    pub outcomes: HashMap<String, Outcome>,
    /// Provider updates running ("<environment>\n<instance>"), and
    /// how each ended.
    pub provider_updates: HashSet<String>,
    pub provider_outcomes: HashMap<String, Outcome>,
    /// The machines waiting on the user's word that their desktop
    /// apps relaunch.
    pub confirming: Vec<String>,
    pub confirm_text: String,
    pub message: Option<Outcome>,
}

impl Core {
    /// Start reading the session; the read's number.
    pub fn begin_session_read(&mut self) -> u64 {
        self.session = Session::Reading;
        self.session_read += 1;
        self.session_read
    }

    /// Another connection may be another session: forget this one,
    /// and a read started for it no longer answers.
    pub fn forget_session(&mut self) {
        self.session_read += 1;
        self.session = Session::Unknown;
    }

    /// Whether `read` is still the session read in flight.
    pub fn session_read_is_current(&self, read: u64) -> bool {
        read == self.session_read
    }

    /// Why nothing can be started on the machine, "" when it can.
    pub fn blocked(&self, machine: &Machine, ready: bool) -> String {
        if !ready || !machine.online {
            return "Connect this environment to manage it.".into();
        }
        match self.session {
            Session::May => String::new(),
            Session::MayNot => {
                "This connection does not have permission to manage the environment.".into()
            }
            Session::Failed => "Could not verify your permissions. Reconnect to try again.".into(),
            Session::Unknown | Session::Reading => "Checking permissions…".into(),
        }
    }

    pub fn target(&self, machine: &Machine, app_version: &str) -> String {
        // A cached release counts only while it is still newer:
        // another client may have moved the machine past it.
        if let Some(release) = self.releases.get(&machine.environment_id)
            && !release.available.is_empty()
            && channel_of(&release.available) == channel_of(&machine.version)
            && server_behind(&release.available, &machine.version)
        {
            return release.available.clone();
        }
        if server_behind(app_version, &machine.version) {
            return app_version.to_owned();
        }
        String::new()
    }

    /// The machine's enabled providers: its own MC's from its
    /// config, the others' as last refreshed. A provider turned off
    /// is not this environment's to update.
    pub fn providers_of(&self, machine: &Machine, local_providers: &[Json]) -> Vec<Json> {
        let all: &[Json] = if machine.local {
            local_providers
        } else {
            self.providers
                .get(&machine.environment_id)
                .map_or(&[], Vec::as_slice)
        };
        all.iter()
            .filter(|provider| {
                provider
                    .get("enabled")
                    .and_then(Json::as_bool)
                    .unwrap_or(true)
            })
            .cloned()
            .collect()
    }

    pub fn updatable(&self, machines: &[Machine], app_version: &str, ready: bool) -> Vec<Machine> {
        machines
            .iter()
            .filter(|machine| {
                let path = path_of(&machine.capabilities);
                self.blocked(machine, ready).is_empty()
                    && !self.target(machine, app_version).is_empty()
                    && !self.updating.contains_key(&machine.environment_id)
                    && !self.reconnecting.contains_key(&machine.environment_id)
                    && matches!(path, Path::Update | Path::Desktop)
            })
            .cloned()
            .collect()
    }

    /// A server update the MC refused. A success a late reconnect
    /// settled while this attempt waited stands.
    pub fn update_failed(&mut self, environment_id: &str, label: &str, why: &str) {
        if self.outcomes.get(environment_id).is_some_and(|o| o.ok) {
            return;
        }
        let outcome = Outcome {
            ok: false,
            text: format!("{label} update failed: {why}"),
        };
        self.outcomes
            .insert(environment_id.to_owned(), outcome.clone());
        self.message = Some(outcome);
    }

    /// A machine back on another version settles the update that
    /// waited for it; a slow one still counts after its failure.
    /// Whether anything settled.
    pub fn settle(&mut self, machines: &[Machine]) -> Vec<String> {
        let mut settled = Vec::new();
        let came_back = |core: &mut Core, environment_id: &str, left: &str| -> bool {
            let Some(now) = machines
                .iter()
                .find(|machine| machine.environment_id == environment_id)
            else {
                return false;
            };
            if !now.online || now.version.is_empty() || now.version == left {
                return false;
            }
            let outcome = Outcome {
                ok: true,
                text: format!(
                    "{} was updated and reconnected on {}.",
                    now.label, now.version
                ),
            };
            core.outcomes
                .insert(environment_id.to_owned(), outcome.clone());
            core.message = Some(outcome);
            core.releases.remove(environment_id);
            true
        };
        for environment_id in self.reconnecting.keys().cloned().collect::<Vec<_>>() {
            let left = self.reconnecting[&environment_id].clone();
            if came_back(self, &environment_id, &left) {
                settled.push(environment_id);
            }
        }
        for environment_id in self.gave_up_on.keys().cloned().collect::<Vec<_>>() {
            let left = self.gave_up_on[&environment_id].clone();
            if came_back(self, &environment_id, &left) {
                self.gave_up_on.remove(&environment_id);
            }
        }
        settled
    }

    /// The machines `update` acts on at once, split by what waits
    /// for the user's word; the confirm text when there are desktops.
    pub fn start_updates(
        &mut self,
        machines: &[Machine],
        environments: &[String],
        app_version: &str,
        ready: bool,
    ) -> Vec<String> {
        let mut desktops: Vec<String> = Vec::new();
        let mut labels: Vec<String> = Vec::new();
        let mut at_once: Vec<String> = Vec::new();
        for environment_id in environments {
            let Some(machine) = machines
                .iter()
                .find(|machine| &machine.environment_id == environment_id)
            else {
                continue;
            };
            if !self.blocked(machine, ready).is_empty()
                || self.target(machine, app_version).is_empty()
            {
                continue;
            }
            match path_of(&machine.capabilities) {
                Path::Desktop => {
                    desktops.push(environment_id.clone());
                    labels.push(machine.label.clone());
                }
                Path::Update => at_once.push(environment_id.clone()),
                _ => {}
            }
        }
        if !desktops.is_empty() {
            // A desktop app closes to update: the user says so first.
            self.confirm_text = if desktops.len() == 1 {
                format!(
                    "Update the HAL-C2 desktop app that runs {}? It will close and relaunch on that machine.",
                    labels[0]
                )
            } else {
                format!(
                    "Update the HAL-C2 desktop apps on {}? They will close and relaunch on those machines.",
                    labels.join(", ")
                )
            };
            self.confirming = desktops;
        }
        at_once
    }

    /// What the bricks read.
    pub fn state(
        &self,
        machines: &[Machine],
        app_version: &str,
        ready: bool,
        local_providers: &[Json],
    ) -> Json {
        let mut published: Vec<Json> = Vec::new();
        let mut groups: Vec<(String, Map<String, Json>)> = Vec::new();
        for machine in machines {
            let why = self.blocked(machine, ready);
            let mut providers: Vec<Json> = Vec::new();
            for provider in self.providers_of(machine, local_providers) {
                let provider = provider.as_object().cloned().unwrap_or_default();
                let instance_id = provider
                    .get("instanceId")
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let key = provider_key(&machine.environment_id, &instance_id);
                let running = self.provider_updates.contains(&key) || provider_updating(&provider);
                let can_update = why.is_empty() && !running && can_update_provider(&provider);
                let state = provider
                    .get("updateState")
                    .and_then(Json::as_object)
                    .cloned()
                    .unwrap_or_default();
                let mut status = state
                    .get("message")
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_owned();
                let state_status = state
                    .get("status")
                    .and_then(Json::as_str)
                    .unwrap_or_default();
                if status.is_empty() && !state_status.is_empty() {
                    status = format!("Update {state_status}");
                }
                let outcome = self.provider_outcomes.get(&key);
                providers.push(json!({
                    "instanceId": instance_id,
                    "driver": provider.get("driver").and_then(Json::as_str).unwrap_or_default(),
                    "name": provider_name(&provider),
                    "version": text_at(&provider, "versionAdvisory.currentVersion"),
                    "latest": text_at(&provider, "versionAdvisory.latestVersion"),
                    "canUpdate": can_update,
                    "updating": running,
                    "status": status,
                    "outcome": if running { String::new() } else { outcome.map_or(String::new(), |o| o.text.clone()) },
                    "failed": !running && outcome.is_some_and(|o| !o.ok),
                }));
                if can_update {
                    let driver = provider
                        .get("driver")
                        .and_then(Json::as_str)
                        .unwrap_or_default()
                        .to_owned();
                    match groups.iter_mut().find(|(held, _)| *held == driver) {
                        Some((_, group)) => {
                            let count = group.get("count").and_then(Json::as_i64).unwrap_or(0) + 1;
                            group.insert("count".into(), json!(count));
                        }
                        None => {
                            let mut group = Map::new();
                            group.insert("driver".into(), json!(driver.clone()));
                            group.insert("name".into(), json!(provider_name(&provider)));
                            group.insert("count".into(), json!(1));
                            groups.push((driver, group));
                        }
                    }
                }
            }
            let version = self.target(machine, app_version);
            let release = self.releases.get(&machine.environment_id);
            let has_release = release.is_some_and(|r| r.checking || !r.text.is_empty());
            let outcome = self.outcomes.get(&machine.environment_id);
            published.push(json!({
                "environmentId": machine.environment_id,
                "label": machine.label,
                "version": machine.version,
                "online": machine.online,
                "local": machine.local,
                "blocked": why,
                "path": path_of(&machine.capabilities).name(),
                "target": version,
                "command": if version.is_empty() { String::new() } else { update_command(&version) },
                "updating": self.updating.contains_key(&machine.environment_id)
                    || self.reconnecting.contains_key(&machine.environment_id),
                "outcome": outcome.map(|o| json!({"ok": o.ok, "text": o.text})),
                "release": if has_release {
                    release.map(|r| json!({"checking": r.checking, "text": r.text, "available": r.available}))
                } else {
                    None
                },
                "providers": providers,
                "providersError": self.provider_errors.get(&machine.environment_id).cloned().unwrap_or_default(),
            }));
        }
        let several: Vec<Json> = groups
            .into_iter()
            .filter(|(_, group)| group.get("count").and_then(Json::as_i64).unwrap_or(0) > 1)
            .map(|(_, group)| Json::Object(group))
            .collect();
        json!({
            "appVersion": app_version,
            "machines": published,
            "updatable": self.updatable(machines, app_version, ready).len(),
            "groups": several,
            "confirm": if self.confirming.is_empty() {
                Json::Null
            } else {
                json!({"text": self.confirm_text})
            },
            "message": self.message.as_ref().map(|o| json!({"ok": o.ok, "text": o.text})),
        })
    }
}

/// Writes text to the clipboard; whether it landed.
pub type ClipboardWriter = Rc<dyn Fn(&Engine, &str) -> bool>;

/// Fetches one page of the release index, blocking (off the UI
/// thread): the body, or why not as it is told to the user.
pub type ReleaseFetch = Arc<dyn Fn(&str) -> Result<Vec<u8>, String> + Send + Sync>;

fn fetch_page(url: &str) -> Result<Vec<u8>, String> {
    hal_c2_mc::fetch(url, std::time::Duration::from_secs(15), 4 * 1024 * 1024)
}

/// The seams a test replaces: the app version, the clipboard, the
/// release index fetch, and the reconnect deadline.
#[derive(Default)]
struct Where {
    app_version: RefCell<Option<String>>,
    clipboard: RefCell<Option<ClipboardWriter>>,
    fetch: RefCell<Option<ReleaseFetch>>,
    release_index: RefCell<Option<String>>,
    reconnect_deadline_ms: RefCell<Option<u64>>,
}

pub fn set_app_version(engine: &Engine, version: &str) {
    *engine.extension::<Where>().app_version.borrow_mut() = Some(version.trim().to_owned());
}

pub fn set_clipboard_writer(engine: &Engine, write: impl Fn(&Engine, &str) -> bool + 'static) {
    *engine.extension::<Where>().clipboard.borrow_mut() = Some(Rc::new(write));
}

pub fn set_release_fetch(engine: &Engine, fetch: ReleaseFetch) {
    *engine.extension::<Where>().fetch.borrow_mut() = Some(fetch);
}

/// Where releases are listed; the page number is appended.
pub fn set_release_index(engine: &Engine, url: &str) {
    *engine.extension::<Where>().release_index.borrow_mut() = Some(url.to_owned());
}

/// How long an answered server update may take to come back on
/// another version.
pub fn set_reconnect_deadline(engine: &Engine, ms: u64) {
    *engine
        .extension::<Where>()
        .reconnect_deadline_ms
        .borrow_mut() = Some(ms);
}

pub struct Maintenance {
    bridge: Bridge,
    me: Me<Maintenance>,
    mc: Rc<dyn Mc>,
    core: Core,
    app_version: String,
    fetch: ReleaseFetch,
    release_index: String,
    write_clipboard: ClipboardWriter,
    reconnect_deadline_ms: u64,
    open: bool,
    waiting: HashMap<String, Waiting>,
    wait_run: u64,
    published: Json,
}

impl Controller for Maintenance {
    fn new(init: Init<'_, Self>) -> Self {
        let place = init.engine.extension::<Where>();
        let app_version = place
            .app_version
            .borrow()
            .clone()
            .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_owned());
        let fetch = place
            .fetch
            .borrow()
            .clone()
            .unwrap_or_else(|| Arc::new(fetch_page));
        let release_index = place
            .release_index
            .borrow()
            .clone()
            .unwrap_or_else(|| RELEASE_INDEX.to_owned());
        let write_clipboard = place.clipboard.borrow().clone().unwrap_or_else(|| {
            Rc::new(|engine: &Engine, text: &str| {
                ljos::prelude::Platform::of(engine)
                    .clipboard()
                    .set_text(ljos::prelude::ClipboardMode::Clipboard, text)
                    .is_ok()
            })
        });
        let reconnect_deadline_ms = place
            .reconnect_deadline_ms
            .borrow()
            .unwrap_or(RECONNECT_DEADLINE_MS);
        // Another connection may be another session.
        init.mc.on_ready_changed(Box::new({
            let me = init.me.clone();
            move |engine, ready| {
                me.run(engine, move |c: &mut Maintenance, engine| {
                    c.core.forget_session();
                    if ready && c.open {
                        c.read_session(engine);
                        c.read_providers(engine);
                    }
                    c.publish(engine);
                });
            }
        }));
        store::on_changed(init.engine, {
            let me = init.me.clone();
            move |engine| {
                me.run(engine, move |c: &mut Maintenance, engine| {
                    c.settle(engine);
                    c.publish(engine);
                });
            }
        });
        Settings::of(init.engine).on_config_changed({
            let me = init.me.clone();
            move |engine| {
                me.run(engine, move |c: &mut Maintenance, engine| c.publish(engine));
            }
        });
        Maintenance {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            core: Core::default(),
            app_version,
            fetch,
            release_index,
            write_clipboard,
            reconnect_deadline_ms,
            open: false,
            waiting: HashMap::new(),
            wait_run: 0,
            published: Json::Null,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("maintenance.") {
            return false;
        }
        let text = |key: &str| {
            payload
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let machines = self.machines(engine);
        let named = {
            let id = text("environment");
            machines.iter().find(|m| m.environment_id == id).cloned()
        };
        // Nothing is started where the phone cannot operate.
        let may = named
            .as_ref()
            .is_some_and(|m| self.core.blocked(m, self.mc.is_ready()).is_empty());
        match action {
            "maintenance.open" => {
                self.open = true;
                self.core.message = None;
                if matches!(self.core.session, Session::Unknown | Session::Failed) {
                    self.read_session(engine);
                }
                self.read_providers(engine);
            }
            "maintenance.close" => {
                self.open = false;
                self.core.confirming.clear();
            }
            "maintenance.check" => {
                if may {
                    self.check(engine, named.expect("may names a machine"));
                }
            }
            "maintenance.update" => {
                if may {
                    let id = named.expect("may names a machine").environment_id;
                    self.update(engine, &[id]);
                }
            }
            "maintenance.updateAll" => {
                let all: Vec<String> = self
                    .core
                    .updatable(&machines, &self.app_version.clone(), self.mc.is_ready())
                    .into_iter()
                    .map(|m| m.environment_id)
                    .collect();
                self.update(engine, &all);
            }
            "maintenance.confirm" => {
                let confirmed = std::mem::take(&mut self.core.confirming);
                for environment_id in confirmed {
                    let machines = self.machines(engine);
                    if let Some(machine) = machines
                        .iter()
                        .find(|m| m.environment_id == environment_id)
                        .filter(|m| self.core.blocked(m, self.mc.is_ready()).is_empty())
                        .cloned()
                    {
                        self.update_server(engine, &machine);
                    }
                }
            }
            "maintenance.cancel" => self.core.confirming.clear(),
            "maintenance.copyCommand" => {
                if let Some(machine) = &named {
                    self.copy_command(engine, machine);
                }
            }
            "maintenance.refreshProviders" => {
                if may {
                    let id = named.expect("may names a machine").environment_id;
                    self.refresh_providers(engine, &id, true);
                }
            }
            "maintenance.updateProvider" => {
                if may {
                    let machine = named.expect("may names a machine");
                    self.update_provider(engine, &machine, &text("instanceId"));
                }
            }
            "maintenance.updateProviders" => {
                let driver = text("driver");
                let local = self.local_providers(engine);
                for machine in self.machines(engine) {
                    if !self.core.blocked(&machine, self.mc.is_ready()).is_empty() {
                        continue;
                    }
                    for provider in self.core.providers_of(&machine, &local) {
                        let provider = provider.as_object().cloned().unwrap_or_default();
                        if provider.get("driver").and_then(Json::as_str) == Some(driver.as_str())
                            && can_update_provider(&provider)
                        {
                            let instance = provider
                                .get("instanceId")
                                .and_then(Json::as_str)
                                .unwrap_or_default()
                                .to_owned();
                            self.update_provider(engine, &machine, &instance);
                        }
                    }
                }
            }
            _ => return false,
        }
        self.publish(engine);
        true
    }
}

impl Maintenance {
    fn machines(&self, engine: &Engine) -> Vec<Machine> {
        let own = self.mc.environment();
        store::with(engine, |store| {
            let mut ids: Vec<String> = store
                .environments()
                .into_iter()
                .filter(|id| *id != own)
                .collect();
            // The environment the phone is paired with first, before
            // its MC's shell says it.
            if !own.is_empty() {
                ids.insert(0, own.clone());
            }
            let mut found = Vec::new();
            for id in ids {
                let descriptor = store.environment(&id);
                let get = |key: &str| {
                    descriptor
                        .get(key)
                        .and_then(Json::as_str)
                        .unwrap_or_default()
                        .to_owned()
                };
                let mut machine = Machine {
                    environment_id: id.clone(),
                    label: get("label"),
                    version: get("serverVersion").trim().to_owned(),
                    online: store.environment_online(&id),
                    local: id == own,
                    capabilities: descriptor
                        .get("capabilities")
                        .and_then(Json::as_object)
                        .cloned()
                        .unwrap_or_default(),
                };
                if machine.local {
                    let paired = &self.mc.status().descriptor;
                    if machine.label.is_empty() {
                        machine.label = paired
                            .get("label")
                            .and_then(Json::as_str)
                            .unwrap_or_default()
                            .to_owned();
                    }
                    if machine.version.is_empty() {
                        machine.version = paired
                            .get("serverVersion")
                            .and_then(Json::as_str)
                            .unwrap_or_default()
                            .trim()
                            .to_owned();
                    }
                    machine.online = self.mc.is_ready();
                }
                if machine.label.is_empty() {
                    machine.label = id.clone();
                }
                found.push(machine);
            }
            found
        })
    }

    fn machine(&self, engine: &Engine, environment_id: &str) -> Option<Machine> {
        if environment_id.is_empty() {
            return None;
        }
        self.machines(engine)
            .into_iter()
            .find(|m| m.environment_id == environment_id)
    }

    fn local_providers(&self, engine: &Engine) -> Vec<Json> {
        Settings::of(engine)
            .config()
            .get("providers")
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default()
    }

    fn read_session(&mut self, _engine: &Engine) {
        if !self.mc.is_ready() {
            return;
        }
        let read = self.core.begin_session_read();
        let me = self.me.clone();
        self.mc.get(
            "/api/auth/session",
            Box::new(move |engine, result| {
                me.run(engine, move |c: &mut Maintenance, engine| {
                    if !c.core.session_read_is_current(read) {
                        return;
                    }
                    c.core.session = match &result {
                        Ok(session) if session.as_object().is_some_and(|s| !s.is_empty()) => {
                            let scopes = session.get("scopes");
                            // An MC that lists no scopes checks each
                            // request itself.
                            let may = session
                                .get("authenticated")
                                .and_then(Json::as_bool)
                                .unwrap_or(true)
                                && scopes.is_none_or(|scopes| {
                                    !scopes.is_array()
                                        || scopes
                                            .as_array()
                                            .is_some_and(|list| list.iter().any(|s| s == OPERATE))
                                });
                            if may { Session::May } else { Session::MayNot }
                        }
                        _ => Session::Failed,
                    };
                    if c.open && c.core.session == Session::May {
                        c.read_providers(engine);
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    fn read_providers(&mut self, engine: &Engine) {
        // The MC needs orchestration:operate for the refresh: a
        // denied automatic call is no provider error to record.
        if !self.mc.is_ready() || self.core.session != Session::May {
            return;
        }
        for machine in self.machines(engine) {
            if !machine.local && machine.online {
                self.refresh_providers(engine, &machine.environment_id.clone(), false);
            }
        }
    }

    fn refresh_providers(&mut self, engine: &Engine, environment_id: &str, announce: bool) {
        let environment_id = environment_id.to_owned();
        let local = environment_id == self.mc.environment();
        let me = self.me.clone();
        let environment = environment_id.clone();
        self.mc.call(
            &environment,
            "server.refreshProviders",
            json!({}),
            Box::new(move |engine, result| {
                me.run(engine, move |c: &mut Maintenance, engine| {
                    match result {
                        Err(error) => {
                            c.core
                                .provider_errors
                                .insert(environment_id.clone(), error.message.clone());
                            if announce {
                                c.core.message = Some(Outcome {
                                    ok: false,
                                    text: error.message.clone(),
                                });
                            }
                        }
                        Ok(result) => {
                            c.core.provider_errors.remove(&environment_id);
                            // The MC's own come with its config, as
                            // they change.
                            if !local {
                                let providers = result
                                    .get("providers")
                                    .and_then(Json::as_array)
                                    .cloned()
                                    .unwrap_or_default();
                                c.core.providers.insert(environment_id.clone(), providers);
                            }
                            if announce {
                                c.core.message = Some(Outcome {
                                    ok: true,
                                    text: "Provider status refreshed.".into(),
                                });
                            }
                        }
                    }
                    c.publish(engine);
                });
            }),
        );
        let _ = engine;
    }

    fn check(&mut self, engine: &Engine, machine: Machine) {
        if self
            .core
            .releases
            .get(&machine.environment_id)
            .is_some_and(|release| release.checking)
        {
            return;
        }
        self.core.releases.insert(
            machine.environment_id.clone(),
            Release {
                checking: true,
                text: String::new(),
                available: String::new(),
            },
        );
        let channel = channel_of(&machine.version).to_owned();
        self.check_page(engine, machine, channel, 1);
        self.publish(engine);
    }

    fn check_page(&mut self, engine: &Engine, machine: Machine, channel: String, page: u32) {
        let machine_id = machine.environment_id.clone();
        let url = format!("{}{page}", self.release_index);
        let fetch = self.fetch.clone();
        let me = self.me.clone();
        let spawned = ljos::task::spawn(
            engine,
            move || fetch(&url),
            move |engine, result| {
                let (machine, channel) = (machine.clone(), channel.clone());
                me.run(engine, move |c: &mut Maintenance, engine| {
                    let mut release = Release::default();
                    match result.unwrap_or_else(|_| Err("could not start".into())) {
                        Err(why) => {
                            release.text = format!("Could not check releases ({why}). Try again.");
                        }
                        Ok(body) => {
                            let parsed: Option<Vec<Json>> =
                                serde_json::from_slice::<Json>(&body)
                                    .ok()
                                    .and_then(|value| value.as_array().cloned());
                            let Some(releases) = parsed else {
                                release.text =
                                    "Could not check releases (the release index answered something unreadable). Try again."
                                        .into();
                                c.core
                                    .releases
                                    .insert(machine.environment_id.clone(), release);
                                c.publish(engine);
                                return;
                            };
                            if let Some(newest) = newest_on(&releases, &channel) {
                                // Never back: an environment ahead of
                                // the newest release stays where it is.
                                if server_behind(&newest, &machine.version) {
                                    release.text = format!("Version {newest} is available.");
                                    release.available = newest;
                                } else {
                                    release.text = "You are up to date.".into();
                                }
                            } else if releases.len() >= PAGE_SIZE {
                                c.check_page(engine, machine, channel, page + 1);
                                return;
                            } else {
                                release.text = format!("No {channel} release was found.");
                            }
                        }
                    }
                    c.core
                        .releases
                        .insert(machine.environment_id.clone(), release);
                    c.publish(engine);
                });
            },
        );
        if spawned.is_err() {
            self.core.releases.insert(
                machine_id,
                Release {
                    checking: false,
                    text: "Could not check releases (could not start). Try again.".into(),
                    available: String::new(),
                },
            );
            self.publish(engine);
        }
    }

    fn update(&mut self, engine: &Engine, environments: &[String]) {
        let machines = self.machines(engine);
        let app_version = self.app_version.clone();
        let at_once =
            self.core
                .start_updates(&machines, environments, &app_version, self.mc.is_ready());
        for environment_id in at_once {
            if let Some(machine) = machines
                .iter()
                .find(|m| m.environment_id == environment_id)
                .cloned()
            {
                self.update_server(engine, &machine);
            }
        }
    }

    fn update_server(&mut self, engine: &Engine, machine: &Machine) {
        if self.core.updating.contains_key(&machine.environment_id)
            || self.core.reconnecting.contains_key(&machine.environment_id)
        {
            return;
        }
        let version = self.core.target(machine, &self.app_version.clone());
        if version.is_empty() {
            return;
        }
        self.core
            .updating
            .insert(machine.environment_id.clone(), machine.version.clone());
        // The late-reconnect record stays until the retry is
        // accepted: a rejected retry must not lose the first
        // update's coming back (the C++ dropped it here).
        self.core.outcomes.remove(&machine.environment_id);
        let me = self.me.clone();
        let machine = machine.clone();
        let environment = machine.environment_id.clone();
        self.mc.call(
            &environment,
            "server.updateServer",
            json!({"targetVersion": version}),
            Box::new(move |engine, result| {
                me.run(engine, move |c: &mut Maintenance, engine| {
                    let left = c
                        .core
                        .updating
                        .remove(&machine.environment_id)
                        .unwrap_or_default();
                    match result {
                        Err(error) => {
                            c.core.update_failed(
                                &machine.environment_id,
                                &machine.label,
                                &error.message,
                            );
                        }
                        Ok(result) => {
                            c.core.gave_up_on.remove(&machine.environment_id);
                            let token = result
                                .get("desktopUpdateToken")
                                .and_then(Json::as_str)
                                .unwrap_or_default()
                                .to_owned();
                            c.await_reconnect(engine, &machine, left, token);
                            c.settle(engine);
                        }
                    }
                    c.publish(engine);
                });
            }),
        );
        let _ = engine;
    }

    /// A server update the MC answered: done once the machine is
    /// back on another version.
    fn settle(&mut self, engine: &Engine) {
        let machines = self.machines(engine);
        for environment_id in self.core.settle(&machines) {
            self.end_reconnect(engine, &environment_id);
        }
    }

    /// Waits for the machine to come back, or to say the update it
    /// answered failed.
    fn await_reconnect(&mut self, engine: &Engine, machine: &Machine, left: String, token: String) {
        let environment_id = machine.environment_id.clone();
        self.core.reconnecting.insert(environment_id.clone(), left);
        self.wait_run += 1;
        let run = self.wait_run;
        let me = self.me.clone();
        let deadline = std::time::Duration::from_millis(self.reconnect_deadline_ms);
        let id_for_timer = environment_id.clone();
        let timer = schedule::after(
            engine,
            "maintenance reconnect",
            None,
            deadline,
            move |engine| {
                me.run(engine, move |c: &mut Maintenance, engine| {
                    if c.waiting.get(&id_for_timer).map(|w| w.run) != Some(run) {
                        return;
                    }
                    c.reconnect_failed(
                        engine,
                        &id_for_timer,
                        "it did not come back on a new version. Try again.",
                    );
                });
            },
        );
        let mut waiting = Waiting {
            run,
            timer: Held::default(),
            subscription: None,
        };
        waiting.timer.hold(engine, timer);
        // The reply to a desktop app's update only means ready to
        // install: its MC tells how an install that failed went, by
        // the token it answered with.
        if !token.is_empty() {
            let me = self.me.clone();
            let id = environment_id.clone();
            waiting.subscription = Some(self.mc.subscribe(
                json!({"type": "config", "environment": environment_id}),
                Box::new(move |engine, frame| {
                    let outcome = frame
                        .get("updateOutcome")
                        .and_then(Json::as_object)
                        .cloned()
                        .unwrap_or_default();
                    if outcome.get("id").and_then(Json::as_str) != Some(token.as_str())
                        || outcome.get("status").and_then(Json::as_str) == Some("committed")
                    {
                        return;
                    }
                    let reason = outcome
                        .get("reason")
                        .and_then(Json::as_str)
                        .unwrap_or_default()
                        .to_owned();
                    let id = id.clone();
                    me.run(engine, move |c: &mut Maintenance, engine| {
                        c.reconnect_failed(
                            engine,
                            &id,
                            if reason.is_empty() {
                                "the install failed."
                            } else {
                                &reason
                            },
                        );
                    });
                }),
                None,
            ));
        }
        self.waiting.insert(environment_id, waiting);
    }

    fn reconnect_failed(&mut self, engine: &Engine, environment_id: &str, why: &str) {
        let Some(left) = self.core.reconnecting.get(environment_id).cloned() else {
            return;
        };
        let label = self
            .machine(engine, environment_id)
            .map_or_else(|| environment_id.to_owned(), |m| m.label);
        let outcome = Outcome {
            ok: false,
            text: format!("{label} update failed: {why}"),
        };
        self.core
            .outcomes
            .insert(environment_id.to_owned(), outcome.clone());
        self.core.message = Some(outcome);
        self.core.gave_up_on.insert(environment_id.to_owned(), left);
        self.end_reconnect(engine, environment_id);
        self.publish(engine);
    }

    fn end_reconnect(&mut self, engine: &Engine, environment_id: &str) {
        self.core.reconnecting.remove(environment_id);
        if let Some(waiting) = self.waiting.remove(environment_id) {
            drop(waiting.timer);
            if let Some(subscription) = waiting.subscription {
                // Not from inside its own frame's handler: the
                // caller runs after it (Me::run), so this is safe.
                self.mc.unsubscribe(subscription);
            }
        }
        let _ = engine;
    }

    fn copy_command(&mut self, engine: &Engine, machine: &Machine) {
        let version = self.core.target(machine, &self.app_version.clone());
        if version.is_empty() {
            return;
        }
        let run = update_command(&version);
        self.core.message = Some(if (self.write_clipboard)(engine, &run) {
            Outcome {
                ok: true,
                text: format!("Update command copied. Run `{run}` on {}.", machine.label),
            }
        } else {
            Outcome {
                ok: false,
                text: format!("Run `{run}` on {}.", machine.label),
            }
        });
    }

    fn update_provider(&mut self, engine: &Engine, machine: &Machine, instance_id: &str) {
        let key = provider_key(&machine.environment_id, instance_id);
        if self.core.provider_updates.contains(&key) {
            return;
        }
        let local = self.local_providers(engine);
        let provider = self
            .core
            .providers_of(machine, &local)
            .into_iter()
            .filter_map(|p| p.as_object().cloned())
            .find(|p| p.get("instanceId").and_then(Json::as_str) == Some(instance_id));
        let Some(provider) = provider.filter(can_update_provider) else {
            return;
        };
        self.core.provider_updates.insert(key.clone());
        self.core.provider_outcomes.remove(&key);
        let request = json!({
            "provider": provider.get("driver").cloned().unwrap_or(Json::Null),
            "instanceId": instance_id,
        });
        let me = self.me.clone();
        let machine = machine.clone();
        let instance = instance_id.to_owned();
        let environment = machine.environment_id.clone();
        self.mc.call(
            &environment,
            "server.updateProvider",
            request,
            Box::new(move |engine, result| {
                me.run(engine, move |c: &mut Maintenance, engine| {
                    c.core.provider_updates.remove(&key);
                    match result {
                        Err(error) => {
                            c.core.provider_outcomes.insert(
                                key.clone(),
                                Outcome {
                                    ok: false,
                                    text: format!("Failed: {}", error.message),
                                },
                            );
                        }
                        Ok(result) => {
                            let providers = result
                                .get("providers")
                                .and_then(Json::as_array)
                                .cloned()
                                .unwrap_or_default();
                            if !machine.local {
                                c.core
                                    .providers
                                    .insert(machine.environment_id.clone(), providers.clone());
                            }
                            let updated = providers
                                .iter()
                                .filter_map(|p| p.as_object())
                                .find(|p| {
                                    p.get("instanceId").and_then(Json::as_str)
                                        == Some(instance.as_str())
                                })
                                .cloned()
                                .unwrap_or_default();
                            let status = text_at(&updated, "updateState.status");
                            c.core.provider_outcomes.insert(
                                key.clone(),
                                Outcome {
                                    ok: matches!(status.as_str(), "succeeded" | "unchanged"),
                                    text: provider_outcome(&updated),
                                },
                            );
                        }
                    }
                    c.publish(engine);
                });
            }),
        );
        let _ = engine;
    }

    fn publish(&mut self, engine: &Engine) {
        // A seam-set version stands; else the shell's own, once it
        // is named (Maintenance::setAppVersion).
        if engine.extension::<Where>().app_version.borrow().is_none() {
            let version = controller::with::<ConnectionHealth, _>(engine, |health, _| {
                health.client_version()
            })
            .unwrap_or_default();
            if !version.is_empty() {
                self.app_version = version;
            }
        }
        let machines = self.machines(engine);
        let local = self.local_providers(engine);
        let state = self.core.state(
            &machines,
            &self.app_version.clone(),
            self.mc.is_ready(),
            &local,
        );
        // The shell's rows change far more often than anything here.
        if state == self.published {
            return;
        }
        self.published = state.clone();
        self.bridge.publish(engine, KEY, state);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn machine(id: &str, version: &str) -> Machine {
        Machine {
            environment_id: id.into(),
            label: format!("Machine {id}"),
            version: version.into(),
            online: true,
            local: id == "env-a",
            capabilities: Map::new(),
        }
    }

    #[test]
    fn channels_paths_and_newest_read_as_the_qt_client() {
        assert_eq!(channel_of("0.5.0-nightly.20260901.3"), "nightly");
        assert_eq!(channel_of(" 0.5.0-preview.20260901.1 "), "preview");
        assert_eq!(channel_of("0.5.0"), "stable");
        assert_eq!(channel_of("0.5.0-nightly"), "stable");
        assert_eq!(channel_of("0.5.0-rc.1-nightly.20260901.3"), "stable");
        let releases = vec![
            json!({"tag_name": "mc-v0.6.0-nightly.20260902.1", "draft": true}),
            json!({"tag_name": "v0.6.0", "draft": false}),
            json!({"tag_name": "mc-v0.5.1", "draft": false}),
            json!({"tag_name": "mc-v0.5.0", "draft": false}),
        ];
        assert_eq!(newest_on(&releases, "stable").as_deref(), Some("0.5.1"));
        assert_eq!(newest_on(&releases, "nightly"), None);
        let mut caps = Map::new();
        assert_eq!(path_of(&caps), Path::Command);
        caps.insert("serverSelfUpdate".into(), json!("hot-upgrade"));
        assert_eq!(path_of(&caps), Path::Update);
        caps.insert("serverSelfUpdate".into(), json!("desktop-managed"));
        assert_eq!(path_of(&caps), Path::DesktopManual);
        caps.insert("desktopAppUpdate".into(), json!(true));
        assert_eq!(path_of(&caps), Path::Desktop);
    }

    #[test]
    fn a_retry_failure_does_not_clobber_a_settled_success() {
        // Given up on, retried, then the first attempt comes back
        // while the retry's answer is in flight: its failure must
        // not replace the settlement (the interleaving the prop
        // cannot reach, since it writes outcomes itself).
        let mut core = Core::default();
        core.gave_up_on.insert("env-a".into(), "0.4.0".into());
        let back = machine("env-a", "0.6.0");
        assert_eq!(core.settle(&[back]).len(), 0, "settles through gave_up_on");
        assert!(core.outcomes["env-a"].ok);
        core.update_failed("env-a", "Machine env-a", "refused");
        assert!(core.outcomes["env-a"].ok, "the success stands");
        assert!(core.message.as_ref().is_some_and(|m| m.ok));

        // With no settlement during the retry, the failure is told.
        let mut core = Core::default();
        core.update_failed("env-a", "Machine env-a", "refused");
        assert!(!core.outcomes["env-a"].ok);
        assert!(core.outcomes["env-a"].text.contains("refused"));
    }

    #[test]
    fn a_cached_release_on_another_channel_is_not_offered() {
        let mut core = Core::default();
        core.releases.insert(
            "env-a".into(),
            Release {
                checking: false,
                text: String::new(),
                available: "0.6.0".into(),
            },
        );
        // The machine moved to nightly since the check: the cached
        // stable release is not its target (the app's own may be).
        let nightly = machine("env-a", "0.5.0-nightly.20260901.1");
        assert_eq!(core.target(&nightly, "0.5.0"), "");
        assert_eq!(
            core.target(&nightly, "0.5.0-nightly.20260902.1"),
            "0.5.0-nightly.20260902.1"
        );
    }

    #[test]
    fn a_session_read_for_a_forgotten_connection_no_longer_answers() {
        let mut core = Core::default();
        let read = core.begin_session_read();
        assert!(core.session_read_is_current(read));
        // The connection changes while the read is in flight.
        core.forget_session();
        assert_eq!(core.session, Session::Unknown);
        assert!(!core.session_read_is_current(read), "the stale read is dropped");
        // A read started for the new connection answers.
        let next = core.begin_session_read();
        assert!(core.session_read_is_current(next));
        assert!(!core.session_read_is_current(read));
    }

    #[test]
    fn a_newer_preview_is_the_target() {
        // Preview prereleases are ordered by their date, as
        // nightlies are: 20260902 is newer than 20260901.
        let mut core = Core::default();
        let own = machine("env-a", "0.5.0-preview.20260901.1");
        assert_eq!(core.target(&own, "0.5.0-preview.20260902.1"), "0.5.0-preview.20260902.1");
        assert_eq!(core.target(&own, "0.5.0-preview.20260901.1"), "");
        core.releases.insert(
            "env-a".into(),
            Release {
                checking: false,
                text: String::new(),
                available: "0.5.0-preview.20260902.1".into(),
            },
        );
        assert_eq!(core.target(&own, "0.5.0"), "0.5.0-preview.20260902.1");
    }

    #[test]
    fn blocked_target_and_settle_follow_the_session_and_versions() {
        let mut core = Core::default();
        let own = machine("env-a", "0.4.0");
        assert_eq!(core.blocked(&own, true), "Checking permissions…");
        assert!(!core.blocked(&own, false).is_empty());
        core.session = Session::May;
        assert_eq!(core.blocked(&own, true), "");
        assert_eq!(core.target(&own, "0.5.0"), "0.5.0");
        core.releases.insert(
            "env-a".into(),
            Release {
                checking: false,
                text: String::new(),
                available: "0.6.0".into(),
            },
        );
        assert_eq!(core.target(&own, "0.5.0"), "0.6.0");
        // An answered update settles when the machine is back newer.
        core.reconnecting.insert("env-a".into(), "0.4.0".into());
        let back = machine("env-a", "0.6.0");
        assert_eq!(core.settle(&[back]), vec!["env-a".to_string()]);
        assert!(core.outcomes["env-a"].ok);
        assert!(!core.releases.contains_key("env-a"));
    }
}
