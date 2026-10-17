//! The `Shell` singleton the bricks read from: desktop-qt's ShellBridge.
//!
//! State flows controllers -> QML through [`Bridge::publish`] into
//! `Shell.state`, one property per key, so a publish re-runs only the
//! bindings that read that key. Actions flow QML -> controllers through
//! `Shell.dispatch`: each interceptor (the controllers, see
//! `controller.rs`) is offered the action in turn until one handles it,
//! and the rest reach the bricks as `actionRequested`.
//!
//! The bridge holds no domain logic. Its Rust-side state lives in an
//! engine extension, so [`Bridge`] is only a handle on the singleton.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::rc::Rc;

use ljos::prelude::{
    Atom, Cx, Engine, ObjectId, Platform, PropertyMap, QmlObject, Value, qml_impl,
};
use ljos_engine::qml_singleton;
use ljos_platform::ClipboardMode;

use crate::json::{self, Json};

/// The keys the bricks bind before any controller declares them: main.cpp's
/// `backendError`, the sidebar's, and the ones the default layout reads.
/// A binding made before its key exists never sees the value (Ljós's
/// PropertyMap, like Qt's), so they are there from the start.
pub const STATE_KEYS: [&str; 8] = [
    "backendError",
    "composer",
    "git",
    "layout",
    "modelPicker",
    "sidebar",
    "theme",
    "workspace",
];

/// Hands an action to whoever handles it; true when it did.
pub type Interceptor = Rc<dyn Fn(&Engine, &str, &Json) -> bool>;
type Watcher = Rc<dyn Fn(&Engine, &Json)>;
type Deferred = Box<dyn FnOnce(&Engine)>;

/// What waits for the running controllers to return.
enum Queued {
    Action(String, Json),
    Call(Deferred),
}
type Opener = Rc<dyn Fn(&str)>;
type ClipboardWriter = Rc<dyn Fn(&str)>;

/// `Shell` in `HalC2.Shell`.
#[derive(Debug, QmlObject)]
// Not `uncreatable`: Ljós then cannot make the singleton either
// (meta.create is gone), and `engine.singleton` fails.
#[qml(module = "HalC2.Shell", name = "Shell")]
#[qml_singleton]
pub struct ShellBridge {
    #[qml(constant, readonly)]
    protocol_version: i32,
    /// The `PropertyMap` of published state.
    #[qml(constant, readonly)]
    state: Option<ObjectId>,
    #[qml(constant, readonly)]
    local_folder_import_enabled: bool,
}

impl Default for ShellBridge {
    fn default() -> Self {
        ShellBridge {
            protocol_version: 1,
            state: None,
            local_folder_import_enabled: false,
        }
    }
}

#[qml_impl]
impl ShellBridge {
    #[qml(signal)]
    fn state_entry_changed(key: Atom, value: Value);
    #[qml(signal)]
    fn action_requested(action: Atom, payload: Value);
    #[qml(signal)]
    fn window_command_requested(command: Atom);

    #[qml(invokable)]
    fn dispatch(cx: &Cx, action: Atom, payload: Value) {
        let payload = json::from_value(cx.engine, &payload);
        Bridge(cx.this).dispatch(cx.engine, &action, payload);
    }

    #[qml(invokable)]
    fn publish(cx: &Cx, key: Atom, value: Value) {
        let value = json::from_value(cx.engine, &value);
        Bridge(cx.this).publish(cx.engine, &key, value);
    }

    #[qml(invokable)]
    fn declare_key(cx: &Cx, key: Atom) {
        Bridge(cx.this).declare_key(cx.engine, &key);
    }

    #[qml(invokable)]
    fn window_command(cx: &Cx, command: Atom) {
        let _ = Self::emit_window_command_requested(cx, command);
    }

    #[qml(invokable)]
    fn open_external(cx: &Cx, url: Value) {
        let url = cx.engine.to_js_string(&url);
        Bridge(cx.this).open_external(cx.engine, &url);
    }

    #[qml(invokable)]
    fn clipboard_text(cx: &Cx) -> String {
        Platform::of(cx.engine)
            .clipboard()
            .text(ClipboardMode::Clipboard)
            .unwrap_or_default()
    }

    #[qml(invokable)]
    fn set_clipboard_text(cx: &Cx, text: Atom) {
        Bridge(cx.this).copy_to_clipboard(cx.engine, &text);
    }

