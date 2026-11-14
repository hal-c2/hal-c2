//! The composer's suggestion menus (features/composer/context-references.feature):
//! the files, skills and commands a trigger character offers, what choosing
//! one puts in the draft, and the keys that walk, take and dismiss them. The
//! provider's skills and commands come from the MC's provider snapshot; the
//! files from its workspace search (FakeFiles). desktop-qt's
//! ContextReferenceSteps.cpp.

use hal_c2_shell::composer_model;
use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::workspace;
use ljos::prelude::ObjectId;
use serde_json::{Value, json};

use crate::brick::Brick;
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::{
    composer_brick, composer_brick_shown, composer_item, composer_part, press_in_composer,
    settle_composer, type_in_composer,
};
use crate::steps::composer_picker::model_picker_shown_open;
use crate::steps::fake_files::fake_files;
use crate::steps::settings::{fake_config, publish_providers};
use crate::steps::stream::THREAD;
use crate::steps::turn::open_turn_thread;
use crate::world::World;
use crate::{expect, fail};

/// The provider's skills and commands as the scenario has them, the text
/// the user typed before acting on the menu, and the suggestion last
/// found offered ("the user chooses it").
#[derive(Default)]
struct References {
    skills: Vec<Value>,
    commands: Vec<Value>,
    /// The skills the provider reports in each folder, once read.
    folder_skills: Vec<(String, Vec<Value>)>,
    /// What the MC has read of them (`workspaceSnapshots`).
    snapshots: Vec<Value>,
    published: bool,
    typed: String,
    offered: String,
}

fn refs(world: &mut World) -> &mut References {
    world.mc.part::<References>()
}

fn composer_state(world: &World) -> Value {
    world.state("composer")
}

fn draft_text(world: &World) -> String {
    text(&composer_state(world)["text"])
}

