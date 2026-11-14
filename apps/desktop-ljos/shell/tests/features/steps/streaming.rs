//! What a turn shows while and after it streams
//! (features/timeline/streaming.feature): the working timer before the
//! agent begins, how durations are written, which messages of the
//! user's are shortened, a reply with no text, and a reply's shell
//! command run from its code block in the thread's terminal. The stream
//! is stream.rs's; the rows are read from the Timeline brick drawing it,
//! wired as ThreadView wires it: desktop-qt's StreamingSteps.cpp.

use chrono::Duration;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::thread_view::time::format_duration;
use ljos::prelude::{Engine, ObjectId, Value};
use serde_json::{Value as Json, json};

use super::stream::{
    FakeStreams, THREAD, add_item, describe, iso, now, read, set, settle_run, start_run,
    timeline_object,
};
use super::terminal::{describe_terminal_calls, terminal_call, terminal_writes};
use crate::brick::{self, Brick};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// The open thread's timeline, its replies' commands run as ThreadView
/// runs them.
fn timeline_brick(world: &mut World) -> Outcome<Brick> {
    if world.part::<brick::Shown>().0.is_none() {
        let brick = Brick::new(
            world,
            "import QtQuick\nimport HalC2.Bricks\nimport HalC2.Shell\n\
             Timeline { runnable: true\n\
               onRunCommand: command => Shell.dispatch(\"workspace.runCommand\", { command: command }) }\n",
            820.0,
            1400.0,
        )?;
        world.part::<brick::Shown>().0 = Some(brick);
        let timeline = timeline_object(world)?;
        let Some(root) = brick.root(world) else {
            fail!("the timeline brick has no root");
        };
        brick.write(world, root, "model", Value::Object(timeline))?;
    }
    brick::shown(world)
}

fn collect(engine: &Engine, item: ObjectId, name: &str, out: &mut Vec<ObjectId>) {
    if matches!(engine.read_by_name(item, "objectName"), Value::String(ref s) if s.as_str() == name)
    {
        out.push(item);
    }
    for child in engine.children(item) {
        collect(engine, child, name, out);
    }
}

fn visible(world: &World, brick: Brick, name: &str) -> Vec<ObjectId> {
    let mut items = Vec::new();
    if let Some(root) = brick.root(world) {
        collect(world.engine(), root, name, &mut items);
    }
    items
        .into_iter()
        .filter(|&item| world.engine().read_by_name(item, "visible") == Value::Bool(true))
        .collect()
}

fn collect_all(engine: &Engine, item: ObjectId, out: &mut Vec<ObjectId>) {
    out.push(item);
    for child in engine.children(item) {
        collect_all(engine, child, out);
    }
}

fn has(engine: &Engine, item: ObjectId, property: &str) -> bool {
    !matches!(engine.read_by_name(item, property), Value::Undefined)
}

/// The newest reply as its Markdown brick draws it.
fn drawn_reply(world: &mut World) -> Outcome<ObjectId> {
    let brick = timeline_brick(world)?;
    let newest = move |w: &World| {
        let root = brick.root(w)?;
        let mut all = Vec::new();
        collect_all(w.engine(), root, &mut all);
        all.into_iter()
            .filter(|&item| {
                has(w.engine(), item, "lineBreaks")
                    && has(w.engine(), item, "segmentCount")
                    && w.engine().read_by_name(item, "lineBreaks") != Value::Bool(true)
            })
            .last()
    };
    world.wait_for_with(
        |w| newest(w).is_some(),
        |w| format!("a reply to be drawn; {}", describe(w)),
    )?;
    match newest(world) {
        Some(found) => Ok(found),
        None => fail!("the reply went away"),
    }
}

