//! Connecting the shell to its MC, who owns what once it has, and the MCs
//! clustered with it (desktop-qt's ConnectionSteps.cpp;
//! features/desktop/native-connection.feature).

use std::cell::Cell;
use std::rc::Rc;

use crate::brick::Brick;
use crate::harness::{Q, Steps};
use crate::world::World;
use crate::{expect, fail};

/// A scripted run (main.rs --action, --key, --screenshot) starts on
/// `hal_c2_shell::when_active`, as desktop-qt's starts on NativeShell::ready.
#[derive(Default)]
struct ScriptedRun {
    started: Rc<Cell<u32>>,
    /// Whether the shell had the MC's rows when the run started.
    snapshot_in: Rc<Cell<bool>>,
}

const HOME_PAGE: &str = "import QtQuick\nimport HalC2.Bricks\nHomePage {}\n";

fn subscriptions_to(world: &World, kind: &str) -> usize {
    world
        .mc
        .subscriptions
        .iter()
        .filter(|s| s.pointer("/shape/type").and_then(|t| t.as_str()) == Some(kind))
        .count()
}

pub fn register(steps: &mut Steps) {
    // The MC.
    steps.step(
        &format!("the desktop's MC {Q} serves the environment {Q}"),
        |world, c, _| {
            world.mc.name = c[0].clone();
            world.mc.environment_id = c[1].clone();
            Ok(())
        },
    );
    steps.step(
        &format!("the MC is clustered with {Q}, which serves {Q}"),
        |world, c, _| {
            world.mc.join(&c[0], &c[1]);
            world.sync()
        },
    );

    // Connecting.
    steps.step(
        &format!("the desktop shell connects to its MC with the token {Q}"),
        |world, c, _| world.connect_with(&c[0]),
    );
    steps.step("the desktop shell connects to its MC", |world, _, _| {
        world.connect()
    });
    steps.step("the desktop shell is connected to its MC", |world, _, _| {
        world.connect()?;
        world.wait_for("the shell to start", World::active)
    });
    steps.step(
        "a scripted run is waiting for the desktop app",
        |world, _, _| {
            let started = world.part::<ScriptedRun>().started.clone();
            hal_c2_shell::when_active(world.engine(), move |_| started.set(started.get() + 1));
            Ok(())
        },
    );
    steps.step("the scripted run has not started", |world, _, _| {
        world.sync()?;
        let started = world.part::<ScriptedRun>().started.get();
        expect!(started == 0, "it started");
        Ok(())
    });
    steps.step("the scripted run starts once", |world, _, _| {
        let started = world.part::<ScriptedRun>().started.clone();
        let waiting = started.clone();
        world.wait_for("the scripted run to start", move |_| waiting.get() > 0)?;
        world.sync()?;
        expect!(started.get() == 1, "it started {} times", started.get());
        Ok(())
    });
    // A scripted screenshot (main.rs --screenshot) shows the window once the
    // shell is active; with no project that window is the home page.
    steps.step("the desktop app runs without a display", |_, _, _| {
        // The scenarios' window is a test window: nothing reaches a display.
        Ok(())
    });
    steps.step(
        "the user starts the desktop app asking for a screenshot",
        |world, _, _| {
            let run = world.part::<ScriptedRun>();
            let (started, snapshot_in) = (run.started.clone(), run.snapshot_in.clone());
            hal_c2_shell::when_active(world.engine(), move |engine| {
                started.set(started.get() + 1);
                let bridge = hal_c2_shell::bridge::Bridge::of(engine);
                snapshot_in.set(
                    bridge
                        .published(engine, "sidebar")
                        .is_some_and(|s| !s.is_null()),
                );
            });
            world.connect()?;
            let started = world.part::<ScriptedRun>().started.clone();
            world.wait_for("the scripted run to start", move |_| started.get() > 0)?;
            Brick::show(world, HOME_PAGE, 900.0, 700.0)
        },
    );
    steps.step(
        "the screenshot is taken once the MC's first snapshot is in",
        |world, _, _| {
            let run = world.part::<ScriptedRun>();
            let (started, snapshot_in) = (run.started.get(), run.snapshot_in.get());
            expect!(
                started == 1 && snapshot_in,
                "started {started} times, with the snapshot {snapshot_in}"
            );
            Ok(())
        },
    );
    steps.step(
        "the screenshot shows the app's native window, not an empty view",
        |world, _, _| {
            let brick = crate::brick::shown(world)?;
            let title = brick.item(world, "homeTitle")?;
            let shown = brick.flag(world, title, "visible")
                && !brick.text_of(world, title, "text").is_empty();
            expect!(shown, "the home page has no title");
            // Something was drawn over the background: the title's glyphs.
            expect!(
                world.painted(title) > 0,
                "the home page's title was not painted"
            );
            Ok(())
        },
    );
    steps.step("the MC holds back its snapshot", |world, _, _| {
        world.mc.hold_snapshot = true;
        Ok(())
    });
    steps.step("the MC sends its snapshot", |world, _, _| {
        world.mc.send_snapshot();
        world.sync()
    });
    steps.step("the MC stops accepting connections", |world, _, _| {
        world.mc.stop_accepting();
        Ok(())
    });
    steps.step("the MC drops the connection", |world, _, _| {
        world.mc.drop_connection();
        world.wait_for("the shell to see the drop", |w| !w.client_ready())
    });
    steps.step(
        &format!("the MC was reached with the token {Q}"),
        |world, c, _| {
            let Some(first) = world.mc.connections.first() else {
                fail!("the MC was never reached");
            };
            let url = url::Url::parse(first)
                .map_err(|e| crate::harness::Failure(format!("{first}: {e}")))?;
            expect!(url.path() == "/ws", "connected to {}, not /ws", url.path());
            let token = url
                .query_pairs()
                .find(|(name, _)| name == "token")
                .map(|(_, value)| value.into_owned())
                .unwrap_or_default();
            expect!(token == c[0], "connected with the token \"{token}\"");
            Ok(())
        },
    );
    steps.step(
        &format!("the shell subscribed to the MC's {Q} shape( again)?"),
        |world, c, _| {
            let wanted = if c.get(1).is_none_or(String::is_empty) {
                1
            } else {
                2
            };
            let kind = c[0].clone();
            world.wait_for(&format!("{wanted} subscription(s) to {}", c[0]), move |w| {
                subscriptions_to(w, &kind) >= wanted
            })
        },
    );
    steps.step(
        "the (?:shell|desktop) reconnects to the MC",
        |world, _, _| {
            world.wait_for("a second connection", |w| {
                w.mc.connections.len() >= 2 && w.client_ready()
            })
        },
    );
}
