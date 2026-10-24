//! Managing folders on disk (features/files/folder-operations.feature) and
//! dragging a folder over the window (files/adding-projects.feature),
//! desktop-qt's FilesFolderSteps.cpp: the FolderExplorer and ProjectFolderDrop
//! bricks as DefaultShell places them, over real folders under the scenario's
//! home. The paths a scenario names ("/home/sam/code") live under that home;
//! the system Trash is a folder there.
//!
//! A drag of a link to a remote location cannot be made: Ljós hands a drop
//! only files (`ExternalDrag`), so that one scenario step fails with the gap.

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use ljos::prelude::{ExternalDrag, ObjectId, Value, external_drag};
use serde_json::json;

use super::stream::look_at_thread;
use crate::brick::{self, Brick};
use crate::harness::{Failure, Outcome, Q, Steps, at};
use crate::world::World;
use crate::{expect, fail};

/// What the Trash does, which the shell's trash hook reads while a scenario
/// runs.
#[derive(Default)]
struct Trash {
    path: RefCell<PathBuf>,
    unavailable: Cell<bool>,
}

#[derive(Default)]
struct Folders {
    /// The folder the user manages, as this machine names it.
    root: PathBuf,
    trash: Rc<Trash>,
    /// The disk under the managed folder before the operation under test.
    before: Vec<String>,
    /// The menu entry the user tried, for a folder it is not offered for.
    tried: String,
    /// What the last drag over the window was answered with.
    drag_accepted: bool,
}

fn folders(world: &mut World) -> &mut Folders {
    world.mc.part::<Folders>()
}

/// Where the scenario's machine keeps `path` ("/home/sam/code").
fn base(world: &World) -> PathBuf {
    let files = world.home_dir().join("files");
    let _ = std::fs::create_dir_all(&files);
    files.canonicalize().unwrap_or(files)
}

fn local(world: &World, path: &str) -> PathBuf {
    base(world).join(path.trim_start_matches('/'))
}

fn spelt(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// A name under the managed folder, or a full path.
fn resolve(world: &mut World, name: &str) -> PathBuf {
    if name.starts_with('/') {
        local(world, name)
    } else {
        folders(world).root.join(name)
    }
}

fn make_file(path: &Path) -> Outcome {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    match std::fs::write(path, "kept\n") {
        Ok(()) => Ok(()),
        Err(e) => fail!("cannot write {}: {e}", path.display()),
    }
}

/// Every path under `root`, relative to it and sorted. A link is listed, not
/// followed.
fn listing(root: &Path) -> Vec<String> {
    fn walk(root: &Path, dir: &Path, found: &mut Vec<String>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if let Ok(relative) = path.strip_prefix(root) {
                found.push(spelt(relative));
            }
            if entry.file_type().is_ok_and(|t| t.is_dir()) {
                walk(root, &path, found);
            }
        }
    }
    let mut found = Vec::new();
    walk(root, root, &mut found);
    found.sort();
    found
}

/// The explorer brick and its root item.
fn explorer(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    let shown = brick::shown(world)
        .map_err(|_| Failure("the folder explorer is not open".to_owned()))?;
    let item = shown.item(world, "folderExplorer")?;
    Ok((shown, item))
}

fn prop(world: &mut World, name: &str) -> Outcome<Value> {
    let (shown, item) = explorer(world)?;
    Ok(shown.read(world, item, name))
}

fn prop_text(world: &mut World, name: &str) -> Outcome<String> {
    let (shown, item) = explorer(world)?;
    Ok(shown.text_of(world, item, name))
}

fn prop_flag(world: &mut World, name: &str) -> Outcome<bool> {
    let (shown, item) = explorer(world)?;
    Ok(shown.flag(world, item, name))
}

fn invoke(world: &mut World, item: ObjectId, name: &str, arg: &str) -> Outcome {
    if let Err(error) = world
        .engine()
        .invoke_by_name(item, name, &[Value::from(arg)])
    {
        fail!("{name}: {error:?}");
    }
    world.pump()
}

