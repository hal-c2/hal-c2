//! `snapShot`, desktop-qt's SnapShotController: capturing a window and
//! attaching the picture to the composer, and the settings page and setup
//! wizard around it (features/source-control/snap-shot.feature,
//! features/settings/snap-shot.feature).
//!
//! What the desktop can do is the [`Backend`]'s ([`crate::snap_shot`]); this
//! controller decides what to ask it from the settings (capture is opt-in,
//! the shortcut is bound only while it is on) and where a capture goes (the
//! thread or draft the window last showed, else a new draft).
//!
//! Publishes `snapShot`: the page's state, `{ready, available, mode,
//! backend, desktop, enabled, switchOn, status, description, setupLabel,
//! rows, shortcut{...}, accessibility, sound, flash, animations, wizard}`
//! (see [`SnapShot::state`]); `wizard` is null unless setup is open.
//!
//! Actions: `snapShot.enable{on}`, `snapShot.setup.{open{step},continue,back,
//! close{completed},done}`, `snapShot.record.{start,cancel,key{key,modifiers},
//! modifier{modifier,code,down}}`, `snapShot.shortcut.{save,discard,
//! permissions}`, `snapShot.set{key,value}`, `snapShot.sound{value}` and
//! `snapShot.sound.play{sound}`. All of them are this controller's, even when
//! there is nothing to do.

use std::collections::{BTreeSet, HashMap, VecDeque};
use std::time::Duration;

use chrono::{DateTime, SecondsFormat};
use ljos::prelude::{Engine, TimerId};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::composer;
use crate::controllers::drafts;
use crate::controllers::keybindings::Keymap;
use crate::controllers::navigation::{self, Route};
use crate::controllers::settings::Settings;
use crate::controllers::sidebar;
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::keybindings::{self as keymap, Shortcut as Chord, command_label, qt};
use crate::snap_shot::{self, Backend, Captured, Event, Mode, Unavailable};
use crate::store;
use crate::thread_view::summary::Obj;

/// The settings section that shows the page.
const SECTION: &str = "/settings/snap-shot";
const ACCESS: &str = "access";
const SHORTCUT: &str = "shortcut";
/// What a capture may weigh once attached (the contracts' image limit).
const MAX_IMAGE_BYTES: u64 = 10 * 1024 * 1024;

/// Whether a shortcut can be saved, and why not.
#[derive(Clone, Debug)]
struct Check {
    available: bool,
    message: String,
}

/// The setup wizard: where it is, and whether capture was on before it
/// opened (closing it unfinished turns capture off again if it was not).
#[derive(Clone, Debug)]
struct Wizard {
    step: &'static str,
    was_enabled: bool,
}

pub struct SnapShot {
    bridge: Bridge,
    me: Me<SnapShot>,
    backend: Box<dyn Backend>,
    active: bool,
    /// What the portal is bound to now; empty when it is released.
    bound: String,
    shortcut_problem: String,
    wizard: Option<Wizard>,
    recording: bool,
    /// The modifier keys down while recording, as "modifier:code".
    held: BTreeSet<String>,
    candidate: Option<Json>,
    check: Option<Check>,
    /// The thread or draft the window last showed.
    last_target: String,
    /// What the backend asked to be called back about, by its token.
    timers: HashMap<u64, TimerId>,
    max_image_bytes: u64,
}

/// Runs `f` on the controller once no controller is running: what a
/// settings or route change sets off while this one is.
fn later(engine: &Engine, me: &Me<SnapShot>, f: impl FnOnce(&mut SnapShot, &Engine) + 'static) {
    let me = me.clone();
    Bridge::of(engine).defer(engine, move |engine| me.run(engine, f));
}

/// Hands the controller what the backend's threads left. On the Engine
/// thread, when main.rs is woken.
pub fn deliver(engine: &Engine) {
    controller::with::<SnapShot, _>(engine, |c, e| c.arrive(e));
}

fn is_pair(shortcut: &Json) -> bool {
    shortcut.get("kind").is_some()
}