    /// Whether pasting `text` into a prompt of `prompt_length` characters
    /// makes it a text file instead: 32 KiB or more, or more than the prompt
    /// can hold.
    #[qml(invokable)]
    fn paste_attaches(&self, text: Atom, prompt_length: i32) -> bool {
        const THRESHOLD_BYTES: usize = 32 * 1024;
        const MAX_PROMPT_CHARS: usize = 120_000;
        // Characters as Qt counts them: UTF-16 units.
        let chars = text.encode_utf16().count();
        !text.is_empty()
            && (text.len() >= THRESHOLD_BYTES
                || usize::try_from(prompt_length).unwrap_or(0) + chars > MAX_PROMPT_CHARS)
    }

    /// The folders among `urls`, as paths on this machine.
    #[qml(invokable)]
    fn directory_paths(cx: &Cx, urls: Value) -> Vec<Value> {
        file_urls(cx.engine, &urls)
            .into_iter()
            .filter_map(|url| local_path(&url))
            .filter(|path| Path::new(path).is_dir())
            .map(|path| Value::from(path.as_str()))
            .collect()
    }

    /// A drop imports an existing local directory, never creates one; only
    /// when the MC runs on this machine.
    #[qml(invokable)]
    fn local_directory_path(cx: &Cx, url: Value) -> String {
        let url = cx.engine.to_js_string(&url);
        if !Bridge(cx.this).local_folders(cx.engine) {
            return String::new();
        }
        local_path(&url)
            .and_then(|path| std::fs::canonicalize(path).ok())
            .filter(|path| path.is_dir())
            .map(|path| path.to_string_lossy().into_owned())
            .unwrap_or_default()
    }

    // Not ported yet: reading files and pictures for the composer. Empty,
    // as when nothing usable was dropped or pasted.
    #[qml(invokable)]
    fn read_image_files(&self, _urls: Value) -> Vec<Value> {
        Vec::new()
    }

    #[qml(invokable)]
    fn read_attachment_files(&self, _urls: Value) -> Vec<Value> {
        Vec::new()
    }

    #[qml(invokable)]
    fn clipboard_files(&self) -> Vec<Value> {
        Vec::new()
    }
}

/// What QML hands a file helper (`drop.urls`, one URL), as strings.
fn file_urls(engine: &Engine, urls: &Value) -> Vec<String> {
    match json::from_value(engine, urls) {
        Json::Array(items) => items
            .into_iter()
            .filter_map(|v| v.as_str().map(str::to_owned))
            .collect(),
        Json::String(one) => vec![one],
        _ => Vec::new(),
    }
}

