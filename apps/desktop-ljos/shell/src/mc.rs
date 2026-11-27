//! The controllers' MC: what they ask of it, whoever answers.
//!
//! [`Mc`] is the seam. [`Connection`] is the real one, over the `hal_c2_mc`
//! crate's [`McClient`]: its I/O thread hands every event to the "mc" side
//! stream ([`McStreams`]), waiting while it is full, and the UI thread hands
//! each frame's run of it to the client, where replies and frames reach the
//! controllers. [`Disconnected`] is the shell with no MC (a render, a test
//! that needs none).
//!
//! Every callback runs on the UI thread, with the engine, and never inside
//! the call that registered it, so a controller can register one while it
//! holds itself.
//!
//! Besides RPC, the MC's origin serves streams the socket does not carry (a
//! device's screen and input through `/api/device-hub`): [`Mc::open_stream`]
//! opens one with the access token, and its events reach the UI the same way,
//! through the "mc-streams" stream.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::{Rc, Weak};

use chrono::{DateTime, Utc};

use hal_c2_mc::stream::Stream;
pub use hal_c2_mc::stream::{StreamEnd, StreamEvent};
use hal_c2_mc::{McClient, McEvent};
pub use hal_c2_mc::{Phase, Status};
use ljos::prelude::Engine;

use crate::json::Json;
use crate::streams::{Feed, Tick, Wire};

/// A frame as the MC sent it: a JSON object with its type in `t`.
pub type Frame = serde_json::Map<String, Json>;

/// Why a call failed: the MC's message, or "not connected" / "disconnected"
/// when there was no socket to carry it. `detail` is the contract error
/// (`{"_tag", ...}`) when the MC sent one.
#[derive(Clone, Debug, PartialEq)]
pub struct McError {
    pub message: String,
    pub detail: Json,
}

impl McError {
    pub fn new(message: impl Into<String>) -> McError {
        McError {
            message: message.into(),
            detail: Json::Null,
        }
    }
}

impl From<hal_c2_mc::CallError> for McError {
    fn from(e: hal_c2_mc::CallError) -> McError {
        McError {
            message: e.message,
            detail: e.detail,
        }
    }
}

/// What the MC answers a call for a cluster member it cannot reach.
const UNREACHABLE: &str = "MC unavailable: noconnection";

pub type Reply = Box<dyn FnOnce(&Engine, Result<Json, McError>)>;
/// What [`Mc::download`] gives: the bytes, or why they could not be read.
pub type BytesReply = Box<dyn FnOnce(&Engine, Result<Vec<u8>, McError>)>;
pub type OnFrame = Box<dyn FnMut(&Engine, &Frame)>;
/// What a `sub` frame carries besides its shape (a stream's `offset`,
/// `handle` and `window`), asked each time it is sent: whoever holds the
/// data says where it continues.
pub type Resume = Box<dyn FnMut() -> Frame>;
pub type OnReady = Box<dyn FnMut(&Engine, bool)>;
pub type OnStatus = Box<dyn FnMut(&Engine, &Status)>;
pub type OnRenewed = Box<dyn FnMut(&Engine, DateTime<Utc>)>;
/// A call went out or was settled ([`Mc::on_call`]).
pub type OnCall = Box<dyn FnMut(&Engine, &CallEvent)>;

/// A client RPC's life, for the "Some requests are slow" warning: its id is
/// the connection's own, the same in both.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CallEvent {
    Started {
        id: u64,
        environment: String,
        method: String,
    },
    Ended {
        id: u64,
    },
}
/// A stream's events, in order, the last an [`StreamEvent::Ended`].
pub type OnStream = Box<dyn FnMut(&Engine, StreamEvent)>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SubId(pub u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct StreamId(pub u64);

/// What a websocket stream sends.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StreamMessage {
    Text(String),
    Binary(Vec<u8>),
}

/// A subscription held on another client: that client, and its id there.
pub type Held = (Rc<dyn Mc>, SubId);

/// Which other client serves what is addressed to an environment (and, when
/// the shape names one, a cluster MC): none when this one does.
pub type Route = Rc<dyn Fn(&str, &str) -> Option<Rc<dyn Mc>>>;

/// The MC as a controller sees it: desktop-qt's `McClient` without its
/// QObject context (a controller keeps a `Weak` to itself instead).
pub trait Mc {
    /// Whether the MC said hello on the socket there is now.
    fn is_ready(&self) -> bool;
    /// The environment the MC itself serves; empty until its first hello.
    fn environment(&self) -> String;
    /// A client RPC where `environment` is served.
    fn call(&self, environment: &str, method: &str, payload: Json, reply: Reply);
    /// Follows `shape`, sent once the MC is ready and again on every new
    /// connection, from where `resume` says, or whole without one.
    fn subscribe(&self, shape: Json, on_frame: OnFrame, resume: Option<Resume>) -> SubId;
    /// No frame reaches the subscription's handler after this.
    fn unsubscribe(&self, id: SubId);
    /// Asks a windowed stream for the turns before its window.
    fn more(&self, id: SubId, items: u32);
    /// Says a terminal subscription has taken its output up to `sequence`.
    fn ack(&self, _id: SubId, _sequence: i64) {}
    /// Runs `f` whenever the MC becomes ready or stops being so.
    fn on_ready_changed(&self, f: OnReady);

