//! The owner's side of a connection, on the thread that runs the UI.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::rc::{Rc, Weak};
use std::time::Duration;

use serde_json::{Map, Value};
use url::Url;

use crate::{CallError, Frame, McEvent, McHandle, Phase, Status};

pub type SubId = u64;
pub type ListenerId = u64;

type StatusListener = Box<dyn FnMut(&Status)>;
type CheckedListener = Box<dyn FnMut(bool)>;
type FrameHandler = Box<dyn FnMut(&Frame)>;
type Resume = Box<dyn FnMut() -> Frame>;
type Reply = Box<dyn FnOnce(Result<Value, CallError>)>;
type BytesReply = Box<dyn FnOnce(Result<Vec<u8>, CallError>)>;

/// The shell's connection to its MC, as its controllers use it: subscriptions
/// multiplexed by id, sent once the MC says hello and again after every
/// reconnect or `resync`, from where their owner says they had got to
/// (`resume`), or whole; calls with replies.
///
/// It lives on one thread (the UI's) and holds every callback; the I/O runs
/// behind its [`McHandle`]. Feed it every [`McEvent`] the handle's sink got,
/// in order, with [`McClient::deliver`]. Callbacks run inside `deliver`, never
/// inside the call that registered them, and may call back into the client.
///
/// Cloning is cheap and shares the connection. Callbacks that keep the
/// client should hold a [`WeakMcClient`]: a callback holding a clone keeps
/// itself alive. Once the last clone goes the connection closes and no
/// callback runs again.
#[derive(Clone)]
pub struct McClient {
    inner: Rc<Inner>,
}

/// A [`McClient`] that does not keep it alive.
#[derive(Clone)]
pub struct WeakMcClient {
    inner: Weak<Inner>,
}

impl WeakMcClient {
    pub fn upgrade(&self) -> Option<McClient> {
        self.inner.upgrade().map(|inner| McClient { inner })
    }
}

struct Inner {
    handle: McHandle,
    state: RefCell<State>,
}

impl Drop for Inner {
    fn drop(&mut self) {
        // Whoever is owed a reply is going too.
        self.handle.close();
    }
}

#[derive(Default)]
struct State {
    origin: Option<Url>,
    token: String,
    status: Status,
    /// The ready connection, as the last status said.
    connection: Option<u64>,
    subscriptions: BTreeMap<SubId, Subscription>,
    replies: HashMap<u64, Pending>,
    next_listener: ListenerId,
    status_listeners: Vec<(ListenerId, Option<StatusListener>)>,
    checked_listeners: Vec<(ListenerId, Option<CheckedListener>)>,
}

struct Subscription {
    shape: Value,
    // Taken out while it runs, so it may call back into the client.
    on_frame: Option<FrameHandler>,
    resume: Option<Resume>,
    resumes: bool,
}

enum Pending {
    Value(Reply),
    Bytes(BytesReply),
}

/// A request for the MC's origin carrying the access token, for streams the
/// socket does not carry (a device's screen through /api/device-hub).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthorizedRequest {
    pub url: Url,
    /// The `Authorization` header's value.
    pub authorization: String,
}

impl McClient {
    pub fn new(handle: McHandle) -> Self {
        Self {
            inner: Rc::new(Inner {
                handle,
                state: RefCell::default(),
            }),
        }
    }

    pub fn downgrade(&self) -> WeakMcClient {
        WeakMcClient {
            inner: Rc::downgrade(&self.inner),
        }
    }

    pub fn handle(&self) -> &McHandle {
        &self.inner.handle
    }

    /// Takes in what the connection said. Every event the sink got, in order.
    pub fn deliver(&self, event: McEvent) {
        match event {
            McEvent::Status(status) => self.take_status(status),
            McEvent::Frame { id, frame } => self.on_frame(id, frame),
            McEvent::Reply { id, result } => {
                let pending = self.state().replies.remove(&id);
                if let Some(Pending::Value(reply)) = pending {
                    reply(result);
                }
            }
            McEvent::Bytes { id, result } => {
                let pending = self.state().replies.remove(&id);
                if let Some(Pending::Bytes(reply)) = pending {
                    reply(result);
                }
            }
            McEvent::Checked(alive) => self.notify_checked(alive),
        }
    }

