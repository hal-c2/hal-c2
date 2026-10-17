//! `palette`: the command palette as the CommandPalette brick drives it
//! (CommandPaletteController.cpp, tst_KeysPaletteRegression.cpp,
//! tst_KeysPaletteProp.cpp, features/navigation/command-palette.feature):
//! what it lists for a query, threads found by their messages, files and
//! content, browsing for a folder and asking for a line of text, and its
//! list moving only the rows that change.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::commands::{Choice, Commands};
use hal_c2_shell::controllers::keybindings::{Focus, Keymap};
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::palette::{
    self, BrowseOptions, Palette, PaletteObject, SEARCH_DELAY_MS,
};
use hal_c2_shell::json::Json;
use ljos::prelude::{Atom, Engine, ModelChange, ObjectId, Value};
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::common::{call, js_value};

pub(crate) const AT: &str = "2026-09-23T09:00:00Z";
const MESSAGES: &str = "orchestration.searchThreads";
const PROJECT: &str = "Shop";

fn key(thread: &str) -> String {
    format!("env-1:{thread}")
}

/// A hub on `env-1` (online) with project p1 "Shop" at /work/shop and the
/// threads `(id, title)` in it.
fn hub(threads: &[(&str, &str)]) -> (Hub, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("a cache directory");
    let hub = Hub::with(Launch {
        mc_origin: Some("http://127.0.0.1:1".into()),
        cache_dir: Some(dir.path().to_owned()),
        ..Launch::default()
    });
    hub.mc.set_ready(&hub.engine, true);
    shell(&hub, threads);
    (hub, dir)
}

fn shell(hub: &Hub, threads: &[(&str, &str)]) {
    let mut rows = vec![json!(["a", "p1", "project", {"id": "p1", "title": PROJECT,
        "workspaceRoot": "/work/shop", "createdAt": AT, "updatedAt": AT}])];
    rows.extend(threads.iter().map(|(id, title)| {
        json!(["a", id, "thread", {"id": id, "projectId": "p1", "title": title,
            "createdAt": AT, "updatedAt": AT,
            "modelSelection": {"instanceId": "claude", "model": "m"}}])
    }));
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
            "environment": {"environmentId": "env-1", "label": "Laptop"}}],
            "rows": rows}),
    );
}

pub(crate) fn object(hub: &Hub) -> ObjectId {
    hub.engine
        .singleton::<PaletteObject>()
        .expect("PaletteModel")
}

/// Calls `PaletteModel.<name>(args)` as the brick does.
pub(crate) fn invoke(hub: &Hub, name: &str, args: &[Value]) -> Value {
    call(&hub.engine, object(hub), name, args)
}

/// Types `query` into the field.
pub(crate) fn type_query(hub: &Hub, query: &str) {
    hub.engine
        .write_by_name(object(hub), "query", Value::String(Atom::from(query)))
        .expect("query is writable");
}

pub(crate) fn prop(hub: &Hub, name: &str) -> Value {
    hub.engine.read_by_name(object(hub), name)
}

pub(crate) fn prop_text(hub: &Hub, name: &str) -> String {
    match prop(hub, name) {
        Value::String(s) => s.as_str().to_owned(),
        other => panic!("{name} is {other:?}"),
    }
}

pub(crate) fn role(engine: &Engine, obj: ObjectId, row: usize, role: &str) -> String {
    let model = engine.object_model(obj).expect("a model");
    match model.data(engine, row, role) {
        Value::String(s) => s.as_str().to_owned(),
        Value::Bool(b) => b.to_string(),
        other => format!("{other:?}"),
    }
}

fn row_count(hub: &Hub) -> usize {
    hub.engine
        .object_model(object(hub))
        .expect("a model")
        .row_count()
}

fn titles(engine: &Engine, obj: ObjectId) -> Vec<String> {
    let count = engine.object_model(obj).expect("a model").row_count();
    (0..count)
        .map(|row| role(engine, obj, row, "title"))
        .collect()
}

/// The row of the entry `kind` `id`.
fn index_of(hub: &Hub, kind: &str, id: &str) -> Option<usize> {
    hub.with_controller::<Palette, _>(|c, _| {
        (0..c.count()).find(|&row| c.kind_at(row) == kind && c.id_at(row) == id)
    })
    .map(|row| row as usize)
}

/// Answers every message search waiting, oldest first: `t` found by
/// `messages` when they contain the query.
fn answer_messages(hub: &Hub, messages: &[(&str, &str)]) {
    while let Some(index) = hub.mc.pending(MESSAGES) {
        let query = hub.mc.calls.borrow()[index].2["query"]
            .as_str()
            .unwrap_or_default()
            .to_lowercase();
        let matches: Vec<Json> = messages
            .iter()
            .filter(|(_, said)| said.contains(&query))
            .map(|(thread, said)| json!({"threadId": thread, "snippet": said}))
            .collect();
        hub.mc
            .reply(&hub.engine, index, Ok(json!({"matches": matches})));
    }
}

pub(crate) fn open_thread(hub: &Hub, thread: &str) {
    let route = Route::Thread(key(thread));
    hub.with_controller::<Navigation, _>(|n, engine| n.open(engine, route));
}

// -- What tst_KeysPaletteProp found ------------------------------------------

/// Opening it again read rows whose entries had gone: what reads the rows
/// as it opens reads the rows it lists.
#[test]
fn reopening_reads_the_rows_it_has() {
    let (hub, _dir) = hub(&[("t1", "Login")]);
    invoke(&hub, "show", &[]);
    let obj = object(&hub);
    let listed = titles(&hub.engine, obj);
    assert!(!listed.is_empty());
    invoke(&hub, "dismiss", &[]);

    let read: Rc<RefCell<Vec<Vec<String>>>> = Rc::default();
    let on_open = read.clone();
    hub.engine
        .connect_by_name(obj, "openChanged", move |engine, _| {
            on_open.borrow_mut().push(titles(engine, obj));
        })
        .expect("openChanged");
    let on_change = read.clone();
    let model = hub.engine.object_model(obj).expect("a model");
    model.subscribe(Rc::new(move |engine, _| {
        on_change.borrow_mut().push(titles(engine, obj));
    }));
    invoke(&hub, "show", &[]);
    let read = read.borrow();
    assert!(!read.is_empty());
    assert!(
        read.iter()
            .all(|titles| !titles.iter().any(|t| t == "Undefined"))
    );
    assert_eq!(read[0], listed);
}

