//! `providerUpdateNotice`, desktop-qt's ProviderUpdateNotice:
//! provider updates, as the shell tells of them.
//!
//! At launch, the enabled providers that are behind a latest release
//! they can use are offered in one "Update Available" toast, one per
//! driver. With one environment, Update runs `server.updateProvider`
//! for each the MC can update itself, a loading toast standing in
//! until the MC says how it went; Settings opens the Providers
//! section. With several environments (the cluster's, as the MC labels
//! them: a Windows machine and its WSL backend, say) the toast lists
//! one row per environment with what it can update, each with its own
//! Update, held back up to 30 s while an online environment's providers
//! have not arrived. Closing the toast dismisses that set of versions
//! for good (this device's
//! `dismissedProviderUpdateNotificationKeys`); a set is offered once
//! per run either way.
//!
//! Publishes `providerUpdates`: {notice}, the sidebar's notice of this
//! environment's updates ({key, tone, title, description,
//! dismissible}, or null); `providerUpdates.dismissNotice` dismisses
//! it and `providerUpdates.openNotice` opens the Providers settings.
//!
//! One per process: the toast shows in the window in use. The rules
//! are [`crate::provider_updates`]'.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use ljos::prelude::{Engine, TimerId};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{Navigation, PROVIDERS_SECTION, Route};
use crate::controllers::settings::Settings;
use crate::controllers::toasts::{Action, Row, Toasts};
use crate::environment_settings::EnvironmentSettings;
use crate::json::Json;
use crate::mc::Mc;
use crate::provider_updates as updates;
use crate::store;

const DISMISSED: &str = "dismissedProviderUpdateNotificationKeys";
/// How long "Provider updated" stays (PROVIDER_UPDATE_SUCCESS_VISIBLE_MS).
const SUCCESS_MS: i64 = 3000;
/// How long an offer waits for an environment still connecting.
pub const SETTLING_MS: i64 = 30_000;
const NOT_CONNECTED: &str = "This environment isn’t connected — try again once it reconnects.";

fn instance_of(provider: &Json) -> &str {
    provider["instanceId"].as_str().unwrap_or_default()
}

fn request(provider: &Json) -> Json {
    json!({"provider": provider["driver"], "instanceId": provider["instanceId"]})
}

/// The update the user started: which instances, until it is reported,
/// and the toast saying it runs.
struct Update {
    instance_ids: HashSet<String>,
    count: usize,
    toast_id: String,
}

/// The sequential `server.updateProvider` calls of one update.
struct Run {
    providers: Vec<Json>,
    next: usize,
    snapshots: Vec<Json>,
}

pub struct ProviderUpdateNotice {
    bridge: Bridge,
    me: Me<ProviderUpdateNotice>,
    mc: Rc<dyn Mc>,
    scope: Rc<EnvironmentSettings>,
    now: Rc<dyn Fn() -> DateTime<Utc>>,
    timer: Option<TimerId>,
    active: bool,
    hooked: bool,
    /// The version sets offered this run.
    seen: HashSet<String>,
    /// The prompt on screen and the versions it offers.
    prompt_id: String,
    prompt_key: String,
    update: Option<Update>,

    /// Other environments' providers, by environment, once they arrived.
    remote: HashMap<String, Vec<Json>>,
    /// The rows' prompt: the set it was opened for still the live one,
    /// whether the user started an update from it (it then stays as the
    /// set changes), when it opened, and how each environment's update went.
    rows_mode: bool,
    live_key: String,
    interacted: bool,
    opened_at: String,
    rows: updates::Rows,
    groups: Vec<updates::Group>,
    /// Since when an environment has been connecting.
    settling_since: Option<DateTime<Utc>>,

    sidebar: updates::Sidebar,
}

