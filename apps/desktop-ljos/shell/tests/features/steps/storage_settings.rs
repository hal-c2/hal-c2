//! The native Storage settings section and the settings scope it follows:
//! the @desktop and @shared scenarios of features/settings/storage.feature
//! and the scope ones of features/settings/scopes-and-inheritance.feature it
//! delivers. Other machines are members of the cluster, each with its own
//! settings document. desktop-qt's StorageSettingsSteps.cpp.

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::settings_scope::SettingsScope;
use serde_json::{Map, Value, json};

use crate::harness::{Outcome, Q, Steps, at, show};
use crate::steps::settings::{document_of, fake_config};
use crate::steps::settings_rows::expect_row_locked;
use crate::steps::settings_scoped_rows::with_capabilities;
use crate::world::World;
use crate::expect;

fn supported() -> Value {
    json!({"storageCleanup": true, "projectWorktreeCleanup": true})
}

fn storage(world: &World) -> Value {
    world.state("storageSettings")
}

fn scope(world: &World) -> Value {
    world.state("settingsScope")
}

fn is_empty(value: &Value) -> bool {
    value.is_null() || value.as_object().is_some_and(Map::is_empty)
}

/// This machine, supporting storage cleanup unless told otherwise.
fn support_here(world: &mut World, capabilities: Value) {
    let fake = fake_config(&mut world.mc);
    fake.config = with_capabilities(fake.config.clone(), capabilities);
}

/// Another machine of the cluster, named `name`, with its own settings.
fn join_machine(world: &mut World, name: &str) {
    let fake = fake_config(&mut world.mc);
    let config = fake.elsewhere.remove(name).unwrap_or_default();
    fake.elsewhere
        .insert(name.to_owned(), with_capabilities(config, supported()));
    document_of(&mut world.mc, name);
    world.mc.join_named(name);
}

fn set_cleanup(world: &mut World, environment: &str, key: &str, value: Value) {
    let document = document_of(&mut world.mc, environment);
    let mut cleanup = document
        .settings
        .get("storageCleanup")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    cleanup.insert(key.to_owned(), value);
    document
        .settings
        .insert("storageCleanup".into(), Value::Object(cleanup));
}

fn cleanup_of(world: &mut World, environment: &str, key: &str) -> Value {
    let settings = if environment == world.mc.environment_id {
        fake_config(&mut world.mc).settings.clone()
    } else {
        document_of(&mut world.mc, environment).settings.clone()
    };
    settings["storageCleanup"][key].clone()
}

fn open_storage(world: &mut World) -> Outcome {
    if world.shell_subscriptions() == 0 {
        world.connect()?;
        world.sync()?;
    }
    // Another scoped section that is open stays: the scope is shared.
    if at(&world.state("route"), "kind") != "settings" {
        let _ = hal_c2_shell::controller::with::<Navigation, _>(world.engine(), |n, engine| {
            n.open(engine, Route::Settings("/settings/storage".into()))
        });
    }
    world.wait_for_with(
        |w| !is_empty(&scope(w)) && !is_empty(&storage(w)),
        |w| format!("storage settings to show; they are {}", show(&storage(w))),
    )
}

/// The scope's rows of `list` whose `field` is `value`: their `pick`.
fn offered(world: &World, list: &str, field: &str, value: &str, pick: &str) -> Option<String> {
    scope(world)[list]
        .as_array()?
        .iter()
        .find(|row| row[field] == value)
        .and_then(|row| row[pick].as_str().map(str::to_owned))
}

/// The scope's environment named `label`, "" for all.
fn choose_environment(world: &mut World, label: &str) -> Outcome {
    let mut id = String::new();
    if !label.is_empty() {
        world.wait_for_with(
            |w| offered(w, "environments", "label", label, "id").is_some(),
            |w| format!("{label} to be offered; the scope is {}", show(&scope(w))),
        )?;
        id = offered(world, "environments", "label", label, "id").unwrap_or_default();
    }
    world.dispatch("settingsScope.environment", json!({"id": id}))
}

fn choose_project(world: &mut World, title: &str) -> Outcome {
    let mut key = String::new();
    if !title.is_empty() {
        world.wait_for_with(
            |w| offered(w, "projects", "title", title, "key").is_some(),
            |w| format!("{title} to be offered; the scope is {}", show(&scope(w))),
        )?;
        key = offered(world, "projects", "title", title, "key").unwrap_or_default();
    }
    world.dispatch("settingsScope.project", json!({"key": key}))
}

fn rule(world: &World, key: &str) -> Value {
    for group in ["worktrees", "artifacts"] {
        if let Some(row) = storage(world)[group]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["key"] == key))
        {
            return row.clone();
        }
    }
    Value::Null
}

fn wait_ready(world: &mut World, targets: usize) -> Outcome {
    world.wait_for_with(
        |w| {
            storage(w)["status"] == "ready"
                && scope(w)["editable"] == json!(true)
                && SettingsScope::of(w.engine()).targets().len() == targets
        },
        |w| {
            format!(
                "storage settings to be ready on {targets} environments; they are {}, the scope {}",
                show(&storage(w)),
                show(&scope(w))
            )
        },
    )
}

