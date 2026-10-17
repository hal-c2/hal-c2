//! `connectionHealth`, desktop-qt's ConnectionHealthController: how the
//! shell's one connection to its MC is doing, said in words. The client owns
//! the retries (its phases); this turns them into what every window shows
//! (the ConnectionNotice brick, the first row of Connections settings). One
//! per process.
//!
//! Publishes `connection`:
//!   {phase: connecting | connected | reconnecting | offline | refused |
//!           blocked | problem,
//!    status,          the row's words: "Connected", "Reconnecting: timeout", ...
//!    title, detail,   the notice's words; empty while connected
//!    reason,          why the last connection ended, or ""
//!    traceId,         the failed attempt's trace id, or ""
//!    canRetry, needsPairing, pairing, pairingError,
//!    versionWarning:  null | {key, clientVersion, serverVersion, text}}
//! `connected` is not said before the MC's shell snapshot lands on this
//! connection: the socket alone shows nothing. `problem` is a socket that is
//! fine while the MC turned the shell subscription down, which is not a
//! reconnect.
//!
//! Actions: `connection.retry`, `connection.copyTraceId`, `connection.pair
//! {pairingUrl}` (a fresh link for the same MC replaces the session the MC
//! refused; rows, drafts and the route stay), and
//! `connection.dismissVersionWarning` (kept on this device per pair of
//! versions).
//!
//! TODO(port): ConnectionHealth::wake when the app comes to the foreground
//! (`QGuiApplication::applicationStateChanged`): Ljós's `Application.state`
//! is not followed from Rust yet, so a waiting retry is not run by it.
//! TODO(port): ConnectionHealth::network_changed when the system's
//! reachability changes (`QNetworkInformation`): the shell has no reachability
//! source, so only [`ConnectionHealth::set_network`] says a device is offline.

use std::net::IpAddr;
use std::rc::Rc;
use std::sync::Arc;

use ljos::prelude::Engine;
use serde_json::json;
use url::{Host, Url};

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me, Window};
use crate::controllers::settings::Settings;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;
use crate::mc::{Mc, Phase, Status};
use crate::session::Session;
use crate::store;
use hal_c2_mc::pairing::{self, Client, Link, Outcome, Pairing};

const KEY: &str = "connection";
const DISMISSALS: &str = "versionMismatchDismissals";

/// Spends a pairing link's token on a session; blocking, so it runs off the
/// UI thread.
pub type Exchange = Arc<dyn Fn(&Link, &Client) -> Pairing + Send + Sync>;

/// What says whether this device has a network: `disconnected` is the
/// system's word for it, and `interface_up` whether an interface besides
/// loopback is up with an address, which overrules it (Android says
/// disconnected when any one network is lost).
#[derive(Clone)]
pub struct Network {
    pub disconnected: Rc<dyn Fn() -> bool>,
    pub interface_up: Rc<dyn Fn() -> bool>,
}

impl Default for Network {
    /// A device with no word on its network is online.
    fn default() -> Network {
        Network {
            disconnected: Rc::new(|| false),
            interface_up: Rc::new(|| false),
        }
    }
}

struct Version {
    core: [i64; 3],
    prerelease: Vec<String>,
}

/// major.minor.patch with an optional `-prerelease`; short forms pad with zeros.
fn parse(text: &str) -> Option<Version> {
    let text = text.trim();
    let text = text.strip_prefix('v').unwrap_or(text);
    let text = text.split('+').next().unwrap_or_default();
    let (core, prerelease) = match text.split_once('-') {
        Some((core, prerelease)) => (core, prerelease),
        None => (text, ""),
    };
    let mut numbers = Vec::new();
    for part in core.split('.').filter(|p| !p.is_empty()) {
        let number: i64 = part.trim().parse().ok().filter(|n| *n >= 0)?;
        numbers.push(number);
    }
    if numbers.is_empty() || numbers.len() > 3 {
        return None;
    }
    numbers.resize(3, 0);
    Some(Version {
        core: [numbers[0], numbers[1], numbers[2]],
        prerelease: prerelease
            .split('.')
            .filter(|p| !p.is_empty())
            .map(str::to_owned)
            .collect(),
    })
}

