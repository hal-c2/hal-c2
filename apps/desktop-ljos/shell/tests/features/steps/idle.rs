//! A desktop left alone (features/desktop/idle.feature): what woke it is
//! read from the fires the shell's schedules counted by name, and what
//! could still wake it from the schedules armed and the engine's own next
//! deadline.

use std::collections::BTreeMap;

use chrono::Duration;
use hal_c2_shell::controllers::toasts::Toasts;
use hal_c2_shell::schedule;
use serde_json::json;

use crate::harness::{Outcome, Q, Steps};
use crate::world::World;
use crate::{expect, fail};

/// The work a connected desktop does for itself all along.
const RECURRING: [&str; 2] = ["client activity lease", "desktop update check"];

/// The fires counted when the scenario started watching.
#[derive(Default)]
struct Idle {
    fired: BTreeMap<&'static str, u64>,
}

fn watch(world: &mut World) -> Outcome {
    world.pump()?;
    let fired = schedule::fired(world.engine());
    world.part::<Idle>().fired = fired;
    Ok(())
}

/// What fired since the scenario started watching, by name.
fn woke(world: &mut World) -> BTreeMap<&'static str, u64> {
    let before = world.part::<Idle>().fired.clone();
    schedule::fired(world.engine())
        .into_iter()
        .filter_map(|(name, count)| {
            let since = count - before.get(name).copied().unwrap_or(0);
            (since > 0).then_some((name, since))
        })
        .collect()
}

/// An hour on the shell's clock and on the wall clock, with nothing from
/// the user or the MC.
fn an_hour_passes(world: &mut World) -> Outcome {
    let later = world.now() + Duration::hours(1);
    world.advance(60 * 60 * 1000)?;
    world.set_time(later);
    world.pump()
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the desktop is open with no MC to connect to",
        |world, _, _| watch(world),
    );
    steps.step(
        "the desktop is connected to its MC and shows a thread last active 3 weeks ago",
        |world, _, _| {
            world.connect()?;
            world.sync()?;
            let thread = "thread-idle";
            let row = json!({"id": thread, "title": "Quiet", "projectId": "hal-c2",
                             "createdAt": "2026-09-02T09:00:00Z",
                             "updatedAt": "2026-09-02T09:00:00Z"});
            world.mc.threads.insert(thread.to_owned(), row.clone());
            world.mc.send_row(thread, &row);
            world.sync()?;
            super::mc_plugin::open_thread(world, thread)?;
            world.sync()?;
            watch(world)
        },
    );
    // Runs what the desktop scheduled for itself when it was opened, the
    // lease and the update check aside, which come back all along.
    steps.step("the desktop has done what it was asked", |world, _, _| {
        for _ in 0..10 {
            let engine = world.engine();
            let Some(&(_, due)) = schedule::pending(engine)
                .iter()
                .find(|(name, _)| !RECURRING.contains(name))
            else {
                break;
            };
            let ms = due
                .saturating_since(engine.now())
                .as_micros()
                .div_ceil(1000) as u64;
            if ms > 2 * 60 * 1000 {
                break;
            }
            let later = world.now() + Duration::milliseconds(ms as i64);
            world.advance(ms.max(1))?;
            world.set_time(later);
            world.pump()?;
        }
        watch(world)
    });
    steps.step(
        "an hour passes with no input(?: and no message)?",
        |world, _, _| an_hour_passes(world),
    );
    steps.step("nothing woke the desktop", |world, _, _| {
        let woke = woke(world);
        expect!(woke.is_empty(), "the desktop woke for {woke:?}");
        Ok(())
    });
    steps.step("nothing is scheduled to wake the desktop", |world, _, _| {
        let engine = world.engine();
        let armed = schedule::pending(engine);
        let deadline = engine.next_timer_deadline();
        let timers = engine.running_timers().len();
        expect!(
            armed.is_empty() && deadline.is_none() && timers == 0,
            "{armed:?} are scheduled, the engine wakes at {deadline:?}, and {timers} Timers run"
        );
        Ok(())
    });
    steps.step(
        "nothing but the client lease and the update check woke the desktop",
        |world, _, _| {
            let woke = woke(world);
            let others: Vec<_> = woke
                .keys()
                .filter(|name| !RECURRING.contains(name))
                .collect();
            expect!(others.is_empty(), "the desktop woke for {woke:?}");
            expect!(
                woke.contains_key("client activity lease"),
                "the lease was never renewed: the desktop woke for {woke:?}"
            );
            Ok(())
        },
    );
    steps.step(
        &format!(r"the desktop shows a notice {Q} that goes by itself in (\d+) seconds"),
        |world, c, _| {
            let ms = c[1].parse::<i64>().unwrap_or(0) * 1000;
            let title = c[0].clone();
            world.with::<Toasts, _>(|toasts, engine| {
                toasts.show(engine, "info", &title, "", None, ms);
            })?;
            watch(world)
        },
    );
    steps.step("the notice's going never ran", |world, _, _| {
        let woke = woke(world);
        if woke.contains_key("toast expiry") {
            fail!("the notice's going ran: the desktop woke for {woke:?}");
        }
        Ok(())
    });
}
