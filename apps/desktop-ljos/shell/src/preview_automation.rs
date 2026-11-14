//! This desktop as the browser agents drive (`previewAutomation`,
//! apps/server-ex lib/hal_c2/preview_automation.ex; packages/contracts
//! previewAutomation.ts): desktop-qt's PreviewAutomationHost.
//!
//! The host offers itself to each MC it is given as one host under one
//! client id, and again whenever the MC ends the subscription. Each MC sends
//! requests for its threads' preview tabs; the page attached for that tab
//! carries them out, and the answer goes back with
//! `previewAutomation.respond` before the request's own deadline, as the MC
//! drops a host that answers late. A status is answered at once. Anything
//! else waits for the tab's previous request: one page, one action at a time.
//!
//! desktop-ljos has no browser pages yet (Ljós's web engine is not built
//! in), so nothing attaches a page or offers the host to an MC. It carries
//! status, open (a dev-server port or an address) and evaluate, and tells an
//! agent it does not support the rest.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::{Rc, Weak};
use std::time::Duration;

use ljos::prelude::{Engine, Time, TimerId};
use serde_json::{Map, json};

use crate::json::Json;
use crate::mc::{Frame, Mc, McError, SubId};

/// The tags the MC passes on as they are, or names in its own words.
pub mod tag {
    pub const TAB_NOT_FOUND: &str = "PreviewAutomationTabNotFoundError";
    pub const TIMEOUT: &str = "PreviewAutomationTimeoutError";
    pub const TOO_LARGE: &str = "PreviewAutomationResultTooLargeError";
    pub const DEV_TOOLS: &str = "PreviewAutomationDevToolsOpenError";
    pub const EVALUATION: &str = "PreviewAutomationEvaluationError";
    pub const REGISTRATION_TIMEOUT: &str = "PreviewAutomationWebviewRegistrationTimeoutError";
    pub const TAB_UNAVAILABLE: &str = "PreviewAutomationTabUnavailableError";
    pub const UNREACHABLE: &str = "PreviewAutomationTargetUnreachableError";
    pub const OPEN_FAILED: &str = "PreviewAutomationOpenError";
    pub const UNSUPPORTED: &str = "PreviewAutomationUnsupportedClientError";
    pub const CAPTURE_FAILED: &str = "PreviewAutomationCaptureError";
    pub const INVALID_SELECTOR: &str = "PreviewAutomationInvalidSelectorError";
    pub const TARGET_NOT_FOUND: &str = "PreviewAutomationTargetNotFoundError";
    pub const NOT_EDITABLE: &str = "PreviewAutomationTargetNotEditableError";
    pub const SCRIPT: &str = "PreviewAutomationScriptError";
}

/// How long a request may take when the MC names no limit (ms).
pub const DEFAULT_WAIT_MS: i64 = 15_000;
pub const MAX_EVALUATION_BYTES: usize = 64_000;
/// The most console and network entries a snapshot carries.
pub const MAX_ENTRIES: usize = 200;
/// Snapshots taken before a page whose secrets keep changing is given up on,
/// and tries at drawing a page, a second each.
const SNAPSHOT_ATTEMPTS: u32 = 3;
const CAPTURE_ATTEMPTS: u32 = 3;
const CAPTURE_ATTEMPT_MS: i64 = 1000;
/// An answer leaves this long before the MC's deadline.
pub const ANSWER_MARGIN_MS: i64 = 300;

/// What this host can do, as it tells each MC.
pub const OPERATIONS: [&str; 3] = ["status", "open", "evaluate"];

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
    fn url(&self) -> String;
    fn title(&self) -> String;
    fn loading(&self) -> bool;
    fn load(&self, url: &str);
    fn dev_tools_open(&self) -> bool;
    fn on_screen(&self) -> bool;
    /// The page's rendered size, (0, 0) before it has one.
    fn viewport(&self) -> (i32, i32);
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
    fn console_entries(&self) -> Vec<Json> {
        Vec::new()
    }
    fn failed_loads(&self) -> Vec<Json> {
        Vec::new()
    }
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
type Opened = Rc<dyn Fn(&Engine, String, bool)>;
type RequestRef = Rc<RefCell<Request>>;
type Captured = Box<dyn FnOnce(&Engine, &RequestRef, Json)>;

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
    page: Option<Rc<dyn AutomationPage>>,
    done: bool,
    waiting_for_page: bool,
    deadline: Option<TimerId>,
}

