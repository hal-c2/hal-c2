//! What a settled thread says when it is open, un-settling it from there,
//! settling dismissing the agent's background questions, and turning a
//! thread's auto-settle off and on from its menu
//! (features/threads/settle.feature). The fake MC's rows follow the
//! commands (thread_menu's projection). desktop-qt's ThreadSettleSteps.cpp.

use serde_json::{Value, json};

use super::thread_menu::{id_in, key_of, section_of, update_row};
use crate::expect;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;

fn notice(world: &World) -> Value {
    world.state("threadNotice")
}

fn row_of(world: &World, key: &str) -> Option<Value> {
    let state = world.state("sidebar");
    for section in ["pinned", "active", "working", "snoozed", "settled"] {
        for row in at(&state, section).as_array().into_iter().flatten() {
            if text(&row["key"]) == key {
                return Some(row.clone());
            }
        }
    }
    None
}

fn open(world: &mut World, key: &str) -> Outcome {
    world.dispatch("thread.open", json!({"key": key}))?;
    world.sync()
}

fn settle(world: &mut World, key: &str) -> Outcome {
    update_row(world, id_in(key), |row| {
        row.insert("settledOverride".into(), json!("settled"));
        row.insert("settledAt".into(), json!("2026-09-23T09:40:00Z"));
    })
}

fn wait_for_notice(world: &mut World, key: &str) -> Outcome {
    world.wait_for_with(
        |w| text(&notice(w)["threadKey"]) == key,
        |w| {
            format!(
                "the open thread to say it is settled; it says {}",
                show(&notice(w))
            )
        },
    )
}

/// The thread menu's auto-settle choice for `key`: "enabled" or "disabled".
fn auto_settle_checked(world: &mut World, key: &str) -> Outcome<String> {
    world.sync()?;
    world.dispatch("thread.menu", json!({"key": key, "x": 40, "y": 120}))?;
    let menu = world.state("menu");
    let mut checked = String::new();
    for item in at(&menu, "items").as_array().into_iter().flatten() {
        if text(&item["id"]) != "auto-settle" {
            continue;
        }
        for child in item["children"].as_array().into_iter().flatten() {
            if child["checked"] == json!(true) {
                checked = text(&child["id"])[12..].to_owned();
            }
        }
    }
    world.dispatch(
        "menu.select",
        json!({"requestId": menu["requestId"], "id": Value::Null}),
    )?;
    expect!(
        !checked.is_empty(),
        "the thread menu has no auto-settle choice: {}",
        show(&menu)
    );
    Ok(checked)
}

fn turn_auto_settle(world: &mut World, key: &str, on: bool) -> Outcome {
    world.sync()?;
    world.dispatch("thread.menu", json!({"key": key, "x": 40, "y": 120}))?;
    let menu = world.state("menu");
    expect!(menu.is_object(), "no menu is open");
    world.dispatch(
        "menu.select",
        json!({
            "requestId": menu["requestId"],
            "id": if on { "auto-settle:enabled" } else { "auto-settle:disabled" },
        }),
    )?;
    world.sync()
}

/// Whether the MC's row says auto-settle is off, once the shell has it.
fn auto_settle_is(world: &mut World, key: &str, on: bool) -> Outcome {
    world.wait_for_with(
        |w| {
            w.mc.threads
                .get(id_in(key))
                .is_some_and(|row| row.get("autoSettleDisabledAt").is_some())
                != on
        },
        |w| {
            format!(
                "the MC's row to have auto-settle {}: {}",
                if on { "on" } else { "off" },
                show(w.mc.threads.get(id_in(key)).unwrap_or(&Value::Null))
            )
        },
    )?;
    let checked = auto_settle_checked(world, key)?;
    expect!(
        checked == if on { "enabled" } else { "disabled" },
        "the thread menu has auto-settle {checked}"
    );
    Ok(())
}

/// theme.rs's "the user chooses …", when the choice is the open thread's
/// notice action (Un-settle).
pub fn thread_notice_chooses(world: &mut World, choice: &str) -> Outcome<bool> {
    let now = notice(world);
    if now.is_null() || text(&now["actionLabel"]) != choice {
        return Ok(false);
    }
    world.dispatch("threadNotice.unsettle", json!({}))?;
    world.sync()?;
    Ok(true)
}

