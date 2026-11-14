//! The scenarios desktop-qt runs against its shell test double
//! (tests/tst_Scenarios.qml): the thread list, the header's terminal toggle
//! and the notification cards (threads/qt-scenarios.feature,
//! navigation/qt-scenarios.feature, timeline/notifications.feature). Here
//! the bricks run over the real shell and the fake MC, so a step reads what
//! the action did rather than which action the brick asked for.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::controllers::toasts::{Action, Toasts};
use ljos::ObjectId;
use serde_json::{Value, json};

use super::project::add_project;
use super::terminal::{drawer_available, drawer_open, ensure_thread};
use super::thread_list::{put_thread, title_id, wait_for_section};
use super::thread_menu::{key_of, section_of};
use crate::brick::{Brick, Shown, shown};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

const PROJECT: &str = "project";

/// The thread list as the window draws it, taking the scenario's keys.
fn show_sidebar(world: &mut World) -> Outcome<Brick> {
    world.sync()?;
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Bricks\nSidebar { width: 272; height: 450; showFooter: false }\n",
        272.0,
        450.0,
    )?;
    let mut brick = shown(world)?;
    brick.takes_keys = true;
    world.part::<Shown>().0 = Some(brick);
    Ok(brick)
}

/// The thread `title` in the project, made the first time a step names it;
/// a later one is newer, so the list shows them in the order they are named
/// from the bottom up.
fn thread_titled(world: &mut World, title: &str, fields: Value) -> Outcome<String> {
    if let Ok(key) = key_of(world, title) {
        return Ok(key);
    }
    let minute = world.mc.threads.len();
    let mut row = fields;
    row["title"] = json!(title);
    row["projectId"] = json!(PROJECT);
    row["createdAt"] = json!(format!("2026-09-23T09:{minute:02}:00Z"));
    put_thread(world, &title_id(title), row)?;
    world.sync()?;
    key_of(world, title)
}

/// The list's row for the thread `key`, once it is laid out.
fn row_of(world: &mut World, brick: Brick, key: &str) -> Outcome<ObjectId> {
    let name = format!("threadRow:{key}");
    world.wait_for(&format!("the thread list to draw {key}"), |w| {
        brick.find(w, &name).is_ok_and(|row| row.is_some())
    })?;
    brick.item(world, &name)
}

/// Puts the pointer over the thread's row, which shows its actions.
fn hover_row(world: &mut World, brick: Brick, key: &str) -> Outcome<ObjectId> {
    let row = row_of(world, brick, key)?;
    let (x, y) = brick.at(world, row, 0.4, 0.5)?;
    world.hover_at(x, y)?;
    world.wait_for(&format!("{key} to show its actions"), |w| {
        brick.flag(w, row, "showActions")
    })?;
    Ok(row)
}

/// The shown action named `name` on the row (a row lays its actions out
/// twice, slim and card, and shows one).
fn row_action(world: &World, brick: Brick, row: ObjectId, name: &str) -> Outcome<Option<ObjectId>> {
    brick.visible_in(world, row, name)
}

fn click_item(world: &mut World, brick: Brick, item: ObjectId) -> Outcome {
    let (x, y) = brick.at(world, item, 0.5, 0.5)?;
    world.click_at(x, y)?;
    world.sync()
}

/// The list, focused as Tab or a click would focus it, with its keyboard
/// cursor on a row.
fn focus_list(world: &mut World, brick: Brick) -> Outcome<ObjectId> {
    let list = brick.item(world, "list")?;
    let _ = world.engine().invoke_by_name(list, "forceActiveFocus", &[]);
    world.pump()?;
    world.wait_for("the thread list's keyboard cursor", |w| {
        brick.flag(w, list, "activeFocus") && !brick.text_of(w, list, "cursorKey").is_empty()
    })?;
    Ok(list)
}

/// What the scenario remembers between its steps.
#[derive(Default)]
struct Scenario {
    /// The centre of the row whose menu Shift+F10 asks for.
    row_centre: (f64, f64),
    terminal_was_open: bool,
    /// The notification actions that ran, as "<title>/<label>".
    ran: Rc<RefCell<Vec<String>>>,
    notifications: Option<Brick>,
}

