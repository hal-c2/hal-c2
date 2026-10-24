//! Selecting several threads in the list and acting on all of them from the
//! selection's menu (threads/menu-and-selection.feature, and the bulk
//! scenarios of threads/archive-delete.feature, threads/snooze.feature,
//! threads/titles.feature and threads/unread-and-status.feature). The clicks
//! that select (Ctrl/Cmd and Shift) are SidebarThreadRow.qml's.
//! desktop-qt's ThreadSelectionSteps.cpp.

use chrono::{DateTime, Duration, TimeZone, Utc};
use regex::Regex;
use serde_json::{Map, Value, json};

use super::settings::save_elsewhere;
use super::stream::iso;
use super::thread_menu::{
    answer, id_in, item, items, key_of, pick, project_thread_commands, section_of, update_row,
};
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

const SECTIONS: [&str; 4] = ["pinned", "active", "snoozed", "settled"];
const THREE: [&str; 3] = ["One", "Two", "Three"];

#[derive(Default)]
struct Selection {
    /// The threads the scenario selected, by title.
    titles: Vec<String>,
    made: usize,
}

fn scene(world: &mut World) -> &mut Selection {
    world.mc.part::<Selection>()
}

/// What the MC was asked to remove (`vcs.removeWorktree`), and why it refuses.
#[derive(Default)]
struct Worktrees {
    removed: Vec<Value>,
    refusal: String,
}

fn extension(mc: &mut FakeMc) {
    mc.on_rpc("vcs.removeWorktree", |mc, rpc| {
        let refusal = mc.part::<Worktrees>().refusal.clone();
        if !refusal.is_empty() {
            mc.refuse(rpc, &refusal);
            return Ok(());
        }
        mc.part::<Worktrees>().removed.push(rpc.payload.clone());
        mc.reply(rpc, Value::Null);
        Ok(())
    });
}

fn sidebar(world: &World) -> Value {
    world.state("sidebar")
}

fn row_of(world: &World, key: &str) -> Option<Value> {
    let state = sidebar(world);
    SECTIONS
        .iter()
        .flat_map(|section| state[*section].as_array().into_iter().flatten())
        .find(|row| row["key"] == json!(key))
        .cloned()
}

/// The project the Background's thread is in.
fn project(world: &World) -> String {
    world
        .mc
        .threads
        .values()
        .next()
        .map_or_else(String::new, |row| text(&row["projectId"]))
}

fn exists(world: &World, title: &str) -> bool {
    world
        .mc
        .threads
        .values()
        .any(|row| row["title"] == json!(title))
}

/// Threads newer than the Background's, the first of `titles` on top.
fn add_threads(world: &mut World, titles: &[&str], fields: Value) -> Outcome {
    project_thread_commands(world);
    let project_id = project(world);
    for (index, title) in titles.iter().enumerate() {
        if exists(world, title) {
            continue;
        }
        let made = {
            let scene = scene(world);
            scene.made += 1;
            scene.made
        };
        let id = format!("t-sel-{made}");
        let at = iso(world.now() + Duration::seconds(60 * (titles.len() - index) as i64));
        let mut row = fields.clone();
        if !row.is_object() {
            row = json!({});
        }
        row["id"] = json!(id);
        row["title"] = json!(title);
        row["projectId"] = json!(project_id);
        row["createdAt"] = json!(at);
        row["updatedAt"] = json!(at);
        world.mc.threads.insert(id.clone(), row.clone());
        world.mc.send_row(&id, &row);
    }
    world.sync()
}

fn select(world: &mut World, titles: &[&str]) -> Outcome {
    world.dispatch("thread.select.clear", json!({}))?;
    for title in titles {
        let key = key_of(world, title)?;
        world.dispatch("thread.select.toggle", json!({"key": key}))?;
    }
    scene(world).titles = titles.iter().map(|t| (*t).to_owned()).collect();
    Ok(())
}

fn selected_titles(world: &World) -> Outcome<Vec<String>> {
    let mut titles = Vec::new();
    for key in sidebar(world)["selectedKeys"]
        .as_array()
        .into_iter()
        .flatten()
    {
        let key = text(key);
        let row = row_of(world, &key);
        // The row says so too: SidebarThreadRow.qml highlights it.
        expect!(
            row.as_ref().is_some_and(|r| r["selected"] == json!(true)),
            "the row of {key} is {}",
            show(&row.clone().unwrap_or(Value::Null))
        );
        titles.push(text(&row.unwrap_or(Value::Null)["title"]));
    }
    Ok(titles)
}

