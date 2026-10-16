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
}

impl FakeMc {
    pub fn methods(&self) -> Vec<String> {
        self.calls
            .borrow()
            .iter()
            .map(|(_, m, _)| m.clone())
            .collect()
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

    fn call(&self, environment: &str, method: &str, payload: Json, _reply: Reply) {
        self.calls
            .borrow_mut()
            .push((environment.into(), method.into(), payload));
    }

    fn subscribe(&self, _: Json, _: OnFrame, _: Option<Resume>) -> SubId {
        self.next.set(self.next.get() + 1);
        SubId(self.next.get())
    }

    fn unsubscribe(&self, _: SubId) {}

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
