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
use serde_json::{Map, Value, json};

use super::settings_rows::turn_row;
use super::stream::{FakeStreams, add_item, iso, start_run};
use super::thread_menu::{id_in, key_of, project_thread_commands, section_of, update_row};
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
    ["pinned", "active", "snoozed", "settled"]
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
        |w| format!("{thread} in {section}; it is in \"{}\"", section_of(w, &key)),
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
        // TODO(port): PlannerSteps' openPlannerView, a view of the planner
        // plugin when the MC runs it (steps/planner.rs is not ported yet).
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
    steps.step("the settled section counts (\\d+) threads", |world, c, _| {
        // What its header counts (tst_Sidebar.qml).
        let total = sidebar(world)["settledTotal"].as_i64().unwrap_or(0);
        expect!(
            total.to_string() == c[0],
            "the settled section counts {total} threads"
        );
        Ok(())
    });
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
    steps.step(&format!("{Q} is among the settled threads"), |world, c, _| {
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
    });
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
            let time = NaiveTime::from_hms_opt(
                c[1].parse().unwrap_or(0),
                c[2].parse().unwrap_or(0),
                0,
            )
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
            world.dispatch(
                "thread.snoozeMenu",
                json!({"key": key, "x": 200, "y": 120}),
            )
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
        // Sent without a round trip: a thread the window shows is visited
        // the moment it wakes, and the row is read before the MC says so.
        let id = id_in(&key).to_owned();
        let row = world.mc.threads.entry(id.clone()).or_insert_with(|| json!({}));
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
    steps.step(&format!("{Q} is no longer marked as woke"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        world.wait_for_with(
            |w| row_of(w, &key).is_some_and(|r| word_of(&r) != "Woke"),
            |w| {
                format!(
                    "the woke marker to go; the row is {}",
                    shown_row(w, &key)
                )
            },
        )
    });

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
    steps.step(&format!("the row for {Q} reads {Q}"), |world, c, _| {
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
    });
}