/// The explorer as DefaultShell shows it: made when `folders.toggle` opens it,
/// gone when it closes.
fn open_explorer(world: &mut World) -> Outcome {
    let open = |world: &World| *at(&world.state("folders"), "open") == json!(true);
    if open(world) {
        world.dispatch("folders.toggle", json!({}))?;
        world.part::<brick::Shown>().0 = None;
    }
    world.dispatch("folders.toggle", json!({}))?;
    expect!(open(world), "the folder explorer did not open");
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Shell\nimport HalC2.Bricks\n\
         FolderExplorer { visible: Shell.state.folders?.open ?? false }\n",
        420.0,
        760.0,
    )
}

/// A part of the explorer or of its dialog, which is the overlay's only while
/// it is open.
fn part(world: &mut World, object_name: &str) -> Outcome<ObjectId> {
    let (shown, _) = explorer(world)?;
    shown.item(world, object_name)
}

fn text(world: &mut World, object_name: &str) -> Outcome<String> {
    let label = part(world, object_name)?;
    let (shown, _) = explorer(world)?;
    Ok(if shown.flag(world, label, "visible") {
        shown.text_of(world, label, "text")
    } else {
        String::new()
    })
}

/// What the explorer shows, for a failure's message; never fails itself.
fn describe(world: &mut World) -> String {
    let mut line = |name: &str| text(world, name).unwrap_or_default();
    let status = line("folderExplorerStatus");
    let hint = line("folderExplorerHint");
    let error = line("folderOperationError");
    let root = prop_text(world, "rootPath").unwrap_or_default();
    let selected = prop_text(world, "selectedPath").unwrap_or_default();
    let local = prop_flag(world, "localAccess").unwrap_or(false);
    let visible = explorer(world).is_ok_and(|(shown, item)| shown.flag(world, item, "visible"));
    format!(
        "the explorer (local {local}, visible {visible}) shows \"{root}\" (selected \"{selected}\"), \
         says \"{status}\", hints \"{hint}\" and its dialog says \"{error}\""
    )
}

fn select(world: &mut World, path: &str) -> Outcome {
    let (shown, item) = explorer(world)?;
    let root = shown.text_of(world, item, "rootPath");
    let chosen = if path == root { "" } else { path };
    shown.write(world, item, "selectedPath", Value::from(chosen))
}

fn offered(world: &mut World, operation: &str) -> Outcome<bool> {
    // The menu's entries follow these.
    prop_flag(
        world,
        if operation == "create" {
            "directorySelected"
        } else {
            "canModifySelection"
        },
    )
}

fn dialog(world: &mut World) -> Outcome<ObjectId> {
    part(world, "folderOperationDialog")
}

/// Chooses create, rename, move or trash for `path` from its menu.
fn begin(world: &mut World, operation: &str, path: &Path) -> Outcome {
    select(world, &spelt(path))?;
    if !offered(world, operation)? {
        fail!(
            "{operation} is not offered for {}; {}",
            path.display(),
            describe(world)
        );
    }
    let root = folders(world).root.clone();
    folders(world).before = listing(&root);
    let (_, item) = explorer(world)?;
    invoke(world, item, "beginOperation", operation)?;
    let (shown, _) = explorer(world)?;
    world.wait_for_with(
        |w| {
            shown
                .find(w, "folderOperationDialog")
                .ok()
                .flatten()
                .is_some_and(|d| shown.flag(w, d, "opened"))
        },
        |w| {
            let found = shown.find(w, "folderOperationDialog").ok().flatten();
            let read = |name: &str| found.map(|d| shown.text_of(w, d, name));
            format!(
                "the folder dialog to open (found {}, input {}, menu {}, opened {:?}, visible {:?}, operation {:?}, target {:?})",
                found.is_some(),
                shown.find(w, "folderOperationInput").ok().flatten().is_some(),
                shown.find(w, "folderContextMenu").ok().flatten().is_some(),
                read("opened"),
                read("visible"),
                read("operation"),
                read("targetPath")
            )
        },
    )
}

