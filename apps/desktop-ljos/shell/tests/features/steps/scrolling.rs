//! Following new output at the end of a long thread
//! (features/timeline/scrolling-and-links.feature): the Timeline brick
//! over the open thread holds the end while the agent writes, holds
//! still while nothing is written, stays where the user scrolled to,
//! and follows again from "Scroll to end": desktop-qt's
//! ScrollingSteps.cpp.
//!
//! The background's thread opens empty (the timeline steps'
//! look_at_thread), as the link scenarios of the file want it, so these
//! scenarios give it its turns in their first step.

use chrono::Duration;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::threads::ThreadStore;
use ljos::prelude::{ObjectId, Value};
use serde_json::{Value as Json, json};

use super::stream::{
    FakeStreams, THREAD, change, change_quietly, describe, iso, look, now, read, role,
    timeline_object,
};
use crate::brick::{self, Brick};
use crate::harness::{Outcome, Steps, text};
use crate::world::World;
use crate::{expect, fail};

// Turns enough to fill several views, and more items than a client opens
// a thread with (the timeline's window).
const TURNS: i64 = 28;
const CALLS: i64 = 8;

/// What a scenario watches across its steps.
#[derive(Default)]
struct Watch {
    seeded: bool,
    content_y: f64,
    content_height: f64,
    reading: String,
    reading_y: f64,
}

fn watch(world: &mut World) -> &mut Watch {
    world.mc.part::<Watch>()
}

fn real(world: &World, item: ObjectId, name: &str) -> f64 {
    match world.engine().read_by_name(item, name) {
        Value::Real(r) => r,
        Value::Int(n) => f64::from(n),
        _ => 0.0,
    }
}

fn flag(world: &World, item: ObjectId, name: &str) -> bool {
    world.engine().read_by_name(item, name) == Value::Bool(true)
}

fn rows(world: &mut World) -> Outcome<ObjectId> {
    let brick = timeline_brick(world)?;
    brick.item(world, "timelineRows")
}

/// As the brick reads its own end (Timeline.qml's nearEnd).
fn at_end(world: &World, list: ObjectId) -> bool {
    real(world, list, "contentY") + real(world, list, "height")
        >= real(world, list, "originY") + real(world, list, "contentHeight") - 4.0
}

fn describe_list(world: &World, list: ObjectId) -> String {
    format!(
        "at {} of {} from {}, {} high, following {}, away {}",
        real(world, list, "contentY"),
        real(world, list, "contentHeight"),
        real(world, list, "originY"),
        real(world, list, "height"),
        flag(world, list, "following"),
        flag(world, list, "away")
    )
}

fn timeline_brick(world: &mut World) -> Outcome<Brick> {
    brick::shown(world)
}

fn wait_at_end(world: &mut World) -> Outcome {
    let list = rows(world)?;
    world.wait_for_with(
        move |w| {
            real(w, list, "contentHeight") > real(w, list, "height")
                && at_end(w, list)
                && flag(w, list, "following")
        },
        move |w| {
            format!(
                "the view at the end of the thread; {}",
                describe_list(w, list)
            )
        },
    )
}

fn wait_still(world: &mut World) -> Outcome {
    let list = rows(world)?;
    world.wait_for("the timeline to stop scrolling", move |w| {
        !flag(w, list, "moving")
    })
}

