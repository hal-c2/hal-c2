//! The Device tab as desktop-qt's scenarios drive it
//! (features/preview/devices.feature): `ThreadDevices` listing, opening and
//! closing a thread's devices over an MC the test answers, and its
//! `DeviceStream` showing one on a `DeviceScreen`, with the test as the
//! MC's device proxy and a scripted decoder.

mod common;
#[path = "support/device_fixture.rs"]
mod device_fixture;
#[path = "support/device_mc.rs"]
mod device_mc;

use std::cell::RefCell;
use std::rc::Rc;

use common::{call, read, text};
use device_fixture::{android_video, avcc, envelope, ios_video};
use device_mc::{DeviceMc, Makes, Script, script_decoders};
use hal_c2_shell::device;
use hal_c2_shell::device::devices::{ThreadDevices, tab_id_of};
use hal_c2_shell::device::stream::{self, DeviceStream, FIRST_FRAME_MS, RETRY_MS};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{StreamEnd, StreamEvent, StreamId, StreamMessage};
use ljos::prelude::{Engine, ObjectId, Value};
use ljos::testing::TestWindow;
use serde_json::json;

const MAIN: &str = r#"
import QtQuick
import HalC2.Shell
Item {
    id: root
    width: 400
    height: 800
    property var devices: null
    readonly property var view: devices ? devices.view : null
    readonly property var stream: devices ? devices.stream : null
    readonly property string status: stream ? stream.status : "none"
    readonly property string detail: stream ? stream.detail : ""
    readonly property bool input: stream ? stream.inputConnected : false
    readonly property real aspect: stream ? stream.aspect : 0
    readonly property int turn: stream ? stream.rotation : 0
    readonly property bool shown: screen.hasFrame
    DeviceScreen {
        id: screen
        width: 100
        height: 200
        stream: root.stream
    }
    function offered() {
        return root.view.groups.map(g => g.title + ": " + g.devices.map(d => d.name + " " + d.action).join(", ")).join("; ");
    }
    function field(name) { return String(root.view[name]) }
    function screenName() { return root.view.screen ? root.view.screen.name : "" }
}
"#;

const HUB: &str = "/api/device-hub/mcs/mc-1";
const IPHONE: &str = "UDID-1";
const PIXEL: &str = "emulator-5554";

struct Tab {
    engine: Engine,
    root: ObjectId,
    devices: ObjectId,
    stream: ObjectId,
    mc: Rc<DeviceMc>,
    script: Rc<RefCell<Script>>,
    window: RefCell<TestWindow>,
    opened: Rc<RefCell<Vec<(String, bool)>>>,
    closed: Rc<RefCell<Vec<(String, String)>>>,
    names: Rc<RefCell<u32>>,
}

