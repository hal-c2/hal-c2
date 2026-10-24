//! A thread and the subagents it started (features/timeline/plans-and-subagents.feature):
//! moving between a subagent's thread and its parent, a message that came
//! from another agent's thread, the model a subagent runs on, work a finished
//! subagent left running, and a subagent's approval answered from its parent.
//! The parent is stream.rs's thread-1 ("Tax line"); the MC's side is written as
//! delegation.ex and the Claude adapter write it. desktop-qt's SubagentSteps.cpp.

use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::threads;
use hal_c2_shell::thread_view::agents::{Agents, AgentsModel};
use serde_json::{Value, json};

use super::stream::{
    FakeStreams, THREAD, add_item, describe, iso, now, role, set, settle_run, start_run, status,
};
use super::timeline::last_row_of;
use super::turn::start_working_turn;
use crate::brick::{Brick, shown};
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const CHILD: &str = "thread-child";
const CHILD_TITLE: &str = "Tax tests";
const TASK: &str = "task-1";

fn key(world: &World, thread: &str) -> String {
    format!("{}:{thread}", world.mc.environment_id)
}

fn shown_thread(world: &World) -> String {
    world
        .with::<Navigation, _>(|n, _| n.thread_key().to_owned())
        .unwrap_or_default()
}

/// The MC lists the subagent's thread under its parent.
fn list_child_thread(world: &mut World) -> Outcome {
    let row = json!({"id": CHILD, "title": CHILD_TITLE, "projectId": super::stream::PROJECT,
                     "createdAt": "2026-09-23T09:30:00Z", "updatedAt": "2026-09-23T09:30:00Z",
                     "lineage": {"rootThreadId": THREAD, "parentThreadId": THREAD,
                                 "relationshipToParent": "subagent"}});
    world.mc.threads.insert(CHILD.into(), row.clone());
    world.mc.send_row(CHILD, &row);
    world.sync()
}

/// A subagent of the running turn: its entity and the item that shows it.
fn delegate(world: &mut World, fields: Value) -> Outcome {
    let (thread, run) = {
        let fake = world.mc.part::<FakeStreams>();
        (fake.thread.clone(), fake.run.clone())
    };
    let mut entity = json!({"id": TASK, "threadId": thread, "runId": run, "childThreadId": CHILD,
                            "prompt": "write the tax tests", "title": CHILD_TITLE, "model": "gpt-5.5",
                            "status": "running", "startedAt": iso(now()), "updatedAt": iso(now())});
    let mut item = json!({"id": format!("turn-item:subagent:{TASK}"), "subagentId": TASK,
                          "origin": "app_owned", "childThreadId": CHILD, "title": CHILD_TITLE,
                          "prompt": "write the tax tests", "result": null, "status": "running"});
    for (k, v) in fields.as_object().into_iter().flatten() {
        entity[k] = v.clone();
        if k != "model" {
            item[k] = v.clone();
        }
    }
    set(world, "subagent", TASK, entity)?;
    add_item(world, "subagent", item)?;
    Ok(())
}

fn row_of(world: &World, kind: &str) -> Outcome<usize> {
    last_row_of(world, kind)
}

/// The open thread as the ThreadView brick draws it.
fn view(world: &mut World) -> Outcome<Brick> {
    if let Ok(brick) = shown(world) {
        return Ok(brick);
    }
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Bricks\nThreadView { width: 820; height: 900 }\n",
        820.0,
        900.0,
    )?;
    shown(world)
}

fn drawn(world: &mut World, name: &str) -> Outcome<ljos::prelude::ObjectId> {
    let brick = view(world)?;
    let wanted = format!("the thread to draw {name}");
    world.wait_for(&wanted, |w| {
        brick.find_visible(w, name).ok().flatten().is_some()
    })?;
    match brick.find_visible(world, name)? {
        Some(item) => Ok(item),
        None => fail!("{name} went away"),
    }
}

fn draws(world: &mut World, name: &str) -> Outcome<bool> {
    let brick = view(world)?;
    Ok(brick.find_visible(world, name)?.is_some())
}

fn click(world: &mut World, name: &str) -> Outcome {
    let item = drawn(world, name)?;
    let brick = view(world)?;
    let (x, y) = brick.at(world, item, 0.5, 0.5)?;
    world.click_at(x, y)?;
    world.sync()
}

fn drawn_text(world: &mut World, name: &str) -> Outcome<String> {
    let item = drawn(world, name)?;
    Ok(view(world)?.text_of(world, item, "text"))
}