/// The scenario's thread given `TURNS` settled turns, each a question,
/// `CALLS` tool calls and "Answer <n>" (the last with a table), then a
/// running turn whose reply "reply" is still being written; reopened
/// from scratch and drawn by the Timeline brick at its end.
fn seed_long(world: &mut World) -> Outcome {
    if std::mem::replace(&mut watch(world).seeded, true) {
        return Ok(());
    }
    let environment = world.mc.environment_id.clone();
    let key = format!("{environment}:{THREAD}");
    world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Home))?;
    world.with::<ThreadStore, _>(|s, engine| s.close(engine, &key))?;
    if let Some(cache) = hal_c2_shell::store::cache(world.engine()) {
        cache.forget_thread(&key);
    }
    world.sync()?;
    fn next(world: &mut World) -> i64 {
        let fake = world.mc.part::<FakeStreams>();
        fake.ordinal += 1;
        fake.ordinal
    }
    fn put(world: &mut World, kind: &str, id: &str, mut fields: Json) -> Outcome {
        fields["id"] = json!(id);
        change_quietly(world, kind, id, json!({"s": fields}), true)
    }
    for n in 1..=TURNS {
        let started = now() - Duration::seconds(3600 - n * 60);
        let run = format!("run-{}", world.mc.part::<FakeStreams>().ordinal + 1);
        let ordinal = next(world);
        put(
            world,
            "run",
            &run,
            json!({"ordinal": ordinal, "status": "completed",
                   "requestedAt": iso(started), "startedAt": iso(started),
                   "completedAt": iso(started + Duration::seconds(30))}),
        )?;
        let mut item = |world: &mut World, kind: &str, more: Json| -> Outcome {
            let ordinal = next(world);
            let mut fields = json!({"type": kind, "runId": run, "status": "completed",
                                    "updatedAt": iso(started), "ordinal": ordinal});
            if let Some(more) = more.as_object() {
                for (k, v) in more {
                    fields[k] = v.clone();
                }
            }
            put(world, "turn-item", &format!("{kind}:{ordinal}"), fields)
        };
        item(
            world,
            "user_message",
            json!({"text": format!("Question {n}")}),
        )?;
        for call in 1..=CALLS {
            item(
                world,
                "command_execution",
                json!({"input": format!("bun test {call}"), "exitCode": 0}),
            )?;
        }
        let mut answer = format!("Answer {n}");
        if n == TURNS {
            answer += "\n\n| Item | Price |\n| --- | --- |\n| Cart | 3 |\n| Tax | 1 |";
        }
        item(world, "assistant_message", json!({"text": answer}))?;
    }
    let run = format!("run-{}", world.mc.part::<FakeStreams>().ordinal + 1);
    world.mc.part::<FakeStreams>().run = run.clone();
    let ordinal = next(world);
    put(
        world,
        "run",
        &run,
        json!({"ordinal": ordinal, "status": "running",
               "requestedAt": iso(now()), "startedAt": iso(now())}),
    )?;
    let ordinal = next(world);
    put(
        world,
        "turn-item",
        &format!("message:{run}"),
        json!({"type": "user_message", "runId": run, "ordinal": ordinal,
               "status": "completed", "text": "Add a tax line to the cart",
               "updatedAt": iso(now())}),
    )?;
    let ordinal = next(world);
    put(
        world,
        "turn-item",
        "reply",
        json!({"type": "assistant_message", "runId": run, "ordinal": ordinal,
               "status": "running", "text": "The cart", "streaming": true,
               "updatedAt": iso(now())}),
    )?;
    look(world, &key, true)?;
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nTimeline {}\n",
        820.0,
        600.0,
    )?;
    world.part::<brick::Shown>().0 = Some(brick);
    let timeline = timeline_object(world)?;
    let Some(root) = brick.root(world) else {
        fail!("the timeline brick has no root");
    };
    brick.write(world, root, "model", Value::Object(timeline))?;
    wait_at_end(world)
}

/// The agent writes another paragraph of "reply".
fn grow(world: &mut World) -> Outcome {
    change(
        world,
        "turn-item",
        "reply",
        json!({"a": {"text": "\n\nAnother paragraph of the reply, written just now, with enough words to take a line or two of the view."}}),
    )?;
    world.sync()
}

