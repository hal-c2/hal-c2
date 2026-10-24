//! What the MC holds (threads, projects) and does (updates, refusals, held
//! answers), and the orchestration commands it receives (desktop-qt's
//! McSteps.cpp).

use serde_json::{Map, Value, json};

use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// A thread row from a table's header and one of its rows.
pub fn thread_row(header: &[String], cells: &[String]) -> Value {
    let mut row = Map::new();
    for (column, name) in header.iter().enumerate() {
        let value = cells.get(column).cloned().unwrap_or_default();
        if value.is_empty() {
            continue;
        }
        let name = if name == "project" { "projectId" } else { name };
        row.insert(name.to_owned(), json!(value));
    }
    if !row.contains_key("createdAt") {
        row.insert("createdAt".into(), json!("2026-09-23T09:00:00Z"));
    }
    if !row.contains_key("updatedAt") {
        let created = row["createdAt"].clone();
        row.insert("updatedAt".into(), created);
    }
    Value::Object(row)
}

pub fn project_row(id: &str, title: &str, workspace_root: &str) -> Value {
    json!({
        "id": id,
        "title": title,
        "workspaceRoot": workspace_root,
        "createdAt": "2026-09-01T09:00:00Z",
        "updatedAt": "2026-09-01T09:00:00Z",
        "scripts": [],
    })
}

/// Before the shell connects the project is in the snapshot; after, it
/// arrives as a row.
pub fn add_project(world: &mut World, row: Value) -> Outcome {
    let id = text(&row["id"]);
    world.mc.projects.insert(id.clone(), row.clone());
    world.mc.send_row_of(&id, &row, "project");
    if world.running() && world.client_ready() {
        world.sync()?;
    }
    Ok(())
}

fn set_field(row: &mut Value, name: &str, value: &str) {
    // The MC sends the background tasks themselves; only their count matters here.
    if name == "pendingBackgroundTasks" {
        let count = value.parse::<usize>().unwrap_or(0);
        row[name] = Value::Array((0..count).map(|task| json!({"id": task})).collect());
    } else {
        row[name] = json!(value);
    }
}

/// The first unchecked command of `kind` (for `thread_id`, when given).
pub fn find_command(world: &World, kind: &str, thread_id: &str) -> Option<usize> {
    world
        .mc
        .commands
        .iter()
        .enumerate()
        .find_map(|(index, command)| {
            let fits = !world.checked_commands.contains(&index)
                && text(&command["type"]) == kind
                && (thread_id.is_empty() || text(&command["threadId"]) == thread_id);
            fits.then_some(index)
        })
}

pub fn expect_field(command: &Value, path: &str, expected: &str) -> Outcome {
    let actual = text(at(command, path));
    expect!(
        actual == expected,
        "expected {path} to be \"{expected}\" in {}",
        show(command)
    );
    Ok(())
}

