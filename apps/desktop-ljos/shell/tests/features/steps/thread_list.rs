//! The thread list in the domain's words: its sections and order, opening
//! and scoping from it, the snoozed and settled shelves, and the state each
//! row names (threads/sidebar-list.feature, threads/snooze.feature,
//! threads/settle.feature, threads/unread-and-status.feature,
//! threads/limited-threads.feature): desktop-qt's ThreadListSteps.cpp. The
//! helpers it shares live in thread_menu.rs.

use std::cell::Cell;
use std::collections::BTreeSet;
use std::rc::Rc;

use chrono::{DateTime, Datelike, Duration, NaiveTime, TimeZone, Utc};
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use serde_json::{Map, Value, json};

use super::settings_rows::turn_row;
use super::stream::{FakeStreams, add_item, iso, start_run};
use super::thread_menu::{id_in, key_of, project_thread_commands, section_of, update_row};
use crate::brick::{Brick, Shown};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const AT: &str = "2026-09-23T09:00:00Z";

/// The project whose sections threads/sidebar-list.feature reads, and what
/// the list showed across a reconnect.
#[derive(Default)]
struct ListScene {
    sections_project: String,
    subscriptions: usize,
    fewest: Rc<Cell<usize>>,
}

fn scene(world: &mut World) -> &mut ListScene {
    world.part::<ListScene>()
}

/// The project the list was scoped to, and the member that had not reported.
#[derive(Default)]
struct ScopeMemory {
    name: String,
    key: String,
    waiting: String,
}

/// How many commands the MC had before a drop.
#[derive(Default)]
struct Reorder {
    commands_before: usize,
}

/// A row the row-lines steps draw on its own.
#[derive(Default)]
struct RowItem(Value);

/// The titles of the active section, top first.
fn active_titles(world: &World) -> Vec<String> {
    titles_of(world, "active")
}

/// Takes the project from the MC (while the app is closed: no row is sent).
fn remove_project_titled(world: &mut World, title: &str) {
    world
        .mc
        .projects
        .retain(|_, row| text(&row["title"]) != title);
}

/// The thread list as the window draws it, its rows as Sidebar.qml builds
/// them.
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
    hal_c2_shell::json::from_value(world.engine(), &rows)
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn number(brick: &Brick, world: &World, item: ljos::prelude::ObjectId, name: &str) -> f64 {
    let value = brick.read(world, item, name);
    hal_c2_shell::json::from_value(world.engine(), &value)
        .as_f64()
        .unwrap_or(0.0)
}

/// Where the row's top is in the list's view, or -1 when it is not wholly
/// in it (or not drawn).
fn row_top(brick: &Brick, world: &World, key: &str) -> Outcome<f64> {
    let list = brick.item(world, "list")?;
    if !brick.flag(world, list, "visible") {
        return Ok(-1.0);
    }
    let Some(row) = brick.find(world, &format!("threadRow:{key}"))? else {
        return Ok(-1.0);
    };
    if !brick.flag(world, row, "visible") {
        return Ok(-1.0);
    }
    let (_, row_y) = brick.at(world, row, 0.0, 0.0)?;
    let (_, list_y) = brick.at(world, list, 0.0, 0.0)?;
    let top = row_y - list_y;
    let height = number(&brick, world, row, "height");
    let list_height = number(&brick, world, list, "height");
    Ok(if top >= 0.0 && top + height <= list_height {
        top
    } else {
        -1.0
    })
}

fn sidebar(world: &World) -> Value {
    world.state("sidebar")
}

fn active_count(world: &World) -> usize {
    sidebar(world)["active"].as_array().map_or(0, Vec::len)
}

/// Puts the thread `id` on the MC (`row` plus its id and dates) and, once the
/// shell is connected, waits for it.
pub fn put_thread(world: &mut World, id: &str, fields: Value) -> Outcome {
    let mut row = fields;
    row["id"] = json!(id);
    if row.get("createdAt").is_none() {
        row["createdAt"] = json!(AT);
    }
    if row.get("updatedAt").is_none() {
        row["updatedAt"] = row["createdAt"].clone();
    }
    world.mc.threads.insert(id.to_owned(), row.clone());
    world.mc.send_row(id, &row);
    if world.client_ready() {
        world.sync()?;
    }
    Ok(())
}

pub fn title_id(title: &str) -> String {
    format!("t-{}", title.to_lowercase().replace(' ', "-"))
}

fn has_thread(world: &World, title: &str) -> bool {
    world
        .mc
        .threads
        .values()
        .any(|row| text(&row["title"]) == title)
}

fn first_project(world: &World) -> String {
    world.mc.projects.keys().next().cloned().unwrap_or_default()
}

/// The thread the scenario names, in `project` (the first project when
/// empty) unless the MC already has it.
pub fn ensure_thread(world: &mut World, title: &str, project: &str) -> Outcome<String> {
    if !has_thread(world, title) {
        let project = if project.is_empty() {
            first_project(world)
        } else {
            project.to_owned()
        };
        put_thread(
            world,
            &title_id(title),
            json!({"projectId": project, "title": title}),
        )?;
    }
    key_of(world, title)
}

fn row_of(world: &World, key: &str) -> Option<Value> {
    let state = sidebar(world);
    ["pinned", "active", "working", "snoozed", "settled"]
        .iter()
        .find_map(|section| {
            state[*section]
                .as_array()
                .into_iter()
                .flatten()
                .find(|row| text(&row["key"]) == key)
                .cloned()
        })
}

fn shown_row(world: &World, key: &str) -> String {
    show(&row_of(world, key).unwrap_or(Value::Null))
}

