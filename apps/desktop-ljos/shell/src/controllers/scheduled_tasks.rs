//! `scheduledTasks`, desktop-qt's ScheduledTasksController: Settings →
//! Scheduled Tasks. Each environment's tasks (HalC2.ScheduledTasks) in the
//! settings scope, followed live through a `scheduledTasks` subscription per
//! environment, and the editor that creates and edits them.
//!
//! Publishes `scheduledTasks`: {open, canCreate, environments [{id, label,
//! heading (several shown), status: disconnected | loading | error | ready,
//! message, linkMissing, tasks [{id, title, prompt, schedule ("Weekdays at
//! 09:00"), when ("Next run in 5m", "Paused"), enabled, lastRunStatus (never
//! | running | succeeded | failed), lastRun ("Succeeded", "Failed",
//! "Running", empty before the first run), lastRunError, busy}]}], editor:
//! null | {environmentId, environmentLabel, environments [{id, label}], seq
//! (a new one with each editor opened), editing, connected, saving, missing
//! (the task edited is gone), error (the list could not load),
//! legacyInterval (the task runs more often than once a minute), draft
//! (below), projects [{id, title}], models [{key, label}], branches [{name,
//! current, isDefault, isRemote}] with branchesTotal and branchesLoading}}.
//!
//! A draft is {title, prompt, enabled, scheduleMode: fixed | interval,
//! intervalMinutes, timeOfDay, weekdays [0-6, Sunday first], projectId,
//! threadId, workspaceMode: worktree | root | existing_worktree, baseRef,
//! startFromOrigin, checkoutPath, modelKey ("instance:model")}.
//!
//! Actions (`scheduledTasks.`): `new`, `edit {environmentId, id}`,
//! `editorEnvironment {id}` (a new task only), `close`, `save {draft}`,
//! `branches {projectId, query}` (the editor's base branch choices, from
//! vcs.listRefs), `enable {environmentId, id, enabled}`, `run
//! {environmentId, id}`, `delete {environmentId, id}`, and `open
//! {environmentId, taskId}` (a link to a task: its editor, or "Task
//! unavailable"). Relative times move on every minute while the section
//! shows.

use std::collections::{BTreeSet, HashMap};
use std::rc::Rc;

use ljos::prelude::{Engine, ObjectId};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{Navigation, Route};
use crate::controllers::settings_scope::SettingsScope;
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::mc::{Frame, Mc, McError, SubId};
use crate::settings_page;
use crate::store;

const KEY: &str = "scheduledTasks";
const SECTION: &str = "/settings/scheduled-tasks";
const TICK_MS: i32 = 60_000;

fn at<'a>(object: &'a Json, key: &str) -> &'a str {
    settings_page::text(object, key)
}

fn flag_or(object: &Json, key: &str, default: bool) -> bool {
    object.get(key).and_then(Json::as_bool).unwrap_or(default)
}

fn number(object: &Json, key: &str) -> f64 {
    object.get(key).and_then(Json::as_f64).unwrap_or(0.0)
}

/// "Weekdays at 09:00", "Every 15 min" (scheduleLabel).
pub fn schedule_label(schedule: &Json) -> String {
    if at(schedule, "type") == "interval" {
        let every_ms = number(schedule, "everyMs");
        let minutes = every_ms / 60_000.0;
        return if minutes == minutes.floor() {
            format!("Every {} min", minutes as i64)
        } else {
            format!("Every {} sec", (every_ms / 1000.0).round() as i64)
        };
    }
    const NAMES: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    let weekdays: Vec<i64> = schedule
        .get("weekdays")
        .and_then(Json::as_array)
        .map(|days| days.iter().map(|d| settings_page::int(Some(d))).collect())
        .unwrap_or_default();
    let days = if weekdays.is_empty() {
        "Daily".to_owned()
    } else if weekdays.len() == 5 && weekdays.iter().all(|d| (1..=5).contains(d)) {
        "Weekdays".to_owned()
    } else {
        weekdays
            .iter()
            .map(|d| NAMES.get(*d as usize).copied().unwrap_or_default())
            .collect::<Vec<_>>()
            .join(", ")
    };
    format!("{days} at {}", at(schedule, "timeOfDay"))
}

