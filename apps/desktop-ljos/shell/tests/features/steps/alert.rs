//! Alerts when a thread needs the user (desktop-qt's AlertSteps.cpp;
//! features/timeline/notifications.feature): threads whose rows the MC
//! changes, the window's focus, and a fake of the platform's notification
//! service, sound and badge in place of the desktop's.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::alerts::{AlertController, Presenter, TOGGLE_MUTE};
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::settings::Settings;
use ljos::prelude::{BadgeService, Platform};
use serde_json::{Value, json};

use super::add_project as palette;
use super::move_;
use super::stream::{self, iso};
use super::thread_menu::view;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

/// A thread the steps drive, and where its rows come from.
#[derive(Clone, Default)]
struct Tracked {
    /// Another MC of the cluster that serves it; empty: the MC's own.
    peer: String,
    id: String,
    row: Value,
    runs: u32,
}

/// What the platform was told, and what it lets through.
struct Platformed {
    focused: bool,
    allowed: bool,
    enabled: bool,
    /// The system notifications on screen, by thread key: {title, body}.
    shown: BTreeMap<String, (String, String)>,
    /// Every one shown, and the keys of those no longer on screen but still
    /// clickable.
    delivered: Vec<String>,
    closed: Vec<String>,
    sounds: Vec<String>,
    /// What the dock or taskbar badge counts; -1 before it was ever set.
    badge: i64,
}

impl Default for Platformed {
    fn default() -> Self {
        Platformed {
            focused: true,
            allowed: true,
            enabled: false,
            shown: BTreeMap::new(),
            delivered: Vec::new(),
            closed: Vec::new(),
            sounds: Vec::new(),
            badge: -1,
        }
    }
}

type Shared = Rc<RefCell<Platformed>>;

struct Fake(Shared);

impl Presenter for Fake {
    fn show(&self, key: &str, title: &str, body: &str, _silent: bool) -> bool {
        let mut state = self.0.borrow_mut();
        if !state.enabled || !state.allowed {
            return false;
        }
        state
            .shown
            .insert(key.to_owned(), (title.to_owned(), body.to_owned()));
        state.delivered.push(key.to_owned());
        true
    }
    fn clear(&self) {
        let mut state = self.0.borrow_mut();
        let keys: Vec<String> = state.shown.keys().cloned().collect();
        state.closed.extend(keys);
        state.shown.clear();
    }
    fn set_enabled(&self, enabled: bool) {
        self.0.borrow_mut().enabled = enabled;
        if !enabled {
            self.clear();
        }
    }
    fn play(&self, kind: &str) {
        self.0.borrow_mut().sounds.push(kind.to_owned());
    }
    fn permitted(&self) -> Option<bool> {
        Some(self.0.borrow().allowed)
    }
}

impl BadgeService for Fake {
    fn show(&self, count: u32) {
        self.0.borrow_mut().badge = i64::from(count);
    }
}

#[derive(Default)]
struct FakeAlerts {
    platform: Shared,
    /// By title.
    threads: BTreeMap<String, Tracked>,
    /// The title the last steps were about.
    current: String,
    /// The id of the last in-app alert.
    last_toast: String,
}

fn fake(world: &mut World) -> &mut FakeAlerts {
    world.mc.part::<FakeAlerts>()
}

/// What the platform was told.
pub struct AlertsSeen {
    pub shown: BTreeMap<String, (String, String)>,
    pub closed: Vec<String>,
    pub sounds: Vec<String>,
    pub badge: i64,
}

/// Puts the fake platform on the shell's alerts. Done on every step: a
/// restarted shell has a new controller.
fn alerts(world: &mut World) -> Outcome {
    let shared = fake(world).platform.clone();
    let focused = shared.borrow().focused;
    let presenter: Rc<dyn Presenter> = Rc::new(Fake(shared.clone()));
    world.with::<AlertController, _>(|controller, engine| {
        Platform::of(engine).set_badge(Rc::new(Fake(shared.clone())));
        controller.set_presenter(presenter);
        controller.set_focused(engine, focused);
    })?;
    world.pump()
}

