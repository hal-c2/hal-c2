//! The Archive settings section on the desktop (ArchivedThreads): the
//! archived threads scenarios of threads/archive-delete.feature. The
//! Background's thread and project come from thread_menu.rs, whose MC
//! follows the thread commands it accepts. desktop-qt's
//! ArchivedThreadsSteps.cpp.

use hal_c2_shell::controllers::navigation::{ARCHIVED_SECTION, Navigation, Route};
use serde_json::{Value, json};

use crate::brick::Shown;
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// The MC's side: `orchestration.getArchivedShellSnapshot`, held while the
/// scenario says the environments are still being checked.
#[derive(Default)]
struct FakeArchive {
    refusal: String,
}

const HOLD: &str = "archive";
const ARCHIVED_AT: &str = "2026-09-23T09:30:00Z";

fn extension(mc: &mut FakeMc) {
    mc.on_rpc("orchestration.getArchivedShellSnapshot", |mc, rpc| {
        let rpc = rpc.clone();
        let answer = move |mc: &mut FakeMc| {
            let refusal = mc.part::<FakeArchive>().refusal.clone();
            if !refusal.is_empty() {
                mc.refuse(&rpc, &refusal);
                return;
            }
            let projects: Vec<Value> = mc.projects.values().cloned().collect();
            let threads: Vec<Value> = mc
                .threads
                .values()
                .filter(|thread| thread.get("archivedAt").is_some())
                .cloned()
                .collect();
            mc.reply(
                &rpc,
                json!({"schemaVersion": 1, "snapshotSequence": 0,
                       "projects": projects, "threads": threads}),
            );
        };
        if mc.holding(HOLD) {
            mc.defer(answer);
        } else {
            answer(mc);
        }
        Ok(())
    });
}

/// The MC's thread titled `title`, made in `project` when it has none.
fn thread_named(world: &mut World, title: &str, project: &str) -> Outcome<String> {
    if let Some((id, _)) = world
        .mc
        .threads
        .iter()
        .find(|(_, row)| row["title"] == json!(title))
    {
        return Ok(id.clone());
    }
    expect!(!project.is_empty(), "no thread is titled \"{title}\"");
    let id = format!("t{}", world.mc.threads.len() + 1);
    world.mc.threads.insert(
        id.clone(),
        json!({"id": id, "title": title, "projectId": project,
               "createdAt": "2026-09-23T08:00:00Z", "updatedAt": "2026-09-23T08:00:00Z"}),
    );
    Ok(id)
}

fn ensure_project(world: &mut World, id: &str) {
    if world.mc.projects.contains_key(id) {
        return;
    }
    let row = json!({"id": id, "title": id, "workspaceRoot": format!("/work/{id}"),
                     "scripts": [], "createdAt": "2026-09-01T09:00:00Z",
                     "updatedAt": "2026-09-01T09:00:00Z"});
    world.mc.projects.insert(id.to_owned(), row.clone());
    world.mc.send_row_of(id, &row, "project");
}

fn archive(world: &mut World, title: &str, project: &str) -> Outcome {
    if !project.is_empty() {
        ensure_project(world, project);
    }
    let id = thread_named(world, title, project)?;
    let mut row = world.mc.threads[&id].clone();
    row["archivedAt"] = json!(ARCHIVED_AT);
    world.mc.threads.insert(id.clone(), row.clone());
    world.mc.send_row(&id, &row);
    Ok(())
}

fn open(world: &mut World) -> Outcome {
    world.sync()?;
    world.with::<Navigation, _>(|navigation, engine| {
        navigation.open(engine, Route::Settings(ARCHIVED_SECTION.into()))
    })
}

pub fn groups_of(world: &World) -> Vec<Value> {
    groups(world)
}

