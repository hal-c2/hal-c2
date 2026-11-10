//! The queue of follow-ups on the TurnRequests card: its rows' controls,
//! their attachments, edits and saves of a queued message, and what happens
//! to an edit when its thread goes (desktop-qt's TurnSteps.cpp).

use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use hal_c2_shell::store;
use ljos::prelude::{ObjectId, Value as QmlValue};
use serde_json::{Value, json};

use super::{
    commands_of, finish_turn, last_command, listed, open_draft, question, queue_message,
    requests_brick, submit, thread_b, thread_key, toasts, turn, type_into,
};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::{press_in_composer, type_in_composer};
use crate::steps::keybinding::press_key;
use crate::steps::stream::{self, FakeStreams, THREAD};
use crate::world::World;
use crate::{expect, fail};

const NO_LONGER_QUEUED: &str = "Queued message is no longer queued";

fn composer(world: &World) -> Json {
    world.state("composer")
}

fn editing(world: &World) -> bool {
    !composer(world)["editingQueuedRunId"].is_null()
}

/// The row's `part` (queueText, queueEdit, …) of the queued `typed`, once
/// it shows.
fn row_part(world: &mut World, part: &str, typed: &str) -> Outcome<ObjectId> {
    let brick = requests_brick(world)?;
    let name = format!("{part}-run-queued-{typed}");
    let wanted = name.clone();
    world.wait_for_with(
        move |w| matches!(brick.find(w, &wanted), Ok(Some(item)) if brick.flag(w, item, "visible")),
        move |w| format!("{name} on the queue; the turn is {}", show(&turn(w))),
    )?;
    brick.item(world, &format!("{part}-run-queued-{typed}"))
}

fn enabled(world: &mut World, part: &str, typed: &str) -> Outcome<bool> {
    let brick = requests_brick(world)?;
    let item = row_part(world, part, typed)?;
    Ok(brick.flag(world, item, "enabled"))
}

/// Which of the row's Send now, Edit and Remove can be used, without
/// waiting for them.
fn usable(world: &World, typed: &str) -> Vec<&'static str> {
    let Some(brick) = world.peek_part::<crate::brick::Shown>().and_then(|s| s.0) else {
        return Vec::new();
    };
    ["queueSendNow", "queueEdit", "queueRemove"]
        .into_iter()
        .filter(|part| {
            matches!(brick.find(world, &format!("{part}-run-queued-{typed}")),
                     Ok(Some(item)) if brick.flag(world, item, "visible") && brick.flag(world, item, "enabled"))
        })
        .collect()
}

/// The visible named items at or under `item` that `keep` takes.
fn named_under(
    world: &World,
    brick: &crate::brick::Brick,
    item: ObjectId,
    keep: &dyn Fn(&World, ObjectId, &str) -> bool,
    found: &mut Vec<String>,
) {
    if !brick.flag(world, item, "visible") {
        return;
    }
    let name = brick.text_of(world, item, "objectName");
    if !name.is_empty() && keep(world, item, &name) {
        found.push(name);
    }
    if let QmlValue::List(children) = brick.read(world, item, "children") {
        for child in children.iter() {
            if let QmlValue::Object(child) = child {
                named_under(world, brick, *child, keep, found);
            }
        }
    }
}

/// A name that offers to move a row: Remove is not a move.
fn moves(name: &str) -> bool {
    let lower = name.to_lowercase();
    let moved = lower
        .match_indices("move")
        .any(|(at, _)| !lower[..at].ends_with("re"));
    moved
        || ["handle", "drag", "reorder", "position"]
            .iter()
            .any(|word| lower.contains(word))
}

fn queued_and_held(world: &mut World, texts: &[String]) -> Outcome {
    for typed in texts {
        queue_message(world, typed)?;
    }
    for typed in texts {
        stream::set(
            world,
            "run",
            &format!("run-queued-{typed}"),
            json!({"queueHeld": true}),
        )?;
    }
    finish_turn(world)
}

