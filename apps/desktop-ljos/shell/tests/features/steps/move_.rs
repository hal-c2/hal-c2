//! Moving a thread between the machines of a cluster (desktop-qt's
//! MoveSteps.cpp; features/threads/moving-between-machines.feature): the
//! move from the thread menu and the palette (ThreadMenu), and what the
//! shell does with a thread whose rows say it is moving or has moved
//! (ShellStore::located). The cluster is machines known by one name each,
//! the MC's own among them, whose rows change as the real MCs' do during a
//! move (thread_move.ex).

use std::rc::Rc;

use hal_c2_shell::controllers::composer::kept;
use hal_c2_shell::controllers::navigation::Navigation;
use hal_c2_shell::controllers::palette::Palette;
use hal_c2_shell::controllers::thread_menu::MOVE;
use hal_c2_shell::store;
use serde_json::{Value, json};

use super::add_project as palette;
use super::alert::{await_system_notifications, click_system_notification, system_notifications};
use super::stream::iso;
use super::thread_menu::{MoveHook, item, items, pick, view};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

/// A machine the palette offered a move to.
struct Choice {
    title: String,
    description: String,
    enabled: bool,
}

struct FakeMove {
    /// The scenario built the machines' cluster.
    cluster: bool,
    /// The thread's provider can carry its session.
    carries: bool,
    /// The answer to each `hal-c2.moveThread` that moved.
    moved: Vec<Value>,
    /// What the user holds from before a move: a thread's key, and the one
    /// a system notification named.
    link: String,
    notified: String,
    /// The shell's subscriptions and connections before a move made
    /// elsewhere.
    subscriptions: usize,
    connections: usize,
    /// What the user wrote.
    message: String,
    /// The machines the palette offered, and the thread it named.
    choices: Vec<Choice>,
    palette_thread: String,
}

impl Default for FakeMove {
    fn default() -> Self {
        FakeMove {
            cluster: false,
            carries: true,
            moved: Vec::new(),
            link: String::new(),
            notified: String::new(),
            subscriptions: 0,
            connections: 0,
            message: String::new(),
            choices: Vec::new(),
            palette_thread: String::new(),
        }
    }
}

const AT: &str = "2026-09-23T10:00:00Z";
const PROJECT: &str = "shop";

fn machines(mc: &FakeMc) -> Vec<String> {
    let mut all = vec![mc.environment_id.clone()];
    all.extend(mc.members.iter().cloned());
    all
}

fn row_on(mc: &FakeMc, machine: &str, id: &str) -> Value {
    if machine == mc.environment_id {
        return mc.threads.get(id).cloned().unwrap_or(Value::Null);
    }
    mc.peer_rows
        .get(machine)
        .and_then(|rows| rows.get(id))
        .map_or(Value::Null, |entry| entry[2].clone())
}

fn put_row(mc: &mut FakeMc, machine: &str, id: &str, row: &Value) {
    if machine != mc.environment_id {
        return mc.send_peer_row(machine, id, row);
    }
    mc.threads.insert(id.to_owned(), row.clone());
    mc.send_row(id, row);
}

/// The machine the thread lives on: the one whose row is not a forwarding
/// record.
fn home_of(mc: &FakeMc, id: &str) -> String {
    machines(mc)
        .into_iter()
        .find(|machine| {
            let row = row_on(mc, machine, id);
            row.is_object() && row.get("movedTo").is_none()
        })
        .unwrap_or_default()
}

fn whereabouts(machine: &str) -> Value {
    json!({"label": machine, "environmentId": machine,
        "mc": format!("mc-{machine}"), "at": AT})
}

/// The source says the thread is on its way.
fn start(mc: &mut FakeMc, id: &str, to: &str) {
    let from = home_of(mc, id);
    let mut row = row_on(mc, &from, id);
    row["moving"] = whereabouts(to);
    put_row(mc, &from, id, &row);
}

/// The destination has the thread, then the source keeps only where it went.
fn finish(mc: &mut FakeMc, id: &str, to: &str) {
    let from = home_of(mc, id);
    let mut row = row_on(mc, &from, id);
    if let Some(object) = row.as_object_mut() {
        object.remove("moving");
    }
    put_row(mc, to, id, &row);
    let mut moved_to = whereabouts(to);
    moved_to["projectId"] = row["projectId"].clone();
    row["movedTo"] = moved_to;
    row["worktreePath"] = Value::Null;
    put_row(mc, &from, id, &row);
}

