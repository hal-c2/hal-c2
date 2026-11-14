//! TokenEconomizer's page (features/plugins/token-economizer-*.feature): its
//! real package from plugins/token-economizer, drawn by the desktop against a
//! fake of its MC part that publishes `loopGuard`, `toolPrune`,
//! `microSkills:<project>` and `microSkillsProjects` as the MC part does and
//! answers the calls the page makes: desktop-qt's TokenEconomizerSteps.cpp.

use std::rc::Rc;

use ljos::prelude::ObjectId;
use serde_json::{Map, Value as Json, json};

use super::mc_plugin::{
    FakePluginPart, entry_of, fake_plugin_part, manifest, named, package, publish_topic,
    run_fake_plugin, shown_named, switch_to_tab,
};
use super::plugin::{click_item, shell};
use crate::brick::Brick;
use crate::expect;
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;

const ID: &str = "token-economizer";
const PROJECT: &str = "p1";
const FACT: &str = "pytest-as-module";
const THREAD: &str = "t-partial";
const HELD: &str = "Its saved file is not valid JSON.";
const FILE: &str = "/data/plugins/token-economizer/micro-skills/0f3a.json";
const KEY: &str = "p1:claudeAgent";

/// The MC part's state: the project's micro-skills entry and its tool evidence.
#[derive(Default)]
struct FakeTokenEconomizer {
    skills: Json,
    /// The entry its saved file reads as once repaired, read on the next call
    /// by name.
    repaired: Json,
    /// The fact, as listed while it is not dropped.
    fact: Json,
    prune: Json,
    /// Evidence saved but not loaded since the MC started: only a call naming
    /// the project loads it.
    saved: Json,
    /// Whether a new conversation in the project is told the fact.
    staged: bool,
}

fn state(mc: &mut FakeMc) -> &mut FakeTokenEconomizer {
    mc.part::<FakeTokenEconomizer>()
}

fn is_empty(value: &Json) -> bool {
    value.as_object().is_none_or(Map::is_empty)
}

fn listed(value: &Json) -> Json {
    if is_empty(value) {
        json!([])
    } else {
        json!([value])
    }
}

fn loop_guard() -> Json {
    json!({"mode": "nudge", "watching": 0, "turns": 12, "nudges": 1, "aborts": 0, "recent": []})
}

fn tool_prune(mc: &mut FakeMc) -> Json {
    json!({"mode": "propose", "unreadable": [], "projects": listed(&state(mc).prune)})
}

fn micro_skills(mc: &mut FakeMc) -> Json {
    json!({"mode": "envfacts", "projects": listed(&state(mc).skills)})
}

fn publish(mc: &mut FakeMc) -> Outcome {
    let prune = tool_prune(mc);
    let skills = state(mc).skills.clone();
    let topic = format!("microSkills:{PROJECT}");
    {
        let part = fake_plugin_part(mc, ID)?;
        part.topics.insert("loopGuard".into(), loop_guard());
        part.topics.insert("toolPrune".into(), prune);
        part.topics.insert(topic.clone(), skills.clone());
    }
    publish_topic(mc, ID, "toolPrune")?;
    publish_topic(mc, ID, &topic)?;
    // The project is named for a listing as it first shows, and as its hold
    // begins or ends.
    let named = json!({"projectId": PROJECT, "held": !skills["held"].is_null()});
    let part = fake_plugin_part(mc, ID)?;
    if !is_empty(&skills) && part.topics.get("microSkillsProjects") != Some(&named) {
        part.topics.insert("microSkillsProjects".into(), named);
        publish_topic(mc, ID, "microSkillsProjects")?;
    }
    Ok(())
}

fn history(at: &str, read: u32) -> Json {
    json!({"state": at, "startedAt": "2026-11-01T09:00:00Z", "threads": 5, "threadsRead": read,
           "turns": 9, "pending": 0, "skipped": {"older than 30 days": 2}})
}

fn skills_entry(skills: Json, dropped: Json, history: Json) -> Json {
    json!({"projectId": PROJECT, "history": history, "turns": 9, "staged": "", "skills": skills,
           "dropped": dropped, "held": null, "extractors": []})
}

/// A held project's entry, as the MC part lists it: learned nothing, saying
/// why and where.
fn held_entry() -> Json {
    let mut held = skills_entry(json!([]), json!([]), json!({"state": "none"}));
    held["turns"] = json!(0);
    held["held"] = json!(HELD);
    held["file"] = json!(FILE);
    held
}