fn type_entry(world: &mut World, entry: &str) -> Outcome {
    let (shown, _) = explorer(world)?;
    let input = part(world, "folderOperationInput")?;
    shown.write(world, input, "text", Value::from(entry))
}

fn confirm(world: &mut World) -> Outcome {
    let (shown, _) = explorer(world)?;
    shown.click(world, "folderOperationConfirm")
}

fn run(world: &mut World, operation: &str, path: &Path, entry: &str) -> Outcome {
    begin(world, operation, path)?;
    type_entry(world, entry)?;
    confirm(world)
}

fn expect_finished(world: &mut World) -> Outcome {
    let (shown, _) = explorer(world)?;
    let closed = |w: &World| {
        shown
            .find(w, "folderOperationDialog")
            .ok()
            .flatten()
            .is_none_or(|d| !shown.flag(w, d, "visible"))
    };
    if world
        .wait_for("the folder dialog to close", closed)
        .is_err()
    {
        fail!("the folder dialog to close; {}", describe(world));
    }
    Ok(())
}

/// A project of this machine at `path`.
fn register_project(world: &mut World, path: &Path) -> Outcome {
    let _ = std::fs::create_dir_all(path);
    let id = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let row = json!({"id": id, "title": id, "workspaceRoot": spelt(path),
                     "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z",
                     "scripts": []});
    world.mc.projects.insert(id.clone(), row.clone());
    world.mc.send_row_of(&id, &row, "project");
    world.sync()
}

// --- Dragging over the window ---------------------------------------------------------

fn drag(world: &mut World, files: Vec<PathBuf>) -> Outcome {
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Bricks\nProjectFolderDrop { objectName: \"folderDrop\" }\n",
        900.0,
        700.0,
    )?;
    let taken = external_drag(
        world.engine(),
        &ExternalDrag::Entered {
            files,
            at: Some((450.0, 350.0)),
        },
    );
    folders(world).drag_accepted = taken;
    // The overlay is read while the drag is over the window.
    world.pump()
}

fn try_operation(world: &mut World, operation: &str, folder: &str) -> Outcome {
    let root = folders(world).root.clone();
    folders(world).before = listing(&root);
    let path = local(world, folder);
    select(world, &spelt(&path))?;
    folders(world).tried = operation.to_owned();
    Ok(())
}

/// Renames the folder the user manages; false when no scenario manages one.
pub fn rename_managed_folder(world: &mut World, folder: &str, name: &str) -> Outcome<bool> {
    if folders(world).root.as_os_str().is_empty() {
        return Ok(false);
    }
    let path = resolve(world, folder);
    run(world, "rename", &path, name)?;
    expect_finished(world)?;
    Ok(true)
}

/// Tries to move the folder the user manages; false when no scenario manages
/// one.
pub fn try_move_managed_folder(world: &mut World, folder: &str) -> Outcome<bool> {
    if folders(world).root.as_os_str().is_empty() {
        return Ok(false);
    }
    try_operation(world, "move", folder)?;
    Ok(true)
}

