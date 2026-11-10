//! How the desktop's terminals end and fail (features/terminal/tabs.feature,
//! io.feature, errors.feature, reconnect.feature): desktop-qt's
//! TerminalCloseSteps.cpp. The question a close asks, a shell that leaves on
//! its own, a close the MC cannot do, a terminal that does not open, and how
//! much output the client keeps.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller;
use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::controllers::terminals::Terminals;
use ljos::item::Modifiers;
use ljos::prelude::ObjectId;
use serde_json::{Value, json};

use crate::brick::{Brick, Shown, shown};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::settings::fake_config;
use crate::steps::terminal::{
    FakeTerminals, active_terminal, add_action, add_terminal, attached, confirm_terminal_close,
    describe_rows, describe_terminal_calls, drawer_available, drawer_open, ensure_project,
    ensure_thread, print, rows_in, send_terminal, send_terminals, shown_thread, tab_labels,
    terminal_attach, terminal_call, terminal_session, terminal_summary, terminal_writes,
    toast_shown,
};
use crate::steps::terminal_menu::{drawn_terminal, follow as follow_link};
use crate::world::World;
use crate::{expect, fail};

#[derive(Default)]
struct CloseWorld {
    /// The terminal the scenario is about ("it").
    terminal: String,
    /// Every question the shell asked, in order.
    questions: Rc<RefCell<Vec<Value>>>,
    followed: bool,
    printed: usize,
    first_chunk: String,
    last_chunk: String,
    /// The active group before the user closed a terminal.
    group_before: String,
    /// The Terminal whose engine failed.
    failed: Option<ObjectId>,
}

fn has_tab(world: &World, terminal_id: &str) -> bool {
    controller::with::<Terminals, _>(world.engine(), |t, _| {
        t.tabs().iter().any(|tab| tab.terminal_id == terminal_id)
    })
    .unwrap_or(false)
}

fn asked_count(world: &mut World) -> usize {
    world.mc.part::<CloseWorld>().questions.borrow().len()
}

/// Starts keeping the questions the shell asks.
fn follow(world: &mut World) {
    let close = world.mc.part::<CloseWorld>();
    if std::mem::replace(&mut close.followed, true) {
        return;
    }
    let questions = close.questions.clone();
    Bridge::of(world.engine()).watch(world.engine(), "confirmation", move |_, value| {
        if value.is_object() {
            questions.borrow_mut().push(value.clone());
        }
    });
}

/// The drawer open on the thread with `count` terminals, the last one
/// active.
fn open_terminals(world: &mut World, count: usize) -> Outcome {
    ensure_project(world)?;
    ensure_thread(world)?;
    world.wait_for("the thread's terminal drawer", drawer_available)?;
    follow(world);
    let thread_id = shown_thread(world);
    world.dispatch("terminal.toggle", json!({}))?;
    for n in 1..=count {
        if n > 1 {
            world.dispatch("terminal.new", json!({}))?;
        }
        let id = format!("term-{n}");
        let thread_id = thread_id.clone();
        world.wait_for_with(
            move |w| {
                terminal_attach(w, &thread_id, &id).is_some()
                    && crate::steps::terminal::active_terminal(w) == id
            },
            describe_rows,
        )?;
    }
    world.sync()
}

fn question(world: &World) -> Value {
    world.state("confirmation")
}

fn answer(world: &mut World, accepted: bool) -> Outcome {
    let asked = question(world);
    expect!(asked.is_object(), "no question is asked");
    world.dispatch(
        "confirmation.answer",
        json!({"requestId": asked["requestId"], "accepted": accepted}),
    )?;
    world.sync()
}

/// The drawer under a thread, in a 900 by 700 window.
fn drawer(world: &mut World) -> Outcome<Brick> {
    Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\n\
         Item { width: 900; height: 700; TerminalDrawer { anchors.left: parent.left; \
         anchors.right: parent.right; anchors.bottom: parent.bottom } }\n",
        900.0,
        700.0,
    )
}

fn active_group(world: &World) -> String {
    controller::with::<Terminals, _>(world.engine(), |t, _| t.active_group()).unwrap_or_default()
}

/// Waits for `term-<number>` to be the active terminal.
fn expect_active(world: &mut World, number: &str) -> Outcome {
    world.sync()?;
    let id = format!("term-{number}");
    let wanted = id.clone();
    world.wait_for_with(
        move |w| active_terminal(w) == wanted,
        move |w| {
            format!(
                "{id} active; {} is. {}",
                active_terminal(w),
                describe_rows(w)
            )
        },
    )
}

fn refuse_open(world: &mut World) -> Outcome {
    world.mc.part::<FakeTerminals>().refuse_open =
        "Terminal limit reached on this machine".to_owned();
    Ok(())
}