    // The rest is what the connection's health reads and steers. A fake that
    // does not care for it keeps the defaults: ready when it says so, no
    // retries to run, nothing to open.

    /// How the connection is doing, as last delivered.
    fn status(&self) -> Status {
        let ready = self.is_ready();
        Status {
            phase: if ready { Phase::Ready } else { Phase::Closed },
            connection: ready.then_some(0),
            environment: self.environment(),
            ..Status::default()
        }
    }
    /// Runs `f` with every new status (phase, readiness, failure, ...).
    fn on_status(&self, _f: OnStatus) {}
    /// Runs `f` as each [`Mc::call`] goes out and as it is answered or fails
    /// (McClient's callStarted and callEnded).
    fn on_call(&self, _f: OnCall) {}
    /// Tries again now, whatever the connection was waiting for.
    fn retry_now(&self) {}
    /// Drops the socket and connects again.
    fn reconnect(&self) {}
    /// The app came to the foreground: a waiting retry runs now, and a ready
    /// connection is checked.
    fn wake(&self) {}
    /// Whether this device has a network; offline, a drop is not retried.
    fn set_online(&self, _online: bool) {}
    /// The http(s) origin the MC was opened at, once it was.
    fn origin(&self) -> Option<String> {
        None
    }
    /// Connects to another MC (or the same with a new session).
    fn open(&self, _origin: &str, _token: &str) -> Result<(), String> {
        Err("this shell cannot open another MC".into())
    }
    /// A new client of its own, for a saved environment: delivered with this
    /// one and given its timings. None where there is no I/O to share (a
    /// fake), so no saved environment connects.
    fn spawn_link(&self) -> Option<Rc<dyn Mc>> {
        None
    }
    /// When the credential it was opened with runs out (None: never, or
    /// unknown); a renewal moves it.
    fn set_credential_expiry(&self, _expires_at: Option<DateTime<Utc>>) {}
    fn credential_expiry(&self) -> Option<DateTime<Utc>> {
        None
    }
    /// Runs `f` with the new expiry when a renewal completes, while
    /// the connection stays ready (McClient::credentialRenewed).
    fn on_credential_renewed(&self, _f: OnRenewed) {}
    /// Opens as [`Mc::open`], at an MC that must say it serves
    /// `environment` (a saved environment's).
    fn open_expecting(&self, origin: &str, token: &str, _environment: &str) -> Result<(), String> {
        self.open(origin, token)
    }
    /// The environment it is open for, said hello or not; empty from
    /// [`Mc::close`] on.
    fn open_for(&self) -> String {
        self.environment()
    }
    /// Closes the socket for good: no retry follows.
    fn close(&self) {}
    /// Sends calls and subscriptions addressed to an environment another
    /// client serves through that client (desktop-qt's McClient::setRoute).
    fn set_route(&self, _route: Route) {}
    /// Moves each subscription held on another client to the client that
    /// serves its environment now, once a link was replaced: the old one
    /// hears no more.
    fn reroute(&self) {}
    /// `orchestration.dispatchCommand` with a fresh commandId, where
    /// `environment` is served.
    fn dispatch_command(&self, environment: &str, mut command: Json, reply: Reply) {
        if let Json::Object(fields) = &mut command {
            fields.insert("commandId".into(), hal_c2_mc::new_uuid().into());
        }
        self.call(environment, "orchestration.dispatchCommand", command, reply);
    }
    /// POSTs `body` to `path` of the MC's HTTP API (answers too large for
    /// the socket, as `/api/pull-requests/diff`), with its access token. A
    /// fake answers it as the call `"POST <path>"` on no environment, so its
    /// replies come as any call's do.
    fn post(&self, path: &str, body: Json, reply: Reply) {
        self.call("", &format!("POST {path}"), body, reply);
    }

    /// GETs `path` of the MC's HTTP API (`/api/auth/session`) with its access
    /// token. A fake answers it as the call `"GET <path>"` on no environment.
    fn get(&self, path: &str, reply: Reply) {
        self.call("", &format!("GET {path}"), Json::Null, reply);
    }

    // Streams on the MC's origin, beside the socket (a device's screen). A
    // fake without them has no origin to open one at.

    /// Opens a GET for `path` and `query` (both percent-encoded) on the MC's
    /// origin with its access token, its body handed over as it arrives; with
    /// `socket`, a websocket there instead. None before the MC was opened.
    fn open_stream(
        &self,
        _path: &str,
        _query: &str,
        _socket: bool,
        _on_event: OnStream,
    ) -> Option<StreamId> {
        None
    }
    /// Sends `message` on a websocket stream; nothing on a GET or once it ended.
    fn send_on_stream(&self, _id: StreamId, _message: StreamMessage) {}
    /// Aborts a stream: no event reaches its handler after this.
    fn close_stream(&self, _id: StreamId) {}