    // A new connection is sent every subscription, each from where its owner
    // says it got to; then the status is told.
    fn take_status(&self, status: Status) {
        let resend = {
            let mut state = self.state();
            let resend = status.connection.filter(|c| state.connection != Some(*c));
            state.connection = status.connection;
            state.status = status.clone();
            resend.map(|_| state.subscriptions.keys().copied().collect::<Vec<_>>())
        };
        for id in resend.into_iter().flatten() {
            self.send_sub(id);
        }
        self.notify_status(&status);
    }

    fn on_frame(&self, id: SubId, frame: Frame) {
        let kind = frame
            .get("t")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let handler = {
            let mut state = self.state();
            let Some(subscription) = state.subscriptions.get_mut(&id) else {
                return;
            };
            let handler = subscription.on_frame.take();
            // The MC ended the shape and already forgot it.
            if kind == "end" {
                state.subscriptions.remove(&id);
            }
            handler
        };
        let Some(mut handler) = handler else { return };
        handler(&frame);
        if let Some(subscription) = self.state().subscriptions.get_mut(&id) {
            subscription.on_frame.get_or_insert(handler);
        }
        if kind == "resync" {
            // Fell behind, and the MC dropped the shape: its owner took the
            // offset the MC names, and it is asked for again from there.
            self.send_sub(id);
        }
    }

    fn send_sub(&self, id: SubId) {
        let (connection, resume) = {
            let mut state = self.state();
            let Some(connection) = state.connection else {
                return;
            };
            let Some(subscription) = state.subscriptions.get_mut(&id) else {
                return;
            };
            (connection, subscription.resume.take())
        };
        let resumed = resume.map(|mut resume| (resume(), resume));
        let frame = {
            let mut state = self.state();
            let Some(subscription) = state.subscriptions.get_mut(&id) else {
                return;
            };
            let mut frame = Map::new();
            frame.insert("t".into(), "sub".into());
            frame.insert("id".into(), id.into());
            frame.insert("shape".into(), subscription.shape.clone());
            frame.insert("offset".into(), Value::Null);
            if let Some((fields, resume)) = resumed {
                frame.extend(fields);
                subscription.resume.get_or_insert(resume);
            } else if subscription.resumes {
                // Its resume is running further up (it subscribed from inside
                // it): it sends the subscription itself once it returns.
                return;
            }
            frame
        };
        self.inner.handle.send_sub(connection, frame);
    }

