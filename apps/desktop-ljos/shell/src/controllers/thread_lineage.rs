//! `threadLineage`, desktop-qt's ThreadLineageController: the open thread's
//! relatives, the thread it was forked from and the forks made of it, from
//! the shell's rows (`lineage`, `forkedFrom`), and forking and merging back.
//!
//! Publishes `lineage`: null for a thread with no relatives, else
//! `{threadKey, title ("Lineage", or "Lineage · 2 running"), runningCount,
//! parent: {key, title, missing, subagent} or null (missing: the row is gone,
//! "This related thread is unavailable"), forks: [{key, title, running}],
//! canMerge, mergeHint}`.
//!
//! Actions: `lineage.open {key}` opens a relative; `lineage.mergeBack`
//! merges the fork's latest finished run back into its parent
//! (`thread.merge_back`) and opens the parent; `thread.forkFromRun {runId}`
//! forks the open thread at a response's run (`thread.fork` with that run as
//! its source) and opens the fork once the shell lists it, saying so when it
//! does not arrive.

use std::rc::Rc;
use std::time::Duration;

use ljos::prelude::{Engine, TimerId};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{self, Navigation, Route};
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::mc::Mc;
use crate::sidebar_model::{self, Thread};
use crate::store::{self, Row, ShellStore};

/// How long a fork's row may take to arrive.
pub const ARRIVAL_TIMEOUT_MS: u64 = 5000;

pub struct ThreadLineage {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<ThreadLineage>,
    active: bool,
    /// The fork waited for, and when it is given up on.
    waiting: Option<(String, TimerId)>,
}

fn later(
    engine: &Engine,
    me: &Me<ThreadLineage>,
    f: impl FnOnce(&mut ThreadLineage, &Engine) + 'static,
) {
    let me = me.clone();
    Bridge::of(engine).defer(engine, move |engine| me.run(engine, f));
}

fn shown_thread(engine: &Engine) -> String {
    match navigation::shown(engine) {
        Route::Thread(key) => key,
        _ => String::new(),
    }
}

fn environment_of(key: &str) -> &str {
    key.split_once(':')
        .map_or(key, |(environment, _)| environment)
}

fn text<'a>(row: &'a Row, object: &str, field: &str) -> &'a str {
    row.get(object)
        .and_then(|o| o.get(field))
        .and_then(Json::as_str)
        .unwrap_or("")
}

/// The thread a fork came from: where it was forked (`forkedFrom`), else its
/// lineage's parent.
fn parent_id(row: &Row) -> String {
    if text(row, "lineage", "relationshipToParent") != "fork" {
        return String::new();
    }
    let forked_from = text(row, "forkedFrom", "threadId");
    if forked_from.is_empty() {
        text(row, "lineage", "parentThreadId").to_owned()
    } else {
        forked_from.to_owned()
    }
}

/// The thread a subagent's thread works for; it is shown, never merged back.
fn subagent_parent_id(row: &Row) -> String {
    if text(row, "lineage", "relationshipToParent") != "subagent" {
        return String::new();
    }
    text(row, "lineage", "parentThreadId").to_owned()
}

fn row_of(store: &ShellStore, key: &str) -> Row {
    store.thread_row(key).cloned().unwrap_or_default()
}

/// Where the relative `id` of a thread on `environment_id` is now. A move
/// keeps a thread's id, so a relative that moved (or was left behind when
/// this one moved) is the thread with that id on another machine.
fn relative_key(store: &ShellStore, environment_id: &str, id: &str) -> String {
    let key = store.located(&format!("{environment_id}:{id}"));
    if store.thread(&key).is_some() {
        return key;
    }
    store
        .threads()
        .into_iter()
        .find(|other| other.id == id)
        .map_or(key, |other| other.key())
}

fn running(thread: &Thread) -> bool {
    sidebar_model::status(thread) == "working"
}

