//! More than one window (navigation/windows.feature): each window has its own
//! route, drafts and panels over the shell's one MC connection, and reopens
//! with them after a restart until it is closed. Port of WindowSteps.cpp, with
//! the quit shortcut Quit.h hands to other steps.

use std::cell::Cell;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controller::{self, MAIN};
use hal_c2_shell::controllers::composer::kept;
use hal_c2_shell::controllers::quit::{HOLD, QUIT, QuitController};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::keybindings::qt;
use ljos::keys::{KeyKind, Modifiers};
use serde_json::{Value, json};

use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::keybinding::send_key;
use crate::steps::settings::fake_config;
use crate::steps::stream::{PROJECT, followers};
use crate::world::World;
use crate::{expect, fail};

const FIRST: &str = "t1";
const SECOND: &str = "t2";
const STABLE_ID: &str = "stable";
const DRAFT: &str = "Carry on from the other window";

fn key_of(world: &World, thread: &str) -> String {
    format!("{}:{}", world.mc.environment_id, thread)
}

/// The MC's subscriptions from the second window on, and its id once the
/// first window closed.
#[derive(Default)]
struct SecondWindowWork {
    first_sub: usize,
    id: String,
}

#[derive(Default)]
struct QuitState {
    quits: Rc<Cell<i32>>,
    hooked: bool,
}

/// The window shell has no opener of its own: the headless one shows nothing.
fn ensure_opener(world: &World) {
    controller::set_window_opener(world.engine(), |_, _| {});
}

fn window_ids(world: &World) -> Vec<String> {
    controller::windows(world.engine())
}

fn second_id(world: &World) -> Option<String> {
    window_ids(world).get(1).cloned()
}

fn second(world: &World) -> Outcome<String> {
    match second_id(world) {
        Some(id) => Ok(id),
        None => fail!("there is no second window"),
    }
}

fn bridge(world: &World, id: &str) -> Outcome<Bridge> {
    match controller::window_bridge(world.engine(), id) {
        Some(bridge) => Ok(bridge),
        None => fail!("the window {} is not open", id),
    }
}

/// What window `id` published under `key`.
fn published(world: &World, id: &str, key: &str) -> Value {
    controller::window_bridge(world.engine(), id)
        .and_then(|bridge| bridge.published(world.engine(), key))
        .unwrap_or(Value::Null)
}

/// Dispatches in window `id`, then hands the front back to the first window,
/// whose state `World::state` reads.
fn act_in(world: &mut World, id: &str, action: &str, payload: Value) -> Outcome {
    let engine = world.engine().clone();
    bridge(world, id)?.dispatch(&engine, action, payload);
    if let Some(main) = controller::window_bridge(&engine, MAIN) {
        main.set_front(&engine);
    }
    world.pump()
}

fn shown_by(world: &World, id: &str) -> String {
    text(at(&published(world, id, "route"), "threadKey"))
}

/// Two threads of one project, the first open in the first window.
fn connect_with_threads(world: &mut World) -> Outcome {
    world.mc.projects.insert(
        PROJECT.to_owned(),
        json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": "/work/shop", "scripts": []}),
    );
    for id in [FIRST, SECOND] {
        world.mc.threads.insert(
            id.to_owned(),
            json!({"id": id, "title": id, "projectId": PROJECT,
                   "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"}),
        );
    }
    world.connect()?;
    world.wait_for("the shell to start", |w| w.active())?;
    ensure_opener(world);
    let key = key_of(world, FIRST);
    world.dispatch("thread.open", json!({"key": key}))?;
    world.sync()
}

fn open_second(world: &mut World, payload: Value) -> Outcome<String> {
    world.mc.part::<SecondWindowWork>().first_sub = world.mc.subscriptions.len();
    world.dispatch("window.new", payload)?;
    second(world)
}

fn open_in(world: &mut World, id: &str, thread: &str) -> Outcome {
    let key = key_of(world, thread);
    act_in(world, id, "thread.open", json!({"key": key}))?;
    let (window, wanted) = (id.to_owned(), key_of(world, thread));
    world.wait_for_with(
        |w| shown_by(w, &window) == wanted,
        |w| {
            format!(
                "the window to show {thread}; it shows {}",
                shown_by(w, &window)
            )
        },
    )?;
    world.sync()
}

fn expect_first_on(world: &mut World, thread: &str) -> Outcome {
    world.sync()?;
    let shown = shown_by(world, MAIN);
    let route = published(world, MAIN, "route");
    expect!(
        shown == key_of(world, thread) && text(at(&route, "threadKey")) == shown,
        "the first window shows {}",
        show(&route)
    );
    Ok(())
}

