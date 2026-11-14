//! How the desktop's terminal feels to type, select and scroll in
//! (features/terminal/io.feature): desktop-qt's TerminalInputSteps.cpp.
//! Driven on the bricks with the mouse, wheel, keys and input method the
//! user has; the drawn terminal and its keys are terminal_menu.rs's.

use ljos::ObjectId;
use ljos::item::{DrawOp, KeyEvent, Modifiers, MouseButtons, PointerEvent, kurbo};

use crate::brick::{Brick, Shown};
use crate::harness::{Outcome, Q, Steps};
use crate::steps::terminal::{
    describe_terminal_calls, drawer_open, last_terminal_call, print, shown_thread,
    terminal_calls_of, terminal_writes,
};
use crate::steps::terminal_menu::{call, drawn_terminal, number, take_keyboard};
use crate::world::World;
use crate::{expect, fail};
use hal_c2_shell::controller;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::terminals::Terminals;
use hal_c2_shell::terminal::Terminal;
use serde_json::json;

#[derive(Default)]
struct InputWorld {
    scroll_before: f64,
    wheel_pixels: f64,
    /// Where the scrollbar should have put the view.
    expected_offset: f64,
    /// What the hidden terminal last painted, to see it paints no more.
    painted: String,
    /// The resizes the MC had got once the shell was 120 by 30.
    resize_calls: usize,
    /// The terminal as drawn before the user hid it: a hidden drawer takes it
    /// out of the brick's tree, and desktop-qt's steps keep its item too.
    kept: Option<(Brick, ObjectId)>,
    /// The line a drag past the edge began on.
    dragged_from: String,
    /// Where the prompt's row ends, in the window.
    prompt_y: f64,
    /// The font the prompt's symbols were drawn in: its data's id and index.
    symbol_font: Option<(u64, u32)>,
}

/// The terminal kept before hiding, or the one drawn now.
fn kept_terminal(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    match world.peek_part::<InputWorld>().and_then(|i| i.kept) {
        Some(kept) => Ok(kept),
        None => drawn_terminal(world),
    }
}

fn print_to_shell(world: &mut World, data: &str) -> Outcome {
    let thread_id = shown_thread(world);
    print(&mut world.mc, &thread_id, "term-1", data);
    world.sync()
}

/// Everything the terminal wrote to the shell, run together.
fn writes(world: &World) -> String {
    terminal_writes(world, "term-1").concat()
}

/// The middle of a cell of the screen, in the window.
fn cell_point(
    world: &World,
    brick: &Brick,
    terminal: ObjectId,
    column: f64,
    row: f64,
) -> Outcome<(f64, f64)> {
    let (ox, oy) = brick.at(world, terminal, 0.0, 0.0)?;
    let padding = number(brick, world, terminal, "padding");
    let width = number(brick, world, terminal, "cellWidth");
    let height = number(brick, world, terminal, "cellHeight");
    Ok((
        ox.trunc() + (padding + width * (column + 0.5)).trunc(),
        oy.trunc() + (padding + height * (row + 0.5)).trunc(),
    ))
}

/// A press at `from`, four moves and a release at `to`, holding `modifiers`.
fn drag(world: &mut World, from: (f64, f64), to: (f64, f64), modifiers: Modifiers) -> Outcome {
    world.pointer(|now| PointerEvent::press(from.0, from.1, now).with_modifiers(modifiers))?;
    for step in 1..=4 {
        let x = from.0 + ((to.0 - from.0) * f64::from(step) / 4.0).trunc();
        let y = from.1 + ((to.1 - from.1) * f64::from(step) / 4.0).trunc();
        world.pointer(|now| {
            PointerEvent::moved(x, y, MouseButtons::LEFT, now).with_modifiers(modifiers)
        })?;
    }
    world.pointer(|now| PointerEvent::release(to.0, to.1, now).with_modifiers(modifiers))?;
    world.sync()
}

fn middle(world: &World, brick: &Brick, terminal: ObjectId) -> Outcome<(f64, f64)> {
    let (x, y) = brick.at(world, terminal, 0.5, 0.5)?;
    Ok((x.trunc(), y.trunc()))
}

/// The drawn terminal, `lines` lines of output scrolled into its history.
fn terminal_with_history(world: &mut World, lines: usize) -> Outcome<(Brick, ObjectId)> {
    let (brick, terminal) = drawn_terminal(world)?;
    let output: String = (0..lines).map(|line| format!("line {line}\r\n")).collect();
    print_to_shell(world, &output)?;
    world.wait_for_with(
        move |w| {
            number(&brick, w, terminal, "scrollTotal")
                > number(&brick, w, terminal, "rows") + (lines / 4) as f64
        },
        move |w| {
            format!(
                "history; the terminal has {} rows",
                number(&brick, w, terminal, "scrollTotal")
            )
        },
    )?;
    Ok((brick, terminal))
}

/// The terminal the scenario already shows, as it is now: a full-screen
/// program hides the output [`drawn_terminal`] waits for.
fn shown_terminal(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    match world.peek_part::<Shown>().and_then(|shown| shown.0) {
        Some(brick) => {
            let terminal = brick.item(world, "HalC2Terminal")?;
            Ok((brick, terminal))
        }
        None => drawn_terminal(world),
    }
}

fn remember_offset(world: &mut World, brick: &Brick, terminal: ObjectId) {
    let offset = number(brick, world, terminal, "scrollOffset");
    world.part::<InputWorld>().scroll_before = offset;
}

fn rows_moved(world: &mut World) -> Outcome<f64> {
    let (brick, terminal) = shown_terminal(world)?;
    let after = number(&brick, world, terminal, "scrollOffset");
    Ok(world.part::<InputWorld>().scroll_before - after)
}

/// The rows the wheel's pixels add up to. A sum landing exactly on a row
/// may round to just under it, and that row then comes with the next
/// movement.
fn expect_rows(world: &mut World) -> Outcome {
    let (brick, terminal) = shown_terminal(world)?;
    let cell = number(&brick, world, terminal, "cellHeight");
    let pixels = world.part::<InputWorld>().wheel_pixels;
    let rows = rows_moved(world)?;
    expect!(
        rows >= ((pixels - 1.0) / cell).floor() && rows <= (pixels / cell).floor(),
        "{pixels} pixels of rows {cell} tall moved {rows} rows"
    );
    Ok(())
}

