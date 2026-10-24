//! Settings → Project, Actions (desktop-qt's SettingsProjectActionsSteps.cpp;
//! ProjectActionsController, features/settings/project-actions.feature): the
//! environment's default actions and a project's own list in the MC's
//! settings document, what each project then offers to run, and
//! hal-c2.json's actions read from the checkout.

use std::rc::Rc;

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::settings_scope::SettingsScope;
use serde_json::{Map, Value, json};

use super::fake_files::fake_files;
use super::settings::{document_of, fake_config, save_on};
use super::settings_scoped_rows::{held_all, with_capabilities};
use super::settings_search::settings_shell;
use crate::harness::{Outcome, Q, Steps, at, show};
use crate::world::World;
use crate::{expect, fail};

const SCRIPTS: &str = "defaultProjectScripts";
const OVERRIDES: &str = "projectSettingsOverrides";
const SERVER: &str = "server";
const REPOSITORY: &str = "github.com/acme/shop";

fn script(name: &str, command: &str, setup: bool, preview_url: &str) -> Value {
    let mut action = json!({
        "id": name.to_lowercase(),
        "name": name,
        "command": command,
        "icon": "play",
        "runOnWorktreeCreate": setup,
    });
    if !preview_url.is_empty() {
        action["previewUrl"] = json!(preview_url);
    }
    action
}

fn panel(world: &World) -> Value {
    world.state("projectActions")
}

fn scope_state(world: &World) -> Value {
    world.state("settingsScope")
}

fn names(actions: &Value) -> Vec<String> {
    actions
        .as_array()
        .map(|list| {
            list.iter()
                .map(|action| at(action, "name").as_str().unwrap_or_default().to_owned())
                .collect()
        })
        .unwrap_or_default()
}

fn describe(world: &World) -> String {
    format!(
        "the Actions panel is {}; the MC holds {}",
        show(&panel(world)),
        show(&held_all(world))
    )
}

fn override_of(settings: &Value, project: &str) -> Value {
    settings[OVERRIDES][project][SCRIPTS].clone()
}

fn has_override(settings: &Value, project: &str) -> bool {
    settings[OVERRIDES][project].get(SCRIPTS).is_some()
}

fn set_override(world: &mut World, project: &str, scripts: Value) {
    let mut overrides = held_all(world)[OVERRIDES]
        .as_object()
        .cloned()
        .unwrap_or_default();
    overrides.insert(project.to_owned(), json!({ SCRIPTS: scripts }));
    let environment = world.mc.environment_id.clone();
    save_on(
        &mut world.mc,
        &environment,
        OVERRIDES,
        Value::Object(overrides),
    );
}

/// This machine's MC keeps project overrides, as its config says.
fn announce_overrides(world: &mut World) -> Outcome {
    let fake = fake_config(&mut world.mc);
    fake.config = with_capabilities(fake.config.clone(), json!({ OVERRIDES: true }));
    let mut config = fake.config.clone();
    config.insert("settings".into(), Value::Object(fake.settings.clone()));
    let (environment, name) = (world.mc.environment_id.clone(), world.mc.name.clone());
    super::settings::send_config(
        &world.mc,
        &environment,
        json!({"t": "config", "mc": name, "config": config}),
    );
    world.sync()
}

/// The page's own words, as the brick draws them.
fn drawn_text(world: &mut World, name: &str) -> Outcome<(bool, String)> {
    let brick = settings_shell(world, 900.0, 2000.0)?;
    let item = brick.item(world, name)?;
    Ok((
        brick.flag(world, item, "visible"),
        brick.text_of(world, item, "text"),
    ))
}

