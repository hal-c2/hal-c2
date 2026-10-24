//! The command palette (desktop-qt's PaletteSteps.cpp:
//! features/navigation/command-palette.feature, and opening it from the
//! thread list in features/threads/search.feature): a project with more
//! threads than the palette's recent list holds, threads on other MCs of the
//! cluster, and the palette driven as the CommandPalette brick drives it.
//! The brick's own keys (mod+1..9) are in keybinding.rs.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;

use chrono::Duration;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::drafts;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::palette::Palette;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::theme::Themes;
use serde_json::{Value, json};

use super::add_project::{
    count, highlighted, id_at, is_open, kind_at, prop, role, role_text, searching, set_query,
};
use super::fake_files::fake_files;
use super::keybinding::press_key;
use super::pull_request::{link as link_pull_request, read_tab, wait_for_row};
use super::stream::{PEER, PEER_ENVIRONMENT, iso, now};
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const PROJECT: &str = "hal-c2";
const BACKGROUND_THREADS: i64 = 14;

#[derive(Default)]
struct PaletteState {
    /// The engine the `ran` hook is on (a restart makes a new one).
    hooked: Option<usize>,
    minute: i64,
    /// Thread keys by title, oldest first.
    keys: HashMap<String, Vec<String>>,
    /// The thread a scenario is about.
    that: String,
    /// What the palette listed when it was opened, as "kind\nid".
    listed: Vec<String>,
    ran: Rc<RefCell<Vec<String>>>,
}

/// What each thread's messages say (by thread id, on this MC), for
/// `orchestration.searchThreads`; answers wait while the MC holds "messages".
#[derive(Default)]
struct FakeMessages {
    text: BTreeMap<String, String>,
    asked: usize,
}

fn extension(mc: &mut FakeMc) {
    mc.on_rpc("orchestration.searchThreads", |mc, rpc| {
        mc.part::<FakeMessages>().asked += 1;
        let rpc = rpc.clone();
        let answer = move |mc: &mut FakeMc| {
            let query = text(&rpc.payload["query"]).to_lowercase();
            let mut matches = Vec::new();
            if rpc.environment.is_empty() || rpc.environment == mc.environment_id {
                for (id, said) in &mc.part::<FakeMessages>().text {
                    if said.to_lowercase().contains(&query) {
                        matches.push(json!({"threadId": id, "snippet": said}));
                    }
                }
            }
            mc.reply(&rpc, json!({"matches": matches}));
        };
        if mc.holding("messages") {
            mc.defer(answer);
        } else {
            answer(mc);
        }
        Ok(())
    });
}

fn state(world: &mut World) -> &mut PaletteState {
    world.mc.part::<PaletteState>()
}

/// The palette, with the commands it ran noted.
fn hook(world: &mut World) {
    let engine = world.engine() as *const _ as usize;
    if state(world).hooked == Some(engine) {
        return;
    }
    let ran = state(world).ran.clone();
    state(world).hooked = Some(engine);
    Commands::of(world.engine()).on_ran(move |_, command| {
        ran.borrow_mut().push(command.to_owned());
    });
}

/// Changes the palette as its brick does, then shows what changed.
pub fn act<R>(
    world: &mut World,
    f: impl FnOnce(&mut Palette, &ljos::prelude::Engine) -> R,
) -> Outcome<R> {
    let done = world.with::<Palette, _>(|p, engine| {
        let done = f(p, engine);
        p.sync(engine);
        done
    })?;
    world.pump()?;
    Ok(done)
}

struct Listed {
    title: String,
    description: String,
    group: String,
    kind: String,
    id: String,
}

fn snapshot(world: &World) -> Vec<Listed> {
    (0..count(world))
        .map(|row| Listed {
            title: role_text(world, row, "title"),
            description: role_text(world, row, "description"),
            group: role_text(world, row, "group"),
            kind: kind_at(world, row),
            id: id_at(world, row),
        })
        .collect()
}

/// What the palette lists once its searches against the MC are answered.
fn rows(world: &mut World) -> Outcome<Vec<Listed>> {
    world.sync()?;
    hook(world);
    world.wait_for("the palette's searches to be answered", |w| !searching(w))?;
    Ok(snapshot(world))
}

fn describe(world: &World) -> String {
    let lines: Vec<String> = snapshot(world)
        .iter()
        .map(|row| format!("{}: {} ({})", row.group, row.title, row.description))
        .collect();
    format!(
        "the palette ({}, submenu \"{}\", query \"{}\") lists [{}]",
        if is_open(world) { "open" } else { "closed" },
        current_submenu(world),
        prop(world, "query").unwrap_or_default(),
        lines.join("; ")
    )
}

fn index_of(world: &mut World, title: &str, kind: &str) -> Outcome<Option<usize>> {
    let listed = rows(world)?;
    Ok(listed
        .iter()
        .position(|row| row.title == title && (kind.is_empty() || row.kind == kind)))
}

