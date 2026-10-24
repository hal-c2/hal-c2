//! A thread whose agent stopped on a usage limit
//! (threads/limited-threads.feature): what its conversation keeps, and
//! waiting for the reset from the banner (LimitRecovery). The MC arms the
//! recovery (`thread.metadata.update` with `limitRecovery`), snoozes the
//! thread until the reset when asked, and resumes it then: the fake's rows
//! follow as HalC2.Orchestration does. desktop-qt's ThreadLimitSteps.cpp.

use std::rc::Rc;

use chrono::{DateTime, Duration, TimeZone, Utc};
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::sidebar::Sidebar;
use serde_json::{Value, json};

use super::settings::save_elsewhere;
use super::stream::{iso, timeline_object};
use super::thread_menu::{id_in, key_of, project_thread_commands, section_of, update_row};
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::stream::{describe, role, row_count};
use crate::world::World;
use crate::{expect, fail};

#[derive(Default)]
struct Limits {
    /// The MC arms the recovery itself (the user's settings say so).
    automatic: bool,
    reset_at: String,
}

fn extension(mc: &mut FakeMc) {
    mc.effects.push(Rc::new(|mc: &mut FakeMc, command: &Value| {
        if command["type"] != "thread.metadata.update" || command.get("limitRecovery").is_none() {
            return;
        }
        let id = text(&command["threadId"]);
        let Some(mut row) = mc.threads.get(&id).cloned() else {
            return;
        };
        let update = command["limitRecovery"].clone();
        let previous = row["limitRecovery"].clone();
        let same = previous["runId"] == update["runId"] && previous["resetAt"] == update["resetAt"];
        // A choice the update leaves out keeps the one made for the same run and reset.
        let choice = |key: &str| match update[key].as_bool() {
            Some(chosen) => chosen,
            None => same && previous[key].as_bool() == Some(true),
        };
        let mut recovery = update.clone();
        recovery["autoResume"] = json!(choice("autoResume"));
        recovery["snooze"] = json!(choice("snooze"));
        if recovery["snooze"] == json!(true) {
            row["snoozedUntil"] = recovery["resetAt"].clone();
            row["snoozedAt"] = json!("2026-09-23T10:00:00Z");
        } else if previous["snooze"] == json!(true)
            && let Some(fields) = row.as_object_mut()
        {
            fields.remove("snoozedUntil");
            fields.remove("snoozedAt");
        }
        row["limitRecovery"] = recovery;
        mc.threads.insert(id.clone(), row.clone());
        mc.send_row(&id, &row);
    }));
}

fn today(world: &World, hour: u32, minute: u32) -> DateTime<Utc> {
    let day = world.now().date_naive();
    Utc.from_utc_datetime(&day.and_hms_opt(hour, minute, 0).unwrap_or_default())
}

/// The row of a thread whose latest run stopped on the limit five minutes ago.
fn stop(world: &mut World, title: &str, reset_at: &str) -> Outcome {
    let automatic = {
        let limits = world.mc.part::<Limits>();
        limits.reset_at = reset_at.to_owned();
        limits.automatic
    };
    let key = key_of(world, title)?;
    let (started, stopped) = (
        iso(world.now() - Duration::seconds(900)),
        iso(world.now() - Duration::seconds(300)),
    );
    let reset_at = reset_at.to_owned();
    update_row(world, id_in(&key), move |row| {
        row.insert("latestRunId".into(), json!("r1"));
        row.insert("status".into(), json!("failed"));
        row.insert("lastErrorClass".into(), json!("usage_limit"));
        row.insert("latestRunStartedAt".into(), json!(started));
        row.insert("latestRunCompletedAt".into(), json!(stopped));
        row.insert("updatedAt".into(), json!(stopped));
        if reset_at.is_empty() {
            row.remove("usageLimitResetAt");
        } else {
            row.insert("usageLimitResetAt".into(), json!(reset_at));
        }
        if automatic && !reset_at.is_empty() {
            row.insert(
                "limitRecovery".into(),
                json!({"runId": "r1", "resetAt": reset_at, "autoResume": true, "snooze": true}),
            );
            row.insert("snoozedUntil".into(), json!(reset_at));
            row.insert("snoozedAt".into(), json!(stopped));
        }
    })
}

