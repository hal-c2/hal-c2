//! The composer's turn on an open thread: the agent's requests and
//! questions, its proposed plan, queued messages and follow-ups, as the MC
//! streams them, and what the user's answers send (the `turn` key the
//! composer publishes, and the commands the MC receives) (desktop-qt's
//! Turn.h and TurnSteps.cpp). The thread's stream is stream.rs's.

use hal_c2_shell::controller;
use hal_c2_shell::controllers::composer;
use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::controllers::palette::{Palette, PaletteObject};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use serde_json::{Value, json};

use crate::brick::{Brick, Shown};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::keybinding::condition_problem;
use crate::steps::stream::{self, FakeStreams, PROJECT, THREAD};
use crate::world::World;
use crate::{expect, fail};

const QUESTION: &str = "database";

fn thread_key(world: &World) -> String {
    format!("{}:{THREAD}", world.mc.environment_id)
}

fn turn(world: &World) -> Json {
    world.state("turn")
}

fn listed(world: &World, field: &str) -> Vec<Json> {
    turn(world)[field].as_array().cloned().unwrap_or_default()
}

/// Opens a thread of "shop" on a connected MC, unless one is open.
fn open_thread(world: &mut World) -> Outcome {
    if !world.mc.part::<FakeStreams>().thread.is_empty() {
        return Ok(());
    }
    let project =
        json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": "/work/shop", "scripts": []});
    world.mc.projects.insert(PROJECT.into(), project.clone());
    if world.shell_subscriptions() == 0 {
        world.connect()?;
    } else {
        // Already connected: the project arrives as a row.
        world.mc.send_row_of(PROJECT, &project, "project");
    }
    world.sync()?;
    stream::look_at_thread(world, PROJECT)
}

/// The thread's shell row says whether a turn runs.
fn update_row(world: &mut World, fields: Value) -> Outcome {
    let row = world
        .mc
        .threads
        .entry(THREAD.into())
        .or_insert_with(|| json!({"id": THREAD}));
    if let (Some(row), Some(fields)) = (row.as_object_mut(), fields.as_object()) {
        for (k, v) in fields {
            row.insert(k.clone(), v.clone());
        }
    }
    let row = row.clone();
    world.mc.send_row(THREAD, &row);
    world.sync()
}

fn start_working(world: &mut World) -> Outcome {
    open_thread(world)?;
    let run = stream::start_running(world)?;
    update_row(world, json!({"activeRunId": run, "latestRunId": run}))
}

fn finish_turn(world: &mut World) -> Outcome {
    stream::settle_run(world, "completed", 30)?;
    update_row(world, json!({"activeRunId": null}))
}

/// A pending request of the running turn: its runtime-request and its item.
fn request(world: &mut World, kind: &str, fields: Value, capability: &str) -> Outcome<String> {
    let id = format!("request-{}", world.mc.part::<FakeStreams>().ordinal + 1);
    stream::set(
        world,
        "runtime-request",
        &id,
        json!({"id": id, "status": "pending", "responseCapability": {"type": capability}}),
    )?;
    let mut item = fields;
    item["requestId"] = json!(id);
    item["status"] = json!("waiting");
    stream::add_item(world, kind, item)?;
    Ok(id)
}

fn approval(
    world: &mut World,
    kind: &str,
    prompt: &str,
    options: Vec<Value>,
    capability: &str,
) -> Outcome<String> {
    let mut fields = json!({"requestKind": kind, "prompt": prompt});
    if !options.is_empty() {
        fields["options"] = Value::Array(options);
    }
    request(world, "approval_request", fields, capability)
}

fn question(
    world: &mut World,
    asked: &str,
    labels: &[String],
    multi_select: bool,
    capability: &str,
) -> Outcome<String> {
    let options: Vec<Value> = labels
        .iter()
        .map(|label| json!({"label": label, "description": ""}))
        .collect();
    request(
        world,
        "user_input_request",
        json!({"questions": [{"id": QUESTION, "header": "Database", "question": asked,
                              "options": options, "multiSelect": multi_select,
                              "allowCustomAnswer": true}]}),
        capability,
    )
}

/// The pending approval or question the composer shows first.
fn first(world: &World, field: &str) -> Outcome<Json> {
    match listed(world, field).into_iter().next() {
        Some(request) => Ok(request),
        None => fail!(
            "the composer shows no {field}; the turn is {}",
            show(&turn(world))
        ),
    }
}

fn respond(world: &mut World, decision: &str) -> Outcome {
    let request_id = first(world, "approvals")?["requestId"].clone();
    world.dispatch(
        "composer.approval.respond",
        json!({"requestId": request_id, "decision": decision}),
    )?;
    world.sync()
}

fn answer(world: &mut World, value: Value) -> Outcome {
    let request_id = first(world, "questions")?["requestId"].clone();
    world.dispatch(
        "composer.question.answer",
        json!({"requestId": request_id, "answers": {QUESTION: value}}),
    )?;
    world.sync()
}

/// The commands of a type the MC received, oldest first.
fn commands_of(world: &mut World, kind: &str) -> Outcome<Vec<Value>> {
    world.sync()?;
    Ok(world
        .mc
        .commands
        .iter()
        .filter(|command| text(&command["type"]) == kind)
        .cloned()
        .collect())
}

