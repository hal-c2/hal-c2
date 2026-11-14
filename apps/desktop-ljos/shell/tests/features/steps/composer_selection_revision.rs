//! What the composer shows is what runs: a pick is made against the thread's
//! selection revision, a send without one names no model, a stale one is
//! refused and comes back (features/composer/model-and-mode.feature).
//! desktop-qt's ComposerSelectionRevisionSteps.cpp.

use hal_c2_shell::controllers::composer::kept;
use serde_json::{Value, json};

use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::provider_settings::publish_providers_on;
use crate::steps::settings::{fake_config, publish_providers};
use crate::steps::stream::{
    FakeStreams, PEER, PEER_ENVIRONMENT, PEER_THREAD, PROJECT, THREAD, look,
};
use crate::world::World;
use crate::{expect, fail};

/// A change the MC has taken that this client has not been sent yet.
#[derive(Default)]
struct Unheard {
    pending: bool,
}

fn composer(world: &World) -> Value {
    world.state("composer")
}

fn own_key(world: &World) -> String {
    format!("{}:{THREAD}", world.mc.environment_id)
}

fn peer_key() -> String {
    format!("{PEER_ENVIRONMENT}:{PEER_THREAD}")
}

/// The catalogue of the Background: Codex's models, and Claude's.
fn instance_for(model: &str) -> &'static str {
    if model.starts_with("claude") {
        "claudeAgent"
    } else {
        "codex"
    }
}

fn selection(instance_id: &str, model: &str) -> Value {
    json!({"instanceId": instance_id, "model": model})
}

fn account_id(name: &str) -> String {
    name.to_lowercase().replace(' ', "_")
}

