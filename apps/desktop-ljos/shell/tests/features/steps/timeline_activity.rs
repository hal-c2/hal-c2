//! What the timeline makes of the agent's work once a turn settles
//! (features/timeline/tool-calls.feature, streaming.feature,
//! approvals-and-questions.feature): groups of calls that read as a summary
//! and open into their calls, an ACP agent's reads and searches, a turn the
//! user stopped here, a long message of the user's, and several approvals
//! answered one at a time. The stream is stream.rs's; the rows are read from
//! the timeline and from the Timeline brick drawing it. desktop-qt's
//! TimelineActivitySteps.cpp.

use chrono::Duration;
use ljos::prelude::{ObjectId, Value as Js};
use serde_json::{Value, json};

use super::stream::{
    FakeStreams, PROJECT, add_command, add_item, change, describe, iso, now, role, set, settle_run,
    start_run, timeline_object,
};
use super::timeline::{last_row_of, rows_of};
use super::turn::start_working_turn;
use crate::brick::{self, Brick};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

const SEND: &str = "mcp__hal-c2__hal_c2_thread_send";

fn entries(world: &World) -> Outcome<Vec<Value>> {
    let row = last_row_of(world, "work")?;
    Ok(role(world, row, "entries")
        .as_array()
        .cloned()
        .unwrap_or_default())
}

fn summary(world: &World) -> Outcome<String> {
    let row = last_row_of(world, "work")?;
    Ok(text(&role(world, row, "summary")))
}

/// The open thread's timeline as the Timeline brick draws it.
fn timeline_brick(world: &mut World) -> Outcome<Brick> {
    if world.part::<brick::Shown>().0.is_none() {
        let brick = Brick::new(
            world,
            "import QtQuick\nimport HalC2.Bricks\nTimeline {}\n",
            820.0,
            1400.0,
        )?;
        world.part::<brick::Shown>().0 = Some(brick);
        let timeline = timeline_object(world)?;
        let Some(root) = brick.root(world) else {
            fail!("the timeline brick has no root");
        };
        brick.write(world, root, "model", Js::Object(timeline))?;
    }
    brick::shown(world)
}

/// The visible item named `name` the brick drew last.
fn drawn(world: &mut World, name: &str) -> Outcome<ObjectId> {
    let brick = timeline_brick(world)?;
    let wanted = format!("the timeline to draw {name}");
    world.wait_for(&wanted, |w| {
        brick.find_visible(w, name).ok().flatten().is_some()
    })?;
    match brick.find_visible(world, name)? {
        Some(item) => Ok(item),
        None => fail!("{name} went away"),
    }
}

fn click(world: &mut World, item: ObjectId) -> Outcome {
    let brick = timeline_brick(world)?;
    let (x, y) = brick.at(world, item, 0.3, 0.5)?;
    world.click_at(x, y)
}

fn number(world: &World, brick: Brick, item: ObjectId, name: &str) -> f64 {
    brick.text_of(world, item, name).parse().unwrap_or(0.0)
}

fn send_message(world: &mut World, thread: &str, n: i64, failed: bool) -> Outcome {
    let mut fields = json!({"toolName": SEND,
                            "input": {"threadId": thread, "message": "Check the tax line"}});
    // An MCP error comes back as the call's result, the call itself completed.
    fields["output"] = if failed {
        json!({"isError": true, "content": [{"type": "text", "text": "thread not found"}]})
    } else {
        json!({"structuredContent": {"threadId": thread, "messageId": format!("message-{n}")}})
    };
    add_item(world, "dynamic_tool", fields)?;
    Ok(())
}

/// The turn's reply, and its end: the work folds behind how long it took.
fn finish_turn(world: &mut World) -> Outcome {
    add_item(world, "assistant_message", json!({"text": "Done."}))?;
    settle_run(world, "completed", 30)
}

fn toggle(world: &World, row_id: &str) -> Outcome {
    let timeline = timeline_object(world)?;
    world
        .engine()
        .invoke_by_name(timeline, "toggle", &[Js::from(row_id)])
        .map_err(|e| crate::harness::Failure(format!("toggle: {e:?}")))?;
    Ok(())
}

fn open_fold(world: &mut World) -> Outcome {
    let fold = last_row_of(world, "fold")?;
    if role(world, fold, "expanded") != json!(true) {
        toggle(world, &text(&role(world, fold, "rowId")))?;
    }
    Ok(())
}

fn approvals(world: &World) -> usize {
    world.state("turn")["approvals"]
        .as_array()
        .map_or(0, Vec::len)
}

fn toggle_group(world: &mut World) -> Outcome {
    // The line the user clicks: the group's summary.
    let item = drawn(world, "workGroupToggle")?;
    click(world, item)
}

// What the group's line reads: its summary, or a lone call's own label.
fn group_line(world: &World) -> Outcome<String> {
    let read = summary(world)?;
    let shown = entries(world)?;
    Ok(if !read.is_empty() || shown.len() != 1 {
        read
    } else {
        text(&shown[0]["label"])
    })
}

