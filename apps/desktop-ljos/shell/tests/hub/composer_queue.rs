//! A queue the MC holds (after a restart or a usage limit) and its resume
//! (ComposerController::resumeQueue, features/composer/queue-and-steer.feature
//! "A held queue ...", tst_ComposerRegression.cpp, TurnSteps.cpp).

use std::collections::BTreeMap;

use hal_c2_shell::controller;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::SubId;
use serde_json::json;

use crate::Hub;
use crate::composer::{DISPATCH, commands, on_threads};
use crate::page::{failure, toasts};

pub const FAILURE: &str = "Failed to resume the queue.";
pub const NOT_CONNECTED: &str = "Not connected: queue not resumed";

/// What the MC keeps of each thread's stream: its messages and runs, sent
/// whole to a subscription it answers, then as they change.
#[derive(Default)]
pub struct Streams {
    entities: BTreeMap<String, Vec<(String, String, Json)>>,
    seq: i64,
    /// The stream subscriptions answered, and the thread of each.
    answered: Vec<(SubId, String)>,
    /// While set, stream subscriptions wait unanswered (a reconnect the MC
    /// has not caught up yet).
    pub holding: bool,
    next: u32,
}

impl Streams {
    /// Answers the stream subscriptions not answered yet, unless holding.
    pub fn answer(&mut self, hub: &Hub) {
        if self.holding {
            return;
        }
        // Gone subscriptions are forgotten: a new one is answered whole.
        let live: Vec<(SubId, String)> = hub
            .mc
            .subscriptions()
            .into_iter()
            .filter(|(_, shape)| shape["type"] == "stream")
            .map(|(id, shape)| (id, shape["stream"].as_str().unwrap_or_default().to_owned()))
            .collect();
        self.answered
            .retain(|(id, _)| live.iter().any(|(l, _)| l == id));
        for (id, thread) in live {
            if self.answered.iter().any(|(a, _)| *a == id) {
                continue;
            }
            let rows: Vec<Json> = self
                .entities
                .get(&thread)
                .into_iter()
                .flatten()
                .map(|(kind, id, fields)| json!([kind, id, fields]))
                .collect();
            hub.mc.frame_to(
                &hub.engine,
                id,
                json!({"t": "snapshot", "part": 0, "done": true, "offset": self.seq,
                    "handle": "log-1", "floor": null, "rows": rows}),
            );
            hub.mc.frame_to(
                &hub.engine,
                id,
                json!({"t": "live", "offset": self.seq, "handle": "log-1"}),
            );
            self.answered.push((id, thread));
        }
    }

    /// Forgets what was answered: the connection dropped.
    pub fn dropped(&mut self) {
        self.answered.clear();
    }

    /// Sets `fields` of entity `kind`/`id` on `thread`'s stream.
    pub fn set(&mut self, hub: &Hub, thread: &str, kind: &str, id: &str, fields: Json) {
        let list = self.entities.entry(thread.to_owned()).or_default();
        match list.iter_mut().find(|(k, i, _)| k == kind && i == id) {
            Some((_, _, whole)) => {
                if let (Some(whole), Json::Object(fields)) = (whole.as_object_mut(), &fields) {
                    whole.extend(fields.clone());
                }
            }
            None => list.push((kind.into(), id.into(), fields.clone())),
        }
        self.seq += 1;
        let seq = self.seq;
        for (sub, _) in self.answered.iter().filter(|(_, t)| t == thread) {
            hub.mc.frame_to(
                &hub.engine,
                *sub,
                json!({"t": "events", "offset": seq,
                    "events": [[seq, kind, id, {"s": fields}, "2026-09-23T10:00:00Z"]]}),
            );
        }
    }

    /// A user message queued on `thread`, its run held or not; the message
    /// comes after the run when `late` (returned, for [`Streams::land`]).
    pub fn enqueue(&mut self, hub: &Hub, thread: &str, held: bool, late: bool) -> Json {
        self.next += 1;
        let n = self.next;
        let message = json!({"id": format!("message-{n}"), "role": "user", "createdBy": "user",
            "createdAt": "2026-09-23T10:00:00.000Z", "text": format!("queued {n}")});
        let run = json!({"id": format!("run-{n}"), "ordinal": n, "queuePosition": n,
            "status": "queued", "userMessageId": format!("message-{n}"), "queueHeld": held});
        if !late {
            self.land(hub, thread, message.clone());
        }
        self.set(hub, thread, "run", &format!("run-{n}"), run);
        message
    }

