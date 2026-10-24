//! The file viewer beyond reading (features/files/file-viewer-and-editing.feature,
//! desktop-qt's FilesViewerSteps.cpp): rendered files and their source, the
//! path trail, opening in an editor, and editing with its saves, on the Files
//! tab as the right panel draws it. panel.rs has opening, wrapping and
//! retrying. The MC's `projects.writeFile` is faked here.

use std::collections::HashSet;

use fancy_regex::Regex;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::thread_view::workspace_files::WorkspaceFiles;
use ljos::prelude::{ObjectId, Value};
use serde_json::{Value as Json, json};

use super::fake_files::{FakeFiles, fake_files};
use super::files_workspace::{
    choose, describe_tree, editor_calls, editor_id, ensure_viewer_file, files, file_status,
    flag_prop, open_file, open_path, set_config, show_calls, show_panel, text_prop,
    wait_for_tree, workspace_root,
};
use crate::brick::{self, Brick};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::{THIS_MACHINE, World};
use crate::{expect, fail};

#[derive(Default)]
struct Viewer {
    /// Paths the MC refuses to write.
    unwritable: HashSet<String>,
    /// The session lacks terminal:operate, so the MC refuses writes by full path.
    no_terminal: bool,
    /// The file the scenario edits, and what the user typed into it.
    edited: String,
    typed: String,
    /// The file opened by a description ("a file larger than one megabyte").
    described: String,
    /// How many times the MC had been asked to open an editor before the step under test.
    editor_calls_before: usize,
}

fn viewer(world: &mut World) -> &mut Viewer {
    world.mc.part::<Viewer>()
}

/// The payloads of every `projects.writeFile` the MC was asked.
fn writes(world: &World) -> Vec<Json> {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == "projects.writeFile")
        .map(|rpc| rpc.payload.clone())
        .collect()
}

fn describe_viewer(world: &World) -> String {
    let kind = text_prop(world, "renderKind");
    let note = match text_prop(world, "saveProblem") {
        problem if problem.is_empty() => text_prop(world, "readOnlyReason"),
        problem => problem,
    };
    format!(
        "the viewer has \"{}\" ({}, {}{}{}), note \"{note}\"",
        open_path(world),
        file_status(world),
        if kind.is_empty() { "text" } else { &kind },
        if flag_prop(world, "rendered") { ", rendered" } else { "" },
        if flag_prop(world, "editing") { ", editing" } else { "" },
    )
}

/// Whether the panel draws its part named `object_name` (one a Loader makes
/// may not be there yet).
fn shown(world: &mut World, object_name: &str) -> bool {
    let Ok(brick) = brick::shown(world) else {
        return false;
    };
    match brick.find(world, object_name) {
        Ok(Some(item)) => brick.flag(world, item, "visible"),
        _ => false,
    }
}

/// Whether the shell shows copying's "File contents copied" toast, saying
/// `description`.
fn told_copied(world: &World, description: &str) -> bool {
    at(&world.state("toasts"), "items")
        .as_array()
        .is_some_and(|items| {
            items.iter().any(|toast| {
                at(toast, "type") == "success"
                    && at(toast, "title") == "File contents copied"
                    && text(at(toast, "description")) == description
            })
        })
}

fn describe_toasts(world: &World) -> String {
    format!("the shell shows {}", show(&world.state("toasts")))
}

/// The file in the viewer, with the panel on screen.
fn view(world: &mut World, path: &str) -> Outcome {
    ensure_viewer_file(world, path);
    show_panel(world)?;
    open_file(world, path)?;
    wait_for_tree(world)
}

fn start_editing(world: &mut World, path: &str) -> Outcome {
    view(world, path)?;
    // A rendered file is edited as its source.
    brick::shown(world)?.click(world, "fileEdit")?;
    world.wait_for_with(
        |w| flag_prop(w, "editing") && shown_in(w, "fileEditor"),
        describe_viewer,
    )?;
    viewer(world).edited = path.to_owned();
    Ok(())
}

/// `shown` for a wait's condition, which has no world to change.
fn shown_in(world: &World, object_name: &str) -> bool {
    let Some(brick) = world.peek_part::<brick::Shown>().and_then(|s| s.0) else {
        return false;
    };
    match brick.find(world, object_name) {
        Ok(Some(item)) => brick.flag(world, item, "visible"),
        _ => false,
    }
}

