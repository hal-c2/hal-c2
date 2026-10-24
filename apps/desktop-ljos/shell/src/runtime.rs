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
//! (ARCHITECTURE.md §12.1, `Setup::watch`), which keeps the state of the
//! QML across a save. TODO(ljos#?): Ljós's watcher follows one root with a
//! fixed entry, and the facade offers it only with the `mcp` feature. The
//! shell has an import path of several roots (the user's, the bricks, its
//! own), and changes its entry when the user's shell comes or goes or fails.
//! The state that matters is in the controllers, which a reload keeps.

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
    /// The window of the generation shown.
    shown: Cell<Option<ObjectId>>,
    /// The window the host made its root, which stays (hidden) once another
    /// generation is shown, as a root cannot be replaced (see [`retire`]).
    root: Cell<Option<ObjectId>>,
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
    next_generation(engine, &state);
    let root = state.shown.get().ok_or_else(|| last_error(engine))?;
    state.root.set(Some(root));
    Ok(root)
}

/// The window of the generation shown; none before [`open`].
pub fn window(engine: &Engine) -> Option<ObjectId> {
    RuntimeState::of(engine).shown.get()
}

/// Compiles the roots again and makes the next generation, as ShellRuntime
/// does on `reload()` and when a followed file changed.
pub fn reload(engine: &Engine) {
    let state = RuntimeState::of(engine);
    let Some(roots) = state.roots.borrow().clone() else {
        return;
    };
    match qml::compile(&roots) {
        Ok(compiled) => {
            engine.set_component_source(compiled.source);
            next_generation(engine, &state);
        }
        // A root that cannot be read: what is shown stays, and says why.
        Err(e) => {
            let cx = Cx::new(engine, runtime(engine));
            let _ = cx.set(ShellRuntime::LAST_ERROR, Atom::from(e.as_str()));
            state.fingerprint.set(fingerprint(&roots));
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

/// The user's shell if there is one and it loads, else the built-in one,
/// in place of the generation shown (ShellRuntime::reload).
fn next_generation(engine: &Engine, state: &RuntimeState) {
    let cx = Cx::new(engine, runtime(engine));
    let mut error = String::new();
    let mut made = None;
    let mut using_user_shell = false;
    let user_shell = state.user_shell.borrow().clone();
    if let Some(path) = user_shell.filter(|p| p.is_file()) {
        match make(engine, qml::USER_SHELL, &path.to_string_lossy()) {
            Ok(window) => {
                made = Some(window);
                using_user_shell = true;
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
    if made.is_none() {
        match make(engine, qml::DEFAULT_SHELL, qml::DEFAULT_SHELL) {
            Ok(window) => made = Some(window),
            Err(e) => {
                engine.log(
                    LogLevel::Critical,
                    "hal_c2.shell",
                    format!("default shell failed: {e}"),
                );
                error = if error.is_empty() {
                    e
                } else {
                    format!("{error}\n{e}")
                };
            }
        }
    }
    if let Some(roots) = state.roots.borrow().as_ref() {
        state.fingerprint.set(fingerprint(roots));
    }
    let _ = cx.set(ShellRuntime::LAST_ERROR, Atom::from(error.as_str()));
    let Some(window) = made else {
        // Neither: the window shown stays, and the overlay says why until
        // the next change tries again.
        let _ = cx.notify(ShellRuntime::GENERATION.index);
        return;
    };
    if let Some(old) = state.shown.replace(Some(window)) {
        retire(engine, state, old);
    }
    let generation = cx.get(ShellRuntime::GENERATION).unwrap_or_default() + 1;
    let _ = cx.set(ShellRuntime::USING_USER_SHELL, using_user_shell);
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

/// Lets the previous generation's window go. The host's root is hidden and
/// kept instead: Ljós shows another `Window` in a window of its own, but has
/// no way for the app to replace its root, which stays the platform's first
/// window. TODO(ljos#?): replace the root with the new generation's window,
/// as `QuickScene::replace_root` does for Ljós's own reload.
fn retire(engine: &Engine, state: &RuntimeState, old: ObjectId) {
    if state.root.get() == Some(old) {
        let _ = engine.write_by_name(old, "visible", Value::Bool(false));
    } else {
        engine.destroy(old);
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
