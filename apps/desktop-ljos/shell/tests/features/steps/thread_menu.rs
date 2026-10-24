//! The thread menu and the MC's side of its actions (desktop-qt's
//! ThreadMenuSteps.cpp): features/threads/menu-actions.feature, and the
//! thread menu's scenarios in threads/menu-and-selection.feature,
//! threads/archive-delete.feature, threads/pinning-and-order.feature,
//! threads/titles.feature and threads/creating.feature.
//!
//! Its helpers are the other domains' way to name a thread, find its
//! sidebar section and change its row (desktop-qt's ThreadList.h).

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use chrono::{DateTime, Duration, SecondsFormat};
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::thread_menu::ThreadMenu;
use hal_c2_shell::controllers::toasts::Toasts;
use serde_json::{Map, Value, json};

use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// What the MC does with the menu's commands and moves.
#[derive(Default)]
pub struct FakeThreadMenu {
    /// Whether the MC's rows follow the thread commands it accepts, as the
    /// real projection does; scenarios about the list turn it on.
    pub project: bool,
    /// hal-c2.moveDestinations' answer, and how hal-c2.moveThread answers.
    pub destinations: Vec<Value>,
    /// Asked once before a move that is not confirmed.
    pub confirm_note: String,
    pub refusal: String,
    pub moves: Vec<Value>,
    /// The section each thread was in before the scenario's change.
    pub section_before: HashMap<String, String>,
    /// The scenario turned the question on itself.
    pub confirm_asked: bool,
}

const NOW: &str = "2026-09-23T10:00:00Z";

fn project_command(mc: &mut FakeMc, command: &Value) {
    if !mc.part::<FakeThreadMenu>().project {
        return;
    }
    let kind = text(&command["type"]);
    let id = text(&command["threadId"]);
    let Some(row) = mc.threads.get_mut(&id).and_then(Value::as_object_mut) else {
        return;
    };
    match kind.as_str() {
        "thread.pin" => {
            row.insert("pinnedAt".into(), json!(NOW));
            let order = command["orderKey"].as_str().unwrap_or("a0");
            row.insert("pinOrderKey".into(), json!(order));
        }
        "thread.unpin" => {
            row.remove("pinnedAt");
            row.remove("pinOrderKey");
        }
        "thread.settle" => {
            row.insert("settledOverride".into(), json!("settled"));
            row.insert("settledAt".into(), json!(NOW));
            // Settling clears the thread's pinned and active places
            // (orchestration.ex), and its snooze.
            for key in [
                "pinnedAt",
                "pinOrderKey",
                "activeOrderKey",
                "snoozedUntil",
                "snoozedAt",
            ] {
                row.remove(key);
            }
        }
        "thread.mark-unread" => {
            // Just before the latest run completed.
            let completed = row
                .get("latestRunCompletedAt")
                .and_then(Value::as_str)
                .and_then(|t| DateTime::parse_from_rfc3339(t).ok());
            if let Some(completed) = completed {
                let visited = (completed - Duration::milliseconds(1))
                    .to_utc()
                    .to_rfc3339_opts(SecondsFormat::Millis, true);
                row.insert("lastVisitedAt".into(), json!(visited));
            }
        }
        "thread.active.reorder" => {
            row.insert("activeOrderKey".into(), command["orderKey"].clone());
        }
        "thread.pin.reorder" => {
            row.insert("pinOrderKey".into(), command["orderKey"].clone());
        }
        "thread.unsettle" => {
            row.remove("settledOverride");
            row.remove("settledAt");
            row.insert("unsettledAt".into(), json!(NOW));
        }
        "thread.visit" => {
            let visited = command["visitedAt"].as_str().unwrap_or(NOW);
            row.insert("lastVisitedAt".into(), json!(visited));
        }
        "thread.snooze" => {
            row.insert("snoozedUntil".into(), command["snoozedUntil"].clone());
            row.insert("snoozedAt".into(), json!(NOW));
        }
        "thread.unsnooze" => {
            row.remove("snoozedUntil");
        }
        "thread.archive" => {
            row.insert("archivedAt".into(), json!(NOW));
        }
        "thread.unarchive" => {
            row.remove("archivedAt");
        }
        "thread.delete" => {
            let mut gone = mc.threads.remove(&id).unwrap_or_else(|| json!({}));
            gone["deletedAt"] = json!(NOW);
            mc.send_row(&id, &gone);
            return;
        }
        _ => return,
    }
    let row = mc.threads[&id].clone();
    mc.send_row(&id, &row);
}

/// Answers a move the cluster's scenarios (MoveSteps) own; false leaves it
/// to the menu's fake. Set by the move steps' extension.
pub type MachineMove = fn(&mut FakeMc, &Rpc) -> bool;

#[derive(Default)]
pub struct MoveHook(pub Option<MachineMove>);

