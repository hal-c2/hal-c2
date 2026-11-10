//! `snapShot`, desktop-qt's SnapShotController: capturing a window and
//! attaching the picture to the composer, and the settings page and setup
//! wizard around it (features/source-control/snap-shot.feature,
//! features/settings/snap-shot.feature).
//!
//! What the desktop can do is the [`Backend`]'s ([`crate::snap_shot`]); this
//! controller decides what to ask it from the settings (capture is opt-in,
//! the shortcut is bound only while it is on) and where a capture goes (the
//! thread or draft the window last showed, else a new draft). On Niri and
//! Hyprland the shortcut is a binding in the compositor's config, which the
//! user reviews here before it is written ([`crate::snap_shot::config`]).
//!
//! Publishes `snapShot`: the page's state, `{ready, available, mode,
//! backend, desktop, enabled, switchOn, status, description, setupLabel,
//! rows, shortcut{...}, accessibility, sound, flash, animations, wizard,
//! config}` (see [`SnapShot::state`]); `wizard` is null unless setup is
//! open, `config` unless the compositor keeps the shortcut.
//!
//! Actions: `snapShot.enable{on}`, `snapShot.setup.{open{step},continue,
//! action{action},back,close{completed},done}`, `snapShot.permission.allow{id}`,
//! `snapShot.config.{review{remove,file},save{id},cancel,copy,complete}`,
//! `snapShot.record.{start,cancel,key{key,modifiers,repeat},
//! modifier{modifier,code,down}}`, `snapShot.shortcut.{save,discard,
//! permissions}`, `snapShot.set{key,value}`, `snapShot.sound{value}` and
//! `snapShot.sound.play{sound}`. All of them are this controller's, even when
//! there is nothing to do.

