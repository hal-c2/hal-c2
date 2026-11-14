//! Where settings apply, as the settings pages show and honour it: the scope
//! sentence, a project's overrides, this device's own preferences, and values
//! the environments disagree on (features/settings/scopes-and-inheritance.feature,
//! settings/search-and-navigation.feature). desktop-qt's SettingsScopeSteps.cpp.

use std::collections::HashMap;

use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::settings_scope::SettingsScope;
use serde_json::{Map, Value, json};

use crate::brick;
use crate::expect;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::project_settings::expect_toast;
use crate::steps::settings::{FakeConfig, document_of, fake_config, publish_providers, save_on};
use crate::steps::settings_rows::{choose_row, page_item, row_shown};
use crate::steps::settings_search::settings_shell;
use crate::world::World;

const MODEL: &str = "defaultModelSelection";
const PROVIDER: &str = "claudeAgent";
const DEVICE_PREFERENCE: &str = "timestampFormat";
const ENVIRONMENT_WIDE: &str = "autoResumeLimitedThreads";

#[derive(Default)]
struct Scoped {
    project: String,
}

/// The writes counted when the user acted.
#[derive(Default)]
struct Mark(usize);

fn scope(world: &World) -> Value {
    world.state("settingsScope")
}

fn project_panel(world: &World) -> Value {
    world.state("projectSettings")
}

fn model_row(world: &World) -> Value {
    project_panel(world)["model"].clone()
}

fn selection(slug: &str) -> Value {
    json!({"instanceId": PROVIDER, "model": slug})
}

fn provider(models: &[&str]) -> Value {
    let slugs: Vec<Value> = models
        .iter()
        .map(|m| json!({"slug": m.to_lowercase(), "name": m}))
        .collect();
    json!({"instanceId": PROVIDER, "displayName": "Claude", "enabled": true,
           "installed": true, "models": slugs})
}

/// The models each environment's provider offers, before the settings follow it.
fn offer(world: &mut World, environment: &str, models: &[&str]) {
    let providers = vec![provider(models)];
    if environment == world.mc.environment_id {
        publish_providers(&mut world.mc, providers);
        return;
    }
    let fake = fake_config(&mut world.mc);
    fake.elsewhere
        .entry(environment.to_owned())
        .or_default()
        .insert("providers".into(), Value::Array(providers));
}

fn offer_everywhere(world: &mut World, models: &[&str]) {
    if fake_config(&mut world.mc).config.contains_key("providers") {
        return;
    }
    let here = world.mc.environment_id.clone();
    offer(world, &here, models);
    for environment in world.mc.members.clone() {
        offer(world, &environment, models);
    }
}

fn settings_of<'a>(world: &'a mut World, environment: &str) -> &'a mut Map<String, Value> {
    if environment == world.mc.environment_id {
        &mut fake_config(&mut world.mc).settings
    } else {
        &mut document_of(&mut world.mc, environment).settings
    }
}

/// The project's checkout on a linked machine, as the feature's background names it.
fn checkout_on(project: &str, environment: &str) -> String {
    format!("{project}-{environment}")
}

/// The environment's saved settings, as the fake MC holds them.
fn held(world: &World, environment: &str) -> Map<String, Value> {
    let Some(fake) = world.mc.peek::<FakeConfig>() else {
        return Map::new();
    };
    if environment == world.mc.environment_id {
        fake.settings.clone()
    } else {
        fake.documents
            .get(environment)
            .map(|document| document.settings.clone())
            .unwrap_or_default()
    }
}

fn override_on(world: &World, project: &str, environment: &str) -> Option<Value> {
    SettingsScope::override_of(
        &held(world, environment),
        &checkout_on(project, environment),
        MODEL,
    )
}

fn set_override(world: &mut World, project: &str, environment: &str, value: Option<Value>) {
    let id = checkout_on(project, environment);
    let settings = settings_of(world, environment);
    *settings = SettingsScope::with_override(std::mem::take(settings), &id, MODEL, value);
}

