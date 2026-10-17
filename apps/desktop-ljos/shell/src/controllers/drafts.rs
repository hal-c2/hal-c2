//! `landing`, desktop-qt's DraftController, and the shell's drafts: a new
//! thread the user has opened but not sent yet, one per project folder, kept
//! on this machine only ([`set_path`]) and listed at the top of the sidebar
//! once they hold something. Each draft carries the thread id its first send
//! creates, so when that thread's row reaches the shell (or [`promote`] is
//! called) the draft is done and the window moves on to the thread.
//!
//! `thread.new {projectKey?}` opens the project's draft (the given logical
//! project, else the scoped one, else the one the window shows, else the
//! first), `draft.menu {draftId, x, y}` offers to delete it and
//! `draft.delete {draftId}` does. `draft.project {x, y}` offers the projects
//! the open draft can move to.
//!
//! The draft's text is `text`, which the composer saves on a draft route
//! ([`set_text`]) and reopens the draft with.
//!
//! It registers the palette's ways to start a thread: chat.new ("New thread
//! in <project>", listed while the window shows a project), chat.newLocal,
//! the thread.newIn menu (the window's project first) and draft.moveTo.
//!
//! A window with no thread lands on a draft: on `home`, once the MC's
//! snapshot is in, it opens the draft of the most recently active project
//! ([`sidebar_model::most_recent_project`]). With no project it stays home,
//! which offers to add one. A draft that cannot be kept publishes `landing`
//! {failed: true} until `landing.retry` or the window goes elsewhere.
//!
//! The drafts are the engine's, outside the controller (desktop-qt keeps
//! them in NativeShell::common for every window), so the sidebar and the
//! composer read them without waiting on it.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use chrono::{TimeZone, Utc};
use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::{Choice, Commands};
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::menus::{Item, Menus};
use crate::controllers::navigation::{self, Navigation, Route};
use crate::controllers::sidebar::{self, Sidebar};
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::keybindings::command_label;
use crate::sidebar_model::{self as model, ProjectGroup};
use crate::store;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Draft {
    pub id: String,
    pub environment_id: String,
    pub project_id: String,
    pub thread_id: String,
    pub created_at: String,
    pub text: String,
}

impl Draft {
    /// The thread its first send creates.
    pub fn thread_key(&self) -> String {
        format!("{}:{}", self.environment_id, self.thread_id)
    }

    fn from_json(entry: &Json) -> Option<Draft> {
        let text = |key: &str| entry[key].as_str().unwrap_or_default().to_owned();
        let draft = Draft {
            id: text("id"),
            environment_id: text("environmentId"),
            project_id: text("projectId"),
            thread_id: text("threadId"),
            created_at: text("createdAt"),
            text: text("text"),
        };
        let complete = [
            &draft.id,
            &draft.environment_id,
            &draft.project_id,
            &draft.thread_id,
        ]
        .iter()
        .all(|field| !field.is_empty());
        complete.then_some(draft)
    }

    fn json(&self) -> Json {
        let mut entry = json!({
            "id": self.id,
            "environmentId": self.environment_id,
            "projectId": self.project_id,
            "threadId": self.thread_id,
            "createdAt": self.created_at,
        });
        if !self.text.is_empty() {
            entry["text"] = json!(self.text);
        }
        entry
    }
}

type Hook = Rc<dyn Fn(&Engine)>;
type StartedHook = Rc<dyn Fn(&Engine, &str)>;

#[derive(Default)]
struct Kept {
    drafts: RefCell<Vec<Draft>>,
    path: RefCell<Option<PathBuf>>,
    changed: RefCell<Vec<Hook>>,
    started: RefCell<Vec<StartedHook>>,
}

fn kept(engine: &Engine) -> Rc<Kept> {
    engine.extension::<Kept>()
}

