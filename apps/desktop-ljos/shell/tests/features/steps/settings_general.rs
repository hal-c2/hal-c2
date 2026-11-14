//! Settings → General as the desktop draws it (qml/HalC2/Bricks/GeneralSettings.qml),
//! and what each of its rows changes elsewhere in the shell: the sidebar's
//! grouping and clock, how a diff opens, proactive panels, the composer's
//! keys, the questions asked before a thread goes, and the quit shortcut
//! (features/settings/general.feature). desktop-qt's SettingsGeneralSteps.cpp.
//!
//! The MC's diffs (`orchestration.getTurnDiff`, `getFullThreadDiff`) and the
//! quit shortcut's key presses are the panel's and the window's steps in
//! desktop-qt (PanelSteps.cpp, WindowSteps.cpp); the few lines of each these
//! scenarios need are kept here, private.

use std::cell::Cell;
use std::collections::BTreeMap;
use std::rc::Rc;

use hal_c2_shell::controllers::composer::kept;
use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::quit::{self, QuitController};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::sidebar;
use hal_c2_shell::keybindings::qt::{KEY_CONTROL, KEY_Q};
use hal_c2_shell::thread_view::diff::DiffModel;
use hal_c2_shell::thread_view::thread_diff::ThreadDiff;
use ljos::keys::{KeyKind, Modifiers};
use ljos::prelude::ObjectId;
use serde_json::{Value, json};

use crate::expect;
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::steps::keybinding::send_key;
use crate::steps::settings_rows::{
    choose_row, general_page, page_item, row_shown, row_text, setting_on, turn_row,
};
use crate::steps::stream::{self, FakeStreams, PEER, PEER_ENVIRONMENT, PROJECT, THREAD};
use crate::steps::thread_menu::{
    answer as answer_question, open_menu_at, pick, project_thread_commands, section_of, update_row,
};
use crate::steps::turn::{open_turn_thread, start_working_turn};
use crate::world::World;

/// What the scenario is in the middle of.
#[derive(Default)]
struct General {
    /// "single line" or "multiline".
    prompt: String,
    /// The thread the scenario acts on, by key.
    thread: String,
    /// unpins, archives or deletes.
    action: String,
}

/// The patches of the turns the MC diffs, as a fake's stand-in for diffing
/// two checkpoints.
#[derive(Default)]
struct Diffs {
    patches: BTreeMap<i64, String>,
}

/// How many times the app was asked to quit.
#[derive(Default)]
struct Quits {
    count: Rc<Cell<u32>>,
    hooked: bool,
}

fn row_key(title: &str) -> &'static str {
    match title {
        "Hide whitespace changes" => "diffIgnoreWhitespace",
        "Default diff file state" => "diffFilesCollapsed",
        "Diff layout" => "diffLayout",
        "Confirm thread unpinning" => "confirmThreadUnpin",
        "Confirm thread archiving" => "confirmThreadArchive",
        _ => "confirmThreadDelete",
    }
}

fn setting(world: &World, key: &str) -> Value {
    Settings::of(world.engine())
        .setting(world.engine(), key)
        .unwrap_or(Value::Null)
}

