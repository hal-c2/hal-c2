//! The effort after the model's name, as a word or as bars, as Settings ›
//! Appearance › Effort display says, and the model's options as the
//! composer's controls show them (features/composer/model-and-mode.feature).
//! desktop-qt's ComposerEffortDisplaySteps.cpp and ComposerOptionSteps.cpp.

use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use ljos::prelude::ObjectId;
use serde_json::{Value, json};

use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::{composer_brick, composer_part, editor};
use crate::steps::settings::{fake_config, publish_providers};
use crate::steps::stream::THREAD;
use crate::world::World;
use crate::{expect, fail};

const LEVELS: [(&str, &str); 6] = [
    ("low", "Low"),
    ("medium", "Medium"),
    ("high", "High"),
    ("xhigh", "Extra High"),
    ("max", "Max"),
    ("ultrathink", "Ultrathink"),
];

fn composer(world: &World) -> Json {
    world.state("composer")
}

/// Claude's levels, Max named at the top and Ultrathink carried by the
/// prompt.
fn opus() -> Value {
    let options: Vec<Value> = LEVELS
        .iter()
        .map(|(id, label)| json!({"id": id, "label": label, "isDefault": *id == "medium"}))
        .collect();
    json!({"slug": "claude-opus-5-5", "name": "Claude Opus 5.5",
           "capabilities": {"optionDescriptors": [{
               "id": "effort", "label": "Effort", "type": "select", "options": options,
               "promptInjectedValues": ["ultrathink"], "currentValue": "medium"}]}})
}

fn level_id(label: &str) -> Outcome<&'static str> {
    match LEVELS.iter().find(|(_, l)| *l == label) {
        Some((id, _)) => Ok(id),
        None => fail!("Opus has no {label} effort"),
    }
}

fn part(world: &mut World, object_name: &str) -> Outcome<ObjectId> {
    match composer_part(world, object_name)? {
        Some(item) => Ok(item),
        None => fail!("the composer shows no {object_name}"),
    }
}

fn bars_named(count: &str) -> Option<i64> {
    ["no", "one", "two", "three", "four", "five"]
        .iter()
        .position(|word| *word == count)
        .map(|n| n as i64)
}

