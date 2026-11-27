//! A large thread list under `shell.rows` news, through the phone's own
//! QML (#1703): it must not run the script heap out of memory.
//!
//! The size is what separates the sweeps: with 90 threads the phone keeps
//! within the heap's cap on either, so desktop-ljos's bound would prove
//! little here. At 1,000 threads the replaced generations pile up for
//! dozens of frames before a sweep, so every few frames the heap is held
//! under a fixed 72 MiB. The bound is not a share of the engine's cap: the
//! cap grows with the machine's memory (to 512 MiB), and a bound that grew
//! with it would let replaced generations pile up unseen on a large one.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use hal_c2_mobile::pairing::{self, Environment};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Mc, OnFrame, OnReady, Reply, Resume, SubId};
use hal_c2_shell::{Launch, store};
use ljos::App;
use ljos::prelude::{Engine, ObjectId};
use ljos::testing::TestWindow;
use serde_json::json;

const THREADS: usize = 1000;
const FRAMES: usize = 60;
/// What the script heap may hold after a collection: below the 76 MB the
/// replaced generations reached by frame 40 on a rev without the bounded sweep.
const HELD: usize = 72 * 1024 * 1024;

/// An MC that answers nothing and sends the frames it is given. The
/// desktop's own fake compiles QML, which the phone's tests don't build.
#[derive(Default)]
struct FakeMc {
    ready: Cell<bool>,
    next: Cell<u64>,
    on_ready: RefCell<Vec<OnReady>>,
    subs: RefCell<Vec<(SubId, Json, Option<OnFrame>)>>,
    /// Kept, as a reply dropped could read as a call failed.
    unanswered: RefCell<Vec<Reply>>,
}

impl FakeMc {
    fn hello(&self, engine: &Engine) {
        self.ready.set(true);
        let mut told = self.on_ready.take();
        for f in &mut told {
            f(engine, true);
        }
        self.on_ready.borrow_mut().extend(told);
    }

    /// Sends `frame` to the shell's subscriptions.
    fn send(&self, engine: &Engine, frame: Json) {
        let frame = frame.as_object().expect("a frame is an object").clone();
        let shells: Vec<SubId> = self
            .subs
            .borrow()
            .iter()
            .filter(|(_, shape, _)| shape["type"] == "shell")
            .map(|(id, _, _)| *id)
            .collect();
        assert!(!shells.is_empty(), "nothing follows the shell");
        for id in shells {
            let handler = self
                .subs
                .borrow_mut()
                .iter_mut()
                .find(|sub| sub.0 == id)
                .and_then(|sub| sub.2.take());
            let Some(mut handler) = handler else { continue };
            handler(engine, &frame);
            if let Some(sub) = self.subs.borrow_mut().iter_mut().find(|sub| sub.0 == id) {
                sub.2 = Some(handler);
            }
        }
    }
}

impl Mc for FakeMc {
    fn is_ready(&self) -> bool {
        self.ready.get()
    }

    fn environment(&self) -> String {
        "env-1".into()
    }

    fn call(&self, _environment: &str, _method: &str, _payload: Json, reply: Reply) {
        self.unanswered.borrow_mut().push(reply);
    }

    fn subscribe(&self, shape: Json, on_frame: OnFrame, _resume: Option<Resume>) -> SubId {
        self.next.set(self.next.get() + 1);
        let id = SubId(self.next.get());
        self.subs.borrow_mut().push((id, shape, Some(on_frame)));
        id
    }

    fn unsubscribe(&self, id: SubId) {
        self.subs.borrow_mut().retain(|sub| sub.0 != id);
    }

    fn more(&self, _id: SubId, _items: u32) {}

    fn on_ready_changed(&self, f: OnReady) {
        self.on_ready.borrow_mut().push(f);
    }

    fn open(&self, _origin: &str, _token: &str) -> Result<(), String> {
        Ok(())
    }
}

fn at(seconds: usize) -> String {
    let (h, m, s) = (9 + seconds / 3600, seconds / 60 % 60, seconds % 60);
    format!("2026-11-20T{h:02}:{m:02}:{s:02}.000Z")
}

fn thread(t: usize, tick: usize) -> serde_json::Value {
    json!({
        "id": format!("t{t}"),
        "projectId": format!("p{}", t % 6),
        "title": format!("Thread {t}"),
        "branch": format!("feature/work-{t}"),
        "createdAt": at(t),
        "updatedAt": at(t + tick * 7),
        "latestUserMessageAt": at(t + tick * 7),
        "runtimeMode": "full-access",
        "interactionMode": "default",
        "latestRunId": format!("run-{t}-{}", tick / 4),
        "status": if (t + tick).is_multiple_of(9) { "running" } else { "idle" },
    })
}

