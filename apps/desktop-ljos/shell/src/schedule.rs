//! Native work at a time: once after a delay or at a moment, or every
//! period, on [`Engine::call_at`]. Nothing here polls: an armed schedule
//! is one engine deadline, so an app whose schedules are all cancelled
//! sleeps until input or a message arrives.
//!
//! A schedule is cancelled with [`Schedule::cancel`], or goes when its
//! owner is destroyed. Dropping the handle does not cancel it, so a
//! one-shot nobody needs to call off can be started and forgotten. The
//! handle is not tied to the engine by `Drop` because the facade gives no
//! weak engine to cancel with.
//!
//! Each schedule has a name, and the engine counts the fires per name
//! ([`fired`]) and lists what is armed ([`pending`]): how an idle app is
//! seen to wake zero times, and what woke it when it did.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap};
use std::rc::{Rc, Weak};
use std::time::Duration;

use ljos::prelude::{Engine, ObjectId, Time, TimerId};

/// A handle on a schedule. Clones are the same schedule.
#[derive(Clone)]
pub struct Schedule(Rc<Slot>);

type Fire = Rc<RefCell<dyn FnMut(&Engine)>>;

struct Slot {
    name: &'static str,
    owner: Option<ObjectId>,
    /// A repeating schedule's period.
    period: Option<Duration>,
    /// The engine call that fires it next, and when, while it is armed.
    timer: Cell<Option<(TimerId, Time)>>,
    /// Fired for the last time, or called off.
    done: Cell<bool>,
}

/// One per engine: the fires counted by name, the schedules each owner
/// holds, and every schedule not done.
#[derive(Default)]
struct Registry {
    fired: RefCell<BTreeMap<&'static str, u64>>,
    owned: RefCell<HashMap<ObjectId, Vec<Weak<Slot>>>>,
    live: RefCell<Vec<Weak<Slot>>>,
    /// Whether the destroy listener that cancels owned schedules is in.
    listening: Cell<bool>,
}

fn live(slot: &Weak<Slot>) -> bool {
    slot.upgrade().is_some_and(|slot| !slot.done.get())
}

impl Registry {
    fn of(engine: &Engine) -> Rc<Registry> {
        let registry = engine.extension::<Registry>();
        if !registry.listening.replace(true) {
            engine.on_destroyed(|engine, gone| {
                let registry = engine.extension::<Registry>();
                let slots: Vec<Weak<Slot>> = {
                    let mut owned = registry.owned.borrow_mut();
                    if owned.is_empty() {
                        return;
                    }
                    gone.iter()
                        .filter_map(|object| owned.remove(object))
                        .flatten()
                        .collect()
                };
                for slot in slots.iter().filter_map(Weak::upgrade) {
                    Schedule(slot).cancel(engine);
                }
            });
        }
        registry
    }

    fn adopt(&self, slot: &Rc<Slot>) {
        let weak = Rc::downgrade(slot);
        if let Some(owner) = slot.owner {
            let mut owned = self.owned.borrow_mut();
            let list = owned.entry(owner).or_default();
            list.retain(live);
            list.push(weak.clone());
        }
        let mut all = self.live.borrow_mut();
        all.retain(live);
        all.push(weak);
    }
}

/// `f` once, `delay` from now. Goes with `owner` when that is destroyed
/// first.
pub fn after(
    engine: &Engine,
    name: &'static str,
    owner: Option<ObjectId>,
    delay: Duration,
    f: impl FnOnce(&Engine) + 'static,
) -> Schedule {
    at(engine, name, owner, engine.now() + delay, f)
}

/// `f` once, at `when` on the engine's clock (at once, if that has
/// passed).
pub fn at(
    engine: &Engine,
    name: &'static str,
    owner: Option<ObjectId>,
    when: Time,
    f: impl FnOnce(&Engine) + 'static,
) -> Schedule {
    let mut f = Some(f);
    start(engine, name, owner, None, when, move |engine| {
        if let Some(f) = f.take() {
            f(engine);
        }
    })
}

/// `f` every `period`, the first `period` from now, until cancelled or
/// its owner goes. A fire the app was too busy for is not made up: the
/// next comes a period after the late one, never a burst.
pub fn every(
    engine: &Engine,
    name: &'static str,
    owner: Option<ObjectId>,
    period: Duration,
    f: impl Fn(&Engine) + 'static,
) -> Schedule {
    let period = period.max(Duration::from_millis(1));
    start(engine, name, owner, Some(period), engine.now() + period, f)
}

fn start(
    engine: &Engine,
    name: &'static str,
    owner: Option<ObjectId>,
    period: Option<Duration>,
    when: Time,
    f: impl FnMut(&Engine) + 'static,
) -> Schedule {
    let slot = Rc::new(Slot {
        name,
        owner,
        period,
        timer: Cell::new(None),
        done: Cell::new(false),
    });
    if owner.is_some_and(|owner| !engine.is_alive(owner)) {
        slot.done.set(true);
        return Schedule(slot);
    }
    Registry::of(engine).adopt(&slot);
    arm(engine, &slot, when, Rc::new(RefCell::new(f)));
    Schedule(slot)
}

fn arm(engine: &Engine, slot: &Rc<Slot>, when: Time, fire: Fire) {
    // The call holds the slot, so a schedule whose handles were all
    // dropped still fires; cancelling drops the call and with it the slot.
    let held = slot.clone();
    let timer = engine.call_at(when, move |engine| run(engine, &held, when, fire));
    slot.timer.set(Some((timer, when)));
}

