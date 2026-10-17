//! desktop-qt's DeviceStream: one device's live screen and input, through
//! the MC's device hub proxy (`<hubBase>/vendor/...`, never the device
//! directly):
//!
//! - iOS (serve-sim): video is the `helper/<udid>/stream.avcc` body,
//!   envelopes of `u32be length (tag included), u8 tag, payload` (1 avcC
//!   record, 2 keyframe, 3 delta, 4 JPEG seed); input goes over
//!   `helper/ws?device=` as `[tag][json]`, and the helper answers with its
//!   screen config (0x82). One aborted `stream.mjpeg` request first starts
//!   the helper's capture.
//! - Android (serve-emu): one socket, `ws?device=<serial>&frame-meta=1`,
//!   carries Annex-B access units behind a 16-byte SEMU header and takes JSON
//!   gestures. `{"type":"video-session"}` means the encoder restarted (the
//!   device rotated): decoding starts over from a requested keyframe.
//!
//! Decoding is the [`Decode`]r's, off the UI thread. A decoder that falls
//! behind drops its backlog and the stream asks for a keyframe (Android) or
//! reads the AVCC body again, which starts with one (iOS).
//!
//! `status`: idle (no target, or not shown), connecting, streaming (a
//! picture arrived), or error with `detail` (`reconnect()` starts again). A
//! dropped connection retries after a second; no picture within the
//! first-frame timeout, an AVCC body that stops, a refused credential, a
//! decoder that cannot start, or video it refuses three times running is an
//! error.
//!
//! [`Core`] is the stream: it takes what the connections, timers and decoder
//! say and answers with [`Effect`]s. [`DeviceStream`] is the object QML binds
//! (`ThreadDevices.stream`); it runs those effects on the shell's MC
//! ([`Mc::open_stream`]) and hands pictures to the `DeviceScreen`s showing
//! it.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use ljos::item::{self, ImageHandle};
use ljos::prelude::{Atom, Cx, Engine, EngineError, ObjectId, QmlObject, qml_impl};
use serde_json::json;

use super::decoder::{Decode, Decoded};
use super::{Hub, percent};
use crate::device_screen;
use crate::json::Json;
use crate::keybindings::qt;
use crate::mc::{Mc, StreamEnd, StreamEvent, StreamId, StreamMessage};

pub const RETRY_MS: i32 = 1000;
pub const FIRST_FRAME_MS: i32 = 15000;
pub const PRIME_MS: i32 = 2000;
/// Units the decoder refuses in a row, each time from a fresh keyframe,
/// before the stream gives up: the video is not one it can decode.
pub const MAX_DECODE_FAILURES: u32 = 3;

const SEMU_MAGIC: u32 = 0x5345_4d55;
const SEMU_HEADER: usize = 16;

// serve-sim's input tags (to the helper), and its screen config (from it).
const IOS_TOUCH: u8 = 0x03;
const IOS_BUTTON: u8 = 0x04;
const IOS_KEY: u8 = 0x06;
const IOS_ORIENTATION: u8 = 0x07;
const IOS_HARDWARE_KEYBOARD: u8 = 0x0d;
const IOS_SCREEN_CONFIG: u8 = 0x82;

pub const ORIENTATIONS: [&str; 4] = [
    "portrait",
    "landscape_left",
    "portrait_upside_down",
    "landscape_right",
];

pub const NO_VIDEO: &str = "No video received from the device. Reconnect to try again.";
pub const STALLED: &str = "Device stream stopped receiving video. Reconnect to try again.";
pub const UNDECODABLE: &str = "The device's video could not be decoded. Reconnect to try again.";
pub const REFUSED: &str = "The MC refused the device stream. Reconnect to try again.";
pub const RESTARTED: &str = "Video decoder restarted.";

/// A connection the stream keeps: iOS's video body and the request that
/// primes its capture, and the socket (iOS's input, Android's everything).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Conn {
    Video,
    Prime,
    Socket,
}

/// The stream's single-shot timers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Timer {
    /// No picture since connecting: an error.
    FirstFrame,
    /// The AVCC body went quiet: an error.
    ReadStall,
    /// Reads the AVCC body again.
    VideoRetry,
    /// Connects the socket again (iOS: primes first).
    InputRetry,
    /// The prime request gives up waiting and the input socket follows.
    Prime,
}

const TIMERS: [Timer; 5] = [
    Timer::FirstFrame,
    Timer::ReadStall,
    Timer::VideoRetry,
    Timer::InputRetry,
    Timer::Prime,
];

/// What the stream asks of its host. `id`s tell a connection's or timer's
/// events from an older one's: [`Core::on_event`] and [`Core::on_timer`]
/// drop those not for the current one.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// Opens `conn` at `path` and `query` (percent-encoded) on the MC's
    /// origin: a GET, or with `socket` a websocket.
    Open {
        conn: Conn,
        id: u64,
        path: String,
        query: String,
        socket: bool,
    },
    Close(Conn),
    /// A message on the socket, which is connected.
    Send {
        binary: bool,
        bytes: Vec<u8>,
    },
    /// (Re)starts `timer`: it fires after `ms` unless stopped or started again.
    StartTimer {
        timer: Timer,
        id: u64,
        ms: i32,
    },
    StopTimer(Timer),
}

/// Which properties changed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Note {
    Status,
    Input,
    Screen,
    /// A different device (or none) is streamed: its picture goes.
    Target,
}

/// One device's stream: connections, timers and decoder, without the
/// engine.
pub struct Core {
    decoder: Box<dyn Decode>,
    hub_base: String,
    platform: String,
    device: String,
    active: bool,
    running: bool,
    /// The open connections, by the id of their open; the socket's says
    /// whether it is connected.
    video: Option<u64>,
    prime: Option<u64>,
    socket: Option<(u64, bool)>,
    /// iOS video bytes not yet a whole unit.
    buffer: Vec<u8>,
    awaiting_keyframe: bool,
    /// The running timers, by the id of their start.
    timers: HashMap<Timer, u64>,
    first_frame_ms: i32,
    retry_ms: i32,
    next: u64,
    streaming: bool,
    /// Decoder refusals since the last picture.
    decode_failures: u32,
    status: String,
    detail: String,
    input_connected: bool,
    /// The device's screen: iOS as its helper reports it, Android as its
    /// pictures come.
    width: i32,
    height: i32,
    orientation: String,
    effects: Vec<Effect>,
    notes: Vec<Note>,
}