    /// `message` reaches `thread`'s stream.
    pub fn land(&mut self, hub: &Hub, thread: &str, message: Json) {
        let id = message["id"].as_str().unwrap_or_default().to_owned();
        self.set(hub, thread, "message", &id, message);
    }

    /// The runs of `thread` still queued.
    fn queued(&self, thread: &str) -> Vec<String> {
        self.entities
            .get(thread)
            .into_iter()
            .flatten()
            .filter(|(kind, _, fields)| kind == "run" && fields["status"] == "queued")
            .map(|(_, id, _)| id.clone())
            .collect()
    }

    /// Every queued run of `thread` is held, or none is.
    pub fn hold(&mut self, hub: &Hub, thread: &str, held: bool) {
        for run in self.queued(thread) {
            self.set(hub, thread, "run", &run, json!({"queueHeld": held}));
        }
    }

    /// The first queued run of `thread` leaves the queue as `status`.
    pub fn leave(&mut self, hub: &Hub, thread: &str, status: &str) {
        if let Some(run) = self.queued(thread).first() {
            self.set(hub, thread, "run", run, json!({"status": status}));
        }
    }
}

/// The `queue.resume` commands sent for `thread`.
pub fn resumes(hub: &Hub, thread: &str) -> usize {
    commands(hub)
        .iter()
        .filter(|c| c["type"] == "queue.resume" && c["threadId"] == thread)
        .count()
}

/// The index of the oldest unanswered `queue.resume`.
pub fn pending_resume(hub: &Hub) -> Option<usize> {
    hub.mc
        .pending_where(DISPATCH, |command| command["type"] == "queue.resume")
}

/// The toasts titled `title` in `toasts`.
pub fn count(toasts: &Json, title: &str) -> usize {
    toasts["items"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|t| t["title"] == title)
        .count()
}

/// A hub on t1 whose stream has "later" queued, held.
fn held() -> (Hub, Streams) {
    let hub = on_threads(&["t1"]);
    let mut streams = Streams::default();
    streams.answer(&hub);
    streams.enqueue(&hub, "t1", false, false);
    assert_eq!(hub.published("turn")["queueHeld"], false);
    streams.hold(&hub, "t1", true);
    (hub, streams)
}

fn resume(hub: &Hub) {
    hub.dispatch("composer.queue.resume", json!({}));
}

#[test]
fn a_held_queue_says_its_messages_are_safe() {
    let (hub, _) = held();
    let turn = hub.published("turn");
    assert_eq!(turn["queueHeld"], true);
    assert_eq!(turn["queueResuming"], false);
    assert_eq!(turn["queue"][0]["text"], "queued 1");
}

#[test]
fn a_held_queue_is_resumed_once_at_a_time() {
    let (hub, mut streams) = held();
    resume(&hub);
    assert_eq!(resumes(&hub, "t1"), 1);
    assert_eq!(hub.published("turn")["queueResuming"], true);
    // A second press while the MC has not answered asks nothing.
    resume(&hub);
    assert_eq!(resumes(&hub, "t1"), 1);
    hub.mc
        .reply(&hub.engine, pending_resume(&hub).unwrap(), Ok(json!({})));
    assert_eq!(hub.published("turn")["queueResuming"], false);
    streams.hold(&hub, "t1", false);
    assert_eq!(hub.published("turn")["queueHeld"], false);
    // A stale click, once the queue is no longer held, asks nothing.
    resume(&hub);
    assert_eq!(resumes(&hub, "t1"), 1);
    assert!(toasts(&hub).is_empty());
}

#[test]
fn a_resume_that_the_mc_refuses_is_reported() {
    let (hub, _) = held();
    resume(&hub);
    hub.mc.reply(
        &hub.engine,
        pending_resume(&hub).unwrap(),
        Err(failure("thread is archived")),
    );
    assert_eq!(
        toasts(&hub),
        [(FAILURE.to_owned(), "thread is archived".to_owned())]
    );
    let turn = hub.published("turn");
    assert_eq!(turn["queueResuming"], false);
    assert_eq!(turn["queueHeld"], true);
}

