//! `threadNotice`, desktop-qt's ThreadNoticeController: what the open
//! thread says above the composer, most pressing first:
//!
//! - A finished turn that left background work running (subagents, watch
//!   loops) says what it is waiting on and can stop it, as the web's
//!   background-work banner did (features/timeline/runs-and-queue.feature).
//!   Once the turn settles this is the only way left to stop that work. A
//!   stop the MC accepts may not have ended the work yet, so it reads
//!   "Stopping..." until the tasks it stopped end (work started since does
//!   not count), for up to [`STOP_WAIT_MS`], then Stop is offered again;
//!   one it refuses is told to the user.
//! - A settled thread says so, and can be un-settled from there, as the
//!   web's parked-thread banner did (features/threads/settle.feature).
//!   Sending a message un-settles it too; the MC does that.
//!
//! Publishes `threadNotice`: null, or {threadKey, kind ("background" or
//! "settled"), title, description, actionLabel, busy}.
//!
//! Actions: `threadNotice.stop` stops the open thread's background work,
//! reading "Stopping..." until that work ends or the wait is over.
//! `threadNotice.unsettle` un-settles the open thread; while the MC
//! answers, the notice reads "Un-settling..." for that thread only; a
//! refusal is a toast, and the thread stays settled.

use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::Duration;

use ljos::prelude::{Engine, TimerId};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{self, Route};
use crate::controllers::sidebar;
use crate::controllers::thread_error;
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::mc::Mc;
use crate::store;

/// How long an accepted stop waits for the work it stopped to end before
/// Stop is offered again.
pub const STOP_WAIT_MS: i64 = 10_000;

/// A stop of a thread's background work: the tasks it stopped, and once
/// the MC accepted it, until when it waits for them to end.
struct Stopping {
    tasks: HashSet<String>,
    /// 0 while the MC has not answered.
    deadline: i64,
}

pub struct ThreadNotice {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<ThreadNotice>,
    active: bool,
    timer: Option<TimerId>,
    /// Threads whose un-settle the MC has not answered yet.
    pending: HashSet<String>,
    /// Threads whose background work is being stopped, by thread key.
    stopping: HashMap<String, Stopping>,
}

fn later(
    engine: &Engine,
    me: &Me<ThreadNotice>,
    f: impl FnOnce(&mut ThreadNotice, &Engine) + 'static,
) {
    let me = me.clone();
    Bridge::of(engine).defer(engine, move |engine| me.run(engine, f));
}

fn open_key(engine: &Engine) -> String {
    match navigation::shown(engine) {
        Route::Thread(key) => key,
        _ => String::new(),
    }
}

fn settled(engine: &Engine, key: &str) -> bool {
    if key.is_empty() {
        return false;
    }
    store::with(engine, |s| {
        s.thread(key).is_some_and(|thread| {
            s.capabilities(&thread.environment_id).settlement
                && thread.settled_override.as_deref() == Some("settled")
        })
    })
}

/// What the thread's finished turn left running, by description (else its
/// task id); none while a turn runs, when stopping the turn stops them.
fn background_tasks(engine: &Engine, key: &str) -> Vec<String> {
    if key.is_empty() {
        return Vec::new();
    }
    store::with(engine, |s| {
        let Some(thread) = s.thread(key) else {
            return Vec::new();
        };
        if thread.active_run_id.is_some() {
            return Vec::new();
        }
        s.thread_row(key)
            .and_then(|row| row.get("pendingBackgroundTasks"))
            .and_then(Json::as_array)
            .map(|tasks| {
                tasks
                    .iter()
                    .map(|task| {
                        let description =
                            task.get("description").and_then(Json::as_str).unwrap_or("");
                        if description.is_empty() {
                            task.get("taskId")
                                .and_then(Json::as_str)
                                .unwrap_or("")
                                .to_owned()
                        } else {
                            description.to_owned()
                        }
                    })
                    .collect()
            })
            .unwrap_or_default()
    })
}

