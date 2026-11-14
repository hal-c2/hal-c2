//! `onboarding`, desktop-qt's OnboardingController: the first-run gate and
//! the welcome wizard. Whether setup is done is this device's
//! `onboardingCompletedAt`; a device without it that already has projects
//! or threads counts as done, which is saved quietly. Until the MC's first
//! snapshot the gate is pending, and after 4 s it offers to reconnect.
//! Preferences that cannot be read stop it before anything else.
//!
//! Publishes `onboarding`:
//!   {gate: "pending" | "wizard" | "app", recovery: null | "connection" | "settings",
//!    step: "connection" | "agents" | "import", stage, importing,
//!    computers: [{environmentId, label, connected, selected}], canContinue,
//!    pairing, pairingError, pairingDetail,
//!    agents: [{environmentId, label, cards: [{driver, name, state, headline, detail,
//!              terminalOpen, terminalAvailable}]}],
//!    terminal: null | {environmentId, driver, command, status: "preparing" | "ready" | "openFailed"},
//!    import: {loading, multiple, total, selectedCount, error, scans: [{environmentId, label,
//!             pending, error, truncated, empty, repositories: [group], other: {count, checked,
//!             partial, candidates}}]}}
//! where a group is {key, label, secondary, single, checked, partial, threadCount,
//! age, claude, codex, candidates: [{key, path, checked, threadCount, age, claude, codex}]}.
//!
//! Actions: `onboarding.reload`, `onboarding.retry` (reads the preferences
//! again), `onboarding.select {environmentId, selected}`, `onboarding.pair
//! {pairingUrl}`, `onboarding.continue`, `onboarding.stage {index}`,
//! `onboarding.agent {environmentId, driver}` (opens its setup terminal),
//! `onboarding.terminal.retry`, `onboarding.terminal.close`,
//! `onboarding.scan.retry {environmentId}`, `onboarding.project {keys,
//! selected}`, `onboarding.selectAll`, `onboarding.selectNone`,
//! `onboarding.import`, `onboarding.skip` (finishes without importing, or
//! without the rest after a partial import).
//!
//! The setup terminal is `Onboarding.terminal` in QML, a terminal session
//! the MC runs with the provider instance's own env and home.
//!
//! A shell that started without an MC pairs here as `--pair` does: the
//! link's token is spent on a session and the shell is opened at that MC
//! ([`crate::open`]). With an MC, a link joins the cluster of the computer
//! it is from (`cluster.join`), as desktop-qt does.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet, VecDeque};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use ljos::prelude::{Cx, Engine, QmlObject, TimerId, Value, qml_singleton};
use regex::Regex;
use serde_json::{Map, json};

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::connection_health::Exchange;
use crate::controllers::navigation::{Navigation, Route};
use crate::controllers::settings::Settings;
use crate::controllers::sidebar::now_ms;
use crate::controllers::terminals::{
    self, Session as TerminalSession, SessionEvent, TerminalPlace,
};
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::controllers::{drafts, provider_settings};
use crate::json::Json;
use crate::mc::{Mc, SubId};
use crate::session::Session;
use crate::sidebar_model::{format_iso, locale_compare, normalize_path, parse_iso};
use crate::store;
use hal_c2_mc::pairing::{self, Client, Outcome, Pairing};

const KEY: &str = "onboarding";
const COMPLETED_AT: &str = "onboardingCompletedAt";
/// Terminals are keyed by a free-form thread id; the MC checks only the cwd.
const SETUP_THREAD: &str = "onboarding-agent-setup";
const DRIVERS: [&str; 2] = ["claudeAgent", "codex"];
const DECISION_TIMEOUT_MS: u64 = 4000;
const RECENT_WINDOW_MS: i64 = 30 * 24 * 60 * 60 * 1000;
/// One or two threads in a folder is usually a one-off question, not a project.
const DEFAULT_SELECTION_MIN_THREADS: i64 = 3;

/// `Onboarding` in QML: the setup terminal's session, or null.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Onboarding", uncreatable)]
#[qml_singleton]
pub struct OnboardingObject {
    #[qml(notify, readonly)]
    terminal: Value,
}

impl Default for OnboardingObject {
    fn default() -> Self {
        OnboardingObject {
            terminal: Value::Null,
        }
    }
}

fn str_of<'a>(value: &'a Json, key: &str) -> &'a str {
    value.get(key).and_then(Json::as_str).unwrap_or_default()
}

/// QJsonValue::toInt: a number's whole part, 0 for anything else.
fn int_of(value: &Json, key: &str) -> i64 {
    value
        .get(key)
        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
        .unwrap_or(0)
}

fn bool_of(value: &Json, key: &str) -> bool {
    value.get(key).and_then(Json::as_bool).unwrap_or(false)
}

fn is_empty_object(value: &Json) -> bool {
    value.as_object().is_none_or(Map::is_empty)
}

/// getOnboardingProviderState
fn provider_state(provider: &Json) -> &'static str {
    if is_empty_object(provider) {
        return "checking";
    }
    let status = str_of(provider, "status");
    if !bool_of(provider, "enabled") || status == "disabled" {
        return "disabled";
    }
    if !bool_of(provider, "installed") {
        return "install";
    }
    if provider
        .get("auth")
        .map(|auth| str_of(auth, "status"))
        .unwrap_or_default()
        == "unauthenticated"
    {
        return "signIn";
    }
    if status == "ready" {
        return "ready";
    }
    "attention"
}

fn priority(state: &str) -> i32 {
    [
        "checking",
        "disabled",
        "install",
        "attention",
        "signIn",
        "ready",
    ]
    .iter()
    .position(|s| *s == state)
    .map_or(-1, |i| i as i32)
}

/// selectOnboardingProvidersByDriver: the most usable instance of the driver.
fn provider_for(providers: &Json, driver: &str) -> Json {
    let mut best = Json::Object(Map::new());
    for provider in providers.as_array().into_iter().flatten() {
        if provider.get("driver").and_then(Json::as_str) != Some(driver) {
            continue;
        }
        let provider = if provider.is_object() {
            provider.clone()
        } else {
            Json::Object(Map::new())
        };
        if is_empty_object(&best)
            || priority(provider_state(&provider)) > priority(provider_state(&best))
        {
            best = provider;
        }
    }
    best
}