/// A device on the environment: (name, id, platform, running).
type Device = (&'static str, &'static str, &'static str, bool);

const IPHONE_17: Device = ("iPhone 17", IPHONE, "ios", true);
const PIXEL_9: Device = ("Pixel 9", PIXEL, "android", true);

/// The environment's DeviceServiceState: `devices`, of which `open` are
/// open in thread-1.
fn state(devices: &[Device], open: &[&str]) -> Json {
    let devices: Vec<Json> = devices
        .iter()
        .map(|(name, id, platform, booted)| {
            json!({
                "booted": booted,
                "hostId": "host-1",
                "id": id,
                "name": name,
                "platform": platform,
                "version": if *platform == "ios" { "iOS 26.0" } else { "Android 16" },
            })
        })
        .collect();
    let sessions: Vec<Json> = open
        .iter()
        .map(|id| json!({"deviceId": id, "hostId": "host-1", "threadId": "thread-1"}))
        .collect();
    json!({
        "bootingDevices": [],
        "devices": devices,
        "hostStatus": "ready",
        "hostStatuses": {"host-1": {"status": "ready"}},
        "hosts": [{
            "id": "host-1",
            "label": "studio",
            "platforms": [
                {"available": true, "platform": "ios"},
                {"available": true, "platform": "android"},
            ],
        }],
        "hubBasePath": HUB,
        "onboardingCompleted": true,
        "sessions": sessions,
    })
}

/// thread-1 of env-1 shown, its devices followed through mc-1; decoding is
/// the script's unless `real_decoder`.
fn tab_with(real_decoder: bool) -> Tab {
    let mc = DeviceMc::new();
    let engine = common::engine(common::compile(&[("Main", MAIN)], &[]), mc.clone());
    // A window for its clock, before Main starts its timers on it.
    let window = RefCell::new(ljos::testing::TestWindow::new(&engine, 100.0, 100.0));
    let script = if real_decoder {
        Rc::new(RefCell::new(Script::default()))
    } else {
        script_decoders(&engine)
    };
    let root = engine
        .create_from_url("Main", None, Vec::new())
        .expect("Main is made");
    let devices = ThreadDevices::create(&engine, Some(root), mc.clone()).expect("the devices");
    engine
        .write_by_name(root, "devices", Value::Object(devices))
        .unwrap();
    let stream = ThreadDevices::stream(&engine, devices).expect("its stream");
    let opened = Rc::new(RefCell::new(Vec::new()));
    let closed = Rc::new(RefCell::new(Vec::new()));
    let names = Rc::new(RefCell::new(0));
    let o = opened.clone();
    ThreadDevices::on_opened(&engine, devices, move |_, tab, automatic| {
        o.borrow_mut().push((tab.to_owned(), automatic));
    });
    let c = closed.clone();
    ThreadDevices::on_closed(&engine, devices, move |_, thread, tab| {
        c.borrow_mut().push((thread.to_owned(), tab.to_owned()));
    });
    let n = names.clone();
    ThreadDevices::on_names_changed(&engine, devices, move |_| *n.borrow_mut() += 1);
    ThreadDevices::set_thread(&engine, devices, "env-1", "thread-1", "mc-1");
    Tab {
        engine,
        root,
        devices,
        stream,
        mc,
        script,
        window,
        opened,
        closed,
        names,
    }
}

fn tab() -> Tab {
    tab_with(false)
}

impl Tab {
    fn text(&self, name: &str) -> String {
        text(&self.engine, self.root, name)
    }
    fn shown(&self) -> bool {
        read(&self.engine, self.root, "shown") == Value::Bool(true)
    }
    fn view(&self, field: &str) -> String {
        let v = call(&self.engine, self.root, "field", &[Value::from(field)]);
        self.engine.to_js_string(&v).to_string()
    }
    /// The `devices` shapes followed.
    fn followed(&self) -> Vec<Json> {
        let mut follows = self.mc.follows();
        follows.retain(|s| s["type"] == "devices");
        follows
    }
    fn screen_name(&self) -> String {
        let v = call(&self.engine, self.root, "screenName", &[]);
        self.engine.to_js_string(&v).to_string()
    }
    fn offered(&self) -> String {
        let v = call(&self.engine, self.root, "offered", &[]);
        self.engine.to_js_string(&v).to_string()
    }
    /// The MC's `devices` shape says `state`.
    fn devices_are(&self, state: Json) {
        self.mc.devices(&self.engine, state);
    }
    fn show(&self, tab: &str) {
        ThreadDevices::set_tab(&self.engine, self.devices, tab);
    }
    fn invoke(&self, name: &str, args: &[Value]) -> Value {
        call(&self.engine, self.devices, name, args)
    }
    fn on_stream(&self, name: &str, args: &[Value]) -> Value {
        call(&self.engine, self.stream, name, args)
    }
    /// `ms` pass on the engine's timers.
    fn pass(&self, ms: i32) {
        self.window.borrow_mut().advance(ms as u64).unwrap();
    }
    /// The decoder's news reaches the stream.
    fn decoded(&self) {
        device::deliver(&self.engine);
    }
    fn stream_at(&self, suffix: &str) -> StreamId {
        self.mc
            .stream(suffix)
            .unwrap_or_else(|| panic!("a stream at {suffix} is open: {:?}", self.mc.open_now()))
    }
    fn emit(&self, suffix: &str, event: StreamEvent) {
        assert!(self.mc.emit(&self.engine, self.stream_at(suffix), event));
    }
    /// The hub answers the iOS video request and sends `body`.
    fn ios_video_sends(&self, body: Vec<u8>) {
        self.emit("stream.avcc", StreamEvent::Opened { status: 200 });
        self.emit("stream.avcc", StreamEvent::Data(body));
    }
    /// The iOS helper starts capturing, and its input socket connects.
    fn ios_input_connects(&self) {
        self.emit("stream.mjpeg", StreamEvent::Opened { status: 200 });
        self.emit("/helper/ws", StreamEvent::Opened { status: 101 });
    }
    /// serve-emu's socket connects and sends the fixture's frames.
    fn android_sends(&self) {
        self.emit("/serve-emu/ws", StreamEvent::Opened { status: 101 });
        for (frame, _) in android_video() {
            self.emit("/serve-emu/ws", StreamEvent::Binary(frame));
        }
    }
    /// What the shell sent on the socket at `suffix`, as JSON: binary
    /// messages as [tag, json].
    fn sent(&self, suffix: &str) -> Vec<Json> {
        self.mc
            .take_sent(self.stream_at(suffix))
            .into_iter()
            .map(|m| match m {
                StreamMessage::Text(t) => serde_json::from_str(&t).unwrap(),
                StreamMessage::Binary(b) => {
                    json!([b[0], serde_json::from_slice::<Json>(&b[1..]).unwrap()])
                }
            })
            .collect()
    }
    /// The thread has `devices` open, and the user watches `name`'s tab.
    fn watching(&self, devices: &[Device], open: &[&str], id: &str) {
        self.devices_are(state(devices, open));
        self.show(&tab_id_of("host-1", id));
        assert_eq!(self.text("status"), "connecting");
    }
}

#[test]
fn picking_a_device_shows_its_screen() {
    let t = tab();
    assert_eq!(t.followed(), [json!({"mc": "mc-1", "type": "devices"})]);
    assert_eq!(t.view("loaded"), "false");
    assert_eq!(t.view("loading"), "Finding devices…");
    t.devices_are(state(&[IPHONE_17], &[]));
    assert_eq!(*t.names.borrow(), 1);
    // The user adds a Device tab: it lists again.
    t.show("device");
    assert_eq!(t.mc.asked("device.list"), 1);
    t.mc.answer(&t.engine, "device.list", Ok(state(&[IPHONE_17], &[])));
    assert_eq!(t.offered(), "iOS Simulators: iPhone 17 Open");
    assert_eq!(t.view("canRefresh"), "true");

    t.invoke("open", &[Value::from("host-1"), Value::from(IPHONE)]);
    assert_eq!(t.view("loading"), "Opening device…");
    assert_eq!(t.view("pendingKey"), format!("host-1\0{IPHONE}"));
    // Only one device is opened at a time.
    t.invoke("open", &[Value::from("host-1"), Value::from(IPHONE)]);
    assert_eq!(t.mc.asked("device.open"), 1);
    let payload = t.mc.answer(
        &t.engine,
        "device.open",
        Ok(json!({"deviceId": IPHONE, "hostId": "host-1"})),
    );
    assert_eq!(
        payload,
        json!({"deviceId": IPHONE, "hostId": "host-1", "platform": "ios", "threadId": "thread-1"})
    );
    let tab = tab_id_of("host-1", IPHONE);
    assert_eq!(*t.opened.borrow(), [(tab.clone(), false)]);
    assert_eq!(t.view("pendingKey"), "");

    // The panel shows the device's tab; the MC says the thread has it open,
    // which is not an agent's open.
    t.show(&tab);
    t.devices_are(state(&[IPHONE_17], &[IPHONE]));
    assert_eq!(t.opened.borrow().len(), 1);
    assert_eq!(t.screen_name(), "iPhone 17");
    assert_eq!(
        ThreadDevices::title_of(&t.engine, t.devices, &tab),
        "iPhone 17"
    );
    assert_eq!(t.text("status"), "connecting");
    t.ios_video_sends(ios_video(false));
    t.decoded();
    assert!(t.shown());
    assert_eq!(t.text("status"), "streaming");

    // The screen came through the MC's device proxy.
    let opened = t.mc.opened();
    assert!(!opened.is_empty());
    for (path, _, _) in &opened {
        assert!(
            path.starts_with(&format!("{HUB}/vendor/serve-sim/")),
            "{path}"
        );
    }
    assert_eq!(
        opened[..2],
        [
            (
                format!("{HUB}/vendor/serve-sim/helper/{IPHONE}/stream.mjpeg"),
                String::new(),
                false
            ),
            (
                format!("{HUB}/vendor/serve-sim/helper/{IPHONE}/stream.avcc"),
                String::new(),
                false
            ),
        ]
    );
    // The picture is made no larger than the screen shows it.
    assert_eq!(t.script.borrow().maximum, (100, 200));
}

#[test]
fn a_stopped_device_is_offered_to_start() {
    let t = tab();
    t.devices_are(state(&[("Pixel 9", PIXEL, "android", false)], &[]));
    assert_eq!(t.offered(), "Android Emulators: Pixel 9 Start");
}

#[test]
fn running_devices_come_first_then_by_name() {
    let t = tab();
    t.devices_are(state(
        &[
            ("b phone", "1", "ios", false),
            ("A phone", "2", "ios", false),
            ("Z phone", "3", "ios", true),
            ("Pixel 9", PIXEL, "android", true),
        ],
        &[],
    ));
    assert_eq!(
        t.offered(),
        "iOS Simulators: Z phone Open, A phone Start, b phone Start; Android Emulators: Pixel 9 Open"
    );
}

#[test]
fn an_environment_without_devices_says_so() {
    let t = tab();
    t.devices_are(state(&[], &[]));
    assert_eq!(
        t.view("empty"),
        "No simulators or emulators were found on this environment."
    );
}

#[test]
fn a_device_the_mc_cannot_open_says_why() {
    let t = tab();
    t.devices_are(state(&[IPHONE_17], &[]));
    t.show("device");
    t.invoke("open", &[Value::from("host-1"), Value::from(IPHONE)]);
    t.mc.answer(&t.engine, "device.open", Err("Simulator failed to boot"));
    assert_eq!(t.view("error"), "Simulator failed to boot");
    assert!(t.opened.borrow().is_empty());
    t.invoke("dismissError", &[]);
    assert_eq!(t.view("error"), "");
}

#[test]
fn device_support_that_is_off_points_to_its_settings() {
    let t = tab();
    let mut off = state(&[], &[]);
    off["hostStatus"] = json!("disabled");
    t.devices_are(off);
    assert_eq!(t.view("setup"), "true");
    // Showing the tab never asks a hub that is off.
    t.show("device");
    assert_eq!(t.mc.asked("device.list"), 0);
}

#[test]
fn the_tab_says_it_is_connecting_until_the_first_picture() {
    let t = tab();
    t.script.borrow_mut().makes = Makes::Nothing;
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.ios_video_sends(ios_video(false));
    t.decoded();
    assert_eq!(t.text("status"), "connecting");
    assert_eq!(t.text("detail"), "");
    assert!(!t.shown());
    // The device starts sending pictures.
    t.script.borrow_mut().makes = Makes::Pictures(72, 160);
    t.emit("stream.avcc", StreamEvent::Data(ios_video(false)));
    t.decoded();
    assert_eq!(t.text("status"), "streaming");
    assert!(t.shown());
}

#[test]
fn a_display_of_finer_pixels_gets_a_finer_picture() {
    let t = tab();
    ljos::testing::set_screens(
        &t.engine,
        &[ljos::testing::ScreenSpec {
            scale: 2.0,
            ..Default::default()
        }],
    );
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.ios_video_sends(ios_video(false));
    t.decoded();
    assert!(t.shown());
    // The 100 by 200 screen, in the display's pixels.
    assert_eq!(t.script.borrow().maximum, (200, 400));
}

#[test]
fn video_that_arrives_in_pieces_still_shows_the_screen() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.emit("stream.avcc", StreamEvent::Opened { status: 200 });
    let body = ios_video(false);
    for piece in body.chunks(7) {
        t.emit("stream.avcc", StreamEvent::Data(piece.to_vec()));
    }
    t.decoded();
    assert!(t.shown());
    let script = t.script.borrow();
    let units = device_fixture::avcc_units();
    assert_eq!(script.pushed.len(), units.len());
    assert_eq!(script.pushed[0], units[0]);
    assert!(script.resets.contains(&Some(avcc(false))));
}

