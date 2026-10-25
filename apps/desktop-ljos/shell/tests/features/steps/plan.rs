//! What the user does with a proposed plan besides implementing it in place
//! (Plan; features/timeline/plans-and-subagents.feature): a new thread that
//! carries it out, and copies of it on the clipboard, in the Downloads folder
//! and in the workspace. Driven from the plan card's menu on the TurnRequests
//! brick; the plan is the timeline steps' ("# Tax line" on thread-1).
//! desktop-qt's PlanSteps.cpp.

use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::controllers::plan::Plan;
use hal_c2_shell::controllers::threads;
use hal_c2_shell::thread_view::timeline::Role;
use hal_c2_shell::thread_view::timeline_model::TimelineModel;
use serde_json::{Value, json};

use super::stream::{PROJECT, THREAD};
use crate::brick::{Brick, Shown, key_event, shown};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

const PLAN: &str = "# Tax line\n\n- Add the line\n- Test it\n";

/// What the MC's `projects.writeFile` was asked to write.
#[derive(Default)]
struct FakeWrites {
    files: Vec<Value>,
}

fn downloads(world: &World) -> std::path::PathBuf {
    world.home_dir().join("downloads")
}

/// An entry of the plan card's menu.
fn choose(world: &mut World, entry: &str) -> Outcome {
    let directory = downloads(world);
    world.with::<Plan, _>(|plan, _| plan.set_download_directory(Some(directory)))?;
    world.mc.on_rpc("projects.writeFile", |mc, rpc| {
        mc.part::<FakeWrites>().files.push(rpc.payload.clone());
        mc.reply(rpc, json!({"relativePath": rpc.payload["relativePath"]}));
        Ok(())
    });
    if world.part::<Shown>().0.is_none() {
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nTurnRequests {}\n",
            820.0,
            500.0,
        )?;
    }
    let brick = shown(world)?;
    world.wait_for("the plan card to be drawn", move |w| {
        brick.shows(w, "Tax line").unwrap_or(false)
    })?;
    brick.click(world, "planMore")?;
    let ljos::prelude::Value::Object(menu) = brick.read(world, brick.item(world, entry)?, "menu")
    else {
        fail!("{entry} is not in a menu");
    };
    // An item takes clicks once its menu has finished opening.
    world.wait_for("the plan's actions to open", move |w| {
        brick.flag(w, menu, "opened")
    })?;
    brick.click(world, entry)?;
    // What it chose is done once the menu has gone.
    world.wait_for("the plan's actions to close", move |w| {
        !brick.flag(w, menu, "visible")
    })?;
    world.sync()
}

fn save_to(world: &mut World, path: &str) -> Outcome {
    choose(world, "planSave")?;
    let brick = shown(world)?;
    world.wait_for("the save dialog to open", move |w| {
        brick
            .item(w, "planSavePath")
            .map(|item| brick.flag(w, item, "visible"))
            .unwrap_or(false)
    })?;
    brick.click(world, "planSavePath")?;
    for ch in path.chars() {
        let event = key_event(&format!("\"{ch}\""))?;
        world.key(&event)?;
    }
    brick.click(world, "planSaveConfirm")?;
    world.sync()
}

fn launches(world: &World) -> Vec<Value> {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == "orchestration.launchThread")
        .map(|rpc| rpc.payload.clone())
        .collect()
}

