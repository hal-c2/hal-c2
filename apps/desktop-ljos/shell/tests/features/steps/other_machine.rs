//! A thread whose files are on another machine than the desktop, served by
//! an MC there (desktop-qt's OtherMachineSteps.cpp;
//! files/file-viewer-and-editing.feature): no editor or file manager starts
//! on that machine, and the user is told the files can't be opened here
//! yet.

use serde_json::json;

use serde_json::Value as Json;

use super::files_workspace::{
    editor_calls, editor_id, open_files_tab, serve_config, set_config, show_calls, workspace_root,
};
use crate::expect;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::{OTHER_MACHINE, World};

/// What the MCs had been asked to start before the user acted.
#[derive(Default)]
struct Started {
    calls: usize,
}

fn toast_titles(world: &World) -> Vec<String> {
    at(&world.state("toasts"), "items")
        .as_array()
        .map(|items| items.iter().map(|item| text(&item["title"])).collect())
        .unwrap_or_default()
}

/// This computer's PATH holding only these commands, for as long as the
/// scenario runs.
#[derive(Default)]
struct InstalledEditors {
    dir: Option<tempfile::TempDir>,
    path: Option<std::ffi::OsString>,
    /// A folder per call: the shell looks again when PATH changes.
    folders: Vec<std::path::PathBuf>,
}

impl InstalledEditors {
    fn install(&mut self, commands: &[&str]) -> Outcome {
        use std::os::unix::fs::PermissionsExt as _;
        if self.dir.is_none() {
            self.path = std::env::var_os("PATH");
            self.dir = Some(
                tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR"))
                    .map_err(|e| format!("no folder for the editors: {e}"))?,
            );
        }
        let Some(dir) = &self.dir else {
            crate::fail!("no folder for the editors");
        };
        let folder = dir.path().join(self.folders.len().to_string());
        std::fs::create_dir_all(&folder).map_err(|e| format!("{e}"))?;
        for command in commands {
            let file = folder.join(command);
            std::fs::write(&file, "#!/bin/sh\n").map_err(|e| format!("no {command}: {e}"))?;
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755))
                .map_err(|e| format!("{e}"))?;
        }
        self.folders.push(folder);
        let path = std::env::join_paths(&self.folders).map_err(|e| format!("{e}"))?;
        // SAFETY: the scenarios run one at a time on this thread.
        unsafe { std::env::set_var("PATH", path) };
        Ok(())
    }
}

impl Drop for InstalledEditors {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            // SAFETY: as in `install`.
            unsafe { std::env::set_var("PATH", path) };
        }
    }
}

fn ssh_name(host: &str) -> Json {
    json!({"kind": "mdns", "host": host})
}

/// The thread on another machine that advertises `targets`, this one
/// having VS Code.
fn on_another_machine(world: &mut World, targets: Json) -> Outcome {
    world.mc.part::<InstalledEditors>().install(&["code"])?;
    set_config(
        world,
        json!({"availableEditors": ["sublime"], "remoteOpenTargets": targets}),
    )?;
    world.served_from(OTHER_MACHINE)?;
    open_files_tab(world)
}

fn offered(world: &World) -> Vec<String> {
    at(&world.state("workspace"), "editors")
        .as_array()
        .map(|editors| editors.iter().map(|e| text(at(e, "id"))).collect())
        .unwrap_or_default()
}

