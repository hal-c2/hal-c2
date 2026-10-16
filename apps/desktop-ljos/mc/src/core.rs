//! The connection's decisions, without I/O: [`Core::handle`] takes one input
//! (a command, an answer from the network, the clock) and says what to do as
//! [`Effect`]s. The driver runs them; the property tests play the network.
//!
//! One owner of retries. Before each socket it reads the MC's descriptor
//! (`/.well-known/hal-c2/environment`) and stays blocked on a protocol it does
//! not speak. A socket that drops is retried with growing delays; without a
//! network it waits for one, and a credential the MC refuses waits for the
//! user ([`Phase::Refused`]). The MC's own access token opens the socket as
//! `?token=`; a paired session's token does not, so a handshake that fails
//! asks the MC for a socket ticket (`/api/auth/websocket-ticket`): it either
//! gets one and opens with `?wsTicket=` from then on, or learns the credential
//! is refused. Wake cuts a waiting retry short and checks a connection that
//! looks healthy.

use std::collections::BTreeSet;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};
use url::Url;

use crate::{CallError, Frame, McEvent, PROTOCOL, Phase, Status, new_trace_id};

pub(crate) const DEFAULT_RETRY_DELAYS: [Duration; 5] = [
    Duration::from_millis(500),
    Duration::from_millis(1000),
    Duration::from_millis(2000),
    Duration::from_millis(4000),
    Duration::from_millis(8000),
];

/// What an owner asks of the connection, through [`crate::McHandle`].
#[derive(Debug)]
pub(crate) enum Command {
    Open {
        origin: Url,
        token: String,
    },
    Close,
    Reconnect,
    SetOnline(bool),
    Wake,
    RetryNow,
    /// A whole `sub` frame, sent only if `connection` is still the ready one.
    Sub {
        connection: u64,
        frame: Frame,
    },
    Unsub {
        connection: u64,
        id: u64,
    },
    More {
        connection: u64,
        id: u64,
        items: u32,
    },
    Call {
        id: u64,
        environment: String,
        method: String,
        payload: Value,
    },
    Http {
        id: u64,
        request: HttpCall,
    },
    SetRetryDelays(Vec<Duration>),
    SetPingInterval(Duration),
    SetPongTimeout(Duration),
}

/// A request on the MC's HTTP API whose answer goes straight to its owner.
#[derive(Debug, Clone)]
pub(crate) enum HttpCall {
    /// POSTs JSON to `path`, with the access token.
    Post { path: String, body: Value },
    /// POSTs bytes to a signed URL; the URL is its own authorization.
    Upload {
        relative_url: String,
        bytes: Vec<u8>,
        mime_type: String,
    },
    /// GETs a signed URL.
    Download { relative_url: String },
}

