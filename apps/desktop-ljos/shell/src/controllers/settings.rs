//! `settings`, desktop-qt's SettingsController: the settings the shell reads
//! and changes, in two stores, and the `Settings` QML singleton over them.
//!
//! The MC's settings document (`hal-c2.readSettings` /
//! `hal-c2.writeSettings`, apps/server-ex lib/hal_c2/settings.ex): one
//! versioned document every client of the environment shares. A change is
//! an edit of the whole document written at the version it was read at;
//! when another client saved first the MC refuses it as stale, and the edit
//! is applied again to what the MC now holds, so no one's change is lost to
//! a stale copy. The MC's `config` shape comes with it: the server config,
//! and the themes the MC publishes.
//!
//! This device's preferences (`<config dir>/preferences.json`): what
//! belongs to this desktop and no other client, such as its appearance.
//! They are here before the MC is.
//!
//! Controllers reach it through [`Settings::of`], a handle that is never
//! busy: its state is not the controller's, so a QML binding that reads a
//! setting while a controller runs reads it. Its change hooks run once no
//! controller is running (`Bridge::defer`), so a hook may reach the
//! controller whose write set it off.
//!
//! ```ignore
//! let settings = Settings::of(engine);
//! settings.write(engine, "textGenerationModelSelection.provider", json!("codex"));
//! settings.write_device(engine, "appearance", json!("dark"));
//! settings.on_device_changed(|engine| ...);
//! ```
//!
//! The rows of the settings pages go through `setting` / `set` / `reset`,
//! which know which store a key is in and its default. Failures are toasted.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use ljos::prelude::QmlValue;
use ljos::prelude::{Atom, Cx, Engine, QmlObject, Value, qml_impl, qml_singleton};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init};
use crate::controllers::settings_scope::SettingsScope;
use crate::controllers::toasts::Toasts;
use crate::json::Json;
use crate::mc::{Frame, McError, SubId};

/// A settings document.
pub type Map = serde_json::Map<String, Json>;
/// The whole new document from the current one.
pub type Edit = Rc<dyn Fn(&Map) -> Map>;
/// How a change went: why it failed, or `None`.
pub type Done = Box<dyn FnOnce(&Engine, Option<String>)>;
type Hook = Rc<dyn Fn(&Engine)>;
type Then = Box<dyn FnOnce(&Engine)>;

/// Saves over a stale copy before giving up: each retry is another editor
/// saving in between, which is rare, and never endless.
pub const STALE_RETRIES: u32 = 3;

pub const NOT_LOADED: &str = "The MC's settings are not loaded.";
pub const KEPT_CHANGING: &str = "Settings kept changing elsewhere; not saved.";
pub const NOWHERE: &str = "This device has nowhere to keep its preferences.";
pub const ENVIRONMENT_WIDE: &str = "Environment-wide setting. Select an environment to change it.";

/// A row of the settings pages: the store its key is in and its default.
/// Device rows are this device's; MC rows are the MC document's, which
/// leaves them out while at their default.
struct Row {
    key: &'static str,
    device: bool,
    fallback: fn() -> Json,
}

macro_rules! rows {
    ($($key:literal, $device:literal, $fallback:tt;)*) => {
        &[$(Row { key: $key, device: $device, fallback: || json!($fallback) },)*]
    };
}

static ROWS: &[Row] = rows![
    // General (packages/contracts settings.ts).
    "sidebarProjectGroupingMode", true, "repository";
    "autoResumeLimitedThreads", false, false;
    "snoozeLimitedThreads", false, false;
    "sidebarAutoSettleOnMerge", false, true;
    "sidebarAutoSettleAfterDays", false, 3;
    "notificationMode", true, "off";
    "inAppNotificationsEnabled", true, false;
    "timestampFormat", true, "locale";
    "responseStreamingMode", false, "paragraph";
    "diffIgnoreWhitespace", true, true;
    // The web starts diffs collapsed; the desktop has always opened them,
    // and keeps to that until told otherwise.
    "diffFilesCollapsed", true, false;
    "diffLayout", true, "stacked";
    "proactivePanelsEnabled", true, false;
    "showSkillsInSlashMenu", true, true;
    "composerRichTextEnabled", true, true;
    "composerCollapseOnScroll", true, true;
    "composerVimKeys", true, false;
    "sendShortcut", true, "enter";
    "followUpBehavior", true, "steer";
    "enableProviderUpdateChecks", false, true;
    "continueThreadsAfterServerUpdate", false, false;
    "newWorktreesStartFromOrigin", false, true;
    "addProjectBaseDirectory", false, "";
    "confirmThreadUnpin", true, false;
    "confirmThreadArchive", true, false;
    "confirmThreadDelete", true, true;
    "confirmQuit", true, "hold";
    "planModeEnabled", true, false;
    "contextWindowMeterEnabled", true, false;
    "legacySidebarEnabled", true, false;
    // Appearance.
    "appearanceContrast", true, 100;
    "glassOpacity", true, 96;
    "environmentIdentificationMode", true, "artwork";
    "diffColorScheme", true, "red-green";
    "persistComposerContextStrip", true, false;
    "panelAnimationDurationMs", true, 0;
    "reduceMotion", true, false;
    "fontSizeInterface", true, 16;
    "fontSizePrompt", true, 14;
    "fontSizeCode", true, 13;
    "fontSizeTerminal", true, 12;
    "fontFamilySans", true, "";
    "fontFamilyComposer", true, "";
    "fontFamilyCode", true, "";
    "fontFamilyTerminal", true, "";
    "fontSmoothing", true, true;
    "wordWrap", true, true;
    // SnapShots (SnapShotController).
    "snapShotEnabled", true, false;
    "snapShotIncludeAccessibility", true, true;
    "snapShotShortcut", true, {"kind": "both-shift-keys"};
    "snapShotPlaySound", true, true;
    "snapShotSound", true, "soft-pop";
    "snapShotFlash", true, true;
    "snapShotAnimations", true, true;
];

