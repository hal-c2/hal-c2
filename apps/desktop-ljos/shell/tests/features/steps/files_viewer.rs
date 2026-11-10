//! The file viewer beyond reading (features/files/file-viewer-and-editing.feature,
//! desktop-qt's FilesViewerSteps.cpp): rendered files and their source, the
//! path trail, opening in an editor, and editing with its saves, on the Files
//! tab as the right panel draws it. panel.rs has opening, wrapping and
//! retrying. The MC's `projects.writeFile` is faked here.

use std::collections::HashSet;

use fancy_regex::Regex;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controller;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::quit::{QUIT, QUIT_WRITE_WAIT};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::thread_view::workspace_files::WorkspaceFiles;
use ljos::prelude::{ObjectId, Value};
use serde_json::{Value as Json, json};

use super::fake_files::{FakeFiles, fake_files};
use super::files_workspace::{
    choose, describe_tree, editor_calls, editor_id, ensure_viewer_file, file_status, files,
    flag_prop, open_file, open_path, set_config, show_calls, show_panel, text_prop, wait_for_tree,
    workspace_root,
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
    /// What the folder the path trail opens next is: "empty", "gone" or
    /// "partial" ("" a plain one).
    trail_state: String,
    /// What a file went through after an older read was let go.
    rewritten: String,
    saved_early: std::cell::Cell<bool>,
    signings_before: usize,
    /// Every text the viewer has shown since the older read was let go.
    seen: std::rc::Rc<std::cell::RefCell<Vec<String>>>,
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
        if flag_prop(world, "rendered") {
            ", rendered"
        } else {
            ""
        },
        if flag_prop(world, "editing") {
            ", editing"
        } else {
            ""
        },
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
    let link = Regex::new(r"\[[☐☑]\]\((task:\d+)\) ([^\n]*)")
        .map_err(|e| crate::harness::Failure(e.to_string()))?;
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
/// Clicks the box of `task` in the rendered view; what the click writes,
/// if anything, is the caller's to wait for.
fn click_task_box(world: &mut World, task: &str) -> Outcome {
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
    world.click_at(x, y)
}

fn tick(world: &mut World, task: &str) -> Outcome {
    let before = writes(world).len();
    click_task_box(world, task)?;
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

fn answer_write(mc: &mut crate::fake_mc::FakeMc, rpc: &crate::fake_mc::Rpc) -> Outcome {
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
}

/// The Files viewer's half of "the diagram's source is shown" (the Space
/// steps own the step and hand a file over here).
pub fn diagram_source_shown(world: &mut World) -> Outcome {
    let brick = brick::shown(world)?;
    world.wait_for_with(
        move |w| {
            !flag_prop(w, "rendered")
                && shown_in(w, "fileLines")
                && super::mermaid::drawn(w, brick).is_empty()
        },
        describe_viewer,
    )?;
    let path = open_path(world);
    let newlines = fake_files(&mut world.mc)
        .files
        .get(&path)
        .map_or(0, |contents| contents.matches('\n').count());
    let rows = lines_of(world);
    expect!(rows == newlines, "the viewer shows {rows} lines");
    Ok(())
}

pub fn register(steps: &mut Steps) {
    // As apps/server-ex lib/hal_c2/workspace.ex write_file: the file's new contents.
    steps.extension(|mc| {
        mc.on_rpc("projects.writeFile", |mc, rpc| {
            if mc.holding("write") {
                let rpc = rpc.clone();
                mc.defer(move |mc| {
                    let _ = answer_write(mc, &rpc);
                });
                Ok(())
            } else {
                answer_write(mc, rpc)
            }
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
        let brick = show_panel(world)?;
        // A diagram file the MC could not draw shows its text where the diagram would be.
        if text_prop(world, "renderKind") == "mermaid" && flag_prop(world, "rendered") {
            let path = open_path(world);
            let want = fake_files(&mut world.mc)
                .files
                .get(&path)
                .map(|contents| contents.trim_end_matches('\n').to_owned())
                .unwrap_or_default();
            let code_text = |w: &World| -> Option<String> {
                let code = super::mermaid::shown(w, brick, "codeText");
                let [code] = code[..] else { return None };
                let length = match w.engine().read_by_name(code, "length") {
                    Value::Int(n) => n,
                    Value::Real(r) => r as i32,
                    _ => 0,
                };
                match w.engine().invoke_by_name(
                    code,
                    "getText",
                    &[Value::Int(0), Value::Int(length)],
                ) {
                    // Rich text reports a line break as a line separator.
                    Ok(Value::String(s)) => Some(s.as_str().replace('\u{2028}', "\n")),
                    _ => None,
                }
            };
            return world.wait_for_with(
                |w| {
                    code_text(w).is_some_and(|drawn| drawn == want)
                        && super::mermaid::drawn(w, brick).is_empty()
                },
                |w| {
                    format!(
                        "the diagram's text to be shown; it shows {:?}; {}",
                        code_text(w),
                        describe_viewer(w)
                    )
                },
            );
        }
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
    steps.step(
        &format!("{Q} holds the file {Q} with a flowchart (in it|with an unclosed bracket)"),
        |world, c, _| {
            let diagram = if c[2] == "in it" {
                super::mermaid::FLOWCHART
            } else {
                super::mermaid::BROKEN_FLOWCHART
            };
            let contents = if c[1].ends_with(".md") {
                format!("# Flow\n\nHow an order is paid:\n\n```mermaid\n{diagram}\n```\n")
            } else {
                format!("{diagram}\n")
            };
            fake_files(&mut world.mc)
                .files
                .insert(c[1].clone(), contents);
            Ok(())
        },
    );
    steps.step(
        "on the desktop and the phone the flowchart is drawn",
        |world, _, _| {
            let brick = show_panel(world)?;
            world.wait_for_with(
                move |w| flag_prop(w, "rendered") && super::mermaid::drawn(w, brick).len() == 1,
                describe_viewer,
            )?;
            let drawn = super::mermaid::drawn(world, brick)[0];
            let width = match world.engine().read_by_name(drawn, "width") {
                Value::Real(r) => r,
                Value::Int(n) => f64::from(n),
                _ => 0.0,
            };
            expect!(width > 0.0, "the diagram is drawn with no width");
            Ok(())
        },
    );
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

    steps.step(&format!("{Q} is empty"), |world, _, _| {
        viewer(world).trail_state = "empty".into();
        Ok(())
    });
    steps.step(
        &format!("{Q} was deleted after the file was opened"),
        |world, _, _| {
            viewer(world).trail_state = "gone".into();
            Ok(())
        },
    );
    steps.step(
        &format!("the project index is partial and has nothing in {Q}"),
        |world, _, _| {
            viewer(world).trail_state = "partial".into();
            Ok(())
        },
    );
    steps.step(
        &format!("the user opens the folder {Q} in the path trail"),
        |world, c, _| {
            let fake = fake_files(&mut world.mc);
            fake.files
                .insert("src/lib/util/round.ts".into(), "round\n".into());
            fake.files.insert("src/lib/tax.ts".into(), "tax\n".into());
            let failing = fake.fail_once.remove(&c[0]);
            if open_path(world).is_empty() {
                view(world, "src/lib/cart.ts")?;
            }
            let folder = trail_folder_named(world, &c[0])?;
            let state = std::mem::take(&mut viewer(world).trail_state);
            let fake = fake_files(&mut world.mc);
            if failing {
                fake.fail_once.insert(folder.clone());
            }
            match state.as_str() {
                "empty" => fake.empty_folders.insert(folder.clone()),
                "gone" => fake.gone_folders.insert(folder.clone()),
                "partial" => fake.partial_folders.insert(folder.clone()),
                _ => false,
            };
            brick::shown(world)?.click(world, &format!("filePathPart-{folder}"))?;
            world.wait_for_with(
                |w| {
                    text_prop(w, "trailFolder") == folder
                        && text_prop(w, "trailStatus") != "loading"
                },
                |w| format!("the folder to be listed: {}", text_prop(w, "trailStatus")),
            )?;
            world.pump()
        },
    );
    steps.step(
        &format!("the files and folders of {Q} are listed, folders first"),
        |world, _, _| {
            let names: Vec<String> = trail_entries(world)
                .iter()
                .map(|entry| text(&entry["name"]))
                .collect();
            expect!(
                names == ["util", "cart.ts", "tax.ts"],
                "{}",
                names.join(", ")
            );
            let brick = brick::shown(world)?;
            expect!(
                menu_entry(
                    world,
                    brick,
                    "filePathSiblings",
                    "filePathSibling-src/lib/util"
                )
                .is_some(),
                "the menu does not draw the folder"
            );
            Ok(())
        },
    );
    steps.step("the folder that is open is marked", |world, _, _| {
        let brick = brick::shown(world)?;
        let part = brick.item(world, "filePathPart-src/lib")?;
        expect!(
            brick.flag(world, part, "checked"),
            "the trail does not mark the folder"
        );
        let Some(entry) = menu_entry(
            world,
            brick,
            "filePathSiblings",
            "filePathSibling-src/lib/cart.ts",
        ) else {
            fail!("the menu does not list the open file")
        };
        expect!(
            brick.flag(world, entry, "current"),
            "the list does not mark the open file"
        );
        Ok(())
    });

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
            set_config(world, json!({"availableEditors": [editor_id(&c[0])?]}))
        },
    );
    steps.step(&format!("the user opens {Q} in {Q}"), |world, c, _| {
        let calls = editor_calls(world)?.len();
        viewer(world).editor_calls_before = calls;
        choose(
            world,
            &c[0],
            &format!("fileEntryEditor-{}", editor_id(&c[1])?),
        )
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
                flag_prop(world, "unsaved")
                    && writes(world).is_empty()
                    && !contents.contains(&typed),
                "the change is already written"
            );
            Ok(())
        },
    );
    steps.step(
        "the user opens a file larger than one megabyte",
        |world, _, _| {
            let path = "logs/big.log";
            let fake = fake_files(&mut world.mc);
            fake.files.insert(path.into(), "line\n".repeat(200));
            fake.truncated.insert(path.into(), 3 * 1024 * 1024);
            show_panel(world)?;
            open_file(world, path)?;
            viewer(world).described = path.to_owned();
            expect!(file_status(world) == "ready", "{}", describe_viewer(world));
            Ok(())
        },
    );
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
    steps.step(
        "this device was paired without terminal access",
        |world, _, _| {
            viewer(world).no_terminal = true;
            Ok(())
        },
    );
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
    steps.step(
        &format!("the user opens {Q} and edits it"),
        |world, c, _| {
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
        },
    );
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
    steps.step(
        &format!("the whole of {Q} is on the clipboard"),
        |world, c, _| {
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
        },
    );
    steps.step(
        "the user is told the file's text was copied",
        |world, _, _| {
            expect!(
                told_copied(world, &open_path(world)),
                "{}",
                describe_toasts(world)
            );
            Ok(())
        },
    );
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

    steps.step(&format!("{Q} has the unticked task {Q}"), |world, c, _| {
        fake_files(&mut world.mc).files.insert(
            c[0].clone(),
            format!(
                "# To do\n\n- [x] Draft the plan\n- [ ] {}\n- [ ] Tell everyone\n",
                c[1]
            ),
        );
        Ok(())
    });
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
        if super::space::space_tick(world, &c[0], false)? {
            return Ok(());
        }
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
    steps.step(
        "the user is told the file could not be saved",
        |world, _, _| {
            let path = viewer(world).edited.clone();
            let told_here = brick::shown(world)?
                .shows(world, &format!("Not saved: Could not write {path}."))?;
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
        },
    );
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

    // Files that are not text.
    steps.step(
        &format!("{Q} in {Q} (contains null bytes|is written in a non-UTF-8 text encoding)"),
        |world, c, _| {
            let fake = fake_files(&mut world.mc);
            fake.files.insert(c[0].clone(), String::new());
            fake.unreadable.insert(
                c[0].clone(),
                if c[2] == "contains null bytes" {
                    "binary_file"
                } else {
                    "not_utf8"
                }
                .to_owned(),
            );
            show_panel(world).map(drop)
        },
    );
    steps.step("the file is not shown as text", |world, _, _| {
        world.wait_for_with(|w| file_status(w) == "error", describe_viewer)?;
        expect!(
            !shown(world, "fileLines") && shown(world, "fileMessage"),
            "{}",
            describe_viewer(world)
        );
        Ok(())
    });

    // Tables.
    steps.step(&format!("the user opens {Q} rendered"), |world, c, _| {
        view(world, &c[0])?;
        world.wait_for_with(
            |w| flag_prop(w, "rendered") && shown_in(w, "fileRendered"),
            describe_viewer,
        )
    });
    steps.step(
        &format!("{Q} has more than 100 rows and more than 30 columns"),
        |world, c, _| {
            let mut contents = String::new();
            for row in 0..120 {
                let cells: Vec<String> = (0..35).map(|column| format!("r{row}c{column}")).collect();
                contents += &cells.join(",");
                contents.push('\n');
            }
            fake_files(&mut world.mc)
                .files
                .insert(c[0].clone(), contents);
            Ok(())
        },
    );
    steps.step(
        "the first 100 rows and 30 columns are shown",
        |world, _, _| {
            let table = text_prop(world, "renderedText");
            expect!(
                table.contains("r99c29") && !table.contains("r100c0") && !table.contains("r0c30"),
                "{}",
                table.chars().take(400).collect::<String>()
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told the table is limited and that the source shows the rest",
        |world, _, _| {
            let table = text_prop(world, "renderedText");
            expect!(
                table.ends_with(
                    "Table limited to the first 100 rows and 30 columns; the source shows the rest.\n"
                ),
                "{}",
                table.chars().rev().take(200).collect::<String>().chars().rev().collect::<String>()
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} has a cell reading {Q} and a cell holding two lines"),
        |world, c, _| {
            fake_files(&mut world.mc).files.insert(
                c[0].clone(),
                format!(
                    "\u{feff}name,note\n\"{}\",\"first\nsecond\"\n\"say \"\"hi\"\"\",x\n",
                    c[1]
                ),
            );
            Ok(())
        },
    );
    steps.step("each of those is shown as a single cell", |world, _, _| {
        let table = text_prop(world, "renderedText");
        expect!(
            table.contains("| Smith, Jane | first second |\n")
                && table.contains("| say \"hi\" | x |\n"),
            "{table}"
        );
        Ok(())
    });
    steps.step(
        "a leading byte order mark is not shown as text",
        |world, _, _| {
            let table = text_prop(world, "renderedText");
            expect!(table.starts_with("| name | note |\n"), "{table}");
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} ends with a row whose only cell is an empty quoted value and no line ending"),
        |world, c, _| {
            fake_files(&mut world.mc)
                .files
                .insert(c[0].clone(), "name\nAlice\n\"\"".to_owned());
            Ok(())
        },
    );
    steps.step(
        "that empty row is shown after the last data row",
        |world, _, _| {
            let table = text_prop(world, "renderedText");
            expect!(table == "| name |\n| --- |\n| Alice |\n|  |\n", "{table}");
            Ok(())
        },
    );

    // Following the agent.
    steps.step(
        &format!("the user is reading {Q} with no edits of their own"),
        |world, c, _| view(world, &c[0]),
    );
    steps.step(&format!("the agent changes {Q}"), |world, c, _| {
        fake_files(&mut world.mc)
            .files
            .insert(c[0].clone(), "export const changed = true;\n".to_owned());
        agent_changed(world, &c[0])
    });
    steps.step("the viewer shows the new contents", |world, _, _| {
        world.wait_for_with(
            |w| text_prop(w, "text") == "export const changed = true;\n",
            describe_viewer,
        )?;
        expect!(file_status(world) == "ready", "{}", describe_viewer(world));
        Ok(())
    });
    steps.step(
        "an image the agent rewrites is shown as it is now, not from a cached copy",
        |world, _, _| {
            let image = "assets/logo.png";
            fake_files(&mut world.mc)
                .files
                .insert(image.to_owned(), "png".to_owned());
            open_file(world, image)?;
            world.wait_for_with(|w| !text_prop(w, "mediaUrl").is_empty(), describe_viewer)?;
            let before = text_prop(world, "mediaUrl");
            agent_changed(world, image)?;
            world.wait_for_with(
                |w| {
                    let url = text_prop(w, "mediaUrl");
                    !url.is_empty() && url != before
                },
                describe_viewer,
            )
        },
    );
    steps.step(&format!("the user is previewing {Q}"), |world, c, _| {
        fake_files(&mut world.mc)
            .files
            .insert(c[0].clone(), "png".to_owned());
        show_panel(world)?;
        open_file(world, &c[0])?;
        world.wait_for_with(|w| !text_prop(w, "mediaUrl").is_empty(), describe_viewer)?;
        viewer(world).signings_before = signings(world);
        Ok(())
    });
    steps.step("the agent changes another file", |world, _, _| {
        agent_changed(world, "src/other.ts")?;
        world.sync()
    });
    steps.step(&format!("{Q} is not fetched again"), |world, c, _| {
        world.sync()?;
        let before = viewer(world).signings_before;
        expect!(
            open_path(world) == c[0] && signings(world) == before && file_status(world) == "ready",
            "{} signings since; {}",
            signings(world) - before,
            describe_viewer(world)
        );
        Ok(())
    });
    steps.step(&format!("the user opened {Q}"), |world, c, _| {
        view(world, &c[0])
    });
    steps.step(
        &format!("the user opened {Q} and it is a folder"),
        |world, c, _| {
            fake_files(&mut world.mc)
                .files
                .insert(format!("{}/out.txt", c[0]), "out\n".to_owned());
            show_panel(world)?;
            open_file(world, &c[0])?;
            world.wait_for_with(|w| file_status(w) == "error", describe_viewer)
        },
    );
    steps.step(
        &format!("the agent replaces the folder {Q} with a file"),
        |world, c, _| {
            let fake = fake_files(&mut world.mc);
            fake.files.remove(&format!("{}/out.txt", c[0]));
            fake.files.insert(c[0].clone(), "built\n".to_owned());
            agent_changed(world, &c[0])
        },
    );
    steps.step("the viewer shows the file's contents", |world, _, _| {
        world.wait_for_with(
            |w| file_status(w) == "ready" && text_prop(w, "text") == "built\n",
            describe_viewer,
        )
    });

    // Opening at a line.
    steps.step(
        "the user prefers the rendered Markdown view",
        |world, _, _| {
            let mut lines = String::new();
            for line in 1..=300 {
                lines += &format!("line {line}\n");
            }
            fake_files(&mut world.mc)
                .files
                .insert("docs/guide.md".to_owned(), lines);
            show_panel(world).map(drop)
        },
    );
    steps.step(
        "the Markdown source is shown with line (\\d+) in view",
        |world, c, _| {
            world.wait_for_with(
                |w| !flag_prop(w, "rendered") && shown_in(w, "fileLines"),
                describe_viewer,
            )?;
            let wanted = c[0].parse::<i64>().unwrap_or(0);
            let revealed = super::files_workspace::int_prop(world, "revealLine");
            expect!(revealed == wanted, "line {revealed} is revealed");
            world.sync()?;
            let brick = brick::shown(world)?;
            let lines = brick.item(world, "fileLines")?;
            let line = world.engine().invoke_by_name(
                lines,
                "itemAtIndex",
                &[Value::Int((wanted - 1) as i32)],
            );
            expect!(
                matches!(line, Ok(Value::Object(_))),
                "the line is not drawn"
            );
            // Not a preference: the next open file is rendered as before.
            let kept = Settings::of(world.engine()).device_value("fileSourceKinds");
            let kept: Vec<String> = kept
                .and_then(|v| v.as_array().cloned())
                .unwrap_or_default()
                .iter()
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect();
            expect!(
                !kept.contains(&"markdown".to_owned()),
                "the device now prefers the source"
            );
            Ok(())
        },
    );

    // Selecting lines.
    steps.step(
        &format!(
            "the user (selected lines|is writing a comment on lines) (\\d+) to (\\d+) of {Q}(?: and left the comment form closed)?"
        ),
        |world, c, _| {
            use ljos::item::{Modifiers, MouseButtons};
            let mut lines = String::new();
            for line in 1..=40 {
                lines += &format!("line {line}\n");
            }
            fake_files(&mut world.mc)
                .files
                .insert(c[3].clone(), lines);
            view(world, &c[3])?;
            let brick = brick::shown(world)?;
            let list = brick.item(world, "fileLines")?;
            let gutter = |world: &World, line: i64| -> Outcome<(f64, f64)> {
                let row = world
                    .engine()
                    .invoke_by_name(list, "itemAtIndex", &[Value::Int((line - 1) as i32)]);
                let Ok(Value::Object(row)) = row else {
                    fail!("line {line} is not drawn")
                };
                brick.at_px(world, row, 4.0, 4.0)
            };
            world.sync()?;
            let first = c[1].parse::<i64>().unwrap_or(0);
            let last = c[2].parse::<i64>().unwrap_or(0);
            let (x, y) = gutter(world, first)?;
            world.click_at(x, y)?;
            let (x, y) = gutter(world, last)?;
            world.click_at_with(x, y, MouseButtons::LEFT, Modifiers::SHIFT)?;
            world.sync()?;
            let selected_first = int_of(world, brick, list, "selectionFirst");
            let selected_last = int_of(world, brick, list, "selectionLast");
            expect!(
                selected_first == first && selected_last == last,
                "lines {selected_first} to {selected_last} are selected"
            );
            if c[0] == "is writing a comment on lines" {
                brick.click(world, "fileLineComment")?;
                world.sync()?;
                for character in "why".chars() {
                    brick.press(world, &character.to_string())?;
                }
                let comment = brick.item(world, "fileCommentText")?;
                expect!(
                    brick.text_of(world, comment, "text") == "why",
                    "the comment did not take the keys"
                );
            }
            Ok(())
        },
    );
    steps.step("the user clicks outside the file", |world, _, _| {
        let (x, y, _, _) = place_of(world, "filesExplorer")?;
        let (width, height) = place_of(world, "filesExplorer").map(|p| (p.2, p.3))?;
        world.click_at(x + width / 2.0, y + height / 2.0)?;
        world.sync()
    });
    steps.step(
        "the user presses Escape while the file's text is focused",
        |world, _, _| {
            let brick = brick::shown(world)?;
            let list = brick.item(world, "fileLines")?;
            expect!(
                brick.flag(world, list, "activeFocus"),
                "the file's text does not have the keyboard"
            );
            brick.press(world, "escape")?;
            world.sync()
        },
    );
    steps.step("the lines are no longer selected", |world, _, _| {
        let brick = brick::shown(world)?;
        let list = brick.item(world, "fileLines")?;
        expect!(
            int_of(world, brick, list, "selectionStart") == 0,
            "the lines are still selected"
        );
        Ok(())
    });
    steps.step(
        "the comment form and its text are still there",
        |world, _, _| {
            let brick = brick::shown(world)?;
            let comment = brick.item(world, "fileCommentText")?;
            let list = brick.item(world, "fileLines")?;
            expect!(
                shown(world, "fileCommentForm")
                    && brick.text_of(world, comment, "text") == "why"
                    && int_of(world, brick, list, "selectionStart") > 0,
                "the comment is gone"
            );
            Ok(())
        },
    );

    // The tree beside a file, and the layout.
    steps.step(
        "the user chose to (show|hide) the file tree",
        |world, c, _| {
            let brick = show_panel(world)?;
            let Some(root) = brick.root(world) else {
                fail!("the panel has no root")
            };
            brick.write(world, root, "explorerOpen", Value::Bool(c[0] == "show"))
        },
    );
    steps.step(
        "the user opens a file outside the project on the host",
        |world, _, _| {
            let path = "/home/sam/notes.txt";
            fake_files(&mut world.mc)
                .outside
                .insert(path.to_owned(), "notes\n".to_owned());
            open_file(world, path)?;
            world.wait_for_with(|w| file_status(w) == "ready", describe_viewer)
        },
    );
    steps.step("the user opens an attachment", |world, _, _| {
        world.dispatch(
            "composer.attach",
            json!({"files": [{"name": "notes.md", "mimeType": "text/markdown", "base64": "IyBOb3Rlcwo="}]}),
        )?;
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nItem {\n  Composer { width: parent.width; anchors.bottom: parent.bottom }\n  AttachmentViewer {}\n}\n",
            900.0,
            700.0,
        )?;
        world.sync()?;
        brick::shown(world)?.click(world, "attachmentOpen:notes.md")?;
        world.wait_for_with(
            |w| text(at(&w.state("attachmentViewer"), "name")) == "notes.md",
            |_| "the attachment to open".to_owned(),
        )
    });
    steps.step("the file tree is (shown|hidden)", |world, c, _| {
        world.sync()?;
        expect!(
            shown(world, "filesExplorer") == (c[0] == "shown"),
            "the tree is otherwise; {}",
            describe_viewer(world)
        );
        Ok(())
    });
    steps.step(
        "the file viewer takes the height of the Files tab",
        |world, _, _| {
            show_panel(world)?;
            world.sync()?;
            let brick = brick::shown(world)?;
            let (_, _, _, height) = place_of(world, "fileViewer")?;
            let (_, root_height) = brick.size(world);
            expect!(
                (height - root_height).abs() < 0.5,
                "the viewer is shorter than the tab"
            );
            Ok(())
        },
    );
    steps.step(
        "the file tree is a column beside (?:it|the file)",
        |world, _, _| {
            show_panel(world)?;
            world.sync()?;
            let file = place_of(world, "fileViewer")?;
            let tree = place_of(world, "filesExplorer")?;
            expect!(
                shown(world, "filesExplorer")
                    && tree.0 >= file.0 + file.2
                    && tree.2 > 0.0
                    && (tree.3 - file.3).abs() < 0.5,
                "the tree is not beside the file"
            );
            Ok(())
        },
    );
    steps.step("the user (hides|shows) the file explorer", |world, _, _| {
        show_panel(world)?;
        brick::shown(world)?.click(world, "fileExplorerToggle")?;
        world.sync()
    });
    steps.step(
        "the file viewer takes the whole Files tab",
        |world, _, _| {
            let brick = show_panel(world)?;
            let (_, _, width, _) = place_of(world, "fileViewer")?;
            let (root_width, _) = brick.size(world);
            expect!(
                !shown(world, "filesExplorer") && (width - root_width).abs() < 0.5,
                "the viewer is narrower than the tab"
            );
            Ok(())
        },
    );
    steps.step("the file tree takes the whole Files tab", |world, _, _| {
        let brick = show_panel(world)?;
        world.sync()?;
        let (_, _, width, _) = place_of(world, "filesExplorer")?;
        let (root_width, _) = brick.size(world);
        expect!(
            !shown(world, "fileViewer") && (width - root_width).abs() < 0.5,
            "the tree is narrower than the tab"
        );
        Ok(())
    });
    steps.step(
        "the file tree stays hidden while the file is open",
        |world, _, _| {
            show_panel(world)?;
            world.sync()?;
            expect!(!shown(world, "filesExplorer"), "the tree came back");
            Ok(())
        },
    );
    steps.step("the Files tab is as narrow as a phone", |world, _, _| {
        let brick = show_panel(world)?;
        world.resize(300.0, 700.0)?;
        let Some(root) = brick.root(world) else {
            fail!("the panel has no root")
        };
        brick.write(world, root, "width", Value::from(300.0))?;
        world.sync()
    });
    steps.step(
        "every button above the file is inside the file's column",
        |world, _, _| {
            show_panel(world)?;
            world.sync()?;
            let file = place_of(world, "fileViewer")?;
            for button in ["fileRender", "fileEdit", "fileCopy", "fileClose"] {
                let place = place_of(world, button)?;
                expect!(
                    place.0 + place.2 <= file.0 + file.2 + 0.5,
                    "{button} ends at {}, the file at {}",
                    place.0 + place.2,
                    file.0 + file.2
                );
            }
            Ok(())
        },
    );
    steps.step(
        "the file tree gives way before the buttons do",
        |world, _, _| {
            expect!(!shown(world, "filesExplorer"), "the tree still takes room");
            Ok(())
        },
    );
    steps.step(
        "a tab too narrow to leave the tree room for ten characters of a name at the user's font size shows the file alone",
        |world, _, _| {
            let brick = brick::shown(world)?;
            let Some(root) = brick.root(world) else {
                fail!("the panel has no root")
            };
            let share = num(world, brick, root, "explorerShare");
            let minimum = num(world, brick, root, "explorerMinimum");
            expect!(
                share < minimum
                    && !shown(world, "filesExplorer")
                    && shown(world, "fileViewer"),
                "the tree has {share} of {minimum}"
            );
            Ok(())
        },
    );

    // The path trail, retried.
    steps.step(&format!("the files of {Q} are listed"), |world, _, _| {
        expect!(
            text_prop(world, "trailStatus") == "ready" && !trail_entries(world).is_empty(),
            "{}",
            text_prop(world, "trailStatus")
        );
        let brick = brick::shown(world)?;
        world.wait_for_with(
            |w| {
                menu_entry(
                    w,
                    brick,
                    "filePathSiblings",
                    "filePathSibling-src/lib/cart.ts",
                )
                .is_some()
            },
            |_| "the menu to list the folder".to_owned(),
        )
    });

    // Saving.
    steps.step(
        &format!("writing {Q} failed after an edit"),
        |world, c, _| {
            viewer(world).unwritable.insert(c[0].clone());
            set_save_delay(world, 0)?;
            start_editing(world, &c[0])?;
            type_change(world)?;
            world.wait_for_with(|w| !text_prop(w, "saveProblem").is_empty(), describe_viewer)
        },
    );
    steps.step(&format!("writing {Q} works again"), |world, c, _| {
        viewer(world).unwritable.remove(&c[0]);
        Ok(())
    });
    steps.step(&format!("the edit is written to {Q}"), |world, c, _| {
        let typed = viewer(world).typed.clone();
        world.wait_for_with(
            |w| {
                super::fake_files::contents_of(&w.mc, &c[0])
                    .is_some_and(|contents| contents.contains(&typed))
            },
            |_| "the edit to be written".to_owned(),
        )
    });
    steps.step(&format!("a save of {Q} is being written"), |world, c, _| {
        world.mc.hold("write");
        set_save_delay(world, 0)?;
        viewer(world).edited.clone_from(&c[0]);
        start_editing(world, &c[0])?;
        type_change(world)?;
        world.wait_for_with(
            |w| {
                w.mc.calls
                    .iter()
                    .any(|rpc| rpc.method == "projects.writeFile")
            },
            |_| "the save to start".to_owned(),
        )
    });
    steps.step("the user makes another edit", |world, _, _| {
        brick::shown(world)?.press(world, "z")?;
        world.sync()?;
        expect!(
            text_prop(world, "text").contains('z'),
            "{}",
            describe_viewer(world)
        );
        Ok(())
    });
    steps.step("the file ends up with both edits", |world, _, _| {
        let path = viewer(world).edited.clone();
        let typed = viewer(world).typed.clone();
        let both = |w: &World| {
            super::fake_files::contents_of(&w.mc, &path)
                .is_some_and(|written| written.contains(typed.trim()) && written.contains('z'))
        };
        world.mc.answer_held();
        world.wait_for_with(
            |w| {
                // Noted for "not shown as saved": the wait goes on.
                if !both(w) && !flag_prop(w, "unsaved") {
                    if let Some(viewer) = w.mc.peek::<Viewer>() {
                        viewer.saved_early.set(true);
                    }
                }
                both(w)
            },
            |w| super::fake_files::contents_of(&w.mc, &path).unwrap_or_default(),
        )
    });
    steps.step(
        "the file is not shown as saved until the last edit is written",
        |world, _, _| {
            expect!(
                !viewer(world).saved_early.get(),
                "the file was shown as saved early"
            );
            world.wait_for_with(|w| !flag_prop(w, "unsaved"), describe_viewer)
        },
    );
    // Edits waiting when the window closes or the app quits
    // (NativeShell::closeWindow, NativeShell::finishWrites).
    fn quit_app(world: &mut World) -> Outcome {
        let engine = world.engine().clone();
        expect!(
            Commands::of(&engine).run(&engine, QUIT),
            "there is no Quit command"
        );
        world.pump()
    }
    steps.step(
        "the user closes this window, leaving another",
        |world, _, _| {
            controller::set_window_opener(world.engine(), |_, _| {});
            world.dispatch("window.new", json!({}))?;
            world.pump()?;
            let open = controller::windows(world.engine()).len();
            expect!(open == 2, "{} windows are open, not two", open);
            controller::close_window(world.engine(), controller::MAIN);
            world.pump()?;
            let open = controller::windows(world.engine()).len();
            expect!(open == 1, "the window did not close");
            expect!(
                controller::closing_windows(world.engine()) == [controller::MAIN],
                "the window went before its writes were answered"
            );
            // What it saves while it waits goes with it.
            let saved = world.home_dir().join("state/shell-panel.json");
            if let Err(e) = std::fs::write(&saved, "{}") {
                fail!("{}: {}", saved.display(), e);
            }
            Ok(())
        },
    );
    steps.step(
        "the closed window is gone, with what it kept on this device",
        |world, _, _| {
            world.wait_for("the closed window to go", |w| {
                controller::closing_windows(w.engine()).is_empty()
            })?;
            expect!(
                !world.home_dir().join("state/shell-panel.json").exists(),
                "the closed window's panels stayed"
            );
            Ok(())
        },
    );
    steps.step("the user quits the app", |world, _, _| {
        quit_app(world)?;
        // The MC answers while quitting waits for it.
        world.mc.answer_held();
        world.wait_for("the app to quit", |w| w.engine().quit_requested())
    });
    steps.step(
        "the user quits the app and the MC does not answer",
        |world, _, _| {
            quit_app(world)?;
            expect!(
                !world.engine().quit_requested(),
                "the app quit before its writes were answered"
            );
            world.advance(QUIT_WRITE_WAIT.as_millis() as u64)?;
            world.pump()
        },
    );
    steps.step(
        "the app stops waiting with the write unanswered",
        |world, _, _| {
            expect!(world.engine().quit_requested(), "the app is still waiting");
            let files = files(world)?;
            expect!(
                WorkspaceFiles::writing(world.engine(), files),
                "the write was answered"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user saved an edit to {Q} while an older read of it was still under way"),
        |world, c, _| {
            view(world, &c[0])?;
            set_save_delay(world, 0)?;
            world.mc.hold("read");
            viewer(world).rewritten = "what the older read saw\n".to_owned();
            let written = viewer(world).rewritten.clone();
            fake_files(&mut world.mc)
                .files
                .insert(c[0].clone(), written);
            agent_changed(world, &c[0])?;
            world.sync()?;
            viewer(world).edited.clone_from(&c[0]);
            brick::shown(world)?.click(world, "fileEdit")?;
            world.wait_for_with(
                |w| flag_prop(w, "editing") && shown_in(w, "fileEditor"),
                describe_viewer,
            )?;
            type_change(world)?;
            brick::shown(world)?.click(world, "fileEdit")?;
            let typed = viewer(world).typed.clone();
            world.wait_for_with(
                |w| {
                    super::fake_files::contents_of(&w.mc, &c[0])
                        .is_some_and(|contents| contents.contains(&typed))
                        && !flag_prop(w, "unsaved")
                },
                describe_viewer,
            )
        },
    );
    steps.step("the older read finishes", |world, _, _| {
        let seen = viewer(world).seen.clone();
        seen.borrow_mut().clear();
        let effects = seen.clone();
        let file = files(world)?;
        let _ = world
            .engine()
            .connect_by_name(file, "textChanged", move |engine, _| {
                let text = engine.read_by_name(file, "text");
                effects
                    .borrow_mut()
                    .push(engine.to_js_string(&text).to_string());
            });
        // The environment has moved on again: the new read has something of
        // its own to show.
        let edited = viewer(world).edited.clone();
        if let Some(contents) = fake_files(&mut world.mc).files.get_mut(&edited) {
            contents.push_str("as the environment has it\n");
        }
        world.mc.answer_held();
        Ok(())
    });
    steps.step("the viewer keeps showing the saved edit", |world, _, _| {
        world.sync()?;
        let (rewritten, typed) = {
            let v = viewer(world);
            (v.rewritten.clone(), v.typed.clone())
        };
        let seen_rewritten = viewer(world).seen.borrow().contains(&rewritten);
        expect!(
            !seen_rewritten && text_prop(world, "text").contains(&typed),
            "{}",
            describe_viewer(world)
        );
        Ok(())
    });
    steps.step(
        "it shows the file as the environment has it once the new read arrives",
        |world, _, _| {
            let edited = viewer(world).edited.clone();
            world.wait_for_with(
                |w| {
                    super::fake_files::contents_of(&w.mc, &edited)
                        .is_some_and(|contents| text_prop(w, "text") == contents)
                },
                |w| text_prop(w, "text"),
            )?;
            let rewritten = viewer(world).rewritten.clone();
            let seen_rewritten = viewer(world).seen.borrow().contains(&rewritten);
            expect!(!seen_rewritten, "the older read was shown");
            Ok(())
        },
    );

    // Task ticks against reads still on their way.
    steps.step("the user is looking at the rendered view", |world, _, _| {
        viewer(world).edited = "TODO.md".to_owned();
        view(world, "TODO.md")?;
        world.wait_for_with(
            |w| flag_prop(w, "rendered") && shown_in(w, "fileRenderedMarkdown"),
            describe_viewer,
        )?;
        world.sync()
    });
    steps.step(
        &format!("the agent has since rewritten {Q} so the task moved"),
        |world, c, _| {
            viewer(world).rewritten =
                "# To do\n\n- [ ] Something first\n- [x] Draft the plan\n- [ ] Ship cart\n"
                    .to_owned();
            let written = viewer(world).rewritten.clone();
            fake_files(&mut world.mc)
                .files
                .insert(c[0].clone(), written);
            Ok(())
        },
    );
    steps.step(&format!("the user ticks {Q}"), |world, c, _| {
        // A Space page's checklist item, when the scenario is on one.
        if super::space::space_tick(world, &c[0], true)? {
            return Ok(());
        }
        click_task_box(world, &c[0])?;
        let written = viewer(world).rewritten.clone();
        if written.is_empty() {
            return world.sync();
        }
        world.wait_for_with(|w| text_prop(w, "text") == written, describe_viewer)
    });
    steps.step(
        &format!("the user ticks {Q} and {Q} before either read is answered"),
        |world, c, _| {
            for task in [&c[0], &c[1]] {
                toggle_task(world, task)?;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the user ticks {Q} and adds a task above it before the read is answered"),
        |world, c, _| {
            toggle_task(world, &c[0])?;
            let next = text_prop(world, "text").replace(
                "- [x] Draft the plan\n",
                "- [ ] Something first\n- [x] Draft the plan\n",
            );
            viewer(world).rewritten.clone_from(&next);
            let file = files(world)?;
            world
                .engine()
                .invoke_by_name(file, "edit", &[Value::from(next.as_str())])
                .map(drop)
                .map_err(|error| crate::harness::Failure(error.to_string()))
        },
    );
    steps.step(
        &format!("{Q} holds the user's edit and no task was ticked"),
        |world, c, _| {
            let written = viewer(world).rewritten.clone();
            world.wait_for_with(
                |w| {
                    super::fake_files::contents_of(&w.mc, &c[0]).as_deref() == Some(&written)
                        && !flag_prop(w, "unsaved")
                },
                describe_viewer,
            )?;
            // The read after the save answers, and whatever it would write comes.
            for _ in 0..3 {
                world.sync()?;
            }
            expect!(
                super::fake_files::contents_of(&world.mc, &c[0]).as_deref() == Some(&written)
                    && text_prop(world, "text") == written,
                "{} holds {:?}",
                c[0],
                super::fake_files::contents_of(&world.mc, &c[0])
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} records both tasks as done"), |world, c, _| {
        let wanted = "# To do\n\n- [x] Draft the plan\n- [x] Ship cart\n- [x] Tell everyone\n";
        world.wait_for_with(
            |w| super::fake_files::contents_of(&w.mc, &c[0]).as_deref() == Some(wanted),
            |w| {
                format!(
                    "{} holds {:?}",
                    c[0],
                    super::fake_files::contents_of(&w.mc, &c[0])
                )
            },
        )
    });
    steps.step(&format!("{Q} is not changed"), |world, c, _| {
        world.sync()?;
        expect!(
            writes(world).is_empty()
                && super::fake_files::contents_of(&world.mc, &c[0]).as_deref()
                    == Some(&viewer(world).rewritten.clone()),
            "{} was written",
            c[0]
        );
        Ok(())
    });

    // Opening in the preview browser.
    steps.step(
        "the environment cannot serve a file to the preview browser",
        |world, _, _| {
            fake_files(&mut world.mc).unsignable =
                "Signed asset URLs are not available on this environment.".to_owned();
            Ok(())
        },
    );
    steps.step(
        &format!("the environment can serve {Q} to the preview"),
        |world, c, _| {
            fake_files(&mut world.mc)
                .files
                .insert(c[0].clone(), "<html></html>\n".to_owned());
            Ok(())
        },
    );
    steps.step(
        &format!("the environment cannot serve {Q} to the preview"),
        |world, c, _| {
            let fake = fake_files(&mut world.mc);
            fake.files
                .insert(c[0].clone(), "<html></html>\n".to_owned());
            fake.unsignable = "The file is too large to serve.".to_owned();
            Ok(())
        },
    );
    steps.step(
        &format!("the user's preferred editor is {Q} and it is no longer installed"),
        |world, c, _| {
            let id = editor_id(&c[0])?;
            let engine = world.engine();
            Settings::of(engine).write_device(engine, "lastEditor", json!(id));
            Ok(())
        },
    );
    steps.step(
        r"the environment's host is (macOS|Windows|Linux where reveal runs through Windows \(WSL\)|Linux)",
        |world, c, _| {
            let os = match c[0].as_str() {
                "macOS" => "darwin",
                "Windows" => "win32",
                _ => "linux",
            };
            world.mc.platform.clear();
            world.mc.platform.insert("machineId".into(), json!(THIS_MACHINE));
            world.mc.platform.insert("os".into(), json!(os));
            if c[0].contains("WSL") {
                world.mc.platform.insert("wsl".into(), json!(true));
            }
            world.mc.announce_environment();
            set_config(world, json!({"availableEditors": ["vscode", "file-manager"]}))
        },
    );
    steps.step(
        &format!("the user opens {Q} in the preview browser"),
        |world, c, _| {
            show_panel(world)?;
            // A document's preview is itself an address: asked for once it may be served.
            let refusal = std::mem::take(&mut fake_files(&mut world.mc).unsignable);
            open_file(world, &c[0])?;
            fake_files(&mut world.mc).unsignable = refusal;
            let path = c[0].clone();
            world.wait_for_with(
                move |w| open_path(w) == path && file_status(w) != "loading",
                describe_viewer,
            )?;
            brick::shown(world)?.click(world, "fileOpenPreview")?;
            world.sync()
        },
    );
    steps.step(
        &format!("{Q} is shown in the preview browser"),
        |world, c, _| {
            let name = c[0].rsplit('/').next().unwrap_or_default().to_owned();
            world.wait_for("a browser tab on the file", move |w| {
                w.mc.calls.iter().any(|rpc| {
                    rpc.method == "preview.open" && text(at(&rpc.payload, "url")).ends_with(&name)
                })
            })
        },
    );
    steps.step(
        "the user is told the file could not be opened in the browser with the reason",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    at(&w.state("toasts"), "items")
                        .as_array()
                        .is_some_and(|items| {
                            items.iter().any(|toast| {
                                at(toast, "title") == "Could not open the file in the browser"
                                    && at(toast, "description") == "The file is too large to serve."
                            })
                        })
                },
                describe_toasts,
            )
        },
    );
    steps.step(
        &format!("the user opens {Q} in the preferred editor"),
        |world, c, _| {
            view(world, &c[0])?;
            let before = editor_calls(world)?.len();
            viewer(world).editor_calls_before = before;
            brick::shown(world)?.click(world, "fileOpenInEditor")?;
            world.wait_for("the editor to be asked", move |w| {
                w.mc.calls
                    .iter()
                    .filter(|rpc| rpc.method == "shell.openInEditor")
                    .count()
                    > before
            })
        },
    );
    steps.step(
        &format!("{Q} is the preferred editor from then on"),
        |world, c, _| {
            world.sync()?;
            let workspace = world.state("workspace");
            expect!(
                at(&workspace, "preferredEditorId") == editor_id(&c[0])?,
                "{}",
                show(&workspace)
            );
            Ok(())
        },
    );
    steps.step(&format!("the user opens the menu of {Q}"), |world, _, _| {
        show_panel(world)?;
        world.sync()
    });
    steps.step(&format!("the reveal action reads {Q}"), |world, c, _| {
        let brick = show_panel(world)?;
        let label = |w: &World| {
            super::files_workspace::menu_entry(w, brick, "fileEntryMenu", "fileEntryReveal")
                .ok()
                .flatten()
                .map(|item| brick.text_of(w, item, "text"))
                .unwrap_or_default()
        };
        let wanted = c[0].clone();
        world.wait_for_with(move |w| label(w) == wanted, move |w| label(w))
    });
    steps.step(
        "the user opens the file in the preview browser",
        |world, _, _| {
            brick::shown(world)?.click(world, "fileOpenPreview")?;
            world.sync()
        },
    );
    steps.step(
        &format!("the preview browser opens with {Q} in it"),
        |world, c, _| {
            world.wait_for_with(
                |w| {
                    w.mc.calls.iter().any(|rpc| {
                        rpc.method == "preview.open"
                            && text(at(&rpc.payload, "url")).contains(&format!("/api/assets/file-"))
                    })
                },
                |w| {
                    format!(
                        "the browser to be asked for {}; calls: {}",
                        c[0],
                        w.mc.calls
                            .iter()
                            .map(|rpc| rpc.method.clone())
                            .collect::<Vec<_>>()
                            .join(", ")
                    )
                },
            )?;
            let token = fake_files(&mut world.mc)
                .signed_paths()
                .into_iter()
                .find(|(_, path)| *path == c[0])
                .map(|(token, _)| token);
            let Some(token) = token else {
                fail!("{} was not signed", c[0])
            };
            expect!(
                world.mc.calls.iter().any(|rpc| {
                    rpc.method == "preview.open"
                        && text(at(&rpc.payload, "url")).contains(&format!("/api/assets/{token}"))
                }),
                "the browser was asked for another address"
            );
            Ok(())
        },
    );
    steps.step(
        "the preview browser is not asked for anything",
        |world, _, _| {
            world.sync()?;
            expect!(
                world
                    .mc
                    .calls
                    .iter()
                    .all(|rpc| rpc.method != "preview.open"),
                "the browser was asked"
            );
            Ok(())
        },
    );
}

fn num(world: &World, brick: Brick, item: ObjectId, name: &str) -> f64 {
    match brick.read(world, item, name) {
        Value::Int(n) => n as f64,
        Value::Real(r) => r,
        _ => brick.text_of(world, item, name).parse().unwrap_or(0.0),
    }
}

fn int_of(world: &World, brick: Brick, item: ObjectId, name: &str) -> i64 {
    num(world, brick, item, name) as i64
}

/// (x, y, width, height) of the panel's part named `object_name`, in
/// window coordinates.
fn place_of(world: &mut World, object_name: &str) -> Outcome<(f64, f64, f64, f64)> {
    let brick = show_panel(world)?;
    world.sync()?;
    let Some(item) = brick.find(world, object_name)? else {
        fail!("{object_name} is not drawn")
    };
    let (x, y) = brick.at_px(world, item, 0.0, 0.0)?;
    Ok((
        x,
        y,
        num(world, brick, item, "width"),
        num(world, brick, item, "height"),
    ))
}

fn signings(world: &World) -> usize {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == "assets.createUrl")
        .count()
}

fn agent_changed(world: &mut World, path: &str) -> Outcome {
    super::stream::start_run(world, 30, "running")?;
    super::stream::add_item(world, "file_change", json!({"changes": [{"path": path}]})).map(drop)
}

fn set_save_delay(world: &mut World, ms: i32) -> Outcome {
    WorkspaceFiles::set_save_delay(world.engine(), files(world)?, ms);
    Ok(())
}

/// Toggles `task` by the link the rendered view drew for it, without a
/// click: the read it waits on is the scenario's to answer.
fn toggle_task(world: &mut World, task: &str) -> Outcome {
    let link = task_link(world, task)?;
    let index: i32 = link
        .rsplit(':')
        .next()
        .and_then(|n| n.parse().ok())
        .unwrap_or(0);
    let file = files(world)?;
    world
        .engine()
        .invoke_by_name(file, "toggleTask", &[Value::Int(index)])
        .map(drop)
        .map_err(|error| crate::harness::Failure(error.to_string()))
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

/// The folder on the open file's path whose last part is `name`.
fn trail_folder_named(world: &World, name: &str) -> Outcome<String> {
    let path = open_path(world);
    let mut folder = String::new();
    for part in path.split('/') {
        if !folder.is_empty() {
            folder.push('/');
        }
        folder.push_str(part);
        if part == name {
            return Ok(folder);
        }
    }
    fail!("\"{name}\" is not on the path \"{path}\"")
}

/// What the path trail lists of its open folder.
fn trail_entries(world: &World) -> Vec<Json> {
    let Ok(object) = files(world) else {
        return Vec::new();
    };
    let engine = world.engine();
    match hal_c2_shell::json::from_value(engine, &engine.read_by_name(object, "trailEntries")) {
        Json::Array(entries) => entries,
        _ => Vec::new(),
    }
}

/// The entry named `entry` of the menu `menu_name` the panel keeps.
pub fn menu_entry(world: &World, brick: Brick, menu_name: &str, entry: &str) -> Option<ObjectId> {
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
