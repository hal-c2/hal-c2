//! Removing a project from the desktop's folder explorer, which Settings →
//! Project confirms (features/settings/projects.feature). desktop-qt's
//! SettingsProjectsSteps.cpp.

use serde_json::{Value, json};

use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const PROJECT: &str = "shop";

fn removal(world: &World) -> Value {
    world.state("projectRemoval")
}

fn nothing_sent(world: &World) -> bool {
    world.mc.commands.is_empty()
}

/// The folder explorer's Remove from HAL-C2… on the project registered at
/// the selected folder.
fn remove_from_explorer(world: &mut World, project: &str) -> Outcome {
    if !world.mc.projects.contains_key(project) {
        let row = json!({
            "id": project,
            "title": project,
            "workspaceRoot": format!("/work/{project}"),
            "scripts": [],
        });
        world.mc.projects.insert(project.to_owned(), row.clone());
        if world.shell_subscriptions() > 0 {
            world.mc.send_row_of(project, &row, "project");
        }
    }
    if world.shell_subscriptions() == 0 {
        world.connect()?;
    }
    world.sync()?;
    let locals = at(&world.state("sidebar"), "localProjects").clone();
    for local in locals.as_array().into_iter().flatten() {
        if at(local, "displayName") != project {
            continue;
        }
        world.dispatch(
            "project.remove",
            json!({"projectKey": at(local, "key"), "inSettings": true}),
        )?;
        return world.sync();
    }
    fail!("the folder explorer has no {project}: {}", show(&locals))
}

fn listed(world: &World, project: &str) -> bool {
    at(&world.state("sidebar"), "projects")
        .as_array()
        .is_some_and(|projects| {
            projects
                .iter()
                .any(|entry| at(entry, "displayName") == project)
        })
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the user removes a registered folder from HAL-C2 in the folder explorer",
        |world, _, _| remove_from_explorer(world, PROJECT),
    );
    steps.step(
        "the Projects settings open with the removal confirmation for that project",
        |world, _, _| {
            let route = world.state("route");
            expect!(
                at(&route, "kind") == "settings" && at(&route, "section") == "/settings/projects",
                "the route is {}",
                show(&route)
            );
            // On that project, asking about it.
            world.wait_for_with(
                |w| text(at(&w.state("projectSettings"), "name")) == PROJECT,
                |w| format!("the panel is {}", show(&w.state("projectSettings"))),
            )?;
            expect!(
                text(at(&removal(world), "title")) == PROJECT
                    && world.mc.projects.contains_key(PROJECT)
                    && nothing_sent(world),
                "the confirmation is {}; the MC has {}",
                show(&removal(world)),
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user asked to remove {Q} from the folder explorer"),
        |world, c, _| {
            remove_from_explorer(world, &c[0])?;
            expect!(
                text(at(&removal(world), "title")) == c[0],
                "the confirmation is {}",
                show(&removal(world))
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} is still listed"), |world, c, _| {
        world.sync()?;
        expect!(
            removal(world).as_object().is_none_or(|r| r.is_empty())
                && listed(world, &c[0])
                && world.mc.projects.contains_key(&c[0])
                && nothing_sent(world),
            "the confirmation is {}; the MC has {}",
            show(&removal(world)),
            world.describe_commands()
        );
        Ok(())
    });
    steps.step("the user cancels the removal in settings", |world, _, _| {
        world.dispatch("project.remove.cancel", json!({}))?;
        world.sync()
    });
}
