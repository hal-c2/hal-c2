//! `Threads`, desktop-qt's ThreadStore: follows each open thread through
//! the MC's `stream` shape into a [`TimelineModel`], the one the Timeline
//! brick binds (`Threads.timeline`).
//!
//! The route's thread is the active one. The last [`WARM_THREADS`] opened
//! before it stay followed, so going back to one is instant; one left
//! [`IDLE`] ago is closed, and so is one the MC no longer lists. A thread's
//! copy in the client cache shows first and says where its stream resumes;
//! a closed thread's copy is trimmed back, or forgotten when the thread is
//! gone for good.
//!
//! What other controllers read, at any time: [`active`], [`timeline`],
//! [`timeline_of`], [`upcoming`]; [`on_active_changed`] and
//! [`on_times_changed`] run once the store is done.
//!
//! The cache answers `load_thread` on its own thread: [`set_wake`] hands it
//! the event loop's wake, and the loop then calls [`deliver`].

use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::Rc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use ljos::prelude::{
    Atom, Cx, Engine, ObjectId, QmlObject, Time, TimerId, Value, qml_impl, qml_singleton,
};
use serde_json::json;

use crate::bridge::Bridge;
use crate::cache;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::navigation::{self, Route};
use crate::controllers::settings::Settings;
use crate::json::Json;
use crate::mc::{Frame, Mc, McError, Phase, SubId};
use crate::store;
use crate::thread_view::cache::ThreadCache;
use crate::thread_view::time::{self, Clock};
use crate::thread_view::timeline::{Out, Timeline};
use crate::thread_view::timeline_model::TimelineModel;

/// The threads kept followed besides the active one.
pub const WARM_THREADS: usize = 3;
/// How long a thread left stays followed.
pub const IDLE: Duration = Duration::from_secs(300);
/// A signed attachment address is let go this long before the MC says it
/// expires, so an image asked for at the last moment still loads.
const URL_MARGIN_MS: i64 = 60_000;

/// "environmentId:threadId" → the environment's id.
fn environment_of(key: &str) -> &str {
    key.split_once(':')
        .map_or("", |(environment, _)| environment)
}

/// An open thread.
struct Followed {
    model: ObjectId,
    subscription: Option<SubId>,
    /// Ended by the MC while its machine was offline: followed again once
    /// it is online.
    wait_online: bool,
    /// Its copy is loading from the cache.
    restoring: bool,
    /// Listed by the store once: closed when it no longer is.
    listed: bool,
}

type Listener = Rc<dyn Fn(&Engine)>;

/// What is read without the controller: the active thread and the times,
/// and the cache's answers waiting for [`deliver`].
#[derive(Default)]
struct Shared {
    active: RefCell<String>,
    timeline: Cell<Option<ObjectId>>,
    clock: RefCell<Clock>,
    timestamp_format: RefCell<String>,
    active_changed: RefCell<Vec<Listener>>,
    times_changed: RefCell<Vec<Listener>>,
    /// (key, model, copy): `load_thread` answers, in order.
    loaded: Rc<RefCell<Vec<(String, ObjectId, cache::Thread)>>>,
}

fn shared(engine: &Engine) -> Rc<Shared> {
    Bridge::of(engine).extension::<Shared>(engine)
}

/// The thread shown: "environmentId:threadId", or empty.
pub fn active(engine: &Engine) -> String {
    shared(engine).active.borrow().clone()
}

/// The shown thread's timeline (`Threads.timeline`).
pub fn timeline(engine: &Engine) -> Option<ObjectId> {
    shared(engine).timeline.get()
}

/// The timeline of an open thread; none for one not open, or while the
/// store is running.
pub fn timeline_of(engine: &Engine, key: &str) -> Option<ObjectId> {
    controller::with::<ThreadStore, _>(engine, |s, _| s.timeline(key)).flatten()
}

/// A time that may be ahead, as the timelines show one (a usage limit's
/// reset).
pub fn upcoming(engine: &Engine, at: Option<DateTime<Utc>>) -> String {
    let shared = shared(engine);
    let format = shared.timestamp_format.borrow();
    let format = if format.is_empty() { "locale" } else { &format };
    time::upcoming_stamp(at, &shared.clock.borrow(), format)
}

