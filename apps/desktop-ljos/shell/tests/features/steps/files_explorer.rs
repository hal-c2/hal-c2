//! The Files tab's tree beyond browsing (features/files/file-explorer.feature,
//! desktop-qt's FilesExplorerSteps.cpp): every folder at once, following the
//! agent's changes, and what a file's entry offers.

use hal_c2_shell::thread_view::file_tree::FileTreeModel;
use serde_json::json;

use super::fake_files::fake_files;
use super::files_workspace::{
    OpenedInEditor, choose, describe_tree, editor_calls, file_status, open_files_tab,
    open_path, set_config, show_calls, show_panel, tree, visible_paths, wait_for_tree,
    workspace_root,
};
use super::stream::{add_item, start_run};
use crate::brick;
use crate::harness::{Outcome, Q, Steps, at, show};
use crate::world::World;
use crate::expect;

#[derive(Default)]
struct Explorer {
    /// The file the user last chose something for.
    chosen: String,
}

fn composer_text(world: &World) -> String {
    match &at(&world.state("composer"), "text") {
        serde_json::Value::String(s) => s.clone(),
        _ => String::new(),
    }
}

fn all_expanded(world: &World) -> bool {
    tree(world)
        .ok()
        .and_then(|t| FileTreeModel::read(world.engine(), t, |tree| tree.all_expanded()))
        .unwrap_or(false)
}

