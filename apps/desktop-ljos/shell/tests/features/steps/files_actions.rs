//! Project actions beyond running them (features/files/project-scripts-and-actions.feature)
//! and the checkout's hal-c2.json (files/project-file.feature), desktop-qt's
//! FilesActionsSteps.cpp: the action editor and the thread details' Actions as
//! the window draws them (ProjectActionEditor.qml, ThreadDetailsPanel.qml)
//! over ProjectActions. Running an action from the header is the terminal
//! steps'.

use hal_c2_shell::controllers::keybindings::Keymap;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use serde_json::{Value as Json, json};

use super::fake_files::fake_files;
use super::files_identity::type_into;
use super::keybinding::press_key;
use super::settings::{fake_config, save_on};
use crate::brick::{self, Brick};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

fn scripts_of(world: &World, project: &str) -> Vec<Json> {
    world
        .mc
        .projects
        .get(project)
        .and_then(|row| row["scripts"].as_array().cloned())
        .unwrap_or_default()
}

fn script_named(world: &World, project: &str, name: &str) -> Option<Json> {
    scripts_of(world, project)
        .into_iter()
        .find(|script| script["name"] == name)
}

fn describe_scripts(world: &World, project: &str) -> String {
    format!(
        "{project} has the actions {}",
        Json::Array(scripts_of(world, project))
    )
}

/// The project the scenario's actions belong to: the first the MC has.
fn project(world: &World) -> Outcome<String> {
    if world.mc.projects.is_empty() {
        fail!("the MC has no project");
    }
    Ok(if world.mc.projects.contains_key("shop") {
        "shop".to_owned()
    } else {
        world.mc.projects.keys().next().cloned().unwrap_or_default()
    })
}

fn set_scripts(world: &mut World, project: &str, scripts: Vec<Json>) -> Outcome {
    let mut row = world.mc.projects.get(project).cloned().unwrap_or(json!({}));
    row["scripts"] = Json::Array(scripts);
    world.mc.projects.insert(project.to_owned(), row.clone());
    world.mc.send_row_of(project, &row, "project");
    world.sync()
}

fn script(id: &str, name: &str, command: &str, setup: bool) -> Json {
    json!({"id": id, "name": name, "command": command, "icon": "play",
           "runOnWorktreeCreate": setup})
}

fn workspace(world: &World) -> Json {
    world.state("workspace")
}

fn actions(world: &World) -> Json {
    world.state("projectActions")
}

/// A thread of `project`, shown in the window.
fn show_thread(world: &mut World, project: &str) -> Outcome {
    let thread = format!("thread-in-{project}");
    let environment = world.mc.environment_id.clone();
    let key = format!("{environment}:{thread}");
    if *at(&workspace(world), "threadKey") == json!(key)
        && *at(&world.state("route"), "kind") == json!("thread")
    {
        return Ok(());
    }
    let row = json!({"id": thread, "title": "Cart", "projectId": project,
                     "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
    world.mc.threads.insert(thread.clone(), row.clone());
    world.mc.send_row(&thread, &row);
    let route = Route::Thread(key.clone());
    world.with::<Navigation, _>(|n, engine| n.open(engine, route))?;
    let wanted = format!("{environment}:{project}");
    let ready = {
        let (key, wanted) = (key.clone(), wanted.clone());
        move |w: &World| {
            text(at(&workspace(w), "threadKey")) == key
                && text(at(&actions(w), "projectKey")) == wanted
        }
    };
    let project = project.to_owned();
    world.wait_for_with(ready, move |w| {
        format!(
            "the thread of {project}; the header shows {}",
            show(&workspace(w))
        )
    })
}

// --- The terminal the action runs in ---------------------------------------------------

fn terminal_calls(world: &World, method: &str) -> Vec<Json> {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == method)
        .map(|rpc| rpc.payload.clone())
        .collect()
}

/// `command` was typed into a terminal opened in the thread's workspace.
fn expect_ran(world: &mut World, command: &str) -> Outcome {
    let state = workspace(world);
    let cwd = match text(at(&state, "worktreePath")) {
        path if path.is_empty() => text(at(&state, "projectRoot")),
        path => path,
    };
    let typed = format!("{command}\r");
    let ran = {
        let (cwd, typed) = (cwd.clone(), typed.clone());
        move |w: &World| {
            terminal_calls(w, "terminal.open")
                .iter()
                .any(|call| call["cwd"] == json!(cwd))
                && terminal_calls(w, "terminal.write")
                    .iter()
                    .any(|call| call["data"] == json!(typed))
        }
    };
    let command = command.to_owned();
    world.wait_for_with(ran, move |w| {
        format!(
            "{command} in a terminal at {cwd}; terminals were opened {} and written {}",
            show(&Json::Array(terminal_calls(w, "terminal.open"))),
            show(&Json::Array(terminal_calls(w, "terminal.write")))
        )
    })
}

// --- The editor ------------------------------------------------------------------------

fn show_editor_brick(world: &mut World) -> Outcome {
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Bricks\nItem { ProjectActionEditor {} }\n",
        900.0,
        800.0,
    )?;
    let shown = brick::shown(world)?;
    world.wait_for("the action editor to open", move |w| {
        shown
            .find(w, "projectActionEditor")
            .ok()
            .flatten()
            .is_some_and(|editor| shown.flag(w, editor, "opened"))
    })
}