fn listing(directory: &std::path::Path) -> String {
    let mut names: Vec<String> = std::fs::read_dir(directory)
        .map(|entries| {
            entries
                .flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names.join(", ")
}

fn message(world: &World) -> Option<Value> {
    world
        .mc
        .commands
        .iter()
        .rev()
        .find(|command| text(&command["type"]) == "message.dispatch")
        .cloned()
}

fn current_key(world: &World) -> Outcome<String> {
    world.with::<Navigation, _>(|n, _| n.thread_key().to_owned())
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the user implements the plan in a new thread",
        |world, _, _| choose(world, "planNewThread"),
    );
    steps.step(
        "a new thread starts implementing the plan",
        |world, _, _| {
            let launched = launches(world);
            expect!(
                launched.len() == 1,
                "the MC was asked to start {} threads",
                launched.len()
            );
            let launch = &launched[0];
            let thread_id = text(&launch["threadId"]);
            expect!(
                !thread_id.is_empty()
                    && thread_id != THREAD
                    && text(&launch["projectId"]) == PROJECT
                    && text(&launch["title"]) == "Implement Tax line"
                    && text(&launch["interactionMode"]) == "default"
                    && text(&launch["workspaceStrategy"]["type"]) == "root",
                "the MC was asked to start {}",
                show(launch)
            );
            // The thread first, then its first message.
            world.wait_for("the thread's first message", |w| message(w).is_some())?;
            let message = message(world).unwrap_or(Value::Null);
            let plan_ref = &message["sourcePlanRef"];
            expect!(
                text(&message["threadId"]) == thread_id
                    && text(&message["text"])
                        == "PLEASE IMPLEMENT THIS PLAN:\n# Tax line\n\n- Add the line\n- Test it"
                    && text(&plan_ref["threadId"]) == THREAD
                    && text(&plan_ref["planId"]) == "plan-1",
                "the MC was sent {}",
                show(&message)
            );
            // The window moves to the new thread.
            let key = format!("{}:{thread_id}", world.mc.environment_id);
            let wanted = key.clone();
            world.wait_for("the new thread to open", move |w| {
                current_key(w).is_ok_and(|k| k == wanted)
            })
        },
    );
    steps.step("the planning thread keeps the plan", |world, _, _| {
        // Its plan card is still in its timeline, and nothing was sent to it.
        let key = format!("{}:{THREAD}", world.mc.environment_id);
        let Some(object) = threads::timeline_of(world.engine(), &key) else {
            fail!("the planning thread is gone");
        };
        let card = TimelineModel::read(world.engine(), object, |t| {
            (0..t.row_count()).any(|row| {
                t.data(row, Role::Kind) == Some(json!("plan"))
                    && t.data(row, Role::Title) == Some(json!("Tax line"))
            })
        })
        .unwrap_or(false);
        expect!(card, "the planning thread shows no plan card");
        for command in &world.mc.commands {
            expect!(
                text(&command["threadId"]) != THREAD,
                "the planning thread was sent {}",
                show(command)
            );
        }
        Ok(())
    });
    steps.step(
        "the environment cannot start a new thread",
        |world, _, _| {
            world.mc.refusals.insert(
                "orchestration.launchThread".to_owned(),
                "Provider unavailable".to_owned(),
            );
            Ok(())
        },
    );

    steps.step("the user copies the plan", |world, _, _| {
        choose(world, "planCopy")
    });
    steps.step("the plan's markdown is on the clipboard", |world, _, _| {
        let held = world.clipboard();
        expect!(held == PLAN, "the clipboard holds \"{held}\"");
        Ok(())
    });
    steps.step("the user downloads the plan", |world, _, _| {
        choose(world, "planDownload")
    });
    steps.step("a markdown file of the plan is saved", |world, _, _| {
        let directory = downloads(world);
        let file = directory.join("tax-line.md");
        let Ok(written) = std::fs::read_to_string(&file) else {
            fail!(
                "{} was not written: {}",
                file.display(),
                listing(&directory)
            );
        };
        expect!(written == PLAN, "the file holds \"{written}\"");
        // A second download does not write over the first.
        choose(world, "planDownload")?;
        expect!(
            directory.join("tax-line (2).md").exists(),
            "the downloads are {}",
            listing(&directory)
        );
        Ok(())
    });
    steps.step(&format!("the user saves the plan to {Q}"), |world, c, _| {
        save_to(world, &c[0])
    });
    steps.step(
        &format!("{Q} holds the plan in the workspace"),
        |world, c, _| {
            let files = &world.mc.part::<FakeWrites>().files;
            let first = files.first().cloned();
            expect!(
                files.len() == 1
                    && first
                        .as_ref()
                        .is_some_and(|f| text(&f["cwd"]) == "/work/shop"
                            && text(&f["relativePath"]) == c[0]
                            && text(&f["contents"]) == PLAN),
                "the MC was asked to write {}",
                first.map_or("nothing".to_owned(), |f| show(&f))
            );
            Ok(())
        },
    );
    steps.step("the thread's workspace is unavailable", |world, _, _| {
        if let Some(Value::Object(project)) = world.mc.projects.get_mut(PROJECT) {
            project.remove("workspaceRoot");
        }
        world.mc.send_row_of(
            PROJECT,
            &json!({"id": PROJECT, "title": PROJECT, "scripts": [], "workspaceRoot": null}),
            "project",
        );
        world.sync()
    });
    steps.step("the user saves the plan to the workspace", |world, _, _| {
        save_to(world, "docs/tax-plan.md")?;
        expect!(
            world.mc.part::<FakeWrites>().files.is_empty(),
            "the MC was asked to write a file"
        );
        Ok(())
    });
}
