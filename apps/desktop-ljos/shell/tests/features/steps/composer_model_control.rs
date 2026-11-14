//! The model control: the model picker with the chosen model's efforts and
//! options beside it and speed and permissions below, as upstream's one
//! model-and-effort control (features/composer/model-and-mode.feature).
//! desktop-qt's ComposerModelControlSteps.cpp.

use hal_c2_shell::controllers::settings::Settings;
use ljos::item::KeyEvent;
use ljos::prelude::{ObjectId, Value as QmlValue};
use serde_json::{Value, json};

use crate::brick::{Brick, key_event};
use crate::harness::{Failure, Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::{
    composer_brick, composer_item, composer_part, editor, press_in_composer, settle_composer,
    type_in_composer,
};
use crate::steps::composer_defaults::composer_message_received;
use crate::steps::keybinding::press_key;
use crate::steps::settings::publish_providers;
use crate::steps::stream::THREAD;
use crate::steps::turn::open_turn_thread;
use crate::world::World;
use crate::{expect, fail};

/// What the When steps saw after each pick, for the Then that follows.
#[derive(Default)]
struct Picks {
    left: Vec<String>,
    searched: String,
    height: f64,
}

fn composer(world: &World) -> Value {
    world.state("composer")
}

fn choice(id: &str, label: &str) -> Value {
    json!({"id": id, "label": label})
}

fn select(id: &str, label: &str, choices: Vec<Value>, current: &str) -> Value {
    json!({"id": id, "label": label, "type": "select", "options": choices, "currentValue": current})
}

fn toggle(id: &str, label: &str, current: bool) -> Value {
    json!({"id": id, "label": label, "type": "boolean", "currentValue": current})
}

fn model(slug: &str, name: &str, descriptors: Vec<Value>) -> Value {
    json!({"slug": slug, "name": name, "capabilities": {"optionDescriptors": descriptors}})
}

fn provider(id: &str, driver: &str, name: &str, models: Vec<Value>) -> Value {
    json!({"instanceId": id, "driver": driver, "displayName": name, "enabled": true,
           "installed": true, "status": "ready", "models": models})
}

fn efforts(current: &str) -> Vec<Value> {
    vec![
        select(
            "reasoningEffort",
            "Reasoning",
            vec![
                choice("low", "Low"),
                choice("medium", "Medium"),
                choice("high", "High"),
            ],
            current,
        ),
        toggle("fastMode", "Fast mode", false),
    ]
}

fn codex() -> Value {
    provider(
        "codex",
        "codex",
        "Codex",
        vec![
            model("gpt-5.4", "GPT-5.4", efforts("medium")),
            model("gpt-5.5", "GPT-5.5", efforts("high")),
        ],
    )
}

fn claude() -> Value {
    provider(
        "claudeAgent",
        "claudeAgent",
        "Claude",
        vec![model("claude-haiku", "Claude Haiku", vec![])],
    )
}

/// The thread on `slug` of `instance_id` in its default permissions, so
/// the toolbar leaves them to the model control.
fn on_model(world: &mut World, providers: Vec<Value>, instance_id: &str, slug: &str) -> Outcome {
    publish_providers(&mut world.mc, providers);
    open_turn_thread(world)?;
    composer_brick(world)?;
    world.wait_for_with(
        |w| !text(&composer(w)["defaultRuntimeMode"]).is_empty(),
        |w| {
            format!(
                "the composer to know the default permissions; it shows {}",
                show(&composer(w))
            )
        },
    )?;
    let mode = text(&composer(world)["defaultRuntimeMode"]);
    let Some(row) = world.mc.threads.get_mut(THREAD) else {
        fail!("there is no thread {THREAD}");
    };
    row["modelSelection"] = json!({"instanceId": instance_id, "model": slug});
    row["runtimeMode"] = json!(mode);
    let row = row.clone();
    world.mc.send_row(THREAD, &row);
    world.sync()?;
    let slug = slug.to_owned();
    world.wait_for_with(
        |w| {
            let shown = composer(w);
            shown["selectedModel"] == json!(slug)
                && shown["options"].as_array().is_some_and(|o| !o.is_empty())
        },
        |w| format!("the composer on {slug}; it shows {}", show(&composer(w))),
    )
}

fn codex_thread(world: &mut World) -> Outcome {
    on_model(world, vec![codex(), claude()], "codex", "gpt-5.4")
}

fn part(world: &mut World, object_name: &str) -> Outcome<ObjectId> {
    match composer_part(world, object_name)? {
        Some(item) => Ok(item),
        None => fail!("the composer shows no {object_name}"),
    }
}

/// A part of the open model control, once it is on screen.
fn control_part(world: &mut World, object_name: &str) -> Outcome<ObjectId> {
    let brick = composer_brick(world)?;
    let name = object_name.to_owned();
    world.wait_for_with(
        |w| {
            brick
                .find(w, &name)
                .ok()
                .flatten()
                .is_some_and(|item| brick.flag(w, item, "visible"))
        },
        |_| format!("the model control to show {name}"),
    )?;
    part(world, object_name)
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

/// The model control's trigger, its popup, and the brick showing them.
fn picker(world: &mut World) -> Outcome<(Brick, ObjectId, ObjectId)> {
    let brick = composer_brick(world)?;
    let item = part(world, "modelPicker")?;
    let popup = popup_of(&brick, world, item)?;
    Ok((brick, item, popup))
}

fn control_open(world: &mut World) -> Outcome<bool> {
    let (brick, _, popup) = picker(world)?;
    Ok(brick.flag(world, popup, "opened"))
}

fn open_model_control(world: &mut World) -> Outcome<ObjectId> {
    let (brick, item, popup) = picker(world)?;
    expect!(
        brick.flag(world, item, "controlDocked"),
        "the model picker holds no efforts"
    );
    if !brick.flag(world, popup, "visible") {
        click(world, item)?;
    }
    world.wait_for("the model control to open", |w| {
        brick.flag(w, popup, "opened")
    })?;
    Ok(item)
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

/// A key pressed and let go, as a window is given it: a ComboBox picks on
/// the release.
fn tap(world: &mut World, spelt: &str) -> Outcome {
    let event = key_event(spelt)?;
    world.key(&event)?;
    world.key(&KeyEvent::release(event.key).with_modifiers(event.modifiers))?;
    world.sync()
}

fn number(brick: &Brick, world: &World, item: ObjectId, name: &str) -> f64 {
    brick
        .text_of(world, item, name)
        .parse::<f64>()
        .unwrap_or(-1.0)
}

/// `item`'s left, top, right and bottom in the window.
fn rect(world: &World, brick: &Brick, item: ObjectId) -> Outcome<(f64, f64, f64, f64)> {
    let (left, top) = brick.at(world, item, 0.0, 0.0)?;
    let (right, bottom) = brick.at(world, item, 1.0, 1.0)?;
    Ok((left, top, right, bottom))
}

fn option_value(world: &World, id: &str) -> String {
    composer(world)["options"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|option| option["id"] == json!(id))
        .map(|option| text(&option["value"]))
        .unwrap_or_default()
}

fn effort_value(world: &World) -> String {
    composer(world)["options"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|option| option["effort"] == json!(true))
        .map(|option| text(&option["value"]))
        .unwrap_or_default()
}

/// The efforts the open control lists, top to bottom.
fn effort_ids(world: &World) -> Vec<String> {
    let Some(brick) = crate::steps::composer_brick::composer_brick_now(world) else {
        return Vec::new();
    };
    let mut ids: Vec<String> = composer(world)["options"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|option| option["choices"].as_array().cloned().unwrap_or_default())
        .map(|choice| text(&choice["id"]))
        .collect();
    ids.sort();
    ids.dedup();
    let mut shown: Vec<(f64, String)> = ids
        .into_iter()
        .filter_map(|id| {
            let item = brick
                .find(world, &format!("modelControlEffort:{id}"))
                .ok()
                .flatten()?;
            if !brick.flag(world, item, "visible") {
                return None;
            }
            let (_, y) = brick.at(world, item, 0.0, 0.0).ok()?;
            Some((y, id))
        })
        .collect();
    shown.sort_by(|a, b| a.0.total_cmp(&b.0));
    shown.into_iter().map(|(_, id)| id).collect()
}

/// Whether the keyboard is on the item named `name`.
fn focused_on(world: &World, brick: &Brick, name: &str) -> bool {
    brick
        .find(world, name)
        .ok()
        .flatten()
        .is_some_and(|item| brick.flag(world, item, "activeFocus"))
}

/// Whether the keyboard is in the open model control.
fn focus_in_control(world: &World, brick: &Brick) -> bool {
    [
        "modelControl",
        "modelPickerSearch",
        "modelPickerPermissions",
        "modelPickerRow",
        "modelPickerProvider",
    ]
    .iter()
    .any(|prefix| brick.focused_named(world, prefix).unwrap_or(false))
}

fn wait_on_effort(world: &mut World) -> Outcome {
    let (brick, _, popup) = picker(world)?;
    world.wait_for_with(
        |w| {
            brick.flag(w, popup, "opened")
                && focused_on(
                    w,
                    &brick,
                    &format!("modelControlEffort:{}", effort_value(w)),
                )
        },
        |w| {
            format!(
                "the model control open on the {} effort, with the keyboard",
                effort_value(w)
            )
        },
    )
}

fn wait_on_permissions(world: &mut World) -> Outcome {
    let (brick, _, popup) = picker(world)?;
    let permissions = control_part(world, "modelPickerPermissions")?;
    let menu = popup_of(&brick, world, permissions)?;
    world.wait_for("the model control open on its permissions", |w| {
        brick.flag(w, popup, "opened") && brick.flag(w, menu, "opened")
    })
}

fn search_text(world: &mut World) -> Outcome<String> {
    let brick = composer_brick(world)?;
    let search = control_part(world, "modelPickerSearch")?;
    Ok(brick.text_of(world, search, "text"))
}

/// What the picker listed and the steps reached, and the effort the
/// composer named before a send (Ultrathink is typed, not picked).
#[derive(Default)]
struct Offered {
    listed: Vec<String>,
    stepped: Vec<String>,
    shown: String,
}

pub fn register(steps: &mut Steps) {
    // Ultrathink is typed, not picked: what the picker lists and the steps
    // reach.
    steps.step(
        "the user opens the effort choices or steps the effort",
        |world, _, _| {
            let (brick, _, popup) = picker(world)?;
            open_model_control(world)?;
            world.wait_for("the model control to list the efforts", |w| {
                !effort_ids(w).is_empty()
            })?;
            let mut listed = Vec::new();
            for id in effort_ids(world) {
                let row = part(world, &format!("modelControlEffort:{id}"))?;
                listed.push(format!("{id} {}", brick.text_of(world, row, "text")));
            }
            tap(world, "escape")?;
            world.wait_for("the model control to close", move |w| {
                !brick.flag(w, popup, "opened")
            })?;
            // Once round the levels and one more, so a level the step
            // reaches is seen.
            let mut stepped = Vec::new();
            for _ in 0..=listed.len() {
                let before = effort_value(world);
                world.dispatch("composer.effort.step", json!({"direction": 1}))?;
                let from = before.clone();
                world.wait_for_with(
                    move |w| effort_value(w) != from,
                    move |_| format!("a step from {before} to change the effort"),
                )?;
                stepped.push(effort_value(world));
            }
            let offered = world.mc.part::<Offered>();
            offered.listed = listed;
            offered.stepped = stepped;
            Ok(())
        },
    );
    steps.step("Ultrathink is not offered", |world, _, _| {
        let offered = world.mc.part::<Offered>();
        expect!(
            !offered.listed.is_empty()
                && !offered
                    .listed
                    .join("\n")
                    .to_lowercase()
                    .contains("ultrathink"),
            "the effort choices list {}",
            offered.listed.join(", ")
        );
        expect!(
            !offered.stepped.iter().any(|s| s == "ultrathink"),
            "the steps reach {}",
            offered.stepped.join(", ")
        );
        Ok(())
    });
    steps.step(
        &format!("the user types {Q} and sends it"),
        |world, c, _| {
            let brick = composer_brick(world)?;
            let item = composer_item(world)?;
            world
                .engine()
                .invoke_by_name(item, "focusInput", &[])
                .map_err(|e| Failure(format!("focusInput: {e:?}")))?;
            type_in_composer(world, &c[0])?;
            settle_composer(world)?;
            let effort = part(world, "modelPickerEffort")?;
            // The effort follows the typed prompt once the composer
            // publishes it.
            let typed = c[0].clone();
            world.wait_for_with(
                move |w| effort_value(w) == "ultrathink" || !typed.starts_with("Ultrathink:"),
                |w| {
                    format!(
                        "the effort to follow the typed prompt; it is {} under \"{}\"",
                        effort_value(w),
                        text(&composer(w)["text"])
                    )
                },
            )?;
            world.sync()?;
            let shown = brick.text_of(world, effort, "text");
            world.mc.part::<Offered>().shown = shown;
            world
                .engine()
                .invoke_by_name(item, "focusInput", &[])
                .map_err(|e| Failure(format!("focusInput: {e:?}")))?;
            press_in_composer(world, "Enter")?;
            Ok(())
        },
    );
    steps.step(
        &format!("the effort reads {Q} and the turn runs at Ultrathink"),
        |world, c, _| {
            let shown = world.mc.part::<Offered>().shown.clone();
            expect!(shown == c[0], "the effort read {shown} before the send");
            expect!(
                composer_message_received(world, "Ultrathink: design the cache")?,
                "the agent did not receive the typed Ultrathink"
            );
            Ok(())
        },
    );
    // One control: the models, the chosen model's efforts beside them, and
    // speed and permissions below.
    steps.step(
        "the user opens the model control in the composer",
        |world, _, _| {
            codex_thread(world)?;
            open_model_control(world).map(|_| ())
        },
    );
    steps.step(
        "the models are listed with the chosen model's efforts beside them, and speed and permissions below",
        |world, _, _| {
            world.wait_for_with(
                |w| effort_ids(w) == ["low", "medium", "high"],
                |w| {
                    format!(
                        "the model control to list low, medium and high; it lists {}",
                        effort_ids(w).join(", ")
                    )
                },
            )?;
            let brick = composer_brick(world)?;
            let row = control_part(world, "modelPickerRow:codex:gpt-5.4")?;
            let low = control_part(world, "modelControlEffort:low")?;
            let high = control_part(world, "modelControlEffort:high")?;
            let speed = control_part(world, "modelControlSpeed")?;
            let permissions = control_part(world, "modelPickerPermissions")?;
            let list = rect(world, &brick, row)?;
            let first = rect(world, &brick, low)?;
            let last = rect(world, &brick, high)?;
            expect!(first.0 >= list.2, "the efforts are not beside the models");
            let speed = rect(world, &brick, speed)?;
            let permissions = rect(world, &brick, permissions)?;
            expect!(
                speed.1 >= list.3 && permissions.1 >= list.3 && speed.1 >= last.3,
                "speed and permissions are not below the models and efforts"
            );
            let fast = control_part(world, "modelControlSpeed:true")?;
            let reads = brick.text_of(world, fast, "text");
            expect!(reads == "Fast", "the speed offers {reads}, not Fast");
            Ok(())
        },
    );
    steps.step("the user picks a model that has efforts", |world, _, _| {
        let row = control_part(world, "modelPickerRow:codex:gpt-5.5")?;
        click(world, row)?;
        world.wait_for_with(
            |w| composer(w)["selectedModel"] == json!("gpt-5.5"),
            |w| format!("the composer on GPT-5.5; it shows {}", show(&composer(w))),
        )
    });
    steps.step(
        "the picker stays open on that model's current effort",
        |world, _, _| {
            world.wait_for_with(
                |w| effort_value(w) == "high",
                |w| format!("GPT-5.5's effort to be high; it is {}", effort_value(w)),
            )?;
            wait_on_effort(world)
        },
    );
    steps.step("picking a model without efforts chooses it at once", |world, _, _| {
        if composer_part(world, "modelPickerRow:claudeAgent:claude-haiku")?.is_none() {
            let rail = control_part(world, "modelPickerProvider:claudeAgent")?;
            click(world, rail)?;
        }
        let row = control_part(world, "modelPickerRow:claudeAgent:claude-haiku")?;
        click(world, row)?;
        let (brick, _, popup) = picker(world)?;
        world.wait_for_with(
            |w| {
                composer(w)["selectedModel"] == json!("claude-haiku")
                    && !brick.flag(w, popup, "opened")
            },
            |w| {
                format!(
                    "Claude Haiku chosen and the control shut; the composer is on {}, the control {}",
                    text(&composer(w)["selectedModel"]),
                    if brick.flag(w, popup, "opened") { "open" } else { "shut" }
                )
            },
        )
    });

    // The effort and permissions keys open the control at their part.
    steps.step(
        "the user presses (mod\\+shift\\+[ea]) while typing in the composer",
        |world, c, _| {
            codex_thread(world)?;
            expect!(!control_open(world)?, "the model control is open already");
            let (_, input) = editor(world)?;
            click(world, input)?;
            press_key(world, &c[0])
        },
    );
    steps.step(
        "the model control opens on the current effort",
        |world, _, _| wait_on_effort(world),
    );
    steps.step(
        "the model control opens on the permissions",
        |world, _, _| wait_on_permissions(world),
    );
    steps.step(
        "pressing it while the control is open moves there",
        |world, _, _| {
            // Elsewhere in the control first: the search.
            let brick = composer_brick(world)?;
            let permissions = control_part(world, "modelPickerPermissions")?;
            let menu = popup_of(&brick, world, permissions)?;
            let on_permissions = brick.flag(world, menu, "opened");
            if on_permissions {
                tap(world, "escape")?;
            }
            world.wait_for("the permissions menu to close", |w| {
                !brick.flag(w, menu, "opened")
            })?;
            let search = control_part(world, "modelPickerSearch")?;
            click(world, search)?;
            let (_, _, popup) = picker(world)?;
            world.wait_for("the keyboard in the search", |w| {
                brick.flag(w, popup, "opened") && brick.flag(w, search, "activeFocus")
            })?;
            press_key(
                world,
                if on_permissions {
                    "mod+shift+a"
                } else {
                    "mod+shift+e"
                },
            )?;
            if on_permissions {
                wait_on_permissions(world)
            } else {
                wait_on_effort(world)
            }
        },
    );

    // A pick leaves the control open.
    steps.step("the user opened the model control", |world, _, _| {
        codex_thread(world)?;
        open_model_control(world).map(|_| ())
    });
    steps.step(
        "the user picks an effort, turns fast mode on or changes the permissions",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let check = |world: &mut World, pick: &str| -> Outcome {
                world.sync()?;
                if !control_open(world)? || !focus_in_control(world, &brick) {
                    world.part::<Picks>().left.push(pick.to_owned());
                }
                Ok(())
            };
            let high = control_part(world, "modelControlEffort:high")?;
            click(world, high)?;
            world.wait_for_with(
                |w| effort_value(w) == "high",
                |w| format!("the effort to be high; it is {}", effort_value(w)),
            )?;
            check(world, "the effort")?;
            world.wait_for("the keyboard on the picked effort", |w| {
                focused_on(w, &brick, "modelControlEffort:high")
            })?;
            let fast = control_part(world, "modelControlSpeed:true")?;
            click(world, fast)?;
            world.wait_for_with(
                |w| option_value(w, "fastMode") == "true",
                |w| format!("fast mode on; it is {}", option_value(w, "fastMode")),
            )?;
            check(world, "fast mode")?;
            // The permissions from their menu, by the keyboard.
            let permissions = control_part(world, "modelPickerPermissions")?;
            let menu = popup_of(&brick, world, permissions)?;
            let from = number(&brick, world, permissions, "currentIndex") as i64;
            click(world, permissions)?;
            world.wait_for("the permissions menu to open", |w| {
                brick.flag(w, menu, "opened")
            })?;
            tap(world, if from == 0 { "arrowdown" } else { "arrowup" })?;
            tap(world, "enter")?;
            world.wait_for_with(
                |w| {
                    w.mc.commands
                        .iter()
                        .any(|command| command["type"] == json!("thread.runtime-mode.set"))
                },
                |w| {
                    format!(
                        "the permissions change; the MC has {}",
                        show(&Value::Array(w.mc.commands.clone()))
                    )
                },
            )?;
            world.wait_for("the permissions menu to close", |w| {
                !brick.flag(w, menu, "opened")
            })?;
            check(world, "the permissions")
        },
    );
    steps.step(
        "the control stays open with the focus in it",
        |world, _, _| {
            let left = world.part::<Picks>().left.join(", ");
            expect!(
                left.is_empty(),
                "the control closed or lost the keyboard after {left}"
            );
            let brick = composer_brick(world)?;
            expect!(
                control_open(world)? && focus_in_control(world, &brick),
                "the control is shut or the keyboard is not in it"
            );
            Ok(())
        },
    );
    steps.step("Escape or a click outside closes it", |world, _, _| {
        let (brick, item, popup) = picker(world)?;
        tap(world, "escape")?;
        world.wait_for("Escape to close the model control", |w| {
            !brick.flag(w, popup, "opened")
        })?;
        world.wait_for("the keyboard back on the control", |w| {
            brick.flag(w, item, "activeFocus")
        })?;
        open_model_control(world)?;
        // Anywhere the popup and its trigger are not: a small window puts
        // the popup over the editor.
        let content = match brick.read(world, popup, "contentItem") {
            QmlValue::Object(content) => content,
            _ => fail!("the model control has no content"),
        };
        let frame = match brick.read(world, content, "parent") {
            QmlValue::Object(frame) => frame,
            _ => content,
        };
        let shown = rect(world, &brick, frame)?;
        let trigger = rect(world, &brick, item)?;
        let inside = |(l, t, r, b): (f64, f64, f64, f64), (x, y): (f64, f64)| {
            x >= l && x <= r && y >= t && y <= b
        };
        let (width, height) = brick.size(world);
        let Some(outside) = [
            (4.0, 4.0),
            (width - 4.0, 4.0),
            (4.0, height - 4.0),
            (width - 4.0, height - 4.0),
        ]
        .into_iter()
        .find(|&point| !inside(shown, point) && !inside(trigger, point)) else {
            fail!("the popup covers the window");
        };
        world.click_at(outside.0, outside.1)?;
        world.sync()?;
        world.wait_for("a click outside to close the model control", |w| {
            !brick.flag(w, popup, "opened")
        })
    });

    // An ACP agent's own options: its thinking levels are the efforts, each
    // other option one row.
    steps.step(
        "an ACP agent offers a long model name, a session mode, auto-approve and its own thinking levels",
        |world, _, _| {
            let mut thinking = select(
                "thought_level",
                "Thinking",
                vec![
                    choice("low", "Low"),
                    choice("medium", "Medium"),
                    choice("high", "High"),
                ],
                "medium",
            );
            thinking["role"] = json!("reasoning");
            let options = vec![
                select(
                    "mode",
                    "Session Mode",
                    vec![
                        choice("default", "Default"),
                        choice("plan", "Plan"),
                        choice("bypassPermissions", "Bypass Permissions"),
                    ],
                    "bypassPermissions",
                ),
                thinking,
                toggle("autoApprove", "Auto-approve tools", false),
                toggle("fastMode", "Fast mode", true),
                select(
                    "contextWindow",
                    "Context window",
                    vec![choice("200k", "200K"), choice("1m", "1M")],
                    "1m",
                ),
            ];
            let agent = provider(
                "gemini",
                "acpRegistry",
                "Gemini CLI",
                vec![model(
                    "gemini-long",
                    "Gemini 3.1 Pro Preview with the Extended Long Context Window",
                    options,
                )],
            );
            on_model(world, vec![agent, codex()], "gemini", "gemini-long")?;
            // Appearance's Bars, so the levels are drawn.
            let engine = world.engine().clone();
            Settings::of(&engine).set(&engine, "effortDisplay", json!("bars"));
            world.wait_for("the composer to draw the effort as bars", |w| {
                composer(w)["effortDisplay"] == json!("bars")
            })
        },
    );
    steps.step("the user opens the model control", |world, _, _| {
        let item = open_model_control(world)?;
        let brick = composer_brick(world)?;
        let popup = popup_of(&brick, world, item)?;
        let height = number(&brick, world, popup, "height");
        world.part::<Picks>().height = height;
        Ok(())
    });
    steps.step(
        "the agent's thinking levels are the efforts, shown as rising bars",
        |world, _, _| {
            world.wait_for_with(
                |w| effort_ids(w) == ["low", "medium", "high"],
                |w| {
                    format!(
                        "the thinking levels as the efforts; the control lists {}",
                        effort_ids(w).join(", ")
                    )
                },
            )?;
            let brick = composer_brick(world)?;
            let header = control_part(world, "modelControlHeader")?;
            let named = brick.text_of(world, header, "text");
            expect!(
                named == "Thinking",
                "the efforts are named {named}, not Thinking"
            );
            let bars = part(world, "modelPickerEffortBars")?;
            world.wait_for_with(
                |w| {
                    brick.flag(w, bars, "visible")
                        && number(&brick, w, bars, "count") == 3.0
                        && number(&brick, w, bars, "filled") == 2.0
                },
                |w| {
                    format!(
                        "two of three bars filled; {} of {} are",
                        number(&brick, w, bars, "filled"),
                        number(&brick, w, bars, "count")
                    )
                },
            )?;
            // Rising: each bar taller than the one before.
            let mut last = 0.0;
            if let QmlValue::List(children) = brick.read(world, bars, "children") {
                for child in children.iter() {
                    let QmlValue::Object(bar) = child else {
                        continue;
                    };
                    let (width, height) = (
                        number(&brick, world, *bar, "width"),
                        number(&brick, world, *bar, "height"),
                    );
                    if !brick.flag(world, *bar, "visible") || width <= 0.0 || height <= 0.0 {
                        continue;
                    }
                    expect!(height > last, "the bars do not rise");
                    last = height;
                }
            }
            expect!(last > 0.0, "the bars draw nothing");
            Ok(())
        },
    );
    steps.step(
        "each other option is one row naming its value, opening its choices beside it, and an on or off option is a switch",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let mode = control_part(world, "modelControlOption:mode")?;
            let (label, detail) = (
                brick.text_of(world, mode, "text"),
                brick.text_of(world, mode, "detail"),
            );
            expect!(
                label == "Session Mode" && detail == "Bypass Permissions",
                "the mode row reads {label}, {detail}"
            );
            expect!(
                composer_part(world, "modelControlEffort:plan")?.is_none(),
                "the mode's choices are among the efforts"
            );
            click(world, mode)?;
            let plan = control_part(world, "modelControlChoice:mode:plan")?;
            let (row, beside) = (rect(world, &brick, mode)?, rect(world, &brick, plan)?);
            expect!(
                beside.0 >= row.2 - 1.0,
                "the mode's choices do not open beside it"
            );
            click(world, plan)?;
            world.wait_for_with(
                |w| option_value(w, "mode") == "plan",
                |w| format!("the mode set to plan; it is {}", option_value(w, "mode")),
            )?;
            world.wait_for("the mode row to read Plan", |w| {
                brick
                    .find(w, "modelControlOption:mode")
                    .ok()
                    .flatten()
                    .is_some_and(|row| brick.text_of(w, row, "detail") == "Plan")
            })?;
            // Auto-approve is a switch, and so is fast mode left out for the
            // speed.
            let approve = control_part(world, "modelControlSwitch:autoApprove")?;
            expect!(
                brick.flag(world, approve, "switchRow") && !brick.flag(world, approve, "switchOn"),
                "auto-approve is not an off switch"
            );
            click(world, approve)?;
            world.wait_for("auto-approve to turn on", |w| {
                option_value(w, "autoApprove") == "true"
            })?;
            world.wait_for("the switch to show it on", |w| {
                brick
                    .find(w, "modelControlSwitch:autoApprove")
                    .ok()
                    .flatten()
                    .is_some_and(|row| brick.flag(w, row, "switchOn"))
            })?;
            expect!(control_open(world)?, "the picks closed the model control");
            Ok(())
        },
    );
    steps.step(
        "the composer names only the model, cut short when long, with its effort, fast mode and context window",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let title = part(world, "modelPickerTitle")?;
            // The short name: the picker drops the provider's own brand.
            let named = brick.text_of(world, title, "text");
            expect!(
                named.contains("3.1 Pro Preview"),
                "the trigger names {named}"
            );
            world.wait_for("the long name to be cut short", |w| {
                brick.flag(w, title, "truncated")
            })?;
            let bars = part(world, "modelPickerEffortBars")?;
            expect!(brick.flag(world, bars, "visible"), "the trigger shows no effort");
            let fast = part(world, "modelPickerFast")?;
            expect!(brick.flag(world, fast, "visible"), "the trigger shows no fast mode");
            let window = part(world, "modelPickerContextWindow")?;
            expect!(
                brick.text_of(world, window, "text") == "1M",
                "the trigger shows no context window"
            );
            // Nothing else: the mode and auto-approve stay in the control.
            for chip in ["optionPicker:mode", "optionToggle:autoApprove", "effortPicker"] {
                if let Some(item) = composer_part(world, chip)? {
                    expect!(!brick.flag(world, item, "visible"), "the toolbar shows {chip}");
                }
            }
            Ok(())
        },
    );
    steps.step(
        "the picker keeps one height while the user moves between providers",
        |world, _, _| {
            let (brick, _, popup) = picker(world)?;
            let height = world.part::<Picks>().height;
            expect!(height > 0.0, "the control's height was not taken");
            for (instance, slug) in [
                ("codex", "gpt-5.4"),
                ("gemini", "gemini-long"),
                ("codex", "gpt-5.4"),
            ] {
                let rail = control_part(world, &format!("modelPickerProvider:{instance}"))?;
                // The pointer moves to the button first, as Qt does before a
                // press elsewhere: the last button's tooltip, open over this
                // one, closes (hal-c2/ljos-ui#315).
                let (x, y) = brick.at(world, rail, 0.5, 0.5)?;
                world.hover_at(x, y)?;
                world.sync()?;
                click(world, rail)?;
                let row = format!("modelPickerRow:{instance}:{slug}");
                world.wait_for_with(
                    |w| brick.find(w, &row).ok().flatten().is_some(),
                    |_| format!("{instance}'s models listed"),
                )?;
                let now = number(&brick, world, popup, "height");
                expect!(
                    (now - height).abs() < 0.5,
                    "the control is {now} tall on {instance}, not {height}"
                );
            }
            Ok(())
        },
    );

    // An input method's Enter and Escape are its own.
    steps.step(
        "the user is searching the models with a Japanese input method",
        |world, _, _| {
            codex_thread(world)?;
            open_model_control(world)?;
            let brick = composer_brick(world)?;
            let search = control_part(world, "modelPickerSearch")?;
            world.wait_for("the keyboard in the search", |w| {
                brick.flag(w, search, "activeFocus")
            })
        },
    );
    steps.step(
        "the user presses Enter to confirm the composed text, or Escape to cancel it",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let search = control_part(world, "modelPickerSearch")?;
            // げん, confirmed as 現 with Enter.
            world.preedit("げん")?;
            expect!(
                brick.flag(world, search, "inputMethodComposing"),
                "the search is not composing"
            );
            tap(world, "enter")?;
            if !control_open(world)? {
                world.part::<Picks>().left.push("Enter".into());
            }
            world.type_text("現")?;
            // ご, then cancelled with Escape.
            world.preedit("ご")?;
            tap(world, "escape")?;
            if !control_open(world)? {
                world.part::<Picks>().left.push("Escape".into());
            }
            world.preedit("")?;
            world.part::<Picks>().searched = "現".into();
            world.sync()
        },
    );
    steps.step(
        "the picker stays open with the search text as the input method left it",
        |world, _, _| {
            let left = world.part::<Picks>().left.join(", ");
            expect!(left.is_empty(), "the picker closed on {left}");
            expect!(control_open(world)?, "the picker closed");
            let searched = world.part::<Picks>().searched.clone();
            let (brick, item, _) = picker(world)?;
            let search = control_part(world, "modelPickerSearch")?;
            world.wait_for_with(
                |w| {
                    brick.text_of(w, search, "text") == searched
                        && brick.text_of(w, item, "query") == searched
                },
                |w| {
                    format!(
                        "the search to read {searched}; it reads {}",
                        brick.text_of(w, search, "text")
                    )
                },
            )?;
            expect!(
                composer(world)["selectedModel"] == json!("gpt-5.4"),
                "a model was chosen"
            );
            Ok(())
        },
    );
    steps.step(
        "Enter outside composition still chooses the highlighted model, and Escape closes the picker",
        |world, _, _| {
            tap(world, "backspace")?;
            world.type_text("haiku")?;
            world.wait_for_with(
                |w| search_text_now(w) == "haiku",
                |w| format!("the search to read haiku; it reads {}", search_text_now(w)),
            )?;
            tap(world, "enter")?;
            let (brick, _, popup) = picker(world)?;
            world.wait_for_with(
                |w| {
                    composer(w)["selectedModel"] == json!("claude-haiku")
                        && !brick.flag(w, popup, "opened")
                },
                |w| {
                    format!(
                        "Enter to choose Claude Haiku; the composer is on {}",
                        text(&composer(w)["selectedModel"])
                    )
                },
            )?;
            open_model_control(world)?;
            let search = control_part(world, "modelPickerSearch")?;
            world.wait_for("the keyboard in the search", |w| {
                brick.flag(w, search, "activeFocus")
            })?;
            search_text(world)?;
            tap(world, "escape")?;
            world.wait_for("Escape to close the picker", |w| {
                !brick.flag(w, popup, "opened")
            })
        },
    );
}

fn search_text_now(world: &World) -> String {
    let Some(brick) = crate::steps::composer_brick::composer_brick_now(world) else {
        return String::new();
    };
    brick
        .find(world, "modelPickerSearch")
        .ok()
        .flatten()
        .map(|search| brick.text_of(world, search, "text"))
        .unwrap_or_default()
}
