//! The native Scheduled Tasks settings section (ScheduledTasks, desktop-qt's
//! ScheduledTasksSteps.cpp): the settings scenarios of
//! features/settings/scheduled-tasks.feature. The fake keeps each
//! environment's tasks as the MC's HalC2.ScheduledTasks does, answering
//! scheduledTasks.* and the `scheduledTasks` shape.

use std::collections::HashMap;

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use serde_json::{Map, Value, json};

use super::settings::{document_of, fake_config, publish_providers};
use super::workspace::seed_branches;
use crate::expect;
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;

#[derive(Default)]
struct FakeTasks {
    /// By environment.
    tasks: HashMap<String, Vec<Value>>,
    next: i64,
    /// The scenario's new task, before it is saved.
    draft: Value,
}

fn environment_of(mc: &FakeMc, rpc: &Rpc) -> String {
    if rpc.environment.is_empty() {
        mc.environment_id.clone()
    } else {
        rpc.environment.clone()
    }
}

/// The environment a `scheduledTasks` shape follows: its `mc`'s.
fn shape_environment(mc: &FakeMc, shape: &Value) -> String {
    let named = text(&shape["mc"]);
    mc.peers
        .iter()
        .find(|(_, peer)| **peer == named)
        .map_or_else(
            || mc.environment_id.clone(),
            |(environment, _)| environment.clone(),
        )
}

fn listed(mc: &mut FakeMc, environment: &str) -> Value {
    Value::Array(
        mc.part::<FakeTasks>()
            .tasks
            .get(environment)
            .cloned()
            .unwrap_or_default(),
    )
}

/// An environment's list to its watchers, as HalC2.ScheduledTasks
/// broadcasts it.
fn broadcast(mc: &mut FakeMc, environment: &str) {
    for id in mc.subscribers("scheduledTasks") {
        if shape_environment(mc, &mc.shape_of(id)) != environment {
            continue;
        }
        let tasks = listed(mc, environment);
        mc.send(&json!({"t": "scheduledTasks", "id": id, "tasks": tasks}));
    }
}

fn index_of(tasks: &[Value], id: &str) -> Option<usize> {
    tasks.iter().position(|task| text(&task["id"]) == id)
}

fn answer(mc: &mut FakeMc, rpc: &Rpc) {
    let environment = environment_of(mc, rpc);
    let id = text(&rpc.payload["id"]);
    let fake = mc.part::<FakeTasks>();
    let at = index_of(fake.tasks.get(&environment).map_or(&[], Vec::as_slice), &id);
    if rpc.method == "scheduledTasks.upsert" {
        let mut task = rpc.payload.clone();
        if at.is_none() && task["requireExisting"].as_bool() == Some(true) {
            return mc.refuse(rpc, "Schedule task not found.");
        }
        task.as_object_mut()
            .map(|task| task.remove("requireExisting"));
        if id.is_empty() {
            fake.next += 1;
            task["id"] = json!(format!("task-{}", fake.next));
        }
        task["nextRunAt"] = if task["enabled"].as_bool() == Some(true) {
            json!("2099-01-01T09:00:00.000Z")
        } else {
            Value::Null
        };
        let tasks = fake.tasks.entry(environment.clone()).or_default();
        task["lastRunStatus"] = match at {
            Some(at) => tasks[at]["lastRunStatus"].clone(),
            None => json!("never"),
        };
        match at {
            Some(at) => tasks[at] = task.clone(),
            None => tasks.push(task.clone()),
        }
        mc.reply(rpc, task);
    } else if let Some(at) = at {
        let tasks = fake.tasks.entry(environment.clone()).or_default();
        if rpc.method == "scheduledTasks.delete" {
            tasks.remove(at);
            mc.reply(rpc, json!({}));
        } else if rpc.method == "scheduledTasks.setEnabled" {
            tasks[at]["enabled"] = rpc.payload["enabled"].clone();
            let task = tasks[at].clone();
            mc.reply(rpc, task);
        } else {
            mc.reply(rpc, json!({}));
        }
    } else {
        return mc.refuse(rpc, "Schedule task not found.");
    }
    broadcast(mc, &environment);
}