    /// POSTs `bytes` to a signed URL the MC handed out (`relativeUrl`, as
    /// `attachments.createUploadUrl`'s). A fake sees it as an `http.upload`
    /// call carrying the URL, the type and the size.
    fn upload(&self, relative_url: &str, bytes: Vec<u8>, mime_type: &str, reply: Reply) {
        let payload = serde_json::json!({
            "relativeUrl": relative_url,
            "mimeType": mime_type,
            "sizeBytes": bytes.len(),
        });
        self.call("", "http.upload", payload, reply);
    }
    /// GETs a signed URL the MC handed out (`assets.createUrl`'s
    /// `relativeUrl`). A fake sees it as an `http.download` call carrying the
    /// URL, and answers with the file's text.
    fn download(&self, relative_url: &str, reply: BytesReply) {
        let payload = serde_json::json!({ "relativeUrl": relative_url });
        self.call(
            "",
            "http.download",
            payload,
            Box::new(move |engine, result| {
                reply(
                    engine,
                    result.map(|body| match body {
                        Json::String(text) => text.into_bytes(),
                        other => other.to_string().into_bytes(),
                    }),
                )
            }),
        );
    }
}

thread_local! {
    /// The engine while the "mc" stream's handler runs: `McClient`'s
    /// callbacks get none, and every one of them runs inside it.
    static DELIVERING: RefCell<Option<Engine>> = const { RefCell::new(None) };
}

fn with_delivering(f: impl FnOnce(&Engine)) {
    let engine = DELIVERING.with(|d| d.borrow().clone());
    match engine {
        Some(engine) => f(&engine),
        None => debug_assert!(false, "an McClient callback ran outside the MC's stream"),
    }
}

/// How many of the MC's events wait for the UI at most: a frame's worth of
/// a busy thread's deltas. A burst beyond it waits on the I/O thread, whose
/// socket then waits on the MC (DECISION: backpressure, not a drop; every
/// event is a reply or a frame some controller is owed).
pub const MC_CAPACITY: usize = 1024;
/// How many of the streams' events wait at most: a device's video comes in
/// pieces of a few kilobytes, and a full stream holds its reader as above.
pub const STREAMS_CAPACITY: usize = 256;

/// The connections as the streams' handlers find them, by the id each
/// event carries.
type Registry = Rc<RefCell<HashMap<u64, Weak<Connection>>>>;

/// The side streams every [`Connection`] hands its events to, and the
/// connections they go to. One set for the shell: the saved environments'
/// links ([`Mc::spawn_link`]) share their first connection's.
pub struct McStreams {
    events: Feed<(u64, McEvent)>,
    streams: Feed<(u64, u64, StreamEvent)>,
    /// That a call went out: its followers ([`Mc::on_call`]) hear of it on
    /// the UI's next frame, before its answer can arrive.
    calls: Tick,
    registry: Registry,
    next: Cell<u64>,
}

impl McStreams {
    /// Makes the MC's streams on `wire`: "mc-calls", "mc" and
    /// "mc-streams", drained in that order.
    pub fn new(wire: &mut impl Wire) -> Rc<McStreams> {
        let registry: Registry = Rc::default();
        let calls = {
            let registry = registry.clone();
            Tick::new(wire, "mc-calls", move |engine| {
                for connection in live(&registry) {
                    connection.tell_started(engine);
                }
            })
        };
        let events = {
            let registry = registry.clone();
            Feed::new(wire, "mc", MC_CAPACITY, move |engine, run| {
                // A call made since the last frame is heard of before any
                // answer in this run.
                let connections = live(&registry);
                for connection in &connections {
                    connection.tell_started(engine);
                }
                let outer = DELIVERING.with(|d| d.borrow_mut().replace(engine.clone()));
                // The run's shell frames tell the store's listeners once.
                crate::store::batched(engine, || {
                    for (id, event) in run {
                        let connection = registry.borrow().get(&id).and_then(Weak::upgrade);
                        if let Some(connection) = connection {
                            connection.client.deliver(event);
                        }
                    }
                });
                DELIVERING.with(|d| *d.borrow_mut() = outer);
            })
        };
        let streams = {
            let registry = registry.clone();
            Feed::new(wire, "mc-streams", STREAMS_CAPACITY, move |engine, run| {
                for (id, stream, event) in run {
                    let connection = registry.borrow().get(&id).and_then(Weak::upgrade);
                    if let Some(connection) = connection {
                        connection.deliver_stream(engine, stream, event);
                    }
                }
            })
        };
        Rc::new(McStreams {
            events,
            streams,
            calls,
            registry,
            next: Cell::new(0),
        })
    }
}

/// The connections still open, taken out of the registry's borrow: a
/// handler may open another.
fn live(registry: &Registry) -> Vec<Rc<Connection>> {
    let mut registry = registry.borrow_mut();
    registry.retain(|_, connection| connection.strong_count() > 0);
    registry.values().filter_map(Weak::upgrade).collect()
}

/// An open stream and its handler, out of the map while it runs.
struct OpenStream {
    stream: Stream,
    on_event: Option<OnStream>,
}

