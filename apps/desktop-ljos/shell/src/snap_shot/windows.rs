//! Windows capture: desktop-qt's WindowsSnapShot over its WindowsSystem.
//!
//! "Direct" capture with no setup: the shortcut held by the system (a chord
//! as a hot key, a modifier pair through the keyboard hook) and the window
//! in front grabbed off the screen at its bounds, shrunk to 2560x1600, with
//! Windows' flash and flight as the cues. What Windows says on its own (the
//! shortcut pressed, a grab done) is posted to an [`Inbox`] and handed over
//! in [`Backend::arrive`]. Tests stand in for Windows with [`set_factory`]
//! and OS=Windows_NT in [`super::set_environment`].

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use image::RgbaImage;

use super::mac::{MAX_HEIGHT, MAX_WIDTH, Rect, fit};
use super::{Backend, Captured, Check, Event, Json, Mode, Session, Shortcut, Unavailable};

pub const COULD_NOT_CAPTURE: &str = "Could not capture the active window.";
pub const NO_WINDOW: &str = "The active window is not available for capture.";
const TAKEN: &str = "This shortcut is already used by the system or another app.";

/// How long a capture waits for the picture; 15 s, as upstream.
pub const CAPTURE_TIMEOUT_MS: u64 = 15_000;
const DEADLINE: u64 = 1;

// RegisterHotKey's modifiers (WinUser.h).
const MOD_ALT: u32 = 0x0001;
const MOD_CONTROL: u32 = 0x0002;
const MOD_SHIFT: u32 = 0x0004;
const MOD_WIN: u32 = 0x0008;
const MOD_NOREPEAT: u32 = 0x4000;

/// The window in front: its HWND, title, bounds on the screen (physical
/// pixels) and the path of the program that owns it (empty when unknown).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Window {
    pub id: u64,
    pub title: String,
    pub bounds: Rect,
    pub program: String,
}

/// What a grab of the screen gave: the picture now, a failure now, or
/// [`Signal::Grabbed`] / [`Signal::GrabFailed`] later.
pub enum Grab {
    Now(RgbaImage),
    Failed,
    Later,
}

/// What Windows says on its own, from any thread.
#[derive(Debug)]
pub enum Signal {
    /// The capture shortcut was pressed.
    Pressed,
    /// The keyboard hook stopped.
    WatchLost,
    /// A grab left for later finished; none is a null picture.
    Grabbed(Option<RgbaImage>),
    GrabFailed,
}

/// Where a system posts its [`Signal`]s; it wakes the Engine thread.
#[derive(Clone)]
pub struct Inbox {
    signals: Arc<Mutex<Vec<Signal>>>,
    wake: Option<Arc<dyn Fn() + Send + Sync>>,
}

impl Inbox {
    fn new() -> Inbox {
        Inbox {
            signals: Arc::default(),
            wake: super::wake(),
        }
    }

    pub fn post(&self, signal: Signal) {
        if let Ok(mut signals) = self.signals.lock() {
            signals.push(signal);
        }
        if let Some(wake) = &self.wake {
            wake();
        }
    }

    fn take(&self) -> Vec<Signal> {
        self.signals
            .lock()
            .map(|mut signals| std::mem::take(&mut *signals))
            .unwrap_or_default()
    }
}

/// What WindowsSnapShot needs from Windows (WindowsSystem.cpp on Windows).
pub trait WindowsSystem {
    fn foreground(&mut self) -> Option<Window>;
    /// Takes a picture of `bounds` on the screen. `grabbing` holds until it
    /// answers, even after a cancel.
    fn grab(&mut self, bounds: Rect) -> Grab;
    fn grabbing(&self) -> bool;
    /// The caller stopped waiting; a late answer is dropped.
    fn cancel_grab(&mut self);
    /// A key chord as a system hot key (RegisterHotKey): MOD_* flags and a
    /// virtual key. One at a time.
    fn hold_hot_key(&mut self, modifiers: u32, key: u32) -> bool;
    fn release_hot_key(&mut self);
    /// Whether `hold_hot_key` would take it now, without keeping it.
    fn can_hold_hot_key(&mut self, modifiers: u32, key: u32) -> bool;
    /// Both keys of a modifier, by their left and right virtual keys,
    /// through a low-level keyboard hook.
    fn watch_pair(&mut self, left: u32, right: u32) -> bool;
    fn stop_watching(&mut self);
    fn can_watch_pair(&mut self, left: u32, right: u32) -> bool;
    /// Windows' "Animate controls and elements inside windows".
    fn animations_enabled(&self) -> bool;
    /// A brief white flash over `bounds`, fading when `animated`.
    fn flash(&mut self, bounds: Rect, animated: bool);
    /// The captured image flying from `bounds` into HAL-C2, flashing first
    /// when `flash`.
    fn fly(&mut self, image: &RgbaImage, bounds: Rect, flash: bool);
    /// A flash or flight is on the screen, where the next capture would see it.
    fn cue_showing(&self) -> bool;
    /// Plays a capture sound.
    fn play(&mut self, sound: &str) {
        super::play_sound(None, sound);
    }
}

