//! `connectionHealth`: how the connection to the MC is told in words
//! (features/connection/, ConnectionHealthController.cpp). The client's
//! phases are driven by hand through an MC whose status the test sets.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use hal_c2_mc::pairing::{Outcome, Pairing};
use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller;
use hal_c2_shell::controllers::connection_health::{ConnectionHealth, Network, server_behind};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Mc, OnFrame, OnReady, OnStatus, Phase, Reply, Resume, Status, SubId};
use ljos::App;
use ljos::prelude::{Engine, Platform};
use proptest::prelude::*;
use serde_json::{Map, json};

use crate::common::FakeMc;

/// A FakeMc with a client's status: set by the test, told to whoever
/// listens, and the steering calls counted.
#[derive(Default)]
struct StatusMc {
    inner: FakeMc,
    status: RefCell<Option<Status>>,
    on_status: RefCell<Vec<OnStatus>>,
    retries: Cell<u32>,
    reconnects: Cell<u32>,
    wakes: Cell<u32>,
    online: RefCell<Vec<bool>>,
    origin: RefCell<Option<String>>,
    opened: RefCell<Vec<(String, String)>>,
}

impl StatusMc {
    fn set(&self, engine: &Engine, status: Status) {
        *self.status.borrow_mut() = Some(status.clone());
        let mut listeners = std::mem::take(&mut *self.on_status.borrow_mut());
        for f in &mut listeners {
            f(engine, &status);
        }
        self.on_status.borrow_mut().extend(listeners);
    }
}

impl Mc for StatusMc {
    fn is_ready(&self) -> bool {
        self.status().phase == Phase::Ready
    }
    fn environment(&self) -> String {
        "env-1".into()
    }
    fn call(&self, environment: &str, method: &str, payload: Json, reply: Reply) {
        self.inner.call(environment, method, payload, reply);
    }
    fn subscribe(&self, shape: Json, on_frame: OnFrame, resume: Option<Resume>) -> SubId {
        self.inner.subscribe(shape, on_frame, resume)
    }
    fn unsubscribe(&self, id: SubId) {
        self.inner.unsubscribe(id);
    }
    fn more(&self, id: SubId, items: u32) {
        self.inner.more(id, items);
    }
    fn on_ready_changed(&self, f: OnReady) {
        self.inner.on_ready_changed(f);
    }
    fn status(&self) -> Status {
        self.status.borrow().clone().unwrap_or_default()
    }
    fn on_status(&self, f: OnStatus) {
        self.on_status.borrow_mut().push(f);
    }
    fn retry_now(&self) {
        self.retries.set(self.retries.get() + 1);
    }
    fn reconnect(&self) {
        self.reconnects.set(self.reconnects.get() + 1);
    }
    fn wake(&self) {
        self.wakes.set(self.wakes.get() + 1);
    }
    fn set_online(&self, online: bool) {
        self.online.borrow_mut().push(online);
    }
    fn origin(&self) -> Option<String> {
        self.origin.borrow().clone()
    }
    fn open(&self, origin: &str, token: &str) -> Result<(), String> {
        self.opened.borrow_mut().push((origin.into(), token.into()));
        *self.origin.borrow_mut() = Some(origin.into());
        Ok(())
    }
}

struct Rig {
    engine: Engine,
    mc: Rc<StatusMc>,
}