/// Runs `f` when another thread is shown (or none), after the store is done.
pub fn on_active_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    shared(engine).active_changed.borrow_mut().push(Rc::new(f));
}

/// Runs `f` when the times read differently (the device's timestampFormat).
pub fn on_times_changed(engine: &Engine, f: impl Fn(&Engine) + 'static) {
    shared(engine).times_changed.borrow_mut().push(Rc::new(f));
}

fn tell(engine: &Engine, listeners: Vec<Listener>) {
    for f in listeners {
        Bridge::of(engine).defer(engine, move |engine| f(engine));
    }
}

/// Hands the cache the event loop's wake, called (on any thread) when a
/// thread's copy has loaded; the loop then calls [`deliver`]. A shell that
/// has no MC yet has no cache either: the wake is given to the one it makes
/// when it is opened at one.
pub fn set_wake(engine: &Engine, wake: impl Fn() + Send + Sync + 'static) {
    store::when_installed(engine, move |engine| {
        if let Some(cache) = store::cache(engine) {
            cache.set_wake(wake);
        }
    });
}

/// Shows the copies the cache has loaded, and follows their threads.
pub fn deliver(engine: &Engine) {
    if let Some(cache) = store::cache(engine) {
        cache.deliver();
    }
    // Each window's, to its own store.
    controller::each_window(engine, |engine| {
        let loaded = std::mem::take(&mut *shared(engine).loaded.borrow_mut());
        for (key, model, thread) in loaded {
            controller::with::<ThreadStore, _>(engine, |s, e| s.restored(e, &key, model, &thread));
        }
    });
}

/// Whether the active thread is still waiting for its first rows: a
/// render waits for them.
pub fn loading(engine: &Engine) -> bool {
    timeline(engine)
        .and_then(|model| TimelineModel::read(engine, model, |t| t.status() == "loading"))
        .unwrap_or(false)
}

/// Waits for the cache to answer what it was asked, then [`deliver`]s:
/// tests and a render, which have no event loop to wake.
pub fn drain(engine: &Engine) {
    if let Some(cache) = store::cache(engine) {
        cache.drain();
    }
    deliver(engine);
}

/// The connection's trouble, as a thread that cannot load says it.
fn connection_problem(phase: Phase) -> &'static str {
    match phase {
        Phase::Refused => "This device is no longer paired with its environment.",
        Phase::Blocked => "Its environment speaks another version of HAL-C2.",
        Phase::Offline => "This device is offline.",
        Phase::Retrying => "The connection to its environment dropped.",
        Phase::Closed | Phase::Connecting | Phase::Ready => "",
    }
}

pub struct ThreadStore {
    mc: Rc<dyn Mc>,
    me: Me<ThreadStore>,
    threads: BTreeMap<String, Followed>,
    /// Most recently opened first.
    recent: Vec<String>,
    /// When each thread was left.
    left_at: BTreeMap<String, Time>,
    idle_timer: Option<TimerId>,
    phase: Phase,
    hooked: bool,
}

impl Controller for ThreadStore {
    fn new(init: Init<'_, Self>) -> Self {
        let engine = init.engine;
        let me = init.me;
        // Each hook runs once the store is free.
        let hook = |f: fn(&mut ThreadStore, &Engine)| {
            let me = me.clone();
            move |engine: &Engine| {
                let me = me.clone();
                Bridge::of(engine).defer(engine, move |engine| me.run(engine, f));
            }
        };
        store::on_changed(engine, hook(ThreadStore::retry));
        // Threads shown from what was kept of another MC go with its thread
        // list; their copies stay in the cache for when the client is
        // opened there again.
        store::on_origin_changed(engine, hook(ThreadStore::close_all));
        let ready = hook(ThreadStore::retry);
        let dropped = hook(ThreadStore::dropped);
        init.mc.on_ready_changed(Box::new(move |engine, is_ready| {
            if is_ready {
                ready(engine)
            } else {
                dropped(engine)
            }
        }));
        let status = hook(ThreadStore::status_changed);
        init.mc.on_status(Box::new(move |engine, _| status(engine)));
        *shared(engine).timestamp_format.borrow_mut() = "locale".into();
        ThreadStore {
            phase: init.mc.status().phase,
            mc: init.mc,
            me,
            threads: BTreeMap::new(),
            recent: Vec::new(),
            left_at: BTreeMap::new(),
            idle_timer: None,
            hooked: false,
        }
    }