impl std::fmt::Debug for Core {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Core")
            .field("platform", &self.platform)
            .field("device", &self.device)
            .field("status", &self.status)
            .field("detail", &self.detail)
            .finish_non_exhaustive()
    }
}

/// Whether the MC turned a connection away: its proxy refuses with 401 or
/// 403, or a relay closes with a policy code.
fn refused(end: &StreamEnd) -> bool {
    matches!(end.status, Some(401 | 403)) || matches!(end.code, Some(1008 | 4401))
}

fn is_landscape(orientation: &str) -> bool {
    orientation == "landscape_left" || orientation == "landscape_right"
}

/// Whether an Annex-B access unit holds an IDR slice (NAL type 5).
pub fn has_keyframe(unit: &[u8]) -> bool {
    let mut i = 0;
    while i + 3 < unit.len() {
        if unit[i] != 0 || unit[i + 1] != 0 {
            i += 1;
            continue;
        }
        let code = match (unit[i + 2], unit[i + 3]) {
            (1, _) => 3,
            (0, 1) => 4,
            _ => 0,
        };
        if code == 0 || i + code >= unit.len() {
            i += 1;
            continue;
        }
        if unit[i + code] & 0x1f == 5 {
            return true;
        }
        i += code + 1;
    }
    false
}

/// `[tag][json]`, as serve-sim's helper takes input.
fn tagged(tag: u8, payload: Json) -> Vec<u8> {
    let mut out = vec![tag];
    out.extend(payload.to_string().into_bytes());
    out
}

/// The USB HID usage serve-sim takes for a key (a `Qt.Key`), by the key a
/// US layout produces it with (shifted symbols share their key's usage).
pub fn hid_usage(key: i32) -> Option<i32> {
    let ascii = |c: u8| i32::from(c);
    if (ascii(b'A')..=ascii(b'Z')).contains(&key) {
        return Some(0x04 + key - ascii(b'A'));
    }
    if (ascii(b'1')..=ascii(b'9')).contains(&key) {
        return Some(0x1e + key - ascii(b'1'));
    }
    let usage = match key {
        qt::KEY_RETURN | qt::KEY_ENTER => 0x28,
        qt::KEY_ESCAPE => 0x29,
        qt::KEY_BACKSPACE => 0x2a,
        qt::KEY_TAB | qt::KEY_BACKTAB => 0x2b,
        qt::KEY_DELETE => 0x4c,
        qt::KEY_RIGHT => 0x4f,
        qt::KEY_LEFT => 0x50,
        qt::KEY_DOWN => 0x51,
        qt::KEY_UP => 0x52,
        qt::KEY_CONTROL => 0xe0,
        qt::KEY_SHIFT => 0xe1,
        qt::KEY_ALT => 0xe2,
        qt::KEY_META => 0xe3,
        _ => {
            let Ok(c) = u8::try_from(key) else {
                return None;
            };
            match c {
                b'0' | b')' => 0x27,
                b'!' => 0x1e,
                b'@' => 0x1f,
                b'#' => 0x20,
                b'$' => 0x21,
                b'%' => 0x22,
                b'^' => 0x23,
                b'&' => 0x24,
                b'*' => 0x25,
                b'(' => 0x26,
                b' ' => 0x2c,
                b'-' | b'_' => 0x2d,
                b'=' | b'+' => 0x2e,
                b'[' | b'{' => 0x2f,
                b']' | b'}' => 0x30,
                b'\\' | b'|' => 0x31,
                b';' | b':' => 0x33,
                b'\'' | b'"' => 0x34,
                b'`' | b'~' => 0x35,
                b',' | b'<' => 0x36,
                b'.' | b'>' => 0x37,
                b'/' | b'?' => 0x38,
                _ => return None,
            }
        }
    };
    Some(usage)
}

/// The Android keycode serve-emu takes for a key (characters go as text).
pub fn android_keycode(key: i32) -> Option<i32> {
    Some(match key {
        qt::KEY_UP => 19,
        qt::KEY_DOWN => 20,
        qt::KEY_LEFT => 21,
        qt::KEY_RIGHT => 22,
        qt::KEY_TAB => 61,
        qt::KEY_RETURN | qt::KEY_ENTER => 66,
        qt::KEY_BACKSPACE => 67,
        qt::KEY_DELETE => 112,
        qt::KEY_HOME => 122,
        qt::KEY_END => 123,
        qt::KEY_PAGE_UP => 92,
        qt::KEY_PAGE_DOWN => 93,
        _ => return None,
    })
}

impl Core {
    pub fn new(decoder: Box<dyn Decode>) -> Core {
        Core {
            decoder,
            hub_base: String::new(),
            platform: String::new(),
            device: String::new(),
            active: false,
            running: false,
            video: None,
            prime: None,
            socket: None,
            buffer: Vec::new(),
            awaiting_keyframe: true,
            timers: HashMap::new(),
            first_frame_ms: FIRST_FRAME_MS,
            retry_ms: RETRY_MS,
            next: 0,
            streaming: false,
            decode_failures: 0,
            status: "idle".into(),
            detail: String::new(),
            input_connected: false,
            width: 0,
            height: 0,
            orientation: "portrait".into(),
            effects: Vec::new(),
            notes: Vec::new(),
        }
    }

