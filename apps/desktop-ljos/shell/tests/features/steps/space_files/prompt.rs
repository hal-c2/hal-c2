//! The page's prompt (features/space/prompt.feature): desktop-qt's
//! SpaceSteps.cpp "The page's prompt", the timeline's Composer aimed at the
//! page.

use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::palette::Palette;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::space::ASK_AGENT;
use ljos::item::{KeyEvent, Modifiers};
use ljos::prelude::{Engine, ObjectId, Value as Qml};
use serde_json::{Value, json};

use crate::brick::{self, Brick};
use crate::harness::{Failure, Outcome, Q, Steps, show, text};
use crate::steps::fake_files::fake_files;
use crate::steps::keybinding::{bind_key, describe_key_press, key_ran, press_key};
use crate::steps::settings::publish_providers;
use crate::steps::space::{
    current, expect_agent, find_page, given_page, id_of_page, id_of_space, look_at_page,
    thread_named, with_space,
};
use crate::steps::space_fake as fake;
use crate::world::World;
use crate::{expect, fail};

/// What the scenario chose in a page's prompt, to find in the ask.
#[derive(Default)]
struct PromptChoice {
    offered: bool,
    model: String,
}

const PROMPT_PAGE: &str = "import QtQuick\nimport HalC2.Bricks\nSpacePage { objectName: \"spacePromptPage\"; width: 900; height: 700 }\n";

/// A 1x1 PNG, and the start of a PDF, as a picker hands them over.
const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
const PDF: &str = "JVBERi0xLjQK";

/// A provider with models that have an effort, and the skill "review".
fn prompt_provider(id: &str, name: &str, models: &[&str]) -> Value {
    let effort = json!({
        "id": "reasoningEffort",
        "label": "Reasoning",
        "type": "select",
        "options": (["low", "medium", "high"].iter().map(|l| json!({"id": l, "label": l})).collect::<Vec<_>>()),
        "currentValue": "medium",
    });
    json!({
        "instanceId": id,
        "driver": id,
        "displayName": name,
        "enabled": true,
        "installed": true,
        "status": "ready",
        "models": (models
            .iter()
            .map(|slug| json!({"slug": slug, "name": slug, "capabilities": {"optionDescriptors": [effort.clone()]}}))
            .collect::<Vec<_>>()),
        "skills": [{"name": "review", "description": "Review the changes", "enabled": true}],
    })
}

fn prompt(world: &World) -> Value {
    world.state("composer")
}

/// The MC's Codex and Claude, and its threads each on a model: the user's
/// last on Claude's second.
fn offer_models(world: &mut World) -> Outcome {
    if std::mem::replace(&mut world.mc.part::<PromptChoice>().offered, true) {
        return Ok(());
    }
    let ids: Vec<String> = world.mc.threads.keys().cloned().collect();
    for id in ids {
        let Some(thread) = world.mc.threads.get_mut(&id) else {
            continue;
        };
        if thread.get("modelSelection").is_some() {
            continue;
        }
        thread["modelSelection"] = json!({"instanceId": "claudeAgent", "model": "claude-sonnet"});
        let row = thread.clone();
        world.mc.send_row(&id, &row);
    }
    publish_providers(
        &mut world.mc,
        vec![
            prompt_provider("codex", "Codex", &["gpt-5", "gpt-5-codex"]),
            prompt_provider("claudeAgent", "Claude", &["claude-opus", "claude-sonnet"]),
        ],
    );
    world.wait_for("the picker to list Codex and Claude", |w| {
        w.state("modelPicker")["instances"]
            .as_array()
            .is_some_and(|i| i.len() == 2)
    })
}

/// The project `id` on this MC, with no thread of its own.
fn have_project(world: &mut World, id: &str) -> Outcome {
    if world.mc.projects.contains_key(id) {
        return Ok(());
    }
    let row = json!({"id": id, "title": id, "workspaceRoot": format!("/work/{id}"), "scripts": []});
    world.mc.projects.insert(id.to_owned(), row.clone());
    world.mc.send_row_of(id, &row, "project");
    world.sync()
}

/// The brick on screen and its `spaceComposer`, when it shows one.
fn composer_shown(world: &World) -> Option<(Brick, ObjectId)> {
    let brick = world.peek_part::<brick::Shown>()?.0?;
    let composer = brick.find_visible(world, "spaceComposer").ok()??;
    Some((brick, composer))
}

fn editor_of(world: &World, brick: Brick, composer: ObjectId) -> Outcome<ObjectId> {
    match brick.find_under(world, composer, "input")? {
        Some(editor) => Ok(editor),
        None => fail!("the page's prompt has no editor"),
    }
}

fn editor_text(world: &World) -> String {
    composer_shown(world)
        .and_then(|(brick, composer)| {
            let editor = brick.find_under(world, composer, "input").ok()??;
            Some(brick.text_of(world, editor, "text"))
        })
        .unwrap_or_default()
}

