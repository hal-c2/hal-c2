//! Where the composer names a thread's permissions: on the toolbar only when
//! they differ from the default, in a new thread's context strip, and in the
//! model control's footer (features/composer/model-and-mode.feature).
//! desktop-qt's ComposerPermissionsSteps.cpp.

use ljos::prelude::{ObjectId, Value as QmlValue};
use serde_json::{Value, json};

use crate::brick::Brick;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::{composer_brick, composer_part_now, press_in_composer};
use crate::steps::composer_workspace::{click, int, part, popup_of};
use crate::steps::stream::THREAD;
use crate::world::World;
use crate::{expect, fail};

fn composer(world: &World) -> Value {
    world.state("composer")
}

fn shown(world: &World, object_name: &str) -> bool {
    match (
        composer_part_now(world, object_name),
        composer_brick_now(world),
    ) {
        (Some(item), Some(brick)) => brick.flag(world, item, "visible"),
        _ => false,
    }
}

fn composer_brick_now(world: &World) -> Option<Brick> {
    crate::steps::composer_brick::composer_brick_now(world)
}

/// The composer on screen with the shell's state drawn.
fn drawn(world: &mut World) -> Outcome<Brick> {
    let brick = composer_brick(world)?;
    let item = brick.item(world, "composer")?;
    world.wait_for_with(
        |w| brick.flag(w, item, "ready") && shown(w, "modelPicker"),
        |w| format!("the composer to be ready; it shows {}", show(&composer(w))),
    )?;
    Ok(brick)
}

fn labels(world: &World, brick: &Brick, combo: ObjectId) -> Vec<String> {
    let model = hal_c2_shell::json::from_value(world.engine(), &brick.read(world, combo, "model"));
    model
        .as_array()
        .into_iter()
        .flatten()
        .map(|entry| match entry {
            Value::String(label) => label.clone(),
            other => text(&other["label"]),
        })
        .collect()
}

