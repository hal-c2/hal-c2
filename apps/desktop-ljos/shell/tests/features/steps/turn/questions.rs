//! Answering from the composer's question card
//! (composer/question-answers.feature): one question of a request at a
//! time, picked, typed and stepped through as the user does (desktop-qt's
//! TurnSteps.cpp).

use ljos::item::{KeyEvent, key};
use ljos::prelude::ObjectId;
use serde_json::{Value, json};

use super::{
    QUESTION, commands_of, expect_question_shown, first, last_command, listed, question_shown_now,
    request, thread_key, turn,
};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::{
    composer_brick, composer_brick_shown, composer_part, editor, type_in_composer,
};
use crate::steps::stream::{self, FakeStreams};
use crate::world::World;
use crate::{expect, fail};

/// Several questions in one request, as Claude's AskUserQuestion asks
/// them: each with its id and two options.
fn asked(text: &str) -> Option<(&'static str, [&'static str; 2])> {
    match text {
        "Which database?" => Some(("database", ["Postgres", "SQLite"])),
        "Which cache?" => Some(("cache", ["Redis", "Memcached"])),
        "Which queue?" => Some(("queue", ["RabbitMQ", "SQS"])),
        _ => None,
    }
}

/// The questions `texts` in one request, in place of the one the agent
/// asked first.
fn ask_together(world: &mut World, texts: &[String]) -> Outcome {
    let request_id = text(&first(world, "questions")?["requestId"]).to_owned();
    stream::set(
        world,
        "runtime-request",
        &request_id,
        json!({"status": "resolved"}),
    )?;
    let mut questions = Vec::new();
    for asked_text in texts {
        let Some((id, labels)) = asked(asked_text) else {
            fail!("no question \"{asked_text}\" to ask");
        };
        questions.push(json!({
            "id": id, "header": id, "question": asked_text,
            "options": labels.map(|label| json!({"label": label, "description": ""})),
            "multiSelect": false, "allowCustomAnswer": true,
        }));
    }
    request(
        world,
        "user_input_request",
        json!({"questions": questions}),
        "live",
    )
    .map(drop)
}

/// Whether the composer's card asks `text`, one of the questions the steps
/// ask: false while no question waits, so `"…" is shown` can name a thread.
pub(super) fn question_shown(world: &mut World, text: &str) -> Outcome<bool> {
    let waiting = !super::listed(world, "questions").is_empty();
    if !composer_brick_shown(world) || !waiting || asked(text).is_none() {
        return Ok(false);
    }
    settle_question(world)?;
    super::expect_question_shown(world, text)?;
    Ok(true)
}

/// The question card above the composer on screen (TurnRequests.qml), once
/// no pick is still about to move it to the next question.
pub(super) fn settle_question(world: &mut World) -> Outcome {
    let brick = composer_brick(world)?;
    world.wait_for("the question card to stop moving on", move |w| {
        crate::steps::composer_brick::composer_part_now(w, "turnRequests")
            .is_some_and(|requests| !brick.flag(w, requests, "advancing"))
    })
}

fn part(world: &mut World, name: &str) -> Outcome<ObjectId> {
    match composer_part(world, name)? {
        Some(item) => Ok(item),
        None => fail!("the composer has no {name}"),
    }
}

fn option_picked(world: &mut World, label: &str) -> Outcome<bool> {
    let brick = composer_brick(world)?;
    Ok(composer_part(world, &format!("questionOption-{label}"))?
        .is_some_and(|option| brick.flag(world, option, "checked")))
}

pub(super) fn click_part(world: &mut World, name: &str) -> Outcome {
    let brick = composer_brick(world)?;
    let item = composer_part(world, name)?;
    let Some(item) =
        item.filter(|&i| brick.flag(world, i, "visible") && brick.flag(world, i, "enabled"))
    else {
        let state = item.map_or("none".to_owned(), |i| {
            format!(
                "visible {}, enabled {}",
                brick.flag(world, i, "visible"),
                brick.flag(world, i, "enabled")
            )
        });
        fail!("{name} cannot be clicked ({state})");
    };
    let (x, y) = brick.at(world, item, 0.5, 0.5)?;
    world.click_at(x, y)?;
    world.sync()
}

/// A key typed where the keyboard is.
fn type_key(world: &mut World, ch: char) -> Outcome {
    let event = KeyEvent::press(ch.to_ascii_uppercase() as i32).with_text(ch.to_string());
    world.key(&event)?;
    world.key(&KeyEvent::release(ch.to_ascii_uppercase() as i32).with_text(ch.to_string()))?;
    world.sync()
}

