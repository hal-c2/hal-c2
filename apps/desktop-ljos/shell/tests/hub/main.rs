//! The hub controllers (toasts, menus, keybindings and commands, settings,
//! quit, alerts) driven as the bricks and the other controllers drive them,
//! headless, against a fake MC and a virtual clock.

#[path = "../common/mod.rs"]
mod common;

mod commands;
mod menus;
mod toasts;

use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use common::FakeMc;
use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::json::Json;
use ljos::App;
use ljos::prelude::Engine;
use ljos_runtime::{Clock as _, VirtualClock};

/// A started shell with no QML, its clock virtual from the start.
pub struct Hub {
    pub engine: Engine,
    pub clock: Arc<VirtualClock>,
    pub mc: Rc<FakeMc>,
}

impl Hub {
    pub fn new() -> Hub {
        Hub::with(Launch::default())
    }

    pub fn with(launch: Launch) -> Hub {
        let engine = App::new("test")
            .register(hal_c2_shell::register)
            .build_engine();
        let clock = Arc::new(VirtualClock::new());
        engine.set_clock(Rc::new(clock.clone()));
        let mc = Rc::new(FakeMc::default());
        hal_c2_shell::start(&engine, &launch, mc.clone());
        Hub { engine, clock, mc }
    }

    pub fn published(&self, key: &str) -> Json {
        Bridge::of(&self.engine)
            .published(&self.engine, key)
            .unwrap_or(Json::Null)
    }

    pub fn dispatch(&self, action: &str, payload: Json) {
        Bridge::of(&self.engine).dispatch(&self.engine, action, payload);
    }

    /// Moves the clock on by `ms` and runs what fell due.
    pub fn advance(&self, ms: u64) {
        self.clock.set(self.clock.now() + Duration::from_millis(ms));
        self.engine.advance_timers(self.clock.now());
    }

    /// Runs `f` on the controller `C`, as another controller would.
    pub fn with_controller<C: hal_c2_shell::controller::Controller, R>(
        &self,
        f: impl FnOnce(&mut C, &Engine) -> R,
    ) -> R {
        hal_c2_shell::controller::with::<C, R>(&self.engine, f).expect("the controller is free")
    }
}
