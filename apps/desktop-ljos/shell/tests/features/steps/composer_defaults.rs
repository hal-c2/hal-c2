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
        "the default permissions (?:for new threads )?are (.+)",
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
    register_fallbacks(steps);
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

fn effort_choices() -> Value {
    json!({"id": "reasoningEffort", "label": "Effort", "type": "select",
           "options": [{"id": "low", "label": "Low", "isDefault": true},
                       {"id": "high", "label": "High"},
                       {"id": "xhigh", "label": "Extra High"}],
           "currentValue": "low"})
}

fn account_model(slug: &str, name: &str, extra: Value) -> Value {
    let mut model = json!({"slug": slug, "name": name,
                           "capabilities": {"optionDescriptors": [effort_choices()]}});
    if let (Some(model), Some(extra)) = (model.as_object_mut(), extra.as_object()) {
        for (key, value) in extra {
            model.insert(key.clone(), value.clone());
        }
    }
    model
}

fn account(id: &str, driver: &str, name: &str, models: Value) -> Value {
    json!({"instanceId": id, "driver": driver, "displayName": name, "enabled": true,
           "installed": true, "status": "ready", "models": models})
}

fn account_id(name: &str) -> String {
    name.to_lowercase().replace(' ', "_")
}

fn add_account(world: &mut World, entry: Value) -> Outcome {
    let mut list = providers(world);
    list.push(entry);
    publish_providers(&mut world.mc, list);
    world.sync()
}

fn effort_of(world: &World) -> String {
    composer(world)["options"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|option| option["id"] == json!("reasoningEffort"))
        .map(|option| text(&option["value"]))
        .unwrap_or_default()
}

fn turn_off(world: &mut World, name: &str) -> Outcome {
    change_provider(world, &account_id(name), |entry| {
        entry["enabled"] = json!(false)
    })
}

fn submit_and_launch(world: &mut World, words: &str) -> Outcome<Value> {
    world.dispatch(
        "composer.submit",
        json!({"text": words, "intent": "foreground"}),
    )?;
    world.wait_for("the thread to launch", |w| !launch_calls_empty(w))?;
    Ok(launch_calls(world).pop().unwrap_or(Value::Null))
}

fn wait_composer(
    world: &mut World,
    what: String,
    shows: impl Fn(&World) -> bool + 'static,
) -> Outcome {
    world.wait_for_with(shows, move |w| {
        format!("{what}; the composer shows {}", show(&composer(w)))
    })
}

