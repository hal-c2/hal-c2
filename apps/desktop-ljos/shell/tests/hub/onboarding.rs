//! `onboarding`: the first-run gate and the welcome wizard
//! (OnboardingController.cpp, features/onboarding/,
//! tst_OnboardingRegression.cpp), driven as the bricks drive it against an
//! MC whose answers the test gives, in any order.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use chrono::{DateTime, Utc};
use hal_c2_mc::pairing::{Outcome, Pairing};
use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller;
use hal_c2_shell::controllers::onboarding::{Onboarding, OnboardingObject};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::terminals;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Mc, McError, OnFrame, OnReady, Reply, Resume, SubId};
use ljos::App;
use ljos::prelude::{Engine, Platform, Value};
use ljos::testing::TestWindow;
use proptest::prelude::*;
use serde_json::{Map, json};

use crate::common::{FakeMc, read};

const NOW: &str = "2026-09-23T10:00:00Z";

/// A FakeMc that counts reconnects and opens as the shell asks for them.
#[derive(Default)]
struct OnboardingMc {
    inner: FakeMc,
    reconnects: Cell<u32>,
    opened: RefCell<Vec<(String, String)>>,
    /// Whether it was ever opened: an MC that never was has no environment.
    connected: Cell<bool>,
}

impl Mc for OnboardingMc {
    fn is_ready(&self) -> bool {
        self.inner.is_ready()
    }
    fn environment(&self) -> String {
        if self.connected.get() {
            self.inner.environment()
        } else {
            String::new()
        }
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
    fn reconnect(&self) {
        self.reconnects.set(self.reconnects.get() + 1);
    }
    fn origin(&self) -> Option<String> {
        self.opened
            .borrow()
            .last()
            .map(|(origin, _)| origin.clone())
    }
    fn open(&self, origin: &str, token: &str) -> Result<(), String> {
        self.opened.borrow_mut().push((origin.into(), token.into()));
        self.connected.set(true);
        Ok(())
    }
}

struct Rig {
    engine: Engine,
    window: RefCell<TestWindow>,
    mc: Rc<OnboardingMc>,
    dir: Option<PathBuf>,
    rev: Cell<u64>,
}

/// A fresh config dir for each rig, the proptest's cases included.
fn config_dir(test: &str) -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("hub-onboarding")
        .join(format!("{test}-{}", NEXT.fetch_add(1, Ordering::Relaxed)));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

impl Rig {
    /// A shell that follows an MC, on this device's preferences in a
    /// config dir of its own (none: every save fails).
    fn new(test: Option<&str>) -> Rig {
        Rig::with(test, Some("http://127.0.0.1:1"), |_| {})
    }

    /// A shell that started without an MC.
    fn disconnected(test: &str) -> Rig {
        Rig::with(Some(test), None, |_| {})
    }

    fn with(test: Option<&str>, origin: Option<&str>, prepare: impl FnOnce(&PathBuf)) -> Rig {
        let engine = App::new("test")
            .register(hal_c2_shell::register)
            .build_engine();
        let window = TestWindow::new(&engine, 100.0, 100.0);
        let pinned = NOW.parse::<DateTime<Utc>>().unwrap().timestamp_millis();
        engine.set_wall_clock_origin(Some(pinned as f64));
        let dir = test.map(config_dir);
        if let Some(dir) = &dir {
            std::fs::create_dir_all(dir).unwrap();
            prepare(dir);
        }
        let mc = Rc::new(OnboardingMc::default());
        mc.connected.set(origin.is_some());
        let launch = Launch {
            config_dir: dir.clone(),
            mc_origin: origin.map(str::to_owned),
            ..Launch::default()
        };
        hal_c2_shell::start(&engine, &launch, mc.clone());
        Rig {
            engine,
            window: RefCell::new(window),
            mc,
            dir,
            rev: Cell::new(0),
        }
    }

    fn state(&self) -> Json {
        Bridge::of(&self.engine)
            .published(&self.engine, "onboarding")
            .unwrap_or(Json::Null)
    }

    fn dispatch(&self, action: &str, payload: Json) {
        Bridge::of(&self.engine).dispatch(&self.engine, action, payload);
    }

    fn advance(&self, ms: u64) {
        self.window
            .borrow_mut()
            .advance(ms)
            .expect("the hub comes to rest");
    }

    fn onboarding<R>(&self, f: impl FnOnce(&mut Onboarding, &Engine) -> R) -> R {
        controller::with::<Onboarding, R>(&self.engine, f).expect("the controller is free")
    }

    /// The cluster: `env-1` (Laptop, its own computer) and `others`
    /// `(environment, label, online)`, with `projects` `(id, root)` on
    /// `env-1` and `threads` `(id, project)`.
    fn shell(&self, others: &[(&str, &str, bool)], projects: &[(&str, &str)], threads: &[&str]) {
        self.rev.set(self.rev.get() + 1);
        let at = "2026-09-01T09:00:00Z";
        let mut mcs = vec![
            json!({"mc": "a", "online": true, "epoch": "e", "rev": self.rev.get(),
            "environment": {"environmentId": "env-1", "label": "Laptop"}}),
        ];
        for (i, (environment, label, online)) in others.iter().enumerate() {
            mcs.push(
                json!({"mc": format!("m{i}"), "online": online, "epoch": "e", "rev": self.rev.get(),
                "environment": {"environmentId": environment, "label": label}}),
            );
        }
        let mut rows: Vec<Json> = projects
            .iter()
            .map(|(id, root)| {
                json!(["a", id, "project", {"id": id, "title": id, "workspaceRoot": root,
                    "createdAt": at, "updatedAt": at}])
            })
            .collect();
        rows.extend(threads.iter().map(|id| {
            json!(["a", id, "thread", {"id": id, "projectId": projects.first().map_or("p0", |p| p.0),
                "title": id, "createdAt": at, "updatedAt": at,
                "modelSelection": {"instanceId": "claude", "model": "m"}}])
        }));
        self.mc.inner.frame(
            &self.engine,
            "shell",
            "",
            json!({"t": "shell", "mcs": mcs, "rows": rows}),
        );
    }

