//! The shell's route (NavigationController): where the user goes from the
//! shell and the window title (features/desktop/native-navigation.feature),
//! and settings left for the thread it was opened from
//! (settings/search-and-navigation.feature, navigation/focus.feature).
//! desktop-qt's NavigationSteps.cpp.

use serde_json::{Value, json};

use super::stream::{PROJECT, THREAD, look_at_thread};
use crate::expect;
use crate::harness::{Outcome, Q, Steps, at, show};
use crate::world::World;

fn route(world: &World) -> Value {
    world.state("route")
}

fn expect_route(world: &mut World, kind: &str, field: &str, value: &str) -> Outcome {
    world.sync()?;
    let current = route(world);
    expect!(
        at(&current, "kind") == kind && (field.is_empty() || at(&current, field) == value),
        "the route is {}",
        show(&current)
    );
    Ok(())
}

pub fn register(steps: &mut Steps) {
    // The user in the shell.
    steps.step(
        &format!("the user opens {Q} from the sidebar"),
        |world, c, _| world.dispatch("thread.open", json!({"key": c[0]})),
    );
    steps.step(
        &format!("the user opens the draft {Q} from the sidebar"),
        |world, c, _| world.dispatch("draft.open", json!({"draftId": c[0]})),
    );
    steps.step(
        &format!("the user starts a new thread in {Q}"),
        |world, c, _| {
            let key = world.project_key(&c[0]);
            world.start_new_thread(json!({"projectKey": key}))
        },
    );
    steps.step("the user opens settings", |world, _, _| {
        world.dispatch("settings.open", Value::Null)
    });
    // Settings reached from a thread of "shop" (settings/search-and-navigation.feature, navigation/focus.feature).
    steps.step("the user (?:has opened|is in) settings", |world, _, _| {
        if !world.mc.projects.contains_key(PROJECT) {
            world.mc.projects.insert(
                PROJECT.into(),
                json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": "/work/shop", "scripts": []}),
            );
            world.connect()?;
            world.sync()?;
        }
        world.dispatch("settings.open", Value::Null)
    });
    steps.step("the user opened settings from a thread", |world, _, _| {
        look_at_thread(world, PROJECT)?;
        world.dispatch("settings.open", Value::Null)
    });
    steps.step("the user opens pull requests", |world, _, _| {
        world.dispatch("pullRequests.open", Value::Null)
    });
    steps.step("the user opens usage", |world, _, _| {
        world.dispatch("usage.open", Value::Null)
    });

    steps.step("the desktop quits and starts again", |world, _, _| {
        world.restart()
    });

    // What the shell shows.
    steps.step(&format!("the window shows {Q}"), |world, c, _| {
        expect_route(world, "thread", "threadKey", &c[0])
    });
    steps.step(&format!("the window shows the draft {Q}"), |world, c, _| {
        expect_route(world, "draft", "draftId", &c[0])
    });
    steps.step("the window shows settings", |world, _, _| {
        expect_route(world, "settings", "", "")
    });
    steps.step(
        &format!("the window shows the settings section {Q}"),
        |world, c, _| expect_route(world, "settings", "section", &c[0]),
    );
    steps.step("the window shows pull requests", |world, _, _| {
        expect_route(world, "pullRequests", "", "")
    });
    steps.step("the window shows usage", |world, _, _| {
        expect_route(world, "usage", "", "")
    });
    steps.step("(?:the|that) thread is shown(?: again)?", |world, _, _| {
        let key = format!("{}:{THREAD}", world.mc.environment_id);
        expect_route(world, "thread", "threadKey", &key)
    });
    steps.step("the window shows home", |world, _, _| {
        expect_route(world, "home", "", "")
    });
    steps.step(&format!("the window is titled {Q}"), |world, c, _| {
        world.sync()?;
        expect!(
            at(&route(world), "title") == c[0].as_str(),
            "the route is {}",
            show(&route(world))
        );
        Ok(())
    });
    for (text, can) in [
        ("the user can go back", true),
        ("the user can not go back", false),
    ] {
        steps.step(text, move |world, _, _| {
            world.sync()?;
            expect!(
                (at(&route(world), "canGoBack") == true) == can,
                "the route is {}",
                show(&route(world))
            );
            Ok(())
        });
    }
    steps.step(&format!("the sidebar marks {Q} as open"), |world, c, _| {
        world.sync()?;
        let sidebar = world.state("sidebar");
        expect!(
            at(&sidebar, "activeThreadKey") == c[0].as_str(),
            "the sidebar marks {}",
            show(at(&sidebar, "activeThreadKey"))
        );
        Ok(())
    });
    steps.step(
        &format!("the sidebar marks the draft {Q} as open"),
        |world, c, _| {
            world.sync()?;
            let sidebar = world.state("sidebar");
            expect!(
                at(&sidebar, "activeDraftId") == c[0].as_str()
                    && at(&sidebar, "activeThreadKey").is_null(),
                "the sidebar is {}",
                show(&sidebar)
            );
            Ok(())
        },
    );
}