/// Whether the window has the user's attention.
pub fn set_alert_focus(world: &mut World, focused: bool) -> Outcome {
    fake(world).platform.borrow_mut().focused = focused;
    alerts(world)
}

/// Whether the system lets the app notify.
pub fn set_alerts_allowed(world: &mut World, allowed: bool) -> Outcome {
    fake(world).platform.borrow_mut().allowed = allowed;
    alerts(world)
}

pub fn alerts_seen(world: &mut World) -> Outcome<AlertsSeen> {
    alerts(world)?;
    let state = fake(world).platform.borrow();
    Ok(AlertsSeen {
        shown: state.shown.clone(),
        closed: state.closed.clone(),
        sounds: state.sounds.clone(),
        badge: state.badge,
    })
}

/// Clicks the system notification for thread `key`; `raised` gets the
/// window commands asked of the window. False when the click opens nothing.
pub fn click_notification(
    world: &mut World,
    key: &str,
    raised: Option<&Rc<RefCell<Vec<String>>>>,
) -> Outcome<bool> {
    alerts(world)?;
    if let Some(raised) = raised {
        let raised = raised.clone();
        let bridge = Bridge::of(world.engine()).object();
        let _ = world.engine().connect_by_name(
            bridge,
            "windowCommandRequested",
            move |engine, args| {
                raised
                    .borrow_mut()
                    .push(engine.to_js_string(&args[0]).to_string());
            },
        );
    }
    let opened = world
        .with::<AlertController, _>(|controller, engine| controller.open_thread(engine, key))?;
    world.pump()?;
    Ok(opened)
}

/// Alerts are on and the window is somewhere else, so what a thread does
/// next reaches the user as a system notification.
pub fn await_system_notifications(world: &mut World) -> Outcome {
    set_setting(world, "inAppNotificationsEnabled", json!(true));
    set_setting(world, "notificationMode", json!("notifications-and-sound"));
    fake(world).platform.borrow_mut().focused = false;
    alerts(world)
}

/// The keys of the threads a system notification was shown for, oldest first.
pub fn system_notifications(world: &mut World) -> Vec<String> {
    fake(world).platform.borrow().delivered.clone()
}

/// The user clicks the system notification about the thread `key`; whether
/// it opened anything.
pub fn click_system_notification(world: &mut World, key: &str) -> Outcome<bool> {
    click_notification(world, key, None)
}

fn set_setting(world: &mut World, key: &str, value: Value) {
    let engine = world.engine().clone();
    Settings::of(&engine).set(&engine, key, value);
}

fn key_of(world: &mut World, thread: &Tracked) -> String {
    let environment = if thread.peer.is_empty() {
        world.mc.environment_id.clone()
    } else {
        world
            .mc
            .peers
            .iter()
            .find(|(_, peer)| **peer == thread.peer)
            .map(|(environment, _)| environment.clone())
            .unwrap_or_default()
    };
    format!("{environment}:{}", thread.id)
}

fn send(world: &mut World, thread: &Tracked) -> Outcome {
    if thread.peer.is_empty() {
        world
            .mc
            .threads
            .insert(thread.id.clone(), thread.row.clone());
        world.mc.send_row(&thread.id, &thread.row);
    } else {
        world
            .mc
            .send_rows(&thread.peer, vec![json!([thread.id, "thread", thread.row])]);
    }
    world.sync()?;
    alerts(world)
}

fn tracked(world: &mut World, title: &str) -> Outcome<Tracked> {
    let state = fake(world);
    let Some(thread) = state.threads.get(title).cloned() else {
        fail!("no thread \"{title}\" was started");
    };
    state.current = title.to_owned();
    Ok(thread)
}

/// A thread with a run under way, in the Background's project.
fn working(world: &mut World, title: &str, peer: &str) -> Outcome<Tracked> {
    alerts(world)?;
    let started = iso(world.now());
    let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
    let state = fake(world);
    let thread = state.threads.entry(title.to_owned()).or_default();
    thread.peer = peer.to_owned();
    thread.id = format!("thread-{}", title.to_lowercase().replace(' ', "-"));
    thread.runs += 1;
    thread.row = json!({"id": thread.id, "title": title, "projectId": project,
        "createdAt": started, "updatedAt": started,
        "latestRunId": format!("run-{}", thread.runs), "latestRunStartedAt": started,
        "status": "running"});
    let thread = thread.clone();
    state.current = title.to_owned();
    send(world, &thread)?;
    Ok(thread)
}

