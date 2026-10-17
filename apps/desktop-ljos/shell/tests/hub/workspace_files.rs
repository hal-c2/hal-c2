//! `WorkspaceFiles` as the Files tab binds it, over a fake MC the test
//! answers (tst_WorkspaceFilesRegression, features/files/file-explorer.feature
//! and file-viewer-and-editing.feature): the tree listing as folders open,
//! the search after a pause, the file read, edited and written, and the tree
//! following the agent.

use std::cell::RefCell;
use std::rc::Rc;

use crate::Hub;
use crate::common::{self, FakeMc};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use hal_c2_shell::thread_view::file_tree::FileTreeModel;
use hal_c2_shell::thread_view::rows::RowSource;
use hal_c2_shell::thread_view::timeline::Timeline;
use hal_c2_shell::thread_view::timeline_model::TimelineModel;
use hal_c2_shell::thread_view::workspace_files::{
    SAVE_DELAY_MS, SEARCH_DELAY_MS, TextLinesModel, WorkspaceFiles, search_entries,
};
use ljos::prelude::{Engine, ObjectId, Value};
use serde_json::json;

struct Files {
    hub: Hub,
    engine: Engine,
    files: ObjectId,
    tree: ObjectId,
    mc: Rc<FakeMc>,
}

/// A Files tab on `env-a` at `/w`; hidden unless `active`.
fn files_on(root: &str, active: bool) -> Files {
    let hub = Hub::new();
    let (engine, mc) = (hub.engine.clone(), hub.mc.clone());
    let files = WorkspaceFiles::create(&engine, None, mc.clone()).expect("the files");
    let tree = WorkspaceFiles::tree(&engine, files).expect("its tree");
    WorkspaceFiles::set_target(&engine, files, "env-a", root);
    WorkspaceFiles::set_active(&engine, files, active);
    Files {
        hub,
        engine,
        files,
        tree,
        mc,
    }
}

fn s(v: &Value) -> String {
    match v {
        Value::String(a) => (**a).to_owned(),
        _ => String::new(),
    }
}

fn file(path: &str) -> Json {
    json!({"path": path, "kind": "file"})
}

fn folder(path: &str) -> Json {
    json!({"path": path, "kind": "directory"})
}

fn listing(entries: &[Json]) -> Result<Json, McError> {
    Ok(json!({ "entries": entries }))
}

fn refuse() -> Result<Json, McError> {
    Err(McError::new(""))
}

impl Files {
    /// "path kind" per row of the tree.
    fn rows(&self) -> Vec<String> {
        FileTreeModel::read(&self.engine, self.tree, |t| {
            (0..t.row_count())
                .map(|r| format!("{} {}", s(&t.data(r, "path")), s(&t.data(r, "kind"))))
                .collect()
        })
        .unwrap()
    }

    fn text(&self, name: &str) -> String {
        common::text(&self.engine, self.files, name)
    }

    fn flag(&self, name: &str) -> bool {
        common::read(&self.engine, self.files, name) == Value::Bool(true)
    }

    fn set(&self, name: &str, value: Value) {
        self.engine
            .write_by_name(self.files, name, value)
            .unwrap_or_else(|e| panic!("{name}: {e}"));
    }

    fn invoke(&self, name: &str, args: &[Value]) {
        common::call(&self.engine, self.files, name, args);
    }

    fn pass(&self, ms: i32) {
        self.hub.advance(ms as u64);
    }

    /// Every call so far to `method`, with its payload.
    fn asked(&self, method: &str) -> Vec<Json> {
        self.mc
            .calls
            .borrow()
            .iter()
            .filter(|(_, m, _)| m == method)
            .map(|(_, _, p)| p.clone())
            .collect()
    }

    /// The files calls (`projects.*`; the started shell makes others) in
    /// the order they were made, as their index among all the calls.
    fn made(&self) -> Vec<usize> {
        let calls = self.mc.calls.borrow();
        (0..calls.len())
            .filter(|&i| calls[i].1.starts_with("projects."))
            .collect()
    }

    /// The files calls so far as "method key": the folder listed, the query
    /// searched, the file read or written.
    fn log(&self) -> Vec<String> {
        let calls = self.mc.calls.borrow();
        self.made()
            .into_iter()
            .map(|i| {
                let (_, method, payload) = &calls[i];
                let key = ["directoryPath", "query", "relativePath"]
                    .iter()
                    .find_map(|k| payload.get(*k).and_then(Json::as_str))
                    .unwrap_or("");
                format!("{} {key}", method.trim_start_matches("projects."))
            })
            .collect()
    }

