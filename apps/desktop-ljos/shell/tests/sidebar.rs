//! The shell over an MC that streams its `shell` shape: the controllers wait
//! for the first snapshot, a later start previews what the cache kept, and
//! `Shell.state.sidebar` lists the MC's projects and threads.

mod common;

use std::cell::{Cell, RefCell};
use std::path::Path;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Mc, McError, OnFrame, OnReady, Reply, Resume, SubId};
use hal_c2_shell::{Launch, store};
use ljos::App;
use ljos::prelude::Engine;
use serde_json::json;

const ORIGIN: &str = "http://127.0.0.1:3773";
const AT: &str = "2026-09-23T09:00:00Z";

/// A call the shell made, until the test answers it.
struct Call {
    environment: String,
    method: String,
    payload: Json,
    reply: Option<Reply>,
}

/// An MC whose `shell` subscription the test feeds, and whose calls it
/// answers.
#[derive(Default)]
struct StreamingMc {
    subscription: RefCell<Option<(OnFrame, Option<Resume>)>>,
    next: Cell<u64>,
    calls: RefCell<Vec<Call>>,
}

impl StreamingMc {
    /// What the store resumes from, as a connection sends it on subscribing.
    fn have(&self) -> Json {
        let mut slot = self.subscription.borrow_mut();
        let resume = slot
            .as_mut()
            .and_then(|(_, r)| r.as_mut())
            .expect("a resume");
        resume()["have"].clone()
    }

    fn send(&self, engine: &Engine, frame: Json) {
        let (mut on_frame, resume) = self.subscription.borrow_mut().take().expect("subscribed");
        on_frame(engine, frame.as_object().expect("an object"));
        *self.subscription.borrow_mut() = Some((on_frame, resume));
    }
}

impl Mc for StreamingMc {
    fn is_ready(&self) -> bool {
        true
    }

    fn environment(&self) -> String {
        "env-a".into()
    }

    fn call(&self, environment: &str, method: &str, payload: Json, reply: Reply) {
        self.calls.borrow_mut().push(Call {
            environment: environment.into(),
            method: method.into(),
            payload,
            reply: Some(reply),
        });
    }

    fn subscribe(&self, shape: Json, on_frame: OnFrame, resume: Option<Resume>) -> SubId {
        if shape["type"] == "shell" {
            *self.subscription.borrow_mut() = Some((on_frame, resume));
        }
        self.next.set(self.next.get() + 1);
        SubId(self.next.get())
    }

    fn unsubscribe(&self, _: SubId) {}

    fn more(&self, _: SubId, _: u32) {}

    fn on_ready_changed(&self, _: OnReady) {}
}

fn start(cache: &Path) -> (Engine, Rc<StreamingMc>) {
    let source = common::compile(&[("Main", "import QtQuick\nItem {}\n")], &[]);
    let engine = App::new("test")
        .register(hal_c2_shell::register)
        .source(source)
        .build_engine();
    let mc = Rc::new(StreamingMc::default());
    let launch = Launch {
        mc_origin: Some(ORIGIN.into()),
        cache_dir: Some(cache.to_owned()),
        ..Launch::default()
    };
    hal_c2_shell::start(&engine, &launch, mc.clone());
    (engine, mc)
}

fn snapshot(threads: &[&str]) -> Json {
    let mut rows = vec![json!(["mc-a", "p1", "project",
        {"id": "p1", "title": "Ljos", "workspaceRoot": "/w/ljos", "createdAt": AT, "updatedAt": AT}])];
    for id in threads {
        rows.push(json!(["mc-a", id, "thread",
            {"id": id, "projectId": "p1", "title": format!("Thread {id}"), "createdAt": AT, "updatedAt": AT}]));
    }
    json!({
        "t": "shell",
        "mcs": [{"mc": "mc-a", "environment": {"environmentId": "env-a", "capabilities": {}},
                 "online": true, "epoch": "e1", "rev": 1}],
        "rows": rows,
    })
}

fn sidebar(engine: &Engine) -> Json {
    Bridge::of(engine)
        .published(engine, "sidebar")
        .unwrap_or(Json::Null)
}