fn last_command(world: &mut World, kind: &str) -> Outcome<Value> {
    match commands_of(world, kind)?.pop() {
        Some(command) => Ok(command),
        None => fail!(
            "no {kind} command; the MC has {}",
            world.describe_commands()
        ),
    }
}

fn expect_decision(world: &mut World, decision: &str) -> Outcome {
    let command = last_command(world, "runtime-request.respond")?;
    expect!(
        text(&command["decision"]) == decision && text(&command["threadId"]) == THREAD,
        "the MC was told {}",
        show(&command)
    );
    Ok(())
}

fn received_answer(world: &mut World) -> Outcome<Value> {
    let command = last_command(world, "runtime-request.respond")?;
    Ok(command["answers"][QUESTION].clone())
}

fn last_message(world: &mut World) -> Outcome<Value> {
    last_command(world, "message.dispatch")
}

/// A proposed plan in the latest run of a thread in plan mode; `settled`
/// ends that run.
fn propose_plan(world: &mut World, settled: bool) -> Outcome {
    start_working(world)?;
    // Plans come from plan mode.
    update_row(world, json!({"interactionMode": "plan"}))?;
    let markdown = "# Tax line\n\n- Add the line\n- Test it";
    stream::add_item(
        world,
        "proposed_plan",
        json!({"markdown": markdown, "planId": "plan-1"}),
    )?;
    let run = world.mc.part::<FakeStreams>().run.clone();
    stream::set(
        world,
        "plan",
        "plan-1",
        json!({"id": "plan-1", "kind": "proposed_plan", "status": "active", "runId": run,
               "markdown": markdown}),
    )?;
    if settled {
        finish_turn(world)?;
    }
    Ok(())
}

fn queue(world: &mut World, run: &str, message: &str, fields: Value) -> Outcome {
    let position = {
        let fake = world.mc.part::<FakeStreams>();
        fake.ordinal += 1;
        fake.ordinal
    };
    let mut row = json!({"id": message, "role": "user"});
    if let Some(fields) = fields.as_object() {
        for (k, v) in fields {
            row[k] = v.clone();
        }
    }
    stream::set(world, "message", message, row)?;
    stream::set(
        world,
        "run",
        run,
        json!({"id": run, "ordinal": position, "status": "queued", "queuePosition": position,
               "userMessageId": message}),
    )
}

fn queue_message(world: &mut World, typed: &str) -> Outcome {
    queue(
        world,
        &format!("run-queued-{typed}"),
        &format!("message-{typed}"),
        json!({"text": typed}),
    )
}

fn queue_wake(world: &mut World) -> Outcome {
    queue(
        world,
        "run-queued-wake",
        "message-wake",
        json!({"providerWake": true}),
    )
}

