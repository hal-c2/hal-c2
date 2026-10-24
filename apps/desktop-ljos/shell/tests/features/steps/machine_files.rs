//! Another machine's files opened from the folder the MC on this machine
//! keeps for it (desktop-qt's MachineFilesSteps.cpp;
//! files/files-on-another-machine.feature): the shell asks its MC where a
//! cluster member's file is here (`files.localPath`), and starts the editor
//! or file manager through that MC, never the member's.

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use serde_json::{Value as Json, json};

use super::files_workspace::{editor_calls, open_files_tab, set_config, workspace_root};
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::{THIS_MACHINE, World};
use crate::expect;

/// What the MC on this machine answers `files.localPath` with.
struct MachineFolders {
    /// Where the MC mounts its members' folders.
    root: String,
    /// An MC from before files.localPath answers null.
    answers: bool,
    /// Without FUSE the MC says so instead of a path.
    can_show: bool,
    /// On a platform with no folders yet (macOS, Windows) the MC names it.
    unsupported_on: String,
    /// The editor calls made before the user acted.
    calls_before: usize,
}

impl Default for MachineFolders {
    fn default() -> MachineFolders {
        MachineFolders {
            root: "/home/user/.local/state/hal-c2/elixir/machines".into(),
            answers: false,
            can_show: true,
            unsupported_on: String::new(),
            calls_before: 0,
        }
    }
}

const THREAD: &str = "t-cart";

fn unsupported_message(label: &str, platform: &str) -> String {
    format!(
        "The file is on \"{label}\". Opening another machine's files on {platform} is not supported yet; \
         edit it or copy its text in HAL-C2's file viewer."
    )
}

fn files_local_path(mc: &mut FakeMc, rpc: &Rpc) {
    let (answers, can_show, unsupported_on, root) = {
        let f = mc.part::<MachineFolders>();
        (f.answers, f.can_show, f.unsupported_on.clone(), f.root.clone())
    };
    if !answers {
        mc.reply(rpc, Json::Null);
        return;
    }
    let environment = text(&rpc.payload["environmentId"]);
    let path = text(&rpc.payload["path"]);
    if !mc.members.contains(&environment) {
        mc.reply(
            rpc,
            json!({"reason": "not_a_member",
                   "message": "The file is on a machine that is not in this machine's cluster."}),
        );
        return;
    }
    let label = mc
        .peer_labels
        .get(&environment)
        .cloned()
        .unwrap_or_else(|| environment.clone());
    // As machine_files.ex message/2 words it.
    if !unsupported_on.is_empty() {
        mc.reply(
            rpc,
            json!({"reason": "unsupported", "machine": label,
                   "message": unsupported_message(&label, &unsupported_on)}),
        );
        return;
    }
    if !can_show {
        mc.reply(
            rpc,
            json!({"reason": "no_fuse", "machine": label,
                   "message": format!("The file is on \"{label}\". To open it here, install FUSE 3 (fuse3).")}),
        );
        return;
    }
    mc.reply(rpc, json!({"path": format!("{root}/{label}{path}")}));
}

/// Every `shell.openInEditor` since the user acted, with the MC it went to.
fn started_now(world: &World) -> Vec<Rpc> {
    let before = world.mc.peek::<MachineFolders>().map_or(0, |f| f.calls_before);
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == "shell.openInEditor")
        .skip(before)
        .cloned()
        .collect()
}

fn started_since_acting(world: &mut World) -> Outcome<Vec<Rpc>> {
    world.sync()?;
    Ok(started_now(world))
}

fn describe(calls: &[Rpc]) -> String {
    if calls.is_empty() {
        return "nothing".into();
    }
    calls
        .iter()
        .map(|rpc| format!("{} on \"{}\"", show(&rpc.payload), rpc.environment))
        .collect::<Vec<_>>()
        .join(", ")
}

fn toast_titles(world: &World) -> Vec<String> {
    at(&world.state("toasts"), "items")
        .as_array()
        .map(|items| items.iter().map(|item| text(&item["title"])).collect())
        .unwrap_or_default()
}

fn wait_for_toast(world: &mut World, told: String) -> Outcome {
    world.wait_for_with(
        |w| toast_titles(w).contains(&told),
        |w| format!("\"{told}\"; the toasts are {}", show(&w.state("toasts"))),
    )
}

