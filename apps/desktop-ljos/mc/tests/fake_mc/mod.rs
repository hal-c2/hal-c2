//! An MC in the test's process: the descriptor, the socket ticket, and `/ws`
//! with the access token or a ticket, saying hello as it opens. It tells the
//! test what it saw through the same channel the connection's events come
//! down, so a test waits on one queue in the order things happened.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

use futures_util::{SinkExt, StreamExt};
use hal_c2_mc::McEvent;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

pub const TOKEN: &str = "secret";
/// The pairing token `/oauth/token` spends once, for [`TOKEN`].
pub const PAIRING_TOKEN: &str = "pair-once";

/// One thing that happened, on the connection's side or the MC's.
#[derive(Debug)]
pub enum Event {
    Client(McEvent),
    Mc(Seen),
}

/// What the MC saw.
#[derive(Debug, Clone, PartialEq)]
pub enum Seen {
    Descriptor,
    Ticket {
        authorization: String,
    },
    /// A socket opened; `query` is how it authorized.
    Socket {
        socket: u64,
        query: String,
    },
    /// A socket refused at its handshake.
    Rejected {
        query: String,
    },
    Text {
        socket: u64,
        frame: Value,
    },
    Closed {
        socket: u64,
    },
    /// A pairing exchange, its form as sent.
    Exchange {
        form: String,
    },
}

enum Control {
    Send(Value),
    Close(u16, String),
    Drop,
}

#[derive(Clone)]
pub struct FakeMc {
    pub origin: url::Url,
    shared: Arc<Shared>,
}

struct Shared {
    events: Mutex<Sender<Event>>,
    protocol: AtomicI64,
    /// Whether `?token=` opens a socket: a paired session's token does not,
    /// and needs a ticket.
    token_on_socket: AtomicBool,
    refuse_tickets: AtomicBool,
    tickets: Mutex<Vec<String>>,
    paired: AtomicBool,
    sockets: Mutex<HashMap<u64, UnboundedSender<Control>>>,
    next_socket: AtomicU64,
}

impl FakeMc {
    /// Starts it on its own thread; what it sees goes to `events`.
    pub fn start(events: Sender<Event>) -> Self {
        let std_listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        std_listener.set_nonblocking(true).unwrap();
        let port = std_listener.local_addr().unwrap().port();
        let shared = Arc::new(Shared {
            events: Mutex::new(events),
            protocol: AtomicI64::new(3),
            token_on_socket: AtomicBool::new(true),
            refuse_tickets: AtomicBool::new(false),
            tickets: Mutex::default(),
            paired: AtomicBool::new(false),
            sockets: Mutex::default(),
            next_socket: AtomicU64::new(1),
        });
        let serving = shared.clone();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async move {
                let listener = TcpListener::from_std(std_listener).unwrap();
                loop {
                    let Ok((stream, _)) = listener.accept().await else {
                        return;
                    };
                    tokio::spawn(serve(stream, serving.clone()));
                }
            });
        });
        Self {
            origin: url::Url::parse(&format!("http://127.0.0.1:{port}")).unwrap(),
            shared,
        }
    }

    /// The protocol its descriptor names.
    pub fn set_protocol(&self, protocol: i64) {
        self.shared.protocol.store(protocol, Ordering::SeqCst);
    }

    pub fn set_token_on_socket(&self, accepted: bool) {
        self.shared
            .token_on_socket
            .store(accepted, Ordering::SeqCst);
    }

    pub fn set_refuse_tickets(&self, refuse: bool) {
        self.shared.refuse_tickets.store(refuse, Ordering::SeqCst);
    }

    pub fn send(&self, socket: u64, frame: Value) {
        self.control(socket, Control::Send(frame));
    }

    /// Closes `socket` with a close frame, as the MC does for a revoked session.
    pub fn close(&self, socket: u64, code: u16, reason: &str) {
        self.control(socket, Control::Close(code, reason.to_owned()));
    }

    /// Drops `socket`'s connection without a word, as a lost network does.
    pub fn drop_socket(&self, socket: u64) {
        self.control(socket, Control::Drop);
    }

    fn control(&self, socket: u64, control: Control) {
        let sockets = self.shared.sockets.lock().unwrap();
        sockets[&socket].send(control).unwrap();
    }
}

impl Shared {
    fn saw(&self, seen: Seen) {
        let _ = self.events.lock().unwrap().send(Event::Mc(seen));
    }
}