/// The wheel turned up until the view is more than a page from the end.
fn scroll_away(world: &mut World) -> Outcome {
    let list = rows(world)?;
    let brick = timeline_brick(world)?;
    let (x, y) = brick.at(world, list, 0.5, 0.5)?;
    let far = |w: &World| {
        !flag(w, list, "following")
            && real(w, list, "originY") + real(w, list, "contentHeight")
                - (real(w, list, "contentY") + real(w, list, "height"))
                > real(w, list, "height")
    };
    // The wait cannot turn the wheel itself, so turn it between checks;
    // each notch glides, so time passes between them.
    world.hover_at(x, y)?;
    for _ in 0..200 {
        if far(world) {
            return wait_still(world);
        }
        world.wheel(x, y, 1.0)?;
        world.advance(50)?;
    }
    fail!("the view away from the end; {}", describe_list(world, list))
}

/// The drawn row `row_id`, or none while the list has not made it.
fn drawn_row(world: &World, list: ObjectId, row_id: &str) -> Option<ObjectId> {
    let count = super::stream::row_count(world).ok()?;
    let index = (0..count).find(|&row| text(&role(world, row, "rowId")) == row_id)?;
    match world
        .engine()
        .invoke_by_name(list, "itemAtIndex", &[Value::Int(index as i32)])
    {
        Ok(Value::Object(item)) => Some(item),
        _ => None,
    }
}

fn drawn_at(world: &mut World, row_id: &str) -> Outcome<f64> {
    let list = rows(world)?;
    let Some(row) = drawn_row(world, list, row_id) else {
        fail!("the row {row_id} is not drawn");
    };
    let brick = timeline_brick(world)?;
    Ok(brick.at(world, row, 0.0, 0.0)?.1)
}

/// The row at the top of the view, where the brick's own hold looks.
fn top_row(world: &mut World) -> Outcome<String> {
    let list = rows(world)?;
    let y = real(world, list, "contentY") + real(world, list, "topMargin") + 1.0;
    let index = match world.engine().invoke_by_name(
        list,
        "indexAt",
        &[
            Value::from(real(world, list, "width") / 2.0),
            Value::from(y),
        ],
    ) {
        Ok(Value::Int(index)) => index,
        Ok(other) => fail!("indexAt gave {other:?}"),
        Err(error) => fail!("indexAt: {error}"),
    };
    if index < 0 {
        fail!(
            "no row at the top of the view; {}",
            describe_list(world, list)
        );
    }
    Ok(text(&role(world, index as usize, "rowId")))
}

/// Whether the reply's drawn row ends inside the view.
fn reply_end_in_view(world: &World, brick: Brick, list: ObjectId) -> bool {
    let Some(row) = drawn_row(world, list, "reply") else {
        return false;
    };
    let (Ok((_, top)), Ok((_, bottom))) = (
        brick.at(world, list, 0.0, 0.0),
        brick.at(world, row, 0.0, 1.0),
    ) else {
        return false;
    };
    let bottom = bottom - top;
    bottom > 0.0 && bottom <= real(world, list, "height") + 1.0
}

fn wait_jump(world: &mut World) -> Outcome<ObjectId> {
    let brick = timeline_brick(world)?;
    world.wait_for("\"Scroll to end\" to be offered", move |w| {
        matches!(brick.find_visible(w, "jumpToLatest"), Ok(Some(_)))
    })?;
    match brick.find_visible(world, "jumpToLatest")? {
        Some(jump) => Ok(jump),
        None => fail!("\"Scroll to end\" is not offered"),
    }
}

