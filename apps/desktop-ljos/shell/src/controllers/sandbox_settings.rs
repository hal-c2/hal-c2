//! `sandboxSettings`, desktop-qt's SandboxSettingsController: Settings →
//! Review sandboxes, whether this environment can run code reviews in an
//! OpenShell sandbox, and when it can't, why and what to do, from the MC's
//! `server.getOpenShellStatus` (apps/server-ex HalC2.OpenShell.Command).
//! Read when the page opens and on refresh; never pushed or polled.
//!
//! Publishes `sandboxSettings`: {loading, state: loading | error |
//! unsupported | attention | ready, summary, detail, error (string | null),
//! problems: [{code, message}]}, where state is what the last answer said
//! (loading until one lands) and `loading` is whether a read is out. Only the
//! latest read lands.
//!
//! Actions: `sandboxSettings.refresh`.

use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::json::Json;
use crate::mc::Mc;

pub const SECTION: &str = "/settings/sandboxes";

pub struct SandboxSettings {
    bridge: Bridge,
    me: Me<SandboxSettings>,
    mc: Rc<dyn Mc>,
    active: bool,
    open: bool,
    loading: bool,
    // An answer, or an error, has landed.
    landed: bool,
    generation: u64,
    error: String,
    status: Json,
}

impl Controller for SandboxSettings {
    fn new(init: Init<'_, Self>) -> Self {
        SandboxSettings {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            open: false,
            loading: false,
            landed: false,
            generation: 0,
            error: String::new(),
            status: json!({}),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let open = opened(route);
            me.run(engine, |s, engine| {
                if open != s.open {
                    s.open = open;
                    if open {
                        s.read(engine);
                    }
                }
            });
        });
        self.open = self
            .bridge
            .published(engine, "route")
            .is_some_and(|r| opened(&r));
        if self.open {
            self.read(engine);
        }
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, _payload: &Json) -> bool {
        if !self.active || action != "sandboxSettings.refresh" {
            return false;
        }
        self.read(engine);
        true
    }
}

/// Whether the route is the sandboxes page.
fn opened(route: &Json) -> bool {
    route.get("kind").and_then(Json::as_str) == Some("settings")
        && route.get("section").and_then(Json::as_str) == Some(SECTION)
}

fn mode_name(mode: &str) -> &str {
    match mode {
        "managed" => "run by this MC",
        "external" => "a gateway you run",
        "foreground" => "the dev run",
        other => other,
    }
}

impl SandboxSettings {
    fn read(&mut self, engine: &Engine) {
        self.loading = true;
        self.generation += 1;
        let generation = self.generation;
        let me = self.me.clone();
        self.mc.call(
            &self.mc.environment(),
            "server.getOpenShellStatus",
            json!({}),
            Box::new(move |engine: &Engine, result| {
                me.run(engine, |s, engine| {
                    if generation != s.generation {
                        return;
                    }
                    s.loading = false;
                    s.landed = true;
                    match result {
                        Ok(status) => {
                            s.error.clear();
                            s.status = status;
                        }
                        Err(error) => {
                            s.error = if error.message.is_empty() {
                                "The MC did not say why.".into()
                            } else {
                                error.message
                            };
                            s.status = json!({});
                        }
                    }
                    s.publish(engine);
                });
            }),
        );
        self.publish(engine);
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let field = |key: &str| self.status.get(key).and_then(Json::as_str).unwrap_or("");
        let flag = |key: &str| self.status.get(key).and_then(Json::as_bool) == Some(true);
        let problems: Vec<Json> = self
            .status
            .get("problems")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
            .map(|p| {
                json!({"code": p.get("code").and_then(Json::as_str).unwrap_or(""),
                       "message": p.get("message").and_then(Json::as_str).unwrap_or("")})
            })
            .collect();
        let (state, summary, detail) = if !self.landed {
            (
                "loading",
                "Asking the MC whether review sandboxes can run here…",
                String::new(),
            )
        } else if !self.error.is_empty() {
            (
                "error",
                "Could not read whether review sandboxes can run here.",
                String::new(),
            )
        } else if !flag("supported") {
            (
                "unsupported",
                "Review sandboxes can't run on this machine.",
                "Code reviews run without a sandbox here.".to_owned(),
            )
        } else if !flag("ready") {
            (
                "attention",
                "Review sandboxes can't run here yet.",
                format!(
                    "OpenShell {} is the version this MC pins.",
                    field("pinnedVersion")
                ),
            )
        } else {
            let mode = mode_name(field("mode"));
            let version = field("version");
            let detail = if version.is_empty() {
                format!("OpenShell, {mode}.")
            } else {
                format!("OpenShell {version}, {mode}.")
            };
            ("ready", "Review sandboxes can run here.", detail)
        };
        let error = if self.error.is_empty() {
            Json::Null
        } else {
            json!(self.error)
        };
        self.bridge.publish(
            engine,
            "sandboxSettings",
            json!({"loading": self.loading, "state": state, "summary": summary,
                   "detail": detail, "error": error, "problems": problems}),
        );
    }
}
