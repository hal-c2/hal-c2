//! This desktop as the browser agents drive (`previewAutomation`,
//! apps/server-ex lib/hal_c2/preview_automation.ex; packages/contracts
//! previewAutomation.ts): desktop-qt's PreviewAutomationHost.
//!
//! The host offers itself to each MC it is given as one host under one
//! client id, and again whenever the MC ends the subscription. Each MC sends
//! requests for its threads' preview tabs; the page the browser attached for
//! that tab carries them out, and the answer goes back with
//! `previewAutomation.respond` before the request's own deadline, as the MC
//! drops a host that answers late. A status is answered at once. Anything
//! else waits for the tab's previous request: one page, one action at a time.
//! An agent keeps off a page whose developer tools are open, and the user's
//! own input inside the page interrupts what the agent is doing there.
//!
//! The PreviewAutomation controller (controllers/preview_automation.rs)
//! makes the app's host and attaches each browser tab's page.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::{Rc, Weak};
use std::time::Duration;

use ljos::prelude::{Engine, Time, TimerId};
use serde_json::{Map, json};

use crate::controllers::client_activity::now_iso8601;
use crate::json::Json;
use crate::mc::{Frame, Mc, McError, SubId};

/// The tags the MC passes on as they are, or names in its own words. Any
/// other tag reaches the agent as an execution error carrying this host's
/// message, which is why the desktop's own failures have tags of their own.
pub mod tag {
    pub const TAB_NOT_FOUND: &str = "PreviewAutomationTabNotFoundError";
    pub const TIMEOUT: &str = "PreviewAutomationTimeoutError";
    pub const INTERRUPTED: &str = "PreviewAutomationControlInterruptedError";
    pub const INVALID_SELECTOR: &str = "PreviewAutomationInvalidSelectorError";
    pub const NOT_EDITABLE: &str = "PreviewAutomationTargetNotEditableError";
    pub const TOO_LARGE: &str = "PreviewAutomationResultTooLargeError";
    pub const DEV_TOOLS: &str = "PreviewAutomationDevToolsOpenError";
    pub const TARGET_NOT_FOUND: &str = "PreviewAutomationTargetNotFoundError";
    pub const OUTSIDE_VIEWPORT: &str = "PreviewAutomationCoordinatesOutsideViewportError";
    pub const EVALUATION: &str = "PreviewAutomationEvaluationError";
    pub const CONDITION_TIMEOUT: &str = "PreviewAutomationConditionTimeoutError";
    pub const NAVIGATION_TIMEOUT: &str = "PreviewAutomationNavigationTimeoutError";
    pub const REGISTRATION_TIMEOUT: &str = "PreviewAutomationWebviewRegistrationTimeoutError";
    pub const VIEWPORT_BUSY: &str = "PreviewAutomationViewportBusyError";
    pub const VIEWPORT_NOT_RENDERED: &str = "PreviewAutomationViewportNotRenderedError";
    pub const CAPTURE_FAILED: &str = "PreviewAutomationCaptureError";
    pub const TAB_UNAVAILABLE: &str = "PreviewAutomationTabUnavailableError";
    pub const INVALID_INPUT: &str = "PreviewAutomationInvalidInputError";
    pub const SCRIPT: &str = "PreviewAutomationScriptError";
    pub const UNREACHABLE: &str = "PreviewAutomationTargetUnreachableError";
    pub const OPEN_FAILED: &str = "PreviewAutomationOpenError";
    pub const UNSUPPORTED: &str = "PreviewAutomationUnsupportedClientError";
}

/// How long a request may take when the MC names no limit, and the most a
/// wait may ask for (ms).
pub const DEFAULT_WAIT_MS: i64 = 15_000;
pub const MAX_WAIT_MS: i64 = 60_000;
pub const MAX_EVALUATION_BYTES: usize = 64_000;
pub const MAX_SCREENSHOT_WIDTH: u32 = 1280;
/// The most console and network entries a snapshot carries, and the most
/// actions a tab's timeline keeps.
pub const MAX_ENTRIES: usize = 200;
pub const TIMELINE_ENTRIES: usize = 200;
/// Snapshots taken before a page whose secrets keep changing is given up on,
/// and tries at drawing a page, a second each.
const SNAPSHOT_ATTEMPTS: u32 = 3;
const CAPTURE_ATTEMPTS: u32 = 3;
const CAPTURE_ATTEMPT_MS: i64 = 1000;
/// An answer leaves this long before the MC's deadline.
pub const ANSWER_MARGIN_MS: i64 = 300;
/// The cue over a page fades this long after the agent's last action, and
/// the user shows as in control this long after their own input.
pub const IDLE_FADE_MS: i64 = 1500;
pub const USER_CONTROL_MS: i64 = 750;
const POLL_MS: i64 = 100;

/// What this host can do, as it tells each MC. No recording: the MC tells
/// an agent this desktop does not support it.
pub const OPERATIONS: [&str; 12] = [
    "status",
    "open",
    "navigate",
    "snapshot",
    "click",
    "type",
    "press",
    "scroll",
    "evaluate",
    "waitFor",
    "resize",
    "setColorScheme",
];

/// Device sizes as Chrome's developer tools give them, portrait.
pub const PRESETS: [(&str, i32, i32); 17] = [
    ("iphone-se", 375, 667),
    ("iphone-xr", 414, 896),
    ("iphone-12-pro", 390, 844),
    ("iphone-14-pro-max", 430, 932),
    ("pixel-7", 412, 915),
    ("samsung-galaxy-s8-plus", 360, 740),
    ("samsung-galaxy-s20-ultra", 412, 915),
    ("ipad-mini", 768, 1024),
    ("ipad-air", 820, 1180),
    ("ipad-pro", 1024, 1366),
    ("surface-pro-7", 912, 1368),
    ("surface-duo", 540, 720),
    ("galaxy-z-fold-5", 344, 882),
    ("asus-zenbook-fold", 853, 1280),
    ("samsung-galaxy-a51-71", 412, 914),
    ("nest-hub", 1024, 600),
    ("nest-hub-max", 1280, 800),
];

/// Preset `id`'s size in `landscape` or portrait.
pub fn preset(id: &str, landscape: bool) -> Option<(i32, i32)> {
    let &(_, w, h) = PRESETS.iter().find(|(name, ..)| *name == id)?;
    Some(if landscape == (h > w) { (h, w) } else { (w, h) })
}

/// Whether `name` is a key as agents write it (Playwright's): a named key,
/// F1 to F24, or one character.
pub fn known_key(name: &str) -> bool {
    const NAMED: [&str; 15] = [
        "Enter",
        "Tab",
        "Escape",
        "Backspace",
        "Delete",
        "ArrowLeft",
        "ArrowRight",
        "ArrowUp",
        "ArrowDown",
        "Home",
        "End",
        "PageUp",
        "PageDown",
        "Space",
        "Insert",
    ];
    if NAMED.contains(&name) {
        return true;
    }
    if let Some(n) = name.strip_prefix('F').filter(|n| !n.is_empty()) {
        return n.parse::<u32>().is_ok_and(|n| (1..=24).contains(&n));
    }
    name.chars().count() == 1
}

/// What a page's script answered: its JSON string, or None when the page ran
/// none (it went, or refused).
pub type ScriptDone = Box<dyn FnOnce(&Engine, Option<String>)>;

/// A page's picture, {mimeType: "image/png", data (base64), width, height},
/// or None when it could not take one.
pub type GrabDone = Box<dyn FnOnce(&Engine, Option<Json>)>;

/// A tab's page, as the browser shows it.
pub trait AutomationPage {
    /// Runs `script` in the page's own world; `done` gets the string it
    /// returned. `done` may run inside this call.
    fn run_script(&self, engine: &Engine, script: &str, done: ScriptDone);
    fn url(&self, engine: &Engine) -> String;
    fn title(&self, engine: &Engine) -> String;
    fn loading(&self, engine: &Engine) -> bool;
    /// Loads `url`, as the user's own navigation would.
    fn load(&self, engine: &Engine, url: &str);
    fn dev_tools_open(&self, engine: &Engine) -> bool;
    fn on_screen(&self, engine: &Engine) -> bool;
    /// The page's rendered size in CSS pixels, (0, 0) before it has one.
    fn viewport(&self, engine: &Engine) -> (i32, i32);
    /// Runs `script` where it shares the page's document but not its
    /// scripts, so the page cannot change what the runtime calls.
    fn run_isolated(&self, engine: &Engine, script: &str, done: ScriptDone) {
        self.run_script(engine, script, done);
    }
    /// The page's picture as the user would see it.
    fn grab(&self, engine: &Engine, done: GrabDone) {
        done(engine, None);
    }
    /// What the page logged, and the loads of it that failed, oldest first.
    fn console_entries(&self, _engine: &Engine) -> Vec<Json> {
        Vec::new()
    }
    fn failed_loads(&self, _engine: &Engine) -> Vec<Json> {
        Vec::new()
    }
    /// How many loads the page has started, so a navigation knows the new
    /// page's readiness from the old one's.
    fn loads_started(&self, _engine: &Engine) -> u64 {
        0
    }
    /// Whether a size change is outstanding (the user's pick, say).
    fn resizing(&self, _engine: &Engine) -> bool {
        false
    }
    /// The page drawn at `size`, or filling its panel (None).
    fn set_viewport(&self, _engine: &Engine, _size: Option<(i32, i32)>) {}
    /// system, light or dark: the page's prefers-color-scheme.
    fn set_color_scheme(&self, _engine: &Engine, _scheme: &str) {}
}

/// A tab the MC asked for that has no page yet: the browser shows it, and
/// attaches its page. `show` is the agent's wish (None: it said nothing).
#[derive(Clone, Debug, PartialEq)]
pub struct Reveal {
    pub environment_id: String,
    pub thread_id: String,
    pub tab_id: String,
    pub show: Option<bool>,
}

type Then = Box<dyn FnOnce(&Engine)>;
type OnReveal = Rc<dyn Fn(&Engine, &Reveal)>;
type OnActivity = Rc<dyn Fn(&Engine, &Json)>;
type Opened = Rc<dyn Fn(&Engine, String, bool)>;
type RequestRef = Rc<RefCell<Request>>;
type Captured = Box<dyn FnOnce(&Engine, &RequestRef, Json)>;
type Page = Rc<dyn AutomationPage>;
/// One look at a condition: `done(engine, met)`.
type Check = Rc<dyn Fn(&Engine, Box<dyn FnOnce(&Engine, bool)>)>;
type Ends = Rc<RefCell<Option<(Then, Then)>>>;