fn machine_move(mc: &mut FakeMc, rpc: &Rpc) -> bool {
    match mc.part::<MoveHook>().0 {
        Some(answer) => answer(mc, rpc),
        None => false,
    }
}

fn extension(mc: &mut FakeMc) {
    mc.effects.push(Rc::new(project_command));
    mc.on_rpc("hal-c2.moveDestinations", |mc, rpc| {
        if machine_move(mc, rpc) {
            return Ok(());
        }
        let destinations = Value::Array(mc.part::<FakeThreadMenu>().destinations.clone());
        mc.reply(rpc, destinations);
        Ok(())
    });
    mc.on_rpc("hal-c2.moveThread", |mc, rpc| {
        if machine_move(mc, rpc) {
            return Ok(());
        }
        let fake = mc.part::<FakeThreadMenu>();
        fake.moves.push(rpc.payload.clone());
        let (refusal, note) = (fake.refusal.clone(), fake.confirm_note.clone());
        if !refusal.is_empty() {
            mc.refuse(rpc, &refusal);
            return Ok(());
        }
        if !note.is_empty() && !rpc.payload["confirmed"].as_bool().unwrap_or(false) {
            mc.reply(
                rpc,
                json!({"status": "confirm", "message": "Confirm the move", "notes": [note]}),
            );
            return Ok(());
        }
        let id = text(&rpc.payload["threadId"]);
        // A move names its destination by environment id; the MC answers
        // with the machine's label.
        let environment = text(&rpc.payload["machine"]);
        let machine = mc
            .peers
            .get(&environment)
            .cloned()
            .unwrap_or_else(|| environment.clone());
        let title = mc
            .threads
            .get(&id)
            .map(|row| text(&row["title"]))
            .unwrap_or_default();
        mc.reply(
            rpc,
            json!({
                "status": "moved",
                "threadId": id,
                "machine": machine,
                "environmentId": environment,
                "message": format!("{title} moved to {machine}."),
            }),
        );
        Ok(())
    });
}

pub fn fake(world: &mut World) -> &mut FakeThreadMenu {
    world.mc.part::<FakeThreadMenu>()
}

type Maker = Rc<dyn Fn(&mut World) -> Outcome>;

thread_local! {
    static PROVIDED: RefCell<HashMap<String, Maker>> = RefCell::new(HashMap::new());
}

/// Makes the thread titled `title` the first time a step names it, for the
/// scenarios whose background does not.
pub fn provide_thread(title: &str, make: impl Fn(&mut World) -> Outcome + 'static) {
    PROVIDED.with(|p| p.borrow_mut().insert(title.to_owned(), Rc::new(make)));
}

fn titled(world: &World, title: &str) -> Option<String> {
    world
        .mc
        .threads
        .iter()
        .find(|(_, row)| text(&row["title"]) == title)
        .map(|(id, _)| format!("{}:{id}", world.mc.environment_id))
}

/// A thread by key (`env-a:t1`) or by title.
pub fn key_of(world: &mut World, thread: &str) -> Outcome<String> {
    if thread.contains(':') {
        return Ok(thread.to_owned());
    }
    if let Some(key) = titled(world, thread) {
        return Ok(key);
    }
    let maker = PROVIDED.with(|p| p.borrow().get(thread).cloned());
    if let Some(make) = maker {
        make(world)?;
        if let Some(key) = titled(world, thread) {
            return Ok(key);
        }
    }
    fail!("no thread is titled \"{thread}\"")
}

pub fn id_of(world: &mut World, thread: &str) -> Outcome<String> {
    let key = key_of(world, thread)?;
    Ok(id_in(&key).to_owned())
}

/// The thread id in a thread key.
pub fn id_in(key: &str) -> &str {
    key.split_once(':').map_or(key, |(_, id)| id)
}

pub fn items(world: &World) -> Vec<Value> {
    at(&world.state("menu"), "items")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

pub fn item(world: &World, id: &str) -> Option<Value> {
    items(world)
        .into_iter()
        .find(|entry| text(&entry["id"]) == id)
}

fn menu_is(world: &World) -> String {
    format!("the menu is {}", show(&Value::Array(items(world))))
}

pub fn open_menu_at(world: &mut World, thread: &str, x: f64, y: f64) -> Outcome {
    world.sync()?;
    let key = key_of(world, thread)?;
    world.dispatch("thread.menu", json!({"key": key, "x": x, "y": y}))?;
    expect!(
        world.state("menu").is_object(),
        "no menu opened for {thread}"
    );
    Ok(())
}

pub fn open_menu(world: &mut World, thread: &str) -> Outcome {
    open_menu_at(world, thread, 40.0, 120.0)
}

pub fn pick(world: &mut World, id: &str) -> Outcome {
    let menu = world.state("menu");
    expect!(menu.is_object(), "no menu is open");
    world.dispatch(
        "menu.select",
        json!({"requestId": menu["requestId"], "id": id}),
    )
}

pub fn answer(world: &mut World, accepted: bool) -> Outcome {
    world.sync()?; // the MC's answer can ask it
    let question = world.state("confirmation");
    expect!(question.is_object(), "no question is asked");
    world.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": accepted}),
    )
}

