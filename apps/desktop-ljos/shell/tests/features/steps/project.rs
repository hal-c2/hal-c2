//! Projects (the projects controller and the sidebar's grouping): the MC's
//! `projects.mutate`, adding a local folder, asking before removing, and the
//! domain's thread-list scenarios (desktop-qt's ProjectSteps.cpp).

use std::collections::{BTreeSet, HashMap};
use std::path::PathBuf;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::drafts;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use serde_json::{Value, json};

use crate::brick::Brick;
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::{OTHER_MACHINE, World};
use crate::{expect, fail};

const AT: &str = "2026-09-23T09:00:00Z";

/// What the fake MC's `projects.mutate` saw, and the error it answers with:
/// `refusal` everywhere, `refused_on` on one environment. Other members'
/// projects are their rows.
#[derive(Default)]
pub struct FakeProjects {
    pub mutations: Vec<Value>,
    pub refusal: String,
    pub refused_on: HashMap<String, String>,
}

fn deleted() -> Value {
    json!({"deletedAt": "2026-09-23T10:00:00Z"})
}

/// `row` with the payload's fields (but its type and project) set.
fn updated(mut row: Value, payload: &Value) -> Value {
    if let Some(fields) = payload.as_object() {
        for (name, value) in fields {
            if name != "type" && name != "projectId" {
                row[name] = value.clone();
            }
        }
    }
    row
}

/// The last part of a path, as QFileInfo::fileName gives it.
fn file_name(path: &str) -> String {
    path.trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or_default()
        .to_owned()
}

/// The MC answers before the row arrives, which the shell must not trip on.
fn extension(mc: &mut FakeMc) {
    mc.on_rpc("projects.mutate", |mc, rpc| {
        mutate(mc, rpc);
        Ok(())
    });
}

fn mutate(mc: &mut FakeMc, rpc: &Rpc) {
    let fake = mc.part::<FakeProjects>();
    fake.mutations.push(rpc.payload.clone());
    if !fake.refusal.is_empty() {
        let refusal = fake.refusal.clone();
        mc.refuse(rpc, &refusal);
        return;
    }
    let kind = text(&rpc.payload["type"]);
    let id = text(&rpc.payload["projectId"]);
    let environment = if rpc.environment.is_empty() {
        mc.environment_id.clone()
    } else {
        rpc.environment.clone()
    };
    if let Some(refusal) = mc.part::<FakeProjects>().refused_on.get(&environment) {
        let refusal = refusal.clone();
        mc.refuse(rpc, &refusal);
        return;
    }
    // Another member's projects are its rows.
    if environment != mc.environment_id {
        let entry = mc
            .peer_rows
            .get(&environment)
            .and_then(|rows| rows.get(&id))
            .cloned();
        let supported = kind == "project.update" || kind == "project.delete";
        let Some(entry) = entry.filter(|_| supported) else {
            mc.refuse(rpc, &format!("{kind} of {id} is not supported"));
            return;
        };
        let row = if kind == "project.delete" {
            deleted()
        } else {
            updated(entry[2].clone(), &rpc.payload)
        };
        mc.reply(rpc, json!({}));
        mc.send_peer_row_of(&environment, &id, &row, "project");
        return;
    }
    match kind.as_str() {
        "project.update" => {
            let Some(row) = mc.projects.get(&id).cloned() else {
                mc.refuse(rpc, &format!("unknown project {id}"));
                return;
            };
            let row = updated(row, &rpc.payload);
            mc.projects.insert(id.clone(), row.clone());
            mc.reply(rpc, row.clone());
            mc.send_row_of(&id, &row, "project");
        }
        "project.create" => {
            let root = text(&rpc.payload["workspaceRoot"]);
            let row = json!({
                "id": id,
                "title": file_name(&root),
                "workspaceRoot": root,
                "createdAt": "2026-09-23T10:00:00Z",
                "updatedAt": "2026-09-23T10:00:00Z",
                "scripts": [],
            });
            mc.reply(rpc, row.clone());
            mc.projects.insert(id.clone(), row.clone());
            mc.send_row_of(&id, &row, "project");
        }
        "project.delete" => {
            if !mc.projects.contains_key(&id) {
                mc.refuse(rpc, &format!("unknown project {id}"));
                return;
            }
            let threads: Vec<String> = mc
                .threads
                .iter()
                .filter(|(_, row)| text(&row["projectId"]) == id)
                .map(|(thread, _)| thread.clone())
                .collect();
            if !threads.is_empty() && rpc.payload["force"] != json!(true) {
                mc.refuse(rpc, &format!("Project {id} is not empty."));
                return;
            }
            for thread in &threads {
                mc.threads.remove(thread);
                mc.send_row(thread, &deleted());
            }
            mc.projects.remove(&id);
            mc.send_row_of(&id, &deleted(), "project");
            mc.reply(rpc, json!({}));
        }
        other => mc.refuse(rpc, &format!("{other} is not supported")),
    }
}