fn offered(world: &World) -> Vec<Value> {
    composer_state(world)["suggestions"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn kind_of(item: &Value) -> String {
    text(&item["kind"])
}

fn label_of(item: &Value) -> String {
    text(&item["label"])
}

fn id_of(item: &Value) -> String {
    text(&item["id"])
}

/// What a suggestion names: a skill's or command's name, a path, or a
/// built-in command's word.
fn name_of(item: &Value) -> String {
    let id = id_of(item);
    if let Some(rest) = id.strip_prefix("slash:") {
        return rest.to_owned();
    }
    id.split(':').skip(2).collect::<Vec<_>>().join(":")
}

fn describe_menu(world: &World) -> String {
    let state = composer_state(world);
    format!(
        "the draft reads \"{}\", the menu is {} with {} (empty text {})",
        text(&state["text"]),
        show(&state["triggerKind"]),
        show(&state["suggestions"]),
        show(&state["suggestionsEmptyText"])
    )
}

fn quoted_in(text: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut rest = text;
    while let Some(open) = rest.find('"') {
        rest = &rest[open + 1..];
        match rest.find('"') {
            Some(close) => {
                found.push(rest[..close].to_owned());
                rest = &rest[close + 1..];
            }
            None => break,
        }
    }
    found
}

/// The thread's provider, with the scenario's skills and commands.
fn announce(mc: &mut FakeMc) {
    let (skills, commands, snapshots) = {
        let r = mc.part::<References>();
        r.published = true;
        (r.skills.clone(), r.commands.clone(), r.snapshots.clone())
    };
    publish_providers(
        mc,
        vec![json!({
            "instanceId": "codex", "driver": "codex", "displayName": "Codex",
            "enabled": true, "installed": true, "status": "ready",
            "models": [{"slug": "gpt-5", "name": "GPT-5"}],
            "slashCommands": commands, "skills": skills,
            "workspaceSnapshots": snapshots,
        })],
    );
    // The open thread runs on it, as every thread the MC holds names a model.
    if let Some(row) = mc.threads.get(THREAD)
        && row.get("modelSelection").is_none()
    {
        let mut row = row.clone();
        row["modelSelection"] = json!({"instanceId": "codex", "model": "gpt-5"});
        mc.threads.insert(THREAD.into(), row.clone());
        mc.send_row(THREAD, &row);
    }
}

fn publish(world: &mut World) -> Outcome {
    announce(&mut world.mc);
    world.sync()
}

/// The MC reads a folder's skills when asked for it and announces them with
/// the providers (`server.refreshProviders` with a `cwd`).
fn read_folders_when_asked(mc: &mut FakeMc) {
    mc.on_rpc("server.refreshProviders", |mc, rpc| {
        let cwd = text(&rpc.payload["cwd"]);
        let r = mc.part::<References>();
        if let Some((_, skills)) = r.folder_skills.iter().find(|(folder, _)| *folder == cwd) {
            let snapshot = json!({"cwd": cwd, "skills": skills, "slashCommands": []});
            r.snapshots.push(snapshot);
            announce(mc);
        }
        let providers = fake_config(mc)
            .config
            .get("providers")
            .cloned()
            .unwrap_or(Value::Null);
        mc.reply(rpc, json!({"providers": providers}));
        Ok(())
    });
}

fn ensure_provider(world: &mut World) -> Outcome {
    if refs(world).published {
        Ok(())
    } else {
        publish(world)
    }
}

fn add_skill(world: &mut World, name: &str, more: Value) {
    let mut skill = json!({"name": name, "enabled": true});
    if let (Some(into), Some(extra)) = (skill.as_object_mut(), more.as_object()) {
        for (key, value) in extra {
            into.insert(key.clone(), value.clone());
        }
    }
    refs(world).skills.push(skill);
}

fn add_command(world: &mut World, name: &str) {
    refs(world)
        .commands
        .push(json!({"name": name, "description": format!("Run {name}")}));
}

fn target(world: &World) -> String {
    world
        .with::<Navigation, _>(|n, _| n.thread_key().to_owned())
        .unwrap_or_default()
}

/// The user types `text` into the draft (the composer's debounced edit,
/// as the brick dispatches it); with the composer on screen its editor
/// follows.
fn type_text(world: &mut World, typed: &str) -> Outcome {
    refs(world).typed = typed.to_owned();
    let target = target(world);
    let revision = world.next_edit;
    world.next_edit += 1;
    world.dispatch(
        "composer.text.set",
        json!({
            "target": target,
            "edit": {"clientId": "qml", "revision": revision},
            "text": typed,
            "cursor": typed.chars().count(),
        }),
    )?;
    world.sync()?;
    if composer_brick_shown(world) {
        settle_composer(world)?;
    }
    Ok(())
}

/// Types `text` key by key into the composer on screen.
fn type_on_screen(world: &mut World, typed: &str) -> Outcome {
    composer_brick(world)?;
    refs(world).typed = typed.to_owned();
    type_in_composer(world, typed)?;
    settle_composer(world)
}

fn wait_for_menu(world: &mut World, done: impl Fn(&[Value]) -> bool, what: &str) -> Outcome {
    let what = what.to_owned();
    world.wait_for_with(
        |w| done(&offered(w)),
        move |w| format!("{}; {}", what, describe_menu(w)),
    )
}

/// The menu has answered the text typed: its suggestions, or why it has none.
fn wait_for_answer(world: &mut World) -> Outcome {
    world.sync()?;
    world.wait_for_with(
        |w| {
            let state = composer_state(w);
            state["triggerKind"].is_null()
                || !offered(w).is_empty()
                || !state["suggestionsEmptyText"].is_null()
        },
        |w| format!("the menu to answer; {}", describe_menu(w)),
    )
}

/// The first suggestion that `matches`; remembered for "the user chooses it".
fn wait_for_offered(
    world: &mut World,
    matches: impl Fn(&Value) -> bool,
    what: &str,
) -> Outcome<Value> {
    let mut found = Value::Null;
    {
        let found = &mut found;
        let what = what.to_owned();
        world.wait_for_with(
            |w| {
                for item in offered(w) {
                    if matches(&item) {
                        *found = item;
                        return true;
                    }
                }
                false
            },
            move |w| format!("{}; {}", what, describe_menu(w)),
        )?;
    }
    refs(world).offered = id_of(&found);
    Ok(found)
}

fn choose(world: &mut World, id: &str) -> Outcome {
    world.dispatch("composer.suggest.select", json!({"id": id}))?;
    world.sync()?;
    if composer_brick_shown(world) {
        settle_composer(world)?;
    }
    Ok(())
}

/// Whether `query`'s letters appear in `value` in order.
fn in_order(value: &str, query: &str) -> bool {
    let value = value.to_lowercase();
    let mut rest = value.as_str();
    for c in query.to_lowercase().chars() {
        match rest.find(c) {
            Some(at) => rest = &rest[at + c.len_utf8()..],
            None => return false,
        }
    }
    true
}

fn suggestion_list(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    let brick = composer_brick(world)?;
    match composer_part(world, "suggestionList")? {
        Some(list) => Ok((brick, list)),
        None => fail!("the composer has no suggestion list"),
    }
}

fn highlighted(world: &mut World) -> Outcome<i64> {
    let (brick, list) = suggestion_list(world)?;
    Ok(brick.read(world, list, "currentIndex").to_number() as i64)
}

/// The composer on screen offers suggestions for `text`, typed key by key.
fn offered_on_screen(world: &mut World, typed: &str, count: i64) -> Outcome {
    open_turn_thread(world)?;
    type_on_screen(world, typed)?;
    wait_for_menu(
        world,
        |items| (count < 0 && !items.is_empty()) || items.len() as i64 == count,
        &format!("suggestions for \"{typed}\""),
    )?;
    let (brick, list) = suggestion_list(world)?;
    world.wait_for("the suggestion list to show the suggestions", |w| {
        brick.read(w, list, "count").to_number() as usize == offered(w).len()
    })
}

fn expect_interaction_mode(world: &mut World, mode: &str) -> Outcome {
    let mode = mode.to_owned();
    world.wait_for_with(
        move |w| composer_state(w)["interactionMode"] == json!(mode),
        move |w| {
            format!(
                "the thread to be in {} mode; the composer shows {}",
                composer_state(w)["interactionMode"],
                show(&composer_state(w))
            )
        },
    )
}

pub fn register(steps: &mut Steps) {
    let list = "(\"[^\"]*\"(?:(?:, | and )\"[^\"]*\")*)";

    steps.step(
        &format!("the provider reports different skills for {Q} and for {Q}"),
        |world, c, _| {
            for folder in [&c[0], &c[1]] {
                let seg = folder.rsplit('/').next().unwrap_or_default();
                let skill = json!({"name": format!("{seg}-deploy"), "enabled": true});
                refs(world)
                    .folder_skills
                    .push((folder.clone(), vec![skill]));
            }
            read_folders_when_asked(&mut world.mc);
            publish(world)
        },
    );
    steps.step(
        &format!("the user types {Q} in a thread working in {Q}"),
        |world, c, _| {
            open_turn_thread(world)?;
            let mut row = world.mc.threads[THREAD].clone();
            row["worktreePath"] = json!(c[1]);
            world.mc.threads.insert(THREAD.into(), row.clone());
            world.mc.send_row(THREAD, &row);
            let cwd = c[1].clone();
            world.wait_for(&format!("the thread to work in {cwd}"), |w| {
                workspace::place(w.engine()).is_some_and(|place| place.cwd() == cwd)
            })?;
            type_text(world, &c[0])
        },
    );
    steps.step(
        &format!("only the skills reported for {Q} are offered"),
        |world, c, _| {
            let seg = c[0].rsplit('/').next().unwrap_or_default();
            let wanted = format!("{seg}-deploy");
            wait_for_menu(
                world,
                |items| {
                    items.len() == 1
                        && kind_of(&items[0]) == "skill"
                        && name_of(&items[0]) == wanted
                },
                &format!("only \"{wanted}\" to be offered"),
            )
        },
    );

    // The workspace and the provider.
    steps.step(
        &format!("the project has the files? {list}"),
        |world, c, _| {
            for path in quoted_in(&c[0]) {
                fake_files(&mut world.mc).files.insert(path, String::new());
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the provider offers the skills? {list}"),
        |world, c, _| {
            for name in quoted_in(&c[0]) {
                add_skill(world, &name, json!({}));
            }
            publish(world)
        },
    );
    steps.step(
        &format!("the provider offers the commands? {list}"),
        |world, c, _| {
            for name in quoted_in(&c[0]) {
                add_command(world, &name);
            }
            publish(world)
        },
    );
    steps.step(
        &format!("the provider offers the commands {list} and the skill {Q}"),
        |world, c, _| {
            for name in quoted_in(&c[0]) {
                add_command(world, &name);
            }
            add_skill(world, &c[1], json!({}));
            publish(world)
        },
    );
    steps.step(
        &format!("the provider offers the skill {Q} and also a command {Q}"),
        |world, c, _| {
            add_skill(world, &c[0], json!({}));
            add_command(world, &c[1]);
            publish(world)
        },
    );
    // A command and a skill whose names start with the word and are as
    // long as the built-in's (a longer name ranks lower).
    steps.step(
        &format!(
            "the provider offers a command and a skill that both match {Q} as well as {Q} does"
        ),
        |world, c, _| {
            let word = c[0].strip_prefix('/').unwrap_or(&c[0]).to_owned();
            let built_in = c[1].strip_prefix('/').unwrap_or(&c[1]).to_owned();
            expect!(
                built_in.starts_with(&word) && built_in.len() > word.len(),
                "\"{built_in}\" does not start with \"{word}\""
            );
            let pad = built_in.len() - word.len();
            add_command(world, &format!("{word}{}", "x".repeat(pad)));
            add_skill(world, &format!("{word}{}", "y".repeat(pad)), json!({}));
            publish(world)
        },
    );
    steps.step(
        &format!("the provider reports the skill {Q} from two places and a skill {Q} the user may not run"),
        |world, c, _| {
            add_skill(
                world,
                &c[0],
                json!({"scope": "repo", "path": "/work/shop/.codex/skills/review"}),
            );
            add_skill(
                world,
                &c[0],
                json!({"scope": "user", "path": "/home/sam/.codex/skills/review"}),
            );
            add_skill(world, &c[1], json!({"userInvocable": false}));
            publish(world)
        },
    );
    steps.step(
        &format!("the provider offers the skill {Q} with no display name"),
        |world, c, _| {
            add_skill(world, &c[0], json!({}));
            publish(world)
        },
    );
    steps.step(
        &format!("the provider offers the skill {Q} described as {Q}"),
        |world, c, _| {
            add_skill(world, &c[0], json!({"description": c[1]}));
            publish(world)
        },
    );
    steps.step(
        &format!("the provider offers a skill described as {Q}"),
        |world, c, _| {
            add_skill(world, "release-notes", json!({"description": c[0]}));
            publish(world)
        },
    );
    steps.step("skills are shown in the slash menu", |world, _, _| {
        let engine = world.engine().clone();
        Settings::of(&engine).set(&engine, "showSkillsInSlashMenu", json!(true));
        expect!(
            Settings::of(&engine).setting(&engine, "showSkillsInSlashMenu") == Some(json!(true)),
            "skills are not shown in the slash menu"
        );
        Ok(())
    });
    steps.step("the Build and Plan toggle setting is on", |world, _, _| {
        ensure_provider(world)?;
        let engine = world.engine().clone();
        let written = Settings::of(&engine).write_device(&engine, "planModeEnabled", json!(true));
        expect!(written, "plan mode could not be turned on");
        world.sync()
    });
    steps.step("the thread is (building|planning)", |world, c, _| {
        let mode = if c[0] == "planning" {
            "plan"
        } else {
            "default"
        };
        world.dispatch("composer.interactionMode.set", json!({"mode": mode}))?;
        expect_interaction_mode(world, mode)
    });

    // Typing.
    steps.step(
        &format!(
            "the user types {Q} and (no skill matches|no file or folder matches|no command matches)"
        ),
        |world, c, _| {
            ensure_provider(world)?;
            fake_files(&mut world.mc);
            type_text(world, &c[0])
        },
    );
    steps.step(
        &format!("the user types {Q} and the files have not come back yet"),
        |world, c, _| {
            fake_files(&mut world.mc)
                .files
                .insert("src/cart.ts".into(), String::new());
            world.mc.hold("search");
            type_text(world, &c[0])
        },
    );
    steps.step(
        &format!("the user types {Q} and chooses {Q}"),
        |world, c, _| {
            type_text(world, &c[0])?;
            let wanted = c[1].clone();
            let found = wait_for_offered(
                world,
                |item| name_of(item) == wanted,
                &format!("\"{}\" to be offered", c[1]),
            )?;
            choose(world, &id_of(&found))
        },
    );
    steps.step(
        "the environment of the open thread is unreachable",
        |world, _, _| {
            fake_files(&mut world.mc);
            let environment = world.mc.environment_id.clone();
            world.mc.set_online(&environment, false);
            world.sync()
        },
    );
    steps.step(
        "the environment of the open thread is reachable again",
        |world, _, _| {
            let environment = world.mc.environment_id.clone();
            world.mc.set_online(&environment, true);
            world.sync()
        },
    );

    // What the menu offers.
    steps.step(
        &format!("the user is offered (files and folders|skills|commands) matching {Q}"),
        |world, c, _| {
            let what = c[0].clone();
            let query = c[1].clone();
            let kinds: &[&str] = match what.as_str() {
                "skills" => &["skill"],
                "commands" => &["slash-command", "provider-slash-command"],
                _ => &["path"],
            };
            wait_for_menu(
                world,
                |items| !items.is_empty(),
                &format!("{what} to be offered"),
            )?;
            for item in offered(world) {
                expect!(
                    kinds.contains(&kind_of(&item).as_str()),
                    "not only {what} are offered: {}",
                    describe_menu(world)
                );
                let name = name_of(&item);
                // A skill or command may match by its description as well.
                let matches = if what == "files and folders" {
                    name.to_lowercase().contains(&query.to_lowercase())
                } else {
                    in_order(&name, &query)
                        || text(&item["description"])
                            .to_lowercase()
                            .contains(&query.to_lowercase())
                };
                expect!(
                    matches,
                    "{name} does not match \"{query}\": {}",
                    describe_menu(world)
                );
            }
            if what == "files and folders" {
                let mut found: Vec<String> = offered(world)
                    .iter()
                    .map(|item| id_of(item).split(':').nth(1).unwrap_or_default().to_owned())
                    .collect();
                found.sort();
                found.dedup();
                expect!(
                    found.iter().any(|f| f == "file") && found.iter().any(|f| f == "directory"),
                    "not both files and folders: {}",
                    describe_menu(world)
                );
            }
            Ok(())
        },
    );
    steps.step("the user is offered suggestions", |world, _, _| {
        fake_files(&mut world.mc)
            .files
            .insert("README.md".into(), String::new());
        offered_on_screen(world, "@rea", -1)
    });
    steps.step(
        &format!("the user typed {Q} and suggestions are offered"),
        |world, c, _| {
            fake_files(&mut world.mc)
                .files
                .insert("README.md".into(), String::new());
            offered_on_screen(world, &c[0], -1)
        },
    );
    steps.step(
        &format!("the user typed {Q} and three files are offered"),
        |world, c, _| {
            for path in ["search.ts", "shop.ts", "style.css"] {
                fake_files(&mut world.mc)
                    .files
                    .insert(path.into(), String::new());
            }
            offered_on_screen(world, &c[0], 3)
        },
    );
    steps.step(
        &format!("the user typed {Q} and {Q} is highlighted"),
        |world, c, _| {
            fake_files(&mut world.mc)
                .files
                .insert(c[1].clone(), String::new());
            offered_on_screen(world, &c[0], -1)?;
            let (brick, list) = suggestion_list(world)?;
            let wanted = c[1].clone();
            world.wait_for_with(
                move |w| {
                    let at = brick.read(w, list, "currentIndex").to_number() as usize;
                    offered(w)
                        .get(at)
                        .is_some_and(|item| label_of(item) == wanted)
                },
                move |w| format!("\"{}\" to be highlighted; of {}", c[1], describe_menu(w)),
            )
        },
    );
    steps.step(
        &format!("the provider command {Q} is offered"),
        |world, c, _| {
            let wanted = c[0].clone();
            wait_for_offered(
                world,
                |item| kind_of(item) == "provider-slash-command" && name_of(item) == wanted,
                &format!("the provider command \"{}\" to be offered", c[0]),
            )?;
            Ok(())
        },
    );
    steps.step("no provider command is offered", |world, _, _| {
        // Mid-sentence the menu may not open at all.
        wait_for_answer(world)?;
        for item in offered(world) {
            expect!(
                kind_of(&item) != "provider-slash-command",
                "a provider command is offered: {}",
                describe_menu(world)
            );
        }
        Ok(())
    });
    steps.step("a built-in command or skill is offered", |world, _, _| {
        wait_for_offered(
            world,
            |item| kind_of(item) == "skill" || id_of(item).starts_with("slash:"),
            "a built-in command or skill to be offered",
        )?;
        Ok(())
    });
    steps.step("the built-in model command is offered", |world, _, _| {
        wait_for_offered(
            world,
            |item| id_of(item) == "slash:model",
            "/model to be offered",
        )?;
        Ok(())
    });
    steps.step(&format!("the skill {Q} is offered"), |world, c, _| {
        let wanted = c[0].clone();
        wait_for_offered(
            world,
            |item| kind_of(item) == "skill" && name_of(item) == wanted,
            &format!("the skill \"{}\" to be offered", c[0]),
        )?;
        Ok(())
    });
    steps.step(&format!("the suggestion {Q} is offered"), |world, c, _| {
        let wanted = c[0].clone();
        wait_for_offered(
            world,
            |item| label_of(item) == wanted,
            &format!("\"{}\" to be offered", c[0]),
        )?;
        Ok(())
    });
    steps.step(&format!("the skill {Q} is offered once"), |world, c, _| {
        let wanted = c[0].clone();
        wait_for_offered(
            world,
            |item| name_of(item) == wanted,
            &format!("the skill \"{}\" to be offered", c[0]),
        )?;
        let count = offered(world)
            .iter()
            .filter(|item| name_of(item) == c[0])
            .count();
        expect!(
            count == 1,
            "\"{}\" is offered {count} times: {}",
            c[0],
            describe_menu(world)
        );
        Ok(())
    });
    steps.step(&format!("the skill {Q} is not offered"), |world, c, _| {
        wait_for_answer(world)?;
        for item in offered(world) {
            expect!(
                name_of(&item) != c[0],
                "\"{}\" is offered: {}",
                c[0],
                describe_menu(world)
            );
        }
        Ok(())
    });
    steps.step(
        &format!("{Q} is offered once, as the skill"),
        |world, c, _| {
            let wanted = c[0].clone();
            wait_for_offered(
                world,
                |item| name_of(item) == wanted,
                &format!("\"{}\" to be offered", c[0]),
            )?;
            let kinds: Vec<String> = offered(world)
                .iter()
                .filter(|item| name_of(item) == c[0])
                .map(kind_of)
                .collect();
            expect!(
                kinds == ["skill"],
                "\"{}\" is offered as {}",
                c[0],
                kinds.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is offered first, then {Q}, then {Q} and {Q}"),
        |world, c, _| {
            wait_for_menu(world, |items| items.len() >= 4, "four suggestions")?;
            let names: Vec<String> = offered(world).iter().map(name_of).collect();
            let ordered = names.len() == 4
                && names[0] == c[0]
                && names[1] == c[1]
                && [names[2].as_str(), names[3].as_str()]
                    .iter()
                    .all(|n| *n == c[2] || *n == c[3]);
            expect!(ordered, "the menu offers {}", names.join(", "));
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is offered before the provider command, and the skill last"),
        |world, c, _| {
            wait_for_menu(world, |items| items.len() >= 3, "three suggestions")?;
            let items = offered(world);
            let (mut built_in, mut command, mut skill) = (-1i64, -1i64, -1i64);
            for (i, item) in items.iter().enumerate() {
                if label_of(item) == c[0] && built_in < 0 {
                    built_in = i as i64;
                }
                if kind_of(item) == "provider-slash-command" && command < 0 {
                    command = i as i64;
                }
                if kind_of(item) == "skill" {
                    skill = i as i64;
                }
            }
            expect!(
                built_in >= 0 && command > built_in && skill > command && skill == command + 1,
                "the menu offers {}",
                describe_menu(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("the skill is shown as {Q}"), |world, c, _| {
        let wanted = c[0].clone();
        wait_for_offered(
            world,
            |item| kind_of(item) == "skill" && label_of(item) == wanted,
            &format!("a skill shown as \"{}\"", c[0]),
        )?;
        Ok(())
    });
    steps.step(
        "no slash command or skill suggestions are offered",
        |world, _, _| {
            world.sync()?;
            let kind = text(&composer_state(world)["triggerKind"]);
            expect!(
                kind != "slash-command" && kind != "skill",
                "a menu is open: {}",
                describe_menu(world)
            );
            expect!(offered(world).is_empty(), "{}", describe_menu(world));
            Ok(())
        },
    );
    steps.step("no skill menu opens", |world, _, _| {
        world.sync()?;
        expect!(
            text(&composer_state(world)["triggerKind"]) != "skill",
            "the skill menu is open: {}",
            describe_menu(world)
        );
        Ok(())
    });
    steps.step("the skill menu opens", |world, _, _| {
        wait_for_answer(world)?;
        let state = composer_state(world);
        expect!(
            state["triggerKind"] == json!("skill")
                && (!offered(world).is_empty() || !state["suggestionsEmptyText"].is_null()),
            "no skill menu: {}",
            describe_menu(world)
        );
        Ok(())
    });

    // Choosing and dismissing.
    steps.step(
        &format!("the user chooses {Q} from the suggestions"),
        |world, c, _| {
            let wanted = c[0].clone();
            let found = wait_for_offered(
                world,
                |item| label_of(item) == wanted,
                &format!("\"{}\" to be offered", c[0]),
            )?;
            choose(world, &id_of(&found))
        },
    );
    steps.step("the user chooses it", |world, _, _| {
        // The model picker's provider-setup offer is chosen in the same words.
        if composer_brick_shown(world)
            && let Some(setup) = composer_part(world, "modelPickerSetup")?
        {
            let brick = composer_brick(world)?;
            if brick.flag(world, setup, "visible") {
                let (x, y) = brick.at(world, setup, 0.5, 0.5)?;
                world.click_at(x, y)?;
                return world.sync();
            }
        }
        let offered = refs(world).offered.clone();
        expect!(!offered.is_empty(), "nothing was offered to choose");
        choose(world, &offered)
    });
    steps.step(
        &format!("the user chooses the built-in command {Q}"),
        |world, c, _| {
            composer_brick(world)?;
            type_text(world, &c[0])?;
            let id = format!("slash:{}", c[0].strip_prefix('/').unwrap_or(&c[0]));
            let wanted = id.clone();
            wait_for_offered(
                world,
                |item| id_of(item) == wanted,
                &format!("{} to be offered", c[0]),
            )?;
            choose(world, &id)
        },
    );
    steps.step(
        "the user dismisses (?:them with Escape|the suggestions)",
        |world, _, _| {
            let took = press_in_composer(world, "Escape")?;
            expect!(took, "the composer is not on screen");
            settle_composer(world)
        },
    );
    steps.step(
        "the user presses Up on the first suggestion",
        |world, _, _| {
            let at = highlighted(world)?;
            expect!(at == 0, "row {at} is highlighted");
            press_in_composer(world, "Up")?;
            Ok(())
        },
    );

    // What the draft holds.
    steps.step(
        "the (first|last) suggestion is highlighted",
        |world, c, _| {
            let (brick, list) = suggestion_list(world)?;
            let count = brick.read(world, list, "count").to_number() as i64;
            let at = brick.read(world, list, "currentIndex").to_number() as i64;
            let expected = if c[0] == "first" { 0 } else { count - 1 };
            expect!(
                count > 1 && at == expected,
                "row {at} of {count} is highlighted"
            );
            Ok(())
        },
    );
    steps.step(&format!("the draft references {Q}"), |world, c, _| {
        settle_composer(world)?;
        let link = composer_model::path_link(&c[0]).trim().to_owned();
        let wanted = link.clone();
        world.wait_for_with(
            move |w| draft_text(w).contains(&wanted),
            move |w| format!("the draft to hold {link}; it reads \"{}\"", draft_text(w)),
        )
    });
    steps.step(
        &format!("the draft references the skill {Q}"),
        |world, c, _| {
            settle_composer(world)?;
            let skill = format!("${} ", c[0]);
            let wanted = skill.clone();
            world.wait_for_with(
                move |w| draft_text(w).contains(&wanted),
                move |w| format!("the draft to hold {skill}; it reads \"{}\"", draft_text(w)),
            )
        },
    );
    steps.step(
        &format!("the draft reads {Q} followed by the skill {Q}"),
        |world, c, _| {
            settle_composer(world)?;
            let expected = format!("{}${} ", c[0], c[1]);
            let wanted = expected.clone();
            world.wait_for_with(
                move |w| draft_text(w) == wanted,
                move |w| {
                    format!(
                        "the draft to read \"{expected}\"; it reads \"{}\"",
                        draft_text(w)
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the draft reads {Q} with the caret after the space"),
        |world, c, _| {
            world.sync()?;
            let state = composer_state(world);
            expect!(
                state["text"] == json!(c[0])
                    && state["cursor"].as_i64() == Some(c[0].chars().count() as i64)
                    && c[0].ends_with(' '),
                "the draft reads \"{}\" with the caret at {}",
                text(&state["text"]),
                state["cursor"]
            );
            Ok(())
        },
    );
    steps.step("no suggestion is inserted", |world, _, _| {
        settle_composer(world)?;
        let typed = refs(world).typed.clone();
        let brick = composer_brick(world)?;
        let item = composer_item(world)?;
        expect!(
            draft_text(world) == typed && !brick.flag(world, item, "suggesting"),
            "after Escape {}",
            describe_menu(world)
        );
        Ok(())
    });
    steps.step(&format!("{Q} is removed from the draft"), |world, c, _| {
        settle_composer(world)?;
        expect!(
            !draft_text(world).contains(c[0].as_str()),
            "the draft reads \"{}\"",
            draft_text(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the next letter the user types follows {Q}"),
        |world, c, _| {
            type_in_composer(world, "d")?;
            settle_composer(world)?;
            let typed = refs(world).typed.clone();
            let expected = format!("{typed}d");
            expect!(
                typed.ends_with(c[0].as_str()) && draft_text(world) == expected,
                "the draft reads \"{}\"",
                draft_text(world)
            );
            Ok(())
        },
    );

    // What the built-in commands do.
    steps.step("the thread switches to planning", |world, _, _| {
        expect_interaction_mode(world, "plan")
    });
    steps.step("the thread switches back to building", |world, _, _| {
        expect_interaction_mode(world, "default")
    });
    steps.step("the user is asked to choose a model", |world, _, _| {
        let opened = model_picker_shown_open(world)?;
        expect!(opened, "the model picker to open");
        Ok(())
    });

    // Sending.
    steps.step(
        &format!("pressing Enter sends the draft with {Q} as typed"),
        |world, c, _| {
            composer_brick(world)?;
            settle_composer(world)?;
            let took = press_in_composer(world, "Enter")?;
            expect!(took, "the composer is not on screen");
            world.wait_for_with(
                |w| {
                    w.mc.commands
                        .iter()
                        .any(|command| command["type"] == json!("message.dispatch"))
                },
                |w| format!("a message to be sent; the MC has {}", w.describe_commands()),
            )?;
            let mut sent = String::new();
            for command in &world.mc.commands {
                if command["type"] == json!("message.dispatch") {
                    sent = text(&command["text"]);
                }
            }
            expect!(sent == c[0], "the agent received \"{sent}\"");
            Ok(())
        },
    );
}