fn describe_documents(world: &World) -> String {
    let mut lines = vec![format!(
        "this machine holds {}",
        show(&Value::Object(held(world, &world.mc.environment_id)))
    )];
    for environment in &world.mc.members {
        lines.push(format!(
            "{environment} holds {}",
            show(&Value::Object(held(world, environment)))
        ));
    }
    lines.join("; ")
}

fn writes(world: &World) -> usize {
    world.mc.peek::<FakeConfig>().map_or(0, |fake| {
        fake.writes.len()
            + fake
                .documents
                .values()
                .map(|document| document.version as usize)
                .sum::<usize>()
    })
}

fn connect_if_needed(world: &mut World) -> Outcome {
    if world.shell_subscriptions() > 0 {
        return Ok(());
    }
    world.connect()?;
    world.sync()
}

fn open_section(world: &mut World, section: &str) -> Outcome {
    connect_if_needed(world)?;
    world.dispatch("settings.navigate", json!({"to": section}))?;
    let section = section.to_owned();
    let wanted = section.clone();
    world.wait_for_with(
        move |w| at(&w.state("route"), "section") == &Value::String(wanted.clone()),
        move |w| format!("the route is {}", show(&w.state("route"))),
    )
}

/// Picks the project in the scope sentence's list, as its picker does.
fn choose_project(world: &mut World, title: &str) -> Outcome {
    let find = |w: &World| {
        scope(w)["projects"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["title"] == title))
            .map(|row| text(&row["key"]))
            .filter(|key| !key.is_empty())
    };
    world.wait_for_with(
        |w| find(w).is_some(),
        |w| format!("{title} to be offered; the scope is {}", show(&scope(w))),
    )?;
    let key = find(world).unwrap_or_default();
    world.dispatch("settingsScope.project", json!({"key": key}))?;
    world.wait_for_with(
        |w| scope(w)["kind"] == "project" && scope(w)["projectLabel"] == title,
        |w| format!("the project scope; it is {}", show(&scope(w))),
    )
}

fn wait_for_model_row(world: &mut World, what: &str, holds: impl Fn(&Value) -> bool) -> Outcome {
    world.wait_for_with(
        |w| project_panel(w)["open"] == true && holds(&model_row(w)),
        |w| format!("{what}; the panel is {}", show(&project_panel(w))),
    )
}

fn offers_models(row: &Value) -> bool {
    row["models"].as_array().is_some_and(|m| !m.is_empty())
}

fn shell(world: &mut World) -> Outcome<brick::Brick> {
    settings_shell(world, 900.0, 300.0)
}

fn breadcrumb(world: &World, brick: brick::Brick) -> (bool, String) {
    match brick.find(world, "settingsBreadcrumb") {
        Ok(Some(item)) => (
            brick.flag(world, item, "visible"),
            brick.text_of(world, item, "text"),
        ),
        _ => (false, String::new()),
    }
}

fn asks_where(world: &World, brick: brick::Brick) -> bool {
    brick.shows(world, "Applying settings for").unwrap_or(false)
}

fn scope_display(world: &World, brick: brick::Brick, name: &str) -> String {
    match brick.find(world, name) {
        Ok(Some(item)) => brick.text_of(world, item, "displayText"),
        _ => String::new(),
    }
}

/// A toast of the failed default model whose text holds `description`.
fn model_toast(world: &mut World, description: &str) -> Outcome {
    expect_toast(world, "Default model not saved", description)
}

fn all_overriding(world: &World, project: &str, value: &Value) -> bool {
    world
        .mc
        .members
        .iter()
        .all(|environment| override_on(world, project, environment).as_ref() == Some(value))
}