fn row_of(key: &str) -> Option<&'static Row> {
    ROWS.iter().find(|r| r.key == key)
}

/// The MC's rows a project can override (packages/contracts
/// ProjectSettingsOverrides).
pub fn project_overridable(key: &str) -> bool {
    matches!(
        key,
        "newWorktreesStartFromOrigin"
            | "sidebarAutoSettleOnMerge"
            | "sidebarAutoSettleAfterDays"
            | "continueThreadsAfterServerUpdate"
            | "responseStreamingMode"
    )
}

/// A row's stored value on one environment: the project's override when
/// the scope is a project and it has one, else the environment's; `None`
/// when unset.
fn stored_in(settings: &Map, project_id: &str, key: &str) -> Option<Json> {
    if !project_id.is_empty()
        && project_overridable(key)
        && let Some(value) = SettingsScope::override_of(settings, project_id, key)
    {
        return Some(value);
    }
    settings.get(key).cloned()
}

/// JSON equality as Qt's: numbers by value, so `3` is `3.0` (QML hands
/// numbers over as either).
pub fn same(a: &Json, b: &Json) -> bool {
    match (a, b) {
        (Json::Number(x), Json::Number(y)) => x.as_f64() == y.as_f64(),
        (Json::Array(x), Json::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(a, b)| same(a, b))
        }
        (Json::Object(x), Json::Object(y)) => same_map(x, y),
        _ => a == b,
    }
}

pub fn same_map(a: &Map, b: &Map) -> bool {
    a.len() == b.len() && a.iter().all(|(k, v)| b.get(k).is_some_and(|w| same(v, w)))
}

/// What QML passed, its whole numbers as integers: QJsonDocument writes
/// `3.0` as `3`, and the MC tells the two apart.
pub fn tidy(json: Json) -> Json {
    match json {
        Json::Number(n) if !n.is_i64() && !n.is_u64() => match n.as_f64() {
            Some(f) if f.fract() == 0.0 && f.abs() < 9.0e15 => Json::from(f as i64),
            _ => Json::Number(n),
        },
        Json::Array(items) => Json::Array(items.into_iter().map(tidy).collect()),
        Json::Object(map) => Json::Object(map.into_iter().map(|(k, v)| (k, tidy(v))).collect()),
        other => other,
    }
}

/// `object` with the value at `path` set; null removes it.
fn with_path(mut object: Map, path: &[&str], value: &Json) -> Map {
    let Some((key, rest)) = path.split_first() else {
        return object;
    };
    if rest.is_empty() {
        if value.is_null() {
            object.remove(*key);
        } else {
            object.insert((*key).to_owned(), value.clone());
        }
        return object;
    }
    let inner = match object.get(*key) {
        Some(Json::Object(inner)) => inner.clone(),
        _ => Map::new(),
    };
    object.insert(
        (*key).to_owned(),
        Json::Object(with_path(inner, rest, value)),
    );
    object
}

#[derive(Default)]
struct State {
    active: bool,
    ready: bool,
    /// The config subscription, and the environment it names.
    subscription: Option<SubId>,
    followed: String,
    settings: Map,
    version: i64,
    error: String,
    /// Bumped by every read and save; a read's answer lands only if
    /// nothing was read or saved since it was asked.
    generation: u64,
    config: Map,
    themes: Vec<Json>,
    device_path: Option<PathBuf>,
    device: Map,
    device_error: String,
    /// The preferences file exists but is not a JSON object. Saving is
    /// refused until it reads again, so defaults never replace what the
    /// user saved.
    device_unreadable: bool,
}

#[derive(Default)]
struct Hooks {
    settings: Vec<Hook>,
    config: Vec<Hook>,
    keybindings: Vec<Hook>,
    themes: Vec<Hook>,
    device: Vec<Hook>,
}

#[derive(Clone, Copy)]
enum Signal {
    Settings,
    Config,
    KeybindingsPushed,
    Themes,
    Device,
}

#[derive(Default)]
struct Inner {
    state: RefCell<State>,
    hooks: RefCell<Hooks>,
}

#[derive(Default)]
struct Slot(RefCell<Option<Settings>>);

/// The settings, from Rust: a handle, cheap to clone.
#[derive(Clone, Default)]
pub struct Settings(Rc<Inner>);

impl std::fmt::Debug for Settings {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let state = self.0.state.borrow();
        f.debug_struct("Settings")
            .field("ready", &state.ready)
            .field("version", &state.version)
            .finish_non_exhaustive()
    }
}

