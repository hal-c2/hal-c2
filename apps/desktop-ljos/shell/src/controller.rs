//! The shell's pieces, desktop-qt's NativeController and NativeShell: each
//! controller publishes its part of `Shell.state` and handles the actions
//! that are its own.
//!
//! [`start`] builds every registered controller in name order (shared ones
//! first), declares their state keys before any QML binds them, and offers
//! them each dispatched action in name order until one handles it.
//! [`activate`] follows once the shell has what they show.
//!
//! A controller is a `RefCell` the shell borrows to run it. Its callbacks
//! (an MC reply, a timer) go through its [`Me`], which borrows it the same
//! way; while one runs, a `Shell.dispatch` its publishing set off waits and
//! runs right after it returns (see [`Bridge::dispatch`]), so no controller
//! is ever entered twice.

use std::any::Any;
use std::cell::RefCell;
use std::rc::{Rc, Weak};

use ljos::prelude::{Engine, ObjectId};

use crate::bridge::Bridge;
use crate::json::Json;
use crate::mc::Mc;

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
    pub bridge: Bridge,
    pub mc: Rc<dyn Mc>,
    /// For its own callbacks.
    pub me: Me<C>,
}

/// A controller's handle on itself, for the callbacks it registers.
pub struct Me<C>(Weak<RefCell<C>>);

impl<C> Clone for Me<C> {
    fn clone(&self) -> Self {
        Me(self.0.clone())
    }
}

impl<C: 'static> Me<C> {
    /// Runs `f` on the controller, unless it is gone. Actions dispatched
    /// meanwhile run after it.
    pub fn run(&self, engine: &Engine, f: impl FnOnce(&mut C, &Engine)) {
        let Some(me) = self.0.upgrade() else { return };
        Bridge::of(engine).hold(engine, || f(&mut me.borrow_mut(), engine));
    }
}

/// One controller per window, or one for the process that every window
/// shares (settings, alerts).
///
/// Ljós makes a singleton per engine, not per window, so the shell has one
/// window and each scope one controller; the scope still orders building and
/// attaching as desktop-qt does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    Window,
    Shared,
}

pub struct Registration {
    /// Orders building, activating and handling.
    pub name: &'static str,
    /// The `Shell.state` keys it publishes.
    pub state_keys: &'static [&'static str],
    pub scope: Scope,
    create: fn(&Engine, Bridge, Rc<dyn Mc>) -> Entry,
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