/// Negative when `left` is the older.
fn compare(left: &Version, right: &Version, with_prerelease: bool) -> i32 {
    for (a, b) in left.core.iter().zip(&right.core) {
        if a != b {
            return if a < b { -1 } else { 1 };
        }
    }
    if !with_prerelease {
        return 0;
    }
    // A release is newer than its prereleases.
    if left.prerelease.is_empty() != right.prerelease.is_empty() {
        return if left.prerelease.is_empty() { 1 } else { -1 };
    }
    for (a, b) in left.prerelease.iter().zip(&right.prerelease) {
        match (a.parse::<i64>(), b.parse::<i64>()) {
            (Ok(x), Ok(y)) => {
                if x != y {
                    return if x < y { -1 } else { 1 };
                }
            }
            _ => {
                if a != b {
                    return if a < b { -1 } else { 1 };
                }
            }
        }
    }
    if left.prerelease.len() != right.prerelease.len() {
        return if left.prerelease.len() < right.prerelease.len() {
            -1
        } else {
            1
        };
    }
    0
}

/// Whether a server on `server` is behind a client on `client`: two
/// nightlies compare whole, anything else by its core major.minor.patch, so
/// a release and a nightly of one core do not differ.
pub fn server_behind(client: &str, server: &str) -> bool {
    if client.trim().is_empty() || server.trim().is_empty() {
        return false;
    }
    let (Some(ours), Some(theirs)) = (parse(client), parse(server)) else {
        // Versions that are not semver differ when their text does.
        return client.trim() != server.trim();
    };
    let nightly = |v: &Version| v.prerelease.first().is_some_and(|p| p == "nightly");
    compare(&theirs, &ours, nightly(&ours) && nightly(&theirs)) < 0
}

pub struct ConnectionHealth {
    bridge: Bridge,
    me: Me<ConnectionHealth>,
    mc: Rc<dyn Mc>,
    active: bool,
    client_version: String,
    network: Network,
    pairing_client: Client,
    exchange: Exchange,
    /// The store's snapshot count when the socket last became ready: the
    /// connection is described once it grows.
    snapshots_at_ready: u64,
    /// Whether the client's phase was Ready when last seen.
    ready: bool,
    pairing: bool,
    pairing_error: String,
}

impl Controller for ConnectionHealth {
    fn new(init: Init<'_, Self>) -> Self {
        let engine = init.engine;
        let me = init.me.clone();
        // Counted as the phase turns Ready, before update() reads it: the
        // hello says Ready before readiness changes, and a drop says not
        // ready while the phase still reads Ready, so readiness is no moment
        // to look.
        init.mc.on_status(Box::new(move |engine, status| {
            me.run(engine, |c, engine| c.status_changed(engine, status));
        }));
        let me = init.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.update(engine));
        });
        // The MC the client is opened at may be on this machine where the
        // last one was not, or the other way round.
        let mut health = ConnectionHealth {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            client_version: env!("CARGO_PKG_VERSION").to_owned(),
            network: Network::default(),
            pairing_client: Client {
                label: "HAL-C2 desktop".into(),
                device_type: "desktop".into(),
                os: String::new(),
            },
            exchange: Arc::new(pairing::exchange),
            snapshots_at_ready: 0,
            ready: false,
            pairing: false,
            pairing_error: String::new(),
        };
        health.network_changed(engine);
        health.update(engine);
        health
    }

    fn activate(&mut self, engine: &Engine) {
        if !self.active {
            self.active = true;
            let me = self.me.clone();
            Settings::of(engine).on_device_changed(move |engine| {
                me.run(engine, |c, engine| c.update(engine));
            });
        }
        self.update(engine);
    }

    fn attach(&mut self, engine: &Engine, _window: &Window) {
        let mc = self.mc.clone();
        Commands::of(engine).add(
            engine,
            "connection.retry",
            "Reconnect to the environment",
            move |_| mc.retry_now(),
        );
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("connection.") {
            return false;
        }
        match action {
            "connection.retry" => {
                // A subscription the MC turned down is asked for again on a
                // new socket.
                if self.mc.is_ready() {
                    self.mc.reconnect();
                } else {
                    self.mc.retry_now();
                }
            }
            "connection.copyTraceId" => self.copy_trace_id(engine),
            "connection.pair" => {
                let url = payload
                    .get("pairingUrl")
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .trim()
                    .to_owned();
                self.pair(engine, &url);
            }
            "connection.dismissVersionWarning" => {
                let warning = self.version_warning(engine);
                if let Some(key) = warning.get("key").and_then(Json::as_str) {
                    let mut keys = self.dismissed(engine);
                    keys.push(key.to_owned());
                    Settings::of(engine).write_device(engine, DISMISSALS, json!(keys));
                    self.update(engine);
                }
            }
            _ => return false,
        }
        true
    }
}

impl ConnectionHealth {
    /// This app's version (the crate's by default).
    pub fn set_client_version(&mut self, engine: &Engine, version: &str) {
        self.client_version = version.to_owned();
        self.update(engine);
    }