/// A thread found by its title once its messages no longer count showed
/// the snippet until something else repainted it.
#[test]
fn a_row_that_stays_repaints_when_it_changes() {
    let (hub, _dir) = hub(&[("t1", "Login")]);
    invoke(&hub, "show", &[]);
    type_query(&hub, "slow");
    hub.advance(SEARCH_DELAY_MS);
    answer_messages(&hub, &[("t1", "slow login")]);
    let row = index_of(&hub, "thread", &key("t1")).expect("found by its messages");
    let obj = object(&hub);
    assert_eq!(role(&hub.engine, obj, row, "description"), "slow login");

    let changes: Rc<RefCell<Vec<ModelChange>>> = Rc::default();
    let seen = changes.clone();
    hub.engine
        .object_model(obj)
        .expect("a model")
        .subscribe(Rc::new(move |_, change| {
            seen.borrow_mut().push(change.clone())
        }));
    type_query(&hub, "login");
    assert_eq!(index_of(&hub, "thread", &key("t1")), Some(row));
    assert_eq!(role(&hub.engine, obj, row, "description"), PROJECT);
    let repainted = changes.borrow().iter().any(|change| match *change {
        ModelChange::DataChanged { first, count, .. }
        | ModelChange::RowsInserted { first, count } => first <= row && row < first + count,
        _ => false,
    });
    assert!(repainted, "{:?}", changes.borrow());
}

/// Opening it again said the highlight changed when it stayed on the first
/// row.
#[test]
fn reopening_keeps_an_unmoved_highlight_quiet() {
    let (hub, _dir) = hub(&[("t1", "Login")]);
    invoke(&hub, "show", &[]);
    assert_eq!(prop(&hub, "highlighted").to_number(), 0.0);
    let changed = Rc::new(RefCell::new(0));
    let count = changed.clone();
    hub.engine
        .connect_by_name(object(&hub), "highlightedChanged", move |_, _| {
            *count.borrow_mut() += 1;
        })
        .expect("highlightedChanged");
    invoke(&hub, "show", &[]);
    assert_eq!(prop(&hub, "highlighted").to_number(), 0.0);
    assert_eq!(*changed.borrow(), 0);
}

// -- Command mode -------------------------------------------------------------

#[test]
fn its_toggle_opens_and_closes_it_and_holds_the_thread_keys_meanwhile() {
    let (hub, _dir) = hub(&[("t1", "Login")]);
    hub.dispatch(palette::TOGGLE, Json::Null);
    assert_eq!(prop(&hub, "open"), Value::Bool(true));
    assert_eq!(prop_text(&hub, "mode"), "command");
    assert_eq!(
        prop_text(&hub, "placeholder"),
        "Search commands, projects, and threads..."
    );
    // Its own toggle is never listed; the hand-picked actions and recent
    // threads are.
    assert!(index_of(&hub, "action", palette::TOGGLE).is_none());
    assert!(index_of(&hub, "thread", &key("t1")).is_some());
    assert_eq!(role(&hub.engine, object(&hub), 0, "group"), "Actions");
    // Open, it keeps the keys but its own and the window's.
    let chrome = Focus::default();
    let keymap = Keymap::of(&hub.engine);
    assert_eq!(keymap.resolve(&hub.engine, "Ctrl+[", chrome), "");
    hub.dispatch(palette::TOGGLE, Json::Null);
    assert_eq!(prop(&hub, "open"), Value::Bool(false));
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+[", chrome),
        "navigation.back"
    );
}

#[test]
fn a_query_ranks_titles_first_and_a_leading_angle_keeps_to_actions() {
    let (hub, _dir) = hub(&[("t1", "Login"), ("t2", "Alpha draft")]);
    let commands = Commands::of(&hub.engine);
    commands.add(&hub.engine, "test.alpha", "Alpha task", |_| {});
    commands.add(&hub.engine, "test.run", "Run alpha", |_| {});
    invoke(&hub, "show", &[]);
    type_query(&hub, "alpha");
    let alpha = index_of(&hub, "action", "test.alpha").expect("listed");
    let run = index_of(&hub, "action", "test.run").expect("listed");
    assert!(
        alpha < run,
        "a title that starts with the query comes first"
    );
    assert!(index_of(&hub, "thread", &key("t2")).is_some());
    assert_eq!(role(&hub.engine, object(&hub), alpha, "group"), "Actions");

    type_query(&hub, ">alpha");
    assert!(index_of(&hub, "action", "test.alpha").is_some());
    assert!(index_of(&hub, "thread", &key("t2")).is_none());

    type_query(&hub, "zzzz");
    assert_eq!(row_count(&hub), 0);
    assert_eq!(prop_text(&hub, "emptyText"), "Searching thread messages…");
    hub.advance(SEARCH_DELAY_MS);
    answer_messages(&hub, &[]);
    assert_eq!(
        prop_text(&hub, "emptyText"),
        "No matching commands, projects, or threads."
    );
}

#[test]
fn running_a_thread_opens_it_and_marks_it_current() {
    let (hub, _dir) = hub(&[("t1", "Login"), ("t2", "Cart")]);
    invoke(&hub, "show", &[]);
    type_query(&hub, "cart");
    let row = index_of(&hub, "thread", &key("t2")).expect("listed");
    assert_eq!(
        invoke(&hub, "run", &[Value::Int(row as i32)]),
        Value::Bool(true)
    );
    assert_eq!(prop(&hub, "open"), Value::Bool(false));
    assert_eq!(hub.published("route")["kind"], "thread");
    invoke(&hub, "show", &[]);
    type_query(&hub, "cart");
    let row = index_of(&hub, "thread", &key("t2")).expect("listed");
    assert_eq!(
        role(&hub.engine, object(&hub), row, "description"),
        "Shop · Current thread"
    );
}