pub fn set_device(world: &mut World, key: &str, value: Value) -> Outcome {
    let engine = world.engine().clone();
    let settings = Settings::of(&engine);
    let mut device = settings.device();
    device.insert(key.to_owned(), value);
    expect!(
        settings.set_device_settings(&engine, device),
        "the preferences were not saved"
    );
    world.pump()
}

/// The thread the route shows, empty when it shows none.
pub fn route_thread(world: &World) -> String {
    world
        .with::<Navigation, _>(|navigation, _| navigation.thread_key().to_owned())
        .unwrap_or_default()
}

pub fn view(world: &mut World, key: &str) -> Outcome {
    let route = Route::Thread(key.to_owned());
    world.with::<Navigation, _>(|navigation, engine| navigation.open(engine, route))?;
    world.wait_for_with(
        |w| text(at(&w.state("workspace"), "threadKey")) == key,
        |_| format!("the header to show {key}"),
    )
}

/// The sidebar section listing the thread `key`, empty when none does.
pub fn section_of(world: &World, key: &str) -> String {
    let sidebar = world.state("sidebar");
    for section in ["pinned", "active", "settled", "snoozed"] {
        let rows = sidebar[section].as_array().into_iter().flatten();
        if rows.into_iter().any(|row| text(&row["key"]) == key) {
            return section.to_owned();
        }
    }
    String::new()
}

pub fn thread(id: &str, title: &str, project: &str, created_at: &str) -> Value {
    json!({"id": id, "title": title, "projectId": project, "createdAt": created_at, "updatedAt": created_at})
}

pub fn project(id: &str) -> Value {
    json!({
        "id": id,
        "title": id,
        "workspaceRoot": format!("/work/{id}"),
        "scripts": [],
        "createdAt": "2026-09-01T09:00:00Z",
        "updatedAt": "2026-09-01T09:00:00Z",
    })
}

/// Changes the MC's row for the thread `id` and sends it.
pub fn update_row(
    world: &mut World,
    id: &str,
    change: impl FnOnce(&mut Map<String, Value>),
) -> Outcome {
    let row = world
        .mc
        .threads
        .entry(id.to_owned())
        .or_insert_with(|| json!({}));
    if let Some(fields) = row.as_object_mut() {
        change(fields);
    }
    let row = row.clone();
    world.mc.send_row(id, &row);
    world.sync()
}

/// The MC's rows follow the thread commands it accepts.
pub fn project_thread_commands(world: &mut World) {
    fake(world).project = true;
}

/// The web menu's names for its items, as the ledger reads them.
fn item_id(phrase: &str) -> String {
    if phrase.starts_with("new thread on") {
        return "new-thread-on-branch".into();
    }
    if phrase.starts_with("filter by") {
        return "filter-by-project".into();
    }
    match phrase {
        "regenerate title" => "regenerate-title",
        "mark unread" => "mark-unread",
        "project settings" => "project-settings",
        other => other,
    }
    .to_owned()
}

fn pin(row: &mut Map<String, Value>) {
    row.insert("pinnedAt".into(), json!("2026-09-23T09:30:00Z"));
    row.insert("pinOrderKey".into(), json!("a0"));
}

