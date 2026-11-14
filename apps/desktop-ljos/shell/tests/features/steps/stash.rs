//! The prompt stash (ComposerController): stashing the route thread's draft,
//! bringing it back, deleting it, and the stash's cap, as the composer brick
//! dispatches them (features/composer/editors-and-keys.feature).
//! desktop-qt's StashSteps.cpp.

use hal_c2_shell::controllers::composer;
use hal_c2_shell::controllers::navigation::Navigation;
use serde_json::{Value, json};

use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::composer_brick;
use crate::world::World;
use crate::{expect, fail};

/// Whether the scenario has touched the stash yet: until then "the draft
/// reads" sets the draft up, afterwards it checks it.
#[derive(Default)]
struct StashState {
    acted: bool,
    /// The text last stashed.
    stashed: String,
}

fn target(world: &World) -> Outcome<String> {
    world.with::<Navigation, _>(|n, _| n.thread_key().to_owned())
}

fn draft(world: &World) -> String {
    target(world).map_or_else(
        |_| String::new(),
        |target| composer::draft(world.engine(), &target),
    )
}

fn type_text(world: &mut World, typed: &str) -> Outcome {
    let target = target(world)?;
    world.dispatch(
        "composer.text.set",
        json!({"target": target, "text": typed, "cursor": typed.chars().count()}),
    )
}

fn entries(world: &World) -> Vec<Value> {
    world.state("composerStash")["entries"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn stash(world: &mut World) -> Outcome {
    world.part::<StashState>().acted = true;
    world.dispatch("composer.stash", Value::Null)?;
    world.sync()
}

fn stash_text(world: &mut World, typed: &str) -> Outcome {
    type_text(world, typed)?;
    stash(world)?;
    world.part::<StashState>().stashed = typed.to_owned();
    Ok(())
}

fn newest(world: &World) -> Outcome<String> {
    match entries(world).first() {
        Some(entry) => Ok(text(&entry["id"])),
        None => fail!("nothing is stashed"),
    }
}

fn expect_draft(world: &mut World, expected: &str) -> Outcome {
    world.wait_for_with(
        |w| draft(w) == expected,
        |w| format!("the draft reads \"{}\"", draft(w)),
    )
}

pub fn register(steps: &mut Steps) {
    steps.step(&format!("the draft reads {Q}"), |world, c, _| {
        if world.part::<StashState>().acted || world.checking {
            expect_draft(world, &c[0])
        } else {
            type_text(world, &c[0])?;
            world.sync()
        }
    });
    steps.step(
        &format!("the draft reads {Q} and then {Q}"),
        |world, c, _| expect_draft(world, &format!("{}\n\n{}", c[0], c[1])),
    );
    steps.step(&format!("the user stashed {Q}"), |world, c, _| {
        stash_text(world, &c[0])
    });
    steps.step(&format!("the user stashes {Q}"), |world, c, _| {
        stash_text(world, &c[0])
    });
    steps.step("the user stashed (\\d+) prompts", |world, c, _| {
        for n in 1..=c[0].parse::<i32>().unwrap_or(0) {
            stash_text(world, &format!("prompt {n}"))?;
        }
        Ok(())
    });
    steps.step("the user stashes the prompt(?: again)?", |world, _, _| {
        stash(world)
    });
    steps.step("the user restores the stashed prompt", |world, _, _| {
        let id = newest(world)?;
        world.dispatch("composer.stash.restore", json!({"id": id}))?;
        world.sync()
    });
    steps.step("the user deletes the stashed prompt", |world, _, _| {
        let id = newest(world)?;
        world.dispatch("composer.stash.delete", json!({"id": id}))?;
        world.sync()
    });
    steps.step("nothing is stashed", |world, _, _| {
        let list = entries(world);
        expect!(
            list.is_empty(),
            "the stash holds {}",
            show(&Value::Array(list))
        );
        Ok(())
    });
    steps.step(
        &format!("(\\d+) prompts are stashed, {Q} first"),
        |world, c, _| {
            let list = entries(world);
            expect!(
                list.len() == c[0].parse::<usize>().unwrap_or(0)
                    && list.first().is_some_and(|e| e["snippet"] == c[1]),
                "the stash holds {}",
                show(&Value::Array(list))
            );
            Ok(())
        },
    );
    steps.step("the composer is still empty", |world, _, _| {
        expect_draft(world, "")
    });
    steps.step(&format!("the user stashed {Q} and {Q}"), |world, c, _| {
        stash_text(world, &c[0])?;
        stash_text(world, &c[1])
    });
    steps.step(
        "the user stashed a prompt of (\\d+) characters",
        |world, c, _| {
            let count: usize = c[0].parse().unwrap_or(0);
            let typed: String = (0..count)
                .map(|i| (b'a' + (i % 26) as u8) as char)
                .collect();
            stash_text(world, &typed)
        },
    );
    steps.step(
        "the user stashes the prompt and the stash cannot be written",
        |world, _, _| {
            // A folder where the stash's file goes: nothing can be written there.
            let path = world.home_dir().join("data/shell-composer.json");
            let aside = path.with_extension("json.aside");
            let had = path.exists();
            let moved = !had || std::fs::rename(&path, &aside).is_ok();
            expect!(moved, "could not move {} aside", path.display());
            let made = std::fs::create_dir_all(&path).is_ok();
            expect!(made, "could not make {}", path.display());
            let stashed = stash(world);
            let back = std::fs::remove_dir_all(&path).is_ok()
                && (!had || std::fs::rename(&aside, &path).is_ok());
            expect!(back, "could not put {} back", path.display());
            stashed
        },
    );
    steps.step("the user opens the stash", |world, _, _| {
        world.dispatch("composer.stash.menu", json!({"open": true}))?;
        world.sync()
    });
    steps.step(
        &format!("the stash lists {Q} and then {Q}"),
        |world, c, _| {
            let list = entries(world);
            let snippet = |i: usize| list.get(i).map_or(String::new(), |e| text(&e["snippet"]));
            expect!(
                world.state("composerStash")["open"] == json!(true)
                    && list.len() == 2
                    && snippet(0) == c[0]
                    && snippet(1) == c[1],
                "the stash is {}",
                show(&world.state("composerStash"))
            );
            Ok(())
        },
    );
    // A listed text in quotes may hold quotes of its own.
    steps.step("the prompt is listed as \"(.*)\"", |world, c, _| {
        let expected = if c[0] == "its first 90 characters and \"…\"" {
            let stashed = world.part::<StashState>().stashed.clone();
            format!("{}…", stashed.chars().take(90).collect::<String>())
        } else {
            c[0].clone()
        };
        let listed = entries(world)
            .first()
            .map_or(String::new(), |e| text(&e["snippet"]));
        expect!(listed == expected, "the stash lists \"{listed}\"");
        Ok(())
    });
    steps.step(
        "the prompt says how long ago it was stashed",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let age = brick.find(world, "stashAge-0")?;
            expect!(
                age.is_some_and(|age| brick.flag(world, age, "visible")),
                "the stash shows no age for its prompt"
            );
            let said = age.map_or(String::new(), |age| brick.text_of(world, age, "text"));
            expect!(said == "just now", "the prompt was stashed \"{said}\"");
            Ok(())
        },
    );
}
