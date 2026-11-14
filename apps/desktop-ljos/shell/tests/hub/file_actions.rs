//! `fileActions` as the Files tab meets it (FileActionsController.cpp,
//! features/files/file-explorer.feature): the kinds the user reads as source
//! are kept in the device settings and handed back to the tab, and a save the
//! MC refuses is toasted.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::file_actions::COPY_CONTENTS;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use hal_c2_shell::thread_view::workspace_files::{SAVE_DELAY_MS, WorkspaceFiles};
use ljos::prelude::{ObjectId, Value};
use serde_json::json;

use crate::Hub;
use crate::page::toasts;

/// A thread `t1` of project `p1` (`/work/p`) open with its Files tab, over a
/// device whose settings sit in a folder of their own.
fn files_tab() -> (Hub, ObjectId, tempfile::TempDir) {
    let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    let hub = Hub::with(Launch {
        config_dir: Some(dir.path().to_owned()),
        mc_origin: Some("http://127.0.0.1:1".into()),
        ..Launch::default()
    });
    hub.mc.set_ready(&hub.engine, true);
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
        "environment": {"environmentId": "env-1", "label": "Here"}}],
        "rows": [
            ["a", "p1", "project", {"id": "p1", "title": "P", "workspaceRoot": "/work/p"}],
            ["a", "t1", "thread", {"id": "t1", "projectId": "p1", "title": "T1"}],
        ]}),
    );
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    hub.dispatch("rightPanel.add", json!({"kind": "files"}));
    let files = hub.with_controller::<RightPanel, _>(|p, _| p.files().expect("the Files tab"));
    (hub, files, dir)
}

/// Answers the read of `path`, whatever else the shell has read.
fn read(hub: &Hub, path: &str, contents: &str) {
    let index = hub
        .mc
        .calls
        .borrow()
        .iter()
        .position(|(_, method, payload)| {
            method == "projects.readFile" && payload["relativePath"] == path
        })
        .expect("the file is read");
    assert!(
        hub.mc
            .reply(&hub.engine, index, Ok(json!({"contents": contents})))
    );
}

fn source_kinds(hub: &Hub, files: ObjectId) -> Vec<String> {
    WorkspaceFiles::source_kinds(&hub.engine, files)
}

#[test]
fn the_tab_shows_the_kinds_this_device_keeps_as_source() {
    let (hub, files, _dir) = files_tab();
    assert!(source_kinds(&hub, files).is_empty());
    Settings::of(&hub.engine).write_device(&hub.engine, "fileSourceKinds", json!(["markdown"]));
    assert_eq!(source_kinds(&hub, files), ["markdown"]);
    Settings::of(&hub.engine).write_device(&hub.engine, "fileSourceKinds", Json::Null);
    assert!(source_kinds(&hub, files).is_empty());
}

#[test]
fn reading_a_kind_as_source_is_kept_for_the_next_file_of_it() {
    let (hub, files, _dir) = files_tab();
    hub.mc.answer(
        &hub.engine,
        "projects.listEntries",
        Ok(json!({"entries": []})),
    );
    hub.engine
        .invoke_by_name(files, "openFile", &[Value::from("todo.md"), Value::from(0)])
        .unwrap();
    read(&hub, "todo.md", "- [ ] a\n");

    hub.engine
        .write_by_name(files, "rendered", Value::Bool(false))
        .unwrap();
    assert_eq!(
        Settings::of(&hub.engine).device_value("fileSourceKinds"),
        Some(json!(["markdown"]))
    );
    // Rendered again, nothing is kept (the setting goes).
    hub.engine
        .write_by_name(files, "rendered", Value::Bool(true))
        .unwrap();
    assert_eq!(
        Settings::of(&hub.engine).device_value("fileSourceKinds"),
        None
    );
}

