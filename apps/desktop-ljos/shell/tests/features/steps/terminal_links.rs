//! What the pointer and the output do around a link in a terminal
//! (features/terminal/links-and-graphics.feature): desktop-qt's
//! TerminalMenuSteps.cpp, "What pointer and output do around a link".
//! TerminalSplits underlines the link Ctrl (Cmd on macOS) holds the pointer
//! over and follows the one a Ctrl-click pressed and released on.

use ljos::ObjectId;
use ljos::item::{Modifiers, MouseButtons, PointerEvent};

use crate::brick::Brick;
use crate::expect;
use crate::harness::{Outcome, Steps};
use crate::steps::terminal::{describe_terminal_calls, print, shown_thread, terminal_writes};
use crate::steps::terminal_close::visible_items;
use crate::steps::terminal_menu::{call, drawn_terminal, number, open_menu_at, point_on};
use crate::world::World;

const ADDRESS: &str = "http://localhost:5173";

#[derive(Default)]
struct LinkWorld {
    /// The address the shell printed.
    address: String,
    /// Where the user pressed and has not yet released.
    pressed: (f64, f64),
    /// What a double click and then a third selected.
    word: String,
    line: String,
}

fn address(world: &mut World) -> String {
    world.mc.part::<LinkWorld>().address.clone()
}

/// The window's point of the middle of a cell of the screen.
fn cell(
    world: &World,
    brick: &Brick,
    terminal: ObjectId,
    row: i64,
    column: i64,
) -> Outcome<(f64, f64)> {
    let padding = number(brick, world, terminal, "padding");
    let width = number(brick, world, terminal, "cellWidth");
    let height = number(brick, world, terminal, "cellHeight");
    let (ox, oy) = brick.at(world, terminal, 0.0, 0.0)?;
    Ok((
        ox.trunc() + (padding + width * (column as f64 + 0.5)).trunc(),
        oy.trunc() + (padding + height * (row as f64 + 0.5)).trunc(),
    ))
}

/// The screen row `address` starts on. The text joins soft wraps, so a line
/// takes a row per terminal width (terminalLinks.js).
fn row_of(world: &World, brick: &Brick, terminal: ObjectId, address: &str) -> Outcome<i64> {
    let columns = number(brick, world, terminal, "columns").max(1.0) as usize;
    let mut row = 0usize;
    let mut found = None;
    for line in call(world, terminal, "text").split('\n') {
        if line.contains(address) {
            found = Some(row);
        }
        row += line.chars().count().div_ceil(columns).max(1);
    }
    let Some(found) = found else {
        crate::fail!("the terminal draws \"{address}\"");
    };
    let top = number(brick, world, terminal, "scrollOffset").round() as i64;
    Ok(found as i64 - top)
}

/// The pointer moves to (x, y) with `modifiers` held and no button down.
fn hover(world: &mut World, (x, y): (f64, f64), modifiers: Modifiers) -> Outcome {
    world.pointer(|now| {
        let mut event = PointerEvent::moved(x, y, MouseButtons::empty(), now);
        event.modifiers = modifiers;
        event
    })?;
    world.sync()
}

fn press(world: &mut World, (x, y): (f64, f64), modifiers: Modifiers) -> Outcome {
    world.pointer(|now| {
        let mut event = PointerEvent::press(x, y, now);
        event.modifiers = modifiers;
        event
    })?;
    Ok(())
}

fn release(world: &mut World, (x, y): (f64, f64), modifiers: Modifiers) -> Outcome {
    world.pointer(|now| {
        let mut event = PointerEvent::release(x, y, now);
        event.modifiers = modifiers;
        event
    })?;
    world.sync()
}

/// The shell prints `printed`, which holds `address`; the drawn terminal.
fn print_address(world: &mut World, printed: &str, address: &str) -> Outcome<(Brick, ObjectId)> {
    let (brick, terminal) = drawn_terminal(world)?;
    world.mc.part::<LinkWorld>().address = address.to_owned();
    let thread = shown_thread(world);
    print(&mut world.mc, &thread, "term-1", &format!("{printed}\r\n"));
    let wanted = address.to_owned();
    world.wait_for("the terminal to draw the address", move |w| {
        call(w, terminal, "text").contains(&wanted)
    })?;
    Ok((brick, terminal))
}

fn print_server(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    print_address(
        world,
        &format!("Server ready at {ADDRESS} (press h for help)"),
        ADDRESS,
    )
}

