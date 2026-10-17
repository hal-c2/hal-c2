//! `cluster`, desktop-qt's ClusterController: this machine's cluster, a
//! settings page the shell owns (apps/server-ex `HalC2.Cluster`). The MC
//! does the work of status, invite, join and remove over the shell's own
//! connection (`cluster.*` RPCs).
//!
//! Publishes `cluster`: {busy, status, error, needsAdmin (the session lacks
//! the access scopes that manage the cluster), invite, notice {kind, text}}.
//! The page shows while the route is the settings section
//! `/settings/cluster` (Navigation, which takes `cluster.open` and
//! `cluster.close`); opening it reads the status afresh.
//!
//! Actions: `cluster.refresh`, `cluster.invite {tailscale?}`,
//! `cluster.invite.copy`, `cluster.join {link}`, `cluster.remove {id}`.

use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::controllers::navigation::CLUSTER_SECTION;
use crate::controllers::settings::Map;
use crate::json::Json;
use crate::mc::{Mc, McError};
use crate::settings_page;

/// What the loopback hint tells the user to do instead.
const LOCAL_ONLY_HINT: &str =
    "Only this machine can open it: the MC listens on loopback. Invite over Tailscale instead.";

type Removed = Rc<dyn Fn(&Engine, &str)>;

pub struct Cluster {
    bridge: Bridge,
    me: Me<Cluster>,
    mc: Rc<dyn Mc>,
    state: Map,
    active: bool,
    /// Whether the route shows this page.
    open: bool,
    /// Bumped by every read and change; a read's answer lands only if
    /// nothing was asked since.
    generation: u64,
    removed: Vec<Removed>,
}

impl Controller for Cluster {
    fn new(init: Init<'_, Self>) -> Self {
        let mut state = Map::new();
        state.insert("busy".into(), json!(false));
        state.insert("status".into(), Json::Null);
        state.insert("error".into(), Json::Null);
        state.insert("needsAdmin".into(), json!(false));
        state.insert("invite".into(), Json::Null);
        state.insert("notice".into(), Json::Null);
        Cluster {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            state,
            active: false,
            open: false,
            generation: 0,
            removed: Vec::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        self.publish(engine);
        // Opening the page (Navigation takes cluster.open) reads it afresh.
        let route = self.bridge.published(engine, "route").unwrap_or(Json::Null);
        self.open = settings_page::shows(&route, &[CLUSTER_SECTION]);
        if self.open {
            self.refresh(engine);
        }
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let open = settings_page::shows(route, &[CLUSTER_SECTION]);
            me.run(engine, |c, engine| {
                if open == c.open {
                    return;
                }
                c.open = open;
                if !open {
                    return;
                }
                c.state.insert("notice".into(), Json::Null);
                c.publish(engine);
                c.refresh(engine);
            });
        });
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("cluster.") {
            return false;
        }
        match action {
            "cluster.refresh" => self.refresh(engine),
            "cluster.invite" => self.invite(engine, settings_page::flag(payload.get("tailscale"))),
            "cluster.invite.copy" => {
                let link = self
                    .state
                    .get("invite")
                    .and_then(|i| i.get("link"))
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_owned();
                if !link.is_empty() {
                    self.bridge.copy_to_clipboard(engine, &link);
                    self.set_notice(engine, "success", "Invite link copied.");
                }
            }
            "cluster.join" => {
                let link = settings_page::text(payload, "link").trim().to_owned();
                if link.is_empty() {
                    self.set_notice(
                        engine,
                        "error",
                        "Paste the invite link from the other machine.",
                    );
                } else {
                    self.change(
                        engine,
                        "cluster.join",
                        json!({"link": link}),
                        "Joined the cluster.".into(),
                        "Join failed",
                    );
                }
            }
            "cluster.remove" => {
                let id = settings_page::text(payload, "id").to_owned();
                if id.is_empty() {
                    return true;
                }
                let label = self
                    .state
                    .get("status")
                    .and_then(|s| s.get("members"))
                    .and_then(Json::as_array)
                    .and_then(|members| {
                        members
                            .iter()
                            .rev()
                            .find(|m| m.get("id").and_then(Json::as_str) == Some(id.as_str()))
                    })
                    .map_or_else(
                        || id.clone(),
                        |m| settings_page::text(m, "label").to_owned(),
                    );
                self.change(
                    engine,
                    "cluster.remove",
                    json!({"id": id}),
                    format!("Removed {label} from the cluster."),
                    "Remove failed",
                );
            }
            _ => return false,
        }
        true
    }
}

