//! `quit`, desktop-qt's QuitController: the quit shortcut (mod+Q), guarded
//! as this device's `confirmQuit` says:
//!   - "hold" (the default): holding it 1.2 seconds quits, as do two presses
//!     within half a second; a single quick press only says how.
//!   - "double-click": two presses within half a second quit; one says to
//!     press again.
//!   - "direct": one press quits.
//!
//! It sees the window's key events before anything in the window, so a text
//! field or a terminal never sees the shortcut ([`filter`]). "Still held" is
//! proven by auto-repeat: without it only two presses quit. Quit (the
//! palette's `app.quit`) is immediate.
//!
//! Publishes `quitHint`: null, or `{message}` while the hint shows.
//!
//! Time is the engine's clock, so a test's virtual clock drives it; the next
//! deadline is one `Engine::call_at`.

use std::rc::Rc;
use std::time::Duration;

use ljos::prelude::Engine;
use ljos_quick::{KeyEvent, KeyKind, Modifiers};
use ljos_runtime::{Time, TimerId};
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me, Window};
use crate::controllers::keybindings::Keymap;
use crate::controllers::settings::Settings;
use crate::json::Json;
use crate::keybindings::qt;

pub const HOLD: Duration = Duration::from_millis(1200);
pub const DOUBLE_PRESS: Duration = Duration::from_millis(500);
pub const RELEASE_GRACE: Duration = Duration::from_millis(600);
/// A released hold's hint stays as long as a hold takes.
pub const HINT_LINGER: Duration = Duration::from_millis(1200);
pub const QUIT: &str = "app.quit";

/// What `confirmQuit` asks of the shortcut.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Hold,
    DoublePress,
    Direct,
}

impl Mode {
    /// The setting's value; the old setting was a boolean, and anything
    /// else holds.
    pub fn of(value: Option<&Json>) -> Mode {
        match value {
            Some(Json::Bool(true)) => Mode::Hold,
            Some(Json::Bool(false)) => Mode::Direct,
            Some(Json::String(s)) if s == "direct" => Mode::Direct,
            Some(Json::String(s)) if s == "double-click" => Mode::DoublePress,
            _ => Mode::Hold,
        }
    }
}

/// What the watchdog does when its time comes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Then {
    Release,
    Quit,
}

pub type Hook = Rc<dyn Fn(&Engine)>;

pub struct QuitController {
    bridge: Bridge,
    me: Me<Self>,
    active: bool,
    timer: Option<TimerId>,
    watch_at: Option<Time>,
    on_watchdog: Option<Then>,
    linger_at: Option<Time>,
    /// The mode of the press under way; `None` between presses.
    mode: Option<Mode>,
    hint_mode: Option<Mode>,
    hint: String,
    holding: bool,
    notified: bool,
    /// A hold may complete (from auto-repeats) only once armed.
    armed: bool,
    quit_on_release: bool,
    held_since: Time,
    last_press_at: Option<Time>,
    last_repeat_at: Option<Time>,
    repeat_cadence: Duration,
    quit_hooks: Vec<Hook>,
    conceal_hooks: Vec<Hook>,
}

impl Controller for QuitController {
    fn new(init: Init<'_, Self>) -> Self {
        QuitController {
            bridge: init.bridge,
            me: init.me,
            active: false,
            timer: None,
            watch_at: None,
            on_watchdog: None,
            linger_at: None,
            mode: None,
            hint_mode: None,
            hint: String::new(),
            holding: false,
            notified: false,
            armed: false,
            quit_on_release: false,
            held_since: Time::ZERO,
            last_press_at: None,
            last_repeat_at: None,
            repeat_cadence: Duration::ZERO,
            quit_hooks: Vec::new(),
            conceal_hooks: Vec::new(),
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        self.publish(engine);
    }

    fn attach(&mut self, engine: &Engine, _window: &Window) {
        let commands = Commands::of(engine);
        let me = self.me.clone();
        commands.add(engine, QUIT, "Quit HAL-C2", move |engine| {
            me.run(engine, |quit, engine| quit.quit(engine));
        });
        commands.set_terms(QUIT, &["quit", "exit"]);
    }
}

/// Offers a key event of the window's to the quit shortcut before anything
/// in the window sees it; true when it was the shortcut's, and so not the
/// window's. The window calls it for every key event it gets.
///
/// TODO(ljos#43): Ljós has no application-wide key filter (Qt's
/// `installEventFilter`); an application `Shortcut` takes mod+Q before an
/// editor but not the hold and release this counts, so nothing calls this
/// yet. Claiming the press also covers Qt's ShortcutOverride:
/// no `Shortcut` sees a press this took.
pub fn filter(engine: &Engine, ev: &KeyEvent) -> bool {
    controller::with::<QuitController, _>(engine, |quit, engine| quit.key_event(engine, ev))
        .unwrap_or(false)
}

impl QuitController {
    /// Quits now, whatever the setting.
    pub fn quit(&mut self, engine: &Engine) {
        self.release(engine, false);
        self.last_press_at = None;
        // Queued, as main.cpp's connection is: the quit hooks may reach back.
        let hooks = self.quit_hooks.clone();
        self.bridge.defer(engine, move |engine| {
            for hook in &hooks {
                hook(engine);
            }
            // Qt.quit(): Ljós has no Rust call for it (`Engine::request_quit`
            // is crate-private), so it goes through JS.
            let _ = engine.eval_js("Qt.quit()");
        });
    }

