//! What the shell's own threads hand the UI thread: one bounded side stream
//! each (Ljós's `UiBatch`, ARCHITECTURE.md §3.3), with a capacity, a name the
//! Observer lists it by, and a handler that takes a frame's run of it in one
//! turn.
//!
//! [`wire`] makes them all, on whatever runs the frames ([`Wire`]): the
//! window's [`ljos::Setup`], or a [`Pump`] where no window does (`--render`,
//! the tests). Each stream says what gives way when it is full:
//!
//! - **coalesced** ([`Tick`], the device's screens): state the thread keeps
//!   itself and the UI only has to look at, so a newer notice replaces the
//!   queued one;
//! - **waiting** ([`Feed`]): items that all matter, in order (the MC's
//!   frames, a child process's output, file changes). A full stream holds
//!   its sender until the UI has taken some, so nothing is dropped and
//!   nothing grows past the capacity: the sender's own source (a socket, a
//!   pipe, the kernel's watch queue) waits instead.

use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use ljos::prelude::Engine;
use ljos::{BatchPolicy, BatchSender, CoalesceKey, Drain, DrainBudget};

use crate::controllers::{desktop_update, plugin, settings, snap_shot, threads};
use crate::mc::McStreams;
use crate::{clock, device, folders, local_transcriber, theme};

/// The streams [`wire`] made whose senders are given later than the wiring:
/// the MC's, for each connection; the local cache's, once the shell has
/// started; the snapshot system's, when it is made; the clock watcher's,
/// where a window starts one.
pub struct Wired {
    pub mc: Rc<McStreams>,
    /// For [`threads::set_wake`], after [`crate::start`].
    pub local_cache: Tick,
    /// For [`crate::snap_shot::system`].
    pub snap_shot: Tick,
    /// For [`clock::set_wake`], which starts a thread that watches the
    /// system's clock: only a window does, not a picture or a test.
    pub clock: Tick,
}

/// Every side stream the shell's threads feed, on `wire`, drained each
/// frame in this order: the MC's first, as its news is what most of the
/// others act on.
///
/// DECISION: the subsystems that keep their news as state (a flag, the
/// newest file, an answer to a request the UI made) are woken by a
/// [`Tick`] each, so a flood of notices is one look; those whose every item
/// matters have a [`Feed`] or a stream of their own (see each `wire`).
pub fn wire(engine: &Engine, wire: &mut impl Wire) -> Wired {
    let mc = McStreams::new(wire);
    folders::wire(engine, wire);
    device::wire(engine, wire);
    plugin::wire(engine, wire);
    local_transcriber::wire(engine, wire);
    let theme = Tick::new(wire, "theme", theme::deliver);
    theme::set_wake(engine, theme.waker());
    let settings = Tick::new(wire, "settings", settings::deliver);
    settings::set_wake(engine, settings.waker());
    let update = Tick::new(wire, "desktop-update", desktop_update::deliver);
    desktop_update::set_wake(engine, update.waker());
    Wired {
        mc,
        local_cache: Tick::new(wire, "local-cache", threads::deliver),
        snap_shot: Tick::new(wire, "snap-shot", snap_shot::deliver),
        // The wall clock jumping or the machine waking: one look however
        // many jumps came, as the listeners work their moments out again.
        clock: Tick::new(wire, "clock", clock::deliver),
    }
}

/// Whatever runs the frames that drain the streams.
pub trait Wire {
    /// A stream of `capacity` items named `name`, whose runs go to
    /// `handler`, one turn each; the sender is for the threads that feed it.
    fn stream<T: Send + 'static>(
        &mut self,
        name: &'static str,
        capacity: usize,
        policy: BatchPolicy<T>,
        handler: impl FnMut(&Engine, Drain<'_, T>) + 'static,
    ) -> BatchSender<T>;
}

impl<M: Send + 'static> Wire for ljos::Setup<'_, M> {
    fn stream<T: Send + 'static>(
        &mut self,
        name: &'static str,
        capacity: usize,
        policy: BatchPolicy<T>,
        handler: impl FnMut(&Engine, Drain<'_, T>) + 'static,
    ) -> BatchSender<T> {
        let sender = self.batch(name, capacity, policy);
        self.on_batch(&sender, handler);
        sender
    }
}

/// A coalesced notice that a subsystem has something for the UI: however
/// many times it is given before the UI looks, the UI looks once.
#[derive(Clone)]
pub struct Tick(BatchSender<()>);

impl Tick {
    pub fn new(
        wire: &mut impl Wire,
        name: &'static str,
        mut look: impl FnMut(&Engine) + 'static,
    ) -> Tick {
        Tick(wire.stream(
            name,
            1,
            BatchPolicy::Coalesce(|_| CoalesceKey(0)),
            move |engine, _notices| look(engine),
        ))
    }

    /// Never waits: a notice already queued stands for this one.
    pub fn give(&self) {
        let _ = self.0.send(());
    }

    /// [`Tick::give`] as the `wake` the subsystems take.
    pub fn waker(&self) -> impl Fn() + Send + Sync + 'static {
        let tick = self.clone();
        move || tick.give()
    }
}