    fn preview(&mut self, engine: &Engine) {
        if let Route::Thread(key) = navigation::shown(engine)
            && store::with(engine, |s| s.thread(&key).is_some())
        {
            self.open(engine, &key);
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if !self.hooked {
            self.hooked = true;
            // The open thread is the route's.
            let me = self.me.clone();
            Bridge::of(engine).watch(engine, "route", move |engine, _| {
                let me = me.clone();
                Bridge::of(engine).defer(engine, move |engine| {
                    me.run(engine, |s, e| s.open(e, &route_key(e)));
                });
            });
            let me = self.me.clone();
            Settings::of(engine).on_device_changed(move |engine| {
                let me = me.clone();
                Bridge::of(engine).defer(engine, move |engine| me.run(engine, Self::read_settings));
            });
        }
        self.read_settings(engine);
        self.open(engine, &route_key(engine));
        self.retry(engine);
    }
}

fn route_key(engine: &Engine) -> String {
    match navigation::shown(engine) {
        Route::Thread(key) => key,
        _ => String::new(),
    }
}

impl ThreadStore {
    pub fn timeline(&self, key: &str) -> Option<ObjectId> {
        self.threads.get(key).map(|f| f.model)
    }

    /// The threads followed, the active one included.
    pub fn open_threads(&self) -> Vec<String> {
        self.threads.keys().cloned().collect()
    }

    /// What "now" is for the timelines and idle threads' times (tests).
    pub fn set_clock(&mut self, engine: &Engine, clock: Clock) {
        *shared(engine).clock.borrow_mut() = clock.clone();
        for followed in self.threads.values() {
            let clock = clock.clone();
            TimelineModel::update(engine, followed.model, |t| t.set_clock(clock));
        }
        self.evict_idle(engine);
    }

    fn read_settings(&mut self, engine: &Engine) {
        let format = Settings::of(engine)
            .device_value("timestampFormat")
            .and_then(|v| v.as_str().map(str::to_owned))
            .filter(|f| !f.is_empty())
            .unwrap_or_else(|| "locale".into());
        *shared(engine).timestamp_format.borrow_mut() = format;
        for followed in self.threads.values() {
            configure(engine, followed.model);
        }
        let listeners = shared(engine).times_changed.borrow().clone();
        tell(engine, listeners);
    }

    /// Shows `key` (none when empty): followed from its cached copy, or
    /// from the MC. The thread left stays followed for a while.
    pub fn open(&mut self, engine: &Engine, key: &str) {
        let shared = shared(engine);
        if *shared.active.borrow() == key {
            return;
        }
        let left = shared.active.borrow().clone();
        if !left.is_empty() && self.threads.contains_key(&left) {
            self.left_at.insert(left, engine.now());
        }
        // One left too long ago is loaded again, the one being opened
        // included.
        shared.active.borrow_mut().clear();
        self.evict_idle(engine);
        key.clone_into(&mut shared.active.borrow_mut());
        self.left_at.remove(key);
        if !key.is_empty() {
            self.recent.retain(|k| k != key);
            self.recent.insert(0, key.to_owned());
            if !self.threads.contains_key(key) {
                self.start(engine, key);
            }
            self.evict(engine);
        }
        self.show_active(engine);
    }