impl Settings {
    /// The engine's settings.
    pub fn of(engine: &Engine) -> Settings {
        let slot = engine.extension::<Slot>();
        if let Some(settings) = slot.0.borrow().clone() {
            return settings;
        }
        let settings = Settings::default();
        *slot.0.borrow_mut() = Some(settings.clone());
        for signal in [
            Signal::Settings,
            Signal::Config,
            Signal::Themes,
            Signal::Device,
        ] {
            settings.show(engine, signal);
        }
        settings
    }

    // -- Reading ---------------------------------------------------------

    /// The MC's document has been read since the shell connected.
    pub fn ready(&self) -> bool {
        self.0.state.borrow().ready
    }

    pub fn settings(&self) -> Map {
        self.0.state.borrow().settings.clone()
    }

    pub fn version(&self) -> i64 {
        self.0.state.borrow().version
    }

    /// Why the last read or change failed; empty once one succeeds.
    pub fn error(&self) -> String {
        self.0.state.borrow().error.clone()
    }

    /// The MC's ServerConfig (packages/contracts server.ts), as `config`
    /// frames keep it.
    pub fn config(&self) -> Map {
        self.0.state.borrow().config.clone()
    }

    /// EnvironmentTheme[] the MC publishes (`config.themes`).
    pub fn themes(&self) -> Vec<Json> {
        self.0.state.borrow().themes.clone()
    }

    /// A value in the MC's document by dotted path; `None` when absent.
    pub fn value(&self, path: &str) -> Option<Json> {
        let state = self.0.state.borrow();
        let mut parts = path.split('.');
        let mut current = state.settings.get(parts.next()?)?;
        for part in parts {
            current = current.as_object()?.get(part)?;
        }
        Some(current.clone())
    }

    pub fn device(&self) -> Map {
        self.0.state.borrow().device.clone()
    }

    pub fn device_value(&self, key: &str) -> Option<Json> {
        self.0.state.borrow().device.get(key).cloned()
    }

    /// Why this device's preferences could not be read or saved; empty
    /// otherwise.
    pub fn device_error(&self) -> String {
        self.0.state.borrow().device_error.clone()
    }

    pub fn device_unreadable(&self) -> bool {
        self.0.state.borrow().device_unreadable
    }

    pub fn device_path(&self) -> Option<PathBuf> {
        self.0.state.borrow().device_path.clone()
    }

    // -- Change hooks: each runs once no controller is running. ----------

    /// The document, its version, `ready` or `error` changed; or the
    /// settings scope did (what `setting` and `mixed` say).
    pub fn on_settings_changed(&self, f: impl Fn(&Engine) + 'static) {
        self.0.hooks.borrow_mut().settings.push(Rc::new(f));
    }

    pub fn on_config_changed(&self, f: impl Fn(&Engine) + 'static) {
        self.0.hooks.borrow_mut().config.push(Rc::new(f));
    }

    /// The MC pushed changed keybindings (`config.keybindings`), not the
    /// snapshot a subscription starts with.
    pub fn on_keybindings_pushed(&self, f: impl Fn(&Engine) + 'static) {
        self.0.hooks.borrow_mut().keybindings.push(Rc::new(f));
    }

    pub fn on_themes_changed(&self, f: impl Fn(&Engine) + 'static) {
        self.0.hooks.borrow_mut().themes.push(Rc::new(f));
    }

    pub fn on_device_changed(&self, f: impl Fn(&Engine) + 'static) {
        self.0.hooks.borrow_mut().device.push(Rc::new(f));
    }

    /// Tells the `Settings` object and then the hooks.
    fn emit(&self, engine: &Engine, signal: Signal) {
        self.show(engine, signal);
        let hooks = {
            let hooks = self.0.hooks.borrow();
            match signal {
                Signal::Settings => hooks.settings.clone(),
                Signal::Config => hooks.config.clone(),
                Signal::KeybindingsPushed => hooks.keybindings.clone(),
                Signal::Themes => hooks.themes.clone(),
                Signal::Device => hooks.device.clone(),
            }
        };
        let bridge = Bridge::of(engine);
        for hook in hooks {
            bridge.defer(engine, move |engine| hook(engine));
        }
    }

    /// The scope changed what the MC's rows read.
    pub(crate) fn scope_changed(&self, engine: &Engine) {
        self.emit(engine, Signal::Settings);
    }