/// An address too long for one row, on the screen's own rows.
fn print_wrapping(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    let (brick, terminal) = drawn_terminal(world)?;
    let columns = number(&brick, world, terminal, "columns") as usize;
    let mut address = "http://localhost:5173/".to_owned();
    let fill = (columns + 10).saturating_sub(address.len());
    address.push_str(&"a".repeat(fill));
    print_address(world, &address, &address.clone())
}

fn underlines(world: &World, brick: &Brick) -> Vec<ObjectId> {
    visible_items(world, brick, "terminalLinkUnderline").unwrap_or_default()
}

/// Whether the pointer shows a hand. Ljós's TestWindow does not say what
/// cursor the scene shows (`Scene::cursor_shape` is not reachable from it):
/// the hand is TerminalSplits' HoverHandler's, which shows it exactly while
/// the terminal has a hovered link.
fn pointer_is_hand(world: &World, brick: &Brick, terminal: ObjectId) -> bool {
    !matches!(
        brick.read(world, terminal, "hoveredLink"),
        ljos::prelude::Value::Null | ljos::prelude::Value::Undefined
    )
}

fn mouse_sent(world: &World) -> String {
    terminal_writes(world, "term-1").concat()
}

fn opened(world: &World) -> String {
    format!("{:?}", world.opened_urls())
}

fn register_hover(steps: &mut Steps) {
    steps.step(
        "the shell prints a web address that wraps across two lines",
        |world, _, _| print_wrapping(world).map(drop),
    );
    steps.step(
        "the user holds Ctrl \\(Cmd on macOS\\) and moves the pointer over one piece of it",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let address = address(world);
            let row = row_of(world, &brick, terminal, &address)?;
            let at = cell(world, &brick, terminal, row + 1, 2)?;
            hover(world, at, Modifiers::CONTROL)
        },
    );
    steps.step("every piece of the address is underlined", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        world.wait_for_with(
            move |w| underlines(w, &brick).len() == 2,
            move |w| format!("two underlines; there are {}", underlines(w, &brick).len()),
        )?;
        let width: f64 = underlines(world, &brick)
            .into_iter()
            .map(|piece| number(&brick, world, piece, "width"))
            .sum();
        let address = address(world);
        let wanted = address.chars().count() as f64 * number(&brick, world, terminal, "cellWidth");
        expect!(
            (width - wanted).abs() < 1.0,
            "the underlines are {width} wide, the address {wanted}"
        );
        Ok(())
    });
    steps.step(
        "the pointer shows that it can be followed",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            world.wait_for("the pointer to become a hand", move |w| {
                pointer_is_hand(w, &brick, terminal)
            })
        },
    );
    steps.step("the pointer moves off the address", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        let address = address(world);
        let row = row_of(world, &brick, terminal, &address)?;
        let at = cell(world, &brick, terminal, row + 3, 2)?;
        hover(world, at, Modifiers::CONTROL)
    });
    steps.step(
        "the underline and the pointer go back to normal",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            world.wait_for("the underline and the hand to go", move |w| {
                underlines(w, &brick).is_empty() && !pointer_is_hand(w, &brick, terminal)
            })
        },
    );
}