fn finished(thread: &Thread) -> bool {
    thread
        .latest_run
        .as_ref()
        .is_some_and(|run| run.status == "completed")
}

fn open(engine: &Engine, key: String) {
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Navigation, _>(engine, |n, e| n.open(e, Route::Thread(key)));
    });
}

fn error(engine: &Engine, title: &str, description: &str) {
    let (title, description) = (title.to_owned(), description.to_owned());
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Toasts, _>(engine, |t, e| {
            t.error(e, &title, &description);
        });
    });
}

/// What `lineage` shows of the open thread.
fn state(store: &ShellStore, key: &str) -> Json {
    let Some(thread) = (!key.is_empty()).then(|| store.thread(key)).flatten() else {
        return Json::Null;
    };
    let row = row_of(store, key);
    let parent = parent_id(&row);
    let shown_parent = if parent.is_empty() {
        subagent_parent_id(&row)
    } else {
        parent.clone()
    };
    let mut parent_state = Json::Null;
    let mut parent_title = String::new();
    let mut parent_here = true;
    let mut running_count = 0;
    if !shown_parent.is_empty() {
        let parent_key = relative_key(store, &thread.environment_id, &shown_parent);
        let parent_thread = store.thread(&parent_key);
        // Merging back is a command to one machine: both threads have to be
        // on it.
        parent_here = environment_of(&parent_key) == thread.environment_id;
        parent_title = parent_thread
            .as_ref()
            .map(|p| p.title.clone())
            .unwrap_or_default();
        if parent_thread.as_ref().is_some_and(running) {
            running_count += 1;
        }
        parent_state = json!({
            "key": parent_key,
            "title": parent_thread.as_ref().map_or("This related thread is unavailable", |p| p.title.as_str()),
            "missing": parent_thread.is_none(),
            // A subagent's thread says whose it is, and is not merged back.
            "subagent": parent.is_empty(),
        });
    }
    let mut forks = Vec::new();
    for other in store.threads() {
        if other.archived_at.is_some() || parent_id(&row_of(store, &other.key())) != thread.id {
            continue;
        }
        if running(&other) {
            running_count += 1;
        }
        forks.push(json!({"key": other.key(), "title": other.title, "running": running(&other)}));
    }
    if shown_parent.is_empty() && forks.is_empty() {
        return Json::Null;
    }
    let finished = finished(&thread);
    let can_merge = !parent.is_empty() && !parent_title.is_empty() && finished && parent_here;
    let merge_hint = if parent.is_empty() {
        String::new()
    } else if !finished {
        "Complete a run in this fork before merging it back".to_owned()
    } else if !parent_here {
        "Move this fork to the machine its source is on to merge it back".to_owned()
    } else if parent_title.is_empty() {
        "Merge this conversation back into its source".to_owned()
    } else {
        format!("Merge this conversation back into {parent_title}")
    };
    json!({
        "threadKey": key,
        "title": if running_count > 0 {
            format!("Lineage · {running_count} running")
        } else {
            "Lineage".to_owned()
        },
        "runningCount": running_count,
        "parent": parent_state,
        "forks": forks,
        "canMerge": can_merge,
        "mergeHint": merge_hint,
    })
}