/// "in 5m" for a coming run, "5m ago" for a past one (relativeLabel).
pub fn relative_label(iso: &str, now_ms: i64) -> String {
    let Some(when) = crate::sidebar_model::parse_iso(Some(iso)) else {
        return "Not scheduled".into();
    };
    let diff = when - now_ms;
    if diff <= 0 {
        let minutes = -diff / 60_000;
        return match minutes {
            0 => "just now".into(),
            1..=59 => format!("{minutes}m ago"),
            60..=1439 => format!("{}h ago", minutes / 60),
            _ => format!("{}d ago", minutes / (60 * 24)),
        };
    }
    let minutes = (diff + 59_999) / 60_000;
    if minutes < 2 {
        return "in under a minute".into();
    }
    if minutes < 60 {
        return format!("in {minutes}m");
    }
    let hours = (minutes as f64 / 60.0).round() as i64;
    if hours < 24 {
        return format!("in {hours}h");
    }
    format!("in {}d", (hours as f64 / 24.0).round() as i64)
}

/// The providers a task can run on (scheduledTaskDefaultModel's
/// `available`).
fn usable(providers: Vec<Json>) -> Vec<Json> {
    providers
        .into_iter()
        .filter(|p| {
            flag_or(p, "enabled", true)
                && flag_or(p, "installed", true)
                && at(p, "availability") != "unavailable"
                && p.get("auth")
                    .is_none_or(|auth| at(auth, "status") != "unauthenticated")
        })
        .collect()
}

fn models_of(entry: &Json) -> &[Json] {
    entry
        .get("models")
        .and_then(Json::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
}

fn offers(entries: &[Json], selection: &Json) -> bool {
    for entry in entries {
        if at(entry, "instanceId") != at(selection, "instanceId") {
            continue;
        }
        if let Some(model) = models_of(entry)
            .iter()
            .find(|m| at(m, "slug") == at(selection, "model"))
        {
            return !flag_or(model, "isLegacy", false);
        }
    }
    false
}

/// The badge for a task's last run; none before its first.
fn last_run_label(status: &str) -> &'static str {
    match status {
        "succeeded" => "Succeeded",
        "failed" => "Failed",
        "running" => "Running",
        _ => "",
    }
}

fn key_of(selection: &Json) -> String {
    match selection.as_object() {
        Some(o) if !o.is_empty() => {
            format!("{}:{}", at(selection, "instanceId"), at(selection, "model"))
        }
        _ => String::new(),
    }
}

#[derive(Default)]
struct Listing {
    subscription: Option<SubId>,
    listed: bool,
    tasks: Vec<Json>,
    error: String,
}

#[derive(Default)]
struct Editor {
    open: bool,
    environment_id: String,
    /// The task edited, null for a new one.
    task: Json,
    draft: Json,
    saving: bool,
    /// The project's refs matching the base branch typed.
    branches: Vec<Json>,
    branches_total: i64,
    branches_loading: bool,
}

#[derive(Default)]
struct Link {
    environment_id: String,
    task_id: String,
    shown: bool,
}

pub struct ScheduledTasks {
    bridge: Bridge,
    me: Me<ScheduledTasks>,
    mc: Rc<dyn Mc>,
    active: bool,
    open: bool,
    listings: HashMap<String, Listing>,
    busy: BTreeSet<String>,
    editor: Editor,
    link: Link,
    /// Which editor the dialog's draft belongs to.
    editor_seq: u64,
    /// The latest branch listing asked for.
    branches_request: u64,
    tick: Option<ObjectId>,
}

