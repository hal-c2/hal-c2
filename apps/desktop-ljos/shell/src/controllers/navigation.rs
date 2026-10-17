//! `route`, desktop-qt's NavigationController: what the window's centre
//! shows (home, a thread, a draft, settings, pull requests, usage) and the
//! way back and forward.
//!
//! The route is kept in the window's `shell-route.json`
//! ([`controller::state_file`]) after every change and read back when the
//! window is made, so the app comes back where it was. Until the MC's rows
//! are in, a restored thread route shows only if the cache lists the thread
//! ([`Controller::preview`]); on activation a thread that moved opens where
//! it lives now, and a thread that was deleted or a draft that was sent or
//! deleted sends the window home. The back and forward stacks do the same
//! to what they hold, and the open thread going away (here or elsewhere)
//! sends the window home too, unless the sidebar is already moving it on
//! (`Sidebar::park`). The route's `title` is the open thread's, which
//! follows a rename.
//!
//! The tabs: "threads" and a tab for each page a plugin adds
//! ([`mc_plugin::pages`]). Opening anything but settings returns to the
//! threads; a page that goes away does too, and a page's tab follows its
//! environment to the version it updates to. `tabs.select {key}`,
//! `tabs.next` and `tabs.previous` choose among them, each page is a
//! `tabs.open:<key>` command in the palette, and `plugin` is the open
//! thread's plugin mark {id, kind}.
//!
//! It adds "Open settings", "Open usage" and "Open pull requests" (listed
//! while an environment has a source control provider) to the palette, and
//! once its route is checked it lands a window with no thread on a draft
//! ([`DraftController::land`]).
//!
//! What another controller reads of the route while Navigation may be
//! running is [`shown`].

use std::path::PathBuf;

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::drafts::{self, DraftController};
use crate::controllers::mc_plugin;
use crate::controllers::sidebar::Sidebar;
use crate::json::Json;
use crate::keybindings::command_label;
use crate::store;

pub const CLUSTER_SECTION: &str = "/settings/cluster";
pub const KEYBINDINGS_SECTION: &str = "/settings/keybindings";
pub const CONNECTIONS_SECTION: &str = "/settings/connections";
pub const PROVIDERS_SECTION: &str = "/settings/providers";
pub const ARCHIVED_SECTION: &str = "/settings/archived";
/// Its commands in `Keybindings.commands`.
pub const OPEN_SETTINGS: &str = "settings.open";
pub const OPEN_USAGE: &str = "usage.open";
pub const OPEN_PULL_REQUESTS: &str = "pullRequests.open";
const THREADS_TAB: &str = "threads";
/// Enough to walk back through a session, not a history log.
const BACK_STACK_LIMIT: usize = 50;

/// Whether a published `route` is `kind` (`usage`, `pullRequests`).
pub fn at_kind(route: &Json, kind: &str) -> bool {
    route.get("kind").and_then(Json::as_str) == Some(kind)
}

/// Whether a published `route` is the settings page at `section`.
pub fn at_section(route: &Json, section: &str) -> bool {
    at_kind(route, "settings") && route.get("section").and_then(Json::as_str) == Some(section)
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Route {
    #[default]
    Home,
    Thread(String),
    Draft(String),
    /// A section path (`/settings/cluster`), empty for the first.
    Settings(String),
    PullRequests,
    Usage,
}

impl Route {
    pub fn kind(&self) -> &'static str {
        match self {
            Route::Home => "home",
            Route::Thread(_) => "thread",
            Route::Draft(_) => "draft",
            Route::Settings(_) => "settings",
            Route::PullRequests => "pullRequests",
            Route::Usage => "usage",
        }
    }

    /// The route a published or saved `{kind, threadKey, draftId, section}`
    /// names, none for a kind that is not one or a thread or draft without
    /// its key. Only the fields the kind has are read, so two ways of saying
    /// one route compare equal.
    pub fn from_json(value: &Json) -> Option<Route> {
        let text = |key: &str| value[key].as_str().unwrap_or_default();
        match value["kind"].as_str()? {
            "home" => Some(Route::Home),
            "thread" if !text("threadKey").is_empty() => {
                Some(Route::Thread(text("threadKey").into()))
            }
            "draft" if !text("draftId").is_empty() => Some(Route::Draft(text("draftId").into())),
            "settings" => Some(Route::Settings(text("section").into())),
            "pullRequests" => Some(Route::PullRequests),
            "usage" => Some(Route::Usage),
            _ => None,
        }
    }

    fn json(&self) -> Json {
        let text = |s: &str| if s.is_empty() { Json::Null } else { json!(s) };
        let (thread, draft, section) = match self {
            Route::Thread(key) => (text(key), Json::Null, Json::Null),
            Route::Draft(id) => (Json::Null, text(id), Json::Null),
            Route::Settings(section) => (Json::Null, Json::Null, text(section)),
            _ => (Json::Null, Json::Null, Json::Null),
        };
        json!({"kind": self.kind(), "threadKey": thread, "draftId": draft, "projectKey": null, "section": section})
    }

    /// The same route with a thread's key as the thread lives under now.
    fn located(self, engine: &Engine) -> Route {
        match self {
            Route::Thread(key) => {
                // No store (no MC yet) answers nothing: the key stays.
                let located = store::with(engine, |s| s.located(&key));
                Route::Thread(if located.is_empty() { key } else { located })
            }
            other => other,
        }
    }
}