fn ask_for_mouse(world: &mut World) -> Outcome {
    let (brick, terminal) = drawn_terminal(world)?;
    print_to_shell(world, "\x1b[?1002h\x1b[?1006h")?;
    world.wait_for("the Terminal to hand the mouse to the program", move |w| {
        brick.flag(w, terminal, "mouseTracking")
    })
}

/// Whether anything is drawn in the cell two to the right of the cursor,
/// at the start of the third row: blank, unless something is composed over
/// it.
fn beside_the_cursor(world: &World, brick: &Brick, terminal: ObjectId) -> bool {
    let padding = number(brick, world, terminal, "padding");
    let width = number(brick, world, terminal, "cellWidth");
    let height = number(brick, world, terminal, "cellHeight");
    let cell = kurbo::Rect::new(
        padding + width * 2.0,
        padding + height * 2.0,
        padding + width * 3.0,
        padding + height * 3.0,
    );
    world.painted_ops(terminal).iter().any(|op| match op {
        DrawOp::Glyphs { run, origin, .. } => {
            let ink = run.bounds + *origin;
            // The row above's descenders reach into the cell a little.
            let overlap = ink.intersect(cell);
            overlap.width() > 0.0 && overlap.height() >= height / 2.0
        }
        _ => false,
    })
}

/// Puts row `offset` of the history at the top of the view.
fn scroll_view_to(world: &World, terminal: ObjectId, offset: f64) {
    let _ =
        world
            .engine()
            .invoke_by_name(terminal, "scrollTo", &[ljos::prelude::Value::Real(offset)]);
}

/// The item's box in the window: its top-left and bottom-right corners.
fn scene_rect(world: &World, brick: &Brick, item: ObjectId) -> Outcome<kurbo::Rect> {
    let (x0, y0) = brick.at(world, item, 0.0, 0.0)?;
    let (x1, y1) = brick.at(world, item, 1.0, 1.0)?;
    Ok(kurbo::Rect::new(x0, y0, x1, y1))
}