/// A provider binary's path, quoted for the command line it is shown in.
fn quote_binary(path: &str, fallback: &str, os: &str) -> String {
    static SAFE: std::sync::LazyLock<Regex> =
        std::sync::LazyLock::new(|| Regex::new(r"^[A-Za-z0-9_./:\\-]+$").expect("a valid pattern"));
    if SAFE.is_match(path) && (os == "windows" || !path.contains('\\')) {
        return path.to_owned();
    }
    if os == "windows" {
        return format!("& '{}'", path.replace('\'', "''"));
    }
    if os == "darwin" || os == "linux" {
        let escape = |text: &str| text.replace('\'', "'\"'\"'");
        if let Some(rest) = path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\")) {
            return format!("~/'{}'", escape(rest));
        }
        return format!("'{}'", escape(path));
    }
    fallback.to_owned()
}

/// resolveOnboardingProviderInstallCommand: the vendors' standalone
/// installers, which keep Settings' updater working.
fn install_command(driver: &str, os: &str) -> String {
    let windows = os == "windows";
    match (driver == "claudeAgent", windows) {
        (true, true) => "irm https://claude.ai/install.ps1 | iex",
        (true, false) => "curl -fsSL https://claude.ai/install.sh | bash",
        (false, true) => "irm https://chatgpt.com/codex/install.ps1 | iex",
        (false, false) => "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
    }
    .to_owned()
}

/// resolveOnboardingProviderLoginCommand: the instance's own binary.
fn login_command(provider: &Json, settings: &Json, os: &str) -> String {
    let driver = str_of(provider, "driver");
    let id = str_of(provider, "instanceId");
    let instances = settings.get("providerInstances");
    let config = match instances.and_then(|i| i.get(id)) {
        Some(instance) => instance.get("config"),
        None => settings.get("providers").and_then(|p| p.get(driver)),
    };
    let claude = driver == "claudeAgent";
    let fallback = if claude { "claude" } else { "codex" };
    let binary = config
        .map(|c| str_of(c, "binaryPath").trim())
        .filter(|b| !b.is_empty())
        .unwrap_or(fallback);
    let verb = if claude { " auth login" } else { " login" };
    quote_binary(binary, fallback, os) + verb
}

fn key_of(environment_id: &str, path: &str) -> String {
    format!("{environment_id}\n{path}")
}

fn plural(count: i64, one: &str, many: &str) -> String {
    format!("{count} {}", if count == 1 { one } else { many })
}

#[derive(Clone, Debug)]
struct Scan {
    pending: bool,
    error: String,
    data: Map<String, Json>,
}

impl Default for Scan {
    /// A computer not scanned yet reads as one being scanned.
    fn default() -> Scan {
        Scan {
            pending: true,
            error: String::new(),
            data: Map::new(),
        }
    }
}

struct Config {
    config: Map<String, Json>,
    subscription: SubId,
}

#[derive(Clone, Debug)]
struct Setup {
    environment_id: String,
    driver: String,
    instance_id: String,
    cwd: String,
    command: String,
    terminal_id: String,
    status: &'static str,
}

/// A project of the cluster: environment and project id.
type ProjectRef = (String, String);

pub struct Onboarding {
    bridge: Bridge,
    me: Me<Onboarding>,
    mc: Rc<dyn Mc>,
    active: bool,
    previewing: bool,
    timeout_ms: u64,
    timer: Option<TimerId>,
    pairing_client: Client,
    exchange: Exchange,

    gate: &'static str,
    stalled: bool,
    step: &'static str,
    finishing: bool,
    finish_toast: String,

    // Connect: every computer offered once is selected once.
    computers: Vec<String>,
    offered: HashSet<String>,
    selected: HashSet<String>,
    pairing: bool,
    pairing_error: String,
    pairing_detail: String,
    setup_ids: Vec<String>,

    // Agents.
    configs: HashMap<String, Config>,
    setup: Option<Setup>,
    session: Option<TerminalSession>,
    /// Which session the events heard are for: one that was replaced
    /// says nothing.
    session_generation: u64,

    // Import.
    scans: HashMap<String, Scan>,
    selection: Option<HashSet<String>>,
    importing: bool,
    import_error: String,
    queue: VecDeque<Json>,
    last_selection: Vec<String>,
    imported: HashMap<String, ProjectRef>,
    with_history: HashMap<String, ProjectRef>,
    attempts: HashMap<String, String>,
    imported_projects: i64,
    imported_threads: i64,
    skipped_threads: i64,
    selection_size: i64,
    rescan: Vec<String>,
    /// The project the wizard lands on once the shell lists it.
    landing: Option<ProjectRef>,
}

impl Controller for Onboarding {
    fn new(init: Init<'_, Self>) -> Self {
        let engine = init.engine;
        // The device's own record may be read after the kept rows are shown,
        // and a save that fails says so too.
        let me = init.me.clone();
        Settings::of(engine).on_device_changed(move |engine| {
            me.run(engine, |c, engine| {
                if c.active || c.previewing {
                    c.decide(engine);
                    c.publish(engine);
                }
            });
        });
        let mut onboarding = Onboarding {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            previewing: false,
            timeout_ms: DECISION_TIMEOUT_MS,
            timer: None,
            pairing_client: Client {
                label: "HAL-C2 desktop".into(),
                device_type: "desktop".into(),
                os: String::new(),
            },
            exchange: Arc::new(pairing::exchange),
            gate: "pending",
            stalled: false,
            step: "connection",
            finishing: false,
            finish_toast: String::new(),
            computers: Vec::new(),
            offered: HashSet::new(),
            selected: HashSet::new(),
            pairing: false,
            pairing_error: String::new(),
            pairing_detail: String::new(),
            setup_ids: Vec::new(),
            configs: HashMap::new(),
            setup: None,
            session: None,
            session_generation: 0,
            scans: HashMap::new(),
            selection: None,
            importing: false,
            import_error: String::new(),
            queue: VecDeque::new(),
            last_selection: Vec::new(),
            imported: HashMap::new(),
            with_history: HashMap::new(),
            attempts: HashMap::new(),
            imported_projects: 0,
            imported_threads: 0,
            skipped_threads: 0,
            selection_size: 0,
            rescan: Vec::new(),
            landing: None,
        };
        onboarding.start_timeout(engine);
        onboarding.publish(engine);
        onboarding
    }