/// A provider account that cannot run falls back to another of its driver;
/// a draft switched to an instance whose catalogue lacks its model.
fn register_fallbacks(steps: &mut Steps) {
    steps.step(
        &format!("new threads default to Claude Opus at extra high effort on the account {Q}"),
        |world, c, _| {
            let opus = || json!([account_model("opus", "Claude Opus", json!({}))]);
            add_account(
                world,
                account(&account_id(&c[0]), "claudeAgent", &c[0], opus()),
            )?;
            add_account(
                world,
                account("claude_team", "claudeAgent", "Claude Team", opus()),
            )?;
            // The project's default for new threads (a carried model gives way to it).
            let mut row = world.mc.projects.get(PROJECT).cloned().unwrap_or(json!({}));
            row["defaultModelSelection"] = json!({"instanceId": account_id(&c[0]), "model": "opus",
                "options": [{"id": "reasoningEffort", "value": "xhigh"}]});
            world.mc.projects.insert(PROJECT.into(), row.clone());
            let name = world.mc.name.clone();
            world
                .mc
                .send_rows(&name, vec![json!([PROJECT, "project", row])]);
            world.sync()
        },
    );
    steps.step(
        &format!("{Q} is turned off and the account {Q} is ready"),
        |world, c, _| turn_off(world, &c[0]),
    );
    steps.step(
        &format!("{Q} is turned off and {Q}, with high effort of its own is ready"),
        |world, c, _| {
            // The fallback account's own effort for the model, from when it was used.
            world.dispatch(
                "composer.model.select",
                json!({"instanceId": account_id(&c[1]), "model": "opus"}),
            )?;
            world.dispatch(
                "composer.option.set",
                json!({"id": "reasoningEffort", "value": "high"}),
            )?;
            world.wait_for("the fallback account's own effort to be set", |w| {
                effort_of(w) == "high"
            })?;
            turn_off(world, &c[0])
        },
    );
    steps.step(
        &format!("{Q} is turned off and only a Codex account is ready"),
        |world, c, _| {
            turn_off(world, &c[0])?;
            turn_off(world, "Claude Team")?;
            change_provider(world, "claudeAgent", |entry| {
                entry["enabled"] = json!(false)
            })
        },
    );
    steps.step(
        &format!("the composer shows Claude Opus at extra high effort on {Q}"),
        |world, c, _| {
            let id = account_id(&c[0]);
            wait_composer(world, format!("Opus at extra high on {}", c[0]), move |w| {
                let shown = composer(w);
                shown["target"] == json!(w.draft_id)
                    && shown["selectedInstanceId"] == json!(id)
                    && shown["selectedModel"] == json!("opus")
                    && effort_of(w) == "xhigh"
            })
        },
    );
    steps.step(
        "the first turn is sent at extra high effort",
        |world, _, _| {
            let launched = submit_and_launch(world, "first turn")?;
            let sent = launched["modelSelection"]["options"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|o| o["id"] == json!("reasoningEffort") && o["value"] == json!("xhigh"));
            expect!(sent, "the launch is {}", show(&launched));
            Ok(())
        },
    );
    steps.step(
        &format!("the composer shows {Q} at its own high effort"),
        |world, c, _| {
            let id = account_id(&c[0]);
            wait_composer(world, format!("{} at high", c[0]), move |w| {
                let shown = composer(w);
                shown["target"] == json!(w.draft_id)
                    && shown["selectedInstanceId"] == json!(id)
                    && effort_of(w) == "high"
            })
        },
    );
    steps.step(
        "the composer shows the Codex model at its default effort",
        |world, _, _| {
            wait_composer(world, "the Codex model".into(), |w| {
                let shown = composer(w);
                shown["target"] == json!(w.draft_id)
                    && shown["selectedInstanceId"] == json!("codex")
                    && shown["selectedModel"] == json!("gpt-5")
            })?;
            // Codex's effort defaults to medium in this catalogue.
            let effort = effort_of(world);
            expect!(effort == "medium", "the effort is {effort}");
            Ok(())
        },
    );

    // A thread saved under a model's alias, on an account that is now off.
    steps.step(
        &format!("a thread saved on the account {Q} with the model {Q} at high effort"),
        |world, c, _| {
            let builtin = account_model("gpt-5.4", "GPT-5.4", json!({"aliases": ["5.4"]}));
            let custom = account_model("my-5.4", "5.4", json!({"isCustom": true}));
            add_account(
                world,
                account(
                    &account_id(&c[0]),
                    "codex",
                    &c[0],
                    json!([builtin.clone(), custom]),
                ),
            )?;
            add_account(
                world,
                account("codex_work", "codex", "Codex Work", json!([builtin])),
            )?;
            update_thread(
                world,
                json!({"modelSelection": {"instanceId": account_id(&c[0]), "model": c[1],
                    "options": [{"id": "reasoningEffort", "value": "high"}]}}),
            )
        },
    );
    steps.step(
        &format!("the composer shows {Q} on {Q} at high effort"),
        |world, c, _| {
            let (model, id) = (c[0].clone(), account_id(&c[1]));
            wait_composer(world, format!("{} on {} at high", c[0], c[1]), move |w| {
                let shown = composer(w);
                shown["selectedInstanceId"] == json!(id)
                    && shown["selectedModel"] == json!(model)
                    && effort_of(w) == "high"
            })
        },
    );
    steps.step(
        &format!("a custom model named {Q} on {Q} is not taken for {Q}"),
        |world, c, _| {
            let model = composer(world)["selectedModel"].clone();
            expect!(
                model == json!(c[2]) && model != json!("my-5.4"),
                "the composer is on {}",
                text(&model)
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the draft picked {Q} on the default OpenCode instance"),
        |world, c, _| {
            let picked = json!([account_model("kimi-k3.1-pro", &c[0], json!({}))]);
            add_account(world, account("opencode", "opencode", "OpenCode", picked))?;
            let own = account_model("kimi-default", "Kimi Default", json!({"isDefault": true}));
            add_account(world, account("kimi", "opencode", "Kimi", json!([own])))?;
            save_elsewhere(
                &mut world.mc,
                "defaultModelSelection",
                json!({"instanceId": "opencode", "model": "kimi-k3.1-pro"}),
                false,
            );
            world.sync()
        },
    );
    steps.step(
        &format!(
            "the user switches the draft to a second OpenCode instance {Q} without picking a model"
        ),
        |world, c, _| {
            save_elsewhere(
                &mut world.mc,
                "defaultModelSelection",
                json!({"instanceId": account_id(&c[0]), "model": "kimi-k3.1-pro"}),
                false,
            );
            new_thread(world)
        },
    );
    steps.step(
        &format!("the composer shows {Q}'s own default model with its effort choices"),
        |world, c, _| {
            wait_composer(world, format!("{}'s default", c[0]), |w| {
                let shown = composer(w);
                shown["selectedInstanceId"] == json!("kimi")
                    && shown["selectedModel"] == json!("kimi-default")
                    && !effort_of(w).is_empty()
            })
        },
    );
    steps.step(
        &format!("sending asks {Q} only for a model in its own catalog"),
        |world, _, _| {
            let launched = submit_and_launch(world, "hello")?;
            let selection = &launched["modelSelection"];
            expect!(
                selection["instanceId"] == json!("kimi")
                    && selection["model"] == json!("kimi-default"),
                "the launch asks for {}",
                show(selection)
            );
            Ok(())
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
    let sent = text(&message["text"]);
    let simplified = sent.split_whitespace().collect::<Vec<_>>().join(" ");
    expect!(simplified == wanted, "the agent received \"{sent}\"");
    Ok(true)
}