    fn preferences(&self) -> Json {
        let path = self.dir.as_ref().unwrap().join("preferences.json");
        std::fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or(Json::Null)
    }

    fn answer(&self, method: &str, result: Result<Json, McError>) {
        self.mc.inner.answer(&self.engine, method, result);
    }

    fn toasts(&self) -> Vec<(String, String)> {
        Bridge::of(&self.engine)
            .published(&self.engine, "toasts")
            .unwrap_or(Json::Null)["items"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .iter()
            .map(|i| {
                (
                    i["title"].as_str().unwrap_or_default().to_owned(),
                    i["description"].as_str().unwrap_or_default().to_owned(),
                )
            })
            .collect()
    }

    /// The MC's config for `env-1`: its cwd, platform and `providers`.
    fn config(&self, providers: Json, settings: Json) {
        self.mc.inner.frame(
            &self.engine,
            "config",
            "env-1",
            json!({"t": "config", "config": {
                "cwd": "/home/ada",
                "environment": {"platform": {"os": "linux"}},
                "providers": providers,
                "settings": settings,
            }}),
        );
    }

    /// The wizard on its agents step, for `env-1`.
    fn to_agents(&self) {
        self.shell(&[], &[], &[]);
        self.dispatch("onboarding.continue", json!({}));
        assert_eq!(self.state()["step"], "agents");
    }

    /// The wizard on its import step, `candidates` found on `env-1`.
    fn to_import(&self, candidates: Json) {
        self.to_agents();
        self.dispatch("onboarding.continue", json!({}));
        assert_eq!(self.state()["step"], "import");
        self.answer("agentSessions.scan", Ok(json!({"candidates": candidates})));
    }

    fn terminal_shapes(&self) -> Vec<Json> {
        self.mc
            .inner
            .subscriptions()
            .into_iter()
            .map(|(_, shape)| shape)
            .filter(|shape| shape["type"] == "terminal")
            .collect()
    }

    fn writes(&self) -> Vec<String> {
        self.mc
            .inner
            .calls
            .borrow()
            .iter()
            .filter(|(_, method, _)| method == "terminal.write")
            .map(|(_, _, payload)| payload["data"].as_str().unwrap_or_default().to_owned())
            .collect()
    }

    fn terminal_object(&self) -> Value {
        read(
            &self.engine,
            self.engine.singleton::<OnboardingObject>().unwrap(),
            "terminal",
        )
    }
}

fn provider(driver: &str, instance: &str, state: &str) -> Json {
    let installed = state != "not installed";
    let signed_in = state == "signed in";
    json!({
        "instanceId": instance,
        "driver": driver,
        "enabled": true,
        "installed": installed,
        "status": if signed_in { "ready" } else { "error" },
        "auth": {"status": if !installed { "unknown" } else if signed_in { "authenticated" } else { "unauthenticated" }},
    })
}

fn candidate(path: &str, git: Json, threads: i64, last: &str) -> Json {
    json!({"path": path, "title": path.rsplit('/').next().unwrap(), "git": git,
        "threadCount": threads, "lastActiveAt": last, "sources": ["codex"]})
}

fn repository(name: &str) -> Json {
    json!({"remoteKey": format!("github.com/{name}"), "repository": name})
}

/// A busy recent repository (selected by default), a quiet one, and a
/// plain folder.
fn three_projects() -> Json {
    json!([
        candidate(
            "/home/ada/api",
            repository("acme/api"),
            5,
            "2026-09-22T10:00:00.000Z"
        ),
        candidate(
            "/home/ada/site",
            repository("acme/site"),
            1,
            "2026-09-21T10:00:00.000Z"
        ),
        candidate("/home/ada/notes", Json::Null, 4, "2026-09-20T10:00:00.000Z"),
    ])
}

fn error(message: &str) -> Result<Json, McError> {
    Err(McError::new(message))
}

// -- The first-run gate --------------------------------------------------------

#[test]
fn a_fresh_device_on_an_empty_cluster_is_welcomed() {
    let rig = Rig::new(Some("fresh"));
    assert_eq!(rig.state()["gate"], "pending");
    rig.shell(&[], &[], &[]);
    let state = rig.state();
    assert_eq!(state["gate"], "wizard");
    assert_eq!(state["step"], "connection");
    assert_eq!(
        state["computers"],
        json!([{"environmentId": "env-1", "label": "Laptop", "connected": true, "selected": true}])
    );
    assert_eq!(state["canContinue"], true);
    // Nothing is saved until setup finishes.
    assert_eq!(rig.preferences(), Json::Null);
}

#[test]
fn a_workspace_with_projects_counts_as_set_up_and_says_so_quietly() {
    let rig = Rig::new(Some("existing"));
    rig.shell(&[], &[("p1", "/work/shop")], &[]);
    assert_eq!(rig.state()["gate"], "app");
    assert_eq!(
        rig.preferences(),
        json!({"onboardingCompletedAt": "2026-09-23T10:00:00.000Z"})
    );
    // Threads alone count too.
    let rig = Rig::new(Some("existing-threads"));
    rig.shell(&[], &[], &["t1"]);
    assert_eq!(rig.state()["gate"], "app");
}

#[test]
fn a_device_that_finished_setup_opens_the_app_before_the_mc_answers() {
    let rig = Rig::with(Some("finished"), Some("http://127.0.0.1:1"), |dir| {
        std::fs::write(
            dir.join("preferences.json"),
            r#"{"onboardingCompletedAt": "2026-01-05T09:00:00.000Z"}"#,
        )
        .unwrap();
    });
    rig.onboarding(hal_c2_shell::controller::Controller::preview);
    assert_eq!(rig.state()["gate"], "app");
}

#[test]
fn an_mc_that_does_not_answer_is_offered_a_reconnect() {
    let rig = Rig::new(Some("stalled"));
    rig.advance(3999);
    assert_eq!(rig.state()["recovery"], Json::Null);
    rig.advance(1);
    assert_eq!(rig.state()["recovery"], "connection");
    assert_eq!(rig.state()["gate"], "pending");

    rig.dispatch("onboarding.reload", json!({}));
    assert_eq!(rig.mc.reconnects.get(), 1);
    assert_eq!(rig.state()["recovery"], Json::Null);
    // The wait starts over.
    rig.advance(4000);
    assert_eq!(rig.state()["recovery"], "connection");
    // The answer comes after all.
    rig.shell(&[], &[], &[]);
    assert_eq!(
        (rig.state()["gate"].clone(), rig.state()["recovery"].clone()),
        (json!("wizard"), Json::Null)
    );
}

#[test]
fn preferences_that_cannot_be_read_stop_the_gate_until_they_can() {
    let rig = Rig::with(Some("unreadable"), Some("http://127.0.0.1:1"), |dir| {
        std::fs::write(dir.join("preferences.json"), "[1, 2").unwrap();
    });
    rig.shell(&[], &[("p1", "/work/shop")], &[]);
    assert_eq!(
        (rig.state()["gate"].clone(), rig.state()["recovery"].clone()),
        (json!("pending"), json!("settings"))
    );
    // Not saved over.
    let path = rig.dir.as_ref().unwrap().join("preferences.json");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "[1, 2");

