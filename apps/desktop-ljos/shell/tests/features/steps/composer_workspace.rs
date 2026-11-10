//! Where a new thread runs, picked in the composer's context strip on screen
//! (desktop-qt's ComposerWorkspaceSteps.cpp): the machine, the checkout mode
//! and the branch (features/composer/model-and-mode.feature).

use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::workspace;
use hal_c2_shell::store;
use ljos::prelude::{ObjectId, Value as QmlValue};
use serde_json::{Value, json};

use crate::brick::Brick;
use crate::harness::{Failure, Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::{
    composer_brick, composer_item, composer_part, composer_part_now, editor, press_in_composer,
    settle_composer, type_in_composer,
};
use crate::steps::launch::{FakeLaunches, launch_calls};
use crate::steps::settings::{fake_config, publish_providers, save_elsewhere};
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
    workspace_choice(steps);
}

/// The worktree the scenario's new thread is to be in, when it is in one.
#[derive(Default)]
struct ChoiceDraft {
    worktree: String,
}

/// A thread of the project that worked in `worktree`, `hour` o'clock its
/// last use.
fn have_worktree_thread(
    world: &mut World,
    project: &str,
    id: &str,
    branch: &str,
    worktree: &str,
    hour: u32,
    archived_at: &str,
) -> Outcome {
    let mut row = json!({"id": id, "title": id, "projectId": project, "worktreePath": worktree,
        "createdAt": "2026-09-23T07:00:00Z", "updatedAt": format!("2026-09-23T{hour:02}:00:00Z")});
    if !branch.is_empty() {
        row["branch"] = json!(branch);
    }
    if !archived_at.is_empty() {
        row["archivedAt"] = json!(archived_at);
    }
    world.mc.threads.insert(id.to_owned(), row.clone());
    world.mc.send_row(id, &row);
    world.sync()
}