/// The modifier a pair is made of, as the recorder names it.
fn pair_modifier(shortcut: &Json) -> String {
    let text = |key: &str| {
        shortcut
            .get(key)
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    if text("kind") == "both-shift-keys" {
        "shift".to_owned()
    } else {
        text("modifier")
    }
}

fn chord_of(shortcut: &Json) -> Chord {
    let on = |key: &str| shortcut.get(key).and_then(Json::as_bool).unwrap_or(false);
    Chord {
        key: shortcut
            .get("key")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned(),
        meta: on("metaKey"),
        ctrl: on("ctrlKey"),
        shift: on("shiftKey"),
        alt: on("altKey"),
        mod_: on("modKey"),
    }
}

fn json_of(chord: &Chord) -> Json {
    json!({"key": chord.key, "metaKey": chord.meta, "ctrlKey": chord.ctrl,
        "shiftKey": chord.shift, "altKey": chord.alt, "modKey": chord.mod_})
}

/// What two chords share when they are the same key: `key|meta|ctrl|shift|alt`
/// with `mod` as the platform's.
fn conflict_key(chord: &Chord, mac: bool) -> String {
    let meta = chord.meta || (mac && chord.mod_);
    let ctrl = chord.ctrl || (!mac && chord.mod_);
    format!(
        "{}|{}|{}|{}|{}",
        chord.key.to_lowercase(),
        u8::from(meta),
        u8::from(ctrl),
        u8::from(chord.shift),
        u8::from(chord.alt)
    )
}

/// The system shortcut a chord collides with, if any: only a lone modifier
/// is judged, as the web's checkShortcut does.
fn system_conflict(chord: &Chord) -> String {
    let modifiers = [chord.mod_, chord.meta, chord.ctrl, chord.alt, chord.shift]
        .into_iter()
        .filter(|on| *on)
        .count();
    if modifiers != 1 {
        return String::new();
    }
    if chord.shift {
        return "Shift combinations are used for typing and text selection. Add another modifier."
            .into();
    }
    let key = chord.key.to_lowercase();
    if chord.mod_ {
        let action = match key.as_str() {
            "a" => "Select All",
            "c" => "Copy",
            "f" => "Find",
            "n" => "New",
            "o" => "Open",
            "p" => "Print",
            "q" => "Quit",
            "s" => "Save",
            "t" => "New Tab",
            "v" => "Paste",
            "w" => "Close Window",
            "x" => "Cut",
            "z" => "Undo",
            _ => return String::new(),
        };
        return format!("This shortcut is {action} in most apps.");
    }
    if chord.ctrl && matches!(key.as_str(), "c" | "d" | "z") {
        return "This shortcut controls running commands in terminals.".into();
    }
    if chord.alt && key == "tab" {
        return "The system uses Alt+Tab to switch apps.".into();
    }
    if chord.meta && matches!(key.as_str(), "l" | " " | "space") {
        return "The system already uses this shortcut.".into();
    }
    String::new()
}

fn desktop_name(desktop: &str) -> &'static str {
    match desktop {
        "gnome" => "GNOME",
        "kde" => "KDE Plasma",
        "niri" => "Niri",
        "hyprland" => "Hyprland",
        _ => "",
    }
}

fn int(payload: &Json, key: &str) -> i32 {
    let value = payload.get(key);
    value
        .and_then(Json::as_i64)
        .or_else(|| value.and_then(Json::as_f64).map(|f| f as i64))
        .map_or(0, |n| i32::try_from(n).unwrap_or(0))
}