    /// Sets the `Settings` object's properties for `signal`.
    fn show(&self, engine: &Engine, signal: Signal) {
        let Ok(obj) = engine.singleton::<SettingsObject>() else {
            return;
        };
        let cx = Cx::new(engine, obj);
        let object = |map: &Map| Json::Object(map.clone()).to_value();
        match signal {
            Signal::Settings => {
                let (ready, document, version, error) = {
                    let s = self.0.state.borrow();
                    (s.ready, s.settings.clone(), s.version, s.error.clone())
                };
                engine.batch(|| {
                    let _ = cx.set(SettingsObject::READY, ready);
                    // Anew each time: a binding that reads `document` to
                    // follow `setting()` re-runs on a scope change too.
                    let _ = cx.set(SettingsObject::DOCUMENT, object(&document));
                    let _ = cx.set(
                        SettingsObject::VERSION,
                        i32::try_from(version).unwrap_or(i32::MAX),
                    );
                    let _ = cx.set(SettingsObject::ERROR, Atom::from(error.as_str()));
                });
            }
            Signal::Config => {
                let config = self.0.state.borrow().config.clone();
                let _ = cx.set(SettingsObject::CONFIG, object(&config));
            }
            Signal::Themes => {
                let themes = Json::Array(self.0.state.borrow().themes.clone());
                let _ = cx.set(SettingsObject::THEMES, themes.to_value());
            }
            Signal::Device => {
                let (device, error) = {
                    let s = self.0.state.borrow();
                    (s.device.clone(), s.device_error.clone())
                };
                engine.batch(|| {
                    let _ = cx.set(SettingsObject::DEVICE, object(&device));
                    let _ = cx.set(SettingsObject::DEVICE_ERROR, Atom::from(error.as_str()));
                });
            }
            Signal::KeybindingsPushed => {}
        }
    }

    // -- The MC's document -------------------------------------------------

    /// Subscribes to the MC's config and reads its settings.
    pub(crate) fn activate(&self, engine: &Engine) {
        if std::mem::replace(&mut self.0.state.borrow_mut().active, true) {
            return;
        }
        self.follow(engine);
    }

    /// A reconnect may reach a restarted MC, whose versions start again;
    /// the config snapshot that follows the re-sent subscription reads them
    /// afresh.
    pub(crate) fn ready_changed(&self, engine: &Engine, ready: bool) {
        let active = self.0.state.borrow().active;
        if ready && active {
            self.follow(engine);
        }
        let dropped = {
            let mut s = self.0.state.borrow_mut();
            if ready || !s.ready {
                false
            } else {
                s.ready = false;
                s.generation += 1;
                true
            }
        };
        if dropped {
            self.emit(engine, Signal::Settings);
        }
    }

    /// Follows the config of the environment the MC serves.
    fn follow(&self, engine: &Engine) {
        let Some(mc) = controller::mc(engine) else {
            return;
        };
        let environment = mc.environment();
        let old = {
            let mut s = self.0.state.borrow_mut();
            if s.subscription.is_some() && s.followed == environment {
                return;
            }
            s.followed = environment.clone();
            s.subscription.take()
        };
        if let Some(old) = old {
            mc.unsubscribe(old);
        }
        let me = Rc::downgrade(&self.0);
        // `usageLimitsCommand`: this client answers /usage-limits itself
        // (the composer).
        let id = mc.subscribe(
            json!({"type": "config", "environment": environment, "usageLimitsCommand": true}),
            Box::new(move |engine: &Engine, frame: &Frame| {
                if let Some(inner) = me.upgrade() {
                    Settings(inner).on_config(engine, frame);
                }
            }),
            None,
        );
        self.0.state.borrow_mut().subscription = Some(id);
    }

    fn on_config(&self, engine: &Engine, frame: &Frame) {
        let field = |key: &str| frame.get(key).cloned().unwrap_or(Json::Null);
        match frame.get("t").and_then(Json::as_str).unwrap_or_default() {
            "config" => {
                let config = match field("config") {
                    Json::Object(config) => config,
                    _ => Map::new(),
                };
                let changed = {
                    let mut s = self.0.state.borrow_mut();
                    let changed = !same_map(&config, &s.config);
                    if changed {
                        s.config = config;
                    }
                    changed
                };
                if changed {
                    self.emit(engine, Signal::Config);
                }
                // The snapshot after every (re)subscription: the document
                // may have moved on.
                self.read(engine, None);
            }
            "config.settings" => {
                self.0
                    .state
                    .borrow_mut()
                    .config
                    .insert("settings".into(), field("settings"));
                self.emit(engine, Signal::Config);
                // The frame has no version to save against; the read brings
                // one.
                self.read(engine, None);
            }
            "config.providers" => {
                self.0
                    .state
                    .borrow_mut()
                    .config
                    .insert("providers".into(), field("providers"));
                self.emit(engine, Signal::Config);
            }
            "config.keybindings" => {
                self.0
                    .state
                    .borrow_mut()
                    .config
                    .insert("keybindingRules".into(), field("rules"));
                self.emit(engine, Signal::Config);
                self.emit(engine, Signal::KeybindingsPushed);
            }
            "config.themes" => {
                let themes = match field("themes") {
                    Json::Array(themes) => themes,
                    _ => Vec::new(),
                };
                self.set_themes(engine, themes);
            }
            _ => {}
        }
    }

    /// What `config.themes` delivers; tests set it.
    pub fn set_themes(&self, engine: &Engine, themes: Vec<Json>) {
        {
            let mut s = self.0.state.borrow_mut();
            if same(&Json::Array(themes.clone()), &Json::Array(s.themes.clone())) {
                return;
            }
            s.themes = themes;
        }
        self.emit(engine, Signal::Themes);
    }

