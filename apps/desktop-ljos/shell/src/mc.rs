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

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use hal_c2_mc::{McClient, McEvent};
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
pub type OnFrame = Box<dyn FnMut(&Engine, &Frame)>;
/// What a `sub` frame carries besides its shape (a stream's `offset`,
/// `handle` and `window`), asked each time it is sent: whoever holds the
/// data says where it continues.
pub type Resume = Box<dyn FnMut() -> Frame>;
pub type OnReady = Box<dyn FnMut(&Engine, bool)>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SubId(pub u64);

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

/// The real MC, over `hal_c2_mc`.
pub struct Connection {
    client: McClient,
    queue: McQueue,
}

impl Connection {
    /// Starts the I/O thread; `wake` runs on it whenever events wait for
    /// [`Connection::deliver`] (the shell posts to its inbox).
    pub fn spawn(wake: impl Fn() + Send + 'static) -> Connection {
        let queue = McQueue::default();
        let sink = queue.clone();
        let handle = hal_c2_mc::spawn(move |event| {
            if sink.push(event) {
                wake();
            }
        });
        Connection {
            client: McClient::new(handle),
            queue,
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

    /// Hands what the I/O thread said to the callbacks, in order.
    pub fn deliver(&self, engine: &Engine) {
        let events = self.queue.take();
        if events.is_empty() {
            return;
        }
        let outer = DELIVERING.with(|d| d.borrow_mut().replace(engine.clone()));
        for event in events {
            self.client.deliver(event);
        }
        DELIVERING.with(|d| *d.borrow_mut() = outer);
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
