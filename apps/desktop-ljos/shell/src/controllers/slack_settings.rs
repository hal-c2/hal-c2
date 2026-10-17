//! `slackSettings`, desktop-qt's SlackSettingsController: Settings →
//! Integrations → Slack. The Slack connection of the settings scope's first
//! environment (HalC2.Slack on the MC serving it), followed through the MC's
//! `slack` shape. Slack is changed one environment at a time: two MCs on one
//! Slack app would split its Socket Mode events between them, so with
//! several environments selected the section only shows the first and says
//! so. The tokens go to the MC in `slack.connect` and never come back; the
//! page learns only whether they are set.
//!
//! Publishes `slackSettings`: {open, loaded, failed (the MC could not follow
//! Slack: HalC2.Slack is down, or the MC serving the environment is out of
//! reach; `error` says why), editable, statusNote ("" unless several
//! environments are selected), state (off | connecting | connected |
//! reconnecting | failed), team, bot, error ("" or why the last change, the
//! connection or loading failed, whichever came last), tokensSet, pending
//! (connect | disconnect | manifest, "" when idle)}.
//!
//! Actions (`slackSettings.`): `connect {botToken, appToken}`, `disconnect`,
//! `copyManifest` (the Slack app manifest onto the clipboard), `retry`
//! (follows Slack again after it failed to load).

use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::settings::Map;
use crate::controllers::settings_scope::SettingsScope;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;
use crate::mc::{Frame, Mc, McError, SubId};
use crate::settings_page;
use crate::store;

const KEY: &str = "slackSettings";
const SECTION: &str = "/settings/integrations";

pub struct SlackSettings {
    bridge: Bridge,
    me: Me<SlackSettings>,
    mc: Rc<dyn Mc>,
    active: bool,
    open: bool,
    environment_id: String,
    subscription: Option<SubId>,
    /// Bumped when Slack is followed afresh or fails to load, so older
    /// answers are dropped.
    generation: u64,
    status: Map,
    /// Counts the statuses taken, so a call's answer can tell whether one
    /// came since it was made.
    statuses: u64,
    loaded: bool,
    failed: bool,
    error: String,
    pending: String,
}

impl Controller for SlackSettings {
    fn new(init: Init<'_, Self>) -> Self {
        SlackSettings {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            open: false,
            environment_id: String::new(),
            subscription: None,
            generation: 0,
            status: Map::new(),
            statuses: 0,
            loaded: false,
            failed: false,
            error: String::new(),
            pending: String::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        self.bridge.watch(engine, "route", move |engine, route| {
            let open = settings_page::shows(route, &[SECTION]);
            me.run(engine, |c, engine| c.route(engine, open));
        });
        let me = self.me.clone();
        SettingsScope::of(engine).on_changed(move |engine| {
            me.run(engine, |c, engine| c.follow(engine));
        });
        // A window restored on Integrations has its route before this
        // activates.
        let route = self.bridge.published(engine, "route").unwrap_or(Json::Null);
        self.route(engine, settings_page::shows(&route, &[SECTION]));
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        let Some(name) = action
            .strip_prefix(KEY)
            .and_then(|rest| rest.strip_prefix('.'))
            .filter(|_| self.active)
        else {
            return false;
        };
        if !self.open || self.environment_id.is_empty() || !self.pending.is_empty() {
            return true;
        }
        if name == "retry" {
            if self.failed {
                self.subscribe(engine);
                self.publish(engine);
            }
            return true;
        }
        // Until Slack is followed, a call's answer would be a status nothing
        // keeps current.
        if !self.loaded {
            return true;
        }
        match name {
            "connect" => {
                if !self.editable(engine) {
                    return true;
                }
                let bot = settings_page::text(payload, "botToken").trim().to_owned();
                let app = settings_page::text(payload, "appToken").trim().to_owned();
                if bot.is_empty() || app.is_empty() {
                    self.error = "Enter both the bot token and the app token.".into();
                    self.publish(engine);
                    return true;
                }
                self.change(engine, "connect", json!({"botToken": bot, "appToken": app}));
            }
            "disconnect" => {
                if self.editable(engine) {
                    self.change(engine, "disconnect", json!({}));
                }
            }
            "copyManifest" => self.copy_manifest(engine),
            _ => {}
        }
        true
    }
}

impl SlackSettings {
    /// The environment whose connection shows: the scope's first connected
    /// one.
    fn inspected(&self, engine: &Engine) -> String {
        if !self.open {
            return String::new();
        }
        SettingsScope::of(engine)
            .targets()
            .into_iter()
            .next()
            .unwrap_or_default()
    }

    fn route(&mut self, engine: &Engine, open: bool) {
        if open == self.open {
            return;
        }
        self.open = open;
        self.follow(engine);
    }

    fn editable(&self, engine: &Engine) -> bool {
        let scope = SettingsScope::of(engine);
        !scope.project_scope() && scope.editable(engine) && scope.targets().len() == 1
    }

    fn follow(&mut self, engine: &Engine) {
        let environment_id = self.inspected(engine);
        if environment_id != self.environment_id {
            self.environment_id = environment_id;
            self.subscribe(engine);
        }
        self.publish(engine);
    }