/// What a test gives instead of Windows: the system, posting to the inbox
/// it is handed; none once the test it stands in for is over.
pub type Factory = Rc<dyn Fn(Inbox) -> Option<Box<dyn WindowsSystem>>>;

thread_local! {
    static FACTORY: RefCell<Option<Factory>> = const { RefCell::new(None) };
}

/// Tests stand in for Windows (setWindowsFactory); `None` restores it.
pub fn set_factory(factory: Option<Factory>) {
    FACTORY.with(|held| *held.borrow_mut() = factory);
}

/// Whether a test stands in for Windows.
pub fn overridden() -> bool {
    FACTORY.with(|held| held.borrow().is_some())
}

/// WindowsSnapShot on Windows, or where a test's stand-in environment says
/// OS=Windows_NT; there without a system, the reason it cannot capture.
pub fn create() -> Option<Box<dyn Backend>> {
    let stand_in =
        super::environment_overridden() && super::env_var("OS").as_deref() == Some("Windows_NT");
    if !cfg!(windows) && !stand_in {
        return None;
    }
    let inbox = Inbox::new();
    let factory = FACTORY.with(|held| held.borrow().clone());
    let system = match factory {
        Some(factory) => factory(inbox.clone()),
        None => native::system(inbox.clone()),
    };
    Some(match system {
        Some(system) => Box::new(WindowsSnapShot::new(system, inbox)),
        None => Box::new(Unavailable::new(
            "SnapShots are not supported on this platform.",
        )),
    })
}

mod native {
    use super::{Inbox, WindowsSystem};

    // TODO(port): WindowsSystem.cpp (GetForegroundWindow, the screen grab,
    // RegisterHotKey, the low-level keyboard hook, the flash and flight
    // windows). Until then Windows captures nothing.
    pub fn system(_inbox: Inbox) -> Option<Box<dyn WindowsSystem>> {
        None
    }
}

fn is_pair(shortcut: &Json) -> bool {
    shortcut.get("kind").is_some()
}

fn flag(shortcut: &Json, name: &str) -> bool {
    shortcut.get(name).and_then(Json::as_bool).unwrap_or(false)
}

fn pair_modifier(shortcut: &Json) -> String {
    match shortcut.get("kind").and_then(Json::as_str) {
        Some("both-shift-keys") => "shift".into(),
        _ => shortcut
            .get("modifier")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned(),
    }
}

fn pair_label(modifier: &str) -> String {
    let name = match modifier {
        "meta" => "Super",
        "control" => "Ctrl",
        "alt" => "Alt",
        _ => "Shift",
    };
    format!("{name} + {name}")
}

