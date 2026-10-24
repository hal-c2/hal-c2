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
//! engine extension, so [`Bridge`] is only a handle on a `Shell` object.
//!
//! Each window has its own bridge, as each of desktop-qt's windows had its
//! own ShellBridge: the first window's is the singleton, the others' are
//! made by [`Bridge::new_window`]. [`Bridge::of`] is the bridge of the window
//! acting now ([`Bridge::act`]): the one an action came from, or whose
//! controller is running; else the front window's. A key every window
//! shows ([`Bridge::share_key`]) is published on every bridge.

use std::any::{Any, TypeId};
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::Path;
use std::rc::Rc;

use ljos::ljos_engine::QmlSingleton;
use ljos::prelude::ClipboardMode;
use ljos::prelude::QmlValue;
use ljos::prelude::{
    Atom, Cx, Engine, EngineError, ObjectId, Platform, PropertyMap, QmlObject, Value, qml_impl,
    qml_singleton,
};

use crate::attachment_files;
use crate::json::{self, Json};
use crate::this_machine;

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

/// What waits for the running controllers to return, with the bridge it
/// is for.
enum Queued {
    Action(ObjectId, String, Json),
    Call(ObjectId, Deferred),
}
type ClipboardWriter = Rc<dyn Fn(&str) -> bool>;