fn toasts(world: &World) -> Vec<Json> {
    at(&world.state("toasts"), "items")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// The composer the window shows: the open thread's, or a new thread's
/// draft.
fn composer_target(world: &World) -> String {
    let route = world.state("route");
    if text(&route["kind"]) == "draft" {
        return text(&route["draftId"]);
    }
    controller::with::<Navigation, _>(world.engine(), |n, _| n.thread_key().to_owned())
        .unwrap_or_default()
}

fn type_into(world: &mut World, typed: &str) -> Outcome {
    let target = composer_target(world);
    world.dispatch(
        "composer.text.set",
        json!({"target": target, "text": typed, "cursor": typed.chars().count()}),
    )
}

fn draft_of(world: &World, key: &str) -> String {
    composer::draft(world.engine(), key)
}

fn open_draft(world: &World) -> String {
    draft_of(world, &composer_target(world))
}

fn submit(world: &mut World, typed: &str) -> Outcome {
    world.dispatch(
        "composer.submit",
        json!({"text": typed, "intent": "foreground"}),
    )
}

fn queued_texts(world: &World) -> Vec<String> {
    listed(world, "queue")
        .iter()
        .map(|queued| text(&queued["text"]))
        .collect()
}

fn queued_run(world: &World, typed: &str) -> Outcome<String> {
    for entry in listed(world, "queue") {
        if text(&entry["text"]) == typed {
            return Ok(text(&entry["runId"]));
        }
    }
    fail!(
        "\"{typed}\" is not queued; the turn is {}",
        show(&turn(world))
    )
}

fn thread_b(world: &mut World) -> Outcome<String> {
    let id = "thread-2";
    if !world.mc.threads.contains_key(id) {
        let row = json!({"id": id, "title": "Other", "projectId": PROJECT,
                         "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
        world.mc.threads.insert(id.into(), row.clone());
        world.mc.send_row(id, &row);
        world.sync()?;
    }
    Ok(format!("{}:{id}", world.mc.environment_id))
}

/// The TurnRequests brick on screen.
fn requests_brick(world: &mut World) -> Outcome<Brick> {
    if let Some(brick) = world.part::<Shown>().0
        && brick
            .root(world)
            .is_some_and(|root| brick.text_of(world, root, "objectName") == "turnRequestsBrick")
    {
        return Ok(brick);
    }
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Bricks\nTurnRequests { objectName: \"turnRequestsBrick\" }\n",
        820.0,
        500.0,
    )?;
    crate::brick::shown(world)
}

/// Whether the shell tells the user `told` anywhere a step can see:
/// the pending approval, a toast, a settings page, the usage page, the
/// command palette, a page's inline error or the brick on screen.
fn tells(world: &World, told: &str) -> bool {
    if listed(world, "approvals")
        .iter()
        .any(|item| text(&item["problem"]) == told)
    {
        return true;
    }
    // A toast is told by its title, its description, or as "title —
    // description".
    for item in toasts(world) {
        let (title, description) = (text(&item["title"]), text(&item["description"]));
        if title == told || description == told || format!("{title} — {description}") == told {
            return true;
        }
    }
    if text(at(&world.state("sourceControlSettings"), "discovery.title")) == told {
        return true;
    }
    // What came of spending a reset credit on the usage page.
    let pools = at(&world.state("usage"), "limits.pools")
        .as_array()
        .cloned()
        .unwrap_or_default();
    if pools.iter().any(|pool| {
        pool["credits"]
            .as_array()
            .is_some_and(|credits| credits.iter().any(|c| text(&c["status"]) == told))
    }) {
        return true;
    }
    // Or what an open command palette says of its search.
    let searching =
        controller::with::<Palette, _>(world.engine(), |p, _| p.is_open() && !p.searching())
            .unwrap_or(false);
    if searching && let Ok(palette) = world.engine().singleton::<PaletteObject>() {
        for name in ["emptyText", "status"] {
            let said = world.engine().read_by_name(palette, name);
            if text(&hal_c2_shell::json::from_value(world.engine(), &said)) == told {
                return true;
            }
        }
    }
    // The welcome wizard's pairing, setup terminal or import error.
    if super::onboarding::onboarding_tells(world, told) {
        return true;
    }
    if world
        .told_in_place
        .as_ref()
        .is_some_and(|in_place| in_place(world).iter().any(|said| said == told))
    {
        return true;
    }
    // Or why the add-provider wizard does not take the instance id.
    if text(at(
        &world.state("providerSettings"),
        "wizard.instanceIdError",
    )) == told
    {
        return true;
    }
    // Or what a brick on screen says.
    world
        .peek_part::<Shown>()
        .and_then(|shown| shown.0)
        .is_some_and(|brick| brick.shows(world, told).unwrap_or(false))
}

pub fn register(steps: &mut Steps) {
    // Threads.
    steps.step(
        &format!("the user is looking at a thread in {Q} whose agent is working"),
        |world, c, _| {
            stream::look_at_thread(world, &c[0])?;
            start_working(world)
        },
    );
    steps.step(
        "a thread whose agent is working on a turn",
        |world, _, _| start_working(world),
    );
    steps.step("a project with an open thread", |world, _, _| {
        open_thread(world)
    });
    steps.step("the thread's provider is ready", |_, _, _| Ok(()));

    // Approvals.
    steps.step(&format!("the agent asks to run {Q}"), |world, c, _| {
        approval(world, "command", &c[0], vec![], "live").map(drop)
    });
    steps.step(
        "the user chooses to (approve it|decline it|always allow it this session|cancel the request)",
        |world, c, _| {
            let decision = match c[0].as_str() {
                "approve it" => "accept",
                "decline it" => "decline",
                "always allow it this session" => "acceptForSession",
                _ => "cancel",
            };
            // The option the approval offers for it, as the panel's buttons.
            let options = first(world, "approvals")?["options"].clone();
            let offered = options
                .as_array()
                .is_some_and(|all| all.iter().any(|o| text(&o["decision"]) == decision));
            expect!(offered, "the approval offers {}", show(&options));
            respond(world, decision)
        },
    );
    steps.step("the command runs and the agent continues", |world, _, _| {
        expect_decision(world, "accept")
    });
    steps.step(
        "the command is not run and the agent is told it was declined",
        |world, _, _| expect_decision(world, "decline"),
    );
    steps.step(
        "the command runs and matching requests stop asking this session",
        |world, _, _| expect_decision(world, "acceptForSession"),
    );
    steps.step(
        "the command is not run and the turn stops waiting",
        |world, _, _| expect_decision(world, "cancel"),
    );
    steps.step(
        "the agent requests (to run a command|to read a file|to change a file|access for an app|a permission for an app)",
        |world, c, _| {
            let kind = match c[0].as_str() {
                "to run a command" => "command",
                "to read a file" => "file-read",
                "to change a file" => "file-change",
                "access for an app" => "mcp-elicitation",
                _ => "permission",
            };
            approval(world, kind, "", vec![], "live").map(drop)
        },
    );
    steps.step(&format!("the request is titled {Q}"), |world, c, _| {
        let title = text(&first(world, "approvals")?["title"]);
        expect!(title == c[0], "the request is titled \"{title}\"");
        Ok(())
    });
    steps.step(
        "the provider warns that an option may follow injected instructions",
        |world, _, _| {
            approval(
                world,
                "mcp-elicitation",
                "Allow the browser app?",
                vec![
                    json!({"decision": "accept", "label": "Allow"}),
                    json!({"decision": "acceptForSession", "label": "Always allow",
                           "warning": "The app may follow instructions injected into pages it reads."}),
                    json!({"decision": "decline", "label": "Deny"}),
                ],
                "live",
            )
            .map(drop)
        },
    );
    steps.step("the user reviews the approval", |_, _, _| Ok(()));
    steps.step("the warning is shown next to that option", |world, _, _| {
        let options = first(world, "approvals")?["options"].clone();
        let warned: Vec<String> = options
            .as_array()
            .into_iter()
            .flatten()
            .filter(|option| !text(&option["warning"]).is_empty())
            .map(|option| text(&option["label"]))
            .collect();
        expect!(
            warned == ["Always allow"],
            "the options are {}",
            show(&options)
        );
        Ok(())
    });
    steps.step(
        "the provider process stopped while an approval was pending",
        |world, _, _| approval(world, "command", "rm -rf dist", vec![], "not_resumable").map(drop),
    );
    steps.step("the approval cannot be answered", |world, _, _| {
        let shown = first(world, "approvals")?;
        expect!(
            shown["canRespond"] != json!(true),
            "the approval is {}",
            show(&shown)
        );
        Ok(())
    });
    // Shared with other domains' messages: why the pending approval cannot
    // be answered, a toast, or what a settings page shows instead.
    steps.step(&format!("the user is told {Q}"), |world, c, _| {
        let told = c[0].clone();
        let problem = condition_problem(world);
        let shown = told.clone();
        world.wait_for_with(
            move |w| tells(w, &told) || problem == told,
            move |w| {
                format!(
                    "\"{shown}\"; the turn is {}, the toasts are {}",
                    show(&turn(w)),
                    show(&w.state("toasts"))
                )
            },
        )
    });
    steps.step("the user approved a pending request", |world, _, _| {
        approval(world, "command", "npm test", vec![], "live").map(drop)
    });
    steps.step(
        "sending the answer fails because (the request was already resolved|the connection dropped for a moment)",
        |world, c, _| {
            let refusal = if c[0] == "the request was already resolved" {
                "no pending request"
            } else {
                "connection closed"
            };
            world
                .mc
                .refusals
                .insert("runtime-request.respond".into(), refusal.into());
            respond(world, "accept")
        },
    );
    steps.step("the approval is closed", |world, _, _| {
        expect!(
            listed(world, "approvals").is_empty(),
            "the turn is {}",
            show(&turn(world))
        );
        Ok(())
    });
    steps.step(
        "the approval is still open so the user can answer again",
        |world, _, _| {
            let shown = first(world, "approvals")?;
            expect!(
                shown["canRespond"] == json!(true) && shown["responding"] != json!(true),
                "the approval is {}",
                show(&shown)
            );
            Ok(())
        },
    );

    // Questions.
    steps.step(
        &format!("the agent asks {Q} with the options {Q}, {Q} and {Q}"),
        |world, c, _| question(world, &c[0], &c[1..4], false, "live").map(drop),
    );
    steps.step(
        &format!("the agent asks {Q} with three options"),
        |world, c, _| {
            let labels = ["Postgres", "SQLite", "MySQL"].map(String::from);
            question(world, &c[0], &labels, false, "live").map(drop)
        },
    );
    steps.step(
        "the question allows (one answer|several answers)",
        |world, c, _| {
            // The question as the agent asked it, again with the choice it
            // allows.
            let pending = first(world, "questions")?;
            let request_id = text(&pending["requestId"]);
            let shown = pending["questions"][0].clone();
            let labels: Vec<String> = shown["options"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|option| text(&option["label"]))
                .collect();
            stream::set(
                world,
                "runtime-request",
                &request_id,
                json!({"status": "resolved"}),
            )?;
            question(
                world,
                &text(&shown["question"]),
                &labels,
                c[0] == "several answers",
                "live",
            )
            .map(drop)
        },
    );
    steps.step(&format!("the user picks {Q} and {Q}"), |world, c, _| {
        answer(world, json!([c[0], c[1]]))
    });
    steps.step(&format!("the user answers {Q}"), |world, c, _| {
        answer(world, json!(c[0]))
    });
    steps.step(&format!("the agent receives {Q}"), |world, c, _| {
        if crate::steps::composer_defaults::composer_message_received(world, &c[0])? {
            return Ok(());
        }
        let received = received_answer(world)?;
        expect!(
            received == json!(c[0]),
            "the agent received {}",
            show(&received)
        );
        Ok(())
    });
    steps.step(&format!("the agent receives {Q} and {Q}"), |world, c, _| {
        let received = received_answer(world)?;
        expect!(
            received == json!([c[0], c[1]]),
            "the agent received {}",
            show(&received)
        );
        Ok(())
    });
    steps.step(
        "the agent asked a question that can be answered by message",
        |world, _, _| {
            let labels = ["Postgres", "SQLite"].map(String::from);
            question(world, "Which database?", &labels, false, "message").map(drop)
        },
    );
    steps.step("the turn ends before the user answers", |world, _, _| {
        finish_turn(world)
    });
    steps.step("the user can still answer the question", |world, _, _| {
        let shown = first(world, "questions")?;
        expect!(
            shown["canRespond"] == json!(true),
            "the question is {}",
            show(&shown)
        );
        answer(world, json!("SQLite"))?;
        expect!(
            received_answer(world)? == json!("SQLite"),
            "the answer did not reach the MC"
        );
        Ok(())
    });
    steps.step(
        &format!("the agent has asked {Q} with options {Q} and {Q}"),
        |world, c, _| {
            start_working(world)?;
            question(world, &c[0], &c[1..3], false, "live").map(drop)
        },
    );
    steps.step(
        "the user dismisses the question without answering",
        |world, _, _| {
            let request_id = first(world, "questions")?["requestId"].clone();
            world.dispatch(
                "composer.question.dismiss",
                json!({"requestId": request_id}),
            )?;
            world.sync()
        },
    );
    steps.step(
        "the agent is told the question was dismissed",
        |world, _, _| {
            let command = last_command(world, "thread.user-input.dismiss")?;
            expect!(
                text(&command["threadId"]) == THREAD && !text(&command["requestId"]).is_empty(),
                "the MC was told {}",
                show(&command)
            );
            expect!(
                commands_of(world, "runtime-request.respond")?.is_empty(),
                "the agent was also given an answer"
            );
            Ok(())
        },
    );

    // Plans.
    steps.step(
        "the agent (?:has proposed|proposed) a plan(?: and the thread is idle)?",
        |world, _, _| {
            propose_plan(world, true)?;
            world.wait_for_with(
                |w| !turn(w)["plan"].is_null(),
                |w| format!("the plan to be offered; the turn is {}", show(&turn(w))),
            )
        },
    );
    steps.step(
        "the user (?:implements the plan with no feedback|chooses to implement the plan)",
        |world, _, _| {
            world.dispatch("composer.plan.implement", json!({}))?;
            world.sync()
        },
    );
    steps.step(
        "(?:the agent starts implementing it in this thread|a turn starts that carries out the plan)",
        |world, _, _| {
            let message = last_message(world)?;
            expect!(
                text(&message["threadId"]) == THREAD
                    && text(&message["text"]).starts_with("PLEASE IMPLEMENT THIS PLAN:\n# Tax line")
                    && text(at(&message, "sourcePlanRef.planId")) == "plan-1",
                "the MC was sent {}",
                show(&message)
            );
            let mode = last_command(world, "thread.interaction-mode.set")?;
            expect!(
                text(&mode["interactionMode"]) == "default",
                "the thread was set to {}",
                show(&mode)
            );
            Ok(())
        },
    );
    steps.step("the plan card is no longer offered", |world, _, _| {
        // What the MC does with the message's sourcePlanRef.
        stream::set(world, "plan", "plan-1", json!({"status": "completed"}))?;
        expect!(
            turn(world)["plan"].is_null(),
            "the turn is {}",
            show(&turn(world))
        );
        Ok(())
    });
    steps.step(&format!("the user sends {Q} as feedback"), |world, c, _| {
        submit(world, &c[0])?;
        world.sync()
    });
    steps.step("the agent revises the plan", |world, _, _| {
        let message = last_message(world)?;
        expect!(
            text(&message["text"]) == "split the migration into its own step"
                && message.get("sourcePlanRef").is_none(),
            "the MC was sent {}",
            show(&message)
        );
        Ok(())
    });
    steps.step("the thread stays in plan mode", |world, _, _| {
        for mode in commands_of(world, "thread.interaction-mode.set")? {
            expect!(
                text(&mode["interactionMode"]) == "plan",
                "the thread was set to {}",
                show(&mode)
            );
        }
        Ok(())
    });
    steps.step(
        "the agent is proposing a plan in the running turn",
        |world, _, _| propose_plan(world, false),
    );
    steps.step("no plan is offered", |world, _, _| {
        expect!(
            turn(world)["plan"].is_null(),
            "the turn is {}",
            show(&turn(world))
        );
        Ok(())
    });

    // Follow-ups and the queue.
    steps.step(
        &format!("the follow-up behaviour setting is {Q}"),
        |world, c, _| {
            let engine = world.engine().clone();
            Settings::of(&engine).write_device(&engine, "followUpBehavior", json!(c[0]));
            world.pump()
        },
    );
    steps.step(&format!("{Q} is queued"), |world, c, _| {
        // As a precondition it is waiting in the thread's queue.
        if !world.checking {
            return queue_message(world, &c[0]);
        }
        let message = last_message(world)?;
        expect!(
            text(&message["text"]) == c[0]
                && text(at(&message, "dispatchMode.type")) == "queue_after_active"
                && message.get("deliveryIntent").is_none(),
            "the MC was sent {}",
            show(&message)
        );
        Ok(())
    });
    steps.step(&format!("{Q} steers the running turn"), |world, c, _| {
        let message = last_message(world)?;
        expect!(
            text(&message["text"]) == c[0]
                && text(&message["deliveryIntent"]) == "steer"
                && text(at(&message, "dispatchMode.type")) == "start_immediately",
            "the MC was sent {}",
            show(&message)
        );
        Ok(())
    });
    steps.step("the composer is empty", |world, _, _| {
        let draft = open_draft(world);
        expect!(draft.is_empty(), "the draft reads \"{draft}\"");
        Ok(())
    });
    steps.step("the user chooses to stop", |world, _, _| {
        world.dispatch("composer.interrupt", json!({}))?;
        world.sync()
    });
    steps.step("the running turn is interrupted", |world, _, _| {
        let command = last_command(world, "run.interrupt")?;
        let run = world.mc.part::<FakeStreams>().run.clone();
        expect!(
            text(&command["runId"]) == run,
            "the MC was told {}",
            show(&command)
        );
        Ok(())
    });
    steps.step(&format!("{Q} and {Q} are queued"), |world, c, _| {
        queue_message(world, &c[0])?;
        queue_message(world, &c[1])
    });
    // What the MC queued for the agent itself (delegation.ex and the Claude
    // runtime's wake): the fields are what its message carries.
    fn queue_for_agent(world: &mut World, typed: &str, fields: Value) -> Outcome {
        queue_message(world, typed)?;
        stream::set(world, "message", &format!("message-{typed}"), fields)
    }
    steps.step(
        "the MC queued a delegated task's result for the agent",
        |world, _, _| {
            queue_for_agent(
                world,
                "<delegated_task_result taskId=\"task:1\">done</delegated_task_result>",
                json!({"delegatedCompletion": {"taskId": "task:1", "status": "completed"},
                       "notification": {"outcome": "completed", "summary": "Tax tests finished"}}),
            )
        },
    );
    steps.step(
        "the MC queued a delegated task's result stored before results were notifications for the agent",
        |world, _, _| {
            queue_for_agent(
                world,
                "<delegated_task_result taskId=\"task:1\" title=\"Tax tests\" status=\"completed\" childThreadId=\"thread-9\">\ndone\n</delegated_task_result>",
                json!({"delegatedCompletion": {"taskId": "task:1", "status": "completed"},
                       "createdBy": "system"}),
            )
        },
    );
    steps.step(
        "the MC queued the agent's own wake-up for the agent",
        |world, _, _| {
            queue_for_agent(
                world,
                "Background task completed.",
                json!({"providerWake": true,
                       "notification": {"outcome": "updated", "summary": "Background activity updated"}}),
            )
        },
    );
    steps.step(
        &format!("the composer lists only the queued message {Q}"),
        |world, c, _| {
            let texts = queued_texts(world);
            expect!(
                texts == [c[0].clone()],
                "the queue lists {}",
                texts.join(" | ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the composer shows {Q} waiting behind it"),
        |world, c, _| {
            let summaries: Vec<String> = listed(world, "waiting")
                .iter()
                .map(|waiting| text(&waiting["summary"]))
                .collect();
            expect!(
                summaries == [c[0].clone()],
                "waiting behind the queue: {}",
                summaries.join(" | ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the composer lists the queued messages {Q} and {Q}"),
        |world, c, _| {
            let texts = queued_texts(world);
            expect!(
                texts == [c[0].clone(), c[1].clone()],
                "the composer lists [{}]",
                texts.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user removes {Q} from the queue"),
        |world, c, _| {
            let run = queued_run(world, &c[0])?;
            world.dispatch("composer.queue.remove", json!({"runId": run}))?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user steers the running turn with the queued {Q}"),
        |world, c, _| {
            let run = queued_run(world, &c[0])?;
            world.dispatch("composer.queue.steer", json!({"runId": run}))?;
            world.sync()
        },
    );
    steps.step(
        &format!("the MC is asked to cancel the queued run of {Q}"),
        |world, c, _| {
            let command = last_command(world, "queued-run.cancel")?;
            expect!(
                text(&command["runId"]) == format!("run-queued-{}", c[0]),
                "the MC was told {}",
                show(&command)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the MC is asked to steer the running turn with the queued run of {Q}"),
        |world, c, _| {
            let command = last_command(world, "queued-message.promote-to-steer")?;
            let run = world.mc.part::<FakeStreams>().run.clone();
            expect!(
                text(&command["queuedRunId"]) == format!("run-queued-{}", c[0])
                    && text(&command["targetRunId"]) == run,
                "the MC was told {}",
                show(&command)
            );
            Ok(())
        },
    );

    // A queue the MC holds after a restart (HalC2.Orchestration.Recovery
    // marks its queued runs `queueHeld`) is resumed from the card the
    // TurnRequests brick draws.
    steps.step(
        &format!("{Q} was queued when the MC restarted"),
        |world, c, _| queue_message(world, &c[0]),
    );
    steps.step(
        "a provider wake was queued when the MC restarted",
        |world, _, _| queue_wake(world),
    );
    steps.step("the MC comes back", |world, _, _| {
        let entries: Vec<Json> = listed(world, "queue")
            .into_iter()
            .chain(listed(world, "waiting"))
            .collect();
        for entry in entries {
            stream::set(
                world,
                "run",
                &text(&entry["runId"]),
                json!({"queueHeld": true}),
            )?;
        }
        world.wait_for_with(
            |w| turn(w)["queueHeld"] == json!(true),
            |w| format!("the queue to be held; the turn is {}", show(&turn(w))),
        )
    });
    steps.step(
        &format!("the queue is headed {Q} and says {Q}"),
        |world, c, _| {
            let brick = requests_brick(world)?;
            let (head, says) = (c[0].clone(), c[1].clone());
            let shown = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                move |w| {
                    brick.shows(w, &head).unwrap_or(false) && brick.shows(w, &says).unwrap_or(false)
                },
                move |w| {
                    format!(
                        "the queue to read \"{}\" and \"{}\"; the turn is {}",
                        shown.0,
                        shown.1,
                        show(&turn(w))
                    )
                },
            )
        },
    );
    steps.step("the user resumes the queue", |world, _, _| {
        let brick = requests_brick(world)?;
        world.wait_for("the queue's Resume queue button", move |w| {
            matches!(brick.find(w, "queueResume"), Ok(Some(item)) if brick.flag(w, item, "visible"))
        })?;
        brick.click(world, "queueResume")?;
        world.sync()
    });
    steps.step("the MC is asked to resume the queue", |world, _, _| {
        let command = last_command(world, "queue.resume")?;
        expect!(
            text(&command["threadId"]) == THREAD,
            "the MC was told {}",
            show(&command)
        );
        Ok(())
    });
    steps.step("the MC is not asked to resume the queue", |world, _, _| {
        let found = commands_of(world, "queue.resume")?;
        expect!(found.is_empty(), "the MC has {}", world.describe_commands());
        Ok(())
    });

    // Editing a queued message.
    steps.step(
        "the user starts editing the last queued message from the start of the composer",
        |world, _, _| {
            // The brick sends this for its edit key with the caret at the
            // start.
            world.dispatch("composer.queue.edit", json!({}))?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user changes the edit to {Q}"),
        |world, c, _| type_into(world, &c[0]),
    );
    steps.step(
        &format!("the user sends {Q} from the composer"),
        |world, c, _| {
            submit(world, &c[0])?;
            world.sync()
        },
    );
    steps.step("the user cancels the edit", |world, _, _| {
        world.dispatch("composer.queue.edit.cancel", json!({}))
    });
    steps.step(
        &format!("the composer holds {Q}(?: again)?"),
        |world, c, _| {
            let want = c[0].clone();
            world.wait_for_with(
                move |w| text(&w.state("composer")["text"]) == want,
                |w| format!("the composer shows {}", show(&w.state("composer"))),
            )
        },
    );
    steps.step(&format!("the queued run of {Q} starts"), |world, c, _| {
        stream::set(
            world,
            "run",
            &format!("run-queued-{}", c[0]),
            json!({"status": "running"}),
        )
    });
    steps.step(
        &format!("the MC is asked to change the queued run of {Q} to {Q}"),
        |world, c, _| {
            let command = last_command(world, "queued-run.edit")?;
            expect!(
                text(&command["runId"]) == format!("run-queued-{}", c[0])
                    && text(&command["text"]) == c[1],
                "the MC was told {}",
                show(&command)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the queued message still reads {Q}"),
        |world, c, _| {
            let texts = queued_texts(world);
            let edits = commands_of(world, "queued-run.edit")?;
            expect!(
                texts.contains(&c[0]) && edits.is_empty(),
                "the queue is [{}] and the MC has {}",
                texts.join(", "),
                world.describe_commands()
            );
            Ok(())
        },
    );

    // Answers in flight.
    steps.step("the user approves it", |world, _, _| {
        respond(world, "accept")
    });
    steps.step("the approval shows it is being answered", |world, _, _| {
        let shown = first(world, "approvals")?;
        expect!(
            shown["responding"] == json!(true),
            "the approval is {}",
            show(&shown)
        );
        Ok(())
    });
    steps.step("the MC receives one answer", |world, _, _| {
        let answers = commands_of(world, "runtime-request.respond")?.len();
        expect!(answers == 1, "the MC received {answers} answers");
        Ok(())
    });

    // Drafts.
    steps.step(
        &format!("the user has typed {Q} in thread A"),
        |world, c, _| type_into(world, &c[0]),
    );
    steps.step(
        "the user switches to thread B and back to thread A",
        |world, _, _| {
            let thread_b = thread_b(world)?;
            stream::look(world, &thread_b, true)?;
            let thread_a = thread_key(world);
            stream::look(world, &thread_a, true)
        },
    );
    steps.step(&format!("thread A's draft reads {Q}"), |world, c, _| {
        let shown = world.state("composer");
        expect!(
            text(&shown["target"]) == thread_key(world) && text(&shown["text"]) == c[0],
            "the composer shows {}",
            show(&shown)
        );
        Ok(())
    });
    steps.step("thread B's draft is empty", |world, _, _| {
        let thread_b = thread_b(world)?;
        let draft = draft_of(world, &thread_b);
        expect!(draft.is_empty(), "thread B's draft reads \"{draft}\"");
        Ok(())
    });
    steps.step("the environment is disconnected", |world, _, _| {
        world.mc.stop_accepting();
        world.mc.drop_connection();
        world.wait_for("the shell to see the drop", |w| !w.client_ready())
    });
    steps.step(&format!("the user has typed {Q}"), |world, c, _| {
        type_into(world, &c[0])
    });
    steps.step("the user tries to send it", |world, _, _| {
        let draft = open_draft(world);
        submit(world, &draft)
    });
    steps.step(
        "the user is told the message was not sent because they are not connected",
        |world, _, _| {
            world.wait_for("a toast", |w| !toasts(w).is_empty())?;
            let toast = toasts(world).pop().unwrap_or(Json::Null);
            expect!(
                text(&toast["type"]) == "warning"
                    && text(&toast["title"]) == "Not connected: message not sent",
                "the toast is {}",
                show(&toast)
            );
            expect!(
                world.mc.commands.is_empty(),
                "the MC has {}",
                world.describe_commands()
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the draft (?:still reads {Q}|reads {Q} again)"),
        |world, c, _| {
            let expected = if c[0].is_empty() {
                c[1].clone()
            } else {
                c[0].clone()
            };
            world.wait_for_with(
                move |w| open_draft(w) == expected,
                |w| format!("the draft reads \"{}\"", open_draft(w)),
            )
        },
    );
    steps.step(
        "the user sends it and the MC rejects the message",
        |world, _, _| {
            world
                .mc
                .refusals
                .insert("message.dispatch".into(), "Provider unavailable".into());
            let draft = open_draft(world);
            submit(world, &draft)?;
            world.sync()
        },
    );
    steps.step(
        "the user sends it and the MC cannot start the thread",
        |world, _, _| {
            world.mc.refusals.insert(
                "orchestration.launchThread".into(),
                "Provider unavailable".into(),
            );
            let draft = open_draft(world);
            submit(world, &draft)?;
            world.sync()?;
            world.wait_for_with(
                |w| draft_of(w, &w.draft_id) == "Fix the failing test",
                |w| format!("the draft reads \"{}\"", draft_of(w, &w.draft_id)),
            )
        },
    );
    steps.step(
        &format!("the new thread's draft reads {Q} with {Q}"),
        |world, c, _| {
            fn names(world: &World) -> Vec<String> {
                composer::attachments(world.engine(), &world.draft_id)
                    .iter()
                    .map(|attachment| text(&attachment["name"]))
                    .collect()
            }
            let (draft, name) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                move |w| draft_of(w, &w.draft_id) == draft && names(w) == [name.clone()],
                |w| {
                    format!(
                        "the draft reads \"{}\" with [{}]",
                        draft_of(w, &w.draft_id),
                        names(w).join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        "the user starts a new thread in the project",
        |world, _, _| {
            let key = world.project_key(PROJECT);
            world.start_new_thread(json!({"projectKey": key}))?;
            expect!(
                !world.draft_id.is_empty(),
                "{}",
                show(&world.state("route"))
            );
            Ok(())
        },
    );
    steps.step("the user sends it before the MC answers", |world, _, _| {
        world.mc.hold("answers");
        let draft = open_draft(world);
        submit(world, &draft)?;
        world.sync()
    });
    steps.step(
        &format!("the user types {Q} while it is sending"),
        |world, c, _| type_into(world, &c[0]),
    );
    steps.step(
        &format!("the new thread's composer reads {Q}"),
        |world, c, _| {
            fn opened(world: &World) -> bool {
                text(&world.state("route")["kind"]) == "thread"
            }
            let want = c[0].clone();
            world.wait_for_with(
                move |w| opened(w) && open_draft(w) == want,
                |w| {
                    format!(
                        "the {} composer reads \"{}\"",
                        if opened(w) { "thread's" } else { "draft's" },
                        open_draft(w)
                    )
                },
            )
        },
    );
    steps.step("the MC takes the message", |world, _, _| {
        world.mc.answer_held();
        world.sync()
    });
    steps.step(
        "the thread (no longer )?says the message is sending",
        |world, c, _| {
            // An optional group that did not match captures nothing.
            let sending = c[0].is_empty();
            fn busy(world: &World) -> bool {
                world.state("composer")["isSendBusy"] == json!(true)
            }
            world.wait_for_with(
                move |w| busy(w) == sending,
                |w| {
                    format!(
                        "the composer's send is {}busy",
                        if busy(w) { "" } else { "not " }
                    )
                },
            )
        },
    );
    steps.step("the user sees why the send failed", |world, _, _| {
        world.wait_for("a toast", |w| !toasts(w).is_empty())?;
        let toast = toasts(world).pop().unwrap_or(Json::Null);
        expect!(
            text(&toast["title"]) == "Failed to send message"
                && text(&toast["description"]) == "Provider unavailable",
            "the toast is {}",
            show(&toast)
        );
        Ok(())
    });
}

/// Picks `label` in the agent's pending question, as the question panel
/// does.
pub fn pick_answer(world: &mut World, label: &str) -> Outcome {
    answer(world, json!(label))
}

/// Opens a thread of "shop" on a connected MC, unless one is open.
pub fn open_turn_thread(world: &mut World) -> Outcome {
    open_thread(world)
}

/// The same thread with its agent working on a turn.
pub fn start_working_turn(world: &mut World) -> Outcome {
    start_working(world)
}

/// A message waiting in the thread's queue behind the running turn (its
/// run is "run-queued-<text>").
pub fn queue_turn_message(world: &mut World, typed: &str) -> Outcome {
    queue_message(world, typed)
}