struct Request {
    environment_id: String,
    connection_id: String,
    request_id: String,
    thread_id: String,
    tab_id: String,
    operation: String,
    input: Json,
    timeout_ms: i64,
    started: Time,
    /// The queues it is in: its tab's, after the thread's when it named no tab.
    queues: Vec<String>,
    /// What it does once it is first in the queue it waits in.
    resume: Option<Then>,
    page: Option<Page>,
    done: bool,
    waiting_for_page: bool,
    deadline: Option<TimerId>,
    /// Its entry in its tab's action timeline, once it acted.
    timeline_id: String,
}

struct Connection {
    environment_id: String,
    subscription: Option<SubId>,
    connection_id: String,
}

struct State {
    mc: Rc<dyn Mc>,
    client_id: String,
    focused: bool,
    connections: HashMap<String, Connection>,
    pages: HashMap<String, Page>,
    /// Requests waiting for their queue, by key; the first is the one running.
    queues: HashMap<String, Vec<RequestRef>>,
    page_waiters: HashMap<String, Vec<Then>>,
    timelines: HashMap<String, Vec<Json>>,
    timeline_ids: u64,
    /// The tab each thread's agent last acted on, for requests that name none.
    current_tabs: HashMap<String, String>,
    /// The size each tab was given, as a PreviewViewportSetting.
    settings: HashMap<String, Json>,
    /// Tabs an agent opened asking not to be shown.
    hidden: HashSet<String>,
    /// What the agent is doing in each tab, for the cue over the page.
    activity: Map<String, Json>,
    /// Bumped by each change to a tab's activity, so a late fade leaves a
    /// newer one.
    activity_generation: HashMap<String, u64>,
    on_reveal: Option<OnReveal>,
    on_activity: Option<OnActivity>,
    evaluations: u64,
}

/// The host; clones are the same host.
#[derive(Clone)]
pub struct PreviewAutomationHost(Rc<RefCell<State>>);

impl PreviewAutomationHost {
    pub fn new(mc: Rc<dyn Mc>, client_id: &str) -> PreviewAutomationHost {
        let host = PreviewAutomationHost(Rc::new(RefCell::new(State {
            mc: mc.clone(),
            client_id: client_id.to_owned(),
            focused: false,
            connections: HashMap::new(),
            pages: HashMap::new(),
            queues: HashMap::new(),
            page_waiters: HashMap::new(),
            timelines: HashMap::new(),
            timeline_ids: 0,
            current_tabs: HashMap::new(),
            settings: HashMap::new(),
            hidden: HashSet::new(),
            activity: Map::new(),
            activity_generation: HashMap::new(),
            on_reveal: None,
            on_activity: None,
            evaluations: 0,
        })));
        // The client offers every subscription again once it is back, and
        // each MC answers with a new connection; until then requests cannot
        // be answered.
        let weak = host.weak();
        mc.on_ready_changed(Box::new(move |_, ready| {
            if let (false, Some(state)) = (ready, weak.upgrade()) {
                for connection in state.borrow_mut().connections.values_mut() {
                    connection.connection_id.clear();
                }
            }
        }));
        host
    }

    fn weak(&self) -> Weak<RefCell<State>> {
        Rc::downgrade(&self.0)
    }

    pub fn client_id(&self) -> String {
        self.0.borrow().client_id.clone()
    }

    /// Runs `f` whenever a request needs a tab shown that may have no page.
    pub fn set_on_reveal(&self, f: impl Fn(&Engine, &Reveal) + 'static) {
        self.0.borrow_mut().on_reveal = Some(Rc::new(f));
    }

    /// Runs `f` with [`Self::activity`] whenever it changes.
    pub fn set_on_activity(&self, f: impl Fn(&Engine, &Json) + 'static) {
        self.0.borrow_mut().on_activity = Some(Rc::new(f));
    }

    /// What the agent is doing in each tab, by tab id: {label, operation,
    /// pointer: {x, y}?, actingSince, userInControl}.
    pub fn activity(&self) -> Json {
        Json::Object(self.0.borrow().activity.clone())
    }

    /// The MCs to offer this host to, as (mc, environment it serves): new
    /// ones are subscribed, gone ones dropped.
    pub fn set_mcs(&self, mcs: &[(String, String)]) {
        let mc = self.0.borrow().mc.clone();
        let mut stale = Vec::new();
        let mut fresh = Vec::new();
        {
            let mut state = self.0.borrow_mut();
            for (name, environment) in mcs {
                match state.connections.get(name) {
                    Some(c) if &c.environment_id == environment => continue,
                    Some(c) => stale.extend(c.subscription),
                    None => {}
                }
                state.connections.insert(
                    name.clone(),
                    Connection {
                        environment_id: environment.clone(),
                        subscription: None,
                        connection_id: String::new(),
                    },
                );
                fresh.push(name.clone());
            }
            state.connections.retain(|name, c| {
                let wanted = mcs.iter().any(|(m, _)| m == name);
                if !wanted {
                    stale.extend(c.subscription);
                }
                wanted
            });
        }
        for id in stale {
            mc.unsubscribe(id);
        }
        for name in fresh {
            self.subscribe(&name);
        }
    }

    /// The app's window has the focus: the MCs prefer the focused desktop.
    pub fn set_focused(&self, focused: bool) {
        let names: Vec<String> = {
            let mut state = self.0.borrow_mut();
            if state.focused == focused {
                return;
            }
            state.focused = focused;
            state.connections.keys().cloned().collect()
        };
        for name in names {
            self.report_focus(&name);
        }
    }

    pub fn focused(&self) -> bool {
        self.0.borrow().focused
    }

    /// The connection `mc` gave this host, empty until it said `connected`.
    pub fn connection_id(&self, mc: &str) -> String {
        let state = self.0.borrow();
        state
            .connections
            .get(mc)
            .map(|c| c.connection_id.clone())
            .unwrap_or_default()
    }

    fn subscribe(&self, name: &str) {
        let (mc, shape) = {
            let state = self.0.borrow();
            let Some(connection) = state.connections.get(name) else {
                return;
            };
            let shape = json!({
                "type": "previewAutomation",
                "mc": name,
                "host": {
                    "clientId": state.client_id,
                    "environmentId": connection.environment_id,
                    "supportedOperations": OPERATIONS,
                },
            });
            (state.mc.clone(), shape)
        };
        let weak = self.weak();
        let owner = name.to_owned();
        let id = mc.subscribe(
            shape,
            Box::new(move |engine, frame| {
                if let Some(state) = weak.upgrade() {
                    PreviewAutomationHost(state).on_frame(engine, &owner, frame);
                }
            }),
            None,
        );
        let mut state = self.0.borrow_mut();
        if let Some(connection) = state.connections.get_mut(name) {
            connection.connection_id.clear();
            connection.subscription = Some(id);
        }
    }

    fn on_frame(&self, engine: &Engine, name: &str, frame: &Frame) {
        let kind = frame.get("t").and_then(Json::as_str).unwrap_or_default();
        if kind == "end" {
            // The MC let this host go (it answered too late, or the MC
            // restarted its broker): offer it again, after a moment so a
            // refusal cannot spin.
            let subscription = {
                let mut state = self.0.borrow_mut();
                let Some(connection) = state.connections.get_mut(name) else {
                    return;
                };
                connection.connection_id.clear();
                connection.subscription
            };
            let weak = self.weak();
            let name = name.to_owned();
            engine.call_at(after(engine, 500), move |_| {
                let Some(state) = weak.upgrade() else { return };
                let host = PreviewAutomationHost(state);
                let same = host
                    .0
                    .borrow()
                    .connections
                    .get(&name)
                    .map(|c| c.subscription)
                    == Some(subscription);
                if same {
                    host.subscribe(&name);
                }
            });
            return;
        }
        if kind != "previewAutomation" {
            return;
        }
        let event = frame.get("event").cloned().unwrap_or(Json::Null);
        match event["type"].as_str() {
            Some("connected") => {
                let id = text(&event["connectionId"]);
                if let Some(c) = self.0.borrow_mut().connections.get_mut(name) {
                    c.connection_id = id;
                }
                self.report_focus(name);
            }
            Some("request") => {
                let mut request = event["request"].clone();
                request["connectionId"] = event["connectionId"].clone();
                self.on_request(engine, name, &request);
            }
            _ => {}
        }
    }

    fn report_focus(&self, name: &str) {
        let (mc, environment_id, payload) = {
            let state = self.0.borrow();
            let Some(connection) = state.connections.get(name) else {
                return;
            };
            if connection.connection_id.is_empty() {
                return;
            }
            let payload = json!({
                "clientId": state.client_id,
                "environmentId": connection.environment_id,
                "connectionId": connection.connection_id,
                "focused": state.focused,
            });
            (state.mc.clone(), connection.environment_id.clone(), payload)
        };
        mc.call(
            &environment_id,
            "previewAutomation.focusHost",
            payload,
            Box::new(|_, _: Result<Json, McError>| {}),
        );
    }

    // Pages.

    /// The page the browser shows for a tab; a page is one tab's at a time.
    pub fn attach(&self, engine: &Engine, thread_id: &str, tab_id: &str, page: Page) {
        if tab_id.is_empty() {
            return;
        }
        if self.page(tab_id).is_some_and(|p| Rc::ptr_eq(&p, &page)) {
            return;
        }
        if let Some(elsewhere) = self.tab_of(&page) {
            self.detach(engine, &elsewhere);
        }
        self.detach(engine, tab_id);
        let waiters = {
            let mut state = self.0.borrow_mut();
            state.pages.insert(tab_id.to_owned(), page);
            state
                .current_tabs
                .entry(thread_id.to_owned())
                .or_insert_with(|| tab_id.to_owned());
            state.page_waiters.remove(tab_id).unwrap_or_default()
        };
        for waiter in waiters {
            waiter(engine);
        }
    }