/// The titles of the rows the sidebar lists, in order.
fn titles(engine: &Engine) -> Vec<String> {
    let state = sidebar(engine);
    ["pinned", "active", "snoozed", "settled"]
        .iter()
        .flat_map(|section| state[section].as_array().cloned().unwrap_or_default())
        .map(|row| row["title"].as_str().unwrap_or("").to_owned())
        .collect()
}

#[test]
fn the_controllers_wait_for_the_first_snapshot() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, mc) = start(dir.path());
    assert!(!hal_c2_shell::active(&engine));
    assert_eq!(sidebar(&engine), Json::Null);

    mc.send(&engine, snapshot(&["t1", "t2"]));
    assert!(hal_c2_shell::active(&engine));
    let mut shown = titles(&engine);
    shown.sort();
    assert_eq!(shown, ["Thread t1", "Thread t2"]);
    assert_eq!(sidebar(&engine)["projects"][0]["displayName"], "Ljos");
    assert_eq!(sidebar(&engine)["localEnvironmentId"], "env-a");

    // A row the MC adds is listed; the route marks the open one.
    mc.send(
        &engine,
        json!({"t": "shell.rows", "mc": "mc-a", "epoch": "e1", "rev": 2, "rows": [["t3", "thread",
            {"id": "t3", "projectId": "p1", "title": "Thread t3", "createdAt": AT, "updatedAt": AT}]]}),
    );
    assert!(titles(&engine).contains(&"Thread t3".to_owned()));
    Bridge::of(&engine).dispatch(&engine, "thread.open", json!({"key": "env-a:t3"}));
    assert_eq!(sidebar(&engine)["activeThreadKey"], "env-a:t3");
}

#[test]
fn a_later_start_previews_what_the_cache_kept() {
    let dir = tempfile::tempdir().unwrap();
    {
        let (engine, mc) = start(dir.path());
        mc.send(&engine, snapshot(&["t1"]));
        store::flush(&engine);
    }
    let (engine, mc) = start(dir.path());
    // Kept rows show, nothing is decided on them.
    assert!(!hal_c2_shell::active(&engine));
    assert_eq!(titles(&engine), ["Thread t1"]);
    // The MC is asked only for what changed since.
    assert_eq!(mc.have(), json!({"mc-a": ["e1", 1]}));

    mc.send(&engine, snapshot(&["t1", "t2"]));
    assert!(hal_c2_shell::active(&engine));
    assert_eq!(titles(&engine).len(), 2);
}

#[test]
fn usage_prices_for_every_environment_the_cluster_serves() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, mc) = start(dir.path());
    let mut frame = snapshot(&[]);
    frame["mcs"]
        .as_array_mut()
        .unwrap()
        .push(json!({"mc": "mc-b",
        "environment": {"environmentId": "env-b", "label": "Studio", "capabilities": {}},
        "online": true, "epoch": "e1", "rev": 1}));
    mc.send(&engine, frame);
    Bridge::of(&engine).dispatch(&engine, "usagePrices.open", json!({}));
    let targets = Bridge::of(&engine)
        .published(&engine, "usagePrices")
        .unwrap()["targets"]
        .clone();
    let labels: Vec<&str> = targets
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["label"].as_str().unwrap())
        .collect();
    assert_eq!(labels, ["This machine", "Studio"]);
}

// -- The sidebar's actions, the thread menu and the drafts ----------------

const CAPABILITIES: &str = r#"{"threadPinning": true, "threadSettlement": true, "threadSnooze": true,
    "threadVisitedTracking": true, "threadTitleRegeneration": true}"#;

impl StreamingMc {
    /// The unanswered calls of `method`: their index and payload.
    fn waiting(&self, method: &str) -> Vec<(usize, Json)> {
        self.calls
            .borrow()
            .iter()
            .enumerate()
            .filter(|(_, c)| c.method == method && c.reply.is_some())
            .map(|(i, c)| (i, c.payload.clone()))
            .collect()
    }

    /// The types of the commands sent and not answered, with their thread.
    fn commands(&self) -> Vec<(String, String)> {
        self.waiting("orchestration.dispatchCommand")
            .into_iter()
            .map(|(_, c)| {
                (
                    c["type"].as_str().unwrap_or("").to_owned(),
                    c["threadId"].as_str().unwrap_or("").to_owned(),
                )
            })
            .collect()
    }