fn text(payload: &Json, key: &str) -> String {
    payload
        .get(key)
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn flag(payload: &Json, key: &str) -> bool {
    payload.get(key).and_then(Json::as_bool).unwrap_or(false)
}

impl SnapShot {
    /// Replaces the backend: main.rs gives the platform's once the shell
    /// runs, and tests a fake. The shortcut the old one held is let go.
    pub fn set_backend(&mut self, engine: &Engine, backend: Box<dyn Backend>) {
        let events = self.backend.release();
        self.apply(engine, events);
        for (_, timer) in self.timers.drain() {
            engine.cancel_call(timer);
        }
        self.backend = backend;
        self.bound.clear();
        self.follow(engine);
    }

    /// Takes what the backend's own threads left, and acts on it.
    pub fn arrive(&mut self, engine: &Engine) {
        let events = self.backend.arrive();
        self.apply(engine, events);
    }

    /// The most a captured picture may weigh once attached.
    pub fn set_max_image_bytes(&mut self, bytes: u64) {
        self.max_image_bytes = bytes;
    }

    // --- Settings ---------------------------------------------------------------

    fn setting(&self, engine: &Engine, key: &str) -> Json {
        Settings::of(engine)
            .setting(engine, key)
            .unwrap_or(Json::Null)
    }

    fn set(&self, engine: &Engine, key: &str, value: Json) {
        Settings::of(engine).set(engine, key, value);
    }

    fn enabled(&self, engine: &Engine) -> bool {
        self.setting(engine, "snapShotEnabled")
            .as_bool()
            .unwrap_or(false)
    }

    fn saved_shortcut(&self, engine: &Engine) -> Json {
        match self.setting(engine, "snapShotShortcut") {
            shortcut @ Json::Object(_) => shortcut,
            _ => json!({}),
        }
    }

    fn mac(&self, engine: &Engine) -> bool {
        Keymap::of(engine).mac()
    }

    fn access_ready(&self) -> bool {
        let session = self.backend.session();
        session.mode != Mode::Unavailable && session.message.is_empty()
    }

    fn panel_open(&self, engine: &Engine) -> bool {
        navigation::shown(engine) == Route::Settings(SECTION.to_owned())
    }

    // --- Following the settings -------------------------------------------------

    /// Notes where the window is, for a capture to attach to.
    fn note_route(&mut self, engine: &Engine) {
        match navigation::shown(engine) {
            Route::Thread(key) | Route::Draft(key) => self.last_target = key,
            _ => {}
        }
    }

    /// Asks the desktop what it offers while capture is wanted or its page
    /// is open, binds or releases the shortcut to match, and shows it.
    fn follow(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        if self.enabled(engine) || self.panel_open(engine) {
            let events = self.backend.probe();
            self.apply(engine, events);
        }
        self.apply_shortcut(engine);
        self.publish(engine);
    }

    fn apply_shortcut(&mut self, engine: &Engine) {
        let mut trigger = String::new();
        let mut problem = String::new();
        if self.enabled(engine) && self.backend.session().mode == Mode::Portal {
            match snap_shot::portal_trigger(&self.saved_shortcut(engine)) {
                Ok(found) => trigger = found,
                Err(why) => problem = why,
            }
        }
        self.shortcut_problem = problem;
        if trigger == self.bound {
            return;
        }
        self.bound = trigger.clone();
        let events = if trigger.is_empty() {
            self.backend.release()
        } else {
            self.backend.bind(&trigger)
        };
        self.apply(engine, events);
    }

    // --- Setup ------------------------------------------------------------------

    fn initial_step(&self, requested: &str) -> &'static str {
        if !self.access_ready() {
            return ACCESS;
        }
        match requested {
            ACCESS => ACCESS,
            SHORTCUT => SHORTCUT,
            _ if self.backend.session().backend == "picker" => ACCESS,
            _ => SHORTCUT,
        }
    }

    fn open_setup(&mut self, engine: &Engine, requested: &str) {
        if !self.backend.session().ready {
            return;
        }
        self.stop_recording();
        self.reset_candidate();
        let was_enabled = self.enabled(engine);
        let step = self.initial_step(requested);
        // Opening setup is the opt-in.
        if !was_enabled && step != ACCESS {
            self.set(engine, "snapShotEnabled", json!(true));
        }
        self.wizard = Some(Wizard { step, was_enabled });
        self.publish(engine);
    }

    fn close_setup(&mut self, engine: &Engine, completed: bool) {
        let Some(wizard) = self.wizard.take() else {
            return;
        };
        self.stop_recording();
        if self.enabled(engine) && !wizard.was_enabled && !completed {
            self.set(engine, "snapShotEnabled", json!(false));
        }
        self.publish(engine);
    }

    fn stop_recording(&mut self) {
        self.recording = false;
        self.held.clear();
    }

    fn reset_candidate(&mut self) {
        self.candidate = None;
        self.check = None;
    }

    // --- The shortcut -----------------------------------------------------------

    /// How the shortcut reads: "Shift + Shift", or "Ctrl+Shift+2".
    fn label(&self, engine: &Engine, shortcut: &Json) -> String {
        if is_pair(shortcut) {
            let apple = self.mac(engine);
            let name = match pair_modifier(shortcut).as_str() {
                "meta" if apple => "Command",
                "meta" => "Super",
                "control" if apple => "Control",
                "control" => "Ctrl",
                "alt" if apple => "Option",
                "alt" => "Alt",
                _ => "Shift",
            };
            return format!("{name} + {name}");
        }
        keymap::label(&chord_of(shortcut), self.mac(engine))
    }

    /// The command HAL-C2 already runs on `shortcut`, or empty.
    fn conflict(&self, engine: &Engine, shortcut: &Json) -> String {
        if is_pair(shortcut) {
            return String::new();
        }
        let keys = Keymap::of(engine);
        let mac = keys.mac();
        let key = conflict_key(&chord_of(shortcut), mac);
        keys.bindings()
            .into_iter()
            .find(|binding| conflict_key(&binding.shortcut, mac) == key)
            .map(|binding| binding.command)
            .unwrap_or_default()
    }

    /// DesktopSnapShot.checkShortcut: whether the desktop can take it.
    fn check(&self, shortcut: &Json) -> Check {
        if self.backend.session().mode != Mode::Portal {
            return Check {
                available: false,
                message: "SnapShots are not supported on this platform.".into(),
            };
        }
        if !is_pair(shortcut) {
            let reserved = system_conflict(&chord_of(shortcut));
            if !reserved.is_empty() {
                return Check {
                    available: false,
                    message: reserved,
                };
            }
        }
        match snap_shot::portal_trigger(shortcut) {
            Err(problem) => Check {
                available: false,
                message: problem,
            },
            Ok(_) => Check {
                available: true,
                message: "Your desktop will confirm this shortcut when you save it.".into(),
            },
        }
    }

    fn record(&mut self, engine: &Engine, shortcut: Json) {
        self.stop_recording();
        self.check = None;
        let changed = shortcut != self.saved_shortcut(engine);
        self.candidate = Some(shortcut.clone());
        if changed && self.conflict(engine, &shortcut).is_empty() {
            self.check = Some(self.check(&shortcut));
        }
        self.publish(engine);
    }

    fn shortcut_changed(&self, engine: &Engine) -> bool {
        self.candidate
            .as_ref()
            .is_some_and(|candidate| *candidate != self.saved_shortcut(engine))
    }

    fn can_save(&self, engine: &Engine) -> bool {
        let Some(candidate) = &self.candidate else {
            return false;
        };
        self.shortcut_changed(engine)
            && self.conflict(engine, candidate).is_empty()
            && self.check.as_ref().is_some_and(|c| c.available)
    }

    /// The line under the shortcut: what to do next, or what is wrong.
    fn shortcut_status(&self, engine: &Engine) -> String {
        // A refused modifier pair shows here while recording, where the
        // user can see why nothing was recorded.
        if self.recording {
            return self.check.as_ref().map_or_else(
                || "Press your shortcut. Esc cancels.".to_owned(),
                |c| c.message.clone(),
            );
        }
        let changed = self.shortcut_changed(engine);
        if changed && let Some(candidate) = &self.candidate {
            let command = self.conflict(engine, candidate);
            if !command.is_empty() {
                return format!(
                    "HAL-C2 already uses this for \"{}\".",
                    command_label(&command)
                );
            }
        }
        if let Some(check) = &self.check {
            return if check.available {
                "Ready to save.".to_owned()
            } else {
                check.message.clone()
            };
        }
        let session = self.backend.session();
        let shortcut = self.backend.shortcut();
        let display = self.display_shortcut(engine);
        if session.mode == Mode::Portal && shortcut.label.is_empty() && is_pair(&display) {
            return "Try a shortcut such as Ctrl+Shift+2.".into();
        }
        if !self.shortcut_problem.is_empty() {
            return self.shortcut_problem.clone();
        }
        if shortcut.pending {
            return "Approve the shortcut permission prompt to continue.".into();
        }
        if shortcut.registered {
            return if session.mode == Mode::Portal {
                String::new()
            } else {
                "Shortcut saved.".into()
            };
        }
        shortcut.message
    }

    /// The shortcut the page shows: the one being chosen, else the saved.
    fn display_shortcut(&self, engine: &Engine) -> Json {
        match &self.candidate {
            Some(candidate) if self.shortcut_changed(engine) => candidate.clone(),
            _ => self.saved_shortcut(engine),
        }
    }

    // --- Actions ----------------------------------------------------------------

    fn record_key(&mut self, engine: &Engine, payload: &Json) {
        if !self.recording {
            return;
        }
        let key = int(payload, "key");
        if key == qt::KEY_ESCAPE {
            self.stop_recording();
            self.publish(engine);
            return;
        }
        let recorded = Keymap::of(engine).record_key(key, int(payload, "modifiers"));
        let chord = (!recorded.is_empty())
            .then(|| keymap::parse_shortcut(&recorded))
            .flatten();
        if let Some(chord) = chord {
            self.record(engine, json_of(&chord));
        }
    }

    fn record_modifier(&mut self, engine: &Engine, payload: &Json) {
        if !self.recording {
            return;
        }
        let modifier = text(payload, "modifier");
        let held = format!("{modifier}:{}", int(payload, "code"));
        if !flag(payload, "down") {
            self.held.remove(&held);
            return;
        }
        self.held.insert(held);
        // Both of one modifier's keys make a pair.
        let prefix = format!("{modifier}:");
        if self.held.iter().filter(|e| e.starts_with(&prefix)).count() < 2 {
            return;
        }
        if self.backend.session().mode == Mode::Portal {
            self.check = Some(Check {
                available: false,
                message: "Add a letter, number, or function key to your shortcut.".into(),
            });
            self.publish(engine);
            return;
        }
        let pair = if modifier == "shift" {
            json!({"kind": "both-shift-keys"})
        } else {
            json!({"kind": "modifier-pair", "modifier": modifier})
        };
        self.record(engine, pair);
    }

    fn act(&mut self, engine: &Engine, action: &str, payload: &Json) {
        match action {
            "snapShot.enable" => {
                if flag(payload, "on") {
                    self.open_setup(engine, "resume");
                } else {
                    self.stop_recording();
                    self.wizard = None;
                    self.set(engine, "snapShotEnabled", json!(false));
                    self.publish(engine);
                }
            }
            "snapShot.setup.open" => {
                let step = payload
                    .get("step")
                    .and_then(Json::as_str)
                    .unwrap_or("resume");
                self.open_setup(engine, step);
            }
            "snapShot.setup.continue" => {
                if self.wizard.is_none() {
                    return;
                }
                if !self.enabled(engine) || !self.backend.session().message.is_empty() {
                    self.set(engine, "snapShotEnabled", json!(true));
                }
                if self.access_ready() {
                    self.stop_recording();
                    if let Some(wizard) = &mut self.wizard {
                        wizard.step = SHORTCUT;
                    }
                }
                self.publish(engine);
            }
            "snapShot.setup.back" => {
                let Some(wizard) = &mut self.wizard else {
                    return;
                };
                wizard.step = ACCESS;
                self.stop_recording();
                self.publish(engine);
            }
            "snapShot.setup.close" => self.close_setup(engine, flag(payload, "completed")),
            "snapShot.setup.done" => {
                if self.wizard.is_none() || !self.access_ready() {
                    return;
                }
                if self.shortcut_changed(engine) {
                    if !self.can_save(engine) {
                        return;
                    }
                    self.save_candidate(engine);
                }
                let shortcut = self.backend.shortcut();
                if shortcut.registered || shortcut.pending {
                    self.close_setup(engine, true);
                } else {
                    self.publish(engine);
                }
            }
            "snapShot.record.start" => {
                self.recording = true;
                self.held.clear();
                self.check = None;
                self.publish(engine);
            }
            "snapShot.record.cancel" => {
                if self.recording {
                    self.stop_recording();
                    self.publish(engine);
                }
            }
            "snapShot.record.key" => self.record_key(engine, payload),
            "snapShot.record.modifier" => self.record_modifier(engine, payload),
            "snapShot.shortcut.save" => {
                if self.can_save(engine) {
                    self.save_candidate(engine);
                    self.publish(engine);
                }
            }
            "snapShot.shortcut.discard" => {
                self.stop_recording();
                self.reset_candidate();
                self.publish(engine);
            }
            "snapShot.shortcut.permissions" => {
                let events = self.backend.configure();
                self.apply(engine, events);
            }
            "snapShot.set" => {
                let key = match text(payload, "key").as_str() {
                    "accessibility" => "snapShotIncludeAccessibility",
                    "flash" => "snapShotFlash",
                    "animations" => "snapShotAnimations",
                    _ => return,
                };
                self.set(engine, key, json!(flag(payload, "value")));
            }
            "snapShot.sound" => {
                let value = text(payload, "value");
                match value.as_str() {
                    "off" => self.set(engine, "snapShotPlaySound", json!(false)),
                    "soft-pop" | "camera-shutter" => {
                        self.set(engine, "snapShotPlaySound", json!(true));
                        self.set(engine, "snapShotSound", json!(value));
                    }
                    _ => {}
                }
            }
            "snapShot.sound.play" => self.backend.play(&text(payload, "sound")),
            _ => {}
        }
    }

    /// Saves the shortcut being chosen as the setting, and binds it at once:
    /// the settings' own hook runs after the action, and setup closes on
    /// what the desktop says of the binding.
    fn save_candidate(&mut self, engine: &Engine) {
        let Some(shortcut) = self.candidate.take() else {
            return;
        };
        self.reset_candidate();
        self.set(engine, "snapShotShortcut", shortcut);
        self.follow(engine);
    }

    // --- Capturing --------------------------------------------------------------

    /// Acts on what the backend reported, and on what that set off.
    fn apply(&mut self, engine: &Engine, events: Vec<Event>) {
        let mut queue: VecDeque<Event> = events.into();
        while let Some(event) = queue.pop_front() {
            match event {
                Event::Changed => self.publish(engine),
                Event::Activated => {
                    // Recording a shortcut suppresses the one held.
                    if !self.recording && self.enabled(engine) {
                        queue.extend(self.backend.capture());
                    }
                }
                Event::Captured(captured) => self.on_captured(engine, captured),
                Event::Failed(message) => self.on_failed(engine, &message),
                Event::After { token, ms } => self.start_timer(engine, token, ms),
                Event::Cancel(token) => {
                    if let Some(timer) = self.timers.remove(&token) {
                        engine.cancel_call(timer);
                    }
                }
            }
        }
    }

    fn start_timer(&mut self, engine: &Engine, token: u64, ms: u64) {
        if let Some(old) = self.timers.remove(&token) {
            engine.cancel_call(old);
        }
        let me = self.me.clone();
        let at = engine.now() + Duration::from_millis(ms);
        let timer = engine.call_at(at, move |engine| {
            me.run(engine, move |c, engine| {
                c.timers.remove(&token);
                let events = c.backend.timeout(token);
                c.apply(engine, events);
            });
        });
        self.timers.insert(token, timer);
    }

    /// Where a capture goes: the thread or draft the window last showed if
    /// it still exists, else a new draft. Empty when there is no project.
    fn target(&mut self, engine: &Engine) -> String {
        self.note_route(engine);
        let last = self.last_target.clone();
        if !last.is_empty()
            && (store::with(engine, |s| s.thread(&last).is_some())
                || drafts::draft(engine, &last).is_some())
        {
            return last;
        }
        self.last_target.clear();
        drafts::start_new(engine, "");
        self.note_route(engine);
        self.last_target.clone()
    }

    fn toast_error(&self, engine: &Engine, title: &str, description: &str) {
        controller::with::<Toasts, _>(engine, |t, e| {
            t.error(e, title, description);
        });
    }

    fn on_captured(&mut self, engine: &Engine, captured: Captured) {
        // TODO(port): SnapShotController::onCaptured: the capture flash and
        // animation; no backend offers them yet (`feedback_available`).
        if self
            .setting(engine, "snapShotPlaySound")
            .as_bool()
            .unwrap_or(false)
        {
            let sound = self.setting(engine, "snapShotSound");
            self.backend.play(sound.as_str().unwrap_or_default());
        }
        let to = self.target(engine);
        if to.is_empty() {
            self.toast_error(
                engine,
                "Snapshot taken, but no project is available",
                "Add a project, then capture the window again.",
            );
            return;
        }
        let Some((bytes, mime_type)) = snap_shot::encode(&captured.image, self.max_image_bytes)
        else {
            self.on_failed(engine, "The captured window is too large to attach.");
            return;
        };
        let at = DateTime::from_timestamp_millis(sidebar::now_ms(engine)).unwrap_or_default();
        let captured_at = at.to_rfc3339_opts(SecondsFormat::Millis, true);
        let extension = if mime_type == "image/png" {
            "png"
        } else {
            "jpg"
        };
        let name = format!("window-{}.{extension}", captured_at.replace(':', "-"));
        let app_name = captured.app_name.trim();
        let mut source = Obj::new();
        source.insert("kind".into(), json!("snap-shot"));
        source.insert("capturedAt".into(), json!(captured_at));
        source.insert(
            "appName".into(),
            json!(if app_name.is_empty() {
                "Window"
            } else {
                app_name
            }),
        );
        source.insert("windowTitle".into(), json!(captured.window_title.trim()));
        composer::attach_image(engine, &to, &name, mime_type, &bytes, source);
        self.bridge.window_command(engine, "raise");
        self.bridge
            .send_to_bricks(engine, "composer.focus", &Json::Null);
    }

    fn on_failed(&self, engine: &Engine, message: &str) {
        self.toast_error(engine, "Snapshot failed", message);
    }

    // --- State ------------------------------------------------------------------

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        self.bridge.publish(engine, "snapShot", self.state(engine));
    }

    /// The `snapShot` state: the page's rows and the setup wizard.
    fn state(&self, engine: &Engine) -> Json {
        let session = self.backend.session();
        let shortcut = self.backend.shortcut();
        let on = self.enabled(engine);
        let portal = session.mode == Mode::Portal;
        let available = session.ready && session.mode != Mode::Unavailable;
        let picker = portal && session.backend == "picker";
        let ready = self.access_ready();
        let desktop = if portal {
            desktop_name(&session.desktop)
        } else {
            ""
        };
        let saved = self.saved_shortcut(engine);
        let changed = self.shortcut_changed(engine);
        let display = self.display_shortcut(engine);
        let can_save = self.can_save(engine);

        let status = if !session.ready {
            "Checking snapshots…".to_owned()
        } else if !available {
            if session.message.is_empty() {
                "Not supported on this platform.".to_owned()
            } else {
                session.message.clone()
            }
        } else if !on {
            "Turn this on to set up snapshots.".to_owned()
        } else if !session.message.is_empty() {
            "Capture needs attention".to_owned()
        } else if picker {
            "Manual capture only — you'll choose a window each time".to_owned()
        } else if shortcut.pending {
            "Waiting for shortcut permission".to_owned()
        } else if shortcut.registered {
            if shortcut.label.is_empty() {
                "Shortcut saved".to_owned()
            } else {
                "Ready to capture".to_owned()
            }
        } else {
            "Finish shortcut setup".to_owned()
        };

        let setup_label = if !(on && session.ready) {
            String::new()
        } else if ready {
            "Manage capture".to_owned()
        } else if desktop.is_empty() {
            "Continue setup".to_owned()
        } else {
            format!("Set up {desktop} capture")
        };

        let keys = if self.recording {
            "Press shortcut…".to_owned()
        } else if portal && is_pair(&display) {
            "Choose shortcut".to_owned()
        } else if !changed && !shortcut.label.is_empty() {
            shortcut.label.clone()
        } else {
            self.label(engine, &display)
        };

        let can_retry = shortcut.can_retry && !is_pair(&saved);
        let effects = if portal && !session.feedback_available {
            if session.desktop == "niri" {
                "Capture effects aren't available on Niri."
            } else {
                "Capture effects aren't available on this desktop."
            }
        } else {
            ""
        };
        let screenshot_only = if portal {
            "This desktop only provides a screenshot."
        } else {
            ""
        };
        let toggle = |key: &str, unavailable: &str| {
            let checked = self.setting(engine, key).as_bool().unwrap_or(false);
            json!({"checked": unavailable.is_empty() && checked,
                "enabled": available && unavailable.is_empty(),
                "status": unavailable})
        };
        let sound = if self
            .setting(engine, "snapShotPlaySound")
            .as_bool()
            .unwrap_or(false)
        {
            self.setting(engine, "snapShotSound")
                .as_str()
                .unwrap_or_default()
                .to_owned()
        } else {
            "off".to_owned()
        };
        let sound_label = match sound.as_str() {
            "off" => "Off",
            "soft-pop" => "Whoosh (Default)",
            _ => "Click",
        };

        let wizard = self.wizard.as_ref().map_or(Json::Null, |wizard| {
            let access = wizard.step == ACCESS;
            let (heading, body) = if !access {
                (
                    "Choose your shortcut",
                    if portal {
                        "Choose your keys, then approve the permission prompt if asked."
                    } else {
                        "Use both Shift keys, or record a different shortcut."
                    },
                )
            } else if !session.message.is_empty() {
                (
                    "Let's try that again",
                    "Couldn't check snapshots. Try again to continue.",
                )
            } else if picker {
                (
                    "Choose a window each time",
                    "Your desktop doesn't support automatic capture. You'll choose the window to capture instead.",
                )
            } else {
                (
                    "Allow snapshots",
                    if portal {
                        "Your desktop may ask for permission when you first capture."
                    } else {
                        "Allow access when prompted to start capturing windows."
                    },
                )
            };
            let title = if desktop.is_empty() {
                "Set up snapshots".to_owned()
            } else {
                format!("Set up snapshots for {desktop}")
            };
            json!({
                "step": wizard.step,
                "title": title,
                "heading": heading,
                "body": body,
                "details": if access { session.message.as_str() } else { "" },
                "attention": if !access && !ready {
                    "Capture needs attention. Go back to check access."
                } else {
                    ""
                },
                "closeLabel": if wizard.was_enabled { "Close" } else { "Finish later" },
                "continueLabel": if ready { "Continue" } else { "Try again" },
                "doneLabel": if changed { "Save and finish" } else { "Done" },
                "doneEnabled": ready && if changed {
                    can_save
                } else {
                    shortcut.registered || shortcut.pending
                },
                "permissions": !changed && !shortcut.registered && !shortcut.pending && can_retry,
                "permissionsLabel": if portal { "Shortcut permissions" } else { "Try again" },
            })
        });

        json!({
            "ready": session.ready,
            "available": available,
            "mode": session.mode.as_str(),
            "backend": session.backend,
            "desktop": session.desktop,
            "enabled": on,
            "switchOn": on || self.wizard.is_some(),
            "status": status,
            "description": if picker {
                "Automatic capture isn't available here. Choose a window instead."
            } else {
                "Capture a window and attach it to your current draft."
            },
            "setupLabel": setup_label,
            "rows": on && available,
            "shortcut": {
                "description": if picker {
                    "Choose a window to capture from any app."
                } else {
                    "Capture the window you're using without switching apps."
                },
                "keys": keys,
                "label": self.label(engine, &display),
                "recording": self.recording,
                "status": self.shortcut_status(engine),
                "changed": changed,
                "canSave": can_save,
                "registered": shortcut.registered,
                "pending": shortcut.pending,
                "permissions": !changed && portal && can_retry,
                "permissionsEnabled": !shortcut.pending,
            },
            "accessibility": toggle("snapShotIncludeAccessibility", screenshot_only),
            "sound": {"value": sound, "label": sound_label},
            "flash": toggle("snapShotFlash", effects),
            "animations": toggle("snapShotAnimations", effects),
            "wizard": wizard,
        })
    }
}