    /// The tab's page is gone: what was acting on it fails.
    pub fn detach(&self, engine: &Engine, tab_id: &str) {
        let lost: Vec<RequestRef> = {
            let mut state = self.0.borrow_mut();
            if state.pages.remove(tab_id).is_none() {
                return;
            }
            let mut lost: Vec<RequestRef> = Vec::new();
            for request in state.queues.values().flatten() {
                let r = request.borrow();
                if r.tab_id == tab_id
                    && !r.waiting_for_page
                    && !lost.iter().any(|l| Rc::ptr_eq(l, request))
                {
                    lost.push(request.clone());
                }
            }
            lost
        };
        for request in lost {
            self.fail(
                engine,
                &request,
                tag::TAB_UNAVAILABLE,
                &format!("Preview tab {tab_id} is no longer available."),
            );
        }
        self.clear_activity(engine, tab_id);
    }

    /// Whether `tab_id` has a page attached.
    pub fn has_page(&self, tab_id: &str) -> bool {
        self.0.borrow().pages.contains_key(tab_id)
    }

    /// The tabs with a page, and the page each has.
    pub fn attached(&self) -> Vec<(String, Page)> {
        let state = self.0.borrow();
        state
            .pages
            .iter()
            .map(|(tab, page)| (tab.clone(), page.clone()))
            .collect()
    }

    fn page(&self, tab_id: &str) -> Option<Page> {
        self.0.borrow().pages.get(tab_id).cloned()
    }

    fn tab_of(&self, page: &Page) -> Option<String> {
        let state = self.0.borrow();
        state
            .pages
            .iter()
            .find(|(_, p)| Rc::ptr_eq(p, page))
            .map(|(tab, _)| tab.clone())
    }

    fn current_tab(&self, thread_id: &str) -> String {
        self.0
            .borrow()
            .current_tabs
            .get(thread_id)
            .cloned()
            .unwrap_or_default()
    }

    fn reveal(&self, engine: &Engine, reveal: Reveal) {
        let on_reveal = self.0.borrow().on_reveal.clone();
        if let Some(f) = on_reveal {
            f(engine, &reveal);
        }
    }

    /// The tab's page went to another address: the pointer pointed at
    /// something of the old one.
    pub fn url_changed(&self, engine: &Engine, tab_id: &str) {
        let removed = {
            let mut state = self.0.borrow_mut();
            state
                .activity
                .get_mut(tab_id)
                .and_then(Json::as_object_mut)
                .is_some_and(|entry| entry.remove("pointer").is_some())
        };
        if removed {
            self.activity_changed(engine);
        }
    }

    /// The user's own input inside the tab's page: what the agent is doing
    /// there with the pointer or keys stops, and the user shows as in
    /// control for a moment.
    pub fn human_input(&self, engine: &Engine, tab_id: &str) {
        if !self.has_page(tab_id) {
            return;
        }
        let running = self
            .0
            .borrow()
            .queues
            .get(tab_id)
            .and_then(|queue| queue.first().cloned());
        if let Some(running) = running {
            let operation = running.borrow().operation.clone();
            let acting = ["click", "type", "press", "scroll"].contains(&operation.as_str());
            if acting && self.alive(&running) {
                self.fail(
                    engine,
                    &running,
                    tag::INTERRUPTED,
                    &format!(
                        "Preview automation {operation} was interrupted by human input in tab {tab_id}"
                    ),
                );
            }
        }
        let generation = {
            let mut state = self.0.borrow_mut();
            let entry = state
                .activity
                .entry(tab_id.to_owned())
                .or_insert_with(|| json!({}));
            entry["userInControl"] = json!(true);
            let generation = state
                .activity_generation
                .entry(tab_id.to_owned())
                .or_default();
            *generation += 1;
            *generation
        };
        self.activity_changed(engine);
        let host = self.weak();
        let tab = tab_id.to_owned();
        engine.call_at(after(engine, USER_CONTROL_MS), move |engine| {
            let Some(state) = host.upgrade() else { return };
            let host = PreviewAutomationHost(state);
            {
                let mut state = host.0.borrow_mut();
                if state.activity_generation.get(&tab) != Some(&generation) {
                    return;
                }
                let Some(entry) = state.activity.get_mut(&tab) else {
                    return;
                };
                entry["userInControl"] = json!(false);
            }
            host.activity_changed(engine);
            host.clear_activity(engine, &tab);
        });
    }

    // Requests.

    fn on_request(&self, engine: &Engine, name: &str, json: &Json) {
        let environment_id = {
            let state = self.0.borrow();
            state
                .connections
                .get(name)
                .map(|c| c.environment_id.clone())
                .unwrap_or_default()
        };
        let request = Rc::new(RefCell::new(Request {
            environment_id,
            connection_id: text(&json["connectionId"]),
            request_id: text(&json["requestId"]),
            thread_id: text(&json["threadId"]),
            tab_id: text(&json["tabId"]),
            operation: text(&json["operation"]),
            input: json
                .get("input")
                .filter(|i| i.is_object())
                .cloned()
                .unwrap_or_else(|| json!({})),
            timeout_ms: json["timeoutMs"].as_i64().unwrap_or(DEFAULT_WAIT_MS),
            started: engine.now(),
            queues: Vec::new(),
            resume: None,
            page: None,
            done: false,
            waiting_for_page: false,
            deadline: None,
            timeline_id: String::new(),
        }));
        let (id, operation, timeout_ms) = {
            let r = request.borrow();
            (r.request_id.clone(), r.operation.clone(), r.timeout_ms)
        };
        if id.is_empty() {
            return;
        }
        if operation == "status" {
            // At once, whatever else the tab is doing: the MC reads it after
            // every action.
            let tab = {
                let r = request.borrow();
                if r.tab_id.is_empty() {
                    self.current_tab(&r.thread_id)
                } else {
                    r.tab_id.clone()
                }
            };
            let status = self.status(engine, &tab);
            self.finish(engine, &request, Ok(status));
            return;
        }
        // Answered by this host before the MC gives up on it, which would
        // drop it.
        let weak_host = self.weak();
        let weak = Rc::downgrade(&request);
        let deadline = engine.call_at(
            after(engine, (timeout_ms - ANSWER_MARGIN_MS).max(50)),
            move |engine| {
                let (Some(state), Some(request)) = (weak_host.upgrade(), weak.upgrade()) else {
                    return;
                };
                let host = PreviewAutomationHost(state);
                request.borrow_mut().deadline = None;
                let (done, waiting, message) = {
                    let r = request.borrow();
                    let message = if r.waiting_for_page {
                        format!(
                            "Preview webview for request {} on environment {} thread {} did not register within {}ms.",
                            r.request_id, r.environment_id, r.thread_id, r.timeout_ms
                        )
                    } else {
                        format!(
                            "Preview automation {} timed out after {}ms.",
                            r.operation, r.timeout_ms
                        )
                    };
                    (r.done, r.waiting_for_page, message)
                };
                if done {
                    return;
                }
                let tag = if waiting {
                    tag::REGISTRATION_TIMEOUT
                } else {
                    tag::TIMEOUT
                };
                host.fail(engine, &request, tag, &message);
            },
        );
        request.borrow_mut().deadline = Some(deadline);
        // One page, one action at a time; requests that name no tab wait for
        // the thread's others, as they act on whatever tab is current when
        // they start, and then for that tab's turn.
        let queue = {
            let r = request.borrow();
            if r.tab_id.is_empty() {
                format!("thread:{}", r.thread_id)
            } else {
                r.tab_id.clone()
            }
        };
        let host = self.clone();
        let started = request.clone();
        self.enqueue(
            engine,
            &request,
            &queue,
            Box::new(move |engine| host.start(engine, &started)),
        );
    }

    /// Puts `request` in `queue` and runs `then` once it is first there (at
    /// once, when it already is).
    fn enqueue(&self, engine: &Engine, request: &RequestRef, queue: &str, then: Then) {
        if request.borrow().queues.iter().any(|q| q == queue) {
            then(engine);
            return;
        }
        request.borrow_mut().queues.push(queue.to_owned());
        let first = {
            let mut state = self.0.borrow_mut();
            let waiting = state.queues.entry(queue.to_owned()).or_default();
            waiting.push(request.clone());
            waiting.len() == 1
        };
        if first {
            then(engine);
        } else {
            request.borrow_mut().resume = Some(then);
        }
    }

    fn remaining_ms(&self, engine: &Engine, request: &RequestRef) -> i64 {
        let r = request.borrow();
        let elapsed = engine.now().saturating_since(r.started).as_millis() as i64;
        (r.timeout_ms - ANSWER_MARGIN_MS - elapsed).max(0)
    }

    fn start(&self, engine: &Engine, request: &RequestRef) {
        let operation = request.borrow().operation.clone();
        if operation == "open" {
            self.open(engine, request);
            return;
        }
        let tab = {
            let mut r = request.borrow_mut();
            if r.tab_id.is_empty() {
                r.tab_id = self.current_tab(&r.thread_id);
            }
            r.tab_id.clone()
        };
        if tab.is_empty() {
            self.fail(
                engine,
                request,
                tag::TAB_NOT_FOUND,
                &format!("No active preview tab was found for {operation}."),
            );
            return;
        }
        let host = self.clone();
        let acting = request.clone();
        let at = tab.clone();
        self.enqueue(
            engine,
            request,
            &tab,
            Box::new(move |engine| host.act(engine, &acting, &at)),
        );
    }