#[test]
fn a_command_that_fails_says_so() {
    let (hub, _dir) = hub(&[]);
    let throws = js_value(&hub.engine, "(function () { throw new Error(\"no\") })");
    Commands::of(&hub.engine).add_js(&hub.engine, "test.fails", "Fails", throws, None);
    invoke(&hub, "show", &[]);
    type_query(&hub, "fails");
    let row = index_of(&hub, "action", "test.fails").expect("listed");
    assert_eq!(
        invoke(&hub, "run", &[Value::Int(row as i32)]),
        Value::Bool(true)
    );
    let toasts = hub.published("toasts");
    let toast = &toasts["items"][0];
    assert_eq!(toast["title"], "Unable to run command");
    assert_eq!(toast["description"], "no");
}

#[test]
fn a_menu_opens_its_choices_and_backspace_leaves_it() {
    let (hub, _dir) = hub(&[]);
    let picked: Rc<RefCell<Vec<String>>> = Rc::default();
    let log = picked.clone();
    Commands::of(&hub.engine).add_menu(&hub.engine, "test.menu", "Pick one", move |_| {
        let mut choices = Vec::new();
        for (id, title) in [("a", "First"), ("b", "Second")] {
            let log = log.clone();
            let mut choice = Choice::new(id, title, move |_| log.borrow_mut().push(id.into()));
            choice.current = id == "b";
            choices.push(choice);
        }
        choices
    });
    invoke(&hub, "show", &[]);
    type_query(&hub, "pick");
    let row = index_of(&hub, "action", "test.menu").expect("listed");
    assert_eq!(
        invoke(&hub, "run", &[Value::Int(row as i32)]),
        Value::Bool(true)
    );
    assert_eq!(prop_text(&hub, "submenu"), "Pick one");
    assert_eq!(prop_text(&hub, "query"), "");
    assert_eq!(prop_text(&hub, "placeholder"), "Search...");
    // The choice in effect is where the highlight starts.
    assert_eq!(prop(&hub, "highlighted").to_number(), 1.0);
    assert_eq!(role(&hub.engine, object(&hub), 1, "current"), "true");
    assert_eq!(invoke(&hub, "leaveSubmenu", &[]), Value::Bool(true));
    assert_eq!(prop_text(&hub, "submenu"), "");
    assert_eq!(invoke(&hub, "leaveSubmenu", &[]), Value::Bool(false));

    // Running the menu command opens the palette on it.
    invoke(&hub, "dismiss", &[]);
    Commands::of(&hub.engine).run(&hub.engine, "test.menu");
    assert_eq!(prop(&hub, "open"), Value::Bool(true));
    assert_eq!(prop_text(&hub, "submenu"), "Pick one");
    assert_eq!(invoke(&hub, "runHighlighted", &[]), Value::Bool(true));
    assert_eq!(*picked.borrow(), ["b"]);
    assert_eq!(prop(&hub, "open"), Value::Bool(false));
}

#[test]
fn escape_goes_back_a_level_before_it_dismisses() {
    let (hub, _dir) = hub(&[("t1", "Login")]);
    open_thread(&hub, "t1");
    hub.dispatch(palette::FILES, Json::Null);
    assert_eq!(prop_text(&hub, "mode"), "files");
    invoke(&hub, "back", &[]);
    assert_eq!(prop_text(&hub, "mode"), "command");
    assert_eq!(prop(&hub, "open"), Value::Bool(true));
    invoke(&hub, "back", &[]);
    assert_eq!(prop(&hub, "open"), Value::Bool(false));
}

#[test]
fn offline_environments_are_named_as_not_searched() {
    let (hub, _dir) = hub(&[("t1", "Login")]);
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [
            {"mc": "a", "online": true, "epoch": "e", "rev": 2,
             "environment": {"environmentId": "env-1", "label": "Laptop"}},
            {"mc": "b", "online": false, "epoch": "e", "rev": 1,
             "environment": {"environmentId": "env-2", "label": "Desk"}}],
            "rows": []}),
    );
    invoke(&hub, "show", &[]);
    type_query(&hub, "lo");
    assert_eq!(prop_text(&hub, "status"), "Not searched (offline): Desk");
    hub.advance(SEARCH_DELAY_MS);
    // Only the online environment is asked.
    let asked: Vec<String> = hub
        .mc
        .calls
        .borrow()
        .iter()
        .filter(|c| c.1 == MESSAGES)
        .map(|c| c.0.clone())
        .collect();
    assert_eq!(asked, ["env-1"]);
}

/// Only the newest message search counts: an answer for a query the user
/// typed past is dropped.
#[test]
fn a_late_answer_for_an_old_query_is_dropped() {
    let (hub, _dir) = hub(&[("t1", "Login"), ("t2", "Cart")]);
    invoke(&hub, "show", &[]);
    type_query(&hub, "slow");
    hub.advance(SEARCH_DELAY_MS);
    let old = hub.mc.pending(MESSAGES).expect("asked");
    type_query(&hub, "beta");
    hub.advance(SEARCH_DELAY_MS);
    hub.mc.reply(
        &hub.engine,
        old,
        Ok(json!({"matches": [{"threadId": "t1", "snippet": "slow login"}]})),
    );
    assert!(index_of(&hub, "thread", &key("t1")).is_none());
    answer_messages(&hub, &[("t2", "beta notes")]);
    let row = index_of(&hub, "thread", &key("t2")).expect("found by its messages");
    assert_eq!(
        role(&hub.engine, object(&hub), row, "description"),
        "beta notes"
    );
}

// -- Files and content ---------------------------------------------------------