impl Controller for ProviderUpdateNotice {
    fn new(init: Init<'_, Self>) -> Self {
        let scope = Rc::new(EnvironmentSettings::new(init.mc.clone()));
        let me = init.me.clone();
        scope.on_frame(move |engine, environment_id, frame| {
            let providers = match frame.get("t").and_then(Json::as_str) {
                Some("config") => frame
                    .get("config")
                    .and_then(|config| config["providers"].as_array())
                    .cloned()
                    .unwrap_or_default(),
                Some("config.providers") => frame
                    .get("providers")
                    .and_then(Json::as_array)
                    .cloned()
                    .unwrap_or_default(),
                _ => return,
            };
            let environment_id = environment_id.to_owned();
            me.run(engine, move |c, engine| {
                c.remote.insert(environment_id, providers);
                c.evaluate(engine);
            });
        });
        ProviderUpdateNotice {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            scope,
            now: Rc::new(Utc::now),
            timer: None,
            active: false,
            hooked: false,
            seen: HashSet::new(),
            prompt_id: String::new(),
            prompt_key: String::new(),
            update: None,
            remote: HashMap::new(),
            rows_mode: false,
            live_key: String::new(),
            interacted: false,
            opened_at: String::new(),
            rows: updates::Rows::default(),
            groups: Vec::new(),
            settling_since: None,
            sidebar: updates::Sidebar::default(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if std::mem::replace(&mut self.active, true) {
            return;
        }
        let me = self.me.clone();
        Settings::of(engine).on_config_changed(move |engine| {
            me.run(engine, |c, engine| c.evaluate(engine));
        });
        let me = self.me.clone();
        store::on_changed(engine, move |engine: &Engine| {
            me.run(engine, |c, engine| c.evaluate(engine));
        });
        self.publish(engine);
        self.evaluate(engine);
    }

    fn attach(&mut self, engine: &Engine, _window: &crate::controller::Window) {
        self.evaluate(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, _payload: &Json) -> bool {
        match action {
            "providerUpdates.dismissNotice" => {
                if self.sidebar.dismiss((self.now)()) {
                    self.publish(engine);
                }
                self.schedule(engine);
                true
            }
            "providerUpdates.openNotice" => {
                self.open_settings(engine);
                true
            }
            _ => false,
        }
    }
}

fn providers_of(engine: &Engine) -> Vec<Json> {
    Settings::of(engine)
        .config()
        .get("providers")
        .and_then(Json::as_array)
        .cloned()
        .unwrap_or_default()
}

impl ProviderUpdateNotice {
    /// Tests pin the clock; the app uses the system's.
    pub fn set_clock(&mut self, now: impl Fn() -> DateTime<Utc> + 'static) {
        self.now = Rc::new(now);
    }

    /// Acts on the deadlines passed: a success's notice, an update
    /// unanswered, the wait for an environment; the timer calls it at
    /// the next one.
    pub fn expire(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let now = (self.now)();
        if self.sidebar.expire(now) {
            self.publish(engine);
        }
        self.rows.expire(now);
        self.evaluate(engine);
    }

    fn dismissed_keys(&self, engine: &Engine) -> Vec<String> {
        Settings::of(engine)
            .device_value(DISMISSED)
            .and_then(|keys| {
                keys.as_array().map(|keys| {
                    keys.iter()
                        .filter_map(Json::as_str)
                        .map(str::to_owned)
                        .collect()
                })
            })
            .unwrap_or_default()
    }

    fn dismiss_key(&mut self, engine: &Engine, key: &str) {
        if key.is_empty() {
            return;
        }
        let mut dismissed = self.dismissed_keys(engine);
        if !dismissed.contains(&key.to_owned()) {
            dismissed.push(key.to_owned());
        }
        Settings::of(engine).write_device(engine, DISMISSED, json!(dismissed));
    }

    fn publish(&self, engine: &Engine) {
        let notice = match self.sidebar.current() {
            Some(current) => json!({
                "key": current.key,
                "tone": current.tone,
                "title": current.title,
                "description": current.description,
                "dismissible": current.dismissible,
            }),
            None => Json::Null,
        };
        self.bridge
            .publish(engine, "providerUpdates", json!({"notice": notice}));
    }

    fn schedule(&mut self, engine: &Engine) {
        let mut next = self.sidebar.deadline();
        let sooner = |at: Option<DateTime<Utc>>, next: &mut Option<DateTime<Utc>>| {
            if at.is_some() && next.is_none_or(|n| at.unwrap() < n) {
                *next = at;
            }
        };
        sooner(self.rows.deadline(), &mut next);
        // The wait for a connecting environment, while it lasts.
        if let Some(since) = self.settling_since {
            let until = since + chrono::TimeDelta::milliseconds(SETTLING_MS);
            if until > (self.now)() {
                sooner(Some(until), &mut next);
            }
        }
        if let Some(timer) = self.timer.take() {
            engine.cancel_call(timer);
        }
        let Some(next) = next else { return };
        let ms = (next - (self.now)()).num_milliseconds().max(0) as u64;
        let me = self.me.clone();
        self.timer = Some(engine.call_at(
            engine.now() + Duration::from_millis(ms),
            move |engine| {
                me.run(engine, |c, engine| {
                    c.timer = None;
                    c.expire(engine);
                });
            },
        ));
    }

    fn evaluate(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let local = providers_of(engine);
        if self.sidebar.set_providers(&local, (self.now)()) {
            self.publish(engine);
        }

        // Offers wait for the cluster's members, so one machine is not
        // offered alone and then again with the others.
        if store::with(engine, |store| store.synchronized()) {
            let here = self.mc.environment();
            let mut environments = vec![here.clone()];
            for environment_id in store::with(engine, |store| store.environments()) {
                if environment_id != here && !environment_id.is_empty() {
                    environments.push(environment_id);
                }
            }
            self.remote
                .retain(|environment_id, _| environments.contains(environment_id));
            if environments.len() > 1 {
                if !self.rows_mode {
                    self.close_prompt(engine);
                    self.rows_mode = true;
                }
                self.scope.set_targets(&environments[1..]);
                self.evaluate_rows(engine, &environments, &local);
            } else {
                if self.rows_mode {
                    self.close_prompt(engine);
                    self.rows_mode = false;
                    self.settling_since = None;
                    self.scope.set_targets(&[]);
                }
                self.evaluate_single(engine, &local);
            }
        }
        self.schedule(engine);
    }

    fn close_prompt(&mut self, engine: &Engine) {
        if !self.prompt_id.is_empty() {
            let id = self.prompt_id.clone();
            controller::with::<Toasts, _>(engine, |toasts, engine| {
                toasts.dismiss(engine, &id);
            });
        }
        self.prompt_id.clear();
        self.prompt_key.clear();
        self.rows.clear();
        self.interacted = false;
    }

    /// Closing the prompt by hand dismisses the versions it offered for good.
    fn hook(&mut self, engine: &Engine) {
        if std::mem::replace(&mut self.hooked, true) {
            return;
        }
        let me = self.me.clone();
        controller::with::<Toasts, _>(engine, |toasts, _| {
            toasts.on_closed_by_user(move |engine, id| {
                let id = id.to_owned();
                me.run(engine, |c, engine| {
                    if id != c.prompt_id {
                        return;
                    }
                    // What is on offer as it closes, not as it opened
                    // (the rows prompt's live key).
                    let key = if c.rows_mode {
                        c.live_key.clone()
                    } else {
                        c.prompt_key.clone()
                    };
                    c.prompt_id.clear();
                    c.prompt_key.clear();
                    c.dismiss_key(engine, &key);
                });
            });
        });
    }

    fn settings_action(&self) -> Action {
        let me = self.me.clone();
        Action::new("Settings", move |engine| {
            me.run(engine, |c, engine| {
                c.prompt_id.clear();
                c.prompt_key.clear();
                c.open_settings(engine);
            });
        })
    }

    fn open_settings(&mut self, engine: &Engine) {
        controller::with::<Navigation, _>(engine, |navigation, engine| {
            navigation.open(engine, Route::Settings(PROVIDERS_SECTION.into()));
        });
    }

    // One environment: the toast and its updates.
    fn evaluate_single(&mut self, engine: &Engine, providers: &[Json]) {
        // An update the user started reports once the MC says how it went.
        if let Some(update) = &self.update {
            let followed: Vec<Json> = providers
                .iter()
                .filter(|p| update.instance_ids.contains(instance_of(p)))
                .cloned()
                .collect();
            if self.report(engine, &followed) {
                self.update = None;
            }
            return;
        }

        let outdated = updates::candidates(providers);
        let key = updates::key(&outdated);

        // Other versions than the prompt offers: it no longer says what is true.
        if !self.prompt_id.is_empty() && self.prompt_key != key {
            self.close_prompt(engine);
        }
        if key.is_empty()
            || !self.prompt_id.is_empty()
            || self.seen.contains(&key)
            || self.dismissed_keys(engine).contains(&key)
        {
            return;
        }
        self.seen.insert(key.clone());

        let one_click_providers: Vec<Json> = outdated
            .iter()
            .filter(|p| updates::one_click(p, providers))
            .cloned()
            .collect();
        let view = updates::offer(&outdated, !one_click_providers.is_empty());
        let mut actions = Vec::new();
        if !one_click_providers.is_empty() {
            let me = self.me.clone();
            actions.push(Action::new("Update", move |engine| {
                let chosen = one_click_providers.clone();
                me.run(engine, |c, engine| c.run_updates(engine, chosen));
            }));
        }
        actions.push(self.settings_action());
        self.hook(engine);
        let id = controller::with::<Toasts, _>(engine, |toasts, engine| {
            toasts.show_actions(
                engine,
                &view.kind,
                &view.title,
                &view.description,
                actions,
                0,
            )
        });
        if let Some(id) = id {
            self.prompt_key = key;
            self.prompt_id = id;
        }
    }

    fn groups(
        &self,
        engine: &Engine,
        environments: &[String],
        local: &[Json],
    ) -> Vec<updates::Group> {
        let here = self.mc.environment();
        environments
            .iter()
            .map(|environment_id| {
                let is_here = *environment_id == here;
                let descriptor = store::with(engine, |store| store.environment(environment_id));
                let mut label = descriptor
                    .get("label")
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_owned();
                if label.is_empty() {
                    label = if is_here {
                        "This machine".into()
                    } else {
                        environment_id.clone()
                    };
                }
                // An online environment whose providers have not come is
                // still connecting.
                let settling = !is_here
                    && !self.remote.contains_key(environment_id)
                    && store::with(engine, |store| store.environment_online(environment_id));
                let providers = if is_here {
                    local
                } else {
                    self.remote
                        .get(environment_id)
                        .map(Vec::as_slice)
                        .unwrap_or(&[])
                };
                updates::group(environment_id, &label, providers, settling)
            })
            .collect()
    }

    // Several: the toast's rows.
    fn evaluate_rows(&mut self, engine: &Engine, environments: &[String], local: &[Json]) {
        self.groups = self.groups(engine, environments, local);
        let now = (self.now)();
        let settling = self.groups.iter().any(|group| group.settling);
        if !settling {
            self.settling_since = None;
        } else if self.settling_since.is_none() {
            self.settling_since = Some(now);
        }
        let gated = settling
            && self
                .settling_since
                .is_some_and(|since| now < since + chrono::TimeDelta::milliseconds(SETTLING_MS));
        let key = updates::groups_key(&self.groups);
        self.live_key.clone_from(&key);

        // A prompt the user has not acted on gives way to a changed set,
        // unless that set is only an environment reconnecting.
        if !self.prompt_id.is_empty()
            && self.prompt_key != key
            && !self.interacted
            && (key.is_empty() || !gated)
        {
            self.close_prompt(engine);
        }

        if self.prompt_id.is_empty()
            && !key.is_empty()
            && !gated
            && !self.seen.contains(&key)
            && !self.dismissed_keys(engine).contains(&key)
        {
            self.seen.insert(key.clone());
            self.rows.clear();
            self.interacted = false;
            self.opened_at = updates::iso(now);
            let offered: Vec<Json> = self
                .groups
                .iter()
                .flat_map(|group| group.candidates.iter().cloned())
                .collect();
            let title = updates::offer(&updates::by_driver(&offered), true).title;
            self.hook(engine);
            let actions = vec![self.settings_action()];
            let id = controller::with::<Toasts, _>(engine, |toasts, engine| {
                toasts.show_actions(engine, "warning", &title, "", actions, 0)
            });
            if let Some(id) = id {
                self.prompt_key = key;
                self.prompt_id = id;
            }
        }
        if !self.prompt_id.is_empty() {
            self.show_rows(engine);
        }
    }

    fn show_rows(&mut self, engine: &Engine) {
        if self.prompt_id.is_empty() {
            return;
        }
        let mut rows = Vec::new();
        for group in &self.groups {
            let status = self.rows.status(group, &self.opened_at.clone());
            if group.candidates.is_empty() && status.kind == "idle" {
                continue;
            }
            let action = match status.kind.as_str() {
                "idle" => "Update",
                "failed" | "unchanged" => "Retry",
                _ => "",
            };
            rows.push(Row {
                id: group.environment_id.clone(),
                label: group.label.clone(),
                text: status.text,
                kind: status.kind,
                action: action.into(),
            });
        }
        let id = self.prompt_id.clone();
        let (me, bridge) = (self.me.clone(), self.bridge);
        let shown = controller::with::<Toasts, _>(engine, |toasts, engine| {
            toasts.set_rows(engine, &id, rows, move |engine, row_id| {
                // After the toasts' action ends: the row's start shows
                // its rows on them again.
                let (me, row_id) = (me.clone(), row_id.to_owned());
                bridge.defer(engine, move |engine| {
                    me.run(engine, move |c, engine| c.start_row(engine, &row_id));
                });
            })
        });
        if shown != Some(true) {
            self.prompt_id.clear();
            self.prompt_key.clear();
        }
    }

    fn start_row(&mut self, engine: &Engine, environment_id: &str) {
        let Some(group) = self
            .groups
            .iter()
            .find(|group| group.environment_id == environment_id)
            .cloned()
        else {
            return;
        };
        if group.candidates.is_empty() {
            return;
        }
        self.interacted = true;
        if !store::with(engine, |store| store.environment_online(environment_id)) {
            self.rows.refuse(environment_id, NOT_CONNECTED);
            self.show_rows(engine);
            return;
        }
        let Some(version) = self.rows.start(environment_id, (self.now)()) else {
            return;
        };
        self.show_rows(engine);
        self.schedule(engine);

        // Every candidate of the environment at once; the row says how
        // the worst went.
        struct RowRun {
            remaining: usize,
            count: usize,
            rejected: Option<String>,
            snapshots: Vec<Json>,
        }
        let run = Rc::new(RefCell::new(RowRun {
            remaining: group.candidates.len(),
            count: group.candidates.len(),
            rejected: None,
            snapshots: Vec::new(),
        }));
        for candidate in &group.candidates {
            let instance_id = instance_of(candidate).to_owned();
            let environment = environment_id.to_owned();
            let run = run.clone();
            let me = self.me.clone();
            self.mc.call(
                environment_id,
                "server.updateProvider",
                request(candidate),
                Box::new(move |engine, result| {
                    {
                        let mut run = run.borrow_mut();
                        match &result {
                            Err(error) => {
                                if run.rejected.is_none() {
                                    run.rejected = Some(if error.message.is_empty() {
                                        "Provider update failed.".into()
                                    } else {
                                        error.message.clone()
                                    });
                                }
                            }
                            Ok(result) => {
                                for value in result["providers"].as_array().into_iter().flatten() {
                                    if instance_of(value) == instance_id {
                                        run.snapshots.push(value.clone());
                                    }
                                }
                            }
                        }
                        run.remaining -= 1;
                        if run.remaining > 0 {
                            return;
                        }
                    }
                    let (rejected, snapshots, count) = {
                        let run = run.borrow();
                        (run.rejected.clone(), run.snapshots.clone(), run.count)
                    };
                    let environment = environment.clone();
                    me.run(engine, move |c, engine| {
                        if let Some(rejected) = rejected {
                            c.rows.settle(&environment, version, &rejected, None);
                        } else {
                            let view =
                                updates::progress(&updates::worst_by_driver(&snapshots), count);
                            c.rows.settle(&environment, version, "", Some(view));
                        }
                        c.show_rows(engine);
                        c.schedule(engine);
                    });
                }),
            );
        }
    }

    fn run_updates(&mut self, engine: &Engine, providers: Vec<Json>) {
        self.prompt_id.clear();
        self.prompt_key.clear();
        let mut update = Update {
            instance_ids: providers
                .iter()
                .map(|p| instance_of(p).to_owned())
                .collect(),
            count: providers.len(),
            toast_id: String::new(),
        };
        let view = updates::running(update.count);
        if let Some(id) = controller::with::<Toasts, _>(engine, |toasts, engine| {
            toasts.show_actions(
                engine,
                &view.kind,
                &view.title,
                &view.description,
                Vec::new(),
                0,
            )
        }) {
            update.toast_id = id;
        }
        self.update = Some(update);
        let run = Rc::new(RefCell::new(Run {
            providers,
            next: 0,
            snapshots: Vec::new(),
        }));
        self.step(engine, run);
    }

    // One after another; the first refusal ends it.
    fn step(&mut self, engine: &Engine, run: Rc<RefCell<Run>>) {
        if self.update.is_none() {
            return;
        }
        let provider = {
            let mut run = run.borrow_mut();
            if run.next >= run.providers.len() {
                // The answers' snapshots of the updated instances; a
                // later `config.providers` reports it if these do not
                // settle it.
                let snapshots = run.snapshots.clone();
                drop(run);
                if self.report(engine, &snapshots) {
                    self.update = None;
                }
                return;
            }
            run.next += 1;
            run.providers[run.next - 1].clone()
        };
        let me = self.me.clone();
        self.mc.call(
            &self.mc.environment(),
            "server.updateProvider",
            request(&provider),
            Box::new(move |engine, result| {
                crate::bridge::Bridge::of(engine).defer(engine, move |engine| {
                    me.run(engine, |c, engine| c.answered(engine, run, result));
                });
            }),
        );
    }

    fn answered(
        &mut self,
        engine: &Engine,
        run: Rc<RefCell<Run>>,
        result: Result<Json, crate::mc::McError>,
    ) {
        let Some(update) = &self.update else { return };
        match result {
            Err(error) => {
                let (count, toast_id) = (update.count, update.toast_id.clone());
                self.update = None;
                let view = updates::rejected(
                    count,
                    if error.message.is_empty() {
                        "Provider update failed."
                    } else {
                        &error.message
                    },
                );
                let actions = vec![self.settings_action()];
                controller::with::<Toasts, _>(engine, |toasts, engine| {
                    if !toasts.replace(
                        engine,
                        &toast_id,
                        &view.kind,
                        &view.title,
                        &view.description,
                        actions.clone(),
                        0,
                    ) {
                        toasts.show_actions(
                            engine,
                            &view.kind,
                            &view.title,
                            &view.description,
                            actions,
                            0,
                        );
                    }
                });
            }
            Ok(result) => {
                for provider in result["providers"].as_array().into_iter().flatten() {
                    if update.instance_ids.contains(instance_of(provider)) {
                        run.borrow_mut().snapshots.push(provider.clone());
                    }
                }
                self.step(engine, run);
            }
        }
    }

    /// The update's toast turns into how it went once the snapshots
    /// settle it. Reports once no provider is still updating; false
    /// while one is.
    fn report(&mut self, engine: &Engine, snapshots: &[Json]) -> bool {
        let Some(update) = &self.update else {
            return true;
        };
        let view = updates::progress(snapshots, update.count);
        if !view.terminal() {
            return false;
        }
        let actions = if view.phase != "succeeded" {
            vec![self.settings_action()]
        } else {
            Vec::new()
        };
        let timeout = if view.phase == "succeeded" {
            SUCCESS_MS
        } else {
            0
        };
        let toast_id = update.toast_id.clone();
        controller::with::<Toasts, _>(engine, |toasts, engine| {
            if !toasts.replace(
                engine,
                &toast_id,
                &view.kind,
                &view.title,
                &view.description,
                actions.clone(),
                timeout,
            ) {
                toasts.show_actions(
                    engine,
                    &view.kind,
                    &view.title,
                    &view.description,
                    actions,
                    timeout,
                );
            }
        });
        true
    }
}