/// The editor on a new action, or on the action named `name`.
fn open_editor(world: &mut World, name: Option<&str>) -> Outcome {
    let project = project(world)?;
    show_thread(world, &project)?;
    match name {
        None => world.dispatch("projectActions.add", json!({}))?,
        Some(name) => {
            let Some(found) = script_named(world, &project, name) else {
                fail!("{}", describe_scripts(world, &project));
            };
            world.dispatch("projectActions.edit", json!({"scriptId": found["id"]}))?;
        }
    }
    expect!(
        !at(&actions(world), "editor").is_null(),
        "no editor opened: {}",
        show(&actions(world))
    );
    show_editor_brick(world)
}

/// Replaces what the field holds, typing as the user does.
fn type_field(world: &mut World, field: &str, typed: &str) -> Outcome {
    type_into(world, field, typed)?;
    if typed.is_empty() {
        brick::shown(world)?.press(world, "backspace")?;
    }
    Ok(())
}

fn save(world: &mut World) -> Outcome {
    brick::shown(world)?.click(world, "projectActionSave")?;
    world.sync()
}

fn saved(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| at(&actions(w), "editor").is_null(),
        |w| {
            format!(
                "the editor to close; it is {}",
                show(at(&actions(w), "editor"))
            )
        },
    )?;
    world.sync()
}

fn updates(world: &World) -> usize {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| {
            rpc.method == "projects.mutate"
                && rpc.payload["type"] == "project.update"
                && rpc.payload.get("scripts").is_some()
        })
        .count()
}

fn run_script(world: &mut World, id: &Json) -> Outcome {
    world.dispatch("workspace.runScript", json!({"scriptId": id}))
}

// --- Shortcuts -------------------------------------------------------------------------

fn command_of(world: &World, project: &str, name: &str) -> String {
    let id = script_named(world, project, name)
        .map(|found| text(&found["id"]))
        .unwrap_or_else(|| name.to_lowercase());
    format!("script.{id}.run")
}

fn rules(world: &mut World) -> Vec<Json> {
    fake_config(&mut world.mc)
        .config
        .get("keybindingRules")
        .and_then(|rules| rules.as_array().cloned())
        .unwrap_or_default()
}

fn bound(world: &mut World, key: &str, command: &str) -> bool {
    rules(world)
        .iter()
        .any(|rule| rule["key"] == key && rule["command"] == command)
}

fn runs(world: &World, command: &str) -> bool {
    Keymap::of(world.engine())
        .bindings()
        .iter()
        .any(|binding| binding.command == command)
}

