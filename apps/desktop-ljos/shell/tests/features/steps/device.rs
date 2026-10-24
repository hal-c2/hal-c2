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
use hal_c2_shell::device::devices::{ThreadDevices, tab_id_of};
use hal_c2_shell::device::stream::DeviceStream;
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
}

impl Default for FakeHub {
    fn default() -> FakeHub {
        FakeHub {
            devices: Vec::new(),
            sessions: Vec::new(),
            host_status: "ready".into(),
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
        }
    }
}

impl Drop for FakeHub {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::SeqCst);
    }
}

/// The Device tab's brick, once shown over the right panel's ThreadDevices.
#[derive(Default)]
struct Panel(Option<Brick>);

fn state_of(mc: &mut FakeMc) -> Value {
    let name = mc.name.clone();
    let hub = mc.part::<FakeHub>();
    let platforms = json!([
        {"platform": "ios", "available": true},
        {"platform": "android", "available": true},
    ]);
    json!({
        "hosts": [{
            "id": HOST,
            "kind": "local",
            "label": "This Mac",
            "platforms": platforms,
            "hubInstalled": true,
            "agentDeviceInstalled": true,
        }],
        "hostStatus": hub.host_status,
        "hostStatuses": {HOST: {"status": hub.host_status}},
        "devices": hub.devices,
        "sessions": hub.sessions,
        "onboardingCompleted": hub.host_status != "disabled",
        "agentAccessEnabled": false,
        "hubBasePath": format!("/api/device-hub/mcs/{}", hal_c2_shell::device::percent(&name)),
        "revision": hub.revision,
    })
}

/// The MC tells every watcher, as devices.ex does on each change.
fn announce(mc: &mut FakeMc) {
    mc.part::<FakeHub>().revision += 1;
    let state = state_of(mc);
    for id in mc.subscribers("devices") {
        mc.send(&json!({"t": "devices", "id": id, "state": state}));
    }
}

fn session_of(hub: &FakeHub, device_id: &str, thread: &str) -> Option<usize> {
    hub.sessions
        .iter()
        .position(|s| text(&s["threadId"]) == thread && text(&s["deviceId"]) == device_id)
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
    if session_of(hub, &text(&device["id"]), thread).is_none() {
        hub.sessions.push(json!({
            "threadId": thread,
            "hostId": HOST,
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
    if hub.refuse != 0 {
        let _ = stream.read_exact(&mut vec![0u8; head.len()]);
        respond(stream, hub.refuse);
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

fn close_device(mc: &mut FakeMc, rpc: &crate::fake_mc::Rpc) {
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
            let state = state_of(mc);
            mc.send(&json!({"t": "devices", "id": id, "state": state}));
            Ok(())
        });
        world.mc.on_rpc("device.list", |mc, rpc| {
            let state = state_of(mc);
            mc.reply(rpc, state);
            Ok(())
        });
        world.mc.on_rpc("device.open", |mc, rpc| {
            let refusal = mc.part::<FakeHub>().refuse_open.clone();
            if !refusal.is_empty() {
                mc.refuse(rpc, &refusal);
                return Ok(());
            }
            let wanted = &rpc.payload["deviceId"];
            let device = mc
                .part::<FakeHub>()
                .devices
                .iter()
                .find(|d| d["id"] == *wanted)
                .cloned();
            let Some(device) = device else {
                mc.refuse(rpc, "Device not found");
                return Ok(());
            };
            let thread = text(&rpc.payload["threadId"]);
            open_session(mc, &device, &thread);
            announce(mc);
            let hub = mc.part::<FakeHub>();
            let session = session_of(hub, &text(&device["id"]), &thread)
                .map_or(Value::Null, |at| hub.sessions[at].clone());
            mc.reply(rpc, session);
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

fn stream_object(world: &World) -> Outcome<ObjectId> {
    ThreadDevices::stream(world.engine(), devices_object(world)?)
        .ok_or_else(|| Failure("the Device tabs have no stream".into()))
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
    let id = if platform == "ios" {
        format!("UDID-{}", name.replace(' ', "-").to_uppercase())
    } else {
        "emulator-5554".to_owned()
    };
    fake_hub(world).devices.push(json!({
        "hostId": HOST,
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
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nDevicePanel { anchors.fill: parent }\n",
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
    DeviceStream::set_timeouts(
        world.engine(),
        stream_object(world)?,
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
    let row = format!("deviceRow-{}", text(&row_of(world, name, "")["id"]));
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
    !open && stream_of(world).0 == "idle"
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
    steps.step("FFmpeg is not installed", |_, _, _| {
        fail!(
            "desktop-ljos decodes with Ljós's own H.264 decoder and has no FFmpeg to hide: \
             there is no state to put the shell in"
        )
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
                let shown = view(w);
                let (status, detail, ..) = stream_of(w);
                text(&shown["empty"]) == wanted
                    || text(&shown["error"]) == wanted
                    || (status == "error" && detail == wanted)
            },
            describe_ref,
        )
    });
    steps.step("the user dismisses the error", |world, _, _| {
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
                    && !view(world)["screen"].is_null()
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
                }) && stream_of(w).0 == "idle"
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