/// What a plain HTTP request came back with.
#[derive(Debug, Clone, Default)]
pub(crate) struct HttpAnswer {
    /// None when no response came.
    pub status: Option<u16>,
    pub body: Vec<u8>,
    pub error: Option<NetError>,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum NetError {
    /// Nobody there (refused, or no such host): the socket would only fail the same way.
    Unreachable(String),
    Timeout,
    /// Anything else (TLS, protocol): left to the socket to tell.
    Other(String),
}

/// How a socket ended, as the driver saw it.
#[derive(Debug, Clone, Default)]
pub(crate) struct SocketEnd {
    /// The MC's close code.
    pub code: Option<u16>,
    /// The MC's close reason.
    pub reason: String,
    /// What went wrong, when something did.
    pub error: Option<String>,
    pub timed_out: bool,
}

#[derive(Debug)]
pub(crate) enum Input {
    Command(Command),
    Descriptor {
        attempt: u64,
        answer: HttpAnswer,
    },
    Ticket {
        attempt: u64,
        answer: HttpAnswer,
    },
    SocketText {
        attempt: u64,
        text: String,
    },
    SocketClosed {
        attempt: u64,
        end: SocketEnd,
    },
    /// An answer that goes to the owner as it is (an HTTP call's).
    Deliver(McEvent),
    /// The clock moved: run what is due.
    Tick,
}

#[derive(Debug)]
pub(crate) enum Effect {
    Emit(McEvent),
    GetDescriptor {
        attempt: u64,
        url: Url,
        token: String,
    },
    PostTicket {
        attempt: u64,
        url: Url,
        token: String,
    },
    OpenSocket {
        attempt: u64,
        url: Url,
        traceparent: String,
    },
    Send {
        attempt: u64,
        text: String,
    },
    /// Abort the socket: its end has already been handled.
    CloseSocket {
        attempt: u64,
    },
    Http {
        id: u64,
        origin: Url,
        token: String,
        request: HttpCall,
    },
}

pub(crate) struct Core {
    origin: Option<Url>,
    ws_url: Option<Url>,
    token: String,
    closed: bool,
    online: bool,
    phase: Phase,
    failure: String,
    trace_id: String,
    failure_trace_id: String,
    /// Why the socket is being dropped from this side ("timeout").
    drop_reason: String,
    descriptor: Arc<Map<String, Value>>,
    retry_delay: Duration,
    blocked_protocol: Option<i64>,
    /// Bumped by every attempt: an answer to an older one is ignored.
    attempt: u64,
    /// The attempt whose socket is open or opening.
    socket: Option<u64>,
    /// The token is a paired session's: every socket needs a ticket.
    ticketed: bool,
    mc: String,
    environment: String,
    retries: u32,
    ready: bool,
    /// Hellos so far; the ready connection is the latest.
    hellos: u64,
    /// Calls in flight on the socket, answered "disconnected" if it goes.
    calls: BTreeSet<u64>,
    retry_delays: Vec<Duration>,
    ping_interval: Duration,
    pong_timeout: Duration,
    retry_at: Option<Instant>,
    ping_at: Option<Instant>,
    pong_by: Option<Instant>,
    last_status: Status,
    effects: Vec<Effect>,
    now: Instant,
}

impl Core {
    pub fn new(now: Instant) -> Self {
        Self {
            origin: None,
            ws_url: None,
            token: String::new(),
            closed: true,
            online: true,
            phase: Phase::Closed,
            failure: String::new(),
            trace_id: String::new(),
            failure_trace_id: String::new(),
            drop_reason: String::new(),
            descriptor: Arc::default(),
            retry_delay: Duration::ZERO,
            blocked_protocol: None,
            attempt: 0,
            socket: None,
            ticketed: false,
            mc: String::new(),
            environment: String::new(),
            retries: 0,
            ready: false,
            hellos: 0,
            calls: BTreeSet::new(),
            retry_delays: DEFAULT_RETRY_DELAYS.to_vec(),
            ping_interval: Duration::from_secs(25),
            pong_timeout: Duration::from_secs(10),
            retry_at: None,
            ping_at: None,
            pong_by: None,
            last_status: Status::default(),
            effects: Vec::new(),
            now,
        }
    }

    /// When the next timer is due, for the driver to wake and send [`Input::Tick`].
    pub fn next_deadline(&self) -> Option<Instant> {
        [self.retry_at, self.ping_at, self.pong_by]
            .into_iter()
            .flatten()
            .min()
    }

    pub fn handle(&mut self, input: Input, now: Instant) -> Vec<Effect> {
        self.now = now;
        match input {
            Input::Command(command) => self.command(command),
            Input::Descriptor { attempt, answer } => self.on_descriptor(attempt, answer),
            Input::Ticket { attempt, answer } => self.on_ticket(attempt, answer),
            Input::SocketText { attempt, text } => {
                if self.socket == Some(attempt) {
                    self.on_message(&text);
                }
            }
            Input::SocketClosed { attempt, end } => self.on_closed(attempt, end),
            Input::Deliver(event) => self.emit(event),
            Input::Tick => self.tick(),
        }
        let status = self.status();
        if !same_status(&status, &self.last_status) {
            self.last_status = status.clone();
            self.emit(McEvent::Status(status));
        }
        std::mem::take(&mut self.effects)
    }

    pub fn status(&self) -> Status {
        Status {
            phase: self.phase,
            connection: self.ready.then_some(self.hellos),
            failure: self.failure.clone(),
            failure_trace_id: self.failure_trace_id.clone(),
            retry_delay: self.retry_delay,
            retries: self.retries,
            blocked_protocol: self.blocked_protocol,
            descriptor: self.descriptor.clone(),
            mc: self.mc.clone(),
            environment: self.environment.clone(),
        }
    }

    /// The attempt an answer must carry to count.
    #[cfg(test)]
    pub(crate) fn attempt(&self) -> u64 {
        self.attempt
    }

    fn emit(&mut self, event: McEvent) {
        self.effects.push(Effect::Emit(event));
    }

