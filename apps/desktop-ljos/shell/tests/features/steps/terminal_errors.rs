//! What a terminal says when something it was asked to do fails
//! (features/terminal/errors.feature): desktop-qt's TerminalMenuSteps.cpp,
//! "What a terminal says when something it was asked to do fails".

use ljos::item::Modifiers;

use crate::harness::{Q, Steps};
use crate::steps::terminal::{
    FakeTerminals, describe_terminal_calls, drawer_open, print, shown_thread, terminal_session,
    terminal_writes,
};
use crate::steps::terminal_menu::{
    call, chord, drawn_terminal, follow, open_menu_at, point_on, select_first_line, take_keyboard,
};
use crate::world::World;
use crate::{expect, fail};

/// What the user's keys sent when the write fails, by what they were doing.
fn keys_of(action: &str) -> &'static str {
    if action.starts_with("sending") {
        "ls\r"
    } else if action.starts_with("moving") {
        "\x01"
    } else if action.starts_with("deleting") {
        "\x15"
    } else {
        "\x0c"
    }
}

fn write(world: &mut World, data: &str) -> crate::harness::Outcome {
    terminal_session(world, "term-1")?.write(world.engine(), data);
    world.sync()
}

fn shown(world: &World) -> String {
    match drawn(world) {
        Some(terminal) => call(world, terminal, "text"),
        None => String::new(),
    }
}

fn drawn(world: &World) -> Option<ljos::ObjectId> {
    let brick = world.peek_part::<crate::brick::Shown>()?.0?;
    brick.item(world, "HalC2Terminal").ok()
}

pub fn register(steps: &mut Steps) {
    steps.step("the terminal shows a running shell", |world, _, _| {
        drawn_terminal(world).map(|_| ())
    });
    steps.step(
        &format!(
            "(sending what the user typed|moving the cursor by word or line|deleting to the start of the line|clearing from the keyboard) fails with {Q}"
        ),
        |world, c, _| {
            world.mc.part::<FakeTerminals>().refuse_write = Some(c[1].clone());
            write(world, keys_of(&c[0]))
        },
    );
    steps.step(
        &format!("opening a file path from the output fails with {Q}"),
        |world, _, _| {
            // An environment with no editor to open it in.
            follow(
                world,
                "src/app.ts:12:4",
                "src/app.ts:12:4",
                Modifiers::CONTROL,
            )
        },
    );
    steps.step(
        &format!("copying the selection fails with {Q}"),
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            select_first_line(world, brick, terminal)?;
            world.set_clipboard_fails(true);
            take_keyboard(world, brick, terminal)?;
            let event = chord(world, "Ctrl+C")?;
            world.key(&event)?;
            world.sync()?;
            expect!(
                brick.flag(world, terminal, "hasSelection"),
                "a failed copy cleared the selection"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("copying a link from the terminal's menu fails with {Q}"),
        |world, _, _| {
            let address = "http://localhost:5173";
            let (brick, terminal) = drawn_terminal(world)?;
            let thread_id = shown_thread(world);
            print(
                &mut world.mc,
                &thread_id,
                "term-1",
                &format!("Server ready at {address}\r\n"),
            );
            world.wait_for("the terminal to draw the address", move |w| {
                call(w, terminal, "text").contains(address)
            })?;
            let (x, y) = point_on(world, &brick, terminal, address)?;
            open_menu_at(world, brick, x, y)?;
            let copy = brick.item(world, "terminalCopyLink")?;
            world.wait_for("the menu to offer the link", move |w| {
                brick.flag(w, copy, "visible")
            })?;
            world.set_clipboard_fails(true);
            brick.click(world, "terminalCopyLink")?;
            world.sync()
        },
    );
    steps.step(
        "the user types again while the MC is still unreachable",
        |world, _, _| {
            write(world, "l")?;
            write(world, "s\r")
        },
    );
    steps.step(
        "the MC drops the connection and the terminal attaches again",
        |world, _, _| {
            let (_, terminal) = drawn_terminal(world)?;
            world
                .client()
                .set_retry_delays(vec![std::time::Duration::from_millis(10)]);
            world.mc.drop_connection();
            world.wait_for("the shell to see the drop", |w| !w.client_ready())?;
            // Attaching again starts with the MC's snapshot, which holds only
            // the shell's output.
            world.wait_for_with(
                move |w| w.client_ready() && !call(w, terminal, "text").contains("[terminal]"),
                move |w| {
                    format!(
                        "the terminal to attach again; it shows \"{}\"",
                        call(w, terminal, "text")
                    )
                },
            )
        },
    );
    steps.step(&format!("the terminal shows {Q} once"), |world, c, _| {
        drawn_terminal(world)?;
        let wanted = c[0].clone();
        world.wait_for_with(move |w| shown(w).contains(&wanted), {
            let wanted = c[0].clone();
            move |w| {
                format!(
                    "the terminal to say \"{wanted}\"; it shows \"{}\"",
                    shown(w)
                )
            }
        })?;
        let times = shown(world).matches(c[0].as_str()).count();
        expect!(times == 1, "it says \"{}\" {times} times", c[0]);
        Ok(())
    });
    steps.step(&format!("the terminal shows {Q}"), |world, c, _| {
        drawn_terminal(world)?;
        let wanted = c[0].clone();
        world.wait_for_with(move |w| shown(w).contains(&wanted), {
            let wanted = c[0].clone();
            move |w| {
                format!(
                    "the terminal to say \"{wanted}\"; it shows \"{}\"",
                    shown(w)
                )
            }
        })
    });
    steps.step("the terminal keeps working", |world, _, _| {
        world.mc.part::<FakeTerminals>().refuse_write = None;
        world.set_clipboard_fails(false);
        write(world, "pwd\r")?;
        world.wait_for_with(
            |w| terminal_writes(w, "term-1").concat().contains("pwd"),
            |w| format!("the write; the MC got {}", describe_terminal_calls(w)),
        )?;
        if !drawer_open(world) {
            fail!("the drawer closed");
        }
        terminal_session(world, "term-1").map(|_| ())
    });
}