    /// A device that finished setup shows what the client kept (LocalCache)
    /// without waiting for the MC to say so again. The wizard is only ever
    /// decided on the MC's own rows.
    fn preview(&mut self, engine: &Engine) {
        if self.active || self.previewing {
            return;
        }
        self.previewing = true;
        self.decide(engine);
        self.publish(engine);
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.store_changed(engine));
        });
        self.decide(engine);
        self.update_computers(engine);
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("onboarding.") {
            return false;
        }
        let text = |key: &str| str_of(payload, key).to_owned();
        match action {
            "onboarding.reload" => {
                self.stalled = false;
                self.mc.reconnect();
                if self.gate == "pending" {
                    self.start_timeout(engine);
                }
            }
            "onboarding.retry" => {
                Settings::of(engine).reload_device(engine);
                self.decide(engine);
            }
            _ if !self.active || self.gate != "wizard" => return true,
            "onboarding.select" => {
                let id = text("environmentId");
                if bool_of(payload, "selected") {
                    self.selected.insert(id);
                } else {
                    self.selected.remove(&id);
                }
            }
            "onboarding.pair" => {
                let url = text("pairingUrl").trim().to_owned();
                self.pair(engine, &url);
            }
            "onboarding.continue" => match self.step {
                "connection" => self.start_setup(engine),
                "agents" => self.set_stage(engine, 2),
                _ => {}
            },
            "onboarding.stage" => {
                let index = int_of(payload, "index");
                self.set_stage(engine, index);
            }
            "onboarding.agent" => {
                let (environment_id, driver) = (text("environmentId"), text("driver"));
                self.open_setup(engine, &environment_id, &driver);
            }
            "onboarding.terminal.retry" => {
                if self.setup.is_some() {
                    self.start_terminal(engine);
                }
            }
            "onboarding.terminal.close" => self.close_setup(engine),
            "onboarding.scan.retry" => {
                let id = text("environmentId");
                self.scan(&id);
            }
            "onboarding.project" => {
                if self.importing {
                    return true;
                }
                let mut next = self.selected_keys(engine);
                let selected = bool_of(payload, "selected");
                for key in payload
                    .get("keys")
                    .and_then(Json::as_array)
                    .into_iter()
                    .flatten()
                {
                    let key = match key {
                        Json::String(key) => key.clone(),
                        other => other.to_string(),
                    };
                    if selected {
                        next.insert(key);
                    } else {
                        next.remove(&key);
                    }
                }
                self.selection = Some(next);
            }
            "onboarding.selectAll" => {
                if self.importing {
                    return true;
                }
                let all = self
                    .candidates()
                    .iter()
                    .map(|c| str_of(c, "key").to_owned())
                    .collect();
                self.selection = Some(all);
            }
            "onboarding.selectNone" => {
                if !self.importing {
                    self.selection = Some(HashSet::new());
                }
            }
            "onboarding.import" => self.run_import(engine),
            "onboarding.skip" => {
                if self.importing {
                    return true;
                }
                if self.import_error.is_empty() {
                    self.finish(engine, None);
                } else {
                    self.finish_after_import(engine);
                }
            }
            _ => return false,
        }
        self.publish(engine);
        true
    }
}

impl Onboarding {
    /// How long the gate waits for the MC before offering to reconnect.
    pub fn set_decision_timeout(&mut self, engine: &Engine, ms: u64) {
        self.timeout_ms = ms;
        if self.gate == "pending" && !self.stalled {
            self.start_timeout(engine);
        }
    }

    /// What a pairing from a shell without an MC says this client is; the
    /// desktop unless told.
    pub fn set_pairing_client(&mut self, client: Client) {
        self.pairing_client = client;
    }

    /// What spends a pairing link (the MC's HTTP, unless a test says).
    pub fn set_exchange(&mut self, exchange: Exchange) {
        self.exchange = exchange;
    }

    fn start_timeout(&mut self, engine: &Engine) {
        if let Some(timer) = self.timer.take() {
            engine.cancel_call(timer);
        }
        let me = self.me.clone();
        let at = engine.now() + Duration::from_millis(self.timeout_ms);
        self.timer = Some(engine.call_at(at, move |engine| {
            me.run(engine, |c, engine| {
                c.timer = None;
                if c.gate != "pending" {
                    return;
                }
                c.stalled = true;
                c.publish(engine);
            });
        }));
    }

    fn store_changed(&mut self, engine: &Engine) {
        self.update_computers(engine);
        if let Some((environment_id, project_id)) = self.landing.clone()
            && store::with(engine, |s| {
                s.project(&format!("{environment_id}:{project_id}"))
                    .is_some()
            })
        {
            self.landing = None;
            self.finish(engine, Some((environment_id, project_id)));
        }
        self.publish(engine);
    }

    /// FirstRunGate: done when this device says so, or when the workspace
    /// already has something in it; the wizard otherwise. Once shown, the
    /// wizard stays until it finishes.
    fn decide(&mut self, engine: &Engine) {
        if self.gate != "pending" {
            return;
        }
        let device = Settings::of(engine);
        if device.device_unreadable() {
            return;
        }
        let completed = device
            .device_value(COMPLETED_AT)
            .is_some_and(|v| v.as_str().is_some_and(|s| !s.is_empty()));
        if completed {
            self.settle(engine, "app");
            return;
        }
        if !self.active {
            return;
        }
        let something = store::with(engine, |s| {
            !s.projects().is_empty() || !s.threads().is_empty()
        });
        if something {
            // Settled first: a save that fails says the device changed,
            // which decides again.
            self.settle(engine, "app");
            let mut saved = device.device();
            saved.insert(COMPLETED_AT.into(), json!(now_iso(engine)));
            device.set_device_settings(engine, saved);
            return;
        }
        self.settle(engine, "wizard");
    }

    fn settle(&mut self, engine: &Engine, gate: &'static str) {
        self.gate = gate;
        self.stalled = false;
        if let Some(timer) = self.timer.take() {
            engine.cancel_call(timer);
        }
    }

    // ---- Connect ----------------------------------------------------------

    /// The computers of the cluster, the MC's own first; each is selected
    /// the first time it is offered.
    fn update_computers(&mut self, engine: &Engine) {
        let own = self.mc.environment();
        let mut computers: Vec<(String, String)> = store::with(engine, |s| s.environments())
            .into_iter()
            .filter(|id| *id != own)
            .map(|id| (label(engine, &id), id))
            .collect();
        computers.sort_by(|(left, _), (right, _)| locale_compare(left, right));
        let mut computers: Vec<String> = computers.into_iter().map(|(_, id)| id).collect();
        if !own.is_empty() {
            computers.insert(0, own);
        }
        for id in &computers {
            if self.offered.insert(id.clone()) {
                self.selected.insert(id.clone());
            }
        }
        self.computers = computers;
    }