/// The listed groups.
fn groups(world: &World) -> Vec<Value> {
    at(&world.state("archivedThreads"), "groups")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn listed(world: &World, title: &str) -> Option<Value> {
    groups(world)
        .iter()
        .flat_map(|group| group["threads"].as_array().into_iter().flatten())
        .find(|thread| thread["title"] == json!(title))
        .cloned()
}

fn group_of(world: &World, title: &str) -> String {
    groups(world)
        .iter()
        .find(|group| {
            group["threads"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|thread| thread["title"] == json!(title))
        })
        .map(|group| text(&group["title"]))
        .unwrap_or_default()
}

fn wait_listed(world: &mut World, title: &str) -> Outcome<Value> {
    world.wait_for_with(
        |w| listed(w, title).is_some(),
        |w| {
            format!(
                "{title} in the archived threads; they are {}",
                show(&w.state("archivedThreads"))
            )
        },
    )?;
    Ok(listed(world, title).unwrap_or(Value::Null))
}

fn act(world: &mut World, action: &str, title: &str) -> Outcome {
    let thread = wait_listed(world, title)?;
    world.dispatch(
        &format!("archivedThreads.{action}"),
        json!({"environmentId": thread["environmentId"], "threadId": thread["threadId"]}),
    )?;
    world.sync()?;
    // A delete the user wants confirmed is confirmed.
    let question = world.state("confirmation");
    if question.is_object() {
        world.dispatch(
            "confirmation.answer",
            json!({"requestId": question["requestId"], "accepted": true}),
        )?;
    }
    Ok(())
}

fn in_thread_list(world: &World, title: &str) -> bool {
    let sidebar = world.state("sidebar");
    ["pinned", "active", "settled", "snoozed"].iter().any(|section| {
        sidebar[*section]
            .as_array()
            .into_iter()
            .flatten()
            .any(|row| row["title"] == json!(title))
    })
}

/// Whether the archive lists only `title` (workspace.rs' "only {Q} is
/// listed" asks this while the Archive section is open).
pub fn archive_lists_only(world: &World, title: &str) -> bool {
    let listed_groups = groups(world);
    listed_groups.len() == 1
        && listed_groups[0]["threads"].as_array().map(Vec::len) == Some(1)
        && listed(world, title).is_some()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    steps.step(&format!("{Q} is archived"), |world, c, _| {
        archive(world, &c[0], "")?;
        world.sync()
    });
    steps.step(
        &format!("{Q} in {Q} and {Q} in {Q} are archived"),
        |world, c, _| {
            archive(world, &c[0], &c[1])?;
            archive(world, &c[2], &c[3])?;
            world.sync()
        },
    );
    steps.step("the environments are still being checked", |world, _, _| {
        world.mc.hold(HOLD);
        Ok(())
    });
    steps.step("no thread has been archived", |world, _, _| {
        for thread in world.mc.threads.values() {
            expect!(
                thread.get("archivedAt").is_none(),
                "{} is archived",
                text(&thread["title"])
            );
        }
        Ok(())
    });
    steps.step("the archived threads cannot be loaded", |world, _, _| {
        world.mc.part::<FakeArchive>().refusal = "The archive is unavailable".into();
        Ok(())
    });

    steps.step("the user opens the archived threads", |world, _, _| {
        open(world)
    });
    // The settings scope's project picker, then the Archive section.
    steps.step(
        &format!("the user opens the archived threads from the settings of {Q}"),
        |world, c, _| {
            open(world)?;
            let find = |w: &World| {
                at(&w.state("settingsScope"), "projects")
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|row| row["title"] == json!(c[0]))
                    .map(|row| text(&row["key"]))
                    .last()
                    .filter(|key| !key.is_empty())
            };
            world.wait_for_with(
                |w| find(w).is_some(),
                |w| {
                    format!(
                        "{} to be offered; the scope is {}",
                        c[0],
                        show(&w.state("settingsScope"))
                    )
                },
            )?;
            let key = find(world).unwrap_or_default();
            world.dispatch("settingsScope.project", json!({"key": key}))
        },
    );
    steps.step(
        &format!("the user (restores|deletes) {Q} from the archived threads"),
        |world, c, _| {
            open(world)?;
            let action = if c[0] == "restores" { "unarchive" } else { "delete" };
            act(world, action, &c[1])
        },
    );
    steps.step(
        &format!("the user restores {Q} before the environment lists the archived threads again"),
        |world, c, _| {
            open(world)?;
            wait_listed(world, &c[0])?;
            world.mc.hold(HOLD);
            act(world, "unarchive", &c[0])
        },
    );
    steps.step(
        &format!("the user tries to (unarchive|delete) {Q} and the environment refuses"),
        |world, c, _| {
            world.mc.refusals.insert(
                format!("thread.{}", c[0]),
                "The environment is read-only".into(),
            );
            open(world)?;
            act(world, &c[0], &c[1])
        },
    );

    steps.step(&format!("the user sees {Q}"), |world, c, _| {
        // The archive's page title, or the welcome wizard's (or its recovery page's).
        // TODO(port): OnboardingSteps' onboardingShows (the welcome wizard's text).
        let shown = |w: &World| {
            at(&w.state("archivedThreads"), "title") == &json!(c[0])
                || w.peek_part::<Shown>()
                    .and_then(|shown| shown.0.as_ref())
                    .is_some_and(|brick| brick.shows(w, &c[0]).unwrap_or(false))
        };
        world.wait_for_with(shown, |w| {
            format!(
                "\"{}\"; the archive shows {}",
                c[0],
                show(&w.state("archivedThreads"))
            )
        })
    });
    // The page only narrows a list, so a connected environment is never asked to reconnect.
    steps.step(
        "the archived threads page shows no reconnect notice",
        |world, _, _| {
            world.wait_for("the archive to list threads", |w| !groups(w).is_empty())?;
            let scope = world.state("settingsScope");
            expect!(
                text(&scope["disabledReason"]).is_empty(),
                "no notice; the scope is {}",
                show(&scope)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is listed under {Q} and {Q} under {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| group_of(w, &c[0]) == c[1] && group_of(w, &c[2]) == c[3],
                |w| {
                    format!(
                        "the groups to be right; they are {}",
                        show(&Value::Array(groups(w)))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("{Q} is no longer in the archived threads"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    listed(w, &c[0]).is_none()
                        && at(&w.state("archivedThreads"), "status") == &json!("empty")
                },
                |w| {
                    format!(
                        "{} gone; the archive shows {}",
                        c[0],
                        show(&w.state("archivedThreads"))
                    )
                },
            )?;
            expect!(
                !world.mc.threads.contains_key("t1"),
                "the MC still has the thread"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is not listed in the archived threads"),
        |world, c, _| {
            let id = thread_named(world, &c[0], "")?;
            world.wait_for_with(
                |w| w.mc.threads.get(&id).is_some_and(|row| row.get("archivedAt").is_none()),
                |_| format!("the MC to unarchive {}", c[0]),
            )?;
            world.sync()?;
            expect!(
                listed(world, &c[0]).is_none(),
                "the archive shows {}",
                show(&world.state("archivedThreads"))
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} is back in the thread list"), |world, c, _| {
        world.wait_for_with(
            |w| in_thread_list(w, &c[0]),
            |w| {
                format!(
                    "{} in the thread list; it is {}",
                    c[0],
                    show(&w.state("sidebar"))
                )
            },
        )
    });
    steps.step(
        &format!("the user is told {Q} and why"),
        |world, c, _| {
            let told = |w: &World| {
                w.state("toasts")["items"].as_array().is_some_and(|items| {
                    items.iter().any(|item| {
                        item["title"] == json!(c[0])
                            && item["description"] == json!("The environment is read-only")
                    })
                })
            };
            world.wait_for_with(told, |w| {
                format!("\"{}\"; the toasts are {}", c[0], show(&w.state("toasts")))
            })
        },
    );
    steps.step(
        &format!("{Q} stays in the archived threads"),
        |world, c, _| {
            world.sync()?;
            let thread = listed(world, &c[0]);
            expect!(
                thread.is_some_and(|t| t["busy"] != json!(true)),
                "the archive shows {}",
                show(&world.state("archivedThreads"))
            );
            let id = thread_named(world, &c[0], "")?;
            if world.mc.threads[&id].get("archivedAt").is_none() {
                fail!("the MC's row is not archived");
            }
            Ok(())
        },
    );
}