fn extension(mc: &mut FakeMc) {
    mc.on_shape("scheduledTasks", |mc, id, shape| {
        let environment = shape_environment(mc, shape);
        let tasks = listed(mc, &environment);
        mc.send(&json!({"t": "scheduledTasks", "id": id, "tasks": tasks}));
        Ok(())
    });
    mc.on_rpc("scheduledTasks.", |mc, rpc| {
        // A held save is answered once released, late.
        if mc.holding("scheduledTasks") && rpc.method == "scheduledTasks.upsert" {
            let rpc = rpc.clone();
            mc.defer(move |mc| answer(mc, &rpc));
            return Ok(());
        }
        answer(mc, rpc);
        Ok(())
    });
}

fn task(id: &str, title: &str, project: &str, fields: Value) -> Value {
    let mut result = json!({
        "id": id,
        "title": title,
        "prompt": format!("Look at {title}"),
        "enabled": true,
        "schedule": {"type": "fixed_time", "timeOfDay": "09:00"},
        "projectId": project,
        "threadId": null,
        "workspaceStrategy": {"type": "root"},
        "modelSelection": {"instanceId": "codex", "model": "codex-model"},
        "runtimeMode": "full-access",
        "interactionMode": "default",
        "nextRunAt": "2099-01-01T09:00:00.000Z",
        "lastRunStatus": "succeeded",
    });
    for (key, value) in fields.as_object().into_iter().flatten() {
        result[key] = value.clone();
    }
    result
}

fn seed(world: &mut World, task: Value) {
    let environment = world.mc.environment_id.clone();
    world
        .mc
        .part::<FakeTasks>()
        .tasks
        .entry(environment)
        .or_default()
        .push(task);
}

fn stored(world: &mut World) -> Vec<Value> {
    let environment = world.mc.environment_id.clone();
    world
        .mc
        .part::<FakeTasks>()
        .tasks
        .get(&environment)
        .cloned()
        .unwrap_or_default()
}

fn provider(instance: &str, name: &str, models: &[&str]) -> Value {
    let models: Vec<Value> = models
        .iter()
        .map(|model| json!({"slug": model, "name": model}))
        .collect();
    json!({"instanceId": instance, "driver": instance, "displayName": name,
        "enabled": true, "installed": true, "status": "ready",
        "auth": {"status": "authenticated"}, "models": models})
}

/// Codex and Claude on this machine, and "api" defaulting to Claude's model.
fn providers_here(world: &mut World) {
    publish_providers(
        &mut world.mc,
        vec![
            provider("codex", "Codex", &["codex-model"]),
            provider("claude", "Claude", &["claude-model"]),
        ],
    );
    let api = world
        .mc
        .projects
        .entry("api".to_owned())
        .or_insert_with(|| json!({}));
    api["defaultModelSelection"] = json!({"instanceId": "claude", "model": "claude-model"});
}

fn section(world: &World) -> Value {
    world.state("scheduledTasks")
}

fn scope(world: &World) -> Value {
    world.state("settingsScope")
}

fn editor(world: &World) -> Value {
    section(world)["editor"].clone()
}

fn is_empty(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::Object(object) => object.is_empty(),
        Value::Array(array) => array.is_empty(),
        Value::String(string) => string.is_empty(),
        _ => false,
    }
}

fn open_tasks(world: &mut World) -> Outcome {
    if world.shell_subscriptions() == 0 {
        world.connect()?;
        world.sync()?;
    }
    world.with::<Navigation, _>(|navigation, engine| {
        navigation.open(
            engine,
            Route::Settings("/settings/scheduled-tasks".to_owned()),
        )
    })?;
    world.wait_for_with(
        |w| section(w)["open"].as_bool() == Some(true) && !is_empty(&scope(w)),
        |w| format!("scheduled tasks to show; they are {}", show(&section(w))),
    )
}

/// This machine's listing, once loaded.
fn environment(world: &World, id: &str) -> Value {
    section(world)["environments"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|row| text(&row["id"]) == id)
        .cloned()
        .unwrap_or(Value::Null)
}

fn ready(world: &mut World) -> Outcome<Value> {
    let own = world.mc.environment_id.clone();
    world.wait_for_with(
        |w| environment(w, &own)["status"] == "ready",
        |w| {
            format!(
                "this machine's tasks to load; they are {}",
                show(&section(w))
            )
        },
    )?;
    Ok(environment(world, &own))
}

fn row(world: &mut World, title: &str) -> Outcome<Value> {
    let machine = ready(world)?;
    Ok(machine["tasks"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|task| text(&task["title"]) == title)
        .cloned()
        .unwrap_or(Value::Null))
}