    /// A model for `key`, its copy loading or its stream followed.
    fn start(&mut self, engine: &Engine, key: &str) {
        let mut timeline = Timeline::new(key);
        timeline.set_clock(shared(engine).clock.borrow().clone());
        let kept = store::cache(engine);
        timeline.set_cache(kept.clone().map(|c| c as Rc<dyn ThreadCache>));
        let owner = Bridge::of(engine).singleton::<ThreadsObject>(engine).ok();
        let model = match TimelineModel::create(engine, owner, timeline) {
            Ok(model) => model,
            Err(e) => {
                engine.log(ljos::prelude::LogLevel::Warning, "Threads", e.to_string());
                return;
            }
        };
        configure(engine, model);
        let mc = self.mc.clone();
        let me = self.me.clone();
        let observed = key.to_owned();
        TimelineModel::observe(engine, model, move |engine, out| match out {
            Out::AttachmentWanted(id) => sign_attachment(&mc, model, &observed, id),
            Out::EarlierWanted(items) => {
                let (me, key, items) = (me.clone(), observed.clone(), *items);
                Bridge::of(engine).defer(engine, move |engine| {
                    me.run(engine, |s, _| s.more(&key, items));
                });
            }
            _ => {}
        });
        // Listed now, not once its copy is in: one the MC deletes while the
        // copy loads is closed when the reconnect says so (forget_removed).
        let listed = store::with(engine, |s| s.thread(key).is_some());
        let restoring = kept.as_ref().is_some_and(|c| c.is_open());
        self.threads.insert(
            key.to_owned(),
            Followed {
                model,
                subscription: None,
                wait_online: false,
                restoring,
                listed,
            },
        );
        match kept {
            // What the cache kept shows first, and says where the stream
            // resumes.
            Some(kept) if restoring => {
                let loaded = shared(engine).loaded.clone();
                let key = key.to_owned();
                kept.load_thread(&key.clone(), move |thread| {
                    loaded.borrow_mut().push((key, model, thread));
                });
            }
            _ => self.follow(engine, key),
        }
    }

    /// The cache's copy of `key` is in.
    fn restored(&mut self, engine: &Engine, key: &str, model: ObjectId, thread: &cache::Thread) {
        let Some(followed) = self.threads.get_mut(key) else {
            return;
        };
        if followed.model != model {
            return;
        }
        followed.restoring = false;
        TimelineModel::update(engine, model, |t| t.restore(thread));
        self.show_connection(engine);
        self.follow(engine, key);
    }

    fn more(&self, key: &str, items: i64) {
        if let Some(subscription) = self.threads.get(key).and_then(|f| f.subscription) {
            self.mc.more(
                subscription,
                u32::try_from(items.max(0)).unwrap_or(u32::MAX),
            );
        }
    }

    /// Stops following `key`; its copy is trimmed back, or forgotten when
    /// the thread is gone.
    pub fn close(&mut self, engine: &Engine, key: &str) {
        let Some(mut followed) = self.threads.remove(key) else {
            return;
        };
        self.unfollow(&mut followed);
        self.recent.retain(|k| k != key);
        self.left_at.remove(key);
        let shared = shared(engine);
        if *shared.active.borrow() == key {
            shared.active.borrow_mut().clear();
            self.show_active(engine);
        }
        let gone = store::with(engine, |s| s.synchronized() && s.thread(key).is_none());
        if gone {
            // Deleted, moved to another machine, or its environment
            // removed: there is nothing to come back to.
            TimelineModel::update(engine, followed.model, |t| t.set_cache(None));
            if let Some(kept) = store::cache(engine) {
                kept.forget_thread(key);
            }
        } else {
            TimelineModel::update(engine, followed.model, Timeline::park);
        }
        engine.destroy(followed.model);
    }

    fn close_all(&mut self, engine: &Engine) {
        for key in self.open_threads() {
            self.close(engine, &key);
        }
    }

    /// Follows `key` again from where its timeline stands.
    pub fn reload(&mut self, engine: &Engine, key: &str) {
        let Some(followed) = self.threads.get_mut(key) else {
            return;
        };
        let model = followed.model;
        Self::unfollow_with(&self.mc, followed);
        followed.wait_online = false;
        TimelineModel::update(engine, model, |t| t.set_status("loading", ""));
        self.follow(engine, key);
        self.show_connection(engine);
    }