/// A chord's RegisterHotKey arguments (MOD_* | MOD_NOREPEAT, VK_*); none
/// for a key Windows has no virtual key for.
pub fn hot_key(chord: &Json) -> Option<(u32, u32)> {
    let key = chord
        .get("key")
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_lowercase();
    let named = match key.as_str() {
        " " | "space" => 0x20,
        "escape" | "esc" => 0x1B,
        "enter" => 0x0D,
        "tab" => 0x09,
        "backspace" => 0x08,
        "delete" => 0x2E,
        "insert" => 0x2D,
        "home" => 0x24,
        "end" => 0x23,
        "pageup" => 0x21,
        "pagedown" => 0x22,
        "arrowleft" | "left" => 0x25,
        "arrowup" | "up" => 0x26,
        "arrowright" | "right" => 0x27,
        "arrowdown" | "down" => 0x28,
        ";" => 0xBA,
        "=" => 0xBB,
        "," => 0xBC,
        "-" => 0xBD,
        "." => 0xBE,
        "/" => 0xBF,
        "`" => 0xC0,
        "[" => 0xDB,
        "\\" => 0xDC,
        "]" => 0xDD,
        "'" => 0xDE,
        _ => 0,
    };
    let mut chars = key.chars();
    let vk = match (named, chars.next(), chars.next()) {
        (0, Some(c), None) if c.is_ascii_lowercase() || c.is_ascii_digit() => {
            u32::from(c.to_ascii_uppercase())
        }
        (0, _, _) => key
            .strip_prefix('f')
            .and_then(|n| n.parse::<u32>().ok())
            .filter(|n| (1..=24).contains(n) && !key[1..].starts_with('0'))
            .map_or(0, |n| 0x70 + n - 1),
        (vk, _, _) => vk,
    };
    if vk == 0 {
        return None;
    }
    let mut modifiers = MOD_NOREPEAT;
    if flag(chord, "ctrlKey") || flag(chord, "modKey") {
        modifiers |= MOD_CONTROL;
    }
    if flag(chord, "altKey") {
        modifiers |= MOD_ALT;
    }
    if flag(chord, "shiftKey") {
        modifiers |= MOD_SHIFT;
    }
    if flag(chord, "metaKey") {
        modifiers |= MOD_WIN;
    }
    Some((modifiers, vk))
}

/// The left and right virtual keys of a modifier: shift, control, alt, meta.
pub fn pair_keys(modifier: &str) -> Option<(u32, u32)> {
    match modifier {
        "shift" => Some((0xA0, 0xA1)),
        "control" => Some((0xA2, 0xA3)),
        "alt" => Some((0xA4, 0xA5)),
        "meta" => Some((0x5B, 0x5C)),
        _ => None,
    }
}

/// What a capture's attachment calls the program at `path`: "Code" for
/// C:\...\Code.exe, "Window" with none.
pub fn app_name(path: &str) -> String {
    let path = path.replace('\\', "/");
    let name = path.rsplit('/').next().unwrap_or_default().trim();
    let bare = if name.len() >= 4 && name[name.len() - 4..].eq_ignore_ascii_case(".exe") {
        name[..name.len() - 4].trim()
    } else {
        name
    };
    if !bare.is_empty() {
        bare.to_owned()
    } else if name.is_empty() {
        "Window".into()
    } else {
        name.to_owned()
    }
}

/// "Super + Super is observed and cannot be reserved exclusively. ..."
pub fn observed_message(modifier: &str) -> String {
    let mut message = format!(
        "{} is observed and cannot be reserved exclusively.",
        pair_label(modifier)
    );
    match modifier {
        "meta" => message.push_str(" This key can also open the system's own menu."),
        "alt" => message.push_str(" This key can also activate app menu bars."),
        _ => {}
    }
    message
}

pub fn unavailable_message(modifier: &str) -> String {
    format!("{} is not available on this system.", pair_label(modifier))
}

fn unheld() -> Shortcut {
    Shortcut {
        can_retry: false,
        ..Shortcut::default()
    }
}

/// desktop-qt's WindowsSnapShot.
pub struct WindowsSnapShot {
    system: Box<dyn WindowsSystem>,
    inbox: Inbox,
    shortcut: Shortcut,
    /// The shortcut held, as `trigger` gave it.
    bound: String,
    flash: bool,
    animations: bool,
    capturing: bool,
    window: Window,
}

impl WindowsSnapShot {
    pub fn new(system: Box<dyn WindowsSystem>, inbox: Inbox) -> WindowsSnapShot {
        WindowsSnapShot {
            system,
            inbox,
            shortcut: unheld(),
            bound: String::new(),
            flash: true,
            animations: true,
            capturing: false,
            window: Window::default(),
        }
    }

    pub fn capturing(&self) -> bool {
        self.capturing
    }

    fn held(&self) -> Json {
        serde_json::from_str(&self.bound).unwrap_or(Json::Null)
    }

    fn fail(&mut self, message: &str) -> Vec<Event> {
        let mut events = Vec::new();
        if self.capturing {
            events.push(Event::Cancel(DEADLINE));
        }
        self.capturing = false;
        events.push(Event::Failed(message.into()));
        events
    }