fn register_program_mouse(steps: &mut Steps) {
    steps.step("the shell prints a web address", |world, _, _| {
        print_server(world).map(drop)
    });
    steps.step(
        "the user moves the pointer over a web address in the output",
        |world, _, _| {
            let (brick, terminal) = print_server(world)?;
            let at = point_on(world, &brick, terminal, ADDRESS)?;
            hover(world, at, Modifiers::empty())
        },
    );
    steps.step("the address is not underlined", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        world.sync()?;
        expect!(
            underlines(world, &brick).is_empty() && !pointer_is_hand(world, &brick, terminal),
            "the address is offered"
        );
        Ok(())
    });
    steps.step("pressing on it goes to the program", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        let address = address(world);
        let (x, y) = point_on(world, &brick, terminal, &address)?;
        world.click_at_with(x, y, MouseButtons::LEFT, Modifiers::empty())?;
        world.wait_for_with(
            |w| mouse_sent(w).contains("\x1b[<0;"),
            |w| {
                format!(
                    "the program to get the press; the MC got {}",
                    describe_terminal_calls(w)
                )
            },
        )?;
        expect!(world.opened_urls().is_empty(), "the address was followed");
        Ok(())
    });
    steps.step("the terminal's menu on it offers no link", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        let address = address(world);
        let (x, y) = point_on(world, &brick, terminal, &address)?;
        open_menu_at(world, brick, x, y)?;
        let offered = |name: &str| -> Outcome<bool> {
            let item = brick.item(world, name)?;
            Ok(brick.flag(world, item, "visible") && number(&brick, world, item, "height") > 0.0)
        };
        expect!(
            !offered("terminalOpenLink")? && !offered("terminalCopyLink")?,
            "the menu offers the link"
        );
        Ok(())
    });
    steps.step(
        "the user holds Ctrl and moves the pointer over the address",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let address = address(world);
            let (x, y) = point_on(world, &brick, terminal, &address)?;
            // From elsewhere, as the user comes to it.
            hover(world, (x, y + 100.0), Modifiers::CONTROL)?;
            hover(world, (x, y), Modifiers::CONTROL)
        },
    );
    steps.step("the address is underlined", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        world.wait_for_with(
            move |w| underlines(w, &brick).len() == 1 && pointer_is_hand(w, &brick, terminal),
            move |w| {
                format!(
                    "an underline and a hand; there are {} underlines",
                    underlines(w, &brick).len()
                )
            },
        )
    });
    steps.step(
        "the user holds Ctrl and clicks the address",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let address = address(world);
            let (x, y) = point_on(world, &brick, terminal, &address)?;
            world.click_at_with(x, y, MouseButtons::LEFT, Modifiers::CONTROL)?;
            world.sync()
        },
    );
    steps.step("the program receives no click", |world, _, _| {
        world.sync()?;
        expect!(
            !mouse_sent(world).contains("\x1b[<"),
            "the MC got {}",
            describe_terminal_calls(world)
        );
        Ok(())
    });
}

fn register_clicks(steps: &mut Steps) {
    steps.step(
        "the user double-clicks and then triple-clicks on the address",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let address = address(world);
            let (x, y) = point_on(world, &brick, terminal, &address)?;
            // The clicks come at the same moment of the window's clock,
            // however long a busy machine takes between them.
            world.click_at(x, y)?;
            world.click_at(x, y)?;
            let word = call(world, terminal, "selectedText");
            world.click_at(x, y)?;
            let line = call(world, terminal, "selectedText");
            let links = world.mc.part::<LinkWorld>();
            links.word = word;
            links.line = line;
            world.sync()
        },
    );
    steps.step(
        "the word is selected and then the whole line",
        |world, _, _| {
            let links = world.mc.part::<LinkWorld>();
            let (word, line, address) = (
                links.word.clone(),
                links.line.clone(),
                links.address.clone(),
            );
            expect!(
                !word.is_empty() && address.contains(&word),
                "a double click selected \"{word}\""
            );
            expect!(
                line.trim() == format!("Server ready at {address} (press h for help)"),
                "a third click selected \"{line}\""
            );
            Ok(())
        },
    );
    steps.step(
        "the user holds Ctrl, presses on the address and releases a few pixels away",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let address = address(world);
            let (x, y) = point_on(world, &brick, terminal, &address)?;
            press(world, (x, y), Modifiers::CONTROL)?;
            release(world, (x + 3.0, y + 1.0), Modifiers::CONTROL)
        },
    );
    steps.step("the address is followed", |world, _, _| {
        let address = address(world);
        world.wait_for_with(
            move |w| w.opened_urls() == [address.clone()],
            |w| format!("the browser to open the address; it opened {}", opened(w)),
        )
    });
    steps.step(
        "the user presses on the address and drags well away before releasing",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let address = address(world);
            let (x, y) = point_on(world, &brick, terminal, &address)?;
            let row = number(&brick, world, terminal, "cellHeight").trunc();
            press(world, (x, y), Modifiers::empty())?;
            for down in [row, row * 3.0] {
                world.pointer(|now| PointerEvent::moved(x, y + down, MouseButtons::LEFT, now))?;
            }
            release(world, (x, y + row * 3.0), Modifiers::empty())
        },
    );
    steps.step(
        "the text between the press and the release is selected",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            world.wait_for("a selection", move |w| {
                brick.flag(w, terminal, "hasSelection")
            })?;
            let selected = call(world, terminal, "selectedText");
            // From the press, inside the address, on past its end; the rows
            // below are blank.
            let from_the_press = !selected.starts_with("Server") && !selected.starts_with("http");
            expect!(
                from_the_press && selected.contains("(press h for help)"),
                "selected \"{selected}\""
            );
            Ok(())
        },
    );
    steps.step("the address is not followed", |world, _, _| {
        world.sync()?;
        expect!(
            world.opened_urls().is_empty(),
            "the browser opened {}",
            opened(world)
        );
        Ok(())
    });
    steps.step("the user pressed on a link", |world, _, _| {
        let (brick, terminal) = print_server(world)?;
        let at = point_on(world, &brick, terminal, ADDRESS)?;
        world.mc.part::<LinkWorld>().pressed = at;
        press(world, at, Modifiers::CONTROL)
    });
    steps.step(
        "the output changes so that another address is under the pointer before release",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let address = address(world);
            let row = row_of(world, &brick, terminal, &address)?;
            let other = "http://localhost:9999/other";
            let thread = shown_thread(world);
            print(
                &mut world.mc,
                &thread,
                "term-1",
                &format!("\x1b[{};1HServer ready at {other}\x1b[K", row + 1),
            );
            world.wait_for("the terminal to draw the other address", move |w| {
                call(w, terminal, "text").contains(other)
            })?;
            let at = world.mc.part::<LinkWorld>().pressed;
            release(world, at, Modifiers::CONTROL)
        },
    );
    steps.step("nothing is followed", |world, _, _| {
        world.sync()?;
        expect!(
            world.opened_urls().is_empty(),
            "the browser opened {}",
            opened(world)
        );
        Ok(())
    });
}