    fn answer(&self, engine: &Engine, index: usize, result: Result<Json, &str>) {
        let reply = self.calls.borrow_mut()[index]
            .reply
            .take()
            .expect("unanswered");
        reply(engine, result.map_err(McError::new));
    }

    /// Answers every waiting command with `result`.
    fn answer_commands(&self, engine: &Engine, result: Result<Json, &str>) {
        for (index, _) in self.waiting("orchestration.dispatchCommand") {
            self.answer(engine, index, result.clone());
        }
    }
}

/// The cluster: env-a with threads `threads` of project p1, and env-b
/// ("Studio") when `two` says.
fn cluster(threads: &[&str], two: bool) -> Json {
    let mut frame = snapshot(threads);
    let capabilities: Json = serde_json::from_str(CAPABILITIES).unwrap();
    frame["mcs"][0]["environment"]["capabilities"] = capabilities.clone();
    if two {
        frame["mcs"].as_array_mut().unwrap().push(json!({"mc": "mc-b",
            "environment": {"environmentId": "env-b", "label": "Studio", "capabilities": capabilities},
            "online": true, "epoch": "e1", "rev": 1}));
    }
    frame
}

fn started(dir: &Path, threads: &[&str], two: bool) -> (Engine, Rc<StreamingMc>) {
    let (engine, mc) = start(dir);
    engine.set_wall_clock_origin(Some(1_790_000_000_000.0));
    mc.send(&engine, cluster(threads, two));
    (engine, mc)
}

fn dispatch(engine: &Engine, action: &str, payload: Json) {
    Bridge::of(engine).dispatch(engine, action, payload);
}

fn selected(engine: &Engine) -> Vec<String> {
    serde_json::from_value(sidebar(engine)["selectedKeys"].clone()).unwrap()
}

fn route(engine: &Engine) -> Json {
    Bridge::of(engine)
        .published(engine, "route")
        .unwrap_or(Json::Null)
}

/// The open menu's items, by label.
fn menu(engine: &Engine) -> Vec<String> {
    let menu = Bridge::of(engine)
        .published(engine, "menu")
        .unwrap_or(Json::Null);
    menu["items"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|i| i["label"].as_str().unwrap_or("").to_owned())
        .collect()
}

fn choose(engine: &Engine, id: &str) {
    let menu = Bridge::of(engine)
        .published(engine, "menu")
        .expect("a menu");
    dispatch(
        engine,
        "menu.select",
        json!({"requestId": menu["requestId"], "id": id}),
    );
}

fn answer_confirmation(engine: &Engine, accepted: bool) {
    let question = Bridge::of(engine)
        .published(engine, "confirmation")
        .expect("a question");
    dispatch(
        engine,
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": accepted}),
    );
}

fn toast_titles(engine: &Engine) -> Vec<String> {
    let toasts = Bridge::of(engine)
        .published(engine, "toasts")
        .unwrap_or(Json::Null);
    toasts["items"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|t| t["title"].as_str().unwrap_or("").to_owned())
        .collect()
}

#[test]
fn rows_are_selected_one_by_one_and_by_range() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, _mc) = started(dir.path(), &["t1", "t2", "t3"], false);
    let order: Vec<String> = serde_json::from_value(
        sidebar(&engine)["active"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["key"].clone())
            .collect(),
    )
    .unwrap();
    assert_eq!(order.len(), 3);

    dispatch(&engine, "thread.select.toggle", json!({"key": order[0]}));
    dispatch(&engine, "thread.select.range", json!({"key": order[2]}));
    assert_eq!(selected(&engine), order);
    // Toggling a selected row takes it out.
    dispatch(&engine, "thread.select.toggle", json!({"key": order[1]}));
    assert_eq!(selected(&engine), [order[0].clone(), order[2].clone()]);
    // Opening a thread ends the selection; so does scoping the list.
    dispatch(&engine, "thread.open", json!({"key": order[1]}));
    assert!(selected(&engine).is_empty());
    assert_eq!(sidebar(&engine)["activeThreadKey"], json!(order[1]));
    dispatch(&engine, "thread.select.toggle", json!({"key": order[0]}));
    dispatch(&engine, "sidebar.scope", json!({"projectKey": null}));
    assert!(selected(&engine).is_empty());
}