#[test]
fn a_jpeg_seed_goes_to_the_decoder() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.emit("stream.avcc", StreamEvent::Opened { status: 200 });
    t.emit("stream.avcc", StreamEvent::Data(envelope(4, &[0xff, 0xd8])));
    assert_eq!(t.script.borrow().jpegs, 1);
}

#[test]
fn a_tab_turned_to_another_device_never_shows_the_last_ones_picture() {
    let t = tab();
    t.watching(&[IPHONE_17, PIXEL_9], &[IPHONE, PIXEL], IPHONE);
    t.ios_video_sends(ios_video(false));
    t.decoded();
    assert!(t.shown());
    t.script.borrow_mut().makes = Makes::Nothing;
    t.show(&tab_id_of("host-1", PIXEL));
    assert_eq!(t.text("status"), "connecting");
    assert!(!t.shown());
    // The iPhone's connections are gone; the emulator's socket is open.
    assert_eq!(t.mc.open_now(), [format!("{HUB}/vendor/serve-emu/ws")]);
    assert_eq!(
        t.mc.opened().last().unwrap().1,
        format!("device={PIXEL}&frame-meta=1")
    );
}

#[test]
fn a_device_that_sends_nothing_is_an_error_the_user_can_retry() {
    let t = tab();
    t.script.borrow_mut().makes = Makes::Nothing;
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.emit("stream.avcc", StreamEvent::Opened { status: 200 });
    // Video keeps coming, but no picture.
    t.pass(FIRST_FRAME_MS / 2);
    t.emit("stream.avcc", StreamEvent::Data(ios_video(false)));
    t.decoded();
    t.pass(FIRST_FRAME_MS / 2);
    assert_eq!(t.text("status"), "error");
    assert_eq!(t.text("detail"), stream::NO_VIDEO);
    assert!(t.mc.open_now().is_empty());
    // An error stays: nothing retries by itself.
    t.pass(RETRY_MS * 5);
    assert!(t.mc.open_now().is_empty());

    t.script.borrow_mut().makes = Makes::Pictures(72, 160);
    t.on_stream("reconnect", &[]);
    assert_eq!(t.text("status"), "connecting");
    t.ios_video_sends(ios_video(false));
    t.decoded();
    assert!(t.shown());
}

