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
mod composer;
mod composer_prop;
mod connection_health;
mod connections;
mod device_settings;
mod diagnostics;
mod file_actions;
mod git;
mod identity;
mod keybindings;
mod layout;
mod limit_recovery;
mod lineage;
mod mc_plugin;
mod menus;
mod onboarding;
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
mod pull_request_thread;
mod quit;
mod rewind;
mod scheduled_tasks;
mod scripted_run;
mod settings;
mod simple_pages;
mod slack;
mod snap_shot;
mod snap_shot_prop;
mod source_control;
mod terminals;
mod threads;
mod toasts;
mod usage;
mod workspace;
mod workspace_files;
mod worktree_setup;

use std::cell::RefCell;
use std::rc::Rc;

use common::FakeMc;
use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::json::Json;
use ljos::App;
use ljos::keys::KeyEvent;
use ljos::prelude::Engine;
use ljos::testing::TestWindow;

/// A started shell with no QML, its clock virtual from the start: the
/// clock of a test window that shows nothing until [`Hub::window`].
pub struct Hub {
    pub engine: Engine,
    test_window: Rc<RefCell<TestWindow>>,
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
        // Before the shell starts, for its timers to start on the window's clock.
        let test_window = Rc::new(RefCell::new(ljos::testing::TestWindow::new(
            &engine, 100.0, 100.0,
        )));
        let mc = Rc::new(FakeMc::default());
        hal_c2_shell::start(&engine, &launch, mc.clone());
        Hub {
            engine,
            test_window,
            mc,
        }
    }

    pub fn published(&self, key: &str) -> Json {
        Bridge::of(&self.engine)
            .published(&self.engine, key)
            .unwrap_or(Json::Null)
    }

    pub fn dispatch(&self, action: &str, payload: Json) {
        Bridge::of(&self.engine).dispatch(&self.engine, action, payload);
    }

    /// Moves the clock on by `ms`, running each timer as it falls due.
    pub fn advance(&self, ms: u64) {
        self.test_window
            .borrow_mut()
            .advance(ms)
            .expect("the hub comes to rest");
    }

    /// The hub's window with an empty item in it, for key events given as
    /// a window is given them: the application's key filters see them first.
    pub fn window(&self) -> Window {
        let source = common::compile(&[("Window", "import QtQuick\nItem {}")], &[]);
        let root = ljos::create_root(&self.engine, source, "Window").expect("the window");
        self.test_window.borrow_mut().show(root).expect("a root");
        Window(self.test_window.clone())
    }

    /// Runs `f` on the controller `C`, as another controller would.
    pub fn with_controller<C: hal_c2_shell::controller::Controller, R>(
        &self,
        f: impl FnOnce(&mut C, &Engine) -> R,
    ) -> R {
        hal_c2_shell::controller::with::<C, R>(&self.engine, f).expect("the controller is free")
    }
}

/// A window with nothing in it ([`Hub::window`]).
pub struct Window(Rc<RefCell<TestWindow>>);

impl Window {
    /// Gives the window `ev`; true when something kept it.
    pub fn key(&self, ev: &KeyEvent) -> bool {
        self.0.borrow_mut().key(ev)
    }
}
