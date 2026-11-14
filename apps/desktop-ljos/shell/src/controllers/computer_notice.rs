//! The thread's notice about the computer it runs on, when that is another
//! member of the cluster and it is down: desktop-qt's
//! ComputerNoticeController (ComputerNotice.h holds the rules). The computers
//! come from ServerUpdates' `serverUpdates`, which knows each one's label,
//! whether it is online and whether an update of it is running; whether the
//! cluster still tries one from the shell store; the thread from the window's
//! active thread.
//!
//! Publishes `threadComputer`: null | {kind, environmentId, title, detail,
//! canReconnect, canDisconnect}. Takes `threadComputer.reconnect` (the cluster
//! tries the computer again) and `threadComputer.disconnect` (switches it off
//! in the cluster, which hides it and its threads, and goes home), each
//! {environmentId}; a failure is a toast with the MC's reason.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use ljos::prelude::{Engine, TimerId};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{Navigation, Route};
use crate::controllers::sidebar::now_ms;
use crate::controllers::threads;
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::mc::Mc;
use crate::{store, this_machine};

const KEY: &str = "threadComputer";

/// What a computer is now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Computer {
    pub id: String,
    pub label: String,
    pub online: bool,
    pub updating: bool,
    /// The MC still tries to reach it while it is down.
    pub trying: bool,
    /// It runs on the machine this app runs on.
    pub local: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Notice {
    pub kind: String,
    pub environment_id: String,
    pub title: String,
    pub detail: String,
    pub can_reconnect: bool,
    pub can_disconnect: bool,
}

/// What a thread says about its computer. The MC keeps trying to reach a
/// member that is down, so down reads as reconnecting until the MC says it
/// has stopped trying:
///
/// * `offline`: the MC no longer tries it on its own; the user may ask it to
///   reconnect, update or not
/// * `updating`: an update of it is running; the update, not a warning
/// * `reconnecting`: down for longer than two seconds
/// * empty: down for less; the thread knows, and says nothing yet
///
/// A computer down for [`Rules::DISCONNECT_MS`] that does not run on this
/// machine may be switched off from the notice; coming back starts its time
/// over. Told what each computer is and what time it is (milliseconds, any
/// epoch); the owner calls `advance` at `next_deadline`.
#[derive(Default)]
pub struct Rules {
    computers: HashMap<String, Computer>,
    down_since: HashMap<String, i64>,
    shown: String,
    notice: Option<Notice>,
}

impl Rules {
    pub const GRACE_MS: i64 = 2_000;
    pub const DISCONNECT_MS: i64 = 20_000;

    /// A computer's state now; true when the notice changed.
    pub fn see(&mut self, computer: Computer, now_ms: i64) -> bool {
        if computer.online {
            self.down_since.remove(&computer.id);
        } else {
            self.down_since.entry(computer.id.clone()).or_insert(now_ms);
        }
        self.computers.insert(computer.id.clone(), computer);
        self.refresh(now_ms)
    }

    /// The computer is gone from the cluster.
    pub fn forget(&mut self, id: &str, now_ms: i64) -> bool {
        self.down_since.remove(id);
        self.computers.remove(id);
        self.refresh(now_ms)
    }

    /// The thread shown is on `id`; empty for none, or for the computer this
    /// client connects to.
    pub fn show(&mut self, id: &str, now_ms: i64) -> bool {
        id.clone_into(&mut self.shown);
        self.refresh(now_ms)
    }

    pub fn advance(&mut self, now_ms: i64) -> bool {
        self.refresh(now_ms)
    }

    /// When the shown computer's grace, or its wait for a disconnect, ends;
    /// none when nothing waits on it.
    pub fn next_deadline(&self, now_ms: i64) -> Option<i64> {
        let since = *self.down_since.get(&self.shown)?;
        self.notice.as_ref()?;
        [since + Self::GRACE_MS, since + Self::DISCONNECT_MS]
            .into_iter()
            .find(|&deadline| deadline > now_ms)
    }