    /// With an MC, joins the cluster of the computer the link is from
    /// (`cluster.join`); its machines are offered as the shell lists them.
    /// Without one, spends the link on a session with its MC and opens the
    /// shell there; that MC's computers are offered as it says them.
    fn pair(&mut self, engine: &Engine, url: &str) {
        if self.pairing || url.is_empty() {
            return;
        }
        self.pairing = true;
        self.pairing_error.clear();
        self.pairing_detail.clear();
        if !crate::has_mc(engine) {
            self.pair_disconnected(engine, url);
            return;
        }
        let me = self.me.clone();
        self.mc.call(
            &self.mc.environment(),
            "cluster.join",
            json!({"link": url}),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    c.pairing = false;
                    if let Err(error) = result {
                        c.pairing_error = "Pairing failed.".into();
                        c.pairing_detail = error.message;
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    fn pair_disconnected(&mut self, engine: &Engine, url: &str) {
        let link = pairing::read_invitation(url)
            .and_then(|invitation| pairing::read_link(&invitation.link))
            .or_else(|| pairing::read_link(url));
        let Some(link) = link else {
            self.pairing = false;
            self.pairing_error = "Pairing failed.".into();
            self.pairing_detail = "Enter a pairing link from the environment.".into();
            return;
        };
        let exchange = self.exchange.clone();
        let client = self.pairing_client.clone();
        let me = self.me.clone();
        let spawned = ljos::task::spawn(
            engine,
            move || exchange(&link, &client),
            move |engine, result| {
                me.run(engine, |c, engine| {
                    c.paired(engine, result.ok());
                    c.publish(engine);
                });
            },
        );
        if spawned.is_err() {
            self.pairing = false;
            self.pairing_error = "Pairing failed.".into();
            self.pairing_detail = "Could not start pairing. Try again.".into();
        }
    }

    fn paired(&mut self, engine: &Engine, result: Option<Pairing>) {
        self.pairing = false;
        let Some(result) = result else {
            self.pairing_error = "Pairing failed.".into();
            self.pairing_detail = "Could not start pairing. Try again.".into();
            return;
        };
        let detail = match result.outcome {
            Outcome::Paired => {
                let said = |key: &str| {
                    result
                        .descriptor
                        .get(key)
                        .and_then(Json::as_str)
                        .unwrap_or_default()
                        .to_owned()
                };
                let session = Session {
                    origin: result.origin.clone(),
                    token: result.token.clone(),
                    label: said("label"),
                    environment_id: said("environmentId"),
                };
                match crate::open(engine, &session) {
                    Ok(()) => return,
                    Err(error) => error,
                }
            }
            Outcome::Unreachable => format!("No environment answered at {}.", result.origin),
            Outcome::NotMc => format!("{} is not a HAL-C2 environment.", result.origin),
            Outcome::Incompatible => {
                format!("{} runs another version of HAL-C2.", result.origin)
            }
            Outcome::Refused => {
                "The pairing link is invalid or expired. Ask for a fresh one.".into()
            }
        };
        self.pairing_error = "Pairing failed.".into();
        self.pairing_detail = detail;
    }

    fn start_setup(&mut self, engine: &Engine) {
        let ids: Vec<String> = self
            .computers
            .iter()
            .filter(|id| self.selected.contains(*id))
            .cloned()
            .collect();
        if ids.is_empty() || self.pairing {
            return;
        }
        if !ids
            .iter()
            .all(|id| store::with(engine, |s| s.environment_online(id)))
        {
            return;
        }
        self.setup_ids = ids.clone();
        self.step = "agents";
        self.watch_configs();
        for id in ids {
            // Re-probe on entry so freshly installed CLIs show up.
            self.refresh_providers(&id);
        }
    }

    /// `server.refreshProviders` on `id`; its providers replace the ones the
    /// cards read.
    fn refresh_providers(&self, id: &str) {
        let me = self.me.clone();
        let environment_id = id.to_owned();
        self.mc.call(
            id,
            "server.refreshProviders",
            json!({}),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    let Ok(result) = result else { return };
                    let Some(providers) = result.get("providers").filter(|p| p.is_array()) else {
                        return;
                    };
                    let Some(config) = c.configs.get_mut(&environment_id) else {
                        return;
                    };
                    config.config.insert("providers".into(), providers.clone());
                    c.publish(engine);
                });
            }),
        );
    }

    /// The progress bar goes back only, and not while an import runs.
    fn set_stage(&mut self, engine: &Engine, index: i64) {
        let current = stage_of(self.step);
        if self.importing {
            return;
        }
        if index == 2 && current == 1 {
            self.close_setup(engine);
            self.step = "import";
            for id in self.setup_ids.clone() {
                if !self.scans.contains_key(&id) {
                    self.scan(&id);
                }
            }
            return;
        }
        if index >= current {
            return;
        }
        self.close_setup(engine);
        self.step = if index == 0 { "connection" } else { "agents" };
    }

    // ---- Agents -----------------------------------------------------------

    fn watch_configs(&mut self) {
        let gone: Vec<String> = self
            .configs
            .keys()
            .filter(|id| !self.setup_ids.contains(id))
            .cloned()
            .collect();
        for id in gone {
            if let Some(config) = self.configs.remove(&id) {
                self.mc.unsubscribe(config.subscription);
            }
        }
        for id in self.setup_ids.clone() {
            if self.configs.contains_key(&id) {
                continue;
            }
            let me = self.me.clone();
            let environment_id = id.clone();
            let subscription = self.mc.subscribe(
                json!({"type": "config", "environment": id}),
                Box::new(move |engine, frame| {
                    let frame = frame.clone();
                    let environment_id = environment_id.clone();
                    me.run(engine, move |c, engine| {
                        let Some(entry) = c.configs.get_mut(&environment_id) else {
                            return;
                        };
                        let config = &mut entry.config;
                        match frame.get("t").and_then(Json::as_str) {
                            Some("config") => {
                                *config = frame
                                    .get("config")
                                    .and_then(Json::as_object)
                                    .cloned()
                                    .unwrap_or_default();
                            }
                            Some("config.providers") => {
                                let providers = frame.get("providers").cloned();
                                config.insert("providers".into(), providers.unwrap_or(Json::Null));
                            }
                            Some("config.settings") => {
                                let settings = frame.get("settings").cloned();
                                config.insert("settings".into(), settings.unwrap_or(Json::Null));
                            }
                            _ => return,
                        }
                        c.publish(engine);
                    });
                }),
                None,
            );
            self.configs.insert(
                id,
                Config {
                    config: Map::new(),
                    subscription,
                },
            );
        }
    }

    fn agents(&self, engine: &Engine) -> Json {
        let available = terminals::supported(engine);
        let computers: Vec<Json> = self
            .setup_ids
            .iter()
            .map(|id| {
                let config = self
                    .configs
                    .get(id)
                    .map(|c| c.config.clone())
                    .unwrap_or_default();
                let cards: Vec<Json> = DRIVERS
                    .iter()
                    .map(|driver| {
                        // Checking until the MC has said which providers it has.
                        let provider = match config.get("providers") {
                            Some(providers) => provider_for(providers, driver),
                            None => Json::Object(Map::new()),
                        };
                        let (headline, detail) = if is_empty_object(&provider) {
                            (
                                "Checking provider status".to_owned(),
                                "Waiting for the server to report installation and authentication details."
                                    .to_owned(),
                            )
                        } else {
                            provider_settings::summary(&provider)
                        };
                        let open = self
                            .setup
                            .as_ref()
                            .is_some_and(|s| s.environment_id == *id && s.driver == *driver);
                        json!({
                            "driver": driver,
                            "name": if *driver == "claudeAgent" { "Claude Code" } else { "Codex" },
                            "state": provider_state(&provider),
                            "headline": headline,
                            "detail": detail,
                            "terminalOpen": open,
                            "terminalAvailable": !config.is_empty() && available,
                        })
                    })
                    .collect();
                json!({"environmentId": id, "label": label(engine, id), "cards": cards})
            })
            .collect();
        Json::Array(computers)
    }

    /// Install or sign in: a terminal on the computer, run as the provider
    /// instance, with the command typed but not run.
    fn open_setup(&mut self, engine: &Engine, environment_id: &str, driver: &str) {
        if !terminals::supported(engine) {
            return;
        }
        if !self.setup_ids.iter().any(|id| id == environment_id) || !DRIVERS.contains(&driver) {
            return;
        }
        let Some(config) = self
            .configs
            .get(environment_id)
            .map(|c| Json::Object(c.config.clone()))
            .filter(|c| !is_empty_object(c))
        else {
            return;
        };
        let provider = provider_for(config.get("providers").unwrap_or(&Json::Null), driver);
        if is_empty_object(&provider) {
            return;
        }
        // One setup terminal at a time: another card's replaces it.
        self.close_setup(engine);
        let os = config
            .get("environment")
            .and_then(|e| e.get("platform"))
            .map(|p| str_of(p, "os"))
            .unwrap_or_default();
        let command = if bool_of(&provider, "installed") {
            let settings = config.get("settings").cloned().unwrap_or(Json::Null);
            login_command(&provider, &settings, os)
        } else {
            install_command(driver, os)
        };
        self.setup = Some(Setup {
            environment_id: environment_id.to_owned(),
            driver: driver.to_owned(),
            instance_id: str_of(&provider, "instanceId").to_owned(),
            cwd: str_of(&config, "cwd").to_owned(),
            command,
            terminal_id: format!("onboarding-{driver}-{}", hal_c2_mc::new_uuid()),
            status: "preparing",
        });
        self.start_terminal(engine);
    }

    fn start_terminal(&mut self, engine: &Engine) {
        if let Some(old) = self.session.take() {
            old.end(engine);
        }
        let Some(setup) = self.setup.as_mut() else {
            return;
        };
        setup.status = "preparing";
        let place = TerminalPlace {
            environment_id: setup.environment_id.clone(),
            thread_id: SETUP_THREAD.into(),
            cwd: setup.cwd.clone(),
            provider_instance_id: setup.instance_id.clone(),
            ..TerminalPlace::default()
        };
        self.session_generation += 1;
        let generation = self.session_generation;
        let me = self.me.clone();
        let session = TerminalSession::open(
            engine,
            self.mc.clone(),
            &place,
            &setup.terminal_id.clone(),
            None,
            move |engine, event| {
                let event = event.clone();
                me.run(engine, move |c, engine| {
                    c.terminal_event(engine, generation, &event)
                });
            },
        );
        self.session = Some(session);
        self.terminal_changed(engine);
    }

    fn terminal_event(&mut self, engine: &Engine, generation: u64, event: &SessionEvent) {
        if self.session.is_none() || self.session_generation != generation {
            return;
        }
        match event {
            SessionEvent::Attached => {
                let Some(setup) = self.setup.as_mut() else {
                    return;
                };
                if let Some(session) = &self.session {
                    session.write(engine, &setup.command);
                }
                setup.status = "ready";
                self.terminal_changed(engine);
                self.publish(engine);
            }
            SessionEvent::Failed(_) => {
                let Some(setup) = self.setup.as_mut() else {
                    return;
                };
                setup.status = "openFailed";
                let session = self.session.take();
                self.terminal_changed(engine);
                if let Some(session) = session {
                    session.end(engine);
                }
                self.publish(engine);
            }
            SessionEvent::Closed => {
                self.close_setup(engine);
                self.publish(engine);
            }
            SessionEvent::Exited | SessionEvent::Resized(..) => {}
        }
    }

    /// Every way out ends the terminal, and the cards look again.
    fn close_setup(&mut self, engine: &Engine) {
        let Some(setup) = self.setup.take() else {
            return;
        };
        let session = self.session.take();
        self.terminal_changed(engine);
        if let Some(session) = session {
            session.end(engine);
        }
        self.mc.call(
            &setup.environment_id,
            "terminal.close",
            json!({"threadId": SETUP_THREAD, "terminalId": setup.terminal_id, "deleteHistory": true}),
            Box::new(|_, _| {}),
        );
        self.refresh_providers(&setup.environment_id);
    }

    /// Tells `Onboarding.terminal` which session it is now.
    fn terminal_changed(&self, engine: &Engine) {
        let value = self
            .session
            .as_ref()
            .and_then(TerminalSession::object)
            .map_or(Value::Null, Value::Object);
        if let Ok(obj) = self.bridge.singleton::<OnboardingObject>(engine) {
            let _ = Cx::new(engine, obj).set(OnboardingObject::TERMINAL, value);
        }
    }

    // ---- Import -----------------------------------------------------------

    fn scan(&mut self, environment_id: &str) {
        if !self.setup_ids.iter().any(|id| id == environment_id) {
            return;
        }
        let entry = self.scans.entry(environment_id.to_owned()).or_default();
        entry.pending = true;
        entry.error.clear();
        let me = self.me.clone();
        let id = environment_id.to_owned();
        self.mc.call(
            environment_id,
            "agentSessions.scan",
            json!({}),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    let entry = c.scans.entry(id).or_default();
                    entry.pending = false;
                    match result {
                        Err(error) => entry.error = error.message,
                        Ok(result) => entry.data = result.as_object().cloned().unwrap_or_default(),
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    fn candidates(&self) -> Vec<Json> {
        let mut result = Vec::new();
        for id in &self.setup_ids {
            let Some(scan) = self.scans.get(id) else {
                continue;
            };
            for value in scan
                .data
                .get("candidates")
                .and_then(Json::as_array)
                .into_iter()
                .flatten()
            {
                let mut candidate = value.as_object().cloned().unwrap_or_default();
                let key = key_of(id, str_of(value, "path"));
                candidate.insert("environmentId".into(), json!(id));
                candidate.insert("key".into(), json!(key));
                result.push(Json::Object(candidate));
            }
        }
        result
    }

    /// partitionOnboardingProjects: by default, git repositories active in
    /// the last 30 days with enough threads to look like real work.
    fn selected_keys(&self, engine: &Engine) -> HashSet<String> {
        if let Some(selection) = &self.selection {
            return selection.clone();
        }
        let now = now_ms(engine);
        self.candidates()
            .iter()
            .filter(|candidate| {
                if candidate.get("git") == Some(&Json::Null) {
                    return false;
                }
                if int_of(candidate, "threadCount") < DEFAULT_SELECTION_MIN_THREADS {
                    return false;
                }
                parse_iso(candidate.get("lastActiveAt").and_then(Json::as_str))
                    .is_some_and(|last| last <= now && now - last <= RECENT_WINDOW_MS)
            })
            .map(|candidate| str_of(candidate, "key").to_owned())
            .collect()
    }

    fn run_import(&mut self, engine: &Engine) {
        if self.importing {
            return;
        }
        let keys = self.selected_keys(engine);
        let selection: Vec<Json> = self
            .candidates()
            .into_iter()
            .filter(|c| keys.contains(str_of(c, "key")))
            .collect();
        if selection.is_empty() {
            self.finish(engine, None);
            return;
        }
        self.importing = true;
        self.import_error.clear();
        self.last_selection.clear();
        self.imported_projects = 0;
        for candidate in &selection {
            let key = str_of(candidate, "key").to_owned();
            // Retries skip what already landed.
            if self.imported.contains_key(&key) {
                self.imported_projects += 1;
            }
            self.last_selection.push(key);
        }
        self.imported_threads = 0;
        self.skipped_threads = 0;
        self.selection_size = selection.len() as i64;
        self.rescan.clear();
        self.queue = selection.into();
        self.import_next(engine);
    }

    /// One candidate at a time: its project (the MC's match, the shell's,
    /// or a new one), then its history.
    fn import_next(&mut self, engine: &Engine) {
        while self
            .queue
            .front()
            .is_some_and(|c| self.imported.contains_key(str_of(c, "key")))
        {
            self.queue.pop_front();
        }
        let Some(candidate) = self.queue.pop_front() else {
            self.after_import(engine);
            return;
        };
        let env = str_of(&candidate, "environmentId").to_owned();
        let key = str_of(&candidate, "key").to_owned();
        let path = str_of(&candidate, "path").to_owned();
        let mut project_id = str_of(&candidate, "projectId").to_owned();
        if project_id.is_empty() {
            let root = normalize_path(&path);
            project_id = store::with(engine, |s| {
                s.projects()
                    .into_iter()
                    .find(|p| p.environment_id == env && normalize_path(&p.workspace_root) == root)
                    .map(|p| p.id)
                    .unwrap_or_default()
            });
        }
        if !project_id.is_empty() {
            self.import_threads(env, key, path, project_id);
            return;
        }
        let created = self
            .attempts
            .entry(key.clone())
            .or_insert_with(hal_c2_mc::new_uuid)
            .clone();
        let me = self.me.clone();
        self.mc.call(
            &env.clone(),
            "projects.mutate",
            json!({
                "type": "project.create",
                "projectId": created,
                "title": str_of(&candidate, "title"),
                "workspaceRoot": path,
                "createWorkspaceRootIfMissing": false,
            }),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    if result.is_err() {
                        c.attempts.remove(&key);
                        c.note_rescan(&env);
                        c.import_next(engine);
                        return;
                    }
                    c.import_threads(env, key, path, created);
                });
            }),
        );
    }

    fn import_threads(&mut self, env: String, key: String, path: String, project_id: String) {
        let me = self.me.clone();
        self.mc.call(
            &env.clone(),
            "agentSessions.import",
            json!({"projectId": project_id, "expectedWorkspaceRoot": path}),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    match result {
                        Err(_) => {
                            c.attempts.remove(&key);
                            c.note_rescan(&env);
                        }
                        Ok(result) => {
                            let imported = int_of(&result, "importedCount");
                            let skipped = int_of(&result, "skippedCount");
                            c.imported_threads += imported;
                            c.skipped_threads += skipped;
                            if imported > 0 {
                                c.with_history
                                    .insert(key.clone(), (env.clone(), project_id.clone()));
                            }
                            if skipped == 0 {
                                c.imported_projects += 1;
                                c.imported.insert(key, (env, project_id));
                            }
                        }
                    }
                    c.import_next(engine);
                });
            }),
        );
    }

    fn note_rescan(&mut self, env: &str) {
        if !self.rescan.iter().any(|e| e == env) {
            self.rescan.push(env.to_owned());
        }
    }

    fn after_import(&mut self, engine: &Engine) {
        for env in self.rescan.clone() {
            self.scan(&env);
        }
        self.importing = false;
        if self.imported_projects < self.selection_size {
            let imported = self.imported_threads;
            let skipped = self.skipped_threads;
            self.import_error = if imported > 0 && skipped > 0 {
                format!(
                    "Imported {}. {} could not be imported.",
                    plural(imported, "thread", "threads"),
                    plural(skipped, "thread", "threads")
                )
            } else if skipped > 0 {
                format!(
                    "{} not be imported.",
                    plural(skipped, "thread could", "threads could")
                )
            } else if imported > 0 {
                format!(
                    "Imported {}. Some thread history could not be imported.",
                    plural(imported, "thread", "threads")
                )
            } else {
                "Could not import thread history.".into()
            };
            self.publish(engine);
            return;
        }
        self.finish_after_import(engine);
        self.publish(engine);
    }

    /// resolveOnboardingLandingProject: a selected project with imported
    /// history first, else one that imported cleanly; opened once the shell
    /// lists it.
    fn finish_after_import(&mut self, engine: &Engine) {
        let project = self
            .last_selection
            .iter()
            .find_map(|key| self.with_history.get(key))
            .or_else(|| {
                self.last_selection
                    .iter()
                    .find_map(|key| self.imported.get(key))
            })
            .cloned();
        let Some(project) = project else {
            self.finish(engine, None);
            return;
        };
        let listed = store::with(engine, |s| {
            s.project(&format!("{}:{}", project.0, project.1)).is_some()
        });
        if listed {
            self.finish(engine, Some(project));
            return;
        }
        self.importing = true;
        self.landing = Some(project);
    }

    fn import_state(&self, engine: &Engine) -> Json {
        let selected = self.selected_keys(engine);
        let all = self.candidates();
        let now = now_ms(engine);
        // formatRelativeTime, with "just now" as "now" to fit the column.
        let age = |at: &str| -> String {
            let Some(time) = parse_iso(Some(at)) else {
                return String::new();
            };
            let seconds = (now - time) / 1000;
            if seconds < 60 {
                "now".into()
            } else if seconds < 3600 {
                format!("{}m", seconds / 60)
            } else if seconds < 86400 {
                format!("{}h", seconds / 3600)
            } else {
                format!("{}d", seconds / 86400)
            }
        };
        let sourced = |candidate: &Json, source: &str| {
            candidate
                .get("sources")
                .and_then(Json::as_array)
                .is_some_and(|s| s.iter().any(|v| v.as_str() == Some(source)))
        };
        let row = |candidate: &Json| {
            json!({
                "key": str_of(candidate, "key"),
                "path": str_of(candidate, "path"),
                "checked": selected.contains(str_of(candidate, "key")),
                "threadCount": int_of(candidate, "threadCount"),
                "age": age(str_of(candidate, "lastActiveAt")),
                "claude": sourced(candidate, "claudeAgent"),
                "codex": sourced(candidate, "codex"),
            })
        };
        // Nothing found anywhere yet, and something still looking.
        let mut any_data = false;
        let mut any_pending = false;
        let mut scans = Vec::new();
        for id in &self.setup_ids {
            let entry = self.scans.get(id).cloned().unwrap_or_default();
            any_data = any_data || !entry.data.is_empty();
            any_pending = any_pending || entry.pending;
            // groupOnboardingProjects: clones of one remote share a group;
            // folders that are not repositories are the "Other folders".
            struct Group<'a> {
                key: String,
                label: String,
                repository: String,
                last_active_at: String,
                thread_count: i64,
                members: Vec<&'a Json>,
            }
            let mut groups: Vec<Group> = Vec::new();
            let mut other: Vec<&Json> = Vec::new();
            let mine: Vec<&Json> = all
                .iter()
                .filter(|c| str_of(c, "environmentId") == id)
                .collect();
            for candidate in &mine {
                let git = candidate.get("git");
                if git == Some(&Json::Null) {
                    other.push(candidate);
                    continue;
                }
                let git = git.cloned().unwrap_or(Json::Null);
                let remote = str_of(&git, "remoteKey");
                let key = if remote.is_empty() {
                    format!("path:{}", str_of(candidate, "path"))
                } else {
                    format!("remote:{remote}")
                };
                let last = str_of(candidate, "lastActiveAt").to_owned();
                match groups.iter_mut().find(|g| g.key == key) {
                    None => {
                        let repository = str_of(&git, "repository").to_owned();
                        groups.push(Group {
                            key,
                            label: if repository.is_empty() {
                                str_of(candidate, "title").to_owned()
                            } else {
                                repository.clone()
                            },
                            repository,
                            last_active_at: last,
                            thread_count: int_of(candidate, "threadCount"),
                            members: vec![candidate],
                        });
                    }
                    Some(found) => {
                        found.members.push(candidate);
                        found.thread_count += int_of(candidate, "threadCount");
                        if last > found.last_active_at {
                            found.last_active_at = last;
                        }
                    }
                }
            }
            groups.sort_by(|left, right| {
                if left.last_active_at == right.last_active_at {
                    return locale_compare(&left.label, &right.label);
                }
                if left.last_active_at.is_empty() {
                    return Ordering::Greater;
                }
                if right.last_active_at.is_empty() {
                    return Ordering::Less;
                }
                right.last_active_at.cmp(&left.last_active_at)
            });
            let repositories: Vec<Json> = groups
                .iter()
                .map(|group| {
                    let members: Vec<Json> = group.members.iter().map(|c| row(c)).collect();
                    let checked = members.iter().filter(|m| bool_of(m, "checked")).count();
                    let claude = members.iter().any(|m| bool_of(m, "claude"));
                    let codex = members.iter().any(|m| bool_of(m, "codex"));
                    let single = group.members.len() == 1;
                    let secondary = if single && !group.repository.is_empty() {
                        str_of(group.members[0], "path")
                    } else {
                        ""
                    };
                    json!({
                        "key": group.key,
                        "label": group.label,
                        "secondary": secondary,
                        "single": single,
                        "checked": checked == group.members.len(),
                        "partial": checked > 0 && checked < group.members.len(),
                        "threadCount": group.thread_count,
                        "age": age(&group.last_active_at),
                        "claude": claude,
                        "codex": codex,
                        "candidates": members,
                    })
                })
                .collect();
            let others: Vec<Json> = other.iter().map(|c| row(c)).collect();
            let other_checked = others.iter().filter(|m| bool_of(m, "checked")).count();
            scans.push(json!({
                "environmentId": id,
                "label": label(engine, id),
                "pending": entry.pending && entry.data.is_empty(),
                "error": entry.error,
                "truncated": entry.data.get("truncated").and_then(Json::as_bool).unwrap_or(false),
                "empty": mine.is_empty() && !entry.pending && entry.error.is_empty(),
                "repositories": repositories,
                "other": {
                    "count": others.len(),
                    "checked": !others.is_empty() && other_checked == others.len(),
                    "partial": other_checked > 0 && other_checked < others.len(),
                    "candidates": others,
                },
            }));
        }
        let selected_count = all
            .iter()
            .filter(|c| selected.contains(str_of(c, "key")))
            .count();
        json!({
            "loading": !any_data && any_pending,
            "multiple": self.setup_ids.len() > 1,
            "total": all.len(),
            "selectedCount": selected_count,
            "error": self.import_error,
            "scans": scans,
        })
    }

    // ---- Finishing --------------------------------------------------------

    /// Saves that setup is done, then opens the app: on a new thread in the
    /// project it lands on, else home.
    fn finish(&mut self, engine: &Engine, project: Option<ProjectRef>) {
        if self.finishing {
            return;
        }
        let device = Settings::of(engine);
        let mut saved = device.device();
        saved.insert(COMPLETED_AT.into(), json!(now_iso(engine)));
        self.finishing = true;
        let done = device.set_device_settings(engine, saved);
        self.finishing = false;
        if !done {
            self.importing = false;
            let title = "Could not finish setup";
            let description = "Your settings could not be saved. Try again.";
            let shown = self.finish_toast.clone();
            let id = controller::with::<Toasts, _>(engine, |toasts, engine| {
                if !shown.is_empty() && toasts.update(engine, &shown, title, description) {
                    return shown;
                }
                toasts.show(
                    engine,
                    "error",
                    title,
                    description,
                    None,
                    DEFAULT_TIMEOUT_MS,
                )
            });
            if let Some(id) = id {
                self.finish_toast = id;
            }
            self.publish(engine);
            return;
        }
        let shown = std::mem::take(&mut self.finish_toast);
        if !shown.is_empty() {
            controller::with::<Toasts, _>(engine, |toasts, engine| toasts.dismiss(engine, &shown));
        }
        self.close_setup(engine);
        self.importing = false;
        self.gate = "app";
        self.publish(engine);
        match project {
            Some((environment_id, project_id)) => {
                drafts::start(engine, &environment_id, &project_id);
            }
            None => {
                controller::with::<Navigation, _>(engine, |navigation, engine| {
                    navigation.open(engine, Route::Home)
                });
            }
        }
    }

    // ---- Publishing -------------------------------------------------------

    fn publish(&self, engine: &Engine) {
        let recovery = if Settings::of(engine).device_unreadable() {
            json!("settings")
        } else if self.gate == "pending" && self.stalled {
            json!("connection")
        } else {
            Json::Null
        };
        let mut ready = false;
        let computers: Vec<Json> = self
            .computers
            .iter()
            .map(|id| {
                let selected = self.selected.contains(id);
                ready = ready || selected;
                json!({
                    "environmentId": id,
                    "label": label(engine, id),
                    "connected": store::with(engine, |s| s.environment_online(id)),
                    "selected": selected,
                })
            })
            .collect();
        if self.selected.iter().any(|id| {
            self.computers.contains(id) && !store::with(engine, |s| s.environment_online(id))
        }) {
            ready = false;
        }
        let terminal = self.setup.as_ref().map_or(Json::Null, |setup| {
            json!({
                "environmentId": setup.environment_id,
                "driver": setup.driver,
                "command": setup.command,
                "status": setup.status,
            })
        });
        let agents = if self.step == "agents" {
            self.agents(engine)
        } else {
            json!([])
        };
        let import = if self.step == "import" {
            self.import_state(engine)
        } else {
            json!({})
        };
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "gate": self.gate,
                "recovery": recovery,
                "step": self.step,
                "stage": stage_of(self.step),
                "importing": self.importing,
                "computers": computers,
                "canContinue": ready && !self.pairing,
                "pairing": self.pairing,
                "pairingError": self.pairing_error,
                "pairingDetail": self.pairing_detail,
                "agents": agents,
                "terminal": terminal,
                "import": import,
            }),
        );
    }
}