pub struct Navigation {
    bridge: Bridge,
    me: Me<Self>,
    active: bool,
    /// A thread route the cache lists is shown before the MC has answered.
    previewing: bool,
    route: Route,
    /// The logical project a settings route was opened for, empty for none.
    /// Only the shown route carries it: going anywhere else clears it.
    project_key: String,
    back_stack: Vec<Route>,
    forward_stack: Vec<Route>,
    /// Where the route is kept between runs; none keeps it for this one.
    store_path: Option<PathBuf>,
    target: String,
    target_seq: u64,
    search: String,
    search_seq: u64,
    /// The open thread's row has been seen, so its absence means it went
    /// away rather than has not arrived yet.
    thread_seen: bool,
    /// The top-level tab shown: "threads", or a plugin page's key.
    tab: String,
    /// The environments the selected page showed, to follow it to its next
    /// version.
    tab_environments: Vec<String>,
    /// The palette entries of the pages, by command.
    page_commands: Vec<String>,
}

impl Controller for Navigation {
    fn new(init: Init<'_, Self>) -> Self {
        // The window title follows the open thread's.
        let me = init.me.clone();
        store::on_changed(init.engine, move |engine| {
            me.run_after(engine, |c, e| c.store_changed(e));
        });
        // Its window's: none keeps the route for this run only.
        let store_path = controller::state_file(init.engine, "shell-route.json");
        let route = store_path
            .as_ref()
            .and_then(|path| std::fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice::<Json>(&bytes).ok())
            .and_then(|saved| Route::from_json(&saved))
            .unwrap_or_default();
        Navigation {
            bridge: init.bridge,
            me: init.me,
            active: false,
            previewing: false,
            route,
            project_key: String::new(),
            back_stack: Vec::new(),
            forward_stack: Vec::new(),
            store_path,
            target: String::new(),
            target_seq: 0,
            search: String::new(),
            search_seq: 0,
            thread_seen: false,
            tab: THREADS_TAB.into(),
            tab_environments: Vec::new(),
            page_commands: Vec::new(),
        }
    }

