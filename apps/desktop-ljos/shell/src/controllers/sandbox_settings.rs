//! `sandboxSettings`, desktop-qt's SandboxSettingsController: Settings →
//! Review sandboxes, whether this environment can run code reviews in an
//! OpenShell sandbox, and when it can't, why and what to do, from the MC's
//! `server.getOpenShellStatus` (apps/server-ex HalC2.OpenShell.Command),
//! read when the page opens, on refresh and after each operation; and the
//! operations that status offers (Install, Check, Rotate certificates,
//! Uninstall, …), run with `server.runOpenShellOperation` while their steps
//! and outcome come from the openShell shape, followed while the page is
//! open, so an operation another device started shows here too.
//!
//! Publishes `sandboxSettings`: {loading,
//! state: loading | error | unsupported | attention | ready, summary,
//! detail, error (string | null), problems: [{code, message}],
//! actions: [{operation, label}], canManage, manageReason (string | null),
//! busy, operation: {operation, running, label, steps: [string],
//! result: {ok, message} | null} | null, refusal (string | null),
//! confirm: {text} | null}, where state is what the last answer said
//! (loading until one lands) and `loading` is whether a read is out. Only
//! the latest read lands. `busy` is whether an operation runs on the MC, or
//! one this page asked for has been neither refused nor followed by a frame
//! of its run (by the number its reply carries); the actions are off while
//! it is or when this session may not manage the MC's machine (manageReason
//! says why). `confirm` asks before an operation this page asked for stops
//! this MC's reviews (or runs without knowing whether it would); a yes names
//! the reviews it asked about (`drain`), and the MC asks again when others
//! run by then (`sandboxes-changed`). `refusal` also says when the MC lost
//! track of the run this page asked for before it told how it went (it
//! restarted, or a later run replaced it unseen).
//!
//! Actions: `sandboxSettings.refresh`, `sandboxSettings.run` {operation},
//! `sandboxSettings.confirm`, `sandboxSettings.cancel`.

use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::json::Json;
use crate::mc::{Mc, SubId};

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
    subscription: Option<SubId>,
    // The openShell shape's last frame: {operation, running, steps, result}.
    operation: Json,
    // The operation this page asked for, until its outcome arrives.
    asked: String,
    // A run this page sent that the MC has not refused and no frame of has
    // landed since its reply.
    starting: bool,
    // The run's number, from its reply: -1 until it lands.
    awaited: i64,
    // The latest run asked for, so an older one's reply is not taken for it.
    request: u64,
    refusal: String,
    // A frame of this opening has landed, and the last one's number.
    followed: bool,
    last: i64,
    // The ended run the status was last read for: the one the shape's first
    // frame showed ended (the read the page opened with covers it), then
    // each one after.
    known: Option<i64>,
    // What a yes reruns: the operation and what it adds, the drain's names
    // or force.
    confirm_operation: String,
    confirm_flags: Json,
    confirm_text: String,
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
            subscription: None,
            operation: json!({}),
            asked: String::new(),
            starting: false,
            awaited: -1,
            request: 0,
            refusal: String::new(),
            followed: false,
            last: 0,
            known: None,
            confirm_operation: String::new(),
            confirm_flags: json!({}),
            confirm_text: String::new(),
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
                        s.open_page(engine);
                    } else {
                        s.close_page(engine);
                    }
                }
            });
        });
        self.open = self
            .bridge
            .published(engine, "route")
            .is_some_and(|r| opened(&r));
        if self.open {
            self.open_page(engine);
        }
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active {
            return false;
        }
        match action {
            "sandboxSettings.refresh" => self.read(engine),
            "sandboxSettings.run" => {
                let operation = payload
                    .get("operation")
                    .and_then(Json::as_str)
                    .unwrap_or("")
                    .to_owned();
                // Only what the status offers, on the page, while nothing
                // runs and this session may.
                if self.open
                    && self.offered(&operation)
                    && self.status.get("canManage").and_then(Json::as_bool) == Some(true)
                    && !self.busy()
                {
                    self.run(engine, &operation, json!({}));
                }
            }
            "sandboxSettings.confirm" => {
                // As a press of an action: not while one runs (another
                // device may have started one since the page asked). The
                // question stays, to confirm once that run ends.
                if !self.confirm_operation.is_empty() && !self.busy() {
                    let operation = std::mem::take(&mut self.confirm_operation);
                    let flags = std::mem::replace(&mut self.confirm_flags, json!({}));
                    self.confirm_text.clear();
                    self.run(engine, &operation, flags);
                }
            }
            "sandboxSettings.cancel" => {
                self.clear_confirm();
                self.publish(engine);
            }
            _ => return false,
        }
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

