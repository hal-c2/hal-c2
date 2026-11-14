//! `layout`, desktop-qt's LayoutController: the sidebar's width, how it
//! draws, whether it is collapsed or over the thread, and the zoom, for
//! ShellWindow.
//!
//! `sidebarMode` is "full" (two-line rows), "slim" (one-line rows, a window
//! under 1100) or "rail" (a column of icons, one under 860). A narrow window
//! keeps the rail beside the thread, or nothing if the user hid the list;
//! `sidebar.toggle` there opens the full list over the thread
//! (`sidebarOverlay`) and puts it away again, unremembered. A window whose
//! layout has no slim rows or rail (`layout.window {modes: false}`, the
//! phone's tablet) keeps the full list, and is narrow only with no room for
//! its minimum beside the thread, where it shows nothing until toggled open
//! over it. `layout.window {monospace}` widens the default width.
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

/// The thread list's width: the default (wider in a monospace interface,
/// so a resting row shows 24 characters of its title) and minimum, the
/// rail's, and the room the thread keeps beside it.
pub const SIDEBAR_WIDTH: i32 = 256;
pub const SIDEBAR_MONOSPACE_WIDTH: i32 = 296;
pub const SIDEBAR_MIN_WIDTH: i32 = 208;
pub const RAIL_WIDTH: i32 = 48;
pub const CONTENT_MIN_WIDTH: i32 = 480;
/// The window widths under which the rows go slim, and the list a rail.
pub const SLIM_BELOW: i32 = 1100;
pub const RAIL_BELOW: i32 = 860;

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
    /// Opened over the thread in a narrow window (`sidebar_overlay`);
    /// forgotten when the window widens.
    overlay_open: bool,
    /// The width the user chose, or 0 for the default.
    sidebar_width: i32,
    /// 0 until the window says.
    window_width: i32,
    monospace: bool,
    /// The window's layout draws the slim rows and the rail.
    modes: bool,
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
            sidebar_width: 0,
            window_width: 0,
            monospace: false,
            modes: true,
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
            move |engine| me.run(engine, |c, engine| c.toggle_sidebar(engine)),
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
            "sidebar.toggle" => self.toggle_sidebar(engine),
            "sidebar.resize" => match payload.get("width").and_then(Json::as_f64) {
                Some(width) => self.set_sidebar_width(engine, width as i32),
                None => self.choose_sidebar_width(engine, 0),
            },
            "layout.window" => {
                let width = payload.get("width").and_then(Json::as_f64).unwrap_or(0.0) as i32;
                let monospace = payload.get("monospace").and_then(Json::as_bool);
                let modes = payload.get("modes").and_then(Json::as_bool);
                if let Some(monospace) = monospace {
                    self.set_monospace(engine, monospace);
                }
                self.change_window(engine, |layout| {
                    if let Some(modes) = modes {
                        layout.modes = modes;
                    }
                    layout.window_width = width;
                });
            }
            _ => return false,
        }
        true
    }
}

impl Layout {
    /// The window is too narrow for the full list beside the thread: it
    /// keeps a rail there instead. Without the rail, too narrow for its
    /// minimum.
    pub fn narrow(&self) -> bool {
        let below = if self.modes {
            RAIL_BELOW
        } else {
            SIDEBAR_MIN_WIDTH + CONTENT_MIN_WIDTH
        };
        self.window_width > 0 && self.window_width < below
    }

    /// The rail is drawn beside the thread.
    pub fn rail(&self) -> bool {
        self.modes && self.narrow() && !self.overlay_open
    }

    /// The full list is drawn over the thread.
    pub fn sidebar_overlay(&self) -> bool {
        self.narrow() && self.overlay_open
    }

    /// Nothing of the list is drawn: hidden by the user, and in a narrow
    /// window not opened over the thread; without the rail, a narrow window
    /// shows nothing until it is.
    pub fn sidebar_collapsed(&self) -> bool {
        if !self.modes && self.narrow() {
            return !self.overlay_open;
        }
        self.sidebar_collapsed && !self.sidebar_overlay()
    }

