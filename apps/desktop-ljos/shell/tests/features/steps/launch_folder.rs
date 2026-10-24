//! A folder named when the app is launched again (src/single_instance.rs;
//! desktop-qt's LaunchFolderSteps.cpp): the later launch hands it to the
//! running window and ends, and the window adds it as a project, or finds
//! it, and starts a thread there (features/navigation/qt-shell-backlog.feature,
//! "Opening a folder from outside").

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, channel};

use hal_c2_shell::controllers::drafts;
use hal_c2_shell::single_instance::{self, Listener};
use serde_json::{Value as Json, json};

use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

#[derive(Default)]
struct Launches {
    running: Option<Listener>,
    arrivals: Option<Receiver<Vec<String>>>,
    folder: String,
    forwarded: bool,
    connections_before: usize,
}

fn state_dir(world: &World) -> PathBuf {
    world.home_dir().join("state")
}

/// A real folder under the scenario's home, as the user's `~/code/<name>`.
fn folder(world: &World, name: &str) -> Outcome<String> {
    let path = world.home_dir().join("code").join(name);
    if let Err(error) = std::fs::create_dir_all(&path) {
        fail!("{}: {error}", path.display());
    }
    match path.canonicalize() {
        Ok(path) => Ok(path.to_string_lossy().into_owned()),
        Err(error) => fail!("{}: {error}", path.display()),
    }
}

/// What the running window does with the folders a later launch handed it:
/// the socket's thread gave them over a channel, and this runs them on the
/// engine's.
fn take_arrivals(world: &mut World) -> Outcome {
    let mut folders = Vec::new();
    let state = world.part::<Launches>();
    if let Some(arrivals) = &state.arrivals {
        while let Ok(batch) = arrivals.try_recv() {
            folders.extend(batch);
        }
    }
    for path in folders {
        world.dispatch("project.launch", json!({"path": path}))?;
    }
    Ok(())
}

/// The app as main.cpp runs it: connected, and listening for later launches.
fn run(world: &mut World) -> Outcome {
    if world.part::<Launches>().running.is_some() {
        return Ok(());
    }
    if world.shell_subscriptions() == 0 {
        world.connect()?;
    }
    world.wait_for("the shell to start", |w| w.running())?;
    world.sync()?;
    let (send, receive) = channel();
    let dir = state_dir(world);
    let send = std::sync::Mutex::new(send);
    let listener = single_instance::listen(&dir, move |folders| {
        if let Ok(send) = send.lock() {
            let _ = send.send(folders);
        }
    });
    let Some(listener) = listener else {
        fail!("the running app cannot listen for later launches");
    };
    let connections = world.mc.connections.len();
    let state = world.part::<Launches>();
    state.running = Some(listener);
    state.arrivals = Some(receive);
    state.connections_before = connections;
    Ok(())
}

/// The later launch, up to where it would start its own MC.
fn launch_again(world: &mut World, path: String) -> Outcome {
    world.part::<Launches>().folder = path.clone();
    // The second process blocks on the socket while this one answers it.
    let done = Arc::new(AtomicBool::new(false));
    let forwarded = Arc::new(AtomicBool::new(false));
    let dir = state_dir(world);
    let later = {
        let (done, forwarded) = (done.clone(), forwarded.clone());
        std::thread::spawn(move || {
            forwarded.store(single_instance::forward(&dir, &[path]), Ordering::SeqCst);
            done.store(true, Ordering::SeqCst);
        })
    };
    world.wait_for("the later launch to reach the running app", move |_| {
        done.load(Ordering::SeqCst)
    })?;
    let _ = later.join();
    world.part::<Launches>().forwarded = forwarded.load(Ordering::SeqCst);
    take_arrivals(world)?;
    world.sync()
}

fn created(world: &World) -> Vec<Json> {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| {
            rpc.method == "projects.mutate" && rpc.payload["type"] == json!("project.create")
        })
        .map(|rpc| rpc.payload.clone())
        .collect()
}

/// The project of the draft the window shows.
fn draft_project(world: &World) -> String {
    let route = world.state("route");
    if at(&route, "kind") != &json!("draft") {
        return String::new();
    }
    drafts::draft(world.engine(), &text(&route["draftId"]))
        .map(|d| d.project_id)
        .unwrap_or_default()
}

fn leaf(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

pub fn register(steps: &mut Steps) {
    steps.step("the app is running", |world, _, _| run(world));
    // A launch that names no folder asks nobody and goes straight to
    // listening: it must find the running app's socket taken and leave it
    // alone.
    steps.step(
        "the user launches the app again without a folder",
        |world, _, _| {
            let later = single_instance::listen(&state_dir(world), |_| {});
            expect!(
                later.is_none(),
                "the later launch took the running app's socket"
            );
            Ok(())
        },
    );
    steps.step(
        "the user launches the app again with a folder path",
        |world, _, _| {
            let path = folder(world, "shop")?;
            launch_again(world, path)
        },
    );
    steps.step(
        "the running window adds the folder as a project and opens a new thread there",
        |world, _, _| {
            world.wait_for_with(
                |w| created(w).len() == 1 && !draft_project(w).is_empty(),
                |w| {
                    format!(
                        "the project and its thread; the MC was asked for {}, the route is {}",
                        show(&json!(created(w))),
                        show(&w.state("route"))
                    )
                },
            )?;
            let wanted = world.part::<Launches>().folder.clone();
            let project = created(world).remove(0);
            expect!(
                project["workspaceRoot"] == json!(wanted)
                    && json!(draft_project(world)) == project["projectId"],
                "the project is {}, the draft in {}",
                show(&project),
                draft_project(world)
            );
            Ok(())
        },
    );
    steps.step("no second server starts", |world, _, _| {
        // The later launch ended once the running app took the folder, and
        // the MC has the one shell.
        let before = world.part::<Launches>().connections_before;
        let forwarded = world.part::<Launches>().forwarded;
        let now = world.mc.connections.len();
        expect!(
            forwarded && now == before,
            "forwarded: {forwarded}; the MC has {now} connections"
        );
        Ok(())
    });
    steps.step(&format!("{Q} is already a project"), |world, c, _| {
        let path = folder(world, leaf(&c[0]))?;
        world.mc.projects.insert(
            "api".into(),
            json!({"id": "api", "title": "api", "workspaceRoot": path, "scripts": [],
                   "createdAt": "2026-09-01T09:00:00Z", "updatedAt": "2026-09-01T09:00:00Z"}),
        );
        // With a thread of its own, which a launch must not just reopen.
        world.mc.threads.insert(
            "t-api".into(),
            json!({"id": "t-api", "projectId": "api", "title": "Earlier work",
                   "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"}),
        );
        run(world)?;
        let key = format!("{}:t-api", world.mc.environment_id);
        world.dispatch("thread.open", json!({"key": key}))?;
        world.wait_for("the earlier thread", |w| {
            at(&w.state("route"), "kind") == &json!("thread")
        })
    });
    steps.step(
        &format!("the user launches the app again with {Q}"),
        |world, c, _| {
            let path = folder(world, leaf(&c[0]))?;
            launch_again(world, path)
        },
    );
    steps.step(
        "a new thread opens in the existing project",
        |world, _, _| {
            world.wait_for_with(
                |w| draft_project(w) == "api",
                |w| {
                    format!(
                        "a new thread in the project; the route is {}",
                        show(&w.state("route"))
                    )
                },
            )?;
            let forwarded = world.part::<Launches>().forwarded;
            expect!(
                forwarded && created(world).is_empty(),
                "a second project was created: {}",
                show(&json!(created(world)))
            );
            Ok(())
        },
    );
}
