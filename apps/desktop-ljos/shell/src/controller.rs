//! The shell's pieces and its windows, desktop-qt's NativeController,
//! NativeShell and NativeWindow: each controller publishes its part of
//! `Shell.state` and handles the actions that are its own.
//!
//! [`start`] builds the shared controllers (settings, alerts, ...) once and
//! the first window: its own [`Bridge`] and a fresh set of every
//! [`Scope::Window`] controller, in name order, their state keys declared
//! before any QML binds them. [`open_window`] builds another such set on a
//! bridge of its own, [`close_window`] drops it. Each window's bridge offers
//! its actions to its own controllers and the shared ones, in name order,
//! until one handles them. [`activate`] follows once the shell has what
//! they show.
//!
//! A window's controllers run as their window ([`Bridge::act`]): building,
//! the actions it dispatched, their callbacks ([`Me`]), their MC's answers
//! ([`WindowMc`]) and their timers ([`every`]). So [`Bridge::of`],
//! [`controller`] and [`with`] find that window's bridge and controllers.
//! A shared controller runs as whichever window acts; one that made an MC
//! call hears the answer as the window that asked.
//!
//! A controller is a `RefCell` the shell borrows to run it. Its callbacks
//! go through its [`Me`], which borrows it the same way; while one runs, a
//! `Shell.dispatch` its publishing set off waits and runs right after it
//! returns (see [`Bridge::dispatch`]), so no controller is ever entered
//! twice.
//!
//! What every window shares and Ljós keeps once per engine stays engine
//! wide: the hooks of the shared controllers (settings, ...) wake every
//! window's closures, each as its own window. QML still finds the first
//! window's singletons (see [`Bridge::singleton`]), so the app shows one
//! window; the others are built and run headless until the shell's
//! singletons are window-scoped (TODO(#569), [`set_window_opener`]).

use std::any::Any;
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};

use ljos::prelude::{Application, Engine, ObjectId, QtObject, Value};

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::json::Json;
use crate::mc::Mc;
use crate::window_mc::WindowMc;

pub trait Controller: 'static {
    fn new(init: Init<'_, Self>) -> Self
    where
        Self: Sized;
    /// Once the shell has its MC's first snapshot; again when the sidebar
    /// changes hands, so it must be idempotent.
    fn activate(&mut self, _engine: &Engine) {}
    /// The sidebar came from the cache and the MC has not answered: show what
    /// can be shown of it, decide nothing. May come more than once.
    fn preview(&mut self, _engine: &Engine) {}
    /// An action dispatched to the shell; true when it was this one's.
    /// Controllers see actions in name order, so claim disjoint ones.
    fn handle(&mut self, _engine: &Engine, _action: &str, _payload: &Json) -> bool {
        false
    }
    /// A shared controller meets each window once that window is active.
    fn attach(&mut self, _engine: &Engine, _window: &Window) {}
}

/// What a controller is built with.
pub struct Init<'a, C> {
    pub engine: &'a Engine,
    /// Its window's; the first window's for a shared controller.
    pub bridge: Bridge,
    pub mc: Rc<dyn Mc>,
    /// For its own callbacks.
    pub me: Me<C>,
}

/// A controller's handle on itself, for the callbacks it registers.
pub struct Me<C> {
    controller: Weak<RefCell<C>>,
    /// A window controller's window; none for a shared one.
    window: Option<Bridge>,
}

impl<C> Clone for Me<C> {
    fn clone(&self) -> Self {
        Me {
            controller: self.controller.clone(),
            window: self.window,
        }
    }
}