/// The page `title` open with its prompt on screen, aimed at it and knowing
/// where an ask runs.
fn prompt_on(world: &mut World, title: &str) -> Outcome<(Brick, ObjectId)> {
    let id = id_of_page(world, title)?;
    offer_models(world)?;
    look_at_page(world, &id)?;
    let mounted = world
        .peek_part::<brick::Shown>()
        .and_then(|s| s.0)
        .and_then(|b| b.root(world).map(|r| b.text_of(world, r, "objectName")));
    let in_window = mounted
        .as_deref()
        .is_some_and(|name| name != "spacePromptPage");
    if mounted.as_deref() != Some("spacePromptPage") && !in_window {
        Brick::show(world, PROMPT_PAGE, 900.0, 700.0)?;
    }
    let target = format!("page#{id}");
    world.wait_for_with(
        |w| {
            let state = prompt(w);
            text(&state["target"]) == target
                && !state["project"].is_null()
                && !state["selectedModel"].is_null()
        },
        |w| format!("the prompt to be the page's; it is {}", show(&prompt(w))),
    )?;
    world.wait_for_with(
        |w| composer_shown(w).is_some() && editor_text(w) == text(&prompt(w)["text"]),
        |w| {
            format!(
                "the page to show its prompt; the editor reads \"{}\" ({})",
                editor_text(w),
                if composer_shown(w).is_some() {
                    "shown"
                } else {
                    "not shown"
                }
            )
        },
    )?;
    composer_shown(world).ok_or_else(|| Failure("the page's prompt went away".into()))
}

fn invoke(engine: &Engine, item: ObjectId, function: &str, args: &[Qml]) -> Outcome<Qml> {
    engine
        .invoke_by_name(item, function, args)
        .map_err(|e| Failure(format!("{function}: {e:?}")))
}

/// The editor and the shell agree on what the prompt holds.
fn settle_prompt(world: &mut World, composer: ObjectId) -> Outcome {
    invoke(world.engine(), composer, "flushText", &[])?;
    world.sync()?;
    world.wait_for_with(
        |w| editor_text(w) == text(&prompt(w)["text"]),
        |w| {
            format!(
                "the editor to read what the shell has: {}",
                show(&prompt(w))
            )
        },
    )
}

/// Presses and releases `event`'s key in the window.
fn click(world: &mut World, event: KeyEvent) -> Outcome<bool> {
    let release = KeyEvent::release(event.key).with_modifiers(event.modifiers);
    let taken = world.key(&event)?;
    world.key(&release)?;
    Ok(taken)
}

fn type_keys(world: &mut World, typed: &str) -> Outcome {
    for ch in typed.chars() {
        let mut event = KeyEvent::press(ch.to_ascii_uppercase() as i32).with_text(ch.to_string());
        if ch.is_ascii_uppercase() {
            event = event.with_modifiers(Modifiers::SHIFT);
        }
        click(world, event)?;
    }
    Ok(())
}

fn press(world: &mut World, spelt: &str) -> Outcome {
    let event = brick::key_event(spelt)?;
    click(world, event).map(|_| ())
}

/// The keyboard in the prompt of `title`, at the end of what it holds.
fn focus_prompt(world: &mut World, title: &str) -> Outcome<(Brick, ObjectId)> {
    let (brick, composer) = prompt_on(world, title)?;
    let editor = editor_of(world, brick, composer)?;
    invoke(world.engine(), composer, "focusInput", &[])?;
    let end = brick.text_of(world, editor, "text").encode_utf16().count();
    brick.write(world, editor, "cursorPosition", Qml::from(end as f64))?;
    Ok((brick, composer))
}

/// Types `typed` at the end of the prompt of `title`, a key at a time.
fn type_in_prompt(world: &mut World, title: &str, typed: &str) -> Outcome<ObjectId> {
    let (_, composer) = focus_prompt(world, title)?;
    type_keys(world, typed)?;
    settle_prompt(world, composer)?;
    Ok(composer)
}

/// Whether the window took the last Ctrl+K a step pressed.
#[derive(Default)]
struct PaletteKey {
    taken: Option<bool>,
    ran: std::rc::Rc<std::cell::RefCell<Vec<String>>>,
    hooked: Option<usize>,
}

/// What the window made of the last Ctrl+K, for a failure.
fn describe_palette_key(world: &World) -> String {
    let taken = world.peek_part::<PaletteKey>().and_then(|k| k.taken);
    let ran = world
        .peek_part::<PaletteKey>()
        .map(|k| k.ran.borrow().clone())
        .unwrap_or_default();
    let shortcut = hal_c2_shell::controllers::keybindings::Keymap::of(world.engine())
        .shortcuts()
        .into_iter()
        .find(|s| text(&s["sequence"]).eq_ignore_ascii_case("ctrl+k"));
    let root = world
        .peek_part::<brick::Shown>()
        .and_then(|shown| shown.0)
        .and_then(|brick| brick.root(world));
    let flags = root.map(|root| {
        [
            "popupHoldsKeys",
            "composerFocused",
            "editableFocused",
            "terminalFocused",
            "previewFocused",
        ]
        .iter()
        .map(|name| format!("{name}={:?}", world.engine().read_by_name(root, name)))
        .collect::<Vec<_>>()
        .join(" ")
    });
    format!(
        "the window {} the key and ran {}; its Ctrl+K shortcut is {}; the window has {}",
        match taken {
            Some(true) => "took",
            Some(false) => "did not take",
            None => "was never sent",
        },
        show(&json!(ran)),
        shortcut.map_or("missing".to_owned(), |s| show(&s)),
        flags.unwrap_or_else(|| "no root".to_owned())
    )
}

