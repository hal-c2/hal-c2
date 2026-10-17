//! The controllers' MC: what they ask of it, whoever answers.
//!
//! [`Mc`] is the seam. [`Connection`] is the real one, over the `hal_c2_mc`
//! crate's [`McClient`]: its I/O thread hands every event to a sink, which
//! queues it and wakes the UI through the shell's inbox; the UI thread then
//! hands the queue to [`Connection::deliver`], where replies and frames reach
//! the controllers. [`Disconnected`] is the shell with no MC (a render, a
//! test that needs none).
//!
//! Every callback runs on the UI thread, with the engine, and never inside
//! the call that registered it, so a controller can register one while it
//! holds itself.
//!
//! Besides RPC, the MC's origin serves streams the socket does not carry (a
//! device's screen and input through `/api/device-hub`): [`Mc::open_stream`]
//! opens one with the access token, and its events reach the UI the same way.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};

use hal_c2_mc::stream::Stream;
pub use hal_c2_mc::stream::{StreamEnd, StreamEvent};
use hal_c2_mc::{McClient, McEvent};
pub use hal_c2_mc::{Phase, Status};
use ljos::prelude::Engine;

use crate::json::Json;

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

/// What the I/O thread said, waiting for the UI thread. Only the wake-up
/// goes through the shell's inbox, coalesced: the UI thread takes whatever
/// queued in one turn, and the I/O thread never waits on it (as it would
/// with a message per frame and `send_blocking`).
#[derive(Clone, Default)]
pub struct McQueue(Arc<Mutex<VecDeque<McEvent>>>);

impl McQueue {
    /// Queues `event`; true when the queue was empty, so the UI needs waking.
    pub fn push(&self, event: McEvent) -> bool {
        let mut queue = self.0.lock().unwrap_or_else(|e| e.into_inner());
        queue.push_back(event);
        queue.len() == 1
    }

    fn take(&self) -> VecDeque<McEvent> {
        std::mem::take(&mut *self.0.lock().unwrap_or_else(|e| e.into_inner()))
    }
}

thread_local! {
    /// The engine while [`Connection::deliver`] runs: `McClient`'s callbacks
    /// get none, and every one of them runs inside `deliver`.
    static DELIVERING: RefCell<Option<Engine>> = const { RefCell::new(None) };
}

fn with_delivering(f: impl FnOnce(&Engine)) {
    let engine = DELIVERING.with(|d| d.borrow().clone());
    match engine {
        Some(engine) => f(&engine),
        None => debug_assert!(
            false,
            "an McClient callback ran outside Connection::deliver"
        ),
    }
}

/// The streams' events waiting for the UI thread, each with its stream's id;
/// woken as [`McQueue`].
#[derive(Clone, Default)]
struct StreamQueue(Arc<Mutex<VecDeque<(u64, StreamEvent)>>>);

impl StreamQueue {
    fn push(&self, id: u64, event: StreamEvent) -> bool {
        let mut queue = self.0.lock().unwrap_or_else(|e| e.into_inner());
        queue.push_back((id, event));
        queue.len() == 1
    }

    fn take(&self) -> VecDeque<(u64, StreamEvent)> {
        std::mem::take(&mut *self.0.lock().unwrap_or_else(|e| e.into_inner()))
    }
}

type Wake = Arc<Mutex<Box<dyn Fn() + Send>>>;

/// An open stream and its handler, out of the map while it runs.
struct OpenStream {
    stream: Stream,
    on_event: Option<OnStream>,
}

/// The real MC, over `hal_c2_mc`.
pub struct Connection {
    client: McClient,
    queue: McQueue,
    wake: Wake,
    stream_queue: StreamQueue,
    streams: RefCell<HashMap<u64, OpenStream>>,
    next_stream: Cell<u64>,
}

impl Connection {
    /// Starts the I/O thread; `wake` runs on it (or a stream's thread)
    /// whenever events wait for [`Connection::deliver`] (the shell posts to
    /// its inbox).
    pub fn spawn(wake: impl Fn() + Send + 'static) -> Connection {
        let wake: Wake = Arc::new(Mutex::new(Box::new(wake)));
        let queue = McQueue::default();
        let sink = queue.clone();
        let waking = wake.clone();
        let handle = hal_c2_mc::spawn(move |event| {
            if sink.push(event) {
                (waking.lock().unwrap_or_else(|e| e.into_inner()))();
            }
        });
        Connection {
            client: McClient::new(handle),
            queue,
            wake,
            stream_queue: StreamQueue::default(),
            streams: RefCell::default(),
            next_stream: Cell::new(0),
        }
    }

    pub fn client(&self) -> &McClient {
        &self.client
    }

    /// Connects to the MC at `origin` (`http://127.0.0.1:3773`) with the
    /// token host/main.ts would hand over.
    pub fn open(&self, origin: &str, token: &str) -> Result<(), String> {
        let origin = url::Url::parse(origin).map_err(|e| format!("{origin}: {e}"))?;
        self.client.open(origin, token);
        Ok(())
    }

    /// Hands what the I/O thread and the streams said to the callbacks, in
    /// order.
    pub fn deliver(&self, engine: &Engine) {
        let events = self.queue.take();
        if !events.is_empty() {
            let outer = DELIVERING.with(|d| d.borrow_mut().replace(engine.clone()));
            for event in events {
                self.client.deliver(event);
            }
            DELIVERING.with(|d| *d.borrow_mut() = outer);
        }
        for (id, event) in self.stream_queue.take() {
            self.deliver_stream(engine, id, event);
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
        self.client
            .call(environment, method, payload, move |result| {
                with_delivering(|engine| reply(engine, result.map_err(McError::from)));
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
        let frame = move |frame: &Frame| with_delivering(|engine| on_frame(engine, frame));
        SubId(match resume {
            Some(resume) => self.client.subscribe_resuming(shape, frame, resume),
            None => self.client.subscribe(shape, frame),
        })
    }

    fn unsubscribe(&self, id: SubId) {
        self.client.unsubscribe(id.0);
    }

    fn more(&self, id: SubId, items: u32) {
        self.client.more(id.0, items);
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
        let (queue, wake) = (self.stream_queue.clone(), self.wake.clone());
        let stream = hal_c2_mc::stream::open(request, socket, move |event| {
            if queue.push(id, event) {
                (wake.lock().unwrap_or_else(|e| e.into_inner()))();
            }
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