fn menu_items(world: &World) -> Vec<Value> {
    if world.state("menu").is_object() {
        items(world)
    } else {
        Vec::new()
    }
}

fn menu_is(world: &World) -> String {
    show(&Value::Array(menu_items(world)))
}

/// The menu of one of the selected threads, which is the selection's.
fn open_menu(world: &mut World, title: &str) -> Outcome {
    world.sync()?;
    let title = if title.is_empty() {
        scene(world).titles.first().cloned().unwrap_or_default()
    } else {
        title.to_owned()
    };
    let key = key_of(world, &title)?;
    world.dispatch("thread.menu", json!({"key": key, "x": 40, "y": 120}))?;
    expect!(!menu_items(world).is_empty(), "no menu opened");
    Ok(())
}

/// The selection's menu item `id` names `count` threads, as "Settle (2)".
fn expect_counted(world: &World, id: &str, count: usize) -> Outcome {
    let entry = item(world, id);
    expect!(
        entry
            .as_ref()
            .is_some_and(|e| e["enabled"] == json!(true)
                && text(&e["label"]).ends_with(&format!(" ({count})"))),
        "the menu is {}",
        menu_is(world)
    );
    Ok(())
}

fn gone(world: &World, title: &str) -> bool {
    if exists(world, title) {
        return false;
    }
    let state = sidebar(world);
    !SECTIONS.iter().any(|section| {
        state[*section]
            .as_array()
            .into_iter()
            .flatten()
            .any(|row| row["title"] == json!(title))
    })
}

fn pinned_row(row: &mut Map<String, Value>) {
    row.insert("pinnedAt".into(), json!("2026-09-23T09:30:00Z"));
    row.insert("pinOrderKey".into(), json!("a0"));
}

