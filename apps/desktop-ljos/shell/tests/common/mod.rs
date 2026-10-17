//! A shell without a window: `HalC2.Shell` registered through the facade,
//! the controllers started, and a root of QML written in the test.

#![allow(dead_code)]

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Mc, OnFrame, OnReady, Reply, Resume, SubId};
use ljos::App;
use ljos::MapSource;
use ljos::dev::OnError;
use ljos::prelude::{Engine, ObjectId, Value};

/// `files` (key, text) compiled against the standard modules and
/// `HalC2.Shell`, with `qmldirs` (directory key, text) beside them. Panics
/// with the errors of a file that does not compile.
pub fn compile(files: &[(&str, &str)], qmldirs: &[(&str, &str)]) -> MapSource {
    let dir = tempfile::tempdir().expect("a directory for the QML");
    let put = |path: std::path::PathBuf, text: &str| {
        std::fs::create_dir_all(path.parent().expect("a file in the directory"))
            .and_then(|()| std::fs::write(&path, text))
            .unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    };
    for (key, text) in files {
        put(dir.path().join(format!("{key}.qml")), text);
    }
    for (key, text) in qmldirs {
        put(dir.path().join(key).join("qmldir"), text);
    }
    let snapshot = ljos::engine();
    hal_c2_shell::register(&snapshot);
    ljos::dev::compile(dir.path(), Some(&snapshot), OnError::Fail).unwrap_or_else(|e| panic!("{e}"))
}

/// The engine of an app with `source`, the shell started over `mc`.
pub fn engine(source: MapSource, mc: Rc<dyn Mc>) -> Engine {
    let engine = App::new("test")
        .register(hal_c2_shell::register)
        .source(source)
        .build_engine();
    hal_c2_shell::start(&engine, &Launch::default(), mc);
    engine
}

/// `main` as the root of a started shell.
pub fn shell(main: &str, mc: Rc<dyn Mc>) -> (Engine, ObjectId) {
    shell_with(&[("Main", main)], &[], mc)
}

pub fn shell_with(
    files: &[(&str, &str)],
    qmldirs: &[(&str, &str)],
    mc: Rc<dyn Mc>,
) -> (Engine, ObjectId) {
    let engine = engine(compile(files, qmldirs), mc);
    let root = engine
        .create_from_url("Main", None, Vec::new())
        .expect("Main is made");
    (engine, root)
}

pub fn read(engine: &Engine, obj: ObjectId, name: &str) -> Value {
    engine.read_by_name(obj, name)
}

pub fn text(engine: &Engine, obj: ObjectId, name: &str) -> String {
    engine.to_js_string(&read(engine, obj, name)).to_string()
}

pub fn number(engine: &Engine, obj: ObjectId, name: &str) -> f64 {
    read(engine, obj, name).to_number()
}

pub fn call(engine: &Engine, obj: ObjectId, name: &str, args: &[Value]) -> Value {
    engine
        .invoke_by_name(obj, name, args)
        .unwrap_or_else(|e| panic!("{name}: {e}"))
}

/// An MC that answers nothing on its own: the test says when it is ready,
/// and reads what was called.
#[derive(Default)]
pub struct FakeMc {
    pub ready: Cell<bool>,
    pub calls: RefCell<Vec<(String, String, Json)>>,
    on_ready: RefCell<Vec<OnReady>>,
    next: Cell<u64>,
    /// Each call's reply, by its index in `calls`, until answered.
    replies: RefCell<Vec<Option<Reply>>>,
    /// The subscriptions still followed: id, shape, handler.
    subs: RefCell<Vec<(SubId, Json, Option<OnFrame>)>>,
}

impl FakeMc {
    pub fn methods(&self) -> Vec<String> {
        self.calls
            .borrow()
            .iter()
            .map(|(_, m, _)| m.clone())
            .collect()
    }

    /// Answers call `index` (of `calls`); false when it was answered before.
    pub fn reply(
        &self,
        engine: &Engine,
        index: usize,
        result: Result<Json, hal_c2_shell::mc::McError>,
    ) -> bool {
        let reply = self
            .replies
            .borrow_mut()
            .get_mut(index)
            .and_then(Option::take);
        match reply {
            Some(reply) => {
                reply(engine, result);
                true
            }
            None => false,
        }
    }

    /// Whether call `index` (of `calls`) is still unanswered.
    pub fn is_pending(&self, index: usize) -> bool {
        self.replies
            .borrow()
            .get(index)
            .is_some_and(Option::is_some)
    }

    /// The index of the oldest call to `method` not answered yet.
    pub fn pending(&self, method: &str) -> Option<usize> {
        let calls = self.calls.borrow();
        let replies = self.replies.borrow();
        (0..calls.len()).find(|&i| calls[i].1 == method && replies[i].is_some())
    }

    /// The index of the oldest call to `method` on `environment` not
    /// answered yet.
    pub fn pending_on(&self, environment: &str, method: &str) -> Option<usize> {
        let calls = self.calls.borrow();
        let replies = self.replies.borrow();
        (0..calls.len())
            .find(|&i| calls[i].0 == environment && calls[i].1 == method && replies[i].is_some())
    }

