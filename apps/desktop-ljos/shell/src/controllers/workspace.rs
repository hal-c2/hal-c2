//! `workspace`, desktop-qt's WorkspaceController: the header and the
//! composer's context strip for the route's thread (a draft too), from the
//! MC. Publishes `workspace` in the ShellWorkspaceState shape (packages/
//! contracts shell.ts) less the terminal fields, which `Terminals` owns. The
//! thread and its project are store rows, the checkout's git status the MC's
//! `vcs` shape, the refs `vcs.listRefs`, the editors each environment's
//! `config`.
//!
//! It takes every `workspace.*` action: `workspace.newThread` opens a draft
//! in the header's project (`thread.new`), `workspace.openPullRequest` the
//! checkout's pull request in the browser, `workspace.previousWorktree`
//! points a draft at the worktree `previousWorktree` ({label} or null)
//! offers. `workspace.titleMenu` is the thread menu's, which sees it first.
//!
//! A draft's checkout (mode, start from origin, branch, worktree, the machine
//! it runs on) lives here, keyed by draft id, and [`launch`] turns it into
//! the thread the composer launches.
//!
//! What other controllers read ([`place`], [`git`], [`checkout`],
//! [`launch`], [`environment_config`]) is kept on the engine beside the
//! controller, so they read it while the workspace is running (a terminal
//! started by `workspace.runScript` asks where it starts).

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use ljos::prelude::Engine;
use serde_json::{Map, json};

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::drafts;
use crate::controllers::navigation::{self, Route};
use crate::controllers::settings::Settings;
use crate::controllers::terminals::Terminals;
use crate::controllers::thread_menu::ThreadMenu;
use crate::controllers::toasts::{DEFAULT_TIMEOUT_MS, Toasts};
use crate::json::Json;
use crate::mc::{Mc, McError, SubId};
use crate::project::scripts;
use crate::sidebar_model;
use crate::store;

/// packages/contracts EDITORS, in the order the picker offers them.
const EDITORS: &[(&str, &str)] = &[
    ("default", "Default Editor"),
    ("cursor", "Cursor"),
    ("trae", "Trae"),
    ("kiro", "Kiro"),
    ("vscode", "VS Code"),
    ("vscode-insiders", "VS Code Insiders"),
    ("vscodium", "VSCodium"),
    ("zed", "Zed"),
    ("antigravity", "Antigravity"),
    ("idea", "IntelliJ IDEA"),
    ("aqua", "Aqua"),
    ("clion", "CLion"),
    ("datagrip", "DataGrip"),
    ("dataspell", "DataSpell"),
    ("goland", "GoLand"),
    ("phpstorm", "PhpStorm"),
    ("pycharm", "PyCharm"),
    ("rider", "Rider"),
    ("rubymine", "RubyMine"),
    ("rustrover", "RustRover"),
    ("webstorm", "WebStorm"),
    ("file-manager", "File Manager"),
];

// Device settings keys.
const LAST_EDITOR: &str = "lastEditor";
const LAST_SCRIPTS: &str = "lastProjectScripts";

/// A new thread's checkout, or the mode picked for a server thread that has
/// not started yet.
#[derive(Clone, Debug, PartialEq)]
pub struct Checkout {
    /// "local" or "worktree".
    pub env_mode: String,
    pub start_from_origin: bool,
    pub branch: Option<String>,
    pub worktree_path: Option<String>,
    /// "Run on" another machine's checkout; empty keeps the draft's own.
    pub environment_id: String,
    pub project_id: String,
}

impl Default for Checkout {
    fn default() -> Self {
        Checkout {
            env_mode: "local".into(),
            start_from_origin: false,
            branch: None,
            worktree_path: None,
            environment_id: String::new(),
            project_id: String::new(),
        }
    }
}

/// Where the route's thread is and what its terminals start in.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Place {
    pub environment_id: String,
    pub thread_id: String,
    pub project_id: String,
    /// Empty for a server thread.
    pub draft_id: String,
    /// Empty while the MC does not know the project.
    pub root: String,
    /// Empty without a worktree.
    pub worktree_path: String,
    pub scripts: Vec<Json>,
}

impl Place {
    pub fn thread_key(&self) -> String {
        format!("{}:{}", self.environment_id, self.thread_id)
    }

    pub fn cwd(&self) -> &str {
        if self.worktree_path.is_empty() {
            &self.root
        } else {
            &self.worktree_path
        }
    }
}

/// The checkout's git status as the MC's `vcs` shape has it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Git {
    pub local: Map<String, Json>,
    /// Empty while unknown.
    pub remote: Map<String, Json>,
}

/// Where a draft's first message starts its thread: the environment and
/// project it runs in, and the MC's `workspaceStrategy` for
/// `orchestration.launchThread` ({type: "root" | "existing_worktree" |
/// "worktree", ...}), or `problem` when it cannot start yet. `tied` when the
/// user chose where it runs (a machine, a branch or a worktree), so it is not
/// placed on another machine.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Launch {
    pub environment_id: String,
    pub project_id: String,
    pub strategy: Map<String, Json>,
    pub problem: String,
    pub tied: bool,
}

type Hook = Rc<dyn Fn(&Engine)>;

/// The workspace's state others read, on the engine.
#[derive(Default)]
struct Shared {
    place: RefCell<Option<Place>>,
    git: RefCell<Option<Git>>,
    git_error: RefCell<String>,
    /// Another machine's `config` while the route is there.
    config_environment: RefCell<String>,
    config_elsewhere: RefCell<Map<String, Json>>,
    checkouts: RefCell<HashMap<String, Checkout>>,
    place_changed: RefCell<Vec<Hook>>,
    git_changed: RefCell<Vec<Hook>>,
    config_changed: RefCell<Vec<Hook>>,
}

fn shared(engine: &Engine) -> Rc<Shared> {
    Bridge::of(engine).extension::<Shared>(engine)
}

/// Runs each hook once no controller is running.
fn emit(engine: &Engine, hooks: &RefCell<Vec<Hook>>) {
    let hooks = hooks.borrow().clone();
    for hook in hooks {
        Bridge::of(engine).defer(engine, move |engine| hook(engine));
    }
}

/// The route's thread or draft: where it is, its root and worktree; none
/// on another page, or for a thread the shell does not list (yet).
pub fn place(engine: &Engine) -> Option<Place> {
    shared(engine).place.borrow().clone()
}

/// The route's checkout status; none while unknown or not followed.
pub fn git(engine: &Engine) -> Option<Git> {
    shared(engine).git.borrow().clone()
}

/// Why the checkout's status could not be followed (a machine that is
/// unreachable).
pub fn git_error(engine: &Engine) -> String {
    shared(engine).git_error.borrow().clone()
}

/// After the route's thread, its root or worktree changed.
pub fn on_place_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    shared(engine).place_changed.borrow_mut().push(Rc::new(f));
}

/// After [`git`] changed.
pub fn on_git_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    shared(engine).git_changed.borrow_mut().push(Rc::new(f));
}

/// After [`environment_config`] may have changed.
pub fn on_config_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    shared(engine).config_changed.borrow_mut().push(Rc::new(f));
}

/// The ServerConfig of the route's environment: the shell's own
/// (`Settings::config`), or the one watched on the other machine the route is
/// on (empty until it arrives, and while that machine is down).
pub fn environment_config(engine: &Engine) -> Map<String, Json> {
    let shared = shared(engine);
    let own = controller::mc(engine).map(|mc| mc.environment());
    let elsewhere = shared
        .place
        .borrow()
        .as_ref()
        .map(|p| p.environment_id.clone())
        .filter(|env| Some(env) != own.as_ref());
    match elsewhere {
        Some(env) if env == *shared.config_environment.borrow() => {
            shared.config_elsewhere.borrow().clone()
        }
        Some(_) => Map::new(),
        None => Settings::of(engine).config(),
    }
}

