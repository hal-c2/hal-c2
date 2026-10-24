//! "/usage-limits" in the composer (the composer's slash command): the
//! desktop's half of features/providers/usage-limits.feature (desktop-qt's
//! UsageLimitsCommandSteps.cpp). The MC offers the command to a client that
//! says it answers it itself, on the providers with limits to show.

use serde_json::{Value, json};

use super::settings::publish_providers;
use super::stream::{PROJECT, THREAD, look_at_thread};
use crate::brick::{Brick, Shown, shown};
use crate::expect;
use crate::harness::{Outcome, Steps, show};
use crate::world::World;

fn model(slug: &str) -> Value {
    json!({"slug": slug, "name": slug})
}

/// Codex with a subscription's windows and the command; Antigravity with
/// neither.
fn providers(world: &World) -> Vec<Value> {
    let now = world.now();
    let limits = json!({
        "checkedAt": now.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        "windows": [{
            "id": "five-hour",
            "kind": "session",
            "label": "5-hour",
            "usedPercent": 40,
            "resetsAt": (now + chrono::Duration::seconds(3600))
                .to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            "windowDurationMins": 300,
        }],
    });
    let entry = |id: &str, name: &str, slug: &str| {
        json!({
            "instanceId": id, "driver": id, "displayName": name,
            "enabled": true, "installed": true, "status": "ready",
            "models": [model(slug)],
        })
    };
    let mut codex = entry("codex", "Codex", "gpt-5");
    codex["usageLimits"] = limits;
    codex["slashCommands"] = json!([{
        "name": "usage-limits",
        "description": "Show this provider's usage limits",
    }]);
    vec![codex, entry("antigravity", "Antigravity", "gemini-pro")]
}

fn composer(world: &World) -> Value {
    world.state("composer")
}

fn open_thread_on(world: &mut World, instance_id: &str, slug: &str) -> Outcome {
    if world.shell_subscriptions() == 0 {
        world.connect()?;
        world.sync()?;
    }
    let project = json!({
        "id": PROJECT, "title": PROJECT,
        "workspaceRoot": "/work/shop", "scripts": [],
    });
    world.mc.projects.insert(PROJECT.into(), project.clone());
    world.mc.send_row_of(PROJECT, &project, "project");
    let all = providers(world);
    publish_providers(&mut world.mc, all);
    look_at_thread(world, PROJECT)?;
    let row = world
        .mc
        .threads
        .get_mut(THREAD)
        .ok_or_else(|| crate::harness::Failure(format!("the MC has no thread {THREAD}")))?;
    row["modelSelection"] = json!({"instanceId": instance_id, "model": slug});
    let row = row.clone();
    world.mc.send_row(THREAD, &row);
    world.wait_for_with(
        |w| composer(w)["selectedModel"] == json!(slug),
        |w| format!("the composer on {slug}; it shows {}", show(&composer(w))),
    )?;
    // The client told the environment it answers the command itself.
    let told = world.mc.subscriptions.iter().any(|sub| {
        let shape = &sub["shape"];
        shape["type"] == json!("config") && shape["usageLimitsCommand"] == json!(true)
    });
    expect!(
        told,
        "no config subscription said the client answers /usage-limits"
    );
    Ok(())
}

fn send(world: &mut World, text: &str) -> Outcome {
    world.dispatch(
        "composer.submit",
        json!({"text": text, "intent": "foreground"}),
    )
}

fn dispatched(world: &World) -> bool {
    world
        .mc
        .commands
        .iter()
        .any(|command| command["type"] == json!("message.dispatch"))
}

/// The composer's command menu, when open, does not offer `command` (and
/// sent anyway it is an ordinary message to the agent): for the steps of
/// other files that check a command by name (ThemeSteps).
pub fn expect_command_not_offered(world: &mut World, command: &str) -> Outcome {
    let composer_state = composer(world);
    let suggestions = composer_state["suggestions"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    if suggestions.is_empty() || !command.starts_with('/') {
        return Ok(());
    }
    let offered: Vec<String> = suggestions
        .iter()
        .map(|item| crate::harness::text(&item["label"]))
        .collect();
    expect!(
        offered.iter().any(|label| label == "/model")
            && !offered.iter().any(|label| label == command),
        "the menu offers {}",
        offered.join(", ")
    );
    // Sent anyway, it is an ordinary message to the agent.
    send(world, command)?;
    world.wait_for("the message to be sent", dispatched)?;
    expect!(
        composer(world)["usageLimits"].is_null(),
        "limits were shown"
    );
    Ok(())
}

pub fn register(steps: &mut Steps) {
    steps.step("a Codex thread", |world, _, _| {
        open_thread_on(world, "codex", "gpt-5")
    });
    steps.step("an Antigravity thread", |world, _, _| {
        open_thread_on(world, "antigravity", "gemini-pro")
    });
    steps.step(
        "Codex's windows are shown above the composer without running the agent",
        |world, _, _| {
            let limits = composer(world)["usageLimits"].clone();
            let window = limits["windows"][0].clone();
            expect!(
                limits["provider"] == json!("Codex")
                    && window["label"] == json!("5-hour")
                    && window["remainingPercent"].as_f64() == Some(60.0),
                "the composer shows {}",
                show(&limits)
            );
            let brick = Brick::new(
                world,
                "import QtQuick\nimport HalC2.Bricks\nComposerUsageLimits { width: 600 }\n",
                600.0,
                200.0,
            )?;
            world.part::<Shown>().0 = Some(brick);
            expect!(
                brick.shows(world, "Codex limits")?
                    && brick.shows(world, "5-hour")?
                    && brick.shows(world, "60% left")?,
                "the limits are not drawn"
            );
            world.sync()?;
            expect!(
                !dispatched(world) && crate::harness::text(&composer(world)["text"]).is_empty(),
                "the command went to the agent: {}",
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step(
        "they close when the user sends the next message",
        |world, _, _| {
            send(world, "Add a tax line")?;
            world.wait_for_with(dispatched, |w| {
                format!("the message; the MC has {}", w.describe_commands())
            })?;
            expect!(
                composer(world)["usageLimits"].is_null(),
                "the limits stayed open"
            );
            // Asked for again, they also close when dismissed.
            send(world, "/usage-limits")?;
            expect!(
                !composer(world)["usageLimits"].is_null(),
                "the limits did not open again"
            );
            shown(world)?.click(world, "composerUsageLimitsDismiss")?;
            expect!(
                composer(world)["usageLimits"].is_null(),
                "the limits stayed open"
            );
            Ok(())
        },
    );
    steps.step(
        "the user opens the composer's command menu",
        |world, _, _| {
            let target = format!("{}:{THREAD}", world.mc.environment_id);
            world.dispatch(
                "composer.text.set",
                json!({"target": target, "text": "/", "cursor": 1}),
            )?;
            world.wait_for_with(
                |w| {
                    composer(w)["suggestions"]
                        .as_array()
                        .is_some_and(|s| !s.is_empty())
                },
                |w| {
                    format!(
                        "the command menu; the composer shows {}",
                        show(&composer(w))
                    )
                },
            )
        },
    );
}
