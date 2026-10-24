//! The provider list of the Providers settings section as
//! features/providers/provider-instances.feature words it: whose providers it
//! shows, what a session that may only view them sees, and each provider's
//! status headline (desktop-qt's ProviderListSteps.cpp). The MC's own
//! environment is this machine; the others are environments it is linked to.

use hal_c2_shell::controllers::navigation::{Navigation, PROVIDERS_SECTION, Route};
use hal_c2_shell::controllers::settings::Settings;
use serde_json::{Map, Value, json};

use super::settings::{fake_config, publish_providers, save_elsewhere};
use crate::brick::{Brick, Shown};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

#[derive(Default)]
struct ProviderList {
    /// The environment the scenario is about, when it is not this machine.
    environment: String,
    /// The instance whose headline the scenario reads.
    instance_id: String,
    hid_model: bool,
}

fn panel(world: &World) -> Value {
    world.state("providerSettings")
}

fn provider(instance_id: &str, name: &str, fields: Value) -> Value {
    let mut entry = json!({
        "instanceId": instance_id,
        "driver": "codex",
        "displayName": name,
        "enabled": true,
        "installed": true,
        "status": "ready",
        "version": "1.0.0",
        "auth": {"status": "unknown"},
        "models": [{"slug": format!("{instance_id}-model"), "name": format!("{name} model")}],
    });
    if let Value::Object(fields) = fields {
        for (key, value) in fields {
            entry[key] = value;
        }
    }
    entry
}

fn link(world: &mut World, environment: &str, providers: Vec<Value>) {
    fake_config(&mut world.mc).elsewhere.insert(
        environment.to_owned(),
        Map::from_iter([("providers".to_owned(), Value::Array(providers))]),
    );
    world.mc.join_named(environment);
}

fn open_panel(world: &mut World) -> Outcome {
    if panel(world)["open"] == json!(true) {
        return Ok(());
    }
    world.with::<Navigation, _>(|n, engine| {
        n.open(engine, Route::Settings(PROVIDERS_SECTION.into()))
    })?;
    world.wait_for_with(
        |w| panel(w)["open"] == json!(true),
        |w| {
            format!(
                "the Providers settings to open; they are {}",
                show(&panel(w))
            )
        },
    )
}

fn pick(world: &mut World, environment: &str) -> Outcome {
    open_panel(world)?;
    world.wait_for_with(
        |w| {
            panel(w)["environments"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|row| row["id"] == json!(environment))
        },
        |w| {
            format!(
                "{environment} to be offered; the panel is {}",
                show(&panel(w))
            )
        },
    )?;
    world.dispatch("providerSettings.environment", json!({"id": environment}))?;
    world.wait_for_with(
        |w| panel(w)["environmentId"] == json!(environment),
        |w| {
            format!(
                "{environment} to be shown; the panel is {}",
                show(&panel(w))
            )
        },
    )
}

fn listed(world: &World) -> Vec<String> {
    panel(world)["providers"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| text(&row["name"]))
        .collect()
}

/// Claude with four models, as the environment lists them.
fn offer_claude(world: &mut World) -> Outcome {
    let models: Vec<Value> = ["Opus", "Sonnet", "Haiku", "Fable"]
        .iter()
        .map(|name| json!({"slug": name.to_lowercase(), "name": name}))
        .collect();
    let mut claude = provider("claudeAgent", "Claude", json!({"models": models}));
    claude["driver"] = json!("claudeAgent");
    publish_providers(&mut world.mc, vec![claude]);
    world.open_draft("shop")?;
    open_panel(world)?;
    world.wait_for_with(
        |w| listed(w) == ["Claude"],
        |w| format!("Claude to be listed; the panel is {}", show(&panel(w))),
    )
}

/// The models the picker offers for Claude, by name, in order.
fn picked(world: &World) -> Vec<String> {
    world.state("modelPicker")["instances"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|instance| instance["instanceId"] == json!("claudeAgent"))
        .flat_map(|instance| instance["models"].as_array().cloned().unwrap_or_default())
        .map(|model| text(&model["name"]))
        .collect()
}

