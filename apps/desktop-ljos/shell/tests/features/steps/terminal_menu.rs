//! What the user does inside a terminal the desktop draws: its right-click
//! menu (TerminalMenu), clearing from the keyboard, its colours and font,
//! and the keys a program asks for (features/terminal/composer-context.feature,
//! io.feature, links-and-graphics.feature): desktop-qt's
//! TerminalMenuSteps.cpp. Driven on the bricks themselves, with the mouse
//! and keys the user has.

use hal_c2_shell::controller;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::theme::Themes;
use ljos::ObjectId;
use ljos::item::{Modifiers, MouseButtons, PointerEvent};
use serde_json::{Value, json};

use crate::brick::{self, Brick, Shown, key_event};
use crate::harness::{Outcome, Q, Steps, text};
use crate::steps::settings::fake_config;
use crate::steps::terminal::{
    FakeTerminals, describe_rows, describe_terminal_calls, drawer_available, drawer_open,
    ensure_project, ensure_thread, print, shown_thread, terminal_attach, terminal_writes,
};
use crate::world::World;
use crate::{expect, fail};

const OUTPUT: &str = "FAIL cart.test.ts\r\n  expected 3, got 2\r\n";
const CLIPBOARD: &str = "bun test cart";

#[derive(Default)]
struct MenuWorld {
    selected: String,
}

/// The brick world's shown, when a step showed one.
fn current(world: &mut World) -> Option<Brick> {
    world.peek_part::<Shown>().and_then(|shown| shown.0)
}

fn call(world: &World, terminal: ObjectId, method: &str) -> String {
    match world.engine().invoke_by_name(terminal, method, &[]) {
        Ok(value) => world.engine().to_js_string(&value).to_string(),
        Err(_) => String::new(),
    }
}

fn number(brick: &Brick, world: &World, item: ObjectId, name: &str) -> f64 {
    brick.text_of(world, item, name).parse().unwrap_or_default()
}

/// The thread's drawer, open on a terminal that printed [`OUTPUT`], drawn.
fn drawn_terminal(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    let brick = match current(world) {
        Some(brick) => brick,
        None => {
            ensure_project(world)?;
            ensure_thread(world)?;
            world.wait_for("the thread's terminal drawer", drawer_available)?;
            let thread_id = shown_thread(world);
            if !drawer_open(world) {
                world.dispatch("terminal.toggle", json!({}))?;
            }
            let id = thread_id.clone();
            world.wait_for_with(
                move |w| terminal_attach(w, &id, "term-1").is_some(),
                describe_rows,
            )?;
            world.sync()?;
            print(&mut world.mc, &thread_id, "term-1", OUTPUT);
            // The palette's own colours ride along for the theme steps.
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Bricks\nimport HalC2.Shell\n\
                 Item { width: 900; height: 600; objectName: \"terminalBrick\"\n\
                 property color paletteCanvas: Theme.palette.color(\"canvas\", \"transparent\")\n\
                 property color paletteText: Theme.palette.color(\"text\", \"transparent\")\n\
                 property color paletteSelection: Qt.alpha(Theme.palette.color(\"accent\", \"transparent\"), 0.35)\n\
                 TerminalDrawer { objectName: \"drawer\"; anchors.left: parent.left; \
                 anchors.right: parent.right; anchors.bottom: parent.bottom } }\n",
                900.0,
                600.0,
            )?;
            brick::shown(world)?
        }
    };
    let terminal = brick.item(world, "HalC2Terminal")?;
    world.wait_for_with(
        move |w| call(w, terminal, "text").contains("expected 3, got 2"),
        move |w| {
            format!(
                "the terminal to draw its output; it draws \"{}\"",
                call(w, terminal, "text")
            )
        },
    )?;
    Ok((brick, terminal))
}

