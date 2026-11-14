//! What the composer's model picker and permissions offer as the MC's
//! providers change: why an instance cannot be used, the permissions a
//! provider supports, plan mode, a model its provider dropped and a
//! composer with no provider at all (features/composer/model-and-mode.feature).
//! The rest of desktop-qt's ModelSteps.cpp, beside steps/model.rs.

use hal_c2_shell::controllers::settings::Settings;
use ljos::prelude::{ObjectId, Value as QmlValue};
use serde_json::{Value, json};

use crate::brick::Brick;
use crate::harness::{Failure, Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::{composer_brick, composer_part};
use crate::steps::settings::{fake_config, publish_providers};
use crate::steps::stream::THREAD;
use crate::world::World;
use crate::{expect, fail};

fn composer(world: &World) -> Value {
    world.state("composer")
}

fn effort() -> Value {
    let choices: Vec<Value> = ["low", "medium", "high"]
        .iter()
        .map(|level| json!({"id": level, "label": level}))
        .collect();
    json!({"id": "reasoningEffort", "label": "Reasoning", "type": "select",
           "options": choices, "currentValue": "medium"})
}

fn provider(id: &str, driver: &str, name: &str, models: &[&str], fields: Value) -> Value {
    let list: Vec<Value> = models
        .iter()
        .map(|slug| json!({"slug": slug, "name": slug, "capabilities": {"optionDescriptors": [effort()]}}))
        .collect();
    let mut entry = json!({"instanceId": id, "driver": driver, "displayName": name,
                           "enabled": true, "installed": true, "status": "ready", "models": list});
    if let (Some(entry), Some(fields)) = (entry.as_object_mut(), fields.as_object()) {
        for (key, value) in fields {
            entry.insert(key.clone(), value.clone());
        }
    }
    entry
}

fn instances(world: &World) -> Vec<Value> {
    world.state("modelPicker")["instances"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn instance(world: &World, id: &str) -> Value {
    instances(world)
        .into_iter()
        .find(|entry| entry["instanceId"] == json!(id))
        .unwrap_or(Value::Null)
}

fn providers(world: &mut World) -> Vec<Value> {
    fake_config(&mut world.mc)
        .config
        .get("providers")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

/// The MC offers `list` and the picker lists the enabled ones.
fn offer(world: &mut World, list: Vec<Value>) -> Outcome {
    publish_providers(&mut world.mc, list.clone());
    world.sync()?;
    let enabled = list
        .iter()
        .filter(|entry| entry["enabled"] == json!(true))
        .count();
    world.wait_for_with(
        move |w| instances(w).len() == enabled,
        |w| {
            format!(
                "the picker to list the providers; it lists {}",
                show(&Value::Array(instances(w)))
            )
        },
    )
}

/// `entry` in place of the provider with its instance id, or added.
fn add(world: &mut World, entry: Value) -> Outcome {
    let mut list = providers(world);
    list.retain(|p| p["instanceId"] != entry["instanceId"]);
    list.push(entry);
    offer(world, list)
}

fn codex_and_claude() -> Vec<Value> {
    vec![
        provider(
            "codex",
            "codex",
            "Codex",
            &["gpt-5", "gpt-5-codex"],
            json!({}),
        ),
        provider(
            "claudeAgent",
            "claudeAgent",
            "Claude",
            &["claude-opus", "claude-sonnet"],
            json!({}),
        ),
    ]
}

fn update_thread(world: &mut World, fields: Value) -> Outcome {
    let mut row = world.mc.threads.get(THREAD).cloned().unwrap_or(json!({}));
    if let (Some(row), Some(fields)) = (row.as_object_mut(), fields.as_object()) {
        for (key, value) in fields {
            row.insert(key.clone(), value.clone());
        }
    }
    world.mc.threads.insert(THREAD.into(), row.clone());
    world.mc.send_row(THREAD, &row);
    world.sync()
}

/// Sends a turn and returns the commands it made, the message last.
fn send_turn(world: &mut World) -> Outcome<Vec<Value>> {
    let before = world.mc.commands.len();
    world.dispatch(
        "composer.submit",
        json!({"text": "next turn", "intent": "foreground"}),
    )?;
    world.wait_for_with(
        |w| {
            w.mc.commands.len() > before
                && w.mc
                    .commands
                    .last()
                    .is_some_and(|c| c["type"] == json!("message.dispatch"))
        },
        |w| format!("the message; the MC has {}", w.describe_commands()),
    )?;
    Ok(world.mc.commands[before..].to_vec())
}

fn picker(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    let brick = composer_brick(world)?;
    match composer_part(world, "modelPicker")? {
        Some(item) => Ok((brick, item)),
        None => fail!("the composer has no model picker"),
    }
}

fn popup_open(world: &World, brick: &Brick, item: ObjectId) -> bool {
    match brick.read(world, item, "popup") {
        QmlValue::Object(popup) => brick.flag(world, popup, "opened"),
        _ => false,
    }
}

/// Asks the picker to open, as its trigger does.
fn try_open(world: &mut World, item: ObjectId) -> Outcome {
    world
        .engine()
        .invoke_by_name(item, "open", &[])
        .map_err(|e| Failure(format!("open: {e:?}")))?;
    world.sync()
}

fn expect_shut(world: &mut World, why: &str) -> Outcome {
    let (brick, item) = picker(world)?;
    try_open(world, item)?;
    expect!(
        !popup_open(world, &brick, item),
        "the model picker opened {why}"
    );
    Ok(())
}

fn expect_opens(world: &mut World) -> Outcome {
    let (brick, item) = picker(world)?;
    world.wait_for("the model picker to open", |w| {
        brick.flag(w, item, "enabled")
    })?;
    try_open(world, item)?;
    world.wait_for("the model picker to open", |w| popup_open(w, &brick, item))
}

fn mode_label(world: &World, value: &str) -> String {
    composer(world)["runtimeModes"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|mode| mode["value"] == json!(value))
        .map(|mode| text(&mode["label"]))
        .unwrap_or_default()
}

fn set_plan_mode(world: &mut World, on: bool) -> Outcome {
    let engine = world.engine().clone();
    let written = Settings::of(&engine).write_device(&engine, "planModeEnabled", json!(on));
    expect!(written, "the plan mode setting could not be written");
    world.sync()
}

fn only_supervised_and_full(world: &mut World) -> Outcome {
    add(
        world,
        provider(
            "codex",
            "codex",
            "Codex",
            &["gpt-5", "gpt-5-codex"],
            json!({"supportedRuntimeModes": ["approval-required", "full-access"]}),
        ),
    )
}

pub fn register(steps: &mut Steps) {
    // Why a provider instance cannot be used, in its rail tooltip.
    steps.step(&format!("the provider instance {Q} (.+)"), |world, c, _| {
        let state = c[1].as_str();
        let quoted = |prefix: &str| {
            state
                .strip_prefix(prefix)
                .and_then(|rest| rest.strip_prefix('"'))
                .and_then(|rest| rest.strip_suffix('"'))
                .map(str::to_owned)
        };
        let fields = if state == "is turned off in settings" {
            json!({"status": "disabled"})
        } else if let Some(message) = quoted("failed its check with ") {
            json!({"status": "error", "message": message})
        } else if let Some(message) = quoted("reports the warning ") {
            json!({"status": "warning", "message": message})
        } else if state == "has not finished its check" {
            json!({"status": "checking"})
        } else {
            fail!("the steps do not know the state {state}");
        };
        add(
            world,
            provider("codex_work", "codex", &c[0], &["gpt-5-work"], fields),
        )
    });
    steps.step(
        &format!("the user rests on {Q} in the model picker"),
        |world, _, _| world.sync(),
    );
    steps.step(&format!("the user reads {Q}"), |world, c, _| {
        let reason = text(&instance(world, "codex_work")["unavailableReason"]);
        expect!(
            reason == c[0],
            "the picker says \"{reason}\", not \"{}\"",
            c[0]
        );
        Ok(())
    });

    // Only the permissions the provider supports.
    steps.step(
        "the thread's provider supports only Supervised and Full access",
        |world, _, _| only_supervised_and_full(world),
    );
    steps.step(
        "its provider now supports only Supervised and Full access",
        |world, _, _| only_supervised_and_full(world),
    );
    steps.step("the user opens the permissions", |world, _, _| world.sync());
    steps.step(
        "only Supervised and Full access are offered, each with a line saying what it allows",
        |world, _, _| {
            let modes = composer(world)["runtimeModes"].clone();
            let list = modes.as_array().cloned().unwrap_or_default();
            let labels: Vec<String> = list.iter().map(|mode| text(&mode["label"])).collect();
            let described = list
                .iter()
                .all(|mode| !text(&mode["description"]).is_empty());
            expect!(
                labels == ["Supervised", "Full access"] && described,
                "the composer offers {}",
                show(&modes)
            );
            Ok(())
        },
    );
    steps.step(
        "the thread was saved with Auto-accept edits",
        |world, _, _| update_thread(world, json!({"runtimeMode": "auto-accept-edits"})),
    );
    steps.step("the user looks at the composer", |world, _, _| world.sync());
    steps.step(&format!("the permissions read {Q}"), |world, c, _| {
        let shown = text(&composer(world)["runtimeMode"]);
        let label = mode_label(world, &shown);
        expect!(label == c[0], "the permissions read \"{label}\" ({shown})");
        Ok(())
    });
    steps.step(
        "the thread's saved permissions are unchanged until the user chooses",
        |world, _, _| {
            let saved = world
                .mc
                .threads
                .get(THREAD)
                .map(|row| row["runtimeMode"].clone());
            let changed = world
                .mc
                .commands
                .iter()
                .any(|command| command["type"] == json!("thread.runtime-mode.set"));
            expect!(
                saved == Some(json!("auto-accept-edits")) && !changed,
                "the MC has {}",
                world.describe_commands()
            );
            Ok(())
        },
    );

    // Build and Plan only while the plan mode setting is on.
    steps.step("the plan mode setting is on", |world, _, _| {
        set_plan_mode(world, true)
    });
    steps.step(
        "the composer offers to switch between \"Build\" and \"Plan\"",
        |world, _, _| {
            world.wait_for_with(
                |w| composer(w)["showInteractionModeToggle"] == json!(true),
                |w| {
                    format!(
                        "the Build/Plan switch; the composer shows {}",
                        show(&composer(w))
                    )
                },
            )
        },
    );
    steps.step("the user turns the plan mode setting off", |world, _, _| {
        set_plan_mode(world, false)
    });
    steps.step("the composer offers no such switch", |world, _, _| {
        world.wait_for_with(
            |w| composer(w)["showInteractionModeToggle"] != json!(true),
            |w| {
                format!(
                    "no Build/Plan switch; the composer shows {}",
                    show(&composer(w))
                )
            },
        )
    });
    steps.step("the next turn builds", |world, _, _| {
        let mode = text(&composer(world)["interactionMode"]);
        expect!(mode == "default", "the composer is in {mode}");
        for command in send_turn(world)? {
            expect!(
                command["interactionMode"] != json!("plan"),
                "the send made {}",
                show(&command)
            );
        }
        Ok(())
    });

    // A saved model its provider no longer lists.
    steps.step(
        &format!("the thread runs on OpenCode with the model {Q}"),
        |world, c, _| {
            let slug = c[0].clone();
            add(
                world,
                provider(
                    "opencode",
                    "opencode",
                    "OpenCode",
                    &[&slug, "big-pickle"],
                    json!({}),
                ),
            )?;
            update_thread(
                world,
                json!({"modelSelection": {"instanceId": "opencode", "model": slug}}),
            )?;
            world.wait_for_with(
                |w| composer(w)["selectedModel"] == json!(slug),
                |w| format!("the composer on {slug}; it shows {}", show(&composer(w))),
            )
        },
    );
    steps.step(&format!("OpenCode no longer lists {Q}"), |world, _, _| {
        add(
            world,
            provider(
                "opencode",
                "opencode",
                "OpenCode",
                &["big-pickle"],
                json!({}),
            ),
        )
    });
    steps.step(&format!("the model reads {Q}"), |world, c, _| {
        // The trigger reads "<model> (Unavailable)" from the kept model's
        // flag.
        let slug = c[0]
            .strip_suffix(" (Unavailable)")
            .unwrap_or(&c[0])
            .to_owned();
        world.wait_for_with(
            |w| {
                let kept = instance(w, "opencode")["models"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|model| {
                        model["slug"] == json!(slug) && model["isUnavailable"] == json!(true)
                    });
                kept && composer(w)["selectedModel"] == json!(slug)
            },
            |w| {
                format!(
                    "{slug} kept as unavailable; the picker lists {}",
                    show(&Value::Array(instances(w)))
                )
            },
        )
    });
    steps.step(
        "the thread's model is not changed to another one",
        |world, _, _| {
            let saved = world
                .mc
                .threads
                .get(THREAD)
                .map(|row| row["modelSelection"]["model"].clone())
                .unwrap_or(Value::Null);
            expect!(
                saved == composer(world)["selectedModel"],
                "the thread is on {}",
                show(&saved)
            );
            Ok(())
        },
    );

    // A composer with no usable provider. The thread runs on OpenCode, a
    // keep-unlisted driver, so its dropped model still resolves in the
    // picker: the stand-in has to win over the model name on the trigger
    // itself.
    steps.step("no provider can run a turn", |world, _, _| {
        offer(
            world,
            vec![
                provider(
                    "codex",
                    "codex",
                    "Codex",
                    &["gpt-5"],
                    json!({"installed": false, "status": "error", "message": "codex not found"}),
                ),
                provider(
                    "claudeAgent",
                    "claudeAgent",
                    "Claude",
                    &["claude-opus"],
                    json!({"installed": false, "status": "error"}),
                ),
                provider(
                    "opencode",
                    "opencode",
                    "OpenCode",
                    &["big-pickle"],
                    json!({"installed": false, "status": "error"}),
                ),
            ],
        )?;
        update_thread(
            world,
            json!({"modelSelection": {"instanceId": "opencode", "model": "kimi-k2"}}),
        )?;
        world.wait_for_with(
            |w| composer(w)["selectedModel"] == json!("kimi-k2"),
            |w| format!("the composer on kimi-k2; it shows {}", show(&composer(w))),
        )
    });
    steps.step("one of the providers can be set up", |world, _, _| {
        add(
            world,
            provider(
                "cursor",
                "cursor",
                "Cursor",
                &["cursor-auto"],
                json!({"installed": false, "status": "error",
                       "setup": {"canInstall": true, "canAuthenticate": false}}),
            ),
        )
    });
    steps.step("none of the providers can be set up", |world, _, _| {
        world.sync()
    });
    steps.step(
        &format!("the composer shows {Q} where the model would be"),
        |world, c, _| {
            let (brick, item) = picker(world)?;
            let wanted = c[0].clone();
            world.wait_for_with(
                |w| brick.text_of(w, item, "triggerTitle") == wanted,
                |w| {
                    format!(
                        "the trigger to read \"{wanted}\"; it reads \"{}\"",
                        brick.text_of(w, item, "triggerTitle")
                    )
                },
            )
        },
    );
    steps.step("no message can be sent", |world, _, _| {
        let shown = composer(world);
        expect!(
            shown["canSend"] != json!(true)
                && shown["sendDisabledReason"] == json!("No provider available"),
            "the composer shows {}",
            show(&shown)
        );
        Ok(())
    });

    // The model cannot change while a message is on its way.
    steps.step(
        "the user has sent a message the MC has not taken yet",
        |world, _, _| {
            composer_brick(world)?;
            world.mc.hold("answers");
            world.dispatch(
                "composer.submit",
                json!({"text": "next turn", "intent": "foreground"}),
            )?;
            world.wait_for("the send to be on its way", |w| {
                composer(w)["isSendBusy"] == json!(true)
            })
        },
    );
    steps.step("the model picker cannot be opened", |world, _, _| {
        let (brick, item) = picker(world)?;
        expect!(
            !brick.flag(world, item, "enabled"),
            "the model picker can be opened while a message is on its way"
        );
        expect_shut(world, "while a message is on its way")
    });
    steps.step(
        "it can be opened again once the MC takes the message",
        |world, _, _| {
            world.mc.answer_held();
            world.sync()?;
            world.wait_for("the send to finish", |w| {
                composer(w)["isSendBusy"] != json!(true)
            })?;
            expect_opens(world)
        },
    );

    // The picker waits for the provider list.
    steps.step(
        "the environment has not yet reported its providers",
        |world, _, _| {
            composer_brick(world)?;
            offer(world, Vec::new())
        },
    );
    steps.step(
        "the composer shows the thread's model and the model picker cannot be opened",
        |world, _, _| {
            let (brick, item) = picker(world)?;
            world.wait_for("the model picker to wait", |w| {
                !brick.flag(w, item, "enabled")
            })?;
            let (title, selected) = (
                brick.text_of(world, item, "triggerTitle"),
                text(&composer(world)["selectedModel"]),
            );
            expect!(
                title == selected,
                "the picker reads \"{title}\", not {selected}"
            );
            expect_shut(world, "before the providers arrived")
        },
    );
    steps.step("the providers arrive", |world, _, _| {
        offer(world, codex_and_claude())
    });
    steps.step("the model picker can be opened", |world, _, _| {
        expect_opens(world)
    });
}
