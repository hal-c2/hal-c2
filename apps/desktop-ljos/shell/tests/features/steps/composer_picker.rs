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

/// A model with efforts keeps the model control open on them; one
/// without closes it.
fn closed_or_on_efforts(world: &mut World) -> Outcome {
    let (brick, item) = picker(world)?;
    let popup = popup_of(&brick, world, item)?;
    world.wait_for_with(
        |w| {
            !brick.flag(w, popup, "opened")
                || brick
                    .focused_named(w, "modelControlEffort:")
                    .unwrap_or(false)
        },
        |_| "the picker to close or move to the model's efforts".to_owned(),
    )
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
        // The effort is the model control's.
        "effort picker" => ("composer.effort", "modelPicker"),
        // A new thread names its permissions in the context strip.
        "access mode picker" => ("composer.mode", "contextPermissions"),
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
    steps.step(
        "the model picker closes, or stays open on the model's efforts",
        |world, _, _| closed_or_on_efforts(world),
    );

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
        // The Device tab's Tools drawer.
        if super::device::device_cannot_choose(world, &c[0])? {
            return Ok(());
        }
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

    // A narrow composer: the chips that do not fit fold into its overflow
    // chip's menu (composerOverflow) instead of wrapping the toolbar.
    steps.step(
        "the composer offers its plan and access controls",
        |world, _, _| {
            open_turn_thread(world)?;
            publish_providers(
                &mut world.mc,
                vec![provider(
                    "codex",
                    "Codex",
                    vec![model("gpt-5.4", "GPT-5.4")],
                )],
            );
            // Permissions other than the default, which the toolbar names.
            update_thread(
                world,
                json!({"modelSelection": {"instanceId": "codex", "model": "gpt-5.4"},
                       "runtimeMode": "approval-required"}),
            )?;
            let engine = world.engine().clone();
            let written =
                Settings::of(&engine).write_device(&engine, "planModeEnabled", json!(true));
            expect!(written, "plan mode could not be turned on");
            let brick = composer_brick(world)?;
            let plan = part(world, "planToggle")?;
            let access = part(world, "runtimeModePicker")?;
            world.wait_for_with(
                |w| brick.flag(w, plan, "visible") && brick.flag(w, access, "visible"),
                |w| {
                    format!(
                        "plan and access on the toolbar; the composer shows {}",
                        show(&composer(w))
                    )
                },
            )
        },
    );
    steps.step(
        "the composer is too narrow to show all its controls",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let (_, height) = brick.size(world);
            world.resize(380.0, height)?;
            if let Some(root) = brick.root(world) {
                brick.write(world, root, "width", QmlValue::from(380.0))?;
                brick.write(world, root, "height", QmlValue::from(height))?;
            }
            let overflow = part(world, "composerOverflow")?;
            world.wait_for("the composer to fold a control", |w| {
                brick.flag(w, overflow, "visible")
            })
        },
    );
    steps.step("its toolbar is still one line", |world, _, _| {
        let brick = composer_brick(world)?;
        let toolbar = part(world, "toolbar")?;
        let mut line = shown_chips(&brick, world)?;
        line.push(part(world, "modelPicker")?);
        let send = part(world, "primaryAction")?;
        line.push(send);
        let (_, middle) = brick.at(world, toolbar, 0.0, 0.5)?;
        let (right, _) = brick.at(world, send, 0.0, 0.5)?;
        for item in line {
            let (x, y) = brick.at(world, item, 1.0, 0.5)?;
            let name = brick.text_of(world, item, "objectName");
            expect!((y - middle).abs() < 1.0, "{name} is off the toolbar's line");
            if item != send {
                expect!(x <= right, "{name} runs under Send");
            }
        }
        Ok(())
    });
    steps.step(
        "plan is offered in its menu of further controls",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let plan = part(world, "planToggle")?;
            let shown = shown_chips(&brick, world)?;
            expect!(!shown.contains(&plan), "plan is still on the toolbar");
            let overflow = part(world, "composerOverflow")?;
            click(world, overflow)?;
            world.wait_for_with(
                |w| overflow_rows(&brick, w).iter().any(|r| r == OVERFLOW_PLAN),
                |w| {
                    format!(
                        "plan in the menu; it offers {}",
                        overflow_rows(&brick, w).join(", ")
                    )
                },
            )
        },
    );
    steps.step("the model can still be chosen beside it", |world, _, _| {
        let brick = composer_brick(world)?;
        let picker = part(world, "modelPicker")?;
        expect!(
            brick.flag(world, picker, "visible") && brick.flag(world, picker, "enabled"),
            "the model picker is not on the toolbar"
        );
        Ok(())
    });
    steps.step(
        &format!("the user chooses {Q} in that menu"),
        |world, c, _| {
            expect!(c[0] == "Plan", "the menu has no {} for this step", c[0]);
            let brick = composer_brick(world)?;
            world.wait_for_with(
                |w| overflow_rows(&brick, w).iter().any(|r| r == OVERFLOW_PLAN),
                |w| {
                    format!(
                        "Plan in the menu; it offers {}",
                        overflow_rows(&brick, w).join(", ")
                    )
                },
            )?;
            let item = part(world, OVERFLOW_PLAN)?;
            let label = brick.text_of(world, item, "text");
            expect!(label == c[0], "the row reads {label}");
            click(world, item)
        },
    );

    // Send stands out only with something to send.
    steps.step("the send control cannot be used", |world, _, _| {
        let brick = composer_brick(world)?;
        let action = part(world, "primaryAction")?;
        world.wait_for("Send to be off", |w| {
            !brick.flag(w, action, "enabled") && !brick.flag(w, action, "sendable")
        })
    });
    steps.step(
        "the send control can be used and is the composer's accent",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let action = part(world, "primaryAction")?;
            world.wait_for("Send to be on", |w| {
                brick.flag(w, action, "enabled") && brick.flag(w, action, "sendable")
            })?;
            let fill = match brick.read(world, action, "background") {
                QmlValue::Object(background) => brick.read(world, background, "color"),
                other => fail!("Send has no background: {other:?}"),
            };
            let accent = brick.read(world, action, "accent");
            expect!(fill == accent, "Send is filled {fill:?}, not {accent:?}");
            Ok(())
        },
    );
    // Send is Stop while a turn runs with nothing to send.
    steps.step(
        "the send control is replaced by a control that stops the turn",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let action = part(world, "primaryAction")?;
            world.wait_for("the composer to offer Stop", |w| {
                brick.flag(w, action, "stopMode") && brick.flag(w, action, "enabled")
            })?;
            let glyph = part(world, "stopGlyph")?;
            expect!(
                brick.flag(world, glyph, "visible"),
                "Stop does not show its square"
            );
            Ok(())
        },
    );
    steps.step("the send control is back", |world, _, _| {
        let brick = composer_brick(world)?;
        let action = part(world, "primaryAction")?;
        world.wait_for("the composer to offer Send again", |w| {
            !brick.flag(w, action, "stopMode") && brick.flag(w, action, "sendable")
        })
    });
    // What a screen reader calls it: its Accessible.name, the brick's name.
    steps.step(&format!("the send control is named {Q}"), |world, c, _| {
        let brick = composer_brick(world)?;
        let action = part(world, "primaryAction")?;
        let wanted = c[0].clone();
        world.wait_for_with(
            move |w| brick.text_of(w, action, "name") == wanted,
            move |w| {
                format!(
                    "the send control to be named it; it is named \"{}\"",
                    brick.text_of(w, action, "name")
                )
            },
        )
    });
    steps.step("the running turn has finished", |world, _, _| {
        stream::settle_run(world, "completed", 30)?;
        let Some(row) = world.mc.threads.get_mut(THREAD) else {
            fail!("there is no thread {THREAD}");
        };
        row["activeRunId"] = Value::Null;
        let row = row.clone();
        world.mc.send_row(THREAD, &row);
        world.sync()
    });
    steps.step("the user opens the model's options", |world, _, _| {
        open_picker(world)
    });
    // The effort a prompt's ultrathink holds.
    steps.step(
        &format!("the effort reads {Q} and cannot be changed"),
        |world, c, _| {
            let brick = composer_brick(world)?;
            let shown = part(world, "modelPickerEffort")?;
            let wanted = c[0].clone();
            world.wait_for_with(
                move |w| brick.text_of(w, shown, "text") == wanted,
                move |w| {
                    format!(
                        "the effort to read it; it reads {}",
                        brick.text_of(w, shown, "text")
                    )
                },
            )?;
            open_picker(world)?;
            let effort = effort_option(world);
            let mut rows = Vec::new();
            for choice in effort["choices"].as_array().into_iter().flatten() {
                let name = format!("modelControlEffort:{}", text(&choice["id"]));
                if let Some(row) = composer_part(world, &name)?
                    && brick.flag(world, row, "visible")
                {
                    rows.push(row);
                }
            }
            expect!(!rows.is_empty(), "the model control lists no efforts");
            let enabled = rows
                .iter()
                .filter(|&&row| brick.flag(world, row, "enabled"))
                .count();
            expect!(
                enabled == 0,
                "{enabled} of the effort's {} rows can be chosen",
                rows.len()
            );
            // Not by the controller either.
            world.dispatch(
                "composer.option.set",
                json!({"id": effort["id"].clone(), "value": "high"}),
            )?;
            world.sync()?;
            let now = brick.text_of(world, shown, "text");
            expect!(now == c[0], "the effort changed to {now}");
            Ok(())
        },
    );
    steps.step(
        "the user is told \"(Your prompt contains .+)\"",
        |world, c, _| {
            open_picker(world)?;
            let brick = composer_brick(world)?;
            let Some(note) = composer_part(world, "modelControlEffortNote")? else {
                fail!("the model control has no note on its effort");
            };
            let said = brick.text_of(world, note, "text");
            expect!(said == c[0], "the model control says \"{said}\"");
            Ok(())
        },
    );
    steps.step(
        &format!("a turn is running and the follow-up behaviour is {Q}"),
        |world, c, _| {
            let engine = world.engine().clone();
            Settings::of(&engine).write_device(&engine, "followUpBehavior", json!(c[0]));
            world.pump()
        },
    );
    register_more(steps);
}