    std::fs::write(&path, "{}").unwrap();
    rig.dispatch("onboarding.retry", json!({}));
    assert_eq!(
        (rig.state()["gate"].clone(), rig.state()["recovery"].clone()),
        (json!("app"), Json::Null)
    );
}

/// tst_OnboardingRegression::aFailedSaveOfTheFirstRunSettlesOnce: the
/// quiet save failing says the device changed, which must not decide again.
#[test]
fn a_failed_save_of_the_first_run_settles_once() {
    let rig = Rig::new(None);
    rig.shell(&[], &[("p1", "/work/shop")], &[]);
    assert_eq!(rig.state()["gate"], "app");
    assert!(!Settings::of(&rig.engine).device_error().is_empty());
    assert!(rig.toasts().is_empty());
}

#[test]
fn finishing_when_the_settings_cannot_be_saved_says_so_once() {
    let rig = Rig::new(None);
    rig.shell(&[], &[], &[]);
    rig.dispatch("onboarding.continue", json!({}));
    rig.dispatch("onboarding.continue", json!({}));
    rig.dispatch("onboarding.skip", json!({}));
    assert_eq!(rig.state()["gate"], "wizard");
    let toast = (
        "Could not finish setup".to_owned(),
        "Your settings could not be saved. Try again.".to_owned(),
    );
    assert_eq!(rig.toasts(), std::slice::from_ref(&toast));
    // Again: the same toast, not a second.
    rig.dispatch("onboarding.skip", json!({}));
    assert_eq!(rig.toasts(), [toast]);
}

// -- Connect your computers -----------------------------------------------------

#[test]
fn every_computer_of_the_cluster_is_offered_once_and_selected_once() {
    let rig = Rig::new(Some("computers"));
    rig.shell(
        &[("env-3", "Studio", true), ("env-2", "Attic", true)],
        &[],
        &[],
    );
    let ids: Vec<_> = rig.state()["computers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| (c["label"].clone(), c["selected"].clone()))
        .collect();
    assert_eq!(
        ids,
        [
            (json!("Laptop"), json!(true)),
            (json!("Attic"), json!(true)),
            (json!("Studio"), json!(true)),
        ]
    );
    rig.dispatch(
        "onboarding.select",
        json!({"environmentId": "env-2", "selected": false}),
    );
    // Listed again: what the user unchecked stays unchecked.
    rig.shell(
        &[("env-3", "Studio", true), ("env-2", "Attic", true)],
        &[],
        &[],
    );
    assert_eq!(rig.state()["computers"][1]["selected"], false);
    rig.dispatch("onboarding.continue", json!({}));
    assert_eq!(
        rig.mc
            .inner
            .calls
            .borrow()
            .iter()
            .filter(|(_, m, _)| m == "server.refreshProviders")
            .map(|(env, _, _)| env.clone())
            .collect::<Vec<_>>(),
        ["env-1", "env-3"]
    );
}

#[test]
fn a_selected_computer_that_is_offline_holds_the_wizard() {
    let rig = Rig::new(Some("offline"));
    rig.shell(&[("env-2", "Studio", false)], &[], &[]);
    assert_eq!(rig.state()["canContinue"], false);
    rig.dispatch("onboarding.continue", json!({}));
    assert_eq!(rig.state()["step"], "connection");
    rig.dispatch(
        "onboarding.select",
        json!({"environmentId": "env-2", "selected": false}),
    );
    assert_eq!(rig.state()["canContinue"], true);
    // Nothing selected: nothing to set up.
    rig.dispatch(
        "onboarding.select",
        json!({"environmentId": "env-1", "selected": false}),
    );
    assert_eq!(rig.state()["canContinue"], false);
}

#[test]
fn a_pairing_link_joins_the_cluster_of_its_computer() {
    let rig = Rig::new(Some("join"));
    rig.shell(&[], &[], &[]);
    rig.dispatch(
        "onboarding.pair",
        json!({"pairingUrl": "  https://studio.example/pair#token=T0KEN  "}),
    );
    assert_eq!(
        rig.mc.inner.calls.borrow().last().cloned().unwrap(),
        (
            "env-1".to_owned(),
            "cluster.join".to_owned(),
            json!({"link": "https://studio.example/pair#token=T0KEN"})
        )
    );
    assert_eq!(
        (
            rig.state()["pairing"].clone(),
            rig.state()["canContinue"].clone()
        ),
        (json!(true), json!(false))
    );
    // Not while it is pairing.
    rig.dispatch("onboarding.continue", json!({}));
    assert_eq!(rig.state()["step"], "connection");
    rig.answer("cluster.join", error("That link was used already"));
    let state = rig.state();
    assert_eq!(
        (
            state["pairing"].clone(),
            state["pairingError"].clone(),
            state["pairingDetail"].clone()
        ),
        (
            json!(false),
            json!("Pairing failed."),
            json!("That link was used already")
        )
    );
    // A second try clears the error; the new computer is offered as the
    // cluster lists it.
    rig.dispatch(
        "onboarding.pair",
        json!({"pairingUrl": "https://studio.example/pair#token=AGAIN"}),
    );
    assert_eq!(rig.state()["pairingError"], "");
    rig.answer("cluster.join", Ok(json!({})));
    rig.shell(&[("env-2", "Studio", true)], &[], &[]);
    assert_eq!(rig.state()["computers"][1]["environmentId"], "env-2");
}

#[test]
fn a_shell_started_without_an_mc_pairs_and_connects_from_the_wizard() {
    let rig = Rig::disconnected("disconnected");
    // Nothing to ask: the wizard, with no computer yet.
    assert_eq!(rig.state()["gate"], "wizard");
    assert_eq!(rig.state()["computers"], json!([]));
    assert!(!hal_c2_shell::has_mc(&rig.engine));

    rig.dispatch("onboarding.pair", json!({"pairingUrl": "not a link"}));
    assert_eq!(
        rig.state()["pairingDetail"],
        "Enter a pairing link from the environment."
    );

    rig.onboarding(|c, _| {
        c.set_exchange(Arc::new(|link, client| {
            assert_eq!(link.token, "T0KEN");
            assert_eq!(client.device_type, "desktop");
            let mut descriptor = Map::new();
            descriptor.insert("label".into(), json!("Laptop"));
            descriptor.insert("environmentId".into(), json!("env-1"));
            Pairing {
                outcome: Outcome::Paired,
                origin: "https://laptop.example".into(),
                token: "session".into(),
                descriptor,
            }
        }))
    });
    rig.dispatch(
        "onboarding.pair",
        json!({"pairingUrl": "https://laptop.example/pair#token=T0KEN"}),
    );
    assert_eq!(rig.state()["pairing"], true);
    Platform::of(&rig.engine).finish(&rig.engine);
    assert_eq!(
        *rig.mc.opened.borrow(),
        [("https://laptop.example".to_owned(), "session".to_owned())]
    );
    assert!(hal_c2_shell::has_mc(&rig.engine));
    assert_eq!(
        (
            rig.state()["pairing"].clone(),
            rig.state()["pairingError"].clone()
        ),
        (json!(false), json!(""))
    );
    // The MC it opened says what it has.
    rig.shell(&[], &[], &[]);
    assert_eq!(rig.state()["computers"][0]["label"], "Laptop");
    assert_eq!(rig.state()["gate"], "wizard");
    // A second link now joins that MC's cluster.
    rig.dispatch(
        "onboarding.pair",
        json!({"pairingUrl": "https://studio.example/pair#token=NEXT"}),
    );
    assert!(rig.mc.inner.pending("cluster.join").is_some());
}

#[test]
fn a_link_no_mc_takes_says_why() {
    let rig = Rig::disconnected("disconnected-refused");
    let outcomes = [
        (
            Outcome::Unreachable,
            "No environment answered at https://x.example.",
        ),
        (
            Outcome::NotMc,
            "https://x.example is not a HAL-C2 environment.",
        ),
        (
            Outcome::Incompatible,
            "https://x.example runs another version of HAL-C2.",
        ),
        (
            Outcome::Refused,
            "The pairing link is invalid or expired. Ask for a fresh one.",
        ),
    ];
    for (outcome, detail) in outcomes {
        rig.onboarding(move |c, _| {
            c.set_exchange(Arc::new(move |_, _| Pairing {
                outcome,
                origin: "https://x.example".into(),
                token: String::new(),
                descriptor: Map::new(),
            }))
        });
        rig.dispatch(
            "onboarding.pair",
            json!({"pairingUrl": "https://x.example/pair#token=T0KEN"}),
        );
        Platform::of(&rig.engine).finish(&rig.engine);
        let state = rig.state();
        assert_eq!(
            (
                state["pairingError"].clone(),
                state["pairingDetail"].clone()
            ),
            (json!("Pairing failed."), json!(detail))
        );
    }
    assert!(rig.mc.opened.borrow().is_empty());
    assert!(!hal_c2_shell::has_mc(&rig.engine));
}

// -- Set up your agents ---------------------------------------------------------

#[test]
fn each_agent_card_tells_how_far_its_provider_is() {
    let rig = Rig::new(Some("cards"));
    rig.to_agents();
    let cards = |rig: &Rig| {
        rig.state()["agents"][0]["cards"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["state"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>()
    };
    assert_eq!(cards(&rig), ["checking", "checking"]);
    assert_eq!(
        rig.state()["agents"][0]["cards"][0]["headline"],
        "Checking provider status"
    );
    rig.config(
        json!([
            provider("claudeAgent", "claudeAgent", "signed in"),
            provider("codex", "codex", "signed out")
        ]),
        json!({}),
    );
    assert_eq!(cards(&rig), ["ready", "signIn"]);
    // What the refresh says replaces what the config said.
    rig.answer(
        "server.refreshProviders",
        Ok(json!({"providers": [provider("codex", "codex", "not installed")]})),
    );
    assert_eq!(cards(&rig), ["checking", "install"]);
}

#[test]
fn installing_an_agent_types_its_installer_in_a_terminal() {
    let rig = Rig::new(Some("install"));
    terminals::set_supported(&rig.engine, true);
    rig.to_agents();
    rig.config(
        json!([provider("codex", "codex", "not installed")]),
        json!({}),
    );
    assert_eq!(
        rig.state()["agents"][0]["cards"][1]["terminalAvailable"],
        true
    );
    rig.dispatch(
        "onboarding.agent",
        json!({"environmentId": "env-1", "driver": "codex"}),
    );
    let shapes = rig.terminal_shapes();
    assert_eq!(shapes.len(), 1);
    assert_eq!(shapes[0]["input"]["cwd"], "/home/ada");
    assert_eq!(shapes[0]["input"]["threadId"], "onboarding-agent-setup");
    let terminal = rig.state()["terminal"].clone();
    assert_eq!(
        (terminal["status"].clone(), terminal["command"].clone()),
        (
            json!("preparing"),
            json!("curl -fsSL https://chatgpt.com/codex/install.sh | sh")
        )
    );
    assert!(matches!(rig.terminal_object(), Value::Object(_)));
    assert_eq!(rig.state()["agents"][0]["cards"][1]["terminalOpen"], true);

    let id = shapes[0]["input"]["terminalId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(id.starts_with("onboarding-codex-"));
    rig.mc.inner.frame_where(
        &rig.engine,
        |shape| shape["type"] == "terminal",
        json!({"t": "terminal", "event": {"type": "snapshot", "snapshot": {"history": ""}}}),
    );
    assert_eq!(rig.state()["terminal"]["status"], "ready");
    // Typed, never run.
    assert_eq!(
        rig.writes(),
        ["curl -fsSL https://chatgpt.com/codex/install.sh | sh"]
    );

    rig.dispatch("onboarding.terminal.close", json!({}));
    assert_eq!(rig.state()["terminal"], Json::Null);
    assert_eq!(rig.terminal_object(), Value::Null);
    let close = rig
        .mc
        .inner
        .calls
        .borrow()
        .iter()
        .find(|(_, m, _)| m == "terminal.close")
        .cloned()
        .unwrap();
    assert_eq!(
        close.2,
        json!({"threadId": "onboarding-agent-setup", "terminalId": id, "deleteHistory": true})
    );
    // The cards look again.
    assert_eq!(
        rig.mc
            .inner
            .methods()
            .iter()
            .filter(|m| *m == "server.refreshProviders")
            .count(),
        2
    );
}

#[test]
fn signing_in_runs_the_instance_own_binary_with_its_env() {
    let rig = Rig::new(Some("sign-in"));
    terminals::set_supported(&rig.engine, true);
    rig.to_agents();
    rig.config(
        json!([provider("codex", "codex_work", "signed out")]),
        json!({"providerInstances": {"codex_work": {"driver": "codex",
            "config": {"binaryPath": "~/bin/codex work", "homePath": "/home/ada/.codex-work"}}}}),
    );
    rig.dispatch(
        "onboarding.agent",
        json!({"environmentId": "env-1", "driver": "codex"}),
    );
    assert_eq!(
        rig.terminal_shapes()[0]["input"]["providerInstanceId"],
        "codex_work"
    );
    rig.mc.inner.frame_where(
        &rig.engine,
        |shape| shape["type"] == "terminal",
        json!({"t": "terminal", "event": {"type": "snapshot", "snapshot": {"history": ""}}}),
    );
    assert_eq!(rig.writes(), ["~/'bin/codex work' login"]);
}

#[test]
fn a_terminal_the_mc_will_not_start_says_so_and_can_be_retried() {
    let rig = Rig::new(Some("terminal-refused"));
    terminals::set_supported(&rig.engine, true);
    rig.to_agents();
    rig.config(
        json!([provider("codex", "codex", "not installed")]),
        json!({}),
    );
    rig.dispatch(
        "onboarding.agent",
        json!({"environmentId": "env-1", "driver": "codex"}),
    );
    rig.mc.inner.frame_where(
        &rig.engine,
        |shape| shape["type"] == "terminal",
        json!({"t": "error", "reason": "Terminal limit reached on this machine"}),
    );
    assert_eq!(rig.state()["terminal"]["status"], "openFailed");
    assert_eq!(rig.terminal_object(), Value::Null);
    rig.dispatch("onboarding.terminal.retry", json!({}));
    assert_eq!(rig.state()["terminal"]["status"], "preparing");
    assert!(matches!(rig.terminal_object(), Value::Object(_)));
    // Leaving the step closes it.
    rig.dispatch("onboarding.stage", json!({"index": 0}));
    assert_eq!(rig.state()["terminal"], Json::Null);
    assert_eq!(rig.state()["step"], "connection");
}

#[test]
fn without_terminals_the_cards_offer_none() {
    let rig = Rig::new(Some("no-terminals"));
    terminals::set_supported(&rig.engine, false);
    rig.to_agents();
    rig.config(
        json!([provider("codex", "codex", "not installed")]),
        json!({}),
    );
    assert_eq!(
        rig.state()["agents"][0]["cards"][1]["terminalAvailable"],
        false
    );
    rig.dispatch(
        "onboarding.agent",
        json!({"environmentId": "env-1", "driver": "codex"}),
    );
    assert_eq!(rig.state()["terminal"], Json::Null);
}

// -- Import your projects -------------------------------------------------------

#[test]
fn busy_recent_repositories_are_selected_by_default() {
    let rig = Rig::new(Some("default-selection"));
    rig.to_import(three_projects());
    let import = rig.state()["import"].clone();
    assert_eq!(
        (import["total"].clone(), import["selectedCount"].clone()),
        (json!(3), json!(1))
    );
    let scan = &import["scans"][0];
    assert_eq!(scan["label"], "Laptop");
    let groups: Vec<_> = scan["repositories"]
        .as_array()
        .unwrap()
        .iter()
        .map(|g| (g["label"].clone(), g["checked"].clone(), g["age"].clone()))
        .collect();
    assert_eq!(
        groups,
        [
            (json!("acme/api"), json!(true), json!("1d")),
            (json!("acme/site"), json!(false), json!("2d")),
        ]
    );
    assert_eq!(scan["other"]["count"], 1);
    assert_eq!(scan["repositories"][0]["secondary"], "/home/ada/api");
}

#[test]
fn every_project_or_none_can_be_selected() {
    let rig = Rig::new(Some("select-all"));
    rig.to_import(three_projects());
    rig.dispatch("onboarding.selectAll", json!({}));
    assert_eq!(rig.state()["import"]["selectedCount"], 3);
    rig.dispatch("onboarding.selectNone", json!({}));
    assert_eq!(rig.state()["import"]["selectedCount"], 0);
    let key = rig.state()["import"]["scans"][0]["other"]["candidates"][0]["key"].clone();
    rig.dispatch(
        "onboarding.project",
        json!({"keys": [key], "selected": true}),
    );
    assert_eq!(rig.state()["import"]["scans"][0]["other"]["checked"], true);
    // Nothing selected: importing finishes setup.
    rig.dispatch("onboarding.selectNone", json!({}));
    rig.dispatch("onboarding.import", json!({}));
    assert_eq!(rig.state()["gate"], "app");
}

#[test]
fn an_import_the_mc_refuses_says_so_and_can_be_skipped() {
    let rig = Rig::new(Some("import-refused"));
    rig.to_import(three_projects());
    rig.dispatch("onboarding.import", json!({}));
    assert_eq!(rig.state()["importing"], true);
    let create = rig.mc.inner.calls.borrow().last().cloned().unwrap();
    assert_eq!(create.1, "projects.mutate");
    assert_eq!(create.2["type"], "project.create");
    assert_eq!(create.2["workspaceRoot"], "/home/ada/api");
    assert_eq!(create.2["createWorkspaceRootIfMissing"], false);
    rig.answer("projects.mutate", Ok(json!({})));
    let import = rig.mc.inner.calls.borrow().last().cloned().unwrap();
    assert_eq!(
        import.2,
        json!({"projectId": create.2["projectId"], "expectedWorkspaceRoot": "/home/ada/api"})
    );
    rig.answer("agentSessions.import", error("no"));
    let state = rig.state();
    assert_eq!(
        (state["importing"].clone(), state["import"]["error"].clone()),
        (json!(false), json!("Could not import thread history."))
    );
    // The computer is looked at again.
    assert!(rig.mc.inner.pending("agentSessions.scan").is_some());
    rig.dispatch("onboarding.skip", json!({}));
    assert_eq!(rig.state()["gate"], "app");
}

#[test]
fn partial_imports_say_what_landed() {
    let rig = Rig::new(Some("import-partial"));
    rig.to_import(three_projects());
    rig.dispatch("onboarding.import", json!({}));
    rig.answer("projects.mutate", Ok(json!({})));
    rig.answer(
        "agentSessions.import",
        Ok(json!({"importedCount": 2, "skippedCount": 1})),
    );
    assert_eq!(
        rig.state()["import"]["error"],
        "Imported 2 threads. 1 thread could not be imported."
    );
}

#[test]
fn while_importing_the_wizard_stays_put_and_lands_on_the_project() {
    let rig = Rig::new(Some("importing"));
    rig.to_import(
        json!([{"path": "/home/ada/api", "title": "api", "projectId": "p1",
        "git": repository("acme/api"), "threadCount": 5,
        "lastActiveAt": "2026-09-22T10:00:00.000Z", "sources": ["claudeAgent"]}]),
    );
    rig.dispatch("onboarding.import", json!({}));
    // Its project is the MC's already: straight to its history.
    assert!(rig.mc.inner.pending("projects.mutate").is_none());
    assert!(rig.mc.inner.pending("agentSessions.import").is_some());
    rig.dispatch("onboarding.stage", json!({"index": 0}));
    rig.dispatch("onboarding.skip", json!({}));
    rig.dispatch("onboarding.selectNone", json!({}));
    let state = rig.state();
    assert_eq!(
        (
            state["gate"].clone(),
            state["step"].clone(),
            state["importing"].clone(),
            state["import"]["selectedCount"].clone()
        ),
        (json!("wizard"), json!("import"), json!(true), json!(1))
    );
    rig.answer(
        "agentSessions.import",
        Ok(json!({"importedCount": 3, "skippedCount": 0})),
    );
    // Not listed yet: it waits for the shell to list it.
    assert_eq!(
        (
            rig.state()["gate"].clone(),
            rig.state()["importing"].clone()
        ),
        (json!("wizard"), json!(true))
    );
    rig.shell(&[], &[("p1", "/home/ada/api")], &[]);
    assert_eq!(rig.state()["gate"], "app");
    assert_eq!(
        rig.preferences()["onboardingCompletedAt"],
        "2026-09-23T10:00:00.000Z"
    );
}

#[test]
fn going_back_keeps_the_choices_made() {
    let rig = Rig::new(Some("back"));
    rig.shell(&[("env-2", "Studio", true)], &[], &[]);
    rig.dispatch(
        "onboarding.select",
        json!({"environmentId": "env-2", "selected": false}),
    );
    rig.dispatch("onboarding.continue", json!({}));
    rig.dispatch("onboarding.stage", json!({"index": 0}));
    assert_eq!(rig.state()["stage"], 0);
    assert_eq!(rig.state()["computers"][1]["selected"], false);
    // The progress bar goes back only.
    rig.dispatch("onboarding.stage", json!({"index": 2}));
    assert_eq!(rig.state()["stage"], 0);
}

// -- The model ------------------------------------------------------------------

/// What the user and the MC do to the wizard, in any order.
#[derive(Clone, Debug)]
enum Op {
    Advance(u64),
    Reload,
    /// The MC's rows: with the project `p1` or without.
    Snapshot(bool),
    Select(bool),
    Pair,
    AnswerJoin(bool),
    Continue,
    Stage(i64),
    AnswerScan,
    Import,
    /// The import's answer: refused, or with that many skipped.
    AnswerImport(Option<i64>),
    Skip,
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        2 => (0u64..3000).prop_map(Op::Advance),
        1 => Just(Op::Reload),
        2 => any::<bool>().prop_map(Op::Snapshot),
        1 => any::<bool>().prop_map(Op::Select),
        2 => Just(Op::Pair),
        2 => any::<bool>().prop_map(Op::AnswerJoin),
        3 => Just(Op::Continue),
        1 => (0i64..3).prop_map(Op::Stage),
        2 => Just(Op::AnswerScan),
        2 => Just(Op::Import),
        2 => prop_oneof![Just(None), (0i64..2).prop_map(Some)].prop_map(Op::AnswerImport),
        1 => Just(Op::Skip),
    ]
}

/// What the wizard should say: the C++'s rules, step by step.
#[derive(Debug)]
struct Model {
    gate: &'static str,
    /// Virtual ms until the decision timer fires, while it runs.
    timer: Option<u64>,
    stalled: bool,
    active: bool,
    listed: bool,
    selected: bool,
    pairing: bool,
    pair_failed: bool,
    step: i64,
    scanned_once: bool,
    scans_pending: u32,
    found: bool,
    importing: bool,
    import_pending: bool,
    imported: bool,
    /// Some of its history landed, all of it or not.
    history: bool,
    landing: bool,
    import_failed: bool,
}

impl Model {
    fn new() -> Model {
        Model {
            gate: "pending",
            timer: Some(4000),
            stalled: false,
            active: false,
            listed: false,
            selected: true,
            pairing: false,
            pair_failed: false,
            step: 0,
            scanned_once: false,
            scans_pending: 0,
            found: false,
            importing: false,
            import_pending: false,
            imported: false,
            history: false,
            landing: false,
            import_failed: false,
        }
    }

    fn settle(&mut self, gate: &'static str) {
        self.gate = gate;
        self.stalled = false;
        self.timer = None;
    }

    fn wizard(&self) -> bool {
        self.active && self.gate == "wizard"
    }

    fn finish(&mut self) {
        self.importing = false;
        self.gate = "app";
    }

    fn finish_after_import(&mut self) {
        if !(self.imported || self.history) || self.listed {
            self.finish();
        } else {
            self.importing = true;
            self.landing = true;
        }
    }

    fn set_stage(&mut self, index: i64) {
        if self.importing {
            return;
        }
        if index == 2 && self.step == 1 {
            self.step = 2;
            if !self.scanned_once {
                self.scanned_once = true;
                self.scans_pending += 1;
            }
            return;
        }
        if index >= self.step {
            return;
        }
        self.step = index;
    }
}

#[test]
fn the_wizard_follows_its_rules_in_any_order() {
    // Runs start before the MC answers, in the wizard, or on its import
    // step: an early import or skip ends most runs before the import's
    // rules are reached.
    proptest!(ProptestConfig::with_cases(128), |(start in 0usize..3, ops in prop::collection::vec(op(), 1..60))| {
        let rig = Rig::new(Some("model"));
        let starts = [
            vec![],
            vec![Op::Snapshot(false)],
            vec![Op::Snapshot(false), Op::Continue, Op::Continue, Op::AnswerScan],
        ];
        let ops = starts[start].clone().into_iter().chain(ops);
        let mut m = Model::new();
        let candidates = json!([{"path": "/home/ada/api", "title": "api", "projectId": "p1",
            "git": repository("acme/api"), "threadCount": 5,
            "lastActiveAt": "2026-09-22T10:00:00.000Z", "sources": ["codex"]}]);
        for op in ops {
            match op {
                Op::Advance(ms) => {
                    rig.advance(ms);
                    if let Some(left) = m.timer {
                        if left <= ms {
                            m.timer = None;
                            m.stalled = m.gate == "pending";
                        } else {
                            m.timer = Some(left - ms);
                        }
                    }
                }
                Op::Reload => {
                    rig.dispatch("onboarding.reload", json!({}));
                    m.stalled = false;
                    if m.gate == "pending" {
                        m.timer = Some(4000);
                    }
                }
                Op::Snapshot(listed) => {
                    let projects: &[(&str, &str)] = if listed { &[("p1", "/home/ada/api")] } else { &[] };
                    rig.shell(&[], projects, &[]);
                    m.listed = listed;
                    if !m.active {
                        m.active = true;
                        if m.gate == "pending" {
                            m.settle(if listed { "app" } else { "wizard" });
                        }
                    } else if m.landing && listed {
                        m.landing = false;
                        m.finish();
                    }
                }
                Op::Select(selected) => {
                    rig.dispatch("onboarding.select", json!({"environmentId": "env-1", "selected": selected}));
                    if m.wizard() {
                        m.selected = selected;
                    }
                }
                Op::Pair => {
                    rig.dispatch("onboarding.pair", json!({"pairingUrl": "https://studio.example/pair#token=T"}));
                    if m.wizard() && !m.pairing {
                        m.pairing = true;
                        m.pair_failed = false;
                    }
                }
                Op::AnswerJoin(ok) => {
                    if rig.mc.inner.pending("cluster.join").is_some() {
                        rig.answer("cluster.join", if ok { Ok(json!({})) } else { error("no") });
                        m.pairing = false;
                        m.pair_failed = !ok;
                    }
                }
                Op::Continue => {
                    rig.dispatch("onboarding.continue", json!({}));
                    if m.wizard() {
                        match m.step {
                            0 if m.selected && !m.pairing => m.step = 1,
                            1 => m.set_stage(2),
                            _ => {}
                        }
                    }
                }
                Op::Stage(index) => {
                    rig.dispatch("onboarding.stage", json!({"index": index}));
                    if m.wizard() {
                        m.set_stage(index);
                    }
                }
                Op::AnswerScan => {
                    if rig.mc.inner.pending("agentSessions.scan").is_some() {
                        rig.answer("agentSessions.scan", Ok(json!({"candidates": candidates.clone()})));
                        m.scans_pending -= 1;
                        m.found = true;
                    }
                }
                Op::Import => {
                    rig.dispatch("onboarding.import", json!({}));
                    if m.wizard() && !m.importing {
                        if !m.found {
                            m.finish();
                        } else {
                            m.importing = true;
                            m.import_failed = false;
                            if m.imported {
                                m.finish_after_import();
                            } else {
                                m.import_pending = true;
                            }
                        }
                    }
                }
                Op::AnswerImport(answer) => {
                    if m.import_pending {
                        let result = match answer {
                            None => error("no"),
                            Some(skipped) => Ok(json!({"importedCount": 2, "skippedCount": skipped})),
                        };
                        rig.answer("agentSessions.import", result);
                        m.import_pending = false;
                        m.history = m.history || answer.is_some();
                        match answer {
                            Some(0) => {
                                m.imported = true;
                                m.finish_after_import();
                            }
                            failed => {
                                if failed.is_none() {
                                    m.scans_pending += 1;
                                }
                                m.importing = false;
                                m.import_failed = true;
                            }
                        }
                    }
                }
                Op::Skip => {
                    rig.dispatch("onboarding.skip", json!({}));
                    if m.wizard() && !m.importing {
                        if m.import_failed {
                            m.finish_after_import();
                        } else {
                            m.finish();
                        }
                    }
                }
            }
            let state = rig.state();
            let recovery = if m.gate == "pending" && m.stalled { json!("connection") } else { Json::Null };
            prop_assert_eq!(&state["gate"], &json!(m.gate), "{:?}", m);
            prop_assert_eq!(&state["recovery"], &recovery, "{:?}", m);
            prop_assert_eq!(&state["stage"], &json!(m.step), "{:?}", m);
            prop_assert_eq!(&state["importing"], &json!(m.importing), "{:?}", m);
            prop_assert_eq!(&state["pairing"], &json!(m.pairing), "{:?}", m);
            prop_assert_eq!(state["pairingError"] != "", m.pair_failed, "{:?}", m);
            prop_assert_eq!(state["import"]["error"].as_str().is_some_and(|e| !e.is_empty()),
                m.step == 2 && m.import_failed, "{:?}", m);
            prop_assert_eq!(&state["canContinue"], &json!(m.active && m.selected && !m.pairing), "{:?}", m);
            prop_assert_eq!(rig.mc.inner.pending("cluster.join").is_some(), m.pairing);
            prop_assert_eq!(rig.mc.inner.pending("agentSessions.import").is_some(), m.import_pending);
            // Whatever opened the app said so where the next start reads it.
            prop_assert_eq!(
                rig.preferences()["onboardingCompletedAt"].is_string(),
                m.gate == "app",
                "{:?}", m
            );
        }
    });
}