    /// Shows the thread the window was left on while the sidebar is the
    /// cache's; what a route that names nothing becomes is decided on the
    /// MC's rows ([`Navigation::activate`]), never on cached ones.
    fn preview(&mut self, engine: &Engine) {
        let Route::Thread(key) = &self.route else {
            return;
        };
        if self.active || store::with(engine, |s| s.thread(key)).is_none() {
            return;
        }
        self.previewing = true;
        self.publish(engine);
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        // A thread that moved since the last run opens where it lives now.
        let restored = self.route.clone();
        self.route = restored.clone().located(engine);
        // A thread deleted since the last run is not coming back; one on an
        // environment the MC does not serve yet may still arrive. Nor is a
        // draft that was sent or deleted.
        let gone = match &self.route {
            Route::Thread(key) => thread_gone(engine, key),
            Route::Draft(id) => drafts::draft(engine, id).is_none(),
            _ => false,
        };
        if gone {
            self.route = Route::Home;
        }
        if self.route != restored {
            self.save();
        }
        self.publish(engine);
        self.add_commands(engine);
        let me = self.me.clone();
        mc_plugin::on_pages_changed(engine, move |engine| {
            me.run_after(engine, |c, e| c.follow_pages(e));
        });
        self.follow_pages(engine);
        self.thread_seen = self.shows_listed_thread(engine);
        // With the route checked, a window with no thread lands on a draft.
        Bridge::of(engine).defer(engine, |engine| {
            controller::with::<DraftController, _>(engine, |d, e| d.land(e));
        });
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
        match action {
            "thread.open" => {
                let key = text("key");
                if !key.is_empty() {
                    self.open(engine, Route::Thread(key));
                }
            }
            "tabs.select" => {
                self.select_tab(engine, &text("key"));
            }
            "tabs.next" => self.step_tab(engine, 1),
            "tabs.previous" => self.step_tab(engine, -1),
            "link.open" => {
                self.open_link(engine, &text("url"));
            }
            "draft.open" => {
                let id = text("draftId");
                if !id.is_empty() {
                    self.open(engine, Route::Draft(id));
                }
            }
            "settings.open" => {
                if !matches!(self.route, Route::Settings(_)) {
                    self.open(engine, Route::Settings(String::new()));
                }
            }
            "settings.back" => self.back(engine),
            "settings.search" => {
                if !matches!(self.route, Route::Settings(_)) {
                    self.open(engine, Route::Settings(String::new()));
                }
                self.search = text("query");
                self.search_seq += 1;
                self.publish(engine);
            }
            "pullRequests.open" => self.open(engine, Route::PullRequests),
            "usage.open" => self.open(engine, Route::Usage),
            "cluster.open" => self.open(engine, Route::Settings(CLUSTER_SECTION.into())),
            "cluster.close" => self.back_from(engine, CLUSTER_SECTION),
            "keybindings.open" => self.open(engine, Route::Settings(KEYBINDINGS_SECTION.into())),
            "connections.open" => self.open(engine, Route::Settings(CONNECTIONS_SECTION.into())),
            "connections.close" => self.back_from(engine, CONNECTIONS_SECTION),
            "settings.navigate" | "settings.openResult" => {
                // Any settings section, from anywhere; within settings, one step back.
                let to = text("to");
                if to == "/settings" || to.starts_with("/settings/") {
                    self.open(engine, Route::Settings(to));
                    if action == "settings.openResult" {
                        self.reveal(engine, text("targetId"));
                    }
                }
            }
            _ => return false,
        }
        true
    }
}

impl Navigation {
    pub fn route(&self) -> &Route {
        &self.route
    }

    /// The thread shown, empty when the route is not a thread.
    pub fn thread_key(&self) -> &str {
        match &self.route {
            Route::Thread(key) => key,
            _ => "",
        }
    }

    /// The draft shown, empty when the route is not a draft.
    pub fn draft_id(&self) -> &str {
        match &self.route {
            Route::Draft(id) => id,
            _ => "",
        }
    }

    /// The top-level tab shown: "threads", or a plugin page's key.
    pub fn tab(&self) -> &str {
        &self.tab
    }

    pub fn open(&mut self, engine: &Engine, route: Route) {
        self.go(engine, route, false);
    }

    /// Opens `route` for the logical project `project_key`, which the route
    /// publishes as `projectKey` (the projects page opens on it). Opening
    /// the route already shown for another project moves it there.
    pub fn open_for_project(&mut self, engine: &Engine, route: Route, project_key: String) {
        self.go_with(engine, route, false, project_key);
    }

    /// Goes to `route` in place of the one shown, leaving nothing to go
    /// back to (a parked thread's window moving on, a sent draft).
    pub fn replace(&mut self, engine: &Engine, route: Route) {
        self.go(engine, route, true);
    }

    /// `hal-c2://thread/<environment>/<thread>` opens the thread.
    pub fn open_link(&mut self, engine: &Engine, url: &str) -> bool {
        let Some(path) = url.strip_prefix("hal-c2://thread/") else {
            return false;
        };
        let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
        let [environment, thread] = parts[..] else {
            return false;
        };
        self.open(engine, Route::Thread(format!("{environment}:{thread}")));
        true
    }

