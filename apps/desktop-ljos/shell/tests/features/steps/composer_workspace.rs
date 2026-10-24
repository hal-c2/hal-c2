//! Where a new thread runs, picked in the composer's context strip on screen
//! (desktop-qt's ComposerWorkspaceSteps.cpp): the machine, the checkout mode
//! and the branch (features/composer/model-and-mode.feature).

use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::workspace;
use ljos::prelude::{ObjectId, Value as QmlValue};
use serde_json::{Value, json};

use crate::brick::Brick;
use crate::harness::{Failure, Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::{
    composer_brick, composer_item, composer_part, composer_part_now, editor, press_in_composer,
    settle_composer, type_in_composer,
};
use crate::steps::launch::{FakeLaunches, launch_calls};
use crate::steps::settings::publish_providers;
use crate::steps::stream::{FakeStreams, PEER, PEER_ENVIRONMENT, PROJECT, THREAD};
use crate::steps::workspace::fake_git_repo;
use crate::world::World;
use crate::{expect, fail};

const ROOT: &str = "/work/shop";
const PROMPT: &str = "Add caching";

fn workspace_state(world: &World) -> Value {
    world.state("workspace")
}

fn toasts(world: &World) -> Vec<Value> {
    world.state("toasts")["items"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

pub fn part(world: &mut World, object_name: &str) -> Outcome<ObjectId> {
    match composer_part(world, object_name)? {
        Some(item) => Ok(item),
        None => fail!("the composer shows no {object_name}"),
    }
}

pub fn int(brick: &Brick, world: &World, item: ObjectId, name: &str) -> i64 {
    brick
        .text_of(world, item, name)
        .parse::<f64>()
        .map_or(0, |n| n as i64)
}

/// The popup of the combo box `control`.
pub fn popup_of(brick: &Brick, world: &World, control: ObjectId) -> Outcome<ObjectId> {
    match brick.read(world, control, "popup") {
        QmlValue::Object(popup) => Ok(popup),
        _ => fail!("the control has no popup"),
    }
}

pub fn click(world: &mut World, item: ObjectId) -> Outcome {
    let brick = composer_brick(world)?;
    let name = brick.text_of(world, item, "objectName");
    let visible = brick.flag(world, item, "visible");
    let enabled = brick.flag(world, item, "enabled");
    expect!(
        visible && enabled,
        "{name} cannot be clicked (visible {visible}, enabled {enabled}); the header shows {}",
        show(&workspace_state(world))
    );
    let (x, y) = brick.at(world, item, 0.5, 0.5)?;
    world.click_at(x, y)?;
    world.sync()
}

/// Opens the picker's list and takes its entry `index` with the keyboard.
fn pick(world: &mut World, picker_name: &str, index: i64) -> Outcome {
    let brick = composer_brick(world)?;
    let picker = part(world, picker_name)?;
    let popup = popup_of(&brick, world, picker)?;
    world.wait_for_with(
        |w| !brick.flag(w, popup, "visible"),
        |_| format!("{picker_name} to be closed"),
    )?;
    click(world, picker)?;
    world.wait_for_with(
        |w| brick.flag(w, popup, "opened"),
        |w| {
            format!(
                "{picker_name} to open (visible {}, enabled {}, focus {})",
                brick.flag(w, popup, "visible"),
                brick.flag(w, picker, "enabled"),
                brick.flag(w, picker, "activeFocus")
            )
        },
    )?;
    for _ in 0..8 {
        let at = int(&brick, world, picker, "highlightedIndex");
        if at == index {
            break;
        }
        press_in_composer(world, if at < index { "Down" } else { "Up" })?;
    }
    expect!(
        int(&brick, world, picker, "highlightedIndex") == index,
        "{picker_name} offers no entry {index}"
    );
    press_in_composer(world, "Return")?;
    world.sync()
}

/// The window on a new thread's draft in "shop", the composer on screen.
fn new_thread(world: &mut World) -> Outcome {
    let drafting = world
        .with::<Navigation, _>(|n, _| {
            matches!(
                n.route(),
                hal_c2_shell::controllers::navigation::Route::Draft(_)
            )
        })
        .unwrap_or(false);
    if !drafting {
        world.open_draft(PROJECT)?;
        world.wait_for_with(
            |w| workspace_state(w)["isDraft"] == json!(true),
            |w| format!("the draft; the header shows {}", show(&workspace_state(w))),
        )?;
    }
    composer_brick(world)?;
    Ok(())
}

/// Types `name` in the branch picker and confirms it once the refs answered.
fn confirm_branch(world: &mut World, name: &str) -> Outcome {
    let button = part(world, "branchButton")?;
    click(world, button)?;
    let brick = composer_brick(world)?;
    let find = |w: &World| brick.find(w, "branchPicker").ok().flatten();
    world.wait_for("the branch picker to open", |w| {
        find(w).is_some_and(|popup| brick.flag(w, popup, "opened"))
    })?;
    type_in_composer(world, name)?;
    world.wait_for_with(
        |w| {
            let state = workspace_state(w);
            state["branchQuery"] == json!(name) && state["branchesLoading"] != json!(true)
        },
        |w| {
            format!(
                "the refs for {name}; the header shows {}",
                show(&workspace_state(w))
            )
        },
    )?;
    world.sync()?;
    press_in_composer(world, "Enter")?;
    world.wait_for("the branch picker to close", |w| {
        find(w).is_none_or(|popup| !brick.flag(w, popup, "visible"))
    })
}

fn send_first_message(world: &mut World) -> Outcome {
    let item = composer_item(world)?;
    world
        .engine()
        .invoke_by_name(item, "focusInput", &[])
        .map_err(|e| Failure(format!("focusInput: {e:?}")))?;
    type_in_composer(world, PROMPT)?;
    press_in_composer(world, "Enter")?;
    Ok(())
}

pub fn launch(world: &mut World) -> Outcome<Value> {
    world.wait_for_with(
        |w| {
            !w.mc
                .peek::<crate::steps::launch::FakeLaunches>()
                .is_none_or(|l| l.calls.is_empty())
        },
        |w| {
            format!(
                "a launch; the toasts are {}",
                show(&Value::Array(toasts(w)))
            )
        },
    )?;
    Ok(launch_calls(world).pop().unwrap_or(Value::Null))
}

fn provider(id: &str, name: &str, models: &[&str]) -> Value {
    let list: Vec<Value> = models
        .iter()
        .map(|slug| json!({"slug": slug, "name": slug}))
        .collect();
    json!({"instanceId": id, "driver": id, "displayName": name, "enabled": true,
           "installed": true, "status": "ready", "models": list})
}

fn environments(world: &World) -> Vec<Value> {
    workspace_state(world)["environments"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn picker_text(world: &mut World, name: &str) -> Outcome<String> {
    let brick = composer_brick(world)?;
    let picker = part(world, name)?;
    Ok(brick.text_of(world, picker, "displayText"))
}

pub fn register(steps: &mut Steps) {
    // One prompt, several models (drafting-and-sending.feature).
    steps.step("the user is starting a new thread", |world, _, _| {
        // With Codex and Claude ready to take it.
        let listed = world.state("modelPicker")["instances"]
            .as_array()
            .is_none_or(|i| i.is_empty());
        if listed {
            publish_providers(
                &mut world.mc,
                vec![
                    provider("codex", "Codex", &["gpt-5", "gpt-5-codex"]),
                    provider("claudeAgent", "Claude", &["claude-opus", "claude-sonnet"]),
                ],
            );
            world.sync()?;
        }
        new_thread(world)?;
        world.wait_for_with(
            |w| w.state("composer")["selectedModel"] == json!("gpt-5"),
            |w| {
                format!(
                    "the draft on gpt-5; the composer shows {}",
                    show(&w.state("composer"))
                )
            },
        )
    });
    steps.step(
        &format!("the user chooses two models and a base branch and sends {Q}"),
        |world, c, _| {
            // The draft's own model, and Claude's beside it.
            let picker = part(world, "modelPicker")?;
            click(world, picker)?;
            world.wait_for("the model picker to open", |w| {
                composer_part_now(w, "modelPickerProvider:claudeAgent").is_some()
            })?;
            // Its enter transition done, the rail stands where it is clicked.
            let brick = composer_brick(world)?;
            let popup = popup_of(&brick, world, picker)?;
            world.wait_for("the model picker to finish opening", |w| {
                brick.flag(w, popup, "opened")
            })?;
            let claude = part(world, "modelPickerProvider:claudeAgent")?;
            click(world, claude)?;
            world.wait_for("Claude's models", |w| {
                composer_part_now(w, "modelPickerMultiple:claudeAgent:claude-opus").is_some()
            })?;
            let opus = part(world, "modelPickerMultiple:claudeAgent:claude-opus")?;
            click(world, opus)?;
            world.wait_for_with(
                |w| {
                    w.state("modelPicker")["multiple"]
                        .as_array()
                        .is_some_and(|m| m.len() == 2)
                },
                |w| {
                    format!(
                        "two models; the picker has {}",
                        show(&w.state("modelPicker")["multiple"])
                    )
                },
            )?;
            let brick = composer_brick(world)?;
            let title = part(world, "modelPickerTitle")?;
            expect!(
                brick.text_of(world, title, "text") == "2 models",
                "the picker does not say two models"
            );
            press_in_composer(world, "Escape")?;
            confirm_branch(world, "main")?;
            let item = composer_item(world)?;
            world
                .engine()
                .invoke_by_name(item, "focusInput", &[])
                .map_err(|e| Failure(format!("focusInput: {e:?}")))?;
            type_in_composer(world, &c[0])?;
            press_in_composer(world, "Enter")?;
            Ok(())
        },
    );
    steps.step(
        &format!("one thread per model starts with {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| launch_calls_len(w) == 2,
                |w| {
                    format!(
                        "two launches; the MC got {} and the toasts are {}",
                        launch_calls_len(w),
                        show(&Value::Array(toasts(w)))
                    )
                },
            )?;
            let mut models = Vec::new();
            for call in launch_calls(world) {
                expect!(
                    call["initialMessage"]["text"] == json!(c[0]),
                    "the launch is {}",
                    show(&call)
                );
                models.push(text(&call["modelSelection"]["model"]));
            }
            models.sort();
            expect!(
                models == ["claude-opus", "gpt-5"],
                "the threads run on {}",
                models.join(", ")
            );
            world.sync()?;
            expect!(
                toasts(world)
                    .iter()
                    .any(|toast| text(&toast["title"]).starts_with("Started 2 thread")),
                "the toasts are {}",
                show(&Value::Array(toasts(world)))
            );
            Ok(())
        },
    );
    steps.step("each thread works in its own worktree", |world, _, _| {
        let calls = launch_calls(world);
        for call in &calls {
            let strategy = &call["workspaceStrategy"];
            expect!(
                strategy["type"] == json!("worktree") && strategy["baseRef"] == json!("main"),
                "the launch works in {}",
                show(strategy)
            );
        }
        expect!(
            calls.len() == 2 && calls[0]["threadId"] != calls[1]["threadId"],
            "both launches name one thread"
        );
        Ok(())
    });

    // The machine.
    steps.step(
        "the user starts a new thread on the second environment",
        |world, _, _| {
            new_thread(world)?;
            let listed = environments(world);
            let second = listed
                .iter()
                .position(|e| e["environmentId"] == json!(PEER_ENVIRONMENT));
            expect!(
                second.is_some(),
                "the composer offers {}",
                show(&Value::Array(listed.clone()))
            );
            pick(world, "hostPicker", second.unwrap_or(0) as i64)?;
            world.wait_for_with(
                |w| workspace_state(w)["activeEnvironmentId"] == json!(PEER_ENVIRONMENT),
                |w| {
                    format!(
                        "the draft on the second environment; the header shows {}",
                        show(&workspace_state(w))
                    )
                },
            )?;
            send_first_message(world)
        },
    );
    steps.step(
        "the thread is created in the second environment",
        |world, _, _| {
            let call = launch(world)?;
            expect!(
                call["projectId"] == json!("shop-copy")
                    && call["initialMessage"]["text"] == json!(PROMPT),
                "the launch is {}",
                show(&call)
            );
            // The fake MC lists every launched thread as its own, so the project says where it went.
            let ending = format!(":{}", text(&call["threadId"]));
            world.wait_for_with(
                |w| {
                    w.with::<Navigation, _>(|n, _| n.thread_key().ends_with(&ending))
                        .unwrap_or(false)
                },
                |w| {
                    format!(
                        "the thread {}; the route is {}",
                        text(&call["threadId"]),
                        show(&w.state("route"))
                    )
                },
            )
        },
    );

    steps.step(
        &format!("{Q} has the project {Q} and the connected machine {Q} has only {Q}"),
        |world, c, _| {
            expect!(c[1] == PROJECT, "the open thread's project is {PROJECT}");
            world.mc.label = c[0].clone();
            // The second machine joins the cluster under its own name.
            world.mc.peers.insert(PEER_ENVIRONMENT.into(), PEER.into());
            let shell = world.mc.subscribers("shell").first().copied().unwrap_or(0);
            let capabilities = world.mc.capabilities.clone();
            world
                .mc
                .send(&json!({"t": "shell.environment", "id": shell, "mc": PEER,
                "environment": {"environmentId": PEER_ENVIRONMENT, "label": c[2],
                                "capabilities": capabilities}}));
            world
                .mc
                .send(&json!({"t": "shell.mc", "id": shell, "mc": PEER, "online": true}));
            world.mc.send_rows(
                PEER,
                vec![json!([c[3], "project", {
                    "id": c[3], "title": c[3],
                    "workspaceRoot": format!("/srv/{}", c[3]), "scripts": []}])],
            );
            world.sync()
        },
    );
    steps.step(
        &format!("the user has typed a prompt for a new thread in {Q}"),
        |world, c, _| {
            expect!(c[0] == PROJECT, "the open thread's project is {PROJECT}");
            new_thread(world)?;
            type_in_composer(world, PROMPT)?;
            settle_composer(world)
        },
    );
    steps.step(
        &format!("the user chooses {Q} as the machine the thread runs on"),
        |world, c, _| {
            let listed = environments(world);
            let choice = listed.iter().position(|e| e["label"] == json!(c[0]));
            expect!(
                choice.is_some(),
                "the composer offers {}",
                show(&Value::Array(listed.clone()))
            );
            pick(world, "hostPicker", choice.unwrap_or(0) as i64)
        },
    );
    steps.step(
        &format!("the new thread is in {Q} on {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    let state = workspace_state(w);
                    state["activeEnvironmentId"] == json!(PEER_ENVIRONMENT)
                        && state["projectTitle"] == json!(c[0])
                },
                |w| {
                    format!(
                        "the draft in {} on {}; the header shows {}",
                        c[0],
                        c[1],
                        show(&workspace_state(w))
                    )
                },
            )?;
            let draft = world.draft_id.clone();
            let where_ = workspace::launch(world.engine(), &draft);
            // The draft is the machine's own now: the picker names the machine, the header the project.
            let shown = picker_text(world, "hostPicker")?;
            expect!(
                where_.environment_id == PEER_ENVIRONMENT
                    && where_.project_id == c[0]
                    && shown == c[1],
                "the thread would start in {} on {}; the picker reads \"{shown}\"",
                where_.project_id,
                where_.environment_id
            );
            Ok(())
        },
    );
    steps.step("the prompt is still there", |world, _, _| {
        settle_composer(world)?;
        let (brick, input) = editor(world)?;
        let reads = brick.text_of(world, input, "text");
        expect!(
            reads == PROMPT && world.state("composer")["target"] == json!(world.draft_id),
            "the composer reads \"{reads}\""
        );
        Ok(())
    });

    // The checkout.
    steps.step("the project is a Git repository", |world, _, _| {
        fake_git_repo(world, ROOT, &["main", "feature/tax"], "feature/tax", "main");
        world.sync()
    });
    steps.step(
        &format!("the user chooses to work in a new worktree from branch {Q}"),
        |world, c, _| {
            new_thread(world)?;
            pick(world, "envModePicker", 1)?;
            world.wait_for_with(
                |w| workspace_state(w)["envMode"] == json!("worktree"),
                |w| {
                    format!(
                        "New worktree; the header shows {}",
                        show(&workspace_state(w))
                    )
                },
            )?;
            confirm_branch(world, &c[0])
        },
    );
    steps.step(
        &format!("the first turn works in a new worktree based on {Q}"),
        |world, c, _| {
            send_first_message(world)?;
            let strategy = launch(world)?["workspaceStrategy"].clone();
            expect!(
                strategy["type"] == json!("worktree") && strategy["baseRef"] == json!(c[0]),
                "the launch works in {}",
                show(&strategy)
            );
            Ok(())
        },
    );
    steps.step("the user chose to work in a new worktree", |world, _, _| {
        // A checkout on no branch (a detached head) offers no base to start from.
        fake_git_repo(world, ROOT, &["main"], "", "main");
        world.sync()?;
        new_thread(world)?;
        pick(world, "envModePicker", 1)?;
        world.wait_for_with(
            |w| workspace_state(w)["envMode"] == json!("worktree"),
            |w| {
                format!(
                    "New worktree; the header shows {}",
                    show(&workspace_state(w))
                )
            },
        )
    });
    steps.step("no base branch is chosen", |world, _, _| {
        expect!(
            workspace_state(world)["branch"].is_null(),
            "the header shows {}",
            show(&workspace_state(world))
        );
        Ok(())
    });
    steps.step("the user tries to send the first message", |world, _, _| {
        send_first_message(world)
    });
    steps.step(
        "the user is asked to select a base branch",
        |world, _, _| {
            let shown = toasts(world);
            expect!(
                shown.iter().any(|toast| toast["description"]
                    == json!("Select a base branch before sending in New worktree mode.")),
                "the toasts are {}",
                show(&Value::Array(shown.clone()))
            );
            world.sync()?;
            let (brick, input) = editor(world)?;
            expect!(
                launch_calls(world).is_empty() && brick.text_of(world, input, "text") == PROMPT,
                "the MC launched a thread, or the draft was lost"
            );
            Ok(())
        },
    );

    // The branch.
    steps.step(&format!("the project has no branch {Q}"), |world, c, _| {
        // A started thread keeps the composer's branch control only with Composer context on.
        let engine = world.engine().clone();
        Settings::of(&engine).set(&engine, "persistComposerContextStrip", json!(true));
        fake_git_repo(world, ROOT, &["main"], "main", "main");
        world.wait_for_with(
            |w| workspace_state(w)["branch"] == json!("main"),
            |w| {
                format!(
                    "the thread on main; the header shows {}",
                    show(&workspace_state(w))
                )
            },
        )?;
        expect!(c[0] != "main", "main exists");
        Ok(())
    });
    steps.step(
        &format!("the user searches for {Q} and confirms it"),
        |world, c, _| {
            composer_brick(world)?;
            confirm_branch(world, &c[0])
        },
    );
    steps.step(
        &format!("the thread works on a new branch {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    workspace_state(w)["branch"] == json!(c[0])
                        && w.mc
                            .threads
                            .get(THREAD)
                            .is_some_and(|t| t["branch"] == json!(c[0]))
                },
                |w| {
                    format!(
                        "the thread on {}; the header shows {}",
                        c[0],
                        show(&workspace_state(w))
                    )
                },
            )
        },
    );
}

