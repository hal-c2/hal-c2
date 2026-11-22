//! The script heap under a steady stream of `shell.rows` frames, through
//! the whole shell (#1703): news that only moves threads along must not
//! keep a generation of script objects per frame.
//!
//! Each publish of a state tree mints a fresh record on the script side.
//! Those replaced generations are let go only when Ljós sweeps its
//! record table, so this drives far more frames than one sweep cycle
//! and holds every sample to the bound a cycle may reach — an endpoint
//! check alone could land in a trough and miss a pile-up.

mod common;

use std::cell::RefCell;
use std::rc::Rc;

use common::FakeMc;
use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::qml::Roots;
use ljos::App;
use ljos::prelude::{Engine, ObjectId};
use ljos::testing::TestWindow;
use serde_json::json;

struct Shell {
    engine: Engine,
    window: Rc<RefCell<TestWindow>>,
    mc: Rc<FakeMc>,
}

fn start() -> Shell {
    ljos::render::set_fonts(ljos::render::Fonts::Bundled);
    let engine = App::new("test")
        .register(hal_c2_shell::register)
        .build_engine();
    // Before the shell starts, for its timers to start on the window's clock.
    let window = Rc::new(RefCell::new(TestWindow::new(&engine, 1200.0, 900.0)));
    ljos_controls::WindowSystem::of(&engine).set_host(|| {});
    let mc = Rc::new(FakeMc::default());
    hal_c2_shell::start(
        &engine,
        &Launch {
            mc_origin: Some("http://127.0.0.1:1".into()),
            ..Launch::default()
        },
        mc.clone(),
    );
    Shell { engine, window, mc }
}

/// The whole shell the app shows (`Main` is its ShellLoader), compiled
/// from the checkout as a `dev-qml` run compiles it.
fn show(shell: &Shell) -> ObjectId {
    let compiled = common::compile_roots(&Roots::checkout());
    let root = Bridge::main(&shell.engine)
        .in_scope(&shell.engine, || {
            ljos::create_root(&shell.engine, compiled.source, "Main")
        })
        .expect("the shell is made");
    shell.window.borrow_mut().show(root).expect("a root");
    root
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
    rows.extend((0..90).map(|t| json!(["mc-a", format!("t{t}"), "thread", thread(t, 0)])));
    json!({
        "t": "shell",
        "mcs": [{"mc": "mc-a", "environment": {"environmentId": "env-1", "capabilities": {}},
                 "online": true, "epoch": "e1", "rev": 1}],
        "rows": rows,
    })
}

/// The script heap after a collection: what is actually held, in bytes.
fn heap(shell: &Shell) -> usize {
    shell.engine.collect_garbage();
    shell
        .engine
        .script_memory()
        .expect("the shell ran scripts")
        .bytes
}

#[test]
fn rows_news_does_not_grow_the_script_heap() {
    let shell = start();
    let _root = show(&shell);
    shell.mc.set_ready(&shell.engine, true);
    shell.mc.frame(&shell.engine, "shell", "", snapshot());
    shell.window.borrow_mut().advance(1000).expect("at rest");

    // Two minutes of news at the audit's cadence, moving the same six
    // threads along each frame. Fixed frames sampled every twenty ticks
    // can sit in a sweep trough while peaks pile up between them;
    // tracking the peak over every frame would collect on each one and
    // drive the sweep this means to observe, so the samples are the
    // frames and the bound leaves room for one cycle's climb.
    let start = heap(&shell);
    let mut peak = start;
    for tick in 1..=480usize {
        let rows: Vec<serde_json::Value> = (0..6)
            .map(|i| (tick * 6 + i * 13) % 90)
            .map(|t| json!([format!("t{t}"), "thread", thread(t, tick)]))
            .collect();
        shell.mc.frame(
            &shell.engine,
            "shell",
            "",
            json!({"t": "shell.rows", "mc": "mc-a", "epoch": "e1", "rev": tick + 1, "rows": rows}),
        );
        shell.window.borrow_mut().advance(250).expect("at rest");
        if tick % 20 == 0 {
            peak = peak.max(heap(&shell));
        }
    }
    assert!(
        peak < start + 6 * 1024 * 1024,
        "script heap peaked at {peak} bytes from a start of {start} over 480 rows frames: \
         replaced generations pile up between sweeps"
    );
}
