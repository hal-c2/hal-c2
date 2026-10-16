//! `route`, desktop-qt's NavigationController: what the window's centre
//! shows (home, a thread, a draft, settings, pull requests, usage) and the
//! way back and forward.
//!
//! Not ported yet, for want of the store, drafts, plugins and commands:
//! thread titles and locating moved or deleted threads, dropping a sent
//! draft, plugin tabs, the palette's places, and keeping the route between
//! runs. A thread route is shown as named.

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init};
use crate::json::Json;

pub const CLUSTER_SECTION: &str = "/settings/cluster";
pub const KEYBINDINGS_SECTION: &str = "/settings/keybindings";
pub const CONNECTIONS_SECTION: &str = "/settings/connections";
const THREADS_TAB: &str = "threads";
/// Enough to walk back through a session, not a history log.
const BACK_STACK_LIMIT: usize = 50;

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

    fn title(&self) -> &'static str {
        match self {
            Route::Draft(_) => "New thread",
            Route::Settings(_) => "Settings",
            Route::PullRequests => "Pull requests",
            Route::Usage => "Usage",
            Route::Home | Route::Thread(_) => "",
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
}

pub struct Navigation {
    bridge: Bridge,
    active: bool,
    route: Route,
    back_stack: Vec<Route>,
    forward_stack: Vec<Route>,
    target: String,
    target_seq: u64,
    search: String,
    search_seq: u64,
}

impl Controller for Navigation {
    fn new(init: Init<'_, Self>) -> Self {
        Navigation {
            bridge: init.bridge,
            active: false,
            route: Route::Home,
            back_stack: Vec::new(),
            forward_stack: Vec::new(),
            target: String::new(),
            target_seq: 0,
            search: String::new(),
            search_seq: 0,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        self.publish(engine);
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

    pub fn open(&mut self, engine: &Engine, route: Route) {
        self.go(engine, route, false);
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
        let to = take_reachable(&mut self.back_stack, &self.route).unwrap_or_default();
        self.go(engine, to, true);
        if self.route != from {
            self.forward_stack.push(from);
        }
    }

    /// Where back left, as a browser's forward: gone once the user goes
    /// somewhere new.
    pub fn forward(&mut self, engine: &Engine) {
        let mut rest = std::mem::take(&mut self.forward_stack);
        if let Some(to) = take_reachable(&mut rest, &self.route) {
            self.go(engine, to, false);
            self.forward_stack = rest;
        }
    }

    fn back_from(&mut self, engine: &Engine, section: &str) {
        if self.route == Route::Settings(section.into()) {
            self.back(engine);
        }
    }

    fn go(&mut self, engine: &Engine, route: Route, replace: bool) {
        if route == self.route {
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

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let mut state = self.route.json();
        let extra = json!({
            "title": self.route.title(),
            "tab": THREADS_TAB,
            "plugin": null,
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

fn take_reachable(stack: &mut Vec<Route>, current: &Route) -> Option<Route> {
    while let Some(route) = stack.pop() {
        if route != *current {
            return Some(route);
        }
    }
    None
}