/// Takes the keyboard off the composer to the question card, as a click on
/// the card does: number keys pick only there.
fn keyboard_to_card(world: &mut World) -> Outcome {
    let (brick, input) = editor(world)?;
    brick.write(world, input, "focus", ljos::prelude::Value::Bool(false))?;
    let card = part(world, "questionCard")?;
    expect!(
        brick.flag(world, card, "visible"),
        "no question card is shown"
    );
    let _ = world.engine().invoke_by_name(card, "forceActiveFocus", &[]);
    world.sync()?;
    expect!(
        brick.flag(world, card, "activeFocus"),
        "the question card did not take the keyboard"
    );
    Ok(())
}

fn typed_answer(world: &mut World, id: &str, typed: &str) -> Outcome {
    let brick = composer_brick(world)?;
    let field = part(world, &format!("questionAnswer-{id}"))?;
    let (x, y) = brick.at(world, field, 0.5, 0.5)?;
    world.click_at(x, y)?;
    type_in_composer(world, typed)?;
    let read = brick.text_of(world, field, "text");
    expect!(read == typed, "the answer reads \"{read}\"");
    Ok(())
}

/// Each of `parts` is shown above the composer's editor.
fn above_editor(world: &mut World, parts: &[&str]) -> Outcome {
    let (brick, input) = editor(world)?;
    let (_, editor_top) = brick.at(world, input, 0.0, 0.0)?;
    for name in parts {
        let item = part(world, name)?;
        let (_, top) = brick.at(world, item, 0.0, 0.0)?;
        let (_, bottom) = brick.at(world, item, 0.0, 1.0)?;
        expect!(
            brick.flag(world, item, "visible") && top >= 0.0 && bottom <= editor_top,
            "{name} (visible: {}) spans {top}..{bottom}, the editor starts at {editor_top}",
            brick.flag(world, item, "visible")
        );
    }
    Ok(())
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "each question, its options and the answer button sit above the composer's editor as the user steps through them",
        |world, _, _| {
            composer_brick(world)?;
            world.wait_for("the second question to arrive", |w| {
                crate::steps::composer_brick::composer_part_now(w, "questionAnswer-direction")
                    .is_some()
            })?;
            above_editor(
                world,
                &[
                    "questionTitle",
                    "questionOption-Yes, start now (Recommended)",
                    "questionAnswer-lint",
                    "questionNext",
                    "questionSubmit",
                ],
            )?;
            click_part(world, "questionNext")?;
            above_editor(
                world,
                &[
                    "questionTitle",
                    "questionOption-Decide later",
                    "questionAnswer-direction",
                    "questionSubmit",
                ],
            )
        },
    );
    steps.step(
        &format!("the agent asked {Q} and {Q} in one request"),
        |world, c, _| ask_together(world, &c[0..2]),
    );
    steps.step(
        &format!("the agent asked {Q}, {Q} and {Q} in one request"),
        |world, c, _| ask_together(world, &c[0..3]),
    );
    steps.step(
        &format!("{Q} is shown with {Q} kept as the first answer"),
        |world, c, _| {
            expect_question_shown(world, &c[0])?;
            expect!(
                option_picked(world, &c[1])?,
                "\"{}\" is no longer picked",
                c[1]
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is still shown so {Q} can be picked too"),
        |world, c, _| {
            settle_question(world)?;
            expect_question_shown(world, &c[0])?;
            let brick = composer_brick(world)?;
            let option = composer_part(world, &format!("questionOption-{}", c[1]))?;
            let can = option.is_some_and(|o| {
                brick.flag(world, o, "visible") && brick.flag(world, o, "enabled")
            });
            expect!(
                can && !option_picked(world, &c[1])?,
                "\"{}\" cannot be picked",
                c[1]
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is still shown a moment later"),
        |world, c, _| {
            settle_question(world)?;
            expect_question_shown(world, &c[0])
        },
    );
    steps.step(
        &format!(
            "the user picks {Q} and at once (presses Next|goes back to a question already shown)"
        ),
        |world, c, _| {
            // The pick's move to the next question is still to come when
            // the user moves.
            click_part(world, &format!("questionOption-{}", c[0]))?;
            let brick = composer_brick(world)?;
            let requests = part(world, "turnRequests")?;
            expect!(
                brick.flag(world, requests, "advancing"),
                "the pick did not wait to move on"
            );
            click_part(world, "questionNext")?;
            if c[1] == "goes back to a question already shown" {
                click_part(world, "questionPrevious")?;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the question is marked {Q} and the user can go on to the next question"),
        |world, c, _| {
            let brick = composer_brick(world)?;
            let wanted = c[0].clone();
            world.wait_for_with(
                {
                    let wanted = wanted.clone();
                    move |w| {
                        crate::steps::composer_brick::composer_part_now(w, "questionPosition")
                            .is_some_and(|p| brick.text_of(w, p, "text") == wanted)
                    }
                },
                move |_| format!("the question to be marked {wanted}"),
            )?;
            click_part(world, "questionNext")?;
            expect_question_shown(world, "Which cache?")
        },
    );
    steps.step("the user answers both questions", |world, _, _| {
        click_part(world, "questionPrevious")?;
        expect_question_shown(world, "Which database?")?;
        click_part(world, "questionOption-Postgres")?;
        // Typed, as a pick on the last question would send the answers at
        // once.
        expect_question_shown(world, "Which cache?")?;
        typed_answer(world, "cache", "Redis")
    });
    steps.step(
        "the user can go back to the previous question to change its answer",
        |world, _, _| {
            click_part(world, "questionPrevious")?;
            expect_question_shown(world, "Which database?")?;
            click_part(world, "questionOption-SQLite")?;
            expect!(
                option_picked(world, "SQLite")? && !option_picked(world, "Postgres")?,
                "the answer did not change"
            );
            Ok(())
        },
    );
    steps.step(
        "submitting sends both answers to the agent together",
        |world, _, _| {
            settle_question(world)?;
            click_part(world, "questionSubmit")?;
            let sent = commands_of(world, "runtime-request.respond")?;
            let answers = sent
                .last()
                .map(|s| s["answers"].clone())
                .unwrap_or(Value::Null);
            expect!(
                sent.len() == 1
                    && answers["database"] == json!("SQLite")
                    && answers["cache"] == json!("Redis"),
                "the MC has {}",
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user types {Q} as the answer to {Q}"),
        |world, c, _| {
            settle_question(world)?;
            expect_question_shown(world, &c[1])?;
            let Some((id, _)) = asked(&c[1]) else {
                fail!("no question \"{}\" was asked", c[1]);
            };
            typed_answer(world, id, &c[0])
        },
    );
    steps.step(
        &format!("the user went on to {Q} without answering {Q}"),
        |world, c, _| {
            expect_question_shown(world, &c[1])?;
            click_part(world, "questionNext")?;
            expect_question_shown(world, &c[0])
        },
    );
    steps.step(&format!("the answer button reads {Q}"), |world, c, _| {
        let brick = composer_brick(world)?;
        let button = part(world, "questionSubmit")?;
        let read = brick.text_of(world, button, "text");
        expect!(
            read == c[0] && brick.flag(world, button, "visible"),
            "the answer button reads \"{read}\""
        );
        Ok(())
    });
    steps.step("the user presses Enter in the answer", |world, _, _| {
        let event = KeyEvent::press(key::RETURN).with_text("\r");
        world.key(&event)?;
        world.key(&KeyEvent::release(key::RETURN).with_text("\r"))?;
        world.sync()
    });
    steps.step("the user presses the answer button", |world, _, _| {
        click_part(world, "questionSubmit")
    });
    steps.step("no answer has been sent", |world, _, _| {
        settle_question(world)?;
        expect!(
            commands_of(world, "runtime-request.respond")?.is_empty(),
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });
    steps.step(
        &format!("the user answered {Q} and left the thread"),
        |world, c, _| {
            expect_question_shown(world, &c[0])?;
            click_part(world, "questionOption-Postgres")?;
            expect_question_shown(world, "Which cache?")?;
            // Back on the first question, so coming back is what moves on.
            click_part(world, "questionPrevious")?;
            expect_question_shown(world, &c[0])?;
            world.start_new_thread(json!({}))?;
            world.wait_for("the question to go with the thread", |w| {
                question_shown_now(w).is_empty()
            })
        },
    );
    steps.step("the user opens the thread again", |world, _, _| {
        let key = thread_key(world);
        stream::look(world, &key, true)
    });
    steps.step("the user is not typing in the composer", |world, _, _| {
        composer_brick(world)?;
        settle_question(world)?;
        keyboard_to_card(world)
    });
    steps.step(&format!("{Q} is picked"), |world, c, _| {
        expect!(option_picked(world, &c[0])?, "\"{}\" is not picked", c[0]);
        Ok(())
    });
    steps.step(
        "the user is typing an answer and presses (\\d)",
        |world, c, _| {
            let brick = composer_brick(world)?;
            let field = composer_part(world, &format!("questionAnswer-{QUESTION}"))?;
            let Some(field) = field.filter(|&f| brick.flag(world, f, "visible")) else {
                fail!("the question takes no typed answer");
            };
            let (x, y) = brick.at(world, field, 0.5, 0.5)?;
            world.click_at(x, y)?;
            expect!(
                brick.flag(world, field, "activeFocus"),
                "the answer field did not take the keyboard"
            );
            type_key(world, c[0].chars().next().unwrap_or('1'))
        },
    );
    steps.step(
        &format!("{Q} is typed into the answer and no option is picked"),
        |world, c, _| {
            let brick = composer_brick(world)?;
            let field = part(world, &format!("questionAnswer-{QUESTION}"))?;
            let read = brick.text_of(world, field, "text");
            expect!(read == c[0], "the answer reads \"{read}\"");
            for label in ["Postgres", "SQLite"] {
                expect!(!option_picked(world, label)?, "\"{label}\" is picked");
            }
            Ok(())
        },
    );
    steps.step(
        "the user hides the question and its options",
        |world, _, _| {
            composer_brick(world)?;
            settle_question(world)?;
            click_part(world, "questionFold")
        },
    );
    steps.step(
        "only the question's title stays above the composer",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let title = composer_part(world, "questionTitle")?;
            expect!(
                title.is_some_and(|t| brick.flag(world, t, "visible")
                    && brick.text_of(world, t, "text") == "Which database?"),
                "the question's title is gone"
            );
            for name in [
                "questionOption-Postgres",
                "questionAnswer-database",
                "questionSubmit",
            ] {
                let item = part(world, name)?;
                expect!(!brick.flag(world, item, "visible"), "{name} is still shown");
            }
            Ok(())
        },
    );
    steps.step(
        "number keys pick nothing while it is hidden",
        |world, _, _| {
            keyboard_to_card(world)?;
            type_key(world, '1')?;
            expect!(!option_picked(world, "Postgres")?, "1 picked \"Postgres\"");
            Ok(())
        },
    );
    steps.step("the user shows the question again", |world, _, _| {
        click_part(world, "questionFold")
    });
    steps.step(
        "the options and what the user already picked are shown",
        |world, _, _| {
            let brick = composer_brick(world)?;
            for name in [
                "questionOption-Postgres",
                "questionOption-SQLite",
                "questionAnswer-database",
                "questionSubmit",
            ] {
                let item = part(world, name)?;
                expect!(brick.flag(world, item, "visible"), "{name} is not shown");
            }
            expect!(
                !option_picked(world, "Postgres")? && !option_picked(world, "SQLite")?,
                "an option was picked while hidden"
            );
            Ok(())
        },
    );
    steps.step(
        "the environment refuses to dismiss the question",
        |world, _, _| {
            world.mc.refusals.insert(
                "thread.user-input.dismiss".into(),
                "The provider is still writing the question".into(),
            );
            Ok(())
        },
    );
    steps.step(
        "the question is still waiting for an answer",
        |world, _, _| {
            world.wait_for("the dismissal to settle", |w| {
                listed(w, "questions")
                    .first()
                    .is_some_and(|q| q["responding"] != json!(true))
            })?;
            let shown = first(world, "questions")?;
            expect!(
                shown["canRespond"] == json!(true),
                "the question is {}",
                show(&shown)
            );
            Ok(())
        },
    );
    steps.step(
        "the agent asked the question while its turn is still running",
        |world, _, _| {
            expect!(
                turn(world)["running"] == json!(true) && !listed(world, "questions").is_empty(),
                "the turn is {}",
                show(&turn(world))
            );
            Ok(())
        },
    );
    steps.step(
        "the user can stop the turn as well as answer the question",
        |world, _, _| {
            let brick = composer_brick(world)?;
            settle_question(world)?;
            let option = composer_part(world, "questionOption-Postgres")?;
            expect!(
                option.is_some_and(
                    |o| brick.flag(world, o, "visible") && brick.flag(world, o, "enabled")
                ),
                "the question cannot be answered"
            );
            let action = composer_part(world, "primaryAction")?;
            expect!(
                action.is_some_and(
                    |a| brick.flag(world, a, "visible") && brick.flag(world, a, "stopMode")
                ),
                "the composer offers no Stop"
            );
            click_part(world, "primaryAction")?;
            let command = last_command(world, "run.interrupt")?;
            let run = world.mc.part::<FakeStreams>().run.clone();
            // The user's Stop also stops what the thread delegated
            // (delegation.feature).
            expect!(
                text(&command["runId"]) == run && command["stopDelegated"] == json!(true),
                "the MC was told {}",
                show(&command)
            );
            Ok(())
        },
    );
}