    /// `request`'s action, on its tab's turn.
    fn act(&self, engine: &Engine, request: &RequestRef, tab: &str) {
        let (environment_id, thread_id) = {
            let r = request.borrow();
            (r.environment_id.clone(), r.thread_id.clone())
        };
        if self.page(tab).is_none() {
            // A tab of the thread this desktop has no page for yet: the
            // browser makes one, out of sight unless the user wants to see
            // what agents do.
            let hidden = self.0.borrow().hidden.contains(tab);
            self.reveal(
                engine,
                Reveal {
                    environment_id: environment_id.clone(),
                    thread_id: thread_id.clone(),
                    tab_id: tab.to_owned(),
                    show: hidden.then_some(false),
                },
            );
        }
        let host = self.clone();
        let acting = request.clone();
        let tab = tab.to_owned();
        self.wait_for_page(
            engine,
            request,
            &tab.clone(),
            Box::new(move |engine| {
                let request = &acting;
                let (operation, page) = {
                    let r = request.borrow();
                    (r.operation.clone(), r.page.clone())
                };
                let Some(page) = page else { return };
                if page.dev_tools_open(engine) {
                    host.fail(
                        engine,
                        request,
                        tag::DEV_TOOLS,
                        &format!(
                            "Preview automation {operation} cannot control tab {tab} while its developer tools are open; close the preview's developer tools before using agent browser control."
                        ),
                    );
                    return;
                }
                let hidden = host.0.borrow().hidden.contains(&tab);
                if !hidden && operation != "snapshot" && operation != "evaluate" {
                    host.reveal(
                        engine,
                        Reveal {
                            environment_id,
                            thread_id: thread_id.clone(),
                            tab_id: tab.clone(),
                            show: None,
                        },
                    );
                }
                host.0.borrow_mut().current_tabs.insert(thread_id, tab.clone());
                host.record(engine, request, "running", "");
                host.set_activity(engine, &tab, &operation);
                match operation.as_str() {
                    "navigate" => host.navigate(engine, request),
                    "snapshot" => host.snapshot(engine, request, 0),
                    "click" => host.click(engine, request),
                    "type" => host.type_text(engine, request),
                    "press" => host.press(engine, request),
                    "scroll" => host.scroll(engine, request),
                    "evaluate" => host.evaluate(engine, request),
                    "waitFor" => host.wait_for(engine, request),
                    "resize" => host.resize(engine, request),
                    "setColorScheme" => host.set_color_scheme(engine, request),
                    _ => {
                        let client = host.client_id();
                        host.fail(
                            engine,
                            request,
                            tag::UNSUPPORTED,
                            &format!(
                                "Preview automation client {client} does not support {operation}."
                            ),
                        );
                    }
                }
            }),
        );
    }

    fn finish(&self, engine: &Engine, request: &RequestRef, outcome: Result<Json, Json>) {
        if request.borrow().done {
            return;
        }
        let failure = outcome.as_ref().err().map(|error| {
            let interrupted = error["_tag"] == tag::INTERRUPTED;
            (interrupted, text(&error["message"]))
        });
        let (response, environment_id, queues, deadline, tab, timeline) = {
            let mut r = request.borrow_mut();
            r.done = true;
            r.waiting_for_page = false;
            r.resume = None;
            let mut response = Map::new();
            response.insert("clientId".into(), json!(self.client_id()));
            response.insert("connectionId".into(), json!(r.connection_id));
            response.insert("requestId".into(), json!(r.request_id));
            response.insert("ok".into(), json!(outcome.is_ok()));
            match outcome {
                Ok(result) => {
                    response.insert("result".into(), result);
                }
                Err(mut error) => {
                    // A failed open names the tab it reached, so the MC can
                    // close one it made.
                    if r.operation == "open" && !r.tab_id.is_empty() && error.get("tabId").is_none()
                    {
                        error["tabId"] = json!(r.tab_id);
                    }
                    response.insert("error".into(), error);
                }
            }
            (
                Json::Object(response),
                r.environment_id.clone(),
                r.queues.clone(),
                r.deadline.take(),
                r.tab_id.clone(),
                !r.timeline_id.is_empty(),
            )
        };
        if let Some(deadline) = deadline {
            engine.cancel_call(deadline);
        }
        if timeline {
            let (status, error) = match &failure {
                None => ("succeeded", String::new()),
                Some((true, message)) => ("interrupted", message.clone()),
                Some((false, message)) => ("failed", message.clone()),
            };
            self.record(engine, request, status, &error);
        }
        let mc = self.0.borrow().mc.clone();
        mc.call(
            &environment_id,
            "previewAutomation.respond",
            response,
            Box::new(|_, _: Result<Json, McError>| {}),
        );
        if queues.is_empty() {
            return;
        }
        if !tab.is_empty() {
            // Fades the cue once the agent has been idle a moment.
            let generation = {
                let mut state = self.0.borrow_mut();
                let generation = state.activity_generation.entry(tab.clone()).or_default();
                *generation += 1;
                *generation
            };
            let host = self.weak();
            engine.call_at(after(engine, IDLE_FADE_MS), move |engine| {
                let Some(state) = host.upgrade() else { return };
                let host = PreviewAutomationHost(state);
                let same = host.0.borrow().activity_generation.get(&tab) == Some(&generation);
                if same {
                    host.clear_activity(engine, &tab);
                }
            });
        }
        let mut next = Vec::new();
        {
            let mut state = self.0.borrow_mut();
            for key in queues {
                let Some(queue) = state.queues.get_mut(&key) else {
                    continue;
                };
                let was_running = queue
                    .first()
                    .is_some_and(|first| Rc::ptr_eq(first, request));
                queue.retain(|each| !Rc::ptr_eq(each, request));
                if queue.is_empty() {
                    state.queues.remove(&key);
                } else if was_running {
                    next.push(queue[0].clone());
                }
            }
        }
        for request in next {
            engine.call_at(engine.now(), move |engine| {
                let resume = {
                    let mut r = request.borrow_mut();
                    if r.done { None } else { r.resume.take() }
                };
                if let Some(resume) = resume {
                    resume(engine);
                }
            });
        }
    }

    fn succeed(&self, engine: &Engine, request: &RequestRef, result: Json) {
        self.finish(engine, request, Ok(result));
    }

    fn fail(&self, engine: &Engine, request: &RequestRef, tag: &str, message: &str) {
        self.fail_with(engine, request, tag, message, Json::Null);
    }

    fn fail_with(
        &self,
        engine: &Engine,
        request: &RequestRef,
        tag: &str,
        message: &str,
        detail: Json,
    ) {
        let mut error = json!({"_tag": tag, "message": message});
        if !detail.is_null() {
            error["detail"] = detail;
        }
        self.finish(engine, request, Err(error));
    }

    // Helpers the operations share. Each continuation runs only while the
    // request is still unanswered and its page still attached.

    fn alive(&self, request: &RequestRef) -> bool {
        let r = request.borrow();
        !r.done
            && r.page
                .as_ref()
                .is_some_and(|page| self.page(&r.tab_id).is_some_and(|p| Rc::ptr_eq(&p, page)))
    }

    /// The request's page while it is alive.
    fn page_of(&self, request: &RequestRef) -> Option<Page> {
        if !self.alive(request) {
            return None;
        }
        request.borrow().page.clone()
    }

    fn after(
        &self,
        engine: &Engine,
        request: &RequestRef,
        ms: i64,
        then: impl FnOnce(&Engine) + 'static,
    ) {
        let host = self.clone();
        let request = request.clone();
        engine.call_at(after(engine, ms), move |engine| {
            if host.alive(&request) {
                then(engine);
            }
        });
    }

    /// Looks at `check` every 100 ms until it is met (`then`) or `wait_ms`
    /// pass (`timed_out`).
    fn poll(
        &self,
        engine: &Engine,
        request: &RequestRef,
        wait_ms: i64,
        check: Check,
        then: Then,
        timed_out: Then,
    ) {
        let since = engine.now();
        let ends: Ends = Rc::new(RefCell::new(Some((then, timed_out))));
        self.poll_step(engine, request.clone(), since, wait_ms, check, ends);
    }

    fn poll_step(
        &self,
        engine: &Engine,
        request: RequestRef,
        since: Time,
        wait_ms: i64,
        check: Check,
        ends: Ends,
    ) {
        let host = self.clone();
        let again = check.clone();
        check(
            engine,
            Box::new(move |engine, met| {
                if !host.alive(&request) {
                    return;
                }
                let waited = engine.now().saturating_since(since).as_millis() as i64;
                if met || waited >= wait_ms {
                    let end = ends.borrow_mut().take();
                    if let Some((then, timed_out)) = end {
                        if met { then(engine) } else { timed_out(engine) }
                    }
                    return;
                }
                let step = host.clone();
                let r = request.clone();
                host.after(engine, &request, POLL_MS, move |engine| {
                    step.poll_step(engine, r, since, wait_ms, again, ends);
                });
            }),
        );
    }

    fn wait_for_page(&self, engine: &Engine, request: &RequestRef, tab_id: &str, then: Then) {
        if let Some(page) = self.page(tab_id) {
            request.borrow_mut().page = Some(page);
            then(engine);
            return;
        }
        request.borrow_mut().waiting_for_page = true;
        let host = self.clone();
        let waiting = request.clone();
        let tab = tab_id.to_owned();
        self.0
            .borrow_mut()
            .page_waiters
            .entry(tab_id.to_owned())
            .or_default()
            .push(Box::new(move |engine| {
                if waiting.borrow().done {
                    return;
                }
                let page = host.page(&tab);
                {
                    let mut r = waiting.borrow_mut();
                    r.waiting_for_page = false;
                    r.page = page.clone();
                }
                if page.is_some() {
                    then(engine);
                }
            }));
    }

    fn rendered_viewport(&self, engine: &Engine, page: &Page) -> Json {
        let (width, height) = page.viewport(engine);
        json!({"width": width.max(1), "height": height.max(1)})
    }

    // The operations.

    fn status(&self, engine: &Engine, tab_id: &str) -> Json {
        let page = self.page(tab_id);
        let mut result = json!({
            "available": page.is_some(),
            "visible": page.as_ref().is_some_and(|p| p.on_screen(engine)),
            "tabId": if tab_id.is_empty() { Json::Null } else { json!(tab_id) },
            "url": page.as_ref().map_or(Json::Null, |p| json!(p.url(engine))),
            "title": page.as_ref().map_or(Json::Null, |p| json!(p.title(engine))),
            "loading": page.as_ref().is_some_and(|p| p.loading(engine)),
        });
        if let Some(setting) = self.0.borrow().settings.get(tab_id) {
            result["viewportSetting"] = setting.clone();
        }
        if let Some(page) = page {
            let (width, height) = page.viewport(engine);
            if width > 0 && height > 0 {
                result["viewport"] = self.rendered_viewport(engine, &page);
            }
        }
        result
    }

    fn tab_status(&self, engine: &Engine, request: &RequestRef) -> Json {
        let tab = request.borrow().tab_id.clone();
        self.status(engine, &tab)
    }