impl Controller for ScheduledTasks {
    fn new(init: Init<'_, Self>) -> Self {
        ScheduledTasks {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            open: false,
            listings: HashMap::new(),
            busy: BTreeSet::new(),
            editor: Editor::default(),
            link: Link::default(),
            editor_seq: 0,
            branches_request: 0,
            tick: None,
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
            me.run(engine, |c, engine| {
                if open == c.open {
                    return;
                }
                c.open = open;
                if !open {
                    c.editor = Editor::default();
                    c.link = Link::default();
                }
                c.follow(engine);
            });
        });
        let me = self.me.clone();
        SettingsScope::of(engine).on_changed(move |engine| {
            me.run(engine, |c, engine| c.follow(engine));
        });
        // A window restored on this page has its route before this activates.
        let route = self.bridge.published(engine, "route").unwrap_or(Json::Null);
        if settings_page::shows(&route, &[SECTION]) {
            self.open = true;
            self.follow(engine);
        }
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
        let environment_id = at(payload, "environmentId").to_owned();
        let id = at(payload, "id").to_owned();
        match name {
            "new" => {
                let environment = self.default_environment(engine);
                if !environment.is_empty() {
                    self.open_editor(engine, &environment, Json::Null);
                }
            }
            "edit" => {
                if let Some(task) = self.find(engine, &environment_id, &id) {
                    self.open_editor(engine, &environment_id, task);
                }
            }
            "editorEnvironment" => {
                if self.editor.open && self.editor.task.is_null() {
                    self.open_editor(engine, &id, Json::Null);
                }
            }
            "close" => {
                if !self.editor.saving {
                    self.editor = Editor::default();
                }
            }
            "branches" => self.branches(engine, at(payload, "projectId"), at(payload, "query")),
            "save" => self.save(engine, payload.get("draft").cloned().unwrap_or(Json::Null)),
            "enable" => {
                let enabled = settings_page::flag(payload.get("enabled"));
                self.act(
                    engine,
                    &environment_id,
                    &id,
                    "scheduledTasks.setEnabled",
                    json!({"id": id, "enabled": enabled}),
                );
            }
            "run" => self.act(
                engine,
                &environment_id,
                &id,
                "scheduledTasks.runNow",
                json!({"id": id}),
            ),
            "delete" => self.act(
                engine,
                &environment_id,
                &id,
                "scheduledTasks.delete",
                json!({"id": id}),
            ),
            "open" => {
                self.link = Link {
                    environment_id,
                    task_id: at(payload, "taskId").to_owned(),
                    shown: false,
                };
                // The route changes after this controller is through: its
                // watcher runs this one again.
                self.bridge.defer(engine, |engine| {
                    controller::with::<Navigation, _>(engine, |navigation, engine| {
                        navigation.open(engine, Route::Settings(SECTION.into()));
                    });
                });
                self.follow(engine);
            }
            _ => {}
        }
        self.publish(engine);
        true
    }
}

impl ScheduledTasks {
    /// The environments whose tasks are fetched: the scope's connected ones.
    fn fetched(&self, engine: &Engine) -> Vec<String> {
        if self.open {
            SettingsScope::of(engine).targets()
        } else {
            Vec::new()
        }
    }

    fn follow(&mut self, engine: &Engine) {
        let wanted = self.fetched(engine);
        let gone: Vec<String> = self
            .listings
            .keys()
            .filter(|id| !wanted.contains(id))
            .cloned()
            .collect();
        for id in gone {
            if let Some(subscription) = self.listings.remove(&id).and_then(|l| l.subscription) {
                self.mc.unsubscribe(subscription);
            }
        }
        for environment_id in wanted {
            if self.listings.contains_key(&environment_id) {
                continue;
            }
            let mc = store::with(engine, |s| s.mc_serving(&environment_id));
            let me = self.me.clone();
            let id = environment_id.clone();
            let subscription = self.mc.subscribe(
                json!({"type": "scheduledTasks", "mc": mc}),
                Box::new(move |engine: &Engine, frame: &Frame| {
                    let frame = Json::Object(frame.clone());
                    let id = id.clone();
                    me.run(engine, |c, engine| c.take(engine, &id, &frame));
                }),
                None,
            );
            self.listings.insert(
                environment_id,
                Listing {
                    subscription: Some(subscription),
                    ..Listing::default()
                },
            );
        }
        // Relative times move on while the section shows.
        match (self.open, self.tick) {
            (true, None) => {
                let me = self.me.clone();
                self.tick = controller::every(engine, None, TICK_MS, move |engine| {
                    me.run(engine, |c, engine| c.publish(engine));
                });
            }
            (false, Some(timer)) => {
                controller::stop_timer(engine, timer);
                self.tick = None;
            }
            _ => {}
        }
        self.publish(engine);
    }