    /// Answers the oldest unanswered call to `method`; panics without one.
    pub fn answer(
        &self,
        engine: &Engine,
        method: &str,
        result: Result<Json, hal_c2_shell::mc::McError>,
    ) {
        let index = self
            .pending(method)
            .unwrap_or_else(|| panic!("no unanswered {method}"));
        self.reply(engine, index, result);
    }

    /// Answers the oldest unanswered call to `method` on `environment`.
    pub fn answer_on(
        &self,
        engine: &Engine,
        environment: &str,
        method: &str,
        result: Result<Json, hal_c2_shell::mc::McError>,
    ) {
        let index = self
            .pending_on(environment, method)
            .unwrap_or_else(|| panic!("no unanswered {method} on {environment}"));
        self.reply(engine, index, result);
    }

    /// The shapes followed now, with their ids.
    pub fn subscriptions(&self) -> Vec<(SubId, Json)> {
        self.subs
            .borrow()
            .iter()
            .map(|(id, shape, _)| (*id, shape.clone()))
            .collect()
    }

    /// Sends `frame` (an object with `t`) to every subscription whose shape
    /// is `{type: kind}` for `environment` (any, when empty).
    pub fn frame(&self, engine: &Engine, kind: &str, environment: &str, frame: Json) {
        let Json::Object(frame) = frame else {
            panic!("a frame is an object")
        };
        let ids: Vec<SubId> = self
            .subscriptions()
            .into_iter()
            .filter(|(_, shape)| {
                shape.get("type").and_then(Json::as_str) == Some(kind)
                    && (environment.is_empty()
                        || shape.get("environment").and_then(Json::as_str) == Some(environment))
            })
            .map(|(id, _)| id)
            .collect();
        for id in ids {
            let handler = self
                .subs
                .borrow_mut()
                .iter_mut()
                .find(|(i, _, _)| *i == id)
                .and_then(|(_, _, h)| h.take());
            let Some(mut handler) = handler else { continue };
            handler(engine, &frame);
            // Back, unless the frame unsubscribed it.
            if let Some(slot) = self.subs.borrow_mut().iter_mut().find(|(i, _, _)| *i == id) {
                slot.2 = Some(handler);
            }
        }
    }

    /// The MC says hello (or drops), as a delivery would tell it.
    pub fn set_ready(&self, engine: &Engine, ready: bool) {
        self.ready.set(ready);
        let mut fs = std::mem::take(&mut *self.on_ready.borrow_mut());
        for f in &mut fs {
            f(engine, ready);
        }
        self.on_ready.borrow_mut().extend(fs);
    }
}

impl Mc for FakeMc {
    fn is_ready(&self) -> bool {
        self.ready.get()
    }

    fn environment(&self) -> String {
        "env-1".into()
    }

    fn call(&self, environment: &str, method: &str, payload: Json, reply: Reply) {
        self.calls
            .borrow_mut()
            .push((environment.into(), method.into(), payload));
        self.replies.borrow_mut().push(Some(reply));
    }

    fn subscribe(&self, shape: Json, on_frame: OnFrame, _: Option<Resume>) -> SubId {
        self.next.set(self.next.get() + 1);
        let id = SubId(self.next.get());
        self.subs.borrow_mut().push((id, shape, Some(on_frame)));
        id
    }

    fn unsubscribe(&self, id: SubId) {
        self.subs.borrow_mut().retain(|(i, _, _)| *i != id);
    }

    fn more(&self, _: SubId, _: u32) {}

    fn on_ready_changed(&self, f: OnReady) {
        self.on_ready.borrow_mut().push(f);
    }
}

/// A JS value, as QML would pass one (`({"a": 1})`).
pub fn js_value(engine: &Engine, js: &str) -> Value {
    engine.eval_js(js).unwrap_or_else(|e| panic!("{js}: {e}"))
}

/// A scene over `root`, for what a test wants to see painted or send input
/// to. Frames run on the engine's own clock, which only moves when told.
pub struct Scene {
    pub scene: ljos_quick::QuickScene,
}

impl Scene {
    pub fn new(engine: &Engine, root: ObjectId, size: (f64, f64)) -> Self {
        // The bundled font: the same cells on every machine.
        ljos_quick::set_text_engine(ljos_quick::TextEngine::new());
        let mut scene = ljos_quick::QuickScene::new(ljos_render::kurbo::Size::new(size.0, size.1));
        scene.set_root(engine, root).expect("a root");
        let mut s = Scene { scene };
        s.settle(engine);
        s
    }

    /// Frames until the scene has nothing left to do.
    pub fn settle(&mut self, engine: &Engine) {
        for _ in 0..64 {
            let now = engine.now();
            let out = self.scene.frame(engine, now);
            if !self.scene.needs_frame() && out.next_wake.is_none_or(|t| t > now) {
                return;
            }
        }
        panic!("the scene did not settle");
    }

    /// What `item` last painted, back to front.
    pub fn ops(&mut self, engine: &Engine, item: ObjectId) -> Vec<ljos_render::DrawOp> {
        self.settle(engine);
        let node = self.scene.node_of(item).expect("a node for the item");
        let snapshot = self.scene.snapshot().expect("a frame").clone();
        snapshot
            .items
            .iter()
            .filter(|p| p.node == node)
            .filter_map(|p| p.list.as_ref())
            .flat_map(|l| l.ops().to_vec())
            .collect()
    }
}