    pub fn back(&mut self, engine: &Engine) {
        let from = self.route.clone();
        let to = take_reachable(engine, &mut self.back_stack, &self.route).unwrap_or_default();
        self.go(engine, to, true);
        if self.route != from {
            self.forward_stack.push(from);
        }
    }

    /// Where back left, as a browser's forward: gone once the user goes
    /// somewhere new.
    pub fn forward(&mut self, engine: &Engine) {
        let mut rest = std::mem::take(&mut self.forward_stack);
        if let Some(to) = take_reachable(engine, &mut rest, &self.route) {
            self.go(engine, to, false);
            self.forward_stack = rest;
        }
    }

    /// Shows tab `key` ("threads" or a page's key); false for no such tab.
    pub fn select_tab(&mut self, engine: &Engine, key: &str) -> bool {
        let pages = mc_plugin::pages(engine);
        if !tabs(&pages).iter().any(|tab| tab == key) {
            return false;
        }
        // A tab is chosen to be seen: settings make way for it.
        if matches!(self.route, Route::Settings(_)) {
            self.back(engine);
        }
        self.tab_environments = page_environments(&pages, key);
        if key != self.tab {
            self.tab = key.to_owned();
            self.publish(engine);
        }
        true
    }

    /// Moves `by` tabs along, wrapping.
    fn step_tab(&mut self, engine: &Engine, by: isize) {
        let keys = tabs(&mc_plugin::pages(engine));
        if keys.len() < 2 {
            return;
        }
        let at = keys.iter().position(|key| *key == self.tab).unwrap_or(0) as isize;
        let next = (at + by).rem_euclid(keys.len() as isize) as usize;
        self.select_tab(engine, &keys[next]);
    }

    fn back_from(&mut self, engine: &Engine, section: &str) {
        if self.route == Route::Settings(section.into()) {
            self.back(engine);
        }
    }

    fn go(&mut self, engine: &Engine, route: Route, replace: bool) {
        self.go_with(engine, route, replace, String::new());
    }

    fn go_with(&mut self, engine: &Engine, route: Route, replace: bool, project_key: String) {
        // A key from before the thread moved (a link, a notification, the
        // back stack) opens it where it lives now.
        let route = route.located(engine);
        // Whatever the user opens shows in the threads (settings show over
        // any tab).
        if !replace && !matches!(route, Route::Settings(_)) && self.tab != THREADS_TAB {
            self.tab = THREADS_TAB.into();
            self.publish(engine);
        }
        if route == self.route {
            if !project_key.is_empty() && self.project_key != project_key {
                self.project_key = project_key;
                self.publish(engine);
            }
            return;
        }
        self.target.clear();
        if !matches!(route, Route::Settings(_)) {
            self.search.clear();
        }
        let settings_to_settings = matches!(
            (&route, &self.route),
            (Route::Settings(_), Route::Settings(_))
        );
        // Home is on the way somewhere: back should not return to it, and
        // landing from it keeps where back left.
        let passes_through = self.route == Route::Home;
        if !replace && !passes_through {
            self.forward_stack.clear();
        }
        if !replace && !settings_to_settings && !passes_through {
            let from = self.route.clone();
            self.back_stack.retain(|r| *r != from);
            self.back_stack.push(from);
            if self.back_stack.len() > BACK_STACK_LIMIT {
                self.back_stack.remove(0);
            }
        }
        self.route = route;
        self.project_key = project_key;
        self.thread_seen = self.shows_listed_thread(engine);
        self.save();
        self.publish(engine);
    }

    fn reveal(&mut self, engine: &Engine, target: String) {
        if target.is_empty() {
            return;
        }
        self.target = target;
        self.target_seq += 1;
        self.publish(engine);
    }

    /// Whether the route is a thread the store lists.
    fn shows_listed_thread(&self, engine: &Engine) -> bool {
        match &self.route {
            Route::Thread(key) => store::with(engine, |s| s.thread(key)).is_some(),
            _ => false,
        }
    }

    /// Keeps the route where [`Controller::new`] reads it back from.
    fn save(&self) {
        if let Some(path) = &self.store_path {
            let _ = drafts::write_atomically(path, self.route.json().to_string().as_bytes());
        }
    }

    /// The store changed: the window follows the open thread to where it
    /// lives, or leaves it once it is gone; its title follows a rename.
    fn store_changed(&mut self, engine: &Engine) {
        self.leave_vanished_thread(engine);
        self.publish(engine);
        if self.active {
            offer_pull_requests(engine);
        }
    }

