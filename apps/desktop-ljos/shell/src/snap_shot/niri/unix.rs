//! Niri where it runs (Linux and the BSDs): see [`super`].

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use zbus::blocking::{Connection, MessageIterator};
use zbus::fdo::{RequestNameFlags, RequestNameReply};
use zbus::message::Type as MessageType;

use crate::snap_shot::config::{NIRI_INTERFACE, NIRI_PATH};
use crate::snap_shot::{
    Backend, Captured, Event, Json, Mode, Platform, Session, Shortcut, env_var,
};

const TOO_OLD: &str = "SnapShots require Niri 25.11 or newer.";
const NO_WINDOW: &str = "Niri has no focused window to capture.";
const TIMED_OUT: &str = "Niri did not answer in time.";
const UNREACHABLE: &str = "Could not reach Niri.";
const UNEXPECTED: &str = "Niri sent an unexpected reply.";
const TIMEOUT: Duration = Duration::from_secs(5);
const MAX_MESSAGE: usize = 4 * 1024 * 1024;
/// The endpoint's bus name: the app id's.
const NAME: &str = "hal-c2.SnapShot";

/// $NIRI_SOCKET when it is usable: outside a sandbox, and absolute.
pub fn socket_path() -> Option<PathBuf> {
    if env_var("FLATPAK_ID").is_some() || env_var("SNAP").is_some() {
        return None;
    }
    let socket = PathBuf::from(env_var("NIRI_SOCKET")?);
    socket.is_absolute().then_some(socket)
}

/// The Niri backend where its socket is, else none.
pub fn create(platform: &Platform) -> Option<Box<dyn Backend>> {
    let socket = socket_path()?;
    Some(Box::new(Niri::new(platform, socket)))
}

/// What the threads found out.
enum Arrival {
    Version(Result<String, String>),
    Activated,
    EndpointLost,
    Captured(Captured),
    Failed(String),
}

struct Inbox {
    items: Mutex<Vec<Arrival>>,
    wake: Option<Arc<dyn Fn() + Send + Sync>>,
}

impl Inbox {
    fn push(&self, arrival: Arrival) {
        self.items
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(arrival);
        if let Some(wake) = &self.wake {
            wake();
        }
    }
}

pub struct Niri {
    socket: PathBuf,
    session: Session,
    shortcut: Shortcut,
    probing: bool,
    capturing: bool,
    inbox: Arc<Inbox>,
    /// The endpoint's connection, while it holds the name.
    bus: Option<Connection>,
}

impl Niri {
    pub fn new(platform: &Platform, socket: PathBuf) -> Niri {
        Niri {
            socket,
            session: Session {
                mode: Mode::Portal,
                backend: "niri".into(),
                desktop: platform.desktop.clone(),
                ..Session::default()
            },
            shortcut: Shortcut {
                can_retry: false,
                ..Shortcut::default()
            },
            probing: false,
            capturing: false,
            inbox: Arc::new(Inbox {
                items: Mutex::new(Vec::new()),
                wake: crate::snap_shot::wake(),
            }),
            bus: None,
        }
    }

    fn start_endpoint(&mut self) {
        match endpoint(self.inbox.clone()) {
            Some(bus) => {
                self.bus = Some(bus);
                self.shortcut.registered = true;
                self.shortcut.message = "Set up the shortcut to add it to your Niri config.".into();
            }
            None => {
                self.shortcut.message = "Could not start the Niri capture endpoint. Another HAL-C2 instance may be using it.".into();
            }
        }
    }
}

impl Drop for Niri {
    fn drop(&mut self) {
        if let Some(bus) = self.bus.take() {
            let _ = bus.release_name(NAME);
        }
    }
}

impl Backend for Niri {
    fn session(&self) -> Session {
        self.session.clone()
    }

    fn shortcut(&self) -> Shortcut {
        self.shortcut.clone()
    }

