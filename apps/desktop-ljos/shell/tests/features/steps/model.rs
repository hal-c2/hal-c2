//! The model, effort and permissions a turn runs with (desktop-qt's
//! ModelSteps.cpp): the MC's providers (`config.providers`), the model
//! picker the composer controller publishes (`modelPicker`), and the message
//! a send makes of the choice (features/composer/model-and-mode.feature).

use hal_c2_shell::controllers::navigation::Navigation;
use ljos::prelude::Value as QmlValue;
use serde_json::{Value, json};

use crate::brick::{Brick, Shown};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::composer_picker;
use crate::steps::keybinding::{describe_key_press, key_ran, set_key_focus};
use crate::steps::settings::publish_providers;
use crate::steps::stream::{PROJECT, THREAD, look_at_thread};
use crate::steps::turn::open_turn_thread;
use crate::world::World;
use crate::{expect, fail};
use hal_c2_shell::controllers::keybindings::Focus;

/// The providers the MC offers, and the model last made a favourite.
#[derive(Default)]
struct Catalogue {
    providers: Vec<Value>,
    favourite: String,
}

fn effort() -> Value {
    let choices: Vec<Value> = ["low", "medium", "high"]
        .iter()
        .map(|level| json!({"id": level, "label": level}))
        .collect();
    json!({"id": "reasoningEffort", "label": "Reasoning", "type": "select",
           "options": choices, "currentValue": "medium"})
}