    fn read(&self, engine: &Engine, then: Option<Then>) {
        let Some(mc) = controller::mc(engine) else {
            return;
        };
        let generation = {
            let mut s = self.0.state.borrow_mut();
            s.generation += 1;
            s.generation
        };
        let me = self.clone();
        mc.call(
            &mc.environment(),
            "hal-c2.readSettings",
            json!({}),
            Box::new(move |engine: &Engine, result: Result<Json, McError>| {
                // Answers land out of order: a read asked before a save may
                // arrive after it. What waits on it goes on with what is
                // newer.
                if generation != me.0.state.borrow().generation {
                    if let Some(then) = then {
                        then(engine);
                    }
                    return;
                }
                let answer = match result {
                    Ok(answer) => answer,
                    Err(error) => {
                        me.fail(engine, &error.message);
                        if let Some(then) = then {
                            then(engine);
                        }
                        return;
                    }
                };
                let settings = match answer.get("settings") {
                    Some(Json::Object(settings)) => settings.clone(),
                    _ => Map::new(),
                };
                let version = answer.get("version").and_then(Json::as_i64).unwrap_or(0);
                let changed = {
                    let mut s = me.0.state.borrow_mut();
                    let changed = !s.ready
                        || !same_map(&settings, &s.settings)
                        || version != s.version
                        || !s.error.is_empty();
                    s.settings = settings;
                    s.version = version;
                    s.ready = true;
                    s.error.clear();
                    changed
                };
                if changed {
                    me.emit(engine, Signal::Settings);
                }
                if let Some(then) = then {
                    then(engine);
                }
            }),
        );
    }

    /// Applies `edit` to the MC's document and saves it; `done` says how it
    /// went. A stale save re-reads and applies `edit` again, a few times.
    pub fn change(
        &self,
        engine: &Engine,
        edit: impl Fn(&Map) -> Map + 'static,
        done: impl FnOnce(&Engine, Option<String>) + 'static,
    ) {
        self.attempt(engine, Rc::new(edit), Box::new(done), STALE_RETRIES);
    }

    fn attempt(&self, engine: &Engine, edit: Edit, done: Done, retries: u32) {
        let (ready, current, version) = {
            let s = self.0.state.borrow();
            (s.ready, s.settings.clone(), s.version)
        };
        if !ready {
            self.fail(engine, NOT_LOADED);
            done(engine, Some(NOT_LOADED.to_owned()));
            return;
        }
        let next = edit(&current);
        if same_map(&next, &current) {
            done(engine, None);
            return;
        }
        let Some(mc) = controller::mc(engine) else {
            done(engine, Some("not connected".to_owned()));
            return;
        };
        let generation = {
            let mut s = self.0.state.borrow_mut();
            s.generation += 1;
            s.generation
        };
        let me = self.clone();
        mc.call(
            &mc.environment(),
            "hal-c2.writeSettings",
            json!({"settings": next, "version": version}),
            Box::new(move |engine: &Engine, result: Result<Json, McError>| {
                let answer = match result {
                    Ok(answer) => answer,
                    Err(error) => {
                        let stale = error.detail.get("_tag").and_then(Json::as_str)
                            == Some("StaleSettings");
                        if stale && retries > 0 {
                            // Another client saved first: apply the edit to
                            // what it saved.
                            let again = me.clone();
                            me.read(
                                engine,
                                Some(Box::new(move |engine| {
                                    again.attempt(engine, edit, done, retries - 1)
                                })),
                            );
                            return;
                        }
                        let message = if stale {
                            KEPT_CHANGING.to_owned()
                        } else {
                            error.message
                        };
                        me.fail(engine, &message);
                        done(engine, Some(message));
                        return;
                    }
                };
                // A read overtaken by this save is dropped; this is newer.
                let landed = {
                    let mut s = me.0.state.borrow_mut();
                    let landed = generation == s.generation;
                    if landed {
                        s.version = answer
                            .get("version")
                            .and_then(Json::as_i64)
                            .unwrap_or(s.version + 1);
                        s.settings = next;
                        s.error.clear();
                    }
                    landed
                };
                if landed {
                    me.emit(engine, Signal::Settings);
                }
                done(engine, None);
            }),
        );
    }

    fn fail(&self, engine: &Engine, error: &str) {
        self.0.state.borrow_mut().error = error.to_owned();
        self.emit(engine, Signal::Settings);
    }

    /// Sets one value of the MC's document by dotted path; null removes it.
    /// A failure is toasted.
    pub fn write(&self, engine: &Engine, path: &str, value: Json) {
        let keys: Vec<String> = path
            .split('.')
            .filter(|k| !k.is_empty())
            .map(str::to_owned)
            .collect();
        if keys.is_empty() {
            return;
        }
        self.change(
            engine,
            move |settings| {
                let keys: Vec<&str> = keys.iter().map(String::as_str).collect();
                with_path(settings.clone(), &keys, &value)
            },
            |engine, error| {
                if let Some(error) = error {
                    toast(engine, "Setting not saved", &error);
                }
            },
        );
    }

    // -- This device's preferences ---------------------------------------

