//! The thread list's Working section (threads/sidebar-list.feature): busy
//! threads fold into it, leave it after a grace the clock runs out, and the
//! inbox above it keeps the order threads came back in. The grace is driven
//! by set_time and a refresh, never by waiting. desktop-qt's
//! ThreadWorkingSteps.cpp.

use chrono::{DateTime, Duration, Utc};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::sidebar::Sidebar;
use hal_c2_shell::json as shell_json;
use ljos::prelude::Value as QmlValue;
use serde_json::{Map, Value, json};

use super::settings_rows::{general_page, page_item, setting_on, turn_row};
use super::stream::iso;
use super::thread_list::{put_thread, title_id};
use super::thread_menu::{key_of, section_of, update_row};
use crate::brick::{Brick, Shown};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const SHELF: &str = "sidebarWorkingShelfEnabled";
const GRACE_MS: i64 = hal_c2_shell::sidebar_model::WORKING_EXIT_GRACE_MS;

/// What the scenario saw: the section of the thread it follows after each
/// change.
#[derive(Default)]
struct Scene {
    subject: String,
    seen: Vec<String>,
    orders: Vec<Vec<String>>,
}

fn id_of(title: &str) -> String {
    title_id(title)
}

fn put(world: &mut World, title: &str, mut row: Value) -> Outcome {
    if row.get("projectId").is_none() {
        let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
        row["projectId"] = json!(project);
    }
    row["title"] = json!(title);
    put_thread(world, &id_of(title), row)?;
    world.sync()
}

/// A run the user asked for at `at`, going.
fn running(run: &str, at: DateTime<Utc>) -> Value {
    json!({
        "latestRunId": run,
        "activeRunId": run,
        "status": "running",
        "latestRunRequestedAt": iso(at),
        "latestRunStartedAt": iso(at),
        "latestUserMessageAt": iso(at),
        "latestUserAuthoredMessageAt": iso(at),
        "updatedAt": iso(at),
    })
}

fn change(world: &mut World, title: &str, edit: impl FnOnce(&mut Map<String, Value>)) -> Outcome {
    let now = iso(world.now());
    update_row(world, &id_of(title), |row| {
        edit(row);
        row.insert("updatedAt".into(), json!(now));
    })
}

fn end_run(row: &mut Map<String, Value>, at: DateTime<Utc>) {
    row.insert("status".into(), json!("idle"));
    row.remove("activeRunId");
    row.insert("latestRunCompletedAt".into(), json!(iso(at)));
}

/// The clock moves on and the list looks again, as the grace's timer has
/// it do.
fn advance(world: &mut World, ms: i64) -> Outcome {
    let at = world.now() + Duration::milliseconds(ms);
    world.set_time(at);
    world.with::<Sidebar, _>(|sidebar, engine| sidebar.refresh(engine))?;
    world.sync()
}

fn titles(world: &World, section: &str) -> Vec<String> {
    at(&world.state("sidebar"), section)
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| text(&row["title"]))
        .collect()
}

fn section_of_title(world: &mut World, title: &str) -> Outcome<String> {
    let key = key_of(world, title)?;
    Ok(section_of(world, &key))
}

fn see(world: &mut World) -> Outcome {
    let subject = world.part::<Scene>().subject.clone();
    let section = section_of_title(world, &subject)?;
    world.part::<Scene>().seen.push(section);
    Ok(())
}

/// The thread list as the window draws it.
fn thread_list(world: &mut World) -> Outcome<Brick> {
    if let Some(brick) = world.part::<Shown>().0 {
        return Ok(brick);
    }
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nSidebar { height: 600 }\n",
        256.0,
        600.0,
    )?;
    world.part::<Shown>().0 = Some(brick);
    Ok(brick)
}