impl ThreadLineage {
    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let key = shown_thread(engine);
        let state = store::with(engine, |s| state(s, &key));
        self.bridge.publish(engine, "lineage", state);
    }

    fn merge_back(&mut self, engine: &Engine) {
        let key = shown_thread(engine);
        let found = store::with(engine, |s| {
            let thread = s.thread(&key)?;
            let parent = parent_id(&row_of(s, &key));
            let run = thread.latest_run.as_ref()?;
            if parent.is_empty() || run.status != "completed" {
                return None;
            }
            let parent_key = relative_key(s, &thread.environment_id, &parent);
            (environment_of(&parent_key) == thread.environment_id).then(|| {
                (
                    thread.environment_id.clone(),
                    thread.id.clone(),
                    run.run_id.clone(),
                    parent,
                    parent_key,
                )
            })
        });
        let Some((environment, id, run_id, parent, parent_key)) = found else {
            return;
        };
        self.mc.dispatch_command(
            &environment,
            json!({
                "type": "thread.merge_back",
                "createdBy": "user",
                "creationSource": "web",
                "sourceThreadId": id,
                "targetThreadId": parent,
                "sourcePoint": {"type": "run", "runId": run_id},
            }),
            Box::new(move |engine, result| match result {
                Err(e) => error(engine, "Failed to merge back", &e.message),
                Ok(_) => open(engine, parent_key),
            }),
        );
    }

    fn fork_from(&mut self, engine: &Engine, run_id: &str) {
        let key = shown_thread(engine);
        let found = store::with(engine, |s| {
            s.thread(&key)
                .filter(|_| s.thread_online(&key))
                .map(|t| (t.environment_id, t.id, t.title))
        });
        let Some((environment, id, title)) = found.filter(|_| !run_id.is_empty()) else {
            return;
        };
        let target = hal_c2_mc::new_uuid();
        let target_key = format!("{environment}:{target}");
        let me = self.me.clone();
        self.mc.dispatch_command(
            &environment,
            json!({
                "type": "thread.fork",
                "createdBy": "user",
                "creationSource": "web",
                "sourceThreadId": id,
                "targetThreadId": target,
                "sourcePoint": {"type": "run", "runId": run_id},
                "title": format!("{title} fork"),
            }),
            Box::new(move |engine, result| match result {
                Err(e) => error(engine, "Failed to fork this response.", &e.message),
                Ok(_) => later(engine, &me, move |c, e| c.open_when_listed(e, target_key)),
            }),
        );
    }

    /// The fork's row follows the command's answer; one that never comes is
    /// said.
    fn open_when_listed(&mut self, engine: &Engine, key: String) {
        if let Some((_, timer)) = self.waiting.take() {
            engine.cancel_call(timer);
        }
        if store::with(engine, |s| s.thread(&key).is_some()) {
            open(engine, key);
            return;
        }
        let me = self.me.clone();
        let timer = engine.call_at(
            engine.now() + Duration::from_millis(ARRIVAL_TIMEOUT_MS),
            move |engine| {
                later(engine, &me, |c, e| {
                    if c.waiting.take().is_some() {
                        error(
                            e,
                            "The fork was created, but it did not reach this client",
                            "Reconnect and try opening it from the thread list.",
                        );
                    }
                })
            },
        );
        self.waiting = Some((key, timer));
    }

    fn store_changed(&mut self, engine: &Engine) {
        let arrived = self
            .waiting
            .as_ref()
            .is_some_and(|(key, _)| store::with(engine, |s| s.thread(key).is_some()));
        if arrived && let Some((key, timer)) = self.waiting.take() {
            engine.cancel_call(timer);
            open(engine, key);
        }
        self.publish(engine);
    }
}

impl Controller for ThreadLineage {
    fn new(init: Init<'_, Self>) -> Self {
        ThreadLineage {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            active: false,
            waiting: None,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |e, _| {
            later(e, &me, |c, e| c.publish(e))
        });
        let me = self.me.clone();
        store::on_changed(engine, move |e| later(e, &me, Self::store_changed));
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active {
            return false;
        }
        let field = |name: &str| {
            payload
                .get(name)
                .and_then(Json::as_str)
                .unwrap_or("")
                .to_owned()
        };
        match action {
            "lineage.open" => {
                let key = field("key");
                if store::with(engine, |s| s.thread(&key).is_some()) {
                    open(engine, key);
                }
            }
            "lineage.mergeBack" => self.merge_back(engine),
            "thread.forkFromRun" => self.fork_from(engine, &field("runId")),
            _ => return false,
        }
        true
    }
}