/// The project's "Dev" script, run from the header.
fn run_script(world: &mut World) -> Outcome {
    add_action(world, "p1", "Dev", "bun dev")?;
    world.dispatch("workspace.runScript", json!({"scriptId": "dev"}))?;
    world.sync()
}

/// Whether the shell said the terminal or the script could not open.
fn told_it_failed(world: &World) -> bool {
    toast_shown(world, "Unable to open terminal")
        || toast_shown(world, "Failed to run script \"Dev\".")
}

fn describe_failure(world: &World) -> String {
    format!(
        "{}; the shell shows {}",
        describe_rows(world),
        show(&world.state("toasts"))
    )
}

/// Which terminal is active as terminals close, and what a terminal that
/// does not open leaves (terminal/tabs.feature, errors.feature).
fn register_tabs(steps: &mut Steps) {
    steps.step(
        "the thread has terminals 1, 2 and 3 with terminal 3 active",
        |world, _, _| open_terminals(world, 3),
    );
    steps.step("terminal (\\d) is (?:still )?active", |world, c, _| {
        expect_active(world, &c[0])
    });
    steps.step("the user closes terminal (\\d)", |world, c, _| {
        world.mc.part::<CloseWorld>().group_before = active_group(world);
        world.dispatch(
            "terminal.close",
            json!({"terminalId": format!("term-{}", c[0])}),
        )?;
        confirm_terminal_close(world)?;
        world.sync()
    });
    steps.step(
        "its group and place in the row are unchanged",
        |world, _, _| {
            let before = world.mc.part::<CloseWorld>().group_before.clone();
            let rows = rows_in(world, false);
            expect!(
                rows.len() == 2
                    && rows[1].terminal_id == "term-3"
                    && rows[1].group == before
                    && active_group(world) == before,
                "{}",
                describe_rows(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the thread has one running terminal that is active",
        |world, _, _| {
            open_terminals(world, 1)?;
            // A script would rather not type into a busy one.
            let thread_id = shown_thread(world);
            add_terminal(&mut world.mc, &thread_id, "term-1", "", true);
            world.sync()
        },
    );
    steps.step(
        "a project script's terminal is already known to the thread",
        |world, _, _| open_terminals(world, 1),
    );
    steps.step(
        "the MC refuses to open (?:another terminal|it again|the terminal)",
        |world, _, _| refuse_open(world),
    );
    steps.step(
        "the user splits the terminal (side by side|stacked)",
        |world, c, _| {
            let action = if c[0] == "stacked" {
                "terminal.splitVertical"
            } else {
                "terminal.split"
            };
            world.dispatch(action, json!({"terminalId": "term-1"}))?;
            world.sync()
        },
    );
    steps.step(
        "the user runs (?:a project script that wants a new terminal|the script)",
        |world, _, _| run_script(world),
    );
    steps.step(
        "the thread still has only its first terminal and it is still active",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let rows = rows_in(w, false);
                    told_it_failed(w)
                        && rows.len() == 1
                        && rows[0].terminal_id == "term-1"
                        && rows[0].span == 1
                        && active_terminal(w) == "term-1"
                },
                describe_failure,
            )
        },
    );
    steps.step("nothing is typed into any terminal", |world, _, _| {
        let typed = world.mc.peek::<FakeTerminals>().is_some_and(|f| {
            f.calls
                .iter()
                .any(|call| call["method"] == "terminal.write")
        });
        expect!(!typed, "{}", describe_terminal_calls(world));
        Ok(())
    });
    steps.step("the terminal stays in the thread", |world, _, _| {
        world.wait_for_with(
            |w| told_it_failed(w) && rows_in(w, false).len() == 1 && has_tab(w, "term-1"),
            describe_failure,
        )
    });
    steps.step("the script's command is not typed", |world, _, _| {
        let typed = terminal_writes(world, "term-1").concat();
        expect!(
            !typed.contains("bun dev"),
            "{}",
            describe_terminal_calls(world)
        );
        Ok(())
    });
}

/// The drawer as the world's brick, drawn once per scenario.
fn shown_drawer(world: &mut World) -> Outcome<Brick> {
    if let Some(brick) = world.part::<Shown>().0 {
        return Ok(brick);
    }
    let brick = drawer(world)?;
    world.part::<Shown>().0 = Some(brick);
    Ok(brick)
}

/// The visible items named `name`, in document order.
pub(crate) fn visible_items(world: &World, brick: &Brick, name: &str) -> Outcome<Vec<ObjectId>> {
    let mut items = Vec::new();
    while let Some(item) = brick.find_visible_nth(world, name, items.len())? {
        items.push(item);
    }
    Ok(items)
}