/// The real MC, over `hal_c2_mc`.
pub struct Connection {
    client: McClient,
    /// What its events carry, so the streams' handlers find it.
    id: u64,
    sides: Rc<McStreams>,
    streams: RefCell<HashMap<u64, OpenStream>>,
    next_stream: Cell<u64>,
    calls: Rc<Calls>,
    route: RefCell<Option<Route>>,
    /// Subscriptions another client serves: the id given out, and that
    /// client's own.
    forwarded: RefCell<HashMap<u64, Forwarded>>,
    next_forwarded: Cell<u64>,
}

/// A subscription another client serves ([`Mc::set_route`]): what it was
/// made with, shared so [`Mc::reroute`] can make it again on a new link.
struct Forwarded {
    environment: String,
    mc: String,
    shape: Json,
    on_frame: Rc<RefCell<OnFrame>>,
    resume: Option<Rc<RefCell<Resume>>>,
    held: Holder,
}

/// Who serves a forwarded subscription now: a link, or, once the route
/// named none, this client itself under an id of its own.
#[derive(Clone)]
enum Holder {
    Link(Held),
    Own(SubId),
}

impl Forwarded {
    /// Subscribes on `link` with the shared callbacks.
    fn subscribe_on(&self, link: &Rc<dyn Mc>) -> SubId {
        let on_frame = self.on_frame.clone();
        let resume = self
            .resume
            .clone()
            .map(|resume| -> Resume { Box::new(move || (resume.borrow_mut())()) });
        link.subscribe(
            self.shape.clone(),
            Box::new(move |engine, frame| (on_frame.borrow_mut())(engine, frame)),
            resume,
        )
    }

    /// Subscribes on `client`, the shell's own, with the shared callbacks.
    fn subscribe_own(&self, client: &McClient) -> SubId {
        let on_frame = self.on_frame.clone();
        let frame =
            move |frame: &Frame| with_delivering(|engine| (on_frame.borrow_mut())(engine, frame));
        let shape = self.shape.clone();
        SubId(match self.resume.clone() {
            Some(resume) => {
                client.subscribe_resuming(shape, frame, move || (resume.borrow_mut())())
            }
            None => client.subscribe(shape, frame),
        })
    }
}

/// Where the ids of forwarded subscriptions start, above any the client
/// gives.
const FORWARDED: u64 = 1 << 62;

/// Who follows the calls ([`Mc::on_call`]), and the calls that went out
/// since they last heard: a call has no engine to tell them with, so they
/// hear of it on the next frame ([`McStreams`]), before its answer.
#[derive(Default)]
struct Calls {
    next: Cell<u64>,
    started: RefCell<Vec<CallEvent>>,
    listeners: RefCell<Vec<OnCall>>,
}

impl Calls {
    fn notify(&self, engine: &Engine, event: &CallEvent) {
        // Taken out while they run: one may follow too.
        let mut running = std::mem::take(&mut *self.listeners.borrow_mut());
        for f in &mut running {
            f(engine, event);
        }
        let mut kept = self.listeners.borrow_mut();
        running.append(&mut kept);
        *kept = running;
    }
}

impl Connection {
    /// Starts the I/O thread, which hands its events to `sides`.
    pub fn spawn(sides: &Rc<McStreams>) -> Rc<Connection> {
        let id = sides.next.get() + 1;
        sides.next.set(id);
        let feed = sides.events.clone();
        let handle = hal_c2_mc::spawn(move |event| {
            // Handed back only once the window is gone: nobody to tell.
            let _ = feed.send((id, event));
        });
        let connection = Rc::new(Connection {
            client: McClient::new(handle),
            id,
            sides: sides.clone(),
            streams: RefCell::default(),
            next_stream: Cell::new(0),
            calls: Rc::default(),
            route: RefCell::default(),
            forwarded: RefCell::default(),
            next_forwarded: Cell::new(FORWARDED),
        });
        sides
            .registry
            .borrow_mut()
            .insert(id, Rc::downgrade(&connection));
        connection
    }

    /// The client that serves `environment` (or the cluster MC `mc`) when
    /// another does; never this one.
    fn routed(&self, environment: &str, mc: &str) -> Option<Rc<dyn Mc>> {
        if environment.is_empty() && mc.is_empty() {
            return None;
        }
        let route = self.route.borrow().clone()?;
        route(environment, mc)
    }

    fn forwarded(&self, id: SubId) -> Option<Holder> {
        self.forwarded.borrow().get(&id.0).map(|f| f.held.clone())
    }

    pub fn client(&self) -> &McClient {
        &self.client
    }

    /// Connects to the MC at `origin` (`http://127.0.0.1:3773`) with the
    /// token the desktop host would hand over.
    pub fn open(&self, origin: &str, token: &str) -> Result<(), String> {
        let origin = url::Url::parse(origin).map_err(|e| format!("{origin}: {e}"))?;
        self.client.open(origin, token);
        Ok(())
    }

    /// Tells the calls' followers of the calls that went out since they
    /// last heard.
    fn tell_started(&self, engine: &Engine) {
        let started = std::mem::take(&mut *self.calls.started.borrow_mut());
        for event in &started {
            self.calls.notify(engine, event);
        }
    }