/// The word SidebarThreadRow shows for a row's state (its status first, then
/// woke, then unread).
pub fn word_of(row: &Value) -> &'static str {
    if row["offline"].as_bool() == Some(true) {
        return "Offline";
    }
    match text(&row["status"]).as_str() {
        "working" => return "Working",
        "waiting" => return "Waiting",
        "approval" => return "Approval",
        "input" => return "Input",
        "limited" => return "Limited",
        "failed" => return "Failed",
        _ => {}
    }
    if !row["wokeAt"].is_null() {
        return "Woke";
    }
    if row["unread"].as_bool() == Some(true) {
        return "Done";
    }
    ""
}

pub fn wait_for_section(world: &mut World, thread: &str, section: &str) -> Outcome {
    let key = key_of(world, thread)?;
    world.wait_for_with(
        |w| section_of(w, &key) == section,
        |w| {
            format!(
                "{thread} in {section}; it is in \"{}\"",
                section_of(w, &key)
            )
        },
    )
}

/// Midnight-plus-nine tomorrow, as the scenarios' zone (UTC) reads it.
fn tomorrow_at_nine(now: DateTime<Utc>) -> DateTime<Utc> {
    let day = now.date_naive().succ_opt().unwrap_or(now.date_naive());
    Utc.from_utc_datetime(&day.and_time(NaiveTime::from_hms_opt(9, 0, 0).unwrap_or_default()))
}

/// Snoozed from an hour ago until tomorrow at nine.
fn snooze_until_tomorrow(world: &mut World, thread: &str) -> Outcome {
    let until = iso(tomorrow_at_nine(world.now()));
    let since = iso(world.now() - Duration::hours(1));
    let key = key_of(world, thread)?;
    update_row(world, id_in(&key), |row| {
        row.insert("snoozedUntil".into(), json!(until));
        row.insert("snoozedAt".into(), json!(since));
    })
}

fn active_projects(world: &World) -> BTreeSet<String> {
    sidebar(world)["active"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| text(&row["projectKey"]))
        .collect()
}

fn titles_of(world: &World, section: &str) -> Vec<String> {
    sidebar(world)[section]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| text(&row["title"]))
        .collect()
}

/// Sidebar.qml's "Show N more" row under the shelf: the next page, or what
/// is left.
fn settled_more(world: &World) -> String {
    let state = sidebar(world);
    let total = state["settledTotal"].as_i64().unwrap_or(0);
    let shown = state["settled"].as_array().map_or(0, Vec::len) as i64;
    let page = state["settledPage"].as_i64().unwrap_or(0);
    if total - shown > 0 {
        format!("Show {} more", (total - shown).min(page))
    } else {
        String::new()
    }
}

/// Waits until the shell has noticed the lost connection, keeping count of
/// the fewest active rows the list held meanwhile.
fn wait_until_lost(world: &mut World, fewest: &Rc<Cell<usize>>) -> Outcome {
    let fewest = fewest.clone();
    world.wait_for("the shell to notice the lost connection", move |w| {
        fewest.set(fewest.get().min(active_count(w)));
        !w.client_ready()
    })
}

fn set_state(row: &mut Map<String, Value>, now: DateTime<Utc>, state: &str) {
    let run = |row: &mut Map<String, Value>, status: &str| {
        row.insert("latestRunId".into(), json!("r1"));
        row.insert("status".into(), json!(status));
        row.insert(
            "latestRunStartedAt".into(),
            json!(iso(now - Duration::seconds(900))),
        );
    };
    let finished = |row: &mut Map<String, Value>, visited_at: String| {
        run(row, "completed");
        let ended = iso(now - Duration::seconds(600));
        row.insert("latestRunCompletedAt".into(), json!(ended));
        // The MC stamps the thread when its run ends.
        row.insert("updatedAt".into(), json!(ended));
        row.insert("lastVisitedAt".into(), json!(visited_at));
    };
    if state == "has an agent working" {
        run(row, "running");
        row.insert("activeRunId".into(), json!("r1"));
    } else if state == "has a queued turn waiting to start" {
        // The session is up and idle; the queued turn has not started a run.
        row.insert("activeProviderThreadId".into(), json!("p1"));
        row.insert("status".into(), json!("idle"));
    } else if state.starts_with("is waiting for an") {
        run(row, "running");
        let kind = if state.ends_with("question") {
            "user_input"
        } else {
            "command_approval"
        };
        row.insert(
            "pendingRuntimeRequest".into(),
            json!({"id": "q1", "kind": kind, "createdAt": iso(now - Duration::seconds(60))}),
        );
    } else if state.contains("usage limit") {
        run(row, "failed");
        row.insert("lastErrorClass".into(), json!("usage_limit"));
    } else if state == "had its last run fail" {
        run(row, "failed");
    } else if state == "woke early from a snooze" {
        // Snoozed until tomorrow, but its run finished after the snooze.
        finished(row, iso(now - Duration::hours(3)));
        row.insert("snoozedAt".into(), json!(iso(now - Duration::hours(2))));
        row.insert("snoozedUntil".into(), json!(iso(now + Duration::days(1))));
    } else {
        finished(row, iso(now - Duration::hours(1)));
    }
}

