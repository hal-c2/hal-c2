//! Starting threads (threads/creating.feature): the model a new thread
//! starts with, background starts that leave the draft ready for the next
//! one, one prompt sent to several models, and a draft moved to another
//! project: desktop-qt's ThreadCreateSteps.cpp.

use std::collections::BTreeSet;
use std::rc::Rc;

use hal_c2_shell::controllers::drafts;
use hal_c2_shell::controllers::workspace::{self, Checkout};
use serde_json::{Value, json};

use super::launch::{FakeLaunches, launch_calls};
use super::settings::publish_providers;
use super::thread_menu::update_row;
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

fn selection_of(model: &str) -> Value {
    json!({"instanceId": "claudeAgent", "model": format!("claude-{}", model.to_lowercase())})
}

/// The draft's thread id when the scenario's first prompt was written.
#[derive(Default)]
struct Creating {
    first_thread_id: String,
}

fn route_kind(world: &World) -> String {
    text(&world.state("route")["kind"])
}

fn start_draft(world: &mut World, payload: Value) -> Outcome {
    world.start_new_thread(payload)?;
    world.wait_for_with(
        |w| route_kind(w) == "draft",
        |w| format!("a draft; the route is {}", show(&w.state("route"))),
    )?;
    world.draft_id = text(&world.state("route")["draftId"]);
    world.wait_for("the header to show the draft", |w| {
        w.state("workspace")["isDraft"].as_bool().unwrap_or(false)
    })
}

/// A new worktree off "main", as the header's checkout picker sets it.
fn use_new_worktree(world: &mut World) {
    let checkout = Checkout {
        env_mode: "worktree".into(),
        branch: Some("main".into()),
        ..Checkout::default()
    };
    workspace::set_checkout(world.engine(), &world.draft_id.clone(), checkout);
}

fn type_(world: &mut World, text: &str) -> Outcome {
    let target = world.draft_id.clone();
    world.dispatch(
        "composer.text.set",
        json!({"target": target, "text": text, "cursor": text.chars().count()}),
    )
}

fn send_in_background(world: &mut World) -> Outcome {
    world.dispatch("composer.submit", json!({"intent": "background"}))?;
    world.sync()
}

/// The project's folder is a Git checkout on "main": its status reaches
/// whoever follows it.
fn make_git_project(world: &mut World, project: &str) -> Outcome {
    let cwd = format!("/work/{project}");
    let local = json!({"isRepo": true, "isDefaultRef": true, "hasWorkingTreeChanges": false,
                       "hasPrimaryRemote": true, "refName": "main", "workingTree": {"files": []}});
    let answer = local.clone();
    world.mc.checkouts.insert(
        cwd.clone(),
        Rc::new(move |_: &mut FakeMc| json!({"local": answer, "remote": {}})),
    );
    for id in world.mc.subscribers("vcs") {
        if text(&world.mc.shape_of(id)["cwd"]) != cwd {
            continue;
        }
        world.mc.send(&json!({"t": "vcs", "id": id, "event": {
            "_tag": "localUpdated", "local": local}}));
    }
    world.sync()
}

const MODELS: [(&str, &str, &str); 3] = [
    ("Opus", "claudeAgent", "claude-opus"),
    ("GPT-5", "codex", "gpt-5"),
    ("Gemini", "gemini", "gemini-2.5-pro"),
];

fn model_named(name: &str) -> Outcome<Value> {
    match MODELS.iter().find(|(label, ..)| *label == name) {
        Some((_, instance, model)) => Ok(json!({"instanceId": instance, "model": model})),
        None => fail!("no model \"{name}\""),
    }
}

/// The three agents, each with its model, ready to run.
fn offer_models(world: &mut World) -> Outcome {
    let providers = MODELS
        .iter()
        .map(|(label, instance, model)| {
            json!({"instanceId": instance, "driver": instance, "displayName": label,
                   "enabled": true, "installed": true, "status": "ready",
                   "models": [{"slug": model, "name": label,
                               "capabilities": {"optionDescriptors": []}}]})
        })
        .collect();
    publish_providers(&mut world.mc, providers);
    world.sync()?;
    world.wait_for_with(
        |w| w.state("modelPicker")["instances"].as_array().map(Vec::len) == Some(3),
        |w| format!("the models; the picker is {}", show(&w.state("modelPicker"))),
    )
}

fn choose(world: &mut World, action: &str, name: &str) -> Outcome {
    let model = model_named(name)?;
    world.dispatch(action, model)
}