    /// Runs a stream's handler with the map free, so it may open or close
    /// streams (its own too); one that ended is forgotten.
    fn deliver_stream(&self, engine: &Engine, id: u64, event: StreamEvent) {
        let ended = matches!(event, StreamEvent::Ended(_));
        let handler = self
            .streams
            .borrow_mut()
            .get_mut(&id)
            .and_then(|open| open.on_event.take());
        let Some(mut handler) = handler else {
            return;
        };
        handler(engine, event);
        let mut streams = self.streams.borrow_mut();
        if ended {
            streams.remove(&id);
        } else if let Some(open) = streams.get_mut(&id) {
            open.on_event = Some(handler);
        }
    }
}

impl Mc for Connection {
    fn is_ready(&self) -> bool {
        self.client.is_ready()
    }

    fn environment(&self) -> String {
        self.client.environment()
    }

    fn call(&self, environment: &str, method: &str, payload: Json, reply: Reply) {
        if let Some(link) = self.routed(environment, "") {
            return link.call(environment, method, payload, reply);
        }
        let client = self.client.downgrade();
        let addressed = environment.to_owned();
        let id = self.calls.next.get() + 1;
        self.calls.next.set(id);
        let calls = self.calls.clone();
        calls.started.borrow_mut().push(CallEvent::Started {
            id,
            environment: environment.to_owned(),
            method: method.to_owned(),
        });
        self.sides.calls.give();
        self.client
            .call(environment, method, payload, move |result| {
                with_delivering(|engine| {
                    calls.notify(engine, &CallEvent::Ended { id });
                    let result = result.map_err(|e| {
                        let mut error = McError::from(e);
                        // A cluster member the MC cannot reach: named, as the
                        // user knows it (McClient.cpp's environmentNames).
                        if error.message == UNREACHABLE {
                            let environment = match (addressed.is_empty(), client.upgrade()) {
                                (true, Some(client)) => client.environment(),
                                _ => addressed,
                            };
                            let label = crate::store::with(engine, |s| {
                                s.environment(&environment)
                                    .get("label")
                                    .and_then(Json::as_str)
                                    .unwrap_or_default()
                                    .to_owned()
                            });
                            let name = if label.is_empty() { environment } else { label };
                            error.message = format!("{name} is not connected.");
                        }
                        error
                    });
                    reply(engine, result)
                });
            });
    }

    fn post(&self, path: &str, body: Json, reply: Reply) {
        self.client.post(path, body, move |result| {
            with_delivering(|engine| reply(engine, result.map_err(McError::from)));
        });
    }

    fn get(&self, path: &str, reply: Reply) {
        self.client.get(path, move |result| {
            with_delivering(|engine| reply(engine, result.map_err(McError::from)));
        });
    }

    fn upload(&self, relative_url: &str, bytes: Vec<u8>, mime_type: &str, reply: Reply) {
        self.client
            .upload(relative_url, bytes, mime_type, move |result| {
                with_delivering(|engine| reply(engine, result.map_err(McError::from)));
            });
    }

    fn download(&self, relative_url: &str, reply: BytesReply) {
        self.client.download(relative_url, move |result| {
            with_delivering(|engine| reply(engine, result.map_err(McError::from)));
        });
    }

    fn subscribe(&self, shape: Json, mut on_frame: OnFrame, resume: Option<Resume>) -> SubId {
        let field = |key: &str| shape.get(key).and_then(Json::as_str).unwrap_or_default();
        let environment = match field("environment") {
            "" => field("environmentId"),
            named => named,
        }
        .to_owned();
        let mc = field("mc").to_owned();
        // One that names its environment or MC is kept even while this
        // client serves it, so [`Mc::reroute`] can move it to a link that
        // comes to serve it later.
        if !environment.is_empty() || !mc.is_empty() {
            let link = self.routed(&environment, &mc);
            let mut forwarded = Forwarded {
                environment,
                mc,
                shape,
                on_frame: Rc::new(RefCell::new(on_frame)),
                resume: resume.map(|r| Rc::new(RefCell::new(r))),
                held: Holder::Own(SubId(0)),
            };
            forwarded.held = match link {
                Some(link) => Holder::Link((link.clone(), forwarded.subscribe_on(&link))),
                None => Holder::Own(forwarded.subscribe_own(&self.client)),
            };
            let id = self.next_forwarded.get();
            self.next_forwarded.set(id + 1);
            self.forwarded.borrow_mut().insert(id, forwarded);
            return SubId(id);
        }
        let frame = move |frame: &Frame| with_delivering(|engine| on_frame(engine, frame));
        SubId(match resume {
            Some(resume) => self.client.subscribe_resuming(shape, frame, resume),
            None => self.client.subscribe(shape, frame),
        })
    }

    fn unsubscribe(&self, id: SubId) {
        let forwarded = self.forwarded.borrow_mut().remove(&id.0);
        match forwarded.map(|f| f.held) {
            Some(Holder::Link((link, theirs))) => link.unsubscribe(theirs),
            Some(Holder::Own(own)) => self.client.unsubscribe(own.0),
            None => self.client.unsubscribe(id.0),
        }
    }