fn running_label(operation: &str) -> &str {
    match operation {
        "install" => "Installing OpenShell…",
        "check" => "Checking OpenShell…",
        "rotate" => "Replacing OpenShell's certificates…",
        "uninstall" => "Removing OpenShell…",
        _ => "",
    }
}

fn reviews(count: usize) -> String {
    if count == 1 {
        "1 review".into()
    } else {
        format!("{count} reviews")
    }
}

fn or_null(text: &str) -> Json {
    if text.is_empty() {
        Json::Null
    } else {
        json!(text)
    }
}

/// A frame's or reply's run number: 0 before any run, -1 before any frame.
fn run_of(state: &Json) -> i64 {
    match state.as_object() {
        Some(object) if !object.is_empty() => state.get("run").and_then(Json::as_i64).unwrap_or(0),
        _ => -1,
    }
}

fn field<'a>(value: &'a Json, key: &str) -> &'a str {
    value.get(key).and_then(Json::as_str).unwrap_or("")
}

fn flag(value: &Json, key: &str) -> bool {
    value.get(key).and_then(Json::as_bool) == Some(true)
}

impl SandboxSettings {
    // What the page shows of an operation comes from the shape's first
    // frame; the last status stands until the read asked for here lands.
    fn open_page(&mut self, engine: &Engine) {
        self.operation = json!({});
        self.asked.clear();
        self.starting = false;
        self.awaited = -1;
        self.refusal.clear();
        self.followed = false;
        self.known = None;
        self.clear_confirm();
        if let Some(id) = self.subscription.take() {
            self.mc.unsubscribe(id);
        }
        let me = self.me.clone();
        self.subscription = Some(self.mc.subscribe(
            json!({"type": "openShell", "environment": self.mc.environment()}),
            Box::new(move |engine, frame| {
                let frame = Json::Object(frame.clone());
                if field(&frame, "t") != "openShell" {
                    return;
                }
                let next = frame.get("operation").cloned().unwrap_or_else(|| json!({}));
                me.run(engine, |s, engine| s.follow(engine, &next));
            }),
            None,
        ));
        self.read(engine);
    }

    // What this page asked for is forgotten: an outcome that lands while it
    // is closed is not asked about when it opens again, and a reply that
    // lands after it reopens touches nothing.
    fn close_page(&mut self, engine: &Engine) {
        if let Some(id) = self.subscription.take() {
            self.mc.unsubscribe(id);
        }
        self.request += 1;
        self.asked.clear();
        self.starting = false;
        self.awaited = -1;
        self.refusal.clear();
        self.clear_confirm();
        self.publish(engine);
    }

    fn busy(&self) -> bool {
        self.starting || flag(&self.operation, "running")
    }

    fn offered(&self, operation: &str) -> bool {
        self.status
            .get("actions")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
            .any(|value| field(value, "operation") == operation)
    }

    fn clear_confirm(&mut self) {
        self.confirm_operation.clear();
        self.confirm_flags = json!({});
        self.confirm_text.clear();
    }

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

