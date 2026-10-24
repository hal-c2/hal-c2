//! Resetting the keymap (features/plugins/keymaps.feature): Settings →
//! Keybindings takes every rule of the user's away at once, leaving the
//! built-in bindings (desktop-qt's KeymapSteps.cpp).

use hal_c2_shell::controllers::keybindings::Keymap;
use hal_c2_shell::keybindings;
use serde_json::{Value, json};

use crate::brick::Brick;
use crate::expect;
use crate::harness::{Steps, at, show, text};
use crate::world::World;

fn keymap(world: &World) -> Keymap {
    Keymap::of(world.engine())
}

fn stored_rules(world: &World) -> usize {
    world
        .mc
        .peek::<crate::steps::settings::FakeConfig>()
        .and_then(|fake| fake.config.get("keybindingRules").cloned())
        .and_then(|rules| rules.as_array().map(Vec::len))
        .unwrap_or(0)
}

/// The built-in keys of `command`, as keybindings.json spells them.
fn built_in_keys(command: &str) -> Vec<String> {
    keybindings::defaults()
        .iter()
        .filter(|rule| rule.command == command)
        .map(|rule| rule.key.clone())
        .collect()
}

fn describe_counts(world: &World) -> String {
    format!(
        "the shell has {}, the MC {}",
        keymap(world).custom_count(),
        stored_rules(world)
    )
}

pub fn register(steps: &mut Steps) {
    // The terminal client's names for them are "palette.open" and
    // "thread.new"; on the desktop the palette is commandPalette.toggle and
    // a new thread chat.new, both on the platform's primary modifier.
    steps.step(
        "the built-in keymap binds \"ctrl\\+k\" to \"palette.open\" and \"ctrl\\+n\" to \"thread.new\"",
        |_, _, _| {
            let palette = built_in_keys("commandPalette.toggle");
            expect!(
                palette.iter().any(|key| key == "mod+k"),
                "the palette is on {}",
                palette.join(", ")
            );
            let new_thread = built_in_keys("chat.new");
            expect!(
                new_thread.iter().any(|key| key == "mod+n"),
                "a new thread is on {}",
                new_thread.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        "the user has several keybinding overrides",
        |world, _, _| {
            world.connect()?;
            world.wait_for("the shell to start", |w| w.active())?;
            world.sync()?;
            for (command, key) in [
                ("chat.new", "mod+alt+n"),
                ("diff.toggle", "mod+alt+d"),
                ("commandPalette.toggle", "mod+alt+k"),
            ] {
                let engine = world.engine().clone();
                keymap(world).save(&engine, command, key, "", None);
                world.wait_for("the keybinding to be saved", |w| !keymap(w).saving())?;
                world.sync()?;
            }
            world.wait_for_with(
                |w| keymap(w).custom_count() == 3 && stored_rules(w) == 3,
                |w| format!("three overrides; {}", describe_counts(w)),
            )
        },
    );
    steps.step("the user resets keybindings to the defaults", |world, _, _| {
        let page = Brick::new(
            world,
            "import QtQuick\nimport HalC2.Bricks\nKeybindingsSettings { anchors.fill: parent }\n",
            900.0,
            700.0,
        )?;
        page.click(world, "keybindingResetAll")?;
        // It asks first, saying how many go.
        let question = world.state("confirmation");
        expect!(
            text(at(&question, "title")) == "Reset every keybinding to its default?"
                && text(at(&question, "description")) == "This removes your 3 custom keybindings.",
            "the shell asks {}",
            show(&question)
        );
        expect!(stored_rules(world) == 3, "rules went before the answer");
        let request: Value = at(&question, "requestId").clone();
        world.dispatch(
            "confirmation.answer",
            json!({"requestId": request, "accepted": true}),
        )?;
        world.wait_for("the reset to finish", |w| !keymap(w).saving())?;
        world.sync()
    });
    steps.step("only the built-in bindings apply", |world, _, _| {
        world.wait_for_with(
            |w| stored_rules(w) == 0 && keymap(w).custom_count() == 0,
            |w| format!("no overrides; {}", describe_counts(w)),
        )?;
        let keymap = keymap(world);
        for row in keymap.rows() {
            expect!(
                text(&row["source"]) != "Custom",
                "a custom binding is left: {}",
                show(&row)
            );
        }
        let (bound, built_in) = (keymap.bindings().len(), keybindings::defaults().len());
        expect!(bound == built_in, "{bound} bindings, {built_in} built in");
        for command in ["chat.new", "diff.toggle", "commandPalette.toggle"] {
            let labels: Vec<String> = built_in_keys(command)
                .iter()
                .map(|key| keymap.key_label(key))
                .collect();
            let label = keymap.shortcut_label(world.engine(), command);
            expect!(labels.contains(&label), "{command} is on {label}");
        }
        Ok(())
    });
}
