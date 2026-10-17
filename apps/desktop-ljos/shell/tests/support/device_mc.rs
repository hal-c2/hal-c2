//! An MC for the Device tab's tests: calls held until the test answers
//! them, `devices` frames sent when the test says, and streams on its origin
//! the test plays the device hub's side of. Also a decoder the test scripts.
//! Included by the device tests (`#[path = "support/device_mc.rs"] mod
//! device_mc;`).

#![allow(dead_code)]

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use hal_c2_shell::device::decoder::{Decode, Decoded, Picture};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{
    Mc, McError, OnFrame, OnReady, OnStream, Reply, Resume, StreamEnd, StreamEvent, StreamId,
    StreamMessage, SubId,
};
use ljos::prelude::Engine;

/// One stream the shell opened.
pub struct Stream {
    pub id: StreamId,
    pub path: String,
    pub query: String,
    pub socket: bool,
    /// Closed by the shell, or ended by the test.
    pub closed: bool,
    pub sent: Vec<StreamMessage>,
    on_event: Rc<RefCell<OnStream>>,
}

/// (environment, method, payload, the reply until answered)
type Call = (String, String, Json, Option<Reply>);
type Follow = (SubId, Json, Rc<RefCell<OnFrame>>);

#[derive(Default)]
pub struct DeviceMc {
    calls: RefCell<Vec<Call>>,
    follows: RefCell<Vec<Follow>>,
    streams: RefCell<Vec<Stream>>,
    next: Cell<u64>,
    /// Streams cannot be opened (no MC origin).
    pub no_origin: Cell<bool>,
}

impl DeviceMc {
    pub fn new() -> Rc<DeviceMc> {
        Rc::new(DeviceMc::default())
    }

    fn id(&self) -> u64 {
        self.next.set(self.next.get() + 1);
        self.next.get()
    }

    /// (environment, method, payload) of every call, answered or not.
    pub fn calls(&self) -> Vec<(String, String, Json)> {
        self.calls
            .borrow()
            .iter()
            .map(|(e, m, p, _)| (e.clone(), m.clone(), p.clone()))
            .collect()
    }

    pub fn asked(&self, method: &str) -> usize {
        self.calls
            .borrow()
            .iter()
            .filter(|(_, m, _, _)| m == method)
            .count()
    }

    /// Whether a call to `method` waits for its answer.
    pub fn waiting(&self, method: &str) -> bool {
        self.calls
            .borrow()
            .iter()
            .any(|(_, m, _, r)| m == method && r.is_some())
    }

    /// Answers the oldest waiting call to `method`; its payload.
    pub fn answer(&self, engine: &Engine, method: &str, result: Result<Json, &str>) -> Json {
        let (payload, reply) = {
            let mut calls = self.calls.borrow_mut();
            let call = calls
                .iter_mut()
                .find(|(_, m, _, r)| m == method && r.is_some())
                .unwrap_or_else(|| panic!("{method} was asked"));
            (call.2.clone(), call.3.take())
        };
        if let Some(reply) = reply {
            reply(engine, result.map_err(McError::new));
        }
        payload
    }

    /// The shapes followed now.
    pub fn follows(&self) -> Vec<Json> {
        self.follows
            .borrow()
            .iter()
            .map(|(_, s, _)| s.clone())
            .collect()
    }

    /// Sends a `devices` frame with `state` to whoever follows `devices`.
    pub fn devices(&self, engine: &Engine, state: Json) {
        let mut frame = serde_json::Map::new();
        frame.insert("t".into(), "devices".into());
        frame.insert("state".into(), state);
        let handlers: Vec<_> = self
            .follows
            .borrow()
            .iter()
            .filter(|(_, s, _)| s.get("type").and_then(Json::as_str) == Some("devices"))
            .map(|(_, _, h)| h.clone())
            .collect();
        for handler in handlers {
            (handler.borrow_mut())(engine, &frame);
        }
    }

    /// (path, query, socket) of every stream opened, in order.
    pub fn opened(&self) -> Vec<(String, String, bool)> {
        self.streams
            .borrow()
            .iter()
            .map(|s| (s.path.clone(), s.query.clone(), s.socket))
            .collect()
    }

    /// How many streams were opened at a path ending with `suffix`.
    pub fn opened_at(&self, suffix: &str) -> usize {
        self.streams
            .borrow()
            .iter()
            .filter(|s| s.path.ends_with(suffix))
            .count()
    }

    /// The paths of the streams open now.
    pub fn open_now(&self) -> Vec<String> {
        self.streams
            .borrow()
            .iter()
            .filter(|s| !s.closed)
            .map(|s| s.path.clone())
            .collect()
    }

    /// The newest open stream at a path ending with `suffix`.
    pub fn stream(&self, suffix: &str) -> Option<StreamId> {
        self.streams
            .borrow()
            .iter()
            .rev()
            .find(|s| !s.closed && s.path.ends_with(suffix))
            .map(|s| s.id)
    }

    /// What the shell sent on `id`, taken.
    pub fn take_sent(&self, id: StreamId) -> Vec<StreamMessage> {
        self.streams
            .borrow_mut()
            .iter_mut()
            .find(|s| s.id == id)
            .map(|s| std::mem::take(&mut s.sent))
            .unwrap_or_default()
    }

    /// The hub says `event` on `id`; an end closes it. False when it is
    /// closed.
    pub fn emit(&self, engine: &Engine, id: StreamId, event: StreamEvent) -> bool {
        let handler = {
            let mut streams = self.streams.borrow_mut();
            let Some(stream) = streams.iter_mut().find(|s| s.id == id && !s.closed) else {
                return false;
            };
            if matches!(event, StreamEvent::Ended(_)) {
                stream.closed = true;
            }
            stream.on_event.clone()
        };
        (handler.borrow_mut())(engine, event);
        true
    }