fn learned_fact() -> Json {
    json!({"id": FACT, "family": "test-command",
           "claim": "Run the tests with `python -m pytest`; `pytest` is not on PATH.",
           "state": "ACTIVE", "staged": true, "high": true, "source": "envfacts",
           "evidence": {"confirms": 4, "contradicts": 0, "fired": 3, "exercised": 4,
                        "firingRate": 0.75}})
}

/// The project as the sidebar lists it, so the page asks for it by name.
fn ensure_project(mc: &mut FakeMc) {
    if mc.projects.contains_key(PROJECT) {
        return;
    }
    let row = json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": format!("/work/{PROJECT}"),
                     "scripts": [], "createdAt": "2026-09-01T09:00:00Z",
                     "updatedAt": "2026-09-01T09:00:00Z"});
    mc.projects.insert(PROJECT.into(), row.clone());
    mc.send_row_of(PROJECT, &row, "project");
}

fn tool(at: &str, unused: u32) -> Json {
    json!({"state": at, "unusedSessions": unused, "unusedPrompts": unused * 3,
           "loadedSessions": unused})
}

/// The project's evidence for Claude: "CronCreate" as `at`, threads holding
/// pruning off as `unresolved` and away as `away`.
fn prune_of(at: &str, unresolved: Json, away: Json) -> Json {
    let cron = |state: &str| {
        if at == state {
            json!(["CronCreate"])
        } else {
            json!([])
        }
    };
    json!({"projectId": PROJECT, "provider": "claudeAgent", "unit": "tool", "mode": "propose",
           "off": cron("off"), "proposed": cron("proposed"), "kept": cron("kept"),
           "pending": [], "sessions": 6, "prompts": 18,
           "tools": {"CronCreate": tool(at, 5), "Bash": tool("used", 0)},
           "unresolved": unresolved, "unreadable": false, "away": away})
}

/// The calls the page makes, answered as the MC part answers them.
fn answer(mc: &mut FakeMc, rpc: &Rpc) -> Outcome {
    let method = text(&rpc.payload["method"]);
    let input = &rpc.payload["input"];
    let project = &input["projectId"];
    match method.as_str() {
        "status" => {
            mc.reply(rpc, loop_guard());
            return Ok(());
        }
        "toolPrune" => {
            let mut answer = tool_prune(mc);
            if let Some(answer) = answer.as_object_mut() {
                answer.remove("unreadable");
            }
            // Naming the project loads its saved evidence, as the topic then
            // carries it.
            if input.get("projectId").is_some() {
                let fake = state(mc);
                if project == PROJECT && is_empty(&fake.prune) {
                    fake.prune = fake.saved.clone();
                }
                let prune = if project == PROJECT {
                    fake.prune.clone()
                } else {
                    Json::Null
                };
                answer["projects"] = listed(&prune);
            }
            mc.reply(rpc, answer);
            return Ok(());
        }
        "microSkills" => {
            // Naming a held project reads its file again.
            let fake = state(mc);
            if project == PROJECT && !is_empty(&fake.repaired) {
                fake.skills = std::mem::take(&mut fake.repaired);
            }
            let answer = micro_skills(mc);
            mc.reply(rpc, answer);
            return Ok(());
        }
        "toolPruneRestore" => state(mc).prune = prune_of("kept", json!([]), json!([])),
        "toolPruneApply" => state(mc).prune = prune_of("off", json!([]), json!([])),
        _ if project != PROJECT => {
            mc.refuse(rpc, "Give a projectId and an id.");
            return Ok(());
        }
        "microSkills.drop" => {
            let fake = state(mc);
            fake.staged = false;
            fake.skills = skills_entry(json!([]), json!([FACT]), fake.skills["history"].clone());
        }
        "microSkills.restore" => {
            let fake = state(mc);
            fake.skills = skills_entry(
                json!([fake.fact.clone()]),
                json!([]),
                fake.skills["history"].clone(),
            );
        }
        "microSkills.forget" => {
            let fake = state(mc);
            fake.staged = false;
            fake.skills = skills_entry(
                json!([]),
                fake.skills["dropped"].clone(),
                history("running", 0),
            );
        }
        _ => {
            mc.refuse(rpc, &format!("Unknown method {method}."));
            return Ok(());
        }
    }
    let answer = if method.starts_with("microSkills") {
        micro_skills(mc)
    } else {
        tool_prune(mc)
    };
    mc.reply(rpc, answer);
    publish(mc)
}