    /// This device's preferences file; read now, and saved there on change.
    pub fn set_device_path(&self, engine: &Engine, path: Option<PathBuf>) {
        let mut device = Map::new();
        let mut error = String::new();
        if let Some(path) = &path
            && path.exists()
        {
            match std::fs::read(path)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Json>(&bytes).ok())
            {
                Some(Json::Object(read)) => device = read,
                _ => error = format!("Cannot read {}", path.display()),
            }
        }
        {
            let mut s = self.0.state.borrow_mut();
            s.device_path = path;
            s.device = device;
            s.device_unreadable = !error.is_empty();
            s.device_error = error;
        }
        self.emit(engine, Signal::Device);
    }

    /// Reads the preferences file again.
    pub fn reload_device(&self, engine: &Engine) {
        let path = self.device_path();
        self.set_device_path(engine, path);
    }

    /// Replaces this device's preferences; false (and `device_error`) when
    /// they cannot be saved, leaving them as they were.
    pub fn set_device_settings(&self, engine: &Engine, device: Map) -> bool {
        let (unchanged, unreadable, path) = {
            let s = self.0.state.borrow();
            (
                same_map(&device, &s.device),
                s.device_unreadable,
                s.device_path.clone(),
            )
        };
        if unchanged {
            return true;
        }
        let error = match (&path, unreadable) {
            (Some(path), true) => Some(format!("Cannot read {}", path.display())),
            (None, _) => Some(NOWHERE.to_owned()),
            (Some(path), false) => save(path, &device)
                .err()
                .map(|_| format!("Cannot save {}", path.display())),
        };
        let saved = error.is_none();
        {
            let mut s = self.0.state.borrow_mut();
            match error {
                Some(error) => s.device_error = error,
                None => {
                    s.device = device;
                    s.device_error.clear();
                }
            }
        }
        self.emit(engine, Signal::Device);
        saved
    }

    /// One preference; null removes it. A failure is toasted.
    pub fn write_device(&self, engine: &Engine, key: &str, value: Json) -> bool {
        let device = with_path(self.device(), &[key], &value);
        if self.set_device_settings(engine, device) {
            return true;
        }
        toast(engine, "Setting not saved", &self.device_error());
        false
    }

    // -- The rows of the settings pages ----------------------------------

    /// The scope a row of the MC's goes through: none for this device's
    /// rows, or while the scope is only this machine's own document.
    fn scope_for(&self, engine: &Engine, key: &str) -> Option<SettingsScope> {
        let row = row_of(key)?;
        if row.device {
            return None;
        }
        let scope = SettingsScope::of(engine);
        let targets = scope.targets();
        if targets.is_empty() {
            return None;
        }
        let local = controller::mc(engine).map(|mc| mc.environment());
        if !scope.project_scope() && local.is_some_and(|local| targets == [local]) {
            return None;
        }
        Some(scope)
    }

    /// A row's value, its default when unset; `None` for an unknown key.
    pub fn setting(&self, engine: &Engine, key: &str) -> Option<Json> {
        let row = row_of(key)?;
        if let Some(scope) = self.scope_for(engine, key) {
            let reading = scope.read(|settings, project| stored_in(settings, project, key));
            if reading.known > 0 {
                return Some(reading.value.unwrap_or_else(row.fallback));
            }
        }
        let s = self.0.state.borrow();
        let store = if row.device { &s.device } else { &s.settings };
        // An explicit null is a value (inactive settling off), an absent
        // key is not.
        Some(store.get(key).cloned().unwrap_or_else(row.fallback))
    }

    pub fn default_of(&self, key: &str) -> Option<Json> {
        row_of(key).map(|r| (r.fallback)())
    }

    pub fn is_default(&self, engine: &Engine, key: &str) -> bool {
        let Some(row) = row_of(key) else {
            return true;
        };
        let fallback = (row.fallback)();
        if let Some(scope) = self.scope_for(engine, key) {
            // A project is at its default while it inherits; environments
            // while none holds another value.
            let project = scope.project_scope() && project_overridable(key);
            let reading = scope.read(|settings, project_id| {
                Some(Json::Bool(if project {
                    SettingsScope::override_of(settings, project_id, key).is_none()
                } else {
                    settings.get(key).is_none_or(|v| same(v, &fallback))
                }))
            });
            if reading.known > 0 {
                return !reading.mixed && reading.value == Some(Json::Bool(true));
            }
        }
        let s = self.0.state.borrow();
        let store = if row.device { &s.device } else { &s.settings };
        store.get(key).is_none_or(|v| same(v, &fallback))
    }

    /// The selected environments disagree on the row.
    pub fn mixed(&self, engine: &Engine, key: &str) -> bool {
        let (Some(scope), Some(row)) = (self.scope_for(engine, key), row_of(key)) else {
            return false;
        };
        // An environment that leaves the row unset holds its default.
        scope
            .read(|settings, project| {
                Some(stored_in(settings, project, key).unwrap_or_else(row.fallback))
            })
            .mixed
    }

    /// Why the row cannot be changed at this scope; empty when it can.
    pub fn disabled_reason(&self, engine: &Engine, key: &str) -> String {
        let Some(row) = row_of(key) else {
            return String::new();
        };
        if row.device {
            return String::new();
        }
        let scope = SettingsScope::of(engine);
        if scope.project_scope() && !project_overridable(key) {
            return ENVIRONMENT_WIDE.to_owned();
        }
        if self.scope_for(engine, key).is_some() {
            scope.disabled_reason(engine)
        } else {
            String::new()
        }
    }

    /// The selected environments that are out of reach, by label: a change
    /// leaves them as they were.
    pub fn unreachable(&self, engine: &Engine) -> Vec<String> {
        let scope = SettingsScope::of(engine);
        scope
            .environments(engine)
            .into_iter()
            .filter(|id| !scope.online(engine, id))
            .map(|id| scope.label(engine, &id))
            .collect()
    }

    /// Whether every selected environment is connected and has the
    /// capability (ServerConfig environment.capabilities).
    pub fn supports(&self, engine: &Engine, capability: &str) -> bool {
        let scope = SettingsScope::of(engine);
        let targets = scope.targets();
        !targets.is_empty()
            && targets.iter().all(|id| scope.settings(id).is_some())
            && scope.lacking(capability).is_empty()
    }

    /// Whether a row is kept on this device rather than by the MC.
    pub fn on_device(&self, key: &str) -> bool {
        row_of(key).is_some_and(|r| r.device)
    }

    /// Changes a row in the store it belongs to; its default is stored as
    /// absence, so a row at its default offers no reset.
    pub fn set(&self, engine: &Engine, key: &str, value: Json) {
        let Some(row) = row_of(key) else { return };
        let value = tidy(value);
        let absent = same(&value, &(row.fallback)());
        if row.device {
            let mut device = self.device();
            if absent {
                device.remove(key);
            } else {
                device.insert(key.to_owned(), value);
            }
            if !self.set_device_settings(engine, device) {
                toast(engine, "Setting not saved", &self.device_error());
            }
            return;
        }
        let reason = self.disabled_reason(engine, key);
        if !reason.is_empty() {
            toast(engine, "Setting not saved", &reason);
            return;
        }
        if let Some(scope) = self.scope_for(engine, key) {
            let project = scope.project_scope();
            let key = key.to_owned();
            scope.write(
                engine,
                move |mut settings, project_id| {
                    // A project keeps its own value as an override.
                    if project {
                        return SettingsScope::with_override(
                            settings,
                            project_id,
                            &key,
                            Some(value.clone()),
                        );
                    }
                    // Each environment holds what was chosen, its default
                    // too: what it would otherwise fall back to is its own.
                    settings.insert(key.clone(), value.clone());
                    settings
                },
                "",
            );
            // An environment out of reach keeps what it had.
            let skipped = self.unreachable(engine);
            if !skipped.is_empty() {
                let title = format!("Not updated: {}", skipped.join(", "));
                Bridge::of(engine).defer(engine, move |engine| {
                    controller::with::<Toasts, _>(engine, |toasts, engine| {
                        toasts.show(
                            engine,
                            "warning",
                            &title,
                            "An offline environment keeps its settings until they are changed while it is connected.",
                            None,
                            crate::controllers::toasts::DEFAULT_TIMEOUT_MS,
                        );
                    });
                });
            }
            return;
        }
        let key = key.to_owned();
        self.change(
            engine,
            move |settings| {
                let mut settings = settings.clone();
                if absent {
                    settings.remove(&key);
                } else {
                    settings.insert(key.clone(), value.clone());
                }
                settings
            },
            |engine, error| {
                if let Some(error) = error {
                    toast(engine, "Setting not saved", &error);
                }
            },
        );
    }

    /// Back to the row's default; a project goes back to inheriting its
    /// environment's value.
    pub fn reset(&self, engine: &Engine, key: &str) {
        if let Some(scope) = self.scope_for(engine, key)
            && scope.project_scope()
            && project_overridable(key)
        {
            let key = key.to_owned();
            scope.write(
                engine,
                move |settings, project_id| {
                    SettingsScope::with_override(settings, project_id, &key, None)
                },
                "",
            );
            return;
        }
        if let Some(fallback) = self.default_of(key) {
            self.set(engine, key, fallback);
        }
    }

    /// Resets rows together: one save of this device's and one of the
    /// MC's.
    pub fn reset_all(&self, engine: &Engine, keys: &[String]) {
        let mut device = self.device();
        let mut mc = Vec::new();
        for key in keys {
            let Some(row) = row_of(key) else { continue };
            if row.device {
                device.remove(key);
            } else {
                mc.push(key.clone());
            }
        }
        if !self.set_device_settings(engine, device) {
            toast(engine, "Settings not restored", &self.device_error());
        }
        if mc.is_empty() {
            return;
        }
        self.change(
            engine,
            move |settings| {
                let mut settings = settings.clone();
                for key in &mc {
                    settings.remove(key);
                }
                settings
            },
            |engine, error| {
                if let Some(error) = error {
                    toast(engine, "Settings not restored", &error);
                }
            },
        );
    }
}