fn leaf(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn toggle_all(world: &mut World) -> Outcome {
    let shown = brick::shown(world)?;
    shown.click(world, "filesExpandAll")
}

pub fn register(steps: &mut Steps) {
    steps.step("the user expands every folder", |world, _, _| {
        show_panel(world)?;
        toggle_all(world)?;
        wait_for_tree(world)
    });
    steps.step(&format!("{Q} is visible"), |world, c, _| {
        wait_for_tree(world)?;
        let shown = visible_paths(world);
        expect!(
            shown.iter().any(|p| leaf(p) == c[0]) && all_expanded(world),
            "{}",
            describe_tree(world)
        );
        // Ignored folders stay closed.
        let ignored = fake_files(&mut world.mc).ignored.clone();
        for path in &shown {
            for folder in &ignored {
                expect!(
                    !path.starts_with(&format!("{folder}/")),
                    "{}",
                    describe_tree(world)
                );
            }
        }
        Ok(())
    });
    steps.step("the user collapses every folder", |world, _, _| {
        toggle_all(world)
    });
    steps.step("only the top level is visible", |world, _, _| {
        let shown = visible_paths(world);
        expect!(
            !shown.is_empty() && !all_expanded(world) && shown.iter().all(|p| !p.contains('/')),
            "{}",
            describe_tree(world)
        );
        Ok(())
    });

    // The user has the file's folder open when the agent's change lands.
    steps.step(&format!("the agent creates {Q}"), |world, c, _| {
        open_files_tab(world)?;
        let folder = c[0].rsplit_once('/').map_or("", |(folder, _)| folder).to_owned();
        if !folder.is_empty() {
            let tree = tree(world)?;
            FileTreeModel::update(world.engine(), tree, |t| t.expand(&folder));
        }
        wait_for_tree(world)?;
        expect!(!visible_paths(world).contains(&c[0]), "{}", describe_tree(world));
        fake_files(&mut world.mc)
            .files
            .insert(c[0].clone(), "export const checkout = true;\n".into());
        start_run(world, 30, "running")?;
        add_item(
            world,
            "file_change",
            json!({"changes": [{"path": c[0]}]}),
        )?;
        Ok(())
    });
    steps.step(&format!("{Q} appears in the tree"), |world, c, _| {
        world.wait_for_with(
            |w| visible_paths(w).contains(&c[0]),
            |w| describe_tree(w),
        )
    });

    steps.step(&format!("the user adds {Q} to the chat"), |world, c, _| {
        // With no chat open the Files tab is not on screen; the action is what
        // is left to ask.
        if world.state("composer").is_null() {
            world.dispatch("files.addToChat", json!({"path": c[0]}))
        } else {
            choose(world, &c[0], "fileEntryAddToChat")
        }
    });
    steps.step(&format!("the composer mentions {Q}"), |world, c, _| {
        let mention = format!("[{}]({}) ", leaf(&c[0]), c[0]);
        world.wait_for_with(
            |w| composer_text(w) == mention,
            |w| format!("the mention; the composer has \"{}\"", composer_text(w)),
        )
    });
    steps.step(&format!("no chat is open for {Q}"), |world, _, _| {
        // Away from every thread and draft: the settings.
        world.dispatch("settings.open", json!({}))?;
        world.sync()?;
        let composer = world.state("composer");
        expect!(composer.is_null(), "a composer is open: {}", show(&composer));
        Ok(())
    });
    steps.step(
        "the user is told to open a chat for this project and try again",
        |world, _, _| {
            let told = |w: &World| {
                at(&w.state("toasts"), "items")
                    .as_array()
                    .is_some_and(|toasts| {
                        toasts.iter().any(|toast| {
                            toast["type"] == json!("error")
                                && toast["title"] == json!("Unable to add to chat")
                                && toast["description"]
                                    == json!("Open a chat for this project and try again.")
                        })
                    })
            };
            world.wait_for_with(told, |w| {
                format!("the toast; the shell shows {}", show(&w.state("toasts")))
            })
        },
    );

    steps.step(
        &format!("the user chooses to (open|reveal in its folder|open with the editor|copy a mention of) {Q}"),
        |world, c, _| {
            world.part::<Explorer>().chosen = c[1].clone();
            match c[0].as_str() {
                "open" => choose(world, &c[1], "fileEntryOpen"),
                "copy a mention of" => choose(world, &c[1], "fileEntryCopyMention"),
                what => {
                    // The environment has an editor and a file manager that can
                    // select a file.
                    set_config(
                        world,
                        json!({"availableEditors": ["vscode", "file-manager"],
                               "shellRevealInFileManager": true}),
                    )?;
                    let entry = if what == "reveal in its folder" {
                        "fileEntryReveal"
                    } else {
                        "fileEntryEditor-vscode"
                    };
                    choose(world, &c[1], entry)
                }
            }
        },
    );
    steps.step("the file opens in the viewer", |world, _, _| {
        let chosen = world.part::<Explorer>().chosen.clone();
        world.wait_for_with(
            |w| open_path(w) == chosen && file_status(w) == "ready",
            |w| {
                format!(
                    "{chosen} in the viewer; it has \"{}\" ({})",
                    open_path(w),
                    file_status(w)
                )
            },
        )
    });
    steps.step("the system file manager shows the file", |world, _, _| {
        let calls = editor_calls(world)?;
        let wanted = json!({
            "cwd": format!("{}/{}", workspace_root(world), world.part::<Explorer>().chosen),
            "editor": "file-manager",
            "reveal": true,
        });
        expect!(
            calls.len() == 1 && calls[0] == wanted,
            "the MC was asked {}",
            show_calls(&calls)
        );
        Ok(())
    });
    steps.step("the file opens in the user's editor", |world, _, _| {
        let calls = editor_calls(world)?;
        // The explorer's file in VS Code, or the changed file another surface
        // opened.
        let (path, editor) = {
            let other = world.part::<OpenedInEditor>();
            (other.path.clone(), other.editor.clone())
        };
        let chosen = world.part::<Explorer>().chosen.clone();
        let wanted = json!({
            "cwd": format!("{}/{}", workspace_root(world), if path.is_empty() { &chosen } else { &path }),
            "editor": if path.is_empty() { "vscode".to_owned() } else { editor },
        });
        expect!(
            calls.len() == 1 && calls[0] == wanted,
            "the MC was asked {}",
            show_calls(&calls)
        );
        Ok(())
    });
    steps.step(
        &format!("a mention of {Q} is on the clipboard"),
        |world, c, _| {
            let clipboard = world.clipboard();
            expect!(
                clipboard == format!("[{}]({})", leaf(&c[0]), c[0]),
                "the clipboard has \"{clipboard}\""
            );
            Ok(())
        },
    );
}