/// The calls of `method` the page made, with their input.
fn asked(mc: &FakeMc, method: &str) -> Vec<Json> {
    mc.calls
        .iter()
        .filter(|rpc| rpc.method == "plugins.call" && text(&rpc.payload["method"]) == method)
        .map(|rpc| rpc.payload["input"].clone())
        .collect()
}

/// The first `method` call the page made, once it has reached the MC.
fn wait_asked(world: &mut World, method: &str) -> Outcome<Json> {
    world.wait_for_with(
        |w| !asked(&w.mc, method).is_empty(),
        |_| format!("the page to call {method}"),
    )?;
    Ok(asked(&world.mc, method).swap_remove(0))
}

fn text_of(w: &World, brick: Brick, object_name: &str) -> String {
    named(w, brick, object_name)
        .map(|found| brick.text_of(w, found, "text"))
        .unwrap_or_default()
}

/// Waits until `object_name`'s text holds every one of `parts`.
fn wait_says(world: &mut World, object_name: &str, parts: &[&str]) -> Outcome {
    let brick = shell(world)?;
    shown_named(world, object_name)?;
    world.wait_for_with(
        |w| {
            let text = text_of(w, brick, object_name);
            parts.iter().all(|part| text.contains(part))
        },
        |w| {
            format!(
                "{object_name} to say {}, not {}",
                parts.join(" … "),
                text_of(w, brick, object_name)
            )
        },
    )
}

/// Whether the item named `object_name`, or a visible item under it, draws
/// `wanted`.
fn draws(w: &World, brick: Brick, object_name: &str, wanted: &str) -> bool {
    named(w, brick, object_name)
        .is_some_and(|found| brick.shows_under(w, found, wanted).unwrap_or(false))
}

/// Waits until the shown `object_name` draws `wanted`.
fn wait_draws(world: &mut World, object_name: &str, wanted: &str) -> Outcome {
    let brick = shell(world)?;
    shown_named(world, object_name)?;
    world.wait_for_with(
        |w| draws(w, brick, object_name, wanted),
        |_| format!("{object_name} to draw {wanted}"),
    )
}

/// Whether nothing named `object_name` is on screen.
fn gone(w: &World, brick: Brick, object_name: &str) -> bool {
    named(w, brick, object_name).is_none_or(|found| !brick.flag(w, found, "visible"))
}

fn click(world: &mut World, object_name: &str) -> Outcome {
    let brick = shell(world)?;
    let target: ObjectId = shown_named(world, object_name)?;
    world.wait_for_with(
        |w| brick.flag(w, target, "enabled"),
        |_| format!("{object_name} to be enabled"),
    )?;
    click_item(world, target)
}

fn run_plugin(world: &mut World) -> Outcome {
    let package = package(ID);
    let read = manifest(&package)?;
    let mut settings = Map::new();
    for each in read["settings"].as_array().into_iter().flatten() {
        settings.insert(text(&each["key"]), each["default"].clone());
    }
    let part = FakePluginPart {
        package,
        call: Some(Rc::new(answer)),
        ..FakePluginPart::default()
    };
    run_fake_plugin(world, entry_of(ID, &read, &Json::Object(settings)), part)?;
    publish(&mut world.mc)
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "an MC running the TokenEconomizer plugin( with micro-skills)?",
        |world, _, _| run_plugin(world),
    );
    steps.step("the person opens TokenEconomizer's page", |world, _, _| {
        switch_to_tab(world, "TokenEconomizer")?;
        shown_named(world, "tokenEconomizerPage").map(|_| ())
    });
    register_micro_skills(steps);
    register_history(steps);
    register_tool_prune(steps);
}