    fn command(&mut self, command: Command) {
        match command {
            Command::Open { origin, token } => self.open(origin, token),
            Command::Close => self.close(),
            Command::Reconnect => {
                if let Some(origin) = self.origin.clone() {
                    let token = self.token.clone();
                    self.close();
                    self.open(origin, token);
                }
            }
            Command::SetOnline(online) => self.set_online(online),
            Command::Wake => self.wake(),
            Command::RetryNow => self.retry_now(),
            Command::Sub { connection, frame } => {
                if self.is_connection(connection) {
                    self.send(&Value::Object(frame));
                }
            }
            Command::Unsub { connection, id } => {
                if self.is_connection(connection) {
                    self.send(&json!({"t": "unsub", "id": id}));
                }
            }
            Command::More {
                connection,
                id,
                items,
            } => {
                if self.is_connection(connection) {
                    self.send(&json!({"t": "more", "id": id, "items": items}));
                }
            }
            Command::Call {
                id,
                environment,
                method,
                payload,
            } => self.call(id, environment, method, payload),
            Command::Http { id, request } => match &self.origin {
                Some(origin) if !self.closed => self.effects.push(Effect::Http {
                    id,
                    origin: origin.clone(),
                    token: self.token.clone(),
                    request,
                }),
                _ => {
                    let event = match request {
                        HttpCall::Download { .. } => McEvent::Bytes {
                            id,
                            result: Err(CallError::not_connected()),
                        },
                        _ => McEvent::Reply {
                            id,
                            result: Err(CallError::not_connected()),
                        },
                    };
                    self.emit(event);
                }
            },
            Command::SetRetryDelays(delays) => self.retry_delays = delays,
            Command::SetPingInterval(interval) => {
                self.ping_interval = interval;
                if self.ping_at.is_some() {
                    self.ping_at = Some(self.now + interval);
                }
            }
            Command::SetPongTimeout(timeout) => self.pong_timeout = timeout,
        }
    }

    /// A `sub`, `unsub` or `more` made for `connection` is sent only on it: an
    /// owner that has not yet heard of a newer hello sends its subscriptions
    /// again once it does.
    fn is_connection(&self, connection: u64) -> bool {
        self.ready && connection == self.hellos
    }

    // `origin` is the MC's http(s) origin; the token is its access token.
    // Opening an open connection starts it over, as a reconnect.
    fn open(&mut self, origin: Url, token: String) {
        if !self.closed {
            self.close();
        }
        let mut url = origin.clone();
        let _ = url.set_scheme(if origin.scheme() == "https" {
            "wss"
        } else {
            "ws"
        });
        url.set_path("/ws");
        url.set_fragment(None);
        url.query_pairs_mut().clear().append_pair("token", &token);
        self.origin = Some(origin);
        self.ws_url = Some(url);
        self.token = token;
        self.closed = false;
        self.retries = 0;
        self.failure.clear();
        self.failure_trace_id.clear();
        self.blocked_protocol = None;
        self.ticketed = false;
        self.connect();
    }

    fn close(&mut self) {
        self.closed = true;
        self.attempt += 1;
        self.retry_at = None;
        self.pong_by = None;
        if let Some(attempt) = self.socket.take() {
            self.effects.push(Effect::CloseSocket { attempt });
        }
        self.ready = false;
        self.ping_at = None;
        // The socket that carried them is gone: they are answered as by a drop.
        self.fail_calls();
        self.phase = Phase::Closed;
    }

    /// Answers every call in flight with "disconnected", in the order they
    /// were made, so a caller's later call fails after its earlier one.
    fn fail_calls(&mut self) {
        for id in std::mem::take(&mut self.calls) {
            self.emit(McEvent::Reply {
                id,
                result: Err(CallError::disconnected()),
            });
        }
    }

    fn set_online(&mut self, online: bool) {
        if online == self.online {
            return;
        }
        self.online = online;
        if self.closed {
            return;
        }
        if online {
            if self.phase == Phase::Offline {
                self.retry_now();
            }
        } else if self.phase == Phase::Retrying {
            // The retry would only fail: wait for the network instead.
            self.retry_at = None;
            self.phase = Phase::Offline;
        }
    }

    fn wake(&mut self) {
        if self.closed {
            return;
        }
        if self.phase == Phase::Retrying {
            self.retry_now();
        } else if self.ready {
            self.ping();
        }
    }

    fn retry_now(&mut self) {
        if self.closed || self.ready || self.phase == Phase::Connecting {
            return;
        }
        self.retry_at = None;
        self.retries = 0;
        self.connect();
    }

    // One ping at a time: the pong (or any frame) must come before the timeout.
    fn ping(&mut self) {
        if !self.ready {
            return;
        }
        self.send(&json!({"t": "ping"}));
        if self.pong_by.is_none() {
            self.pong_by = Some(self.now + self.pong_timeout);
        }
    }

    // Gives up on a socket that stopped answering; it is retried like any drop.
    fn drop_socket(&mut self, reason: &str) {
        let Some(attempt) = self.socket else { return };
        self.drop_reason = reason.to_owned();
        self.effects.push(Effect::CloseSocket { attempt });
        self.on_closed(attempt, SocketEnd::default());
    }