    fn run(&mut self, engine: &Engine, operation: &str, flags: Json) {
        self.asked = operation.to_owned();
        self.starting = true;
        self.awaited = -1;
        self.refusal.clear();
        self.clear_confirm();
        let mut payload = flags;
        if !payload.is_object() {
            payload = json!({});
        }
        payload["operation"] = json!(operation);
        self.request += 1;
        let request = self.request;
        let me = self.me.clone();
        self.mc.call(
            &self.mc.environment(),
            "server.runOpenShellOperation",
            payload,
            Box::new(move |engine: &Engine, result| {
                me.run(engine, |s, engine| {
                    // Only the latest press on this opening of the page: one
                    // from before the page closed, or before a later press,
                    // is forgotten.
                    if request != s.request {
                        return;
                    }
                    match result {
                        Ok(result) => {
                            // The reply names the run; a frame of it that
                            // came first settles it now.
                            if !s.starting {
                                return;
                            }
                            s.awaited = run_of(&result);
                            if run_of(&s.operation.clone()) >= s.awaited {
                                let current = s.operation.clone();
                                s.settle(engine, &current, false);
                            }
                        }
                        Err(error) => {
                            s.starting = false;
                            s.asked.clear();
                            s.refusal = if error.message.is_empty() {
                                "The MC did not say why.".into()
                            } else {
                                error.message
                            };
                            s.publish(engine);
                        }
                    }
                });
            }),
        );
        self.publish(engine);
    }

    // The openShell shape: the operation running or last run on the MC.
    fn follow(&mut self, engine: &Engine, next: &Json) {
        // The MC sends a subscription's frames in order, and the first after
        // a reconnect is its state then, so a number below the last frame's
        // is from an MC whose clock went back across a restart. The old MC's
        // numbers then say nothing of the new one's runs.
        let number = run_of(next);
        let back = self.followed && number < self.last;
        if back {
            self.known = None;
        }
        if !self.followed && !flag(next, "running") {
            self.known = Some(number);
        }
        self.followed = true;
        self.last = number;
        // The actions stay off from a run until its reply has named it and a
        // frame of it (or a later run) has landed: a second press in between
        // would be refused as busy, and that refusal would forget what this
        // page asked for. A frame from before the run (the shape's first,
        // another device's last) is shown, but neither reopens the actions
        // nor answers the run. Whichever of the reply and the frame lands
        // second settles it, so a run that ended while the connection was
        // down settles on the first frame after it.
        if self.starting && !back && (self.awaited < 0 || number < self.awaited) {
            self.operation = next.clone();
            if !self.reread(engine, next, false) {
                self.publish(engine);
            }
            return;
        }
        self.settle(engine, next, back);
    }

    // What is installed may have changed once a run ended: the status is
    // read again for each run seen ended, once, whether or not this page saw
    // it run (it may have ended on another device while the connection was
    // down), and for a run this page saw going that went with a restart
    // (`ended`), and when a frame's number went back across a restart
    // (`back`, through `settle`): what that MC has installed may differ from
    // what the one before it said, run or no run seen going.
    fn reread(&mut self, engine: &Engine, next: &Json, ended: bool) -> bool {
        let number = run_of(next);
        if !self.open
            || flag(next, "running")
            || self.known == Some(number)
            || (field(next, "operation").is_empty() && !ended)
        {
            return false;
        }
        self.known = Some(number);
        self.read(engine);
        true
    }

    fn settle(&mut self, engine: &Engine, next: &Json, back: bool) {
        let operation = field(next, "operation").to_owned();
        let running = flag(next, "running");
        let ended = self.busy() && !running;
        self.operation = next.clone();
        self.starting = false;
        let result = next.get("result").cloned().unwrap_or(Json::Null);
        if !running
            && result.is_object()
            && !self.asked.is_empty()
            && self.asked == operation
            && run_of(next) == self.awaited
        {
            self.asked.clear();
            self.answer(&operation, &result);
        } else if !self.asked.is_empty()
            && self.awaited >= 0
            && (back || run_of(next) > self.awaited)
        {
            // A frame numbered above the run's is not it: with no operation
            // it is from an MC that has run none since it started, its
            // number is when it started, and above the run's number it
            // started after the run did — it restarted, and the run's
            // outcome went with the old one; with an operation it is a later
            // run (this page was away while its own ended and another
            // device's followed), and its own run's outcome went unseen
            // either way. Whether the run's work got done is unknown, so
            // the words promise no retry.
            self.asked.clear();
            self.refusal =
                "The MC lost track of the run; check the status before trying again.".into();
        }
        if !self.reread(engine, next, ended || back) {
            self.publish(engine);
        }
    }

