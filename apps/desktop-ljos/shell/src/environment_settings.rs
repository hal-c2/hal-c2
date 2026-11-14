//! A setting across the selected environments, desktop-qt's
//! EnvironmentSettings: the settings documents of a few environments, read as
//! one value that may be mixed, and changed on each of them.
//!
//! Each target's `config` shape brings its settings document (`config`, then
//! `config.settings`). A reading takes the first target's value as the one to
//! show and says whether any other target differs. A change applies an edit to
//! every target that has answered, each read and written at its own version
//! (`hal-c2.readSettings` / `hal-c2.writeSettings`, a stale write edited
//! again), and reports which targets could not save, so one failing machine
//! does not hide the others' saves.
//!
//! A controller owns one and listens for what arrives:
//!
//! ```ignore
//! let scope = EnvironmentSettings::new(mc.clone());
//! scope.on_changed({ let me = me.clone(); move |engine| me.run(engine, |c, e| c.publish(e)) });
//! if scope.set_targets(&ids) { self.publish(engine) }   // no listener call
//! let interval = scope.read_path("backgroundActivity.profile");
//! ```
//!
//! `set_targets` never calls the listener: the caller is usually inside its
//! own controller, which `Me::run` could not borrow again, so it publishes
//! itself when the call says something changed. Likewise `change` answers at
//! once, as an `Err`, when no target can be written, and calls `done` only
//! later, from an MC delivery.
//!
//! A project scope is an edit of `projectSettingsOverrides[<project>]` on each
//! target, and a pick that reads it; the model itself knows only documents.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::rc::{Rc, Weak};

use ljos::prelude::Engine;

use crate::json::Json;
use crate::mc::{Frame, Mc, McError, SubId};

/// How often a write refused as stale is edited again before giving up.
const STALE_RETRIES: u32 = 3;

/// The new document from a target's current one and its environment id.
pub type Edit = Rc<dyn Fn(Json, &str) -> Json>;
/// What a pick reads from a target's document; `None` is undefined.
pub type Pick<'a> = &'a dyn Fn(&Json, &str) -> Option<Json>;

/// How a `change` ended.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Outcome {
    /// The targets that could not save, with why, by environment.
    pub failed: BTreeMap<String, String>,
    /// How many targets saved (or had nothing to change).
    pub saved: usize,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Reading {
    /// The first answering target's value; `None` when none has answered or
    /// the setting is not set there.
    pub value: Option<Json>,
    /// Another answering target holds something else.
    pub mixed: bool,
    /// How many targets have answered.
    pub known: usize,
}

struct Target {
    subscription: SubId,
    settings: Option<Json>,
}

#[derive(Default)]
struct State {
    targets: Vec<String>,
    followed: HashMap<String, Target>,
}

type Done = Box<dyn FnOnce(&Engine, Outcome)>;
type ChangedListener = Rc<dyn Fn(&Engine)>;
type FrameListener = Rc<dyn Fn(&Engine, &str, &Frame)>;

struct Inner {
    mc: Rc<dyn Mc>,
    state: RefCell<State>,
    on_changed: RefCell<Option<ChangedListener>>,
    on_frame: RefCell<Option<FrameListener>>,
}

pub struct EnvironmentSettings(Rc<Inner>);

impl EnvironmentSettings {
    pub fn new(mc: Rc<dyn Mc>) -> EnvironmentSettings {
        EnvironmentSettings(Rc::new(Inner {
            mc,
            state: RefCell::default(),
            on_changed: RefCell::default(),
            on_frame: RefCell::default(),
        }))
    }

    /// A target's settings arrived or changed. Not called for `set_targets`.
    pub fn on_changed(&self, f: impl Fn(&Engine) + 'static) {
        *self.0.on_changed.borrow_mut() = Some(Rc::new(f));
    }

    /// Every frame a target's `config` shape sends, settings or not
    /// (providers, themes), for owners that need more of the environment's
    /// config. Called before `on_changed` for the same frame.
    pub fn on_frame(&self, f: impl Fn(&Engine, &str, &Frame) + 'static) {
        *self.0.on_frame.borrow_mut() = Some(Rc::new(f));
    }