/// Settings → Project, on all projects or on `project`.
fn open_actions(world: &mut World, project: &str) -> Outcome {
    // FilesActionsSteps' words for the thread's details, as this page shows them.
    world.on_settings_page.insert(
        "hasAction".into(),
        Rc::new(|world: &mut World, c: &Vec<String>| {
            let wanted = c[1].clone();
            let key = c[0].clone();
            world.wait_for_with(
                |w| {
                    let own = override_of(&held_all(w), &key);
                    names(&own) == [wanted.clone()]
                        && own[0]["command"] == "bun lint"
                        && names(&panel(w)["scripts"]) == [wanted.clone()]
                        && panel(w)["imports"].as_array().is_none_or(Vec::is_empty)
                },
                describe,
            )
        }),
    );
    world.on_settings_page.insert(
        "invalidProjectFile".into(),
        Rc::new(|world: &mut World, _: &Vec<String>| {
            world.wait_for_with(|w| panel(w)["file"] == "invalid", describe)?;
            let (visible, text) = drawn_text(world, "invalidFile")?;
            expect!(
                visible && text.starts_with("hal-c2.json is invalid"),
                "the page does not warn"
            );
            Ok(())
        }),
    );
    world.with::<Navigation, _>(|n, engine| {
        n.open(engine, Route::Settings("/settings/projects".into()))
    })?;
    world.wait_for_with(
        |w| panel(w)["settings"] == true && !scope_state(w).is_null(),
        describe,
    )?;
    announce_overrides(world)?;
    let mut key = String::new();
    if !project.is_empty() {
        let title = project.to_owned();
        world.wait_for_with(
            |w| find_project(w, &title).is_some(),
            |w| {
                format!(
                    "{title} to be offered; the scope is {}",
                    show(&scope_state(w))
                )
            },
        )?;
        key = find_project(world, project).unwrap_or_default();
    }
    world.dispatch("settingsScope.project", json!({"key": key}))?;
    world.dispatch("settingsScope.environment", json!({"id": ""}))?;
    let on_project = !project.is_empty();
    world.wait_for_with(
        move |w| (panel(w)["project"] == true) == on_project && panel(w)["available"] == true,
        describe,
    )
}

fn find_project(world: &World, title: &str) -> Option<String> {
    scope_state(world)["projects"]
        .as_array()?
        .iter()
        .find(|row| at(row, "title") == title)
        .and_then(|row| at(row, "key").as_str().map(str::to_owned))
        .filter(|key| !key.is_empty())
}

fn add(world: &mut World, name: &str, command: &str) -> Outcome {
    world.dispatch(
        "projectActions.add",
        json!({"name": name, "command": command}),
    )
}

/// Another project on this machine, with `own` actions if any.
fn add_project(world: &mut World, project: &str, own: Value) -> Outcome {
    let row = json!({
        "id": project,
        "title": project,
        "workspaceRoot": format!("/work/{project}"),
        "scripts": own,
    });
    world.mc.projects.insert(project.to_owned(), row.clone());
    world.mc.send_row_of(project, &row, "project");
    world.sync()
}

/// What a new thread in `project` offers to run (the header's actions).
fn offered(world: &mut World, project: &str) -> Outcome<Vec<String>> {
    let key = world.project_key(project);
    world.start_new_thread(json!({"projectKey": key}))?;
    let root = format!("/work/{project}");
    world.wait_for_with(
        |w| {
            let workspace = w.state("workspace");
            workspace["isDraft"] == true && workspace["projectRoot"] == root.as_str()
        },
        |w| {
            format!(
                "a new thread in {project}; the header shows {}",
                show(&w.state("workspace"))
            )
        },
    )?;
    Ok(names(&world.state("workspace")["scripts"]))
}

fn expect_offered(world: &mut World, project: &str, wanted: &[&str]) -> Outcome {
    let wanted: Vec<String> = wanted.iter().map(|s| (*s).to_owned()).collect();
    let mut shown = Vec::new();
    for _ in 0..200 {
        shown = offered(world, project)?;
        if shown == wanted {
            return Ok(());
        }
        world.pump()?;
    }
    fail!(
        "{project} to offer {}; it offers {}",
        wanted.join(", "),
        shown.join(", ")
    )
}

