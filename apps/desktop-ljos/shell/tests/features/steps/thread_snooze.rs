//! Snoozing from the thread's menu and the list, what a row says of its wake
//! time, and waking early (features/threads/snooze.feature), plus what the
//! list says of a thread's state and order (threads/unread-and-status,
//! threads/settle, threads/pinning-and-order): desktop-qt's
//! ThreadSnoozeSteps.cpp.

use chrono::{DateTime, Datelike, Duration, NaiveTime, SecondsFormat, TimeZone, Utc};
use serde_json::{Map, Value, json};

use super::thread_menu::{id_in, key_of, pick, route_thread, section_of, set_device, update_row};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

#[derive(Default)]
struct ThreadScene {
    /// The thread the scenario's last step was about ("it").
    subject: String,
    /// The active threads' titles before the scenario's change.
    order_before: Vec<String>,
}

fn scene(world: &mut World) -> &mut ThreadScene {
    world.part::<ThreadScene>()
}

fn iso(time: DateTime<Utc>) -> String {
    time.to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn row_of(world: &World, key: &str) -> Option<Value> {
    let sidebar = world.state("sidebar");
    ["pinned", "active", "snoozed", "settled"]
        .iter()
        .find_map(|section| {
            sidebar[*section]
                .as_array()
                .into_iter()
                .flatten()
                .find(|row| text(&row["key"]) == key)
                .cloned()
        })
}

fn shown_row(world: &World, key: &str) -> String {
    format!(
        "the row is {}",
        show(&row_of(world, key).unwrap_or(Value::Null))
    )
}

fn active_titles(world: &World) -> Vec<String> {
    world.state("sidebar")["active"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| text(&row["title"]))
        .collect()
}

/// The next time it is `hour:minute` on the day named `day`, in the
/// scenarios' zone (UTC, as World pins the sidebar's).
fn next_on(world: &World, day: &str, hour: &str, minute: &str) -> Outcome<DateTime<Utc>> {
    let now = world.now();
    let time = NaiveTime::from_hms_opt(hour.parse().unwrap_or(99), minute.parse().unwrap_or(99), 0);
    let Some(time) = time else {
        fail!("{hour}:{minute} is not a time of day");
    };
    let mut date = now.date_naive();
    for _ in 0..8 {
        let at = Utc.from_utc_datetime(&date.and_time(time));
        if date.weekday().to_string() == day[..3] && at > now {
            return Ok(at);
        }
        date = date.succ_opt().unwrap_or(date);
    }
    fail!("\"{day}\" is not a day of the week")
}

fn menu_items(world: &World) -> Outcome<Vec<Value>> {
    let menu = world.state("menu");
    expect!(menu.is_object(), "no menu is open");
    Ok(at(&menu, "items").as_array().cloned().unwrap_or_default())
}

fn menu_item(world: &World, id: &str) -> Outcome<Option<Value>> {
    Ok(menu_items(world)?
        .into_iter()
        .find(|entry| text(&entry["id"]) == id))
}

fn menu_is(world: &World) -> String {
    format!(
        "the menu is {}",
        show(&Value::Array(menu_items(world).unwrap_or_default()))
    )
}

fn open_menu(world: &mut World, key: &str) -> Outcome {
    world.sync()?;
    world.dispatch("thread.menu", json!({"key": key, "x": 40, "y": 120}))
}

fn enabled(entry: &Value) -> bool {
    entry["enabled"].as_bool().unwrap_or(false)
}

/// Snoozes from the thread's menu with the choice the scenario names.
fn snooze_with(world: &mut World, key: &str, choice: &str) -> Outcome {
    let preset = match choice {
        "for 1 hour" => "hour",
        "for 3 hours" => "three-hours",
        "this evening" => "evening",
        "tomorrow" | "until tomorrow" => "tomorrow",
        "next week" => "next-week",
        _ => "",
    };
    open_menu(world, key)?;
    let id = format!("snooze:{preset}");
    let Some(snooze) = menu_item(world, "snooze")?.filter(enabled) else {
        fail!("{}", menu_is(world));
    };
    let offered = snooze["children"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|child| text(&child["id"]) == id);
    expect!(
        offered,
        "the snooze choices are {}",
        show(&snooze["children"])
    );
    pick(world, &id)
}

fn wait_for_section(world: &mut World, key: &str, section: &str) -> Outcome {
    world.wait_for_with(
        |w| section_of(w, key) == section,
        |w| format!("{key} in {section}; it is in \"{}\"", section_of(w, key)),
    )
}

/// The thread's run `status`, started a quarter of an hour ago.
fn set_run(row: &mut Map<String, Value>, status: &str, now: DateTime<Utc>) {
    row.insert("latestRunId".into(), json!("r1"));
    row.insert("status".into(), json!(status));
    row.insert(
        "latestRunStartedAt".into(),
        json!(iso(now - Duration::seconds(900))),
    );
    row.insert("updatedAt".into(), json!(iso(now)));
}

fn request(kind: &str, now: DateTime<Utc>) -> Value {
    json!({"id": "q1", "kind": kind, "createdAt": iso(now)})
}

fn wait_snoozed_until(world: &mut World, key: &str, wake: DateTime<Utc>) -> Outcome {
    let expected = wake.timestamp_millis();
    let until = |w: &World| {
        row_of(w, key)
            .and_then(|row| {
                row["snoozedUntil"]
                    .as_str()
                    .and_then(|t| DateTime::parse_from_rfc3339(t).ok())
            })
            .map_or(0, |t| t.timestamp_millis())
    };
    world.wait_for_with(
        |w| section_of(w, key) == "snoozed" && until(w) == expected,
        |w| format!("{key} snoozed until {}; {}", iso(wake), shown_row(w, key)),
    )
}

/// "Custom…" in the thread's snooze menu, which asks for the time.
fn ask_custom(world: &mut World, key: &str) -> Outcome {
    open_menu(world, key)?;
    expect!(
        menu_item(world, "snooze")?.is_some_and(|s| enabled(&s)),
        "{}",
        menu_is(world)
    );
    pick(world, "snooze:custom")?;
    expect!(
        world.state("customSnooze").is_object(),
        "the user is not asked for a time"
    );
    Ok(())
}

fn submit_custom(world: &mut World, input: Value) -> Outcome {
    world.dispatch("snooze.custom.submit", input)
}

fn first_thread(world: &World) -> String {
    world.mc.threads.keys().next().cloned().unwrap_or_default()
}

pub fn register(steps: &mut Steps) {
    // Snoozing.
    steps.step(
        &format!("the user snoozes {Q} (for 1 hour|for 3 hours|this evening|tomorrow|next week|until tomorrow)"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            scene(world).subject = key.clone();
            // "The next thread in the list" needs one: an older thread beside
            // the one the window shows.
            if world.mc.threads.len() == 1 && route_thread(world) == key {
                let mut next = world.mc.threads.values().next().cloned().unwrap_or_else(|| json!({}));
                next["id"] = json!("t-next");
                next["title"] = json!("Next up");
                next["createdAt"] = json!("2026-09-23T08:00:00Z");
                next["updatedAt"] = json!("2026-09-23T08:00:00Z");
                world.mc.threads.insert("t-next".into(), next.clone());
                world.mc.send_row("t-next", &next);
            }
            snooze_with(world, &key, &c[1])
        },
    );
    steps.step(
        &format!("{Q} wakes (\\w+day) at (\\d+):(\\d+)"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            let wake = next_on(world, &c[1], &c[2], &c[3])?;
            wait_snoozed_until(world, &key, wake)
        },
    );
    steps.step("the user opens the snooze choices", |world, _, _| {
        world.sync()?;
        let key = format!("{}:{}", world.mc.environment_id, first_thread(world));
        world.dispatch("thread.snoozeMenu", json!({"key": key, "x": 200, "y": 120}))?;
        expect!(
            !menu_items(world)?.is_empty(),
            "no snooze choice is offered"
        );
        Ok(())
    });
    steps.step(
        "only one choice wakes the thread on (\\w+day) at (\\d+):(\\d+)",
        |world, c, _| {
            let wake = next_on(world, &c[0], &c[1], &c[2])?;
            // Each choice names its wake time; the menu lists the presets in order.
            let presets = hal_c2_shell::controllers::sidebar::snooze_presets(world.engine());
            let items = menu_items(world)?;
            let shown = show(&Value::Array(items.clone()));
            // The presets, then "Custom…".
            expect!(items.len() == presets.len() + 1, "the menu is {shown}");
            let mut waking = 0;
            for (index, preset) in presets.iter().enumerate() {
                expect!(
                    text(&items[index]["id"]) == format!("snooze:{}", preset.id),
                    "the menu is {shown}"
                );
                let until = DateTime::parse_from_rfc3339(&preset.snoozed_until)
                    .map(|t| t.timestamp_millis());
                if until == Ok(wake.timestamp_millis()) {
                    waking += 1;
                }
            }
            expect!(
                waking == 1,
                "{waking} choices wake the thread then: {shown}"
            );
            Ok(())
        },
    );
    steps.step(
        "the user prefers a (24-hour|12-hour) clock",
        |world, c, _| set_device(world, "timestampFormat", json!(c[0])),
    );
    steps.step(
        &format!("{Q} is snoozed until (\\w+day) (\\d+):(\\d+)"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            scene(world).subject = key.clone();
            let until = iso(next_on(world, &c[1], &c[2], &c[3])?);
            let at = iso(world.now() - Duration::seconds(60));
            update_row(world, id_in(&key), |row| {
                row.insert("snoozedUntil".into(), json!(until));
                row.insert("snoozedAt".into(), json!(at));
            })
        },
    );
    steps.step(
        &format!("{Q} is snoozed until 20 seconds from now"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            scene(world).subject = key.clone();
            let now = world.now();
            update_row(world, id_in(&key), |row| {
                row.insert(
                    "snoozedUntil".into(),
                    json!(iso(now + Duration::seconds(20))),
                );
                row.insert("snoozedAt".into(), json!(iso(now - Duration::seconds(60))));
            })
        },
    );
    steps.step(
        "the user looks at the (?:snoozed )?thread",
        |world, _, _| world.sync(),
    );
    steps.step(&format!("the wake time reads {Q}"), |world, c, _| {
        let subject = scene(world).subject.clone();
        let row = row_of(world, &subject);
        expect!(
            row.is_some_and(|row| text(&row["wakeDescription"]) == c[0]),
            "{}",
            shown_row(world, &subject)
        );
        Ok(())
    });
    steps.step(&format!("its wake label reads {Q}"), |world, c, _| {
        let subject = scene(world).subject.clone();
        let row = row_of(world, &subject);
        expect!(
            section_of(world, &subject) == "snoozed"
                && row.is_some_and(|row| text(&row["wakeLabel"]) == c[0]),
            "{}",
            shown_row(world, &subject)
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} has a turn queued that has not started"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            let now = world.now();
            update_row(world, id_in(&key), |row| {
                row.insert("latestRunId".into(), json!("r1"));
                row.insert("status".into(), json!("queued"));
                row.insert("latestRunRequestedAt".into(), json!(iso(now)));
            })
        },
    );
    steps.step(&format!("the user tries to snooze {Q}"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        scene(world).subject = key.clone();
        open_menu(world, &key)
    });
    steps.step("snoozing is unavailable", |world, _, _| {
        // Neither the menu nor the row's own action snoozes it.
        let subject = scene(world).subject.clone();
        expect!(
            menu_item(world, "snooze")?.is_some_and(|s| !enabled(&s)),
            "{}",
            menu_is(world)
        );
        let row = row_of(world, &subject);
        expect!(
            row.is_some_and(|row| !row["canSnooze"].as_bool().unwrap_or(false)),
            "{}",
            shown_row(world, &subject)
        );
        Ok(())
    });
    steps.step(&format!("{Q} is snoozed"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        if !world.checking {
            let now = world.now();
            update_row(world, id_in(&key), |row| {
                row.insert("snoozedUntil".into(), json!(iso(now + Duration::days(1))));
                row.insert("snoozedAt".into(), json!(iso(now - Duration::seconds(60))));
            })?;
        }
        wait_for_section(world, &key, "snoozed")
    });

    // A wake time of the user's own, through the Custom snooze dialog.
    steps.step(
        &format!("the user snoozes {Q} for a custom (45 minutes|2 days|date of Friday 08:30)"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            scene(world).subject = key.clone();
            ask_custom(world, &key)?;
            let input = if c[1].starts_with("date of") {
                let friday = next_on(world, "Friday", "8", "30")?;
                json!({"mode": "date", "date": friday.date_naive().to_string(), "time": "08:30"})
            } else {
                let (amount, unit) = c[1].split_once(' ').unwrap_or_default();
                json!({"mode": "duration", "amount": amount, "unit": unit})
            };
            submit_custom(world, input)?;
            let asked = world.state("customSnooze");
            expect!(!asked.is_object(), "the dialog says {}", show(&asked));
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} wakes 48 hours after confirming"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            let wake = world.now() + Duration::hours(48);
            wait_snoozed_until(world, &key, wake)
        },
    );
    steps.step(
        &format!("{Q} wakes (\\w+day) at (\\d+):(\\d+) local time"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            let wake = next_on(world, &c[1], &c[2], &c[3])?;
            wait_snoozed_until(world, &key, wake)
        },
    );
    steps.step(
        &format!("the user tries to snooze {Q} until (Tuesday 09:00|an unreadable date|a time skipped by a daylight saving change)"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            scene(world).subject = key.clone();
            let input = match c[1].as_str() {
                // The day before the scenario's Wednesday.
                "Tuesday 09:00" => {
                    let day = world.now().date_naive().pred_opt().unwrap_or_default();
                    json!({"mode": "date", "date": day.to_string(), "time": "09:00"})
                }
                "an unreadable date" => json!({"mode": "date", "date": "next friday", "time": "09:00"}),
                // New York's clocks go from 02:00 to 03:00 on 14 March 2027.
                // TODO(port): SidebarModel::setTimeZone takes a named zone; the
                // shell's sidebar::set_time_zone takes a fixed offset, which
                // has no daylight saving change to skip.
                _ => fail!("the sidebar's zone is a fixed offset, with no daylight saving change"),
            };
            ask_custom(world, &key)?;
            submit_custom(world, input)
        },
    );
    steps.step("the snooze is refused", |world, _, _| {
        world.sync()?;
        let asked = world.state("customSnooze");
        expect!(
            text(&asked["error"]) == "Choose a valid date and time in the future.",
            "the dialog says {}",
            show(&asked)
        );
        let snoozed = world
            .mc
            .commands
            .iter()
            .any(|command| text(&command["type"]) == "thread.snooze");
        expect!(!snoozed, "the MC has {}", world.describe_commands());
        let subject = scene(world).subject.clone();
        expect!(
            section_of(world, &subject) == "active",
            "the thread is not active"
        );
        Ok(())
    });

    // Waking early: what the MC's row says once the thread needs the user.
    steps.step(
        "(the agent asks for an approval|the agent asks the user a question|the agent run fails|a run that started after the snooze finishes)",
        |world, c, _| {
            let id = first_thread(world);
            scene(world).subject = format!("{}:{id}", world.mc.environment_id);
            let now = world.now();
            let what = c[0].clone();
            update_row(world, &id, |row| {
                if what.starts_with("the agent asks") {
                    set_run(row, "running", now);
                    row.insert("activeRunId".into(), json!("r1"));
                    let kind = if what.ends_with("question") { "user_input" } else { "command_approval" };
                    row.insert("pendingRuntimeRequest".into(), request(kind, now));
                } else if what == "the agent run fails" {
                    set_run(row, "failed", now);
                } else {
                    set_run(row, "completed", now);
                    row.insert("latestRunCompletedAt".into(), json!(iso(now)));
                }
            })
        },
    );
    steps.step("it is marked as woke", |world, _, _| {
        let subject = scene(world).subject.clone();
        let row = row_of(world, &subject);
        expect!(
            row.is_some_and(|row| row["wokeAt"].is_string()),
            "{}",
            shown_row(world, &subject)
        );
        Ok(())
    });

    // Failures and where the window goes.
    steps.step("the environment rejects the snooze", |world, _, _| {
        world.mc.refusals.insert(
            "thread.snooze".into(),
            "The thread cannot be snoozed".into(),
        );
        Ok(())
    });
    steps.step(&format!("{Q} stays active"), |world, c, _| {
        world.sync()?;
        let key = key_of(world, &c[0])?;
        let section = section_of(world, &key);
        expect!(section == "active", "{} is in \"{section}\"", c[0]);
        Ok(())
    });
    steps.step("the next thread in the list opens", |world, _, _| {
        let snoozed = scene(world).subject.clone();
        world.wait_for_with(
            |w| {
                let open = route_thread(w);
                !open.is_empty() && open != snoozed && section_of(w, &open) == "active"
            },
            |w| {
                format!(
                    "another thread to open; the route is {}",
                    show(&w.state("route"))
                )
            },
        )
    });
    steps.step("the user can undo the snooze", |world, _, _| {
        let snoozed = scene(world).subject.clone();
        wait_for_section(world, &snoozed, "snoozed")?;
        let toasts = world.state("toasts");
        let toast = toasts["items"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|item| text(&item["title"]).starts_with("Snoozed until"))
            .last()
            .cloned()
            .unwrap_or(Value::Null);
        let actions = toast["actions"].as_array().cloned().unwrap_or_default();
        expect!(
            actions.len() == 1 && text(&actions[0]["label"]) == "Undo",
            "the shell shows {}",
            show(&toasts)
        );
        world.dispatch(
            "notification.action",
            json!({"id": toast["id"], "actionId": actions[0]["id"]}),
        )?;
        wait_for_section(world, &snoozed, "active")
    });

    // Settling.
    steps.step(
        &format!("{Q} is settled and no longer (pinned|snoozed)"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            wait_for_section(world, &key, "settled")?;
            let row = row_of(world, &key).unwrap_or(Value::Null);
            let cleared = if c[1] == "pinned" {
                !row["pinned"].as_bool().unwrap_or(false)
            } else {
                !row["snoozedUntil"].is_string()
            };
            expect!(cleared, "the row is {}", show(&row));
            Ok(())
        },
    );

    // What a row and a project say.
    steps.step(
        &format!("{Q} has an agent working and is waiting for an approval"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            let now = world.now();
            update_row(world, id_in(&key), |row| {
                set_run(row, "running", now);
                row.insert("activeRunId".into(), json!("r1"));
                row.insert(
                    "pendingRuntimeRequest".into(),
                    request("command_approval", now),
                );
            })
        },
    );
    steps.step(
        &format!("one thread in {Q} is working and another is waiting for an approval"),
        |world, c, _| {
            let first = first_thread(world);
            let in_project = world
                .mc
                .threads
                .get(&first)
                .is_some_and(|row| text(&row["projectId"]) == c[0]);
            expect!(in_project, "the thread is not in {}", c[0]);
            let now = world.now();
            update_row(world, &first, |row| {
                set_run(row, "running", now);
                row.insert("activeRunId".into(), json!("r1"));
            })?;
            let mut other = world.mc.threads[&first].clone();
            other["id"] = json!("t-approval");
            other["title"] = json!("Needs approval");
            other["pendingRuntimeRequest"] = request("command_approval", now);
            world.mc.threads.insert("t-approval".into(), other.clone());
            world.mc.send_row("t-approval", &other);
            world.sync()
        },
    );
    steps.step(
        &format!("the user looks at the project {Q}"),
        |world, c, _| {
            world.sync()?;
            let key = world.project_key(&c[0]);
            scene(world).subject = key;
            Ok(())
        },
    );
    steps.step(
        "the project shows that a thread needs an approval",
        |world, _, _| {
            // Sidebar.qml names the state beside the project in its scope menu.
            let subject = scene(world).subject.clone();
            let projects = world.state("sidebar")["projects"].clone();
            let Some(project) = projects
                .as_array()
                .into_iter()
                .flatten()
                .find(|p| text(&p["key"]) == subject)
            else {
                fail!("the projects are {}", show(&projects));
            };
            expect!(
                text(&project["status"]) == "approval",
                "the project is {}",
                show(project)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the agent has been working in {Q} for (\\d+) minutes"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            scene(world).subject = key.clone();
            let now = world.now();
            let minutes: i64 = c[1].parse().unwrap_or(0);
            update_row(world, id_in(&key), |row| {
                set_run(row, "running", now);
                row.insert("activeRunId".into(), json!("r1"));
                row.insert(
                    "latestRunStartedAt".into(),
                    json!(iso(now - Duration::seconds(60 * minutes + 20))),
                );
            })
        },
    );
    steps.step(
        "the thread shows it has been working for (\\d+) minutes",
        |world, c, _| {
            // SidebarThreadRow.qml reads "Working 3m".
            let subject = scene(world).subject.clone();
            let row = row_of(world, &subject);
            expect!(
                row.is_some_and(|row| text(&row["status"]) == "working"
                    && text(&row["workingLabel"]) == format!("{}m", c[0])),
                "{}",
                shown_row(world, &subject)
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} is read"), |world, c, _| {
        super::thread_menu::project_thread_commands(world);
        let key = key_of(world, &c[0])?;
        let now = world.now();
        update_row(world, id_in(&key), |row| {
            set_run(row, "completed", now - Duration::seconds(600));
            row.insert(
                "latestRunCompletedAt".into(),
                json!(iso(now - Duration::seconds(600))),
            );
            row.insert(
                "lastVisitedAt".into(),
                json!(iso(now - Duration::seconds(300))),
            );
        })?;
        let row = row_of(world, &key);
        expect!(
            row.is_some_and(|row| !row["unread"].as_bool().unwrap_or(false)),
            "{}",
            shown_row(world, &key)
        );
        Ok(())
    });

    // The order of the active threads.
    steps.step(
        "the user arranged the active threads by hand",
        |world, _, _| {
            world.sync()?;
            let ids: Vec<String> = world.state("sidebar")["active"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|row| text(&row["threadId"]))
                .collect();
            for (place, id) in ids.iter().enumerate() {
                update_row(world, id, |fields| {
                    fields.insert("activeOrderKey".into(), json!(format!("a{place}")));
                })?;
            }
            let titles = active_titles(world);
            scene(world).order_before = titles;
            Ok(())
        },
    );
    steps.step(&format!("a new thread {Q} is created"), |world, c, _| {
        let now = iso(world.now());
        let project = world.mc.threads.values().next().map(|row| row["projectId"].clone()).unwrap_or(Value::Null);
        let row = json!({"id": "t-new", "title": c[0], "projectId": project, "createdAt": now, "updatedAt": now});
        world.mc.threads.insert("t-new".into(), row.clone());
        world.mc.send_row("t-new", &row);
        world.sync()
    });
    steps.step(
        &format!("{Q} is listed above the arranged threads"),
        |world, c, _| {
            let mut expected = vec![c[0].clone()];
            expected.extend(scene(world).order_before.clone());
            let titles = active_titles(world);
            expect!(
                titles == expected,
                "the active threads are {}",
                titles.join(", ")
            );
            Ok(())
        },
    );
    steps.step(&format!("the agent finishes work in {Q}"), |world, c, _| {
        world.sync()?;
        let titles = active_titles(world);
        scene(world).order_before = titles;
        let key = key_of(world, &c[0])?;
        let now = world.now();
        update_row(world, id_in(&key), |row| {
            set_run(row, "completed", now);
            row.insert("latestRunCompletedAt".into(), json!(iso(now)));
            row.insert(
                "latestUserMessageAt".into(),
                json!(iso(now - Duration::seconds(60))),
            );
        })
    });
    steps.step(
        "the order of the active threads does not change",
        |world, _, _| {
            let titles = active_titles(world);
            let before = scene(world).order_before.clone();
            expect!(
                titles == before,
                "the active threads are {}",
                titles.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is the second active thread( again)?"),
        |world, c, _| {
            world.wait_for_with(
                |w| active_titles(w).get(1) == Some(&c[0]),
                |w| {
                    format!(
                        "{} second; the active threads are {}",
                        c[0],
                        active_titles(w).join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user pins and then unpins {Q}"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            open_menu(world, &key)?;
            pick(world, "pin")?;
            wait_for_section(world, &key, "pinned")?;
            open_menu(world, &key)?;
            pick(world, "unpin")
        },
    );
}