    fn probe(&mut self) -> Vec<Event> {
        if self.session.ready || self.probing {
            return Vec::new();
        }
        self.probing = true;
        self.start_endpoint();
        let socket = self.socket.clone();
        let inbox = self.inbox.clone();
        let spawned = std::thread::Builder::new()
            .name("snap-shot-niri".into())
            .spawn(move || {
                let version = ask(&socket, &json!("Version")).map(|ok| {
                    ok.get("Version")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned()
                });
                inbox.push(Arrival::Version(version));
            });
        if spawned.is_err() {
            self.inbox
                .push(Arrival::Version(Err(UNREACHABLE.to_owned())));
        }
        vec![Event::Changed]
    }

    fn capture(&mut self) -> Vec<Event> {
        if !self.session.message.is_empty() {
            return vec![Event::Failed(self.session.message.clone())];
        }
        // A second press while one is taken is the same capture.
        if self.capturing {
            return Vec::new();
        }
        self.capturing = true;
        let socket = self.socket.clone();
        let inbox = self.inbox.clone();
        let spawned = std::thread::Builder::new()
            .name("snap-shot-niri-capture".into())
            .spawn(move || {
                inbox.push(match capture(&socket) {
                    Ok(captured) => Arrival::Captured(captured),
                    Err(failure) => Arrival::Failed(failure),
                })
            });
        if spawned.is_err() {
            self.capturing = false;
            return vec![Event::Failed("Could not prepare the capture.".into())];
        }
        Vec::new()
    }

    fn arrive(&mut self) -> Vec<Event> {
        let arrivals =
            std::mem::take(&mut *self.inbox.items.lock().unwrap_or_else(|e| e.into_inner()));
        let mut events = Vec::new();
        for arrival in arrivals {
            match arrival {
                Arrival::Version(version) => {
                    self.probing = false;
                    self.session.ready = true;
                    match version {
                        Err(error) => self.session.message = error,
                        Ok(version) if !recent(&version) => self.session.message = TOO_OLD.into(),
                        Ok(_) => {}
                    }
                    events.push(Event::Changed);
                }
                Arrival::Activated => events.push(Event::Activated),
                Arrival::EndpointLost => {
                    if self.shortcut.registered {
                        self.shortcut.registered = false;
                        self.shortcut.message =
                            "The Niri capture endpoint disconnected. Restart HAL-C2.".into();
                        events.push(Event::Changed);
                    }
                }
                Arrival::Captured(captured) => {
                    self.capturing = false;
                    events.push(Event::Captured(captured));
                }
                Arrival::Failed(failure) => {
                    self.capturing = false;
                    events.push(Event::Failed(failure));
                }
            }
        }
        events
    }
}

/// Niri 25.11 or newer, from what `Version` says ("25.11.0", "niri 25.11 (…)").
fn recent(version: &str) -> bool {
    let version = version.strip_prefix("niri ").unwrap_or(version);
    let mut parts = version.splitn(2, '.');
    let number = |part: Option<&str>| -> Option<u32> {
        let digits: String = part?.chars().take_while(char::is_ascii_digit).collect();
        digits.parse().ok()
    };
    let major = number(parts.next());
    let minor = number(parts.next());
    matches!((major, minor), (Some(major), Some(minor)) if major > 25 || (major == 25 && minor >= 11))
}

/// The bus the endpoint is on: a test's stand-in environment names its own
/// (and without one has none, so a test never takes the real session's
/// name); otherwise the session bus.
fn bus() -> Option<Connection> {
    if crate::snap_shot::environment_overridden() {
        let address = env_var("DBUS_SESSION_BUS_ADDRESS")?;
        return zbus::blocking::connection::Builder::address(address.as_str())
            .ok()?
            .build()
            .ok();
    }
    Connection::session().ok()
}

/// Takes the endpoint's name and answers its calls on a thread; none when
/// the bus is not there or the name is someone else's.
fn endpoint(inbox: Arc<Inbox>) -> Option<Connection> {
    let bus = bus()?;
    // Before the name is taken, so no call is missed.
    let messages = MessageIterator::from(&bus);
    let reply = bus
        .request_name_with_flags(NAME, RequestNameFlags::DoNotQueue.into())
        .ok()?;
    if reply != RequestNameReply::PrimaryOwner {
        return None;
    }
    let answering = bus.clone();
    std::thread::Builder::new()
        .name("snap-shot-niri-endpoint".into())
        .spawn(move || {
            for message in messages {
                let Ok(message) = message else { break };
                if !answer(&answering, &message, &inbox) {
                    break;
                }
            }
            inbox.push(Arrival::EndpointLost);
        })
        .ok()?;
    Some(bus)
}

