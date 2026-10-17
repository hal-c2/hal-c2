//! The I/O thread: runs [`Core`]'s effects on a single-threaded runtime and
//! feeds what comes back in as inputs, one at a time.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tokio::task::JoinHandle;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::{self, Message};
use tokio_tungstenite::{Connector, connect_async_tls_with_config};
use url::Url;

use crate::core::{Command, Core, Effect, HttpCall, Input, SocketEnd};
use crate::http::{Http, tls};
use crate::{Frame, McEvent};

/// How long a socket's handshake may take, as QWebSocket's default.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

/// Starts a connection on its own thread. It stays closed until
/// [`McHandle::open`]; everything it has to say goes to `sink`, in order, from
/// that thread. The thread ends once every handle is dropped.
///
/// The sink runs between the socket's reads, so it must be cheap and never
/// block: queue the event and wake the owner, who hands each to
/// [`McClient::deliver`](crate::McClient::deliver) in the same order, whenever
/// it gets to them. Nothing here waits on the owner: a late status only means
/// its subscriptions are sent late, and the connection drops any meant for a
/// socket already gone.
pub fn spawn(sink: impl FnMut(McEvent) + Send + 'static) -> McHandle {
    let (commands, receiver) = unbounded_channel();
    std::thread::Builder::new()
        .name("hal-c2-mc".to_owned())
        .spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("the MC connection's runtime starts");
            runtime.block_on(run(receiver, Box::new(sink)));
        })
        .expect("the MC connection's thread starts");
    McHandle::new(commands)
}

/// Commands to a connection. Cheap to clone and `Send`; every method returns
/// at once, and anything that has an answer gets it as an [`McEvent`] with the
/// id it was given.
#[derive(Clone)]
pub struct McHandle {
    commands: UnboundedSender<Command>,
    ids: Arc<AtomicU64>,
}

impl McHandle {
    pub(crate) fn new(commands: UnboundedSender<Command>) -> Self {
        Self {
            commands,
            ids: Arc::new(AtomicU64::new(1)),
        }
    }

    fn send(&self, command: Command) {
        // A connection whose thread is gone has nobody left to answer.
        let _ = self.commands.send(command);
    }

    /// An id for a subscription or a call, unique across both on this connection.
    pub fn next_id(&self) -> u64 {
        self.ids.fetch_add(1, Ordering::Relaxed)
    }

    /// `origin` is the MC's http(s) origin; the token is its access token.
    /// Opening an open connection starts it over.
    pub fn open(&self, origin: Url, token: impl Into<String>) {
        self.send(Command::Open {
            origin,
            token: token.into(),
        });
    }

    pub fn close(&self) {
        self.send(Command::Close);
    }

    /// Drops the socket and connects again.
    pub fn reconnect(&self) {
        self.send(Command::Reconnect);
    }

    /// Whether this device has a network. Offline, a drop is not retried until
    /// the network is back.
    pub fn set_online(&self, online: bool) {
        self.send(Command::SetOnline(online));
    }

    /// The app came to the foreground: a waiting retry runs now, and a ready
    /// connection is checked ([`McEvent::Checked`]) and replaced if it does not answer.
    pub fn wake(&self) {
        self.send(Command::Wake);
    }

    /// Tries again now, whatever it was waiting for.
    pub fn retry_now(&self) {
        self.send(Command::RetryNow);
    }

    /// Sends a whole `sub` frame, if `connection` is still the ready one.
    pub fn send_sub(&self, connection: u64, frame: Frame) {
        self.send(Command::Sub { connection, frame });
    }

    pub fn send_unsub(&self, connection: u64, id: u64) {
        self.send(Command::Unsub { connection, id });
    }

    /// Asks windowed stream `id` for the runs before its window that hold
    /// `items` turn items; a `page` frame answers.
    pub fn send_more(&self, connection: u64, id: u64, items: u32) {
        self.send(Command::More {
            connection,
            id,
            items,
        });
    }

