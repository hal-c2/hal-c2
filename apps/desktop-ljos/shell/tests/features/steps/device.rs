//! The right panel's Device tabs (ThreadDevices, DeviceStream, the stream
//! decoder): the MC's DeviceServiceState on the `devices` shape and
//! `device.list`, `device.open` and `device.close`, and a fake device hub
//! behind the MC's `/api/device-hub/` proxy speaking serve-sim (AVCC video,
//! `[tag][json]` input) and serve-emu (SEMU-framed Annex-B and JSON gestures
//! on one socket). The pictures are the committed fixture, a solid red 72x160
//! H.264 clip, decoded by Ljós's decoder.
//!
//! The tab is the desktop's own DevicePanel (qml/HalC2/Bricks), loaded over
//! the right panel's ThreadDevices once the user looks at the thread: the
//! user's clicks, drags and keys are events on the window, and a step reads
//! the picture back from what the window painted for DeviceScreen.
//! Choosing which tab shows is the right panel's, so those steps dispatch.
//! features/preview/devices.feature, desktop-qt's DeviceSteps.cpp.

use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, TryRecvError, channel};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::device::decoder;
use hal_c2_shell::device::devices::{DeviceTab, ThreadDevices, tab_id_of};
use hal_c2_shell::device::stream::DeviceStream;
use hal_c2_shell::device::tools::{DeviceTools, PRESETS};
use ljos::item::{DrawOp, KeyEvent, PointerEvent};
use ljos::prelude::{ObjectId, Value as QmlValue};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::{self, Message};

use super::stream::{THREAD, look as look_stream, look_at_thread};
use crate::brick::{Brick, key_event};
use crate::fake_mc::FakeMc;
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::world::{Signal, World};
use crate::{expect, fail};

#[path = "../../support/device_fixture.rs"]
mod device_fixture;

const HOST: &str = "local";
const PROJECT: &str = super::stream::PROJECT;
const RETRY_MS: i32 = 50;
const FIRST_FRAME_MS: i32 = 15000;

/// What the hub's sockets saw, from their threads.
#[derive(Default)]
struct Seen {
    /// Every request that reached the proxy: "<target> <authorization>".
    requests: Vec<String>,
    /// What the device received: serve-sim's `[tag][json]`.
    binary: Vec<Vec<u8>>,
    /// What the device received: serve-emu's JSON.
    text: Vec<Value>,
}

/// What the scenario's thread and the hub's socket threads share.
#[derive(Default)]
struct Shared {
    seen: Mutex<Seen>,
    /// The device has sent no picture yet.
    silent: AtomicBool,
    /// The hub is gone: its socket threads end.
    stop: AtomicBool,
    signal: Mutex<Option<Arc<Signal>>>,
}

impl Shared {
    fn seen(&self) -> MutexGuard<'_, Seen> {
        self.seen.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Wakes the scenario's thread to look at what arrived.
    fn notify(&self) {
        let signal = self.signal.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(signal) = &*signal {
            signal.notify();
        }
    }
}

/// A serve-emu socket the device keeps open.
struct Input {
    android: bool,
    out: Sender<Message>,
    closed: Arc<AtomicBool>,
}

/// The environment's devices and the hub the MC proxies to.
struct FakeHub {
    devices: Vec<Value>,
    sessions: Vec<Value>,
    host_status: String,
    /// The local host's own status and detail, when they differ from the whole.
    local_status: String,
    banner_detail: String,
    host_label: String,
    host_detail: String,
    onboarding: bool,
    agent_access: bool,
    supports_retry: bool,
    /// Platform availability by platform, when a scenario sets it.
    availability: Vec<(String, Value)>,
    configures: Vec<Value>,
    lists: Vec<Value>,
    revision: i64,
    /// Why the MC fails `device.open`, when it does.
    refuse_open: String,
    closes: Vec<Value>,
    /// The proxy's status for every hub request (401: a refused credential), when not 0.
    refuse: u16,
    /// Its video is not one the desktop can decode.
    undecodable: bool,
    used: bool,
    looking: bool,
    shared: Arc<Shared>,
    videos: Vec<TcpStream>,
    kept: Vec<TcpStream>,
    inputs: Vec<Input>,
    /// The Tools drawer's device: its settings, the app in front (null:
    /// none), and every `device.action` it was asked.
    settings: Value,
    foreground_app: Value,
    actions: Vec<Value>,
    /// Why the device refuses every change, when it does.
    refuse_action: String,
    /// The accessibility requests served, and whether they get an answer.
    ax_requests: usize,
    stall_ax: bool,
    android_ax: Value,
    /// The iOS accessibility tree the hub answers.
    ax_tree: Value,
    /// The tools' server-sent event feeds, by path, held open.
    feeds: Vec<(String, TcpStream)>,
    feed_requests: usize,
    /// What the tools steps typed last, and where they mean the device to be.
    last_field: String,
    wanted_location: (f64, f64),
    /// No hub base path: the client was given no device access.
    no_access: bool,
    /// FFmpeg is made to look not installed, until this MC goes.
    no_ffmpeg: bool,
    /// A second machine offering devices, when the scenario has one.
    second_host_id: String,
    second_label: String,
    /// Devices starting for a thread: {name, threadId}.
    booting: Vec<Value>,
    /// The devices shape is not answered yet.
    hold_state: bool,
    /// The stream's access expired: only a fresh ticket is let through.
    expired: bool,
    ticket_requests: usize,
    /// The one ticket an expired stream may use: the latest given out.
    accepted_ticket: String,
    /// Ticket requests kept unanswered, while held.
    hold_tickets: bool,
    /// The unanswered ticket requests, with the ticket each was minted.
    held_tickets: Vec<(TcpStream, String)>,
    /// device.close is refused with this, when not empty.
    refuse_close: String,
    /// Each device's video requests when a step began that must keep its
    /// stream, by name.
    kept_counts: std::collections::HashMap<String, usize>,
    /// New input connections are closed at once.
    drop_inputs: bool,
    /// The 3D body's yaw while a drag was still held.
    dragged_yaw: f64,
}

impl Default for FakeHub {
    fn default() -> FakeHub {
        FakeHub {
            devices: Vec::new(),
            sessions: Vec::new(),
            host_status: "ready".into(),
            local_status: String::new(),
            banner_detail: String::new(),
            host_label: "This Mac".into(),
            host_detail: String::new(),
            onboarding: true,
            agent_access: false,
            supports_retry: false,
            availability: Vec::new(),
            configures: Vec::new(),
            lists: Vec::new(),
            revision: 0,
            refuse_open: String::new(),
            closes: Vec::new(),
            refuse: 0,
            undecodable: false,
            used: false,
            looking: false,
            shared: Arc::default(),
            videos: Vec::new(),
            kept: Vec::new(),
            inputs: Vec::new(),
            settings: json!({
                "appearance": "light",
                "textSize": "default",
                "liquidGlass": "clear",
                "colorFilter": "none",
                "reduceMotion": false,
                "increaseContrast": false,
                "reduceTransparency": false,
                "showBorders": false,
                "voiceOver": false,
                "networkEnabled": true,
            }),
            foreground_app: Value::Null,
            actions: Vec::new(),
            refuse_action: String::new(),
            ax_requests: 0,
            stall_ax: false,
            android_ax: Value::Null,
            ax_tree: json!([]),
            feeds: Vec::new(),
            feed_requests: 0,
            last_field: String::new(),
            wanted_location: (0.0, 0.0),
            no_access: false,
            no_ffmpeg: false,
            second_host_id: String::new(),
            second_label: String::new(),
            booting: Vec::new(),
            hold_state: false,
            expired: false,
            ticket_requests: 0,
            accepted_ticket: String::new(),
            hold_tickets: false,
            held_tickets: Vec::new(),
            refuse_close: String::new(),
            kept_counts: std::collections::HashMap::new(),
            drop_inputs: false,
            dragged_yaw: 0.0,
        }
    }
}

impl Drop for FakeHub {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::SeqCst);
        if self.no_ffmpeg {
            decoder::pretend_missing(false);
        }
    }
}

/// The Device tab's brick, once shown over the right panel's ThreadDevices.
#[derive(Default)]
struct Panel(Option<Brick>);

/// The right panel's own brick, for its tab strip (renaming a tab).
#[derive(Default)]
struct RightPanelBrick(Option<Brick>);

fn panel_brick(world: &mut World) -> Outcome<Brick> {
    if let Some(brick) = world.part::<RightPanelBrick>().0 {
        return Ok(brick);
    }
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nRightPanel {}\n",
        900.0,
        600.0,
    )?;
    world.part::<RightPanelBrick>().0 = Some(brick);
    Ok(brick)
}

/// Whether the Device tab's brick shows `words`, as the user reads them.
fn device_panel_shows(world: &World, words: &str) -> bool {
    world
        .peek_part::<Panel>()
        .and_then(|p| p.0)
        .is_some_and(|brick| brick.shows(world, words).unwrap_or(false))
}

fn state_of(mc: &mut FakeMc) -> Value {
    let name = mc.name.clone();
    let hub = mc.part::<FakeHub>();
    let availability = |platform: &str| {
        hub.availability
            .iter()
            .find(|(p, _)| p == platform)
            .map_or_else(
                || json!({"platform": platform, "available": true}),
                |(_, a)| a.clone(),
            )
    };
    let platforms = json!([availability("ios"), availability("android")]);
    let local = if hub.local_status.is_empty() {
        &hub.host_status
    } else {
        &hub.local_status
    };
    let mut local_status = json!({"status": local});
    if !hub.banner_detail.is_empty() {
        local_status["detail"] = json!(hub.banner_detail);
    }
    let host = |id: &str, kind: &str, label: &str| {
        json!({
            "id": id,
            "kind": kind,
            "label": label,
            "platforms": platforms,
            "hubInstalled": true,
            "agentDeviceInstalled": true,
        })
    };
    let mut hosts = vec![host(HOST, "local", &hub.host_label)];
    let mut statuses = json!({HOST: local_status});
    if !hub.second_host_id.is_empty() {
        hosts.push(host(&hub.second_host_id, "ssh", &hub.second_label));
        statuses[hub.second_host_id.clone()] = json!({"status": "ready"});
    }
    let mut state = json!({
        "hosts": hosts,
        "hostStatus": hub.host_status,
        "hostStatuses": statuses,
        "devices": hub.devices,
        "sessions": hub.sessions,
        "bootingDevices": hub.booting,
        "onboardingCompleted": hub.onboarding,
        "agentAccessEnabled": hub.agent_access,
        "supportsHostRetry": hub.supports_retry,
        "hubBasePath": if hub.no_access {
            String::new()
        } else {
            format!("/api/device-hub/mcs/{}", hal_c2_shell::device::percent(&name))
        },
        "revision": hub.revision,
    });
    if !hub.host_detail.is_empty() {
        state["hostStatusDetail"] = json!(hub.host_detail);
    }
    state
}

/// The MC's `device.configure`: turns the hub and agent access on or off and
/// records setup as done, then tells every watcher.
fn configure(mc: &mut FakeMc, rpc: &crate::fake_mc::Rpc) {
    let hub = mc.part::<FakeHub>();
    hub.configures.push(rpc.payload.clone());
    if let Some(enabled) = rpc.payload["enabled"].as_bool() {
        if !enabled {
            hub.host_status = "disabled".into();
        } else if hub.host_status == "disabled" {
            hub.host_status = "installing".into();
        }
    }
    if let Some(on) = rpc.payload["agentAccessEnabled"].as_bool() {
        hub.agent_access = on;
    }
    if let Some(done) = rpc.payload["onboardingCompleted"].as_bool() {
        hub.onboarding = done;
    }
    announce(mc);
    let state = state_of(mc);
    mc.reply(rpc, state);
}

/// The MC tells every watcher, as devices.ex does on each change.
fn announce(mc: &mut FakeMc) {
    mc.part::<FakeHub>().revision += 1;
    let state = state_of(mc);
    for id in mc.subscribers("devices") {
        mc.send(&json!({"t": "devices", "id": id, "state": state}));
    }
}

/// What `device.detail` and `device.action` answer: the device as it is now.
fn detail_of(hub: &FakeHub, rpc: &crate::fake_mc::Rpc) -> Value {
    json!({
        "hostId": rpc.payload.get("hostId").cloned().unwrap_or_else(|| json!(HOST)),
        "deviceId": rpc.payload["deviceId"],
        "settings": hub.settings,
        "foregroundApp": hub.foreground_app,
        "readAt": "2026-09-23T10:00:00Z",
    })
}

/// The MC's `device.action`: the device applies the change, or refuses it.
fn act(mc: &mut FakeMc, rpc: &crate::fake_mc::Rpc) {
    let hub = mc.part::<FakeHub>();
    let payload = &rpc.payload;
    hub.actions.push(payload.clone());
    if !hub.refuse_action.is_empty() {
        let refusal = hub.refuse_action.clone();
        mc.refuse(rpc, &refusal);
        return;
    }
    let setting = match payload["type"].as_str().unwrap_or_default() {
        "setAppearance" => Some("appearance".to_owned()),
        "setTextSize" => Some("textSize".to_owned()),
        "setLiquidGlass" => Some("liquidGlass".to_owned()),
        "setColorFilter" => Some("colorFilter".to_owned()),
        "setToggle" => Some(text(&payload["setting"])),
        _ => None,
    };
    if let Some(setting) = setting {
        hub.settings[setting] = payload["value"].clone();
    }
    match payload["type"].as_str().unwrap_or_default() {
        "setLocation" => {
            hub.settings["location"] =
                json!({"latitude": payload["latitude"], "longitude": payload["longitude"]});
        }
        "clearLocation" => hub.settings["location"] = Value::Null,
        "terminateApp" => hub.foreground_app = Value::Null,
        "launchApp" => hub.foreground_app = json!({"id": payload["appId"]}),
        _ => {}
    }
    let detail = detail_of(hub, rpc);
    mc.reply(rpc, detail);
}

fn session_of(hub: &FakeHub, device_id: &str, thread: &str) -> Option<usize> {
    session_on(hub, device_id, thread, "")
}

fn session_on(hub: &FakeHub, device_id: &str, thread: &str, host: &str) -> Option<usize> {
    hub.sessions.iter().position(|s| {
        text(&s["threadId"]) == thread
            && text(&s["deviceId"]) == device_id
            && (host.is_empty() || text(&s["hostId"]) == host)
    })
}

fn device_named(hub: &FakeHub, name: &str) -> Outcome<Value> {
    match hub.devices.iter().find(|d| text(&d["name"]) == name) {
        Some(device) => Ok(device.clone()),
        None => fail!("the hub has no device \"{name}\""),
    }
}

fn open_session(mc: &mut FakeMc, device: &Value, thread: &str) {
    let hub = mc.part::<FakeHub>();
    for listed in &mut hub.devices {
        if listed["id"] == device["id"] {
            listed["booted"] = json!(true);
        }
    }
    let host = {
        let host = text(&device["hostId"]);
        if host.is_empty() {
            HOST.to_owned()
        } else {
            host
        }
    };
    if session_on(hub, &text(&device["id"]), thread, &host).is_none() {
        hub.sessions.push(json!({
            "threadId": thread,
            "hostId": host,
            "deviceId": device["id"],
            "platform": device["platform"],
            "openedAt": "2026-09-23T10:00:00Z",
        }));
    }
}

fn android_frames() -> Vec<Message> {
    device_fixture::android_video()
        .into_iter()
        .map(|(frame, _)| Message::binary(frame))
        .collect()
}

/// Whether the peer still holds `stream` open.
fn connected(stream: &TcpStream) -> bool {
    let _ = stream.set_nonblocking(true);
    let alive = match stream.peek(&mut [0u8; 1]) {
        Ok(0) => false,
        Ok(_) => true,
        Err(e) => e.kind() == std::io::ErrorKind::WouldBlock,
    };
    let _ = stream.set_nonblocking(false);
    alive
}

fn send_video(hub: &mut FakeHub) {
    for video in &mut hub.videos {
        if connected(video) {
            let _ = video.write_all(&device_fixture::ios_video(false));
        }
    }
    for input in &hub.inputs {
        if input.android && !input.closed.load(Ordering::SeqCst) {
            for frame in android_frames() {
                let _ = input.out.send(frame);
            }
        }
    }
}

