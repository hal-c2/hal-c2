//! "/usage-limits" in the composer (the composer's slash command): the
//! desktop's half of features/providers/usage-limits.feature (desktop-qt's
//! UsageLimitsCommandSteps.cpp). The MC offers the command to a client that
//! says it answers it itself, on the providers with limits to show.

use serde_json::{Value, json};

use hal_c2_shell::controllers::settings::Settings;

use super::settings::{publish_providers, publish_sources};
use super::stream::{PROJECT, THREAD, look_at_thread};
use crate::brick::{Brick, Shown, shown};
use crate::expect;
use crate::harness::{Outcome, Q, Steps, show};
use crate::world::World;

fn model(slug: &str) -> Value {
    json!({"slug": slug, "name": slug})
}

fn stamp(at: chrono::DateTime<chrono::Utc>) -> String {
    at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

/// A subscription's 5-hour window, `used` percent spent.
fn limits(world: &World, used: f64) -> Value {
    let now = world.now();
    json!({
        "checkedAt": stamp(now),
        "windows": [{
            "id": "five-hour",
            "kind": "session",
            "label": "5-hour",
            "usedPercent": used,
            "resetsAt": stamp(now + chrono::Duration::seconds(3600)),
            "windowDurationMins": 300,
        }],
    })
}

fn entry(id: &str, driver: &str, name: &str, slug: &str) -> Value {
    json!({
        "instanceId": id, "driver": driver, "displayName": name,
        "enabled": true, "installed": true, "status": "ready",
        "models": [model(slug)],
    })
}

fn antigravity() -> Value {
    entry("antigravity", "antigravity", "Antigravity", "gemini-pro")
}

/// A Codex instance offering the command, with `limits` when there are
/// any.
fn codex(id: &str, name: &str, limits: Option<Value>) -> Value {
    let mut codex = entry(id, "codex", name, "gpt-5");
    if let Some(limits) = limits {
        codex["usageLimits"] = limits;
    }
    codex["slashCommands"] = json!([{
        "name": "usage-limits",
        "description": "Show this provider's usage limits",
    }]);
    codex
}

/// Codex with a subscription's windows and the command; Antigravity with
/// neither.
fn providers(world: &World) -> Vec<Value> {
    vec![
        codex("codex", "Codex", Some(limits(world, 40.0))),
        antigravity(),
    ]
}

/// A hub's Codex accounts, by id.
fn hub(world: &World, accounts: &[&str]) -> Vec<Value> {
    let listed: Vec<Value> = accounts
        .iter()
        .map(|id| json!({"id": id, "driver": "codex", "usageLimits": limits(world, 50.0)}))
        .collect();
    vec![json!({
        "id": "team-hub",
        "kind": "cliproxy",
        "label": "Team hub",
        "checkedAt": stamp(world.now()),
        "accounts": listed,
    })]
}

fn composer(world: &World) -> Value {
    world.state("composer")
}

fn open_thread_on(world: &mut World, instance_id: &str, slug: &str) -> Outcome {
    open_thread_with(world, instance_id, slug, Vec::new(), Vec::new())
}

/// The thread on `instance_id`, with the environment's `catalogue` of
/// providers (the default one when empty) and its hubs.
fn open_thread_with(
    world: &mut World,
    instance_id: &str,
    slug: &str,
    catalogue: Vec<Value>,
    sources: Vec<Value>,
) -> Outcome {
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
    let all = if catalogue.is_empty() {
        providers(world)
    } else {
        catalogue
    };
    publish_providers(&mut world.mc, all);
    if !sources.is_empty() {
        publish_sources(&mut world.mc, sources);
        world.wait_for("the hubs to be read", |w| {
            Settings::of(w.engine())
                .config()
                .contains_key("usageLimitSources")
        })?;
    }
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

/// The answer as drawn above the composer.
fn answer(world: &mut World) -> Outcome<Brick> {
    if let Some(brick) = world.part::<Shown>().0 {
        return Ok(brick);
    }
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nComposerUsageLimits { width: 600 }\n",
        600.0,
        300.0,
    )?;
    world.part::<Shown>().0 = Some(brick);
    world.sync()?;
    Ok(brick)
}

fn open_answer(world: &mut World) -> Outcome {
    send(world, "/usage-limits")?;
    world.wait_for_with(
        |w| !composer(w)["usageLimits"].is_null(),
        |w| format!("the answer; the composer shows {}", show(&composer(w))),
    )
}

/// The account's label as drawn, scrambled or not.
fn account_text(world: &mut World) -> Outcome<String> {
    let brick = answer(world)?;
    let account = brick.item(world, "composerUsageLimitsAccount")?;
    Ok(brick.text_of(world, account, "text"))
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
            let account = limits["accounts"][0].clone();
            let window = account["windows"][0].clone();
            expect!(
                account["label"] == json!("Codex")
                    && window["label"] == json!("5-hour")
                    && window["remainingPercent"].as_f64() == Some(60.0),
                "the composer shows {}",
                show(&limits)
            );
            let brick = answer(world)?;
            expect!(
                brick.shows(world, "Usage limits")?
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
    // Whose limits the answer shows.
    steps.step(
        "a Codex thread whose limits come from (.+)",
        |world, c, _| {
            let accounts = c[0].as_str();
            if accounts.contains("plan") {
                let plan = accounts.split('"').nth(1).unwrap_or_default();
                let mut one = codex("codex", "Codex", Some(limits(world, 40.0)));
                one["auth"] = json!({"status": "authenticated", "label": plan});
                open_thread_with(
                    world,
                    "codex",
                    "gpt-5",
                    vec![one, antigravity()],
                    Vec::new(),
                )
            } else if accounts.contains("named") {
                let name = accounts.split('"').nth(1).unwrap_or_default();
                // The default instance reports no limits of its own.
                let catalogue = vec![
                    codex("codex", "Codex", None),
                    codex("codex_work", name, Some(limits(world, 40.0))),
                    antigravity(),
                ];
                open_thread_with(world, "codex_work", "gpt-5", catalogue, Vec::new())
            } else {
                let sources = hub(world, &["ops.json", "build.json", "review.json"]);
                let catalogue = vec![codex("codex", "Codex", None), antigravity()];
                open_thread_with(world, "codex", "gpt-5", catalogue, sources)
            }
        },
    );
    steps.step(
        &format!("the answer is headed {Q} and says {Q}"),
        |world, c, _| {
            let brick = answer(world)?;
            expect!(
                brick.shows(world, &c[0])? && brick.shows(world, &c[1])?,
                "the answer is {}",
                show(&composer(world)["usageLimits"])
            );
            expect!(
                !dispatched(world),
                "the command went to the agent: {}",
                world.describe_commands()
            );
            Ok(())
        },
    );
    // An account named by its email.
    steps.step(&format!("a hub account is labelled {Q}"), |world, c, _| {
        let sources = hub(world, &[c[0].as_str()]);
        open_thread_with(
            world,
            "codex",
            "gpt-5",
            vec![codex("codex", "Codex", None)],
            sources,
        )
    });
    steps.step(&format!("the answer does not show {Q}"), |world, c, _| {
        world.wait_for("the answer", |w| !composer(w)["usageLimits"].is_null())?;
        let brick = answer(world)?;
        let account = brick.item(world, "composerUsageLimitsAccount")?;
        let drawn = brick.text_of(world, account, "text");
        expect!(
            brick.flag(world, account, "visible") && !drawn.contains(c[0].as_str()),
            "the answer shows {} as \"{drawn}\"",
            c[0]
        );
        // Only the account is hidden; the hub it came through is still named.
        expect!(
            brick.shows(world, "Team hub · ")?,
            "the hub's name is hidden too"
        );
        Ok(())
    });
    steps.step("the user chooses to reveal the account", |world, _, _| {
        answer(world)?.click(world, "composerUsageLimitsAccount")
    });
    steps.step(&format!("the answer shows {Q}"), |world, c, _| {
        let drawn = account_text(world)?;
        expect!(
            drawn.contains(c[0].as_str()),
            "the account reads \"{drawn}\""
        );
        Ok(())
    });
    steps.step("the user can hide it again", |world, _, _| {
        answer(world)?.click(world, "composerUsageLimitsAccount")?;
        let drawn = account_text(world)?;
        expect!(
            !drawn.contains("@example.com"),
            "the account stayed revealed"
        );
        Ok(())
    });
    // Dismissed.
    steps.step(
        &format!("the answer to {Q} is shown above the composer"),
        |world, _, _| {
            open_thread_on(world, "codex", "gpt-5")?;
            open_answer(world)?;
            let brick = answer(world)?;
            expect!(
                brick.shows(world, "Usage limits")?,
                "the answer is not drawn"
            );
            Ok(())
        },
    );
    steps.step("the user dismisses the usage limits", |world, _, _| {
        answer(world)?.click(world, "composerUsageLimitsDismiss")
    });
    steps.step("the answer is gone", |world, _, _| {
        let brick = answer(world)?;
        world.sync()?;
        expect!(
            composer(world)["usageLimits"].is_null() && !brick.shows(world, "Usage limits")?,
            "the answer stayed: {}",
            show(&composer(world)["usageLimits"])
        );
        Ok(())
    });
    steps.step("nothing was sent to the agent", |world, _, _| {
        world.sync()?;
        expect!(
            !dispatched(world),
            "the MC was sent {}",
            world.describe_commands()
        );
        Ok(())
    });
}