    /// The open thread's row went away: home, unless the sidebar is already
    /// moving the window on (`Sidebar::park`).
    fn leave_vanished_thread(&mut self, engine: &Engine) {
        let Route::Thread(key) = &self.route else {
            return;
        };
        if !self.active {
            return;
        }
        let key = key.clone();
        if store::with(engine, |s| s.thread(&key)).is_some() {
            self.thread_seen = true;
            return;
        }
        // A thread that moved to another machine is followed there.
        let located = store::with(engine, |s| s.located(&key));
        if !located.is_empty() && located != key {
            self.replace(engine, Route::Thread(located));
            return;
        }
        let parking = controller::with::<Sidebar, _>(engine, |s, _| s.parking(&key)) == Some(true);
        if !self.thread_seen || parking {
            return;
        }
        self.replace(engine, Route::Home);
    }

    /// The places the palette offers; they have no default keys.
    fn add_commands(&self, engine: &Engine) {
        let commands = Commands::of(engine);
        let open = |route: Route| {
            move |engine: &Engine| {
                controller::with::<Navigation, _>(engine, |n, e| n.open(e, route.clone()));
            }
        };
        commands.add(
            engine,
            OPEN_SETTINGS,
            "Open settings",
            open(Route::Settings(String::new())),
        );
        commands.add(engine, OPEN_USAGE, "Open usage", open(Route::Usage));
        commands.add(
            engine,
            OPEN_PULL_REQUESTS,
            "Open pull requests",
            open(Route::PullRequests),
        );
        commands.set_terms(
            OPEN_SETTINGS,
            &["settings", "preferences", "configuration", "keybindings"],
        );
        commands.set_terms(
            OPEN_USAGE,
            &[
                "usage",
                "use",
                "tokens",
                "cost",
                "spend",
                "limits",
                "stats",
                "analytics",
            ],
        );
        commands.set_terms(
            OPEN_PULL_REQUESTS,
            &[
                "pull requests",
                "prs",
                "pr",
                "github",
                "review",
                "merge",
                "branch",
            ],
        );
        offer_pull_requests(engine);
        // The tabs: the keys step through them, and each page is in the palette.
        for (command, by) in [("tabs.next", 1), ("tabs.previous", -1)] {
            commands.add(engine, command, &command_label(command), move |engine| {
                controller::with::<Navigation, _>(engine, |n, e| n.step_tab(e, by));
            });
        }
    }

    /// Follows the pages that come and go: their palette entries, and the tab.
    fn follow_pages(&mut self, engine: &Engine) {
        let commands = Commands::of(engine);
        let pages = mc_plugin::pages(engine);
        let mut listed = Vec::new();
        for page in &pages {
            let key = field(page, "key").to_owned();
            let command = format!("tabs.open:{key}");
            commands.add(engine, &command, field(page, "title"), move |engine| {
                controller::with::<Navigation, _>(engine, |n, e| n.select_tab(e, &key));
            });
            commands.set_terms(&command, &[field(page, "pluginName"), "tab", "page"]);
            listed.push(command);
        }
        for gone in &self.page_commands {
            if !listed.contains(gone) {
                commands.remove(engine, gone);
            }
        }
        let several = !listed.is_empty();
        self.page_commands = listed;
        commands.set_listed(engine, "tabs.next", several);
        commands.set_listed(engine, "tabs.previous", several);
        // A page's tab is keyed by its version, so an update keeps the user
        // on the page: on the version the environments they were looking at
        // now run, when another version of it is open too.
        let keys = tabs(&pages);
        if !keys.contains(&self.tab) {
            let page = format!("{}@", self.tab.split('@').next().unwrap_or_default());
            let mut next = THREADS_TAB.to_owned();
            for key in keys.iter().filter(|key| key.starts_with(&page)) {
                let shared = page_environments(&pages, key)
                    .iter()
                    .any(|each| self.tab_environments.contains(each));
                if shared || next == THREADS_TAB {
                    next = key.clone();
                }
                if shared {
                    break;
                }
            }
            self.tab = next;
        }
        self.tab_environments = page_environments(&pages, &self.tab);
        self.publish(engine);
    }