#[test]
fn a_save_the_mc_refuses_is_toasted_with_the_path() {
    let (hub, files, _dir) = files_tab();
    hub.mc.answer(
        &hub.engine,
        "projects.listEntries",
        Ok(json!({"entries": []})),
    );
    hub.engine
        .invoke_by_name(files, "openFile", &[Value::from("a.txt"), Value::from(0)])
        .unwrap();
    read(&hub, "a.txt", "");
    hub.engine
        .write_by_name(files, "editing", Value::Bool(true))
        .unwrap();
    hub.engine
        .invoke_by_name(files, "edit", &[Value::from("x")])
        .unwrap();
    hub.advance(SAVE_DELAY_MS as u64);
    hub.mc.answer(
        &hub.engine,
        "projects.writeFile",
        Err(McError::new("read-only file system")),
    );
    assert_eq!(
        toasts(&hub),
        [(
            "Could not save a.txt".to_owned(),
            "read-only file system".to_owned()
        )]
    );
}

#[test]
fn a_file_opens_in_the_checkout_the_files_tab_shows() {
    let (hub, _files, _dir) = files_tab();
    crate::workspace::editors(&hub, &["vscode"]);
    hub.dispatch(
        "files.openInEditor",
        json!({"path": "src/a.rs", "editorId": "vscode"}),
    );
    let opened: Vec<Json> = hub
        .mc
        .calls
        .borrow()
        .iter()
        .filter(|(_, method, _)| method == "shell.openInEditor")
        .map(|(_, _, payload)| payload.clone())
        .collect();
    assert_eq!(
        opened,
        [json!({"cwd": "/work/p/src/a.rs", "editor": "vscode"})]
    );
}

/// Whether "Copy file contents" can run, and shows in the palette.
fn copy_offered(hub: &Hub) -> (bool, bool) {
    let rows = Commands::of(&hub.engine).rows();
    let row = rows
        .iter()
        .find(|r| r.command == COPY_CONTENTS)
        .expect("the command is added");
    (row.enabled, row.listed)
}

/// "Copy file contents" puts the open text file on the clipboard, saying
/// when only its start came along; it is offered only while one is open
/// (features/files/file-viewer-and-editing.feature).
#[test]
fn the_open_text_file_is_copied_whole_or_said_to_be_its_start() {
    let (hub, files, _dir) = files_tab();
    let copied = Rc::new(RefCell::new(Vec::<String>::new()));
    let writes = Rc::new(RefCell::new(true));
    let (sink, works) = (copied.clone(), writes.clone());
    Bridge::of(&hub.engine).set_clipboard_writer(&hub.engine, move |t| {
        sink.borrow_mut().push(t.to_owned());
        *works.borrow()
    });
    hub.mc.answer(
        &hub.engine,
        "projects.listEntries",
        Ok(json!({"entries": []})),
    );
    let commands = Commands::of(&hub.engine);
    assert_eq!(copy_offered(&hub), (false, false));
    assert!(commands.run(&hub.engine, COPY_CONTENTS));
    assert!(copied.borrow().is_empty());

    let open = |path: &str| {
        hub.engine
            .invoke_by_name(files, "openFile", &[Value::from(path), Value::from(0)])
            .unwrap();
    };
    open("a.txt");
    // Still loading.
    assert_eq!(copy_offered(&hub), (false, false));
    read(&hub, "a.txt", "one\ntwo");
    assert_eq!(copy_offered(&hub), (true, true));
    commands.run(&hub.engine, COPY_CONTENTS);
    assert_eq!(*copied.borrow(), ["one\ntwo"]);
    assert_eq!(
        toasts(&hub).first().cloned(),
        Some(("File contents copied".into(), "a.txt".into()))
    );

    open("big.log");
    let index = hub
        .mc
        .pending_where("projects.readFile", |p| p["relativePath"] == "big.log")
        .expect("the file is read");
    hub.mc.reply(
        &hub.engine,
        index,
        Ok(json!({"contents": "start", "truncated": true})),
    );
    commands.run(&hub.engine, COPY_CONTENTS);
    assert_eq!(copied.borrow().last().map(String::as_str), Some("start"));
    assert_eq!(
        toasts(&hub).first().cloned(),
        Some((
            "File contents copied".into(),
            "Only the first 1 MB of big.log.".into()
        ))
    );

    *writes.borrow_mut() = false;
    commands.run(&hub.engine, COPY_CONTENTS);
    assert_eq!(
        toasts(&hub).first().cloned(),
        Some((
            "Failed to copy file contents".into(),
            "An error occurred.".into()
        ))
    );

    // An image is shown, not copied as text.
    open("logo.png");
    assert_eq!(copy_offered(&hub), (false, false));
}