    /// Follows the inspected environment's Slack afresh, from loading. Frames
    /// of the old subscription stop with it.
    fn subscribe(&mut self, engine: &Engine) {
        if let Some(old) = self.subscription.take() {
            self.mc.unsubscribe(old);
        }
        self.reset();
        if self.environment_id.is_empty() {
            return;
        }
        let mc = store::with(engine, |s| s.mc_serving(&self.environment_id));
        let me = self.me.clone();
        self.subscription = Some(self.mc.subscribe(
            json!({"type": "slack", "mc": mc}),
            Box::new(move |engine: &Engine, frame: &Frame| {
                let status = frame
                    .get("status")
                    .and_then(Json::as_object)
                    .cloned()
                    .unwrap_or_default();
                let reason = frame
                    .get("reason")
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_owned();
                match frame.get("t").and_then(Json::as_str).unwrap_or_default() {
                    "slack" => me.run(engine, |c, engine| c.take(engine, status)),
                    "error" => me.run(engine, |c, engine| c.fail(engine, &reason)),
                    _ => {}
                }
            }),
            None,
        ));
    }

    /// Forgets what was shown. A call in flight answers for that: the
    /// buttons are free again.
    fn reset(&mut self) {
        self.status = Map::new();
        self.loaded = false;
        self.failed = false;
        self.error.clear();
        self.pending.clear();
        self.generation += 1;
    }

    /// The MC could not follow Slack (on a sub, or its resend after a
    /// reconnect) and watches nothing for it: the page says why until the
    /// user retries.
    fn fail(&mut self, engine: &Engine, reason: &str) {
        if let Some(old) = self.subscription.take() {
            self.mc.unsubscribe(old);
        }
        self.reset();
        self.failed = true;
        self.error = reason.to_owned();
        self.publish(engine);
    }

    /// A status from the MC is newer than the page's own error (a refusal,
    /// blank tokens), so it replaces it; the status carries its own error.
    fn take(&mut self, engine: &Engine, status: Map) {
        self.statuses += 1;
        self.status = status;
        self.loaded = true;
        self.error.clear();
        self.publish(engine);
    }

    /// `slack.connect` or `slack.disconnect` on the inspected environment;
    /// each answers with the connection as it now is, and Slack's refusal is
    /// its error. The MC answers and pushes its status along different
    /// paths, so a status that arrived while the call was out may be newer
    /// than the answer, which then only frees the buttons.
    fn change(&mut self, engine: &Engine, pending: &str, input: Json) {
        self.pending = pending.to_owned();
        self.error.clear();
        let me = self.me.clone();
        let generation = self.generation;
        let statuses = self.statuses;
        self.mc.call(
            &self.environment_id,
            &format!("slack.{pending}"),
            input,
            Box::new(move |engine: &Engine, result: Result<Json, McError>| {
                me.run(engine, |c, engine| {
                    if c.generation != generation {
                        return;
                    }
                    c.pending.clear();
                    if c.statuses == statuses {
                        match result {
                            Err(e) => c.error = e.message,
                            Ok(status) => {
                                let status = status.as_object().cloned().unwrap_or_default();
                                c.take(engine, status);
                            }
                        }
                    }
                    c.publish(engine);
                });
            }),
        );
        self.publish(engine);
    }

    fn copy_manifest(&mut self, engine: &Engine) {
        self.pending = "manifest".into();
        let me = self.me.clone();
        let generation = self.generation;
        self.mc.call(
            &self.environment_id,
            "slack.manifest",
            json!({}),
            Box::new(move |engine: &Engine, result: Result<Json, McError>| {
                me.run(engine, |c, engine| {
                    if c.generation != generation {
                        return;
                    }
                    c.pending.clear();
                    let (manifest, error) = match &result {
                        Ok(r) => (settings_page::text(r, "manifest").to_owned(), None),
                        Err(e) => (String::new(), Some(e.message.clone())),
                    };
                    if error.is_some() || manifest.is_empty() {
                        controller::with::<Toasts, _>(engine, |toasts, engine| {
                            toasts.error(
                                engine,
                                "Could not copy the Slack app manifest",
                                &error.unwrap_or_default(),
                            );
                        });
                    } else {
                        c.bridge.copy_text(engine, &manifest);
                        controller::with::<Toasts, _>(engine, |toasts, engine| {
                            toasts.show(
                                engine,
                                "success",
                                "Slack app manifest copied",
                                "Paste it into a new app at api.slack.com/apps.",
                                None,
                                DEFAULT_TIMEOUT_MS,
                            );
                        });
                    }
                    c.publish(engine);
                });
            }),
        );
        self.publish(engine);
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        if !self.open {
            self.bridge.publish(engine, KEY, json!({"open": false}));
            return;
        }
        let scope = SettingsScope::of(engine);
        let targets = scope.targets();
        let status_text = |key: &str| {
            self.status
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let error = if self.error.is_empty() {
            status_text("error")
        } else {
            self.error.clone()
        };
        let state = match status_text("state") {
            s if s.is_empty() => "off".to_owned(),
            s => s,
        };
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "open": true,
                "loaded": self.loaded,
                "failed": self.failed,
                "editable": self.loaded && self.editable(engine),
                "statusNote": if targets.len() > 1 {
                    format!(
                        "Slack for {}. Select one environment to connect or disconnect it.",
                        scope.label(engine, &self.environment_id)
                    )
                } else {
                    String::new()
                },
                "state": state,
                "team": status_text("team"),
                "bot": status_text("bot"),
                "error": error,
                "tokensSet": self.status.get("tokensSet").and_then(Json::as_bool).unwrap_or(false),
                "pending": self.pending,
            }),
        );
    }
}