    fn state(&self) -> std::cell::RefMut<'_, State> {
        self.inner.state.borrow_mut()
    }

    /// `origin` is the MC's http(s) origin; the token is its access token.
    pub fn open(&self, origin: Url, token: impl Into<String>) {
        let token = token.into();
        {
            let mut state = self.state();
            state.origin = Some(origin.clone());
            state.token = token.clone();
        }
        self.inner.handle.open(origin, token);
    }

    pub fn close(&self) {
        self.inner.handle.close();
    }

    /// Drops the socket and connects again.
    pub fn reconnect(&self) {
        self.inner.handle.reconnect();
    }

    /// Whether this device has a network. Offline, a drop is not retried until
    /// the network is back.
    pub fn set_online(&self, online: bool) {
        self.inner.handle.set_online(online);
    }

    /// The app came to the foreground: a waiting retry runs now, and a ready
    /// connection is checked ([`McClient::on_checked`]) and replaced if it does
    /// not answer.
    pub fn wake(&self) {
        self.inner.handle.wake();
    }

    /// Tries again now, whatever it was waiting for.
    pub fn retry_now(&self) {
        self.inner.handle.retry_now();
    }

    /// The connection's status as last delivered.
    pub fn status(&self) -> Status {
        self.state().status.clone()
    }

    pub fn phase(&self) -> Phase {
        self.state().status.phase
    }

    pub fn is_ready(&self) -> bool {
        self.state().connection.is_some()
    }

    /// The MC's node name, from its hello.
    pub fn mc(&self) -> String {
        self.state().status.mc.clone()
    }

    /// The environment the MC itself serves; empty until the first hello.
    pub fn environment(&self) -> String {
        self.state().status.environment.clone()
    }

    /// The http(s) origin the MC was opened at.
    pub fn origin(&self) -> Option<Url> {
        self.state().origin.clone()
    }

    /// Runs `listener` with every new status (phase, readiness, failure...),
    /// after any subscriptions were sent again on a new connection.
    pub fn on_status(&self, listener: impl FnMut(&Status) + 'static) -> ListenerId {
        let mut state = self.state();
        state.next_listener += 1;
        let id = state.next_listener;
        state.status_listeners.push((id, Some(Box::new(listener))));
        id
    }

    /// Runs `listener` when a ping was answered (`true`), or was not in time
    /// and the socket is replaced (`false`).
    pub fn on_checked(&self, listener: impl FnMut(bool) + 'static) -> ListenerId {
        let mut state = self.state();
        state.next_listener += 1;
        let id = state.next_listener;
        state.checked_listeners.push((id, Some(Box::new(listener))));
        id
    }

    pub fn remove_listener(&self, id: ListenerId) {
        let mut state = self.state();
        state
            .status_listeners
            .retain(|(listener, _)| *listener != id);
        state
            .checked_listeners
            .retain(|(listener, _)| *listener != id);
    }

    fn notify_status(&self, status: &Status) {
        let ids: Vec<_> = self
            .state()
            .status_listeners
            .iter()
            .map(|(id, _)| *id)
            .collect();
        for id in ids {
            let listener = self
                .state()
                .status_listeners
                .iter_mut()
                .find(|(listener, _)| *listener == id)
                .and_then(|(_, listener)| listener.take());
            let Some(mut listener) = listener else {
                continue;
            };
            listener(status);
            if let Some((_, slot)) = self
                .state()
                .status_listeners
                .iter_mut()
                .find(|(l, _)| *l == id)
            {
                slot.get_or_insert(listener);
            }
        }
    }

    fn notify_checked(&self, alive: bool) {
        let ids: Vec<_> = self
            .state()
            .checked_listeners
            .iter()
            .map(|(id, _)| *id)
            .collect();
        for id in ids {
            let listener = self
                .state()
                .checked_listeners
                .iter_mut()
                .find(|(listener, _)| *listener == id)
                .and_then(|(_, listener)| listener.take());
            let Some(mut listener) = listener else {
                continue;
            };
            listener(alive);
            if let Some((_, slot)) = self
                .state()
                .checked_listeners
                .iter_mut()
                .find(|(l, _)| *l == id)
            {
                slot.get_or_insert(listener);
            }
        }
    }

    /// Follows `shape`, asked for whole each time it is sent.
    pub fn subscribe(&self, shape: Value, on_frame: impl FnMut(&Frame) + 'static) -> SubId {
        self.add_subscription(shape, Box::new(on_frame), None)
    }

    /// Follows `shape`; `resume` gives what a `sub` frame carries besides its
    /// shape: a stream's `offset`, `handle` and `window`, the shell's `have`.
    /// It is asked each time the frame is sent, so whoever holds the data is
    /// the one to say where it continues.
    pub fn subscribe_resuming(
        &self,
        shape: Value,
        on_frame: impl FnMut(&Frame) + 'static,
        resume: impl FnMut() -> Frame + 'static,
    ) -> SubId {
        self.add_subscription(shape, Box::new(on_frame), Some(Box::new(resume)))
    }

    fn add_subscription(
        &self,
        shape: Value,
        on_frame: FrameHandler,
        resume: Option<Resume>,
    ) -> SubId {
        let id = self.inner.handle.next_id();
        let resumes = resume.is_some();
        self.state().subscriptions.insert(
            id,
            Subscription {
                shape,
                on_frame: Some(on_frame),
                resume,
                resumes,
            },
        );
        self.send_sub(id);
        id
    }

    /// Ends subscription `id`; no frame reaches its handler after this.
    pub fn unsubscribe(&self, id: SubId) {
        let connection = {
            let mut state = self.state();
            if state.subscriptions.remove(&id).is_none() {
                return;
            }
            state.connection
        };
        if let Some(connection) = connection {
            self.inner.handle.send_unsub(connection, id);
        }
    }

    /// Asks a windowed stream for the runs before its window that hold `items`
    /// turn items; a `page` frame answers.
    pub fn more(&self, id: SubId, items: u32) {
        let connection = {
            let state = self.state();
            if !state.subscriptions.contains_key(&id) {
                return;
            }
            state.connection
        };
        if let Some(connection) = connection {
            self.inner.handle.send_more(connection, id, items);
        }
    }

    /// A client RPC run where `environment` is served. `reply` gets the result,
    /// or why it failed: the MC's error, or "not connected" / "disconnected"
    /// when the socket was not there to carry it.
    pub fn call(
        &self,
        environment: &str,
        method: &str,
        payload: Value,
        reply: impl FnOnce(Result<Value, CallError>) + 'static,
    ) {
        let id = self.expect(Pending::Value(Box::new(reply)));
        self.inner.handle.call(id, environment, method, payload);
    }

    /// `orchestration.dispatchCommand` with a fresh commandId.
    pub fn dispatch_command(
        &self,
        environment: &str,
        mut command: Map<String, Value>,
        reply: impl FnOnce(Result<Value, CallError>) + 'static,
    ) {
        command.insert("commandId".into(), crate::new_uuid().into());
        self.call(
            environment,
            "orchestration.dispatchCommand",
            Value::Object(command),
            reply,
        );
    }

    /// POSTs `body` to `path` of the MC's origin (its HTTP API, for answers
    /// too large for the socket, as `/api/pull-requests/diff`), with the
    /// access token. A refusal's error is the body's `message`, `detail` or
    /// `_tag`, else the HTTP status; its detail is then the body.
    pub fn post(
        &self,
        path: &str,
        body: Value,
        reply: impl FnOnce(Result<Value, CallError>) + 'static,
    ) {
        let id = self.expect(Pending::Value(Box::new(reply)));
        self.inner.handle.post(id, path, body);
    }

    /// GETs `path` of the MC's origin (its HTTP API, as `/api/auth/session`)
    /// with the access token. A refusal reads as a [`McClient::post`]'s does.
    pub fn get(&self, path: &str, reply: impl FnOnce(Result<Value, CallError>) + 'static) {
        let id = self.expect(Pending::Value(Box::new(reply)));
        self.inner.handle.get(id, path);
    }

    /// POSTs `bytes` to a signed URL the MC handed out (`relativeUrl`, as
    /// `attachments.createUploadUrl`'s): the URL is its own authorization.
    pub fn upload(
        &self,
        relative_url: &str,
        bytes: Vec<u8>,
        mime_type: &str,
        reply: impl FnOnce(Result<Value, CallError>) + 'static,
    ) {
        let id = self.expect(Pending::Value(Box::new(reply)));
        self.inner.handle.upload(id, relative_url, bytes, mime_type);
    }

    /// GETs a signed URL the MC handed out (`assets.createUrl`'s
    /// `relativeUrl`) and gives its bytes, or why it could not be read.
    pub fn download(
        &self,
        relative_url: &str,
        reply: impl FnOnce(Result<Vec<u8>, CallError>) + 'static,
    ) {
        let id = self.expect(Pending::Bytes(Box::new(reply)));
        self.inner.handle.download(id, relative_url);
    }

    fn expect(&self, pending: Pending) -> u64 {
        let id = self.inner.handle.next_id();
        self.state().replies.insert(id, pending);
        id
    }

    /// A request for `path` (and `query`), both percent-encoded, on the MC's
    /// origin carrying the access token. `socket`: its ws(s) twin. None before
    /// the client was opened.
    pub fn request(&self, path: &str, query: &str, socket: bool) -> Option<AuthorizedRequest> {
        let state = self.state();
        let mut url = state.origin.clone()?;
        if socket {
            let scheme = if url.scheme() == "https" { "wss" } else { "ws" };
            url.set_scheme(scheme).ok()?;
        }
        // Already encoded: an MC's hubBasePath carries `mcs/<name%40host>`.
        url.set_path(path);
        url.set_query((!query.is_empty()).then_some(query));
        url.set_fragment(None);
        Some(AuthorizedRequest {
            url,
            authorization: format!("Bearer {}", state.token),
        })
    }

    pub fn set_retry_delays(&self, delays: Vec<Duration>) {
        self.inner.handle.set_retry_delays(delays);
    }

    pub fn set_ping_interval(&self, interval: Duration) {
        self.inner.handle.set_ping_interval(interval);
    }

    /// How long a ping may go unanswered before the connection counts as dead.
    pub fn set_pong_timeout(&self, timeout: Duration) {
        self.inner.handle.set_pong_timeout(timeout);
    }
}