/// The thread does `what` a minute later.
fn change(world: &mut World, title: &str, what: &str) -> Outcome {
    let mut thread = tracked(world, title)?;
    let later = world.now() + chrono::Duration::seconds(60);
    world.set_time(later);
    let at = iso(world.now());
    {
        let row = thread.row.as_object_mut().expect("a row is an object");
        row.insert("updatedAt".into(), json!(at));
        row.remove("pendingRuntimeRequest");
        match what {
            "completes" => {
                row.insert("status".into(), json!("completed"));
                row.insert("latestRunCompletedAt".into(), json!(at));
            }
            "asks for approval" => {
                row.insert(
                    "pendingRuntimeRequest".into(),
                    json!({"kind": "command_approval"}),
                );
            }
            "asks the user a question" => {
                row.insert(
                    "pendingRuntimeRequest".into(),
                    json!({"kind": "user_input"}),
                );
            }
            "fails" | "stops at the provider's usage limit" => {
                row.insert("status".into(), json!("failed"));
                row.insert("latestRunCompletedAt".into(), json!(at));
                let class = if what == "fails" {
                    "provider_error"
                } else {
                    "usage_limit"
                };
                row.insert("lastErrorClass".into(), json!(class));
            }
            _ => fail!("no change \"{what}\""),
        }
    }
    fake(world).threads.insert(title.to_owned(), thread.clone());
    send(world, &thread)
}