/// The scrollbar's history steps (desktop-qt's "a scrollbar shows where the
/// view sits in the history" and those after it).
fn register_scrollbar(steps: &mut Steps) {
    steps.step(
        "the terminal has more output than fits on screen",
        |world, _, _| {
            let (brick, terminal) = terminal_with_history(world, 300)?;
            take_keyboard(world, brick, terminal)?;
            // In the middle of the history, so every gesture has somewhere to go.
            let total = number(&brick, world, terminal, "scrollTotal");
            let rows = number(&brick, world, terminal, "rows");
            let middle = ((total - rows) / 2.0).trunc();
            scroll_view_to(world, terminal, middle);
            world.sync()?;
            remember_offset(world, &brick, terminal);
            let offset = number(&brick, world, terminal, "scrollOffset");
            expect!(offset == middle, "the view is at {offset}, not {middle}");
            Ok(())
        },
    );
    steps.step("the terminal has a very long history", |world, _, _| {
        terminal_with_history(world, 2000).map(|_| ())
    });
    steps.step(
        "a scrollbar shows where the view sits in the history",
        |world, _, _| {
            let (brick, terminal) = shown_terminal(world)?;
            let bar = brick.item(world, "terminalScrollbar")?;
            let thumb = brick.item(world, "terminalScrollbarThumb")?;
            expect!(brick.flag(world, bar, "visible"), "no scrollbar");
            scroll_view_to(world, terminal, 0.0);
            world.sync()?;
            let top = number(&brick, world, thumb, "y");
            expect!(top == 0.0, "at the oldest output the thumb is at {top}");
            let _ = world
                .engine()
                .invoke_by_name(terminal, "scrollToBottom", &[]);
            world.sync()?;
            let end = number(&brick, world, thumb, "y") + number(&brick, world, thumb, "height");
            let height = number(&brick, world, bar, "height");
            expect!(
                (end - height).abs() < 1.0,
                "at the newest output the thumb ends at {end} of {height}"
            );
            Ok(())
        },
    );
    steps.step(
        "the drawer's buttons leave the scrollbar clear",
        |world, _, _| {
            let (brick, terminal) = shown_terminal(world)?;
            let thumb = brick.item(world, "terminalScrollbarThumb")?;
            let actions = brick.item(world, "terminalDrawerActions")?;
            scroll_view_to(world, terminal, 0.0);
            world.sync()?;
            // The buttons sit on a background 2 pixels wider than they are.
            let buttons = scene_rect(world, &brick, actions)?.inflate(2.0, 2.0);
            let grip = scene_rect(world, &brick, thumb)?;
            let overlap = buttons.intersect(grip);
            expect!(
                overlap.width() <= 0.0 || overlap.height() <= 0.0,
                "at the oldest output the thumb is under the buttons"
            );
            Ok(())
        },
    );
    steps.step(
        "the scrollbar is hidden while everything fits",
        |world, _, _| {
            let (brick, terminal) = shown_terminal(world)?;
            let _ = world.engine().invoke_by_name(terminal, "reset", &[]);
            let bar = brick.item(world, "terminalScrollbar")?;
            world.wait_for("the scrollbar to hide", move |w| {
                !brick.flag(w, bar, "visible")
            })
        },
    );
    steps.step("the user drags the scrollbar's thumb", |world, _, _| {
        let (brick, terminal) = shown_terminal(world)?;
        let bar = brick.item(world, "terminalScrollbar")?;
        let thumb = brick.item(world, "terminalScrollbarThumb")?;
        let max_offset = number(&brick, world, terminal, "scrollTotal")
            - number(&brick, world, terminal, "rows");
        let travel = number(&brick, world, bar, "height") - number(&brick, world, thumb, "height");
        let start_top = number(&brick, world, thumb, "y");
        let (x, y) = brick.at(world, thumb, 0.5, 0.5)?;
        let (x, y) = (x.trunc(), y.trunc());
        world.pointer(|now| PointerEvent::press(x, y, now))?;
        for moved in [-10.0, -20.0, -30.0] {
            world.pointer(|now| PointerEvent::moved(x, y + moved, MouseButtons::LEFT, now))?;
            world.sync()?;
            let expected = ((start_top + moved) / travel * max_offset).round();
            let offset = number(&brick, world, terminal, "scrollOffset");
            expect!(
                (offset - expected).abs() <= 1.0,
                "{} pixels up the view is at {offset}, not {expected}",
                -moved
            );
            world.part::<InputWorld>().expected_offset = expected;
        }
        world.pointer(|now| PointerEvent::release(x, y - 30.0, now))?;
        world.sync()
    });
    steps.step("the view follows the thumb row for row", |world, _, _| {
        let (brick, terminal) = shown_terminal(world)?;
        let expected = world.part::<InputWorld>().expected_offset;
        let before = world.part::<InputWorld>().scroll_before;
        let offset = number(&brick, world, terminal, "scrollOffset");
        expect!(
            (offset - expected).abs() <= 1.0 && offset < before,
            "the view is at {offset}, not {expected}"
        );
        expect!(
            brick.flag(world, terminal, "activeFocus"),
            "the terminal lost the keyboard"
        );
        Ok(())
    });
    steps.step("the user clicks the scrollbar's track", |world, _, _| {
        let (brick, terminal) = shown_terminal(world)?;
        let bar = brick.item(world, "terminalScrollbar")?;
        let thumb = brick.item(world, "terminalScrollbarThumb")?;
        let thumb_height = number(&brick, world, thumb, "height");
        let bar_height = number(&brick, world, bar, "height");
        let y = (thumb_height / 2.0).trunc() + 3.0;
        let max_offset = number(&brick, world, terminal, "scrollTotal")
            - number(&brick, world, terminal, "rows");
        world.part::<InputWorld>().expected_offset =
            (3.0 / (bar_height - thumb_height) * max_offset).round();
        let (x, y) = brick.at(world, bar, 0.5, y / bar_height)?;
        world.click_at_with(x.trunc(), y.trunc(), MouseButtons::LEFT, Modifiers::empty())?;
        world.sync()
    });
    steps.step(
        "the view jumps to that place in the history",
        |world, _, _| {
            let (brick, terminal) = shown_terminal(world)?;
            let expected = world.part::<InputWorld>().expected_offset;
            let offset = number(&brick, world, terminal, "scrollOffset");
            expect!(
                (offset - expected).abs() <= 1.0,
                "the view is at {offset}, not {expected}"
            );
            Ok(())
        },
    );
    steps.step(
        "the user presses (Page Up|Page Down|Home|End|an arrow key) on the scrollbar",
        |world, c, _| {
            let (brick, _) = shown_terminal(world)?;
            let bar = brick.item(world, "terminalScrollbar")?;
            let _ = world.engine().invoke_by_name(bar, "forceActiveFocus", &[]);
            world.wait_for("the scrollbar to take the keyboard", move |w| {
                brick.flag(w, bar, "activeFocus")
            })?;
            let spelt = match c[0].as_str() {
                "Page Up" => "pageup",
                "Page Down" => "pagedown",
                "Home" => "home",
                "End" => "end",
                _ => "up",
            };
            let event = crate::brick::key_event(spelt)?;
            world.key(&event)?;
            world.sync()
        },
    );
    steps.step(
        "the view (moves up a screenful|moves down a screenful|moves to the oldest output|moves to the newest output|moves one row)",
        |world, c, _| {
            let (brick, terminal) = shown_terminal(world)?;
            let before = world.part::<InputWorld>().scroll_before;
            let rows = number(&brick, world, terminal, "rows");
            let expected = match c[0].as_str() {
                "moves up a screenful" => before - rows,
                "moves down a screenful" => before + rows,
                "moves to the oldest output" => 0.0,
                "moves to the newest output" => number(&brick, world, terminal, "scrollTotal") - rows,
                _ => before - 1.0,
            };
            let offset = number(&brick, world, terminal, "scrollOffset");
            expect!(offset == expected, "the view is at {offset}, not {expected}");
            expect!(
                writes(world).is_empty(),
                "the shell got {}",
                describe_terminal_calls(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the scrollbar's thumb is never smaller than a small grab target",
        |world, _, _| {
            let (brick, terminal) = shown_terminal(world)?;
            let bar = brick.item(world, "terminalScrollbar")?;
            let thumb = brick.item(world, "terminalScrollbarThumb")?;
            let proportional = number(&brick, world, bar, "height")
                * number(&brick, world, terminal, "rows")
                / number(&brick, world, terminal, "scrollTotal");
            expect!(
                proportional < 18.0,
                "the history is too short to show it: {proportional}"
            );
            let height = number(&brick, world, thumb, "height");
            expect!(height >= 18.0, "the thumb is {height} tall");
            Ok(())
        },
    );
}

/// The height the Terminals controller keeps for the drawer.
fn kept_height(world: &World) -> f64 {
    controller::with::<Terminals, _>(world.engine(), |t, _| f64::from(t.height())).unwrap_or(0.0)
}

/// Everything the terminal item painted at the last frame, spelt out.
fn painted_now(world: &World, terminal: ObjectId) -> String {
    format!("{:?}", world.painted_ops(terminal))
}

/// Whether the terminal painted glyphs on screen row `row`.
fn painted_row(world: &World, brick: &Brick, terminal: ObjectId, row: f64) -> bool {
    let padding = number(brick, world, terminal, "padding");
    let height = number(brick, world, terminal, "cellHeight");
    let middle = padding + height * (row + 0.5);
    world.painted_ops(terminal).iter().any(|op| match op {
        DrawOp::Glyphs { run, origin, .. } => {
            let ink = run.bounds + *origin;
            ink.width() > 0.0 && ink.y0 <= middle && ink.y1 >= middle
        }
        _ => false,
    })
}

/// The shell is still 120 by 30, and nothing resized it since.
fn not_resized(world: &World, brick: &Brick, terminal: ObjectId) -> Outcome {
    let calls = terminal_calls_of(world, "terminal.resize");
    let before = world
        .peek_part::<InputWorld>()
        .map_or(0, |i| i.resize_calls);
    expect!(
        calls == before,
        "the shell was resized: {}",
        describe_terminal_calls(world)
    );
    let columns = number(brick, world, terminal, "columns");
    let rows = number(brick, world, terminal, "rows");
    expect!(
        columns == 120.0 && rows == 30.0,
        "the screen is {columns}x{rows}"
    );
    Ok(())
}

/// Half the cursor flash time, the length of a blink's half.
fn half_blink(world: &World) -> u64 {
    hal_c2_shell::terminal::cursor_flash_ms(world.engine()) / 2
}

/// Whether the terminal paints its cursor as an outline: four one-pixel
/// edges, and no solid block.
fn hollow_cursor(world: &World, terminal: ObjectId) -> bool {
    let edges = world
        .painted_ops(terminal)
        .iter()
        .filter(|op| match op {
            DrawOp::Rect { rect, .. } => {
                (rect.width() == 1.0 && rect.height() > 1.0)
                    || (rect.height() == 1.0 && rect.width() > 1.0)
            }
            _ => false,
        })
        .count();
    edges >= 4
}

/// The terminal draws the same through a whole blink, off half included.
fn steady(world: &mut World, terminal: ObjectId) -> Outcome {
    let before = painted_now(world, terminal);
    let quarter = half_blink(world) / 2;
    for _ in 0..6 {
        world.advance(quarter)?;
        expect!(painted_now(world, terminal) == before, "the cursor changed");
    }
    Ok(())
}

fn register_cursor(steps: &mut Steps) {
    steps.step("the shell asked for a blinking cursor", |world, _, _| {
        drawn_terminal(world)?;
        print_to_shell(world, "\x1b[1 q")
    });
    steps.step("the user prefers reduced motion", |world, _, _| {
        Settings::of(world.engine()).set(world.engine(), "reduceMotion", json!(true));
        world.wait_for("the preference to be saved", |w| {
            Settings::of(w.engine())
                .setting(w.engine(), "reduceMotion")
                .and_then(|v| v.as_bool())
                == Some(true)
        })?;
        world.sync()
    });
    steps.step("the terminal has focus", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        take_keyboard(world, brick, terminal)
    });
    steps.step("the cursor blinks", |world, _, _| {
        let (_, terminal) = drawn_terminal(world)?;
        world.sync()?;
        let first = painted_now(world, terminal);
        world.wait_for("the cursor to change", move |w| {
            painted_now(w, terminal) != first
        })
    });
    steps.step("the cursor does not blink", |world, _, _| {
        let (_, terminal) = drawn_terminal(world)?;
        world.sync()?;
        steady(world, terminal)
    });
    steps.step("the terminal loses focus", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        let Some(root) = brick.root(world) else {
            fail!("no brick is showing");
        };
        let _ = world.engine().invoke_by_name(root, "forceActiveFocus", &[]);
        world.wait_for("the terminal to lose the keyboard", move |w| {
            !brick.flag(w, terminal, "activeFocus")
        })?;
        world.sync()
    });
    steps.step(
        "the cursor is drawn as an outline and does not blink",
        |world, _, _| {
            let (_, terminal) = drawn_terminal(world)?;
            world.wait_for("a hollow cursor", move |w| hollow_cursor(w, terminal))?;
            steady(world, terminal)
        },
    );
}

fn register_hiding(steps: &mut Steps) {
    steps.step(
        "the terminal is running a build that prints continuously",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            world.part::<InputWorld>().kept = Some((brick, terminal));
            print_to_shell(world, "building 1\r\n")?;
            world.wait_for("the output to be drawn", move |w| {
                call(w, terminal, "text").contains("building 1")
                    && painted_row(w, &brick, terminal, 2.0)
            })
        },
    );
    // desktop-qt counts the window's frames; Ljós's TestWindow has no frame
    // count, so this asks that the hidden terminal paints nothing new.
    steps.step("the terminal does no drawing work", |world, _, _| {
        world.wait_for("the terminal to hide", |w| !drawer_open(w))?;
        world.sync()?;
        let (_, terminal) = kept_terminal(world)?;
        let before = painted_now(world, terminal);
        print_to_shell(world, "building 2\r\nbuilding 3\r\n")?;
        world.advance(100)?;
        world.sync()?;
        expect!(
            painted_now(world, terminal) == before,
            "the hidden terminal painted again"
        );
        world.part::<InputWorld>().painted = before;
        Ok(())
    });
    steps.step(
        "the shell's output keeps being read and its replies keep being sent",
        |world, _, _| {
            let (_, terminal) = kept_terminal(world)?;
            // A program asks for the terminal's status while nothing shows it.
            print_to_shell(world, "\x1b[5n")?;
            world.wait_for_with(
                |w| writes(w).contains("\x1b[0n"),
                |w| {
                    format!(
                        "the status reply; the MC got {}",
                        describe_terminal_calls(w)
                    )
                },
            )?;
            let text = call(world, terminal, "text");
            expect!(
                text.contains("building 3"),
                "the output was not read: {text}"
            );
            Ok(())
        },
    );
    steps.step("the user shows the terminal again", |world, _, _| {
        world.dispatch("terminal.toggle", json!({}))?;
        world.wait_for("the terminal to show", drawer_open)?;
        world.sync()
    });
    steps.step(
        "the terminal is drawn in full and shows the latest output",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            world.wait_for("the terminal to be visible", move |w| {
                brick.flag(w, terminal, "visible")
            })?;
            let text = call(world, terminal, "text");
            expect!(text.contains("building 3"), "it shows \"{text}\"");
            // Row 4 is "building 3": OUTPUT's two lines come first.
            world.wait_for("the latest row to be drawn", move |w| {
                painted_row(w, &brick, terminal, 4.0)
            })
        },
    );
    steps.step(
        "the shell is running at 120 columns and 30 rows",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let padding = number(&brick, world, terminal, "padding");
            let width =
                (120.0 * number(&brick, world, terminal, "cellWidth") + 2.0 * padding).ceil();
            let Some(root) = brick.root(world) else {
                fail!("no brick is showing");
            };
            world.resize(width, 1000.0)?;
            brick.write(world, root, "width", ljos::prelude::Value::from(width))?;
            brick.write(world, root, "height", ljos::prelude::Value::from(1000.0))?;
            world.sync()?;
            let rows = number(&brick, world, terminal, "rows");
            let height = kept_height(world)
                + ((30.0 - rows) * number(&brick, world, terminal, "cellHeight")).ceil();
            world.dispatch("terminal.resize", json!({ "height": height }))?;
            world.wait_for_with(
                move |w| {
                    let resize =
                        last_terminal_call(w, "terminal.resize", &shown_thread(w), "term-1");
                    number(&brick, w, terminal, "columns") == 120.0
                        && number(&brick, w, terminal, "rows") == 30.0
                        && resize.is_some_and(|r| r["cols"] == 120 && r["rows"] == 30)
                },
                move |w| {
                    format!(
                        "120x30; it is {}x{} and the MC got {}",
                        number(&brick, w, terminal, "columns"),
                        number(&brick, w, terminal, "rows"),
                        describe_terminal_calls(w)
                    )
                },
            )?;
            world.sync()?;
            let calls = terminal_calls_of(world, "terminal.resize");
            let input = world.part::<InputWorld>();
            input.resize_calls = calls;
            input.kept = Some((brick, terminal));
            Ok(())
        },
    );
    steps.step(
        "the user hides the terminal so that it has no size",
        |world, _, _| {
            let (brick, _) = kept_terminal(world)?;
            let drawer = brick.item(world, "drawer")?;
            world.dispatch("terminal.toggle", json!({}))?;
            world.wait_for("the drawer to have no size", move |w| {
                number(&brick, w, drawer, "height") == 0.0
            })?;
            world.sync()
        },
    );
    steps.step("the shell is not resized", |world, _, _| {
        let (brick, terminal) = kept_terminal(world)?;
        not_resized(world, &brick, terminal)
    });
    steps.step(
        "the user shows the terminal at the same size again",
        |world, _, _| {
            let (brick, _) = kept_terminal(world)?;
            let drawer = brick.item(world, "drawer")?;
            world.dispatch("terminal.toggle", json!({}))?;
            world.wait_for("the drawer to show", move |w| {
                number(&brick, w, drawer, "height") > 0.0
            })?;
            world.sync()
        },
    );
    steps.step("it is drawn again without a resize", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        not_resized(world, &brick, terminal)?;
        world.wait_for("the terminal to draw", move |w| {
            painted_row(w, &brick, terminal, 0.0)
        })
    });
}