#[test]
fn settling_the_shown_thread_moves_on_once_the_mc_answers_and_undo_unsettles() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, mc) = started(dir.path(), &["t1", "t2"], false);
    dispatch(&engine, "thread.open", json!({"key": "env-a:t1"}));

    dispatch(&engine, "thread.settle", json!({"key": "env-a:t1"}));
    // A second settle while the first is out sends nothing.
    dispatch(&engine, "thread.settle", json!({"key": "env-a:t1"}));
    assert_eq!(
        mc.commands(),
        [("thread.settle".to_owned(), "t1".to_owned())]
    );
    assert_eq!(route(&engine)["threadKey"], "env-a:t1");

    mc.answer_commands(&engine, Ok(json!({})));
    assert_eq!(route(&engine)["threadKey"], "env-a:t2");
    assert_eq!(toast_titles(&engine), ["Settled"]);

    hal_c2_shell::controller::with::<hal_c2_shell::controllers::toasts::Toasts, _>(
        &engine,
        |t, e| t.run_action(e, "Undo"),
    );
    assert_eq!(
        mc.commands(),
        [("thread.unsettle".to_owned(), "t1".to_owned())]
    );
}

#[test]
fn a_failed_settle_says_so_and_stays() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, mc) = started(dir.path(), &["t1", "t2"], false);
    dispatch(&engine, "thread.open", json!({"key": "env-a:t1"}));
    dispatch(&engine, "thread.settle", json!({"key": "env-a:t1"}));
    mc.answer_commands(&engine, Err("busy"));
    assert_eq!(route(&engine)["threadKey"], "env-a:t1");
    assert_eq!(toast_titles(&engine), ["Failed to settle thread"]);
    // No longer pending: settling again is sent.
    dispatch(&engine, "thread.settle", json!({"key": "env-a:t1"}));
    assert_eq!(mc.commands().len(), 1);
}

#[test]
fn the_thread_menu_offers_what_the_environment_can_do() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, _mc) = started(dir.path(), &["t1"], false);
    dispatch(
        &engine,
        "thread.menu",
        json!({"key": "env-a:t1", "x": 1, "y": 2}),
    );
    let labels = menu(&engine);
    for label in [
        "Pin thread",
        "Settle thread",
        "Snooze",
        "Rename thread",
        "Regenerate title",
        "Mark unread",
        "Filter by Ljos",
        "Copy",
        "Project settings",
        "Fork thread",
        "Archive thread",
        "Delete",
    ] {
        assert!(labels.contains(&label.to_owned()), "{label} in {labels:?}");
    }
    // One machine: nowhere to move to.
    assert!(!labels.iter().any(|l| l.starts_with("Move to another")));

    // A capability the environment lacks leaves its item out.
    let dir = tempfile::tempdir().unwrap();
    let (engine, mc) = start(dir.path());
    mc.send(&engine, snapshot(&["t1"]));
    dispatch(
        &engine,
        "thread.menu",
        json!({"key": "env-a:t1", "x": 1, "y": 2}),
    );
    let labels = menu(&engine);
    assert!(!labels.contains(&"Pin thread".to_owned()));
    assert!(labels.contains(&"Rename thread".to_owned()));
}

#[test]
fn copying_from_the_thread_menu_says_whether_it_was_copied() {
    use hal_c2_shell::controllers::thread_menu::ThreadMenu;
    let dir = tempfile::tempdir().unwrap();
    let (engine, _mc) = started(dir.path(), &["t1"], false);
    let copied = Rc::new(RefCell::new(Vec::<String>::new()));
    let works = Rc::new(Cell::new(true));
    let (c, w) = (copied.clone(), works.clone());
    hal_c2_shell::controller::with::<ThreadMenu, _>(&engine, |m, _| {
        m.set_clipboard_writer(Rc::new(move |_, text| {
            c.borrow_mut().push(text.to_owned());
            w.get()
        }));
    });
    dispatch(
        &engine,
        "thread.menu",
        json!({"key": "env-a:t1", "x": 0, "y": 0}),
    );
    choose(&engine, "copy-thread-id");
    assert_eq!(*copied.borrow(), ["t1"]);
    assert_eq!(toast_titles(&engine), ["Thread ID copied"]);

    works.set(false);
    dispatch(
        &engine,
        "thread.menu",
        json!({"key": "env-a:t1", "x": 0, "y": 0}),
    );
    choose(&engine, "copy-path");
    assert_eq!(copied.borrow().last().unwrap(), "/w/ljos");
    assert!(toast_titles(&engine).contains(&"Failed to copy path".to_owned()));
}