    /// What `connection.pair` says this client is; the desktop unless told.
    pub fn set_pairing_client(&mut self, client: Client) {
        self.pairing_client = client;
    }

    /// What says whether this device has a network (see [`Network`]).
    pub fn set_network(&mut self, network: Network) {
        self.network = network;
    }

    /// What spends a pairing link (the MC's HTTP, unless a test says).
    pub fn set_exchange(&mut self, exchange: Exchange) {
        self.exchange = exchange;
    }

    /// The network changed, or the MC the client is opened at: says again
    /// whether the client is online, and wakes it when it is. A remote MC is
    /// not retried while this device has no network, and is tried at once
    /// when it returns. The MC on this machine needs none.
    pub fn network_changed(&mut self, _engine: &Engine) {
        let local = self
            .mc
            .origin()
            .and_then(|origin| Url::parse(&origin).ok())
            .is_some_and(|url| match url.host() {
                Some(Host::Domain(name)) => name == "localhost",
                Some(Host::Ipv4(ip)) => IpAddr::V4(ip).is_loopback(),
                Some(Host::Ipv6(ip)) => IpAddr::V6(ip).is_loopback(),
                None => false,
            });
        let online = local || !(self.network.disconnected)() || (self.network.interface_up)();
        self.mc.set_online(online);
        if online {
            self.mc.wake();
        }
    }

    /// The client's status changed: counts the snapshots as the phase turns
    /// Ready, then says it.
    fn status_changed(&mut self, engine: &Engine, status: &Status) {
        let ready = status.phase == Phase::Ready;
        if ready && !self.ready {
            self.snapshots_at_ready = store::with(engine, |s| s.snapshots());
        }
        self.ready = ready;
        self.update(engine);
    }

    fn copy_trace_id(&self, engine: &Engine) {
        let trace_id = self.mc.status().failure_trace_id;
        if trace_id.is_empty() {
            return;
        }
        self.bridge.copy_to_clipboard(engine, &trace_id);
        controller::with::<Toasts, _>(engine, |toasts, engine| {
            toasts.show(
                engine,
                "success",
                "Trace ID copied",
                &trace_id,
                None,
                DEFAULT_TIMEOUT_MS,
            );
        });
    }

    /// Spends a pairing link's single-use token on a new session with the MC
    /// the link names, as the desktop host does when it attaches, and
    /// connects with it. Everything the shell holds stays as it is.
    fn pair(&mut self, engine: &Engine, pairing_url: &str) {
        if self.pairing {
            return;
        }
        let Some(link) = pairing::read_link(pairing_url) else {
            self.pairing_error = "Enter a pairing link from the environment.".into();
            self.update(engine);
            return;
        };
        self.pairing = true;
        self.pairing_error.clear();
        self.update(engine);
        let exchange = self.exchange.clone();
        let client = self.pairing_client.clone();
        let me = self.me.clone();
        let spawned = ljos::task::spawn(
            engine,
            move || exchange(&link, &client),
            move |engine, result| {
                me.run(engine, |c, engine| c.paired(engine, result.ok()));
            },
        );
        if spawned.is_err() {
            self.pairing = false;
            self.pairing_error = "Could not start pairing. Try again.".into();
            self.update(engine);
        }
    }

