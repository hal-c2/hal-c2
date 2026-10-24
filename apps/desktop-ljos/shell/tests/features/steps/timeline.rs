//! The thread's timeline (features/timeline/*): desktop-qt's
//! TimelineSteps.cpp. For now only its Background, which most domains'
//! scenarios start from.

use serde_json::json;

use crate::harness::{Q, Steps};

pub fn register(steps: &mut Steps) {
    // Background.
    steps.step(
        &format!("a connected environment with the project {Q}"),
        |world, c, _| {
            let name = &c[0];
            world.mc.projects.insert(
                name.clone(),
                json!({"id": name, "title": name, "workspaceRoot": format!("/work/{name}"), "scripts": []}),
            );
            world.connect()?;
            world.sync()
        },
    );
}