    /// None while the shown computer is up; its kind is empty in the grace.
    pub fn notice(&self) -> Option<&Notice> {
        self.notice.as_ref()
    }

    fn refresh(&mut self, now_ms: i64) -> bool {
        let next = self
            .computers
            .get(&self.shown)
            .filter(|c| !self.shown.is_empty() && !c.online)
            .map(|computer| {
                let label = if computer.label.is_empty() {
                    &computer.id
                } else {
                    &computer.label
                };
                let down = now_ms - self.down_since.get(&computer.id).copied().unwrap_or(now_ms);
                let mut notice = Notice {
                    environment_id: computer.id.clone(),
                    ..Notice::default()
                };
                if !computer.trying {
                    notice.kind = "offline".into();
                    notice.title = format!("{label} is offline");
                    notice.can_reconnect = true;
                } else if computer.updating {
                    notice.kind = "updating".into();
                    notice.title = format!("Updating {label}");
                    notice.detail = format!("{label} is restarting on the new version.");
                } else if down >= Self::GRACE_MS {
                    notice.kind = "reconnecting".into();
                    notice.title = format!("{label} is reconnecting");
                }
                notice.can_disconnect =
                    !computer.local && down >= Self::DISCONNECT_MS && notice.kind != "updating";
                notice
            });
        if next == self.notice {
            return false;
        }
        self.notice = next;
        true
    }
}

pub struct ComputerNotice {
    me: Me<ComputerNotice>,
    bridge: Bridge,
    mc: std::rc::Rc<dyn Mc>,
    rules: Rules,
    seen: HashSet<String>,
    timer: Option<TimerId>,
}

impl Controller for ComputerNotice {
    fn new(init: Init<'_, Self>) -> Self {
        ComputerNotice {
            me: init.me,
            bridge: init.bridge,
            mc: init.mc,
            rules: Rules::default(),
            seen: HashSet::new(),
            timer: None,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        let me = self.me.clone();
        self.bridge
            .watch(engine, "serverUpdates", move |engine, _| {
                me.run_after(engine, |c, engine| c.see_computers(engine));
            });
        // Whether the cluster still tries a computer comes with the shell's
        // frames; and the client's own MC may change hands.
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run_after(engine, |c, engine| {
                c.see_computers(engine);
                c.show_thread(engine);
            });
        });
        let me = self.me.clone();
        threads::on_active_changed(engine, move |engine| {
            me.run_after(engine, |c, engine| c.show_thread(engine));
        });
        self.see_computers(engine);
        self.show_thread(engine);
        self.bridge.publish(engine, KEY, Json::Null);
        self.changed(engine, true);
    }

    fn handle(&mut self, _engine: &Engine, action: &str, payload: &Json) -> bool {
        let reconnect = action == "threadComputer.reconnect";
        if !reconnect && action != "threadComputer.disconnect" {
            return false;
        }
        let id = payload
            .get("environmentId")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned();
        // Only what the notice offers, for the computer it is about.
        let offered = self.rules.notice().is_some_and(|n| {
            n.environment_id == id
                && if reconnect {
                    n.can_reconnect
                } else {
                    n.can_disconnect
                }
        });
        if !offered {
            return true;
        }
        if reconnect {
            self.ask(
                "cluster.reconnect",
                json!({"id": id}),
                "Could not reconnect environment",
                false,
            );
        } else {
            self.ask(
                "cluster.switch",
                json!({"id": id, "on": false}),
                "Could not disconnect server",
                true,
            );
        }
        true
    }
}

impl ComputerNotice {
    /// The grace of a computer that dropped may have run out; the timer
    /// calls it, and a test that moves the clock.
    pub fn expire(&mut self, engine: &Engine) {
        let changed = self.rules.advance(now_ms(engine));
        self.changed(engine, changed);
    }