fn register_micro_skills(steps: &mut Steps) {
    steps.step(
        "TokenEconomizer has learned a fact on a project",
        |world, _, _| {
            let fake = state(&mut world.mc);
            fake.fact = learned_fact();
            fake.skills = skills_entry(
                json!([fake.fact.clone()]),
                json!([]),
                json!({"state": "none"}),
            );
            fake.staged = true;
            publish(&mut world.mc)
        },
    );
    steps.step(
        "the fact is listed with how many turns confirmed it and how often it fires",
        |world, _, _| {
            let claim = text(&state(&mut world.mc).fact["claim"]);
            wait_draws(world, &format!("tokenEconomizerFact:{FACT}"), &claim)?;
            wait_says(
                world,
                &format!("tokenEconomizerEvidence:{FACT}"),
                &["confirmed by 4 turn(s)", "fires 75%", "active, staged"],
            )
        },
    );
    steps.step("the page says nothing is learned yet", |world, _, _| {
        wait_says(
            world,
            "tokenEconomizerSkillsMode",
            &["Nothing learned yet."],
        )
    });
    steps.step("the person drops the fact there", |world, _, _| {
        click(world, &format!("tokenEconomizerDrop:{FACT}"))
    });
    steps.step(
        "a new conversation in that project is not told the fact",
        |world, _, _| {
            world.wait_for("the fact to be dropped", |w| {
                w.mc.peek::<FakeTokenEconomizer>()
                    .is_some_and(|f| !f.staged)
            })?;
            let dropped = wait_asked(world, "microSkills.drop")?;
            expect!(
                dropped == json!({"projectId": PROJECT, "id": FACT}),
                "the MC was asked {}",
                show(&dropped)
            );
            Ok(())
        },
    );
    steps.step(
        "the page lists it as dropped, with a way to restore it",
        |world, _, _| {
            wait_draws(
                world,
                &format!("tokenEconomizerDropped:{FACT}"),
                &format!("Dropped: {FACT}, never staged or learned again"),
            )?;
            let brick = shell(world)?;
            let fact = format!("tokenEconomizerFact:{FACT}");
            world.wait_for("the dropped fact to leave the facts", |w| {
                gone(w, brick, &fact)
            })?;
            click(world, &format!("tokenEconomizerRestore:{FACT}"))?;
            shown_named(world, &fact).map(|_| ())
        },
    );

    steps.step(
        "TokenEconomizer holds a project's micro-skills, its saved file not being valid JSON",
        |world, _, _| {
            state(&mut world.mc).skills = held_entry();
            publish(&mut world.mc)
        },
    );
    steps.step(
        "the page shows the project as held, saying why and naming its file",
        |world, _, _| {
            wait_says(
                world,
                "tokenEconomizerHeld",
                &[&format!("Held: {HELD}"), "Repair or remove the file"],
            )?;
            wait_says(world, "tokenEconomizerHeldFile", &[FILE])
        },
    );
    steps.step(
        "the page offers no way to drop or forget there",
        |world, _, _| {
            let brick = shell(world)?;
            shown_named(world, "tokenEconomizerPage")?;
            expect!(
                gone(world, brick, "tokenEconomizerForget"),
                "Forget is offered on a held project"
            );
            Ok(())
        },
    );
    steps.step(
        "the person repairs the file and reads it again from the page",
        |world, _, _| {
            let fake = state(&mut world.mc);
            fake.fact = learned_fact();
            fake.repaired = skills_entry(
                json!([fake.fact.clone()]),
                json!([]),
                json!({"state": "none"}),
            );
            click(world, "tokenEconomizerReadAgain")?;
            world.wait_for("the page to ask for the project by name", |w| {
                asked(&w.mc, "microSkills").contains(&json!({"projectId": PROJECT}))
            })?;
            let brick = shell(world)?;
            world.wait_for("the project to no longer show as held", |w| {
                gone(w, brick, "tokenEconomizerHeld")
            })
        },
    );
}

fn register_history(steps: &mut Steps) {
    steps.step(
        "TokenEconomizer's history import on a project is under way",
        |world, _, _| {
            state(&mut world.mc).skills = skills_entry(json!([]), json!([]), history("running", 2));
            publish(&mut world.mc)
        },
    );
    steps.step(
        "the project shows how many threads the import read of how many, and what it left out",
        |world, _, _| {
            wait_says(
                world,
                "tokenEconomizerImport",
                &["running", "read 2 of 5 thread", "older than 30 days: 2"],
            )
        },
    );
    steps.step(
        "the person forgets what the project learned there",
        |world, _, _| click(world, "tokenEconomizerForget"),
    );
    steps.step(
        "the page shows the project having learned nothing, its import running again",
        |world, _, _| {
            let forgot = wait_asked(world, "microSkills.forget")?;
            expect!(
                forgot == json!({"projectId": PROJECT}),
                "the MC was asked {}",
                show(&forgot)
            );
            wait_says(
                world,
                "tokenEconomizerImport",
                &["running", "read 0 of 5 thread"],
            )?;
            let brick = shell(world)?;
            expect!(
                named(world, brick, &format!("tokenEconomizerFact:{FACT}")).is_none(),
                "a fact is still listed"
            );
            Ok(())
        },
    );
}

