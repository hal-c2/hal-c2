//! A shell without a window: `HalC2.Shell` registered through the facade,
//! the controllers started, and a root of QML written in the test.

#![allow(dead_code)]

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Frame, Mc, OnFrame, OnReady, Reply, Resume, SubId};
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
    /// What each subscription that has one says it resumes from.
    resumes: RefCell<Vec<(SubId, Option<Resume>)>>,
    /// Every `more`: the subscription and how many turns it asked for.
    pub mores: RefCell<Vec<(SubId, u32)>>,
    /// Every origin and token it was opened at, as a pairing does.
    pub opened: RefCell<Vec<(String, String)>>,
}

impl FakeMc {
    pub fn methods(&self) -> Vec<String> {
        self.calls
            .borrow()
            .iter()
            .map(|(_, m, _)| m.clone())
            .collect()
    }

    /// What subscription `id` says it resumes from, as a `sub` frame would
    /// carry it; none without a resume (or once unsubscribed).
    pub fn resume(&self, id: SubId) -> Option<Frame> {
        let mut resume = self
            .resumes
            .borrow_mut()
            .iter_mut()
            .find(|(i, _)| *i == id)
            .and_then(|(_, r)| r.take())?;
        let frame = resume();
        if let Some(slot) = self.resumes.borrow_mut().iter_mut().find(|(i, _)| *i == id) {
            slot.1 = Some(resume);
        }
        Some(frame)
    }

    /// Sends `frame` (an object with `t`) to subscription `id` alone.
    pub fn frame_to(&self, engine: &Engine, id: SubId, frame: Json) {
        let Json::Object(frame) = frame else {
            panic!("a frame is an object")
        };
        self.deliver(engine, id, &frame);
    }

    fn deliver(&self, engine: &Engine, id: SubId, frame: &Frame) {
        let handler = self
            .subs
            .borrow_mut()
            .iter_mut()
            .find(|(i, _, _)| *i == id)
            .and_then(|(_, _, h)| h.take());
        let Some(mut handler) = handler else { return };
        handler(engine, frame);
        // Back, unless the frame unsubscribed it.
        if let Some(slot) = self.subs.borrow_mut().iter_mut().find(|(i, _, _)| *i == id) {
            slot.2 = Some(handler);
        }
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
        self.pending_where(method, |_| true)
    }

    /// The index of the oldest call to `method` whose payload `matches`, not
    /// answered yet.
    pub fn pending_where(&self, method: &str, matches: impl Fn(&Json) -> bool) -> Option<usize> {
        let calls = self.calls.borrow();
        let replies = self.replies.borrow();
        (0..calls.len())
            .find(|&i| calls[i].1 == method && replies[i].is_some() && matches(&calls[i].2))
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
        self.frame_where(
            engine,
            |shape| {
                shape.get("type").and_then(Json::as_str) == Some(kind)
                    && (environment.is_empty()
                        || shape.get("environment").and_then(Json::as_str) == Some(environment))
            },
            frame,
        );
    }

    /// Sends `frame` to every subscription whose shape `matches`.
    pub fn frame_where(&self, engine: &Engine, matches: impl Fn(&Json) -> bool, frame: Json) {
        let ids: Vec<SubId> = self
            .subscriptions()
            .into_iter()
            .filter(|(_, shape)| matches(shape))
            .map(|(id, _)| id)
            .collect();
        for id in ids {
            self.frame_to(engine, id, frame.clone());
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

    fn subscribe(&self, shape: Json, on_frame: OnFrame, resume: Option<Resume>) -> SubId {
        self.next.set(self.next.get() + 1);
        let id = SubId(self.next.get());
        self.subs.borrow_mut().push((id, shape, Some(on_frame)));
        if resume.is_some() {
            self.resumes.borrow_mut().push((id, resume));
        }
        id
    }

    fn unsubscribe(&self, id: SubId) {
        self.subs.borrow_mut().retain(|(i, _, _)| *i != id);
        self.resumes.borrow_mut().retain(|(i, _)| *i != id);
    }

    fn more(&self, id: SubId, items: u32) {
        self.mores.borrow_mut().push((id, items));
    }

    fn on_ready_changed(&self, f: OnReady) {
        self.on_ready.borrow_mut().push(f);
    }

    fn open(&self, origin: &str, token: &str) -> Result<(), String> {
        self.opened.borrow_mut().push((origin.into(), token.into()));
        Ok(())
    }
}

/// A JS value, as QML would pass one (`({"a": 1})`).
pub fn js_value(engine: &Engine, js: &str) -> Value {
    engine.eval_js(js).unwrap_or_else(|e| panic!("{js}: {e}"))
}

/// A window showing `root`, for what a test wants to see painted or send
/// input to. It runs on a virtual clock, which only moves when told.
pub struct Scene {
    pub window: ljos::testing::TestWindow,
}

impl Scene {
    pub fn new(engine: &Engine, root: ObjectId, size: (f64, f64)) -> Self {
        // The bundled font: the same cells on every machine.
        ljos::testing::set_text_engine(ljos::item::TextEngine::new());
        let mut window = ljos::testing::TestWindow::new(engine, size.0, size.1);
        window.show(root).expect("the root is shown");
        Scene { window }
    }

    /// Frames until the scene has nothing left to do.
    pub fn settle(&mut self) {
        self.window.settle().expect("the scene settles");
    }

    /// What `item` last painted, back to front.
    pub fn ops(&mut self, item: ObjectId) -> Vec<ljos::item::DrawOp> {
        self.settle();
        self.window
            .painted(item)
            .map(|list| list.ops().to_vec())
            .unwrap_or_default()
    }
}
