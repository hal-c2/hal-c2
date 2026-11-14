//! The effort stepped from the keyboard without opening its picker
//! (composer.increaseEffort / decreaseEffort)
//! (features/composer/model-and-mode.feature). desktop-qt's
//! ComposerEffortStepSteps.cpp.

use hal_c2_shell::controllers::keybindings::{Focus, Keymap};
use hal_c2_shell::json::Json;
use hal_c2_shell::keybindings as keymap;
use ljos::prelude::Value as QmlValue;
use serde_json::{Value, json};

use crate::harness::{Outcome, Steps, show, text};
use crate::steps::composer_brick::{composer_part, editor, settle_composer, type_in_composer};
use crate::steps::keybinding::bind_key;
use crate::steps::settings::{fake_config, publish_providers};
use crate::steps::stream;
use crate::steps::turn::{queue_turn_message, start_working_turn};
use crate::world::World;
use crate::{expect, fail};

// The keys the scenario gives the two commands, which have none by default.
const UP: &str = "mod+alt+k";
const DOWN: &str = "mod+alt+j";

#[derive(Default)]
struct Stepping {
    bound: bool,
    // The step key is held down after one step: the next is a repeat.
    held: bool,
    effort_before: String,
    text: String,
    cursor: i64,
}

fn composer(world: &World) -> Json {
    world.state("composer")
}

/// The composer's effort: its first choice option.
fn effort(world: &World) -> Json {
    composer(world)["options"]
        .as_array()
        .and_then(|options| {
            options
                .iter()
                .find(|o| o["type"] == json!("select"))
                .cloned()
        })
        .unwrap_or(Json::Null)
}

fn effort_value(world: &World) -> String {
    text(&effort(world)["value"]).to_owned()
}

fn effort_choices(world: &World) -> Vec<String> {
    effort(world)["choices"]
        .as_array()
        .map(|choices| choices.iter().map(|c| text(&c["id"]).to_owned()).collect())
        .unwrap_or_default()
}

/// A press of `key` with the keyboard in the composer, as the window's
/// shortcut takes it: only when the key is the shell's there, and a held key
/// again only when the shortcut repeats.
fn press_step(world: &mut World, key: &str, repeat: bool) -> Outcome {
    let keys = Keymap::of(world.engine());
    let Some(shortcut) = keymap::parse_shortcut(key) else {
        fail!("{key} is not a key");
    };
    let sequence = keymap::sequence(&shortcut, keys.mac());
    let Some(found) = keys
        .shortcuts()
        .into_iter()
        .find(|s| text(&s["sequence"]) == sequence)
    else {
        fail!("no window shortcut for {key}");
    };
    expect!(
        found["composer"] == json!(true),
        "{key} is not the shell's while the composer has the keyboard"
    );
    if repeat && found["autoRepeat"] != json!(true) {
        return Ok(());
    }
    let focus = Focus {
        composer: true,
        editable: true,
        ..Focus::default()
    };
    keys.press(world.engine(), &sequence, focus);
    world.sync()
}

fn bind_steps(world: &mut World) -> Outcome {
    if world.mc.part::<Stepping>().bound {
        return Ok(());
    }
    world.mc.part::<Stepping>().bound = true;
    bind_key(world, UP, "composer.increaseEffort")?;
    bind_key(world, DOWN, "composer.decreaseEffort")?;
    world.sync()
}

fn set_effort(world: &mut World, value: &str) -> Outcome {
    let id = effort(world)["id"].clone();
    world.dispatch("composer.option.set", json!({"id": id, "value": value}))?;
    let value = value.to_owned();
    world.wait_for_with(
        {
            let value = value.clone();
            move |w| effort_value(w) == value
        },
        move |w| format!("the effort to be {value}; it is {}", show(&effort(w))),
    )
}