/// `item`'s box in window coordinates: left, top, right, bottom.
fn scene_box(world: &World, brick: &Brick, item: ObjectId) -> Outcome<(f64, f64, f64, f64)> {
    let (left, top) = brick.at(world, item, 0.0, 0.0)?;
    let (right, bottom) = brick.at(world, item, 1.0, 1.0)?;
    Ok((left, top, right, bottom))
}

const ACTIONS: [&str; 4] = [
    "terminalSplit",
    "terminalSplitVertical",
    "terminalNew",
    "terminalClose",
];

/// The terminal list's groups and rows, and the terminals the MC's late
/// lists would bring back (terminal/tabs.feature).
fn register_list(steps: &mut Steps) {
    steps.step(
        "the thread has one terminal on its own, a group of two side by side, and a stacked group of three",
        |world, _, _| {
            open_terminals(world, 1)?;
            for (action, number) in [
                ("terminal.new", 2),
                ("terminal.split", 3),
                ("terminal.new", 4),
                ("terminal.splitVertical", 5),
                ("terminal.splitVertical", 6),
            ] {
                let active = active_terminal(world);
                world.dispatch(action, json!({"terminalId": active}))?;
                let id = format!("term-{number}");
                world.wait_for_with(move |w| active_terminal(w) == id, describe_rows)?;
            }
            world.sync()
        },
    );
    steps.step("the user looks at the terminal list", |world, _, _| {
        let brick = shown_drawer(world)?;
        world.wait_for_with(
            move |w| visible_items(w, &brick, "terminalGroupLabel").is_ok_and(|l| l.len() == 3),
            move |w| {
                format!(
                    "three groups; {} show",
                    visible_items(w, &brick, "terminalGroupLabel").map_or(0, |l| l.len())
                )
            },
        )
    });
    steps.step(
        &format!("the groups are labelled {Q}, {Q} and {Q}"),
        |world, c, _| {
            let brick = shown(world)?;
            let labels = visible_items(world, &brick, "terminalGroupLabel")?;
            expect!(labels.len() == 3, "{} groups show", labels.len());
            for (n, label) in labels.iter().enumerate() {
                let said = brick.text_of(world, *label, "text");
                expect!(said.starts_with(&c[n]), "group {} says \"{said}\"", n + 1);
            }
            Ok(())
        },
    );
    steps.step(
        "each label shows how many terminals the group holds",
        |world, _, _| {
            let brick = shown(world)?;
            for (n, label) in visible_items(world, &brick, "terminalGroupLabel")?
                .iter()
                .enumerate()
            {
                let said = brick.text_of(world, *label, "text");
                expect!(
                    said.contains(&format!("({})", n + 1)),
                    "group {} says \"{said}\"",
                    n + 1
                );
            }
            Ok(())
        },
    );
    steps.step(
        "choosing a group's label makes that group's terminal active",
        |world, _, _| {
            let brick = shown(world)?;
            let Some(single) = visible_items(world, &brick, "terminalGroupLabel")?
                .first()
                .copied()
            else {
                fail!("no group label shows");
            };
            let (x, y) = brick.at(world, single, 0.5, 0.5)?;
            world.click_at(x, y)?;
            expect_active(world, "1")
        },
    );

    steps.step("the thread has one terminal", |world, _, _| {
        open_terminals(world, 1)?;
        shown_drawer(world).map(|_| ())
    });
    // Above the terminal's right half, never over its first line of output.
    steps.step(
        "the terminal offers split, new and close actions above its own corner",
        |world, _, _| {
            let brick = shown(world)?;
            let Some(terminal) = visible_items(world, &brick, "HalC2Terminal")?.first().copied()
            else {
                fail!("no terminal shows");
            };
            let (left, top, right, _) = scene_box(world, &brick, terminal)?;
            let middle = (left + right) / 2.0;
            for name in ACTIONS {
                let action = brick.item(world, name)?;
                let (aleft, _, aright, abottom) = scene_box(world, &brick, action)?;
                let centre = (aleft + aright) / 2.0;
                expect!(
                    brick.flag(world, action, "visible")
                        && abottom <= top + 0.5
                        && centre > middle
                        && centre < right,
                    "{name} spans {aleft}..{aright} down to {abottom}, over a terminal at {left},{top}..{right}"
                );
            }
            Ok(())
        },
    );
    steps.step("no terminal list is shown", |world, _, _| {
        let brick = shown(world)?;
        let list = brick.item(world, "terminalList")?;
        expect!(!brick.flag(world, list, "visible"), "the list shows");
        Ok(())
    });
    steps.step("the user opens a second terminal", |world, _, _| {
        world.dispatch("terminal.new", json!({}))?;
        world.wait_for_with(|w| active_terminal(w) == "term-2", describe_rows)?;
        world.sync()
    });
    steps.step(
        "the terminal list appears beside the terminals with the same actions",
        |world, _, _| {
            let brick = shown(world)?;
            let list = brick.item(world, "terminalList")?;
            world.wait_for("the terminal list", move |w| brick.flag(w, list, "visible"))?;
            let Some(terminal) = visible_items(world, &brick, "HalC2Terminal")?
                .first()
                .copied()
            else {
                fail!("no terminal shows");
            };
            let (_, _, right, _) = scene_box(world, &brick, terminal)?;
            let (list_left, _, _, _) = scene_box(world, &brick, list)?;
            expect!(
                right <= list_left + 0.5,
                "the terminal runs to {right}, under the list from {list_left}"
            );
            for name in ACTIONS {
                let action = brick.item(world, name)?;
                expect!(brick.flag(world, action, "visible"), "{name} is hidden");
            }
            Ok(())
        },
    );

    steps.step(
        "the thread has two terminals side by side with the first active",
        |world, _, _| {
            open_terminals(world, 1)?;
            world.dispatch("terminal.split", json!({"terminalId": "term-1"}))?;
            expect_active(world, "2")?;
            shown_drawer(world)?;
            world.dispatch("terminal.select", json!({"terminalId": "term-1"}))?;
            expect_active(world, "1")?;
            world.sync()
        },
    );
    steps.step(
        "the user clicks inside the second terminal",
        |world, _, _| {
            let brick = shown(world)?;
            let cell = brick.item(world, "terminalCell-term-2")?;
            let (x, y) = brick.at(world, cell, 0.5, 0.5)?;
            world.click_at(x, y)?;
            world.sync()
        },
    );
    steps.step(
        "the second terminal is active and has the keyboard",
        |world, _, _| {
            expect_active(world, "2")?;
            let brick = shown(world)?;
            let cell = brick.item(world, "terminalCell-term-2")?;
            let terminal_of = move |w: &World, id: &str| {
                brick
                    .find(w, &format!("terminalCell-{id}"))
                    .ok()
                    .flatten()
                    .and_then(|c| brick.find_in(w, c, "HalC2Terminal").ok().flatten())
            };
            world.wait_for_with(
                move |w| {
                    brick
                        .find_in(w, cell, "HalC2Terminal")
                        .ok()
                        .flatten()
                        .is_some_and(|t| brick.flag(w, t, "activeFocus"))
                },
                move |w| {
                    let says = |id: &str| match terminal_of(w, id) {
                        Some(t) => format!(
                            "{id} focus {} activeFocus {}",
                            brick.flag(w, t, "focus"),
                            brick.flag(w, t, "activeFocus")
                        ),
                        None => format!("{id} has no terminal"),
                    };
                    let focused = brick
                        .root(w)
                        .and_then(|root| ljos::item::active_focus_item(w.engine(), root))
                        .map_or("nothing".to_owned(), |item| {
                            format!("{item:?} {}", brick.text_of(w, item, "objectName"))
                        });
                    format!(
                        "the second terminal to have the keyboard; {}; {}; cell focus {}; \
                         the keys go to {focused}",
                        says("term-1"),
                        says("term-2"),
                        brick.flag(w, cell, "focus")
                    )
                },
            )
        },
    );
    steps.step(
        "closing the active terminal now closes the second terminal",
        |world, _, _| {
            world.dispatch("terminal.close", json!({}))?;
            confirm_terminal_close(world)?;
            let thread_id = shown_thread(world);
            world.wait_for_with(
                move |w| terminal_call(w, "terminal.close", &thread_id, "term-2").is_some(),
                |w| {
                    format!(
                        "the second terminal to close; the MC got {}",
                        describe_terminal_calls(w)
                    )
                },
            )?;
            expect!(has_tab(world, "term-1"), "{}", describe_rows(world));
            Ok(())
        },
    );

    steps.step("the thread has terminals 1 and 2", |world, _, _| {
        open_terminals(world, 2)?;
        world.mc.part::<FakeTerminals>().hold_remove = true;
        Ok(())
    });
    steps.step(
        "the MC's list of terminals, sent before the close finished, still includes terminal 1",
        |world, _, _| {
            let thread_id = shown_thread(world);
            expect!(
                terminal_call(world, "terminal.close", &thread_id, "term-1").is_some(),
                "{}",
                describe_terminal_calls(world)
            );
            send_terminals(
                &mut world.mc,
                &json!({"type": "snapshot", "terminals": [
                    terminal_summary(&thread_id, "term-1", "/work"),
                    terminal_summary(&thread_id, "term-2", "/work"),
                ]}),
            );
            world.sync()
        },
    );
    steps.step(
        "terminal 1 does not return to the terminal list",
        |world, _, _| {
            expect!(!has_tab(world, "term-1"), "{}", describe_rows(world));
            let key = format!("{}/term-1", shown_thread(world));
            expect!(!attached(&world.mc).contains(&key), "it attached again");
            Ok(())
        },
    );
    steps.step("terminal 1 is opened again later", |world, _, _| {
        let held = {
            let fake = world.mc.part::<FakeTerminals>();
            fake.hold_remove = false;
            std::mem::take(&mut fake.held_removes)
        };
        for remove in &held {
            send_terminals(&mut world.mc, remove);
        }
        let thread_id = shown_thread(world);
        add_terminal(&mut world.mc, &thread_id, "term-1", "", false);
        world.sync()
    });
    steps.step(
        "terminal 1 appears in the terminal list again",
        |world, _, _| world.wait_for_with(|w| has_tab(w, "term-1"), describe_rows),
    );

    steps.step(
        "the user opens a second terminal and the MC's list of terminals still shows only the first",
        |world, _, _| {
            open_terminals(world, 1)?;
            let thread_id = shown_thread(world);
            world.mc.part::<FakeTerminals>().quiet_open = true;
            world.dispatch("terminal.split", json!({"terminalId": "term-1"}))?;
            let id = thread_id.clone();
            world.wait_for_with(
                move |w| terminal_attach(w, &id, "term-2").is_some(),
                describe_rows,
            )?;
            send_terminals(
                &mut world.mc,
                &json!({"type": "snapshot", "terminals": [
                    terminal_summary(&thread_id, "term-1", "/work"),
                ]}),
            );
            world.sync()
        },
    );
    steps.step(
        "the second terminal stays in the terminal list",
        |world, _, _| {
            expect!(has_tab(world, "term-2"), "{}", describe_rows(world));
            Ok(())
        },
    );
    steps.step(
        "it stays in the split group it was opened in",
        |world, _, _| {
            let rows = rows_in(world, false);
            expect!(
                rows.len() == 2 && rows[0].group == rows[1].group && rows[1].span == 2,
                "{}",
                describe_rows(world)
            );
            Ok(())
        },
    );
}