fn toasts(world: &World) -> Vec<Value> {
    world.state("toasts")["items"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn toast_titled(world: &World, title: &str) -> Option<Value> {
    toasts(world)
        .into_iter()
        .find(|t| text(&t["title"]) == title)
}

/// Shows a toast that stays until it is dismissed, and the cards that draw
/// it.
fn notify(world: &mut World, title: &str, label: Option<&str>) -> Outcome {
    let ran = world.part::<Scenario>().ran.clone();
    let actions: Vec<Action> = label
        .map(|label| {
            let said = format!("{title}/{label}");
            Action::new(label, move |_| ran.borrow_mut().push(said.clone()))
        })
        .into_iter()
        .collect();
    let kind = if label.is_some() { "info" } else { "success" };
    let shown_title = title.to_owned();
    world.with::<Toasts, _>(move |t, engine| {
        t.show_actions(engine, kind, &shown_title, "", actions, 0);
    })?;
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nNotifications {}\n",
        340.0,
        200.0,
    )?;
    world.part::<Scenario>().notifications = Some(brick);
    let toast = toast_titled(world, title).unwrap_or(Value::Null);
    let card = format!("notification-{}", text(&toast["id"]));
    world.wait_for_with(
        |w| {
            brick
                .find(w, &card)
                .ok()
                .flatten()
                .is_some_and(|c| brick.read(w, c, "opacity").to_number() == 1.0)
        },
        |w| {
            format!(
                "the card {card}; the shell shows {}",
                show(&Value::Array(toasts(w)))
            )
        },
    )
}

fn notifications(world: &mut World) -> Outcome<Brick> {
    match world.part::<Scenario>().notifications {
        Some(brick) => Ok(brick),
        None => fail!("no notification is shown"),
    }
}

/// Clicks the action labelled `label` on the notification that offers it,
/// when one does.
pub fn notification_chooses(world: &mut World, label: &str) -> Outcome<bool> {
    if world.part::<Scenario>().notifications.is_none() {
        return Ok(false);
    }
    let brick = notifications(world)?;
    for toast in toasts(world) {
        for action in toast["actions"].as_array().into_iter().flatten() {
            if action["label"] != label {
                continue;
            }
            let name = format!(
                "notificationAction-{}-{}",
                text(&toast["id"]),
                text(&action["id"])
            );
            let Some(button) = brick.find_visible(world, &name)? else {
                fail!("the card shows no {name}");
            };
            click_item(world, brick, button)?;
            return Ok(true);
        }
    }
    Ok(false)
}

pub fn register(steps: &mut Steps) {
    // The thread list.
    steps.step(
        &format!("the project {Q} is in the thread list"),
        |world, c, _| {
            // The MC applies what the list asks of a thread.
            super::thread_menu::fake(world).project = true;
            add_project(world, PROJECT, &c[0], "/work/project")?;
            if world.shell_subscriptions() == 0 {
                world.connect()?;
            }
            world.sync()
        },
    );
    steps.step(
        &format!("the threads {Q} and {Q} with {Q} open"),
        |world, c, _| {
            // The first named is the newest, at the top.
            thread_titled(world, &c[1], json!({}))?;
            thread_titled(world, &c[0], json!({}))?;
            let key = key_of(world, &c[2])?;
            world.dispatch("thread.open", json!({"key": key}))
        },
    );
    steps.step("the thread list has keyboard focus", |world, _, _| {
        let brick = show_sidebar(world)?;
        focus_list(world, brick).map(|_| ())
    });
    steps.step("the user moves down and presses Enter", |world, _, _| {
        let brick = shown(world)?;
        expect!(brick.press(world, "down")?, "the list did not take Down");
        expect!(brick.press(world, "enter")?, "the list did not take Enter");
        world.sync()
    });
    steps.step(
        &format!("the thread list has keyboard focus on {Q}"),
        |world, c, _| {
            let key = thread_titled(world, &c[0], json!({}))?;
            world.dispatch("thread.open", json!({"key": key}))?;
            let brick = show_sidebar(world)?;
            let row = row_of(world, brick, &key)?;
            let list = focus_list(world, brick)?;
            let cursor = brick.text_of(world, list, "cursorKey");
            expect!(cursor == key, "the keyboard cursor is on {cursor}");
            world.part::<Scenario>().row_centre = brick.at(world, row, 0.5, 0.5)?;
            Ok(())
        },
    );
    steps.step(
        &format!("the menu for {Q} is requested beside that thread"),
        |world, c, _| {
            let menu = world.state("menu");
            expect!(
                menu.is_object() && !menu["items"].as_array().is_none_or(Vec::is_empty),
                "no menu opened for {}",
                c[0]
            );
            let (x, y) = world.part::<Scenario>().row_centre;
            let (mx, my) = (
                menu["x"].as_f64().unwrap_or(f64::NAN),
                menu["y"].as_f64().unwrap_or(f64::NAN),
            );
            expect!(
                (mx - x).abs() < 1.0 && (my - y).abs() < 1.0,
                "the menu is at {mx}, {my}, not beside {} at {x}, {y}",
                c[0]
            );
            Ok(())
        },
    );
    steps.step(&format!("the thread {Q} can be settled"), |world, c, _| {
        thread_titled(world, &c[0], json!({}))?;
        wait_for_section(world, &c[0], "active")
    });
    steps.step(
        &format!("the user (settles|wakes) {Q} from the thread list"),
        |world, c, _| {
            let key = key_of(world, &c[1])?;
            let brick = show_sidebar(world)?;
            let row = hover_row(world, brick, &key)?;
            let name = if c[0] == "settles" {
                "settleAction"
            } else {
                "wakeAction"
            };
            let Some(button) = row_action(world, brick, row, name)? else {
                fail!("{} shows no {name}", c[1]);
            };
            click_item(world, brick, button)
        },
    );
    steps.step(&format!("the thread {Q} is snoozed"), |world, c, _| {
        let now = world.now();
        let iso =
            |t: chrono::DateTime<chrono::Utc>| t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        thread_titled(
            world,
            &c[0],
            json!({
                "snoozedUntil": iso(now + chrono::Duration::days(1)),
                "snoozedAt": iso(now - chrono::Duration::seconds(60)),
            }),
        )?;
        wait_for_section(world, &c[0], "snoozed")
    });
    steps.step(
        &format!("{Q} offers to wake but not to settle"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            let brick = show_sidebar(world)?;
            let row = hover_row(world, brick, &key)?;
            let wake = row_action(world, brick, row, "wakeAction")?;
            let settle = row_action(world, brick, row, "settleAction")?;
            expect!(
                wake.is_some() && settle.is_none(),
                "{} offers wake {}, settle {}",
                c[0],
                wake.is_some(),
                settle.is_some()
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} is no longer snoozed"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        world.wait_for_with(
            |w| !matches!(section_of(w, &key).as_str(), "snoozed" | ""),
            |w| {
                format!(
                    "{key} to wake; it is in \"{}\"; the MC has {}",
                    section_of(w, &key),
                    w.describe_commands()
                )
            },
        )
    });
    steps.step(
        &format!("the thread list is scoped to {Q}"),
        |world, c, _| {
            let key = world.project_key(&c[0]);
            world.dispatch("sidebar.scope", json!({"projectKey": key}))
        },
    );
    steps.step(
        "the user starts a new thread from the thread list",
        |world, _, _| {
            let brick = show_sidebar(world)?;
            brick.click(world, "newThread")?;
            world.sync()
        },
    );

    // The header.
    steps.step("the thread can open a terminal", |world, _, _| {
        super::terminal::ensure_project(world)?;
        ensure_thread(world)?;
        world.wait_for("the thread's terminal drawer", drawer_available)?;
        world.part::<Scenario>().terminal_was_open = drawer_open(world);
        Ok(())
    });
    steps.step(
        "the user toggles the terminal from the header",
        |world, _, _| {
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Bricks\nWorkspace { width: 900; height: 52 }\n",
                900.0,
                52.0,
            )?;
            let brick = shown(world)?;
            world.wait_for("the header's terminal toggle", |w| {
                brick
                    .find(w, "terminalToggle")
                    .ok()
                    .flatten()
                    .is_some_and(|t| brick.flag(w, t, "visible"))
            })?;
            brick.click(world, "terminalToggle")?;
            world.sync()
        },
    );
    steps.step("the terminal drawer is toggled", |world, _, _| {
        let was = world.part::<Scenario>().terminal_was_open;
        world.wait_for(
            &format!(
                "the terminal drawer to {}",
                if was { "close" } else { "open" }
            ),
            move |w| drawer_open(w) != was,
        )
    });

    // The notification cards.
    steps.step(
        &format!("the notification {Q} offers {Q}"),
        |world, c, _| notify(world, &c[0], Some(&c[1])),
    );
    steps.step(&format!("the only notification is {Q}"), |world, c, _| {
        expect!(
            toasts(world).is_empty(),
            "the shell already shows {}",
            show(&Value::Array(toasts(world)))
        );
        notify(world, &c[0], None)
    });
    steps.step(&format!("the {Q} action of {Q} runs"), |world, c, _| {
        let said = format!("{}/{}", c[1], c[0]);
        let ran = world.part::<Scenario>().ran.clone();
        expect!(
            ran.borrow().contains(&said),
            "the actions that ran are {:?}",
            ran.borrow()
        );
        Ok(())
    });
    steps.step(&format!("the user dismisses {Q}"), |world, c, _| {
        let brick = notifications(world)?;
        let Some(toast) = toast_titled(world, &c[0]) else {
            fail!("no notification is titled \"{}\"", c[0]);
        };
        let id = text(&toast["id"]);
        // The close button shows on the card the pointer is over.
        let card = brick.item(world, &format!("notification-{id}"))?;
        let (x, y) = brick.at(world, card, 0.5, 0.5)?;
        world.hover_at(x, y)?;
        let name = format!("notificationDismiss-{id}");
        let Some(button) = brick.find_visible(world, &name)? else {
            fail!("the card shows no {name}");
        };
        click_item(world, brick, button)
    });
    steps.step(&format!("{Q} is dismissed"), |world, c, _| {
        let title = c[0].clone();
        world.wait_for_with(
            move |w| toast_titled(w, &title).is_none(),
            |w| format!("the shell shows {}", show(&Value::Array(toasts(w)))),
        )
    });
    steps.step("no notifications are shown", |world, _, _| {
        let brick = notifications(world)?;
        let Some(root) = brick.root(world) else {
            fail!("the notifications did not load");
        };
        world.wait_for("the notifications to hide", |w| {
            !brick.flag(w, root, "visible")
        })
    });
}