pub fn register(steps: &mut Steps) {
    // Backgrounds and the list's contents.
    steps.step(
        &format!("a connected environment with the thread {Q} on Claude"),
        |world, c, _| {
            world.mc.projects.insert(
                "shop".into(),
                json!({"id": "shop", "title": "shop", "workspaceRoot": "/work/shop",
                       "scripts": [], "createdAt": AT, "updatedAt": AT}),
            );
            world.connect()?;
            put_thread(
                world,
                "t1",
                json!({"projectId": "shop", "title": c[0],
                       "modelSelection": {"instanceId": "claudeAgent", "model": "claude-sonnet-4-5"}}),
            )
        },
    );
    steps.step(
        &format!("{Q} has a draft, a pinned thread, two active threads, a snoozed thread and a settled thread"),
        |world, c, _| {
            project_thread_commands(world);
            let project = c[0].clone();
            let later = iso(world.now() + Duration::days(1));
            put_thread(
                world,
                "t-pinned",
                json!({"projectId": project, "title": "Pinned", "pinnedAt": AT, "pinOrderKey": "a0"}),
            )?;
            put_thread(world, "t-first", json!({"projectId": project, "title": "First"}))?;
            put_thread(world, "t-second", json!({"projectId": project, "title": "Second"}))?;
            put_thread(
                world,
                "t-snoozed",
                json!({"projectId": project, "title": "Snoozed", "snoozedUntil": later, "snoozedAt": AT}),
            )?;
            put_thread(
                world,
                "t-settled",
                json!({"projectId": project, "title": "Settled",
                       "settledOverride": "settled", "settledAt": AT}),
            )?;
            // The list holds the drafts the user wrote in (drafts.feature),
            // once left.
            let key = world.project_key(&project);
            world.start_new_thread(json!({"projectKey": key}))?;
            let target = world.draft_id.clone();
            let revision = world.next_edit;
            world.next_edit += 1;
            world.dispatch(
                "composer.text.set",
                json!({"target": target,
                       "edit": {"clientId": "qml", "revision": revision},
                       "text": "Plan the release", "cursor": 16}),
            )?;
            let first = key_of(world, "First")?;
            world.dispatch("thread.open", json!({"key": first}))?;
            scene(world).sections_project = world.project_key(&project);
            Ok(())
        },
    );
    steps.step(&format!("{Q} was created before {Q}"), |world, c, _| {
        let project = first_project(world);
        put_thread(
            world,
            &title_id(&c[0]),
            json!({"projectId": project, "title": c[0], "createdAt": "2026-09-23T08:00:00Z"}),
        )?;
        put_thread(
            world,
            &title_id(&c[1]),
            json!({"projectId": project, "title": c[1], "createdAt": "2026-09-23T09:00:00Z"}),
        )
    });
    steps.step("there are (\\d+) settled threads", |world, c, _| {
        for index in 0..c[0].parse::<i64>().unwrap_or(0) {
            let at = iso(world.now() - Duration::seconds(60 * (index + 1)));
            let project = first_project(world);
            put_thread(
                world,
                &format!("t-settled-{index}"),
                json!({"projectId": project, "title": format!("Settled {index}"),
                       "settledOverride": "settled", "settledAt": at}),
            )?;
        }
        Ok(())
    });
    steps.step("there are (\\d+) active threads", |world, c, _| {
        for index in 0..c[0].parse::<i64>().unwrap_or(0) {
            let at = iso(world.now() - Duration::seconds(60 * (index + 1)));
            let project = first_project(world);
            put_thread(
                world,
                &format!("t-active-{index}"),
                json!({"projectId": project, "title": format!("Active {index}"), "createdAt": at}),
            )?;
        }
        Ok(())
    });
    // Threads a plugin settles as it finishes them, as the code-review plugin
    // does.
    steps.step("(\\d+) settled threads a plugin started", |world, c, _| {
        for index in 1..=c[0].parse::<i64>().unwrap_or(0) {
            let project = first_project(world);
            let settled = iso(world.now() - Duration::seconds(30 * index));
            put_thread(
                world,
                &format!("t-review-{index}"),
                json!({"projectId": project, "title": format!("Review {index}"),
                       "settledOverride": "settled", "settledAt": settled,
                       "plugin": {"id": "code-review", "kind": "review", "listed": true}}),
            )?;
        }
        Ok(())
    });
    // Settings → General's row, which writes the MC's settings document.
    steps.step(
        "the user turns (on|off) \"Show plugin threads in Settled\"",
        |world, c, _| {
            turn_row(world, "sidebarShowSettledPluginThreads", c[0] == "on")?;
            world.sync()
        },
    );
    steps.step(&format!("{Q} settled after {Q}"), |world, c, _| {
        // Created the other way round, so only when they settled orders them.
        let project = first_project(world);
        put_thread(
            world,
            &title_id(&c[0]),
            json!({"projectId": project, "title": c[0], "createdAt": "2026-09-23T08:00:00Z",
                   "settledOverride": "settled", "settledAt": "2026-09-23T09:50:00Z"}),
        )?;
        put_thread(
            world,
            &title_id(&c[1]),
            json!({"projectId": project, "title": c[1], "createdAt": "2026-09-23T09:00:00Z",
                   "settledOverride": "settled", "settledAt": "2026-09-23T09:10:00Z"}),
        )
    });
    steps.step(&format!("{Q} was renamed since"), |world, c, _| {
        update_row(world, &title_id(&c[0]), |row| {
            row.insert("updatedAt".into(), json!("2026-09-23T09:58:00Z"));
        })
    });
    steps.step(
        &format!("the rows for {Q} and {Q} count their ages from when they settled"),
        |world, c, _| {
            world.sync()?;
            for title in [&c[0], &c[1]] {
                let settled_at = text(&world.mc.threads[&title_id(title)]["settledAt"]);
                let settled = sidebar(world)["settled"].clone();
                let mut listed = false;
                for row in settled.as_array().into_iter().flatten() {
                    if text(&row["title"]) != *title {
                        continue;
                    }
                    listed = true;
                    expect!(
                        text(&row["timeAt"]) == settled_at,
                        "{title} settled at {settled_at}; its row is {}",
                        show(row)
                    );
                }
                expect!(
                    listed,
                    "{title} is not among the settled rows {}",
                    show(&settled)
                );
            }
            Ok(())
        },
    );
    steps.step("the user looks at the settled section", |world, _, _| {
        world.sync()
    });

    // Opening and scoping.
    steps.step("the user opens \"([^\"./:]*)\"", |world, c, _| {
        // A Space page of that name, when the scenario made one.
        if super::space::space_opens(world, &c[0])? {
            return Ok(());
        }
        // A view of the planner plugin, when the MC runs it.
        if super::planner::open_planner_view(world, &c[0])? {
            return Ok(());
        }
        // The Device tab's Tools drawer and event log.
        if super::device::device_opens(world, &c[0])? {
            return Ok(());
        }
        let key = ensure_thread(world, &c[0], "")?;
        world.dispatch("thread.open", json!({"key": key}))
    });
    steps.step("the user opens the draft", |world, _, _| {
        let draft = world.draft_id.clone();
        world.dispatch("draft.open", json!({"draftId": draft}))
    });
    steps.step(
        &format!("the user scopes the thread list to (all projects|{Q})"),
        |world, c, _| {
            // A thread in each project, so the scope has something to leave
            // out.
            let projects: Vec<String> = world.mc.projects.keys().cloned().collect();
            for project in projects {
                ensure_thread(world, &format!("Work in {project}"), &project)?;
            }
            let scope = if c.get(1).is_none_or(String::is_empty) {
                Value::Null
            } else {
                json!(world.project_key(&c[1]))
            };
            world.dispatch("sidebar.scope", json!({"projectKey": scope}))
        },
    );

    // What the list shows.
    steps.step(
        "the sections read drafts, pinned, active, snoozed, settled in that order",
        |world, _, _| {
            // Sidebar.qml draws the sections in this order (tst_Sidebar.qml).
            let state = sidebar(world);
            let own = scene(world).sections_project.clone();
            let mut counts = Vec::new();
            for section in ["drafts", "pinned", "active", "snoozed", "settled"] {
                let rows = state[section].as_array().cloned().unwrap_or_default();
                // The draft the window landed on (navigation/landing.feature)
                // is another project's.
                let n = if section == "drafts" {
                    rows.iter()
                        .filter(|row| text(&row["projectKey"]) == own)
                        .count()
                } else {
                    rows.len()
                };
                counts.push(format!("{section} {n}"));
            }
            expect!(
                counts.join(", ") == "drafts 1, pinned 1, active 2, snoozed 1, settled 1",
                "the list holds {}",
                counts.join(", ")
            );
            Ok(())
        },
    );
    steps.step("(\\d+) settled threads are shown", |world, c, _| {
        let shown = titles_of(world, "settled").len();
        expect!(
            shown.to_string() == c[0],
            "{shown} settled threads are shown"
        );
        Ok(())
    });
    steps.step(
        "the settled section counts (\\d+) threads",
        |world, c, _| {
            // What its header counts (tst_Sidebar.qml).
            let total = sidebar(world)["settledTotal"].as_i64().unwrap_or(0);
            expect!(
                total.to_string() == c[0],
                "the settled section counts {total} threads"
            );
            Ok(())
        },
    );
    steps.step(&format!("the section offers {Q}"), |world, c, _| {
        let more = settled_more(world);
        expect!(more == c[0], "the section offers \"{more}\"");
        Ok(())
    });
    steps.step("the section offers no more", |world, _, _| {
        let more = settled_more(world);
        expect!(more.is_empty(), "the section offers \"{more}\"");
        Ok(())
    });
    steps.step("the user shows more settled threads", |world, _, _| {
        world.dispatch("sidebar.more", json!({}))?;
        world.sync()
    });
    steps.step(
        &format!("{Q} is among the settled threads"),
        |world, c, _| {
            let title = c[0].clone();
            world.wait_for_with(
                |w| titles_of(w, "settled").contains(&title),
                |w| {
                    format!(
                        "{title} among the {} settled rows",
                        titles_of(w, "settled").len()
                    )
                },
            )
        },
    );
    steps.step(&format!("{Q} is shown in the main view"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        world.wait_for_with(
            |w| {
                super::thread_menu::route_thread(w) == key
                    && text(at(&w.state("workspace"), "threadKey")) == key
            },
            |w| {
                format!(
                    "{key} to be shown; the route is {}",
                    show(&w.state("route"))
                )
            },
        )
    });
    steps.step(
        "the draft composer is shown with its unsent text",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let route = w.state("route");
                    let composer = w.state("composer");
                    text(&route["kind"]) == "draft"
                        && text(&route["draftId"]) == w.draft_id
                        && text(&composer["target"]) == w.draft_id
                        && text(&composer["text"]) == "Unsent work"
                },
                |w| {
                    format!(
                        "the draft; the route is {}, the composer {}",
                        show(&w.state("route")),
                        show(&w.state("composer"))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("threads from {Q} and {Q} are listed"),
        |world, c, _| {
            world.sync()?;
            let projects = active_projects(world);
            expect!(
                projects.contains(&world.project_key(&c[0]))
                    && projects.contains(&world.project_key(&c[1])),
                "the list shows {}",
                projects.into_iter().collect::<Vec<_>>().join(", ")
            );
            Ok(())
        },
    );

    // Reconnecting: the MC's snapshot brings what the shell missed, and the
    // rows it already listed stay listed all the while.
    steps.step(
        "the client was disconnected while two threads were created",
        |world, _, _| {
            let project = first_project(world);
            put_thread(
                world,
                "t-earlier",
                json!({"projectId": project, "title": "Earlier work"}),
            )?;
            world.sync()?;
            let subscriptions = world.shell_subscriptions();
            let count = active_count(world);
            let fewest = {
                let state = scene(world);
                state.subscriptions = subscriptions;
                state.fewest = Rc::new(Cell::new(count));
                state.fewest.clone()
            };
            world.mc.drop_connection();
            wait_until_lost(world, &fewest)?;
            for title in ["Made offline one", "Made offline two"] {
                let id = title_id(title);
                world.mc.threads.insert(
                    id.clone(),
                    json!({"id": id, "projectId": project, "title": title,
                           "createdAt": AT, "updatedAt": AT}),
                );
            }
            Ok(())
        },
    );
    steps.step("the client reconnects", |world, _, _| {
        let before = scene(world).subscriptions;
        let fewest = scene(world).fewest.clone();
        world.wait_for("the shell to reconnect", move |w| {
            fewest.set(fewest.get().min(active_count(w)));
            w.client_ready() && w.shell_subscriptions() > before
        })
    });
    steps.step(
        "both threads are listed without reloading the whole list",
        |world, _, _| {
            for title in ["Made offline one", "Made offline two"] {
                wait_for_section(world, title, "active")?;
            }
            let active = active_count(world);
            let fewest = scene(world).fewest.get();
            expect!(
                active == 3 && fewest >= 1,
                "the list holds {active} threads and held as few as {fewest}"
            );
            Ok(())
        },
    );
    steps.step("the MC sent only the two new threads", |world, _, _| {
        // The client said what it held, so nothing it had was sent again.
        let have = world
            .mc
            .subscriptions
            .iter()
            .rev()
            .find(|sub| text(&sub["shape"]["type"]) == "shell")
            .map_or(Value::Null, |sub| sub["have"].clone());
        let Some(frame) = world.mc.shell_frames.last().cloned() else {
            fail!("the MC sent no shell frame");
        };
        let mc = frame["mcs"][0].clone();
        expect!(
            world.mc.shell_frames.len() == 2
                && have[&world.mc.name][0] == json!(world.mc.epoch)
                && mc["reset"] == json!(false)
                && frame["rows"].as_array().map_or(0, Vec::len) == 2,
            "the client held {} and the MC sent {}",
            show(&have),
            show(&frame)
        );
        Ok(())
    });
    steps.step(
        "the client was disconnected while its MC restarted and lost a thread",
        |world, _, _| {
            let project = first_project(world);
            put_thread(
                world,
                "t-earlier",
                json!({"projectId": project, "title": "Earlier work"}),
            )?;
            put_thread(
                world,
                "t-lost",
                json!({"projectId": project, "title": "Lost work"}),
            )?;
            world.sync()?;
            wait_for_section(world, "Lost work", "active")?;
            let subscriptions = world.shell_subscriptions();
            scene(world).subscriptions = subscriptions;
            world.mc.drop_connection();
            let fewest = Rc::new(Cell::new(usize::MAX));
            wait_until_lost(world, &fewest)?;
            // Another run of the MC's shell: what a client holds of its rows
            // is of no use.
            world.mc.epoch = "epoch-2".into();
            world.mc.threads.remove("t-lost");
            Ok(())
        },
    );
    steps.step("the MC sent its whole list", |world, _, _| {
        world.sync()?;
        let Some(frame) = world.mc.shell_frames.last().cloned() else {
            fail!("the MC sent no shell frame");
        };
        let mc = frame["mcs"][0].clone();
        let rows = world.mc.threads.len() + world.mc.projects.len();
        expect!(
            world.mc.shell_frames.len() == 2
                && mc["reset"] == json!(true)
                && frame["rows"].as_array().map_or(0, Vec::len) == rows,
            "the MC holds {rows} rows and sent {}",
            show(&frame)
        );
        Ok(())
    });
    steps.step("the lost thread is no longer listed", |world, _, _| {
        let titles = titles_of(world, "active");
        expect!(
            titles == ["Earlier work"],
            "the list holds {}",
            titles.join(", ")
        );
        Ok(())
    });

    // Snoozing.
    // A day of the week the scenarios' clock starts in (Wednesday 23
    // September 2026).
    steps.step(
        "the local time is (\\w+day) (\\d+):(\\d+)",
        |world, c, _| {
            let mut date = Utc
                .with_ymd_and_hms(2026, 9, 21, 0, 0, 0)
                .single()
                .unwrap_or_default()
                .date_naive();
            for _ in 0..7 {
                if date.weekday().to_string() == c[0][..3] {
                    break;
                }
                date = date.succ_opt().unwrap_or(date);
            }
            let time =
                NaiveTime::from_hms_opt(c[1].parse().unwrap_or(0), c[2].parse().unwrap_or(0), 0)
                    .unwrap_or_default();
            world.set_time(Utc.from_utc_datetime(&date.and_time(time)));
            Ok(())
        },
    );
    steps.step(&format!("{Q} is snoozed until tomorrow"), |world, c, _| {
        snooze_until_tomorrow(world, &c[0])
    });
    steps.step(
        &format!("{Q} is listed in the snoozed section"),
        |world, c, _| wait_for_section(world, &c[0], "snoozed"),
    );
    steps.step("the row says when it will wake", |world, _, _| {
        let snoozed = sidebar(world)["snoozed"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        expect!(
            snoozed.len() == 1 && text(&snoozed[0]["wakeLabel"]) == "23h",
            "the snoozed rows are {}",
            show(&Value::Array(snoozed))
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} returns to the active threads"),
        |world, c, _| wait_for_section(world, &c[0], "active"),
    );
    steps.step(
        &format!("the user points at {Q} in the thread list"),
        |world, c, _| {
            world.sync()?;
            world.checked_commands.clear();
            // Sidebar.qml shows the row's snooze action on hover
            // (tst_Sidebar.qml); choosing it opens the snooze menu at the
            // pointer.
            let key = key_of(world, &c[0])?;
            let row = row_of(world, &key);
            expect!(
                row.as_ref().is_some_and(|r| r["canSnooze"] == json!(true)),
                "the row is {}",
                shown_row(world, &key)
            );
            world.dispatch("thread.snoozeMenu", json!({"key": key, "x": 200, "y": 120}))
        },
    );
    steps.step("the user can snooze it from there", |world, _, _| {
        let menu = world.state("menu");
        expect!(
            menu.is_object() && at(&menu, "items").as_array().is_some_and(|i| !i.is_empty()),
            "the snooze menu is {}",
            show(&menu)
        );
        Ok(())
    });
    steps.step(&format!("{Q} woke from a snooze"), |world, c, _| {
        project_thread_commands(world);
        let key = key_of(world, &c[0])?;
        let now = world.now();
        // A thread the window shows is visited the moment it wakes, so the
        // marker only stays on one the user is not looking at. desktop-qt
        // reads its row in-process before that visit; here the row crosses a
        // socket, so the window looks elsewhere first.
        if super::thread_menu::route_thread(world) == key {
            world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Home))?;
            world.wait_for_with(
                |w| super::thread_menu::route_thread(w) != key,
                |_| format!("the window to leave {key}"),
            )?;
        }
        let id = id_in(&key).to_owned();
        let row = world
            .mc
            .threads
            .entry(id.clone())
            .or_insert_with(|| json!({}));
        row["snoozedAt"] = json!(iso(now - Duration::hours(3)));
        row["snoozedUntil"] = json!(iso(now - Duration::hours(1)));
        row["lastVisitedAt"] = json!(iso(now - Duration::hours(4)));
        let row = row.clone();
        world.mc.send_row(&id, &row);
        world.wait_for_with(
            |w| row_of(w, &key).is_some_and(|r| word_of(&r) == "Woke"),
            |w| format!("the row to say Woke; it is {}", shown_row(w, &key)),
        )
    });
    steps.step("the user dismisses its woke marker", |world, _, _| {
        let active = sidebar(world)["active"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        for row in active {
            if word_of(&row) == "Woke" {
                return world.dispatch("thread.wokeDismiss", json!({"key": row["key"]}));
            }
        }
        fail!("no row is marked as woke")
    });
    steps.step(
        &format!("{Q} is no longer marked as woke"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            world.wait_for_with(
                |w| row_of(w, &key).is_some_and(|r| word_of(&r) != "Woke"),
                |w| format!("the woke marker to go; the row is {}", shown_row(w, &key)),
            )
        },
    );

    // Settling.
    steps.step(
        &format!("{Q} moves to the settled section"),
        |world, c, _| wait_for_section(world, &c[0], "settled"),
    );
    steps.step(&format!("{Q} is settled"), |world, c, _| {
        if world.checking {
            return wait_for_section(world, &c[0], "settled");
        }
        // Another thread began since, so un-settling has to lift it above one.
        let project = first_project(world);
        put_thread(
            world,
            "t-newer",
            json!({"projectId": project, "title": "Newer", "createdAt": "2026-09-23T09:30:00Z"}),
        )?;
        let key = key_of(world, &c[0])?;
        update_row(world, id_in(&key), |row| {
            row.insert("settledOverride".into(), json!("settled"));
            row.insert("settledAt".into(), json!("2026-09-23T09:40:00Z"));
        })?;
        wait_for_section(world, &c[0], "settled")
    });
    steps.step(
        &format!("{Q} returns to the top of the active threads"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            world.wait_for_with(
                |w| {
                    let state = sidebar(w);
                    let active = state["active"].as_array().cloned().unwrap_or_default();
                    active.len() > 1 && text(&active[0]["key"]) == key
                },
                |w| {
                    format!(
                        "{key} on top; the active threads are {}",
                        show(&sidebar(w)["active"])
                    )
                },
            )
        },
    );
    steps.step("the pull request is merged on GitHub", |world, _, _| {
        // The MC settles a thread whose pull request merged
        // (HalC2.Orchestration.Settlement).
        let id = world.mc.threads.keys().next().cloned().unwrap_or_default();
        let now = iso(world.now());
        update_row(world, &id, |row| {
            row.insert("settledOverride".into(), json!("settled"));
            row.insert("settledAt".into(), json!(now));
        })
    });
    steps.step(
        &format!("{Q} moves to the settled section without the user settling it"),
        |world, c, _| {
            wait_for_section(world, &c[0], "settled")?;
            for command in &world.mc.commands {
                expect!(
                    text(&command["type"]) != "thread.settle",
                    "the MC has {}",
                    world.describe_commands()
                );
            }
            Ok(())
        },
    );

    // The state a row names.
    steps.step(
        &format!("{Q} (has an agent working|has a queued turn waiting to start|is waiting for an approval|is waiting for an answer to a question|has hit a usage limit|stopped on a usage limit|had its last run fail|woke early from a snooze|finished work the user has not seen)"),
        |world, c, _| {
            let state = c[1].clone();
            let now = world.now();
            let key = key_of(world, &c[0])?;
            update_row(world, id_in(&key), |row| set_state(row, now, &state))?;
            // The conversation holds what the agent said when it stopped on
            // the limit.
            if state.contains("usage limit") {
                let environment = world.mc.environment_id.clone();
                let streams = world.mc.part::<FakeStreams>();
                streams.thread = id_in(&key).to_owned();
                streams.environment = environment;
                start_run(world, 900, "failed")?;
                add_item(
                    world,
                    "error",
                    json!({"status": "failed",
                           "failure": {"class": "usage_limit",
                                       "message": "You've hit your usage limit. It resets at 2:00 PM."}}),
                )?;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the row for {Q} reads \"([^\"·]*)\""),
        |world, c, _| {
            world.sync()?;
            let key = key_of(world, &c[0])?;
            let row = row_of(world, &key);
            let word = row.as_ref().map_or("", word_of);
            expect!(
                word == c[1],
                "the row reads \"{word}\": {}",
                shown_row(world, &key)
            );
            Ok(())
        },
    );

    // A window that crosses a width where the rows change height keeps the
    // open thread's row in the list's view.
    steps.step(
        &format!("the thread list is scrolled to {Q}"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            world.sync()?;
            let brick = thread_list(world)?;
            world.pump()?;
            let rows = list_rows(&brick, world);
            let index = rows.iter().position(|row| text(&row["rowKey"]) == key);
            let Some(index) = index else {
                fail!("the list has no row for {}", c[0]);
            };
            let list = brick.item(world, "list")?;
            expect!(
                index >= 4,
                "{} has too few rows above it to scroll past",
                c[0]
            );
            // As the user scrolls down to it: show the rows above first
            // (ListView.Beginning, 0), then scroll on.
            let first = text(&rows[index - 4]["rowKey"]);
            world
                .engine()
                .invoke_by_name(
                    list,
                    "positionViewAtIndex",
                    &[
                        ljos::prelude::Value::from(i32::try_from(index - 4).unwrap_or(0)),
                        ljos::prelude::Value::from(0),
                    ],
                )
                .map_err(|e| crate::harness::Failure(format!("positionViewAtIndex: {e:?}")))?;
            let first_key = first.clone();
            world.wait_for_with(
                |w| row_top(&brick, w, &first_key).is_ok_and(|top| top == 0.0),
                |_| format!("the rows above {} at the top of the list", c[0]),
            )?;
            let row = brick.find(world, &format!("threadRow:{key}"))?;
            expect!(
                row.is_some(),
                "the list draws {} below the rows above it",
                c[0]
            );
            let row = row.unwrap();
            let (_, row_y) = brick.at(world, row, 0.0, 0.0)?;
            let (_, list_y) = brick.at(world, list, 0.0, 0.0)?;
            let content_y = number(&brick, world, list, "contentY");
            brick.write(
                world,
                list,
                "contentY",
                ljos::prelude::Value::from(content_y + (row_y - list_y)),
            )?;
            let key2 = key.clone();
            let total = rows.len();
            world.wait_for_with(
                |w| row_top(&brick, w, &key2).is_ok_and(|top| top == 0.0),
                |_| format!("{} (row {index} of {total}) at the top of the list", c[0]),
            )?;
            expect!(
                brick.find(world, &format!("threadRow:{first}"))?.is_some(),
                "the list keeps the rows above {} drawn",
                c[0]
            );
            Ok(())
        },
    );
    steps.step(&format!("the thread list shows {Q}"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        world.sync()?;
        let brick = thread_list(world)?;
        world.wait_for_with(
            |w| row_top(&brick, w, &key).is_ok_and(|top| top >= 0.0),
            |w| {
                format!(
                    "{} in the list's view; the list is in {} mode",
                    c[0],
                    at(&w.state("layout"), "sidebarMode")
                )
            },
        )
    });

    // A thread's composer holding unsent text marks its row (but the open
    // one's).
    steps.step(
        &format!("the user typed a message in the composer of {Q} and did not send it"),
        |world, c, _| {
            let key = ensure_thread(world, &c[0], "")?;
            world.dispatch("thread.open", json!({"key": key}))?;
            let typed = "Half a thought";
            let revision = world.next_edit;
            world.next_edit += 1;
            world.dispatch(
                "composer.text.set",
                json!({
                    "target": key,
                    "edit": {"clientId": "qml", "revision": revision},
                    "text": typed,
                    "cursor": typed.len(),
                }),
            )?;
            world.sync()
        },
    );
    steps.step(&format!("{Q} is the open thread"), |world, c, _| {
        let key = ensure_thread(world, &c[0], "")?;
        world.dispatch("thread.open", json!({"key": key}))?;
        world.sync()
    });
    steps.step(
        &format!("the row for {Q} (says|no longer says) \"Unsent draft\""),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            let marked = c[1] == "says";
            world.wait_for_with(
                |w| row_of(w, &key).is_some_and(|row| row["unsentDraft"].as_bool() == Some(marked)),
                |w| {
                    format!(
                        "the row for {} is {}",
                        c[0],
                        show(&row_of(w, &key).unwrap_or(Value::Null))
                    )
                },
            )
        },
    );
    steps.step("the user discards the draft from the row", |world, _, _| {
        let mut marked = String::new();
        let state = sidebar(world);
        for section in ["pinned", "active", "snoozed", "settled"] {
            for row in at(&state, section).as_array().into_iter().flatten() {
                if row["unsentDraft"] == json!(true) {
                    marked = text(&row["key"]);
                }
            }
        }
        expect!(!marked.is_empty(), "no row is marked \"Unsent draft\"");
        world.dispatch("thread.draft.discard", json!({"key": marked}))?;
        world.sync()
    });
    steps.step(&format!("the composer of {Q} is empty"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        let preview = hal_c2_shell::controllers::drafts::preview(world.engine(), &key);
        expect!(
            preview.is_none(),
            "the composer of {} holds {}",
            c[0],
            preview.unwrap_or_default()
        );
        Ok(())
    });

    // The project filter this device remembers.
    steps.step(
        &format!("the user scoped the list to {Q}(?: before closing the app)?"),
        |world, c, _| {
            let key = world.project_key(&c[0]);
            {
                let memory = world.part::<ScopeMemory>();
                memory.name = c[0].clone();
                memory.key = key.clone();
            }
            world.dispatch("sidebar.scope", json!({"projectKey": key}))?;
            world.sync()
        },
    );
    steps.step(
        &format!("the list (?:is|is still|stays) scoped to {Q}"),
        |world, c, _| {
            let key = world.part::<ScopeMemory>().key.clone();
            expect!(!key.is_empty(), "the list was scoped to {}", c[0]);
            world.sync()?;
            world.wait_for_with(
                |w| text(&sidebar(w)["scopeProjectKey"]) == key,
                |w| {
                    format!(
                        "the list scoped to {key}; it is scoped to \"{}\"",
                        text(&sidebar(w)["scopeProjectKey"])
                    )
                },
            )
        },
    );
    steps.step(
        "the user opens settings and then returns to the threads",
        |world, _, _| {
            world.dispatch("settings.open", json!({}))?;
            world.sync()?;
            world.dispatch("settings.back", json!({}))?;
            world.sync()
        },
    );
    // The scoped project goes from this MC while it is closed, and the
    // member is listed but unreachable when the app starts.
    steps.step(
        &format!("the app starts and the environment {Q} has not reported its projects yet"),
        |world, c, _| {
            world.part::<ScopeMemory>().waiting = c[0].clone();
            world.restart()?;
            let name = world.part::<ScopeMemory>().name.clone();
            remove_project_titled(world, &name);
            world.mc.offline.insert(c[0].clone());
            world.mc.join_named(&c[0]);
            world.connect()?;
            world.wait_for("the shell to start", |w| w.active())
        },
    );
    steps.step(
        &format!("every environment has reported and {Q} is gone"),
        |world, c, _| {
            let waiting = world.part::<ScopeMemory>().waiting.clone();
            world.mc.set_online(&waiting, true);
            world.sync()?;
            expect!(
                c[0] == world.part::<ScopeMemory>().name,
                "{} was the remembered project",
                c[0]
            );
            Ok(())
        },
    );
    steps.step("the list shows every project", |world, _, _| {
        world.wait_for_with(
            |w| sidebar(w)["scopeProjectKey"].is_null(),
            |w| {
                format!(
                    "the list unscoped; it is scoped to \"{}\"",
                    text(&sidebar(w)["scopeProjectKey"])
                )
            },
        )
    });

    // A drop beside rows the offline member serves.
    steps.step(
        "the sidebar shows rows from a machine that is offline or asleep",
        |world, _, _| {
            project_thread_commands(world);
            let project = first_project(world);
            put_thread(
                world,
                &title_id("Here one"),
                json!({"projectId": project, "title": "Here one", "createdAt": AT}),
            )?;
            put_thread(
                world,
                &title_id("Here two"),
                json!({
                    "projectId": project, "title": "Here two",
                    "createdAt": "2026-09-23T09:05:00Z",
                }),
            )?;
            let deploy = "t-deploy";
            world.mc.send_peer_row(
                "work",
                deploy,
                &json!({
                    "id": deploy, "title": "Deploy", "projectId": project,
                    "createdAt": "2026-09-23T09:10:00Z",
                    "updatedAt": "2026-09-23T09:10:00Z",
                }),
            );
            world.mc.offline.insert("work".to_owned());
            world.mc.join_named("work");
            world.wait_for_with(
                |w| {
                    active_titles(w)
                        == vec![
                            "Deploy".to_owned(),
                            "Here two".to_owned(),
                            "Here one".to_owned(),
                        ]
                },
                |w| {
                    format!(
                        "Deploy, Here two, Here one; the active threads are {}",
                        active_titles(w).join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        "the user drops a thread among rows that have no order yet",
        |world, _, _| {
            world.part::<Reorder>().commands_before = world.mc.commands.len();
            let key = key_of(world, "Here one")?;
            let before = key_of(world, "Here two")?;
            world.dispatch(
                "thread.drop",
                json!({
                    "key": key,
                    "section": "active",
                    "beforeKey": before,
                }),
            )?;
            world.sync()
        },
    );
    steps.step("the thread lands where it was dropped", |world, _, _| {
        world.wait_for_with(
            |w| {
                active_titles(w)
                    == vec![
                        "Deploy".to_owned(),
                        "Here one".to_owned(),
                        "Here two".to_owned(),
                    ]
            },
            |w| {
                format!(
                    "Deploy, Here one, Here two; the active threads are {}",
                    active_titles(w).join(", ")
                )
            },
        )
    });
    steps.step(
        "rows that cannot store an order are not written",
        |world, _, _| {
            world.sync()?;
            let before = world.part::<Reorder>().commands_before;
            for index in before..world.mc.commands.len() {
                expect!(
                    world.mc.command_environments.get(index).map(String::as_str) != Some("work"),
                    "no command to the offline \"work\"; the MC has {}",
                    world.describe_commands()
                );
            }
            Ok(())
        },
    );

    // The row's two lines, title first (SidebarThreadRow.qml as the list
    // draws it with every project in scope).
    steps.step(
        &format!("the thread {Q} in {Q} works on the branch {Q}"),
        |world, c, _| {
            let mut item = json!({
                "title": c[0], "branch": c[2], "status": "ready",
                "updatedAt": "2026-09-23T09:00:00Z",
            });
            item["_project"] = json!(c[1]);
            world.part::<RowItem>().0 = item;
            Ok(())
        },
    );
    steps.step("the user looks at its row in the thread list", |world, _, _| {
        let item = world.part::<RowItem>().0.clone();
        let project = text(&item["_project"]);
        let js = |value: &Value| serde_json::to_string(value).unwrap_or_else(|_| "null".into());
        let mut bare = item.clone();
        if let Some(map) = bare.as_object_mut() {
            map.remove("_project");
        }
        let qml = format!(
            "import QtQuick\nimport HalC2.Bricks\nSidebarThreadRow {{ width: 256; active: false; projectInDetail: true; projectName: {}; item: ({}) }}\n",
            js(&json!(project)),
            js(&bare)
        );
        Brick::show(world, &qml, 256.0, 80.0)
    });
    steps.step(&format!("the row's first line reads {Q}"), |world, c, _| {
        let brick = world.part::<Shown>().0;
        let Some(brick) = brick else {
            fail!("no row is shown");
        };
        let title = brick.item(world, "cardTitle")?;
        let read = brick.text_of(world, title, "text");
        expect!(read == c[0], "the first line reads {read}");
        Ok(())
    });
    steps.step(&format!("its second line reads {Q}"), |world, c, _| {
        let brick = world.part::<Shown>().0;
        let Some(brick) = brick else {
            fail!("no row is shown");
        };
        let line = format!(
            "{} \u{b7} {}",
            brick.text_of(world, brick.item(world, "rowDetailProject")?, "text"),
            brick.text_of(world, brick.item(world, "rowDetailBranch")?, "text")
        );
        let (_, title_bottom) = brick.at(world, brick.item(world, "cardTitle")?, 0.5, 1.0)?;
        let detail_item = brick.item(world, "rowDetail")?;
        let (_, detail_top) = brick.at(world, detail_item, 0.5, 0.0)?;
        expect!(
            brick.flag(world, detail_item, "visible") && line == c[0] && detail_top >= title_bottom,
            "the second line reads {line}, {} px under the title",
            detail_top - title_bottom
        );
        Ok(())
    });
}
