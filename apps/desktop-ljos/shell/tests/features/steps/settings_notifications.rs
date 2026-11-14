//! Thread notifications as this device's settings shape them: the mode
//! chosen in Settings → General, the system's permission, what each
//! notification says, and the app's badge (desktop-qt's
//! SettingsNotificationsSteps.cpp; features/settings/notifications.feature).
//! The platform's notification service is alert.rs's fake.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::settings::Settings;
use ljos::prelude::Value as JsValue;
use serde_json::{Value, json};

use super::alert::{alerts_seen, click_notification, set_alert_focus, set_alerts_allowed};
use super::settings_rows::{choose_row, page_item, row_text, turn_row};
use crate::expect;
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::steps::stream::iso;
use crate::world::World;

const PROJECT: &str = "shop";

#[derive(Default)]
struct Notified {
    raised: Rc<RefCell<Vec<String>>>,
    runs: u32,
}

fn id_of(title: &str) -> String {
    format!("thread-{}", title.to_lowercase().replace(' ', "-"))
}

fn key_of(world: &World, title: &str) -> String {
    format!("{}:{}", world.mc.environment_id, id_of(title))
}

fn mode(world: &World) -> Value {
    Settings::of(world.engine())
        .setting(world.engine(), "notificationMode")
        .unwrap_or(Value::Null)
}

fn send(world: &mut World, title: &str) -> Outcome {
    let id = id_of(title);
    let row = world.mc.threads.get(&id).cloned().unwrap_or(Value::Null);
    world.mc.send_row(&id, &row);
    world.sync()
}

/// A thread with a run under way.
fn start(world: &mut World, title: &str) -> Outcome {
    let at = iso(world.now());
    let run = {
        let notified = world.mc.part::<Notified>();
        notified.runs += 1;
        notified.runs
    };
    world.mc.threads.insert(
        id_of(title),
        json!({"id": id_of(title), "title": title, "projectId": PROJECT,
            "createdAt": at, "updatedAt": at, "latestRunId": format!("run-{run}"),
            "latestRunStartedAt": at, "status": "running"}),
    );
    send(world, title)
}

/// What the MC's row says when the thread's run ends or waits on the user.
fn happen(world: &mut World, title: &str, event: &str) -> Outcome {
    let later = world.now() + chrono::Duration::seconds(60);
    world.set_time(later);
    let at = iso(world.now());
    let Some(row) = world
        .mc
        .threads
        .get_mut(&id_of(title))
        .and_then(Value::as_object_mut)
    else {
        return Err(Failure(format!("no thread \"{title}\" was started")));
    };
    row.insert("updatedAt".into(), json!(at));
    match event {
        "finishes" => {
            row.insert("status".into(), json!("completed"));
            row.insert("latestRunCompletedAt".into(), json!(at));
        }
        "asks for approval" => {
            row.insert(
                "pendingRuntimeRequest".into(),
                json!({"kind": "command_approval"}),
            );
        }
        "asks a question" => {
            row.insert(
                "pendingRuntimeRequest".into(),
                json!({"kind": "user_input"}),
            );
        }
        _ => {
            row.insert("status".into(), json!("failed"));
            row.insert("latestRunCompletedAt".into(), json!(at));
            let class = if event == "fails" {
                "provider_error"
            } else {
                "usage_limit"
            };
            row.insert("lastErrorClass".into(), json!(class));
        }
    }
    send(world, title)
}