fn register_tool_prune(steps: &mut Steps) {
    steps.step(
        &format!("a project where {Q} is turned off for Claude"),
        |world, c, _| {
            expect!(c[0] == "CronCreate", "only CronCreate is faked");
            state(&mut world.mc).prune = prune_of("off", json!([]), json!([]));
            publish(&mut world.mc)
        },
    );
    steps.step(
        &format!("the page shows {Q} as off, with the evidence for it"),
        |world, c, _| {
            let row = format!("tokenEconomizerTool:{KEY}:{}", c[0]);
            wait_draws(world, &row, &format!("{} · Off", c[0]))?;
            let brick = shell(world)?;
            expect!(
                draws(
                    world,
                    brick,
                    &row,
                    "unused for the last 5 conversation(s) and 15 prompt(s); loaded in 5"
                ),
                "{}'s evidence is not shown",
                c[0]
            );
            Ok(())
        },
    );
    steps.step("the page offers to give it back", |world, _, _| {
        click(world, &format!("tokenEconomizerGiveBack:{KEY}:CronCreate"))?;
        let restored = wait_asked(world, "toolPruneRestore")?;
        expect!(
            restored
                == json!({"projectId": PROJECT, "provider": "claudeAgent", "tools": ["CronCreate"]}),
            "the MC was asked {}",
            show(&restored)
        );
        wait_draws(
            world,
            &format!("tokenEconomizerTool:{KEY}:CronCreate"),
            "CronCreate · Given back",
        )
    });

    steps.step(
        &format!("a project where {Q} was turned off for Claude before the MC restarted"),
        |world, c, _| {
            expect!(c[0] == "CronCreate", "only CronCreate is faked");
            ensure_project(&mut world.mc);
            state(&mut world.mc).saved = prune_of("off", json!([]), json!([]));
            publish(&mut world.mc)
        },
    );
    steps.step(
        "the page asked for the project's tools by name",
        |world, _, _| {
            world.wait_for_with(
                |w| asked(&w.mc, "toolPrune").contains(&json!({"projectId": PROJECT})),
                |_| format!("the page to ask for {PROJECT}'s tools by name"),
            )
        },
    );

    steps.step(
        "tool pruning heard only part of a turn of a Claude thread in a project",
        |world, _, _| {
            state(&mut world.mc).prune = prune_of("proposed", json!([]), json!([]));
            Ok(())
        },
    );
    steps.step(
        "it could not read that turn back from the thread",
        |world, _, _| {
            state(&mut world.mc).prune = prune_of("proposed", json!([THREAD]), json!([]));
            publish(&mut world.mc)
        },
    );
    steps.step(
        "the thread moved to another machine before that turn could be read back",
        |world, _, _| {
            state(&mut world.mc).prune = prune_of("proposed", json!([]), json!([THREAD]));
            publish(&mut world.mc)
        },
    );
    steps.step(
        "the page shows that nothing is turned off for the project's new conversations until that thread is read back",
        |world, _, _| {
            wait_says(
                world,
                &format!("tokenEconomizerUnresolved:{KEY}"),
                &["Nothing is turned off for this project's new conversations until 1 thread(s) are read back"],
            )?;
            shown_named(world, &format!("tokenEconomizerHolding:{KEY}:{THREAD}")).map(|_| ())
        },
    );
    steps.step(
        "the page lists the thread as away, not as holding pruning off",
        |world, _, _| {
            wait_draws(
                world,
                &format!("tokenEconomizerAway:{KEY}:{THREAD}"),
                &format!(
                    "Away on another machine, holding nothing off until it comes back: {THREAD}"
                ),
            )?;
            let brick = shell(world)?;
            expect!(
                gone(
                    world,
                    brick,
                    &format!("tokenEconomizerHolding:{KEY}:{THREAD}")
                ) && gone(world, brick, &format!("tokenEconomizerUnresolved:{KEY}")),
                "the away thread is listed as holding pruning off"
            );
            Ok(())
        },
    );
}