    fn paired(&mut self, engine: &Engine, result: Option<Pairing>) {
        self.pairing = false;
        let text = |p: &Pairing, key: &str| {
            p.descriptor
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        match result {
            Some(paired) if paired.outcome == Outcome::Paired => {
                let session = Session {
                    origin: paired.origin.clone(),
                    token: paired.token.clone(),
                    label: text(&paired, "label"),
                    environment_id: text(&paired, "environmentId"),
                };
                match crate::open(engine, &session) {
                    Ok(()) => self.network_changed(engine),
                    Err(_) => {
                        self.pairing_error =
                            "The pairing link is invalid or expired. Ask for a fresh one.".into();
                    }
                }
            }
            _ => {
                self.pairing_error =
                    "The pairing link is invalid or expired. Ask for a fresh one.".into();
            }
        }
        self.update(engine);
    }

    /// The name of the environment behind this connection.
    fn label(&self, status: &Status, engine: &Engine) -> String {
        let label = store::with(engine, |s| {
            s.environment(&s.environment_of(&status.mc))
                .get("label")
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        });
        let label = if label.is_empty() {
            descriptor_text(status, "label")
        } else {
            label
        };
        if label.is_empty() {
            "the environment".into()
        } else {
            label
        }
    }

    fn dismissed(&self, engine: &Engine) -> Vec<String> {
        Settings::of(engine)
            .device_value(DISMISSALS)
            .and_then(|v| {
                v.as_array().map(|a| {
                    a.iter()
                        .filter_map(|s| s.as_str().map(str::to_owned))
                        .collect()
                })
            })
            .unwrap_or_default()
    }

    /// Null, or the warning of a server older than this app that the user
    /// has not dismissed.
    fn version_warning(&self, engine: &Engine) -> Json {
        let status = self.mc.status();
        let server = store::with(engine, |s| {
            s.environment(&s.environment_of(&status.mc))
                .get("serverVersion")
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        });
        let server = if server.is_empty() {
            descriptor_text(&status, "serverVersion")
        } else {
            server
        };
        if !server_behind(&self.client_version, &server) {
            return Json::Null;
        }
        let (client, server) = (self.client_version.trim(), server.trim());
        let key = format!("{}:{client}:{server}", status.environment);
        if self.dismissed(engine).contains(&key) {
            return Json::Null;
        }
        json!({
            "key": key,
            "clientVersion": client,
            "serverVersion": server,
            "text": format!(
                "Version mismatch: {} runs HAL-C2 {server}, older than this app ({client}). Update it to stay in sync.",
                self.label(&status, engine)
            ),
        })
    }

    fn update(&self, engine: &Engine) {
        let status = self.mc.status();
        let reason = status.failure.clone();
        let label = || self.label(&status, engine);
        let problem = store::with(engine, |s| s.problem().to_owned());
        let snapshots = store::with(engine, |s| s.snapshots());
        let (name, state, title, detail, can_retry);
        match status.phase {
            Phase::Closed | Phase::Connecting | Phase::Retrying => {
                // A first attempt that has not failed is connecting; anything
                // after a failure is a reconnect.
                if reason.is_empty() {
                    name = "connecting";
                    state = "Connecting".to_owned();
                    title = String::new();
                    detail = String::new();
                    can_retry = false;
                } else {
                    name = "reconnecting";
                    state = format!("Reconnecting: {reason}");
                    title = format!("Reconnecting to {}", label());
                    detail = reason.clone();
                    can_retry = status.phase == Phase::Retrying;
                }
            }
            Phase::Ready => {
                can_retry = !problem.is_empty();
                if !problem.is_empty() {
                    name = "problem";
                    state = format!("Could not load its data: {problem}");
                    title = "Could not load projects and threads".to_owned();
                    detail = problem;
                } else if snapshots > self.snapshots_at_ready {
                    name = "connected";
                    state = "Connected".to_owned();
                    title = String::new();
                    detail = String::new();
                } else {
                    // The socket is open; the environment has not described
                    // itself yet.
                    name = if reason.is_empty() {
                        "connecting"
                    } else {
                        "reconnecting"
                    };
                    state = "Connecting".to_owned();
                    title = String::new();
                    detail = String::new();
                }
            }
            Phase::Offline => {
                name = "offline";
                state = "Waiting for the network".to_owned();
                title = "This device is offline".to_owned();
                detail = "HAL-C2 connects again when the network is back.".to_owned();
                can_retry = false;
            }
            Phase::Refused => {
                name = "refused";
                state = "Access refused: pair it again".to_owned();
                title = format!("{} no longer accepts this device", label());
                detail = "Pair again with a fresh pairing link from the environment.".to_owned();
                can_retry = true;
            }
            Phase::Blocked => {
                name = "blocked";
                if status
                    .blocked_protocol
                    .is_some_and(|p| p > hal_c2_mc::PROTOCOL)
                {
                    state = "This app is too old: update HAL-C2 on this device".to_owned();
                    title = format!("This app is too old for {}", label());
                    detail = "Update HAL-C2 on this device to connect.".to_owned();
                } else {
                    state = "Its server is too old: update HAL-C2 on that environment".to_owned();
                    title = format!("{} runs an older HAL-C2", label());
                    detail = "Update HAL-C2 on that environment to connect.".to_owned();
                }
                can_retry = true;
            }
        }
        let connected = name == "connected";
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "phase": name,
                "status": state,
                "title": title,
                "detail": detail,
                "reason": if connected { "" } else { reason.as_str() },
                "traceId": if connected { "" } else { status.failure_trace_id.as_str() },
                "canRetry": can_retry,
                "needsPairing": status.phase == Phase::Refused,
                "pairing": self.pairing,
                "pairingError": self.pairing_error,
                "versionWarning": if connected { self.version_warning(engine) } else { Json::Null },
            }),
        );
    }
}

fn descriptor_text(status: &Status, key: &str) -> String {
    status
        .descriptor
        .get(key)
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}
