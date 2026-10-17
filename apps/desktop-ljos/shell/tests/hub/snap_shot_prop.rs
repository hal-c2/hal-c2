//! The capture flow as a state machine: capture turned on and off, the
//! shortcut recorded, the shortcut pressed, and the desktop answering each
//! capture in its own time with a picture or a failure. A press starts a
//! capture only while capture is on and no shortcut is being recorded; every
//! picture lands in the thread the window shows; the shortcut is bound
//! exactly while capture is on.

use proptest::prelude::*;
use serde_json::json;

use hal_c2_shell::snap_shot::Event;

use crate::Hub;
use crate::composer::{launch_in, on_threads_with, open};
use crate::page::toasts;
use crate::snap_shot::{Desktop, arrive, chips, chord, install, portal, set, window};

use std::cell::RefCell;
use std::rc::Rc;

#[derive(Clone, Copy, Debug)]
enum Op {
    Enable(bool),
    RecordStart,
    RecordCancel,
    /// The shortcut is pressed.
    Press,
    /// The desktop answers the oldest capture with a picture.
    Picture,
    /// The desktop answers the oldest capture with a failure.
    Fail,
    Open(usize),
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        2 => any::<bool>().prop_map(Op::Enable),
        2 => Just(Op::RecordStart),
        2 => Just(Op::RecordCancel),
        5 => Just(Op::Press),
        4 => Just(Op::Picture),
        2 => Just(Op::Fail),
        2 => (0usize..2).prop_map(Op::Open),
    ]
}

const THREADS: [&str; 2] = ["t1", "t2"];

#[derive(Default)]
struct Model {
    enabled: bool,
    recording: bool,
    open: usize,
    /// The captures asked for and not answered, each for the thread shown
    /// when it is answered.
    asked: u32,
    started: u32,
    attached: [usize; 2],
    failures: u32,
}

struct World {
    hub: Hub,
    desktop: Rc<RefCell<Desktop>>,
    model: Model,
}

impl World {
    fn new() -> World {
        let hub = on_threads_with(launch_in("snap-shot-prop"), &THREADS);
        hub.engine.set_wall_clock_origin(Some(1_790_000_000_000.0));
        let desktop = Rc::new(RefCell::new(Desktop {
            session: portal("hyprland"),
            ..Desktop::default()
        }));
        install(&hub, &desktop);
        set(&hub, "snapShotShortcut", chord());
        set(&hub, "snapShotPlaySound", json!(false));
        World {
            hub,
            desktop,
            model: Model::default(),
        }
    }

    fn step(&mut self, op: Op) {
        let (hub, desktop, model) = (&self.hub, &self.desktop, &mut self.model);
        match op {
            Op::Enable(on) => {
                hub.dispatch("snapShot.enable", json!({"on": on}));
                if on {
                    // Opening setup is the opt-in, and the wizard then holds
                    // capture on until it is closed unfinished.
                    model.enabled = true;
                    model.recording = false;
                    hub.dispatch("snapShot.setup.close", json!({"completed": true}));
                } else {
                    model.enabled = false;
                    model.recording = false;
                }
            }
            Op::RecordStart => {
                hub.dispatch("snapShot.record.start", json!({}));
                model.recording = true;
            }
            Op::RecordCancel => {
                hub.dispatch("snapShot.record.cancel", json!({}));
                model.recording = false;
            }
            Op::Press => {
                arrive(hub, desktop, vec![Event::Activated]);
                if model.enabled && !model.recording {
                    model.asked += 1;
                    model.started += 1;
                }
            }
            Op::Picture | Op::Fail => {
                if model.asked == 0 {
                    return;
                }
                model.asked -= 1;
                if matches!(op, Op::Picture) {
                    arrive(hub, desktop, vec![window("App", "Title")]);
                    model.attached[model.open] += 1;
                } else {
                    arrive(hub, desktop, vec![Event::Failed("no".into())]);
                    model.failures += 1;
                }
            }
            Op::Open(thread) => {
                open(hub, THREADS[thread]);
                model.open = thread;
            }
        }
    }

    fn check(&self) {
        let (hub, desktop, model) = (&self.hub, &self.desktop, &self.model);
        let page = hub.published("snapShot");
        assert_eq!(page["enabled"], model.enabled);
        assert_eq!(page["shortcut"]["recording"], model.recording);
        // Bound exactly while capture is on.
        assert_eq!(desktop.borrow().bound.is_some(), model.enabled);
        // Every press that started a capture reached the backend, no other.
        let captures = desktop
            .borrow()
            .calls
            .iter()
            .filter(|c| *c == "capture")
            .count();
        assert_eq!(captures as u32, model.started);
        assert_eq!(chips(hub).len(), model.attached[model.open]);
        // A failure is a toast; they are shown up to the stack's limit.
        let failed = toasts(hub)
            .iter()
            .filter(|(title, _)| title == "Snapshot failed")
            .count();
        assert_eq!(failed > 0, model.failures > 0);
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 96, ..ProptestConfig::default() })]

    #[test]
    fn captures_follow_their_model(ops in proptest::collection::vec(op(), 1..40)) {
        let mut world = World::new();
        for op in ops {
            world.step(op);
            world.check();
        }
    }
}