/// The latest call the group shows.
fn last_call(world: &World) -> Outcome<Value> {
    match entries(world)?.pop() {
        Some(call) => Ok(call),
        None => fail!("the group shows no call; {}", describe(world)),
    }
}

/// A "quoted" step argument whose \" and \\ are escapes, as an example
/// table writes a command.
const ESCAPED: &str = r#""((?:[^"\\]|\\.)*)""#;

fn unescaped(quoted: &str) -> String {
    let mut out = String::new();
    let mut chars = quoted.chars();
    while let Some(ch) = chars.next() {
        out.push(if ch == '\\' {
            chars.next().unwrap_or(ch)
        } else {
            ch
        });
    }
    out
}

/// A call to one of HAL-C2's own tools, as Codex names it, that returned
/// `result`.
fn hal_c2_call(tool: &str, input: Value, result: Value) -> Value {
    json!({"toolName": format!("mcp__hal-c2__{tool}"), "input": input,
           "output": {"structuredContent": result}})
}

/// A call through a browser, the computer or an integration, as the MC
/// names it (codex/tool_presentation.ex).
fn sourced_call(key: &str, name: &str, kind: &str) -> Value {
    json!({"toolName": format!("mcp__{key}__navigate"),
           "toolSource": {"key": key, "name": name, "kind": kind}})
}