/// Drags the mouse over the terminal's first line, as the user selects it.
fn select_first_line(world: &mut World, brick: Brick, terminal: ObjectId) -> Outcome {
    let cell = number(&brick, world, terminal, "cellWidth");
    let row = number(&brick, world, terminal, "cellHeight");
    let padding = number(&brick, world, terminal, "padding");
    let (ox, oy) = brick.at(world, terminal, 0.0, 0.0)?;
    let from = (
        (ox + (padding + cell * 0.5).trunc()).trunc(),
        (oy + (padding + row * 0.5).trunc()).trunc(),
    );
    let to = ((ox + (padding + cell * 16.5).trunc()).trunc(), from.1);
    world.pointer(|now| PointerEvent::press(from.0, from.1, now))?;
    for step in 1..=4 {
        let x = from.0 + ((to.0 - from.0) * f64::from(step) / 4.0).trunc();
        world.pointer(|now| PointerEvent::moved(x, from.1, MouseButtons::LEFT, now))?;
    }
    world.pointer(|now| PointerEvent::release(to.0, to.1, now))?;
    world.wait_for("the terminal to have a selection", move |w| {
        brick.flag(w, terminal, "hasSelection")
    })?;
    let selected = call(world, terminal, "selectedText");
    expect!(
        selected.contains("FAIL cart.test.ts"),
        "the selection is \"{selected}\""
    );
    world.mc.part::<MenuWorld>().selected = selected;
    Ok(())
}

/// Right-clicks at (x, y); the terminal's menu's items then take clicks,
/// as they do once the menu has finished opening.
fn open_menu_at(world: &mut World, brick: Brick, x: f64, y: f64) -> Outcome {
    world.click_at_with(x, y, MouseButtons::RIGHT, Modifiers::empty())?;
    let ljos::prelude::Value::Object(menu) =
        brick.read(world, brick.item(world, "terminalPaste")?, "menu")
    else {
        fail!("the terminal has no menu");
    };
    world.wait_for("the terminal's menu to open", move |w| {
        brick.flag(w, menu, "opened")
    })
}

fn open_menu(world: &mut World, brick: Brick, terminal: ObjectId) -> Outcome {
    let (x, y) = brick.at(world, terminal, 0.5, 0.6)?;
    open_menu_at(world, brick, x.trunc(), y.trunc())
}

struct Offer {
    offered: bool,
    enabled: bool,
}

fn offer(world: &World, brick: &Brick, object_name: &str) -> Outcome<Offer> {
    let item = brick.item(world, object_name)?;
    Ok(Offer {
        offered: brick.flag(world, item, "visible") && number(brick, world, item, "height") > 0.0,
        enabled: brick.flag(world, item, "enabled"),
    })
}

/// A key the user presses in the terminal, which takes the keyboard first.
fn press_in_terminal(world: &mut World, brick: Brick, terminal: ObjectId, spelt: &str) -> Outcome {
    take_keyboard(world, brick, terminal)?;
    let event = key_event(spelt)?;
    world.key(&event)?;
    world.sync()
}

fn take_keyboard(world: &mut World, brick: Brick, terminal: ObjectId) -> Outcome {
    let _ = world
        .engine()
        .invoke_by_name(terminal, "forceActiveFocus", &[]);
    world.pump()?;
    world.wait_for("the terminal to take the keyboard", move |w| {
        brick.flag(w, terminal, "activeFocus")
    })
}

/// Where `link` is drawn, on the last line that shows it.
fn point_on(world: &World, brick: &Brick, terminal: ObjectId, link: &str) -> Outcome<(f64, f64)> {
    let shown = call(world, terminal, "text");
    let lines: Vec<&str> = shown.split('\n').collect();
    let Some(row) = lines.iter().rposition(|line| line.contains(link)) else {
        fail!("the terminal draws \"{link}\"");
    };
    let byte = lines[row].find(link).unwrap_or_default();
    let column = lines[row][..byte].chars().count() + link.chars().count() / 2;
    let cell = number(brick, world, terminal, "cellWidth");
    let height = number(brick, world, terminal, "cellHeight");
    let padding = number(brick, world, terminal, "padding");
    let (ox, oy) = brick.at(world, terminal, 0.0, 0.0)?;
    Ok((
        ox.trunc() + (padding + cell * (column as f64 + 0.5)).trunc(),
        oy.trunc() + (padding + height * (row as f64 + 0.5)).trunc(),
    ))
}

/// The shell prints a line with `link` in it; where the link is drawn.
fn show_link(world: &mut World, printed: &str, link: &str) -> Outcome<(f64, f64)> {
    let (brick, terminal) = drawn_terminal(world)?;
    let thread_id = shown_thread(world);
    print(
        &mut world.mc,
        &thread_id,
        "term-1",
        &format!("{printed}\r\n"),
    );
    let wanted = link.to_owned();
    let shown = printed.to_owned();
    world.wait_for_with(
        move |w| call(w, terminal, "text").contains(&wanted),
        move |_| format!("the terminal to draw \"{shown}\""),
    )?;
    point_on(world, &brick, terminal, link)
}