/// The ask the MC was sent last, once one came.
fn last_ask(world: &mut World) -> Outcome<Value> {
    for _ in 0..100 {
        let ask = fake::fake(&mut world.mc).last_ask.clone();
        if ask.as_object().is_some_and(|o| !o.is_empty()) {
            return Ok(ask);
        }
        world.sync()?;
    }
    fail!("no ask reached the MC")
}

fn attachment_names(state: &Value) -> Vec<String> {
    state["attachments"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|a| text(&a["name"]))
        .collect()
}

/// Attaches `name` to the prompt of `title`: a picture, or a PDF that uploads.
fn attach_to_prompt(world: &mut World, title: &str, name: &str) -> Outcome {
    prompt_on(world, title)?;
    let image = name.ends_with(".png");
    world.dispatch(
        "composer.attach",
        json!({"files": [{
            "name": name,
            "mimeType": (if image { "image/png" } else { "application/pdf" }),
            "base64": (if image { PNG } else { PDF }),
        }]}),
    )?;
    // A file is the MC's once its upload is done.
    let wanted = name.to_owned();
    world.wait_for_with(
        move |w| {
            prompt(w)["attachments"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|a| text(&a["name"]) == wanted && text(&a["status"]).is_empty())
        },
        |w| {
            format!(
                "the prompt to hold the file; it holds {}",
                show(&prompt(w)["attachments"])
            )
        },
    )
}

/// Types `typed` into the prompt of `title` and picks the suggestion `id`
/// it offers.
fn suggest_in_prompt(world: &mut World, title: &str, typed: &str, id: &str) -> Outcome {
    type_in_prompt(world, title, typed)?;
    let wanted = id.to_owned();
    world.wait_for_with(
        |w| {
            prompt(w)["suggestions"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|s| text(&s["id"]).contains(&wanted))
        },
        |w| {
            format!(
                "the prompt to offer {id}; it offers {}",
                show(&prompt(w)["suggestions"])
            )
        },
    )?;
    let chosen = prompt(world)["suggestions"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|s| text(&s["id"]))
        .find(|s| s.contains(id))
        .unwrap_or_default();
    world.dispatch("composer.suggest.select", json!({"id": chosen}))?;
    world.sync()
}

fn has_effort(selection: &Value, level: &str) -> bool {
    selection["options"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|o| text(&o["id"]) == "reasoningEffort" && text(&o["value"]) == level)
}

fn thread_key(world: &mut World, title: &str) -> Outcome<String> {
    let id = thread_named(world, title)?;
    Ok(format!("{}:{id}", world.mc.environment_id))
}

/// The window a step drew (stage.rs's "the window is drawn by").
fn window(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    let brick = brick::shown(world)?;
    match brick.root(world) {
        Some(root) => Ok((brick, root)),
        None => fail!("no window is drawn"),
    }
}

fn visible(engine: &Engine, item: ObjectId) -> bool {
    engine.read_by_name(item, "visible") == Qml::Bool(true)
}

/// The prompts the window shows: each Composer's editor that is on screen.
fn prompts_shown(engine: &Engine, item: ObjectId, out: &mut Vec<ObjectId>) {
    if !visible(engine, item) {
        return;
    }
    if engine.read_by_name(item, "composerInput") == Qml::Bool(true) {
        out.push(item);
    }
    for child in engine.children(item) {
        prompts_shown(engine, child, out);
    }
}

fn shown_prompts(world: &World) -> Vec<ObjectId> {
    let mut out = Vec::new();
    if let Some(root) = world
        .peek_part::<brick::Shown>()
        .and_then(|s| s.0)
        .and_then(|b| b.root(world))
    {
        prompts_shown(world.engine(), root, &mut out);
    }
    out
}

/// The item named `name` at or under `item` that is on screen.
fn shown_item(engine: &Engine, item: ObjectId, name: &str) -> Option<ObjectId> {
    if !visible(engine, item) {
        return None;
    }
    if matches!(engine.read_by_name(item, "objectName"), Qml::String(ref s) if s.as_str() == name) {
        return Some(item);
    }
    engine
        .children(item)
        .into_iter()
        .find_map(|child| shown_item(engine, child, name))
}

fn object_name(engine: &Engine, item: ObjectId) -> String {
    match engine.read_by_name(item, "objectName") {
        Qml::String(s) => s.to_string(),
        _ => String::new(),
    }
}

fn on_page(engine: &Engine, editor: ObjectId) -> bool {
    let mut at = Some(editor);
    while let Some(item) = at {
        if object_name(engine, item) == "spaceComposer" {
            return true;
        }
        at = match engine.read_by_name(item, "parent") {
            Qml::Object(parent) => Some(parent),
            _ => None,
        };
    }
    false
}

fn focused(world: &World, item: ObjectId) -> bool {
    world.engine().read_by_name(item, "activeFocus") == Qml::Bool(true)
}