    /// Sets the `Threads` object's properties and tells who listens.
    fn show_active(&self, engine: &Engine) {
        let shared = shared(engine);
        let key = shared.active.borrow().clone();
        let model = self.threads.get(&key).map(|f| f.model);
        shared.timeline.set(model);
        if let Ok(obj) = Bridge::of(engine).singleton::<ThreadsObject>(engine) {
            let result = engine
                .set_internal(obj, ThreadsObject::ACTIVE_THREAD, Atom::from(key.as_str()))
                .and_then(|()| {
                    engine.set_internal(
                        obj,
                        ThreadsObject::TIMELINE,
                        model.map_or(Value::Null, Value::Object),
                    )
                });
            if let Err(e) = result {
                engine.log(ljos::prelude::LogLevel::Warning, "Threads", e.to_string());
            }
        }
        let listeners = shared.active_changed.borrow().clone();
        tell(engine, listeners);
    }

    fn evict(&mut self, engine: &Engine) {
        while self.recent.len() > WARM_THREADS + 1 {
            let Some(last) = self.recent.last().cloned() else {
                break;
            };
            self.close(engine, &last);
        }
    }

    /// Closes the threads the store no longer lists, on the MC's word only:
    /// rows from the cache may be behind. One the store lists counts as
    /// listed from now on, its copy still loading or not.
    fn forget_removed(&mut self, engine: &Engine) {
        if !store::with(engine, |s| s.synchronized()) {
            return;
        }
        for (key, followed) in &mut self.threads {
            followed.listed |= store::with(engine, |s| s.thread(key).is_some());
        }
        let removed: Vec<String> = self
            .threads
            .iter()
            .filter(|(key, f)| f.listed && store::with(engine, |s| s.thread(key).is_none()))
            .map(|(key, _)| key.clone())
            .collect();
        for key in removed {
            self.close(engine, &key);
        }
    }

    /// Closes the threads left [`IDLE`] ago, and wakes for the next.
    fn evict_idle(&mut self, engine: &Engine) {
        let now = engine.now();
        let mut next: Option<Duration> = None;
        let left: Vec<(String, Time)> = self
            .left_at
            .iter()
            .map(|(k, at)| (k.clone(), *at))
            .collect();
        for (key, at) in left {
            let since = now - at;
            if since >= IDLE {
                self.close(engine, &key);
            } else {
                let rest = IDLE - since;
                next = Some(next.map_or(rest, |n| n.min(rest)));
            }
        }
        if let Some(timer) = self.idle_timer.take() {
            engine.cancel_call(timer);
        }
        if let Some(next) = next {
            let me = self.me.clone();
            self.idle_timer = Some(engine.call_at(now + next, move |engine| {
                me.run(engine, |s, e| {
                    s.idle_timer = None;
                    s.evict_idle(e);
                });
            }));
        }
    }

    fn follow(&mut self, engine: &Engine, key: &str) {
        let Some(followed) = self.threads.get_mut(key) else {
            return;
        };
        if followed.subscription.is_some() || followed.restoring {
            return;
        }
        // Not in the sidebar yet: a change of the store retries.
        let (listed, synchronized) =
            store::with(engine, |s| (s.thread(key).is_some(), s.synchronized()));
        if !listed {
            return;
        }
        followed.listed = true;
        // Listed by what the client kept, and shown from it: the MC is
        // asked for the thread once its own list says it is still there
        // (retry).
        if !synchronized {
            return;
        }
        followed.wait_online = false;
        let (environment, thread) = key.split_once(':').unwrap_or((key, ""));
        let shape = json!({
            "type": "stream",
            "environment": environment,
            "stream": thread,
            "kinds": Timeline::stream_kinds(),
        });
        let me = self.me.clone();
        let framed = key.to_owned();
        let model = followed.model;
        // The model says where each `sub` frame resumes from: the first,
        // and the ones after a reconnect or `resync`.
        let mut resume = TimelineModel::resumer(engine, model);
        let subscription = self.mc.subscribe(
            shape,
            Box::new(move |engine, frame| {
                me.run(engine, |s, e| s.on_frame(e, &framed, frame));
            }),
            Some(Box::new(move || match resume() {
                Json::Object(resume) => resume,
                _ => Frame::new(),
            })),
        );
        if let Some(followed) = self.threads.get_mut(key) {
            followed.subscription = Some(subscription);
        }
    }

