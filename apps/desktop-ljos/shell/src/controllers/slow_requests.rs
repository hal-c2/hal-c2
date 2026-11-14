//! The "Some requests are slow" warning, desktop-qt's SlowRequestController
//! (SlowRequests.h holds the rules): a toast that stays while any of the MC's
//! calls has waited too long for its answer, and closes once none does. Its
//! "Show requests" lists each by its method and environment and when it
//! started. No state of its own: the warning is a toast.

use chrono::{Local, TimeZone};
use ljos::prelude::{Engine, TimerId};

use crate::controller::{self, Controller, Init, Me};
use crate::controllers::sidebar::now_ms;
use crate::controllers::toasts::{Action, Row, Toasts};
use crate::json::Json;
use crate::mc::CallEvent;

const TITLE: &str = "Some requests are slow";

/// The calls that have waited too long. Told when a call starts and ends and
/// what time it is (milliseconds, any epoch); a call is slow once it has
/// waited its method's threshold: 15 s, or 2 min for a provider or server
/// update, which install before they answer. Pull request lookups and
/// subscriptions are never tracked, nor the usage summary. At most 256 calls
/// are tracked: the oldest waiting one makes room.
#[derive(Default)]
pub struct Waiting {
    waiting: Vec<Request>,
    slow: Vec<Request>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub id: u64,
    pub environment: String,
    pub method: String,
    pub started_at_ms: i64,
    pub threshold_ms: i64,
}

impl Waiting {
    pub const THRESHOLD_MS: i64 = 15_000;
    pub const LONG_THRESHOLD_MS: i64 = 120_000;
    pub const MAX_TRACKED: usize = 256;

    pub fn tracked(method: &str) -> bool {
        !method.contains("subscribe")
            && !method.starts_with("pullRequests.")
            && method != "server.getUsageSummary"
            && method != "previewAutomation.connect"
    }

    pub fn threshold_of(method: &str) -> i64 {
        match method {
            "server.updateProvider" | "server.refreshProviders" | "server.updateServer" => {
                Self::LONG_THRESHOLD_MS
            }
            _ => Self::THRESHOLD_MS,
        }
    }

    /// A call went out. True when the slow list changed (a slow one made room).
    pub fn start(&mut self, id: u64, environment: &str, method: &str, now_ms: i64) -> bool {
        if !Self::tracked(method) {
            return false;
        }
        let mut changed = self.end(id);
        if self.waiting.len() + self.slow.len() >= Self::MAX_TRACKED {
            // The waiting ones go first; the slow ones are on screen.
            if !self.waiting.is_empty() {
                self.waiting.remove(0);
            } else {
                self.slow.remove(0);
                changed = true;
            }
        }
        self.waiting.push(Request {
            id,
            environment: environment.to_owned(),
            method: method.to_owned(),
            started_at_ms: now_ms,
            threshold_ms: Self::threshold_of(method),
        });
        changed
    }

    /// A call was answered, or failed. True when the slow list changed.
    pub fn end(&mut self, id: u64) -> bool {
        self.waiting.retain(|r| r.id != id);
        let before = self.slow.len();
        self.slow.retain(|r| r.id != id);
        self.slow.len() != before
    }

    /// The time is `now_ms`: the calls that waited their threshold become
    /// slow. True when the slow list changed.
    pub fn advance(&mut self, now_ms: i64) -> bool {
        let (due, waiting): (Vec<_>, Vec<_>) = std::mem::take(&mut self.waiting)
            .into_iter()
            .partition(|r| now_ms - r.started_at_ms >= r.threshold_ms);
        self.waiting = waiting;
        let changed = !due.is_empty();
        self.slow.extend(due);
        changed
    }

    /// When the next waiting call becomes slow, none when nothing waits.
    pub fn next_deadline(&self) -> Option<i64> {
        self.waiting
            .iter()
            .map(|r| r.started_at_ms + r.threshold_ms)
            .min()
    }

    /// The slow calls, in the order they became slow.
    pub fn slow(&self) -> &[Request] {
        &self.slow
    }

    pub fn tracking(&self) -> usize {
        self.waiting.len() + self.slow.len()
    }

    /// "2 requests waiting longer than 15s.": the smallest threshold they passed.
    pub fn description(&self) -> String {
        let Some(threshold) = self.slow.iter().map(|r| r.threshold_ms).min() else {
            return String::new();
        };
        let count = self.slow.len();
        format!(
            "{count} request{} waiting longer than {}s.",
            if count == 1 { "" } else { "s" },
            (threshold + 500) / 1000
        )
    }
}

/// When a request started, as its row says it: "Started 09:41".
pub fn started_text(started_at_ms: i64) -> String {
    let at = Local
        .timestamp_millis_opt(started_at_ms)
        .single()
        .unwrap_or_default();
    format!("Started {}", at.format("%H:%M"))
}

pub struct SlowRequests {
    me: Me<SlowRequests>,
    requests: Waiting,
    timer: Option<TimerId>,
    toast: String,
    shown: bool,
}