    fn open(&self, engine: &Engine, request: &RequestRef) {
        let (input, environment_id, thread_id, tab_id) = {
            let r = request.borrow();
            (
                r.input.clone(),
                r.environment_id.clone(),
                r.thread_id.clone(),
                r.tab_id.clone(),
            )
        };
        let wish = input.get("open").or_else(|| input.get("show"));
        let show = wish.and_then(Json::as_bool);
        let reuse = input["reuseExistingTab"].as_bool().unwrap_or(true);
        let Some(url) = self.address(engine, request) else {
            return;
        };

        let opened: Opened = {
            let host = self.clone();
            let request = request.clone();
            let url = url.clone();
            let environment_id = environment_id.clone();
            let thread_id = thread_id.clone();
            Rc::new(move |engine: &Engine, tab: String, load: bool| {
                request.borrow_mut().tab_id = tab.clone();
                {
                    let mut state = host.0.borrow_mut();
                    state.current_tabs.insert(thread_id.clone(), tab.clone());
                    match show {
                        Some(false) => {
                            state.hidden.insert(tab.clone());
                        }
                        Some(true) => {
                            state.hidden.remove(&tab);
                        }
                        None => {}
                    }
                }
                host.reveal(
                    engine,
                    Reveal {
                        environment_id: environment_id.clone(),
                        thread_id: thread_id.clone(),
                        tab_id: tab.clone(),
                        show,
                    },
                );
                // Loading is an action on the tab: it waits for the tab's turn.
                let (h, r, u, t) = (host.clone(), request.clone(), url.clone(), tab.clone());
                host.enqueue(
                    engine,
                    &request,
                    &tab,
                    Box::new(move |engine| {
                        let (h2, r2) = (h.clone(), r.clone());
                        h.wait_for_page(
                            engine,
                            &r,
                            &t.clone(),
                            Box::new(move |engine| {
                                h2.record(engine, &r2, "running", "");
                                let page = r2.borrow().page.clone();
                                if let (true, false, Some(page)) = (load, u.is_empty(), page) {
                                    page.load(engine, &u);
                                }
                                let status = h2.status(engine, &t);
                                h2.succeed(engine, &r2, status);
                            }),
                        );
                    }),
                );
            })
        };

        let existing = if !reuse {
            String::new()
        } else if tab_id.is_empty() {
            self.current_tab(&thread_id)
        } else {
            tab_id
        };
        if !existing.is_empty() {
            opened(engine, existing, true);
            return;
        }
        // A new tab of the thread: the MC makes it, so every client sees it.
        let mut payload = json!({"threadId": thread_id});
        if !url.is_empty() {
            payload["url"] = json!(url);
        }
        let host = self.clone();
        let request = request.clone();
        let mc = self.0.borrow().mc.clone();
        mc.call(
            &environment_id,
            "preview.open",
            payload,
            Box::new(move |engine, result| {
                if request.borrow().done {
                    return;
                }
                let tab = result
                    .as_ref()
                    .map(|r| text(&r["tabId"]))
                    .unwrap_or_default();
                if result.is_err() || tab.is_empty() {
                    let why = result
                        .err()
                        .map_or_else(|| "no tab came back".to_owned(), |e| e.message);
                    let thread = request.borrow().thread_id.clone();
                    host.fail(
                        engine,
                        &request,
                        tag::OPEN_FAILED,
                        &format!("Preview tab for thread {thread} could not be opened: {why}"),
                    );
                    return;
                }
                opened(engine, tab, false);
            }),
        );
    }

    /// The address an open or navigate names: a dev-server `target` wins
    /// over `url`. Fails the request and returns None when it names none it
    /// can reach; an empty address is none at all.
    fn address(&self, engine: &Engine, request: &RequestRef) -> Option<String> {
        let (input, environment_id) = {
            let r = request.borrow();
            (r.input.clone(), r.environment_id.clone())
        };
        let target = &input["target"];
        if !target.as_object().is_some_and(|t| !t.is_empty()) {
            return Some(text(&input["url"]));
        }
        if target["kind"] == "url" {
            return Some(text(&target["url"]));
        }
        // A port of the environment's machine, which only this machine's own
        // MC is reached by name from here.
        let mc = self.0.borrow().mc.clone();
        if environment_id != mc.environment() {
            self.fail(
                engine,
                request,
                tag::UNREACHABLE,
                &format!(
                    "Ports of environment {environment_id} are not reachable from this desktop; navigate to a url instead."
                ),
            );
            return None;
        }
        let mut host = mc.origin().map(|o| origin_host(&o)).unwrap_or_default();
        if host.is_empty() || host == "127.0.0.1" {
            host = "localhost".into();
        }
        let protocol = target["protocol"].as_str().unwrap_or("http");
        let port = target["port"].as_i64().unwrap_or(0);
        let path = target["path"].as_str().unwrap_or("/");
        Some(format!("{protocol}://{host}:{port}{path}"))
    }

    fn navigate(&self, engine: &Engine, request: &RequestRef) {
        let Some(url) = self.address(engine, request) else {
            return;
        };
        if scheme(&url).is_none() {
            self.fail(
                engine,
                request,
                tag::INVALID_INPUT,
                &format!("Preview navigation needs an absolute url, not {url}."),
            );
            return;
        }
        let Some(page) = self.page_of(request) else {
            return;
        };
        let readiness = request.borrow().input["readiness"]
            .as_str()
            .unwrap_or("load")
            .to_owned();
        // Readiness counts from the new page: the old one is done loading
        // already.
        let before = page.loads_started(engine);
        page.load(engine, &url);
        let started = Rc::new(Cell::new(page.loading(engine)));
        if readiness == "none" {
            let status = self.tab_status(engine, request);
            self.succeed(engine, request, status);
            return;
        }
        let wait_ms = self.remaining_ms(engine, request);
        let wanted = readiness.clone();
        let check: Check = Rc::new(move |engine, done| {
            if page.loading(engine) || page.loads_started(engine) > before {
                started.set(true);
            }
            if !started.get() || (wanted == "load" && page.loading(engine)) {
                return done(engine, false);
            }
            let wanted = wanted.clone();
            page.run_isolated(
                engine,
                &script::call("ready", &json!({})),
                Box::new(move |engine, result| {
                    let answer = script::parse(result.as_deref());
                    let state = answer["value"]["readyState"].as_str().unwrap_or_default();
                    done(
                        engine,
                        if wanted == "load" {
                            state == "complete"
                        } else {
                            state == "interactive" || state == "complete"
                        },
                    );
                }),
            );
        });
        let (host, done_request) = (self.clone(), request.clone());
        let (late, late_request) = (self.clone(), request.clone());
        self.poll(
            engine,
            request,
            wait_ms,
            check,
            Box::new(move |engine| {
                let status = host.tab_status(engine, &done_request);
                host.succeed(engine, &done_request, status);
            }),
            Box::new(move |engine| {
                let message = {
                    let r = late_request.borrow();
                    format!(
                        "Preview navigation for request {} on environment {} thread {} tab {} did not reach {readiness} readiness within {wait_ms}ms.",
                        r.request_id, r.environment_id, r.thread_id, r.tab_id
                    )
                };
                late.fail(engine, &late_request, tag::NAVIGATION_TIMEOUT, &message);
            }),
        );
    }

    fn evaluate(&self, engine: &Engine, request: &RequestRef) {
        let Some(page) = self.page_of(request) else {
            return;
        };
        let key = {
            let mut state = self.0.borrow_mut();
            state.evaluations += 1;
            format!(
                "__halc2Evaluation{}_{}",
                state.evaluations,
                &hal_c2_mc::new_uuid()[..8]
            )
        };
        let (expression, await_promise) = {
            let r = request.borrow();
            (
                text(&r.input["expression"]),
                r.input["awaitPromise"].as_bool().unwrap_or(true),
            )
        };
        let host = self.clone();
        let asked = request.clone();
        let polled = page.clone();
        page.run_script(
            engine,
            &script::evaluate(&expression, &key, MAX_EVALUATION_BYTES),
            Box::new(move |engine, result| {
                let request = &asked;
                if !host.alive(request) {
                    return;
                }
                let outcome = script::parse(result.as_deref());
                if outcome.as_object().is_none_or(|o| o.is_empty()) {
                    // The page refused to run it at all (a policy against eval).
                    let tab = request.borrow().tab_id.clone();
                    host.fail(
                        engine,
                        request,
                        tag::EVALUATION,
                        &format!(
                            "Preview JavaScript evaluation failed in tab {tab}: the page did not run the script"
                        ),
                    );
                    return;
                }
                if outcome["pending"] != json!(true) {
                    host.evaluated(engine, request, &outcome);
                    return;
                }
                if !await_promise {
                    host.succeed(engine, request, json!({}));
                    return;
                }
                let settled = Rc::new(RefCell::new(Json::Null));
                let check: Check = {
                    let settled = settled.clone();
                    Rc::new(move |engine, done| {
                        let settled = settled.clone();
                        polled.run_script(
                            engine,
                            &script::settled(&key),
                            Box::new(move |engine, result| {
                                let outcome = script::parse(result.as_deref());
                                let met = outcome.as_object().is_some_and(|o| !o.is_empty());
                                *settled.borrow_mut() = outcome;
                                done(engine, met);
                            }),
                        );
                    })
                };
                let wait_ms = host.remaining_ms(engine, request);
                let (h, r) = (host.clone(), request.clone());
                let (late, late_request) = (host.clone(), request.clone());
                host.poll(
                    engine,
                    request,
                    wait_ms,
                    check,
                    Box::new(move |engine| {
                        let outcome = settled.borrow().clone();
                        h.evaluated(engine, &r, &outcome);
                    }),
                    Box::new(move |engine| {
                        let timeout = late_request.borrow().timeout_ms;
                        late.fail(
                            engine,
                            &late_request,
                            tag::TIMEOUT,
                            &format!("Preview automation evaluate timed out after {timeout}ms."),
                        );
                    }),
                );
            }),
        );
    }

