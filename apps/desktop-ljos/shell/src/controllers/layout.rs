//! `layout`, desktop-qt's LayoutController: the sidebar's width, whether it
//! is collapsed or over the thread, and the zoom, for ShellWindow.
//!
//! Not ported yet: keeping them in the device preferences (they last as long
//! as the window), and the zoom and sidebar commands, which wait for the
//! command registry.

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{Controller, Init};
use crate::json::Json;

pub const SIDEBAR_WIDTH: i32 = 256;
pub const SIDEBAR_MIN_WIDTH: i32 = 208;
pub const CONTENT_MIN_WIDTH: i32 = 480;

pub struct Layout {
    bridge: Bridge,
    sidebar_collapsed: bool,
    /// Shown over the thread while `sidebar_overlay`; forgotten when the
    /// window widens.
    overlay_open: bool,
    sidebar_width: i32,
    /// 0 until the window says.
    window_width: i32,
    zoom_level: f64,
}

impl Controller for Layout {
    // The layout needs no MC, so it shows before the first snapshot.
    fn new(init: Init<'_, Self>) -> Self {
        let layout = Layout {
            bridge: init.bridge,
            sidebar_collapsed: false,
            overlay_open: false,
            sidebar_width: SIDEBAR_WIDTH,
            window_width: 0,
            zoom_level: 0.0,
        };
        layout.publish(init.engine);
        layout
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        match action {
            "sidebar.toggle" => self.set_sidebar_collapsed(engine, !self.sidebar_collapsed()),
            "sidebar.resize" => match payload.get("width").and_then(Json::as_f64) {
                Some(width) => self.set_sidebar_width(engine, width as i32),
                None => self.set_sidebar_width(engine, SIDEBAR_WIDTH),
            },
            "layout.window" => {
                let width = payload.get("width").and_then(Json::as_f64).unwrap_or(0.0) as i32;
                self.set_window_width(engine, width);
            }
            _ => return false,
        }
        true
    }
}

impl Layout {
    pub fn sidebar_overlay(&self) -> bool {
        self.window_width > 0 && self.window_width < SIDEBAR_MIN_WIDTH + CONTENT_MIN_WIDTH
    }

    pub fn sidebar_collapsed(&self) -> bool {
        if self.sidebar_overlay() {
            !self.overlay_open
        } else {
            self.sidebar_collapsed
        }
    }

    /// What the sidebar may take and leave the thread its minimum.
    fn sidebar_room(&self) -> i32 {
        if self.window_width > 0 {
            (self.window_width - CONTENT_MIN_WIDTH).max(0)
        } else {
            i32::MAX
        }
    }

    pub fn sidebar_width(&self) -> i32 {
        self.sidebar_width
            .min(self.sidebar_room())
            .max(SIDEBAR_MIN_WIDTH)
    }

    fn set_sidebar_width(&mut self, engine: &Engine, width: i32) {
        let width = width.min(self.sidebar_room()).max(SIDEBAR_MIN_WIDTH);
        if width == self.sidebar_width {
            return;
        }
        self.sidebar_width = width;
        self.publish(engine);
    }

    fn set_window_width(&mut self, engine: &Engine, width: i32) {
        if width == self.window_width {
            return;
        }
        let before = (
            self.sidebar_width(),
            self.sidebar_overlay(),
            self.sidebar_collapsed(),
        );
        self.window_width = width;
        if self.sidebar_overlay() != before.1 {
            self.overlay_open = false;
        }
        if (
            self.sidebar_width(),
            self.sidebar_overlay(),
            self.sidebar_collapsed(),
        ) != before
        {
            self.publish(engine);
        }
    }

    fn set_sidebar_collapsed(&mut self, engine: &Engine, collapsed: bool) {
        if collapsed == self.sidebar_collapsed() {
            return;
        }
        if self.sidebar_overlay() {
            self.overlay_open = !collapsed;
        } else {
            self.sidebar_collapsed = collapsed;
        }
        self.publish(engine);
    }

    fn publish(&self, engine: &Engine) {
        self.bridge.publish(
            engine,
            "layout",
            json!({
                "sidebarCollapsed": self.sidebar_collapsed(),
                "sidebarWidth": self.sidebar_width(),
                "sidebarOverlay": self.sidebar_overlay(),
                "zoom": 1.2_f64.powf(self.zoom_level),
            }),
        );
    }
}