impl Controller for SlowRequests {
    fn new(init: Init<'_, Self>) -> Self {
        let me = init.me.clone();
        init.mc.on_call(Box::new(move |engine, event| {
            let event = event.clone();
            me.run_after(engine, move |c, engine| c.on_call(engine, &event));
        }));
        SlowRequests {
            me: init.me,
            requests: Waiting::default(),
            timer: None,
            toast: String::new(),
            shown: false,
        }
    }

    fn handle(&mut self, _engine: &Engine, _action: &str, _payload: &Json) -> bool {
        false
    }
}

impl SlowRequests {
    pub fn requests(&self) -> &Waiting {
        &self.requests
    }

    fn on_call(&mut self, engine: &Engine, event: &CallEvent) {
        let changed = match event {
            CallEvent::Started {
                id,
                environment,
                method,
            } => self
                .requests
                .start(*id, environment, method, now_ms(engine)),
            CallEvent::Ended { id } => self.requests.end(*id),
        };
        self.schedule(engine);
        if changed {
            self.publish(engine);
        }
    }

    /// The calls that have waited their threshold become slow; the timer
    /// calls it at the next deadline, and a test that moves the clock.
    pub fn expire(&mut self, engine: &Engine) {
        let changed = self.requests.advance(now_ms(engine));
        self.schedule(engine);
        if changed {
            self.publish(engine);
        }
    }

    fn schedule(&mut self, engine: &Engine) {
        if let Some(timer) = self.timer.take() {
            engine.cancel_call(timer);
        }
        let Some(deadline) = self.requests.next_deadline() else {
            return;
        };
        let wait = (deadline - now_ms(engine)).clamp(0, 120_000) as u64;
        let me = self.me.clone();
        self.timer = Some(engine.call_at(
            engine.now() + std::time::Duration::from_millis(wait),
            move |engine| {
                me.run(engine, |c, engine| {
                    c.timer = None;
                    c.expire(engine);
                });
            },
        ));
    }

    fn environment_label(engine: &Engine, environment: &str) -> String {
        let label = crate::store::with(engine, |s| {
            s.environment(environment)
                .get("label")
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        });
        if label.is_empty() {
            environment.to_owned()
        } else {
            label
        }
    }

    fn publish(&mut self, engine: &Engine) {
        if self.requests.slow().is_empty() {
            if !self.toast.is_empty() {
                let toast = std::mem::take(&mut self.toast);
                Self::toasts(engine, |t, engine| t.dismiss(engine, &toast));
            }
            self.shown = false;
            return;
        }
        let me = self.me.clone();
        let toggle = |shown: bool| {
            let me = me.clone();
            Action::new(
                if shown {
                    "Hide requests"
                } else {
                    "Show requests"
                },
                move |engine| {
                    me.run_after(engine, |c, engine| {
                        c.shown = !c.shown;
                        c.publish(engine);
                    })
                },
            )
            .keeping_toast()
        };
        let description = self.requests.description();
        let shown = self.shown;
        let toast = self.toast.clone();
        // Closed by the user: the next change shows it again.
        let replaced = !toast.is_empty()
            && Self::toasts(engine, |t, engine| {
                t.replace(
                    engine,
                    &toast,
                    "warning",
                    TITLE,
                    &description,
                    vec![toggle(shown)],
                    0,
                )
            })
            .unwrap_or(false);
        if !replaced {
            self.shown = false;
            self.toast = Self::toasts(engine, |t, engine| {
                t.show(
                    engine,
                    "warning",
                    TITLE,
                    &description,
                    Some(toggle(false)),
                    0,
                )
            })
            .unwrap_or_default();
        }
        let rows: Vec<Row> = if self.shown {
            self.requests
                .slow()
                .iter()
                .map(|r| Row {
                    id: r.id.to_string(),
                    label: r.method.clone(),
                    text: format!(
                        "{} · {}",
                        Self::environment_label(engine, &r.environment),
                        started_text(r.started_at_ms)
                    ),
                    kind: "idle".into(),
                    action: String::new(),
                })
                .collect()
        } else {
            Vec::new()
        };
        let toast = self.toast.clone();
        Self::toasts(engine, |t, engine| {
            t.set_rows(engine, &toast, rows, |_, _| {})
        });
    }

    fn toasts<R>(engine: &Engine, f: impl FnOnce(&mut Toasts, &Engine) -> R) -> Option<R> {
        controller::with::<Toasts, _>(engine, f)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_call_is_slow_once_it_waited_its_threshold() {
        let mut w = Waiting::default();
        assert!(!w.start(1, "env", "projects.searchEntries", 0));
        assert!(!w.start(2, "env", "server.updateProvider", 0));
        assert!(!w.start(3, "env", "pullRequests.detail", 0));
        assert_eq!(w.tracking(), 2);
        assert!(!w.advance(14_999));
        assert!(w.advance(15_000));
        assert_eq!(w.description(), "1 request waiting longer than 15s.");
        assert_eq!(w.next_deadline(), Some(120_000));
        assert!(w.advance(120_000));
        assert_eq!(w.description(), "2 requests waiting longer than 15s.");
        assert!(w.end(1));
        assert_eq!(w.description(), "1 request waiting longer than 120s.");
        assert!(w.end(2));
        assert_eq!(w.description(), "");
    }
}