    /// Follows these environments' settings, and nothing else; in the order a
    /// reading prefers them. True when the targets changed.
    pub fn set_targets(&self, environment_ids: &[String]) -> bool {
        let mut targets: Vec<String> = Vec::new();
        for id in environment_ids {
            if !id.is_empty() && !targets.contains(id) {
                targets.push(id.clone());
            }
        }
        let mut state = self.0.state.borrow_mut();
        if targets == state.targets {
            return false;
        }
        state.targets = targets.clone();
        let dropped: Vec<String> = state
            .followed
            .keys()
            .filter(|id| !targets.contains(id))
            .cloned()
            .collect();
        for id in dropped {
            if let Some(target) = state.followed.remove(&id) {
                self.0.mc.unsubscribe(target.subscription);
            }
        }
        for id in targets {
            if state.followed.contains_key(&id) {
                continue;
            }
            let subscription = self.follow(&id);
            state.followed.insert(
                id,
                Target {
                    subscription,
                    settings: None,
                },
            );
        }
        true
    }

    fn follow(&self, environment_id: &str) -> SubId {
        let inner = Rc::downgrade(&self.0);
        let id = environment_id.to_owned();
        let shape = serde_json::json!({ "type": "config", "environment": environment_id });
        self.0.mc.subscribe(
            shape,
            Box::new(move |engine, frame| {
                if let Some(inner) = inner.upgrade() {
                    inner.receive(engine, &id, frame);
                }
            }),
            None,
        )
    }

    pub fn targets(&self) -> Vec<String> {
        self.0.state.borrow().targets.clone()
    }

    /// Whether every target has answered.
    pub fn ready(&self) -> bool {
        let state = self.0.state.borrow();
        state
            .targets
            .iter()
            .all(|id| state.followed.get(id).is_some_and(|t| t.settings.is_some()))
    }

    pub fn settings(&self, environment_id: &str) -> Option<Json> {
        let state = self.0.state.borrow();
        state.followed.get(environment_id)?.settings.clone()
    }

    pub fn read(&self, pick: Pick) -> Reading {
        let state = self.0.state.borrow();
        let mut reading = Reading::default();
        for id in &state.targets {
            let Some(settings) = state.followed.get(id).and_then(|t| t.settings.as_ref()) else {
                continue;
            };
            let value = pick(settings, id);
            if reading.known == 0 {
                reading.value = value;
            } else if !same_option(&value, &reading.value) {
                reading.mixed = true;
            }
            reading.known += 1;
        }
        reading
    }

    /// A value by dotted path, as `Settings.value` reads one.
    pub fn read_path(&self, path: &str) -> Reading {
        self.read(&|settings, _| at(settings, path).cloned())
    }

    /// Applies `edit` on every target; one that has not answered counts as
    /// failed ("Not connected."). An edit that changes nothing writes nothing.
    /// `done` runs once every target has finished, from an MC delivery; when
    /// there is nothing to wait for the outcome is the `Err` and `done` is
    /// dropped unused.
    pub fn change(
        &self,
        edit: Edit,
        done: impl FnOnce(&Engine, Outcome) + 'static,
    ) -> Result<(), Outcome> {
        let mut outcome = Outcome::default();
        let mut reachable = Vec::new();
        {
            let state = self.0.state.borrow();
            for id in &state.targets {
                if state.followed.get(id).is_some_and(|t| t.settings.is_some()) {
                    reachable.push(id.clone());
                } else {
                    outcome.failed.insert(id.clone(), "Not connected.".into());
                }
            }
        }
        if reachable.is_empty() {
            return Err(outcome);
        }
        struct Pending {
            waiting: usize,
            outcome: Outcome,
            done: Option<Done>,
        }
        let pending = Rc::new(RefCell::new(Pending {
            waiting: reachable.len(),
            outcome,
            done: Some(Box::new(done)),
        }));
        for id in reachable {
            let pending = pending.clone();
            let environment_id = id.clone();
            attempt(
                Rc::downgrade(&self.0),
                id,
                edit.clone(),
                STALE_RETRIES,
                Rc::new(move |engine, error| {
                    let finished = {
                        let mut p = pending.borrow_mut();
                        match &error {
                            Some(error) => {
                                p.outcome
                                    .failed
                                    .insert(environment_id.clone(), error.clone());
                            }
                            None => p.outcome.saved += 1,
                        }
                        p.waiting -= 1;
                        if p.waiting == 0 {
                            p.done
                                .take()
                                .map(|done| (done, std::mem::take(&mut p.outcome)))
                        } else {
                            None
                        }
                    };
                    if let Some((done, outcome)) = finished {
                        done(engine, outcome);
                    }
                }),
            );
        }
        Ok(())
    }
}

impl Drop for EnvironmentSettings {
    fn drop(&mut self) {
        for target in self.0.state.borrow().followed.values() {
            self.0.mc.unsubscribe(target.subscription);
        }
    }
}

