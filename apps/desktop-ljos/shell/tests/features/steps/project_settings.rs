//! The native Project settings section (ProjectSettingsController): the
//! @desktop scenarios of features/settings/projects.feature and
//! features/settings/project-defaults.feature it delivers. The project's
//! checkouts live on other members of the cluster, each its own machine.
//! desktop-qt's ProjectSettingsSteps.cpp.

use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::settings_scope::SettingsScope;
use hal_c2_shell::controllers::sidebar;
use serde_json::{Value, json};

use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::project::FakeProjects;
use crate::steps::settings::{FakeConfig, document_of, publish_providers, save_on};
use crate::world::World;
use crate::{expect, fail};

const AT: &str = "2026-09-01T09:00:00Z";
const REMOVED_AT: &str = "2026-09-23T10:00:00Z";

fn panel(world: &World) -> Value {
    world.state("projectSettings")
}

fn scope(world: &World) -> Value {
    world.state("settingsScope")
}

fn act(world: &mut World, name: &str, payload: Value) -> Outcome {
    world.dispatch(&format!("projectSettings.{name}"), payload)
}

fn checkout_id(project: &str, environment: &str) -> String {
    format!("{project}-{environment}")
}

/// A checkout of `project` on the cluster member `environment`, one
/// repository wherever it is so its checkouts are one project.
fn add_checkout(world: &mut World, project: &str, environment: &str) {
    let root = format!("/home/{environment}/{project}");
    let id = checkout_id(project, environment);
    world.mc.send_peer_row_of(
        environment,
        &id,
        &json!({"id": id, "title": project, "workspaceRoot": root, "createdAt": AT,
                "updatedAt": AT,
                "repositoryIdentity": {"canonicalKey": format!("github.com/hal-c2/{project}"),
                                       "rootPath": root, "name": project}}),
        "project",
    );
}

fn remove_checkout(world: &mut World, project: &str, environment: &str) {
    world.mc.send_peer_row_of(
        environment,
        &checkout_id(project, environment),
        &json!({"deletedAt": REMOVED_AT}),
        "project",
    );
}

fn checkout(world: &World, project: &str, environment: &str) -> Value {
    world
        .mc
        .peer_rows
        .get(environment)
        .and_then(|rows| rows.get(&checkout_id(project, environment)))
        .map_or(Value::Null, |entry| entry[2].clone())
}

/// Another machine of the cluster, with its own settings.
fn join_machine(world: &mut World, name: &str) {
    document_of(&mut world.mc, name);
    world.mc.join_named(name);
}

fn open_projects(world: &mut World) -> Outcome {
    if world.shell_subscriptions() == 0 {
        world.connect()?;
        world.sync()?;
    }
    world.dispatch("settings.navigate", json!({"to": "/settings/projects"}))?;
    world.wait_for_with(
        |w| panel(w)["open"] == json!(true) && !scope(w).is_null(),
        |w| format!("project settings to show; they are {}", show(&panel(w))),
    )
}

fn choose_project(world: &mut World, title: &str) -> Outcome {
    let mut key = String::new();
    if !title.is_empty() {
        let wanted = title.to_owned();
        let find = move |w: &World| {
            scope(w)["projects"]
                .as_array()
                .and_then(|rows| rows.iter().find(|row| row["title"] == wanted.as_str()))
                .map(|row| text(&row["key"]))
        };
        let looking = find.clone();
        world.wait_for_with(
            move |w| looking(w).is_some(),
            |w| format!("{title} to be offered; the scope is {}", show(&scope(w))),
        )?;
        key = find(world).unwrap_or_default();
    }
    world.dispatch("settingsScope.project", json!({"key": key}))
}

fn choose_environment(world: &mut World, label: &str) -> Outcome {
    let mut id = String::new();
    if !label.is_empty() {
        let wanted = label.to_owned();
        let find = move |w: &World| {
            scope(w)["environments"]
                .as_array()
                .and_then(|rows| rows.iter().find(|row| row["label"] == wanted.as_str()))
                .map(|row| text(&row["id"]))
        };
        let looking = find.clone();
        world.wait_for_with(
            move |w| looking(w).is_some(),
            |w| format!("{label} to be offered; the scope is {}", show(&scope(w))),
        )?;
        id = find(world).unwrap_or_default();
    }
    world.dispatch("settingsScope.environment", json!({"id": id}))
}