fn snapshot() -> serde_json::Value {
    let mut rows: Vec<serde_json::Value> = (0..6)
        .map(|p| {
            json!(["mc-a", format!("p{p}"), "project",
                {"id": format!("p{p}"), "title": format!("Project {p}"),
                 "workspaceRoot": format!("/work/project-{p}"),
                 "createdAt": at(0), "updatedAt": at(0)}])
        })
        .collect();
    rows.extend((0..THREADS).map(|t| json!(["mc-a", format!("t{t}"), "thread", thread(t, 0)])));
    json!({
        "t": "shell",
        "mcs": [{"mc": "mc-a", "environment": {"environmentId": "env-1", "capabilities": {}},
                 "online": true, "epoch": "e1", "rev": 1}],
        "rows": rows,
    })
}

/// The script heap after a collection: what is actually held, in bytes.
fn heap(engine: &Engine) -> usize {
    engine.collect_garbage();
    engine.script_memory().expect("the phone ran scripts").bytes
}

fn shows(engine: &Engine, item: ObjectId, name: &str) -> bool {
    engine.to_js_string(&engine.read_by_name(item, "objectName")) == name
        || engine
            .children(item)
            .into_iter()
            .any(|child| shows(engine, child, name))
}

#[test]
fn rows_news_does_not_exhaust_a_large_lists_script_heap() {
    let home = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).expect("a home for the phone");
    let dir = |name: &str| Some(home.path().join(name));
    // Paired, so the phone shows its list and not the pairing screen.
    assert!(pairing::save(
        &home.path().join("data/pairing.json"),
        &Environment {
            origin: "http://127.0.0.1:1".into(),
            token: "session".into(),
            label: "My MacBook".into(),
            environment_id: "env-1".into(),
            expires_at: String::new(),
        },
    ));

    ljos::render::set_fonts(ljos::render::Fonts::Bundled);
    let engine = App::new("phone-sidebar-heap")
        .register(hal_c2_mobile::register)
        .source(hal_c2_mobile::pack())
        .root("Main")
        .build_engine();
    // Before the shell starts, for its timers to start on the window's clock.
    let mut window = TestWindow::new(&engine, 412.0, 915.0);
    // And the wall clock with it, just after the threads' last news: the
    // sidebar times a working thread's grace and its labels' turns by the
    // wall clock, so on the machine's it rebuilt as often as the run was
    // slow, and the heap held at a frame varied from run to run.
    engine.set_wall_clock_origin(Some(1_795_167_000_000.0)); // 2026-11-20T09:30:00Z
    let mc = Rc::new(FakeMc::default());
    let launch = Launch {
        config_dir: dir("config"),
        cache_dir: dir("cache"),
        data_dir: dir("data"),
        state_dir: dir("state"),
        ..Launch::default()
    };
    hal_c2_mobile::install(&engine, launch.data_dir.clone(), launch.config_dir.clone());
    hal_c2_shell::start_with(&engine, &launch, mc.clone(), hal_c2_mobile::registrations());
    hal_c2_mobile::start(&engine);
    let root = hal_c2_shell::runtime::open(&engine).expect("the phone's shell is made");
    window.show(root).expect("a root");

    mc.hello(&engine);
    mc.send(&engine, snapshot());
    window.advance(1000).expect("at rest");
    // Without the rows on screen the frames would cost no script heap.
    assert!(
        shows(&engine, root, "rowBackground"),
        "no thread row is shown"
    );
    assert_eq!(engine.faults_reported(), 0, "faults before any news");

    for tick in 1..=FRAMES {
        let rows: Vec<serde_json::Value> = (0..6)
            .map(|i| (tick * 6 + i * 13) % THREADS)
            .map(|t| json!([format!("t{t}"), "thread", thread(t, tick)]))
            .collect();
        mc.send(
            &engine,
            json!({"t": "shell.rows", "mc": "mc-a", "epoch": "e1", "rev": tick + 1, "rows": rows}),
        );
        window.advance(250).expect("at rest");
        // The news landed: otherwise the heap would have nothing to hold.
        let moved = tick * 6 % THREADS;
        let shown = store::get(&engine)
            .expect("the phone keeps a store")
            .borrow()
            .thread(&format!("env-1:t{moved}"))
            .map(|thread| thread.updated_at);
        assert_eq!(
            shown,
            Some(at(moved + tick * 7)),
            "rows frame {tick} didn't reach the phone's threads"
        );
        assert_eq!(
            engine.faults_reported(),
            0,
            "the script heap gave out, or something else faulted, after {tick} rows frames"
        );
        if tick % 5 == 0 {
            let held = heap(&engine);
            assert!(
                held < HELD,
                "script heap reached {held} bytes after {tick} rows frames: \
                 replaced generations pile up between sweeps"
            );
        }
    }
}