    fn see_computers(&mut self, engine: &Engine) {
        let state = self
            .bridge
            .published(engine, "serverUpdates")
            .unwrap_or(Json::Null);
        let now = now_ms(engine);
        let mut seen = HashSet::new();
        let mut moved = false;
        for machine in state
            .get("machines")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
        {
            let text = |key: &str| {
                machine
                    .get(key)
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_owned()
            };
            let flag = |key: &str| machine.get(key).and_then(Json::as_bool).unwrap_or(false);
            let id = text("environmentId");
            let computer = Computer {
                trying: store::with(engine, |s| s.environment_trying(&id)),
                local: this_machine::hosts(engine, &id),
                label: text("label"),
                online: flag("online"),
                updating: flag("updating"),
                id: id.clone(),
            };
            seen.insert(id);
            moved |= self.rules.see(computer, now);
        }
        for gone in self.seen.difference(&seen) {
            moved |= self.rules.forget(gone, now);
        }
        self.seen = seen;
        self.changed(engine, moved);
    }

    fn show_thread(&mut self, engine: &Engine) {
        let key = threads::active(engine);
        let mut environment = key.split(':').next().unwrap_or_default();
        // The computer this client connects to has the window's own notice.
        if environment == self.mc.environment() {
            environment = "";
        }
        let changed = self.rules.show(environment, now_ms(engine));
        self.changed(engine, changed);
    }

    /// Asks the window's own MC `method` for the computer, toasting `failure`
    /// with its reason; a disconnect that succeeds goes home.
    fn ask(&self, method: &str, payload: Json, failure: &'static str, home: bool) {
        let me = self.me.clone();
        self.mc.call(
            &self.mc.environment(),
            method,
            payload,
            Box::new(move |engine, result| {
                me.run_after(engine, move |_, engine| match result {
                    Ok(_) if home => {
                        controller::with::<Navigation, _>(engine, |n, engine| {
                            n.open(engine, Route::Home)
                        });
                    }
                    Ok(_) => {}
                    Err(error) => {
                        controller::with::<Toasts, _>(engine, |t, engine| {
                            t.show(engine, "error", failure, &error.message, None, 5_000)
                        });
                    }
                });
            }),
        );
    }

    fn changed(&mut self, engine: &Engine, changed: bool) {
        if let Some(timer) = self.timer.take() {
            engine.cancel_call(timer);
        }
        let now = now_ms(engine);
        if let Some(deadline) = self.rules.next_deadline(now) {
            let me = self.me.clone();
            let wait = (deadline - now).max(0) as u64;
            self.timer = Some(engine.call_at(
                engine.now() + Duration::from_millis(wait),
                move |engine| {
                    me.run(engine, |c, engine| {
                        c.timer = None;
                        c.expire(engine);
                    });
                },
            ));
        }
        if !changed {
            return;
        }
        let value = self.rules.notice().map_or(Json::Null, |n| {
            json!({
                "kind": n.kind,
                "environmentId": n.environment_id,
                "title": n.title,
                "detail": n.detail,
                "canReconnect": n.can_reconnect,
                "canDisconnect": n.can_disconnect,
            })
        });
        self.bridge.publish(engine, KEY, value);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn studio(online: bool) -> Computer {
        Computer {
            id: "studio".into(),
            label: "studio".into(),
            online,
            updating: false,
            trying: true,
            local: false,
        }
    }

    #[test]
    fn a_computer_down_is_named_after_its_grace_and_offered_after_twenty_seconds() {
        let mut rules = Rules::default();
        rules.show("studio", 0);
        rules.see(studio(false), 0);
        assert_eq!(rules.notice().map(|n| n.kind.as_str()), Some(""));
        assert_eq!(rules.next_deadline(0), Some(2_000));
        rules.advance(2_000);
        assert_eq!(
            rules.notice().map(|n| n.title.as_str()),
            Some("studio is reconnecting")
        );
        assert!(!rules.notice().is_some_and(|n| n.can_disconnect));
        rules.advance(20_000);
        assert!(rules.notice().is_some_and(|n| n.can_disconnect));
        rules.see(studio(true), 21_000);
        assert!(rules.notice().is_none());
        rules.see(studio(false), 22_000);
        rules.advance(41_999);
        assert!(!rules.notice().is_some_and(|n| n.can_disconnect));
    }
}