    fn call(&mut self, id: u64, environment: String, method: String, payload: Value) {
        if !self.ready {
            self.emit(McEvent::Reply {
                id,
                result: Err(CallError::not_connected()),
            });
            return;
        }
        self.calls.insert(id);
        self.send(&json!({
            "t": "rpc",
            "id": id,
            "environment": environment,
            "method": method,
            "payload": payload,
        }));
    }

    fn tick(&mut self) {
        let now = self.now;
        if self.retry_at.is_some_and(|at| at <= now) {
            self.retry_at = None;
            self.connect();
        }
        if self.pong_by.is_some_and(|at| at <= now) {
            self.pong_by = None;
            self.emit(McEvent::Checked(false));
            self.drop_socket("timeout");
        }
        if let Some(at) = self.ping_at.filter(|at| *at <= now) {
            // A clock that jumped ahead pings once, not once per missed interval.
            self.ping_at = Some((at + self.ping_interval).max(now));
            self.ping();
        }
    }

    // One attempt: the MC's descriptor first, which says whether its protocol is
    // one this client speaks, then the socket.
    fn connect(&mut self) {
        if self.closed {
            return;
        }
        if !self.online {
            self.phase = Phase::Offline;
            return;
        }
        let Some(origin) = self.origin.clone() else {
            return;
        };
        self.attempt += 1;
        self.trace_id = new_trace_id();
        self.drop_reason.clear();
        self.retry_delay = Duration::ZERO;
        self.phase = Phase::Connecting;
        self.effects.push(Effect::GetDescriptor {
            attempt: self.attempt,
            url: at_path(&origin, "/.well-known/hal-c2/environment"),
            token: self.token.clone(),
        });
    }

    fn on_descriptor(&mut self, attempt: u64, answer: HttpAnswer) {
        if attempt != self.attempt || self.closed {
            return;
        }
        if let Ok(Value::Object(descriptor)) = serde_json::from_slice::<Value>(&answer.body) {
            let protocol = descriptor
                .get("orchestrationProtocolVersion")
                .and_then(Value::as_f64);
            self.descriptor = Arc::new(descriptor);
            if let Some(protocol) = protocol.filter(|p| *p != PROTOCOL as f64) {
                // Retrying cannot help: one side has to be updated.
                self.blocked_protocol = Some(protocol as i64);
                self.failure_trace_id = self.trace_id.clone();
                self.phase = Phase::Blocked;
                return;
            }
        }
        // Nobody there: the socket would only fail the same way.
        match answer.error {
            Some(NetError::Unreachable(message)) => {
                self.failure = message;
                self.failure_trace_id = self.trace_id.clone();
                self.schedule_retry();
            }
            Some(NetError::Timeout) => {
                self.failure = "timeout".to_owned();
                self.failure_trace_id = self.trace_id.clone();
                self.schedule_retry();
            }
            // An MC that does not describe itself is left to the socket to refuse.
            _ if self.ticketed => self.open_with_ticket(),
            _ => self.open_socket(None),
        }
    }

    // Asks the MC for a socket ticket and opens with it; a credential it does
    // not know is refused, and anything else is retried.
    fn open_with_ticket(&mut self) {
        let Some(origin) = &self.origin else { return };
        self.effects.push(Effect::PostTicket {
            attempt: self.attempt,
            url: at_path(origin, "/api/auth/websocket-ticket"),
            token: self.token.clone(),
        });
    }

    fn on_ticket(&mut self, attempt: u64, answer: HttpAnswer) {
        if attempt != self.attempt || self.closed {
            return;
        }
        let issued = serde_json::from_slice::<Value>(&answer.body)
            .ok()
            .and_then(|body| body.get("ticket")?.as_str().map(str::to_owned))
            .unwrap_or_default();
        match answer.status {
            // The MC no longer knows this credential: no retry mends that.
            Some(401) => self.phase = Phase::Refused,
            Some(200) if !issued.is_empty() => {
                self.ticketed = true;
                self.open_socket(Some(&issued));
            }
            _ => self.schedule_retry(),
        }
    }

    fn open_socket(&mut self, ticket: Option<&str>) {
        let Some(mut url) = self.ws_url.clone() else {
            return;
        };
        if let Some(ticket) = ticket {
            url.query_pairs_mut()
                .clear()
                .append_pair("wsTicket", ticket);
        }
        self.socket = Some(self.attempt);
        self.effects.push(Effect::OpenSocket {
            attempt: self.attempt,
            url,
            traceparent: format!("00-{}-{}-01", self.trace_id, &self.trace_id[..16]),
        });
    }

