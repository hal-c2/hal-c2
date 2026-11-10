//! `sidebar` and `customSnooze`, desktop-qt's SidebarController: once the
//! shell has its MC's first snapshot, the rows and projects of the shell
//! store, grouped by [`sidebar_model::group_projects`], the drafts that hold
//! something, and the row actions (settle, snooze, wake, mark unread,
//! dismiss the woke pill, arrange), the selection and the project scope.
//!
//! A draft is listed only once it holds something, newest first. The draft
//! the window shows keeps the row it had when the window opened it: none for
//! one that was empty then, and the same label however the user types.
//!
//! The Settled shelf lists a page of rows at a time ([`model::SETTLED_PAGE`]),
//! and `sidebar.more` lists the next; the open thread is listed past the
//! page. Settled threads a plugin started stay out of it, and its count,
//! unless the MC's `sidebarShowSettledPluginThreads` says otherwise.
//!
//! Selection: `thread.select.toggle {key}` adds or removes one,
//! `thread.select.range {key}` selects from the anchor (the last one toggled
//! or opened) to it, `thread.select.clear` drops them all, as does scoping
//! the list or opening a thread.
//!
//! Arranging: `thread.move {key, direction: "up"|"down"}` moves a pinned or
//! active row one place; `thread.drop {key, section, beforeKey}` puts a
//! dragged row before `beforeKey` of `section` (at its end without one). A
//! drop within the pinned or the active rows reorders them; into another
//! section it pins, unpins, settles, un-settles or wakes the thread, and into
//! the snoozed shelf does nothing. The environment has to support the order
//! (threadPinReorder, threadActiveReorder).
//!
//! Every snooze menu ends in "Custom…" ([`CUSTOM_SNOOZE`]), which asks
//! through `customSnooze` ({keys, date, time, error}): `snooze.custom.submit
//! {mode, date, time, amount, unit}` snoozes the threads it was asked for or
//! says what is wrong with the time; `snooze.custom.cancel` closes it.
//!
//! What another controller reads (the groups, the scope, the rows' order,
//! the selection) is kept outside the controller, so reading it never waits
//! on the sidebar: [`groups`], [`scope`], [`selection`] and the rest.
//!
//! It sees every action before the other controllers, as desktop-qt's window
//! offers it first.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::Duration;

use chrono::{DateTime, Local, TimeZone, Utc};
use ljos::locale::Locale;
use ljos::prelude::Engine;
use ljos::prelude::{Time, TimerId};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::composer::Composer;
use crate::controllers::drafts;
use crate::controllers::keybindings::Keymap;
use crate::controllers::mc_plugin;
use crate::controllers::menus::{Item, Menus};
use crate::controllers::navigation::{self, Navigation, Route};
use crate::controllers::settings::Settings;
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::mc::Mc;
use crate::sidebar_model::{
    self as model, CustomSnooze, GroupingSettings, Input, Nullable, ProjectGroup, SnoozePreset,
    Thread, Tree, View, WorkingTracker,
};
use crate::store;
use crate::this_machine;
use crate::time_zone::Zone;

/// The snooze menus' last item, which asks for a time of the user's own.
pub const CUSTOM_SNOOZE: &str = "snooze:custom";
/// Reading a thread is told at most this often, unless a run completed.
const VISIT_EVERY: Duration = Duration::from_secs(5);
const MIGRATED_ANNOUNCED: &str = "migratedThreadsAnnounced";
/// The device preference that remembers the project the list is scoped to.
const SCOPE_KEY: &str = "sidebarProjectScopeKey";
/// The legacy tree's folded projects and hand order, on this device.
const FOLDED_PROJECTS: &str = "sidebarFoldedProjects";
const PROJECT_ORDER: &str = "sidebarProjectOrder";

/// What runs once a command lands.
pub type Then = Box<dyn FnOnce(&Engine)>;

/// What the sidebar shows, for the controllers that read it.
type Hook = Rc<dyn Fn(&Engine)>;

#[derive(Default)]
struct Shared {
    active: Cell<bool>,
    groups: RefCell<Vec<ProjectGroup>>,
    scope: RefCell<Nullable>,
    view: RefCell<View>,
    selected: RefCell<HashSet<String>>,
    grouped: RefCell<Vec<Hook>>,
    /// Tests pin the zone; the app uses the system's.
    zone: RefCell<Option<Zone>>,
    timestamp_format: RefCell<String>,
    /// Whether the Working section is off, as [`can_move`] reads it (it is
    /// on until the device's settings say otherwise).
    working_shelf_off: Cell<bool>,
}

fn shared(engine: &Engine) -> std::rc::Rc<Shared> {
    Bridge::of(engine).extension::<Shared>(engine)
}

/// Whether the sidebar lists the MC's rows (activated).
pub fn is_active(engine: &Engine) -> bool {
    shared(engine).active.get()
}

/// The logical projects, in sidebar order.
pub fn groups(engine: &Engine) -> Vec<ProjectGroup> {
    shared(engine).groups.borrow().clone()
}

pub fn group(engine: &Engine, key: &str) -> Option<ProjectGroup> {
    shared(engine)
        .groups
        .borrow()
        .iter()
        .find(|g| g.key == key)
        .cloned()
}

/// The logical project `<environmentId>:<projectId>` belongs to.
pub fn logical_project_key(
    engine: &Engine,
    environment_id: &str,
    project_id: &str,
) -> Option<String> {
    let physical = format!("{environment_id}:{project_id}");
    shared(engine)
        .groups
        .borrow()
        .iter()
        .find(|g| g.member_keys.contains(&physical))
        .map(|g| g.key.clone())
}

/// The project the list is scoped to, if any.
pub fn scope(engine: &Engine) -> Nullable {
    shared(engine).scope.borrow().clone()
}

/// The rows' keys in the order they render.
pub fn ordered_keys(engine: &Engine) -> Vec<String> {
    shared(engine).view.borrow().ordered_keys.clone()
}

/// The threads selected for a bulk action, in the order they render.
pub fn selection(engine: &Engine) -> Vec<String> {
    let shared = shared(engine);
    let selected = shared.selected.borrow();
    let view = shared.view.borrow();
    view.ordered_keys
        .iter()
        .filter(|k| selected.contains(*k))
        .cloned()
        .collect()
}

/// Runs `f` once no controller is running whenever the logical projects are
/// grouped differently: one came, went, or took other folders.
pub fn on_grouped(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    shared(engine).grouped.borrow_mut().push(Rc::new(f));
}

/// The wall clock: the engine's pinned one (tests), else the system's.
pub fn now_ms(engine: &Engine) -> i64 {
    engine
        .wall_clock_ms()
        .map_or_else(|| Utc::now().timestamp_millis(), |ms| ms as i64)
}

/// Pins the zone wake times are read in; none is the system's.
pub fn set_time_zone(engine: &Engine, zone: Option<Zone>) {
    shared(engine).zone.replace(zone);
}

/// Runs `$body` with `$now`, the wall clock in the sidebar's zone.
macro_rules! zoned {
    ($engine:expr, $ms:expr, |$now:ident| $body:expr) => {{
        let at = Utc.timestamp_millis_opt($ms).single().unwrap_or_default();
        match shared($engine).zone.borrow().clone() {
            Some(zone) => {
                let $now = at.with_timezone(&zone);
                $body
            }
            None => {
                let $now = at.with_timezone(&Local);
                $body
            }
        }
    }};
}

fn timestamp_format(engine: &Engine) -> String {
    let format = shared(engine).timestamp_format.borrow().clone();
    if format.is_empty() {
        "locale".into()
    } else {
        format
    }
}

/// The snooze choices now.
pub fn snooze_presets(engine: &Engine) -> Vec<SnoozePreset> {
    let format = timestamp_format(engine);
    let locale = Locale::of(engine);
    zoned!(engine, now_ms(engine), |now| model::snooze_presets(
        &now, &format, &locale
    ))
}

pub fn snooze_label(preset: &SnoozePreset) -> String {
    format!("{} ({})", preset.label, preset.when_label)
}