    /// Answers the `nth` files call made (from 0).
    fn answer(&self, nth: usize, result: Result<Json, McError>) {
        let index = self.made()[nth];
        assert!(self.mc.reply(&self.engine, index, result), "call {nth}");
    }

    fn lines(&self) -> Vec<String> {
        let lines = WorkspaceFiles::lines(&self.engine, self.files).unwrap();
        let count = common::number(&self.engine, lines, "count") as i32;
        (0..count)
            .map(|row| {
                let v = common::call(&self.engine, lines, "line", &[Value::from(row)]);
                self.engine.to_js_string(&v).to_string()
            })
            .collect()
    }

    /// Answers the oldest unanswered call to `method`.
    fn reply(&self, method: &str, result: Result<Json, McError>) {
        self.mc.answer(&self.engine, method, result);
    }

    /// Opens `path`, answers its read with `text`.
    fn open_with(&self, path: &str, text: &str) {
        self.invoke("openFile", &[Value::from(path), Value::from(0)]);
        self.reply("projects.readFile", Ok(json!({ "contents": text })));
    }
}

// --- Regressions: what tst_WorkspaceFilesProp found ---

// Two listings of one folder answered out of order: the older one, read
// before the agent changed the workspace, replaced the newer.
#[test]
fn an_older_listing_answered_late_is_dropped() {
    let f = files_on("/w", true);
    assert_eq!(f.log(), ["listEntries "]);
    f.answer(0, listing(&[file("first")]));
    FileTreeModel::update(&f.engine, f.tree, |t| t.refresh());
    FileTreeModel::update(&f.engine, f.tree, |t| t.refresh());
    assert_eq!(f.log().len(), 3);
    f.answer(2, listing(&[file("newer")]));
    f.answer(1, listing(&[file("older")]));
    assert_eq!(f.rows(), ["newer file"]);
}

// Switching workspace while a search was on its way showed the old
// workspace's matches in the new one.
#[test]
fn a_search_of_the_workspace_left_is_dropped() {
    let f = files_on("/w1", false);
    f.set("query", Value::from("x"));
    f.pass(SEARCH_DELAY_MS);
    assert_eq!(f.log(), ["searchEntries x"]);
    WorkspaceFiles::set_target(&f.engine, f.files, "env-a", "/w2");
    f.answer(0, listing(&[file("x-of-w1")]));
    assert!(!f.flag("searching"));
    assert_eq!(f.text("query"), "");
    assert!(f.rows().is_empty());
    assert_eq!(
        FileTreeModel::read(&f.engine, f.tree, |t| t.filtered()),
        Some(false)
    );
}

// A query typed with no workspace said a search was on its way, forever.
#[test]
fn a_query_without_a_workspace_is_not_searching() {
    let f = files_on("", false);
    f.set("query", Value::from("x"));
    assert!(!f.flag("searching"));
    f.pass(SEARCH_DELAY_MS);
    assert!(f.log().is_empty());
}

// The tab shown with a search's matches on screen never listed the top
// folder: it judged "never listed" by the tree having no rows.
#[test]
fn showing_the_tab_over_a_search_lists_the_top_folder() {
    let f = files_on("/w", false);
    f.set("query", Value::from("x"));
    f.pass(SEARCH_DELAY_MS);
    f.answer(0, listing(&[file("x")]));
    WorkspaceFiles::set_active(&f.engine, f.files, true);
    assert_eq!(f.log(), ["searchEntries x", "listEntries "]);
    // The search stays on screen until the query is cleared.
    assert_eq!(
        FileTreeModel::read(&f.engine, f.tree, |t| t.filtered()),
        Some(true)
    );
    f.answer(1, listing(&[file("top")]));
    assert_eq!(f.rows(), ["x file"]);
    f.set("query", Value::from(""));
    assert_eq!(f.rows(), ["top file"]);
}

// --- The tree ---

#[test]
fn a_hidden_tab_lists_nothing_until_it_shows() {
    let f = files_on("/w", false);
    assert!(f.log().is_empty());
    WorkspaceFiles::set_active(&f.engine, f.files, true);
    assert_eq!(f.log(), ["listEntries "]);
    // Showing it again does not list again.
    WorkspaceFiles::set_active(&f.engine, f.files, false);
    WorkspaceFiles::set_active(&f.engine, f.files, true);
    assert_eq!(f.log().len(), 1);
    let payload = f.asked("projects.listEntries").remove(0);
    assert_eq!(payload, json!({"cwd": "/w", "directoryPath": ""}));
}

