//! Settings → General's text generation model (TextGenerationController,
//! features/settings/general.feature): what the selected environments'
//! providers offer, and a choice one of them cannot honour. desktop-qt's
//! SettingsTextGenerationSteps.cpp.

use hal_c2_shell::controllers::settings_scope::SettingsScope;
use ljos::prelude::Value as Q;
use serde_json::{Map, Value, json};

use crate::expect;
use crate::harness::{Failure, Outcome, Steps, show};
use crate::steps::settings::{FakeConfig, document_of, fake_config, publish_providers, save_on};
use crate::steps::settings_rows::{general_page, page_item};
use crate::world::World;

const OTHER: &str = "Build box";
const SETTING: &str = "textGenerationModelSelection";
const ROW: &str = "settingsRow:text-generation-model";

fn provider(models: &[&str], writes_text: bool) -> Value {
    let slugs: Vec<Value> = models
        .iter()
        .map(|model| json!({"slug": model.to_lowercase(), "name": model}))
        .collect();
    json!({
        "instanceId": "claudeAgent",
        "displayName": "Claude",
        "enabled": true,
        "installed": true,
        "supportsTextGeneration": writes_text,
        "models": slugs,
    })
}

fn selection(slug: &str) -> Value {
    json!({"instanceId": "claudeAgent", "model": slug})
}

fn row(world: &World) -> Value {
    world.state("textGeneration")
}

fn describe(world: &World) -> String {
    format!("the text generation row is {}", show(&row(world)))
}

fn held(world: &World) -> Value {
    world
        .mc
        .peek::<FakeConfig>()
        .and_then(|config| config.settings.get(SETTING))
        .cloned()
        .unwrap_or(Value::Null)
}

fn held_by_other(world: &World) -> Value {
    world
        .mc
        .peek::<FakeConfig>()
        .and_then(|config| config.documents.get(OTHER))
        .and_then(|document| document.settings.get(SETTING))
        .cloned()
        .unwrap_or(Value::Null)
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the settings scope covers an environment that does not offer the chosen model",
        |world, _, _| -> Outcome {
            // This machine offers Opus and writes with Sonnet; the other offers Sonnet alone.
            let environment = world.mc.environment_id.clone();
            save_on(&mut world.mc, &environment, SETTING, selection("sonnet"));
            publish_providers(&mut world.mc, vec![provider(&["Sonnet", "Opus"], true)]);
            let mut elsewhere = Map::new();
            elsewhere.insert("providers".into(), json!([provider(&["Sonnet"], true)]));
            fake_config(&mut world.mc)
                .elsewhere
                .insert(OTHER.into(), elsewhere);
            document_of(&mut world.mc, OTHER)
                .settings
                .insert(SETTING.into(), selection("sonnet"));
            world.mc.join_named(OTHER);
            world.wait_for_with(
                |w| {
                    let scope = SettingsScope::of(w.engine());
                    scope.targets().len() == 2
                        && scope.settings(OTHER).is_some()
                        && row(w)["models"].as_array().is_some_and(|m| m.len() == 2)
                },
                describe,
            )
        },
    );
    steps.step(
        "the user chooses that text generation model",
        |world, _, _| {
            let page = general_page(world)?;
            let control = page_item(world, ROW, "control")?;
            let shown = page.text_of(world, control, "displayText");
            expect!(
                page.flag(world, control, "visible")
                    && page.flag(world, control, "enabled")
                    && shown == "Claude · Sonnet",
                "the row reads \"{shown}\"; {}",
                describe(world)
            );
            // Opus, the second of the list.
            world
                .engine()
                .emit_by_name(control, "activated", &[Q::from(1)])
                .map_err(|e| Failure(format!("activated: {e:?}")))?;
            world.sync()
        },
    );
    steps.step("the previous model stays selected", |world, _, _| {
        world.sync()?;
        let writes = world
            .mc
            .peek::<FakeConfig>()
            .map_or(0, |config| config.writes.len());
        expect!(
            held(world) == selection("sonnet")
                && held_by_other(world) == selection("sonnet")
                && writes == 0,
            "this machine holds {}",
            show(&held(world))
        );
        let page = general_page(world)?;
        let control = page_item(world, ROW, "control")?;
        let shown = page.text_of(world, control, "displayText");
        expect!(
            shown == "Claude · Sonnet" && page.text_of(world, control, "currentIndex") == "0",
            "the row reads \"{shown}\""
        );
        Ok(())
    });

    steps.step(
        "no enabled provider in the scope can generate text",
        |world, _, _| -> Outcome {
            // One that can is offered first.
            publish_providers(&mut world.mc, vec![provider(&["Sonnet"], true)]);
            world.wait_for_with(
                |w| {
                    let shown = row(w);
                    shown["unavailable"].as_str().is_none_or(str::is_empty)
                        && shown["models"].as_array().is_some_and(|m| !m.is_empty())
                },
                describe,
            )?;
            let page = general_page(world)?;
            let control = page_item(world, ROW, "control")?;
            expect!(
                page.flag(world, control, "visible"),
                "the row offers no model"
            );
            // Then only one that cannot write text, and one that is turned off.
            let mut off = provider(&["GPT"], true);
            off["instanceId"] = json!("codex");
            off["enabled"] = json!(false);
            publish_providers(&mut world.mc, vec![provider(&["Sonnet"], false), off]);
            Ok(())
        },
    );
    steps.step(
        "the text generation model row explains why it cannot be chosen",
        |world, _, _| {
            world.wait_for_with(
                |w| row(w)["unavailable"] == "No text generation providers available.",
                describe,
            )?;
            let page = general_page(world)?;
            let note = page_item(world, ROW, "unavailable")?;
            let control = page_item(world, ROW, "control")?;
            expect!(
                page.flag(world, note, "visible")
                    && page.text_of(world, note, "text")
                        == "No text generation providers available."
                    && !page.flag(world, control, "visible"),
                "the row still offers a model"
            );
            Ok(())
        },
    );
}