/// Saves `device` at `path` whole or not at all (QSaveFile).
fn save(path: &Path, device: &Map) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut text = serde_json::to_vec_pretty(device).map_err(std::io::Error::other)?;
    text.push(b'\n');
    let mut temp = path.as_os_str().to_owned();
    temp.push(format!(".{}.tmp", std::process::id()));
    let temp = PathBuf::from(temp);
    let written = std::fs::write(&temp, &text).and_then(|()| std::fs::rename(&temp, path));
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written
}

/// An error toast, once no controller is running.
fn toast(engine: &Engine, title: &str, reason: &str) {
    let (title, reason) = (title.to_owned(), reason.to_owned());
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<Toasts, _>(engine, |toasts, engine| {
            toasts.error(engine, &title, &reason);
        });
    });
}

/// `Settings` in QML.
///
/// ```qml
/// Settings.setting("wordWrap"); Settings.set("wordWrap", false)
/// Settings.document.enableAssistantStreaming; Settings.device.appearance
/// ```
///
/// `setting()` is a call, not a property: a binding that must follow it
/// reads `document` or `device` too, which change whenever what it says
/// may have.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Settings", uncreatable)]
#[qml_singleton]
pub struct SettingsObject {
    #[qml(notify, readonly)]
    ready: bool,
    #[qml(notify, readonly)]
    document: Value,
    #[qml(notify, readonly)]
    version: i32,
    #[qml(notify, readonly)]
    error: Atom,
    #[qml(notify, readonly)]
    config: Value,
    #[qml(notify, readonly)]
    themes: Value,
    #[qml(notify, readonly)]
    device: Value,
    #[qml(notify, readonly)]
    device_error: Atom,
}

