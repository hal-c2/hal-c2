//! The composer's toolbar on screen: the model picker's popup, the plan
//! toggle, the pickers the toolbar shortcuts open and the send/stop button
//! (desktop-qt's ComposerPickerSteps.cpp; features/composer/model-and-mode.feature,
//! qt-scenarios.feature).

use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::settings::Settings;
use ljos::prelude::{ObjectId, Value as QmlValue};
use serde_json::{Value, json};

use crate::brick::Brick;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::{
    composer_brick, composer_brick_shown, composer_part, editor, press_in_composer,
    type_in_composer,
};
use crate::steps::settings::{fake_config, publish_providers};
use crate::steps::stream::{self, FakeStreams, PEER, PEER_ENVIRONMENT, THREAD};
use crate::steps::turn::open_turn_thread;
use crate::steps::workspace::fake_git_repo;
use crate::world::World;
use crate::{expect, fail};

/// The model the scenario expects the next choice to be.
#[derive(Default)]
struct Expected {
    instance_id: String,
    slug: String,
}

fn composer(world: &World) -> Value {
    world.state("composer")
}

fn instances(world: &World) -> Vec<Value> {
    world.state("modelPicker")["instances"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn part(world: &mut World, object_name: &str) -> Outcome<ObjectId> {
    match composer_part(world, object_name)? {
        Some(item) => Ok(item),
        None => fail!("the composer shows no {object_name}"),
    }
}

/// The composer's model picker, with the brick that shows it.
fn picker(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    let brick = composer_brick(world)?;
    let item = part(world, "modelPicker")?;
    Ok((brick, item))
}

fn popup_of(brick: &Brick, world: &World, control: ObjectId) -> Outcome<ObjectId> {
    match brick.read(world, control, "popup") {
        QmlValue::Object(popup) => Ok(popup),
        _ => fail!(
            "{} has no popup",
            brick.text_of(world, control, "objectName")
        ),
    }
}

fn picker_open(world: &mut World) -> Outcome<bool> {
    let (brick, item) = picker(world)?;
    let popup = popup_of(&brick, world, item)?;
    Ok(brick.flag(world, popup, "opened"))
}

fn picker_visible(world: &mut World) -> Outcome<bool> {
    let (brick, item) = picker(world)?;
    let popup = popup_of(&brick, world, item)?;
    Ok(brick.flag(world, popup, "visible"))
}

fn rows_of(brick: &Brick, world: &World, item: ObjectId) -> Vec<Value> {
    let rows = brick.read(world, item, "rows");
    hal_c2_shell::json::from_value(world.engine(), &rows)
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn row_name(row: &Value) -> String {
    text(&row["model"]["name"])
}

fn listed_in(brick: &Brick, world: &World, item: ObjectId) -> Vec<String> {
    rows_of(brick, world, item).iter().map(row_name).collect()
}

fn listed(world: &mut World) -> Outcome<Vec<String>> {
    let (brick, item) = picker(world)?;
    Ok(listed_in(&brick, world, item))
}

fn click(world: &mut World, item: ObjectId) -> Outcome {
    let brick = composer_brick(world)?;
    let visible = brick.flag(world, item, "visible");
    expect!(
        visible,
        "{} is not on screen",
        brick.text_of(world, item, "objectName")
    );
    let (x, y) = brick.at(world, item, 0.5, 0.5)?;
    world.click_at(x, y)?;
    world.sync()
}

/// The picker has opened: the second model it lists is the one "the second
/// model" steps mean.
fn opened(world: &mut World) -> Outcome {
    let (brick, item) = picker(world)?;
    let popup = popup_of(&brick, world, item)?;
    world.wait_for("the model picker to open", |w| {
        brick.flag(w, popup, "opened")
    })?;
    let rows = rows_of(&brick, world, item);
    let second = rows.get(1).cloned().unwrap_or(Value::Null);
    let expected = world.part::<Expected>();
    expected.instance_id = text(&second["instance"]["instanceId"]);
    expected.slug = text(&second["model"]["slug"]);
    Ok(())
}

fn open_picker(world: &mut World) -> Outcome {
    if !picker_visible(world)? {
        let (_, item) = picker(world)?;
        click(world, item)?;
    }
    opened(world)
}

fn toggle_by_shell(world: &mut World) -> Outcome {
    composer_brick(world)?;
    let open = picker_open(world)?;
    let ran = Commands::of(world.engine()).run(world.engine(), "modelPicker.toggle");
    expect!(ran, "modelPicker.toggle is not a command");
    if open {
        let (brick, item) = picker(world)?;
        let popup = popup_of(&brick, world, item)?;
        world.wait_for("the model picker to close", |w| {
            !brick.flag(w, popup, "visible")
        })
    } else {
        opened(world)
    }
}

/// The row of the model named `name`, in whichever provider's list.
fn row_of(world: &mut World, name: &str) -> Outcome<ObjectId> {
    for entry in instances(world) {
        for model in entry["models"].as_array().into_iter().flatten() {
            if model["name"] != json!(name) && model["slug"] != json!(name) {
                continue;
            }
            let instance_id = text(&entry["instanceId"]);
            let row = format!("modelPickerRow:{instance_id}:{}", text(&model["slug"]));
            // Its provider's list, from the rail.
            if composer_part(world, &row)?.is_none() {
                let rail = part(world, &format!("modelPickerProvider:{instance_id}"))?;
                click(world, rail)?;
            }
            let brick = composer_brick(world)?;
            let (_, item) = picker(world)?;
            world.wait_for_with(
                |w| brick.find(w, &row).ok().flatten().is_some(),
                |w| {
                    format!(
                        "{name} to be listed; the picker lists {}",
                        listed_in(&brick, w, item).join(", ")
                    )
                },
            )?;
            return part(world, &row);
        }
    }
    fail!(
        "no provider offers {name}; the picker offers {}",
        show(&Value::Array(instances(world)))
    )
}

fn model(slug: &str, name: &str) -> Value {
    json!({"slug": slug, "name": name,
           "capabilities": {"optionDescriptors": [{
               "id": "reasoningEffort", "label": "Reasoning", "type": "select",
               "options": [{"id": "low", "label": "Low"}, {"id": "high", "label": "High"}],
               "currentValue": "low"}]}})
}

fn provider(id: &str, name: &str, models: Vec<Value>) -> Value {
    json!({"instanceId": id, "driver": id, "displayName": name, "enabled": true,
           "installed": true, "status": "ready", "models": models})
}

fn providers(world: &mut World) -> Vec<Value> {
    fake_config(&mut world.mc)
        .config
        .get("providers")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

/// The MC's providers change and the picker follows.
fn offer(world: &mut World, list: Vec<Value>) -> Outcome {
    publish_providers(&mut world.mc, list.clone());
    world.sync()?;
    let enabled = list
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

fn change_provider(world: &mut World, instance_id: &str, change: impl Fn(&mut Value)) -> Outcome {
    let mut list = providers(world);
    for entry in list.iter_mut() {
        if entry["instanceId"] == json!(instance_id) {
            change(entry);
        }
    }
    offer(world, list)
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

/// A thread on Codex's GPT-5.4 with Codex and Claude offered, unless the
/// scenario already has its thread.
fn shell_thread(world: &mut World) -> Outcome {
    if !world.mc.part::<FakeStreams>().thread.is_empty() {
        return Ok(());
    }
    publish_providers(
        &mut world.mc,
        vec![
            provider(
                "codex",
                "Codex",
                vec![model("gpt-5.4", "GPT-5.4"), model("gpt-5.5", "GPT-5.5")],
            ),
            provider(
                "claudeAgent",
                "Claude",
                vec![
                    model("opus", "Claude Opus"),
                    model("sonnet", "Claude Sonnet"),
                ],
            ),
        ],
    );
    open_turn_thread(world)?;
    update_thread(
        world,
        json!({"modelSelection": {"instanceId": "codex", "model": "gpt-5.4"}}),
    )?;
    world.wait_for_with(
        |w| composer(w)["selectedModel"] == json!("gpt-5.4"),
        |w| format!("the composer on GPT-5.4; it shows {}", show(&composer(w))),
    )
}

/// The thread's session has started on a provider that keeps its model.
fn lock_model(world: &mut World) -> Outcome {
    change_provider(world, "codex", |entry| {
        entry["requiresNewThreadForModelChange"] = json!(true);
    })?;
    update_thread(
        world,
        json!({"latestRunId": "run-0",
               "runtime": {"status": "ready", "updatedAt": "2026-09-23T09:30:00Z"}}),
    )
}

fn driver_of(name: &str) -> String {
    if name == "Claude" {
        "claudeAgent".into()
    } else {
        name.to_lowercase()
    }
}

fn only_listed(brick: &Brick, world: &World, item: ObjectId, driver: &str) -> bool {
    let shown = rows_of(brick, world, item);
    !shown.is_empty()
        && shown
            .iter()
            .all(|row| row["instance"]["driverKind"] == json!(driver))
}

fn next_message(world: &mut World) -> Outcome<Value> {
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
    Ok(world.mc.commands.last().cloned().unwrap_or(Value::Null))
}

fn expect_switched(world: &mut World, instance_id: &str, slug: &str) -> Outcome {
    world.wait_for_with(
        |w| {
            composer(w)["selectedInstanceId"] == json!(instance_id)
                && composer(w)["selectedModel"] == json!(slug)
        },
        |w| {
            format!(
                "the composer on {slug} of {instance_id}; it is on {} of {}",
                text(&composer(w)["selectedModel"]),
                text(&composer(w)["selectedInstanceId"])
            )
        },
    )
}

/// A new thread's draft in a git project two environments have, on a model
/// with an effort: every toolbar control has something to offer.
fn toolbar_draft(world: &mut World) -> Outcome {
    if composer_brick_shown(world) {
        return Ok(());
    }
    let project = "shop";
    let identity = json!({"canonicalKey": "github.com/acme/shop"});
    world.mc.projects.insert(
        project.into(),
        json!({"id": project, "title": project, "workspaceRoot": "/work/shop",
               "scripts": [], "repositoryIdentity": identity}),
    );
    fake_git_repo(
        world,
        "/work/shop",
        &["main", "feature/tax"],
        "main",
        "main",
    );
    publish_providers(
        &mut world.mc,
        vec![provider(
            "codex",
            "Codex",
            vec![model("gpt-5.4", "GPT-5.4")],
        )],
    );
    world.connect()?;
    world.sync()?;
    world.mc.join(PEER, PEER_ENVIRONMENT);
    world.mc.send_rows(
        PEER,
        vec![json!(["shop-copy", "project", {
            "id": "shop-copy", "title": project, "workspaceRoot": "/srv/shop",
            "scripts": [], "repositoryIdentity": identity}])],
    );
    world.sync()?;
    world.open_draft(project)?;
    world.wait_for("the draft to open", |w| {
        w.state("workspace")["isDraft"] == json!(true)
    })?;
    composer_brick(world)?;
    Ok(())
}

fn search(world: &mut World, query: &str) -> Outcome {
    open_picker(world)?;
    type_in_composer(world, query)?;
    let (brick, item) = picker(world)?;
    let read = brick.text_of(world, item, "query");
    expect!(read == query, "the search reads \"{read}\"");
    Ok(())
}

/// The toolbar control a shortcut opens: its command and its object name.
fn control_of(name: &str) -> Outcome<(&'static str, &'static str)> {
    Ok(match name {
        "effort picker" => ("composer.effort", "effortPicker"),
        "access mode picker" => ("composer.mode", "runtimeModePicker"),
        "host picker" => ("composer.host", "hostPicker"),
        "workspace picker" => ("composer.workspace", "envModePicker"),
        "branch picker" => ("composer.branch", "branchPicker"),
        _ => fail!("the toolbar has no {name}"),
    })
}

fn control_popup(world: &mut World, name: &str) -> Outcome<(Brick, ObjectId)> {
    let brick = composer_brick(world)?;
    if name == "branchPicker" {
        return match brick.find(world, name)? {
            Some(popup) => Ok((brick, popup)),
            None => fail!("the composer shows no {name}"),
        };
    }
    let control = part(world, name)?;
    let popup = popup_of(&brick, world, control)?;
    Ok((brick, popup))
}

pub fn register(steps: &mut Steps) {
    // The catalogue (model-and-mode.feature's background has its own).
    steps.step("Claude is enabled", |world, _, _| {
        change_provider(world, "claudeAgent", |entry| entry["enabled"] = json!(true))
    });
    steps.step(
        "the shell lists models from Codex and Claude",
        |world, _, _| shell_thread(world),
    );
    steps.step(
        &format!("the shell has chosen {Q} on (\\w+)"),
        |world, c, _| {
            world.dispatch(
                "composer.model.select",
                json!({"instanceId": driver_of(&c[1]), "model": c[0]}),
            )?;
            world.sync()
        },
    );
    steps.step(
        &format!("the shell lists {Q} as a favourite"),
        |world, c, _| {
            shell_thread(world)?;
            world.dispatch(
                "composer.model.favorite.toggle",
                json!({"instanceId": "claudeAgent", "model": "opus"}),
            )?;
            world.sync()?;
            expect!(c[0] == "Claude Opus", "the steps know Claude Opus only");
            Ok(())
        },
    );
    steps.step(
        &format!("the model {Q} cannot be used because {Q}"),
        |world, _, _| {
            change_provider(world, "codex", |entry| {
                if let Some(models) = entry["models"].as_array_mut() {
                    models.push(model("gpt-5.5", "gpt-5.5"));
                }
            })?;
            lock_model(world)
        },
    );
    steps.step(
        &format!("the shell says {Q} cannot be used because {Q}"),
        |world, _, _| {
            shell_thread(world)?;
            lock_model(world)
        },
    );
    steps.step(
        &format!("the shell lists Cursor as unavailable because {Q}"),
        |world, _, _| {
            shell_thread(world)?;
            let mut list = providers(world);
            let mut cursor = provider("cursor", "Cursor", vec![model("cursor-auto", "Auto")]);
            cursor["installed"] = json!(false);
            cursor["status"] = json!("error");
            cursor["message"] = json!("Not installed.");
            list.push(cursor);
            offer(world, list)
        },
    );

    // Opening and closing.
    steps.step("the user opens the model picker", |world, _, _| {
        open_picker(world)
    });
    steps.step(
        "the shell asks to toggle the model picker(?: again)?",
        |world, _, _| {
            shell_thread(world)?;
            toggle_by_shell(world)
        },
    );
    steps.step(
        "the user presses the model picker shortcut(?: again)?",
        |world, _, _| {
            composer_brick(world)?;
            let open = picker_visible(world)?;
            let took = press_in_composer(world, "mod+shift+m")?;
            expect!(took, "the composer's window did not take the key");
            if !open {
                opened(world)?;
            }
            Ok(())
        },
    );
    steps.step("the model picker is closed", |world, _, _| {
        let (brick, item) = picker(world)?;
        let popup = popup_of(&brick, world, item)?;
        world.wait_for("the model picker to be closed", |w| {
            !brick.flag(w, popup, "visible")
        })
    });

    // Looking through the models.
    steps.step(
        &format!("the user searches the models for {Q}"),
        |world, c, _| search(world, &c[0]),
    );
    steps.step(&format!("the user searches for {Q}"), |world, c, _| {
        search(world, &c[0])
    });
    steps.step("only Claude's models are listed", |world, _, _| {
        let (brick, item) = picker(world)?;
        world.wait_for_with(
            |w| only_listed(&brick, w, item, "claudeAgent"),
            |w| {
                format!(
                    "Claude's models; the picker lists {}",
                    listed_in(&brick, w, item).join(", ")
                )
            },
        )
    });
    steps.step("Claude's models are listed", |world, _, _| {
        let (brick, item) = picker(world)?;
        world.wait_for_with(
            |w| only_listed(&brick, w, item, "claudeAgent") && rows_of(&brick, w, item).len() == 2,
            |w| {
                format!(
                    "Claude's models; the picker lists {}",
                    listed_in(&brick, w, item).join(", ")
                )
            },
        )
    });
    steps.step(
        "the model picker offers a Codex section and a Claude section",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let codex = part(world, "modelPickerProvider:codex")?;
            let claude = part(world, "modelPickerProvider:claudeAgent")?;
            expect!(
                brick.flag(world, codex, "visible") && brick.flag(world, claude, "visible"),
                "the rail does not show both"
            );
            Ok(())
        },
    );
    steps.step(
        "the Codex section lists only Codex's models",
        |world, _, _| {
            let codex = part(world, "modelPickerProvider:codex")?;
            click(world, codex)?;
            let names = listed(world)?;
            expect!(
                names == ["GPT-5.4", "GPT-5.5"],
                "the picker lists {}",
                names.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the model picker shows {Q} marked as a (\\w+) model"),
        |world, c, _| {
            let brick = composer_brick(world)?;
            let title = part(world, "modelPickerTitle")?;
            let icon = part(world, "modelPickerIcon")?;
            let driver = driver_of(&c[1]);
            world.wait_for_with(
                |w| {
                    brick.text_of(w, title, "text") == c[0]
                        && brick.flag(w, icon, "visible")
                        && brick.text_of(w, icon, "driverKind") == driver
                },
                |w| {
                    format!(
                        "the picker to name {}; it names {} of {}",
                        c[0],
                        brick.text_of(w, title, "text"),
                        brick.text_of(w, icon, "driverKind")
                    )
                },
            )
        },
    );
    steps.step(&format!("{Q} cannot be chosen"), |world, c, _| {
        let before = composer(world)["selectedModel"].clone();
        let row = row_of(world, &c[0])?;
        click(world, row)?;
        let now = composer(world)["selectedModel"].clone();
        expect!(
            picker_open(world)? && now == before,
            "the composer is on {}",
            text(&now)
        );
        Ok(())
    });
    steps.step(&format!("Cursor is listed with {Q}"), |world, c, _| {
        let brick = composer_brick(world)?;
        let cursor = part(world, "modelPickerProvider:cursor")?;
        let tooltip = brick.text_of(world, cursor, "tooltip");
        expect!(
            brick.flag(world, cursor, "visible") && tooltip == c[0],
            "Cursor says \"{tooltip}\""
        );
        Ok(())
    });
    steps.step("Cursor cannot be chosen", |world, _, _| {
        let (brick, item) = picker(world)?;
        let view = brick.text_of(world, item, "view");
        let cursor = part(world, "modelPickerProvider:cursor")?;
        click(world, cursor)?;
        let now = brick.text_of(world, item, "view");
        expect!(
            now == view && only_listed(&brick, world, item, "codex"),
            "the picker shows {now}"
        );
        Ok(())
    });

    // Choosing.
    steps.step(
        &format!("the shell is asked to switch to {Q} on (\\w+)"),
        |world, c, _| expect_switched(world, &driver_of(&c[1]), &c[0]),
    );
    steps.step("the shell is not asked to switch models", |world, _, _| {
        world.sync()?;
        let selected = composer(world)["selectedModel"].clone();
        expect!(
            selected == json!("gpt-5.4") && picker_open(world)?,
            "the composer is on {}",
            text(&selected)
        );
        Ok(())
    });
    let down_and_enter = |world: &mut World, _: &Vec<String>, _: &crate::gherkin::Table| {
        press_in_composer(world, "Down")?;
        press_in_composer(world, "Enter")?;
        Ok(())
    };
    steps.step("the user presses Down and then Enter", down_and_enter);
    steps.step(
        "the user moves to the next model and confirms it",
        down_and_enter,
    );
    steps.step(
        "the user presses the shortcut for the second model",
        |world, _, _| {
            press_in_composer(world, "mod+2")?;
            Ok(())
        },
    );
    steps.step(
        "the shell is asked to switch to the second model listed",
        |world, _, _| {
            let (instance_id, slug) = {
                let second = world.part::<Expected>();
                (second.instance_id.clone(), second.slug.clone())
            };
            expect!(!slug.is_empty(), "the picker listed one model");
            expect_switched(world, &instance_id, &slug)?;
            expect!(!picker_open(world)?, "the picker stayed open");
            Ok(())
        },
    );
    steps.step(
        "the next turn runs on (?:that model|the second model listed)",
        |world, _, _| {
            let (instance_id, slug) = {
                let second = world.part::<Expected>();
                (second.instance_id.clone(), second.slug.clone())
            };
            expect!(!slug.is_empty(), "the picker listed one model");
            let selection = next_message(world)?["modelSelection"].clone();
            expect!(
                selection["model"] == json!(slug) && selection["instanceId"] == json!(instance_id),
                "the message runs on {}, not {slug}",
                show(&selection)
            );
            Ok(())
        },
    );
    let next_provider = |world: &mut World, _: &Vec<String>, _: &crate::gherkin::Table| {
        press_in_composer(world, "mod+shift+Down")?;
        Ok(())
    };
    steps.step("the user moves to the next provider", next_provider);
    steps.step("the user presses the next provider shortcut", next_provider);

    // Favourites.
    steps.step(&format!("the favourites list {Q} first"), |world, c, _| {
        let (brick, item) = picker(world)?;
        let view = brick.text_of(world, item, "view");
        let rows = rows_of(&brick, world, item);
        expect!(
            view == "favorites" && rows.first().map(row_name).as_deref() == Some(c[0].as_str()),
            "the {view} view lists {}",
            listed_in(&brick, world, item).join(", ")
        );
        Ok(())
    });
    steps.step(
        &format!("the user removes {Q} from the favourites"),
        |world, _, _| {
            let star = part(world, "modelPickerFavorite:claudeAgent:opus")?;
            click(world, star)
        },
    );
    steps.step(
        &format!("the shell is asked to toggle {Q} on (\\w+) as a favourite"),
        |world, c, _| {
            let instance_id = driver_of(&c[1]);
            let starred = |w: &World| {
                for entry in instances(w) {
                    if entry["instanceId"] != json!(instance_id) {
                        continue;
                    }
                    for listed in entry["models"].as_array().into_iter().flatten() {
                        if listed["slug"] == json!(c[0]) {
                            return listed["isFavorite"] == json!(true);
                        }
                    }
                }
                true
            };
            world.wait_for_with(
                |w| !starred(w),
                |w| {
                    format!(
                        "{} to leave the favourites; the picker lists {}",
                        c[0],
                        show(&Value::Array(instances(w)))
                    )
                },
            )?;
            let kept = Settings::of(world.engine()).device_value("favorites");
            expect!(
                kept.is_none_or(|kept| kept.as_array().is_none_or(Vec::is_empty)),
                "this device still keeps a favourite"
            );
            Ok(())
        },
    );

    // Build and plan.
    let build_mode = |world: &mut World, _: &Vec<String>, _: &crate::gherkin::Table| {
        shell_thread(world)?;
        let engine = world.engine().clone();
        let written = Settings::of(&engine).write_device(&engine, "planModeEnabled", json!(true));
        expect!(written, "plan mode could not be turned on");
        let brick = composer_brick(world)?;
        let toggle = part(world, "planToggle")?;
        world.wait_for("the composer to offer Build and Plan", |w| {
            composer(w)["showInteractionModeToggle"] == json!(true)
                && brick.flag(w, toggle, "visible")
        })?;
        expect!(
            composer(world)["interactionMode"] == json!("default"),
            "the composer is not in build mode"
        );
        Ok(())
    };
    steps.step("the composer is in build mode", build_mode);
    steps.step(
        "the composer is in build mode with keyboard focus",
        build_mode,
    );
    steps.step("the user switches the composer's mode", |world, _, _| {
        let toggle = part(world, "planToggle")?;
        click(world, toggle)
    });
    steps.step("plan mode is requested", |world, _, _| {
        world.wait_for_with(
            |w| composer(w)["interactionMode"] == json!("plan"),
            |w| format!("plan mode; the composer shows {}", show(&composer(w))),
        )?;
        let brick = composer_brick(world)?;
        let toggle = part(world, "planToggle")?;
        expect!(
            brick.flag(world, toggle, "checked"),
            "the toggle does not show Plan"
        );
        Ok(())
    });
    steps.step("the composer keeps the keyboard", |world, _, _| {
        let (brick, item) = editor(world)?;
        expect!(
            brick.flag(world, item, "activeFocus"),
            "the editor lost the keyboard"
        );
        Ok(())
    });

    // Send and stop.
    steps.step("a turn is running", |world, _, _| {
        shell_thread(world)?;
        let run = stream::start_running(world)?;
        update_thread(world, json!({"activeRunId": run, "latestRunId": run}))
    });
    steps.step(
        "the user uses the composer's primary action",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let action = part(world, "primaryAction")?;
            world.wait_for("the primary action to offer Stop", |w| {
                brick.flag(w, action, "stopMode")
            })?;
            click(world, action)
        },
    );
    steps.step("the turn is interrupted", |world, _, _| {
        world.sync()?;
        let run = world.mc.part::<FakeStreams>().run.clone();
        let interrupted = world
            .mc
            .commands
            .iter()
            .find(|command| command["type"] == json!("run.interrupt"))
            .is_some_and(|command| command["runId"] == json!(run));
        expect!(interrupted, "the MC has {}", world.describe_commands());
        Ok(())
    });

    // The toolbar shortcuts (composer.effort, .mode, .host, .workspace, .branch).
    steps.step("the shell asks to open the (.+ picker)", |world, c, _| {
        toolbar_draft(world)?;
        let (command, name) = control_of(&c[0])?;
        let (brick, popup) = control_popup(world, name)?;
        expect!(
            !brick.flag(world, popup, "visible"),
            "the {} is open already",
            c[0]
        );
        let ran = Commands::of(world.engine()).run(world.engine(), command);
        expect!(ran, "{command} is not a command");
        Ok(())
    });
    steps.step("the native (.+ picker) opens", |world, c, _| {
        let (_, name) = control_of(&c[0])?;
        let (brick, popup) = control_popup(world, name)?;
        world.wait_for_with(
            |w| brick.flag(w, popup, "opened"),
            |_| format!("the {} to open", c[0]),
        )
    });
}

/// Whether the picker's own scenario is on screen: it lists (or lacks) the
/// model `name`. False when the composer is not showing.
pub fn model_picker_lists(world: &mut World, name: &str, expected: bool) -> Outcome<bool> {
    if !composer_brick_shown(world) {
        return Ok(false);
    }
    let names = listed(world)?;
    let found = names.iter().any(|entry| entry.contains(name));
    expect!(
        picker_open(world)? && found == expected,
        "the picker lists {}",
        names.join(", ")
    );
    Ok(true)
}

pub fn model_picker_shows(world: &mut World, name: &str, reason: &str) -> Outcome<bool> {
    // The picker's own scenarios: a thread of Stream.h's with providers listed.
    if world.mc.part::<FakeStreams>().thread.is_empty() || instances(world).is_empty() {
        return Ok(false);
    }
    if !composer_brick_shown(world) || !picker_open(world)? {
        open_picker(world)?;
    }
    let row = row_of(world, name)?;
    let brick = composer_brick(world)?;
    let shown = brick.text_of(world, row, "disabledReason");
    expect!(shown.ends_with(reason), "{name} shows \"{shown}\"");
    Ok(true)
}

pub fn model_picker_chooses(world: &mut World, name: &str) -> Outcome<bool> {
    if !composer_brick_shown(world) || !picker_open(world)? {
        return Ok(false);
    }
    let row = row_of(world, name)?;
    click(world, row)?;
    Ok(true)
}

pub fn model_picker_shown_open(world: &mut World) -> Outcome<bool> {
    // As an outcome with the composer on screen; as a precondition it is ModelSteps'.
    if !world.checking || !composer_brick_shown(world) {
        return Ok(false);
    }
    let (brick, item) = picker(world)?;
    let popup = popup_of(&brick, world, item)?;
    world.wait_for("the model picker to be open", |w| {
        brick.flag(w, popup, "opened")
    })?;
    // Open, it has the keyboard for the search.
    let search = part(world, "modelPickerSearch")?;
    expect!(
        brick.flag(world, search, "activeFocus"),
        "the search does not have the keyboard"
    );
    Ok(true)
}