fn toast_titles(world: &World, id: &str) -> Vec<String> {
    let toasts = published(world, id, "toasts");
    at(&toasts, "items")
        .as_array()
        .map(|items| items.iter().map(|item| text(at(item, "title"))).collect())
        .unwrap_or_default()
}

/// The zoom factor window `id` draws its content at.
fn zoom_of(world: &World, id: &str) -> f64 {
    at(&published(world, id, "layout"), "zoom")
        .as_f64()
        .unwrap_or(0.0)
}

fn ensure_connected(world: &mut World) -> Outcome {
    if world.shell_subscriptions() > 0 {
        return Ok(());
    }
    world.connect()?;
    world.wait_for("the shell to start", |w| w.active())
}

fn collect_keys(value: &Value, keys: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            for (name, item) in map {
                if name == "key" {
                    keys.push(text(item));
                }
                collect_keys(item, keys);
            }
        }
        Value::Array(items) => items.iter().for_each(|item| collect_keys(item, keys)),
        _ => {}
    }
}

fn set_text(world: &mut World, id: &str, target: &str) -> Outcome {
    let revision = world.next_edit;
    world.next_edit += 1;
    act_in(
        world,
        id,
        "composer.text.set",
        json!({"target": target,
               "edit": {"clientId": "qml", "revision": revision},
               "text": DRAFT, "cursor": DRAFT.chars().count()}),
    )
}

/// The quit shortcut's counter, hooked on the first use after a start.
fn quitting(world: &mut World) -> Rc<Cell<i32>> {
    let engine = world.engine().clone();
    let state = world.mc.part::<QuitState>();
    if !state.hooked {
        state.hooked = true;
        let quits = state.quits.clone();
        let counter = quits.clone();
        let _ = controller::with::<QuitController, _>(&engine, |quit, _| {
            quit.on_quit(move |_| counter.set(counter.get() + 1));
        });
        return quits;
    }
    state.quits.clone()
}

fn quit_key(world: &mut World, kind: KeyKind, auto_repeat: bool) -> Outcome {
    send_key(world, kind, qt::KEY_Q, Modifiers::CONTROL, auto_repeat).map(|_| ())
}

/// mod goes down, then Q; `held_ms` later (auto-repeating meanwhile, as a held
/// key does after half a second) Q comes up, then mod.
pub fn press_quit_shortcut(world: &mut World, held_ms: u64, release_mod: bool) -> Outcome {
    quitting(world);
    send_key(
        world,
        KeyKind::Press,
        qt::KEY_CONTROL,
        Modifiers::CONTROL,
        false,
    )?;
    quit_key(world, KeyKind::Press, false)?;
    let mut elapsed = 0;
    let mut at_ms = 500;
    while at_ms <= held_ms {
        world.advance(at_ms - elapsed)?;
        elapsed = at_ms;
        quit_key(world, KeyKind::Press, true)?;
        at_ms += 33;
    }
    world.advance(held_ms - elapsed)?;
    quit_key(world, KeyKind::Release, false)?;
    if release_mod {
        send_key(
            world,
            KeyKind::Release,
            qt::KEY_CONTROL,
            Modifiers::empty(),
            false,
        )?;
    }
    world.sync()
}

/// Moves the clock the quit shortcut is timed on.
pub fn advance_quit_clock(world: &mut World, ms: u64) -> Outcome {
    quitting(world);
    world.advance(ms)
}

/// How often the app was asked to quit.
pub fn quit_requests(world: &mut World) -> i32 {
    quitting(world).get()
}

/// What the quit hint says.
pub fn quit_shortcut_hint(world: &mut World) -> Outcome<String> {
    world.sync()?;
    Ok(text(at(&world.state("quitHint"), "message")))
}

/// The quit shortcut as the platform's menus name it.
const QUIT_KEYS: &str = if cfg!(target_os = "macos") {
    "⌘Q"
} else {
    "Ctrl+Q"
};