pub fn register(steps: &mut Steps) {
    steps.extension(|mc| mc.on_rpc("files.localPath", |mc, rpc| {
            files_local_path(mc, rpc);
            Ok(())
        }));

    steps.step(
        "the client is connected to the MC on the user's machine",
        |world, _, _| {
            world.mc.part::<MachineFolders>().answers = true;
            world.connect()?;
            world.served_from(THIS_MACHINE)?;
            // This machine's editors and file manager.
            set_config(
                world,
                json!({"availableEditors": ["vscode", "file-manager"],
                       "shellRevealInFileManager": true}),
            )
        },
    );
    steps.step(&format!("that MC is in a cluster with {Q}"), |world, c, _| {
        world.mc.join_named(&c[0]);
        world.sync()
    });
    steps.step(&format!("{Q} has the project {Q} at {Q}"), |world, c, _| {
        world.mc.send_peer_row_of(
            &c[0],
            &c[1],
            &json!({"id": c[1], "title": c[1], "workspaceRoot": c[2], "scripts": []}),
            "project",
        );
        world.sync()
    });
    steps.step(
        "this machine has no way to show another machine's folder",
        |world, _, _| {
            world.mc.part::<MachineFolders>().can_show = false;
            Ok(())
        },
    );
    steps.step(
        "this machine is a Mac, which cannot show another machine's folder yet",
        |world, _, _| {
            world.mc.part::<MachineFolders>().unsupported_on = "macOS".into();
            Ok(())
        },
    );

    steps.step(&format!("a thread of {Q} runs on {Q}"), |world, c, _| {
        world.mc.send_peer_row(
            &c[1],
            THREAD,
            &json!({"id": THREAD, "title": "Cart", "projectId": c[0],
                    "createdAt": "2026-10-16T09:00:00Z", "updatedAt": "2026-10-16T09:00:00Z"}),
        );
        world.sync()?;
        let key = format!("{}:{THREAD}", c[1]);
        let route = Route::Thread(key.clone());
        world.with::<Navigation, _>(|n, engine| n.open(engine, route))?;
        world.pump()?;
        world.wait_for_with(
            |w| text(&w.state("workspace")["threadKey"]) == key && !workspace_root(w).is_empty(),
            |w| {
                format!(
                    "the header to show {key}; it shows {}",
                    show(&w.state("workspace"))
                )
            },
        )?;
        open_files_tab(world)?;
        let before = editor_calls(world)?.len();
        world.mc.part::<MachineFolders>().calls_before = before;
        Ok(())
    });

    steps.step(
        &format!("(\"VS Code\"|the file manager|the editor) on this machine opens {Q} from the folder kept for {Q}"),
        |world, c, _| {
            let root = world.mc.part::<MachineFolders>().root.clone();
            let local = format!("{root}/{}{}/{}", c[2], workspace_root(world), c[1]);
            let reveal = c[0] == "the file manager";
            let mut wanted = json!({"cwd": local,
                                    "editor": if reveal { "file-manager" } else { "vscode" }});
            if reveal {
                wanted["reveal"] = json!(true);
            }
            world.wait_for_with(
                |w| !started_now(w).is_empty(),
                |_| format!("{} to open {local}", c[0]),
            )?;
            let started = started_since_acting(world)?;
            // Through the MC on this machine, which the shell is connected to.
            let shell_mc = world.mc.environment_id.clone();
            expect!(
                started.len() == 1
                    && started[0].payload == wanted
                    && (started[0].environment.is_empty() || started[0].environment == shell_mc),
                "{} was wanted on \"{shell_mc}\"; the MC was asked {}",
                show(&wanted),
                describe(&started)
            );
            Ok(())
        },
    );

    steps.step(&format!("nothing is started on {Q}"), |world, c, _| {
        let elsewhere: Vec<Rpc> = started_since_acting(world)?
            .into_iter()
            .filter(|rpc| rpc.environment == c[0])
            .collect();
        expect!(
            elsewhere.is_empty(),
            "the MC was asked {}",
            describe(&elsewhere)
        );
        Ok(())
    });

    steps.step(
        &format!("the user is told the file is on {Q} and what to install to open it here"),
        |world, c, _| {
            wait_for_toast(
                world,
                format!(
                    "The file is on \"{}\". To open it here, install FUSE 3 (fuse3).",
                    c[0]
                ),
            )?;
            let started = started_since_acting(world)?;
            expect!(started.is_empty(), "the MC was asked {}", describe(&started));
            Ok(())
        },
    );
    steps.step(
        &format!("the user is told the file is on {Q} and to edit or copy it in HAL-C2's file viewer"),
        |world, c, _| wait_for_toast(world, unsupported_message(&c[0], "macOS")),
    );
}