/// A terminal that does not open, a link nothing opens, and an engine
/// that does not start (terminal/errors.feature).
fn register_failures(steps: &mut Steps) {
    steps.step(
        "the user's links open in the in-app browser",
        |world, _, _| {
            // The desktop has no in-app browser (docs/internals/desktop-qt.md):
            // the setting another client chose changes nothing here.
            fake_config(&mut world.mc)
                .settings
                .insert("browserLinkTarget".into(), json!("in-app"));
            drawn_terminal(world).map(|_| ())
        },
    );
    steps.step(
        "neither the in-app browser nor the system browser can open an address",
        |world, _, _| {
            world.set_browser_fails(true);
            Ok(())
        },
    );
    steps.step(
        "the user follows a web address in the terminal",
        |world, _, _| {
            let address = "http://localhost:5173";
            follow_link(
                world,
                &format!("Server ready at {address} (press h for help)"),
                address,
                Modifiers::CONTROL,
            )
        },
    );

    steps.step("the thread has no terminals", |world, _, _| {
        ensure_project(world)?;
        ensure_thread(world)?;
        world.wait_for("the thread's terminal drawer", drawer_available)?;
        expect!(rows_in(world, false).is_empty(), "{}", describe_rows(world));
        Ok(())
    });
    steps.step(
        "the drawer does not stay open with a dead terminal",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    !drawer_open(w)
                        && rows_in(w, false).is_empty()
                        && toast_shown(w, "Unable to open terminal")
                },
                describe_failure,
            )
        },
    );
    steps.step(
        "the user shows the terminal again and the MC accepts",
        |world, _, _| {
            world.mc.part::<FakeTerminals>().refuse_open.clear();
            world.dispatch("terminal.toggle", json!({}))?;
            world.sync()
        },
    );
    steps.step(
        "the terminal opens and the drawer shows it",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    drawer_open(w)
                        && rows_in(w, false).len() == 1
                        && w.mc
                            .peek::<FakeTerminals>()
                            .is_some_and(|f| f.terminals.len() == 1)
                },
                describe_rows,
            )
        },
    );

    steps.step(
        "the terminal's rendering engine cannot start",
        |world, _, _| {
            ensure_project(world)?;
            ensure_thread(world)?;
            Ok(())
        },
    );
    steps.step("the user opens a terminal", |world, _, _| {
        let (_, terminal) = drawn_terminal(world)?;
        world.mc.part::<CloseWorld>().failed = Some(terminal);
        hal_c2_shell::terminal::fail(world.engine(), terminal, "Could not create a terminal");
        world.sync()
    });
    steps.step(
        &format!("the terminal says why, followed by {Q}"),
        |world, c, _| {
            let brick = shown(world)?;
            let said = brick.item(world, "terminalEngineError")?;
            let text = brick.text_of(world, said, "text");
            expect!(
                brick.flag(world, said, "visible")
                    && text == format!("Could not create a terminal: {}", c[0]),
                "the terminal says \"{text}\""
            );
            Ok(())
        },
    );
    steps.step(
        "the user closes the terminal and opens it again",
        |world, _, _| {
            world.dispatch("terminal.close", json!({}))?;
            confirm_terminal_close(world)?;
            let brick = shown(world)?;
            let failed = world.mc.part::<CloseWorld>().failed;
            world.wait_for("the failed engine to go", move |w| {
                brick
                    .find_visible(w, "HalC2Terminal")
                    .ok()
                    .flatten()
                    .is_none()
            })?;
            world.dispatch("terminal.toggle", json!({}))?;
            world.wait_for_with(
                move |w| {
                    brick
                        .find_visible(w, "HalC2Terminal")
                        .ok()
                        .flatten()
                        .is_some_and(|t| Some(t) != failed)
                },
                describe_rows,
            )
        },
    );
    steps.step(
        "the terminal tries to start the engine again",
        |world, _, _| {
            let brick = shown(world)?;
            let showing = brick
                .find_visible(world, "terminalEngineError")?
                .is_some_and(|said| brick.flag(world, said, "visible"));
            expect!(!showing, "the new Terminal still says it failed");
            Ok(())
        },
    );
}