fn stage_of(step: &str) -> i64 {
    match step {
        "agents" => 1,
        "import" => 2,
        _ => 0,
    }
}

/// A computer's name as the shell lists it.
fn label(engine: &Engine, environment_id: &str) -> String {
    let label = store::with(engine, |s| {
        s.environment(environment_id)
            .get("label")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned()
    });
    if label.is_empty() {
        "Computer".into()
    } else {
        label
    }
}

/// Now as the device's record keeps it: `2026-01-05T09:00:00.000Z`.
fn now_iso(engine: &Engine) -> String {
    format_iso(&DateTime::<Utc>::from_timestamp_millis(now_ms(engine)).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_binary_path_is_quoted_for_its_shell() {
        assert_eq!(quote_binary("codex", "codex", "linux"), "codex");
        assert_eq!(
            quote_binary("~/bin/codex work", "codex", "linux"),
            "~/'bin/codex work'"
        );
        assert_eq!(
            quote_binary("/opt/it's/claude", "claude", "darwin"),
            "'/opt/it'\"'\"'s/claude'"
        );
        assert_eq!(
            quote_binary("C:\\Program Files\\codex.exe", "codex", "windows"),
            "& 'C:\\Program Files\\codex.exe'"
        );
        assert_eq!(
            quote_binary("C:\\codex.exe", "codex", "windows"),
            "C:\\codex.exe"
        );
        assert_eq!(quote_binary("a\\b", "codex", "linux"), "'a\\b'");
        assert_eq!(quote_binary("a b", "codex", ""), "codex");
    }

    #[test]
    fn the_most_usable_instance_of_a_driver_is_chosen() {
        let providers = json!([
            {"driver": "codex", "instanceId": "a", "enabled": true, "installed": false},
            {"driver": "codex", "instanceId": "b", "enabled": true, "installed": true, "status": "ready"},
            {"driver": "claudeAgent", "instanceId": "c", "enabled": false},
        ]);
        assert_eq!(provider_for(&providers, "codex")["instanceId"], "b");
        assert_eq!(
            provider_state(&provider_for(&providers, "claudeAgent")),
            "disabled"
        );
        assert_eq!(
            provider_state(&provider_for(&providers, "cursor")),
            "checking"
        );
    }

    #[test]
    fn a_login_uses_the_instance_binary() {
        let provider = json!({"driver": "codex", "instanceId": "codex_work"});
        let settings = json!({"providerInstances": {"codex_work": {"config": {"binaryPath": " ~/bin/codex work "}}}});
        assert_eq!(
            login_command(&provider, &settings, "linux"),
            "~/'bin/codex work' login"
        );
        let settings = json!({"providers": {"claudeAgent": {"binaryPath": ""}}});
        let provider = json!({"driver": "claudeAgent", "instanceId": "claudeAgent"});
        assert_eq!(
            login_command(&provider, &settings, "linux"),
            "claude auth login"
        );
    }
}
