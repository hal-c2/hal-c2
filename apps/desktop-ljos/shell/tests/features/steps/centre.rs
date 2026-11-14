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
use ljos::prelude::{Engine, ObjectId, Value as Qml};
use serde_json::{Value, json};

use super::stream::{
    FakeStreams, add_item, describe, followers, look_at_thread, read, role, set, settle_run,
    start_run, timeline_object,
};
use crate::brick::{self, Brick};
use crate::harness::{Failure, Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

/// The agent replies the steps' thread has, in order.
#[derive(Default)]
struct FakeTurns {
    replies: Vec<String>,
    // Since the user last clicked a copy button, in real time: the shell's
    // clock follows it while a step waits.
    copied: Option<std::time::Instant>,
}

/// The open thread's timeline as the Timeline brick draws it.
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
        brick.write(world, root, "model", Qml::Object(timeline))?;
    }
    brick::shown(world)
}

fn collect(engine: &Engine, item: ObjectId, name: &str, out: &mut Vec<ObjectId>) {
    if matches!(engine.read_by_name(item, "objectName"), Qml::String(ref s) if s.as_str() == name) {
        out.push(item);
    }
    for child in engine.children(item) {
        collect(engine, child, name, out);
    }
}

fn str_of(world: &World, item: ObjectId, name: &str) -> String {
    match world.engine().read_by_name(item, name) {
        Qml::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

/// The copy button the timeline draws for `row_id`, or none.
fn copy_button(world: &World, brick: Brick, row_id: &str) -> Option<ObjectId> {
    let root = brick.root(world)?;
    let mut buttons = Vec::new();
    collect(world.engine(), root, "copyMessage", &mut buttons);
    buttons.into_iter().find(|&button| {
        world.engine().read_by_name(button, "visible") == Qml::Bool(true)
            && str_of(world, button, "rowId") == row_id
    })
}

/// What the first reply's copy button says beside itself: empty while it
/// says nothing.
fn copy_notice(world: &World, brick: Brick, row_id: &str) -> Vec<String> {
    let Some(button) = copy_button(world, brick, row_id) else {
        return Vec::new();
    };
    let mut found = Vec::new();
    collect(world.engine(), button, "copyNotice", &mut found);
    let Some(&notice) = found.first() else {
        return Vec::new();
    };
    if world.engine().read_by_name(notice, "visible") != Qml::Bool(true) {
        return Vec::new();
    }
    let mut said = Vec::new();
    for name in ["copyNoticeTitle", "copyNoticeReason"] {
        let mut texts = Vec::new();
        collect(world.engine(), notice, name, &mut texts);
        if let Some(&item) = texts.first()
            && world.engine().read_by_name(item, "visible") == Qml::Bool(true)
        {
            said.push(str_of(world, item, "text"));
        }
    }
    said
}

fn first_reply(world: &mut World) -> String {
    world
        .mc
        .part::<FakeTurns>()
        .replies
        .first()
        .cloned()
        .unwrap_or_default()
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
            return Ok(text(&role(world, row, "rowId")));
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
    steps.step(
        &format!("a thread in {Q} whose first turn failed but left a ready checkpoint"),
        |world, c, _| {
            look_at_thread(world, &c[0])?;
            let run = start_run(world, 60, "running")?;
            let reply = add_item(
                world,
                "assistant_message",
                json!({"text": "Turn 1 is done."}),
            )?;
            world.mc.part::<FakeTurns>().replies.push(reply);
            settle_run(world, "failed", 30)?;
            set(
                world,
                "checkpoint",
                "cp-1",
                json!({"id": "cp-1", "scopeId": "scope-1", "runId": run,
                       "appRunOrdinal": 1, "status": "ready"}),
            )
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
        let reply = first_reply(world);
        let brick = timeline_brick(world)?;
        let wanted = reply.clone();
        world.wait_for_with(
            move |w| copy_button(w, brick, &wanted).is_some(),
            |w| format!("the reply's copy button; {}", describe(w)),
        )?;
        let Some(button) = copy_button(world, brick, &reply) else {
            fail!("the reply has no copy button; {}", describe(world));
        };
        let (x, y) = brick.at(world, button, 0.5, 0.5)?;
        world.click_at(x, y)?;
        world.mc.part::<FakeTurns>().copied = Some(std::time::Instant::now());
        Ok(())
    });
    steps.step(
        "the copy button shows that the reply was copied",
        |world, _, _| {
            let reply = first_reply(world);
            let brick = timeline_brick(world)?;
            let button = copy_button(world, brick, &reply);
            expect!(
                button.is_some_and(|b| str_of(world, b, "icon") == "check"),
                "the copy button shows no check"
            );
            let said = copy_notice(world, brick, &reply);
            expect!(
                said == ["Copied!"],
                "beside the copy button: [{}]",
                said.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        "that confirmation goes away after about a second",
        |world, _, _| {
            let reply = first_reply(world);
            let brick = timeline_brick(world)?;
            let wanted = reply.clone();
            world.wait_for("the confirmation to go away", move |w| {
                copy_notice(w, brick, &wanted).is_empty()
            })?;
            let copied = world.mc.part::<FakeTurns>().copied;
            let shown = copied.map_or(0, |at| at.elapsed().as_millis());
            expect!(
                (800..3000).contains(&shown),
                "the confirmation went away after {shown}ms"
            );
            let button = copy_button(world, brick, &reply);
            expect!(
                button.is_some_and(|b| str_of(world, b, "icon") == "copy"),
                "the copy button still shows a check"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user sees a {Q} message beside the copy button with the reason"),
        |world, c, _| {
            let reply = first_reply(world);
            let brick = timeline_brick(world)?;
            let said = copy_notice(world, brick, &reply);
            expect!(
                said.len() == 2
                    && said[0] == c[0]
                    && said[1] == "The clipboard could not be written.",
                "beside the copy button: [{}]",
                said.join(", ")
            );
            Ok(())
        },
    );
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
