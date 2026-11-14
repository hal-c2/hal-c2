//! How the timeline shows subagents, where a message came from and the
//! changes to a thread's context (features/timeline/plans-and-subagents.feature):
//! subagent rows, groups and pointing cards, a message's sender, a fork's
//! inherited work, compaction, handoff, fork and created-thread markers,
//! interrupts, the result waiting to wake the parent and the agents-working
//! banner. The open thread is stream.rs's thread-1, drawn by the ThreadView
//! brick: desktop-qt's SubagentDisplaySteps.cpp. A subagent's title is
//! subagent.rs's.

use chrono::Duration;
use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::thread_view::timeline_model::TimelineModel;
use ljos::prelude::{ObjectId, Value as LValue};
use serde_json::{Value, json};

use super::composer_brick::{composer_brick, composer_part, composer_part_now};
use super::settings::publish_providers;
use super::stream::{
    FakeStreams, PROJECT, THREAD, add_command, add_item, describe, iso, now, read, role, set,
    settle_run, start_run, timeline_object,
};
use crate::brick::{self, Brick};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

const SOURCE: &str = "thread-source";
const CREATED: &str = "thread-tax-tests";

/// What a step said that a later one compares against.
#[derive(Default)]
struct Said {
    note: String,
    run_message: String,
    opened_from: String,
}

fn key(world: &World, thread: &str) -> String {
    format!("{}:{thread}", world.mc.environment_id)
}

fn shown_thread(world: &World) -> String {
    world
        .with::<Navigation, _>(|n, _| n.thread_key().to_owned())
        .unwrap_or_default()
}

fn merge(into: &mut Value, fields: &Value) {
    if let Some(fields) = fields.as_object() {
        for (k, v) in fields {
            into[k] = v.clone();
        }
    }
}

/// The MC lists a thread of the open thread's project.
fn list_thread(world: &mut World, id: &str, title: &str, more: Value) -> Outcome {
    let mut row = json!({"id": id, "title": title, "projectId": PROJECT,
                         "createdAt": "2026-09-23T09:30:00Z", "updatedAt": "2026-09-23T09:30:00Z"});
    merge(&mut row, &more);
    world.mc.threads.insert(id.into(), row.clone());
    world.mc.send_row(id, &row);
    world.sync()
}

/// The open thread's row moves on.
fn change_thread_row(world: &mut World, fields: Value) -> Outcome {
    let mut row = world
        .mc
        .threads
        .get(THREAD)
        .cloned()
        .unwrap_or_else(|| json!({}));
    merge(&mut row, &fields);
    world.mc.threads.insert(THREAD.into(), row.clone());
    world.mc.send_row(THREAD, &row);
    world.sync()
}

fn rows_of(world: &World, kind: &str) -> Vec<usize> {
    let count = read(world, |t| t.row_count()).unwrap_or(0);
    (0..count)
        .filter(|row| role(world, *row, "kind") == kind)
        .collect()
}

fn last_row_of(world: &World, kind: &str) -> Outcome<usize> {
    match rows_of(world, kind).last() {
        Some(row) => Ok(*row),
        None => fail!("no {kind} row; {}", describe(world)),
    }
}

fn last_of(world: &World, kind: &str, name: &str) -> Outcome<Value> {
    Ok(role(world, last_row_of(world, kind)?, name))
}

fn toggle_row(world: &mut World, row_id: &str) -> Outcome {
    let obj = timeline_object(world)?;
    TimelineModel::update(world.engine(), obj, |t| t.toggle(row_id));
    world.pump()
}

/// Opens every closed turn fold, so the work in it is listed.
fn open_folds(world: &mut World) -> Outcome {
    loop {
        let closed = rows_of(world, "fold")
            .into_iter()
            .find(|row| role(world, *row, "expanded") != true);
        let Some(row) = closed else {
            return world.sync();
        };
        let id = text(&role(world, row, "rowId"));
        toggle_row(world, &id)?;
    }
}

/// The calls the work rows list, with every fold and group opened.
fn calls(world: &mut World) -> Outcome<Vec<Value>> {
    open_folds(world)?;
    let mut found = Vec::new();
    for row in rows_of(world, "work") {
        if role(world, row, "expanded") != true {
            let id = text(&role(world, row, "rowId"));
            toggle_row(world, &id)?;
        }
    }
    for row in rows_of(world, "work") {
        if let Value::Array(entries) = role(world, row, "entries") {
            found.extend(entries);
        }
    }
    Ok(found)
}

fn describe_calls(world: &mut World) -> String {
    let listed = calls(world).unwrap_or_default();
    let shown: Vec<String> = listed.iter().map(show).collect();
    format!(
        "{}; rows: {}",
        if shown.is_empty() {
            "no calls".to_owned()
        } else {
            shown.join("; ")
        },
        describe(world)
    )
}

/// The open thread as the ThreadView brick draws it.
fn view(world: &mut World) -> Outcome<Brick> {
    if world.part::<brick::Shown>().0.is_none() {
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n",
            820.0,
            900.0,
        )?;
    }
    brick::shown(world)
}

