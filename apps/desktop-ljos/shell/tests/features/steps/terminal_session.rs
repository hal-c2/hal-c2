//! Showing, hiding and sizing the thread's terminal, and where a new one
//! starts (features/terminal/sessions.feature's desktop scenarios):
//! desktop-qt's TerminalSessionSteps.cpp. The Terminals controller behind
//! the drawer, and the TerminalDrawer and Workspace bricks the user reaches
//! it through.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::controller;
use hal_c2_shell::controllers::keybindings::Keymap;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::terminals::{Session, Terminals, TerminalsObject};
use ljos::item::PointerEvent;
use serde_json::{Value, json};

use crate::brick::{self, Brick};
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::steps::terminal::{
    active_terminal, add_action, attached, describe_rows, describe_terminal_calls,
    drawer_available, drawer_open, ensure_project, ensure_thread, print, rows_in, show_thread,
    shown_thread, tab_labels, terminal_attach, terminal_call, terminal_session, terminal_writes,
};
use crate::world::World;
use crate::{expect, fail};

/// What the scenario's terminal did: who was handed the keyboard, the
/// session showing the build, and the launch a script's terminal was opened
/// with.
#[derive(Default)]
struct SessionWorld {
    focused: Rc<RefCell<Vec<String>>>,
    session: Option<Session>,
    attaches: usize,
    script_launch: Value,
    window_height: f64,
}

const WORKTREE: &str = "/work/p1-wt";
const BUILD: &str = "building cart… 42 modules";

fn terminals_of<R>(world: &World, f: impl FnOnce(&Terminals) -> R) -> Option<R> {
    controller::with::<Terminals, _>(world.engine(), |t, _| f(t))
}

fn drawer_height(world: &World) -> i32 {
    terminals_of(world, |t| t.height()).unwrap_or(0)
}

/// How tall the drawer item is.
fn height_of(brick: &Brick, world: &World, drawer: ljos::ObjectId) -> f64 {
    brick
        .text_of(world, drawer, "height")
        .parse()
        .unwrap_or_default()
}

fn attaches_of(world: &World, thread_id: &str, terminal_id: &str) -> usize {
    world
        .mc
        .subscriptions
        .iter()
        .filter(|sub| {
            let shape = &sub["shape"];
            let input = &shape["input"];
            shape["type"] == "terminal"
                && input["threadId"] == thread_id
                && input["terminalId"] == terminal_id
        })
        .count()
}

fn open_drawer(world: &mut World) -> Outcome {
    ensure_project(world)?;
    ensure_thread(world)?;
    world.wait_for("the thread's terminal drawer", drawer_available)?;
    if !drawer_open(world) {
        world.dispatch("terminal.toggle", json!({}))?;
    }
    world.wait_for_with(
        |w| drawer_open(w) && !rows_in(w, false).is_empty(),
        describe_rows,
    )
}

/// The drawer under a thread, in a window `height` tall. The brick's root
/// is given its size here: the probe does not size it as desktop-qt's does.
fn drawer_brick(world: &mut World, height: f64) -> Outcome<Brick> {
    Brick::show(
        world,
        &format!(
            "import QtQuick\nimport HalC2.Bricks\n\
         Item {{ width: 900; height: {height}; TerminalDrawer {{ objectName: \"drawer\"; anchors.left: parent.left; \
         anchors.right: parent.right; anchors.bottom: parent.bottom }} }}\n"
        ),
        900.0,
        height,
    )?;
    brick::shown(world)
}

/// What the drawer's Terminal item draws.
fn drawn(world: &World, brick: &Brick) -> Outcome<String> {
    let terminal = brick.item(world, "HalC2Terminal")?;
    Ok(match world.engine().invoke_by_name(terminal, "text", &[]) {
        Ok(value) => world.engine().to_js_string(&value).to_string(),
        Err(e) => fail!("the drawer's terminal has no text: {e:?}"),
    })
}