async fn serve(mut stream: TcpStream, shared: Arc<Shared>) {
    let Some(head) = peek_head(&stream).await else {
        return;
    };
    let path = head
        .split_whitespace()
        .nth(1)
        .unwrap_or_default()
        .to_owned();
    if path.starts_with("/ws") {
        socket(stream, shared).await;
    } else {
        let request = read_request(&mut stream).await;
        let (status, body) = answer(&path, &request, &shared);
        let response = format!(
            "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.write_all(response.as_bytes()).await;
        let _ = stream.shutdown().await;
    }
}

/// The request's first line, left in the stream for whoever handles it.
async fn peek_head(stream: &TcpStream) -> Option<String> {
    let mut buffer = [0u8; 1024];
    loop {
        let n = stream.peek(&mut buffer).await.ok()?;
        if n == 0 {
            return None;
        }
        let text = String::from_utf8_lossy(&buffer[..n]);
        if let Some(line) = text.split("\r\n").next().filter(|_| text.contains("\r\n")) {
            return Some(line.to_owned());
        }
        stream.readable().await.ok()?;
    }
}

/// The whole request: head and body, as one string.
async fn read_request(stream: &mut TcpStream) -> String {
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 4096];
    loop {
        let n = stream.read(&mut buffer).await.unwrap_or(0);
        if n == 0 {
            break;
        }
        bytes.extend_from_slice(&buffer[..n]);
        let text = String::from_utf8_lossy(&bytes);
        if let Some(end) = text.find("\r\n\r\n") {
            let length = text[..end]
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse().ok())?
                })
                .unwrap_or(0usize);
            if bytes.len() >= end + 4 + length {
                break;
            }
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

fn header(request: &str, name: &str) -> String {
    request
        .lines()
        .find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.eq_ignore_ascii_case(name)
                .then(|| value.trim().to_owned())
        })
        .unwrap_or_default()
}

fn answer(path: &str, request: &str, shared: &Shared) -> (u16, String) {
    match path {
        "/.well-known/hal-c2/environment" => {
            shared.saw(Seen::Descriptor);
            let protocol = shared.protocol.load(Ordering::SeqCst);
            (
                200,
                json!({"environmentId": "env-1", "label": "Fake", "orchestrationProtocolVersion": protocol})
                    .to_string(),
            )
        }
        "/api/auth/websocket-ticket" => {
            let authorization = header(request, "authorization");
            shared.saw(Seen::Ticket {
                authorization: authorization.clone(),
            });
            if shared.refuse_tickets.load(Ordering::SeqCst)
                || authorization != format!("Bearer {TOKEN}")
            {
                return (401, json!({"error": "unauthorized"}).to_string());
            }
            let mut tickets = shared.tickets.lock().unwrap();
            let ticket = format!("tk-{}", tickets.len() + 1);
            tickets.push(ticket.clone());
            (
                200,
                json!({"ticket": ticket, "expiresAt": "2026-10-16T00:00:00Z"}).to_string(),
            )
        }
        "/oauth/token" => {
            let form = request
                .split_once("\r\n\r\n")
                .map(|(_, body)| body.to_owned())
                .unwrap_or_default();
            shared.saw(Seen::Exchange { form: form.clone() });
            let offered = form
                .split('&')
                .any(|pair| pair == format!("subject_token={PAIRING_TOKEN}"));
            if offered && !shared.paired.swap(true, Ordering::SeqCst) {
                (
                    200,
                    json!({"access_token": TOKEN, "token_type": "Bearer", "expires_in": 3600})
                        .to_string(),
                )
            } else {
                (400, json!({"error": "invalid_grant"}).to_string())
            }
        }
        _ => (404, "{}".to_owned()),
    }
}

// tungstenite's handshake callback returns its refusal unboxed.
#[allow(clippy::result_large_err)]
async fn socket(stream: TcpStream, shared: Arc<Shared>) {
    let mut query = String::new();
    let accepting = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        query = request.uri().query().unwrap_or_default().to_owned();
        let ticketed = query
            .strip_prefix("wsTicket=")
            .is_some_and(|ticket| shared.tickets.lock().unwrap().iter().any(|t| t == ticket));
        let tokened =
            query == format!("token={TOKEN}") && shared.token_on_socket.load(Ordering::SeqCst);
        if ticketed || tokened {
            Ok(response)
        } else {
            let mut refusal = ErrorResponse::new(Some("unauthorized".to_owned()));
            *refusal.status_mut() = tokio_tungstenite::tungstenite::http::StatusCode::UNAUTHORIZED;
            Err(refusal)
        }
    };
    let accepted = tokio_tungstenite::accept_hdr_async(stream, accepting).await;
    let Ok(mut ws) = accepted else {
        shared.saw(Seen::Rejected { query });
        return;
    };
    let id = shared.next_socket.fetch_add(1, Ordering::SeqCst);
    let (control, mut controls) = unbounded_channel();
    shared.sockets.lock().unwrap().insert(id, control);
    shared.saw(Seen::Socket { socket: id, query });
    // The MC says hello as the socket opens, unasked.
    let hello = json!({"t": "hello", "protocol": 3, "mc": "mc@fake", "environment": "env-1"});
    let _ = ws.send(Message::text(hello.to_string())).await;
    loop {
        tokio::select! {
            message = ws.next() => match message {
                Some(Ok(Message::Text(text))) => {
                    let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                    shared.saw(Seen::Text { socket: id, frame });
                }
                Some(Ok(_)) => {}
                Some(Err(_)) | None => break,
            },
            control = controls.recv() => match control {
                Some(Control::Send(frame)) => {
                    let _ = ws.send(Message::text(frame.to_string())).await;
                }
                Some(Control::Close(code, reason)) => {
                    let frame = CloseFrame { code: CloseCode::from(code), reason: reason.into() };
                    let _ = ws.close(Some(frame)).await;
                }
                Some(Control::Drop) | None => break,
            },
        }
    }
    shared.sockets.lock().unwrap().remove(&id);
    shared.saw(Seen::Closed { socket: id });
}