/// A draft's checkout as the user left it (defaults for one never touched).
pub fn checkout(engine: &Engine, draft_id: &str) -> Checkout {
    shared(engine)
        .checkouts
        .borrow()
        .get(draft_id)
        .cloned()
        .unwrap_or_default()
}

/// Sets a draft's checkout (a new thread on another thread's branch); the
/// workspace follows once no controller is running.
pub fn set_checkout(engine: &Engine, draft_id: &str, checkout: Checkout) {
    shared(engine)
        .checkouts
        .borrow_mut()
        .insert(draft_id.to_owned(), checkout);
    refresh(engine);
}

/// The draft is gone (sent or discarded).
pub fn forget_draft(engine: &Engine, draft_id: &str) {
    shared(engine).checkouts.borrow_mut().remove(draft_id);
}

/// Resolves the route again (a draft moved, say), once no controller is
/// running.
pub fn refresh(engine: &Engine) {
    Bridge::of(engine).defer(engine, |engine| {
        controller::with::<Workspace, _>(engine, |c, engine| c.refresh(engine));
    });
}

/// Asks the MC to read the route's checkout status again.
pub fn refresh_git(engine: &Engine) {
    controller::with::<Workspace, _>(engine, |c, engine| c.refresh_git(engine));
}

/// Opens `path` on the route's environment in `editor_id` (the preferred one
/// when empty), or shows it in the file manager (`reveal`). False when the
/// environment has no such editor, or the workspace is busy.
pub fn open_in_editor(engine: &Engine, editor_id: &str, path: &str, reveal: bool) -> bool {
    controller::with::<Workspace, _>(engine, |c, engine| {
        c.open_in_editor(engine, editor_id, path, reveal)
    })
    .unwrap_or(false)
}

/// The bootstrap of a thread's first turn, from the checkout the header
/// shows: a new worktree off the picked (else current) branch, the worktree
/// picked, or the project folder. A folder that is not a repository always
/// starts in the folder.
pub fn launch(engine: &Engine, draft_id: &str) -> Launch {
    let mut launch = Launch::default();
    let Some(draft) = drafts::draft(engine, draft_id) else {
        launch.problem = "This draft no longer points to an available project.".into();
        return launch;
    };
    let shared = shared(engine);
    let checkout = checkout(engine, draft_id);
    let moved = !checkout.environment_id.is_empty();
    launch.environment_id = if moved {
        checkout.environment_id.clone()
    } else {
        draft.environment_id
    };
    launch.project_id = if moved {
        checkout.project_id.clone()
    } else {
        draft.project_id
    };
    launch.tied = moved || checkout.branch.is_some() || checkout.worktree_path.is_some();
    // The checkout's status is known only for the draft the window shows.
    let shown = shared
        .place
        .borrow()
        .as_ref()
        .is_some_and(|p| p.draft_id == draft_id);
    let git = shared.git.borrow().clone();
    let repo = !(shown && git.as_ref().is_some_and(|g| !is_repo(&g.local)));
    let current = if shown {
        current_branch(git.as_ref())
    } else {
        String::new()
    };
    let branch = checkout
        .branch
        .clone()
        .or_else(|| (!current.is_empty()).then_some(current));
    let with_branch = |mut strategy: Map<String, Json>| {
        if let Some(branch) = &branch {
            strategy.insert("branch".into(), branch.clone().into());
        }
        strategy
    };
    if let Some(worktree) = &checkout.worktree_path {
        launch.strategy = with_branch(object(json!({
            "type": "existing_worktree",
            "worktreePath": worktree,
        })));
    } else if repo && checkout.env_mode == "worktree" {
        let Some(branch) = &branch else {
            launch.problem = "Select a base branch before sending in New worktree mode.".into();
            return launch;
        };
        launch.strategy = object(json!({ "type": "worktree", "baseRef": branch }));
        if checkout.start_from_origin {
            launch
                .strategy
                .insert("startFromOrigin".into(), true.into());
        }
    } else {
        launch.strategy = with_branch(object(json!({ "type": "root" })));
    }
    launch
}

fn object(value: Json) -> Map<String, Json> {
    match value {
        Json::Object(map) => map,
        _ => Map::new(),
    }
}

