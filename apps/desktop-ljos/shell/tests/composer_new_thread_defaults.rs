//! A new thread starts on the model and permissions its project's MC
//! names (the project row's `newThreadModelSelection` /
//! `newThreadRuntimeMode`), ahead of this device's own defaults; a model
//! carried in from the open thread gives way when the row arrives late,
//! and a draft routed to another machine takes that machine's defaults.
//!
//! The Gherkin scenario for the first of these ("A new thread on another
//! machine shows that machine's defaults") still carries
//! `@backlog-desktop` for desktop-qt (#1525), and the desktop-ljos
//! features runner shares the `@desktop` surface with desktop-qt, so no
//! ledger tag can hold it for this shell alone; these plain tests are the
//! guard that runs on the default `cargo test` path.

mod common;

use std::cell::{Cell, RefCell};
use std::path::Path;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::composer::kept;
use hal_c2_shell::controllers::drafts;
use hal_c2_shell::controllers::workspace::{self, Checkout};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Mc, OnFrame, OnReady, Reply, Resume, SubId};
use hal_c2_shell::{Launch, store};
use ljos::App;
use ljos::prelude::Engine;
use serde_json::json;

const ORIGIN: &str = "http://127.0.0.1:3773";
const AT: &str = "2026-09-23T09:00:00Z";

struct Call {
    method: String,
    reply: Option<Reply>,
}

/// An MC whose subscriptions the test feeds and whose calls it answers
/// (sidebar.rs's StreamingMc, keeping every subscription).
#[derive(Default)]
struct FakeMc {
    subs: RefCell<Vec<(SubId, Json, Option<OnFrame>)>>,
    calls: RefCell<Vec<Call>>,
    next: Cell<u64>,
}

impl FakeMc {
    fn send(&self, engine: &Engine, kind: &str, frame: Json) {
        let ids: Vec<SubId> = self
            .subs
            .borrow()
            .iter()
            .filter(|(_, shape, _)| shape["type"] == json!(kind))
            .map(|(id, _, _)| *id)
            .collect();
        for id in ids {
            let handler = self
                .subs
                .borrow_mut()
                .iter_mut()
                .find(|(i, _, _)| *i == id)
                .and_then(|(_, _, h)| h.take());
            let Some(mut handler) = handler else { continue };
            handler(engine, frame.as_object().expect("an object"));
            if let Some(slot) = self.subs.borrow_mut().iter_mut().find(|(i, _, _)| *i == id) {
                slot.2 = Some(handler);
            }
        }
    }

    fn answer(&self, engine: &Engine, method: &str, result: Json) {
        let index = self
            .calls
            .borrow()
            .iter()
            .position(|c| c.method == method && c.reply.is_some())
            .unwrap_or_else(|| panic!("no unanswered {method}"));
        let reply = self.calls.borrow_mut()[index]
            .reply
            .take()
            .expect("unanswered");
        reply(engine, Ok(result));
    }
}

impl Mc for FakeMc {
    fn is_ready(&self) -> bool {
        true
    }

    fn environment(&self) -> String {
        "env-a".into()
    }

    fn call(&self, _: &str, method: &str, _: Json, reply: Reply) {
        self.calls.borrow_mut().push(Call {
            method: method.into(),
            reply: Some(reply),
        });
    }

    fn subscribe(&self, shape: Json, on_frame: OnFrame, _: Option<Resume>) -> SubId {
        self.next.set(self.next.get() + 1);
        let id = SubId(self.next.get());
        self.subs.borrow_mut().push((id, shape, Some(on_frame)));
        id
    }

    fn unsubscribe(&self, id: SubId) {
        self.subs.borrow_mut().retain(|(i, _, _)| *i != id);
    }

    fn more(&self, _: SubId, _: u32) {}

    fn on_ready_changed(&self, _: OnReady) {}
}

