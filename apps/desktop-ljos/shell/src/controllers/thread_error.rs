//! `threadError`, desktop-qt's ThreadErrorController: the open thread's
//! error, as the web's ThreadErrorBanner showed it over the timeline
//! (features/timeline/runs-and-queue.feature): what this client could
//! not do on the thread ([`report`]), else the thread's last error from
//! its row (`lastError`). A usage limit the thread's failed run stopped
//! on is left to the timeline, whose warning line names when to retry.
//! Dismissing hides that error of that run on that thread until the app
//! restarts; a different one, the same one from a later run, or this
//! client reporting it again, shows.
//!
//! Publishes `threadError`: null, or {threadKey, message, warning};
//! warning for a usage limit.
//!
//! Action: `threadError.dismiss` hides the open thread's error.

use std::collections::{HashMap, HashSet};

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{self, Route};
use crate::json::Json;
use crate::store;

pub struct ThreadError {
    bridge: Bridge,
    me: Me<ThreadError>,
    active: bool,
    /// This client's own errors, by thread key.
    local: HashMap<String, String>,
    /// Errors the user dismissed: thread key, NUL, latest run, NUL, message.
    dismissed: HashSet<String>,
}

struct Shown {
    message: String,
    warning: bool,
}

fn later(
    engine: &Engine,
    me: &Me<ThreadError>,
    f: impl FnOnce(&mut ThreadError, &Engine) + 'static,
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

fn text(row: &serde_json::Map<String, Json>, field: &str) -> String {
    row.get(field)
        .and_then(Json::as_str)
        .unwrap_or("")
        .to_owned()
}

/// Something this client could not do on the thread `thread_key`: it is
/// the thread's error until dismissed.
pub fn report(engine: &Engine, thread_key: &str, message: &str) {
    let key = thread_key.to_owned();
    let message = message.to_owned();
    controller::with::<ThreadError, _>(engine, move |c, engine| {
        c.report(engine, &key, &message);
    });
}

impl ThreadError {
    pub fn report(&mut self, engine: &Engine, thread_key: &str, message: &str) {
        if thread_key.is_empty() || message.is_empty() {
            return;
        }
        // A report is a new event: the same refusal twice in one run is
        // said twice.
        let dismissal = self.dismissal(engine, thread_key, message);
        self.dismissed.remove(&dismissal);
        self.local.insert(thread_key.to_owned(), message.to_owned());
        self.publish(engine);
    }

    /// What a dismissal of `message` on the thread `key` hides: that
    /// message while the thread's latest run is the one now.
    fn dismissal(&self, engine: &Engine, key: &str, message: &str) -> String {
        let run = store::with(engine, |s| {
            s.thread_row(key).map(|row| text(row, "latestRunId"))
        })
        .unwrap_or_default();
        format!("{key}\u{0}{run}\u{0}{message}")
    }

    fn shown(&self, engine: &Engine, key: &str) -> Option<Shown> {
        if key.is_empty() {
            return None;
        }
        let row = store::with(engine, |s| s.thread_row(key).cloned())?;
        let last = text(&row, "lastError");
        let message = self.local.get(key).unwrap_or(&last).clone();
        if message.is_empty()
            || self
                .dismissed
                .contains(&self.dismissal(engine, key, &message))
        {
            return None;
        }
        let from_row = !self.local.contains_key(key);
        let limit = from_row && text(&row, "lastErrorClass") == "usage_limit";
        // The run that stopped on the limit says so in the timeline.
        if limit && text(&row, "status") == "failed" && !text(&row, "latestRunId").is_empty() {
            return None;
        }
        Some(Shown {
            message,
            warning: limit,
        })
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let key = open_key(engine);
        match self.shown(engine, &key) {
            None => self.bridge.publish(engine, "threadError", Json::Null),
            Some(error) => self.bridge.publish(
                engine,
                "threadError",
                json!({"threadKey": key, "message": error.message, "warning": error.warning}),
            ),
        }
    }
}

impl Controller for ThreadError {
    fn new(init: Init<'_, Self>) -> Self {
        ThreadError {
            bridge: init.bridge,
            me: init.me,
            active: false,
            local: HashMap::new(),
            dismissed: HashSet::new(),
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
        store::on_changed(engine, move |e| later(e, &me, |c, e| c.publish(e)));
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, _payload: &Json) -> bool {
        if !self.active || action != "threadError.dismiss" {
            return false;
        }
        let key = open_key(engine);
        let Some(error) = self.shown(engine, &key) else {
            return true;
        };
        self.local.remove(&key);
        self.dismissed
            .insert(self.dismissal(engine, &key, &error.message));
        self.publish(engine);
        true
    }
}