#[test]
fn a_body_that_goes_quiet_is_an_error() {
    let t = tab();
    t.script.borrow_mut().makes = Makes::Nothing;
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.emit("stream.avcc", StreamEvent::Opened { status: 200 });
    // Data keeps the body alive past the first-frame time...
    t.pass(FIRST_FRAME_MS - 1);
    t.emit("stream.avcc", StreamEvent::Data(Vec::new()));
    t.script.borrow_mut().makes = Makes::Pictures(72, 160);
    t.emit("stream.avcc", StreamEvent::Data(ios_video(false)));
    t.decoded();
    assert_eq!(t.text("status"), "streaming");
    // ...and its silence ends it.
    t.pass(FIRST_FRAME_MS);
    assert_eq!(t.text("status"), "error");
    assert_eq!(t.text("detail"), stream::STALLED);
}

#[test]
fn a_device_screen_is_decoded_on_the_desktop() {
    let t = tab_with(true);
    let (woke, wakes) = std::sync::mpsc::channel();
    let woke = std::sync::Mutex::new(woke);
    device::set_wake(&t.engine, move || {
        let _ = woke.lock().map(|w| w.send(()));
    });
    t.watching(&[PIXEL_9], &[PIXEL], PIXEL);
    t.android_sends();
    // A guard, not a pace: the decoder wakes the shell when it has a picture.
    wakes
        .recv_timeout(std::time::Duration::from_secs(60))
        .expect("the decoder wakes the shell");
    t.decoded();
    assert_eq!(t.text("status"), "streaming");
    assert!(t.shown());
}