impl<C: 'static> Me<C> {
    /// Runs `f` with the bridge it runs on: as the controller's window, or
    /// as whichever acts for a shared controller. None once its window is
    /// gone.
    fn as_window<R>(&self, engine: &Engine, f: impl FnOnce(Bridge) -> R) -> Option<R> {
        match self.window {
            Some(window) => window.if_open(engine, || f(window)),
            None => Some(f(Bridge::of(engine))),
        }
    }

    /// Runs `f` on the controller, unless it is gone. Actions dispatched
    /// meanwhile run after it. `f` may borrow, so it cannot wait: the
    /// controller must not be running (use [`Me::run_after`] for a callback
    /// that can come while it is).
    pub fn run(&self, engine: &Engine, f: impl FnOnce(&mut C, &Engine)) {
        let Some(me) = self.controller.upgrade() else {
            return;
        };
        self.as_window(engine, |bridge| {
            bridge.hold(engine, || f(&mut me.borrow_mut(), engine))
        });
    }

    /// Runs `f` on the controller, unless it is gone, as [`Me::run`] does
    /// when the controller is free. A callback that comes while the
    /// controller is running (one it set off itself, a route it published)
    /// cannot borrow it: `f` waits in the bridge's queue and runs once the
    /// controller returns, in order with the actions dispatched meanwhile. A
    /// controller borrowed outside the bridge's hold (a test holding it)
    /// stays borrowed past that, and `f` is dropped rather than queued
    /// again.
    pub fn run_after(&self, engine: &Engine, f: impl FnOnce(&mut C, &Engine) + 'static) {
        self.run_at(engine, f, true);
    }

    fn run_at(&self, engine: &Engine, f: impl FnOnce(&mut C, &Engine) + 'static, retry: bool) {
        let Some(me) = self.controller.upgrade() else {
            return;
        };
        // Held either way: what `f` dispatches waits for it to return.
        let busy = self.as_window(engine, |bridge| {
            let busy = bridge.hold(engine, || match me.try_borrow_mut() {
                Ok(mut c) => {
                    f(&mut c, engine);
                    None
                }
                Err(_) => Some(f),
            });
            (bridge, busy)
        });
        if let (Some((bridge, Some(f))), true) = (busy, retry) {
            let this = self.clone();
            bridge.defer(engine, move |engine| this.run_at(engine, f, false));
        }
    }
}

/// One controller per window, or one for the process that every window
/// shares (settings, alerts).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    Window,
    Shared,
}

type Create = fn(&Engine, Bridge, Rc<dyn Mc>, Option<Bridge>) -> Entry;

#[derive(Clone, Copy)]
pub struct Registration {
    /// Orders building, activating and handling.
    pub name: &'static str,
    /// The `Shell.state` keys it publishes.
    pub state_keys: &'static [&'static str],
    pub scope: Scope,
    create: Create,
}

impl Registration {
    pub fn new<C: Controller>(
        name: &'static str,
        state_keys: &'static [&'static str],
        scope: Scope,
    ) -> Self {
        Registration {
            name,
            state_keys,
            scope,
            create: create::<C>,
        }
    }
}

fn create<C: Controller>(
    engine: &Engine,
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    window: Option<Bridge>,
) -> Entry {
    let controller: Rc<RefCell<C>> = Rc::new_cyclic(|weak| {
        RefCell::new(C::new(Init {
            engine,
            bridge,
            mc,
            me: Me {
                controller: weak.clone(),
                window,
            },
        }))
    });
    Entry {
        name: "",
        run: controller.clone(),
        any: controller,
    }
}

struct Entry {
    name: &'static str,
    run: Rc<RefCell<dyn Controller>>,
    any: Rc<dyn Any>,
}