fn list_rows(brick: &Brick, world: &World) -> Vec<Value> {
    let Some(root) = brick.root(world) else {
        return Vec::new();
    };
    let rows = brick.read(world, root, "rows");
    shell_json::from_value(world.engine(), &rows)
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// Where the list draws the row named `row_key` (a thread's key,
/// "header:working"), -1 when it does not.
fn row_index(rows: &[Value], row_key: &str) -> i64 {
    rows.iter()
        .position(|row| text(&row["rowKey"]) == row_key)
        .map_or(-1, |i| i as i64)
}

fn toggle_working(world: &mut World) -> Outcome {
    let brick = thread_list(world)?;
    let Some(root) = brick.root(world) else {
        fail!("the thread list did not load");
    };
    world
        .engine()
        .invoke_by_name(root, "toggleSection", &[QmlValue::from("working")])
        .map_err(|e| crate::harness::Failure(format!("toggleSection: {e:?}")))?;
    world.pump()
}

pub fn register(steps: &mut Steps) {
    // The setting.
    steps.step(
        "Working section is on in General settings",
        |world, _, _| {
            turn_row(world, SHELF, true)?;
            world.part::<Shown>().0 = None;
            Ok(())
        },
    );
    steps.step("the Working section is on", |world, _, _| {
        expect!(setting_on(world, SHELF), "the Working section is off");
        Ok(())
    });
    // For scenarios about the order the user arranges, which the section's
    // inbox does not keep.
    steps.step("the Working section is off", |world, _, _| {
        let engine = world.engine().clone();
        Settings::of(&engine).set(&engine, SHELF, json!(false));
        world.with::<Sidebar, _>(|sidebar, engine| sidebar.refresh(engine))?;
        world.sync()
    });
    steps.step(
        "the user never changed whether the Working section is on",
        |world, _, _| {
            let device = Settings::of(world.engine()).device();
            expect!(
                !device.contains_key(SHELF),
                "this device has a Working section setting"
            );
            Ok(())
        },
    );

    // Busy threads.
    steps.step(
        "threads are working, connecting or monitoring",
        |world, _, _| {
            let now = world.now();
            put(world, "Idle", json!({}))?;
            put(
                world,
                "Later",
                json!({
                    "snoozedUntil": iso(now + Duration::days(1)),
                    "snoozedAt": iso(now - Duration::seconds(3600)),
                }),
            )?;
            put(
                world,
                "Done",
                json!({
                    "settledOverride": "settled",
                    "settledAt": iso(now - Duration::seconds(3600)),
                }),
            )?;
            put(
                world,
                "Build",
                running("r-build", now - Duration::seconds(60)),
            )?;
            let mut connecting = running("r-connect", now - Duration::seconds(50));
            connecting["status"] = json!("starting");
            put(world, "Connect", connecting)?;
            // Its run ended, and it waits on a command it left running.
            let mut monitoring = running("r-monitor", now - Duration::seconds(40));
            if let Some(fields) = monitoring.as_object_mut() {
                end_run(fields, now - Duration::seconds(30));
            }
            monitoring["pendingBackgroundTasks"] = json!([{"id": "tests"}]);
            put(world, "Monitor", monitoring)
        },
    );
    steps.step("threads are working", |world, _, _| {
        let at = world.now() - Duration::seconds(60);
        put(world, "Build", running("r-build", at))
    });
    steps.step(
        "they move into a collapsed Working section above Snoozed and Settled",
        |world, _, _| {
            world.wait_for_with(
                |w| titles(w, "working").len() == 3,
                |w| {
                    format!(
                        "three working threads; Working lists {}",
                        titles(w, "working").join(", ")
                    )
                },
            )?;
            expect!(
                titles(world, "active") == vec!["Idle".to_owned()],
                "the inbox lists {}",
                titles(world, "active").join(", ")
            );
            let brick = thread_list(world)?;
            let rows = list_rows(&brick, world);
            let working = row_index(&rows, "header:working");
            let snoozed = row_index(&rows, "header:snoozed");
            let settled = row_index(&rows, "header:settled");
            expect!(
                working >= 0 && working < snoozed && snoozed < settled,
                "the headers are at {working}, {snoozed} and {settled}"
            );
            expect!(
                rows[working as usize]["open"] != json!(true),
                "the Working section is open"
            );
            for title in ["Build", "Connect", "Monitor"] {
                let key = key_of(world, title)?;
                expect!(
                    row_index(&rows, &key) < 0,
                    "{title} is drawn in the folded section"
                );
            }
            // Opened, its rows are the inbox's cards, not a shelf's slim
            // ones.
            toggle_working(world)?;
            let open = list_rows(&brick, world);
            let key = key_of(world, "Build")?;
            let build = row_index(&open, &key);
            expect!(
                build >= 0 && text(&open[build as usize]["kind"]) == "thread",
                "the open section draws {}",
                show(if build >= 0 {
                    &open[build as usize]
                } else {
                    &Value::Null
                })
            );
            Ok(())
        },
    );
    steps.step("they move into the Working section", |world, _, _| {
        world.wait_for_with(
            |w| {
                let sidebar = w.state("sidebar");
                at(&sidebar, "working")
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|row| text(&row["title"]) == "Build")
            },
            |w| {
                format!(
                    "Build in Working; Working lists {}",
                    titles(w, "working").join(", ")
                )
            },
        )
    });
    steps.step(
        "a thread returns to the top of the inbox when it finishes, fails or asks for approval or an answer",
        |world, _, _| {
            let top = |world: &World, title: &str| -> Outcome {
                let inbox = titles(world, "active");
                expect!(
                    inbox.first().is_some_and(|first| first == title),
                    "{title} at the top of the inbox; it lists {}",
                    inbox.join(", ")
                );
                Ok(())
            };
            // Finishing: once the grace is up.
            advance(world, 1000)?;
            let at = world.now();
            change(world, "Build", |row| end_run(row, at))?;
            advance(world, GRACE_MS)?;
            top(world, "Build")?;
            // Failing, at once.
            advance(world, 1000)?;
            let at = world.now();
            change(world, "Connect", |row| {
                end_run(row, at);
                row.insert("status".into(), json!("failed"));
            })?;
            top(world, "Connect")?;
            // Asking for an answer, at once.
            advance(world, 1000)?;
            change(world, "Monitor", |row| {
                row.insert(
                    "pendingRuntimeRequest".into(),
                    json!({"kind": "user_input"}),
                );
            })?;
            top(world, "Monitor")?;
            // And for an approval.
            advance(world, 1000)?;
            let at = world.now();
            put(world, "Deploy", running("r-deploy", at))?;
            expect!(
                section_of_title(world, "Deploy")? == "working",
                "Deploy is not working"
            );
            advance(world, 1000)?;
            change(world, "Deploy", |row| {
                row.insert(
                    "pendingRuntimeRequest".into(),
                    json!({"kind": "command_approval"}),
                );
            })?;
            top(world, "Deploy")
        },
    );
    steps.step(
        "drag reordering in the inbox is off while it is on",
        |world, _, _| {
            let before = titles(world, "active");
            expect!(before.len() >= 2, "the inbox lists {}", before.join(", "));
            let sent = world.mc.commands.len();
            let last = key_of(world, before.last().unwrap())?;
            let first = key_of(world, before.first().unwrap())?;
            world.dispatch(
                "thread.drop",
                json!({"key": last, "section": "active", "beforeKey": first}),
            )?;
            world.sync()?;
            expect!(
                titles(world, "active") == before && world.mc.commands.len() == sent,
                "the drop moved the inbox to {}",
                titles(world, "active").join(", ")
            );
            // Nor does its menu offer to move a row up or down.
            let last = key_of(world, before.last().unwrap())?;
            expect!(
                !hal_c2_shell::controllers::sidebar::can_move(world.engine(), &last, true),
                "the menu moves an inbox row"
            );
            Ok(())
        },
    );
    steps.step(
        "restoring the setting's default turns the Working section back on",
        |world, _, _| {
            world.part::<Shown>().0 = None;
            turn_row(world, SHELF, false)?;
            world.wait_for_with(
                |w| {
                    at(&w.state("sidebar"), "active")
                        .as_array()
                        .into_iter()
                        .flatten()
                        .any(|row| text(&row["title"]) == "Build")
                },
                |w| {
                    format!(
                        "Build in the inbox with the section off; the inbox lists {}",
                        titles(w, "active").join(", ")
                    )
                },
            )?;
            let page = general_page(world)?;
            let reset = page_item(world, &format!("settingsRow:{SHELF}"), "reset")?;
            let (x, y) = page.at(world, reset, 0.5, 0.5)?;
            world.click_at(x, y)?;
            world.wait_for_with(
                |w| {
                    setting_on(w, SHELF)
                        && at(&w.state("sidebar"), "working")
                            .as_array()
                            .into_iter()
                            .flatten()
                            .any(|row| text(&row["title"]) == "Build")
                },
                |w| {
                    format!(
                        "Build in Working again; Working lists {}",
                        titles(w, "working").join(", ")
                    )
                },
            )
        },
    );

    // The Working section's order.
    steps.step(
        "several threads are in the Working section",
        |world, _, _| {
            let now = world.now();
            put(
                world,
                "Alpha",
                running("r-alpha", now - Duration::seconds(30 * 60)),
            )?;
            put(
                world,
                "Bravo",
                running("r-bravo", now - Duration::seconds(20 * 60)),
            )?;
            put(
                world,
                "Charlie",
                running("r-charlie", now - Duration::seconds(10 * 60)),
            )?;
            *world.part::<Scene>() = Scene::default();
            let order = titles(world, "working");
            world.part::<Scene>().orders.push(order.clone());
            expect!(order.len() == 3, "Working lists {}", order.join(", "));
            Ok(())
        },
    );
    steps.step(
        "an agent run ends, or a subagent result or pull request watch wakes a thread",
        |world, _, _| {
            // Bravo's run ends, leaving a subagent it waits on.
            advance(world, 1000)?;
            let at = world.now();
            change(world, "Bravo", |row| {
                end_run(row, at);
                row.insert("pendingBackgroundTasks".into(), json!([{"id": "subagent"}]));
            })?;
            let order = titles(world, "working");
            world.part::<Scene>().orders.push(order);
            // The subagent's result wakes Alpha with a message sent as
            // the user; the user typed nothing.
            advance(world, 1000)?;
            let at = iso(world.now());
            change(world, "Alpha", |row| {
                row.insert("latestRunId".into(), json!("r-alpha-2"));
                row.insert("activeRunId".into(), json!("r-alpha-2"));
                row.insert("latestRunRequestedAt".into(), json!(at));
                row.insert("latestUserMessageAt".into(), json!(at));
            })?;
            let order = titles(world, "working");
            world.part::<Scene>().orders.push(order);
            // A pull request watch wakes Bravo the same way.
            advance(world, 1000)?;
            let at = iso(world.now());
            change(world, "Bravo", |row| {
                row.remove("pendingBackgroundTasks");
                row.insert("latestRunId".into(), json!("r-bravo-2"));
                row.insert("activeRunId".into(), json!("r-bravo-2"));
                row.insert("status".into(), json!("running"));
                row.remove("latestRunCompletedAt");
                row.insert("latestRunRequestedAt".into(), json!(at));
                row.insert("latestUserMessageAt".into(), json!(at));
            })?;
            let order = titles(world, "working");
            world.part::<Scene>().orders.push(order);
            advance(world, GRACE_MS)?;
            let order = titles(world, "working");
            world.part::<Scene>().orders.push(order);
            Ok(())
        },
    );
    steps.step(
        "the section is ordered by the last message the user sent, newest first, and no row moves",
        |world, _, _| {
            let expected: Vec<String> = ["Charlie", "Bravo", "Alpha"]
                .iter()
                .map(|s| (*s).to_owned())
                .collect();
            for order in world.part::<Scene>().orders.clone() {
                expect!(order == expected, "Working was {}", order.join(", "));
            }
            Ok(())
        },
    );

    // The grace.
    steps.step(&format!("{Q} is in the Working section"), |world, c, _| {
        let at = world.now() - Duration::seconds(60);
        put(world, &c[0], running("r1", at))?;
        *world.part::<Scene>() = Scene {
            subject: c[0].clone(),
            ..Scene::default()
        };
        let section = section_of_title(world, &c[0])?;
        expect!(section == "working", "{} is in \"{section}\"", c[0]);
        Ok(())
    });
    steps.step(
        "its run ends and (its next run starts|the MC settles it|nothing else happens|it asks for approval) within two seconds",
        |world, c, _| {
            let title = world.part::<Scene>().subject.clone();
            if c[0] == "it asks for approval" {
                let at = world.now();
                change(world, &title, |row| {
                    end_run(row, at);
                    row.insert(
                        "pendingRuntimeRequest".into(),
                        json!({"kind": "command_approval"}),
                    );
                })?;
                return see(world);
            }
            let at = world.now();
            change(world, &title, |row| end_run(row, at))?;
            see(world)?;
            advance(world, 1000)?;
            see(world)?;
            if c[0] == "its next run starts" {
                let next = running("r2", world.now());
                change(world, &title, |row| {
                    if let Value::Object(fields) = next {
                        for (k, v) in fields {
                            row.insert(k, v);
                        }
                    }
                    row.remove("latestRunCompletedAt");
                })?;
            } else if c[0] == "the MC settles it" {
                let at = iso(world.now());
                change(world, &title, |row| {
                    row.insert("settledOverride".into(), json!("settled"));
                    row.insert("settledAt".into(), json!(at));
                })?;
            } else {
                advance(world, GRACE_MS - 1000 - 1)?;
            }
            see(world)?;
            advance(world, GRACE_MS)?;
            see(world)
        },
    );
    steps.step(
        &format!(
            "{Q} (never leaves the Working section|moves straight to Settled, never to the inbox|moves to the inbox once the two seconds are up|moves to the inbox at once)"
        ),
        |world, c, _| {
            let seen = world.part::<Scene>().seen.clone();
            let shown = seen.join(" \u{2192} ");
            if c[1].starts_with("never leaves") {
                expect!(
                    !seen.is_empty()
                        && seen.iter().all(|section| section == "working"),
                    "{} went {shown}",
                    c[0]
                );
            } else if c[1].starts_with("moves straight to Settled") {
                expect!(
                    !seen.contains(&"active".to_owned())
                        && seen.last().is_some_and(|s| s == "settled"),
                    "{} went {shown}",
                    c[0]
                );
            } else if c[1].ends_with("are up") {
                // Working at the end of the run, a second on, and a
                // moment before the two are up.
                expect!(
                    seen == vec!["working", "working", "working", "active"],
                    "{} went {shown}",
                    c[0]
                );
            } else {
                expect!(seen == vec!["active"], "{} went {shown}", c[0]);
            }
            Ok(())
        },
    );

    // The status marker's spoken name.
    steps.step(
        "a screen reader reaches a thread's status marker",
        |world, _, _| {
            let now = world.now();
            put(
                world,
                "Build",
                running("r-build", now - Duration::seconds(60)),
            )?;
            let mut asking = running("r-ask", now - Duration::seconds(50));
            asking["pendingRuntimeRequest"] = json!({"kind": "user_input"});
            put(world, "Ask", asking)?;
            let mut approving = running("r-approve", now - Duration::seconds(40));
            approving["pendingRuntimeRequest"] = json!({"kind": "command_approval"});
            put(world, "Approve", approving)?;
            thread_list(world)?;
            toggle_working(world)
        },
    );
    steps.step(
        "it announces Working, Awaiting input or Pending approval",
        |world, _, _| {
            let brick = thread_list(world)?;
            for (title, name) in [
                ("Build", "Working"),
                ("Ask", "Awaiting input"),
                ("Approve", "Pending approval"),
            ] {
                let key = key_of(world, title)?;
                let mut spoken = String::new();
                // The marker's Accessible.name is the row's spokenStatus.
                let found = {
                    world.pump()?;
                    let row = brick.find(world, &format!("threadRow:{key}"))?;
                    match row {
                        Some(row) => {
                            spoken = brick.text_of(world, row, "spokenStatus");
                            spoken == name
                        }
                        None => false,
                    }
                };
                expect!(
                    found,
                    "{title}'s status marker to say \"{name}\"; it says \"{spoken}\""
                );
            }
            Ok(())
        },
    );
}