    /// A client RPC, answered by an [`McEvent::Reply`] for `id`: "not
    /// connected" when the connection is not ready, "disconnected" when it
    /// drops before the MC answers.
    pub fn call(
        &self,
        id: u64,
        environment: impl Into<String>,
        method: impl Into<String>,
        payload: Value,
    ) {
        self.send(Command::Call {
            id,
            environment: environment.into(),
            method: method.into(),
            payload,
        });
    }

    /// POSTs `body` to `path` of the MC's origin (its HTTP API, for answers too
    /// large for the socket, as `/api/pull-requests/diff`), with the access
    /// token. Answered by a [`McEvent::Reply`] for `id`.
    pub fn post(&self, id: u64, path: impl Into<String>, body: Value) {
        self.send(Command::Http {
            id,
            request: HttpCall::Post {
                path: path.into(),
                body,
            },
        });
    }

    /// GETs `path` of the MC's origin (its HTTP API, as `/api/auth/session`),
    /// with the access token. Answered by a [`McEvent::Reply`] for `id`.
    pub fn get(&self, id: u64, path: impl Into<String>) {
        self.send(Command::Http {
            id,
            request: HttpCall::Get { path: path.into() },
        });
    }

    /// POSTs `bytes` to a signed URL the MC handed out (`relativeUrl`, as
    /// `attachments.createUploadUrl`'s): the URL is its own authorization.
    /// Answered by a [`McEvent::Reply`] for `id`.
    pub fn upload(
        &self,
        id: u64,
        relative_url: impl Into<String>,
        bytes: Vec<u8>,
        mime_type: impl Into<String>,
    ) {
        self.send(Command::Http {
            id,
            request: HttpCall::Upload {
                relative_url: relative_url.into(),
                bytes,
                mime_type: mime_type.into(),
            },
        });
    }

    /// GETs a signed URL the MC handed out (`assets.createUrl`'s
    /// `relativeUrl`). Answered by a [`McEvent::Bytes`] for `id`.
    pub fn download(&self, id: u64, relative_url: impl Into<String>) {
        self.send(Command::Http {
            id,
            request: HttpCall::Download {
                relative_url: relative_url.into(),
            },
        });
    }

    pub fn set_retry_delays(&self, delays: Vec<Duration>) {
        self.send(Command::SetRetryDelays(delays));
    }

    pub fn set_ping_interval(&self, interval: Duration) {
        self.send(Command::SetPingInterval(interval));
    }

    /// How long a ping may go unanswered before the connection counts as dead.
    pub fn set_pong_timeout(&self, timeout: Duration) {
        self.send(Command::SetPongTimeout(timeout));
    }
}

/// The socket of one attempt: what to write to it, and the task to abort.
struct Socket {
    attempt: u64,
    out: UnboundedSender<String>,
    task: JoinHandle<()>,
}

async fn run(mut commands: UnboundedReceiver<Command>, mut sink: Box<dyn FnMut(McEvent) + Send>) {
    let (inputs, mut answers) = unbounded_channel::<Input>();
    let http = Http::new();
    let tls = tls();
    let mut core = Core::new(Instant::now().into_std());
    let mut socket: Option<Socket> = None;
    loop {
        let deadline = core.next_deadline().map(Instant::from_std);
        let input = tokio::select! {
            command = commands.recv() => match command {
                Some(command) => Input::Command(command),
                // Every handle is gone: so is the owner.
                None => break,
            },
            Some(answer) = answers.recv() => answer,
            () = sleep_until(deadline) => Input::Tick,
        };
        for effect in core.handle(input, Instant::now().into_std()) {
            match effect {
                Effect::Emit(event) => sink(event),
                Effect::GetDescriptor {
                    attempt,
                    url,
                    token,
                } => {
                    let (http, inputs) = (http.clone(), inputs.clone());
                    tokio::task::spawn_blocking(move || {
                        let answer = http.descriptor(&url, &token);
                        let _ = inputs.send(Input::Descriptor { attempt, answer });
                    });
                }
                Effect::PostTicket {
                    attempt,
                    url,
                    token,
                } => {
                    let (http, inputs) = (http.clone(), inputs.clone());
                    tokio::task::spawn_blocking(move || {
                        let answer = http.ticket(&url, &token);
                        let _ = inputs.send(Input::Ticket { attempt, answer });
                    });
                }
                Effect::Http {
                    id,
                    origin,
                    token,
                    request,
                } => {
                    let (http, inputs) = (http.clone(), inputs.clone());
                    tokio::task::spawn_blocking(move || {
                        let event = http.run(id, &origin, &token, request);
                        let _ = inputs.send(Input::Deliver(event));
                    });
                }
                Effect::OpenSocket {
                    attempt,
                    url,
                    traceparent,
                } => {
                    if let Some(old) = socket.take() {
                        old.task.abort();
                    }
                    let (out, outgoing) = unbounded_channel();
                    let task = tokio::spawn(run_socket(
                        attempt,
                        url,
                        traceparent,
                        tls.clone(),
                        outgoing,
                        inputs.clone(),
                    ));
                    socket = Some(Socket { attempt, out, task });
                }
                Effect::Send { attempt, text } => {
                    if let Some(socket) = socket.as_ref().filter(|s| s.attempt == attempt) {
                        let _ = socket.out.send(text);
                    }
                }
                Effect::CloseSocket { attempt } => {
                    if socket.as_ref().is_some_and(|s| s.attempt == attempt)
                        && let Some(old) = socket.take()
                    {
                        old.task.abort();
                    }
                }
            }
        }
    }
    if let Some(old) = socket.take() {
        old.task.abort();
    }
}

