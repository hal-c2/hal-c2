//! A new thread's worktree being prepared, as the conversation shows it
//! (features/threads/worktree-setup.feature): the MC's `worktreeSetup` shape
//! (a WorktreeSetupSnapshot, packages/contracts/src/worktreeSetup.ts) and the
//! WorktreeSetup controller that follows it for the open thread.
//! desktop-qt's ThreadWorktreeSetupSteps.cpp.

use serde_json::{Value, json};

use super::stream::{FakeStreams, look};
use crate::brick::{Brick, shown};
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

const ID: &str = "t-cart";
const AT: &str = "2026-09-23T09:00:00Z";

/// The snapshot the MC holds for the thread, and who watches it.
#[derive(Default)]
struct FakeSetup {
    snapshot: Value,
    sequence: i64,
}

fn extension(mc: &mut FakeMc) {
    mc.on_shape("worktreeSetup", |mc, id, _| {
        let snapshot = mc.part::<FakeSetup>().snapshot.clone();
        mc.send(&json!({"t": "worktreeSetup", "id": id, "event": snapshot}));
        Ok(())
    });
}

fn stage(id: &str, status: &str, detail: Option<&str>, tail: &[&str]) -> Value {
    json!({
        "id": id, "status": status,
        "startedAt": if status == "pending" { Value::Null } else { json!(AT) },
        "endedAt": null, "percent": null,
        "detail": detail, "tail": tail,
    })
}

fn publish(world: &mut World, phase: &str, stages: Vec<Value>, error: Option<&str>) -> Outcome {
    let fake = world.mc.part::<FakeSetup>();
    fake.sequence += 1;
    let sequence = fake.sequence;
    let snapshot = json!({
        "threadId": ID, "phase": phase, "startedAt": AT,
        "endedAt": if phase == "running" { Value::Null } else { json!(AT) },
        "branch": "hal-c2/cart-totals", "baseRef": "main",
        "worktreePath": "/work/worktrees/cart-totals",
        "setupScript": {"name": "Install", "command": "bun install", "terminalId": "setup-1"},
        "stages": stages, "error": error, "sequence": sequence,
    });
    world.mc.part::<FakeSetup>().snapshot = snapshot.clone();
    for id in world.mc.subscribers("worktreeSetup") {
        world
            .mc
            .send(&json!({"t": "worktreeSetup", "id": id, "event": snapshot}));
    }
    world.sync()
}

fn setup(world: &World) -> Value {
    world.state("worktreeSetup")
}

fn labelled(world: &World, label: &str) -> bool {
    text(&setup(world)["label"]) == label
}