/// The composer's effort: its first choice option.
fn effort_option(world: &World) -> Value {
    world.state("composer")["options"]
        .as_array()
        .and_then(|options| {
            options
                .iter()
                .find(|o| o["type"] == json!("select"))
                .cloned()
        })
        .unwrap_or(Value::Null)
}

/// The overflow menu's row for the plan toggle.
const OVERFLOW_PLAN: &str = "composerOverflow:planToggle";

/// The toolbar's chips on screen, by name.
fn shown_chips(brick: &Brick, world: &mut World) -> Outcome<Vec<ObjectId>> {
    let chips = part(world, "toolbarChips")?;
    let children = world.engine().children(chips);
    Ok(children
        .into_iter()
        .filter(|&chip| {
            brick.flag(world, chip, "visible")
                && !brick.text_of(world, chip, "objectName").is_empty()
        })
        .collect())
}

/// The overflow menu's rows by name, a submenu's by its own.
fn overflow_rows(brick: &Brick, world: &World) -> Vec<String> {
    let QmlValue::Object(menu) = brick
        .find(world, "composer")
        .ok()
        .flatten()
        .map_or(QmlValue::Null, |composer| {
            brick.read(world, composer, "overflowMenu")
        })
    else {
        return Vec::new();
    };
    let engine = world.engine();
    let count = match engine.read_by_name(menu, "count") {
        QmlValue::Int(n) => n,
        _ => 0,
    };
    (0..count)
        .map(
            |i| match engine.invoke_by_name(menu, "itemAt", &[QmlValue::Int(i)]) {
                Ok(QmlValue::Object(row)) => match engine.read_by_name(row, "subMenu") {
                    QmlValue::Object(sub) => brick.text_of(world, sub, "objectName"),
                    _ => brick.text_of(world, row, "objectName"),
                },
                _ => String::new(),
            },
        )
        .collect()
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

/// How tall the picker was before its older models unfolded.
#[derive(Default)]
struct PickerHeight(f64);

/// What the efforts read when each model was offered again.
#[derive(Default)]
struct Offered {
    sonnet: String,
}

fn number_of(brick: &Brick, world: &World, item: ObjectId, name: &str) -> f64 {
    brick.text_of(world, item, name).parse().unwrap_or(-1.0)
}

/// The names in quotes in `text`.
fn quoted_list(text: &str) -> Vec<String> {
    text.split('"')
        .skip(1)
        .step_by(2)
        .map(str::to_owned)
        .collect()
}

fn effort_now(world: &World) -> String {
    composer(world)["options"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|option| option["id"] == json!("reasoningEffort"))
        .map(|option| text(&option["value"]))
        .unwrap_or_default()
}

fn pick_at(world: &mut World, instance_id: &str, model: &str, effort: &str) -> Outcome {
    world.dispatch(
        "composer.model.select",
        json!({"instanceId": instance_id, "model": model}),
    )?;
    world.dispatch(
        "composer.option.set",
        json!({"id": "reasoningEffort", "value": effort}),
    )?;
    world.wait_for_with(
        |w| effort_now(w) == effort,
        |w| format!("{effort} to be set; the effort is {}", effort_now(w)),
    )
}

fn select(world: &mut World, instance_id: &str, model: &str) -> Outcome {
    world.dispatch(
        "composer.model.select",
        json!({"instanceId": instance_id, "model": model}),
    )?;
    world.wait_for_with(
        |w| composer(w)["selectedModel"] == json!(model),
        |w| {
            format!(
                "the switch to {model}; the composer shows {}",
                show(&composer(w))
            )
        },
    )
}

fn wait_listed(world: &mut World, what: &str, holds: impl Fn(&[String]) -> bool) -> Outcome {
    let (brick, item) = picker(world)?;
    world.wait_for_with(
        |w| holds(&listed_in(&brick, w, item)),
        |w| {
            format!(
                "{what}; the picker lists {}",
                show(&Value::Array(rows_of(&brick, w, item)))
            )
        },
    )
}

fn with_model(entry: &mut Value, model: Value) {
    let mut models = entry["models"].as_array().cloned().unwrap_or_default();
    models.push(model);
    entry["models"] = Value::Array(models);
}

fn register_more(steps: &mut Steps) {
    // Search order, older models, new marks and the setup offer.
    steps.step("Claude lists (.+) in that order", |world, c, _| {
        let models: Vec<Value> = quoted_list(&c[0])
            .iter()
            .map(|name| model(&name.to_lowercase().replace(' ', "-"), name))
            .collect();
        change_provider(world, "claudeAgent", |entry| {
            entry["models"] = json!(models)
        })
    });
    steps.step("the models are listed as (.+)", |world, c, _| {
        let expected = quoted_list(&c[0]);
        let what = expected.join(", ");
        wait_listed(world, &what, |names| names == expected.as_slice())
    });
    steps.step(
        "a shorter name is not listed ahead of a newer model",
        |world, _, _| {
            let names = listed(world)?;
            let at = |name: &str| names.iter().position(|n| n == name);
            expect!(
                at("Opus 5.5").is_some() && at("Opus 5") > at("Opus 5.5"),
                "the picker lists {}",
                names.join(", ")
            );
            Ok(())
        },
    );
    steps.step("the user looks through (\\w+)'s models", |world, c, _| {
        open_picker(world)?;
        let rail = part(world, &format!("modelPickerProvider:{}", driver_of(&c[0])))?;
        click(world, rail)
    });
    steps.step(
        &format!("Codex lists the legacy model {Q}"),
        |world, c, _| {
            let mut legacy = model(&c[0], &c[0]);
            legacy["isLegacy"] = json!(true);
            change_provider(world, "codex", |entry| with_model(entry, legacy.clone()))
        },
    );
    // Codex's own list, two current models then three older ones, with the
    // picker's height and the "Show more" row it ends on.
    steps.step(
        "Codex lists two current models and three it calls legacy",
        |world, _, _| {
            // The thread's own model stays current, so the picker opens with
            // the older models folded.
            let chosen = composer(world);
            let first = if chosen["selectedInstanceId"] == json!("codex") {
                text(&chosen["selectedModel"])
            } else {
                "gpt-6".to_owned()
            };
            let mut models = vec![model(&first, "GPT-6"), model("gpt-6-mini", "GPT-6 Mini")];
            for slug in ["gpt-4.1", "gpt-4o", "o3"] {
                let mut legacy = model(slug, &slug.to_uppercase());
                legacy["isLegacy"] = json!(true);
                models.push(legacy);
            }
            change_provider(world, "codex", |entry| entry["models"] = json!(models))
        },
    );
    steps.step(
        &format!("the user chooses {Q} at the end of Codex's models"),
        |world, c, _| {
            open_picker(world)?;
            let rail = part(world, "modelPickerProvider:codex")?;
            click(world, rail)?;
            wait_listed(
                world,
                "Codex's two current models and then a row",
                |names| names == ["GPT-6", "GPT-6 Mini", ""],
            )?;
            let (brick, item) = picker(world)?;
            let rows = rows_of(&brick, world, item);
            let last = rows.last().cloned().unwrap_or(Value::Null);
            expect!(
                last["kind"] == json!("legacy"),
                "Codex's list ends on {}",
                show(&last)
            );
            let more = part(world, "modelPickerLegacy:codex")?;
            let reads = brick.text_of(world, more, "text");
            expect!(reads == c[0], "the row reads {reads}, not {}", c[0]);
            let popup = popup_of(&brick, world, item)?;
            let height = number_of(&brick, world, popup, "height");
            world.part::<PickerHeight>().0 = height;
            click(world, more)
        },
    );
    steps.step(
        &format!("the three older models are listed in place and the row reads {Q}"),
        |world, c, _| {
            wait_listed(world, "the older models above the row", |names| {
                names == ["GPT-6", "GPT-6 Mini", "GPT-4.1", "GPT-4O", "O3", ""]
            })?;
            let (brick, _) = picker(world)?;
            let less = part(world, "modelPickerLegacy:codex")?;
            let reads = brick.text_of(world, less, "text");
            expect!(reads == c[0], "the row reads {reads}, not {}", c[0]);
            expect!(picker_open(world)?, "the picker closed");
            Ok(())
        },
    );
    steps.step("the list scrolls inside the picker", |world, _, _| {
        let before = world.part::<PickerHeight>().0;
        let (brick, item) = picker(world)?;
        let popup = popup_of(&brick, world, item)?;
        let after = number_of(&brick, world, popup, "height");
        expect!(
            before > 0.0 && (before - after).abs() < 0.5,
            "the picker was {before} tall and is {after}"
        );
        // The row's list: the first ancestor that flicks.
        let mut at = part(world, "modelPickerLegacy:codex")?;
        let list = loop {
            let QmlValue::Object(parent) = brick.read(world, at, "parent") else {
                fail!("the rows are not in a list");
            };
            if matches!(brick.read(world, parent, "interactive"), QmlValue::Bool(_))
                && matches!(
                    brick.read(world, parent, "contentY"),
                    QmlValue::Real(_) | QmlValue::Int(_)
                )
            {
                break parent;
            }
            at = parent;
        };
        expect!(
            brick.flag(world, list, "clip") && brick.flag(world, list, "interactive"),
            "the list does not scroll in place"
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} is listed without choosing {Q}"),
        |world, c, _| {
            let name = c[0].clone();
            wait_listed(world, &format!("{name} to be listed"), |names| {
                names.contains(&name)
            })
        },
    );
    steps.step(
        &format!("{Q} is listed above Codex's current models without choosing {Q}"),
        |world, c, _| {
            let names = listed(world)?;
            expect!(
                names.first() == Some(&c[0]),
                "the picker lists {}",
                names.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is back among the older models behind {Q}"),
        |world, c, _| {
            let (brick, item) = picker(world)?;
            let name = c[0].clone();
            world.wait_for_with(
                |w| {
                    let rows = rows_of(&brick, w, item);
                    rows.iter().any(|row| row["kind"] == json!("legacy"))
                        && !rows.iter().any(|row| row_name(row) == name)
                },
                |w| {
                    format!(
                        "{} behind the older models; the picker lists {}",
                        c[0],
                        listed_in(&brick, w, item).join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("Codex reports {Q} as a new model"),
        |world, c, _| {
            let mut fresh = model(&c[0], &c[0]);
            fresh["badge"] = json!("new");
            change_provider(world, "codex", |entry| with_model(entry, fresh.clone()))
        },
    );
    steps.step(&format!("{Q} is marked as new"), |world, c, _| {
        let (brick, item) = picker(world)?;
        let marked = rows_of(&brick, world, item)
            .iter()
            .filter(|row| row["model"]["slug"] == json!(c[0]))
            .last()
            .is_some_and(|row| row["model"]["isNew"] == json!(true));
        let row = part(world, &format!("modelPickerRow:codex:{}", c[0]))?;
        expect!(
            marked && brick.flag(world, row, "visible"),
            "{} is not marked as new",
            c[0]
        );
        Ok(())
    });

    // The picker opens on the favourites, or on a started thread's provider.
    steps.step(
        &format!("the user has marked {Q} as a favourite"),
        |world, c, _| {
            let instance_id = instances(world)
                .iter()
                .filter(|entry| {
                    entry["models"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .any(|m| m["slug"] == json!(c[0]))
                })
                .map(|entry| text(&entry["instanceId"]))
                .last();
            let Some(instance_id) = instance_id else {
                fail!("no provider lists {}", c[0]);
            };
            world.dispatch(
                "composer.model.favorite.toggle",
                json!({"instanceId": instance_id, "model": c[0]}),
            )?;
            world.sync()
        },
    );
    steps.step(
        "the favourites are listed first, each under its own provider's name",
        |world, _, _| {
            let (brick, item) = picker(world)?;
            let view = brick.text_of(world, item, "view");
            expect!(view == "favorites", "the picker opens on {view}");
            let shown = rows_of(&brick, world, item);
            expect!(
                !shown.is_empty()
                    && shown.iter().all(|row| {
                        row["model"]["isFavorite"] == json!(true)
                            && !text(&row["instance"]["displayName"]).is_empty()
                    }),
                "the favourites list {}",
                listed_in(&brick, world, item).join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        "in a thread that has already run a turn the picker opens on the thread's provider",
        |world, _, _| {
            let (_, item) = picker(world)?;
            world
                .engine()
                .invoke_by_name(item, "close", &[])
                .map_err(|e| crate::harness::Failure(format!("close: {e:?}")))?;
            world.pump()?;
            update_thread(
                world,
                json!({"latestRunId": "run-0",
                       "runtime": {"status": "ready", "updatedAt": "2026-09-23T09:30:00Z"}}),
            )?;
            open_picker(world)?;
            let (brick, item) = picker(world)?;
            let view = brick.text_of(world, item, "view");
            let wanted = text(&composer(world)["selectedInstanceId"]);
            expect!(view == wanted, "the picker opens on {view}, not {wanted}");
            Ok(())
        },
    );

    // Each model keeps the options it was last given.
    steps.step(
        &format!("the user set {Q} to high effort and {Q} to low effort"),
        |world, c, _| {
            let models = json!([model(&c[0], &c[0]), model(&c[1], &c[1])]);
            change_provider(world, "claudeAgent", |entry| {
                entry["models"] = models.clone()
            })?;
            pick_at(world, "claudeAgent", &c[0], "high")?;
            pick_at(world, "claudeAgent", &c[1], "low")
        },
    );
    steps.step(
        &format!("the user switches from {Q} to {Q} and back"),
        |world, c, _| {
            world.dispatch(
                "composer.model.select",
                json!({"instanceId": "claudeAgent", "model": c[0]}),
            )?;
            select(world, "claudeAgent", &c[1])?;
            world.part::<Offered>().sonnet = effort_now(world);
            select(world, "claudeAgent", &c[0])
        },
    );
    steps.step(
        &format!("{Q} was offered with low effort and {Q} is back at high effort"),
        |world, _, _| {
            let sonnet = world.part::<Offered>().sonnet.clone();
            expect!(sonnet == "low", "sonnet was offered {sonnet}");
            let now = effort_now(world);
            expect!(now == "high", "opus is back at {now}");
            Ok(())
        },
    );

    // A custom model whose slug is also a built-in's alias stays itself.
    steps.step(
        &format!("the Codex account {Q} has the custom model {Q}"),
        |world, c, _| {
            shell_thread(world)?;
            let mut custom = model(&c[1], &c[1]);
            custom["isCustom"] = json!(true);
            let mut list = providers(world);
            list.push(provider("codex_proxy", &c[0], vec![custom]));
            offer(world, list)
        },
    );
    steps.step(
        &format!("the user picks {Q} on {Q} at high effort and sends a message"),
        |world, c, _| {
            pick_at(world, "codex_proxy", &c[0], "high")?;
            world.dispatch(
                "composer.submit",
                json!({"text": "through the proxy", "intent": "foreground"}),
            )?;
            world.sync()
        },
    );
    steps.step(
        &format!(
            "the turn runs on the custom model {Q}, not on a built-in model it is an alias of"
        ),
        |world, c, _| {
            world.sync()?;
            // The thread's turn runs on what its switch (or its message) named.
            let selection = world
                .mc
                .commands
                .iter()
                .rev()
                .find(|command| {
                    (command["type"] == json!("provider.switch")
                        || command["type"] == json!("message.dispatch"))
                        && command.get("modelSelection").is_some()
                })
                .map(|command| command["modelSelection"].clone())
                .unwrap_or(Value::Null);
            expect!(
                selection["instanceId"] == json!("codex_proxy")
                    && selection["model"] == json!(c[0]),
                "the turn ran on {}; the MC has {}",
                show(&selection),
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step(
        &format!("picking {Q} again offers high effort"),
        |world, c, _| {
            world.dispatch(
                "composer.model.select",
                json!({"instanceId": "codex", "model": "gpt-5"}),
            )?;
            world.dispatch(
                "composer.model.select",
                json!({"instanceId": "codex_proxy", "model": c[0]}),
            )?;
            world.wait_for_with(
                |w| effort_now(w) == "high",
                |w| format!("high again; the composer offers {}", effort_now(w)),
            )
        },
    );

    // The name the model button says.
    steps.step(
        &format!("the model manifest names {Q} {Q} for short"),
        |world, c, _| {
            let mut named = model("claude-opus-5.5", &c[0]);
            named["shortName"] = json!(c[1]);
            change_provider(world, "claudeAgent", |entry| {
                entry["models"] = json!([named])
            })?;
            open_picker(world)
        },
    );
    steps.step(
        &format!("the user chooses the (\\w+) model {Q}"),
        |world, c, _| {
            let instance_id = driver_of(&c[0]);
            let mut slug = String::new();
            for ch in c[1].to_lowercase().chars() {
                if ch.is_ascii_alphanumeric() {
                    slug.push(ch);
                } else if !slug.ends_with('-') {
                    slug.push('-');
                }
            }
            let offered = providers(world)
                .iter()
                .any(|entry| entry["instanceId"] == json!(instance_id));
            if offered {
                let models = json!([model(&slug, &c[1])]);
                change_provider(world, &instance_id, |entry| {
                    entry["models"] = models.clone()
                })?;
            } else {
                let mut list = providers(world);
                list.push(provider(&instance_id, &c[0], vec![model(&slug, &c[1])]));
                offer(world, list)?;
            }
            select(world, &instance_id, &slug)?;
            composer_brick(world)?;
            Ok(())
        },
    );
    steps.step(
        &format!("the full name {Q} is shown in its tooltip and in the model picker"),
        |world, c, _| {
            let (brick, item) = picker(world)?;
            let full = brick.text_of(world, item, "triggerFullTitle");
            expect!(full == c[0], "the tooltip names \"{full}\"");
            open_picker(world)?;
            let names = listed(world)?;
            expect!(
                names.contains(&c[0]),
                "the picker lists {}",
                names.join(", ")
            );
            Ok(())
        },
    );
    steps.step(&format!("the model button reads {Q}"), |world, c, _| {
        let (brick, item) = picker(world)?;
        let wanted = c[0].clone();
        world.wait_for_with(
            |w| brick.text_of(w, item, "triggerTitle") == wanted,
            |w| {
                format!(
                    "the button to read \"{}\"; it reads \"{}\"",
                    c[0],
                    brick.text_of(w, item, "triggerTitle")
                )
            },
        )?;
        let title = part(world, "modelPickerTitle")?;
        let reads = brick.text_of(world, title, "text");
        expect!(reads == c[0], "the button reads \"{reads}\"");
        Ok(())
    });

    // A provider that needs setting up.
    steps.step(
        "Cursor is not installed and HAL-C2 can install it",
        |world, _, _| {
            let mut list = providers(world);
            let mut cursor = provider("cursor", "Cursor", vec![model("cursor-auto", "Auto")]);
            cursor["installed"] = json!(false);
            cursor["status"] = json!("error");
            cursor["message"] = json!("Cursor CLI is not installed.");
            cursor["setup"] = json!({"canInstall": true, "canAuthenticate": false});
            list.push(cursor);
            offer(world, list)
        },
    );
    steps.step(
        &format!("the picker says why Cursor cannot be used and offers {Q}"),
        |world, c, _| {
            let brick = composer_brick(world)?;
            let reason = part(world, "modelPickerSetupReason")?;
            let setup = part(world, "modelPickerSetup")?;
            let wanted = c[0].clone();
            world.wait_for_with(
                |w| {
                    brick.flag(w, reason, "visible")
                        && brick.flag(w, setup, "visible")
                        && brick.text_of(w, setup, "text") == wanted
                },
                |w| {
                    format!(
                        "the setup offer; the picker says \"{}\"",
                        brick.text_of(w, reason, "text")
                    )
                },
            )?;
            let said = brick.text_of(world, reason, "text");
            expect!(
                said.contains("Cursor CLI is not installed."),
                "the picker says \"{said}\""
            );
            Ok(())
        },
    );
    steps.step(
        "the picker closes and the setup for Cursor opens",
        |world, _, _| {
            let (brick, item) = picker(world)?;
            let popup = popup_of(&brick, world, item)?;
            world.wait_for("the picker to close", |w| !brick.flag(w, popup, "visible"))?;
            world.wait_for_with(
                |w| {
                    let route = w.state("route");
                    route["kind"] == json!("settings")
                        && route["section"]
                            == json!(hal_c2_shell::controllers::navigation::PROVIDERS_SECTION)
                },
                |w| {
                    format!(
                        "the Providers settings to open; the window shows {}",
                        show(&w.state("route"))
                    )
                },
            )
        },
    );
}