fn mutations(world: &mut World, kind: &str) -> Vec<Value> {
    world
        .mc
        .part::<FakeProjects>()
        .mutations
        .iter()
        .filter(|m| m["type"] == json!(kind))
        .cloned()
        .collect()
}

/// Where a folder the scenario names lives on this machine: under the
/// World's home.
pub fn local_path(world: &World, path: &str) -> String {
    let config = world.config_dir();
    let base = config.parent().map(PathBuf::from).unwrap_or(config);
    base.join("files")
        .join(path.trim_start_matches('/'))
        .to_string_lossy()
        .into_owned()
}

/// The folder `path` names, made on this machine, as the OS names it.
pub fn make_folder(world: &World, path: &str) -> Outcome<String> {
    let local = local_path(world, path);
    if let Err(error) = std::fs::create_dir_all(&local) {
        fail!("cannot make {local}: {error}");
    }
    Ok(std::fs::canonicalize(&local)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or(local))
}

/// A project row on the MC (in the snapshot, or as a row once connected).
pub fn add_project(world: &mut World, id: &str, title: &str, root: &str) -> Outcome {
    let row = json!({
        "id": id,
        "title": title,
        "workspaceRoot": root,
        "createdAt": AT,
        "updatedAt": AT,
        "scripts": [],
    });
    world.mc.projects.insert(id.to_owned(), row.clone());
    world.mc.send_row_of(id, &row, "project");
    if world.running() && world.client_ready() {
        world.sync()?;
    }
    Ok(())
}

/// A thread row on the MC; `row` holds its fields, and gets the id and the
/// times it lacks.
pub fn add_thread(world: &mut World, id: &str, mut row: Value) -> Outcome {
    row["id"] = json!(id);
    if row.get("createdAt").is_none() {
        row["createdAt"] = json!(AT);
    }
    if row.get("updatedAt").is_none() {
        row["updatedAt"] = row["createdAt"].clone();
    }
    world.mc.threads.insert(id.to_owned(), row.clone());
    world.mc.send_row(id, &row);
    if world.running() && world.client_ready() {
        world.sync()?;
    }
    Ok(())
}

/// The MC serves `environment_id`, and the shell is connected to it.
pub fn connect_as(world: &mut World, environment_id: &str) -> Outcome {
    world.mc.environment_id = environment_id.to_owned();
    world.connect()?;
    world.sync()
}

