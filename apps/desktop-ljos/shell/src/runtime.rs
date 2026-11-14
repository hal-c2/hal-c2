//! `Runtime` in `HalC2.Shell`, desktop-qt's ShellRuntime: which shell the
//! window is, the user's `<config>/shell.qml` or the built-in one, made
//! again as its files change.
//!
//! [`open`] makes the first generation from what the app compiled
//! (`App::qml_dirs` over [`Roots::dirs`], so the user's `<config>/qml` is on
//! the import path), and [`reload`] (`Runtime.reload()`, or a followed file
//! changing) compiles the roots again and makes the next. A user shell that
//! does not load, or whose root is not a `Window`, falls back to the
//! built-in one with `lastError` saying why. When that fails too, the window
//! shown stays and `generation` does not move. The new window is made
//! before the old one goes.
//!
//! The config dir and the QML roots are followed: the OS watcher's thread
//! wakes the shell ([`set_wake`]), which calls [`deliver`] on the Engine
//! thread, as src/theme.rs does. 120 ms after the last change, on the
//! engine's clock, the sources' fingerprint says whether a reload is due.
//!
//! This is a reload of the whole shell and not Ljós's own hot reload
//! (`Setup::watch_roots`), which keeps the state of the QML across a save
//! but comes only with the `dev` feature, for development: a user's
//! `shell.qml` follows its files in a release too, and says through
//! `Runtime` which shell it is and why the last one failed. The state that
//! matters is in the controllers, which a reload keeps.

use std::cell::{Cell, RefCell};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use ljos::prelude::{
    Atom, Cx, Engine, LogLevel, ObjectId, QmlObject, Timer, Value, qml_impl, qml_singleton,
};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};

use crate::bridge::Bridge;
use crate::controller;
use crate::qml::{self, Roots};

/// How long after the last change a reload looks (ShellRuntime's debounce).
const DEBOUNCE_MS: i32 = 120;

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
    #[qml(notify, readonly)]
    generation: i32,
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

type Wake = Arc<dyn Fn() + Send + Sync>;

/// What the watcher thread leaves for the Engine thread.
#[derive(Default)]
struct Changes {
    pending: AtomicBool,
    wake: Mutex<Option<Wake>>,
}

impl Changes {
    fn push(&self) {
        self.pending.store(true, Ordering::SeqCst);
        let wake = self
            .wake
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone();
        if let Some(wake) = wake {
            wake();
        }
    }
}