    pub fn status(&self) -> &str {
        &self.status
    }
    pub fn detail(&self) -> &str {
        &self.detail
    }
    pub fn input_connected(&self) -> bool {
        self.input_connected
    }
    pub fn platform(&self) -> &str {
        &self.platform
    }
    pub fn orientation(&self) -> &str {
        &self.orientation
    }
    pub fn running(&self) -> bool {
        self.running
    }
    /// The connections open now.
    pub fn open(&self) -> Vec<Conn> {
        let mut open = Vec::new();
        if self.video.is_some() {
            open.push(Conn::Video);
        }
        if self.prime.is_some() {
            open.push(Conn::Prime);
        }
        if self.socket.is_some() {
            open.push(Conn::Socket);
        }
        open
    }
    /// The timers running now.
    pub fn timers(&self) -> Vec<Timer> {
        TIMERS
            .into_iter()
            .filter(|t| self.timers.contains_key(t))
            .collect()
    }
    pub fn decoder_mut(&mut self) -> &mut dyn Decode {
        &mut *self.decoder
    }

    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
    }
    pub fn take_notes(&mut self) -> Vec<Note> {
        std::mem::take(&mut self.notes)
    }

    fn ios(&self) -> bool {
        self.platform == "ios"
    }

    /// Degrees the picture turns to show as the device is held: iOS streams
    /// its raw portrait framebuffer while the device reports landscape.
    pub fn rotation(&self) -> i32 {
        if !self.ios() || self.width == 0 || self.width > self.height {
            return 0;
        }
        match self.orientation.as_str() {
            "landscape_left" => 90,
            "landscape_right" => -90,
            "portrait_upside_down" => 180,
            _ => 0,
        }
    }

    /// The device's width over height as the user sees it.
    pub fn aspect(&self) -> f64 {
        if self.width == 0 || self.height == 0 {
            return if self.ios() { 9.0 / 19.5 } else { 9.0 / 20.0 };
        }
        let longer = f64::from(self.width.max(self.height));
        let shorter = f64::from(self.width.min(self.height));
        if is_landscape(&self.orientation) {
            longer / shorter
        } else {
            shorter / longer
        }
    }

    fn note(&mut self, note: Note) {
        if !self.notes.contains(&note) {
            self.notes.push(note);
        }
    }

    fn id(&mut self) -> u64 {
        self.next += 1;
        self.next
    }

    fn vendor_path(&self, path: &str) -> String {
        let vendor = if self.ios() {
            "/vendor/serve-sim"
        } else {
            "/vendor/serve-emu"
        };
        format!("{}{vendor}{path}", self.hub_base)
    }

    fn start_timer(&mut self, timer: Timer) {
        let ms = match timer {
            Timer::FirstFrame | Timer::ReadStall => self.first_frame_ms,
            Timer::VideoRetry | Timer::InputRetry => self.retry_ms,
            Timer::Prime => PRIME_MS,
        };
        let id = self.id();
        self.timers.insert(timer, id);
        self.effects.push(Effect::StartTimer { timer, id, ms });
    }

    fn stop_timer(&mut self, timer: Timer) {
        if self.timers.remove(&timer).is_some() {
            self.effects.push(Effect::StopTimer(timer));
        }
    }

    fn close(&mut self, conn: Conn) {
        let was = match conn {
            Conn::Video => self.video.take().is_some(),
            Conn::Prime => self.prime.take().is_some(),
            Conn::Socket => self.socket.take().is_some(),
        };
        if was {
            self.effects.push(Effect::Close(conn));
        }
    }

    fn open_conn(&mut self, conn: Conn, path: String, query: String, socket: bool) {
        let id = self.id();
        match conn {
            Conn::Video => self.video = Some(id),
            Conn::Prime => self.prime = Some(id),
            Conn::Socket => self.socket = Some((id, false)),
        }
        self.effects.push(Effect::Open {
            conn,
            id,
            path,
            query,
            socket,
        });
    }

    /// The device to stream: its hub base path (DeviceServiceState's
    /// `hubBasePath`), ios or android, and its id. Empty: none.
    pub fn set_target(&mut self, hub_base: &str, platform: &str, device: &str) {
        if hub_base == self.hub_base && platform == self.platform && device == self.device {
            return;
        }
        self.stop("idle", "");
        self.hub_base = hub_base.into();
        self.platform = platform.into();
        self.device = device.into();
        self.width = 0;
        self.height = 0;
        self.orientation = "portrait".into();
        self.note(Note::Target);
        self.note(Note::Screen);
        self.start();
    }

    /// Streams only while shown; hiding closes every connection.
    pub fn set_active(&mut self, active: bool) {
        if active == self.active {
            return;
        }
        self.active = active;
        if active {
            self.start();
        } else {
            self.stop("idle", "");
        }
    }

    /// For running timers too, from their next start.
    pub fn set_timeouts(&mut self, first_frame_ms: i32, retry_ms: i32) {
        self.first_frame_ms = first_frame_ms;
        self.retry_ms = retry_ms;
    }

    /// Starts over after an error.
    pub fn reconnect(&mut self) {
        self.stop("idle", "");
        self.start();
    }

    fn start(&mut self) {
        if self.running {
            return;
        }
        if !self.active || self.hub_base.is_empty() || self.device.is_empty() {
            self.set_status("idle", "");
            return;
        }
        self.running = true;
        self.decode_failures = 0;
        self.connecting("");
        if self.ios() {
            self.prime_ios();
            self.read_ios_video();
        } else {
            self.connect_android();
        }
    }

    /// Closes every connection, leaving `status`.
    fn stop(&mut self, status: &str, detail: &str) {
        self.running = false;
        for timer in TIMERS {
            self.stop_timer(timer);
        }
        self.close(Conn::Video);
        self.close(Conn::Prime);
        self.close(Conn::Socket);
        self.buffer.clear();
        self.decoder.reset(None);
        self.streaming = false;
        self.set_input(false);
        self.set_status(status, detail);
    }

    fn set_status(&mut self, status: &str, detail: &str) {
        if status == self.status && detail == self.detail {
            return;
        }
        self.status = status.into();
        self.detail = detail.into();
        self.note(Note::Status);
    }

    fn set_input(&mut self, connected: bool) {
        if connected != self.input_connected {
            self.input_connected = connected;
            self.note(Note::Input);
        }
    }

    /// Waiting for a picture again: one must come within the first-frame
    /// timeout.
    fn connecting(&mut self, detail: &str) {
        self.streaming = false;
        if !self.timers.contains_key(&Timer::FirstFrame) {
            self.start_timer(Timer::FirstFrame);
        }
        self.set_status("connecting", detail);
    }

    fn fail(&mut self, detail: &str) {
        if self.running {
            self.stop("error", detail);
        }
    }

    fn unauthorized(&mut self) {
        self.fail(REFUSED);
    }

    fn retry(&mut self, timer: Timer) {
        if self.running && !self.timers.contains_key(&timer) {
            self.start_timer(timer);
        }
    }

    /// What the decoder said.
    pub fn on_decoded(&mut self, event: Decoded) {
        match event {
            Decoded::Frame => self.on_frame(),
            Decoded::Broken => {
                if !self.running {
                    return;
                }
                self.decode_failures += 1;
                if self.decode_failures >= MAX_DECODE_FAILURES {
                    self.fail(UNDECODABLE);
                } else {
                    self.recover();
                }
            }
            Decoded::Unsupported(why) => {
                self.fail(&format!("Cannot decode the device's video. {why}"));
            }
        }
    }

    fn on_frame(&mut self) {
        if !self.running {
            return;
        }
        if !self.ios() {
            // serve-emu's pictures come at the size the device is held.
            let (width, height) = self.decoder.source_size();
            if width > 0 && height > 0 {
                let orientation = if width > height {
                    "landscape_left"
                } else {
                    "portrait"
                };
                self.set_screen(width as i32, height as i32, orientation);
            }
        }
        self.decode_failures = 0;
        if self.streaming {
            return;
        }
        self.streaming = true;
        self.stop_timer(Timer::FirstFrame);
        self.set_status("streaming", "");
    }

    /// The decoder fell behind or choked: start over from a keyframe, on iOS
    /// by reading the body again after the retry delay.
    fn recover(&mut self) {
        if !self.running {
            return;
        }
        self.decoder.reset(None);
        if self.ios() {
            self.close(Conn::Video);
            self.stop_timer(Timer::ReadStall);
            self.connecting(RESTARTED);
            self.retry(Timer::VideoRetry);
        } else {
            self.awaiting_keyframe = true;
            self.connecting(RESTARTED);
            self.request_keyframe();
        }
    }

    /// A timer fired.
    pub fn on_timer(&mut self, timer: Timer, id: u64) {
        if self.timers.get(&timer) != Some(&id) {
            return;
        }
        self.timers.remove(&timer);
        match timer {
            Timer::FirstFrame => self.fail(NO_VIDEO),
            Timer::ReadStall => self.fail(STALLED),
            Timer::VideoRetry => self.read_ios_video(),
            Timer::InputRetry => {
                if self.ios() {
                    self.prime_ios();
                } else {
                    self.connect_android();
                }
            }
            Timer::Prime => self.prime_done(None),
        }
    }

    /// What a connection said.
    pub fn on_event(&mut self, conn: Conn, id: u64, event: StreamEvent) {
        let current = match conn {
            Conn::Video => self.video == Some(id),
            Conn::Prime => self.prime == Some(id),
            Conn::Socket => self.socket.is_some_and(|(open, _)| open == id),
        };
        if !current {
            return;
        }
        match conn {
            Conn::Video => self.on_video(event),
            Conn::Prime => match event {
                StreamEvent::Opened { status } => self.prime_done(Some(status)),
                StreamEvent::Ended(end) => {
                    // Ended by itself: the stream is closed already.
                    self.prime = None;
                    self.prime_finished(end.status);
                }
                _ => self.prime_done(None),
            },
            Conn::Socket if self.ios() => self.on_ios_input(event),
            Conn::Socket => self.on_android(event),
        }
    }

    // iOS video: the AVCC body, demuxed into the decoder.
    fn read_ios_video(&mut self) {
        if !self.running || self.video.is_some() {
            return;
        }
        self.buffer.clear();
        let path = self.vendor_path(&format!("/helper/{}/stream.avcc", percent(&self.device)));
        self.open_conn(Conn::Video, path, String::new(), false);
        self.start_timer(Timer::ReadStall);
    }

    fn on_video(&mut self, event: StreamEvent) {
        if !self.running {
            return;
        }
        match event {
            StreamEvent::Opened { status } => {
                if status == 401 || status == 403 {
                    return self.unauthorized();
                }
                if status / 100 != 2 {
                    // The proxy's refusal (the hub is down or the device
                    // went away): retry.
                    self.close(Conn::Video);
                    self.stop_timer(Timer::ReadStall);
                    self.connecting(&format!("stream {status}"));
                    self.retry(Timer::VideoRetry);
                }
            }
            StreamEvent::Data(bytes) => self.on_ios_video(&bytes),
            StreamEvent::Text(_) | StreamEvent::Binary(_) => {}
            StreamEvent::Ended(end) => {
                self.video = None;
                self.stop_timer(Timer::ReadStall);
                if refused(&end) {
                    return self.unauthorized();
                }
                self.decoder.reset(None);
                self.connecting(end.error.as_deref().unwrap_or(""));
                self.retry(Timer::VideoRetry);
            }
        }
    }

    fn on_ios_video(&mut self, bytes: &[u8]) {
        // An AVCC body can stay open after its helper stops producing frames.
        self.start_timer(Timer::ReadStall);
        self.buffer.extend_from_slice(bytes);
        let mut offset = 0;
        while self.buffer.len() - offset >= 4 {
            let at = &self.buffer[offset..];
            let length = u32::from_be_bytes([at[0], at[1], at[2], at[3]]) as usize;
            if self.buffer.len() - offset - 4 < length {
                break;
            }
            if length >= 1 {
                let tag = self.buffer[offset + 4];
                let payload = self.buffer[offset + 5..offset + 4 + length].to_vec();
                match tag {
                    1 => self.decoder.reset(Some(payload)),
                    2 | 3 => {
                        if !self.decoder.push(payload, 0, tag == 2) {
                            self.buffer.clear();
                            self.recover();
                            return;
                        }
                    }
                    4 => self.decoder.push_jpeg(payload),
                    _ => {}
                }
            }
            offset += 4 + length;
        }
        self.buffer.drain(..offset);
    }

    // serve-sim's helper takes input and reports its screen only once
    // capture runs, which the AVCC stream does not reliably start; one
    // aborted MJPEG request does. The input socket follows either way.
    fn prime_ios(&mut self) {
        if !self.running || self.prime.is_some() || self.socket.is_some() {
            return;
        }
        let path = self.vendor_path(&format!("/helper/{}/stream.mjpeg", percent(&self.device)));
        self.open_conn(Conn::Prime, path, String::new(), false);
        self.start_timer(Timer::Prime);
    }

    /// The prime request answered (with its status), or gave up waiting.
    fn prime_done(&mut self, status: Option<u16>) {
        if self.prime.is_none() {
            return;
        }
        self.close(Conn::Prime);
        self.prime_finished(status);
    }

    fn prime_finished(&mut self, status: Option<u16>) {
        self.stop_timer(Timer::Prime);
        if matches!(status, Some(401 | 403)) {
            return self.unauthorized();
        }
        self.connect_ios_input();
    }

    fn connect_ios_input(&mut self) {
        if !self.running || self.socket.is_some() {
            return;
        }
        let path = self.vendor_path("/helper/ws");
        let query = format!("device={}", percent(&self.device));
        self.open_conn(Conn::Socket, path, query, true);
    }

    fn on_ios_input(&mut self, event: StreamEvent) {
        match event {
            StreamEvent::Opened { .. } => {
                if let Some((_, connected)) = &mut self.socket {
                    *connected = true;
                }
                self.send(
                    tagged(IOS_HARDWARE_KEYBOARD, json!({"enabled": false})),
                    true,
                );
                self.set_input(true);
            }
            StreamEvent::Binary(message) => {
                if message.first() != Some(&IOS_SCREEN_CONFIG) {
                    return;
                }
                let config: Json = serde_json::from_slice(&message[1..]).unwrap_or_default();
                let int = |key: &str| {
                    config
                        .get(key)
                        .and_then(Json::as_f64)
                        .map_or(0, |n| n as i32)
                };
                let (width, height) = (int("width"), int("height"));
                if width > 0 && height > 0 {
                    let orientation = config
                        .get("orientation")
                        .and_then(Json::as_str)
                        .unwrap_or_default()
                        .to_owned();
                    self.set_screen(width, height, &orientation);
                }
            }
            StreamEvent::Data(_) | StreamEvent::Text(_) => {}
            StreamEvent::Ended(end) => {
                self.socket = None;
                self.set_input(false);
                if refused(&end) {
                    return self.unauthorized();
                }
                self.retry(Timer::InputRetry);
            }
        }
    }

    // Android: one socket for video and input.
    fn connect_android(&mut self) {
        if !self.running || self.socket.is_some() {
            return;
        }
        self.awaiting_keyframe = true;
        let path = self.vendor_path("/ws");
        let query = format!("device={}&frame-meta=1", percent(&self.device));
        self.open_conn(Conn::Socket, path, query, true);
    }

    fn on_android(&mut self, event: StreamEvent) {
        match event {
            StreamEvent::Opened { .. } => {
                if let Some((_, connected)) = &mut self.socket {
                    *connected = true;
                }
                self.connecting("");
                self.set_input(true);
            }
            StreamEvent::Binary(message) => self.on_android_message(message),
            StreamEvent::Text(message) => {
                // The encoder restarts at a new size when the device rotates;
                // the next keyframe carries a fresh SPS.
                let message: Json = serde_json::from_str(&message).unwrap_or_default();
                if message.get("type").and_then(Json::as_str) == Some("video-session") {
                    self.decoder.reset(None);
                    self.awaiting_keyframe = true;
                    self.connecting("");
                    self.request_keyframe();
                }
            }
            StreamEvent::Data(_) => {}
            StreamEvent::Ended(end) => {
                self.socket = None;
                self.decoder.reset(None);
                self.set_input(false);
                if refused(&end) {
                    return self.unauthorized();
                }
                self.connecting(&end.reason);
                self.retry(Timer::InputRetry);
            }
        }
    }

    fn on_android_message(&mut self, message: Vec<u8>) {
        // A SEMU header says whether the unit behind it is a keyframe.
        let semu = message.len() > SEMU_HEADER
            && u32::from_be_bytes([message[0], message[1], message[2], message[3]]) == SEMU_MAGIC
            && message[4] == 1;
        let keyframe = if semu {
            message[5] & 1 != 0
        } else {
            has_keyframe(&message)
        };
        if self.awaiting_keyframe {
            if !keyframe {
                self.request_keyframe();
                return;
            }
            self.awaiting_keyframe = false;
        }
        let offset = if semu { SEMU_HEADER } else { 0 };
        if !self.decoder.push(message, offset, keyframe) {
            self.recover();
        }
    }

    fn request_keyframe(&mut self) {
        if !self.ios() {
            let message = json!({"ack": false, "type": "reset-video"});
            self.send(message.to_string().into_bytes(), false);
        }
    }

    fn send(&mut self, bytes: Vec<u8>, binary: bool) {
        if self.running && matches!(self.socket, Some((_, true))) {
            self.effects.push(Effect::Send { binary, bytes });
        }
    }

    fn set_screen(&mut self, width: i32, height: i32, orientation: &str) {
        let known = if ORIENTATIONS.contains(&orientation) {
            orientation
        } else {
            "portrait"
        };
        if width == self.width && height == self.height && known == self.orientation {
            return;
        }
        self.width = width;
        self.height = height;
        self.orientation = known.into();
        self.note(Note::Screen);
    }

    /// A touch at x, y (0..1 across the picture as shown); phase begin, move
    /// or end.
    pub fn touch(&mut self, phase: &str, x: f64, y: f64) {
        let (x, y) = (x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
        if self.ios() {
            // serve-sim takes points in its raw framebuffer, which stays
            // portrait while the device turns.
            let (mut raw_x, mut raw_y) = (x, y);
            if self.width != 0 && self.width <= self.height {
                match self.orientation.as_str() {
                    "landscape_left" => (raw_x, raw_y) = (y, 1.0 - x),
                    "landscape_right" => (raw_x, raw_y) = (1.0 - y, x),
                    "portrait_upside_down" => (raw_x, raw_y) = (1.0 - x, 1.0 - y),
                    _ => {}
                }
            }
            let message = json!({"type": phase, "x": raw_x, "y": raw_y});
            self.send(tagged(IOS_TOUCH, message), true);
            return;
        }
        let action = match phase {
            "begin" => "down",
            "move" => "move",
            _ => "up",
        };
        let message = json!({"action": action, "type": "touch", "x": x, "y": y});
        self.send(message.to_string().into_bytes(), false);
    }

    /// A key (`Qt.Key`) going down or up, with the text it types and
    /// whether ctrl or meta is held.
    pub fn key(&mut self, qt_key: i32, text: &str, command: bool, down: bool) {
        if self.ios() {
            if let Some(usage) = hid_usage(qt_key) {
                let kind = if down { "down" } else { "up" };
                let message = json!({"type": kind, "usage": usage});
                self.send(tagged(IOS_KEY, message), true);
            }
            return;
        }
        if !down {
            return;
        }
        let message = if qt_key == qt::KEY_ESCAPE {
            json!({"type": "back"})
        } else if let Some(keycode) = android_keycode(qt_key) {
            json!({"keycode": keycode, "type": "key"})
        } else {
            // One printable UTF-16 unit, as QChar::isPrint.
            let mut units = text.encode_utf16();
            let single = units.next().is_some() && units.next().is_none();
            let printable = text.chars().all(|c| !c.is_control());
            if !single || !printable || command {
                return;
            }
            json!({"text": text, "type": "text"})
        };
        self.send(message.to_string().into_bytes(), false);
    }

    /// home, back, recents or power (iOS: home, recents as the app
    /// switcher, power as lock; back does nothing).
    pub fn press_button(&mut self, button: &str) {
        if self.ios() {
            let name = match button {
                "home" => "home",
                "recents" => "app_switcher",
                "power" => "lock",
                _ => return,
            };
            self.send(tagged(IOS_BUTTON, json!({"button": name})), true);
            return;
        }
        if ["home", "back", "recents", "power"].contains(&button) {
            let message = json!({"type": button});
            self.send(message.to_string().into_bytes(), false);
        }
    }

    /// iOS: the next orientation, clockwise from portrait.
    pub fn rotate(&mut self) {
        if !self.ios() {
            return;
        }
        let at = ORIENTATIONS
            .iter()
            .position(|o| *o == self.orientation)
            .unwrap_or(0);
        let next = ORIENTATIONS[(at + 1) % ORIENTATIONS.len()];
        self.send(tagged(IOS_ORIENTATION, json!({"orientation": next})), true);
    }
}

