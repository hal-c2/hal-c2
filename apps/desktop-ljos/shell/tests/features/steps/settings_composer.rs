//! What General's composer rows change in the composer on screen
//! (qml/HalC2/Bricks/Composer.qml, features/settings/general.feature): skills
//! in the slash menu, Markdown drawn as it reads, and resting on scroll.
//! desktop-qt's SettingsComposerSteps.cpp.

use hal_c2_shell::controllers::settings::Settings;
use ljos::prelude::{ObjectId, Value as QmlValue};
use ljos::testing::highlights;
use serde_json::{Value, json};

use crate::brick::Brick;
use crate::harness::{Failure, Outcome, Steps, at, show, text};
use crate::steps::composer_brick::{composer_brick, composer_item, editor, settle_composer, type_in_composer};
use crate::steps::settings::publish_providers;
use crate::steps::turn::open_turn_thread;
use crate::world::World;
use crate::expect;

fn composer(world: &World) -> Value {
    world.state("composer")
}

/// A provider with one skill, and a thread to write in.
fn open_thread_with_skill(world: &mut World) -> Outcome {
    publish_providers(
        &mut world.mc,
        vec![json!({
            "instanceId": "claudeAgent", "driver": "claudeAgent",
            "displayName": "Claude", "enabled": true, "installed": true,
            "status": "ready",
            "models": [{"slug": "sonnet", "name": "Sonnet"}],
            "skills": [{"name": "review", "description": "Review the changes", "enabled": true}],
        })],
    );
    open_turn_thread(world)?;
    composer_brick(world)?;
    Ok(())
}

/// What the menu lists after the user types `typed`.
fn listed_after(world: &mut World, typed: &str) -> Outcome<Vec<String>> {
    let (_, input) = editor(world)?;
    world
        .engine()
        .invoke_by_name(input, "clear", &[])
        .map_err(|e| Failure(format!("clear: {e:?}")))?;
    settle_composer(world)?;
    type_in_composer(world, typed)?;
    settle_composer(world)?;
    Ok(at(&composer(world), "suggestions")
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .filter(|item| item["kind"] == "skill")
        .map(|item| text(&item["label"]))
        .collect())
}

/// Whether the editor `input` draws the characters of `word` in bold.
pub fn drawn_bold(world: &World, brick: Brick, input: ObjectId, word: &str) -> bool {
    let editor_text = brick.text_of(world, input, "text");
    let Some(start) = editor_text.find(word) else {
        return false;
    };
    let wanted = start..start + word.len();
    let bold: usize = highlights(world.engine(), input)
        .iter()
        .filter(|span| span.weight.is_some_and(|w| w >= 700))
        .map(|span| {
            let from = span.range.start.max(wanted.start);
            let to = span.range.end.min(wanted.end);
            to.saturating_sub(from)
        })
        .sum();
    bold == word.len()
}

/// The composer's height once the user scrolls the conversation of its
/// thread, with the keyboard elsewhere.
struct Heights {
    before: f64,
    scrolled: f64,
}

fn height_of(world: &mut World, brick: Brick, item: ObjectId) -> f64 {
    brick
        .read(world, item, "implicitHeight")
        .as_number()
        .unwrap_or(0.0)
}

fn scroll_conversation(world: &mut World) -> Outcome<Heights> {
    open_turn_thread(world)?;
    composer_brick(world)?;
    let item = composer_item(world)?;
    let (brick, _) = editor(world)?;
    settle_composer(world)?;
    world.pump()?;
    let before = height_of(world, brick, item);
    // The layout tells the composer (DefaultShell: CentreHost.conversationScrolled).
    brick.write(world, item, "conversationScrolled", QmlValue::Bool(true))?;
    world.pump()?;
    let scrolled = height_of(world, brick, item);
    Ok(Heights { before, scrolled })
}