fn agents_count(world: &World) -> usize {
    agents_core(world, Agents::count).unwrap_or(0)
}

fn agents_core<R>(world: &World, f: impl FnOnce(&Agents) -> R) -> Outcome<R> {
    let obj = world
        .with::<RightPanel, _>(|p, _| p.agents())?
        .ok_or_else(|| Failure("the panel has no Agents tab".into()))?;
    AgentsModel::read_core(world.engine(), obj, f)
        .ok_or_else(|| Failure("the Agents tab is busy".into()))
}

fn agent_value(world: &World, row: usize, name: &str) -> Value {
    agents_core(world, |a| a.value(row, name))
        .ok()
        .flatten()
        .unwrap_or(Value::Null)
}

/// A run the MC started for the agent itself: in place of a user's message its
/// first item is the notification of what it was sent (orchestration.ex message_item).
fn start_notified_run(world: &mut World, notification: Value) -> Outcome {
    let run = {
        let fake = world.mc.part::<FakeStreams>();
        let run = format!("run-{}", fake.ordinal + 1);
        fake.run = run.clone();
        fake.run_started = Some(now());
        fake.ordinal += 1;
        run
    };
    let ordinal = world.mc.part::<FakeStreams>().ordinal;
    set(
        world,
        "run",
        &run,
        json!({"id": run, "ordinal": ordinal, "status": "running",
               "requestedAt": iso(now()), "startedAt": iso(now())}),
    )?;
    let item_ordinal = {
        let fake = world.mc.part::<FakeStreams>();
        fake.ordinal += 1;
        fake.ordinal
    };
    let id = format!("turn-item:user:message:{run}");
    let mut item = json!({"id": id, "type": "notification", "runId": run, "ordinal": item_ordinal,
                          "status": "completed", "updatedAt": iso(now())});
    for (k, v) in notification.as_object().into_iter().flatten() {
        item[k] = v.clone();
    }
    set(world, "turn-item", &id, item)?;
    add_item(world, "assistant_message", json!({"text": "Noted."}))?;
    Ok(())
}

fn last_command_of(world: &World, kind: &str) -> Value {
    world
        .mc
        .commands
        .iter()
        .rev()
        .find(|command| text(&command["type"]) == kind)
        .cloned()
        .unwrap_or(Value::Null)
}