/// The bottom of the last row, in the window.
fn prompt_bottom(world: &World, brick: &Brick, terminal: ObjectId) -> Outcome<f64> {
    let padding = number(brick, world, terminal, "padding");
    let rows = number(brick, world, terminal, "rows");
    let cell = number(brick, world, terminal, "cellHeight");
    Ok(brick.at_px(world, terminal, 0.0, padding + rows * cell)?.1)
}

/// Dragging past an edge, and the prompt on the bottom edge.
fn register_edges(steps: &mut Steps) {
    steps.step("the terminal has scrolled-back output", |world, _, _| {
        let (brick, terminal) = terminal_with_history(world, 300)?;
        let total = number(&brick, world, terminal, "scrollTotal");
        let rows = number(&brick, world, terminal, "rows");
        scroll_view_to(world, terminal, ((total - rows) / 2.0).trunc());
        world.sync()?;
        remember_offset(world, &brick, terminal);
        Ok(())
    });
    steps.step(
        "the user drags a selection past the top of the terminal and holds it there",
        |world, _, _| {
            let (brick, terminal) = shown_terminal(world)?;
            let end = cell_point(world, &brick, terminal, 30.0, 3.0)?;
            let (ox, oy) = brick.at(world, terminal, 0.0, 0.0)?;
            let padding = number(&brick, world, terminal, "padding");
            let start = (ox.trunc() + padding.trunc() + 1.0, end.1);
            world.pointer(|now| PointerEvent::press(end.0, end.1, now))?;
            world.pointer(|now| PointerEvent::moved(start.0, start.1, MouseButtons::LEFT, now))?;
            world.sync()?;
            // Backwards over the whole of a line, so it is the selection's last.
            let from = call(world, terminal, "selectedText").trim().to_owned();
            expect!(from.starts_with("line "), "the drag selected \"{from}\"");
            world.part::<InputWorld>().dragged_from = from;
            let above = (start.0, oy.trunc() - 8.0);
            expect!(above.1 >= 0.0, "the terminal has no room above it");
            world.pointer(|now| PointerEvent::moved(above.0, above.1, MouseButtons::LEFT, now))?;
            Ok(())
        },
    );
    steps.step("the history keeps scrolling up", |world, _, _| {
        let (brick, terminal) = shown_terminal(world)?;
        // More rows than any one move scrolls, with the pointer held still.
        let before = world.part::<InputWorld>().scroll_before;
        world.wait_for_with(
            move |w| number(&brick, w, terminal, "scrollOffset") <= before - 5.0,
            move |w| {
                format!(
                    "the view to keep scrolling; it is at {} of {before}",
                    number(&brick, w, terminal, "scrollOffset")
                )
            },
        )
    });
    steps.step("the selection grows with it", |world, _, _| {
        let (brick, terminal) = shown_terminal(world)?;
        let selected = call(world, terminal, "selectedText");
        let lines: Vec<&str> = selected.split('\n').filter(|l| !l.is_empty()).collect();
        let (ox, _) = brick.at(world, terminal, 0.0, 0.0)?;
        world.pointer(|now| PointerEvent::release(ox, 0.0, now))?;
        // It still ends on the text it began on, and takes in the older lines.
        let from = world.part::<InputWorld>().dragged_from.clone();
        expect!(
            lines.len() > 3 && lines.last().map(|l| l.trim()) == Some(from.as_str()),
            "the selection from \"{from}\" is {}",
            lines.join("|")
        );
        Ok(())
    });
    steps.step(
        "the terminal has history and its height is not a whole number of rows",
        |world, _, _| {
            let (brick, terminal) = terminal_with_history(world, 300)?;
            // One pixel over a whole number of rows, wherever the drawer's
            // height left it.
            let cell = number(&brick, world, terminal, "cellHeight");
            let rows = number(&brick, world, terminal, "rows");
            let padding = number(&brick, world, terminal, "padding");
            let own = scene_rect(world, &brick, terminal)?.height();
            let height = kept_height(world) + 1.0 + (rows * cell + 2.0 * padding - own).trunc();
            world.dispatch("terminal.resize", json!({ "height": height }))?;
            world.wait_for("the terminal to take its height", move |w| {
                kept_height(w) == height
            })?;
            world.sync()
        },
    );
    steps.step(
        "the leftover space is above the first row and not below the prompt",
        |world, _, _| {
            let (brick, terminal) = shown_terminal(world)?;
            let cell = brick.item(world, "terminalCell-term-1")?;
            let cell_y = number(&brick, world, cell, "y");
            expect!(cell_y > 0.0, "no space is left over above the first row");
            let drawer = brick.item(world, "drawer")?;
            let padding = number(&brick, world, terminal, "padding");
            let edge = brick.at(world, drawer, 0.0, 1.0)?.1;
            world.wait_for_with(
                move |w| {
                    prompt_bottom(w, &brick, terminal)
                        .is_ok_and(|p| (0.0..1.0).contains(&(edge - padding - p)))
                },
                move |w| {
                    let p = prompt_bottom(w, &brick, terminal).unwrap_or_default();
                    format!(
                        "the prompt ends {} pixels above the padding",
                        edge - padding - p
                    )
                },
            )?;
            world.part::<InputWorld>().prompt_y = prompt_bottom(world, &brick, terminal)?;
            Ok(())
        },
    );
    steps.step(
        "the prompt does not shift while the user drags a selection across rows",
        |world, _, _| {
            let (brick, terminal) = shown_terminal(world)?;
            let from = cell_point(world, &brick, terminal, 1.0, 1.0)?;
            let to = cell_point(world, &brick, terminal, 3.0, 4.0)?;
            drag(world, from, to, Modifiers::empty())?;
            expect!(
                brick.flag(world, terminal, "hasSelection"),
                "nothing was selected"
            );
            let bottom = prompt_bottom(world, &brick, terminal)?;
            let prompt_y = world.part::<InputWorld>().prompt_y;
            expect!(
                bottom == prompt_y,
                "the prompt moved to {bottom}, from {prompt_y}"
            );
            Ok(())
        },
    );
}

