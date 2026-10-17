//! `worktreeSetup`, desktop-qt's WorktreeSetupController: how the open
//! thread's new worktree is being prepared. The MC's `worktreeSetup` shape
//! for the thread (a WorktreeSetupSnapshot of packages/contracts, or null
//! when none is tracked) is followed while the window shows the thread.
//!
//! Publishes `worktreeSetup`: null without a setup, else {threadKey, phase
//! (running | done | failed | cancelled), label ("Setting up worktree…",
//! "Worktree ready", ...), error, branch, baseRef, worktreePath, script (the
//! setup script's name), canCancel, detailsOpen, stages: [{id, label,
//! status, detail, tail}]}.
//!
//! Actions: `worktreeSetup.details {open}` shows or hides the steps and why
//! the setup failed; `worktreeSetup.cancel` stops a running setup
//! (`worktreeSetup.cancel`), told when it cannot.

use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::{Map, json};

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{self, Route};
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::mc::{Mc, SubId};
use crate::store;

pub struct WorktreeSetup {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<WorktreeSetup>,
    active: bool,
    /// The thread followed ("<environment>:<thread id>"), empty for none.
    thread: String,
    /// The cluster MC serving its environment.
    serving: String,
    subscription: Option<SubId>,
    snapshot: Map<String, Json>,
    details_open: bool,
    published: Option<Json>,
}

impl Drop for WorktreeSetup {
    fn drop(&mut self) {
        if let Some(id) = self.subscription.take() {
            self.mc.unsubscribe(id);
        }
    }
}

impl Controller for WorktreeSetup {
    fn new(init: Init<'_, Self>) -> Self {
        WorktreeSetup {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            active: false,
            thread: String::new(),
            serving: String::new(),
            subscription: None,
            snapshot: Map::new(),
            details_open: false,
            published: None,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let later = |me: &Me<WorktreeSetup>| {
            let me = me.clone();
            move |engine: &Engine| {
                let me = me.clone();
                Bridge::of(engine).defer(engine, move |engine| me.run(engine, Self::follow));
            }
        };
        let route = later(&self.me);
        self.bridge
            .watch(engine, "route", move |engine, _| route(engine));
        // The MC serving the thread's environment may arrive after the route.
        store::on_changed(engine, later(&self.me));
        self.follow(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("worktreeSetup.") {
            return false;
        }
        match action {
            "worktreeSetup.details" => {
                self.details_open = payload["open"].as_bool().unwrap_or(false);
                self.publish(engine);
            }
            "worktreeSetup.cancel" if !self.thread.is_empty() => {
                let (environment_id, thread_id) = split_key(&self.thread);
                self.mc.call(
                    environment_id,
                    "worktreeSetup.cancel",
                    json!({ "threadId": thread_id }),
                    Box::new(|engine, result| {
                        let why = match result {
                            Ok(result) if result["cancelled"].as_bool() == Some(true) => return,
                            Ok(_) => "The agent has already started.".to_owned(),
                            Err(error) => error.message,
                        };
                        controller::with::<Toasts, _>(engine, |t, engine| {
                            t.error(engine, "Could not cancel the worktree setup", &why)
                        });
                    }),
                );
            }
            _ => {}
        }
        true
    }
}

/// `<environment>:<thread id>` as its two halves.
fn split_key(thread_key: &str) -> (&str, &str) {
    thread_key.split_once(':').unwrap_or(("", thread_key))
}

fn stage_label(id: &str) -> &'static str {
    match id {
        "fetch" => "Fetch base branch",
        "checkout" => "Check out files",
        "submodules" => "Init submodules",
        "setup-script" => "Run setup script",
        _ => "Start agent",
    }
}

/// QVariant::toString of a tail line.
fn line(value: &Json) -> String {
    match value {
        Json::String(s) => s.clone(),
        Json::Number(n) => n.to_string(),
        Json::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

/// What `worktreeSetup` publishes for a snapshot (null for none).
pub fn state(thread_key: &str, snapshot: &Map<String, Json>, details_open: bool) -> Json {
    if snapshot.is_empty() {
        return Json::Null;
    }
    let text = |value: &Json| value.as_str().unwrap_or_default().to_owned();
    // A Map panics on a missing key; a Value reads null.
    let field = |key: &str| snapshot.get(key).unwrap_or(&Json::Null);
    let phase = text(field("phase"));
    let mut script_failed = false;
    let stages: Vec<Json> = snapshot
        .get("stages")
        .and_then(Json::as_array)
        .into_iter()
        .flatten()
        .map(|stage| {
            let id = text(&stage["id"]);
            let status = text(&stage["status"]);
            script_failed = script_failed || status == "failed";
            let tail: Vec<String> = stage["tail"]
                .as_array()
                .map(|lines| lines.iter().map(line).collect())
                .unwrap_or_default();
            json!({
                "id": id,
                "label": stage_label(&id),
                "status": status,
                "detail": text(&stage["detail"]),
                "tail": tail,
            })
        })
        .collect();
    // The headline of the setup.
    let label = match phase.as_str() {
        "running" => "Setting up worktree…",
        "failed" => "Worktree setup failed",
        "cancelled" => "Worktree setup cancelled",
        _ if script_failed => "Worktree ready, setup script failed",
        _ => "Worktree ready",
    };
    json!({
        "threadKey": thread_key,
        "phase": phase,
        "label": label,
        "error": text(field("error")),
        "branch": text(field("branch")),
        "baseRef": text(field("baseRef")),
        "worktreePath": text(field("worktreePath")),
        "script": text(&field("setupScript")["name"]),
        "canCancel": phase == "running",
        "detailsOpen": details_open,
        "stages": stages,
    })
}

impl WorktreeSetup {
    /// Follows the route's thread on the MC serving its environment.
    fn follow(&mut self, engine: &Engine) {
        let thread = match navigation::shown(engine) {
            Route::Thread(key) => key,
            _ => String::new(),
        };
        let serving = if thread.is_empty() {
            String::new()
        } else {
            store::with(engine, |s| s.mc_serving(split_key(&thread).0))
        };
        if thread == self.thread && serving == self.serving {
            return;
        }
        if let Some(id) = self.subscription.take() {
            self.mc.unsubscribe(id);
        }
        self.thread = thread.clone();
        self.serving = serving.clone();
        self.snapshot = Map::new();
        self.details_open = false;
        if !thread.is_empty() && !serving.is_empty() {
            let me = self.me.clone();
            self.subscription = Some(self.mc.subscribe(
                json!({ "type": "worktreeSetup", "mc": serving, "threadId": split_key(&thread).1 }),
                Box::new(move |engine, frame| {
                    if frame.get("t").and_then(Json::as_str) != Some("worktreeSetup") {
                        return;
                    }
                    let snapshot = frame
                        .get("event")
                        .and_then(Json::as_object)
                        .cloned()
                        .unwrap_or_default();
                    let thread = thread.clone();
                    me.run(engine, move |c, engine| {
                        if thread != c.thread {
                            return;
                        }
                        c.snapshot = snapshot;
                        c.publish(engine);
                    });
                }),
                None,
            ));
        }
        self.publish(engine);
    }

    fn publish(&mut self, engine: &Engine) {
        let state = state(&self.thread, &self.snapshot, self.details_open);
        if self.published.as_ref() == Some(&state) {
            return;
        }
        self.published = Some(state.clone());
        self.bridge.publish(engine, "worktreeSetup", state);
    }
}