#[test]
fn the_selection_menu_acts_on_every_selected_thread() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, mc) = started(dir.path(), &["t1", "t2", "t3"], false);
    dispatch(&engine, "thread.select.toggle", json!({"key": "env-a:t1"}));
    dispatch(&engine, "thread.select.toggle", json!({"key": "env-a:t2"}));
    dispatch(
        &engine,
        "thread.menu",
        json!({"key": "env-a:t1", "x": 0, "y": 0}),
    );
    let labels = menu(&engine);
    assert!(labels.contains(&"Settle (2)".to_owned()), "{labels:?}");
    assert!(labels.contains(&"Delete (2)".to_owned()));
    assert!(
        !labels.iter().any(|l| l.starts_with("Unpin")),
        "nothing is pinned"
    );

    // Deleting asks first; what could not be deleted stays selected.
    choose(&engine, "delete");
    assert!(mc.commands().is_empty());
    answer_confirmation(&engine, true);
    let mut sent = mc.commands();
    sent.sort();
    assert_eq!(
        sent,
        [
            ("thread.delete".to_owned(), "t1".to_owned()),
            ("thread.delete".to_owned(), "t2".to_owned())
        ]
    );
    let waiting = mc.waiting("orchestration.dispatchCommand");
    for (index, payload) in waiting {
        let result = if payload["threadId"] == "t2" {
            Err("locked")
        } else {
            Ok(json!({}))
        };
        mc.answer(&engine, index, result);
    }
    assert_eq!(selected(&engine), ["env-a:t2"]);
    assert_eq!(toast_titles(&engine), ["Failed to delete threads"]);
}

#[test]
fn a_thread_moves_to_the_machine_chosen() {
    let dir = tempfile::tempdir().unwrap();
    let (engine, mc) = started(dir.path(), &["t1"], true);
    dispatch(
        &engine,
        "thread.menu",
        json!({"key": "env-a:t1", "x": 0, "y": 0}),
    );
    assert!(menu(&engine).contains(&"Move to another machine…".to_owned()));
    choose(&engine, "move");
    let (index, asked) = mc.waiting("hal-c2.moveDestinations").remove(0);
    assert_eq!(asked, json!({"threadId": "t1"}));
    mc.answer(
        &engine,
        index,
        Ok(json!([{"environmentId": "env-b", "machine": "Studio", "online": true}])),
    );
    assert_eq!(menu(&engine), ["Studio"]);
    choose(&engine, "machine:env-b");
    let (index, input) = mc.waiting("hal-c2.moveThread").remove(0);
    assert_eq!(input, json!({"threadId": "t1", "machine": "env-b"}));
    // The thread's own MC is asked to move it.
    assert_eq!(mc.calls.borrow()[index].environment, "env-a");

    // The MC asks to confirm what stays behind; the move is sent again.
    mc.answer(
        &engine,
        index,
        Ok(json!({"status": "confirm", "notes": [{"message": "The terminal stays"}]})),
    );
    answer_confirmation(&engine, true);
    let (index, input) = mc.waiting("hal-c2.moveThread").remove(0);
    assert_eq!(input["confirmed"], true);
    mc.answer(
        &engine,
        index,
        Ok(json!({"status": "moved", "environmentId": "env-b"})),
    );
    assert_eq!(route(&engine)["threadKey"], "env-b:t1");
    assert!(toast_titles(&engine).contains(&"Moved to Studio".to_owned()));
}