    /// The page's text, controls and picture. A page whose password fields
    /// (or what it draws as dots) changed between reading its text and
    /// drawing its picture may show what the text hid, so it is read again.
    fn snapshot(&self, engine: &Engine, request: &RequestRef, attempt: u32) {
        let host = self.clone();
        self.runtime(engine, request, "snapshot", json!({}), move |engine, request, value| {
            host.clone().capture(engine, request, 0, Box::new(move |engine, request, shot| {
                host.clone().runtime(engine, request, "secrets", json!({}), move |engine, request, now| {
                    if now["print"] != value["secrets"] {
                        if attempt + 1 < SNAPSHOT_ATTEMPTS {
                            host.snapshot(engine, request, attempt + 1);
                        } else {
                            let tab = request.borrow().tab_id.clone();
                            host.fail(
                                engine,
                                request,
                                tag::CAPTURE_FAILED,
                                &format!(
                                    "Preview tab {tab} was too busy to read safely: its password fields changed while each of {SNAPSHOT_ATTEMPTS} snapshots was taken."
                                ),
                            );
                        }
                        return;
                    }
                    let Some(page) = host.page_of(request) else { return };
                    let tab = request.borrow().tab_id.clone();
                    let timeline = host.0.borrow().timelines.get(&tab).cloned().unwrap_or_default();
                    let mut result = value;
                    let mut network = result["networkEntries"].as_array().cloned().unwrap_or_default();
                    network.extend(page.failed_loads(engine));
                    let over = network.len().saturating_sub(MAX_ENTRIES);
                    network.drain(..over);
                    if let Some(fields) = result.as_object_mut() {
                        fields.remove("viewport");
                        fields.remove("secrets");
                        fields.insert("tabId".into(), json!(tab));
                        fields.insert("networkEntries".into(), Json::Array(network));
                        fields.insert("consoleEntries".into(), Json::Array(page.console_entries(engine)));
                        fields.insert("actionTimeline".into(), Json::Array(timeline));
                        fields.insert("screenshot".into(), shot);
                    }
                    host.succeed(engine, request, result);
                });
            }));
        });
    }

    /// The page's picture, no wider than MAX_SCREENSHOT_WIDTH: three tries,
    /// a second each, as a page that was just shown may not have drawn.
    fn capture(self, engine: &Engine, request: &RequestRef, attempt: u32, then: Captured) {
        let Some(page) = self.page_of(request) else {
            return;
        };
        let settled = Rc::new(Cell::new(false));
        let then = Rc::new(RefCell::new(Some(then)));
        let retry = {
            let (host, request, settled, then) =
                (self.clone(), request.clone(), settled.clone(), then.clone());
            Rc::new(move |engine: &Engine| {
                if settled.replace(true) || !host.alive(&request) {
                    return;
                }
                if attempt + 1 >= CAPTURE_ATTEMPTS {
                    let tab = request.borrow().tab_id.clone();
                    host.fail(
                        engine,
                        &request,
                        tag::CAPTURE_FAILED,
                        &format!(
                            "Preview tab {tab} could not be captured after {CAPTURE_ATTEMPTS} attempts."
                        ),
                    );
                    return;
                }
                let Some(then) = then.borrow_mut().take() else {
                    return;
                };
                let again = host.clone();
                let r = request.clone();
                host.after(engine, &request, 100, move |engine| {
                    again.capture(engine, &r, attempt + 1, then);
                });
            })
        };
        let late = retry.clone();
        self.after(engine, request, CAPTURE_ATTEMPT_MS, move |engine| {
            late(engine)
        });
        let host = self.clone();
        let request = request.clone();
        page.grab(
            engine,
            Box::new(move |engine, shot| {
                if settled.get() || !host.alive(&request) {
                    return;
                }
                let Some(shot) = shot else {
                    return retry(engine);
                };
                settled.set(true);
                if let Some(then) = then.borrow_mut().take() {
                    then(engine, &request, narrowed(shot, MAX_SCREENSHOT_WIDTH));
                }
            }),
        );
    }

    fn click(&self, engine: &Engine, request: &RequestRef) {
        let args = pick(&request.borrow().input, &["selector", "locator", "x", "y"]);
        let (has_x, has_y) = (args.get("x").is_some(), args.get("y").is_some());
        if has_x != has_y {
            return self.fail(
                engine,
                request,
                tag::INVALID_INPUT,
                "A click at a point needs both x and y.",
            );
        }
        if args.as_object().is_none_or(|a| a.is_empty()) {
            return self.fail(
                engine,
                request,
                tag::INVALID_INPUT,
                "A click needs a locator, a selector, or x and y.",
            );
        }
        if has_x {
            let Some(page) = self.page_of(request) else {
                return;
            };
            let x = args["x"].as_f64().unwrap_or(0.0);
            let y = args["y"].as_f64().unwrap_or(0.0);
            let (width, height) = page.viewport(engine);
            if x < 0.0 || y < 0.0 || x >= f64::from(width) || y >= f64::from(height) {
                let tab = request.borrow().tab_id.clone();
                return self.fail(
                    engine,
                    request,
                    tag::OUTSIDE_VIEWPORT,
                    &format!(
                        "Click coordinates ({x}, {y}) are outside the {width}x{height} preview viewport for tab {tab}"
                    ),
                );
            }
        }
        let host = self.clone();
        self.runtime(
            engine,
            request,
            "clickTarget",
            args.clone(),
            move |engine, request, target| {
                host.set_pointer(engine, request, &target);
                // TODO(hal-c2/ljos-ui#459): desktop-qt clicks as a user would
                // (landing on whatever covers the element) when the page is
                // on screen; Ljós cannot send a live view a click yet, so the
                // click is the page script's.
                let settle = if target["scrolled"] == json!(true) {
                    60
                } else {
                    0
                };
                let by_script = host.clone();
                let r = request.clone();
                host.after(engine, request, settle, move |engine| {
                    let done = by_script.clone();
                    by_script.runtime(
                        engine,
                        &r,
                        "clickScript",
                        args,
                        move |engine, request, _| {
                            let status = done.tab_status(engine, request);
                            done.succeed(engine, request, status);
                        },
                    );
                });
            },
        );
    }

    fn type_text(&self, engine: &Engine, request: &RequestRef) {
        let args = {
            let input = &request.borrow().input;
            let mut args = pick(input, &["selector", "locator"]);
            args["text"] = json!(text(&input["text"]));
            args["clear"] = json!(input["clear"].as_bool().unwrap_or(false));
            args
        };
        // Text goes in as the page's own editing would put it (insertText),
        // not as keystrokes: one undoable insertion, the same with any
        // keyboard layout.
        let host = self.clone();
        self.runtime(
            engine,
            request,
            "type",
            args,
            move |engine, request, value| {
                host.set_pointer(engine, request, &value);
                let status = host.tab_status(engine, request);
                host.succeed(engine, request, status);
            },
        );
    }

    fn press(&self, engine: &Engine, request: &RequestRef) {
        let (name, held) = {
            let input = &request.borrow().input;
            let held: Vec<String> = input["modifiers"]
                .as_array()
                .map(|m| m.iter().map(text).collect())
                .unwrap_or_default();
            (text(&input["key"]), held)
        };
        if !known_key(&name) {
            return self.fail(
                engine,
                request,
                tag::INVALID_INPUT,
                &format!("Preview automation press does not know the key {name}."),
            );
        }
        let holds = |m: &str| held.iter().any(|h| h == m);
        let args = json!({
            "key": name,
            "alt": holds("Alt"),
            "control": holds("Control"),
            "meta": holds("Meta"),
            "shift": holds("Shift"),
        });
        // TODO(hal-c2/ljos-ui#459): desktop-qt presses the key in the view
        // when the page is on screen, so the page's editing takes it too;
        // Ljós cannot send a live view a key yet, so the page's scripts see
        // the press and its editing does not, as off screen.
        let host = self.clone();
        self.runtime(
            engine,
            request,
            "armKey",
            json!({}),
            move |engine, request, _| {
                let done = host.clone();
                host.runtime(
                    engine,
                    request,
                    "keyScript",
                    args,
                    move |engine, request, _| {
                        let status = done.tab_status(engine, request);
                        done.succeed(engine, request, status);
                    },
                );
            },
        );
    }

    fn scroll(&self, engine: &Engine, request: &RequestRef) {
        let args = pick(
            &request.borrow().input,
            &["selector", "locator", "deltaX", "deltaY"],
        );
        let host = self.clone();
        self.runtime(
            engine,
            request,
            "scroll",
            args,
            move |engine, request, value| {
                if value.get("x").is_some() {
                    host.set_pointer(engine, request, &value);
                }
                let mut result = host.tab_status(engine, request);
                result["scrollX"] = value["scrollX"].clone();
                result["scrollY"] = value["scrollY"].clone();
                host.succeed(engine, request, result);
            },
        );
    }

    fn wait_for(&self, engine: &Engine, request: &RequestRef) {
        let (asked, args) = {
            let input = &request.borrow().input;
            (
                input["timeoutMs"].as_i64().unwrap_or(DEFAULT_WAIT_MS),
                pick(input, &["selector", "locator", "text", "urlIncludes"]),
            )
        };
        if asked > MAX_WAIT_MS {
            return self.fail(
                engine,
                request,
                tag::INVALID_INPUT,
                &format!("A wait may be at most {MAX_WAIT_MS} milliseconds, not {asked}."),
            );
        }
        if args.as_object().is_none_or(|a| a.is_empty()) {
            return self.fail(
                engine,
                request,
                tag::INVALID_INPUT,
                "Provide at least one wait condition.",
            );
        }
        let Some(page) = self.page_of(request) else {
            return;
        };
        let wait_ms = asked.min(self.remaining_ms(engine, request));
        let check: Check = {
            let (host, request) = (self.clone(), request.clone());
            Rc::new(move |engine, done| {
                let (host, request) = (host.clone(), request.clone());
                page.run_isolated(
                    engine,
                    &script::call("check", &args),
                    Box::new(move |engine, result| {
                        if !host.alive(&request) {
                            return;
                        }
                        let answer = script::parse(result.as_deref());
                        // A navigation in between drops the script's answer:
                        // try again.
                        if answer.as_object().is_none_or(|a| a.is_empty()) {
                            done(engine, false);
                        } else if answer["ok"] != json!(true) {
                            host.fail_target(engine, &request, &answer);
                        } else {
                            done(engine, answer["value"] == json!(true));
                        }
                    }),
                );
            })
        };
        let (host, done_request) = (self.clone(), request.clone());
        let (late, late_request) = (self.clone(), request.clone());
        self.poll(
            engine,
            request,
            wait_ms,
            check,
            Box::new(move |engine| {
                let status = host.tab_status(engine, &done_request);
                host.succeed(engine, &done_request, status);
            }),
            Box::new(move |engine| {
                let tab = late_request.borrow().tab_id.clone();
                late.fail(
                    engine,
                    &late_request,
                    tag::CONDITION_TIMEOUT,
                    &format!("Preview condition did not match within {wait_ms}ms in tab {tab}"),
                );
            }),
        );
    }