/// Answers one message on the endpoint's connection; false once the name
/// is lost.
fn answer(bus: &Connection, message: &zbus::Message, inbox: &Inbox) -> bool {
    let header = message.header();
    let member = header.member().map(|m| m.as_str()).unwrap_or_default();
    let interface = header.interface().map(|i| i.as_str()).unwrap_or_default();
    match header.message_type() {
        MessageType::Signal => {
            if interface == "org.freedesktop.DBus" && member == "NameLost" {
                let lost: Result<String, _> = message.body().deserialize();
                return lost.as_deref() != Ok(NAME);
            }
            if interface == "org.freedesktop.DBus.Local" && member == "Disconnected" {
                return false;
            }
            true
        }
        MessageType::MethodCall => {
            let path = header.path().map(|p| p.as_str()).unwrap_or_default();
            let empty = message.body().signature().to_string().is_empty();
            if path != NIRI_PATH {
                let _ = bus.reply_error(
                    &header,
                    "org.freedesktop.DBus.Error.UnknownObject",
                    &"No such object.",
                );
            } else if interface == "org.freedesktop.DBus.Introspectable" && member == "Introspect" {
                let xml = format!(
                    "<node><interface name=\"{NIRI_INTERFACE}\"><method name=\"Capture\"/></interface></node>"
                );
                let _ = bus.reply(&header, &xml);
            } else if interface == NIRI_INTERFACE && member == "Capture" {
                if empty {
                    // Before the reply, so a caller that waited on it finds the press.
                    inbox.push(Arrival::Activated);
                    let _ = bus.reply(&header, &());
                } else {
                    let _ = bus.reply_error(
                        &header,
                        "org.freedesktop.DBus.Error.InvalidArgs",
                        &"Capture takes no arguments.",
                    );
                }
            } else {
                let _ = bus.reply_error(
                    &header,
                    "org.freedesktop.DBus.Error.UnknownMethod",
                    &"No such method.",
                );
            }
            true
        }
        _ => true,
    }
}

/// A connection to Niri that gives up at `deadline`.
fn connect(socket: &Path, deadline: Instant) -> Result<UnixStream, String> {
    let stream = UnixStream::connect(socket).map_err(|_| UNREACHABLE.to_owned())?;
    let left = deadline
        .checked_duration_since(Instant::now())
        .ok_or_else(|| TIMED_OUT.to_owned())?;
    stream
        .set_read_timeout(Some(left.max(Duration::from_millis(1))))
        .and_then(|()| stream.set_write_timeout(Some(TIMEOUT)))
        .map_err(|_| UNREACHABLE.to_owned())?;
    Ok(stream)
}

fn send(stream: &mut UnixStream, request: &Value) -> Result<(), String> {
    let mut line = request.to_string().into_bytes();
    line.push(b'\n');
    stream.write_all(&line).map_err(|_| UNREACHABLE.to_owned())
}

/// The next JSON line; at most [`MAX_MESSAGE`] long.
fn line(reader: &mut BufReader<UnixStream>, deadline: Instant) -> Result<Value, String> {
    let left = deadline
        .checked_duration_since(Instant::now())
        .ok_or_else(|| TIMED_OUT.to_owned())?;
    let _ = reader
        .get_ref()
        .set_read_timeout(Some(left.max(Duration::from_millis(1))));
    let mut bytes = Vec::new();
    let read = reader
        .by_ref()
        .take(MAX_MESSAGE as u64 + 1)
        .read_until(b'\n', &mut bytes);
    match read {
        Ok(0) => Err(UNREACHABLE.to_owned()),
        Ok(_) if bytes.last() != Some(&b'\n') => Err(UNEXPECTED.to_owned()),
        Ok(_) => Ok(serde_json::from_slice(&bytes).unwrap_or(Value::Null)),
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) =>
        {
            Err(TIMED_OUT.to_owned())
        }
        Err(_) => Err(UNREACHABLE.to_owned()),
    }
}