    fn more(&self, id: SubId, items: u32) {
        match self.forwarded(id) {
            Some(Holder::Link((link, theirs))) => link.more(theirs, items),
            Some(Holder::Own(own)) => self.client.more(own.0, items),
            None => self.client.more(id.0, items),
        }
    }

    fn ack(&self, id: SubId, sequence: i64) {
        match self.forwarded(id) {
            Some(Holder::Link((link, theirs))) => link.ack(theirs, sequence),
            Some(Holder::Own(own)) => self.client.ack(own.0, sequence),
            None => self.client.ack(id.0, sequence),
        }
    }

    fn on_ready_changed(&self, mut f: OnReady) {
        // Each hello is a new connection, ready anew (a drop and a reconnect
        // can fall between two deliveries).
        let mut connection = self.client.status().connection;
        self.client.on_status(move |status| {
            if status.connection != std::mem::replace(&mut connection, status.connection) {
                with_delivering(|engine| f(engine, status.is_ready()));
            }
        });
    }

    fn status(&self) -> Status {
        self.client.status()
    }

    fn on_status(&self, mut f: OnStatus) {
        self.client
            .on_status(move |status| with_delivering(|engine| f(engine, status)));
    }

    fn on_call(&self, f: OnCall) {
        self.calls.listeners.borrow_mut().push(f);
    }

    fn retry_now(&self) {
        self.client.retry_now();
    }

    fn reconnect(&self) {
        self.client.reconnect();
    }

    fn wake(&self) {
        self.client.wake();
    }

    fn set_online(&self, online: bool) {
        self.client.set_online(online);
    }

    fn origin(&self) -> Option<String> {
        self.client.origin().map(String::from)
    }

    fn open(&self, origin: &str, token: &str) -> Result<(), String> {
        Connection::open(self, origin, token)
    }

    fn spawn_link(&self) -> Option<Rc<dyn Mc>> {
        let link = Connection::spawn(&self.sides);
        self.client.copy_timings_to(&link.client);
        Some(link)
    }

    fn set_credential_expiry(&self, expires_at: Option<DateTime<Utc>>) {
        self.client.set_credential_expiry(expires_at);
    }

    fn credential_expiry(&self) -> Option<DateTime<Utc>> {
        self.client.credential_expiry()
    }

    fn on_credential_renewed(&self, mut f: OnRenewed) {
        self.client
            .on_credential_renewed(move |at| with_delivering(|engine| f(engine, at)));
    }

    fn open_expecting(&self, origin: &str, token: &str, environment: &str) -> Result<(), String> {
        let origin = url::Url::parse(origin).map_err(|e| format!("{origin}: {e}"))?;
        self.client.open_expecting(origin, token, environment);
        Ok(())
    }

    fn open_for(&self) -> String {
        self.client.open_for()
    }

    fn close(&self) {
        self.client.close();
    }

    fn set_route(&self, route: Route) {
        *self.route.borrow_mut() = Some(route);
    }

    fn reroute(&self) {
        // Decided first: subscribing on a link runs no code of this one's,
        // but the route reads the store and the saved environments. No
        // route means this client serves it (desktop-qt's McClient::routed).
        let moves: Vec<(u64, Option<Rc<dyn Mc>>)> = self
            .forwarded
            .borrow()
            .iter()
            .filter_map(|(id, f)| {
                let now = self.routed(&f.environment, &f.mc);
                let moved = match (&now, &f.held) {
                    (Some(now), Holder::Link((old, _))) => !Rc::ptr_eq(now, old),
                    (Some(_), Holder::Own(_)) | (None, Holder::Link(_)) => true,
                    (None, Holder::Own(_)) => false,
                };
                moved.then_some((*id, now))
            })
            .collect();
        for (id, target) in moves {
            let Some(old) = self.forwarded.borrow().get(&id).map(|f| f.held.clone()) else {
                continue;
            };
            match old {
                Holder::Link((link, theirs)) => link.unsubscribe(theirs),
                Holder::Own(own) => self.client.unsubscribe(own.0),
            }
            let held = match self.forwarded.borrow().get(&id) {
                Some(f) => match target {
                    Some(link) => Holder::Link((link.clone(), f.subscribe_on(&link))),
                    None => Holder::Own(f.subscribe_own(&self.client)),
                },
                None => continue,
            };
            if let Some(f) = self.forwarded.borrow_mut().get_mut(&id) {
                f.held = held;
            }
        }
    }

    fn open_stream(
        &self,
        path: &str,
        query: &str,
        socket: bool,
        on_event: OnStream,
    ) -> Option<StreamId> {
        let request = self.client.request(path, query, socket)?;
        let id = self.next_stream.get() + 1;
        self.next_stream.set(id);
        let (feed, connection) = (self.sides.streams.clone(), self.id);
        let stream = hal_c2_mc::stream::open(request, socket, move |event| {
            let _ = feed.send((connection, id, event));
        });
        self.streams.borrow_mut().insert(
            id,
            OpenStream {
                stream,
                on_event: Some(on_event),
            },
        );
        Some(StreamId(id))
    }