fn respond(mut stream: TcpStream, status: u16) {
    let _ = write!(
        stream,
        "HTTP/1.1 {status} Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    );
    let _ = stream.shutdown(Shutdown::Both);
}

/// One serve-sim or serve-emu socket, on a thread of its own: records what
/// the device receives, sends what the scenario queues, and answers
/// serve-emu's keyframe request with a fresh keyframe.
fn serve_socket(
    stream: TcpStream,
    android: bool,
    shared: Arc<Shared>,
    queued: Receiver<Message>,
    closed: Arc<AtomicBool>,
) {
    let Ok(mut socket) = tungstenite::accept(stream) else {
        closed.store(true, Ordering::SeqCst);
        return;
    };
    let _ = socket
        .get_ref()
        .set_read_timeout(Some(Duration::from_millis(20)));
    if android && !shared.silent.load(Ordering::SeqCst) {
        for frame in android_frames() {
            if socket.send(frame).is_err() {
                break;
            }
        }
    }
    'serving: while !shared.stop.load(Ordering::SeqCst) {
        loop {
            match queued.try_recv() {
                Ok(message) => {
                    if socket.send(message).is_err() {
                        break 'serving;
                    }
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => break 'serving,
            }
        }
        match socket.read() {
            Ok(Message::Binary(bytes)) => {
                shared.seen().binary.push(bytes.to_vec());
                shared.notify();
            }
            Ok(Message::Text(message)) => {
                let parsed: Value = serde_json::from_str(message.as_str()).unwrap_or(Value::Null);
                let reset = parsed["type"] == "reset-video";
                shared.seen().text.push(parsed);
                if reset && !shared.silent.load(Ordering::SeqCst) {
                    for frame in android_frames() {
                        let _ = socket.send(frame);
                    }
                }
                shared.notify();
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(tungstenite::Error::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(_) => break,
        }
    }
    closed.store(true, Ordering::SeqCst);
    shared.notify();
}

/// The proxy's answer to a hub request, as the MC's device proxy gives it.
fn proxy(mc: &mut FakeMc, mut stream: TcpStream, head: &str) -> Outcome {
    let hub = mc.part::<FakeHub>();
    let target = head
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .unwrap_or_default()
        .to_owned();
    let mut authorization = String::new();
    let mut upgrade = false;
    for line in head.lines() {
        let lower = line.trim().to_lowercase();
        if lower.starts_with("authorization:") {
            authorization = line.trim()[14..].trim().to_owned();
        }
        if lower.starts_with("upgrade:") {
            upgrade = true;
        }
    }
    hub.shared
        .seen()
        .requests
        .push(format!("{target} {authorization}"));
    hub.shared.notify();
    if hub.expired
        && (hub.accepted_ticket.is_empty()
            || !target.contains(&format!("wsTicket={}", hub.accepted_ticket)))
    {
        let _ = stream.read_exact(&mut vec![0u8; head.len()]);
        respond(stream, 401);
        return Ok(());
    }
    if hub.refuse != 0 {
        let _ = stream.read_exact(&mut vec![0u8; head.len()]);
        respond(stream, hub.refuse);
        return Ok(());
    }
    if upgrade && hub.drop_inputs {
        std::thread::spawn(move || {
            if let Ok(mut socket) = tungstenite::accept(stream) {
                let _ = socket.close(Some(tungstenite::protocol::CloseFrame {
                    code: tungstenite::protocol::frame::coding::CloseCode::Normal,
                    reason: "socket closed".into(),
                }));
            }
        });
        return Ok(());
    }
    if upgrade {
        let android = target
            .split('?')
            .next()
            .unwrap_or_default()
            .ends_with("/serve-emu/ws");
        let (out, queued) = channel();
        let closed = Arc::new(AtomicBool::new(false));
        hub.inputs.push(Input {
            android,
            out,
            closed: closed.clone(),
        });
        let shared = hub.shared.clone();
        std::thread::spawn(move || serve_socket(stream, android, shared, queued, closed));
        return Ok(());
    }
    let _ = stream.read_exact(&mut vec![0u8; head.len()]);
    let path = target.split('?').next().unwrap_or_default();
    if path.ends_with("/stream.mjpeg") {
        let _ = stream.write_all(
            b"HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nConnection: close\r\n\r\n--frame\r\n",
        );
        hub.kept.push(stream);
        return Ok(());
    }
    // The tools' read-only feeds: server-sent events, held open.
    if path.ends_with("/appstate") || path.ends_with("/api/event-log/events") {
        let _ = stream.write_all(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
        );
        hub.feeds.push((path.to_owned(), stream));
        hub.feed_requests += 1;
        return Ok(());
    }
    if path.ends_with("/ax") || path.ends_with("/api/accessibility") {
        hub.ax_requests += 1;
        if hub.stall_ax {
            hub.kept.push(stream);
            return Ok(());
        }
        let tree = if hub.android_ax.is_null() {
            &hub.ax_tree
        } else {
            &hub.android_ax
        };
        let body = tree.to_string();
        let _ = write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.shutdown(Shutdown::Both);
        return Ok(());
    }
    if path.ends_with("/stream.avcc") {
        let _ = stream.write_all(
            b"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n",
        );
        if !hub.shared.silent.load(Ordering::SeqCst) {
            let _ = stream.write_all(&device_fixture::ios_video(hub.undecodable));
        }
        if let Ok(kept) = stream.try_clone() {
            hub.videos.push(kept);
        }
        hub.kept.push(stream);
        return Ok(());
    }
    respond(stream, 404);
    Ok(())
}

fn open_device(mc: &mut FakeMc, rpc: &crate::fake_mc::Rpc) {
    let refusal = mc.part::<FakeHub>().refuse_open.clone();
    if !refusal.is_empty() {
        mc.refuse(rpc, &refusal);
        return;
    }
    let wanted = &rpc.payload["deviceId"];
    let host = &rpc.payload["hostId"];
    let device = mc
        .part::<FakeHub>()
        .devices
        .iter()
        .find(|d| d["id"] == *wanted && (host.is_null() || d["hostId"] == *host))
        .cloned();
    let Some(device) = device else {
        mc.refuse(rpc, "Device not found");
        return;
    };
    let thread = text(&rpc.payload["threadId"]);
    open_session(mc, &device, &thread);
    announce(mc);
    let hub = mc.part::<FakeHub>();
    let host = {
        let host = text(&device["hostId"]);
        if host.is_empty() {
            HOST.to_owned()
        } else {
            host
        }
    };
    let session = session_on(hub, &text(&device["id"]), &thread, &host)
        .map_or(Value::Null, |at| hub.sessions[at].clone());
    mc.reply(rpc, session);
}

fn answer_ticket(mc: &mut FakeMc, stream: TcpStream, ticket: &str) {
    mc.part::<FakeHub>().accepted_ticket = ticket.to_owned();
    send_ticket(stream, ticket);
}

fn send_ticket(mut stream: TcpStream, ticket: &str) {
    let body = json!({"ticket": ticket}).to_string();
    let _ = write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.flush();
    let _ = stream.shutdown(Shutdown::Both);
}

/// Reads a whole request (its head was only peeked), body included.
fn read_whole_request(stream: &mut TcpStream) {
    // Bounded: a client that never finishes its request fails its own step.
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 8192];
    loop {
        let n = stream.read(&mut buffer).unwrap_or(0);
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
}

fn close_device(mc: &mut FakeMc, rpc: &crate::fake_mc::Rpc) {
    if !mc.part::<FakeHub>().refuse_close.is_empty() {
        let why = mc.part::<FakeHub>().refuse_close.clone();
        return mc.refuse(rpc, &why);
    }
    mc.part::<FakeHub>().closes.push(rpc.payload.clone());
    let hub = mc.part::<FakeHub>();
    let at = session_of(
        hub,
        &text(&rpc.payload["deviceId"]),
        &text(&rpc.payload["threadId"]),
    );
    if let Some(at) = at {
        hub.sessions.remove(at);
    }
    announce(mc);
    mc.reply(rpc, Value::Null);
}

/// The MC's devices as this file fakes them. A scenario that uses the hub
/// takes them over on first use, before the shell connects.
fn fake_hub(world: &mut World) -> &mut FakeHub {
    if !world.mc.part::<FakeHub>().used {
        world.mc.part::<FakeHub>().used = true;
        let signal = world.mc.signal();
        *world
            .mc
            .part::<FakeHub>()
            .shared
            .signal
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(signal);
        // As an MC is named (`name@host`), which its hubBasePath carries encoded.
        world.mc.name = "hal-c2@studio".into();
        world.mc.on_shape("devices", |mc, id, _| {
            if mc.part::<FakeHub>().hold_state {
                return Ok(());
            }
            let state = state_of(mc);
            mc.send(&json!({"t": "devices", "id": id, "state": state}));
            Ok(())
        });
        world.mc.on_rpc("device.list", |mc, rpc| {
            mc.part::<FakeHub>().lists.push(rpc.payload.clone());
            if mc.holding("device.list") {
                let rpc = rpc.clone();
                mc.defer(move |mc| {
                    let state = state_of(mc);
                    mc.reply(&rpc, state);
                });
                return Ok(());
            }
            let state = state_of(mc);
            mc.reply(rpc, state);
            Ok(())
        });
        world.mc.on_rpc("device.configure", |mc, rpc| {
            if mc.holding("device.configure") {
                let rpc = rpc.clone();
                mc.defer(move |mc| configure(mc, &rpc));
                return Ok(());
            }
            configure(mc, rpc);
            Ok(())
        });
        // The stream mints its ticket over HTTP (Mc::post), as in the app.
        // A raw route, as connection_health's fake answers this path for
        // the client's own socket (and a raw route wins over on_http);
        // until the stream's access expires that is all it answers.
        world
            .mc
            .on_raw("/api/auth/websocket-ticket", |mc, mut stream, _head| {
                read_whole_request(&mut stream);
                let hub = mc.part::<FakeHub>();
                if !hub.expired {
                    send_ticket(stream, "ticket-socket");
                    return Ok(());
                }
                hub.ticket_requests += 1;
                let ticket = format!("fresh{}", hub.ticket_requests);
                if hub.hold_tickets {
                    hub.held_tickets.push((stream, ticket));
                    return Ok(());
                }
                answer_ticket(mc, stream, &ticket);
                Ok(())
            });
        world.mc.on_rpc("device.open", |mc, rpc| {
            if mc.holding("device.open") {
                let rpc = rpc.clone();
                mc.defer(move |mc| open_device(mc, &rpc));
                return Ok(());
            }
            open_device(mc, rpc);
            Ok(())
        });
        world.mc.on_rpc("device.detail", |mc, rpc| {
            if mc.holding("device.detail") {
                let rpc = rpc.clone();
                mc.defer(move |mc| {
                    let detail = detail_of(mc.part::<FakeHub>(), &rpc);
                    mc.reply(&rpc, detail);
                });
                return Ok(());
            }
            let detail = detail_of(mc.part::<FakeHub>(), rpc);
            mc.reply(rpc, detail);
            Ok(())
        });
        world.mc.on_rpc("device.action", |mc, rpc| {
            if mc.holding("device.action") {
                let rpc = rpc.clone();
                mc.defer(move |mc| act(mc, &rpc));
                return Ok(());
            }
            act(mc, rpc);
            Ok(())
        });
        world.mc.on_rpc("device.close", |mc, rpc| {
            if mc.holding("device.close") {
                let rpc = rpc.clone();
                mc.defer(move |mc| close_device(mc, &rpc));
                return Ok(());
            }
            close_device(mc, rpc);
            Ok(())
        });
    }
    world.mc.part::<FakeHub>()
}

fn extension(mc: &mut FakeMc) {
    // The MC's device proxy, and the hub behind it.
    mc.on_raw("/api/device-hub/", |mc, stream, head| {
        proxy(mc, stream, head)
    });
}

fn devices_object(world: &World) -> Outcome<ObjectId> {
    world
        .with::<RightPanel, _>(|p, _| p.devices())?
        .ok_or_else(|| Failure("the panel has no Device tabs".into()))
}

/// The device tab the steps look at: the panel's active one, else any
/// device tab the panel has (DeviceSteps' shownTab).
fn shown_tab(world: &World) -> Outcome<ObjectId> {
    let devices = devices_object(world)?;
    let engine = world.engine();
    if let Some(tab) = ThreadDevices::tab(engine, devices, &active_tab(world)) {
        return Ok(tab);
    }
    ThreadDevices::read(engine, devices, |d| d.tabs())
        .unwrap_or_default()
        .iter()
        .find_map(|id| ThreadDevices::tab(engine, devices, id))
        .ok_or_else(|| Failure("the panel has no device tab".into()))
}

/// The shown device tab's stream.
fn stream_object(world: &World) -> Outcome<ObjectId> {
    DeviceTab::stream(world.engine(), shown_tab(world)?)
        .ok_or_else(|| Failure("the device tab has no stream".into()))
}

/// The shown device tab's device, or null.
fn screen_of(world: &World) -> Value {
    shown_tab(world).ok().map_or(Value::Null, |tab| {
        let screen = world.engine().read_by_name(tab, "screen");
        hal_c2_shell::json::from_value(world.engine(), &screen)
    })
}

fn view(world: &World) -> Value {
    devices_object(world)
        .ok()
        .and_then(|d| ThreadDevices::read(world.engine(), d, |d| d.view().clone()))
        .unwrap_or(Value::Null)
}

/// (status, detail, input connected, orientation) of the stream.
fn stream_of(world: &World) -> (String, String, bool, String) {
    stream_object(world)
        .ok()
        .and_then(|s| {
            DeviceStream::read(world.engine(), s, |c| {
                (
                    c.status().to_owned(),
                    c.detail().to_owned(),
                    c.input_connected(),
                    c.orientation().to_owned(),
                )
            })
        })
        .unwrap_or_default()
}

fn requests(world: &mut World) -> Vec<String> {
    fake_hub(world).shared.seen().requests.clone()
}

/// The video requests made for the device named `name`.
fn video_requests_of(world: &mut World, name: &str) -> Outcome<usize> {
    let device = device_named(fake_hub(world), name)?;
    let id = text(&device["id"]);
    Ok(requests(world)
        .iter()
        .filter(|r| (r.contains("/stream.avcc") || r.contains("/serve-emu/ws")) && r.contains(&id))
        .count())
}

/// Remembers each device's video requests, for "keeps its stream".
fn keep_streams(world: &mut World) -> Outcome {
    let names: Vec<String> = fake_hub(world)
        .devices
        .iter()
        .map(|d| text(&d["name"]))
        .collect();
    fake_hub(world).kept_counts.clear();
    for name in names {
        let count = video_requests_of(world, &name)?;
        fake_hub(world).kept_counts.insert(name, count);
    }
    Ok(())
}

/// The stream of the device named `name`: (status, input connected).
fn stream_named(world: &World, name: &str) -> (String, bool) {
    let Some(hub) = world.mc.peek::<FakeHub>() else {
        return (String::new(), false);
    };
    let Some(device) = hub.devices.iter().find(|d| text(&d["name"]) == name) else {
        return (String::new(), false);
    };
    let host = text(&device["hostId"]);
    let host = if host.is_empty() { HOST } else { &host };
    let tab = tab_id_of(host, &text(&device["id"]));
    let Ok(devices) = devices_object(world) else {
        return (String::new(), false);
    };
    ThreadDevices::stream(world.engine(), devices, &tab)
        .and_then(|stream| {
            hal_c2_shell::device::stream::DeviceStream::read(world.engine(), stream, |c| {
                (c.status().to_owned(), c.input_connected())
            })
        })
        .unwrap_or_default()
}

/// Both devices' tabs on the stage, in columns.
fn side_by_side(world: &mut World, left: &str, right: &str) -> Outcome {
    show_device_tab(world, left)?;
    show_device_tab(world, right)?;
    let left_tab = tab_of(world, left)?;
    let right_tab = tab_of(world, right)?;
    world.dispatch("rightPanel.dock", json!({"id": left_tab, "dock": "stage"}))?;
    world.dispatch(
        "rightPanel.dock",
        json!({"id": right_tab, "dock": "stage", "pane": 0, "zone": "right"}),
    )?;
    world.sync()?;
    world.wait_for_with(
        |w| {
            let panel = w.state("panel");
            let stage = at(&panel, "stage");
            text(&stage["layout"]) == "columns" && stage["panes"] == json!([left_tab, right_tab])
        },
        |w| show(&at(&w.state("panel"), "stage")),
    )
}

/// The 3D body's item, once the panel's loader has made it.
fn body_item(world: &World) -> Option<ObjectId> {
    let panel = world.peek_part::<Panel>().and_then(|p| p.0)?;
    let loader = panel.find(world, "deviceBodyLoader").ok().flatten()?;
    match panel.read(world, loader, "item") {
        QmlValue::Object(item) => Some(item),
        _ => None,
    }
}

fn show_in_3d(world: &mut World) -> Outcome {
    // The device's own tab first, when the Given only opened it.
    if screen_of(world).is_null() {
        let session = fake_hub(world).sessions.last().cloned();
        if let Some(session) = session {
            let name = fake_hub(world)
                .devices
                .iter()
                .find(|d| d["id"] == session["deviceId"])
                .map_or_else(String::new, |d| text(&d["name"]));
            if !name.is_empty() {
                show_device_tab(world, &name)?;
            }
        }
    }
    let panel = device_panel(world)?;
    let showing = panel
        .root(world)
        .is_some_and(|root| panel.flag(world, root, "show3d"));
    if !showing {
        panel.click(world, "device3dToggle")?;
    }
    world.wait_for_with(|w| body_item(w).is_some(), describe_ref)
}

/// The input connections drop with `reason`, and new ones are closed at
/// once until the connection returns.
fn drop_input(world: &mut World, reason: &str) {
    let hub = fake_hub(world);
    hub.drop_inputs = true;
    for input in &hub.inputs {
        let _ = input
            .out
            .send(Message::Close(Some(tungstenite::protocol::CloseFrame {
                code: tungstenite::protocol::frame::coding::CloseCode::Normal,
                reason: reason.to_owned().into(),
            })));
    }
    hub.inputs.clear();
}

fn both_stream(world: &mut World, one: &str, other: &str) -> Outcome {
    let (one, other) = (one.to_owned(), other.to_owned());
    world.wait_for_with(
        move |w| stream_named(w, &one).0 == "streaming" && stream_named(w, &other).0 == "streaming",
        describe_ref,
    )
}

fn describe(world: &mut World) -> String {
    let (status, detail, input, _) = stream_of(world);
    let panel = world.state("panel");
    let seen = requests(world).join(", ");
    format!(
        "the panel is {}; the Device view is {}; the stream is {status} ({detail}), input {}; the hub saw {seen}",
        show(&panel),
        show(&view(world)),
        if input { "connected" } else { "closed" },
    )
}

fn add_device(world: &mut World, platform: &str, name: &str, booted: bool) {
    add_device_on(world, platform, name, booted, HOST, "");
}

fn add_device_on(
    world: &mut World,
    platform: &str,
    name: &str,
    booted: bool,
    host: &str,
    wanted_id: &str,
) {
    let id = if !wanted_id.is_empty() {
        wanted_id.to_owned()
    } else if platform == "ios" {
        format!(
            "UDID-{}{}",
            name.replace(' ', "-").to_uppercase(),
            if host == HOST {
                String::new()
            } else {
                format!("-{}", host.to_uppercase())
            }
        )
    } else {
        "emulator-5554".to_owned()
    };
    fake_hub(world).devices.push(json!({
        "hostId": host,
        "id": id,
        "name": name,
        "platform": platform,
        "version": if platform == "ios" { "iOS 26.0" } else { "Android 16" },
        "booted": booted,
        "physical": false,
    }));
}

/// The Device tab as the desktop draws it, over the right panel's ThreadDevices.
fn device_panel(world: &mut World) -> Outcome<Brick> {
    if let Some(brick) = world.part::<Panel>().0 {
        return Ok(brick);
    }
    // The body of the tab the panel shows, as RightPanel gives it.
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nimport HalC2.Shell\n\
         DevicePanel { anchors.fill: parent; tabId: Shell.state.panel?.floatingDevice ?? Shell.state.panel?.activeId ?? \"\" }\n",
        420.0,
        900.0,
    )?;
    let Some(root) = brick.root(world) else {
        fail!("the Device tab did not load");
    };
    let source = devices_object(world)?;
    brick.write(world, root, "source", QmlValue::Object(source))?;
    world.part::<Panel>().0 = Some(brick);
    Ok(brick)
}

/// The user looks at thread-1, whose environment's devices the shell follows.
fn look(world: &mut World) -> Outcome {
    if fake_hub(world).looking {
        return Ok(());
    }
    fake_hub(world).looking = true;
    world.mc.projects.insert(
        PROJECT.into(),
        json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": format!("/work/{PROJECT}"), "scripts": []}),
    );
    world.connect()?;
    world.sync()?;
    look_at_thread(world, PROJECT)?;
    ThreadDevices::set_timeouts(
        world.engine(),
        devices_object(world)?,
        FIRST_FRAME_MS,
        RETRY_MS,
    );
    device_panel(world)?;
    world.wait_for_with(|w| view(w)["loaded"] == true, describe_ref)
}

/// [`describe`] for a wait, which holds the world only to read it.
fn describe_ref(world: &World) -> String {
    let (status, detail, input, _) = stream_of(world);
    format!(
        "the panel is {}; the Device view is {}; the stream is {status} ({detail}), input {}",
        show(&world.state("panel")),
        show(&view(world)),
        if input { "connected" } else { "closed" },
    )
}

fn active_tab(world: &World) -> String {
    text(at(&world.state("panel"), "activeId"))
}

fn tab_titles(world: &World) -> Vec<String> {
    world.state("panel")["tabs"]
        .as_array()
        .map(|tabs| tabs.iter().map(|t| text(&t["title"])).collect())
        .unwrap_or_default()
}

fn tab_of(world: &mut World, name: &str) -> Outcome<String> {
    let device = device_named(fake_hub(world), name)?;
    Ok(tab_id_of(HOST, &text(&device["id"])))
}

fn add_device_tab(world: &mut World) -> Outcome {
    look(world)?;
    world.dispatch("rightPanel.add", json!({"kind": "device"}))?;
    world.sync()?;
    world.wait_for_with(
        |w| active_tab(w) == "device" && view(w)["loaded"] == true,
        describe_ref,
    )
}

/// The picker's row for the device named `name`, in the group titled `group`
/// (any when empty); null when there is none.
fn row_of(world: &World, name: &str, group: &str) -> Value {
    for listed in view(world)["groups"].as_array().into_iter().flatten() {
        if !group.is_empty() && text(&listed["title"]) != group {
            continue;
        }
        for row in listed["devices"].as_array().into_iter().flatten() {
            if text(&row["name"]) == name {
                return row.clone();
            }
        }
    }
    Value::Null
}

fn open_from_picker(world: &mut World, name: &str) -> Outcome {
    let wanted = name.to_owned();
    world.wait_for_with(|w| !row_of(w, &wanted, "").is_null(), describe_ref)?;
    let row = format!("deviceRow-{}", text(&row_of(world, name, "")["tab"]));
    let panel = device_panel(world)?;
    world.wait_for_with(
        |w| {
            panel.find(w, &row).ok().flatten().is_some_and(|item| {
                panel.flag(w, item, "visible") && panel.flag(w, item, "enabled")
            })
        },
        describe_ref,
    )?;
    panel.click(world, &row)?;
    world.sync()
}

/// The user shows the device's tab: activates it, or opens the device from
/// the picker when the panel has no tab for it yet.
fn show_device_tab(world: &mut World, name: &str) -> Outcome {
    look(world)?;
    let tab = tab_of(world, name)?;
    if tab_titles(world).iter().any(|t| t == name) {
        world.dispatch("rightPanel.activate", json!({"id": tab}))?;
    } else {
        add_device_tab(world)?;
        open_from_picker(world, name)?;
    }
    world.sync()?;
    world.wait_for_with(|w| active_tab(w) == tab, describe_ref)
}

fn screen_item(world: &mut World) -> Outcome<ObjectId> {
    device_panel(world)?.item(world, "deviceScreen")
}

fn red(colour: [u8; 4]) -> bool {
    colour[0] > 160 && colour[1] < 90 && colour[2] < 90
}

/// The colour the window shows at the middle of the device's picture; none
/// before one was painted.
fn drawn_at_screen(world: &World, screen: ObjectId) -> Option<[u8; 4]> {
    for op in world.painted_ops(screen) {
        if let DrawOp::Image { image, .. } = op {
            let (width, height) = (image.width() as usize, image.height() as usize);
            let data = image.data();
            let at = ((height / 2) * width + width / 2) * 4;
            return data.get(at..at + 4).map(|p| [p[0], p[1], p[2], p[3]]);
        }
    }
    None
}

fn drawn_red(world: &World, screen: ObjectId) -> bool {
    drawn_at_screen(world, screen).is_some_and(red)
}

fn describe_screen(world: &mut World) -> String {
    let base = describe(world);
    let Ok(panel) = device_panel(world) else {
        return base;
    };
    let Ok(screen) = panel.item(world, "deviceScreen") else {
        return base;
    };
    format!(
        "{base}; the screen item has a picture: {}, shown {}, colour {:?}",
        panel.flag(world, screen, "hasFrame"),
        panel.flag(world, screen, "visible"),
        drawn_at_screen(world, screen),
    )
}

/// The tab drew the fixture's red screen: DeviceScreen took the picture the
/// stream announced and the window shows it.
fn wait_for_screen(world: &mut World, name: &str) -> Outcome {
    let tab = tab_of(world, name)?;
    let screen = screen_item(world)?;
    let panel = device_panel(world)?;
    let title = name.to_owned();
    world.wait_for_with(
        |w| {
            active_tab(w) == tab
                && tab_titles(w).contains(&title)
                && stream_of(w).0 == "streaming"
                && panel.flag(w, screen, "hasFrame")
                && panel.flag(w, screen, "visible")
        },
        |w| describe_ref(w).to_string(),
    )?;
    expect!(drawn_red(world, screen), "{}", describe_screen(world));
    Ok(())
}

fn watch(world: &mut World, name: &str) -> Outcome {
    show_device_tab(world, name)?;
    wait_for_screen(world, name)?;
    world.wait_for_with(|w| stream_of(w).2, describe_ref)
}

/// serve-sim's input messages of `tag`, as JSON.
fn ios_input(world: &mut World, tag: u8) -> Vec<Value> {
    fake_hub(world)
        .shared
        .seen()
        .binary
        .iter()
        .filter(|m| m.first() == Some(&tag))
        .map(|m| serde_json::from_slice(&m[1..]).unwrap_or(Value::Null))
        .collect()
}

fn emu_input(world: &mut World) -> Vec<Value> {
    fake_hub(world).shared.seen().text.clone()
}

fn describe_input(world: &mut World) -> String {
    let hub = fake_hub(world);
    let seen = hub.shared.seen();
    let mut received: Vec<String> = seen
        .binary
        .iter()
        .map(|m| {
            format!(
                "{} {}",
                m.first().copied().unwrap_or(0),
                String::from_utf8_lossy(m.get(1..).unwrap_or_default())
            )
        })
        .collect();
    received.extend(seen.text.iter().map(Value::to_string));
    format!("the device received {}", received.join(", "))
}

fn stream_closed(world: &mut World) -> bool {
    let hub = fake_hub(world);
    let open = hub.videos.iter().any(connected)
        || hub
            .inputs
            .iter()
            .any(|input| !input.closed.load(Ordering::SeqCst));
    // A closed tab has no stream left to be anything but idle.
    !open && matches!(stream_of(world).0.as_str(), "idle" | "")
}

fn video_requests(world: &mut World) -> usize {
    requests(world)
        .iter()
        .filter(|r| r.contains("/stream.avcc") || r.contains("/serve-emu/ws"))
        .count()
}

/// A click on the screen at (fx, fy) of it as shown.
fn tap(world: &mut World, fx: f64, fy: f64) -> Outcome {
    let panel = device_panel(world)?;
    let touch = panel.item(world, "deviceTouch")?;
    let (x, y) = panel.at(world, touch, fx, fy)?;
    world.click_at(x, y)
}

/// A key typed on the screen, which has the keyboard once the user tapped it.
fn press(world: &mut World, spelt: &str) -> Outcome {
    let panel = device_panel(world)?;
    let stage = panel.item(world, "deviceStage")?;
    expect!(
        panel.flag(world, stage, "activeFocus"),
        "the device's screen does not have the keyboard"
    );
    let down = key_event(spelt)?;
    let up = KeyEvent::release(down.key).with_modifiers(down.modifiers);
    world.key(&down)?;
    world.key(&up)?;
    Ok(())
}

/// Within a pixel of the screen as shown: clicks land on whole pixels.
fn near(value: &Value, wanted: f64) -> bool {
    value.as_f64().is_some_and(|v| (v - wanted).abs() < 0.01)
}

fn open_video(hub: &FakeHub) -> Option<TcpStream> {
    hub.videos
        .iter()
        .find(|v| connected(v))
        .and_then(|v| v.try_clone().ok())
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);
    register_setup(steps);
    register_tools(steps);

    // The environment's devices.
    steps.step(
        &format!(
            "the thread's environment has an (iOS Simulator|Android Emulator) {Q} (running|stopped)"
        ),
        |world, c, _| {
            let platform = if c[0] == "iOS Simulator" {
                "ios"
            } else {
                "android"
            };
            add_device(world, platform, &c[1], c[2] == "running");
            Ok(())
        },
    );
    steps.step("a simulator is booted", |world, _, _| {
        add_device(world, "ios", "iPhone 17", true);
        Ok(())
    });
    steps.step(
        "the thread's environment has no simulators or emulators",
        |world, _, _| {
            fake_hub(world);
            Ok(())
        },
    );
    steps.step(
        "device support is off on the thread's environment",
        |world, _, _| {
            fake_hub(world).host_status = "disabled".into();
            Ok(())
        },
    );
    steps.step(
        &format!("the thread has the (iOS Simulator|Android Emulator) {Q} open"),
        |world, c, _| {
            let platform = if c[0] == "iOS Simulator" {
                "ios"
            } else {
                "android"
            };
            add_device(world, platform, &c[1], true);
            let device = device_named(fake_hub(world), &c[1])?;
            open_session(&mut world.mc, &device, THREAD);
            Ok(())
        },
    );
    steps.step(
        &format!("the MC cannot open devices because {Q}"),
        |world, c, _| {
            fake_hub(world).refuse_open = c[0].clone();
            Ok(())
        },
    );
    steps.step("the MC refuses the device stream", |world, _, _| {
        fake_hub(world).refuse = 401;
        Ok(())
    });
    steps.step("the device sends no picture yet", |world, _, _| {
        fake_hub(world).shared.silent.store(true, Ordering::SeqCst);
        Ok(())
    });
    steps.step("FFmpeg is not installed", |world, _, _| {
        fake_hub(world).no_ffmpeg = true;
        decoder::pretend_missing(true);
        Ok(())
    });
    steps.step(
        "the tab says to install FFmpeg to watch device screens",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let (status, detail, ..) = stream_of(w);
                    status == "error"
                        && detail.starts_with("Install FFmpeg to watch device screens")
                },
                describe_ref,
            )
        },
    );
    steps.step(
        "the device sends video the desktop cannot decode",
        |world, _, _| {
            fake_hub(world).undecodable = true;
            Ok(())
        },
    );
    steps.step(
        "the tab asked for the device's video (\\d+) times",
        |world, c, _| {
            world.sync()?;
            let wanted: usize = c[0].parse().unwrap_or(0);
            expect!(video_requests(world) == wanted, "{}", describe(world));
            Ok(())
        },
    );
    steps.step("the device starts sending pictures", |world, _, _| {
        let hub = fake_hub(world);
        hub.shared.silent.store(false, Ordering::SeqCst);
        send_video(hub);
        Ok(())
    });
    steps.step("the device sends its video in pieces", |world, _, _| {
        world.wait_for_with(open_video_in, describe_ref)?;
        let Some(mut video) = open_video(fake_hub(world)) else {
            fail!("{}", describe(world));
        };
        // Every envelope in three pieces: half its length, then the rest of its
        // header and half its payload, then the rest. A round trip through the
        // MC between pieces lets the desktop read each one on its own.
        let body = device_fixture::ios_video(false);
        let mut cuts = Vec::new();
        let mut at = 0;
        while at < body.len() {
            let length =
                u32::from_be_bytes([body[at], body[at + 1], body[at + 2], body[at + 3]]) as usize;
            cuts.push(at + 2);
            cuts.push(at + 4 + length / 2);
            at += 4 + length;
        }
        cuts.push(body.len());
        let mut from = 0;
        for cut in cuts {
            let _ = video.write_all(&body[from..cut]);
            let _ = video.flush();
            world.sync()?;
            from = cut;
        }
        Ok(())
    });
    steps.step("the user is looking at the thread", |world, _, _| {
        look(world)
    });

    // Choosing.
    steps.step("the user adds a Device tab", |world, _, _| {
        add_device_tab(world)
    });
    steps.step("the user adds a device tab for it", |world, _, _| {
        add_device_tab(world)?;
        open_from_picker(world, "iPhone 17")
    });
    steps.step(
        &format!("{Q} is offered under {Q}( to start)?"),
        |world, c, _| {
            let action = if c.get(2).is_some_and(|s| !s.is_empty()) {
                "Start"
            } else {
                "Open"
            };
            let (name, group) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                |w| row_of(w, &name, &group)["action"] == action,
                describe_ref,
            )
        },
    );
    steps.step(
        &format!("the user opens {Q} from the Device tab"),
        |world, c, _| open_from_picker(world, &c[0]),
    );
    steps.step(&format!("the thread has {Q} open"), |world, c, _| {
        let id = text(&device_named(fake_hub(world), &c[0])?["id"]);
        let opened = session_of(fake_hub(world), &id, THREAD).is_some();
        expect!(opened, "{}", describe(world));
        let tab = tab_of(world, &c[0])?;
        world.wait_for_with(
            |w| active_tab(w) == tab && !tab_titles(w).contains(&"Device".to_owned()),
            describe_ref,
        )
    });
    steps.step(&format!("the tab says {Q}"), |world, c, _| {
        let wanted = c[0].clone();
        world.wait_for_with(
            |w| {
                // desktop-qt's tabSays: the view's own words, or any the
                // panel renders, or the stream's error.
                let shown = view(w);
                let (status, detail, ..) = stream_of(w);
                let banners = shown["banners"].as_array().cloned().unwrap_or_default();
                let wizard = &shown["wizard"];
                ["loading", "empty", "error", "hostDetail", "starting"]
                    .iter()
                    .any(|field| text(&shown[field]) == wanted)
                    || banners.iter().any(|banner| {
                        text(&banner["message"]) == wanted || text(&banner["advice"]) == wanted
                    })
                    || (wizard.is_object()
                        && ["hubStatus", "agentStatus", "error"]
                            .iter()
                            .any(|field| text(&wizard[field]) == wanted))
                    || (status == "error" && detail == wanted)
                    || device_panel_shows(w, &wanted)
            },
            describe_ref,
        )
    });
    steps.step("the user dismisses the error", |world, _, _| {
        // Or the thread's, when the scenario showed one (RunNotices.h).
        if super::run_notice::dismiss_thread_error(world)? {
            return Ok(());
        }
        let panel = device_panel(world)?;
        panel.click(world, "deviceDismissError")
    });
    steps.step("the tab shows no error", |world, _, _| {
        expect!(
            text(&view(world)["error"]).is_empty(),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the tab points to the Integrations settings",
        |world, _, _| world.wait_for_with(|w| view(w)["setup"] == true, describe_ref),
    );
    steps.step("the user follows the tab to its settings", |world, _, _| {
        world.wait_for_with(|w| view(w)["setup"] == true, describe_ref)?;
        let panel = device_panel(world)?;
        // The setup wizard sits in front of the tab; putting it away leaves
        // the tab's own pointer to the settings.
        if !view(world)["wizard"].is_null() {
            panel.click(world, "wizardCancel")?;
            world.sync()?;
        }
        panel.click(world, "deviceOpenSettings")?;
        world.sync()
    });

    // Watching.
    steps.step(&format!("the user shows the {Q} tab"), |world, c, _| {
        show_device_tab(world, &c[0])
    });
    steps.step(
        &format!("the user is watching the {Q} tab"),
        |world, c, _| watch(world, &c[0]),
    );
    steps.step(
        &format!("the tab {Q} shows the device's screen"),
        |world, c, _| wait_for_screen(world, &c[0]),
    );
    steps.step("the tab streams the simulator's screen", |world, _, _| {
        wait_for_screen(world, "iPhone 17")
    });
    steps.step(
        "the screen came through the MC's device proxy",
        |world, _, _| {
            let id = text(&device_named(fake_hub(world), "iPhone 17")?["id"]);
            // The MC's name is encoded once: `hal-c2%40studio`.
            let wanted = format!(
                "/api/device-hub/mcs/{}/vendor/serve-sim/helper/{id}/stream.avcc Bearer mc-token",
                hal_c2_shell::device::percent(&world.mc.name)
            );
            expect!(requests(world).contains(&wanted), "{}", describe(world));
            Ok(())
        },
    );
    steps.step(
        "the tab says it is connecting to the device",
        |world, _, _| {
            world.sync()?;
            let panel = device_panel(world)?;
            let status = panel.item(world, "deviceStatus")?;
            expect!(
                stream_of(world).0 == "connecting"
                    && !screen_of(world).is_null()
                    && panel.flag(world, status, "visible"),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the tab shows no picture", |world, _, _| {
        world.sync()?;
        let panel = device_panel(world)?;
        let screen = screen_item(world)?;
        expect!(
            !panel.flag(world, screen, "hasFrame")
                && !panel.flag(world, screen, "visible")
                && !drawn_red(world, screen),
            "{}",
            describe_screen(world)
        );
        Ok(())
    });
    steps.step("no picture comes in time", |world, _, _| {
        let stream = stream_object(world)?;
        DeviceStream::set_timeouts(world.engine(), stream, 1, RETRY_MS);
        world.wait_for_with(|w| stream_of(w).0 == "error", describe_ref)?;
        DeviceStream::set_timeouts(world.engine(), stream, FIRST_FRAME_MS, RETRY_MS);
        Ok(())
    });
    steps.step("the user reconnects", |world, _, _| {
        let panel = device_panel(world)?;
        panel.click(world, "deviceReconnect")
    });
    steps.step("the device's stream ends", |world, _, _| {
        let hub = fake_hub(world);
        hub.shared.seen().requests.push("-- ended --".into());
        for video in &hub.videos {
            let _ = video.shutdown(Shutdown::Both);
        }
        Ok(())
    });
    steps.step("the tab connects to the device again", |world, _, _| {
        world.wait_for_with(
            |w| {
                let seen =
                    w.mc.peek::<FakeHub>()
                        .map(|h| h.shared.seen().requests.clone())
                        .unwrap_or_default();
                let Some(ended) = seen.iter().position(|r| r == "-- ended --") else {
                    return false;
                };
                seen[ended + 1..].iter().any(|r| r.contains("/stream.avcc"))
            },
            describe_ref,
        )
    });
    steps.step("the emulator's video restarts", |world, _, _| {
        let hub = fake_hub(world);
        hub.shared.seen().text.clear();
        for input in &hub.inputs {
            let _ = input.out.send(Message::text(r#"{"type":"video-session"}"#));
        }
        Ok(())
    });
    steps.step("the device is asked for a fresh keyframe", |world, _, _| {
        world.wait_for_with(
            |w| {
                w.mc.peek::<FakeHub>().is_some_and(|h| {
                    h.shared
                        .seen()
                        .text
                        .iter()
                        .any(|m| m["type"] == "reset-video")
                })
            },
            |_| "the device to be asked for a keyframe".into(),
        )?;
        Ok(())
    });
    steps.step("no device stream is open", |world, _, _| {
        world.wait_for_with(
            |w| {
                let hub = w.mc.peek::<FakeHub>();
                hub.is_none_or(|h| {
                    !h.videos.iter().any(connected)
                        && !h.inputs.iter().any(|i| !i.closed.load(Ordering::SeqCst))
                }) && matches!(stream_of(w).0.as_str(), "idle" | "")
            },
            describe_ref,
        )?;
        let asked = video_requests(world);
        world.sync()?;
        expect!(video_requests(world) == asked, "{}", describe(world));
        Ok(())
    });

    // Driving.
    steps.step("the user taps the middle of the screen", |world, _, _| {
        tap(world, 0.5, 0.5)
    });
    steps.step(
        "the user taps the left middle of the screen",
        |world, _, _| {
            fake_hub(world).shared.seen().binary.clear();
            tap(world, 0.25, 0.5)
        },
    );
    steps.step(
        &format!("the user types {Q} on the device"),
        |world, c, _| {
            let first: String = c[0].chars().take(1).collect();
            press(world, &first)
        },
    );
    steps.step(
        "the user presses the device's (Home|Recents) button",
        |world, c, _| {
            let panel = device_panel(world)?;
            panel.click(world, &format!("device{}", c[0]))
        },
    );
    steps.step("the user presses Escape on the device", |world, _, _| {
        press(world, "escape")
    });
    steps.step(
        "the user drags from the middle of the screen to its left middle and the touch is taken away",
        |world, _, _| {
            fake_hub(world).shared.seen().binary.clear();
            let panel = device_panel(world)?;
            let touch = panel.item(world, "deviceTouch")?;
            let (x, y) = panel.at(world, touch, 0.5, 0.5)?;
            let (left, _) = panel.at(world, touch, 0.25, 0.5)?;
            world.pointer(|now| PointerEvent::press(x, y, now))?;
            world.pointer(|now| PointerEvent::moved(left, y, Default::default(), now))?;
            // What a popup or another item taking the mouse mid-drag does.
            world.pointer(PointerEvent::cancel)?;
            world.pointer(|now| PointerEvent::release(left, y, now))?;
            Ok(())
        },
    );
    steps.step(
        "the device receives a touch that ends at the left middle",
        |world, _, _| {
            world
                .wait_for_with(
                    |w| {
                        let Some(hub) = w.mc.peek::<FakeHub>() else {
                            return false;
                        };
                        let touches: Vec<Value> = hub
                            .shared
                            .seen()
                            .binary
                            .iter()
                            .filter(|m| m.first() == Some(&0x03))
                            .map(|m| serde_json::from_slice(&m[1..]).unwrap_or(Value::Null))
                            .collect();
                        let ends = touches.iter().filter(|t| t["type"] == "end").count();
                        touches.last().is_some_and(|last| {
                            ends == 1
                                && last["type"] == "end"
                                && near(&last["x"], 0.25)
                                && near(&last["y"], 0.5)
                        })
                    },
                    |_| "the device to receive a touch that ends at the left middle".into(),
                )
                .map_err(|f| Failure(format!("{}; {}", f.0, describe_input(world))))
        },
    );
    steps.step(
        "the device receives a touch that begins and ends at the middle",
        |world, _, _| {
            world
                .wait_for_with(
                    |w| {
                        let Some(hub) = w.mc.peek::<FakeHub>() else {
                            return false;
                        };
                        let touches: Vec<Value> = hub
                            .shared
                            .seen()
                            .binary
                            .iter()
                            .filter(|m| m.first() == Some(&0x03))
                            .map(|m| serde_json::from_slice(&m[1..]).unwrap_or(Value::Null))
                            .collect();
                        touches.len() == 2
                            && touches[0]["type"] == "begin"
                            && touches[1]["type"] == "end"
                            && near(&touches[1]["x"], 0.5)
                            && near(&touches[1]["y"], 0.5)
                    },
                    |_| "the device to receive a touch that begins and ends at the middle".into(),
                )
                .map_err(|f| Failure(format!("{}; {}", f.0, describe_input(world))))
        },
    );
    steps.step(
        &format!("the device receives the key {Q} going down and up"),
        |world, c, _| {
            let letter = c[0].chars().next().unwrap_or('a').to_ascii_lowercase();
            let usage = 0x04 + (letter as i64 - 'a' as i64);
            let (down, up) = (
                json!({"type": "down", "usage": usage}),
                json!({"type": "up", "usage": usage}),
            );
            world
                .wait_for_with(
                    |w| {
                        let Some(hub) = w.mc.peek::<FakeHub>() else {
                            return false;
                        };
                        let keys: Vec<Value> = hub
                            .shared
                            .seen()
                            .binary
                            .iter()
                            .filter(|m| m.first() == Some(&0x06))
                            .map(|m| serde_json::from_slice(&m[1..]).unwrap_or(Value::Null))
                            .collect();
                        keys == [down.clone(), up.clone()]
                    },
                    |_| "the device to receive the key going down and up".into(),
                )
                .map_err(|f| Failure(format!("{}; {}", f.0, describe_input(world))))
        },
    );
    steps.step(
        &format!("the device receives the {Q} button"),
        |world, c, _| {
            let wanted = vec![json!({"button": c[0]})];
            world
                .wait_for_with(
                    |w| tagged(w, 0x04) == wanted,
                    |_| "the device to receive the button".into(),
                )
                .map_err(|f| Failure(format!("{}; {}", f.0, describe_input(world))))
        },
    );
    steps.step(
        "the emulator receives a touch down and up at the middle",
        |world, _, _| {
            let touch_at = |received: &[Value], action: &str| {
                received.iter().position(|m| {
                    m["type"] == "touch"
                        && m["action"] == action
                        && near(&m["x"], 0.5)
                        && near(&m["y"], 0.5)
                })
            };
            world
                .wait_for_with(
                    |w| {
                        let Some(hub) = w.mc.peek::<FakeHub>() else {
                            return false;
                        };
                        let received = hub.shared.seen().text.clone();
                        match (touch_at(&received, "down"), touch_at(&received, "up")) {
                            (Some(down), Some(up)) => up > down,
                            _ => false,
                        }
                    },
                    |_| "the emulator to receive a touch down and up".into(),
                )
                .map_err(|f| Failure(format!("{}; {}", f.0, describe_input(world))))
        },
    );
    steps.step(
        &format!("the emulator receives the text {Q}"),
        |world, c, _| {
            let wanted = json!({"type": "text", "text": c[0]});
            world
                .wait_for_with(
                    |w| {
                        w.mc.peek::<FakeHub>()
                            .is_some_and(|h| h.shared.seen().text.contains(&wanted))
                    },
                    |_| "the emulator to receive the text".into(),
                )
                .map_err(|f| Failure(format!("{}; {}", f.0, describe_input(world))))
        },
    );
    steps.step(
        &format!("the emulator receives the {Q} button"),
        |world, c, _| {
            let wanted = json!({"type": c[0]});
            world
                .wait_for_with(
                    |w| {
                        w.mc.peek::<FakeHub>()
                            .is_some_and(|h| h.shared.seen().text.contains(&wanted))
                    },
                    |_| "the emulator to receive the button".into(),
                )
                .map_err(|f| Failure(format!("{}; {}", f.0, describe_input(world))))
        },
    );
    steps.step("the user rotates the device", |world, _, _| {
        let panel = device_panel(world)?;
        panel.click(world, "deviceRotate")
    });
    steps.step(
        &format!("the device is asked to turn to {Q}"),
        |world, c, _| {
            let wanted = vec![json!({"orientation": c[0]})];
            world
                .wait_for_with(
                    |w| tagged(w, 0x07) == wanted,
                    |_| "the device to be asked to turn".into(),
                )
                .map_err(|f| Failure(format!("{}; {}", f.0, describe_input(world))))
        },
    );
    steps.step(
        &format!("the device reports it is held {Q}"),
        |world, c, _| {
            // serve-sim's framebuffer stays portrait as the device turns.
            let mut config = vec![0x82u8];
            config.extend(
                json!({"width": 1179, "height": 2556, "orientation": c[0]})
                    .to_string()
                    .into_bytes(),
            );
            for input in &fake_hub(world).inputs {
                let _ = input.out.send(Message::binary(config.clone()));
            }
            Ok(())
        },
    );
    steps.step(
        "the screen is shown sideways and wider than tall",
        |world, _, _| {
            let panel = device_panel(world)?;
            let screen = screen_item(world)?;
            let number =
                |w: &World, name: &str| panel.read(w, screen, name).as_number().unwrap_or(0.0);
            // The item's box turned by its rotation, as the window shows it.
            let shown = move |w: &World| {
                let (width, height) = (number(w, "width"), number(w, "height"));
                if number(w, "rotation").abs().round() as i32 == 90 {
                    (height, width)
                } else {
                    (width, height)
                }
            };
            world.wait_for_with(
                move |w| {
                    number(w, "rotation").round() as i32 == 90 && {
                        let (width, height) = shown(w);
                        width > height
                    }
                },
                move |w| {
                    let (width, height) = shown(w);
                    format!(
                        "the stream is {}; the screen is turned {} and drawn {width}x{height}",
                        stream_of(w).3,
                        number(w, "rotation"),
                    )
                },
            )?;
            expect!(drawn_red(world, screen), "{}", describe_screen(world));
            Ok(())
        },
    );
    steps.step(
        "the device receives the touch where it lands on its own portrait screen",
        |world, _, _| {
            world
                .wait_for_with(
                    |w| {
                        let touches = tagged(w, 0x03);
                        touches.len() == 2
                            && near(&touches[0]["x"], 0.5)
                            && near(&touches[0]["y"], 0.75)
                    },
                    |_| "the device to receive the touch on its portrait screen".into(),
                )
                .map_err(|f| Failure(format!("{}; {}", f.0, describe_input(world))))
        },
    );

    // Closing.
    steps.step(&format!("the thread still has {Q} open"), |world, c, _| {
        let id = text(&device_named(fake_hub(world), &c[0])?["id"]);
        let hub = fake_hub(world);
        let open = hub.closes.is_empty() && session_of(hub, &id, THREAD).is_some();
        expect!(open, "{}", describe(world));
        Ok(())
    });
    steps.step("the user powers the device off", |world, _, _| {
        let panel = device_panel(world)?;
        panel.click(world, "devicePowerOff")
    });
    steps.step(
        &format!("the MC is asked to close {Q} and shut it down"),
        |world, c, _| {
            let id = text(&device_named(fake_hub(world), &c[0])?["id"]);
            world.wait_for_with(
                |w| {
                    let Some(hub) = w.mc.peek::<FakeHub>() else {
                        return false;
                    };
                    hub.closes.len() == 1
                        && text(&hub.closes[0]["deviceId"]) == id
                        && text(&hub.closes[0]["threadId"]) == THREAD
                        && hub.closes[0]["shutdown"] == true
                },
                describe_ref,
            )
        },
    );
    steps.step("the MC is slow to close devices", |world, _, _| {
        fake_hub(world);
        world.mc.hold("device.close");
        Ok(())
    });
    steps.step(
        &format!("before the MC answers, the user switches to another thread showing {Q}"),
        |world, c, _| {
            world.sync()?;
            let slow = world.mc.holding("device.close") && fake_hub(world).closes.is_empty();
            expect!(slow, "{}", describe(world));
            let other = "thread-2";
            let row = json!({"id": other, "title": "Other", "projectId": PROJECT,
                             "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
            world.mc.threads.insert(other.into(), row.clone());
            world.mc.send_row(other, &row);
            world.sync()?;
            let key = format!("{}:{other}", world.mc.environment_id);
            look_stream(world, &key, true)?;
            world.sync()?;
            // An agent opened the same device there: that thread has its own tab for it.
            let device = device_named(fake_hub(world), &c[0])?;
            open_session(&mut world.mc, &device, other);
            announce(&mut world.mc);
            world.sync()?;
            let tab = tab_of(world, &c[0])?;
            world.wait_for_with(|w| active_tab(w) == tab, describe_ref)
        },
    );
    steps.step("the user goes back to the first thread", |world, _, _| {
        let key = format!("{}:{THREAD}", world.mc.environment_id);
        look_stream(world, &key, true)?;
        world.sync()
    });
    steps.step(&format!("the right panel has no {Q} tab"), |world, c, _| {
        world.sync()?;
        let title = c[0].clone();
        world.wait_for_with(|w| !tab_titles(w).contains(&title), describe_ref)
    });

    // An agent's devices.
    steps.step(
        &format!("an agent (?:opens|opened) {Q} in the thread"),
        |world, c, _| {
            let device = device_named(fake_hub(world), &c[0])?;
            open_session(&mut world.mc, &device, THREAD);
            announce(&mut world.mc);
            world.sync()?;
            let tab = tab_of(world, &c[0])?;
            world.wait_for_with(|w| active_tab(w) == tab, describe_ref)
        },
    );
    steps.step(
        &format!("the agent closes {Q} and opens it again"),
        |world, c, _| {
            let device = device_named(fake_hub(world), &c[0])?;
            let hub = fake_hub(world);
            if let Some(at) = session_of(hub, &text(&device["id"]), THREAD) {
                hub.sessions.remove(at);
            }
            announce(&mut world.mc);
            world.sync()?;
            open_session(&mut world.mc, &device, THREAD);
            announce(&mut world.mc);
            world.sync()
        },
    );
    steps.step(
        &format!("the right panel shows the {Q} tab"),
        |world, c, _| {
            let tab = tab_of(world, &c[0])?;
            let title = c[0].clone();
            world.wait_for_with(
                move |w| {
                    active_tab(w) == tab
                        && tab_titles(w).contains(&title)
                        && w.with::<RightPanel, _>(|p, _| p.is_open()).unwrap_or(false)
                },
                describe_ref,
            )
        },
    );
}

/// serve-sim's input messages of `tag` the device received, as JSON.
fn tagged(world: &World, tag: u8) -> Vec<Value> {
    world
        .mc
        .peek::<FakeHub>()
        .map(|hub| {
            hub.shared
                .seen()
                .binary
                .iter()
                .filter(|m| m.first() == Some(&tag))
                .map(|m| serde_json::from_slice(&m[1..]).unwrap_or(Value::Null))
                .collect()
        })
        .unwrap_or_default()
}

/// Whether a video socket of the hub is open.
fn open_video_in(world: &World) -> bool {
    world
        .mc
        .peek::<FakeHub>()
        .is_some_and(|hub| hub.videos.iter().any(connected))
}

fn wizard_view(world: &World) -> Value {
    view(world)["wizard"].clone()
}

fn wizard_step(world: &World) -> i64 {
    let Some(brick) = world.peek_part::<Panel>().and_then(|p| p.0) else {
        return -1;
    };
    let Ok(wizard) = brick.item(world, "deviceWizard") else {
        return -1;
    };
    match brick.read(world, wizard, "step") {
        QmlValue::Int(n) => i64::from(n),
        QmlValue::Real(n) => n as i64,
        _ => -1,
    }
}

/// Waits for the wizard, then puts it at `step` as a user who got there.
fn open_wizard(world: &mut World, step: i32) -> Outcome {
    world.wait_for_with(|w| !wizard_view(w).is_null(), describe_ref)?;
    if step > 0 {
        let panel = device_panel(world)?;
        let wizard = panel.item(world, "deviceWizard")?;
        panel.write(world, wizard, "step", QmlValue::Int(step))?;
        panel.write(world, wizard, "furthest", QmlValue::Int(step))?;
        world.sync()?;
    }
    Ok(())
}

/// A first visit to the Device tab: the wizard at `step`.
fn wizard_at(world: &mut World, step: i32) -> Outcome {
    fake_hub(world).onboarding = false;
    add_device_tab(world)?;
    open_wizard(world, step)
}

/// The hub's state changes and every watcher is told, as devices.ex does.
fn set_hub_status(world: &mut World, status: &str) -> Outcome {
    fake_hub(world).host_status = status.into();
    announce(&mut world.mc);
    world.sync()
}

/// The words the Device tab shows anywhere: its view's notes, banners and wizard.
fn tab_words(world: &World) -> Vec<String> {
    let shown = view(world);
    let mut words: Vec<String> = ["loading", "empty", "error", "hostDetail", "starting"]
        .iter()
        .map(|field| text(&shown[*field]))
        .collect();
    for banner in shown["banners"].as_array().into_iter().flatten() {
        words.push(text(&banner["message"]));
        words.push(text(&banner["advice"]));
    }
    let wizard = &shown["wizard"];
    for field in ["hubStatus", "agentStatus", "error"] {
        words.push(text(&wizard[field]));
    }
    words.retain(|w| !w.is_empty());
    words
}

fn panel_shows(world: &World, words: &str) -> bool {
    world
        .peek_part::<Panel>()
        .and_then(|p| p.0)
        .is_some_and(|panel| panel.shows(world, words).unwrap_or(false))
}

fn tab_says(world: &World, words: &str) -> bool {
    tab_words(world).iter().any(|w| w == words) || panel_shows(world, words)
}

fn describe_words(world: &World) -> String {
    format!("{} | {}", tab_words(world).join(" | "), describe_ref(world))
}

fn describe_wizard(world: &World) -> String {
    format!(
        "{}; the wizard is {}",
        describe_ref(world),
        show(&wizard_view(world))
    )
}

fn item_flag(world: &mut World, name: &str, flag: &str) -> Outcome<bool> {
    let panel = device_panel(world)?;
    let item = panel.item(world, name)?;
    Ok(panel.flag(world, item, flag))
}

fn item_text(world: &mut World, name: &str) -> Outcome<String> {
    let panel = device_panel(world)?;
    let item = panel.item(world, name)?;
    Ok(panel.text_of(world, item, "text"))
}

fn click(world: &mut World, name: &str) -> Outcome {
    device_panel(world)?.click(world, name)?;
    world.sync()
}

fn banner_of(world: &World, label: &str) -> Value {
    view(world)["banners"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|b| text(&b["label"]) == label)
        .cloned()
        .unwrap_or(Value::Null)
}

fn set_machine(world: &mut World, label: &str, status: &str, detail: &str) {
    let hub = fake_hub(world);
    hub.host_label = label.into();
    hub.local_status = status.into();
    hub.host_status = status.into();
    hub.banner_detail = detail.into();
}

fn set_availability(world: &mut World, platform: &str, availability: Value) {
    let hub = fake_hub(world);
    hub.onboarding = false;
    hub.availability.retain(|(p, _)| p != platform);
    hub.availability.push((platform.into(), availability));
}

/// The setup wizard's and the banners' "the user chooses …" (ThemeSteps' own
/// step hands them here): false when no wizard is open to take it.
pub fn device_chooses(world: &mut World, what: &str) -> Outcome<bool> {
    if what == "Refresh devices" {
        if world.peek_part::<Panel>().and_then(|p| p.0).is_none() {
            return Ok(false);
        }
        click(world, "deviceRefresh")?;
        return Ok(true);
    }
    if tools_chooses(world, what)? {
        return Ok(true);
    }
    let Some(name) = (match what {
        "Done" => Some("wizardDone"),
        "Cancel" => Some("wizardCancel"),
        "Back" => Some("wizardBack"),
        _ => None,
    }) else {
        return Ok(false);
    };
    if world.peek_part::<Panel>().and_then(|p| p.0).is_none() || wizard_view(world).is_null() {
        return Ok(false);
    }
    // The wizard's finish, held so its Saving… can be seen.
    if what == "Done" {
        world.mc.hold("device.configure");
    }
    click(world, name)?;
    Ok(true)
}

fn wizard_can_continue(world: &mut World) -> Outcome {
    let panel = device_panel(world)?;
    world.wait_for_with(
        |w| {
            panel
                .find(w, "wizardContinue")
                .ok()
                .flatten()
                .is_some_and(|item| panel.flag(w, item, "enabled"))
        },
        describe_wizard,
    )
}

/// The Device tab's "{name} is offered" (MoveSteps' own step hands it
/// here): false unless the Device tab's picker has loaded and lists devices
/// (a thread-move world has none).
pub fn device_offered(world: &mut World, name: &str) -> Outcome<bool> {
    let shown = view(world);
    if shown["loaded"].as_bool() != Some(true)
        || shown["groups"]
            .as_array()
            .is_none_or(|groups| groups.is_empty())
    {
        return Ok(false);
    }
    let wanted = name.to_owned();
    world.wait_for_with(|w| !row_of(w, &wanted, "").is_null(), describe_ref)?;
    Ok(true)
}

/// The setup wizard's "the user can continue" (OnboardingSteps' own step
/// hands it here): false when no Device tab wizard is open.
pub fn device_can_continue(world: &mut World) -> Outcome<bool> {
    if world.peek_part::<Panel>().and_then(|p| p.0).is_none() || wizard_view(world).is_null() {
        return Ok(false);
    }
    wizard_can_continue(world)?;
    Ok(true)
}

fn register_setup(steps: &mut Steps) {
    steps.step("the user shows the Device tab", |world, _, _| {
        look(world)?;
        world.dispatch("rightPanel.activate", json!({"id": "device"}))?;
        world.sync()
    });
    steps.step(
        "device support has never been set up on the thread's environment",
        |world, _, _| {
            let hub = fake_hub(world);
            hub.onboarding = false;
            hub.host_status = "disabled".into();
            Ok(())
        },
    );
    steps.step(
        "a \"Set up devices\" wizard opens with the steps \"Device hub\", \"Simulators\" and \"Agent access\"",
        |world, _, _| {
            let panel = device_panel(world)?;
            world.wait_for_with(
                |w| {
                    !wizard_view(w).is_null()
                        && panel
                            .find(w, "deviceWizard")
                            .ok()
                            .flatten()
                            .is_some_and(|item| panel.flag(w, item, "visible"))
                        && ["Set up devices", "Device hub", "Simulators", "Agent access"]
                            .iter()
                            .all(|t| panel_shows(w, t))
                },
                describe_wizard,
            )
        },
    );
    steps.step("the user finished setting devices up", |world, _, _| {
        fake_hub(world).onboarding = true;
        Ok(())
    });
    steps.step("later turned device support off", |world, _, _| {
        fake_hub(world).host_status = "disabled".into();
        Ok(())
    });
    steps.step("the wizard opens at its first step", |world, _, _| {
        device_panel(world)?;
        world.wait_for_with(
            |w| !wizard_view(w).is_null() && wizard_step(w) == 0,
            describe_wizard,
        )?;
        expect!(
            item_flag(world, "deviceWizard", "visible")?,
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the wizard is at \"Device hub\" (?:with|and) the hub (?:is )?off",
        |world, _, _| {
            fake_hub(world).host_status = "disabled".into();
            wizard_at(world, 0)
        },
    );
    steps.step(
        "the wizard is at (?:\"Device hub\" with the hub ready|its first step)",
        |world, _, _| wizard_at(world, 0),
    );
    steps.step(
        "(?:the wizard is at|the user is at) the \"Simulators\" step(?: and iOS has no simulator runtime)?",
        |world, _, _| wizard_at(world, 1),
    );
    steps.step("the user is at the \"Agent access\" step", |world, _, _| {
        wizard_at(world, 2)
    });
    steps.step(
        "the user is at the \"Agent access\" step with the hub ready",
        |world, _, _| {
            add_device(world, "ios", "iPhone 17", true);
            wizard_at(world, 2)
        },
    );
    steps.step(
        "the user turns (?:on|off) \"Enable device hub\"(?: in the wizard)?",
        |world, _, _| click(world, "wizardHubSwitch"),
    );
    steps.step("the user turned on \"Enable device hub\"", |world, _, _| {
        fake_hub(world).host_status = "disabled".into();
        wizard_at(world, 0)?;
        click(world, "wizardHubSwitch")
    });
    steps.step(
        "the wizard says \"Installing device hub…\", then \"Starting device hub…\"",
        |world, _, _| {
            world.wait_for_with(
                |w| text(&wizard_view(w)["hubStatus"]) == "Installing device hub…",
                describe_wizard,
            )?;
            set_hub_status(world, "starting")?;
            world.wait_for_with(
                |w| text(&wizard_view(w)["hubStatus"]) == "Starting device hub…",
                describe_wizard,
            )?;
            set_hub_status(world, "ready")
        },
    );
    steps.step(
        "when the hub is up it says \"Device hub is ready.\"",
        |world, _, _| {
            world.wait_for_with(
                |w| text(&wizard_view(w)["hubStatus"]) == "Device hub is ready.",
                describe_wizard,
            )
        },
    );
    steps.step("the user can continue to the next step", |world, _, _| {
        wizard_can_continue(world)
    });
    steps.step("the user cannot continue", |world, _, _| {
        world.sync()?;
        let next = item_flag(world, "wizardContinue", "enabled")?;
        let done = item_flag(world, "wizardDone", "visible")?
            && item_flag(world, "wizardDone", "enabled")?;
        expect!(!next && !done, "{}", describe_wizard(world));
        Ok(())
    });
    steps.step(
        "the hub is on and agents may control devices",
        |world, _, _| {
            fake_hub(world).agent_access = true;
            wizard_at(world, 0)
        },
    );
    steps.step("agent access is off as well", |world, _, _| {
        world.wait_for_with(
            |w| {
                let configures = &w
                    .mc
                    .peek::<FakeHub>()
                    .map(|h| h.configures.clone())
                    .unwrap_or_default();
                configures
                    .last()
                    .is_some_and(|c| c["enabled"] == false && c["agentAccessEnabled"] == false)
                    && wizard_view(w)["agentOn"] != true
            },
            describe_wizard,
        )
    });
    steps.step("the device hub is installing", |world, _, _| {
        fake_hub(world).host_status = "installing".into();
        wizard_at(world, 0)
    });
    steps.step("\"Enable device hub\" cannot be changed", |world, _, _| {
        expect!(
            !item_flag(world, "wizardHubSwitch", "enabled")?,
            "{}",
            describe_wizard(world)
        );
        Ok(())
    });
    steps.step(
        "the user cannot go back or choose another step until it is done",
        |world, _, _| {
            let other = item_flag(world, "wizardStep-Simulators", "enabled")?;
            let back = item_flag(world, "wizardBack", "enabled")?;
            expect!(!other && !back, "{}", describe_wizard(world));
            Ok(())
        },
    );
    steps.step(
        "the user chooses the step \"Agent access\" directly",
        |world, _, _| {
            expect!(
                !item_flag(world, "wizardStep-Agent access", "enabled")?,
                "the later step can be chosen; {}",
                describe_wizard(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the wizard (?:stays at|returns to|shows) (?:the )?\"Device hub\"(?: step)?",
        |world, _, _| {
            world.sync()?;
            expect!(
                wizard_step(world) == 0,
                "the wizard is at step {}",
                wizard_step(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user continues twice and then chooses \"Device hub\"",
        |world, _, _| {
            click(world, "wizardContinue")?;
            click(world, "wizardContinue")?;
            click(world, "wizardStep-Device hub")
        },
    );

    // The Simulators step's platform situations.
    steps.step(
        "the hub is ready and (iOS|Android) is not detected and the machine gives no reason",
        |world, c, _| {
            let platform = c[0].to_lowercase();
            set_availability(
                world,
                &platform.clone(),
                json!({"platform": platform, "available": false}),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the hub is ready and iOS is unavailable because {Q}"),
        |world, c, _| {
            set_availability(
                world,
                "ios",
                json!({"platform": "ios", "available": false, "reason": c[0]}),
            );
            Ok(())
        },
    );
    steps.step(
        "the hub is ready and (?:Xcode is installed with no iOS Simulator runtime|the Android SDK is installed with no virtual device)",
        |world, _, _| {
            fake_hub(world).onboarding = false;
            Ok(())
        },
    );
    steps.step(
        "the hub is ready and Xcode has an iOS Simulator",
        |world, _, _| {
            fake_hub(world).onboarding = false;
            add_device(world, "ios", "iPhone 17", true);
            Ok(())
        },
    );
    steps.step(
        "the hub is ready and (?:the Android SDK has an emulator|only Android has an emulator)",
        |world, _, _| {
            fake_hub(world).onboarding = false;
            add_device(world, "android", "Pixel 9", true);
            Ok(())
        },
    );
    steps.step(&format!("(iOS|Android) reads {Q}"), |world, c, _| {
        let (platform, wanted) = (c[0].clone(), c[1].clone());
        world.wait_for_with(
            |w| {
                wizard_view(w)["platforms"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|p| text(&p["platform"]) == platform)
                    .is_some_and(|p| text(&p["message"]) == wanted)
            },
            describe_wizard,
        )
    });
    steps.step(&format!("the wizard says {Q}"), |world, c, _| {
        let wanted = c[0].clone();
        world.wait_for_with(|w| tab_says(w, &wanted), describe_words)
    });
    steps.step(
        "the user installs a runtime and chooses \"Check again\"",
        |world, _, _| {
            add_device(world, "ios", "iPhone 17", true);
            world.mc.hold("device.list");
            click(world, "wizardCheckAgain")
        },
    );
    steps.step(
        "the button says \"Checking…\" until the answer arrives",
        |world, _, _| {
            let label = item_text(world, "wizardCheckAgain")?;
            expect!(
                text(&wizard_view(world)["pending"]) == "check" && label == "Checking…",
                "the button says {label}; {}",
                describe_wizard(world)
            );
            world.mc.answer_held();
            world.sync()
        },
    );
    steps.step(
        "the user turns on \"Allow agents to control devices\" and the hub is (installing agent tools|starting agent tools|updating|ready with agent tools)",
        |world, c, _| {
            // The switch is turned while the hub is ready; installing the
            // agent tools is what the hub then reports, held mid-answer.
            if c[0] != "ready with agent tools" {
                world.mc.hold("device.configure");
            }
            click(world, "wizardAgentSwitch")?;
            let status = match c[0].as_str() {
                "installing agent tools" => "installing",
                "starting agent tools" => "starting",
                _ => return Ok(()),
            };
            set_hub_status(world, status)
        },
    );
    steps.step(
        "\"Allow agents to control devices\" cannot be turned on while the hub is off",
        |world, _, _| {
            set_hub_status(world, "disabled")?;
            expect!(
                !item_flag(world, "wizardAgentSwitch", "enabled")?,
                "{}",
                describe_wizard(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the button says \"Saving…\" until the answer arrives",
        |world, _, _| {
            let label = item_text(world, "wizardDone")?;
            expect!(
                label == "Saving…",
                "the button says {label}; {}",
                describe_wizard(world)
            );
            world.mc.answer_held();
            world.sync()
        },
    );
    steps.step("the wizard closes", |world, _, _| {
        world.wait_for_with(|w| wizard_view(w).is_null(), describe_wizard)
    });
    steps.step(
        "the Device tab lists the environment's devices",
        |world, _, _| world.wait_for_with(|w| !row_of(w, "iPhone 17", "").is_null(), describe_ref),
    );
    steps.step(
        "the user shows the Device tab in another thread",
        |world, _, _| {
            let other = "thread-2";
            let row = json!({"id": other, "title": "Other", "projectId": PROJECT,
                             "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
            world.mc.threads.insert(other.into(), row.clone());
            world.mc.send_row(other, &row);
            world.sync()?;
            let key = format!("{}:{other}", world.mc.environment_id);
            look_stream(world, &key, true)?;
            world.dispatch("rightPanel.add", json!({"kind": "device"}))?;
            world.sync()
        },
    );
    steps.step("no wizard opens", |world, _, _| {
        world.sync()?;
        expect!(wizard_view(world).is_null(), "{}", describe_wizard(world));
        Ok(())
    });
    steps.step("device support stays as the user left it", |world, _, _| {
        expect!(fake_hub(world).configures.is_empty(), "{}", describe(world));
        Ok(())
    });
    steps.step(&format!("the hub fails with {Q}"), |world, c, _| {
        fake_hub(world).host_detail = c[0].clone();
        set_hub_status(world, "failed")
    });
    steps.step(
        &format!("the wizard shows {Q} as an error"),
        |world, c, _| {
            let wanted = c[0].clone();
            world.wait_for_with(
                |w| text(&wizard_view(w)["error"]) == wanted && panel_shows(w, &wanted),
                describe_wizard,
            )
        },
    );

    // Banners.
    steps.step(
        &format!("the machine {Q} is (installing|starting) its device tools"),
        |world, c, _| {
            set_machine(world, &c[0], &c[1], "");
            Ok(())
        },
    );
    steps.step(
        &format!("the machine {Q} is installing and says {Q}"),
        |world, c, _| {
            set_machine(world, &c[0], "installing", &c[1]);
            Ok(())
        },
    );
    steps.step(
        &format!("the machine {Q} failed to start its device tools(?: without saying why)?"),
        |world, c, _| {
            set_machine(world, &c[0], "failed", "");
            Ok(())
        },
    );
    steps.step(
        &format!("the tab shows a banner for {Q} saying {Q}"),
        |world, c, _| {
            let (label, wanted) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                |w| text(&banner_of(w, &label)["message"]) == wanted && panel_shows(w, &wanted),
                describe_words,
            )
        },
    );
    steps.step(&format!("the banner for {Q} says {Q}"), |world, c, _| {
        let (label, wanted) = (c[0].clone(), c[1].clone());
        world.wait_for_with(
            |w| text(&banner_of(w, &label)["message"]) == wanted && panel_shows(w, &wanted),
            describe_words,
        )
    });
    steps.step(&format!("it says {Q}"), |world, c, _| {
        if super::pull_request::pull_request_review_says(world, &c[0])? {
            return Ok(());
        }
        let wanted = c[0].clone();
        world.wait_for_with(|w| tab_says(w, &wanted), describe_words)
    });
    steps.step(
        "the MC (can|cannot) retry a single machine",
        |world, c, _| {
            fake_hub(world).supports_retry = c[0] == "can";
            Ok(())
        },
    );
    steps.step("the user chooses \"Retry\" on its banner", |world, _, _| {
        add_device_tab(world)?;
        world.mc.hold("device.list");
        click(world, &format!("deviceBannerRetry-{HOST}"))
    });
    steps.step(
        &format!("the banner for {Q} offers no \"Retry\""),
        |world, c, _| {
            let label = c[0].clone();
            world.wait_for_with(|w| !banner_of(w, &label).is_null(), describe_words)?;
            expect!(
                !item_flag(world, &format!("deviceBannerRetry-{HOST}"), "visible")?,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the button says \"Retrying…\" until the answer arrives",
        |world, _, _| {
            let label = item_text(world, &format!("deviceBannerRetry-{HOST}"))?;
            expect!(
                label == "Retrying…",
                "the button says {label}; {}",
                describe(world)
            );
            world.mc.answer_held();
            world.sync()
        },
    );
    steps.step(&format!("only {Q} is retried"), |world, _, _| {
        let lists = fake_hub(world).lists.clone();
        expect!(
            lists
                .last()
                .is_some_and(|l| text(&l["retryHostId"]) == HOST),
            "the MC was asked {}",
            show(&Value::Array(lists))
        );
        Ok(())
    });
    steps.step(
        &format!("device support is off and the machine {Q} failed earlier"),
        |world, c, _| {
            set_machine(world, &c[0], "failed", "");
            fake_hub(world).host_status = "disabled".into();
            look(world)
        },
    );
    steps.step(&format!("no banner is shown for {Q}"), |world, _, _| {
        world.sync()?;
        let banners = view(world)["banners"].clone();
        expect!(
            banners.as_array().is_none_or(Vec::is_empty),
            "the banners are {}",
            show(&banners)
        );
        Ok(())
    });
    steps.step(
        &format!("the setup wizard shows the banner for {Q}"),
        |world, c, _| {
            wizard_at(world, 0)?;
            let label = c[0].clone();
            world.wait_for_with(
                |w| {
                    let banner = banner_of(w, &label);
                    !banner.is_null() && panel_shows(w, &text(&banner["message"]))
                },
                describe_words,
            )
        },
    );
    steps.step(
        "so does the Device tab once setup is done",
        |world, _, _| {
            click(world, "wizardCancel")?;
            let banners = view(world)["banners"].clone();
            let first = text(&banners[0]["message"]);
            expect!(
                !first.is_empty() && panel_shows(world, &first),
                "the banners are {}",
                show(&banners)
            );
            Ok(())
        },
    );
}

// --- The Tools drawer ---------------------------------------------------

/// The shown device tab's Tools drawer.
fn tools_object(world: &World) -> Option<ObjectId> {
    shown_tab(world)
        .ok()
        .and_then(|tab| DeviceTab::tools(world.engine(), tab))
}

/// The drawer's `view`, or null when no device tab shows.
fn tools_view(world: &World) -> Value {
    tools_object(world)
        .and_then(|t| DeviceTools::read(world.engine(), t, |t| t.view().clone()))
        .unwrap_or(Value::Null)
}

fn describe_tools(world: &World) -> String {
    format!(
        "the tools are {}; {}",
        show(&tools_view(world)),
        describe_ref(world)
    )
}

/// Lays the Device tab out at `width` by `height`, its window with it.
fn size_panel(world: &mut World, width: f64, height: f64) -> Outcome {
    let panel = device_panel(world)?;
    let Some(root) = panel.root(world) else {
        fail!("the Device tab did not load");
    };
    if let QmlValue::Object(probe) = panel.read(world, root, "parent") {
        panel.write(world, probe, "width", QmlValue::from(width))?;
        panel.write(world, probe, "height", QmlValue::from(height))?;
    }
    panel.write(world, root, "width", QmlValue::from(width))?;
    panel.write(world, root, "height", QmlValue::from(height))?;
    world.resize(width, height)?;
    world.sync()
}

/// On the wide panel the drawer sits beside the screen, and every control
/// can be clicked.
fn wide_panel(world: &mut World) -> Outcome {
    size_panel(world, 900.0, 1100.0)
}

/// The drawer is open; waits for its settings to have landed.
fn open_tools_ready(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| {
            let tools = tools_view(w);
            tools["open"] == true && tools["loaded"] == true
        },
        describe_tools,
    )
}

/// Opens the Tools drawer for the device shown and waits for its settings.
fn open_tools(world: &mut World) -> Outcome {
    if tools_view(world)["open"] != true {
        click(world, "deviceTools")?;
    }
    open_tools_ready(world)
}

/// Types into a tools field the way a user does: click it, then keys.
fn type_into(world: &mut World, name: &str, typed: &str) -> Outcome {
    click(world, name)?;
    world.type_text(typed)?;
    world.sync()
}

fn combo_model(world: &mut World, name: &str) -> Outcome<(ObjectId, Vec<String>)> {
    let panel = device_panel(world)?;
    let combo = panel.item(world, name)?;
    let model = hal_c2_shell::json::from_value(world.engine(), &panel.read(world, combo, "model"));
    let labels = model
        .as_array()
        .map(|m| m.iter().map(text).collect())
        .unwrap_or_default();
    Ok((combo, labels))
}

/// Chooses `label` in the combo box `name`, as the user picking it does.
fn activate(world: &mut World, name: &str, label: &str) -> Outcome {
    let (combo, model) = combo_model(world, name)?;
    let Some(index) = model.iter().position(|m| m == label) else {
        fail!("no choice {label} among {}", model.join(", "));
    };
    expect!(
        world
            .engine()
            .emit_by_name(combo, "activated", &[QmlValue::Int(index as i32)])
            .is_ok(),
        "{name} cannot be chosen from"
    );
    world.sync()
}

/// Whether the drawer's device was asked a `device.action` like `wanted`.
fn asked(world: &mut World, wanted: impl Fn(&Value) -> bool) -> Outcome {
    world.wait_for_with(
        |w| {
            w.mc.peek::<FakeHub>()
                .is_some_and(|hub| hub.actions.iter().any(&wanted))
        },
        |w| {
            let actions =
                w.mc.peek::<FakeHub>()
                    .map(|hub| show(&Value::Array(hub.actions.clone())))
                    .unwrap_or_default();
            format!("{}; the device was asked {actions}", describe_ref(w))
        },
    )
}

fn has_device(world: &mut World, name: &str) -> bool {
    fake_hub(world)
        .devices
        .iter()
        .any(|d| text(&d["name"]) == name)
}

/// The thread has `name` open, on its tab.
fn open_named(world: &mut World, platform: &str, name: &str) -> Outcome {
    if !has_device(world, name) {
        add_device(world, platform, name, true);
    }
    let device = device_named(fake_hub(world), name)?;
    open_session(&mut world.mc, &device, THREAD);
    announce(&mut world.mc);
    // The session opens the device's own tab; a picker added before it
    // lands would be replaced by it.
    if fake_hub(world).looking {
        let title = name.to_owned();
        world.wait_for_with(|w| tab_titles(w).contains(&title), describe_ref)?;
    }
    show_device_tab(world, name)
}

/// A device with a full set of reported settings, open on its tab.
fn tool_device(world: &mut World, platform: &str, name: &str) -> Outcome {
    let hub = fake_hub(world);
    hub.settings = if platform == "ios" {
        json!({
            "appearance": "light",
            "textSize": "default",
            "liquidGlass": "clear",
            "colorFilter": "none",
            "reduceMotion": false,
            "increaseContrast": false,
            "reduceTransparency": false,
            "showBorders": false,
            "voiceOver": false,
        })
    } else {
        json!({
            "appearance": "light",
            "textSize": "default",
            "reduceMotion": false,
            "networkEnabled": true,
        })
    };
    hub.foreground_app = json!({"id": "com.example.shop"});
    open_named(world, platform, name)
}

fn tools_open_for(world: &mut World, platform: &str, name: &str) -> Outcome {
    tool_device(world, platform, name)?;
    wide_panel(world)?;
    open_tools(world)
}

fn platform_of(which: &str) -> &'static str {
    if which == "iOS Simulator" {
        "ios"
    } else {
        "android"
    }
}

/// The feeds the drawer follows whose path ends with `suffix`.
fn feeds(world: &mut World, suffix: &str) -> Vec<TcpStream> {
    fake_hub(world)
        .feeds
        .iter()
        .filter(|(path, feed)| path.ends_with(suffix) && connected(feed))
        .filter_map(|(_, feed)| feed.try_clone().ok())
        .collect()
}

/// The device says `data` on every feed of `suffix`, as one event.
fn report(world: &mut World, suffix: &str, data: &str) -> Outcome {
    let wanted = suffix.to_owned();
    world.wait_for_with(
        |w| {
            w.mc.peek::<FakeHub>().is_some_and(|hub| {
                hub.feeds
                    .iter()
                    .any(|(path, feed)| path.ends_with(&wanted) && connected(feed))
            })
        },
        |w| format!("no {wanted} feed; {}", describe_ref(w)),
    )?;
    for mut feed in feeds(world, suffix) {
        let _ = feed.write_all(format!("data: {data}\n\n").as_bytes());
        let _ = feed.flush();
    }
    world.sync()
}

fn drawer_and_screen(world: &mut World) -> Outcome<((f64, f64), f64, bool, bool)> {
    let panel = device_panel(world)?;
    let drawer = panel.item(world, "deviceToolsPanel")?;
    let screen = panel.item(world, "deviceScreen")?;
    let drawer_at = panel.at(world, drawer, 0.0, 0.0)?;
    let screen_right = panel.at(world, screen, 1.0, 0.0)?.0;
    Ok((
        drawer_at,
        screen_right,
        panel.flag(world, drawer, "visible"),
        panel.flag(world, screen, "visible"),
    ))
}

/// The iOS accessibility tree of a screen with one button, "Buy".
fn ax_screen(world: &mut World) {
    fake_hub(world).ax_tree = json!([{
        "AXLabel": "",
        "frame": {"x": 0, "y": 0, "width": 390, "height": 844},
        "children": [{
            "AXLabel": "Buy",
            "frame": {"x": 39, "y": 84, "width": 78, "height": 42},
        }],
    }]);
}

/// Lets the drawer's refreshes run until `done`: the overlay reads the
/// device again every half second.
fn refresh_until(world: &mut World, done: impl Fn(&World) -> bool) -> Outcome {
    for _ in 0..20 {
        world.sync()?;
        if done(world) {
            return Ok(());
        }
        world.advance(500)?;
    }
    fail!("{}", describe_tools(world))
}

fn no_access(world: &mut World) -> Outcome {
    fake_hub(world).no_access = true;
    announce(&mut world.mc);
    world.sync()?;
    // The tools read their target again from the announcement.
    world.wait_for_with(|w| tools_view(w)["axOffered"] != true, describe_tools)
}

/// The tools' value of a choice the steps name.
fn value_of(choice: &str) -> &'static str {
    match choice {
        "Dark" => "dark",
        "Extra large" => "extra-large",
        "Tinted" => "tinted",
        "Red / green (protanopia)" => "red-green",
        "Landscape left" => "landscape_left",
        _ => "",
    }
}

fn field_text(world: &mut World, name: &str) -> String {
    item_text(world, name).unwrap_or_default()
}

/// The steps that open the drawer and check what it shows.
fn register_tools(steps: &mut Steps) {
    steps.step(
        &format!("the user has the tools open for the (iOS Simulator|Android Emulator) {Q}"),
        |world, c, _| tools_open_for(world, platform_of(&c[0]), &c[1]),
    );
    steps.step(
        &format!(
            "the user has the tools open for the (iOS Simulator|Android Emulator) {Q} with \"com.example.shop\" in front"
        ),
        |world, c, _| tools_open_for(world, platform_of(&c[0]), &c[1]),
    );
    steps.step(
        &format!("the user has the tools open for the iOS Simulator {Q} with Reduce Motion off"),
        |world, c, _| tools_open_for(world, "ios", &c[0]),
    );
    steps.step(
        "the user has the tools open with \"com.example.shop\" in front",
        |world, _, _| tools_open_for(world, "ios", "iPhone 17"),
    );
    steps.step(
        &format!("the user has the tools open for {Q} with {Q} in front"),
        |world, c, _| {
            tool_device(world, "ios", &c[0])?;
            fake_hub(world).foreground_app = json!({"id": c[1]});
            wide_panel(world)?;
            open_tools(world)
        },
    );
    steps.step(
        &format!("the user has the tools open for the iOS Simulator {Q} with no app in front"),
        |world, c, _| {
            fake_hub(world).foreground_app = Value::Null;
            open_named(world, "ios", &c[0])?;
            wide_panel(world)?;
            open_tools(world)
        },
    );
    steps.step(
        &format!("the user has the tools open for the iOS Simulator {Q} placed in Tokyo"),
        |world, c, _| {
            tools_open_for(world, "ios", &c[0])?;
            activate(world, "toolsLocationPreset", "Tokyo")
        },
    );
    steps.step("the user has the tools open", |world, _, _| {
        if !has_device(world, "iPhone 17") {
            open_named(world, "ios", "iPhone 17")?;
        }
        wide_panel(world)?;
        open_tools(world)
    });
    steps.step(
        &format!("the thread has the iOS Simulator {Q} open in light appearance"),
        |world, c, _| {
            fake_hub(world).settings["appearance"] = json!("light");
            open_named(world, "ios", &c[0])
        },
    );

    // Opening and closing.
    steps.step(
        "the tools open beside the screen when the panel is wide enough",
        |world, _, _| {
            wide_panel(world)?;
            world.wait_for_with(|w| tools_view(w)["open"] == true, describe_tools)?;
            let ((drawer_x, _), screen_right, drawer, screen) = drawer_and_screen(world)?;
            expect!(
                drawer && screen && screen_right <= drawer_x + 1.0,
                "the drawer is at {drawer_x} (shown {drawer}), the screen ends at {screen_right} (shown {screen}); {}",
                describe_screen(world)
            );
            world.mc.answer_held();
            world.sync()
        },
    );
    steps.step("over the screen when it is narrow", |world, _, _| {
        size_panel(world, 420.0, 900.0)?;
        let ((drawer_x, _), screen_right, drawer, _) = drawer_and_screen(world)?;
        expect!(
            drawer && drawer_x < screen_right,
            "the drawer is at {drawer_x} (shown {drawer}), the screen ends at {screen_right}; {}",
            describe_screen(world)
        );
        Ok(())
    });
    steps.step("the tools close", |world, _, _| {
        world.wait_for_with(|w| tools_view(w)["open"] != true, describe_tools)
    });
    steps.step(
        "the tools say \"Reading device settings…\" and no control can be changed",
        |world, _, _| {
            let panel = device_panel(world)?;
            world.wait_for_with(
                |w| {
                    tools_view(w)["loaded"] != true
                        && panel.shows(w, "Reading device settings…").unwrap_or(false)
                        && panel
                            .find(w, "toolsChoice-Appearance-Dark")
                            .ok()
                            .flatten()
                            .is_some_and(|dark| !panel.flag(w, dark, "enabled"))
                },
                describe_tools,
            )
        },
    );
    steps.step("the device's settings arrive", |world, _, _| {
        world.mc.answer_held();
        world.sync()
    });
    steps.step(
        "the controls show what the device reports",
        |world, _, _| {
            let panel = device_panel(world)?;
            world.wait_for_with(
                |w| {
                    let tools = tools_view(w);
                    tools["loaded"] == true
                        && tools["settings"]["appearance"] == "light"
                        && panel
                            .find(w, "toolsChoice-Appearance-Dark")
                            .ok()
                            .flatten()
                            .is_some_and(|dark| panel.flag(w, dark, "enabled"))
                },
                describe_tools,
            )
        },
    );

    // What the drawer says.
    steps.step(&format!("the tools say {Q}"), |world, c, _| {
        let (wanted, panel) = (c[0].clone(), device_panel(world)?);
        world.wait_for_with(
            |w| tools_view(w)["error"] == *wanted || panel.shows(w, &wanted).unwrap_or(false),
            describe_tools,
        )
    });
    steps.step(&format!("the tools show {Q}"), |world, c, _| {
        let (wanted, panel) = (c[0].clone(), device_panel(world)?);
        world.wait_for_with(
            |w| tools_view(w)["error"] == *wanted && panel.shows(w, &wanted).unwrap_or(false),
            describe_tools,
        )
    });
    steps.step("the tools have no \"(.+)\"", |world, c, _| {
        let panel = device_panel(world)?;
        expect!(!panel.shows(world, &c[0])?, "the tools show {}", c[0]);
        Ok(())
    });
    steps.step(
        "the tools have no \"Push notification\" section",
        |world, _, _| {
            let panel = device_panel(world)?;
            expect!(
                !panel.shows(world, "Push notification")?,
                "{}",
                describe_tools(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("the tools list (.+) under {Q}"), |world, c, _| {
        world.mc.answer_held();
        open_tools_ready(world)?;
        let panel = device_panel(world)?;
        expect!(panel.shows(world, &c[1])?, "{}", describe_tools(world));
        for label in c[0].split(", ").flat_map(|part| part.split(" and ")) {
            let label = label.trim();
            expect!(panel.shows(world, label)?, "no setting named {label}");
        }
        Ok(())
    });

    // Refusals and waiting.
    steps.step(
        &format!("the device refuses to change appearance because {Q}"),
        |world, c, _| {
            fake_hub(world).refuse_action = c[0].clone();
            Ok(())
        },
    );
    steps.step("the appearance still reads \"Light\"", |world, _, _| {
        expect!(
            tools_view(world)["settings"]["appearance"] == "light",
            "{}",
            describe_tools(world)
        );
        Ok(())
    });
    steps.step(
        "the user changes a setting and the device is slow to answer",
        |world, _, _| {
            world.mc.hold("device.action");
            click(world, "toolsChoice-Appearance-Dark")
        },
    );
    steps.step("a spinner shows beside \"Tools\"", |world, _, _| {
        let panel = device_panel(world)?;
        world.wait_for_with(
            |w| {
                tools_view(w)["pending"] == true
                    && panel
                        .find(w, "toolsSpinner")
                        .ok()
                        .flatten()
                        .is_some_and(|s| panel.flag(w, s, "visible"))
            },
            describe_tools,
        )
    });
    steps.step(
        "no other control can be changed until it answers",
        |world, _, _| {
            expect!(
                !item_flag(world, "toolsSwitch-Reduce Motion", "enabled")?,
                "{}",
                describe_tools(world)
            );
            world.mc.answer_held();
            world.sync()
        },
    );

    // Another device.
    steps.step(
        &format!("the user changed the location of {Q} in the tools"),
        |world, c, _| {
            fake_hub(world).foreground_app = json!({"id": "com.example.shop"});
            open_named(world, "ios", &c[0])?;
            wide_panel(world)?;
            open_tools(world)?;
            type_into(world, "toolsLatitude", "59.33")?;
            type_into(world, "toolsLongitude", "18.07")?;
            click(world, "toolsLocationSet")?;
            // The other device, with its own settings.
            add_device(world, "android", "Pixel 9", true);
            let pixel = device_named(fake_hub(world), "Pixel 9")?;
            open_session(&mut world.mc, &pixel, THREAD);
            announce(&mut world.mc);
            fake_hub(world).settings = json!({
                "appearance": "dark",
                "textSize": "large",
                "reduceMotion": true,
                "networkEnabled": false,
            });
            world.sync()
        },
    );
    steps.step(&format!("the user shows the tab of {Q}"), |world, c, _| {
        show_device_tab(world, &c[0])
    });
    steps.step(
        "its tools show its own settings and an empty location",
        |world, _, _| {
            // Each device tab has its own drawer, closed until opened.
            open_tools(world)?;
            let panel = device_panel(world)?;
            let empty = |w: &World, name: &str| {
                panel
                    .find(w, name)
                    .ok()
                    .flatten()
                    .is_some_and(|f| panel.text_of(w, f, "text").is_empty())
            };
            world.wait_for_with(
                |w| {
                    let tools = tools_view(w);
                    tools["loaded"] == true
                        && tools["settings"]["appearance"] == "dark"
                        && empty(w, "toolsLatitude")
                        && empty(w, "toolsLongitude")
                },
                describe_tools,
            )
        },
    );

    // Choices and switches.
    steps.step(&format!("the user chooses {Q} for {Q}"), |world, c, _| {
        if c[1] == "Appearance" || c[1] == "Liquid Glass" {
            return click(world, &format!("toolsChoice-{}-{}", c[1], c[0]));
        }
        activate(world, &format!("toolsChoice-{}", c[1]), &c[0])
    });
    steps.step(
        &format!("the device is asked to apply {Q}"),
        |world, c, _| {
            let wanted = value_of(&c[0]);
            asked(world, |action| action["value"] == wanted)
        },
    );
    steps.step(&format!("the control then shows {Q}"), |world, c, _| {
        let (choice, wanted) = (c[0].clone(), value_of(&c[0]));
        world.wait_for_with(
            |w| {
                let tools = tools_view(w);
                if choice == "Landscape left" {
                    return tools["pending"] != true;
                }
                tools["settings"]
                    .as_object()
                    .is_some_and(|s| s.values().any(|v| v == wanted))
            },
            describe_tools,
        )
    });
    steps.step("the user turns on \"Reduce Motion\"", |world, _, _| {
        click(world, "toolsSwitch-Reduce Motion")
    });
    steps.step("the device is asked to turn it on", |world, _, _| {
        asked(world, |action| {
            action["type"] == "setToggle"
                && action["setting"] == "reduceMotion"
                && action["value"] == true
        })
    });
    steps.step("the switch then reads on", |world, _, _| {
        world.wait_for_with(
            |w| tools_view(w)["settings"]["reduceMotion"] == true,
            describe_tools,
        )
    });
    steps.step(
        &format!("the device reports no value for {Q}"),
        |world, _, _| {
            tool_device(world, "ios", "iPhone 17")?;
            if let Some(settings) = fake_hub(world).settings.as_object_mut() {
                settings.remove("liquidGlass");
            }
            wide_panel(world)?;
            open_tools(world)
        },
    );
    steps.step("\"Liquid Glass\" cannot be changed", |world, _, _| {
        expect!(
            !item_flag(world, "toolsChoice-Liquid Glass-Tinted", "enabled")?,
            "{}",
            describe_tools(world)
        );
        Ok(())
    });

    // The app in front.
    steps.step(
        &format!("the iOS Simulator {Q} has {Q} in front"),
        |world, c, _| {
            fake_hub(world).foreground_app = json!({"id": c[1]});
            open_named(world, "ios", &c[0])
        },
    );
    steps.step(&format!("{Q} reads {Q}"), |world, c, _| {
        world.mc.answer_held();
        let (wanted, panel) = (c[1].clone(), device_panel(world)?);
        world.wait_for_with(
            |w| tools_view(w)["foreground"] == *wanted && panel.shows(w, &wanted).unwrap_or(false),
            describe_tools,
        )
    });
    steps.step("the app is stopped", |world, _, _| {
        asked(world, |action| action["type"] == "terminateApp")
    });
    steps.step("the app is started again", |world, _, _| {
        // Relaunch after a terminate names the app that was in front.
        asked(world, |action| action["type"] == "launchApp")
    });
    steps.step("the user opens another app on the device", |world, _, _| {
        report(world, "/appstate", "{\"bundleId\":\"com.example.other\"}")
    });
    steps.step(
        &format!("the foreground feed ends with {Q} in front"),
        |world, c, _| {
            let hub = fake_hub(world);
            hub.foreground_app = json!({"id": c[0]});
            let before = hub.feed_requests;
            for feed in feeds(world, "/appstate") {
                let _ = feed.shutdown(Shutdown::Both);
            }
            world.sync()?;
            // The feed is followed again after a wait.
            for _ in 0..20 {
                if fake_hub(world).feed_requests > before {
                    return Ok(());
                }
                world.advance(500)?;
                world.sync()?;
            }
            fail!("the feed was not followed again; {}", describe_tools(world))
        },
    );
    steps.step("\"Foreground\" reads the other app's id", |world, _, _| {
        world.wait_for_with(
            |w| tools_view(w)["foreground"] == "com.example.other",
            describe_tools,
        )
    });
    steps.step("the device has no app in front", |world, _, _| {
        fake_hub(world).foreground_app = Value::Null;
        open_named(world, "ios", "iPhone 17")?;
        wide_panel(world)?;
        open_tools(world)
    });
    steps.step(
        "\"Terminate\" and \"Relaunch\" are not offered",
        |world, _, _| {
            expect!(
                !item_flag(world, "toolsTerminate", "visible")?
                    && !item_flag(world, "toolsRelaunch", "visible")?,
                "{}",
                describe_tools(world)
            );
            Ok(())
        },
    );

    // Addresses and apps by name.
    steps.step(
        &format!("the user types {Q} into {Q} and chooses {Q}"),
        |world, c, _| {
            let field = if c[2] == "Open" { "url" } else { "launch" };
            type_into(world, &format!("toolsField-{field}"), &c[0])?;
            click(world, &format!("toolsSubmit-{field}"))?;
            // The field's name, for its emptiness to be checked against.
            fake_hub(world).last_field = field.to_owned();
            Ok(())
        },
    );
    steps.step(
        &format!("the device is asked to (open|launch) {Q}"),
        |world, c, _| {
            let (open, wanted) = (c[0] == "open", c[1].clone());
            asked(world, |action| {
                if open {
                    action["type"] == "openUrl" && action["url"] == *wanted
                } else {
                    action["type"] == "launchApp" && action["appId"] == *wanted
                }
            })
        },
    );
    steps.step("the field is empty again", |world, _, _| {
        let name = format!("toolsField-{}", fake_hub(world).last_field);
        let panel = device_panel(world)?;
        let field = panel.item(world, &name)?;
        world.wait_for_with(
            |w| panel.text_of(w, field, "text").is_empty(),
            describe_tools,
        )
    });
    steps.step(
        "\"Open\" and \"Launch\" cannot be chosen while their fields are empty",
        |world, _, _| {
            expect!(
                !item_flag(world, "toolsSubmit-url", "enabled")?
                    && !item_flag(world, "toolsSubmit-launch", "enabled")?,
                "{}",
                describe_tools(world)
            );
            Ok(())
        },
    );

    // Location.
    steps.step(
        &format!("the user types latitude {Q} and longitude {Q} and chooses \"Set\""),
        |world, c, _| {
            type_into(world, "toolsLatitude", &c[0])?;
            type_into(world, "toolsLongitude", &c[1])?;
            fake_hub(world).wanted_location = (
                c[0].parse().unwrap_or_default(),
                c[1].parse().unwrap_or_default(),
            );
            if item_flag(world, "toolsLocationSet", "enabled")? {
                click(world, "toolsLocationSet")?;
            }
            Ok(())
        },
    );
    steps.step("the device is placed there", |world, _, _| {
        let (latitude, longitude) = fake_hub(world).wanted_location;
        let near = |value: &Value, wanted: f64| {
            value
                .as_f64()
                .is_some_and(|value| (value - wanted).abs() < 0.01)
        };
        asked(world, |action| {
            action["type"] == "setLocation"
                && near(&action["latitude"], latitude)
                && near(&action["longitude"], longitude)
        })
    });
    steps.step("\"Set\" could not be chosen", |world, _, _| {
        expect!(
            !item_flag(world, "toolsLocationSet", "enabled")?,
            "{}",
            describe_tools(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the user chooses the preset {Q}"),
        |world, c, _| {
            let Some(&(_, latitude, longitude)) =
                PRESETS.iter().find(|(city, ..)| *city == c[0].as_str())
            else {
                fail!("no preset {}", c[0]);
            };
            fake_hub(world).wanted_location = (latitude, longitude);
            activate(world, "toolsLocationPreset", &c[0])
        },
    );
    steps.step(
        "the fields show the preset's latitude and longitude",
        |world, _, _| {
            let (latitude, longitude) = fake_hub(world).wanted_location;
            let panel = device_panel(world)?;
            let (lat, lon) = (
                panel.item(world, "toolsLatitude")?,
                panel.item(world, "toolsLongitude")?,
            );
            world.wait_for_with(
                |w| {
                    panel.text_of(w, lat, "text") == latitude.to_string()
                        && panel.text_of(w, lon, "text") == longitude.to_string()
                },
                |w| {
                    format!(
                        "the fields read {}, {}",
                        panel.text_of(w, lat, "text"),
                        panel.text_of(w, lon, "text")
                    )
                },
            )
        },
    );
    steps.step(
        "the user chooses \"Clear\" under \"Location\"",
        |world, _, _| click(world, "toolsLocationClear"),
    );
    steps.step(
        "the fields are empty and the simulator has no location",
        |world, _, _| {
            asked(world, |action| action["type"] == "clearLocation")?;
            let panel = device_panel(world)?;
            let (lat, lon) = (
                panel.item(world, "toolsLatitude")?,
                panel.item(world, "toolsLongitude")?,
            );
            world.wait_for_with(
                |w| {
                    panel.text_of(w, lat, "text").is_empty()
                        && panel.text_of(w, lon, "text").is_empty()
                },
                describe_tools,
            )
        },
    );
    steps.step(
        "\"Clear\" is not offered under \"Location\"",
        |world, _, _| {
            expect!(
                !item_flag(world, "toolsLocationClear", "visible")?,
                "{}",
                describe_tools(world)
            );
            Ok(())
        },
    );

    // Permissions.
    steps.step(
        &format!("the user chooses the permission {Q} and then {Q}"),
        |world, c, _| {
            // Android calls Motion "Physical activity".
            let label = if c[0] == "Motion" && tools_view(world)["platform"] == "android" {
                "Physical activity".to_owned()
            } else {
                c[0].clone()
            };
            let button = match c[1].as_str() {
                "grant" => "Grant",
                "revoke" => "Revoke",
                _ => "Reset",
            };
            choose_permission(world, &label)?;
            click(world, &format!("toolsPermission{button}"))
        },
    );
    steps.step(
        &format!("the device is asked to (grant|revoke|reset) {Q} for {Q}"),
        |world, c, _| {
            let permission = match c[1].as_str() {
                "Face ID" => "faceid".to_owned(),
                other => other.to_lowercase(),
            };
            let (decision, app) = (c[0].clone(), c[2].clone());
            asked(world, |action| {
                action["type"] == "setPermission"
                    && action["decision"] == *decision
                    && action["permission"] == *permission
                    && action["appId"] == *app
            })
        },
    );
    steps.step(
        &format!("the user types {Q} as the app and chooses \"Grant\" for {Q}"),
        |world, c, _| {
            type_into(world, "toolsPermissionApp", &c[0])?;
            choose_permission(world, &c[1])?;
            click(world, "toolsPermissionGrant")
        },
    );
    steps.step(
        "the device has no app in front and the user typed no app",
        |world, _, _| {
            fake_hub(world).foreground_app = Value::Null;
            open_named(world, "ios", "iPhone 17")?;
            wide_panel(world)?;
            open_tools(world)
        },
    );
    steps.step(
        "\"Grant\", \"Revoke\" and \"Reset\" cannot be chosen",
        |world, _, _| {
            expect!(
                !item_flag(world, "toolsPermissionGrant", "enabled")?
                    && !item_flag(world, "toolsPermissionRevoke", "enabled")?
                    && !item_flag(world, "toolsPermissionReset", "enabled")?,
                "{}",
                describe_tools(world)
            );
            Ok(())
        },
    );
    steps.step("the permission list (.+)", |world, c, _| {
        let (_, model) = combo_model(world, "toolsPermission")?;
        let has = |label: &str| model.iter().any(|m| m == label);
        let reset = item_flag(world, "toolsPermissionReset", "visible")?;
        let ios_only = ["Reminders", "Media library", "Face ID"];
        let fits = if c[0].contains("includes") {
            ios_only.iter().all(|l| has(l)) && reset
        } else {
            !ios_only.iter().any(|l| has(l)) && has("Physical activity") && !reset
        };
        expect!(fits, "{} (Reset shown {reset})", model.join(", "));
        Ok(())
    });

    // Push notifications.
    steps.step(
        &format!("the user types {Q} under \"Push notification\" and chooses \"Send\""),
        |world, c, _| {
            type_into(world, "toolsPushField", &c[0])?;
            click(world, "toolsPushSend")
        },
    );
    steps.step(
        &format!("the simulator is sent the notification for {Q}"),
        |world, c, _| {
            let app = c[0].clone();
            asked(world, |action| {
                action["type"] == "sendPush"
                    && action["appId"] == *app
                    && action["payload"] == "Order shipped"
            })
        },
    );

    // The event log.
    steps.step(
        "it says \"No events yet.\" until the simulator reports something",
        |world, _, _| {
            let panel = device_panel(world)?;
            world.wait_for_with(
                |w| panel.shows(w, "No events yet.").unwrap_or(false),
                describe_tools,
            )
        },
    );
    steps.step("the simulator reports events", |world, _, _| {
        let events: Vec<Value> = (1..=105)
            .map(|id| {
                json!({
                    "id": id,
                    "timestamp": format!("2026-09-23T10:00:{:02}Z", id % 60),
                    "summary": format!("Event {id}"),
                })
            })
            .collect();
        report(
            world,
            "/api/event-log/events",
            &json!({"events": events}).to_string(),
        )
    });
    steps.step("each is listed with its time and summary", |world, _, _| {
        let panel = device_panel(world)?;
        world.wait_for_with(
            |w| {
                let tools = tools_view(w);
                let Some(events) = tools["events"].as_array() else {
                    return false;
                };
                let first = format!(
                    "{}  {}",
                    text(&events[0]["time"]),
                    text(&events[0]["summary"])
                );
                events.len() == 100 && panel.shows(w, &first).unwrap_or(false)
            },
            describe_tools,
        )
    });
    steps.step("only the latest 100 are kept", |world, _, _| {
        let tools = tools_view(world);
        let events = tools["events"].as_array().cloned().unwrap_or_default();
        expect!(
            events.len() == 100 && events[0]["summary"] == "Event 6",
            "{}",
            describe_tools(world)
        );
        Ok(())
    });
    steps.step("the event log is open with entries", |world, _, _| {
        tools_open_for(world, "ios", "iPhone 17")?;
        click(world, "toolsEventLogToggle")?;
        world.wait_for_with(|w| tools_view(w)["eventLogOpen"] == true, describe_tools)?;
        report(
            world,
            "/api/event-log/events",
            "{\"events\":[{\"id\":1,\"timestamp\":\"2026-09-23T10:00:01Z\",\"summary\":\"Event 1\"}]}",
        )?;
        world.wait_for_with(
            |w| tools_view(w)["events"].as_array().is_some_and(|e| e.len() == 1),
            describe_tools,
        )
    });
    steps.step("the user closes \"Event log\"", |world, _, _| {
        click(world, "toolsEventLogToggle")
    });
    steps.step(
        "the simulator's events are no longer read",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let tools = tools_view(w);
                    tools["eventLogOpen"] != true
                        && tools["events"].as_array().is_none_or(Vec::is_empty)
                },
                describe_tools,
            )?;
            let open = feeds(world, "/api/event-log/events");
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakeHub>().is_some_and(|hub| {
                        !hub.feeds.iter().any(|(path, feed)| {
                            path.ends_with("/api/event-log/events") && connected(feed)
                        })
                    })
                },
                |w| {
                    format!(
                        "{} event feeds are still open; {}",
                        open.len(),
                        describe_tools(w)
                    )
                },
            )
        },
    );
    steps.step("the user opens \"Event log\" again", |world, _, _| {
        click(world, "toolsEventLogToggle")
    });
    steps.step("it starts empty", |world, _, _| {
        let panel = device_panel(world)?;
        world.wait_for_with(
            |w| {
                let tools = tools_view(w);
                tools["eventLogOpen"] == true
                    && tools["events"].as_array().is_none_or(Vec::is_empty)
                    && panel.shows(w, "No events yet.").unwrap_or(false)
            },
            describe_tools,
        )
    });

    // Device access and the accessibility overlay.
    steps.step(
        "the MC has given the client no device access yet",
        |world, _, _| no_access(world),
    );
    steps.step(
        &format!("the thread has {Q} open and the MC has given the client no device access yet"),
        |world, c, _| {
            tool_device(world, "ios", &c[0])?;
            no_access(world)
        },
    );
    steps.step(
        "\"Overlay element frames\" cannot be turned on",
        |world, _, _| {
            wide_panel(world)?;
            if tools_view(world)["open"] != true {
                open_tools(world)?;
            }
            expect!(
                !item_flag(world, "toolsAxOverlay", "enabled")?,
                "{}",
                describe_tools(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user turns on \"Overlay element frames\" in the tools",
        |world, _, _| {
            if fake_hub(world).android_ax.is_null() {
                ax_screen(world);
            }
            wide_panel(world)?;
            open_tools(world)?;
            click(world, "toolsAxOverlay")
        },
    );
    steps.step(
        "each accessibility element on the device is outlined over the screen with its label",
        |world, _, _| {
            let panel = device_panel(world)?;
            let overlay = panel.item(world, "deviceAxOverlay")?;
            refresh_until(world, |w| {
                tools_view(w)["axElements"]
                    .as_array()
                    .is_some_and(|e| e.len() == 1)
                    && panel.flag(w, overlay, "visible")
                    && panel.shows(w, "Buy").unwrap_or(false)
            })
        },
    );
    steps.step(
        "the outlines follow the device as its screen changes",
        |world, _, _| {
            let tree = &mut fake_hub(world).ax_tree;
            tree[0]["children"][0]["frame"]["x"] = json!(195);
            tree[0]["children"][0]["frame"]["y"] = json!(422);
            refresh_until(world, |w| {
                tools_view(w)["axElements"].as_array().is_some_and(|e| {
                    e.len() == 1 && e[0]["x"].as_f64().is_some_and(|x| (x - 0.5).abs() < 0.01)
                })
            })
        },
    );
    steps.step(
        "the user turns it off or shows another tab",
        |world, _, _| click(world, "toolsAxOverlay"),
    );
    steps.step("the outlines go away", |world, _, _| {
        let panel = device_panel(world)?;
        let overlay = panel.item(world, "deviceAxOverlay")?;
        world.wait_for_with(|w| !panel.flag(w, overlay, "visible"), describe_tools)
    });
    steps.step("the accessibility requests stall", |world, _, _| {
        fake_hub(world).stall_ax = true;
        Ok(())
    });
    steps.step("no second accessibility request is out", |world, _, _| {
        world.wait_for_with(
            |w| {
                w.mc.peek::<FakeHub>()
                    .is_some_and(|hub| hub.ax_requests > 0)
            },
            describe_tools,
        )?;
        let asked = fake_hub(world).ax_requests;
        // That nothing follows takes a few of the tools' refreshes to show.
        world.advance(1600)?;
        world.sync()?;
        let now = fake_hub(world).ax_requests;
        expect!(now == asked, "{now} requests out");
        Ok(())
    });
    steps.step(
        "the device's screen has more elements than the overlay shows",
        |world, _, _| {
            let mut nodes = vec![json!({"bounds": {"right": 1000, "bottom": 2000}})];
            nodes.extend((0..600).map(|n| {
                json!({
                    "text": format!("Item {n}"),
                    "bounds": {"left": 0, "top": n, "right": 100, "bottom": n + 1},
                })
            }));
            fake_hub(world).android_ax = json!({ "nodes": nodes });
            Ok(())
        },
    );
    steps.step(
        "the overlay outlines the first (\\d+) of them",
        |world, c, _| {
            let wanted: usize = c[0].parse().unwrap_or_default();
            refresh_until(world, |w| {
                tools_view(w)["axElements"]
                    .as_array()
                    .is_some_and(|e| e.len() == wanted)
            })
        },
    );

    // The backlog steps: renaming and floating, the picker's ordering and
    // messages, the stream's recovery, and the 3D body.

    // --- Tab names -----------------------------------------------------------
    steps.step(
        &format!("the thread has {Q} open in a tab"),
        |world, c, _| {
            add_device(world, "ios", &c[0], true);
            let device = device_named(fake_hub(world), &c[0])?;
            open_session(&mut world.mc, &device, THREAD);
            look(world)?;
            let tab = tab_of(world, &c[0])?;
            world.dispatch("rightPanel.activate", json!({"id": tab}))?;
            world.sync()?;
            let name = c[0].clone();
            world.wait_for_with(move |w| tab_titles(w).contains(&name), describe_ref)
        },
    );
    steps.step(
        &format!("the user renames the tab to {Q}"),
        |world, c, _| {
            let brick = panel_brick(world)?;
            let tab = tab_of(world, "iPhone 17")?;
            let item = brick.item(world, &format!("panelTab-{tab}"))?;
            let (x, y) = brick.at(world, item, 0.4, 0.5)?;
            world.click_at(x, y)?;
            world.click_at(x, y)?;
            let rename = format!("panelRename-{tab}");
            world.wait_for_with(
                |w| {
                    brick
                        .find(w, &rename)
                        .ok()
                        .flatten()
                        .is_some_and(|field| brick.flag(w, field, "visible"))
                },
                describe_ref,
            )?;
            world.type_text(&c[0])?;
            let down = key_event("return")?;
            world.key(&down)?;
            world.key(&KeyEvent::release(down.key))?;
            world.sync()
        },
    );
    steps.step(&format!("the tab is named {Q}"), |world, c, _| {
        let name = c[0].clone();
        world.wait_for_with(move |w| tab_titles(w).contains(&name), describe_ref)
    });
    steps.step(
        "the tab keeps that name when the device list is read again",
        |world, _, _| {
            let before = tab_titles(world);
            announce(&mut world.mc);
            world.sync()?;
            ThreadDevices::update(world.engine(), devices_object(world)?, |d| d.refresh());
            world.sync()?;
            expect!(tab_titles(world) == before, "{}", describe(world));
            Ok(())
        },
    );
    steps.step(
        &format!("the user is renaming the tab {Q}"),
        |world, c, _| {
            add_device(world, "ios", &c[0], true);
            let device = device_named(fake_hub(world), &c[0])?;
            open_session(&mut world.mc, &device, THREAD);
            look(world)?;
            let tab = tab_of(world, &c[0])?;
            world.dispatch("rightPanel.activate", json!({"id": tab}))?;
            world.sync()?;
            let brick = panel_brick(world)?;
            let item = brick.item(world, &format!("panelTab-{tab}"))?;
            let (x, y) = brick.at(world, item, 0.4, 0.5)?;
            world.click_at(x, y)?;
            world.click_at(x, y)?;
            let rename = format!("panelRename-{tab}");
            world.wait_for_with(
                |w| {
                    brick
                        .find(w, &rename)
                        .ok()
                        .flatten()
                        .is_some_and(|field| brick.flag(w, field, "visible"))
                },
                describe_ref,
            )
        },
    );
    steps.step(
        &format!("the user types {Q} and presses Escape"),
        |world, c, _| {
            panel_brick(world)?;
            world.type_text(&c[0])?;
            let down = key_event("escape")?;
            world.key(&down)?;
            world.key(&KeyEvent::release(down.key))?;
            world.sync()
        },
    );
    steps.step(&format!("the tab is still named {Q}"), |world, c, _| {
        world.sync()?;
        expect!(
            tab_titles(world).contains(&c[0])
                && !tab_titles(world).iter().any(|t| t == "Checkout flow"),
            "{}",
            describe(world)
        );
        Ok(())
    });

    // --- Two machines, one device id -----------------------------------------
    steps.step(
        "two connected machines each offer a simulator with the same device id",
        |world, _, _| {
            let hub = fake_hub(world);
            hub.second_host_id = "remote".into();
            hub.second_label = "laptop".into();
            add_device_on(world, "ios", "iPhone 17", true, HOST, "UDID-SHARED");
            add_device_on(world, "ios", "iPhone 17", true, "remote", "UDID-SHARED");
            Ok(())
        },
    );
    steps.step("the user opens both", |world, _, _| {
        add_device_tab(world)?;
        for host in [HOST, "remote"] {
            if active_tab(world) != "device" {
                add_device_tab(world)?;
            }
            let wanted = host.to_owned();
            world.wait_for_with(
                |w| {
                    view(w)["groups"].as_array().into_iter().flatten().any(|g| {
                        g["devices"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .any(|row| text(&row["hostId"]) == wanted)
                    })
                },
                describe_ref,
            )?;
            let row = view(world)["groups"]
                .as_array()
                .into_iter()
                .flatten()
                .flat_map(|g| g["devices"].as_array().cloned().unwrap_or_default())
                .find(|row| text(&row["hostId"]) == host)
                .unwrap_or(Value::Null);
            let panel = device_panel(world)?;
            panel.click(world, &format!("deviceRow-{}", text(&row["tab"])))?;
            world.sync()?;
            let tab = tab_id_of(host, "UDID-SHARED");
            world.wait_for_with(move |w| active_tab(w) == tab, describe_ref)?;
        }
        Ok(())
    });
    steps.step("each has its own tab", |world, _, _| {
        let ids: Vec<String> = world.state("panel")["tabs"]
            .as_array()
            .map(|tabs| tabs.iter().map(|t| text(&t["id"])).collect())
            .unwrap_or_default();
        expect!(
            ids.contains(&tab_id_of(HOST, "UDID-SHARED"))
                && ids.contains(&tab_id_of("remote", "UDID-SHARED")),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step("closing one leaves the other open", |world, _, _| {
        world.dispatch(
            "rightPanel.close",
            json!({"id": tab_id_of(HOST, "UDID-SHARED")}),
        )?;
        world.sync()?;
        let ids: Vec<String> = world.state("panel")["tabs"]
            .as_array()
            .map(|tabs| tabs.iter().map(|t| text(&t["id"])).collect())
            .unwrap_or_default();
        expect!(
            !ids.contains(&tab_id_of(HOST, "UDID-SHARED"))
                && ids.contains(&tab_id_of("remote", "UDID-SHARED")),
            "{}",
            describe(world)
        );
        Ok(())
    });

    // --- The picker's order and words ----------------------------------------
    steps.step(
        &format!("the thread's environment has the iOS Simulators {Q} stopped and {Q} running"),
        |world, c, _| {
            add_device(world, "ios", &c[0], false);
            add_device(world, "ios", &c[1], true);
            Ok(())
        },
    );
    steps.step(
        &format!("the thread's environment has the Android Emulators {Q} and {Q}, both running"),
        |world, c, _| {
            add_device(world, "android", &c[0], true);
            add_device(world, "android", &c[1], true);
            Ok(())
        },
    );
    steps.step(
        &format!("the thread's environment has the iOS Simulators {Q} and {Q} running"),
        |world, c, _| {
            add_device(world, "ios", &c[0], true);
            add_device(world, "ios", &c[1], true);
            // The open that follows stays in flight, so the picker can show
            // that only one device opens at a time.
            world.mc.hold("device.open");
            add_device_tab(world)
        },
    );
    steps.step(
        &format!("{Q} is listed before {Q} under {Q}"),
        |world, c, _| {
            let mut names = Vec::new();
            for listed in view(world)["groups"].as_array().into_iter().flatten() {
                if text(&listed["title"]) != c[2] {
                    continue;
                }
                for row in listed["devices"].as_array().into_iter().flatten() {
                    names.push(text(&row["name"]));
                }
            }
            let first = names.iter().position(|n| *n == c[0]);
            let second = names.iter().position(|n| *n == c[1]);
            expect!(
                first.is_some() && first < second,
                "the order is {}",
                names.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the machine {Q} has the iOS Simulator {Q} on iOS 26.0, (running|stopped)"),
        |world, c, _| {
            fake_hub(world).host_label.clone_from(&c[0]);
            add_device(world, "ios", &c[1], c[2] == "running");
            Ok(())
        },
    );
    steps.step(
        &format!("the row for {Q} reads \"([^\"]* · [^\"]*)\""),
        |world, c, _| {
            let (name, detail) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                move |w| text(&row_of(w, &name, "")["detail"]) == detail,
                describe_ref,
            )
        },
    );
    steps.step(&format!("the row offers {Q}"), |world, c, _| {
        let offered = view(world)["groups"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|g| {
                g["devices"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|row| text(&row["action"]) == c[0])
            });
        expect!(offered, "{}", describe(world));
        Ok(())
    });
    steps.step(
        &format!("{Q} cannot be chosen until {Q} is open"),
        |world, c, _| {
            // The first open is in flight (the Given held it); the other row
            // must be disabled while it is.
            expect!(
                !text(&view(world)["pendingKey"]).is_empty(),
                "{}",
                describe(world)
            );
            let row = row_of(world, &c[0], "");
            let panel = device_panel(world)?;
            let item = panel.item(world, &format!("deviceRow-{}", text(&row["tab"])))?;
            expect!(!panel.flag(world, item, "enabled"), "{}", describe(world));
            world.mc.answer_held();
            world.sync()
        },
    );
    steps.step(&format!("the Device tab says {Q}"), |world, c, _| {
        let words = c[0].clone();
        world.wait_for_with(
            move |w| tab_says(w, &words),
            |w| format!("{}\n{}", tab_words(w).join(" | "), describe_ref(w)),
        )
    });
    steps.step(
        &format!("the user opened {Q}, which is already running"),
        |world, c, _| {
            add_device(world, "ios", &c[0], true);
            world.mc.hold("device.open");
            add_device_tab(world)?;
            open_from_picker(world, &c[0])
        },
    );
    steps.step(
        &format!("the user opened {Q}, which is stopped"),
        |world, c, _| {
            add_device(world, "ios", &c[0], false);
            world.mc.hold("device.open");
            add_device_tab(world)?;
            open_from_picker(world, &c[0])
        },
    );
    steps.step(
        "the device tools are still being installed",
        |world, _, _| {
            fake_hub(world).host_status = "installing".into();
            add_device_tab(world)
        },
    );
    steps.step(
        "the device tools are being installed on the thread's environment",
        |world, _, _| {
            fake_hub(world).host_status = "installing".into();
            Ok(())
        },
    );
    steps.step("the list of devices has not arrived yet", |world, _, _| {
        let hub = fake_hub(world);
        hub.hold_state = true;
        hub.looking = true;
        world.mc.projects.insert(
            PROJECT.into(),
            json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": format!("/work/{PROJECT}"), "scripts": []}),
        );
        world.connect()?;
        world.sync()?;
        look_at_thread(world, PROJECT)?;
        world.dispatch("rightPanel.add", json!({"kind": "device"}))?;
        world.sync()
    });
    steps.step(&format!("the thread has {Q} starting"), |world, c, _| {
        add_device(world, "ios", &c[0], false);
        fake_hub(world)
            .booting
            .push(json!({"name": c[0], "threadId": THREAD}));
        look(world)
    });
    steps.step(&format!("{Q} is running"), |world, c, _| {
        fake_hub(world).booting.retain(|b| text(&b["name"]) != c[0]);
        announce(&mut world.mc);
        world.sync()
    });
    steps.step("that message goes away", |world, _, _| {
        world.wait_for_with(|w| text(&view(w)["starting"]).is_empty(), describe_ref)
    });
    steps.step(
        &format!("the device hub is installing on the thread's environment and reports {Q}"),
        |world, c, _| {
            let hub = fake_hub(world);
            hub.host_status = "installing".into();
            hub.host_detail.clone_from(&c[0]);
            Ok(())
        },
    );
    steps.step(
        &format!("the device hub failed to start on the thread's environment and says {Q}"),
        |world, c, _| {
            let hub = fake_hub(world);
            hub.host_status = "failed".into();
            hub.host_detail.clone_from(&c[0]);
            Ok(())
        },
    );
    steps.step(
        "the device hub failed to start on the thread's environment without saying why",
        |world, _, _| {
            fake_hub(world).host_status = "failed".into();
            Ok(())
        },
    );
    steps.step("it has no simulators or emulators", |world, _, _| {
        fake_hub(world);
        Ok(())
    });
    steps.step(
        &format!("the device hub is ready and reports {Q}"),
        |world, c, _| {
            fake_hub(world).host_detail.clone_from(&c[0]);
            add_device(world, "ios", "iPhone 17", true);
            Ok(())
        },
    );
    steps.step(
        &format!("the tab shows {Q} above the list of devices"),
        |world, c, _| {
            let words = c[0].clone();
            world.wait_for_with(
                move |w| text(&view(w)["hostDetail"]) == words && device_panel_shows(w, &words),
                describe_ref,
            )
        },
    );
    steps.step(
        "the thread's environment has the Android SDK",
        |world, _, _| {
            fake_hub(world).availability.push((
                "android".into(),
                json!({"platform": "android", "available": true}),
            ));
            Ok(())
        },
    );
    steps.step("it has no Android virtual devices", |world, _, _| {
        fake_hub(world);
        Ok(())
    });
    steps.step(
        "the user added a Device tab on an environment with no simulators",
        |world, _, _| {
            fake_hub(world);
            add_device_tab(world)
        },
    );
    steps.step(
        &format!("the machine gains the iOS Simulator {Q}"),
        |world, c, _| {
            add_device(world, "ios", &c[0], true);
            Ok(())
        },
    );
    steps.step(
        "the tab does not offer \"Refresh devices\"",
        |world, _, _| {
            let panel = device_panel(world)?;
            let refresh = panel.find(world, "deviceRefresh")?;
            expect!(
                view(world)["canRefresh"] != true
                    && refresh.is_none_or(|item| !panel.flag(world, item, "visible")),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("device support is on and {Q} was added since the list was last read"),
        |world, c, _| {
            look(world)?;
            add_device_tab(world)?;
            add_device(world, "ios", &c[0], true);
            world.dispatch("rightPanel.add", json!({"kind": "diff"}))?;
            world.sync()
        },
    );
    steps.step("device support is off", |world, _, _| {
        fake_hub(world).host_status = "disabled".into();
        announce(&mut world.mc);
        world.sync()
    });
    steps.step(
        "nothing is installed or started on the environment",
        |world, _, _| {
            let (lists, configures) = {
                let hub = fake_hub(world);
                (hub.lists.len(), hub.configures.len())
            };
            world.sync()?;
            let hub = fake_hub(world);
            expect!(
                hub.configures.len() == configures && hub.lists.len() == lists,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the thread has {Q} on iOS 26.0 open on the machine {Q}"),
        |world, c, _| {
            fake_hub(world).host_label.clone_from(&c[1]);
            add_device(world, "ios", &c[0], true);
            let device = device_named(fake_hub(world), &c[0])?;
            open_session(&mut world.mc, &device, THREAD);
            look(world)?;
            let tab = tab_of(world, &c[0])?;
            world.dispatch("rightPanel.activate", json!({"id": tab}))?;
            world.sync()
        },
    );
    steps.step(&format!("the tab's header reads {Q}"), |world, c, _| {
        let words = c[0].clone();
        world.wait_for_with(
            move |w| text(&screen_of(w)["description"]) == words && device_panel_shows(w, &words),
            describe_ref,
        )
    });

    // --- Side by side in the centre -------------------------------------------
    steps.step(
        &format!("the user puts {Q} and {Q} side by side in the centre"),
        |world, c, _| side_by_side(world, &c[0], &c[1]),
    );
    steps.step(
        &format!("{Q} and {Q} both stream at once"),
        |world, c, _| both_stream(world, &c[0], &c[1]),
    );
    steps.step(
        &format!("{Q} and {Q} stream side by side in the centre"),
        |world, c, _| {
            side_by_side(world, &c[0], &c[1])?;
            both_stream(world, &c[0], &c[1])
        },
    );
    steps.step(
        &format!("the user opens it side by side with {Q}"),
        |world, c, _| {
            let panel = device_panel(world)?;
            world.wait_for_with(
                |w| {
                    panel
                        .find(w, "deviceCompare")
                        .ok()
                        .flatten()
                        .is_some_and(|item| panel.flag(w, item, "visible"))
                },
                describe_ref,
            )?;
            panel.click(world, "deviceCompare")?;
            let tab = tab_of(world, &c[0])?;
            let entry = format!("deviceCompare-{tab}");
            let name = c[0].clone();
            let looked_for = entry.clone();
            world.wait_for_with(
                move |w| {
                    panel.shows(w, &name).unwrap_or(false)
                        && panel
                            .find(w, &looked_for)
                            .ok()
                            .flatten()
                            .is_some_and(|item| panel.flag(w, item, "visible"))
                },
                describe_ref,
            )?;
            panel.click(world, &entry)?;
            world.sync()
        },
    );
    steps.step(
        &format!("{Q} and {Q} show side by side in the centre"),
        |world, c, _| {
            let wanted = json!([tab_of(world, &c[0])?, tab_of(world, &c[1])?]);
            world.wait_for_with(
                move |w| {
                    let state = w.state("panel");
                    let stage = at(&state, "stage");
                    text(&stage["layout"]) == "columns" && stage["panes"] == wanted
                },
                |w| show(&at(&w.state("panel"), "stage")),
            )
        },
    );
    steps.step(
        &format!("the user shows only {Q} on the stage"),
        |world, c, _| {
            keep_streams(world)?;
            let tab = tab_of(world, &c[0])?;
            let pane = at(&world.state("panel"), "stage.panes")
                .as_array()
                .and_then(|panes| panes.iter().position(|p| text(p) == tab))
                .unwrap_or(0);
            world.dispatch("stage.focusPane", json!({"pane": pane}))?;
            world.dispatch("stage.layout", json!({"layout": "single"}))?;
            world.sync()
        },
    );
    steps.step(&format!("the user closes the device {Q}"), |world, c, _| {
        keep_streams(world)?;
        let tab = tab_of(world, &c[0])?;
        world.dispatch("rightPanel.close", json!({"id": tab}))?;
        world.sync()
    });
    steps.step(
        &format!("the user moves {Q} to the centre"),
        |world, c, _| {
            keep_streams(world)?;
            let tab = tab_of(world, &c[0])?;
            world.dispatch("rightPanel.dock", json!({"id": tab, "dock": "stage"}))?;
            world.sync()?;
            world.wait_for_with(
                move |w| {
                    at(&w.state("panel"), "stage.panes")
                        .as_array()
                        .is_some_and(|panes| panes.iter().any(|p| text(p) == tab))
                },
                |w| show(&at(&w.state("panel"), "stage")),
            )
        },
    );
    steps.step(&format!("{Q} streams nothing"), |world, c, _| {
        let name = c[0].clone();
        world.wait_for_with(
            move |w| {
                let status = stream_named(w, &name).0;
                status.is_empty() || status == "idle"
            },
            describe_ref,
        )?;
        let asked = video_requests_of(world, &c[0])?;
        world.sync()?;
        expect!(
            video_requests_of(world, &c[0])? == asked,
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(&format!("{Q} keeps its stream"), |world, c, _| {
        world.sync()?;
        let asked = video_requests_of(world, &c[0])?;
        let kept = fake_hub(world)
            .kept_counts
            .get(&c[0])
            .copied()
            .unwrap_or_default();
        expect!(
            stream_named(world, &c[0]).0 == "streaming" && asked == kept,
            "{} asked for video {asked} times, {kept} before; {}",
            c[0],
            describe(world)
        );
        Ok(())
    });

    // --- Watching: progress, an expired stream, the input connection ---------
    steps.step(
        &format!("the thread has the iOS Simulator {Q} opening"),
        |world, c, _| {
            add_device(world, "ios", &c[0], true);
            fake_hub(world).shared.silent.store(true, Ordering::SeqCst);
            world.mc.hold("device.open");
            add_device_tab(world)?;
            open_from_picker(world, &c[0])
        },
    );
    steps.step(
        &format!("the tab shows its progress as {Q}"),
        |world, c, _| {
            let words = c[0].clone();
            world.wait_for_with(move |w| device_panel_shows(w, &words), describe_ref)
        },
    );
    steps.step(
        "the device is open and no picture has arrived yet",
        |world, _, _| {
            world.mc.answer_held();
            world.sync()?;
            world.wait_for_with(|w| stream_of(w).0 == "connecting", describe_ref)
        },
    );
    steps.step(
        "the MC refuses the stream because its access has expired",
        |world, _, _| {
            let hub = fake_hub(world);
            hub.expired = true;
            hub.accepted_ticket.clear();
            // The stream in flight ends; its next request is the refused one.
            for video in hub.videos.drain(..) {
                let _ = video.shutdown(Shutdown::Both);
            }
            world.sync()
        },
    );
    steps.step("the tab asks the MC for fresh access", |world, _, _| {
        world.wait_for_with(
            |w| {
                w.mc.peek::<FakeHub>()
                    .is_some_and(|hub| hub.ticket_requests > 0)
            },
            describe_ref,
        )
    });
    steps.step(
        "the tab asks the MC for fresh access again",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakeHub>()
                        .is_some_and(|hub| hub.ticket_requests > 1)
                },
                describe_ref,
            )
        },
    );
    steps.step("the MC is slow to give fresh access", |world, _, _| {
        fake_hub(world).hold_tickets = true;
        Ok(())
    });
    steps.step(
        "the user reconnects before the MC answers",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakeHub>()
                        .is_some_and(|hub| hub.ticket_requests == 1)
                },
                describe_ref,
            )?;
            let stream = stream_object(world)?;
            hal_c2_shell::device::stream::DeviceStream::update(
                world.engine(),
                stream,
                hal_c2_shell::device::stream::Core::reconnect,
            );
            // Refused again, the new connection asks for its own ticket.
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakeHub>()
                        .is_some_and(|hub| hub.ticket_requests == 2)
                },
                describe_ref,
            )
        },
    );
    steps.step("the MC answers the earlier request", |world, _, _| {
        if fake_hub(world).held_tickets.is_empty() {
            fail!("a held ticket request");
        }
        let (respond, ticket) = fake_hub(world).held_tickets.remove(0);
        answer_ticket(&mut world.mc, respond, &ticket);
        // That the tab ignores it takes a moment to show.
        world.sync()?;
        world.sync()
    });
    steps.step("the tab does not use that answer", |world, _, _| {
        for request in requests(world) {
            expect!(!request.contains("wsTicket=fresh1"), "{request}");
        }
        expect!(stream_of(world).0 == "connecting", "{}", describe(world));
        Ok(())
    });
    steps.step("the MC answers the later request", |world, _, _| {
        fake_hub(world).hold_tickets = false;
        if fake_hub(world).held_tickets.is_empty() {
            fail!("a second held ticket request");
        }
        let (respond, ticket) = fake_hub(world).held_tickets.remove(0);
        answer_ticket(&mut world.mc, respond, &ticket);
        Ok(())
    });
    steps.step(
        &format!("the tab {Q} shows the device's screen again"),
        |world, c, _| wait_for_screen(world, &c[0]),
    );
    steps.step(
        &format!("the device's input connection drops with the reason {Q}"),
        |world, c, _| {
            drop_input(world, &c[0]);
            world.sync()?;
            world.wait_for_with(|w| !stream_of(w).2, describe_ref)
        },
    );
    steps.step(
        &format!("the picture stays and the tab says {Q}"),
        |world, c, _| {
            let screen = screen_item(world)?;
            let panel = device_panel(world)?;
            let words = c[0].clone();
            world.wait_for_with(
                move |w| {
                    device_panel_shows(w, &words)
                        && panel.flag(w, screen, "hasFrame")
                        && panel.flag(w, screen, "visible")
                },
                |w| {
                    format!(
                        "{}; the screen colour is {:?}",
                        describe_ref(w),
                        drawn_at_screen(w, screen)
                    )
                },
            )?;
            expect!(drawn_red(world, screen), "{}", describe_screen(world));
            Ok(())
        },
    );
    steps.step("the device's buttons cannot be used", |world, _, _| {
        let panel = device_panel(world)?;
        let home = panel.item(world, "deviceHome")?;
        expect!(!panel.flag(world, home, "enabled"), "{}", describe(world));
        Ok(())
    });
    steps.step("the input connection returns", |world, _, _| {
        fake_hub(world).drop_inputs = false;
        world.wait_for_with(|w| stream_of(w).2, describe_ref)
    });
    steps.step(
        "the message goes away and the buttons work again",
        |world, _, _| {
            let panel = device_panel(world)?;
            world.wait_for_with(
                move |w| {
                    let hidden = panel
                        .find(w, "deviceInputStatus")
                        .ok()
                        .flatten()
                        .is_none_or(|item| !panel.flag(w, item, "visible"));
                    let enabled = panel
                        .find(w, "deviceHome")
                        .ok()
                        .flatten()
                        .is_some_and(|item| panel.flag(w, item, "enabled"));
                    hidden && enabled
                },
                describe_ref,
            )
        },
    );
    steps.step(
        "the user makes the panel narrower than the device is wide",
        |world, _, _| {
            device_panel(world)?;
            world.resize(220.0, 900.0)
        },
    );
    steps.step(
        "the device is shown smaller with its own proportions",
        |world, _, _| {
            let screen = screen_item(world)?;
            let panel = device_panel(world)?;
            world.wait_for_with(
                move |w| {
                    let aspect = stream_object(w)
                        .ok()
                        .and_then(|stream| {
                            hal_c2_shell::device::stream::DeviceStream::read(
                                w.engine(),
                                stream,
                                |c| c.aspect(),
                            )
                        })
                        .unwrap_or(0.0);
                    let (width, height) = item_size(&panel, w, screen);
                    width > 0.0 && (width / height - aspect).abs() < 0.02 && width <= 224.0
                },
                |w| {
                    format!(
                        "{}; the screen colour is {:?}",
                        describe_ref(w),
                        drawn_at_screen(w, screen)
                    )
                },
            )?;
            expect!(drawn_red(world, screen), "{}", describe_screen(world));
            Ok(())
        },
    );
    steps.step(
        "a touch at the middle of the shown screen is sent as the middle of the device",
        |world, _, _| {
            fake_hub(world).shared.seen().binary.clear();
            tap(world, 0.5, 0.5)?;
            world.wait_for_with(
                |w| {
                    let Some(hub) = w.mc.peek::<FakeHub>() else {
                        return false;
                    };
                    let touches: Vec<Value> = hub
                        .shared
                        .seen()
                        .binary
                        .iter()
                        .filter(|m| m.first() == Some(&0x03))
                        .map(|m| serde_json::from_slice(&m[1..]).unwrap_or(Value::Null))
                        .collect();
                    touches.len() == 2 && near(&touches[0]["x"], 0.5) && near(&touches[0]["y"], 0.5)
                },
                |_| "the device to receive a touch at its middle".into(),
            )
        },
    );

    // --- Driving: the tab's buttons, where the keys go, a command chord ------
    steps.step("the tab offers (?!to )(.+)", |world, c, _| {
        // The Given opened the device; showing its tab is what offers buttons.
        let session = fake_hub(world)
            .sessions
            .last()
            .cloned()
            .unwrap_or(Value::Null);
        let name = fake_hub(world)
            .devices
            .iter()
            .find(|d| d["id"] == session["deviceId"])
            .map_or_else(String::new, |d| text(&d["name"]));
        show_device_tab(world, &name)?;
        let panel = device_panel(world)?;
        let buttons = [
            ("Home", "deviceHome"),
            ("Back", "deviceBack"),
            ("Recents", "deviceRecents"),
            ("Rotate", "deviceRotate"),
        ];
        let wanted: Vec<String> = c[0]
            .split(", ")
            .flat_map(|part| part.split(" and "))
            .map(str::to_owned)
            .collect();
        for (label, object) in buttons {
            let item = panel.item(world, object)?;
            expect!(
                panel.flag(world, item, "visible") == wanted.iter().any(|w| w == label),
                "{label} offered: {}, wanted among {}",
                panel.flag(world, item, "visible"),
                wanted.join(", ")
            );
        }
        Ok(())
    });
    steps.step(
        &format!("the user types {Q} in the tab's tools instead of on the screen"),
        |world, c, _| {
            fake_hub(world).settings = json!({"appearance": "light"});
            // Wide enough that the tools sit beside the screen, not over it.
            world.resize(900.0, 900.0)?;
            open_tools(world)?;
            fake_hub(world).shared.seen().binary.clear();
            type_into(world, "toolsField-url", &c[0])
        },
    );
    steps.step("the device receives no key", |world, _, _| {
        world.sync()?;
        expect!(
            ios_input(world, 0x06).is_empty() && fake_hub(world).shared.seen().text.is_empty(),
            "{}",
            describe_input(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the user clicks the device's screen and types {Q}"),
        |world, c, _| {
            fake_hub(world).shared.seen().binary.clear();
            tap(world, 0.5, 0.5)?;
            fake_hub(world).shared.seen().binary.clear();
            press(world, &c[0].chars().next().unwrap_or('a').to_string())
        },
    );
    steps.step("the user clicked the device's screen", |world, _, _| {
        watch(world, "iPhone 17")?;
        tap(world, 0.5, 0.5)?;
        fake_hub(world).shared.seen().binary.clear();
        Ok(())
    });
    steps.step(
        &format!("the user presses Command with {Q}"),
        |world, c, _| {
            let key = if c[0] == "K" { "meta+k" } else { "meta+r" };
            press(world, key)?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user holds Command with {Q}"),
        |world, _c, _| {
            let down = key_event("meta+r")?;
            world.key(&down)?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user presses Command with {Q} again"),
        |world, _c, _| {
            fake_hub(world).shared.seen().binary.clear();
            press(world, "meta+r")?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user holds Command with {Q} and lets go of Command first"),
        |world, _c, _| {
            let down = key_event("meta+r")?;
            world.key(&down)?;
            // Qt::Key_Meta letting go, as desktop-qt's step sends it.
            world.key(&KeyEvent::release(0x0100_0022))?;
            world.sync()
        },
    );
    steps.step("the device has both keys up", |world, _, _| {
        world.wait_for_with(
            |w| {
                let Some(hub) = w.mc.peek::<FakeHub>() else {
                    return false;
                };
                let keys: Vec<Value> = hub
                    .shared
                    .seen()
                    .binary
                    .iter()
                    .filter(|m| m.first() == Some(&0x06))
                    .map(|m| serde_json::from_slice(&m[1..]).unwrap_or(Value::Null))
                    .collect();
                let downs: i64 = keys
                    .iter()
                    .map(|k| if k["type"] == "down" { 1 } else { -1 })
                    .sum();
                !keys.is_empty() && downs == 0
            },
            |_| "both keys up on the device".into(),
        )
    });
    steps.step(
        &format!("on a Mac the app keeps every Command chord but Command with {Q}"),
        |world, _c, _| {
            let panel = device_panel(world)?;
            let stage = panel.item(world, "deviceStage")?;
            let command =
                brick_invoke(world, stage, "commandModifierOn", &[QmlValue::from("osx")])?;
            // Qt::ControlModifier, what Qt calls Command on a Mac.
            let control = match command {
                QmlValue::Int(n) => i64::from(n),
                QmlValue::Real(r) => r as i64,
                _ => 0,
            };
            expect!(
                control == 0x0400_0000,
                "on a Mac Qt calls Command Control; it is {control}"
            );
            let owns = |world: &mut World, key: i32, modifiers: i64| -> Outcome<bool> {
                let event = QmlValue::Map(Arc::new(vec![
                    ("key".into(), QmlValue::Int(key)),
                    ("modifiers".into(), QmlValue::Real(modifiers as f64)),
                ]));
                let got = brick_invoke(world, stage, "appOwns", &[event, command.clone()])?;
                Ok(matches!(got, QmlValue::Bool(true)))
            };
            // Qt::Key_K, Qt::Key_R, Qt::Key_A; Control and Meta modifiers
            // (Qt::ControlModifier 0x04000000, Qt::MetaModifier 0x10000000).
            expect!(
                owns(world, 0x4b, 0x0400_0000)?,
                "Command+K went to the device"
            );
            expect!(
                !owns(world, 0x52, 0x0400_0000)?,
                "Command+R stayed with the app"
            );
            expect!(
                owns(world, 0x52, 0x1000_0000)?,
                "Control+R went to the device"
            );
            expect!(!owns(world, 0x41, 0)?, "a plain key stayed with the app");
            Ok(())
        },
    );
    steps.step("the app handles the shortcut", |world, _, _| {
        // The stage turns the key away: it never reaches the device, so the
        // window's own shortcut handling sees it.
        world.sync()?;
        expect!(
            ios_input(world, 0x06).is_empty(),
            "{}",
            describe_input(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the device receives the key {Q} with Command"),
        |world, c, _| {
            let letter = c[0].chars().next().unwrap_or('a').to_ascii_lowercase();
            let usage = 0x04 + (letter as i64 - 'a' as i64);
            world.wait_for_with(
                move |w| {
                    let Some(hub) = w.mc.peek::<FakeHub>() else {
                        return false;
                    };
                    let keys: Vec<Value> = hub
                        .shared
                        .seen()
                        .binary
                        .iter()
                        .filter(|m| m.first() == Some(&0x06))
                        .map(|m| serde_json::from_slice(&m[1..]).unwrap_or(Value::Null))
                        .collect();
                    let mut meta_down = false;
                    let mut key_down = false;
                    for key in &keys {
                        if key["usage"].as_i64() == Some(0xe3) && key["type"] == "down" {
                            meta_down = true;
                        }
                        if meta_down
                            && key["usage"].as_i64() == Some(usage)
                            && key["type"] == "down"
                        {
                            key_down = true;
                        }
                    }
                    key_down
                },
                |_| "the device to receive the key with Command".into(),
            )
        },
    );

    // --- Closing and floating --------------------------------------------------
    steps.step(
        &format!("the MC cannot shut the device down because {Q}"),
        |world, c, _| {
            fake_hub(world).refuse_close.clone_from(&c[0]);
            Ok(())
        },
    );
    steps.step(
        &format!("the right panel still has the {Q} tab"),
        |world, c, _| {
            let name = c[0].clone();
            world.wait_for_with(move |w| tab_titles(w).contains(&name), describe_ref)
        },
    );
    steps.step("the user floats the device over the chat", |world, _, _| {
        let panel = device_panel(world)?;
        panel.click(world, "deviceFloat")?;
        world.sync()
    });
    steps.step("the device floats over the conversation", |world, _, _| {
        world.wait_for_with(
            |w| {
                let Some(hub) = w.mc.peek::<FakeHub>() else {
                    return false;
                };
                let Some(device) = hub.devices.iter().find(|d| text(&d["name"]) == "iPhone 17")
                else {
                    return false;
                };
                let tab = tab_id_of(HOST, &text(&device["id"]));
                text(&w.state("panel")["floatingDevice"]) == tab
                    && stream_named(w, "iPhone 17").0 == "streaming"
            },
            describe_ref,
        )
    });
    steps.step("the user opens the right panel", |world, _, _| {
        world.with::<RightPanel, _>(|p, engine| p.set_open(engine, true))?;
        world.sync()
    });
    steps.step("the device no longer floats", |world, _, _| {
        let state = world.state("panel");
        expect!(
            (state["floatingDevice"].is_null() || text(&state["floatingDevice"]).is_empty())
                && world.with::<RightPanel, _>(|p, _| p.is_open())?,
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the right panel closes", |world, _, _| {
        expect!(
            !world.with::<RightPanel, _>(|p, _| p.is_open())?,
            "{}",
            describe(world)
        );
        Ok(())
    });

    // --- The 3D body ------------------------------------------------------------
    steps.step(
        "the user shows the device in 3D and drags across it",
        |world, _, _| {
            show_in_3d(world)?;
            let body = body_item(world).ok_or_else(|| Failure("no 3D body".into()))?;
            let panel = device_panel(world)?;
            let (fx, fy) = panel.at(world, body, 0.3, 0.5)?;
            let (tx, ty) = panel.at(world, body, 0.75, 0.5)?;
            world.pointer(|now| PointerEvent::press(fx, fy, now))?;
            world.pointer(|now| PointerEvent::moved(tx, ty, Default::default(), now))?;
            world.sync()?;
            // The drag's turn is read before its release settles it.
            let yaw = panel.read(world, body, "yaw");
            fake_hub(world).dragged_yaw = match yaw {
                QmlValue::Real(v) => v,
                QmlValue::Int(v) => v as f64,
                _ => 0.0,
            };
            world.pointer(|now| PointerEvent::release(tx, ty, now))?;
            world.sync()
        },
    );
    steps.step("the body turns with the drag", |world, _, _| {
        let yaw = fake_hub(world).dragged_yaw;
        expect!(yaw.abs() > 5.0, "the drag turned {yaw}");
        Ok(())
    });
    steps.step(
        "when the drag ends the body settles on the nearest view that faces its screen",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let Some(panel) = w.peek_part::<Panel>().and_then(|p| p.0) else {
                        return false;
                    };
                    body_item(w).is_some_and(|body| panel.flag(w, body, "settled"))
                },
                |w| describe_ref(w).to_string(),
            )
        },
    );
    steps.step("the 3D screen stands upright on its body", |world, _, _| {
        let body = body_item(world).ok_or_else(|| Failure("no 3D body".into()))?;
        let panel = device_panel(world)?;
        let screen = panel
            .find_in(world, body, "deviceBodyScreen")?
            .ok_or_else(|| Failure("no screen on the body".into()))?;
        world.wait_for_with(
            move |w| panel.read(w, screen, "rotation") != QmlValue::Real(0.0),
            describe_ref,
        )?;
        let rotation = panel.read(world, screen, "rotation");
        let wanted = hal_c2_shell::device::stream::DeviceStream::read(
            world.engine(),
            stream_object(world)?,
            |c| c.rotation(),
        )
        .unwrap_or(0);
        let got = match rotation {
            QmlValue::Real(v) => v as i32,
            QmlValue::Int(v) => v as i32,
            _ => 0,
        };
        expect!(got == wanted, "{}", describe(world));
        let texture = match panel.read(world, screen, "parent") {
            QmlValue::Object(parent) => parent,
            _ => fail!("the screen has no parent"),
        };
        let (tw, th) = item_size(&panel, world, texture);
        let (_sw, sh) = item_size(&panel, world, screen);
        expect!(tw > th && (sh - tw).abs() < 0.5, "{}", describe(world));
        Ok(())
    });
    steps.step(
        "the picture is decoded for the flat view's size",
        |world, _, _| {
            let screen = screen_item(world)?;
            let panel = device_panel(world)?;
            world.wait_for_with(
                move |w| {
                    let limit = stream_object(w)
                        .ok()
                        .and_then(|stream| {
                            hal_c2_shell::device::stream::DeviceStream::read(
                                w.engine(),
                                stream,
                                |c| c.maximum_size(),
                            )
                        })
                        .unwrap_or((0, 0));
                    let (width, height) = item_size(&panel, w, screen);
                    panel.flag(w, screen, "visible")
                        && limit == (width.round() as u32, height.round() as u32)
                },
                |w| {
                    let limit = stream_object(w)
                        .ok()
                        .and_then(|stream| {
                            hal_c2_shell::device::stream::DeviceStream::read(
                                w.engine(),
                                stream,
                                |c| c.maximum_size(),
                            )
                        })
                        .unwrap_or((0, 0));
                    let (width, height) = item_size(&panel, w, screen);
                    format!(
                        "a limit of {}x{} for a screen of {width}x{height}",
                        limit.0, limit.1
                    )
                },
            )
        },
    );
    steps.step("the user shows the device in 3D", |world, _, _| {
        show_in_3d(world)
    });
    steps.step("the device has no 3D model", |world, _, _| look(world));
    steps.step("the 3D model cannot be downloaded", |world, _, _| {
        show_in_3d(world)?;
        let body = body_item(world).ok_or_else(|| Failure("no 3D body".into()))?;
        device_panel(world)?.write(
            world,
            body,
            "modelOverride",
            QmlValue::from("models/no-such-model.glb"),
        )
    });
    steps.step("the 3D model file is not a valid model", |world, _, _| {
        let path = world.home_dir().join("hal-c2-not-a-model.glb");
        std::fs::write(&path, "this is not a glTF model").map_err(|e| Failure(e.to_string()))?;
        show_in_3d(world)?;
        let body = body_item(world).ok_or_else(|| Failure("no 3D body".into()))?;
        device_panel(world)?.write(
            world,
            body,
            "modelOverride",
            QmlValue::from(format!("file://{}", path.display()).as_str()),
        )
    });
    steps.step(
        "a plain body of the device's family is shown instead of an error",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let Some(panel) = w.peek_part::<Panel>().and_then(|p| p.0) else {
                        return false;
                    };
                    body_item(w).is_some_and(|body| panel.flag(w, body, "plain"))
                        && stream_of(w).0 != "error"
                },
                |w| describe_ref(w).to_string(),
            )
        },
    );
    steps.step("the device's screen is still live on it", |world, _, _| {
        world.wait_for_with(
            |w| {
                stream_of(w).0 == "streaming"
                    && w.peek_part::<Panel>()
                        .and_then(|p| p.0)
                        .is_some_and(|panel| {
                            panel
                                .find(w, "deviceScreen")
                                .ok()
                                .flatten()
                                .is_some_and(|screen| panel.flag(w, screen, "hasFrame"))
                        })
            },
            |w| describe_ref(w).to_string(),
        )
    });
    for (words, in3d, attached) in [
        ("in 3D with the Magic Keyboard attached", true, true),
        (
            "in the flat view with the Magic Keyboard attached",
            false,
            true,
        ),
        ("in 3D with no keyboard attached", true, false),
        ("in portrait with no keyboard attached", false, false),
    ] {
        steps.step(
            &format!("the user is viewing the iOS Simulator \"iPad Pro 13-inch\" {words}"),
            move |world, _, _| viewing_ipad(world, in3d, attached),
        );
    }
    steps.step("the user switches to the flat view", |world, _, _| {
        device_panel(world)?.click(world, "device3dToggle")?;
        world.sync()
    });
    steps.step("the user switches to the 3D view", |world, _, _| {
        show_in_3d(world)
    });
    steps.step("the user attaches the Magic Keyboard", |world, _, _| {
        device_panel(world)?.click(world, "deviceKeyboardToggle")?;
        world.sync()
    });
    steps.step("the user detaches the Magic Keyboard", |world, _, _| {
        device_panel(world)?.click(world, "deviceKeyboardToggle")?;
        world.sync()
    });
    steps.step("the live screen fills the panel", |world, _, _| {
        let screen = screen_item(world)?;
        let panel = device_panel(world)?;
        world.wait_for_with(
            move |w| panel.flag(w, screen, "visible") && drawn_red(w, screen),
            |w| {
                format!(
                    "{}; the screen colour is {:?}",
                    describe_ref(w),
                    drawn_at_screen(w, screen)
                )
            },
        )
    });
    steps.step("the Magic Keyboard is not shown", |world, _, _| {
        let panel = device_panel(world)?;
        let showing = panel
            .root(world)
            .is_some_and(|root| panel.flag(world, root, "show3d"));
        expect!(
            !showing || body_item(world).is_none(),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the Magic Keyboard is shown attached to the iPad",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let Some(panel) = w.peek_part::<Panel>().and_then(|p| p.0) else {
                        return false;
                    };
                    let Some(body) = body_item(w) else {
                        return false;
                    };
                    panel
                        .find_in(w, body, "deviceMagicKeyboard")
                        .ok()
                        .flatten()
                        .is_some_and(|marker| panel.flag(w, marker, "visible"))
                        && panel.flag(w, body, "keyboardAttached")
                },
                |w| describe_ref(w).to_string(),
            )
        },
    );
    steps.step("the Magic Keyboard is no longer shown", |world, _, _| {
        world.wait_for_with(
            |w| {
                let Some(panel) = w.peek_part::<Panel>().and_then(|p| p.0) else {
                    return false;
                };
                let Some(body) = body_item(w) else {
                    return false;
                };
                panel
                    .find_in(w, body, "deviceMagicKeyboard")
                    .ok()
                    .flatten()
                    .is_some_and(|marker| !panel.flag(w, marker, "visible"))
                    && !panel.flag(w, body, "keyboardAttached")
            },
            |w| describe_ref(w).to_string(),
        )
    });
    steps.step("the device is asked to turn to landscape", |world, _, _| {
        world.wait_for_with(
            |w| {
                let Some(hub) = w.mc.peek::<FakeHub>() else {
                    return false;
                };
                hub.shared
                    .seen()
                    .binary
                    .iter()
                    .filter(|m| m.first() == Some(&0x07))
                    .map(|m| serde_json::from_slice::<Value>(&m[1..]).unwrap_or(Value::Null))
                    .any(|input| text(&input["orientation"]).starts_with("landscape"))
            },
            |_| "the device to be asked to turn to landscape".into(),
        )
    });
}

/// An iPad open and watched, in 3D or flat, with its keyboard or not.
fn viewing_ipad(world: &mut World, in3d: bool, attached: bool) -> Outcome {
    fake_hub(world).foreground_app = json!({"id": "com.example.shop"});
    add_device(world, "ios", "iPad Pro 13-inch", true);
    let device = device_named(fake_hub(world), "iPad Pro 13-inch")?;
    open_session(&mut world.mc, &device, THREAD);
    show_device_tab(world, "iPad Pro 13-inch")?;
    wait_for_screen(world, "iPad Pro 13-inch")?;
    // Input must be live before an attach can ask the device to turn.
    world.wait_for_with(|w| stream_of(w).2, describe_ref)?;
    if attached {
        let tab = shown_tab(world)?;
        world
            .engine()
            .invoke_by_name(tab, "toggleKeyboard", &[])
            .map_err(|e| Failure(format!("toggleKeyboard: {e:?}")))?;
    }
    if in3d {
        show_in_3d(world)?;
    }
    world.sync()
}

/// Runs a QML function on a brick's item, for the stage's own key policy.
fn brick_invoke(
    world: &mut World,
    item: ObjectId,
    method: &str,
    args: &[QmlValue],
) -> Outcome<QmlValue> {
    world
        .engine()
        .invoke_by_name(item, method, args)
        .map_err(|e| Failure(format!("{method}: {e:?}")))
}

/// An item's own width and height.
fn item_size(panel: &Brick, world: &World, item: ObjectId) -> (f64, f64) {
    let number = |name: &str| match panel.read(world, item, name) {
        QmlValue::Int(n) => f64::from(n),
        QmlValue::Real(r) => r,
        _ => 0.0,
    };
    (number("width"), number("height"))
}

/// "the user chooses {Q}" in the open Tools drawer.
fn tools_chooses(world: &mut World, what: &str) -> Outcome<bool> {
    if world.peek_part::<Panel>().and_then(|p| p.0).is_none() || tools_view(world)["open"] != true {
        return Ok(false);
    }
    let name = match what {
        "Dark" | "Light" => format!("toolsChoice-Appearance-{what}"),
        "Clear" | "Tinted" => format!("toolsChoice-Liquid Glass-{what}"),
        "Close tools" => "toolsClose".to_owned(),
        "Terminate" => "toolsTerminate".to_owned(),
        "Relaunch" => "toolsRelaunch".to_owned(),
        "Set" => "toolsLocationSet".to_owned(),
        _ => return Ok(false),
    };
    click(world, &name)?;
    Ok(true)
}

/// Picks `label` in the permission list, as the user does before a decision.
fn choose_permission(world: &mut World, label: &str) -> Outcome {
    let (combo, model) = combo_model(world, "toolsPermission")?;
    let Some(index) = model.iter().position(|m| m == label) else {
        fail!("no permission {label} among {}", model.join(", "));
    };
    device_panel(world)?.write(world, combo, "currentIndex", QmlValue::Int(index as i32))?;
    world.sync()
}

/// Whether the Device tab shows a device or one is open for the thread.
/// The hub is only looked at: [`fake_hub`] would set one up (and rename
/// the MC) in every world.
fn showing_device(world: &mut World) -> Outcome<bool> {
    if !screen_of(world).is_null() {
        return Ok(true);
    }
    let last = world
        .mc
        .peek::<FakeHub>()
        .filter(|hub| hub.used)
        .and_then(|hub| {
            let id = hub.sessions.last()?["deviceId"].clone();
            hub.devices
                .iter()
                .find(|d| d["id"] == id)
                .map(|d| text(&d["name"]))
        });
    // The device's own tab first, when the scenario only opened the device.
    let Some(name) = last else {
        return Ok(false);
    };
    show_device_tab(world, &name)?;
    Ok(true)
}

/// "the user opens {Q}" for the Device tab: its Tools drawer and its event
/// log. False when no device is open or `what` is neither.
pub fn device_opens(world: &mut World, what: &str) -> Outcome<bool> {
    if !matches!(what, "Tools" | "Event log") || !showing_device(world)? {
        return Ok(false);
    }
    if what == "Tools" {
        // The read is held, so a scenario can watch it land; the others'
        // settings arrive when their next step answers the held call.
        world.mc.hold("device.detail");
        click(world, "deviceTools")?;
        return Ok(true);
    }
    click(world, "toolsEventLogToggle")?;
    world.wait_for_with(
        |w| {
            w.mc.peek::<FakeHub>().is_some_and(|hub| {
                hub.feeds
                    .iter()
                    .any(|(path, feed)| path.ends_with("/api/event-log/events") && connected(feed))
            })
        },
        |w| format!("no event feed; {}", describe_tools(w)),
    )?;
    Ok(true)
}

/// "{Q} cannot be chosen" for the Tools drawer's Send. False when the
/// drawer is not open or `what` is not Send.
pub fn device_cannot_choose(world: &mut World, what: &str) -> Outcome<bool> {
    if what != "Send" || world.peek_part::<Panel>().and_then(|p| p.0).is_none() {
        return Ok(false);
    }
    if tools_view(world)["open"] != true {
        return Ok(false);
    }
    expect!(
        !item_flag(world, "toolsPushSend", "enabled")?,
        "{}",
        describe_tools(world)
    );
    Ok(true)
}
