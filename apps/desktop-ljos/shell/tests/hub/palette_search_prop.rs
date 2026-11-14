//! The palette's searches against the MC as a state machine: files,
//! content and folders typed for faster than the MC answers, the answers
//! coming back in any order or failing, the route moving to another
//! project meanwhile, and Enter handing a browsed path or an asked line on.
//! Only the newest search's answer is listed, the spinner is on exactly
//! while one is on its way, and a view following the row signals keeps up.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::palette::{self, BrowseOptions, Palette, SEARCH_DELAY_MS};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use ljos::prelude::{ObjectId, Value};
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::palette::{
    AT, Mirror, invoke, object, open_thread, prop, prop_text, read_rows, role, type_query,
};

const ENTRIES: &str = "projects.searchEntries";
const CONTENTS: &str = "projects.searchContents";
const BROWSE: &str = "filesystem.browse";

/// The two projects' folders, by the thread shown in each.
const ROOTS: [(&str, &str); 2] = [("t1", "/work/shop"), ("t2", "/work/blog")];
const FILES: [&str; 4] = ["src/app.rs", "app.toml", "src/lib.rs", "docs/app.md"];
const LINES: [(&str, i64, &str); 4] = [
    ("a.rs", 3, "  // todo one"),
    ("b.rs", 9, "TODO two"),
    ("a.rs", 7, "todo three"),
    ("c.rs", 1, "done"),
];
const QUERIES: [&str; 14] = [
    "",
    "app",
    "src",
    "todo",
    "TODO",
    "zz",
    "  hi ",
    "code",
    "~/",
    "~/c",
    "~/code/",
    "~/code/s",
    "~/nowhere/",
    "/",
];

fn join(parent: &str, name: &str) -> String {
    if parent.ends_with('/') {
        format!("{parent}{name}")
    } else {
        format!("{parent}/{name}")
    }
}

