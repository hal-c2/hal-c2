//! Threads on other machines of the cluster, in the shell: listed beside this
//! MC's own and offline while their MC is down (the cluster members' scenarios
//! of navigation/header.feature, navigation/keybindings.feature and
//! source-control/, and threads/sidebar-list.feature): desktop-qt's
//! MemberSteps.cpp.

use serde_json::{Value, json};

use crate::expect;
use crate::harness::{Q, Steps, at, show, text};
use crate::world::World;

/// The thread on another machine the scenario is about.
#[derive(Default)]
struct MemberThread {
    environment: String,
    id: String,
}

const MEMBER_THREAD: &str = "t-member";

fn thread_row(id: &str, title: &str, project: &str) -> Value {
    json!({
        "id": id,
        "title": title,
        "projectId": project,
        "createdAt": "2026-09-23T09:00:00Z",
        "updatedAt": "2026-09-23T09:00:00Z",
    })
}

fn put_project(world: &mut World, environment: &str, project: &str) {
    world.mc.send_peer_row_of(
        environment,
        project,
        &json!({
            "id": project,
            "title": project,
            "workspaceRoot": format!("/work/{project}"),
            "scripts": [],
        }),
        "project",
    );
}

/// Every thread row of the sidebar, whatever its section.
fn sidebar_rows(world: &World) -> Vec<Value> {
    let sidebar = world.state("sidebar");
    ["pinned", "active", "snoozed", "settled"]
        .iter()
        .flat_map(|section| {
            at(&sidebar, section)
                .as_array()
                .cloned()
                .unwrap_or_default()
        })
        .collect()
}

fn sidebar_row(world: &World, key: &str) -> Value {
    sidebar_rows(world)
        .into_iter()
        .find(|row| text(&row["key"]) == key)
        .unwrap_or(Value::Null)
}

/// The member's thread's row, once it satisfies `holds`.
fn wait_for_row(
    world: &mut World,
    holds: impl Fn(&Value) -> bool,
    what: String,
) -> crate::harness::Outcome {
    let thread = world.part::<MemberThread>();
    let key = format!("{}:{}", thread.environment, thread.id);
    world.wait_for_with(
        |w| holds(&sidebar_row(w, &key)),
        |w| format!("{what}; the sidebar is {}", show(&w.state("sidebar"))),
    )
}

fn workspace(world: &World) -> Value {
    world.state("workspace")
}

pub fn register(steps: &mut Steps) {
    steps.step(&format!("{Q} becomes unreachable"), |world, c, _| {
        world.mc.set_online(&c[0], false);
        Ok(())
    });
    steps.step(&format!("{Q} is reachable again"), |world, c, _| {
        world.mc.set_online(&c[0], true);
        Ok(())
    });

    // navigation/header.feature and the git scenarios of source-control/ on another machine.
    steps.step(
        &format!("{Q} has the thread {Q} titled {Q} in {Q} on the branch {Q}"),
        |world, c, _| {
            *world.part::<MemberThread>() = MemberThread {
                environment: c[0].clone(),
                id: c[1].clone(),
            };
            put_project(world, &c[0], &c[3]);
            let mut row = thread_row(&c[1], &c[2], &c[3]);
            row["branch"] = json!(c[4]);
            world.mc.send_peer_row(&c[0], &c[1], &row);
            world.sync()
        },
    );
    steps.step("the header says the thread is offline", |world, _, _| {
        world.wait_for_with(
            |w| workspace(w)["offline"] == json!(true),
            |w| {
                format!(
                    "the header to say offline; it shows {}",
                    show(&workspace(w))
                )
            },
        )
    });
    steps.step(
        "the header no longer says the thread is offline",
        |world, _, _| {
            world.wait_for_with(
                |w| workspace(w)["offline"] == json!(false),
                |w| format!("the header to say online; it shows {}", show(&workspace(w))),
            )
        },
    );

    // threads/sidebar-list.feature: a member of the cluster whose MC is down.
    steps.step(&format!("the environment {Q} is offline"), |world, c, _| {
        *world.part::<MemberThread>() = MemberThread {
            environment: c[0].clone(),
            id: MEMBER_THREAD.into(),
        };
        world.mc.send_peer_row(
            &c[0],
            MEMBER_THREAD,
            &thread_row(MEMBER_THREAD, "Deploy", "shop"),
        );
        world.mc.offline.insert(c[0].clone());
        world.mc.join_named(&c[0]);
        Ok(())
    });
    steps.step(
        &format!("the threads from {Q} are listed as unavailable"),
        |world, c, _| {
            let environment = c[0].clone();
            wait_for_row(
                world,
                |row| row["environmentId"] == json!(environment) && row["offline"] == json!(true),
                format!("the thread from {} to be listed offline", c[0]),
            )
        },
    );
    steps.step(
        &format!("actions that need {Q} are unavailable"),
        |world, c, _| {
            for row in sidebar_rows(world) {
                if row["environmentId"] != json!(c[0]) {
                    continue;
                }
                expect!(
                    row["canSettle"] != json!(true) && row["canSnooze"] != json!(true),
                    "the row offers actions: {}",
                    show(&row)
                );
            }
            Ok(())
        },
    );
}