/// The user takes the drawer's top edge to where the drawer would be
/// `wanted` tall in a window `window` tall.
fn drag_drawer(world: &mut World, brick: &Brick, window: f64, wanted: f64) -> Outcome {
    let drawer = brick.item(world, "drawer")?;
    let (x, top) = brick.at(world, drawer, 0.5, 0.0)?;
    let from = top + 2.0;
    let to = window - wanted + 2.0;
    world.pointer(|now| PointerEvent::press(x, from, now))?;
    for step in 1..=8 {
        let y = from + (to - from) * f64::from(step) / 8.0;
        world.pointer(|now| {
            PointerEvent::moved(x, y.round(), ljos::item::MouseButtons::LEFT, now)
        })?;
    }
    world.pointer(|now| PointerEvent::release(x, to.round(), now))?;
    world.sync()
}

fn open_thread(world: &mut World, key: &str) -> Outcome {
    let route = key.to_owned();
    world.with::<Navigation, _>(move |n, engine| n.open(engine, Route::Thread(route)))
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "a thread whose environment can run terminals",
        |world, _, _| {
            ensure_project(world)?;
            ensure_thread(world)?;
            world.wait_for("the thread's terminal drawer", drawer_available)?;
            let focused = world.mc.part::<SessionWorld>().focused.clone();
            let object = world
                .engine()
                .singleton::<TerminalsObject>()
                .map_err(|e| Failure(format!("the terminals cannot be reached: {e:?}")))?;
            world
                .engine()
                .connect_by_name(object, "focusRequested", move |_, args| {
                    let id = args.first().map(|v| v.to_js_string().to_string());
                    focused.borrow_mut().push(id.unwrap_or_default());
                })
                .map_err(|e| Failure(format!("focusRequested cannot be watched: {e:?}")))?;
            Ok(())
        },
    );
    steps.step(
        "the thread's terminal is visible and has focus",
        |world, _, _| {
            let thread_id = shown_thread(world);
            let id = thread_id.clone();
            world.wait_for_with(
                move |w| {
                    drawer_open(w)
                        && rows_in(w, false).len() == 1
                        && terminal_attach(w, &id, "term-1").is_some()
                },
                describe_rows,
            )?;
            // The drawer brick draws it and hands it the keyboard, as the
            // controller asked.
            let brick = drawer_brick(world, 700.0)?;
            let drawer = brick.item(world, "drawer")?;
            let focused = world.mc.part::<SessionWorld>().focused.borrow().clone();
            expect!(
                focused == ["term-1"],
                "the keyboard was asked for {}",
                focused.join(", ")
            );
            world
                .engine()
                .invoke_by_name(drawer, "focusTerminal", &[])
                .map_err(|e| Failure(format!("focusTerminal: {e:?}")))?;
            world.pump()?;
            world.wait_for_with(
                move |w| {
                    brick.flag(w, drawer, "visible")
                        && height_of(&brick, w, drawer) >= 180.0
                        && brick.flag(w, drawer, "bodyFocused")
                },
                |w| {
                    format!(
                        "the drawer to show the terminal with the keyboard: {}",
                        describe_rows(w)
                    )
                },
            )
        },
    );
    steps.step("its shell keeps running", |world, _, _| {
        world.sync()?;
        let thread_id = shown_thread(world);
        if let Ok(brick) = brick::shown(world) {
            let drawer = brick.item(world, "drawer")?;
            let height = height_of(&brick, world, drawer);
            expect!(
                !brick.flag(world, drawer, "visible") && height == 0.0,
                "the drawer still shows, {height} tall"
            );
        }
        expect!(
            terminal_call(world, "terminal.close", &thread_id, "term-1").is_none()
                && attached(&world.mc).contains(&format!("{thread_id}/term-1")),
            "{}; the MC got {}",
            describe_rows(world),
            describe_terminal_calls(world)
        );
        Ok(())
    });

    steps.step(
        "the selected thread's environment cannot run terminals",
        |world, _, _| {
            // A thread whose project the environment does not have: nowhere
            // to start a shell.
            world.mc.threads.insert(
                "lost".into(),
                json!({
                    "id": "lost",
                    "title": "Lost",
                    "projectId": "gone",
                    "createdAt": "2026-09-23T09:00:00Z",
                    "updatedAt": "2026-09-23T09:00:00Z",
                }),
            );
            ensure_project(world)?;
            let key = format!("{}:lost", world.mc.environment_id);
            open_thread(world, &key)?;
            let wanted = key.clone();
            world.wait_for_with(
                move |w| at(&w.state("route"), "threadKey") == &json!(wanted),
                |w| format!("the route to be {key}; it is {}", show(&w.state("route"))),
            )?;
            world.sync()
        },
    );
    steps.step(
        "the user is not offered a way to show the terminal",
        |world, _, _| {
            expect!(!drawer_available(world), "the terminal drawer is available");
            // The header has no toggle, and the command and its chord do
            // nothing.
            let header = Brick::new(
                world,
                "import QtQuick\nimport HalC2.Bricks\nWorkspace { width: 1200; height: 52 }\n",
                1200.0,
                52.0,
            )?;
            let toggle = header.item(world, "terminalToggle")?;
            expect!(
                !header.flag(world, toggle, "visible"),
                "the header offers the terminal toggle"
            );
            world.dispatch("terminal.toggle", json!({}))?;
            world.sync()?;
            expect!(
                !drawer_open(world) && attached(&world.mc).is_empty(),
                "the toggle opened a terminal: {}",
                describe_rows(world)
            );
            Ok(())
        },
    );

    steps.step(
        "the terminal is showing in a window (\\d+) pixels tall",
        |world, c, _| {
            open_drawer(world)?;
            let height: f64 = c[0].parse().unwrap_or_default();
            world.mc.part::<SessionWorld>().window_height = height;
            let brick = drawer_brick(world, height)?;
            let drawer = brick.item(world, "drawer")?;
            world.wait_for_with(
                move |w| {
                    brick.flag(w, drawer, "visible")
                        && height_of(&brick, w, drawer) == f64::from(drawer_height(w))
                },
                move |w| {
                    format!(
                        "the drawer to show; it is {} tall",
                        height_of(&brick, w, drawer)
                    )
                },
            )
        },
    );
    steps.step(
        "the user drags the terminal to (\\d+) pixels tall",
        |world, c, _| {
            let brick = brick::shown(world)?;
            let window = world.mc.part::<SessionWorld>().window_height;
            drag_drawer(world, &brick, window, c[0].parse().unwrap_or_default())
        },
    );
    steps.step("the terminal is (\\d+) pixels tall", |world, c, _| {
        let brick = brick::shown(world)?;
        let drawer = brick.item(world, "drawer")?;
        let wanted: i32 = c[0].parse().unwrap_or_default();
        world.wait_for_with(
            move |w| height_of(&brick, w, drawer) as i32 == wanted && drawer_height(w) == wanted,
            move |w| {
                format!(
                    "the drawer to be {wanted} tall; it is {} and the shell keeps {}",
                    height_of(&brick, w, drawer),
                    drawer_height(w)
                )
            },
        )
    });

    steps.step(
        "the terminal shows the output of a running build",
        |world, _, _| {
            open_drawer(world)?;
            let thread_id = shown_thread(world);
            let id = thread_id.clone();
            world.wait_for_with(
                move |w| terminal_attach(w, &id, "term-1").is_some(),
                describe_rows,
            )?;
            world.sync()?;
            print(&mut world.mc, &thread_id, "term-1", BUILD);
            let session = terminal_session(world, "term-1")?;
            let watched = session.clone();
            world.wait_for_with(
                move |_| watched.transcript().contains(BUILD),
                |_| {
                    format!(
                        "the build output; the terminal shows \"{}\"",
                        session.transcript()
                    )
                },
            )?;
            let attaches = attaches_of(world, &thread_id, "term-1");
            let session = terminal_session(world, "term-1")?;
            let kept = world.mc.part::<SessionWorld>();
            kept.session = Some(session);
            kept.attaches = attaches;
            Ok(())
        },
    );
    steps.step(
        "the user hides the terminal and shows it again",
        |world, _, _| {
            world.dispatch("terminal.toggle", json!({}))?;
            world.wait_for("the terminal drawer to hide", |w| !drawer_open(w))?;
            world.sync()?;
            world.dispatch("terminal.toggle", json!({}))?;
            world.wait_for("the terminal drawer to show", drawer_open)?;
            world.sync()
        },
    );
    steps.step(
        "the same output is still on screen without a reload",
        |world, _, _| {
            let thread_id = shown_thread(world);
            let session = terminal_session(world, "term-1")?;
            let (kept, attaches) = {
                let kept = world.mc.part::<SessionWorld>();
                (kept.session.clone(), kept.attaches)
            };
            expect!(
                Some(&session) == kept.as_ref(),
                "the terminal was made again"
            );
            expect!(
                session.transcript().contains(BUILD),
                "the terminal shows \"{}\"",
                session.transcript()
            );
            let now = attaches_of(world, &thread_id, "term-1");
            expect!(
                now == attaches,
                "the terminal was attached {now} times, {attaches} before hiding"
            );
            // The drawer draws that screen: the Terminal item holds the
            // build's output.
            let brick = drawer_brick(world, 700.0)?;
            world.wait_for_with(
                move |w| drawn(w, &brick).is_ok_and(|t| t.contains(BUILD)),
                move |w| {
                    format!(
                        "the drawer to draw the build output; it draws \"{}\"",
                        drawn(w, &brick).unwrap_or_default()
                    )
                },
            )
        },
    );

    // The drawer's own chord and what it keeps across a restart
    // (terminal/drawer.feature).
    steps.step(&format!("the user bound {Q} to {Q}"), |world, c, _| {
        let keymap = Keymap::of(world.engine());
        keymap.save(world.engine(), &c[0], &c[1], "", None);
        let (command, key) = (c[0].clone(), c[1].clone());
        world.wait_for_with(
            {
                let (command, key) = (command.clone(), key.clone());
                move |w| {
                    let keymap = Keymap::of(w.engine());
                    !keymap.saving()
                        && keymap.shortcut_label(w.engine(), &command) == keymap.key_label(&key)
                }
            },
            move |w| {
                let keymap = Keymap::of(w.engine());
                format!(
                    "{command} on {}; it is on {}",
                    keymap.key_label(&key),
                    keymap.shortcut_label(w.engine(), &command)
                )
            },
        )
    });
    steps.step("the terminal drawer opens", |world, _, _| {
        let thread_id = shown_thread(world);
        world.wait_for_with(
            move |w| drawer_open(w) && terminal_attach(w, &thread_id, "term-1").is_some(),
            describe_rows,
        )
    });
    steps.step(
        &format!("the user dragged the drawer to (\\d+) pixels with {Q} active"),
        |world, c, _| {
            let thread_id = shown_thread(world);
            world.dispatch("terminal.toggle", json!({}))?;
            world.dispatch("terminal.new", json!({}))?;
            let wanted = c[1].clone();
            world.wait_for_with(
                move |w| {
                    terminal_attach(w, &thread_id, &wanted).is_some()
                        && active_terminal(w) == wanted
                },
                describe_rows,
            )?;
            let brick = drawer_brick(world, 900.0)?;
            let height: f64 = c[0].parse().unwrap_or_default();
            drag_drawer(world, &brick, 900.0, height)?;
            world.wait_for_with(
                move |w| f64::from(drawer_height(w)) == height,
                move |w| format!("the drawer to be {height} tall; it is {}", drawer_height(w)),
            )?;
            world.sync()
        },
    );
    steps.step("the desktop starts again", |world, _, _| {
        let key = world.with::<Navigation, _>(|n, _| n.thread_key().to_owned())?;
        world.restart()?;
        world.connect()?;
        world.wait_for_with(
            {
                let key = key.clone();
                move |w| {
                    w.with::<Navigation, _>(|n, _| n.thread_key() == key)
                        .unwrap_or(false)
                        && drawer_available(w)
                }
            },
            move |w| {
                format!(
                    "the window to show {key} again; it shows {}",
                    show(&w.state("route"))
                )
            },
        )
    });
    steps.step(
        &format!("the drawer is (\\d+) pixels tall with {Q} active"),
        |world, c, _| {
            let thread_id = shown_thread(world);
            let height: i32 = c[0].parse().unwrap_or_default();
            let active = c[1].clone();
            world.wait_for_with(
                {
                    let active = active.clone();
                    move |w| {
                        drawer_open(w) && drawer_height(w) == height && active_terminal(w) == active
                    }
                },
                {
                    let active = active.clone();
                    move |w| {
                        format!(
                            "the drawer open at {height} on {active}; it is {} at {} on {}; {}",
                            if drawer_open(w) { "open" } else { "closed" },
                            drawer_height(w),
                            active_terminal(w),
                            describe_rows(w)
                        )
                    }
                },
            )?;
            // Both terminals are the MC's own, attached again, and drawn at
            // that height.
            expect!(
                tab_labels(world) == "Terminal 1, Terminal 2"
                    && terminal_attach(world, &thread_id, &active).is_some(),
                "{}",
                describe_rows(world)
            );
            let brick = drawer_brick(world, 900.0)?;
            let drawer = brick.item(world, "drawer")?;
            world.wait_for_with(
                move |w| height_of(&brick, w, drawer) as i32 == height,
                move |w| format!("the drawer drawn {} tall", height_of(&brick, w, drawer)),
            )
        },
    );

    // Threads the user left keep their terminals attached
    // (terminal/tabs.feature).
    steps.step(
        "the user has visited ten threads with open terminals",
        |world, _, _| {
            ensure_project(world)?;
            let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
            for n in 1..=10 {
                let thread_id = format!("visited-{n}");
                let row = json!({
                    "id": thread_id,
                    "title": format!("Visit {n}"),
                    "projectId": project,
                    "createdAt": "2026-09-23T09:00:00Z",
                    "updatedAt": "2026-09-23T09:00:00Z",
                });
                world.mc.threads.insert(thread_id.clone(), row.clone());
                world.mc.send_row(&thread_id, &row);
                let key = format!("{}:{thread_id}", world.mc.environment_id);
                open_thread(world, &key)?;
                world.wait_for_with(
                    {
                        let key = key.clone();
                        move |w| {
                            terminals_of(w, |t| t.thread_key() == key).unwrap_or(false)
                                && drawer_available(w)
                        }
                    },
                    {
                        let key = key.clone();
                        move |w| {
                            format!(
                                "the drawer of {key}; it is on {}",
                                terminals_of(w, |t| t.thread_key().to_owned()).unwrap_or_default()
                            )
                        }
                    },
                )?;
                world.dispatch("terminal.toggle", json!({}))?;
                world.wait_for_with(
                    {
                        let thread_id = thread_id.clone();
                        move |w| {
                            terminal_attach(w, &thread_id, "term-1").is_some()
                                && !rows_in(w, false).is_empty()
                        }
                    },
                    describe_rows,
                )?;
                world.sync()?;
                print(
                    &mut world.mc,
                    &thread_id,
                    "term-1",
                    &format!("started in {thread_id}\r\n"),
                );
                world.sync()?;
                if n == 1 {
                    let session = terminal_session(world, "term-1")?;
                    world.mc.part::<SessionWorld>().session = Some(session);
                }
            }
            Ok(())
        },
    );
    steps.step("the user returns to one of them", |world, _, _| {
        // The first one, whose build went on printing while the user was
        // away.
        let thread_id = "visited-1";
        let attaches = attaches_of(world, thread_id, "term-1");
        world.mc.part::<SessionWorld>().attaches = attaches;
        expect!(
            attached(&world.mc).contains(&format!("{thread_id}/term-1")),
            "{thread_id}'s terminal is no longer attached"
        );
        print(&mut world.mc, thread_id, "term-1", BUILD);
        world.sync()?;
        let key = format!("{}:{thread_id}", world.mc.environment_id);
        open_thread(world, &key)?;
        world.wait_for_with(
            move |w| {
                terminals_of(w, |t| t.thread_key() == key).unwrap_or(false)
                    && drawer_open(w)
                    && !rows_in(w, false).is_empty()
            },
            describe_rows,
        )?;
        world.sync()
    });
    steps.step(
        "its terminals show their live output without replaying history",
        |world, _, _| {
            let thread_id = "visited-1";
            let session = terminal_session(world, "term-1")?;
            let (kept, attaches) = {
                let kept = world.mc.part::<SessionWorld>();
                (kept.session.clone(), kept.attaches)
            };
            expect!(
                Some(&session) == kept.as_ref(),
                "the terminal was attached anew"
            );
            let now = attaches_of(world, thread_id, "term-1");
            expect!(
                now == attaches && attaches == 1,
                "the terminal was attached {now} times"
            );
            let transcript = session.transcript();
            expect!(
                transcript.contains(BUILD) && transcript.contains("started in visited-1"),
                "the terminal shows \"{transcript}\""
            );
            let brick = drawer_brick(world, 700.0)?;
            world.wait_for_with(
                move |w| drawn(w, &brick).is_ok_and(|t| t.contains(BUILD)),
                move |w| {
                    format!(
                        "the drawer to draw the live output; it draws \"{}\"",
                        drawn(w, &brick).unwrap_or_default()
                    )
                },
            )
        },
    );

    steps.step("a thread working in a worktree", |world, _, _| {
        ensure_project(world)?;
        let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
        show_thread(world, &project, WORKTREE)?;
        world.wait_for("the thread's terminal drawer", drawer_available)
    });
    steps.step(
        "the user opens another terminal from the drawer",
        |world, _, _| {
            let thread_id = shown_thread(world);
            world.dispatch("terminal.toggle", json!({}))?;
            let id = thread_id.clone();
            world.wait_for_with(
                move |w| terminal_attach(w, &id, "term-1").is_some(),
                describe_rows,
            )?;
            // The drawer's own "New terminal" button.
            let brick = drawer_brick(world, 700.0)?;
            brick.click(world, "terminalNew")?;
            world.wait_for_with(
                move |w| terminal_attach(w, &thread_id, "term-2").is_some(),
                describe_rows,
            )
        },
    );
    steps.step(
        "it starts in the same folder and worktree as the thread",
        |world, _, _| {
            let Some(launch) = terminal_attach(world, &shown_thread(world), "term-2") else {
                fail!("term-2 was not attached");
            };
            let env = &launch["env"];
            expect!(
                launch["cwd"] == WORKTREE
                    && launch["worktreePath"] == WORKTREE
                    && env["HAL_C2_WORKTREE_PATH"] == WORKTREE
                    && env["HAL_C2_PROJECT_ROOT"] == "/work/p1",
                "term-2 started with {launch}"
            );
            Ok(())
        },
    );

    steps.step(
        "a project script is running in a terminal",
        |world, _, _| {
            ensure_project(world)?;
            let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
            add_action(world, &project, "Dev", "bun dev")?;
            show_thread(world, &project, WORKTREE)?;
            world.wait_for("the thread's terminal drawer", drawer_available)?;
            let thread_id = shown_thread(world);
            world.dispatch("workspace.runScript", json!({ "scriptId": "dev" }))?;
            world.wait_for_with(
                |w| terminal_writes(w, "term-1").contains(&"bun dev\r".to_owned()),
                |w| {
                    format!(
                        "the script to run; the MC got {}",
                        describe_terminal_calls(w)
                    )
                },
            )?;
            let Some(open) = terminal_call(world, "terminal.open", &thread_id, "term-1") else {
                fail!("the script's terminal was never opened");
            };
            world.mc.part::<SessionWorld>().script_launch = open;
            Ok(())
        },
    );
    steps.step(
        "the user opens another terminal next to it",
        |world, _, _| {
            let thread_id = shown_thread(world);
            // The drawer's split button, on the script's terminal.
            let brick = drawer_brick(world, 700.0)?;
            brick.click(world, "terminalSplit")?;
            world.wait_for_with(
                move |w| terminal_attach(w, &thread_id, "term-2").is_some(),
                describe_rows,
            )
        },
    );
    steps.step(
        "the new terminal starts in the same folder and worktree as the script",
        |world, _, _| {
            let script = world.mc.part::<SessionWorld>().script_launch.clone();
            let Some(launch) = terminal_attach(world, &shown_thread(world), "term-2") else {
                fail!("term-2 was not attached");
            };
            let rows = rows_in(world, false);
            expect!(
                rows.len() == 2 && rows[0].group == rows[1].group,
                "{}",
                describe_rows(world)
            );
            for field in ["cwd", "worktreePath", "env"] {
                expect!(
                    launch[field] == script[field] && !script[field].is_null(),
                    "term-2 started with {launch}; the script's with {script}"
                );
            }
            expect!(
                launch["cwd"] == WORKTREE,
                "term-2 started in {}",
                text(&launch["cwd"])
            );
            Ok(())
        },
    );
}