    fn take(&mut self, engine: &Engine, environment_id: &str, frame: &Json) {
        let Some(listing) = self.listings.get_mut(environment_id) else {
            return;
        };
        match at(frame, "t") {
            "scheduledTasks" => {
                listing.tasks = frame
                    .get("tasks")
                    .and_then(Json::as_array)
                    .cloned()
                    .unwrap_or_default();
                listing.listed = true;
                listing.error.clear();
            }
            "error" => listing.error = at(frame, "reason").to_owned(),
            _ => {}
        }
        self.publish(engine);
    }

    /// The environment's tasks in the scope.
    fn tasks_of(&self, engine: &Engine, environment_id: &str) -> Vec<Json> {
        let scope = SettingsScope::of(engine);
        self.listings
            .get(environment_id)
            .map(|l| l.tasks.as_slice())
            .unwrap_or_default()
            .iter()
            .filter(|task| scope.covers(engine, environment_id, at(task, "projectId")))
            .cloned()
            .collect()
    }

    fn find(&self, engine: &Engine, environment_id: &str, id: &str) -> Option<Json> {
        self.tasks_of(engine, environment_id)
            .into_iter()
            .find(|task| at(task, "id") == id)
    }

    fn default_environment(&self, engine: &Engine) -> String {
        SettingsScope::of(engine)
            .targets()
            .into_iter()
            .next()
            .unwrap_or_default()
    }

    /// The projects a task on the environment can run in.
    fn projects(&self, engine: &Engine, environment_id: &str) -> Vec<Json> {
        let scope = SettingsScope::of(engine);
        let rows: Vec<Json> = store::with(engine, |s| {
            s.project_rows(environment_id)
                .into_iter()
                .map(|row| Json::Object(row.clone()))
                .collect()
        });
        rows.into_iter()
            .filter(|row| scope.covers(engine, environment_id, at(row, "id")))
            .map(|row| json!({"id": at(&row, "id"), "title": at(&row, "title")}))
            .collect()
    }

    /// scheduledTaskDefaultModel: the project's, then the environment's
    /// default model where it can run, then the providers' own default.
    fn default_model(&self, engine: &Engine, environment_id: &str, project_id: &str) -> String {
        let scope = SettingsScope::of(engine);
        let entries = usable(scope.providers(environment_id));
        let settings = scope.settings(environment_id).unwrap_or_default();
        let environment_default = settings
            .get("defaultModelSelection")
            .cloned()
            .unwrap_or(Json::Null);
        let mut configured =
            SettingsScope::override_of(&settings, project_id, "defaultModelSelection")
                .unwrap_or(Json::Null);
        if !configured.as_object().is_some_and(|o| !o.is_empty()) {
            configured = store::with(engine, |s| {
                s.project_row(environment_id, project_id)
                    .and_then(|row| row.get("defaultModelSelection").cloned())
            })
            .unwrap_or(Json::Null);
        }
        if !configured.as_object().is_some_and(|o| !o.is_empty()) {
            configured = environment_default.clone();
        }
        for selection in [&configured, &environment_default] {
            if selection.as_object().is_some_and(|o| !o.is_empty()) && offers(&entries, selection) {
                return key_of(selection);
            }
        }
        let mut first = String::new();
        for entry in &entries {
            for model in models_of(entry) {
                if flag_or(model, "isLegacy", false) {
                    continue;
                }
                let key = format!("{}:{}", at(entry, "instanceId"), at(model, "slug"));
                if flag_or(model, "isDefault", false) {
                    return key;
                }
                if first.is_empty() {
                    first = key;
                }
            }
        }
        first
    }