impl Controller for SnapShot {
    fn new(init: Init<'_, Self>) -> Self {
        SnapShot {
            bridge: init.bridge,
            me: init.me,
            // Until main.rs gives the platform's.
            backend: Box::new(Unavailable::new(
                "SnapShots are not supported on this platform.",
            )),
            active: false,
            bound: String::new(),
            shortcut_problem: String::new(),
            wizard: None,
            recording: false,
            held: BTreeSet::new(),
            candidate: None,
            check: None,
            last_target: String::new(),
            timers: HashMap::new(),
            max_image_bytes: MAX_IMAGE_BYTES,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if !self.active {
            self.active = true;
            let me = self.me.clone();
            Settings::of(engine).on_device_changed(move |e| later(e, &me, |c, e| c.follow(e)));
            // Where the window is, and whether the page is open.
            let me = self.me.clone();
            self.bridge.watch(engine, "route", move |e, _| {
                later(e, &me, |c, e| {
                    c.note_route(e);
                    c.follow(e);
                });
            });
        }
        self.note_route(engine);
        self.follow(engine);
    }

    fn attach(&mut self, engine: &Engine, _window: &controller::Window) {
        self.note_route(engine);
        self.follow(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("snapShot.") {
            return false;
        }
        self.act(engine, action, payload);
        true
    }
}

impl Drop for SnapShot {
    /// The shortcut is let go with the shell.
    fn drop(&mut self) {
        self.active = false;
        let _ = self.backend.release();
    }
}