fn number(world: &World, brick: &crate::brick::Brick, item: ObjectId, name: &str) -> i64 {
    brick
        .text_of(world, item, name)
        .parse::<f64>()
        .unwrap_or(-1.0) as i64
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("the thread runs on {Q} with (.+) effort"),
        |world, c, _| {
            let effort = level_id(&c[1])?;
            let mut list: Vec<Value> = fake_config(&mut world.mc)
                .config
                .get("providers")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            for entry in &mut list {
                if entry["instanceId"] == json!("claudeAgent") {
                    entry["models"] = json!([opus()]);
                }
            }
            publish_providers(&mut world.mc, list);
            world.sync()?;
            let Some(row) = world.mc.threads.get_mut(THREAD) else {
                fail!("there is no thread {THREAD}");
            };
            row["modelSelection"] = json!({"instanceId": "claudeAgent", "model": "claude-opus-5-5",
                                           "options": [{"id": "effort", "value": effort}]});
            let row = row.clone();
            world.mc.send_row(THREAD, &row);
            world.sync()?;
            world.wait_for_with(
                move |w| {
                    let shown = composer(w);
                    shown["selectedModel"] == json!("claude-opus-5-5")
                        && shown["options"][0]["value"] == json!(effort)
                },
                move |w| {
                    format!(
                        "the composer on Opus at {effort}; it shows {}",
                        show(&composer(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the effort display is set to {Q}"),
        |world, c, _| {
            let display = match c[0].as_str() {
                "Bars" => "bars",
                "Word" => "label",
                other => fail!("Effort display offers Word and Bars, not {other}"),
            };
            let engine = world.engine().clone();
            Settings::of(&engine).set(&engine, "effortDisplay", json!(display));
            world.wait_for_with(
                move |w| composer(w)["effortDisplay"] == json!(display),
                move |w| {
                    format!(
                        "the composer to show the effort as {display}; it shows {}",
                        show(&composer(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the model reads {Q} followed by (.+)"),
        |world, c, _| {
            let brick = composer_brick(world)?;
            let model = part(world, "modelPicker")?;
            let name = c[0].clone();
            world.wait_for_with(
                move |w| brick.text_of(w, model, "triggerTitle") == name,
                move |w| {
                    format!(
                        "the model to read it; it reads {}",
                        brick.text_of(w, model, "triggerTitle")
                    )
                },
            )?;
            // The effort is the model control's, named after the model on
            // its trigger.
            let title = part(world, "modelPickerTitle")?;
            let effort = part(world, "modelPickerEffort")?;
            let bars = part(world, "modelPickerEffortBars")?;
            let left = |world: &World, item| {
                brick
                    .at(world, item, 0.0, 0.0)
                    .map(|(x, _)| x)
                    .unwrap_or(0.0)
            };
            if let Some(word) = c[1].strip_prefix('"').and_then(|w| w.strip_suffix('"')) {
                let word = word.to_owned();
                world.wait_for_with(
                    move |w| {
                        !brick.flag(w, bars, "visible")
                            && brick.flag(w, effort, "visible")
                            && brick.text_of(w, effort, "text") == word
                    },
                    move |w| {
                        format!(
                            "the effort to read it; it reads {} with bars {}",
                            brick.text_of(w, effort, "text"),
                            if brick.flag(w, bars, "visible") {
                                "shown"
                            } else {
                                "hidden"
                            }
                        )
                    },
                )?;
                expect!(
                    left(world, effort) > left(world, title),
                    "the effort is not after the model"
                );
                return Ok(());
            }
            let Some(filled) = c[1].split(' ').next().and_then(bars_named) else {
                fail!("no number of bars in {}", c[1]);
            };
            world.wait_for_with(
                move |w| {
                    brick.flag(w, bars, "visible") && number(w, &brick, bars, "filled") == filled
                },
                move |w| {
                    format!(
                        "{filled} bars filled; {} of {} are, shown: {}",
                        number(w, &brick, bars, "filled"),
                        number(w, &brick, bars, "count"),
                        brick.flag(w, bars, "visible")
                    )
                },
            )?;
            expect!(
                left(world, bars) > left(world, title),
                "the bars are not after the model"
            );
            // One bar a level, Max named apart: low, medium, high and extra
            // high.
            let count = number(world, &brick, bars, "count");
            expect!(count == 4, "the bars count {count} levels");
            Ok(())
        },
    );

    // Choosing another effort takes Ultrathink off the prompt.
    steps.step(
        &format!("the draft reads {Q} without {Q}"),
        |world, c, _| {
            let (brick, item) = editor(world)?;
            let wanted = c[0].clone();
            world.wait_for_with(
                move |w| brick.text_of(w, item, "text") == wanted,
                move |w| {
                    format!(
                        "the draft to read it; it reads \"{}\"",
                        brick.text_of(w, item, "text")
                    )
                },
            )?;
            let shown = brick.text_of(world, item, "text");
            expect!(!shown.contains(&c[1]), "the draft still holds \"{}\"", c[1]);
            Ok(())
        },
    );
    // The provider's default.
    steps.step(
        &format!("the provider's default effort is marked {Q}"),
        |world, c, _| {
            expect!(
                c[0] == "Default",
                "the model control marks the default \"Default\", not \"{}\"",
                c[0]
            );
            let brick = composer_brick(world)?;
            let choices: Vec<String> = composer(world)["options"]
                .as_array()
                .and_then(|options| options.iter().find(|o| o["type"] == json!("select")))
                .and_then(|effort| effort["choices"].as_array())
                .map(|choices| choices.iter().map(|c| text(&c["id"]).to_owned()).collect())
                .unwrap_or_default();
            let (mut marked, mut offered) = (Vec::new(), Vec::new());
            for id in choices {
                let Some(row) = composer_part(world, &format!("modelControlEffort:{id}"))? else {
                    continue;
                };
                if !brick.flag(world, row, "visible") {
                    continue;
                }
                if brick.flag(world, row, "isDefault") {
                    marked.push(id.clone());
                }
                offered.push(id);
            }
            expect!(!offered.is_empty(), "the model control lists no efforts");
            expect!(
                marked == ["medium"],
                "only medium marked \"{}\"; {} are, of {}",
                c[0],
                marked.join(", "),
                offered.join(", ")
            );
            Ok(())
        },
    );
}