    fn models(&self, engine: &Engine, environment_id: &str, keep: &str) -> Vec<Json> {
        let mut result = Vec::new();
        let mut kept = keep.is_empty();
        for entry in usable(SettingsScope::of(engine).providers(environment_id)) {
            let provider = match at(&entry, "displayName") {
                "" => at(&entry, "instanceId"),
                name => name,
            };
            for model in models_of(&entry) {
                if flag_or(model, "isLegacy", false) {
                    continue;
                }
                let key = format!("{}:{}", at(&entry, "instanceId"), at(model, "slug"));
                let name = match at(model, "name") {
                    "" => at(model, "slug"),
                    name => name,
                };
                result.push(json!({"key": key, "label": format!("{provider} · {name}")}));
                kept = kept || key == keep;
            }
        }
        // The task's own model stays choosable where it cannot run now.
        if !kept {
            result.push(json!({"key": keep, "label": format!("{keep} (Unavailable)")}));
        }
        result
    }

    fn open_editor(&mut self, engine: &Engine, environment_id: &str, task: Json) {
        let draft = if task.is_null() {
            let project_id = self
                .projects(engine, environment_id)
                .first()
                .map(|p| at(p, "id").to_owned())
                .unwrap_or_default();
            json!({
                "title": "",
                "prompt": "",
                "enabled": true,
                "scheduleMode": "fixed",
                "intervalMinutes": "15",
                "timeOfDay": "09:00",
                "weekdays": [1, 2, 3, 4, 5],
                "projectId": project_id,
                "threadId": "",
                "workspaceMode": "worktree",
                "baseRef": "main",
                "startFromOrigin": true,
                "checkoutPath": "",
                "modelKey": self.default_model(engine, environment_id, &project_id),
            })
        } else {
            let schedule = task.get("schedule").cloned().unwrap_or(Json::Null);
            let workspace = task.get("workspaceStrategy").cloned().unwrap_or(Json::Null);
            let interval = at(&schedule, "type") == "interval";
            let mut weekdays = schedule
                .get("weekdays")
                .and_then(Json::as_array)
                .cloned()
                .unwrap_or_default();
            if interval || weekdays.is_empty() {
                weekdays = (0..7).map(|d| json!(d)).collect();
            }
            let mode = match at(&workspace, "type") {
                "" => "worktree",
                mode => mode,
            };
            let minutes = (number(&schedule, "everyMs") / 60_000.0).max(1.0);
            json!({
                "title": at(&task, "title"),
                "prompt": at(&task, "prompt"),
                "enabled": flag_or(&task, "enabled", false),
                "scheduleMode": if interval { "interval" } else { "fixed" },
                // QString::number(double): no trailing zeros.
                "intervalMinutes": if interval { format!("{minutes}") } else { "15".to_owned() },
                "timeOfDay": if interval { "09:00" } else { at(&schedule, "timeOfDay") },
                "weekdays": weekdays,
                "projectId": at(&task, "projectId"),
                "threadId": at(&task, "threadId"),
                "workspaceMode": mode,
                "baseRef": if mode == "worktree" { at(&workspace, "baseRef") } else { "main" },
                "startFromOrigin": if mode == "worktree" { flag_or(&workspace, "startFromOrigin", false) } else { true },
                "checkoutPath": if mode == "existing_worktree" { at(&workspace, "worktreePath") } else { "" },
                "modelKey": key_of(task.get("modelSelection").unwrap_or(&Json::Null)),
            })
        };
        self.editor = Editor {
            open: true,
            environment_id: environment_id.to_owned(),
            task,
            draft,
            ..Editor::default()
        };
        self.editor_seq += 1;
    }

    fn fail(&self, engine: &Engine, title: &str, description: &str) {
        controller::with::<Toasts, _>(engine, |toasts, engine| {
            toasts.error(engine, title, description);
        });
    }