#[test]
fn files_are_searched_in_the_route_threads_project_and_open_in_the_panel() {
    let (hub, _dir) = hub(&[("t1", "Login")]);
    hub.dispatch(palette::FILES, Json::Null);
    assert_eq!(
        prop_text(&hub, "emptyText"),
        "Open a project to search its files."
    );
    invoke(&hub, "dismiss", &[]);

    open_thread(&hub, "t1");
    hub.dispatch(palette::FILES, Json::Null);
    assert_eq!(prop_text(&hub, "placeholder"), "Search files…");
    assert_eq!(prop_text(&hub, "emptyText"), "Searching workspace files…");
    type_query(&hub, " app ");
    hub.advance(SEARCH_DELAY_MS);
    let index = hub.mc.pending("projects.searchEntries").expect("asked");
    let call = hub.mc.calls.borrow()[index].clone();
    assert_eq!(call.0, "env-1");
    assert_eq!(
        call.2,
        json!({"cwd": "/work/shop", "query": "app", "limit": 200, "kind": "file"})
    );
    hub.mc.reply(
        &hub.engine,
        index,
        Ok(json!({"entries": [{"path": "src/app.rs"}, {"path": "app.toml"}]})),
    );
    let obj = object(&hub);
    assert_eq!(titles(&hub.engine, obj), ["app.rs", "app.toml"]);
    assert_eq!(role(&hub.engine, obj, 0, "description"), "src");
    assert_eq!(invoke(&hub, "runHighlighted", &[]), Value::Bool(true));
    assert_eq!(prop(&hub, "open"), Value::Bool(false));
    assert_eq!(hub.published("panel")["activeId"], "files");
}

#[test]
fn content_matches_are_grouped_by_file_and_counted() {
    let (hub, _dir) = hub(&[("t1", "Login")]);
    open_thread(&hub, "t1");
    hub.dispatch(palette::CONTENT, Json::Null);
    assert_eq!(prop_text(&hub, "placeholder"), "Search in Shop");
    assert_eq!(
        prop_text(&hub, "emptyText"),
        "Type to search across your project."
    );
    // An empty query asks nothing.
    hub.advance(SEARCH_DELAY_MS);
    assert!(hub.mc.pending("projects.searchContents").is_none());
    type_query(&hub, "todo");
    hub.engine
        .write_by_name(object(&hub), "caseSensitive", Value::Bool(true))
        .expect("caseSensitive is writable");
    assert_eq!(prop_text(&hub, "status"), "Searching…");
    hub.advance(SEARCH_DELAY_MS);
    let index = hub.mc.pending("projects.searchContents").expect("asked");
    assert_eq!(
        hub.mc.calls.borrow()[index].2,
        json!({"cwd": "/work/shop", "query": "todo", "limit": 500,
            "caseSensitive": true, "wholeWord": false, "useRegex": false})
    );
    hub.mc.reply(
        &hub.engine,
        index,
        Ok(json!({"truncated": true, "matches": [
            {"path": "a.rs", "lineNumber": 3, "lineContent": "  // todo one"},
            {"path": "b.rs", "lineNumber": 9, "lineContent": "todo two"},
            {"path": "a.rs", "lineNumber": 7, "lineContent": "todo three"}]})),
    );
    let obj = object(&hub);
    assert_eq!(
        titles(&hub.engine, obj),
        ["// todo one", "todo three", "todo two"]
    );
    assert_eq!(role(&hub.engine, obj, 1, "group"), "a.rs");
    assert_eq!(role(&hub.engine, obj, 1, "description"), "7");
    assert_eq!(prop_text(&hub, "status"), "3+ results in 2 files");
    assert_eq!(index_of(&hub, "match", "a.rs:7"), Some(1));
}

/// Another thread's project is another search: what was found goes.
#[test]
fn moving_to_another_project_starts_the_search_afresh() {
    let (hub, _dir) = hub(&[("t1", "Login")]);
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 2,
            "environment": {"environmentId": "env-1", "label": "Laptop"}}],
            "rows": [
                ["a", "p1", "project", {"id": "p1", "title": PROJECT, "workspaceRoot": "/work/shop",
                    "createdAt": AT, "updatedAt": AT}],
                ["a", "p2", "project", {"id": "p2", "title": "Blog", "workspaceRoot": "/work/blog",
                    "createdAt": AT, "updatedAt": AT}],
                ["a", "t1", "thread", {"id": "t1", "projectId": "p1", "title": "Login",
                    "createdAt": AT, "updatedAt": AT, "modelSelection": {"instanceId": "claude", "model": "m"}}],
                ["a", "t2", "thread", {"id": "t2", "projectId": "p2", "title": "Post",
                    "createdAt": AT, "updatedAt": AT, "modelSelection": {"instanceId": "claude", "model": "m"}}]]}),
    );
    open_thread(&hub, "t1");
    hub.dispatch(palette::FILES, Json::Null);
    type_query(&hub, "app");
    hub.advance(SEARCH_DELAY_MS);
    hub.mc.answer(
        &hub.engine,
        "projects.searchEntries",
        Ok(json!({"entries": [{"path": "app.rs"}]})),
    );
    assert_eq!(row_count(&hub), 1);
    open_thread(&hub, "t2");
    assert_eq!(row_count(&hub), 0);
    assert_eq!(prop_text(&hub, "query"), "");
    hub.advance(SEARCH_DELAY_MS);
    let index = hub
        .mc
        .pending("projects.searchEntries")
        .expect("asked again");
    assert_eq!(hub.mc.calls.borrow()[index].2["cwd"], "/work/blog");
}

// -- Browse and ask -------------------------------------------------------------

fn browsing(hub: &Hub, options: BrowseOptions) -> Rc<RefCell<Vec<String>>> {
    let added: Rc<RefCell<Vec<String>>> = Rc::default();
    let log = added.clone();
    palette::browse(
        &hub.engine,
        "env-1",
        move |_, path| log.borrow_mut().push(path.to_owned()),
        options,
    );
    added
}