fn choose(world: &mut World, list: &str, label: &str) -> Outcome<String> {
    let find = |w: &World| {
        scope(w)[list]
            .as_array()
            .into_iter()
            .flatten()
            .rfind(|entry| text(&entry["label"]) == label || text(&entry["title"]) == label)
            .map(|entry| text(&entry[if list == "projects" { "key" } else { "id" }]))
            .filter(|id| !id.is_empty())
    };
    world.wait_for_with(
        |w| find(w).is_some(),
        |w| format!("{label} to be offered; the scope is {}", show(&scope(w))),
    )?;
    Ok(find(world).unwrap_or_default())
}

/// A new task's editor, its draft filled in and changed by `change`.
fn new_draft(world: &mut World, change: Value) -> Outcome<Value> {
    open_tasks(world)?;
    ready(world)?;
    world.dispatch("scheduledTasks.new", Value::Null)?;
    world.wait_for_with(
        |w| !is_empty(&editor(w)),
        |w| format!("the editor to open; the section is {}", show(&section(w))),
    )?;
    let mut draft = editor(world)["draft"].clone();
    draft["title"] = json!("Check Sentry");
    draft["prompt"] = json!("Look at the new Sentry issues.");
    for (key, value) in change.as_object().into_iter().flatten() {
        draft[key] = value.clone();
    }
    Ok(draft)
}

fn save(world: &mut World, draft: &Value) -> Outcome {
    world.dispatch("scheduledTasks.save", json!({"draft": draft}))
}

fn saved_task(world: &mut World) -> Outcome<Value> {
    let own = world.mc.environment_id.clone();
    world.wait_for_with(
        |w| {
            w.mc.peek::<FakeTasks>()
                .and_then(|fake| fake.tasks.get(&own))
                .is_some_and(|tasks| !tasks.is_empty())
                && is_empty(&editor(w))
        },
        |w| format!("the task to be saved; the section is {}", show(&section(w))),
    )?;
    Ok(stored(world).last().cloned().unwrap_or(Value::Null))
}

fn list_of(names: &str) -> Vec<String> {
    names
        .split(',')
        .map(|name| name.trim().to_owned())
        .collect()
}

/// What the weekday buttons do (js/scheduledTasks.js toggleDay): a day
/// turned off or on, the last chosen day staying chosen.
fn toggle_day(days: &[Value], day: i64) -> Vec<Value> {
    let mut next = days.to_vec();
    match next.iter().position(|d| d.as_i64() == Some(day)) {
        None => next.push(json!(day)),
        Some(at) if next.len() > 1 => {
            next.remove(at);
        }
        Some(_) => {}
    }
    next
}

fn project_row(id: &str) -> Value {
    json!({"id": id, "title": id, "workspaceRoot": format!("/work/{id}"),
        "createdAt": "2026-09-01T09:00:00Z", "updatedAt": "2026-09-01T09:00:00Z",
        "scripts": []})
}