/// Types into the editor as the user does.
fn type_change(world: &mut World) -> Outcome {
    let typed = "edited by hand ";
    let brick = brick::shown(world)?;
    brick.click(world, "fileEditorView")?;
    let editor = brick.item(world, "fileEditor")?;
    expect!(
        brick.flag(world, editor, "activeFocus"),
        "the editor did not take the keyboard"
    );
    for character in typed.chars() {
        let key = if character == ' ' {
            "space".to_owned()
        } else {
            character.to_string()
        };
        brick.press(world, &key)?;
    }
    viewer(world).typed = typed.to_owned();
    expect!(
        text_prop(world, "text").contains(typed),
        "{}",
        describe_viewer(world)
    );
    Ok(())
}

/// The link of the task named `task` in what the rendered view draws.
fn task_link(world: &World, task: &str) -> Outcome<String> {
    let drawn = text_prop(world, "renderedText");
    let link = Regex::new(r"\[[☐☑]\]\((task:\d+)\) ([^\n]*)").map_err(|e| crate::harness::Failure(e.to_string()))?;
    for found in link.captures_iter(&drawn).flatten() {
        if found.get(2).is_some_and(|m| m.as_str().trim() == task)
            && let Some(url) = found.get(1)
        {
            return Ok(url.as_str().to_owned());
        }
    }
    fail!("the rendered file has no task \"{task}\": {drawn}")
}

/// `text` as a JS regular expression matching it literally.
fn js_escape(text: &str) -> String {
    let mut escaped = String::new();
    for c in text.chars() {
        if "\\^$.*+?()[]{}|/".contains(c) {
            escaped.push('\\');
        }
        escaped.push(c);
    }
    escaped
}

/// Clicks the task's box, as the user does: where the rendered view draws
/// it, in the prose that has it.
fn tick(world: &mut World, task: &str) -> Outcome {
    let brick = brick::shown(world)?;
    let rendered = brick.item(world, "fileRenderedMarkdown")?;
    let (x, y) = brick.text_point(
        world,
        rendered,
        "markdownProse",
        &format!("[☐☑] {}(?:[\\s\\u2028\\u2029]|$)", js_escape(task)),
    )?;
    let (width, height) = brick.size(world);
    expect!(
        x >= 0.0 && y >= 0.0 && x < width && y < height,
        "the box of \"{task}\" is drawn out of the window at {x},{y}"
    );
    let before = writes(world).len();
    world.click_at(x, y)?;
    world.wait_for("the file to be written", |w| writes(w).len() > before)?;
    world.sync()
}

/// A path with a folder and an extension is a file for the viewer.
fn is_file(path: &str) -> bool {
    let Some((name, extension)) = path.rsplit_once('.') else {
        return false;
    };
    !name.is_empty()
        && !name.chars().any(|c| c.is_whitespace() || c == ':')
        && !extension.is_empty()
        && extension.chars().all(|c| c.is_ascii_lowercase())
        && path.contains('/')
}

/// The viewer steps' side of "the user is looking at <name>" (a thread's,
/// elsewhere): a path with a folder and an extension is a file to open in
/// the viewer, and true.
pub fn look_at_file(world: &mut World, path: &str) -> Outcome<bool> {
    if !is_file(path) {
        return Ok(false);
    }
    view(world, path)?;
    Ok(true)
}

/// Their side of "<name> opens" (a thread's, elsewhere): a path with a
/// folder and an extension is a file the viewer has open, and true.
pub fn file_opened(world: &mut World, path: &str) -> Outcome<bool> {
    if !is_file(path) {
        return Ok(false);
    }
    world.wait_for_with(
        |w| open_path(w) == path && file_status(w) == "ready",
        describe_viewer,
    )?;
    Ok(true)
}

/// Their side of "the user removes it" (a theme's, elsewhere): while an
/// attachment is open in its viewer it is removed from there, and true.
pub fn remove_viewed_attachment(world: &mut World) -> Outcome<bool> {
    if world.state("attachmentViewer").is_null() {
        return Ok(false);
    }
    brick::shown(world)?.click(world, "attachmentViewerRemove")?;
    world.sync()?;
    Ok(true)
}