fn text(row: &Map<String, Json>, key: &str) -> String {
    row.get(key)
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn optional_text(row: &Map<String, Json>, key: &str) -> Option<String> {
    row.get(key)
        .and_then(Json::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn nullable(value: &str) -> Json {
    if value.is_empty() {
        Json::Null
    } else {
        value.into()
    }
}

fn is_repo(local: &Map<String, Json>) -> bool {
    local.get("isRepo").and_then(Json::as_bool).unwrap_or(true)
}

fn current_branch(git: Option<&Git>) -> String {
    match git {
        Some(git) if is_repo(&git.local) => text(&git.local, "refName"),
        _ => String::new(),
    }
}

/// A new ref's name: trimmed, whitespace runs as "-".
fn ref_name(raw: &str) -> String {
    raw.split_whitespace().collect::<Vec<_>>().join("-")
}

/// The local branch of a remote ref: "origin/feature/x" is "feature/x".
fn local_branch_of(remote_ref: &str) -> String {
    match remote_ref.find('/') {
        Some(slash) if slash > 0 && slash + 1 < remote_ref.len() => {
            remote_ref[slash + 1..].to_owned()
        }
        _ => remote_ref.to_owned(),
    }
}

/// BranchToolbar.logic: the machine's own name, unless it is a generic one.
fn primary_label(label: &str) -> String {
    let lowered = label.trim().to_lowercase();
    if lowered.is_empty() || lowered == "local" || lowered == "local environment" {
        "This device".into()
    } else {
        label.trim().to_owned()
    }
}

/// A worktree's temporary branch (`hal-c2/<8 hex>` or `hal-c2/<uuid v4>`),
/// which a thread's branch does not follow.
fn temporary_branch(reference: &str) -> bool {
    let lowered = reference.trim().to_lowercase();
    let Some(rest) = lowered.strip_prefix("hal-c2/") else {
        return false;
    };
    let hex = |s: &str, n: usize| s.len() == n && s.bytes().all(|b| b.is_ascii_hexdigit());
    if hex(rest, 8) {
        return true;
    }
    let parts: Vec<&str> = rest.split('-').collect();
    parts.len() == 5
        && hex(parts[0], 8)
        && hex(parts[1], 4)
        && hex(parts[2], 4)
        && parts[2].starts_with('4')
        && hex(parts[3], 4)
        && parts[3].starts_with(['8', '9', 'a', 'b'])
        && hex(parts[4], 12)
}

/// BranchToolbar.logic resolvePreviousWorktreeSeed's answer.
struct PreviousWorktree {
    branch: Option<String>,
    worktree_path: String,
}

pub struct Workspace {
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    me: Me<Workspace>,
    active: bool,
    published: Option<Json>,

    /// Picked before an empty server thread's first message, by thread key.
    pending: HashMap<String, Checkout>,
    /// The branch a switch is taking the thread to, until the checkout says
    /// so.
    optimistic_branch: Option<String>,
    switching: bool,

    /// The checkout's git status (`vcs` shape).
    vcs: Option<SubId>,
    vcs_key: String,
    /// Editors of environments other than the MC's own (`config` shape); the
    /// MC's own come with `Settings`.
    config: Option<SubId>,

    /// The ref list: loaded when the picker opens or its search changes.
    query: String,
    refs_cwd: String,
    refs: Vec<Json>,
    refs_total: i64,
    /// Where the next page starts; none once the list is whole.
    refs_next_cursor: Option<i64>,
    refs_loading_more: bool,
    refs_loading: bool,
    refs_generation: Rc<Cell<u64>>,

    /// In memory as well as on the device, by project ("env:projectId").
    last_script: HashMap<String, String>,
    rename_request_id: i64,
    /// A thread asked to rename before it was shown.
    rename_wanted: String,
}

impl Drop for Workspace {
    fn drop(&mut self) {
        if let Some(id) = self.vcs.take() {
            self.mc.unsubscribe(id);
        }
        if let Some(id) = self.config.take() {
            self.mc.unsubscribe(id);
        }
    }
}

impl Controller for Workspace {
    fn new(init: Init<'_, Self>) -> Self {
        Workspace {
            bridge: init.bridge,
            mc: init.mc,
            me: init.me,
            active: false,
            published: None,
            pending: HashMap::new(),
            optimistic_branch: None,
            switching: false,
            vcs: None,
            vcs_key: String::new(),
            config: None,
            query: String::new(),
            refs_cwd: String::new(),
            refs: Vec::new(),
            refs_total: 0,
            refs_next_cursor: None,
            refs_loading_more: false,
            refs_loading: false,
            refs_generation: Rc::new(Cell::new(0)),
            last_script: HashMap::new(),
            rename_request_id: 0,
            rename_wanted: String::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let later = |me: &Me<Workspace>, f: fn(&mut Workspace, &Engine)| {
            let me = me.clone();
            move |engine: &Engine| {
                let me = me.clone();
                Bridge::of(engine).defer(engine, move |engine| me.run(engine, f));
            }
        };
        store::on_changed(engine, later(&self.me, Workspace::refresh));
        let route = later(&self.me, Workspace::refresh);
        self.bridge
            .watch(engine, "route", move |engine, _| route(engine));
        // A draft moved, or the one shown went.
        drafts::on_changed(engine, later(&self.me, Workspace::refresh));
        let settings = Settings::of(engine);
        let publish = later(&self.me, Workspace::publish);
        settings.on_config_changed(move |engine| {
            publish(engine);
            emit(engine, &shared(engine).config_changed);
        });
        settings.on_device_changed(later(&self.me, Workspace::publish));
        // The environment's default actions reach every project without its
        // own.
        settings.on_settings_changed(later(&self.me, Workspace::refresh));
        // The Open in shortcut: the route's folder in the preferred editor.
        let commands = Commands::of(engine);
        let open_favorite = "editor.openFavorite";
        let me = self.me.clone();
        commands.add(
            engine,
            open_favorite,
            &crate::keybindings::command_label(open_favorite),
            move |engine| me.run(engine, |c, engine| c.open_here(engine, "")),
        );
        commands.set_listed(engine, open_favorite, false);
        let previous = "composer.previousWorktree";
        let me = self.me.clone();
        commands.add(
            engine,
            previous,
            &crate::keybindings::command_label(previous),
            move |engine| me.run(engine, |c, engine| c.use_previous_worktree(engine)),
        );
        self.refresh(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("workspace.") {
            return false;
        }
        let arg = |key: &str| payload[key].as_str().unwrap_or_default().to_owned();
        if action == "workspace.rename.begin" {
            let thread_key = arg("threadKey");
            if place(engine).is_some_and(|p| p.thread_key() == thread_key) {
                self.rename_request_id += 1;
                self.publish(engine);
            } else {
                // The route is on its way there.
                self.rename_wanted = thread_key;
            }
            return true;
        }
        // The header's project: a new thread there (the drafts' `thread.new`).
        if action == "workspace.newThread" {
            self.bridge.dispatch(engine, "thread.new", Json::Null);
            return true;
        }
        let Some(here) = place(engine) else {
            return true;
        };
        match action {
            "workspace.openPullRequest" => self.open_pull_request(engine),
            "workspace.previousWorktree" => self.use_previous_worktree(engine),
            "workspace.rename" => self.rename(engine, &here, &arg("title")),
            "workspace.openInEditor" => self.open_here(engine, &arg("editorId")),
            "workspace.openFile" => self.open_file_in_editor(engine, &arg("path")),
            "workspace.runScript" => self.run_script(engine, &here, &arg("scriptId")),
            "workspace.branch.search" => {
                self.query = arg("query");
                self.load_refs(engine);
            }
            "workspace.branch.select" => self.select_branch(engine, &here, &arg("name")),
            "workspace.branch.create" => self.create_branch(engine, &here, &arg("name")),
            "workspace.branch.more" => self.load_more_refs(engine),
            "workspace.branch.copy" => {
                // The branch the header names ("Copy branch name").
                let branch = self.build(engine)["branch"]
                    .as_str()
                    .unwrap_or_default()
                    .to_owned();
                if !branch.is_empty() {
                    controller::with::<ThreadMenu, _>(engine, |menu, engine| {
                        menu.copy(
                            engine,
                            &branch,
                            "Branch name copied",
                            "Failed to copy branch name",
                        )
                    });
                }
            }
            "workspace.envMode.set" => self.set_env_mode(engine, &arg("mode")),
            "workspace.startFromOrigin.set" => {
                if !here.draft_id.is_empty() {
                    let enabled = payload["enabled"].as_bool().unwrap_or(false);
                    self.update_checkout(engine, |c| c.start_from_origin = enabled);
                }
            }
            "workspace.environment.set" => {
                let environment_id = arg("environmentId");
                let mut key = arg("key");
                if key.is_empty() {
                    // An older sender names only the machine: its checkout of
                    // this project.
                    key = self
                        .environment_choices(engine)
                        .iter()
                        .find(|c| c["environmentId"].as_str() == Some(environment_id.as_str()))
                        .and_then(|c| c["key"].as_str())
                        .unwrap_or_default()
                        .to_owned();
                }
                self.set_environment(engine, &key);
            }
            _ => {}
        }
        true
    }
}

impl Workspace {
    // --- Where the route is ---------------------------------------------

    fn resolve(&self, engine: &Engine) -> Option<Place> {
        let mut place = Place::default();
        match navigation::shown(engine) {
            Route::Thread(key) => {
                // A thread the shell does not list (yet: a member's rows come
                // once it joins).
                let row = store::with(engine, |s| s.thread_row(&key).cloned())?;
                place.environment_id = key.split_once(':').map_or(key.as_str(), |(e, _)| e).into();
                place.thread_id = text(&row, "id");
                place.project_id = text(&row, "projectId");
                place.worktree_path = optional_text(&row, "worktreePath").unwrap_or_default();
            }
            Route::Draft(id) => {
                let draft = drafts::draft(engine, &id)?;
                let checkout = checkout(engine, &id);
                let moved = !checkout.environment_id.is_empty();
                place.environment_id = if moved {
                    checkout.environment_id
                } else {
                    draft.environment_id
                };
                place.project_id = if moved {
                    checkout.project_id
                } else {
                    draft.project_id
                };
                place.thread_id = draft.thread_id;
                place.draft_id = id;
                place.worktree_path = checkout.worktree_path.unwrap_or_default();
            }
            _ => return None,
        }
        let project = self.project_row(engine, &place);
        place.root = text(&project, "workspaceRoot");
        // Its own actions, else its environment's defaults (Settings →
        // Project, Actions).
        let settings = if place.environment_id == self.mc.environment() {
            Json::Object(Settings::of(engine).settings())
        } else if place.environment_id == *shared(engine).config_environment.borrow() {
            shared(engine)
                .config_elsewhere
                .borrow()
                .get("settings")
                .cloned()
                .unwrap_or(Json::Null)
        } else {
            Json::Null
        };
        let own = project
            .get("scripts")
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        place.scripts = scripts::resolve(&settings, &place.project_id, &own);
        Some(place)
    }

    fn project_row(&self, engine: &Engine, place: &Place) -> Map<String, Json> {
        store::with(engine, |s| {
            s.project_row(&place.environment_id, &place.project_id)
                .cloned()
        })
        .unwrap_or_default()
    }

    fn refresh(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let next = self.resolve(engine);
        let shared = shared(engine);
        let previous = shared.place.replace(next.clone());
        let changed = next != previous;
        let other_thread = match (&next, &previous) {
            (Some(a), Some(b)) => a.thread_key() != b.thread_key(),
            _ => true,
        };
        if other_thread {
            self.optimistic_branch = None;
            self.query.clear();
        }
        if next
            .as_ref()
            .is_some_and(|p| p.thread_key() == self.rename_wanted)
        {
            self.rename_wanted.clear();
            self.rename_request_id += 1;
        }
        self.follow(engine, next.as_ref().map_or("", |p| p.cwd()));
        // Another machine's editors; one that is unreachable ends the watch
        // at once, so it waits for the machine to be back.
        let elsewhere = next
            .as_ref()
            .map(|p| p.environment_id.clone())
            .filter(|env| {
                *env != self.mc.environment() && store::with(engine, |s| s.environment_online(env))
            });
        self.watch_config(engine, elsewhere.as_deref().unwrap_or(""));
        // The row caught up with the switch.
        if self.optimistic_branch.is_some()
            && next.as_ref().is_some_and(|p| p.draft_id.is_empty())
            && optional_text(&self.thread_row(engine), "branch") == self.optimistic_branch
            && !self.switching
        {
            self.optimistic_branch = None;
        }
        if changed {
            emit(engine, &shared.place_changed);
        }
        self.publish(engine);
    }

    fn thread_row(&self, engine: &Engine) -> Map<String, Json> {
        match place(engine) {
            Some(p) if p.draft_id.is_empty() => {
                store::with(engine, |s| s.thread_row(&p.thread_key()).cloned()).unwrap_or_default()
            }
            _ => Map::new(),
        }
    }

    fn set_git(&self, engine: &Engine, git: Option<Git>, error: String) {
        let shared = shared(engine);
        *shared.git.borrow_mut() = git;
        *shared.git_error.borrow_mut() = error;
        emit(engine, &shared.git_changed);
    }

    /// The checkout's status, from the cluster member serving the thread's
    /// environment. It is followed again when the environment comes back
    /// online, since a member that is unreachable ends it at once with its
    /// reason ([`git_error`]).
    fn follow(&mut self, engine: &Engine, cwd: &str) {
        let environment = place(engine).map(|p| p.environment_id).unwrap_or_default();
        let online =
            !environment.is_empty() && store::with(engine, |s| s.environment_online(&environment));
        let key = if environment.is_empty() || cwd.is_empty() {
            String::new()
        } else {
            format!("{environment}\n{cwd}\n{}", if online { 1 } else { 0 })
        };
        if key == self.vcs_key {
            return;
        }
        if let Some(id) = self.vcs.take() {
            self.mc.unsubscribe(id);
        }
        self.vcs_key = key.clone();
        let shared = shared(engine);
        if shared.git.borrow().is_some() || !shared.git_error.borrow().is_empty() {
            self.set_git(engine, None, String::new());
        }
        let had_refs = !self.refs_cwd.is_empty();
        self.refs.clear();
        self.refs_total = 0;
        self.refs_next_cursor = None;
        self.refs_loading_more = false;
        self.refs_cwd.clear();
        self.refs_generation.set(self.refs_generation.get() + 1);
        self.refs_loading = false;
        if key.is_empty() {
            return;
        }
        let me = self.me.clone();
        self.vcs = Some(self.mc.subscribe(
            json!({ "type": "vcs", "environment": environment, "cwd": cwd }),
            Box::new(move |engine, frame| {
                let frame = frame.clone();
                me.run(engine, |c, engine| c.on_vcs(engine, &frame));
            }),
            None,
        ));
        if had_refs {
            self.load_refs(engine);
        }
    }

    fn on_vcs(&mut self, engine: &Engine, frame: &Map<String, Json>) {
        let t = text(frame, "t");
        if t == "error" {
            let reason = match frame.get("reason") {
                Some(Json::String(s)) => s.clone(),
                Some(Json::Null) | None => String::new(),
                Some(other) => other.to_string(),
            };
            self.set_git(engine, None, reason);
            self.publish(engine);
            return;
        }
        if t != "vcs" {
            return;
        }
        let event = frame
            .get("event")
            .and_then(Json::as_object)
            .cloned()
            .unwrap_or_default();
        let field = |key: &str| {
            event
                .get(key)
                .and_then(Json::as_object)
                .cloned()
                .unwrap_or_default()
        };
        let tag = text(&event, "_tag");
        let before = git(engine);
        let previous_ref = before
            .as_ref()
            .map(|g| text(&g.local, "refName"))
            .unwrap_or_default();
        let mut next = before.unwrap_or_default();
        match tag.as_str() {
            "snapshot" => {
                next.local = field("local");
                next.remote = field("remote");
            }
            "localUpdated" => next.local = field("local"),
            "remoteUpdated" => next.remote = field("remote"),
            _ => return,
        }
        let reference = text(&next.local, "refName");
        let error = git_error(engine);
        self.set_git(engine, Some(next), error);
        if tag == "localUpdated" {
            self.follow_checkout(engine, &previous_ref, &reference);
        }
        if !self.switching && self.optimistic_branch.as_deref() == Some(reference.as_str()) {
            self.optimistic_branch = None;
        }
        self.publish(engine);
    }

    /// A thread on another machine has that machine's editors and providers.
    fn watch_config(&mut self, engine: &Engine, environment_id: &str) {
        let shared = shared(engine);
        if *shared.config_environment.borrow() == environment_id {
            return;
        }
        if let Some(id) = self.config.take() {
            self.mc.unsubscribe(id);
        }
        *shared.config_environment.borrow_mut() = environment_id.to_owned();
        shared.config_elsewhere.borrow_mut().clear();
        emit(engine, &shared.config_changed);
        if environment_id.is_empty() {
            return;
        }
        let me = self.me.clone();
        self.config = Some(self.mc.subscribe(
            json!({ "type": "config", "environment": environment_id, "usageLimitsCommand": true }),
            Box::new(move |engine, frame| {
                let frame = frame.clone();
                me.run(engine, |c, engine| c.on_config(engine, &frame));
            }),
            None,
        ));
    }

    fn on_config(&mut self, engine: &Engine, frame: &Map<String, Json>) {
        let shared = shared(engine);
        {
            let mut config = shared.config_elsewhere.borrow_mut();
            match text(frame, "t").as_str() {
                "config" => {
                    *config = frame
                        .get("config")
                        .and_then(Json::as_object)
                        .cloned()
                        .unwrap_or_default();
                }
                "config.providers" => {
                    let providers = frame.get("providers").cloned().unwrap_or(Json::Null);
                    config.insert("providers".into(), providers);
                }
                "config.settings" => {
                    let settings = frame.get("settings").cloned().unwrap_or(Json::Null);
                    config.insert("settings".into(), settings);
                }
                _ => return,
            }
        }
        emit(engine, &shared.config_changed);
        // Its settings resolve the project's actions.
        self.refresh(engine);
    }

    fn list_refs_input(&self, cwd: &str, cursor: Option<i64>) -> Json {
        let mut input = json!({ "cwd": cwd, "limit": 100 });
        if let Some(cursor) = cursor {
            input["cursor"] = cursor.into();
        }
        let query = ref_name(&self.query);
        if !query.is_empty() {
            input["query"] = query.into();
        }
        input
    }

    fn load_refs(&mut self, engine: &Engine) {
        let Some(here) = place(engine).filter(|p| !p.cwd().is_empty()) else {
            return;
        };
        let generation = self.refs_generation.get() + 1;
        self.refs_generation.set(generation);
        self.refs_cwd = here.cwd().to_owned();
        self.refs_loading = self.refs.is_empty();
        let me = self.me.clone();
        let current = self.refs_generation.clone();
        self.mc.call(
            &here.environment_id,
            "vcs.listRefs",
            self.list_refs_input(here.cwd(), None),
            Box::new(move |engine, result| {
                if current.get() != generation {
                    return;
                }
                me.run(engine, |c, engine| {
                    let list = result.ok().and_then(|r| r.as_object().cloned());
                    let list = list.unwrap_or_default();
                    c.refs_loading = false;
                    c.refs = list
                        .get("refs")
                        .and_then(Json::as_array)
                        .cloned()
                        .unwrap_or_default();
                    c.refs_total = list
                        .get("totalCount")
                        .and_then(Json::as_i64)
                        .unwrap_or(c.refs.len() as i64);
                    c.refs_next_cursor = list.get("nextCursor").and_then(Json::as_i64);
                    c.refs_loading_more = false;
                    c.publish(engine);
                });
            }),
        );
        self.publish(engine);
    }

    /// The next page of the ref list, after the ones shown.
    fn load_more_refs(&mut self, engine: &Engine) {
        let Some(here) = place(engine).filter(|p| !p.cwd().is_empty()) else {
            return;
        };
        let Some(cursor) = self.refs_next_cursor else {
            return;
        };
        if self.refs_loading_more || self.refs_loading {
            return;
        }
        let generation = self.refs_generation.get();
        self.refs_loading_more = true;
        let me = self.me.clone();
        let current = self.refs_generation.clone();
        self.mc.call(
            &here.environment_id,
            "vcs.listRefs",
            self.list_refs_input(here.cwd(), Some(cursor)),
            Box::new(move |engine, result| {
                // A search or another checkout started the list over.
                if current.get() != generation {
                    return;
                }
                me.run(engine, |c, engine| {
                    let list = result.ok().and_then(|r| r.as_object().cloned());
                    let list = list.unwrap_or_default();
                    c.refs_loading_more = false;
                    if let Some(refs) = list.get("refs").and_then(Json::as_array) {
                        c.refs.extend(refs.iter().cloned());
                    }
                    c.refs_total = list
                        .get("totalCount")
                        .and_then(Json::as_i64)
                        .unwrap_or(c.refs_total);
                    c.refs_next_cursor = list.get("nextCursor").and_then(Json::as_i64);
                    c.publish(engine);
                });
            }),
        );
    }

    /// The open thread's branch follows its checkout when the checkout it
    /// was on moves to another branch (the agent's `git switch`): a thread
    /// deliberately on another branch is left alone, as is a worktree's
    /// temporary branch.
    fn follow_checkout(&mut self, engine: &Engine, previous_ref: &str, reference: &str) {
        let Some(here) = place(engine).filter(|p| p.draft_id.is_empty()) else {
            return;
        };
        if self.switching
            || previous_ref.is_empty()
            || reference.is_empty()
            || previous_ref == reference
        {
            return;
        }
        if optional_text(&self.thread_row(engine), "branch").as_deref() != Some(previous_ref) {
            return;
        }
        if temporary_branch(reference) {
            return;
        }
        self.mc.dispatch_command(
            &here.environment_id,
            json!({
                "type": "thread.metadata.update",
                "threadId": here.thread_id,
                "branch": reference,
            }),
            Box::new(|_, _| {}),
        );
    }

    // --- What the header shows ------------------------------------------

    fn locked(&self, engine: &Engine) -> bool {
        let row = self.thread_row(engine);
        if row.is_empty() {
            return false;
        }
        let set = |key: &str| match row.get(key) {
            None | Some(Json::Null) => false,
            Some(Json::String(s)) => !s.is_empty(),
            Some(_) => true,
        };
        row.get("itemCount").and_then(Json::as_i64).unwrap_or(0) > 0
            || set("latestUserMessageAt")
            || set("latestRunId")
            || set("activeProviderThreadId")
    }

    /// BranchToolbar.logic resolveEffectiveEnvMode, with the mode picked for
    /// a server thread that has not started yet.
    fn env_mode(&self, engine: &Engine) -> String {
        let Some(here) = place(engine) else {
            return "local".into();
        };
        if !here.draft_id.is_empty() {
            if !here.worktree_path.is_empty() {
                return "local".into();
            }
            return checkout(engine, &here.draft_id).env_mode;
        }
        if !here.worktree_path.is_empty() {
            return "worktree".into();
        }
        if !self.locked(engine)
            && let Some(pending) = self.pending.get(&here.thread_key())
        {
            return pending.env_mode.clone();
        }
        "local".into()
    }

    fn env_mode_changeable(&self, engine: &Engine) -> bool {
        match place(engine) {
            None => false,
            Some(here) if !here.draft_id.is_empty() => true,
            Some(here) => !self.locked(engine) && here.worktree_path.is_empty(),
        }
    }

    fn editors(&self, engine: &Engine) -> Vec<Json> {
        let config = environment_config(engine);
        let available = config
            .get("availableEditors")
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        EDITORS
            .iter()
            .filter(|(id, _)| available.iter().any(|a| a.as_str() == Some(id)))
            .map(|(id, label)| json!({ "id": id, "label": label }))
            .collect()
    }

    /// The one last opened, else the first the machine has.
    fn preferred_editor(&self, engine: &Engine, editors: &[Json]) -> String {
        let Some(first) = editors.first() else {
            return String::new();
        };
        let last = Settings::of(engine).device_value(LAST_EDITOR);
        if let Some(last) = last.as_ref().and_then(Json::as_str)
            && editors.iter().any(|e| e["id"].as_str() == Some(last))
        {
            return last.to_owned();
        }
        first["id"].as_str().unwrap_or_default().to_owned()
    }

    /// BranchToolbar.logic's environment options: this project's checkout on
    /// each machine (projects sharing its repository), the MC's own first. A
    /// draft may also move to any project on a machine without a checkout.
    fn environment_choices(&self, engine: &Engine) -> Vec<Json> {
        let Some(here) = place(engine) else {
            return Vec::new();
        };
        let own = self.mc.environment();
        let canonical = |row: &Map<String, Json>| {
            row.get("repositoryIdentity")
                .and_then(|r| r.get("canonicalKey"))
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let repository = canonical(&self.project_row(engine, &here));
        struct Choice {
            environment_id: String,
            key: String,
            label: String,
            primary: bool,
        }
        let mut checkouts: Vec<Choice> = Vec::new();
        let mut elsewhere: Vec<Choice> = Vec::new();
        let environments = store::with(engine, |s| {
            s.environments()
                .into_iter()
                .map(|env| {
                    let label = text(&s.environment(&env), "label");
                    let projects: Vec<Map<String, Json>> =
                        s.project_rows(&env).into_iter().cloned().collect();
                    (env, label, projects)
                })
                .collect::<Vec<_>>()
        });
        for (environment_id, label, mut projects) in environments {
            let primary = environment_id == own;
            let label = if primary {
                primary_label(&label)
            } else if label.is_empty() {
                environment_id.clone()
            } else {
                label
            };
            projects.sort_by_key(|row| text(row, "title"));
            let checkout = projects.iter().find(|row| {
                (environment_id == here.environment_id && text(row, "id") == here.project_id)
                    || (!repository.is_empty() && canonical(row) == repository)
            });
            if let Some(row) = checkout {
                checkouts.push(Choice {
                    key: format!("{environment_id}:{}", text(row, "id")),
                    environment_id: environment_id.clone(),
                    label,
                    primary,
                });
            } else if !here.draft_id.is_empty() {
                for row in &projects {
                    elsewhere.push(Choice {
                        environment_id: environment_id.clone(),
                        key: format!("{environment_id}:{}", text(row, "id")),
                        label: format!("{label} · {}", text(row, "title")),
                        primary,
                    });
                }
            }
        }
        checkouts.sort_by(|a, b| {
            b.primary
                .cmp(&a.primary)
                .then_with(|| sidebar_model::locale_compare(&a.label, &b.label))
        });
        checkouts
            .into_iter()
            .chain(elsewhere)
            .map(|c| {
                json!({
                    "environmentId": c.environment_id,
                    "key": c.key,
                    "label": c.label,
                })
            })
            .collect()
    }

    fn build(&self, engine: &Engine) -> Json {
        let Some(here) = place(engine) else {
            return Json::Null;
        };
        let draft = !here.draft_id.is_empty();
        let row = self.thread_row(engine);
        let project = self.project_row(engine, &here);
        let checkout = checkout(engine, &here.draft_id);
        let mode = self.env_mode(engine);
        let changeable = self.env_mode_changeable(engine);
        let previous = match self.previous_worktree(engine) {
            Some(seed) => json!({
                "label": match &seed.branch {
                    Some(branch) => format!("Previous worktree ({branch})"),
                    None => "Previous worktree".into(),
                }
            }),
            None => Json::Null,
        };

        // BranchToolbar.logic resolveBranchToolbarValue.
        let thread_branch = if draft {
            checkout.branch.clone()
        } else {
            optional_text(&row, "branch")
        };
        let git = git(engine);
        let current = current_branch(git.as_ref());
        let current = (!current.is_empty()).then_some(current);
        let mut branch = if mode == "worktree" && here.worktree_path.is_empty() {
            thread_branch.or(current)
        } else {
            current.or(thread_branch)
        };
        if self.optimistic_branch.is_some() {
            branch.clone_from(&self.optimistic_branch);
        }

        let mut can_open_pull_request = false;
        let git_state = match &git {
            Some(git) => {
                let pr = git
                    .remote
                    .get("pr")
                    .and_then(Json::as_object)
                    .cloned()
                    .unwrap_or_default();
                let pull_request = if pr.is_empty() {
                    Json::Null
                } else {
                    can_open_pull_request = true;
                    json!({
                        "number": pr.get("number").and_then(Json::as_i64).unwrap_or(0),
                        "title": text(&pr, "title"),
                        "url": text(&pr, "url"),
                        "state": text(&pr, "state"),
                    })
                };
                let flag = |map: &Map<String, Json>, key: &str| {
                    map.get(key).and_then(Json::as_bool).unwrap_or(false)
                };
                let count = |key: &str| git.remote.get(key).and_then(Json::as_i64).unwrap_or(0);
                json!({
                    "isRepo": is_repo(&git.local),
                    "hasWorkingTreeChanges": flag(&git.local, "hasWorkingTreeChanges"),
                    "aheadCount": count("aheadCount"),
                    "behindCount": count("behindCount"),
                    "hasUpstream": flag(&git.remote, "hasUpstream"),
                    "pullRequest": pull_request,
                })
            }
            None => Json::Null,
        };

        let editors = self.editors(engine);
        let project_key = format!("{}:{}", here.environment_id, here.project_id);
        let mut last_script = self
            .last_script
            .get(&project_key)
            .cloned()
            .unwrap_or_default();
        if let Some(Json::Object(last)) = Settings::of(engine).device_value(LAST_SCRIPTS)
            && let Some(value) = last.get(&project_key)
        {
            last_script = value.as_str().unwrap_or_default().to_owned();
        }
        let known = here
            .scripts
            .iter()
            .any(|s| s["id"].as_str() == Some(last_script.as_str()));

        let branches: Vec<Json> = self
            .refs
            .iter()
            .map(|r| {
                let flag = |key: &str| r[key].as_bool().unwrap_or(false);
                json!({
                    "name": r["name"].as_str().unwrap_or_default(),
                    "isRemote": flag("isRemote"),
                    "isDefault": flag("isDefault"),
                    "current": flag("current"),
                })
            })
            .collect();

        let env_mode_label = match (
            changeable,
            mode == "worktree",
            here.worktree_path.is_empty(),
        ) {
            (true, true, _) => "New worktree",
            (true, false, _) => "Current checkout",
            (false, _, true) => "Local checkout",
            (false, _, false) => "Worktree",
        };
        let offline = !store::with(engine, |s| s.environment_online(&here.environment_id));
        json!({
            "threadKey": here.thread_key(),
            "projectTitle": nullable(&text(&project, "title")),
            "projectRoot": nullable(&here.root),
            "threadTitle": if draft { "New thread".to_owned() } else { text(&row, "title") },
            "isDraft": draft,
            "envMode": mode,
            "envModeLabel": env_mode_label,
            "envModeChangeable": changeable,
            "startFromOrigin": checkout.start_from_origin,
            "branch": branch,
            "worktreePath": nullable(&here.worktree_path),
            "git": git_state,
            "canOpenPullRequest": can_open_pull_request,
            "preferredEditorId": nullable(&self.preferred_editor(engine, &editors)),
            "editors": editors,
            "scripts": here.scripts,
            "preferredScriptId": if known { Json::from(last_script) } else { Json::Null },
            "environments": self.environment_choices(engine),
            "activeEnvironmentId": here.environment_id,
            // The MC serving it is out of reach (a cluster member asleep).
            "offline": offline,
            "environmentChangeable": draft,
            "renameRequestId": self.rename_request_id,
            "branchQuery": self.query,
            "branches": branches,
            "branchesTotal": self.refs_total.max(self.refs.len() as i64),
            "branchesLoading": self.refs_loading,
            "branchSwitchPending": self.switching,
            "branchChangeable": !here.cwd().is_empty(),
            "previousWorktree": previous,
        })
    }

    /// BranchToolbar.logic resolvePreviousWorktreeSeed: for a draft, the
    /// worktree of the project's most recently updated unarchived thread
    /// that the draft does not already point at.
    fn previous_worktree(&self, engine: &Engine) -> Option<PreviousWorktree> {
        let here = place(engine).filter(|p| !p.draft_id.is_empty())?;
        store::with(engine, |s| {
            let mut latest: Option<(i64, PreviousWorktree)> = None;
            for thread in s.threads() {
                if thread.environment_id != here.environment_id
                    || thread.project_id != here.project_id
                    || thread.archived_at.is_some()
                {
                    continue;
                }
                let Some(row) = s.thread_row(&thread.key()) else {
                    continue;
                };
                let worktree_path = text(row, "worktreePath");
                let updated_at = sidebar_model::parse_iso(Some(&thread.updated_at));
                let Some(updated_at) = updated_at else {
                    continue;
                };
                if worktree_path.is_empty() || worktree_path == here.worktree_path {
                    continue;
                }
                if latest.as_ref().is_none_or(|(at, _)| updated_at > *at) {
                    let seed = PreviousWorktree {
                        branch: optional_text(row, "branch"),
                        worktree_path,
                    };
                    latest = Some((updated_at, seed));
                }
            }
            latest.map(|(_, seed)| seed)
        })
    }

    /// BranchToolbar's usePreviousWorktree: the draft points at the existing
    /// worktree, as picking a branch checked out there does, and the composer
    /// takes the keyboard back.
    fn use_previous_worktree(&mut self, engine: &Engine) {
        let Some(previous) = self.previous_worktree(engine) else {
            return;
        };
        let Some(here) = place(engine) else {
            return;
        };
        self.set_thread_branch(engine, &here, previous.branch, Some(previous.worktree_path));
        self.bridge
            .send_to_bricks(engine, "composer.focus", &Json::Null);
    }

    fn publish(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        let state = self.build(engine);
        if self.published.as_ref() == Some(&state) {
            return;
        }
        self.published = Some(state.clone());
        self.bridge.publish(engine, "workspace", state);
    }

    // --- What the header does -------------------------------------------

    /// useRenameThread.
    fn rename(&mut self, engine: &Engine, here: &Place, title: &str) {
        if !here.draft_id.is_empty() {
            return;
        }
        let trimmed = title.trim();
        if trimmed.is_empty() {
            controller::with::<Toasts, _>(engine, |t, engine| {
                t.show(
                    engine,
                    "warning",
                    "Thread title cannot be empty",
                    "",
                    None,
                    DEFAULT_TIMEOUT_MS,
                )
            });
            return;
        }
        if trimmed == text(&self.thread_row(engine), "title") {
            return;
        }
        self.mc.dispatch_command(
            &here.environment_id,
            json!({
                "type": "thread.metadata.update",
                "threadId": here.thread_id,
                "title": trimmed,
            }),
            Box::new(|engine, result| {
                if let Err(error) = result {
                    toast_error(engine, "Failed to rename thread", &error);
                }
            }),
        );
    }

    /// The route's folder in `editor_id` (the preferred one when empty).
    fn open_here(&mut self, engine: &Engine, editor_id: &str) {
        if let Some(here) = place(engine) {
            self.open_in_editor(engine, editor_id, here.cwd(), false);
        }
    }

    pub fn open_in_editor(
        &mut self,
        engine: &Engine,
        editor_id: &str,
        path: &str,
        reveal: bool,
    ) -> bool {
        let Some(here) = place(engine) else {
            return false;
        };
        if path.is_empty() {
            return false;
        }
        let available = self.editors(engine);
        let editor = if reveal {
            "file-manager".to_owned()
        } else if editor_id.is_empty() {
            self.preferred_editor(engine, &available)
        } else {
            editor_id.to_owned()
        };
        if !available
            .iter()
            .any(|e| e["id"].as_str() == Some(editor.as_str()))
        {
            return false;
        }
        // Showing a file in its folder is not choosing an editor.
        if !reveal {
            Settings::of(engine).write_device(engine, LAST_EDITOR, editor.clone().into());
        }
        let mut payload = json!({ "cwd": path, "editor": editor });
        if reveal {
            payload["reveal"] = true.into();
        }
        self.mc.call(
            &here.environment_id,
            "shell.openInEditor",
            payload,
            Box::new(|engine, result| {
                if let Err(error) = result {
                    toast_error(engine, "Failed to open in editor.", &error);
                }
            }),
        );
        self.publish(engine);
        true
    }

    /// `path` of the route's checkout (or absolute) in the preferred editor:
    /// a changed file from the diff or the commit review. Says so when there
    /// is no editor to open it in.
    fn open_file_in_editor(&mut self, engine: &Engine, path: &str) {
        let Some(here) = place(engine) else {
            return;
        };
        if path.is_empty() {
            return;
        }
        let cwd = here.cwd();
        let target = if path.starts_with('/') || cwd.is_empty() {
            path.to_owned()
        } else {
            format!("{cwd}/{path}")
        };
        // The same way the Files tab opens one; with no editor it says so.
        if cwd.is_empty() || !self.open_in_editor(engine, "", &target, false) {
            controller::with::<Toasts, _>(engine, |t, engine| {
                t.error(engine, "Editor opening is unavailable.", "")
            });
        }
    }

    /// In the thread's terminal drawer; the one run last is offered first
    /// next time.
    fn run_script(&mut self, engine: &Engine, here: &Place, script_id: &str) {
        let ran =
            controller::with::<Terminals, _>(engine, |t, engine| t.run_script(engine, script_id));
        if ran != Some(true) {
            return;
        }
        let project_key = format!("{}:{}", here.environment_id, here.project_id);
        self.last_script
            .insert(project_key.clone(), script_id.to_owned());
        let settings = Settings::of(engine);
        let mut last = match settings.device_value(LAST_SCRIPTS) {
            Some(Json::Object(last)) => last,
            _ => Map::new(),
        };
        last.insert(project_key, script_id.into());
        settings.write_device(engine, LAST_SCRIPTS, Json::Object(last));
        self.publish(engine);
    }

    fn set_env_mode(&mut self, engine: &Engine, mode: &str) {
        if !self.env_mode_changeable(engine) || (mode != "local" && mode != "worktree") {
            return;
        }
        let Some(here) = place(engine) else {
            return;
        };
        if !here.draft_id.is_empty() {
            self.update_checkout(engine, |c| {
                c.env_mode = mode.to_owned();
                if mode == "worktree" {
                    c.worktree_path = None;
                }
            });
            return;
        }
        self.pending.entry(here.thread_key()).or_default().env_mode = mode.to_owned();
        self.publish(engine);
    }

    /// "Run on": a draft moves to that machine's checkout of the project.
    fn set_environment(&mut self, engine: &Engine, key: &str) {
        let Some(here) = place(engine).filter(|p| !p.draft_id.is_empty()) else {
            return;
        };
        let Some((environment_id, project_id)) = key.split_once(':') else {
            return;
        };
        if environment_id.is_empty() {
            return;
        }
        let known = store::with(engine, |s| {
            s.project_row(environment_id, project_id)
                .is_some_and(|r| !r.is_empty())
        });
        if !known || (environment_id == here.environment_id && project_id == here.project_id) {
            return;
        }
        self.update_checkout(engine, |c| {
            c.environment_id = environment_id.to_owned();
            c.project_id = project_id.to_owned();
            c.branch = None;
            c.worktree_path = None;
        });
    }

    /// useThreadBranchSelection selectBranch.
    fn select_branch(&mut self, engine: &Engine, here: &Place, name: &str) {
        if self.switching || here.cwd().is_empty() || here.root.is_empty() {
            return;
        }
        let Some(reference) = self
            .refs
            .iter()
            .rev()
            .find(|r| r["name"].as_str() == Some(name))
            .cloned()
        else {
            return;
        };
        let active_worktree = here.worktree_path.clone();
        if self.env_mode(engine) == "worktree" && active_worktree.is_empty() && !self.locked(engine)
        {
            // Picking the base of the worktree the thread will start in.
            self.set_thread_branch(engine, here, Some(name.to_owned()), None);
            return;
        }
        // BranchToolbar.logic resolveBranchSelectionTarget.
        let ref_worktree = reference["worktreePath"].as_str().unwrap_or_default();
        if !ref_worktree.is_empty() {
            let worktree = (ref_worktree != here.root).then(|| ref_worktree.to_owned());
            self.set_thread_branch(engine, here, Some(name.to_owned()), worktree);
            return;
        }
        let is_default = reference["isDefault"].as_bool().unwrap_or(false);
        let next_worktree =
            (!active_worktree.is_empty() && !is_default).then(|| active_worktree.clone());
        let checkout_cwd = next_worktree.clone().unwrap_or_else(|| here.root.clone());
        let remote = reference["isRemote"].as_bool().unwrap_or(false);
        let local = if remote {
            local_branch_of(name)
        } else {
            name.to_owned()
        };
        let previous = self.optimistic_branch.replace(local.clone());
        self.switching = true;
        self.publish(engine);
        let thread_key = here.thread_key();
        let me = self.me.clone();
        self.mc.call(
            &here.environment_id,
            "vcs.switchRef",
            json!({ "cwd": checkout_cwd, "refName": name }),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    c.switching = false;
                    let now = place(engine).filter(|p| p.thread_key() == thread_key);
                    match result {
                        Err(error) => {
                            if now.is_some() {
                                c.optimistic_branch = previous;
                            }
                            toast_error(engine, "Failed to switch ref.", &error);
                        }
                        Ok(result) => {
                            if let Some(now) = &now {
                                let switched = result["refName"].as_str();
                                let branch = match switched {
                                    Some(switched) if remote => switched.to_owned(),
                                    _ => local,
                                };
                                c.optimistic_branch = Some(branch.clone());
                                c.set_thread_branch(engine, now, Some(branch), next_worktree);
                            }
                        }
                    }
                    if now.is_some() {
                        c.load_refs(engine);
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    /// useThreadBranchSelection createRef.
    fn create_branch(&mut self, engine: &Engine, here: &Place, raw: &str) {
        let name = ref_name(raw);
        let cwd = here.cwd().to_owned();
        if name.is_empty() || cwd.is_empty() || self.switching {
            return;
        }
        let worktree = (!here.worktree_path.is_empty()).then(|| here.worktree_path.clone());
        let previous = self.optimistic_branch.replace(name.clone());
        self.switching = true;
        self.publish(engine);
        let thread_key = here.thread_key();
        let me = self.me.clone();
        self.mc.call(
            &here.environment_id,
            "vcs.createRef",
            json!({ "cwd": cwd, "refName": name, "switchRef": true }),
            Box::new(move |engine, result| {
                me.run(engine, |c, engine| {
                    c.switching = false;
                    let now = place(engine).filter(|p| p.thread_key() == thread_key);
                    match result {
                        Err(error) => {
                            if now.is_some() {
                                c.optimistic_branch = previous;
                            }
                            toast_error(engine, "Failed to create and switch ref.", &error);
                        }
                        Ok(result) => {
                            if let Some(now) = &now {
                                let created =
                                    result["refName"].as_str().map_or(name, str::to_owned);
                                c.optimistic_branch = Some(created.clone());
                                c.query.clear();
                                c.set_thread_branch(engine, now, Some(created), worktree);
                            }
                        }
                    }
                    if now.is_some() {
                        c.load_refs(engine);
                    }
                    c.publish(engine);
                });
            }),
        );
    }

    /// useThreadBranchSelection setThreadBranch: a server thread's metadata
    /// (its live session stopped when the checkout moves), or the draft's
    /// checkout.
    fn set_thread_branch(
        &mut self,
        engine: &Engine,
        here: &Place,
        branch: Option<String>,
        worktree_path: Option<String>,
    ) {
        let active_worktree = (!here.worktree_path.is_empty()).then(|| here.worktree_path.clone());
        if here.draft_id.is_empty() {
            let row = self.thread_row(engine);
            let session = optional_text(&row, "activeProviderThreadId");
            if session.is_some() && worktree_path != active_worktree {
                self.mc.dispatch_command(
                    &here.environment_id,
                    json!({
                        "type": "provider-session.detach",
                        "threadId": here.thread_id,
                        "reason": "client-requested",
                    }),
                    Box::new(|_, _| {}),
                );
            }
            self.mc.dispatch_command(
                &here.environment_id,
                json!({
                    "type": "thread.metadata.update",
                    "threadId": here.thread_id,
                    "branch": branch,
                    "worktreePath": worktree_path,
                }),
                Box::new(|_, _| {}),
            );
            return;
        }
        // BranchToolbar.logic resolveDraftEnvModeAfterBranchChange.
        let mode = if worktree_path.is_some()
            || (self.env_mode(engine) == "worktree" && active_worktree.is_none())
        {
            "worktree"
        } else {
            "local"
        };
        self.update_checkout(engine, |c| {
            c.branch = branch;
            c.worktree_path = worktree_path;
            c.env_mode = mode.to_owned();
        });
    }

    /// The shown draft's checkout, edited.
    fn update_checkout(&mut self, engine: &Engine, edit: impl FnOnce(&mut Checkout)) {
        let Some(here) = place(engine) else {
            return;
        };
        {
            let shared = shared(engine);
            let mut checkouts = shared.checkouts.borrow_mut();
            edit(checkouts.entry(here.draft_id).or_default());
        }
        self.refresh(engine);
    }

    fn refresh_git(&mut self, engine: &Engine) {
        let Some(here) = place(engine) else {
            return;
        };
        if self.vcs_key.is_empty() {
            return;
        }
        self.mc.call(
            &here.environment_id,
            "vcs.refreshStatus",
            json!({ "cwd": here.cwd() }),
            Box::new(|_, _| {}),
        );
    }

    /// The checkout's pull request, in the browser.
    fn open_pull_request(&mut self, engine: &Engine) {
        let url = git(engine)
            .and_then(|g| {
                g.remote
                    .get("pr")
                    .and_then(|pr| pr["url"].as_str().map(str::to_owned))
            })
            .unwrap_or_default();
        if !url.is_empty() {
            self.bridge.open_external(engine, &url);
        }
    }
}

fn toast_error(engine: &Engine, title: &str, error: &McError) {
    controller::with::<Toasts, _>(engine, |t, engine| t.error(engine, title, &error.message));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_ref_name_joins_whitespace_runs_with_dashes() {
        assert_eq!(ref_name("  my   new\tbranch "), "my-new-branch");
        assert_eq!(ref_name("   "), "");
    }

    #[test]
    fn a_remote_ref_names_its_local_branch_after_the_remote() {
        assert_eq!(local_branch_of("origin/feature/x"), "feature/x");
        assert_eq!(local_branch_of("main"), "main");
        assert_eq!(local_branch_of("/x"), "/x");
        assert_eq!(local_branch_of("origin/"), "origin/");
    }

    #[test]
    fn a_generic_machine_name_reads_this_device() {
        assert_eq!(primary_label(""), "This device");
        assert_eq!(primary_label(" Local Environment "), "This device");
        assert_eq!(primary_label(" studio "), "studio");
    }

    #[test]
    fn worktree_temporary_branches_are_recognised() {
        assert!(temporary_branch("hal-c2/0123abcd"));
        assert!(temporary_branch(
            " HAL-C2/0123abcd-0123-4abc-8def-0123456789ab "
        ));
        assert!(!temporary_branch(
            "hal-c2/0123abcd-0123-5abc-8def-0123456789ab"
        ));
        assert!(!temporary_branch("hal-c2/feature"));
        assert!(!temporary_branch("feature/0123abcd"));
    }
}