/// The shell prints a line with `link` in it and the user clicks the link.
fn follow(world: &mut World, printed: &str, link: &str, modifiers: Modifiers) -> Outcome {
    let (x, y) = show_link(world, printed, link)?;
    world.click_at_with(x, y, MouseButtons::LEFT, modifiers)?;
    world.sync()
}

/// A finger's tap at (x, y), as the window hands a touch screen's to the
/// scene's handlers: a press and release of a `PointerDevice.TouchScreen`'s
/// `PointerDevice.Finger`.
fn tap_with_finger(world: &mut World, x: f64, y: f64) -> Outcome {
    let finger = |mut event: PointerEvent| {
        event.source.device = 0x2;
        event.source.pointer = 0x2;
        event
    };
    world.pointer(|now| finger(PointerEvent::press(x, y, now)))?;
    world.pointer(|now| finger(PointerEvent::release(x, y, now)))?;
    world.sync()
}

fn editor_call(world: &World) -> Option<Value> {
    world
        .mc
        .calls
        .iter()
        .find(|rpc| rpc.method == "shell.openInEditor")
        .map(|rpc| rpc.payload.clone())
}

/// A colour as the brick prints it: lightness of its RGB part, 0 to 255.
fn lightness(colour: &str) -> i32 {
    let hex = colour.trim_start_matches('#');
    let rgb = &hex[hex.len().saturating_sub(6)..];
    let channel =
        |at: usize| i32::from_str_radix(rgb.get(at..at + 2).unwrap_or("00"), 16).unwrap_or(0);
    let (r, g, b) = (channel(0), channel(2), channel(4));
    (r.max(g).max(b) + r.min(g).min(b)) / 2
}

fn appearance(world: &World) -> String {
    controller::with::<Themes, _>(world.engine(), |t, _| t.appearance().to_owned())
        .unwrap_or_default()
}