pub fn register(steps: &mut Steps) {
    steps.extension(serve_config);
    steps.step(
        "the thread's files are on (?:an MC on another machine the client is paired with|an MC reached through an SSH port forward)",
        |world, _, _| {
            // This machine's editors are the ones offered, wherever the
            // thread runs.
            set_config(
                world,
                json!({"availableEditors": ["vscode", "file-manager"],
                       "shellRevealInFileManager": true}),
            )?;
            // An MC elsewhere says so by its machine's id, whatever address
            // reaches it: an SSH port forward is a loopback one. It keeps no
            // folder of anyone's on this machine.
            world.served_from(OTHER_MACHINE)?;
            open_files_tab(world)?;
            let started = editor_calls(world)?.len();
            world.mc.part::<Started>().calls = started;
            Ok(())
        },
    );

    steps.step(
        &format!("the thread's environment is on another machine reachable over SSH as {Q}"),
        |world, c, _| on_another_machine(world, json!([ssh_name(&c[0])])),
    );
    steps.step(
        "the thread's environment is on another machine reachable over SSH",
        |world, _, _| on_another_machine(world, json!([ssh_name("devbox")])),
    );
    steps.step(
        "the thread's environment is on another machine with no SSH route",
        |world, _, _| on_another_machine(world, json!([])),
    );
    steps.step(
        &format!("the user opens the thread's workspace in {Q}"),
        |world, c, _| {
            world.dispatch(
                "workspace.openInEditor",
                json!({"editorId": editor_id(&c[0])?}),
            )?;
            world.sync()
        },
    );
    steps.step(
        &format!("the local {Q} opens the workspace on {Q} over SSH"),
        |world, c, _| {
            let expected = format!(
                "{}://vscode-remote/ssh-remote+{}{}",
                editor_id(&c[0])?,
                c[1],
                workspace_root(world)
            );
            let wanted = expected.clone();
            world.wait_for_with(
                move |w| w.opened_urls() == [wanted.clone()],
                move |w| format!("{expected}; the links are {:?}", w.opened_urls()),
            )?;
            expect!(
                editor_calls(world)?.is_empty(),
                "an MC was asked to start an editor"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("this computer has {Q} and {Q} installed that can open folders over SSH"),
        |world, _, _| {
            world
                .mc
                .part::<InstalledEditors>()
                .install(&["code", "zed"])
        },
    );
    steps.step(
        &format!("this computer has {Q} installed which cannot"),
        |world, _, _| world.mc.part::<InstalledEditors>().install(&["subl"]),
    );
    steps.step(
        "the user looks at the editors offered for the thread's workspace",
        |world, _, _| {
            // The MC saying something new has the shell look again, as a new thread does.
            set_config(
                world,
                json!({"remoteOpenTargets": [ssh_name("devbox.local")]}),
            )?;
            world.sync()
        },
    );
    steps.step(&format!("{Q} and {Q} are offered"), |world, c, _| {
        // The models a new task offers (connection_kept.rs) share the words.
        if let Some(hook) = world.on_settings_page.get("areOffered").cloned() {
            return hook(world, c);
        }
        let expected = vec![editor_id(&c[0])?.to_owned(), editor_id(&c[1])?.to_owned()];
        world.wait_for_with(
            move |w| offered(w) == expected,
            |w| format!("{:?}", offered(w)),
        )
    });
    steps.step(&format!("{Q} is not among them"), |world, c, _| {
        let id = editor_id(&c[0])?;
        let offered = offered(world);
        expect!(!offered.iter().any(|e| e == id), "{offered:?}");
        Ok(())
    });
    steps.step(
        "the user looks at opening the thread's workspace in an editor",
        |world, _, _| world.sync(),
    );
    steps.step(
        "opening is unavailable and the user is told no SSH route is known",
        |world, _, _| {
            let offered = offered(world);
            expect!(offered.is_empty(), "{offered:?}");
            world.wait_for_with(
                |w| text(at(&w.state("workspace"), "noSshRoute")).starts_with("No SSH route to "),
                |w| show(&w.state("workspace")),
            )
        },
    );

    steps.step(
        &format!("the user reveals {Q} in the file manager"),
        |world, c, _| {
            world.dispatch("files.reveal", json!({"path": c[0]}))?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user opens {Q} in an editor"),
        |world, c, _| {
            world.dispatch("files.openInEditor", json!({"path": c[0]}))?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user follows the path {Q} in a terminal"),
        |world, c, _| {
            world.dispatch(
                "terminal.followLink",
                json!({"kind": "path", "text": c[0], "cwd": ""}),
            )?;
            world.sync()
        },
    );

    steps.step("nothing is started on that machine", |world, _, _| {
        let since = world.mc.part::<Started>().calls;
        let calls: Vec<_> = editor_calls(world)?.into_iter().skip(since).collect();
        expect!(calls.is_empty(), "the MC was asked {}", show_calls(&calls));
        Ok(())
    });
    steps.step(
        "the user is told the files are on another machine and can't be opened here yet",
        |world, _, _| {
            let told = "The files are on another machine and can't be opened here yet.";
            world.wait_for_with(
                |w| toast_titles(w).iter().any(|t| t == told),
                |w| format!("\"{told}\"; the toasts are {}", w.state("toasts")),
            )
        },
    );
}