#[test]
fn a_folder_lists_when_it_opens_and_says_why_it_would_not() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[folder("src"), file("a.txt")]));
    assert_eq!(f.rows(), ["src directory", "a.txt file"]);
    FileTreeModel::update(&f.engine, f.tree, |t| t.expand("src"));
    assert_eq!(f.log(), ["listEntries ", "listEntries src"]);
    f.answer(1, Err(McError::new("denied")));
    assert_eq!(f.rows(), ["src directory", "src error", "a.txt file"]);
    FileTreeModel::update(&f.engine, f.tree, |t| t.retry("src"));
    f.answer(2, listing(&[file("src/b.rs")]));
    assert_eq!(f.rows(), ["src directory", "src/b.rs file", "a.txt file"]);
}

#[test]
fn the_top_folder_can_be_listed_again_after_it_failed() {
    let f = files_on("/w", true);
    f.answer(0, refuse());
    assert_eq!(
        common::text(&f.engine, f.tree, "rootProblem"),
        "Unable to load folder."
    );
    f.invoke("reload", &[]);
    assert_eq!(f.log().len(), 2);
    f.answer(1, listing(&[file("a")]));
    assert_eq!(common::text(&f.engine, f.tree, "rootStatus"), "ready");
}

#[test]
fn a_new_workspace_forgets_the_tree_and_its_answers() {
    let f = files_on("/w1", true);
    WorkspaceFiles::set_target(&f.engine, f.files, "env-a", "/w2");
    assert_eq!(f.log(), ["listEntries ", "listEntries "]);
    assert_eq!(f.asked("projects.listEntries")[1]["cwd"], "/w2");
    f.answer(0, listing(&[file("old")]));
    f.answer(1, listing(&[file("new")]));
    assert_eq!(f.rows(), ["new file"]);
}

// --- Search ---

#[test]
fn typing_waits_for_a_pause_before_asking() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[]));
    f.set("query", Value::from("li"));
    assert!(f.flag("searching"));
    f.pass(SEARCH_DELAY_MS - 1);
    assert!(f.asked("projects.searchEntries").is_empty());
    // Typing on starts the pause again.
    f.set("query", Value::from("lib"));
    f.pass(SEARCH_DELAY_MS - 1);
    assert!(f.asked("projects.searchEntries").is_empty());
    f.pass(1);
    let asked = f.asked("projects.searchEntries");
    assert_eq!(asked, [json!({"cwd": "/w", "query": "lib", "limit": 200})]);
}

#[test]
fn matches_show_in_the_tree_and_a_failed_search_says_so() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[file("top")]));
    f.set("query", Value::from("lib"));
    f.pass(SEARCH_DELAY_MS);
    f.reply(
        "projects.searchEntries",
        Ok(json!({"entries": [file("src/lib.rs")], "truncated": true})),
    );
    assert_eq!(f.rows(), ["src directory", "src/lib.rs file"]);
    assert!(f.flag("searchTruncated") && !f.flag("searching"));
    f.set("query", Value::from("zz"));
    f.pass(SEARCH_DELAY_MS);
    f.reply("projects.searchEntries", Err(McError::new("")));
    assert_eq!(f.text("searchProblem"), "Unable to search files.");
    assert!(f.rows().is_empty());
}

#[test]
fn clearing_the_query_cancels_the_pause() {
    let f = files_on("/w", false);
    f.set("query", Value::from("a"));
    f.pass(SEARCH_DELAY_MS - 1);
    f.set("query", Value::from(" "));
    f.set("query", Value::from(""));
    f.pass(SEARCH_DELAY_MS);
    assert!(f.log().is_empty());
    assert!(!f.flag("searching"));
}

#[test]
fn the_composer_searches_the_same_way() {
    let mc = FakeMc::default();
    let found = Rc::new(RefCell::new(None));
    let engine = Hub::new().engine;
    let out = found.clone();
    search_entries(&mc, "env-a", "/w", "ab", 8, move |_, result| {
        *out.borrow_mut() = Some(result);
    });
    let (environment, method, payload) = mc.calls.borrow()[0].clone();
    assert_eq!(
        (environment.as_str(), method.as_str()),
        ("env-a", "projects.searchEntries")
    );
    assert_eq!(payload, json!({"cwd": "/w", "query": "ab", "limit": 8}));
    mc.reply(
        &engine,
        0,
        Ok(json!({"entries": [file("ab.rs"), folder("abc")], "truncated": true})),
    );
    let (entries, truncated) = found.borrow_mut().take().unwrap().unwrap();
    assert_eq!(entries.len(), 2);
    assert!(truncated);
}

