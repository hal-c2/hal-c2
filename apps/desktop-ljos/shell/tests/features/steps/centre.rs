//! The thread in the window's centre, past its rows: copying a message
//! (TimelineModel::copy), the two ways into a revert, a reply's and the diff
//! panel's, which both ask Panel.diff (ThreadDiff) and so the same question,
//! and following a thread again after its MC stopped sending it
//! (ThreadStore::reload) (timeline/streaming.feature,
//! timeline/checkpoints.feature, and the reply without a checkpoint in
//! features/desktop/native-centre.feature): desktop-qt's CentreSteps.cpp.

use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::threads::ThreadStore;
use hal_c2_shell::thread_view::thread_diff::{DiffTab, ThreadDiff};
use hal_c2_shell::thread_view::timeline::Timeline;
use ljos::prelude::{ObjectId, Value as Qml};
use serde_json::{Value, json};

use super::stream::{
    FakeStreams, add_item, describe, followers, look_at_thread, read, role, settle_run, start_run,
    timeline_object,
};
use crate::harness::{Failure, Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

/// The agent replies the steps' thread has, in order.
#[derive(Default)]
struct FakeTurns {
    replies: Vec<String>,
}

fn thread_key(world: &mut World) -> String {
    let fake = world.mc.part::<FakeStreams>();
    format!("{}:{}", fake.environment, fake.thread)
}

fn diff_object(world: &mut World) -> Outcome<ObjectId> {
    world
        .with::<RightPanel, _>(|p, _| p.diff())?
        .ok_or_else(|| Failure("the panel has no diff".into()))
}

fn with_diff<R>(world: &mut World, f: impl FnOnce(&DiffTab) -> R) -> Outcome<R> {
    let obj = diff_object(world)?;
    ThreadDiff::read(world.engine(), obj, f).ok_or_else(|| Failure("the diff is busy".into()))
}

fn update_diff<R>(world: &mut World, f: impl FnOnce(&mut DiffTab) -> R) -> Outcome<R> {
    let obj = diff_object(world)?;
    ThreadDiff::update(world.engine(), obj, f).ok_or_else(|| Failure("the diff is busy".into()))
}

/// The row of the reply reading `wanted`, or empty.
fn row_reading(world: &World, wanted: &str) -> Outcome<String> {
    let rows = read(world, Timeline::row_count)?;
    for row in 0..rows {
        if text(&role(world, row, "text")) == wanted {
            return Ok(text(&role(world, row, "id")));
        }
    }
    Ok(String::new())
}

fn checkpoint_of(world: &World, reply: &str) -> Outcome<Value> {
    let reply = reply.to_owned();
    read(world, move |t| Value::Object(t.checkpoint_of(&reply)))
}

/// The `checkpoint.rollback` commands the MC got.
fn rollbacks(world: &World) -> Vec<Value> {
    world
        .mc
        .commands
        .iter()
        .filter(|command| command["type"] == "checkpoint.rollback")
        .cloned()
        .collect()
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("a thread in {Q} whose first turn left no checkpoint"),
        |world, c, _| {
            look_at_thread(world, &c[0])?;
            start_run(world, 60, "running")?;
            let reply = add_item(
                world,
                "assistant_message",
                json!({"text": "Turn 1 is done."}),
            )?;
            world.mc.part::<FakeTurns>().replies.push(reply);
            settle_run(world, "completed", 30)
        },
    );

    // Copying.
    steps.step("the agent has answered", |world, _, _| {
        start_run(world, 30, "running")?;
        let reply = add_item(
            world,
            "assistant_message",
            json!({"text": "The cart adds **tax** now."}),
        )?;
        world.mc.part::<FakeTurns>().replies.push(reply);
        settle_run(world, "completed", 30)
    });
    steps.step("the user copies the reply", |world, _, _| {
        world.set_clipboard("");
        let reply = world
            .mc
            .part::<FakeTurns>()
            .replies
            .first()
            .cloned()
            .unwrap_or_default();
        let timeline = timeline_object(world)?;
        let copied = world
            .engine()
            .invoke_by_name(timeline, "copy", &[Qml::from(reply.as_str())])
            .map_err(|e| Failure(format!("copy: {e:?}")))?;
        expect!(
            matches!(copied, Qml::Bool(true)),
            "the reply cannot be copied; {}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the reply's markdown is on the clipboard", |world, _, _| {
        let copied = world.clipboard();
        expect!(
            copied == "The cart adds **tax** now.",
            "the clipboard holds \"{copied}\""
        );
        Ok(())
    });

    // Reverting: the reply's Revert and the diff panel's, as their QML asks
    // (ThreadView.askRevert, DiffPanel), answered as RevertDialog does. The
    // thread is PanelSteps' "a thread in ... with three finished turns".
    steps.step(
        "the user asks to revert to turn (\\d+) from (its reply|the diff panel)",
        |world, c, _| {
            let turn: i32 = c[0].parse().unwrap_or(0);
            if c[1] == "its reply" {
                let reply = row_reading(world, &format!("Answer {turn}"))?;
                let checkpoint = checkpoint_of(world, &reply)?;
                expect!(
                    checkpoint["turn"].as_i64() == Some(i64::from(turn)),
                    "the reply offers {turn}; {}",
                    describe(world)
                );
                update_diff(world, |d| d.request_revert(turn))?;
            } else {
                world.dispatch("panel.open", json!({"tab": "diff", "turn": turn}))?;
                world.wait_for_with(
                    |w| {
                        let Ok(Some(obj)) = w.with::<RightPanel, _>(|p, _| p.diff()) else {
                            return false;
                        };
                        ThreadDiff::read(w.engine(), obj, |d| d.shown_turn()) == Some(turn)
                    },
                    |_| format!("the diff to show turn {turn}"),
                )?;
                update_diff(world, |d| d.request_revert(0))?;
            }
            let asked = with_diff(world, |d| d.revert_turn())?;
            expect!(asked == turn, "the user is asked about turn {asked}");
            expect!(
                rollbacks(world).is_empty(),
                "a rollback was sent before the user confirmed"
            );
            Ok(())
        },
    );
    steps.step(&format!("the user confirms with {Q}"), |world, c, _| {
        let answers = ["Keep files", "Revert files too"];
        expect!(
            answers.contains(&c[0].as_str()),
            "the dialog offers {}",
            answers.join(", ")
        );
        let restore = c[0] == answers[1];
        update_diff(world, |d| d.confirm_revert(restore))?;
        world.wait_for("the revert to finish", diff_idle)?;
        world.sync()
    });
    steps.step(
        "the MC is asked to leave the files as they are",
        |world, _, _| {
            world.wait_for_with(
                |w| !rollbacks(w).is_empty(),
                |_| "a rewind; the MC got none".to_owned(),
            )?;
            let Some(command) = rollbacks(world).last().cloned() else {
                fail!("no rewind");
            };
            expect!(
                command["restoreFiles"] == json!(false),
                "the MC was asked {}",
                show(&command)
            );
            Ok(())
        },
    );
    steps.step("the first turn's reply offers no rewind", |world, _, _| {
        let reply = world
            .mc
            .part::<FakeTurns>()
            .replies
            .first()
            .cloned()
            .unwrap_or_default();
        let checkpoint = checkpoint_of(world, &reply)?;
        expect!(
            checkpoint.as_object().is_some_and(|o| o.is_empty()),
            "the reply offers {}",
            show(&checkpoint)
        );
        update_diff(world, |d| d.request_revert(1))?;
        let (can, asked) = with_diff(world, |d| (d.can_revert(), d.revert_turn()))?;
        expect!(!can && asked == 0, "the user is asked to revert");
        Ok(())
    });

    // Following again.
    steps.step("the MC stops sending the thread", |world, _, _| {
        let (environment, thread) = {
            let fake = world.mc.part::<FakeStreams>();
            (fake.environment.clone(), fake.thread.clone())
        };
        world.mc.part::<FakeStreams>().offline.insert(environment);
        for id in followers(&world.mc, &thread) {
            world
                .mc
                .send(&json!({"t": "error", "id": id, "reason": "stream closed"}));
            world.mc.forget(id);
        }
        world.sync()
    });
    steps.step("the MC can send the thread again", |world, _, _| {
        let environment = world.mc.part::<FakeStreams>().environment.clone();
        world.mc.part::<FakeStreams>().offline.remove(&environment);
        Ok(())
    });
    steps.step("the user retries the thread", |world, _, _| {
        let key = thread_key(world);
        world.with::<ThreadStore, _>(move |store, engine| store.reload(engine, &key))?;
        Ok(())
    });
    steps.step("the thread is still unreachable", |world, _, _| {
        world.sync()?;
        let status = read(world, |t| t.status().to_owned())?;
        expect!(status == "unreachable", "{}", describe(world));
        Ok(())
    });
}

fn diff_idle(world: &World) -> bool {
    let Ok(Some(obj)) = world.with::<RightPanel, _>(|p, _| p.diff()) else {
        return true;
    };
    ThreadDiff::read(world.engine(), obj, |d| !d.reverting()).unwrap_or(true)
}