pub fn register(steps: &mut Steps) {
    steps.step(
        "the user's shell layout opens a second window",
        |world, _, _| {
            connect_with_threads(world)?;
            open_second(world, json!({})).map(|_| ())
        },
    );
    steps.step("a second window is open", |world, _, _| {
        connect_with_threads(world)?;
        open_second(world, json!({})).map(|_| ())
    });
    steps.step(
        "the user opens a thread in the second window",
        |world, _, _| {
            let id = second(world)?;
            open_in(world, &id, SECOND)
        },
    );
    steps.step(
        "the first window still shows its own thread",
        |world, _, _| {
            expect_first_on(world, FIRST)?;
            let id = second(world)?;
            let shown = shown_by(world, &id);
            expect!(
                shown == key_of(world, SECOND),
                "the second window shows {}",
                shown
            );
            Ok(())
        },
    );

    steps.step("the user closes the second window", |world, _, _| {
        // It was showing the other thread, followed only for it.
        let id = second(world)?;
        open_in(world, &id, SECOND)?;
        world.wait_for("the second window to follow its thread", |w| {
            !followers(&w.mc, SECOND).is_empty()
        })?;
        controller::close_window(world.engine(), &id);
        world.pump()
    });
    // The first window closed with others open: the second becomes the main one.
    steps.step("the user closes the first window", |world, _, _| {
        if let Some(id) = second_id(world) {
            open_in(world, &id, SECOND)?;
            world.mc.part::<SecondWindowWork>().id = id;
        }
        controller::close_window(world.engine(), MAIN);
        world.pump()
    });
    steps.step(
        "the second window is still open on its own thread",
        |world, _, _| {
            world.sync()?;
            let windows = window_ids(world);
            let id = world.mc.part::<SecondWindowWork>().id.clone();
            expect!(
                windows.len() == 1 && windows[0] == id,
                "{} windows are open, the first {}",
                windows.len(),
                windows.first().cloned().unwrap_or_default()
            );
            let shown = shown_by(world, &id);
            expect!(
                shown == key_of(world, SECOND),
                "the second window shows {}",
                shown
            );
            expect!(
                !followers(&world.mc, SECOND).is_empty(),
                "the second window stopped following its thread"
            );
            Ok(())
        },
    );
    steps.step("the app is still running", |world, _, _| {
        expect!(
            !world.engine().quit_requested(),
            "the app was told its last window closed"
        );
        Ok(())
    });
    steps.step("only the second window reopens", |world, _, _| {
        let windows = window_ids(world);
        let id = world.mc.part::<SecondWindowWork>().id.clone();
        expect!(
            windows.len() == 1 && windows[0] == id,
            "{} windows reopened, the first {}",
            windows.len(),
            windows.first().cloned().unwrap_or_default()
        );
        let wanted = key_of(world, SECOND);
        world.wait_for_with(
            |w| shown_by(w, &id) == wanted,
            |w| {
                format!(
                    "the window to reopen on {SECOND}; it shows {}",
                    shown_by(w, &id)
                )
            },
        )
    });
    steps.step(
        "the first window stays open on the same thread",
        |world, _, _| {
            let open = window_ids(world).len();
            expect!(open == 1, "{} windows are open", open);
            expect_first_on(world, FIRST)?;
            world.wait_for("the closed window's thread to be let go", |w| {
                followers(&w.mc, SECOND).is_empty()
            })?;
            expect!(
                !followers(&world.mc, FIRST).is_empty(),
                "the first window stopped following its thread"
            );
            Ok(())
        },
    );

    // What main.cpp publishes on the first window's bridge when the backend fails.
    steps.step("the backend fails", |world, _, _| {
        let engine = world.engine().clone();
        Bridge::of(&engine).publish(&engine, "backendError", json!("the MC exited"));
        world.pump()
    });
    steps.step("the user opens a third window", |world, _, _| {
        world.dispatch("window.new", json!({}))?;
        let open = window_ids(world).len();
        expect!(open == 3, "{} windows are open", open);
        Ok(())
    });
    steps.step("every window shows the failure", |world, _, _| {
        for id in window_ids(world) {
            let error = text(&published(world, &id, "backendError"));
            expect!(
                error == "the MC exited",
                "window {} shows the error \"{}\"",
                id,
                error
            );
        }
        Ok(())
    });

    // A failure to save settings reaches the window that asked.
    steps.step("the MC refuses to save settings", |world, _, _| {
        world.wait_for("the shell to read the MC's settings", |w| {
            Settings::of(w.engine()).ready()
        })?;
        fake_config(&mut world.mc).refuse_writes = "The settings file is read-only.".to_owned();
        Ok(())
    });
    steps.step(
        "the user changes an MC setting in the second window and goes back to the first",
        |world, _, _| {
            let id = second(world)?;
            let engine = world.engine().clone();
            controller::in_window(&engine, &id, || {
                Settings::of(&engine).set(&engine, "autoResumeLimitedThreads", json!(true));
            });
            if let Some(main) = controller::window_bridge(&engine, MAIN) {
                main.set_front(&engine);
            }
            world.pump()
        },
    );
    steps.step(
        "the second window says \"Setting not saved\"",
        |world, _, _| {
            let id = second(world)?;
            world.wait_for_with(
                |w| {
                    toast_titles(w, &id)
                        .iter()
                        .any(|t| t == "Setting not saved")
                },
                |w| {
                    format!(
                        "the second window's toasts are {}",
                        toast_titles(w, &id).join(", ")
                    )
                },
            )
        },
    );
    steps.step("the first window shows no toast", |world, _, _| {
        let titles = toast_titles(world, MAIN);
        expect!(
            titles.is_empty(),
            "the first window's toasts are {}",
            titles.join(", ")
        );
        Ok(())
    });

    // Mc work in flight when a window closes (McClient's contexts).
    steps.step("the second window is waiting on the MC", |world, _, _| {
        let id = second(world)?;
        open_in(world, &id, SECOND)?;
        // A refusal would toast in the window that asked.
        world
            .mc
            .refusals
            .insert("thread.unsettle".to_owned(), "Not now".to_owned());
        world.mc.hold("answers");
        let sent = world.mc.commands.len();
        let key = key_of(world, SECOND);
        act_in(world, &id, "thread.unsettle", json!({"key": key}))?;
        world.wait_for("the second window's command to reach the MC", |w| {
            w.mc.commands.len() > sent
        })
    });
    steps.step(
        "the MC answers what the closed window asked",
        |world, _, _| {
            world.mc.answer_held();
            // And a frame already on its way to each of the window's subscriptions.
            let first = world.mc.part::<SecondWindowWork>().first_sub;
            let ids: Vec<Value> = world.mc.subscriptions[first.min(world.mc.subscriptions.len())..]
                .iter()
                .map(|sub| sub["id"].clone())
                .collect();
            for id in ids {
                world.mc.send(&json!({"t": "snapshot", "id": id}));
            }
            world.sync()
        },
    );
    steps.step(
        "the MC no longer sends the closed window anything",
        |world, _, _| {
            world.sync()?;
            let first = world.mc.part::<SecondWindowWork>().first_sub;
            let mut live = Vec::new();
            for sub in world.mc.subscriptions.iter().skip(first) {
                if let Some(id) = sub["id"].as_i64() {
                    let shape = world.mc.shape_of(id);
                    if !shape.is_null() {
                        live.push(show(&shape));
                    }
                }
            }
            expect!(
                live.is_empty(),
                "the closed window still follows {}",
                live.join(", ")
            );
            Ok(())
        },
    );

    // A window's id names its folder (valid_window_id).
    steps.step(
        &format!("the shell is asked for a second window with the id {Q}"),
        |world, c, _| {
            connect_with_threads(world)?;
            // The id may be refused; the step after looks at what opened.
            open_second(world, json!({"id": c[0]})).map(|_| ())
        },
    );
    steps.step(
        "the second window keeps its files in its own folder",
        |world, _, _| {
            let id = second(world)?;
            let windows = world.home_dir().join("state/shell-windows");
            let listed = |dir: &std::path::Path| -> Vec<String> {
                std::fs::read_dir(dir)
                    .map(|entries| {
                        entries
                            .flatten()
                            .map(|e| e.file_name().to_string_lossy().into_owned())
                            .collect()
                    })
                    .unwrap_or_default()
            };
            expect!(
                !id.contains('/') && !id.contains('.') && windows.join(&id).is_dir(),
                "the window is \"{}\"; the windows folder holds {}",
                id,
                listed(&windows).join(", ")
            );
            let home = listed(world.home_dir());
            expect!(
                !home.iter().any(|name| name == "outside"),
                "a folder was made outside the windows folder: {}",
                home.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the saved windows are {Q} and {Q}"),
        |world, c, _| {
            let state = world.home_dir().join("state");
            std::fs::create_dir_all(&state).map_err(|e| crate::harness::Failure(e.to_string()))?;
            let saved = json!({"open": [MAIN, c[0], c[1]]});
            std::fs::write(state.join("shell-windows.json"), saved.to_string())
                .map_err(|e| crate::harness::Failure(e.to_string()))
        },
    );
    steps.step(
        &format!("only the window {Q} reopens beside the first"),
        |world, c, _| {
            let ids = window_ids(world);
            expect!(
                ids.len() == 2 && ids[1] == c[0],
                "the open windows are {}",
                ids.join(", ")
            );
            Ok(())
        },
    );

    steps.step(
        "the second window is signed in to the same environments",
        |world, _, _| {
            let id = second(world)?;
            world.sync()?;
            let mut keys = Vec::new();
            collect_keys(&published(world, &id, "sidebar"), &mut keys);
            let (a, b) = (key_of(world, FIRST), key_of(world, SECOND));
            expect!(
                keys.contains(&a) && keys.contains(&b),
                "the second window's sidebar lists {}",
                keys.join(", ")
            );
            // One connection, and so one sign-in, for every window.
            expect!(
                world.mc.connections.len() == 1,
                "the shell opened {} connections",
                world.mc.connections.len()
            );
            Ok(())
        },
    );
    steps.step(
        "navigating in one window does not navigate the other",
        |world, _, _| {
            let id = second(world)?;
            open_in(world, &id, SECOND)?;
            expect_first_on(world, FIRST)?;
            world.dispatch("settings.open", json!({}))?;
            world.sync()?;
            expect!(
                at(&world.state("route"), "kind") == "settings",
                "the first window did not open settings"
            );
            let route = published(world, &id, "route");
            expect!(
                shown_by(world, &id) == key_of(world, SECOND) && at(&route, "kind") == "thread",
                "the second window moved to {}",
                show(&route)
            );
            Ok(())
        },
    );

    steps.step(
        "a second window with a stable identity has a draft and an open panel",
        |world, _, _| {
            connect_with_threads(world)?;
            let id = open_second(world, json!({"id": STABLE_ID}))?;
            expect!(id == STABLE_ID, "the window is {}", id);
            open_in(world, &id, SECOND)?;
            let target = key_of(world, SECOND);
            set_text(world, &id, &target)?;
            act_in(world, &id, "rightPanel.toggle", json!({}))?;
            world.sync()?;
            expect!(
                at(&published(world, &id, "panel"), "isOpen") == true,
                "the second window's panel did not open"
            );
            expect!(
                at(&world.state("panel"), "isOpen") != true,
                "the first window's panel opened too"
            );
            Ok(())
        },
    );
    // Unsent work outlives the window it was typed in.
    steps.step(
        "the user has unsent work in the second window",
        |world, _, _| {
            let id = second(world)?;
            open_in(world, &id, SECOND)?;
            let target = key_of(world, SECOND);
            set_text(world, &id, &target)?;
            // And a new thread started there.
            act_in(world, &id, "thread.new", json!({}))?;
            world.sync()?;
            let route = published(world, &id, "route");
            expect!(
                at(&route, "kind") == "draft",
                "the second window shows {}",
                show(&route)
            );
            world.draft_id = text(at(&route, "draftId"));
            let draft = world.draft_id.clone();
            set_text(world, &id, &draft)?;
            world.sync()
        },
    );
    steps.step("the first window has that unsent work", |world, _, _| {
        world.sync()?;
        let engine = world.engine().clone();
        let thread_draft = kept::draft(&engine, &key_of(world, SECOND));
        expect!(
            thread_draft == DRAFT,
            "the first window's draft of the thread is \"{}\"",
            thread_draft
        );
        let new_draft = kept::draft(&engine, &world.draft_id);
        expect!(
            new_draft == DRAFT,
            "the first window's new-thread draft is \"{}\"",
            new_draft
        );
        let draft_id = world.draft_id.clone();
        world.dispatch("draft.open", json!({"draftId": draft_id}))?;
        world.sync()?;
        let shown = text(at(&world.state("composer"), "text"));
        expect!(
            shown == DRAFT,
            "the first window's composer on the new thread shows \"{}\"",
            shown
        );
        Ok(())
    });

    steps.step("the user restarts the app", |world, _, _| {
        world.restart()?;
        world.mc.part::<QuitState>().hooked = false;
        world.connect()?;
        world.wait_for("the shell to start", |w| w.active())?;
        // The headless opener shows nothing; the saved windows reopen now.
        ensure_opener(world);
        controller::restore_windows(world.engine());
        let engine = world.engine().clone();
        if let Some(main) = controller::window_bridge(&engine, MAIN) {
            main.set_front(&engine);
        }
        world.pump()
    });
    steps.step("that window has the same draft and panel", |world, _, _| {
        let id = STABLE_ID.to_owned();
        expect!(
            window_ids(world).contains(&id),
            "the window {} did not reopen",
            id
        );
        let wanted = key_of(world, SECOND);
        world.wait_for_with(
            |w| shown_by(w, &id) == wanted,
            |w| {
                format!(
                    "the window to reopen on {SECOND}; it shows {}",
                    shown_by(w, &id)
                )
            },
        )?;
        world.sync()?;
        let engine = world.engine().clone();
        let text_of = kept::draft(&engine, &key_of(world, SECOND));
        expect!(text_of == DRAFT, "the window's draft is \"{}\"", text_of);
        let panel = published(world, &id, "panel");
        expect!(
            at(&panel, "isOpen") == true,
            "the window's panel is {}",
            show(&panel)
        );
        // The first window kept its own route, and sees the same drafts.
        expect_first_on(world, FIRST)?;
        Ok(())
    });

    // The app's zoom (the application menu's mod+=, mod++, mod+-, mod+0).
    steps.step("the app is zoomed in", |world, _, _| {
        ensure_connected(world)?;
        let engine = world.engine().clone();
        for _ in 0..2 {
            Commands::of(&engine).run(&engine, "view.zoomIn");
        }
        world.sync()?;
        let zoom = zoom_of(world, MAIN);
        expect!(zoom > 1.0, "the app is at {}", zoom);
        Ok(())
    });
    steps.step(
        "the app content is (larger|smaller|back to its actual size)",
        |world, c, _| {
            world.sync()?;
            let zoom = zoom_of(world, MAIN);
            let ok = match c[0].as_str() {
                "larger" => zoom > 1.0,
                "smaller" => zoom > 0.0 && zoom < 1.0,
                _ => (zoom - 1.0).abs() < 1e-9,
            };
            expect!(ok, "the app is at {}", zoom);
            Ok(())
        },
    );
    steps.step(
        "the second window's content is larger too",
        |world, _, _| {
            world.sync()?;
            let id = second(world)?;
            let (first, other) = (zoom_of(world, MAIN), zoom_of(world, &id));
            expect!(
                first > 1.0 && (other - first).abs() < 1e-9,
                "the first window is at {}, the second at {}",
                first,
                other
            );
            Ok(())
        },
    );

    // Quitting (QuitController, `confirmQuit`).
    steps.step(
        "the quit shortcut is set to (Hold|Double press|Direct)",
        |world, c, _| {
            let mode = match c[0].as_str() {
                "Hold" => "hold",
                "Direct" => "direct",
                _ => "double-click",
            };
            let engine = world.engine().clone();
            Settings::of(&engine).set(&engine, "confirmQuit", json!(mode));
            quitting(world);
            world.pump()
        },
    );
    steps.step("the user holds mod\\+Q for 1.2 seconds", |world, _, _| {
        press_quit_shortcut(world, HOLD.as_millis() as u64 + 40, true)
    });
    steps.step(
        "the user presses mod\\+Q twice within 500 milliseconds",
        |world, _, _| {
            press_quit_shortcut(world, 80, false)?;
            advance_quit_clock(world, 220)?;
            press_quit_shortcut(world, 80, true)
        },
    );
    steps.step("the user presses mod\\+Q once", |world, _, _| {
        press_quit_shortcut(world, 80, true)
    });
    steps.step(
        "the user chooses Quit from the command palette",
        |world, _, _| {
            ensure_connected(world)?;
            quitting(world);
            let engine = world.engine().clone();
            expect!(
                Commands::of(&engine).run(&engine, QUIT),
                "there is no Quit command"
            );
            world.pump()
        },
    );
    steps.step("the app quits", |world, _, _| {
        // By the quit shortcut, or by closing the last window.
        let hooked = quit_requests(world);
        let quits = if hooked > 0 {
            hooked
        } else {
            i32::from(world.engine().quit_requested())
        };
        expect!(quits == 1, "the app was asked to quit {} times", quits);
        Ok(())
    });
    steps.step("the app keeps running", |world, _, _| {
        expect!(quit_requests(world) == 0, "the app was asked to quit");
        Ok(())
    });
    steps.step(
        "the user is told to hold the shortcut or press twice to quit",
        |world, _, _| {
            let hint = quit_shortcut_hint(world)?;
            expect!(
                hint == format!("Hold {QUIT_KEYS} or press twice to quit"),
                "the hint says \"{}\"",
                hint
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told to press the shortcut again to quit",
        |world, _, _| {
            let hint = quit_shortcut_hint(world)?;
            expect!(
                hint == format!("Press {QUIT_KEYS} again to quit"),
                "the hint says \"{}\"",
                hint
            );
            Ok(())
        },
    );
}