/// The path of a `file:` URL on this machine (no host).
fn local_path(url: &str) -> Option<String> {
    let path = url.strip_prefix("file://")?;
    if !path.starts_with('/') {
        return None;
    }
    Some(percent_decode(path))
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        if bytes[i] == b'%'
            && let (Some(Some(hi)), Some(Some(lo))) = (
                bytes.get(i + 1).map(|b| hex(*b)),
                bytes.get(i + 2).map(|b| hex(*b)),
            )
        {
            out.push((hi * 16 + lo) as u8);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The bridge's Rust side, one per engine.
#[derive(Default)]
struct BridgeState {
    map: RefCell<Option<PropertyMap>>,
    /// What each key last had, to skip a republish of the same value.
    published: RefCell<HashMap<String, Json>>,
    interceptors: RefCell<Vec<Interceptor>>,
    watchers: RefCell<Vec<(String, Watcher)>>,
    /// Controllers running now ([`Bridge::hold`]); actions dispatched
    /// meanwhile wait in `queued`.
    held: Cell<usize>,
    /// The queued actions are running, one after another.
    draining: Cell<bool>,
    queued: RefCell<VecDeque<Queued>>,
    opener: RefCell<Option<Opener>>,
    clipboard_writer: RefCell<Option<ClipboardWriter>>,
    mc_origin: RefCell<String>,
}

impl BridgeState {
    fn of(engine: &Engine) -> Rc<BridgeState> {
        engine.extension::<BridgeState>()
    }
}

/// The engine's `Shell`, from Rust.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bridge(ObjectId);

impl Bridge {
    /// The engine's bridge, made with its state keys on first use.
    pub fn of(engine: &Engine) -> Bridge {
        let obj = engine
            .singleton::<ShellBridge>()
            .expect("HalC2.Shell is registered (crate::register)");
        let state = BridgeState::of(engine);
        if state.map.borrow().is_none() {
            let map = PropertyMap::new(engine, Some(obj)).expect("the bridge is alive");
            for key in STATE_KEYS {
                map.insert(engine, key, Value::Undefined);
            }
            let _ = Cx::new(engine, obj).set(ShellBridge::STATE, Some(map.object()));
            *state.map.borrow_mut() = Some(map);
        }
        Bridge(obj)
    }

    pub fn object(self) -> ObjectId {
        self.0
    }

    fn map(engine: &Engine) -> PropertyMap {
        Bridge::of(engine);
        BridgeState::of(engine)
            .map
            .borrow()
            .clone()
            .expect("made by Bridge::of")
    }

    /// A key bindings can follow before anything publishes it.
    pub fn declare_key(self, engine: &Engine, key: &str) {
        let map = Bridge::map(engine);
        if !map.contains(key) {
            map.insert(engine, key, Value::Undefined);
        }
    }

    /// Sets `Shell.state[key]`, unless it already holds `value`: an unchanged
    /// republish would re-run every binding on the key for nothing.
    pub fn publish(self, engine: &Engine, key: &str, value: Json) {
        let state = BridgeState::of(engine);
        if state.published.borrow().get(key) == Some(&value) {
            return;
        }
        let shown = json::to_value(engine, &value);
        Bridge::map(engine).insert(engine, key, shown.clone());
        state
            .published
            .borrow_mut()
            .insert(key.to_owned(), value.clone());
        let watchers: Vec<Watcher> = state
            .watchers
            .borrow()
            .iter()
            .filter(|(k, _)| k == key)
            .map(|(_, w)| w.clone())
            .collect();
        for watch in watchers {
            watch(engine, &value);
        }
        let _ =
            ShellBridge::emit_state_entry_changed(&Cx::new(engine, self.0), Atom::new(key), shown);
    }

    /// What `key` was last published as.
    pub fn published(self, engine: &Engine, key: &str) -> Option<Json> {
        BridgeState::of(engine).published.borrow().get(key).cloned()
    }

    /// Calls `f` with each value published under `key`, before QML hears of
    /// it: what main.cpp's connections to stateEntryChanged do (the theme).
    pub fn watch(self, engine: &Engine, key: &str, f: impl Fn(&Engine, &Json) + 'static) {
        BridgeState::of(engine)
            .watchers
            .borrow_mut()
            .push((key.to_owned(), Rc::new(f)));
    }

    /// Offers every action to `interceptor` after those added before it.
    pub fn add_interceptor(self, engine: &Engine, interceptor: Interceptor) {
        BridgeState::of(engine)
            .interceptors
            .borrow_mut()
            .push(interceptor);
    }

    /// Hands `action` to the interceptors in turn; one none handles reaches
    /// the bricks as `actionRequested`.
    ///
    /// While a controller is running ([`Bridge::hold`]) the action waits
    /// until it returns: what it published may have made QML dispatch, and
    /// the action may be its own to handle. Qt runs such an action at once;
    /// here it runs right after, behind any that waited before it.
    pub fn dispatch(self, engine: &Engine, action: &str, payload: Json) {
        let state = BridgeState::of(engine);
        if state.held.get() > 0 || state.draining.get() {
            state
                .queued
                .borrow_mut()
                .push_back(Queued::Action(action.to_owned(), payload));
            return;
        }
        self.deliver(engine, &state, action, &payload);
    }

    /// Runs `f` once no controller is running: at once when none is, else
    /// right after the outermost returns, in order with the actions
    /// dispatched meanwhile. What a controller hands back to its caller (a
    /// toast's action, a menu's choice, a command) goes through here, so the
    /// callback may call that controller again.
    pub fn defer(self, engine: &Engine, f: impl FnOnce(&Engine) + 'static) {
        let state = BridgeState::of(engine);
        if state.held.get() > 0 || state.draining.get() {
            state
                .queued
                .borrow_mut()
                .push_back(Queued::Call(Box::new(f)));
            return;
        }
        f(engine);
    }

    fn deliver(self, engine: &Engine, state: &BridgeState, action: &str, payload: &Json) {
        let interceptors = state.interceptors.borrow().clone();
        if interceptors.iter().any(|i| i(engine, action, payload)) {
            return;
        }
        self.send_to_bricks(engine, action, payload);
    }

    /// Native code asking the bricks to do something (focus the composer):
    /// bypasses the interceptors, which would otherwise see their own requests.
    pub fn send_to_bricks(self, engine: &Engine, action: &str, payload: &Json) {
        let payload = json::to_value(engine, payload);
        let _ = ShellBridge::emit_action_requested(
            &Cx::new(engine, self.0),
            Atom::new(action),
            payload,
        );
    }

    /// Runs `f` as a controller: actions dispatched meanwhile wait until the
    /// outermost one returns, then run in order.
    pub fn hold<R>(self, engine: &Engine, f: impl FnOnce() -> R) -> R {
        let state = BridgeState::of(engine);
        let out = {
            let _held = Raise::new(&state.held);
            f()
        };
        // One drain at a time, outermost: a controller that runs for a
        // queued action must not start the next one before it is through.
        if state.held.get() == 0 && !state.draining.replace(true) {
            let _draining = Reset(&state.draining);
            loop {
                let next = state.queued.borrow_mut().pop_front();
                match next {
                    Some(Queued::Action(action, payload)) => {
                        self.deliver(engine, &state, &action, &payload)
                    }
                    Some(Queued::Call(f)) => f(engine),
                    None => break,
                }
            }
        }
        out
    }

    /// Asks the window to do something to itself ("raise", "minimize"), as
    /// the bricks' `Shell.windowCommand` does: `windowCommandRequested`.
    pub fn window_command(self, engine: &Engine, command: &str) {
        let _ = ShellBridge::emit_window_command_requested(
            &Cx::new(engine, self.0),
            Atom::new(command),
        );
    }

    /// Opens a link: the app's own (`hal-c2:`) as `link.open`, a web or mail
    /// link in the system's handler; anything else is ignored.
    pub fn open_external(self, engine: &Engine, url: &str) {
        let scheme = url
            .split_once(':')
            .map_or("", |(s, _)| s)
            .to_ascii_lowercase();
        if scheme == "hal-c2" {
            self.dispatch(engine, "link.open", serde_json::json!({ "url": url }));
            return;
        }
        if !matches!(scheme.as_str(), "http" | "https" | "mailto") {
            return;
        }
        let opener = BridgeState::of(engine).opener.borrow().clone();
        match opener {
            Some(open) => open(url),
            None => open_with_system(url),
        }
    }

    /// Where `open_external` sends a URL instead of the system (tests).
    pub fn set_url_opener(self, engine: &Engine, open: impl Fn(&str) + 'static) {
        *BridgeState::of(engine).opener.borrow_mut() = Some(Rc::new(open));
    }

    /// Where `setClipboardText` writes instead of the clipboard (tests).
    pub fn set_clipboard_writer(self, engine: &Engine, write: impl Fn(&str) + 'static) {
        *BridgeState::of(engine).clipboard_writer.borrow_mut() = Some(Rc::new(write));
    }

    /// Puts `text` on the clipboard, as `setClipboardText` does.
    pub fn copy_to_clipboard(self, engine: &Engine, text: &str) {
        let writer = BridgeState::of(engine).clipboard_writer.borrow().clone();
        match writer {
            Some(write) => write(text),
            None => Platform::of(engine)
                .clipboard()
                .set_text(ClipboardMode::Clipboard, text),
        }
    }

    /// The MC the shell talks to; local folders are its only on loopback.
    pub fn set_mc_origin(self, engine: &Engine, origin: &str) {
        *BridgeState::of(engine).mc_origin.borrow_mut() = origin.to_owned();
    }

    pub fn set_local_folder_import_enabled(self, engine: &Engine, enabled: bool) {
        let _ = Cx::new(engine, self.0).set(ShellBridge::LOCAL_FOLDER_IMPORT_ENABLED, enabled);
    }

    /// Whether this machine's folders are the MC's: import is allowed and
    /// the MC runs here.
    pub fn local_folders(self, engine: &Engine) -> bool {
        let enabled = engine
            .get(self.0, ShellBridge::LOCAL_FOLDER_IMPORT_ENABLED)
            .unwrap_or(false);
        let origin = BridgeState::of(engine).mc_origin.borrow().clone();
        enabled
            && matches!(
                origin_host(&origin).as_str(),
                "localhost" | "127.0.0.1" | "::1"
            )
    }
}

/// Counts a controller running until it returns, or unwinds.
struct Raise<'a>(&'a Cell<usize>);

impl<'a> Raise<'a> {
    fn new(count: &'a Cell<usize>) -> Self {
        count.set(count.get() + 1);
        Raise(count)
    }
}

impl Drop for Raise<'_> {
    fn drop(&mut self) {
        self.0.set(self.0.get() - 1);
    }
}

/// Clears a flag when dropped, also when unwinding.
struct Reset<'a>(&'a Cell<bool>);

impl Drop for Reset<'_> {
    fn drop(&mut self) {
        self.0.set(false);
    }
}

fn origin_host(origin: &str) -> String {
    let rest = origin.split_once("://").map_or(origin, |(_, r)| r);
    let authority = rest.split('/').next().unwrap_or("");
    let host = match authority.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or(""),
        None => authority.split(':').next().unwrap_or(""),
    };
    host.to_ascii_lowercase()
}

/// Ljós has no service for opening a URL in the system's handler
/// (openUrlExternally), so `open` hands it to the platform's, detached.
fn open_with_system(url: &str) {
    if let Err(e) = open::that_detached(url) {
        eprintln!("hal-c2: cannot open {url}: {e}");
    }
}
