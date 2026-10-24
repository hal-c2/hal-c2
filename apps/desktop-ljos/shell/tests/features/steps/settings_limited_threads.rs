//! What General's usage-limit rows mean for a thread that stops on a limit
//! (features/settings/general.feature): the MC arms the recovery its settings
//! ask for (HalC2.Orchestration.LimitRecovery, faked here from the settings
//! document the rows wrote), and the thread's banner shows and cancels it
//! (LimitRecoveryController). desktop-qt's SettingsLimitedThreadsSteps.cpp.

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::sidebar::Sidebar;
use serde_json::{Value, json};

use crate::expect;
use crate::harness::{Outcome, Steps, show};
use crate::steps::settings::fake_config;
use crate::steps::settings_rows::turn_row;
use crate::steps::settings_scoped_rows::{held, held_all};
use crate::steps::stream::THREAD;
use crate::steps::thread_menu::{project_thread_commands, section_of, update_row};
use crate::steps::turn::open_turn_thread;
use crate::world::World;

const AUTO_RESUME: &str = "autoResumeLimitedThreads";
const SNOOZE: &str = "snoozeLimitedThreads";

fn iso(time: DateTime<Utc>) -> String {
    time.to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn key(world: &World) -> String {
    format!("{}:{THREAD}", world.mc.environment_id)
}

/// The reported reset, four hours on.
fn reset_at(world: &World) -> String {
    iso(world.now() + Duration::seconds(4 * 3600))
}

fn banner(world: &World) -> Value {
    world.state("limitRecovery")
}

fn recovery(world: &World) -> Value {
    world
        .mc
        .threads
        .get(THREAD)
        .map_or(Value::Null, |row| row["limitRecovery"].clone())
}

/// The thread's latest run stops on the provider's limit, and the MC arms
/// what its settings say.
fn stop_on_limit(world: &mut World) -> Outcome {
    project_thread_commands(world);
    open_turn_thread(world)?;
    let resume = fake_config(&mut world.mc).settings.get(AUTO_RESUME) == Some(&json!(true));
    let snooze = fake_config(&mut world.mc).settings.get(SNOOZE) == Some(&json!(true));
    let stopped = iso(world.now() - Duration::seconds(300));
    let started = iso(world.now() - Duration::seconds(900));
    let reset = reset_at(world);
    update_row(world, THREAD, |row| {
        row.insert("latestRunId".into(), json!("r1"));
        row.insert("status".into(), json!("failed"));
        row.insert("lastErrorClass".into(), json!("usage_limit"));
        row.insert("latestRunStartedAt".into(), json!(started));
        row.insert("latestRunCompletedAt".into(), json!(stopped));
        row.insert("updatedAt".into(), json!(stopped));
        row.insert("usageLimitResetAt".into(), json!(reset));
        if !resume && !snooze {
            return;
        }
        row.insert(
            "limitRecovery".into(),
            json!({"runId": "r1", "resetAt": reset, "autoResume": resume, "snooze": snooze}),
        );
        if snooze {
            row.insert("snoozedUntil".into(), json!(reset));
            row.insert("snoozedAt".into(), json!(stopped));
        }
    })?;
    let thread = key(world);
    world.with::<Navigation, _>(|navigation, engine| {
        navigation.open(engine, Route::Thread(thread.clone()))
    })?;
    let wanted = key(world);
    world.wait_for_with(
        move |w| banner(w)["threadKey"] == wanted.as_str(),
        |w| format!("the limit banner; it is {}", show(&banner(w))),
    )
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "\"(Auto-resume limited threads|Snooze limited threads)\" is on(?: for the environment)?",
        |world, c, _| {
            let row = if c[0].starts_with("Auto") {
                AUTO_RESUME
            } else {
                SNOOZE
            };
            turn_row(world, row, true)?;
            world.wait_for_with(
                move |w| held(w, row) == json!(true),
                move |w| format!("the MC to hold {row}; it holds {}", show(&held_all(w))),
            )
        },
    );
    steps.step(
        "a thread stops because the provider's usage limit was reached",
        |world, _, _| stop_on_limit(world),
    );
    steps.step(
        "the thread is scheduled to continue at the reported reset time",
        |world, _, _| {
            let shown = banner(world);
            let section = section_of(world, &key(world));
            expect!(
                shown["scheduled"] == json!(true)
                    && shown["snoozed"] != json!(true)
                    && shown["description"]
                        .as_str()
                        .is_some_and(|d| d.starts_with("Resets "))
                    && recovery(world)["resetAt"] == reset_at(world).as_str()
                    && section == "active",
                "the banner is {}; the thread is in \"{section}\"",
                show(&shown)
            );
            Ok(())
        },
    );
    steps.step(
        "the thread is snoozed until it wakes at the reported reset time",
        |world, _, _| {
            let thread = key(world);
            world.wait_for_with(
                |w| section_of(w, &thread) == "snoozed",
                |w| {
                    format!(
                        "the thread to be snoozed; it is in \"{}\"",
                        section_of(w, &thread)
                    )
                },
            )?;
            let shown = banner(world);
            expect!(
                shown["snoozed"] == json!(true)
                    && shown["scheduled"] != json!(true)
                    && world.mc.threads.get(THREAD).map(|row| &row["snoozedUntil"])
                        == Some(&json!(reset_at(world))),
                "the banner is {}",
                show(&shown)
            );
            // At the reset it is back among the active threads.
            let after = world.now() + Duration::seconds(4 * 3600 + 1);
            world.set_time(after);
            world.with::<Sidebar, _>(|sidebar, engine| sidebar.refresh(engine))?;
            let section = section_of(world, &thread);
            expect!(
                section == "active",
                "the thread is in \"{section}\" after the reset"
            );
            Ok(())
        },
    );

    steps.step(
        "a limited thread is scheduled to continue at its reset time",
        |world, _, _| {
            stop_on_limit(world)?;
            expect!(
                banner(world)["scheduled"] == json!(true),
                "the banner is {}",
                show(&banner(world))
            );
            Ok(())
        },
    );
    steps.step(
        "the user cancels the scheduled continuation in that thread",
        |world, _, _| {
            // The banner's own control, on while it is scheduled.
            world.dispatch("limitRecovery.resume", json!({}))?;
            world.sync()
        },
    );
    steps.step("the thread does not continue on its own", |world, _, _| {
        world.wait_for_with(
            // A banner that says nothing of it is still scheduled.
            |w| banner(w)["scheduled"] == json!(false),
            |w| format!("the banner is {}", show(&banner(w))),
        )?;
        expect!(
            recovery(world)["autoResume"] == json!(false) && recovery(world)["runId"] == "r1",
            "the MC holds {}",
            show(&recovery(world))
        );
        // The setting itself is as the user left it: only this thread was taken off.
        expect!(
            held(world, AUTO_RESUME) == json!(true),
            "the setting was changed"
        );
        Ok(())
    });
}