/// "tomorrow 9:00": when a snooze until `snoozed_until` ends.
fn wake_description(engine: &Engine, snoozed_until: &str) -> String {
    let format = timestamp_format(engine);
    let locale = Locale::of(engine);
    zoned!(engine, now_ms(engine), |now| model::wake_description(
        snoozed_until,
        &now,
        &format,
        &locale
    ))
}

/// The snooze menu's items: the presets, then "Custom…".
pub fn snooze_items(presets: &[SnoozePreset]) -> Vec<Item> {
    let mut items: Vec<Item> = presets
        .iter()
        .map(|p| Item::new(format!("snooze:{}", p.id), snooze_label(p)))
        .collect();
    let mut custom = Item::new(CUSTOM_SNOOZE, "Custom…");
    custom.separator_before = true;
    items.push(custom);
    items
}

/// The keys `section` ("pinned", "active", "snoozed", "settled") lists, in order.
fn section_keys(engine: &Engine, section: &str) -> Vec<String> {
    shared(engine).view.borrow().state[section]
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter_map(|row| row["key"].as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

fn section_of(engine: &Engine, key: &str) -> &'static str {
    ["pinned", "active", "working", "snoozed", "settled"]
        .into_iter()
        .find(|section| section_keys(engine, section).iter().any(|k| k == key))
        .unwrap_or("")
}

/// Whether the row can move one place `up` or down within its section.
pub fn can_move(engine: &Engine, key: &str, up: bool) -> bool {
    let section = section_of(engine, key);
    if section != "pinned" && section != "active" {
        return false;
    }
    if section == "active" && !shared(engine).working_shelf_off.get() {
        return false;
    }
    let ordered = section_keys(engine, section);
    let Some(index) = ordered.iter().position(|k| k == key) else {
        return false;
    };
    if up {
        index > 0
    } else {
        index + 1 < ordered.len()
    }
}

/// The thread the window shows, from its route.
fn active_thread_key(engine: &Engine) -> String {
    match navigation::shown(engine) {
        Route::Thread(key) => key,
        _ => String::new(),
    }
}

fn thread(engine: &Engine, key: &str) -> Option<Thread> {
    store::with(engine, |s| s.thread(key))
}

/// The store's threads; one a plugin keeps unlisted is listed once the
/// plugin no longer runs.
fn threads(engine: &Engine) -> Vec<Thread> {
    let mut threads = store::with(engine, |s| s.threads());
    for thread in &mut threads {
        if !thread.listed
            && !mc_plugin::keeps_unlisted(engine, &thread.environment_id, &thread.plugin_id)
        {
            thread.listed = true;
        }
    }
    threads
}

fn toast_error(engine: &Engine, title: &str, reason: &str) {
    controller::with::<Toasts, _>(engine, |t, e| {
        t.error(e, title, reason);
    });
}

/// Sends `command` where `environment_id` is served; a failure toasts
/// `failure_title` (nothing when empty), success runs `then`.
pub fn command(
    engine: &Engine,
    environment_id: &str,
    command: Json,
    failure_title: &str,
    then: Option<Then>,
) {
    let Some(mc) = controller::mc(engine) else {
        return;
    };
    let failure_title = failure_title.to_owned();
    mc.dispatch_command(
        environment_id,
        command,
        Box::new(move |engine, result| match result {
            Ok(_) => {
                if let Some(then) = then {
                    then(engine);
                }
            }
            Err(error) if !failure_title.is_empty() => {
                toast_error(engine, &failure_title, &error.message);
            }
            Err(_) => {}
        }),
    );
}

fn text(payload: &Json, key: &str) -> String {
    payload
        .get(key)
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// Where a window that showed a parked thread goes: settling and snoozing
/// move to the next card, else a new thread in the project; archiving to a
/// new thread in the project; deleting to the project's first other thread
/// ([`model::fallback_after_delete`]), else nowhere, which lands the window
/// on a draft.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Leave {
    NextCard,
    ProjectDraft,
    ProjectFallback,
}

pub struct Sidebar {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<Self>,
    active: bool,
    previewing: bool,
    following: bool,
    grouping: GroupingSettings,
    thread_sort_order: String,
    /// Whether Settled lists the threads a plugin started, as the MC's
    /// settings say (`sidebarShowSettledPluginThreads`).
    show_settled_plugin_threads: bool,
    /// How many settled rows the shelf lists, and how many more
    /// `sidebar.more` lists.
    settled_page: usize,
    settled_shown: usize,
    /// Threads park() waits on the MC for.
    pending: HashSet<String>,
    /// The threads the custom snooze question is about.
    custom_snooze_keys: Vec<String>,
    jump_labels: Vec<String>,
    show_jump_hints: bool,
    /// "<thread key>:<updatedAt>" of the last visit sent, and when.
    visited: String,
    visited_at: Option<Time>,
    visit_later: Option<TimerId>,
    minute: Option<TimerId>,
    anchor: String,
    /// The listed drafts' labels, and the open draft's row as it was when
    /// the window opened it (nothing when it was empty).
    draft_labels: HashMap<String, String>,
    open_draft_id: String,
    open_draft_label: Option<String>,
    /// The migrated threads were announced, or tried to be, this run.
    migration_announced: bool,
    /// The legacy tree, when legacySidebarEnabled; the projects listing
    /// all their threads last the session, as the web's did.
    tree: Option<Tree>,
    showing_all: HashSet<String>,
    working_shelf: bool,
    working: WorkingTracker,
    /// Refreshes when a thread's grace in the Working section runs out.
    working_grace: Option<TimerId>,
    /// The threads whose composer holds something unsent.
    unsent_threads: HashSet<String>,
    scope_restored: bool,
    /// Whether a synchronized MC has listed the scope's project this run
    /// (or the user picked it): only a restored one not seen yet waits
    /// for every environment. A cached listing does not count.
    scope_seen: bool,
}

impl Controller for Sidebar {
    fn new(init: Init<'_, Self>) -> Self {
        // Offered every action first, before the controllers in name order.
        init.bridge.add_interceptor(
            init.engine,
            Rc::new(|engine: &Engine, action: &str, payload: &Json| {
                controller::with::<Sidebar, _>(engine, |s, e| s.handle_action(e, action, payload))
                    .unwrap_or(false)
            }),
        );
        Sidebar {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            active: false,
            previewing: false,
            following: false,
            grouping: GroupingSettings::default(),
            thread_sort_order: "updated_at".into(),
            show_settled_plugin_threads: false,
            settled_page: model::SETTLED_PAGE,
            settled_shown: model::SETTLED_PAGE,
            pending: HashSet::new(),
            custom_snooze_keys: Vec::new(),
            jump_labels: Vec::new(),
            show_jump_hints: false,
            visited: String::new(),
            visited_at: None,
            visit_later: None,
            minute: None,
            anchor: String::new(),
            draft_labels: HashMap::new(),
            open_draft_id: String::new(),
            open_draft_label: None,
            migration_announced: false,
            tree: None,
            showing_all: HashSet::new(),
            working_shelf: true,
            working: WorkingTracker::default(),
            working_grace: None,
            unsent_threads: HashSet::new(),
            scope_restored: false,
            scope_seen: false,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        self.active = true;
        shared(engine).active.set(true);
        self.follow(engine);
        self.refresh(engine);
    }

    fn preview(&mut self, engine: &Engine) {
        self.previewing = true;
        self.follow(engine);
        self.refresh(engine);
    }
}

impl Sidebar {
    /// What refreshes the list: the store, the route, this device's
    /// preferences, the drafts, the jump keys. Followed from the first
    /// preview or activation on.
    fn follow(&mut self, engine: &Engine) {
        if std::mem::replace(&mut self.following, true) {
            return;
        }
        let later = |me: Me<Self>| {
            move |engine: &Engine| {
                let me = me.clone();
                Bridge::of(engine).defer(engine, move |engine| {
                    me.run(engine, |c, e| c.refresh(e));
                });
            }
        };
        store::on_changed(engine, later(self.me.clone()));
        drafts::on_changed(engine, later(self.me.clone()));
        mc_plugin::on_running_changed(engine, later(self.me.clone()));
        Settings::of(engine).on_device_changed(later(self.me.clone()));
        // And the MC's settings, which say whether Settled lists plugin threads.
        Settings::of(engine).on_settings_changed(later(self.me.clone()));
        let refresh = later(self.me.clone());
        self.bridge
            .watch(engine, "route", move |engine, _| refresh(engine));
        let keymap = Keymap::of(engine);
        keymap.set_threads(Rc::new(|engine: &Engine| {
            is_active(engine).then(|| ordered_keys(engine))
        }));
        let me = self.me.clone();
        keymap.on_jump_hints(move |engine, labels, shown| {
            let labels = labels.to_vec();
            me.run(engine, |c, e| c.set_jump_hints(e, labels, shown));
        });
    }

    /// The settled shelf lists `page` rows at a time (and `sidebar.more` lists
    /// the next page too). Tests shorten the page.
    pub fn set_settled_page(&mut self, page: usize) {
        self.settled_page = page;
        self.settled_shown = page;
    }

    /// Re-reads everything the list shows and publishes it.
    pub fn refresh(&mut self, engine: &Engine) {
        if (!self.active && !self.previewing) || store::get(engine).is_none() {
            return;
        }
        self.read_settings(engine);
        let shared = shared(engine);
        let threads = threads(engine);
        let own = self.mc.environment();
        let shape = |groups: &[ProjectGroup]| -> Vec<String> {
            groups
                .iter()
                .map(|g| format!("{}={}", g.key, g.member_keys.join(",")))
                .collect()
        };
        let before = shape(&shared.groups.borrow());
        let groups = store::with(engine, |s| {
            model::group_projects(&s.projects(), &self.grouping, &own, &threads)
        });
        let regrouped = shape(&groups) != before;
        *shared.groups.borrow_mut() = groups.clone();
        // The scope this device chose last time, once per run, as soon as
        // its preferences are read (a preview can refresh before they are).
        let settings = Settings::of(engine);
        if !self.scope_restored && settings.device_path().is_some() {
            self.scope_restored = true;
            if let Some(kept) = settings
                .device_value(SCOPE_KEY)
                .and_then(|v| v.as_str().map(str::to_owned))
                .filter(|s| !s.is_empty())
            {
                *shared.scope.borrow_mut() = Some(kept);
            }
        }
        // A scope whose project went away (removed, regrouped) shows
        // everything again. One restored from the preferences and not
        // seen yet this run waits until every environment has said what
        // projects it has: a cached or unreachable one cannot tell that
        // the project is gone.
        let has_group = |key: &str| groups.iter().any(|g| g.key == key);
        if shared.scope.borrow().as_deref().is_some_and(has_group)
            && store::with(engine, |s| !s.previewing() && s.synchronized())
        {
            self.scope_seen = true;
        }
        let mut cleared = false;
        let scope = {
            let mut scope = shared.scope.borrow_mut();
            if scope.as_ref().is_some_and(|key| !has_group(key))
                && (self.scope_seen || self.projects_reported(engine))
            {
                *scope = None;
                cleared = true;
            }
            scope.clone()
        };
        if cleared {
            self.remember_scope(engine);
        }
        let now = now_ms(engine);
        // The window's route marks the open thread or draft.
        let route = navigation::shown(engine);
        let (active_thread, open_draft) = match &route {
            Route::Thread(key) => (Some(key.clone()), String::new()),
            Route::Draft(id) => (None, id.clone()),
            _ => (None, String::new()),
        };
        if open_draft != self.open_draft_id {
            self.open_draft_label = (!open_draft.is_empty())
                .then(|| drafts::preview(engine, &open_draft))
                .flatten();
            self.open_draft_id = open_draft.clone();
        }
        self.draft_labels.clear();
        let mut listed: Vec<drafts::Draft> = Vec::new();
        for draft in drafts::all(engine) {
            let label = if draft.id == self.open_draft_id {
                self.open_draft_label.clone()
            } else {
                drafts::preview(engine, &draft.id)
            };
            if let Some(label) = label {
                self.draft_labels.insert(draft.id.clone(), label);
                listed.push(draft);
            }
        }
        // Newest first; the stamps are ISO, so they sort as text.
        listed.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        let logical = |env: &str, project: &str| {
            let physical = format!("{env}:{project}");
            groups
                .iter()
                .find(|g| g.member_keys.contains(&physical))
                .map_or(physical, |g| g.key.clone())
        };
        let draft_rows: Vec<Json> = listed
            .iter()
            .map(|d| {
                json!({
                    "draftId": d.id,
                    "projectKey": logical(&d.environment_id, &d.project_id),
                    "label": self.draft_labels.get(&d.id).cloned().unwrap_or_default(),
                })
            })
            .collect();
        let selected = shared.selected.borrow().clone();
        let format = timestamp_format(engine);
        let zone = shared.zone.borrow().clone();
        let locale = Locale::of(engine);
        let describe_wake = move |until: &str| -> String {
            let at = Utc.timestamp_millis_opt(now).single().unwrap_or_default();
            match &zone {
                Some(zone) => {
                    model::wake_description(until, &at.with_timezone(zone), &format, &locale)
                }
                None => model::wake_description(until, &at.with_timezone(&Local), &format, &locale),
            }
        };
        self.unsent_threads = threads
            .iter()
            .map(Thread::key)
            .filter(|key| drafts::preview(engine, key).is_some())
            .collect();
        if self.working_shelf {
            self.working.observe(&threads, now);
        } else {
            self.working.clear();
        }
        let local_folders = !own.is_empty() && this_machine::hosts(engine, &own);
        let view = store::with(engine, |s| {
            let input = Input {
                projects: groups.clone(),
                local_environment_id: (!own.is_empty()).then(|| own.clone()),
                local_folders,
                offline_environments: s
                    .environments()
                    .into_iter()
                    .filter(|e| !s.environment_online(e))
                    .collect(),
                drafts: draft_rows,
                active_thread_key: active_thread,
                active_draft_id: if open_draft.is_empty() {
                    Json::Null
                } else {
                    json!(open_draft)
                },
                unsent_draft_keys: self.unsent_threads.clone(),
                jump_labels: self.jump_labels.clone(),
                show_jump_hints: self.show_jump_hints,
                selected_keys: selected,
                describe_wake: Some(Box::new(describe_wake)),
                settled_limit: self.settled_shown,
                settled_page: self.settled_page,
                show_settled_plugin_threads: self.show_settled_plugin_threads,
                tree: self.tree.clone(),
                working: self.working_shelf.then_some(&self.working),
            };
            model::build(
                &threads,
                &input,
                &scope,
                &|environment| s.capabilities(environment),
                now,
            )
        });
        // A thread that went, or left the list (archived), is not selected
        // any more, so it does not come back selected.
        shared
            .selected
            .borrow_mut()
            .retain(|k| view.ordered_keys.contains(k));
        let state = view.state.clone();
        *shared.view.borrow_mut() = view;
        self.bridge.publish(engine, "sidebar", state);
        if let Some(timer) = self.working_grace.take() {
            engine.cancel_call(timer);
        }
        if let Some(deadline) = self.working.next_deadline() {
            let wait = (deadline - now).clamp(1, model::WORKING_EXIT_GRACE_MS) as u64;
            let me = self.me.clone();
            self.working_grace = Some(engine.call_at(
                engine.now() + Duration::from_millis(wait),
                move |engine| {
                    me.run(engine, |c, e| {
                        c.working_grace = None;
                        c.refresh(e);
                    });
                },
            ));
        }
        // Snoozes wake and "2h" labels tick over on the minute.
        if let Some(timer) = self.minute.take() {
            engine.cancel_call(timer);
        }
        let to_minute = (60_000 - now.rem_euclid(60_000)).max(1000) as u64;
        let me = self.me.clone();
        self.minute = Some(engine.call_at(
            engine.now() + Duration::from_millis(to_minute),
            move |engine| {
                me.run(engine, |c, e| {
                    c.minute = None;
                    c.refresh(e);
                });
            },
        ));
        if regrouped {
            let hooks = shared.grouped.borrow().clone();
            for hook in hooks {
                self.bridge.defer(engine, move |engine| hook(engine));
            }
        }
        self.announce_migrated_threads(engine);
        self.visit_open_thread(engine);
    }

    /// The grouping, ordering and time labels this device's preferences
    /// say, else their defaults.
    fn read_settings(&mut self, engine: &Engine) {
        let device = Settings::of(engine).device();
        let text = |key: &str, default: &str| {
            device
                .get(key)
                .and_then(Json::as_str)
                .filter(|s| !s.is_empty())
                .unwrap_or(default)
                .to_owned()
        };
        let strings = |key: &str| -> Vec<String> {
            device
                .get(key)
                .and_then(Json::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(|v| v.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default()
        };
        let defaults = GroupingSettings::default();
        self.grouping = GroupingSettings {
            mode: text("sidebarProjectGroupingMode", &defaults.mode),
            sort_order: text("sidebarProjectSortOrder", &defaults.sort_order),
            overrides: device
                .get("sidebarProjectGroupingOverrides")
                .and_then(Json::as_object)
                .map(|o| {
                    o.iter()
                        .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_owned())))
                        .collect()
                })
                .unwrap_or_default(),
            manual_order: strings(PROJECT_ORDER),
        };
        self.thread_sort_order = text("sidebarThreadSortOrder", "updated_at");
        self.working_shelf = device
            .get("sidebarWorkingShelfEnabled")
            .and_then(Json::as_bool)
            .unwrap_or(true);
        shared(engine).working_shelf_off.set(!self.working_shelf);
        self.tree = None;
        if device
            .get("legacySidebarEnabled")
            .and_then(Json::as_bool)
            .unwrap_or(false)
        {
            let count = device.get("sidebarThreadPreviewCount");
            self.tree = Some(Tree {
                preview_count: model::clamp_thread_preview_count(
                    count
                        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
                        .unwrap_or(model::DEFAULT_THREAD_PREVIEW_COUNT),
                ),
                thread_sort_order: self.thread_sort_order.clone(),
                folded: strings(FOLDED_PROJECTS).into_iter().collect(),
                showing_all: self.showing_all.clone(),
                manual: self.grouping.sort_order == "manual",
            });
        }
        // The shell's own MC decides for the whole sidebar, as its Settings
        // row shows.
        self.show_settled_plugin_threads = Settings::of(engine)
            .settings()
            .get("sidebarShowSettledPluginThreads")
            .and_then(Json::as_bool)
            .unwrap_or(false);
        *shared(engine).timestamp_format.borrow_mut() = text("timestampFormat", "locale");
    }

    /// Whether every environment has said what projects it has: none is
    /// held from the cache or unreachable.
    fn projects_reported(&self, engine: &Engine) -> bool {
        store::with(engine, |s| {
            !s.previewing()
                && s.synchronized()
                && s.environments().iter().all(|e| s.environment_online(e))
        })
    }

    /// Keeps the scope in this device's preferences for the next start.
    fn remember_scope(&self, engine: &Engine) {
        let settings = Settings::of(engine);
        let current = scope(engine);
        let kept = settings
            .device_value(SCOPE_KEY)
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default();
        if kept != current.clone().unwrap_or_default() {
            settings.write_device(engine, SCOPE_KEY, current.map_or(Json::Null, Json::String));
        }
    }

    /// Threads the MC brought over from the first version (`historyOrigin`
    /// "v1_import") are announced once per device, the first time they are
    /// listed. A device that cannot keep the note is told so once a run,
    /// not at every change of the store.
    fn announce_migrated_threads(&mut self, engine: &Engine) {
        if self.migration_announced || !store::with(engine, |s| s.synchronized()) {
            return;
        }
        let settings = Settings::of(engine);
        if settings.device_value(MIGRATED_ANNOUNCED) == Some(Json::Bool(true)) {
            return;
        }
        let migrated = store::with(engine, |s| {
            s.threads()
                .iter()
                .filter(|t| {
                    s.thread_row(&t.key())
                        .and_then(|r| r.get("historyOrigin"))
                        .and_then(Json::as_str)
                        == Some("v1_import")
                })
                .count()
        });
        if migrated == 0 {
            return;
        }
        self.migration_announced = true;
        if !settings.write_device(engine, MIGRATED_ANNOUNCED, Json::Bool(true)) {
            return;
        }
        let description = if migrated == 1 {
            "1 thread from the previous version is in the list, with its conversation.".to_owned()
        } else {
            format!(
                "{migrated} threads from the previous version are in the list, with their conversations."
            )
        };
        controller::with::<Toasts, _>(engine, |t, e| {
            t.show(
                e,
                "info",
                "Your threads were brought over",
                &description,
                None,
                crate::controllers::toasts::DEFAULT_TIMEOUT_MS,
            );
        });
    }

    /// Reading a thread is a visit: while the window shows one, the MC is
    /// told it was seen up to its newest change (`thread.visit`, visitedAt
    /// its updatedAt), which clears "Done" on every device. Once per change,
    /// an unseen completion at once and other activity at most every few
    /// seconds; an MC that does not keep the watermark (no `lastVisitedAt`
    /// on its rows) is not told.
    fn visit_open_thread(&mut self, engine: &Engine) {
        let key = active_thread_key(engine);
        if key.is_empty() || !self.mc.is_ready() {
            return;
        }
        let Some((thread, keeps_watermark, online, tracking)) = store::with(engine, |s| {
            let thread = s.thread(&key)?;
            let keeps = s
                .thread_row(&key)
                .is_some_and(|r| r.contains_key("lastVisitedAt"));
            let tracking = s.capabilities(&thread.environment_id).visited_tracking;
            Some((thread, keeps, s.thread_online(&key), tracking))
        }) else {
            return;
        };
        if !online || !tracking || !keeps_watermark {
            return;
        }
        let Some(updated_at) = model::parse_iso(Some(&thread.updated_at)) else {
            return;
        };
        let visited_at = model::parse_iso(thread.last_visited_at.as_deref());
        if visited_at.is_some_and(|v| v >= updated_at) {
            return;
        }
        // Once per change: the answer's row comes after this runs again, and
        // a thread marked unread while open stays unread until something new
        // happens.
        let visit = format!("{key}:{}", thread.updated_at);
        if visit == self.visited {
            return;
        }
        let completed_at = thread
            .latest_run
            .as_ref()
            .and_then(|r| model::parse_iso(r.completed_at.as_deref()));
        let unseen_completion = completed_at.is_some_and(|c| visited_at.is_none_or(|v| c > v));
        let now = engine.now();
        if !unseen_completion
            && let Some(at) = self.visited_at
            && now - at < VISIT_EVERY
        {
            if let Some(timer) = self.visit_later.take() {
                engine.cancel_call(timer);
            }
            let me = self.me.clone();
            self.visit_later = Some(engine.call_at(at + VISIT_EVERY, move |engine| {
                me.run(engine, |c, e| {
                    c.visit_later = None;
                    c.visit_open_thread(e);
                });
            }));
            return;
        }
        self.visited = visit;
        self.visited_at = Some(now);
        command(
            engine,
            &thread.environment_id,
            json!({"type": "thread.visit", "threadId": thread.id, "visitedAt": thread.updated_at}),
            "",
            None,
        );
    }

    /// The draft `id` was edited: refreshes when its row would change.
    pub fn draft_edited(&mut self, engine: &Engine, id: &str) {
        if !self.active || id == self.open_draft_id {
            return;
        }
        let label = drafts::preview(engine, id);
        // A thread's row is marked while its composer holds something
        // unsent.
        if thread(engine, id).is_some() {
            if label.is_some() != self.unsent_threads.contains(id) {
                self.refresh(engine);
            }
            return;
        }
        if self.draft_labels.get(id) != label.as_ref() {
            self.refresh(engine);
        }
    }

    /// The action, when it is the sidebar's.
    fn handle_action(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active {
            return false;
        }
        let key = text(payload, "key");
        match action {
            "thread.select.clear" => {
                self.clear_selection(engine);
                true
            }
            "thread.select.toggle" | "thread.select.range" => {
                if thread(engine, &key).is_none() {
                    return true;
                }
                self.select(engine, &key, action == "thread.select.range");
                true
            }
            // Lists the settled shelf's next page.
            "sidebar.more" => {
                self.settled_shown += self.settled_page;
                self.refresh(engine);
                true
            }
            "sidebar.scope" => {
                shared(engine).selected.borrow_mut().clear();
                self.anchor.clear();
                *shared(engine).scope.borrow_mut() = payload
                    .get("projectKey")
                    .and_then(Json::as_str)
                    .map(str::to_owned);
                // Picked from the projects listed now.
                self.scope_seen = true;
                self.remember_scope(engine);
                self.refresh(engine);
                true
            }
            "sidebar.project.fold"
            | "sidebar.project.more"
            | "sidebar.project.less"
            | "sidebar.project.drop"
            | "sidebar.project.menu" => {
                let key = text(payload, "projectKey");
                if group(engine, &key).is_none() {
                    return true;
                }
                match action {
                    "sidebar.project.fold" => {
                        let mut folded: HashSet<String> = self
                            .tree
                            .as_ref()
                            .map(|t| t.folded.clone())
                            .unwrap_or_default();
                        if !folded.remove(&key) {
                            folded.insert(key);
                        }
                        let mut keys: Vec<String> = folded.into_iter().collect();
                        keys.sort();
                        Settings::of(engine).write_device(
                            engine,
                            FOLDED_PROJECTS,
                            if keys.is_empty() {
                                Json::Null
                            } else {
                                json!(keys)
                            },
                        );
                    }
                    "sidebar.project.drop" => {
                        self.drop_project(engine, &key, &text(payload, "targetKey"));
                    }
                    "sidebar.project.menu" => {
                        self.open_project_menu(
                            engine,
                            &key,
                            payload.get("x").and_then(Json::as_f64).unwrap_or(0.0),
                            payload.get("y").and_then(Json::as_f64).unwrap_or(0.0),
                        );
                    }
                    "sidebar.project.more" => {
                        self.showing_all.insert(key);
                        self.refresh(engine);
                    }
                    _ => {
                        self.showing_all.remove(&key);
                        self.refresh(engine);
                    }
                }
                true
            }
            "sidebar.options" => {
                self.open_sort_menu(
                    engine,
                    payload.get("x").and_then(Json::as_f64).unwrap_or(0.0),
                    payload.get("y").and_then(Json::as_f64).unwrap_or(0.0),
                );
                true
            }
            // Opening a thread that woke acknowledges the wake, as dismissing
            // its pill does; Navigation opens it.
            "thread.open" => {
                // A plain open ends the selection and anchors the next range.
                self.anchor = key.clone();
                self.clear_selection(engine);
                if let Some(opened) = thread(engine, &key) {
                    let tracking = store::with(engine, |s| {
                        s.capabilities(&opened.environment_id).visited_tracking
                    });
                    if tracking
                        && let Some(woke_at) = model::visible_woke_at(&opened, now_ms(engine))
                    {
                        command(
                            engine,
                            &opened.environment_id,
                            json!({"type": "thread.visit", "threadId": opened.id, "visitedAt": woke_at}),
                            "",
                            None,
                        );
                    }
                }
                false
            }
            "thread.draft.discard" => {
                let key = key.clone();
                Bridge::of(engine).defer(engine, move |engine| {
                    controller::with::<Composer, _>(engine, |c, e| c.discard_draft(e, &key));
                });
                true
            }
            "thread.attachFiles" => {
                if thread(engine, &key).is_none() {
                    return true;
                }
                controller::with::<Navigation, _>(engine, |n, e| n.open(e, Route::Thread(key)));
                let files = payload.get("files").cloned().unwrap_or(Json::Null);
                self.bridge
                    .dispatch(engine, "composer.attach", json!({"files": files}));
                true
            }
            "snooze.custom.cancel" => {
                self.custom_snooze_keys.clear();
                self.bridge.publish(engine, "customSnooze", Json::Null);
                true
            }
            "snooze.custom.submit" => {
                self.submit_custom_snooze(engine, payload);
                true
            }
            "thread.move" => {
                let up = text(payload, "direction") == "up";
                if !can_move(engine, &key, up) {
                    return true;
                }
                let section = section_of(engine, &key);
                let mut ordered = section_keys(engine, section);
                if let Some(index) = ordered.iter().position(|k| *k == key) {
                    let other = if up { index - 1 } else { index + 1 };
                    ordered.swap(index, other);
                    self.arrange(engine, section, &ordered, &key, false);
                }
                true
            }
            "thread.drop" => {
                self.drop_row(
                    engine,
                    &key,
                    &text(payload, "section"),
                    &text(payload, "beforeKey"),
                );
                true
            }
            "thread.settle" | "thread.unsettle" | "thread.unsnooze" | "thread.snoozeMenu"
            | "thread.wokeDismiss" | "thread.markUnread" => {
                self.row_action(engine, action, &key, payload)
            }
            _ => false,
        }
    }

    fn select(&mut self, engine: &Engine, key: &str, range: bool) {
        let shared = shared(engine);
        {
            let ordered = shared.view.borrow().ordered_keys.clone();
            let mut selected = shared.selected.borrow_mut();
            let anchor = ordered.iter().position(|k| *k == self.anchor);
            let target = ordered.iter().position(|k| k == key);
            match (range, anchor, target) {
                (false, _, _) => {
                    if !selected.remove(key) {
                        selected.insert(key.to_owned());
                        self.anchor = key.to_owned();
                    }
                }
                (true, Some(anchor), Some(target)) => {
                    let (from, to) = (anchor.min(target), anchor.max(target));
                    selected.extend(ordered[from..=to].iter().cloned());
                }
                // No anchor in the list: the row alone, which becomes the anchor.
                (true, _, _) => {
                    selected.insert(key.to_owned());
                    self.anchor = key.to_owned();
                }
            }
        }
        self.refresh(engine);
    }

    pub fn clear_selection(&mut self, engine: &Engine) {
        let cleared = {
            let shared = shared(engine);
            let mut selected = shared.selected.borrow_mut();
            let had = !selected.is_empty();
            selected.clear();
            had
        };
        if cleared {
            self.refresh(engine);
        }
    }

    pub fn deselect(&mut self, engine: &Engine, keys: &[String]) {
        let removed = {
            let shared = shared(engine);
            let mut selected = shared.selected.borrow_mut();
            keys.iter().filter(|k| selected.remove(*k)).count()
        };
        if removed > 0 {
            self.refresh(engine);
        }
    }

    /// While the thread jump modifier is held, the first nine rows show the
    /// key that opens them.
    pub fn set_jump_hints(&mut self, engine: &Engine, labels: Vec<String>, shown: bool) {
        if self.jump_labels == labels && self.show_jump_hints == shown {
            return;
        }
        self.jump_labels = labels;
        self.show_jump_hints = shown;
        self.refresh(engine);
    }

    fn row_action(&mut self, engine: &Engine, action: &str, key: &str, payload: &Json) -> bool {
        // A thread the MC's cluster does not know has nothing to act on.
        let Some(thread) = thread(engine, key) else {
            return false;
        };
        let capabilities = store::with(engine, |s| s.capabilities(&thread.environment_id));
        // An environment without visit tracking has no unread or woke markers.
        if matches!(action, "thread.markUnread" | "thread.wokeDismiss")
            && !capabilities.visited_tracking
        {
            return false;
        }
        let env = thread.environment_id.clone();
        let with = |fields: Json| {
            let mut command = json!({"threadId": thread.id});
            if let (Some(command), Json::Object(fields)) = (command.as_object_mut(), fields) {
                command.extend(fields);
            }
            command
        };
        match action {
            "thread.settle" => self.settle(engine, &thread),
            "thread.unsettle" => command(
                engine,
                &env,
                with(json!({"type": "thread.unsettle", "reason": "user"})),
                "Failed to un-settle thread",
                None,
            ),
            "thread.unsnooze" => {
                // A snooze the limit recovery made is ended there, so the MC
                // does not snooze the thread again for the same reset.
                let recovery = store::with(engine, |s| {
                    s.thread_row(key)
                        .and_then(|r| r.get("limitRecovery"))
                        .cloned()
                })
                .unwrap_or(Json::Null);
                let until = model::parse_iso(thread.snoozed_until.as_deref());
                let reset = model::parse_iso(recovery["resetAt"].as_str());
                let ours = recovery["snooze"] == Json::Bool(true)
                    && thread
                        .latest_run
                        .as_ref()
                        .is_some_and(|r| recovery["runId"].as_str() == Some(&r.run_id))
                    && until.is_some()
                    && until == reset;
                let command_json = if ours {
                    with(json!({
                        "type": "thread.metadata.update",
                        "limitRecovery": {"runId": recovery["runId"], "resetAt": recovery["resetAt"], "snooze": false},
                    }))
                } else {
                    with(json!({"type": "thread.unsnooze", "reason": "user"}))
                };
                command(engine, &env, command_json, "Failed to wake thread", None);
            }
            "thread.snoozeMenu" => {
                let x = payload.get("x").and_then(Json::as_f64).unwrap_or_default();
                let y = payload.get("y").and_then(Json::as_f64).unwrap_or_default();
                open_snooze_menu(engine, key, x, y);
            }
            "thread.wokeDismiss" => {
                // Visiting up to the wake clears the pill without opening the thread.
                if let Some(woke_at) = model::woke_at(&thread, now_ms(engine)) {
                    command(
                        engine,
                        &env,
                        with(json!({"type": "thread.visit", "visitedAt": woke_at})),
                        "",
                        None,
                    );
                }
            }
            _ => command(
                engine,
                &env,
                with(json!({"type": "thread.mark-unread"})),
                "",
                None,
            ),
        }
        true
    }

    /// Settling drops the pin and ends a snooze; undoing puts the pin back
    /// where it was, or snoozes again until the same time.
    fn settle(&mut self, engine: &Engine, thread: &Thread) {
        let pinned = thread.pinned_at.is_some();
        let pin_order_key = if pinned {
            thread.pin_order_key.clone()
        } else {
            None
        };
        let snoozed_until = thread.snoozed_until.clone();
        let key = thread.key();
        let thread_id = thread.id.clone();
        let undo = Rc::new(move |engine: &Engine| {
            let Some(thread) = self::thread(engine, &key) else {
                return;
            };
            let env = thread.environment_id.clone();
            let (thread_id, pin_order_key, snoozed_until) = (
                thread_id.clone(),
                pin_order_key.clone(),
                snoozed_until.clone(),
            );
            let then: Then = Box::new(move |engine: &Engine| {
                if pinned {
                    let mut pin = json!({"type": "thread.pin", "threadId": thread_id});
                    if let Some(order) = pin_order_key {
                        pin["orderKey"] = json!(order);
                    }
                    command(engine, &env, pin, "Failed to pin thread", None);
                } else if let Some(until) = snoozed_until
                    && model::parse_iso(Some(&until)).unwrap_or(0) > now_ms(engine)
                {
                    // Pinning spends a snooze, so only an unpinned thread is
                    // snoozed again.
                    command(
                        engine,
                        &env,
                        json!({"type": "thread.snooze", "threadId": thread_id, "snoozedUntil": until}),
                        "Failed to snooze thread",
                        None,
                    );
                }
            });
            command(
                engine,
                &thread.environment_id,
                json!({"type": "thread.unsettle", "threadId": thread.id, "reason": "user"}),
                "Failed to un-settle thread",
                Some(then),
            );
        });
        self.park(
            engine,
            &thread.key(),
            json!({"type": "thread.settle", "threadId": thread.id}),
            "Failed to settle thread",
            Leave::NextCard,
            Some(Box::new(move |engine: &Engine| {
                controller::with::<Toasts, _>(engine, |t, e| {
                    t.show_undo(e, "Settled", "Settled", undo);
                });
            })),
        );
    }

    /// Runs `park_command`, which takes the thread `key` out of the list
    /// (settle, snooze, archive, delete); the window moves on as `leave`
    /// says when it showed the thread, once the command lands. A failure
    /// toasts `failure_title`.
    pub fn park(
        &mut self,
        engine: &Engine,
        key: &str,
        park_command: Json,
        failure_title: &str,
        leave: Leave,
        then: Option<Then>,
    ) {
        if self.pending.contains(key) {
            return;
        }
        let Some(thread) = thread(engine, key) else {
            return;
        };
        self.pending.insert(key.to_owned());
        // Planned now, before the command reshuffles the list.
        let shows = active_thread_key(engine) == key;
        let navigate: Option<Then> = if !shows {
            None
        } else if leave == Leave::ProjectFallback {
            let fallback =
                model::fallback_after_delete(&threads(engine), key, &self.thread_sort_order);
            Some(Box::new(move |engine: &Engine| {
                let route = fallback.map_or(Route::Home, Route::Thread);
                controller::with::<Navigation, _>(engine, |n, e| n.replace(e, route));
            }))
        } else {
            let next = (leave == Leave::NextCard)
                .then(|| {
                    let view = shared(engine).view.borrow().clone();
                    let keys = &view.ordered_keys;
                    let index = keys.iter().position(|k| k == key)?;
                    (1..keys.len())
                        .map(|step| &keys[(index + step) % keys.len()])
                        .find(|k| !view.parked_keys.contains(*k))
                        .cloned()
                })
                .flatten();
            match next {
                Some(next) => Some(Box::new(move |engine: &Engine| {
                    controller::with::<Navigation, _>(engine, |n, e| {
                        n.open(e, Route::Thread(next));
                    });
                })),
                // Nothing left to show: a new thread in the same project. The
                // thread is parked either way; a draft that could not be
                // started is said.
                None => {
                    let done = match park_command["type"].as_str() {
                        Some("thread.archive") => "archived",
                        Some("thread.settle") => "settled",
                        _ => "snoozed",
                    };
                    let (env, project) = (thread.environment_id.clone(), thread.project_id.clone());
                    Some(Box::new(move |engine: &Engine| {
                        if drafts::start(engine, &env, &project).is_none() {
                            toast_error(
                                engine,
                                &format!("Thread {done}, but navigation failed"),
                                "A new thread could not be started.",
                            );
                        }
                    }))
                }
            }
        };
        let me = self.me.clone();
        let (key, failure_title) = (key.to_owned(), failure_title.to_owned());
        self.mc.dispatch_command(
            &thread.environment_id,
            park_command,
            Box::new(move |engine, result| {
                me.run(engine, |c, _| {
                    c.pending.remove(&key);
                });
                if let Err(error) = result {
                    toast_error(engine, &failure_title, &error.message);
                    return;
                }
                // A navigation made while the command was pending wins over the plan.
                if let Some(navigate) = navigate
                    && active_thread_key(engine) == key
                {
                    navigate(engine);
                }
                if let Some(then) = then {
                    then(engine);
                }
            }),
        );
    }

    /// Whether park() waits on the MC for the thread `key`.
    pub fn parking(&self, key: &str) -> bool {
        self.pending.contains(key)
    }

    /// Snoozes the thread `key` until `snoozed_until`, with an Undo toast.
    pub fn snooze(&mut self, engine: &Engine, key: &str, snoozed_until: &str) {
        let Some(thread) = thread(engine, key) else {
            return;
        };
        let (undo_key, until) = (key.to_owned(), snoozed_until.to_owned());
        self.park(
            engine,
            key,
            json!({"type": "thread.snooze", "threadId": thread.id, "snoozedUntil": snoozed_until}),
            "Failed to snooze thread",
            Leave::NextCard,
            Some(Box::new(move |engine: &Engine| {
                let title = format!("Snoozed until {}", wake_description(engine, &until));
                let undo = Rc::new(move |engine: &Engine| {
                    Bridge::of(engine).dispatch(
                        engine,
                        "thread.unsnooze",
                        json!({"key": undo_key}),
                    );
                });
                controller::with::<Toasts, _>(engine, |t, e| {
                    t.show_undo(e, "Snoozed", &title, undo);
                });
            })),
        );
    }

    /// Asks for a wake time of the user's own for `keys`, starting an hour
    /// from now.
    pub fn ask_custom_snooze(&mut self, engine: &Engine, keys: Vec<String>) {
        if keys.is_empty() {
            return;
        }
        let in_an_hour = now_ms(engine) + 3_600_000;
        let (date, time) = zoned!(engine, in_an_hour, |at| (
            at.format("%Y-%m-%d").to_string(),
            at.format("%H:%M").to_string()
        ));
        self.custom_snooze_keys = keys.clone();
        self.bridge.publish(
            engine,
            "customSnooze",
            json!({"keys": keys, "date": date, "time": time, "error": ""}),
        );
    }

    fn submit_custom_snooze(&mut self, engine: &Engine, payload: &Json) {
        if self.custom_snooze_keys.is_empty() {
            return;
        }
        let input = CustomSnooze {
            mode: text(payload, "mode"),
            date: text(payload, "date"),
            time: text(payload, "time"),
            amount: text(payload, "amount"),
            unit: text(payload, "unit"),
        };
        let now: DateTime<Utc> = Utc
            .timestamp_millis_opt(now_ms(engine))
            .single()
            .unwrap_or_default();
        let zone = shared(engine).zone.borrow().clone();
        let until = match zone {
            Some(zone) => model::resolve_custom_snooze(&input, now, &zone),
            None => model::resolve_custom_snooze(&input, now, &Local),
        };
        let Some(until) = until else {
            let mut asked = self
                .bridge
                .published(engine, "customSnooze")
                .unwrap_or_else(|| json!({}));
            asked["error"] = json!(if input.mode == "duration" {
                "Enter a positive duration."
            } else {
                "Choose a valid date and time in the future."
            });
            self.bridge.publish(engine, "customSnooze", asked);
            return;
        };
        let keys = std::mem::take(&mut self.custom_snooze_keys);
        self.bridge.publish(engine, "customSnooze", Json::Null);
        self.clear_selection(engine);
        for key in keys {
            self.snooze(engine, &key, &until);
        }
    }

    /// Writes the order keys that put `key` where `ordered` has it; when
    /// `pinning`, the thread is pinned with its key instead of reordered.
    fn arrange(
        &mut self,
        engine: &Engine,
        section: &str,
        ordered: &[String],
        key: &str,
        pinning: bool,
    ) {
        let Some(moved) = thread(engine, key) else {
            return;
        };
        let pinned = section == "pinned";
        let capability = if pinned {
            "threadPinReorder"
        } else {
            "threadActiveReorder"
        };
        let failure = if pinned {
            "Failed to reorder pinned threads"
        } else {
            "Failed to reorder active threads"
        };
        if !store::with(engine, |s| s.supports(&moved.environment_id, capability)) {
            let why = if pinned {
                "Update this environment's server to reorder pinned threads."
            } else {
                "Update this environment's server to reorder active threads."
            };
            toast_error(engine, failure, why);
            return;
        }
        // Every thread of the section keeps its key, the ones the scope hides too.
        let threads = threads(engine);
        let all = store::with(engine, |s| {
            model::partition(
                &threads,
                None,
                &|environment| s.capabilities(environment),
                now_ms(engine),
            )
        });
        let mut order_keys: HashMap<String, Nullable> =
            (if pinned { &all.pinned } else { &all.active })
                .iter()
                .map(|t| {
                    let order = if pinned {
                        t.pin_order_key.clone()
                    } else {
                        t.active_order_key.clone()
                    };
                    (t.key(), order)
                })
                .collect();
        if pinning {
            order_keys.insert(key.to_owned(), None);
        }
        let writable: HashSet<String> = store::with(engine, |s| {
            s.threads()
                .iter()
                .filter(|t| s.environment_online(&t.environment_id))
                .map(Thread::key)
                .collect()
        });
        // Keyless rows lead Active and trail Pinned.
        let Some(plan) =
            model::plan_writable_reorder(ordered, &order_keys, key, &writable, !pinned)
        else {
            return;
        };
        for assignment in plan {
            let Some(thread) = thread(engine, &assignment.key) else {
                continue;
            };
            if !store::with(engine, |s| s.supports(&thread.environment_id, capability)) {
                continue;
            }
            let pin = pinning && assignment.key == key;
            let kind = if pin {
                "thread.pin"
            } else if pinned {
                "thread.pin.reorder"
            } else {
                "thread.active.reorder"
            };
            command(
                engine,
                &thread.environment_id,
                json!({"type": kind, "threadId": thread.id, "orderKey": assignment.order_key}),
                if pin { "Failed to pin thread" } else { failure },
                None,
            );
        }
    }

    fn drop_row(&mut self, engine: &Engine, key: &str, section: &str, before_key: &str) {
        let Some(thread) = thread(engine, key) else {
            return;
        };
        let from = section_of(engine, key);
        if from.is_empty() || section == "snoozed" {
            return;
        }
        if from == "working" || section == "working" {
            return;
        }
        let keyed = json!({"key": key});
        let placed = || {
            let mut ordered = section_keys(engine, section);
            ordered.retain(|k| k != key);
            let before = (before_key != key)
                .then(|| ordered.iter().position(|k| k == before_key))
                .flatten();
            ordered.insert(before.unwrap_or(ordered.len()), key.to_owned());
            ordered
        };
        if section == from {
            if section == "pinned" || (section == "active" && !self.working_shelf) {
                let ordered = placed();
                if ordered != section_keys(engine, section) {
                    self.arrange(engine, section, &ordered, key, false);
                }
            }
        } else if section == "pinned" {
            if store::with(engine, |s| s.capabilities(&thread.environment_id).pinning) {
                self.arrange(engine, section, &placed(), key, true);
            }
        } else if section == "settled" {
            self.handle_action(engine, "thread.settle", &keyed);
        } else if from == "pinned" {
            // Dragging out of the pinned rows says it: no question is asked.
            command(
                engine,
                &thread.environment_id,
                json!({"type": "thread.unpin", "threadId": thread.id}),
                "Failed to unpin thread",
                None,
            );
        } else if from == "settled" {
            self.handle_action(engine, "thread.unsettle", &keyed);
        } else if from == "snoozed" {
            self.handle_action(engine, "thread.unsnooze", &keyed);
        }
    }

    fn drop_project(&mut self, engine: &Engine, key: &str, target_key: &str) {
        // Only an order the user keeps by hand takes a drag.
        if self.grouping.sort_order != "manual" || key == target_key {
            return;
        }
        let (Some(dragged), Some(target)) = (group(engine, key), group(engine, target_key)) else {
            return;
        };
        let folders = |group: &ProjectGroup| -> Vec<String> {
            let mut keys: Vec<String> = Vec::new();
            for member in &group.members {
                let physical = model::physical_key(member);
                if !keys.contains(&physical) {
                    keys.push(physical);
                }
            }
            keys
        };
        let mut order: Vec<String> = Vec::new();
        for group in &groups(engine) {
            for physical in folders(group) {
                if !order.contains(&physical) {
                    order.push(physical);
                }
            }
        }
        let next = model::reorder_projects(&order, &folders(&dragged), &folders(&target));
        if next == order {
            return;
        }
        Settings::of(engine).write_device(engine, PROJECT_ORDER, json!(next));
    }

    fn open_project_menu(&mut self, engine: &Engine, key: &str, x: f64, y: f64) {
        let Some(project) = group(engine, key) else {
            return;
        };
        if project.members.is_empty() {
            return;
        }
        let members = project.members.clone();
        let grouped = members.len() > 1;
        // A grouped project's entries name the folder each acts on.
        let member_label = |member: &model::Project| -> String {
            let environment = store::with(engine, |s| {
                s.environment(&member.environment_id)
                    .get("label")
                    .and_then(Json::as_str)
                    .map(str::to_owned)
                    .unwrap_or_default()
            });
            if environment.is_empty() {
                member.workspace_root.clone()
            } else {
                format!("{} ({environment})", member.workspace_root)
            }
        };
        type Run = Rc<dyn Fn(&Engine)>;
        let run: Rc<RefCell<HashMap<String, Run>>> = Rc::new(RefCell::new(HashMap::new()));
        let leaf = |run: &Rc<RefCell<HashMap<String, Run>>>,
                    id: String,
                    label: String,
                    action: Run|
         -> Item {
            run.borrow_mut().insert(id.clone(), action);
            Item::new(id, label)
        };
        let bridge = self.bridge;
        let mut items: Vec<Item> = Vec::new();
        // `targeted(action, label, make)`: one entry, or a folder entry
        // per member of a grouped project.
        macro_rules! targeted {
            ($action:expr, $label:expr, $make:expr) => {{
                let make: &dyn Fn(&model::Project, String, String) -> Item = &$make;
                if !grouped {
                    make(&members[0], format!("{}:0", $action), $label.to_owned())
                } else {
                    let mut item = Item::new($action, $label);
                    for (i, member) in members.iter().enumerate() {
                        let label = member_label(member);
                        item.children
                            .push(make(member, format!("{}:{i}", $action), label));
                    }
                    item
                }
            }};
        }
        items.push(targeted!(
            "rename",
            "Rename",
            |member: &model::Project, id: String, label: String| {
                let member_key = member.key();
                leaf(
                    &run,
                    id,
                    label,
                    Rc::new(move |engine: &Engine| {
                        bridge.dispatch(
                            engine,
                            "project.rename",
                            json!({"projectKey": member_key}),
                        );
                    }),
                )
            }
        ));
        // The device's default, else the folder's own choice
        // (sidebarProjectGroupingOverrides).
        const GROUPINGS: [(&str, &str); 4] = [
            ("inherit", "Use global default"),
            ("repository", "Group by repository"),
            ("repository_path", "Group by repository path"),
            ("separate", "Keep separate"),
        ];
        let overrides = self.grouping.overrides.clone();
        items.push(targeted!(
            "grouping",
            "Group into...",
            |member: &model::Project, id: String, label: String| {
                let folder = model::physical_key(member);
                let current = overrides
                    .get(&folder)
                    .map_or("inherit", String::as_str)
                    .to_owned();
                let mut choices = Item::new(id.clone(), label);
                for (choice, choice_label) in GROUPINGS {
                    let folder = folder.clone();
                    let mut item = leaf(
                        &run,
                        format!("{id}:{choice}"),
                        choice_label.to_owned(),
                        Rc::new(move |engine: &Engine| {
                            let settings = Settings::of(engine);
                            let mut overrides = settings
                                .device_value("sidebarProjectGroupingOverrides")
                                .and_then(|v| v.as_object().cloned())
                                .unwrap_or_default();
                            if choice == "inherit" {
                                overrides.remove(&folder);
                            } else {
                                overrides.insert(folder.clone(), json!(choice));
                            }
                            settings.write_device(
                                engine,
                                "sidebarProjectGroupingOverrides",
                                if overrides.is_empty() {
                                    Json::Null
                                } else {
                                    Json::Object(overrides)
                                },
                            );
                        }),
                    );
                    item.checked = choice == current;
                    choices.children.push(item);
                }
                choices
            }
        ));
        items.push(targeted!(
            "copy-path",
            "Copy Path",
            |member: &model::Project, id: String, label: String| {
                let path = member.workspace_root.clone();
                leaf(
                    &run,
                    id,
                    label,
                    Rc::new(move |engine: &Engine| {
                        if Bridge::of(engine).copy_to_clipboard(engine, &path) {
                            controller::with::<Toasts, _>(engine, |t, e| {
                                t.show(e, "success", "Path copied", &path, None, 0);
                            });
                        } else {
                            toast_error(
                                engine,
                                "Failed to copy path",
                                "The clipboard could not be written.",
                            );
                        }
                    }),
                )
            }
        ));
        let key_owned = key.to_owned();
        let mut settings_item = leaf(
            &run,
            "project-settings".into(),
            "Project settings".into(),
            Rc::new(move |engine: &Engine| {
                let key = key_owned.clone();
                controller::with::<Navigation, _>(engine, |n, e| {
                    n.open_for_project(e, Route::Settings("/settings/projects".into()), key);
                });
            }),
        );
        settings_item.icon = "settings".into();
        items.push(settings_item);
        let bridge = self.bridge;
        let mut remove = targeted!(
            "delete",
            "Remove",
            |member: &model::Project, id: String, label: String| {
                let member_key = member.key();
                let mut item = leaf(
                    &run,
                    id,
                    label,
                    Rc::new(move |engine: &Engine| {
                        // A project with threads says so first; deleting
                        // it anyway still asks (the projects controller).
                        let member_key2 = member_key.clone();
                        let ask = move |engine: &Engine| {
                            bridge.dispatch(
                                engine,
                                "project.remove",
                                json!({"projectKey": member_key2.clone()}),
                            );
                        };
                        let Some(project) = store::with(engine, |s| s.project(&member_key)) else {
                            return;
                        };
                        let threads = store::with(engine, |s| {
                            s.threads()
                                .iter()
                                .filter(|t| {
                                    t.environment_id == project.environment_id
                                        && t.project_id == project.id
                                        && t.archived_at.is_none()
                                })
                                .count()
                        });
                        if threads == 0 {
                            ask(engine);
                            return;
                        }
                        controller::with::<Toasts, _>(engine, |t, e| {
                            t.show(
                                e,
                                "warning",
                                "Project is not empty",
                                "Delete all threads in this project before removing it.",
                                Some(crate::controllers::toasts::Action::new(
                                    "Delete anyway",
                                    ask,
                                )),
                                0,
                            );
                        });
                    }),
                );
                item.destructive = true;
                item
            }
        );
        remove.icon = "trash".into();
        remove.destructive = true;
        items.push(remove);
        controller::with::<Menus, _>(engine, |m, e| {
            m.open(e, x, y, items, move |engine, id| {
                if let Some(action) = run.borrow().get(id).cloned() {
                    action(engine);
                }
            });
        });
    }

    fn open_sort_menu(&mut self, engine: &Engine, x: f64, y: f64) {
        const ORDERS: [(&str, &str); 3] = [
            ("updated_at", "Last user message"),
            ("created_at", "Created at"),
            ("manual", "Manual"),
        ];
        let choices = |prefix: &str, label: &str, count: usize, current: &str| -> Item {
            let mut item = Item::new(prefix, label);
            for (value, text) in ORDERS.iter().take(count) {
                let mut choice = Item::new(format!("{prefix}:{value}"), *text);
                choice.checked = *value == current;
                item.children.push(choice);
            }
            item
        };
        let items = vec![
            choices(
                "sidebarProjectSortOrder",
                "Sort projects",
                3,
                &self.grouping.sort_order,
            ),
            // Threads have no order of the user's own.
            choices(
                "sidebarThreadSortOrder",
                "Sort threads",
                2,
                &self.thread_sort_order,
            ),
        ];
        controller::with::<Menus, _>(engine, |m, e| {
            m.open(e, x, y, items, move |engine, id| {
                if let Some((key, value)) = id.split_once(':') {
                    Settings::of(engine).write_device(engine, key, json!(value));
                }
            });
        });
    }
}

/// The snooze presets at (`x`, `y`) for the thread `key`.
fn open_snooze_menu(engine: &Engine, key: &str, x: f64, y: f64) {
    let presets = snooze_presets(engine);
    let items = snooze_items(&presets);
    let key = key.to_owned();
    controller::with::<Menus, _>(engine, |m, e| {
        m.open(e, x, y, items, move |engine, id| {
            if id == CUSTOM_SNOOZE {
                let keys = vec![key.clone()];
                controller::with::<Sidebar, _>(engine, |s, e| s.ask_custom_snooze(e, keys));
                return;
            }
            if let Some(preset) = presets.iter().find(|p| format!("snooze:{}", p.id) == id) {
                let until = preset.snoozed_until.clone();
                controller::with::<Sidebar, _>(engine, |s, e| s.snooze(e, &key, &until));
            }
        });
    });
}