/// The open connection and running timer objects behind a stream's [`Core`].
struct Inner {
    core: RefCell<Core>,
    mc: Rc<dyn Mc>,
    streams: RefCell<HashMap<Conn, StreamId>>,
    timers: RefCell<HashMap<Timer, ObjectId>>,
    /// The `DeviceScreen`s showing the stream.
    screens: RefCell<Vec<ObjectId>>,
    /// The newest picture, for a screen that starts showing the stream.
    last: RefCell<Option<ImageHandle>>,
    /// The connections whose open failed, waiting to be told so.
    failed: RefCell<Vec<(Conn, u64)>>,
    polling: Cell<bool>,
}

impl Drop for Inner {
    fn drop(&mut self) {
        for (_, id) in self.streams.get_mut().drain() {
            self.mc.close_stream(id);
        }
    }
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeviceStream")
            .field("core", &self.core)
            .finish_non_exhaustive()
    }
}

/// One device's live screen and input: `ThreadDevices.stream`.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "DeviceStream", uncreatable)]
pub struct DeviceStream {
    /// idle, connecting, streaming or error.
    #[qml(readonly, notify)]
    status: Atom,
    /// Why, with error; what it waits on, with connecting.
    #[qml(readonly, notify)]
    detail: Atom,
    #[qml(readonly, notify)]
    input_connected: bool,
    #[qml(readonly, notify)]
    platform: Atom,
    /// portrait, landscape_left, portrait_upside_down or landscape_right.
    #[qml(readonly, notify)]
    orientation: Atom,
    /// Degrees the picture turns to show as the device is held.
    #[qml(readonly, notify)]
    rotation: i32,
    /// The device's width over height as the user sees it.
    #[qml(readonly, notify)]
    aspect: f64,
    #[qml(skip)]
    inner: Rc<Inner>,
}

