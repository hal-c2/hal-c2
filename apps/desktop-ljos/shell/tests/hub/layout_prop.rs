//! The layout as a state machine over what moves the thread list
//! (tst_LayoutProp.cpp): the window's width and interface font, the list's
//! edge dragged or reset, the toggle, and a restart reading the device's
//! preferences back. The list is never narrower than its minimum, leaves
//! the thread its room while it is beside it, goes slim in a window under
//! 1100, and in a window with no room for both keeps a rail beside the
//! thread whose toggle shows the full list over it, unremembered. A window
//! whose layout has no slim rows or rail keeps the full list, and with no
//! room for its minimum shows nothing until toggled open over the thread.

use std::path::PathBuf;

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::layout::{
    CONTENT_MIN_WIDTH, Layout, RAIL_BELOW, RAIL_WIDTH, SIDEBAR_MIN_WIDTH, SIDEBAR_MONOSPACE_WIDTH,
    SIDEBAR_WIDTH, SLIM_BELOW,
};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;

#[derive(Clone, Debug)]
enum Op {
    Toggle,
    Resize(i32),
    ResetWidth,
    Window(i32),
    Font(bool),
    Modes(bool),
    Restart,
}

fn op() -> impl Strategy<Value = Op> {
    // Around the edges: the rail's, the slim rows', the minimum's room, and
    // the default's.
    let window = prop_oneof![800..920, 1040..1160, 640..740, 640..1600];
    prop_oneof![
        2 => Just(Op::Toggle),
        1 => (0..900).prop_map(Op::Resize),
        1 => Just(Op::ResetWidth),
        2 => window.prop_map(Op::Window),
        1 => any::<bool>().prop_map(Op::Font),
        1 => any::<bool>().prop_map(Op::Modes),
        1 => Just(Op::Restart),
    ]
}

#[derive(Clone, Debug, Default)]
struct Model {
    /// What the device remembers: hidden, and the width chosen (0 for the
    /// default).
    collapsed: bool,
    chosen: i32,
    /// This run's: the window's width (0 until it says), its interface
    /// font, the full list shown over the thread, and whether the window's
    /// layout draws the slim rows and the rail.
    window: i32,
    monospace: bool,
    overlay_open: bool,
    no_modes: bool,
}

impl Model {
    fn modes(&self) -> bool {
        !self.no_modes
    }
    fn narrow(&self) -> bool {
        let below = if self.modes() {
            RAIL_BELOW
        } else {
            SIDEBAR_MIN_WIDTH + CONTENT_MIN_WIDTH
        };
        self.window > 0 && self.window < below
    }
    fn overlay(&self) -> bool {
        self.narrow() && self.overlay_open
    }
    fn rail(&self) -> bool {
        self.modes() && self.narrow() && !self.overlay_open
    }
    fn mode(&self) -> &'static str {
        if self.rail() {
            "rail"
        } else if self.modes() && !self.narrow() && self.window > 0 && self.window < SLIM_BELOW {
            "slim"
        } else {
            "full"
        }
    }
    fn fallback(&self) -> i32 {
        if self.monospace {
            SIDEBAR_MONOSPACE_WIDTH
        } else {
            SIDEBAR_WIDTH
        }
    }
    fn room(&self) -> i32 {
        if self.window > 0 {
            (self.window - CONTENT_MIN_WIDTH).max(0)
        } else {
            i32::MAX
        }
    }
    fn width(&self) -> i32 {
        if self.rail() {
            return RAIL_WIDTH;
        }
        let chosen = if self.chosen > 0 {
            self.chosen
        } else {
            self.fallback()
        };
        chosen.min(self.room()).max(SIDEBAR_MIN_WIDTH)
    }
    fn hidden(&self) -> bool {
        if !self.modes() && self.narrow() {
            !self.overlay_open
        } else {
            self.collapsed && !self.overlay()
        }
    }
    /// Changes the window, forgetting an overlay it widened or narrowed away.
    fn window_changes(&mut self, change: impl FnOnce(&mut Model)) {
        let narrow = self.narrow();
        change(self);
        if self.narrow() != narrow {
            self.overlay_open = false;
        }
    }
}

