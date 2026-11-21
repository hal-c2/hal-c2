//! `Runtime` in `HalC2.Shell`, desktop-qt's ShellRuntime: which shell a
//! window shows, the user's `<config>/shell.qml` or the built-in one, and
//! why the user's is not shown.
//!
//! Each window's root is `Main` (qml/Main.qml), a `ShellLoader` of Ljós
//! whose source is the user's `shell.qml` and whose fallback is the
//! built-in shell. The loader shows the shell's `Window` as the window,
//! and the application's user QML (`App::user_qml`, src/main.rs) applies a
//! save of the user's files to it with its state kept. This module follows
//! each window's loader: the `Window` it shows is the window the
//! controllers know (`controller::attach_root`), and `usingUserShell` and
//! `lastError` say what it shows and why.
//!
//! A loader is made once per window, in that window's scope
//! ([`Bridge::in_scope`]), and every shell it makes after that is made in
//! the same scope. That way a shell made again after a save still reads its
//! window's singletons.

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use ljos::prelude::{
    Atom, Cx, Engine, LogLevel, ObjectId, QmlObject, Value, qml_impl, qml_singleton,
};

use crate::bridge::Bridge;
use crate::controller;

/// The key of each window's root, qml/Main.qml: the `ShellLoader`.
pub const MAIN: &str = "Main";

/// The loader's source, as Main.qml names it: `<config>/shell.qml`.
pub const USER_SHELL: &str = "shell.qml";

/// `ShellLoader.status`: the source's shell is shown.
const READY: i32 = 1;

#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Runtime", uncreatable)]
#[qml_singleton]
pub struct ShellRuntime {
    #[qml(constant, readonly)]
    config_dir: Atom,
    #[qml(constant, readonly)]
    user_shell_path: Atom,
    #[qml(notify, readonly)]
    using_user_shell: bool,
    #[qml(notify, readonly)]
    last_error: Atom,
    /// How many shells the first window has shown: one more each time its
    /// loader shows another.
    #[qml(notify, readonly)]
    generation: i32,
    /// Whether a save of the user's files is applied while the app runs.
    #[qml(notify, readonly)]
    hot_reload_enabled: bool,
    #[qml(constant, readonly)]
    app_version: Atom,
}

impl Default for ShellRuntime {
    fn default() -> Self {
        ShellRuntime {
            config_dir: Atom::from(""),
            user_shell_path: Atom::from(""),
            using_user_shell: false,
            last_error: Atom::from(""),
            generation: 0,
            hot_reload_enabled: false,
            app_version: Atom::from(env!("CARGO_PKG_VERSION")),
        }
    }
}

#[qml_impl]
impl ShellRuntime {
    /// The shell's error overlay's "Reload".
    #[qml(invokable)]
    fn reload(cx: &Cx) {
        reload(cx.engine);
    }
}

/// One open window's loader and the shell it shows.
struct Shown {
    id: String,
    loader: ObjectId,
    item: Option<ObjectId>,
    /// The shell the loader let go of while it makes the next: the loader
    /// says it shows none in between, and the next takes this one's
    /// platform window.
    going: Option<ObjectId>,
}

#[derive(Default)]
struct RuntimeState {
    /// `<config>/shell.qml`, when there is a config dir.
    user_shell: RefCell<Option<PathBuf>>,
    /// Each open window's loader, by window id, oldest window first.
    shown: RefCell<Vec<Shown>>,
    /// The loader the host shows while the app runs ([`open`]).
    view: Cell<Option<ObjectId>>,
}

impl RuntimeState {
    fn of(engine: &Engine) -> Rc<RuntimeState> {
        engine.extension::<RuntimeState>()
    }
}

fn runtime(engine: &Engine) -> ObjectId {
    engine
        .singleton::<ShellRuntime>()
        .expect("HalC2.Shell is registered")
}

/// Gives the engine's `Runtime` the config dir. Before the root is made.
pub fn install(engine: &Engine, config_dir: Option<&Path>) {
    let Some(dir) = config_dir else {
        return;
    };
    let cx = Cx::new(engine, runtime(engine));
    let user_shell = dir.join(USER_SHELL);
    let _ = cx.set(
        ShellRuntime::CONFIG_DIR,
        Atom::from(dir.to_string_lossy().as_ref()),
    );
    let _ = cx.set(
        ShellRuntime::USER_SHELL_PATH,
        Atom::from(user_shell.to_string_lossy().as_ref()),
    );
    *RuntimeState::of(engine).user_shell.borrow_mut() = Some(user_shell);
}

/// Says whether a save of the user's files is applied while the app runs:
/// what the app's user QML was started with.
pub fn set_hot_reload_enabled(engine: &Engine, enabled: bool) {
    let cx = Cx::new(engine, runtime(engine));
    let _ = cx.set(ShellRuntime::HOT_RELOAD_ENABLED, enabled);
}

