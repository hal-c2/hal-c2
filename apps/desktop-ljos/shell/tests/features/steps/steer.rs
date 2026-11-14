//! A reply a steer cut off (features/timeline/runs-and-queue.feature): the
//! MC marks the run with the steer that ends it, and its reply stops where
//! it was; the steer starts the next run. desktop-qt's TimelineSteps.cpp.

use hal_c2_shell::thread_view::timeline_model::TimelineModel;
use serde_json::{Value, json};

use super::stream::{FakeStreams, THREAD, add_item, describe, role, set, settle_run, start_run};
use super::timeline::{expect_answer, row_showing, rows_of};
use crate::harness::{Outcome, Q, Steps, text};
use crate::world::World;
use crate::{expect, fail};

const HALF: &str = "The cart total is half wri";

/// The run ends interrupted, its reply stopping where it was if it streamed.
fn interrupt(world: &mut World) -> Outcome {
    settle_run(world, "interrupted", 5)?;
    let reply = world
        .mc
        .part::<FakeStreams>()
        .threads
        .get(THREAD)
        .and_then(|entities| entities.get("turn-item\nreply-1"))
        .cloned()
        .unwrap_or(Value::Null);
    if text(&reply["status"]) == "running" {
        set(
            world,
            "turn-item",
            "reply-1",
            json!({"status": "interrupted", "streaming": false}),
        )?;
    }
    Ok(())
}

fn not_cut_off(world: &World) -> Outcome {
    for row in rows_of(world, "fold")? {
        expect!(
            text(&role(world, row, "title")) != "Cut off by a steer",
            "the reply is folded as cut off; {}",
            describe(world)
        );
    }
    Ok(())
}

pub fn register(steps: &mut Steps) {
    steps.step("the agent finished its reply", |world, _, _| {
        start_run(world, 30, "running")?;
        add_item(
            world,
            "assistant_message",
            json!({"id": "reply-1", "text": "The cart total is done."}),
        )?;
        Ok(())
    });
    steps.step("the agent is in the middle of its reply", |world, _, _| {
        start_run(world, 30, "running")?;
        add_item(
            world,
            "assistant_message",
            json!({"id": "reply-1", "text": HALF, "status": "running", "streaming": true}),
        )?;
        Ok(())
    });
    steps.step("the run ends interrupted without a steer", |world, _, _| {
        interrupt(world)
    });
    steps.step(
        "the user's steer restarts the run(?: before the turn closed)?",
        |world, _, _| {
            let (run, next) = {
                let fake = world.mc.part::<FakeStreams>();
                (fake.run.clone(), fake.ordinal + 1)
            };
            set(
                world,
                "run",
                &run,
                json!({"steeredByRunId": format!("run-{next}")}),
            )?;
            interrupt(world)?;
            let run = start_run(world, 0, "running")?;
            set(
                world,
                "turn-item",
                &format!("message:{run}"),
                json!({"text": "Add tax to the cart", "inputIntent": "steer"}),
            )?;
            add_item(
                world,
                "assistant_message",
                json!({"id": "reply-2", "text": "Tax added.", "status": "running",
                       "streaming": true}),
            )?;
            Ok(())
        },
    );
    steps.step(
        "the finished reply stays visible as the turn's answer",
        |world, _, _| {
            world.sync()?;
            expect_answer(world, "The cart total is done.")
        },
    );
    steps.step("it is not folded away as partial output", |world, _, _| {
        not_cut_off(world)?;
        let row = row_showing(world, "reply-1")?;
        expect!(
            role(world, row, "kind") == "message",
            "the reply is not its own message; {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "what the agent had written is not folded as cut off",
        |world, _, _| {
            world.sync()?;
            not_cut_off(world)?;
            let row = row_showing(world, "reply-1")?;
            expect!(
                role(world, row, "text") == HALF,
                "the reply is not shown; {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("what the agent had written is folded under {Q}"),
        |world, c, _| {
            world.sync()?;
            let fold = rows_of(world, "fold")?
                .into_iter()
                .filter(|row| text(&role(world, *row, "title")) == c[0])
                .last();
            let Some(fold) = fold else {
                fail!("no fold reads \"{}\"; {}", c[0], describe(world));
            };
            for row in 0..super::stream::row_count(world)? {
                expect!(
                    role(world, row, "rowId") != "reply-1",
                    "the cut off reply is in view; {}",
                    describe(world)
                );
            }
            let id = text(&role(world, fold, "rowId"));
            let timeline = super::stream::timeline_object(world)?;
            TimelineModel::update(world.engine(), timeline, |t| t.toggle(&id));
            world.pump()?;
            let reply = row_showing(world, "reply-1")?;
            expect!(
                role(world, reply, "text") == HALF,
                "opening the fold shows {}",
                describe(world)
            );
            Ok(())
        },
    );
}