/// Where the drafts are kept; loads them from there. None keeps them for
/// this run only.
pub fn set_path(engine: &Engine, path: Option<PathBuf>) {
    let kept = kept(engine);
    if let Some(path) = &path
        && let Ok(bytes) = std::fs::read(path)
    {
        let entries: Vec<Json> = serde_json::from_slice(&bytes).unwrap_or_default();
        *kept.drafts.borrow_mut() = entries.iter().filter_map(Draft::from_json).collect();
    }
    *kept.path.borrow_mut() = path;
}

/// Every draft, oldest first.
pub fn all(engine: &Engine) -> Vec<Draft> {
    kept(engine).drafts.borrow().clone()
}

pub fn draft(engine: &Engine, id: &str) -> Option<Draft> {
    kept(engine)
        .drafts
        .borrow()
        .iter()
        .find(|d| d.id == id)
        .cloned()
}

/// What the sidebar lists the draft as: its text's first line, else how
/// many attachments and excerpts the composer holds for it; nothing while
/// it holds nothing.
pub fn preview(engine: &Engine, id: &str) -> Option<String> {
    crate::controllers::composer::draft_preview(engine, id)
}

/// Runs `f` once no controller is running whenever a draft comes, goes or
/// moves.
pub fn on_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    kept(engine).changed.borrow_mut().push(Rc::new(f));
}

/// Runs `f` with the draft's id once no controller is running whenever a
/// thread is asked for in a project, whether its draft is new or the one
/// from before.
pub fn on_started(engine: &Engine, f: impl Fn(&Engine, &str) + 'static) {
    kept(engine).started.borrow_mut().push(Rc::new(f));
}

fn changed(engine: &Engine) {
    let hooks = kept(engine).changed.borrow().clone();
    for hook in hooks {
        Bridge::of(engine).defer(engine, move |engine| hook(engine));
    }
}

/// Writes the drafts where [`set_path`] says; false when they could not be.
fn save(engine: &Engine) -> bool {
    let kept = kept(engine);
    let Some(path) = kept.path.borrow().clone() else {
        return true;
    };
    let entries: Vec<Json> = kept.drafts.borrow().iter().map(Draft::json).collect();
    write_atomically(&path, Json::Array(entries).to_string().as_bytes()).is_ok()
}

/// Writes `bytes` to `path` whole or not at all.
pub(crate) fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut partial = path.as_os_str().to_owned();
    partial.push(".partial");
    std::fs::write(&partial, bytes)?;
    std::fs::rename(&partial, path)
}

fn open(engine: &Engine, route: Route) {
    controller::with::<Navigation, _>(engine, |n, e| n.open(e, route));
}

/// Every window that shows `from` shows `to` instead.
fn leave(engine: &Engine, from: &Route, to: Route) {
    controller::each_window(engine, |engine| {
        controller::with::<Navigation, _>(engine, |n, e| {
            if n.route() == from {
                n.replace(e, to.clone());
            }
        });
    });
}

/// Opens the project's draft, creating it the first time; returns its id,
/// or nothing when a new draft could not be kept (its file is not writable).
pub fn start(engine: &Engine, environment_id: &str, project_id: &str) -> Option<String> {
    let kept = kept(engine);
    let found = kept
        .drafts
        .borrow()
        .iter()
        .rev()
        .find(|d| d.environment_id == environment_id && d.project_id == project_id)
        .map(|d| d.id.clone());
    let id = match found {
        Some(id) => id,
        None => {
            let id = hal_c2_mc::new_uuid();
            let created_at = Utc
                .timestamp_millis_opt(sidebar::now_ms(engine))
                .single()
                .unwrap_or_default();
            kept.drafts.borrow_mut().push(Draft {
                id: id.clone(),
                environment_id: environment_id.to_owned(),
                project_id: project_id.to_owned(),
                thread_id: hal_c2_mc::new_uuid(),
                created_at: model::format_iso(&created_at),
                text: String::new(),
            });
            // A draft that would not survive a restart is not started.
            if !save(engine) {
                kept.drafts.borrow_mut().pop();
                return None;
            }
            changed(engine);
            id
        }
    };
    open(engine, Route::Draft(id.clone()));
    let hooks = kept.started.borrow().clone();
    for hook in hooks {
        let id = id.clone();
        Bridge::of(engine).defer(engine, move |engine| hook(engine, &id));
    }
    Some(id)
}

