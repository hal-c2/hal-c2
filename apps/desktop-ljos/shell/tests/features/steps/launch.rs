//! A new thread's first send (the composer's `submit` of a draft): the
//! thread the MC launches for it, what the launch carries, and the window
//! moving to it (desktop-qt's LaunchSteps.cpp).

use hal_c2_shell::controllers::composer::kept;
use hal_c2_shell::controllers::drafts;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use serde_json::{Value, json};

use crate::expect;
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;

/// Every `orchestration.launchThread` the fake MC was asked, and of which
/// machine.
#[derive(Default)]
pub struct FakeLaunches {
    pub calls: Vec<Value>,
    /// The machine each of `calls` was asked of, by environment id.
    pub machines: Vec<String>,
}

/// `orchestration.launchThread`: the machine it is asked of makes the thread
/// (its shell row) and answers with its id; refused like a command, held
/// with the answers.
fn extension(mc: &mut FakeMc) {
    mc.on_rpc("orchestration.launchThread", |mc, rpc| {
        let method = "orchestration.launchThread";
        let machine = if rpc.environment.is_empty() {
            mc.environment_id.clone()
        } else {
            rpc.environment.clone()
        };
        let launches = mc.part::<FakeLaunches>();
        launches.calls.push(rpc.payload.clone());
        launches.machines.push(machine.clone());
        let rpc = rpc.clone();
        let answer = move |mc: &mut FakeMc| {
            if let Some(refusal) = mc.refusals.get(method).cloned() {
                mc.refuse(&rpc, &refusal);
                return;
            }
            let thread = text(&rpc.payload["threadId"]);
            let row = json!({
                "id": thread,
                "projectId": rpc.payload["projectId"],
                "title": rpc.payload["title"],
                "createdAt": "2026-09-23T10:00:00Z",
                "updatedAt": "2026-09-23T10:00:00Z",
            });
            if mc.members.contains(&machine) {
                mc.send_peer_row(&machine, &thread, &row);
            } else {
                mc.threads.insert(thread.clone(), row.clone());
                mc.send_row(&thread, &row);
            }
            mc.reply(&rpc, json!({"threadId": thread, "resumed": false}));
        };
        if mc.holding("answers") {
            mc.defer(answer);
        } else {
            answer(mc);
        }
        Ok(())
    });
}

/// The prompt the last background start sent.
#[derive(Default)]
struct Background {
    text: String,
}

/// A toast of `kind` titled `title`, with the one action `action` (any,
/// when empty).
fn toast_offering(world: &World, kind: &str, title: &str, action: &str) -> bool {
    let toasts = world.state("toasts");
    at(&toasts, "items")
        .as_array()
        .into_iter()
        .flatten()
        .any(|toast| {
            if toast["type"] != json!(kind) || toast["title"] != json!(title) {
                return false;
            }
            let actions = toast["actions"].as_array().cloned().unwrap_or_default();
            action.is_empty() || (actions.len() == 1 && actions[0]["label"] == json!(action))
        })
}

/// Every `orchestration.launchThread` payload the MC got, oldest first.
pub fn launch_calls(world: &mut World) -> Vec<Value> {
    world.mc.part::<FakeLaunches>().calls.clone()
}

fn last_launch(world: &mut World) -> Outcome<Value> {
    world.wait_for_with(
        |w| {
            !w.mc
                .peek::<FakeLaunches>()
                .is_none_or(|l| l.calls.is_empty())
        },
        |_| "a launch; the MC got none".into(),
    )?;
    Ok(launch_calls(world).pop().unwrap_or(Value::Null))
}

fn message(launch: &Value) -> &Value {
    &launch["initialMessage"]
}

fn strategy(launch: &Value) -> &Value {
    &launch["workspaceStrategy"]
}

fn describe(launch: &Value) -> String {
    show(launch)
}

fn route(world: &World) -> Outcome<Route> {
    world.with::<Navigation, _>(|n, _| n.route().clone())
}

fn thread_key(world: &World) -> Outcome<String> {
    world.with::<Navigation, _>(|n, _| n.thread_key().to_owned())
}

fn on_draft(world: &World) -> bool {
    route(world).is_ok_and(|r| matches!(r, Route::Draft(_)))
}

/// The user starts a new thread in the project the window shows.
fn start_draft(world: &mut World) -> Outcome {
    world.start_new_thread(json!({}))?;
    world.wait_for_with(on_draft, |w| {
        format!("a draft; the route is {}", show(&w.state("route")))
    })?;
    world.draft_id = world.with::<Navigation, _>(|n, _| n.draft_id().to_owned())?;
    world.wait_for_with(
        |w| at(&w.state("workspace"), "isDraft") == &json!(true),
        |w| {
            format!(
                "the header to show the draft; it shows {}",
                show(&w.state("workspace"))
            )
        },
    )
}

/// Waits for the window to show the thread the last launch made.
fn wait_for_launched_thread(world: &mut World, launch: &Value) -> Outcome {
    let key = format!("{}:{}", world.mc.environment_id, text(&launch["threadId"]));
    let wanted = key.clone();
    world.wait_for_with(
        move |w| thread_key(w).is_ok_and(|k| k == wanted),
        |w| format!("{key}; the route is {}", show(&w.state("route"))),
    )
}