impl Default for SettingsObject {
    fn default() -> Self {
        SettingsObject {
            ready: false,
            document: Value::Undefined,
            version: 0,
            error: Atom::from(""),
            config: Value::Undefined,
            themes: Value::Undefined,
            device: Value::Undefined,
            device_error: Atom::from(""),
        }
    }
}

/// A setting as QML reads it: `undefined` when there is none.
fn shown(json: Option<Json>) -> Value {
    json.map_or(Value::Undefined, |j| j.to_value())
}

#[qml_impl]
impl SettingsObject {
    #[qml(invokable)]
    fn value(cx: &Cx, path: Atom) -> Value {
        shown(Settings::of(cx.engine).value(&path))
    }

    #[qml(invokable)]
    fn write(cx: &Cx, path: Atom, value: Json) {
        let value = tidy(value);
        Settings::of(cx.engine).write(cx.engine, &path, value);
    }

    #[qml(invokable)]
    fn device_value(cx: &Cx, key: Atom) -> Value {
        shown(Settings::of(cx.engine).device_value(&key))
    }

    #[qml(invokable)]
    fn write_device(cx: &Cx, key: Atom, value: Json) -> bool {
        let value = tidy(value);
        Settings::of(cx.engine).write_device(cx.engine, &key, value)
    }

    #[qml(invokable)]
    fn reload_device(cx: &Cx) {
        Settings::of(cx.engine).reload_device(cx.engine);
    }

    #[qml(invokable)]
    fn setting(cx: &Cx, key: Atom) -> Value {
        shown(Settings::of(cx.engine).setting(cx.engine, &key))
    }

    #[qml(invokable)]
    fn default_of(cx: &Cx, key: Atom) -> Value {
        shown(Settings::of(cx.engine).default_of(&key))
    }

    #[qml(invokable)]
    fn is_default(cx: &Cx, key: Atom) -> bool {
        Settings::of(cx.engine).is_default(cx.engine, &key)
    }

    #[qml(invokable)]
    fn mixed(cx: &Cx, key: Atom) -> bool {
        Settings::of(cx.engine).mixed(cx.engine, &key)
    }

    #[qml(invokable)]
    fn disabled_reason(cx: &Cx, key: Atom) -> Atom {
        Atom::from(
            Settings::of(cx.engine)
                .disabled_reason(cx.engine, &key)
                .as_str(),
        )
    }

    #[qml(invokable)]
    fn unreachable(cx: &Cx) -> Vec<String> {
        Settings::of(cx.engine).unreachable(cx.engine)
    }

    #[qml(invokable)]
    fn supports(cx: &Cx, capability: Atom) -> bool {
        Settings::of(cx.engine).supports(cx.engine, &capability)
    }

    #[qml(invokable)]
    fn on_device(cx: &Cx, key: Atom) -> bool {
        Settings::of(cx.engine).on_device(&key)
    }

    #[qml(invokable)]
    fn set(cx: &Cx, key: Atom, value: Json) {
        Settings::of(cx.engine).set(cx.engine, &key, value);
    }

    #[qml(invokable)]
    fn reset(cx: &Cx, key: Atom) {
        Settings::of(cx.engine).reset(cx.engine, &key);
    }

    #[qml(invokable)]
    fn reset_all(cx: &Cx, keys: Vec<String>) {
        Settings::of(cx.engine).reset_all(cx.engine, &keys);
    }
}

/// The controller: follows the MC as desktop-qt's does. Everything else is
/// [`Settings`].
pub struct SettingsController {
    settings: Settings,
}

impl Controller for SettingsController {
    fn new(init: Init<'_, Self>) -> Self {
        let settings = Settings::of(init.engine);
        init.mc
            .on_ready_changed(Box::new(|engine: &Engine, ready: bool| {
                Settings::of(engine).ready_changed(engine, ready);
            }));
        SettingsController { settings }
    }

    fn activate(&mut self, engine: &Engine) {
        self.settings.activate(engine);
    }
}

impl SettingsController {
    pub fn settings(&self) -> Settings {
        self.settings.clone()
    }
}