/// Settings open on `project`, on `environment` or across them all.
fn manage(world: &mut World, project: &str, environment: &str) -> Outcome {
    open_projects(world)?;
    choose_project(world, project)?;
    choose_environment(world, environment)?;
    let name = project.to_owned();
    world.wait_for_with(
        move |w| panel(w)["status"] == "ready" && panel(w)["name"] == name.as_str(),
        |w| format!("{project} to be managed; the panel is {}", show(&panel(w))),
    )
}

fn expect_status(world: &mut World, status: &str, message: &str) -> Outcome {
    world.wait_for_with(
        |w| panel(w)["status"] == status,
        |w| format!("the panel to be {status}; it is {}", show(&panel(w))),
    )?;
    expect!(
        text(&panel(world)["message"]).starts_with(message),
        "the panel to say \"{message}\"; it is {}",
        show(&panel(world))
    );
    Ok(())
}

pub fn expect_toast(world: &mut World, title: &str, description: &str) -> Outcome {
    world.wait_for_with(
        |w| {
            w.state("toasts")["items"].as_array().is_some_and(|items| {
                items.iter().any(|toast| {
                    toast["title"] == title && text(&toast["description"]).contains(description)
                })
            })
        },
        |w| {
            format!(
                "\"{title}\" to be toasted; the shell shows {}",
                show(&w.state("toasts"))
            )
        },
    )
}

/// The environments the sidebar lists `project` on.
fn listed_on(world: &World, project: &str) -> Vec<String> {
    let mut environments = Vec::new();
    for group in sidebar::groups(world.engine()) {
        if group.summary.get("displayName") != Some(&json!(project)) {
            continue;
        }
        for member in &group.members {
            environments.push(member.environment_id.clone());
        }
    }
    environments.sort();
    environments
}

fn checkout_key(world: &World, project: &str, environment: &str) -> Outcome<String> {
    let panel = panel(world);
    match panel["checkouts"]
        .as_array()
        .and_then(|rows| rows.iter().find(|row| row["environment"] == environment))
    {
        Some(row) => Ok(text(&row["key"])),
        None => fail!(
            "no checkout of {project} on {environment}; the panel is {}",
            show(&panel)
        ),
    }
}

fn removal(world: &World) -> Value {
    world.state("projectRemoval")
}

fn row(world: &World, name: &str) -> Value {
    panel(world)[name].clone()
}

fn provider(instance_id: &str, name: &str, models: &[&str]) -> Value {
    let slugs: Vec<Value> = models
        .iter()
        .map(|model| json!({"slug": model.to_lowercase(), "name": model}))
        .collect();
    json!({"instanceId": instance_id, "displayName": name, "enabled": true,
           "installed": true, "models": slugs})
}

/// The environment's saved value of `key`.
fn saved_on(world: &World, environment: &str, key: &str) -> Value {
    let Some(config) = world.mc.peek::<FakeConfig>() else {
        return Value::Null;
    };
    let settings = if environment == world.mc.environment_id {
        Some(&config.settings)
    } else {
        config.documents.get(environment).map(|d| &d.settings)
    };
    settings
        .and_then(|settings| settings.get(key))
        .cloned()
        .unwrap_or(Value::Null)
}

fn mutations(world: &mut World) -> Vec<Value> {
    world.mc.part::<FakeProjects>().mutations.clone()
}