fn attach(world: &mut World, typed: &str, attachment: Value) -> Outcome {
    queue_message(world, typed)?;
    stream::set(
        world,
        "message",
        &format!("message-{typed}"),
        json!({"attachments": [attachment]}),
    )
}

/// A follow-up that quotes the agent: its text holds the quote's link.
fn quoting(quote: &str) -> String {
    let mut encoded = String::new();
    for byte in quote.bytes() {
        match byte {
            b' ' => encoded.push('+'),
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                encoded.push(byte as char)
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    format!(
        "see [Assistant quote](hal-c2-citation://v1/env-a/thread-1/msg-1?text={encoded}&start=0&end={}&prefix=&suffix=)",
        quote.chars().count()
    )
}

fn pending_entry(world: &World) -> Json {
    listed(world, "queue")
        .into_iter()
        .find(|entry| entry["pending"] == json!(true))
        .unwrap_or(Json::Null)
}

fn edit_queued_message(world: &mut World, typed: &str) -> Outcome {
    queue_message(world, typed)?;
    world.dispatch("composer.queue.edit", json!({}))?;
    let run = format!("run-queued-{typed}");
    world.wait_for_with(
        move |w| text(&composer(w)["editingQueuedRunId"]) == run,
        |w| format!("the edit to open; the composer is {}", show(&composer(w))),
    )
}

fn edit_count(world: &mut World) -> Outcome<usize> {
    Ok(commands_of(world, "queued-run.edit")?.len())
}

fn look(world: &mut World, key: &str) -> Outcome {
    stream::look(world, key, true)
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("the user presses (\\S+) with {Q} typed during a turn"),
        |world, c, _| {
            type_in_composer(world, &c[1])?;
            expect!(
                press_in_composer(world, &c[0])?,
                "the composer did not take {}",
                c[0]
            );
            let typed = c[1].clone();
            world.wait_for_with(
                move |w| {
                    w.mc.commands
                        .iter()
                        .rev()
                        .find(|command| text(&command["type"]) == "message.dispatch")
                        .is_some_and(|command| text(&command["text"]) == typed)
                },
                |w| format!("a send; the MC has {}", w.describe_commands()),
            )
        },
    );
    steps.step("the edit has ended", |world, _, _| {
        world.wait_for_with(
            |w| !editing(w),
            |w| format!("the composer is {}", show(&composer(w))),
        )
    });
    steps.step("no message about the edit is shown", |world, _, _| {
        world.sync()?;
        for toast in toasts(world) {
            expect!(
                text(&toast["title"]) != NO_LONGER_QUEUED,
                "the toast is {}",
                show(&toast)
            );
        }
        Ok(())
    });
    steps.step(
        &format!("the MC is asked to change the queued run of {Q} to {Q} without attachments"),
        |world, c, _| {
            let command = last_command(world, "queued-run.edit")?;
            expect!(
                text(&command["runId"]) == format!("run-queued-{}", c[0])
                    && text(&command["text"]) == c[1]
                    && command["attachments"]
                        .as_array()
                        .is_some_and(|list| list.is_empty()),
                "the MC was told {}",
                show(&command)
            );
            Ok(())
        },
    );

    // A queued message's attachments, on its row in the queue card.
    steps.step(
        &format!("{Q} is queued with the file {Q}"),
        |world, c, _| {
            attach(
                world,
                &c[0],
                json!({"type": "file", "id": format!("file-{}", c[1]), "name": c[1],
                   "mimeType": "text/markdown", "sizeBytes": 12}),
            )
        },
    );
    steps.step(&format!("the queue shows {Q} on {Q}"), |world, c, _| {
        let brick = requests_brick(world)?;
        let (file, typed) = (c[0].clone(), c[1].clone());
        let said = (c[0].clone(), c[1].clone());
        world.wait_for_with(
            move |w| {
                brick.shows(w, &file).unwrap_or(false) && brick.shows(w, &typed).unwrap_or(false)
            },
            move |w| {
                format!(
                    "\"{}\" on \"{}\"; the turn is {}",
                    said.0,
                    said.1,
                    show(&turn(w))
                )
            },
        )?;
        let item = brick.item(world, &format!("queueAttachment-file-{}", c[0]))?;
        expect!(
            brick.flag(world, item, "visible"),
            "the attachment is hidden"
        );
        Ok(())
    });
    steps.step(
        &format!("the user opens {Q} from the queue"),
        |world, c, _| {
            let brick = requests_brick(world)?;
            brick.click(world, &format!("queueAttachment-file-{}", c[0]))?;
            world.sync()
        },
    );
    steps.step(
        &format!("the attachment viewer shows {Q}"),
        |world, c, _| {
            let name = c[0].clone();
            world.wait_for_with(
                move |w| text(&w.state("attachmentViewer")["name"]) == name,
                |w| format!("the viewer shows {}", show(&w.state("attachmentViewer"))),
            )
        },
    );

    // A queued row's controls: Send now, then Edit and Remove.
    steps.step(
        &format!("{Q}, {Q} and {Q} are queued and held, and the turn is no longer running"),
        |world, c, _| queued_and_held(world, &c[..3]),
    );
    steps.step(
        &format!("{Q} and {Q} are queued and held, and the turn is no longer running"),
        |world, c, _| queued_and_held(world, &c[..2]),
    );
    steps.step(
        &format!("the user looks at {Q} in the queue"),
        |world, c, _| row_part(world, "queueText", &c[0]).map(|_| ()),
    );
    steps.step(
        &format!("the user is offered to send {Q} now, to edit it and to remove it"),
        |world, c, _| {
            let mut offered = Vec::new();
            for part in ["queueSendNow", "queueEdit", "queueRemove"] {
                if enabled(world, part, &c[0])? {
                    offered.push(part);
                }
            }
            let brick = requests_brick(world)?;
            let send = row_part(world, "queueSendNow", &c[0])?;
            let edit = row_part(world, "queueEdit", &c[0])?;
            expect!(
                offered.len() == 3 && brick.text_of(world, send, "text") == "Send now",
                "the row offers {}",
                offered.join(", ")
            );
            // Send now comes first, as upstream's row has it.
            let x = |item| {
                brick
                    .text_of(world, item, "x")
                    .parse::<f64>()
                    .unwrap_or(0.0)
            };
            expect!(x(send) < x(edit), "Send now is not first");
            Ok(())
        },
    );
    steps.step(
        &format!("the user is not offered to move {Q} in the queue"),
        |world, c, _| {
            let brick = requests_brick(world)?;
            let row = brick.item(world, &format!("queueRow-run-queued-{}", c[0]))?;
            let mut found = Vec::new();
            named_under(world, &brick, row, &|_, _, name| moves(name), &mut found);
            expect!(found.is_empty(), "the row offers {}", found.join(", "));
            Ok(())
        },
    );
    steps.step(
        &format!("the user is offered to send {Q} now instead of steering it"),
        |world, c, _| {
            let brick = requests_brick(world)?;
            let send = row_part(world, "queueSendNow", &c[0])?;
            expect!(
                brick.flag(world, send, "enabled")
                    && brick.text_of(world, send, "text") == "Send now",
                "Send now cannot be used"
            );
            brick.click(world, &format!("queueSendNow-run-queued-{}", c[0]))?;
            world.sync()?;
            let command = last_command(world, "queued-run.start")?;
            expect!(
                text(&command["runId"]) == format!("run-queued-{}", c[0])
                    && commands_of(world, "queued-message.promote-to-steer")?.is_empty(),
                "the MC has {}",
                world.describe_commands()
            );
            Ok(())
        },
    );

    // A queued follow-up that quotes the agent.
    steps.step(
        &format!("the user queued a message quoting {Q} from the agent's reply"),
        |world, c, _| {
            let position = {
                let fake = world.mc.part::<FakeStreams>();
                fake.ordinal += 1;
                fake.ordinal
            };
            stream::set(
                world,
                "message",
                "message-quote",
                json!({"id": "message-quote", "role": "user", "text": quoting(&c[0])}),
            )?;
            stream::set(
                world,
                "run",
                "run-queued-quote",
                json!({"id": "run-queued-quote", "ordinal": position, "status": "queued",
                       "queuePosition": position, "userMessageId": "message-quote"}),
            )
        },
    );
    steps.step(
        &format!("the queued message reads {Q}, not a link"),
        |world, c, _| {
            let brick = requests_brick(world)?;
            let item = row_part(world, "queueText", "quote")?;
            let shown = brick.text_of(world, item, "text");
            expect!(
                shown == format!("see {}", c[0]),
                "the row reads \"{shown}\""
            );
            Ok(())
        },
    );
    steps.step(
        "editing it gives back the message with its quote",
        |world, _, _| {
            world.dispatch("composer.queue.edit", json!({"runId": "run-queued-quote"}))?;
            let expected = quoting("the cart total is wrong");
            world.wait_for_with(
                move |w| open_draft(w) == expected,
                |w| format!("the composer reads \"{}\"", open_draft(w)),
            )
        },
    );
    steps.step(
        "the user presses the shortcut that steers the queued message",
        |world, _, _| {
            press_key(world, "mod+shift+enter")?;
            world.sync()
        },
    );
    steps.step(&format!("a turn starts with {Q}"), |world, c, _| {
        let command = last_command(world, "queued-run.start")?;
        expect!(
            text(&command["runId"]) == format!("run-queued-{}", c[0])
                && commands_of(world, "queued-message.promote-to-steer")?.is_empty(),
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });
    steps.step(
        &format!("the user removes {Q} and the MC has not answered yet"),
        |world, c, _| {
            world.mc.hold("answers");
            row_part(world, "queueRemove", &c[0])?;
            let brick = requests_brick(world)?;
            brick.click(world, &format!("queueRemove-run-queued-{}", c[0]))?;
            world.sync()?;
            let cancels = commands_of(world, "queued-run.cancel")?.len();
            expect!(cancels == 1, "the MC has {}", world.describe_commands());
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} cannot be edited, steered or removed until it has"),
        |world, c, _| {
            let typed = c[0].clone();
            let shown = c[0].clone();
            world.wait_for_with(
                move |w| usable(w, &typed).is_empty(),
                move |w| format!("the row still offers {}", usable(w, &shown).join(", ")),
            )?;
            // Nor by its actions or keys.
            let run = json!({"runId": format!("run-queued-{}", c[0])});
            world.dispatch("composer.queue.steer", run.clone())?;
            world.dispatch("composer.queue.remove", run.clone())?;
            world.dispatch("composer.queue.edit", run)?;
            world.sync()?;
            expect!(
                commands_of(world, "queued-run.cancel")?.len() == 1
                    && commands_of(world, "queued-message.promote-to-steer")?.is_empty()
                    && !editing(world),
                "the MC has {}",
                world.describe_commands()
            );
            world.mc.answer_held();
            world.sync()?;
            let typed = c[0].clone();
            let shown = c[0].clone();
            world.wait_for_with(
                move |w| usable(w, &typed).len() == 3,
                move |w| format!("the row offers only {}", usable(w, &shown).join(", ")),
            )
        },
    );

    // A follow-up on its way to the MC.
    steps.step(
        "the MC has not yet confirmed a message the user queued",
        |world, _, _| {
            let engine = world.engine().clone();
            Settings::of(&engine).write_device(&engine, "followUpBehavior", json!("queue"));
            world.mc.hold("answers");
            submit(world, "tweak")?;
            world.sync()
        },
    );
    steps.step(
        "the message is listed in the queue as being saved",
        |world, _, _| {
            world.wait_for_with(
                |w| text(&pending_entry(w)["text"]) == "tweak",
                |w| {
                    format!(
                        "a queued message being saved; the turn is {}",
                        show(&turn(w))
                    )
                },
            )?;
            let brick = requests_brick(world)?;
            let id = text(&pending_entry(world)["messageId"]).to_owned();
            let saving = format!("queueSaving-{id}");
            world.wait_for("the row's saving mark", move |w| {
            matches!(brick.find(w, &saving), Ok(Some(item)) if brick.flag(w, item, "visible"))
        })?;
            let item = brick.item(world, &format!("queueText-{id}"))?;
            let shown = brick.text_of(world, item, "text");
            expect!(shown == "tweak", "the row reads \"{shown}\"");
            Ok(())
        },
    );
    steps.step(
        "it cannot be edited, reordered, steered or removed until the MC confirms it",
        |world, _, _| {
            let brick = requests_brick(world)?;
            let id = text(&pending_entry(world)["messageId"]).to_owned();
            let row = brick.item(world, &format!("queueRow-{id}"))?;
            let mut offered = Vec::new();
            let checkable = |w: &World, item: ObjectId, _: &str| {
                !matches!(
                    brick.read(w, item, "checkable"),
                    QmlValue::Undefined | QmlValue::Null
                )
            };
            named_under(world, &brick, row, &checkable, &mut offered);
            expect!(
                offered.is_empty(),
                "the row being saved offers {}",
                offered.join(", ")
            );
            // The edit-latest key passes it over: it has no run to edit yet.
            world.dispatch("composer.queue.edit", json!({}))?;
            world.sync()?;
            expect!(!editing(world), "an edit opened");
            // The MC has it: the message and its queued run arrive, and the
            // row is a queued one.
            world.mc.answer_held();
            queue_message(world, "tweak")?;
            world.wait_for_with(
                |w| pending_entry(w).is_null(),
                |w| format!("the row to be confirmed; the turn is {}", show(&turn(w))),
            )
        },
    );

    // A queued message while a question is open.
    steps.step("the agent has asked the user a question", |world, _, _| {
        ask_database(world)
    });
    steps.step(
        &format!("editing {Q} is unavailable, saying {Q}"),
        |world, c, _| {
            let brick = requests_brick(world)?;
            let edit = row_part(world, "queueEdit", &c[0])?;
            world.wait_for("Edit to be unavailable", move |w| {
                !brick.flag(w, edit, "enabled")
            })?;
            let tip = brick.text_of(world, edit, "toolTip");
            expect!(
                tip == c[1] && text(&turn(world)["queueEditBlocked"]) == c[1],
                "Edit says \"{tip}\""
            );
            world.dispatch(
                "composer.queue.edit",
                json!({"runId": format!("run-queued-{}", c[0])}),
            )?;
            world.sync()?;
            expect!(!editing(world), "an edit opened");
            Ok(())
        },
    );
    steps.step("the edit-latest shortcut does nothing", |world, _, _| {
        let before = open_draft(world);
        world.dispatch("composer.queue.edit", json!({}))?;
        world.sync()?;
        expect!(
            !editing(world) && open_draft(world) == before,
            "the composer is {}",
            show(&composer(world))
        );
        Ok(())
    });

    // The row of the message being edited.
    steps.step(&format!("{Q} is queued with an image"), |world, c, _| {
        attach(
            world,
            &c[0],
            json!({"type": "image", "id": format!("image-{}", c[0]), "name": "shot.png",
                   "mimeType": "image/png", "sizeBytes": 12}),
        )
    });
    steps.step(
        "the user starts editing it in the composer",
        |world, _, _| {
            let Some(last) = listed(world, "queue").into_iter().last() else {
                fail!("nothing is queued; the turn is {}", show(&turn(world)));
            };
            let name = format!("queueEdit-{}", text(&last["runId"]));
            let brick = requests_brick(world)?;
            let wanted = name.clone();
            world.wait_for("the row's Edit", move |w| {
            matches!(brick.find(w, &wanted), Ok(Some(item)) if brick.flag(w, item, "visible"))
        })?;
            brick.click(world, &name)?;
            world.sync()
        },
    );
    steps.step(
        &format!("the queue marks {Q} as being edited and offers to cancel the edit"),
        |world, c, _| {
            row_part(world, "queueEditCancel", &c[0])?;
            let brick = requests_brick(world)?;
            let row_text = brick.item(world, &format!("queueText-run-queued-{}", c[0]))?;
            expect!(
                matches!(brick.read(world, row_text, "font"), QmlValue::Font(font) if font.italic),
                "the row is not marked"
            );
            for part in ["queueSendNow", "queueEdit", "queueRemove"] {
                let found = brick.find(world, &format!("{part}-run-queued-{}", c[0]))?;
                expect!(
                    found.is_none_or(|item| !brick.flag(world, item, "visible")),
                    "the row being edited offers {part}"
                );
            }
            brick.click(world, &format!("queueEditCancel-run-queued-{}", c[0]))?;
            world.sync()?;
            world.wait_for("the edit to end", |w| !editing(w))
        },
    );

    // Saves of a queued edit, one at a time.
    steps.step(
        &format!("the user saved {Q} over it and the MC has not answered yet"),
        |world, c, _| {
            world.dispatch("composer.queue.edit", json!({}))?;
            world.sync()?;
            world.mc.hold("answers");
            submit(world, &c[0])?;
            world.sync()?;
            expect!(
                edit_count(world)? == 1,
                "the MC has {}",
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user edits it again and saves {Q}"),
        |world, c, _| {
            type_into(world, &c[0])?;
            submit(world, &c[0])?;
            world.sync()
        },
    );
    steps.step(
        &format!("{Q} is sent only after the MC answered the first save"),
        |world, c, _| {
            expect!(
                edit_count(world)? == 1,
                "the MC has {}",
                world.describe_commands()
            );
            world.mc.answer_held();
            world.wait_for_with(
                |w| {
                    w.mc.commands
                        .iter()
                        .filter(|command| text(&command["type"]) == "queued-run.edit")
                        .count()
                        == 2
                },
                |w| format!("the MC has {}", w.describe_commands()),
            )?;
            let second = last_command(world, "queued-run.edit")?;
            expect!(
                text(&second["text"]) == c[0],
                "the MC was told {}",
                show(&second)
            );
            Ok(())
        },
    );
    steps.step(&format!("the queued message ends as {Q}"), |world, c, _| {
        world.wait_for("the edit to end", |w| !editing(w))?;
        let saves = commands_of(world, "queued-run.edit")?;
        expect!(
            saves.len() == 2 && saves.last().is_some_and(|last| text(&last["text"]) == c[0]),
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });

    // The queue folds to its header.
    steps.step(
        &format!("the queue is headed {Q} with the count (\\d+)"),
        |world, c, _| {
            let brick = requests_brick(world)?;
            let (head, count) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                move |w| {
                    brick.shows(w, &head).unwrap_or(false)
                        && matches!(brick.find(w, "queueCount"),
                                    Ok(Some(item)) if brick.text_of(w, item, "text") == count)
                },
                |w| format!("the queue's header; the turn is {}", show(&turn(w))),
            )
        },
    );
    steps.step("the user folds the queue away", |world, _, _| {
        let brick = requests_brick(world)?;
        brick.click(world, "queueToggle")?;
        world.sync()
    });
    steps.step(
        &format!("{Q} and {Q} are hidden and the count is still shown"),
        |world, c, _| {
            let brick = requests_brick(world)?;
            let (a, b) = (c[0].clone(), c[1].clone());
            world.wait_for("the queued messages to be hidden", move |w| {
                !brick.shows(w, &a).unwrap_or(true) && !brick.shows(w, &b).unwrap_or(true)
            })?;
            let count = brick.item(world, "queueCount")?;
            expect!(
                brick.flag(world, count, "visible") && brick.text_of(world, count, "text") == "2",
                "the count is gone"
            );
            Ok(())
        },
    );

    // A queued edit belongs to its thread.
    steps.step(
        &format!(
            "the user is (?:still editing the queued message, reading|editing the queued) {Q}(?: again)?"
        ),
        |world, c, _| {
            // As a precondition the edit is opened.
            if !world.checking {
                return edit_queued_message(world, &c[0]);
            }
            let wanted = c[0].clone();
            world.wait_for_with(
                move |w| editing(w) && text(&composer(w)["text"]) == wanted,
                |w| format!("the edit; the composer is {}", show(&composer(w))),
            )
        },
    );
    steps.step(
        &format!("the user saved {Q} over the queued {Q} and the MC has not answered yet"),
        |world, c, _| {
            edit_queued_message(world, &c[1])?;
            world.mc.hold(&format!("answers:{THREAD}"));
            type_into(world, &c[0])?;
            submit(world, &c[0])?;
            world.sync()?;
            expect!(
                edit_count(world)? == 1,
                "the MC has {}",
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user edits the queued message again to {Q}"),
        |world, c, _| {
            type_into(world, &c[0])?;
            world.sync()
        },
    );
    steps.step("the first save finishes", |world, _, _| {
        world.mc.answer_held();
        world.sync()?;
        expect!(
            edit_count(world)? == 1,
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });
    steps.step(
        &format!("the user is editing the queued {Q} with a change"),
        |world, c, _| {
            edit_queued_message(world, &c[0])?;
            type_into(world, &format!("{} and the docs", c[0]))?;
            world.sync()
        },
    );
    steps.step("the user has gone to another thread", |world, _, _| {
        let other = thread_b(world)?;
        look(world, &other)
    });
    steps.step(
        "the changed edit waits in the thread's composer if it was empty, with a message naming the thread",
        |world, _, _| {
            let title = text(&world.mc.threads[THREAD]["title"]).to_owned();
            let named = title.clone();
            world.wait_for_with(
                move |w| {
                    toasts(w).iter().any(|toast| {
                        text(&toast["title"]) == NO_LONGER_QUEUED
                            && text(&toast["description"]).contains(&named)
                    })
                },
                move |w| {
                    format!(
                        "a toast naming \"{title}\"; the toasts are {}",
                        show(&Json::Array(toasts(w)))
                    )
                },
            )?;
            // Back in the thread, the change is its draft, no longer an edit.
            let key = thread_key(world);
            look(world, &key)?;
            let shown = composer(world);
            expect!(
                shown["editingQueuedRunId"].is_null()
                    && text(&shown["text"]) == "fix typo and the docs",
                "the composer is {}",
                show(&shown)
            );
            Ok(())
        },
    );
    steps.step(
        "the user is editing a queued message in thread A",
        |world, _, _| edit_queued_message(world, "fix typo"),
    );
    steps.step("thread A is deleted", |world, _, _| {
        world.mc.threads.remove(THREAD);
        world
            .mc
            .send_row(THREAD, &json!({"deletedAt": "2026-09-23T10:00:00Z"}));
        let key = thread_key(world);
        world.wait_for("thread A to go", move |w| {
            !store::with(w.engine(), |s| s.thread(&key).is_some())
        })
    });
    steps.step("the agent asks which database to use", |world, _, _| {
        ask_database(world)
    });
}

fn ask_database(world: &mut World) -> Outcome {
    question(
        world,
        "Which database?",
        &["Postgres".to_owned(), "SQLite".to_owned()],
        false,
        "live",
    )?;
    world.wait_for("the question", |w| !listed(w, "questions").is_empty())
}