pub fn register(steps: &mut Steps) {
    // Following the end.
    steps.step("the user is at the end of the thread", |world, _, _| {
        seed_long(world)?;
        wait_at_end(world)
    });
    steps.step("the agent writes more of its reply", |world, _, _| {
        let list = rows(world)?;
        watch(world).content_height = real(world, list, "contentHeight");
        grow(world)?;
        grow(world)
    });
    steps.step("the new text stays in view", |world, _, _| {
        let list = rows(world)?;
        let brick = timeline_brick(world)?;
        let before = watch(world).content_height;
        world.wait_for_with(
            move |w| {
                real(w, list, "contentHeight") > before
                    && at_end(w, list)
                    && reply_end_in_view(w, brick, list)
            },
            move |w| {
                format!(
                    "the new text in view; {} (was {before} high, reply drawn {}, its end in view {})",
                    describe_list(w, list),
                    drawn_row(w, list, "reply").is_some(),
                    reply_end_in_view(w, brick, list)
                )
            },
        )?;
        expect!(
            flag(world, list, "following"),
            "the view stopped following; {}",
            describe_list(world, list)
        );
        Ok(())
    });

    // The end holding still.
    steps.step(
        "a reply with a table sits just above the end",
        |world, _, _| {
            let rows = read(world, |t| t.row_count())?;
            let table = (0..rows).any(|row| text(&role(world, row, "text")).contains("| Cart |"));
            expect!(
                table,
                "no reply with a table is loaded; {}",
                describe(world)
            );
            wait_at_end(world)
        },
    );
    steps.step("nothing new is written", |world, _, _| {
        world.pump()?;
        wait_still(world)?;
        let list = rows(world)?;
        watch(world).content_y = real(world, list, "contentY");
        Ok(())
    });
    steps.step("the view does not move", |world, _, _| {
        world.sync()?;
        world.pump()?;
        wait_still(world)?;
        let list = rows(world)?;
        let y = real(world, list, "contentY");
        let was = watch(world).content_y;
        expect!((y - was).abs() < 1.0, "the view moved from {was} to {y}");
        Ok(())
    });

    // Scrolling away and coming back.
    steps.step("the agent is writing its reply", |world, _, _| {
        seed_long(world)?;
        let rows = read(world, |t| t.row_count())?;
        let streaming = (0..rows).any(|row| role(world, row, "streaming") == json!(true));
        expect!(streaming, "no reply is being written; {}", describe(world));
        wait_at_end(world)
    });
    steps.step(
        "the user scrolls up to an earlier message",
        |world, _, _| {
            scroll_away(world)?;
            world.pump()?;
            let reading = top_row(world)?;
            let y = drawn_at(world, &reading)?;
            let seen = watch(world);
            seen.reading = reading;
            seen.reading_y = y;
            grow(world)
        },
    );
    steps.step(
        "the view stays on that message while the reply grows",
        |world, _, _| {
            grow(world)?;
            world.pump()?;
            let reading = watch(world).reading.clone();
            let y = drawn_at(world, &reading)?;
            let was = watch(world).reading_y;
            expect!(
                (y - was).abs() < 1.0,
                "the message being read moved from {was} to {y} while the reply grew"
            );
            let list = rows(world)?;
            expect!(
                !flag(world, list, "following"),
                "the view is following again; {}",
                describe_list(world, list)
            );
            Ok(())
        },
    );
    steps.step(
        "the user is offered a way to scroll to the end",
        |world, _, _| {
            wait_jump(world)?;
            Ok(())
        },
    );
    steps.step(
        "the user has scrolled away from the end while the agent writes",
        |world, _, _| {
            seed_long(world)?;
            scroll_away(world)?;
            grow(world)
        },
    );
    steps.step("the user scrolls to the end", |world, _, _| {
        let jump = wait_jump(world)?;
        let brick = timeline_brick(world)?;
        let (x, y) = brick.at(world, jump, 0.5, 0.5)?;
        world.click_at(x, y)
    });
    steps.step("the latest output is shown", |world, _, _| {
        wait_at_end(world)?;
        let list = rows(world)?;
        let brick = timeline_brick(world)?;
        world.wait_for_with(
            move |w| reply_end_in_view(w, brick, list),
            move |w| format!("the reply's end in view; {}", describe_list(w, list)),
        )
    });
    steps.step("the view follows new output again", |world, _, _| {
        let list = rows(world)?;
        expect!(
            flag(world, list, "following"),
            "the view is not following; {}",
            describe_list(world, list)
        );
        let before = real(world, list, "contentHeight");
        grow(world)?;
        world.wait_for_with(
            move |w| real(w, list, "contentHeight") > before && at_end(w, list),
            move |w| format!("the view to follow new output; {}", describe_list(w, list)),
        )
    });
}