fn have_started_thread(world: &mut World, project: &str, worktree: &str) -> Outcome {
    let mut row = json!({"id": "t-started", "title": "Tax line", "projectId": project,
        "latestUserMessageAt": "2026-09-23T09:00:00Z",
        "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
    if !worktree.is_empty() {
        row["worktreePath"] = json!(worktree);
    }
    world.mc.threads.insert("t-started".into(), row.clone());
    world.mc.send_row("t-started", &row);
    world.sync()
}

/// A new thread's draft, in `worktree` when there is one.
fn open_choice_draft(world: &mut World, worktree: &str) -> Outcome {
    new_thread(world)?;
    if worktree.is_empty() {
        return Ok(());
    }
    let draft = world.with::<Navigation, _>(|n, _| match n.route() {
        hal_c2_shell::controllers::navigation::Route::Draft(id) => id.clone(),
        _ => String::new(),
    })?;
    let engine = world.engine().clone();
    let mut checkout = workspace::checkout(&engine, &draft);
    checkout.env_mode = "worktree".into();
    checkout.worktree_path = Some(worktree.to_owned());
    workspace::set_checkout(&engine, &draft, checkout);
    world.wait_for_with(
        |w| workspace_state(w)["worktreePath"] == json!(worktree),
        |w| {
            format!(
                "the draft in the worktree; the header shows {}",
                show(&workspace_state(w))
            )
        },
    )
}

fn open_choice(world: &mut World) -> Outcome {
    let brick = composer_brick(world)?;
    let picker = part(world, "envModePicker")?;
    click(world, picker)?;
    let popup = popup_of(&brick, world, picker)?;
    world.wait_for("the workspace choice to open", |w| {
        brick.flag(w, popup, "opened")
    })
}

/// What the workspace choice lists, as on screen.
fn choices(world: &mut World) -> Outcome<Vec<String>> {
    let brick = composer_brick(world)?;
    let picker = part(world, "envModePicker")?;
    let count = int(&brick, world, picker, "count");
    let mut labels = Vec::new();
    for index in 0..count {
        let label =
            match world
                .engine()
                .invoke_by_name(picker, "textAt", &[QmlValue::Int(index as i32)])
            {
                Ok(QmlValue::String(s)) => s.to_string(),
                Ok(other) => format!("{other:?}"),
                Err(e) => fail!("textAt: {e:?}"),
            };
        labels.push(label);
    }
    Ok(labels)
}

fn open_base_picker(world: &mut World) -> Outcome {
    let button = part(world, "branchButton")?;
    click(world, button)?;
    let brick = composer_brick(world)?;
    world.wait_for("the branch picker to open", |w| {
        brick
            .find(w, "branchPicker")
            .ok()
            .flatten()
            .is_some_and(|popup| brick.flag(w, popup, "opened"))
    })?;
    world.sync()
}

/// Codex and Claude ready to take a new thread's prompt.
fn offer_codex_and_claude(world: &mut World) -> Outcome {
    let listed = world.state("modelPicker")["instances"]
        .as_array()
        .is_some_and(|i| !i.is_empty());
    if listed {
        return Ok(());
    }
    publish_providers(
        &mut world.mc,
        vec![
            provider("codex", "Codex", &["gpt-5", "gpt-5-codex"]),
            provider("claudeAgent", "Claude", &["claude-opus", "claude-sonnet"]),
        ],
    );
    world.sync()
}

/// The draft's own model, and Claude's beside it.
fn choose_claude_too(world: &mut World) -> Outcome {
    let picker = part(world, "modelPicker")?;
    click(world, picker)?;
    world.wait_for("the model picker to open", |w| {
        composer_part_now(w, "modelPickerProvider:claudeAgent").is_some()
    })?;
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
    )
}

fn origin_setting(world: &World) -> bool {
    let engine = world.engine().clone();
    Settings::of(&engine).setting(&engine, "newWorktreesStartFromOrigin") == Some(json!(true))
}

/// Turns the base picker's start-from-origin switch to `on` in a new
/// thread's new worktree on main.
fn switch_origin(world: &mut World, on: bool) -> Outcome {
    new_thread(world)?;
    pick(world, "envModePicker", 1)?;
    open_base_picker(world)?;
    let brick = composer_brick(world)?;
    let toggle = part(world, "startFromOrigin")?;
    expect!(
        brick.flag(world, toggle, "checked") != on,
        "the switch already reads {}",
        if on { "on" } else { "off" }
    );
    click(world, toggle)?;
    world.wait_for_with(
        |w| workspace_state(w)["startFromOrigin"] == json!(on),
        |w| {
            format!(
                "the switch to take; the header shows {}",
                show(&workspace_state(w))
            )
        },
    )?;
    press_in_composer(world, "Escape")?;
    world.wait_for("the branch picker to close", |w| {
        brick
            .find(w, "branchPicker")
            .ok()
            .flatten()
            .is_none_or(|popup| !brick.flag(w, popup, "visible"))
    })
}

fn launched_from_origin(world: &mut World, origin: bool) -> Outcome {
    if launch_calls_len(world) == 0 {
        confirm_branch(world, "main")?;
        send_first_message(world)?;
    }
    let call = launch(world)?;
    let strategy = &call["workspaceStrategy"];
    expect!(
        strategy["type"] == json!("worktree")
            && (strategy["startFromOrigin"] == json!(true)) == origin,
        "the launch works in {}",
        show(strategy)
    );
    Ok(())
}

/// The workspace choice (source-control/worktrees-and-setup-scripts.feature).
fn workspace_choice(steps: &mut Steps) {
    steps.step(
        &format!(
            "the user is writing the first message of a new thread in {Q} in the project folder"
        ),
        |world, _, _| new_thread(world),
    );
    steps.step(
        &format!(
            "the user is writing the first message of a new thread in {Q} in an existing worktree"
        ),
        |world, c, _| {
            let tax = "/work/shop-worktrees/tax";
            have_worktree_thread(world, &c[0], "t-before", "feature/tax", tax, 10, "")?;
            open_choice_draft(world, tax)
        },
    );
    steps.step("the user opens the workspace choice", |world, _, _| {
        open_choice(world)
    });
    steps.step(&format!("the choices are {Q} and {Q}"), |world, c, _| {
        let shown = choices(world)?;
        expect!(
            shown == [c[0].clone(), c[1].clone()],
            "the choices are {}",
            shown.join(", ")
        );
        Ok(())
    });
    steps.step(
        &format!("a thread in {Q} has started in the project folder"),
        |world, c, _| have_started_thread(world, &c[0], ""),
    );
    steps.step(
        &format!("a thread in {Q} has started in a worktree"),
        |world, c, _| have_started_thread(world, &c[0], "/work/shop-worktrees/tax"),
    );
    steps.step("the user looks at the thread's workspace", |world, _, _| {
        // A started thread's strip stays only with the setting that keeps it.
        let engine = world.engine().clone();
        Settings::of(&engine).set(&engine, "persistComposerContextStrip", json!(true));
        let key = format!("{}:t-started", world.mc.environment_id);
        let route = key.clone();
        world.with::<Navigation, _>(|navigation, engine| {
            navigation.open(
                engine,
                hal_c2_shell::controllers::navigation::Route::Thread(route),
            )
        })?;
        world.wait_for_with(
            |w| workspace_state(w)["threadKey"] == json!(key),
            |w| format!("the thread; the header shows {}", show(&workspace_state(w))),
        )?;
        composer_brick(world)?;
        Ok(())
    });
    steps.step(
        &format!("it reads {Q} and cannot be changed"),
        |world, c, _| {
            world.sync()?;
            let brick = composer_brick(world)?;
            let locked = part(world, "envModeLocked")?;
            let label = part(world, "envModeLockedLabel")?;
            let picker = part(world, "envModePicker")?;
            world.wait_for_with(
                |w| {
                    brick.flag(w, locked, "visible")
                        && brick.text_of(w, label, "text") == c[0]
                        && !brick.flag(w, picker, "visible")
                        && workspace_state(w)["envModeChangeable"] != json!(true)
                },
                |w| {
                    format!(
                        "the lock; shown {}, label \"{}\", composer {}",
                        brick.flag(w, locked, "visible"),
                        brick.text_of(w, label, "text"),
                        show(&w.state("composer")["showContextStrip"])
                    )
                },
            )?;
            // Asking anyway changes nothing.
            let mode = text(&workspace_state(world)["envMode"]);
            let other = if mode == "worktree" {
                "local"
            } else {
                "worktree"
            };
            world.dispatch("workspace.envMode.set", json!({"mode": other}))?;
            world.sync()?;
            let state = workspace_state(world);
            expect!(
                state["envMode"] == json!(mode) && state["envModeLabel"] == json!(c[0]),
                "the header shows {}",
                show(&state)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user chose two models for a new thread in {Q}"),
        |world, _, _| {
            offer_codex_and_claude(world)?;
            new_thread(world)?;
            choose_claude_too(world)?;
            press_in_composer(world, "Escape")?;
            Ok(())
        },
    );
    steps.step("the user looks at the workspace choice", |world, _, _| {
        world.sync()
    });
    steps.step(
        "it says each model starts in its own worktree",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let locked = part(world, "envModeLocked")?;
            let hint = brick.text_of(world, locked, "hint");
            expect!(
                hint == "Each model starts in its own worktree.",
                "it says \"{hint}\""
            );
            expect!(
                workspace_state(world)["envMode"] == json!("worktree"),
                "the header shows {}",
                show(&workspace_state(world))
            );
            Ok(())
        },
    );
    let latest = "/work/shop-worktrees/latest";
    steps.step(
        &format!("the most recently used worktree of {Q} is on no branch"),
        move |world, c, _| have_worktree_thread(world, &c[0], "t-latest", "", latest, 10, ""),
    );
    steps.step(
        &format!(
            "the most recently used worktree of {Q} is the worktree the new thread is already in"
        ),
        move |world, c, _| {
            have_worktree_thread(world, &c[0], "t-latest", "feature/here", latest, 10, "")?;
            world.mc.part::<ChoiceDraft>().worktree = latest.to_owned();
            Ok(())
        },
    );
    steps.step(
        &format!("the most recently used worktree of {Q} belongs only to an archived thread"),
        move |world, c, _| {
            have_worktree_thread(
                world,
                &c[0],
                "t-latest",
                "feature/gone",
                latest,
                10,
                "2026-09-23T10:30:00Z",
            )
        },
    );
    steps.step(
        &format!("the most recently used worktree of {Q} is on {Q}"),
        move |world, c, _| have_worktree_thread(world, &c[0], "t-latest", &c[1], latest, 10, ""),
    );
    steps.step(
        &format!("an older thread in {Q} used another worktree"),
        |world, c, _| {
            have_worktree_thread(
                world,
                &c[0],
                "t-older",
                "feature/older",
                "/work/shop-worktrees/older",
                8,
                "",
            )
        },
    );
    steps.step(
        &format!("no thread in {Q} has used a worktree"),
        |world, _, _| world.sync(),
    );
    steps.step(
        "the user opens the workspace choice of a new thread",
        |world, _, _| {
            let worktree = world.mc.part::<ChoiceDraft>().worktree.clone();
            open_choice_draft(world, &worktree)?;
            open_choice(world)
        },
    );
    steps.step(&format!("it offers {Q}"), |world, c, _| {
        let shown = choices(world)?;
        expect!(
            shown.len() == 3 && shown[2] == c[0],
            "the choices are {}",
            shown.join(", ")
        );
        Ok(())
    });
    steps.step(
        "the other worktree is offered as the previous worktree",
        |world, _, _| {
            let shown = choices(world)?;
            expect!(
                shown.len() == 3 && shown[2] == "Previous worktree (feature/older)",
                "the choices are {}",
                shown.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        "the choices are the current checkout and a new worktree only",
        |world, _, _| {
            let shown = choices(world)?;
            expect!(
                shown == ["Current checkout", "New worktree"],
                "the choices are {}",
                shown.join(", ")
            );
            Ok(())
        },
    );

    // The base picker's start from origin.
    steps.step(
        &format!("the user chose a new worktree for a new thread in {Q}"),
        |world, _, _| {
            new_thread(world)?;
            pick(world, "envModePicker", 1)
        },
    );
    steps.step("the user opens the base picker", |world, _, _| {
        open_base_picker(world)
    });
    steps.step(
        &format!("it offers {Q} with a switch for starting the worktree from origin"),
        |world, c, _| {
            let brick = composer_brick(world)?;
            let row = part(world, "startFromOriginRow")?;
            let toggle = part(world, "startFromOrigin")?;
            expect!(
                brick.flag(world, row, "visible") && brick.flag(world, toggle, "visible"),
                "the switch is not offered"
            );
            expect!(
                brick.shows(world, &c[0])?,
                "the picker does not say \"{}\"",
                c[0]
            );
            Ok(())
        },
    );
    steps.step(
        "it explains this creates the worktree from the latest matching branch on origin instead of the local branch",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let help = part(world, "startFromOriginHelp")?;
            let said = brick.text_of(world, help, "text");
            expect!(
                said.contains("latest matching branch on origin")
                    && said.contains("instead of your local branch"),
                "it says \"{said}\""
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is (off|on) in the settings"),
        |world, c, _| {
            expect!(
                c[0] == "Start new worktrees from origin",
                "no such setting: {}",
                c[0]
            );
            let on = c[1] == "on";
            save_elsewhere(
                &mut world.mc,
                "newWorktreesStartFromOrigin",
                json!(on),
                false,
            );
            world.wait_for("the shell to take the setting", |w| origin_setting(w) == on)
        },
    );
    steps.step(
        &format!("the user turns on {Q} in a new thread's base picker"),
        |world, _, _| switch_origin(world, true),
    );
    steps.step(
        &format!("the user turns off {Q} in a new thread's base picker"),
        |world, _, _| switch_origin(world, false),
    );
    steps.step(
        "that thread's worktree starts from origin",
        |world, _, _| launched_from_origin(world, true),
    );
    steps.step(
        "that thread's worktree starts from the local branch",
        |world, _, _| launched_from_origin(world, false),
    );
    steps.step(
        "the project's default workspace is a new worktree",
        |world, _, _| {
            save_elsewhere(
                &mut world.mc,
                "defaultThreadEnvMode",
                json!("worktree"),
                false,
            );
            world.sync()
        },
    );
    steps.step(
        &format!("the user opens a new thread in {Q}"),
        |world, c, _| {
            let key = world.project_key(&c[0]);
            world.start_new_thread(json!({"projectKey": key}))?;
            world.wait_for_with(
                |w| workspace_state(w)["envMode"] == json!("worktree"),
                |w| {
                    format!(
                        "the draft in a new worktree; the header shows {}",
                        show(&workspace_state(w))
                    )
                },
            )
        },
    );
    steps.step("the setting stays (off|on)", |world, c, _| {
        world.sync()?;
        let on = c[0] == "on";
        let saved = fake_config(&mut world.mc)
            .settings
            .get("newWorktreesStartFromOrigin")
            == Some(&json!(true));
        expect!(
            origin_setting(world) == on && saved == on,
            "the setting changed"
        );
        Ok(())
    });
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
    world.wait_for_with(
        |w| store::with(w.engine(), |s| !s.project_rows(PEER_ENVIRONMENT).is_empty()),
        |w| {
            format!(
                "the second machine's project; the header shows {}",
                show(&workspace_state(w))
            )
        },
    )?;
    Ok(true)
}