/// The thread or draft the window shows: its environment and project.
fn shown_project(engine: &Engine) -> Option<(String, String)> {
    match navigation::shown(engine) {
        Route::Thread(key) => {
            store::with(engine, |s| s.thread(&key)).map(|t| (t.environment_id, t.project_id))
        }
        Route::Draft(id) => draft(engine, &id).map(|d| (d.environment_id, d.project_id)),
        _ => None,
    }
}

fn shown_group_key(engine: &Engine) -> Option<String> {
    let (environment_id, project_id) = shown_project(engine)?;
    sidebar::logical_project_key(engine, &environment_id, &project_id)
}

/// The logical project a new thread starts in without being told: the
/// scoped one, else the one the window shows, else the first.
fn default_group(engine: &Engine) -> Option<ProjectGroup> {
    sidebar::scope(engine)
        .and_then(|key| sidebar::group(engine, &key))
        .or_else(|| shown_group_key(engine).and_then(|key| sidebar::group(engine, &key)))
        .or_else(|| sidebar::groups(engine).into_iter().next())
}

/// Opens the draft of the logical project `group`: on the member the window
/// shows, else its representative.
pub fn start_in(engine: &Engine, group: &ProjectGroup) {
    let summary = |key: &str| {
        group
            .summary
            .get(key)
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    let (mut environment_id, mut project_id) = (summary("environmentId"), summary("projectId"));
    if let Some(shown) = shown_project(engine)
        && group
            .member_keys
            .contains(&format!("{}:{}", shown.0, shown.1))
    {
        (environment_id, project_id) = shown;
    }
    if start(engine, &environment_id, &project_id).is_none() {
        controller::with::<Toasts, _>(engine, |t, e| {
            t.error(
                e,
                "Couldn't start a new thread",
                "The project is still available. Try opening the draft again.",
            );
        });
    }
}

/// Deletes the draft; the window that shows it leaves it.
pub fn remove(engine: &Engine, id: &str) {
    let removed = {
        let kept = kept(engine);
        let mut drafts = kept.drafts.borrow_mut();
        let before = drafts.len();
        drafts.retain(|d| d.id != id);
        drafts.len() != before
    };
    if !removed {
        return;
    }
    save(engine);
    changed(engine);
    leave(engine, &Route::Draft(id.to_owned()), Route::Home);
}

/// The draft's first turn was sent as the thread `thread_key`: the draft is
/// done and the window that showed it shows the thread instead.
pub fn promote(engine: &Engine, thread_key: &str) {
    let found = kept(engine)
        .drafts
        .borrow()
        .iter()
        .find(|d| d.thread_key() == thread_key)
        .map(|d| d.id.clone());
    if let Some(id) = found {
        promote_draft(engine, &id, thread_key);
    }
}

/// The same for the draft `id`, whose thread may be on another environment
/// ("Run on").
pub fn promote_draft(engine: &Engine, id: &str, thread_key: &str) {
    let promoted = {
        let kept = kept(engine);
        let mut drafts = kept.drafts.borrow_mut();
        let index = drafts.iter().position(|d| d.id == id);
        index.map(|index| drafts.remove(index))
    };
    let Some(promoted) = promoted else {
        return;
    };
    save(engine);
    // The thread's composer takes over what the draft held.
    crate::controllers::composer::adopt(engine, id, thread_key, &promoted.text);
    changed(engine);
    leave(
        engine,
        &Route::Draft(id.to_owned()),
        Route::Thread(thread_key.to_owned()),
    );
}

/// Saves what the composer holds for the draft `id`; the sidebar relists it
/// when its row reads differently.
pub fn set_text(engine: &Engine, id: &str, text: &str) {
    let edited = {
        let kept = kept(engine);
        let mut drafts = kept.drafts.borrow_mut();
        match drafts.iter_mut().find(|d| d.id == id && d.text != text) {
            Some(draft) => {
                draft.text = text.to_owned();
                true
            }
            None => false,
        }
    };
    if !edited {
        return;
    }
    save(engine);
    let id = id.to_owned();
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Sidebar, _>(engine, |s, e| s.draft_edited(e, &id));
    });
}

