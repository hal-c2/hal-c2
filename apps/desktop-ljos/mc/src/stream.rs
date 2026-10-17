//! Long-lived streams to the MC's origin that the protocol socket does not
//! carry: a device's screen and input through `/api/device-hub` (ported from
//! the QNetworkAccessManager GET and QWebSocket that apps/desktop-qt's
//! `DeviceStream` opens itself).
//!
//! [`open`] starts one stream on its own thread, for an [`AuthorizedRequest`]
//! from [`McClient::request`](crate::McClient::request): a GET whose body is
//! read as it arrives, or a websocket. What it reads goes to the sink as
//! [`StreamEvent`]s, in order, ending with one [`StreamEvent::Ended`]. Dropping
//! the [`Stream`] aborts it at once; nothing reaches the sink after that
//! except, at most, the event it was already handing over.

use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::{self, Message};
use tokio_tungstenite::{Connector, connect_async_tls_with_config};

use crate::AuthorizedRequest;
use crate::http::tls;

/// How long connecting (and a websocket's handshake) may take, as
/// QWebSocket's default.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// The most a response's status line and headers may take.
const MAX_HEAD: usize = 64 * 1024;

/// What a stream says, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StreamEvent {
    /// The response's status arrived (101 for a websocket).
    Opened { status: u16 },
    /// More of a GET's body, as it arrived (decoded when chunked).
    Data(Vec<u8>),
    /// A websocket's text message.
    Text(String),
    /// A websocket's binary message.
    Binary(Vec<u8>),
    /// The stream is over; nothing follows.
    Ended(StreamEnd),
}

/// How a stream ended.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StreamEnd {
    /// The HTTP status, when one arrived: a websocket the MC refused at its
    /// handshake (401) ends with that status and never opens.
    pub status: Option<u16>,
    /// A websocket's close code, when its peer sent one.
    pub code: Option<u16>,
    /// A websocket's close reason; empty when none.
    pub reason: String,
    /// Why it failed (QNetworkReply's or QWebSocket's errorString); None when
    /// it ended cleanly.
    pub error: Option<String>,
}

impl StreamEnd {
    fn failed(error: impl Into<String>) -> Self {
        Self {
            error: Some(error.into()),
            ..Self::default()
        }
    }
}

/// An open stream. Dropping it aborts the stream.
pub struct Stream {
    outgoing: UnboundedSender<Message>,
}

impl Stream {
    /// Sends a text message on a websocket; nothing on a GET or once closed.
    pub fn send_text(&self, text: impl Into<String>) {
        let _ = self.outgoing.send(Message::text(text.into()));
    }

    /// Sends a binary message on a websocket; nothing on a GET or once closed.
    pub fn send_binary(&self, bytes: Vec<u8>) {
        let _ = self.outgoing.send(Message::binary(bytes));
    }
}

/// Opens `request` on a thread of its own: a websocket when `socket`, else a
/// GET. The sink runs on that thread, so it must be cheap and never block:
/// queue the event and wake the owner.
pub fn open(
    request: AuthorizedRequest,
    socket: bool,
    mut sink: impl FnMut(StreamEvent) + Send + 'static,
) -> Stream {
    let (outgoing, receiver) = unbounded_channel();
    // Without a thread the stream never opens; its owner's timeouts see to that.
    let _ = std::thread::Builder::new()
        .name("hal-c2-mc-stream".to_owned())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(error) => {
                    return sink(StreamEvent::Ended(StreamEnd::failed(error.to_string())));
                }
            };
            runtime.block_on(async move {
                let mut receiver = receiver;
                let end = if socket {
                    websocket(&request, &mut receiver, &mut sink).await
                } else {
                    get(&request, &mut receiver, &mut sink).await
                };
                // Dropped: the owner is gone and wants nothing more.
                if let Some(end) = end {
                    sink(StreamEvent::Ended(end));
                }
            });
        });
    Stream { outgoing }
}

trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}

/// A GET, its body handed over as it arrives. None when the stream was dropped.
async fn get(
    request: &AuthorizedRequest,
    outgoing: &mut UnboundedReceiver<Message>,
    sink: &mut (impl FnMut(StreamEvent) + Send),
) -> Option<StreamEnd> {
    let reading = async {
        let mut io = match connect(request).await {
            Ok(io) => io,
            Err(error) => return StreamEnd::failed(error),
        };
        read_response(request, &mut io, sink).await
    };
    tokio::pin!(reading);
    loop {
        tokio::select! {
            end = &mut reading => return Some(end),
            message = outgoing.recv() => { message?; }
        }
    }
}