#[test]
fn video_the_desktop_cannot_decode_is_an_error_not_endless_reconnecting() {
    let t = tab();
    t.script.borrow_mut().makes = Makes::Broken;
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    for _ in 0..3 {
        t.ios_video_sends(ios_video(false));
        t.decoded();
        t.pass(RETRY_MS);
    }
    assert_eq!(t.text("status"), "error");
    assert_eq!(t.text("detail"), stream::UNDECODABLE);
    assert_eq!(t.mc.opened_at("stream.avcc"), 3);
}

#[test]
fn a_decoder_that_cannot_start_says_why() {
    let t = tab();
    t.watching(&[PIXEL_9], &[PIXEL], PIXEL);
    t.emit("/serve-emu/ws", StreamEvent::Opened { status: 101 });
    t.engine.batch(|| {
        DeviceStream::update(&t.engine, t.stream, |c| {
            c.on_decoded(hal_c2_shell::device::decoder::Decoded::Unsupported(
                "No H.264 decoder.".into(),
            ))
        })
    });
    assert_eq!(t.text("status"), "error");
    assert_eq!(
        t.text("detail"),
        "Cannot decode the device's video. No H.264 decoder."
    );
}

#[test]
fn a_stream_that_ends_connects_again() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.ios_video_sends(ios_video(false));
    t.decoded();
    assert!(t.shown());
    let end = StreamEnd {
        error: Some("Connection closed".into()),
        ..StreamEnd::default()
    };
    assert!(t.mc.end(&t.engine, t.stream_at("stream.avcc"), end));
    assert_eq!(t.text("status"), "connecting");
    assert_eq!(t.text("detail"), "Connection closed");
    assert!(!t.shown());
    t.pass(RETRY_MS);
    assert_eq!(t.mc.opened_at("stream.avcc"), 2);
    t.ios_video_sends(ios_video(false));
    t.decoded();
    assert_eq!(t.text("status"), "streaming");
    assert!(t.shown());
}

#[test]
fn a_proxy_that_turns_the_video_away_is_retried() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.emit("stream.avcc", StreamEvent::Opened { status: 502 });
    assert_eq!(t.text("status"), "connecting");
    assert_eq!(t.text("detail"), "stream 502");
    assert!(t.mc.stream("stream.avcc").is_none());
    t.pass(RETRY_MS);
    assert_eq!(t.mc.opened_at("stream.avcc"), 2);
}