    /// Ends `id` with `end`.
    pub fn end(&self, engine: &Engine, id: StreamId, end: StreamEnd) -> bool {
        self.emit(engine, id, StreamEvent::Ended(end))
    }
}

impl Mc for DeviceMc {
    fn is_ready(&self) -> bool {
        true
    }

    fn environment(&self) -> String {
        "env-1".into()
    }

    fn call(&self, environment: &str, method: &str, payload: Json, reply: Reply) {
        self.calls
            .borrow_mut()
            .push((environment.into(), method.into(), payload, Some(reply)));
    }

    fn subscribe(&self, shape: Json, on_frame: OnFrame, _: Option<Resume>) -> SubId {
        let id = SubId(self.id());
        self.follows
            .borrow_mut()
            .push((id, shape, Rc::new(RefCell::new(on_frame))));
        id
    }

    fn unsubscribe(&self, id: SubId) {
        self.follows.borrow_mut().retain(|(s, _, _)| *s != id);
    }

    fn more(&self, _: SubId, _: u32) {}

    fn on_ready_changed(&self, _: OnReady) {}

    fn open_stream(
        &self,
        path: &str,
        query: &str,
        socket: bool,
        on_event: OnStream,
    ) -> Option<StreamId> {
        if self.no_origin.get() {
            return None;
        }
        let id = StreamId(self.id());
        self.streams.borrow_mut().push(Stream {
            id,
            path: path.into(),
            query: query.into(),
            socket,
            closed: false,
            sent: Vec::new(),
            on_event: Rc::new(RefCell::new(on_event)),
        });
        Some(id)
    }

    fn send_on_stream(&self, id: StreamId, message: StreamMessage) {
        let mut streams = self.streams.borrow_mut();
        if let Some(stream) = streams.iter_mut().find(|s| s.id == id && !s.closed) {
            stream.sent.push(message);
        }
    }

    fn close_stream(&self, id: StreamId) {
        if let Some(stream) = self.streams.borrow_mut().iter_mut().find(|s| s.id == id) {
            stream.closed = true;
        }
    }
}

/// What a scripted decoder makes of what it is given.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Makes {
    /// A picture of every unit (the size the device sends at).
    Pictures(u32, u32),
    /// Nothing yet.
    Nothing,
    /// The first keyframe after each reset is refused (the stream starts
    /// over at once, as on the real decoder's Broken).
    Broken,
}

/// What the test and a scripted decoder share.
#[derive(Debug)]
pub struct Script {
    pub makes: Makes,
    /// false: each push drops the backlog instead.
    pub keeps_up: bool,
    /// (bytes after the offset, keyframe) of every unit pushed.
    pub pushed: Vec<(Vec<u8>, bool)>,
    pub jpegs: usize,
    /// Every reset's avcC (None: Annex-B).
    pub resets: Vec<Option<Vec<u8>>>,
    pub maximum: (u32, u32),
    broken: bool,
    events: Vec<Decoded>,
    frame: Option<Picture>,
    source: (u32, u32),
}

impl Default for Script {
    fn default() -> Self {
        Script {
            makes: Makes::Pictures(72, 160),
            keeps_up: true,
            pushed: Vec::new(),
            jpegs: 0,
            resets: Vec::new(),
            maximum: (0, 0),
            broken: false,
            events: Vec::new(),
            frame: None,
            source: (0, 0),
        }
    }
}

pub struct Scripted(pub Rc<RefCell<Script>>);

impl Decode for Scripted {
    fn reset(&mut self, avcc: Option<Vec<u8>>) {
        let mut s = self.0.borrow_mut();
        s.resets.push(avcc);
        s.broken = false;
        s.events.clear();
        s.frame = None;
    }

    fn push(&mut self, unit: Vec<u8>, offset: usize, keyframe: bool) -> bool {
        let mut s = self.0.borrow_mut();
        s.pushed.push((unit[offset..].to_vec(), keyframe));
        if !s.keeps_up {
            return false;
        }
        match s.makes {
            Makes::Pictures(width, height) => {
                s.source = (width, height);
                s.frame = Some(Picture {
                    width,
                    height,
                    rgba: [255, 0, 0, 255].repeat((width * height) as usize),
                });
                if !s.events.contains(&Decoded::Frame) {
                    s.events.push(Decoded::Frame);
                }
            }
            Makes::Broken if keyframe && !s.broken => {
                s.broken = true;
                s.events.push(Decoded::Broken);
            }
            Makes::Broken | Makes::Nothing => {}
        }
        true
    }

    fn push_jpeg(&mut self, _: Vec<u8>) {
        self.0.borrow_mut().jpegs += 1;
    }

    fn set_maximum_size(&mut self, size: (u32, u32)) {
        self.0.borrow_mut().maximum = size;
    }

    fn take_events(&mut self) -> Vec<Decoded> {
        std::mem::take(&mut self.0.borrow_mut().events)
    }

    fn take_frame(&mut self) -> Option<Picture> {
        self.0.borrow_mut().frame.take()
    }

    fn source_size(&self) -> (u32, u32) {
        self.0.borrow().source
    }
}

/// The engine's device streams decode with `script` from now on.
pub fn script_decoders(engine: &Engine) -> Rc<RefCell<Script>> {
    let script = Rc::new(RefCell::new(Script::default()));
    let shared = script.clone();
    hal_c2_shell::device::set_decoders(engine, move |_| Box::new(Scripted(shared.clone())));
    script
}