impl Inner {
    fn receive(&self, engine: &Engine, environment_id: &str, frame: &Frame) {
        let settings = match frame.get("t").and_then(Json::as_str) {
            Some("config") => frame
                .get("config")
                .and_then(|c| c.get("settings"))
                .filter(|s| s.is_object())
                .cloned(),
            Some("config.settings") => Some(
                frame
                    .get("settings")
                    .filter(|s| s.is_object())
                    .cloned()
                    .unwrap_or_else(|| Json::Object(Default::default())),
            ),
            _ => None,
        };
        let changed = {
            let mut state = self.state.borrow_mut();
            let Some(target) = state.followed.get_mut(environment_id) else {
                return;
            };
            let changed = settings
                .as_ref()
                .is_some_and(|s| !target.settings.as_ref().is_some_and(|t| same_json(t, s)));
            if changed {
                target.settings = settings;
            }
            changed
        };
        // The listeners may reach back in (read, set_targets), so no borrow is held.
        let on_frame = self.on_frame.borrow().clone();
        if let Some(on_frame) = on_frame {
            on_frame(engine, environment_id, frame);
        }
        if changed {
            let on_changed = self.on_changed.borrow().clone();
            if let Some(on_changed) = on_changed {
                on_changed(engine);
            }
        }
    }
}

type Finish = Rc<dyn Fn(&Engine, Option<String>)>;

/// One target's read, edit and write; a stale write reads and edits again.
fn attempt(inner: Weak<Inner>, environment_id: String, edit: Edit, retries: u32, finish: Finish) {
    let Some(strong) = inner.upgrade() else {
        return;
    };
    let mc = strong.mc.clone();
    drop(strong);
    let id = environment_id.clone();
    let next_mc = mc.clone();
    mc.call(
        &environment_id,
        "hal-c2.readSettings",
        serde_json::json!({}),
        Box::new(move |engine, result| {
            if inner.upgrade().is_none() {
                return;
            }
            let read = match result {
                Ok(read) => read,
                Err(error) => return finish(engine, Some(error.message)),
            };
            let settings = read
                .get("settings")
                .filter(|s| s.is_object())
                .cloned()
                .unwrap_or_else(|| Json::Object(Default::default()));
            let next = edit(settings.clone(), &id);
            if same_json(&next, &settings) {
                return finish(engine, None);
            }
            let version = read.get("version").cloned().unwrap_or(Json::Null);
            let payload = serde_json::json!({ "settings": next, "version": version });
            let retry_id = id.clone();
            next_mc.call(
                &id,
                "hal-c2.writeSettings",
                payload,
                Box::new(move |engine, result| {
                    if inner.upgrade().is_none() {
                        return;
                    }
                    match result {
                        Ok(_) => finish(engine, None),
                        Err(error) if retries > 0 && is_stale(&error) => {
                            attempt(inner, retry_id, edit, retries - 1, finish)
                        }
                        Err(error) => finish(engine, Some(error.message)),
                    }
                }),
            );
        }),
    );
}

fn is_stale(error: &McError) -> bool {
    error.detail.get("_tag").and_then(Json::as_str) == Some("StaleSettings")
}

/// A value by dotted path; `None` where a part is missing or not an object.
pub fn at<'a>(settings: &'a Json, path: &str) -> Option<&'a Json> {
    path.split('.')
        .try_fold(settings, |value, part| value.as_object()?.get(part))
}

/// `settings` with the dotted path set; `None` or null removes it.
pub fn with(settings: Json, path: &str, value: Option<Json>) -> Json {
    let mut map = match settings {
        Json::Object(map) => map,
        _ => Default::default(),
    };
    match path.split_once('.') {
        None => match value {
            None | Some(Json::Null) => {
                map.remove(path);
            }
            Some(value) => {
                map.insert(path.to_owned(), value);
            }
        },
        Some((head, rest)) => {
            let inner = map.remove(head).unwrap_or(Json::Null);
            map.insert(head.to_owned(), with(inner, rest, value));
        }
    }
    Json::Object(map)
}

/// JSON equality as QJsonValue has it: numbers by value, so `1` and `1.0`
/// are one setting.
pub fn same_json(a: &Json, b: &Json) -> bool {
    match (a, b) {
        (Json::Number(a), Json::Number(b)) => a.as_f64() == b.as_f64(),
        (Json::Array(a), Json::Array(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(a, b)| same_json(a, b))
        }
        (Json::Object(a), Json::Object(b)) => {
            a.len() == b.len()
                && a.iter()
                    .all(|(k, a)| b.get(k).is_some_and(|b| same_json(a, b)))
        }
        _ => a == b,
    }
}

/// [`same_json`] where a value may be undefined, which is not null.
pub fn same_option(a: &Option<Json>, b: &Option<Json>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => same_json(a, b),
        (None, None) => true,
        _ => false,
    }
}