fn run(engine: &Engine, slot: &Rc<Slot>, due: Time, fire: Fire) {
    slot.timer.set(None);
    if slot.done.get() || slot.owner.is_some_and(|owner| !engine.is_alive(owner)) {
        slot.done.set(true);
        return;
    }
    *Registry::of(engine)
        .fired
        .borrow_mut()
        .entry(slot.name)
        .or_default() += 1;
    if slot.period.is_none() {
        slot.done.set(true);
    }
    (fire.borrow_mut())(engine);
    // `f` may have called it off.
    if let Some(period) = slot.period
        && !slot.done.get()
    {
        arm(engine, slot, next_due(due, engine.now(), period), fire);
    }
}

/// When a repeating schedule due at `due`, fired at `now`, fires next: a
/// period on from its deadline when it fired on time, and a period after
/// the late fire when it did not, so a late fire is never followed by one
/// sooner than a period.
fn next_due(due: Time, now: Time, period: Duration) -> Time {
    if now > due {
        now + period
    } else {
        due + period
    }
}

impl Schedule {
    /// Calls it off: it does not fire, now or again. Calling off one that
    /// fired for the last time, or was called off, does nothing.
    pub fn cancel(&self, engine: &Engine) {
        self.0.done.set(true);
        if let Some((timer, _)) = self.0.timer.take() {
            engine.cancel_call(timer);
        }
    }

    /// Whether it will still fire.
    pub fn is_pending(&self) -> bool {
        !self.0.done.get()
    }

    /// When it fires next, on the engine's clock.
    pub fn due(&self) -> Option<Time> {
        self.0.timer.get().map(|(_, due)| due)
    }

    pub fn name(&self) -> &'static str {
        self.0.name
    }
}

/// A field for the one schedule of its kind: holding another calls off
/// the one before.
#[derive(Default)]
pub struct Held(Cell<Option<Schedule>>);

impl Held {
    pub fn hold(&self, engine: &Engine, schedule: Schedule) {
        self.cancel(engine);
        self.0.set(Some(schedule));
    }

    pub fn cancel(&self, engine: &Engine) {
        clear_cell(engine, &self.0);
    }

    /// Whether what it holds will still fire.
    pub fn is_pending(&self) -> bool {
        let held = self.0.take();
        let pending = held.as_ref().is_some_and(Schedule::is_pending);
        self.0.set(held);
        pending
    }
}

/// Cancels what `slot` holds and empties it: for a field that holds the
/// one schedule of its kind.
pub fn clear(engine: &Engine, slot: &mut Option<Schedule>) {
    if let Some(schedule) = slot.take() {
        schedule.cancel(engine);
    }
}

/// [`clear`] for a field behind a shared reference.
pub fn clear_cell(engine: &Engine, slot: &Cell<Option<Schedule>>) {
    if let Some(schedule) = slot.take() {
        schedule.cancel(engine);
    }
}

/// How often each schedule fired on `engine`, by name.
pub fn fired(engine: &Engine) -> BTreeMap<&'static str, u64> {
    Registry::of(engine).fired.borrow().clone()
}

/// The schedules armed on `engine`, each name with when it is next due,
/// soonest first.
pub fn pending(engine: &Engine) -> Vec<(&'static str, Time)> {
    let registry = Registry::of(engine);
    let mut armed: Vec<(&'static str, Time)> = registry
        .live
        .borrow()
        .iter()
        .filter_map(Weak::upgrade)
        .filter_map(|slot| slot.timer.get().map(|(_, due)| (slot.name, due)))
        .collect();
    armed.sort_by_key(|(_, due)| *due);
    armed
}

/// The first moment after `now`, up to `until`, at which `label` reads
/// otherwise than at `now`, for text that moves on with the clock ("in
/// 12m", "5m ago"): when to show it again instead of ticking. `label`
/// must never come back to a value it left as time goes on, which holds
/// for countdowns and ages. `None` when it reads the same up to `until`.
pub fn next_change<L: PartialEq>(now: i64, until: i64, label: impl Fn(i64) -> L) -> Option<i64> {
    let shown = label(now);
    if until <= now || label(until) == shown {
        return None;
    }
    // The label at `low` is the one shown; at `high` it is not.
    let (mut low, mut high) = (now, until);
    while high - low > 1 {
        let mid = low + (high - low) / 2;
        if label(mid) == shown {
            low = mid;
        } else {
            high = mid;
        }
    }
    Some(high)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_label_changes_at_its_first_differing_moment() {
        let minutes = |t: i64| (1_000_000 - t).max(0) / 60_000;
        let at = next_change(0, 1_000_000, minutes).unwrap();
        assert_eq!(minutes(at - 1), minutes(0));
        assert_ne!(minutes(at), minutes(0));
        assert_eq!(next_change(0, 10, |_| 1), None);
    }

    #[test]
    fn a_late_fire_is_followed_a_period_later() {
        let ms = |ms: u64| Time::ZERO + Duration::from_millis(ms);
        let period = Duration::from_millis(100);
        // On time: the cadence keeps to its deadlines.
        assert_eq!(next_due(ms(100), ms(100), period), ms(200));
        // Due at 100, delivered at 199: not again at 200, a millisecond on.
        assert_eq!(next_due(ms(100), ms(199), period), ms(299));
        // Delivered past the next deadline: no burst to catch up.
        assert_eq!(next_due(ms(100), ms(350), period), ms(450));
    }
}