fn start(cache: &Path) -> (Engine, Rc<FakeMc>) {
    let source = common::compile(&[("Main", "import QtQuick\nItem {}\n")], &[]);
    let engine = App::new("test")
        .register(hal_c2_shell::register)
        .source(source)
        .build_engine();
    let mc = Rc::new(FakeMc::default());
    let launch = Launch {
        mc_origin: Some(ORIGIN.into()),
        cache_dir: Some(cache.to_owned()),
        ..Launch::default()
    };
    hal_c2_shell::start(&engine, &launch, mc.clone());
    (engine, mc)
}

fn providers() -> Json {
    json!([
        {"instanceId": "codex", "driver": "codex", "displayName": "Codex",
         "enabled": true, "installed": true, "status": "ready",
         "models": [{"slug": "gpt-5", "name": "gpt-5"}]},
        {"instanceId": "claudeAgent", "driver": "claude", "displayName": "Claude",
         "enabled": true, "installed": true, "status": "ready",
         "models": [{"slug": "claude-opus", "name": "claude-opus"}]},
    ])
}

fn project_row(named: bool) -> Json {
    let mut row = json!({
        "id": "p1", "title": "Shop", "workspaceRoot": "/w/shop",
        "createdAt": AT, "updatedAt": AT,
    });
    if named {
        row["newThreadModelSelection"] =
            json!({"instanceId": "claudeAgent", "model": "claude-opus"});
        row["newThreadRuntimeMode"] = json!("approval-required");
    }
    row
}

fn thread_row() -> Json {
    json!({
        "id": "t1", "projectId": "p1", "title": "Thread t1",
        "createdAt": AT, "updatedAt": AT,
        "modelSelection": {"instanceId": "codex", "model": "gpt-5"},
        "runtimeMode": "full-access",
    })
}

/// The shell over one project with thread t1 on gpt-5; this device starts
/// new threads on gpt-5 with full access. `named` says whether the project
/// row already names claude-opus with Supervised access.
fn started(cache: &Path, named: bool) -> (Engine, Rc<FakeMc>) {
    let (engine, mc) = start(cache);
    mc.send(
        &engine,
        "shell",
        json!({
            "t": "shell",
            "mcs": [{"mc": "mc-a", "environment": {"environmentId": "env-a", "capabilities": {}},
                     "online": true, "epoch": "e1", "rev": 1}],
            "rows": [
                ["mc-a", "p1", "project", project_row(named)],
                ["mc-a", "t1", "thread", thread_row()],
            ],
        }),
    );
    mc.send(
        &engine,
        "config",
        json!({"t": "config", "config": {"providers": providers()}}),
    );
    // The config snapshot makes the shell read its settings document.
    mc.answer(
        &engine,
        "hal-c2.readSettings",
        json!({
            "settings": {
                "defaultModelSelection": {"instanceId": "codex", "model": "gpt-5"},
                "defaultRuntimeMode": "full-access",
            },
            "version": 1,
        }),
    );
    (engine, mc)
}

/// A project row arriving later (`rev` past the snapshot's).
fn send_project(engine: &Engine, mc: &FakeMc, rev: i64, named: bool) {
    mc.send(
        engine,
        "shell",
        json!({
            "t": "shell.rows", "mc": "mc-a", "epoch": "e1", "rev": rev,
            "rows": [["p1", "project", project_row(named)]],
        }),
    );
}

fn published(engine: &Engine, key: &str) -> Json {
    Bridge::of(engine)
        .published(engine, key)
        .unwrap_or(Json::Null)
}

fn composer(engine: &Engine) -> Json {
    published(engine, "composer")
}

fn route(engine: &Engine) -> Json {
    published(engine, "route")
}

/// The open draft's id, as the composer shows it.
fn open_draft(engine: &Engine) -> String {
    let state = composer(engine);
    assert_eq!(
        state["target"],
        route(engine)["draftId"],
        "composer: {state}"
    );
    state["target"].as_str().unwrap_or_default().to_owned()
}