/// Gives the draft a new thread id and clears its text: its old thread was
/// started in the background and the draft stays for another prompt.
pub fn renew(engine: &Engine, id: &str) {
    let renewed = {
        let kept = kept(engine);
        let mut drafts = kept.drafts.borrow_mut();
        match drafts.iter_mut().find(|d| d.id == id) {
            Some(draft) => {
                draft.thread_id = hal_c2_mc::new_uuid();
                draft.text.clear();
                true
            }
            None => false,
        }
    };
    if renewed {
        save(engine);
        changed(engine);
    }
}

/// Moves the draft `from` to the logical project `project_key`: opens that
/// project's draft and brings what was typed along, unless that draft has
/// text of its own.
pub fn move_to(engine: &Engine, from: &str, project_key: &str) {
    let (Some(group), Some(left)) = (sidebar::group(engine, project_key), draft(engine, from))
    else {
        return;
    };
    start_in(engine, &group);
    let Route::Draft(to) = navigation::shown(engine) else {
        return;
    };
    let Some(opened) = draft(engine, &to) else {
        return;
    };
    if to == from || !opened.text.is_empty() || left.text.is_empty() {
        return;
    }
    // Through the composer, which the window now shows `to` in, so the caret
    // lands after the text.
    Bridge::of(engine).dispatch(
        engine,
        "composer.text.set",
        json!({"target": to, "text": left.text, "cursor": crate::composer_model::utf16_len(&left.text)}),
    );
    set_text(engine, from, "");
    changed(engine);
}

/// Drops drafts whose thread now exists (promoted) or whose project is gone
/// from an environment the shell still serves.
fn reconcile(engine: &Engine) {
    if !store::with(engine, |s| s.synchronized()) {
        return;
    }
    let (promoted, orphaned) = store::with(engine, |s| {
        let mut promoted = Vec::new();
        let mut orphaned = Vec::new();
        for draft in kept(engine).drafts.borrow().iter() {
            if s.thread(&draft.thread_key()).is_some() {
                promoted.push(draft.thread_key());
            } else if s.serves_environment(&draft.environment_id)
                && s.project(&format!("{}:{}", draft.environment_id, draft.project_id))
                    .is_none()
            {
                // The project was removed, here or on another client.
                orphaned.push(draft.id.clone());
            }
        }
        (promoted, orphaned)
    });
    for key in promoted {
        promote(engine, &key);
    }
    for id in orphaned {
        remove(engine, &id);
    }
}

/// The window's half: landing, the commands and the draft menus.
pub struct DraftController {
    bridge: Bridge,
    me: Me<Self>,
    active: bool,
    landing_failed: bool,
    lands_on_draft: bool,
}

