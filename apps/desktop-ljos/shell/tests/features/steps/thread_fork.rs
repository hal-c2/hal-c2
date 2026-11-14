//! Forking from a response, a thread's relatives and merging a fork back
//! (features/threads/fork-and-lineage.feature): ThreadLineage over the
//! shell's rows (`lineage`, `forkedFrom`). The MC makes the fork
//! (HalC2.Orchestration.Fork): its row follows an accepted `thread.fork`.
//! desktop-qt's ThreadForkSteps.cpp.

use std::rc::Rc;

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use serde_json::{Value, json};

use super::stream::{FakeStreams, add_item, look, read, settle_run, start_run};
use super::thread_menu::{id_in, key_of, project_thread_commands, provide_thread, update_row};
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

const PARENT: &str = "t-plan";
const AT: &str = "2026-09-23T09:00:00Z";

#[derive(Default)]
struct Forks {
    /// The MC makes the fork but its row does not reach the shell.
    withhold: bool,
}

fn fork_row(id: &str, title: &str, project: &str, parent: &str, run: &str) -> Value {
    json!({
        "id": id, "title": title, "projectId": project,
        "createdAt": "2026-09-23T09:30:00Z", "updatedAt": "2026-09-23T09:30:00Z",
        "lineage": {"parentThreadId": parent, "relationshipToParent": "fork", "rootThreadId": parent},
        "forkedFrom": {"type": "run", "threadId": parent, "runId": run},
    })
}

fn extension(mc: &mut FakeMc) {
    mc.effects.push(Rc::new(|mc: &mut FakeMc, command: &Value| {
        if text(&command["type"]) != "thread.fork" {
            return;
        }
        let source = text(&command["sourceThreadId"]);
        let target = text(&command["targetThreadId"]);
        let parent = mc.threads.get(&source).cloned().unwrap_or(Value::Null);
        let title = match text(&command["title"]) {
            t if t.is_empty() => format!("{} fork", text(&parent["title"])),
            t => t,
        };
        let row = fork_row(
            &target,
            &title,
            &text(&parent["projectId"]),
            &source,
            &text(&command["sourcePoint"]["runId"]),
        );
        mc.threads.insert(target.clone(), row.clone());
        if !mc.part::<Forks>().withhold {
            mc.send_row(&target, &row);
        }
    }));
}

/// A fork of the Background's thread; "Try Stripe" is the one the feature takes for granted.
fn add_fork(world: &mut World, title: &str) -> Outcome {
    let id = format!("t-{}", title.to_lowercase().replace(' ', "-"));
    if world.mc.threads.contains_key(&id) {
        return Ok(());
    }
    let project = text(&world.mc.threads[PARENT]["projectId"]);
    let row = fork_row(&id, title, &project, PARENT, "run-1");
    world.mc.threads.insert(id.clone(), row.clone());
    world.mc.send_row(&id, &row);
    world.sync()
}

fn view(world: &mut World, title: &str) -> Outcome {
    let key = key_of(world, title)?;
    let route = Route::Thread(key.clone());
    world.with::<Navigation, _>(|n, engine| n.open(engine, route))?;
    let wanted = key.clone();
    world.wait_for_with(
        move |w| text(&w.state("workspace")["threadKey"]) == wanted,
        move |_| format!("the window to show {key}"),
    )?;
    world.sync()
}

fn lineage(world: &World) -> Value {
    world.state("lineage")
}

fn open_key(world: &World) -> Outcome<String> {
    world.with::<Navigation, _>(|n, _| n.thread_key().to_owned())
}

/// The assistant's latest reply in the open thread, forked from as its "Fork from this response" does.
fn fork_from_latest_response(world: &mut World) -> Outcome {
    let run = read(world, |t| {
        (0..t.row_count()).rev().find_map(|row| {
            let id = text(&t.data(row, hal_c2_shell::thread_view::timeline::Role::Id)?);
            Some(t.finished_run_of(&id)).filter(|run| !run.is_empty())
        })
    })?;
    let Some(run) = run else {
        fail!(
            "no finished response to fork from; {}",
            super::stream::describe(world)
        );
    };
    world.dispatch("thread.forkFromRun", json!({"runId": run}))
}