    fn unfollow(&self, followed: &mut Followed) {
        Self::unfollow_with(&self.mc, followed);
    }

    fn unfollow_with(mc: &Rc<dyn Mc>, followed: &mut Followed) {
        if let Some(subscription) = followed.subscription.take() {
            mc.unsubscribe(subscription);
        }
    }

    fn on_frame(&mut self, engine: &Engine, key: &str, frame: &Frame) {
        let Some(followed) = self.threads.get_mut(key) else {
            return;
        };
        let model = followed.model;
        let kind = frame.get("t").and_then(Json::as_str).unwrap_or_default();
        if kind != "error" && kind != "end" {
            TimelineModel::update(engine, model, |t| t.receive(frame));
            return;
        }
        // The MC ends a refused subscription itself; forget it and retry
        // when the MC (or the connection) comes back.
        Self::unfollow_with(&self.mc, followed);
        followed.wait_online = !store::with(engine, |s| s.thread_online(key));
        let reason = frame
            .get("reason")
            .and_then(Json::as_str)
            .filter(|r| !r.is_empty())
            .unwrap_or("The MC stopped sending this thread.")
            .to_owned();
        TimelineModel::update(engine, model, |t| t.set_status("unreachable", &reason));
    }

    /// Follows the open threads that are not: ones the sidebar did not
    /// list yet, and unreachable ones whose MC is online again or whose
    /// connection is back.
    fn retry(&mut self, engine: &Engine) {
        self.forget_removed(engine);
        if !self.mc.is_ready() {
            return;
        }
        let waiting: Vec<String> = self
            .threads
            .iter()
            .filter(|(key, f)| {
                f.subscription.is_none()
                    && !(f.wait_online && !store::with(engine, |s| s.thread_online(key)))
            })
            .map(|(key, _)| key.clone())
            .collect();
        for key in waiting {
            self.follow(engine, &key);
        }
    }

    /// The connection dropped: what was loaded stays, without passing for
    /// live; the resubscription that follows the reconnect says `live`
    /// again.
    fn dropped(&mut self, engine: &Engine) {
        for followed in self.threads.values() {
            if followed.subscription.is_some() {
                TimelineModel::update(engine, followed.model, |t| {
                    t.set_status("unreachable", "The connection to its environment dropped.");
                });
            }
        }
    }

    fn status_changed(&mut self, engine: &Engine) {
        let phase = self.mc.status().phase;
        if phase != self.phase {
            self.phase = phase;
            self.show_connection(engine);
        }
    }