fn register_cut_off(steps: &mut Steps) {
    steps.step(
        "a web address wraps so that its start has scrolled above the top of the screen",
        |world, _, _| {
            let (brick, terminal) = print_wrapping(world)?;
            let address = address(world);
            let row = row_of(world, &brick, terminal, &address)?;
            // While all of it shows, it is a link.
            let at = cell(world, &brick, terminal, row + 1, 2)?;
            hover(world, at, Modifiers::CONTROL)?;
            world.wait_for("the whole address to be a link", move |w| {
                underlines(w, &brick).len() == 2
            })?;
            let columns = number(&brick, world, terminal, "columns") as i64;
            let corner = cell(world, &brick, terminal, 0, columns - 1)?;
            hover(world, corner, Modifiers::CONTROL)?;
            // The cursor is on the row after it: a screen's worth of new
            // lines, less that row and the one left showing, leave only its
            // second row on screen.
            let top = number(&brick, world, terminal, "scrollOffset").round() as i64;
            let screen = number(&brick, world, terminal, "rows") as usize;
            let thread = shown_thread(world);
            print(
                &mut world.mc,
                &thread,
                "term-1",
                &"\r\n".repeat(screen.saturating_sub(2)),
            );
            world.wait_for_with(
                move |w| {
                    number(&brick, w, terminal, "scrollOffset").round() as i64 == top + row + 1
                },
                move |w| {
                    format!(
                        "its second row on top; the screen starts at {}, from {top} and row {row}",
                        number(&brick, w, terminal, "scrollOffset")
                    )
                },
            )
        },
    );
    steps.step("the part still on screen is not a link", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        let at = cell(world, &brick, terminal, 0, 2)?;
        hover(world, at, Modifiers::CONTROL)?;
        expect!(
            underlines(world, &brick).is_empty() && !pointer_is_hand(world, &brick, terminal),
            "the half-seen address is offered"
        );
        Ok(())
    });
    steps.step(
        "nothing is opened for a half-seen address",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let (x, y) = cell(world, &brick, terminal, 0, 2)?;
            world.click_at_with(x, y, MouseButtons::LEFT, Modifiers::CONTROL)?;
            world.sync()?;
            expect!(world.opened_urls().is_empty(), "the browser was opened");
            Ok(())
        },
    );
}

fn register_menu(steps: &mut Steps) {
    steps.step(
        "the user chooses to open a link in the system browser from the terminal's menu",
        |world, _, _| {
            let (brick, terminal) = print_server(world)?;
            let (x, y) = point_on(world, &brick, terminal, ADDRESS)?;
            open_menu_at(world, brick, x, y)?;
            world.wait_for("the terminal's menu to offer the link", move |w| {
                brick
                    .find(w, "terminalOpenLink")
                    .ok()
                    .flatten()
                    .is_some_and(|item| brick.flag(w, item, "visible"))
            })?;
            brick.click(world, "terminalOpenLink")?;
            world.sync()
        },
    );
}

pub fn register(steps: &mut Steps) {
    register_menu(steps);
    register_hover(steps);
    register_program_mouse(steps);
    register_clicks(steps);
    register_cut_off(steps);
}