fn lines_of(world: &World) -> usize {
    let engine = world.engine();
    files(world)
        .ok()
        .and_then(|f| WorkspaceFiles::lines(engine, f))
        .and_then(|lines| engine.object_model(lines))
        .map_or(0, |model| model.row_count())
}

pub fn register(steps: &mut Steps) {
    // As apps/server-ex lib/hal_c2/workspace.ex write_file: the file's new contents.
    steps.extension(|mc| {
        mc.on_rpc("projects.writeFile", |mc, rpc| {
            let path = text(at(&rpc.payload, "relativePath"));
            if mc.part::<Viewer>().unwritable.contains(&path) {
                mc.refuse(rpc, &format!("Could not write {path}."));
                return Ok(());
            }
            let contents = text(at(&rpc.payload, "contents"));
            if path.starts_with('/') && mc.part::<Viewer>().no_terminal {
                // As apps/server-ex lib/hal_c2/rpc.ex required_scope/2, checked by the socket.
                mc.refuse_with(
                    rpc,
                    "terminal:operate is required",
                    json!({"_tag": "EnvironmentScopeRequiredError", "requiredScope": "terminal:operate"}),
                );
                return Ok(());
            }
            let fake = fake_files(mc);
            if !path.starts_with('/') {
                fake.files.insert(path.clone(), contents);
            } else if fake.outside.contains_key(&path) {
                // By its full path, only a file that is already there.
                fake.outside.insert(path.clone(), contents);
            } else {
                mc.refuse(
                    rpc,
                    &format!(
                        "'{path}' is outside the workspace, where only a file that is already there can be saved."
                    ),
                );
                return Ok(());
            }
            mc.reply(rpc, json!({"relativePath": path}));
            Ok(())
        });
    });

    // Rendered and source.
    steps.step("the file is shown rendered", |world, _, _| {
        show_panel(world)?;
        world.wait_for_with(
            |w| flag_prop(w, "rendered") && shown_in(w, "fileRendered"),
            describe_viewer,
        )?;
        expect!(!shown(world, "fileLines"), "the source shows too");
        // What it draws: a page's markup as text, a table for CSV, Markdown as it reads.
        let brick = brick::shown(world)?;
        let kind = text_prop(world, "renderKind");
        let whole = text_prop(world, "text");
        if kind == "html" {
            let page = brick.find(world, "fileRenderedPage")?;
            expect!(
                shown(world, "fileRenderedPage")
                    && page.is_some_and(|p| brick.text_of(world, p, "text") == whole),
                "the page is not drawn"
            );
        } else {
            let item = brick.item(world, "fileRenderedMarkdown")?;
            let drawn = brick.text_of(world, item, "text");
            let table = "| order | total |\n| --- | --- |\n| 1001 | 12.50 |\n| 1002 | 7,25 |";
            expect!(
                if kind == "csv" {
                    drawn.starts_with(table)
                } else {
                    drawn == whole
                },
                "the rendered view draws \"{drawn}\""
            );
        }
        Ok(())
    });
    steps.step("the user switches to the source", |world, _, _| {
        brick::shown(world)?.click(world, "fileRender")
    });
    steps.step("the file's text is shown", |world, _, _| {
        world.wait_for_with(
            |w| !flag_prop(w, "rendered") && shown_in(w, "fileLines"),
            describe_viewer,
        )?;
        let path = open_path(world);
        let newlines = fake_files(&mut world.mc)
            .files
            .get(&path)
            .map_or(0, |contents| contents.matches('\n').count());
        let rows = lines_of(world);
        expect!(
            !shown(world, "fileRendered") && rows == newlines,
            "the viewer shows {rows} lines"
        );
        Ok(())
    });
    steps.step("the user switches back", |world, _, _| {
        brick::shown(world)?.click(world, "fileRender")
    });
    steps.step("the user chose to see Markdown source", |world, _, _| {
        view(world, "README.md")?;
        expect!(flag_prop(world, "rendered"), "{}", describe_viewer(world));
        brick::shown(world)?.click(world, "fileRender")?;
        expect!(!flag_prop(world, "rendered"), "{}", describe_viewer(world));
        let files = files(world)?;
        WorkspaceFiles::update(world.engine(), files, |f| f.close_file());
        world.pump()
    });
    steps.step("the Markdown source is shown", |world, _, _| {
        show_panel(world)?;
        world.wait_for_with(
            |w| {
                text_prop(w, "renderKind") == "markdown"
                    && !flag_prop(w, "rendered")
                    && shown_in(w, "fileLines")
            },
            describe_viewer,
        )?;
        // Kept on this device.
        let kept = Settings::of(world.engine()).device_value("fileSourceKinds");
        expect!(
            kept == Some(json!(["markdown"])),
            "the device keeps {}",
            kept.map(|k| show(&k)).unwrap_or_default()
        );
        Ok(())
    });

    // The path trail.
    steps.step(
        &format!("the user picks {Q} from the files in {Q}"),
        |world, c, _| {
            let brick = brick::shown(world)?;
            brick.click(world, &format!("filePathPart-{}", c[1]))?;
            let entry = format!("filePathSibling-{}/{}", c[1], c[0]);
            let mut found = None;
            world.wait_for_with(
                |w| {
                    found = menu_entry(w, brick, "filePathSiblings", &entry);
                    found.is_some()
                },
                |w| format!("{} to be listed in {}; {}", c[0], c[1], describe_tree(w)),
            )?;
            if let Some(item) = found
                && let Err(error) = world.engine().emit_by_name(item, "triggered", &[])
            {
                fail!("triggered: {error}");
            }
            world.pump()
        },
    );

    // Editors.
    steps.step(
        &format!("the thread runs on this computer, which has the editor {Q}"),
        |world, c, _| {
            world.mc.platform.clear();
            world
                .mc
                .platform
                .insert("machineId".into(), json!(THIS_MACHINE));
            world.mc.announce_environment();
            set_config(
                world,
                json!({"availableEditors": [editor_id(&c[0])?]}),
            )
        },
    );
    steps.step(&format!("the user opens {Q} in {Q}"), |world, c, _| {
        let calls = editor_calls(world)?.len();
        viewer(world).editor_calls_before = calls;
        choose(world, &c[0], &format!("fileEntryEditor-{}", editor_id(&c[1])?))
    });
    steps.step(&format!("{Q} opens {Q} on this computer"), |world, c, _| {
        let before = viewer(world).editor_calls_before;
        let calls: Vec<Json> = editor_calls(world)?.into_iter().skip(before).collect();
        let wanted = json!({
            "cwd": format!("{}/{}", workspace_root(world), c[1]),
            "editor": editor_id(&c[0])?,
        });
        expect!(
            calls.len() == 1 && calls[0] == wanted,
            "the MC was asked {}",
            show_calls(&calls)
        );
        Ok(())
    });
    steps.step(
        "the user opens the thread's workspace in an editor from the thread's details",
        |world, _, _| {
            let calls = editor_calls(world)?.len();
            viewer(world).editor_calls_before = calls;
            if !world.with::<RightPanel, _>(|p, _| p.details_open())? {
                world.dispatch("threadPanel.toggle", json!({}))?;
            }
            world.sync()?;
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n\
                 ThreadDetailsPanel { details: Shell.state.panel?.details ?? null }\n",
                280.0,
                800.0,
            )?;
            // A Ljós gap while the panel's clipped list ignores presses
            // (issue-clip-anchored-hit-test.md).
            brick::shown(world)?.click(world, "threadDetailsOpenEditor")?;
            world.sync()
        },
    );
    steps.step(
        &format!("{Q} opens the thread's workspace folder on the environment"),
        |world, c, _| {
            let before = viewer(world).editor_calls_before;
            let calls: Vec<Json> = editor_calls(world)?.into_iter().skip(before).collect();
            let root = workspace_root(world);
            let wanted = json!({"cwd": root, "editor": editor_id(&c[0])?});
            expect!(
                !root.is_empty() && calls.len() == 1 && calls[0] == wanted,
                "the MC was asked {}",
                show_calls(&calls)
            );
            // The button names the editor it opened.
            expect!(
                brick::shown(world)?.shows(world, &format!("Open in {}", c[0]))?,
                "the details do not name {}",
                c[0]
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} stays the preferred editor for next time"),
        |world, c, _| {
            world.sync()?;
            let editor = editor_id(&c[0])?;
            let workspace = world.state("workspace");
            let last = Settings::of(world.engine()).device_value("lastEditor");
            expect!(
                at(&workspace, "preferredEditorId") == editor && last == Some(json!(editor)),
                "the header shows {}",
                show(&workspace)
            );
            Ok(())
        },
    );

    // Editing.
    steps.step(&format!("the user is editing {Q}"), |world, c, _| {
        start_editing(world, &c[0])
    });
    steps.step("the user types a change and pauses", |world, _, _| {
        type_change(world)
    });
    steps.step(&format!("the change is written to {Q}"), |world, c, _| {
        let path = c[0].clone();
        world.wait_for_with(
            |w| held(w, &path),
            |w| {
                format!(
                    "{path} to hold the change; it was written {} time(s); {}",
                    writes(w).len(),
                    describe_viewer(w)
                )
            },
        )?;
        world.sync()?;
        let calls = writes(world);
        let typed = viewer(world).typed.clone();
        let root = workspace_root(world);
        let last = calls.last();
        expect!(
            last.is_some_and(|last| at(last, "cwd") == &json!(root)
                && at(last, "relativePath") == &json!(path)
                && text(at(last, "contents")).contains(&typed)),
            "the MC was asked {}",
            show_calls(&calls)
        );
        Ok(())
    });
    steps.step(
        &format!("the user typed a change in {Q} that is not saved yet"),
        |world, c, _| {
            // The pause that would save it never comes: only closing can write it.
            let files = files(world)?;
            WorkspaceFiles::set_save_delay(world.engine(), files, 60 * 60 * 1000);
            start_editing(world, &c[0])?;
            type_change(world)?;
            world.sync()?;
            let typed = viewer(world).typed.clone();
            let contents = fake_files(&mut world.mc)
                .files
                .get(&c[0])
                .cloned()
                .unwrap_or_default();
            expect!(
                flag_prop(world, "unsaved") && writes(world).is_empty() && !contents.contains(&typed),
                "the change is already written"
            );
            Ok(())
        },
    );
    steps.step("the user opens a file larger than one megabyte", |world, _, _| {
        let path = "logs/big.log";
        let fake = fake_files(&mut world.mc);
        fake.files.insert(path.into(), "line\n".repeat(200));
        fake.truncated.insert(path.into(), 3 * 1024 * 1024);
        show_panel(world)?;
        open_file(world, path)?;
        viewer(world).described = path.to_owned();
        expect!(file_status(world) == "ready", "{}", describe_viewer(world));
        Ok(())
    });
    steps.step("the file cannot be edited", |world, _, _| {
        let path = viewer(world).described.clone();
        let (files_before, outside_before) = {
            let fake = fake_files(&mut world.mc);
            (fake.files.clone(), fake.outside.clone())
        };
        let writes_before = writes(world).len();
        let reason = text_prop(world, "readOnlyReason");
        expect!(
            !flag_prop(world, "editable") && !reason.is_empty(),
            "{}",
            describe_viewer(world)
        );
        // The viewer says why (after "Not saved: " when an edit was refused), and its Edit takes no press.
        let brick = brick::shown(world)?;
        let edit = brick.item(world, "fileEdit")?;
        let note = brick.item(world, "fileNote")?;
        let said = brick.text_of(world, note, "text");
        expect!(
            brick.flag(world, edit, "visible")
                && !brick.flag(world, edit, "enabled")
                && brick.flag(world, note, "visible")
                && said.ends_with(&reason),
            "the viewer offers to edit; it says \"{said}\""
        );
        let target = files(world)?;
        let whole = text_prop(world, "text");
        WorkspaceFiles::update(world.engine(), target, |f| {
            f.set_editing(true);
            f.edit(&format!("{whole}changed\n"));
        });
        world.sync()?;
        let fake = fake_files(&mut world.mc);
        let unchanged = fake.files == files_before && fake.outside == outside_before;
        expect!(
            !path.is_empty()
                && !flag_prop(world, "editing")
                && writes(world).len() == writes_before
                && unchanged,
            "the file was changed"
        );
        Ok(())
    });
    // A file the agent left outside the project, on the thread's machine.
    // "on another machine of the cluster" is files_media's thread on a peer.
    steps.step("the thread is on this computer", |_, _, _| Ok(()));
    steps.step(
        &format!("the agent wrote {Q} outside the project"),
        |world, c, _| {
            fake_files(&mut world.mc)
                .outside
                .insert(c[0].clone(), "dish,price\nsoup,4.50\n".into());
            Ok(())
        },
    );
    steps.step("this device was paired without terminal access", |world, _, _| {
        viewer(world).no_terminal = true;
        Ok(())
    });
    steps.step(
        "the user is told saving outside the project needs terminal access",
        |world, _, _| {
            let why = "Saving a file outside the project needs terminal access, which this device was not paired with.";
            world.wait_for_with(|w| text_prop(w, "saveProblem") == why, describe_viewer)?;
            world.sync()?;
            // Asked once: the refusal is not tried again, and the edit stays on screen to copy.
            let typed = viewer(world).typed.clone();
            let told = brick::shown(world)?.shows(world, &format!("Not saved: {why}"))?;
            expect!(
                writes(world).len() == 1
                    && !flag_prop(world, "editing")
                    && text_prop(world, "text").contains(&typed)
                    && told,
                "{} after {} write(s)",
                describe_viewer(world),
                writes(world).len()
            );
            let edited = viewer(world).edited.clone();
            viewer(world).described = edited;
            Ok(())
        },
    );
    steps.step(&format!("the user opens {Q} and edits it"), |world, c, _| {
        show_panel(world)?;
        open_file(world, &c[0])?;
        let brick = brick::shown(world)?;
        let edit = brick.item(world, "fileEdit")?;
        expect!(
            file_status(world) == "ready"
                && flag_prop(world, "editable")
                && brick.flag(world, edit, "enabled"),
            "{}",
            describe_viewer(world)
        );
        brick.click(world, "fileEdit")?;
        world.wait_for_with(
            |w| flag_prop(w, "editing") && shown_in(w, "fileEditor"),
            describe_viewer,
        )?;
        viewer(world).edited = c[0].clone();
        type_change(world)
    });
    steps.step(
        &format!("the change is written to {Q} on the thread's machine"),
        |world, c, _| {
            let path = c[0].clone();
            world.wait_for_with(
                |w| held_outside(w, &path),
                |w| {
                    format!(
                        "{path} to hold the change; it was written {} time(s); {}",
                        writes(w).len(),
                        describe_viewer(w)
                    )
                },
            )?;
            world.sync()?;
            let last = world
                .mc
                .calls
                .iter()
                .rev()
                .find(|rpc| rpc.method == "projects.writeFile")
                .map(|rpc| (rpc.environment.clone(), rpc.payload.clone()));
            // Asked of the MC the thread runs on, by the file's full path.
            let machine = super::files_workspace::environment(world);
            let root = workspace_root(world);
            let there = last.as_ref().is_some_and(|(environment, payload)| {
                (*environment == machine
                    || (environment.is_empty() && machine == world.mc.environment_id))
                    && at(payload, "cwd") == &json!(root)
                    && at(payload, "relativePath") == &json!(path)
            });
            expect!(
                there,
                "the MC was asked {}",
                last.map_or("nothing".to_owned(), |(environment, payload)| format!(
                    "{} on \"{environment}\"",
                    show(&payload)
                ))
            );
            let in_project = fake_files(&mut world.mc).files.contains_key(&path);
            expect!(
                text_prop(world, "saveProblem").is_empty() && !in_project,
                "{}",
                describe_viewer(world)
            );
            Ok(())
        },
    );

    // Copying the open file.
    steps.step(
        &format!("the user is reading {Q} in the viewer"),
        |world, c, _| {
            world.set_clipboard("");
            view(world, &c[0])?;
            expect!(file_status(world) == "ready", "{}", describe_viewer(world));
            Ok(())
        },
    );
    steps.step(
        "the user copies the file's text from the (viewer|command palette)",
        |world, c, _| {
            if c[0] == "viewer" {
                return brick::shown(world)?.click(world, "fileCopy");
            }
            let command = "files.copyContents";
            let commands = Commands::of(world.engine());
            let offered = commands.rows().into_iter().any(|row| {
                row.command == command
                    && row.listed
                    && row.enabled
                    && row.title == "Copy file contents"
            });
            expect!(offered, "the palette does not offer \"Copy file contents\"");
            commands.run(world.engine(), command);
            world.pump()
        },
    );
    steps.step(&format!("the whole of {Q} is on the clipboard"), |world, c, _| {
        let wanted = fake_files(&mut world.mc)
            .files
            .get(&c[0])
            .cloned()
            .unwrap_or_default();
        world.sync()?;
        let held = world.clipboard();
        expect!(
            !wanted.is_empty() && held == wanted,
            "the clipboard holds \"{held}\""
        );
        Ok(())
    });
    steps.step("the user is told the file's text was copied", |world, _, _| {
        expect!(
            told_copied(world, &open_path(world)),
            "{}",
            describe_toasts(world)
        );
        Ok(())
    });
    // The MC sends a file's first 1 MB, marked truncated (panel.rs's "is 3 MB").
    steps.step(
        &format!("the first megabyte of {Q} is on the clipboard"),
        |world, c, _| {
            let fake = fake_files(&mut world.mc);
            let wanted = fake.files.get(&c[0]).cloned().unwrap_or_default();
            let truncated = fake.truncated.contains_key(&c[0]);
            world.sync()?;
            let held = world.clipboard();
            expect!(
                truncated && !wanted.is_empty() && held == wanted,
                "the clipboard holds \"{held}\""
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user is told only the first 1 MB of {Q} was copied"),
        |world, c, _| {
            expect!(
                told_copied(world, &format!("Only the first 1 MB of {}.", c[0])),
                "{}",
                describe_toasts(world)
            );
            Ok(())
        },
    );

    steps.step(
        &format!("{Q} has the unticked task {Q}"),
        |world, c, _| {
            fake_files(&mut world.mc).files.insert(
                c[0].clone(),
                format!("# To do\n\n- [x] Draft the plan\n- [ ] {}\n- [ ] Tell everyone\n", c[1]),
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user ticks {Q} in the rendered view"),
        |world, c, _| {
            viewer(world).edited = "TODO.md".into();
            view(world, "TODO.md")?;
            world.wait_for_with(
                |w| flag_prop(w, "rendered") && shown_in(w, "fileRenderedMarkdown"),
                describe_viewer,
            )?;
            tick(world, &c[0])
        },
    );
    steps.step(&format!("the user unticks {Q}"), |world, c, _| {
        tick(world, &c[0])
    });
    steps.step(&format!("{Q} records {Q} as (done|open)"), |world, c, _| {
        let mark = if c[2] == "done" { "x" } else { " " };
        let wanted = format!(
            "# To do\n\n- [x] Draft the plan\n- [{mark}] {}\n- [ ] Tell everyone\n",
            c[1]
        );
        let held = fake_files(&mut world.mc)
            .files
            .get(&c[0])
            .cloned()
            .unwrap_or_default();
        expect!(held == wanted, "{} holds \"{held}\"", c[0]);
        // The rendered view follows.
        let box_mark = if c[2] == "done" { "☑" } else { "☐" };
        let link = task_link(world, &c[1])?;
        let drawn = text_prop(world, "renderedText");
        expect!(
            drawn.contains(&format!("[{box_mark}]({link}")),
            "the view draws {drawn}"
        );
        Ok(())
    });
    // A draft's attachment, opened from its chip in the composer.
    steps.step("the user is viewing an attachment of a draft", |world, _, _| {
        world.dispatch(
            "composer.attach",
            json!({"files": [{
                "name": "receipt.png",
                "mimeType": "image/png",
                "base64": "iVBORw0KGgo=",
            }]}),
        )?;
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nItem {\n  Composer { width: parent.width; anchors.bottom: parent.bottom }\n  AttachmentViewer {}\n}\n",
            900.0,
            700.0,
        )?;
        brick::shown(world)?.click(world, "attachmentOpen:receipt.png")?;
        world.wait_for_with(
            |w| {
                text(at(&w.state("attachmentViewer"), "name")) == "receipt.png"
                    && shown_in(w, "attachmentViewerImage")
            },
            |w| {
                format!(
                    "the attachment to open; the viewer is {}",
                    show(&w.state("attachmentViewer"))
                )
            },
        )?;
        let viewed = world.state("attachmentViewer");
        expect!(
            at(&viewed, "kind") == "image" && at(&viewed, "origin") == "Draft",
            "{}",
            show(&viewed)
        );
        Ok(())
    });
    steps.step(
        "the viewer closes and the attachment leaves the draft",
        |world, _, _| {
            let viewed = world.state("attachmentViewer");
            let left = at(&world.state("composer"), "attachments").clone();
            expect!(
                viewed.is_null() && left.as_array().is_none_or(Vec::is_empty),
                "the viewer is {} and the draft carries {}",
                show(&viewed),
                show(&left)
            );
            world.wait_for("the viewer to close", |w| !shown_in(w, "attachmentViewer"))
        },
    );
    steps.step(&format!("writing {Q} fails"), |world, c, _| {
        viewer(world).unwritable.insert(c[0].clone());
        Ok(())
    });
    steps.step(&format!("the user edits {Q}"), |world, c, _| {
        start_editing(world, &c[0])?;
        type_change(world)?;
        world.wait_for_with(
            |w| !writes(w).is_empty() && !text_prop(w, "saveProblem").is_empty(),
            |w| format!("the save to be answered; {}", describe_viewer(w)),
        )
    });
    steps.step("the user is told the file could not be saved", |world, _, _| {
        let path = viewer(world).edited.clone();
        let told_here = brick::shown(world)?.shows(world, &format!("Not saved: Could not write {path}."))?;
        expect!(
            text_prop(world, "saveProblem") == format!("Could not write {path}.") && told_here,
            "{}",
            describe_viewer(world)
        );
        let told = at(&world.state("toasts"), "items")
            .as_array()
            .is_some_and(|items| {
                items.iter().any(|toast| {
                    at(toast, "type") == "error"
                        && text(at(toast, "title")) == format!("Could not save {path}")
                })
            });
        expect!(told, "{}", describe_toasts(world));
        Ok(())
    });
    steps.step("the edit is still in the editor", |world, _, _| {
        let typed = viewer(world).typed.clone();
        let edited = viewer(world).edited.clone();
        let brick = brick::shown(world)?;
        let editor = brick.item(world, "fileEditor")?;
        let in_editor = brick.text_of(world, editor, "text").contains(&typed);
        let on_disk = fake_files(&mut world.mc)
            .files
            .get(&edited)
            .is_some_and(|contents| contents.contains(&typed));
        expect!(
            flag_prop(world, "editing")
                && flag_prop(world, "unsaved")
                && text_prop(world, "text").contains(&typed)
                && in_editor
                && !on_disk,
            "{}",
            describe_viewer(world)
        );
        Ok(())
    });
}

/// Whether the project's file at `path` holds what the user typed.
fn held(world: &World, path: &str) -> bool {
    let typed = world.mc.peek::<Viewer>().map(|v| v.typed.clone());
    let files = world.mc.peek::<FakeFiles>();
    matches!((typed, files), (Some(typed), Some(fake))
        if fake.files.get(path).is_some_and(|contents| contents.contains(&typed)))
}

/// Whether the file at the full `path` holds what the user typed.
fn held_outside(world: &World, path: &str) -> bool {
    let typed = world.mc.peek::<Viewer>().map(|v| v.typed.clone());
    let files = world.mc.peek::<FakeFiles>();
    matches!((typed, files), (Some(typed), Some(fake))
        if fake.outside.get(path).is_some_and(|contents| contents.contains(&typed)))
}

/// The entry named `entry` of the menu `menu_name` the panel keeps.
fn menu_entry(world: &World, brick: Brick, menu_name: &str, entry: &str) -> Option<ObjectId> {
    let menu = brick.find(world, menu_name).ok()??;
    let engine = world.engine();
    let count = match engine.read_by_name(menu, "count") {
        Value::Int(n) => n,
        _ => 0,
    };
    for index in 0..count {
        if let Ok(Value::Object(item)) = engine.invoke_by_name(menu, "itemAt", &[Value::Int(index)])
            && engine.read_by_name(item, "objectName") == Value::from(entry)
        {
            return Some(item);
        }
    }
    None
}