fn providers(world: &mut World) -> Vec<Value> {
    fake_config(&mut world.mc).config["providers"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn offer(world: &mut World, list: Vec<Value>) -> Outcome {
    publish_providers(&mut world.mc, list);
    world.sync()
}

/// The thread's row as the MC has it: a change to what it runs on moves its
/// revision on, when it keeps one.
fn change(world: &mut World, fields: Value, heard: bool) -> Outcome {
    let Some(row) = world.mc.threads.get_mut(THREAD) else {
        fail!("the MC has no thread {THREAD}");
    };
    for (key, value) in fields.as_object().into_iter().flatten() {
        row[key] = value.clone();
    }
    if let Some(revision) = row["selectionRevision"].as_i64() {
        row["selectionRevision"] = json!(revision + 1);
    }
    let row = row.clone();
    world.mc.part::<Unheard>().pending = !heard;
    if !heard {
        return Ok(());
    }
    world.mc.send_row(THREAD, &row);
    world.sync()
}

fn expect_on(world: &mut World, instance_id: &str, model: &str) -> Outcome {
    world.wait_for_with(
        |w| {
            let shown = composer(w);
            shown["selectedInstanceId"] == json!(instance_id)
                && shown["selectedModel"] == json!(model)
        },
        |w| {
            format!(
                "the composer on {model} of {instance_id}; it shows {}",
                show(&composer(w))
            )
        },
    )
}

fn pick(world: &mut World, model: &str) -> Outcome {
    world.dispatch(
        "composer.model.select",
        json!({"instanceId": instance_for(model), "model": model}),
    )?;
    expect_on(world, instance_for(model), model)
}

/// The runtime mode a label of the composer's access picker names.
fn mode_of(world: &World, label: &str) -> Outcome<String> {
    let shown = composer(world);
    for entry in shown["runtimeModes"].as_array().into_iter().flatten() {
        if text(&entry["label"]).eq_ignore_ascii_case(label) {
            return Ok(text(&entry["value"]));
        }
    }
    fail!("the composer offers {}", show(&shown["runtimeModes"]))
}

fn commands_of(world: &World, kind: &str) -> Vec<Value> {
    world
        .mc
        .commands
        .iter()
        .filter(|command| command["type"] == json!(kind))
        .cloned()
        .collect()
}

fn index_of(world: &World, matches: impl Fn(&Value) -> bool) -> Option<usize> {
    world.mc.commands.iter().position(matches)
}

fn model_of(command: &Value) -> String {
    text(&command["modelSelection"]["model"])
}

fn own_row(world: &World) -> Value {
    world.mc.threads.get(THREAD).cloned().unwrap_or_default()
}

/// The user changes the open thread's access, and the MC takes it.
fn change_access(world: &mut World, label: &str, thread_id: &str) -> Outcome {
    let mode = mode_of(world, label)?;
    let before = world.mc.commands.len();
    world.dispatch("composer.runtimeMode.set", json!({"mode": mode}))?;
    world.wait_for_with(
        |w| {
            w.mc.commands[before.min(w.mc.commands.len())..]
                .iter()
                .any(|command| {
                    command["type"] == json!("thread.runtime-mode.set")
                        && command["threadId"] == json!(thread_id)
                })
        },
        |w| format!("the access change; the MC has {}", w.describe_commands()),
    )?;
    world.sync()
}

fn submit(world: &mut World, words: &str) -> Outcome {
    world.dispatch(
        "composer.submit",
        json!({"text": words, "intent": "foreground"}),
    )
}

fn wait_for_message(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| !commands_of(w, "message.dispatch").is_empty(),
        |w| format!("the message; the MC has {}", w.describe_commands()),
    )
}

fn peer_row(updated_at: &str, model_selection: Value, revision: i64) -> Value {
    json!({
        "id": PEER_THREAD, "title": "Remote", "projectId": PROJECT,
        "createdAt": "2026-09-23T09:00:00Z", "updatedAt": updated_at,
        "modelSelection": model_selection, "runtimeMode": "full-access",
        "selectionRevision": revision,
    })
}

pub fn register(steps: &mut Steps) {
    // A thread on an MC that keeps a selection revision, Claude's Opus named as its catalogue names it.
    steps.step(&format!("a thread runs on {Q} here"), |world, c, _| {
        let mut list = providers(world);
        for entry in &mut list {
            for model in entry["models"].as_array_mut().into_iter().flatten() {
                if model["slug"] == json!("claude-opus") {
                    model["name"] = json!("Opus");
                }
            }
        }
        offer(world, list)?;
        let Some(row) = world.mc.threads.get_mut(THREAD) else {
            fail!("the MC has no thread {THREAD}");
        };
        row["modelSelection"] = selection(instance_for(&c[0]), &c[0]);
        row["selectionRevision"] = json!(1);
        let row = row.clone();
        world.mc.send_row(THREAD, &row);
        world.sync()?;
        expect_on(world, instance_for(&c[0]), &c[0])
    });
    steps.step(
        &format!("a thread runs on {Q} on an MC that keeps no selection revision"),
        |world, c, _| {
            let Some(row) = world.mc.threads.get_mut(THREAD) else {
                fail!("the MC has no thread {THREAD}");
            };
            row["modelSelection"] = selection(instance_for(&c[0]), &c[0]);
            if let Some(fields) = row.as_object_mut() {
                fields.remove("selectionRevision");
            }
            let row = row.clone();
            world.mc.send_row(THREAD, &row);
            world.sync()?;
            expect_on(world, instance_for(&c[0]), &c[0])
        },
    );
    steps.step(
        &format!("the user picked {Q} for its next turn"),
        |world, c, _| pick(world, &c[0]),
    );
    steps.step(
        &format!("another client has moved the thread to {Q}, which this client has not heard yet"),
        |world, c, _| {
            change(
                world,
                json!({"modelSelection": selection(instance_for(&c[0]), &c[0])}),
                false,
            )
        },
    );

    // A stale send.
    steps.step(
        &format!("nothing is sent on the user's behalf and {Q} stays in the prompt"),
        |world, c, _| {
            let key = own_key(world);
            world.wait_for_with(
                |w| kept::draft_of(w.engine(), &key).text == c[0],
                |w| {
                    format!(
                        "the prompt back; it holds {:?} and the MC has {}",
                        kept::draft_of(w.engine(), &key).text,
                        w.describe_commands()
                    )
                },
            )?;
            world.sync()?;
            expect!(
                commands_of(world, "message.dispatch").len() == 1
                    && commands_of(world, "thread.model-selection.set").is_empty()
                    && commands_of(world, "provider.switch").is_empty(),
                "the client sent more than the one refused message: {}",
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the composer shows {Q} once the change arrives"),
        |world, c, _| {
            expect!(
                world.mc.part::<Unheard>().pending,
                "no change was waiting to arrive"
            );
            world.mc.part::<Unheard>().pending = false;
            let row = own_row(world);
            world.mc.send_row(THREAD, &row);
            world.sync()?;
            expect_on(world, instance_for(&c[0]), &c[0])
        },
    );

    // A send with no pick.
    steps.step(
        &format!("the user sends {Q} without picking a model"),
        |world, c, _| {
            submit(world, &c[0])?;
            wait_for_message(world)
        },
    );
    steps.step(
        &format!("the message names no model, so the turn runs on {Q}"),
        |world, c, _| {
            let message = commands_of(world, "message.dispatch")
                .pop()
                .unwrap_or_default();
            expect!(
                message.get("modelSelection").is_none()
                    && message.get("selectionBase").is_none()
                    && commands_of(world, "provider.switch").is_empty()
                    && commands_of(world, "thread.model-selection.set").is_empty(),
                "the send named a model: {}",
                world.describe_commands()
            );
            let runs = model_of(&own_row(world));
            expect!(runs == c[0], "the thread runs on {runs}");
            Ok(())
        },
    );

    // An MC that keeps no revision.
    steps.step(
        &format!("the thread is set to {Q} before the message goes with that pick"),
        |world, c, _| {
            wait_for_message(world)?;
            let set = index_of(world, |command| {
                command["type"] == json!("thread.model-selection.set") && model_of(command) == c[0]
            });
            let message = index_of(world, |command| {
                command["type"] == json!("message.dispatch") && model_of(command) == c[0]
            });
            expect!(
                matches!((set, message), (Some(set), Some(message)) if message > set),
                "the thread set to {}, then the message with it; the MC has {}",
                c[0],
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the composer shows {Q}, the thread's own now"),
        |world, c, _| {
            world.wait_for("the thread to take the pick", |w| {
                model_of(&own_row(w)) == c[0]
            })?;
            world.sync()?;
            expect_on(world, instance_for(&c[0]), &c[0])
        },
    );
    steps.step(
        "a change made on another client after it replaces the pick",
        |world, _, _| {
            change(
                world,
                json!({"modelSelection": selection("claudeAgent", "claude-opus")}),
                true,
            )?;
            expect_on(world, "claudeAgent", "claude-opus")
        },
    );

    // The user's own access change.
    steps.step(
        "the user changes the thread's access to (.+)",
        |world, c, _| {
            let mode = mode_of(world, &c[0])?;
            change_access(world, &c[0], THREAD)?;
            world.wait_for_with(
                |w| {
                    own_row(w)["runtimeMode"] == json!(mode)
                        && composer(w)["runtimeMode"] == json!(mode)
                },
                |w| {
                    format!(
                        "the thread in {mode}; the composer shows {}",
                        show(&composer(w))
                    )
                },
            )
        },
    );
    steps.step(&format!("the composer still shows {Q}"), |world, c, _| {
        world.sync()?;
        expect_on(world, instance_for(&c[0]), &c[0])
    });

    // A cluster: the first thread's MC keeps no revision, the second's does.
    steps.step(
        "one thread is on an MC that keeps no selection revision and another on one that does",
        |world, _, _| {
            world.mc.join(PEER, PEER_ENVIRONMENT);
            let list = providers(world);
            publish_providers_on(&mut world.mc, PEER_ENVIRONMENT, list);
            world.mc.send_peer_row(
                PEER_ENVIRONMENT,
                PEER_THREAD,
                &peer_row("2026-09-23T09:00:00Z", selection("codex", "gpt-5"), 3),
            );
            world.sync()
        },
    );
    steps.step(
        "the user changed the first thread's access to (.+)",
        |world, c, _| {
            let key = own_key(world);
            look(world, &key, true)?;
            change_access(world, &c[0], THREAD)
        },
    );
    steps.step(
        &format!("the user picked {Q} for the second thread's next turn"),
        |world, c, _| {
            let fake = world.mc.part::<FakeStreams>();
            fake.thread = PEER_THREAD.to_owned();
            fake.environment = PEER_ENVIRONMENT.to_owned();
            look(world, &peer_key(), true)?;
            expect_on(world, "codex", "gpt-5")?;
            pick(world, &c[0])
        },
    );
    // The peer's thread is not among the rows the fake MC moves: its answer names no revision.
    steps.step(
        "the second thread's MC answers an access change to it without moving the thread",
        |world, _, _| change_access(world, "Supervised", PEER_THREAD),
    );
    steps.step(
        "a change made on another client to the second thread replaces the pick",
        |world, _, _| {
            world.mc.send_peer_row(
                PEER_ENVIRONMENT,
                PEER_THREAD,
                &peer_row(
                    "2026-09-23T09:01:00Z",
                    selection("claudeAgent", "claude-opus"),
                    4,
                ),
            );
            world.sync()?;
            expect_on(world, "claudeAgent", "claude-opus")
        },
    );

    // A thread whose account is off.
    steps.step(
        &format!("a thread runs on {Q} on the account {Q}"),
        |world, c, _| {
            let mut list = providers(world);
            for name in [c[1].as_str(), "Codex Work"] {
                list.push(json!({
                    "instanceId": account_id(name), "driver": "codex", "displayName": name,
                    "enabled": true, "installed": true, "status": "ready",
                    "models": [{"slug": c[0], "name": c[0]}],
                }));
            }
            offer(world, list)?;
            change(
                world,
                json!({
                    "modelSelection": selection(&account_id(&c[1]), &c[0]),
                    "selectionRevision": 1,
                }),
                true,
            )
        },
    );
    steps.step(
        &format!("the composer shows {Q} on {Q}, which cannot run a turn now"),
        |world, c, _| {
            expect_on(world, &account_id(&c[1]), &c[0])?;
            world.wait_for_with(
                |w| composer(w)["sendDisabledReason"] == json!("Choose a model to send"),
                |w| {
                    format!(
                        "the composer to ask for a pick; it shows {}",
                        show(&composer(w))
                    )
                },
            )
        },
    );
    steps.step(
        "a message is not sent until the user picks a model",
        |world, _, _| {
            submit(world, "Carry on")?;
            world.sync()?;
            expect!(
                commands_of(world, "message.dispatch").is_empty(),
                "a message was sent: {}",
                world.describe_commands()
            );
            world.dispatch(
                "composer.model.select",
                json!({"instanceId": "codex_work", "model": "gpt-5"}),
            )?;
            expect_on(world, "codex_work", "gpt-5")?;
            submit(world, "Carry on")?;
            wait_for_message(world)?;
            let message = commands_of(world, "message.dispatch")
                .pop()
                .unwrap_or_default();
            expect!(
                message["modelSelection"]["instanceId"] == json!("codex_work"),
                "the message went with {}",
                show(&message)
            );
            Ok(())
        },
    );
}
