//! The native sidebar: row actions, its scope and snooze menu, and the
//! sections it shows (features/threads/thread-list.feature,
//! desktop/native-sidebar.feature): desktop-qt's SidebarSteps.cpp.

use ljos::prelude::Value as Lv;
use serde_json::{Value, json};

use super::add_project::{self, id_at, invoke, is_open, role_text};
use super::thread_menu::key_of;
use super::turn::pick_answer;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

fn keyed(key: &str) -> Value {
    json!({ "key": key })
}

fn section_titles(world: &World, section: &str) -> String {
    world.state("sidebar")[section]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| text(&row["title"]))
        .collect::<Vec<_>>()
        .join(", ")
}

fn choose(world: &mut World, id: Value) -> Outcome {
    let menu = world.state("menu");
    expect!(menu.is_object(), "no menu is open");
    world.dispatch(
        "menu.select",
        json!({"requestId": menu["requestId"], "id": id}),
    )
}

pub fn register(steps: &mut Steps) {
    // The user in the shell, naming a thread by key or title.
    for (text_, action) in [
        ("settles", "thread.settle"),
        ("un-settles", "thread.unsettle"),
        ("wakes", "thread.unsnooze"),
        ("dismisses the woke pill on", "thread.wokeDismiss"),
    ] {
        steps.step(&format!("the user {text_} {Q}"), move |world, c, _| {
            let key = key_of(world, &c[0])?;
            world.dispatch(action, keyed(&key))
        });
    }
    steps.step(&format!("the user marks {Q} unread"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        world.dispatch("thread.markUnread", keyed(&key))
    });
    steps.step(
        &format!("the user dispatches {Q} for {Q}"),
        |world, c, _| world.dispatch(&c[0], keyed(&c[1])),
    );
    steps.step(
        &format!("the user scopes the sidebar to {Q}"),
        |world, c, _| {
            let key = world.project_key(&c[0]);
            world.dispatch("sidebar.scope", json!({"projectKey": key}))
        },
    );
    steps.step("the user clears the sidebar's scope", |world, _, _| {
        world.dispatch("sidebar.scope", json!({"projectKey": null}))
    });
    steps.step(
        &format!("the user opens the snooze menu for {Q} at (\\d+), (\\d+)"),
        |world, c, _| {
            let x: f64 = c[1].parse().unwrap_or(0.0);
            let y: f64 = c[2].parse().unwrap_or(0.0);
            world.dispatch("thread.snoozeMenu", json!({"key": c[0], "x": x, "y": y}))
        },
    );
    steps.step(&format!("the user picks {Q}"), |world, c, _| {
        // In the Project settings, the default workspace looked at
        // (settings/project-defaults.feature).
        if at(&world.state("projectSettings"), "open") == &Value::Bool(true) {
            return world.dispatch("projectSettings.workspace", json!({"value": c[0]}));
        }
        world.sync()?; // a menu can open on the MC's answer
        // From an open command palette (a file found by name): its entry of
        // that title or path.
        if is_open(world) {
            for row in 0..add_project::count(world) {
                if id_at(world, row) == c[0] || role_text(world, row, "title") == c[0] {
                    invoke(world, "run", &[Lv::Int(row as i32)])?;
                    return world.sync();
                }
            }
            fail!("the command palette does not list \"{}\"", c[0]);
        }
        // With no menu open, the pick is an answer to the agent's question.
        if !world.state("menu").is_object() {
            return pick_answer(world, &c[0]);
        }
        choose(world, json!(c[0]))
    });
    steps.step("the user dismisses the menu", |world, _, _| {
        choose(world, Value::Null)
    });

    // The sidebar and menu the shell shows.
    steps.step(
        &format!("the sidebar's {Q} section lists {Q}"),
        |world, c, _| {
            world.sync()?;
            let titles = section_titles(world, &c[0]);
            expect!(titles == c[1], "{} lists \"{titles}\"", c[0]);
            Ok(())
        },
    );
    steps.step(
        &format!("the sidebar's {Q} section is empty"),
        |world, c, _| {
            world.sync()?;
            let titles = section_titles(world, &c[0]);
            expect!(titles.is_empty(), "{} lists \"{titles}\"", c[0]);
            Ok(())
        },
    );
    steps.step(&format!("the sidebar is scoped to {Q}"), |world, c, _| {
        let want = world.project_key(&c[0]);
        world.wait_for_with(
            |w| text(at(&w.state("sidebar"), "scopeProjectKey")) == want,
            |w| {
                format!(
                    "the sidebar is scoped to {}",
                    text(at(&w.state("sidebar"), "scopeProjectKey"))
                )
            },
        )
    });
    steps.step("the sidebar is not scoped", |world, _, _| {
        let sidebar = world.state("sidebar");
        let scope = at(&sidebar, "scopeProjectKey");
        expect!(scope.is_null(), "the sidebar is scoped to {}", text(scope));
        Ok(())
    });
    steps.step("a menu opens at (\\d+), (\\d+) with:", |world, c, table| {
        world.sync()?;
        let menu = world.state("menu");
        let (x, y) = (
            at(&menu, "x").as_i64().unwrap_or(-1),
            at(&menu, "y").as_i64().unwrap_or(-1),
        );
        expect!(
            x.to_string() == c[0] && y.to_string() == c[1],
            "the menu is {}",
            show(&menu)
        );
        let mut actual = vec![table[0].clone()];
        for item in at(&menu, "items").as_array().into_iter().flatten() {
            actual.push(vec![text(&item["id"]), text(&item["label"])]);
        }
        expect!(&actual == table, "the menu is {}", show(&menu));
        Ok(())
    });
    steps.step("the menu closes", |world, _, _| {
        let menu = world.state("menu");
        expect!(menu.is_null(), "the menu is {}", show(&menu));
        Ok(())
    });
}