    fn on_message(&mut self, text: &str) {
        let Ok(Value::Object(frame)) = serde_json::from_str::<Value>(text) else {
            return;
        };
        let kind = frame.get("t").and_then(Value::as_str).unwrap_or_default();
        // Whatever it says, the MC is answering.
        if self.pong_by.take().is_some() {
            self.emit(McEvent::Checked(true));
        }
        match kind {
            "hello" => {
                self.ready = true;
                self.hellos += 1;
                self.retries = 0;
                self.failure.clear();
                self.failure_trace_id.clear();
                self.mc = string(&frame, "mc");
                self.environment = string(&frame, "environment");
                self.ping_at = Some(self.now + self.ping_interval);
                // The status this ends with carries the new connection: the
                // owner sends its subscriptions on it.
                self.phase = Phase::Ready;
                return;
            }
            "pong" => return,
            _ => {}
        }
        let Some(id) = frame.get("id").and_then(Value::as_u64) else {
            return;
        };
        match kind {
            "rpc.result" | "rpc.error" => {
                // A reply to a call that is no longer in flight is nobody's.
                if !self.calls.remove(&id) {
                    return;
                }
                let result = if kind == "rpc.result" {
                    Ok(frame.get("result").cloned().unwrap_or(Value::Null))
                } else {
                    Err(CallError {
                        message: match frame.get("error") {
                            Some(Value::String(error)) => error.clone(),
                            Some(Value::Null) | None => String::new(),
                            Some(other) => other.to_string(),
                        },
                        detail: frame.get("detail").cloned().unwrap_or(Value::Null),
                    })
                };
                self.emit(McEvent::Reply { id, result });
            }
            _ => self.emit(McEvent::Frame { id, frame }),
        }
    }

    fn on_closed(&mut self, attempt: u64, end: SocketEnd) {
        if self.socket != Some(attempt) {
            return;
        }
        self.socket = None;
        // The MC's own close code and words, before the socket goes.
        let revoked = end.code == Some(4401);
        let mut reason = std::mem::take(&mut self.drop_reason);
        if reason.is_empty() && end.timed_out {
            reason = "timeout".to_owned();
        }
        if reason.is_empty() {
            reason = end.reason;
        }
        if reason.is_empty() {
            reason = end.error.unwrap_or_default();
        }
        if reason.is_empty() {
            reason = "closed".to_owned();
        }
        let was_ready = self.ready;
        self.ready = false;
        self.ping_at = None;
        self.pong_by = None;
        self.fail_calls();
        if self.closed {
            return;
        }
        self.failure = reason;
        self.failure_trace_id = self.trace_id.clone();
        if revoked {
            self.phase = Phase::Refused;
            return;
        }
        // A socket that never got its hello may have been turned away for its
        // credential. With the bare token that is either a paired session's
        // token, which needs a ticket, or one the MC refuses: asking for a
        // ticket tells which. A ticketed socket that failed is retried like
        // any other.
        if was_ready || self.ticketed {
            self.schedule_retry();
        } else {
            self.open_with_ticket();
        }
    }

    fn schedule_retry(&mut self) {
        if !self.online {
            self.phase = Phase::Offline;
            return;
        }
        self.retry_delay = match self.retry_delays.as_slice() {
            [] => Duration::from_secs(8),
            delays => delays[(self.retries as usize).min(delays.len() - 1)],
        };
        self.retries += 1;
        self.retry_at = Some(self.now + self.retry_delay);
        self.phase = Phase::Retrying;
    }

    fn send(&mut self, message: &Value) {
        if let Some(attempt) = self.socket {
            self.effects.push(Effect::Send {
                attempt,
                text: message.to_string(),
            });
        }
    }
}

/// `origin` with `path` and nothing after it.
pub(crate) fn at_path(origin: &Url, path: &str) -> Url {
    let mut url = origin.clone();
    url.set_path(path);
    url.set_query(None);
    url.set_fragment(None);
    url
}

fn string(frame: &Frame, key: &str) -> String {
    frame
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

// The descriptor is compared by identity: it is replaced whenever it is read.
fn same_status(a: &Status, b: &Status) -> bool {
    a.phase == b.phase
        && a.connection == b.connection
        && a.failure == b.failure
        && a.failure_trace_id == b.failure_trace_id
        && a.retry_delay == b.retry_delay
        && a.retries == b.retries
        && a.blocked_protocol == b.blocked_protocol
        && Arc::ptr_eq(&a.descriptor, &b.descriptor)
        && a.mc == b.mc
        && a.environment == b.environment
}