fn draft_of(world: &mut World) -> Value {
    world.mc.part::<FakeTasks>().draft.clone()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    steps.step("the user starts a new task", |world, _, _| {
        providers_here(world);
        let draft = new_draft(world, json!({}))?;
        world.mc.part::<FakeTasks>().draft = draft;
        Ok(())
    });
    steps.step(
        &format!("it starts in a new worktree from {Q} fetched from origin"),
        |world, c, _| {
            let draft = draft_of(world);
            expect!(
                draft["workspaceMode"] == "worktree"
                    && draft["baseRef"] == c[0].as_str()
                    && draft["startFromOrigin"].as_bool() == Some(true),
                "a new worktree from {}; the draft is {}",
                c[0],
                show(&draft)
            );
            Ok(())
        },
    );
    steps.step(
        "it runs at 09:00 on weekdays with full access",
        |world, _, _| {
            let draft = draft_of(world);
            save(world, &draft)?;
            let task = saved_task(world)?;
            let schedule = &task["schedule"];
            expect!(
                schedule["type"] == "fixed_time"
                    && schedule["timeOfDay"] == "09:00"
                    && schedule["weekdays"] == json!([1, 2, 3, 4, 5])
                    && task["runtimeMode"] == "full-access",
                "09:00 on weekdays with full access; the task is {}",
                show(&task)
            );
            Ok(())
        },
    );
    steps.step("its model is the project's default model", |world, _, _| {
        let task = saved_task(world)?;
        let selection = &task["modelSelection"];
        expect!(
            selection["instanceId"] == "claude" && selection["model"] == "claude-model",
            "api's Claude model; the task runs {}",
            show(selection)
        );
        Ok(())
    });

    steps.step(
        "the user creates a task that uses (a new worktree|the project checkout|a specific checkout)",
        |world, c, _| {
            providers_here(world);
            let mode = match c[0].as_str() {
                "a new worktree" => "worktree",
                "the project checkout" => "root",
                _ => "existing_worktree",
            };
            let draft = new_draft(
                world,
                json!({"workspaceMode": mode, "checkoutPath": "/work/api-review"}),
            )?;
            save(world, &draft)
        },
    );
    steps.step(
        "each run works in (a fresh worktree from the base|the project root|the chosen checkout path)",
        |world, c, _| {
            let workspace = saved_task(world)?["workspaceStrategy"].clone();
            let expected = match c[0].as_str() {
                "the project root" => json!({"type": "root"}),
                "the chosen checkout path" => {
                    json!({"type": "existing_worktree", "worktreePath": "/work/api-review"})
                }
                _ => json!({"type": "worktree", "baseRef": "main", "startFromOrigin": true}),
            };
            expect!(workspace == expected, "the workspace is {}", show(&workspace));
            Ok(())
        },
    );

    steps.step(
        "the user saves a task (without a prompt|that runs every 0 minutes|that uses a specific checkout with no path)",
        |world, c, _| {
            providers_here(world);
            let change = match c[0].as_str() {
                "without a prompt" => json!({"prompt": "  "}),
                "that runs every 0 minutes" => {
                    json!({"scheduleMode": "interval", "intervalMinutes": "0"})
                }
                _ => json!({"workspaceMode": "existing_worktree", "checkoutPath": ""}),
            };
            let draft = new_draft(world, change)?;
            save(world, &draft)?;
            world.sync()?;
            expect!(stored(world).is_empty(), "nothing to be saved");
            Ok(())
        },
    );
    steps.step(
        "the user saves a task on an environment that is disconnected",
        |world, _, _| {
            // The editor is open on another machine when that machine goes
            // offline.
            let laptop = "Laptop";
            fake_config(&mut world.mc)
                .elsewhere
                .insert(laptop.to_owned(), Map::new());
            document_of(&mut world.mc, laptop);
            world.mc.join_named(laptop);
            open_tasks(world)?;
            let id = choose(world, "environments", laptop)?;
            world.dispatch("settingsScope.environment", json!({"id": id}))?;
            world.wait_for_with(
                |w| environment(w, laptop)["status"] == "ready",
                |w| {
                    format!(
                        "Laptop's tasks to load; the section is {}",
                        show(&section(w))
                    )
                },
            )?;
            world.dispatch("scheduledTasks.new", Value::Null)?;
            world.wait_for_with(
                |w| editor(w)["connected"].as_bool() == Some(true),
                |w| {
                    format!(
                        "the editor to open on Laptop; the section is {}",
                        show(&section(w))
                    )
                },
            )?;
            let mut draft = editor(world)["draft"].clone();
            draft["title"] = json!("Check Sentry");
            draft["prompt"] = json!("Look at the new Sentry issues.");
            world.mc.set_online(laptop, false);
            world.wait_for_with(
                |w| editor(w)["connected"].as_bool() != Some(true),
                |w| {
                    format!(
                        "the editor to see the disconnect; it is {}",
                        show(&editor(w))
                    )
                },
            )?;
            save(world, &draft)
        },
    );

    steps.step(
        "a paused task and a task that failed its last run",
        |world, _, _| {
            seed(
                world,
                task(
                    "paused",
                    "Nightly build",
                    "api",
                    json!({"enabled": false, "nextRunAt": null}),
                ),
            );
            seed(
                world,
                task(
                    "failed",
                    "Check Sentry",
                    "api",
                    json!({"lastRunStatus": "failed",
                        "lastRunError": "The server stopped during this run."}),
                ),
            );
            Ok(())
        },
    );
    steps.step("the user opens scheduled tasks", |world, _, _| {
        open_tasks(world)
    });
    steps.step("the paused task says it is paused", |world, _, _| {
        let paused = row(world, "Nightly build")?;
        expect!(
            paused["when"] == "Paused" && paused["enabled"].as_bool() != Some(true),
            "the paused task is {}",
            show(&paused)
        );
        let other = row(world, "Check Sentry")?;
        expect!(
            text(&other["when"]).starts_with("Next run in"),
            "the other to say when it runs next; it is {}",
            show(&other)
        );
        Ok(())
    });
    steps.step("the failed task shows its last error", |world, _, _| {
        let failed = row(world, "Check Sentry")?;
        expect!(
            failed["lastRunStatus"] == "failed"
                && failed["lastRunError"] == "The server stopped during this run.",
            "the failed task is {}",
            show(&failed)
        );
        Ok(())
    });

    steps.step(&format!("tasks in projects {Q} and {Q}"), |world, c, _| {
        for project in [&c[0], &c[1]] {
            world
                .mc
                .projects
                .insert(project.clone(), project_row(project));
            seed(
                world,
                task(
                    &format!("{project}-task"),
                    &format!("{project} review"),
                    project,
                    json!({}),
                ),
            );
        }
        Ok(())
    });
    steps.step(
        &format!("the user views scheduled tasks for project {Q}"),
        |world, c, _| {
            open_tasks(world)?;
            let key = choose(world, "projects", &c[0])?;
            world.dispatch("settingsScope.project", json!({"key": key}))?;
            world.wait_for_with(
                |w| scope(w)["projectLabel"] == c[0].as_str(),
                |w| format!("the scope to be {}; it is {}", c[0], show(&scope(w))),
            )
        },
    );
    steps.step(
        &format!("only the tasks for {Q} are listed"),
        |world, c, _| {
            let own = world.mc.environment_id.clone();
            world.wait_for_with(
                |w| {
                    let tasks = environment(w, &own)["tasks"]
                        .as_array()
                        .cloned()
                        .unwrap_or_default();
                    environment(w, &own)["status"] == "ready"
                        && tasks.len() == 1
                        && text(&tasks[0]["title"]) == format!("{} review", c[0])
                },
                |w| format!("only {}'s task; the section is {}", c[0], show(&section(w))),
            )
        },
    );

    steps.step(&format!("a task {Q}"), |world, c, _| {
        seed(world, task("task-sentry", &c[0], "api", json!({})));
        Ok(())
    });
    steps.step("the user deletes the task", |world, _, _| {
        open_tasks(world)?;
        world.wait_for_with(
            |w| {
                let own = w.mc.environment_id.clone();
                environment(w, &own)["tasks"]
                    .as_array()
                    .is_some_and(|tasks| !tasks.is_empty())
            },
            |w| {
                format!(
                    "the task to be listed; the section is {}",
                    show(&section(w))
                )
            },
        )?;
        let environment_id = world.mc.environment_id.clone();
        world.dispatch(
            "scheduledTasks.delete",
            json!({"environmentId": environment_id, "id": "task-sentry"}),
        )
    });
    steps.step(
        "it no longer runs and is no longer listed",
        |world, _, _| {
            let own = world.mc.environment_id.clone();
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakeTasks>()
                        .and_then(|fake| fake.tasks.get(&own))
                        .is_none_or(Vec::is_empty)
                        && environment(w, &own)["status"] == "ready"
                        && environment(w, &own)["tasks"]
                            .as_array()
                            .is_none_or(Vec::is_empty)
                },
                |w| format!("the task to be gone; the section is {}", show(&section(w))),
            )
        },
    );

    steps.step(
        "the user follows a link to a task that was deleted",
        |world, _, _| {
            world.connect()?;
            world.sync()?;
            let environment_id = world.mc.environment_id.clone();
            world.dispatch(
                "scheduledTasks.open",
                json!({"environmentId": environment_id, "taskId": "task-gone"}),
            )
        },
    );
    steps.step("the user is told the task is unavailable", |world, _, _| {
        let own = world.mc.environment_id.clone();
        world.wait_for_with(
            |w| environment(w, &own)["linkMissing"].as_bool() == Some(true),
            |w| {
                format!(
                    "the link to be missing; the section is {}",
                    show(&section(w))
                )
            },
        )?;
        expect!(is_empty(&editor(world)), "no editor to open");
        Ok(())
    });

    steps.step(
        &format!("the environment {Q} is disconnected"),
        |world, c, _| {
            fake_config(&mut world.mc)
                .elsewhere
                .insert(c[0].clone(), Map::new());
            document_of(&mut world.mc, &c[0]);
            world.mc.join_named(&c[0]);
            world.mc.set_online(&c[0], false);
            Ok(())
        },
    );
    steps.step(
        &format!("the user opens scheduled tasks for {Q}"),
        |world, c, _| {
            open_tasks(world)?;
            let id = choose(world, "environments", &c[0])?;
            world.dispatch("settingsScope.environment", json!({"id": id}))
        },
    );
    steps.step(
        &format!("the user is offered to reconnect {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    let shown = environment(w, &c[0]);
                    shown["status"] == "disconnected"
                        && text(&shown["message"])
                            == format!("Reconnect {} to view its scheduled tasks.", c[0])
                },
                |w| {
                    format!(
                        "{} to be offered a reconnect; the section is {}",
                        c[0],
                        show(&section(w))
                    )
                },
            )
        },
    );

    // A save answered after the page was left and a new editor opened.
    steps.step(
        "the user saves a task and starts another before the save is answered",
        |world, _, _| {
            providers_here(world);
            world.mc.hold("scheduledTasks");
            let draft = new_draft(world, json!({}))?;
            save(world, &draft)?;
            world.wait_for_with(
                |w| editor(w)["saving"].as_bool() == Some(true),
                |w| format!("the save to be sent; the editor is {}", show(&editor(w))),
            )?;
            world.with::<Navigation, _>(|navigation, engine| {
                navigation.open(engine, Route::Settings("/settings/general".to_owned()))
            })?;
            world.wait_for("the section to close", |w| {
                section(w)["open"].as_bool() != Some(true)
            })?;
            open_tasks(world)?;
            world.dispatch("scheduledTasks.new", Value::Null)?;
            world.wait_for_with(
                |w| !is_empty(&editor(w)) && editor(w)["saving"].as_bool() != Some(true),
                |w| format!("a new editor to open; the section is {}", show(&section(w))),
            )?;
            world.mc.part::<FakeTasks>().draft = editor(world);
            world.mc.answer_held();
            Ok(())
        },
    );
    steps.step(
        "the first task is saved and the new task stays open",
        |world, _, _| {
            let own = world.mc.environment_id.clone();
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakeTasks>()
                        .and_then(|fake| fake.tasks.get(&own))
                        .is_some_and(|tasks| tasks.len() == 1)
                        && environment(w, &own)["tasks"]
                            .as_array()
                            .is_some_and(|tasks| tasks.len() == 1)
                },
                |w| {
                    format!(
                        "the first task to be listed; the section is {}",
                        show(&section(w))
                    )
                },
            )?;
            world.sync()?;
            let opened = draft_of(world);
            let shown = editor(world);
            expect!(
                !is_empty(&shown)
                    && shown["seq"] == opened["seq"]
                    && shown["editing"].as_bool() != Some(true)
                    && shown["saving"].as_bool() != Some(true),
                "the new task's editor to stay open; the section is {}",
                show(&section(world))
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the project {Q} has the branches {Q}"),
        |world, c, _| {
            let names = list_of(&c[1]);
            let branches: Vec<&str> = names.iter().map(String::as_str).collect();
            seed_branches(world, &c[0], &branches, branches[0]);
            Ok(())
        },
    );
    steps.step(
        &format!("the user starts a new task and types {Q} as its base branch"),
        |world, c, _| {
            providers_here(world);
            let draft = new_draft(world, json!({}))?;
            world.dispatch(
                "scheduledTasks.branches",
                json!({"projectId": draft["projectId"], "query": c[0]}),
            )
        },
    );
    steps.step(
        &format!("the base branches offered are {Q}"),
        |world, c, _| {
            let wanted = list_of(&c[0]);
            world.wait_for_with(
                |w| {
                    let names: Vec<String> = editor(w)["branches"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .map(|reference| text(&reference["name"]))
                        .collect();
                    names == wanted && editor(w)["branchesLoading"].as_bool() != Some(true)
                },
                |w| {
                    format!(
                        "{} to be offered; the editor is {}",
                        wanted.join(", "),
                        show(&editor(w))
                    )
                },
            )
        },
    );

    steps.step("a new task that runs only on Wednesday", |world, _, _| {
        providers_here(world);
        let draft = new_draft(world, json!({"weekdays": [3]}))?;
        world.mc.part::<FakeTasks>().draft = draft;
        Ok(())
    });
    steps.step(
        "the user turns Wednesday off and saves it",
        |world, _, _| {
            let mut draft = draft_of(world);
            let days = draft["weekdays"].as_array().cloned().unwrap_or_default();
            draft["weekdays"] = Value::Array(toggle_day(&days, 3));
            world.mc.part::<FakeTasks>().draft = draft.clone();
            save(world, &draft)
        },
    );
    steps.step("the task still runs on Wednesday", |world, _, _| {
        let task = saved_task(world)?;
        expect!(
            task["schedule"]["weekdays"] == json!([3]),
            "the schedule is {}",
            show(&task["schedule"])
        );
        Ok(())
    });

    steps.step(
        "a task saved by an older version that runs every 10 seconds",
        |world, _, _| {
            providers_here(world);
            seed(
                world,
                task(
                    "task-legacy",
                    "Poll",
                    "api",
                    json!({"schedule": {"type": "interval", "everyMs": 10000}}),
                ),
            );
            Ok(())
        },
    );
    steps.step("the user edits it", |world, _, _| {
        open_tasks(world)?;
        world.wait_for_with(
            |w| {
                let own = w.mc.environment_id.clone();
                environment(w, &own)["tasks"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|task| text(&task["title"]) == "Poll")
            },
            |w| format!("the task to be listed; it is {}", show(&section(w))),
        )?;
        let environment_id = world.mc.environment_id.clone();
        world.dispatch(
            "scheduledTasks.edit",
            json!({"environmentId": environment_id, "id": "task-legacy"}),
        )?;
        world.wait_for_with(
            |w| editor(w)["editing"].as_bool() == Some(true),
            |w| format!("the editor to open; the section is {}", show(&section(w))),
        )
    });
    steps.step(
        "the editor says saving raises the interval to a minute",
        |world, _, _| {
            expect!(
                editor(world)["legacyInterval"].as_bool() == Some(true),
                "the editor is {}",
                show(&editor(world))
            );
            Ok(())
        },
    );
    steps.step("saving it runs every minute", |world, _, _| {
        let draft = editor(world)["draft"].clone();
        save(world, &draft)?;
        world.wait_for_with(
            |w| is_empty(&editor(w)),
            |w| format!("the save to finish; the editor is {}", show(&editor(w))),
        )?;
        let schedule = stored(world)
            .last()
            .map_or(Value::Null, |task| task["schedule"].clone());
        expect!(
            schedule["everyMs"].as_f64() == Some(60000.0),
            "the schedule is {}",
            show(&schedule)
        );
        Ok(())
    });

    steps.step(
        "the user edits the task and another client deletes it",
        |world, _, _| {
            open_tasks(world)?;
            world.wait_for_with(
                |w| {
                    let own = w.mc.environment_id.clone();
                    environment(w, &own)["tasks"]
                        .as_array()
                        .is_some_and(|tasks| !tasks.is_empty())
                },
                |w| {
                    format!(
                        "the task to be listed; the section is {}",
                        show(&section(w))
                    )
                },
            )?;
            let environment_id = world.mc.environment_id.clone();
            world.dispatch(
                "scheduledTasks.edit",
                json!({"environmentId": environment_id, "id": "task-sentry"}),
            )?;
            world.wait_for_with(
                |w| editor(w)["editing"].as_bool() == Some(true),
                |w| format!("the editor to open; the section is {}", show(&section(w))),
            )?;
            world
                .mc
                .part::<FakeTasks>()
                .tasks
                .insert(environment_id.clone(), Vec::new());
            broadcast(&mut world.mc, &environment_id);
            Ok(())
        },
    );
    steps.step(
        "the editor says the task no longer exists",
        |world, _, _| {
            world.wait_for_with(
                |w| editor(w)["missing"].as_bool() == Some(true),
                |w| {
                    format!(
                        "the editor to say the task is gone; it is {}",
                        show(&editor(w))
                    )
                },
            )
        },
    );

    steps.step(&format!("the failed task is badged {Q}"), |world, c, _| {
        let failed = row(world, "Check Sentry")?;
        expect!(
            failed["lastRun"] == c[0].as_str(),
            "the failed task is {}",
            show(&failed)
        );
        Ok(())
    });
    steps.step("each task shows its prompt", |world, _, _| {
        for title in ["Nightly build", "Check Sentry"] {
            let shown = row(world, title)?;
            expect!(
                text(&shown["prompt"]) == format!("Look at {title}"),
                "the task is {}",
                show(&shown)
            );
        }
        Ok(())
    });
}