    fn send_on_stream(&self, id: StreamId, message: StreamMessage) {
        if let Some(open) = self.streams.borrow().get(&id.0) {
            match message {
                StreamMessage::Text(text) => open.stream.send_text(text),
                StreamMessage::Binary(bytes) => open.stream.send_binary(bytes),
            }
        }
    }

    fn close_stream(&self, id: StreamId) {
        // Dropped outside the borrow: dropping a stream aborts it.
        let closed = self.streams.borrow_mut().remove(&id.0);
        drop(closed);
    }
}

/// No MC: every call fails as "not connected", no frame ever comes.
#[derive(Default)]
pub struct Disconnected {
    next: Cell<u64>,
    replies: RefCell<Vec<Reply>>,
}

impl Disconnected {
    /// Answers the calls made so far, as `Connection` would on its next
    /// delivery: never inside the call.
    pub fn deliver(&self, engine: &Engine) {
        let replies = std::mem::take(&mut *self.replies.borrow_mut());
        for reply in replies {
            reply(engine, Err(McError::new("not connected")));
        }
    }
}

impl Mc for Disconnected {
    fn is_ready(&self) -> bool {
        false
    }

    fn environment(&self) -> String {
        String::new()
    }

    fn call(&self, _: &str, _: &str, _: Json, reply: Reply) {
        self.replies.borrow_mut().push(reply);
    }

    fn subscribe(&self, _: Json, _: OnFrame, _: Option<Resume>) -> SubId {
        self.next.set(self.next.get() + 1);
        SubId(self.next.get())
    }

    fn unsubscribe(&self, _: SubId) {}

    fn more(&self, _: SubId, _: u32) {}

    fn on_ready_changed(&self, _: OnReady) {}
}

#[cfg(test)]
mod reroute_tests {
    use super::*;
    use crate::streams::Pump;
    use serde_json::json;

    /// A connection that is never opened: its streams' pump is kept with it.
    fn connection() -> (Pump, Rc<Connection>) {
        let mut pump = Pump::new(|| {});
        let sides = McStreams::new(&mut pump);
        (pump, Connection::spawn(&sides))
    }

    /// A link that keeps what was subscribed on it.
    #[derive(Default)]
    struct Recorder {
        live: RefCell<Vec<u64>>,
        more: RefCell<Vec<u64>>,
        next: Cell<u64>,
    }

    impl Mc for Recorder {
        fn is_ready(&self) -> bool {
            true
        }
        fn environment(&self) -> String {
            "studio".into()
        }
        fn call(&self, _: &str, _: &str, _: Json, _: Reply) {}
        fn subscribe(&self, _: Json, _: OnFrame, _: Option<Resume>) -> SubId {
            let id = self.next.get() + 1;
            self.next.set(id);
            self.live.borrow_mut().push(id);
            SubId(id)
        }
        fn unsubscribe(&self, id: SubId) {
            self.live.borrow_mut().retain(|live| *live != id.0);
        }
        fn more(&self, id: SubId, _: u32) {
            self.more.borrow_mut().push(id.0);
        }
        fn on_ready_changed(&self, _: OnReady) {}
    }

    /// The shell frames one drain of the "mc" stream carries tell each of
    /// the store's listeners once, after the last: a burst of rows rebuilds
    /// what shows them once, not once a frame.
    #[test]
    fn a_drain_of_shell_frames_tells_each_store_listener_once() {
        let engine = ljos::App::new("test")
            .register(crate::register)
            .build_engine();
        let mut pump = Pump::new(|| {});
        let sides = McStreams::new(&mut pump);
        let own = Connection::spawn(&sides);
        // The id the store's `shell` subscription gets is the next one.
        let id = own.client().handle().next_id() + 1;
        let mc: Rc<dyn Mc> = own.clone();
        crate::store::install(&engine, &mc, None);
        let heard: Rc<RefCell<Vec<(&str, usize)>>> = Rc::default();
        for name in ["first", "second"] {
            let heard = heard.clone();
            crate::store::on_changed(&engine, move |engine| {
                let threads = crate::store::with(engine, |s| s.threads().len());
                heard.borrow_mut().push((name, threads));
            });
        }
        let thread = |id: &str| {
            json!({"id": id, "projectId": "p1", "title": id,
                   "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"})
        };
        let frames = [
            json!({
                "t": "shell",
                "mcs": [{"mc": "mc-a", "environment": {"environmentId": "env-a", "label": "env-a"},
                         "online": true, "epoch": "e1", "rev": 4}],
                "rows": [["mc-a", "t1", "thread", thread("t1")]],
            }),
            json!({"t": "shell.rows", "mc": "mc-a", "epoch": "e1", "rev": 5,
                   "rows": [["t2", "thread", thread("t2")]]}),
            json!({"t": "shell.rows", "mc": "mc-a", "epoch": "e1", "rev": 6,
                   "rows": [["t3", "thread", thread("t3")]]}),
        ];
        for frame in frames {
            let frame = frame.as_object().cloned().unwrap();
            let sent = sides.events.send((
                own.id,
                McEvent::Frame {
                    id,
                    frame,
                    switched: 0,
                },
            ));
            assert!(sent.is_ok());
        }
        heard.borrow_mut().clear();
        assert!(pump.pump(&engine) >= 3);
        assert_eq!(*heard.borrow(), [("first", 3), ("second", 3)]);
    }

