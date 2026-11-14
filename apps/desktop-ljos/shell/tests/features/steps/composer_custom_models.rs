//! Custom models the user saved for a provider, as the MC lists them after
//! its own (features/composer/model-and-mode.feature). desktop-qt's
//! ComposerCustomModelsSteps.cpp.

use ljos::prelude::Value as QmlValue;
use serde_json::{Value, json};

use crate::harness::{Outcome, Steps, show, text};
use crate::steps::composer_brick::{composer_brick, composer_part};
use crate::steps::settings::{fake_config, publish_providers};
use crate::steps::stream::THREAD;
use crate::world::World;
use crate::{expect, fail};

fn custom_slug(n: usize) -> String {
    format!("custom-model-{n}")
}

fn custom_name(n: usize) -> String {
    format!("Custom Model {n}")
}

fn count_of(c: &[String]) -> Outcome<usize> {
    match c[0].parse() {
        Ok(n) => Ok(n),
        Err(_) => fail!("{} is not a number", c[0]),
    }
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the user has saved (\\d+) custom models for Codex",
        |world, c, _| {
            let count = count_of(c)?;
            let mut list: Vec<Value> = fake_config(&mut world.mc)
                .config
                .get("providers")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            for entry in list.iter_mut() {
                if entry["instanceId"] != json!("codex") {
                    continue;
                }
                let mut models = entry["models"].as_array().cloned().unwrap_or_default();
                for n in 1..=count {
                    models.push(
                        json!({"slug": custom_slug(n), "name": custom_name(n), "isCustom": true}),
                    );
                }
                entry["models"] = Value::Array(models);
            }
            publish_providers(&mut world.mc, list);
            world.sync()
        },
    );
    steps.step("all (\\d+) custom models are offered", |world, c, _| {
        let count = count_of(c)?;
        let brick = composer_brick(world)?;
        let Some(picker) = composer_part(world, "modelPicker")? else {
            fail!("the composer has no model picker");
        };
        let listed = move |w: &World| -> Vec<String> {
            let rows = brick.read(w, picker, "rows");
            hal_c2_shell::json::from_value(w.engine(), &rows)
                .as_array()
                .into_iter()
                .flatten()
                .map(|row| text(&row["model"]["name"]))
                .collect()
        };
        world.wait_for_with(
            move |w| {
                let names = listed(w);
                (1..=count).all(|n| names.contains(&custom_name(n)))
            },
            move |w| {
                format!(
                    "all {count} custom models listed; the picker lists {}",
                    listed(w).join(", ")
                )
            },
        )?;
        // Each one has a row in the list the picker draws, not only an entry
        // in its model.
        let Some(mut at) =
            composer_part(world, &format!("modelPickerRow:codex:{}", custom_slug(1)))?
        else {
            fail!("the picker draws no row for {}", custom_name(1));
        };
        let rows = loop {
            let QmlValue::Object(parent) = brick.read(world, at, "parent") else {
                fail!("the picker draws no list of Codex's models");
            };
            if let (QmlValue::Int(rows), QmlValue::Real(_) | QmlValue::Int(_)) = (
                brick.read(world, parent, "count"),
                brick.read(world, parent, "contentY"),
            ) {
                break rows;
            }
            at = parent;
        };
        expect!(
            rows as usize >= count,
            "the picker's list holds {rows} rows"
        );
        Ok(())
    });
    steps.step(
        "a thread set to the (\\d+)th custom model shows that model as chosen",
        |world, c, _| {
            let n = count_of(c)?;
            let Some(row) = world.mc.threads.get_mut(THREAD) else {
                fail!("there is no thread {THREAD}");
            };
            row["modelSelection"] = json!({"instanceId": "codex", "model": custom_slug(n)});
            let row = row.clone();
            world.mc.send_row(THREAD, &row);
            world.sync()?;
            let brick = composer_brick(world)?;
            let Some(picker) = composer_part(world, "modelPicker")? else {
                fail!("the composer has no model picker");
            };
            world.wait_for_with(
                move |w| {
                    w.state("composer")["selectedModel"] == json!(custom_slug(n))
                        && brick.text_of(w, picker, "triggerTitle") == custom_name(n)
                },
                move |w| {
                    format!(
                        "{} chosen; the composer is {} and reads {}",
                        custom_name(n),
                        show(&w.state("composer")["selectedModel"]),
                        brick.text_of(w, picker, "triggerTitle")
                    )
                },
            )
        },
    );
}