fn create<C: Controller>(engine: &Engine, bridge: Bridge, mc: Rc<dyn Mc>) -> Entry {
    let controller: Rc<RefCell<C>> = Rc::new_cyclic(|weak| {
        RefCell::new(C::new(Init {
            engine,
            bridge,
            mc,
            me: Me(weak.clone()),
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

/// A window of the shell: its id and its own controllers.
pub struct Window {
    pub id: String,
    controllers: Vec<Entry>,
}

/// A controller under its registration name.
type Handler = (&'static str, Rc<RefCell<dyn Controller>>);

#[derive(Default)]
struct Host {
    shared: RefCell<Vec<Entry>>,
    windows: RefCell<Vec<Rc<Window>>>,
    /// Every controller, the window's and the shared, in name order.
    handlers: RefCell<Vec<Handler>>,
    mc: RefCell<Option<Rc<dyn Mc>>>,
}

/// Builds the controllers of `registrations` for the shell's one window.
/// Call it once, after `crate::register` and before the QML loads.
pub fn start(engine: &Engine, mc: Rc<dyn Mc>, mut registrations: Vec<Registration>) {
    let bridge = Bridge::of(engine);
    let host = engine.extension::<Host>();
    assert!(
        host.mc.borrow().is_none(),
        "the controllers are started once"
    );
    *host.mc.borrow_mut() = Some(mc.clone());
    registrations.sort_by_key(|r| r.name);
    for r in &registrations {
        for key in r.state_keys {
            bridge.declare_key(engine, key);
        }
    }
    let mut build = |r: &Registration| {
        let entry = bridge.hold(engine, || (r.create)(engine, bridge, mc.clone()));
        Entry {
            name: r.name,
            ..entry
        }
    };
    let shared: Vec<Entry> = registrations
        .iter()
        .filter(|r| r.scope == Scope::Shared)
        .map(&mut build)
        .collect();
    let own: Vec<Entry> = registrations
        .iter()
        .filter(|r| r.scope == Scope::Window)
        .map(&mut build)
        .collect();
    let mut handlers: Vec<_> = shared
        .iter()
        .chain(&own)
        .map(|e| (e.name, e.run.clone()))
        .collect();
    handlers.sort_by_key(|(name, _)| *name);
    *host.handlers.borrow_mut() = handlers;
    *host.shared.borrow_mut() = shared;
    host.windows.borrow_mut().push(Rc::new(Window {
        id: "main".into(),
        controllers: own,
    }));
    let handlers = Rc::downgrade(&host);
    bridge.add_interceptor(
        engine,
        Rc::new(move |engine: &Engine, action: &str, payload: &Json| {
            let Some(host) = handlers.upgrade() else {
                return false;
            };
            let handlers = host.handlers.borrow().clone();
            handlers.iter().any(|(_, c)| {
                Bridge::of(engine).hold(engine, || c.borrow_mut().handle(engine, action, payload))
            })
        }),
    );
}

/// The shell has what the controllers show: each activates, the shared ones
/// first, then meet each window.
pub fn activate(engine: &Engine) {
    let host = engine.extension::<Host>();
    let bridge = Bridge::of(engine);
    let shared: Vec<_> = host.shared.borrow().iter().map(|e| e.run.clone()).collect();
    for c in &shared {
        bridge.hold(engine, || c.borrow_mut().activate(engine));
    }
    let windows = host.windows.borrow().clone();
    for window in &windows {
        for e in &window.controllers {
            bridge.hold(engine, || e.run.borrow_mut().activate(engine));
        }
        for c in &shared {
            bridge.hold(engine, || c.borrow_mut().attach(engine, window));
        }
    }
}

/// What the cache has shows while the MC answers: each window's controllers
/// preview it.
pub fn preview(engine: &Engine) {
    let host = engine.extension::<Host>();
    let bridge = Bridge::of(engine);
    let windows = host.windows.borrow().clone();
    for window in &windows {
        for e in &window.controllers {
            bridge.hold(engine, || e.run.borrow_mut().preview(engine));
        }
    }
}

/// The controller of type `C`: the window's, else the shared one (a
/// controller reaching another, as `NativeShell::controller<T>()`).
pub fn controller<C: Controller>(engine: &Engine) -> Option<Rc<RefCell<C>>> {
    let host = engine.extension::<Host>();
    let windows = host.windows.borrow();
    let shared = host.shared.borrow();
    windows
        .iter()
        .flat_map(|w| w.controllers.iter())
        .chain(shared.iter())
        .find_map(|e| e.any.clone().downcast::<RefCell<C>>().ok())
}

/// The names of the controllers, in the order they are offered actions.
pub fn names(engine: &Engine) -> Vec<&'static str> {
    engine
        .extension::<Host>()
        .handlers
        .borrow()
        .iter()
        .map(|(n, _)| *n)
        .collect()
}

/// What the shell's controllers were started with.
pub fn mc(engine: &Engine) -> Option<Rc<dyn Mc>> {
    engine.extension::<Host>().mc.borrow().clone()
}

/// A timer for a controller: `f` every `interval_ms`, from now. Stops with
/// `owner`, or when [`stop_timer`] is given what this returns.
pub fn every(
    engine: &Engine,
    owner: Option<ObjectId>,
    interval_ms: i32,
    f: impl Fn(&Engine) + 'static,
) -> Option<ObjectId> {
    use ljos_engine::Timer;
    let mut native = Timer::default();
    native.interval = interval_ms;
    native.repeat = true;
    native.running = true;
    let timer = engine.create_native(native, owner).ok()?;
    engine
        .connect_by_name(timer, "triggered", move |engine, _| f(engine))
        .ok()?;
    // A Timer arms on completion, as in a component; one made here has none.
    engine.complete(timer).ok()?;
    Some(timer)
}

pub fn stop_timer(engine: &Engine, timer: ObjectId) {
    engine.destroy(timer);
}