fn str_of(world: &World, item: ObjectId, name: &str) -> String {
    match world.engine().read_by_name(item, name) {
        Value::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

const COMMAND: &str = "bun test cart";

/// A reply of the current thread holding `block`, written or still
/// streaming.
fn reply_with(world: &mut World, block: &str, streaming: bool) -> Outcome {
    start_run(world, 30, "running")?;
    let mut fields = json!({"text": format!("Run the tests:\n\n{block}")});
    if streaming {
        fields["streaming"] = json!(true);
        fields["status"] = json!("running");
    }
    add_item(world, "assistant_message", fields)?;
    if !streaming {
        settle_run(world, "completed", 30)?;
    }
    Ok(())
}

fn preferred_script(world: &World) -> String {
    text(at(&world.state("workspace"), "preferredScriptId"))
}

/// The workspace's preferred script before the user ran a reply's command.
#[derive(Default)]
struct Before {
    preferred: String,
}

/// The thread's project offers "lint" first, as if the user had run it
/// last, so a change to the selected script shows.
fn prefer_script(world: &mut World) -> Outcome {
    let project = text(&world.mc.threads[THREAD]["projectId"]);
    let mut row = world
        .mc
        .projects
        .get(&project)
        .cloned()
        .unwrap_or(json!({}));
    let mut scripts = row["scripts"].as_array().cloned().unwrap_or_default();
    scripts.push(
        json!({"id": "lint", "name": "Lint", "command": "bun run lint",
                        "icon": "play", "runOnWorktreeCreate": false}),
    );
    row["scripts"] = Json::Array(scripts);
    world.mc.projects.insert(project.clone(), row.clone());
    let environment = world.mc.part::<FakeStreams>().environment.clone();
    Settings::of(world.engine()).write_device(
        world.engine(),
        "lastProjectScripts",
        json!({format!("{environment}:{project}"): "lint"}),
    );
    world.mc.send_row_of(&project, &row, "project");
    world.wait_for_with(
        |w| preferred_script(w) == "lint",
        |w| {
            format!(
                "the project to offer lint first; the workspace is {}",
                show(&w.state("workspace"))
            )
        },
    )
}

pub fn register(steps: &mut Steps) {
    // The working timer counts from the message (deriveActiveWorkStartedAt).
    steps.step(
        "the user sent a message and the agent's session is still starting",
        |world, _, _| {
            let run = start_run(world, -1, "starting")?;
            set(
                world,
                "run",
                &run,
                json!({"requestedAt": iso(now() - Duration::seconds(12))}),
            )
        },
    );
    steps.step("the agent has not yet begun the turn", |world, _, _| {
        let fake = world.mc.part::<FakeStreams>();
        let run = fake
            .threads
            .get(THREAD)
            .and_then(|entities| entities.get(&format!("run\n{}", fake.run)))
            .cloned()
            .unwrap_or(Json::Null);
        expect!(
            run.get("startedAt").is_none(),
            "the run began at {}",
            text(&run["startedAt"])
        );
        Ok(())
    });
    steps.step(
        "the elapsed time counts from when the message was sent",
        |world, _, _| {
            let since = read(world, |t| t.working_since())?;
            expect!(
                since == Some(now() - Duration::seconds(12)),
                "the timer counts from {}",
                since.map_or_else(String::new, iso)
            );
            Ok(())
        },
    );
    steps.step(
        "it does not disappear and come back when the agent begins",
        |world, _, _| {
            expect!(
                read(world, |t| t.working())?,
                "the thread is not working before the agent begins"
            );
            let run = world.mc.part::<FakeStreams>().run.clone();
            set(
                world,
                "run",
                &run,
                json!({"status": "running",
                       "startedAt": iso(now() - Duration::seconds(2))}),
            )?;
            world.sync()?;
            expect!(
                read(world, |t| t.working())?,
                "the thread stopped saying the agent is working"
            );
            // It counts from when the agent began from now on
            // (deriveActiveWorkStartedAt).
            let since = read(world, |t| t.working_since())?;
            expect!(
                since == Some(now() - Duration::seconds(2)),
                "the timer counts from {}",
                since.map_or_else(String::new, iso)
            );
            Ok(())
        },
    );

    // Durations (formatDuration).
    steps.step("the thread shows a duration of (.+)", |world, c, _| {
        let mut ms = 0.0;
        let mut parts = c[0].split_whitespace();
        while let (Some(amount), Some(unit)) = (parts.next(), parts.next()) {
            let amount: f64 = amount.parse().unwrap_or(0.0);
            ms += amount
                * match unit.trim_end_matches('s') {
                    "millisecond" => 1.0,
                    "second" => 1000.0,
                    "minute" => 60000.0,
                    _ => 3600000.0,
                };
        }
        let shown = world.mc.part::<super::stream::ShownDuration>();
        shown.shown = true;
        shown.text = format_duration(ms.round() as i64);
        Ok(())
    });

    // Which messages of the user's are shortened (shouldCollapseUserMessage).
    steps.step("the user sent a message of (.+)", |world, c, _| {
        let body = match c[0].as_str() {
            "600 characters on one line" => "a".repeat(600),
            "601 characters on one line" => "a".repeat(601),
            "8 short lines" => vec!["line"; 8].join("\n"),
            "9 short lines" => vec!["line"; 9].join("\n"),
            "only spaces and blank lines" => {
                format!("   \n\n  \n\n\n\n\n\n\n   {}", " ".repeat(600))
            }
            other => fail!("no message of {other}"),
        };
        let run = start_run(world, 30, "running")?;
        set(
            world,
            "turn-item",
            &format!("message:{run}"),
            json!({"text": body}),
        )?;
        settle_run(world, "completed", 30)
    });
    steps.step("the user looks at it in the conversation", |world, _, _| {
        let brick = timeline_brick(world)?;
        world.wait_for_with(
            move |w| visible(w, brick, "userMessageBody").len() == 1,
            |w| format!("the message to be drawn; {}", describe(w)),
        )
    });
    steps.step("it is (shown in full|shortened)", |world, c, _| {
        let brick = timeline_brick(world)?;
        let bodies = visible(world, brick, "userMessageBody");
        let Some(&body) = bodies.first() else {
            fail!("no message is drawn; {}", describe(world));
        };
        let collapsed = world.engine().read_by_name(body, "collapsed") == Value::Bool(true);
        expect!(
            collapsed == (c[0] == "shortened"),
            "the message is {}",
            if collapsed {
                "shortened"
            } else {
                "shown in full"
            }
        );
        Ok(())
    });

    // A reply's shell command, run from its code block.
    steps.step(
        "the agent's reply has a single-line shell command in a code block",
        |world, _, _| {
            reply_with(world, &format!("```bash\n{COMMAND}\n```"), false)?;
            prefer_script(world)
        },
    );
    steps.step(
        "the user runs the command from its code block",
        |world, _, _| {
            let preferred = preferred_script(world);
            world.mc.part::<Before>().preferred = preferred.clone();
            expect!(
                preferred == "lint",
                "the project offers {preferred} first, not lint"
            );
            drawn_reply(world)?;
            let brick = timeline_brick(world)?;
            world.wait_for_with(
                move |w| visible(w, brick, "runCode").len() == 1,
                move |w| {
                    format!(
                        "the code block to offer Run; {} offered",
                        visible(w, brick, "runCode").len()
                    )
                },
            )?;
            let run = visible(world, brick, "runCode")[0];
            let (x, y) = brick.at(world, run, 0.5, 0.5)?;
            world.click_at(x, y)?;
            world.sync()
        },
    );
    steps.step(
        "the command runs in the thread's terminal in the thread's folder",
        |world, _, _| {
            let workspace = world.state("workspace");
            let worktree = text(at(&workspace, "worktreePath"));
            let folder = if worktree.is_empty() {
                text(at(&workspace, "projectRoot"))
            } else {
                worktree
            };
            let wanted = folder.clone();
            world.wait_for_with(
                move |w| {
                    let open = terminal_call(w, "terminal.open", THREAD, "term-1");
                    open.is_some_and(|open| {
                        !wanted.is_empty()
                            && text(&open["cwd"]) == wanted
                            && terminal_writes(w, "term-1") == [format!("{COMMAND}\r")]
                    })
                },
                move |w| {
                    format!(
                        "{COMMAND} in {folder}; the MC got {}",
                        describe_terminal_calls(w)
                    )
                },
            )
        },
    );
    steps.step(
        "the project's selected script is not changed",
        |world, _, _| {
            world.sync()?;
            let before = world.mc.part::<Before>().preferred.clone();
            expect!(
                preferred_script(world) == before,
                "the project's script went from {before} to {}",
                preferred_script(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the agent's reply has (a shell command still streaming|a shell command that spans several lines|an empty shell block|a shell command ending in a backslash|a Python snippet) in a code block",
        |world, c, _| match c[0].as_str() {
            "a shell command still streaming" => {
                reply_with(world, &format!("```bash\n{COMMAND}\n```"), true)
            }
            "a shell command that spans several lines" => {
                reply_with(world, "```bash\nbun install\nbun test cart\n```", false)
            }
            "an empty shell block" => reply_with(world, "```bash\n\n```", false),
            "a shell command ending in a backslash" => {
                reply_with(world, "```bash\nbun test cart \\\n```", false)
            }
            _ => reply_with(world, "```python\nprint(\"cart\")\n```", false),
        },
    );
    steps.step("the code block offers no run action", |world, _, _| {
        drawn_reply(world)?;
        let brick = timeline_brick(world)?;
        world.wait_for("the code block to be drawn", move |w| {
            !visible(w, brick, "copyCode").is_empty()
        })?;
        let offered = visible(world, brick, "runCode").len();
        expect!(offered == 0, "the code block offers Run {offered} times");
        Ok(())
    });

    // A reply with no text.
    steps.step(
        "the agent's turn ended with a reply that has no text",
        |world, _, _| {
            start_run(world, 30, "running")?;
            add_item(world, "assistant_message", json!({"text": ""}))?;
            settle_run(world, "completed", 30)
        },
    );
    steps.step(&format!("the reply reads {Q}"), |world, c, _| {
        let reply = drawn_reply(world)?;
        let shown = str_of(world, reply, "text");
        expect!(shown == c[0], "the reply reads \"{shown}\"");
        let brick = timeline_brick(world)?;
        let wanted = format!("the reply to draw \"{}\"", c[0]);
        let needle = c[0].clone();
        world.wait_for(&wanted, move |w| {
            brick.shows(w, &needle).unwrap_or(false)
                || matches!(w.engine().read_by_name(reply, "segmentCount"),
                            Value::Int(n) if n > 0)
        })
    });
    steps.step(
        "the agent has started a reply and written nothing yet",
        |world, _, _| {
            start_run(world, 5, "running")?;
            add_item(
                world,
                "assistant_message",
                json!({"text": "", "streaming": true, "status": "running"}),
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the reply shows no text and no {Q}"),
        |world, c, _| {
            let reply = drawn_reply(world)?;
            let shown = str_of(world, reply, "text");
            expect!(shown.is_empty(), "the reply reads \"{shown}\"");
            let brick = timeline_brick(world)?;
            expect!(
                !brick.shows(world, &c[0])?,
                "the timeline shows \"{}\"",
                c[0]
            );
            Ok(())
        },
    );
}