    /// What the hint says; empty while none shows.
    pub fn hint(&self) -> &str {
        &self.hint
    }

    /// `f` runs as the app quits (desktop-qt's `quitRequested`).
    pub fn on_quit(&mut self, f: impl Fn(&Engine) + 'static) {
        self.quit_hooks.push(Rc::new(f));
    }

    /// `f` runs when a hold is complete: the windows can go while the key is
    /// released (desktop-qt's `concealRequested`).
    pub fn on_conceal(&mut self, f: impl Fn(&Engine) + 'static) {
        self.conceal_hooks.push(Rc::new(f));
    }

    /// One key event of the window's, as [`filter`] offers it.
    pub fn key_event(&mut self, engine: &Engine, ev: &KeyEvent) -> bool {
        match ev.kind {
            KeyKind::Press => self.key_down(engine, ev.key, ev.modifiers, ev.auto_repeat),
            KeyKind::Release => {
                // X11 pairs every auto-repeat press with a release.
                if !ev.auto_repeat {
                    self.key_up(engine, ev.key);
                }
                false
            }
        }
    }

    fn mode(&self, engine: &Engine) -> Mode {
        Mode::of(Settings::of(engine).setting(engine, "confirmQuit").as_ref())
    }

    /// True when the press is the quit shortcut's, and so not the window's.
    fn key_down(
        &mut self,
        engine: &Engine,
        key: i32,
        modifiers: Modifiers,
        auto_repeat: bool,
    ) -> bool {
        let now = engine.now();
        // Qt (and Ljós) call Command Control on macOS, so this is mod either
        // way.
        let modifier_down = modifiers.contains(Modifiers::CONTROL);
        let is_q = key == qt::KEY_Q;
        if auto_repeat && modifier_down && is_q {
            self.repeat_cadence = now - self.last_repeat_at.unwrap_or(self.held_since);
            self.last_repeat_at = Some(now);
        }
        if self.quit_on_release {
            // Q still down pushes the quiet period back.
            if is_q {
                self.quit_after_quiet_period(engine);
            }
            return true;
        }
        let other = modifiers.intersects(Modifiers::ALT | Modifiers::SHIFT | Modifiers::META);
        if !modifier_down || other || !is_q {
            // Pressing mod again starts the second press: it must not end
            // the first.
            if key == qt::KEY_CONTROL && !other {
                return false;
            }
            // Any other key cancels the hold and the first press.
            if !auto_repeat {
                self.last_press_at = None;
                self.release(engine, false);
            }
            return false;
        }
        if auto_repeat {
            if self.mode == Some(Mode::Hold) && self.armed && now - self.held_since >= HOLD {
                self.armed = false;
                self.quit_on_release = true;
                let hooks = self.conceal_hooks.clone();
                self.bridge.defer(engine, move |engine| {
                    for hook in &hooks {
                        hook(engine);
                    }
                });
                self.quit_after_quiet_period(engine);
            }
            return true;
        }

        let previous_press_at = self.last_press_at.replace(now);
        // A fresh press supersedes the hold, or the hint left after a
        // release.
        if self.holding || self.notified {
            self.release(engine, false);
        }
        // Every mode takes two presses.
        if previous_press_at.is_some_and(|at| now - at <= DOUBLE_PRESS) {
            self.quit(engine);
            return true;
        }
        let mode = self.mode(engine);
        if mode == Mode::Direct {
            self.quit(engine);
            return true;
        }
        self.holding = true;
        self.held_since = now;
        self.mode = Some(mode);
        self.notified = true;
        self.show_hint(engine, mode);
        if mode == Mode::DoublePress {
            self.watch(engine, DOUBLE_PRESS, Then::Release);
            return true;
        }
        self.armed = true;
        // No auto-repeat by then means the key was released, or repeat is
        // off: either way, no quitting.
        self.watch(engine, HOLD + RELEASE_GRACE, Then::Release);
        true
    }