fn several_models(world: &World) -> Vec<Value> {
    world.state("modelPicker")["multiple"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn first_project(world: &World) -> String {
    world.mc.projects.keys().next().cloned().unwrap_or_default()
}

fn draft_of(world: &World, id: &str) -> Option<drafts::Draft> {
    drafts::draft(world.engine(), id)
}

pub fn register(steps: &mut Steps) {
    // Background starts.
    steps.step(
        "the user has written a first message in a draft",
        |world, _, _| {
            let project = first_project(world);
            make_git_project(world, &project)?;
            start_draft(world, json!({}))?;
            use_new_worktree(world);
            type_(world, "Set up the linter")?;
            let first = draft_of(world, &world.draft_id).map(|d| d.thread_id);
            world.mc.part::<Creating>().first_thread_id = first.unwrap_or_default();
            Ok(())
        },
    );
    steps.step(
        "the user starts the thread in the background",
        |world, _, _| send_in_background(world),
    );
    steps.step(
        "the thread starts working without being opened",
        |world, _, _| {
            world.wait_for("the launch", |w| launch_calls_len(w) == 1)?;
            let launch = launch_calls(world).remove(0);
            let first = world.mc.part::<Creating>().first_thread_id.clone();
            expect!(
                launch["threadId"] == json!(first)
                    && launch["initialMessage"]["text"] == json!("Set up the linter"),
                "the launch is {}",
                show(&launch)
            );
            let route = world.state("route");
            expect!(
                route["kind"] == json!("draft") && text(&route["draftId"]) == world.draft_id,
                "the route is {}",
                show(&route)
            );
            Ok(())
        },
    );
    steps.step(
        "a new draft opens with the same workspace mode and base branch",
        |world, _, _| {
            let draft = draft_of(world, &world.draft_id);
            let checkout = workspace::checkout(world.engine(), &world.draft_id);
            let composer = world.state("composer");
            let first = world.mc.part::<Creating>().first_thread_id.clone();
            // The same draft, for a thread of its own, with nothing written yet.
            expect!(
                draft.is_some_and(|d| d.thread_id != first)
                    && text(&composer["target"]) == world.draft_id
                    && text(&composer["text"]).is_empty(),
                "the composer shows {}",
                show(&composer)
            );
            expect!(
                checkout.env_mode == "worktree" && checkout.branch.as_deref() == Some("main"),
                "the draft is in {} on {}",
                checkout.env_mode,
                checkout.branch.unwrap_or_default()
            );
            Ok(())
        },
    );
    steps.step(
        "the draft is set to use a new worktree",
        |world, _, _| {
            let project = first_project(world);
            make_git_project(world, &project)?;
            start_draft(world, json!({}))?;
            use_new_worktree(world);
            Ok(())
        },
    );
    steps.step(
        "the user starts two threads in the background",
        |world, _, _| {
            for prompt in ["Add caching", "Add retries"] {
                type_(world, prompt)?;
                send_in_background(world)?;
            }
            Ok(())
        },
    );
    steps.step(
        "each thread works in its own new worktree",
        |world, _, _| {
            world.sync()?;
            let launches = launch_calls(world);
            expect!(
                launches.len() >= 2,
                "the MC launched {} threads",
                launches.len()
            );
            let mut threads = BTreeSet::new();
            for launch in &launches {
                let strategy = &launch["workspaceStrategy"];
                // A worktree the MC makes for this thread alone, off the base branch.
                expect!(
                    strategy["type"] == json!("worktree")
                        && strategy["baseRef"] == json!("main")
                        && strategy.get("worktreePath").is_none(),
                    "the launch is {}",
                    show(launch)
                );
                threads.insert(text(&launch["threadId"]));
            }
            expect!(threads.len() == launches.len(), "two launches share a thread");
            Ok(())
        },
    );

    // Several models.
    steps.step(&format!("{Q} is a Git project"), |world, c, _| {
        make_git_project(world, &c[0])
    });
    steps.step(
        &format!("the user sends the first message to the models {Q}, {Q} and {Q}"),
        |world, c, _| {
            start_draft(world, json!({}))?;
            world.wait_for("the draft's checkout to be known", |w| {
                workspace::git(w.engine())
                    .is_some_and(|git| git.local.get("isRepo").and_then(Value::as_bool) == Some(true))
            })?;
            offer_models(world)?;
            choose(world, "composer.model.select", &c[0])?;
            choose(world, "composer.model.multiple.toggle", &c[1])?;
            choose(world, "composer.model.multiple.toggle", &c[2])?;
            expect!(
                several_models(world).len() == 3,
                "the picker is {}",
                show(&world.state("modelPicker"))
            );
            type_(world, "Add caching")?;
            world.dispatch("composer.submit", json!({"intent": "foreground"}))?;
            world.sync()
        },
    );
    steps.step("three threads are created, one per model", |world, _, _| {
        world.wait_for_with(
            |w| launch_calls_len(w) == 3,
            |w| format!("three launches; the MC got {}", launch_calls_len(w)),
        )?;
        let mut started = Vec::new();
        for launch in launch_calls(world) {
            expect!(
                launch["initialMessage"]["text"] == json!("Add caching"),
                "the launch is {}",
                show(&launch)
            );
            started.push(text(&launch["modelSelection"]["model"]));
        }
        started.sort();
        expect!(
            started == ["claude-opus", "gemini-2.5-pro", "gpt-5"],
            "the models are {}",
            started.join(", ")
        );
        // The window stays on the draft, ready for another prompt.
        expect!(
            text(&world.state("route")["draftId"]) == world.draft_id
                && text(&world.state("composer")["text"]).is_empty(),
            "the route is {}",
            show(&world.state("route"))
        );
        Ok(())
    });
    steps.step(&format!("{Q} is not a Git project"), |world, c, _| {
        let row = json!({"id": c[0], "title": c[0], "workspaceRoot": format!("/work/{}", c[0]),
                         "scripts": []});
        world.mc.projects.insert(c[0].clone(), row.clone());
        world.mc.send_row_of(&c[0], &row, "project");
        world.sync()?;
        let key = world.project_key(&c[0]);
        start_draft(world, json!({"projectKey": key}))?;
        world.wait_for("the draft's folder to be read", |w| {
            workspace::git(w.engine()).is_some()
        })
    });
    steps.step(
        "the user tries to pick more than one model for the first message",
        |world, _, _| {
            offer_models(world)?;
            choose(world, "composer.model.select", "Opus")?;
            choose(world, "composer.model.multiple.toggle", "GPT-5")
        },
    );
    steps.step("only one model can be chosen", |world, _, _| {
        let composer = world.state("composer");
        expect!(
            several_models(world).is_empty() && composer["selectedModel"] == json!("gpt-5"),
            "the picker is {}, the composer {}",
            show(&Value::Array(several_models(world))),
            show(&composer)
        );
        let toasts = world.state("toasts");
        let told = toasts["items"].as_array().is_some_and(|items| {
            items
                .iter()
                .any(|item| item["title"] == json!("Only one model can be chosen"))
        });
        expect!(told, "the shell shows {}", show(&toasts));
        Ok(())
    });

    // A draft's project.
    steps.step(
        &format!("the project {Q} exists only on the environment {Q}"),
        |world, c, _| {
            let peer = format!("mc-{}", c[1]);
            world.mc.join(&peer, &c[1]);
            let shell = world.mc.subscribers("shell").first().copied().unwrap_or(0);
            world.mc.send(
                &json!({"t": "shell.mc", "id": shell, "mc": peer, "online": true}),
            );
            let row = json!({"id": c[0], "title": c[0], "workspaceRoot": format!("/srv/{}", c[0]),
                             "scripts": []});
            world.mc.send_rows(&peer, vec![json!([c[0], "project", row])]);
            world.sync()?;
            // The draft that is moved (DraftSteps' "the user moves the draft to"):
            // this machine's, with something written.
            start_draft(world, json!({}))?;
            type_(world, "Sketch the endpoint")?;
            let before = draft_of(world, &world.draft_id);
            expect!(
                before.is_some_and(|d| d.environment_id == world.mc.environment_id),
                "the draft is not this machine's"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the draft targets the environment {Q}"),
        |world, c, _| {
            // The draft the window shows after the move.
            let shown = text(&world.state("route")["draftId"]);
            let draft = draft_of(world, &shown);
            expect!(
                draft
                    .as_ref()
                    .is_some_and(|d| d.environment_id == c[0] && d.project_id == "api"),
                "the draft is on {} in {}",
                draft.as_ref().map_or("", |d| &d.environment_id),
                draft.as_ref().map_or("", |d| &d.project_id)
            );
            // What was written came along, and the header names the new project.
            world.wait_for_with(
                |w| w.state("workspace")["projectTitle"] == json!("api"),
                |w| format!("the header to name api; it shows {}", show(&w.state("workspace"))),
            )?;
            let composer = world.state("composer");
            expect!(
                composer["text"] == json!("Sketch the endpoint"),
                "the composer shows {}",
                show(&composer)
            );
            Ok(())
        },
    );

    steps.step(&format!("{Q} has the default model {Q}"), |world, c, _| {
        expect!(
            world.mc.projects.contains_key(&c[0]),
            "there is no project {}",
            c[0]
        );
        let mut row = world.mc.projects[&c[0]].clone();
        row["defaultModelSelection"] = selection_of(&c[1]);
        world.mc.projects.insert(c[0].clone(), row.clone());
        world.mc.send_row_of(&c[0], &row, "project");
        world.sync()
    });
    steps.step(&format!("the current thread uses the model {Q}"), |world, c, _| {
        let key = text(&world.state("route")["threadKey"]);
        expect!(!key.is_empty(), "no thread is open");
        let id = key.split_once(':').map_or(key.as_str(), |(_, id)| id).to_owned();
        let selection = selection_of(&c[0]);
        update_row(world, &id, |row| {
            row.insert("modelSelection".into(), selection.clone());
        })?;
        let model = text(&selection["model"]);
        world.wait_for_with(
            |w| text(&w.state("composer")["selectedModel"]) == model,
            |w| format!("the thread's model; the composer is {}", show(&w.state("composer"))),
        )
    });
    steps.step(&format!("the draft uses the model {Q}"), |world, c, _| {
        let model = text(&selection_of(&c[0])["model"]);
        world.wait_for_with(
            |w| {
                let composer = w.state("composer");
                route_kind(w) == "draft"
                    && text(&composer["target"]) == w.draft_id
                    && text(&composer["selectedModel"]) == model
            },
            |w| format!("the draft on {}; the composer is {}", c[0], show(&w.state("composer"))),
        )
    });
}

fn launch_calls_len(world: &World) -> usize {
    world
        .mc
        .peek::<FakeLaunches>()
        .map_or(0, |launches| launches.calls.len())
}