#[test]
fn a_draft_starts_on_what_the_projects_mc_names() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, _mc) = started(dir.path(), true);
    let draft = open_draft(&engine);
    assert!(!draft.is_empty());
    let state = composer(&engine);
    assert_eq!(state["selectedInstanceId"], json!("claudeAgent"), "{state}");
    assert_eq!(state["selectedModel"], json!("claude-opus"), "{state}");
    assert_eq!(state["runtimeMode"], json!("approval-required"), "{state}");
    store::flush(&engine);
}

#[test]
fn a_carried_model_gives_way_when_the_row_names_one_later() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, mc) = started(dir.path(), false);
    // The open thread's model carries into its new thread.
    Bridge::of(&engine).dispatch(&engine, "thread.open", json!({"key": "env-a:t1"}));
    let draft = drafts::start_carrying(&engine, "env-a", "p1", true).expect("a draft");
    let kept = kept::draft_of(&engine, &draft);
    assert!(kept.carried, "{kept:?}");
    assert_eq!(
        kept.model_selection,
        Some(serde_json::from_value(json!({"instanceId": "codex", "model": "gpt-5"})).unwrap())
    );
    assert_eq!(composer(&engine)["selectedModel"], json!("gpt-5"));

    // The row arrives naming another model: the carried one is dropped.
    send_project(&engine, &mc, 2, true);
    assert_eq!(
        kept::draft_of(&engine, &draft).model_selection,
        None,
        "the carried model is dropped"
    );
    let state = composer(&engine);
    assert_eq!(state["selectedModel"], json!("claude-opus"), "{state}");
    assert_eq!(state["runtimeMode"], json!("approval-required"), "{state}");

    // A model the user picks stays, whatever the row later says.
    Bridge::of(&engine).dispatch(
        &engine,
        "composer.model.select",
        json!({"instanceId": "codex", "model": "gpt-5"}),
    );
    assert!(!kept::draft_of(&engine, &draft).carried);
    send_project(&engine, &mc, 3, true);
    assert_eq!(composer(&engine)["selectedModel"], json!("gpt-5"));
    store::flush(&engine);
}

#[test]
fn a_routed_draft_takes_the_launch_machines_defaults() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, mc) = start(dir.path());
    // Two machines with the same project; only env-b's row names defaults.
    let mut row_b = project_row(true);
    row_b["title"] = json!("Shop (Studio)");
    mc.send(
        &engine,
        "shell",
        json!({
            "t": "shell",
            "mcs": [
                {"mc": "mc-a", "environment": {"environmentId": "env-a", "capabilities": {}},
                 "online": true, "epoch": "e1", "rev": 1},
                {"mc": "mc-b", "environment": {"environmentId": "env-b", "label": "Studio", "capabilities": {}},
                 "online": true, "epoch": "e1", "rev": 1},
            ],
            "rows": [
                ["mc-a", "p1", "project", project_row(false)],
                ["mc-b", "p1", "project", row_b],
                ["mc-a", "t1", "thread", thread_row()],
            ],
        }),
    );
    mc.send(
        &engine,
        "config",
        json!({"t": "config", "config": {"providers": providers()}}),
    );
    mc.answer(
        &engine,
        "hal-c2.readSettings",
        json!({
            "settings": {
                "defaultModelSelection": {"instanceId": "codex", "model": "gpt-5"},
                "defaultRuntimeMode": "full-access",
            },
            "version": 1,
        }),
    );
    let draft = open_draft(&engine);
    // This device's defaults, until the draft is routed to Studio.
    assert_eq!(composer(&engine)["selectedModel"], json!("gpt-5"));
    workspace::set_checkout(
        &engine,
        &draft,
        Checkout {
            environment_id: "env-b".into(),
            project_id: "p1".into(),
            manual: true,
            ..Checkout::default()
        },
    );
    let state = composer(&engine);
    assert_eq!(state["selectedModel"], json!("claude-opus"), "{state}");
    assert_eq!(state["runtimeMode"], json!("approval-required"), "{state}");
    store::flush(&engine);
}