#[test]
fn a_stream_the_mc_refuses_is_an_error() {
    let t = tab();
    t.watching(&[PIXEL_9], &[PIXEL], PIXEL);
    let refused = StreamEnd {
        status: Some(401),
        ..StreamEnd::default()
    };
    assert!(t.mc.end(&t.engine, t.stream_at("/serve-emu/ws"), refused));
    assert_eq!(t.text("status"), "error");
    assert_eq!(t.text("detail"), stream::REFUSED);
    assert!(t.mc.open_now().is_empty());
}

#[test]
fn an_ios_video_request_the_mc_refuses_is_an_error() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.emit("stream.avcc", StreamEvent::Opened { status: 403 });
    assert_eq!(t.text("status"), "error");
    assert_eq!(t.text("detail"), stream::REFUSED);
}

#[test]
fn an_android_emulator_that_rotates_starts_its_video_over() {
    let t = tab();
    t.watching(&[PIXEL_9], &[PIXEL], PIXEL);
    t.android_sends();
    t.decoded();
    assert!(t.shown());
    assert_eq!(t.text("status"), "streaming");
    // serve-emu's pictures say how the device is held.
    t.script.borrow_mut().makes = Makes::Pictures(160, 72);
    t.emit(
        "/serve-emu/ws",
        StreamEvent::Text(r#"{"type":"video-session"}"#.into()),
    );
    assert_eq!(
        t.sent("/serve-emu/ws"),
        [json!({"ack": false, "type": "reset-video"})]
    );
    assert_eq!(t.text("status"), "connecting");
    assert!(!t.shown());
    // A delta before the keyframe is not decoded; it asks again.
    let frames = android_video();
    let pushed = t.script.borrow().pushed.len();
    t.emit("/serve-emu/ws", StreamEvent::Binary(frames[1].0.clone()));
    assert_eq!(t.script.borrow().pushed.len(), pushed);
    assert_eq!(t.sent("/serve-emu/ws").len(), 1);
    t.emit("/serve-emu/ws", StreamEvent::Binary(frames[0].0.clone()));
    t.decoded();
    assert!(t.shown());
    assert_eq!(t.text("status"), "streaming");
    assert!(read(&t.engine, t.root, "aspect").to_number() > 1.0);
    // The SEMU header is not the decoder's.
    assert_eq!(
        t.script.borrow().pushed.last().unwrap().0,
        frames[0].0[16..]
    );
}

#[test]
fn a_decoder_that_falls_behind_asks_for_a_keyframe() {
    let t = tab();
    t.watching(&[PIXEL_9], &[PIXEL], PIXEL);
    t.android_sends();
    t.decoded();
    t.sent("/serve-emu/ws");
    t.script.borrow_mut().keeps_up = false;
    t.emit(
        "/serve-emu/ws",
        StreamEvent::Binary(android_video()[1].0.clone()),
    );
    assert_eq!(
        t.sent("/serve-emu/ws"),
        [json!({"ack": false, "type": "reset-video"})]
    );
    assert_eq!(t.text("status"), "connecting");
    assert_eq!(t.text("detail"), stream::RESTARTED);
}

#[test]
fn a_device_tab_in_the_background_streams_nothing() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.ios_video_sends(ios_video(false));
    t.decoded();
    assert!(t.shown());
    // The user switches to the Diff tab.
    t.show("");
    assert!(t.mc.open_now().is_empty());
    assert_eq!(t.text("status"), "idle");
    t.pass(FIRST_FRAME_MS * 2);
    assert!(t.mc.open_now().is_empty());
    t.show(&tab_id_of("host-1", IPHONE));
    t.ios_video_sends(ios_video(false));
    t.decoded();
    assert!(t.shown());
}

#[test]
fn a_session_that_ends_shows_the_picker_again() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.devices_are(state(&[IPHONE_17], &[]));
    assert_eq!(t.text("status"), "idle");
    assert!(t.mc.open_now().is_empty());
    assert_eq!(t.screen_name(), "");
}

#[test]
fn an_agents_open_brings_its_tab() {
    let t = tab();
    // The first state is the baseline: what the thread had open already
    // opens nothing.
    t.devices_are(state(&[IPHONE_17, PIXEL_9], &[IPHONE]));
    assert!(t.opened.borrow().is_empty());
    t.devices_are(state(&[IPHONE_17, PIXEL_9], &[IPHONE, PIXEL]));
    assert_eq!(*t.opened.borrow(), [(tab_id_of("host-1", PIXEL), true)]);
    // Closed and opened again: its tab comes again.
    t.devices_are(state(&[IPHONE_17, PIXEL_9], &[IPHONE]));
    t.devices_are(state(&[IPHONE_17, PIXEL_9], &[IPHONE, PIXEL]));
    assert_eq!(t.opened.borrow().len(), 2);
}