/// A shortcut (mod+k by default), as the window's shortcut hands it to the shell.
fn press_toggle(world: &mut World, key: &str) -> Outcome {
    press_key(world, key)?;
    hook(world);
    world.sync()
}

/// A mode as the scenarios name it, as the palette names it, and its key.
fn mode_of(name: &str) -> &'static str {
    match name {
        "go to file" => "files",
        "project search" => "content",
        _ => "command",
    }
}

fn shortcut_of(name: &str) -> &'static str {
    match name {
        "go to file" => "mod+p",
        "project search" => "mod+shift+f",
        _ => "mod+k",
    }
}

fn open(world: &mut World) -> Outcome {
    if !world.client_ready() {
        world.connect()?;
        world.wait_for("the shell to start", |w| w.active())?;
    }
    hook(world);
    if !is_open(world) {
        press_toggle(world, "mod+k")?;
    }
    expect!(is_open(world), "{}", describe(world));
    let listed: Vec<String> = rows(world)?
        .iter()
        .map(|row| format!("{}\n{}", row.kind, row.id))
        .collect();
    state(world).listed = listed;
    Ok(())
}

fn search(world: &mut World, query: &str) -> Outcome {
    open(world)?;
    set_query(world, query)
}

fn add_project(world: &mut World, id: &str) {
    let row = json!({
        "id": id,
        "title": id,
        "workspaceRoot": format!("/work/{id}"),
        "createdAt": iso(now()),
        "updatedAt": iso(now()),
        "scripts": [],
    });
    world.mc.projects.insert(id.to_owned(), row.clone());
    world.mc.send_row_of(id, &row, "project");
}

/// A thread newer than every one before it, on this MC unless `peer` (another
/// MC of the cluster) serves it.
fn add_thread(world: &mut World, title: &str, extra: Value, peer: bool) -> Outcome<String> {
    let minute = {
        let fake = state(world);
        fake.minute += 1;
        fake.minute
    };
    let at_time = iso(now() + Duration::seconds(60 * minute));
    let mut row = if extra.is_object() { extra } else { json!({}) };
    let id = row["id"]
        .as_str()
        .map_or_else(|| format!("thread-{minute}"), str::to_owned);
    row["id"] = json!(id);
    row["title"] = json!(title);
    if row.get("projectId").is_none() {
        row["projectId"] = json!(PROJECT);
    }
    row["createdAt"] = json!(at_time);
    row["updatedAt"] = json!(at_time);
    let key = if peer {
        world.mc.send_peer_row(PEER_ENVIRONMENT, &id, &row);
        format!("{PEER_ENVIRONMENT}:{id}")
    } else {
        world.mc.threads.insert(id.clone(), row.clone());
        world.mc.send_row(&id, &row);
        format!("{}:{id}", world.mc.environment_id)
    };
    world.sync()?;
    let fake = state(world);
    fake.keys
        .entry(title.to_owned())
        .or_default()
        .push(key.clone());
    fake.that = key.clone();
    Ok(key)
}

/// This MC's environment with `changes` to what it can do, as the MC says
/// when a capability changes.
fn set_capabilities(world: &mut World, changes: Value) -> Outcome {
    if let Some(changes) = changes.as_object() {
        for (name, value) in changes {
            world.mc.capabilities[name] = value.clone();
        }
    }
    world.mc.announce_environment();
    world.sync()
}

fn key_of(world: &mut World, title: &str) -> Outcome<String> {
    match state(world).keys.get(title).and_then(|keys| keys.last()) {
        Some(key) => Ok(key.clone()),
        None => fail!("no thread \"{title}\""),
    }
}

fn thread_key(world: &World) -> String {
    world
        .with::<Navigation, _>(|n, _| n.thread_key().to_owned())
        .unwrap_or_default()
}

fn id_of_key(key: &str) -> &str {
    key.split_once(':').map_or(key, |(_, id)| id)
}

fn route_kind(world: &mut World) -> Outcome<String> {
    world.sync()?;
    Ok(text(&world.state("route")["kind"]))
}

fn pull_request_link(number: i64, title: &str) -> Value {
    json!({
        "number": number,
        "repository": "acme/shop",
        "url": format!("https://github.com/acme/shop/pull/{number}"),
        "source": "manual",
        "snapshot": {"title": title},
    })
}