    fn resize(&self, engine: &Engine, request: &RequestRef) {
        let input = request.borrow().input.clone();
        let (setting, size) = match input["mode"].as_str().unwrap_or_default() {
            "fill" => (json!({"_tag": "fill"}), None),
            "freeform" => {
                let width = input["width"].as_i64().unwrap_or(0) as i32;
                let height = input["height"].as_i64().unwrap_or(0) as i32;
                (
                    json!({"_tag": "freeform", "width": width, "height": height}),
                    Some((width, height)),
                )
            }
            "preset" => {
                let id = text(&input["preset"]);
                let landscape = input["orientation"] == "landscape";
                let Some((width, height)) = preset(&id, landscape) else {
                    return self.fail(
                        engine,
                        request,
                        tag::INVALID_INPUT,
                        &format!("Unknown viewport preset {id}."),
                    );
                };
                (
                    json!({"_tag": "preset", "presetId": id, "width": width, "height": height}),
                    Some((width, height)),
                )
            }
            _ => (Json::Null, None),
        };
        if setting.is_null() || size.is_some_and(|(w, h)| w <= 0 || h <= 0) {
            return self.fail(
                engine,
                request,
                tag::INVALID_INPUT,
                "Viewport mode must be fill, freeform or preset.",
            );
        }
        let Some(page) = self.page_of(request) else {
            return;
        };
        let tab = request.borrow().tab_id.clone();
        // One size at a time: the page ignores a request while one is
        // outstanding (a person's pick, say), so say so now instead of
        // timing out unanswered.
        if page.resizing(engine) {
            return self.fail(
                engine,
                request,
                tag::VIEWPORT_BUSY,
                &format!("A size change is already in progress in tab {tab}; try again."),
            );
        }
        self.0
            .borrow_mut()
            .settings
            .insert(tab.clone(), setting.clone());
        page.set_viewport(engine, size);
        let wait_ms = self.remaining_ms(engine, request);
        // Within a pixel: a fractional device scale rounds the drawn size.
        let drawn = page.clone();
        let check: Check = Rc::new(move |engine, done| {
            let (w, h) = drawn.viewport(engine);
            done(
                engine,
                match size {
                    None => w > 0 && h > 0,
                    Some((width, height)) => (w - width).abs() <= 1 && (h - height).abs() <= 1,
                },
            );
        });
        let (host, done_request) = (self.clone(), request.clone());
        let (late, late_request) = (self.clone(), request.clone());
        let (width, height) = size.unwrap_or_default();
        self.poll(
            engine,
            request,
            wait_ms,
            check,
            Box::new(move |engine| {
                let viewport = host.rendered_viewport(engine, &page);
                let tab = done_request.borrow().tab_id.clone();
                host.succeed(
                    engine,
                    &done_request,
                    json!({"tabId": tab, "setting": setting, "viewport": viewport}),
                );
            }),
            Box::new(move |engine| {
                let tab = late_request.borrow().tab_id.clone();
                late.fail(
                    engine,
                    &late_request,
                    tag::VIEWPORT_NOT_RENDERED,
                    &format!(
                        "Preview viewport for tab {tab} was not rendered at {width}x{height} within {wait_ms}ms."
                    ),
                );
            }),
        );
    }

    fn set_color_scheme(&self, engine: &Engine, request: &RequestRef) {
        let scheme = text(&request.borrow().input["colorScheme"]);
        if !["system", "light", "dark"].contains(&scheme.as_str()) {
            return self.fail(
                engine,
                request,
                tag::INVALID_INPUT,
                "The color scheme must be system, light or dark.",
            );
        }
        let Some(page) = self.page_of(request) else {
            return;
        };
        page.set_color_scheme(engine, &scheme);
        let tab = request.borrow().tab_id.clone();
        self.succeed(
            engine,
            request,
            json!({"tabId": tab, "colorScheme": scheme}),
        );
    }

    /// Runs the automation runtime's `name` in the page; `then` gets its
    /// value, and a failure fails the request.
    fn runtime(
        &self,
        engine: &Engine,
        request: &RequestRef,
        name: &str,
        args: Json,
        then: impl FnOnce(&Engine, &RequestRef, Json) + 'static,
    ) {
        let Some(page) = self.page_of(request) else {
            return;
        };
        let host = self.clone();
        let asked = request.clone();
        page.run_isolated(
            engine,
            &script::call(name, &args),
            Box::new(move |engine, result| {
                if !host.alive(&asked) {
                    return;
                }
                let mut answer = script::parse(result.as_deref());
                if answer["ok"] != json!(true) {
                    host.fail_target(engine, &asked, &answer);
                    return;
                }
                then(engine, &asked, answer["value"].take());
            }),
        );
    }

    /// The runtime's failure, as the agent is told it.
    fn fail_target(&self, engine: &Engine, request: &RequestRef, answer: &Json) {
        let (operation, tab, target, aimed) = {
            let r = request.borrow();
            let aimed = r.input.get("selector").is_some() || r.input.get("locator").is_some();
            (
                r.operation.clone(),
                r.tab_id.clone(),
                target_label(&r.input),
                aimed,
            )
        };
        let reason = text(&answer["reason"]);
        let (tag, message) = match answer["kind"].as_str().unwrap_or_default() {
            "invalid" => (
                tag::INVALID_SELECTOR,
                format!("Preview automation {operation} rejected {target} in tab {tab}: {reason}"),
            ),
            "missing" => (
                tag::TARGET_NOT_FOUND,
                format!("Preview automation {operation} could not find {target} in tab {tab}"),
            ),
            "notEditable" if aimed => (
                tag::NOT_EDITABLE,
                format!(
                    "Preview automation {operation} found {target}, but it is not editable in tab {tab}"
                ),
            ),
            "notEditable" => (
                tag::NOT_EDITABLE,
                format!(
                    "Preview automation {operation} needs an editable target in tab {tab}; the focused element is not editable"
                ),
            ),
            "error" => (
                tag::SCRIPT,
                format!("Preview automation {operation} failed in tab {tab}: {reason}"),
            ),
            // No answer at all: the page went, or navigated away mid-script.
            _ => (
                tag::TAB_UNAVAILABLE,
                format!("Preview automation {operation} lost tab {tab}'s page before it answered."),
            ),
        };
        self.fail(engine, request, tag, &message);
    }

    fn evaluated(&self, engine: &Engine, request: &RequestRef, outcome: &Json) {
        let tab = request.borrow().tab_id.clone();
        if let Some(error) = outcome.get("error") {
            let message = format!(
                "Preview JavaScript evaluation failed in tab {tab}: {}",
                text(error)
            );
            self.fail(engine, request, tag::EVALUATION, &message);
        } else if let Some(bytes) = outcome.get("tooLarge") {
            let message = format!(
                "Preview evaluation result in tab {tab} was {bytes} bytes; maximum is {MAX_EVALUATION_BYTES} bytes"
            );
            let detail = json!({"maximumBytes": MAX_EVALUATION_BYTES});
            self.fail_with(engine, request, tag::TOO_LARGE, &message, detail);
        } else if let Some(value) = outcome.get("value") {
            let value = serde_json::from_str(&text(value)).unwrap_or(Json::Null);
            self.succeed(engine, request, value);
        } else {
            self.succeed(engine, request, Json::Null);
        }
    }

    // What the user sees.

    /// The request's entry in its tab's action timeline: made the first
    /// time, then updated.
    fn record(&self, engine: &Engine, request: &RequestRef, status: &str, error: &str) {
        let (tab, id, operation) = {
            let r = request.borrow();
            (r.tab_id.clone(), r.timeline_id.clone(), r.operation.clone())
        };
        if tab.is_empty() {
            return;
        }
        let now = now_iso8601(engine);
        let mut state = self.0.borrow_mut();
        if id.is_empty() {
            state.timeline_ids += 1;
            let id = format!("action-{}", state.timeline_ids);
            request.borrow_mut().timeline_id = id.clone();
            let timeline = state.timelines.entry(tab).or_default();
            timeline.push(json!({
                "id": id, "action": operation, "status": status, "startedAt": now,
            }));
            let over = timeline.len().saturating_sub(TIMELINE_ENTRIES);
            timeline.drain(..over);
            return;
        }
        let Some(entry) = state
            .timelines
            .get_mut(&tab)
            .and_then(|t| t.iter_mut().rev().find(|e| e["id"] == id.as_str()))
        else {
            return;
        };
        entry["status"] = json!(status);
        if status != "running" {
            entry["completedAt"] = json!(now);
        }
        if !error.is_empty() {
            entry["error"] = json!(error);
        }
    }

    fn set_activity(&self, engine: &Engine, tab: &str, operation: &str) {
        let now = now_iso8601(engine);
        {
            let mut state = self.0.borrow_mut();
            *state.activity_generation.entry(tab.to_owned()).or_default() += 1;
            let entry = state
                .activity
                .entry(tab.to_owned())
                .or_insert_with(|| json!({}));
            entry["label"] = json!("Agent is using this tab");
            entry["operation"] = json!(operation);
            if entry.get("actingSince").is_none() {
                entry["actingSince"] = json!(now);
            }
            if entry.get("userInControl").is_none() {
                entry["userInControl"] = json!(false);
            }
        }
        self.activity_changed(engine);
    }

    /// The pointer at the `{x, y}` in `at`, where the request acted.
    fn set_pointer(&self, engine: &Engine, request: &RequestRef, at: &Json) {
        let tab = request.borrow().tab_id.clone();
        {
            let mut state = self.0.borrow_mut();
            let entry = state.activity.entry(tab).or_insert_with(|| json!({}));
            entry["pointer"] = json!({
                "x": at["x"].as_f64().unwrap_or(0.0),
                "y": at["y"].as_f64().unwrap_or(0.0),
            });
        }
        self.activity_changed(engine);
    }

    fn clear_activity(&self, engine: &Engine, tab: &str) {
        {
            let attached = self.has_page(tab);
            let mut state = self.0.borrow_mut();
            let Some(entry) = state.activity.remove(tab) else {
                return;
            };
            // The pointer stays where the agent last acted, as the page
            // shows it.
            if let (Some(pointer), true) = (entry.get("pointer"), attached) {
                let kept = json!({"pointer": pointer, "userInControl": entry["userInControl"]});
                state.activity.insert(tab.to_owned(), kept);
            }
        }
        self.activity_changed(engine);
    }

    fn activity_changed(&self, engine: &Engine) {
        let f = self.0.borrow().on_activity.clone();
        if let Some(f) = f {
            f(engine, &self.activity());
        }
    }
}