#[test]
fn browsing_lists_folders_and_enter_adds_the_path_typed() {
    let (hub, _dir) = hub(&[]);
    let added = browsing(&hub, BrowseOptions::default());
    assert_eq!(prop_text(&hub, "mode"), "browse");
    assert_eq!(prop_text(&hub, "query"), "~/");
    assert_eq!(prop(&hub, "highlighted").to_number(), -1.0);
    hub.advance(SEARCH_DELAY_MS);
    let index = hub.mc.pending("filesystem.browse").expect("asked");
    assert_eq!(hub.mc.calls.borrow()[index].2, json!({"partialPath": "~/"}));
    hub.mc.reply(
        &hub.engine,
        index,
        Ok(json!({"parentPath": "/home/me", "entries": [
            {"name": "code", "fullPath": "/home/me/code"},
            {"name": ".config", "fullPath": "/home/me/.config"}]})),
    );
    let obj = object(&hub);
    assert_eq!(titles(&hub.engine, obj), ["..", "code", ".config"]);
    assert_eq!(index_of(&hub, "up", "/home/"), Some(0));
    assert_eq!(prop_text(&hub, "submitLabel"), "Add");

    // Choosing a folder goes into it.
    assert_eq!(invoke(&hub, "run", &[Value::Int(1)]), Value::Bool(true));
    assert_eq!(prop_text(&hub, "query"), "~/code/");

    // A name that is not there is created.
    type_query(&hub, "~/code/new");
    hub.advance(SEARCH_DELAY_MS);
    hub.mc.answer(
        &hub.engine,
        "filesystem.browse",
        Ok(json!({"parentPath": "/home/me/code", "entries": []})),
    );
    assert_eq!(prop_text(&hub, "submitLabel"), "Create & Add");
    assert_eq!(invoke(&hub, "runHighlighted", &[]), Value::Bool(true));
    assert_eq!(*added.borrow(), ["~/code/new"]);
    assert_eq!(prop(&hub, "open"), Value::Bool(false));
}

#[test]
fn a_relative_path_needs_a_project() {
    let (hub, _dir) = hub(&[]);
    let added = browsing(&hub, BrowseOptions::default());
    type_query(&hub, "code");
    assert_eq!(
        prop_text(&hub, "emptyText"),
        "Relative paths require an active project."
    );
    assert_eq!(prop_text(&hub, "submitLabel"), "");
    assert_eq!(invoke(&hub, "runHighlighted", &[]), Value::Bool(false));
    assert!(added.borrow().is_empty());
}

/// A clone's destination: the repository's name stays at the end of the
/// path, and the palette stays open until the clone starts.
#[test]
fn a_pinned_name_follows_the_folders_chosen_and_the_palette_waits() {
    let (hub, _dir) = hub(&[]);
    let added = browsing(
        &hub,
        BrowseOptions {
            query: "~/code/repo".into(),
            pinned: "repo".into(),
            empty_text: "Choose a destination path and press Enter to clone.".into(),
            submit: "Clone".into(),
            keep_open: true,
        },
    );
    hub.advance(SEARCH_DELAY_MS);
    let index = hub.mc.pending("filesystem.browse").expect("asked");
    // The whole folder is listed, filtered here.
    assert_eq!(
        hub.mc.calls.borrow()[index].2,
        json!({"partialPath": "~/code/"})
    );
    hub.mc.reply(
        &hub.engine,
        index,
        Ok(json!({"parentPath": "/home/me/code", "entries": [
            {"name": "work", "fullPath": "/home/me/code/work"}]})),
    );
    assert_eq!(titles(&hub.engine, object(&hub)), ["..", "work"]);
    assert_eq!(invoke(&hub, "run", &[Value::Int(1)]), Value::Bool(true));
    assert_eq!(prop_text(&hub, "query"), "~/code/work/repo");
    assert_eq!(prop_text(&hub, "submitLabel"), "Clone");
    assert_eq!(invoke(&hub, "runHighlighted", &[]), Value::Bool(true));
    assert_eq!(*added.borrow(), ["~/code/work/repo"]);
    assert_eq!(prop(&hub, "open"), Value::Bool(true));
    palette::finish(&hub.engine);
    assert_eq!(prop(&hub, "open"), Value::Bool(false));
}

#[test]
fn asking_hands_the_trimmed_text_on_and_stays_open() {
    let (hub, _dir) = hub(&[]);
    let given: Rc<RefCell<Vec<String>>> = Rc::default();
    let log = given.clone();
    palette::ask(
        &hub.engine,
        "Git URL",
        "Enter Git clone URL",
        "Enter a Git clone URL and press Enter to continue.",
        move |_, text| log.borrow_mut().push(text.to_owned()),
    );
    assert_eq!(prop_text(&hub, "mode"), "ask");
    assert_eq!(prop_text(&hub, "submenu"), "Git URL");
    assert_eq!(prop_text(&hub, "placeholder"), "Enter Git clone URL");
    assert_eq!(
        prop_text(&hub, "emptyText"),
        "Enter a Git clone URL and press Enter to continue."
    );
    assert_eq!(invoke(&hub, "runHighlighted", &[]), Value::Bool(false));
    type_query(&hub, "  https://example.com/a.git ");
    assert_eq!(row_count(&hub), 0);
    assert_eq!(invoke(&hub, "runHighlighted", &[]), Value::Bool(true));
    assert_eq!(*given.borrow(), ["https://example.com/a.git"]);
    assert_eq!(prop(&hub, "open"), Value::Bool(true));
    invoke(&hub, "back", &[]);
    assert_eq!(prop_text(&hub, "mode"), "command");
}

/// Add project's Local folder browses the environment's folders.
#[test]
fn add_projects_local_folder_browses() {
    let (hub, _dir) = hub(&[]);
    Commands::of(&hub.engine).run(&hub.engine, "project.add");
    assert_eq!(prop(&hub, "open"), Value::Bool(true));
    let row = index_of(&hub, "choice", "local-folder").expect("offered");
    assert_eq!(
        invoke(&hub, "run", &[Value::Int(row as i32)]),
        Value::Bool(true)
    );
    assert_eq!(prop_text(&hub, "mode"), "browse");
    assert_eq!(prop_text(&hub, "submitLabel"), "Add");
}

// -- The model, as a state machine ---------------------------------------------

const COMMANDS: [&str; 3] = ["test.one", "test.two", "test.three"];
const TITLES: [&str; 4] = ["Alpha task", "Beta", "Run alpha", "Slow"];
const THREADS: [&str; 4] = ["t1", "t2", "t3", "t4"];
/// What each thread's messages say; t4 arrives later.
const SAID: [(&str, &str); 4] = [
    ("t1", "slow login"),
    ("t2", "beta notes"),
    ("t3", "the alpha bug"),
    ("t4", "alpha beta"),
];
const THREAD_TITLES: [&str; 4] = ["Login", "Alpha draft", "Cart", "Checkout"];
const QUERIES: [&str; 14] = [
    "", "a", "al", "alpha", "be", "lo", "slow", "test", ">al", ">", "t1", "zz", "alpha b", "login",
];