fn bind_shortcut(world: &mut World, command: &str, key: &str) -> Outcome {
    Keymap::of(world.engine()).save(world.engine(), command, key, "", None);
    let (command_wanted, key_wanted) = (command.to_owned(), key.to_owned());
    world.wait_for("the shortcut to be saved", move |w| {
        let kept = fake_config_peek(w)
            .iter()
            .any(|rule| rule["key"] == key_wanted && rule["command"] == command_wanted);
        kept && !Keymap::of(w.engine()).saving()
    })?;
    world.sync()
}

/// The saved rules, read without the mutable access `fake_config` takes.
fn fake_config_peek(world: &World) -> Vec<Json> {
    world
        .mc
        .peek::<super::settings::FakeConfig>()
        .and_then(|config| config.config.get("keybindingRules"))
        .and_then(|rules| rules.as_array().cloned())
        .unwrap_or_default()
}

// --- hal-c2.json -----------------------------------------------------------------------

fn write_project_file(world: &mut World, contents: &str) {
    fake_files(&mut world.mc)
        .files
        .insert("hal-c2.json".to_owned(), contents.to_owned());
}

fn file_scripts(scripts: &[(&str, &str)]) -> String {
    let list: Vec<Json> = scripts
        .iter()
        .map(|(name, command)| json!({"name": name, "command": command}))
        .collect();
    serde_json::to_string_pretty(&json!({"scripts": list})).unwrap_or_default()
}

/// The thread details column, with the project's actions.
fn show_details(world: &mut World, project: &str) -> Outcome {
    show_thread(world, project)?;
    if !at(&world.state("panel"), "detailsOpen")
        .as_bool()
        .unwrap_or(false)
    {
        world.dispatch("threadPanel.toggle", json!({}))?;
    }
    world.wait_for("hal-c2.json to be read", |w| {
        *at(&actions(w), "file") != json!("loading")
    })?;
    // The thread's own read of the file has been answered.
    world.sync()?;
    world.sync()?;
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n\
         ThreadDetailsPanel { details: Shell.state.panel?.details ?? null }\n",
        280.0,
        800.0,
    )
}

fn offered_imports(world: &mut World) -> Outcome<Vec<String>> {
    let shown = brick::shown(world)?;
    let mut names = Vec::new();
    let offered = at(&actions(world), "imports")
        .as_array()
        .cloned()
        .unwrap_or_default();
    for entry in offered {
        let name = text(&entry["name"]);
        // As the details column draws them.
        let item = shown.item(world, &format!("threadDetailsImport-{name}"))?;
        if shown.flag(world, item, "visible") {
            names.push(name);
        }
    }
    Ok(names)
}

fn starts_in(world: &mut World, mode: &str) -> Outcome {
    world.wait_for_with(
        |w| {
            at(&workspace(w), "isDraft").as_bool().unwrap_or(false)
                && *at(&actions(w), "file") != json!("loading")
        },
        |w| {
            format!(
                "the draft and its hal-c2.json; the header shows {}",
                show(&workspace(w))
            )
        },
    )?;
    let wanted = mode.to_owned();
    let shown = mode.to_owned();
    world.wait_for_with(
        move |w| text(at(&workspace(w), "envMode")) == wanted,
        move |w| {
            format!(
                "the draft to start in \"{shown}\"; the header shows {}",
                show(&workspace(w))
            )
        },
    )?;
    world.sync()?;
    expect!(
        text(at(&workspace(world), "envMode")) == mode,
        "the header shows {}",
        show(&workspace(world))
    );
    Ok(())
}