fn hide(world: &mut World, name: &str, hidden: bool) -> Outcome {
    world.dispatch(
        "providerSettings.modelHidden",
        json!({"instanceId": "claudeAgent", "slug": name.to_lowercase(), "hidden": hidden}),
    )
}

/// The model picker offers `name` after the user hid it and showed it again;
/// false when no scenario hid a model, for the steps of other files that
/// share a phrase with this one.
pub fn expect_model_offered(world: &mut World, name: &str) -> Outcome<bool> {
    if !world.mc.part::<ProviderList>().hid_model {
        return Ok(false);
    }
    world.wait_for_with(
        |w| picked(w).iter().any(|offered| offered == name),
        |w| format!("{name} in the picker; it offers {}", picked(w).join(", ")),
    )?;
    Ok(true)
}

pub fn register(steps: &mut Steps) {
    // Whose providers.
    steps.step(
        &format!("the user is connected to the environments {Q} and {Q}"),
        |world, c, _| {
            for environment in [&c[0], &c[1]] {
                link(
                    world,
                    environment,
                    vec![provider(
                        "codex",
                        &format!("Codex on {environment}"),
                        Value::Null,
                    )],
                );
            }
            world.sync()
        },
    );
    steps.step(
        &format!("the user picks {Q} in provider settings"),
        |world, c, _| pick(world, &c[0]),
    );
    steps.step(&format!("the providers of {Q} are shown"), |world, c, _| {
        world.wait_for_with(
            |w| {
                panel(w)["status"] == json!("ready")
                    && panel(w)["environmentId"] == json!(c[0])
                    && listed(w) == [format!("Codex on {}", c[0])]
            },
            |w| {
                format!(
                    "only the providers of {}; the panel is {}",
                    c[0],
                    show(&panel(w))
                )
            },
        )
    });
    steps.step(
        "the user is told to reconnect that device or pick another one",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    panel(w)["status"] == json!("offline")
                        && panel(w)["description"]
                            == json!("Reconnect this device to set up its provider, or select another device.")
                        && panel(w)["providers"]
                            .as_array()
                            .is_none_or(|providers| providers.is_empty())
                },
                |w| {
                    format!(
                        "the panel to ask for a reconnect; it is {}",
                        show(&panel(w))
                    )
                },
            )
        },
    );
    steps.step("the user opens provider settings", |world, _, _| {
        let environment = world.mc.part::<ProviderList>().environment.clone();
        if environment.is_empty() {
            open_panel(world)
        } else {
            pick(world, &environment)
        }
    });

    // Which models this device's picker offers (providers/models.feature).
    steps.step(&format!("the user hid the model {Q}"), |world, c, _| {
        offer_claude(world)?;
        world.mc.part::<ProviderList>().hid_model = true;
        hide(world, &c[0], true)?;
        world.wait_for_with(
            |w| !picked(w).contains(&c[0]),
            |w| {
                format!(
                    "{} to leave the picker; it offers {}",
                    c[0],
                    picked(w).join(", ")
                )
            },
        )
    });
    steps.step(
        &format!("the user shows {Q} in the picker again"),
        |world, c, _| {
            // From the provider's card, where the hidden model is still listed.
            let brick = Brick::new(
                world,
                "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n\
                 ProviderModelList { width: 500; provider: Shell.state.providerSettings.providers[0] }\n",
                500.0,
                300.0,
            )?;
            world.part::<Shown>().0 = Some(brick);
            expect!(
                brick.shows(world, "Show")?,
                "the card does not offer to show a model"
            );
            brick.click(world, &format!("modelHidden-{}", c[0].to_lowercase()))
        },
    );
    steps.step(
        "the user favourites one model, hides another and moves a third up",
        |world, _, _| {
            offer_claude(world)?;
            world.dispatch(
                "composer.model.favorite.toggle",
                json!({"instanceId": "claudeAgent", "model": "sonnet"}),
            )?;
            hide(world, "Haiku", true)?;
            // Fable is listed last: up past Haiku, Sonnet and Opus.
            for _ in 0..3 {
                world.dispatch(
                    "providerSettings.modelMove",
                    json!({"instanceId": "claudeAgent", "slug": "fable", "by": -1}),
                )?;
            }
            Ok(())
        },
    );
    steps.step(
        "the model picker on this device reflects those choices",
        |world, _, _| {
            // The favourite leads, the one moved up comes before Opus, and Haiku is gone.
            let expected = ["Sonnet", "Fable", "Opus"];
            world.wait_for_with(
                |w| picked(w) == expected,
                |w| {
                    format!(
                        "the picker to offer {}; it offers {}",
                        expected.join(", "),
                        picked(w).join(", ")
                    )
                },
            )?;
            // And they outlive the app.
            world.restart()?;
            world.connect()?;
            world.sync()?;
            let providers = fake_config(&mut world.mc)
                .config
                .get("providers")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            publish_providers(&mut world.mc, providers);
            world.wait_for_with(
                |w| picked(w) == expected,
                |w| {
                    format!(
                        "the same after a restart; the picker offers {}",
                        picked(w).join(", ")
                    )
                },
            )
        },
    );
    steps.step("other devices keep their own choices", |world, _, _| {
        // Kept in this device's preferences: nothing of them was saved on the environment.
        for write in fake_config(&mut world.mc).writes.clone() {
            let saved = write.to_string();
            expect!(
                !saved.contains("hiddenModels")
                    && !saved.contains("favorites")
                    && !saved.contains("modelOrder"),
                "the choices were saved on the environment: {saved}"
            );
        }
        let device = Settings::of(world.engine()).device();
        expect!(
            device.contains_key("providerModelPreferences") && device.contains_key("favorites"),
            "this device keeps {}",
            show(&Value::Object(device))
        );
        Ok(())
    });

    // Status headlines.
    steps.step(
        "a provider that is (not checked yet|disabled|not installed|signed out|failing its startup checks|signed in)",
        |world, c, _| {
            let instance_id = "codex_work";
            world.mc.part::<ProviderList>().instance_id = instance_id.into();
            // Configured here, as every state is; what the environment reports of it differs.
            let mut instances = at(
                &Value::Object(fake_config(&mut world.mc).settings.clone()),
                "providerInstances",
            )
            .as_object()
            .cloned()
            .unwrap_or_default();
            instances.insert(
                instance_id.into(),
                json!({
                    "driver": "codex",
                    "displayName": "Codex Work",
                    "enabled": c[0] != "disabled",
                }),
            );
            save_elsewhere(
                &mut world.mc,
                "providerInstances",
                Value::Object(instances),
                false,
            );
            let fields = match c[0].as_str() {
                "not checked yet" => return Ok(()),
                "disabled" => json!({"enabled": false, "status": "disabled"}),
                "not installed" => json!({"installed": false, "status": "error"}),
                "signed out" => {
                    json!({"auth": {"status": "unauthenticated"}, "status": "error"})
                }
                "failing its startup checks" => json!({"status": "error"}),
                _ => json!({"auth": {"status": "authenticated"}}),
            };
            publish_providers(
                &mut world.mc,
                vec![provider(instance_id, "Codex Work", fields)],
            );
            Ok(())
        },
    );
    steps.step("the user opens the provider list", |world, _, _| {
        open_panel(world)?;
        world.wait_for_with(
            |w| panel(w)["status"] == json!("ready"),
            |w| {
                format!(
                    "the providers to be ready; the panel is {}",
                    show(&panel(w))
                )
            },
        )
    });
    steps.step(&format!("the provider reads {Q}"), |world, c, _| {
        let instance_id = world.mc.part::<ProviderList>().instance_id.clone();
        if instance_id.is_empty() {
            fail!("a provider to have been set up");
        }
        let headline = |w: &World| {
            panel(w)["providers"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|row| row["instanceId"] == json!(instance_id))
                .map(|row| text(&row["headline"]))
                .next_back()
                .unwrap_or_default()
        };
        world.wait_for_with(
            |w| headline(w) == c[0],
            |w| {
                format!(
                    "{instance_id} to read \"{}\"; it reads \"{}\" in {}",
                    c[0],
                    headline(w),
                    show(&panel(w))
                )
            },
        )
    });
}
