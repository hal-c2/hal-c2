//! The window set as a state machine: windows opened by id or by
//! `window.new`, closed in any order (the first among them), acted in, the
//! clock moving and the MC answering calls made from windows since closed.
//! Each window keeps its own route and layout, what is shared shows the same
//! everywhere, the open set is what is saved, a closed window's timers and
//! subscriptions go with it, and closing the last one quits instead. A
//! restart reopens the saved set in its order, the first saved as the
//! first window, each where its route was. A restored window no root could
//! be made for is set aside: closed, but still saved with its route, to come
//! back as it was.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller::{self, MAIN, NEW_WINDOW};
use hal_c2_shell::json::Json;
use ljos::prelude::ObjectId;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;

const NAMES: [&str; 4] = [MAIN, "two", "three", "../up"];
const SECTIONS: [&str; 3] = ["/settings/general", "/settings/archived", "/settings"];
const TICK_MS: u64 = 100;

#[derive(Clone, Debug)]
enum Op {
    /// `open_window` with a name (invalid ones get a fresh id).
    Open(&'static str),
    /// `window.new` from the open window at `pick`.
    New(usize),
    Close(usize),
    /// `set_aside_window`, as when no root could be made for it.
    SetAside(usize),
    Navigate(usize, &'static str),
    Width(usize, bool),
    /// `backendError` published from a window.
    Share(usize, u8),
    /// A shared controller's MC call made from a window.
    Call(usize),
    Answer(usize),
    Tick,
    /// The app quits and starts again over the same state directory.
    Restart,
}

fn op() -> impl Strategy<Value = Op> {
    let pick = any::<usize>();
    prop_oneof![
        3 => proptest::sample::select(&NAMES[..]).prop_map(Op::Open),
        2 => pick.prop_map(Op::New),
        4 => pick.prop_map(Op::Close),
        2 => pick.prop_map(Op::SetAside),
        2 => (pick, proptest::sample::select(&SECTIONS[..])).prop_map(|(i, s)| Op::Navigate(i, s)),
        2 => (pick, any::<bool>()).prop_map(|(i, narrow)| Op::Width(i, narrow)),
        1 => (pick, 0u8..3).prop_map(|(i, v)| Op::Share(i, v)),
        2 => pick.prop_map(Op::Call),
        2 => pick.prop_map(Op::Answer),
        2 => Just(Op::Tick),
        1 => Just(Op::Restart),
    ]
}

/// What the model expects of an open window.
#[derive(Clone)]
struct Open {
    id: String,
    bridge: Bridge,
    section: Option<&'static str>,
    narrow: Option<bool>,
    timer: ObjectId,
    ticks: Rc<Cell<u32>>,
    /// How many times the model says its timer ran.
    expected_ticks: u32,
    /// Opened from the saved set ([`controller::restore_windows`] or by
    /// the id of one set aside).
    restored: bool,
}

/// A call's: its index among the MC's calls, the window it was made from,
/// and as whom the answer ran.
type Asked = (usize, Bridge, Rc<RefCell<Option<Bridge>>>);

/// The running shell's hub, borrowing only that field.
macro_rules! hub {
    ($w:expr) => {
        $w.hub.as_ref().expect("the shell runs")
    };
}

struct World {
    hub: Option<Hub>,
    dir: PathBuf,
    open: Vec<Open>,
    /// Closed windows: their bridge and their timer, gone for good.
    closed: Vec<(Bridge, ObjectId)>,
    shared: Json,
    /// Windows set aside: still saved, with their route.
    aside: Vec<(String, Option<&'static str>)>,
    quit: bool,
    asked: Vec<Asked>,
    /// The subscriptions with one window open, and each other one's.
    base_subscriptions: usize,
    per_window: usize,
}

impl World {
    /// The shell started over `dir`, its first window alone.
    fn launch(dir: &std::path::Path) -> Hub {
        let hub = Hub::with(Launch {
            state_dir: Some(dir.to_owned()),
            ..Launch::default()
        });
        controller::set_window_opener(&hub.engine, |_, _| {});
        hub
    }

    fn new() -> World {
        let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("hub-windows-prop");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let hub = World::launch(&dir);
        let base_subscriptions = hub.mc.subscriptions().len();
        let mut world = World {
            dir,
            open: Vec::new(),
            closed: Vec::new(),
            shared: Json::Null,
            aside: Vec::new(),
            quit: false,
            asked: Vec::new(),
            base_subscriptions,
            per_window: 0,
            hub: Some(hub),
        };
        let first = world.opened(MAIN);
        world.open.push(first);
        // What one more window follows, measured once.
        controller::open_window(&hub!(world).engine, Some("probe"));
        world.per_window = hub!(world).mc.subscriptions().len() - base_subscriptions;
        controller::close_window(&hub!(world).engine, "probe");
        world
    }

    /// The model's record of window `id`, just opened: a timer of its own.
    fn opened(&self, id: &str) -> Open {
        let engine = &hub!(self).engine;
        let bridge = controller::window_bridge(engine, id).expect("the window is open");
        let ticks = Rc::new(Cell::new(0));
        let t = ticks.clone();
        let timer = controller::in_window(engine, id, || {
            controller::every(engine, None, TICK_MS as i32, move |_| t.set(t.get() + 1))
        })
        .flatten()
        .expect("a timer");
        Open {
            id: id.to_owned(),
            bridge,
            section: None,
            narrow: None,
            timer,
            ticks,
            expected_ticks: 0,
            restored: false,
        }
    }

    fn pick(&self, i: usize) -> usize {
        i % self.open.len()
    }

    /// The window the shell added last that the model has not.
    fn adopt_new(&mut self) {
        let ids = controller::windows(&hub!(self).engine);
        let new = ids
            .iter()
            .find(|id| !self.open.iter().any(|o| &o.id == *id))
            .expect("a window was added")
            .clone();
        assert_eq!(new.len(), 12, "a fresh id: {new}");
        let record = self.opened(&new);
        self.open.push(record);
    }

    fn step(&mut self, op: Op) {
        let engine = &hub!(self).engine;
        match op {
            Op::Open(name) => {
                let before = self.open.len();
                let id = controller::open_window(engine, Some(name)).unwrap();
                if self.open.iter().any(|o| o.id == name) {
                    assert_eq!(id, name, "an open window is raised");
                    assert_eq!(controller::windows(engine).len(), before);
                } else if controller::valid_window_id(name) {
                    assert_eq!(id, name);
                    let mut record = self.opened(name);
                    if let Some(at) = self.aside.iter().position(|(id, _)| id == name) {
                        record.restored = true;
                        record.section = self.aside.remove(at).1;
                    }
                    self.open.push(record);
                } else {
                    self.adopt_new();
                }
            }
            Op::New(i) => {
                let from = self.open[self.pick(i)].bridge;
                from.dispatch(engine, NEW_WINDOW, Json::Null);
                self.adopt_new();
            }
            Op::Close(i) => {
                let at = self.pick(i);
                controller::close_window(engine, &self.open[at].id.clone());
                if self.open.len() == 1 {
                    self.quit = !cfg!(target_os = "macos");
                } else {
                    let gone = self.open.remove(at);
                    self.closed.push((gone.bridge, gone.timer));
                }
                engine.process_deferred_deletes();
            }
            Op::SetAside(i) => {
                let at = self.pick(i);
                controller::set_aside_window(engine, &self.open[at].id.clone());
                if self.open.len() == 1 {
                    self.quit = !cfg!(target_os = "macos");
                } else {
                    let gone = self.open.remove(at);
                    if gone.restored {
                        self.aside.push((gone.id.clone(), gone.section));
                    }
                    self.closed.push((gone.bridge, gone.timer));
                }
                engine.process_deferred_deletes();
            }
            Op::Navigate(i, section) => {
                let at = self.pick(i);
                self.open[at]
                    .bridge
                    .dispatch(engine, "settings.navigate", json!({"to": section}));
                self.open[at].section = Some(section);
            }
            Op::Width(i, narrow) => {
                let at = self.pick(i);
                let width = if narrow { 500 } else { 1400 };
                self.open[at]
                    .bridge
                    .dispatch(engine, "layout.window", json!({"width": width}));
                self.open[at].narrow = Some(narrow);
            }
            Op::Share(i, value) => {
                let at = self.pick(i);
                let value = json!(format!("down {value}"));
                self.open[at]
                    .bridge
                    .publish(engine, "backendError", value.clone());
                self.shared = value;
            }
            Op::Call(i) => {
                let from = self.open[self.pick(i)].bridge;
                let ran_as = Rc::new(RefCell::new(None));
                let r = ran_as.clone();
                let mc = controller::mc(engine).unwrap();
                let index = hub!(self).mc.calls.borrow().len();
                from.act(engine, || {
                    mc.call(
                        "local",
                        "probe.call",
                        Json::Null,
                        Box::new(move |engine, _| {
                            *r.borrow_mut() = Some(Bridge::of(engine));
                        }),
                    );
                });
                self.asked.push((index, from, ran_as));
            }
            Op::Answer(i) => {
                if self.asked.is_empty() {
                    return;
                }
                let (index, from, ran_as) = self.asked.remove(i % self.asked.len());
                assert!(hub!(self).mc.reply(engine, index, Ok(Json::Null)));
                let ran = ran_as
                    .borrow()
                    .expect("a shared controller hears its answer");
                if from.is_open(engine) {
                    assert_eq!(ran, from, "the answer runs as the window that asked");
                } else {
                    assert!(ran.is_open(engine) || ran == Bridge::main(engine));
                }
            }
            Op::Tick => {
                hub!(self).advance(TICK_MS);
                for open in &mut self.open {
                    open.expected_ticks += 1;
                }
            }
            Op::Restart => self.restart(),
        }
    }

    /// NativeShell::setStoreDirs and restoreWindows: the saved windows come
    /// back in order, each with its route; what was this run's is gone.
    fn restart(&mut self) {
        let sections: Vec<(String, Option<&'static str>)> = self
            .open
            .iter()
            .map(|o| (o.id.clone(), o.section))
            .chain(std::mem::take(&mut self.aside))
            .collect();
        // One shell at a time: the first goes before the next reads.
        self.hub = None;
        self.hub = Some(World::launch(&self.dir));
        let engine = &hub!(self).engine;
        assert_eq!(
            controller::windows(engine),
            vec![sections[0].0.clone()],
            "the first window is the first saved"
        );
        self.base_subscriptions = hub!(self).mc.subscriptions().len();
        controller::restore_windows(engine);
        self.closed.clear();
        self.asked.clear();
        self.shared = Json::Null;
        self.quit = false;
        self.open = sections
            .into_iter()
            .enumerate()
            .map(|(at, (id, section))| Open {
                section,
                restored: at > 0,
                ..self.opened(&id)
            })
            .collect();
    }

    fn check(&self) {
        let engine = &hub!(self).engine;
        let ids: Vec<String> = self.open.iter().map(|o| o.id.clone()).collect();
        assert_eq!(controller::windows(engine), ids);
        let saved: Json = serde_json::from_str(
            &std::fs::read_to_string(self.dir.join("shell-windows.json")).unwrap(),
        )
        .unwrap();
        let kept: Vec<String> = ids
            .iter()
            .cloned()
            .chain(self.aside.iter().map(|(id, _)| id.clone()))
            .collect();
        assert_eq!(saved, json!({"open": kept}));
        assert_eq!(engine.quit_requested(), self.quit);
        for open in &self.open {
            let published = |key: &str| open.bridge.published(engine, key).unwrap_or(Json::Null);
            let route = published("route");
            match open.section {
                None => assert_eq!(route["kind"], "home", "{}: {route}", open.id),
                Some(section) => assert_eq!(route["section"], section, "{}", open.id),
            }
            if let Some(narrow) = open.narrow {
                let mode = if narrow { "rail" } else { "full" };
                assert_eq!(published("layout")["sidebarMode"], mode, "{}", open.id);
            }
            assert_eq!(published("backendError"), self.shared, "{}", open.id);
            assert_eq!(open.ticks.get(), open.expected_ticks, "{}", open.id);
            assert!(engine.is_alive(open.timer));
        }
        for (bridge, timer) in &self.closed {
            assert!(!bridge.is_open(engine));
            assert!(!engine.is_alive(*timer), "a closed window's timer is gone");
            if *bridge != Bridge::main(engine) {
                assert!(
                    !engine.is_alive(bridge.object()),
                    "a closed window's bridge is gone"
                );
            }
        }
        assert_eq!(
            hub!(self).mc.subscriptions().len(),
            self.base_subscriptions + self.per_window * (self.open.len() - 1),
            "each open window follows its own, and no closed one does"
        );
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 48, ..ProptestConfig::default() })]

    #[test]
    fn each_window_keeps_its_own_and_a_closed_one_leaves_nothing_behind(
        ops in proptest::collection::vec(op(), 1..30)
    ) {
        let mut world = World::new();
        world.check();
        for op in ops {
            world.step(op);
            world.check();
        }
    }
}