    /// A thread with rows that is not live says why the connection cannot
    /// load it; one with nothing to show keeps saying it is loading.
    fn show_connection(&self, engine: &Engine) {
        let problem = connection_problem(self.mc.status().phase);
        if problem.is_empty() {
            return;
        }
        for followed in self.threads.values() {
            TimelineModel::update(engine, followed.model, |t| {
                if t.status() != "live" && t.row_count() > 0 {
                    t.set_status("unreachable", problem);
                }
            });
        }
    }
}

impl Drop for ThreadStore {
    fn drop(&mut self) {
        for followed in self.threads.values_mut() {
            Self::unfollow_with(&self.mc, followed);
        }
    }
}

/// The device's time format, and where the thread works and its
/// environment's other threads are named, read from the store when asked.
fn configure(engine: &Engine, model: ObjectId) {
    let format = shared(engine).timestamp_format.borrow().clone();
    let held = store::get(engine).map(|s| Rc::downgrade(&s));
    let key = TimelineModel::read(engine, model, |t| t.thread_key().to_owned()).unwrap_or_default();
    let environment = environment_of(&key).to_owned();
    TimelineModel::update(engine, model, |t| {
        t.set_timestamp_format(&format);
        let Some(held) = held else { return };
        // Where it works: its worktree, else its project's root
        // (WorkspaceController::Place::cwd).
        let rows = held.clone();
        let thread = key.clone();
        t.set_workspace_root(Some(Rc::new(move || {
            let Some(store) = rows.upgrade() else {
                return String::new();
            };
            let Ok(store) = store.try_borrow() else {
                return String::new();
            };
            let Some(row) = store.thread_row(&thread) else {
                return String::new();
            };
            let text = |row: &crate::store::Row, field: &str| {
                row.get(field)
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_owned()
            };
            let worktree = text(row, "worktreePath");
            if !worktree.is_empty() {
                return worktree;
            }
            let project = text(row, "projectId");
            store
                .project_row(environment_of(&thread), &project)
                .map(|p| text(p, "workspaceRoot"))
                .unwrap_or_default()
        })));
        // The other threads of its environment, by the titles the shell
        // lists.
        t.set_thread_titles(Some(Rc::new(move |id: &str| {
            let Some(store) = held.upgrade() else {
                return String::new();
            };
            let Ok(store) = store.try_borrow() else {
                return String::new();
            };
            store
                .thread_row(&format!("{environment}:{id}"))
                .and_then(|row| row.get("title"))
                .and_then(Json::as_str)
                .unwrap_or_default()
                .to_owned()
        })));
    });
}

/// Asks the MC for an address for attachment `id` of the thread at `key`.
fn sign_attachment(mc: &Rc<dyn Mc>, model: ObjectId, key: &str, id: &str) {
    let resource = json!({"_tag": "attachment", "attachmentId": id, "disposition": "inline"});
    let origin = mc.origin();
    let id = id.to_owned();
    mc.call(
        environment_of(key),
        "assets.createUrl",
        json!({"resource": resource}),
        Box::new(move |engine, result: Result<Json, McError>| {
            let signed = result.ok().and_then(|result| {
                let relative = result.get("relativeUrl")?.as_str()?.to_owned();
                if relative.is_empty() {
                    return None;
                }
                // The cluster hands the address to the member that signed
                // it.
                let url = origin
                    .as_deref()
                    .and_then(|o| url::Url::parse(o).ok())
                    .and_then(|o| o.join(&relative).ok())
                    .map_or(relative, |u| u.to_string());
                let expires_at = result
                    .get("expiresAt")
                    .and_then(Json::as_f64)
                    .unwrap_or(0.0);
                let expires = DateTime::from_timestamp_millis(expires_at as i64 - URL_MARGIN_MS);
                Some((url, expires))
            });
            TimelineModel::update(engine, model, |t| match signed {
                Some((url, expires)) => t.set_attachment_url(&id, &url, expires),
                None => t.set_attachment_url(&id, "", None),
            });
        }),
    );
}

/// `Threads` in QML: the thread shown and its timeline.
///
/// ```qml
/// Timeline { model: Threads.timeline }
/// onClicked: Threads.reload(Threads.activeThread)
/// ```
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "Threads", uncreatable)]
#[qml_singleton]
pub struct ThreadsObject {
    /// "environmentId:threadId", or "".
    #[qml(notify, readonly)]
    active_thread: Atom,
    /// Its TimelineModel, or null.
    #[qml(notify, readonly)]
    timeline: Value,
}

impl Default for ThreadsObject {
    fn default() -> Self {
        ThreadsObject {
            active_thread: Atom::new(""),
            timeline: Value::Null,
        }
    }
}

/// Runs `f` on the store once it is free.
fn later(engine: &Engine, f: impl FnOnce(&mut ThreadStore, &Engine) + 'static) {
    Bridge::of(engine).defer(engine, move |engine| {
        controller::with::<ThreadStore, _>(engine, f);
    });
}

#[qml_impl]
impl ThreadsObject {
    #[qml(invokable)]
    fn open(cx: &Cx, thread_key: Atom) {
        let key = thread_key.to_string();
        later(cx.engine, move |s, e| s.open(e, &key));
    }

    #[qml(invokable)]
    fn close(cx: &Cx, thread_key: Atom) {
        let key = thread_key.to_string();
        later(cx.engine, move |s, e| s.close(e, &key));
    }

    /// Follows the thread again: its Retry.
    #[qml(invokable)]
    fn reload(cx: &Cx, thread_key: Atom) {
        let key = thread_key.to_string();
        later(cx.engine, move |s, e| s.reload(e, &key));
    }
}