/// How many items a [`Feed`]'s stream holds, counted by its senders and
/// its handler, so a sender waits for room instead of being refused.
struct Room {
    queued: Mutex<usize>,
    freed: Condvar,
    capacity: usize,
    /// The handler is gone (the window closed): nobody makes room again.
    closed: AtomicBool,
}

impl Room {
    fn made(&self, taken: usize) {
        let mut queued = self.queued.lock().unwrap_or_else(|e| e.into_inner());
        *queued = queued.saturating_sub(taken);
        self.freed.notify_all();
    }
}

/// Closes the room when the handler that holds it is dropped.
struct Closer(Arc<Room>);

impl Drop for Closer {
    fn drop(&mut self) {
        self.0.closed.store(true, Ordering::Release);
        self.0.freed.notify_all();
    }
}

/// The sending side of a stream whose every item matters: [`Feed::send`]
/// waits while the stream is full, so the stream never refuses one and the
/// Observer's `depth` never passes its capacity.
pub struct Feed<T> {
    sender: BatchSender<T>,
    room: Arc<Room>,
}

impl<T> Clone for Feed<T> {
    fn clone(&self) -> Self {
        Feed {
            sender: self.sender.clone(),
            room: self.room.clone(),
        }
    }
}

/// How long a waiting sender sleeps before it looks whether the UI is gone.
const RECHECK: Duration = Duration::from_millis(100);

impl<T: Send + 'static> Feed<T> {
    pub fn new(
        wire: &mut impl Wire,
        name: &'static str,
        capacity: usize,
        mut handler: impl FnMut(&Engine, Drain<'_, T>) + 'static,
    ) -> Feed<T> {
        let room = Arc::new(Room {
            queued: Mutex::new(0),
            freed: Condvar::new(),
            capacity,
            closed: AtomicBool::new(false),
        });
        let closer = Closer(room.clone());
        let sender = wire.stream(
            name,
            capacity,
            BatchPolicy::DropNewest,
            move |engine, run| {
                // Room before the handler runs: what it does may send again.
                closer.0.made(run.len());
                handler(engine, run);
            },
        );
        Feed { sender, room }
    }

    /// Queues `item` in order, waiting for room while the stream is full.
    /// Hands it back once the UI is gone. Never call it on the UI thread.
    pub fn send(&self, item: T) -> Result<(), T> {
        let room = &*self.room;
        {
            let mut queued = room.queued.lock().unwrap_or_else(|e| e.into_inner());
            while *queued >= room.capacity {
                if room.closed.load(Ordering::Acquire) || self.sender.is_closed() {
                    return Err(item);
                }
                queued = room
                    .freed
                    .wait_timeout(queued, RECHECK)
                    .unwrap_or_else(|e| e.into_inner())
                    .0;
            }
            *queued += 1;
        }
        self.sender.send(item).map_err(|e| {
            // Gone, not full: the room said there was a slot.
            room.made(1);
            e.into_inner()
        })
    }

    pub fn name(&self) -> &'static str {
        self.sender.name()
    }
}

/// One stream's frame under a [`Pump`]: how many items it handled.
type PumpDrain = Box<dyn FnMut(&Engine, DrainBudget) -> usize>;

/// The streams' frames where no window runs them: an inbox of its own whose
/// wake is the caller's, and each stream drained in the order it was made,
/// in a turn of its own, as the window's frames do.
pub struct Pump {
    // Kept for its wake: a stream's sender wakes through its inbox.
    _inbox: ljos_runtime::UiInbox<()>,
    handle: ljos_runtime::UiHandle<()>,
    drains: Vec<PumpDrain>,
    /// What one [`Pump::pump`] takes of each stream at most, as a frame's
    /// budget does.
    pub budget: DrainBudget,
}

impl Pump {
    /// `wake` runs on a sender's thread whenever a stream that was empty
    /// gets an item, or a pump left items behind.
    pub fn new(wake: impl Fn() + Send + Sync + 'static) -> Pump {
        let (inbox, handle) = ljos_runtime::UiInbox::channel_with_wake(1, Arc::new(wake));
        Pump {
            _inbox: inbox,
            handle,
            drains: Vec::new(),
            budget: DrainBudget::UNLIMITED,
        }
    }

    /// One frame's worth of every stream; the number of items handled.
    pub fn pump(&mut self, engine: &Engine) -> usize {
        let budget = self.budget;
        self.drains
            .iter_mut()
            .map(|drain| drain(engine, budget))
            .sum()
    }
}

impl Wire for Pump {
    fn stream<T: Send + 'static>(
        &mut self,
        name: &'static str,
        capacity: usize,
        policy: BatchPolicy<T>,
        mut handler: impl FnMut(&Engine, Drain<'_, T>) + 'static,
    ) -> BatchSender<T> {
        let (mut batch, sender) = self.handle.batch(name, capacity, policy);
        let clock = ljos_runtime::SystemClock::new();
        self.drains.push(Box::new(move |engine, budget| {
            if !batch.has_pending() {
                return 0;
            }
            batch
                .drain(budget, &clock, |run| {
                    engine.turn(None, || handler(engine, run));
                })
                .drained
        }));
        sender
    }
}