impl Cluster {
    /// `f` runs with the id of a machine removed from the cluster, once the
    /// MC has said so: whatever the shell wrote for it goes with it.
    // TODO(port): DraftController is not ported; its drafts for the removed
    // environment are to be dropped from here (ClusterController::change).
    pub fn on_removed(&mut self, f: impl Fn(&Engine, &str) + 'static) {
        self.removed.push(Rc::new(f));
    }

    fn refresh(&mut self, engine: &Engine) {
        self.generation += 1;
        let generation = self.generation;
        self.call(
            engine,
            "cluster.status",
            json!({}),
            move |c, engine, result| {
                // RPCs answer concurrently: a read sent before a join or remove
                // may land after it.
                if generation != c.generation {
                    return;
                }
                match result {
                    Err(error) => {
                        // What was read before may no longer hold; the page
                        // shows why instead.
                        c.state.insert("status".into(), Json::Null);
                        let needs_admin = error.message.starts_with("access:")
                            && error.message.ends_with(" is required");
                        c.state.insert("needsAdmin".into(), json!(needs_admin));
                        let shown = if needs_admin {
                            Json::Null
                        } else {
                            json!(error.message)
                        };
                        c.set(engine, "error", shown);
                    }
                    Ok(status) => {
                        c.state.insert("needsAdmin".into(), json!(false));
                        c.state.insert("error".into(), Json::Null);
                        c.set(engine, "status", object_or_empty(status));
                    }
                }
            },
        );
    }

    fn invite(&mut self, engine: &Engine, tailscale: bool) {
        let payload = if tailscale {
            json!({"tailscale": true})
        } else {
            json!({})
        };
        self.set(engine, "busy", json!(true));
        self.call(engine, "cluster.invite", payload, |c, engine, result| {
            c.state.insert("busy".into(), json!(false));
            let invite = match result {
                Err(error) => {
                    c.set_notice(
                        engine,
                        "error",
                        &format!("Invite failed: {}", error.message),
                    );
                    return;
                }
                Ok(invite) => object_or_empty(invite),
            };
            c.state.insert("invite".into(), invite.clone());
            c.bridge
                .copy_to_clipboard(engine, settings_page::text(&invite, "link"));
            let local_only = invite
                .get("localOnly")
                .and_then(Json::as_bool)
                .unwrap_or(false);
            let mut text = "Invite link copied; join with it on the other machine.".to_owned();
            if local_only {
                text.push(' ');
                text.push_str(LOCAL_ONLY_HINT);
            }
            c.set_notice(engine, if local_only { "error" } else { "success" }, &text);
        });
    }

    /// Join and remove answer with the cluster as it now is.
    fn change(
        &mut self,
        engine: &Engine,
        method: &'static str,
        payload: Json,
        success: String,
        failure: &'static str,
    ) {
        self.generation += 1;
        self.set(engine, "busy", json!(true));
        let sent = payload.clone();
        self.call(engine, method, payload, move |c, engine, result| {
            c.state.insert("busy".into(), json!(false));
            let status = match result {
                Err(error) => {
                    c.set_notice(engine, "error", &format!("{failure}: {}", error.message));
                    // In place of any read this change overtook.
                    c.refresh(engine);
                    return;
                }
                Ok(status) => status,
            };
            // Nothing written for a removed machine is kept: its rows go
            // with it, its drafts here.
            if method == "cluster.remove" {
                let removed = settings_page::text(&sent, "id").to_owned();
                for hook in c.removed.clone() {
                    hook(engine, &removed);
                }
            }
            c.state.insert("status".into(), object_or_empty(status));
            c.state.insert("error".into(), Json::Null);
            c.set_notice(engine, "success", &success);
        });
    }

    /// `method` on the shell's own MC; `reply` runs on this controller.
    fn call(
        &self,
        _engine: &Engine,
        method: &str,
        payload: Json,
        reply: impl FnOnce(&mut Cluster, &Engine, Result<Json, McError>) + 'static,
    ) {
        let me = self.me.clone();
        self.mc.call(
            &self.mc.environment(),
            method,
            payload,
            Box::new(move |engine: &Engine, result| {
                me.run(engine, |c, engine| reply(c, engine, result));
            }),
        );
    }

    fn set_notice(&mut self, engine: &Engine, kind: &str, text: &str) {
        self.set(engine, "notice", json!({"kind": kind, "text": text}));
    }

    fn set(&mut self, engine: &Engine, field: &str, value: Json) {
        self.state.insert(field.into(), value);
        self.publish(engine);
    }

    fn publish(&self, engine: &Engine) {
        if self.active {
            self.bridge
                .publish(engine, "cluster", Json::Object(self.state.clone()));
        }
    }
}

/// `QJsonValue::toObject`: what is not an object is an empty one.
fn object_or_empty(value: Json) -> Json {
    if value.is_object() { value } else { json!({}) }
}