/// The terminal's own font, laid out as its cells are.
fn own_style(world: &World, terminal: ObjectId) -> ljos::item::TextStyle {
    let font = ljos::item::prop(world.engine(), terminal, Terminal::FONT);
    ljos::item::text_style(world.engine(), &font)
}

/// The fonts `text` is set in, laid out in `style`.
fn fonts_of(text: &str, style: &ljos::item::TextStyle) -> Vec<(u64, u32)> {
    ljos::item::with_text_engine(|te| {
        te.layout(text, style, &ljos::item::LayoutParams::default())
            .lines
            .iter()
            .flat_map(|line| &line.runs)
            .map(|run| (run.glyphs.font.data.id(), run.glyphs.font.index))
            .collect()
    })
    .unwrap_or_default()
}

/// The font of a glyph the terminal drew in its first cell, when it is no
/// missing-glyph box.
fn first_cell_font(world: &World, brick: &Brick, terminal: ObjectId) -> Option<(u64, u32)> {
    let padding = number(brick, world, terminal, "padding");
    let width = number(brick, world, terminal, "cellWidth");
    let height = number(brick, world, terminal, "cellHeight");
    world.painted_ops(terminal).iter().find_map(|op| match op {
        DrawOp::Glyphs { run, origin, .. } => run
            .glyphs
            .iter()
            .any(|glyph| {
                let x = origin.x + f64::from(glyph.x);
                let y = origin.y + f64::from(glyph.y);
                glyph.id != 0 && x < padding + width && y > padding && y <= padding + height
            })
            .then(|| (run.font.data.id(), run.font.index)),
        _ => None,
    })
}