fn providers(world: &mut World) -> Vec<Value> {
    fake_config(&mut world.mc)
        .config
        .get("providers")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

/// A pending request of the running turn, as turn.rs makes them.
fn request(world: &mut World, kind: &str, mut item: Value) -> Outcome {
    let id = format!(
        "request-{}",
        world.mc.part::<stream::FakeStreams>().ordinal + 1
    );
    stream::set(
        world,
        "runtime-request",
        &id,
        json!({"id": id, "status": "pending", "responseCapability": {"type": "live"}}),
    )?;
    item["requestId"] = json!(id);
    item["status"] = json!("waiting");
    stream::add_item(world, kind, item)?;
    Ok(())
}

fn await_listed(world: &mut World, field: &'static str) -> Outcome {
    world.wait_for(&format!("the {field} to reach the composer"), move |w| {
        w.state("turn")[field]
            .as_array()
            .is_some_and(|list| !list.is_empty())
    })
}

fn caret(world: &mut World) -> Outcome<(String, i64, bool)> {
    let (brick, editor) = editor(world)?;
    let cursor = brick
        .text_of(world, editor, "cursorPosition")
        .parse::<f64>()
        .unwrap_or(-1.0);
    Ok((
        brick.text_of(world, editor, "text"),
        cursor as i64,
        brick.flag(world, editor, "activeFocus"),
    ))
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the thread runs on a model whose efforts are low, medium and high",
        |world, _, _| {
            world.wait_for_with(
                |w| effort_choices(w) == ["low", "medium", "high"],
                |w| {
                    format!(
                        "the model's efforts to be low, medium and high; they are {}",
                        show(&effort(w))
                    )
                },
            )
        },
    );
    steps.step(
        "the effort is (low|medium|high) and the user is typing a draft",
        |world, c, _| {
            set_effort(world, &c[0])?;
            type_in_composer(world, "fix the tax line")?;
            settle_composer(world)?;
            // The caret mid-word, where the user stopped.
            let (brick, item) = editor(world)?;
            brick.write(world, item, "cursorPosition", QmlValue::from(7.0))?;
            let (text, cursor, _) = caret(world)?;
            let state = world.mc.part::<Stepping>();
            state.text = text;
            state.cursor = cursor;
            Ok(())
        },
    );
    steps.step("the user steps the effort (up|down)", |world, c, _| {
        bind_steps(world)?;
        let before = effort_value(world);
        let held = {
            let state = world.mc.part::<Stepping>();
            state.effort_before = before;
            state.held
        };
        press_step(world, if c[0] == "up" { UP } else { DOWN }, held)
    });
    steps.step("the effort is (low|medium|high)", |world, c, _| {
        let wanted = c[0].clone();
        world.wait_for_with(
            {
                let wanted = wanted.clone();
                move |w| effort_value(w) == wanted
            },
            move |w| format!("the effort to be {wanted}; it is {}", show(&effort(w))),
        )
    });
    steps.step("the effort is unchanged", |world, _, _| {
        world.sync()?;
        let before = world.mc.part::<Stepping>().effort_before.clone();
        let now = effort_value(world);
        expect!(now == before, "the effort went from {before} to {now}");
        Ok(())
    });
    steps.step(
        "the draft and where the user was typing are unchanged",
        |world, _, _| {
            let (text, cursor, focused) = caret(world)?;
            let state = world.mc.part::<Stepping>();
            expect!(
                text == state.text && cursor == state.cursor,
                "the draft reads \"{text}\" with the caret at {cursor}; it read \"{}\" at {}",
                state.text,
                state.cursor
            );
            expect!(focused, "the editor lost the keyboard");
            Ok(())
        },
    );
    steps.step("the effort picker stays closed", |world, _, _| {
        let brick = crate::steps::composer_brick::composer_brick(world)?;
        let Some(picker) = composer_part(world, "modelPicker")? else {
            fail!("the composer shows no model control");
        };
        let QmlValue::Object(popup) = brick.read(world, picker, "popup") else {
            fail!("the model control has no popup");
        };
        expect!(
            !brick.flag(world, popup, "visible"),
            "the model control opened"
        );
        Ok(())
    });
    // The prompt's own ultrathink.
    steps.step(
        &format!("the effort still reads {}", crate::harness::Q),
        |world, c, _| {
            world.sync()?;
            expect!(
                effort_value(world) == c[0].to_lowercase(),
                "the effort reads {}",
                show(&effort(world))
            );
            Ok(())
        },
    );

    // An effort the model does not list (OpenCode's "default").
    steps.step(
        "the provider reports an effort the model does not list",
        |world, _, _| {
            let mut list = providers(world);
            for entry in &mut list {
                if entry["instanceId"] != json!("codex") {
                    continue;
                }
                for model in entry["models"].as_array_mut().into_iter().flatten() {
                    let descriptors = model["capabilities"]["optionDescriptors"].as_array_mut();
                    for descriptor in descriptors.into_iter().flatten() {
                        if descriptor["type"] == json!("select") {
                            descriptor["currentValue"] = json!("default");
                        }
                    }
                }
            }
            publish_providers(&mut world.mc, list);
            world.wait_for_with(
                |w| effort_value(w) == "default",
                |w| {
                    format!(
                        "the composer to hold the provider's \"default\"; it shows {}",
                        show(&effort(w))
                    )
                },
            )
        },
    );
    steps.step(
        "the model's default effort is (low|medium|high)",
        |world, c, _| {
            // The model marks the level it starts from.
            let level = c[0].clone();
            let mut list = providers(world);
            for entry in &mut list {
                if entry["instanceId"] != json!("codex") {
                    continue;
                }
                for model in entry["models"].as_array_mut().into_iter().flatten() {
                    let descriptors = model["capabilities"]["optionDescriptors"].as_array_mut();
                    for descriptor in descriptors.into_iter().flatten() {
                        if descriptor["type"] != json!("select") {
                            continue;
                        }
                        for option in descriptor["options"].as_array_mut().into_iter().flatten() {
                            option["isDefault"] = json!(option["id"] == json!(level));
                        }
                    }
                }
            }
            publish_providers(&mut world.mc, list);
            let wanted = c[0].clone();
            world.wait_for_with(
                move |w| {
                    effort(w)["choices"].as_array().is_some_and(|choices| {
                        choices.iter().any(|choice| {
                            choice["isDefault"] == json!(true) && choice["id"] == json!(wanted)
                        })
                    })
                },
                |w| {
                    format!(
                        "the model to mark its default; it shows {}",
                        show(&effort(w))
                    )
                },
            )?;
            let effort = effort(world);
            let marked = effort["choices"].as_array().and_then(|choices| {
                choices
                    .iter()
                    .find(|c| c["isDefault"] == json!(true))
                    .cloned()
            });
            let Some(marked) = marked else {
                fail!("the model marks no default effort: {}", show(&effort));
            };
            expect!(
                text(&marked["id"]) == c[0],
                "the default effort is {}",
                text(&marked["id"])
            );
            Ok(())
        },
    );

    // Something else owns the composer.
    steps.step("an approval is waiting for the user", |world, _, _| {
        start_working_turn(world)?;
        request(
            world,
            "approval_request",
            json!({"requestKind": "command", "prompt": "Run the tests?"}),
        )?;
        await_listed(world, "approvals")
    });
    steps.step(
        "the agent's question is waiting for an answer",
        |world, _, _| {
            start_working_turn(world)?;
            let options: Vec<Value> = ["Postgres", "SQLite"]
                .iter()
                .map(|label| json!({"label": label, "description": ""}))
                .collect();
            request(
                world,
                "user_input_request",
                json!({"questions": [{"id": "database", "header": "Database",
                                      "question": "Which database?", "options": options,
                                      "multiSelect": false, "allowCustomAnswer": true}]}),
            )?;
            await_listed(world, "questions")
        },
    );
    steps.step("the user is editing a queued message", |world, _, _| {
        start_working_turn(world)?;
        queue_turn_message(world, "then the docs")?;
        await_listed(world, "queue")?;
        world.dispatch("composer.queue.edit", Json::Null)?;
        world.wait_for_with(
            |w| composer(w)["text"] == json!("then the docs"),
            |w| {
                format!(
                    "the composer to edit the queued message; it shows {}",
                    show(&composer(w))
                )
            },
        )
    });
    steps.step("no provider is available", |world, _, _| {
        let mut list = providers(world);
        for entry in &mut list {
            entry["status"] = json!("error");
        }
        publish_providers(&mut world.mc, list);
        world.wait_for_with(
            |w| composer(w)["sendDisabledReason"] == json!("No provider available"),
            |w| {
                format!(
                    "no provider to be ready; the composer shows {}",
                    show(&composer(w))
                )
            },
        )
    });
    steps.step(
        "the user is holding the step key down after one step",
        |world, _, _| {
            bind_steps(world)?;
            let before = effort_value(world);
            press_step(world, UP, false)?;
            world.wait_for("the first step to change the effort", move |w| {
                effort_value(w) != before
            })?;
            world.mc.part::<Stepping>().held = true;
            Ok(())
        },
    );
}