fn focused_item(world: &World) -> Option<ObjectId> {
    let root = world.peek_part::<brick::Shown>()?.0?.root(world)?;
    ljos::item::active_focus_item(world.engine(), root)
}

fn palette_open(world: &World) -> bool {
    world
        .with::<Palette, _>(|p, _| p.is_open())
        .unwrap_or(false)
}

fn run_command(world: &mut World, command: &str) -> Outcome {
    Commands::of(world.engine()).run(world.engine(), command);
    world.sync()
}

pub fn register(steps: &mut Steps) {
    register_prompt(steps);
    register_choices(steps);
    register_drafts(steps);
    register_window(steps);
}

fn register_prompt(steps: &mut Steps) {
    steps.step(&format!("the page {Q} in the Space {Q}"), |world, c, _| {
        let space = id_of_space(world, &c[1])?;
        expect!(
            space == current(world)?,
            "the scenario's Space is not {}",
            c[1]
        );
        given_page(world, &c[0], "").map(|_| ())
    });
    steps.step(
        &format!("the user (?:typed|types) {Q} in the prompt of {Q}"),
        |world, c, _| type_in_prompt(world, &c[1], &c[0]).map(|_| ()),
    );
    steps.step(
        &format!("the user sends {Q} from the prompt of {Q}"),
        |world, c, _| {
            let composer = type_in_prompt(world, &c[1], &c[0])?;
            press(world, "enter")?;
            settle_prompt(world, composer)?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user is offered the kinds of block, and {Q}"),
        |world, c, _| {
            let brick = brick::shown(world)?;
            let Some(slash) = brick.find(world, "spaceSlashMenu")? else {
                fail!("the page has no slash menu");
            };
            let labels = move |w: &World| -> Vec<String> {
                let engine = w.engine();
                hal_c2_shell::json::from_value(engine, &engine.read_by_name(slash, "shown"))
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|e| text(&e["label"]))
                    .collect()
            };
            let wanted = c[0].clone();
            world.wait_for_with(
                |w| {
                    let shown = labels(w);
                    brick.flag(w, slash, "visible")
                        && [wanted.as_str(), "Heading", "Checklist"]
                            .iter()
                            .all(|l| shown.iter().any(|s| s == l))
                },
                |w| {
                    format!(
                        "the slash menu to offer the kinds and {}; it offers {}",
                        c[0],
                        labels(w).join(", ")
                    )
                },
            )?;
            // The page's own menu, not the thread's slash commands.
            let suggestions = prompt(world)["suggestions"].clone();
            expect!(
                suggestions.as_array().is_none_or(Vec::is_empty),
                "the prompt also offers {}",
                show(&suggestions)
            );
            Ok(())
        },
    );
    // Older than the Background's thread, so an ask still runs in its
    // project by default.
    steps.step(
        &format!("the thread {Q} of the project {Q} runs on another model"),
        |world, c, _| {
            have_project(world, &c[1])?;
            let id = format!("t-{}", c[0].to_lowercase());
            let row = json!({
                "id": id,
                "title": c[0],
                "projectId": c[1],
                "createdAt": "2026-09-22T09:00:00Z",
                "updatedAt": "2026-09-22T09:00:00Z",
                "modelSelection": {"instanceId": "codex", "model": "gpt-5"},
            });
            world.mc.threads.insert(id.clone(), row.clone());
            world.mc.send_row(&id, &row);
            world.sync()
        },
    );
    steps.step(&format!("the user starts an ask on {Q}"), |world, c, _| {
        prompt_on(world, &c[0])?;
        world.dispatch("composer.ask", json!({}))?;
        world.wait_for_with(
            |w| text(&prompt(w)["text"]).starts_with("@agent "),
            |w| {
                format!(
                    "the prompt to start an ask; it reads {}",
                    show(&prompt(w)["text"])
                )
            },
        )?;
        let (_, composer) = prompt_on(world, &c[0])?;
        settle_prompt(world, composer)
    });
    steps.step(
        &format!("the prompt of {Q} says the ask runs in the project {Q} on the model of {Q}"),
        |world, c, _| {
            let (brick, composer) = prompt_on(world, &c[0])?;
            let project = brick.item(world, "spaceAskProject")?;
            let wanted = c[1].clone();
            world.wait_for_with(
                |w| {
                    brick.flag(w, project, "visible") && brick.text_of(w, project, "text") == wanted
                },
                |w| {
                    format!(
                        "the prompt to say the project {}; it says \"{}\"",
                        c[1],
                        brick.text_of(w, project, "text")
                    )
                },
            )?;
            let thread = thread_named(world, &c[2])?;
            let model = world
                .mc
                .threads
                .get(&thread)
                .map(|t| t["modelSelection"].clone())
                .unwrap_or_default();
            let state = prompt(world);
            expect!(
                text(&state["selectedModel"]) == text(&model["model"])
                    && text(&state["selectedInstanceId"]) == text(&model["instanceId"]),
                "the prompt is on {} of {}, {} on {}",
                text(&state["selectedModel"]),
                text(&state["selectedInstanceId"]),
                c[2],
                show(&model)
            );
            expect!(
                brick.flag(world, composer, "visible"),
                "the prompt is hidden"
            );
            Ok(())
        },
    );
}

