//! What the keymap's commands do once a key runs them
//! (features/navigation/keybindings.feature, "What the commands do", and the
//! contexts keybinding-customisation.feature names): undoing sidebar actions,
//! the project a new thread asks for, what mod+w closes, steering with the
//! first queued message, and terminal commands on a hidden drawer.
//! desktop-qt's ShortcutSteps.cpp.

use std::cell::Cell;
use std::rc::Rc;

use chrono::Duration;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::keybindings::Focus;
use hal_c2_shell::controllers::palette::Palette;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::sidebar::{self, Sidebar};
use hal_c2_shell::controllers::terminals::Terminals;
use ljos::prelude::Value;
use serde_json::{Value as Json, json};

use super::add_project::prop;
use super::keybinding::{describe_key_press, key_delivered_to, key_ran, press_key, set_key_focus};
use super::stream::iso;
use super::thread_menu::{project_thread_commands, section_of};
use super::turn::{open_turn_thread, queue_turn_message, start_working_turn};
use crate::harness::{Outcome, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

#[derive(Default)]
struct ShortcutState {
    /// The threads the scenario acted on, by key.
    threads: Vec<String>,
    close_requests: Rc<Cell<i32>>,
    watching_window: bool,
}

fn state(world: &mut World) -> &mut ShortcutState {
    world.mc.part::<ShortcutState>()
}

const PROJECT: &str = "p1";

const NOWHERE: Focus = Focus {
    terminal: false,
    composer: false,
    editable: false,
};

const COMPOSER: Focus = Focus {
    terminal: false,
    composer: true,
    editable: true,
};

const TERMINAL: Focus = Focus {
    terminal: true,
    composer: false,
    editable: false,
};

fn project_row(id: &str) -> Json {
    json!({
        "id": id,
        "title": id,
        "workspaceRoot": format!("/work/{id}"),
        "createdAt": "2026-09-01T09:00:00Z",
        "updatedAt": "2026-09-01T09:00:00Z",
        "scripts": [],
    })
}

/// Threads "Alpha", "Beta"... of one project on a connected MC whose rows
/// follow the commands it accepts.
fn threads_of(world: &mut World, titles: &[&str]) -> Outcome<Vec<String>> {
    world
        .mc
        .projects
        .insert(PROJECT.to_owned(), project_row(PROJECT));
    let mut keys = Vec::new();
    for title in titles {
        let id = format!("t-{}", title.to_lowercase());
        world.mc.threads.insert(
            id.clone(),
            json!({
                "id": id,
                "projectId": PROJECT,
                "title": title,
                "createdAt": "2026-09-23T09:00:00Z",
                "updatedAt": "2026-09-23T09:00:00Z",
            }),
        );
        keys.push(format!("{}:{id}", world.mc.environment_id));
    }
    project_thread_commands(world);
    let connected = world.shell_subscriptions() > 0;
    set_key_focus(world, NOWHERE)?;
    if connected {
        // Already connected: they arrive as rows.
        let project = world.mc.projects[PROJECT].clone();
        world.mc.send_row_of(PROJECT, &project, "project");
        for key in &keys {
            let id = key.split_once(':').map_or(key.as_str(), |(_, id)| id);
            let row = world.mc.threads[id].clone();
            world.mc.send_row(id, &row);
        }
        world.sync()?;
    }
    let wanted = titles.len();
    world.wait_for("the threads in the list", |w| {
        sidebar::ordered_keys(w.engine()).len() >= wanted
    })?;
    state(world).threads = keys.clone();
    Ok(keys)
}

fn wait_for_section(world: &mut World, key: &str, section: &str, within: bool) -> Outcome {
    world.wait_for_with(
        |w| (section_of(w, key) == section) == within,
        |w| {
            format!(
                "{key} {} {section}; it is in {}, the MC has {}",
                if within { "in" } else { "out of" },
                section_of(w, key),
                w.describe_commands()
            )
        },
    )
}

fn settle_first(world: &mut World) -> Outcome {
    let key = threads_of(world, &["Alpha", "Beta"])?.remove(0);
    // The sidebar row's settle action.
    world.dispatch("thread.settle", json!({"key": key}))?;
    wait_for_section(world, &key, "settled", true)?;
    world.sync()
}

fn panel_state(world: &World) -> Outcome<(bool, String)> {
    world.with::<RightPanel, _>(|p, _| (p.is_open(), p.active_tab()))
}

fn terminals_state(world: &World) -> Outcome<(bool, bool, usize)> {
    world.with::<Terminals, _>(|t, _| (t.available(), t.is_open(), t.tabs().len()))
}

/// A thread shown in the window, its terminal drawer available.
fn show_thread(world: &mut World) -> Outcome<String> {
    let key = threads_of(world, &["Alpha"])?.remove(0);
    world.dispatch("thread.open", json!({"key": key}))?;
    world.wait_for("the thread's terminal drawer", |w| {
        terminals_state(w).is_ok_and(|(available, _, _)| available)
    })?;
    Ok(key)
}

fn watch_window(world: &mut World) {
    if std::mem::replace(&mut state(world).watching_window, true) {
        return;
    }
    let closes = state(world).close_requests.clone();
    let engine = world.engine().clone();
    // ShellWindow closes its window on it.
    let _ = engine.connect_by_name(
        Bridge::of(&engine).object(),
        "windowCommandRequested",
        move |_, args| {
            #[allow(clippy::cmp_owned)]
            if matches!(args.first(), Some(Value::String(command)) if command.to_string() == "close")
            {
                closes.set(closes.get() + 1);
            }
        },
    );
}

fn open_files_tab(world: &mut World) -> Outcome {
    world.with::<RightPanel, _>(|p, engine| p.open(engine, "files", &json!({})))?;
    world.wait_for_with(
        |w| panel_state(w).is_ok_and(|(open, tab)| open && tab == "files"),
        |w| format!("the Files tab; the panel is {}", show(&w.state("panel"))),
    )
}

fn last_command(world: &World, kind: &str) -> Json {
    world
        .mc
        .commands
        .iter()
        .rev()
        .find(|command| command["type"] == kind)
        .cloned()
        .unwrap_or(Json::Null)
}

fn command_count(world: &World, kind: &str) -> usize {
    world
        .mc
        .commands
        .iter()
        .filter(|command| command["type"] == kind)
        .count()
}

fn queue(world: &World) -> Vec<Json> {
    at(&world.state("turn"), "queue")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn turn_running(world: &World) -> bool {
    at(&world.state("turn"), "running")
        .as_bool()
        .unwrap_or(false)
}

pub fn register(steps: &mut Steps) {
    // Undo.
    steps.step(
        "the user settled a thread from the sidebar",
        |world, _, _| settle_first(world),
    );
    steps.step(
        "the user presses ([^ ]+) within 5 seconds",
        |world, c, _| {
            let time = world.now() + Duration::seconds(4);
            world.set_time(time);
            press_key(world, &c[0])
        },
    );
    steps.step("the thread is no longer settled", |world, _, _| {
        let key = state(world).threads[0].clone();
        expect!(
            key_ran(world, "thread.undo"),
            "{}",
            describe_key_press(world)
        );
        wait_for_section(world, &key, "settled", false)?;
        expect!(
            command_count(world, "thread.unsettle") == 1,
            "{}",
            world.describe_commands()
        );
        Ok(())
    });
    steps.step("the thread stays settled", |world, _, _| {
        world.sync()?;
        let key = state(world).threads[0].clone();
        expect!(
            section_of(world, &key) == "settled" && command_count(world, "thread.unsettle") == 0,
            "{}",
            world.describe_commands()
        );
        Ok(())
    });
    steps.step("the composer's own undo runs", |world, _, _| {
        // The window stood down, so the key is the field's (its undo).
        expect!(
            key_delivered_to(world) == "composer" && !key_ran(world, "thread.undo"),
            "{}",
            describe_key_press(world)
        );
        Ok(())
    });
    steps.step(
        "the user snoozed three threads one after another",
        |world, _, _| {
            let keys = threads_of(world, &["Alpha", "Beta", "Gamma", "Delta"])?;
            let until = iso(world.now() + Duration::days(1));
            for key in &keys[..3] {
                // What picking a preset from the row's snooze menu does.
                world.with::<Sidebar, _>(|s, engine| s.snooze(engine, key, &until))?;
                world.pump()?;
                wait_for_section(world, key, "snoozed", true)?;
                world.sync()?;
                let time = world.now() + Duration::seconds(1);
                world.set_time(time);
            }
            state(world).threads = keys[..3].to_vec();
            Ok(())
        },
    );
    steps.step("all three threads are awake again", |world, _, _| {
        expect!(
            key_ran(world, "thread.undo"),
            "{}",
            describe_key_press(world)
        );
        for key in state(world).threads.clone() {
            wait_for_section(world, &key, "snoozed", false)?;
        }
        expect!(
            command_count(world, "thread.unsnooze") == 3,
            "{}",
            world.describe_commands()
        );
        Ok(())
    });
    steps.step("the user pinned a thread 6 seconds ago", |world, _, _| {
        let key = threads_of(world, &["Alpha", "Beta"])?.remove(0);
        world.dispatch("thread.open", json!({"key": key}))?;
        world.wait_for("the thread to open", |w| {
            super::thread_menu::route_thread(w) == key
        })?;
        set_key_focus(world, NOWHERE)?;
        press_key(world, "mod+shift+p")?;
        wait_for_section(world, &key, "pinned", true)?;
        let time = world.now() + Duration::seconds(6);
        world.set_time(time);
        Ok(())
    });
    steps.step("the thread stays pinned", |world, _, _| {
        world.sync()?;
        let key = state(world).threads[0].clone();
        expect!(
            section_of(world, &key) == "pinned" && command_count(world, "thread.unpin") == 0,
            "{}",
            world.describe_commands()
        );
        Ok(())
    });

    // A new thread.
    steps.step(
        "the user has several projects and none is in scope",
        |world, _, _| {
            threads_of(world, &["Alpha"])?;
            world.mc.projects.insert("p2".to_owned(), project_row("p2"));
            world.mc.send_row_of("p2", &project_row("p2"), "project");
            world.sync()?;
            world.wait_for("two projects in the sidebar", |w| {
                sidebar::groups(w.engine()).len() == 2
            })?;
            // The window shows no project (the usage page) and the list is not scoped.
            world.dispatch("usage.open", Json::Null)?;
            expect!(
                sidebar::scope(world.engine()).is_none(),
                "the thread list is scoped"
            );
            Ok(())
        },
    );
    steps.step("the user is asked to choose a project", |world, _, _| {
        world.sync()?;
        let (open, count) = world.with::<Palette, _>(|p, _| (p.is_open(), p.count()))?;
        let submenu = prop(world, "submenu").unwrap_or_default();
        expect!(
            open && submenu == "New thread in..." && count == 2,
            "the palette is {} on \"{submenu}\" with {count} entries; the route is {}",
            if open { "open" } else { "closed" },
            show(&world.state("route"))
        );
        expect!(
            at(&world.state("route"), "kind") == "usage",
            "a thread started without asking: {}",
            show(&world.state("route"))
        );
        Ok(())
    });

    // mod+w closes the innermost thing.
    steps.step(
        "a focused terminal and an open right panel tab",
        |world, _, _| {
            show_thread(world)?;
            watch_window(world);
            open_files_tab(world)?;
            world.dispatch("terminal.toggle", Json::Null)?;
            world.wait_for("the thread's first terminal", |w| {
                terminals_state(w).is_ok_and(|(_, open, tabs)| open && tabs == 1)
            })?;
            set_key_focus(world, TERMINAL)
        },
    );
    steps.step(
        "an active right panel tab and no focused terminal",
        |world, _, _| {
            show_thread(world)?;
            watch_window(world);
            open_files_tab(world)?;
            set_key_focus(world, NOWHERE)
        },
    );
    steps.step("nothing but the window", |world, _, _| {
        show_thread(world)?;
        watch_window(world);
        let (open, _) = panel_state(world)?;
        let (_, drawer, _) = terminals_state(world)?;
        expect!(!open && !drawer, "a panel or terminal is open");
        set_key_focus(world, NOWHERE)
    });
    steps.step("the active right panel tab closes", |world, _, _| {
        world.sync()?;
        let (open, tab) = panel_state(world)?;
        let closes = state(world).close_requests.get();
        expect!(
            !open && tab != "files" && closes == 0,
            "{}; the panel is {}",
            describe_key_press(world),
            show(&world.state("panel"))
        );
        Ok(())
    });
    steps.step("the window closes", |world, _, _| {
        let closes = state(world).close_requests.get();
        expect!(
            closes == 1,
            "{}; the window was asked to close {closes} times",
            describe_key_press(world)
        );
        Ok(())
    });

    // Steering.
    steps.step(
        "a turn is running and two messages are queued",
        |world, _, _| {
            start_working_turn(world)?;
            queue_turn_message(world, "check the logs")?;
            queue_turn_message(world, "update the docs")?;
            world.wait_for_with(
                |w| queue(w).len() == 2,
                |w| {
                    format!(
                        "two queued messages; the turn is {}",
                        show(&w.state("turn"))
                    )
                },
            )?;
            set_key_focus(world, NOWHERE)
        },
    );
    steps.step(
        "the first queued message is sent as a steer",
        |world, _, _| {
            world.sync()?;
            let command = last_command(world, "queued-message.promote-to-steer");
            expect!(
                command["queuedRunId"] == "run-queued-check the logs",
                "{}; the MC was told {}",
                describe_key_press(world),
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step("the second stays queued", |world, _, _| {
        expect!(
            command_count(world, "queued-message.promote-to-steer") == 1,
            "{}",
            world.describe_commands()
        );
        let queued = queue(world)
            .iter()
            .any(|entry| text(&entry["text"]) == "update the docs");
        expect!(queued, "the queue is {}", show(&Json::Array(queue(world))));
        Ok(())
    });

    // Terminal commands on a hidden drawer.
    steps.step(
        "the thread's terminal is shown with a new terminal",
        |world, _, _| {
            world.wait_for("the drawer open on one terminal", |w| {
                terminals_state(w).is_ok_and(|(_, open, tabs)| open && tabs == 1)
            })
        },
    );
    steps.step(
        "the thread's terminal is shown with a second terminal (side by side|stacked below)",
        |world, c, _| {
            let stacked = c[0] == "stacked below";
            world.wait_for_with(
                |w| {
                    let Ok((open, rows)) = w.with::<Terminals, _>(|t, _| (t.is_open(), t.tabs()))
                    else {
                        return false;
                    };
                    open && rows.len() == 2
                        && rows[0].group == rows[1].group
                        && rows[1].slot == 1
                        && rows[1].vertical == stacked
                },
                |w| {
                    let tabs = terminals_state(w).map_or(0, |(_, _, tabs)| tabs);
                    format!("two terminals in one group; there are {tabs}")
                },
            )
        },
    );

    // Where the keyboard is (the keymap's contexts).
    steps.step(
        "the user is outside text fields and terminals",
        |world, _, _| set_key_focus(world, NOWHERE),
    );
    steps.step(
        "(?:the user is in the composer|a text field has focus)",
        |world, _, _| set_key_focus(world, COMPOSER),
    );
    steps.step("a terminal has focus", |world, _, _| {
        set_key_focus(world, TERMINAL)
    });
    // The desktop's preview is the right panel's Previews tab.
    steps.step("the preview is closed", |world, _, _| {
        show_thread(world)?;
        let (open, tab) = panel_state(world)?;
        expect!(
            !(open && tab == "previews"),
            "{}",
            show(&world.state("panel"))
        );
        set_key_focus(world, NOWHERE)
    });
    steps.step("both the terminal and preview are open", |world, _, _| {
        show_thread(world)?;
        world.dispatch("terminal.toggle", Json::Null)?;
        world.wait_for("the terminal drawer", |w| {
            terminals_state(w).is_ok_and(|(_, open, _)| open)
        })?;
        set_key_focus(world, NOWHERE)?;
        press_key(world, "mod+shift+j")?;
        world.wait_for_with(
            |w| panel_state(w).is_ok_and(|(open, tab)| open && tab == "previews"),
            |w| format!("the Previews tab; the panel is {}", show(&w.state("panel"))),
        )
    });
    steps.step(
        "the user is in the composer while a turn runs",
        |world, _, _| {
            start_working_turn(world)?;
            world.wait_for_with(turn_running, |w| {
                format!("a running turn; the turn is {}", show(&w.state("turn")))
            })?;
            set_key_focus(world, COMPOSER)
        },
    );
    steps.step(
        "the composer has focus and no turn is running",
        |world, _, _| {
            open_turn_thread(world)?;
            expect!(!turn_running(world), "{}", show(&world.state("turn")));
            set_key_focus(world, COMPOSER)
        },
    );
    steps.step(
        "the user is in the composer of a new thread",
        |world, _, _| {
            threads_of(world, &["Alpha"])?;
            let key = world.project_key(PROJECT);
            world.start_new_thread(json!({"projectKey": key}))?;
            let route = world.state("route");
            if at(&route, "kind") != "draft" {
                fail!("{}", show(&route));
            }
            set_key_focus(world, COMPOSER)
        },
    );
}