/// The calls an activity group holds, by how a scenario describes them.
fn add_calls(world: &mut World, calls: &str) -> Outcome {
    fn tool(world: &mut World, fields: Value) -> Outcome {
        add_item(world, "dynamic_tool", fields).map(drop)
    }
    fn edit(world: &mut World, file: &str) -> Outcome {
        add_item(world, "file_change", json!({"fileName": file})).map(drop)
    }
    fn web(world: &mut World) -> Outcome {
        add_item(world, "web_search", json!({"patterns": ["vat rates"]})).map(drop)
    }
    fn thought(world: &mut World) -> Outcome {
        add_item(world, "reasoning", json!({"text": ""})).map(drop)
    }
    fn integration(world: &mut World, name: &str) -> Outcome {
        tool(
            world,
            sourced_call(&name.to_lowercase(), name, "integration"),
        )
    }
    fn hal(world: &mut World, name: &str, input: Value, result: Value) -> Outcome {
        tool(world, hal_c2_call(name, input, result))
    }
    fn command(world: &mut World, n: i64) -> Outcome {
        add_command(world, n, "completed").map(drop)
    }
    // A thought, which a summary does not count, keeps a lone call from
    // reading as itself.
    let (thinks, calls) = match calls.strip_prefix("a thought and ") {
        Some(rest) => (true, rest),
        None => (false, calls),
    };
    let none = json!({});
    let w = world;
    let add = |w: &mut World| -> Outcome {
        match calls {
            "one file read" => add_item(
                w,
                "file_search",
                json!({"pattern": "cart.ts", "results": [{"fileName": "cart.ts"}]}),
            )
            .map(drop),
            "edits to three different files" => {
                for file in ["src/a.ts", "src/b.ts", "src/c.ts"] {
                    edit(w, file)?;
                }
                Ok(())
            }
            "two edits to the same file" => {
                edit(w, "src/cart.ts")?;
                edit(w, "src/cart.ts")
            }
            "one command" => command(w, 1),
            "two web searches" => {
                web(w)?;
                web(w)
            }
            "one search of the project's code" => add_item(
                w,
                "file_search",
                json!({"pattern": "taxLine", "results": []}),
            )
            .map(drop),
            "three browser calls" => {
                for _ in 0..3 {
                    hal(
                        w,
                        "preview_open",
                        json!({"url": "http://localhost:3000"}),
                        none.clone(),
                    )?;
                }
                Ok(())
            }
            "two device controls" => {
                for _ in 0..2 {
                    hal(w, "device_screenshot", json!({}), none.clone())?;
                }
                Ok(())
            }
            "one tool with no more specific kind" => tool(w, json!({"toolName": "lookup_rates"})),
            "two progress updates" => {
                add_item(w, "system_notice", json!({"message": "Indexing"}))?;
                add_item(w, "system_notice", json!({"message": "Indexed"})).map(drop)
            }
            "one thread the agent created" => hal(
                w,
                "create_threads",
                json!({}),
                json!({"threads": [{"threadId": "thread-9"}]}),
            ),
            "two links of a pull request and one check" => {
                for n in 1..=2 {
                    hal(
                        w,
                        "link_pull_request",
                        json!({"url": format!("https://github.com/o/r/pull/{n}")}),
                        none.clone(),
                    )?;
                }
                hal(w, "list_thread_pull_requests", json!({}), none.clone())
            }
            "one pull request unlinked" => hal(
                w,
                "unlink_pull_request",
                json!({"url": "https://github.com/o/r/pull/1"}),
                none.clone(),
            ),
            "two checks of the linked pull requests" => {
                for _ in 0..2 {
                    hal(w, "list_thread_pull_requests", json!({}), none.clone())?;
                }
                Ok(())
            }
            "two thoughts and one command" => {
                thought(w)?;
                thought(w)?;
                command(w, 1)
            }
            "one thought" => thought(w),
            "three thoughts" => {
                for _ in 0..3 {
                    thought(w)?;
                }
                Ok(())
            }
            "two calls through the \"Chrome\" integration and one command" => {
                integration(w, "Chrome")?;
                integration(w, "Chrome")?;
                command(w, 1)
            }
            "calls through the \"Chrome\" and \"Slack\" integrations" => {
                integration(w, "Chrome")?;
                integration(w, "Slack")
            }
            "calls through the \"Chrome\", \"Slack\" and \"Linear\" integrations" => {
                integration(w, "Chrome")?;
                integration(w, "Slack")?;
                integration(w, "Linear")
            }
            "calls through the built-in browser and computer controls" => {
                tool(w, sourced_call("browser", "Browser", "browser"))?;
                tool(w, sourced_call("computer", "Computer Use", "computer"))
            }
            "commands, file changes and four web searches" => {
                command(w, 1)?;
                command(w, 2)?;
                edit(w, "src/cart.ts")?;
                for _ in 0..4 {
                    web(w)?;
                }
                Ok(())
            }
            "two tasks delegated to subagents" => {
                for n in 1..=2 {
                    hal(
                        w,
                        "delegate_task",
                        json!({}),
                        json!({"taskId": format!("task-{n}")}),
                    )?;
                }
                Ok(())
            }
            "the same task cancelled twice" => {
                for _ in 0..2 {
                    hal(w, "task_cancel", json!({"taskId": "task-1"}), none.clone())?;
                }
                Ok(())
            }
            "one thread read and the same thread read again" => {
                for _ in 0..2 {
                    hal(
                        w,
                        "hal_c2_thread_read",
                        json!({"threadId": "thread-2"}),
                        none.clone(),
                    )?;
                }
                Ok(())
            }
            "one wait on a thread" => hal(
                w,
                "hal_c2_thread_wait",
                json!({"threadId": "thread-2"}),
                none.clone(),
            ),
            "one scheduled task created" => hal(
                w,
                "schedule_task",
                json!({}),
                json!({"scheduledTaskId": "schedule-1"}),
            ),
            "one scheduled task run on request" => hal(
                w,
                "run_scheduled_task_now",
                json!({"scheduledTaskId": "schedule-1"}),
                none.clone(),
            ),
            "a queued message edited and another reordered" => {
                hal(
                    w,
                    "hal_c2_queue_edit",
                    json!({"queuedRunId": "queued-1"}),
                    none.clone(),
                )?;
                hal(
                    w,
                    "hal_c2_queue_reorder",
                    json!({"queuedRunId": "queued-2"}),
                    none.clone(),
                )
            }
            "a pending question answered" => hal(
                w,
                "hal_c2_pending_request_respond",
                json!({"requestId": "request-1"}),
                none.clone(),
            ),
            "one handoff to a worktree" => hal(
                w,
                "hal_c2_worktree_handoff",
                json!({"worktreePath": "/work/shop-tax"}),
                none.clone(),
            ),
            "one project registered and one cloned" => {
                hal(
                    w,
                    "hal_c2_project_create",
                    json!({}),
                    json!({"id": "project-2"}),
                )?;
                hal(
                    w,
                    "hal_c2_project_clone",
                    json!({"cwd": "/work/rates"}),
                    none.clone(),
                )
            }
            "two attachments sent to one thread" => hal(
                w,
                "hal_c2_thread_send_attachments",
                json!({"threadId": "thread-2", "attachments": ["a.png", "b.png"]}),
                json!({"messageId": "message-1"}),
            ),
            "two attempts to send a message that both failed" => {
                // Neither said which thread it was for.
                for _ in 0..2 {
                    tool(
                        w,
                        json!({"toolName": SEND, "status": "failed",
                               "input": {"message": "Check the tax line"}}),
                    )?;
                }
                Ok(())
            }
            "a command that exited with a failure" => {
                command(w, 1)?;
                add_item(
                    w,
                    "command_execution",
                    json!({"input": "bun lint", "exitCode": 2}),
                )
                .map(drop)
            }
            _ => fail!("no calls described as \"{calls}\""),
        }
    };
    if thinks {
        thought(w)?;
    }
    add(w)
}

/// A HAL-C2 tool call named `name`, in a settled turn whose work is open.
fn call_tool(world: &mut World, name: &str) -> Outcome {
    start_run(world, 30, "running")?;
    add_item(
        world,
        "dynamic_tool",
        json!({"toolName": name, "input": {"threadId": "thread-2"}}),
    )?;
    finish_turn(world)?;
    open_fold(world)
}

/// Waits for the timeline brick to draw `line`.
fn draws(world: &mut World, line: &str) -> Outcome {
    let brick = timeline_brick(world)?;
    let line = line.to_owned();
    world.wait_for(&format!("the timeline to draw \"{line}\""), move |w| {
        brick.shows(w, &line).unwrap_or(false)
    })
}

