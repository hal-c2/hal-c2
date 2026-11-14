//! What the desktop shows of things the MC's orchestration decides: a turn
//! that failed, a queue a usage limit holds, a plan Codex marked finished.
//! The @shared scenarios of features/mc/orchestration and features/providers
//! that are the MC's to decide and the client's to show; the MC's side is
//! faked as the entities apps/server-ex writes. desktop-qt's
//! OrchestrationViewSteps.cpp.

use serde_json::{Value, json};

use super::stream::{
    FakeStreams, PROJECT, add_item, describe, look, role, row_count, set, settle_run, start_run,
};
use super::thread_menu::update_row;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

#[derive(Default)]
struct Orchestration {
    commands_before: usize,
}

fn turn(world: &World) -> Value {
    world.state("turn")
}

/// The thread `id` of `project`, opened and followed.
fn open_thread(world: &mut World, id: &str, project: &str) -> Outcome {
    if world.shell_subscriptions() == 0 {
        world.connect()?;
        world.sync()?;
    }
    let row = world
        .mc
        .projects
        .entry(project.to_owned())
        .or_insert_with(|| {
            json!({"id": project, "title": project,
               "workspaceRoot": format!("/work/{project}"), "scripts": []})
        });
    let row = row.clone();
    world.mc.send_row_of(project, &row, "project");
    let thread = json!({"id": id, "title": "Tax line", "projectId": project,
                        "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
    world.mc.threads.insert(id.to_owned(), thread.clone());
    world.mc.send_row(id, &thread);
    world.sync()?;
    let environment = world.mc.environment_id.clone();
    let fake = world.mc.part::<FakeStreams>();
    fake.thread = id.to_owned();
    fake.environment = environment.clone();
    look(world, &format!("{environment}:{id}"), true)
}

fn begin_run(world: &mut World, thread: &str) -> Outcome<String> {
    let run = start_run(world, 0, "running")?;
    update_row(world, thread, |row| {
        row.insert("activeRunId".into(), json!(run));
        row.insert("latestRunId".into(), json!(run));
    })?;
    Ok(run)
}

fn queued(world: &World) -> Vec<String> {
    turn(world)["queue"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|entry| text(&entry["text"]))
        .collect()
}

/// Whether some row of the timeline holds `wanted` in its text.
fn shows(world: &World, wanted: &str) -> bool {
    let rows = row_count(world).unwrap_or(0);
    (0..rows).any(|row| text(&role(world, row, "text")).contains(wanted))
}

fn any_row(world: &World, matches: impl Fn(usize) -> bool) -> bool {
    let rows = row_count(world).unwrap_or(0);
    (0..rows).any(matches)
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("an MC with a project {Q} rooted at a git repository"),
        |_, _, _| Ok(()),
    );
    steps.step(
        &format!("thread {Q} exists in {Q}(?: with provider {Q})?"),
        |world, c, _| open_thread(world, &c[0], &c[1]),
    );

    // A turn that failed part-way (mc/orchestration/runs.feature).
    steps.step(
        &format!("the provider streamed part of its answer to {Q} and then failed"),
        |world, c, _| {
            begin_run(world, &c[0])?;
            add_item(
                world,
                "assistant_message",
                json!({"text": "The cart total needs", "streaming": true, "status": "running"}),
            )?;
            expect!(
                shows(world, "The cart total needs"),
                "the answer is not streaming: {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the failure is recorded", |world, _, _| {
        let fake = world.mc.part::<FakeStreams>();
        let thread = fake.thread.clone();
        // As HalC2.Orchestration records it: the message stops streaming where
        // it was, an error item, the run failed.
        let message = fake.threads.get(&thread).and_then(|entities| {
            entities
                .values()
                .find(|entity| entity["type"] == "assistant_message")
                .map(|entity| text(&entity["id"]))
        });
        if let Some(id) = message {
            set(
                world,
                "turn-item",
                &id,
                json!({"streaming": false, "status": "failed"}),
            )?;
        }
        add_item(
            world,
            "error",
            json!({"status": "failed",
                   "failure": {"class": "provider_error",
                               "message": "The provider stopped responding."}}),
        )?;
        settle_run(world, "failed", 5)?;
        update_row(world, &thread, |row| {
            row.insert("activeRunId".into(), Value::Null);
        })
    });
    steps.step(
        "the partial answer stays in the failed run",
        |world, _, _| {
            expect!(
                shows(world, "The cart total needs"),
                "the partial answer is gone: {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the run is marked failed", |world, _, _| {
        let failed = any_row(world, |row| role(world, row, "kind") == "error");
        expect!(
            failed
                && turn(world)["running"] != json!(true)
                && shows(world, "The provider stopped responding."),
            "the thread shows {}; the turn is {}",
            describe(world),
            show(&turn(world))
        );
        Ok(())
    });

    steps.step(
        &format!("the provider retries a failed request during a turn of {Q}"),
        |world, c, _| {
            begin_run(world, &c[0])?;
            world.part::<Orchestration>().commands_before = world.mc.commands.len();
            Ok(())
        },
    );
    steps.step("the retry is recorded", |world, _, _| {
        // One item of the running run, which the retry does not fail
        // (HalC2.Orchestration).
        add_item(
            world,
            "error",
            json!({"status": "running", "title": "Provider retry",
                   "retry": {"attempt": 2, "maxAttempts": 5, "retryDelayMs": null},
                   "failure": {"class": "transport_error",
                               "code": "responseStreamDisconnected",
                               "message": "stream disconnected before completion"}}),
        )
        .map(drop)
    });
    steps.step(
        "the turn's work log shows a provider retry",
        |world, _, _| {
            let retry = any_row(world, |row| {
                role(world, row, "title") == "Provider retry"
                    && role(world, row, "text") == "stream disconnected before completion"
            });
            expect!(
                retry && turn(world)["running"] == json!(true),
                "the thread shows {}; the turn is {}",
                describe(world),
                show(&turn(world))
            );
            Ok(())
        },
    );
    steps.step("no second user turn is created", |world, _, _| {
        let rows = row_count(world)?;
        let asked = (0..rows)
            .filter(|row| {
                role(world, *row, "kind") == "message" && role(world, *row, "author") == "user"
            })
            .count();
        world.sync()?;
        let before = world.part::<Orchestration>().commands_before;
        expect!(
            asked == 1 && world.mc.commands.len() == before,
            "{asked} user messages; the client sent {}",
            world.describe_commands()
        );
        Ok(())
    });

    // A queue a usage limit holds (mc/orchestration/queue-and-steering.feature).
    steps.step(
        &format!("{Q} has a running turn and queued messages {Q} and {Q}"),
        |world, c, _| {
            begin_run(world, &c[0])?;
            for (position, queued_text) in [&c[1], &c[2]].into_iter().enumerate() {
                let message = format!("message-{queued_text}");
                set(
                    world,
                    "message",
                    &message,
                    json!({"id": message, "role": "user", "text": queued_text}),
                )?;
                let ordinal = {
                    let fake = world.mc.part::<FakeStreams>();
                    fake.ordinal += 1;
                    fake.ordinal
                };
                let run = format!("run-queued-{queued_text}");
                set(
                    world,
                    "run",
                    &run,
                    json!({"id": run, "ordinal": ordinal, "status": "queued",
                           "queuePosition": position + 1, "userMessageId": message}),
                )?;
            }
            let wanted = vec![c[1].clone(), c[2].clone()];
            world.wait_for_with(
                |w| queued(w) == wanted,
                |w| format!("the queue; the turn is {}", show(&turn(w))),
            )
        },
    );
    steps.step(
        &format!("the provider stops {Q} because its usage limit was reached"),
        |world, c, _| {
            world.part::<Orchestration>().commands_before = world.mc.commands.len();
            // The run fails as a usage limit, which holds the queue where it is.
            add_item(
                world,
                "error",
                json!({"status": "failed",
                       "failure": {"class": "usage_limit",
                                   "message": "You've hit your usage limit."}}),
            )?;
            settle_run(world, "failed", 5)?;
            let thread = world.mc.part::<FakeStreams>().thread.clone();
            let held: Vec<String> = world
                .mc
                .part::<FakeStreams>()
                .threads
                .get(&thread)
                .into_iter()
                .flat_map(|entities| entities.values())
                .filter(|entity| entity["status"] == "queued")
                .map(|entity| text(&entity["id"]))
                .collect();
            for id in held {
                set(world, "run", &id, json!({"queueHeld": true}))?;
            }
            update_row(world, &c[0], |row| {
                row.insert("activeRunId".into(), Value::Null);
            })
        },
    );
    steps.step(
        &format!("{Q} and {Q} stay queued in their original order"),
        |world, c, _| {
            expect!(
                queued(world) == vec![c[0].clone(), c[1].clone()]
                    && turn(world)["running"] != json!(true),
                "the composer lists [{}]; the turn is {}",
                queued(world).join(", "),
                show(&turn(world))
            );
            Ok(())
        },
    );
    steps.step("neither is discarded or sent early", |world, _, _| {
        world.sync()?;
        // The client asked nothing of the MC on its own: no cancel, no steer,
        // no send.
        let before = world.part::<Orchestration>().commands_before;
        expect!(
            world.mc.commands.len() == before && queued(world).len() == 2,
            "the client sent {}",
            world.describe_commands()
        );
        // The limit is one line, the row's title; the provider's own words
        // are not shown.
        let limited = any_row(world, |row| {
            text(&role(world, row, "title")).starts_with("Usage limit reached")
        });
        expect!(limited, "the thread shows {}", describe(world));
        Ok(())
    });

    // A plan Codex marked finished (providers/codex.feature).
    steps.step(
        "Codex proposed a plan and marked it finished",
        |world, _, _| {
            let thread = "thread-plan";
            open_thread(world, thread, PROJECT)?;
            let run = begin_run(world, thread)?;
            update_row(world, thread, |row| {
                row.insert("interactionMode".into(), json!("plan"));
            })?;
            let markdown = "# Tax line\n\n- Add the line\n- Test it";
            // Codex's own plan item completed; the plan itself stays active until
            // it is implemented.
            add_item(
                world,
                "proposed_plan",
                json!({"markdown": markdown, "planId": "plan-1", "status": "completed",
                   "streaming": false}),
            )?;
            set(
                world,
                "plan",
                "plan-1",
                json!({"id": "plan-1", "kind": "proposed_plan", "status": "active",
                   "runId": run, "markdown": markdown}),
            )?;
            settle_run(world, "completed", 30)?;
            update_row(world, thread, |row| {
                row.insert("activeRunId".into(), Value::Null);
                row.insert("hasActionableProposedPlan".into(), json!(true));
            })
        },
    );
    steps.step("the plan is offered for implementation", |world, _, _| {
        world.wait_for_with(
            |w| !turn(w)["plan"].is_null(),
            |w| format!("the plan to be offered; the turn is {}", show(&turn(w))),
        )
    });
    steps.step("the user implements the plan", |world, _, _| {
        world.dispatch("composer.plan.implement", Value::Null)?;
        world.sync()
    });
    steps.step("a new run starts from that plan", |world, _, _| {
        let found = |w: &World| {
            w.mc.commands
                .iter()
                .rfind(|command| command["type"] == "message.dispatch")
                .cloned()
        };
        world.wait_for_with(
            |w| found(w).is_some(),
            |w| {
                format!(
                    "the plan's message; the MC was sent {}",
                    w.describe_commands()
                )
            },
        )?;
        let Some(message) = found(world) else {
            fail!("the plan's message is gone");
        };
        expect!(
            message["threadId"] == "thread-plan"
                && message["sourcePlanRef"]["planId"] == "plan-1"
                && text(&message["text"]).contains("# Tax line"),
            "the MC was sent {}",
            world.describe_commands()
        );
        Ok(())
    });
}
