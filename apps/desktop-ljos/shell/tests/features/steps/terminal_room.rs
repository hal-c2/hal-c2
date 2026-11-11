//! The terminal drawer's room in a real shell (features/terminal/drawer.feature,
//! "The drawer has its own room under the thread"): the built-in layout,
//! or a custom shell's column with the drawer under its thread, and where
//! the drawer's buttons, list and terminals land in the window (desktop-qt's
//! TerminalRoomSteps.cpp).

use ljos::item::kurbo;
use ljos::prelude::{ObjectId, Value};

use crate::brick::{self, Brick};
use crate::harness::{Outcome, Q, Steps};
use crate::world::World;
use crate::{expect, fail};

use super::terminal::{drawer_open, ensure_project};

const BUILT_IN: &str = "import QtQuick\nimport HalC2.Bricks\n\
     ShellWindow { id: root; width: 1200; height: 800; \
     DefaultLayout { anchors.fill: parent; window: root } }\n";

// A custom shell as apps/desktop-qt/examples/terminal/shell.qml lays one
// out: a sidebar's room on the left, the thread over the drawer beside it.
const OWN_COLUMN: &str = "import QtQuick\nimport QtQuick.Layouts\nimport HalC2.Bricks\n\
     ShellWindow { id: root; width: 1200; height: 800\n\
       RowLayout { anchors.fill: parent; spacing: 0\n\
         Item { Layout.preferredWidth: 300; Layout.fillHeight: true }\n\
         ColumnLayout { Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0\n\
           Item { objectName: \"threadArea\"; Layout.fillWidth: true; Layout.fillHeight: true }\n\
           TerminalDrawer { Layout.fillWidth: true }\n\
         }\n\
       }\n\
     }\n";

/// The item's box in the window.
fn rect(world: &World, brick: &Brick, item: ObjectId) -> Outcome<kurbo::Rect> {
    let (x0, y0) = brick.at(world, item, 0.0, 0.0)?;
    let (x1, y1) = brick.at(world, item, 1.0, 1.0)?;
    Ok(kurbo::Rect::new(x0, y0, x1, y1))
}

fn inside(world: &World, brick: &Brick, item: ObjectId) -> Outcome<bool> {
    let (width, height) = brick.size(world);
    let r = rect(world, brick, item)?;
    Ok(r.width() > 0.0
        && r.x0 >= -0.5
        && r.y0 >= -0.5
        && r.x1 <= width + 0.5
        && r.y1 <= height + 0.5)
}

/// The visible items named `name`.
fn shown_named(world: &World, brick: &Brick, name: &str) -> Outcome<Vec<ObjectId>> {
    let mut found = Vec::new();
    while let Some(item) = brick.find_visible_nth(world, name, found.len())? {
        found.push(item);
    }
    Ok(found)
}

fn text(world: &World, brick: &Brick, item: ObjectId) -> String {
    brick.text_of(world, item, "text")
}

/// The thread's room: its top and bottom in the window, and the bottom of
/// the column it shares with the drawer.
fn thread_room(world: &World, brick: &Brick) -> Outcome<(f64, f64, f64)> {
    let thread = brick.item(world, "threadArea")?;
    let Value::Object(column) = brick.read(world, thread, "parent") else {
        fail!("the thread has no column");
    };
    let own = rect(world, brick, thread)?;
    let room = rect(world, brick, column)?;
    Ok((own.y0, own.y1, room.y1))
}