#[test]
fn powering_off_closes_the_tab_in_the_thread_it_was_asked_from() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    let tab = tab_id_of("host-1", IPHONE);
    t.invoke("powerOff", &[]);
    // Before the MC answers, the user switches to another thread.
    ThreadDevices::set_thread(&t.engine, t.devices, "env-1", "thread-2", "mc-1");
    let payload = t.mc.answer(&t.engine, "device.close", Ok(json!({})));
    assert_eq!(
        payload,
        json!({"deviceId": IPHONE, "hostId": "host-1", "shutdown": true, "threadId": "thread-1"})
    );
    assert_eq!(
        *t.closed.borrow(),
        [("env-1:thread-1".to_owned(), tab.clone())]
    );
}

#[test]
fn a_failed_power_off_is_shown_only_in_its_thread() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.invoke("powerOff", &[]);
    t.mc.answer(&t.engine, "device.close", Err("Busy"));
    assert_eq!(t.view("error"), "Busy");
    t.invoke("dismissError", &[]);
    t.invoke("powerOff", &[]);
    ThreadDevices::set_thread(&t.engine, t.devices, "env-1", "thread-2", "mc-1");
    t.mc.answer(&t.engine, "device.close", Err("Busy"));
    assert_eq!(t.view("error"), "");
    assert!(t.closed.borrow().is_empty());
}

#[test]
fn closing_a_tab_leaves_the_device_open() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.invoke("close", &[]);
    assert_eq!(
        *t.closed.borrow(),
        [("env-1:thread-1".to_owned(), tab_id_of("host-1", IPHONE))]
    );
    assert_eq!(t.mc.asked("device.close"), 0);
}

#[test]
fn another_environment_drops_the_last_ones_answers() {
    let t = tab();
    t.devices_are(state(&[IPHONE_17], &[]));
    t.invoke("refresh", &[]);
    ThreadDevices::set_thread(&t.engine, t.devices, "env-2", "thread-9", "");
    assert!(t.followed().is_empty());
    t.mc.answer(&t.engine, "device.list", Ok(state(&[IPHONE_17], &[])));
    assert_eq!(t.view("loaded"), "false");
    // Without a cluster MC, refreshing reads the list.
    t.invoke("refresh", &[]);
    t.mc.answer(&t.engine, "device.list", Ok(state(&[PIXEL_9], &[])));
    assert_eq!(t.offered(), "Android Emulators: Pixel 9 Open");
    assert_eq!(t.mc.calls().last().unwrap().0, "env-2");
}

#[test]
fn touches_keys_and_buttons_reach_a_simulator_through_the_mc() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    assert_eq!(read(&t.engine, t.root, "input"), Value::Bool(false));
    t.ios_input_connects();
    assert_eq!(read(&t.engine, t.root, "input"), Value::Bool(true));
    assert_eq!(
        t.mc.opened().last().unwrap(),
        &(
            format!("{HUB}/vendor/serve-sim/helper/ws"),
            format!("device={IPHONE}"),
            true
        )
    );
    assert!(t.mc.stream("stream.mjpeg").is_none());
    assert_eq!(t.sent("/helper/ws"), [json!([0x0d, {"enabled": false}])]);

    let half = Value::Real(0.5);
    t.on_stream("touch", &[Value::from("begin"), half.clone(), half.clone()]);
    t.on_stream("touch", &[Value::from("end"), half.clone(), half.clone()]);
    t.on_stream(
        "key",
        &[
            Value::Int(0x41),
            Value::from("a"),
            Value::Bool(false),
            Value::Bool(true),
        ],
    );
    t.on_stream(
        "key",
        &[
            Value::Int(0x41),
            Value::from("a"),
            Value::Bool(false),
            Value::Bool(false),
        ],
    );
    t.on_stream("pressButton", &[Value::from("home")]);
    assert_eq!(
        t.sent("/helper/ws"),
        [
            json!([3, {"type": "begin", "x": 0.5, "y": 0.5}]),
            json!([3, {"type": "end", "x": 0.5, "y": 0.5}]),
            json!([6, {"type": "down", "usage": 4}]),
            json!([6, {"type": "up", "usage": 4}]),
            json!([4, {"button": "home"}]),
        ]
    );
}