async fn sleep_until(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending().await,
    }
}

/// One socket: its handshake, then what it reads and writes until it ends,
/// which it reports once.
async fn run_socket(
    attempt: u64,
    url: Url,
    traceparent: String,
    tls: Arc<rustls::ClientConfig>,
    mut outgoing: UnboundedReceiver<String>,
    inputs: UnboundedSender<Input>,
) {
    let end = socket(attempt, url, traceparent, tls, &mut outgoing, &inputs).await;
    let _ = inputs.send(Input::SocketClosed { attempt, end });
}

async fn socket(
    attempt: u64,
    url: Url,
    traceparent: String,
    tls: Arc<rustls::ClientConfig>,
    outgoing: &mut UnboundedReceiver<String>,
    inputs: &UnboundedSender<Input>,
) -> SocketEnd {
    let failed = |error: String| SocketEnd {
        error: Some(error),
        ..SocketEnd::default()
    };
    let mut request = match url.as_str().into_client_request() {
        Ok(request) => request,
        Err(error) => return failed(error.to_string()),
    };
    if let Ok(value) = traceparent.parse() {
        request.headers_mut().insert("traceparent", value);
    }
    // No limits on what the MC sends: a snapshot is as large as its thread.
    let config = WebSocketConfig::default()
        .max_message_size(None)
        .max_frame_size(None);
    let connecting =
        connect_async_tls_with_config(request, Some(config), true, Some(Connector::Rustls(tls)));
    let stream = match tokio::time::timeout(HANDSHAKE_TIMEOUT, connecting).await {
        Err(_) => {
            return SocketEnd {
                timed_out: true,
                ..SocketEnd::default()
            };
        }
        Ok(Err(error)) => return failed(error.to_string()),
        Ok(Ok((stream, _response))) => stream,
    };
    let (mut write, mut read) = stream.split();
    let mut end = SocketEnd::default();
    loop {
        tokio::select! {
            message = read.next() => match message {
                Some(Ok(Message::Text(text))) => {
                    let _ = inputs.send(Input::SocketText { attempt, text: text.as_str().to_owned() });
                }
                // The MC's close code and words; the stream ends after it.
                Some(Ok(Message::Close(frame))) => {
                    if let Some(frame) = frame {
                        end.code = Some(frame.code.into());
                        end.reason = frame.reason.as_str().to_owned();
                    }
                }
                Some(Ok(_)) => {}
                Some(Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed)) | None => break,
                Some(Err(error)) => {
                    end.error = Some(error.to_string());
                    break;
                }
            },
            text = outgoing.recv() => match text {
                Some(text) => {
                    if let Err(error) = write.send(Message::text(text)).await {
                        end.error = Some(error.to_string());
                        break;
                    }
                }
                None => break,
            },
        }
    }
    end
}