const CHOICES: &str = "another model|high effort|planning|approval for each action|the project {Q}|the image {Q}|the file {Q}|a mention of {Q}|the skill {Q}";

fn register_choices(steps: &mut Steps) {
    let choices = CHOICES.replace("{Q}", Q);
    steps.step(
        &format!("the user chooses ({choices}) in the prompt of {Q}"),
        |world, c, _| {
            // Each choice that names something has its own group: one of
            // them matched.
            let title = c.last().cloned().unwrap_or_default();
            prompt_on(world, &title)?;
            let what = c[0].clone();
            let named = c[1..c.len() - 1].concat();
            match what.as_str() {
                "another model" => {
                    let now = text(&prompt(world)["selectedModel"]);
                    let other = if now == "gpt-5-codex" {
                        "gpt-5"
                    } else {
                        "gpt-5-codex"
                    };
                    world.mc.part::<PromptChoice>().model = other.to_owned();
                    world.dispatch(
                        "composer.model.select",
                        json!({"instanceId": "codex", "model": other}),
                    )?;
                    world.wait_for(&format!("the prompt to be on {other}"), |w| {
                        text(&prompt(w)["selectedModel"]) == other
                    })?;
                }
                "high effort" => {
                    world.dispatch(
                        "composer.option.set",
                        json!({"id": "reasoningEffort", "value": "high"}),
                    )?;
                    world.sync()?;
                }
                "planning" => {
                    let engine = world.engine().clone();
                    expect!(
                        Settings::of(&engine).write_device(&engine, "planModeEnabled", json!(true)),
                        "the device settings refused planning"
                    );
                    world.wait_for("the prompt to offer planning", |w| {
                        prompt(w)["showInteractionModeToggle"] == json!(true)
                    })?;
                    world.dispatch("composer.interactionMode.set", json!({"mode": "plan"}))?;
                    world.wait_for("the prompt to plan", |w| {
                        text(&prompt(w)["interactionMode"]) == "plan"
                    })?;
                }
                "approval for each action" => {
                    world.dispatch(
                        "composer.runtimeMode.set",
                        json!({"mode": "approval-required"}),
                    )?;
                    world.wait_for("the prompt to ask before each action", |w| {
                        text(&prompt(w)["runtimeMode"]) == "approval-required"
                    })?;
                }
                w if w.starts_with("the project") => {
                    have_project(world, &named)?;
                    choose_project(world, &named)?;
                }
                w if w.starts_with("the image") || w.starts_with("the file") => {
                    attach_to_prompt(world, &title, &named)?;
                }
                w if w.starts_with("a mention") => {
                    fake_files(&mut world.mc)
                        .files
                        .insert(named.clone(), "# shop\n".to_owned());
                    let typed: String = named.chars().take(4).collect();
                    suggest_in_prompt(world, &title, &format!("@{typed}"), &named)?;
                }
                _ => {
                    let typed: String = named.chars().take(3).collect();
                    suggest_in_prompt(world, &title, &format!("${typed}"), &format!(":{named}"))?;
                }
            }
            let (_, composer) = prompt_on(world, &title)?;
            settle_prompt(world, composer)
        },
    );
    steps.step(
        &format!("the agent's thread of {Q} has ({choices})"),
        |world, c, _| {
            let ask = last_ask(world)?;
            let what = c[1].as_str();
            let named = c[2..].concat();
            let model = &ask["modelSelection"];
            let attached: Vec<String> = ask["attachments"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|a| text(&a["name"]))
                .collect();
            let request = text(&ask["request"]);
            let has = match what {
                "another model" => text(&model["model"]) == world.mc.part::<PromptChoice>().model,
                "high effort" => has_effort(model, "high"),
                "planning" => text(&ask["interactionMode"]) == "plan",
                "approval for each action" => text(&ask["runtimeMode"]) == "approval-required",
                w if w.starts_with("the project") => text(&ask["projectId"]) == named,
                w if w.starts_with("the image") || w.starts_with("the file") => {
                    attached.contains(&named)
                }
                w if w.starts_with("a mention") => request.contains(&named),
                _ => request.contains(&format!("${named}")),
            };
            // And it is the ask the user sent, the page's agent working on it.
            expect!(
                has && request.ends_with("tidy this"),
                "the ask was {}",
                show(&ask)
            );
            expect_agent(world, &c[0], "working", |agent| {
                agent.get("status").map(text).as_deref() == Some("running")
            })
        },
    );
}

