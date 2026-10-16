//! `toasts`, desktop-qt's ToastController: the shell's own toasts.
//! Controllers call [`Toasts::show`] (through [`crate::controller::with`]);
//! the Notifications brick renders `toasts`: `{items, expanded}`, items
//! newest first, each `{id, type, title, description, updateKey, actions}`.
//! Dismiss and action clicks come back by id. No toast is dropped for lack
//! of room: the brick stacks them, and `expanded` (the pointer over the
//! stack, a tap on a phone) spreads them out and holds every toast's time.
//!
//! Time is the engine's clock, so a test's virtual clock drives it; the
//! next deadline is one `Engine::call_at`.

use std::rc::Rc;
use std::time::Duration;

use ljos::prelude::Engine;
use ljos_runtime::{Time, TimerId};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init, Me};
use crate::json::Json;

/// How long a toast shows unless told otherwise.
pub const DEFAULT_TIMEOUT_MS: i64 = 5000;

/// What an action does; it runs once no controller is running, so it may
/// call this one again (show a toast of its own).
pub type Run = Rc<dyn Fn(&Engine)>;
pub type ClosedByUser = Rc<dyn Fn(&Engine, &str)>;

/// A toast's button. Clicking it dismisses the toast first, unless it
/// `keeps_toast` (a clone's Cancel and Retry, whose toast changes with what
/// they start).
#[derive(Clone, Default)]
pub struct Action {
    pub label: String,
    pub run: Option<Run>,
    pub keeps_toast: bool,
    /// What kind of change it takes back ("Settled", "Snoozed"):
    /// consecutive toasts of one group are undone together.
    pub group: String,
}

impl Action {
    pub fn new(label: impl Into<String>, run: impl Fn(&Engine) + 'static) -> Action {
        Action {
            label: label.into(),
            run: Some(Rc::new(run)),
            keeps_toast: false,
            group: String::new(),
        }
    }

    pub fn keeping_toast(mut self) -> Action {
        self.keeps_toast = true;
        self
    }

    pub fn in_group(mut self, group: impl Into<String>) -> Action {
        self.group = group.into();
        self
    }
}

struct Toast {
    id: String,
    kind: String,
    title: String,
    description: String,
    actions: Vec<Action>,
    /// Set while its time runs; while the stack is expanded the time left
    /// sits in `remaining` instead.
    deadline: Option<Time>,
    remaining: Duration,
    revision: u64,
    /// The changes its Undo takes back ([`Toasts::show_undo`]); one again
    /// once `replace` gives it other actions.
    count: u32,
}

pub struct Toasts {
    bridge: Bridge,
    me: Me<Toasts>,
    toasts: Vec<Toast>,
    timer: Option<TimerId>,
    next_id: u64,
    expanded: bool,
    closed_by_user: Vec<ClosedByUser>,
}

