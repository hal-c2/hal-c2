//! What the open thread says about its runs over and under its
//! conversation (features/timeline/runs-and-queue.feature): background
//! work its finished turn left running, which stops from the notice
//! under the conversation (ThreadNotice), and the thread's error over
//! its top, which dismisses. Both are drawn in the ThreadView brick;
//! the fake MC's thread row says what the MC would:
//! desktop-qt's RunNoticeSteps.cpp.

use chrono::Duration;
use hal_c2_shell::controllers::navigation::{Navigation, PROVIDERS_SECTION, Route};
use hal_c2_shell::controllers::thread_notice::STOP_WAIT_MS;
use ljos::prelude::{ObjectId, Value};
use serde_json::{Value as Json, json};

use super::settings::publish_providers;
use super::stream::{
    FakeStreams, PROJECT, THREAD, describe, iso, look, now, read, role, seed_turns,
};
use crate::brick::{self, Brick};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// Whether the scenario showed the thread's error, so "the user dismisses
/// the error" is this one's and not the Device tab's.
#[derive(Default)]
struct ThreadErrorShown {
    shown: bool,
}

/// The provider a scenario's thread runs on, as the MC's config lists it.
#[derive(Default)]
struct ProviderShown {
    shown: bool,
    entry: Json,
}

fn thread_view(world: &mut World) -> Outcome<Brick> {
    if world.part::<brick::Shown>().0.is_none() {
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n",
            820.0,
            560.0,
        )?;
    }
    brick::shown(world)
}

/// The notices as they stack above the composer, drawn together: the
/// bricks ThreadView and the composer place, in one column.
fn stack_view(world: &mut World) -> Outcome<Brick> {
    if world.part::<brick::Shown>().0.is_none() {
        let mut brick = Brick::new(
            world,
            "import QtQuick\nimport QtQuick.Layouts\nimport HalC2.Bricks\n\
             ColumnLayout {\n  spacing: 4\n\
               ThreadErrorBanner { Layout.fillWidth: true }\n\
               ProviderStatusBanner { Layout.fillWidth: true }\n\
               LimitRecoveryBanner { Layout.fillWidth: true }\n\
               ThreadNotice { Layout.fillWidth: true }\n\
               NoticeStackPeek { Layout.fillWidth: true }\n\
               ComposerUsageLimits { Layout.fillWidth: true }\n\
               Item { Layout.fillHeight: true }\n}\n",
            820.0,
            560.0,
        )?;
        brick.takes_keys = true;
        world.part::<brick::Shown>().0 = Some(brick);
    }
    brick::shown(world)
}

fn notice(world: &World) -> Json {
    world.state("threadNotice")
}

fn seen(world: &World) -> String {
    format!(
        "threadNotice is {}; threadError is {}",
        show(&world.state("threadNotice")),
        show(&world.state("threadError"))
    )
}

fn stack(world: &World) -> Json {
    world.state("noticeStack")
}

fn stack_seen(world: &World) -> String {
    format!(
        "noticeStack is {}; {}",
        show(&world.state("noticeStack")),
        seen(world)
    )
}

fn update_thread_row(world: &mut World, fields: Json) {
    let mut row = world.mc.threads.get(THREAD).cloned().unwrap_or(json!({}));
    if let Some(extra) = fields.as_object() {
        for (k, v) in extra {
            row[k] = v.clone();
        }
    }
    world.mc.threads.insert(THREAD.into(), row.clone());
    world.mc.send_row(THREAD, &row);
}

fn leave_running(world: &mut World, tasks: &[String]) {
    let pending: Vec<Json> = tasks
        .iter()
        .enumerate()
        .map(|(i, description)| {
            json!({"taskId": format!("task-{}", i + 1), "description": description})
        })
        .collect();
    update_thread_row(
        world,
        json!({"latestRunId": "run-1", "activeRunId": Json::Null,
               "status": "completed", "pendingBackgroundTasks": pending}),
    );
}

fn quoted(words: &str) -> Vec<String> {
    words
        .split('"')
        .skip(1)
        .step_by(2)
        .map(str::to_owned)
        .collect()
}

fn interrupts(world: &World) -> usize {
    world
        .mc
        .commands
        .iter()
        .filter(|command| command["type"] == json!("run.interrupt"))
        .count()
}

fn running_task(world: &World, description: &str) -> bool {
    world.mc.threads[THREAD]["pendingBackgroundTasks"]
        .as_array()
        .is_some_and(|tasks| {
            tasks
                .iter()
                .any(|task| text(&task["description"]) == description)
        })
}