fn inner_of(engine: &Engine, obj: ObjectId) -> Option<Rc<Inner>> {
    engine
        .with::<DeviceStream, _>(obj, |s| s.inner.clone())
        .ok()
}

fn warn(engine: &Engine, result: Result<(), EngineError>) {
    if let Err(e) = result {
        engine.log(
            ljos::prelude::LogLevel::Warning,
            "DeviceStream",
            e.to_string(),
        );
    }
}

impl DeviceStream {
    /// A stream owned by `owner`, opened on `mc`'s origin, decoding with the
    /// engine's decoder ([`super::set_decoders`]).
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        mc: Rc<dyn Mc>,
    ) -> Result<ObjectId, EngineError> {
        let core = Core::new(super::decoder(engine));
        let aspect = core.aspect();
        let inner = Rc::new(Inner {
            core: RefCell::new(core),
            mc,
            streams: RefCell::default(),
            timers: RefCell::default(),
            screens: RefCell::default(),
            last: RefCell::default(),
            failed: RefCell::default(),
            polling: Cell::new(false),
        });
        let stream = DeviceStream {
            status: Atom::new("idle"),
            detail: Atom::new(""),
            input_connected: false,
            platform: Atom::new(""),
            orientation: Atom::new("portrait"),
            rotation: 0,
            aspect,
            inner,
        };
        let obj = engine.create_native(stream, owner)?;
        Hub::of(engine).streams.borrow_mut().push(obj);
        Ok(obj)
    }

    /// See [`Core::set_target`].
    pub fn set_target(
        engine: &Engine,
        obj: ObjectId,
        hub_base: &str,
        platform: &str,
        device: &str,
    ) {
        Self::update(engine, obj, |c| c.set_target(hub_base, platform, device));
    }

    /// See [`Core::set_active`].
    pub fn set_active(engine: &Engine, obj: ObjectId, active: bool) {
        Self::update(engine, obj, |c| c.set_active(active));
    }

    pub fn set_timeouts(engine: &Engine, obj: ObjectId, first_frame_ms: i32, retry_ms: i32) {
        Self::update(engine, obj, |c| c.set_timeouts(first_frame_ms, retry_ms));
    }

    /// Runs `f` on the stream of `obj`, then tells the properties and the
    /// screens what it changed and runs what it asked for. None when `obj`
    /// is not a live stream.
    pub fn update<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&mut Core) -> R) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let (result, notes, effects) = {
            let mut core = inner.core.borrow_mut();
            let result = f(&mut core);
            (result, core.take_notes(), core.take_effects())
        };
        settle(engine, obj, &inner, &notes, effects);
        Some(result)
    }

    /// Reads the stream of `obj`.
    pub fn read<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&Core) -> R) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let core = inner.core.borrow();
        Some(f(&core))
    }

    /// Hands what the decoder said to the stream and its pictures to the
    /// screens. On the Engine thread, when the decoder woke it.
    pub(super) fn poll(engine: &Engine, obj: ObjectId) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        if inner.polling.replace(true) {
            return;
        }
        let limit = limit_of(engine, &inner.screens.borrow());
        let events = {
            let mut core = inner.core.borrow_mut();
            core.decoder_mut().set_maximum_size(limit);
            core.decoder_mut().take_events()
        };
        for event in events {
            if event == Decoded::Frame {
                let picture = inner.core.borrow_mut().decoder_mut().take_frame();
                if let Some(picture) = picture {
                    show(engine, &inner, picture);
                }
            }
            Self::update(engine, obj, |c| c.on_decoded(event));
        }
        inner.polling.set(false);
    }
}

