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
use crate::controllers::settings::Settings;
use crate::json::Json;
use crate::platform_window;

pub const SIDEBAR_WIDTH: i32 = 256;
pub const SIDEBAR_MIN_WIDTH: i32 = 208;
pub const CONTENT_MIN_WIDTH: i32 = 480;

/// The panel animation's length for the two ways to ask for less motion and
/// the duration the user chose.
pub fn panel_animation_ms(system_reduced: bool, setting_reduced: bool, chosen_ms: i64) -> i32 {
    if system_reduced || setting_reduced {
        0
    } else {
        chosen_ms.clamp(0, 400) as i32
    }
}

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

    /// How long a panel opens or closes over, in ms: none when the system or
    /// the "Reduce motion" setting asks for less motion, else the
    /// `panelAnimationDurationMs` setting up to 400.
    pub fn panel_animation_ms(&self, engine: &Engine) -> i32 {
        let settings = Settings::of(engine);
        let setting = |key| settings.setting(engine, key);
        panel_animation_ms(
            platform_window::system_reduced_motion(engine),
            setting("reduceMotion")
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
            setting("panelAnimationDurationMs")
                .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
                .unwrap_or(0),
        )
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

#[cfg(test)]
mod tests {
    use super::panel_animation_ms;

    #[test]
    fn less_motion_from_the_system_or_the_setting_is_none() {
        assert_eq!(panel_animation_ms(false, false, 150), 150);
        assert_eq!(panel_animation_ms(true, false, 150), 0);
        assert_eq!(panel_animation_ms(false, true, 150), 0);
    }

    #[test]
    fn the_chosen_duration_stays_within_zero_and_four_hundred() {
        assert_eq!(panel_animation_ms(false, false, -5), 0);
        assert_eq!(panel_animation_ms(false, false, 9999), 400);
    }
}