pub fn register(steps: &mut Steps) {
    // Running from the thread's details and from a shortcut.
    steps.step(
        &format!("the user is looking at the details of a thread in {Q}"),
        |world, c, _| show_details(world, &c[0]),
    );
    steps.step(
        &format!("the user runs {Q} from the thread's details"),
        |world, c, _| {
            let project = project(world)?;
            let Some(found) = script_named(world, &project, &c[0]) else {
                fail!("{}", describe_scripts(world, &project));
            };
            brick::shown(world)?.click(
                world,
                &format!("threadDetailsAction-{}", text(&found["id"])),
            )?;
            world.sync()
        },
    );
    steps.step(
        &format!("{Q} runs in a terminal for the thread's workspace"),
        |world, c, _| expect_ran(world, &c[0]),
    );
    steps.step(
        &format!("{Q} runs in the thread's terminal"),
        |world, c, _| expect_ran(world, &c[0]),
    );
    steps.step(&format!("{Q} has the shortcut {Q}"), |world, c, _| {
        let project = project(world)?;
        let command = command_of(world, &project, &c[0]);
        bind_shortcut(world, &command, &c[1])
    });
    steps.step(
        &format!("the user presses {Q} in a thread of {Q}"),
        |world, c, _| {
            show_thread(world, &c[1])?;
            press_key(world, &c[0])?;
            world.sync()
        },
    );

    // Adding, editing and removing.
    steps.step(
        &format!(
            "the user adds an action named {Q} running {Q} with the (play|test|lint|configure|build|debug) icon"
        ),
        |world, c, _| {
            open_editor(world, None)?;
            type_field(world, "projectActionName", &c[0])?;
            type_field(world, "projectActionCommand", &c[1])?;
            world.dispatch("projectActions.set", json!({"icon": c[2]}))?;
            save(world)?;
            saved(world)
        },
    );
    steps.step(&format!("{Q} has the action {Q}"), |world, c, _| {
        if let Some(hook) = world.on_settings_page.get("hasAction").cloned() {
            return hook(world, c);
        }
        let (project, name) = (c[0].clone(), c[1].clone());
        world.wait_for_with(
            {
                let (project, name) = (project.clone(), name.clone());
                move |w| script_named(w, &project, &name).is_some()
            },
            {
                let project = project.clone();
                move |w| describe_scripts(w, &project)
            },
        )?;
        world.sync()?;
        // And the header offers it.
        let id = script_named(world, &project, &name)
            .map(|found| found["id"].clone())
            .unwrap_or(Json::Null);
        let offered = at(&workspace(world), "scripts")
            .as_array()
            .cloned()
            .unwrap_or_default();
        expect!(
            offered.iter().any(|entry| entry["id"] == id),
            "the header offers {}",
            show(&Json::Array(offered))
        );
        Ok(())
    });
    steps.step(&format!("{Q} can be run"), |world, c, _| {
        let project = project(world)?;
        let Some(found) = script_named(world, &project, &c[0]) else {
            fail!("{}", describe_scripts(world, &project));
        };
        run_script(world, &found["id"])?;
        expect_ran(world, &text(&found["command"]))
    });
    steps.step(
        "the user adds an action with (no name|no command)",
        |world, c, _| {
            open_editor(world, None)?;
            if c[0] == "no name" {
                type_field(world, "projectActionCommand", "bun test")?;
            } else {
                type_field(world, "projectActionName", "Test")?;
            }
            save(world)
        },
    );
    steps.step("no action is added", |world, _, _| {
        world.sync()?;
        let project = project(world)?;
        expect!(
            updates(world) == 0 && !at(&actions(world), "editor").is_null(),
            "the project was saved {} time(s); {}",
            updates(world),
            describe_scripts(world, &project)
        );
        Ok(())
    });
    steps.step(
        &format!("the user changes the command of {Q} to {Q}"),
        |world, c, _| {
            open_editor(world, Some(&c[0]))?;
            type_field(world, "projectActionCommand", &c[1])?;
            save(world)?;
            saved(world)
        },
    );
    steps.step(&format!("{Q} runs {Q}"), |world, c, _| {
        let project = project(world)?;
        let found = script_named(world, &project, &c[0]);
        let Some(found) = found.filter(|f| f["command"] == c[1]) else {
            fail!("{}", describe_scripts(world, &project));
        };
        run_script(world, &found["id"])?;
        expect_ran(world, &c[1])
    });
    steps.step(
        &format!("the user deletes the action {Q}(?: from {Q})?"),
        |world, c, _| {
            open_editor(world, Some(&c[0]))?;
            brick::shown(world)?.click(world, "projectActionDelete")?;
            // "from <project>" has no question in its scenario: the user says yes.
            let from = c.get(1).cloned().unwrap_or_default();
            if !from.is_empty() {
                let question = world.state("confirmation");
                expect!(question.is_object(), "no question is asked");
                world.dispatch(
                    "confirmation.answer",
                    json!({"requestId": question["requestId"], "accepted": true}),
                )?;
                let name = c[0].clone();
                world.wait_for_with(
                    {
                        let (from, name) = (from.clone(), name.clone());
                        move |w| script_named(w, &from, &name).is_none()
                    },
                    move |w| describe_scripts(w, &from),
                )?;
                world.sync()?;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the user is asked to confirm deleting {Q} because it cannot be undone"),
        |world, c, _| {
            let question = world.state("confirmation");
            expect!(
                question["title"] == format!("Delete action \"{}\"?", c[0])
                    && question["description"] == "This action cannot be undone."
                    && question["destructive"] == true,
                "the question is {}",
                show(&question)
            );
            let project = project(world)?;
            expect!(
                script_named(world, &project, &c[0]).is_some(),
                "the action went before the user answered"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} no longer has the action {Q}"),
        |world, c, _| {
            let (project, name) = (c[0].clone(), c[1].clone());
            world.wait_for_with(
                {
                    let (project, name) = (project.clone(), name.clone());
                    move |w| script_named(w, &project, &name).is_none()
                },
                move |w| describe_scripts(w, &project),
            )?;
            world.sync()?;
            let offered = at(&workspace(world), "scripts")
                .as_array()
                .cloned()
                .unwrap_or_default();
            expect!(
                offered.iter().all(|entry| entry["name"] != name),
                "the header offers {}",
                show(&Json::Array(offered))
            );
            Ok(())
        },
    );

    // The setup script.
    steps.step(&format!("{Q} is the setup script of {Q}"), |world, c, _| {
        let mut scripts = scripts_of(world, &c[1]);
        if script_named(world, &c[1], &c[0]).is_none() {
            scripts.push(script(&c[0].to_lowercase(), &c[0], "bun install", true));
        }
        set_scripts(world, &c[1], scripts)
    });
    steps.step(
        &format!("the user makes {Q} run automatically on worktree creation"),
        |world, c, _| {
            open_editor(world, Some(&c[0]))?;
            brick::shown(world)?.click(world, "projectActionSetup")?;
            save(world)?;
            saved(world)
        },
    );
    steps.step(&format!("{Q} is the setup script"), |world, c, _| {
        let project = project(world)?;
        let found = script_named(world, &project, &c[0]);
        expect!(
            found.is_some_and(|f| f["runOnWorktreeCreate"] == true),
            "{}",
            describe_scripts(world, &project)
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} no longer runs on worktree creation"),
        |world, c, _| {
            let project = project(world)?;
            let found = script_named(world, &project, &c[0]);
            expect!(
                found.is_some_and(|f| f["runOnWorktreeCreate"] != true),
                "{}",
                describe_scripts(world, &project)
            );
            Ok(())
        },
    );

    // Shortcuts.
    steps.step(
        &format!("the user clears the shortcut of {Q}"),
        |world, c, _| {
            open_editor(world, Some(&c[0]))?;
            let shown = brick::shown(world)?;
            shown.click(world, "projectActionKeybinding")?;
            shown.press(world, "backspace")?;
            save(world)?;
            saved(world)
        },
    );
    steps.step(&format!("{Q} no longer runs {Q}"), |world, c, _| {
        let project = project(world)?;
        let command = command_of(world, &project, &c[1]);
        let (key, wanted) = (c[0].clone(), command.clone());
        let gone = move |w: &World| {
            !fake_config_peek(w)
                .iter()
                .any(|rule| rule["key"] == key && rule["command"] == wanted)
                && !runs(w, &wanted)
        };
        let (key, wanted) = (c[0].clone(), command);
        world.wait_for_with(gone, move |w| {
            format!(
                "{key} to stop running {wanted}; the rules are {}",
                show(&Json::Array(fake_config_peek(w)))
            )
        })
    });
    steps.step(
        &format!("the project {Q} also has an action {Q} with the shortcut {Q}"),
        |world, c, _| {
            let existing = project(world)?;
            let command = command_of(world, &existing, &c[1]);
            let id = command.split('.').nth(1).unwrap_or_default().to_owned();
            let row = json!({"id": c[0], "title": c[0], "workspaceRoot": format!("/work/{}", c[0]),
                             "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z",
                             "scripts": [script(&id, &c[1], "bun docs", false)]});
            world.mc.projects.insert(c[0].clone(), row.clone());
            world.mc.send_row_of(&c[0], &row, "project");
            world.sync()?;
            bind_shortcut(world, &command, &c[2])
        },
    );
    steps.step(&format!("{Q} still runs {Q} in {Q}"), |world, c, _| {
        world.sync()?;
        let Some(found) = script_named(world, &c[2], &c[1]) else {
            fail!("{}", describe_scripts(world, &c[2]));
        };
        let command = format!("script.{}.run", text(&found["id"]));
        let kept = bound(world, &c[0], &command) && runs(world, &command);
        expect!(kept, "the rules are {}", show(&Json::Array(rules(world))));
        for rpc in &world.mc.calls {
            expect!(
                rpc.method != "hal-c2.removeKeybinding",
                "the shortcut was removed"
            );
        }
        Ok(())
    });

    // The preview address.
    steps.step(
        &format!("the user edits {Q} without a preview address"),
        |world, c, _| {
            open_editor(world, Some(&c[0]))?;
            expect!(
                text(at(&actions(world), "editor.previewUrl")).is_empty(),
                "{}",
                show(&actions(world))
            );
            Ok(())
        },
    );
    steps.step(
        "opening the preview automatically (cannot|can) be turned on",
        |world, c, _| {
            let wanted = c[0] == "can";
            let shown = brick::shown(world)?;
            let toggle = shown.item(world, "projectActionAutoOpenPreview")?;
            world.wait_for(
                if wanted {
                    "the switch to be enabled"
                } else {
                    "the switch to be disabled"
                },
                move |w| shown.flag(w, toggle, "enabled") == wanted,
            )?;
            if !wanted {
                return Ok(());
            }
            shown.click(world, "projectActionAutoOpenPreview")?;
            world.wait_for_with(
                |w| at(&actions(w), "editor.autoOpenPreview") == &json!(true),
                |w| {
                    format!(
                        "the editor to take it; it is {}",
                        show(at(&actions(w), "editor"))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user sets the preview address {Q}"),
        |world, c, _| type_field(world, "projectActionPreviewUrl", &c[0]),
    );

    // hal-c2.json.
    steps.step(
        &format!("the checkout's hal-c2.json sets the default workspace to {Q}"),
        |world, c, _| {
            write_project_file(
                world,
                &format!("{{\"defaultThreadEnvMode\": \"{}\"}}", c[0]),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user never chose a default workspace for {Q}"),
        |world, c, _| {
            let settings = Json::Object(fake_config(&mut world.mc).settings.clone());
            expect!(
                text(&settings["defaultThreadEnvMode"]).is_empty()
                    && settings["projectSettingsOverrides"][&c[0]]
                        .get("defaultThreadEnvMode")
                        .is_none(),
                "the settings are {}",
                show(&settings)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user set the default workspace for {Q} to {Q}"),
        |world, c, _| {
            let environment = world.mc.environment_id.clone();
            save_on(
                &mut world.mc,
                &environment,
                "projectSettingsOverrides",
                json!({c[0].as_str(): {"defaultThreadEnvMode": c[1]}}),
            );
            world.sync()
        },
    );
    steps.step("the draft starts in a new worktree", |world, _, _| {
        starts_in(world, "worktree")
    });
    steps.step("the draft starts in the project folder", |world, _, _| {
        starts_in(world, "local")
    });

    steps.step(
        &format!("the checkout's hal-c2.json declares the actions {Q} and {Q}"),
        |world, c, _| {
            let first = format!("bun {}", c[0].to_lowercase());
            let second = format!("bun {}", c[1].to_lowercase());
            write_project_file(world, &file_scripts(&[(&c[0], &first), (&c[1], &second)]));
            Ok(())
        },
    );
    steps.step(
        &format!("the checkout's hal-c2.json declares {Q} running {Q} and {Q} running {Q}"),
        |world, c, _| {
            write_project_file(world, &file_scripts(&[(&c[0], &c[1]), (&c[2], &c[3])]));
            Ok(())
        },
    );
    steps.step(
        "the checkout's hal-c2.json does not match the project file format",
        |world, _, _| {
            // A script without a command.
            write_project_file(world, "{\"scripts\": [{\"name\": \"Dev\"}]}");
            Ok(())
        },
    );
    steps.step(
        &format!("the checkout's hal-c2.json has comments and declares the action {Q}"),
        |world, c, _| {
            write_project_file(
                world,
                &format!(
                    "// Shared with everyone who opens the checkout.\n{{\n  /* the dev server */\n  \"scripts\": [\n    \
                     {{\"name\": \"{}\", \"command\": \"bun dev\"}}, // trailing comma next\n  ],\n}}\n",
                    c[0]
                ),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} already has an action {Q} running {Q}"),
        |world, c, _| {
            let mut scripts = scripts_of(world, &c[0]);
            scripts.push(script(&c[1].to_lowercase(), &c[1], &c[2], false));
            set_scripts(world, &c[0], scripts)
        },
    );
    steps.step(
        &format!("the user looks at the actions of {Q}"),
        |world, c, _| show_details(world, &c[0]),
    );
    steps.step(
        &format!("{Q} and {Q} are offered to import from hal-c2.json"),
        |world, c, _| {
            let offered = offered_imports(world)?;
            expect!(
                offered == [c[0].clone(), c[1].clone()],
                "the details offer {}",
                offered.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is offered to import from hal-c2.json"),
        |world, c, _| {
            let offered = offered_imports(world)?;
            expect!(
                offered == [c[0].clone()],
                "the details offer {}",
                offered.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        "the user imports actions from hal-c2.json",
        |world, _, _| {
            let project = project(world)?;
            show_details(world, &project)?;
            let offered = offered_imports(world)?;
            expect!(
                !offered.is_empty(),
                "nothing is offered to import: {}",
                show(&actions(world))
            );
            for name in offered {
                let before = scripts_of(world, &project).len();
                brick::shown(world)?.click(world, &format!("threadDetailsImport-{name}"))?;
                world.sync()?;
                let shown = project.clone();
                world.wait_for_with(
                    {
                        let project = project.clone();
                        move |w| scripts_of(w, &project).len() > before
                    },
                    move |w| describe_scripts(w, &shown),
                )?;
                world.sync()?;
            }
            Ok(())
        },
    );
    steps.step(&format!("only {Q} is added"), |world, c, _| {
        let project = project(world)?;
        let scripts = scripts_of(world, &project);
        expect!(
            scripts.len() == 2
                && scripts.last().is_some_and(|s| s["name"] == c[0])
                && updates(world) == 1,
            "{}",
            describe_scripts(world, &project)
        );
        expect!(
            at(&actions(world), "imports")
                .as_array()
                .is_none_or(Vec::is_empty),
            "more is offered: {}",
            show(&actions(world))
        );
        Ok(())
    });
    steps.step(
        "the user is warned that hal-c2.json is invalid",
        |world, _, _| {
            if let Some(hook) = world.on_settings_page.get("invalidProjectFile").cloned() {
                return hook(world, &Vec::new());
            }
            let shown = brick::shown(world)?;
            let warning = shown.item(world, "threadDetailsProjectFileProblem")?;
            expect!(
                shown.flag(world, warning, "visible")
                    && shown
                        .text_of(world, warning, "text")
                        .starts_with("hal-c2.json is invalid"),
                "the details say nothing of the file: {}",
                show(&actions(world))
            );
            Ok(())
        },
    );
    steps.step("no actions are offered from it", |world, _, _| {
        expect!(
            at(&actions(world), "imports")
                .as_array()
                .is_none_or(Vec::is_empty),
            "{}",
            show(&actions(world))
        );
        Ok(())
    });
}