/// A client id that is the same every run for the desktop on this machine
/// that keeps its state in `home`, and another for one that keeps it
/// elsewhere: the MC keeps one host per id and drops the one it replaces, so
/// the installed desktop and a dev build on one machine must not share one.
pub fn machine_client_id(home: &str) -> String {
    let machine = crate::this_machine::raw_id()
        .filter(|id| !id.is_empty())
        .or_else(|| crate::this_machine::host_name().map(String::into_bytes))
        .unwrap_or_default();
    client_id_of(&machine, home)
}

fn client_id_of(machine: &[u8], home: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(b"hal-c2-desktop:");
    hasher.update(machine);
    hasher.update(b"\n");
    hasher.update(clean_path(home).as_bytes());
    let hex: String = hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    format!("desktop-{}", &hex[..24])
}

/// `path` as Qt's QDir::cleanPath gives it: no `.`, no `..` that can be
/// resolved, no repeated or trailing separator.
fn clean_path(path: &str) -> String {
    if path.is_empty() {
        return String::new();
    }
    let absolute = path.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." if parts.last().is_some_and(|p| *p != "..") => {
                parts.pop();
            }
            ".." if absolute => {}
            part => parts.push(part),
        }
    }
    let joined = parts.join("/");
    match (absolute, joined.is_empty()) {
        (true, _) => format!("/{joined}"),
        (false, true) => ".".to_owned(),
        (false, false) => joined,
    }
}

fn after(engine: &Engine, ms: i64) -> Time {
    engine.now() + Duration::from_millis(ms.max(0) as u64)
}

fn text(value: &Json) -> String {
    value.as_str().unwrap_or_default().to_owned()
}

/// The fields of `input` named in `keys`, as an object.
fn pick(input: &Json, keys: &[&str]) -> Json {
    let mut picked = Map::new();
    for key in keys {
        if let Some(value) = input.get(*key) {
            picked.insert((*key).to_owned(), value.clone());
        }
    }
    Json::Object(picked)
}

/// What an action aimed at, as its failure names it: never the locator or
/// selector itself, which may carry what the agent typed.
pub fn target_label(input: &Json) -> String {
    let chars = |key: &str| text(&input[key]).chars().count();
    if input.get("locator").is_some() {
        format!("locator ({} characters)", chars("locator"))
    } else if input.get("selector").is_some() {
        format!("selector ({} characters)", chars("selector"))
    } else if input.get("x").is_some() {
        let x = input["x"].as_f64().unwrap_or(0.0);
        let y = input["y"].as_f64().unwrap_or(0.0);
        format!("point ({x}, {y})")
    } else {
        "the focused element".to_owned()
    }
}

/// A url's scheme (`https` of `https://…`), None for a relative one.
fn scheme(url: &str) -> Option<&str> {
    let (scheme, _) = url.split_once(':')?;
    let mut chars = scheme.chars();
    let valid = chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c));
    valid.then_some(scheme)
}

/// `shot` (a PNG picture) scaled down to `max_width` when it is wider.
fn narrowed(shot: Json, max_width: u32) -> Json {
    use base64::Engine as _;
    let width = shot["width"].as_u64().unwrap_or(0);
    if width <= u64::from(max_width) {
        return shot;
    }
    let scaled = (|| {
        let png = base64::engine::general_purpose::STANDARD
            .decode(shot["data"].as_str()?)
            .ok()?;
        let image = image::load_from_memory_with_format(&png, image::ImageFormat::Png).ok()?;
        let height = (u64::from(image.height()) * u64::from(max_width) / width).max(1) as u32;
        let image = image.resize_exact(max_width, height, image::imageops::FilterType::Triangle);
        let mut out = std::io::Cursor::new(Vec::new());
        image.write_to(&mut out, image::ImageFormat::Png).ok()?;
        Some(json!({
            "mimeType": "image/png",
            "data": base64::engine::general_purpose::STANDARD.encode(out.into_inner()),
            "width": max_width,
            "height": height,
        }))
    })();
    scaled.unwrap_or(shot)
}

/// The host of an origin such as `http://127.0.0.1:3773`.
fn origin_host(origin: &str) -> String {
    let rest = origin.split_once("://").map_or(origin, |(_, rest)| rest);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let authority = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    if let Some(v6) = authority.strip_prefix('[') {
        return v6.split(']').next().unwrap_or_default().to_owned();
    }
    authority.split(':').next().unwrap_or_default().to_owned()
}

/// The scripts the host runs in a page (desktop-qt's PreviewAutomationScript).
/// Each answers with one JSON string, so what comes back is the same whatever
/// the engine makes of objects.
pub mod script {
    use super::Json;

    /// Runs in the page's own world, where the agent's script means what it
    /// would in the page's console. The value is turned to JSON here, so its
    /// size is known before it is sent.
    const EVALUATE: &str = r#"
(function (source, key, max) {
  function settle(value) {
    if (value === undefined) return { done: true, undefined: true };
    var json;
    try { json = JSON.stringify(value); } catch (e) { return { done: true, value: JSON.stringify(String(value)) }; }
    if (json === undefined) return { done: true, value: JSON.stringify(String(value)) };
    var bytes = new TextEncoder().encode(json).length;
    if (bytes > max) return { done: true, tooLarge: bytes };
    return { done: true, value: json };
  }
  function failure(e) {
    var message = e && e.message !== undefined ? (e.name ? e.name + ": " : "") + e.message : String(e);
    return { done: true, error: message };
  }
  var value;
  try { value = (0, eval)(source); } catch (e) { return JSON.stringify(failure(e)); }
  if (value && typeof value.then === "function") {
    window[key] = { pending: true };
    Promise.resolve(value).then(function (v) { window[key] = settle(v); }, function (e) { window[key] = failure(e); });
    return JSON.stringify({ pending: true });
  }
  return JSON.stringify(settle(value));
})
"#;

    /// desktop-qt's automation runtime: `(name, args)` answers
    /// {ok: true, value} | {ok: false, kind, reason}.
    const RUNTIME: &str = include_str!("preview_automation_runtime.js");

    /// The runtime's `name` with `args`.
    pub fn call(name: &str, args: &Json) -> String {
        format!("{RUNTIME}({}, {args})", literal(name))
    }

    fn literal(value: &str) -> String {
        Json::String(value.to_owned()).to_string()
    }

    /// `expression` evaluated in the page's own world, its value kept under
    /// `key` when it is a promise: {"done": true, "value"?: json,
    /// "undefined"?: true} | {"done": true, "error": message} |
    /// {"done": true, "tooLarge": bytes} | {"pending": true}.
    pub fn evaluate(expression: &str, key: &str, max_bytes: usize) -> String {
        format!(
            "{EVALUATE}({}, {}, {max_bytes})",
            literal(expression),
            literal(key)
        )
    }

    /// What a pending evaluation came to: null while it is pending.
    pub fn settled(key: &str) -> String {
        format!(
            "(function (k) {{ var r = window[k]; if (!r || r.pending) return null; delete window[k]; return JSON.stringify(r); }})({})",
            literal(key)
        )
    }

    /// The parsed answer of a script, an empty object when it was not one.
    pub fn parse(result: Option<&str>) -> Json {
        result
            .and_then(|s| serde_json::from_str::<Json>(s).ok())
            .filter(Json::is_object)
            .unwrap_or_else(|| Json::Object(Default::default()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_are_named_function_or_one_character() {
        for key in ["Enter", "Tab", "Space", "F1", "F24", "a", "é", "/"] {
            assert!(known_key(key), "{key}");
        }
        for key in ["", "F0", "F25", "Fx", "Return", "ab"] {
            assert!(!known_key(key), "{key}");
        }
    }

    #[test]
    fn a_preset_turns_with_its_orientation() {
        assert_eq!(preset("iphone-se", false), Some((375, 667)));
        assert_eq!(preset("iphone-se", true), Some((667, 375)));
        // Already landscape: nest-hub is wider than tall.
        assert_eq!(preset("nest-hub", true), Some((1024, 600)));
        assert_eq!(preset("nest-hub", false), Some((600, 1024)));
        assert_eq!(preset("toaster", false), None);
    }

    #[test]
    fn a_target_is_named_without_what_it_says() {
        assert_eq!(
            target_label(&json!({"locator": "role=button[name=\"Pay\"]"})),
            "locator (23 characters)"
        );
        assert_eq!(
            target_label(&json!({"selector": "#pin", "locator": "x"})),
            "locator (1 characters)"
        );
        assert_eq!(
            target_label(&json!({"selector": "#pin"})),
            "selector (4 characters)"
        );
        assert_eq!(target_label(&json!({"x": 3, "y": 4.5})), "point (3, 4.5)");
        assert_eq!(target_label(&json!({})), "the focused element");
    }

    #[test]
    fn only_an_absolute_url_has_a_scheme() {
        assert_eq!(scheme("https://example.com"), Some("https"));
        assert_eq!(scheme("about:blank"), Some("about"));
        assert_eq!(scheme("/relative"), None);
        assert_eq!(scheme("example.com"), None);
        assert_eq!(scheme("1http://x"), None);
    }

    #[test]
    fn a_client_id_is_the_machine_and_home() {
        let id = client_id_of(b"machine", "/home/me/.local/state/hal-c2/");
        assert_eq!(
            id,
            client_id_of(b"machine", "/home/me/.local/state//hal-c2")
        );
        assert_eq!(
            id,
            client_id_of(b"machine", "/home/me/x/../.local/state/hal-c2")
        );
        assert_ne!(
            id,
            client_id_of(b"machine", "/home/me/.local/state/hal-c2-dev")
        );
        assert_ne!(id, client_id_of(b"other", "/home/me/.local/state/hal-c2"));
        assert!(id.starts_with("desktop-") && id.len() == 8 + 24, "{id}");
    }

    #[test]
    fn paths_clean_as_qt_cleans_them() {
        assert_eq!(clean_path("/a//b/./c/"), "/a/b/c");
        assert_eq!(clean_path("/../a"), "/a");
        assert_eq!(clean_path("a/../.."), "..");
        assert_eq!(clean_path("./"), ".");
        assert_eq!(clean_path("/"), "/");
    }

    #[test]
    fn an_origin_names_its_host() {
        assert_eq!(origin_host("http://127.0.0.1:3773"), "127.0.0.1");
        assert_eq!(origin_host("https://mc.tail.ts.net/"), "mc.tail.ts.net");
        assert_eq!(origin_host("http://[::1]:80"), "::1");
    }
}