struct Connection {
    environment_id: String,
    subscription: Option<SubId>,
    connection_id: String,
}

struct State {
    mc: Rc<dyn Mc>,
    client_id: String,
    connections: HashMap<String, Connection>,
    pages: HashMap<String, Rc<dyn AutomationPage>>,
    /// Requests waiting for their queue, by key; the first is the one running.
    queues: HashMap<String, Vec<RequestRef>>,
    page_waiters: HashMap<String, Vec<Then>>,
    /// The tab each thread's agent last acted on, for requests that name none.
    current_tabs: HashMap<String, String>,
    /// Tabs an agent opened asking not to be shown.
    hidden: HashSet<String>,
    on_reveal: Option<OnReveal>,
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
            connections: HashMap::new(),
            pages: HashMap::new(),
            queues: HashMap::new(),
            page_waiters: HashMap::new(),
            current_tabs: HashMap::new(),
            hidden: HashSet::new(),
            on_reveal: None,
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
            }
            Some("request") => {
                let mut request = event["request"].clone();
                request["connectionId"] = event["connectionId"].clone();
                self.on_request(engine, name, &request);
            }
            _ => {}
        }
    }

    // Pages.

    /// The page the browser shows for a tab; a page is one tab's at a time.
    pub fn attach(
        &self,
        engine: &Engine,
        thread_id: &str,
        tab_id: &str,
        page: Rc<dyn AutomationPage>,
    ) {
        if tab_id.is_empty() {
            return;
        }
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
    }

    fn page(&self, tab_id: &str) -> Option<Rc<dyn AutomationPage>> {
        self.0.borrow().pages.get(tab_id).cloned()
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
            input: json.get("input").cloned().unwrap_or_else(|| json!({})),
            timeout_ms: json["timeoutMs"].as_i64().unwrap_or(DEFAULT_WAIT_MS),
            started: engine.now(),
            queues: Vec::new(),
            resume: None,
            page: None,
            done: false,
            waiting_for_page: false,
            deadline: None,
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
            let status = self.status(&tab);
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
                let tag = if waiting { tag::REGISTRATION_TIMEOUT } else { tag::TIMEOUT };
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
                if page.dev_tools_open() {
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
                        Reveal { environment_id, thread_id: thread_id.clone(), tab_id: tab.clone(), show: None },
                    );
                }
                host.0.borrow_mut().current_tabs.insert(thread_id, tab);
                match operation.as_str() {
                    "evaluate" => host.evaluate(engine, request, &page),
                    "snapshot" => host.snapshot(engine, request, page, 0),
                    _ => {
                        let client = host.client_id();
                        host.fail(
                            engine,
                            request,
                            tag::UNSUPPORTED,
                            &format!("Preview automation client {client} does not support {operation}."),
                        );
                    }
                }
            }),
        );
    }

    fn finish(&self, engine: &Engine, request: &RequestRef, outcome: Result<Json, Json>) {
        let (response, environment_id, queues, deadline) = {
            let mut r = request.borrow_mut();
            if r.done {
                return;
            }
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
            )
        };
        if let Some(deadline) = deadline {
            engine.cancel_call(deadline);
        }
        let mc = self.0.borrow().mc.clone();
        mc.call(
            &environment_id,
            "previewAutomation.respond",
            response,
            Box::new(|_, _: Result<Json, McError>| {}),
        );
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

    // The operations.

    fn status(&self, tab_id: &str) -> Json {
        let page = self.page(tab_id);
        let mut result = json!({
            "available": page.is_some(),
            "visible": page.as_ref().is_some_and(|p| p.on_screen()),
            "tabId": if tab_id.is_empty() { Json::Null } else { json!(tab_id) },
            "url": page.as_ref().map_or(Json::Null, |p| json!(p.url())),
            "title": page.as_ref().map_or(Json::Null, |p| json!(p.title())),
            "loading": page.as_ref().is_some_and(|p| p.loading()),
        });
        if let Some(page) = page {
            let (width, height) = page.viewport();
            if width > 0 && height > 0 {
                result["viewport"] = json!({"width": width, "height": height});
            }
        }
        result
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
                                let page = r2.borrow().page.clone();
                                if let (true, false, Some(page)) = (load, u.is_empty(), page) {
                                    page.load(&u);
                                }
                                let status = h2.status(&t);
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

    /// The address an open names: a dev-server `target` wins over `url`.
    /// Fails the request and returns None when it names none it can reach;
    /// an empty address is none at all.
    fn address(&self, engine: &Engine, request: &RequestRef) -> Option<String> {
        let (input, environment_id) = {
            let r = request.borrow();
            (r.input.clone(), r.environment_id.clone())
        };
        let target = &input["target"];
        if !target.is_object() {
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

    fn evaluate(&self, engine: &Engine, request: &RequestRef, page: &Rc<dyn AutomationPage>) {
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
                if request.borrow().done {
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
                host.settle(engine, request, polled, key);
            }),
        );
    }

    /// Asks the page every 100 ms what a pending evaluation came to, until
    /// the request runs out of time.
    fn settle(
        &self,
        engine: &Engine,
        request: &RequestRef,
        page: Rc<dyn AutomationPage>,
        key: String,
    ) {
        let host = self.clone();
        let asked = request.clone();
        let again = page.clone();
        page.run_script(
            engine,
            &script::settled(&key),
            Box::new(move |engine, result| {
                if asked.borrow().done {
                    return;
                }
                let outcome = script::parse(result.as_deref());
                if outcome.as_object().is_some_and(|o| !o.is_empty()) {
                    host.evaluated(engine, &asked, &outcome);
                    return;
                }
                if host.remaining_ms(engine, &asked) <= 0 {
                    let timeout = asked.borrow().timeout_ms;
                    host.fail(
                        engine,
                        &asked,
                        tag::TIMEOUT,
                        &format!("Preview automation evaluate timed out after {timeout}ms."),
                    );
                    return;
                }
                engine.call_at(after(engine, 100), move |engine| {
                    if !asked.borrow().done {
                        host.settle(engine, &asked, again, key);
                    }
                });
            }),
        );
    }

    /// The page's text, controls and picture. A page whose password fields
    /// (or what it draws as dots) changed between reading its text and
    /// drawing its picture may show what the text hid, so it is read again.
    fn snapshot(
        &self,
        engine: &Engine,
        request: &RequestRef,
        page: Rc<dyn AutomationPage>,
        attempt: u32,
    ) {
        let host = self.clone();
        let read = page.clone();
        self.runtime(engine, request, &page, "snapshot", json!({}), move |engine, request, value| {
            let again = read.clone();
            host.clone().capture(engine, request, read, 0, Box::new(move |engine, request, shot| {
                let checked = again.clone();
                host.clone().runtime(engine, request, &checked, "secrets", json!({}), move |engine, request, now| {
                    if now["print"] != value["secrets"] {
                        if attempt + 1 < SNAPSHOT_ATTEMPTS {
                            host.snapshot(engine, request, again, attempt + 1);
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
                    let mut result = value;
                    let mut network = result["networkEntries"].as_array().cloned().unwrap_or_default();
                    network.extend(again.failed_loads());
                    let over = network.len().saturating_sub(MAX_ENTRIES);
                    network.drain(..over);
                    if let Some(fields) = result.as_object_mut() {
                        fields.remove("viewport");
                        fields.remove("secrets");
                        fields.insert("tabId".into(), json!(request.borrow().tab_id));
                        fields.insert("networkEntries".into(), Json::Array(network));
                        fields.insert("consoleEntries".into(), Json::Array(again.console_entries()));
                        fields.insert("actionTimeline".into(), json!([]));
                        fields.insert("screenshot".into(), shot);
                    }
                    host.succeed(engine, request, result);
                });
            }));
        });
    }

    /// The page's picture: three tries, a second each, as a page that was
    /// just shown may not have drawn.
    fn capture(
        self,
        engine: &Engine,
        request: &RequestRef,
        page: Rc<dyn AutomationPage>,
        attempt: u32,
        then: Captured,
    ) {
        let settled = Rc::new(std::cell::Cell::new(false));
        let then = Rc::new(RefCell::new(Some(then)));
        let retry = {
            let (host, request, page, settled, then) = (
                self.clone(),
                request.clone(),
                page.clone(),
                settled.clone(),
                then.clone(),
            );
            Rc::new(move |engine: &Engine| {
                if settled.replace(true) || request.borrow().done {
                    return;
                }
                if attempt + 1 >= CAPTURE_ATTEMPTS {
                    let tab = request.borrow().tab_id.clone();
                    host.fail(
                        engine,
                        &request,
                        tag::CAPTURE_FAILED,
                        &format!("Preview tab {tab} could not be captured after {CAPTURE_ATTEMPTS} attempts."),
                    );
                    return;
                }
                let Some(then) = then.borrow_mut().take() else {
                    return;
                };
                let (host, request, page) = (host.clone(), request.clone(), page.clone());
                engine.call_at(after(engine, 100), move |engine| {
                    if !request.borrow().done {
                        host.capture(engine, &request, page, attempt + 1, then);
                    }
                });
            })
        };
        let late = retry.clone();
        engine.call_at(after(engine, CAPTURE_ATTEMPT_MS), move |engine| {
            late(engine)
        });
        let request = request.clone();
        page.grab(
            engine,
            Box::new(move |engine, shot| {
                if settled.get() || request.borrow().done {
                    return;
                }
                let Some(shot) = shot else {
                    return retry(engine);
                };
                settled.set(true);
                if let Some(then) = then.borrow_mut().take() {
                    then(engine, &request, shot);
                }
            }),
        );
    }

    /// Runs the automation runtime's `name` in the page; `then` gets its
    /// value, and a failure fails the request.
    fn runtime(
        &self,
        engine: &Engine,
        request: &RequestRef,
        page: &Rc<dyn AutomationPage>,
        name: &str,
        args: Json,
        then: impl FnOnce(&Engine, &RequestRef, Json) + 'static,
    ) {
        let host = self.clone();
        let asked = request.clone();
        page.run_isolated(
            engine,
            &script::call(name, &args),
            Box::new(move |engine, result| {
                if asked.borrow().done {
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

    /// The runtime's failure, said for the request.
    fn fail_target(&self, engine: &Engine, request: &RequestRef, answer: &Json) {
        let (operation, tab, target) = {
            let r = request.borrow();
            let target = ["locator", "selector"]
                .iter()
                .find_map(|key| r.input[*key].as_str().map(|v| format!("{key} {v}")))
                .unwrap_or_else(|| "its target".to_owned());
            (r.operation.clone(), r.tab_id.clone(), target)
        };
        let reason = text(&answer["reason"]);
        match answer["kind"].as_str().unwrap_or_default() {
            "invalid" => self.fail(
                engine,
                request,
                tag::INVALID_SELECTOR,
                &format!("Preview automation {operation} rejected {target} in tab {tab}: {reason}"),
            ),
            "missing" => self.fail(
                engine,
                request,
                tag::TARGET_NOT_FOUND,
                &format!("Preview automation {operation} could not find {target} in tab {tab}"),
            ),
            "notEditable" => self.fail(
                engine,
                request,
                tag::NOT_EDITABLE,
                &format!("Preview automation {operation} found {target}, but it is not editable in tab {tab}"),
            ),
            "error" => self.fail(
                engine,
                request,
                tag::SCRIPT,
                &format!("Preview automation {operation} failed in tab {tab}: {reason}"),
            ),
            // No answer at all: the page went, or navigated away mid-script.
            _ => self.fail(
                engine,
                request,
                tag::TAB_UNAVAILABLE,
                &format!("Preview automation {operation} lost tab {tab}'s page before it answered."),
            ),
        }
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
}

fn after(engine: &Engine, ms: i64) -> Time {
    engine.now() + Duration::from_millis(ms.max(0) as u64)
}

fn text(value: &Json) -> String {
    value.as_str().unwrap_or_default().to_owned()
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
    use super::origin_host;

    #[test]
    fn an_origin_names_its_host() {
        assert_eq!(origin_host("http://127.0.0.1:3773"), "127.0.0.1");
        assert_eq!(origin_host("https://mc.tail.ts.net/"), "mc.tail.ts.net");
        assert_eq!(origin_host("http://[::1]:80"), "::1");
    }
}
