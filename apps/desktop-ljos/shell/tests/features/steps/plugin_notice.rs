//! A plugin's notice in a turn (features/plugins/turn-hooks.feature): one
//! that offers to stop its turn draws Stop while the turn works, and Stop
//! asks the MC to stop that turn, never one that started after it. The
//! notice is the item HalC2.Plugins.Host.notice/5 writes; the stream is
//! stream.rs's, the rows the timeline's and the Timeline brick's.
//! desktop-qt's PluginNoticeSteps.cpp.

use ljos::prelude::{ObjectId, Value as Js};
use serde_json::{Value, json};

use super::stream::{
    FakeStreams, THREAD, add_command, add_item, describe, role, row_count, settle_run,
    timeline_object,
};
use super::turn::start_working_turn;
use crate::brick::{self, Brick};
use crate::harness::{Failure, Outcome, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

/// The run the scenario's notice was shown in.
#[derive(Default)]
struct NoticeRun(String);

fn notice_run(world: &mut World) -> String {
    world.part::<NoticeRun>().0.clone()
}

fn toggle(world: &World, row_id: &str) -> Outcome {
    let timeline = timeline_object(world)?;
    world
        .engine()
        .invoke_by_name(timeline, "toggle", &[Js::from(row_id)])
        .map_err(|e| Failure(format!("toggle: {e:?}")))?;
    Ok(())
}

/// The notice's entry, wherever the timeline shows it (a settled turn folds
/// its work behind a summary; this opens it).
fn notice(world: &mut World) -> Outcome<Value> {
    for kind in ["fold", "work"] {
        for row in 0..row_count(world)? {
            if text(&role(world, row, "kind")) == kind
                && role(world, row, "hiddenCount").as_i64().unwrap_or(0) > 0
                && role(world, row, "expanded") != json!(true)
            {
                toggle(world, &text(&role(world, row, "rowId")))?;
            }
        }
    }
    world.sync()?;
    for row in 0..row_count(world)? {
        let entries = role(world, row, "entries");
        if let Some(entry) = entries
            .as_array()
            .into_iter()
            .flatten()
            .find(|entry| entry["label"] == json!("Loop"))
        {
            return Ok(entry.clone());
        }
    }
    fail!("the timeline shows no notice; {}", describe(world))
}

fn timeline_brick(world: &mut World) -> Outcome<Brick> {
    if world.part::<brick::Shown>().0.is_none() {
        let brick = Brick::new(
            world,
            "import QtQuick\nimport HalC2.Bricks\nTimeline {}\n",
            820.0,
            1400.0,
        )?;
        world.part::<brick::Shown>().0 = Some(brick);
        let timeline = timeline_object(world)?;
        let Some(root) = brick.root(world) else {
            fail!("the timeline brick has no root");
        };
        brick.write(world, root, "model", Js::Object(timeline))?;
    }
    brick::shown(world)
}

fn stop_links(world: &mut World) -> Outcome<Vec<ObjectId>> {
    let brick = timeline_brick(world)?;
    let mut links = Vec::new();
    while let Some(link) = brick.find_visible_nth(world, "noticeInterrupt", links.len())? {
        links.push(link);
    }
    Ok(links)
}

/// The runs the MC was asked to stop.
fn stopped(world: &mut World) -> Outcome<Vec<String>> {
    world.sync()?;
    Ok(world
        .mc
        .commands
        .iter()
        .filter(|command| command["type"] == json!("run.interrupt"))
        .map(|command| text(&command["runId"]))
        .collect())
}

fn click_stop(world: &mut World, what: &str) -> Outcome {
    let brick = timeline_brick(world)?;
    world.wait_for(&format!("the timeline to draw {what}"), |w| {
        brick
            .find_visible_nth(w, "noticeInterrupt", 0)
            .ok()
            .flatten()
            .is_some()
    })?;
    let Some(link) = stop_links(world)?.pop() else {
        fail!("{what} went away");
    };
    let (x, y) = brick.at(world, link, 0.5, 0.5)?;
    world.click_at(x, y)?;
    world.sync()
}

fn expect_stopped(world: &mut World) -> Outcome {
    let run = notice_run(world);
    let stopped = stopped(world)?;
    expect!(
        stopped == [run.clone()],
        "Stop did not ask the MC to stop the notice's turn {run}; it has {}",
        world.describe_commands()
    );
    Ok(())
}

fn no_stop_drawn(world: &mut World, what: &str) -> Outcome {
    let brick = timeline_brick(world)?;
    world.wait_for(&format!("the timeline to stop drawing {what}"), |w| {
        brick
            .find_visible_nth(w, "noticeInterrupt", 0)
            .ok()
            .flatten()
            .is_none()
    })
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "a plugin's notice in a turn that is working, offering to stop it",
        |world, _, _| {
            start_working_turn(world)?;
            add_command(world, 1, "completed")?;
            let run = world.mc.part::<FakeStreams>().run.clone();
            world.part::<NoticeRun>().0 = run;
            add_item(
                world,
                "system_notice",
                json!({"message": "The agent is repeating itself.", "title": "Loop",
                       "pluginId": "token-economizer", "actions": ["interrupt"]}),
            )?;
            Ok(())
        },
    );
    steps.step("the notice shows a Stop action", |world, _, _| {
        let entry = notice(world)?;
        let run = notice_run(world);
        expect!(
            text(&entry["interrupt"]) == run
                && entry["detail"] == json!("The agent is repeating itself."),
            "the notice is {}",
            show(&entry)
        );
        let brick = timeline_brick(world)?;
        click_stop(world, "the notice's Stop")?;
        expect!(
            brick.shows(world, "Loop")?,
            "the timeline does not draw the notice's title"
        );
        expect_stopped(world)
    });
    steps.step(
        "the turn runs another command after the notice",
        |world, _, _| {
            add_command(world, 2, "completed")?;
            Ok(())
        },
    );
    steps.step("the folded tool calls still offer Stop", |world, _, _| {
        world.sync()?;
        let group = (0..row_count(world)?)
            .rev()
            .find(|row| text(&role(world, *row, "kind")) == "work");
        let Some(group) = group else {
            fail!("the turn's calls are not grouped; {}", describe(world));
        };
        expect!(
            role(world, group, "hiddenCount").as_i64().unwrap_or(0) > 0
                && role(world, group, "expanded") != json!(true),
            "the turn's calls are not folded; {}",
            describe(world)
        );
        let entries = role(world, group, "entries");
        expect!(
            !entries
                .as_array()
                .into_iter()
                .flatten()
                .any(|entry| entry["label"] == json!("Loop")),
            "the notice is on screen, not folded"
        );
        let run = notice_run(world);
        expect!(
            text(&role(world, group, "stopRun")) == run,
            "the folded group does not offer to stop the notice's turn"
        );
        click_stop(world, "the folded group's Stop")?;
        expect_stopped(world)?;
        expect!(
            role(world, group, "expanded") != json!(true),
            "Stop opened the folded group"
        );
        Ok(())
    });
    // The thread's row says the next turn is the one working before the
    // notice's turn is seen to end, as a queued turn starts the moment the
    // one before it settles.
    steps.step(
        "the thread moves on to its next turn before the notice redraws",
        |world, _, _| {
            let Some(row) = world.mc.threads.get_mut(THREAD) else {
                fail!("the MC has no thread {THREAD}");
            };
            row["activeRunId"] = json!("run-next");
            row["latestRunId"] = json!("run-next");
            let row = row.clone();
            world.mc.send_row(THREAD, &row);
            world.sync()
        },
    );
    steps.step("the notice's Stop stops nothing", |world, _, _| {
        click_stop(world, "the notice's Stop")?;
        let stopped = stopped(world)?;
        expect!(
            stopped.is_empty(),
            "Stop asked the MC to stop {}",
            stopped.join(", ")
        );
        Ok(())
    });
    steps.step("the turn ends", |world, _, _| {
        settle_run(world, "interrupted", 30)
    });
    steps.step(
        "the folded tool calls no longer offer Stop",
        |world, _, _| {
            world.sync()?;
            for row in 0..row_count(world)? {
                expect!(
                    text(&role(world, row, "stopRun")).is_empty(),
                    "row {row} still offers to stop the turn; {}",
                    describe(world)
                );
            }
            no_stop_drawn(world, "the folded group's Stop")
        },
    );
    steps.step("the notice no longer offers to stop it", |world, _, _| {
        let entry = notice(world)?;
        expect!(
            text(&entry["interrupt"]).is_empty(),
            "the notice is {}",
            show(&entry)
        );
        no_stop_drawn(world, "the notice's Stop")
    });
}
