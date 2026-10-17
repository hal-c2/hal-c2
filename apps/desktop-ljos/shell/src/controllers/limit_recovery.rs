//! `limitRecovery`, desktop-qt's LimitRecoveryController: what the user can
//! do about the open thread once its agent stopped on a usage limit:
//! continue on its own when the limit resets, or snooze the thread until
//! then. The MC arms both (`thread.metadata.update` with `limitRecovery`,
//! HalC2.Orchestration.LimitRecovery); the row says what is armed.
//!
//! Publishes `limitRecovery`: null unless the open thread is limited, else
//! `{threadKey, title, description ("Resets <when>", or "Reset time
//! unavailable; retry manually"), canSchedule (the agent said when the limit
//! resets), scheduled (it resumes at the reset), snoozed (it is snoozed until
//! the reset), canSnooze (the reset is still ahead), error}`.
//!
//! Actions: `limitRecovery.resume` and `limitRecovery.snooze` turn each on,
//! or off again.

use chrono::DateTime;
use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::controllers::{navigation, sidebar, threads};
use crate::json::Json;
use crate::mc::Mc;
use crate::sidebar_model::{self, parse_iso};
use crate::store;
use std::rc::Rc;

pub struct LimitRecovery {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<LimitRecovery>,
    active: bool,
    error: String,
}

/// What the open thread's limit allows now.
#[derive(Default)]
struct Reading {
    limited: bool,
    key: String,
    run_id: String,
    reset_at: String,
    can_schedule: bool,
    scheduled: bool,
    snoozed: bool,
    can_snooze: bool,
}

fn later(engine: &Engine, me: &Me<LimitRecovery>, f: impl FnOnce(&mut LimitRecovery, &Engine) + 'static) {
    let me = me.clone();
    Bridge::of(engine).defer(engine, move |engine| me.run(engine, f));
}

fn read(engine: &Engine) -> Reading {
    let key = match navigation::shown(engine) {
        navigation::Route::Thread(key) => key,
        _ => String::new(),
    };
    let now = sidebar::now_ms(engine);
    store::with(engine, |s| {
        let mut reading = Reading {
            key: key.clone(),
            ..Reading::default()
        };
        let Some(thread) = (!key.is_empty()).then(|| s.thread(&key)).flatten() else {
            return reading;
        };
        let Some(run) = &thread.latest_run else {
            return reading;
        };
        if sidebar_model::status(&thread) != "limited" {
            return reading;
        }
        let row = s.thread_row(&key).cloned().unwrap_or_default();
        let text = |value: Option<&Json>| value.and_then(Json::as_str).unwrap_or("").to_owned();
        reading.limited = true;
        reading.run_id = run.run_id.clone();
        reading.reset_at = text(row.get("usageLimitResetAt"));
        let reset = parse_iso(Some(&reading.reset_at));
        let stopped = parse_iso(Some(run.completed_at.as_deref().unwrap_or(&thread.updated_at)));
        reading.can_schedule = matches!((reset, stopped), (Some(r), Some(s)) if r > s);
        let recovery = row.get("limitRecovery").cloned().unwrap_or(Json::Null);
        let same = text(recovery.get("runId")) == reading.run_id
            && text(recovery.get("resetAt")) == reading.reset_at;
        let flag = |name: &str| recovery.get(name).and_then(Json::as_bool).unwrap_or(false);
        reading.scheduled = same && flag("autoResume");
        let snoozed_until = parse_iso(thread.snoozed_until.as_deref());
        reading.snoozed = same && flag("snooze") && reset.is_some() && snoozed_until == reset;
        reading.can_snooze = reset.is_some_and(|r| r > now);
        reading
    })
}

impl LimitRecovery {
    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let now = read(engine);
        if !now.limited {
            self.bridge.publish(engine, "limitRecovery", Json::Null);
            return;
        }
        // The reset as the timeline's usage-limit row reads it.
        let description = match parse_iso(Some(&now.reset_at)) {
            Some(reset) => format!(
                "Resets {}",
                threads::upcoming(engine, DateTime::from_timestamp_millis(reset))
            ),
            None => "Reset time unavailable; retry manually".to_owned(),
        };
        self.bridge.publish(
            engine,
            "limitRecovery",
            json!({
                "threadKey": now.key,
                "title": "Usage limit reached",
                "description": description,
                "canSchedule": now.can_schedule,
                "scheduled": now.scheduled,
                "snoozed": now.snoozed,
                "canSnooze": now.can_snooze,
                "error": self.error,
            }),
        );
    }
}

impl Controller for LimitRecovery {
    fn new(init: Init<'_, Self>) -> Self {
        LimitRecovery {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            active: false,
            error: String::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |e, _| {
            later(e, &me, |c, e| {
                c.error.clear();
                c.publish(e);
            })
        });
        let me = self.me.clone();
        store::on_changed(engine, move |e| later(e, &me, |c, e| c.publish(e)));
        // The reset reads in the device's time format.
        let me = self.me.clone();
        threads::on_times_changed(engine, move |e| later(e, &me, |c, e| c.publish(e)));
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, _payload: &Json) -> bool {
        if !self.active || !action.starts_with("limitRecovery.") {
            return false;
        }
        let now = read(engine);
        if !now.limited || !now.can_schedule {
            return true;
        }
        let mut update = json!({"runId": now.run_id, "resetAt": now.reset_at});
        match action {
            "limitRecovery.resume" => update["autoResume"] = json!(!now.scheduled),
            "limitRecovery.snooze" => {
                if !now.snoozed && !now.can_snooze {
                    self.error = "The reset time has passed. Retry the thread manually.".into();
                    self.publish(engine);
                    return true;
                }
                update["snooze"] = json!(!now.snoozed);
            }
            _ => return true,
        }
        self.error.clear();
        let (environment, thread) = now.key.split_once(':').unwrap_or(("", &now.key));
        let me = self.me.clone();
        self.mc.dispatch_command(
            environment,
            json!({"type": "thread.metadata.update", "threadId": thread, "limitRecovery": update}),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    c.error = result.err().map(|e| e.message).unwrap_or_default();
                    c.publish(engine);
                });
            }),
        );
        true
    }
}