/// How the latest command ends.
fn end_command(world: &mut World, how: &str) -> Outcome {
    let fields = match how {
        "is running" => json!({"status": "running"}),
        "succeeds" => json!({"status": "completed", "exitCode": 0}),
        "fails" => json!({"status": "failed", "exitCode": 1}),
        "is declined by the user" => json!({"status": "declined"}),
        "is stopped" => json!({"status": "interrupted"}),
        _ => fail!("no command that {how}"),
    };
    set(world, "turn-item", "command:latest", fields)
}

pub fn register(steps: &mut Steps) {
    // Summaries.
    steps.step(
        "the agent ran two commands and sent messages to three threads",
        |world, _, _| {
            start_run(world, 30, "running")?;
            add_command(world, 1, "completed")?;
            add_command(world, 2, "completed")?;
            for n in 1..=3 {
                send_message(world, &format!("thread-{}", n + 1), n, false)?;
            }
            finish_turn(world)
        },
    );
    steps.step(
        "the agent ran commands, changed files, searched the web and read files",
        |world, _, _| {
            start_run(world, 30, "running")?;
            add_item(
                world,
                "dynamic_tool",
                json!({"toolName": "Read", "input": {"path": "src/cart.ts"}}),
            )?;
            add_item(world, "web_search", json!({"patterns": ["vat rates"]}))?;
            add_command(world, 1, "completed")?;
            add_command(world, 2, "completed")?;
            add_item(world, "file_change", json!({"fileName": "src/cart.ts"}))?;
            finish_turn(world)
        },
    );
    steps.step(
        "the agent sent three messages and one of them failed",
        |world, _, _| {
            start_run(world, 30, "running")?;
            send_message(world, "thread-2", 1, false)?;
            send_message(world, "thread-2", 2, true)?;
            send_message(world, "thread-2", 3, false)?;
            finish_turn(world)
        },
    );
    steps.step("the user reads the activity group", |world, _, _| {
        open_fold(world)?;
        // Collapsed, the group is its summary alone; a lone call is its own
        // line.
        let shown = entries(world)?;
        let row = last_row_of(world, "work")?;
        expect!(
            shown.is_empty() || role(world, row, "hiddenCount").as_i64().unwrap_or(0) == 0,
            "the collapsed group shows {}",
            show(&Value::Array(shown))
        );
        Ok(())
    });
    steps.step(&format!("it reads {Q}"), |world, c, _| {
        if world.mc.part::<super::stream::ShownDuration>().shown {
            let read = world.mc.part::<super::stream::ShownDuration>().text.clone();
            expect!(read == c[0], "the duration reads \"{read}\"");
            return Ok(());
        }
        let read = group_line(world)?;
        expect!(read == c[0], "the group reads \"{read}\"");
        let brick = timeline_brick(world)?;
        let wanted = format!("the timeline to draw \"{}\"", c[0]);
        let line = c[0].clone();
        world.wait_for(&wanted, move |w| brick.shows(w, &line).unwrap_or(false))
    });
    steps.step(
        "the summary names commands and file changes",
        |world, _, _| {
            let read = summary(world)?;
            expect!(
                read.starts_with("Ran 2 commands, changed 1 file"),
                "the group reads \"{read}\""
            );
            Ok(())
        },
    );
    steps.step(
        "it counts the rest instead of naming them",
        |world, _, _| {
            let read = summary(world)?;
            expect!(
                read == "Ran 2 commands, changed 1 file, and performed 2 other actions",
                "the group reads \"{read}\""
            );
            let brick = timeline_brick(world)?;
            let wanted = format!("the timeline to draw \"{read}\"");
            world.wait_for(&wanted, move |w| brick.shows(w, &read).unwrap_or(false))
        },
    );
    steps.step("the summary counts two messages sent", |world, _, _| {
        let read = summary(world)?;
        expect!(
            read == "Sent 2 messages to 1 thread",
            "the group reads \"{read}\""
        );
        let row = last_row_of(world, "work")?;
        expect!(
            role(world, row, "summaryFailed") == json!(true),
            "the group does not say a call failed"
        );
        Ok(())
    });

    // What a call is labelled by.
    steps.step(
        &format!("the agent ran {Q} through a shell and changed a file in the workspace"),
        |world, c, _| {
            start_run(world, 30, "running")?;
            add_item(
                world,
                "command_execution",
                json!({"input": format!("bash -lc '{}'", c[0]), "exitCode": 0}),
            )?;
            let root = text(&world.mc.projects[PROJECT]["workspaceRoot"]);
            add_item(
                world,
                "file_change",
                json!({"fileName": format!("{root}/src/cart.ts")}),
            )?;
            finish_turn(world)?;
            open_fold(world)
        },
    );
    steps.step("the user opens the activity group", |world, _, _| {
        let item = drawn(world, "workGroupToggle")?;
        click(world, item)?;
        world.wait_for_with(
            |w| entries(w).is_ok_and(|e| e.len() == 2),
            |w| format!("the group to open; {}", describe(w)),
        )
    });
    steps.step(
        &format!("the command is labelled {Q} and the file change {Q}"),
        |world, c, _| {
            let calls = entries(world)?;
            expect!(
                calls.len() == 2 && calls[0]["label"] == c[0] && calls[1]["label"] == c[1],
                "the calls read {}",
                show(&Value::Array(calls))
            );
            Ok(())
        },
    );

    // A usage limit on the thread's timeline.
    steps.step(
        "the provider stopped the turn at its usage limit, resetting at the top of an hour",
        |world, _, _| {
            start_run(world, 30, "running")?;
            add_item(
                world,
                "error",
                json!({"status": "failed",
                       "failure": {"class": "usage_limit",
                                   "message": "You've hit your usage limit.",
                                   "resetAt": iso(now() + Duration::seconds(3 * 3600))}}),
            )?;
            settle_run(world, "failed", 5)
        },
    );
    steps.step(
        "the timeline shows one warning line naming when to retry",
        |world, _, _| {
            let row = last_row_of(world, "error")?;
            let title = text(&role(world, row, "title"));
            expect!(
                title.starts_with("Usage limit reached. Retry after ")
                    && title.ends_with('.')
                    && text(&role(world, row, "text")).is_empty()
                    && role(world, row, "warning") == json!(true),
                "the error row is {}",
                describe(world)
            );
            Ok(())
        },
    );

    // Opening a group.
    steps.step("a collapsed group of tool calls", |world, _, _| {
        start_run(world, 30, "running")?;
        add_item(
            world,
            "command_execution",
            json!({"input": "bun test cart", "exitCode": 0}),
        )?;
        add_item(
            world,
            "command_execution",
            json!({"input": "bun lint", "status": "failed", "exitCode": 2}),
        )?;
        send_message(world, "thread-2", 1, false)?;
        finish_turn(world)?;
        open_fold(world)?;
        expect!(
            entries(world)?.is_empty() && !summary(world)?.is_empty(),
            "the group is not collapsed; {}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the user opens the group", |world, _, _| {
        toggle_group(world)
    });
    steps.step("the user closes the group", |world, _, _| {
        toggle_group(world)
    });
    steps.step(
        "each call shows its command or input, its status and its exit code",
        |world, _, _| {
            world.wait_for_with(
                |w| entries(w).is_ok_and(|e| e.len() == 3),
                |w| format!("the group to open; {}", describe(w)),
            )?;
            let calls = entries(world)?;
            let (passed, failed, sent) = (&calls[0], &calls[1], &calls[2]);
            expect!(
                passed["command"] == "bun test cart"
                    && passed["status"] == "completed"
                    && passed["exitCode"] == 0,
                "the first call is {}",
                show(passed)
            );
            expect!(
                failed["command"] == "bun lint"
                    && failed["statusLabel"] == "Failed"
                    && failed["exitCode"] == 2,
                "the second call is {}",
                show(failed)
            );
            expect!(
                text(&sent["detail"]).contains("\"threadId\": \"thread-2\"")
                    && sent["status"] == "completed"
                    && sent.get("exitCode").is_none(),
                "the third call is {}",
                show(sent)
            );
            // As drawn: the failed call says so, and an opened call shows its command and exit code.
            let brick = timeline_brick(world)?;
            world.wait_for("the timeline to mark the failed call", move |w| {
                brick.shows(w, "Failed").unwrap_or(false)
            })?;
            world.wait_for("the timeline to draw the three calls", move |w| {
                brick
                    .find_visible_nth(w, "workCall", 2)
                    .ok()
                    .flatten()
                    .is_some()
                    && brick
                        .find_visible_nth(w, "workCall", 3)
                        .ok()
                        .flatten()
                        .is_none()
            })?;
            let Some(line) = brick.find_visible_nth(world, "workCall", 1)? else {
                fail!("the second call went away");
            };
            click(world, line)?;
            world.wait_for("the call's command and exit code", move |w| {
                brick.shows(w, "$ bun lint").unwrap_or(false)
                    && brick
                        .shows(w, "Process exited with code 2")
                        .unwrap_or(false)
            })
        },
    );
    steps.step("the calls collapse back into the summary", |world, _, _| {
        world.wait_for_with(
            |w| entries(w).is_ok_and(|e| e.is_empty()),
            |w| format!("the group to close; {}", describe(w)),
        )?;
        let read = summary(world)?;
        expect!(
            read == "Ran 2 commands and sent 1 message to 1 thread",
            "the group reads \"{read}\""
        );
        let brick = timeline_brick(world)?;
        world.wait_for("the timeline to draw only the summary", move |w| {
            brick.shows(w, &read).unwrap_or(false) && !brick.shows(w, "$ bun lint").unwrap_or(true)
        })
    });

    // An ACP agent's read, search and fetch, as the MC projects them
    // (acp/thread_runtime.ex tool_kind; apps/server-ex/test/steps/timeline/tool_calls_steps.exs).
    steps.step(
        &format!("an ACP agent's tool call is of kind {Q}"),
        |world, c, _| {
            start_run(world, 0, "running")?;
            match c[0].as_str() {
                "read" => add_item(
                    world,
                    "file_search",
                    json!({"pattern": "src/app.ts", "results": [{"fileName": "src/app.ts"}]}),
                )?,
                "search" => add_item(world, "file_search", json!({"pattern": "TODO"}))?,
                "fetch" => add_item(
                    world,
                    "web_search",
                    json!({"patterns": ["https://example.com/docs"]}),
                )?,
                other => fail!("unknown ACP tool kind: {other}"),
            };
            Ok(())
        },
    );
    // The item above is the projected call; the shell has it once it is streamed.
    steps.step("the MC projects the call", |world, _, _| {
        expect!(
            entries(world)?.len() == 1,
            "the timeline shows {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the timeline shows it as (a file read|a file search|a web search)",
        |world, c, _| {
            let want = match c[0].as_str() {
                "a file read" => ("Read file", "eye", "src/app.ts"),
                "a file search" => ("Searched files", "search", "TODO"),
                _ => ("Searched the web", "globe", "https://example.com/docs"),
            };
            let calls = entries(world)?;
            let call = calls.last().cloned().unwrap_or(Value::Null);
            expect!(
                call["label"] == want.0 && call["icon"] == want.1 && call["detail"] == want.2,
                "the call is shown as {}",
                show(&call)
            );
            let brick = timeline_brick(world)?;
            let wanted = format!("the timeline to draw \"{}\"", want.0);
            world.wait_for(&wanted, move |w| brick.shows(w, want.0).unwrap_or(false))
        },
    );

    // A turn the user stops here.
    steps.step(
        "the user interrupted the running turn a moment ago",
        |world, _, _| {
            start_working_turn(world)?;
            add_command(world, 1, "completed")?;
            add_command(world, 2, "running")?;
            world.dispatch("composer.interrupt", Value::Null)?;
            world.sync()?;
            let asked = world
                .mc
                .commands
                .iter()
                .any(|command| command["type"] == "run.interrupt");
            expect!(
                asked,
                "the MC was not asked to stop; it has {}",
                world.describe_commands()
            );
            // What the MC makes of the stop: the running call was cut off.
            let running = text(
                &entries(world)?
                    .last()
                    .map_or(Value::Null, |e| e["id"].clone()),
            );
            set(
                world,
                "turn-item",
                &running,
                json!({"status": "interrupted"}),
            )
        },
    );
    steps.step(
        "its work stays expanded so the user can see where it stopped",
        |world, _, _| {
            let fold = last_row_of(world, "fold")?;
            expect!(
                role(world, fold, "expanded") == json!(true)
                    && text(&role(world, fold, "title")).starts_with("You stopped"),
                "the fold is not open; {}",
                describe(world)
            );
            let calls = entries(world)?;
            expect!(
                calls.len() == 2
                    && calls[1]["command"] == "bun test cart-2"
                    && calls[1]["statusLabel"] == "Stopped",
                "the calls shown are {}",
                show(&Value::Array(calls))
            );
            // The reverse: the user can still fold it away.
            toggle(world, &text(&role(world, fold, "rowId")))?;
            expect!(
                rows_of(world, "work")?.is_empty(),
                "the work cannot be folded away; {}",
                describe(world)
            );
            Ok(())
        },
    );

    // A long message of the user's.
    steps.step("a message longer than the preview length", |world, _, _| {
        let run = start_run(world, 0, "running")?;
        let lines: Vec<String> = (1..=30).map(|n| format!("Requirement {n}")).collect();
        set(
            world,
            "turn-item",
            &format!("message:{run}"),
            json!({"text": lines.join("\n")}),
        )?;
        let body = drawn(world, "userMessageBody")?;
        let brick = timeline_brick(world)?;
        world.wait_for_with(
            |w| brick.flag(w, body, "collapsed") && number(w, brick, body, "height") <= 200.0,
            |w| {
                format!(
                    "the message to show its preview; it is {} high",
                    number(w, brick, body, "height")
                )
            },
        )
    });
    steps.step("the user shows the full message", |world, _, _| {
        let link = drawn(world, "messageExpand")?;
        let brick = timeline_brick(world)?;
        let offered = brick.text_of(world, link, "text");
        expect!(
            offered == "Show full message",
            "the message offers \"{offered}\""
        );
        click(world, link)
    });
    steps.step("the whole message is shown", |world, _, _| {
        let body = drawn(world, "userMessageBody")?;
        let brick = timeline_brick(world)?;
        // Thirty lines are taller than the preview, and nothing is cut off.
        let Some(clip) = brick.find_under(world, body, "userMessageClip")? else {
            fail!("the message has no clip");
        };
        world.wait_for_with(
            |w| {
                !brick.flag(w, body, "collapsed")
                    && number(w, brick, body, "height") > 400.0
                    && !brick.flag(w, clip, "clip")
            },
            |w| {
                format!(
                    "the whole message; it is {} high",
                    number(w, brick, body, "height")
                )
            },
        )?;
        let link = drawn(world, "messageExpand")?;
        expect!(
            brick.text_of(world, link, "text") == "Show less",
            "the message does not offer to show less"
        );
        Ok(())
    });
    steps.step("the user shows less", |world, _, _| {
        let link = drawn(world, "messageExpand")?;
        click(world, link)
    });
    steps.step("the message returns to its preview", |world, _, _| {
        let body = drawn(world, "userMessageBody")?;
        let brick = timeline_brick(world)?;
        let Some(clip) = brick.find_under(world, body, "userMessageClip")? else {
            fail!("the message has no clip");
        };
        // Cut off inside the padding, as far from the bottom edge as the top.
        world.wait_for_with(
            |w| {
                let (height, top) = (
                    number(w, brick, body, "height"),
                    number(w, brick, clip, "y"),
                );
                brick.flag(w, body, "collapsed")
                    && height <= 200.0
                    && brick.flag(w, clip, "clip")
                    && top > 0.0
                    && (height - (top + number(w, brick, clip, "height")) - top).abs() < 1e-6
            },
            |w| {
                format!(
                    "the preview; the message is {} high",
                    number(w, brick, body, "height")
                )
            },
        )?;
        let link = drawn(world, "messageExpand")?;
        expect!(
            brick.text_of(world, link, "text") == "Show full message",
            "the message does not offer to show it in full"
        );
        Ok(())
    });

    // Several approvals, on the request brick the composer stacks over its prompt.
    steps.step("the agent has three pending approvals", |world, _, _| {
        for command in ["npm test", "npm run lint", "npm run build"] {
            let id = {
                let fake = world.mc.part::<FakeStreams>();
                format!("request-{}", fake.ordinal + 1)
            };
            set(
                world,
                "runtime-request",
                &id,
                json!({"id": id, "status": "pending", "responseCapability": {"type": "live"}}),
            )?;
            add_item(
                world,
                "approval_request",
                json!({"requestId": id, "status": "waiting", "requestKind": "command",
                       "prompt": command}),
            )?;
        }
        world.wait_for_with(
            |w| approvals(w) == 3,
            |w| format!("three approvals; the turn is {}", show(&w.state("turn"))),
        )?;
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nTurnRequests {}\n",
            820.0,
            400.0,
        )?;
        let brick = brick::shown(world)?;
        world.wait_for("the first approval to be shown", move |w| {
            brick.shows(w, "npm test").unwrap_or(false)
        })
    });
    steps.step("the user moves to the next approval", |world, _, _| {
        let brick = brick::shown(world)?;
        brick.click(world, "approvalNext")?;
        world.wait_for("the second approval to be shown", move |w| {
            brick.shows(w, "npm run lint").unwrap_or(false)
        })
    });
    steps.step("the user moves back", |world, _, _| {
        let brick = brick::shown(world)?;
        brick.click(world, "approvalPrevious")?;
        world.wait_for("the first approval to be shown again", move |w| {
            brick.shows(w, "npm test").unwrap_or(false)
        })
    });

    // What a group's calls were, and how a call is named.
    steps.step("the activity group holds (.+)", |world, c, _| {
        start_run(world, 30, "running")?;
        add_calls(world, &c[0])?;
        finish_turn(world)
    });
    steps.step(&format!("it ends with {Q}"), |world, c, _| {
        // The count ends a sentence that starts with what was named.
        let read = summary(world)?;
        expect!(
            read.to_lowercase().ends_with(&c[0].to_lowercase()),
            "the group reads \"{read}\""
        );
        Ok(())
    });
    steps.step("the group is marked as having a failure", |world, _, _| {
        let row = last_row_of(world, "work")?;
        expect!(
            role(world, row, "summaryFailed") == json!(true),
            "the group \"{}\" is not marked failed",
            summary(world)?
        );
        Ok(())
    });
    steps.step(
        "the provider reported a (?:HAL-C2 tool call|command) as completed",
        |world, _, _| start_run(world, 30, "running").map(drop),
    );
    steps.step("the tool's answer says it is an error", |world, _, _| {
        send_message(world, "thread-2", 1, true)?;
        finish_turn(world)
    });
    steps.step(
        "the (?:call|command) is shown as (failed|succeeded)",
        |world, c, _| {
            let call = last_call(world)?;
            let failed = c[0] == "failed";
            expect!(
                text(&call["status"]) == "completed"
                    && text(&call["statusLabel"]) == if failed { "Failed" } else { "" },
                "the call is {}",
                show(&call)
            );
            let brick = timeline_brick(world)?;
            let label = text(&call["label"]);
            world.wait_for(
                &format!("the timeline to draw the call as {}", c[0]),
                move |w| {
                    brick.shows(w, &label).unwrap_or(false)
                        && brick.shows(w, "Failed").unwrap_or(false) == failed
                },
            )
        },
    );
    steps.step(
        &format!("the agent called HAL-C2's {Q} tool"),
        |world, c, _| call_tool(world, &format!("mcp__hal-c2__{}", c[0])),
    );
    steps.step(
        &format!(
            "the agent called (?:HAL-C2's thread-reading tool and the provider named it|a tool named) {Q}"
        ),
        |world, c, _| call_tool(world, &c[0]),
    );
    steps.step(&format!("the call reads {Q}"), |world, c, _| {
        let label = text(&last_call(world)?["label"]);
        expect!(label == c[0], "the call reads \"{label}\"");
        draws(world, &c[0])
    });
    steps.step(
        "the call is shown as an ordinary tool call",
        |world, _, _| {
            let label = text(&last_call(world)?["label"]);
            expect!(
                label == "mcp__other-server__hal_c2_thread_read",
                "the call reads \"{label}\""
            );
            draws(world, &label)
        },
    );
    steps.step(
        "it does not carry HAL-C2's name for the tool",
        |world, _, _| {
            let brick = timeline_brick(world)?;
            expect!(
                !brick.shows(world, "Read a HAL-C2 thread")?,
                "the call carries HAL-C2's name"
            );
            Ok(())
        },
    );
    steps.step(&format!("the command's output says {Q}"), |world, c, _| {
        // The wire carries no output, only what the MC made of it:
        // TurnWriter flags a completed command whose output says it failed
        // (orchestration/command_output.ex).
        let mut fields = json!({"input": "npm test", "status": "completed"});
        if c[0] != "exited with exit code 0" {
            fields["outputIndicatesFailure"] = json!(true);
        }
        add_item(world, "command_execution", fields)?;
        finish_turn(world)
    });

    // The running turn's latest command.
    steps.step(
        &format!("the agent's latest command is {ESCAPED}"),
        |world, c, _| {
            start_run(world, 30, "running")?;
            add_item(
                world,
                "command_execution",
                json!({"id": "command:latest", "input": unescaped(&c[0]), "status": "running"}),
            )
            .map(drop)
        },
    );
    steps.step("it finishes", |world, _, _| end_command(world, "succeeds"));
    steps.step(
        "the command (is running|succeeds|fails|is declined by the user|is stopped)",
        |world, c, _| end_command(world, &c[0]),
    );
    steps.step(&format!("the live row reads {Q}"), |world, c, _| {
        let label = text(&last_call(world)?["label"]);
        expect!(label == c[0], "the live row reads \"{label}\"");
        draws(world, &c[0])
    });

    // A command as the provider wrapped it.
    steps.step(&format!("the agent ran {ESCAPED}"), |world, c, _| {
        start_run(world, 30, "running")?;
        add_item(
            world,
            "command_execution",
            json!({"input": unescaped(&c[0]), "exitCode": 0}),
        )?;
        finish_turn(world)
    });
    steps.step(&format!("the command reads {ESCAPED}"), |world, c, _| {
        let label = text(&last_call(world)?["label"]);
        let wanted = unescaped(&c[0]);
        expect!(label == wanted, "the command reads \"{label}\"");
        Ok(())
    });
    steps.step(&format!("the details show {Q}"), |world, c, _| {
        let call = last_call(world)?;
        expect!(
            text(&call["command"]) == c[0],
            "the call is {}",
            show(&call)
        );
        draws(world, &format!("$ {}", c[0]))
    });

    // Progress on a call already shown, while the agent writes.
    steps.step("the agent is writing a message", |world, _, _| {
        start_run(world, 30, "running")?;
        add_item(
            world,
            "command_execution",
            json!({"id": "command:dev", "input": "npm run dev", "status": "running"}),
        )?;
        add_item(
            world,
            "assistant_message",
            json!({"id": "reply", "streaming": true, "status": "running",
                   "text": "| Item | Tax |\n|---|---|\n"}),
        )
        .map(drop)
    });
    steps.step(
        "a command it started in the background reports progress in the middle of the message",
        |world, _, _| {
            change(
                world,
                "turn-item",
                "command:dev",
                json!({"a": {"output": "ready on :3000\n"}}),
            )?;
            change(
                world,
                "turn-item",
                "reply",
                json!({"a": {"text": "| Cart | 2.50 |"}}),
            )
        },
    );
    steps.step("the message stays one message", |world, _, _| {
        let messages = rows_of(world, "message")?;
        let replies = messages
            .iter()
            .filter(|row| text(&role(world, **row, "text")).contains("| Item | Tax |"))
            .count();
        let count = super::stream::row_count(world)?;
        expect!(
            replies == 1 && messages.last() == Some(&(count - 1)),
            "the reply is split; {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the text the agent writes after the progress is part of it",
        |world, _, _| {
            let Some(&last) = rows_of(world, "message")?.last() else {
                fail!("no message; {}", describe(world));
            };
            let read = text(&role(world, last, "text"));
            expect!(
                read.contains("| Item | Tax |") && read.contains("| Cart | 2.50 |"),
                "the reply reads \"{read}\""
            );
            Ok(())
        },
    );
}