// Prompt symbols. A machine can't be made to lack a font here, so this asks
// what the terminal draws them in: the bundled font, found by coverage.
fn register_symbols(steps: &mut Steps) {
    steps.step("the machine has no Nerd Font installed", |world, _, _| {
        drawn_terminal(world)?;
        Ok(())
    });
    steps.step(
        "the shell prints a prompt with powerline separators and file-type icons",
        |world, _, _| {
            let (_, terminal) = drawn_terminal(world)?;
            call(world, terminal, "reset");
            print_to_shell(world, "\x1b[H\u{e0b0} \u{f015}")
        },
    );
    steps.step("the terminal draws those symbols", |world, _, _| {
        let (brick, terminal) = shown_terminal(world)?;
        world.wait_for_with(
            move |w| first_cell_font(w, &brick, terminal).is_some(),
            move |w| {
                format!(
                    "the separator to be drawn; the terminal painted {}",
                    painted_now(w, terminal)
                )
            },
        )?;
        let symbol = first_cell_font(world, &brick, terminal);
        let own = fonts_of("M", &own_style(world, terminal));
        expect!(
            symbol.is_some_and(|font| !own.contains(&font)),
            "the separator is drawn in the terminal's own font, which has no such glyph"
        );
        world.part::<InputWorld>().symbol_font = symbol;
        Ok(())
    });
    steps.step(
        "the text keeps its own font and cell size",
        |world, _, _| {
            let (brick, terminal) = shown_terminal(world)?;
            let style = own_style(world, terminal);
            let Some((width, height)) = ljos::item::with_text_engine(|te| {
                (
                    te.advance_width("M", &style),
                    te.font_metrics(&style).line_height,
                )
            }) else {
                fail!("no text engine");
            };
            let cell_width = number(&brick, world, terminal, "cellWidth");
            let cell_height = number(&brick, world, terminal, "cellHeight");
            expect!(
                cell_width == width.max(1.0) && cell_height == height.max(1.0),
                "cells are {cell_width} by {cell_height}, the font's \"M\" {width} by {height}"
            );
            Ok(())
        },
    );
    steps.step(
        "text outside the terminal does not take the symbol font",
        |world, _, _| {
            shown_terminal(world)?;
            let Some(symbol) = world.part::<InputWorld>().symbol_font else {
                fail!("the symbols were not drawn");
            };
            // Only a character no other font has falls back to it.
            let style = ljos::item::text_style(world.engine(), &ljos::item::Font::default());
            expect!(
                !fonts_of("The quick brown fox, 0123 ->", &style).contains(&symbol),
                "the app's text is set in the symbol font"
            );
            Ok(())
        },
    );
}