    fn save(&mut self, engine: &Engine, draft: Json) {
        if !self.editor.open || self.editor.saving {
            return;
        }
        self.editor.draft = draft.clone();
        let environment_id = self.editor.environment_id.clone();
        let listed = self.listings.get(&environment_id).is_some_and(|l| l.listed);
        if !SettingsScope::of(engine).online(engine, &environment_id) || !listed {
            self.fail(
                engine,
                "Reconnect this environment before saving",
                "The task was not saved.",
            );
            return;
        }
        let title = at(&draft, "title").trim().to_owned();
        let prompt = at(&draft, "prompt").trim().to_owned();
        let project_id = at(&draft, "projectId").to_owned();
        let model_key = at(&draft, "modelKey").to_owned();
        let colon = model_key.find(':');
        let known_project = self
            .projects(engine, &environment_id)
            .iter()
            .any(|p| at(p, "id") == project_id);
        let model_ok = colon.is_some_and(|c| c > 0 && c + 1 != model_key.len());
        if title.is_empty() || prompt.is_empty() || !known_project || !model_ok {
            self.fail(
                engine,
                "Scheduled task is incomplete",
                "Add a title, prompt, project, and model.",
            );
            return;
        }
        let colon = colon.unwrap_or_default();
        let schedule = if at(&draft, "scheduleMode") == "interval" {
            let minutes = at(&draft, "intervalMinutes").trim().parse::<f64>();
            let every_ms = minutes
                .as_ref()
                .map_or(f64::NAN, |m| (m * 60_000.0).round());
            if !every_ms.is_finite() || every_ms < 60_000.0 || every_ms > 9_007_199_254_740_991.0 {
                self.fail(
                    engine,
                    "Invalid interval",
                    "Enter an interval of at least one minute.",
                );
                return;
            }
            json!({"type": "interval", "everyMs": every_ms as i64})
        } else {
            let mut weekdays: Vec<i64> = draft
                .get("weekdays")
                .and_then(Json::as_array)
                .map(|days| days.iter().map(|d| settings_page::int(Some(d))).collect())
                .unwrap_or_default();
            weekdays.sort_unstable();
            weekdays.dedup();
            let time = at(&draft, "timeOfDay");
            let mut schedule = json!({
                "type": "fixed_time",
                "timeOfDay": if time.is_empty() { "09:00" } else { time },
            });
            if !weekdays.is_empty() && weekdays.len() != 7 {
                schedule["weekdays"] = json!(weekdays);
            }
            schedule
        };
        let workspace = match at(&draft, "workspaceMode") {
            "root" => json!({"type": "root"}),
            "existing_worktree" => {
                let path = at(&draft, "checkoutPath").trim();
                if path.is_empty() {
                    self.fail(
                        engine,
                        "Checkout path is required",
                        "Enter the path of the checkout to run in.",
                    );
                    return;
                }
                json!({"type": "existing_worktree", "worktreePath": path})
            }
            _ => {
                let base = at(&draft, "baseRef").trim();
                json!({
                    "type": "worktree",
                    "baseRef": if base.is_empty() { "main" } else { base },
                    "startFromOrigin": settings_page::flag(draft.get("startFromOrigin")),
                })
            }
        };
        // The task's own selection keeps its options while its model is kept.
        let mut selection = self
            .editor
            .task
            .get("modelSelection")
            .cloned()
            .unwrap_or(Json::Null);
        if key_of(&selection) != model_key {
            selection = json!({
                "instanceId": &model_key[..colon],
                "model": &model_key[colon + 1..],
            });
        }
        let thread_id = at(&draft, "threadId");
        let task = &self.editor.task;
        let mut input = json!({
            "title": title,
            "prompt": prompt,
            "enabled": settings_page::flag(draft.get("enabled")),
            "schedule": schedule,
            "projectId": project_id,
            "threadId": if thread_id.is_empty() { Json::Null } else { json!(thread_id) },
            "workspaceStrategy": workspace,
            "modelSelection": selection,
            "runtimeMode": match at(task, "runtimeMode") { "" => "full-access", mode => mode },
            "interactionMode": match at(task, "interactionMode") { "" => "default", mode => mode },
            "creationSource": "web",
        });
        if !task.is_null() {
            input["id"] = json!(at(task, "id"));
            input["requireExisting"] = json!(true);
        }
        self.editor.saving = true;
        // The reply belongs to this editor; one opened since keeps its draft.
        let seq = self.editor_seq;
        let me = self.me.clone();
        self.mc.call(
            &environment_id,
            "scheduledTasks.upsert",
            input,
            Box::new(move |engine: &Engine, result: Result<Json, McError>| {
                me.run(engine, |c, engine| {
                    let current = c.editor.open && c.editor_seq == seq;
                    if current {
                        c.editor.saving = false;
                    }
                    match result {
                        Err(e) => c.fail(engine, "Could not save scheduled task", &e.message),
                        Ok(_) if current => c.editor = Editor::default(),
                        Ok(_) => {}
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    /// The branches of the editor's project a new worktree can start from,
    /// as the header's branch picker lists them.
    fn branches(&mut self, engine: &Engine, project_id: &str, query: &str) {
        if !self.editor.open {
            return;
        }
        let environment_id = self.editor.environment_id.clone();
        let cwd = store::with(engine, |s| {
            s.project_row(&environment_id, project_id)
                .and_then(|row| row.get("workspaceRoot"))
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        });
        let seq = self.editor_seq;
        self.branches_request += 1;
        let request = self.branches_request;
        if cwd.is_empty() {
            self.editor.branches.clear();
            self.editor.branches_total = 0;
            return;
        }
        self.editor.branches_loading = true;
        let mut input = json!({"cwd": cwd, "limit": 20});
        if !query.trim().is_empty() {
            input["query"] = json!(query.trim());
        }
        let me = self.me.clone();
        self.mc.call(
            &environment_id,
            "vcs.listRefs",
            input,
            Box::new(move |engine: &Engine, result: Result<Json, McError>| {
                me.run(engine, |c, engine| {
                    if c.editor_seq != seq || c.branches_request != request || !c.editor.open {
                        return;
                    }
                    let list = result.unwrap_or(Json::Null);
                    c.editor.branches_loading = false;
                    c.editor.branches = list
                        .get("refs")
                        .and_then(Json::as_array)
                        .cloned()
                        .unwrap_or_default();
                    c.editor.branches_total = list
                        .get("totalCount")
                        .and_then(Json::as_i64)
                        .unwrap_or(c.editor.branches.len() as i64);
                    c.publish(engine);
                });
            }),
        );
    }

    fn act(
        &mut self,
        engine: &Engine,
        environment_id: &str,
        id: &str,
        method: &str,
        payload: Json,
    ) {
        let busy = format!("{environment_id}\n{id}");
        if self.busy.contains(&busy) || self.find(engine, environment_id, id).is_none() {
            return;
        }
        self.busy.insert(busy.clone());
        let me = self.me.clone();
        self.mc.call(
            environment_id,
            method,
            payload,
            Box::new(move |engine: &Engine, result: Result<Json, McError>| {
                me.run(engine, |c, engine| {
                    c.busy.remove(&busy);
                    if let Err(e) = result {
                        c.fail(engine, "Could not update scheduled task", &e.message);
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    fn publish(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let scope = SettingsScope::of(engine);
        let now_ms = chrono::Utc::now().timestamp_millis();
        let shown = if scope.kind(engine) == "unavailable" || !self.open {
            Vec::new()
        } else {
            scope.environments(engine)
        };
        let heading = shown.len() > 1;
        let mut environments = Vec::new();
        for environment_id in &shown {
            let label = scope.label(engine, environment_id);
            let mut entry = json!({"id": environment_id, "label": label, "heading": heading});
            let mut rows = Vec::new();
            let listing = self.listings.get(environment_id);
            match listing {
                Some(listing) if scope.online(engine, environment_id) => {
                    if !listing.error.is_empty() && !listing.listed {
                        entry["status"] = json!("error");
                        entry["message"] = json!(listing.error);
                    } else if !listing.listed {
                        entry["status"] = json!("loading");
                    } else {
                        entry["status"] = json!("ready");
                        let mut linked = false;
                        for task in self.tasks_of(engine, environment_id) {
                            let id = at(&task, "id");
                            linked = linked || id == self.link.task_id;
                            let enabled = flag_or(&task, "enabled", false);
                            let next = at(&task, "nextRunAt");
                            let when = if !enabled {
                                "Paused".to_owned()
                            } else if next.is_empty() {
                                "Not scheduled".to_owned()
                            } else {
                                format!("Next run {}", relative_label(next, now_ms))
                            };
                            let status = at(&task, "lastRunStatus");
                            rows.push(json!({
                                "id": id,
                                "title": at(&task, "title"),
                                "prompt": at(&task, "prompt"),
                                "schedule": schedule_label(task.get("schedule").unwrap_or(&Json::Null)),
                                "when": when,
                                "enabled": enabled,
                                "lastRunStatus": if status.is_empty() { "never" } else { status },
                                "lastRun": last_run_label(status),
                                "lastRunError": at(&task, "lastRunError"),
                                "busy": self.busy.contains(&format!("{environment_id}\n{id}")),
                            }));
                        }
                        // A link to a task opens it, once; one gone says so.
                        let link_here = !self.link.task_id.is_empty()
                            && if self.link.environment_id.is_empty() {
                                *environment_id == self.default_environment(engine)
                            } else {
                                self.link.environment_id == *environment_id
                            };
                        entry["linkMissing"] = json!(link_here && !linked);
                        if link_here && linked && !self.link.shown {
                            self.link.shown = true;
                            let task = self
                                .find(engine, environment_id, &self.link.task_id.clone())
                                .unwrap_or(Json::Null);
                            self.open_editor(engine, environment_id, task);
                        }
                    }
                }
                _ => {
                    entry["status"] = json!("disconnected");
                    entry["message"] =
                        json!(format!("Reconnect {label} to view its scheduled tasks."));
                }
            }
            entry["tasks"] = json!(rows);
            environments.push(entry);
        }
        let editor = self.editor_state(engine, &scope);
        self.bridge.publish(
            engine,
            KEY,
            json!({
                "open": self.open,
                "canCreate": !self.default_environment(engine).is_empty(),
                "environments": environments,
                "editor": editor,
            }),
        );
    }

    fn editor_state(&self, engine: &Engine, scope: &SettingsScope) -> Json {
        if !self.editor.open {
            return Json::Null;
        }
        let environment_id = &self.editor.environment_id;
        let choices: Vec<Json> = scope
            .targets()
            .into_iter()
            .map(|id| json!({"label": scope.label(engine, &id), "id": id}))
            .collect();
        let listing = self.listings.get(environment_id);
        let listed = listing.is_some_and(|l| l.listed);
        let task_id = at(&self.editor.task, "id");
        let schedule = self
            .editor
            .task
            .get("schedule")
            .cloned()
            .unwrap_or(Json::Null);
        let refs: Vec<Json> = self
            .editor
            .branches
            .iter()
            .map(|r| {
                json!({
                    "name": at(r, "name"),
                    "current": flag_or(r, "current", false),
                    "isDefault": flag_or(r, "isDefault", false),
                    "isRemote": flag_or(r, "isRemote", false),
                })
            })
            .collect();
        json!({
            "seq": self.editor_seq,
            "environmentId": environment_id,
            "environmentLabel": scope.label(engine, environment_id),
            "environments": choices,
            "editing": !self.editor.task.is_null(),
            "connected": scope.online(engine, environment_id) && listed,
            "saving": self.editor.saving,
            "missing": !task_id.is_empty()
                && listed
                && !listing.is_some_and(|l| l.tasks.iter().any(|t| at(t, "id") == task_id)),
            "error": listing.map(|l| l.error.as_str()).unwrap_or_default(),
            "legacyInterval": at(&schedule, "type") == "interval" && number(&schedule, "everyMs") < 60_000.0,
            "branches": refs,
            "branchesTotal": self.editor.branches_total,
            "branchesLoading": self.editor.branches_loading,
            "draft": self.editor.draft,
            "projects": self.projects(engine, environment_id),
            "models": self.models(engine, environment_id, at(&self.editor.draft, "modelKey")),
        })
    }
}
