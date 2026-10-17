//! The hub controllers (toasts, menus, keybindings and commands, settings,
//! quit, alerts) driven as the bricks and the other controllers drive them,
//! headless, against a fake MC and a virtual clock.

#[path = "../common/mod.rs"]
mod common;

mod alerts;
mod archived_threads;
mod background_activity;
mod cluster;
mod commands;
mod connection_health;
mod connections;
mod device_settings;
mod diagnostics;
mod git;
mod keybindings;
mod layout;
mod limit_recovery;
mod lineage;
mod mc_plugin;
mod menus;
mod page;
mod panel;
mod plan;
mod plugin;
mod project_actions;
mod project_clone;
mod project_settings;
mod projects;
mod provider_settings;
mod provider_update_notice;
mod pull_request_list;
mod quit;
mod rewind;
mod scheduled_tasks;
mod scripted_run;
mod settings;
mod simple_pages;
mod slack;
mod source_control;
mod terminals;
mod threads;
mod toasts;
mod usage;
mod workspace;
mod worktree_setup;

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

impl Default for Hub {
    fn default() -> Hub {
        Hub::new()
    }
}

impl Hub {
    pub fn new() -> Hub {
        Hub::with(Launch::default())
    }

    /// A hub that follows the cluster: the shell store is installed and the
    /// controllers wait for the first `shell` frame, which the test sends.
    pub fn clustered() -> Hub {
        Hub::with(Launch {
            mc_origin: Some("http://127.0.0.1:1".into()),
            ..Launch::default()
        })
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