struct World {
    hub: Option<Hub>,
    home: tempfile::TempDir,
    model: Model,
}

impl World {
    fn new() -> World {
        let home = tempfile::tempdir_in(PathBuf::from(env!("CARGO_TARGET_TMPDIR"))).unwrap();
        let mut world = World {
            hub: None,
            home,
            model: Model::default(),
        };
        world.start();
        world
    }

    fn hub(&self) -> &Hub {
        self.hub.as_ref().unwrap()
    }

    fn start(&mut self) {
        self.hub = None;
        self.hub = Some(Hub::with(Launch {
            config_dir: Some(self.home.path().to_owned()),
            ..Launch::default()
        }));
    }

    fn window(&self, payload: Json) {
        self.hub().dispatch("layout.window", payload);
    }

    fn step(&mut self, op: Op) {
        let model = &mut self.model;
        match op {
            Op::Toggle => {
                if model.narrow() {
                    model.overlay_open = !model.overlay_open;
                } else {
                    model.collapsed = !model.collapsed;
                }
                self.hub().dispatch("sidebar.toggle", Json::Null);
            }
            Op::Resize(width) => {
                let clamped = width.min(model.room()).max(SIDEBAR_MIN_WIDTH);
                model.chosen = if clamped == model.fallback() {
                    0
                } else {
                    clamped
                };
                self.hub()
                    .dispatch("sidebar.resize", json!({"width": width}));
            }
            Op::ResetWidth => {
                model.chosen = 0;
                self.hub().dispatch("sidebar.resize", Json::Null);
            }
            Op::Window(width) => {
                model.window_changes(|m| m.window = width);
                self.window(json!({"width": width}));
            }
            Op::Font(monospace) => {
                model.monospace = monospace;
                let width = model.window;
                self.window(json!({"width": width, "monospace": monospace}));
            }
            Op::Modes(modes) => {
                model.window_changes(|m| m.no_modes = !modes);
                let width = model.window;
                self.window(json!({"width": width, "modes": modes}));
            }
            Op::Restart => {
                model.window = 0;
                model.monospace = false;
                model.overlay_open = false;
                model.no_modes = false;
                self.start();
                // The first thing a window does.
                self.window(json!({"width": 0}));
            }
        }
        self.check();
    }

    fn check(&self) {
        let m = &self.model;
        let hub = self.hub();
        let layout = hub.published("layout");
        let width = layout["sidebarWidth"].as_i64().unwrap() as i32;
        assert_eq!(width, m.width(), "{m:?}");
        assert_eq!(layout["sidebarMode"], m.mode(), "{m:?}");
        assert_eq!(layout["sidebarOverlay"], m.overlay(), "{m:?}");
        assert_eq!(layout["sidebarCollapsed"], m.hidden(), "{m:?}");
        let collapsed = hub.with_controller::<Layout, _>(|l, _| l.sidebar_collapsed());
        assert_eq!(collapsed, m.hidden());
        // Never under its minimum but as the rail, and beside the thread
        // only with room for both.
        if !m.rail() {
            assert!(width >= SIDEBAR_MIN_WIDTH);
        }
        if m.window > 0 && (!m.narrow() || m.rail()) {
            assert!(width <= m.window - CONTENT_MIN_WIDTH, "{m:?}");
        }
        // Without the modes, the full list or nothing.
        if !m.modes() {
            assert_eq!(layout["sidebarMode"], "full");
        }
        // What the device remembers, and the default never written down.
        let settings = Settings::of(&hub.engine);
        let value = |key: &str| settings.device_value(key).unwrap_or(Json::Null);
        assert_eq!(
            value("sidebarCollapsed").as_bool().unwrap_or(false),
            m.collapsed
        );
        assert_eq!(
            value("sidebarWidth").as_i64().unwrap_or(0) as i32,
            m.chosen,
            "{m:?}"
        );
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 48, ..ProptestConfig::default() })]

    #[test]
    fn the_list_keeps_its_minimum_and_the_thread_its_room_or_a_rail_goes_over_it(
        ops in proptest::collection::vec(op(), 1..30)
    ) {
        let mut world = World::new();
        world.check();
        for op in ops {
            world.step(op);
        }
    }
}