    fn grabbed(&mut self, grabbed: Option<RgbaImage>) -> Vec<Event> {
        if !self.capturing {
            return Vec::new();
        }
        self.capturing = false;
        let mut events = vec![Event::Cancel(DEADLINE)];
        let Some(image) = grabbed.filter(|image| image.width() > 0 && image.height() > 0) else {
            events.push(Event::Failed(COULD_NOT_CAPTURE.into()));
            return events;
        };
        let image = fit(image, MAX_WIDTH, MAX_HEIGHT);
        // The flight carries the flash when it runs; without it, a still flash.
        if self.animations && self.system.animations_enabled() {
            self.system.fly(&image, self.window.bounds, self.flash);
        } else if self.flash {
            self.system.flash(self.window.bounds, false);
        }
        events.push(Event::Captured(Captured {
            image,
            app_name: app_name(&self.window.program),
            window_title: self.window.title.clone(),
            context: Json::Null,
        }));
        events
    }

    fn signal(&mut self, signal: Signal) -> Vec<Event> {
        match signal {
            Signal::Pressed => vec![Event::Activated],
            Signal::WatchLost => {
                let held = self.held();
                if !is_pair(&held) {
                    return Vec::new();
                }
                self.system.stop_watching();
                self.shortcut = Shortcut {
                    message: unavailable_message(&pair_modifier(&held)),
                    ..unheld()
                };
                vec![Event::Changed]
            }
            Signal::Grabbed(image) => self.grabbed(image),
            Signal::GrabFailed => {
                if self.capturing {
                    self.fail(COULD_NOT_CAPTURE)
                } else {
                    Vec::new()
                }
            }
        }
    }
}

impl Drop for WindowsSnapShot {
    fn drop(&mut self) {
        self.system.release_hot_key();
        self.system.stop_watching();
        if self.capturing {
            self.system.cancel_grab();
        }
    }
}

impl Backend for WindowsSnapShot {
    fn session(&self) -> Session {
        Session {
            ready: true,
            mode: Mode::Direct,
            feedback_available: true,
            setup_free: true,
            ..Session::default()
        }
    }

    fn shortcut(&self) -> Shortcut {
        self.shortcut.clone()
    }

    fn trigger(&self, shortcut: &Json) -> Result<String, String> {
        let mut held = serde_json::Map::new();
        if is_pair(shortcut) {
            let modifier = pair_modifier(shortcut);
            if pair_keys(&modifier).is_none() {
                return Err(unavailable_message(&modifier));
            }
            held.insert("kind".into(), "modifier-pair".into());
            held.insert("modifier".into(), modifier.into());
        } else {
            if hot_key(shortcut).is_none() {
                return Err("The system could not register this shortcut.".into());
            }
            for name in ["metaKey", "ctrlKey", "shiftKey", "altKey", "modKey"] {
                held.insert(
                    name.into(),
                    shortcut.get(name).cloned().unwrap_or(Json::Null),
                );
            }
            let key = shortcut
                .get("key")
                .and_then(Json::as_str)
                .unwrap_or_default();
            held.insert("key".into(), key.to_lowercase().into());
        }
        Ok(Json::Object(held).to_string())
    }

    fn check_shortcut(&mut self, shortcut: &Json) -> Option<Check> {
        let wanted = match self.trigger(shortcut) {
            Ok(wanted) => wanted,
            Err(problem) => {
                return Some(Check {
                    available: false,
                    message: problem,
                });
            }
        };
        // The one already held is free to keep; asking Windows again would refuse it.
        let held = wanted == self.bound && self.shortcut.registered;
        if is_pair(shortcut) {
            let modifier = pair_modifier(shortcut);
            let (left, right) = pair_keys(&modifier)?;
            let available = held || self.system.can_watch_pair(left, right);
            return Some(Check {
                available,
                message: if available {
                    observed_message(&modifier)
                } else {
                    unavailable_message(&modifier)
                },
            });
        }
        let (modifiers, key) = hot_key(shortcut)?;
        Some(if held || self.system.can_hold_hot_key(modifiers, key) {
            Check {
                available: true,
                message: String::new(),
            }
        } else {
            Check {
                available: false,
                message: TAKEN.into(),
            }
        })
    }