fn current_submenu(world: &World) -> String {
    prop(world, "submenu").unwrap_or_default()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // Background.
    steps.step(
        &format!("the user has a project {Q} with threads"),
        |world, c, _| {
            expect!(
                c[0] == PROJECT,
                "the palette's steps know the project \"{PROJECT}\""
            );
            add_project(world, PROJECT);
            // Projects and a thread for a query to find besides actions and settings.
            add_project(world, "theme-lab");
            add_project(world, "docs-site");
            world.connect()?;
            world.sync()?;
            add_thread(world, "Tweak theme colors", json!({}), false)?;
            // More than the recent list holds.
            for n in 1..=BACKGROUND_THREADS {
                add_thread(world, &format!("Chore {n}"), json!({}), false)?;
            }
            // What the brick hands over from js/settingsPages.js.
            let sections = vec![
                json!({"to": "/settings/general", "label": "General",
                       "keywords": "time format diff layout"}),
                json!({"to": "/settings/appearance", "label": "Appearance",
                       "keywords": "theme light dark font size word wrap"}),
            ];
            act(world, |p, engine| p.set_settings_sections(engine, sections))
        },
    );
    steps.step(
        "the user is looking at a thread in that project",
        |world, _, _| {
            let key = key_of(world, &format!("Chore {BACKGROUND_THREADS}"))?;
            world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Thread(key)))?;
            world.sync()
        },
    );

    // features/threads/search.feature.
    steps.step(
        &format!("a connected environment with the threads {Q} and {Q} in the project {Q}"),
        |world, c, _| {
            add_project(world, &c[2]);
            world.connect()?;
            world.sync()?;
            for title in [&c[0], &c[1]] {
                add_thread(world, title, json!({"projectId": c[2]}), false)?;
            }
            Ok(())
        },
    );
    // Threads in one of the background's other projects, oldest first.
    steps.step(
        &format!("the project {Q} has the threads {Q} and {Q}"),
        |world, c, _| {
            for title in [&c[1], &c[2]] {
                add_thread(world, title, json!({"projectId": c[0]}), false)?;
            }
            Ok(())
        },
    );
    // The sidebar's Search button (tst_Sidebar.qml).
    steps.step(
        "the user starts a search from the thread list",
        |world, _, _| {
            hook(world);
            act(world, |p, engine| p.show(engine))
        },
    );
    steps.step(
        "the command palette opens ready to search threads",
        |world, _, _| {
            let recent: Vec<String> = rows(world)?
                .into_iter()
                .filter(|row| row.group == "Recent Threads")
                .map(|row| row.title)
                .collect();
            expect!(
                is_open(world)
                    && prop(world, "query")?.is_empty()
                    && recent == ["Add dark mode", "Fix OAuth loop"],
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    // Threads.
    steps.step(&format!("the thread {Q} is archived"), |world, c, _| {
        add_thread(world, &c[0], json!({"archivedAt": iso(now())}), false)?;
        Ok(())
    });
    steps.step(
        &format!("the thread {Q} is on branch {Q}"),
        |world, c, _| {
            add_thread(world, &c[0], json!({"branch": c[1]}), false)?;
            Ok(())
        },
    );
    steps.step(
        &format!("the thread {Q} is on another MC of the cluster"),
        |world, c, _| {
            world.mc.join(PEER, PEER_ENVIRONMENT);
            world.sync()?;
            add_thread(world, &c[0], json!({}), true)?;
            Ok(())
        },
    );
    steps.step(&format!("a thread titled {Q}"), |world, c, _| {
        add_thread(world, &c[0], json!({}), false)?;
        Ok(())
    });
    steps.step(
        &format!("threads titled {Q}, {Q} and {Q}"),
        |world, c, _| {
            for title in c {
                add_thread(world, title, json!({}), false)?;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("two threads titled {Q} and {Q} with the second updated more recently"),
        |world, c, _| {
            add_thread(world, &c[0], json!({}), false)?;
            add_thread(world, &c[1], json!({}), false)?;
            Ok(())
        },
    );
    steps.step(
        &format!(
            "a thread whose (title|linked pull request|project name|branch|id|message content) contains {Q}"
        ),
        |world, c, _| {
            let word = c[1].clone();
            match c[0].as_str() {
                "title" => {
                    add_thread(world, &format!("Paint the {word}"), json!({}), false)?;
                }
                "linked pull request" => {
                    let link = json!({
                        "number": 7, "repository": "acme/shop",
                        "url": "https://github.com/acme/shop/pull/7", "source": "manual",
                        "snapshot": {"title": format!("Add {word} stripes")},
                    });
                    add_thread(world, "Tidy", json!({"pullRequests": [link]}), false)?;
                }
                "project name" => {
                    add_project(world, &format!("{word}-lab"));
                    add_thread(
                        world,
                        "Tidy",
                        json!({"projectId": format!("{word}-lab")}),
                        false,
                    )?;
                }
                "message content" => {
                    add_thread(world, "Tidy", json!({"id": "thread-talk"}), false)?;
                    world.mc.part::<FakeMessages>().text.insert(
                        "thread-talk".into(),
                        format!("The {word} crossing is striped"),
                    );
                }
                "branch" => {
                    add_thread(
                        world,
                        "Tidy",
                        json!({"branch": format!("feature/{word}")}),
                        false,
                    )?;
                }
                _ => {
                    add_thread(
                        world,
                        "Tidy",
                        json!({"id": format!("thread-{word}")}),
                        false,
                    )?;
                }
            }
            Ok(())
        },
    );

    steps.step(
        "a pull request is linked to an archived thread",
        |world, _, _| {
            let link = pull_request_link(42, "Ship the cart");
            add_thread(
                world,
                "First try",
                json!({"pullRequests": [link], "archivedAt": iso(now())}),
                false,
            )?;
            add_thread(world, "Second try", json!({"pullRequests": [link]}), false)?;
            // Archived, with no pull request: never listed.
            add_thread(
                world,
                "Old notes #42",
                json!({"archivedAt": iso(now())}),
                false,
            )?;
            Ok(())
        },
    );
    steps.step(
        "the user searches the palette for that pull request",
        |world, _, _| search(world, "acme/shop#42"),
    );
    steps.step(
        &format!("the archived thread is listed as {Q}"),
        |world, c, _| {
            let listed = rows(world)?;
            let row = index_of(world, "First try", "thread")?;
            let old = index_of(world, "Old notes #42", "")?;
            expect!(
                row.is_some_and(|row| listed[row].description == c[0]) && old.is_none(),
                "{}",
                describe(world)
            );
            // And only for its pull request: by its title it stays out.
            set_query(world, "First try")?;
            let by_title = index_of(world, "First try", "")?;
            expect!(by_title.is_none(), "{}", describe(world));
            set_query(world, "acme/shop#42")
        },
    );
    steps.step(&format!("live threads are listed as {Q}"), |world, c, _| {
        let listed = rows(world)?;
        let row = index_of(world, "Second try", "thread")?;
        expect!(
            row.is_some_and(|row| listed[row].description == c[0]),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user last filtered the pull requests page to their own open pull requests",
        |world, _, _| {
            let before = world.state("route");
            world.dispatch("pullRequests.open", json!({}))?;
            for (name, value) in [("involvement", "authored"), ("state", "open")] {
                world.dispatch(
                    "pullRequestList.filter",
                    json!({"name": name, "value": value}),
                )?;
            }
            world.sync()?;
            // And went back to the thread.
            world.with::<Navigation, _>(|n, engine| n.back(engine))?;
            world.sync()?;
            let route = world.state("route");
            expect!(route == before, "{}", show(&route));
            Ok(())
        },
    );
    steps.step(
        "the pull requests page opens filtered to the user's own open pull requests",
        |world, _, _| {
            world.sync()?;
            let page = world.state("pullRequestList");
            let route = world.state("route");
            expect!(
                at(&route, "kind") == "pullRequests"
                    && at(&page, "open") == &json!(true)
                    && at(&page, "filters.involvement") == "authored"
                    && at(&page, "filters.state") == "open",
                "the route is {}, the page {}",
                show(&route),
                show(at(&page, "filters"))
            );
            // And the MC is asked for those, not for everyone's.
            let asked = world
                .mc
                .calls
                .iter()
                .rfind(|rpc| rpc.method == "pullRequests.list")
                .map_or(json!({}), |rpc| rpc.payload.clone());
            expect!(
                asked["involvement"] == "authored" && asked["state"] == "open",
                "the MC was asked for {}",
                show(&asked)
            );
            Ok(())
        },
    );

    // Opening and closing.
    steps.step(
        "the user presses the (command palette|command|go to file|project search) shortcut",
        |world, c, _| press_toggle(world, shortcut_of(&c[0])),
    );
    steps.step(
        "the command palette is open in (command|go to file|project search) mode",
        |world, c, _| {
            let mode = mode_of(&c[0]);
            if !world.checking {
                open(world)?;
                if prop(world, "mode")? != mode {
                    act(world, |p, engine| p.toggle_mode(engine, mode))?;
                }
            }
            expect!(
                is_open(world) && prop(world, "mode")? == mode,
                "{} in {}",
                describe(world),
                prop(world, "mode")?
            );
            Ok(())
        },
    );
    steps.step("no other palette mode is open", |world, _, _| {
        expect!(
            current_submenu(world).is_empty(),
            "the palette shows the submenu {}",
            current_submenu(world)
        );
        Ok(())
    });
    steps.step(
        "the palette is in (go to file|project search) mode",
        |world, c, _| {
            expect!(
                is_open(world) && prop(world, "mode")? == mode_of(&c[0]),
                "{} in {}",
                describe(world),
                prop(world, "mode")?
            );
            Ok(())
        },
    );
    steps.step("the user opens the command palette", |world, _, _| {
        open(world)
    });
    steps.step("the command palette is (open|closed)", |world, c, _| {
        if !world.checking && c[0] == "open" {
            open(world)?;
        }
        expect!(is_open(world) == (c[0] == "open"), "{}", describe(world));
        Ok(())
    });
    steps.step("the user dismisses the command palette", |world, _, _| {
        act(world, |p, engine| p.dismiss(engine))
    });
    // The brick focuses its field whenever the palette opens (tst_CommandPalette.qml);
    // here the palette staying open, with what the user typed, is what counts.
    steps.step(
        "the (?:search field|command palette search still) has keyboard focus",
        |world, _, _| {
            expect!(is_open(world), "{}", describe(world));
            Ok(())
        },
    );
    steps.step("the search field is empty", |world, _, _| {
        expect!(prop(world, "query")?.is_empty(), "{}", describe(world));
        Ok(())
    });
    steps.step(
        "a background update changes the thread list",
        |world, _, _| {
            let before = id_at(world, highlighted(world).max(0) as usize);
            add_thread(world, "Arrived meanwhile", json!({}), false)?;
            let after = id_at(world, highlighted(world).max(0) as usize);
            expect!(
                after == before,
                "the highlight moved off {before}: {}",
                describe(world)
            );
            Ok(())
        },
    );

    // Searching.
    steps.step(&format!("the user types {Q}"), |world, c, _| {
        open(world)?;
        let typed = prop(world, "query")? + &c[0];
        set_query(world, &typed)
    });
    steps.step(
        &format!("the user searches the palette for {Q}"),
        |world, c, _| search(world, &c[0]),
    );

    // What it lists.
    steps.step(
        &format!("the palette shows an? {Q} group"),
        |world, c, _| {
            let listed = rows(world)?;
            expect!(
                listed.iter().any(|row| row.group == c[0]),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the palette shows an? {Q} group of at most (\\d+) threads"),
        |world, c, _| {
            let threads: Vec<String> = rows(world)?
                .into_iter()
                .filter(|row| row.group == c[0])
                .map(|row| row.title)
                .collect();
            // The Background has more threads than fit, the newest first.
            expect!(
                threads.len().to_string() == c[1]
                    && threads.first().map(String::as_str)
                        == Some(format!("Chore {BACKGROUND_THREADS}").as_str()),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} is not listed"), |world, c, _| {
        // TODO(port): ComposerPickerSteps' modelPickerLists answers first
        // while the composer brick is shown; it is not ported.
        let row = index_of(world, &c[0], "")?;
        expect!(row.is_none(), "{}", describe(world));
        Ok(())
    });
    steps.step(
        &format!("{Q} is described with the project {Q} and {Q}"),
        |world, c, _| {
            let listed = rows(world)?;
            let row = index_of(world, &c[0], "thread")?;
            expect!(
                row.is_some_and(|row| listed[row].description == format!("{} · {}", c[1], c[2])),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the thread the user is looking at is described as {Q}"),
        |world, c, _| {
            let current = thread_key(world);
            let listed = rows(world)?;
            let row = listed.iter().find(|entry| entry.id == current);
            expect!(
                row.is_some_and(|row| row.description.ends_with(c[0].as_str())),
                "{}",
                describe(world)
            );
            let marked = listed
                .iter()
                .filter(|entry| entry.description.ends_with(c[0].as_str()))
                .count();
            expect!(marked == 1, "{}", describe(world));
            Ok(())
        },
    );
    steps.step(&format!("{Q} is listed before {Q}"), |world, c, _| {
        let first = index_of(world, &c[0], "")?;
        let second = index_of(world, &c[1], "")?;
        expect!(
            matches!((first, second), (Some(a), Some(b)) if a < b),
            "{}",
            describe(world)
        );
        Ok(())
    });
    // Entries by kind, where a setting and a thread share a title.
    steps.step(
        &format!("the {Q} setting is listed before the thread {Q}"),
        |world, c, _| {
            let first = index_of(world, &c[0], "setting")?;
            let second = index_of(world, &c[1], "thread")?;
            expect!(
                matches!((first, second), (Some(a), Some(b)) if a < b),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is listed before the {Q} setting"),
        |world, c, _| {
            let first = index_of(world, &c[0], "")?;
            let second = index_of(world, &c[1], "setting")?;
            expect!(
                matches!((first, second), (Some(a), Some(b)) if a < b),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the more recently updated thread is listed first",
        |world, _, _| {
            let row = index_of(world, "Refactor", "thread")?;
            let key = key_of(world, "Refactor")?;
            expect!(
                row.is_some_and(|row| id_at(world, row) == key),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("that thread is listed", |world, _, _| {
        let listed = rows(world)?;
        let that = state(world).that.clone();
        expect!(
            listed
                .iter()
                .any(|row| row.group == "Threads" && row.id == that),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step("only actions are listed", |world, _, _| {
        let listed = rows(world)?;
        expect!(
            !listed.is_empty() && listed.iter().all(|row| row.kind == "action"),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(&format!("the palette says {Q}"), |world, c, _| {
        rows(world)?;
        expect!(
            count(world) == 0 && prop(world, "emptyText")? == c[0],
            "{}",
            describe(world)
        );
        Ok(())
    });

    // Choosing entries.
    steps.step(&format!("the command palette lists {Q}"), |world, c, _| {
        open(world)?;
        let row = index_of(world, &c[0], "")?;
        expect!(row.is_some(), "{}", describe(world));
        Ok(())
    });
    steps.step(
        &format!("the user moves the highlight to {Q} and presses Enter"),
        |world, c, _| {
            let mut moves = 0;
            while moves < count(world)
                && role_text(world, highlighted(world).max(0) as usize, "title") != c[0]
            {
                act(world, |p, _| p.move_by(1))?;
                moves += 1;
            }
            let ran = act(world, |p, engine| p.run_highlighted(engine))?;
            expect!(ran, "{}", describe(world));
            world.sync()
        },
    );
    steps.step("the third listed entry runs", |world, _, _| {
        world.sync()?;
        let listed = state(world).listed.clone();
        let ran = state(world).ran.borrow().clone();
        let entry = listed.get(2).cloned().unwrap_or_default();
        let (kind, id) = entry.split_once('\n').unwrap_or_default();
        expect!(
            kind == "action" && ran.iter().any(|command| command == id),
            "listed {}, ran {}",
            listed.join(", "),
            ran.join(", ")
        );
        expect!(!is_open(world), "{}", describe(world));
        Ok(())
    });
    steps.step("settings open", |world, _, _| {
        let kind = route_kind(world)?;
        expect!(kind == "settings", "{}", show(&world.state("route")));
        Ok(())
    });
    steps.step("the usage page opens", |world, _, _| {
        let kind = route_kind(world)?;
        expect!(kind == "usage", "{}", show(&world.state("route")));
        Ok(())
    });
    // Groups and submenus.
    steps.step(
        "matching actions, projects, settings and threads are listed in their own groups",
        |world, _, _| {
            let mut groups: Vec<String> = Vec::new();
            for row in rows(world)? {
                if !groups.contains(&row.group) {
                    groups.push(row.group);
                }
            }
            expect!(
                groups == ["Actions", "Projects", "Settings", "Threads"],
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("the {Q} group is hidden"), |world, c, _| {
        let listed = rows(world)?;
        expect!(
            !listed.iter().any(|row| row.group == c[0]),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        &format!("the palette shows the {Q} submenu"),
        |world, c, _| {
            if !world.checking {
                if c[0] == "Change theme" {
                    // A theme of this device's own to choose.
                    let engine = world.engine().clone();
                    let settings = Settings::of(&engine);
                    let mut custom = settings
                        .device()
                        .get("customThemes")
                        .and_then(Value::as_array)
                        .cloned()
                        .unwrap_or_default();
                    custom.push(json!({
                        "id": "Nord", "label": "Nord", "appearance": "dark",
                        "colors": {"canvas": "#2e3440", "accent": "#88c0d0"},
                        "variants": {"light": {"canvas": "#eceff4", "accent": "#5e81ac"}},
                    }));
                    let saved = settings.write_device(&engine, "customThemes", json!(custom));
                    expect!(saved, "{}", settings.device_error());
                }
                open(world)?;
                let row = index_of(world, &c[0], "action")?;
                let ran = match row {
                    Some(row) => act(world, |p, engine| p.run(engine, row as i32))?,
                    None => false,
                };
                expect!(ran, "{}", describe(world));
                world.sync()?;
            }
            expect!(
                is_open(world) && current_submenu(world) == c[0],
                "the submenu is \"{}\"; {}",
                current_submenu(world),
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the palette shows the root list again", |world, _, _| {
        let listed = rows(world)?;
        expect!(
            is_open(world)
                && current_submenu(world).is_empty()
                && listed.iter().any(|row| row.group == "Actions"),
            "{}",
            describe(world)
        );
        Ok(())
    });

    // Searching thread messages.
    steps.step(
        "the user searches for text that only appears inside messages",
        |world, _, _| {
            world.mc.hold("messages");
            add_thread(world, "Tidy", json!({"id": "thread-talk"}), false)?;
            world.mc.part::<FakeMessages>().text.insert(
                "thread-talk".into(),
                "The flamingo stands on one leg".into(),
            );
            search(world, "flamingo")
        },
    );
    steps.step(
        &format!("the palette says {Q} until the results arrive"),
        |world, c, _| {
            world.wait_for("the palette to search messages", |w| {
                w.mc.peek::<FakeMessages>().is_some_and(|m| m.asked > 0)
            })?;
            world.sync()?;
            expect!(
                count(world) == 0 && prop(world, "emptyText")? == c[0],
                "the palette says \"{}\" with {} rows",
                prop(world, "emptyText")?,
                count(world)
            );
            world.mc.answer_held();
            let listed = rows(world)?;
            let that = state(world).that.clone();
            expect!(
                listed.iter().any(|row| row.id == that),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    // A command that fails.
    steps.step("an action that will fail", |world, _, _| {
        hook(world);
        let engine = world.engine().clone();
        let fails =
            match engine.eval_js("(function () { throw new Error(\"The disk is full.\"); })") {
                Ok(fails) => fails,
                Err(error) => fail!("the failing action: {error}"),
            };
        Commands::of(&engine).add_js(&engine, "test.explode", "Explode", fails, None);
        Ok(())
    });
    steps.step("the user runs it from the palette", |world, _, _| {
        search(world, "Explode")?;
        let row = index_of(world, "Explode", "")?;
        let ran = match row {
            Some(row) => act(world, |p, engine| p.run(engine, row as i32))?,
            None => false,
        };
        expect!(ran, "{}", describe(world));
        world.sync()
    });

    // What the palette's actions do.
    steps.step(
        &format!("the user runs {Q} from the palette"),
        |world, c, _| {
            open(world)?;
            let mut row = index_of(world, &c[0], "")?;
            if row.is_none() {
                set_query(world, &c[0])?;
                row = index_of(world, &c[0], "")?;
            }
            let ran = match row {
                Some(row) => act(world, |p, engine| p.run(engine, row as i32))?,
                None => false,
            };
            expect!(ran, "{}", describe(world));
            world.sync()
        },
    );
    steps.step(
        "the palette lists projects with the current project first",
        |world, _, _| {
            let titles: Vec<String> = rows(world)?.into_iter().map(|row| row.title).collect();
            expect!(
                current_submenu(world) == "New thread in..."
                    && titles.first().map(String::as_str) == Some(PROJECT)
                    && titles.iter().any(|t| t == "theme-lab")
                    && titles.iter().any(|t| t == "docs-site"),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the thread id is on the clipboard", |world, _, _| {
        let key = thread_key(world);
        let clipboard = world.clipboard();
        expect!(
            !key.is_empty() && clipboard == id_of_key(&key),
            "the clipboard holds \"{clipboard}\" for {key}"
        );
        Ok(())
    });
    steps.step(
        "the user is asked which pull request to link to the thread",
        |world, _, _| {
            world.sync()?;
            let (open, tab) = world.with::<RightPanel, _>(|p, _| (p.is_open(), p.active_tab()))?;
            let linking = read_tab(world, |t| t.link_open()).unwrap_or(false);
            expect!(
                linking && open && tab == "pull-requests",
                "{}",
                show(&world.state("panel"))
            );
            Ok(())
        },
    );
    steps.step(
        "the (?:command )?palette asks where the project comes from",
        |world, _, _| {
            let local = index_of(world, "Local folder", "")?;
            expect!(
                is_open(world) && current_submenu(world) == "Add project" && local.is_some(),
                "the submenu is \"{}\"; {}",
                current_submenu(world),
                describe(world)
            );
            Ok(())
        },
    );
    // The brick marks a current row "Current" (tst_CommandPalette.qml).
    steps.step(
        "the palette lists themes with the current one marked \"Current\"",
        |world, _, _| {
            world.sync()?;
            let current: Vec<String> = (0..count(world))
                .filter(|&row| role(world, row, "current") == ljos::prelude::Value::Bool(true))
                .map(|row| role_text(world, row, "title"))
                .collect();
            // The standard look is the one drawn.
            expect!(
                current_submenu(world) == "Change theme" && current == ["HAL-C2"],
                "current: {}; {}",
                current.join(", "),
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the palette offers System, Light and Dark",
        |world, _, _| {
            let titles: Vec<String> = rows(world)?.into_iter().map(|row| row.title).collect();
            expect!(
                current_submenu(world) == "Change appearance"
                    && titles == ["System", "Light", "Dark"],
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the theme editor opens", |world, _, _| {
        let open = world.with::<Themes, _>(|t, _| t.editor_open())?;
        expect!(open, "the theme editor is closed");
        Ok(())
    });
    steps.step("the pull request list opens", |world, _, _| {
        let kind = route_kind(world)?;
        expect!(kind == "pullRequests", "{}", show(&world.state("route")));
        Ok(())
    });
    steps.step("the current project's settings open", |world, _, _| {
        world.sync()?;
        let route = world.state("route");
        expect!(
            at(&route, "kind") == "settings" && text(&route["projectKey"]).ends_with(PROJECT),
            "{}",
            show(&route)
        );
        Ok(())
    });
    steps.step(
        "the app appearance is (dark|light|system)",
        |world, c, _| {
            world.sync()?;
            let mode = world.with::<Themes, _>(|t, _| t.mode().name())?;
            expect!(mode == c[0], "the appearance is {mode}");
            Ok(())
        },
    );

    // Pull requests.
    steps.step("the thread has a linked pull request", |world, _, _| {
        let key = thread_key(world);
        let id = id_of_key(&key).to_owned();
        let mut row = world.mc.threads.get(&id).cloned().unwrap_or(json!({}));
        row["linkedPullRequest"] = json!({"url": "https://github.com/acme/shop/pull/7"});
        world.mc.threads.insert(id.clone(), row.clone());
        world.mc.send_row(&id, &row);
        world.sync()
    });
    steps.step("the pull request URL is on the clipboard", |world, _, _| {
        let clipboard = world.clipboard();
        expect!(
            clipboard == "https://github.com/acme/shop/pull/7",
            "the clipboard holds \"{clipboard}\""
        );
        Ok(())
    });
    steps.step("the thread has no linked pull request", |world, _, _| {
        let key = thread_key(world);
        let linked = world
            .mc
            .threads
            .get(id_of_key(&key))
            .and_then(|row| row["pullRequests"].as_array())
            .is_some_and(|links| !links.is_empty());
        expect!(!linked, "{key} has pull requests");
        Ok(())
    });
    steps.step(&format!("{Q} cannot be run"), |world, c, _| {
        let row = index_of(world, &c[0], "")?;
        expect!(
            row.is_some_and(|row| role(world, row, "runnable") != ljos::prelude::Value::Bool(true)),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the environment has no source control provider for pull requests",
        |world, _, _| set_capabilities(world, json!({"pullRequests": false})),
    );
    steps.step(
        "the thread's environment cannot link pull requests to threads",
        |world, _, _| {
            set_capabilities(
                world,
                json!({"threadPullRequests": false, "threadPullRequestLinking": false}),
            )
        },
    );
    steps.step(
        "one connected environment supports pull requests and another does not",
        |world, _, _| {
            world.mc.join(PEER, PEER_ENVIRONMENT);
            set_capabilities(world, json!({"pullRequests": false}))
        },
    );
    steps.step("the user gives pull request (\\d+)", |world, c, _| {
        // The project's repository is on the host, so its pull requests can be read.
        let mut project = world.mc.projects.get(PROJECT).cloned().unwrap_or(json!({}));
        project["repositoryIdentity"] = json!({"canonicalKey": "github.com/acme/shop"});
        world.mc.projects.insert(PROJECT.into(), project.clone());
        world.mc.send_row_of(PROJECT, &project, "project");
        world.sync()?;
        let linking = read_tab(world, |t| t.link_open()).unwrap_or(false);
        expect!(linking, "the link field is closed");
        link_pull_request(
            world,
            &format!("https://github.com/acme/shop/pull/{}", c[0]),
        )?;
        world.sync()
    });
    steps.step(
        "pull request (\\d+) is linked to the thread",
        |world, c, _| wait_for_row(world, c[0].parse().unwrap_or(0), true),
    );

    // Add project.
    steps.step(
        &format!("the user chooses a local folder {Q}"),
        |world, c, _| {
            {
                let files = fake_files(&mut world.mc);
                let home = files.home.clone();
                files.folders.insert(format!("{home}/code"));
                files.folders.insert(format!("{home}/code/shop"));
            }
            let row = index_of(world, "Local folder", "")?;
            let ran = match row {
                Some(row) => act(world, |p, engine| p.run(engine, row as i32))?,
                None => false,
            };
            expect!(ran, "{}", describe(world));
            // Typed, then mod+Enter: the folder the path names.
            set_query(world, &c[0])?;
            rows(world)?;
            let added = act(world, |p, engine| p.add_browsed_folder(engine))?;
            expect!(added, "{}", describe(world));
            world.sync()
        },
    );
    steps.step(&format!("{Q} is added as a project"), |world, c, _| {
        let home = fake_files(&mut world.mc).home.clone();
        let name = c[0].clone();
        world.wait_for(&format!("the project {name}"), move |w| {
            w.mc.projects.values().any(|project| {
                project["title"] == name.as_str()
                    && project["workspaceRoot"] == format!("{home}/code/{name}").as_str()
            })
        })
    });
    steps.step("the user can start a thread in it", |world, _, _| {
        world.wait_for_with(
            |w| at(&w.state("route"), "kind") == "draft",
            |w| show(&w.state("route")),
        )?;
        let route = world.state("route");
        let draft = drafts::draft(world.engine(), &text(&route["draftId"]));
        let titled_shop = draft.is_some_and(|draft| {
            world
                .mc
                .projects
                .get(&draft.project_id)
                .is_some_and(|project| project["title"] == "shop")
        });
        expect!(titled_shop, "{}", show(&route));
        Ok(())
    });
}