fn stages_done(fetch: &str) -> Vec<Value> {
    vec![
        stage("fetch", fetch, None, &[]),
        stage("checkout", "done", None, &[]),
        stage("setup-script", "done", None, &[]),
        stage("agent", "done", None, &[]),
    ]
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    steps.step(
        &format!("the project {Q} has a setup script"),
        |world, c, _| {
            world.mc.projects.insert(
                c[0].clone(),
                json!({"id": c[0], "title": c[0], "workspaceRoot": format!("/work/{}", c[0]),
                   "scripts": [{"id": "setup", "name": "Install", "command": "bun install",
                                "runOnWorktreeCreate": true}]}),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user started the thread {Q} in a new worktree from {Q}"),
        |world, c, _| {
            let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
            world.mc.threads.insert(
                ID.to_owned(),
                json!({"id": ID, "title": c[0], "projectId": project,
                       "createdAt": AT, "updatedAt": AT}),
            );
            world.connect()?;
            world.sync()?;
            let environment = world.mc.environment_id.clone();
            let streams = world.mc.part::<FakeStreams>();
            streams.thread = ID.to_owned();
            streams.environment = environment.clone();
            look(world, &format!("{environment}:{ID}"), true)?;
            world.wait_for("the shell to follow the thread's setup", |w| {
                !w.mc.subscribers("worktreeSetup").is_empty()
            })
        },
    );
    steps.step(
        &format!(
            "the setup of {Q} (is still running|finished|made the worktree but its setup script failed|failed|was cancelled)"
        ),
        |world, c, _| {
            let fetched = stage("fetch", "done", None, &[]);
            let state = c[1].as_str();
            if state == "is still running" {
                publish(
                    world,
                    "running",
                    vec![
                        fetched,
                        stage("checkout", "running", Some("120 files"), &[]),
                        stage("setup-script", "pending", None, &[]),
                        stage("agent", "pending", None, &[]),
                    ],
                    None,
                )
            } else if state == "finished" {
                publish(world, "done", stages_done("done"), None)
            } else if state.starts_with("made the worktree") {
                publish(
                    world,
                    "done",
                    vec![
                        fetched,
                        stage("checkout", "done", None, &[]),
                        stage(
                            "setup-script",
                            "failed",
                            Some("exit 1"),
                            &["error: lockfile is frozen"],
                        ),
                        stage("agent", "done", None, &[]),
                    ],
                    None,
                )
            } else if state == "failed" {
                publish(
                    world,
                    "failed",
                    vec![
                        fetched,
                        stage("checkout", "failed", Some("exit 128"), &[]),
                        stage("setup-script", "skipped", None, &[]),
                        stage("agent", "skipped", None, &[]),
                    ],
                    Some("Could not create the worktree: the branch already exists."),
                )
            } else {
                publish(
                    world,
                    "cancelled",
                    vec![
                        fetched,
                        stage("checkout", "done", None, &[]),
                        stage("setup-script", "skipped", None, &[]),
                        stage("agent", "skipped", None, &[]),
                    ],
                    None,
                )
            }
        },
    );
    // source-control/worktrees-and-setup-scripts.feature: the card over a
    // thread whose first message made its worktree.
    steps.step(
        "the user sends the first message of a thread in a new worktree",
        |world, _, _| {
            let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
            world.open_draft(&project)?;
            world.dispatch("workspace.envMode.set", json!({"mode": "worktree"}))?;
            world.dispatch("workspace.branch.search", json!({"query": ""}))?;
            world.sync()?;
            world.dispatch("workspace.branch.select", json!({"name": "main"}))?;
            world.dispatch(
                "composer.submit",
                json!({"text": "Ship the fix", "intent": "foreground"}),
            )?;
            world.sync()?;
            // The window moves to the new thread and follows its setup.
            world.wait_for("the shell to follow the new thread's setup", |w| {
                !w.mc.subscribers("worktreeSetup").is_empty()
            })?;
            let last = world.mc.subscribers("worktreeSetup").last().copied();
            let asked = last.map_or(Value::Null, |id| world.mc.shape_of(id));
            expect!(
                world.mc.threads.contains_key(&text(&asked["threadId"])),
                "the shell follows {}",
                show(&asked)
            );
            publish(
                world,
                "running",
                vec![
                    stage("fetch", "done", None, &[]),
                    stage("checkout", "running", Some("120 files"), &[]),
                    stage("setup-script", "pending", None, &[]),
                    stage("agent", "pending", None, &[]),
                ],
                None,
            )
        },
    );
    steps.step(
        "the thread shows the worktree's base, branch and path with the stages",
        |world, _, _| {
            world.wait_for_with(
                |w| labelled(w, "Setting up worktree…"),
                |w| format!("the setup; it shows {}", show(&setup(w))),
            )?;
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Bricks\nWorktreeSetupCard { width: 700 }\n",
                700.0,
                300.0,
            )?;
            let brick = shown(world)?;
            brick.click(world, "worktreeSetupDetails")?;
            let shown_setup = setup(world);
            expect!(
                text(&shown_setup["baseRef"]) == "main"
                    && text(&shown_setup["branch"]) == "hal-c2/cart-totals"
                    && text(&shown_setup["worktreePath"]) == "/work/worktrees/cart-totals",
                "the setup shown is {}",
                show(&shown_setup)
            );
            world.wait_for("the card to say where the worktree is", move |w| {
                brick
                    .shows(w, "main → hal-c2/cart-totals · /work/worktrees/cart-totals")
                    .unwrap_or(false)
            })?;
            for label in [
                "Fetch base branch",
                "Check out files",
                "Run setup script",
                "Start agent",
            ] {
                expect!(
                    brick.shows(world, label)?,
                    "the card does not show the stage \"{label}\""
                );
            }
            expect!(
                brick.shows(world, "120 files")?,
                "the running stage's progress is not shown"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("it reads {Q} once the agent starts"),
        |world, c, _| {
            publish(world, "done", stages_done("done"), None)?;
            let Ok(brick) = shown(world) else {
                fail!("no brick is shown");
            };
            let wanted = c[0].clone();
            world.wait_for_with(
                move |w| labelled(w, &wanted) && brick.shows(w, &wanted).unwrap_or(false),
                |w| format!("\"{}\"; the setup shown is {}", c[0], show(&setup(w))),
            )
        },
    );
    steps.step(&format!("the conversation says {Q}"), |world, c, _| {
        // WorktreeSetupCard.qml shows the label over the conversation.
        world.wait_for_with(
            |w| labelled(w, &c[0]),
            |w| format!("\"{}\"; the setup shown is {}", c[0], show(&setup(w))),
        )
    });
    steps.step("the user opens the setup details", |world, _, _| {
        expect!(
            setup(world)["detailsOpen"] != json!(true),
            "the details are already open"
        );
        world.dispatch("worktreeSetup.details", json!({"open": true}))
    });
    steps.step(
        "the user sees why the setup failed and the steps that ran",
        |world, _, _| {
            let shown_setup = setup(world);
            let ran: Vec<String> = shown_setup["stages"]
                .as_array()
                .map(|stages| {
                    stages
                        .iter()
                        .map(|s| format!("{}={}", text(&s["label"]), text(&s["status"])))
                        .collect()
                })
                .unwrap_or_default();
            expect!(
                shown_setup["detailsOpen"] == json!(true)
                    && text(&shown_setup["error"])
                        == "Could not create the worktree: the branch already exists."
                    && ran
                        == [
                            "Fetch base branch=done",
                            "Check out files=failed",
                            "Run setup script=skipped",
                            "Start agent=skipped"
                        ],
                "the setup shown is {}",
                show(&shown_setup)
            );
            Ok(())
        },
    );
}