pub fn register(steps: &mut Steps) {
    // The open thread's notice ("the user opens" is thread_list's).
    steps.step(
        &format!("the user has opened {Q}, which is settled"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            settle(world, &key)?;
            open(world, &key)?;
            wait_for_notice(world, &key)
        },
    );
    steps.step(
        &format!("the thread says {Q} and that sending a message un-settles it"),
        |world, c, _| {
            let key = text(&world.state("route")["threadKey"]);
            wait_for_notice(world, &key)?;
            let now = notice(world);
            expect!(
                text(&now["title"]) == c[0]
                    && text(&now["description"]) == "Send a message to unsettle"
                    && text(&now["actionLabel"]) == "Un-settle",
                "the thread says {}",
                show(&now)
            );
            Ok(())
        },
    );
    steps.step("the environment rejects the un-settle", |world, _, _| {
        world.mc.refusals.insert(
            "thread.unsettle".into(),
            "The thread cannot be un-settled".into(),
        );
        Ok(())
    });
    steps.step(&format!("{Q} stays settled"), |world, c, _| {
        world.sync()?;
        let key = key_of(world, &c[0])?;
        let section = section_of(world, &key);
        expect!(section == "settled", "{} is in \"{section}\"", c[0]);
        let now = notice(world);
        expect!(
            text(&now["threadKey"]) == key && text(&now["actionLabel"]) == "Un-settle",
            "the thread says {}",
            show(&now)
        );
        Ok(())
    });

    // A thread that woke, then was settled.
    steps.step(
        &format!("{Q} woke from a snooze and was then settled"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            // Another thread is open, so the woke one is not visited yet.
            let mut other = world
                .mc
                .threads
                .get(id_in(&key))
                .cloned()
                .unwrap_or(json!({}));
            other["id"] = json!("t-other");
            other["title"] = json!("Other work");
            world.mc.threads.insert("t-other".to_owned(), other.clone());
            world.mc.send_row("t-other", &other);
            world.sync()?;
            let other_key = format!("{}:t-other", world.mc.environment_id);
            open(world, &other_key)?;
            update_row(world, id_in(&key), |row| {
                row.insert("snoozedAt".into(), json!("2026-09-23T07:00:00Z"));
                row.insert("snoozedUntil".into(), json!("2026-09-23T09:00:00Z"));
                row.insert("lastVisitedAt".into(), json!("2026-09-23T06:00:00Z"));
                row.insert("settledOverride".into(), json!("settled"));
                row.insert("settledAt".into(), json!("2026-09-23T09:40:00Z"));
            })
        },
    );
    steps.step("the thread says it is settled", |world, _, _| {
        let key = text(&world.state("route")["threadKey"]);
        wait_for_notice(world, &key)?;
        let now = notice(world);
        expect!(
            text(&now["kind"]) == "settled" && text(&now["title"]) == "This thread is settled",
            "the thread says {}",
            show(&now)
        );
        Ok(())
    });
    steps.step("it does not say it woke from a snooze", |world, _, _| {
        let now = notice(world);
        for field in ["title", "description", "actionLabel"] {
            let said = text(&now[field]).to_lowercase();
            expect!(
                !said.contains("woke") && !said.contains("wake"),
                "the thread says {}",
                show(&now)
            );
        }
        Ok(())
    });

    // Questions the agent is waiting on.
    steps.step(
        &format!("the agent in {Q} asked a question in the background"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            update_row(world, id_in(&key), |row| {
                row.insert("latestRunId".into(), json!("r1"));
                row.insert("status".into(), json!("completed"));
                row.insert(
                    "pendingRuntimeRequest".into(),
                    json!({
                        "id": "q1", "kind": "user_input",
                        "createdAt": "2026-09-23T09:50:00Z",
                    }),
                );
            })?;
            let row = row_of(world, &key);
            expect!(
                row.as_ref().is_some_and(|r| text(&r["status"]) == "input"),
                "the row is {}",
                show(&row.unwrap_or(Value::Null))
            );
            Ok(())
        },
    );
    steps.step("the question is dismissed", |world, _, _| {
        let key = key_of(world, "Ship checkout")?;
        world.wait_for_with(
            |w| {
                row_of(w, &key).is_some_and(|row| {
                    section_of(w, &key) == "settled" && text(&row["status"]) != "input"
                })
            },
            |w| {
                format!(
                    "the question to go; the row is {}",
                    show(&row_of(w, &key).unwrap_or(Value::Null))
                )
            },
        )
    });

    // A thread's auto-settle.
    steps.step(
        &format!("the user turns auto-settle (off|on) for {Q}"),
        |world, c, _| {
            let key = key_of(world, &c[1])?;
            turn_auto_settle(world, &key, c[0] == "on")
        },
    );
    steps.step(&format!("{Q} has auto-settle turned off"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        turn_auto_settle(world, &key, false)?;
        auto_settle_is(world, &key, false)
    });
    steps.step(
        &format!("{Q} stays out of automatic settling"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            auto_settle_is(world, &key, false)
        },
    );
    steps.step(
        &format!("{Q} settles automatically again after a quiet spell"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            auto_settle_is(world, &key, true)
        },
    );
}
