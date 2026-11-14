//! `folders`, desktop-qt's FoldersController: whether the folder explorer
//! (the local folder browser, `crate::folders`) is open. A palette command
//! and an action both toggle it.
//!
//! Publishes `folders`: {open}. Action `folders.toggle {open?}` (no `open`
//! flips it).

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{Controller, Init, Me};
use crate::json::Json;
use crate::settings_page;

const TOGGLE: &str = "folders.toggle";

pub struct Folders {
    bridge: Bridge,
    me: Me<Folders>,
    active: bool,
    open: bool,
}

impl Controller for Folders {
    fn new(init: Init<'_, Self>) -> Self {
        Folders {
            bridge: init.bridge,
            me: init.me,
            active: false,
            open: false,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let commands = Commands::of(engine);
        let me = self.me.clone();
        commands.add(engine, TOGGLE, "Manage folders", move |engine| {
            me.run(engine, |c, engine| c.set_open(engine, !c.open));
        });
        commands.set_terms(
            TOGGLE,
            &["folder explorer", "rename", "move", "trash", "directory"],
        );
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if action != TOGGLE {
            return false;
        }
        let open = match payload.get("open") {
            Some(open) => settings_page::flag(Some(open)),
            None => !self.open,
        };
        self.set_open(engine, open);
        true
    }
}

impl Folders {
    pub fn is_open(&self) -> bool {
        self.open
    }

    pub fn set_open(&mut self, engine: &Engine, open: bool) {
        if open == self.open {
            return;
        }
        self.open = open;
        self.publish(engine);
    }

    fn publish(&self, engine: &Engine) {
        self.bridge
            .publish(engine, "folders", json!({"open": self.open}));
    }
}