    /// A frame the connection handed over before it was closed is for what
    /// the close left: it does not refill the emptied store, reopened for
    /// another or not.
    #[test]
    fn a_frame_queued_before_a_close_does_not_refill_the_store() {
        for reopened in [false, true] {
            let engine = ljos::App::new("test")
                .register(crate::register)
                .build_engine();
            let mut pump = Pump::new(|| {});
            let sides = McStreams::new(&mut pump);
            let own = Connection::spawn(&sides);
            let id = own.client().handle().next_id() + 1;
            let mc: Rc<dyn Mc> = own.clone();
            crate::store::install(&engine, &mc, None);
            let frame = json!({
                "t": "shell",
                "mcs": [{"mc": "mc-a", "environment": {"environmentId": "env-a", "label": "env-a"},
                         "online": true, "epoch": "e1", "rev": 4}],
                "rows": [["mc-a", "t1", "thread", {"id": "t1", "title": "t1"}]],
            });
            let frame = frame.as_object().cloned().unwrap();
            let event = McEvent::Frame {
                id,
                frame,
                switched: 0,
            };
            assert!(sides.events.send((own.id, event)).is_ok());
            mc.close();
            crate::store::clear(&engine, |_, _| {});
            if reopened {
                mc.open("http://127.0.0.1:9", "token").unwrap();
            }
            pump.pump(&engine);
            let listed = crate::store::with(&engine, |s| s.threads().len());
            assert_eq!(listed, 0, "reopened: {reopened}");
        }
    }

    #[test]
    fn a_held_subscription_moves_to_the_link_that_replaced_its_own() {
        let (_pump, own) = connection();
        let old = Rc::new(Recorder::default());
        let serving: Rc<RefCell<Rc<dyn Mc>>> = Rc::new(RefCell::new(old.clone()));
        let route = serving.clone();
        own.set_route(Rc::new(move |environment, _| {
            (environment == "studio").then(|| route.borrow().clone())
        }));
        let shape = json!({"type": "thread", "environmentId": "studio", "threadId": "t9"});
        let id = own.subscribe(shape, Box::new(|_, _| {}), None);
        assert_eq!(*old.live.borrow(), [1]);
        // Nothing moved: the link is the same.
        own.reroute();
        assert_eq!(*old.live.borrow(), [1]);

        let new = Rc::new(Recorder::default());
        *serving.borrow_mut() = new.clone();
        own.reroute();
        assert!(old.live.borrow().is_empty());
        assert_eq!(*new.live.borrow(), [1]);
        own.more(id, 10);
        assert_eq!(*new.more.borrow(), [1]);
        assert!(old.more.borrow().is_empty());
        own.unsubscribe(id);
        assert!(new.live.borrow().is_empty());
    }

    #[test]
    fn a_held_subscription_comes_back_when_no_link_serves_it() {
        let (_pump, own) = connection();
        let link = Rc::new(Recorder::default());
        let serving: Rc<RefCell<Option<Rc<dyn Mc>>>> = Rc::new(RefCell::new(Some(link.clone())));
        let route = serving.clone();
        own.set_route(Rc::new(move |_, _| route.borrow().clone()));
        let shape = json!({"type": "thread", "environmentId": "studio", "threadId": "t9"});
        let id = own.subscribe(shape, Box::new(|_, _| {}), None);
        assert_eq!(*link.live.borrow(), [1]);
        // The shell's own client serves it now: it leaves the link.
        *serving.borrow_mut() = None;
        own.reroute();
        assert!(link.live.borrow().is_empty());
        own.more(id, 10);
        assert!(link.more.borrow().is_empty());
        // And goes back to a link that serves it again, under the same id.
        *serving.borrow_mut() = Some(link.clone());
        own.reroute();
        assert_eq!(*link.live.borrow(), [2]);
        own.more(id, 10);
        assert_eq!(*link.more.borrow(), [2]);
        own.unsubscribe(id);
        assert!(link.live.borrow().is_empty());
    }

    #[test]
    fn a_subscription_this_client_served_first_moves_to_a_link_that_comes_to_serve_it() {
        let (_pump, own) = connection();
        let serving: Rc<RefCell<Option<Rc<dyn Mc>>>> = Rc::new(RefCell::new(None));
        let route = serving.clone();
        own.set_route(Rc::new(move |_, _| route.borrow().clone()));
        let shape = json!({"type": "thread", "environmentId": "studio", "threadId": "t9"});
        let id = own.subscribe(shape, Box::new(|_, _| {}), None);
        // The link comes up after: the subscription moves, under the same id.
        let link = Rc::new(Recorder::default());
        *serving.borrow_mut() = Some(link.clone());
        own.reroute();
        assert_eq!(*link.live.borrow(), [1]);
        own.more(id, 10);
        assert_eq!(*link.more.borrow(), [1]);
        own.unsubscribe(id);
        assert!(link.live.borrow().is_empty());
    }
}