/// The `Err` of a reply or event, as the user is told it.
fn refusal(reply: &Value) -> Option<String> {
    let error = reply.get("Err")?;
    Some(format!("Niri: {}", error.as_str().unwrap_or_default()))
}

/// Asks Niri `request` on a connection of its own: the reply's `Ok`.
fn ask(socket: &Path, request: &Value) -> Result<Value, String> {
    let deadline = Instant::now() + TIMEOUT;
    let mut stream = connect(socket, deadline)?;
    send(&mut stream, request)?;
    let reply = line(&mut BufReader::new(stream), deadline)?;
    if let Some(error) = refusal(&reply) {
        return Err(error);
    }
    reply
        .get("Ok")
        .cloned()
        .ok_or_else(|| UNEXPECTED.to_owned())
}

/// A window's identity, to tell it is still the one captured.
fn same_window(a: &Value, b: &Value) -> bool {
    ["id", "pid", "app_id", "title"]
        .iter()
        .all(|key| a.get(key) == b.get(key))
}

/// Where Niri writes the picture: a folder of this capture's own.
struct Folder(PathBuf);

impl Folder {
    fn new() -> Option<Folder> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let base = env_var("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .filter(|dir| dir.is_absolute())
            .unwrap_or_else(std::env::temp_dir);
        let name = format!(
            "hal-c2-niri-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let path = base.join(name);
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
        builder.create(&path).ok()?;
        Some(Folder(path))
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The focused window, captured: the event stream first, so the
/// screenshot's event is not missed; then the window it names.
fn capture(socket: &Path) -> Result<Captured, String> {
    let deadline = Instant::now() + TIMEOUT;
    let folder = Folder::new().ok_or_else(|| "Could not prepare the capture.".to_owned())?;
    let path = folder.0.join("capture.png");
    let path_text = path.to_string_lossy().into_owned();
    let mut events = connect(socket, deadline)?;
    send(&mut events, &json!("EventStream"))?;
    let mut events = BufReader::new(events);
    let mut window: Option<Value> = None;
    loop {
        let event = line(&mut events, deadline)?;
        if let Some(error) = refusal(&event) {
            return Err(error);
        }
        if event.get("WindowsChanged").is_some() && window.is_none() {
            let ok = ask(socket, &json!("FocusedWindow"))?;
            let focused = ok.get("FocusedWindow").cloned().unwrap_or(Value::Null);
            if !focused.is_object() {
                return Err(NO_WINDOW.to_owned());
            }
            let action = json!({"Action": {"ScreenshotWindow": {
                "id": focused.get("id").cloned().unwrap_or(Value::Null),
                "write_to_disk": true,
                "show_pointer": false,
                "path": path_text,
            }}});
            ask(socket, &action)?;
            window = Some(focused);
            continue;
        }
        let shot = event
            .get("ScreenshotCaptured")
            .and_then(|shot| shot.get("path"))
            .and_then(Value::as_str);
        let Some(window) = window.as_ref().filter(|_| shot == Some(&path_text)) else {
            continue;
        };
        let image = image::open(&path)
            .map_err(|_| "Niri returned an unreadable screenshot.".to_owned())?
            .to_rgba8();
        // The title is only the window's while it is still the one captured.
        let windows = ask(socket, &json!("Windows")).unwrap_or(Value::Null);
        let same = windows
            .get("Windows")
            .and_then(Value::as_array)
            .is_some_and(|all| all.iter().any(|other| same_window(other, window)));
        let field = |key: &str| {
            same.then(|| window.get(key).and_then(Value::as_str))
                .flatten()
                .unwrap_or_default()
                .to_owned()
        };
        let app = field("app_id");
        return Ok(Captured {
            image,
            app_name: if app.is_empty() { "Window".into() } else { app },
            window_title: field("title"),
            context: Json::Null,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn niri_versions() {
        assert!(recent("25.11.0"));
        assert!(recent("niri 25.11 (abc)"));
        assert!(recent("26.1"));
        assert!(!recent("25.8.0"));
        assert!(!recent("unknown"));
    }
}