impl Controller for Toasts {
    fn new(init: Init<'_, Self>) -> Self {
        Toasts {
            bridge: init.bridge,
            me: init.me,
            toasts: Vec::new(),
            timer: None,
            next_id: 1,
            expanded: false,
            closed_by_user: Vec::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        let text = |key: &str| {
            payload
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        match action {
            "notification.expand" => {
                let expanded = payload
                    .get("expanded")
                    .and_then(Json::as_bool)
                    .unwrap_or(false);
                self.set_expanded(engine, expanded);
                true
            }
            "notification.action" => {
                let index = usize::from(text("actionId") == "secondary");
                self.click(engine, &text("id"), index);
                // A click on an action the toast no longer offers (replace()
                // changed them under the pointer) leaves it be.
                true
            }
            "notification.dismiss" => {
                let id = text("id");
                let closed = self.toasts.iter().any(|t| t.id == id);
                self.dismiss(engine, &id);
                if closed {
                    for f in self.closed_by_user.clone() {
                        let id = id.clone();
                        self.bridge.defer(engine, move |engine| f(engine, &id));
                    }
                }
                true
            }
            _ => false,
        }
    }
}

impl Toasts {
    /// Shows a toast of `kind` (error, warning, success, info, loading) for
    /// `timeout_ms` (0 keeps it until dismissed); returns its id.
    pub fn show(
        &mut self,
        engine: &Engine,
        kind: &str,
        title: &str,
        description: &str,
        action: Option<Action>,
        timeout_ms: i64,
    ) -> String {
        self.show_actions(
            engine,
            kind,
            title,
            description,
            action.into_iter().collect(),
            timeout_ms,
        )
    }

    /// A toast with a primary action and, second, a lesser one ("Retry" and
    /// "Remove project"). A third has no button.
    pub fn show_actions(
        &mut self,
        engine: &Engine,
        kind: &str,
        title: &str,
        description: &str,
        actions: Vec<Action>,
        timeout_ms: i64,
    ) -> String {
        let id = format!("native:{}", self.next_id);
        self.next_id += 1;
        let mut toast = Toast {
            id: id.clone(),
            kind: kind.into(),
            title: title.into(),
            description: description.into(),
            actions,
            deadline: None,
            remaining: Duration::ZERO,
            revision: 0,
            count: 1,
        };
        self.start_time(engine, &mut toast, timeout_ms);
        self.toasts.insert(0, toast);
        self.publish(engine);
        self.schedule(engine);
        id
    }

    /// The notice of a change the user can take back ("Settled", "Snoozed":
    /// `group`, which `run_action("Undo")` undoes together). A change
    /// straight after another of its group joins that toast, which then
    /// reads "Settled 2 threads" and undoes both; `title` is what one change
    /// reads. The description names the undo shortcut.
    pub fn show_undo(&mut self, engine: &Engine, group: &str, title: &str, undo: Run) -> String {
        let hint = undo_hint(engine);
        let description = if hint.is_empty() {
            String::new()
        } else {
            format!("{hint} to undo")
        };
        let reading = |count: u32| {
            if count == 1 {
                title.to_owned()
            } else {
                format!("{group} {count} threads")
            }
        };
        // The action as the sidebar and the menu build it, over the earlier
        // one it joins.
        let joined = |earlier: Option<Run>| Action {
            label: "Undo".into(),
            run: Some(Rc::new({
                let undo = undo.clone();
                move |engine: &Engine| {
                    undo(engine);
                    if let Some(earlier) = &earlier {
                        earlier(engine);
                    }
                }
            })),
            keeps_toast: false,
            group: group.into(),
        };
        if let Some(newest) = self.toasts.first()
            && let Some(first) = newest.actions.first()
            && first.label == "Undo"
            && first.group == group
        {
            let count = newest.count + 1;
            let id = newest.id.clone();
            let kind = newest.kind.clone();
            let earlier = first.run.clone();
            self.replace(
                engine,
                &id,
                &kind,
                &reading(count),
                &description,
                vec![joined(earlier)],
                DEFAULT_TIMEOUT_MS,
            );
            if let Some(newest) = self.toasts.first_mut() {
                newest.count = count;
            }
            return id;
        }
        self.show(
            engine,
            "success",
            &reading(1),
            &description,
            Some(joined(None)),
            DEFAULT_TIMEOUT_MS,
        )
    }

    /// An error toast, with "An error occurred." for an empty reason.
    pub fn error(&mut self, engine: &Engine, title: &str, description: &str) -> String {
        let description = if description.is_empty() {
            "An error occurred."
        } else {
            description
        };
        self.show(
            engine,
            "error",
            title,
            description,
            None,
            DEFAULT_TIMEOUT_MS,
        )
    }

    pub fn dismiss(&mut self, engine: &Engine, id: &str) {
        let before = self.toasts.len();
        self.toasts.retain(|t| t.id != id);
        if self.toasts.len() == before {
            return;
        }
        self.publish(engine);
        self.schedule(engine);
    }

    /// Changes a shown toast's text in place (a running action's stage);
    /// false once it is gone.
    pub fn update(&mut self, engine: &Engine, id: &str, title: &str, description: &str) -> bool {
        let Some(toast) = self.toasts.iter_mut().find(|t| t.id == id) else {
            return false;
        };
        if toast.title == title && toast.description == description {
            return true;
        }
        toast.title = title.into();
        toast.description = description.into();
        toast.revision += 1;
        self.publish(engine);
        true
    }

    /// Turns a shown toast into another in place (a clone's running toast
    /// into its success or failure), its time starting afresh; false once it
    /// is gone.
    #[allow(clippy::too_many_arguments)]
    pub fn replace(
        &mut self,
        engine: &Engine,
        id: &str,
        kind: &str,
        title: &str,
        description: &str,
        actions: Vec<Action>,
        timeout_ms: i64,
    ) -> bool {
        let Some(index) = self.toasts.iter().position(|t| t.id == id) else {
            return false;
        };
        let mut toast = self.toasts.remove(index);
        toast.kind = kind.into();
        toast.title = title.into();
        toast.description = description.into();
        toast.actions = actions;
        toast.count = 1;
        self.start_time(engine, &mut toast, timeout_ms);
        toast.revision += 1;
        self.toasts.insert(index, toast);
        self.publish(engine);
        self.schedule(engine);
        true
    }

    /// Runs the action of the newest toast offering `label` (the undo
    /// shortcut's "Undo"), as clicking it would; false when none does. The
    /// toasts straight after it offering the same action for the same group
    /// run with it.
    pub fn run_action(&mut self, engine: &Engine, label: &str) -> bool {
        let mut chosen: Vec<(String, usize)> = Vec::new();
        let mut group = String::new();
        for toast in &self.toasts {
            // Of the two actions a toast shows; a third has no button.
            let found = toast.actions.iter().take(2).position(|a| a.label == label);
            let Some(found) = found else {
                if chosen.is_empty() {
                    continue;
                }
                break;
            };
            let its = &toast.actions[found].group;
            if !chosen.is_empty() && (group.is_empty() || *its != group) {
                break;
            }
            group = its.clone();
            chosen.push((toast.id.clone(), found));
        }
        for (id, index) in &chosen {
            self.click(engine, id, *index);
        }
        !chosen.is_empty()
    }

    /// Drops the toasts whose time is up; the timer calls it at the next
    /// deadline.
    pub fn expire(&mut self, engine: &Engine) {
        let now = engine.now();
        let before = self.toasts.len();
        self.toasts
            .retain(|t| t.deadline.is_none_or(|deadline| deadline > now));
        if self.toasts.len() != before {
            self.publish(engine);
        }
        self.schedule(engine);
    }

    /// Spreads the stack out and holds every toast's remaining time until it
    /// collapses again (`notification.expand` from the brick). It collapses
    /// by itself once the last toast goes.
    pub fn set_expanded(&mut self, engine: &Engine, expanded: bool) {
        if expanded == self.expanded {
            return;
        }
        if expanded {
            // Gone before it holds: a toast already due does not linger.
            self.expire(engine);
            if self.toasts.is_empty() {
                return;
            }
        }
        self.expanded = expanded;
        let now = engine.now();
        for toast in &mut self.toasts {
            if expanded && let Some(deadline) = toast.deadline.take() {
                toast.remaining = deadline - now;
            } else if !expanded && !toast.remaining.is_zero() {
                toast.deadline = Some(now + toast.remaining);
                toast.remaining = Duration::ZERO;
            }
        }
        self.publish(engine);
        self.schedule(engine);
    }

    pub fn expanded(&self) -> bool {
        self.expanded
    }

    /// Calls `f` with the id of each toast the user closes, rather than it
    /// timing out or an action being chosen.
    pub fn on_closed_by_user(&mut self, f: impl Fn(&Engine, &str) + 'static) {
        self.closed_by_user.push(Rc::new(f));
    }

    /// The action `index` of toast `id` chosen: dismissed first (the action
    /// may show a toast of its own), then run once this one returns.
    fn click(&mut self, engine: &Engine, id: &str, index: usize) {
        let Some(chosen) = self
            .toasts
            .iter()
            .find(|t| t.id == id)
            .and_then(|t| t.actions.get(index))
            .cloned()
        else {
            return;
        };
        if !chosen.keeps_toast {
            self.dismiss(engine, id);
        }
        if let Some(run) = chosen.run {
            self.bridge.defer(engine, move |engine| run(engine));
        }
    }

    fn start_time(&self, engine: &Engine, toast: &mut Toast, timeout_ms: i64) {
        toast.deadline = None;
        toast.remaining = Duration::ZERO;
        let Ok(ms) = u64::try_from(timeout_ms) else {
            return;
        };
        if ms == 0 {
            return;
        }
        let timeout = Duration::from_millis(ms);
        if self.expanded {
            toast.remaining = timeout;
        } else {
            toast.deadline = Some(engine.now() + timeout);
        }
    }

    fn schedule(&mut self, engine: &Engine) {
        if let Some(timer) = self.timer.take() {
            engine.cancel_call(timer);
        }
        let Some(next) = self.toasts.iter().filter_map(|t| t.deadline).min() else {
            return;
        };
        let me = self.me.clone();
        self.timer = Some(engine.call_at(next, move |engine| {
            me.run(engine, |toasts, engine| {
                toasts.timer = None;
                toasts.expire(engine);
            });
        }));
    }

    fn publish(&mut self, engine: &Engine) {
        // An empty stack has nothing to hold open.
        if self.toasts.is_empty() {
            self.expanded = false;
        }
        let items: Vec<Json> = self
            .toasts
            .iter()
            .map(|toast| {
                // The lesser action sits before the primary one.
                let actions: Vec<Json> = toast
                    .actions
                    .iter()
                    .take(2)
                    .enumerate()
                    .rev()
                    .map(|(index, action)| {
                        json!({
                            "id": if index == 0 { "primary" } else { "secondary" },
                            "label": action.label,
                            "primary": index == 0,
                        })
                    })
                    .collect();
                json!({
                    "id": toast.id,
                    "type": toast.kind,
                    "title": toast.title,
                    "description": if toast.description.is_empty() { Json::Null } else { json!(toast.description) },
                    "updateKey": toast.revision,
                    "actions": actions,
                })
            })
            .collect();
        self.bridge.publish(
            engine,
            "toasts",
            json!({"items": items, "expanded": self.expanded}),
        );
    }
}

/// The undo shortcut's label, as the toast names it.
fn undo_hint(_engine: &Engine) -> String {
    String::new()
}