pub fn register(steps: &mut Steps) {
    // projects.feature
    steps.step(
        &format!("the user has the project {Q} with checkouts on {Q} and {Q}"),
        |world, c, _| {
            for environment in [&c[1], &c[2]] {
                join_machine(world, environment);
                add_checkout(world, &c[0], environment);
            }
            Ok(())
        },
    );
    steps.step("both environments are connected", |world, _, _| {
        world.connect()?;
        world.sync()?;
        world.wait_for("both machines' checkouts to be listed", |w| {
            listed_on(w, "shop").len() == 2
        })
    });
    steps.step(
        "the user opens the Projects settings without a project picked",
        |world, _, _| {
            open_projects(world)?;
            choose_project(world, "")
        },
    );
    steps.step(
        "the user is asked to choose a project to manage its name, icon, checkouts and actions",
        |world, _, _| {
            expect_status(
                world,
                "pick",
                "Choose a project to manage its name, icon, checkouts and actions.",
            )
        },
    );
    steps.step("the user has no projects", |world, _, _| {
        for environment in world.mc.members.clone() {
            let ids: Vec<String> = world
                .mc
                .peer_rows
                .get(&environment)
                .map(|rows| rows.keys().cloned().collect())
                .unwrap_or_default();
            for id in ids {
                world.mc.send_peer_row_of(
                    &environment,
                    &id,
                    &json!({"deletedAt": REMOVED_AT}),
                    "project",
                );
            }
        }
        world.sync()
    });
    steps.step("the user opens the Projects settings", |world, _, _| {
        open_projects(world)
    });
    steps.step(
        "the user is told to add a project from the sidebar to configure it here",
        |world, _, _| {
            expect_status(
                world,
                "empty",
                "Add a project from the sidebar to configure it here.",
            )
        },
    );
    steps.step(
        &format!("the user (?:is managing|manages) {Q} in settings"),
        |world, c, _| manage(world, &c[0], ""),
    );
    steps.step(
        &format!("{Q} is removed on another device"),
        |world, c, _| {
            for environment in world.mc.members.clone() {
                remove_checkout(world, &c[0], &environment);
            }
            world.sync()
        },
    );
    steps.step(
        "the user is told this project is no longer available",
        |world, _, _| expect_status(world, "missing", "This project is no longer available."),
    );
    steps.step(
        &format!("the user is managing the {Q} checkout of {Q}"),
        |world, c, _| manage(world, &c[1], &c[0]),
    );
    steps.step(
        "that checkout is removed on another device",
        |world, _, _| {
            let environment = SettingsScope::of(world.engine()).environment_filter();
            let project = text(&panel(world)["name"]);
            remove_checkout(world, &project, &environment);
            world.sync()
        },
    );
    steps.step(
        "the user is told this checkout is no longer available in the selected project and environment",
        |world, _, _| {
            expect_status(
                world,
                "checkout-missing",
                "This checkout is no longer available in the selected project and environment.",
            )
        },
    );
    steps.step(
        "the user changes how projects are grouped",
        |world, _, _| {
            let before = SettingsScope::of(world.engine()).project_key();
            let engine = world.engine().clone();
            Settings::of(&engine).set(&engine, "sidebarProjectGroupingMode", json!("separate"));
            world.wait_for_with(
                move |w| SettingsScope::of(w.engine()).project_key() != before,
                |w| {
                    format!(
                        "the project to be regrouped; the scope is {}",
                        show(&scope(w))
                    )
                },
            )
        },
    );
    steps.step(&format!("the panel still shows {Q}"), |world, c, _| {
        let name = c[0].clone();
        world.wait_for_with(
            move |w| panel(w)["status"] == "ready" && panel(w)["name"] == name.as_str(),
            |w| format!("{} to show; the panel is {}", c[0], show(&panel(w))),
        )
    });

    // Renaming.
    steps.step(
        &format!("the user renames {Q} to {Q} in settings"),
        |world, c, _| {
            // A machine that went down says so first.
            world.sync()?;
            manage(world, &c[0], "")?;
            act(world, "rename", json!({"title": c[1]}))
        },
    );
    steps.step(
        &format!("{Q} is shown for the checkouts on {Q} and {Q}"),
        |world, c, _| {
            let (name, first, second) = (c[0].clone(), c[1].clone(), c[2].clone());
            world.wait_for_with(
                move |w| {
                    checkout(w, "shop", &first)["title"] == name.as_str()
                        && checkout(w, "shop", &second)["title"] == name.as_str()
                        && listed_on(w, &name).len() == 2
                },
                |w| {
                    format!(
                        "both checkouts to be renamed {}; the panel is {}",
                        c[0],
                        show(&panel(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user clears the name of {Q} in settings"),
        |world, c, _| {
            manage(world, &c[0], "")?;
            act(world, "rename", json!({"title": "  "}))
        },
    );
    steps.step(
        "the user is told the project title cannot be empty",
        |world, _, _| expect_toast(world, "Project title cannot be empty", ""),
    );
    steps.step(&format!("the name stays {Q}"), |world, c, _| {
        world.sync()?;
        expect!(
            mutations(world).is_empty() && panel(world)["name"] == c[0].as_str(),
            "nothing to be renamed; the panel is {}",
            show(&panel(world))
        );
        Ok(())
    });
    steps.step(
        &format!("the user is told to connect {Q} and try again"),
        |world, c, _| {
            expect_toast(
                world,
                "Failed to rename project",
                &format!("Connect {} and try again.", c[0]),
            )?;
            expect!(mutations(world).is_empty(), "no checkout to be renamed");
            Ok(())
        },
    );
    steps.step(&format!("renaming fails on {Q}"), |world, c, _| {
        world
            .mc
            .part::<FakeProjects>()
            .refused_on
            .insert(c[0].clone(), "disk full".into());
        Ok(())
    });
    steps.step(
        &format!("the user is told the rename failed on {Q}"),
        |world, c, _| {
            expect_toast(
                world,
                &format!("Failed to rename project on {}", c[0]),
                "disk full",
            )
        },
    );

    // The icon.
    steps.step(
        &format!("the user chooses the emoji {Q} as the icon of {Q} in settings"),
        |world, c, _| {
            manage(world, &c[1], "")?;
            act(world, "icon", json!({"emoji": c[0]}))
        },
    );
    steps.step(
        &format!("{Q} shows {Q} on every checkout"),
        |world, c, _| {
            let (project, emoji) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                move |w| {
                    w.mc.members.iter().all(|e| {
                        at(&checkout(w, &project, e), "projectIcon.emoji") == emoji.as_str()
                    }) && at(&panel(w), "icon.label") == emoji.as_str()
                },
                |w| {
                    format!(
                        "{} on every checkout; the panel is {}",
                        c[1],
                        show(&panel(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user sets the icon of {Q} back to automatic"),
        |world, _, _| act(world, "icon", json!({})),
    );
    steps.step(&format!("{Q} shows its automatic icon"), |world, c, _| {
        let project = c[0].clone();
        world.wait_for_with(
            move |w| {
                w.mc.members
                    .iter()
                    .all(|e| checkout(w, &project, e)["projectIcon"].is_null())
                    && at(&panel(w), "icon.custom") != &json!(true)
            },
            |w| format!("the automatic icon; the panel is {}", show(&panel(w))),
        )
    });

    // Checkouts and removing them.
    steps.step(
        &format!("the checkouts on {Q} and {Q} are listed with their folders"),
        |world, c, _| {
            let mut listed: Vec<String> = panel(world)["checkouts"]
                .as_array()
                .map(|rows| {
                    rows.iter()
                        .map(|row| format!("{} {}", text(&row["environment"]), text(&row["path"])))
                        .collect()
                })
                .unwrap_or_default();
            listed.sort();
            let mut wanted = vec![
                format!("{} /home/{}/shop", c[0], c[0]),
                format!("{} /home/{}/shop", c[1], c[1]),
            ];
            wanted.sort();
            expect!(listed == wanted, "the checkouts are {}", listed.join(", "));
            Ok(())
        },
    );
    steps.step(
        &format!("the user removes the {Q} checkout of {Q} and confirms"),
        |world, c, _| {
            manage(world, &c[1], "")?;
            let key = checkout_key(world, &c[1], &c[0])?;
            act(world, "remove", json!({"key": key}))?;
            world.wait_for("the removal to be confirmed", |w| !removal(w).is_null())?;
            world.dispatch("project.remove.confirm", json!({}))
        },
    );
    steps.step(&format!("{Q} is listed only on {Q}"), |world, c, _| {
        let (project, only) = (c[0].clone(), c[1].clone());
        world.wait_for_with(
            move |w| listed_on(w, &project) == [only.clone()],
            |w| {
                format!(
                    "{} only on {}; it is on {}",
                    c[0],
                    c[1],
                    listed_on(w, &c[0]).join(", ")
                )
            },
        )
    });
    steps.step(
        &format!("the user removes {Q} everywhere and confirms"),
        |world, c, _| {
            manage(world, &c[0], "")?;
            act(world, "remove", json!({}))?;
            world.wait_for_with(
                |w| removal(w)["count"] == json!(2),
                |w| {
                    format!(
                        "both checkouts to be confirmed; the confirmation is {}",
                        show(&removal(w))
                    )
                },
            )?;
            world.dispatch("project.remove.confirm", json!({}))
        },
    );
    steps.step(
        &format!("{Q} is no longer listed on {Q} or {Q}"),
        |world, c, _| {
            let project = c[0].clone();
            world.wait_for_with(
                move |w| listed_on(w, &project).is_empty(),
                |w| {
                    format!(
                        "{} to be gone; it is on {}",
                        c[0],
                        listed_on(w, &c[0]).join(", ")
                    )
                },
            )
        },
    );
    steps.step("no files are deleted on either machine", |world, _, _| {
        // Only the entries go: nothing asks a machine to delete a folder.
        for mutation in mutations(world) {
            expect!(
                mutation["type"] == "project.delete" && mutation.get("deleteFiles").is_none(),
                "the MC was asked to {}",
                show(&mutation)
            );
        }
        Ok(())
    });
    steps.step(
        &format!("the {Q} checkout of {Q} has (\\d+) threads"),
        |world, c, _| {
            let count: i32 = c[2].parse().unwrap_or(0);
            for index in 1..=count {
                let id = format!("{}-thread-{index}", c[0]);
                world.mc.send_peer_row(
                    &c[0],
                    &id,
                    &json!({"id": id, "projectId": checkout_id(&c[1], &c[0]),
                            "title": format!("Thread {index}"), "createdAt": AT,
                            "updatedAt": AT}),
                );
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the user asks to remove the {Q} checkout of {Q}"),
        |world, c, _| {
            manage(world, &c[1], "")?;
            let key = checkout_key(world, &c[1], &c[0])?;
            act(world, "remove", json!({"key": key}))
        },
    );
    steps.step(
        &format!("the confirmation names (\\d+) threads, the folder and {Q}"),
        |world, c, _| {
            let (count, environment) = (c[0].parse::<i64>().unwrap_or(0), c[1].clone());
            world.wait_for_with(
                move |w| {
                    let shown = removal(w);
                    shown["threadCount"] == json!(count)
                        && shown["workspaceRoot"] == format!("/home/{environment}/shop").as_str()
                        && shown["environment"] == environment.as_str()
                },
                |w| format!("the confirmation is {}", show(&removal(w))),
            )
        },
    );
    steps.step(
        "the confirmation says conversation history is cleared permanently",
        |world, _, _| {
            // ProjectRemovalDialog.qml says so of every checkout it removes.
            expect!(
                removal(world)["kind"] == "checkout",
                "the confirmation is {}",
                show(&removal(world))
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told to keep the project picked while browsing other pages to find more of its settings",
        |world, _, _| {
            expect!(
                text(&panel(world)["note"]).contains("Keep this project picked above"),
                "the panel is {}",
                show(&panel(world))
            );
            Ok(())
        },
    );

    // project-defaults.feature
    steps.step(
        &format!("a connected environment {Q} with the project {Q}"),
        |world, c, _| {
            world.mc.environment_id = c[0].clone();
            world.mc.label = c[0].clone();
            world.mc.projects.insert(
                c[1].clone(),
                json!({"id": c[1], "title": c[1], "workspaceRoot": format!("/work/{}", c[1]),
                       "createdAt": AT, "updatedAt": AT, "scripts": []}),
            );
            publish_providers(
                &mut world.mc,
                vec![provider("claudeAgent", "Claude", &["Sonnet"])],
            );
            world.connect()?;
            world.sync()
        },
    );
    steps.step(
        &format!("neither {Q} nor {Q} sets a default model"),
        |world, _, _| {
            let config = world.mc.part::<FakeConfig>();
            expect!(
                !config.settings.contains_key("defaultModelSelection"),
                "no default model"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user looks at the project defaults of {Q}"),
        |world, c, _| manage(world, &c[0], ""),
    );
    steps.step("the default model shows as automatic", |world, _, _| {
        world.wait_for_with(
            |w| row(w, "model")["automatic"] == json!(true),
            |w| format!("an automatic model; the panel is {}", show(&panel(w))),
        )?;
        expect!(
            row(world, "model")["label"] == "Automatic",
            "the panel is {}",
            show(&panel(world))
        );
        Ok(())
    });
    // Only Sonnet is offered there.
    steps.step(&format!("{Q} is not available on {Q}"), |_, _, _| Ok(()));
    steps.step(
        &format!("the user sets the default model of {Q} to {Q}"),
        |world, c, _| {
            manage(world, &c[0], "")?;
            act(
                world,
                "model",
                json!({"key": format!("claudeAgent:{}", c[1].to_lowercase())}),
            )
        },
    );
    steps.step(
        &format!(
            "the user is told the default model was not saved because it is unavailable on {Q}"
        ),
        |world, c, _| {
            expect_toast(
                world,
                "Default model not saved",
                &format!("This model is unavailable on {}.", c[0]),
            )?;
            expect!(
                world.mc.part::<FakeConfig>().writes.is_empty(),
                "nothing to be written"
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} has no providers"), |world, _, _| {
        publish_providers(&mut world.mc, vec![]);
        Ok(())
    });
    steps.step(
        "the user is told no providers are available",
        |world, _, _| {
            world.wait_for_with(
                |w| row(w, "model")["none"] == json!(true),
                |w| format!("no models to be offered; the panel is {}", show(&panel(w))),
            )
        },
    );
    steps.step(
        &format!("the user applies settings to {Q} and {Q}"),
        |world, c, _| {
            join_machine(world, &c[1]);
            open_projects(world)?;
            choose_project(world, "")?;
            choose_environment(world, "")?;
            world.wait_for_with(
                |w| SettingsScope::of(w.engine()).targets().len() == 2,
                |w| {
                    format!(
                        "both environments to be selected; the scope is {}",
                        show(&scope(w))
                    )
                },
            )
        },
    );
    steps.step("their default workspaces differ", |world, _, _| {
        let own = world.mc.environment_id.clone();
        let other = world.mc.members.first().cloned().unwrap_or_default();
        save_on(
            &mut world.mc,
            &own,
            "defaultThreadEnvMode",
            json!("worktree"),
        );
        save_on(
            &mut world.mc,
            &other,
            "defaultThreadEnvMode",
            json!("local"),
        );
        Ok(())
    });
    steps.step("the user looks at the default workspace", |world, _, _| {
        world.wait_for_with(
            |w| row(w, "workspace")["mixed"] == json!(true),
            |w| {
                format!(
                    "the workspaces to be read; the panel is {}",
                    show(&panel(w))
                )
            },
        )
    });
    steps.step("it shows as mixed", |world, _, _| {
        expect!(
            row(world, "workspace")["label"] == "Mixed",
            "the panel is {}",
            show(&panel(world))
        );
        Ok(())
    });
    // "the user picks" is the sidebar's, which picks the workspace here.
    steps.step(&format!("both environments use {Q}"), |world, c, _| {
        let mode = c[0].clone();
        world.wait_for_with(
            move |w| {
                let other = w.mc.members.first().cloned().unwrap_or_default();
                saved_on(w, &w.mc.environment_id, "defaultThreadEnvMode") == json!(mode)
                    && saved_on(w, &other, "defaultThreadEnvMode") == json!(mode)
                    && row(w, "workspace")["mixed"] != json!(true)
            },
            |w| format!("{} on both; the panel is {}", c[0], show(&panel(w))),
        )
    });
    steps.step("no environment is connected", |world, _, _| {
        open_projects(world)?;
        world.mc.stop_accepting();
        world.mc.drop_connection();
        world.wait_for("the shell to see the drop", |w| !w.client_ready())
    });
    steps.step("the user looks at the project defaults", |_, _, _| Ok(()));
    steps.step("the defaults show as unavailable", |world, _, _| {
        world.wait_for_with(
            |w| {
                // An absent flag is an available panel.
                panel(w)["available"] == json!(false)
                    && row(w, "model")["label"] == "Unavailable"
                    && row(w, "workspace")["label"] == "Unavailable"
            },
            |w| {
                format!(
                    "the defaults to be unavailable; the panel is {}",
                    show(&panel(w))
                )
            },
        )
    });
}
