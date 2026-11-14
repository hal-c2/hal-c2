//! An MC the test scripts: answers calls as the test says, and sends frames
//! to the subscriptions it names. Included by the test files that need one
//! (`#[path = "support/scripted_mc.rs"] mod scripted_mc;`).

#![allow(dead_code)]

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Frame, Mc, McError, OnFrame, OnReady, Reply, Resume, SubId};
use ljos::prelude::Engine;

type Script = Box<dyn FnMut(&str, &str, &Json) -> Result<Json, McError>>;

struct Subscription {
    id: SubId,
    shape: Json,
    on_frame: Rc<RefCell<OnFrame>>,
}

/// Replies wait for [`ScriptedMc::deliver`], as the real MC answers on a
/// delivery and never inside the call.
pub struct ScriptedMc {
    pub ready: Cell<bool>,
    pub environment: RefCell<String>,
    pub calls: RefCell<Vec<(String, String, Json)>>,
    script: RefCell<Script>,
    waiting: RefCell<Vec<(Reply, Result<Json, McError>)>>,
    subscriptions: RefCell<Vec<Subscription>>,
    on_ready: RefCell<Vec<OnReady>>,
    next: Cell<u64>,
}

impl ScriptedMc {
    /// `script` gets (environment, method, payload) of each call.
    pub fn new(
        script: impl FnMut(&str, &str, &Json) -> Result<Json, McError> + 'static,
    ) -> Rc<ScriptedMc> {
        Rc::new(ScriptedMc {
            ready: Cell::new(true),
            environment: RefCell::new("env-1".into()),
            calls: RefCell::default(),
            script: RefCell::new(Box::new(script)),
            waiting: RefCell::default(),
            subscriptions: RefCell::default(),
            on_ready: RefCell::default(),
            next: Cell::new(0),
        })
    }

    pub fn answers(
        &self,
        script: impl FnMut(&str, &str, &Json) -> Result<Json, McError> + 'static,
    ) {
        *self.script.borrow_mut() = Box::new(script);
    }

    /// Answers every call made so far, in order, and those they make.
    pub fn deliver(&self, engine: &Engine) {
        loop {
            let waiting = std::mem::take(&mut *self.waiting.borrow_mut());
            if waiting.is_empty() {
                return;
            }
            for (reply, result) in waiting {
                reply(engine, result);
            }
        }
    }

    /// Sends `frame` to the subscriptions whose shape has `shape`'s keys.
    pub fn send(&self, engine: &Engine, shape: &Json, frame: Json) {
        let Json::Object(frame) = frame else {
            panic!("a frame is an object")
        };
        let handlers: Vec<_> = self
            .subscriptions
            .borrow()
            .iter()
            .filter(|s| s.shape == *shape)
            .map(|s| s.on_frame.clone())
            .collect();
        for handler in handlers {
            (handler.borrow_mut())(engine, &frame);
        }
    }

    pub fn subscribed(&self) -> Vec<Json> {
        self.subscriptions
            .borrow()
            .iter()
            .map(|s| s.shape.clone())
            .collect()
    }

    pub fn methods(&self) -> Vec<String> {
        self.calls
            .borrow()
            .iter()
            .map(|(_, m, _)| m.clone())
            .collect()
    }

    pub fn payloads(&self, method: &str) -> Vec<Json> {
        self.calls
            .borrow()
            .iter()
            .filter(|(_, m, _)| m == method)
            .map(|(_, _, p)| p.clone())
            .collect()
    }

    pub fn set_ready(&self, engine: &Engine, ready: bool) {
        self.ready.set(ready);
        let mut fs = std::mem::take(&mut *self.on_ready.borrow_mut());
        for f in &mut fs {
            f(engine, ready);
        }
        self.on_ready.borrow_mut().extend(fs);
    }
}

impl Mc for ScriptedMc {
    fn is_ready(&self) -> bool {
        self.ready.get()
    }

    fn environment(&self) -> String {
        self.environment.borrow().clone()
    }

    fn call(&self, environment: &str, method: &str, payload: Json, reply: Reply) {
        let result = (self.script.borrow_mut())(environment, method, &payload);
        self.calls
            .borrow_mut()
            .push((environment.into(), method.into(), payload));
        self.waiting.borrow_mut().push((reply, result));
    }

    fn subscribe(&self, shape: Json, on_frame: OnFrame, _: Option<Resume>) -> SubId {
        self.next.set(self.next.get() + 1);
        let id = SubId(self.next.get());
        self.subscriptions.borrow_mut().push(Subscription {
            id,
            shape,
            on_frame: Rc::new(RefCell::new(on_frame)),
        });
        id
    }

    fn unsubscribe(&self, id: SubId) {
        self.subscriptions.borrow_mut().retain(|s| s.id != id);
    }

    fn more(&self, _: SubId, _: u32) {}

    fn on_ready_changed(&self, f: OnReady) {
        self.on_ready.borrow_mut().push(f);
    }
}

/// `Err` as the MC refuses a stale write.
pub fn stale() -> McError {
    McError {
        message: "The settings changed.".into(),
        detail: serde_json::json!({ "_tag": "StaleSettings" }),
    }
}

pub fn frame(json: Json) -> Frame {
    match json {
        Json::Object(map) => map,
        _ => panic!("a frame is an object"),
    }
}
