//! Arranging the pinned and active threads by hand
//! (threads/pinning-and-order.feature): moving a thread from its menu, and
//! what a drag in the list does, as the Sidebar brick reports it
//! (`thread.drop {key, section, beforeKey}`). The MC keeps the order
//! (thread.pin.reorder, thread.active.reorder; thread_menu.rs projects
//! them). desktop-qt's ThreadOrderSteps.cpp.

use hal_c2_shell::controllers::keybindings::{Focus, Keymap};
use hal_c2_shell::keybindings;
use serde_json::{Value, json};

use super::thread_menu::{id_in, key_of, section_of, update_row};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

#[derive(Default)]
struct Arrangement {
    dragged: String,
    commands_before: usize,
    shortcut_taken: bool,
}

fn scene(world: &mut World) -> &mut Arrangement {
    world.mc.part::<Arrangement>()
}

fn titles_of(world: &World, section: &str) -> Vec<String> {
    world.state("sidebar")[section]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| text(&row["title"]))
        .collect()
}

fn wait_order(world: &mut World, section: &str, first: &str, second: &str) -> Outcome {
    let order = |w: &World| {
        let titles = titles_of(w, section);
        let place = |t: &str| titles.iter().position(|x| x == t);
        matches!((place(first), place(second)), (Some(a), Some(b)) if a < b)
    };
    world.wait_for_with(order, |w| {
        format!(
            "{first} above {second}; the {section} threads are {}",
            titles_of(w, section).join(", ")
        )
    })
}

fn drop_on(world: &mut World, title: &str, section: &str, before: &str) -> Outcome {
    world.sync()?;
    let key = key_of(world, title)?;
    let before_key = if before.is_empty() {
        Value::Null
    } else {
        json!(key_of(world, before)?)
    };
    let commands = world.mc.commands.len();
    let state = scene(world);
    state.dragged = title.to_owned();
    state.commands_before = commands;
    world.dispatch(
        "thread.drop",
        json!({"key": key, "section": section, "beforeKey": before_key}),
    )
}

fn pick_from_menu(world: &mut World, title: &str, id: &str) -> Outcome {
    world.sync()?;
    let key = key_of(world, title)?;
    world.dispatch("thread.menu", json!({"key": key, "x": 40, "y": 120}))?;
    let menu = world.state("menu");
    let offered = menu["items"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|entry| entry["id"] == json!(id) && entry["enabled"].as_bool() == Some(true));
    expect!(offered, "the menu is {}", show(&menu["items"]));
    world.dispatch(
        "menu.select",
        json!({"requestId": at(&menu, "requestId"), "id": id}),
    )
}

fn pin(world: &mut World, title: &str, order_key: &str) -> Outcome {
    let key = key_of(world, title)?;
    update_row(world, id_in(&key), |row| {
        row.insert("pinnedAt".into(), json!("2026-09-23T09:30:00Z"));
        row.insert("pinOrderKey".into(), json!(order_key));
    })
}

fn commands_since(world: &mut World) -> Vec<String> {
    let before = scene(world).commands_before;
    world
        .mc
        .commands
        .iter()
        .skip(before)
        .map(|command| text(&command["type"]))
        .collect()
}

fn wait_section(world: &mut World, title: &str, section: &str) -> Outcome {
    let key = key_of(world, title)?;
    world.wait_for_with(
        |w| section_of(w, &key) == section,
        |w| format!("{title} in {section}; it is in \"{}\"", section_of(w, &key)),
    )
}