impl Controller for DraftController {
    fn new(init: Init<'_, Self>) -> Self {
        let me = init.me.clone();
        store::on_changed(init.engine, move |engine| {
            let me = me.clone();
            Bridge::of(engine).defer(engine, move |engine| {
                me.run(engine, |c, e| c.store_changed(e));
            });
        });
        DraftController {
            bridge: init.bridge,
            me: init.me,
            active: false,
            landing_failed: false,
            lands_on_draft: true,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if std::mem::replace(&mut self.active, true) {
            return;
        }
        reconcile(engine);
        add_commands(engine);
        let me = self.me.clone();
        let present_and_land = move |engine: &Engine| {
            let me = me.clone();
            Bridge::of(engine).defer(engine, move |engine| {
                me.run(engine, |c, e| {
                    present(e);
                    c.land(e);
                });
            });
        };
        self.bridge.watch(engine, "route", {
            let f = present_and_land.clone();
            move |engine, _| f(engine)
        });
        // The sidebar's groups and scope.
        self.bridge.watch(engine, "sidebar", move |engine, _| {
            Bridge::of(engine).defer(engine, present);
        });
        self.bridge
            .publish(engine, "landing", json!({"failed": self.landing_failed}));
        present(engine);
        self.land(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active {
            return false;
        }
        let text = |key: &str| {
            payload
                .get(key)
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let number = |key: &str| payload.get(key).and_then(Json::as_f64).unwrap_or_default();
        match action {
            "thread.new" => {
                let requested = text("projectKey");
                Bridge::of(engine).defer(engine, move |engine| start_new(engine, &requested));
            }
            "landing.retry" => {
                self.set_landing_failed(engine, false);
                self.land(engine);
            }
            "draft.delete" => {
                let id = text("draftId");
                Bridge::of(engine).defer(engine, move |engine| remove(engine, &id));
            }
            "draft.project" => open_projects(engine, number("x"), number("y")),
            "draft.menu" => open_menu(engine, &text("draftId"), number("x"), number("y")),
            _ => return false,
        }
        true
    }
}

impl DraftController {
    /// Whether a window with no thread lands on a draft at all. A client
    /// whose home is the thread list itself (the phone) turns it off.
    pub fn set_lands_on_draft(&mut self, lands: bool) {
        self.lands_on_draft = lands;
    }

    fn store_changed(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        reconcile(engine);
        present(engine);
        self.land(engine);
    }

    /// On `home`, opens the most recent project's draft. Home passes
    /// through (Navigation), so the draft takes its place rather than
    /// stacking on it.
    pub fn land(&mut self, engine: &Engine) {
        // Until Navigation has published the route (restored or not), Home
        // is only the absence of one.
        let routed = Bridge::of(engine).published(engine, "route").is_some();
        if !self.lands_on_draft
            || !self.active
            || !routed
            || !store::with(engine, |s| s.synchronized())
        {
            return;
        }
        if navigation::shown(engine) != Route::Home {
            self.set_landing_failed(engine, false);
            return;
        }
        if self.landing_failed {
            return;
        }
        let project = store::with(engine, |s| {
            model::most_recent_project(&s.projects(), &s.threads())
        });
        if let Some(project) = project
            && start(engine, &project.environment_id, &project.id).is_none()
        {
            self.set_landing_failed(engine, true);
        }
    }

    fn set_landing_failed(&mut self, engine: &Engine, failed: bool) {
        if self.landing_failed == failed {
            return;
        }
        self.landing_failed = failed;
        self.bridge
            .publish(engine, "landing", json!({"failed": failed}));
    }
}

/// The project to start in: the one asked for, else the scoped one, else
/// the one the window shows, else the first. With several projects and
/// none of them showing or in scope, it asks which one.
pub fn start_new(engine: &Engine, requested: &str) {
    let group = if !requested.is_empty() {
        // A stale key (project removed, environment gone) must not land the
        // thread in whichever project sorts first.
        match sidebar::group(engine, requested) {
            Some(group) => group,
            None => return,
        }
    } else {
        if shown_project(engine).is_none()
            && sidebar::scope(engine).is_none()
            && sidebar::groups(engine).len() > 1
        {
            Commands::of(engine).run(engine, "thread.newIn");
            return;
        }
        // No project yet: the sidebar offers to add one.
        let Some(group) = default_group(engine) else {
            return;
        };
        group
    };
    start_in(engine, &group);
}

fn display_name(group: &ProjectGroup) -> String {
    group
        .summary
        .get("displayName")
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn workspace_root(group: &ProjectGroup) -> String {
    group
        .summary
        .get("workspaceRoot")
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn add_commands(engine: &Engine) {
    let commands = Commands::of(engine);
    let new_thread = "chat.new";
    commands.add(engine, new_thread, &command_label(new_thread), |engine| {
        start_new(engine, "");
    });
    commands.set_terms(new_thread, &["new thread", "chat", "create", "draft"]);
    // The contextual create, never a project chooser.
    let new_local = "chat.newLocal";
    commands.add(engine, new_local, &command_label(new_local), |engine| {
        if let Some(group) = default_group(engine) {
            start_in(engine, &group);
        }
    });
    commands.set_listed(engine, new_local, false);
    commands.add_menu(engine, "thread.newIn", "New thread in...", |engine| {
        // The window's project first, then the sidebar's order.
        let current = shown_group_key(engine);
        let mut choices = Vec::new();
        for group in sidebar::groups(engine) {
            let key = group.key.clone();
            let mut choice = Choice::new(&group.key, &display_name(&group), move |engine| {
                if let Some(chosen) = sidebar::group(engine, &key) {
                    start_in(engine, &chosen);
                }
            });
            choice.description = workspace_root(&group);
            for member in &group.members {
                choice.terms.push(member.title.clone());
                choice.terms.push(member.workspace_root.clone());
            }
            if current.as_ref() == Some(&group.key) {
                choices.insert(0, choice);
            } else {
                choices.push(choice);
            }
        }
        choices
    });
    commands.add_menu(engine, "draft.moveTo", "Move draft to...", |engine| {
        let Route::Draft(draft_id) = navigation::shown(engine) else {
            return Vec::new();
        };
        let current = shown_group_key(engine);
        sidebar::groups(engine)
            .into_iter()
            .map(|group| {
                let (from, key) = (draft_id.clone(), group.key.clone());
                let mut choice = Choice::new(&group.key, &display_name(&group), move |engine| {
                    move_to(engine, &from, &key);
                });
                choice.description = workspace_root(&group);
                choice.current = current.as_ref() == Some(&group.key);
                choice
            })
            .collect()
    });
    commands.set_terms("draft.moveTo", &["move draft", "project", "change project"]);
    commands.set_terms(
        "thread.newIn",
        &["new thread", "project", "pick", "choose", "select"],
    );
}

/// "New thread in <project>", naming where it starts, while the window
/// shows a project or the list is scoped to one.
fn present(engine: &Engine) {
    let commands = Commands::of(engine);
    let new_thread = "chat.new";
    let group = (shown_project(engine).is_some() || sidebar::scope(engine).is_some())
        .then(|| default_group(engine))
        .flatten();
    let title = group.as_ref().map_or_else(
        || command_label(new_thread),
        |group| format!("New thread in {}", display_name(group)),
    );
    commands.set_title(engine, new_thread, &title);
    commands.set_listed(engine, new_thread, group.is_some());
    let on_draft = matches!(navigation::shown(engine), Route::Draft(_));
    commands.set_listed(
        engine,
        "draft.moveTo",
        on_draft && sidebar::groups(engine).len() > 1,
    );
}

fn open_menu(engine: &Engine, id: &str, x: f64, y: f64) {
    if draft(engine, id).is_none() {
        return;
    }
    let mut delete = Item::new("delete", "Delete draft");
    delete.icon = "trash".into();
    delete.destructive = true;
    let id = id.to_owned();
    controller::with::<Menus, _>(engine, |m, e| {
        m.open(e, x, y, vec![delete], move |engine, _| remove(engine, &id));
    });
}

/// The sidebar's projects, the open draft's ticked; picking another moves
/// the draft ([`move_to`]).
fn open_projects(engine: &Engine, x: f64, y: f64) {
    let Route::Draft(from) = navigation::shown(engine) else {
        return;
    };
    let current = shown_group_key(engine);
    let items: Vec<Item> = sidebar::groups(engine)
        .iter()
        .map(|group| {
            let mut item = Item::new(group.key.clone(), display_name(group));
            item.checked = current.as_ref() == Some(&group.key);
            item
        })
        .collect();
    controller::with::<Menus, _>(engine, |m, e| {
        m.open(e, x, y, items, move |engine, key| {
            move_to(engine, &from, key)
        });
    });
}