fn route_is(world: &World) -> String {
    format!("the route is {}", show(&world.state("route")))
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // Backgrounds.
    steps.step(
        &format!(
            "a connected environment with the thread {Q} on the branch {Q} in the project {Q}"
        ),
        |world, c, _| {
            world.mc.projects.insert(c[2].clone(), project(&c[2]));
            world.mc.projects.insert("docs".into(), project("docs"));
            let mut row = thread("t1", &c[0], &c[2], "2026-09-23T09:00:00Z");
            row["branch"] = json!(c[1]);
            world.mc.threads.insert("t1".into(), row);
            world.mc.threads.insert(
                "t9".into(),
                thread("t9", "Write docs", "docs", "2026-09-23T08:00:00Z"),
            );
            world.connect()?;
            let key = format!("{}:t1", world.mc.environment_id);
            view(world, &key)
        },
    );
    steps.step(
        &format!("a connected environment with the idle thread {Q}(?: in the project {Q})?"),
        |world, c, _| {
            fake(world).project = true;
            let project_id = match c.get(1) {
                Some(p) if !p.is_empty() => p.clone(),
                _ => "shop".to_owned(),
            };
            world
                .mc
                .projects
                .insert(project_id.clone(), project(&project_id));
            world.mc.threads.insert(
                "t1".into(),
                thread("t1", &c[0], &project_id, "2026-09-23T09:00:00Z"),
            );
            world.connect()?;
            let key = format!("{}:t1", world.mc.environment_id);
            view(world, &key)
        },
    );
    steps.step(
        &format!("a connected environment with the active threads {Q}, {Q} and {Q}"),
        |world, c, _| {
            fake(world).project = true;
            world.mc.projects.insert("shop".into(), project("shop"));
            for (index, title) in c.iter().take(3).enumerate() {
                let id = format!("t{}", index + 1);
                let created = format!("2026-09-23T09:0{}:00Z", 5 - index);
                world
                    .mc
                    .threads
                    .insert(id.clone(), thread(&id, title, "shop", &created));
            }
            world.connect()?;
            world.sync()
        },
    );

    // The menu.
    steps.step(
        &format!("the user opens the (?:thread )?menu for {Q}(?: at (\\d+), (\\d+))?"),
        |world, c, _| match (
            c.get(1).and_then(|x| x.parse().ok()),
            c.get(2).and_then(|y| y.parse().ok()),
        ) {
            (Some(x), Some(y)) => open_menu_at(world, &c[0], x, y),
            _ => open_menu(world, &c[0]),
        },
    );
    steps.step("the user opens the thread(?:'s)? menu", |world, _, _| {
        let key = route_thread(world);
        open_menu(world, &key)
    });
    steps.step(
        "the user opens the header's title menu at (\\d+), (\\d+)",
        |world, c, _| {
            let (x, y): (f64, f64) = (c[0].parse().unwrap_or(0.0), c[1].parse().unwrap_or(0.0));
            world.dispatch("workspace.titleMenu", json!({"x": x, "y": y}))
        },
    );
    steps.step(
        &format!("the actions for {Q} are offered"),
        |world, _, _| {
            expect!(item(world, "archive").is_some(), "{}", menu_is(world));
            Ok(())
        },
    );
    steps.step(
        &format!("the menu (offers|does not offer) {Q}"),
        |world, c, _| {
            expect!(
                item(world, &c[1]).is_some() == (c[0] == "offers"),
                "{}",
                menu_is(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("only these of the menu's actions can be chosen: {Q}"),
        |world, c, _| {
            let enabled: Vec<String> = items(world)
                .iter()
                .filter(|entry| entry["enabled"].as_bool().unwrap_or(false))
                .map(|entry| text(&entry["id"]))
                .collect();
            let enabled = enabled.join(", ");
            expect!(enabled == c[0], "the menu can choose \"{enabled}\"");
            Ok(())
        },
    );
    // Fork and Move are the fork's additions, specified in the native
    // feature; moving a thread up or down is threads/pinning-and-order's.
    steps.step("the actions read, in order: (.+)", |world, c, _| {
        let expected: Vec<String> = c[0].split(", ").map(item_id).collect();
        let actual: Vec<String> = items(world)
            .iter()
            .map(|entry| text(&entry["id"]))
            .filter(|id| id != "fork" && !id.starts_with("move"))
            .collect();
        expect!(actual == expected, "the menu reads {}", actual.join(", "));
        let named = regex::Regex::new(Q)
            .ok()
            .and_then(|q| q.captures(&c[0]).map(|m| m[1].to_owned()))
            .unwrap_or_default();
        let labelled = item(world, "new-thread-on-branch")
            .is_some_and(|branch| text(&branch["label"]) == format!("New thread on {named}"));
        expect!(labelled, "{}", menu_is(world));
        Ok(())
    });
    steps.step(
        "the environment does not support (snoozing or pinning|title regeneration)",
        |world, c, _| {
            let capabilities = &mut world.mc.capabilities;
            if !capabilities.is_object() {
                *capabilities = json!({});
            }
            if c[0] == "title regeneration" {
                capabilities["threadTitleRegeneration"] = json!(false);
            } else {
                capabilities["threadSnooze"] = json!(false);
                capabilities["threadPinning"] = json!(false);
            }
            world.mc.send_snapshot();
            world.sync()
        },
    );
    steps.step("snoozing and pinning are not offered", |world, _, _| {
        expect!(
            item(world, "snooze").is_none() && item(world, "pin").is_none(),
            "{}",
            menu_is(world)
        );
        Ok(())
    });
    steps.step("archiving is still offered", |world, _, _| {
        expect!(item(world, "archive").is_some(), "{}", menu_is(world));
        Ok(())
    });
    steps.step(
        "(archiving|regenerating the title) is unavailable( and shows it is in progress)?",
        |world, c, _| {
            let id = if c[0] == "archiving" {
                "archive"
            } else {
                "regenerate-title"
            };
            let entry = item(world, id);
            let in_progress = c.get(1).is_some_and(|s| !s.is_empty());
            let enabled = |e: &Value| e["enabled"].as_bool().unwrap_or(false);
            if c[0] == "regenerating the title" && !in_progress {
                expect!(
                    entry.as_ref().is_none_or(|e| !enabled(e)),
                    "{}",
                    menu_is(world)
                );
                return Ok(());
            }
            let Some(entry) = entry.filter(|e| !enabled(e)) else {
                fail!("{}", menu_is(world));
            };
            if in_progress {
                expect!(
                    text(&entry["label"]) == "Regenerating…",
                    "the item is {}",
                    show(&entry)
                );
            }
            Ok(())
        },
    );
    steps.step(
        &format!("a new title is already being generated for {Q}"),
        |world, c, _| {
            let id = id_of(world, &c[0])?;
            update_row(world, &id, |row| {
                row.insert(
                    "titleRegeneration".into(),
                    json!({"requestId": "c1", "startedAt": "2026-09-23T09:59:00Z"}),
                );
            })
        },
    );
    steps.step(&format!("the agent is working in {Q}"), |world, c, _| {
        let id = id_of(world, &c[0])?;
        update_row(world, &id, |row| {
            row.insert("latestRunId".into(), json!("r1"));
            row.insert("activeRunId".into(), json!("r1"));
            row.insert("status".into(), json!("running"));
        })
    });

    // Copying.
    steps.step(
        &format!("the user copies the (path|branch|thread id) of {Q}"),
        |world, c, _| {
            open_menu(world, &c[1])?;
            let id = match c[0].as_str() {
                "path" => "copy-path",
                "branch" => "copy-branch",
                _ => "copy-thread-id",
            };
            pick(world, id)
        },
    );
    steps.step(
        &format!("the user copies a reference to {Q}"),
        |world, c, _| {
            world.sync()?;
            let key = key_of(world, &c[0])?;
            world.with::<ThreadMenu, _>(|menu, engine| menu.copy_reference(engine, &key))?;
            world.pump()
        },
    );
    steps.step("the clipboard holds (.+)", |world, c, _| {
        let said = c[0].as_str();
        let expected = if said == "the thread's workspace path" {
            "/work/shop".to_owned()
        } else if said == "the pull request address" {
            "https://github.com/acme/shop/pull/7".to_owned()
        } else if said == "the thread id" {
            "t1".to_owned()
        } else if let Some(named) = said.strip_prefix("the id of \"") {
            id_of(world, named.trim_end_matches('"'))?
        } else if said.starts_with('"') {
            said.trim_matches('"').to_owned()
        } else {
            said.to_owned()
        };
        world.sync()?;
        let held = world.clipboard();
        expect!(held == expected, "the clipboard holds \"{held}\"");
        Ok(())
    });
    steps.step(&format!("{Q} has no workspace path"), |world, c, _| {
        let id = id_of(world, &c[0])?;
        let project_id = world
            .mc
            .threads
            .get(&id)
            .map(|row| text(&row["projectId"]))
            .unwrap_or_default();
        let mut row = world
            .mc
            .projects
            .get(&project_id)
            .cloned()
            .unwrap_or_else(|| json!({}));
        row["workspaceRoot"] = json!("");
        world.mc.projects.insert(project_id.clone(), row.clone());
        world.mc.send_row_of(&project_id, &row, "project");
        world.sync()
    });
    steps.step("the clipboard cannot be written", |world, _, _| {
        world.set_clipboard_fails(true);
        Ok(())
    });
    steps.step(
        &format!("{Q} (is linked to a pull request|has no pull request)"),
        |world, c, _| {
            if c[1] == "has no pull request" {
                return Ok(());
            }
            let id = id_of(world, &c[0])?;
            update_row(world, &id, |row| {
                row.insert(
                    "linkedPullRequest".into(),
                    json!({
                        "projectId": "shop",
                        "repository": "acme/shop",
                        "number": 7,
                        "url": "https://github.com/acme/shop/pull/7",
                    }),
                );
            })
        },
    );

    // Filtering and project settings.
    steps.step(
        &format!("the user filters by the project of {Q}"),
        |world, c, _| {
            open_menu(world, &c[0])?;
            pick(world, "filter-by-project")
        },
    );
    steps.step("the user shows all projects again", |world, _, _| {
        let key = format!("{}:t1", world.mc.environment_id);
        open_menu(world, &key)?;
        let shown = item(world, "filter-by-project")
            .is_some_and(|entry| text(&entry["label"]) == "Show all projects");
        expect!(shown, "{}", menu_is(world));
        pick(world, "filter-by-project")
    });
    steps.step(
        &format!("(only threads from {Q}|threads from every project) (?:are|is) listed"),
        |world, c, _| {
            world.sync()?;
            let mut projects: Vec<String> = world.state("sidebar")["active"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|row| text(&row["projectKey"]))
                .collect();
            projects.sort();
            projects.dedup();
            match c.get(1).filter(|p| !p.is_empty()) {
                Some(named) => {
                    let wanted = world.project_key(named);
                    expect!(
                        projects == [wanted],
                        "the list shows {}",
                        projects.join(", ")
                    );
                }
                None => expect!(projects.len() > 1, "the list shows {}", projects.join(", ")),
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the user opens the project settings from {Q}"),
        |world, c, _| {
            open_menu(world, &c[0])?;
            pick(world, "project-settings")
        },
    );
    steps.step(&format!("the settings for {Q} open"), |world, c, _| {
        world.sync()?;
        let route = world.state("route");
        let wanted = world.project_key(&c[0]);
        expect!(
            text(&route["kind"]) == "settings" && text(&route["projectKey"]) == wanted,
            "the route is {}",
            show(&route)
        );
        Ok(())
    });

    // Archiving, deleting, pinning.
    steps.step(
        "the user asked to confirm before (archiving|deleting|unpinning)",
        |world, c, _| {
            let key = match c[0].as_str() {
                "archiving" => "confirmThreadArchive",
                "deleting" => "confirmThreadDelete",
                _ => "confirmThreadUnpin",
            };
            set_device(world, key, json!(true))?;
            fake(world).confirm_asked = true;
            Ok(())
        },
    );
    // A scenario that did not ask for the question is about the delete: the
    // question deleting asks by default is answered yes.
    steps.step(
        &format!("the user (archives|deletes|pins|unpins) {Q}"),
        |world, c, _| {
            open_menu(world, &c[1])?;
            let id = match c[0].as_str() {
                "archives" => "archive",
                "deletes" => "delete",
                verb => verb.trim_end_matches('s'),
            }
            .to_owned();
            pick(world, &id)?;
            if id == "delete" && !fake(world).confirm_asked {
                answer(world, true)?;
            }
            Ok(())
        },
    );
    steps.step(&format!("the user is asked {Q}"), |world, c, _| {
        let question = world.state("confirmation");
        let asked = text(&question["title"]);
        let description = text(&question["description"]);
        let expected = c[0].replace('\'', "\"");
        expect!(
            asked == expected || format!("{asked} {description}") == expected,
            "the question is {}",
            show(&question)
        );
        Ok(())
    });
    steps.step(
        "the user is warned that deleting clears the conversation history",
        |world, _, _| {
            let question = world.state("confirmation");
            expect!(
                text(&question["description"]).contains("clears conversation history")
                    && question["destructive"].as_bool().unwrap_or(false),
                "the question is {}",
                show(&question)
            );
            Ok(())
        },
    );
    steps.step("the user (confirms|cancels) the question", |world, c, _| {
        answer(world, c[0] == "confirms")
    });
    steps.step(
        &format!("{Q} stays pinned until the user confirms"),
        |world, c, _| {
            world.sync()?;
            let key = key_of(world, &c[0])?;
            expect!(
                world.mc.commands.is_empty() && section_of(world, &key) == "pinned",
                "the MC has {}",
                world.describe_commands()
            );
            answer(world, true)?;
            world.wait_for("the thread to be unpinned", |w| {
                section_of(w, &key) == "active"
            })
        },
    );
    steps.step(&format!("{Q} is pinned"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        if world.checking {
            return world.wait_for_with(
                |w| section_of(w, &key) == "pinned",
                |w| format!("{} pinned; it is in \"{}\"", c[0], section_of(w, &key)),
            );
        }
        update_row(world, id_in(&key), pin)
    });
    steps.step(
        &format!("{Q} (moves to the pinned section|returns to its place among the active threads)"),
        |world, c, _| {
            let section = if c[1].starts_with("moves") {
                "pinned"
            } else {
                "active"
            };
            let key = key_of(world, &c[0])?;
            world.wait_for_with(
                |w| section_of(w, &key) == section,
                |w| {
                    format!(
                        "{} in {section}; it is in \"{}\"",
                        c[0],
                        section_of(w, &key)
                    )
                },
            )
        },
    );
    steps.step(
        &format!("every connected device shows {Q} as pinned"),
        |world, c, _| {
            let id = id_of(world, &c[0])?;
            let pinned = world
                .mc
                .threads
                .get(&id)
                .is_some_and(|row| row.get("pinnedAt").is_some());
            expect!(pinned, "the MC's row is not pinned");
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is the top remaining thread in {Q}"),
        |world, c, _| {
            let project_id = world
                .mc
                .threads
                .get("t1")
                .map(|row| text(&row["projectId"]))
                .unwrap_or_default();
            let row = thread("t2", &c[0], &project_id, "2026-09-23T08:00:00Z");
            world.mc.threads.insert("t2".into(), row.clone());
            world.mc.send_row("t2", &row);
            world.sync()
        },
    );
    steps.step(&format!("{Q} is an older thread in {Q}"), |world, c, _| {
        let row = thread("t3", &c[0], &c[1], "2026-09-23T07:00:00Z");
        world.mc.threads.insert("t3".into(), row.clone());
        world.mc.send_row("t3", &row);
        world.sync()
    });
    steps.step(&format!("{Q} opens"), |world, c, _| {
        world.sync()?; // a thread the MC just made is listed by now
        if super::files_viewer::file_opened(world, &c[0])? {
            return Ok(());
        }
        let key = key_of(world, &c[0])?;
        world.wait_for_with(
            |w| route_thread(w) == key,
            |w| format!("{key} to open; {}", route_is(w)),
        )
    });
    steps.step(
        &format!("{Q} is listed in the pinned section above {Q} and {Q}"),
        |world, c, _| {
            let keys = [
                key_of(world, &c[0])?,
                key_of(world, &c[1])?,
                key_of(world, &c[2])?,
            ];
            expect!(
                section_of(world, &keys[0]) == "pinned"
                    && section_of(world, &keys[1]) == "active"
                    && section_of(world, &keys[2]) == "active",
                "the list is {}",
                show(&world.state("sidebar"))
            );
            Ok(())
        },
    );

    // Undo.
    steps.step(
        &format!("the user just (unpinned|settled|snoozed|archived) {Q}"),
        |world, c, _| {
            let key = key_of(world, &c[1])?;
            if c[0] == "unpinned" {
                update_row(world, id_in(&key), pin)?;
            }
            world.sync()?;
            let before = section_of(world, &key);
            fake(world)
                .section_before
                .insert(key.clone(), before.clone());
            open_menu(world, &key)?;
            if c[0] == "snoozed" {
                let Some(snooze) = item(world, "snooze") else {
                    fail!("{}", menu_is(world));
                };
                let first = text(&snooze["children"][0]["id"]);
                pick(world, &first)?;
            } else {
                let id = match c[0].as_str() {
                    "unpinned" => "unpin",
                    "settled" => "settle",
                    _ => "archive",
                };
                pick(world, id)?;
            }
            world.wait_for("the change to land", |w| section_of(w, &key) != before)
        },
    );
    steps.step(
        "the user undoes the change(?: within five seconds)?",
        |world, _, _| {
            world.sync()?;
            undo(world)
        },
    );
    steps.step(
        &format!("one notice reads {Q} and names the undo shortcut"),
        |world, c, _| {
            let shown = |w: &World| {
                w.state("toasts")["items"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
            };
            world.wait_for_with(
                |w| {
                    let toasts = shown(w);
                    toasts.len() == 1
                        && text(&toasts[0]["title"]) == c[0]
                        && text(&toasts[0]["description"]).ends_with(" to undo")
                },
                |w| {
                    format!(
                        "one notice \"{}\"; the toasts are {}",
                        c[0],
                        show(&Value::Array(shown(w)))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("{Q} is back where it was before"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            let before = fake(world)
                .section_before
                .get(&key)
                .cloned()
                .unwrap_or_default();
            world.wait_for_with(
                |w| section_of(w, &key) == before,
                |w| {
                    format!(
                        "{} in \"{before}\"; it is in \"{}\"",
                        c[0],
                        section_of(w, &key)
                    )
                },
            )
        },
    );
    steps.step(
        &format!("{Q} is restored and opened again"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            world.wait_for_with(
                |w| !section_of(w, &key).is_empty() && route_thread(w) == key,
                |w| format!("{key} back and open; {}", route_is(w)),
            )
        },
    );
    steps.step("five seconds pass", |world, _, _| {
        let later = world.now() + Duration::seconds(5);
        world.set_time(later);
        Ok(())
    });
    steps.step("the change can no longer be undone", |world, _, _| {
        let before = world.mc.commands.len();
        undo(world)?;
        world.sync()?;
        expect!(
            world.mc.commands.len() == before,
            "the MC has {}",
            world.describe_commands()
        );
        Ok(())
    });

    // Viewing, renaming, forking.
    steps.step(&format!("the user is viewing {Q}"), |world, c, _| {
        world.sync()?;
        let key = key_of(world, &c[0])?;
        view(world, &key)
    });
    steps.step(&format!("the header is renaming {Q}"), |world, c, _| {
        world.wait_for_with(
            |w| {
                let state = w.state("workspace");
                text(&state["threadTitle"]) == c[0]
                    && state["renameRequestId"].as_i64().unwrap_or(0) > 0
            },
            |w| format!("the header is {}", show(&w.state("workspace"))),
        )
    });
    steps.step(&format!("the MC is asked to fork {Q}"), |world, c, _| {
        world.sync()?;
        let asked = world.mc.commands.iter().any(|command| {
            text(&command["type"]) == "thread.fork"
                && text(&command["sourceThreadId"]) == c[0]
                && text(at(command, "sourcePoint.type")) == "latest_stable"
        });
        expect!(asked, "the MC has {}", world.describe_commands());
        Ok(())
    });
    steps.step("the window shows the fork", |world, _, _| {
        world.sync()?;
        let target = world
            .mc
            .commands
            .iter()
            .rev()
            .find(|command| text(&command["type"]) == "thread.fork")
            .map(|command| text(&command["targetThreadId"]))
            .unwrap_or_default();
        let key = format!("{}:{target}", world.mc.environment_id);
        expect!(
            !target.is_empty() && route_thread(world) == key,
            "{}",
            route_is(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the window shows the thread {Q}"),
        |world, c, _| world.wait_for_with(|w| route_thread(w) == c[0], route_is),
    );

    // Starting a thread on another thread's branch.
    steps.step(
        &format!("the current thread is on the branch {Q}"),
        |world, c, _| {
            world.sync()?;
            let key = route_thread(world);
            expect!(!key.is_empty(), "no thread is open");
            let branch = c[0].clone();
            update_row(world, id_in(&key), move |row| {
                row.insert(
                    "worktreePath".into(),
                    json!(format!("/work/wt-{}", branch.replace('/', "-"))),
                );
                row.insert("branch".into(), json!(branch));
            })
        },
    );
    steps.step(
        "the user starts a new thread on that branch from the thread menu",
        |world, _, _| {
            let key = route_thread(world);
            open_menu(world, &key)?;
            pick(world, "new-thread-on-branch")
        },
    );
    steps.step(
        "a draft opens in the same worktree as the current thread",
        |world, _, _| {
            world.sync()?;
            let route = world.state("route");
            expect!(
                text(&route["kind"]) == "draft",
                "the route is {}",
                show(&route)
            );
            let draft = text(&route["draftId"]);
            let checkout = hal_c2_shell::controllers::workspace::checkout(world.engine(), &draft);
            expect!(
                checkout.env_mode == "worktree"
                    && checkout.worktree_path.as_deref() == Some("/work/wt-feature-cart")
                    && checkout.branch.as_deref() == Some("feature/cart"),
                "the draft is in {} on {}",
                checkout
                    .worktree_path
                    .clone()
                    .unwrap_or(checkout.env_mode.clone()),
                checkout.branch.clone().unwrap_or_default()
            );
            Ok(())
        },
    );

    // Moving.
    steps.step(
        &format!("the MC can move {Q} to {Q}(?: and to {Q}, which is offline)?(?: once told {Q})?(?: but refuses with {Q})?"),
        |world, c, _| {
            let environment = environment_of(world, &c[1]);
            let offline = c.get(2).filter(|s| !s.is_empty()).cloned();
            let (note, refusal) = (c.get(3).cloned().unwrap_or_default(), c.get(4).cloned().unwrap_or_default());
            let fake = fake(world);
            fake.destinations.push(
                json!({"machine": c[1], "environmentId": environment, "online": true, "projects": []}),
            );
            if let Some(offline) = offline {
                fake.destinations.push(
                    json!({"machine": offline, "environmentId": "env-c", "online": false, "projects": []}),
                );
            }
            fake.confirm_note = note;
            fake.refusal = refusal;
            Ok(())
        },
    );
    steps.step(
        &format!("the MC is asked to move {Q} to {Q}( confirmed)?"),
        |world, c, _| {
            let environment = environment_of(world, &c[1]);
            let confirmed = c.get(2).is_some_and(|s| !s.is_empty());
            world.wait_for_with(
                |w| {
                    w.mc.peek::<FakeThreadMenu>().is_some_and(|fake| {
                        fake.moves.iter().any(|m| {
                            text(&m["threadId"]) == c[0]
                                && text(&m["machine"]) == environment
                                && m["confirmed"].as_bool().unwrap_or(false) == confirmed
                        })
                    })
                },
                |w| {
                    let asked =
                        w.mc.peek::<FakeThreadMenu>()
                            .map_or(0, |fake| fake.moves.len());
                    format!("the moves asked are {asked}")
                },
            )
        },
    );
}

/// The environment the cluster's member `machine` serves (QHash::key).
pub fn environment_of(world: &World, machine: &str) -> String {
    world
        .mc
        .peers
        .iter()
        .find(|(_, name)| name.as_str() == machine)
        .map(|(environment, _)| environment.clone())
        .unwrap_or_default()
}

/// The newest toast's Undo (ThreadMenuController::undo).
pub fn undo(world: &mut World) -> Outcome {
    world
        .with::<Toasts, _>(|toasts, engine| toasts.run_action(engine, "Undo"))
        .map_err(|e| Failure(e.0))?;
    world.pump()
}