fn old_spike(row: &mut Map<String, Value>) {
    row.insert("branch".into(), json!("spike/old"));
    row.insert("worktreePath".into(), json!("/work/worktrees/old-spike"));
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // Selecting.
    steps.step(
        &format!("the threads {Q}, {Q}, {Q} and {Q} are listed in that order"),
        |world, c, _| {
            add_threads(world, &[&c[0], &c[1], &c[2], &c[3]], json!({}))?;
            let top: Vec<String> = sidebar(world)["active"]
                .as_array()
                .into_iter()
                .flatten()
                .take(4)
                .map(|row| text(&row["title"]))
                .collect();
            expect!(top == c[..4], "the list starts {}", top.join(", "));
            Ok(())
        },
    );
    steps.step(
        &format!("the user adds {Q} and then {Q} to the selection"),
        |world, c, _| {
            for title in [&c[0], &c[1]] {
                let key = key_of(world, title)?;
                world.dispatch("thread.select.toggle", json!({"key": key}))?;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the user selects {Q} and then extends the range to {Q}"),
        |world, c, _| {
            let first = key_of(world, &c[0])?;
            world.dispatch("thread.select.toggle", json!({"key": first}))?;
            let last = key_of(world, &c[1])?;
            world.dispatch("thread.select.range", json!({"key": last}))
        },
    );
    // A Given selects them (among "A" to "D"); a Then checks the selection.
    steps.step(
        "(\"[^\"]*\"(?:, \"[^\"]*\")* and \"[^\"]*\") are selected",
        |world, c, _| {
            let titles: Vec<String> = Regex::new(Q)
                .expect("a quoted name")
                .captures_iter(&c[0])
                .map(|m| m[1].to_owned())
                .collect();
            if !world.checking {
                add_threads(world, &["A", "B", "C", "D"], json!({}))?;
                let names: Vec<&str> = titles.iter().map(String::as_str).collect();
                select(world, &names)?;
            }
            let selected = selected_titles(world)?;
            expect!(
                selected == titles,
                "the selection is {}",
                selected.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} and {Q} are selected and only {Q} is pinned"),
        |world, c, _| {
            add_threads(world, &["A", "B", "C", "D"], json!({}))?;
            let key = key_of(world, &c[2])?;
            update_row(world, id_in(&key), pinned_row)?;
            select(world, &[&c[0], &c[1]])
        },
    );
    steps.step(
        &format!("{Q} and {Q} are selected and the agent is working in {Q}"),
        |world, c, _| {
            add_threads(world, &["A", "B", "C", "D"], json!({}))?;
            let key = key_of(world, &c[2])?;
            update_row(world, id_in(&key), |row| {
                row.insert("latestRunId".into(), json!("r1"));
                row.insert("activeRunId".into(), json!("r1"));
                row.insert("status".into(), json!("running"));
            })?;
            select(world, &[&c[0], &c[1]])
        },
    );
    steps.step("the user clears the selection", |world, _, _| {
        world.dispatch("thread.select.clear", json!({}))
    });
    steps.step(
        "the user scopes the list to another project",
        |world, _, _| {
            let current = project(world);
            let other = sidebar(world)["projects"]
                .as_array()
                .into_iter()
                .flatten()
                .rfind(|entry| text(&entry["projectId"]) != current)
                .map(|entry| text(&entry["key"]))
                .unwrap_or_default();
            expect!(!other.is_empty(), "there is no other project");
            world.dispatch("sidebar.scope", json!({"projectKey": other}))
        },
    );
    steps.step("no thread is selected", |world, _, _| {
        let selected = sidebar(world)["selectedKeys"]
            .as_array()
            .is_none_or(Vec::is_empty);
        expect!(
            selected,
            "the selection is {}",
            selected_titles(world)?.join(", ")
        );
        Ok(())
    });
    steps.step(&format!("{Q} stays selected"), |world, c, _| {
        world.sync()?;
        let selected = selected_titles(world)?;
        expect!(
            selected == [c[0].clone()],
            "the selection is {}",
            selected.join(", ")
        );
        Ok(())
    });

    // The selection's menu.
    steps.step(
        "the user opens the menu for the selection",
        |world, _, _| open_menu(world, ""),
    );
    steps.step("unpinning is offered for (\\d+) threads?", |world, c, _| {
        expect_counted(world, "unpin", c[0].parse().unwrap_or(0))
    });
    steps.step(
        "settling, snoozing, marking unread and deleting are offered for (\\d+) threads",
        |world, c, _| {
            for id in ["settle", "snooze", "mark-unread", "delete"] {
                expect_counted(world, id, c[0].parse().unwrap_or(0))?;
            }
            Ok(())
        },
    );
    steps.step("archiving the selection is unavailable", |world, _, _| {
        let archive = item(world, "archive");
        expect!(
            archive
                .as_ref()
                .is_some_and(|a| a["enabled"] != json!(true) && a["label"] == json!("Archive (2)")),
            "the menu is {}",
            menu_is(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the user chooses to (settle|snooze|delete) from the menu of {Q}"),
        |world, c, _| {
            open_menu(world, &c[1])?;
            if c[0] == "snooze" {
                let Some(snooze) = item(world, "snooze") else {
                    fail!("the menu is {}", menu_is(world));
                };
                let first = text(&snooze["children"][0]["id"]);
                return pick(world, &first);
            }
            pick(world, &c[0])?;
            if c[0] == "delete" {
                answer(world, true)?;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} and {Q} are (settled|snoozed|deleted)"),
        |world, c, _| {
            for title in [&c[0], &c[1]] {
                if c[2] == "deleted" {
                    world
                        .wait_for_with(|w| gone(w, title), |_| format!("{title} to be deleted"))?;
                    continue;
                }
                let key = key_of(world, title)?;
                world.wait_for_with(
                    |w| section_of(w, &key) == c[2],
                    |w| format!("{title} {}; it is in \"{}\"", c[2], section_of(w, &key)),
                )?;
            }
            Ok(())
        },
    );

    // Deleting.
    steps.step(&format!("deleting {Q} fails"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        world.mc.refusals.insert(
            format!("thread.delete:{}", id_in(&key)),
            "The thread is locked".into(),
        );
        Ok(())
    });
    steps.step("the user deletes the selection", |world, _, _| {
        open_menu(world, "")?;
        pick(world, "delete")?;
        // The question is the scenario's to answer when it asks about it.
        if scene(world).titles != THREE {
            answer(world, true)?;
        }
        Ok(())
    });
    steps.step(&format!("{Q} is deleted"), |world, c, _| {
        world.wait_for_with(|w| gone(w, &c[0]), |_| format!("{} to be deleted", c[0]))
    });
    steps.step(
        "all three threads are deleted after confirming",
        |world, _, _| {
            for title in THREE {
                expect!(
                    exists(world, title),
                    "{title} was deleted before the user confirmed"
                );
            }
            answer(world, true)?;
            for title in THREE {
                world.wait_for_with(|w| gone(w, title), |_| format!("{title} to be deleted"))?;
            }
            Ok(())
        },
    );

    // The worktree a deleted thread leaves behind.
    steps.step(
        &format!("{Q} is the only thread using its worktree"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            update_row(world, id_in(&key), old_spike)
        },
    );
    steps.step(
        &format!("the worktree of {Q} cannot be removed"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            update_row(world, id_in(&key), old_spike)?;
            world.mc.part::<Worktrees>().refusal = "The worktree has uncommitted changes".into();
            Ok(())
        },
    );
    steps.step(
        "the user chose to always remove orphaned worktrees",
        |world, _, _| {
            save_elsewhere(
                &mut world.mc,
                "storageCleanup",
                json!({"worktreeOnDelete": true}),
                false,
            );
            world.sync()
        },
    );
    steps.step(
        "the user is asked whether to delete the worktree too",
        |world, _, _| {
            world.sync()?;
            let question = world.state("confirmation");
            expect!(
                question["title"] == json!("Delete the worktree too?")
                    && text(&question["description"]).ends_with("old-spike"),
                "the question is {}",
                show(&question)
            );
            // Nothing is deleted before the answer.
            let removed = world.mc.part::<Worktrees>().removed.is_empty();
            expect!(
                world.mc.commands.is_empty() && removed,
                "the MC has {}",
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step(
        "the thread and its worktree are deleted without a question",
        |world, _, _| {
            world.wait_for("the worktree to be removed", |w| {
                w.mc.peek::<Worktrees>()
                    .is_some_and(|f| !f.removed.is_empty())
            })?;
            let removed = world.mc.part::<Worktrees>().removed[0].clone();
            expect!(
                removed["path"] == json!("/work/worktrees/old-spike")
                    && removed["cwd"] == json!("/work/shop")
                    && removed["force"] == json!(true),
                "the MC was asked {}",
                show(&removed)
            );
            expect!(
                gone(world, "Old spike") && !world.state("confirmation").is_object(),
                "the question is {}",
                show(&world.state("confirmation"))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user deletes {Q} and its worktree"),
        |world, c, _| {
            open_menu(world, &c[0])?;
            pick(world, "delete")?;
            answer(world, true)?; // delete the thread
            answer(world, true) // and its worktree
        },
    );
    steps.step("opening another thread fails", |world, _, _| {
        // Nothing else to show, and the desktop cannot keep the new thread it would start.
        let drafts = world.home_dir().join("data/shell-drafts.json");
        let _ = std::fs::remove_file(&drafts);
        expect!(
            std::fs::create_dir_all(&drafts).is_ok(),
            "could not block {}",
            drafts.display()
        );
        Ok(())
    });

    // Three threads, selected.
    steps.step("the user has selected three threads", |world, _, _| {
        add_threads(world, &THREE, json!({}))?;
        select(world, &THREE)
    });
    steps.step(
        "the user has selected three threads and one cannot be snoozed",
        |world, _, _| {
            add_threads(world, &THREE, json!({}))?;
            select(world, &THREE)?;
            let key = key_of(world, THREE[2])?;
            world.mc.refusals.insert(
                format!("thread.snooze:{}", id_in(&key)),
                "The thread has a queued run".into(),
            );
            Ok(())
        },
    );
    steps.step(
        "the user has selected three threads, one of which is already regenerating",
        |world, _, _| {
            add_threads(world, &THREE, json!({}))?;
            let key = key_of(world, THREE[2])?;
            update_row(world, id_in(&key), |row| {
                row.insert(
                    "titleRegeneration".into(),
                    json!({"requestId": "c1", "startedAt": "2026-09-23T09:59:00Z"}),
                );
            })?;
            select(world, &THREE)
        },
    );
    steps.step("the user has selected three read threads", |world, _, _| {
        let completed = iso(world.now() - Duration::seconds(600));
        let visited = iso(world.now() - Duration::seconds(300));
        add_threads(
            world,
            &THREE,
            json!({"latestRunId": "r1", "status": "completed",
                   "latestRunCompletedAt": completed, "lastVisitedAt": visited}),
        )?;
        select(world, &THREE)?;
        for title in THREE {
            let key = key_of(world, title)?;
            let unread = row_of(world, &key).is_some_and(|row| row["unread"] == json!(true));
            expect!(!unread, "{title} is unread");
        }
        Ok(())
    });

    // Snoozing, titles, unread.
    steps.step(
        "the user snoozes the selection until tomorrow",
        |world, _, _| {
            open_menu(world, "")?;
            let snooze = item(world, "snooze");
            expect!(
                snooze.is_some_and(|s| s["label"] == json!("Snooze (3)")),
                "the menu is {}",
                menu_is(world)
            );
            pick(world, "snooze:tomorrow")
        },
    );
    steps.step(
        "all three threads are snoozed until Thursday at 09:00",
        |world, _, _| {
            let thursday = Utc
                .with_ymd_and_hms(2026, 9, 24, 9, 0, 0)
                .single()
                .map(|t| t.timestamp_millis());
            for title in THREE {
                let key = key_of(world, title)?;
                let snoozed = |w: &World| {
                    row_of(w, &key).is_some_and(|row| {
                        section_of(w, &key) == "snoozed"
                            && DateTime::parse_from_rfc3339(&text(&row["snoozedUntil"]))
                                .ok()
                                .map(|t| t.timestamp_millis())
                                == thursday
                    })
                };
                world.wait_for_with(snoozed, |w| {
                    format!(
                        "{title} snoozed until Thursday; its row is {}",
                        show(&row_of(w, &key).unwrap_or(Value::Null))
                    )
                })?;
            }
            Ok(())
        },
    );
    steps.step("two threads are snoozed", |world, _, _| {
        world.wait_for_with(
            |w| sidebar(w)["snoozed"].as_array().map(Vec::len) == Some(2),
            |w| {
                format!(
                    "two snoozed threads; the list is {}",
                    show(&sidebar(w)["snoozed"])
                )
            },
        )?;
        world.sync()?;
        let key = key_of(world, THREE[2])?;
        expect!(
            section_of(world, &key) == "active",
            "the refused thread is not active"
        );
        Ok(())
    });
    steps.step(
        "the user regenerates titles for the selection",
        |world, _, _| {
            open_menu(world, "")?;
            let regenerate = item(world, "regenerate-title");
            expect!(
                regenerate.is_some_and(|r| r["label"] == json!("Regenerate titles (2)")),
                "the menu is {}",
                menu_is(world)
            );
            pick(world, "regenerate-title")
        },
    );
    steps.step(
        "titles are regenerated for the two eligible threads",
        |world, _, _| {
            world.sync()?;
            let mut asked: Vec<String> = world
                .mc
                .commands
                .iter()
                .filter(|command| {
                    command["type"] == json!("thread.metadata.update")
                        && command["regenerateTitle"] == json!(true)
                })
                .map(|command| text(&command["threadId"]))
                .collect();
            asked.sort();
            let mut eligible = Vec::new();
            for title in &THREE[..2] {
                eligible.push(id_in(&key_of(world, title)?).to_owned());
            }
            eligible.sort();
            expect!(
                asked == eligible,
                "the MC has {}",
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step("the user marks the selection unread", |world, _, _| {
        open_menu(world, "")?;
        expect_counted(world, "mark-unread", 3)?;
        pick(world, "mark-unread")
    });
    steps.step("all three threads are unread", |world, _, _| {
        for title in THREE {
            let key = key_of(world, title)?;
            let row_shown = |w: &World| row_of(w, &key).unwrap_or(Value::Null);
            world.wait_for_with(
                |w| row_shown(w)["unread"] == json!(true),
                |w| format!("{title} to be unread; its row is {}", show(&row_shown(w))),
            )?;
        }
        Ok(())
    });
}