fn toasts(world: &World) -> Vec<Value> {
    world.state("toasts")["items"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn describe(world: &mut World) -> String {
    let Ok(seen) = alerts_seen(world) else {
        return "the alerts are unavailable".into();
    };
    let shown: serde_json::Map<String, Value> = seen
        .shown
        .iter()
        .map(|(key, (title, body))| (key.clone(), json!([title, body])))
        .collect();
    format!(
        "toasts {}, system notifications {}, sounds [{}], badge {}, mode {}",
        show(&Value::Array(toasts(world))),
        show(&Value::Object(shown)),
        seen.sounds.join(","),
        seen.badge,
        show(&mode(world))
    )
}

/// The window is somewhere else while `title` finishes, with system
/// notifications on.
fn notify_in_background(world: &mut World, title: &str) -> Outcome {
    if !world.mc.threads.contains_key(&id_of(title)) {
        start(world, title)?;
    }
    if text(&mode(world)) == "off" {
        choose_row(world, "notificationMode", "Notifications only")?;
    }
    set_alert_focus(world, false)?;
    happen(world, title, "finishes")?;
    let key = key_of(world, title);
    let seen = alerts_seen(world)?;
    expect!(seen.shown.contains_key(&key), "{}", describe(world));
    Ok(())
}

fn open_thread(world: &mut World, title: &str) -> Outcome {
    let key = key_of(world, title);
    world
        .with::<Navigation, _>(|navigation, engine| navigation.open(engine, Route::Thread(key)))?;
    world.pump()
}

fn shown_thread(world: &mut World) -> Outcome<String> {
    world.with::<Navigation, _>(|navigation, _| navigation.thread_key().to_owned())
}

pub fn register(steps: &mut Steps) {
    steps.step(&format!("the user has a thread {Q}"), |world, c, _| {
        world.mc.projects.insert(
            PROJECT.into(),
            json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": "/work/shop", "scripts": []}),
        );
        world.connect()?;
        world.sync()?;
        alerts_seen(world)?;
        start(world, &c[0])
    });

    // The mode, as Settings → General's list sets it.
    steps.step(&format!("the notification mode is {Q}"), |world, c, _| {
        if c[0] == "Off" {
            expect!(text(&mode(world)) == "off", "{}", describe(world));
            // Still following the thread, so only the mode keeps it quiet.
            return turn_row(world, "inAppNotificationsEnabled", true);
        }
        choose_row(world, "notificationMode", &c[0])
    });
    steps.step("HAL-C2 is in the background", |world, _, _| {
        set_alert_focus(world, false)
    });
    steps.step(
        &format!("{Q} (finishes|fails|asks for approval|asks a question|hits its usage limit)"),
        |world, c, _| {
            // An archived thread's scenario says nothing of how the user is
            // told: every way is on, in the background.
            let archived = world
                .mc
                .threads
                .get(&id_of(&c[0]))
                .is_some_and(|row| row.get("archivedAt").is_some());
            if archived {
                turn_row(world, "inAppNotificationsEnabled", true)?;
                choose_row(world, "notificationMode", "Notifications with sound")?;
                set_alert_focus(world, false)?;
            }
            happen(world, &c[0], &c[1])
        },
    );
    steps.step("nothing is shown or played", |world, _, _| {
        let seen = alerts_seen(world)?;
        expect!(
            seen.shown.is_empty() && seen.sounds.is_empty() && toasts(world).is_empty(),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        &format!("a system notification {Q} is shown"),
        |world, c, _| {
            let seen = alerts_seen(world)?;
            expect!(
                seen.shown.len() == 1
                    && seen
                        .shown
                        .values()
                        .next()
                        .is_some_and(|(title, _)| *title == c[0])
                    && seen.sounds.is_empty(),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the completion sound plays", |world, _, _| {
        let seen = alerts_seen(world)?;
        expect!(
            seen.sounds == ["completion"] && seen.shown.is_empty(),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "a system notification is shown and the sound plays",
        |world, _, _| {
            let seen = alerts_seen(world)?;
            expect!(
                seen.shown.len() == 1 && seen.sounds == ["completion"],
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    // The system's permission.
    steps.step("the system has not allowed notifications", |world, _, _| {
        set_alerts_allowed(world, false)
    });
    steps.step(
        "the user chooses notifications only and the system refuses",
        |world, _, _| {
            expect!(text(&mode(world)) == "off", "{}", describe(world));
            // Picked in the list, as choose_row does, but the setting does
            // not stay.
            let control = page_item(world, "settingsRow:notificationMode", "control")?;
            world
                .engine()
                .emit_by_name(control, "activated", &[JsValue::from(1)])
                .map_err(|e| Failure(format!("activated: {e:?}")))?;
            world.sync()
        },
    );
    steps.step("the notification mode is unchanged", |world, _, _| {
        let row = row_text(world, "notificationMode")?;
        expect!(
            text(&mode(world)) == "off" && row == "Off",
            "the row reads \"{row}\"; {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user is told to allow notifications and that sound only is still available",
        |world, _, _| {
            let told = toasts(world).iter().any(|toast| {
                let text = text(at(toast, "description"));
                text.starts_with("Allow notifications")
                    && text.ends_with("Sound only is still available.")
            });
            expect!(told, "{}", describe(world));
            Ok(())
        },
    );

    // What a notification says, and clicking it.
    steps.step(
        &format!("a system notification titled {Q} names {Q}"),
        |world, c, _| {
            let key = key_of(world, &c[1]);
            let seen = alerts_seen(world)?;
            expect!(
                seen.shown
                    .get(&key)
                    .is_some_and(|(title, body)| *title == c[0] && *body == c[1]),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("a system notification for {Q} is shown"),
        |world, c, _| {
            notify_in_background(world, &c[0])?;
            let shown = shown_thread(world)?;
            expect!(shown != key_of(world, &c[0]), "the thread is already shown");
            Ok(())
        },
    );
    steps.step("the user clicks it", |world, _, _| {
        let Some(key) = alerts_seen(world)?.shown.keys().next().cloned() else {
            return Err(Failure("no system notification is shown".into()));
        };
        let raised = world.mc.part::<Notified>().raised.clone();
        let opened = click_notification(world, &key, Some(&raised))?;
        expect!(opened, "the click opened nothing");
        world.sync()
    });
    steps.step(
        &format!("HAL-C2 comes to the front showing {Q}"),
        |world, c, _| {
            let shown = shown_thread(world)?;
            let raised = world.mc.part::<Notified>().raised.borrow().clone();
            expect!(
                shown == key_of(world, &c[0]) && raised.len() == 1,
                "the window shows \"{shown}\"; raised: {}",
                raised.join(", ")
            );
            Ok(())
        },
    );

    // In front.
    steps.step("in-app notifications are on", |world, _, _| {
        turn_row(world, "inAppNotificationsEnabled", true)?;
        // System notifications too, so only being in front keeps them away.
        choose_row(world, "notificationMode", "Notifications only")
    });
    steps.step(
        "HAL-C2 is in front showing another thread",
        |world, _, _| {
            start(world, "Other work")?;
            open_thread(world, "Other work")?;
            set_alert_focus(world, true)
        },
    );
    steps.step(&format!("HAL-C2 is in front showing {Q}"), |world, c, _| {
        open_thread(world, &c[0])?;
        set_alert_focus(world, true)
    });
    steps.step(
        "a toast says the thread completed and offers to open it",
        |world, _, _| {
            let shown = toasts(world);
            expect!(
                shown.len() == 1
                    && text(at(&shown[0], "title")) == "Thread completed"
                    && text(at(&shown[0], "description")) == "Fix login"
                    && text(&shown[0]["actions"][0]["label"]) == "Open thread",
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("no toast or notification is shown", |world, _, _| {
        let seen = alerts_seen(world)?;
        expect!(
            toasts(world).is_empty() && seen.shown.is_empty(),
            "{}",
            describe(world)
        );
        Ok(())
    });

    // Archived threads ("is archived" is ArchivedThreadsSteps').
    steps.step("no notification is shown", |world, _, _| {
        let seen = alerts_seen(world)?;
        expect!(
            seen.shown.is_empty() && seen.sounds.is_empty() && toasts(world).is_empty(),
            "{}",
            describe(world)
        );
        // A subagent's thread is as quiet, where another thread's finish is
        // told.
        start(world, "Helper")?;
        if let Some(row) = world
            .mc
            .threads
            .get_mut(&id_of("Helper"))
            .and_then(Value::as_object_mut)
        {
            row.insert(
                "lineage".into(),
                json!({"parentThreadId": id_of("Fix login"), "relationshipToParent": "subagent"}),
            );
        }
        send(world, "Helper")?;
        happen(world, "Helper", "finishes")?;
        let seen = alerts_seen(world)?;
        expect!(seen.shown.is_empty(), "{}", describe(world));
        start(world, "Other work")?;
        happen(world, "Other work", "finishes")?;
        let other = key_of(world, "Other work");
        let seen = alerts_seen(world)?;
        expect!(seen.shown.keys().eq([&other]), "{}", describe(world));
        Ok(())
    });

    // The badge.
    steps.step("two system notifications are waiting", |world, _, _| {
        notify_in_background(world, "Fix login")?;
        notify_in_background(world, "Other work")?;
        let seen = alerts_seen(world)?;
        expect!(seen.shown.len() == 2, "{}", describe(world));
        Ok(())
    });
    steps.step(r"the app shows a badge of (\d+)", |world, c, _| {
        let seen = alerts_seen(world)?;
        expect!(
            seen.badge == c[0].parse::<i64>().unwrap_or(-2),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the user brings HAL-C2 to the front", |world, _, _| {
        set_alert_focus(world, true)
    });
    steps.step(
        "the notifications are dismissed and the badge is cleared",
        |world, _, _| {
            let seen = alerts_seen(world)?;
            expect!(
                seen.shown.is_empty() && seen.closed.len() == 2 && seen.badge == 0,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
}