fn notice_says(world: &mut World, title: &str) -> Outcome<ObjectId> {
    let view = thread_view(world)?;
    let wanted = title.to_owned();
    world.wait_for_with(
        move |w| {
            let shown_item = view.find(w, "threadNotice").ok().flatten();
            shown_item.is_some_and(|item| view.flag(w, item, "visible"))
                && view
                    .find(w, "threadNoticeTitle")
                    .ok()
                    .flatten()
                    .is_some_and(|t| view.text_of(w, t, "text") == wanted)
        },
        move |w| format!("the thread to say \"{title}\"; {}", seen(w)),
    )?;
    view.item(world, "threadNotice")
}

fn stop_from_notice(world: &mut World) -> Outcome {
    let view = thread_view(world)?;
    world.wait_for_with(
        move |w| {
            view.find(w, "threadNoticeAction")
                .ok()
                .flatten()
                .is_some_and(|action| view.text_of(w, action, "text") == "Stop")
        },
        |w| format!("the notice to offer Stop; {}", seen(w)),
    )?;
    let before = interrupts(world);
    view.click(world, "threadNoticeAction")?;
    world.wait_for_with(
        move |w| interrupts(w) > before,
        |w| format!("the MC to be asked to stop; {}", seen(w)),
    )?;
    let command = world.mc.commands.last().cloned().unwrap_or(Json::Null);
    expect!(
        command["threadId"] == json!(THREAD) && command.get("runId").is_none(),
        "{}",
        show(&command)
    );
    Ok(())
}

fn error_shows(world: &mut World, message: &str) -> Outcome {
    let view = thread_view(world)?;
    let wanted = message.to_owned();
    world.wait_for_with(
        move |w| {
            let banner = view.find(w, "threadError").ok().flatten();
            banner.is_some_and(|item| view.flag(w, item, "visible"))
                && view
                    .find(w, "threadErrorMessage")
                    .ok()
                    .flatten()
                    .is_some_and(|m| view.text_of(w, m, "text") == wanted)
                && w.state("threadError")["message"] == Json::from(wanted.as_str())
        },
        move |w| format!("the thread to show the error \"{message}\"; {}", seen(w)),
    )
}

fn show_error(world: &mut World, message: &str) -> Outcome {
    update_thread_row(world, json!({"lastError": message}));
    world.mc.part::<ThreadErrorShown>().shown = true;
    error_shows(world, message)
}

fn provider_notice(world: &World) -> Json {
    world.state("providerNotice")
}

fn provider_notice_says(world: &mut World, title: &str, message: &str) -> Outcome {
    let view = thread_view(world)?;
    let (title, message) = (title.to_owned(), message.to_owned());
    let (said_title, said_message) = (title.clone(), message.clone());
    world.wait_for_with(
        move |w| {
            let (title, message) = (&said_title, &said_message);
            let banner = view.find(w, "providerNotice").ok().flatten();
            banner.is_some_and(|item| view.flag(w, item, "visible"))
                && view
                    .find(w, "providerNoticeTitle")
                    .ok()
                    .flatten()
                    .is_some_and(|t| view.text_of(w, t, "text") == *title)
                && (message.is_empty()
                    || view
                        .find(w, "providerNoticeMessage")
                        .ok()
                        .flatten()
                        .is_some_and(|m| view.text_of(w, m, "text") == *message))
        },
        {
            let (title, message) = (title.clone(), message.clone());
            move |w| {
                format!(
                    "the thread to show \"{title}\" with \"{message}\"; providerNotice is {}",
                    show(&w.state("providerNotice"))
                )
            }
        },
    )
}

fn no_provider_notice(world: &mut World) -> Outcome {
    let view = thread_view(world)?;
    world.sync()?;
    world.wait_for_with(
        move |w| {
            let banner = view.find(w, "providerNotice").ok().flatten();
            w.state("providerNotice").is_null()
                && !banner.is_some_and(|item| view.flag(w, item, "visible"))
        },
        |w| {
            format!(
                "no provider notice; providerNotice is {}",
                show(&w.state("providerNotice"))
            )
        },
    )
}

fn run_on(world: &mut World, driver: &str, name: &str, version: &str) -> Outcome {
    thread_view(world)?;
    let entry = json!({"instanceId": driver, "driver": driver, "displayName": name,
                       "enabled": true, "installed": true, "version": version,
                       "status": "ready", "auth": {"status": "authenticated"},
                       "models": [{"slug": "model-1", "name": "Model 1"}]});
    world.mc.part::<ProviderShown>().entry = entry.clone();
    publish_providers(&mut world.mc, vec![entry]);
    update_thread_row(
        world,
        json!({"modelSelection": {"instanceId": driver, "model": "model-1"}}),
    );
    Ok(())
}