/// The largest picture worth making: the first screen's size in device
/// pixels (Qt's `DeviceScreen::limit()`).
fn limit_of(engine: &Engine, screens: &[ObjectId]) -> (u32, u32) {
    let Some(&screen) = screens.iter().find(|s| engine.is_alive(**s)) else {
        return (0, 0);
    };
    let ratio = Some(item::device_pixel_ratio(engine, screen))
        .filter(|r| r.is_finite() && *r > 0.0)
        .unwrap_or(1.0);
    let side = |name: &str| {
        let n = engine.read_by_name(screen, name).to_number() * ratio;
        if n.is_finite() && n > 0.0 {
            n.round() as u32
        } else {
            0
        }
    };
    (side("width"), side("height"))
}

fn show(engine: &Engine, inner: &Inner, picture: super::decoder::Picture) {
    let Ok(image) = ImageHandle::from_straight(picture.width, picture.height, picture.rgba) else {
        return;
    };
    let screens = {
        let mut screens = inner.screens.borrow_mut();
        screens.retain(|s| engine.is_alive(*s));
        screens.clone()
    };
    for screen in screens {
        device_screen::show_image(engine, screen, image.clone());
    }
    *inner.last.borrow_mut() = Some(image);
}

fn drop_frames(engine: &Engine, inner: &Inner) {
    inner.last.borrow_mut().take();
    let screens = inner.screens.borrow().clone();
    for screen in screens {
        device_screen::drop_frame(engine, screen);
    }
}