fn project() -> Value {
    json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": "/work/shop",
        "repositoryIdentity": {"canonicalKey": "github.com/acme/shop"},
        "scripts": [],
        "createdAt": "2026-09-01T09:00:00Z", "updatedAt": "2026-09-01T09:00:00Z"})
}

fn fake(world: &mut World) -> &mut FakeMove {
    world.mc.part::<FakeMove>()
}

fn id_of(world: &mut World, title: &str) -> Outcome<String> {
    let mc = &world.mc;
    if let Some((id, _)) = mc
        .threads
        .iter()
        .find(|(_, row)| text(&row["title"]) == title)
    {
        return Ok(id.clone());
    }
    for machine in &mc.members {
        let found = mc.peer_rows.get(machine).and_then(|rows| {
            rows.values()
                .find(|entry| text(&entry[1]) == "thread" && text(&entry[2]["title"]) == title)
        });
        if let Some(entry) = found {
            return Ok(text(&entry[0]));
        }
    }
    fail!("no thread is titled \"{title}\"")
}

fn key_on(machine: &str, id: &str) -> String {
    format!("{machine}:{id}")
}

/// The thread's key where it lives now.
fn key_of(world: &mut World, title: &str) -> Outcome<String> {
    let id = id_of(world, title)?;
    Ok(key_on(&home_of(&world.mc, &id), &id))
}

fn sidebar_row(world: &World, key: &str) -> Option<Value> {
    let sidebar = world.state("sidebar");
    ["pinned", "active", "snoozed", "settled"]
        .iter()
        .flat_map(|section| sidebar[*section].as_array().into_iter().flatten())
        .find(|row| text(&row["key"]) == key)
        .cloned()
}

fn sidebar(world: &World) -> String {
    format!("the sidebar is {}", show(&world.state("sidebar")))
}

/// The thread is listed on `machine` and on no other.
fn wait_for_listed(world: &mut World, title: &str, machine: &str) -> Outcome {
    let id = id_of(world, title)?;
    let all = machines(&world.mc);
    world.wait_for_with(
        |w| {
            all.iter()
                .all(|other| sidebar_row(w, &key_on(other, &id)).is_none() == (other != machine))
        },
        |w| format!("{title} to be listed only under {machine}; {}", sidebar(w)),
    )
}

fn shown_key(world: &World) -> String {
    text(at(&world.state("workspace"), "threadKey"))
}

/// The window shows the thread on `machine`, in the route and in the header.
fn wait_for_shown(world: &mut World, title: &str, machine: &str) -> Outcome {
    let key = key_on(machine, &id_of(world, title)?);
    world.wait_for_with(
        |w| {
            let route = w
                .with::<Navigation, _>(|navigation, _| navigation.thread_key().to_owned())
                .unwrap_or_default();
            route == key
                && shown_key(w) == key
                && text(at(&w.state("workspace"), "threadTitle")) == title
        },
        |w| {
            format!(
                "the window to show {key}; it shows {}",
                show(&w.state("workspace"))
            )
        },
    )
}

/// The thread's menu, then its Move: the machines the MC lists.
fn choose_machine(world: &mut World, title: &str) -> Outcome {
    world.sync()?;
    let key = key_of(world, title)?;
    world.dispatch("thread.menu", json!({"key": key, "x": 40, "y": 120}))?;
    let menu = world.state("menu");
    expect!(
        item(world, "move").is_some(),
        "the menu has no \"move\": {}",
        show(&Value::Array(items(world)))
    );
    drop(menu);
    pick(world, "move")?;
    world.wait_for_with(
        |w| {
            items(w)
                .first()
                .is_some_and(|first| text(&first["id"]).starts_with("machine:"))
        },
        |w| {
            format!(
                "the machines to be listed; the menu is {}",
                show(&Value::Array(items(w)))
            )
        },
    )
}

fn move_from_menu(world: &mut World, title: &str, machine: &str) -> Outcome {
    choose_machine(world, title)?;
    expect!(
        item(world, &format!("machine:{machine}")).is_some(),
        "the menu has no \"machine:{machine}\": {}",
        show(&Value::Array(items(world)))
    );
    pick(world, &format!("machine:{machine}"))?;
    world.sync()
}

/// A move the client under test did not ask for: only the rows tell it.
fn move_elsewhere(world: &mut World, title: &str, machine: &str) -> Outcome {
    let id = id_of(world, title)?;
    start(&mut world.mc, &id, machine);
    finish(&mut world.mc, &id, machine);
    world.sync()
}

