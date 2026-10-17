//! `layout`, desktop-qt's LayoutController: the sidebar's width, whether it
//! is collapsed or over the thread, and the zoom, for ShellWindow.
//!
//! The width, whether the list is collapsed and the zoom level are kept in
//! this device's preferences (`sidebarWidth`, `sidebarCollapsed`,
//! `zoomLevel`; a default is not written, the key goes) and read when the
//! preferences file is, which is after the controllers are built. A
//! collapse chosen while the window is too narrow for the list beside the
//! thread (`sidebar_overlay`) is not kept. Every window follows the zoom
//! another window wrote.
//!
//! Commands: `sidebar.toggle`, and `view.zoomIn`, `view.zoomOut` and
//! `view.resetZoom`, which move the zoom level by half a step within the
//! range of 25% to 500% (levels -7.5 to 8.5; the zoom is 1.2 to the level).

use ljos::prelude::Engine;
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{Controller, Init, Me};
use crate::controllers::settings::Settings;
use crate::json::Json;
use crate::keybindings::command_label;
use crate::platform_window;

pub const SIDEBAR_WIDTH: i32 = 256;
pub const SIDEBAR_MIN_WIDTH: i32 = 208;
pub const CONTENT_MIN_WIDTH: i32 = 480;

const SIDEBAR_COLLAPSED: &str = "sidebarCollapsed";
const SIDEBAR_WIDTH_KEY: &str = "sidebarWidth";
const ZOOM_LEVEL: &str = "zoomLevel";
/// The zoom menu's step, and the range of 25% to 500%.
const ZOOM_STEP: f64 = 0.5;
const MIN_ZOOM_LEVEL: f64 = -7.5;
const MAX_ZOOM_LEVEL: f64 = 8.5;

/// How long a panel opens or closes over, in ms: none when the system or
/// the "Reduce motion" setting asks for less motion, else the
/// `panelAnimationDurationMs` setting up to 400.
pub fn panel_animation_ms(engine: &Engine) -> i32 {
    let settings = Settings::of(engine);
    let setting = |key| settings.setting(engine, key);
    animation_ms(
        platform_window::system_reduced_motion(engine),
        setting("reduceMotion")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        setting("panelAnimationDurationMs")
            .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
            .unwrap_or(0),
    )
}

/// The panel animation's length for the two ways to ask for less motion and
/// the duration the user chose.
fn animation_ms(system_reduced: bool, setting_reduced: bool, chosen_ms: i64) -> i32 {
    if system_reduced || setting_reduced {
        0
    } else {
        chosen_ms.clamp(0, 400) as i32
    }
}

pub struct Layout {
    bridge: Bridge,
    me: Me<Layout>,
    /// The device preferences have been read.
    loaded: bool,
    /// The commands are registered.
    active: bool,
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
        // The preferences file is read after the controllers are built: the
        // first time they change is when they are there to read. Later
        // changes are another window's zoom.
        let me = init.me.clone();
        Settings::of(init.engine).on_device_changed(move |engine| {
            me.run(engine, |c, engine| c.device_changed(engine));
        });
        let layout = Layout {
            bridge: init.bridge,
            me: init.me,
            loaded: false,
            active: false,
            sidebar_collapsed: false,
            overlay_open: false,
            sidebar_width: SIDEBAR_WIDTH,
            window_width: 0,
            zoom_level: 0.0,
        };
        layout.publish(init.engine);
        layout
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let commands = Commands::of(engine);
        let me = self.me.clone();
        commands.add(
            engine,
            "sidebar.toggle",
            &command_label("sidebar.toggle"),
            move |engine| {
                me.run(engine, |c, engine| {
                    c.set_sidebar_collapsed(engine, !c.sidebar_collapsed())
                })
            },
        );
        let zoom = |engine: &Engine, command: &str, title: &str, to: fn(f64) -> f64| {
            let me = self.me.clone();
            commands.add(engine, command, title, move |engine| {
                me.run(engine, |c, engine| {
                    c.set_zoom_level(engine, to(c.zoom_level))
                })
            });
        };
        zoom(engine, "view.zoomIn", "Zoom in", |level| level + ZOOM_STEP);
        zoom(engine, "view.zoomOut", "Zoom out", |level| {
            level - ZOOM_STEP
        });
        zoom(engine, "view.resetZoom", "Actual size", |_| 0.0);
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

    /// The device preferences changed: the first time they are read, then
    /// only the zoom another window set is followed.
    fn device_changed(&mut self, engine: &Engine) {
        let settings = Settings::of(engine);
        let level = settings
            .device_value(ZOOM_LEVEL)
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        if self.loaded {
            if level != self.zoom_level {
                self.zoom_level = level;
                self.publish(engine);
            }
            return;
        }
        self.loaded = true;
        self.sidebar_collapsed = settings
            .device_value(SIDEBAR_COLLAPSED)
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        self.zoom_level = level;
        let width = settings
            .device_value(SIDEBAR_WIDTH_KEY)
            .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
            .unwrap_or(0);
        if width > 0 {
            self.sidebar_width = (width.min(i32::MAX as i64) as i32).max(SIDEBAR_MIN_WIDTH);
        }
        self.publish(engine);
    }

    fn set_zoom_level(&mut self, engine: &Engine, level: f64) {
        let level = level.clamp(MIN_ZOOM_LEVEL, MAX_ZOOM_LEVEL);
        if level == self.zoom_level {
            return;
        }
        self.zoom_level = level;
        let value = if level == 0.0 {
            Json::Null
        } else {
            json!(level)
        };
        Settings::of(engine).write_device(engine, ZOOM_LEVEL, value);
        self.publish(engine);
    }

    fn set_sidebar_width(&mut self, engine: &Engine, width: i32) {
        let width = width.min(self.sidebar_room()).max(SIDEBAR_MIN_WIDTH);
        if width == self.sidebar_width {
            return;
        }
        self.sidebar_width = width;
        let value = if width == SIDEBAR_WIDTH {
            Json::Null
        } else {
            json!(width)
        };
        Settings::of(engine).write_device(engine, SIDEBAR_WIDTH_KEY, value);
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
            Settings::of(engine).write_device(engine, SIDEBAR_COLLAPSED, json!(collapsed));
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
    use super::animation_ms;

    #[test]
    fn less_motion_from_the_system_or_the_setting_is_none() {
        assert_eq!(animation_ms(false, false, 150), 150);
        assert_eq!(animation_ms(true, false, 150), 0);
        assert_eq!(animation_ms(false, true, 150), 0);
    }

    #[test]
    fn the_chosen_duration_stays_within_zero_and_four_hundred() {
        assert_eq!(animation_ms(false, false, -5), 0);
        assert_eq!(animation_ms(false, false, 9999), 400);
    }
}