fn tell(engine: &Engine, obj: ObjectId, inner: &Inner, notes: &[Note]) {
    if notes.is_empty() {
        return;
    }
    let (status, detail, input, platform, orientation, rotation, aspect) = {
        let c = inner.core.borrow();
        (
            Atom::new(c.status()),
            Atom::new(c.detail()),
            c.input_connected(),
            Atom::new(c.platform()),
            Atom::new(c.orientation()),
            c.rotation(),
            c.aspect(),
        )
    };
    let drop_picture = notes.contains(&Note::Target)
        || (notes.contains(&Note::Status) && (&*status == "connecting" || &*status == "idle"));
    if drop_picture {
        drop_frames(engine, inner);
    }
    let result = engine.batch(|| {
        let mut result = Ok(());
        for note in notes {
            result = result.and_then(|()| match note {
                Note::Status => engine
                    .set_internal(obj, DeviceStream::STATUS, status.clone())
                    .and_then(|()| engine.set_internal(obj, DeviceStream::DETAIL, detail.clone())),
                Note::Input => engine.set_internal(obj, DeviceStream::INPUT_CONNECTED, input),
                Note::Screen => engine
                    .set_internal(obj, DeviceStream::PLATFORM, platform.clone())
                    .and_then(|()| {
                        engine.set_internal(obj, DeviceStream::ORIENTATION, orientation.clone())
                    })
                    .and_then(|()| engine.set_internal(obj, DeviceStream::ROTATION, rotation))
                    .and_then(|()| engine.set_internal(obj, DeviceStream::ASPECT, aspect)),
                Note::Target => Ok(()),
            });
        }
        result
    });
    warn(engine, result);
}

/// Tells the properties and the screens what the core changed, runs what it
/// asked for, then ends each open that failed, after what was asked with it.
fn settle(engine: &Engine, obj: ObjectId, inner: &Inner, notes: &[Note], effects: Vec<Effect>) {
    tell(engine, obj, inner, notes);
    for effect in effects {
        run(engine, obj, inner, effect);
    }
    let failed = std::mem::take(&mut *inner.failed.borrow_mut());
    for (conn, id) in failed {
        let end = StreamEnd {
            error: Some("The MC is not connected.".into()),
            ..StreamEnd::default()
        };
        let (notes, effects) = {
            let mut core = inner.core.borrow_mut();
            core.on_event(conn, id, StreamEvent::Ended(end));
            (core.take_notes(), core.take_effects())
        };
        settle(engine, obj, inner, &notes, effects);
    }
}