/// Makes the first window's root, the loader, for the host to show. `Err`
/// when the loader shows no shell, neither the user's nor the built-in one,
/// with why.
pub fn open(engine: &Engine) -> Result<ObjectId, String> {
    let loader = make_loader(engine, Bridge::main(engine))?;
    RuntimeState::of(engine).shown.borrow_mut().push(Shown {
        id: controller::MAIN.to_owned(),
        loader,
        item: None,
        going: None,
    });
    follow(engine, loader);
    if window(engine).is_none() {
        let why = loader_error(engine, loader);
        RuntimeState::of(engine).shown.borrow_mut().clear();
        engine.destroy(loader);
        return Err(why);
    }
    RuntimeState::of(engine).view.set(Some(loader));
    Ok(loader)
}

/// The `Window` the first open window shows; none before [`open`].
pub fn window(engine: &Engine) -> Option<ObjectId> {
    RuntimeState::of(engine)
        .shown
        .borrow()
        .first()
        .and_then(|s| s.item)
}

/// The `Window` window `id` shows.
pub fn root_of(engine: &Engine, id: &str) -> Option<ObjectId> {
    RuntimeState::of(engine)
        .shown
        .borrow()
        .iter()
        .find(|s| s.id == id)
        .and_then(|s| s.item)
}

/// The loader of window `id`.
pub fn loader_of(engine: &Engine, id: &str) -> Option<ObjectId> {
    RuntimeState::of(engine)
        .shown
        .borrow()
        .iter()
        .find(|s| s.id == id)
        .map(|s| s.loader)
}

/// The opener of [`controller::set_window_opener`]: a loader for `window`,
/// whose shell is a platform window of its own (desktop-qt's
/// ShellWindows::add, an engine per window there). A window that shows no
/// shell is closed again, so that it is not left open and unclosable; a
/// restored one keeps what it saved, a new one is not saved.
pub fn open_window(engine: &Engine, window: &controller::Window) {
    let made = make_loader(engine, window.bridge);
    let loader = match made {
        Ok(loader) => loader,
        Err(why) => return set_aside(engine, &window.id, &why),
    };
    RuntimeState::of(engine).shown.borrow_mut().push(Shown {
        id: window.id.clone(),
        loader,
        item: None,
        going: None,
    });
    follow(engine, loader);
    if root_of(engine, &window.id).is_none() {
        let why = loader_error(engine, loader);
        forget(engine, &window.id);
        engine.destroy(loader);
        return set_aside(engine, &window.id, &why);
    }
    // A reload that makes the loaders again (a full one) makes this one
    // again in its scope too: the host gives only the first window's.
    let id = window.id.clone();
    let _ = engine.remake_on_reload(loader, move |engine, old, new| {
        replaced(engine, &id, old, new)
    });
}

fn set_aside(engine: &Engine, id: &str, why: &str) {
    engine.log(
        LogLevel::Critical,
        "hal_c2.shell",
        format!("window {id}: {why}"),
    );
    controller::set_aside_window(engine, id);
}

/// Lets go of closed window `id`'s shell, before its bridge goes. The
/// host's own is only hidden, as the host shows its loader while the app
/// runs.
pub fn window_closed(engine: &Engine, id: &str) {
    let state = RuntimeState::of(engine);
    let shown = {
        let mut shown = state.shown.borrow_mut();
        let Some(at) = shown.iter().position(|s| s.id == id) else {
            return;
        };
        shown.remove(at)
    };
    if state.view.get() == Some(shown.loader) {
        if let Some(item) = shown.item {
            let _ = engine.invoke_by_name(item, "hide", &[]);
        }
    } else {
        engine.destroy(shown.loader);
    }
}

/// Makes the user's shell again, or the built-in one when the user's does
/// not load: `Runtime.reload()`, as ShellRuntime's. Every window's loader
/// looks at its source anew.
pub fn reload(engine: &Engine) {
    let loaders: Vec<ObjectId> = RuntimeState::of(engine)
        .shown
        .borrow()
        .iter()
        .map(|s| s.loader)
        .collect();
    for loader in loaders {
        // A ShellLoader loads again only when its source changes, and an
        // empty source would make the built-in shell first. So the source
        // goes between two spellings of the same file, the name and its
        // address, and the user's shell is made once (the built-in one only
        // when it fails).
        let address = engine.resolve_url(loader, USER_SHELL);
        let now = match engine.read_by_name(loader, "source") {
            Value::Url(url) => url.as_str().to_owned(),
            other => engine.to_js_string(&other).to_string(),
        };
        let next = if now == USER_SHELL {
            address
        } else {
            USER_SHELL.to_owned()
        };
        let _ = engine.write_by_name(loader, "source", Value::Url(Atom::from(next.as_str())));
    }
}

/// After the app applied a save of the user's files (or failed to): a
/// loader a reload made again takes its window's place, and `Runtime`
/// says what the first window shows now. On the Engine thread, before the
/// reload is finished (`Engine::reload_counterpart`).
pub fn reloaded(engine: &Engine) {
    let state = RuntimeState::of(engine);
    let gone: Vec<(String, ObjectId)> = state
        .shown
        .borrow()
        .iter()
        .filter(|s| !engine.is_alive(s.loader))
        .map(|s| (s.id.clone(), s.loader))
        .collect();
    for (id, old) in gone {
        match engine.reload_counterpart(old) {
            Some(new) => replaced(engine, &id, old, new),
            None => engine.log(
                LogLevel::Warning,
                "hal_c2.shell",
                format!("window {id}: its shell went in a reload, and none took its place"),
            ),
        }
    }
    sync(engine);
}