/// Picks `named` from the project button's menu, as the user does.
fn choose_project(world: &mut World, named: &str) -> Outcome {
    let brick = brick::shown(world)?;
    brick.click(world, "spaceAskProject")?;
    let Some(menu) = brick.find(world, "spaceAskProjectMenu")? else {
        fail!("the prompt has no project menu");
    };
    let entry = |w: &World| -> Option<ObjectId> {
        let engine = w.engine();
        let count = match engine.read_by_name(menu, "count") {
            Qml::Int(n) => n,
            Qml::Real(n) => n as i32,
            _ => 0,
        };
        (0..count).find_map(
            |i| match engine.invoke_by_name(menu, "itemAt", &[Qml::Int(i)]) {
                Ok(Qml::Object(item)) if brick.text_of(w, item, "text") == named => Some(item),
                _ => None,
            },
        )
    };
    world.wait_for(&format!("the project menu to offer {named}"), |w| {
        entry(w).is_some()
    })?;
    let Some(item) = entry(world) else {
        fail!("the project menu lost {named}");
    };
    world
        .engine()
        .emit_by_name(item, "triggered", &[])
        .map_err(|e| Failure(format!("triggered: {e:?}")))?;
    invoke(world.engine(), menu, "close", &[])?;
    world.pump()?;
    let wanted = named.to_owned();
    world.wait_for_with(
        move |w| text(&prompt(w)["project"]["id"]) == wanted,
        |w| {
            format!(
                "the ask to run in {named}; it runs in {}",
                show(&prompt(w)["project"])
            )
        },
    )
}