/// The task ids the MC's row of the thread still lists as running.
fn pending_task_ids(engine: &Engine, key: &str) -> HashSet<String> {
    store::with(engine, |s| {
        s.thread_row(key)
            .and_then(|row| row.get("pendingBackgroundTasks"))
            .and_then(Json::as_array)
            .map(|tasks| {
                tasks
                    .iter()
                    .filter_map(|task| task.get("taskId").and_then(Json::as_str).map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default()
    })
}

impl ThreadNotice {
    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let key = open_key(engine);
        let tasks = background_tasks(engine, &key);
        if !tasks.is_empty() {
            let busy = self.stopping.contains_key(&key);
            self.bridge.publish(
                engine,
                "threadNotice",
                json!({
                    "threadKey": key,
                    "kind": "background",
                    "title": if tasks.len() == 1 {
                        "Waiting on background task".to_owned()
                    } else {
                        format!("Waiting on {} background tasks", tasks.len())
                    },
                    "description": tasks.join(", "),
                    "actionLabel": if busy { "Stopping..." } else { "Stop" },
                    "busy": busy,
                }),
            );
            return;
        }
        if !settled(engine, &key) {
            self.bridge.publish(engine, "threadNotice", Json::Null);
            return;
        }
        let busy = self.pending.contains(&key);
        self.bridge.publish(
            engine,
            "threadNotice",
            json!({
                "threadKey": key,
                "kind": "settled",
                "title": "This thread is settled",
                "description": "Send a message to unsettle",
                "actionLabel": if busy { "Un-settling..." } else { "Un-settle" },
                "busy": busy,
            }),
        );
    }

    /// Forgets the accepted stops whose tasks have all ended or whose
    /// wait is over, and arms the timer for the next deadline.
    fn settle_stops(&mut self, engine: &Engine) {
        let now = sidebar::now_ms(engine);
        let mut next: i64 = 0;
        self.stopping.retain(|key, stopping| {
            if stopping.deadline == 0 {
                return true;
            }
            if stopping.deadline <= now
                || pending_task_ids(engine, key).is_disjoint(&stopping.tasks)
            {
                return false;
            }
            if next == 0 || stopping.deadline < next {
                next = stopping.deadline;
            }
            true
        });
        if let Some(timer) = self.timer.take() {
            engine.cancel_call(timer);
        }
        if next != 0 {
            let me = self.me.clone();
            self.timer = Some(engine.call_at(
                engine.now() + Duration::from_millis((next - now).max(0) as u64),
                move |engine| {
                    me.run(engine, |c, e| {
                        c.timer = None;
                        c.settle_stops(e);
                        c.publish(e);
                    });
                },
            ));
        }
    }

    /// Stops that have waited STOP_WAIT_MS give up; the timer calls it at
    /// the next deadline.
    pub fn expire(&mut self, engine: &Engine) {
        self.settle_stops(engine);
        self.publish(engine);
    }

    /// Interrupts the thread, as the web did: with no run named, the MC
    /// stops what its provider session still has running.
    fn stop(&mut self, engine: &Engine, key: &str) {
        if background_tasks(engine, key).is_empty() || self.stopping.contains_key(key) {
            return;
        }
        let Some(thread) = store::with(engine, |s| s.thread(key)) else {
            return;
        };
        self.stopping.insert(
            key.to_owned(),
            Stopping {
                tasks: pending_task_ids(engine, key),
                deadline: 0,
            },
        );
        self.publish(engine);
        let me = self.me.clone();
        let key_owned = key.to_owned();
        self.mc.dispatch_command(
            &thread.environment_id,
            json!({"type": "run.interrupt", "threadId": thread.id}),
            Box::new(move |engine, result| {
                me.run(engine, |c, e| {
                    match result {
                        Err(error) => {
                            c.stopping.remove(&key_owned);
                            let message = if error.message.is_empty() {
                                "Failed to stop background work.".to_owned()
                            } else {
                                error.message.clone()
                            };
                            thread_error::report(e, &key_owned, &message);
                        }
                        Ok(_) => {
                            if let Some(stopping) = c.stopping.get_mut(&key_owned) {
                                stopping.deadline = sidebar::now_ms(e) + STOP_WAIT_MS;
                            }
                        }
                    }
                    c.settle_stops(e);
                    c.publish(e);
                });
            }),
        );
    }
}

impl Controller for ThreadNotice {
    fn new(init: Init<'_, Self>) -> Self {
        ThreadNotice {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            active: false,
            timer: None,
            pending: HashSet::new(),
            stopping: HashMap::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |e, _| {
            later(e, &me, |c, e| c.publish(e));
        });
        let me = self.me.clone();
        store::on_changed(engine, move |e| {
            later(e, &me, |c, e| {
                c.settle_stops(e);
                c.publish(e);
            });
        });
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, _payload: &Json) -> bool {
        if !self.active {
            return false;
        }
        if action == "threadNotice.stop" {
            let key = open_key(engine);
            self.stop(engine, &key);
            return true;
        }
        if action != "threadNotice.unsettle" {
            return false;
        }
        let key = open_key(engine);
        if !settled(engine, &key) || self.pending.contains(&key) {
            return true;
        }
        self.pending.insert(key.clone());
        self.publish(engine);
        let (environment, thread) = match key.split_once(':') {
            Some((environment, thread)) => (environment.to_owned(), thread.to_owned()),
            None => (String::new(), key.clone()),
        };
        let me = self.me.clone();
        self.mc.dispatch_command(
            &environment,
            json!({"type": "thread.unsettle", "threadId": thread, "reason": "user"}),
            Box::new(move |engine, result| {
                me.run(engine, |c, e| {
                    c.pending.remove(&key);
                    if let Err(error) = result {
                        controller::with::<Toasts, _>(e, |t, e| {
                            t.error(e, "Failed to un-settle thread", &error.message);
                        });
                    }
                    c.publish(e);
                });
            }),
        );
        true
    }
}