fn table_rows(table: &[Vec<String>]) -> impl Iterator<Item = (&[String], &[String])> {
    let header = table.first().map(Vec::as_slice).unwrap_or(&[]);
    table
        .iter()
        .skip(1)
        .map(move |row| (header, row.as_slice()))
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the MC's environment does not track visits",
        |world, _, _| {
            if let Some(capabilities) = world.mc.capabilities.as_object_mut() {
                capabilities.remove("threadVisitedTracking");
            }
            Ok(())
        },
    );
    steps.step("the MC has these threads:", |world, _, table| {
        for (header, cells) in table_rows(table) {
            let thread = thread_row(header, cells);
            world.mc.threads.insert(text(&thread["id"]), thread);
        }
        Ok(())
    });

    // The MC's updates.
    steps.step(
        &format!("the MC updates the thread {Q} with the title {Q}"),
        |world, c, _| {
            let row = world
                .mc
                .threads
                .entry(c[0].clone())
                .or_insert_with(|| json!({}));
            row["title"] = json!(c[1]);
            let row = row.clone();
            world.mc.send_row(&c[0], &row);
            world.sync()
        },
    );
    steps.step(
        &format!("the MC updates the thread {Q} with:"),
        |world, c, table| {
            let row = world
                .mc
                .threads
                .entry(c[0].clone())
                .or_insert_with(|| json!({}));
            for cells in table {
                let name = cells.first().cloned().unwrap_or_default();
                let value = cells.get(1).cloned().unwrap_or_default();
                set_field(row, &name, &value);
            }
            let row = row.clone();
            world.mc.send_row(&c[0], &row);
            world.sync()
        },
    );
    steps.step(&format!("the MC deletes the thread {Q}"), |world, c, _| {
        let mut row = world.mc.threads.remove(&c[0]).unwrap_or_else(|| json!({}));
        row["deletedAt"] = json!("2026-09-23T10:00:00Z");
        world.mc.send_row(&c[0], &row);
        world.sync()
    });
    steps.step(&format!("the MC refuses {Q} with {Q}"), |world, c, _| {
        world.mc.refusals.insert(c[0].clone(), c[1].clone());
        Ok(())
    });
    steps.step("the MC holds its answers", |world, _, _| {
        world.mc.hold("answers");
        Ok(())
    });
    steps.step("the MC answers", |world, _, _| {
        // Every held command has reached the MC.
        world.sync()?;
        world.mc.answer_held();
        world.sync()
    });

    // What the MC received.
    steps.step(
        &format!("the MC receives an? {Q} command for {Q}"),
        |world, c, _| {
            let (kind, thread) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                |w| find_command(w, &kind, &thread).is_some(),
                |w| {
                    format!(
                        "a {} command for {}; the MC has {}",
                        c[0],
                        c[1],
                        w.describe_commands()
                    )
                },
            )?;
            let found = find_command(world, &c[0], &c[1]);
            world.command = found;
            if let Some(index) = found {
                world.checked_commands.insert(index);
            }
            Ok(())
        },
    );
    steps.step(&format!("the command's {Q} is {Q}"), |world, c, _| {
        let Some(index) = world.command else {
            fail!("no command was found before");
        };
        expect_field(&world.mc.commands[index], &c[0], &c[1])
    });
    steps.step(
        &format!("the command {Q} has {Q} {Q}"),
        |world, c, _| match world
            .mc
            .commands
            .iter()
            .find(|command| text(&command["type"]) == c[0])
        {
            Some(command) => expect_field(command, &c[1], &c[2]),
            None => fail!(
                "no {} command; the MC has {}",
                c[0],
                world.describe_commands()
            ),
        },
    );
    steps.step(
        "the MC receives these commands in order:",
        |world, _, table| {
            let wanted = table.len().saturating_sub(1);
            world.wait_for(&format!("{wanted} commands"), |w| {
                w.mc.commands.len() >= wanted
            })?;
            world.sync()?;
            expect!(
                world.mc.commands.len() == wanted,
                "the MC has {}",
                world.describe_commands()
            );
            for (row, cells) in table.iter().enumerate().skip(1) {
                let kind = text(&world.mc.commands[row - 1]["type"]);
                let expected = cells.first().cloned().unwrap_or_default();
                expect!(kind == expected, "command {row} is {kind}, not {expected}");
                world.checked_commands.insert(row - 1);
            }
            Ok(())
        },
    );
    steps.step(
        "the MC receives these messages in order:",
        |world, _, table| {
            fn texts(world: &World) -> Vec<String> {
                world
                    .mc
                    .commands
                    .iter()
                    .filter(|command| text(&command["type"]) == "message.dispatch")
                    .map(|command| text(&command["text"]))
                    .collect()
            }
            let wanted: Vec<String> = table
                .iter()
                .skip(1)
                .map(|row| row.first().cloned().unwrap_or_default())
                .collect();
            let count = wanted.len();
            world.wait_for(&format!("{count} messages"), |w| texts(w).len() >= count)?;
            world.sync()?;
            let got = texts(world);
            expect!(got == wanted, "the MC has the messages {}", got.join(", "));
            Ok(())
        },
    );
    steps.step("the MC receives no commands", |world, _, _| {
        world.sync()?;
        expect!(
            world.mc.commands.is_empty(),
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });
    steps.step("the MC receives no other commands", |world, _, _| {
        world.sync()?;
        expect!(
            world.mc.commands.len() == world.checked_commands.len(),
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });

    // The MC's projects.
    steps.step(
        &format!("the MC has the project {Q} at {Q}"),
        |world, c, _| {
            world.mc.projects.insert(
                c[0].clone(),
                json!({"id": c[0], "title": c[0], "workspaceRoot": c[1], "scripts": []}),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the MC has the project {Q} titled {Q}"),
        |world, c, _| add_project(world, project_row(&c[0], &c[1], &format!("/work/{}", c[1]))),
    );
    steps.step("the MC has these projects:", |world, _, table| {
        let rows: Vec<Value> = table_rows(table)
            .map(|(header, line)| {
                let cell = |name: &str| {
                    header
                        .iter()
                        .position(|h| h == name)
                        .and_then(|i| line.get(i))
                        .cloned()
                        .unwrap_or_default()
                };
                let title = cell("title");
                let root = header
                    .iter()
                    .position(|h| h == "workspaceRoot")
                    .and_then(|i| line.get(i).cloned())
                    .unwrap_or_else(|| format!("/work/{title}"));
                let mut row = project_row(&cell("id"), &title, &root);
                let created = cell("createdAt");
                if !created.is_empty() {
                    row["createdAt"] = json!(created);
                    row["updatedAt"] = json!(created);
                }
                let repository = cell("repository");
                if !repository.is_empty() {
                    let name = repository.rsplit('/').next().unwrap_or_default().to_owned();
                    row["repositoryIdentity"] = json!({"canonicalKey": repository, "name": name});
                }
                row
            })
            .collect();
        for row in rows {
            add_project(world, row)?;
        }
        Ok(())
    });
    steps.step(&format!("the MC removes the project {Q}"), |world, c, _| {
        world.mc.projects.remove(&c[0]);
        world.mc.send_row_of(
            &c[0],
            &json!({"deletedAt": "2026-09-23T10:00:00Z"}),
            "project",
        );
        world.sync()
    });
    steps.step(
        &format!("the project {Q} has these scripts:"),
        |world, c, table| {
            let scripts: Vec<Value> = table_rows(table)
                .map(|(header, row)| {
                    let script: Map<String, Value> = header
                        .iter()
                        .enumerate()
                        .map(|(i, name)| {
                            (name.clone(), json!(row.get(i).cloned().unwrap_or_default()))
                        })
                        .collect();
                    Value::Object(script)
                })
                .collect();
            let project = world
                .mc
                .projects
                .entry(c[0].clone())
                .or_insert_with(|| json!({}));
            project["scripts"] = Value::Array(scripts);
            Ok(())
        },
    );
}
