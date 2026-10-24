//! A thread whose files are on another machine than the desktop, served by
//! an MC there (desktop-qt's OtherMachineSteps.cpp;
//! files/file-viewer-and-editing.feature): no editor or file manager starts
//! on that machine, and the user is told the files can't be opened here
//! yet.

use serde_json::json;

use super::files_workspace::{editor_calls, open_files_tab, set_config, show_calls};
use crate::harness::{Q, Steps, at, text};
use crate::world::{OTHER_MACHINE, World};
use crate::expect;

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

pub fn register(steps: &mut Steps) {
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

    steps.step(&format!("the user reveals {Q} in the file manager"), |world, c, _| {
        world.dispatch("files.reveal", json!({"path": c[0]}))?;
        world.sync()
    });
    steps.step(&format!("the user opens {Q} in an editor"), |world, c, _| {
        world.dispatch("files.openInEditor", json!({"path": c[0]}))?;
        world.sync()
    });
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