fn describe(world: &World, brick: &Brick) -> String {
    let room = thread_room(world, brick)
        .map(|(top, bottom, end)| {
            format!("the thread runs {top}..{bottom} of a column ending at {end}")
        })
        .unwrap_or_else(|e| e.0);
    let splits = brick
        .find(world, "terminalDrawerSplits")
        .ok()
        .flatten()
        .and_then(|s| rect(world, brick, s).ok())
        .map(|r| format!("{r:?}"))
        .unwrap_or_else(|| "none".into());
    format!(
        "{room}; the drawer is {}, its terminals at {splits}",
        if drawer_open(world) { "open" } else { "closed" }
    )
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the user's shell has the drawer (in the built-in layout|under its thread in a column of its own)",
        |world, c, _| {
            ensure_project(world)?;
            let qml = if c[0] == "in the built-in layout" { BUILT_IN } else { OWN_COLUMN };
            Brick::show(world, qml, 1200.0, 800.0)?;
            world.sync()
        },
    );
    steps.step(
        "the drawer's buttons are inside the window",
        |world, _, _| {
            let brick = brick::shown(world)?;
            world.wait_for("the drawer's buttons", move |w| {
                brick
                    .find_visible(w, "terminalDrawerActions")
                    .ok()
                    .flatten()
                    .is_some()
            })?;
            for name in [
                "terminalSplit",
                "terminalSplitVertical",
                "terminalNew",
                "terminalClose",
            ] {
                let button = brick.item(world, name)?;
                expect!(
                    brick.flag(world, button, "visible") && inside(world, &brick, button)?,
                    "{name} is at {:?}, outside the window {:?}",
                    rect(world, &brick, button)?,
                    brick.size(world)
                );
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the drawer's list names {Q} and {Q} under {Q} inside the window"),
        |world, c, _| {
            let brick = brick::shown(world)?;
            let wanted = [c[0].clone(), c[1].clone()];
            world.wait_for("the drawer's list", move |w| {
                shown_named(w, &brick, "terminalTab").is_ok_and(|tabs| tabs.len() == wanted.len())
            })?;
            let tabs = shown_named(world, &brick, "terminalTab")?;
            let names: Vec<String> = tabs.iter().map(|t| text(world, &brick, *t)).collect();
            expect!(
                names == [c[0].clone(), c[1].clone()],
                "the list names {names:?}"
            );
            for tab in &tabs {
                expect!(
                    inside(world, &brick, *tab)?,
                    "{} is at {:?}, outside the window {:?}",
                    text(world, &brick, *tab),
                    rect(world, &brick, *tab)?,
                    brick.size(world)
                );
                expect!(
                    brick.shows_under(world, *tab, &text(world, &brick, *tab))?,
                    "{} draws no label",
                    text(world, &brick, *tab)
                );
            }
            let groups = shown_named(world, &brick, "terminalGroupLabel")?;
            expect!(
                groups.len() == tabs.len(),
                "{} group labels for {} terminals",
                groups.len(),
                tabs.len()
            );
            for group in groups {
                expect!(
                    text(world, &brick, group) == c[2] && inside(world, &brick, group)?,
                    "a group label says {:?} at {:?}",
                    text(world, &brick, group),
                    rect(world, &brick, group)?
                );
            }
            Ok(())
        },
    );
    steps.step("the terminal drawer takes no room", |world, _, _| {
        let brick = brick::shown(world)?;
        world.wait_for_with(
            move |w| {
                !drawer_open(w)
                    && thread_room(w, &brick)
                        .is_ok_and(|(_, bottom, end)| (bottom - end).abs() < 0.5)
            },
            move |w| describe(w, &brick),
        )
    });
    steps.step(
        "the terminal drawer is drawn under the thread with its terminals",
        |world, _, _| {
            let brick = brick::shown(world)?;
            world.wait_for_with(
                move |w| {
                    let Ok(Some(splits)) = brick.find_visible(w, "terminalDrawerSplits") else {
                        return false;
                    };
                    let (Ok((_, bottom, end)), Ok(drawn)) =
                        (thread_room(w, &brick), rect(w, &brick, splits))
                    else {
                        return false;
                    };
                    drawn.height() > 100.0
                        && bottom <= drawn.y0 + 0.5
                        && drawn.y1 <= end + 0.5
                        && brick
                            .find_visible(w, "terminalDrawerActions")
                            .ok()
                            .flatten()
                            .is_some()
                        && brick
                            .find_visible(w, "HalC2Terminal")
                            .ok()
                            .flatten()
                            .is_some()
                },
                move |w| describe(w, &brick),
            )
        },
    );
}