    // An outcome this page asked for may need the user's yes to go on.
    fn answer(&mut self, operation: &str, result: &Json) {
        if flag(result, "ok") {
            return;
        }
        let code = field(result, "code");
        let message = field(result, "message");
        let drain = result.get("drain").and_then(Json::as_array);
        if (code == "sandboxes-running" || code == "sandboxes-changed")
            && drain.is_some_and(|drain| !drain.is_empty())
        {
            // The yes names what it was asked about: the MC deletes no other
            // review.
            let drain = result.get("drain").cloned().unwrap_or_else(|| json!([]));
            let count = drain.as_array().map_or(0, Vec::len);
            self.confirm_operation = operation.to_owned();
            self.confirm_flags = json!({"drain": drain});
            self.confirm_text = format!("Stop {} and go ahead? {message}", reviews(count));
        } else if code == "sandboxes-unknown" {
            self.confirm_operation = operation.to_owned();
            self.confirm_flags = json!({"force": true});
            self.confirm_text = format!("Go ahead anyway? {message}");
        }
    }

    fn operation_state(&self) -> Json {
        let operation = field(&self.operation, "operation");
        if operation.is_empty() {
            return Json::Null;
        }
        let steps: Vec<Json> = self
            .operation
            .get("steps")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
            .map(|step| json!(step.as_str().unwrap_or("")))
            .collect();
        let running = flag(&self.operation, "running");
        let result = self.operation.get("result");
        json!({"operation": operation,
        "running": running,
        "label": if running { running_label(operation) } else { "" },
        "steps": steps,
        "result": if !running && result.is_some_and(Json::is_object) {
            let result = result.cloned().unwrap_or(Json::Null);
            json!({"ok": flag(&result, "ok"), "message": field(&result, "message")})
        } else {
            Json::Null
        }})
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let status_field = |key: &str| field(&self.status, key);
        let status_flag = |key: &str| flag(&self.status, key);
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
        let actions: Vec<Json> = self
            .status
            .get("actions")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
            .map(|a| {
                json!({"operation": a.get("operation").and_then(Json::as_str).unwrap_or(""),
                       "label": a.get("label").and_then(Json::as_str).unwrap_or("")})
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
        } else if !status_flag("supported") {
            (
                "unsupported",
                "Review sandboxes can't run on this machine.",
                "Code reviews run without a sandbox here.".to_owned(),
            )
        } else if !status_flag("ready") {
            (
                "attention",
                "Review sandboxes can't run here yet.",
                format!(
                    "OpenShell {} is the version this MC pins.",
                    status_field("pinnedVersion")
                ),
            )
        } else {
            let mode = mode_name(status_field("mode"));
            let version = status_field("version");
            let detail = if version.is_empty() {
                format!("OpenShell, {mode}.")
            } else {
                format!("OpenShell {version}, {mode}.")
            };
            ("ready", "Review sandboxes can run here.", detail)
        };
        let can_manage = status_flag("canManage");
        self.bridge.publish(
            engine,
            "sandboxSettings",
            json!({"loading": self.loading, "state": state, "summary": summary,
            "detail": detail, "error": or_null(&self.error),
            "problems": problems, "actions": actions,
            "canManage": can_manage,
            "manageReason": if can_manage {
                Json::Null
            } else {
                or_null(status_field("manageReason"))
            },
            "busy": self.busy(),
            "operation": self.operation_state(),
            "refusal": or_null(&self.refusal),
            "confirm": if self.confirm_operation.is_empty() {
                Json::Null
            } else {
                json!({"text": self.confirm_text})
            }}),
        );
    }
}