fn project_row(name: &str) -> Value {
    json!({"id": name, "title": name, "workspaceRoot": format!("/work/{name}"),
           "createdAt": "2026-09-01T09:00:00Z", "updatedAt": "2026-09-01T09:00:00Z",
           "scripts": []})
}

fn change(world: &mut World) -> Outcome {
    world.dispatch(
        "storageSettings.set",
        json!({"key": "worktreeOnMerge", "value": true}),
    )
}

pub fn register(steps: &mut Steps) {
    // storage.feature
    steps.step(&format!("an MC with a project {Q}"), |world, c, _| {
        support_here(world, supported());
        world.mc.projects.insert(c[0].clone(), project_row(&c[0]));
        Ok(())
    });
    steps.step(
        &format!("{Q} deletes inactive worktrees and {Q} does not"),
        |world, c, _| {
            for name in [&c[0], &c[1]] {
                join_machine(world, name);
            }
            set_cleanup(world, &c[0], "worktreeAfterDays", json!(8));
            set_cleanup(world, &c[1], "worktreeAfterDays", Value::Null);
            Ok(())
        },
    );
    steps.step("the user views storage settings for both machines", |world, _, _| {
        open_storage(world)?;
        world.wait_for_with(
            |w| scope(w)["environments"].as_array().map(Vec::len) == Some(3),
            |w| format!("three environments; the scope is {}", show(&scope(w))),
        )?;
        choose_environment(world, "")
    });
    steps.step("that rule shows as mixed", |world, _, _| {
        world.wait_for_with(
            |w| rule(w, "worktreeAfterDays")["mixed"] == json!(true),
            |w| format!("inactive worktrees to be mixed; storage is {}", show(&storage(w))),
        )?;
        expect!(
            rule(world, "worktreeOnMerge")["mixed"] != json!(true),
            "rules set alike to stay unmixed; storage is {}",
            show(&storage(world))
        );
        Ok(())
    });
    steps.step(
        "the selected machine does not support storage cleanup",
        |world, _, _| {
            support_here(world, json!({}));
            Ok(())
        },
    );
    steps.step("the user opens storage settings", |world, _, _| open_storage(world));
    steps.step(
        "the user is asked to update that machine first",
        |world, _, _| {
            world.wait_for_with(
                |w| storage(w)["status"] == "unsupported",
                |w| format!("storage settings to ask for an update; they are {}", show(&storage(w))),
            )?;
            expect!(
                storage(world)["notice"]
                    .as_str()
                    .is_some_and(|n| n.starts_with("Update the selected environments")),
                "the update notice; storage is {}",
                show(&storage(world))
            );
            Ok(())
        },
    );

    // scopes-and-inheritance.feature, through the Storage section.
    steps.step(
        &format!("the user has environments {Q} and {Q}"),
        |world, c, _| {
            support_here(world, supported());
            for name in [&c[0], &c[1]] {
                join_machine(world, name);
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the project {Q} has a checkout on each environment"),
        |world, c, _| {
            for environment in world.mc.members.clone() {
                let id = format!("{}-{environment}", c[0]);
                let mut row = project_row(&c[0]);
                row["id"] = json!(id);
                // One repository, so its checkouts are one project.
                row["repositoryIdentity"] = json!({
                    "canonicalKey": format!("github.com/hal-c2/{}", c[0]),
                    "rootPath": format!("/work/{}", c[0]),
                    "name": c[0],
                });
                world.mc.send_peer_row_of(&environment, &id, &row, "project");
            }
            // And another project, only here.
            world.mc.projects.insert("docs".into(), project_row("docs"));
            Ok(())
        },
    );
    steps.step(
        &format!("the user is editing settings for {Q} on {Q}"),
        |world, c, _| {
            open_storage(world)?;
            choose_project(world, &c[0])?;
            choose_environment(world, &c[1])?;
            world.wait_for_with(
                |w| scope(w)["kind"] == "project",
                |w| format!("the project scope; it is {}", show(&scope(w))),
            )
        },
    );
    steps.step(&format!("the user chooses the environment {Q}"), |world, c, _| {
        choose_environment(world, &c[0])
    });
    steps.step("the user chooses all environments", |world, _, _| {
        choose_environment(world, "")
    });
    steps.step("the user chooses all projects", |world, _, _| {
        choose_project(world, "")
    });
    steps.step(&format!("settings apply to {Q} on {Q}"), |world, c, _| {
        world.wait_for_with(
            |w| {
                let now = scope(w);
                now["projectLabel"] == c[0].as_str()
                    && now["environmentLabel"] == c[1].as_str()
                    && now["connective"] == "on"
                    && now["kind"] == "project"
            },
            |w| format!("{} on {}; the scope is {}", c[0], c[1], show(&scope(w))),
        )?;
        expect!(
            SettingsScope::of(world.engine()).targets() == [c[1].clone()],
            "only {} to be written to",
            c[1]
        );
        Ok(())
    });
    steps.step(
        &format!("settings apply to {Q} across all checkouts"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    let now = scope(w);
                    now["projectLabel"] == c[0].as_str()
                        && now["environmentLabel"] == "All environments"
                        && now["connective"] == "across"
                },
                |w| format!("{} across all environments; the scope is {}", c[0], show(&scope(w))),
            )?;
            // Only the environments with a checkout of it.
            let mut targets = SettingsScope::of(world.engine()).targets();
            targets.sort();
            expect!(
                targets == ["Build box", "Laptop"],
                "the checkouts to be written to; they are {}",
                targets.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("settings apply to every project on {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    let now = scope(w);
                    now["kind"] == "environment"
                        && now["projectLabel"] == "All projects"
                        && now["environmentLabel"] == c[0].as_str()
                },
                |w| format!("every project on {}; the scope is {}", c[0], show(&scope(w))),
            )
        },
    );
    steps.step(
        "the user chooses which environment settings apply to",
        |world, _, _| open_storage(world),
    );
    steps.step(&format!("{Q} is listed as offline"), |world, c, _| {
        world.wait_for_with(
            |w| {
                scope(w)["environments"]
                    .as_array()
                    .and_then(|rows| rows.iter().find(|row| row["label"] == c[0].as_str()))
                    .is_some_and(|row| row["online"] != json!(true))
            },
            |w| format!("{} to be listed offline; the scope is {}", c[0], show(&scope(w))),
        )
    });
    steps.step(
        "the user is editing settings across all environments",
        |world, _, _| {
            // The ledger's two other machines, when the feature has named none.
            if world.mc.members.is_empty() {
                support_here(world, supported());
                for name in ["Laptop", "Build box"] {
                    join_machine(world, name);
                }
            }
            open_storage(world)?;
            choose_environment(world, "")?;
            wait_ready(world, 3)
        },
    );
    steps.step(&format!("saving on {Q} fails"), |world, c, _| {
        document_of(&mut world.mc, &c[0]).refuse_writes = "disk full".into();
        Ok(())
    });
    steps.step("the user changes an environment-wide setting", |world, _, _| {
        change(world)
    });
    steps.step("the user changes a setting", |world, _, _| change(world));
    steps.step(
        &format!("the change is saved on {Q} and on {Q}"),
        |world, c, _| {
            world.wait_for(
                "merged worktree cleanup to be saved on every environment",
                |w| {
                    let this = w.mc.environment_id.clone();
                    let saved = |environment: &str| {
                        let settings = if environment == this {
                            w.mc.peek::<crate::steps::settings::FakeConfig>()
                                .map(|f| f.settings.clone())
                        } else {
                            w.mc.peek::<crate::steps::settings::FakeConfig>()
                                .and_then(|f| f.documents.get(environment))
                                .map(|d| d.settings.clone())
                        };
                        settings.is_some_and(|s| s["storageCleanup"]["worktreeOnMerge"] == json!(true))
                    };
                    saved(&c[0]) && saved(&c[1]) && saved(&this)
                },
            )
        },
    );
    steps.step(
        &format!("the user is told the setting saved on some environments and could not update {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    w.state("toasts")["items"].as_array().is_some_and(|items| {
                        items.iter().any(|toast| {
                            toast["title"] == "Setting saved on some environments"
                                && toast["description"].as_str().is_some_and(|d| d.contains(&c[0]))
                        })
                    })
                },
                |w| {
                    format!(
                        "a partial save to be reported; the shell shows {}",
                        show(&w.state("toasts"))
                    )
                },
            )?;
            expect!(
                cleanup_of(world, "Laptop", "worktreeOnMerge") == json!(true),
                "Laptop to have saved the change"
            );
            Ok(())
        },
    );
    steps.step(&format!("the user is editing settings for {Q}"), |world, c, _| {
        open_storage(world)?;
        choose_environment(world, &c[0])
    });
    steps.step("the user looks at an environment setting", |world, _, _| {
        world.wait_for_with(
            |w| scope(w)["disabledReason"].as_str().is_some_and(|r| !r.is_empty()),
            |w| format!("the scope to be disabled; it is {}", show(&scope(w))),
        )
    });
    steps.step("the setting cannot be changed", |world, _, _| {
        if !world.setting_row.is_empty() {
            // A row of Settings → General.
            let row = world.setting_row.clone();
            return expect_row_locked(world, &row);
        }
        expect!(
            scope(world)["editable"] != json!(true),
            "the setting to be locked"
        );
        let writes = fake_config(&mut world.mc).writes.len();
        change(world)?;
        world.sync()?;
        expect!(
            fake_config(&mut world.mc).writes.len() == writes,
            "nothing to be written"
        );
        Ok(())
    });
    steps.step(
        "the user is told to reconnect the selected environment to change it",
        |world, _, _| {
            expect!(
                scope(world)["disabledReason"]
                    == "Reconnect the selected environment to change this setting.",
                "the reconnect notice; the scope is {}",
                show(&scope(world))
            );
            Ok(())
        },
    );
}