fn approvals(world: &World) -> Vec<Value> {
    world.state("turn")["approvals"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn no_user_message(world: &mut World) -> Outcome {
    let rows = super::stream::row_count(world)?;
    for row in 0..rows {
        expect!(
            role(world, row, "kind") != "message" || role(world, row, "author") != "user",
            "{}",
            describe(world)
        );
        expect!(
            !text(&role(world, row, "text")).contains("delegated_task_result"),
            "{}",
            describe(world)
        );
        expect!(
            text(&role(world, row, "attribution")).is_empty(),
            "{}",
            describe(world)
        );
    }
    // The agent's reply to it is there, so the thread is drawn.
    drawn(world, "markerTitle")?;
    expect!(
        !draws(world, "messageAttribution")?,
        "a message is drawn with a sender"
    );
    Ok(())
}

pub fn register(steps: &mut Steps) {
    // Between a subagent and its parent.
    steps.step("the agent has a subagent", |world, _, _| {
        list_child_thread(world)?;
        start_run(world, 0, "running")?;
        delegate(world, json!({}))
    });
    steps.step("the user opens the subagent's thread", |world, _, _| {
        // The subagent's row in the parent's timeline.
        click(world, "subagentRow")?;
        let child = key(world, CHILD);
        world.wait_for_with(
            |w| shown_thread(w) == child,
            |w| {
                format!(
                    "the subagent's thread to open; the window shows {}",
                    shown_thread(w)
                )
            },
        )
    });
    steps.step(
        "the thread says it is a subagent of the parent",
        |world, _, _| {
            let parent = key(world, THREAD);
            world.wait_for_with(
                |w| {
                    let lineage = w.state("lineage");
                    at(&lineage, "parent.key") == parent.as_str()
                        && at(&lineage, "parent.subagent") == &json!(true)
                },
                |w| {
                    format!(
                        "the thread's parent; its lineage is {}",
                        show(&w.state("lineage"))
                    )
                },
            )?;
            let brick = view(world)?;
            world.wait_for("the thread to say where it came from", |w| {
                brick.shows(w, "Subagent of Tax line").unwrap_or(false)
            })
        },
    );
    steps.step("the user opens the parent thread", |world, _, _| {
        click(world, "lineageParent")
    });
    steps.step("the parent thread is shown", |world, _, _| {
        let parent = key(world, THREAD);
        world.wait_for_with(
            |w| shown_thread(w) == parent && threads::active(w.engine()) == parent,
            |w| format!("the parent thread; the window shows {}", shown_thread(w)),
        )?;
        // Its own timeline, with the subagent's row and no line saying where it came from.
        let row = row_of(world, "subagent")?;
        expect!(
            role(world, row, "title") == CHILD_TITLE,
            "{}",
            describe(world)
        );
        let brick = view(world)?;
        world.wait_for("the parent to say nothing of a parent", |w| {
            w.state("lineage")["parent"].is_null()
                && !brick.shows(w, "Subagent of Tax line").unwrap_or(true)
        })
    });

    // A message from another agent.
    steps.step("a subagent sent a message to its parent", |world, _, _| {
        list_child_thread(world)?;
        let run = start_run(world, 0, "running")?;
        // The MC records the sending thread on the message.
        set(
            world,
            "turn-item",
            &format!("message:{run}"),
            json!({"text": "12 tests added", "createdBy": "agent", "senderThreadId": CHILD}),
        )
    });
    steps.step(
        "the user reads the message in the parent thread",
        |world, _, _| {
            expect!(
                shown_thread(world) == key(world, THREAD),
                "the window shows {}",
                shown_thread(world)
            );
            let row = row_of(world, "message")?;
            expect!(
                role(world, row, "text") == "12 tests added",
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("it says which thread it came from", |world, _, _| {
        let row = row_of(world, "message")?;
        let attribution = text(&role(world, row, "attribution"));
        expect!(
            attribution == "From Tax tests",
            "the message says \"{attribution}\""
        );
        expect!(
            drawn_text(world, "messageAttribution")? == "From Tax tests",
            "the message is not drawn with its sender"
        );
        Ok(())
    });
    steps.step("the user can open that thread", |world, _, _| {
        click(world, "messageAttribution")?;
        let child = key(world, CHILD);
        world.wait_for_with(
            |w| shown_thread(w) == child,
            |w| {
                format!(
                    "the sender's thread to open; the window shows {}",
                    shown_thread(w)
                )
            },
        )
    });

    // What the MC sent the agent for itself.
    steps.step(
        &format!("a task the agent delegated as {Q} finished"),
        |world, c, _| {
            list_child_thread(world)?;
            start_notified_run(
                world,
                json!({"source": {"kind": "delegated_task", "taskIds": [TASK]},
                       "outcome": "completed", "summary": format!("{} finished", c[0])}),
            )
        },
    );
    steps.step(
        &format!("a thread stored the failed result of the delegated task {Q} as a user message"),
        |world, c, _| {
            list_child_thread(world)?;
            let run = start_run(world, 0, "running")?;
            // What delegation.ex sent before the MC recorded it as a notification.
            set(
                world,
                "turn-item",
                &format!("message:{run}"),
                json!({"createdBy": "system", "creationSource": "server",
                       "inputIntent": "queued_turn",
                       "text": format!("<delegated_task_result taskId=\"task:1\" title=\"{}\" status=\"failed\" childThreadId=\"{CHILD}\">\nThe tests do not build.\n</delegated_task_result>", c[0])}),
            )?;
            add_item(world, "assistant_message", json!({"text": "Noted."}))?;
            Ok(())
        },
    );
    steps.step("the agent's background work woke it up", |world, _, _| {
        // claude/thread_runtime.ex wake.
        start_notified_run(
            world,
            json!({"source": {"kind": "background_task"}, "outcome": "updated",
                   "summary": "Background activity updated"}),
        )
    });
    steps.step(
        "a thread stored the agent's own wake-up as a user message",
        |world, _, _| {
            let run = start_run(world, 0, "running")?;
            set(
                world,
                "turn-item",
                &format!("message:{run}"),
                json!({"createdBy": "agent", "creationSource": "provider",
                       "text": "Background task completed."}),
            )?;
            add_item(world, "assistant_message", json!({"text": "Noted."}))?;
            Ok(())
        },
    );
    steps.step("the user reads the parent thread", |world, _, _| {
        expect!(
            shown_thread(world) == key(world, THREAD),
            "the window shows {}",
            shown_thread(world)
        );
        Ok(())
    });
    steps.step(&format!("the timeline says {Q}"), |world, c, _| {
        let row = row_of(world, "marker")?;
        expect!(role(world, row, "title") == c[0], "{}", describe(world));
        expect!(
            text(&role(world, row, "text")).is_empty(),
            "{}",
            describe(world)
        );
        expect!(
            drawn_text(world, "markerTitle")? == c[0],
            "the row is not drawn as \"{}\"",
            c[0]
        );
        Ok(())
    });
    steps.step(
        "the result is not shown as a message of the user's",
        |world, _, _| no_user_message(world),
    );
    steps.step(
        "nothing says a message was sent by another agent",
        |world, _, _| no_user_message(world),
    );

    // The model a subagent runs on.
    steps.step(
        &format!("the agent delegated work to a subagent on the model {Q}"),
        |world, c, _| {
            let row = {
                let row = world
                    .mc
                    .threads
                    .entry(THREAD.into())
                    .or_insert_with(|| json!({"id": THREAD}));
                row["modelSelection"] = json!({"instanceId": "codex", "model": "gpt-5"});
                row.clone()
            };
            world.mc.send_row(THREAD, &row);
            world.sync()?;
            start_run(world, 0, "running")?;
            // The MC lists the task with the model it was delegated to (delegation.ex).
            delegate(world, json!({"model": c[0]}))
        },
    );
    steps.step("the user looks at the parent's subagents", |world, _, _| {
        world.dispatch("rightPanel.add", json!({"kind": "agents"}))?;
        world.sync()?;
        world.wait_for("the Agents tab to list the subagent", |w| {
            agents_count(w) == 1
        })
    });
    steps.step(&format!("the subagent is shown with {Q}"), |world, c, _| {
        let row = row_of(world, "subagent")?;
        expect!(
            role(world, row, "agentModel") == c[0],
            "{}",
            describe(world)
        );
        let detail = drawn_text(world, "subagentDetail")?;
        expect!(
            detail == format!("{} · write the tax tests", c[0]),
            "the subagent reads \"{detail}\""
        );
        let named = agent_value(world, 0, "modelName");
        expect!(named == c[0], "the Agents tab names {}", text(&named));
        Ok(())
    });
    steps.step("the parent's model is not shown for it", |world, _, _| {
        let parent = text(&world.mc.threads[THREAD]["modelSelection"]["model"]);
        expect!(parent == "gpt-5", "the parent runs on {parent}");
        let detail = drawn_text(world, "subagentDetail")?;
        expect!(
            !detail.contains(&format!("{parent} ·"))
                && text(&agent_value(world, 0, "modelName")) != parent,
            "the subagent reads \"{detail}\""
        );
        Ok(())
    });

    // What a subagent's row says it did.
    steps.step(
        &format!("a subagent that reported {Q} and then finished with {Q}"),
        |world, c, _| {
            start_run(world, 30, "running")?;
            delegate(
                world,
                json!({"progress": c[0], "status": "completed", "result": c[1]}),
            )
        },
    );
    steps.step(
        &format!("a subagent that is still working after reporting {Q}"),
        |world, c, _| {
            start_run(world, 30, "running")?;
            delegate(world, json!({"progress": c[0], "result": "Earlier result"}))
        },
    );
    steps.step(&format!("the subagent's row reads {Q}"), |world, c, _| {
        let row = row_of(world, "subagent")?;
        let shown = text(&role(world, row, "text"));
        expect!(shown == c[0], "the row reads \"{shown}\"");
        Ok(())
    });

    // A finished subagent that left work running.
    steps.step(
        "a subagent returned its result while background work it started is still running",
        |world, _, _| {
            start_run(world, 30, "running")?;
            add_item(
                world,
                "command_execution",
                json!({"input": "npm run dev", "status": "running"}),
            )?;
            delegate(
                world,
                json!({"status": "completed", "result": "Dev server started"}),
            )?;
            add_item(
                world,
                "assistant_message",
                json!({"text": "The dev server is up."}),
            )?;
            // The turn is over; the command the subagent started is what is still pending.
            settle_run(world, "completed", 30)?;
            let row = {
                let row = &mut world
                    .mc
                    .threads
                    .entry(THREAD.into())
                    .or_insert_with(|| json!({"id": THREAD}));
                row["activeRunId"] = Value::Null;
                row["pendingBackgroundTasks"] = json!([{"taskType": "command_execution",
                                                        "description": "npm run dev"}]);
                row.clone()
            };
            world.mc.send_row(THREAD, &row);
            world.sync()
        },
    );
    steps.step("the user looks at the parent thread", |world, _, _| {
        expect!(
            shown_thread(world) == key(world, THREAD) && status(world) == "live",
            "the window shows {}",
            shown_thread(world)
        );
        view(world)?;
        Ok(())
    });
    steps.step("the subagent's result is shown", |world, _, _| {
        let row = row_of(world, "subagent")?;
        expect!(
            role(world, row, "text") == "Dev server started"
                && role(world, row, "statusLabel") == "Completed",
            "{}",
            describe(world)
        );
        expect!(
            drawn_text(world, "subagentDetail")?.ends_with("Dev server started"),
            "the result is not drawn"
        );
        Ok(())
    });
    steps.step(
        "its background work is still shown as running",
        |world, _, _| {
            // Out of the settled turn's fold, marked as running.
            let row = row_of(world, "work")?;
            let entries = role(world, row, "entries");
            let entries = entries.as_array().cloned().unwrap_or_default();
            expect!(
                entries.len() == 1
                    && entries[0]["command"] == "npm run dev"
                    && entries[0]["statusLabel"] == "Running",
                "{}",
                describe(world)
            );
            let brick = view(world)?;
            world.wait_for("the running command to be drawn", |w| {
                brick.shows(w, "Running").unwrap_or(false)
            })?;
            // And the Agents tab lists it beside the finished subagent.
            world.dispatch("rightPanel.add", json!({"kind": "agents"}))?;
            world.sync()?;
            let listed = (0..agents_count(world)).any(|row| {
                agent_value(world, row, "kind") == "command"
                    && agent_value(world, row, "title") == "npm run dev"
                    && agent_value(world, row, "running") == json!(true)
            });
            expect!(listed, "the Agents tab does not list the running command");
            Ok(())
        },
    );

    // A subagent's approval, answered from the parent.
    steps.step(
        "a subagent asks for approval to run a command",
        |world, _, _| {
            start_working_turn(world)?;
            delegate(world, json!({}))?;
            // The request is the parent's: the subagent's own thread holds none.
            let request = "request-subagent";
            set(
                world,
                "runtime-request",
                request,
                json!({"id": request, "status": "pending", "kind": "command",
                   "responseCapability": {"type": "live"}}),
            )?;
            add_item(
                world,
                "approval_request",
                json!({"requestId": request, "status": "waiting", "requestKind": "command",
                   "prompt": "npm test"}),
            )?;
            Ok(())
        },
    );
    steps.step("the approval is listed there", |world, _, _| {
        world.wait_for_with(
            |w| approvals(w).len() == 1,
            |w| format!("the approval; the turn is {}", show(&w.state("turn"))),
        )?;
        let approval = approvals(world)[0].clone();
        expect!(
            approval["requestId"] == "request-subagent"
                && approval["detail"] == "npm test"
                && approval["canRespond"] == json!(true),
            "the approval is {}",
            show(&approval)
        );
        // Beside the subagent that asked, still working.
        let row = row_of(world, "subagent")?;
        expect!(
            role(world, row, "statusLabel") == "Working",
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the user answers it", |world, _, _| {
        let request = approvals(world)
            .first()
            .map_or(Value::Null, |a| a["requestId"].clone());
        world.dispatch(
            "composer.approval.respond",
            json!({"requestId": request, "decision": "accept"}),
        )?;
        world.sync()
    });
    steps.step("the subagent continues with the answer", |world, _, _| {
        let answer = last_command_of(world, "runtime-request.respond");
        expect!(
            answer["threadId"] == THREAD
                && answer["requestId"] == "request-subagent"
                && answer["decision"] == "accept",
            "the MC was told {}; it has {}",
            show(&answer),
            world.describe_commands()
        );
        // What the MC makes of it: the request is resolved and the subagent finishes.
        set(
            world,
            "runtime-request",
            "request-subagent",
            json!({"status": "resolved", "decision": "accept"}),
        )?;
        set(
            world,
            "turn-item",
            &format!("turn-item:subagent:{TASK}"),
            json!({"status": "completed", "result": "ran npm test"}),
        )?;
        world.wait_for_with(
            |w| approvals(w).is_empty(),
            |w| {
                format!(
                    "the approval to close; the turn is {}",
                    show(&w.state("turn"))
                )
            },
        )?;
        let row = row_of(world, "subagent")?;
        expect!(
            role(world, row, "text") == "ran npm test",
            "{}",
            describe(world)
        );
        Ok(())
    });
}