/// Opens the palette's Move on the shown thread; its rows are then the
/// machines.
fn ask_palette(world: &mut World) -> Outcome {
    palette::open(world)?;
    palette::set_query(world, "Move to another machine")?;
    world.wait_for("the palette to settle", |w| !palette::searching(w))?;
    let mut titles = Vec::new();
    for row in 0..palette::count(world) {
        titles.push(palette::role_text(world, row, "title"));
        if palette::id_at(world, row) != MOVE {
            continue;
        }
        fake(world).palette_thread = palette::role_text(world, row, "description");
        palette::invoke_ok(world, "run", &[ljos::prelude::Value::Int(row as i32)])?;
        world.wait_for_with(
            |w| {
                palette::prop(w, "submenu").unwrap_or_default() == "Move to another machine"
                    && palette::count(w) > 0
                    && !palette::searching(w)
            },
            |w| format!("the machines to be listed; {}", palette::describe(w)),
        )?;
        let choices = (0..palette::count(world))
            .map(|choice| Choice {
                title: palette::role_text(world, choice, "title"),
                description: palette::role_text(world, choice, "description"),
                enabled: palette::role(world, choice, "runnable")
                    == ljos::prelude::Value::Bool(true),
            })
            .collect();
        fake(world).choices = choices;
        return Ok(());
    }
    fail!("the palette offers no move: {}", titles.join(", "))
}

fn offered(world: &mut World) -> String {
    let menu = show(&Value::Array(items(world)));
    let palette: Vec<String> = fake(world)
        .choices
        .iter()
        .map(|entry| {
            if entry.enabled {
                entry.title.clone()
            } else {
                format!("{} ({})", entry.title, entry.description)
            }
        })
        .collect();
    format!("the menu offers {menu}, the palette {}", palette.join(", "))
}

fn choice_offered(world: &mut World, machine: &str) -> Option<(String, bool)> {
    fake(world)
        .choices
        .iter()
        .find(|offered| offered.title == machine)
        .map(|offered| (offered.description.clone(), offered.enabled))
}

/// The `message.dispatch` the MC got for the thread, with the machine it was
/// sent to.
fn sent(world: &World, id: &str) -> Option<(Value, String)> {
    let mc = &world.mc;
    (0..mc.commands.len()).rev().find_map(|index| {
        let command = &mc.commands[index];
        (text(&command["type"]) == "message.dispatch" && text(&command["threadId"]) == id)
            .then(|| (command.clone(), mc.command_environments[index].clone()))
    })
}

fn submit(world: &mut World, mut payload: Value) -> Outcome {
    payload["intent"] = json!("foreground");
    world.dispatch("composer.submit", payload)
}

fn toast_titled(world: &World, title: &str) -> bool {
    world.state("toasts")["items"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|toast| text(&toast["title"]) == title)
}

/// Answers `hal-c2.moveDestinations` and `hal-c2.moveThread` as the machines'
/// MCs do, their rows following the move. False when the scenario built no
/// such cluster.
fn answer_machine_move(mc: &mut FakeMc, rpc: &Rpc) -> bool {
    if !mc.part::<FakeMove>().cluster {
        return false;
    }
    let from = if rpc.environment.is_empty() {
        mc.environment_id.clone()
    } else {
        rpc.environment.clone()
    };
    if rpc.method == "hal-c2.moveDestinations" {
        let destinations: Vec<Value> = machines(mc)
            .into_iter()
            .filter(|machine| *machine != from)
            .map(|machine| {
                json!({"machine": mc.peer_labels.get(&machine).cloned().unwrap_or_else(|| machine.clone()),
                    "environmentId": machine,
                    "online": !mc.offline.contains(&machine),
                    "projects": [project()]})
            })
            .collect();
        mc.reply(rpc, Value::Array(destinations));
        return true;
    }

    let id = text(&rpc.payload["threadId"]);
    let to = text(&rpc.payload["machine"]);
    let row = row_on(mc, &from, &id);
    let title = text(&row["title"]);
    // What thread_move.ex refuses before anything is copied.
    let refusal = if row.get("movedTo").is_some() {
        format!(
            "{title} has already moved to {}.",
            text(&row["movedTo"]["label"])
        )
    } else if row.get("moving").is_some() {
        format!(
            "{title} is already moving to {}.",
            text(&row["moving"]["label"])
        )
    } else if row.get("activeRunId").is_some() {
        format!("{title} is running. Stop it or wait for it to finish before moving it.")
    } else if mc.offline.contains(&to) {
        format!("{to} is offline. {title} was not moved.")
    } else {
        String::new()
    };
    if !refusal.is_empty() {
        mc.refuse(rpc, &refusal);
        return true;
    }

    start(mc, &id, &to);
    finish(mc, &id, &to);
    let carries = mc.part::<FakeMove>().carries;
    let message = if carries {
        format!("{title} moved to {to}. The agent continues its own session there.")
    } else {
        format!("{title} moved to {to}. The agent there will get a summary of the conversation.")
    };
    let mut answer = json!({"status": "moved", "threadId": id, "machine": to,
        "environmentId": to, "projectId": row["projectId"],
        "sessionCarried": carries, "message": message, "notes": []});
    mc.reply(rpc, answer.clone());
    answer["from"] = json!(from);
    mc.part::<FakeMove>().moved.push(answer);
    true
}

