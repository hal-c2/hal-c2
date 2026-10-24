//! The prompt stash (ComposerController): stashing the route thread's draft,
//! bringing it back, deleting it, and the stash's cap, as the composer brick
//! dispatches them (features/composer/editors-and-keys.feature).
//! desktop-qt's StashSteps.cpp.

use hal_c2_shell::controllers::composer;
use hal_c2_shell::controllers::navigation::Navigation;
use serde_json::{Value, json};

use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

/// Whether the scenario has touched the stash yet: until then "the draft
/// reads" sets the draft up, afterwards it checks it.
#[derive(Default)]
struct StashState {
    acted: bool,
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
    stash(world)
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
}