/// What the fake MC finds for a search, from its payload alone.
fn found(method: &str, payload: &Json) -> Result<Json, McError> {
    let field = |key: &str| payload[key].as_str().unwrap_or_default().to_owned();
    match method {
        ENTRIES => {
            let query = field("query");
            let entries: Vec<Json> = FILES
                .iter()
                .filter(|path| path.contains(&query))
                .map(|path| json!({"path": path}))
                .collect();
            Ok(json!({"entries": entries}))
        }
        CONTENTS => {
            let query = field("query");
            let case = payload["caseSensitive"].as_bool().unwrap_or(false);
            let matches: Vec<Json> = LINES
                .iter()
                .filter(|(_, _, line)| {
                    if case {
                        line.contains(&query)
                    } else {
                        line.to_lowercase().contains(&query.to_lowercase())
                    }
                })
                .map(|(path, number, line)| {
                    json!({"path": path, "lineNumber": number, "lineContent": line})
                })
                .collect();
            Ok(json!({"matches": matches, "truncated": false}))
        }
        _ => {
            let path = field("partialPath");
            let (folder, leaf) = path.rfind('/').map_or(("", path.as_str()), |slash| {
                (&path[..=slash], &path[slash + 1..])
            });
            let cwd = field("cwd");
            let (parent, names): (&str, &[&str]) = match folder {
                "~/" => ("/home/me", &["code", "docs", ".config"]),
                "~/code/" => ("/home/me/code", &["shop", "blog"]),
                "/" => ("/", &["home"]),
                "" => (cwd.as_str(), &["src"]),
                _ => return Err(McError::new("No such folder")),
            };
            let entries: Vec<Json> = names
                .iter()
                .filter(|name| name.starts_with(leaf))
                .map(|name| json!({"name": name, "fullPath": join(parent, name)}))
                .collect();
            Ok(json!({"parentPath": parent, "entries": entries}))
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Mode {
    Closed,
    /// Back from a search: command mode, whose rows the other machine
    /// checks.
    Command,
    Files,
    Content,
    Browse,
    Ask,
}

#[derive(Clone, Debug)]
enum Op {
    /// The file finder's key: opens it, or closes it when it shows.
    Files,
    Content,
    /// Add project's Local folder, or a clone's destination kept open.
    Browse {
        keep_open: bool,
    },
    Ask,
    /// Escape.
    Back,
    Dismiss,
    Type(&'static str),
    CaseSensitive,
    /// Typing pauses: the search waiting goes out.
    Pause,
    /// The MC answers one of the searches still waiting, any of them.
    Answer {
        pick: usize,
        ok: bool,
    },
    Enter,
    /// Browse mode's mod+Enter.
    AddFolder,
    Move(i32),
    /// The window shows the thread of the first or the second project.
    Route {
        second: bool,
    },
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        2 => Just(Op::Files),
        2 => Just(Op::Content),
        2 => any::<bool>().prop_map(|keep_open| Op::Browse { keep_open }),
        1 => Just(Op::Ask),
        1 => Just(Op::Back),
        1 => Just(Op::Dismiss),
        // Typing, pausing and answering race each other most.
        8 => proptest::sample::select(&QUERIES[..]).prop_map(Op::Type),
        1 => Just(Op::CaseSensitive),
        6 => Just(Op::Pause),
        7 => (any::<usize>(), proptest::bool::weighted(0.8))
            .prop_map(|(pick, ok)| Op::Answer { pick, ok }),
        2 => Just(Op::Enter),
        1 => Just(Op::AddFolder),
        1 => (-2i32..3).prop_map(Op::Move),
        1 => any::<bool>().prop_map(|second| Op::Route { second }),
    ]
}

/// A row as the model has it: kind, id, title.
type Entry = (String, String, String);

fn entry(kind: &str, id: impl Into<String>, title: impl Into<String>) -> Entry {
    (kind.to_owned(), id.into(), title.into())
}

/// What the palette should show and have asked for.
struct Model {
    mode: Mode,
    query: String,
    case_sensitive: bool,
    keep_open: bool,
    root: &'static str,
    /// A search waits for typing to pause.
    scheduled: bool,
    /// The newest search, by its call, until answered: the answers to the
    /// others no longer count.
    newest: Option<usize>,
    rows: Vec<Entry>,
    error: String,
    /// The path the folders listed are for, their parent, and each one's
    /// name and full path.
    browsed: (String, String, Vec<(String, String)>),
    /// Paths and lines handed on.
    handed: Vec<String>,
    /// How many searches went to the MC.
    asked: usize,
}

impl Model {
    fn searching(&self) -> bool {
        self.scheduled || self.newest.is_some()
    }

    fn open(&mut self, mode: Mode) {
        self.mode = mode;
        self.query = if mode == Mode::Browse {
            "~/".into()
        } else {
            String::new()
        };
        self.rows.clear();
        self.error.clear();
        self.browsed = Default::default();
        self.newest = None;
        self.scheduled = matches!(mode, Mode::Files | Mode::Content | Mode::Browse);
    }

    fn close(&mut self) {
        self.mode = Mode::Closed;
        self.scheduled = false;
        self.newest = None;
    }

    fn searches(&self) -> bool {
        matches!(self.mode, Mode::Files | Mode::Content | Mode::Browse)
    }

    /// Asks again once typing pauses; what is on its way no longer counts.
    fn search_again(&mut self) {
        self.scheduled = true;
        self.newest = None;
    }

    /// The search the pause sends: its method and payload, or none when
    /// there is nothing to ask (and nothing listed).
    fn pause(&mut self) -> Option<(&'static str, Json)> {
        if !std::mem::take(&mut self.scheduled) {
            return None;
        }
        let trimmed = self.query.trim().to_owned();
        let asked = match self.mode {
            Mode::Files => (
                ENTRIES,
                json!({"cwd": self.root, "query": trimmed, "limit": 200, "kind": "file"}),
            ),
            Mode::Content if trimmed.is_empty() => {
                self.rows.clear();
                self.error.clear();
                return None;
            }
            Mode::Content => (
                CONTENTS,
                json!({"cwd": self.root, "query": self.query, "limit": 500,
                    "caseSensitive": self.case_sensitive, "wholeWord": false,
                    "useRegex": false}),
            ),
            Mode::Browse if trimmed.is_empty() => {
                self.rows.clear();
                self.browsed.1.clear();
                self.browsed.2.clear();
                return None;
            }
            Mode::Browse if trimmed.starts_with('/') || trimmed.starts_with('~') => {
                (BROWSE, json!({"partialPath": trimmed}))
            }
            Mode::Browse => (BROWSE, json!({"partialPath": trimmed, "cwd": self.root})),
            _ => return None,
        };
        self.asked += 1;
        Some(asked)
    }

    /// The MC answered call `index`, asked with `payload`.
    fn answered(
        &mut self,
        index: usize,
        method: &str,
        payload: &Json,
        result: &Result<Json, McError>,
    ) {
        if self.newest != Some(index) {
            return;
        }
        self.newest = None;
        let (answer, error) = match result {
            Ok(answer) => (answer.clone(), String::new()),
            Err(error) => (Json::Null, error.message.clone()),
        };
        self.error = error;
        let list = |key: &str| answer[key].as_array().cloned().unwrap_or_default();
        let field = |j: &Json, key: &str| j[key].as_str().unwrap_or_default().to_owned();
        self.rows = match method {
            ENTRIES => list("entries")
                .iter()
                .map(|found| {
                    let path = field(found, "path");
                    let name = path.rsplit('/').next().unwrap_or_default().to_owned();
                    entry("file", path, name)
                })
                .collect(),
            CONTENTS => {
                // Grouped by file, in the order the MC found them.
                let mut by_file: Vec<(String, Vec<Entry>)> = Vec::new();
                for found in list("matches") {
                    let path = field(&found, "path");
                    let id = format!("{path}:{}", found["lineNumber"]);
                    let row = entry("match", id, field(&found, "lineContent").trim());
                    match by_file.iter_mut().find(|(p, _)| *p == path) {
                        Some((_, rows)) => rows.push(row),
                        None => by_file.push((path, vec![row])),
                    }
                }
                by_file.into_iter().flat_map(|(_, rows)| rows).collect()
            }
            _ => {
                let asked = payload["partialPath"].as_str().unwrap_or_default();
                let parent = field(&answer, "parentPath");
                let folders: Vec<(String, String)> = list("entries")
                    .iter()
                    .map(|f| (field(f, "name"), field(f, "fullPath")))
                    .collect();
                let mut rows = Vec::new();
                if asked.ends_with('/') && !parent.is_empty() && parent != "/" {
                    let up = match parent.rfind('/') {
                        Some(0) => "/".to_owned(),
                        Some(slash) => format!("{}/", &parent[..slash]),
                        None => "./".to_owned(),
                    };
                    rows.push(entry("up", up, ".."));
                }
                rows.extend(
                    folders
                        .iter()
                        .map(|(name, full)| entry("folder", full.clone(), name.clone())),
                );
                self.browsed = (asked.to_owned(), parent, folders);
                rows
            }
        };
    }

    /// The path Enter hands on with no folder highlighted.
    fn browsed_path(&self) -> String {
        let query = self.query.trim();
        let (path, parent, folders) = &self.browsed;
        if query.is_empty() || path != query {
            return query.to_owned();
        }
        if query.ends_with('/') {
            return if parent.is_empty() {
                query.to_owned()
            } else {
                parent.clone()
            };
        }
        let leaf = query.rsplit('/').next().unwrap_or_default();
        folders
            .iter()
            .find(|(name, _)| name == leaf)
            .map_or_else(|| query.to_owned(), |(_, full)| full.clone())
    }

    fn hand_on(&mut self, path: String) {
        self.handed.push(path);
        if !self.keep_open {
            self.close();
        }
    }

    /// The highlighted row is a folder.
    fn folder_at(&self, highlighted: i64) -> Option<&Entry> {
        usize::try_from(highlighted)
            .ok()
            .and_then(|row| self.rows.get(row))
            .filter(|row| row.0 == "folder")
    }

    /// What browse mode's button says.
    fn submit_label(&self, highlighted: i64) -> String {
        let path = self.browsed_path();
        if path.is_empty() {
            return String::new();
        }
        let query = self.query.trim();
        let (asked, _, folders) = &self.browsed;
        let missing = self.folder_at(highlighted).is_none()
            && asked == query
            && if query.ends_with('/') {
                !self.error.is_empty()
            } else {
                let leaf = query.rsplit('/').next().unwrap_or_default();
                !folders.iter().any(|(name, _)| name == leaf)
            };
        if missing { "Create & Add" } else { "Add" }.into()
    }
}

/// The searches asked of the MC, by their index in its calls.
fn searches(hub: &Hub) -> Vec<(usize, String, Json)> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .enumerate()
        .filter(|(_, (_, method, _))| [ENTRIES, CONTENTS, BROWSE].contains(&method.as_str()))
        .map(|(index, (_, method, payload))| (index, method.clone(), payload.clone()))
        .collect()
}

fn highlighted(hub: &Hub) -> i64 {
    prop(hub, "highlighted").to_number() as i64
}

struct World {
    hub: Hub,
    _dir: tempfile::TempDir,
    obj: ObjectId,
    model: Model,
    mirror: Rc<RefCell<Mirror>>,
    handed: Rc<RefCell<Vec<String>>>,
}

impl World {
    fn new() -> World {
        let dir = tempfile::tempdir().expect("a cache directory");
        let hub = Hub::with(Launch {
            mc_origin: Some("http://127.0.0.1:1".into()),
            cache_dir: Some(dir.path().to_owned()),
            ..Launch::default()
        });
        hub.mc.set_ready(&hub.engine, true);
        let mut rows = Vec::new();
        for (index, (thread, root)) in ROOTS.iter().enumerate() {
            let project = format!("p{index}");
            rows.push(json!(["a", project, "project", {"id": project,
                "title": format!("Project {index}"), "workspaceRoot": root,
                "createdAt": AT, "updatedAt": AT}]));
            rows.push(
                json!(["a", thread, "thread", {"id": thread, "projectId": project,
                "title": format!("Thread {index}"), "createdAt": AT, "updatedAt": AT,
                "modelSelection": {"instanceId": "claude", "model": "m"}}]),
            );
        }
        hub.mc.frame(
            &hub.engine,
            "shell",
            "",
            json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
                "environment": {"environmentId": "env-1", "label": "Laptop"}}],
                "rows": rows}),
        );
        open_thread(&hub, ROOTS[0].0);
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
        World {
            hub,
            _dir: dir,
            obj,
            model: Model {
                mode: Mode::Closed,
                query: String::new(),
                case_sensitive: false,
                keep_open: false,
                root: ROOTS[0].1,
                scheduled: false,
                newest: None,
                rows: Vec::new(),
                error: String::new(),
                browsed: Default::default(),
                handed: Vec::new(),
                asked: 0,
            },
            mirror,
            handed: Rc::default(),
        }
    }

    fn step(&mut self, op: Op) {
        let engine = &self.hub.engine;
        let model = &mut self.model;
        match op {
            Op::Files | Op::Content => {
                let (action, mode) = match op {
                    Op::Files => (palette::FILES, Mode::Files),
                    _ => (palette::CONTENT, Mode::Content),
                };
                if model.mode == mode {
                    model.close();
                } else {
                    model.open(mode);
                }
                self.hub.dispatch(action, Json::Null);
            }
            Op::Browse { keep_open } => {
                model.keep_open = keep_open;
                model.open(Mode::Browse);
                let handed = self.handed.clone();
                palette::browse(
                    engine,
                    "env-1",
                    move |_, path| handed.borrow_mut().push(path.to_owned()),
                    BrowseOptions {
                        keep_open,
                        ..BrowseOptions::default()
                    },
                );
            }
            Op::Ask => {
                model.open(Mode::Ask);
                let handed = self.handed.clone();
                palette::ask(
                    engine,
                    "Git URL",
                    "Enter Git clone URL",
                    "",
                    move |_, text| {
                        handed.borrow_mut().push(text.to_owned());
                    },
                );
            }
            Op::Back => {
                match model.mode {
                    Mode::Closed => {}
                    Mode::Command => model.close(),
                    _ => model.open(Mode::Command),
                }
                invoke(&self.hub, "back", &[]);
            }
            Op::Dismiss => {
                model.close();
                invoke(&self.hub, "dismiss", &[]);
            }
            Op::Type(query) => {
                if model.query != query {
                    model.query = query.to_owned();
                    if model.searches() {
                        model.search_again();
                    }
                }
                type_query(&self.hub, query);
            }
            Op::CaseSensitive => {
                model.case_sensitive = !model.case_sensitive;
                if model.mode == Mode::Content {
                    model.search_again();
                }
                engine
                    .write_by_name(self.obj, "caseSensitive", Value::Bool(model.case_sensitive))
                    .expect("caseSensitive is writable");
            }
            Op::Pause => {
                let sent = model.pause();
                let before = searches(&self.hub).len();
                self.hub.advance(SEARCH_DELAY_MS);
                let calls = searches(&self.hub);
                match sent {
                    Some((method, payload)) => {
                        assert_eq!(calls.len(), before + 1, "{method} went out");
                        let (index, sent_method, sent_payload) = calls.last().cloned().unwrap();
                        assert_eq!((sent_method.as_str(), &sent_payload), (method, &payload));
                        self.model.newest = Some(index);
                    }
                    None => assert_eq!(calls.len(), before, "nothing to ask"),
                }
            }
            Op::Answer { pick, ok } => {
                let waiting: Vec<_> = searches(&self.hub)
                    .into_iter()
                    .filter(|(index, _, _)| self.hub.mc.is_pending(*index))
                    .collect();
                if waiting.is_empty() {
                    return;
                }
                let (index, method, payload) = waiting[pick % waiting.len()].clone();
                let result = if ok {
                    found(&method, &payload)
                } else {
                    Err(McError::new("The MC is busy"))
                };
                model.answered(index, &method, &payload, &result);
                self.hub.mc.reply(engine, index, result);
            }
            Op::Enter => {
                let highlighted = highlighted(&self.hub);
                let row = usize::try_from(highlighted)
                    .ok()
                    .and_then(|row| model.rows.get(row))
                    .cloned();
                let runs = match model.mode {
                    // Its rows are the other machine's: Enter there runs
                    // whatever command is first.
                    Mode::Command => return,
                    Mode::Closed => false,
                    Mode::Ask => {
                        let line = model.query.trim().to_owned();
                        if !line.is_empty() {
                            model.handed.push(line);
                        }
                        !model.query.trim().is_empty()
                    }
                    Mode::Files | Mode::Content => {
                        if row.is_some() {
                            model.close();
                        }
                        row.is_some()
                    }
                    Mode::Browse => match row {
                        Some((kind, id, title)) => {
                            let next = if kind == "up" {
                                id
                            } else {
                                let cut = model.query.rfind('/').map_or(0, |slash| slash + 1);
                                format!("{}{title}/", &model.query[..cut])
                            };
                            if next != model.query {
                                model.query = next;
                                model.search_again();
                            }
                            true
                        }
                        None => {
                            let path = model.browsed_path();
                            if !path.is_empty() {
                                model.hand_on(path.clone());
                            }
                            !path.is_empty()
                        }
                    },
                };
                let ran = invoke(&self.hub, "runHighlighted", &[]);
                assert_eq!(ran, Value::Bool(runs), "Enter in {:?}", self.model.mode);
            }
            Op::AddFolder => {
                let highlighted = highlighted(&self.hub);
                let adds = model.mode == Mode::Browse && {
                    let path = model
                        .folder_at(highlighted)
                        .map_or_else(|| model.browsed_path(), |row| row.1.clone());
                    if !path.is_empty() {
                        model.hand_on(path.clone());
                    }
                    !path.is_empty()
                };
                let added = invoke(&self.hub, "addBrowsedFolder", &[]);
                assert_eq!(added, Value::Bool(adds), "mod+Enter");
            }
            Op::Move(delta) => {
                invoke(&self.hub, "move", &[Value::Int(delta)]);
            }
            Op::Route { second } => {
                let (thread, root) = ROOTS[usize::from(second)];
                if model.root != root {
                    model.root = root;
                    // Another project's search starts afresh.
                    if matches!(model.mode, Mode::Files | Mode::Content) {
                        model.query.clear();
                        model.rows.clear();
                        model.error.clear();
                        model.search_again();
                    }
                }
                open_thread(&self.hub, thread);
            }
        }
    }

    fn check(&self) {
        let model = &self.model;
        let engine = &self.hub.engine;
        let mirror = self.mirror.borrow();
        assert_eq!(mirror.faults, Vec::<String>::new());
        assert_eq!(mirror.rows, read_rows(engine, self.obj), "the view's rows");
        assert_eq!(searches(&self.hub).len(), model.asked, "searches asked");
        assert_eq!(*self.handed.borrow(), model.handed, "handed on");
        assert_eq!(prop_text(&self.hub, "query"), model.query);
        assert_eq!(
            prop(&self.hub, "open"),
            Value::Bool(model.mode != Mode::Closed)
        );
        let searching = self.hub.with_controller::<Palette, _>(|c, _| c.searching());
        if model.searches() {
            assert_eq!(searching, model.searching(), "the spinner");
        }
        let mode = match model.mode {
            Mode::Closed | Mode::Command => return,
            Mode::Files => "files",
            Mode::Content => "content",
            Mode::Browse => "browse",
            Mode::Ask => "ask",
        };
        assert_eq!(prop_text(&self.hub, "mode"), mode);
        let rows: Vec<Entry> = self.hub.with_controller::<Palette, _>(|c, _| {
            (0..c.count())
                .map(|row| (c.kind_at(row), c.id_at(row), String::new()))
                .collect()
        });
        let rows: Vec<Entry> = rows
            .into_iter()
            .enumerate()
            .map(|(row, (kind, id, _))| (kind, id, role(engine, self.obj, row, "title")))
            .collect();
        assert_eq!(rows, model.rows, "rows for {:?}", model.query);
        let highlighted = highlighted(&self.hub);
        let lowest = if model.mode == Mode::Browse { -1 } else { 0 };
        assert!(
            highlighted == lowest || (lowest..rows.len() as i64).contains(&highlighted),
            "highlight {highlighted} of {}",
            rows.len()
        );
        let has_query = !model.query.trim().is_empty();
        match model.mode {
            Mode::Files if rows.is_empty() => assert_eq!(
                prop_text(&self.hub, "emptyText"),
                if model.searching() {
                    "Searching workspace files…"
                } else if has_query {
                    "No matching files."
                } else {
                    "No files found."
                }
            ),
            Mode::Content => {
                let files: std::collections::BTreeSet<&str> = model
                    .rows
                    .iter()
                    .map(|row| row.1.rsplit_once(':').map_or("", |(path, _)| path))
                    .collect();
                let status = if !has_query {
                    String::new()
                } else if model.searching() {
                    "Searching…".into()
                } else if !model.error.is_empty() {
                    model.error.clone()
                } else {
                    format!("{} results in {} files", rows.len(), files.len())
                };
                assert_eq!(prop_text(&self.hub, "status"), status);
            }
            Mode::Browse => assert_eq!(
                prop_text(&self.hub, "submitLabel"),
                model.submit_label(highlighted)
            ),
            _ => {}
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn only_the_newest_search_is_listed_whatever_order_the_mc_answers_in(
        ops in proptest::collection::vec(op(), 1..40)
    ) {
        let mut world = World::new();
        world.check();
        for op in ops {
            world.step(op);
            world.check();
        }
    }
}
