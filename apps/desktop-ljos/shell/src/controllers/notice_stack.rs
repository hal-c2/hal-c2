//! `noticeStack`, desktop-qt's NoticeStackController: several notices
//! above the composer show one at a time, the most pressing first
//! (features/timeline/runs-and-queue.feature, the web's
//! ComposerBannerStack): the thread's error, a usage limit with its
//! recovery actions and what its provider says when it cannot run stay
//! in front of the answer to "/usage-limits" and of what the agent is
//! doing (background work, then a settled thread). The bricks draw
//! only the front one while the stack is collapsed; asking for the
//! other notices draws them all, and Escape (or going to another
//! thread, or the stack shrinking to one) collapses it again.
//! Dismissing the front one is its own controller's action and brings
//! the next one forward on its own.
//!
//! Publishes `noticeStack`: {front, behind, expanded, order}; front is
//! "" when there are no notices, behind counts the ones behind it.
//!
//! Actions: `noticeStack.expand` shows every notice;
//! `noticeStack.collapse` shows only the front one again.

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::controllers::navigation::{self, Route};
use crate::json::Json;

/// The published states the stack is ordered from.
const SOURCES: [&str; 5] = [
    "threadError",
    "limitRecovery",
    "providerNotice",
    "composer",
    "threadNotice",
];

pub struct NoticeStack {
    bridge: Bridge,
    me: Me<NoticeStack>,
    active: bool,
    expanded: bool,
    thread_key: String,
}

fn later(
    engine: &Engine,
    me: &Me<NoticeStack>,
    f: impl FnOnce(&mut NoticeStack, &Engine) + 'static,
) {
    let me = me.clone();
    Bridge::of(engine).defer(engine, move |engine| me.run(engine, f));
}

fn shown(state: &Json) -> bool {
    state.as_object().is_some_and(|object| !object.is_empty())
}

impl NoticeStack {
    fn order(&self, engine: &Engine) -> Vec<&'static str> {
        let state = |key: &str| self.bridge.published(engine, key).unwrap_or(Json::Null);
        let mut order = Vec::new();
        if shown(&state("threadError")) {
            order.push("error");
        }
        if shown(&state("limitRecovery")) {
            order.push("limit");
        }
        if shown(&state("providerNotice")) {
            order.push("provider");
        }
        if shown(state("composer").get("usageLimits").unwrap_or(&Json::Null)) {
            order.push("usageLimits");
        }
        let notice = state("threadNotice");
        match notice.get("kind").and_then(Json::as_str) {
            Some("background") => order.push("activity"),
            Some("settled") => order.push("settled"),
            _ => {}
        }
        order
    }

    fn publish(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let ordered = self.order(engine);
        if ordered.len() < 2 {
            self.expanded = false;
        }
        self.bridge.publish(
            engine,
            "noticeStack",
            json!({"front": ordered.first().copied().unwrap_or(""),
                   "behind": ordered.len().saturating_sub(1),
                   "expanded": self.expanded,
                   "order": ordered}),
        );
    }
}

impl Controller for NoticeStack {
    fn new(init: Init<'_, Self>) -> Self {
        NoticeStack {
            bridge: init.bridge,
            me: init.me,
            active: false,
            expanded: false,
            thread_key: String::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        for source in SOURCES {
            let me = self.me.clone();
            self.bridge.watch(engine, source, move |e, _| {
                later(e, &me, |c, e| c.publish(e));
            });
        }
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |e, _| {
            later(e, &me, |c, e| {
                let key = match navigation::shown(e) {
                    Route::Thread(key) => key,
                    _ => String::new(),
                };
                if key != c.thread_key {
                    c.thread_key = key;
                    c.expanded = false;
                }
                c.publish(e);
            });
        });
        self.thread_key = match navigation::shown(engine) {
            Route::Thread(key) => key,
            _ => String::new(),
        };
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, _payload: &Json) -> bool {
        if !self.active {
            return false;
        }
        match action {
            "noticeStack.expand" => {
                self.expanded = self.order(engine).len() > 1;
                self.publish(engine);
                true
            }
            "noticeStack.collapse" => {
                self.expanded = false;
                self.publish(engine);
                true
            }
            _ => false,
        }
    }
}