fn provider(
    instance_id: &str,
    driver: &str,
    display_name: &str,
    models: &[&str],
    fields: Value,
) -> Value {
    let list: Vec<Value> = models
        .iter()
        .map(|slug| {
            json!({"slug": slug, "name": slug,
                   "capabilities": {"optionDescriptors": [effort()]}})
        })
        .collect();
    let mut entry = json!({"instanceId": instance_id, "driver": driver,
                           "displayName": display_name, "enabled": true,
                           "installed": true, "status": "ready", "models": list});
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

fn instance(world: &World, instance_id: &str) -> Value {
    instances(world)
        .into_iter()
        .find(|entry| entry["instanceId"] == json!(instance_id))
        .unwrap_or(Value::Null)
}

fn slugs(instance: &Value) -> Vec<String> {
    instance["models"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|model| text(&model["slug"]))
        .collect()
}

/// The MC offers `providers` and the picker lists them.
fn offer(world: &mut World, providers: Vec<Value>) -> Outcome {
    world.mc.part::<Catalogue>().providers = providers.clone();
    publish_providers(&mut world.mc, providers.clone());
    let enabled = providers
        .iter()
        .filter(|entry| entry["enabled"] == json!(true))
        .count();
    world.wait_for_with(
        |w| instances(w).len() == enabled,
        |w| {
            format!(
                "the picker to list the providers; it lists {}",
                show(&Value::Array(instances(w)))
            )
        },
    )
}

fn add(world: &mut World, entry: Value) -> Outcome {
    let mut providers = world.mc.part::<Catalogue>().providers.clone();
    if let Some(at) = providers
        .iter()
        .position(|p| p["instanceId"] == entry["instanceId"])
    {
        providers.remove(at);
    }
    providers.push(entry);
    offer(world, providers)
}

/// Codex and Claude, as an MC with both signed in.
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

/// The instance whose models include `slug`.
fn instance_of(world: &World, slug: &str) -> Outcome<String> {
    for entry in instances(world) {
        if slugs(&entry).iter().any(|s| s == slug) {
            return Ok(text(&entry["instanceId"]));
        }
    }
    fail!(
        "no provider lists {slug}; the picker lists {}",
        show(&Value::Array(instances(world)))
    )
}

fn composer(world: &World) -> Value {
    world.state("composer")
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

fn favourite(world: &World, slug: &str) -> bool {
    for entry in instances(world) {
        let models = entry["models"].as_array().cloned().unwrap_or_default();
        for (i, model) in models.iter().enumerate() {
            // Favourites lead their provider's list.
            if model["slug"] == json!(slug) {
                return model["isFavorite"] == json!(true)
                    && models[..i].iter().all(|m| m["isFavorite"] == json!(true));
            }
        }
    }
    false
}

fn project_row() -> Value {
    json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": "/work/shop", "scripts": []})
}

fn codex_selection() -> Value {
    json!({"instanceId": "codex", "model": "gpt-5"})
}

fn runtime_modes(world: &World) -> Value {
    composer(world)["runtimeModes"].clone()
}

pub fn register(steps: &mut Steps) {
    // The MC's providers.
    steps.step("a project with an open thread on Codex", |world, _, _| {
        world.mc.projects.insert(PROJECT.into(), project_row());
        world.mc.part::<Catalogue>().providers = codex_and_claude();
        publish_providers(&mut world.mc, codex_and_claude());
        world.connect()?;
        world.sync()?;
        look_at_thread(world, PROJECT)?;
        update_thread(
            world,
            json!({"modelSelection": codex_selection(), "runtimeMode": "full-access"}),
        )?;
        world.wait_for_with(
            |w| composer(w)["selectedModel"] == json!("gpt-5"),
            |w| format!("the composer on gpt-5; it shows {}", show(&composer(w))),
        )
    });
    steps.step("the Cursor provider is not installed", |world, _, _| {
        add(
            world,
            provider(
                "cursor",
                "cursor",
                "Cursor",
                &["cursor-auto"],
                json!({"installed": false, "status": "error",
                       "message": "Cursor CLI is not installed."}),
            ),
        )
    });
    steps.step(
        &format!("Claude and a second Codex instance {Q} are enabled"),
        |world, c, _| {
            add(
                world,
                provider("codex_work", "codex", &c[0], &["gpt-5-work"], json!({})),
            )?;
            // And one the user turned off in settings.
            add(
                world,
                provider(
                    "opencode",
                    "opencode",
                    "OpenCode",
                    &["big-pickle"],
                    json!({"enabled": false}),
                ),
            )
        },
    );
    steps.step(
        "the thread has already run a turn on Codex",
        |world, _, _| {
            update_thread(world, json!({"latestRunId": "run-0"}))?;
            world.sync()
        },
    );

    // providers/permission-modes.feature: the composer's own permission picker.
    steps.step("a supervised thread", |world, _, _| {
        world.mc.part::<Catalogue>().providers = codex_and_claude();
        publish_providers(&mut world.mc, codex_and_claude());
        look_at_thread(world, PROJECT)?;
        update_thread(
            world,
            json!({"modelSelection": codex_selection(), "runtimeMode": "approval-required"}),
        )?;
        world.wait_for_with(
            |w| composer(w)["runtimeMode"] == json!("approval-required"),
            |w| format!("a supervised composer; it shows {}", show(&composer(w))),
        )
    });
    steps.step(
        "the user switches the thread to auto-accept edits on desktop or mobile",
        |world, _, _| {
            let modes = runtime_modes(world);
            for mode in modes.as_array().into_iter().flatten() {
                if mode["value"] == json!("auto-accept-edits") {
                    return world.dispatch(
                        "composer.runtimeMode.set",
                        json!({"mode": "auto-accept-edits"}),
                    );
                }
            }
            fail!(
                "the composer does not offer auto-accept edits: {}",
                show(&modes)
            )
        },
    );

    // What the user does.
    steps.step("the user looks through the models", |world, _, _| {
        world.sync()
    });
    steps.step(&format!("the user chooses the model {Q}"), |world, c, _| {
        let instance = instance_of(world, &c[0])?;
        world.dispatch(
            "composer.model.select",
            json!({"instanceId": instance, "model": c[0]}),
        )
    });
    steps.step(
        "the user sets the effort to (low|medium|high)",
        |world, c, _| {
            world.dispatch(
                "composer.option.set",
                json!({"id": "reasoningEffort", "value": c[0]}),
            )
        },
    );
    steps.step("the user sets the permissions to (.+)", |world, c, _| {
        let modes = runtime_modes(world);
        for mode in modes.as_array().into_iter().flatten() {
            if mode["label"] == json!(c[0]) {
                return world.dispatch("composer.runtimeMode.set", json!({"mode": mode["value"]}));
            }
        }
        fail!("the composer offers {}", show(&modes))
    });
    steps.step(
        &format!("the user marks {Q} as a favourite"),
        |world, c, _| {
            world.mc.part::<Catalogue>().favourite = c[0].clone();
            let instance = instance_of(world, &c[0])?;
            world.dispatch(
                "composer.model.favorite.toggle",
                json!({"instanceId": instance, "model": c[0]}),
            )
        },
    );
    steps.step("the user removes it from the favourites", |world, _, _| {
        let slug = world.mc.part::<Catalogue>().favourite.clone();
        let instance = instance_of(world, &slug)?;
        world.dispatch(
            "composer.model.favorite.toggle",
            json!({"instanceId": instance, "model": slug}),
        )
    });

    // What the picker and the composer show.
    steps.step("Cursor's models cannot be chosen", |world, _, _| {
        let cursor = instance(world, "cursor");
        expect!(
            !cursor.is_null() && cursor["isAvailable"] != json!(true) && slugs(&cursor).is_empty(),
            "the picker lists Cursor as {}",
            show(&cursor)
        );
        world.dispatch(
            "composer.model.select",
            json!({"instanceId": "cursor", "model": "cursor-auto"}),
        )?;
        let chosen = composer(world);
        expect!(
            chosen["selectedInstanceId"] != json!("cursor"),
            "the composer chose {}",
            show(&chosen)
        );
        Ok(())
    });
    steps.step(
        "Cursor is listed with the reason it is unavailable",
        |world, _, _| {
            let reason = text(&instance(world, "cursor")["unavailableReason"]);
            expect!(
                reason.contains("Cursor CLI is not installed."),
                "the picker lists {}",
                show(&Value::Array(instances(world)))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("Codex, {Q} and Claude each list only their own models"),
        |world, c, _| {
            let work = instance(world, "codex_work");
            expect!(
                slugs(&instance(world, "codex")) == ["gpt-5", "gpt-5-codex"]
                    && work["displayName"] == json!(c[0])
                    && slugs(&work) == ["gpt-5-work"]
                    && slugs(&instance(world, "claudeAgent")) == ["claude-opus", "claude-sonnet"],
                "the picker lists {}",
                show(&Value::Array(instances(world)))
            );
            Ok(())
        },
    );
    steps.step(
        "a provider that is turned off in settings is not listed",
        |world, _, _| {
            expect!(
                instance(world, "opencode").is_null(),
                "the picker lists {}",
                show(&Value::Array(instances(world)))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the composer shows {Q} marked as a (\\w+) model"),
        |world, c, _| {
            let shown = composer(world);
            let chosen = instance(world, &text(&shown["selectedInstanceId"]));
            expect!(
                shown["selectedModel"] == json!(c[0]) && chosen["displayName"] == json!(c[1]),
                "the composer shows {} of {}",
                show(&shown["selectedModel"]),
                show(&chosen)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is listed among the favourites"),
        |world, c, _| {
            let slug = c[0].clone();
            world.wait_for_with(
                |w| favourite(w, &slug),
                |w| {
                    format!(
                        "a favourite; the picker lists {}",
                        show(&Value::Array(instances(w)))
                    )
                },
            )
        },
    );
    steps.step(
        "it is no longer listed among the favourites",
        |world, _, _| {
            let slug = world.mc.part::<Catalogue>().favourite.clone();
            world.wait_for_with(
                |w| !favourite(w, &slug),
                |w| {
                    format!(
                        "no favourite; the picker lists {}",
                        show(&Value::Array(instances(w)))
                    )
                },
            )
        },
    );

    // What the next turn runs with.
    steps.step(&format!("the next turn runs on {Q}"), |world, c, _| {
        let commands = send_turn(world)?;
        let selection = commands
            .last()
            .map_or(Value::Null, |m| m["modelSelection"].clone());
        expect!(
            selection["model"] == json!(c[0]),
            "the message runs on {}",
            show(&selection)
        );
        Ok(())
    });
    steps.step(
        &format!("the next turn moves the thread to Claude before it runs on {Q}"),
        |world, c, _| {
            let commands = send_turn(world)?;
            let before = commands
                .len()
                .checked_sub(2)
                .map_or(Value::Null, |i| commands[i].clone());
            let last = commands.last().cloned().unwrap_or(Value::Null);
            expect!(
                before["type"] == json!("provider.switch")
                    && at(&before, "modelSelection.instanceId") == &json!("claudeAgent")
                    && at(&last, "modelSelection.model") == &json!(c[0]),
                "the send made {}",
                show(&Value::Array(commands))
            );
            Ok(())
        },
    );
    steps.step(
        "the next turn runs with (low|medium|high) effort",
        |world, c, _| {
            let commands = send_turn(world)?;
            let selection = commands
                .last()
                .map_or(Value::Null, |m| m["modelSelection"].clone());
            let found = selection["options"].as_array().is_some_and(|options| {
                options
                    .iter()
                    .any(|o| o["id"] == json!("reasoningEffort") && o["value"] == json!(c[0]))
            });
            expect!(found, "the message runs with {}", show(&selection));
            Ok(())
        },
    );
    steps.step("the next turn runs in (.+)", |world, c, _| {
        let mut mode = String::new();
        for entry in runtime_modes(world).as_array().into_iter().flatten() {
            if text(&entry["label"]).to_lowercase() == c[0].to_lowercase() {
                mode = text(&entry["value"]);
            }
        }
        let before = text(
            &world
                .mc
                .threads
                .get(THREAD)
                .map_or(Value::Null, |t| t["runtimeMode"].clone()),
        );
        // The mode is set before the message, unless the thread already runs in it.
        let mut runs = before;
        for command in send_turn(world)? {
            if command["type"] == json!("thread.runtime-mode.set") {
                runs = text(&command["runtimeMode"]);
            }
        }
        expect!(
            !mode.is_empty() && runs == mode,
            "the turn runs in {runs}, not {mode}"
        );
        Ok(())
    });

    // Plan mode, a beta setting, on a provider that offers it.
    steps.step("plan mode is turned on", |world, _, _| {
        let engine = world.engine().clone();
        hal_c2_shell::controllers::settings::Settings::of(&engine).set(
            &engine,
            "planModeEnabled",
            json!(true),
        );
        world.pump()?;
        world.mc.part::<Catalogue>().providers = codex_and_claude();
        publish_providers(&mut world.mc, codex_and_claude());
        world.sync()
    });

    picker_steps(steps);
}

// The picker itself (qml/HalC2/Bricks/ModelPicker.qml) open over the thread:
// its numbered keys and the keymap's modelPickerOpen
// (navigation/focus.feature, keybinding-customisation.feature).
#[derive(Default)]
struct OpenPicker {
    second: String,
    thread: String,
}

const PICKER_QML: &str = r#"import QtQuick
import HalC2.Shell
import HalC2.Bricks
Item { ModelPicker { objectName: "picker"; y: 500; width: 220
  selectedInstanceId: Shell.state.composer ? Shell.state.composer.selectedInstanceId : null
  selectedModel: Shell.state.composer ? Shell.state.composer.selectedModel : null } }
"#;

fn thread_key(world: &World) -> String {
    world
        .with::<Navigation, _>(|n, _| match n.route() {
            hal_c2_shell::controllers::navigation::Route::Thread(key) => key.clone(),
            _ => String::new(),
        })
        .unwrap_or_default()
}

fn picker_opened(world: &mut World) -> Outcome<bool> {
    let Some(brick) = world.peek_part::<Shown>().and_then(|s| s.0) else {
        return Ok(false);
    };
    let Some(picker) = brick.find(world, "picker")? else {
        return Ok(false);
    };
    match brick.read(world, picker, "popup") {
        QmlValue::Object(popup) => Ok(brick.flag(world, popup, "opened")),
        _ => Ok(false),
    }
}

fn picker_brick(world: &mut World) -> Outcome<(Brick, ljos::prelude::ObjectId)> {
    let brick = crate::brick::shown(world)?;
    let picker = brick.item(world, "picker")?;
    Ok((brick, picker))
}

fn picker_steps(steps: &mut Steps) {
    steps.step("the model picker is open", |world, _, _| {
        if composer_picker::model_picker_shown_open(world)? {
            return Ok(());
        }
        world.mc.projects.insert(PROJECT.into(), project_row());
        world.mc.part::<Catalogue>().providers = codex_and_claude();
        if world.shell_subscriptions() == 0 {
            world.connect()?;
        } else {
            let row = world.mc.projects[PROJECT].clone();
            world.mc.send_row_of(PROJECT, &row, "project");
        }
        world.sync()?;
        publish_providers(&mut world.mc, codex_and_claude());
        // A second thread, which mod+2 would jump to.
        let other = json!({"id": "thread-other", "title": "Other", "projectId": PROJECT,
                           "createdAt": "2026-09-23T08:00:00Z",
                           "updatedAt": "2026-09-23T08:00:00Z"});
        world
            .mc
            .threads
            .insert("thread-other".into(), other.clone());
        world.mc.send_row("thread-other", &other);
        look_at_thread(world, PROJECT)?;
        update_thread(
            world,
            json!({"modelSelection": codex_selection(), "runtimeMode": "full-access"}),
        )?;
        world.wait_for_with(
            |w| composer(w)["selectedModel"] == json!("gpt-5"),
            |w| format!("the composer on gpt-5; it shows {}", show(&composer(w))),
        )?;
        let mut brick = Brick::new(world, PICKER_QML, 800.0, 700.0)?;
        brick.takes_keys = true;
        world.part::<Shown>().0 = Some(brick);
        let (brick, picker) = picker_brick(world)?;
        world
            .engine()
            .invoke_by_name(picker, "open", &[])
            .map_err(|e| crate::harness::Failure(format!("open: {e:?}")))?;
        world.wait_for("the model picker to open", |w| {
            let mut w = w;
            let _ = &mut w;
            picker_popup_open(w, &brick, picker)
        })?;
        let thread = thread_key(world);
        let rows = brick.read(world, picker, "rows");
        let rows = hal_c2_shell::json::from_value(world.engine(), &rows);
        let mut second = String::new();
        for row in rows.as_array().into_iter().flatten() {
            if row["jumpIndex"] == json!(1) && row["kind"] == json!("model") {
                second = text(at(row, "model.slug"));
            }
        }
        expect!(
            !second.is_empty() && second != "gpt-5",
            "the picker lists {}",
            show(&rows)
        );
        let state = world.part::<OpenPicker>();
        state.thread = thread;
        state.second = second;
        // The keyboard is in the picker's search field.
        set_key_focus(
            world,
            Focus {
                terminal: false,
                composer: false,
                editable: true,
            },
        )
    });
    steps.step("the second model is chosen", |world, _, _| {
        let second = world.part::<OpenPicker>().second.clone();
        let want = second.clone();
        world.wait_for_with(
            |w| composer(w)["selectedModel"] == json!(want),
            |w| {
                format!(
                    "{second} to be chosen; the composer shows {}",
                    text(&composer(w)["selectedModel"])
                )
            },
        )?;
        expect!(!picker_opened(world)?, "the picker is still open");
        Ok(())
    });
    steps.step("no thread jump happens", |world, _, _| {
        world.sync()?;
        let thread = world.part::<OpenPicker>().thread.clone();
        expect!(
            thread_key(world) == thread && !key_ran(world, "thread.jump.2"),
            "{}; the route is {}",
            describe_key_press(world),
            show(&world.state("route"))
        );
        Ok(())
    });
    steps.step("the composer has focus and a draft", |world, _, _| {
        open_turn_thread(world)?;
        let target = thread_key(world);
        world.dispatch(
            "composer.text.set",
            json!({"target": target, "text": "Add tax", "cursor": 7}),
        )?;
        world.wait_for("the draft", |w| composer(w)["text"] == json!("Add tax"))?;
        set_key_focus(
            world,
            Focus {
                terminal: false,
                composer: true,
                editable: true,
            },
        )
    });
}

fn picker_popup_open(world: &World, brick: &Brick, picker: ljos::prelude::ObjectId) -> bool {
    match brick.read(world, picker, "popup") {
        QmlValue::Object(popup) => brick.flag(world, popup, "opened"),
        _ => false,
    }
}