fn sidebar_projects(world: &World) -> Vec<Value> {
    at(&world.state("sidebar"), "projects")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn describe_projects(world: &World) -> String {
    format!(
        "the sidebar's projects are {}",
        show(&Value::Array(sidebar_projects(world)))
    )
}

fn project_row(id: &str) -> Value {
    json!({
        "id": id,
        "title": id,
        "workspaceRoot": format!("/work/{id}"),
        "scripts": [],
        "repositoryIdentity": {"canonicalKey": format!("github.com/acme/{id}"), "name": id},
    })
}

/// A thread of "shop" the scenario opens: its row as given, then its stream.
fn open_thread_with(world: &mut World, id: &str, fields: Value) -> Outcome {
    let project = project_row(PROJECT);
    world.mc.projects.insert(PROJECT.into(), project.clone());
    world.mc.send_row_of(PROJECT, &project, "project");
    let mut row = json!({
        "id": id, "title": "Tax line", "projectId": PROJECT,
        "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z",
    });
    if let Some(fields) = fields.as_object() {
        for (key, value) in fields {
            row[key] = value.clone();
        }
    }
    world.mc.threads.insert(id.into(), row.clone());
    world.mc.send_row(id, &row);
    world.sync()?;
    let environment = world.mc.environment_id.clone();
    let fake = world.mc.part::<FakeStreams>();
    fake.thread = id.into();
    fake.environment = environment.clone();
    stream::look(world, &format!("{environment}:{id}"), true)
}

fn panel_state(world: &World) -> Value {
    world.state("panel")
}

fn describe_panel(world: &World) -> String {
    format!("the panel is {}", show(&panel_state(world)))
}

// --- The diff -------------------------------------------------------------------

/// What the Diff tab holds.
#[derive(Default)]
struct DiffFacts {
    status: String,
    ignore_whitespace: bool,
    split: bool,
    all_expanded: bool,
    files: Vec<(String, bool)>,
}

fn diff_object(world: &World) -> Option<ObjectId> {
    world
        .with::<RightPanel, _>(|panel, _| panel.diff())
        .ok()
        .flatten()
}

fn diff_model(world: &World) -> Option<ObjectId> {
    ThreadDiff::model(world.engine(), diff_object(world)?)
}

fn diff_facts(world: &World) -> DiffFacts {
    let engine = world.engine();
    let Some(diff) = diff_object(world) else {
        return DiffFacts::default();
    };
    let (status, ignore_whitespace) = ThreadDiff::read(engine, diff, |tab| {
        (tab.status().to_owned(), tab.ignore_whitespace())
    })
    .unwrap_or_default();
    let model = ThreadDiff::model(engine, diff)
        .and_then(|model| {
            DiffModel::read(engine, model, |d| {
                (
                    d.split(),
                    d.all_expanded(),
                    (0..d.file_count())
                        .map(|file| {
                            (
                                d.path(file).unwrap_or_default().to_owned(),
                                d.expanded(file),
                            )
                        })
                        .collect::<Vec<_>>(),
                )
            })
        })
        .unwrap_or_default();
    DiffFacts {
        status,
        ignore_whitespace,
        split: model.0,
        all_expanded: model.1,
        files: model.2,
    }
}

fn describe_diff(world: &World) -> String {
    let facts = diff_facts(world);
    let files: Vec<String> = facts
        .files
        .iter()
        .map(|(path, expanded)| {
            format!(
                "{path} ({})",
                if *expanded { "expanded" } else { "collapsed" }
            )
        })
        .collect();
    format!(
        "the diff is {}, {}, whitespace {}: {}",
        facts.status,
        if facts.split { "split" } else { "stacked" },
        if facts.ignore_whitespace {
            "hidden"
        } else {
            "shown"
        },
        files.join(", ")
    )
}

fn patch_of(path: &str) -> String {
    format!(
        "diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -1,2 +1,2 @@\n-export const rate = 1;\n+export const rate = 2;\n export const done = true;\n"
    )
}

/// The MC answers a turn's diff with the patches of the turns in its range.
fn serve_diffs(mc: &mut crate::fake_mc::FakeMc) {
    for (method, full) in [
        ("orchestration.getTurnDiff", false),
        ("orchestration.getFullThreadDiff", true),
    ] {
        mc.on_rpc(method, move |mc, rpc| {
            let from = if full {
                0
            } else {
                rpc.payload["fromTurnCount"].as_i64().unwrap_or(0)
            };
            let to = rpc.payload["toTurnCount"].as_i64().unwrap_or(0);
            let patch: String = mc
                .part::<Diffs>()
                .patches
                .range(from + 1..=to)
                .map(|(_, patch)| patch.as_str())
                .collect();
            mc.reply(rpc, json!({"diff": patch}));
            Ok(())
        });
    }
}

/// A turn that finished and left a checkpoint, changing `files` with `patch`.
fn finish_turn_with_patch(world: &mut World, turn: i64, patch: &str, files: Value) -> Outcome {
    serve_diffs(&mut world.mc);
    let run = stream::start_running(world)?;
    stream::add_item(
        world,
        "assistant_message",
        json!({"text": format!("Answer {turn}")}),
    )?;
    stream::settle_run(world, "completed", 30)?;
    let checkpoint = format!("cp-{turn}");
    stream::set(
        world,
        "checkpoint",
        &checkpoint,
        json!({"id": checkpoint, "scopeId": "scope-1", "runId": run,
               "appRunOrdinal": turn, "status": "ready"}),
    )?;
    world
        .mc
        .part::<Diffs>()
        .patches
        .insert(turn, patch.to_owned());
    if files.as_array().is_some_and(|files| !files.is_empty()) {
        stream::set(world, "checkpoint", &checkpoint, json!({"files": files}))?;
    }
    Ok(())
}

/// The thread's latest turn changed two files; its diff is opened from the
/// panel.
fn open_diff(world: &mut World) -> Outcome {
    open_turn_thread(world)?;
    let patch = patch_of("src/rates.ts") + &patch_of("src/cart.ts");
    finish_turn_with_patch(world, 1, &patch, json!([]))?;
    world.dispatch("panel.open", json!({"tab": "diff", "turn": -1}))?;
    world.wait_for_with(|w| diff_facts(w).status == "ready", describe_diff)
}

// --- The quit shortcut ----------------------------------------------------------

/// Counts the times the app is asked to quit, from now on.
fn watch_quits(world: &mut World) -> Outcome {
    if world.part::<Quits>().hooked {
        return Ok(());
    }
    let count = world.part::<Quits>().count.clone();
    world.with::<QuitController, _>(|quit, _| {
        quit.on_quit(move |_| count.set(count.get() + 1));
    })?;
    world.part::<Quits>().hooked = true;
    Ok(())
}

fn quit_requests(world: &mut World) -> u32 {
    world.part::<Quits>().count.get()
}

/// mod goes down, then Q; `held_ms` later (auto-repeating meanwhile, as a held
/// key does after half a second) Q comes up, then mod.
fn press_quit_shortcut(world: &mut World, held_ms: u64, release_mod: bool) -> Outcome {
    watch_quits(world)?;
    let ctrl = Modifiers::CONTROL;
    send_key(world, KeyKind::Press, KEY_CONTROL, ctrl, false)?;
    send_key(world, KeyKind::Press, KEY_Q, ctrl, false)?;
    let mut elapsed = 0;
    let mut repeat = 500;
    while repeat <= held_ms {
        world.advance(repeat - elapsed)?;
        elapsed = repeat;
        send_key(world, KeyKind::Press, KEY_Q, ctrl, true)?;
        repeat += 33;
    }
    world.advance(held_ms - elapsed)?;
    send_key(world, KeyKind::Release, KEY_Q, ctrl, false)?;
    if release_mod {
        send_key(
            world,
            KeyKind::Release,
            KEY_CONTROL,
            Modifiers::empty(),
            false,
        )?;
    }
    world.sync()
}

// --- Commands the scenarios read -----------------------------------------------

fn commands_of(world: &World, kind: &str) -> Vec<Value> {
    world
        .mc
        .commands
        .iter()
        .filter(|command| text(&command["type"]) == kind)
        .cloned()
        .collect()
}

fn command_of(action: &str) -> String {
    format!(
        "thread.{}",
        match action {
            "unpins" => "unpin",
            "archives" => "archive",
            _ => "delete",
        }
    )
}

fn question(world: &mut World) -> Outcome<Value> {
    world.sync()?;
    Ok(world.state("confirmation"))
}

fn thread_target(world: &World) -> String {
    world
        .with::<Navigation, _>(|navigation, _| navigation.thread_key().to_owned())
        .unwrap_or_default()
}

pub fn register(steps: &mut Steps) {
    // Project grouping.
    steps.step(
        "project grouping combines matching repositories across environments",
        |world, _, _| {
            // The same repository checked out on this machine and on a linked one.
            let row = project_row(PROJECT);
            world.mc.projects.insert(PROJECT.into(), row.clone());
            world.mc.send_row_of(PROJECT, &row, "project");
            world.mc.join(PEER, PEER_ENVIRONMENT);
            world
                .mc
                .send_peer_row_of(PEER_ENVIRONMENT, PROJECT, &row, "project");
            world.wait_for_with(
                |w| sidebar_projects(w).len() == 1 && setting_on(w, "sidebarProjectGroupingMode"),
                describe_projects,
            )
        },
    );
    steps.step("the user turns project grouping off", |world, _, _| {
        turn_row(world, "sidebarProjectGroupingMode", false)
    });
    steps.step(
        "the sidebar lists each environment's copy of a repository as its own project",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let projects = sidebar_projects(w);
                    projects.len() == 2
                        && at(&projects[0], "environmentId") != at(&projects[1], "environmentId")
                },
                describe_projects,
            )
        },
    );
    steps.step(
        "the user had grouped projects by repository and then turned grouping off",
        |world, _, _| {
            expect!(
                setting(world, "sidebarProjectGroupingMode") == json!("repository"),
                "projects are not grouped by repository"
            );
            turn_row(world, "sidebarProjectGroupingMode", false)?;
            expect!(
                setting(world, "sidebarProjectGroupingMode") == json!("separate"),
                "grouping is {}",
                show(&setting(world, "sidebarProjectGroupingMode"))
            );
            Ok(())
        },
    );
    steps.step("the user turns project grouping on again", |world, _, _| {
        turn_row(world, "sidebarProjectGroupingMode", true)
    });
    steps.step("projects are grouped by repository again", |world, _, _| {
        expect!(
            setting(world, "sidebarProjectGroupingMode") == json!("repository"),
            "grouping is {}",
            show(&setting(world, "sidebarProjectGroupingMode"))
        );
        Ok(())
    });

    // The time format, as the sidebar's snooze times read (10:00 now; this
    // evening is 18:00).
    steps.step(
        &format!("the user sets the time format to {Q}"),
        |world, c, _| choose_row(world, "timestampFormat", &c[0]),
    );
    steps.step(
        "timestamps are shown (the way the system clock is configured|with AM and PM|on a 24-hour clock)",
        |world, c, _| {
            let evening = sidebar::snooze_presets(world.engine())
                .into_iter()
                .find(|preset| preset.id == "evening")
                .map(|preset| preset.when_label)
                .unwrap_or_default();
            // en-US reads "6:00 PM" however the CLDR data spaces it.
            let wanted = if c[0].starts_with("on a 24") { "18:00" } else { "6:00 PM" };
            expect!(evening == wanted, "this evening reads \"{evening}\", not \"{wanted}\"");
            Ok(())
        },
    );

    // Diffs.
    steps.step(
        &format!(
            "the user sets \"(Hide whitespace changes|Default diff file state|Diff layout)\" to {Q}"
        ),
        |world, c, _| {
            let key = row_key(&c[0]);
            if c[1] == "on" || c[1] == "off" {
                return turn_row(world, key, c[1] == "on");
            }
            choose_row(world, key, &c[1])
        },
    );
    steps.step("the user opens a diff", |world, _, _| open_diff(world));
    steps.step(
        "the diff opens (without whitespace-only edits|with every file collapsed|with every file expanded|side by side|stacked)",
        |world, c, _| {
            let facts = diff_facts(world);
            expect!(facts.files.len() == 2, "{}", describe_diff(world));
            if c[0].starts_with("without") {
                // The MC leaves them out of the patch when asked to.
                let asked = world
                    .mc
                    .calls
                    .iter()
                    .rev()
                    .find(|rpc| rpc.method == "orchestration.getTurnDiff")
                    .map(|rpc| rpc.payload.clone())
                    .unwrap_or(Value::Null);
                expect!(
                    facts.ignore_whitespace && asked["ignoreWhitespace"] == json!(true),
                    "{}; the MC was asked {}",
                    describe_diff(world),
                    show(&asked)
                );
            } else if c[0].ends_with("collapsed") {
                expect!(
                    facts.files.iter().all(|(_, expanded)| !expanded),
                    "{}",
                    describe_diff(world)
                );
            } else if c[0].ends_with("expanded") {
                expect!(facts.all_expanded, "{}", describe_diff(world));
            } else {
                expect!(
                    facts.split == (c[0] == "side by side"),
                    "{}",
                    describe_diff(world)
                );
            }
            Ok(())
        },
    );
    steps.step(&format!("the diff layout setting is {Q}"), |world, c, _| {
        choose_row(world, "diffLayout", &c[0])
    });
    steps.step(
        "the user switches an open diff to side by side",
        |world, _, _| {
            open_diff(world)?;
            expect!(!diff_facts(world).split, "{}", describe_diff(world));
            // As the diff's toolbar does (DiffPanel.qml).
            let Some(model) = diff_model(world) else {
                return Err(Failure("the diff has no model".into()));
            };
            DiffModel::update(world.engine(), model, |d| d.set_split(true));
            world.pump()
        },
    );
    steps.step(
        &format!("the diff layout setting reads {Q}"),
        |world, c, _| {
            let shown = row_text(world, "diffLayout")?;
            expect!(shown == c[0], "the row reads \"{shown}\"");
            Ok(())
        },
    );

    // Proactive panels.
    steps.step("proactive panels are (on|off)", |world, c, _| {
        turn_row(world, "proactivePanelsEnabled", c[0] == "on")
    });
    steps.step(
        "the user opens a thread with a linked pull request",
        |world, _, _| {
            let links = json!([{
                "host": "github.com", "repository": "acme/shop", "number": 7,
                "url": "https://github.com/acme/shop/pull/7", "source": "agent", "snapshot": null,
            }]);
            open_thread_with(world, "thread-pr", json!({"pullRequests": links}))?;
            world.sync()
        },
    );
    steps.step(
        "the user opens a thread whose working tree changed at least 3 files",
        |world, _, _| {
            open_thread_with(world, "thread-diff", json!({}))?;
            let mut files = Vec::new();
            let mut patch = String::new();
            for path in ["src/rates.ts", "src/cart.ts", "src/tax.ts"] {
                files.push(json!({"path": path, "additions": 1, "deletions": 1}));
                patch += &patch_of(path);
            }
            finish_turn_with_patch(world, 1, &patch, Value::Array(files))?;
            world.sync()
        },
    );
    steps.step(
        "the pull request panel opens with the thread",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let panel = panel_state(w);
                    panel["isOpen"] == json!(true)
                        && text(&panel["activeId"]).contains("pull-request")
                },
                describe_panel,
            )
        },
    );
    steps.step(
        "the working tree diff opens with the thread",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let panel = panel_state(w);
                    panel["isOpen"] == json!(true)
                        && panel["activeId"] == json!("diff")
                        && diff_facts(w).status == "ready"
                },
                |w| format!("{}; {}", describe_panel(w), describe_diff(w)),
            )?;
            expect!(
                diff_facts(world).files.len() == 3,
                "{}",
                describe_diff(world)
            );
            Ok(())
        },
    );
    steps.step("no side panel opens by itself", |world, _, _| {
        world.sync()?;
        let panel = panel_state(world);
        expect!(
            text(&panel["threadKey"]).ends_with(":thread-pr")
                && panel.get("isOpen").is_some()
                && panel["isOpen"] == json!(false)
                && panel["tabs"].as_array().is_none_or(|tabs| tabs.is_empty()),
            "{}",
            describe_panel(world)
        );
        Ok(())
    });

    // The send shortcut. The page words the modifier as this platform's key.
    steps.step(&format!("the send shortcut is {Q}"), |world, c, _| {
        choose_row(
            world,
            "sendShortcut",
            &c[0].replace("Modifier and Enter", "Ctrl + Enter"),
        )
    });
    steps.step(
        "the user presses Enter in a (single line|multiline) prompt",
        |world, c, _| {
            open_turn_thread(world)?;
            let multiline = c[0] == "multiline";
            let prompt = if multiline { "first line\nsecond line" } else { "one line" };
            world.part::<General>().prompt = prompt.into();
            let target = thread_target(world);
            world.dispatch(
                "composer.text.set",
                json!({"target": target, "text": prompt, "cursor": prompt.encode_utf16().count()}),
            )?;
            // What the composer does with a bare Enter (Composer.qml
            // enterIntent): send as the table says, else leave the key to
            // the editor.
            let table = if multiline { "multiline" } else { "singleLine" };
            let composer = world.state("composer");
            let intent = text(&at(&composer, &format!("enterIntents.{table}"))[""]);
            if intent.is_empty() {
                let prompt = format!("{prompt}\n");
                world.part::<General>().prompt = prompt.clone();
                world.dispatch(
                    "composer.text.set",
                    json!({"target": target, "text": prompt, "cursor": prompt.encode_utf16().count()}),
                )?;
            } else {
                world.dispatch("composer.submit", json!({"text": prompt, "intent": intent}))?;
            }
            world.sync()
        },
    );
    steps.step("the prompt (is sent|gets a new line)", |world, c, _| {
        let prompt = world.part::<General>().prompt.clone();
        let sent = commands_of(world, "message.dispatch");
        if c[0] == "is sent" {
            expect!(
                sent.len() == 1 && sent[0]["text"] == json!(prompt),
                "the MC has {}",
                world.describe_commands()
            );
            return Ok(());
        }
        let kept = kept::draft(world.engine(), &thread_target(world));
        expect!(
            sent.is_empty() && kept == prompt && kept.ends_with('\n'),
            "the prompt reads {}; the MC has {}",
            show(&json!(kept)),
            world.describe_commands()
        );
        Ok(())
    });

    // Follow-ups.
    steps.step(&format!("the follow-up behaviour is {Q}"), |world, c, _| {
        choose_row(world, "followUpBehavior", &c[0])
    });
    steps.step(
        "the user sends a message while the agent is running",
        |world, _, _| {
            start_working_turn(world)?;
            world.dispatch(
                "composer.submit",
                json!({"text": "also update the docs", "intent": "foreground"}),
            )?;
            world.sync()
        },
    );
    steps.step(
        "the message (waits until the run ends|is sent into the current run)",
        |world, c, _| {
            let sent = commands_of(world, "message.dispatch");
            expect!(
                sent.len() == 1 && sent[0]["text"] == json!("also update the docs"),
                "the MC has {}",
                world.describe_commands()
            );
            let message = &sent[0];
            let mode = text(&message["dispatchMode"]["type"]);
            let steers = message["deliveryIntent"] == json!("steer") && mode == "start_immediately";
            let queues = message.get("deliveryIntent").is_none() && mode == "queue_after_active";
            expect!(
                if c[0].starts_with("waits") {
                    queues
                } else {
                    steers
                },
                "the MC was sent {}",
                show(message)
            );
            Ok(())
        },
    );

    // Confirmations.
    steps.step(
        "\"(Confirm thread unpinning|Confirm thread archiving|Confirm thread deletion)\" is (on|off)",
        |world, c, _| turn_row(world, row_key(&c[0]), c[1] == "on"),
    );
    steps.step(
        "the user (unpins|archives|deletes) a thread",
        |world, c, _| {
            project_thread_commands(world);
            open_turn_thread(world)?;
            let key = format!("{}:{THREAD}", world.mc.environment_id);
            let state = world.part::<General>();
            state.action = c[0].clone();
            state.thread = key.clone();
            if c[0] == "unpins" {
                update_row(world, THREAD, |row| {
                    row.insert("pinnedAt".into(), json!("2026-09-23T09:30:00Z"));
                    row.insert("pinOrderKey".into(), json!("a0"));
                })?;
                let pinned = key.clone();
                world.wait_for("the thread to be pinned", move |w| {
                    section_of(w, &pinned) == "pinned"
                })?;
            }
            // From the thread's menu, as the sidebar offers it.
            open_menu_at(world, &key, 40.0, 120.0)?;
            let id = match c[0].as_str() {
                "unpins" => "unpin",
                "archives" => "archive",
                _ => "delete",
            };
            pick(world, id)?;
            world.sync()
        },
    );
    steps.step(
        "the user is asked before the (?:thread is unpinned|history is deleted)",
        |world, _, _| {
            let action = world.part::<General>().action.clone();
            let asked = question(world)?;
            let title = if action == "unpins" {
                "Unpin thread \"Tax line\"?"
            } else {
                "Delete thread \"Tax line\"?"
            };
            expect!(
                asked["title"] == json!(title)
                    && commands_of(world, &command_of(&action)).is_empty(),
                "the question is {}; the MC has {}",
                show(&asked),
                world.describe_commands()
            );
            if action == "deletes" {
                expect!(
                    text(&asked["description"]).contains("clears conversation history"),
                    "the question is {}",
                    show(&asked)
                );
            }
            Ok(())
        },
    );
    steps.step(
        "the archive action must be chosen a second time",
        |world, _, _| {
            // The menu's Archive only asks; the question's own Archive archives.
            let asked = question(world)?;
            expect!(
                asked["confirmLabel"] == json!("Archive")
                    && commands_of(world, "thread.archive").is_empty(),
                "the question is {}; the MC has {}",
                show(&asked),
                world.describe_commands()
            );
            answer_question(world, true)?;
            world.wait_for_with(
                |w| commands_of(w, "thread.archive").len() == 1,
                |w| {
                    format!(
                        "the thread to be archived; the MC has {}",
                        w.describe_commands()
                    )
                },
            )
        },
    );
    steps.step(
        "the thread is (?:unpinned|archived|deleted) straight away",
        |world, _, _| {
            let action = world.part::<General>().action.clone();
            let asked = question(world)?;
            expect!(
                asked.is_null() || asked.as_object().is_some_and(|o| o.is_empty()),
                "the user was asked {}",
                show(&asked)
            );
            let command = command_of(&action);
            let shown = command.clone();
            world.wait_for_with(
                move |w| commands_of(w, &command).len() == 1,
                move |w| format!("{shown}; the MC has {}", w.describe_commands()),
            )
        },
    );

    // The quit shortcut.
    steps.step(
        "the quit shortcut behaviour is \"(direct|hold|double-click)\"",
        |world, c, _| {
            let label = match c[0].as_str() {
                "direct" => "Direct",
                "hold" => "Hold",
                _ => "Double press",
            };
            choose_row(world, "confirmQuit", label)?;
            watch_quits(world)?;
            expect!(
                setting(world, "confirmQuit") == json!(c[0]),
                "the quit shortcut is {}",
                show(&setting(world, "confirmQuit"))
            );
            expect!(quit_requests(world) == 0, "the app was asked to quit");
            Ok(())
        },
    );
    steps.step("the user presses the quit shortcut", |world, _, _| {
        press_quit_shortcut(world, 80, true)
    });
    steps.step("the app quits at once", |world, _, _| {
        let asked = quit_requests(world);
        expect!(asked == 1, "the app was asked to quit {asked} times");
        Ok(())
    });
    steps.step(
        "the app quits only after the shortcut is held",
        |world, _, _| {
            expect!(quit_requests(world) == 0, "a quick press quit the app");
            // Long after the quick press, so this is not a second press of two.
            world.advance(5000)?;
            press_quit_shortcut(world, quit::HOLD.as_millis() as u64 + 40, true)?;
            let asked = quit_requests(world);
            expect!(asked == 1, "holding asked the app to quit {asked} times");
            Ok(())
        },
    );
    steps.step(
        "the app quits only after the shortcut is pressed twice",
        |world, _, _| {
            expect!(quit_requests(world) == 0, "one press quit the app");
            world.advance(220)?;
            press_quit_shortcut(world, 80, true)?;
            let asked = quit_requests(world);
            expect!(
                asked == 1,
                "the second press asked the app to quit {asked} times"
            );
            Ok(())
        },
    );
    steps.step(
        "the user presses the quit shortcut twice quickly",
        |world, _, _| {
            press_quit_shortcut(world, 80, false)?;
            world.advance(220)?;
            press_quit_shortcut(world, 80, true)
        },
    );

    // Legacy features.
    steps.step("the legacy features section is folded", |world, _, _| {
        for key in [
            "planModeEnabled",
            "contextWindowMeterEnabled",
            "legacySidebarEnabled",
        ] {
            expect!(!row_shown(world, key)?, "{key} is shown");
        }
        let page = general_page(world)?;
        expect!(
            page.shows(world, "Legacy features")?,
            "the page has no legacy features section"
        );
        Ok(())
    });
    steps.step("the user unfolds it", |world, _, _| {
        let page = general_page(world)?;
        let fold = page_item(world, "settingsSection:Legacy features", "fold")?;
        let (x, y) = page.at(world, fold, 0.5, 0.5)?;
        world.click_at(x, y)
    });
    steps.step(
        "the legacy plan mode, context window indicator and per-project sidebar can be turned on",
        |world, _, _| {
            for key in [
                "planModeEnabled",
                "contextWindowMeterEnabled",
                "legacySidebarEnabled",
            ] {
                expect!(
                    row_shown(world, key)? && !setting_on(world, key),
                    "{key} is not offered"
                );
                turn_row(world, key, true)?;
            }
            Ok(())
        },
    );
}