#[test]
fn a_lost_input_connection_connects_again() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.ios_input_connects();
    assert!(t.mc.end(&t.engine, t.stream_at("/helper/ws"), StreamEnd::default()));
    assert_eq!(read(&t.engine, t.root, "input"), Value::Bool(false));
    // Nothing is sent without a connection.
    t.on_stream("pressButton", &[Value::from("home")]);
    t.pass(RETRY_MS);
    // It primes the helper again, then connects.
    assert_eq!(t.mc.opened_at("stream.mjpeg"), 2);
    t.pass(stream::PRIME_MS);
    assert!(t.mc.stream("/helper/ws").is_some());
}

#[test]
fn touches_keys_and_buttons_reach_an_emulator_through_the_mc() {
    let t = tab();
    t.watching(&[PIXEL_9], &[PIXEL], PIXEL);
    t.android_sends();
    t.decoded();
    t.sent("/serve-emu/ws");
    let half = Value::Real(0.5);
    t.on_stream("touch", &[Value::from("begin"), half.clone(), half.clone()]);
    t.on_stream("touch", &[Value::from("end"), half.clone(), half.clone()]);
    t.on_stream(
        "key",
        &[
            Value::Int(0x41),
            Value::from("a"),
            Value::Bool(false),
            Value::Bool(true),
        ],
    );
    // A key going up, and a shortcut, type nothing.
    t.on_stream(
        "key",
        &[
            Value::Int(0x41),
            Value::from("a"),
            Value::Bool(false),
            Value::Bool(false),
        ],
    );
    t.on_stream(
        "key",
        &[
            Value::Int(0x41),
            Value::from("a"),
            Value::Bool(true),
            Value::Bool(true),
        ],
    );
    t.on_stream(
        "key",
        &[
            Value::Int(0x0100_0000),
            Value::from("\u{1b}"),
            Value::Bool(false),
            Value::Bool(true),
        ],
    );
    t.on_stream(
        "key",
        &[
            Value::Int(0x0100_0003),
            Value::from("\u{8}"),
            Value::Bool(false),
            Value::Bool(true),
        ],
    );
    t.on_stream("pressButton", &[Value::from("recents")]);
    assert_eq!(
        t.sent("/serve-emu/ws"),
        [
            json!({"action": "down", "type": "touch", "x": 0.5, "y": 0.5}),
            json!({"action": "up", "type": "touch", "x": 0.5, "y": 0.5}),
            json!({"text": "a", "type": "text"}),
            json!({"type": "back"}),
            json!({"keycode": 67, "type": "key"}),
            json!({"type": "recents"}),
        ]
    );
}

#[test]
fn rotating_a_simulator_turns_its_screen() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.ios_input_connects();
    t.sent("/helper/ws");
    assert!(read(&t.engine, t.root, "aspect").to_number() < 1.0);
    t.on_stream("rotate", &[]);
    assert_eq!(
        t.sent("/helper/ws"),
        [json!([7, {"orientation": "landscape_left"}])]
    );
    // The device reports it is held landscape_left.
    let mut config = vec![0x82];
    config.extend(
        json!({"height": 844, "orientation": "landscape_left", "width": 390})
            .to_string()
            .into_bytes(),
    );
    t.emit("/helper/ws", StreamEvent::Binary(config));
    // The screen is shown sideways and wider than tall.
    assert_eq!(read(&t.engine, t.root, "turn"), Value::Int(90));
    assert!(read(&t.engine, t.root, "aspect").to_number() > 1.0);
    // The touch lands where it is on the device's own portrait screen.
    t.on_stream(
        "touch",
        &[Value::from("begin"), Value::Real(0.0), Value::Real(0.5)],
    );
    assert_eq!(
        t.sent("/helper/ws"),
        [json!([3, {"type": "begin", "x": 0.5, "y": 1.0}])]
    );
}

#[test]
fn a_shell_without_an_mc_origin_retries_its_streams() {
    let t = tab();
    t.mc.no_origin.set(true);
    t.devices_are(state(&[IPHONE_17], &[IPHONE]));
    t.show(&tab_id_of("host-1", IPHONE));
    assert_eq!(t.text("status"), "connecting");
    assert_eq!(t.text("detail"), "The MC is not connected.");
    t.mc.no_origin.set(false);
    t.pass(RETRY_MS);
    assert!(t.mc.stream("stream.avcc").is_some());
}

#[test]
fn a_screen_set_to_a_streaming_stream_shows_its_newest_picture() {
    let t = tab();
    t.watching(&[IPHONE_17], &[IPHONE], IPHONE);
    t.ios_video_sends(ios_video(false));
    t.decoded();
    assert!(t.shown());
    t.engine
        .write_by_name(t.root, "devices", Value::Null)
        .unwrap();
    assert!(!t.shown());
    t.engine
        .write_by_name(t.root, "devices", Value::Object(t.devices))
        .unwrap();
    assert!(t.shown());
}
