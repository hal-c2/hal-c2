//! Starting threads (threads/creating.feature): the model a new thread
//! starts with, background starts that leave the draft ready for the next
//! one, one prompt sent to several models, and a draft moved to another
//! project, the thread list's button, and starts that fail or cannot be
//! made: desktop-qt's ThreadCreateSteps.cpp.

use std::collections::BTreeSet;
use std::rc::Rc;

use hal_c2_shell::controllers::composer::Composer;
use hal_c2_shell::controllers::drafts;
use hal_c2_shell::controllers::palette::Palette;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::sidebar as sidebar_ctl;
use hal_c2_shell::controllers::workspace::{self, Checkout};
use ljos::item::{Modifiers, MouseButtons};
use serde_json::{Value, json};

use super::add_project::{is_open as palette_open, prop as palette_prop};
use super::launch::{FakeLaunches, launch_calls};
use super::settings::publish_providers;
use super::thread_menu::update_row;
use crate::brick::{Brick, Shown};
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
    /// The draft sent while its thread is still being made, and its thread.
    sent_draft_id: String,
    sent_thread_key: String,
}

fn composer_shown(world: &World) -> Value {
    world.state("composer")
}

/// The thread list as the window draws it (Sidebar.qml).
fn thread_list(world: &mut World) -> Outcome<Brick> {
    if let Some(brick) = world.part::<Shown>().0 {
        return Ok(brick);
    }
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nSidebar { height: 600 }\n",
        256.0,
        600.0,
    )?;
    world.part::<Shown>().0 = Some(brick);
    Ok(brick)
}

fn add_project_row(world: &mut World, name: &str) -> Outcome {
    let row = json!({
        "id": name, "title": name, "workspaceRoot": format!("/work/{name}"),
        "createdAt": "2026-09-01T09:00:00Z", "updatedAt": "2026-09-01T09:00:00Z",
        "scripts": [],
    });
    world.mc.projects.insert(name.to_owned(), row.clone());
    world.mc.send_row_of(name, &row, "project");
    world.sync()
}

fn submit(world: &mut World) -> Outcome {
    world.dispatch("composer.submit", json!({"intent": "foreground"}))?;
    world.sync()
}

/// A draft in a new worktree, sent, whose launch the MC holds: its thread
/// is still being made.
fn send_held(world: &mut World) -> Outcome {
    let project = first_project(world);
    make_git_project(world, &project)?;
    start_draft(world, json!({}))?;
    use_new_worktree(world);
    type_(world, "Set up the linter")?;
    let sent_draft_id = world.draft_id.clone();
    let sent_thread_key = format!(
        "{}:{}",
        world.mc.environment_id,
        draft_of(world, &sent_draft_id)
            .map(|d| d.thread_id)
            .unwrap_or_default()
    );
    {
        let creating = world.mc.part::<Creating>();
        creating.sent_draft_id = sent_draft_id;
        creating.sent_thread_key = sent_thread_key;
    }
    world.mc.hold("answers");
    submit(world)?;
    world.wait_for_with(
        |w| launch_calls_len(w) == 1,
        |w| format!("the launch; the toasts are {}", show(&w.state("toasts"))),
    )
}

fn told_titled(world: &World, title: &str) -> bool {
    world.state("toasts")["items"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|item| text(&item["title"]).starts_with(title))
}