fn run(engine: &Engine, obj: ObjectId, inner: &Inner, effect: Effect) {
    match effect {
        Effect::Open {
            conn,
            id,
            path,
            query,
            socket,
        } => {
            let opened = inner.mc.open_stream(
                &path,
                &query,
                socket,
                Box::new(move |engine, event| {
                    DeviceStream::update(engine, obj, |c| c.on_event(conn, id, event));
                }),
            );
            match opened {
                Some(stream) => {
                    let old = inner.streams.borrow_mut().insert(conn, stream);
                    if let Some(old) = old {
                        inner.mc.close_stream(old);
                    }
                }
                None => inner.failed.borrow_mut().push((conn, id)),
            }
        }
        Effect::Close(conn) => {
            let stream = inner.streams.borrow_mut().remove(&conn);
            if let Some(stream) = stream {
                inner.mc.close_stream(stream);
            }
        }
        Effect::Send { binary, bytes } => {
            let stream = inner.streams.borrow().get(&Conn::Socket).copied();
            if let Some(stream) = stream {
                let message = if binary {
                    StreamMessage::Binary(bytes)
                } else {
                    StreamMessage::Text(String::from_utf8_lossy(&bytes).into_owned())
                };
                inner.mc.send_on_stream(stream, message);
            }
        }
        Effect::StartTimer { timer, id, ms } => {
            let old = inner.timers.borrow_mut().remove(&timer);
            if let Some(old) = old {
                engine.destroy(old);
            }
            if let Some(made) = single_shot(engine, obj, ms, move |engine| {
                DeviceStream::update(engine, obj, |c| c.on_timer(timer, id));
            }) {
                inner.timers.borrow_mut().insert(timer, made);
            }
        }
        Effect::StopTimer(timer) => {
            let old = inner.timers.borrow_mut().remove(&timer);
            if let Some(old) = old {
                engine.destroy(old);
            }
        }
    }
}

/// A timer owned by `obj` that runs `f` once after `ms`.
fn single_shot(
    engine: &Engine,
    obj: ObjectId,
    ms: i32,
    f: impl Fn(&Engine) + 'static,
) -> Option<ObjectId> {
    let native = ljos::prelude::Timer {
        interval: ms,
        repeat: false,
        running: true,
        ..ljos::prelude::Timer::default()
    };
    let timer = engine.create_native(native, Some(obj)).ok()?;
    engine
        .connect_by_name(timer, "triggered", move |engine, _| f(engine))
        .ok()?;
    Some(timer)
}

/// `screen` shows `stream`'s pictures from now on, starting with its newest.
/// For `DeviceScreen`; false when `stream` is not a live `DeviceStream`.
pub fn attach_screen(engine: &Engine, stream: ObjectId, screen: ObjectId) -> bool {
    let Some(inner) = inner_of(engine, stream) else {
        return false;
    };
    {
        let mut screens = inner.screens.borrow_mut();
        if !screens.contains(&screen) {
            screens.push(screen);
        }
    }
    let last = inner.last.borrow().clone();
    if let Some(image) = last {
        device_screen::show_image(engine, screen, image);
    }
    true
}

/// `screen` no longer shows `stream`.
pub fn detach_screen(engine: &Engine, stream: ObjectId, screen: ObjectId) {
    if let Some(inner) = inner_of(engine, stream) {
        inner.screens.borrow_mut().retain(|s| *s != screen);
    }
}

#[qml_impl]
impl DeviceStream {
    /// Starts over after an error.
    #[qml(invokable)]
    fn reconnect(cx: &Cx) {
        DeviceStream::update(cx.engine, cx.this, Core::reconnect);
    }

    /// A touch at x, y (0..1 across the picture as shown); phase begin,
    /// move or end.
    #[qml(invokable)]
    fn touch(cx: &Cx, phase: Atom, x: f64, y: f64) {
        DeviceStream::update(cx.engine, cx.this, |c| c.touch(&phase, x, y));
    }

    /// A key (`Qt.Key`) going down or up, with the text it types and
    /// whether ctrl or meta is held.
    #[qml(invokable)]
    fn key(cx: &Cx, qt_key: i32, text: Atom, command: bool, down: bool) {
        DeviceStream::update(cx.engine, cx.this, |c| c.key(qt_key, &text, command, down));
    }

    /// home, back, recents or power.
    #[qml(invokable)]
    fn press_button(cx: &Cx, button: Atom) {
        DeviceStream::update(cx.engine, cx.this, |c| c.press_button(&button));
    }

    /// iOS: the next orientation, clockwise from portrait.
    #[qml(invokable)]
    fn rotate(cx: &Cx) {
        DeviceStream::update(cx.engine, cx.this, Core::rotate);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_keyframe_is_found_behind_either_start_code() {
        assert!(has_keyframe(&[0, 0, 0, 1, 0x65, 1]));
        assert!(has_keyframe(&[0, 0, 0, 1, 0x67, 0, 0, 1, 0x65]));
        assert!(!has_keyframe(&[0, 0, 0, 1, 0x41, 1, 2]));
        assert!(!has_keyframe(&[0, 0, 1]));
    }

    #[test]
    fn keys_map_as_serve_sim_and_serve_emu_take_them() {
        assert_eq!(hid_usage(i32::from(b'A')), Some(0x04));
        assert_eq!(hid_usage(i32::from(b'Z')), Some(0x1d));
        assert_eq!(hid_usage(i32::from(b'1')), Some(0x1e));
        assert_eq!(hid_usage(i32::from(b'0')), Some(0x27));
        assert_eq!(hid_usage(i32::from(b'?')), Some(0x38));
        assert_eq!(hid_usage(qt::KEY_RETURN), Some(0x28));
        assert_eq!(hid_usage(0x0100_0030), None); // Qt::Key_F1
        assert_eq!(android_keycode(qt::KEY_BACKSPACE), Some(67));
        assert_eq!(android_keycode(i32::from(b'A')), None);
    }
}