    fn key_up(&mut self, engine: &Engine, key: i32) {
        if key == qt::KEY_Q {
            let should_quit = self.quit_on_release;
            self.release(engine, true);
            if should_quit {
                self.quit(engine);
            }
        } else if key == qt::KEY_CONTROL {
            if self.quit_on_release {
                self.quit_after_quiet_period(engine);
            } else {
                self.release(engine, true);
            }
        }
    }

    fn release(&mut self, engine: &Engine, keep_double_press_hint: bool) {
        if !self.holding && !self.notified {
            return;
        }
        let keep_hint =
            keep_double_press_hint && self.mode == Some(Mode::DoublePress) && self.notified;
        self.holding = false;
        self.armed = false;
        self.quit_on_release = false;
        self.last_repeat_at = None;
        self.repeat_cadence = Duration::ZERO;
        if keep_hint {
            return;
        }
        self.mode = None;
        self.watch_at = None;
        self.on_watchdog = None;
        self.schedule(engine);
        if self.notified {
            self.notified = false;
            self.hide_hint(engine);
        }
    }

    /// Quits once the key has gone quiet, so its repeats cannot reach the
    /// next app. A slow repeat rate waits for two of its cadences.
    fn quit_after_quiet_period(&mut self, engine: &Engine) {
        let wait = RELEASE_GRACE.max(self.repeat_cadence * 2);
        self.watch(engine, wait, Then::Quit);
    }

    fn watch(&mut self, engine: &Engine, after: Duration, then: Then) {
        self.on_watchdog = Some(then);
        self.watch_at = Some(engine.now() + after);
        self.schedule(engine);
    }

    /// Runs what the clock says is due: a hold given up, a quiet period
    /// over, a hint gone.
    fn poll(&mut self, engine: &Engine) {
        let now = engine.now();
        if self.watch_at.is_some_and(|at| at <= now) {
            self.watch_at = None;
            match self.on_watchdog.take() {
                Some(Then::Release) => self.release(engine, false),
                Some(Then::Quit) => self.quit(engine),
                None => {}
            }
        }
        if self.linger_at.is_some_and(|at| at <= now) {
            self.linger_at = None;
            self.hint.clear();
            self.publish(engine);
        }
        self.schedule(engine);
    }

    /// One call at the nearest deadline wakes [`Self::poll`].
    fn schedule(&mut self, engine: &Engine) {
        if let Some(timer) = self.timer.take() {
            engine.cancel_call(timer);
        }
        let Some(next) = self.watch_at.into_iter().chain(self.linger_at).min() else {
            return;
        };
        let me = self.me.clone();
        self.timer = Some(engine.call_at(next, move |engine| {
            me.run(engine, |quit, engine| {
                quit.timer = None;
                quit.poll(engine);
            });
        }));
    }

    fn show_hint(&mut self, engine: &Engine, mode: Mode) {
        self.linger_at = None;
        self.schedule(engine);
        self.hint_mode = Some(mode);
        let shortcut = Keymap::of(engine).key_label("mod+q");
        self.hint = if mode == Mode::Hold {
            format!("Hold {shortcut} or press twice to quit")
        } else {
            format!("Press {shortcut} again to quit")
        };
        self.publish(engine);
    }

    /// A double press's hint goes with its window; a hold's lingers.
    fn hide_hint(&mut self, engine: &Engine) {
        if self.hint_mode == Some(Mode::DoublePress) {
            self.hint.clear();
            self.publish(engine);
        } else {
            self.linger_at = Some(engine.now() + HINT_LINGER);
            self.schedule(engine);
        }
    }

    fn publish(&self, engine: &Engine) {
        let hint = if self.hint.is_empty() {
            Json::Null
        } else {
            json!({ "message": self.hint })
        };
        self.bridge.publish(engine, "quitHint", hint);
    }
}