pub fn register(steps: &mut Steps) {
    register_tabs(steps);
    register_list(steps);
    register_failures(steps);
    steps.step(
        "the terminal \"Terminal (\\d+)\" is running",
        |world, c, _| {
            open_terminals(world, c[0].parse().unwrap_or_default())?;
            world.mc.part::<CloseWorld>().terminal = format!("term-{}", c[0]);
            let thread_id = shown_thread(world);
            print(
                &mut world.mc,
                &thread_id,
                &format!("term-{}", c[0]),
                "bun dev\r\nlistening on 5173\r\n",
            );
            world.sync()
        },
    );
    steps.step("the user closes it", |world, _, _| {
        // The drawer's own close button, on the active terminal.
        let drawer = drawer(world)?;
        drawer.click(world, "terminalClose")?;
        world.sync()?;
        // A close the scenario does not ask about is confirmed.
        if !world.mc.part::<FakeTerminals>().refuse_close.is_empty() {
            answer(world, true)?;
        }
        Ok(())
    });
    steps.step(
        &format!("the user is asked 'Close terminal {Q}\\?' and warned its history is cleared"),
        |world, c, _| {
            let asked = question(world);
            expect!(
                asked["title"] == format!("Close terminal \"{}\"?", c[0])
                    && asked["description"]
                        == "This stops the running process and clears its history."
                    && asked["destructive"] == json!(true),
                "the shell asks {}",
                show(&asked)
            );
            // Nothing stops before the answer.
            let terminal = world.mc.part::<CloseWorld>().terminal.clone();
            expect!(
                terminal_call(world, "terminal.close", &shown_thread(world), &terminal).is_none()
                    && tab_labels(world).contains(&c[0]),
                "the MC got {}; the tabs are {}",
                describe_terminal_calls(world),
                tab_labels(world)
            );
            Ok(())
        },
    );
    steps.step(
        "its process stops and its history is deleted",
        |world, _, _| {
            let terminal = world.mc.part::<CloseWorld>().terminal.clone();
            let thread_id = shown_thread(world);
            let (watched, id) = (terminal.clone(), thread_id.clone());
            world.wait_for_with(
                move |w| {
                    terminal_call(w, "terminal.close", &id, &watched)
                        .is_some_and(|payload| payload["deleteHistory"] == json!(true))
                        && !has_tab(w, &watched)
                },
                |w| {
                    format!(
                        "{}; the MC got {}",
                        describe_rows(w),
                        describe_terminal_calls(w)
                    )
                },
            )?;
            let key = format!("{thread_id}/{terminal}");
            expect!(
                !world
                    .mc
                    .part::<FakeTerminals>()
                    .terminals
                    .contains_key(&key),
                "the MC still runs {terminal}"
            );
            Ok(())
        },
    );
    steps.step(
        "the user closes it and declines the confirmation",
        |world, _, _| {
            // The terminal's own chord (terminal.close, mod+w with the
            // keyboard in it).
            world.dispatch("terminal.close", json!({}))?;
            world.sync()?;
            let asked = question(world);
            expect!(
                text(&asked["title"]).starts_with("Close terminal"),
                "the shell asks {}",
                show(&asked)
            );
            answer(world, false)
        },
    );
    steps.step(
        "\"Terminal (\\d+)\" keeps running with its history",
        |world, c, _| {
            let terminal = format!("term-{}", c[0]);
            let thread_id = shown_thread(world);
            expect!(
                question(world).is_null(),
                "the question stays: {}",
                show(&question(world))
            );
            expect!(
                terminal_call(world, "terminal.close", &thread_id, &terminal).is_none()
                    && attached(&world.mc).contains(&format!("{thread_id}/{terminal}"))
                    && crate::steps::terminal::active_terminal(world) == terminal,
                "{}; the MC got {}",
                describe_rows(world),
                describe_terminal_calls(world)
            );
            let transcript = terminal_session(world, &terminal)?.transcript();
            expect!(
                transcript.contains("listening on 5173"),
                "{terminal} shows \"{transcript}\""
            );
            Ok(())
        },
    );

    steps.step(
        "the user closes a split group of three terminals",
        |world, _, _| {
            ensure_project(world)?;
            ensure_thread(world)?;
            world.wait_for("the thread's terminal drawer", drawer_available)?;
            follow(world);
            // A terminal tab of the right panel, split twice.
            world.dispatch("rightPanel.add", json!({"kind": "terminal"}))?;
            world.wait_for_with(|w| rows_in(w, true).len() == 1, describe_rows)?;
            for count in 2..=3 {
                let last = rows_in(world, true)
                    .last()
                    .map(|t| t.terminal_id.clone())
                    .unwrap_or_default();
                world.dispatch("terminal.split", json!({"terminalId": last}))?;
                world.wait_for_with(move |w| rows_in(w, true).len() == count, describe_rows)?;
            }
            world.sync()?;
            let active = at(&world.state("panel"), "activeId").clone();
            world.dispatch("rightPanel.close", json!({"id": active}))?;
            world.sync()
        },
    );
    steps.step(
        "the user is asked once to close 3 terminals, naming each of them",
        |world, _, _| {
            let asked_so_far = asked_count(world);
            expect!(
                asked_so_far == 1,
                "the shell asked {asked_so_far} questions"
            );
            let asked = question(world);
            let description = text(&asked["description"]);
            expect!(
                asked["title"] == "Close 3 terminals?",
                "the shell asks {}",
                show(&asked)
            );
            for row in rows_in(world, true) {
                expect!(
                    description.contains(&format!("\"{}\"", row.label)),
                    "{} is not named in \"{description}\"",
                    row.label
                );
            }
            expect!(rows_in(world, true).len() == 3, "{}", describe_rows(world));
            // One yes closes all three, and no second question follows.
            answer(world, true)?;
            world.wait_for_with(|w| rows_in(w, true).is_empty(), describe_rows)?;
            let asked_after = asked_count(world);
            expect!(
                asked_after == 1 && question(world).is_null(),
                "the shell asked {asked_after} questions"
            );
            Ok(())
        },
    );

    steps.step("a terminal whose close request fails", |world, _, _| {
        open_terminals(world, 2)?;
        world.mc.part::<CloseWorld>().terminal = "term-2".into();
        world.mc.part::<FakeTerminals>().refuse_close = "Unknown terminal".into();
        Ok(())
    });
    steps.step(
        "the client sends \"exit\" to the shell instead",
        |world, _, _| {
            let terminal = world.mc.part::<CloseWorld>().terminal.clone();
            let watched = terminal.clone();
            world.wait_for_with(
                move |w| terminal_writes(w, &watched).contains(&"exit\n".to_owned()),
                |w| {
                    format!(
                        "\"exit\" to be written; the MC got {}",
                        describe_terminal_calls(w)
                    )
                },
            )?;
            world.sync()?;
            // And the terminal leaves the drawer without an error.
            let toasts = world.state("toasts");
            expect!(
                !has_tab(world, &terminal)
                    && at(&toasts, "items").as_array().is_none_or(Vec::is_empty),
                "{}; the shell says {}",
                describe_rows(world),
                show(&toasts)
            );
            Ok(())
        },
    );

    steps.step(
        "the terminal's shell exits after the user types \"exit\"",
        |world, _, _| {
            open_terminals(world, 2)?;
            let thread_id = shown_thread(world);
            let session = terminal_session(world, "term-2")?;
            session.write(world.engine(), "exit\r");
            world.pump()?;
            world.wait_for_with(
                |w| terminal_writes(w, "term-2").contains(&"exit\r".to_owned()),
                describe_terminal_calls,
            )?;
            // The shell leaves: the MC says so to whoever is attached.
            send_terminal(
                &mut world.mc,
                &format!("{thread_id}/term-2"),
                &json!({"type": "exited", "exitCode": 0, "exitSignal": null}),
            );
            world.sync()
        },
    );
    steps.step(
        "the terminal closes without a confirmation",
        |world, _, _| {
            let thread_id = shown_thread(world);
            world.wait_for_with(
                move |w| {
                    terminal_call(w, "terminal.close", &thread_id, "term-2").is_some()
                        && !has_tab(w, "term-2")
                },
                |w| {
                    format!(
                        "{}; the MC got {}",
                        describe_rows(w),
                        describe_terminal_calls(w)
                    )
                },
            )?;
            expect!(
                asked_count(world) == 0 && question(world).is_null(),
                "the shell asked {}",
                show(&question(world))
            );
            expect!(
                tab_labels(world) == "Terminal 1" && drawer_open(world),
                "the tabs are {}",
                tab_labels(world)
            );
            Ok(())
        },
    );

    steps.step(
        "the user opens a terminal in a folder that no longer exists",
        |world, _, _| {
            ensure_project(world)?;
            ensure_thread(world)?;
            world.wait_for("the thread's terminal drawer", drawer_available)?;
            // The MC's own words for it (apps/server-ex terminal.ex
            // check_cwd).
            world.mc.part::<FakeTerminals>().refuse_open =
                "Terminal cwd does not exist: /work/p1".into();
            world.dispatch("terminal.toggle", json!({}))?;
            world.sync()
        },
    );
    steps.step(
        "the user is told the folder does not exist",
        |world, _, _| {
            let told = |w: &World| {
                let toasts = w.state("toasts");
                toasts["items"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|item| text(at(item, "title")) == "Unable to open terminal")
                    .map(|item| text(at(item, "description")))
                    .unwrap_or_default()
            };
            world.wait_for_with(
                move |w| told(w) == "Terminal cwd does not exist: /work/p1",
                |w| format!("the reason; the shell shows {}", show(&w.state("toasts"))),
            )?;
            // The refused terminal goes again, and the drawer with it.
            expect!(
                rows_in(world, false).is_empty() && !drawer_open(world),
                "{}",
                describe_rows(world)
            );
            Ok(())
        },
    );
    steps.step("the rest of the thread keeps working", |world, _, _| {
        let key = world.with::<Navigation, _>(|n, _| n.thread_key().to_owned())?;
        let route = world.state("route");
        expect!(
            at(&route, "kind") == "thread" && text(&world.state("backendError")).is_empty(),
            "the window shows {}",
            show(&route)
        );
        // The composer still takes the user's words.
        world.dispatch(
            "composer.text.set",
            json!({"target": key, "text": "try again", "cursor": 9}),
        )?;
        world.wait_for_with(
            |w| at(&w.state("composer"), "text") == "try again",
            |w| format!("the composer shows {}", show(&w.state("composer"))),
        )
    });

    steps.step(
        "a terminal that has printed more than 512 KiB since the client attached",
        |world, _, _| {
            open_terminals(world, 1)?;
            let thread_id = shown_thread(world);
            // 600 KiB, a numbered 8 KiB line at a time.
            for n in 0..75 {
                let chunk = format!("line-{n:04} {}\r\n", "x".repeat(8192 - 11));
                let close = world.mc.part::<CloseWorld>();
                if n == 0 {
                    close.first_chunk = chunk[..9].to_owned();
                }
                close.last_chunk = chunk[..9].to_owned();
                close.printed += chunk.chars().count();
                print(&mut world.mc, &thread_id, "term-1", &chunk);
            }
            // The MC sends past its unread window only as the client says
            // what it read, so this waits for the last chunk to arrive.
            let last = world.mc.part::<CloseWorld>().last_chunk.clone();
            world.wait_for("the last of the output to arrive", move |w| {
                terminal_session(w, "term-1").is_ok_and(|s| s.transcript().contains(&last))
            })
        },
    );
    steps.step("the client keeps the newest 512 KiB", |world, _, _| {
        let transcript = terminal_session(world, "term-1")?.transcript();
        let close = world.mc.part::<CloseWorld>();
        let (printed, first, last) = (
            close.printed,
            close.first_chunk.clone(),
            close.last_chunk.clone(),
        );
        expect!(printed > 512 * 1024, "only {printed} bytes were printed");
        let size = transcript.encode_utf16().count();
        expect!(
            size <= 512 * 1024 && size > 512 * 1024 - 8192,
            "the client keeps {size} bytes of {printed}"
        );
        expect!(
            transcript.contains(&last)
                && !transcript.contains(&first)
                && transcript.ends_with("x\r\n"),
            "the client keeps other output than the newest"
        );
        Ok(())
    });
}