pub fn register(steps: &mut Steps) {
    // From the menu.
    steps.step(&format!("the user moves {Q} (up|down)"), |world, c, _| {
        pick_from_menu(world, &c[0], &format!("move-{}", c[1]))
    });
    steps.step(
        "the environment does not support reordering active threads",
        |world, _, _| {
            world.mc.capabilities["threadActiveReorder"] = json!(false);
            world.mc.send_snapshot();
            world.sync()
        },
    );
    steps.step(&format!("the user tries to move {Q}"), |world, c, _| {
        if super::files_folder::try_move_managed_folder(world, &c[0])? {
            return Ok(());
        }
        scene(world).commands_before = world.mc.commands.len();
        pick_from_menu(world, &c[0], "move-up")?;
        world.sync()?;
        let sent = commands_since(world);
        expect!(sent.is_empty(), "the MC has {}", world.describe_commands());
        Ok(())
    });

    // Dragging within a section.
    steps.step(
        &format!("the (pinned|active) threads are {Q} then {Q}"),
        |world, c, _| {
            if !world.checking && c[0] == "pinned" {
                // Pinned before arranging existed: neither has a place of its own yet.
                for title in [&c[1], &c[2]] {
                    let key = key_of(world, title)?;
                    update_row(world, id_in(&key), |row| {
                        row.insert("pinnedAt".into(), json!("2026-09-23T09:30:00Z"));
                    })?;
                }
            }
            wait_order(world, &c[0], &c[1], &c[2])
        },
    );
    steps.step(&format!("the user drags {Q} above {Q}"), |world, c, _| {
        let key = key_of(world, &c[1])?;
        let section = section_of(world, &key);
        drop_on(world, &c[0], &section, &c[1])
    });
    steps.step("the order is the same after a restart", |world, _, _| {
        world.sync()?;
        let pinned = titles_of(world, "pinned");
        let active = titles_of(world, "active");
        world.restart()?;
        world.connect()?;
        world.wait_for_with(
            |w| titles_of(w, "pinned") == pinned && titles_of(w, "active") == active,
            |w| {
                format!(
                    "the same order; the list is {} then {}",
                    titles_of(w, "pinned").join(", "),
                    titles_of(w, "active").join(", ")
                )
            },
        )
    });

    // Dragging between sections.
    steps.step(&format!("{Q} is active"), |world, c, _| {
        wait_section(world, &c[0], "active")
    });
    steps.step(
        &format!(
            "the user drags {Q} (into the pinned section|into the active section|onto the settled section header|onto the snoozed section|to the top of the list)"
        ),
        |world, c, _| match c[1].as_str() {
            "into the pinned section" => {
                // Above the thread already pinned there.
                let other = if c[0] == "Alpha" { "Gamma" } else { "Alpha" };
                pin(world, other, "n")?;
                drop_on(world, &c[0], "pinned", other)
            }
            "into the active section" => drop_on(world, &c[0], "active", ""),
            "onto the settled section header" => drop_on(world, &c[0], "settled", ""),
            "onto the snoozed section" => drop_on(world, &c[0], "snoozed", ""),
            _ => drop_on(world, &c[0], "pinned", ""),
        },
    );
    steps.step(
        &format!("{Q} is pinned at the drop position"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    let pinned = titles_of(w, "pinned");
                    pinned.first() == Some(&c[0]) && pinned.len() == 2
                },
                |w| {
                    format!(
                        "{} first among the pinned; they are {}",
                        c[0],
                        titles_of(w, "pinned").join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("{Q} is unpinned without confirmation"),
        |world, c, _| {
            wait_section(world, &c[0], "active")?;
            let sent = commands_since(world);
            expect!(
                !world.state("confirmation").is_object() && sent == ["thread.unpin"],
                "the MC has {}",
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} is (un-settled|woken)"), |world, c, _| {
        wait_section(world, &c[0], "active")?;
        let expected = if c[1] == "woken" {
            "thread.unsnooze"
        } else {
            "thread.unsettle"
        };
        let sent = commands_since(world);
        expect!(
            sent == [expected],
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });
    steps.step(&format!("nothing happens to {Q}"), |world, c, _| {
        world.sync()?;
        let key = key_of(world, &c[0])?;
        let sent = commands_since(world);
        expect!(
            sent.is_empty() && section_of(world, &key) == "active",
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });
    steps.step("no thread is pinned", |world, _, _| {
        world.sync()?;
        let pinned = titles_of(world, "pinned");
        expect!(
            pinned.is_empty(),
            "the pinned threads are {}",
            pinned.join(", ")
        );
        Ok(())
    });

    // The undo shortcut.
    // "the user is typing in the composer" is TerminalSteps': it puts text in
    // the open thread's composer.
    steps.step("the user presses the undo shortcut", |world, _, _| {
        world.sync()?;
        scene(world).commands_before = world.mc.commands.len();
        let Some(shortcut) = keybindings::parse_shortcut("mod+z") else {
            fail!("mod+z is not a shortcut");
        };
        // The keyboard is in the composer while it holds what the user is typing.
        let composer = world.state("composer");
        expect!(
            !text(&composer["text"]).is_empty(),
            "the composer is {}",
            show(&composer)
        );
        let focus = Focus {
            terminal: false,
            composer: true,
            editable: true,
        };
        let engine = world.engine().clone();
        let taken =
            Keymap::of(&engine).press(&engine, &keybindings::sequence(&shortcut, false), focus);
        scene(world).shortcut_taken = taken;
        world.sync()
    });
    steps.step("the text edit is undone", |world, _, _| {
        // The shell leaves the key to the text field, which undoes its own edit.
        expect!(!scene(world).shortcut_taken, "the shell took the shortcut");
        Ok(())
    });
    steps.step(&format!("{Q} stays unpinned"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        let sent = commands_since(world);
        expect!(
            sent.is_empty() && section_of(world, &key) == "active",
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });
}