fn register_drafts(steps: &mut Steps) {
    steps.step(
        &format!("the user asks an agent about {Q} from (the page's menu|the command palette|its keybinding)"),
        |world, c, _| {
            let (brick, composer) = prompt_on(world, &c[0])?;
            match c[1].as_str() {
                "the page's menu" => {
                    let entry = brick.find(world, "spaceAskAgent")?;
                    let Some(entry) = entry.filter(|e| brick.flag(world, *e, "enabled")) else {
                        fail!("the page's menu has no way to ask an agent");
                    };
                    world
                        .engine()
                        .emit_by_name(entry, "triggered", &[])
                        .map_err(|e| Failure(format!("triggered: {e:?}")))?;
                }
                "the command palette" => {
                    Commands::of(world.engine()).run(world.engine(), ASK_AGENT);
                }
                _ => {
                    bind_key(world, "mod+alt+y", ASK_AGENT)?;
                    press_key(world, "mod+alt+y")?;
                    expect!(key_ran(world, ASK_AGENT), "{}", describe_key_press(world));
                }
            }
            world.sync()?;
            settle_prompt(world, composer)
        },
    );
    steps.step(
        &format!("the prompt of {Q} is ready to ask an agent"),
        |world, c, _| {
            let (brick, composer) = prompt_on(world, &c[0])?;
            let editor = editor_of(world, brick, composer)?;
            world.wait_for_with(
                |w| brick.text_of(w, editor, "text").starts_with("@agent ") && focused(w, editor),
                |w| {
                    format!(
                        "the prompt to start an ask with the keyboard in it; it reads \"{}\"",
                        brick.text_of(w, editor, "text")
                    )
                },
            )?;
            let project = brick.item(world, "spaceAskProject")?;
            expect!(
                brick.flag(world, project, "visible"),
                "the prompt does not say where the ask runs"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user takes \"@agent\" out of the prompt of {Q} and sends {Q}"),
        |world, c, _| {
            let (brick, composer) = focus_prompt(world, &c[0])?;
            let editor = editor_of(world, brick, composer)?;
            let mut left = brick.text_of(world, editor, "text").chars().count() + 1;
            while !brick.text_of(world, editor, "text").is_empty() && left > 0 {
                press(world, "backspace")?;
                left -= 1;
            }
            settle_prompt(world, composer)?;
            type_keys(world, &c[1])?;
            press(world, "enter")?;
            settle_prompt(world, composer)
        },
    );
    steps.step(
        &format!("the user stops from the prompt of {Q}"),
        |world, c, _| {
            let (brick, _) = prompt_on(world, &c[0])?;
            let button = brick.item(world, "primaryAction")?;
            world.wait_for_with(
                |w| brick.flag(w, button, "stopMode") && brick.flag(w, button, "enabled"),
                |w| format!("the prompt to offer a stop; it is {}", show(&prompt(w))),
            )?;
            brick.click(world, "primaryAction")?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user opens {Q} and comes back to {Q}"),
        |world, c, _| {
            prompt_on(world, &c[0])?;
            prompt_on(world, &c[1]).map(|_| ())
        },
    );
    steps.step(&format!("the user opens the thread {Q}"), |world, c, _| {
        let key = thread_key(world, &c[0])?;
        world.dispatch("thread.open", json!({"key": key}))?;
        world.wait_for("the prompt to be the thread's", |w| {
            text(&prompt(w)["target"]) == key
        })
    });
    steps.step(
        &format!("the prompt of {Q} (reads|does not read) {Q}(?: with the image {Q})?"),
        |world, c, _| {
            let reads = c[1] == "reads";
            if find_page(world, &c[0])?.is_empty() {
                // A thread's prompt.
                let key = thread_key(world, &c[0])?;
                world.sync()?;
                let state = prompt(world);
                expect!(
                    text(&state["target"]) == key && (text(&state["text"]) == c[2]) == reads,
                    "the prompt of {} is {}",
                    c[0],
                    show(&state)
                );
                return Ok(());
            }
            prompt_on(world, &c[0])?;
            let (said, image) = (c[2].clone(), c.get(3).cloned().unwrap_or_default());
            world.wait_for_with(
                |w| {
                    let state = prompt(w);
                    let same = text(&state["text"]) == said
                        && editor_text(w) == said
                        && (image.is_empty() || attachment_names(&state) == [image.clone()]);
                    same == reads
                },
                |w| {
                    format!(
                        "the prompt to {} \"{}\"; it is {}",
                        c[1],
                        c[2],
                        show(&prompt(w))
                    )
                },
            )
        },
    );
    steps.step(&format!("the prompt of {Q} is empty"), |world, c, _| {
        prompt_on(world, &c[0])?;
        let state = prompt(world);
        expect!(
            text(&state["text"]).is_empty()
                && editor_text(world).is_empty()
                && state["attachments"].as_array().is_none_or(Vec::is_empty),
            "the prompt is {}",
            show(&state)
        );
        Ok(())
    });
    steps.step(
        &format!("the user stashes the prompt of {Q}"),
        |world, c, _| {
            let (_, composer) = prompt_on(world, &c[0])?;
            settle_prompt(world, composer)?;
            world.dispatch("composer.stash", json!({}))?;
            world.sync()?;
            let state = prompt(world);
            expect!(
                text(&state["text"]).is_empty(),
                "the prompt kept {}",
                show(&state)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user brings {Q} back from the stash"),
        |world, c, _| {
            let stash = world.state("composerStash");
            let id = stash["entries"]
                .as_array()
                .into_iter()
                .flatten()
                .find(|e| text(&e["snippet"]) == c[0])
                .map(|e| text(&e["id"]))
                .unwrap_or_default();
            expect!(!id.is_empty(), "the stash holds {}", show(&stash));
            world.dispatch("composer.stash.restore", json!({"id": id}))?;
            world.sync()
        },
    );
    steps.step("the user turned on (vim keys|rich text)", |world, c, _| {
        let key = if c[0] == "vim keys" {
            "composerVimKeys"
        } else {
            "composerRichTextEnabled"
        };
        // What the General page's switch does (SettingsRow), from off.
        let engine = world.engine().clone();
        Settings::of(&engine).set(&engine, key, json!(false));
        Settings::of(&engine).set(&engine, key, json!(true));
        world.pump()
    });
    steps.step(
        &format!("the prompt of {Q} edits with (vim keys|rich text)"),
        |world, c, _| {
            let (brick, composer) = prompt_on(world, &c[0])?;
            if c[1] == "vim keys" {
                let Qml::Object(vim) = brick.read(world, composer, "vim") else {
                    fail!("the page's prompt has no Vim keys");
                };
                expect!(
                    brick.flag(world, vim, "vimEnabled"),
                    "the page's prompt has Vim keys off"
                );
                // Escape leaves insert mode, as in a thread's prompt.
                invoke(world.engine(), composer, "focusInput", &[])?;
                press(world, "escape")?;
                world.wait_for("Escape to leave insert mode", |w| {
                    !brick.flag(w, vim, "insertMode")
                })
            } else {
                expect!(
                    brick.flag(world, composer, "richText"),
                    "the page's prompt has rich text off"
                );
                Ok(())
            }
        },
    );
    steps.step(
        &format!("the user attached the image {Q} in the prompt of {Q}"),
        |world, c, _| attach_to_prompt(world, &c[1], &c[0]),
    );
}

fn register_window(steps: &mut Steps) {
    steps.step(
        &format!("the user opens {Q} in the window"),
        |world, c, _| {
            let id = id_of_page(world, &c[0])?;
            look_at_page(world, &id)?;
            let target = format!("page#{id}");
            world.wait_for_with(
                |w| text(&prompt(w)["target"]) == target,
                |w| format!("the prompt to be the page's; it is {}", show(&prompt(w))),
            )
        },
    );
    steps.step(
        &format!("the user asks an agent about {Q} from the command palette in the window"),
        |world, c, _| {
            window(world)?;
            let page = id_of_page(world, &c[0])?;
            let shown = with_space(world, |s, _| s.page_id().to_owned())?;
            expect!(shown == page, "the window does not show {}", c[0]);
            run_command(world, ASK_AGENT)
        },
    );
    steps.step(
        "the keyboard is in the prompt the window shows",
        |world, _, _| {
            window(world)?;
            world.wait_for_with(
                |w| {
                    let shown = shown_prompts(w);
                    shown.len() == 1 && focused(w, shown[0])
                },
                |w| {
                    let at = focused_item(w);
                    let engine = w.engine();
                    format!(
                        "the keyboard to be in the prompt on screen ({} shown); it is in {}",
                        shown_prompts(w).len(),
                        match at {
                            None => "nothing".to_owned(),
                            Some(item)
                                if engine.read_by_name(item, "composerInput")
                                    == Qml::Bool(true) =>
                            {
                                if on_page(engine, item) {
                                    "the page's prompt"
                                } else {
                                    "the shell's prompt"
                                }
                                .to_owned()
                            }
                            Some(item) => format!("\"{}\"", object_name(engine, item)),
                        }
                    )
                },
            )
        },
    );
    // The palette's key, with the keyboard in a part of the page the window
    // shows.
    steps.step(
        &format!("the user presses Ctrl\\+K in the window with the keyboard in (the page's prompt(?: under its / menu)?|the page's title|the block {Q})"),
        |world, c, _| {
            let (_, root) = window(world)?;
            let where_ = c[0].clone();
            let block = format!("spaceBlock:{}", c[1]);
            let find = move |w: &World| -> Option<ObjectId> {
                let engine = w.engine();
                if where_.starts_with("the page's prompt") {
                    let shown = shown_prompts(w);
                    (shown.len() == 1).then(|| shown[0])
                } else if where_ == "the page's title" {
                    shown_item(engine, root, "spacePageTitle")
                } else {
                    let block = shown_item(engine, root, &block)?;
                    match engine.read_by_name(block, "editor") {
                        Qml::Object(editor) => Some(editor),
                        _ => {
                            let _ = engine.invoke_by_name(block, "edit", &[Qml::Undefined, Qml::Undefined]);
                            match engine.read_by_name(block, "editor") {
                                Qml::Object(editor) => Some(editor),
                                _ => None,
                            }
                        }
                    }
                }
            };
            let mut target = None;
            for _ in 0..50 {
                world.pump()?;
                if let Some(item) = find(world) {
                    if !focused(world, item) {
                        invoke(world.engine(), item, "forceActiveFocus", &[])?;
                        world.pump()?;
                    }
                    if focused(world, item) {
                        target = Some(item);
                        break;
                    }
                }
                world.sync()?;
            }
            let Some(target) = target else {
                fail!("the keyboard did not go to {}", c[0]);
            };
            // The menu `/` opens leaves the keyboard in the prompt.
            if c[0].ends_with("/ menu") {
                type_keys(world, "/")?;
                let brick = brick::shown(world)?;
                world.wait_for_with(
                    |w| {
                        matches!(brick.find(w, "spaceSlashMenu"), Ok(Some(slash)) if brick.flag(w, slash, "visible"))
                            && focused(w, target)
                    },
                    |w| {
                        format!(
                            "the / menu to open with the keyboard left in the prompt; the prompt reads \"{}\" and {} the keyboard",
                            brick.text_of(w, target, "text"),
                            if focused(w, target) { "has" } else { "lacks" }
                        )
                    },
                )?;
            }
            let ran = world.part::<PaletteKey>().ran.clone();
            let engine = world.engine() as *const _ as usize;
            if std::mem::replace(&mut world.part::<PaletteKey>().hooked, Some(engine)) != Some(engine) {
                let log = ran.clone();
                Commands::of(world.engine()).on_ran(move |_, command| {
                    log.borrow_mut().push(command.to_owned());
                });
            }
            ran.borrow_mut().clear();
            let taken = click(world, brick::key_event("ctrl+k")?)?;
            world.part::<PaletteKey>().taken = Some(taken);
            world.sync()
        },
    );
    steps.step("the command palette is open, with the keyboard in its search", |world, _, _| {
        window(world)?;
        world.wait_for_with(
            |w| {
                palette_open(w)
                    && focused_item(w).is_some_and(|f| object_name(w.engine(), f) == "commandPaletteSearch")
            },
            |w| {
                format!(
                    "the palette to be open (it is {}) with the keyboard in its search; it is in {}; {}",
                    if palette_open(w) { "open" } else { "shut" },
                    focused_item(w).map_or("nothing".to_owned(), |f| format!("\"{}\"", object_name(w.engine(), f))),
                    describe_palette_key(w)
                )
            },
        )
    });
    steps.step(
        &format!("the user types {Q} in the window"),
        |world, c, _| {
            window(world)?;
            type_keys(world, &c[0])?;
            world.sync()
        },
    );
    steps.step(
        &format!("the command palette's search reads {Q}"),
        |world, c, _| {
            let wanted = c[0].clone();
            world.wait_for_with(
                |w| {
                    w.with::<Palette, _>(|p, _| p.is_open() && p.query() == wanted)
                        .unwrap_or(false)
                },
                |w| {
                    format!(
                        "the palette's search to read {}; it reads \"{}\"",
                        c[0],
                        w.with::<Palette, _>(|p, _| p.query().to_owned())
                            .unwrap_or_default()
                    )
                },
            )
        },
    );
    // One editor on screen, the page's own on a page and the shell's on a
    // thread.
    steps.step(
        &format!("the window shows one prompt, aimed at (the page|the thread) {Q}"),
        |world, c, _| {
            window(world)?;
            let page = c[0] == "the page";
            let target = if page {
                format!("page#{}", id_of_page(world, &c[1])?)
            } else {
                thread_key(world, &c[1])?
            };
            world.wait_for_with(
                |w| {
                    let shown = shown_prompts(w);
                    text(&prompt(w)["target"]) == target
                        && shown.len() == 1
                        && on_page(w.engine(), shown[0]) == page
                },
                |w| {
                    let shown = shown_prompts(w);
                    let where_: Vec<&str> = shown
                        .iter()
                        .map(|e| {
                            if on_page(w.engine(), *e) {
                                "the page's"
                            } else {
                                "the shell's"
                            }
                        })
                        .collect();
                    format!(
                        "one prompt on {}; the window shows {} ({}), aimed at {}",
                        c[1],
                        shown.len(),
                        where_.join(", "),
                        text(&prompt(w)["target"])
                    )
                },
            )
        },
    );
}
