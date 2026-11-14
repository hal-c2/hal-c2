//! Where a scenario starts: the time, and what the window shows (a thread
//! of another environment, or a new thread's draft) (desktop-qt's
//! ViewingSteps.cpp).

use serde_json::json;

use crate::harness::{Q, Steps};

pub fn register(steps: &mut Steps) {
    // A thread of another environment: a cluster member's rows carry it.
    steps.step(
        &format!("the user is viewing {Q} with its project at {Q}"),
        |world, c, _| {
            let (environment, thread) = c[0].split_once(':').unwrap_or(("", c[0].as_str()));
            let project = format!("project-{thread}");
            if let Some(peer) = world.mc.peers.get(environment).cloned() {
                world.mc.send_rows(
                    &peer,
                    vec![
                        json!([project, "project",
                               {"id": project, "workspaceRoot": c[1], "scripts": []}]),
                        json!([thread, "thread",
                               {"id": thread, "projectId": project, "title": thread}]),
                    ],
                );
                world.sync()?;
            }
            world.dispatch("thread.open", json!({"key": c[0]}))
        },
    );
    steps.step(
        &format!("the user is viewing a new thread in {Q}"),
        |world, c, _| world.open_draft(&c[0]),
    );
    steps.step(&format!("the time is {Q}"), |world, c, _| {
        world.set_time_iso(&c[0])
    });
}