fn view(world: &mut World, title: &str) -> Outcome {
    let key = key_of(world, title)?;
    let route = Route::Thread(key.clone());
    world.with::<Navigation, _>(|navigation, engine| navigation.open(engine, route))?;
    world.wait_for_with(
        |w| text(&w.state("limitRecovery")["threadKey"]) == key,
        |w| {
            format!(
                "the limit banner of {title}; it is {}",
                show(&w.state("limitRecovery"))
            )
        },
    )
}

fn banner(world: &World) -> Value {
    world.state("limitRecovery")
}

fn wait_section(world: &mut World, title: &str, section: &str) -> Outcome {
    let key = key_of(world, title)?;
    world.wait_for_with(
        |w| section_of(w, &key) == section,
        |w| format!("{title} in {section}; it is in \"{}\"", section_of(w, &key)),
    )
}

fn messages_sent(world: &World) -> usize {
    world
        .mc
        .commands
        .iter()
        .filter(|command| command["type"] == json!("message.dispatch"))
        .count()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    steps.step(
        "the conversation says the thread stopped on a usage limit",
        |world, _, _| {
            let limited = |w: &World| {
                timeline_object(w).is_ok()
                    && (0..row_count(w).unwrap_or(0)).any(|row| {
                        role(w, row, "kind") == json!("error")
                            && text(&role(w, row, "title")).starts_with("Usage limit reached")
                            && role(w, row, "warning") == json!(true)
                    })
            };
            world.wait_for_with(limited, |w| {
                format!(
                    "the usage limit line; {}",
                    if timeline_object(w).is_ok() {
                        describe(w)
                    } else {
                        "no thread is open".into()
                    }
                )
            })
        },
    );

    steps.step(
        &format!("(?:{Q}|Claude) (?:stopped|stops) (?:{Q} )?on a usage limit that resets at (\\d+):(\\d+)"),
        |world, c, _| {
            let title = if c[0].is_empty() { &c[1] } else { &c[0] };
            project_thread_commands(world);
            let reset = iso(today(
                world,
                c[2].parse().unwrap_or(0),
                c[3].parse().unwrap_or(0),
            ));
            stop(world, title, &reset)
        },
    );
    steps.step(
        &format!("the agent stopped {Q} on a limit without saying when it resets"),
        |world, c, _| {
            project_thread_commands(world);
            stop(world, &c[0], "")
        },
    );
    steps.step(
        &format!("the user snoozes {Q} until the reset"),
        |world, c, _| {
            view(world, &c[0])?;
            let banner = banner(world);
            expect!(
                banner["canSchedule"] == json!(true) && banner["canSnooze"] == json!(true),
                "the banner is {}",
                show(&banner)
            );
            world.dispatch("limitRecovery.snooze", json!({}))
        },
    );
    steps.step(
        &format!("{Q} is snoozed until (\\d+):(\\d+)"),
        |world, c, _| {
            wait_section(world, &c[0], "snoozed")?;
            let key = key_of(world, &c[0])?;
            let until = text(&world.mc.threads[id_in(&key)]["snoozedUntil"]);
            let expected = iso(today(
                world,
                c[1].parse().unwrap_or(0),
                c[2].parse().unwrap_or(0),
            ));
            expect!(until == expected, "the thread is snoozed until {until}");
            Ok(())
        },
    );
    steps.step("it wakes without sending a message", |world, _, _| {
        let id = world.mc.threads.keys().next().cloned().unwrap_or_default();
        let key = format!("{}:{id}", world.mc.environment_id);
        let reset = world.mc.part::<Limits>().reset_at.clone();
        let Ok(reset) = DateTime::parse_from_rfc3339(&reset) else {
            fail!("the reset time {reset} is not a time");
        };
        world.set_time(reset.with_timezone(&Utc) + Duration::seconds(1));
        world.with::<Sidebar, _>(|sidebar, engine| sidebar.refresh(engine))?;
        expect!(
            section_of(world, &key) == "active",
            "the thread is in \"{}\"",
            section_of(world, &key)
        );
        world.sync()?;
        let resumes = world
            .mc
            .threads
            .values()
            .next()
            .is_some_and(|row| row["limitRecovery"]["autoResume"] == json!(true));
        expect!(
            messages_sent(world) == 0 && !resumes,
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });

    steps.step(
        "the user turned on auto-resume and snoozing for limited threads",
        |world, _, _| {
            save_elsewhere(&mut world.mc, "autoResumeLimitedThreads", json!(true), false);
            save_elsewhere(&mut world.mc, "snoozeLimitedThreads", json!(true), false);
            world.mc.part::<Limits>().automatic = true;
            world.sync()
        },
    );
    steps.step(
        &format!("at (\\d+):(\\d+) {Q} wakes and continues"),
        |world, c, _| {
            // Until then it is shelved, and its banner says it continues on its own.
            wait_section(world, &c[2], "snoozed")?;
            view(world, &c[2])?;
            let shelved = banner(world);
            expect!(
                shelved["scheduled"] == json!(true) && shelved["snoozed"] == json!(true),
                "the banner is {}",
                show(&shelved)
            );
            // At the reset the MC resumes the thread.
            world.set_time(
                today(world, c[0].parse().unwrap_or(0), c[1].parse().unwrap_or(0))
                    + Duration::seconds(1),
            );
            let now = iso(world.now());
            let key = key_of(world, &c[2])?;
            update_row(world, id_in(&key), move |row| {
                row.insert("latestRunId".into(), json!("r2"));
                row.insert("activeRunId".into(), json!("r2"));
                row.insert("status".into(), json!("running"));
                row.insert("latestRunStartedAt".into(), json!(now));
                row.insert("updatedAt".into(), json!(now));
                for key in [
                    "latestRunCompletedAt",
                    "lastErrorClass",
                    "usageLimitResetAt",
                    "limitRecovery",
                    "snoozedUntil",
                    "snoozedAt",
                ] {
                    row.remove(key);
                }
            })?;
            wait_section(world, &c[2], "active")?;
            let sidebar = world.state("sidebar");
            for row in sidebar["active"].as_array().into_iter().flatten() {
                if row["key"] == json!(key) {
                    expect!(row["status"] == json!("working"), "the row is {}", show(row));
                }
            }
            let banner = banner(world);
            expect!(
                !banner.is_object() && messages_sent(world) == 0,
                "the banner is {}",
                show(&banner)
            );
            Ok(())
        },
    );

    steps.step(
        &format!("{Q} is snoozed until its limit resets"),
        |world, c, _| {
            project_thread_commands(world);
            world.mc.part::<Limits>().automatic = true;
            let reset = iso(today(world, 14, 0));
            stop(world, &c[0], &reset)?;
            wait_section(world, &c[0], "snoozed")
        },
    );
    steps.step(&format!("the user wakes {Q} now"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        world.dispatch("thread.unsnooze", json!({"key": key}))
    });
    steps.step(&format!("{Q} is active again"), |world, c, _| {
        wait_section(world, &c[0], "active")?;
        // The recovery's own snooze is ended there, so the MC does not snooze it again.
        let key = key_of(world, &c[0])?;
        let recovery = world.mc.threads[id_in(&key)]["limitRecovery"].clone();
        expect!(
            recovery["snooze"] != json!(true) && recovery["autoResume"] == json!(true),
            "the recovery is {}",
            show(&recovery)
        );
        Ok(())
    });

    steps.step(
        "the user can retry by hand or snooze with the usual choices",
        |world, _, _| {
            let key = text(&world.state("route")["threadKey"]);
            world.wait_for("the limit banner", |w| {
                text(&banner(w)["threadKey"]) == key
            })?;
            let shown = banner(world);
            expect!(
                shown["description"] == json!("Reset time unavailable; retry manually")
                    && shown["canSchedule"] != json!(true),
                "the banner is {}",
                show(&shown)
            );
            // The usual snooze choices.
            world.dispatch(
                "thread.snoozeMenu",
                json!({"key": key, "x": 200, "y": 120}),
            )?;
            let menu = world.state("menu");
            let choices: Vec<String> = at(&menu, "items")
                .as_array()
                .into_iter()
                .flatten()
                .map(|item| text(&item["id"]))
                .collect();
            expect!(
                ["snooze:hour", "snooze:tomorrow", "snooze:custom"]
                    .iter()
                    .all(|id| choices.iter().any(|c| c == id)),
                "the snooze choices are {}",
                choices.join(", ")
            );
            world.dispatch(
                "menu.select",
                json!({"requestId": at(&menu, "requestId"), "id": Value::Null}),
            )?;
            // Retrying is sending again.
            let revision = world.next_edit;
            world.next_edit += 1;
            world.dispatch(
                "composer.submit",
                json!({"edit": {"clientId": "qml", "revision": revision},
                       "text": "Try again", "intent": "foreground"}),
            )?;
            world.sync()?;
            expect!(
                messages_sent(world) == 1,
                "the MC has {}",
                world.describe_commands()
            );
            Ok(())
        },
    );
}
