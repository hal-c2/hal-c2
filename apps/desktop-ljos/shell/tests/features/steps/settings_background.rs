//! What the desktop tells the MC it is looking at (ClientActivityController,
//! features/settings/background-service.feature): desktop-qt's
//! SettingsBackgroundSteps.cpp.

use serde_json::Value;

use crate::expect;
use crate::harness::{Outcome, Steps, show};
use crate::steps::stream::THREAD;
use crate::steps::turn::open_turn_thread;
use crate::world::World;

/// The last `server.reportClientActivity` the MC got.
fn last_report(world: &World) -> Value {
    world
        .mc
        .calls
        .iter()
        .rfind(|rpc| rpc.method == "server.reportClientActivity")
        .map(|rpc| rpc.payload.clone())
        .unwrap_or(Value::Null)
}

fn watches(report: &Value, kind: &str, key: &str, value: &str) -> bool {
    report["scopes"].as_array().is_some_and(|scopes| {
        scopes
            .iter()
            .any(|scope| scope["type"] == kind && scope[key] == value)
    })
}

fn told(world: &World) -> String {
    format!("the MC was last told {}", show(&last_report(world)))
}

pub fn register(steps: &mut Steps) {
    steps.step("the user opens a thread in the client", |world, _, _| {
        open_turn_thread(world)?;
        world.sync()
    });
    steps.step(
        "the client tells the MC it is watching that thread's git status",
        |world, _, _| -> Outcome {
            world.wait_for_with(
                |w| watches(&last_report(w), "vcs-status", "cwd", "/work/shop"),
                told,
            )?;
            let report = last_report(world);
            // As a lease the MC can let run out: who watches, what, and for how long.
            expect!(
                watches(&report, "thread", "threadId", THREAD)
                    && report["clientKind"] == "desktop-renderer"
                    && report["clientId"].as_str().is_some_and(|id| !id.is_empty())
                    && report["ttlMs"].as_i64().unwrap_or(0) > 0
                    && report["environmentId"] == world.mc.environment_id.as_str(),
                "{}",
                told(world)
            );
            Ok(())
        },
    );
}