fn toasts(world: &World) -> Vec<Value> {
    world.state("toasts")["items"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// The in-app alert about `title`, if one is shown.
fn toast_for(world: &World, title: &str) -> Option<Value> {
    toasts(world)
        .into_iter()
        .find(|toast| text(&toast["description"]) == title)
}

fn describe(world: &mut World) -> String {
    let toasts = show(&Value::Array(toasts(world)));
    let state = fake(world).platform.borrow();
    let shown: serde_json::Map<String, Value> = state
        .shown
        .iter()
        .map(|(key, (title, body))| (key.clone(), json!([title, body])))
        .collect();
    format!(
        "toasts {toasts}, system notifications {}, sounds {}",
        show(&Value::Object(shown)),
        state.sounds.join(",")
    )
}

fn set_mode(world: &mut World, mode: &str) -> Outcome {
    set_setting(world, "notificationMode", json!(mode));
    alerts(world)
}

fn mode_of(label: &str) -> Option<&'static str> {
    Some(match label {
        "Off" => "off",
        "Notifications only" => "notifications",
        "Sound only" => "sound",
        "Notifications with sound" => "notifications-and-sound",
        _ => return None,
    })
}

/// The window is somewhere else while `title` completes.
fn completes_in_background(world: &mut World, title: &str) -> Outcome {
    fake(world).platform.borrow_mut().focused = false;
    alerts(world)?;
    working(world, title, "")?;
    change(world, title, "completes")
}

fn thread_key(world: &World) -> String {
    world
        .with::<Navigation, _>(|navigation, _| navigation.thread_key().to_owned())
        .unwrap_or_default()
}

/// Mutes or unmutes `title` from the palette while it is shown, then leaves
/// it for the usage page so its alerts are not the shown thread's.
fn toggle_mute_from_palette(world: &mut World, title: &str, mute: bool) -> Outcome {
    let thread = tracked(world, title)?;
    let key = key_of(world, &thread);
    view(world, &key)?;
    world.sync()?;
    palette::invoke(world, "show", &[])?;
    palette::set_query(world, "alerts")?;
    world.wait_for("the palette to settle", |w| !palette::searching(w))?;
    let wanted = if mute {
        "Mute alerts for this thread"
    } else {
        "Unmute alerts for this thread"
    };
    let row = (0..palette::count(world)).find(|&row| {
        palette::id_at(world, row) == TOGGLE_MUTE
            && palette::role_text(world, row, "title") == wanted
    });
    let Some(row) = row else {
        fail!(
            "the palette offers no \"{wanted}\": {}",
            palette::describe(world)
        );
    };
    palette::invoke_ok(world, "run", &[ljos::prelude::Value::Int(row as i32)])?;
    world.sync()?;
    let muted = world.with::<AlertController, _>(|controller, _| controller.is_muted(&key))?;
    expect!(
        muted == mute,
        "{title} is {}",
        if muted { "muted" } else { "not muted" }
    );
    world.with::<Navigation, _>(|navigation, engine| {
        navigation.open(engine, Route::Settings("usage".to_owned()))
    })?;
    world.sync()
}

pub fn register(steps: &mut Steps) {
    // The shell's own alerts with the window out of focus
    // (timeline/qt-shell-backlog.feature). AlertController hands them to the
    // platform's notification service and badge itself (the Presenter):
    // nothing else is installed.
    fn in_background(world: &mut World) -> Outcome {
        if world.shell_subscriptions() == 0 {
            world.mc.projects.insert(
                "shop".to_owned(),
                json!({"id": "shop", "title": "shop", "workspaceRoot": "/work/shop",
                    "scripts": []}),
            );
            world.connect()?;
            world.sync()?;
        }
        set_mode(world, "notifications")?;
        fake(world).platform.borrow_mut().focused = false;
        alerts(world)
    }
    fn two_finish(world: &mut World) -> Outcome {
        working(world, "Tax fix", "")?;
        change(world, "Tax fix", "completes")?;
        working(world, "Cart tests", "")?;
        change(world, "Cart tests", "completes")
    }

    steps.step(
        "the native desktop shell has no notification extension installed",
        |world, _, _| {
            // Nothing but the shell's own presenter is there to deliver a
            // notification.
            let empty = {
                let state = fake(world).platform.borrow();
                state.shown.is_empty() && state.delivered.is_empty()
            };
            expect!(
                empty,
                "a notification is already shown: {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the app is in the background", |world, _, _| {
        in_background(world)
    });
    steps.step("a turn finishes", |world, _, _| {
        working(world, "Tax fix", "")?;
        change(world, "Tax fix", "completes")
    });
    steps.step("an operating system notification arrives", |world, _, _| {
        let thread = fake(world)
            .threads
            .get("Tax fix")
            .cloned()
            .unwrap_or_default();
        let key = key_of(world, &thread);
        let told = fake(world).platform.borrow().shown.get(&key).cloned();
        let none = toasts(world).is_empty();
        expect!(
            told == Some(("Thread completed".to_owned(), "Tax fix".to_owned())) && none,
            "the user sees {}",
            describe(world)
        );
        Ok(())
    });
    steps.step("two turns finish", |world, _, _| two_finish(world));
    steps.step(r"the dock or taskbar badge shows (\d+)", |world, c, _| {
        // As a precondition: that many turns finished while the app was
        // away.
        if !world.checking {
            in_background(world)?;
            two_finish(world)?;
        }
        let badge = fake(world).platform.borrow().badge;
        expect!(
            badge == c[0].parse::<i64>().unwrap_or(-2),
            "the badge shows {badge}"
        );
        Ok(())
    });
    steps.step("the user returns to the app", |world, _, _| {
        fake(world).platform.borrow_mut().focused = true;
        alerts(world)
    });
    steps.step("the badge is cleared", |world, _, _| {
        let badge = fake(world).platform.borrow().badge;
        expect!(badge == 0, "the badge shows {badge}");
        // A turn that finishes while the user is here is not counted.
        working(world, "Docs", "")?;
        change(world, "Docs", "completes")?;
        let badge = fake(world).platform.borrow().badge;
        expect!(
            badge == 0,
            "the badge shows {badge} with the window in front"
        );
        Ok(())
    });

    steps.step("the user has alerts turned on", |world, _, _| {
        set_setting(world, "inAppNotificationsEnabled", json!(true));
        set_setting(world, "notificationMode", json!("notifications-and-sound"));
        alerts(world)
    });
    steps.step(&format!("alerts are set to {Q}"), |world, c, _| {
        let Some(mode) = mode_of(&c[0]) else {
            fail!("no alert setting \"{}\"", c[0]);
        };
        set_mode(world, mode)
    });
    steps.step("the user turns system notifications off", |world, _, _| {
        set_mode(world, "off")
    });
    steps.step(
        "the operating system has not allowed notifications",
        |world, _, _| {
            fake(world).platform.borrow_mut().allowed = false;
            alerts(world)
        },
    );
    steps.step("the user comes back to the window", |world, _, _| {
        fake(world).platform.borrow_mut().focused = true;
        alerts(world)
    });

    steps.step(
        &format!("the thread {Q} is working in the background"),
        |world, c, _| working(world, &c[0], "").map(drop),
    );
    steps.step(
        &format!("the thread {Q} is working in the background on another MC of the cluster"),
        |world, c, _| {
            world.mc.join(stream::PEER, stream::PEER_ENVIRONMENT);
            world.sync()?;
            working(world, &c[0], stream::PEER).map(drop)
        },
    );
    steps.step(
        "the thread (completes|asks for approval|asks the user a question|fails|stops at the provider's usage limit)",
        |world, c, _| {
            let current = fake(world).current.clone();
            change(world, &current, &c[0])
        },
    );
    steps.step(
        &format!("{Q} (completes|then asks for approval)"),
        |world, c, _| {
            if !fake(world).threads.contains_key(&c[0]) {
                working(world, &c[0], "")?;
            }
            let what = if c[1] == "completes" {
                "completes"
            } else {
                "asks for approval"
            };
            change(world, &c[0], what)
        },
    );
    steps.step("a background thread completes", |world, _, _| {
        completes_in_background(world, "Tax fix")
    });
    steps.step(
        &format!("{Q} completed while the client was closed"),
        |world, c, _| {
            working(world, &c[0], "")?;
            world.restart()?;
            // Closed: the MC's row changes with nobody to tell.
            world.mc.drop_connection();
            let mut thread = tracked(world, &c[0])?;
            let completed = iso(world.now() + chrono::Duration::seconds(60));
            let row = thread.row.as_object_mut().expect("a row is an object");
            row.insert("status".into(), json!("completed"));
            row.insert("latestRunCompletedAt".into(), json!(completed));
            world
                .mc
                .threads
                .insert(thread.id.clone(), thread.row.clone());
            fake(world).threads.insert(c[0].clone(), thread);
            Ok(())
        },
    );
    steps.step("the user opens the client", |world, _, _| {
        alerts(world)?;
        world.connect()?;
        world.sync()
    });
    steps.step(&format!("the user is looking at {Q}"), |world, c, _| {
        // TODO(port): FilesViewerSteps' lookAtFile goes first, a file the
        // viewer opens.
        if !fake(world).threads.contains_key(&c[0]) && move_::show_machine_thread(world, &c[0])? {
            return Ok(());
        }
        let thread = if fake(world).threads.contains_key(&c[0]) {
            tracked(world, &c[0])?
        } else {
            working(world, &c[0], "")?
        };
        let key = key_of(world, &thread);
        world.with::<Navigation, _>(|navigation, engine| {
            navigation.open(engine, Route::Thread(key))
        })?;
        world.pump()
    });

    // In-app alerts.
    steps.step(
        &format!("an in-app alert says {Q} (needs approval|completed)"),
        |world, c, _| {
            working(world, &c[0], "")?;
            let what = if c[1] == "completed" {
                "completes"
            } else {
                "asks for approval"
            };
            change(world, &c[0], what)?;
            let Some(toast) = toast_for(world, &c[0]) else {
                fail!("no in-app alert: {}", describe(world));
            };
            fake(world).last_toast = text(&toast["id"]);
            Ok(())
        },
    );
    steps.step("the user opens the thread from the alert", |world, _, _| {
        let id = fake(world).last_toast.clone();
        world.dispatch("notification.action", json!({"id": id}))
    });
    steps.step("the user dismisses the alert", |world, _, _| {
        let id = fake(world).last_toast.clone();
        world.dispatch("notification.dismiss", json!({"id": id}))
    });
    steps.step("the alert is gone", |world, _, _| {
        let id = fake(world).last_toast.clone();
        let present = toasts(world).iter().any(|toast| text(&toast["id"]) == id);
        expect!(!present, "the alert is still shown: {}", describe(world));
        Ok(())
    });
    steps.step(&format!("{Q} is shown"), |world, c, _| {
        if let Some(page) = world.on_settings_page.get("isShown").cloned() {
            return page(world, c);
        }
        let thread = tracked(world, &c[0])?;
        let key = key_of(world, &thread);
        let shown = thread_key(world);
        expect!(shown == key, "the window shows \"{shown}\", not \"{key}\"");
        Ok(())
    });
    steps.step(&format!("{Q} is not opened"), |world, c, _| {
        let thread = tracked(world, &c[0])?;
        let key = key_of(world, &thread);
        expect!(thread_key(world) != key, "the thread was opened");
        Ok(())
    });

    // What the user is told.
    steps.step(
        &format!("the user is alerted {Q} for {Q}"),
        |world, c, _| {
            let in_app = toast_for(world, &c[1]).is_some_and(|toast| text(&toast["title"]) == c[0]);
            let thread = fake(world).threads.get(&c[1]).cloned().unwrap_or_default();
            let key = key_of(world, &thread);
            let system = fake(world).platform.borrow().shown.get(&key).cloned();
            expect!(
                in_app || system == Some((c[0].clone(), c[1].clone())),
                "no alert \"{}\": {}",
                c[0],
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("no alert is raised for {Q}"), |world, c, _| {
        world.sync()?;
        let quiet = {
            let state = fake(world).platform.borrow();
            state.delivered.is_empty() && state.sounds.is_empty()
        };
        expect!(
            toast_for(world, &c[0]).is_none() && quiet,
            "an alert was raised: {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(&format!("an alert for {Q} is raised"), |world, c, _| {
        world.sync()?;
        let thread = fake(world).threads.get(&c[0]).cloned().unwrap_or_default();
        let key = key_of(world, &thread);
        let system = fake(world).platform.borrow().shown.contains_key(&key);
        expect!(
            toast_for(world, &c[0]).is_some() || system,
            "no alert was raised: {}",
            describe(world)
        );
        Ok(())
    });

    // Muting one thread.
    steps.step(&format!("the user mutes alerts for {Q}"), |world, c, _| {
        toggle_mute_from_palette(world, &c[0], true)
    });
    steps.step(&format!("the user unmutes {Q}"), |world, c, _| {
        toggle_mute_from_palette(world, &c[0], false)
    });
    steps.step(&format!("alerts for {Q} are muted"), |world, c, _| {
        working(world, &c[0], "")?;
        toggle_mute_from_palette(world, &c[0], true)
    });
    steps.step(&format!("{Q} finishes its turn"), |world, c, _| {
        change(world, &c[0], "completes")
    });
    steps.step(
        &format!("alerts for other threads in {Q} still arrive"),
        |world, c, _| {
            let title = world
                .mc
                .projects
                .values()
                .next()
                .map(|project| text(&project["title"]))
                .unwrap_or_default();
            expect!(title == c[0], "the threads are not in \"{}\"", c[0]);
            working(world, "Docs pass", "")?;
            change(world, "Docs pass", "completes")?;
            expect!(
                toast_for(world, "Docs pass").is_some(),
                "no alert for another thread: {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("no in-app alert is shown for {Q}"),
        |world, c, _| {
            world.sync()?;
            expect!(
                toast_for(world, &c[0]).is_none(),
                "an in-app alert was shown: {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "a system notification is (shown|not shown)",
        |world, c, _| {
            let none = fake(world).platform.borrow().shown.is_empty();
            expect!(
                none == (c[0] == "not shown"),
                "the user sees {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("no system notification is shown", |world, _, _| {
        let none = fake(world).platform.borrow().shown.is_empty();
        expect!(none, "the user sees {}", describe(world));
        Ok(())
    });
    steps.step("a sound is (played|not played)", |world, c, _| {
        let none = fake(world).platform.borrow().sounds.is_empty();
        expect!(
            none == (c[0] == "not played"),
            "the user hears {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the in-app alert and sound still follow the user's settings",
        |world, _, _| {
            // Away from the window no in-app alert shows; the setting still
            // plays its sound.
            let sounds = fake(world).platform.borrow().sounds.clone();
            expect!(
                toast_for(world, "Tax fix").is_none() && sounds == ["completion"],
                "the user gets {}",
                describe(world)
            );
            Ok(())
        },
    );

    // System notifications.
    steps.step(
        &format!("a system notification says {Q} completed"),
        |world, c, _| {
            completes_in_background(world, &c[0])?;
            let count = fake(world).platform.borrow().shown.len();
            expect!(count == 1, "the user sees {}", describe(world));
            Ok(())
        },
    );
    steps.step(
        &format!("system notifications were shown for {Q} and then for {Q}"),
        |world, c, _| {
            completes_in_background(world, &c[0])?;
            completes_in_background(world, &c[1])?;
            let count = fake(world).platform.borrow().delivered.len();
            expect!(count == 2, "the user sees {}", describe(world));
            Ok(())
        },
    );
    steps.step(
        "system notifications are shown for two threads",
        |world, _, _| {
            completes_in_background(world, "Tax fix")?;
            completes_in_background(world, "Docs")?;
            let count = fake(world).platform.borrow().shown.len();
            expect!(count == 2, "the user sees {}", describe(world));
            Ok(())
        },
    );
    steps.step("the user clicks the older notification", |world, _, _| {
        // The headless shell has one window, so which window comes to the
        // front is not told apart: the click is made, and a raise asked of
        // the window is recorded.
        let raised = Rc::new(RefCell::new(Vec::new()));
        let first = fake(world)
            .platform
            .borrow()
            .delivered
            .first()
            .cloned()
            .unwrap_or_default();
        click_notification(world, &first, Some(&raised))?;
        Ok(())
    });
    steps.step("the user last used a second window", |_, _, _| {
        second_window()
    });
    steps.step(
        &format!("the second window shows {Q} and comes to the front"),
        |_, _, _| second_window(),
    );
    steps.step("the first window stays where it was", |_, _, _| {
        second_window()
    });
    steps.step(
        &format!("only one system notification is shown for {Q}"),
        |world, c, _| {
            let thread = fake(world).threads.get(&c[0]).cloned().unwrap_or_default();
            let key = key_of(world, &thread);
            let only = {
                let state = fake(world).platform.borrow();
                state.shown.len() == 1 && state.shown.contains_key(&key)
            };
            expect!(only, "the user sees {}", describe(world));
            Ok(())
        },
    );
    steps.step(&format!("it says {Q} needs approval"), |world, c, _| {
        let thread = fake(world).threads.get(&c[0]).cloned().unwrap_or_default();
        let key = key_of(world, &thread);
        let told = fake(world).platform.borrow().shown.get(&key).cloned();
        expect!(
            told == Some(("Approval needed".to_owned(), c[0].clone())),
            "the user sees {}",
            describe(world)
        );
        Ok(())
    });
    steps.step("both notifications are closed", |world, _, _| {
        let closed = {
            let state = fake(world).platform.borrow();
            state.shown.is_empty() && state.closed.len() == 2 && !state.enabled
        };
        expect!(closed, "the user sees {}", describe(world));
        Ok(())
    });
    steps.step(
        "clicking a notification that was already on its way opens nothing",
        |world, _, _| {
            let before = thread_key(world);
            let last = fake(world)
                .platform
                .borrow()
                .delivered
                .last()
                .cloned()
                .unwrap_or_default();
            let opened = click_notification(world, &last, None)?;
            expect!(!opened, "the click was taken");
            expect!(thread_key(world) == before, "a thread was opened");
            Ok(())
        },
    );
}

/// The headless shell keeps to one window (`set_window_opener` is not given
/// one here), so what a second window shows can not be read.
fn second_window() -> Outcome {
    fail!("the headless shell has one window; a second one is not opened")
}
