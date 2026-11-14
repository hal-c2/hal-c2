//! Settings → General's background activity (BackgroundActivityController,
//! features/settings/background-service.feature): the custom profile the MC
//! is handed, which HalC2.BackgroundPolicy gates its Git fetches by.
//! desktop-qt's SettingsBackgroundActivitySteps.cpp.

use hal_c2_shell::controllers::settings_scope::SettingsScope;
use ljos::prelude::Value as Q;
use serde_json::{Value, json};

use crate::expect;
use crate::harness::{Failure, Outcome, Steps, show};
use crate::steps::settings::FakeConfig;
use crate::steps::settings_rows::{general_page, page_item};
use crate::world::World;

const ROW: &str = "settingsRow:background-activity";

/// What the MC holds for the row.
fn activity(world: &World) -> Value {
    world
        .mc
        .peek::<FakeConfig>()
        .and_then(|config| config.settings.get("backgroundActivity"))
        .cloned()
        .unwrap_or(Value::Null)
}

fn describe(world: &World) -> String {
    format!(
        "the MC holds {}; the row is {}",
        show(&activity(world)),
        show(&world.state("backgroundActivity"))
    )
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the user chooses advanced background activity for the environment",
        |world, _, _| -> Outcome {
            if world.shell_subscriptions() == 0 {
                world.connect()?;
                world.sync()?;
            }
            world.dispatch("settings.navigate", json!({"to": "/settings/general"}))?;
            let environment = world.mc.environment_id.clone();
            world.wait_for_with(
                move |w| {
                    w.state("backgroundActivity")["open"] == json!(true)
                        && w.state("settingsScope")["editable"] == json!(true)
                        && SettingsScope::of(w.engine())
                            .settings(&environment)
                            .is_some()
                },
                |w| {
                    format!(
                        "the row is {}; the scope is {}",
                        show(&w.state("backgroundActivity")),
                        show(&w.state("settingsScope"))
                    )
                },
            )?;
            let page = general_page(world)?;
            let control = page_item(world, ROW, "control")?;
            let shown = page.text_of(world, control, "displayText");
            expect!(shown == "Balanced", "the row reads \"{shown}\"");
            // Advanced, the last of the list.
            world
                .engine()
                .emit_by_name(control, "activated", &[Q::from(3)])
                .map_err(|e| Failure(format!("activated: {e:?}")))?;
            world.pump()?;
            world.wait_for_with(
                |w| {
                    let held = activity(w);
                    held["profile"] == "custom" && held["baseProfile"] == "balanced"
                },
                describe,
            )
        },
    );
    steps.step(
        "the user sets git fetch to every 2 minutes and turns off pausing when locked",
        |world, _, _| -> Outcome {
            let page = general_page(world)?;
            let seconds = page_item(world, ROW, "fetchSeconds")?;
            world.wait_for_with(
                move |w| page.flag(w, seconds, "visible"),
                |w| format!("the interval to show; {}", describe(w)),
            )?;
            let value = page.text_of(world, seconds, "value");
            expect!(value == "30", "the interval starts at {value}");
            // Typed into the field, as the user does.
            page.write(world, seconds, "value", Q::from(120))?;
            world
                .engine()
                .emit_by_name(seconds, "valueModified", &[])
                .map_err(|e| Failure(format!("valueModified: {e:?}")))?;
            world.pump()?;
            // The second edit builds on what the MC saved of the first.
            world.wait_for_with(
                |w| activity(w)["overrides"]["automaticGitFetchInterval"] == json!(120000),
                describe,
            )?;
            let locked = page_item(world, ROW, "pauseWhenLocked")?;
            expect!(
                page.flag(world, locked, "checked"),
                "pausing when locked starts off"
            );
            // The row lies below the test window's 800 pixels, past where a pointer
            // reaches: the switch toggles as a click on it does.
            page.write(world, locked, "checked", Q::from(false))?;
            world
                .engine()
                .emit_by_name(locked, "toggled", &[])
                .map_err(|e| Failure(format!("toggled: {e:?}")))?;
            world.pump()
        },
    );
    steps.step(
        "the MC fetches git every 2 minutes, even when locked",
        |world, _, _| -> Outcome {
            // What HalC2.BackgroundPolicy reads: a custom profile's overrides over its base.
            world.wait_for_with(
                |w| {
                    let held = activity(w);
                    held["profile"] == "custom"
                        && held["overrides"]["automaticGitFetchInterval"] == json!(120000)
                        && held["overrides"]["pauseWhenHostLocked"] == json!(false)
                },
                describe,
            )?;
            let held = activity(world);
            expect!(
                held["baseProfile"] == "balanced"
                    && held["overrides"].as_object().map(|o| o.len()) == Some(2),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
}