fn launch_calls_len(world: &World) -> usize {
    world.mc.peek::<FakeLaunches>().map_or(0, |l| l.calls.len())
}

/// The composer's scenarios give the open thread's project a checkout on a
/// second machine of the same repository. False when no thread of
/// stream.rs's is open.
pub fn connect_second_composer_environment(world: &mut World) -> Outcome<bool> {
    if world.mc.part::<FakeStreams>().thread.is_empty() {
        return Ok(false);
    }
    // The second has a checkout of the same repository.
    let identity = json!({"canonicalKey": "github.com/acme/shop"});
    let mut row = world.mc.projects.get(PROJECT).cloned().unwrap_or(json!({}));
    row["repositoryIdentity"] = identity.clone();
    world.mc.projects.insert(PROJECT.into(), row.clone());
    let name = world.mc.name.clone();
    world
        .mc
        .send_rows(&name, vec![json!([PROJECT, "project", row])]);
    world.mc.join(PEER, PEER_ENVIRONMENT);
    world.mc.send_rows(
        PEER,
        vec![json!(["shop-copy", "project", {
            "id": "shop-copy", "title": PROJECT, "workspaceRoot": "/srv/shop",
            "scripts": [], "repositoryIdentity": identity}])],
    );
    world.sync()?;
    Ok(true)
}