fn report_provider(world: &mut World, fields: Json) {
    let mut entry = world.mc.part::<ProviderShown>().entry.clone();
    if let Some(extra) = fields.as_object() {
        for (k, v) in extra {
            entry[k] = v.clone();
        }
    }
    world.mc.part::<ProviderShown>().entry = entry.clone();
    publish_providers(&mut world.mc, vec![entry]);
    world.mc.part::<ProviderShown>().shown = true;
}

fn signed_out(setup: bool) -> Json {
    json!({"status": "error", "auth": {"status": "unauthenticated"},
           "setup": {"canAuthenticate": setup}})
}

fn drawn(world: &mut World, object_name: &str) -> bool {
    let Ok(view) = stack_view(world) else {
        return false;
    };
    view.find_visible(world, object_name)
        .is_ok_and(|found| found.is_some())
}

fn drawn_in(world: &World, view: Brick, object_name: &str) -> bool {
    view.find_visible(world, object_name)
        .is_ok_and(|found| found.is_some())
}

/// The thread runs on Codex, which offers "/usage-limits" and has limits
/// to show, and the user has asked: the answer is the composer's.
fn open_usage_limits_answer(world: &mut World) -> Outcome {
    let limits = json!({"checkedAt": iso(now()),
                        "windows": [{"id": "five-hour", "kind": "session",
                                     "label": "5-hour", "usedPercent": 40.0,
                                     "resetsAt": iso(now() + Duration::seconds(3600)),
                                     "windowDurationMins": 300}]});
    let codex = json!({"instanceId": "codex", "driver": "codex",
                       "displayName": "Codex", "enabled": true,
                       "installed": true, "status": "ready",
                       "models": [{"slug": "gpt-5", "name": "gpt-5"}],
                       "usageLimits": limits,
                       "slashCommands": [{"name": "usage-limits",
                                          "description": "Show this provider's usage limits"}]});
    publish_providers(&mut world.mc, vec![codex]);
    update_thread_row(
        world,
        json!({"modelSelection": {"instanceId": "codex", "model": "gpt-5"}}),
    );
    world.wait_for_with(
        |w| w.state("composer")["selectedModel"] == json!("gpt-5"),
        |w| {
            format!(
                "the composer on Codex; it shows {}",
                show(&w.state("composer"))
            )
        },
    )?;
    world.dispatch(
        "composer.submit",
        json!({"text": "/usage-limits", "intent": "foreground"}),
    )?;
    world.wait_for_with(
        |w| !w.state("composer")["usageLimits"].is_null(),
        |w| {
            format!(
                "the answer to /usage-limits; the composer shows {}",
                show(&w.state("composer"))
            )
        },
    )
}

/// The thread's latest run stopped on a usage limit an hour from
/// resetting.
fn stop_on_limit(world: &mut World) -> Outcome {
    let stopped = iso(now() - Duration::seconds(300));
    update_thread_row(
        world,
        json!({"latestRunId": "r1", "activeRunId": Json::Null,
               "status": "failed", "lastErrorClass": "usage_limit",
               "latestRunStartedAt": iso(now() - Duration::seconds(900)),
               "latestRunCompletedAt": stopped, "updatedAt": stopped,
               "usageLimitResetAt": iso(now() + Duration::seconds(3600))}),
    );
    world.wait_for_with(
        |w| !w.state("limitRecovery").is_null(),
        |w| {
            format!(
                "the usage limit banner; it is {}",
                show(&w.state("limitRecovery"))
            )
        },
    )
}

/// Whether the open thread's notice says what its background work is,
/// once it reads `title` (the connections steps' "the thread says" is
/// the computer's notice otherwise).
pub fn background_notice_says(world: &mut World, title: &str) -> Outcome<bool> {
    if notice(world)["kind"] != json!("background") {
        return Ok(false);
    }
    notice_says(world, title)?;
    Ok(true)
}

/// The thread's error's dismiss, when the scenario showed one (the
/// device steps' "the user dismisses the error" is the Device tab's
/// otherwise).
pub fn dismiss_thread_error(world: &mut World) -> Outcome<bool> {
    if !world.mc.part::<ThreadErrorShown>().shown {
        return Ok(false);
    }
    let view = thread_view(world)?;
    view.click(world, "threadErrorDismiss")?;
    Ok(true)
}