pub fn register(steps: &mut Steps) {
    // A terminal with no draft beside it: a provider's sign-in terminal, as
    // Settings shows it.
    steps.step(
        "the terminal is shown somewhere without a message draft",
        |world, _, _| {
            world.connect()?;
            world.sync()?;
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Bricks\n\
                 Item { width: 700; height: 300; ProviderAuthTerminal { anchors.fill: parent; \
                 instanceId: \"codex\"; \
                 terminal: ({ output: \"FAIL cart.test.ts\\r\\n  expected 3, got 2\\r\\n\", offset: 40 }) } }\n",
                700.0,
                300.0,
            )
        },
    );
    steps.step("the user selects terminal output", |world, _, _| {
        let brick = brick::shown(world)?;
        let terminal = brick.item(world, "HalC2Terminal")?;
        world.wait_for("the terminal to draw its output", move |w| {
            call(w, terminal, "text").contains("expected 3, got 2")
        })?;
        select_first_line(world, brick, terminal)
    });
    steps.step(
        "the user is offered to copy it but not to add it to the chat",
        |world, _, _| {
            let brick = brick::shown(world)?;
            let terminal = brick.item(world, "HalC2Terminal")?;
            open_menu(world, brick, terminal)?;
            let copy = offer(world, &brick, "terminalCopy")?;
            let add = offer(world, &brick, "terminalAddToChat")?;
            expect!(
                copy.offered && copy.enabled,
                "Copy is offered {}, enabled {}",
                copy.offered,
                copy.enabled
            );
            expect!(!add.offered, "Add to chat is offered");
            world.set_clipboard("something else");
            brick.click(world, "terminalCopy")?;
            let selected = world.mc.part::<MenuWorld>().selected.clone();
            world.wait_for_with(
                move |w| w.clipboard() == selected,
                |w| {
                    format!(
                        "the selection on the clipboard; it holds \"{}\"",
                        w.clipboard()
                    )
                },
            )
        },
    );

    steps.step("nothing is selected in the terminal", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        expect!(
            !brick.flag(world, terminal, "hasSelection"),
            "the terminal has a selection"
        );
        Ok(())
    });
    steps.step("the user opens the terminal's menu", |world, _, _| {
        let (brick, terminal) = drawn_terminal(world)?;
        open_menu(world, brick, terminal)
    });
    steps.step(
        "adding to chat and copying are unavailable",
        |world, _, _| {
            let brick = brick::shown(world)?;
            let copy = offer(world, &brick, "terminalCopy")?;
            let add = offer(world, &brick, "terminalAddToChat")?;
            // Listed, since the thread has a draft, and greyed until
            // something is selected.
            expect!(
                add.offered && !add.enabled && copy.offered && !copy.enabled,
                "Add to chat is offered {}, enabled {}; Copy is offered {}, enabled {}",
                add.offered,
                add.enabled,
                copy.offered,
                copy.enabled
            );
            Ok(())
        },
    );
    steps.step("pasting is available", |world, _, _| {
        let brick = brick::shown(world)?;
        let paste = offer(world, &brick, "terminalPaste")?;
        expect!(
            paste.offered && paste.enabled,
            "Paste is offered {}, enabled {}",
            paste.offered,
            paste.enabled
        );
        Ok(())
    });

    steps.step("the terminal has a selection", |world, _, _| {
        world.set_clipboard(CLIPBOARD);
        let (brick, terminal) = drawn_terminal(world)?;
        select_first_line(world, brick, terminal)
    });
    steps.step(
        &format!("the user chooses {Q} from the terminal's menu"),
        |world, c, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            open_menu(world, brick, terminal)?;
            brick.click(
                world,
                if c[0] == "Copy" {
                    "terminalCopy"
                } else {
                    "terminalPaste"
                },
            )?;
            world.sync()
        },
    );
    steps.step("the selected text is on the clipboard", |world, _, _| {
        let selected = world.mc.part::<MenuWorld>().selected.clone();
        let wanted = selected.clone();
        world.wait_for_with(
            move |w| w.clipboard() == wanted,
            move |w| {
                format!(
                    "\"{selected}\" on the clipboard; it holds \"{}\"",
                    w.clipboard()
                )
            },
        )?;
        expect!(
            terminal_writes(world, "term-1").is_empty(),
            "the MC got {}",
            describe_terminal_calls(world)
        );
        Ok(())
    });
    steps.step("the clipboard text is sent to the shell", |world, _, _| {
        world.wait_for_with(
            |w| terminal_writes(w, "term-1").join("").contains(CLIPBOARD),
            |w| {
                format!(
                    "\"{CLIPBOARD}\" to be written; the MC got {}",
                    describe_terminal_calls(w)
                )
            },
        )
    });

    steps.step(
        &format!("the user presses {Q} in the terminal"),
        |world, c, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let spelt = if c[0] == "Ctrl+C" { "ctrl+c" } else { "ctrl+v" };
            press_in_terminal(world, brick, terminal, spelt)
        },
    );
    steps.step("the shell receives Ctrl-C", |world, _, _| {
        world.wait_for_with(
            |w| terminal_writes(w, "term-1").contains(&"\x03".to_owned()),
            |w| {
                format!(
                    "Ctrl-C to be written; the MC got {}",
                    describe_terminal_calls(w)
                )
            },
        )
    });

    steps.step(
        "the user clears the terminal from the keyboard",
        |world, _, _| {
            // A shell answers Ctrl-L by clearing the screen and drawing its
            // prompt.
            world
                .mc
                .part::<FakeTerminals>()
                .replies
                .insert("\x0c".into(), "\x1b[H\x1b[2J$ ".into());
            let (brick, terminal) = drawn_terminal(world)?;
            // The terminal item encodes Control as Ctrl on every platform.
            press_in_terminal(world, brick, terminal, "ctrl+l")
        },
    );
    steps.step(
        "the shell receives Ctrl-L and redraws its prompt at the top",
        |world, _, _| {
            world.wait_for_with(
                |w| terminal_writes(w, "term-1").contains(&"\x0c".to_owned()),
                |w| {
                    format!(
                        "Ctrl-L to be written; the MC got {}",
                        describe_terminal_calls(w)
                    )
                },
            )?;
            let brick = brick::shown(world)?;
            let terminal = brick.item(world, "HalC2Terminal")?;
            // The prompt is the screen's first line, and the old output is
            // off it.
            world.wait_for_with(
                move |w| call(w, terminal, "text").trim() == "$",
                move |w| {
                    format!(
                        "only the prompt; the terminal draws \"{}\"",
                        call(w, terminal, "text")
                    )
                },
            )
        },
    );

    steps.step(
        "the user switches the app to a dark theme",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            world.dispatch("theme.mode", json!({"mode": "light"}))?;
            world.wait_for("the app to be drawn light", |w| appearance(w) == "light")?;
            world.mc.part::<MenuWorld>().selected =
                brick.text_of(world, terminal, "backgroundColor");
            let settings = Settings::of(world.engine());
            let written =
                settings.write_device(world.engine(), "fontFamilyTerminal", json!("Courier"))
                    && settings.write_device(world.engine(), "fontSizeTerminal", json!(15));
            expect!(written, "{}", settings.device_error());
            world.dispatch("theme.mode", json!({"mode": "dark"}))?;
            world.wait_for("the app to be drawn dark", |w| appearance(w) == "dark")
        },
    );
    steps.step(
        "the terminal's colours and selection follow the dark theme",
        |world, _, _| {
            let brick = brick::shown(world)?;
            let terminal = brick.item(world, "HalC2Terminal")?;
            let root = brick.item(world, "terminalBrick")?;
            let canvas = brick.text_of(world, root, "paletteCanvas");
            let ink = brick.text_of(world, root, "paletteText");
            let selection = brick.text_of(world, root, "paletteSelection");
            let drawn = {
                let (canvas, ink) = (canvas.clone(), ink.clone());
                move |w: &World| {
                    brick.text_of(w, terminal, "backgroundColor") == canvas
                        && brick.text_of(w, terminal, "foregroundColor") == ink
                        && brick.text_of(w, terminal, "cursorColor") == ink
                }
            };
            world.wait_for_with(drawn, {
                let (canvas, ink) = (canvas.clone(), ink.clone());
                move |w| {
                    format!(
                        "the terminal on {canvas} in {ink}; it is on {} in {}",
                        brick.text_of(w, terminal, "backgroundColor"),
                        brick.text_of(w, terminal, "foregroundColor")
                    )
                }
            })?;
            let chosen = brick.text_of(world, terminal, "selectionColor");
            expect!(
                chosen == selection,
                "the selection is {chosen}, the accent {selection}"
            );
            // It was light before: these are the dark theme's.
            let light = world.mc.part::<MenuWorld>().selected.clone();
            expect!(
                lightness(&canvas) < 128 && canvas != light,
                "the canvas is {canvas}"
            );
            Ok(())
        },
    );
    steps.step(
        "the terminal uses the app's terminal font",
        |world, _, _| {
            let brick = brick::shown(world)?;
            let terminal = brick.item(world, "HalC2Terminal")?;
            let font = move |w: &World| match brick.read(w, terminal, "font") {
                // Ljós reads a family as a CSS-like list, and the shell appends the
                // generic `monospace` to one this machine lacks (`fixed_width`):
                // the family asked for is the list's head.
                ljos::prelude::Value::Font(f) => (
                    f.family
                        .split(',')
                        .next()
                        .unwrap_or_default()
                        .trim()
                        .to_owned(),
                    f.pixel_size.to_string(),
                ),
                _ => (String::new(), String::new()),
            };
            world.wait_for_with(
                move |w| font(w) == ("Courier".to_owned(), "15".to_owned()),
                move |w| {
                    let (family, size) = font(w);
                    format!("the terminal in Courier at 15; it is in {family} at {size}")
                },
            )
        },
    );

    // Links in the output (TerminalSplits follows the one under a
    // Ctrl-click).
    steps.step(
        "the user's links open in the system browser",
        |world, _, _| {
            // The setting's default (BrowserLinkTarget "system").
            drawn_terminal(world)?;
            let settings = Settings::of(world.engine()).settings();
            let target = settings
                .get("browserLinkTarget")
                .map_or_else(|| "system".to_owned(), text);
            expect!(target == "system", "links open in {target}");
            Ok(())
        },
    );
    steps.step(
        &format!("the user follows {Q} in the terminal"),
        |world, c, _| {
            follow(
                world,
                &format!("Server ready at {} (press h for help)", c[0]),
                &c[0],
                Modifiers::CONTROL,
            )
        },
    );
    steps.step(
        &format!("the user clicks {Q} in the terminal without holding Ctrl"),
        |world, c, _| {
            follow(
                world,
                &format!("Server ready at {} (press h for help)", c[0]),
                &c[0],
                Modifiers::empty(),
            )
        },
    );
    steps.step(
        &format!("the user taps {Q} in the terminal on a touch screen"),
        |world, c, _| {
            let printed = format!("Server ready at {} (press h for help)", c[0]);
            let (x, y) = show_link(world, &printed, &c[0])?;
            tap_with_finger(world, x, y)
        },
    );
    steps.step("the address opens in the system browser", |world, _, _| {
        world.wait_for_with(
            |w| w.opened_urls() == ["http://localhost:5173"],
            |w| {
                format!(
                    "the browser to open the address; it opened {} addresses",
                    w.opened_urls().len()
                )
            },
        )?;
        // The click went to the link, not the shell, and selected nothing.
        let brick = brick::shown(world)?;
        let terminal = brick.item(world, "HalC2Terminal")?;
        expect!(
            terminal_writes(world, "term-1").is_empty()
                && !brick.flag(world, terminal, "hasSelection"),
            "the MC got {}",
            describe_terminal_calls(world)
        );
        Ok(())
    });
    steps.step(&format!("the shell prints {Q}"), |world, c, _| {
        // An environment with an editor, and a thread in /work/p1.
        fake_config(&mut world.mc)
            .config
            .insert("availableEditors".into(), json!(["zed"]));
        if world.shell_subscriptions() > 0 {
            let fake = fake_config(&mut world.mc);
            let mut config = fake.config.clone();
            config.insert("settings".into(), Value::Object(fake.settings.clone()));
            let mc = &world.mc;
            for id in mc.subscribers("config") {
                if text(&mc.shape_of(id)["environment"]) != mc.environment_id {
                    continue;
                }
                mc.send(&json!({"t": "config", "id": id, "mc": mc.name, "config": config}));
            }
            world.sync()?;
        }
        let (_, terminal) = drawn_terminal(world)?;
        let thread_id = shown_thread(world);
        print(
            &mut world.mc,
            &thread_id,
            "term-1",
            &format!("error TS2322 at {}.\r\n", c[0]),
        );
        let wanted = c[0].clone();
        world.wait_for_with(
            move |w| call(w, terminal, "text").contains(&wanted),
            |_| format!("the terminal to draw \"{}\"", c[0]),
        )
    });
    steps.step("the user follows that path", |world, _, _| {
        follow(world, "(1 error)", "src/app.ts:12:4", Modifiers::CONTROL)
    });
    steps.step(
        &format!("the user opens the terminal's menu on {Q}"),
        |world, c, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            let (x, y) = point_on(world, &brick, terminal, &c[0])?;
            open_menu_at(world, brick, x, y)
        },
    );
    steps.step(
        "\"src/app.ts\" opens in the user's editor at line 12, column 4",
        |world, _, _| {
            world.wait_for("the editor to be asked for the file", |w| {
                editor_call(w).is_some()
            })?;
            let asked = editor_call(world).unwrap_or_default();
            expect!(
                asked["editor"] == "zed" && text(&asked["cwd"]).ends_with("/src/app.ts:12:4"),
                "the editor was asked for {asked}"
            );
            expect!(world.opened_urls().is_empty(), "the browser was opened");
            Ok(())
        },
    );
    steps.step(
        "the path is resolved against the terminal's folder",
        |world, _, _| {
            let folder = terminal_attach(world, &shown_thread(world), "term-1")
                .map(|input| text(&input["cwd"]))
                .unwrap_or_default();
            let asked = editor_call(world).unwrap_or_default();
            expect!(
                !folder.is_empty() && asked["cwd"] == format!("{folder}/src/app.ts:12:4"),
                "the terminal runs in {folder}; the editor was asked for {}",
                text(&asked["cwd"])
            );
            Ok(())
        },
    );

    steps.step(
        "a program turns on the Kitty keyboard protocol",
        |world, _, _| {
            let (brick, terminal) = drawn_terminal(world)?;
            // CSI > 1 u: disambiguate escape codes.
            let thread_id = shown_thread(world);
            print(&mut world.mc, &thread_id, "term-1", "\x1b[>1u");
            world.sync()?;
            take_keyboard(world, brick, terminal)
        },
    );
    steps.step("the user presses a key with modifiers", |world, _, _| {
        // Shift+Enter: plain terminals cannot tell it from Enter.
        let event = key_event("shift+enter")?;
        world.key(&event)?;
        world.sync()
    });
    steps.step(
        "the program receives the enhanced key report",
        |world, _, _| {
            world.wait_for_with(
                |w| terminal_writes(w, "term-1").contains(&"\x1b[13;2u".to_owned()),
                |w| {
                    format!(
                        "CSI 13;2u to be written; the MC got {}",
                        describe_terminal_calls(w)
                    )
                },
            )
        },
    );
}