// --- Revealing ---

// The tree opens the folders above a file as they are listed, and selects
// it.
#[test]
fn opening_a_file_reveals_it_in_the_tree() {
    let f = files_on("/w", true);
    f.invoke("openFile", &[Value::from("a/b/c.rs"), Value::from(0)]);
    assert_eq!(f.log(), ["listEntries ", "readFile a/b/c.rs"]);
    f.answer(0, listing(&[folder("a"), file("z.txt")]));
    assert_eq!(f.log().last().unwrap(), "listEntries a");
    f.answer(2, listing(&[folder("a/b")]));
    assert_eq!(f.log().last().unwrap(), "listEntries a/b");
    f.answer(3, listing(&[file("a/b/c.rs"), file("a/b/d.rs")]));
    assert_eq!(common::text(&f.engine, f.tree, "selectedPath"), "a/b/c.rs");
    assert_eq!(
        f.rows(),
        [
            "a directory",
            "a/b directory",
            "a/b/c.rs file",
            "a/b/d.rs file",
            "z.txt file"
        ]
    );
}

#[test]
fn a_file_outside_the_workspace_is_read_and_not_revealed() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[file("z.txt")]));
    f.invoke("openFile", &[Value::from("/etc/hosts"), Value::from(0)]);
    assert_eq!(f.log().last().unwrap(), "readFile /etc/hosts");
    assert_eq!(common::text(&f.engine, f.tree, "selectedPath"), "");
}

#[test]
fn revealing_a_file_of_a_tab_never_shown_lists_the_top_folder() {
    let f = files_on("/w", false);
    WorkspaceFiles::reveal_path(&f.engine, f.files, "x.txt");
    assert_eq!(f.log(), ["listEntries "]);
    f.answer(0, listing(&[file("x.txt")]));
    assert_eq!(common::text(&f.engine, f.tree, "selectedPath"), "x.txt");
}

// --- The file ---

#[test]
fn a_file_opens_as_one_row_per_line() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[]));
    f.open_with("src/a.rs", "fn a() {}\r\n\nfn b() {}\n");
    assert_eq!(f.text("fileStatus"), "ready");
    assert_eq!(f.lines(), ["fn a() {}", "", "fn b() {}"]);
    let lines = WorkspaceFiles::lines(&f.engine, f.files).unwrap();
    assert_eq!(common::number(&f.engine, lines, "maxColumns"), 9.0);
    f.invoke("closeFile", &[]);
    assert_eq!(f.text("fileStatus"), "none");
    assert!(f.lines().is_empty());
}

#[test]
fn a_requested_line_is_revealed_once_and_again_on_a_second_open() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[]));
    f.invoke("openFile", &[Value::from("a.txt"), Value::from(99)]);
    f.reply("projects.readFile", Ok(json!({"contents": "a\nb\nc\n"})));
    assert_eq!(common::number(&f.engine, f.files, "revealLine"), 3.0);
    f.invoke("openFile", &[Value::from("a.txt"), Value::from(2)]);
    assert_eq!(common::number(&f.engine, f.files, "revealLine"), 2.0);
    assert_eq!(f.asked("projects.readFile").len(), 1);
}

#[test]
fn a_file_that_fails_to_read_can_be_read_again() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[]));
    f.invoke("openFile", &[Value::from("a.txt"), Value::from(0)]);
    f.reply("projects.readFile", refuse());
    assert_eq!(f.text("fileStatus"), "error");
    assert_eq!(f.text("fileProblem"), "Unable to read this file.");
    f.invoke("reloadFile", &[]);
    assert_eq!(f.text("fileStatus"), "loading");
    f.reply("projects.readFile", Ok(json!({"contents": "ok"})));
    assert_eq!(f.lines(), ["ok"]);
}