fn sidebar_projects(world: &World) -> Vec<Value> {
    at(&world.state("sidebar"), "projects")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// The sidebar's projects named `name`, with their environments.
fn project_environments(world: &World, name: &str) -> Vec<String> {
    sidebar_projects(world)
        .iter()
        .filter(|p| p["displayName"] == json!(name))
        .map(|p| text(&p["environmentId"]))
        .collect()
}

fn project_names(world: &World) -> Vec<String> {
    sidebar_projects(world)
        .iter()
        .map(|p| text(&p["displayName"]))
        .collect()
}

fn thread_titles(world: &World) -> Vec<String> {
    let sidebar = world.state("sidebar");
    ["pinned", "active", "snoozed", "settled"]
        .iter()
        .flat_map(|section| {
            at(&sidebar, section)
                .as_array()
                .cloned()
                .unwrap_or_default()
        })
        .map(|row| text(&row["title"]))
        .collect()
}

fn removal(world: &World) -> Value {
    world.state("projectRemoval")
}

fn ask_to_remove(world: &mut World, name: &str) -> Outcome {
    let key = world.project_key(name);
    world.dispatch("project.remove", json!({"projectKey": key}))
}

fn route_is_home(world: &World) -> Outcome {
    let route = world.state("route");
    expect!(
        at(&route, "kind") == "home",
        "the route is {}",
        show(&route)
    );
    Ok(())
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // Environments and their projects.
    steps.step(&format!("a connected environment {Q}"), |world, c, _| {
        connect_as(world, &c[0])
    });
    steps.step(
        &format!("a connected environment with the projects {Q} and {Q}"),
        |world, c, _| {
            for name in c {
                add_project(world, name, name, &format!("/work/{name}"))?;
            }
            let environment = world.mc.environment_id.clone();
            connect_as(world, &environment)
        },
    );
    steps.step(
        &format!("a connected environment {Q} with the project {Q} at {Q}"),
        |world, c, _| {
            add_project(world, &c[1], &c[1], &c[2])?;
            connect_as(world, &c[0])
        },
    );
    steps.step(&format!("the folder {Q} exists on {Q}"), |world, c, _| {
        make_folder(world, &c[0]).map(|_| ())
    });
    steps.step(
        &format!("{Q} is already a project on {Q} with an unsettled thread {Q}"),
        |world, c, _| {
            let root = make_folder(world, &format!("/home/sam/{}", c[0]))?;
            add_project(world, &c[0], &c[0], &root)?;
            add_thread(
                world,
                "t-latest",
                json!({"projectId": c[0], "title": c[2],
                       "latestUserMessageAt": "2026-09-23T09:30:00Z"}),
            )?;
            add_thread(
                world,
                "t-settled",
                json!({"projectId": c[0], "title": "Done", "settledOverride": "settled",
                       "latestUserMessageAt": "2026-09-23T09:45:00Z"}),
            )
        },
    );
    steps.step(&format!("{Q} has (\\d+) threads"), |world, c, _| {
        let count: usize = c[1].parse().unwrap_or(0);
        for index in 1..=count {
            add_thread(
                world,
                &format!("{}-{index}", c[0]),
                json!({"projectId": c[0], "title": format!("Thread {index}")}),
            )?;
        }
        Ok(())
    });
    // A new thread the user typed into and left.
    steps.step(&format!("{Q} has an unsent draft"), |world, c, _| {
        let key = world.project_key(&c[0]);
        world.start_new_thread(json!({"projectKey": key}))?;
        let revision = world.next_edit;
        world.next_edit += 1;
        let target = world.draft_id.clone();
        world.dispatch(
            "composer.text.set",
            json!({"target": target,
                   "edit": {"clientId": "qml", "revision": revision},
                   "text": "Unsent work", "cursor": 11}),
        )?;
        world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Home))
    });
    steps.step(
        &format!("the environments {Q} and {Q} both have a project {Q}"),
        |world, c, _| {
            for environment in [&c[0], &c[1]] {
                let mc = format!("mc-{environment}");
                world.mc.join(&mc, environment);
                let subscription = world.mc.subscribers("shell").first().copied().unwrap_or(0);
                let row = json!({"id": c[2], "title": c[2],
                                 "workspaceRoot": format!("/work/{}", c[2]),
                                 "createdAt": AT, "updatedAt": AT});
                world.mc.send(&json!({
                    "t": "shell.rows", "id": subscription, "mc": mc,
                    "rows": [[c[2], "project", row]],
                }));
            }
            world.sync()
        },
    );
    steps.step(
        &format!("the environment refuses to change projects with {Q}"),
        |world, c, _| {
            world.mc.part::<FakeProjects>().refusal = c[0].clone();
            Ok(())
        },
    );
    steps.step("the local environment is disconnected", |world, _, _| {
        world.mc.stop_accepting();
        world.mc.drop_connection();
        world.wait_for("the shell to see the drop", |w| !w.client_ready())
    });
    steps.step("the shell may not open local folders", |world, _, _| {
        Bridge::of(world.engine()).set_local_folder_import_enabled(world.engine(), false);
        world.pump()
    });
    steps.step("the shell's MC runs on another machine", |world, _, _| {
        world.served_from(OTHER_MACHINE)
    });
    // Sidebar.qml and HomePage.qml open the folder picker on the sidebar's localFolders.
    for here in [true, false] {
        let words = if here {
            "adding a project picks a folder on this machine"
        } else {
            "adding a project does not pick a folder on this machine"
        };
        steps.step(words, move |world, _, _| {
            let local = at(&world.state("sidebar"), "localFolders").clone();
            expect!(
                local == json!(here),
                "the thread list's localFolders is {}",
                text(&local)
            );
            Ok(())
        });
    }
    steps.step(
        "the user asks to add a project without a folder",
        |world, _, _| world.dispatch("project.add", json!({})),
    );
    steps.step(
        "the desktop app is connected to its own local environment",
        |world, _, _| {
            if world.shell_subscriptions() == 0 {
                world.connect()?;
                world.sync()?;
            }
            let enabled = Bridge::of(world.engine()).local_folder_import_enabled(world.engine());
            expect!(
                enabled && world.client_ready(),
                "the shell is not connected to its own environment"
            );
            Ok(())
        },
    );

    // Threads in the domain's words.
    steps.step(
        &format!("the user last wrote in {Q} after {Q}"),
        |world, c, _| {
            add_thread(
                world,
                "t-later",
                json!({"projectId": c[0], "title": "Later",
                       "latestUserMessageAt": "2026-09-23T09:30:00Z"}),
            )?;
            add_thread(
                world,
                "t-earlier",
                json!({"projectId": c[1], "title": "Earlier",
                       "latestUserMessageAt": "2026-09-23T09:10:00Z"}),
            )
        },
    );
    steps.step(
        &format!("the agent in {Q} started a helper agent thread"),
        |world, c, _| {
            let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
            add_thread(
                world,
                "t-parent",
                json!({"projectId": project, "title": c[0]}),
            )?;
            add_thread(
                world,
                "t-helper",
                json!({"projectId": project, "title": "Helper",
                       "lineage": {"parentThreadId": "t-parent",
                                   "relationshipToParent": "subagent"}}),
            )
        },
    );
    steps.step(
        &format!("the thread list is scoped to the project {Q}"),
        |world, c, _| {
            if project_environments(world, &c[0]).is_empty() {
                add_project(world, &c[0], &c[0], &format!("/work/{}", c[0]))?;
            }
            let key = world.project_key(&c[0]);
            world.dispatch("sidebar.scope", json!({"projectKey": key}))
        },
    );

    steps.step(&format!("{Q} has no projects"), |world, c, _| {
        world.sync()?;
        let names = project_names(world);
        expect!(
            world.mc.environment_id == c[0] && names.is_empty(),
            "{} lists the projects {}",
            c[0],
            names.join(", ")
        );
        Ok(())
    });

    // Home as the window draws it (HomePage.qml), with nothing to open.
    steps.step("the user opens the app", |world, _, _| {
        world.sync()?;
        route_is_home(world)?;
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nHomePage {}\n",
            900.0,
            700.0,
        )
    });
    steps.step(
        "the user is asked what they should work on",
        |world, _, _| {
            let brick = crate::brick::shown(world)?;
            let title = brick.item(world, "homeTitle")?;
            let words = brick.text_of(world, title, "text");
            expect!(
                brick.flag(world, title, "visible") && words == "What should we work on?",
                "home says \"{words}\""
            );
            Ok(())
        },
    );
    steps.step("the user is offered to add a project", |world, _, _| {
        let brick = crate::brick::shown(world)?;
        let action = brick.item(world, "homeAction")?;
        let words = brick.text_of(world, action, "text");
        expect!(
            brick.flag(world, action, "visible") && words == "Add project",
            "home offers \"{words}\""
        );
        Ok(())
    });

    // The user.
    steps.step(
        "the user looks at the (?:projects|thread list)",
        |world, _, _| world.sync(),
    );
    // The sidebar's folder picker and the drop target hand over the folder as this machine names it.
    steps.step(
        &format!("the user adds the local folder {Q}"),
        |world, c, _| {
            let path = local_path(world, &c[0]);
            world.dispatch("project.add", json!({"path": path}))
        },
    );
    steps.step(
        &format!("the user drops the folder {Q} on the window"),
        |world, c, _| {
            let path = make_folder(world, &c[0])?;
            world.dispatch("project.folder.open", json!({"path": path}))
        },
    );
    steps.step(
        &format!("the user adds the local folder of {Q} again"),
        |world, c, _| {
            let root =
                text(&world.mc.projects.get(&c[0]).cloned().unwrap_or_default()["workspaceRoot"]);
            world.dispatch("project.add", json!({"path": root}))
        },
    );
    steps.step(&format!("the user asks to remove {Q}"), |world, c, _| {
        ask_to_remove(world, &c[0])
    });
    steps.step(
        &format!("the user confirms removing {Q}(?: everywhere)?"),
        |world, c, _| {
            ask_to_remove(world, &c[0])?;
            world.dispatch("project.remove.confirm", json!({}))?;
            world.sync()
        },
    );
    steps.step("the user cancels", |world, _, _| {
        if let Some(answer) = world.answer_question.take() {
            return answer(world, false);
        }
        // "Edit from here?" (timeline/checkpoints).
        if super::checkpoint_edit::cancel_rewind_question(world)? {
            return Ok(());
        }
        world.dispatch("project.remove.cancel", json!({}))
    });
    steps.step(&format!("the folder explorer shows {Q}"), |world, c, _| {
        world.sync()?;
        let sidebar = world.state("sidebar");
        let local = at(&sidebar, "localProjects")
            .as_array()
            .cloned()
            .unwrap_or_default();
        expect!(
            local.iter().any(|p| p["workspaceRoot"] == json!(c[0])),
            "the explorer's projects are {}",
            show(&json!(local))
        );
        Ok(())
    });
    steps.step(
        &format!("the user removes {Q} from HAL-C2"),
        |world, c, _| {
            // FolderExplorer.qml: the registered project at the selected folder.
            let sidebar = world.state("sidebar");
            let local = at(&sidebar, "localProjects")
                .as_array()
                .cloned()
                .unwrap_or_default();
            for project in local {
                if project["workspaceRoot"] != json!(c[0]) {
                    continue;
                }
                return world.dispatch("project.remove", json!({"projectKey": project["key"]}));
            }
            fail!("no project at {}", c[0])
        },
    );

    // What the user sees.
    steps.step(
        &format!("the (?:project )?{Q} is listed for {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| project_environments(w, &c[0]).contains(&w.mc.environment_id),
                |w| {
                    format!(
                        "{} to be listed; the sidebar lists {}",
                        c[0],
                        project_names(w).join(", ")
                    )
                },
            )
        },
    );
    steps.step(&format!("{Q} is still listed for {Q}"), |world, c, _| {
        world.sync()?;
        expect!(
            project_environments(world, &c[0]).contains(&world.mc.environment_id),
            "the sidebar lists {}",
            project_names(world).join(", ")
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} is no longer listed for {Q}"),
        |world, c, _| {
            world.sync()?;
            expect!(
                !project_environments(world, &c[0]).contains(&world.mc.environment_id),
                "the sidebar lists {}",
                project_names(world).join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the sidebar lists the projects {Q}"),
        |world, c, _| {
            world.sync()?;
            let names = project_names(world).join(", ");
            expect!(names == c[0], "the sidebar lists the projects \"{names}\"");
            Ok(())
        },
    );
    // Projects, or threads when the names are threads'.
    steps.step(&format!("{Q} is listed above {Q}"), |world, c, _| {
        world.sync()?;
        let projects = project_names(world);
        let threads = !projects.contains(&c[0]);
        let names = if threads {
            thread_titles(world)
        } else {
            projects
        };
        let first = names.iter().position(|n| *n == c[0]);
        let second = names.iter().position(|n| *n == c[1]);
        expect!(
            matches!((first, second), (Some(a), Some(b)) if a < b),
            "the sidebar lists the {} {}",
            if threads { "threads" } else { "projects" },
            names.join(", ")
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} is listed once for each environment"),
        |world, c, _| {
            world.sync()?;
            let environments = project_environments(world, &c[0]);
            let distinct: BTreeSet<&String> = environments.iter().collect();
            expect!(
                environments.len() == distinct.len() && environments.len() >= 2,
                "{} is listed for {}",
                c[0],
                environments.join(", ")
            );
            Ok(())
        },
    );
    steps.step("the helper thread is not listed", |world, _, _| {
        world.sync()?;
        let titles = thread_titles(world);
        expect!(
            !titles.iter().any(|t| t == "Helper") && titles.iter().any(|t| t == "Alpha"),
            "the sidebar lists {}",
            titles.join(", ")
        );
        Ok(())
    });
    steps.step(&format!("the thread {Q} opens"), |world, c, _| {
        world.sync()?;
        let route = world.state("route");
        expect!(
            at(&route, "title") == &json!(c[0]),
            "the route is {}",
            show(&route)
        );
        Ok(())
    });
    steps.step("no (?:second )?project is created", |world, _, _| {
        world.sync()?;
        let created = mutations(world, "project.create");
        expect!(
            created.is_empty(),
            "the MC was asked to create {} project(s)",
            created.len()
        );
        Ok(())
    });
    steps.step(
        "the user is told the folder could not be opened",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    at(&w.state("toasts"), "items")
                        .as_array()
                        .is_some_and(|items| {
                            items
                                .iter()
                                .any(|t| t["title"] == json!("Could not open folder"))
                        })
                },
                |w| format!("a toast; the shell shows {}", show(&w.state("toasts"))),
            )
        },
    );
    steps.step(
        "the user is told (\\d+) threads and their conversation history will be cleared",
        |world, c, _| {
            world.sync()?;
            let removal = removal(world);
            expect!(
                at(&removal, "threadCount").as_i64() == c[0].parse::<i64>().ok(),
                "the confirmation is {}",
                show(&removal)
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told the files on disk are kept",
        |world, _, _| {
            // ProjectRemovalDialog.qml names the folder it keeps.
            let removal = removal(world);
            expect!(
                !text(&removal["workspaceRoot"]).is_empty(),
                "the confirmation is {}",
                show(&removal)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the removal confirmation for {Q} on {Q} opens"),
        |world, c, _| {
            world.sync()?;
            let removal = removal(world);
            expect!(
                removal["title"] == json!(c[0])
                    && text(&removal["projectKey"]).starts_with(&format!("{}:", c[1])),
                "the confirmation is {}",
                show(&removal)
            );
            Ok(())
        },
    );
    steps.step("the removal confirmation is closed", |world, _, _| {
        world.sync()?;
        let removal = removal(world);
        expect!(removal.is_null(), "the confirmation is {}", show(&removal));
        Ok(())
    });
    steps.step(&format!("the draft for {Q} is gone"), |world, _, _| {
        world.sync()?;
        let sidebar = world.state("sidebar");
        let listed = at(&sidebar, "drafts")
            .as_array()
            .cloned()
            .unwrap_or_default();
        expect!(
            listed.is_empty(),
            "the sidebar lists the drafts {}",
            show(&json!(listed))
        );
        expect!(
            drafts::draft(world.engine(), &world.draft_id).is_none(),
            "the desktop keeps the draft"
        );
        Ok(())
    });
    steps.step("the user is taken home", |world, _, _| {
        world.sync()?;
        route_is_home(world)
    });
}