/// A controller under its registration name.
type Handler = (&'static str, Rc<RefCell<dyn Controller>>);

/// What shows a window [`open_window`] built: makes its native window.
pub type Opener = Rc<dyn Fn(&Engine, &Window)>;

/// The action, and the command, that opens another window.
pub const NEW_WINDOW: &str = "window.new";
/// The first window's id while no other was ever saved.
pub const MAIN: &str = "main";
const WINDOWS_DIR: &str = "shell-windows";

/// A window of the shell: its id, its bridge and its own controllers.
pub struct Window {
    pub id: String,
    pub bridge: Bridge,
    controllers: RefCell<Vec<Entry>>,
    /// Its controllers and the shared ones, in name order.
    handlers: RefCell<Vec<Handler>>,
    mc: Rc<WindowMc>,
    /// What its controllers' timers belong to, gone with it.
    owner: Option<ObjectId>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum Stage {
    #[default]
    Starting,
    Previewing,
    Active,
}

#[derive(Default)]
struct Host {
    registrations: RefCell<Vec<Registration>>,
    shared: RefCell<Vec<Entry>>,
    /// The open windows, oldest first.
    windows: RefCell<Vec<Rc<Window>>>,
    mc: RefCell<Option<Rc<dyn Mc>>>,
    /// The shared controllers' MC, also what [`mc`] gives.
    shared_mc: RefCell<Option<Rc<dyn Mc>>>,
    stage: Cell<Stage>,
    state_dir: RefCell<Option<PathBuf>>,
    opener: RefCell<Option<Opener>>,
}

impl Host {
    fn of(engine: &Engine) -> Rc<Host> {
        engine.extension::<Host>()
    }

    fn window(&self, id: &str) -> Option<Rc<Window>> {
        self.windows.borrow().iter().find(|w| w.id == id).cloned()
    }

    /// The window of `bridge`.
    fn window_of(&self, bridge: Bridge) -> Option<Rc<Window>> {
        self.windows
            .borrow()
            .iter()
            .find(|w| w.bridge == bridge)
            .cloned()
    }

    fn shared_runs(&self) -> Vec<Rc<RefCell<dyn Controller>>> {
        self.shared.borrow().iter().map(|e| e.run.clone()).collect()
    }
}

/// Builds the shared controllers of `registrations` and the first window's.
/// Call it once, after `crate::register` and [`set_state_dir`], and before
/// the QML loads.
pub fn start(engine: &Engine, mc: Rc<dyn Mc>, mut registrations: Vec<Registration>) {
    let host = Host::of(engine);
    assert!(
        host.mc.borrow().is_none(),
        "the controllers are started once"
    );
    registrations.sort_by_key(|r| r.name);
    *host.mc.borrow_mut() = Some(mc.clone());
    let shared_mc: Rc<dyn Mc> = Rc::new(WindowMc::shared(mc, Bridge::acting_now(engine)));
    *host.shared_mc.borrow_mut() = Some(shared_mc.clone());
    *host.registrations.borrow_mut() = registrations.clone();
    // Every window shows the connection's failure and what the shared
    // controllers publish.
    Bridge::share_key(engine, "backendError");
    for r in registrations.iter().filter(|r| r.scope == Scope::Shared) {
        for key in r.state_keys {
            Bridge::share_key(engine, key);
        }
    }
    let main = Bridge::main(engine);
    declare(engine, &registrations, main);
    // As no window: a shared controller is every window's.
    let shared: Vec<Entry> = registrations
        .iter()
        .filter(|r| r.scope == Scope::Shared)
        .map(|r| build(engine, r, main, shared_mc.clone(), None))
        .collect();
    *host.shared.borrow_mut() = shared;
    // desktop-qt's setStoreDirs: the first window is the first one saved.
    let id = saved_windows(&host)
        .into_iter()
        .next()
        .unwrap_or_else(|| MAIN.to_owned());
    add_window(engine, &host, id, main);
}

fn declare(engine: &Engine, registrations: &[Registration], bridge: Bridge) {
    for r in registrations {
        for key in r.state_keys {
            bridge.declare_key(engine, key);
        }
    }
}

fn build(
    engine: &Engine,
    r: &Registration,
    bridge: Bridge,
    mc: Rc<dyn Mc>,
    window: Option<Bridge>,
) -> Entry {
    let entry = bridge.hold(engine, || (r.create)(engine, bridge, mc, window));
    Entry {
        name: r.name,
        ..entry
    }
}

/// A window on `bridge`, with its own controllers, offered its actions.
fn add_window(engine: &Engine, host: &Host, id: String, bridge: Bridge) -> Rc<Window> {
    let inner = host.mc.borrow().clone().expect("the shell is started");
    let mc = Rc::new(WindowMc::for_window(inner, bridge));
    let owner = engine.create_native(QtObject::default(), None).ok();
    let window = Rc::new(Window {
        id,
        bridge,
        controllers: RefCell::default(),
        handlers: RefCell::default(),
        mc: mc.clone(),
        owner,
    });
    // Listed before its controllers are built, which may read its files.
    host.windows.borrow_mut().push(window.clone());
    let registrations = host.registrations.borrow().clone();
    declare(engine, &registrations, bridge);
    let own: Vec<Entry> = bridge.act(engine, || {
        registrations
            .iter()
            .filter(|r| r.scope == Scope::Window)
            .map(|r| build(engine, r, bridge, mc.clone(), Some(bridge)))
            .collect()
    });
    let mut handlers: Vec<Handler> = own
        .iter()
        .chain(host.shared.borrow().iter())
        .map(|e| (e.name, e.run.clone()))
        .collect();
    handlers.sort_by_key(|(name, _)| *name);
    *window.controllers.borrow_mut() = own;
    *window.handlers.borrow_mut() = handlers;
    let weak = Rc::downgrade(&window);
    bridge.add_interceptor(
        engine,
        Rc::new(move |engine: &Engine, action: &str, payload: &Json| {
            let Some(window) = weak.upgrade() else {
                return false;
            };
            // The window acted in is the one in front.
            window.bridge.set_front(engine);
            if action == NEW_WINDOW && can_open(engine) {
                let id = payload.get("id").and_then(Json::as_str).map(str::to_owned);
                window.bridge.defer(engine, move |engine| {
                    open_window(engine, id.as_deref());
                });
                return true;
            }
            let handlers = window.handlers.borrow().clone();
            handlers.iter().any(|(_, c)| {
                window
                    .bridge
                    .hold(engine, || c.borrow_mut().handle(engine, action, payload))
            })
        }),
    );
    window
}

/// The shell has what the controllers show: each activates, the shared ones
/// first, then each window's, which the shared ones then meet.
pub fn activate(engine: &Engine) {
    let host = Host::of(engine);
    host.stage.set(Stage::Active);
    for c in host.shared_runs() {
        Bridge::of(engine).hold(engine, || c.borrow_mut().activate(engine));
    }
    let windows = host.windows.borrow().clone();
    for window in &windows {
        activate_window(engine, &host, window);
    }
}

fn activate_window(engine: &Engine, host: &Host, window: &Window) {
    let own: Vec<_> = window
        .controllers
        .borrow()
        .iter()
        .map(|e| e.run.clone())
        .collect();
    let shared = host.shared_runs();
    let bridge = window.bridge;
    bridge.act(engine, || {
        for c in &own {
            bridge.hold(engine, || c.borrow_mut().activate(engine));
        }
        for c in &shared {
            bridge.hold(engine, || c.borrow_mut().attach(engine, window));
        }
        if can_open(engine) {
            add_new_window_command(engine);
        }
    });
}

/// "New window" in the palette of the window acting now.
fn add_new_window_command(engine: &Engine) {
    Commands::of(engine).add(engine, NEW_WINDOW, "New window", |engine| {
        Bridge::of(engine).defer(engine, |engine| {
            open_window(engine, None);
        });
    });
}

/// What the cache has shows while the MC answers: each window's controllers
/// preview it.
pub fn preview(engine: &Engine) {
    let host = Host::of(engine);
    if host.stage.get() != Stage::Active {
        host.stage.set(Stage::Previewing);
    }
    let windows = host.windows.borrow().clone();
    for window in &windows {
        preview_window(engine, window);
    }
}

fn preview_window(engine: &Engine, window: &Window) {
    let own: Vec<_> = window
        .controllers
        .borrow()
        .iter()
        .map(|e| e.run.clone())
        .collect();
    let bridge = window.bridge;
    bridge.act(engine, || {
        for c in &own {
            bridge.hold(engine, || c.borrow_mut().preview(engine));
        }
    });
}

// ---- Windows ---------------------------------------------------------------

/// Where the windows keep their files: each one's route, panels and
/// terminals, and which are open (`shell-windows.json`). Before [`start`].
pub fn set_state_dir(engine: &Engine, dir: Option<PathBuf>) {
    *Host::of(engine).state_dir.borrow_mut() = dir;
}

/// What shows each window [`open_window`] builds. Without one the shell
/// keeps to its first window: `window.new` is not handled, there is no
/// "New window" command, and no saved window is restored.
pub fn set_window_opener(engine: &Engine, open: impl Fn(&Engine, &Window) + 'static) {
    let host = Host::of(engine);
    let had = host.opener.replace(Some(Rc::new(open))).is_some();
    // Windows already active gain the command now.
    if !had && host.stage.get() == Stage::Active {
        let bridges: Vec<Bridge> = host.windows.borrow().iter().map(|w| w.bridge).collect();
        for bridge in bridges {
            bridge.act(engine, || add_new_window_command(engine));
        }
    }
}

fn can_open(engine: &Engine) -> bool {
    Host::of(engine).opener.borrow().is_some()
}

/// A window's id names its directory, so one from an action or a saved file
/// is used only if it cannot climb out of it.
pub fn valid_window_id(id: &str) -> bool {
    (1..=32).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Opens window `id` (raised if it is open already), or a new one under a
/// fresh id when `id` is none or not a valid one. Its controllers come up
/// as far as the others are (previewing or active), the open windows are
/// saved, and the opener shows it. The window's id, unless the shell has
/// not started.
pub fn open_window(engine: &Engine, id: Option<&str>) -> Option<String> {
    let host = Host::of(engine);
    host.mc.borrow().as_ref()?;
    if let Some(open) = id.and_then(|id| host.window(id)) {
        open.bridge.window_command(engine, "raise");
        return Some(open.id.clone());
    }
    let id = match id.filter(|id| valid_window_id(id)) {
        Some(id) => id.to_owned(),
        None => hal_c2_mc::new_uuid().replace('-', "")[..12].to_owned(),
    };
    let bridge = Bridge::new_window(engine)?;
    let window = add_window(engine, &host, id.clone(), bridge);
    bridge.set_front(engine);
    match host.stage.get() {
        Stage::Active => activate_window(engine, &host, &window),
        Stage::Previewing => preview_window(engine, &window),
        Stage::Starting => {}
    }
    save_windows(&host);
    let opener = host.opener.borrow().clone();
    if let Some(open) = opener {
        open(engine, &window);
    }
    Some(id)
}

/// Closes window `id`: its controllers, what they followed and its files
/// go. The last window keeps its place and files, to reopen with, and the
/// app quits (desktop-qt's lastWindowClosed); it runs once no controller
/// is.
pub fn close_window(engine: &Engine, id: &str) {
    let id = id.to_owned();
    Bridge::of(engine).defer(engine, move |engine| close_now(engine, &id));
}

fn close_now(engine: &Engine, id: &str) {
    let host = Host::of(engine);
    let window = {
        let mut windows = host.windows.borrow_mut();
        let Some(at) = windows.iter().position(|w| w.id == id) else {
            return;
        };
        if windows.len() == 1 {
            drop(windows);
            // On macOS the app stays in the Dock, and opening it again
            // shows the window ([`attach_root`]).
            if !cfg!(target_os = "macos") {
                engine.request_quit();
            }
            return;
        }
        windows.remove(at)
    };
    save_windows(&host);
    let bridge = window.bridge;
    // As the window, so what they do on the way out stays in it.
    bridge.act(engine, || {
        window.handlers.borrow_mut().clear();
        let controllers = std::mem::take(&mut *window.controllers.borrow_mut());
        drop(controllers);
    });
    window.mc.close();
    if let Some(owner) = window.owner {
        engine.destroy(owner);
    }
    bridge.close(engine);
    // Its route, panels and terminals; the drafts are every window's.
    if let Some(dir) = host.state_dir.borrow().as_deref() {
        if id == MAIN {
            for name in [
                "shell-route.json",
                "shell-panel.json",
                "shell-terminals.json",
            ] {
                let _ = std::fs::remove_file(dir.join(name));
            }
        } else {
            let _ = std::fs::remove_dir_all(window_dir(dir, id));
        }
    }
}

/// Makes `root` what window `id` shows: closing it closes the window
/// ([`close_window`]), and the main one's shows again when its user opens
/// the app with no window shown, as a click on its Dock icon does on macOS
/// (desktop-qt's ShellRuntime::closed and ShellWindows::reopen). The app
/// keeps running with its last window closed
/// (`App::quit_on_last_window_closed(false)`): [`close_window`] says when it
/// ends.
pub fn attach_root(engine: &Engine, id: &str, root: ObjectId) {
    let closing = id.to_owned();
    let _ = engine.connect_by_name(root, "closing", move |engine, _| {
        close_window(engine, &closing)
    });
    if id != MAIN {
        return;
    }
    let Ok(app) = engine.singleton::<Application>() else {
        return;
    };
    let _ = engine.signal_index(app, "reopened").and_then(|reopened| {
        engine.connect_to(app, reopened, root, move |engine, args| {
            // A reloaded shell's old root lasts until the next frame
            // ([`crate::runtime`]): only the generation shown comes back.
            let shown = crate::runtime::window(engine).is_none_or(|w| w == root);
            if shown && matches!(args.first(), Some(Value::Bool(false))) {
                for show in ["show", "raise", "requestActivate"] {
                    let _ = engine.invoke_by_name(root, show, &[]);
                }
            }
        })
    });
}

/// Opens every saved window that is not open, once an opener can show
/// them.
pub fn restore_windows(engine: &Engine) {
    let host = Host::of(engine);
    if !can_open(engine) {
        return;
    }
    for id in saved_windows(&host) {
        if host.window(&id).is_none() {
            open_window(engine, Some(&id));
        }
    }
}

/// The open windows' ids, oldest first.
pub fn windows(engine: &Engine) -> Vec<String> {
    Host::of(engine)
        .windows
        .borrow()
        .iter()
        .map(|w| w.id.clone())
        .collect()
}

/// The bridge of open window `id`.
pub fn window_bridge(engine: &Engine, id: &str) -> Option<Bridge> {
    Host::of(engine).window(id).map(|w| w.bridge)
}

/// Runs `f` as open window `id`, as an action from it would.
pub fn in_window<R>(engine: &Engine, id: &str, f: impl FnOnce() -> R) -> Option<R> {
    let bridge = window_bridge(engine, id)?;
    Some(bridge.act(engine, f))
}

/// Runs `f` as each open window in turn; once, as is, before the shell has
/// a window.
pub fn each_window(engine: &Engine, f: impl Fn(&Engine)) {
    let bridges: Vec<Bridge> = Host::of(engine)
        .windows
        .borrow()
        .iter()
        .map(|w| w.bridge)
        .collect();
    if bridges.is_empty() {
        f(engine);
    }
    for bridge in bridges {
        bridge.if_open(engine, || f(engine));
    }
}

/// The file `name` of the window acting now (or in front), in its
/// directory: desktop-qt's NativeWindow::setStoreDirs. None without a state
/// directory.
pub fn state_file(engine: &Engine, name: &str) -> Option<PathBuf> {
    let dir = Host::of(engine).state_dir.borrow().clone()?;
    Some(window_dir(&dir, &window_id(engine)).join(name))
}

/// The id of the window acting now (see [`Bridge::of`]), `main` when there
/// is no window set.
pub fn window_id(engine: &Engine) -> String {
    Host::of(engine)
        .window_of(Bridge::of(engine))
        .map_or_else(|| MAIN.to_owned(), |w| w.id.clone())
}

/// The state directory itself for `main`, else its own under it.
fn window_dir(state: &Path, id: &str) -> PathBuf {
    if id == MAIN {
        state.to_owned()
    } else {
        state.join(WINDOWS_DIR).join(id)
    }
}

/// The saved ids that are valid, each once.
fn saved_windows(host: &Host) -> Vec<String> {
    let Some(dir) = host.state_dir.borrow().clone() else {
        return Vec::new();
    };
    let Ok(text) = std::fs::read_to_string(dir.join(format!("{WINDOWS_DIR}.json"))) else {
        return Vec::new();
    };
    let saved: Json = serde_json::from_str(&text).unwrap_or_default();
    let mut ids: Vec<String> = Vec::new();
    for id in saved
        .get("open")
        .and_then(Json::as_array)
        .into_iter()
        .flatten()
    {
        if let Some(id) = id.as_str()
            && valid_window_id(id)
            && !ids.iter().any(|kept| kept == id)
        {
            ids.push(id.to_owned());
        }
    }
    ids
}

fn save_windows(host: &Host) {
    let Some(dir) = host.state_dir.borrow().clone() else {
        return;
    };
    let ids: Vec<String> = host.windows.borrow().iter().map(|w| w.id.clone()).collect();
    let body = serde_json::json!({ "open": ids }).to_string();
    let path = dir.join(format!("{WINDOWS_DIR}.json"));
    if let Err(e) = crate::controllers::drafts::write_atomically(&path, body.as_bytes()) {
        eprintln!("hal-c2: shell windows not saved: {e}");
    }
}

// ---- Controllers -------------------------------------------------------------

/// The controller of type `C`: the acting window's, else the shared one (a
/// controller reaching another, as `NativeShell::controller<T>()`).
pub fn controller<C: Controller>(engine: &Engine) -> Option<Rc<RefCell<C>>> {
    let host = Host::of(engine);
    let find = |e: &Entry| e.any.clone().downcast::<RefCell<C>>().ok();
    if let Some(window) = host.window_of(Bridge::of(engine))
        && let Some(found) = window.controllers.borrow().iter().find_map(find)
    {
        return Some(found);
    }
    host.shared.borrow().iter().find_map(find)
}

/// Runs `f` on the controller of type `C`, unless there is none or it is
/// running now (a callback of its own that reached back into it): then
/// `None`, where a `borrow_mut` would panic. What another controller calls,
/// as `NativeShell::controller<T>()->...` does.
pub fn with<C: Controller, R>(engine: &Engine, f: impl FnOnce(&mut C, &Engine) -> R) -> Option<R> {
    let c = controller::<C>(engine)?;
    // Held, so what it dispatches waits until it is free again.
    Bridge::of(engine).hold(engine, || {
        let mut c = c.try_borrow_mut().ok()?;
        Some(f(&mut c, engine))
    })
}

/// The names of the controllers, in the order they are offered actions.
pub fn names(engine: &Engine) -> Vec<&'static str> {
    Host::of(engine)
        .registrations
        .borrow()
        .iter()
        .map(|r| r.name)
        .collect()
}

/// The MC the shell's controllers were started with, as the shared ones
/// have it: a reply comes back as the window that asked.
pub fn mc(engine: &Engine) -> Option<Rc<dyn Mc>> {
    Host::of(engine).shared_mc.borrow().clone()
}

/// A timer for a controller: `f` every `interval_ms`, from now. Stops with
/// `owner` (by default the acting window, as which `f` runs), or when
/// [`stop_timer`] is given what this returns.
pub fn every(
    engine: &Engine,
    owner: Option<ObjectId>,
    interval_ms: i32,
    f: impl Fn(&Engine) + 'static,
) -> Option<ObjectId> {
    use ljos::prelude::Timer;
    let window = Bridge::acting(engine).and_then(|b| Host::of(engine).window_of(b));
    let owner = owner.or_else(|| window.as_ref().and_then(|w| w.owner));
    let bridge = window.map(|w| w.bridge);
    let native = Timer {
        interval: interval_ms,
        repeat: true,
        running: true,
        ..Timer::default()
    };
    let timer = engine.create_native(native, owner).ok()?;
    engine
        .connect_by_name(timer, "triggered", move |engine, _| match bridge {
            Some(bridge) => {
                bridge.if_open(engine, || f(engine));
            }
            None => f(engine),
        })
        .ok()?;
    Some(timer)
}

pub fn stop_timer(engine: &Engine, timer: ObjectId) {
    engine.destroy(timer);
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;
    use ljos::App;

    struct Probe(Vec<&'static str>);

    fn engine() -> Engine {
        App::new("test").register(crate::register).build_engine()
    }

    fn probe() -> (Rc<RefCell<Probe>>, Me<Probe>) {
        let rc = Rc::new(RefCell::new(Probe(Vec::new())));
        let me = Me {
            controller: Rc::downgrade(&rc),
            window: None,
        };
        (rc, me)
    }

    #[test]
    fn a_callback_while_the_controller_runs_waits_until_it_returns() {
        let engine = engine();
        let (rc, me) = probe();
        Bridge::of(&engine).hold(&engine, || {
            let mut running = rc.borrow_mut();
            // As an MC reply the controller's own publishing set off.
            me.run_after(&engine, |c, _| c.0.push("callback"));
            running.0.push("running");
        });
        assert_eq!(rc.borrow().0, ["running", "callback"]);
    }

    #[test]
    fn callbacks_that_waited_run_in_the_order_they_came() {
        let engine = engine();
        let (rc, me) = probe();
        Bridge::of(&engine).hold(&engine, || {
            let _running = rc.borrow_mut();
            me.run_after(&engine, |c, _| c.0.push("first"));
            me.run_after(&engine, |c, _| c.0.push("second"));
        });
        assert_eq!(rc.borrow().0, ["first", "second"]);
    }

    #[test]
    fn a_callback_for_a_controller_that_is_gone_is_skipped() {
        let engine = engine();
        let (rc, me) = probe();
        drop(rc);
        let ran = Rc::new(Cell::new(false));
        let flag = ran.clone();
        me.run_after(&engine, move |_, _| flag.set(true));
        assert!(!ran.get());
    }

    #[test]
    fn a_callback_runs_at_once_when_the_controller_is_free() {
        let engine = engine();
        let (rc, me) = probe();
        me.run_after(&engine, |c, _| c.0.push("now"));
        assert_eq!(rc.borrow().0, ["now"]);
    }

    #[test]
    fn a_window_controllers_callback_runs_as_its_window_and_not_once_it_is_gone() {
        let engine = engine();
        let window = Bridge::new_window(&engine).expect("a second bridge");
        let rc = Rc::new(RefCell::new(Probe(Vec::new())));
        let me = Me {
            controller: Rc::downgrade(&rc),
            window: Some(window),
        };
        let seen = Rc::new(Cell::new(None));
        let saw = seen.clone();
        me.run(&engine, move |c, engine| {
            saw.set(Some(Bridge::of(engine)));
            c.0.push("ran");
        });
        assert_eq!(seen.get(), Some(window));
        window.close(&engine);
        me.run(&engine, |c, _| c.0.push("after"));
        assert_eq!(rc.borrow().0, ["ran"]);
    }

    #[test]
    fn window_ids_that_could_leave_their_directory_are_refused() {
        assert!(valid_window_id("main"));
        assert!(valid_window_id("a1_B-2"));
        assert!(!valid_window_id(""));
        assert!(!valid_window_id("../x"));
        assert!(!valid_window_id("a/b"));
        assert!(!valid_window_id(&"x".repeat(33)));
    }
}