fn config_dir(test: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("hub-connection-health")
        .join(test);
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

impl Rig {
    fn new(test: &str) -> Rig {
        let engine = App::new("test")
            .register(hal_c2_shell::register)
            .build_engine();
        let mc = Rc::new(StatusMc::default());
        let launch = Launch {
            config_dir: Some(config_dir(test)),
            // The store follows the MC; the controllers wait for its first
            // snapshot, which the tests send.
            mc_origin: Some("http://127.0.0.1:1".into()),
            ..Launch::default()
        };
        hal_c2_shell::start(&engine, &launch, mc.clone());
        Rig { engine, mc }
    }

    fn published(&self) -> Json {
        Bridge::of(&self.engine)
            .published(&self.engine, "connection")
            .unwrap_or(Json::Null)
    }

    fn phase(&self) -> String {
        self.published()["phase"].as_str().unwrap().to_owned()
    }

    fn status(&self, phase: Phase, failure: &str) {
        self.mc.set(
            &self.engine,
            Status {
                phase,
                failure: failure.into(),
                environment: "env-1".into(),
                mc: "mc-a".into(),
                ..Status::default()
            },
        );
    }

    fn snapshot(&self) {
        self.mc.inner.frame(
            &self.engine,
            "shell",
            "",
            json!({"t": "shell", "mcs": [{"mc": "mc-a", "online": true, "epoch": "e", "rev": 1,
                "environment": {"environmentId": "env-1", "label": "Laptop", "serverVersion": "0.0.5"}}],
                "rows": []}),
        );
    }

    fn dispatch(&self, action: &str, payload: Json) {
        Bridge::of(&self.engine).dispatch(&self.engine, action, payload);
    }

    fn with_health<R>(&self, f: impl FnOnce(&mut ConnectionHealth, &Engine) -> R) -> R {
        controller::with::<ConnectionHealth, R>(&self.engine, f).expect("free")
    }
}

#[test]
fn a_socket_alone_is_not_connected_until_the_snapshot_lands() {
    let rig = Rig::new("snapshot");
    assert_eq!(rig.phase(), "connecting");
    assert_eq!(rig.published()["status"], "Connecting");
    rig.status(Phase::Ready, "");
    assert_eq!(rig.phase(), "connecting");
    rig.snapshot();
    assert_eq!(rig.phase(), "connected");
    assert_eq!(rig.published()["status"], "Connected");
    assert_eq!(rig.published()["title"], "");

    // A drop and a new hello need their own snapshot.
    rig.status(Phase::Retrying, "timeout");
    assert_eq!(rig.phase(), "reconnecting");
    let state = rig.published();
    assert_eq!(state["status"], "Reconnecting: timeout");
    assert_eq!(state["title"], "Reconnecting to Laptop");
    assert_eq!(state["detail"], "timeout");
    assert_eq!(state["canRetry"], true);
    rig.status(Phase::Ready, "timeout");
    assert_eq!(rig.phase(), "reconnecting");
    rig.snapshot();
    assert_eq!(rig.phase(), "connected");
    assert_eq!(rig.published()["reason"], "");
}

#[test]
fn a_refused_subscription_is_a_problem_not_a_reconnect() {
    let rig = Rig::new("problem");
    rig.status(Phase::Ready, "");
    rig.snapshot();
    rig.mc.inner.frame(
        &rig.engine,
        "shell",
        "",
        json!({"t": "error", "reason": "database is locked"}),
    );
    let state = rig.published();
    assert_eq!(state["phase"], "problem");
    assert_eq!(
        state["status"],
        "Could not load its data: database is locked"
    );
    assert_eq!(state["canRetry"], true);
    // Retrying a ready connection asks for the subscription on a new socket.
    rig.dispatch("connection.retry", json!({}));
    assert_eq!((rig.mc.reconnects.get(), rig.mc.retries.get()), (1, 0));
    rig.snapshot();
    assert_eq!(rig.phase(), "connected");
}

#[test]
fn each_phase_that_waits_says_what_for() {
    let rig = Rig::new("phases");
    rig.status(Phase::Offline, "");
    let state = rig.published();
    assert_eq!(
        (state["phase"].as_str(), state["status"].as_str()),
        (Some("offline"), Some("Waiting for the network"))
    );
    assert_eq!(state["canRetry"], false);

    rig.status(Phase::Refused, "");
    let state = rig.published();
    assert_eq!(state["phase"], "refused");
    assert_eq!(state["needsPairing"], true);
    assert_eq!(
        state["title"],
        "the environment no longer accepts this device"
    );

    rig.mc.set(
        &rig.engine,
        Status {
            phase: Phase::Blocked,
            blocked_protocol: Some(hal_c2_mc::PROTOCOL + 1),
            ..Status::default()
        },
    );
    assert_eq!(
        rig.published()["status"],
        "This app is too old: update HAL-C2 on this device"
    );
    rig.mc.set(
        &rig.engine,
        Status {
            phase: Phase::Blocked,
            blocked_protocol: Some(0),
            ..Status::default()
        },
    );
    assert_eq!(
        rig.published()["status"],
        "Its server is too old: update HAL-C2 on that environment"
    );

    // Retry while not ready tries again now.
    rig.dispatch("connection.retry", json!({}));
    assert_eq!((rig.mc.reconnects.get(), rig.mc.retries.get()), (0, 1));
}

#[test]
fn the_trace_id_of_a_failed_attempt_is_copied() {
    let rig = Rig::new("trace");
    rig.mc.set(
        &rig.engine,
        Status {
            phase: Phase::Retrying,
            failure: "closed".into(),
            failure_trace_id: "00-abc-01".into(),
            ..Status::default()
        },
    );
    assert_eq!(rig.published()["traceId"], "00-abc-01");
    rig.dispatch("connection.copyTraceId", json!({}));
    let toasts = Bridge::of(&rig.engine)
        .published(&rig.engine, "toasts")
        .unwrap();
    assert_eq!(toasts["items"][0]["title"], "Trace ID copied");
    assert_eq!(toasts["items"][0]["description"], "00-abc-01");
}

#[test]
fn a_server_older_than_the_app_warns_until_dismissed() {
    let rig = Rig::new("version");
    rig.with_health(|c, engine| c.set_client_version(engine, "0.0.9"));
    rig.status(Phase::Ready, "");
    rig.snapshot();
    let warning = rig.published()["versionWarning"].clone();
    assert_eq!(warning["key"], "env-1:0.0.9:0.0.5");
    assert_eq!(
        warning["text"],
        "Version mismatch: Laptop runs HAL-C2 0.0.5, older than this app (0.0.9). Update it to stay in sync."
    );
    rig.dispatch("connection.dismissVersionWarning", json!({}));
    assert_eq!(rig.published()["versionWarning"], Json::Null);
    assert_eq!(
        Settings::of(&rig.engine).device_value("versionMismatchDismissals"),
        Some(json!(["env-1:0.0.9:0.0.5"]))
    );
    // Another app version is another warning.
    rig.with_health(|c, engine| c.set_client_version(engine, "0.0.10"));
    assert_eq!(
        rig.published()["versionWarning"]["key"],
        "env-1:0.0.10:0.0.5"
    );
}

#[test]
fn versions_compare_by_core_and_nightlies_whole() {
    assert!(server_behind("0.0.9", "0.0.5"));
    assert!(!server_behind("0.0.5", "0.0.5"));
    assert!(!server_behind("0.0.5", "0.0.9"));
    assert!(!server_behind("", "0.0.1"));
    // A release and a prerelease of one core do not differ.
    assert!(!server_behind("1.0.0", "1.0.0-beta.1"));
    assert!(server_behind("1.0.0-nightly.20", "1.0.0-nightly.19"));
    assert!(!server_behind("1.0.0-nightly.19", "1.0.0-nightly.20"));
    assert!(server_behind("v2", "1.9.9"));
    // Not semver: differs when the text does.
    assert!(server_behind("abc", "abd"));
    assert!(!server_behind("abc", "abc"));
}

/// The shell is not ahead of the MC it is built beside. A shell version past
/// `apps/server-ex/VERSION` makes every MC of this checkout "older than this
/// app", and the version-mismatch strip takes room off the window foot.
#[test]
fn the_shell_is_not_ahead_of_the_mc_it_ships_with() {
    let mc = include_str!("../../../../server-ex/VERSION").trim();
    assert!(
        !server_behind(env!("CARGO_PKG_VERSION"), mc),
        "the shell ({}) is ahead of the MC ({mc})",
        env!("CARGO_PKG_VERSION")
    );
}

#[test]
fn a_remote_mc_is_not_tried_without_a_network_and_woken_when_it_returns() {
    let rig = Rig::new("network");
    let down = Rc::new(Cell::new(true));
    let up = Rc::new(Cell::new(false));
    let (d, u) = (down.clone(), up.clone());
    *rig.mc.origin.borrow_mut() = Some("https://mc.example".into());
    rig.with_health(|c, engine| {
        c.set_network(Network {
            disconnected: Rc::new(move || d.get()),
            interface_up: Rc::new(move || u.get()),
        });
        c.network_changed(engine);
    });
    assert_eq!(rig.mc.online.borrow().last(), Some(&false));
    // An interface that is up overrules the system's word.
    up.set(true);
    rig.with_health(|c, engine| c.network_changed(engine));
    assert_eq!(rig.mc.online.borrow().last(), Some(&true));
    assert!(rig.mc.wakes.get() >= 1);
    // The MC on this machine needs no network.
    up.set(false);
    *rig.mc.origin.borrow_mut() = Some("http://127.0.0.1:7000".into());
    rig.with_health(|c, engine| c.network_changed(engine));
    assert_eq!(rig.mc.online.borrow().last(), Some(&true));
}

fn paired(origin: &str, token: &str) -> Pairing {
    let mut descriptor = Map::new();
    descriptor.insert("label".into(), json!("Studio"));
    descriptor.insert("environmentId".into(), json!("env-9"));
    Pairing {
        outcome: Outcome::Paired,
        origin: origin.into(),
        token: token.into(),
        descriptor,
    }
}

#[test]
fn a_fresh_link_replaces_the_session_the_mc_refused() {
    let rig = Rig::new("pair");
    rig.status(Phase::Refused, "");
    rig.with_health(|c, _| {
        c.set_exchange(Arc::new(|link, _| {
            assert_eq!(link.token, "T0KEN");
            paired("https://studio.example", "session")
        }))
    });
    rig.dispatch(
        "connection.pair",
        json!({"pairingUrl": "not a link at all"}),
    );
    assert_eq!(
        rig.published()["pairingError"],
        "Enter a pairing link from the environment."
    );

    rig.dispatch(
        "connection.pair",
        json!({"pairingUrl": "https://studio.example/pair#token=T0KEN"}),
    );
    assert_eq!(rig.published()["pairing"], true);
    // A second link while one is being spent is left be.
    rig.dispatch(
        "connection.pair",
        json!({"pairingUrl": "https://studio.example/pair#token=OTHER"}),
    );
    Platform::of(&rig.engine).finish(&rig.engine);
    let state = rig.published();
    assert_eq!(
        (state["pairing"].clone(), state["pairingError"].clone()),
        (json!(false), json!(""))
    );
    assert_eq!(
        *rig.mc.opened.borrow(),
        [("https://studio.example".to_owned(), "session".to_owned())]
    );
}

#[test]
fn a_link_the_mc_turns_down_says_so_and_changes_nothing() {
    let rig = Rig::new("pair-refused");
    rig.with_health(|c, _| {
        c.set_exchange(Arc::new(|_, _| Pairing {
            outcome: Outcome::Refused,
            ..paired("https://studio.example", "")
        }))
    });
    rig.dispatch(
        "connection.pair",
        json!({"pairingUrl": "https://studio.example/pair#token=T0KEN"}),
    );
    Platform::of(&rig.engine).finish(&rig.engine);
    assert_eq!(
        rig.published()["pairingError"],
        "The pairing link is invalid or expired. Ask for a fresh one."
    );
    assert!(rig.mc.opened.borrow().is_empty());
}

// -- The model ------------------------------------------------------------------

/// What the client and the MC do to the connection, in any order.
#[derive(Clone, Debug)]
enum Op {
    /// The client's phase turns, with a failure or without.
    Phase(u8, bool),
    /// The MC answers the shell subscription.
    Snapshot,
    /// The MC turns the shell subscription down.
    Refuse,
    Retry,
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        5 => (0u8..7, any::<bool>()).prop_map(|(p, f)| Op::Phase(p, f)),
        4 => Just(Op::Snapshot),
        2 => Just(Op::Refuse),
        1 => Just(Op::Retry),
    ]
}