    fn publish(&self, engine: &Engine) {
        if !self.active && !self.previewing {
            return;
        }
        let thread = match &self.route {
            Route::Thread(key) => store::with(engine, |s| s.thread(key)),
            _ => None,
        };
        let mut title = match &self.route {
            Route::Thread(_) => thread.as_ref().map(|t| t.title.clone()).unwrap_or_default(),
            Route::Draft(_) => "New thread".into(),
            Route::Settings(_) => "Settings".into(),
            Route::PullRequests => "Pull requests".into(),
            Route::Usage => "Usage".into(),
            Route::Home => String::new(),
        };
        let plugin = thread.filter(|t| !t.plugin_id.is_empty()).map_or(
            Json::Null,
            |t| json!({"id": t.plugin_id, "kind": t.plugin_kind}),
        );
        // A page shows under its own title, over everything but settings.
        if self.tab != THREADS_TAB && !matches!(self.route, Route::Settings(_)) {
            let pages = mc_plugin::pages(engine);
            if let Some(page) = pages.iter().find(|page| field(page, "key") == self.tab) {
                title = field(page, "title").to_owned();
            }
        }
        let mut state = self.route.json();
        let extra = json!({
            "projectKey": if self.project_key.is_empty() { Json::Null } else { json!(self.project_key) },
            "title": title,
            "tab": self.tab,
            "plugin": plugin,
            "canGoBack": !self.back_stack.is_empty(),
            "target": self.target,
            "targetSeq": self.target_seq,
            "search": self.search,
            "searchSeq": self.search_seq,
        });
        if let (Some(state), Json::Object(extra)) = (state.as_object_mut(), extra) {
            state.extend(extra);
        }
        self.bridge.publish(engine, "route", state);
    }
}

/// The route the window shows, as last published: what a controller reads
/// without borrowing Navigation (which may be the one running).
pub fn shown(engine: &Engine) -> Route {
    Bridge::of(engine)
        .published(engine, "route")
        .and_then(|route| Route::from_json(&route))
        .unwrap_or_default()
}

/// The link [`Navigation::open_link`] opens `thread_key`
/// (`environment:thread`) by.
pub fn thread_link(thread_key: &str) -> String {
    let (environment, thread) = thread_key.split_once(':').unwrap_or(("", thread_key));
    format!("hal-c2://thread/{environment}/{thread}")
}

/// Whether the thread `key` was deleted: the MC serves its environment and
/// lists no such thread. One on an environment the MC does not serve may
/// come back.
fn thread_gone(engine: &Engine, key: &str) -> bool {
    let environment = key.split(':').next().unwrap_or_default();
    store::with(engine, |s| {
        s.serves_environment(environment) && s.thread(key).is_none()
    })
}

/// Offered while some environment has a source control provider for them.
fn offer_pull_requests(engine: &Engine) {
    let offered = store::with(engine, |s| {
        s.environments()
            .iter()
            .any(|id| s.supports(id, "pullRequests"))
    });
    Commands::of(engine).set_listed(engine, OPEN_PULL_REQUESTS, offered);
}

/// Pops the newest place of `stack` the window can go to: not a thread that
/// was deleted since, and not where the window already is.
fn take_reachable(engine: &Engine, stack: &mut Vec<Route>, current: &Route) -> Option<Route> {
    while let Some(route) = stack.pop() {
        let route = route.located(engine);
        let gone = matches!(&route, Route::Thread(key) if thread_gone(engine, key));
        if !gone && route != *current {
            return Some(route);
        }
    }
    None
}

fn field<'a>(page: &'a Json, name: &str) -> &'a str {
    page.get(name).and_then(Json::as_str).unwrap_or_default()
}

/// The tabs: the threads, then each plugin page.
fn tabs(pages: &[Json]) -> Vec<String> {
    std::iter::once(THREADS_TAB.to_owned())
        .chain(pages.iter().map(|page| field(page, "key").to_owned()))
        .collect()
}

/// The environments the page tab `key` shows, none for the threads.
fn page_environments(pages: &[Json], key: &str) -> Vec<String> {
    pages
        .iter()
        .find(|page| field(page, "key") == key)
        .and_then(|page| page.get("environments"))
        .and_then(Json::as_array)
        .map(|environments| {
            environments
                .iter()
                .filter_map(|each| each.as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default()
}