#[derive(Default)]
struct RuntimeState {
    /// What a reload compiles; none: the runtime makes no shell.
    roots: RefCell<Option<Roots>>,
    /// `<config>/shell.qml`, when there is a config dir.
    user_shell: RefCell<Option<PathBuf>>,
    /// Each open window's root of the generation shown, by window id,
    /// oldest window first.
    shown: RefCell<Vec<(String, ObjectId)>>,
    /// The root the host shows as its view, which a reload's root takes
    /// over ([`retire`]) and closing the window only hides.
    view: Cell<Option<ObjectId>>,
    /// The sources as the generation shown was made of them.
    fingerprint: Cell<u64>,
    debounce: Cell<Option<ObjectId>>,
    watcher: RefCell<Option<RecommendedWatcher>>,
    changes: Arc<Changes>,
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

/// Gives the engine's `Runtime` the config dir and what a reload compiles,
/// `roots` (with the user's directories, [`Roots::with_user`]); none makes
/// no shell. Before the root is made.
pub fn install(engine: &Engine, config_dir: Option<&Path>, roots: Option<Roots>) {
    let cx = Cx::new(engine, runtime(engine));
    let state = RuntimeState::of(engine);
    if let Some(dir) = config_dir {
        let user_shell = dir.join("shell.qml");
        let _ = cx.set(
            ShellRuntime::CONFIG_DIR,
            Atom::from(dir.to_string_lossy().as_ref()),
        );
        let _ = cx.set(
            ShellRuntime::USER_SHELL_PATH,
            Atom::from(user_shell.to_string_lossy().as_ref()),
        );
        *state.user_shell.borrow_mut() = Some(user_shell);
    }
    *state.roots.borrow_mut() = roots;
}

/// The first generation, from the QML the engine has (the [`install`]ed
/// roots, compiled), for the host to make its root: the user's shell, or
/// the built-in one. With `watch` the files are followed from here on.
/// `Err` when neither shell can be made, with why.
pub fn open(engine: &Engine, watch: bool) -> Result<ObjectId, String> {
    let state = RuntimeState::of(engine);
    if watch {
        follow(engine, &state);
    }
    let seen = state.roots.borrow().as_ref().map(fingerprint);
    next_generation(engine, &state, seen);
    let root = window(engine).ok_or_else(|| last_error(engine))?;
    state.view.set(Some(root));
    Ok(root)
}

/// The root the first open window shows; none before [`open`].
pub fn window(engine: &Engine) -> Option<ObjectId> {
    RuntimeState::of(engine)
        .shown
        .borrow()
        .first()
        .map(|(_, root)| *root)
}

/// The root window `id` shows.
pub fn root_of(engine: &Engine, id: &str) -> Option<ObjectId> {
    RuntimeState::of(engine)
        .shown
        .borrow()
        .iter()
        .find(|(shown, _)| shown == id)
        .map(|(_, root)| *root)
}

/// The opener of [`controller::set_window_opener`]: a root of the shell
/// shown now for `window`, in a platform window of its own (desktop-qt's
/// ShellWindows::add, an engine per window there). A window no shell can
/// be made for is closed again, so that it is not left open, unclosable,
/// and saved to come back the same way.
pub fn open_window(engine: &Engine, window: &controller::Window) {
    let state = RuntimeState::of(engine);
    let made = make_shell(engine, &state, window.bridge);
    let Some(root) = made.root else {
        engine.log(
            LogLevel::Critical,
            "hal_c2.shell",
            format!("window {}: {}", window.id, made.error),
        );
        controller::close_window(engine, &window.id);
        return;
    };
    controller::attach_root(engine, &window.id, root);
    state.shown.borrow_mut().push((window.id.clone(), root));
}

/// Lets go of closed window `id`'s root, before its bridge goes: the
/// host's view is only hidden, as the host shows it while the app runs.
pub fn window_closed(engine: &Engine, id: &str) {
    let state = RuntimeState::of(engine);
    let root = {
        let mut shown = state.shown.borrow_mut();
        let Some(at) = shown.iter().position(|(shown, _)| shown == id) else {
            return;
        };
        shown.remove(at).1
    };
    if state.view.get() == Some(root) {
        let _ = engine.invoke_by_name(root, "hide", &[]);
    } else {
        engine.destroy(root);
    }
}

/// Compiles the roots again and makes the next generation, as ShellRuntime
/// does on `reload()` and when a followed file changed.
pub fn reload(engine: &Engine) {
    let state = RuntimeState::of(engine);
    let Some(roots) = state.roots.borrow().clone() else {
        return;
    };
    // Before the files are read: one saved while this reload runs is a
    // change the next debounce sees.
    let seen = fingerprint(&roots);
    match qml::compile(&roots) {
        Ok(compiled) => {
            engine.set_component_source(compiled.source);
            // Plugin pages are QML text; a fresh compiler reads the files
            // as they are now, as `App::qml_dirs` gave the first one.
            if let Ok(dirs) = roots.dirs() {
                let paths: Vec<&Path> = dirs.iter().map(PathBuf::as_path).collect();
                ljos::dev::install_text_compiler(engine, &paths);
            }
            next_generation(engine, &state, Some(seen));
        }
        // A root that cannot be read: what is shown stays, and says why.
        Err(e) => {
            let cx = Cx::new(engine, runtime(engine));
            let _ = cx.set(ShellRuntime::LAST_ERROR, Atom::from(e.as_str()));
            state.fingerprint.set(seen);
            let _ = cx.notify(ShellRuntime::GENERATION.index);
        }
    }
}

/// Says what to run, on any thread, when a followed file changed: post a
/// message to the Engine thread, which calls [`deliver`].
pub fn set_wake(engine: &Engine, wake: impl Fn() + Send + Sync + 'static) {
    let wake: Wake = Arc::new(wake);
    *RuntimeState::of(engine)
        .changes
        .wake
        .lock()
        .unwrap_or_else(PoisonError::into_inner) = Some(wake);
}

/// Starts the debounce again when a followed file changed. On the Engine
/// thread.
pub fn deliver(engine: &Engine) {
    let state = RuntimeState::of(engine);
    if !state.changes.pending.swap(false, Ordering::SeqCst) {
        return;
    }
    if let Some(timer) = state.debounce.get() {
        // From the start: running again counts the interval anew.
        let _ = engine.write_by_name(timer, "running", Value::Bool(false));
        let _ = engine.write_by_name(timer, "running", Value::Bool(true));
    }
}

fn last_error(engine: &Engine) -> String {
    let cx = Cx::new(engine, runtime(engine));
    cx.get(ShellRuntime::LAST_ERROR)
        .map(|e| e.to_string())
        .unwrap_or_default()
}

/// A shell root for the window of `bridge`, made in its scope so that it
/// reads the window's own singletons ([`Bridge::in_scope`]).
struct Made {
    root: Option<ObjectId>,
    using_user_shell: bool,
    error: String,
}

/// The user's shell if there is one and it loads, else the built-in one.
fn make_shell(engine: &Engine, state: &RuntimeState, bridge: Bridge) -> Made {
    bridge.in_scope(engine, || {
        let mut error = String::new();
        let user_shell = state.user_shell.borrow().clone();
        if let Some(path) = user_shell.filter(|p| p.is_file()) {
            match make(engine, qml::USER_SHELL, &path.to_string_lossy()) {
                Ok(root) => {
                    return Made {
                        root: Some(root),
                        using_user_shell: true,
                        error,
                    };
                }
                Err(e) => {
                    engine.log(
                        LogLevel::Warning,
                        "hal_c2.shell",
                        format!("user shell failed, falling back to default: {e}"),
                    );
                    error = e;
                }
            }
        }
        match make(engine, qml::DEFAULT_SHELL, qml::DEFAULT_SHELL) {
            Ok(root) => Made {
                root: Some(root),
                using_user_shell: false,
                error,
            },
            Err(e) => {
                engine.log(
                    LogLevel::Critical,
                    "hal_c2.shell",
                    format!("default shell failed: {e}"),
                );
                let error = if error.is_empty() {
                    e
                } else {
                    format!("{error}\n{e}")
                };
                Made {
                    root: None,
                    using_user_shell: false,
                    error,
                }
            }
        }
    })
}

/// The windows a generation is made for: the open ones, oldest first, or
/// the first window's alone before the controllers have started.
fn targets(engine: &Engine) -> Vec<(String, Bridge)> {
    let open: Vec<(String, Bridge)> = controller::windows(engine)
        .into_iter()
        .filter_map(|id| controller::window_bridge(engine, &id).map(|b| (id, b)))
        .collect();
    if open.is_empty() {
        vec![(controller::MAIN.to_owned(), Bridge::main(engine))]
    } else {
        open
    }
}

/// The next generation of every open window's root, in place of the one
/// shown (ShellRuntime::reload, which each window's runtime does). `seen`
/// is the sources' fingerprint from before they were compiled. What the
/// runtime says (`usingUserShell`, `lastError`) is the first window's.
fn next_generation(engine: &Engine, state: &RuntimeState, seen: Option<u64>) {
    let cx = Cx::new(engine, runtime(engine));
    if let Some(seen) = seen {
        state.fingerprint.set(seen);
    }
    let generation = cx.get(ShellRuntime::GENERATION).unwrap_or_default() + 1;
    let mut first: Option<Made> = None;
    for (id, bridge) in targets(engine) {
        let made = make_shell(engine, state, bridge);
        if let Some(root) = made.root {
            controller::attach_root(engine, &id, root);
            let old = {
                let mut shown = state.shown.borrow_mut();
                match shown.iter_mut().find(|(shown, _)| *shown == id) {
                    Some(entry) => Some(std::mem::replace(&mut entry.1, root)),
                    None => {
                        shown.push((id.clone(), root));
                        None
                    }
                }
            };
            if let Some(old) = old {
                retire(engine, state, old, root, generation);
            }
        }
        first.get_or_insert(made);
    }
    let first = first.expect("a generation has a window");
    let _ = cx.set(ShellRuntime::LAST_ERROR, Atom::from(first.error.as_str()));
    if first.root.is_none() {
        // Neither: the window shown stays, and the overlay says why until
        // the next change tries again.
        let _ = cx.notify(ShellRuntime::GENERATION.index);
        return;
    }
    let _ = cx.set(ShellRuntime::USING_USER_SHELL, first.using_user_shell);
    let _ = cx.set(ShellRuntime::GENERATION, generation);
}

/// A window of `key`, or why there is none. `name` is what the error calls
/// it.
fn make(engine: &Engine, key: &str, name: &str) -> Result<ObjectId, String> {
    let made = engine
        .create_from_url(key, None, Vec::new())
        .map_err(|e| e.to_string())?;
    if engine
        .meta_of(made)
        .is_some_and(|m| m.inherits_name("Window"))
    {
        return Ok(made);
    }
    engine.destroy(made);
    Err(format!("Shell root must be a Window: {name}"))
}

/// Lets the previous generation's window go: `new` takes the platform
/// window `old` had, which is destroyed before the next frame, and what the
/// shell asked of that window. A window no host shows (a headless test's)
/// is destroyed now, and `new` opens one of its own.
///
/// Each swap is logged (`hal_c2.shell`, which the app prints): a window
/// left empty after a reload says here whether the swap was asked, and the
/// host's warning that it "cannot be shown" says whether it was made.
fn retire(engine: &Engine, state: &RuntimeState, old: ObjectId, new: ObjectId, generation: i32) {
    if !engine.is_alive(old) {
        // The host destroys a root it could not show, and keeps the one
        // before it.
        engine.log(
            LogLevel::Warning,
            "hal_c2.shell",
            format!(
                "generation {}: the window shown before, {old:?}, was not shown",
                generation - 1
            ),
        );
    }
    crate::platform_window::root_replaced(engine, old, new);
    #[cfg(target_os = "macos")]
    crate::macos_window::root_replaced(engine, old, new);
    match ljos::window::replace_root(engine, old, new) {
        Ok(()) => {
            if state.view.get() == Some(old) {
                state.view.set(Some(new));
            }
            engine.log(
                LogLevel::Info,
                "hal_c2.shell",
                format!("generation {generation}: {new:?} takes the window of {old:?}"),
            )
        }
        Err(e) => {
            engine.log(
                LogLevel::Info,
                "hal_c2.shell",
                format!("generation {generation}: {new:?} opens a window of its own ({e})"),
            );
            engine.destroy(old);
        }
    }
}

/// Follows the config dir and the roots, and makes the debounce timer.
fn follow(engine: &Engine, state: &Rc<RuntimeState>) {
    let Some(roots) = state.roots.borrow().clone() else {
        return;
    };
    let timer = Timer {
        interval: DEBOUNCE_MS,
        repeat: false,
        running: false,
        ..Timer::default()
    };
    let Ok(timer) = engine.create_native(timer, None) else {
        return;
    };
    let weak = Rc::downgrade(state);
    let _ = engine.connect_by_name(timer, "triggered", move |engine, _| {
        let Some(state) = weak.upgrade() else { return };
        let due = state
            .roots
            .borrow()
            .as_ref()
            .is_some_and(|roots| fingerprint(roots) != state.fingerprint.get());
        if due {
            reload(engine);
        }
    });
    state.debounce.set(Some(timer));
    let watcher = watch(&roots.watched(), &state.changes);
    let enabled = watcher.is_some();
    *state.watcher.borrow_mut() = watcher;
    let cx = Cx::new(engine, runtime(engine));
    let _ = cx.set(ShellRuntime::HOT_RELOAD_ENABLED, enabled);
}

/// One OS watcher over `dirs`, each with all below it; none when the first
/// (the config dir, else the bricks) cannot be followed.
fn watch(dirs: &[PathBuf], changes: &Arc<Changes>) -> Option<RecommendedWatcher> {
    let changes = changes.clone();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        // A source, or what may be a directory of them.
        if let Ok(event) = event
            && !event.kind.is_access()
            && event
                .paths
                .iter()
                .any(|p| is_source(p) || p.extension().is_none())
        {
            changes.push();
        }
    })
    .ok()?;
    let (first, rest) = dirs.split_first()?;
    watcher.watch(first, RecursiveMode::Recursive).ok()?;
    for dir in rest {
        let _ = watcher.watch(dir, RecursiveMode::Recursive);
    }
    Some(watcher)
}

/// A file a shell is made of: `.qml`, `.js` or a `qmldir`.
fn is_source(path: &Path) -> bool {
    path.file_name().is_some_and(|n| n == "qmldir")
        || path.extension().is_some_and(|e| e == "qml" || e == "js")
}

/// The path, time and size of every source under the followed directories:
/// what tells a change from an event that changed nothing (an editor's
/// backup file, the shell's own preferences).
fn fingerprint(roots: &Roots) -> u64 {
    let mut found = Vec::new();
    for dir in roots.watched() {
        sources(&dir, &mut found);
    }
    found.sort();
    let mut hasher = DefaultHasher::new();
    found.hash(&mut hasher);
    hasher.finish()
}

fn sources(dir: &Path, found: &mut Vec<(PathBuf, Option<std::time::SystemTime>, u64)>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        // Not through a link: a link to a parent would never end.
        match entry.file_type() {
            Ok(t) if t.is_dir() => sources(&path, found),
            Ok(_) if is_source(&path) => {
                let meta = std::fs::metadata(&path).ok();
                found.push((
                    path,
                    meta.as_ref().and_then(|m| m.modified().ok()),
                    meta.map_or(0, |m| m.len()),
                ));
            }
            _ => {}
        }
    }
}