fn name_of(world: &World, item: ObjectId) -> String {
    match world.engine().read_by_name(item, "objectName") {
        LValue::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

fn text_of(world: &World, item: ObjectId) -> String {
    match world.engine().read_by_name(item, "text") {
        LValue::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

fn collect(world: &World, item: ObjectId, name: &str, found: &mut Vec<ObjectId>) {
    if world.engine().read_by_name(item, "visible") != LValue::Bool(true) {
        return;
    }
    if name_of(world, item) == name {
        found.push(item);
    }
    for child in world.engine().children(item) {
        collect(world, child, name, found);
    }
}

fn drawn_all(world: &World, name: &str) -> Vec<ObjectId> {
    let Some(brick) = world.peek_part::<brick::Shown>().and_then(|s| s.0) else {
        return Vec::new();
    };
    let mut found = Vec::new();
    if let Some(root) = brick.root(world) {
        collect(world, root, name, &mut found);
    }
    found
}

fn drawn(world: &mut World, name: &str) -> Outcome<ObjectId> {
    view(world)?;
    world.wait_for_with(
        |w| !drawn_all(w, name).is_empty(),
        |w| format!("the thread to draw {name}; {}", describe(w)),
    )?;
    match drawn_all(world, name).last() {
        Some(item) => Ok(*item),
        None => fail!("the thread did not draw {name}"),
    }
}

/// Waits for an item of that name to read `wanted`.
fn draws_text(world: &mut World, name: &str, wanted: &str) -> Outcome {
    view(world)?;
    world.wait_for_with(
        |w| {
            drawn_all(w, name)
                .iter()
                .any(|item| text_of(w, *item) == wanted)
        },
        |w| {
            let texts: Vec<String> = drawn_all(w, name)
                .iter()
                .map(|item| text_of(w, *item))
                .collect();
            format!(
                "the thread to draw {name} reading \"{wanted}\"; it reads [{}]",
                texts.join(", ")
            )
        },
    )
}

fn click_item(world: &mut World, item: ObjectId) -> Outcome {
    let brick = view(world)?;
    let (x, y) = brick.at(world, item, 0.5, 0.5)?;
    world.click_at(x, y)?;
    world.sync()
}

fn click(world: &mut World, name: &str) -> Outcome {
    let item = drawn(world, name)?;
    click_item(world, item)
}

fn slug_of(title: &str) -> String {
    title.to_lowercase().replace(' ', "-")
}

fn fake_run(world: &mut World) -> (String, String) {
    let fake = world.mc.part::<FakeStreams>();
    (fake.thread.clone(), fake.run.clone())
}

/// A subagent of the current run, as delegation.ex records it: its entity
/// and the turn item that shows it. `fields` go on both, but for its model.
fn add_subagent(world: &mut World, title: &str, fields: Value) -> Outcome<String> {
    if world.mc.part::<FakeStreams>().run.is_empty() {
        start_run(world, 0, "running")?;
    }
    let (thread, run) = fake_run(world);
    let id = format!("task-{}", slug_of(title));
    let started = iso(now() - Duration::seconds(60));
    let child = format!("thread-{}", slug_of(title));
    let mut entity = json!({"id": id, "threadId": thread, "runId": run, "childThreadId": child,
                            "prompt": "write the tax tests", "title": title, "model": "gpt-5.5",
                            "status": "running", "startedAt": started, "updatedAt": started});
    let mut item = json!({"id": format!("turn-item:subagent:{id}"), "subagentId": id,
                          "origin": "app_owned", "childThreadId": child, "title": title,
                          "prompt": "write the tax tests", "status": "running", "startedAt": started});
    if let Some(fields) = fields.as_object() {
        for (k, v) in fields {
            entity[k] = v.clone();
            if k != "model" {
                item[k] = v.clone();
            }
        }
        // A subagent with no thread names none.
        if fields.get("childThreadId") == Some(&Value::Null) {
            entity.as_object_mut().map(|e| e.remove("childThreadId"));
            item.as_object_mut().map(|i| i.remove("childThreadId"));
        }
    }
    set(world, "subagent", &id, entity)?;
    add_item(world, "subagent", item)?;
    Ok(id)
}

fn change_subagent(world: &mut World, id: &str, fields: Value) -> Outcome {
    set(world, "subagent", id, fields.clone())?;
    set(
        world,
        "turn-item",
        &format!("turn-item:subagent:{id}"),
        fields,
    )?;
    world.sync()
}

/// Subagents the agent started in one go: one provider turn.
fn start_together(world: &mut World, titles: &[&str], statuses: &[&str]) -> Outcome {
    world.set_time(now());
    start_run(world, 120, "running")?;
    for (i, title) in titles.iter().enumerate() {
        let status = statuses.get(i).copied().unwrap_or("running");
        add_subagent(
            world,
            title,
            json!({"providerTurnId": "turn-a", "status": status}),
        )?;
    }
    Ok(())
}

/// The fork's history: the open thread was forked from "Cart work" after
/// its run run-1, which ran a command; the fork carried that run over.
fn fork_with_history(world: &mut World) -> Outcome {
    list_thread(world, SOURCE, "Cart work", json!({}))?;
    change_thread_row(
        world,
        json!({"forkedFrom": {"type": "run", "threadId": SOURCE, "runId": "run-1"}}),
    )?;
    start_run(world, 300, "running")?;
    add_command(world, 1, "completed")?;
    add_item(
        world,
        "assistant_message",
        json!({"text": "The cart has a tax line."}),
    )?;
    settle_run(world, "completed", 30)
}

fn provider(id: &str, name: &str, slug: &str, model: &str) -> Value {
    json!({"instanceId": id, "driver": id, "displayName": name, "enabled": true,
           "status": "ready", "models": [{"slug": slug, "name": model}]})
}

/// "Claude · Opus" as the run's model selection, from the providers the
/// handoff steps publish.
fn selection_of(said: &str) -> Value {
    if said.split(" · ").next() == Some("Claude") {
        json!({"instanceId": "claude", "model": "claude-opus-4-6"})
    } else {
        json!({"instanceId": "codex", "model": "gpt-5.4"})
    }
}

fn start_run_on(world: &mut World, selection: Value) -> Outcome {
    let run = start_run(world, 60, "running")?;
    set(world, "run", &run, json!({"modelSelection": selection}))
}

/// The last message row of the open thread.
fn message_row(world: &mut World) -> Outcome<usize> {
    let id = format!("message:{}", world.mc.part::<FakeStreams>().run);
    let count = read(world, |t| t.row_count())?;
    match (0..count).find(|row| role(world, *row, "rowId") == id.as_str()) {
        Some(row) => Ok(row),
        None => fail!("no row for {id}; {}", describe(world)),
    }
}

fn send_message(world: &mut World, fields: Value) -> Outcome {
    let run = start_run(world, 30, "running")?;
    set(world, "turn-item", &format!("message:{run}"), fields)?;
    world.sync()
}

/// A thread the agent created in the current run.
fn create_thread(world: &mut World, title: &str) -> Outcome {
    list_thread(
        world,
        CREATED,
        if title.is_empty() {
            "New thread"
        } else {
            title
        },
        json!({}),
    )?;
    let mut fields = json!({"targetThreadId": CREATED});
    if !title.is_empty() {
        fields["title"] = json!(title);
    }
    add_item(world, "thread_created", fields)?;
    world.sync()
}

/// A row's title as it reads, with a marker's detail after it.
fn row_texts(world: &World) -> Vec<String> {
    let count = read(world, |t| t.row_count()).unwrap_or(0);
    (0..count)
        .map(|row| {
            let title = text(&role(world, row, "title"));
            let detail = text(&role(world, row, "text"));
            if detail.is_empty() || role(world, row, "kind") != "marker" {
                title
            } else {
                format!("{title} · {detail}")
            }
        })
        .collect()
}

/// The pointing card of the last subagent row, as the hover draws it.
fn pointed_card(world: &World) -> Outcome<Value> {
    let id = text(&last_of(world, "subagent", "rowId")?);
    read(world, |t| Value::Object(t.subagent_card(&id)))
}

fn card_lines(world: &World) -> Vec<String> {
    let Some(brick) = world.peek_part::<brick::Shown>().and_then(|s| s.0) else {
        return Vec::new();
    };
    let Ok(Some(card)) = brick.find_visible(world, "subagentCard") else {
        return Vec::new();
    };
    let mut lines = Vec::new();
    collect(world, card, "subagentCardLine", &mut lines);
    lines.iter().map(|line| text_of(world, *line)).collect()
}

fn opens(world: &mut World, wanted: String) -> Outcome {
    world.wait_for_with(
        |w| shown_thread(w) == wanted,
        |w| format!("{wanted} to open; {} is shown", shown_thread(w)),
    )
}

pub fn register(steps: &mut Steps) {
    register_sources(steps);
    register_markers(steps);
    register_subagents(steps);
    register_groups(steps);
}

/// The result waiting to wake the parent, where a message came from and
/// the work a fork carried over.
fn register_sources(steps: &mut Steps) {
    steps.step(
        "the user looks at the result waiting to wake the parent",
        |world, _, _| {
            let finished = {
                let fake = world.mc.part::<FakeStreams>();
                let mut finished = None;
                for entity in fake.threads.get(THREAD).into_iter().flat_map(|e| e.values()) {
                    if entity.get("subagentId").is_some() || !entity["result"].is_string() {
                        continue;
                    }
                    if entity["status"] == "completed" {
                        finished = Some(entity.clone());
                    }
                }
                finished
            };
            let Some(finished) = finished else {
                fail!("no subagent has finished");
            };
            let title = text(&finished["title"]);
            // The MC queues the parent's next run with the result as its
            // message (delegation.ex).
            let run = "run-wake";
            set(
                world,
                "message",
                "message-wake",
                json!({"id": "message-wake", "role": "user", "runId": run,
                       "notification": {"summary": format!("{title} finished"), "outcome": "completed",
                                        "workerThreadId": finished["childThreadId"], "workerTitle": title,
                                        "detail": finished["result"]}}),
            )?;
            let ordinal = {
                let fake = world.mc.part::<FakeStreams>();
                fake.ordinal += 1;
                fake.ordinal
            };
            set(
                world,
                "run",
                run,
                json!({"id": run, "ordinal": ordinal, "status": "queued", "queuePosition": 1,
                       "userMessageId": "message-wake", "requestedAt": iso(now())}),
            )?;
            world.part::<Said>().opened_from = text(&finished["childThreadId"]);
            composer_brick(world)?;
            world.wait_for_with(
                |w| {
                    w.state("turn")["waiting"]
                        .as_array()
                        .is_some_and(|waiting| waiting.len() == 1)
                },
                |w| format!("the result to wait; the turn is {}", show(&w.state("turn"))),
            )
        },
    );
    steps.step("it names the worker", |world, _, _| {
        composer_brick(world)?;
        world.wait_for("the composer to list the waiting result", |w| {
            composer_part_now(w, "queueWaiting-run-wake")
                .is_some_and(|n| w.engine().read_by_name(n, "visible") == LValue::Bool(true))
        })?;
        let Some(notice) = composer_part(world, "queueWaiting-run-wake")? else {
            fail!("the composer lists no waiting result");
        };
        let said = text_of(world, notice);
        expect!(
            said.contains("Tax tests"),
            "the waiting result reads \"{said}\""
        );
        Ok(())
    });
    steps.step(
        "the user can open the worker's thread from it",
        |world, _, _| {
            let Some(notice) = composer_part(world, "queueWaiting-run-wake")? else {
                fail!("the composer lists no waiting result");
            };
            let brick = composer_brick(world)?;
            let (x, y) = brick.at(world, notice, 0.2, 0.5)?;
            world.click_at(x, y)?;
            world.sync()?;
            let worker = key(
                world,
                &world
                    .peek_part::<Said>()
                    .map(|s| s.opened_from.clone())
                    .unwrap_or_default(),
            );
            opens(world, worker)
        },
    );

    steps.step("a scheduled task sent a message to the thread", |world, _, _| {
        send_message(
            world,
            json!({"createdBy": "system", "scheduledTaskId": "task-nightly", "text": "Check the build"}),
        )
    });
    steps.step(
        "a message was sent to the thread by automation that is not a scheduled task",
        |world, _, _| {
            // An older MC's: the task named in the text, no task id
            // (userMessage.ts LEGACY_AUTOMATION_PREFIX).
            send_message(
                world,
                json!({"createdBy": "agent",
                       "text": "[Triggered by schedule task: Nightly]\n\nCheck the build"}),
            )
        },
    );
    steps.step(
        "another agent sent a message whose thread is not known",
        |world, _, _| {
            send_message(
                world,
                json!({"createdBy": "agent", "senderThreadId": "thread-gone", "text": "The tests pass"}),
            )
        },
    );
    steps.step("the user reads the message in the thread", |world, _, _| {
        view(world)?;
        message_row(world)?;
        drawn(world, "messageAttribution")?;
        Ok(())
    });
    steps.step(&format!("the message says {Q}"), |world, c, _| {
        let row = message_row(world)?;
        let said = text(&role(world, row, "attribution"));
        expect!(said == c[0], "the message says \"{said}\"");
        draws_text(world, "messageAttribution", &c[0])?;
        let row = message_row(world)?;
        let body = text(&role(world, row, "text"));
        expect!(
            !body.starts_with("[Triggered"),
            "the message reads \"{body}\""
        );
        Ok(())
    });
    steps.step(
        "the user can open that scheduled task from it",
        |world, _, _| {
            click(world, "openAutomation")?;
            world.wait_for("the scheduled tasks to be followed", |w| {
                !w.mc.subscribers("scheduledTasks").is_empty()
            })?;
            let task = json!({"id": "task-nightly", "title": "Nightly", "prompt": "Check the build",
                              "enabled": true,
                              "schedule": {"type": "fixed_time", "timeOfDay": "09:00"},
                              "projectId": PROJECT, "threadId": THREAD,
                              "workspaceStrategy": {"type": "root"},
                              "modelSelection": {"instanceId": "codex", "model": "codex-model"},
                              "runtimeMode": "full-access", "interactionMode": "default",
                              "nextRunAt": "2099-01-01T09:00:00.000Z", "lastRunStatus": "succeeded"});
            for id in world.mc.subscribers("scheduledTasks") {
                world
                    .mc
                    .send(&json!({"t": "scheduledTasks", "id": id, "tasks": [task]}));
            }
            world.wait_for_with(
                |w| {
                    let editor = &w.state("scheduledTasks")["editor"];
                    editor["editing"] == true && editor["draft"]["title"] == "Nightly"
                },
                |w| {
                    format!(
                        "the task to open; scheduled tasks are {}",
                        show(&w.state("scheduledTasks"))
                    )
                },
            )
        },
    );
    steps.step("it cannot be opened", |world, _, _| {
        let row = message_row(world)?;
        let thread = text(&role(world, row, "thread"));
        expect!(thread.is_empty(), "the message opens {thread}");
        let before = shown_thread(world);
        click(world, "messageAttribution")?;
        let after = shown_thread(world);
        expect!(after == before, "{after} opened");
        Ok(())
    });

    // Work a fork carried over, and what HAL-C2 recorded itself.
    steps.step(
        "the timeline shows work that (the fork's source thread did before the fork|HAL-C2 recorded rather than the agent)",
        |world, _, _| {
            // A fork's history ends at the marker HAL-C2 adds, which no
            // agent wrote.
            fork_with_history(world)?;
            start_run(world, 10, "running")?;
            world.sync()
        },
    );
    steps.step(&format!("the work is marked {Q}"), |world, c, _| {
        view(world)?;
        if c[0] == "Inherited" {
            let listed = calls(world)?;
            let inherited = listed.iter().any(|call| call["visibility"] == "Inherited");
            if !inherited {
                fail!("no inherited call: {}", describe_calls(world));
            }
            return draws_text(world, "workCallVisibility", &c[0]);
        }
        let marked = text(&last_of(world, "marker", "visibility")?);
        expect!(
            marked == c[0],
            "the marker is marked \"{marked}\"; {}",
            describe(world)
        );
        draws_text(world, "markerVisibility", &c[0])
    });
    steps.step("the user opens the work", |world, _, _| {
        view(world)?;
        calls(world)?;
        click(world, "workCall")
    });
    steps.step("the work says which thread it came from", |world, _, _| {
        draws_text(world, "workCallSource", "From Cart work")
    });
}

/// Compaction, handoff, fork and created-thread markers, and interrupts.
fn register_markers(steps: &mut Steps) {
    steps.step(
        "the context compaction (is in progress|finishes|fails|is cancelled|is interrupted)",
        |world, c, _| {
            let status = match c[0].as_str() {
                "is in progress" => "running",
                "finishes" => "completed",
                "fails" => "failed",
                "is cancelled" => "cancelled",
                _ => "interrupted",
            };
            start_run(world, 0, "running")?;
            add_item(world, "compaction", json!({"status": status}))?;
            world.sync()
        },
    );
    steps.step(
        &format!("the context compaction finishes with the summary {Q}"),
        |world, c, _| {
            start_run(world, 0, "running")?;
            add_item(
                world,
                "compaction",
                json!({"summary": c[0], "beforeTokenCount": 120000, "afterTokenCount": 30000}),
            )?;
            world.sync()
        },
    );
    steps.step(
        "the context compaction finishes from (\\d+) to (\\d+) tokens",
        |world, c, _| {
            let before: i64 = c[0].parse().unwrap_or(0);
            let after: i64 = c[1].parse().unwrap_or(0);
            start_run(world, 0, "running")?;
            add_item(
                world,
                "compaction",
                json!({"beforeTokenCount": before, "afterTokenCount": after}),
            )?;
            world.sync()
        },
    );
    steps.step(
        "the context compaction finishes knowing only that it ended at (\\d+) tokens",
        |world, c, _| {
            let after: i64 = c[0].parse().unwrap_or(0);
            start_run(world, 0, "running")?;
            add_item(world, "compaction", json!({"afterTokenCount": after}))?;
            world.sync()
        },
    );
    steps.step(&format!("the marker's detail reads {Q}"), |world, c, _| {
        let detail = text(&last_of(world, "marker", "text")?);
        expect!(detail == c[0], "the marker's detail reads \"{detail}\"");
        Ok(())
    });

    // Handoff.
    steps.step(
        &format!("the thread ran on {Q} and then on {Q}"),
        |world, c, _| {
            publish_providers(
                &mut world.mc,
                vec![
                    provider("claude", "Claude", "claude-opus-4-6", "Opus"),
                    provider("codex", "Codex", "gpt-5.4", "GPT"),
                ],
            );
            world.sync()?;
            start_run_on(world, selection_of(&c[0]))?;
            add_item(
                world,
                "assistant_message",
                json!({"text": "Done on the first."}),
            )?;
            settle_run(world, "completed", 20)?;
            world.part::<Said>().note = c[1].clone();
            world.sync()
        },
    );
    steps.step(&format!("the context is handed to {Q}"), |world, c, _| {
        let to = selection_of(&c[0]);
        start_run_on(world, to.clone())?;
        add_item(
            world,
            "handoff",
            json!({"fromProviderInstanceIds": ["claude"], "toProviderInstanceId": to["instanceId"]}),
        )?;
        world.sync()
    });
    steps.step(
        &format!("the marker shows {Q} and {Q} with their models"),
        |world, c, _| {
            view(world)?;
            let ends = last_of(world, "marker", "handoff")?;
            let ends = ends.as_array().cloned().unwrap_or_default();
            let named = |end: &Value| text(&end["provider"]);
            let model = |end: &Value| text(&end["model"]);
            expect!(
                ends.len() == 2
                    && named(&ends[0]) == c[0]
                    && named(&ends[1]) == c[1]
                    && !model(&ends[0]).is_empty()
                    && !model(&ends[1]).is_empty(),
                "the handoff's ends are {}",
                show(&Value::Array(ends.clone()))
            );
            draws_text(world, "handoffEnd", &c[0])?;
            draws_text(world, "handoffEnd", &format!("→ {}", c[1]))
        },
    );
    steps.step(
        "pointing at either names its provider and model",
        |world, _, _| {
            let ends = last_of(world, "marker", "handoff")?;
            let tips: Vec<String> = ends
                .as_array()
                .map(|ends| ends.iter().map(|end| text(&end["tooltip"])).collect())
                .unwrap_or_default();
            expect!(
                tips == ["Claude · Opus", "Codex · GPT"],
                "pointing names {}",
                tips.join(", ")
            );
            Ok(())
        },
    );
    steps.step("the context handoff fails", |world, _, _| {
        start_run(world, 0, "running")?;
        add_item(
            world,
            "handoff",
            json!({"status": "failed", "toProviderInstanceId": "codex"}),
        )?;
        world.sync()
    });
    steps.step(
        &format!("the marker {Q} is shown as a failure"),
        |world, c, _| {
            view(world)?;
            let row = last_row_of(world, "marker")?;
            let title = text(&role(world, row, "title"));
            let status = text(&role(world, row, "status"));
            expect!(
                title == c[0] && status == "failed",
                "the marker \"{title}\" is {status}"
            );
            draws_text(world, "markerTitle", &c[0])?;
            let Some(drawn_title) = drawn_all(world, "markerTitle")
                .into_iter()
                .filter(|item| text_of(world, *item) == c[0])
                .last()
            else {
                fail!("no marker title reads \"{}\"", c[0]);
            };
            let engine = world.engine();
            let mut error = LValue::Undefined;
            let mut up = Some(drawn_title);
            while let Some(item) = up {
                let found = engine.read_by_name(item, "errorColor");
                if !matches!(found, LValue::Undefined | LValue::Null) {
                    error = found;
                    break;
                }
                up = engine.visual_parent(item);
            }
            let color = engine.read_by_name(drawn_title, "color");
            expect!(
                !matches!(error, LValue::Undefined) && color == error,
                "the marker is drawn in {color:?}, not the error colour {error:?}"
            );
            Ok(())
        },
    );

    // Fork markers.
    steps.step("this thread was forked from another", |world, _, _| {
        fork_with_history(world)
    });
    steps.step(
        "the fork's history loaded before the thread said where it was forked from",
        |world, _, _| {
            start_run(world, 300, "running")?;
            add_command(world, 1, "completed")?;
            add_item(
                world,
                "assistant_message",
                json!({"text": "The cart has a tax line."}),
            )?;
            settle_run(world, "completed", 30)?;
            list_thread(world, SOURCE, "Cart work", json!({}))?;
            change_thread_row(
                world,
                json!({"forkedFrom": {"type": "run", "threadId": SOURCE, "runId": "run-1"}}),
            )
        },
    );
    steps.step("another thread was forked from this one", |world, _, _| {
        list_thread(world, "thread-2", "Cart fork", json!({}))?;
        start_run(world, 0, "running")?;
        add_item(world, "fork", json!({"targetThreadId": "thread-2"}))?;
        world.sync()
    });
    steps.step(
        &format!("the user can open the other thread with {Q}"),
        |world, c, _| {
            view(world)?;
            let action = text(&last_of(world, "marker", "action")?);
            let other = text(&last_of(world, "marker", "thread")?);
            expect!(action == c[0], "the marker offers \"{action}\"");
            draws_text(world, "markerAction", &c[0])?;
            click(world, "markerAction")?;
            let wanted = key(world, &other);
            opens(world, wanted)
        },
    );

    // Created threads.
    steps.step(
        &format!("the agent creates the thread {Q}"),
        |world, c, _| {
            start_run(world, 0, "running")?;
            create_thread(world, &c[0])
        },
    );
    steps.step(
        "the agent creates a thread that has no title",
        |world, _, _| {
            start_run(world, 0, "running")?;
            create_thread(world, "")
        },
    );
    steps.step(&format!("the timeline shows {Q}"), |world, c, _| {
        let texts = row_texts(world);
        expect!(
            texts.contains(&c[0]),
            "the timeline shows {}",
            texts.join(" | ")
        );
        Ok(())
    });
    steps.step(&format!("the user can open it with {Q}"), |world, c, _| {
        view(world)?;
        let action = text(&last_of(world, "marker", "action")?);
        expect!(action == c[0], "the marker offers \"{action}\"");
        draws_text(world, "markerAction", &c[0])?;
        click(world, "markerAction")?;
        let wanted = key(world, CREATED);
        opens(world, wanted)
    });
    steps.step(
        &format!("the agent created the thread {Q} and the timeline shows it as a resource"),
        |world, c, _| {
            start_run(world, 60, "running")?;
            create_thread(world, &c[0])?;
            add_item(
                world,
                "assistant_message",
                json!({"text": "I made a thread for the tests."}),
            )?;
            settle_run(world, "completed", 30)?;
            world.sync()
        },
    );
    steps.step(&format!("the card is titled {Q}"), |world, c, _| {
        view(world)?;
        let title = text(&last_of(world, "resource", "title")?);
        expect!(title == c[0], "the card is titled \"{title}\"");
        draws_text(world, "resourceTitle", &c[0])
    });
    steps.step(
        &format!("the user can open the thread with {Q}"),
        |world, c, _| {
            view(world)?;
            let action = text(&last_of(world, "resource", "action")?);
            expect!(action == c[0], "the card offers \"{action}\"");
            draws_text(world, "resourceAction", &c[0])?;
            click(world, "resourceAction")?;
            let wanted = key(world, CREATED);
            opens(world, wanted)
        },
    );

    // Interrupts.
    steps.step(
        &format!("the user interrupts the running turn with the message {Q}"),
        |world, c, _| {
            world.set_time(now());
            start_run(world, 60, "running")?;
            add_command(world, 1, "running")?;
            add_item(world, "run_interrupt_request", json!({"message": c[0]}))?;
            world.sync()
        },
    );
    steps.step(
        &format!("the timeline shows {Q} and the time"),
        |world, c, _| {
            let listed = calls(world)?;
            let found = listed.iter().any(|call| {
                format!("{} · {}", text(&call["label"]), text(&call["detail"])) == c[0]
                    && !text(&call["time"]).is_empty()
            });
            if !found {
                fail!("the timeline lists {}", describe_calls(world));
            }
            Ok(())
        },
    );
    steps.step("the run stops", |world, _, _| {
        let message = "Stopped at the user's request".to_owned();
        world.part::<Said>().run_message = message.clone();
        add_item(world, "run_interrupt_result", json!({"message": message}))?;
        settle_run(world, "interrupted", 40)?;
        world.sync()
    });
    steps.step(
        &format!("the timeline shows {Q} with the run's message"),
        |world, c, _| {
            let message = world.part::<Said>().run_message.clone();
            let listed = calls(world)?;
            let found = listed
                .iter()
                .any(|call| call["label"] == c[0].as_str() && call["detail"] == message.as_str());
            if !found {
                fail!("the timeline lists {}", describe_calls(world));
            }
            Ok(())
        },
    );
}

/// A subagent's row and its pointing card.
fn register_subagents(steps: &mut Steps) {
    steps.step(
        &format!(
            "the agent has a subagent that is (running|completed) and has (no model reported|the model {Q}|a result of (\\d+) characters|its own project|its own branch, other than the parent's|its own worktree with no branch)"
        ),
        |world, c, _| {
            world.set_time(now());
            start_run(world, 120, "running")?;
            let mut fields = json!({"status": c[0], "startedAt": iso(now() - Duration::seconds(42))});
            let mut child = json!({});
            let detail = c[1].as_str();
            if detail == "no model reported" {
                fields["model"] = json!("");
            } else if detail.starts_with("the model") {
                fields["model"] = json!(c[2]);
            } else if detail.starts_with("a result") {
                let length: usize = c[3].parse().unwrap_or(0);
                let result: String = (0..length)
                    .map(|i| char::from(b'a' + (i % 26) as u8))
                    .collect();
                fields["result"] = json!(result);
                fields["completedAt"] = json!(iso(now()));
                world.part::<Said>().note = result;
            } else if detail == "its own project" {
                let project = json!({"id": "billing", "title": "Billing", "workspaceRoot": "/work/billing",
                                     "scripts": [], "createdAt": "2026-09-01T09:00:00Z",
                                     "updatedAt": "2026-09-01T09:00:00Z"});
                world.mc.projects.insert("billing".into(), project.clone());
                world.mc.send_row_of("billing", &project, "project");
                child["projectId"] = json!("billing");
            } else if detail.starts_with("its own branch") {
                change_thread_row(world, json!({"branch": "main"}))?;
                child["branch"] = json!("tax-tests");
            } else {
                child["worktreePath"] = json!("/work/shop/.worktrees/tax-tests");
            }
            list_thread(world, CREATED, "Tax tests", child)?;
            add_subagent(world, "Tax tests", fields)?;
            world.sync()
        },
    );
    steps.step(
        "the user points at the subagent in the parent's timeline",
        |world, _, _| {
            let row = drawn(world, "subagentRow")?;
            let brick = view(world)?;
            let (x, y) = brick.at(world, row, 0.5, 0.5)?;
            world.hover_at(x, y + 4.0)?;
            world.hover_at(x, y)?;
            // The card shows after its delay.
            world.advance(600)?;
            world.wait_for_with(
                |w| !card_lines(w).is_empty(),
                |w| {
                    format!(
                        "the subagent's card to show; the model gives {}",
                        pointed_card(w).map(|c| show(&c)).unwrap_or_default()
                    )
                },
            )
        },
    );
    steps.step(
        "the card shows (\"Not reported\" in place of the model|the model's name and how long it has worked|its first 280 characters followed by an ellipsis|the subagent's project|the subagent's branch|the worktree's folder name)",
        |world, c, _| {
            let card = pointed_card(world)?;
            let (field, wanted) = if c[0].starts_with("\"Not reported\"") {
                ("model", "Not reported".to_owned())
            } else if c[0].starts_with("the model's") {
                expect!(card["elapsed"] == "42s", "the card is {}", show(&card));
                ("model", "model-b".to_owned())
            } else if c[0].starts_with("its first") {
                let note = world.part::<Said>().note.clone();
                let head: String = note.chars().take(280).collect();
                ("preview", format!("{head}…"))
            } else if c[0] == "the subagent's project" {
                ("project", "Billing".to_owned())
            } else {
                ("place", "tax-tests".to_owned())
            };
            expect!(
                card[field] == wanted.as_str(),
                "the card is {}",
                show(&card)
            );
            world.wait_for_with(
                |w| card_lines(w).contains(&wanted),
                |w| {
                    format!(
                        "the card to read \"{wanted}\"; it reads {}",
                        card_lines(w).join(" | ")
                    )
                },
            )
        },
    );

    // Subagent rows.
    steps.step(
        &format!("a subagent ended with no answer and the note {Q}"),
        |world, c, _| {
            world.part::<Said>().note = c[0].clone();
            add_subagent(
                world,
                "Tax tests",
                json!({"status": "completed", "result": c[0], "completedAt": iso(now())}),
            )?;
            world.sync()
        },
    );
    steps.step(
        &format!("the subagent row shows {Q} and not that note"),
        |world, c, _| {
            let label = text(&last_of(world, "subagent", "statusLabel")?);
            let shown = text(&last_of(world, "subagent", "text")?);
            let note = world.part::<Said>().note.clone();
            expect!(
                label == c[0] && !shown.contains(&note),
                "the row shows \"{label}\" and \"{shown}\""
            );
            drawn(world, "subagentRow")?;
            Ok(())
        },
    );
    steps.step(
        &format!("the agent has a subagent that reported the progress {Q}"),
        |world, c, _| {
            add_subagent(world, "Tax tests", json!({"progress": c[0]}))?;
            world.sync()
        },
    );
    steps.step(&format!("the row shows {Q} and {Q}"), |world, c, _| {
        let label = text(&last_of(world, "subagent", "statusLabel")?);
        let shown = text(&last_of(world, "subagent", "text")?);
        expect!(
            label == c[0] && shown == c[1],
            "the row shows \"{label}\" and \"{shown}\""
        );
        drawn(world, "subagentRow")?;
        Ok(())
    });
    steps.step(
        &format!("the subagent finishes with the result {Q}"),
        |world, c, _| {
            change_subagent(
                world,
                "task-tax-tests",
                json!({"status": "completed", "result": c[0], "completedAt": iso(now())}),
            )
        },
    );
    steps.step(
        &format!("the row shows {Q} instead of the progress"),
        |world, c, _| {
            let shown = text(&last_of(world, "subagent", "text")?);
            expect!(shown == c[0], "the row shows \"{shown}\"");
            Ok(())
        },
    );
    steps.step(
        "the agent has a subagent that has not started a thread",
        |world, _, _| {
            add_subagent(world, "Tax tests", json!({"childThreadId": null}))?;
            world.sync()
        },
    );
    steps.step("its row is shown with its status", |world, _, _| {
        let label = text(&last_of(world, "subagent", "statusLabel")?);
        expect!(label == "Working", "the row shows \"{label}\"");
        drawn(world, "subagentRow")?;
        Ok(())
    });
    steps.step("the row cannot be opened", |world, _, _| {
        let thread = text(&last_of(world, "subagent", "thread")?);
        expect!(thread.is_empty(), "the row opens {thread}");
        let before = shown_thread(world);
        click(world, "subagentRow")?;
        let after = shown_thread(world);
        expect!(after == before, "{after} opened");
        Ok(())
    });

    // The agents-working banner.
    steps.step("the Agents tab is closed", |world, _, _| {
        view(world)?;
        world.sync()?;
        let active = text(&world.state("panel")["activeId"]);
        expect!(active != "agents", "the Agents tab is open");
        Ok(())
    });
    steps.step(
        "the user chooses View on the agents-working banner",
        |world, _, _| {
            drawn(world, "agentsBanner")?;
            click(world, "agentsBannerView")
        },
    );
    steps.step("the Agents tab opens", |world, _, _| {
        world.wait_for_with(
            |w| w.state("panel")["activeId"] == "agents",
            |w| {
                format!(
                    "the Agents tab to open; the panel is {}",
                    show(&w.state("panel"))
                )
            },
        )
    });
}

/// Groups of subagents started together.
fn register_groups(steps: &mut Steps) {
    steps.step(
        &format!("the agent started the subagents {Q}, {Q} and {Q} together"),
        |world, c, _| {
            start_together(world, &[&c[0], &c[1], &c[2]], &[])?;
            world.sync()
        },
    );
    steps.step(
        &format!("the agent started the subagents {Q} and {Q} together"),
        |world, c, _| {
            start_together(world, &[&c[0], &c[1]], &[])?;
            world.sync()
        },
    );
    steps.step(
        "the agent started five subagents together",
        |world, _, _| {
            start_together(world, &["Tax tests", "Docs", "Lint", "Types", "Build"], &[])?;
            world.sync()
        },
    );
    steps.step(
        "the agent started a group of subagents of which (.+)",
        |world, c, _| {
            let statuses: &[&str] = match c[0].as_str() {
                "two are working and one is done" => &["running", "running", "completed"],
                "one is waiting for the user and one is not started yet" => &["waiting", "pending"],
                "two are done, one failed and one was stopped" => {
                    &["completed", "completed", "failed", "cancelled"]
                }
                "one is working, one is done, one failed, one stopped, one idle" => {
                    &["running", "completed", "failed", "cancelled", "idle"]
                }
                other => fail!("no such group: {other}"),
            };
            let titles: Vec<String> = (1..=statuses.len()).map(|i| format!("Agent {i}")).collect();
            let titles: Vec<&str> = titles.iter().map(String::as_str).collect();
            start_together(world, &titles, statuses)?;
            world.sync()
        },
    );
    steps.step(&format!("the group reads {Q}"), |world, c, _| {
        view(world)?;
        let summary = text(&last_of(world, "subagents", "text")?);
        expect!(summary == c[0], "the group reads \"{summary}\"");
        draws_text(world, "subagentGroupSummary", &c[0])
    });
    steps.step(
        &format!(
            "the timeline shows one entry reading {Q} with how many are working, done, failed, stopped or idle"
        ),
        |world, c, _| {
            view(world)?;
            let groups = rows_of(world, "subagents");
            expect!(
                groups.len() == 1 && rows_of(world, "subagent").is_empty(),
                "{}",
                describe(world)
            );
            let title = text(&role(world, groups[0], "title"));
            let summary = text(&role(world, groups[0], "text"));
            expect!(
                title == c[0] && summary == "3 working",
                "the entry reads \"{title}\", \"{summary}\""
            );
            draws_text(world, "subagentGroupTitle", &c[0])?;
            draws_text(world, "subagentGroupSummary", &summary)
        },
    );
    steps.step(
        "the rows of the subagents are shown only once the user opens the entry",
        |world, _, _| {
            view(world)?;
            world.sync()?;
            expect!(
                drawn_all(world, "subagentRow").is_empty(),
                "the rows are shown before the entry opens"
            );
            click(world, "subagentGroup")?;
            world.wait_for_with(
                |w| rows_of(w, "subagent").len() == 3 && drawn_all(w, "subagentRow").len() == 3,
                |w| format!("the rows to show; {}", describe(w)),
            )
        },
    );
    steps.step(
        "the entry stays open or closed the way the user left it while the thread is open",
        |world, _, _| {
            change_subagent(
                world,
                "task-docs",
                json!({"status": "completed", "completedAt": iso(now())}),
            )?;
            expect!(
                last_of(world, "subagents", "expanded")? == true
                    && rows_of(world, "subagent").len() == 3,
                "the entry closed as a subagent finished; {}",
                describe(world)
            );
            click(world, "subagentGroup")?;
            change_subagent(
                world,
                "task-lint",
                json!({"status": "completed", "completedAt": iso(now())}),
            )?;
            expect!(
                last_of(world, "subagents", "expanded")? != true
                    && rows_of(world, "subagent").is_empty(),
                "the entry opened as a subagent finished; {}",
                describe(world)
            );
            world.wait_for("the rows to hide", |w| {
                drawn_all(w, "subagentRow").is_empty()
            })
        },
    );
    steps.step(
        &format!("{Q} started at (\\d\\d:\\d\\d:\\d\\d) and finished at (\\d\\d:\\d\\d:\\d\\d)"),
        |world, c, _| {
            change_subagent(
                world,
                &format!("task-{}", slug_of(&c[0])),
                json!({"status": "completed", "startedAt": format!("2026-09-23T{}Z", c[1]),
                       "completedAt": format!("2026-09-23T{}Z", c[2])}),
            )
        },
    );
    steps.step(
        &format!("{Q} started at (\\d\\d:\\d\\d:\\d\\d) and is still working"),
        |world, c, _| {
            change_subagent(
                world,
                &format!("task-{}", slug_of(&c[0])),
                json!({"status": "running", "startedAt": format!("2026-09-23T{}Z", c[1])}),
            )
        },
    );
    steps.step("a second passes while the group works", |world, _, _| {
        // The model's own once-a-second timer, without waiting a second
        // for it.
        let ticking = read(world, |t| t.spans_ticking())?;
        expect!(
            ticking,
            "the group's span is not moving; {}",
            describe(world)
        );
        let next = world.now() + Duration::seconds(1);
        world.set_time(next);
        let obj = timeline_object(world)?;
        TimelineModel::update(world.engine(), obj, |t| t.tick_spans());
        world.pump()
    });
    steps.step("the group's span reads (.+) on screen", |world, c, _| {
        draws_text(world, "subagentGroupSpan", &c[0])
    });
    steps.step(
        "the span stands still once every subagent of the group has finished",
        |world, _, _| {
            for title in ["Tax tests", "Docs"] {
                let at = iso(world.now());
                change_subagent(
                    world,
                    &format!("task-{}", slug_of(title)),
                    json!({"status": "completed", "completedAt": at}),
                )?;
            }
            let ticking = read(world, |t| t.spans_ticking())?;
            expect!(
                !ticking,
                "the group's span still moves; {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("both have finished but the end time of {Q} was not reported"),
        |world, c, _| {
            for title in ["Tax tests", "Docs"] {
                let completed = if title == c[0] {
                    Value::Null
                } else {
                    json!(iso(now()))
                };
                change_subagent(
                    world,
                    &format!("task-{}", slug_of(title)),
                    json!({"status": "completed", "completedAt": completed}),
                )?;
            }
            Ok(())
        },
    );
    steps.step("the user looks at the group", |world, _, _| {
        drawn(world, "subagentGroup")?;
        Ok(())
    });
    steps.step("the group shows a span of (.+)", |world, c, _| {
        view(world)?;
        let span = text(&last_of(world, "subagents", "span")?);
        expect!(span == c[0], "the group shows a span of \"{span}\"");
        draws_text(world, "subagentGroupSpan", &c[0])
    });
    steps.step("the group shows no span", |world, _, _| {
        view(world)?;
        world.sync()?;
        let span = text(&last_of(world, "subagents", "span")?);
        expect!(
            span.is_empty() && drawn_all(world, "subagentGroupSpan").is_empty(),
            "the group shows a span of \"{span}\""
        );
        Ok(())
    });
    steps.step(
        &format!("it shows the avatars of the first three and {Q}"),
        |world, c, _| {
            view(world)?;
            let avatars = last_of(world, "subagents", "avatars")?;
            let titles: Vec<String> = avatars
                .as_array()
                .map(|a| a.iter().map(|avatar| text(&avatar["title"])).collect())
                .unwrap_or_default();
            expect!(
                titles == ["Tax tests", "Docs", "Lint"],
                "the avatars are of {}",
                titles.join(", ")
            );
            world.wait_for_with(
                |w| drawn_all(w, "subagentAvatar").len() == 3,
                |w| {
                    format!(
                        "three avatars; {} are drawn",
                        drawn_all(w, "subagentAvatar").len()
                    )
                },
            )?;
            draws_text(world, "subagentMore", &c[0])
        },
    );
}
