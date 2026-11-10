//! Saying what was read (features/terminal/io.feature): the fake MC's
//! output window. desktop-qt's TerminalSessionSteps.cpp, "Saying what was
//! read".

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::terminals::{DEFAULT_ACK_DELAY_MS, set_ack_delay};
use serde_json::json;

use crate::expect;
use crate::harness::{Outcome, Steps};
use crate::steps::terminal::{
    FakeTerminals, attached, drawer_open, print, shown_thread, terminal_session, terminal_window,
};
use crate::world::World;

const TERM: &str = "term-1";

/// What the steps remember between them; dropping it (with the scenario's
/// MC) puts the ack delay back.
#[derive(Default)]
struct AckWorld {
    /// The acks the MC had when the step that counts began.
    marked: usize,
    /// The terminal the user left, as "threadId/terminalId".
    key: String,
    thread: String,
}

impl Drop for AckWorld {
    fn drop(&mut self) {
        set_ack_delay(DEFAULT_ACK_DELAY_MS);
    }
}

fn shown_key(world: &World) -> String {
    format!("{}/{TERM}", shown_thread(world))
}

fn shown_or_left(world: &World) -> String {
    match world.mc.peek::<AckWorld>() {
        Some(acks) if !acks.key.is_empty() => acks.key.clone(),
        _ => shown_key(world),
    }
}

fn acks(world: &World) -> usize {
    world.mc.peek::<FakeTerminals>().map_or(0, |f| f.acks.len())
}

fn caught_up(world: &World, key: &str) -> bool {
    terminal_window(&world.mc, key).is_some_and(|w| w.pending.is_empty())
}

fn wait_caught_up(world: &mut World, key: &str, what: &str) -> Outcome {
    let key = key.to_owned();
    world.wait_for(what, move |w| caught_up(w, &key))
}

fn acked_all(world: &World) -> bool {
    let key = shown_or_left(world);
    caught_up(world, &key) && acks(world) > 0
}