/// `Shell` in `HalC2.Shell`.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Shell", uncreatable)]
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
    fn dispatch(cx: &Cx, action: Atom, payload: Json) {
        Bridge(cx.this).dispatch(cx.engine, &action, payload);
    }

    #[qml(invokable)]
    fn publish(cx: &Cx, key: Atom, value: Json) {
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
        // desktop-qt's setClipboardText says nothing either.
        let _ = Bridge(cx.this).copy_to_clipboard(cx.engine, &text);
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
    fn directory_paths(&self, urls: Vec<String>) -> Vec<Value> {
        urls.into_iter()
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

    /// Images for the composer: [{name, mimeType, base64}], skipping
    /// anything that is not an image or is over the attachment size limit.
    #[qml(invokable)]
    fn read_image_files(cx: &Cx, urls: Value) -> Vec<Value> {
        file_urls(cx.engine, &urls)
            .iter()
            .filter_map(|url| local_path(url))
            .filter_map(|path| attachment_files::read_image(&path))
            .map(|file| file.to_value())
            .collect()
    }

    /// Files for the composer: an image as readImageFiles has it, any other
    /// file as {name, mimeType, path}; folders, empty files and ones over
    /// the limits are skipped.
    #[qml(invokable)]
    fn read_attachment_files(cx: &Cx, urls: Value) -> Vec<Value> {
        file_urls(cx.engine, &urls)
            .iter()
            .filter_map(|url| local_path(url))
            .filter_map(|path| attachment_files::read_attachment(&path))
            .map(|file| file.to_value())
            .collect()
    }

    /// What the composer's own paste attaches: a copied picture as
    /// "image.png". Empty when the paste is text.
    ///
    /// TODO(ljos#97): desktop-qt first takes copied files (the clipboard's
    /// URLs); Ljós's clipboard holds no URL list, so a file copied in a file
    /// manager pastes as its path's text here.
    #[qml(invokable)]
    fn clipboard_files(cx: &Cx) -> Vec<Value> {
        let Some(image) = Platform::of(cx.engine).clipboard().image() else {
            return Vec::new();
        };
        attachment_files::pasted_image(image.width, image.height, image.rgba)
            .map(|file| vec![file.to_value()])
            .unwrap_or_default()
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

/// `%xx` escapes decoded, as QUrl::fromPercentEncoding does.
pub(crate) fn percent_decode(s: &str) -> String {
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

/// One bridge's own: its state, and what was added to it.
#[derive(Default)]
struct Own {
    map: RefCell<Option<PropertyMap>>,
    /// What each key last had, to skip a republish of the same value.
    published: RefCell<HashMap<String, Json>>,
    interceptors: RefCell<Vec<Interceptor>>,
    watchers: RefCell<Vec<(String, Watcher)>>,
    /// [`Bridge::extension`]'s.
    extensions: RefCell<Vec<(TypeId, Rc<dyn Any>)>>,
    /// [`Bridge::singleton`]'s, for a bridge that is not the singleton.
    objects: RefCell<Vec<(TypeId, ObjectId)>>,
}

/// The bridges' Rust side, one per engine.
#[derive(Default)]
struct BridgeState {
    /// The singleton's, once made.
    main: Cell<Option<ObjectId>>,
    /// Every bridge's own, oldest first.
    bridges: RefCell<Vec<(ObjectId, Rc<Own>)>>,
    /// The window acting now ([`Bridge::act`]).
    acting: Cell<Option<ObjectId>>,
    /// The window last acted in, or opened: [`Bridge::of`] when none acts.
    front: Cell<Option<ObjectId>>,
    /// The keys every window shows ([`Bridge::share_key`]).
    shared_keys: RefCell<HashSet<String>>,
    /// Controllers running now ([`Bridge::hold`]); actions dispatched
    /// meanwhile wait in `queued`.
    held: Cell<usize>,
    /// The queued actions are running, one after another.
    draining: Cell<bool>,
    queued: RefCell<VecDeque<Queued>>,
    clipboard_writer: RefCell<Option<ClipboardWriter>>,
    mc_origin: RefCell<String>,
}

impl BridgeState {
    fn of(engine: &Engine) -> Rc<BridgeState> {
        engine.extension::<BridgeState>()
    }

    fn own(&self, bridge: ObjectId) -> Option<Rc<Own>> {
        self.bridges
            .borrow()
            .iter()
            .find(|(b, _)| *b == bridge)
            .map(|(_, own)| own.clone())
    }

    fn is_open(&self, bridge: ObjectId) -> bool {
        self.bridges.borrow().iter().any(|(b, _)| *b == bridge)
    }
}

/// [`Bridge::acting_now`]: who acts, asked later.
#[derive(Clone)]
pub struct Acting(Rc<BridgeState>);

impl Acting {
    pub fn now(&self) -> Option<Bridge> {
        self.0.acting.get().map(Bridge)
    }
}

/// A window's `Shell`, from Rust.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bridge(ObjectId);

impl Bridge {
    /// The bridge of the window acting now, else of the front window, else
    /// the singleton (the first window's), made with its state keys on
    /// first use.
    pub fn of(engine: &Engine) -> Bridge {
        let main = Bridge::main(engine);
        let state = BridgeState::of(engine);
        if let Some(b) = state.acting.get().filter(|b| state.is_open(*b)) {
            return Bridge(b);
        }
        Bridge::front(&state).unwrap_or(main)
    }

    /// The front window's bridge, else the oldest open one's.
    fn front(state: &BridgeState) -> Option<Bridge> {
        state
            .front
            .get()
            .filter(|b| state.is_open(*b))
            .or_else(|| state.bridges.borrow().first().map(|(b, _)| *b))
            .map(Bridge)
    }

    /// The singleton: the first window's bridge, which the shared
    /// controllers are built on. It outlives its window, but is no longer
    /// one of the open ones once that closes.
    pub fn main(engine: &Engine) -> Bridge {
        let state = BridgeState::of(engine);
        if let Some(obj) = state.main.get() {
            return Bridge(obj);
        }
        let obj = engine
            .singleton::<ShellBridge>()
            .expect("HalC2.Shell is registered (crate::register)");
        state.main.set(Some(obj));
        Bridge::made(engine, &state, obj);
        Bridge(obj)
    }

    /// A bridge for another window: its own `Shell` object and state, the
    /// shared keys as the others show them.
    pub fn new_window(engine: &Engine) -> Option<Bridge> {
        let main = Bridge::main(engine);
        let state = BridgeState::of(engine);
        let source = Bridge::front(&state).unwrap_or(main);
        let obj = engine.create_native(ShellBridge::default(), None).ok()?;
        let own = Bridge::made(engine, &state, obj);
        let bridge = Bridge(obj);
        let keys: Vec<Atom> = source
            .own(engine)
            .and_then(|o| o.map.borrow().as_ref().map(PropertyMap::keys))
            .unwrap_or_default();
        for key in keys {
            bridge.declare_key(engine, &key);
        }
        let shared: Vec<(String, Json)> = {
            let keys = state.shared_keys.borrow();
            source
                .own(engine)
                .map(|o| {
                    o.published
                        .borrow()
                        .iter()
                        .filter(|(k, _)| keys.contains(*k))
                        .map(|(k, v)| (k.clone(), v.clone()))
                        .collect()
                })
                .unwrap_or_default()
        };
        for (key, value) in shared {
            bridge.publish_own(engine, &own, &key, value);
        }
        let enabled = engine
            .get(source.0, ShellBridge::LOCAL_FOLDER_IMPORT_ENABLED)
            .unwrap_or(false);
        let _ = Cx::new(engine, obj).set(ShellBridge::LOCAL_FOLDER_IMPORT_ENABLED, enabled);
        Some(bridge)
    }

    fn made(engine: &Engine, state: &BridgeState, obj: ObjectId) -> Rc<Own> {
        let map = PropertyMap::new(engine, Some(obj)).expect("the bridge is alive");
        for key in STATE_KEYS {
            map.insert(engine, key, Value::Undefined);
        }
        let _ = Cx::new(engine, obj).set(ShellBridge::STATE, Some(map.object()));
        let own = Rc::new(Own {
            map: RefCell::new(Some(map)),
            ..Own::default()
        });
        state.bridges.borrow_mut().push((obj, own.clone()));
        own
    }

    /// The window is gone: so is what was added to its bridge, and the
    /// bridge, unless it is the singleton (which only stops being open).
    pub fn close(self, engine: &Engine) {
        let state = BridgeState::of(engine);
        let own = {
            let mut bridges = state.bridges.borrow_mut();
            let at = bridges.iter().position(|(b, _)| *b == self.0);
            at.map(|at| bridges.remove(at).1)
        };
        let Some(own) = own else { return };
        let objects = std::mem::take(&mut *own.objects.borrow_mut());
        for (_, obj) in objects {
            engine.destroy(obj);
        }
        own.interceptors.borrow_mut().clear();
        own.watchers.borrow_mut().clear();
        // Dropped out of the borrow: an extension's drop may reach the bridge.
        let extensions = std::mem::take(&mut *own.extensions.borrow_mut());
        drop(extensions);
        if state.main.get() != Some(self.0) {
            engine.destroy(self.0);
        }
    }

    /// Runs `f` as this bridge's window: [`Bridge::of`] is this bridge
    /// until it returns.
    pub fn act<R>(self, engine: &Engine, f: impl FnOnce() -> R) -> R {
        let state = BridgeState::of(engine);
        let _acting = Restore(&state.acting, state.acting.replace(Some(self.0)));
        f()
    }

    /// The bridge of the window acting now, if one is.
    pub fn acting(engine: &Engine) -> Option<Bridge> {
        BridgeState::of(engine).acting.get().map(Bridge)
    }

    /// Who acts, readable where there is no engine: an MC call binds its
    /// reply to the window that made it.
    pub fn acting_now(engine: &Engine) -> Acting {
        Acting(BridgeState::of(engine))
    }

    /// Runs `f` as this bridge's window if it is still open; `None` once
    /// it is gone. A callback a window registered somewhere every window
    /// shares (settings, the application) goes through here.
    pub fn if_open<R>(self, engine: &Engine, f: impl FnOnce() -> R) -> Option<R> {
        self.is_open(engine).then(|| self.act(engine, f))
    }

    /// Makes this the window [`Bridge::of`] is when none acts.
    pub fn set_front(self, engine: &Engine) {
        BridgeState::of(engine).front.set(Some(self.0));
    }

    /// The open window's bridge that `obj` is, if it is one: what a native
    /// object a bridge owns runs as.
    pub fn open_at(engine: &Engine, obj: ObjectId) -> Option<Bridge> {
        let bridge = Bridge(obj);
        bridge.is_open(engine).then_some(bridge)
    }

    /// Whether this bridge's window is still there.
    pub fn is_open(self, engine: &Engine) -> bool {
        BridgeState::of(engine).is_open(self.0)
    }

    /// `key` is every window's: published on one bridge, it is published
    /// on all.
    pub fn share_key(engine: &Engine, key: &str) {
        BridgeState::of(engine)
            .shared_keys
            .borrow_mut()
            .insert(key.to_owned());
    }

    /// This bridge's `T`, made on first use: what would be an engine
    /// extension, one per window instead.
    pub fn extension<T: Default + 'static>(self, engine: &Engine) -> Rc<T> {
        let Some(own) = self.own(engine) else {
            // A bridge that is gone keeps nothing.
            return Rc::new(T::default());
        };
        let id = TypeId::of::<T>();
        if let Some(found) = own.extensions.borrow().iter().find(|(t, _)| *t == id) {
            return found.1.clone().downcast::<T>().expect("of its type");
        }
        let made = Rc::new(T::default());
        own.extensions.borrow_mut().push((id, made.clone()));
        made
    }

    /// This window's `T`: the engine's singleton for the first window, an
    /// object of its own for each other.
    ///
    /// TODO(ljos#81): QML still finds the engine's, so another window's
    /// bricks cannot see their own. Ljós's window-scoped singletons are
    /// made by Ljós when a root's QML first reads them, and a window's
    /// bridge is built, and its controllers publish on it, before its root
    /// is made, and with no root at all headless; a host cannot hand a
    /// window an object it made, as desktop-qt's
    /// qmlRegisterSingletonInstance does for each window's engine.
    pub fn singleton<T: QmlSingleton + Default>(
        self,
        engine: &Engine,
    ) -> Result<ObjectId, EngineError> {
        if Some(self.0) == BridgeState::of(engine).main.get() || !self.is_open(engine) {
            return engine.singleton::<T>();
        }
        let own = self.own(engine).expect("an open bridge has its own");
        let id = TypeId::of::<T>();
        if let Some(found) = own.objects.borrow().iter().find(|(t, _)| *t == id) {
            return Ok(found.1);
        }
        let obj = engine.create_native(T::default(), None)?;
        own.objects.borrow_mut().push((id, obj));
        Ok(obj)
    }

    pub fn object(self) -> ObjectId {
        self.0
    }

    fn own(self, engine: &Engine) -> Option<Rc<Own>> {
        Bridge::main(engine);
        BridgeState::of(engine).own(self.0)
    }

    /// A key bindings can follow before anything publishes it.
    pub fn declare_key(self, engine: &Engine, key: &str) {
        let Some(map) = self.own(engine).and_then(|o| o.map.borrow().clone()) else {
            return;
        };
        if !map.contains(key) {
            map.insert(engine, key, Value::Undefined);
        }
    }

    /// Sets `Shell.state[key]`, unless it already holds `value`: an unchanged
    /// republish would re-run every binding on the key for nothing. A shared
    /// key is set on every window's bridge.
    pub fn publish(self, engine: &Engine, key: &str, value: Json) {
        let state = BridgeState::of(engine);
        Bridge::main(engine);
        if state.shared_keys.borrow().contains(key) {
            let all = state.bridges.borrow().clone();
            for (b, own) in all {
                Bridge(b).publish_own(engine, &own, key, value.clone());
            }
            return;
        }
        if let Some(own) = state.own(self.0) {
            self.publish_own(engine, &own, key, value);
        }
    }

    fn publish_own(self, engine: &Engine, own: &Own, key: &str, value: Json) {
        if own.published.borrow().get(key) == Some(&value) {
            return;
        }
        let shown = value.to_value();
        let Some(map) = own.map.borrow().clone() else {
            return;
        };
        map.insert(engine, key, shown.clone());
        own.published
            .borrow_mut()
            .insert(key.to_owned(), value.clone());
        let watchers: Vec<Watcher> = own
            .watchers
            .borrow()
            .iter()
            .filter(|(k, _)| k == key)
            .map(|(_, w)| w.clone())
            .collect();
        self.act(engine, || {
            for watch in watchers {
                watch(engine, &value);
            }
        });
        let _ =
            ShellBridge::emit_state_entry_changed(&Cx::new(engine, self.0), Atom::new(key), shown);
    }

    /// What `key` was last published as.
    pub fn published(self, engine: &Engine, key: &str) -> Option<Json> {
        self.own(engine)?.published.borrow().get(key).cloned()
    }

    /// Calls `f` with each value published under `key`, before QML hears of
    /// it: what main.cpp's connections to stateEntryChanged do (the theme).
    pub fn watch(self, engine: &Engine, key: &str, f: impl Fn(&Engine, &Json) + 'static) {
        if let Some(own) = self.own(engine) {
            own.watchers.borrow_mut().push((key.to_owned(), Rc::new(f)));
        }
    }

    /// Offers every action to `interceptor` after those added before it.
    pub fn add_interceptor(self, engine: &Engine, interceptor: Interceptor) {
        if let Some(own) = self.own(engine) {
            own.interceptors.borrow_mut().push(interceptor);
        }
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
                .push_back(Queued::Action(self.0, action.to_owned(), payload));
            return;
        }
        self.deliver(engine, action, &payload);
    }

    /// Runs `f` once no controller is running: at once when none is, else
    /// right after the outermost returns, in order with the actions
    /// dispatched meanwhile. What a controller hands back to its caller (a
    /// toast's action, a menu's choice, a command) goes through here, so the
    /// callback may call that controller again. It runs as the window that
    /// was acting (else this bridge's).
    pub fn defer(self, engine: &Engine, f: impl FnOnce(&Engine) + 'static) {
        let state = BridgeState::of(engine);
        let window = state.acting.get().unwrap_or(self.0);
        if state.held.get() > 0 || state.draining.get() {
            state
                .queued
                .borrow_mut()
                .push_back(Queued::Call(window, Box::new(f)));
            return;
        }
        Bridge(window).run_as(engine, f);
    }

    /// `f` as this bridge's window, or as the front one once it is gone.
    fn run_as(self, engine: &Engine, f: impl FnOnce(&Engine)) {
        if self.is_open(engine) {
            self.act(engine, || f(engine));
        } else {
            f(engine);
        }
    }

    fn deliver(self, engine: &Engine, action: &str, payload: &Json) {
        let Some(own) = self.own(engine) else {
            // Its window is gone. What the shared controllers dispatch on
            // the first window's bridge goes on to the window in front.
            let to = Bridge::of(engine);
            if BridgeState::of(engine).main.get() == Some(self.0) && to != self {
                to.deliver(engine, action, payload);
            }
            return;
        };
        let interceptors = own.interceptors.borrow().clone();
        self.act(engine, || {
            if interceptors.iter().any(|i| i(engine, action, payload)) {
                return;
            }
            self.send_to_bricks(engine, action, payload);
        });
    }

    /// Native code asking the bricks to do something (focus the composer):
    /// bypasses the interceptors, which would otherwise see their own requests.
    pub fn send_to_bricks(self, engine: &Engine, action: &str, payload: &Json) {
        let payload = payload.to_value();
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
                    Some(Queued::Action(bridge, action, payload)) => {
                        Bridge(bridge).deliver(engine, &action, &payload)
                    }
                    Some(Queued::Call(bridge, f)) => Bridge(bridge).run_as(engine, f),
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
    /// link with the platform's opener (`Qt.openUrlExternally`'s); anything
    /// else is ignored.
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
        if !Platform::of(engine).open_url().open(url) {
            eprintln!("hal-c2: cannot open {url}");
        }
    }

    /// Where `setClipboardText` writes instead of the clipboard (tests); it
    /// says whether the write happened.
    pub fn set_clipboard_writer(self, engine: &Engine, write: impl Fn(&str) -> bool + 'static) {
        *BridgeState::of(engine).clipboard_writer.borrow_mut() = Some(Rc::new(write));
    }

    /// Puts `text` on the clipboard, as `setClipboardText` does, or where
    /// [`Bridge::set_clipboard_writer`] says; false when the clipboard
    /// refused it (or there is none), for a caller that says "copied".
    pub fn copy_to_clipboard(self, engine: &Engine, text: &str) -> bool {
        let writer = BridgeState::of(engine).clipboard_writer.borrow().clone();
        match writer {
            Some(write) => write(text),
            None => Platform::of(engine)
                .clipboard()
                .set_text(ClipboardMode::Clipboard, text)
                .is_ok(),
        }
    }

    /// The MC the shell talks to; its origin is one way to tell whether it
    /// runs here (`this_machine::hosts`).
    pub fn set_mc_origin(self, engine: &Engine, origin: &str) {
        *BridgeState::of(engine).mc_origin.borrow_mut() = origin.to_owned();
    }

    /// The origin [`Bridge::set_mc_origin`] was given; empty while the shell
    /// is connected to no MC.
    pub fn mc_origin(self, engine: &Engine) -> String {
        BridgeState::of(engine).mc_origin.borrow().clone()
    }

    /// Every window's bridge says so.
    pub fn set_local_folder_import_enabled(self, engine: &Engine, enabled: bool) {
        let main = Bridge::main(engine);
        let mut all: Vec<ObjectId> = BridgeState::of(engine)
            .bridges
            .borrow()
            .iter()
            .map(|(b, _)| *b)
            .collect();
        if !all.contains(&main.0) {
            all.push(main.0);
        }
        for b in all {
            let _ = Cx::new(engine, b).set(ShellBridge::LOCAL_FOLDER_IMPORT_ENABLED, enabled);
        }
    }

    /// Whether the user allowed folders of this machine to be imported.
    pub fn local_folder_import_enabled(self, engine: &Engine) -> bool {
        engine
            .get(self.0, ShellBridge::LOCAL_FOLDER_IMPORT_ENABLED)
            .unwrap_or(false)
    }

    /// Whether this machine's folders are the MC's: import is allowed, the
    /// shell is connected to an MC, and `this_machine` says it runs here.
    pub fn local_folders(self, engine: &Engine) -> bool {
        self.local_folder_import_enabled(engine)
            && !self.mc_origin(engine).is_empty()
            && this_machine::mc_here(engine)
    }
}

/// Puts a cell back as it was when dropped, also when unwinding.
struct Restore<'a, T: Copy>(&'a Cell<T>, T);

impl<T: Copy> Drop for Restore<'_, T> {
    fn drop(&mut self) {
        self.0.set(self.1);
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