#[test]
fn pin_and_settle_keys_act_on_the_shown_thread() {
    use hal_c2_shell::commands::Commands;
    let dir = tempfile::tempdir().unwrap();
    let (engine, mc) = started(dir.path(), &["t1"], false);
    dispatch(&engine, "thread.open", json!({"key": "env-a:t1"}));
    assert!(Commands::of(&engine).run(&engine, "thread.pin"));
    assert_eq!(mc.commands(), [("thread.pin".to_owned(), "t1".to_owned())]);
    mc.answer_commands(&engine, Ok(json!({})));
    assert!(Commands::of(&engine).run(&engine, "thread.settle"));
    assert_eq!(
        mc.commands(),
        [("thread.settle".to_owned(), "t1".to_owned())]
    );
}

#[test]
fn a_new_thread_is_a_draft_until_its_thread_arrives() {
    use hal_c2_shell::controllers::drafts;
    use hal_c2_shell::controllers::navigation::{Navigation, Route};
    let dir = tempfile::tempdir().unwrap();
    let (engine, mc) = started(dir.path(), &["t1"], false);
    // A window with no thread lands on its project's draft.
    assert_eq!(route(&engine)["kind"], "draft");
    let id = route(&engine)["draftId"].as_str().unwrap().to_owned();
    // Listed once it holds something; the open draft's row keeps the label
    // it opened with, so typing does not move it.
    assert!(sidebar(&engine)["drafts"].as_array().unwrap().is_empty());
    drafts::set_text(&engine, &id, "Port the sidebar\nwith tests");
    assert!(sidebar(&engine)["drafts"].as_array().unwrap().is_empty());
    dispatch(&engine, "thread.open", json!({"key": "env-a:t1"}));
    assert_eq!(sidebar(&engine)["drafts"][0]["label"], "Port the sidebar");
    hal_c2_shell::controller::with::<Navigation, _>(&engine, |n, e| {
        n.open(e, Route::Draft(id.clone()));
    });

    // Its first send creates its thread; the window follows it there.
    let thread = drafts::draft(&engine, &id).unwrap().thread_id;
    mc.send(
        &engine,
        json!({"t": "shell.rows", "mc": "mc-a", "epoch": "e1", "rev": 2, "rows": [[thread, "thread",
            {"id": thread, "projectId": "p1", "title": "Port", "createdAt": AT, "updatedAt": AT}]]}),
    );
    assert_eq!(
        route(&engine)["threadKey"],
        json!(format!("env-a:{thread}"))
    );
    assert!(drafts::draft(&engine, &id).is_none());
}

#[test]
fn migrated_threads_are_announced_once() {
    let migrated = |title: &str| {
        let mut frame = cluster(&["t1"], false);
        let row = &mut frame["rows"][1][3];
        row["historyOrigin"] = json!("v1_import");
        row["title"] = json!(title);
        frame
    };
    let count = |engine: &Engine, title: &str| {
        toast_titles(engine)
            .iter()
            .filter(|t| t.as_str() == title)
            .count()
    };

    // With nowhere to keep the note, the device is told once, not at
    // every change of the store.
    let dir = tempfile::tempdir().unwrap();
    let (engine, mc) = start(dir.path());
    for title in ["One", "Two", "Three"] {
        mc.send(&engine, migrated(title));
    }
    assert_eq!(count(&engine, "Setting not saved"), 1);
    assert_eq!(count(&engine, "Your threads were brought over"), 0);

    // Kept, the threads are announced once.
    let dir = tempfile::tempdir().unwrap();
    let source = common::compile(&[("Main", "import QtQuick\nItem {}\n")], &[]);
    let engine = App::new("test")
        .register(hal_c2_shell::register)
        .source(source)
        .build_engine();
    let mc = Rc::new(StreamingMc::default());
    let launch = Launch {
        mc_origin: Some(ORIGIN.into()),
        cache_dir: Some(dir.path().join("cache")),
        config_dir: Some(dir.path().join("config")),
        ..Launch::default()
    };
    hal_c2_shell::start(&engine, &launch, mc.clone());
    for title in ["One", "Two", "Three"] {
        mc.send(&engine, migrated(title));
    }
    assert_eq!(count(&engine, "Your threads were brought over"), 1);
    assert_eq!(count(&engine, "Setting not saved"), 0);
}