fn phase_of(n: u8) -> Phase {
    [
        Phase::Closed,
        Phase::Connecting,
        Phase::Ready,
        Phase::Retrying,
        Phase::Offline,
        Phase::Refused,
        Phase::Blocked,
    ][usize::from(n)]
}

/// What the connection should read as, from the facts alone.
struct Model {
    phase: Phase,
    failed: bool,
    snapshots: u32,
    at_ready: u32,
    problem: bool,
}

impl Model {
    fn expected(&self) -> &'static str {
        match self.phase {
            Phase::Closed | Phase::Connecting | Phase::Retrying => {
                if self.failed {
                    "reconnecting"
                } else {
                    "connecting"
                }
            }
            Phase::Ready if self.problem => "problem",
            Phase::Ready if self.snapshots > self.at_ready => "connected",
            Phase::Ready if self.failed => "reconnecting",
            Phase::Ready => "connecting",
            Phase::Offline => "offline",
            Phase::Refused => "refused",
            Phase::Blocked => "blocked",
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 128, ..ProptestConfig::default() })]

    #[test]
    fn the_connection_is_connected_only_after_a_snapshot_on_this_socket(
        ops in proptest::collection::vec(op(), 1..50)
    ) {
        static CASE: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let rig = Rig::new(&format!("model-{}", CASE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)));
        let mut model = Model {
            phase: Phase::Closed,
            failed: false,
            snapshots: 0,
            at_ready: 0,
            problem: false,
        };
        for op in ops {
            match op {
                Op::Phase(n, failed) => {
                    let phase = phase_of(n);
                    if phase == Phase::Ready && model.phase != Phase::Ready {
                        model.at_ready = model.snapshots;
                    }
                    model.phase = phase;
                    model.failed = failed;
                    rig.status(phase, if failed { "closed" } else { "" });
                }
                Op::Snapshot => {
                    model.snapshots += 1;
                    model.problem = false;
                    rig.snapshot();
                }
                Op::Refuse => {
                    model.problem = true;
                    rig.mc.inner.frame(&rig.engine, "shell", "", json!({"t": "error", "reason": "no"}));
                }
                Op::Retry => {
                    let (reconnects, retries) = (rig.mc.reconnects.get(), rig.mc.retries.get());
                    rig.dispatch("connection.retry", json!({}));
                    // A ready connection reconnects; any other tries now.
                    if model.phase == Phase::Ready {
                        prop_assert_eq!((rig.mc.reconnects.get(), rig.mc.retries.get()), (reconnects + 1, retries));
                    } else {
                        prop_assert_eq!((rig.mc.reconnects.get(), rig.mc.retries.get()), (reconnects, retries + 1));
                    }
                }
            }
            let state = rig.published();
            prop_assert_eq!(state["phase"].as_str().unwrap(), model.expected());
            let connected = state["phase"] == "connected";
            prop_assert_eq!(state["status"] == "Connected", connected);
            if connected {
                prop_assert_eq!(&state["reason"], "");
                prop_assert_eq!(&state["title"], "");
            }
            prop_assert_eq!(&state["needsPairing"], &json!(model.phase == Phase::Refused));
        }
    }
}