pub fn register(steps: &mut Steps) {
    register_edges(steps);
    register_hiding(steps);
    register_cursor(steps);
    register_symbols(steps);
    register_scrollbar(steps);
    steps.step("the selection (is cleared|stays)", |world, c, _| {
        let (brick, terminal) = shown_terminal(world)?;
        let stays = c[0] == "stays";
        let has = brick.flag(world, terminal, "hasSelection");
        expect!(
            has == stays,
            "the terminal {} a selection",
            if has { "still has" } else { "has no" }
        );
        Ok(())
    });
    // Keys that reach the shell through the terminal's chords.
    steps.step(&format!("the shell prompt holds {Q}"), |world, c, _| {
        drawn_terminal(world)?;
        print_to_shell(world, &format!("$ {}", c[0]))
    });
    steps.step(
        "the shell receives the command that deletes to the start of the line",
        |world, _, _| {
            world.wait_for_with(
                |w| terminal_writes(w, "term-1").iter().any(|s| s == "\x15"),
                |w| {
                    format!(
                        "Ctrl-U to be written; the MC got {}",
                        describe_terminal_calls(w)
                    )
                },
            )
        },
    );
    steps.step(
        "the terminal's cursor moves (one word left|one word right|to the start of the line|to the end of the line)",
        |world, c, _| {
            let expected = match c[0].as_str() {
                "one word left" => "\x1bb",
                "one word right" => "\x1bf",
                "to the start of the line" => "\x01",
                _ => "\x05",
            };
            world.wait_for_with(
                move |w| terminal_writes(w, "term-1").iter().any(|s| s == expected),
                |w| {
                    format!(
                        "the movement to be written; the MC got {}",
                        describe_terminal_calls(w)
                    )
                },
            )
        },
    );
    steps.step(
        "the shell receives the key as the terminal encodes it",
        |world, _, _| {
            world.wait_for_with(
                |w| writes(w).contains("\x1b[1;4D"),
                |w| {
                    format!(
                        "Shift+Alt+Left as CSI 1;4 D; the MC got {}",
                        describe_terminal_calls(w)
                    )
                },
            )
        },
    );
    steps.step("no word or line movement is sent", |world, _, _| {
        let sent = terminal_writes(world, "term-1");
        for movement in ["\x1bb", "\x1bf", "\x01", "\x05"] {
            expect!(
                !sent.iter().any(|s| s == movement),
                "the MC got {}",
                describe_terminal_calls(world)
            );
        }
        Ok(())
    });

    // Selecting with the mouse.
    steps.step(&format!("the shell has printed {Q}"), |world, c, _| {
        let (_, terminal) = drawn_terminal(world)?;
        print_to_shell(world, &format!("{}\r\n", c[0]))?;
        let line = c[0].clone();
        world.wait_for("the line on screen", move |w| {
            call(w, terminal, "text").contains(&line)
        })
    });
    steps.step(
        &format!("the user clicks (twice|3 times) in quick succession on {Q}"),
        |world, c, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let Some(column) = "git commit -m fix".find(&c[1]) else {
                fail!("\"{}\" is not on the line", c[1]);
            };
            let (x, y) = cell_point(world, &brick, terminal, column as f64 + 1.0, 2.0)?;
            let times = if c[0] == "twice" { 2 } else { 3 };
            for _ in 0..times {
                world.click_at_with(x, y, MouseButtons::LEFT, Modifiers::empty())?;
            }
            world.sync()
        },
    );
    steps.step(
        &format!("{Q} is selected in the terminal"),
        |world, c, _| {
            let (_, terminal) = drawn_terminal(world)?;
            let wanted = c[0].clone();
            world.wait_for_with(
                move |w| call(w, terminal, "selectedText") == wanted,
                move |w| format!("\"{}\" is selected", call(w, terminal, "selectedText")),
            )
        },
    );

    // A middle click where the button pastes nothing.
    steps.step("the user middle-clicks the terminal", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        let (x, y) = middle(world, &brick, terminal)?;
        world.click_at_with(x, y, MouseButtons::MIDDLE, Modifiers::empty())?;
        world.sync()
    });
    steps.step("nothing is sent to the shell", |world, _, _| {
        expect!(
            terminal_writes(world, "term-1").is_empty(),
            "the MC got {}",
            describe_terminal_calls(world)
        );
        Ok(())
    });

    // Programs that take the mouse.
    steps.step(
        "a program in the terminal has asked to receive mouse events",
        |world, _, _| ask_for_mouse(world),
    );
    steps.step(
        "the user clicks and drags in the terminal",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let from = cell_point(world, &brick, terminal, 1.0, 0.0)?;
            let to = cell_point(world, &brick, terminal, 6.0, 0.0)?;
            drag(world, from, to, Modifiers::empty())
        },
    );
    steps.step(
        "the program receives the presses, motion and releases",
        |world, _, _| {
            let sent = writes(world);
            let calls = describe_terminal_calls(world);
            expect!(sent.contains("\x1b[<0;2;1M"), "no press: {calls}");
            expect!(sent.contains("\x1b[<32;"), "no motion: {calls}");
            expect!(sent.contains("\x1b[<0;7;1m"), "no release: {calls}");
            Ok(())
        },
    );
    steps.step("no text is selected", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        expect!(
            !brick.flag(world, terminal, "hasSelection"),
            "the terminal has a selection"
        );
        Ok(())
    });
    steps.step(
        "the user drags in the terminal holding (Shift|Ctrl|Cmd)",
        |world, c, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            // As the toolkit reports them off macOS, where Cmd is Meta.
            let modifier = match c[0].as_str() {
                "Shift" => Modifiers::SHIFT,
                "Ctrl" => Modifiers::CONTROL,
                _ => Modifiers::META,
            };
            let from = cell_point(world, &brick, terminal, 0.0, 0.0)?;
            let to = cell_point(world, &brick, terminal, 6.0, 0.0)?;
            drag(world, from, to, modifier)
        },
    );
    steps.step("the text is selected", |world, _, _| {
        let (_, terminal) = drawn_terminal(world)?;
        world.wait_for_with(
            move |w| call(w, terminal, "selectedText").starts_with("FAIL"),
            move |w| {
                format!(
                    "the text selected; \"{}\" is",
                    call(w, terminal, "selectedText")
                )
            },
        )
    });
    steps.step("the program receives nothing", |world, _, _| {
        expect!(
            terminal_writes(world, "term-1").is_empty(),
            "the MC got {}",
            describe_terminal_calls(world)
        );
        Ok(())
    });
    steps.step("the user scrolls the wheel", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        let (x, y) = middle(world, &brick, terminal)?;
        world.wheel(x, y, 1.0)?;
        world.sync()
    });
    steps.step("the program receives wheel events", |world, _, _| {
        world.wait_for_with(
            |w| writes(w).contains("\x1b[<64;"),
            |w| format!("wheel presses; the MC got {}", describe_terminal_calls(w)),
        )
    });

    // The wheel.
    steps.step(
        "a full-screen program such as an editor or pager is showing",
        |world, _, _| {
            let (brick, terminal) = terminal_with_history(world, 300)?;
            print_to_shell(world, "\x1b[?1049h")?;
            remember_offset(world, &brick, terminal);
            Ok(())
        },
    );
    steps.step(
        "the user scrolls the wheel down three rows",
        |world, _, _| {
            let (brick, terminal) = shown_terminal(world)?;
            let (x, y) = middle(world, &brick, terminal)?;
            world.wheel(x, y, -1.0)?;
            world.sync()
        },
    );
    steps.step("the shell receives three down-arrow keys", |world, _, _| {
        world.wait_for_with(
            |w| writes(w) == "\x1b[B\x1b[B\x1b[B",
            |w| {
                format!(
                    "three down-arrows; the MC got {}",
                    describe_terminal_calls(w)
                )
            },
        )
    });
    steps.step(
        "the terminal's own history does not scroll",
        |world, _, _| {
            let moved = rows_moved(world)?;
            expect!(moved == 0.0, "the view moved {moved} rows");
            Ok(())
        },
    );
    steps.step(
        "the terminal has history above what is on screen",
        |world, _, _| {
            let (brick, terminal) = terminal_with_history(world, 300)?;
            remember_offset(world, &brick, terminal);
            Ok(())
        },
    );
    steps.step(
        "the user scrolls with a trackpad in many movements each smaller than a row",
        |world, _, _| {
            let (brick, terminal) = shown_terminal(world)?;
            let cell = number(&brick, world, terminal, "cellHeight");
            let movement = (cell / 3.0).trunc().max(1.0);
            let (x, y) = middle(world, &brick, terminal)?;
            for _ in 0..20 {
                world.wheel_pixels(x, y, movement)?;
                world.sync()?;
                world.part::<InputWorld>().wheel_pixels += movement;
                expect_rows(world)?;
            }
            Ok(())
        },
    );
    steps.step(
        "the terminal scrolls one row each time the movements add up to a row",
        |world, _, _| {
            let moved = rows_moved(world)?;
            expect!(moved > 0.0, "the view did not move");
            Ok(())
        },
    );
    steps.step("no movement is lost", |world, _, _| expect_rows(world));
    steps.step("the wheel reports three lines", |world, _, _| {
        let (brick, terminal) = shown_terminal(world)?;
        let (x, y) = middle(world, &brick, terminal)?;
        world.wheel(x, y, 1.0)?;
        world.sync()
    });
    steps.step("the terminal scrolls three rows", |world, _, _| {
        let moved = rows_moved(world)?;
        expect!(moved == 3.0, "it moved {moved} rows");
        Ok(())
    });
    steps.step("the wheel reports pixels", |world, _, _| {
        let (brick, terminal) = shown_terminal(world)?;
        let cell = number(&brick, world, terminal, "cellHeight");
        let (x, y) = middle(world, &brick, terminal)?;
        world.wheel_pixels(x, y, (cell * 2.5).trunc())?;
        world.sync()
    });
    steps.step(
        "the terminal scrolls by that many pixels, rounded down to rows",
        |world, _, _| {
            let moved = rows_moved(world)?;
            expect!(moved == 2.0, "2.5 rows of pixels moved {moved} rows");
            Ok(())
        },
    );

    // Input methods.
    steps.step(
        &format!("the user composes {Q} with an input method in the terminal"),
        |world, c, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            take_keyboard(world, brick, terminal)?;
            world.preedit("にほ")?;
            world.sync()?;
            expect!(
                terminal_writes(world, "term-1").is_empty(),
                "the composition reached the shell: {}",
                describe_terminal_calls(world)
            );
            world.type_text(&c[0])?;
            world.sync()
        },
    );
    steps.step(
        "the user is composing with an input method in the terminal",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            take_keyboard(world, brick, terminal)?;
            world.preedit("にほ")?;
            world.sync()
        },
    );
    steps.step(
        "what is being composed is drawn at the cursor",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            world.wait_for("the composition to be drawn", move |w| {
                beside_the_cursor(w, &brick, terminal)
            })?;
            expect!(
                terminal_writes(world, "term-1").is_empty(),
                "the composition reached the shell: {}",
                describe_terminal_calls(world)
            );
            Ok(())
        },
    );
    steps.step("the user cancels the composition", |world, _, _| {
        world.preedit("")?;
        world.sync()
    });
    steps.step("nothing is drawn in its place", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        world.wait_for("the composition to go", move |w| {
            !beside_the_cursor(w, &brick, terminal)
        })
    });
    steps.step(
        &format!("the shell receives {Q} once the composition is committed"),
        |world, c, _| {
            let wanted = c[0].clone();
            let shown = c[0].clone();
            world.wait_for_with(
                move |w| writes(w) == wanted,
                move |w| {
                    format!(
                        "\"{shown}\" once; the MC got {}",
                        describe_terminal_calls(w)
                    )
                },
            )
        },
    );
    steps.step(
        "the keys pressed during the composition are not sent separately",
        |world, _, _| {
            expect!(
                terminal_writes(world, "term-1").len() == 1,
                "the MC got {}",
                describe_terminal_calls(world)
            );
            Ok(())
        },
    );

    // AltGr.
    steps.step(
        &format!("the user's keyboard layout types {Q} with AltGr"),
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            take_keyboard(world, brick, terminal)
        },
    );
    steps.step(
        &format!("the user types {Q} with AltGr in the terminal"),
        |world, c, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            take_keyboard(world, brick, terminal)?;
            let at = c[0].chars().next().map_or(0, |ch| ch as i32);
            // As Windows reports it, Ctrl+Alt; X11's Mode_switch reaches Ljós
            // as the character alone, with no modifier for it.
            for modifiers in [Modifiers::CONTROL | Modifiers::ALT, Modifiers::empty()] {
                let press = KeyEvent::press(at)
                    .with_modifiers(modifiers)
                    .with_text(&*c[0]);
                world.key(&press)?;
            }
            world.sync()
        },
    );
    steps.step(&format!("the shell receives {Q}"), |world, c, _| {
        let wanted = vec![c[0].clone(), c[0].clone()];
        let shown = c[0].clone();
        world.wait_for_with(
            move |w| terminal_writes(w, "term-1") == wanted,
            move |w| {
                format!(
                    "\"{shown}\" for each way of typing it; the MC got {}",
                    describe_terminal_calls(w)
                )
            },
        )
    });
}