fn key_of(row: &str) -> &'static str {
    match row {
        "Show skills in slash menu" => "showSkillsInSlashMenu",
        "Rich text composer" => "composerRichTextEnabled",
        _ => "composerCollapseOnScroll",
    }
}

fn setting(world: &World, key: &str) -> Value {
    Settings::of(world.engine())
        .setting(world.engine(), key)
        .unwrap_or(Value::Null)
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the user turns \"(Show skills in slash menu|Rich text composer|Collapse composer on scroll)\" (on|off)",
        |world, c, _| {
            // What the General page's switch does (SettingsRow); the composer is
            // what is on screen here.
            let key = key_of(&c[0]);
            let on = c[1] == "on";
            let engine = world.engine().clone();
            // From the other state, so the row is what makes the difference.
            Settings::of(&engine).set(&engine, key, json!(!on));
            Settings::of(&engine).set(&engine, key, json!(on));
            world.pump()?;
            let now = setting(world, key);
            expect!(now == json!(on), "{key} is {}", show(&now));
            Ok(())
        },
    );

    steps.step(
        "skills are listed in the slash command menu as well as after a dollar sign",
        |world, _, _| {
            open_thread_with_skill(world)?;
            let slash = listed_after(world, "/")?;
            let dollar = listed_after(world, "$")?;
            expect!(
                slash.len() == 1
                    && slash[0].to_lowercase().contains("review")
                    && dollar.len() == 1,
                "/ lists {}, $ lists {}",
                slash.join(", "),
                dollar.join(", ")
            );
            Ok(())
        },
    );
    steps.step("skills are only listed after a dollar sign", |world, _, _| {
        open_thread_with_skill(world)?;
        let slash = listed_after(world, "/")?;
        let dollar = listed_after(world, "$")?;
        expect!(
            slash.is_empty() && dollar.len() == 1,
            "/ lists {}, $ lists {}",
            slash.join(", "),
            dollar.join(", ")
        );
        Ok(())
    });

    steps.step("Markdown is shown formatted while typing", |world, _, _| {
        open_turn_thread(world)?;
        composer_brick(world)?;
        type_in_composer(world, "**careful**")?;
        settle_composer(world)?;
        let (brick, input) = editor(world)?;
        world.wait_for("\"careful\" to be drawn bold", move |w| {
            drawn_bold(w, brick, input, "careful")
        })
    });
    steps.step("the composer shows plain text", |world, _, _| {
        open_turn_thread(world)?;
        composer_brick(world)?;
        type_in_composer(world, "**careful**")?;
        settle_composer(world)?;
        world.pump()?;
        let (brick, input) = editor(world)?;
        let shown = brick.text_of(world, input, "text");
        expect!(
            !drawn_bold(world, brick, input, "careful") && shown == "**careful**",
            "the editor reads \"{shown}\""
        );
        Ok(())
    });

    steps.step(
        "the composer of an existing thread shrinks to one line while scrolling",
        |world, _, _| {
            let heights = scroll_conversation(world)?;
            let item = composer_item(world)?;
            let (brick, _) = editor(world)?;
            expect!(
                brick.flag(world, item, "resting") && heights.scrolled < heights.before - 20.0,
                "the composer is {} tall, {} before scrolling",
                heights.scrolled,
                heights.before
            );
            // Typing brings it back.
            type_in_composer(world, "a")?;
            world.pump()?;
            let back = height_of(world, brick, item);
            expect!(
                !brick.flag(world, item, "resting") && back >= heights.before,
                "typing did not bring the composer back"
            );
            Ok(())
        },
    );
    steps.step("the composer keeps its size while scrolling", |world, _, _| {
        let heights = scroll_conversation(world)?;
        let item = composer_item(world)?;
        let (brick, _) = editor(world)?;
        expect!(
            !brick.flag(world, item, "resting") && heights.scrolled == heights.before,
            "the composer is {} tall, {} before scrolling",
            heights.scrolled,
            heights.before
        );
        Ok(())
    });
}