/// Shows the thread titled `title` on the machine it lives on; false when
/// the scenario built no cluster.
pub fn show_machine_thread(world: &mut World, title: &str) -> Outcome<bool> {
    if !fake(world).cluster {
        return Ok(false);
    }
    let key = key_of(world, title)?;
    view(world, &key)?;
    Ok(true)
}

/// Checks that a move does not offer `machine`, from the menu or the
/// palette; false when the scenario built no cluster.
pub fn machine_not_offered(world: &mut World, machine: &str) -> Outcome<bool> {
    if !fake(world).cluster {
        return Ok(false);
    }
    let absent = item(world, &format!("machine:{machine}")).is_none()
        && choice_offered(world, machine).is_none();
    expect!(absent, "{}", offered(world));
    Ok(true)
}

fn extension(mc: &mut FakeMc) {
    mc.part::<MoveHook>().0 = Some(answer_machine_move);
    // A stopped run leaves its thread free to move.
    mc.effects.push(Rc::new(|mc: &mut FakeMc, command: &Value| {
        if !mc.part::<FakeMove>().cluster || text(&command["type"]) != "run.interrupt" {
            return;
        }
        let id = text(&command["threadId"]);
        let machine = home_of(mc, &id);
        let mut row = row_on(mc, &machine, &id);
        if let Some(object) = row.as_object_mut() {
            object.remove("activeRunId");
            object.insert("status".into(), json!("interrupted"));
        }
        put_row(mc, &machine, &id, &row);
    }));
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // The Background: the MC is the first machine, the others its cluster's.
    steps.step(
        &format!("a cluster of the machines {Q} and {Q}"),
        |world, c, _| {
            fake(world).cluster = true;
            world.mc.environment_id = c[0].clone();
            world.mc.name = format!("mc-{}", c[0]);
            world.mc.label = c[0].clone();
            world.mc.join_named(&c[1]);
            Ok(())
        },
    );
    steps.step(
        &format!("the project {Q} on each machine is a checkout of the same repository"),
        |world, c, _| {
            // Any other project is one a new thread is placed in
            // (LoadBalancing).
            if c[0] != PROJECT {
                // TODO(port): LoadBalancing's shareProject, a project every
                // machine has a checkout of, goes here.
                fail!("TODO(port): LoadBalancing's shareProject is not ported");
            }
            world.mc.projects.insert(PROJECT.to_owned(), project());
            for machine in world.mc.members.clone() {
                world
                    .mc
                    .send_peer_row_of(&machine, PROJECT, &project(), "project");
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the thread {Q} lives on {Q} in {Q}"),
        |world, c, _| {
            let id = c[0].to_lowercase();
            put_row(
                &mut world.mc,
                &c[1],
                &id,
                &json!({"id": id, "title": c[0], "projectId": c[2],
                    "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"}),
            );
            world.connect()?;
            world.sync()
        },
    );
    steps.step(
        &format!("the cluster also has the machine {Q}, which is offline"),
        |world, c, _| {
            world.mc.offline.insert(c[0].clone());
            world
                .mc
                .send_peer_row_of(&c[0], PROJECT, &project(), "project");
            world.mc.join_named(&c[0]);
            world.sync()
        },
    );
    // Its environment is its own; only the name is shared.
    steps.step(
        &format!("the cluster also has a second machine called {Q}"),
        |world, c, _| {
            let environment = format!("{}-2", c[0]);
            world
                .mc
                .send_peer_row_of(&environment, PROJECT, &project(), "project");
            world
                .mc
                .peer_labels
                .insert(environment.clone(), c[0].clone());
            world.mc.join(&format!("mc-{environment}"), &environment);
            world.sync()
        },
    );
    steps.step(
        &format!("{Q} runs on an agent whose provider (can|cannot) carry its session"),
        |world, c, _| {
            fake(world).carries = c[1] == "can";
            Ok(())
        },
    );

    // Moving, by the user here and by somebody else.
    steps.step(
        &format!("the user moves {Q} to {Q}( and chooses to stop it first)?"),
        |world, c, _| {
            move_from_menu(world, &c[0], &c[1])?;
            if c[2].is_empty() {
                return Ok(());
            }
            let question = world.state("confirmation");
            let wanted = format!("Stop \"{}\" and move it to {}?", c[0], c[1]);
            expect!(
                text(at(&question, "title")) == wanted,
                "the user is asked {}",
                show(&question)
            );
            world.dispatch(
                "confirmation.answer",
                json!({"requestId": question["requestId"], "accepted": true}),
            )
        },
    );
    // Relatives across machines (ThreadLineage): a move keeps a thread's id.
    steps.step(&format!("{Q} on {Q} is a fork of {Q}"), |world, c, _| {
        let id = c[0].to_lowercase();
        let parent = id_of(world, &c[2])?;
        put_row(
            &mut world.mc,
            &c[1],
            &id,
            &json!({"id": id, "title": c[0], "projectId": PROJECT,
                    "createdAt": "2026-09-23T09:10:00Z", "updatedAt": "2026-09-23T09:10:00Z",
                    "lineage": {"relationshipToParent": "fork", "parentThreadId": parent}}),
        );
        world.sync()
    });
    steps.step(
        &format!("the user opens {Q} where it lives now"),
        |world, c, _| {
            let id = id_of(world, &c[0])?;
            let key = key_on(&home_of(&world.mc, &id), &id);
            view(world, &key)?;
            world.sync()
        },
    );
    steps.step(&format!("its parent is {Q} on {Q}"), |world, c, _| {
        world.sync()?;
        let lineage = world.state("lineage");
        let parent = &lineage["parent"];
        let wanted = format!("{}:{}", c[1], id_of(world, &c[0])?);
        expect!(
            text(&parent["key"]) == wanted
                && text(&parent["title"]) == c[0]
                && parent["missing"].as_bool() != Some(true),
            "the lineage is {}",
            show(&lineage)
        );
        Ok(())
    });
    steps.step(&format!("{Q} is listed as its fork"), |world, c, _| {
        world.sync()?;
        let lineage = world.state("lineage");
        let titles: Vec<String> = lineage["forks"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|fork| text(&fork["title"]))
            .collect();
        expect!(
            titles == [c[0].clone()],
            "the lineage is {}",
            show(&lineage)
        );
        Ok(())
    });
    steps.step(&format!("{Q} was moved from {Q} to {Q}"), |world, c, _| {
        let id = id_of(world, &c[0])?;
        expect!(
            home_of(&world.mc, &id) == c[1],
            "{} does not live on {}",
            c[0],
            c[1]
        );
        move_elsewhere(world, &c[0], &c[2])
    });
    steps.step(&format!("{Q} has since moved to {Q}"), |world, c, _| {
        move_elsewhere(world, &c[0], &c[1])
    });
    steps.step(
        &format!("{Q} is moved to {Q} from another client"),
        |world, c, _| move_elsewhere(world, &c[0], &c[1]),
    );
    steps.step(
        &format!("the user moves {Q} to {Q} from the desktop app"),
        |world, c, _| move_elsewhere(world, &c[0], &c[1]),
    );
    steps.step(
        &format!("{Q} (?:starts|is) moving to {Q}"),
        |world, c, _| {
            let id = id_of(world, &c[0])?;
            start(&mut world.mc, &id, &c[1]);
            world.sync()
        },
    );
    steps.step(&format!("the user worked in {Q} on {Q}"), |world, c, _| {
        let id = id_of(world, &c[0])?;
        expect!(
            home_of(&world.mc, &id) == c[1],
            "{} does not live on {}",
            c[0],
            c[1]
        );
        let later = world.now() + chrono::Duration::seconds(600);
        world.set_time(later);
        let mut row = row_on(&world.mc, &c[1], &id);
        let at = iso(world.now());
        row["latestRunId"] = json!(format!("run-{}", c[1]));
        row["status"] = json!("completed");
        row["latestRunCompletedAt"] = json!(at);
        row["updatedAt"] = json!(at);
        put_row(&mut world.mc, &c[1], &id, &row);
        world.sync()
    });

    // Where the thread is listed and shown.
    steps.step(&format!("{Q} is listed under {Q}"), |world, c, _| {
        let key = key_on(&c[1], &id_of(world, &c[0])?);
        world.wait_for_with(
            |w| sidebar_row(w, &key).is_some_and(|row| text(&row["environmentId"]) == c[1]),
            |w| format!("{} to be listed under {}; {}", c[0], c[1], sidebar(w)),
        )
    });
    steps.step(
        &format!("{Q} is no longer listed under {Q}"),
        |world, c, _| {
            world.sync()?;
            let key = key_on(&c[1], &id_of(world, &c[0])?);
            expect!(sidebar_row(world, &key).is_none(), "{}", sidebar(world));
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} is listed under {Q} with the work done on {Q}"),
        |world, c, _| {
            wait_for_listed(world, &c[0], &c[1])?;
            let key = key_on(&c[1], &id_of(world, &c[0])?);
            let row = store::with(world.engine(), |store| {
                store.thread_row(&key).cloned().unwrap_or_default()
            });
            expect!(
                row.get("latestRunId").and_then(|run| run.as_str())
                    == Some(&format!("run-{}", c[2])),
                "the thread's row is {}",
                serde_json::Value::Object(row)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user is looking at {Q} on {Q}"),
        |world, c, _| wait_for_shown(world, &c[0], &c[1]),
    );
    steps.step(&format!("{Q} opens on {Q}"), |world, c, _| {
        wait_for_shown(world, &c[0], &c[1])
    });
    steps.step(&format!("{Q} moves to {Q}"), |world, c, _| {
        let id = id_of(world, &c[0])?;
        world.wait_for_with(
            |w| {
                w.mc.peek::<FakeMove>().is_some_and(|fake| {
                    fake.moved.iter().any(|answer| {
                        text(&answer["threadId"]) == id && text(&answer["machine"]) == c[1]
                    })
                })
            },
            |w| {
                format!(
                    "the MC to be asked to move {} to {}; it got {}",
                    c[0],
                    c[1],
                    w.describe_commands()
                )
            },
        )?;
        wait_for_listed(world, &c[0], &c[1])
    });
    steps.step(
        &format!("the agent on {Q} continues the session as it was on {Q}"),
        |world, c, _| {
            let Some(answer) = fake(world).moved.last().cloned() else {
                fail!("no thread was moved");
            };
            expect!(
                text(&answer["machine"]) == c[0]
                    && text(&answer["from"]) == c[1]
                    && answer["sessionCarried"].as_bool() == Some(true),
                "the move was answered {}",
                show(&answer)
            );
            expect!(
                toast_titled(world, &text(&answer["message"])),
                "the user is told {}",
                show(&world.state("toasts"))
            );
            Ok(())
        },
    );

    // Choosing the machine.
    steps.step(
        &format!("the user chooses where to move {Q}"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            view(world, &key)?;
            ask_palette(world)?;
            world.with::<Palette, _>(|palette, engine| palette.dismiss(engine))?;
            choose_machine(world, &c[0])
        },
    );
    steps.step(&format!("{Q} is offered"), |world, c, _| {
        if super::files_identity::check_icon_image_offered(world, &c[0], true)? {
            return Ok(());
        }
        let entry = item(world, &format!("machine:{}", c[0]));
        let listed = choice_offered(world, &c[0]);
        expect!(
            entry.is_some_and(|entry| entry["enabled"].as_bool() == Some(true))
                && listed.is_some_and(|(_, enabled)| enabled),
            "{}",
            offered(world)
        );
        Ok(())
    });
    steps.step(
        &format!("{Q} is shown as offline and cannot be chosen"),
        |world, c, _| {
            let entry = item(world, &format!("machine:{}", c[0]));
            let listed = choice_offered(world, &c[0]);
            let right = entry.is_some_and(|entry| {
                text(&entry["label"]) == format!("{} (offline)", c[0])
                    && entry["enabled"].as_bool() != Some(true)
            }) && listed
                .is_some_and(|(description, enabled)| !enabled && description == "Offline");
            expect!(right, "{}", offered(world));
            Ok(())
        },
    );
    steps.step(
        &format!("both machines called {Q} are offered, each with its environment id"),
        |world, c, _| {
            for environment in [c[0].clone(), format!("{}-2", c[0])] {
                let name = format!("{} · {environment}", c[0]);
                let entry = item(world, &format!("machine:{environment}"));
                let listed = choice_offered(world, &name);
                expect!(
                    entry.is_some_and(|entry| text(&entry["label"]) == name)
                        && listed.is_some_and(|(_, enabled)| enabled),
                    "{}",
                    offered(world)
                );
            }
            Ok(())
        },
    );
    steps.step("moving to another machine is offered", |world, _, _| {
        let entry = item(world, "move");
        expect!(
            entry.is_some_and(|entry| entry["enabled"].as_bool() == Some(true)),
            "the menu is {}",
            show(&Value::Array(items(world)))
        );
        Ok(())
    });
    steps.step(
        "the user asks the command palette to move the thread to another machine",
        |world, _, _| ask_palette(world),
    );
    steps.step(
        &format!("the user is asked which machine to move {Q} to"),
        |world, c, _| {
            let mut wanted = machines(&world.mc);
            let id = id_of(world, &c[0])?;
            let home = home_of(&world.mc, &id);
            wanted.retain(|machine| *machine != home);
            let listed: Vec<String> = fake(world)
                .choices
                .iter()
                .map(|entry| entry.title.clone())
                .collect();
            let submenu = palette::prop(world, "submenu")?;
            let thread = fake(world).palette_thread.clone();
            expect!(
                palette::is_open(world)
                    && submenu == "Move to another machine"
                    && thread == c[0]
                    && listed == wanted,
                "the palette shows \"{submenu}\" for \"{thread}\": {}",
                listed.join(", ")
            );
            Ok(())
        },
    );

    // A thread found from before it moved.
    steps.step(
        &format!("the user copied a link to {Q} while it lived on {Q}"),
        |world, c, _| {
            let link = key_of(world, &c[0])?;
            fake(world).link = link.clone();
            let wanted = key_on(&c[1], &id_of(world, &c[0])?);
            expect!(link == wanted, "{} does not live on {}", c[0], c[1]);
            Ok(())
        },
    );
    steps.step("the user follows the link", |world, _, _| {
        let key = fake(world).link.clone();
        world.dispatch("thread.open", json!({"key": key}))
    });
    steps.step(
        &format!("the user was notified that {Q} finished while it lived on {Q}"),
        |world, c, _| {
            let id = id_of(world, &c[0])?;
            await_system_notifications(world)?;
            let mut row = row_on(&world.mc, &c[1], &id);
            row["latestRunId"] = json!("run-1");
            row["latestRunStartedAt"] = json!(iso(world.now()));
            row["status"] = json!("running");
            put_row(&mut world.mc, &c[1], &id, &row);
            world.sync()?;
            let later = world.now() + chrono::Duration::seconds(60);
            world.set_time(later);
            let at = iso(world.now());
            row["status"] = json!("completed");
            row["latestRunCompletedAt"] = json!(at);
            row["updatedAt"] = json!(at);
            put_row(&mut world.mc, &c[1], &id, &row);
            world.sync()?;
            let notified = key_on(&c[1], &id);
            fake(world).notified = notified.clone();
            let told = system_notifications(world);
            expect!(
                told == [notified],
                "the user was notified of {}",
                told.join(", ")
            );
            Ok(())
        },
    );
    steps.step("the user opens the notification", |world, _, _| {
        let key = fake(world).notified.clone();
        let opened = click_system_notification(world, &key)?;
        expect!(opened, "the notification opened nothing");
        Ok(())
    });

    // A client that did not make the move. The client under test is the one
    // watching: the move is made elsewhere and reaches it as rows.
    steps.step(
        "a phone and the desktop app both follow the cluster's threads",
        |world, _, _| {
            world.sync()?;
            let subscriptions = world.shell_subscriptions();
            let connections = world.mc.connections.len();
            let state = fake(world);
            state.subscriptions = subscriptions;
            state.connections = connections;
            Ok(())
        },
    );
    steps.step(
        &format!("the phone lists {Q} under {Q} and no longer under {Q}"),
        |world, c, _| {
            wait_for_listed(world, &c[0], &c[1])?;
            let key = key_on(&c[2], &id_of(world, &c[0])?);
            expect!(sidebar_row(world, &key).is_none(), "{}", sidebar(world));
            Ok(())
        },
    );
    steps.step("the phone did not have to reconnect", |world, _, _| {
        let (subscriptions, connections) =
            (world.shell_subscriptions(), world.mc.connections.len());
        let before = (fake(world).subscriptions, fake(world).connections);
        expect!(
            (subscriptions, connections) == before,
            "the client subscribed {subscriptions} times over {connections} connections"
        );
        Ok(())
    });
    steps.step(&format!("the phone is showing {Q}"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        view(world, &key)
    });
    steps.step(&format!("the phone keeps showing {Q}"), |world, c, _| {
        let id = id_of(world, &c[0])?;
        let home = home_of(&world.mc, &id);
        wait_for_shown(world, &c[0], &home)
    });
    steps.step(
        &format!("a message sent from the phone reaches {Q} on {Q}"),
        |world, c, _| {
            let id = id_of(world, &c[0])?;
            submit(world, json!({"text": "Carry on"}))?;
            world.wait_for_with(
                |w| sent(w, &id).is_some(),
                |w| {
                    format!(
                        "the message to be sent; the MC got {}",
                        w.describe_commands()
                    )
                },
            )?;
            let machine = sent(world, &id)
                .map(|(_, machine)| machine)
                .unwrap_or_default();
            expect!(machine == c[1], "the message went to \"{machine}\"");
            Ok(())
        },
    );
    steps.step(&format!("the phone lists {Q}"), |world, c, _| {
        let key = key_of(world, &c[0])?;
        world.wait_for_with(|w| sidebar_row(w, &key).is_some(), sidebar)
    });
    steps.step(
        &format!("the phone shows {Q} as moving to {Q} until it arrives"),
        |world, c, _| {
            let id = id_of(world, &c[0])?;
            let from = key_of(world, &c[0])?;
            world.wait_for_with(
                |w| sidebar_row(w, &from).is_some_and(|row| text(&row["movingTo"]) == c[1]),
                sidebar,
            )?;
            finish(&mut world.mc, &id, &c[1]);
            wait_for_listed(world, &c[0], &c[1])?;
            let arrived = sidebar_row(world, &key_on(&c[1], &id)).unwrap_or(Value::Null);
            expect!(
                text(&arrived["movingTo"]).is_empty(),
                "the row is {}",
                show(&arrived)
            );
            Ok(())
        },
    );

    // Stopping first, and writing while the thread is on its way.
    steps.step(
        &format!("the running turn of {Q} is interrupted"),
        |world, c, _| {
            let id = id_of(world, &c[0])?;
            world.wait_for_with(
                |w| {
                    w.mc.commands.iter().any(|command| {
                        text(&command["type"]) == "run.interrupt"
                            && text(&command["threadId"]) == id
                            && text(&command["runId"]) == "r1"
                    })
                },
                |w| {
                    format!(
                        "the run to be interrupted; the MC got {}",
                        w.describe_commands()
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user writes a message in {Q}"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            view(world, &key)?;
            fake(world).message = "Carry on from here".to_owned();
            submit(world, json!({"text": "Carry on from here"}))?;
            world.sync()
        },
    );
    steps.step("the message is kept as a draft", |world, _, _| {
        let key =
            world.with::<Navigation, _>(|navigation, _| navigation.thread_key().to_owned())?;
        let id = key
            .split_once(':')
            .map_or(key.as_str(), |(_, id)| id)
            .to_owned();
        let row = store::with(world.engine(), |store| {
            store.thread_row(&key).cloned().unwrap_or_default()
        });
        expect!(
            sent(world, &id).is_none(),
            "the message was sent: {}",
            world.describe_commands()
        );
        let draft = kept::draft(world.engine(), &key);
        let message = fake(world).message.clone();
        expect!(draft == message, "the draft is \"{draft}\"");
        let moving = row
            .get("moving")
            .and_then(|moving| moving.get("label"))
            .and_then(|label| label.as_str())
            .unwrap_or_default();
        let title = row
            .get("title")
            .and_then(|title| title.as_str())
            .unwrap_or_default();
        let told = format!("{title} is moving to {moving}");
        expect!(
            toast_titled(world, &told),
            "the user is told {}",
            show(&world.state("toasts"))
        );
        Ok(())
    });
    steps.step(
        &format!("it can be sent once {Q} has arrived on {Q}"),
        |world, c, _| {
            let id = id_of(world, &c[0])?;
            finish(&mut world.mc, &id, &c[1]);
            wait_for_shown(world, &c[0], &c[1])?;
            let draft = kept::draft(world.engine(), &key_on(&c[1], &id));
            let message = fake(world).message.clone();
            expect!(draft == message, "the draft on {} is \"{draft}\"", c[1]);
            submit(world, json!({}))?;
            world.wait_for_with(
                |w| sent(w, &id).is_some(),
                |w| {
                    format!(
                        "the message to be sent; the MC got {}",
                        w.describe_commands()
                    )
                },
            )?;
            let (command, machine) = sent(world, &id).expect("the wait found it");
            expect!(
                text(&command["text"]) == message && machine == c[1],
                "\"{}\" went to \"{machine}\"",
                text(&command["text"])
            );
            Ok(())
        },
    );
}