fn open_thread(world: &mut World, thread: &str) -> Outcome {
    let key = format!("{}:{thread}", world.mc.environment_id);
    world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Thread(key)))?;
    let thread = thread.to_owned();
    world.wait_for("the thread to show", move |w| shown_thread(w) == thread)?;
    world.sync()
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "saying what was read waits as long as it can",
        |world, _, _| {
            let key = shown_key(world);
            wait_caught_up(world, &key, "the MC to hear of the output so far")?;
            world.mc.part::<AckWorld>().marked = acks(world);
            set_ack_delay(3_600_000);
            Ok(())
        },
    );
    steps.step("the shell prints a little, five times", |world, _, _| {
        let thread = shown_thread(world);
        for chunk in 0..5 {
            print(&mut world.mc, &thread, TERM, &format!("chunk {chunk}\r\n"));
        }
        world.wait_for("the output to arrive", |w| {
            terminal_session(w, TERM).is_ok_and(|s| s.transcript().contains("chunk 4"))
        })
    });
    steps.step("the shell prints a little", |world, _, _| {
        world.sync()?;
        let thread = shown_thread(world);
        world.mc.part::<AckWorld>().key = format!("{thread}/{TERM}");
        print(&mut world.mc, &thread, TERM, "a little\r\n");
        Ok(())
    });
    steps.step(
        "the MC has heard nothing about that output yet",
        |world, _, _| {
            world.sync()?;
            let heard = acks(world) - world.mc.part::<AckWorld>().marked;
            expect!(heard == 0, "the MC heard {heard} times");
            Ok(())
        },
    );
    steps.step("the shell prints 20 KiB more", |world, _, _| {
        let thread = shown_thread(world);
        let data = format!("{}\r\n", "x".repeat(20 * 1024));
        print(&mut world.mc, &thread, TERM, &data);
        Ok(())
    });
    steps.step(
        "the MC hears once that all of it has been read",
        |world, _, _| {
            world.wait_for("the MC to hear", acked_all)?;
            world.sync()?;
            let heard = acks(world) - world.mc.part::<AckWorld>().marked;
            expect!(heard == 1, "the MC heard {heard} times");
            let key = shown_or_left(world);
            let fake = world.mc.part::<FakeTerminals>();
            let printed = fake.terminals.get(&key).map_or(0, |t| t.sequence);
            let last = fake.acks.last().and_then(|a| a["sequence"].as_i64());
            expect!(
                last == Some(printed),
                "the MC heard of {last:?}, not the last chunk {printed}"
            );
            Ok(())
        },
    );
    steps.step(
        "the MC hears that all of it has been read",
        |world, _, _| world.wait_for("the MC to hear", acked_all),
    );
    steps.step("the user hides the terminal drawer", |world, _, _| {
        world.dispatch("terminal.toggle", json!({}))?;
        world.sync()?;
        expect!(!drawer_open(world), "the drawer is still open");
        Ok(())
    });
    steps.step(
        "the connection to the MC drops and comes back",
        |world, _, _| {
            world.sync()?;
            world.mc.part::<AckWorld>().marked = acks(world);
            let subscribed = world.mc.subscriptions.len();
            world.mc.drop_connection();
            world.wait_for("the terminal to attach again", move |w| {
                w.mc.subscriptions.len() > subscribed && !attached(&w.mc).is_empty()
            })?;
            world.sync()
        },
    );
    steps.step(
        "the terminal asks again to say what it has read",
        |world, _, _| {
            let key = shown_key(world);
            expect!(
                terminal_window(&world.mc, &key).is_some(),
                "the attach asked for no window"
            );
            Ok(())
        },
    );
    steps.step("the MC hears once, of the new snapshot", |world, _, _| {
        let key = shown_key(world);
        wait_caught_up(world, &key, "the MC to hear of the snapshot")?;
        world.sync()?;
        let heard = acks(world) - world.mc.part::<AckWorld>().marked;
        expect!(heard == 1, "the MC heard {heard} times");
        Ok(())
    });
    steps.step("the user goes to another thread", |world, _, _| {
        let thread = shown_thread(world);
        let key = format!("{thread}/{TERM}");
        {
            let acks = world.mc.part::<AckWorld>();
            acks.key = key.clone();
            acks.thread = thread.clone();
        }
        wait_caught_up(world, &key, "the MC to hear of the output so far")?;
        let other = "elsewhere";
        let mut row = world.mc.threads.get(&thread).cloned().unwrap_or_default();
        row["id"] = json!(other);
        world.mc.threads.insert(other.to_owned(), row.clone());
        world.mc.send_row(other, &row);
        open_thread(world, other)
    });
    steps.step(
        "the shell prints more than the MC sends a client that has not read it",
        |world, _, _| {
            world.sync()?;
            world.mc.part::<AckWorld>().marked = acks(world);
            let thread = world.mc.part::<AckWorld>().thread.clone();
            let data = format!("{}\r\n", "x".repeat(20 * 1024));
            for _ in 0..5 {
                print(&mut world.mc, &thread, TERM, &data);
            }
            print(&mut world.mc, &thread, TERM, "the very last line\r\n");
            world.sync()
        },
    );
    steps.step("the MC holds the rest back", |world, _, _| {
        let key = world.mc.part::<AckWorld>().key.clone();
        let behind = terminal_window(&world.mc, &key).is_some_and(|w| w.behind);
        expect!(
            behind,
            "everything went out: the parked terminal said it had read it"
        );
        let marked = world.mc.part::<AckWorld>().marked;
        expect!(
            acks(world) == marked,
            "the parked terminal said what it read"
        );
        Ok(())
    });
    steps.step("the terminal stays attached", |world, _, _| {
        let key = world.mc.part::<AckWorld>().key.clone();
        let attached = attached(&world.mc);
        expect!(attached.contains(&key), "attached: {}", attached.join(" "));
        Ok(())
    });
    steps.step(
        "the user returns to the terminal's thread",
        |world, _, _| {
            let thread = world.mc.part::<AckWorld>().thread.clone();
            open_thread(world, &thread)
        },
    );
    steps.step(
        "the terminal has everything the shell printed",
        |world, _, _| {
            world.wait_for("what the MC held back", |w| {
                terminal_session(w, TERM)
                    .is_ok_and(|s| s.transcript().contains("the very last line"))
            })
        },
    );
    steps.step("the MC holds nothing back", |world, _, _| {
        let key = world.mc.part::<AckWorld>().key.clone();
        world.wait_for("the MC to hear of the snapshot", move |w| {
            terminal_window(&w.mc, &key).is_some_and(|win| !win.behind && win.pending.is_empty())
        })
    });
}
