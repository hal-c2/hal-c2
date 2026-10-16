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
use ljos::dev::EngineOracle;
use ljos::prelude::{Engine, ObjectId, Value};
use ljos_compiler::{Project, compile_file};

/// `files` (key, text) compiled against the standard modules and
/// `HalC2.Shell`; `qmldirs` (directory key, text) after them. Panics with
/// the diagnostics of a file that does not compile.
pub fn compile(files: &[(&str, &str)], qmldirs: &[(&str, &str)]) -> MapSource {
    let snapshot = ljos::engine();
    hal_c2_shell::register(&snapshot);
    let mut project = Project::new(EngineOracle::from_engine(&snapshot));
    for (key, text) in files {
        project.add(key, *text);
    }
    for (dir, text) in qmldirs {
        project.add_qmldir(dir, text);
    }
    let mut source = MapSource::new();
    for (key, _) in files {
        match compile_file(&project, key) {
            Ok(c) if !c.has_errors() => source.insert(*key, c.file),
            Ok(c) => panic!("{key}: {:?}", c.diagnostics),
            Err(ds) => panic!("{key}: {ds:?}"),
        }
    }
    source
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