pub fn register(steps: &mut Steps) {
    // A full path on the scenario's machine.
    let path = "\"(/[^\"]*)\"";

    steps.step(
        &format!("the user manages (?:the folder )?{path}"),
        |world, c, _| {
            if folders(world).root.as_os_str().is_empty() {
                let root = local(world, &c[0]);
                for folder in ["old", "tmp", "archive/2025", "shop/tmp"] {
                    let _ = std::fs::create_dir_all(root.join(folder));
                }
                make_file(&root.join("notes.txt"))?;
                let trash = base(world).join(".Trash");
                let _ = std::fs::create_dir_all(&trash);
                let state = folders(world);
                state.root = root;
                let hook = Rc::clone(&state.trash);
                *hook.path.borrow_mut() = trash;
                hal_c2_shell::folders::set_trash(world.engine(), move |source| {
                    !hook.unavailable.get()
                        && Path::new(source).file_name().is_some_and(|name| {
                            std::fs::rename(source, hook.path.borrow().join(name)).is_ok()
                        })
                });
                open_explorer(world)?;
            }
            let (shown, item) = explorer(world)?;
            world.wait_for("the explorer to see the local environment", |w| {
                shown.flag(w, item, "localAccess")
            })?;
            let root = spelt(&folders(world).root);
            invoke(world, item, "openRoot", &root)?;
            if prop_text(world, "rootPath")? != root {
                fail!("{}", describe(world));
            }
            Ok(())
        },
    );

    steps.step(
        "the desktop app shows an environment on another machine",
        |world, _, _| {
            // As main.cpp starts a shell attached to an MC elsewhere.
            let engine = world.engine();
            Bridge::of(engine).set_local_folder_import_enabled(engine, false);
            Bridge::of(engine).set_mc_origin(engine, "https://mc-b.example.ts.net");
            if world.part::<brick::Shown>().0.is_some() {
                world.dispatch("folders.toggle", json!({"open": false}))?;
                world.part::<brick::Shown>().0 = None;
            }
            Ok(())
        },
    );
    steps.step("the user opens the folder explorer", |world, _, _| {
        open_explorer(world)
    });
    steps.step(
        "the user is told folder management needs a connected local environment",
        |world, _, _| {
            expect!(
                text(world, "folderExplorerUnavailable")?
                    .starts_with("Folder management is available only for a connected local environment"),
                "{}",
                describe(world)
            );
            expect!(
                !offered(world, "create")? && !offered(world, "rename")?,
                "folders can still be changed"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user is looking at a thread in the project at {path}"),
        |world, c, _| {
            let folder = local(world, &c[0]);
            register_project(world, &folder)?;
            let name = folder
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            look_at_thread(world, &name)
        },
    );
    steps.step(&format!("the explorer shows {path}"), |world, c, _| {
        let wanted = spelt(&local(world, &c[0]));
        let (shown, item) = explorer(world)?;
        if world
            .wait_for("the explorer to show the folder", |w| {
                shown.text_of(w, item, "rootPath") == wanted
            })
            .is_err()
        {
            fail!("{}", describe(world));
        }
        Ok(())
    });

    steps.step(
        "the user chooses to manage (the home folder|the filesystem root|a link to another folder|a folder that does not exist)",
        |world, c, _| {
            let mut chosen = std::env::var("HOME").unwrap_or_else(|_| "/".to_owned());
            match c[0].as_str() {
                "the filesystem root" => chosen = "/".to_owned(),
                "a folder that does not exist" => {
                    chosen = spelt(&local(world, "/home/sam/missing"));
                }
                "a link to another folder" => {
                    let link = local(world, "/home/sam/link");
                    let root = folders(world).root.clone();
                    if let Err(e) = std::os::unix::fs::symlink(&root, &link) {
                        fail!("cannot link {}: {e}", link.display());
                    }
                    chosen = spelt(&link);
                }
                _ => {}
            }
            let (_, item) = explorer(world)?;
            invoke(world, item, "openRoot", &chosen)
        },
    );
    steps.step(
        "the user is told to choose an existing local folder other than home or a filesystem root",
        |world, _, _| {
            let said = text(world, "folderExplorerStatus")?
                .starts_with("Choose an existing local folder other than your home or a filesystem root.");
            expect!(
                said && prop_text(world, "rootPath")?.is_empty(),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    steps.step(&format!("the user selects the file {Q}"), |world, c, _| {
        let file = resolve(world, &c[0]);
        select(world, &spelt(&file))
    });
    steps.step("the user is told files are shown read-only", |world, _, _| {
        expect!(
            text(world, "folderExplorerHint")?.starts_with("Files are shown read-only."),
            "{}",
            describe(world)
        );
        for operation in ["create", "rename"] {
            expect!(
                !offered(world, operation)?,
                "{operation} is offered for a file"
            );
        }
        Ok(())
    });

    // Creating, renaming and moving.
    steps.step(
        &format!("the user creates the folder {Q} in {path}"),
        |world, c, _| {
            let parent = local(world, &c[1]);
            run(world, "create", &parent, &c[0])?;
            expect_finished(world)
        },
    );
    steps.step(&format!("{path} holds {Q}"), |world, c, _| {
        make_file(&local(world, &c[0]).join(&c[1]))
    });
    steps.step(
        &format!("the user moves {Q} into {path}"),
        |world, c, _| {
            let target = local(world, &c[1]);
            let _ = std::fs::create_dir_all(&target);
            let source = resolve(world, &c[0]);
            run(world, "move", &source, &spelt(&target))
        },
    );
    steps.step(&format!("{path} exists"), |world, c, _| {
        let wanted = local(world, &c[0]);
        if world
            .wait_for("the folder to exist", |_| wanted.exists())
            .is_err()
        {
            fail!("{}; {}", c[0], describe(world));
        }
        Ok(())
    });
    steps.step(&format!("{path} does not exist"), |world, c, _| {
        expect!(!local(world, &c[0]).exists(), "{} is still there", c[0]);
        Ok(())
    });
    steps.step(&format!("{path} still exists"), |world, c, _| {
        expect!(
            local(world, &c[0]).is_dir(),
            "{} is gone; {}",
            c[0],
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user is told the folder was updated on disk",
        |world, _, _| {
            expect!(
                text(world, "folderExplorerStatus")? == "Folder updated on disk.",
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told a folder cannot be moved into itself or one of its descendants",
        |world, _, _| {
            let shown_error = text(world, "folderOperationError")?
                == "A folder cannot be moved into itself or one of its descendants.";
            let (shown, _) = explorer(world)?;
            let dialog = dialog(world)?;
            let visible = shown.flag(world, dialog, "visible");
            expect!(shown_error && visible, "{}", describe(world));
            Ok(())
        },
    );

    // Names that would overwrite or escape.
    steps.step(&format!("the user creates a folder using {Q}"), |world, c, _| {
        let root = folders(world).root.clone();
        run(world, "create", &root, &c[0])
    });
    steps.step(
        &format!("the user renames {Q} using {Q}"),
        |world, c, _| {
            let folder = resolve(world, &c[0]);
            run(world, "rename", &folder, &c[1])
        },
    );
    // The folder moved into already holds one of that name.
    steps.step(
        &format!("the user moves {Q} into a folder using {Q}"),
        |world, c, _| {
            let target = resolve(world, &c[1]);
            let _ = std::fs::create_dir_all(target.join(&c[0]));
            let source = resolve(world, &c[0]);
            run(world, "move", &source, &spelt(&target))
        },
    );
    steps.step("nothing on disk changes", |world, _, _| {
        let root = folders(world).root.clone();
        let now = listing(&root);
        let before = folders(world).before.clone();
        expect!(
            now == before,
            "the disk went from [{}] to [{}]",
            before.join(", "),
            now.join(", ")
        );
        Ok(())
    });

    // Projects keep their place.
    steps.step(&format!("{path} is a registered project"), |world, c, _| {
        let folder = local(world, &c[0]);
        register_project(world, &folder)
    });
    steps.step(
        &format!("the user tries to (rename|move to the Trash) {path}"),
        |world, c, _| {
            let operation = if c[0] == "rename" { "rename" } else { "trash" };
            try_operation(world, operation, &c[1])
        },
    );
    steps.step(
        "the user is told the location is protected because threads may still use that path",
        |world, _, _| {
            let (shown, _) = explorer(world)?;
            let hint = part(world, "folderExplorerHint")?;
            if world
                .wait_for("the location to be called protected", |w| {
                    shown.flag(w, hint, "visible")
                        && shown
                            .text_of(w, hint, "text")
                            .contains("Its location is protected because threads may still use that path.")
                })
                .is_err()
            {
                fail!("{}", describe(world));
            }
            // The entry is there and cannot be chosen.
            let tried = folders(world).tried.clone();
            let entry = shown.find(world, &format!("{tried}FolderMenuItem"))?;
            expect!(
                entry.is_some_and(|e| !shown.flag(world, e, "enabled")),
                "{tried} can be chosen"
            );
            let root = folders(world).root.clone();
            expect!(
                listing(&root) == folders(world).before,
                "the disk changed"
            );
            Ok(())
        },
    );

    // The Trash.
    steps.step(
        &format!("the user asks to move {Q} to the Trash"),
        |world, c, _| {
            let folder = resolve(world, &c[0]);
            begin(world, "trash", &folder)
        },
    );
    steps.step(
        "the user is told it moves the folder to the system Trash and keeps projects and conversations",
        |world, _, _| {
            let (shown, _) = explorer(world)?;
            expect!(
                shown.shows(
                    world,
                    "This moves the folder and everything inside it to your system Trash. It does not remove a project or \
                     its conversations from HAL-C2. Type the folder name to confirm."
                )?,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the Trash cannot be confirmed until the user types {Q}"),
        |world, c, _| {
            let (shown, _) = explorer(world)?;
            let button = part(world, "folderOperationConfirm")?;
            let enabled = |world: &World| shown.flag(world, button, "enabled");
            expect!(!enabled(world), "the Trash can be confirmed with nothing typed");
            type_entry(world, &format!("{}x", c[0]))?;
            expect!(
                !enabled(world),
                "the Trash can be confirmed with another name"
            );
            type_entry(world, &c[0])?;
            expect!(
                enabled(world),
                "the Trash cannot be confirmed with the folder's name"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user moves {Q} to the Trash and confirms with its name"),
        |world, c, _| {
            let folder = resolve(world, &c[0]);
            run(world, "trash", &folder, &c[0])
        },
    );
    steps.step(&format!("{path} is in the system Trash"), |world, c, _| {
        expect_finished(world)?;
        let gone = local(world, &c[0]);
        let trash = folders(world).trash.path.borrow().clone();
        let name = gone.file_name().map(|n| n.to_owned()).unwrap_or_default();
        expect!(
            !gone.exists() && trash.join(&name).is_dir(),
            "the Trash holds [{}]; {}",
            listing(&trash).join(", "),
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user is told the folder moved to the system Trash",
        |world, _, _| {
            expect!(
                text(world, "folderExplorerStatus")? == "Folder moved to system Trash.",
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the system Trash is unavailable", |world, _, _| {
        folders(world).trash.unavailable.set(true);
        Ok(())
    });
    steps.step(
        "the user is told it could not be moved and was not permanently deleted",
        |world, _, _| {
            expect!(
                text(world, "folderOperationError")?
                    == "The folder could not be moved to the system trash. It has not been permanently deleted.",
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user starts renaming {Q} and cancels"),
        |world, c, _| {
            let folder = resolve(world, &c[0]);
            begin(world, "rename", &folder)?;
            type_entry(world, "renamed")?;
            let (shown, _) = explorer(world)?;
            shown.click(world, "folderOperationCancel")?;
            expect_finished(world)?;
            let root = folders(world).root.clone();
            expect!(
                listing(&root) == folders(world).before,
                "the disk changed"
            );
            Ok(())
        },
    );

    steps.step(
        &format!("{path} is replaced by a link to another folder"),
        |world, c, _| {
            let root = local(world, &c[0]);
            let mut moved = root.clone().into_os_string();
            moved.push("-moved");
            let moved = PathBuf::from(moved);
            expect!(
                std::fs::rename(&root, &moved).is_ok()
                    && std::os::unix::fs::symlink(&moved, &root).is_ok(),
                "cannot replace {} by a link",
                root.display()
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told the selected root is no longer a plain local folder",
        |world, _, _| {
            let (shown, _) = explorer(world)?;
            let status = part(world, "folderExplorerStatus")?;
            if world
                .wait_for("the root to be called not plain", |w| {
                    shown.flag(w, status, "visible")
                        && shown.text_of(w, status, "text")
                            == "The selected root is no longer a plain local folder."
                })
                .is_err()
            {
                fail!("{}", describe(world));
            }
            expect!(
                prop_text(world, "rootPath")?.is_empty() && !offered(world, "create")?,
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the user opens {path} as a project"),
        |world, c, _| {
            let folder = local(world, &c[0]);
            let _ = std::fs::create_dir_all(&folder);
            select(world, &spelt(&folder))?;
            let (shown, _) = explorer(world)?;
            let entry = shown.find(world, "openFolderProjectMenuItem")?;
            let usable = entry.is_some_and(|e| shown.flag(world, e, "enabled"));
            expect!(
                usable,
                "the folder cannot be opened as a project; {}",
                describe(world)
            );
            if let Some(entry) = entry
                && let Err(error) = world.engine().emit_by_name(entry, "triggered", &[])
            {
                fail!("triggered: {error}");
            }
            world.pump()
        },
    );
    steps.step(&format!("the project {Q} is listed"), |world, c, _| {
        let names = |w: &World| -> Vec<String> {
            at(&w.state("sidebar"), "projects")
                .as_array()
                .map(|projects| {
                    projects
                        .iter()
                        .filter_map(|p| p["displayName"].as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default()
        };
        let wanted = c[0].clone();
        world.wait_for_with(
            |w| names(w).contains(&wanted),
            |w| format!("{}; the sidebar lists {}", c[0], names(w).join(", ")),
        )
    });

    // Dragging over the window.
    steps.step(
        &format!("the user drags the folder {path} over the window"),
        |world, c, _| {
            let folder = local(world, &c[0]);
            let _ = std::fs::create_dir_all(&folder);
            drag(world, vec![folder])
        },
    );
    steps.step(
        "the user drags (a file|two folders|a link to a remote location|a local folder) over the window",
        |world, c, _| {
            let one = local(world, "/home/sam/one");
            let two = local(world, "/home/sam/two");
            let _ = std::fs::create_dir_all(&one);
            let _ = std::fs::create_dir_all(&two);
            make_file(&one.join("notes.txt"))?;
            let files = match c[0].as_str() {
                "a file" => vec![one.join("notes.txt")],
                "two folders" => vec![one, two],
                "a link to a remote location" => {
                    fail!("Ljós hands a drop only files; a dragged link to https://example.com/shop cannot be made")
                }
                _ => vec![one],
            };
            drag(world, files)
        },
    );
    steps.step(
        "the user is told the folder opens as a project",
        |world, _, _| {
            let shown = brick::shown(world)?;
            let drop = shown.item(world, "folderDrop")?;
            let folder = shown.text_of(world, drop, "directoryPath");
            let accepted = folders(world).drag_accepted;
            let told = shown.shows(
                world,
                &format!("Open folder as a project\n{folder}\nNo files will be moved or deleted."),
            )?;
            expect!(
                accepted && !folder.is_empty() && told,
                "the drag was {} for \"{folder}\"",
                if accepted { "taken" } else { "refused" }
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told no files will be moved or deleted",
        |world, _, _| {
            let shown = brick::shown(world)?;
            let drop = shown.item(world, "folderDrop")?;
            let folder = shown.text_of(world, drop, "directoryPath");
            expect!(
                shown.shows(
                    world,
                    &format!("Open folder as a project\n{folder}\nNo files will be moved or deleted.")
                )?,
                "the window does not say files are kept"
            );
            Ok(())
        },
    );
    steps.step("the drop is refused", |world, _, _| {
        let shown = brick::shown(world)?;
        let drop = shown.item(world, "folderDrop")?;
        let folder = shown.text_of(world, drop, "directoryPath");
        expect!(
            !folders(world).drag_accepted && folder.is_empty(),
            "the drag was taken for \"{folder}\""
        );
        world.sync()?;
        for rpc in &world.mc.calls {
            expect!(rpc.method != "projects.mutate", "a project was changed");
        }
        Ok(())
    });
}