#[test]
fn a_resume_while_reconnecting_is_refused_with_one_warning() {
    let (hub, mut streams) = held();
    hub.mc.set_ready(&hub.engine, false);
    streams.dropped();
    resume(&hub);
    assert_eq!(
        toasts(&hub),
        [(
            NOT_CONNECTED.to_owned(),
            "Reconnecting to the environment. Try again once it is connected.".to_owned()
        )]
    );
    assert_eq!(resumes(&hub, "t1"), 0);
    resume(&hub);
    assert_eq!(count(&hub.published("toasts"), NOT_CONNECTED), 1);

    // Dismissed and shown again: one fresh warning.
    let id = hub.published("toasts")["items"][0]["id"].clone();
    hub.dispatch("notification.dismiss", json!({"id": id}));
    assert!(toasts(&hub).is_empty());
    resume(&hub);
    assert_eq!(count(&hub.published("toasts"), NOT_CONNECTED), 1);
    assert_eq!(resumes(&hub, "t1"), 0);
}

#[test]
fn a_resume_before_the_stream_catches_up_asks_nothing() {
    let (hub, mut streams) = held();
    hub.mc.set_ready(&hub.engine, false);
    streams.dropped();
    streams.holding = true;
    hub.mc.set_ready(&hub.engine, true);
    // The held flag shown may be one the MC has since cleared.
    resume(&hub);
    assert_eq!(resumes(&hub, "t1"), 0);
    assert_eq!(count(&hub.published("toasts"), NOT_CONNECTED), 1);
    streams.holding = false;
    streams.answer(&hub);
    resume(&hub);
    assert_eq!(resumes(&hub, "t1"), 1);
}

#[test]
fn a_held_queue_that_only_waits_on_the_provider_can_be_resumed() {
    let hub = on_threads(&["t1"]);
    let mut streams = Streams::default();
    streams.answer(&hub);
    streams.land(
        &hub,
        "t1",
        json!({"id": "message-wake", "role": "user", "providerWake": true}),
    );
    streams.set(
        &hub,
        "t1",
        "run",
        "run-wake",
        json!({"id": "run-wake", "ordinal": 1, "status": "queued", "queuePosition": 1,
            "userMessageId": "message-wake", "queueHeld": true}),
    );
    let turn = hub.published("turn");
    assert_eq!(turn["queue"], json!([]));
    assert_eq!(turn["waiting"].as_array().map(Vec::len), Some(1));
    assert_eq!(turn["queueHeld"], true);
    resume(&hub);
    assert_eq!(resumes(&hub, "t1"), 1);
}

#[test]
fn a_held_queue_with_nothing_listed_offers_no_resume() {
    let hub = on_threads(&["t1"]);
    let mut streams = Streams::default();
    streams.answer(&hub);
    let message = streams.enqueue(&hub, "t1", true, true);
    assert_eq!(hub.published("turn")["queueHeld"], false);
    resume(&hub);
    assert_eq!(resumes(&hub, "t1"), 0);
    streams.land(&hub, "t1", message);
    assert_eq!(hub.published("turn")["queueHeld"], true);
    resume(&hub);
    assert_eq!(resumes(&hub, "t1"), 1);
}

#[test]
fn a_resume_outlives_the_window_that_asked() {
    let (hub, mut streams) = held();
    controller::set_window_opener(&hub.engine, |_, _| {});
    controller::open_window(&hub.engine, Some("two")).expect("the shell is started");
    let two = controller::window_bridge(&hub.engine, "two").unwrap();
    two.dispatch(&hub.engine, "thread.open", json!({"key": "env-1:t1"}));
    streams.answer(&hub);
    assert_eq!(
        two.published(&hub.engine, "turn").unwrap()["queueHeld"],
        true
    );
    two.dispatch(&hub.engine, "composer.queue.resume", json!({}));
    assert_eq!(resumes(&hub, "t1"), 1);
    // The other window shows the resume outstanding, and asks nothing more.
    let main = controller::window_bridge(&hub.engine, controller::MAIN).unwrap();
    assert_eq!(
        main.published(&hub.engine, "turn").unwrap()["queueResuming"],
        true
    );
    main.dispatch(&hub.engine, "composer.queue.resume", json!({}));
    assert_eq!(resumes(&hub, "t1"), 1);
    controller::close_window(&hub.engine, "two");
    hub.engine.process_deferred_deletes();
    hub.mc.reply(
        &hub.engine,
        pending_resume(&hub).unwrap(),
        Err(failure("thread is archived")),
    );
    // Told in the window left, which no longer shows it outstanding.
    assert_eq!(
        toasts(&hub),
        [(FAILURE.to_owned(), "thread is archived".to_owned())]
    );
    assert_eq!(hub.published("turn")["queueResuming"], false);
}