/// The thread's provider notice: dismissed and gone, when the scenario
/// showed one (the provider settings steps' are the sidebar's update
/// notice otherwise).
pub fn dismiss_provider_notice(world: &mut World) -> Outcome<bool> {
    if !world.mc.part::<ProviderShown>().shown {
        return Ok(false);
    }
    let view = thread_view(world)?;
    view.click(world, "providerNoticeDismiss")?;
    Ok(true)
}

pub fn provider_notice_gone(world: &mut World) -> Outcome<bool> {
    if !world.mc.part::<ProviderShown>().shown {
        return Ok(false);
    }
    no_provider_notice(world)?;
    Ok(true)
}

fn register_background(steps: &mut Steps) {
    steps.step(
        "the turn has finished and left (the tasks? .+?) running(?: in the background)?",
        |world, c, _| {
            let tasks = quoted(&c[0]);
            expect!(!tasks.is_empty(), "{}", c[0]);
            thread_view(world)?;
            leave_running(world, &tasks);
            world.wait_for_with(
                |w| notice(w)["kind"] == json!("background"),
                |w| format!("the thread to say what it waits on; {}", seen(w)),
            )
        },
    );
    steps.step(&format!("the thread says {Q}"), |world, c, _| {
        if notice(world)["kind"] == json!("background") {
            notice_says(world, &c[0])?;
            return Ok(());
        }
        super::connection_health::computer_notice_says(world, &c[0])
    });
    steps.step("it names each task by its description", |world, _, _| {
        let tasks: Vec<String> = world.mc.threads[THREAD]["pendingBackgroundTasks"]
            .as_array()
            .map(|tasks| {
                tasks
                    .iter()
                    .map(|task| text(&task["description"]))
                    .collect()
            })
            .unwrap_or_default();
        let view = thread_view(world)?;
        let wanted = tasks.join(", ");
        world.wait_for_with(
            move |w| {
                view.find(w, "threadNoticeDescription")
                    .ok()
                    .flatten()
                    .is_some_and(|item| view.text_of(w, item, "text") == wanted)
            },
            {
                let wanted = tasks.join(", ");
                move |w| format!("the notice to name {wanted}; {}", seen(w))
            },
        )
    });
    steps.step("the user can stop them from that notice", |world, _, _| {
        stop_from_notice(world)
    });
    steps.step(
        "the user stops the background work and the environment accepts",
        |world, _, _| {
            stop_from_notice(world)?;
            // The MC's answer is in, and the work it stopped has not ended yet.
            world.sync()
        },
    );
    steps.step("the user stops the background work", |world, _, _| {
        stop_from_notice(world)
    });
    steps.step(
        &format!("the stop shows {Q} and cannot be pressed while {Q} is still running"),
        |world, c, _| {
            expect!(running_task(world, &c[1]), "{}", c[1]);
            let view = thread_view(world)?;
            let action = view
                .find(world, "threadNoticeAction")?
                .ok_or_else(|| crate::harness::Failure(format!("no stop; {}", seen(world))))?;
            expect!(
                view.text_of(world, action, "text") == c[0] && !view.flag(world, action, "enabled"),
                "{}",
                seen(world)
            );
            // The button is disabled; the action, sent anyway, is not a second stop.
            let before = interrupts(world);
            world.dispatch("threadNotice.stop", json!({}))?;
            world.sync()?;
            expect!(
                interrupts(world) == before,
                "a pending stop was sent again; {}",
                seen(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is still running 10 seconds later"),
        |world, c, _| {
            expect!(running_task(world, &c[0]), "{}", c[0]);
            let at = world.now() + Duration::milliseconds(STOP_WAIT_MS);
            world.set_time(at);
            Ok(())
        },
    );
    steps.step(&format!("{Q} is still running"), |world, c, _| {
        expect!(running_task(world, &c[0]), "{}", c[0]);
        world.sync()?;
        expect!(
            notice(world)["description"] == Json::from(c[0].as_str()),
            "{}",
            seen(world)
        );
        Ok(())
    });
    steps.step("the user can ask to stop it again", |world, _, _| {
        let before = interrupts(world);
        stop_from_notice(world)?;
        expect!(interrupts(world) == before + 1, "{}", seen(world));
        Ok(())
    });
    steps.step(
        &format!("the task {Q} starts in the background"),
        |world, c, _| {
            let mut pending = world.mc.threads[THREAD]["pendingBackgroundTasks"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            pending.push(json!({"taskId": format!("task-{}", pending.len() + 1),
                                "description": c[0]}));
            update_thread_row(world, json!({"pendingBackgroundTasks": pending}));
            world.sync()?;
            // The stop still waits on the work it was asked for.
            expect!(notice(world)["busy"] == json!(true), "{}", seen(world));
            Ok(())
        },
    );
    steps.step(&format!("{Q} ends"), |world, c, _| {
        let pending: Vec<Json> = world.mc.threads[THREAD]["pendingBackgroundTasks"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|task| text(&task["description"]) != c[0])
            .collect();
        update_thread_row(world, json!({"pendingBackgroundTasks": pending}));
        Ok(())
    });
    steps.step(&format!("the notice offers Stop for {Q}"), |world, c, _| {
        let view = thread_view(world)?;
        let wanted = c[0].clone();
        world.wait_for_with(
            move |w| {
                let action = view.find(w, "threadNoticeAction").ok().flatten();
                action.is_some_and(|a| {
                    view.text_of(w, a, "text") == "Stop" && view.flag(w, a, "enabled")
                }) && view
                    .find(w, "threadNoticeDescription")
                    .ok()
                    .flatten()
                    .is_some_and(|d| view.text_of(w, d, "text") == wanted)
            },
            {
                let wanted = c[0].clone();
                move |w| format!("Stop for {wanted}; {}", seen(w))
            },
        )
    });
    steps.step("the environment rejects the stop", |world, _, _| {
        world.mc.refusals.insert(
            "run.interrupt".into(),
            "The provider session has already exited.".into(),
        );
        Ok(())
    });
    steps.step("the thread shows the reason as its error", |world, _, _| {
        world.mc.part::<ThreadErrorShown>().shown = true;
        error_shows(world, "The provider session has already exited.")
    });
    steps.step(&format!("the notice about {Q} stays"), |world, c, _| {
        // The error is in front of it now (the notice stack); the notice
        // itself stays, no longer busy, still naming the task.
        let wanted = c[0].clone();
        world.wait_for_with(
            move |w| {
                notice(w)["busy"] == json!(false)
                    && notice(w)["description"] == Json::from(wanted.as_str())
            },
            |w| seen(w),
        )?;
        let view = thread_view(world)?;
        let said = view
            .find(world, "threadNoticeDescription")?
            .map_or_else(String::new, |item| view.text_of(world, item, "text"));
        expect!(said == c[0], "{}", seen(world));
        Ok(())
    });
    steps.step(
        &format!("an earlier turn left the task {Q} running"),
        |world, c, _| {
            thread_view(world)?;
            leave_running(world, std::slice::from_ref(&c[0]));
            notice_says(world, "Waiting on background task")?;
            Ok(())
        },
    );
    steps.step(
        "that turn is older than the part of the thread the client has loaded",
        |world, _, _| {
            let key = format!("{}:{THREAD}", world.mc.environment_id);
            world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Home))?;
            use hal_c2_shell::controllers::threads::ThreadStore;
            world.with::<ThreadStore, _>(|s, engine| s.close(engine, &key))?;
            if let Some(cache) = hal_c2_shell::store::cache(world.engine()) {
                cache.forget_thread(&key);
            }
            world.sync()?;
            seed_turns(world, 12, 23)?;
            let run = world.mc.part::<FakeStreams>().run.clone();
            update_thread_row(world, json!({"latestRunId": run}));
            look(world, &key, true)?;
            let timeline = super::stream::timeline_object(world)?;
            let has_earlier = world.engine().read_by_name(timeline, "hasEarlier");
            let first = text(&role(world, 0, "text"));
            let rows = read(world, |t| t.row_count())?;
            expect!(
                has_earlier == Value::Bool(true) && first != "Question 1",
                "the thread opened whole: {rows} rows from \"{first}\""
            );
            notice_says(world, "Waiting on background task")?;
            Ok(())
        },
    );
    steps.step("the user stops the thread", |world, _, _| {
        stop_from_notice(world)
    });
    steps.step(&format!("{Q} is stopped"), |world, c, _| {
        update_thread_row(world, json!({"pendingBackgroundTasks": []}));
        world.wait_for_with(|w| w.state("threadNotice").is_null(), {
            let wanted = c[0].clone();
            move |w| format!("{wanted} to stop; {}", seen(w))
        })
    });
    steps.step(
        "a turn is running and has started background tasks",
        |world, _, _| {
            thread_view(world)?;
            update_thread_row(
                world,
                json!({"latestRunId": "run-1", "activeRunId": "run-1",
                       "status": "running",
                       "pendingBackgroundTasks":
                       [{"taskId": "task-1", "description": "watch tests"}]}),
            );
            Ok(())
        },
    );
    steps.step(
        "the thread shows no notice about background work",
        |world, _, _| {
            world.sync()?;
            let view = thread_view(world)?;
            let shown_item = view.find(world, "threadNotice")?;
            expect!(
                world.state("threadNotice").is_null()
                    && !shown_item.is_some_and(|item| view.flag(world, item, "visible")),
                "{}",
                seen(world)
            );
            Ok(())
        },
    );
    steps.step(
        "stopping the turn is the way to stop them",
        |world, _, _| {
            world.wait_for_with(
                |w| at(&w.state("turn"), "running") == &json!(true),
                |w| {
                    format!(
                        "the composer to offer stopping the turn; turn is {}",
                        show(&w.state("turn"))
                    )
                },
            )
        },
    );
}

fn register_errors(steps: &mut Steps) {
    steps.step(&format!("the thread shows the error {Q}"), |world, c, _| {
        thread_view(world)?;
        show_error(world, &c[0])
    });
    steps.step("the error is hidden for this thread", |world, _, _| {
        let view = thread_view(world)?;
        world.wait_for_with(
            move |w| {
                let banner = view.find(w, "threadError").ok().flatten();
                w.state("threadError").is_null()
                    && !banner.is_some_and(|item| view.flag(w, item, "visible"))
            },
            |w| seen(w),
        )?;
        // The MC's row still says it.
        expect!(
            !text(&world.mc.threads[THREAD]["lastError"]).is_empty(),
            "{}",
            seen(world)
        );
        Ok(())
    });
    steps.step(
        "a different error on the same thread is still shown",
        |world, _, _| show_error(world, "Provider crashed"),
    );
    steps.step(
        &format!("a later run of the thread (fails with {Q}|completes)"),
        |world, c, _| {
            let failed = !c[1].is_empty();
            update_thread_row(
                world,
                json!({"latestRunId": "run-later",
                       "status": if failed { "failed" } else { "completed" },
                       "lastError": if failed { Json::from(c[1].as_str()) } else { Json::Null }}),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the thread shows {Q} as its error"),
        |world, c, _| error_shows(world, &c[0]),
    );
    steps.step("the thread shows no error", |world, _, _| {
        let view = thread_view(world)?;
        world.wait_for_with(
            move |w| {
                let banner = view.find(w, "threadError").ok().flatten();
                w.state("threadError").is_null()
                    && !banner.is_some_and(|item| view.flag(w, item, "visible"))
            },
            |w| seen(w),
        )
    });
}

fn register_provider(steps: &mut Steps) {
    steps.step(
        &format!("the thread in {Q} runs on (Codex|Antigravity)(?: (\\d[\\d.]*))?"),
        |world, c, _| {
            let codex = c[1] == "Codex";
            run_on(
                world,
                if codex { "codex" } else { "antigravity" },
                &c[1],
                if c[2].is_empty() { "0.51.0" } else { &c[2] },
            )
        },
    );
    steps.step(
        "Codex (is not installed and HAL-C2 can install it|is signed out and HAL-C2 can sign it in|is signed out and can only be signed in from its own CLI|is unavailable)",
        |world, c, _| {
            if c[0].starts_with("is not installed") {
                report_provider(
                    world,
                    json!({"installed": false, "status": "error",
                           "auth": {"status": "unknown"},
                           "setup": {"canInstall": true}}),
                );
            } else if c[0].starts_with("is signed out") {
                report_provider(world, signed_out(c[0].contains("HAL-C2")));
            } else {
                report_provider(world, json!({"status": "error"}));
            }
            Ok(())
        },
    );
    steps.step("Codex ([\\d.]+) is known to be broken", |world, c, _| {
        report_provider(
            world,
            json!({"version": c[0],
                   "compatibilityAdvisory":
                   {"status": "broken",
                    "message": "Turns fail mid-run on this version. Use v0.51.0."}}),
        );
        Ok(())
    });
    steps.step(
        "Antigravity has not checked its saved sign-in since the environment restarted",
        |world, _, _| {
            report_provider(
                world,
                json!({"status": "warning", "auth": {"status": "unknown"},
                       "message": "Antigravity checks its sign-in when a session starts."}),
            );
            Ok(())
        },
    );
    steps.step(&format!("the thread shows {Q} with {Q}"), |world, c, _| {
        provider_notice_says(world, &c[0], &c[1])
    });
    steps.step(&format!("the thread warns {Q}"), |world, c, _| {
        provider_notice_says(world, &c[0], "")?;
        expect!(
            provider_notice(world)["warning"] == json!(true),
            "{}",
            show(&provider_notice(world))
        );
        Ok(())
    });
    steps.step(
        "the thread shows that Codex is signed out",
        |world, _, _| {
            run_on(world, "codex", "Codex", "0.51.0")?;
            report_provider(world, signed_out(true));
            provider_notice_says(world, "Codex is unauthenticated", "")
        },
    );
    steps.step(
        "the user opens provider setup from the thread",
        |world, _, _| {
            let view = thread_view(world)?;
            view.click(world, "providerNoticeSetup")
        },
    );
    steps.step("the setup for Codex opens", |world, _, _| {
        world.wait_for("Settings › Providers to open", |w| {
            w.with::<Navigation, _>(|n, _| {
                matches!(n.route(), Route::Settings(section) if section == PROVIDERS_SECTION)
            })
            .unwrap_or(false)
        })
    });
    steps.step(
        "Codex later becomes unavailable for another reason",
        |world, _, _| {
            report_provider(
                world,
                json!({"status": "error", "auth": {"status": "authenticated"},
                       "message": "Codex exited during startup."}),
            );
            Ok(())
        },
    );
    steps.step("the thread shows the new problem", |world, _, _| {
        provider_notice_says(
            world,
            "Codex provider status",
            "Codex exited during startup.",
        )
    });
    steps.step("no provider notice is shown", |world, _, _| {
        no_provider_notice(world)
    });
}

fn register_stack(steps: &mut Steps) {
    steps.step(
        &format!("the thread shows the error {Q} and the answer to {Q}"),
        |world, c, _| {
            expect!(c[1] == "/usage-limits", "{}", c[1]);
            stack_view(world)?;
            open_usage_limits_answer(world)?;
            show_error(world, &c[0])
        },
    );
    steps.step(
        "the error is the notice shown and the composer says there are other notices behind it",
        |world, _, _| {
            let view = stack_view(world)?;
            world.wait_for_with(
                move |w| {
                    drawn_in(w, view, "threadError")
                        && !drawn_in(w, view, "composerUsageLimits")
                        && drawn_in(w, view, "noticeStackPeek")
                        && stack(w)["front"] == json!("error")
                        && stack(w)["behind"].as_i64().unwrap_or(0) >= 1
                },
                |w| {
                    format!(
                        "the error in front, the answer behind it; {}",
                        stack_seen(w)
                    )
                },
            )?;
            expect!(
                view.shows(world, "1 other notice")?,
                "the peek does not say so; {}",
                stack_seen(world)
            );
            Ok(())
        },
    );
    steps.step("the user asks for the other notices", |world, _, _| {
        let view = stack_view(world)?;
        view.click(world, "noticeStackToggle")?;
        world.wait_for_with(|w| stack(w)["expanded"] == json!(true), |w| stack_seen(w))
    });
    steps.step(
        &format!("the answer to {Q} is shown as well"),
        |world, c, _| {
            expect!(c[0] == "/usage-limits", "{}", c[0]);
            let view = stack_view(world)?;
            world.wait_for_with(
                move |w| {
                    drawn_in(w, view, "composerUsageLimits") && drawn_in(w, view, "threadError")
                },
                |w| format!("the answer shown as well; {}", stack_seen(w)),
            )?;
            expect!(
                view.shows(world, "Usage limits")?,
                "the answer is not drawn; {}",
                stack_seen(world)
            );
            Ok(())
        },
    );
    steps.step("only the error is shown again", |world, _, _| {
        let view = stack_view(world)?;
        world.wait_for_with(
            move |w| {
                drawn_in(w, view, "threadError")
                    && !drawn_in(w, view, "composerUsageLimits")
                    && stack(w)["expanded"] != json!(true)
                    && stack(w)["front"] == json!("error")
            },
            |w| format!("only the error again; {}", stack_seen(w)),
        )
    });
    steps.step(
        &format!("the answer to {Q} is the notice shown"),
        |world, c, _| {
            expect!(c[0] == "/usage-limits", "{}", c[0]);
            let view = stack_view(world)?;
            world.wait_for_with(
                move |w| {
                    drawn_in(w, view, "composerUsageLimits")
                        && !drawn_in(w, view, "threadError")
                        && stack(w)["front"] == json!("usageLimits")
                },
                |w| format!("the answer in front; {}", stack_seen(w)),
            )
        },
    );
    steps.step(
        "the composer no longer says there are other notices",
        |world, _, _| {
            let view = stack_view(world)?;
            world.wait_for_with(
                move |w| {
                    !drawn_in(w, view, "noticeStackPeek")
                        && stack(w)["behind"].as_i64().unwrap_or(0) == 0
                },
                |w| stack_seen(w),
            )
        },
    );
    steps.step(
        "the user dismisses the error and at once opens another thread",
        |world, _, _| {
            let other = json!({"id": "thread-2", "title": "Other work",
                               "projectId": PROJECT,
                               "createdAt": "2026-09-23T09:00:00Z",
                               "updatedAt": "2026-09-23T09:00:00Z"});
            world.mc.threads.insert("thread-2".into(), other.clone());
            world.mc.send_row("thread-2", &other);
            // No wait between the dismiss and the switch: the error going
            // away must not be undone by leaving.
            let view = thread_view(world)?;
            view.click(world, "threadErrorDismiss")?;
            let key = format!("{}:thread-2", world.mc.environment_id);
            world.with::<Navigation, _>(|n, engine| {
                n.open(engine, Route::Thread(key.clone()));
            })?;
            world.wait_for("the other thread to open", |w| {
                w.with::<Navigation, _>(
                    |n, _| matches!(n.route(), Route::Thread(k) if k.ends_with("thread-2")),
                )
                .unwrap_or(false)
            })
        },
    );
    steps.step("the user comes back to the thread", |world, _, _| {
        let key = format!("{}:{THREAD}", world.mc.environment_id);
        world.with::<Navigation, _>(|n, engine| {
            n.open(engine, Route::Thread(key.clone()));
        })?;
        world.wait_for("the thread to open again", |w| {
            w.with::<Navigation, _>(
                |n, _| matches!(n.route(), Route::Thread(k) if k.ends_with(THREAD)),
            )
            .unwrap_or(false)
        })
    });
    steps.step("the error is not shown", |world, _, _| {
        let view = thread_view(world)?;
        world.wait_for_with(
            move |w| {
                let banner = view.find(w, "threadError").ok().flatten();
                w.state("threadError").is_null()
                    && !banner.is_some_and(|item| view.flag(w, item, "visible"))
            },
            |w| seen(w),
        )?;
        expect!(
            !text(&world.mc.threads[THREAD]["lastError"]).is_empty(),
            "{}",
            seen(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the thread says it is waiting on the background work {Q}"),
        |world, c, _| {
            stack_view(world)?;
            leave_running(world, std::slice::from_ref(&c[0]));
            world.wait_for_with(|w| notice(w)["kind"] == json!("background"), |w| seen(w))
        },
    );
    steps.step(
        "the thread shows a usage limit with its recovery actions",
        |world, _, _| {
            stack_view(world)?;
            stop_on_limit(world)
        },
    );
    steps.step(
        "a usage limit with its recovery actions is the notice shown",
        |world, _, _| {
            let view = stack_view(world)?;
            world.wait_for_with(
                move |w| {
                    drawn_in(w, view, "limitRecovery")
                        && drawn_in(w, view, "limitRecoveryResume")
                        && stack(w)["front"] == json!("limit")
                },
                |w| format!("the usage limit in front; {}", stack_seen(w)),
            )
        },
    );
    steps.step(
        &format!("the error {Q} is the notice shown"),
        |world, c, _| {
            let view = stack_view(world)?;
            let wanted = c[0].clone();
            world.wait_for_with(
                move |w| {
                    drawn_in(w, view, "threadError")
                        && view
                            .find(w, "threadErrorMessage")
                            .ok()
                            .flatten()
                            .is_some_and(|m| view.text_of(w, m, "text") == wanted)
                        && stack(w)["front"] == json!("error")
                },
                {
                    let _ = &c;
                    move |w| format!("the error in front; {}", stack_seen(w))
                },
            )
        },
    );
    steps.step(
        "the notice about what the agent is doing waits behind it",
        |world, _, _| {
            let view = stack_view(world)?;
            world.wait_for_with(
                move |w| {
                    let order = stack(w)["order"].as_array().cloned().unwrap_or_default();
                    notice(w)["kind"] == json!("background")
                        && !drawn_in(w, view, "threadNotice")
                        && order.len() > 1
                        && order.last() == Some(&json!("activity"))
                        && drawn_in(w, view, "noticeStackPeek")
                },
                |w| format!("the activity notice behind; {}", stack_seen(w)),
            )
        },
    );
}

pub fn register(steps: &mut Steps) {
    register_background(steps);
    register_errors(steps);
    register_provider(steps);
    register_stack(steps);
}