fn layers(world: &World) -> Vec<Value> {
    at(&model_row(world), "inheritance.layers")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

const SECTIONS: [(&str, &str); 8] = [
    ("the Keybindings section", "/settings/keybindings"),
    ("the Appearance section", "/settings/appearance"),
    ("the Integrations section", "/settings/integrations"),
    ("the Providers section", "/settings/providers"),
    ("the Cluster section", "/settings/cluster"),
    ("the Archive section", "/settings/archived"),
    ("diagnostics", "/settings/diagnostics"),
    (
        "the open source licenses page",
        "/settings/open-source-licenses",
    ),
];

pub fn register(steps: &mut Steps) {
    // The scope sentence.
    steps.step(
        "the page says it is applying settings for all projects across all environments",
        |world, _, _| {
            connect_if_needed(world)?;
            let brick = shell(world)?;
            world.wait_for("the page to say where settings apply", |w| {
                asks_where(w, brick)
            })?;
            let project = scope_display(world, brick, "scopeProject");
            let environment = scope_display(world, brick, "scopeEnvironment");
            expect!(
                project == "All projects"
                    && environment == "All environments"
                    && brick.shows(world, "across")?,
                "the page says \"{project}\" and \"{environment}\"; the scope is {}",
                show(&scope(world))
            );
            Ok(())
        },
    );

    // A project scope.
    steps.step(
        &format!("the user is editing settings for the project {Q}"),
        |world, c, _| {
            world.mc.part::<Scoped>().project = c[0].clone();
            offer_everywhere(world, &["Sonnet", "Opus"]);
            connect_if_needed(world)?;
            // A feature with no such project has it on this machine.
            let known = world.state("sidebar")["projects"]
                .as_array()
                .is_some_and(|projects| projects.iter().any(|p| p["displayName"] == c[0]));
            if !known {
                let row = json!({"id": c[0], "title": c[0], "workspaceRoot": format!("/work/{}", c[0]),
                                 "scripts": []});
                world.mc.projects.insert(c[0].clone(), row.clone());
                world.mc.send_row_of(&c[0], &row, "project");
                world.sync()?;
            }
            open_section(world, "/settings/projects")?;
            world.dispatch("settingsScope.environment", json!({"id": ""}))?;
            choose_project(world, &c[0])
        },
    );
    steps.step("the user changes the default model", |world, _, _| {
        wait_for_model_row(world, "models to be offered", offers_models)?;
        // A change counts a target that has not sent its settings as one
        // that could not save ("Not connected."), and models show once one
        // has.
        world.wait_for_with(
            |w| {
                let scope = SettingsScope::of(w.engine());
                scope.read(|_, _| None).known == scope.targets().len()
            },
            |w| {
                format!(
                    "every environment's settings; the scope is {}",
                    show(&w.state("settingsScope"))
                )
            },
        )?;
        world.dispatch(
            "projectSettings.model",
            json!({"key": format!("{PROVIDER}:opus")}),
        )
    });
    steps.step(
        &format!("{Q} overrides the default model on each environment with a checkout of it"),
        |world, c, _| {
            let project = c[0].clone();
            world.wait_for_with(
                |w| all_overriding(w, &project, &selection("opus")),
                describe_documents,
            )
        },
    );
    steps.step(
        "other projects keep the environment's default model",
        |world, _, _| {
            world.sync()?;
            for environment in world.mc.members.clone() {
                let settings = held(world, &environment);
                expect!(
                    !settings.contains_key(MODEL)
                        && settings
                            .get("projectSettingsOverrides")
                            .and_then(Value::as_object)
                            .is_some_and(|o| o.len() == 1),
                    "{}",
                    describe_documents(world)
                );
            }
            // And the environment with no checkout of it is not written to.
            expect!(
                fake_config(&mut world.mc).writes.is_empty(),
                "{}",
                describe_documents(world)
            );
            Ok(())
        },
    );

    // This device's preferences.
    steps.step(
        "the user changes a preference that belongs to this device",
        |world, _, _| {
            open_section(world, "/settings/general")?;
            let count = writes(world);
            world.mc.part::<Mark>().0 = count;
            choose_row(world, DEVICE_PREFERENCE, "24-hour")
        },
    );
    steps.step("the preference is saved on this device", |world, _, _| {
        let settings = Settings::of(world.engine());
        let held = settings.device_value(DEVICE_PREFERENCE);
        expect!(
            settings.on_device(DEVICE_PREFERENCE) && held == Some(json!("24-hour")),
            "this device holds {}",
            show(&Value::Object(settings.device()))
        );
        Ok(())
    });
    steps.step("no environment is changed", |world, _, _| {
        world.sync()?;
        expect!(
            writes(world) == world.mc.part::<Mark>().0,
            "{}",
            describe_documents(world)
        );
        Ok(())
    });

    // An environment-wide row at project scope.
    steps.step(
        "the user looks at an environment-wide setting",
        |world, _, _| {
            open_section(world, "/settings/general")?;
            world.setting_row = ENVIRONMENT_WIDE.to_owned();
            expect!(
                row_shown(world, ENVIRONMENT_WIDE)?,
                "the page has no {ENVIRONMENT_WIDE} row"
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told to select an environment to change it",
        |world, _, _| {
            let page = brick::shown(world)?;
            let status = page_item(world, &format!("settingsRow:{ENVIRONMENT_WIDE}"), "status")?;
            let said = page.text_of(world, status, "text");
            expect!(
                page.flag(world, status, "visible")
                    && said == "Environment-wide setting. Select an environment to change it.",
                "the row says \"{said}\""
            );
            // A setting the project can override stays open.
            let control = page_item(world, "settingsRow:responseStreamingMode", "control")?;
            expect!(
                page.flag(world, control, "enabled"),
                "a project setting is locked too"
            );
            Ok(())
        },
    );

    // Overrides.
    steps.step(
        &format!("{Q} overrides the default model"),
        |world, c, _| {
            // The environments default to Opus; the project keeps Sonnet.
            for environment in world.mc.members.clone() {
                settings_of(world, &environment).insert(MODEL.into(), selection("opus"));
                set_override(world, &c[0], &environment, Some(selection("sonnet")));
            }
            Ok(())
        },
    );
    steps.step(
        "the user resets the default model to the inherited value",
        |world, _, _| {
            wait_for_model_row(world, "the project's own model with a reset", |row| {
                row["resettable"] == true && row["label"] == "Claude · Sonnet"
            })?;
            world.dispatch("projectSettings.reset", json!({"key": "model"}))
        },
    );
    steps.step(
        &format!("{Q} no longer overrides the default model"),
        |world, c, _| {
            let project = c[0].clone();
            world.wait_for_with(
                |w| {
                    w.mc.members
                        .iter()
                        .all(|environment| override_on(w, &project, environment).is_none())
                },
                describe_documents,
            )
        },
    );
    steps.step(
        "the default model shows the environment's value",
        |world, _, _| {
            wait_for_model_row(world, "the environment's model without a reset", |row| {
                row["label"] == "Claude · Opus" && row["resettable"] != true
            })
        },
    );

    // Where a value comes from.
    steps.step(
        &format!("{Q} does not override the default model"),
        |world, c, _| {
            // The environments set one; the project sets none.
            for environment in world.mc.members.clone() {
                expect!(
                    override_on(world, &c[0], &environment).is_none(),
                    "{}",
                    describe_documents(world)
                );
                save_on(&mut world.mc, &environment, MODEL, selection("opus"));
            }
            // The page already open reads what the environments now hold.
            if world.shell_subscriptions() > 0 {
                world.sync()?;
            }
            Ok(())
        },
    );
    steps.step(
        "the user asks where the default model comes from",
        |world, _, _| {
            if at(&world.state("route"), "section") != "/settings/projects" {
                open_section(world, "/settings/projects")?;
            }
            wait_for_model_row(world, "the default model row", offers_models)?;
            world.dispatch("projectSettings.inspect", json!({"key": "model"}))
        },
    );
    steps.step(
        "the project, environment, repository file and built-in default layers are listed in that order",
        |world, _, _| {
            let keys: Vec<String> = layers(world).iter().map(|l| text(&l["key"])).collect();
            expect!(
                keys == ["project", "environment", "hal-c2.json", "built-in"],
                "the layers are {}",
                show(&model_row(world)["inheritance"])
            );
            Ok(())
        },
    );
    steps.step(
        "the environment layer is marked as the one in effect",
        |world, _, _| {
            let in_effect: Vec<Value> = layers(world)
                .into_iter()
                .filter(|l| l["effective"] == true)
                .collect();
            expect!(
                in_effect.len() == 1
                    && in_effect[0]["key"] == "environment"
                    && in_effect[0]["value"] == "Claude · Opus",
                "the layers are {}",
                show(&model_row(world)["inheritance"])
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} overrides the default model on {Q}"),
        |world, c, _| {
            offer_everywhere(world, &["Sonnet", "Opus"]);
            settings_of(world, &c[1]).insert(MODEL.into(), selection("opus"));
            set_override(world, &c[0], &c[1], Some(selection("sonnet")));
            world.mc.part::<Scoped>().project = c[0].clone();
            Ok(())
        },
    );
    steps.step(&format!("{Q} is listed as overriding it"), |world, c, _| {
        let title = c[0].clone();
        world.wait_for_with(
            |w| {
                let listed = at(&model_row(w), "inheritance.overridingProjects")
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                listed.len() == 1
                    && listed[0]["title"] == title.as_str()
                    && listed[0]["value"] == "Claude · Sonnet"
            },
            |w| format!("the row is {}", show(&model_row(w))),
        )
    });
    steps.step(
        &format!("the user resets the override for {Q}"),
        |world, c, _| {
            let overriding = at(&model_row(world), "inheritance.overridingProjects")[0].clone();
            expect!(
                overriding["title"] == c[0].as_str(),
                "the row is {}",
                show(&model_row(world))
            );
            world.dispatch(
                "projectSettings.clearOverride",
                json!({"environmentId": overriding["environmentId"],
                       "projectId": overriding["projectId"]}),
            )
        },
    );
    steps.step(&format!("{Q} uses the value from {Q}"), |world, c, _| {
        let (project, environment) = (c[0].clone(), c[1].clone());
        world.wait_for_with(
            |w| {
                override_on(w, &project, &environment).is_none()
                    && at(&model_row(w), "inheritance.overridingProjects")
                        .as_array()
                        .is_none_or(Vec::is_empty)
            },
            describe_documents,
        )?;
        // The environment's own model is untouched, and is what the project now gets.
        expect!(
            held(world, &environment).get(MODEL) == Some(&selection("opus")),
            "{}",
            describe_documents(world)
        );
        Ok(())
    });

    // Environments that disagree.
    steps.step(
        &format!("the default model differs between {Q} and {Q}"),
        |world, c, _| {
            offer_everywhere(world, &["Sonnet", "Opus"]);
            settings_of(world, &c[0]).insert(MODEL.into(), selection("sonnet"));
            settings_of(world, &c[1]).insert(MODEL.into(), selection("opus"));
            Ok(())
        },
    );
    steps.step("the user looks at the default model", |world, _, _| {
        open_section(world, "/settings/projects")?;
        wait_for_model_row(world, "the default model row", offers_models)
    });
    steps.step(
        "it shows as mixed across the selected environments",
        |world, _, _| {
            wait_for_model_row(world, "a mixed default model", |row| {
                row["mixed"] == true && row["label"] == "Mixed"
            })
        },
    );
    steps.step("the user chooses one model", |world, _, _| {
        world.dispatch(
            "projectSettings.model",
            json!({"key": format!("{PROVIDER}:opus")}),
        )
    });
    steps.step("every environment uses that model", |world, _, _| {
        world.wait_for_with(
            |w| {
                let mut all = w.mc.members.clone();
                all.push(w.mc.environment_id.clone());
                all.iter()
                    .all(|e| held(w, e).get(MODEL) == Some(&selection("opus")))
            },
            describe_documents,
        )?;
        wait_for_model_row(world, "one default model", |row| {
            row["mixed"] != true && row["label"] == "Claude · Opus"
        })
    });
    steps.step(
        &format!("the model {Q} is only available on {Q}"),
        |world, c, _| {
            // Of the feature's two machines; this one offers it too.
            let here = world.mc.environment_id.clone();
            offer(world, &here, &["Sonnet", &c[0]]);
            for environment in world.mc.members.clone() {
                if environment == c[1] {
                    offer(world, &environment, &["Sonnet", &c[0]]);
                } else {
                    offer(world, &environment, &["Sonnet"]);
                }
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the user tries to choose {Q} as the default model"),
        |world, c, _| {
            open_section(world, "/settings/projects")?;
            let key = format!("{PROVIDER}:{}", c[0]);
            let wanted = key.clone();
            wait_for_model_row(world, &format!("{} to be offered", c[0]), move |row| {
                row["models"]
                    .as_array()
                    .is_some_and(|models| models.iter().any(|m| m["key"] == wanted.as_str()))
            })?;
            let count = writes(world);
            world.mc.part::<Mark>().0 = count;
            world.dispatch("projectSettings.model", json!({"key": key}))
        },
    );
    steps.step(
        &format!("the user is told the model is unavailable on {Q}"),
        |world, c, _| {
            model_toast(world, &format!("This model is unavailable on {}.", c[0]))?;
            world.sync()?;
            expect!(
                writes(world) == world.mc.part::<Mark>().0,
                "{}",
                describe_documents(world)
            );
            Ok(())
        },
    );
    steps.step(
        "is told to select that environment to choose its model separately",
        |world, _, _| {
            model_toast(
                world,
                "Select that environment to choose its model separately.",
            )
        },
    );

    // Sections and their titles (search-and-navigation.feature).
    let names: Vec<&str> = SECTIONS.iter().map(|(name, _)| *name).collect();
    steps.step(
        &format!("the user opens ({})", names.join("|")),
        |world, c, _| {
            let sections: HashMap<&str, &str> = SECTIONS.into_iter().collect();
            // General asks where settings apply, before the user moves on.
            if world.shell_subscriptions() > 0 && world.mc.part::<Scoped>().project.is_empty() {
                let brick = shell(world)?;
                world.wait_for("General to say where settings apply", |w| {
                    asks_where(w, brick)
                })?;
            }
            open_section(world, sections[c[0].as_str()])
        },
    );
    steps.step(&format!("the page is titled {Q}"), |world, c, _| {
        let brick = shell(world)?;
        let title = c[0].clone();
        world.wait_for_with(
            |w| {
                let (visible, text) = breadcrumb(w, brick);
                visible && text == title
            },
            |w| format!("the page is titled \"{}\"", breadcrumb(w, brick).1),
        )
    });
    steps.step(
        "the page does not offer a choice of project or environment",
        |world, _, _| {
            let brick = shell(world)?;
            world.wait_for("the Appearance page", |w| {
                breadcrumb(w, brick).1 == "Settings / Appearance"
            })?;
            expect!(
                !asks_where(world, brick),
                "the page asks where settings apply"
            );
            Ok(())
        },
    );
    steps.step(&format!("settings still apply to {Q}"), |world, c, _| {
        world.sync()?;
        expect!(
            scope(world)["kind"] == "project" && scope(world)["projectLabel"] == c[0].as_str(),
            "the scope is {}",
            show(&scope(world))
        );
        // And the page says so.
        let brick = shell(world)?;
        let title = c[0].clone();
        world.wait_for("the page to name the project", |w| {
            asks_where(w, brick) && scope_display(w, brick, "scopeProject") == title
        })
    });
}
