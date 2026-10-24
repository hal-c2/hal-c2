//! What a turn starts from without the user choosing: the model last used,
//! the default permissions, and an effort the prompt carries (desktop-qt's
//! ComposerDefaultsSteps.cpp, features/composer/model-and-mode.feature).

use hal_c2_shell::controllers::settings::Settings;
use serde_json::{Value, json};

use crate::harness::{Failure, Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::{
    composer_brick, composer_brick_shown, composer_item, composer_part, press_in_composer,
    type_in_composer,
};
use crate::steps::composer_workspace::{click, int, popup_of};
use crate::steps::launch::{FakeLaunches, launch_calls};
use crate::steps::settings::{fake_config, publish_providers, save_elsewhere};
use crate::steps::stream::{PROJECT, THREAD};
use crate::world::World;
use crate::{expect, fail};

fn composer(world: &World) -> Value {
    world.state("composer")
}

fn providers(world: &mut World) -> Vec<Value> {
    fake_config(&mut world.mc)
        .config
        .get("providers")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

fn change_provider(world: &mut World, instance_id: &str, change: impl Fn(&mut Value)) -> Outcome {
    let mut list = providers(world);
    for entry in list.iter_mut() {
        if entry["instanceId"] == json!(instance_id) {
            change(entry);
        }
    }
    publish_providers(&mut world.mc, list);
    world.sync()
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

fn last_message(world: &mut World) -> Outcome<Value> {
    world.sync()?;
    Ok(world
        .mc
        .commands
        .iter()
        .rfind(|command| command["type"] == json!("message.dispatch"))
        .cloned()
        .unwrap_or(Value::Null))
}

fn new_thread(world: &mut World) -> Outcome {
    world.open_draft(PROJECT)?;
    world.wait_for_with(
        |w| composer(w)["target"] == json!(w.draft_id),
        |w| {
            format!(
                "the composer on the new thread; it shows {}",
                show(&composer(w))
            )
        },
    )
}

fn label_of(world: &World, mode: &str) -> String {
    for entry in composer(world)["runtimeModes"]
        .as_array()
        .into_iter()
        .flatten()
    {
        if entry["value"] == json!(mode) {
            return text(&entry["label"]);
        }
    }
    mode.to_owned()
}

fn mode_of(world: &World, label: &str) -> Outcome<String> {
    for entry in composer(world)["runtimeModes"]
        .as_array()
        .into_iter()
        .flatten()
    {
        if entry["label"] == json!(label) {
            return Ok(text(&entry["value"]));
        }
    }
    fail!(
        "the composer offers {}",
        show(&composer(world)["runtimeModes"])
    )
}

fn ultrathink_effort() -> Value {
    json!({"id": "effort", "label": "Effort", "type": "select",
           "options": [{"id": "medium", "label": "Medium", "isDefault": true},
                       {"id": "high", "label": "High"},
                       {"id": "ultrathink", "label": "Ultrathink"}],
           "promptInjectedValues": ["ultrathink"], "currentValue": "medium"})
}

pub fn register(steps: &mut Steps) {
    // Ultrathink.
    steps.step("the thread runs on Claude", |world, _, _| {
        // Claude's effort offers Ultrathink, which rides in the prompt.
        change_provider(world, "claudeAgent", |entry| {
            if let Some(models) = entry["models"].as_array_mut() {
                for model in models {
                    model["capabilities"] = json!({"optionDescriptors": [ultrathink_effort()]});
                }
            }
        })?;
        update_thread(
            world,
            json!({"modelSelection": {"instanceId": "claudeAgent", "model": "claude-opus"}}),
        )?;
        world.wait_for_with(
            |w| composer(w)["selectedInstanceId"] == json!("claudeAgent"),
            |w| format!("the composer on Claude; it shows {}", show(&composer(w))),
        )
    });
    steps.step(
        &format!("the user turns on Ultrathink and sends {Q}"),
        |world, c, _| {
            let brick = composer_brick(world)?;
            type_in_composer(world, &c[0])?;
            // From the effort picker's list, with the keyboard.
            let picker = composer_part(world, "effortPicker")?;
            let Some(picker) = picker.filter(|p| brick.flag(world, *p, "visible")) else {
                fail!("the composer shows no effort picker");
            };
            let popup = popup_of(&brick, world, picker)?;
            click(world, picker)?;
            world.wait_for("the effort picker to open", |w| {
                brick.flag(w, popup, "opened")
            })?;
            let last = int(&brick, world, picker, "count") - 1;
            for _ in 0..8 {
                if int(&brick, world, picker, "highlightedIndex") == last {
                    break;
                }
                press_in_composer(world, "Down")?;
            }
            press_in_composer(world, "Return")?;
            world.wait_for_with(
                |w| brick.text_of(w, picker, "displayText") == "Ultrathink",
                |w| {
                    format!(
                        "the effort to read Ultrathink; it reads {}",
                        brick.text_of(w, picker, "displayText")
                    )
                },
            )?;
            let item = composer_item(world)?;
            world
                .engine()
                .invoke_by_name(item, "focusInput", &[])
                .map_err(|e| Failure(format!("focusInput: {e:?}")))?;
            press_in_composer(world, "Enter")?;
            Ok(())
        },
    );

    // The model last used.
    steps.step(
        &format!("the user last used {Q} with Codex"),
        |world, c, _| {
            // Codex would start a thread on another model.
            let slug = c[0].clone();
            change_provider(world, "codex", |entry| {
                let mut models: Vec<Value> = Vec::new();
                for model in entry["models"].as_array().cloned().unwrap_or_default() {
                    if model["slug"] != json!(slug) {
                        models.insert(0, model);
                    } else {
                        models.push(model);
                    }
                }
                entry["models"] = Value::Array(models);
            })?;
            world.dispatch(
                "composer.model.select",
                json!({"instanceId": "codex", "model": c[0]}),
            )?;
            world.dispatch(
                "composer.submit",
                json!({"text": "use it", "intent": "foreground"}),
            )?;
            let sent = last_message(world)?;
            expect!(
                sent["modelSelection"]["model"] == json!(c[0]),
                "the turn did not run on {}",
                c[0]
            );
            Ok(())
        },
    );
    steps.step("the user starts a new thread on Codex", |world, _, _| {
        new_thread(world)
    });
    steps.step(&format!("{Q} is chosen"), |world, c, _| {
        let shown = composer(world);
        expect!(
            shown["selectedInstanceId"] == json!("codex") && shown["selectedModel"] == json!(c[0]),
            "the composer is on {} of {}",
            text(&shown["selectedModel"]),
            text(&shown["selectedInstanceId"])
        );
        Ok(())
    });
    steps.step(
        "a model set for the project takes precedence",
        |world, _, _| {
            let mut row = world.mc.projects.get(PROJECT).cloned().unwrap_or(json!({}));
            row["defaultModelSelection"] =
                json!({"instanceId": "claudeAgent", "model": "claude-sonnet"});
            world.mc.projects.insert(PROJECT.into(), row.clone());
            let name = world.mc.name.clone();
            world
                .mc
                .send_rows(&name, vec![json!([PROJECT, "project", row])]);
            world.sync()?;
            world.wait_for_with(
                |w| composer(w)["selectedModel"] == json!("claude-sonnet"),
                |w| {
                    format!(
                        "the project's model; the composer is on {}",
                        text(&composer(w)["selectedModel"])
                    )
                },
            )
        },
    );

    // Default permissions (Settings → Project defaults; the MC keeps them).
    steps.step(
        "the default permissions for new threads are (.+)",
        |world, c, _| {
            let engine = world.engine().clone();
            world.wait_for("the shell to read the settings", |_| {
                Settings::of(&engine).ready()
            })?;
            let mode = mode_of(world, &c[0])?;
            save_elsewhere(&mut world.mc, "defaultRuntimeMode", json!(mode), false);
            world.wait_for("the shell to read the default permissions", |_| {
                Settings::of(&engine).value("defaultRuntimeMode") == Some(json!(mode))
            })
        },
    );
    steps.step("the thread runs in (.+)", |world, c, _| {
        let mode = mode_of(world, &c[0])?;
        let shown = composer(world);
        let default = Settings::of(world.engine()).value("defaultRuntimeMode");
        expect!(
            shown["target"] == json!(world.draft_id) && shown["runtimeMode"] == json!(mode),
            "the composer shows {}; the MC's default is {}, the draft {} of {}",
            label_of(world, &text(&shown["runtimeMode"])),
            show(&default.unwrap_or(Value::Null)),
            world.draft_id,
            text(&shown["target"])
        );
        world.dispatch(
            "composer.submit",
            json!({"text": "Add caching", "intent": "foreground"}),
        )?;
        world.wait_for("the thread to launch", |w| !launch_calls_empty(w))?;
        let launched = launch_calls(world).pop().unwrap_or(Value::Null);
        expect!(
            launched["runtimeMode"] == json!(mode),
            "the launch is {}",
            show(&launched)
        );
        world.sync()
    });
    steps.step(
        "a project that overrides the default uses its own permissions",
        |world, _, _| {
            save_elsewhere(
                &mut world.mc,
                "projectSettingsOverrides",
                json!({ PROJECT: {"defaultRuntimeMode": "auto-accept-edits"} }),
                false,
            );
            world.sync()?;
            new_thread(world)?;
            world.wait_for_with(
                |w| composer(w)["runtimeMode"] == json!("auto-accept-edits"),
                |w| {
                    format!(
                        "the project's permissions; the composer shows {}",
                        text(&composer(w)["runtimeMode"])
                    )
                },
            )
        },
    );
}

fn launch_calls_empty(world: &World) -> bool {
    world
        .mc
        .peek::<FakeLaunches>()
        .is_none_or(|l| l.calls.is_empty())
}

/// The text of the composer's last message, when the composer is on screen:
/// what the agent received of an answer typed there. False when it is not
/// on screen or nothing was sent.
pub fn composer_message_received(world: &mut World, wanted: &str) -> Outcome<bool> {
    if !composer_brick_shown(world) {
        return Ok(false);
    }
    let message = last_message(world)?;
    if message.is_null() {
        return Ok(false);
    }
    // "Ultrathink:" leads the prompt on a line of its own.
    let sent = text(&message["text"]);
    let simplified = sent.split_whitespace().collect::<Vec<_>>().join(" ");
    expect!(
        simplified == wanted && sent.starts_with("Ultrathink:\n"),
        "the agent received \"{sent}\""
    );
    Ok(true)
}