    /// How the list draws: "full", "slim" or "rail".
    pub fn sidebar_mode(&self) -> &'static str {
        if self.rail() {
            "rail"
        } else if self.modes
            && !self.narrow()
            && self.window_width > 0
            && self.window_width < SLIM_BELOW
        {
            "slim"
        } else {
            "full"
        }
    }

    /// The default width for the window's interface font.
    pub fn default_sidebar_width(&self) -> i32 {
        if self.monospace {
            SIDEBAR_MONOSPACE_WIDTH
        } else {
            SIDEBAR_WIDTH
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

    /// The width drawn now: the one chosen, less when the window leaves it
    /// no room, never under the minimum; the rail's in a narrow window.
    pub fn sidebar_width(&self) -> i32 {
        if self.rail() {
            return RAIL_WIDTH;
        }
        let chosen = if self.sidebar_width > 0 {
            self.sidebar_width
        } else {
            self.default_sidebar_width()
        };
        chosen.min(self.sidebar_room()).max(SIDEBAR_MIN_WIDTH)
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

    /// The width the user chose, at least the minimum and no more than the
    /// window allows. The default is not a choice: a monospace interface
    /// keeps its own.
    fn set_sidebar_width(&mut self, engine: &Engine, width: i32) {
        let width = width.min(self.sidebar_room()).max(SIDEBAR_MIN_WIDTH);
        let chosen = if width == self.default_sidebar_width() {
            0
        } else {
            width
        };
        self.choose_sidebar_width(engine, chosen);
    }

    /// Remembers the width chosen, 0 for the default (whose key goes).
    fn choose_sidebar_width(&mut self, engine: &Engine, width: i32) {
        if width == self.sidebar_width {
            return;
        }
        let before = self.sidebar_width();
        self.sidebar_width = width;
        let value = if width == 0 { Json::Null } else { json!(width) };
        Settings::of(engine).write_device(engine, SIDEBAR_WIDTH_KEY, value);
        if self.sidebar_width() != before {
            self.publish(engine);
        }
    }

    fn set_monospace(&mut self, engine: &Engine, monospace: bool) {
        if monospace == self.monospace {
            return;
        }
        let before = self.sidebar_width();
        self.monospace = monospace;
        if self.sidebar_width() != before {
            self.publish(engine);
        }
    }

    /// Changes the window, forgetting an overlay the change widened (or
    /// narrowed) away, and publishes what that changed.
    fn change_window(&mut self, engine: &Engine, change: impl FnOnce(&mut Layout)) {
        let before = self.state();
        let was_narrow = self.narrow();
        change(self);
        if self.narrow() != was_narrow {
            self.overlay_open = false;
        }
        if self.state() != before {
            self.publish(engine);
        }
    }

    /// A narrow window opens the full list over the thread, from the rail
    /// or from nothing, and puts it away again.
    fn toggle_sidebar(&mut self, engine: &Engine) {
        if self.narrow() {
            self.overlay_open = !self.overlay_open;
            self.publish(engine);
            return;
        }
        self.set_sidebar_collapsed(engine, !self.sidebar_collapsed());
    }

    /// Hides or shows the list; in a narrow window, closes or opens it over
    /// the thread, which is not remembered.
    pub fn set_sidebar_collapsed(&mut self, engine: &Engine, collapsed: bool) {
        if self.narrow() {
            if self.overlay_open == !collapsed {
                return;
            }
            self.overlay_open = !collapsed;
            self.publish(engine);
            return;
        }
        if collapsed == self.sidebar_collapsed() {
            return;
        }
        self.sidebar_collapsed = collapsed;
        Settings::of(engine).write_device(engine, SIDEBAR_COLLAPSED, json!(collapsed));
        self.publish(engine);
    }

    fn state(&self) -> Json {
        json!({
            "sidebarCollapsed": self.sidebar_collapsed(),
            "sidebarWidth": self.sidebar_width(),
            "sidebarMode": self.sidebar_mode(),
            "sidebarOverlay": self.sidebar_overlay(),
            "contentMinimumWidth": CONTENT_MIN_WIDTH,
            "zoom": 1.2_f64.powf(self.zoom_level),
        })
    }

    fn publish(&self, engine: &Engine) {
        self.bridge.publish(engine, "layout", self.state());
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