#[test]
fn markdown_renders_until_the_user_chooses_its_source() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[]));
    let kinds = Rc::new(RefCell::new(0));
    let k = kinds.clone();
    WorkspaceFiles::on_source_kinds_changed(&f.engine, f.files, move |_| *k.borrow_mut() += 1);
    f.open_with("README.md", "- [ ] a\n");
    assert_eq!(f.text("renderKind"), "markdown");
    assert!(f.flag("rendered"));
    assert_eq!(f.text("renderedText"), "- [☐](task:0) a\n");
    f.set("rendered", Value::Bool(false));
    assert!(!f.flag("rendered"));
    assert_eq!(
        WorkspaceFiles::source_kinds(&f.engine, f.files),
        ["markdown"]
    );
    assert_eq!(*kinds.borrow(), 1);
    // Set by the owner (the device setting) it is not told back.
    WorkspaceFiles::set_source_kinds(&f.engine, f.files, &[]);
    assert!(f.flag("rendered"));
    assert_eq!(*kinds.borrow(), 1);
}

#[test]
fn a_csv_file_shows_as_a_table() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[]));
    f.open_with("t.csv", "a,b\n1,2\n");
    assert_eq!(f.text("renderKind"), "csv");
    assert_eq!(
        f.text("renderedText"),
        "| a | b |\n| --- | --- |\n| 1 | 2 |\n"
    );
}

#[test]
fn a_part_of_a_file_says_so_and_cannot_be_edited() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[]));
    f.invoke("openFile", &[Value::from("big.log"), Value::from(0)]);
    f.reply(
        "projects.readFile",
        Ok(json!({"contents": "x", "truncated": true, "byteLength": 3_145_728})),
    );
    assert_eq!(
        f.text("truncatedNotice"),
        "Preview limited to the first 1 MB of a 3,145,728 byte file."
    );
    assert!(!f.flag("editable"));
    assert_eq!(
        f.text("readOnlyReason"),
        "Files larger than 1 MB open read-only."
    );
}

#[test]
fn the_word_wrap_setting_is_the_default_until_the_user_chooses() {
    let f = files_on("/w", false);
    assert!(!f.flag("wrap"));
    WorkspaceFiles::set_default_wrap(&f.engine, f.files, true);
    assert!(f.flag("wrap"));
    f.set("wrap", Value::Bool(false));
    WorkspaceFiles::set_default_wrap(&f.engine, f.files, true);
    assert!(!f.flag("wrap"));
}

// --- Editing ---

#[test]
fn edits_save_themselves_shortly_after_the_user_stops_typing() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[]));
    f.open_with("a.txt", "one\n");
    f.set("editing", Value::Bool(true));
    assert!(f.flag("editing"));
    f.invoke("edit", &[Value::from("one\ntwo\n")]);
    assert!(f.flag("unsaved"));
    f.pass(SAVE_DELAY_MS - 1);
    assert!(f.asked("projects.writeFile").is_empty());
    f.invoke("edit", &[Value::from("one\ntwo\nthree\n")]);
    f.pass(SAVE_DELAY_MS - 1);
    assert!(f.asked("projects.writeFile").is_empty());
    f.pass(1);
    assert_eq!(
        f.asked("projects.writeFile"),
        [json!({"cwd": "/w", "relativePath": "a.txt", "contents": "one\ntwo\nthree\n"})]
    );
    f.reply("projects.writeFile", Ok(json!({})));
    assert!(!f.flag("unsaved"));
}

#[test]
fn closing_the_file_saves_pending_edits_first() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[]));
    f.open_with("a.txt", "");
    f.set("editing", Value::Bool(true));
    f.invoke("edit", &[Value::from("typed")]);
    f.invoke("closeFile", &[]);
    assert_eq!(f.asked("projects.writeFile")[0]["contents"], "typed");
    assert!(!f.flag("editing"));
}

#[test]
fn a_write_the_mc_refuses_is_told_to_the_owner() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[]));
    let failed = Rc::new(RefCell::new(Vec::new()));
    let out = failed.clone();
    WorkspaceFiles::on_save_failed(&f.engine, f.files, move |_, path, problem| {
        out.borrow_mut().push((path.to_owned(), problem.to_owned()));
    });
    f.open_with("a.txt", "");
    f.set("editing", Value::Bool(true));
    f.invoke("edit", &[Value::from("x")]);
    f.pass(SAVE_DELAY_MS);
    f.reply(
        "projects.writeFile",
        Err(McError::new("read-only file system")),
    );
    assert_eq!(f.text("saveProblem"), "read-only file system");
    assert!(f.flag("unsaved"));
    assert_eq!(
        *failed.borrow(),
        [("a.txt".to_owned(), "read-only file system".to_owned())]
    );
}