/// The first message of a new thread, typed.
fn type_first(world: &mut World, words: &str) -> Outcome {
    // The window may already have landed on a draft (the drafts controller's `land`).
    if on_draft(world) {
        world.draft_id = world.with::<Navigation, _>(|n, _| n.draft_id().to_owned())?;
    } else {
        start_draft(world)?;
    }
    let target = world.draft_id.clone();
    world.dispatch(
        "composer.text.set",
        json!({"target": target, "text": words, "cursor": words.chars().count()}),
    )
}

fn send_in_background(world: &mut World) -> Outcome {
    let target = world.draft_id.clone();
    world.mc.part::<Background>().text = kept::draft(world.engine(), &target);
    world.dispatch("composer.submit", json!({"intent": "background"}))
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // The user.
    steps.step(
        "the user is starting a new thread in the project",
        |world, _, _| start_draft(world),
    );
    steps.step(
        &format!("the user sends {Q} in the background"),
        |world, c, _| {
            world.dispatch(
                "composer.submit",
                json!({"text": c[0], "intent": "background"}),
            )
        },
    );
    steps.step("the user tries to start the thread", |world, _, _| {
        world.dispatch(
            "composer.submit",
            json!({"text": "Add tax to the cart", "intent": "foreground"}),
        )
    });
    steps.step(
        "the user tries to start a thread with an empty first message",
        |world, _, _| {
            start_draft(world)?;
            world.dispatch(
                "composer.submit",
                json!({"text": "  ", "intent": "foreground"}),
            )
        },
    );
    steps.step("the user goes back", |world, _, _| {
        world.with::<Navigation, _>(|n, engine| n.back(engine))
    });

    // The launch.
    steps.step(
        &format!("a thread titled from {Q} is created"),
        |world, c, _| {
            let launch = last_launch(world)?;
            expect!(
                launch["title"] == json!(c[0]) && launch["generateTitle"] == json!(true),
                "the launch is {}",
                describe(&launch)
            );
            wait_for_launched_thread(world, &launch)
        },
    );
    steps.step("its first turn starts with that message", |world, _, _| {
        let launch = last_launch(world)?;
        expect!(
            !text(&message(&launch)["text"]).is_empty()
                && message(&launch)["text"] == launch["title"],
            "the launch is {}",
            describe(&launch)
        );
        Ok(())
    });
    steps.step(
        &format!("the MC launches the thread with the message {Q} titled {Q}"),
        |world, c, _| {
            let launch = last_launch(world)?;
            expect!(
                message(&launch)["text"] == json!(c[0])
                    && launch["title"] == json!(c[1])
                    && !text(&message(&launch)["messageId"]).is_empty(),
                "the launch is {}",
                describe(&launch)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the launch is for the draft's thread in {Q}"),
        |world, c, _| {
            let launch = last_launch(world)?;
            let draft = drafts::draft(world.engine(), &world.draft_id);
            expect!(
                launch["projectId"] == json!(c[0])
                    && draft.is_none_or(|d| text(&launch["threadId"]) == d.thread_id),
                "the launch is {}",
                describe(&launch)
            );
            Ok(())
        },
    );
    steps.step("the launch starts in the project folder", |world, _, _| {
        let launch = last_launch(world)?;
        expect!(
            strategy(&launch)["type"] == json!("root"),
            "the launch is {}",
            describe(&launch)
        );
        Ok(())
    });
    steps.step(&format!("the worktree starts from {Q}"), |world, c, _| {
        let launch = last_launch(world)?;
        expect!(
            strategy(&launch)["type"] == json!("worktree")
                && strategy(&launch)["baseRef"] == json!(c[0]),
            "the launch is {}",
            describe(&launch)
        );
        Ok(())
    });
    steps.step(
        &format!("the launch uses the model {Q} of {Q} in the {Q} and {Q} modes"),
        |world, c, _| {
            let launch = last_launch(world)?;
            let model = &launch["modelSelection"];
            expect!(
                model["model"] == json!(c[0])
                    && model["instanceId"] == json!(c[1])
                    && launch["runtimeMode"] == json!(c[2])
                    && launch["interactionMode"] == json!(c[3]),
                "the launch is {}",
                describe(&launch)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the launch carries the image {Q}"),
        |world, c, _| {
            let launch = last_launch(world)?;
            let found = message(&launch)["attachments"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|image| image["name"] == json!(c[0]) && !text(&image["id"]).is_empty());
            expect!(found, "the launch is {}", describe(&launch));
            Ok(())
        },
    );
    steps.step("the thread is not started", |world, _, _| {
        world.sync()?;
        let calls = launch_calls(world);
        expect!(
            calls.is_empty() && on_draft(world),
            "the MC launched {}; the route is {}",
            describe(calls.first().unwrap_or(&Value::Null)),
            show(&world.state("route"))
        );
        Ok(())
    });
    steps.step("the user is told to pick a base branch", |world, _, _| {
        world.wait_for_with(
            |w| {
                at(&w.state("toasts"), "items")
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|toast| text(&toast["description"]).starts_with("Select a base branch"))
            },
            |w| format!("a toast; the shell shows {}", show(&w.state("toasts"))),
        )
    });
    steps.step("the MC launches no thread", |world, _, _| {
        world.sync()?;
        let calls = launch_calls(world);
        expect!(
            calls.is_empty(),
            "the MC launched {}",
            describe(calls.first().unwrap_or(&Value::Null))
        );
        Ok(())
    });
    // A launch whose answer a drop took, sent again as it was: the MC carries
    // out a command id once.
    steps.step(
        "the MC is asked for the same thread again",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakeLaunches>()
                        .is_some_and(|l| l.calls.len() >= 2)
                },
                |w| {
                    format!(
                        "a second launch; the MC got {}",
                        w.mc.peek::<FakeLaunches>().map_or(0, |l| l.calls.len())
                    )
                },
            )?;
            world.sync()?;
            let calls = launch_calls(world);
            expect!(
                calls.len() == 2 && calls[0] == calls[1],
                "the MC got {}, then {}",
                describe(&calls[0]),
                describe(calls.last().unwrap_or(&Value::Null))
            );
            Ok(())
        },
    );
    steps.step("the MC launches (\\d+) threads?", |world, c, _| {
        world.sync()?;
        let count = launch_calls(world).len();
        expect!(
            Some(count) == c[0].parse().ok(),
            "the MC launched {count} threads"
        );
        Ok(())
    });

    // What the window shows.
    steps.step(
        "the window shows the launched thread in the draft's place",
        |world, _, _| {
            let launch = last_launch(world)?;
            wait_for_launched_thread(world, &launch)?;
            expect!(
                drafts::draft(world.engine(), &world.draft_id).is_none(),
                "the shell still keeps the draft {}",
                world.draft_id
            );
            Ok(())
        },
    );
    steps.step(
        "the window shows the thread the background start launched",
        |world, _, _| {
            let launch = last_launch(world)?;
            wait_for_launched_thread(world, &launch)
        },
    );
    steps.step(&format!("the new thread still reads {Q}"), |world, c, _| {
        world.sync()?;
        let draft = drafts::draft(world.engine(), &world.draft_id);
        expect!(
            draft.as_ref().is_some_and(|d| d.text == c[0]),
            "the draft reads {}",
            draft.map_or("nothing; it is gone".to_owned(), |d| d.text)
        );
        Ok(())
    });

    // A background start (mod+alt+Enter): the prompt it sent.
    steps.step(
        "the user is writing the first message of a new thread",
        |world, _, _| type_first(world, "Set up the linter"),
    );
    steps.step("the user sends it in the background", |world, _, _| {
        send_in_background(world)
    });
    steps.step(
        &format!("the user sent {Q} in the background"),
        |world, c, _| {
            world.mc.hold("answers");
            type_first(world, &c[0])?;
            send_in_background(world)
        },
    );
    steps.step("the background thread fails to start", |world, _, _| {
        world.mc.refusals.insert(
            "orchestration.launchThread".into(),
            "Provider unavailable".into(),
        );
        world.sync()?;
        world.mc.answer_held();
        world.sync()
    });
    steps.step("a new thread starts with that message", |world, _, _| {
        let launch = last_launch(world)?;
        let sent = world.mc.part::<Background>().text.trim().to_owned();
        expect!(
            text(&message(&launch)["text"]) == sent,
            "the launch is {}",
            describe(&launch)
        );
        Ok(())
    });
    steps.step(
        "the user is told it started in the background with a way to open it",
        |world, _, _| {
            world.wait_for_with(
                |w| toast_offering(w, "success", "Started 1 thread in background", "Open"),
                |w| format!("the toast; the shell shows {}", show(&w.state("toasts"))),
            )
        },
    );
    steps.step("the composer is ready for another prompt", |world, _, _| {
        let launch = last_launch(world)?;
        let draft = drafts::draft(world.engine(), &world.draft_id);
        let composer = world.state("composer");
        let routed = world.with::<Navigation, _>(|n, _| n.draft_id().to_owned())?;
        expect!(
            routed == world.draft_id
                && draft.is_some_and(|d| d.thread_id != text(&launch["threadId"]))
                && composer["target"] == json!(world.draft_id)
                && text(&composer["text"]).is_empty(),
            "the composer shows {}",
            show(&composer)
        );
        Ok(())
    });
    steps.step(
        "the user is told the background prompt could not be sent",
        |world, _, _| {
            world.wait_for_with(
                |w| toast_offering(w, "error", "A background prompt could not be sent", ""),
                |w| format!("the toast; the shell shows {}", show(&w.state("toasts"))),
            )
        },
    );
    steps.step(
        &format!("the user can restore {Q} into the composer"),
        |world, c, _| {
            // The draft was empty, so the prompt is back in it.
            let composer = world.state("composer");
            expect!(
                composer["target"] == json!(world.draft_id) && composer["text"] == json!(c[0]),
                "the composer shows {}",
                show(&composer)
            );
            Ok(())
        },
    );
}