use std::collections::{BTreeSet, HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use chrono::{DateTime, SecondsFormat};
use ljos::prelude::{Application, ApplicationState, Engine, TimerId, Value};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::composer;
use crate::controllers::drafts;
use crate::controllers::keybindings::Keymap;
use crate::controllers::navigation::{self, Navigation, Route};
use crate::controllers::settings::Settings;
use crate::controllers::sidebar;
use crate::controllers::toasts::{self, Toasts};
use crate::json::Json;
use crate::keybindings::{self as keymap, Shortcut as Chord, command_label, qt};
use crate::snap_shot::config::{self, Applied, Config, Format, Preview, Target, Tools};
use crate::snap_shot::{self, Backend, Captured, Check, Event, Mode, Unavailable};
use crate::store;
use crate::thread_view::summary::Obj;

/// The settings section that shows the page.
const SECTION: &str = "/settings/snap-shot";
const ACCESS: &str = "access";
const SHORTCUT: &str = "shortcut";
/// Where macOS's permission prompt quit the app from setup: `enabled` or
/// `disabled`, as capture was when setup opened.
const RESUME: &str = "snapShotSetupResume";
/// The app id the compositor's binding names (main.rs's APP_ID).
const APP_ID: &str = "hal-c2";
/// What a capture may weigh once attached (the contracts' image limit).
const MAX_IMAGE_BYTES: u64 = 10 * 1024 * 1024;
const FALLBACK_KEYS: &str = "Ctrl+Shift+2";

/// The setup wizard: where it is, and whether capture was on before it
/// opened (closing it unfinished turns capture off again if it was not).
#[derive(Clone, Debug)]
struct Wizard {
    step: &'static str,
    was_enabled: bool,
    /// The user asked the desktop again: its answer is worth saying.
    checked: bool,
    /// What went wrong in setup, shown in it.
    error: String,
}

impl Wizard {
    fn new(step: &'static str, was_enabled: bool) -> Wizard {
        Wizard {
            step,
            was_enabled,
            checked: false,
            error: String::new(),
        }
    }
}

/// Reviewing and saving the shortcut in the compositor's config.
#[derive(Clone, Debug, Default)]
struct ConfigFlow {
    preview: Option<Preview>,
    preparing: bool,
    saving: bool,
    error: String,
    details: String,
    result: String,
    backup: String,
    /// The config the user chose instead of the standard one.
    file: String,
    copied: bool,
    saved: bool,
}

/// What a config job came back with.
enum Done {
    Preview(Result<Preview, String>),
    Applied(Result<Applied, String>),
}

pub struct SnapShot {
    bridge: Bridge,
    me: Me<SnapShot>,
    backend: Box<dyn Backend>,
    active: bool,
    /// What the backend holds now; empty when it is released.
    bound: String,
    /// Why the saved shortcut cannot be held.
    shortcut_problem: String,
    wizard: Option<Wizard>,
    /// The test capture is under way: setup waits for it.
    testing: bool,
    resume_checked: bool,
    /// Setup came back and Settings has been opened to it.
    resume_shown: bool,
    /// The resume mark while the settings have no row for it.
    resume: String,
    recording: bool,
    /// The modifier keys down while recording, as "modifier:code".
    held: BTreeSet<String>,
    candidate: Option<Json>,
    check: Option<Check>,
    /// A check is out; its answer arrives as [`Event::Checked`].
    checking: bool,
    /// Answers the backend still owes, oldest first: only the last
    /// one is for the shortcut being checked.
    checks_owed: usize,
    /// The thread or draft the window last showed.
    last_target: String,
    /// What the backend asked to be called back about, by its token.
    timers: HashMap<u64, TimerId>,
    max_image_bytes: u64,
    published: Json,
    config_tools: Option<Tools>,
    config: Option<Arc<Mutex<Config>>>,
    job: Option<JoinHandle<Done>>,
    flow: ConfigFlow,
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
    if text(shortcut, "kind") == "both-shift-keys" {
        "shift".to_owned()
    } else {
        text(shortcut, "modifier")
    }
}

fn chord_of(shortcut: &Json) -> Chord {
    Chord {
        key: text(shortcut, "key"),
        meta: flag(shortcut, "metaKey"),
        ctrl: flag(shortcut, "ctrlKey"),
        shift: flag(shortcut, "shiftKey"),
        alt: flag(shortcut, "altKey"),
        mod_: flag(shortcut, "modKey"),
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

/// The changed lines of an edit, with two lines either side: `{kind:
/// context | removed | added, text}`.
fn diff_lines(before: &str, after: &str) -> Vec<Json> {
    let lines = |text: &str| -> Vec<String> {
        text.split('\n')
            .map(|line| line.strip_suffix('\r').unwrap_or(line).to_owned())
            .collect()
    };
    let a = lines(before);
    let b = lines(after);
    let mut head = 0;
    while head < a.len() && head < b.len() && a[head] == b[head] {
        head += 1;
    }
    let mut tail = 0;
    while tail < a.len() - head
        && tail < b.len() - head
        && a[a.len() - 1 - tail] == b[b.len() - 1 - tail]
    {
        tail += 1;
    }
    let mut diff = Vec::new();
    let mut add = |kind: &str, text: &str| diff.push(json!({"kind": kind, "text": text}));
    for line in &a[head.saturating_sub(2)..head] {
        add("context", line);
    }
    for line in &a[head..a.len() - tail] {
        add("removed", line);
    }
    for line in &b[head..b.len() - tail] {
        add("added", line);
    }
    for line in &a[a.len() - tail..(a.len() - tail + 2).min(a.len())] {
        add("context", line);
    }
    diff
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

/// Whether the application is in front; in front when there is none.
fn app_active(engine: &Engine) -> bool {
    let Ok(app) = engine.singleton::<Application>() else {
        return true;
    };
    matches!(engine.read_by_name(app, "state"),
        Value::Int(state) if state == ApplicationState::Active.qt_value())
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

    /// Takes what the backend's own threads left, and acts on it; and a
    /// config job that finished.
    pub fn arrive(&mut self, engine: &Engine) {
        let events = self.backend.arrive();
        self.apply(engine, events);
        if self.job.as_ref().is_some_and(JoinHandle::is_finished) {
            self.finish_config(engine);
        }
    }

    /// The most a captured picture may weigh once attached.
    pub fn set_max_image_bytes(&mut self, bytes: u64) {
        self.max_image_bytes = bytes;
    }

    /// What the compositor is asked instead of the system's `niri` and
    /// `hyprctl`, for tests; none goes back to the system's.
    pub fn set_config_tools(&mut self, tools: Option<Tools>) {
        self.config_tools = tools;
        self.config = None;
    }

    /// Waits for the config job under way, if any, and acts on it.
    pub fn finish_config(&mut self, engine: &Engine) {
        let Some(job) = self.job.take() else {
            return;
        };
        match job.join() {
            Ok(Done::Preview(result)) => self.previewed(result),
            Ok(Done::Applied(result)) => self.applied(engine, result),
            Err(_) => {
                self.flow.preparing = false;
                self.flow.saving = false;
                self.flow.error = "Couldn't prepare the changes. Check Advanced for help.".into();
            }
        }
        self.publish(engine);
    }

    // --- Settings ---------------------------------------------------------------

    fn setting(&self, engine: &Engine, key: &str) -> Json {
        if key == RESUME {
            return Settings::of(engine)
                .setting(engine, key)
                .filter(|v| v.as_str().is_some_and(|s| !s.is_empty()))
                .unwrap_or_else(|| json!(self.resume));
        }
        Settings::of(engine)
            .setting(engine, key)
            .unwrap_or(Json::Null)
    }

    fn set(&mut self, engine: &Engine, key: &str, value: Json) {
        if key == RESUME {
            self.resume = value.as_str().unwrap_or_default().to_owned();
        }
        Settings::of(engine).set(engine, key, value);
    }

    fn on(&self, engine: &Engine, key: &str) -> bool {
        self.setting(engine, key).as_bool().unwrap_or(false)
    }

    fn enabled(&self, engine: &Engine) -> bool {
        self.on(engine, "snapShotEnabled")
    }

    fn include_accessibility(&self, engine: &Engine) -> bool {
        self.on(engine, "snapShotIncludeAccessibility")
    }

    fn resume_mark(&self, engine: &Engine) -> String {
        self.setting(engine, RESUME)
            .as_str()
            .unwrap_or_default()
            .to_owned()
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
        if let Some(setup) = self.backend.setup() {
            return setup.access_ready;
        }
        let session = self.backend.session();
        session.mode != Mode::Unavailable && session.message.is_empty()
    }

    fn permissions_ready(&self, engine: &Engine) -> bool {
        let session = self.backend.session();
        session.permissions.is_some_and(|p| {
            session.permissions_error.is_empty()
                && p.screen_recording
                && (!self.include_accessibility(engine) || p.accessibility)
        })
    }

    fn panel_open(&self, engine: &Engine) -> bool {
        navigation::shown(engine) == Route::Settings(SECTION.to_owned())
    }

    /// Setup is waiting on the desktop and cannot be left or stepped through.
    fn busy(&self) -> bool {
        self.wizard.is_some() && self.backend.session().checking
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
        let include = self.include_accessibility(engine);
        self.backend.set_include_accessibility(include);
        if self.enabled(engine) || self.panel_open(engine) || !self.resume_mark(engine).is_empty() {
            let events = self.backend.probe();
            self.apply(engine, events);
        }
        self.resume_setup(engine);
        // Leaving the panel ends recording, and with it the pause on captures.
        if self.recording && !self.panel_open(engine) {
            self.stop_recording(engine);
        }
        self.apply_shortcut(engine);
        self.publish(engine);
    }

    fn apply_shortcut(&mut self, engine: &Engine) {
        let flash = self.on(engine, "snapShotFlash");
        let animations = self.on(engine, "snapShotAnimations");
        self.backend.set_cues(flash, animations);
        let mut trigger = String::new();
        let mut problem = String::new();
        // Niri's shortcut is a binding in its config. Hyprland's is too, but
        // it reaches HAL-C2 through the portal session this opens.
        let session = self.backend.session();
        let desktop = if self.managed() {
            session.desktop.clone()
        } else {
            String::new()
        };
        let on = self.enabled(engine);
        let saved = self.saved_shortcut(engine);
        if on && session.mode == Mode::Portal && desktop != "niri" {
            match snap_shot::portal_trigger(&saved) {
                Ok(found) => trigger = found,
                Err(why) => problem = why,
            }
            // The keys live in Hyprland's config; the session only has to
            // exist, and the portal needs a trigger to open it.
            if trigger.is_empty() && desktop == "hyprland" {
                trigger = "CTRL+SHIFT+2".into();
                problem.clear();
            }
        } else if on && session.mode != Mode::Unavailable && desktop != "niri" {
            match self.backend.trigger(&saved) {
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
        // Permissions and the test capture come first, every time.
        if !self.access_ready() || self.backend.session().permissions.is_some() {
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
        if self.job.is_some() {
            return;
        }
        let session = self.backend.session();
        // A desktop without capture has nothing to set up.
        if !session.ready || session.mode == Mode::Unavailable {
            return;
        }
        // Nor does one that needs no setup: opening it turns capture on.
        if session.setup_free {
            if !self.enabled(engine) {
                self.set(engine, "snapShotEnabled", json!(true));
            }
            self.publish(engine);
            return;
        }
        self.stop_recording(engine);
        self.reset_candidate();
        let was_enabled = self.enabled(engine);
        let step = self.initial_step(requested);
        // Opening setup is the opt-in.
        if !was_enabled && step != ACCESS {
            self.set(engine, "snapShotEnabled", json!(true));
        }
        self.wizard = Some(Wizard::new(step, was_enabled));
        self.publish(engine);
    }

    fn close_setup(&mut self, engine: &Engine, completed: bool) {
        let Some(wizard) = self.wizard.take() else {
            return;
        };
        self.stop_recording(engine);
        self.set(engine, RESUME, json!(""));
        self.flow = ConfigFlow::default();
        // A shortcut in the compositor's config is only ever a proposal for this setup.
        if self.managed() {
            self.reset_candidate();
        }
        if self.enabled(engine) && !wizard.was_enabled && !completed {
            self.set(engine, "snapShotEnabled", json!(false));
        }
        self.publish(engine);
    }

    /// macOS can quit the app from its permission prompt.
    fn save_resume(&mut self, engine: &Engine) {
        if let Some(wizard) = &self.wizard {
            let mark = if wizard.was_enabled {
                "enabled"
            } else {
                "disabled"
            };
            self.set(engine, RESUME, json!(mark));
        }
    }

    /// Opens setup again after macOS restarted the app from a permission prompt.
    fn resume_setup(&mut self, engine: &Engine) {
        let session = self.backend.session();
        if !self.resume_checked && session.ready {
            // Once per start, so opening System Settings cannot redirect later.
            self.resume_checked = true;
            let resume = self.resume_mark(engine);
            if !resume.is_empty() && session.permissions.is_some() && self.wizard.is_none() {
                self.wizard = Some(Wizard::new(ACCESS, resume == "enabled"));
                self.resume_shown = false;
            }
        }
        if self.resume_shown {
            return;
        }
        self.resume_shown = true;
        let route = Route::Settings(SECTION.to_owned());
        let me = self.me.clone();
        // Navigation may be the controller running now.
        Bridge::of(engine).defer(engine, move |engine| {
            controller::with::<Navigation, _>(engine, |n, e| n.open(e, route));
            me.run(engine, |c, e| c.publish(e));
        });
    }

    fn stop_recording(&mut self, engine: &Engine) {
        self.held.clear();
        if !std::mem::replace(&mut self.recording, false) {
            return;
        }
        let _ = self.backend.pause(false);
        // Recording cleared the check; the shortcut recorded before it can still be saved.
        self.check_candidate(engine);
    }

    fn reset_candidate(&mut self) {
        self.candidate = None;
        self.checking = false;
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

    /// SnapShotSettings' checkShortcut: HAL-C2's own keybindings first,
    /// then the system's, then the desktop's.
    fn check_candidate(&mut self, engine: &Engine) {
        self.checking = false;
        self.check = None;
        let Some(candidate) = self.candidate.clone() else {
            return;
        };
        if self.managed() {
            self.check = Some(match config::keys(&self.label(engine, &candidate)) {
                Ok(_) => Check {
                    available: false,
                    message: if self.backend.session().desktop == "niri" {
                        "Configure the capture shortcut in your Niri config, not in HAL-C2.".into()
                    } else {
                        "Change the capture binding in your Hyprland config, then save it.".into()
                    },
                },
                Err(problem) => Check {
                    available: false,
                    message: problem,
                },
            });
            return;
        }
        if !self.shortcut_changed(engine) || !self.conflict(engine, &candidate).is_empty() {
            return;
        }
        if !is_pair(&candidate) {
            let reserved = system_conflict(&chord_of(&candidate));
            if !reserved.is_empty() {
                self.check = Some(Check {
                    available: false,
                    message: reserved,
                });
                return;
            }
        }
        self.checking = true;
        match self.backend.check_shortcut(&candidate) {
            Some(answer) => self.checked(answer),
            None => self.checks_owed += 1,
        }
    }

    /// The answer to the check out.
    fn checked(&mut self, mut answer: Check) {
        if !self.checking {
            return;
        }
        self.checking = false;
        if !answer.available && answer.message.is_empty() {
            answer.message = "Could not check this shortcut.".into();
        }
        self.check = Some(answer);
    }

    fn record(&mut self, engine: &Engine, shortcut: Json) {
        self.candidate = Some(shortcut);
        // A review is of the keys it was prepared for.
        self.withdraw_review();
        // Recording ends with a check of what it recorded.
        if self.recording {
            self.stop_recording(engine);
        } else {
            self.check_candidate(engine);
        }
        self.publish(engine);
    }

    fn shortcut_changed(&self, engine: &Engine) -> bool {
        !self.managed()
            && self
                .candidate
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
        let session = self.backend.session();
        let shortcut = self.backend.shortcut();
        if self.managed() && self.check.is_none() {
            return shortcut.message;
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
        if self.checking {
            return "Checking shortcut…".into();
        }
        // A direct backend's word on a free shortcut is worth reading (it
        // may only be observed); the portal's only promises what saving does.
        if let Some(check) = &self.check {
            return if !check.available
                || (session.mode == Mode::Direct && !check.message.is_empty())
            {
                check.message.clone()
            } else {
                "Ready to save.".to_owned()
            };
        }
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
            return if session.mode == Mode::Portal || !shortcut.message.is_empty() {
                shortcut.message
            } else {
                "Shortcut saved.".into()
            };
        }
        shortcut.message
    }

    /// The shortcut the page shows: the one being chosen, else the saved.
    fn display_shortcut(&self, engine: &Engine) -> Json {
        match &self.candidate {
            Some(candidate) if self.shortcut_changed(engine) || self.managed() => candidate.clone(),
            _ => self.saved_shortcut(engine),
        }
    }

    // --- Actions ----------------------------------------------------------------

    fn record_key(&mut self, engine: &Engine, payload: &Json) {
        if !self.recording {
            return;
        }
        let key = int(payload, "key");
        let modifiers = int(payload, "modifiers");
        // A held key repeats, and a plain Tab moves focus on: neither is a shortcut.
        if flag(payload, "repeat") {
            return;
        }
        const CONTROL: i32 = 0x0400_0000;
        const ALT: i32 = 0x0800_0000;
        const META: i32 = 0x1000_0000;
        if (key == qt::KEY_TAB || key == qt::KEY_BACKTAB) && modifiers & (CONTROL | ALT | META) == 0
        {
            return;
        }
        if key == qt::KEY_ESCAPE {
            self.stop_recording(engine);
            self.publish(engine);
            return;
        }
        let recorded = Keymap::of(engine).record_key(key, modifiers);
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
        // The key's scan code, a number from SnapShotSettings.qml; a native
        // caller may name the key instead ("ShiftLeft").
        let code = match payload.get("code") {
            Some(Json::String(name)) => name.clone(),
            _ => int(payload, "code").to_string(),
        };
        let held = format!("{modifier}:{code}");
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
        // Setup waits on the desktop before it can be left or stepped through.
        if self.busy()
            && (action.starts_with("snapShot.setup.")
                || action == "snapShot.enable"
                || action == "snapShot.record.start")
        {
            return;
        }
        match action {
            "snapShot.enable" => {
                if flag(payload, "on") {
                    self.open_setup(engine, "resume");
                } else {
                    if self.job.is_some() {
                        return;
                    }
                    self.stop_recording(engine);
                    self.wizard = None;
                    self.set(engine, RESUME, json!(""));
                    // Like closing setup: a review is only ever of this setup.
                    self.flow = ConfigFlow::default();
                    if self.managed() {
                        self.reset_candidate();
                    }
                    self.set(engine, "snapShotEnabled", json!(false));
                    self.publish(engine);
                }
            }
            "snapShot.setup.open" => {
                let step = payload
                    .get("step")
                    .and_then(Json::as_str)
                    .unwrap_or("resume")
                    .to_owned();
                self.open_setup(engine, &step);
            }
            "snapShot.setup.continue" => self.setup_continue(engine),
            "snapShot.setup.action" => {
                // Only a step the user chose: checking access never installs anything.
                if let Some(wizard) = &mut self.wizard {
                    wizard.error.clear();
                    wizard.checked = false;
                }
                self.publish(engine);
                let events = self.backend.perform(&text(payload, "action"));
                self.apply(engine, events);
                self.publish(engine);
            }
            "snapShot.permission.allow" => {
                if self.wizard.is_none() || self.testing {
                    return;
                }
                self.save_resume(engine);
                self.backend.allow(&text(payload, "id"));
                self.publish(engine);
            }
            "snapShot.setup.back" => {
                if self.wizard.is_none() || self.testing || self.job.is_some() {
                    return;
                }
                self.stop_recording(engine);
                if let Some(wizard) = &mut self.wizard {
                    wizard.step = ACCESS;
                }
                self.publish(engine);
            }
            "snapShot.setup.close" => {
                if self.testing || self.job.is_some() {
                    return;
                }
                self.close_setup(engine, flag(payload, "completed"));
            }
            "snapShot.config.review" => {
                self.review(engine, flag(payload, "remove"), &text(payload, "file"));
            }
            "snapShot.config.save" => self.save_review(engine, &text(payload, "id")),
            "snapShot.config.cancel" => {
                // The file is being read or written: the outcome is what the user sees next.
                if self.job.is_some() {
                    return;
                }
                self.withdraw_review();
                self.flow.error.clear();
                self.flow.details.clear();
                self.publish(engine);
            }
            "snapShot.config.copy" => {
                if !self.managed() {
                    return;
                }
                self.bridge.copy_to_clipboard(engine, &self.binding(engine));
                self.flow.copied = true;
                self.publish(engine);
            }
            "snapShot.config.complete" => {
                if self.managed() && self.job.is_none() {
                    self.close_setup(engine, true);
                }
            }
            "snapShot.setup.done" => self.setup_done(engine),
            "snapShot.record.start" => {
                if self.job.is_some() {
                    return;
                }
                self.held.clear();
                self.checking = false;
                self.check = None;
                // The capture shortcut must not fire while its replacement is pressed.
                if self.recording {
                    // Already recording.
                } else {
                    match self.backend.pause(true) {
                        Ok(()) => self.recording = true,
                        Err(reason) => {
                            self.check = Some(Check {
                                available: false,
                                message: if reason.is_empty() {
                                    "Could not start shortcut recording.".into()
                                } else {
                                    reason
                                },
                            });
                        }
                    }
                }
                self.publish(engine);
            }
            "snapShot.record.cancel" => {
                if self.recording {
                    self.stop_recording(engine);
                    self.publish(engine);
                }
            }
            "snapShot.record.key" => self.record_key(engine, payload),
            "snapShot.record.modifier" => self.record_modifier(engine, payload),
            "snapShot.shortcut.save" => {
                if !self.can_save(engine) {
                    return;
                }
                let shortcut = self.candidate.clone().unwrap_or(Json::Null);
                self.reset_candidate();
                self.set(engine, "snapShotShortcut", shortcut);
                self.follow(engine);
            }
            "snapShot.shortcut.discard" => {
                if self.job.is_some() {
                    return;
                }
                self.stop_recording(engine);
                self.reset_candidate();
                self.publish(engine);
            }
            "snapShot.shortcut.permissions" => {
                let events = self.backend.configure();
                self.apply(engine, events);
            }
            "snapShot.set" => self.set_toggle(engine, payload),
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

    fn setup_continue(&mut self, engine: &Engine) {
        if self.wizard.is_none() || self.testing {
            return;
        }
        if self.backend.session().permissions.is_some() {
            if !self.permissions_ready(engine) {
                return;
            }
            self.save_resume(engine);
            if let Some(wizard) = &mut self.wizard {
                wizard.error.clear();
            }
            self.testing = true;
            self.publish(engine);
            let events = self.backend.test();
            self.apply(engine, events);
            return;
        }
        let retry = match self.backend.setup() {
            Some(setup) => !setup.access_ready,
            None => !self.backend.session().message.is_empty(),
        };
        if let Some(wizard) = &mut self.wizard {
            wizard.error.clear();
            // Try again: the desktop is asked once more, and setup moves on once it answers.
            wizard.checked = retry;
        }
        if !self.enabled(engine) || retry {
            self.set(engine, "snapShotEnabled", json!(true));
        }
        if retry {
            let events = self.backend.refresh();
            self.apply(engine, events);
        }
        if self.access_ready() {
            self.stop_recording(engine);
            if let Some(wizard) = &mut self.wizard {
                wizard.step = SHORTCUT;
            }
        }
        self.publish(engine);
    }

    fn setup_done(&mut self, engine: &Engine) {
        if self.wizard.is_none() || !self.access_ready() || self.job.is_some() {
            return;
        }
        if self.managed() {
            let same = self
                .flow
                .preview
                .as_ref()
                .is_some_and(|p| p.before == p.after);
            if self.flow.saved || same {
                self.close_setup(engine, true);
            }
            return;
        }
        if self.shortcut_changed(engine) {
            if !self.can_save(engine) {
                return;
            }
            let shortcut = self.candidate.clone().unwrap_or(Json::Null);
            self.set(engine, "snapShotShortcut", shortcut);
            self.reset_candidate();
            // The settings' own hook runs after the action; setup closes on
            // what the desktop says of the binding.
            self.follow(engine);
        }
        let shortcut = self.backend.shortcut();
        if shortcut.registered || shortcut.pending {
            self.close_setup(engine, true);
        } else {
            self.publish(engine);
        }
    }

    fn set_toggle(&mut self, engine: &Engine, payload: &Json) {
        let key = match text(payload, "key").as_str() {
            "accessibility" => "snapShotIncludeAccessibility",
            "flash" => "snapShotFlash",
            "animations" => "snapShotAnimations",
            _ => return,
        };
        let value = flag(payload, "value");
        let session = self.backend.session();
        // A desktop that gives only a screenshot has no app text to include.
        if key == "snapShotIncludeAccessibility" && !session.app_text {
            return;
        }
        if key == "snapShotIncludeAccessibility"
            && value
            && self.enabled(engine)
            && session.permissions.is_some()
        {
            let refused = self.backend.request_permissions(true);
            if !refused.is_empty() {
                let title = "Couldn't allow app text capture";
                if let Some(wizard) = &mut self.wizard {
                    wizard.error = format!("{title}. {refused}");
                } else {
                    self.toast_error(engine, title, &refused);
                }
                self.publish(engine);
                return;
            }
        }
        self.set(engine, key, json!(value));
    }

    // --- The compositor's config ------------------------------------------------

    /// The compositor keeps the shortcut in its config: Niri or Hyprland,
    /// outside a sandbox (which can neither reach the config nor answer
    /// its binding).
    fn managed(&self) -> bool {
        if snap_shot::env_var("FLATPAK_ID").is_some() || snap_shot::env_var("SNAP").is_some() {
            return false;
        }
        let session = self.backend.session();
        session.mode == Mode::Portal && matches!(session.desktop.as_str(), "niri" | "hyprland")
    }

    fn config_target(&self) -> Target {
        let desktop = self.backend.session().desktop;
        let env = |name: &str| snap_shot::env_var(name);
        let standard = if desktop == "niri" {
            config::niri_config_path(&env)
        } else {
            config::hyprland_config_path(&env)
        };
        Target {
            desktop,
            path: if self.flow.file.is_empty() {
                standard
            } else {
                self.flow.file.clone()
            },
            app_id: APP_ID.into(),
        }
    }

    /// The binding the user can paste in themselves.
    fn binding(&self, engine: &Engine) -> String {
        let target = self.config_target();
        let format = if target.desktop == "niri" {
            Format::Niri
        } else if target.path.ends_with(".lua") {
            Format::HyprlandLua
        } else {
            Format::Hyprland
        };
        let mut keys = match (&self.flow.preview, &self.candidate) {
            (Some(preview), _) => preview.shortcut.clone(),
            (None, Some(candidate)) => self.label(engine, candidate),
            (None, None) => FALLBACK_KEYS.into(),
        };
        if config::keys(&keys).is_err() {
            keys = FALLBACK_KEYS.into();
        }
        config::binding(format, &target.app_id, &keys)
    }

    /// Runs `work` on the config's thread; false while one runs.
    fn run_config(&mut self, work: impl FnOnce(&mut Config) -> Done + Send + 'static) -> bool {
        if self.job.is_some() {
            return false;
        }
        let config = self
            .config
            .get_or_insert_with(|| {
                let env = |name: &str| snap_shot::env_var(name);
                let tools = self.config_tools.clone().unwrap_or_else(Tools::system);
                Arc::new(Mutex::new(Config::new(config::home(&env), tools)))
            })
            .clone();
        let wake = snap_shot::wake();
        self.job = Some(std::thread::spawn(move || {
            let done = {
                let mut config = config.lock().unwrap_or_else(|e| e.into_inner());
                work(&mut config)
            };
            if let Some(wake) = wake {
                wake();
            }
            done
        }));
        true
    }

    fn review(&mut self, engine: &Engine, remove: bool, file: &str) {
        const UNPREPARED: &str = "Couldn't prepare the changes. Check Advanced for help.";
        if !self.managed() {
            self.flow.error = UNPREPARED.into();
            self.flow.details = "Config setup requires a Niri or Hyprland session.".into();
            self.publish(engine);
            return;
        }
        if self.job.is_some() {
            self.flow.details = "Wait for the current config change to finish.".into();
            self.flow.error = UNPREPARED.into();
            self.publish(engine);
            return;
        }
        self.stop_recording(engine);
        let chosen = if file.is_empty() {
            self.flow.file.clone()
        } else {
            file.to_owned()
        };
        self.flow = ConfigFlow {
            file: chosen,
            preparing: true,
            ..ConfigFlow::default()
        };
        let target = self.config_target();
        let keys = match (&self.candidate, remove) {
            (Some(candidate), false) => self.label(engine, candidate),
            _ => String::new(),
        };
        self.run_config(move |config| Done::Preview(config.preview(&target, !remove, &keys)));
        self.publish(engine);
    }

    fn previewed(&mut self, result: Result<Preview, String>) {
        self.flow.preparing = false;
        match result {
            Ok(preview) => self.flow.preview = Some(preview),
            Err(reason) => {
                self.flow.preview = None;
                self.flow.error = "Couldn't prepare the changes. Check Advanced for help.".into();
                self.flow.details = reason;
            }
        }
    }

    fn save_review(&mut self, engine: &Engine, id: &str) {
        if !self.managed() || self.job.is_some() {
            return;
        }
        let Some(preview) = self.flow.preview.clone() else {
            return;
        };
        if preview.before == preview.after {
            return;
        }
        // A key recorded during the save would withdraw the review being saved.
        self.stop_recording(engine);
        // Hyprland's binding does nothing until the portal session that serves it is up.
        let shortcut = self.backend.shortcut();
        let desktop = self.backend.session().desktop;
        if preview.install
            && !shortcut.registered
            && (desktop == "hyprland" || !shortcut.message.is_empty())
        {
            return;
        }
        self.flow.saving = true;
        self.flow.error.clear();
        self.flow.details.clear();
        let reviewed = if id.is_empty() {
            preview.id.clone()
        } else {
            id.to_owned()
        };
        self.run_config(move |config| Done::Applied(config.apply(&reviewed, &desktop)));
        self.publish(engine);
    }

    fn applied(&mut self, engine: &Engine, result: Result<Applied, String>) {
        let preview = self.flow.preview.take();
        self.flow.saving = false;
        let applied = match result {
            Ok(applied) => applied,
            Err(reason) => {
                self.flow.error =
                    "Couldn't save your shortcut. Review the changes and try again.".into();
                self.flow.details = reason;
                return;
            }
        };
        let Some(preview) = preview else {
            return;
        };
        self.flow.backup = applied.backup_path;
        if preview.install
            && let Some(candidate) = self.candidate.clone()
        {
            self.set(engine, "snapShotShortcut", candidate);
        }
        if !applied.warning.is_empty() {
            self.flow.result =
                "Saved, but the shortcut needs attention. Check Advanced for help.".into();
            self.flow.details = applied.warning;
            return;
        }
        if !preview.install {
            self.flow.result = "Shortcut removed.".into();
            self.flow.saved = true;
            return;
        }
        let description = format!("Use {} from another app.", preview.shortcut);
        controller::with::<Toasts, _>(engine, |t, e| {
            t.show(
                e,
                "success",
                "Shortcut saved",
                &description,
                None,
                toasts::DEFAULT_TIMEOUT_MS,
            );
        });
        self.close_setup(engine, true);
    }

    fn withdraw_review(&mut self) {
        self.flow.preview = None;
        self.flow.result.clear();
        self.flow.saved = false;
        self.flow.copied = false;
    }

    fn config_state(&self, engine: &Engine) -> Json {
        if !self.managed() {
            return Json::Null;
        }
        let session = self.backend.session();
        let shortcut = self.backend.shortcut();
        let niri = session.desktop == "niri";
        let target = self.config_target();
        let flow = &self.flow;
        let busy = flow.preparing || flow.saving;
        let connecting = if !niri && !shortcut.registered {
            if shortcut.message.is_empty() {
                "Connecting to your desktop…"
            } else {
                "Restart HAL-C2 to finish connecting your shortcut."
            }
        } else {
            ""
        };
        let unconnected = !shortcut.registered && (!niri || !shortcut.message.is_empty());

        let mut intro = "Allow HAL-C2 to read your desktop settings. You'll review any changes here before saving.".to_owned();
        let mut reviewed = Json::Null;
        if let Some(preview) = &flow.preview {
            let same = preview.before == preview.after;
            intro = match (same, preview.install) {
                (true, true) => "This shortcut is already set up.",
                (true, false) => "There's no capture shortcut to remove.",
                (false, true) => "Review the change below, then save your shortcut.",
                (false, false) => "Review the change below to remove your shortcut.",
            }
            .into();
            let linked = !preview.resolved_path.is_empty() && preview.resolved_path != preview.path;
            reviewed = json!({
                "id": preview.id,
                "changed": !same,
                "install": preview.install,
                "shortcut": preview.shortcut,
                "note": if same { "" } else { "Only these changes will be saved. We'll keep a backup." },
                "lines": if same { Vec::new() } else { diff_lines(&preview.before, &preview.after) },
                "saveLabel": if flow.saving {
                    "Saving…"
                } else if preview.install {
                    "Save shortcut"
                } else {
                    "Remove shortcut"
                },
                "canSave": !same && !busy && (!preview.install || !unconnected),
                "linked": if linked {
                    format!("Linked to {}. The link will be kept.", preview.resolved_path)
                } else {
                    String::new()
                },
            });
        }
        if !flow.result.is_empty() {
            intro = flow.result.clone();
        }
        json!({
            "intro": intro,
            "reviewLabel": if flow.preparing { "Preparing changes…" } else { "Review changes" },
            "canReview": !busy && flow.preview.is_none(),
            "busy": busy,
            "review": reviewed,
            "connecting": connecting,
            "error": flow.error,
            "details": flow.details,
            "backup": if flow.backup.is_empty() {
                String::new()
            } else {
                format!("Backup: {}", flow.backup)
            },
            "file": flow.preview.as_ref().map_or(target.path.clone(), |p| p.path.clone()),
            "fileHint": if niri {
                "HAL-C2 also reads any files included by this file."
            } else {
                "On Omarchy, use your own bindings file, not its defaults."
            },
            "binding": self.binding(engine),
            "manual": if niri {
                "Paste this inside binds { … } in your Niri config, then save. Change the keys if needed."
            } else {
                "Add this binding to your Hyprland config, then save. Change the keys if needed."
            },
            "copyLabel": if flow.copied { "Copied" } else { "Copy shortcut" },
            "removeNote": format!(
                "Turn capture off in HAL-C2 to stop it. Remove the shortcut from {} to free up the keys.",
                if niri { "Niri" } else { "Hyprland" }
            ),
        })
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
                        let flash = self.on(engine, "snapShotFlash");
                        let animations = self.on(engine, "snapShotAnimations");
                        self.backend.set_effects(flash, animations);
                        queue.extend(self.backend.capture());
                    }
                }
                Event::Captured(captured) => self.on_captured(engine, captured),
                Event::Failed(message) => self.on_failed(engine, &message),
                Event::SetupFailed(message) => self.on_setup_failed(engine, message),
                Event::Tested(error) => self.on_tested(engine, &error),
                Event::Checked(answer) => {
                    self.checks_owed = self.checks_owed.saturating_sub(1);
                    // An answer for a shortcut the user has since replaced.
                    if self.checks_owed == 0 {
                        self.checked(answer);
                    }
                    self.publish(engine);
                }
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

    /// The user may have changed capture access or the shortcut while away.
    fn on_application_state(&mut self, engine: &Engine) {
        if self.active && app_active(engine) && (self.enabled(engine) || self.panel_open(engine)) {
            let events = self.backend.refresh();
            self.apply(engine, events);
        }
    }

    /// The test image is the backend's to throw away; only the answer comes here.
    fn on_tested(&mut self, engine: &Engine, error: &str) {
        if !self.testing {
            return;
        }
        self.testing = false;
        let Some(wizard) = &mut self.wizard else {
            self.publish(engine);
            return;
        };
        if !error.is_empty() {
            wizard.error = format!("Couldn't verify capture access. {error}");
            self.publish(engine);
            return;
        }
        let include = self.include_accessibility(engine);
        self.backend.request_permissions(include);
        if !self.enabled(engine) {
            self.set(engine, "snapShotEnabled", json!(true));
        }
        if self.access_ready() {
            self.stop_recording(engine);
            if let Some(wizard) = &mut self.wizard {
                wizard.step = SHORTCUT;
            }
        }
        self.publish(engine);
    }

    /// Setup errors stay in setup; without it open, the panel has nowhere else.
    fn on_setup_failed(&mut self, engine: &Engine, message: String) {
        match &mut self.wizard {
            Some(wizard) => {
                wizard.error = message;
                self.publish(engine);
            }
            None => self.on_failed(engine, &message),
        }
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
        if self.on(engine, "snapShotPlaySound") {
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
        if self.include_accessibility(engine)
            && let Json::Object(context) = captured.context
        {
            source.extend(context);
        }
        composer::attach_image(engine, &to, &name, mime_type, &bytes, source);
        self.bridge.window_command(engine, "raise");
        self.bridge
            .send_to_bricks(engine, "composer.focus", &Json::Null);
    }

    fn on_failed(&self, engine: &Engine, message: &str) {
        self.toast_error(engine, "Snapshot failed", message);
    }

    // --- State ------------------------------------------------------------------

    fn publish(&mut self, engine: &Engine) {
        if !self.active {
            return;
        }
        // A permission can change in System Settings while setup or the
        // panel shows it, and one granted again brings the shortcut back
        // without a restart.
        let watch = !self.testing
            && (self.wizard.as_ref().is_some_and(|w| w.step == ACCESS)
                || (self.enabled(engine)
                    && (self.panel_open(engine) || !self.backend.session().message.is_empty())));
        self.backend.watch_permissions(watch);
        let next = self.state(engine);
        if next == self.published {
            return;
        }
        self.published = next.clone();
        self.bridge.publish(engine, "snapShot", next);
    }

    /// The `snapShot` state: the page's rows, the setup wizard and the
    /// config review.
    fn state(&self, engine: &Engine) -> Json {
        let session = self.backend.session();
        let shortcut = self.backend.shortcut();
        let setup = self.backend.setup();
        let on = self.enabled(engine);
        let portal = session.mode == Mode::Portal;
        let available = session.ready && session.mode != Mode::Unavailable;
        let picker = portal && session.backend == "picker";
        let ready = self.access_ready();
        let permissions_ready = self.permissions_ready(engine);
        let desktop = if portal {
            desktop_name(&session.desktop)
        } else {
            ""
        };
        let saved = self.saved_shortcut(engine);
        let changed = self.shortcut_changed(engine);
        let in_config = self.managed();
        let display = self.display_shortcut(engine);
        let can_save = self.can_save(engine);
        let busy = self.busy();

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
        } else if let Some(setup) = setup
            .as_ref()
            .filter(|s| !s.access_ready && !s.status.is_empty())
        {
            setup.status.clone()
        } else if picker {
            "Manual capture only — you'll choose a window each time".to_owned()
        } else if in_config && shortcut.registered {
            "Use your shortcut from another app".to_owned()
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

        // macOS hides setup once there is nothing left to do in it.
        let complete =
            session.permissions.is_some() && ready && permissions_ready && shortcut.registered;
        let setup_label = if on && session.ready && !session.setup_free && !complete {
            // The button is short: "Set up KDE capture".
            let name = if session.desktop == "kde" {
                "KDE"
            } else {
                desktop
            };
            if ready {
                "Manage capture".to_owned()
            } else if name.is_empty() {
                "Continue setup".to_owned()
            } else {
                format!("Set up {name} capture")
            }
        } else {
            String::new()
        };

        let keys = if self.recording {
            "Press shortcut…".to_owned()
        } else if (in_config && self.wizard.is_none())
            || (!is_pair(&display) && text(&display, "key").is_empty())
        {
            "Change shortcut".to_owned()
        } else if portal && is_pair(&display) {
            "Choose shortcut".to_owned()
        } else if !changed && !shortcut.label.is_empty() {
            shortcut.label.clone()
        } else {
            self.label(engine, &display)
        };

        let can_retry = shortcut.can_retry && !is_pair(&saved) && !in_config;
        let effects = match setup.as_ref().filter(|s| !s.effects.is_empty()) {
            Some(setup) => setup.effects.clone(),
            None if portal && !session.feedback_available => if session.desktop == "niri" {
                "Capture effects aren't available on Niri."
            } else {
                "Capture effects aren't available on this desktop."
            }
            .to_owned(),
            None => String::new(),
        };
        let screenshot_only = if available && !session.app_text {
            "This desktop only provides a screenshot."
        } else {
            ""
        };
        let toggle = |key: &str, unavailable: &str| {
            json!({"checked": unavailable.is_empty() && self.on(engine, key),
                "enabled": available && unavailable.is_empty(),
                "status": unavailable})
        };
        let sound = if self.on(engine, "snapShotPlaySound") {
            text(&json!({"s": self.setting(engine, "snapShotSound")}), "s")
        } else {
            "off".to_owned()
        };
        let sounds = [
            ("off", "Off"),
            ("soft-pop", "Whoosh (Default)"),
            ("camera-shutter", "Click"),
        ];
        let sound_label = sounds
            .iter()
            .find(|(value, _)| *value == sound)
            .map_or("", |(_, label)| label);
        let choices: Vec<Json> = sounds
            .iter()
            .map(|(value, label)| json!({"value": value, "label": label}))
            .collect();

        let wizard = self.wizard.as_ref().map_or(Json::Null, |wizard| {
            let access = wizard.step == ACCESS;
            let (heading, body): (String, String) = match (&setup, access) {
                (Some(setup), true) => (setup.heading.clone(), setup.body.clone()),
                (None, true) => {
                    let (heading, body) = if session.permissions.is_some() {
                        (
                            "Allow snapshots",
                            if permissions_ready {
                                "Test a snapshot of the current window. If macOS asks to bypass its window picker, choose Allow. The test image is discarded."
                            } else {
                                "Allow each permission, then continue."
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
                    (heading.into(), body.into())
                }
                (_, false) => (
                    "Choose your shortcut".into(),
                    if self.recording {
                        "Click the shortcut, then press the keys you want."
                    } else if portal {
                        "Choose your keys, then approve the permission prompt if asked."
                    } else {
                        "Use both Shift keys, or record a different shortcut."
                    }
                    .into(),
                ),
            };
            let advanced: Vec<Json> = match (&setup, access) {
                (Some(setup), true) => setup
                    .advanced
                    .iter()
                    .map(|o| json!({"action": o.action, "label": o.label, "note": o.note}))
                    .collect(),
                _ => Vec::new(),
            };
            let permission_rows: Vec<Json> = session.permissions.map_or_else(Vec::new, |p| {
                let text = self.include_accessibility(engine);
                vec![
                    json!({"id": "screen-recording", "title": "Screen Recording",
                        "description": "Capture the window you're using.",
                        "required": true, "granted": p.screen_recording}),
                    json!({"id": "accessibility", "title": "Accessibility",
                        "description": if text {
                            "Include text and controls from the captured app."
                        } else {
                            "Optional. Include text and controls from the captured app."
                        },
                        "required": text, "granted": p.accessibility}),
                ]
            });
            let continue_label = if self.testing {
                "Working…".to_owned()
            } else if busy {
                "Checking…".to_owned()
            } else if session.permissions.is_some() {
                "Test capture and continue".to_owned()
            } else if let Some(setup) = setup.as_ref().filter(|s| !s.action_label.is_empty()) {
                setup.action_label.clone()
            } else if ready {
                "Continue".to_owned()
            } else {
                "Try again".to_owned()
            };
            let details = if !wizard.error.is_empty() {
                wizard.error.clone()
            } else if !access || session.permissions.is_some() {
                String::new()
            } else if let Some(setup) = &setup {
                setup.details.clone()
            } else {
                session.message.clone()
            };
            let same = self
                .flow
                .preview
                .as_ref()
                .is_some_and(|p| p.before == p.after);
            json!({
                "step": wizard.step,
                "busy": busy,
                "permissionRows": permission_rows,
                "permissionsBusy": self.testing,
                "permissionsError": session.permissions_error,
                "continueEnabled": !self.testing && (session.permissions.is_none() || permissions_ready),
                "title": if desktop.is_empty() {
                    "Set up snapshots".to_owned()
                } else {
                    format!("Set up snapshots for {desktop}")
                },
                "heading": heading,
                "body": body,
                "details": details,
                // The access step's own button runs this setup step, else
                // checks again or continues.
                "action": match (&setup, access) {
                    (Some(setup), true) => setup.action.clone(),
                    _ => String::new(),
                },
                "checkMessage": match (&setup, access && wizard.checked && !busy) {
                    (Some(setup), true) => setup.check_message.clone(),
                    _ => String::new(),
                },
                "advanced": advanced,
                "attention": if !access && !ready {
                    "Capture needs attention. Go back to check access."
                } else {
                    ""
                },
                "closeLabel": if wizard.was_enabled { "Close" } else { "Finish later" },
                "continueLabel": continue_label,
                "doneLabel": if changed { "Save and finish" } else { "Done" },
                "doneEnabled": ready && if in_config {
                    self.flow.saved || same
                } else if changed {
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
                "managed": in_config,
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
            "sound": {"value": sound, "label": sound_label, "choices": choices},
            "flash": toggle("snapShotFlash", &effects),
            "animations": toggle("snapShotAnimations", &effects),
            "wizard": wizard,
            "config": self.config_state(engine),
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
            testing: false,
            resume_checked: false,
            resume_shown: true,
            resume: String::new(),
            recording: false,
            held: BTreeSet::new(),
            candidate: None,
            check: None,
            checking: false,
            checks_owed: 0,
            last_target: String::new(),
            timers: HashMap::new(),
            max_image_bytes: MAX_IMAGE_BYTES,
            published: Json::Null,
            config_tools: None,
            config: None,
            job: None,
            flow: ConfigFlow::default(),
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
            // The user may have changed capture access or the shortcut while away.
            if let Ok(app) = engine.singleton::<Application>() {
                let me = self.me.clone();
                let _ = engine.connect_by_name(app, "stateChanged", move |engine, _| {
                    later(engine, &me, |c, e| c.on_application_state(e));
                });
            }
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
        if let Some(job) = self.job.take() {
            let _ = job.join();
        }
        let _ = self.backend.release();
    }
}
