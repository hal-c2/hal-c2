//! The shell's own toasts (ToastController): what the user sees in `toasts`,
//! and dismissing them or choosing their action as the Notifications brick
//! does (features/navigation/toasts.feature, desktop/native-toasts.feature).
//! desktop-qt's ToastSteps.cpp.

use chrono::Duration;
use serde_json::{Value, json};

use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

fn toasts(world: &World) -> Vec<Value> {
    world.state("toasts")["items"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn toast_titled(world: &World, title: &str) -> Option<Value> {
    toasts(world)
        .into_iter()
        .find(|t| text(&t["title"]) == title)
}

fn shows(world: &World) -> String {
    show(&Value::Array(toasts(world)))
}

fn wait_for_toast(world: &mut World, title: &str) -> Outcome<Value> {
    let wanted = title.to_owned();
    world.wait_for_with(
        |w| toast_titled(w, &wanted).is_some(),
        |w| format!("the toast \"{title}\"; the shell shows {}", shows(w)),
    )?;
    Ok(toast_titled(world, title).unwrap_or(Value::Null))
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("the user sees an? {Q} toast {Q} saying {Q}"),
        |world, c, _| {
            let toast = wait_for_toast(world, &c[1])?;
            expect!(
                toast["type"] == c[0] && toast["description"] == c[2],
                "the toast is {}",
                show(&toast)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user sees an? {Q} toast {Q}"),
        |world, c, _| {
            let toast = wait_for_toast(world, &c[1])?;
            expect!(toast["type"] == c[0], "the toast is {}", show(&toast));
            Ok(())
        },
    );
    steps.step(
        &format!("the user sees an? {Q} toast {Q} offering {Q}"),
        |world, c, _| {
            let toast = wait_for_toast(world, &c[1])?;
            let actions = toast["actions"].as_array().cloned().unwrap_or_default();
            expect!(
                toast["type"] == c[0] && actions.len() == 1 && actions[0]["label"] == c[2],
                "the toast is {}",
                show(&toast)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the toast {Q} offers {Q} and {Q}"),
        |world, c, _| {
            let toast = wait_for_toast(world, &c[0])?;
            let mut labels: Vec<String> = toast["actions"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|a| text(&a["label"]))
                .collect();
            labels.sort();
            let mut wanted = vec![c[1].clone(), c[2].clone()];
            wanted.sort();
            expect!(labels == wanted, "the toast is {}", show(&toast));
            Ok(())
        },
    );
    steps.step(
        &format!("the user sees the toast {Q} once"),
        |world, c, _| {
            wait_for_toast(world, &c[0])?;
            world.sync()?;
            let count = toasts(world)
                .iter()
                .filter(|t| text(&t["title"]) == c[0])
                .count();
            expect!(count == 1, "the shell shows {}", shows(world));
            Ok(())
        },
    );
    steps.step(&format!("the toast {Q} is gone"), |world, c, _| {
        world.sync()?;
        expect!(
            toast_titled(world, &c[0]).is_none(),
            "the shell shows {}",
            shows(world)
        );
        Ok(())
    });
    steps.step("the user sees (\\d+) toasts", |world, c, _| {
        world.sync()?;
        expect!(
            toasts(world).len() == c[0].parse::<usize>().unwrap_or(0),
            "the shell shows {}",
            shows(world)
        );
        Ok(())
    });
    // The pointer over the stack, or a tap on it on a phone, as the brick says.
    steps.step("the user (expands|collapses) the toasts", |world, c, _| {
        world.dispatch(
            "notification.expand",
            json!({"expanded": c[0] == "expands"}),
        )
    });
    steps.step("the user sees no toast", |world, _, _| {
        world.sync()?;
        expect!(toasts(world).is_empty(), "the shell shows {}", shows(world));
        Ok(())
    });
    steps.step(
        &format!("the user chooses {Q} on the toast {Q}"),
        |world, c, _| {
            let toast = wait_for_toast(world, &c[1])?;
            for action in toast["actions"].as_array().into_iter().flatten() {
                if action["label"] != c[0] {
                    continue;
                }
                return world.dispatch(
                    "notification.action",
                    json!({"id": toast["id"], "actionId": action["id"]}),
                );
            }
            fail!("the toast is {}", show(&toast))
        },
    );
    steps.step(
        &format!("the user dismisses the toast {Q}"),
        |world, c, _| {
            let toast = wait_for_toast(world, &c[0])?;
            world.dispatch("notification.dismiss", json!({"id": toast["id"]}))
        },
    );
    steps.step("(\\d+) seconds? pass(?:es)?", |world, c, _| {
        let later = world.now() + Duration::seconds(c[0].parse().unwrap_or(0));
        world.set_time(later);
        world.pump()
    });
}