fn toast_titled(world: &World, title: &str) -> Option<Value> {
    world.state("toasts")["items"]
        .as_array()?
        .iter()
        .find(|item| text(&item["title"]) == title)
        .cloned()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);
    provide_thread("Try Stripe", |world| add_fork(world, "Try Stripe"));

    steps.step(
        &format!("a connected environment with the thread {Q} whose last agent run finished"),
        |world, c, _| {
            world.mc.projects.insert(
                "shop".to_owned(),
                json!({"id": "shop", "title": "shop", "workspaceRoot": "/work/shop", "scripts": []}),
            );
            world.mc.threads.insert(
                PARENT.to_owned(),
                json!({"id": PARENT, "title": c[0], "projectId": "shop",
                       "createdAt": AT, "updatedAt": AT, "latestRunId": "run-1",
                       "status": "completed", "latestRunCompletedAt": AT}),
            );
            world.connect()?;
            world.sync()?;
            let environment = world.mc.environment_id.clone();
            let streams = world.mc.part::<FakeStreams>();
            streams.thread = PARENT.to_owned();
            streams.environment = environment.clone();
            start_run(world, 600, "running")?;
            add_item(
                world,
                "assistant_message",
                json!({"text": "Stripe and Paddle both fit."}),
            )?;
            settle_run(world, "completed", 60)?;
            look(world, &format!("{environment}:{PARENT}"), true)?;
            // The row the fake projects commands onto is this MC's.
            project_thread_commands(world);
            Ok(())
        },
    );

    // Forking from a response.
    steps.step(
        &format!("the user forks {Q} from (?:the agent's latest|a) response"),
        |world, c, _| {
            let wanted = key_of(world, &c[0])?;
            expect!(open_key(world)? == wanted, "{} is not open", c[0]);
            fork_from_latest_response(world)
        },
    );
    steps.step("the environment rejects the fork", |world, _, _| {
        world.mc.refusals.insert(
            "thread.fork".to_owned(),
            "Only finished runs can be used.".to_owned(),
        );
        Ok(())
    });
    steps.step(
        "the fork was created but its thread has not reached this client",
        |world, _, _| {
            world.mc.part::<Forks>().withhold = true;
            Ok(())
        },
    );
    steps.step(
        "the user is told to reconnect and open the fork from the thread list",
        |world, _, _| {
            let title = "The fork was created, but it did not reach this client";
            // The shell waits for the fork on its own clock, once the MC has
            // answered the command.
            world.wait_for("the MC to be asked to fork", |w| {
                w.mc.commands
                    .iter()
                    .any(|c| text(&c["type"]) == "thread.fork")
            })?;
            world.sync()?;
            world.advance(hal_c2_shell::controllers::thread_lineage::ARRIVAL_TIMEOUT_MS)?;
            world.wait_for_with(
                |w| toast_titled(w, title).is_some(),
                |w| format!("the notice; the shell shows {}", show(&w.state("toasts"))),
            )?;
            let toast = toast_titled(world, title).unwrap_or(Value::Null);
            expect!(
                text(&toast["description"]) == "Reconnect and try opening it from the thread list.",
                "the notice is {}",
                show(&toast)
            );
            // The MC did make the fork; the window stayed where it was.
            let wanted = format!("{}:{PARENT}", world.mc.environment_id);
            expect!(
                world.mc.threads.len() == 2 && open_key(world)? == wanted,
                "the route is {}",
                show(&world.state("route"))
            );
            Ok(())
        },
    );

    // Relatives.
    steps.step(&format!("{Q} and {Q} are forks of {Q}"), |world, c, _| {
        add_fork(world, &c[0])?;
        add_fork(world, &c[1])?;
        // One of them is at work.
        let id = id_in(&key_of(world, &c[1])?).to_owned();
        update_row(world, &id, |row| {
            row.insert("latestRunId".into(), json!("r1"));
            row.insert("activeRunId".into(), json!("r1"));
            row.insert("status".into(), json!("running"));
        })
    });
    steps.step(
        &format!("the user looks at (?:the relatives of|merging) {Q}(?: back)?"),
        |world, c, _| view(world, &c[0]),
    );
    steps.step(
        "both forks are listed with how many are running",
        |world, _, _| {
            let mut titles: Vec<String> = lineage(world)["forks"]
                .as_array()
                .map(|forks| forks.iter().map(|f| text(&f["title"])).collect())
                .unwrap_or_default();
            titles.sort();
            expect!(
                titles == ["Try Paddle", "Try Stripe"]
                    && text(&lineage(world)["title"]) == "Lineage · 1 running",
                "the lineage is {}",
                show(&lineage(world))
            );
            Ok(())
        },
    );
    steps.step("the user opens its parent thread", |world, _, _| {
        let parent = lineage(world)["parent"].clone();
        expect!(
            parent.as_object().is_some_and(|p| !p.is_empty()) && parent["missing"] != json!(true),
            "the lineage is {}",
            show(&lineage(world))
        );
        world.dispatch("lineage.open", json!({"key": parent["key"]}))
    });
    steps.step(&format!("the parent of {Q} was deleted"), |world, c, _| {
        key_of(world, &c[0])?; // the fork exists
        view(world, &c[0])?;
        let mut gone = world.mc.threads.remove(PARENT).unwrap_or(Value::Null);
        gone["deletedAt"] = json!("2026-09-23T09:45:00Z");
        world.mc.send_row(PARENT, &gone);
        world.sync()
    });
    steps.step("the parent is shown as unavailable", |world, _, _| {
        let parent = lineage(world)["parent"].clone();
        expect!(
            parent["missing"] == json!(true)
                && text(&parent["title"]) == "This related thread is unavailable",
            "the lineage is {}",
            show(&lineage(world))
        );
        // It cannot be opened.
        let before = open_key(world)?;
        world.dispatch("lineage.open", json!({"key": parent["key"]}))?;
        expect!(open_key(world)? == before, "the missing parent opened");
        Ok(())
    });

    // Merging back.
    steps.step(&format!("{Q} has (no|a) finished run"), |world, c, _| {
        let id = id_in(&key_of(world, &c[0])?).to_owned();
        if c[1] == "no" {
            return Ok(());
        }
        update_row(world, &id, |row| {
            row.insert("latestRunId".into(), json!("run-fork"));
            row.insert("status".into(), json!("completed"));
            row.insert("latestRunCompletedAt".into(), json!("2026-09-23T09:50:00Z"));
        })
    });
    steps.step(
        "merging is unavailable until a run in the fork completes",
        |world, _, _| {
            expect!(
                lineage(world)["canMerge"] != json!(true)
                    && text(&lineage(world)["mergeHint"])
                        == "Complete a run in this fork before merging it back",
                "the lineage is {}",
                show(&lineage(world))
            );
            let before = world.mc.commands.len();
            world.dispatch("lineage.mergeBack", json!({}))?;
            world.sync()?;
            expect!(
                world.mc.commands.len() == before,
                "the MC has {}",
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user merges {Q} back into {Q}"),
        |world, c, _| {
            view(world, &c[0])?;
            expect!(
                lineage(world)["canMerge"] == json!(true)
                    && text(&lineage(world)["mergeHint"])
                        == format!("Merge this conversation back into {}", c[1]),
                "the lineage is {}",
                show(&lineage(world))
            );
            world.dispatch("lineage.mergeBack", json!({}))?;
            world.sync()?;
            let source = id_in(&key_of(world, &c[0])?).to_owned();
            let merged = world.mc.commands.iter().any(|command| {
                text(&command["type"]) == "thread.merge_back"
                    && text(&command["sourceThreadId"]) == source
                    && text(&command["targetThreadId"]) == PARENT
                    && text(&command["sourcePoint"]["runId"]) == "run-fork"
            });
            expect!(merged, "the MC has {}", world.describe_commands());
            Ok(())
        },
    );

    // Where a fork came from.
    steps.step(
        "the user reads the start of the conversation",
        |world, _, _| world.sync(),
    );
    steps.step(
        &format!("it says the thread was forked from {Q}"),
        |world, c, _| {
            // ThreadLineage.qml reads "Forked from <title>" over the conversation.
            let parent = lineage(world)["parent"].clone();
            expect!(
                text(&parent["title"]) == c[0] && parent["missing"] != json!(true),
                "the lineage is {}",
                show(&lineage(world))
            );
            Ok(())
        },
    );
    steps.step(
        "the user can open the source conversation from there",
        |world, _, _| {
            let parent = text(&lineage(world)["parent"]["key"]);
            world.dispatch("lineage.open", json!({"key": parent}))?;
            let wanted = parent.clone();
            world.wait_for_with(
                move |w| open_key(w).is_ok_and(|k| k == wanted),
                |w| {
                    format!(
                        "the source to open; the route is {}",
                        show(&w.state("route"))
                    )
                },
            )
        },
    );
}