async fn connect(request: &AuthorizedRequest) -> Result<Box<dyn Io>, String> {
    let url = &request.url;
    let host = url.host_str().ok_or("the URL has no host")?.to_owned();
    let port = url.port_or_known_default().ok_or("the URL has no port")?;
    let connecting = async {
        let tcp = TcpStream::connect((host.trim_matches(['[', ']']), port))
            .await
            .map_err(|error| error.to_string())?;
        let _ = tcp.set_nodelay(true);
        if url.scheme() != "https" {
            return Ok::<Box<dyn Io>, String>(Box::new(tcp));
        }
        let name =
            rustls::pki_types::ServerName::try_from(host.trim_matches(['[', ']']).to_owned())
                .map_err(|error| error.to_string())?;
        let tls = tokio_rustls::TlsConnector::from(tls())
            .connect(name, tcp)
            .await
            .map_err(|error| error.to_string())?;
        Ok(Box::new(tls))
    };
    match tokio::time::timeout(CONNECT_TIMEOUT, connecting).await {
        Ok(result) => result,
        Err(_) => Err("Connection timed out".to_owned()),
    }
}

/// Writes the GET and reads its response until the body ends.
async fn read_response(
    request: &AuthorizedRequest,
    io: &mut Box<dyn Io>,
    sink: &mut (impl FnMut(StreamEvent) + Send),
) -> StreamEnd {
    let url = &request.url;
    let target = match url.query() {
        Some(query) => format!("{}?{query}", url.path()),
        None => url.path().to_owned(),
    };
    let host = match (url.host_str(), url.port()) {
        (Some(host), Some(port)) => format!("{host}:{port}"),
        (Some(host), None) => host.to_owned(),
        _ => String::new(),
    };
    let head = format!(
        "GET {target} HTTP/1.1\r\nHost: {host}\r\nAuthorization: {}\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n",
        request.authorization
    );
    if let Err(error) = io.write_all(head.as_bytes()).await {
        return StreamEnd::failed(error.to_string());
    }
    let mut buffer = Vec::new();
    let mut chunk = vec![0u8; 64 * 1024];
    let (status, body) = loop {
        if let Some(end) = find(&buffer, b"\r\n\r\n") {
            match parse_head(&buffer[..end]) {
                Ok(parsed) => {
                    buffer.drain(..end + 4);
                    break parsed;
                }
                Err(error) => return StreamEnd::failed(error),
            }
        }
        if buffer.len() > MAX_HEAD {
            return StreamEnd::failed("the response's headers are too long");
        }
        match io.read(&mut chunk).await {
            Ok(0) => return StreamEnd::failed("Connection closed"),
            Ok(n) => buffer.extend_from_slice(&chunk[..n]),
            Err(error) => return StreamEnd::failed(error.to_string()),
        }
    };
    sink(StreamEvent::Opened { status });
    let mut end = StreamEnd {
        status: Some(status),
        ..StreamEnd::default()
    };
    let mut body = body;
    let mut pending = buffer;
    loop {
        if !pending.is_empty() {
            match body.feed(&pending) {
                Ok(data) if !data.is_empty() => sink(StreamEvent::Data(data)),
                Ok(_) => {}
                Err(error) => {
                    end.error = Some(error);
                    return end;
                }
            }
            pending.clear();
        }
        if body.done() {
            return end;
        }
        match io.read(&mut chunk).await {
            Ok(0) => {
                if !body.complete_at_eof() {
                    end.error = Some("Connection closed".to_owned());
                }
                return end;
            }
            Ok(n) => pending.extend_from_slice(&chunk[..n]),
            Err(error) => {
                end.error = Some(error.to_string());
                return end;
            }
        }
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// The status and how the body is framed, from a response's head.
fn parse_head(head: &[u8]) -> Result<(u16, Body), String> {
    let head = std::str::from_utf8(head).map_err(|_| "the response's headers are not text")?;
    let mut lines = head.split("\r\n");
    let status = lines
        .next()
        .and_then(|line| line.split(' ').nth(1))
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or("the response has no status")?;
    let mut length = None;
    let mut chunked = false;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        if name.eq_ignore_ascii_case("transfer-encoding") {
            chunked = value.to_ascii_lowercase().contains("chunked");
        } else if name.eq_ignore_ascii_case("content-length") {
            length = value.parse::<usize>().ok();
        }
    }
    let body = if chunked {
        Body::Chunked(Chunked::default())
    } else if let Some(length) = length {
        Body::Length(length)
    } else {
        Body::Close
    };
    Ok((status, body))
}

/// How a response's body ends.
#[derive(Debug)]
enum Body {
    /// So many bytes are left.
    Length(usize),
    /// Chunked.
    Chunked(Chunked),
    /// When the connection closes.
    Close,
}

impl Body {
    fn feed(&mut self, bytes: &[u8]) -> Result<Vec<u8>, String> {
        match self {
            Body::Length(left) => {
                let take = bytes.len().min(*left);
                *left -= take;
                Ok(bytes[..take].to_vec())
            }
            Body::Chunked(chunked) => chunked.feed(bytes),
            Body::Close => Ok(bytes.to_vec()),
        }
    }

    fn done(&self) -> bool {
        match self {
            Body::Length(left) => *left == 0,
            Body::Chunked(chunked) => chunked.state == Chunk::Done,
            Body::Close => false,
        }
    }

    fn complete_at_eof(&self) -> bool {
        matches!(self, Body::Close) || self.done()
    }
}

/// A chunked body's decoder, fed bytes as they arrive.
#[derive(Debug, Default)]
struct Chunked {
    buffer: Vec<u8>,
    state: Chunk,
}

#[derive(Debug, Default, PartialEq, Eq)]
enum Chunk {
    /// Reading a size line.
    #[default]
    Size,
    /// So many bytes of the chunk are left.
    Data(usize),
    /// The CRLF after a chunk.
    End,
    /// The last chunk arrived; trailers are ignored.
    Done,
}

impl Chunked {
    fn feed(&mut self, bytes: &[u8]) -> Result<Vec<u8>, String> {
        self.buffer.extend_from_slice(bytes);
        let mut out = Vec::new();
        let mut at = 0;
        loop {
            match self.state {
                Chunk::Size => {
                    let Some(line) = find(&self.buffer[at..], b"\r\n") else {
                        break;
                    };
                    let text = std::str::from_utf8(&self.buffer[at..at + line])
                        .map_err(|_| "a chunk's size is not text")?;
                    let hex = text.split(';').next().unwrap_or_default().trim();
                    let size = usize::from_str_radix(hex, 16)
                        .map_err(|_| format!("a chunk's size is not a number: {hex:?}"))?;
                    at += line + 2;
                    self.state = if size == 0 {
                        Chunk::Done
                    } else {
                        Chunk::Data(size)
                    };
                }
                Chunk::Data(left) => {
                    let available = self.buffer.len() - at;
                    if available == 0 {
                        break;
                    }
                    let take = available.min(left);
                    out.extend_from_slice(&self.buffer[at..at + take]);
                    at += take;
                    self.state = if take == left {
                        Chunk::End
                    } else {
                        Chunk::Data(left - take)
                    };
                }
                Chunk::End => {
                    if self.buffer.len() - at < 2 {
                        break;
                    }
                    at += 2;
                    self.state = Chunk::Size;
                }
                Chunk::Done => {
                    at = self.buffer.len();
                    break;
                }
            }
        }
        self.buffer.drain(..at);
        Ok(out)
    }
}

/// A websocket, until it closes. None when the stream was dropped.
async fn websocket(
    request: &AuthorizedRequest,
    outgoing: &mut UnboundedReceiver<Message>,
    sink: &mut (impl FnMut(StreamEvent) + Send),
) -> Option<StreamEnd> {
    let mut handshake = match request.url.as_str().into_client_request() {
        Ok(handshake) => handshake,
        Err(error) => return Some(StreamEnd::failed(error.to_string())),
    };
    if let Ok(value) = request.authorization.parse() {
        handshake.headers_mut().insert("authorization", value);
    }
    let config = WebSocketConfig::default()
        .max_message_size(None)
        .max_frame_size(None);
    let connecting = connect_async_tls_with_config(
        handshake,
        Some(config),
        true,
        Some(Connector::Rustls(tls())),
    );
    let connecting = tokio::time::timeout(CONNECT_TIMEOUT, connecting);
    tokio::pin!(connecting);
    let stream = loop {
        tokio::select! {
            connected = &mut connecting => match connected {
                Err(_) => return Some(StreamEnd::failed("Connection timed out")),
                // The MC answered the handshake with a status: its own words.
                Ok(Err(tungstenite::Error::Http(response))) => {
                    return Some(StreamEnd {
                        status: Some(response.status().as_u16()),
                        error: Some(format!("HTTP error: {}", response.status())),
                        ..StreamEnd::default()
                    });
                }
                Ok(Err(error)) => return Some(StreamEnd::failed(error.to_string())),
                Ok(Ok((stream, _response))) => break stream,
            },
            // Nothing is sent before it opens; only a drop ends it here.
            message = outgoing.recv() => { message?; }
        }
    };
    sink(StreamEvent::Opened { status: 101 });
    let (mut write, mut read) = stream.split();
    let mut end = StreamEnd {
        status: Some(101),
        ..StreamEnd::default()
    };
    loop {
        tokio::select! {
            message = read.next() => match message {
                Some(Ok(Message::Text(text))) => sink(StreamEvent::Text(text.as_str().to_owned())),
                Some(Ok(Message::Binary(bytes))) => sink(StreamEvent::Binary(bytes.to_vec())),
                Some(Ok(Message::Close(frame))) => {
                    if let Some(frame) = frame {
                        end.code = Some(frame.code.into());
                        end.reason = frame.reason.as_str().to_owned();
                    }
                }
                Some(Ok(_)) => {}
                Some(Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed))
                | None => return Some(end),
                Some(Err(error)) => {
                    end.error = Some(error.to_string());
                    return Some(end);
                }
            },
            message = outgoing.recv() => match message {
                Some(message) => {
                    if let Err(error) = write.send(message).await {
                        end.error = Some(error.to_string());
                        return Some(end);
                    }
                }
                None => return None,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;

    use tokio::net::TcpListener;
    use url::Url;

    use super::*;

    fn request(url: &str) -> AuthorizedRequest {
        AuthorizedRequest {
            url: Url::parse(url).unwrap(),
            authorization: "Bearer mc-token".to_owned(),
        }
    }

    /// Feeds a chunked body one byte at a time, which splits every line.
    #[test]
    fn chunked_bodies_decode_however_they_arrive() {
        let body = b"4\r\nWiki\r\n5;x=y\r\npedia\r\n0\r\nTrailer: 1\r\n\r\n";
        let mut whole = Chunked::default();
        assert_eq!(whole.feed(body).unwrap(), b"Wikipedia");
        assert_eq!(whole.state, Chunk::Done);
        let mut bytewise = Chunked::default();
        let out: Vec<u8> = body
            .iter()
            .flat_map(|byte| bytewise.feed(&[*byte]).unwrap())
            .collect();
        assert_eq!(out, b"Wikipedia");
        assert_eq!(bytewise.state, Chunk::Done);
        assert!(Chunked::default().feed(b"zz\r\n").is_err());
    }

    /// Serves one connection with `serve` on a thread of its own and gives the
    /// port.
    fn serve<F, Fut>(serve: F) -> u16
    where
        F: FnOnce(TcpStream) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = ()>,
    {
        let (port_tx, port_rx) = mpsc::channel();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async move {
                let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
                port_tx.send(listener.local_addr().unwrap().port()).unwrap();
                let (stream, _) = listener.accept().await.unwrap();
                serve(stream).await;
            });
        });
        port_rx.recv().unwrap()
    }

    /// Collects a stream's events until it ends.
    fn events(
        stream_request: AuthorizedRequest,
        socket: bool,
    ) -> (Stream, mpsc::Receiver<StreamEvent>) {
        let (tx, rx) = mpsc::channel();
        let stream = open(stream_request, socket, move |event| {
            let _ = tx.send(event);
        });
        (stream, rx)
    }

    fn until_end(rx: &mpsc::Receiver<StreamEvent>) -> Vec<StreamEvent> {
        let mut seen = Vec::new();
        while let Ok(event) = rx.recv() {
            let ended = matches!(event, StreamEvent::Ended(_));
            seen.push(event);
            if ended {
                break;
            }
        }
        seen
    }

    #[test]
    fn a_get_carries_the_token_and_hands_over_its_chunked_body() {
        let (head_tx, head_rx) = mpsc::channel();
        let port = serve(move |mut stream| async move {
            let mut head = Vec::new();
            let mut byte = [0u8; 1];
            while !head.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut byte).await.unwrap();
                head.push(byte[0]);
            }
            head_tx.send(String::from_utf8(head).unwrap()).unwrap();
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n")
                .await
                .unwrap();
            stream.write_all(b"2\r\nde\r\n0\r\n\r\n").await.unwrap();
        });
        let (_stream, rx) = events(
            request(&format!(
                "http://127.0.0.1:{port}/api/device-hub/mcs/a%40b/x?device=1"
            )),
            false,
        );
        let seen = until_end(&rx);
        let head = head_rx.recv().unwrap();
        assert!(
            head.starts_with("GET /api/device-hub/mcs/a%40b/x?device=1 HTTP/1.1\r\n"),
            "{head}"
        );
        assert!(
            head.contains("\r\nAuthorization: Bearer mc-token\r\n"),
            "{head}"
        );
        let body: Vec<u8> = seen
            .iter()
            .filter_map(|event| match event {
                StreamEvent::Data(data) => Some(data.clone()),
                _ => None,
            })
            .flatten()
            .collect();
        assert_eq!(seen.first(), Some(&StreamEvent::Opened { status: 200 }));
        assert_eq!(body, b"abcde");
        assert_eq!(
            seen.last(),
            Some(&StreamEvent::Ended(StreamEnd {
                status: Some(200),
                ..StreamEnd::default()
            }))
        );
    }

    #[test]
    fn a_refused_get_ends_with_its_status() {
        let port = serve(|mut stream| async move {
            let mut buffer = [0u8; 1024];
            let _ = stream.read(&mut buffer).await;
            stream
                .write_all(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")
                .await
                .unwrap();
        });
        let (_stream, rx) = events(request(&format!("http://127.0.0.1:{port}/x")), false);
        let seen = until_end(&rx);
        assert_eq!(seen.first(), Some(&StreamEvent::Opened { status: 401 }));
        assert!(matches!(seen.last(), Some(StreamEvent::Ended(end)) if end.status == Some(401)));
    }

    #[test]
    fn a_websocket_carries_messages_both_ways_and_its_close_code() {
        let port = serve(|stream| async move {
            let mut socket = tokio_tungstenite::accept_hdr_async(
                stream,
                |request: &tungstenite::handshake::server::Request, response| {
                    assert_eq!(request.headers()["authorization"], "Bearer mc-token");
                    Ok(response)
                },
            )
            .await
            .unwrap();
            socket
                .send(Message::binary(vec![0x82, b'{', b'}']))
                .await
                .unwrap();
            let echoed = socket.next().await.unwrap().unwrap();
            assert_eq!(echoed, Message::text("hi"));
            socket
                .close(Some(tungstenite::protocol::CloseFrame {
                    code: 4401.into(),
                    reason: "refused".into(),
                }))
                .await
                .unwrap();
            while socket.next().await.is_some() {}
        });
        let (stream, rx) = events(request(&format!("ws://127.0.0.1:{port}/ws?device=1")), true);
        assert_eq!(rx.recv().unwrap(), StreamEvent::Opened { status: 101 });
        assert_eq!(
            rx.recv().unwrap(),
            StreamEvent::Binary(vec![0x82, b'{', b'}'])
        );
        stream.send_text("hi");
        let seen = until_end(&rx);
        let Some(StreamEvent::Ended(end)) = seen.last() else {
            panic!("{seen:?}");
        };
        assert_eq!((end.code, end.reason.as_str()), (Some(4401), "refused"));
    }

    #[test]
    fn a_websocket_refused_at_its_handshake_ends_with_the_status() {
        let port = serve(|mut stream| async move {
            let mut buffer = [0u8; 4096];
            let _ = stream.read(&mut buffer).await;
            stream
                .write_all(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")
                .await
                .unwrap();
        });
        let (_stream, rx) = events(request(&format!("ws://127.0.0.1:{port}/ws")), true);
        let seen = until_end(&rx);
        assert!(
            matches!(seen.as_slice(), [StreamEvent::Ended(end)] if end.status == Some(401)),
            "{seen:?}"
        );
    }
}