    fn bind(&mut self, trigger: &str) -> Vec<Event> {
        self.system.release_hot_key();
        self.system.stop_watching();
        self.bound = trigger.to_owned();
        self.shortcut = unheld();
        let held = self.held();
        if is_pair(&held) {
            let modifier = pair_modifier(&held);
            let registered = pair_keys(&modifier)
                .is_some_and(|(left, right)| self.system.watch_pair(left, right));
            self.shortcut.registered = registered;
            self.shortcut.message = if registered {
                observed_message(&modifier)
            } else {
                unavailable_message(&modifier)
            };
        } else {
            let registered = hot_key(&held)
                .is_some_and(|(modifiers, key)| self.system.hold_hot_key(modifiers, key));
            self.shortcut.registered = registered;
            if !registered {
                self.shortcut.message = TAKEN.into();
            }
        }
        vec![Event::Changed]
    }

    fn release(&mut self) -> Vec<Event> {
        self.system.release_hot_key();
        self.system.stop_watching();
        self.bound.clear();
        self.shortcut = unheld();
        vec![Event::Changed]
    }

    fn set_cues(&mut self, flash: bool, animations: bool) {
        self.flash = flash;
        self.animations = animations;
    }

    fn set_effects(&mut self, flash: bool, animate: bool) {
        self.set_cues(flash, animate);
    }

    /// A second press while one is being taken or its cue still shows is
    /// ignored; a grab still running from before (one that timed out) fails
    /// this one rather than queue behind it.
    fn capture(&mut self) -> Vec<Event> {
        if self.capturing || self.system.cue_showing() {
            return Vec::new();
        }
        let Some(window) = self.system.foreground().filter(|w| !w.bounds.is_empty()) else {
            return vec![Event::Failed(NO_WINDOW.into())];
        };
        if self.system.grabbing() {
            return vec![Event::Failed(COULD_NOT_CAPTURE.into())];
        }
        self.capturing = true;
        self.window = window;
        match self.system.grab(self.window.bounds) {
            Grab::Now(image) => self.grabbed(Some(image)),
            Grab::Failed => self.fail(COULD_NOT_CAPTURE),
            Grab::Later => vec![Event::After {
                token: DEADLINE,
                ms: CAPTURE_TIMEOUT_MS,
            }],
        }
    }

    fn play(&mut self, sound: &str) {
        self.system.play(sound);
    }

    fn arrive(&mut self) -> Vec<Event> {
        let mut events = Vec::new();
        for signal in self.inbox.take() {
            events.extend(self.signal(signal));
        }
        events
    }

    /// The capture's deadline passed.
    fn timeout(&mut self, token: u64) -> Vec<Event> {
        if token != DEADLINE || !self.capturing {
            return Vec::new();
        }
        self.system.cancel_grab();
        self.capturing = false;
        vec![Event::Failed(COULD_NOT_CAPTURE.into())]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chord(key: &str) -> Json {
        serde_json::json!({"key": key, "ctrlKey": true, "shiftKey": true})
    }

    #[test]
    fn a_chord_becomes_a_hot_key() {
        assert_eq!(
            hot_key(&chord("2")),
            Some((MOD_NOREPEAT | MOD_CONTROL | MOD_SHIFT, 0x32))
        );
        assert_eq!(hot_key(&chord("F12")).map(|k| k.1), Some(0x7B));
        assert_eq!(hot_key(&chord("ArrowUp")).map(|k| k.1), Some(0x26));
        assert_eq!(hot_key(&chord("f25")), None);
        assert_eq!(hot_key(&chord("é")), None);
    }

    #[test]
    fn the_program_names_the_attachment() {
        assert_eq!(app_name("C:\\Program Files\\Code\\Code.exe"), "Code");
        assert_eq!(app_name("C:\\Tools\\Terminal.EXE"), "Terminal");
        assert_eq!(app_name(""), "Window");
    }

    #[test]
    fn menu_keys_say_what_else_they_do() {
        assert_eq!(
            observed_message("meta"),
            "Super + Super is observed and cannot be reserved exclusively. \
             This key can also open the system's own menu."
        );
        assert_eq!(
            unavailable_message("alt"),
            "Alt + Alt is not available on this system."
        );
    }
}