fn told(world: &World, title: &str) -> bool {
    at(&world.state("toasts"), "items")
        .as_array()
        .is_some_and(|items| items.iter().any(|toast| at(toast, "title") == title))
}

fn expect_told(world: &mut World, title: &str) -> Outcome {
    let wanted = title.to_owned();
    world.wait_for_with(
        |w| told(w, &wanted),
        |w| format!("\"{title}\"; the shell shows {}", show(&w.state("toasts"))),
    )
}

fn dev() -> Value {
    json!([script("Dev", "bun dev", false, "")])
}

pub fn register(steps: &mut Steps) {
    // The environment's defaults.
    steps.step(&format!("{Q} has no default actions"), |world, _, _| {
        expect!(
            held_all(world).get(SCRIPTS).is_none(),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user opens the Actions settings for all projects",
        |world, _, _| open_actions(world, ""),
    );
    steps.step(
        "the user is told no actions are configured",
        |world, _, _| {
            world.wait_for_with(|w| names(&panel(w)["scripts"]).is_empty(), describe)?;
            let (visible, _) = drawn_text(world, "noActions")?;
            let brick = settings_shell(world, 900.0, 2000.0)?;
            expect!(
                visible && brick.shows(world, "No actions configured.")?,
                "the page does not say so"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user adds the default action {Q} running {Q} for all projects"),
        |world, c, _| {
            open_actions(world, "")?;
            add(world, &c[0], &c[1])?;
            let wanted = c[0].clone();
            world.wait_for_with(
                |w| names(&held_all(w)[SCRIPTS]) == [wanted.clone()],
                describe,
            )
        },
    );
    steps.step(
        &format!("{Q} is offered in every project on {Q} that has no actions of its own"),
        |world, c, _| {
            add_project(world, "docs", json!([]))?;
            add_project(
                world,
                "tools",
                json!([script("Lint", "bun lint", false, "")]),
            )?;
            expect_offered(world, "shop", &[&c[0]])?;
            expect_offered(world, "docs", &[&c[0]])?;
            // A project with its own keeps them.
            expect_offered(world, "tools", &["Lint"])
        },
    );
    steps.step(&format!("{Q} has the default action {Q}"), |world, c, _| {
        let environment = world.mc.environment_id.clone();
        save_on(
            &mut world.mc,
            &environment,
            SCRIPTS,
            json!([script(&c[1], "bun dev", false, "")]),
        );
        Ok(())
    });

    // A project's own.
    steps.step(
        &format!("the user picks {Q} and adds the action {Q}"),
        |world, c, _| {
            open_actions(world, &c[0])?;
            add(world, &c[1], "bun storybook")
        },
    );
    steps.step(
        &format!("{Q} offers its own list with {Q} and {Q}"),
        |world, c, _| {
            let (project, wanted) = (c[0].clone(), vec![c[1].clone(), c[2].clone()]);
            world.wait_for_with(
                |w| {
                    names(&override_of(&held_all(w), &project)) == wanted && panel(w)["own"] == true
                },
                describe,
            )?;
            expect_offered(world, &c[0], &[&c[1], &c[2]])
        },
    );
    steps.step(
        &format!("other projects still offer only {Q}"),
        |world, c, _| {
            expect!(
                names(&held_all(world)[SCRIPTS]) == [c[0].clone()],
                "{}",
                describe(world)
            );
            add_project(world, "docs", json!([]))?;
            expect_offered(world, "docs", &[&c[0]])
        },
    );
    steps.step(&format!("{Q} has its own actions"), |world, c, _| {
        let environment = world.mc.environment_id.clone();
        save_on(&mut world.mc, &environment, SCRIPTS, dev());
        set_override(world, &c[0], json!([script("Lint", "bun lint", false, "")]));
        Ok(())
    });
    steps.step(
        &format!("the user resets the actions of {Q}"),
        |world, c, _| {
            open_actions(world, &c[0])?;
            world.wait_for_with(
                |w| panel(w)["own"] == true && names(&panel(w)["scripts"]) == ["Lint"],
                describe,
            )?;
            world.dispatch("projectActions.reset", Value::Null)
        },
    );
    steps.step(
        &format!("{Q} offers the default actions of {Q} again"),
        |world, c, _| {
            let project = c[0].clone();
            world.wait_for_with(
                |w| !has_override(&held_all(w), &project) && panel(w)["own"] != true,
                describe,
            )?;
            expect_offered(world, &c[0], &["Dev"])
        },
    );

    // What the list marks.
    steps.step(
        &format!("{Q} has the setup action {Q} and the action {Q} with a preview address"),
        |world, c, _| {
            set_override(
                world,
                &c[0],
                json!([
                    script(&c[1], "bun install", true, ""),
                    script(&c[2], "bun dev", false, "http://localhost:3000")
                ]),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user opens the Actions settings for {Q}"),
        |world, c, _| open_actions(world, &c[0]),
    );
    steps.step(
        &format!("{Q} is marked as the setup action"),
        |world, c, _| {
            let wanted = c[0].clone();
            world.wait_for_with(|w| names(&panel(w)["scripts"]).contains(&wanted), describe)?;
            let (visible, text) = mark(world, &c[0], "setup")?;
            expect!(visible && text == "setup", "{} has no setup mark", c[0]);
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is marked as having a preview on desktop only"),
        |world, c, _| {
            let (visible, text) = mark(world, &c[0], "preview")?;
            expect!(
                visible && text == "preview · desktop only",
                "{} has no preview mark",
                c[0]
            );
            // Only it, and only it is not the setup action.
            let (setup_visible, _) = mark(world, &c[0], "setup")?;
            expect!(!setup_visible, "{} is marked as the setup action", c[0]);
            Ok(())
        },
    );

    // hal-c2.json.
    steps.step(
        &format!("the checkout's hal-c2.json declares the action {Q}"),
        |world, c, _| {
            let file = json!({"scripts": [{"name": c[0], "command": "bun lint"}]});
            fake_files(&mut world.mc)
                .files
                .insert("hal-c2.json".into(), file.to_string());
            Ok(())
        },
    );
    steps.step(
        &format!("the user imports the actions of {Q} from hal-c2.json"),
        |world, c, _| {
            open_actions(world, &c[0])?;
            world.wait_for_with(|w| names(&panel(w)["imports"]) == ["Lint"], describe)?;
            world.dispatch("projectActions.import", json!({"name": "Lint"}))
        },
    );
    steps.step("the checkout's hal-c2.json is invalid", |world, _, _| {
        fake_files(&mut world.mc).files.insert(
            "hal-c2.json".into(),
            "{ \"scripts\": [ { \"name\": \"Lint\" ".into(),
        );
        Ok(())
    });

    // Several environments.
    steps.step("their default actions differ", |world, _, _| {
        let environment = world.mc.environment_id.clone();
        save_on(&mut world.mc, &environment, SCRIPTS, dev());
        let other = world.mc.members.first().cloned().unwrap_or_default();
        save_on(
            &mut world.mc,
            &other,
            SCRIPTS,
            json!([script("Test", "bun test", false, "")]),
        );
        Ok(())
    });
    steps.step("the user opens the Actions settings", |world, _, _| {
        world.wait_for_with(|w| panel(w)["settings"] == true, describe)
    });
    steps.step(
        "the user is told the environments have different actions",
        |world, _, _| {
            world.wait_for_with(|w| panel(w)["mixed"] == true, describe)?;
            let (visible, text) = drawn_text(world, "mixedActions")?;
            expect!(
                visible && text.starts_with("Different actions across environments."),
                "the page does not say the environments differ"
            );
            Ok(())
        },
    );

    // Saves that do not land.
    steps.step(
        "no connected environment can take the change",
        |world, _, _| {
            open_actions(world, "")?;
            world.mc.stop_accepting();
            world.mc.drop_connection();
            world.wait_for("the shell to see the drop", |w| !w.client_ready())?;
            world.wait_for_with(|w| panel(w)["available"] == false, describe)
        },
    );
    steps.step("the user adds a default action", |world, _, _| {
        if panel(world)["settings"] != true {
            open_actions(world, "")?;
        }
        add(world, "Dev", "bun dev")
    });
    steps.step(
        "the user is told the actions were not saved",
        |world, _, _| {
            expect_told(world, "Actions not saved")?;
            let writes = fake_config(&mut world.mc).writes.len();
            expect!(writes == 0, "{}", describe(world));
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} rejects the settings change"),
        |world, _, _| {
            fake_config(&mut world.mc).refuse_writes = "disk full".into();
            Ok(())
        },
    );
    steps.step(
        "the user is told the project actions failed to save",
        |world, _, _| {
            expect_told(world, "Failed to save project actions")?;
            expect!(
                held_all(world).get(SCRIPTS).is_none()
                    && names(&panel(world)["scripts"]).is_empty(),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    // An environment too old for project overrides.
    steps.step(
        &format!("{Q} runs a server without project overrides"),
        |world, c, _| {
            // The same repository on both, so "shop" is one project with two checkouts.
            let mut local = world
                .mc
                .projects
                .get("shop")
                .cloned()
                .unwrap_or(Value::Null);
            local["repositoryIdentity"] = json!({"canonicalKey": REPOSITORY, "name": "shop"});
            world.mc.projects.insert("shop".into(), local.clone());
            world.mc.send_row_of("shop", &local, "project");
            let fake = fake_config(&mut world.mc);
            fake.elsewhere.insert(
                c[0].clone(),
                with_capabilities(Map::new(), json!({ OVERRIDES: false })),
            );
            document_of(&mut world.mc, &c[0]);
            world.mc.join_named(&c[0]);
            let mut remote = local;
            remote["id"] = json!("shop-server");
            world
                .mc
                .send_peer_row_of(&c[0], "shop-server", &remote, "project");
            world.sync()
        },
    );
    steps.step(
        &format!("the user picks {Q} in the Actions settings"),
        |world, c, _| {
            open_actions(world, &c[0])?;
            world.wait_for_with(
                |w| {
                    SettingsScope::of(w.engine()).targets().len() == 2
                        && SettingsScope::of(w.engine()).settings(SERVER).is_some()
                },
                |w| {
                    format!(
                        "both checkouts in the scope; it is {}",
                        show(&scope_state(w))
                    )
                },
            )
        },
    );
    steps.step(
        "changes apply only to environments that support project overrides",
        |world, _, _| {
            add(world, "Dev", "bun dev")?;
            world.wait_for_with(
                |w| names(&override_of(&held_all(w), "shop")) == ["Dev"],
                describe,
            )?;
            world.sync()?;
            let server = document_of(&mut world.mc, SERVER);
            expect!(
                server.version == 0 && server.settings.is_empty(),
                "{SERVER} was written {}",
                show(&Value::Object(server.settings.clone()))
            );
            expect!(
                !told(world, "Failed to save project actions"),
                "a failure was reported: {}",
                show(&world.state("toasts"))
            );
            Ok(())
        },
    );
}

fn mark(world: &mut World, action: &str, name: &str) -> Outcome<(bool, String)> {
    let brick = settings_shell(world, 900.0, 2000.0)?;
    let row = brick.item(world, &format!("action:{}", action.to_lowercase()))?;
    let Some(tag) = brick.find_under(world, row, name)? else {
        fail!("{action} has no {name} mark");
    };
    Ok((
        brick.flag(world, tag, "visible"),
        brick.text_of(world, tag, "text"),
    ))
}
