//! The shell over an MC that streams its `shell` shape: the controllers wait
//! for the first snapshot, a later start previews what the cache kept, and
//! `Shell.state.sidebar` lists the MC's projects and threads.

mod common;

use std::cell::{Cell, RefCell};
use std::path::Path;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Mc, OnFrame, OnReady, Reply, Resume, SubId};
use hal_c2_shell::{Launch, store};
use ljos::App;
use ljos::prelude::Engine;
use serde_json::json;

const ORIGIN: &str = "http://127.0.0.1:3773";
const AT: &str = "2026-09-23T09:00:00Z";

/// An MC whose `shell` subscription the test feeds.
#[derive(Default)]
struct StreamingMc {
    subscription: RefCell<Option<(OnFrame, Option<Resume>)>>,
    next: Cell<u64>,
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

    fn call(&self, _: &str, _: &str, _: Json, _: Reply) {}

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