/// Why the config dir's `shell.qml` did not load, when the built-in shell
/// stands in for it.
pub fn user_shell_failed(engine: &Engine) -> Option<String> {
    sync(engine);
    let cx = Cx::new(engine, runtime(engine));
    cx.get(ShellRuntime::LAST_ERROR)
        .ok()
        .map(|e| e.to_string())
        .filter(|e| !e.is_empty())
}

/// The loader for the window of `bridge`, made in its scope so that it,
/// and every shell it makes, reads the window's own singletons.
fn make_loader(engine: &Engine, bridge: Bridge) -> Result<ObjectId, String> {
    bridge
        .in_scope(engine, || engine.create_from_url(MAIN, None, Vec::new()))
        .map_err(|e| e.to_string())
}

/// Window `id`'s loader `new` goes on for `old`.
fn replaced(engine: &Engine, id: &str, old: ObjectId, new: ObjectId) {
    {
        let state = RuntimeState::of(engine);
        if state.view.get() == Some(old) {
            state.view.set(Some(new));
        }
        let mut shown = state.shown.borrow_mut();
        let Some(entry) = shown.iter_mut().find(|s| s.id == id && s.loader == old) else {
            return;
        };
        entry.loader = new;
    }
    follow(engine, new);
}

fn forget(engine: &Engine, id: &str) {
    RuntimeState::of(engine)
        .shown
        .borrow_mut()
        .retain(|s| s.id != id);
}

/// Follows what `loader` shows, from now on.
fn follow(engine: &Engine, loader: ObjectId) {
    for signal in ["itemChanged", "statusChanged", "errorChanged"] {
        let _ = engine.connect_by_name(loader, signal, move |engine, _| shown(engine, loader));
    }
    shown(engine, loader);
}

/// `loader` shows another shell, or says something else about it.
fn shown(engine: &Engine, loader: ObjectId) {
    let state = RuntimeState::of(engine);
    let item = engine.read_by_name(loader, "item").as_object();
    let (at, old) = {
        let mut shown = state.shown.borrow_mut();
        // One a later loader took the place of says nothing.
        let Some(at) = shown.iter().position(|s| s.loader == loader) else {
            return;
        };
        let entry = &mut shown[at];
        if entry.item == item {
            drop(shown);
            return sync(engine);
        }
        let before = std::mem::replace(&mut entry.item, item);
        if item.is_none() {
            entry.going = before.or(entry.going);
            drop(shown);
            return sync(engine);
        }
        (at, before.or(entry.going.take()))
    };
    let id = state.shown.borrow()[at].id.clone();
    if let Some(new) = item {
        controller::attach_root(engine, &id, new);
        if let Some(old) = old.filter(|old| engine.is_alive(*old)) {
            // The new shell takes the platform window and what the shell
            // asked of it.
            crate::platform_window::root_replaced(engine, old, new);
            #[cfg(target_os = "macos")]
            crate::macos_window::root_replaced(engine, old, new);
        }
        if at == 0 {
            let cx = Cx::new(engine, runtime(engine));
            let generation = cx.get(ShellRuntime::GENERATION).unwrap_or_default() + 1;
            let _ = cx.set(ShellRuntime::GENERATION, generation);
            // A window the broken shell could not show comes back now.
            controller::reopen_set_aside(engine);
        }
    }
    sync(engine);
}

/// `usingUserShell` and `lastError` from the first window's loader and
/// the last reload: a save that did not apply says why, then a user's
/// shell that does not load does. A user with no `shell.qml` is no error.
fn sync(engine: &Engine) {
    let Some(loader) = RuntimeState::of(engine)
        .shown
        .borrow()
        .first()
        .map(|s| s.loader)
    else {
        return;
    };
    if !engine.is_alive(loader) {
        return;
    }
    let using = engine.read_by_name(loader, "status").to_number() as i32 == READY;
    let error = match engine.last_reload_error() {
        Some(fault) => fault.to_string(),
        None if user_shell_exists(engine) => loader_error(engine, loader),
        None => String::new(),
    };
    let cx = Cx::new(engine, runtime(engine));
    let _ = cx.set(ShellRuntime::USING_USER_SHELL, using);
    let _ = cx.set(ShellRuntime::LAST_ERROR, Atom::from(error.as_str()));
}

fn user_shell_exists(engine: &Engine) -> bool {
    RuntimeState::of(engine)
        .user_shell
        .borrow()
        .as_deref()
        .is_some_and(Path::is_file)
}

fn loader_error(engine: &Engine, loader: ObjectId) -> String {
    match engine.read_by_name(loader, "error") {
        Value::String(s) => s.to_string(),
        _ => String::new(),
    }
}