fn said(thread: &str) -> &'static str {
    SAID.iter()
        .find(|(t, _)| *t == thread)
        .map_or("", |(_, s)| *s)
}

fn normalized(text: &str) -> String {
    text.to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn has_all(haystack: &str, tokens: &[String]) -> bool {
    tokens.iter().all(|t| haystack.contains(t.as_str()))
}

#[derive(Clone, Debug)]
enum Op {
    Show,
    Toggle,
    /// Escape, or Dismiss: with no submenu both close it.
    Close {
        escape: bool,
    },
    Type(&'static str),
    /// Moves the highlight, or sets it anywhere.
    Move {
        delta: i32,
        set: bool,
    },
    /// The MC holds its message searches back.
    Hold,
    /// The MC answers every search it held, the newest last.
    Answer,
    Add {
        id: &'static str,
        title: &'static str,
    },
    Remove(&'static str),
    Retitle {
        id: &'static str,
        title: &'static str,
    },
    Enable {
        id: &'static str,
        enabled: bool,
    },
    /// A thread arrives, or one is renamed.
    ThreadRow {
        id: &'static str,
        title: &'static str,
    },
    /// Enter on a test command or a thread where it is listed, else past the
    /// end.
    Run {
        thread: bool,
        id: &'static str,
    },
}

fn op() -> impl Strategy<Value = Op> {
    let command = proptest::sample::select(&COMMANDS[..]);
    let title = proptest::sample::select(&TITLES[..]);
    prop_oneof![
        2 => Just(Op::Show),
        1 => Just(Op::Toggle),
        1 => any::<bool>().prop_map(|escape| Op::Close { escape }),
        6 => proptest::sample::select(&QUERIES[..]).prop_map(Op::Type),
        2 => (-3i32..4, any::<bool>()).prop_map(|(delta, set)| Op::Move { delta, set }),
        1 => Just(Op::Hold),
        2 => Just(Op::Answer),
        2 => (command.clone(), title.clone()).prop_map(|(id, title)| Op::Add { id, title }),
        1 => command.clone().prop_map(Op::Remove),
        1 => (command.clone(), title).prop_map(|(id, title)| Op::Retitle { id, title }),
        1 => (command.clone(), any::<bool>()).prop_map(|(id, enabled)| Op::Enable { id, enabled }),
        1 => (
            proptest::sample::select(&THREADS[..]),
            proptest::sample::select(&THREAD_TITLES[..])
        )
            .prop_map(|(id, title)| Op::ThreadRow { id, title }),
        2 => prop_oneof![
            command.prop_map(|id| Op::Run { thread: false, id }),
            proptest::sample::select(&THREADS[..]).prop_map(|id| Op::Run { thread: true, id }),
        ],
    ]
}

#[derive(Clone, Debug)]
struct Command {
    title: String,
    enabled: bool,
}

#[derive(Clone, Debug, Default)]
struct Model {
    open: bool,
    query: String,
    commands: BTreeMap<String, Command>,
    threads: BTreeMap<String, String>,
    holding: bool,
    /// The normalized query the newest message search was sent for, whether
    /// its answer is in, and the threads it named.
    sent: String,
    answered: bool,
    matched: BTreeSet<String>,
    searches: usize,
    ran: Vec<String>,
    route: Option<String>,
}

impl Model {
    fn actions_only(&self) -> bool {
        self.query.starts_with('>')
    }

    fn tokens(&self) -> Vec<String> {
        let query = if self.actions_only() {
            &self.query[1..]
        } else {
            &self.query
        };
        normalized(query)
            .split(' ')
            .filter(|t| !t.is_empty())
            .map(String::from)
            .collect()
    }

    fn answer(&mut self) {
        self.answered = true;
        self.matched = self
            .threads
            .keys()
            .filter(|t| said(t).contains(self.sent.as_str()))
            .cloned()
            .collect();
    }

    /// The palette's generation moves on: no answer on its way counts.
    fn forget(&mut self) {
        self.sent.clear();
        self.answered = false;
        self.matched.clear();
    }

    fn show(&mut self) {
        self.open = true;
        self.query.clear();
        self.forget();
    }

    fn close(&mut self) {
        self.open = false;
        self.forget();
    }

    fn set_query(&mut self, next: &str) {
        if next == self.query {
            return;
        }
        self.query = next.to_owned();
        if !self.open {
            return;
        }
        self.forget();
        if !self.actions_only() && normalized(&self.query).chars().count() >= 2 {
            self.sent = normalized(&self.query);
            self.searches += 1;
            if !self.holding {
                self.answer();
            }
        }
    }

    /// Whether the palette lists the test's command `id`.
    fn lists(&self, id: &str) -> bool {
        let tokens = self.tokens();
        let Some(command) = self.commands.get(id) else {
            return false;
        };
        self.open
            && !tokens.is_empty()
            && has_all(&format!("{} {id}", normalized(&command.title)), &tokens)
    }

    /// Whether it lists the thread, and with what description.
    fn thread(&self, id: &str) -> Option<String> {
        if !self.open || self.actions_only() {
            return None;
        }
        let title = self.threads.get(id)?;
        let mut description = PROJECT.to_owned();
        if self.route.as_deref() == Some(key(id).as_str()) {
            description += " · Current thread";
        }
        let tokens = self.tokens();
        let haystack = format!("{} {} {id}", normalized(title), normalized(PROJECT));
        if tokens.is_empty() || has_all(&haystack, &tokens) {
            return Some(description);
        }
        if self.answered && self.sent == normalized(&self.query) && self.matched.contains(id) {
            return Some(said(id).to_owned());
        }
        None
    }
}

/// What a row shows, read from the model's roles.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Shown {
    title: String,
    description: String,
    group: String,
    kind: String,
    runnable: String,
}

fn read_row(engine: &Engine, obj: ObjectId, row: usize) -> Shown {
    Shown {
        title: role(engine, obj, row, "title"),
        description: role(engine, obj, row, "description"),
        group: role(engine, obj, row, "group"),
        kind: role(engine, obj, row, "kind"),
        runnable: role(engine, obj, row, "runnable"),
    }
}

pub(crate) fn read_rows(engine: &Engine, obj: ObjectId) -> Vec<Shown> {
    let count = engine.object_model(obj).expect("a model").row_count();
    (0..count).map(|row| read_row(engine, obj, row)).collect()
}

/// The list as a view keeps it, from the row signals alone, and what went
/// wrong inside a signal.
#[derive(Default)]
pub(crate) struct Mirror {
    pub(crate) rows: Vec<Shown>,
    pub(crate) faults: Vec<String>,
}

impl Mirror {
    /// Rows outside `range` (indices now, `shift` rows after it) read as the
    /// mirror has them.
    pub(crate) fn unmoved(
        &mut self,
        engine: &Engine,
        obj: ObjectId,
        signal: &str,
        range: (usize, usize),
        shift: isize,
    ) {
        let count = engine.object_model(obj).expect("a model").row_count();
        for row in 0..count {
            if row >= range.0 && row < range.1 {
                continue;
            }
            let was = if row >= range.1 {
                row as isize - shift
            } else {
                row as isize
            };
            let Some(was) = usize::try_from(was).ok().and_then(|w| self.rows.get(w)) else {
                continue;
            };
            let now = read_row(engine, obj, row);
            if &now != was {
                self.faults.push(format!(
                    "{signal}: row {row} read {}, not {}",
                    now.title, was.title
                ));
            }
        }
    }

    pub(crate) fn on(&mut self, engine: &Engine, obj: ObjectId, change: &ModelChange) {
        match *change {
            ModelChange::RowsAboutToBeInserted { .. }
            | ModelChange::RowsAboutToBeRemoved { .. } => {
                self.unmoved(engine, obj, "about to", (0, 0), 0);
            }
            ModelChange::RowsInserted { first, count } => {
                self.unmoved(
                    engine,
                    obj,
                    "rowsInserted",
                    (first, first + count),
                    count as isize,
                );
                for row in first..first + count {
                    self.rows.insert(row, read_row(engine, obj, row));
                }
            }
            ModelChange::RowsRemoved { first, count } => {
                self.rows.drain(first..first + count);
                self.unmoved(engine, obj, "rowsRemoved", (0, 0), 0);
            }
            ModelChange::DataChanged { first, count, .. } => {
                self.unmoved(engine, obj, "dataChanged", (first, first + count), 0);
                for row in first..first + count {
                    self.rows[row] = read_row(engine, obj, row);
                }
            }
            _ => self.rows = read_rows(engine, obj),
        }
    }
}

struct World {
    hub: Hub,
    _dir: tempfile::TempDir,
    obj: ObjectId,
    model: Model,
    mirror: Rc<RefCell<Mirror>>,
    ran: Rc<RefCell<Vec<String>>>,
    /// The threads the MC has, with their titles.
    threads: BTreeMap<&'static str, &'static str>,
    /// What notified for no change.
    quiet: Rc<RefCell<Vec<String>>>,
    /// A write from QML is under way: one the palette clamps notifies for
    /// no change (palette.rs `on_write`).
    writing: Rc<Cell<bool>>,
    holding: bool,
}

impl World {
    fn new() -> World {
        let threads: BTreeMap<_, _> = THREADS[..3]
            .iter()
            .copied()
            .zip(THREAD_TITLES.iter().copied())
            .collect();
        let rows: Vec<(&str, &str)> = threads.iter().map(|(k, v)| (*k, *v)).collect();
        let (hub, dir) = hub(&rows);
        let obj = object(&hub);
        let mirror = Rc::new(RefCell::new(Mirror {
            rows: read_rows(&hub.engine, obj),
            faults: Vec::new(),
        }));
        let follow = mirror.clone();
        hub.engine
            .object_model(obj)
            .expect("a model")
            .subscribe(Rc::new(move |engine, change| {
                follow.borrow_mut().on(engine, obj, change);
            }));
        let quiet: Rc<RefCell<Vec<String>>> = Rc::default();
        let writing: Rc<Cell<bool>> = Rc::default();
        for name in ["open", "query", "highlighted", "mode", "count"] {
            let last = Rc::new(RefCell::new(hub.engine.read_by_name(obj, name)));
            let quiet = quiet.clone();
            let writing = writing.clone();
            let mirror = mirror.clone();
            hub.engine
                .connect_by_name(obj, &format!("{name}Changed"), move |engine, _| {
                    // What QML binds to reads the rows as they stand.
                    mirror.borrow_mut().unmoved(engine, obj, name, (0, 0), 0);
                    let now = engine.read_by_name(obj, name);
                    if *last.borrow() == now && !writing.get() {
                        quiet
                            .borrow_mut()
                            .push(format!("{name}Changed for no change"));
                    }
                    *last.borrow_mut() = now;
                })
                .expect("a notify signal");
        }
        let model = Model {
            threads: threads
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
                .collect(),
            ..Model::default()
        };
        World {
            hub,
            _dir: dir,
            obj,
            model,
            mirror,
            ran: Rc::default(),
            threads,
            quiet,
            writing,
            holding: false,
        }
    }

    fn palette<R>(&self, f: impl FnOnce(&mut Palette, &Engine) -> R) -> R {
        self.hub.with_controller::<Palette, _>(|c, engine| {
            let r = f(c, engine);
            c.sync(engine);
            r
        })
    }

    fn searches(&self) -> usize {
        self.hub
            .mc
            .calls
            .borrow()
            .iter()
            .filter(|c| c.1 == MESSAGES)
            .count()
    }

    fn answer(&self) {
        answer_messages(&self.hub, &SAID);
    }

    fn step(&mut self, op: Op) {
        let commands = Commands::of(&self.hub.engine);
        let engine = &self.hub.engine;
        match op {
            Op::Show => {
                self.model.show();
                invoke(&self.hub, "show", &[]);
            }
            Op::Toggle => {
                if self.model.open {
                    self.model.close();
                } else {
                    self.model.show();
                }
                invoke(&self.hub, "toggle", &[]);
            }
            Op::Close { escape } => {
                if self.model.open {
                    self.model.close();
                }
                invoke(&self.hub, if escape { "back" } else { "dismiss" }, &[]);
            }
            Op::Type(query) => {
                self.model.set_query(query);
                type_query(&self.hub, query);
            }
            Op::Move { delta, set } => {
                if set {
                    self.writing.set(true);
                    let written =
                        engine.write_by_name(self.obj, "highlighted", Value::Int(delta * 7));
                    self.writing.set(false);
                    written.expect("highlighted is writable");
                } else {
                    invoke(&self.hub, "move", &[Value::Int(delta)]);
                }
            }
            Op::Hold => {
                self.model.holding = true;
                self.holding = true;
            }
            Op::Answer => {
                self.model.holding = false;
                if !self.model.sent.is_empty() && !self.model.answered {
                    self.model.answer();
                }
                self.holding = false;
                self.answer();
            }
            Op::Add { id, title } => {
                if self.model.commands.contains_key(id) {
                    return;
                }
                self.model.commands.insert(
                    id.to_owned(),
                    Command {
                        title: title.to_owned(),
                        enabled: true,
                    },
                );
                let ran = self.ran.clone();
                commands.add(engine, id, title, move |_| {
                    ran.borrow_mut().push(id.to_owned())
                });
            }
            Op::Remove(id) => {
                if self.model.commands.remove(id).is_none() {
                    return;
                }
                commands.remove(engine, id);
            }
            Op::Retitle { id, title } => {
                let Some(command) = self.model.commands.get_mut(id) else {
                    return;
                };
                command.title = title.to_owned();
                commands.set_title(engine, id, title);
            }
            Op::Enable { id, enabled } => {
                let Some(command) = self.model.commands.get_mut(id) else {
                    return;
                };
                command.enabled = enabled;
                commands.set_enabled(engine, id, enabled);
            }
            Op::ThreadRow { id, title } => {
                self.model.threads.insert(id.to_owned(), title.to_owned());
                self.threads.insert(id, title);
                let rows: Vec<(&str, &str)> = self.threads.iter().map(|(k, v)| (*k, *v)).collect();
                shell(&self.hub, &rows);
            }
            Op::Run { thread, id } => {
                let (kind, entry) = if thread {
                    ("thread", key(id))
                } else {
                    ("action", id.to_owned())
                };
                let listed = if thread {
                    self.model.thread(id).is_some()
                } else {
                    self.model.lists(id)
                };
                let runs = listed && (thread || self.model.commands[id].enabled);
                if listed {
                    if thread {
                        self.model.route = Some(key(id));
                    } else if runs {
                        self.model.ran.push(id.to_owned());
                    }
                    if runs {
                        self.model.close();
                    }
                }
                let row = index_of(&self.hub, kind, &entry);
                let past_the_end = self.palette(|c, _| c.count());
                let row = row.map_or(past_the_end, |r| r as i32);
                let ran = invoke(&self.hub, "run", &[Value::Int(row)]);
                assert_eq!(ran, Value::Bool(runs), "run {kind} {id}");
            }
        }
        // Typing pauses: the searches it asked for go out.
        self.hub.advance(SEARCH_DELAY_MS);
        if !self.holding {
            self.answer();
        }
    }

    fn check(&self) {
        let engine = &self.hub.engine;
        let model = &self.model;
        assert_eq!(self.mirror.borrow().faults, Vec::<String>::new());
        assert_eq!(*self.quiet.borrow(), Vec::<String>::new());
        assert_eq!(self.searches(), model.searches, "message searches");
        let rows = read_rows(engine, self.obj);
        assert_eq!(self.mirror.borrow().rows, rows, "the view's rows");
        assert_eq!(prop(&self.hub, "open"), Value::Bool(model.open));
        assert_eq!(prop_text(&self.hub, "query"), model.query);
        assert_eq!(prop(&self.hub, "count").to_number() as usize, rows.len());
        assert_eq!(*self.ran.borrow(), model.ran);
        let route = match self.hub.published("route") {
            r if r["kind"] == "thread" => r["threadKey"].as_str().map(String::from),
            _ => None,
        };
        if model.route.is_some() {
            assert_eq!(route, model.route, "the route");
        }
        if !model.open {
            return;
        }
        let highlighted = prop(&self.hub, "highlighted").to_number() as i64;
        if rows.is_empty() {
            assert_eq!(highlighted, 0);
        } else {
            assert!(
                (0..rows.len() as i64).contains(&highlighted),
                "highlight {highlighted}"
            );
        }
        for id in COMMANDS {
            let row = index_of(&self.hub, "action", id);
            assert_eq!(row.is_some(), model.lists(id), "{id} for {:?}", model.query);
            if let Some(row) = row {
                let command = &model.commands[id];
                assert_eq!(rows[row].title, command.title);
                assert_eq!(rows[row].runnable, command.enabled.to_string());
            }
        }
        for id in THREADS {
            let row = index_of(&self.hub, "thread", &key(id));
            let description = model.thread(id);
            assert_eq!(
                row.is_some(),
                description.is_some(),
                "{id} for {:?}",
                model.query
            );
            if let (Some(row), Some(description)) = (row, description) {
                assert_eq!(rows[row].title, model.threads[id]);
                assert_eq!(rows[row].description, description, "{id}");
            }
        }
        // Each entry is listed once.
        let entries: Vec<(String, String)> = self.palette(|c, _| {
            (0..c.count())
                .map(|row| (c.kind_at(row), c.id_at(row)))
                .collect()
        });
        let unique: BTreeSet<_> = entries.iter().collect();
        assert_eq!(unique.len(), entries.len());
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 48, ..ProptestConfig::default() })]

    #[test]
    fn the_palette_lists_what_the_model_says_and_its_views_keep_up(
        ops in proptest::collection::vec(op(), 1..40)
    ) {
        let mut world = World::new();
        // The route the shell starts on, if it is a thread.
        world.check();
        for op in ops {
            world.step(op);
            world.check();
        }
    }
}