fn launching(world: &World, draft_id: &str) -> bool {
    world
        .with::<Composer, _>(|c, _| c.launching(draft_id))
        .unwrap_or(false)
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
        |w| {
            format!(
                "the models; the picker is {}",
                show(&w.state("modelPicker"))
            )
        },
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
    steps.step("the draft is set to use a new worktree", |world, _, _| {
        let project = first_project(world);
        make_git_project(world, &project)?;
        start_draft(world, json!({}))?;
        use_new_worktree(world);
        Ok(())
    });
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
            expect!(
                threads.len() == launches.len(),
                "two launches share a thread"
            );
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
                workspace::git(w.engine()).is_some_and(|git| {
                    git.local.get("isRepo").and_then(Value::as_bool) == Some(true)
                })
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
            world
                .mc
                .send(&json!({"t": "shell.mc", "id": shell, "mc": peer, "online": true}));
            let row = json!({"id": c[0], "title": c[0], "workspaceRoot": format!("/srv/{}", c[0]),
                             "scripts": []});
            world
                .mc
                .send_rows(&peer, vec![json!([c[0], "project", row])]);
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
                |w| {
                    format!(
                        "the header to name api; it shows {}",
                        show(&w.state("workspace"))
                    )
                },
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
    steps.step(
        &format!("the current thread uses the model {Q}"),
        |world, c, _| {
            let key = text(&world.state("route")["threadKey"]);
            expect!(!key.is_empty(), "no thread is open");
            let id = key
                .split_once(':')
                .map_or(key.as_str(), |(_, id)| id)
                .to_owned();
            let selection = selection_of(&c[0]);
            update_row(world, &id, |row| {
                row.insert("modelSelection".into(), selection.clone());
            })?;
            let model = text(&selection["model"]);
            world.wait_for_with(
                |w| text(&w.state("composer")["selectedModel"]) == model,
                |w| {
                    format!(
                        "the thread's model; the composer is {}",
                        show(&w.state("composer"))
                    )
                },
            )
        },
    );
    // The thread list's new thread button.
    steps.step(
        &format!("the environment also has the project {Q}"),
        |world, c, _| {
            add_project_row(world, &c[0])?;
            world.wait_for("two projects in the sidebar", |w| {
                sidebar_ctl::groups(w.engine()).len() == 2
            })
        },
    );
    steps.step(&format!("{Q} is the only project"), |world, c, _| {
        world.sync()?;
        let groups = sidebar_ctl::groups(world.engine());
        expect!(
            groups.len() == 1
                && groups[0]
                    .summary
                    .get("displayName")
                    .is_some_and(|v| text(v) == c[0]),
            "the sidebar has {} projects",
            groups.len()
        );
        Ok(())
    });
    steps.step(
        "the user presses the new thread button in the thread list( with Shift held)?",
        |world, c, _| {
            let list = thread_list(world)?;
            world.sync()?;
            let button = list.item(world, "newThread")?;
            let (x, y) = list.at(world, button, 0.5, 0.5)?;
            if c[0].is_empty() {
                world.click_at_with(x, y, MouseButtons::LEFT, Modifiers::empty())?;
                return world.sync();
            }
            // Shift is read off the click itself, as Qt reads it.
            world.click_at_with(x, y, MouseButtons::LEFT, Modifiers::SHIFT)?;
            world.sync()
        },
    );
    steps.step(
        "the user is asked which project to start the thread in",
        |world, _, _| {
            let (open, count) = world
                .with::<Palette, _>(|p, _| (p.is_open(), p.count()))
                .unwrap_or((false, 0));
            let submenu = palette_prop(world, "submenu").unwrap_or_default();
            expect!(
                palette_open(world) && open && submenu == "New thread in..." && count == 2,
                "the palette is {} on \"{submenu}\" with {count} entries",
                if open { "open" } else { "closed" }
            );
            expect!(
                route_kind(world) == "thread",
                "a thread started without asking: {}",
                show(&world.state("route"))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("a draft thread opens in {Q} without asking"),
        |world, c, _| {
            world.wait_for_with(
                |w| route_kind(w) == "draft",
                |w| format!("a draft; the route is {}", show(&w.state("route"))),
            )?;
            world.draft_id = text(&world.state("route")["draftId"]);
            let draft = draft_of(world, &world.draft_id);
            expect!(
                draft.as_ref().is_some_and(|d| d.project_id == c[0]),
                "the draft is in {}",
                draft.as_ref().map_or("", |d| &d.project_id)
            );
            expect!(
                !world
                    .with::<Palette, _>(|p, _| p.is_open())
                    .unwrap_or(false),
                "the command palette asked"
            );
            Ok(())
        },
    );
    steps.step(
        "the button's hint says Shift starts the thread in the current project",
        |world, _, _| {
            let list = thread_list(world)?;
            let button = list.item(world, "newThread")?;
            let hint = list.text_of(world, button, "toolTip");
            expect!(
                hint.contains("New thread in current project: Shift+click"),
                "the hint is \"{hint}\""
            );
            Ok(())
        },
    );

    // The model and mode a new thread keeps.
    steps.step(
        &format!("the current thread uses the model {Q} in plan mode"),
        |world, c, _| {
            offer_models(world)?;
            let engine = world.engine().clone();
            expect!(
                Settings::of(&engine).write_device(&engine, "planModeEnabled", json!(true)),
                "plan mode could not be turned on"
            );
            let key = text(&world.state("route")["threadKey"]);
            expect!(!key.is_empty(), "no thread is open");
            let model = model_named(&c[0])?;
            let id = key
                .split_once(':')
                .map_or(key.as_str(), |(_, id)| id)
                .to_owned();
            update_row(world, &id, |row| {
                row.insert("modelSelection".into(), model.clone());
                row.insert("interactionMode".into(), json!("plan"));
            })?;
            let wanted = text(&model["model"]);
            world.wait_for_with(
                |w| {
                    let composer = composer_shown(w);
                    text(&composer["selectedModel"]) == wanted
                        && text(&composer["interactionMode"]) == "plan"
                },
                |w| {
                    format!(
                        "the thread's model and mode; the composer is {}",
                        show(&composer_shown(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the draft uses the model {Q} in (plan|default) mode"),
        |world, c, _| {
            let model = text(&model_named(&c[0])?["model"]);
            world.wait_for_with(
                |w| {
                    let composer = composer_shown(w);
                    route_kind(w) == "draft"
                        && text(&composer["target"]) == text(&w.state("route")["draftId"])
                        && text(&composer["selectedModel"]) == model
                        && text(&composer["interactionMode"]) == c[1]
                },
                |w| {
                    format!(
                        "the draft on {} in {} mode; the composer is {}",
                        c[0],
                        c[1],
                        show(&composer_shown(w))
                    )
                },
            )
        },
    );
    // Another thread of the project, in the default mode, opened from
    // the draft.
    steps.step(
        &format!("the user opens another thread of {Q} that uses the model {Q}"),
        |world, c, _| {
            let id = "thread-other";
            let model = model_named(&c[1])?;
            let row = json!({
                "id": id, "title": "Cart totals", "projectId": c[0],
                "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z",
                "modelSelection": model, "interactionMode": "default",
            });
            world.mc.threads.insert(id.to_owned(), row.clone());
            world.mc.send_row(id, &row);
            world.sync()?;
            let key = format!("{}:{id}", world.mc.environment_id);
            world.dispatch("thread.open", json!({"key": key}))?;
            let wanted = text(&model["model"]);
            let key2 = format!("{}:{id}", world.mc.environment_id);
            world.wait_for_with(
                |w| {
                    let composer = composer_shown(w);
                    text(&composer["target"]) == key2
                        && text(&composer["selectedModel"]) == wanted
                        && text(&composer["interactionMode"]) == "default"
                },
                |w| {
                    format!(
                        "the other thread; the composer is {}",
                        show(&composer_shown(w))
                    )
                },
            )
        },
    );

    // A new thread while the last one is still being made.
    steps.step(
        "the user sent a draft that is still creating its worktree",
        |world, _, _| send_held(world),
    );
    steps.step("a fresh draft opens", |world, _, _| {
        let sent = world.mc.part::<Creating>().sent_draft_id.clone();
        world.wait_for_with(
            |w| route_kind(w) == "draft" && text(&w.state("route")["draftId"]) != sent,
            |w| format!("a fresh draft; the route is {}", show(&w.state("route"))),
        )?;
        world.draft_id = text(&world.state("route")["draftId"]);
        let composer = composer_shown(world);
        expect!(
            text(&composer["target"]) == world.draft_id && text(&composer["text"]).is_empty(),
            "the composer shows {}",
            show(&composer)
        );
        Ok(())
    });
    steps.step(
        "the sent thread keeps setting up and starts when its worktree is ready",
        |world, _, _| {
            let (sent_draft, sent_key) = {
                let creating = world.mc.part::<Creating>();
                (
                    creating.sent_draft_id.clone(),
                    creating.sent_thread_key.clone(),
                )
            };
            expect!(
                draft_of(world, &sent_draft).is_some() && launching(world, &sent_draft),
                "the sent draft is no longer being made"
            );
            world.mc.answer_held();
            world.sync()?;
            let thread_id = sent_key
                .split_once(':')
                .map_or(sent_key.as_str(), |(_, id)| id)
                .to_owned();
            world.wait_for_with(
                |w| draft_of(w, &sent_draft).is_none() && w.mc.threads.contains_key(&thread_id),
                |_| "the sent thread to start".to_owned(),
            )?;
            expect!(
                launch_calls_len(world) == 1
                    && text(&world.state("route")["draftId"]) == world.draft_id,
                "{} launches; the route is {}",
                launch_calls_len(world),
                show(&world.state("route"))
            );
            Ok(())
        },
    );
    steps.step(
        "the user sent a draft and opened a new draft while it set up",
        |world, _, _| {
            send_held(world)?;
            world.start_new_thread(json!({}))?;
            let sent = world.mc.part::<Creating>().sent_draft_id.clone();
            world.wait_for_with(
                |w| text(&w.state("route")["draftId"]) != sent,
                |_| "a new draft".to_owned(),
            )?;
            world.draft_id = text(&world.state("route")["draftId"]);
            type_(world, "Write the changelog")
        },
    );
    steps.step("the sent thread fails to start", |world, _, _| {
        world.mc.refusals.insert(
            "orchestration.launchThread".into(),
            "Provider unavailable".into(),
        );
        world.mc.answer_held();
        world.sync()?;
        let sent = world.mc.part::<Creating>().sent_draft_id.clone();
        world.wait_for_with(
            |w| !launching(w, &sent),
            |_| "the launch to be answered".to_owned(),
        )
    });
    steps.step("its prompt is back in its own draft", |world, _, _| {
        let sent_id = world.mc.part::<Creating>().sent_draft_id.clone();
        let sent = draft_of(world, &sent_id);
        expect!(
            sent.as_ref().is_some_and(|d| d.text == "Set up the linter"),
            "the sent draft reads \"{}\"",
            sent.as_ref().map_or("", |d| &d.text)
        );
        Ok(())
    });
    steps.step("the new draft is unchanged", |world, _, _| {
        let fresh = draft_of(world, &world.draft_id);
        let composer = composer_shown(world);
        expect!(
            fresh
                .as_ref()
                .is_some_and(|d| d.text == "Write the changelog")
                && text(&world.state("route")["draftId"]) == world.draft_id
                && composer["text"] == json!("Write the changelog"),
            "the composer shows {}",
            show(&composer)
        );
        Ok(())
    });

    // A request to several models whose start fails after the user moved on.
    steps.step(
        "a request to several models is still starting",
        |world, _, _| {
            let project = first_project(world);
            make_git_project(world, &project)?;
            start_draft(world, json!({}))?;
            world.wait_for("the draft's checkout to be known", |w| {
                workspace::git(w.engine()).is_some_and(|git| {
                    git.local.get("isRepo").and_then(Value::as_bool) == Some(true)
                })
            })?;
            offer_models(world)?;
            choose(world, "composer.model.select", "Opus")?;
            choose(world, "composer.model.multiple.toggle", "Gemini")?;
            expect!(
                several_models(world).len() == 2,
                "the picker is {}",
                show(&world.state("modelPicker"))
            );
            world.mc.hold("answers");
            type_(world, "Add caching")?;
            submit(world)?;
            world.wait_for_with(
                |w| launch_calls_len(w) == 2,
                |w| format!("two launches; the MC got {}", launch_calls_len(w)),
            )
        },
    );
    steps.step(
        "the user has typed a new prompt in the emptied draft",
        |world, _, _| {
            world.wait_for_with(
                |w| text(&composer_shown(w)["text"]).is_empty(),
                |w| {
                    format!(
                        "the draft to empty; the composer shows {}",
                        show(&composer_shown(w))
                    )
                },
            )?;
            type_(world, "Add retries")
        },
    );
    steps.step("one of the models fails to start", |world, _, _| {
        world.mc.refusals.insert(
            "orchestration.launchThread".into(),
            "Provider unavailable".into(),
        );
        world.mc.answer_held();
        world.sync()?;
        world.wait_for_with(
            |w| told_titled(w, "Could not start"),
            |w| format!("the failure; the toasts are {}", show(&w.state("toasts"))),
        )
    });
    steps.step("the new prompt is left as it is", |world, _, _| {
        let composer = composer_shown(world);
        let draft = draft_of(world, &world.draft_id);
        expect!(
            composer["text"] == json!("Add retries")
                && draft.as_ref().is_some_and(|d| d.text == "Add retries"),
            "the composer shows {}",
            show(&composer)
        );
        Ok(())
    });

    // A draft whose project is gone: here, its machine left the cluster.
    steps.step(
        "the draft's project is no longer available",
        |world, _, _| {
            world.draft_id = drafts::start(world.engine(), "env-left", "shop").unwrap_or_default();
            let wanted = world.draft_id.clone();
            world.wait_for_with(
                |w| text(&composer_shown(w)["target"]) == wanted,
                |w| format!("the draft; the composer is {}", show(&composer_shown(w))),
            )
        },
    );
    steps.step("the draft keeps its prompt", |world, _, _| {
        let draft = draft_of(world, &world.draft_id);
        expect!(
            draft.as_ref().is_some_and(|d| !d.text.is_empty())
                && text(&composer_shown(world)["text"]) == draft.as_ref().map_or("", |d| &d.text)
                && launch_calls_len(world) == 0,
            "the composer shows {}",
            show(&composer_shown(world))
        );
        Ok(())
    });

    // A start the environment refuses, or cannot be asked for.
    steps.step("the environment rejects new threads", |world, _, _| {
        world.mc.refusals.insert(
            "orchestration.launchThread".into(),
            "Provider unavailable".into(),
        );
        Ok(())
    });
    steps.step(
        "the user sends the first message of a new thread",
        |world, _, _| {
            start_draft(world, json!({}))?;
            type_(world, "Add caching")?;
            submit(world)
        },
    );
    steps.step("the environment is unreachable", |world, _, _| {
        let environment = world.mc.environment_id.clone();
        world.mc.set_online(&environment, false);
        world.sync()
    });
    steps.step(
        "the user is told the environment is offline",
        |world, _, _| {
            world.wait_for_with(
                |w| text(&composer_shown(w)["sendDisabledReason"]) == "Not connected",
                |w| format!("the composer to say so; it is {}", show(&composer_shown(w))),
            )?;
            type_(world, "Add caching")?;
            submit(world)?;
            world.wait_for_with(
                |w| told_titled(w, "Not connected"),
                |w| format!("the notice; the toasts are {}", show(&w.state("toasts"))),
            )
        },
    );
    steps.step("no draft is sent to the environment", |world, _, _| {
        expect!(launch_calls_len(world) == 0, "the MC was asked to launch");
        expect!(
            !text(&composer_shown(world)["text"]).is_empty(),
            "the draft lost its prompt"
        );
        Ok(())
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
            |w| {
                format!(
                    "the draft on {}; the composer is {}",
                    c[0],
                    show(&w.state("composer"))
                )
            },
        )
    });
}

fn launch_calls_len(world: &World) -> usize {
    world
        .mc
        .peek::<FakeLaunches>()
        .map_or(0, |launches| launches.calls.len())
}