#[test]
fn ticking_a_markdown_task_writes_the_file() {
    let f = files_on("/w", true);
    f.answer(0, listing(&[]));
    f.open_with("todo.md", "- [ ] a\n- [x] b\n");
    f.invoke("toggleTask", &[Value::from(0)]);
    assert_eq!(
        f.asked("projects.writeFile")[0]["contents"],
        "- [x] a\n- [x] b\n"
    );
    assert_eq!(f.lines(), ["- [x] a", "- [x] b"]);
    assert_eq!(f.text("renderedText"), "- [☑](task:0) a\n- [☑](task:1) b\n");
}

// --- Following the agent ---

fn timeline(f: &Files) -> ObjectId {
    let model = TimelineModel::create(&f.engine, None, Timeline::new("env-a:t1")).unwrap();
    TimelineModel::update(&f.engine, model, |t| {
        t.subscribing();
    });
    receive(
        f,
        model,
        json!({"t": "snapshot", "part": 0, "rows": [], "done": true, "offset": 0,
            "handle": "log-1"}),
    );
    receive(
        f,
        model,
        json!({"t": "live", "offset": 0, "handle": "log-1"}),
    );
    model
}

fn receive(f: &Files, model: ObjectId, frame: Json) {
    let Json::Object(frame) = frame else {
        panic!("a frame is an object")
    };
    TimelineModel::update(&f.engine, model, |t| t.receive(&frame));
}

/// The agent's command `id` finishes.
fn command_finishes(f: &Files, model: ObjectId, id: &str, offset: i64) {
    receive(
        f,
        model,
        json!({"t": "events", "offset": offset, "events": [[offset, "turn-item", id,
            {"s": {"id": id, "type": "command_execution", "status": "completed",
                "ordinal": offset, "runId": "run-1"}}, "x"]]}),
    );
}

#[test]
fn a_shown_tab_lists_again_when_the_agent_changes_the_workspace() {
    let f = files_on("/w", true);
    let model = timeline(&f);
    WorkspaceFiles::set_timeline(&f.engine, f.files, Some(model));
    f.answer(0, listing(&[file("a")]));
    command_finishes(&f, model, "cmd-1", 1);
    assert_eq!(f.log(), ["listEntries ", "listEntries "]);
    f.answer(1, listing(&[file("a"), file("b")]));
    assert_eq!(f.rows(), ["a file", "b file"]);
    // The same state again is not a change.
    receive(
        &f,
        model,
        json!({"t": "live", "offset": 1, "handle": "log-1"}),
    );
    assert_eq!(f.log().len(), 2);
}

#[test]
fn a_hidden_tab_lists_again_when_it_next_shows() {
    let f = files_on("/w", true);
    let model = timeline(&f);
    WorkspaceFiles::set_timeline(&f.engine, f.files, Some(model));
    f.answer(0, listing(&[file("a")]));
    WorkspaceFiles::set_active(&f.engine, f.files, false);
    command_finishes(&f, model, "cmd-1", 1);
    assert_eq!(f.log().len(), 1);
    WorkspaceFiles::set_active(&f.engine, f.files, true);
    assert_eq!(f.log().len(), 2);
    // Showing it with nothing new lists nothing.
    WorkspaceFiles::set_active(&f.engine, f.files, false);
    WorkspaceFiles::set_active(&f.engine, f.files, true);
    assert_eq!(f.log().len(), 2);
}

#[test]
fn a_timeline_left_is_no_longer_followed() {
    let f = files_on("/w", true);
    let model = timeline(&f);
    WorkspaceFiles::set_timeline(&f.engine, f.files, Some(model));
    f.answer(0, listing(&[file("a")]));
    WorkspaceFiles::set_timeline(&f.engine, f.files, None);
    command_finishes(&f, model, "cmd-1", 1);
    assert_eq!(f.log().len(), 1);
}

// The lines model alone: the text a viewer lays out.
#[test]
fn the_lines_model_is_made_of_the_text() {
    let f = files_on("/w", false);
    let lines = TextLinesModel::create(&f.engine, None).unwrap();
    TextLinesModel::set_text(&f.engine, lines, "a\nbb\n");
    assert_eq!(common::number(&f.engine, lines, "count"), 2.0);
    assert_eq!(common::number(&f.engine, lines, "maxColumns"), 2.0);
    TextLinesModel::set_text(&f.engine, lines, "");
    assert_eq!(common::number(&f.engine, lines, "count"), 0.0);
}