/// Opens `combo` and chooses its entry `label` with the keyboard.
fn choose(world: &mut World, combo: ObjectId, label: &str) -> Outcome {
    let brick = composer_brick(world)?;
    let name = brick.text_of(world, combo, "objectName");
    let popup = popup_of(&brick, world, combo)?;
    if !brick.flag(world, popup, "opened") {
        click(world, combo)?;
    }
    world.wait_for_with(
        |w| brick.flag(w, popup, "opened"),
        |_| format!("{name} to open"),
    )?;
    let offered = labels(world, &brick, combo);
    let Some(index) = offered.iter().position(|l| l == label) else {
        fail!("{name} offers {}", offered.join(", "));
    };
    let index = index as i64;
    for _ in 0..8 {
        let at = int(&brick, world, combo, "highlightedIndex");
        if at == index {
            break;
        }
        press_in_composer(world, if at < index { "Down" } else { "Up" })?;
    }
    expect!(
        int(&brick, world, combo, "highlightedIndex") == index,
        "{name} cannot reach {label}"
    );
    press_in_composer(world, "Return")?;
    world.sync()
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

/// The MC's row says the thread runs in `mode`.
fn run_in(world: &mut World, mode: &str) -> Outcome {
    let Some(row) = world.mc.threads.get_mut(THREAD) else {
        fail!("the MC has no thread {THREAD}");
    };
    row["runtimeMode"] = json!(mode);
    let row = row.clone();
    world.mc.send_row(THREAD, &row);
    world.sync()
}

pub fn register(steps: &mut Steps) {
    steps.step("the open thread runs in (.+)", |world, c, _| {
        let mode = mode_of(world, &c[0])?;
        run_in(world, &mode)?;
        let key = format!("{}:{THREAD}", world.mc.environment_id);
        world.wait_for_with(
            |w| composer(w)["target"] == json!(key) && composer(w)["runtimeMode"] == json!(mode),
            |w| {
                format!(
                    "the thread in {}; the composer shows {}",
                    c[0],
                    show(&composer(w))
                )
            },
        )
    });
    steps.step(
        "the composer does not name the permissions",
        |world, _, _| {
            drawn(world)?;
            let state = composer(world);
            expect!(
                state["runtimeMode"] == state["defaultRuntimeMode"],
                "the thread's permissions are not the default; the composer shows {}",
                show(&state)
            );
            expect!(
                !shown(world, "runtimeModePicker") && !shown(world, "contextPermissions"),
                "the composer names the permissions"
            );
            Ok(())
        },
    );
    steps.step(
        "the user sets the thread's permissions to (.+) from the effort menu",
        |world, c, _| {
            let brick = drawn(world)?;
            let picker = part(world, "modelPicker")?;
            let popup = popup_of(&brick, world, picker)?;
            if !brick.flag(world, popup, "opened") {
                click(world, picker)?;
            }
            world.wait_for("the model control to open", |w| {
                brick.flag(w, popup, "opened")
            })?;
            let permissions = part(world, "modelPickerPermissions")?;
            choose(world, permissions, &c[0])?;
            // The MC is told, then its row carries the change.
            let mode = mode_of(world, &c[0])?;
            world.wait_for_with(
                |w| {
                    w.mc.commands.iter().any(|command| {
                        command["type"] == json!("thread.runtime-mode.set")
                            && command["runtimeMode"] == json!(mode)
                    })
                },
                |w| {
                    format!(
                        "the access change for {mode}; the MC has {}",
                        w.describe_commands()
                    )
                },
            )?;
            run_in(world, &mode)
        },
    );
    steps.step(
        &format!("the composer names {Q} beside the model"),
        |world, c, _| {
            let brick = composer_brick(world)?;
            world.wait_for_with(
                |w| {
                    composer_part_now(w, "runtimeModePicker").is_some_and(|chip| {
                        brick.flag(w, chip, "visible")
                            && brick.text_of(w, chip, "displayText") == c[0]
                    })
                },
                |w| {
                    format!(
                        "the toolbar to name {}; the composer shows {}",
                        c[0],
                        show(&composer(w))
                    )
                },
            )?;
            let chip = part(world, "runtimeModePicker")?;
            let toolbar = part(world, "toolbarChips")?;
            expect!(
                brick.read(world, chip, "parent") == QmlValue::Object(toolbar),
                "the permissions are not on the toolbar"
            );
            Ok(())
        },
    );

    // A new thread names them in its context strip.
    steps.step(
        &format!("the draft says it will run in {Q}"),
        |world, c, _| {
            let brick = drawn(world)?;
            world.wait_for_with(
                |w| {
                    composer(w)["routeKind"] == json!("draft")
                        && composer_part_now(w, "contextPermissions").is_some_and(|named| {
                            brick.flag(w, named, "visible")
                                && brick.text_of(w, named, "displayText") == c[0]
                        })
                },
                |w| {
                    format!(
                        "the draft to name {}; the composer shows {}",
                        c[0],
                        show(&composer(w))
                    )
                },
            )?;
            expect!(
                !shown(world, "runtimeModePicker"),
                "the toolbar names the permissions too"
            );
            Ok(())
        },
    );
    steps.step(
        "the user chooses the permissions it names",
        |world, _, _| {
            let named = part(world, "contextPermissions")?;
            click(world, named)
        },
    );
    steps.step(
        "the user can pick other permissions for the thread",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let named = part(world, "contextPermissions")?;
            let popup = popup_of(&brick, world, named)?;
            world.wait_for("the permissions menu to open", |w| {
                brick.flag(w, popup, "opened")
            })?;
            let picker = part(world, "modelPicker")?;
            let list = popup_of(&brick, world, picker)?;
            expect!(
                !brick.flag(world, list, "visible"),
                "the model list opened first"
            );
            let offered = labels(world, &brick, named);
            expect!(offered.len() > 1, "the menu offers {}", offered.join(", "));
            choose(world, named, "Supervised")?;
            world.wait_for_with(
                |w| composer(w)["runtimeMode"] == json!("approval-required"),
                |w| {
                    format!(
                        "the draft in Supervised; the composer shows {}",
                        show(&composer(w))
                    )
                },
            )
        },
    );
}
