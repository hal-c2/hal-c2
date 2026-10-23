//! `WorkspaceFiles`: the Files tab against a fake MC that holds every
//! listing, search and read and answers them in any order, as the MC (which
//! runs each RPC on its own) may. Meanwhile the user switches workspace,
//! shows and hides the tab, opens and closes folders and files, searches,
//! retries, and the agent changes the files and the tree is listed again.
//! The port of desktop-qt's tests/prop/tst_WorkspaceFilesProp.cpp.
//!
//! The model is what the user should see: each folder's listing from the
//! newest request for it that was answered (an older answer landing later is
//! stale), the newest search's matches, the open file as the newest read of
//! it found it, and nothing at all from a workspace the user already left.
//! The MC reads the disk when the request comes in, so each request's answer
//! is fixed when it is asked.

mod common;

use std::collections::HashMap;
use std::rc::Rc;

use common::FakeMc;
use hal_c2_shell::Launch;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use hal_c2_shell::thread_view::file_tree::FileTreeModel;
use hal_c2_shell::thread_view::rows::RowSource;
use hal_c2_shell::thread_view::workspace_files::{SEARCH_DELAY_MS, WorkspaceFiles};
use ljos::App;
use ljos::prelude::{Engine, ObjectId, Value};
use ljos::testing::TestWindow;
use proptest::prelude::*;
use serde_json::json;

const ROOTS: [&str; 3] = ["/w1", "/w2", ""];
const FOLDERS: [&str; 2] = ["d", "d/e"];
const QUERIES: [&str; 4] = ["", "w", "md", "zz"];

fn parent_of(path: &str) -> &str {
    path.rfind('/').map_or("", |slash| &path[..slash])
}

/// (path, is a folder)
type Entry = (String, bool);

/// A workspace's disk at a version: `d/e` deep, a file in each folder, the
/// top's and the deepest's named after the version so a stale listing shows.
fn listing_of(root: &str, version: u32, folder: &str) -> Vec<Entry> {
    let tag = &root[1.min(root.len())..];
    match folder {
        "" => vec![("d".into(), true), (format!("{tag}-{version}.txt"), false)],
        "d" => vec![("d/e".into(), true), (format!("d/{tag}.md"), false)],
        _ => vec![(format!("d/e/{tag}-{version}.txt"), false)],
    }
}

fn files_of(root: &str, version: u32) -> Vec<String> {
    ["", "d", "d/e"]
        .iter()
        .flat_map(|folder| listing_of(root, version, folder))
        .filter(|(_, folder)| !folder)
        .map(|(path, _)| path)
        .collect()
}

fn matches_of(root: &str, version: u32, query: &str) -> Vec<String> {
    files_of(root, version)
        .into_iter()
        .filter(|file| file.contains(query))
        .collect()
}

fn contents_of(root: &str, version: u32, path: &str) -> String {
    format!("{root}:{path}@{version}")
}

fn entries_json(entries: &[Entry]) -> Json {
    Json::Array(
        entries
            .iter()
            .map(|(path, folder)| {
                json!({"path": path, "kind": if *folder { "directory" } else { "file" }})
            })
            .collect(),
    )
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum State {
    Unloaded,
    Loading,
    Loaded,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Kind {
    List,
    Search,
    Read,
}

/// One request the MC holds: what it is for, and its answer as the disk was.
#[derive(Clone, Debug)]
struct Request {
    kind: Kind,
    key: String,
    root: String,
    seq: u32,
    entries: Vec<Entry>,
    contents: String,
}

impl Request {
    fn same(&self, other: &Request) -> bool {
        self.kind == other.kind && self.key == other.key && self.root == other.root
    }

    fn label(&self) -> String {
        format!("{:?} {} of {}", self.kind, self.key, self.root)
    }
}

#[derive(Clone, Debug)]
struct Folder {
    state: State,
    children: Vec<Entry>,
    expanded: bool,
}

const UNLOADED: Folder = Folder {
    state: State::Unloaded,
    children: Vec::new(),
    expanded: false,
};

#[derive(Clone, Debug)]
struct Model {
    root: String,
    active: bool,
    versions: HashMap<String, u32>,
    /// The user's tree; empty until the top folder is first asked for.
    tree: HashMap<String, Folder>,
    selected: String,
    revealing: String,
    query: String,
    searching: bool,
    /// The tree shows the search's matches.
    search_shown: bool,
    matches: Vec<String>,
    open_path: String,
    file_status: &'static str,
    text: String,
    pending: Vec<Request>,
    seq: u32,
    /// The newest request of each folder, search and read of this workspace.
    latest_list: HashMap<String, u32>,
    latest_search: Option<u32>,
    latest_read: Option<u32>,
}

impl Model {
    fn new() -> Model {
        Model {
            root: String::new(),
            active: false,
            versions: HashMap::new(),
            tree: HashMap::new(),
            selected: String::new(),
            revealing: String::new(),
            query: String::new(),
            searching: false,
            search_shown: false,
            matches: Vec::new(),
            open_path: String::new(),
            file_status: "none",
            text: String::new(),
            pending: Vec::new(),
            seq: 0,
            latest_list: HashMap::new(),
            latest_search: None,
            latest_read: None,
        }
    }

    fn version(&self) -> u32 {
        self.versions.get(&self.root).copied().unwrap_or(0)
    }

    fn folder(&self, path: &str) -> Folder {
        self.tree.get(path).cloned().unwrap_or(UNLOADED)
    }

    fn ask(&mut self, kind: Kind, key: &str) {
        self.seq += 1;
        let mut request = Request {
            kind,
            key: key.into(),
            root: self.root.clone(),
            seq: self.seq,
            entries: Vec::new(),
            contents: String::new(),
        };
        match kind {
            Kind::List => {
                request.entries = listing_of(&self.root, self.version(), key);
                self.latest_list.insert(key.into(), self.seq);
            }
            Kind::Search => {
                request.entries = matches_of(&self.root, self.version(), key)
                    .into_iter()
                    .map(|path| (path, false))
                    .collect();
                self.latest_search = Some(self.seq);
            }
            Kind::Read => {
                request.contents = contents_of(&self.root, self.version(), key);
                self.latest_read = Some(self.seq);
            }
        }
        self.pending.push(request);
    }

    /// FileTreeModel::reload: a search on screen stays.
    fn reload_tree(&mut self) {
        self.tree.clear();
        if !self.search_shown {
            self.selected.clear();
        }
        self.tree.insert(
            String::new(),
            Folder {
                state: State::Loading,
                children: Vec::new(),
                expanded: true,
            },
        );
        self.ask(Kind::List, "");
    }

    fn expand(&mut self, folder: &str) {
        let entry = self.tree.entry(folder.into()).or_insert(UNLOADED);
        if entry.expanded {
            return;
        }
        entry.expanded = true;
        if entry.state != State::Unloaded {
            return;
        }
        entry.state = State::Loading;
        self.ask(Kind::List, folder);
    }

    /// WorkspaceFiles::walkReveal: opens the folders above the file, and
    /// selects it once they are listed.
    fn walk(&mut self) {
        if self.revealing.is_empty() || self.folder("").state != State::Loaded {
            return;
        }
        let revealing = self.revealing.clone();
        let parts: Vec<&str> = revealing.split('/').collect();
        let mut folder = String::new();
        for part in &parts[..parts.len() - 1] {
            folder = if folder.is_empty() {
                (*part).into()
            } else {
                format!("{folder}/{part}")
            };
            self.expand(&folder);
            if self.folder(&folder).state != State::Loaded {
                return;
            }
        }
        self.selected = std::mem::take(&mut self.revealing);
    }

    fn set_query(&mut self, next: &str) {
        if next == self.query {
            return;
        }
        self.query = next.into();
        // Whatever is on its way answers an older query.
        self.latest_search = None;
        if self.query.is_empty() {
            self.searching = false;
            self.search_shown = false;
            self.matches.clear();
            return;
        }
        self.revealing.clear();
        if self.root.is_empty() {
            return;
        }
        self.searching = true;
        let query = self.query.clone();
        self.ask(Kind::Search, &query);
    }

    fn close(&mut self) {
        self.open_path.clear();
        self.file_status = "none";
        self.text.clear();
        self.latest_read = None;
    }

    fn set_target(&mut self, next: &str) {
        if next == self.root {
            return;
        }
        self.root = next.into();
        self.tree.clear();
        self.selected.clear();
        self.revealing.clear();
        self.latest_list.clear();
        self.query.clear();
        self.searching = false;
        self.search_shown = false;
        self.matches.clear();
        self.latest_search = None;
        self.close();
        self.set_active(self.active);
    }

    fn set_active(&mut self, next: bool) {
        self.active = next;
        if self.active && !self.root.is_empty() && self.folder("").state == State::Unloaded {
            self.reload_tree();
        }
    }

    fn open(&mut self, path: &str) {
        if self.root.is_empty() {
            return;
        }
        if path != self.open_path || self.file_status != "ready" {
            self.open_path = path.into();
            self.file_status = "loading";
            self.ask(Kind::Read, path);
        }
        self.set_query("");
        self.revealing = path.into();
        if self.folder("").state == State::Unloaded {
            self.reload_tree();
            return;
        }
        self.walk();
    }

    /// The MC answers the request, the `rank`-th like it (oldest first).
    fn answer(&mut self, like: &Request, rank: usize, ok: bool) {
        let at = self
            .pending
            .iter()
            .enumerate()
            .filter(|(_, r)| r.same(like))
            .nth(rank)
            .map(|(at, _)| at)
            .expect("a pending request");
        let request = self.pending.remove(at);
        if request.root != self.root {
            return;
        }
        match request.kind {
            Kind::List => {
                if self.latest_list.get(&request.key) != Some(&request.seq) {
                    return;
                }
                let folder = self.tree.entry(request.key.clone()).or_insert(UNLOADED);
                folder.state = if ok { State::Loaded } else { State::Failed };
                folder.children = if ok { request.entries } else { Vec::new() };
                self.walk();
            }
            Kind::Search => {
                if self.latest_search != Some(request.seq) {
                    return;
                }
                self.searching = false;
                self.search_shown = true;
                self.matches = if ok {
                    request.entries.into_iter().map(|(path, _)| path).collect()
                } else {
                    Vec::new()
                };
            }
            Kind::Read => {
                if self.latest_read != Some(request.seq) {
                    return;
                }
                self.file_status = if ok { "ready" } else { "error" };
                self.text = if ok { request.contents } else { String::new() };
            }
        }
    }

    fn rows_under(&self, path: &str, rows: &mut Vec<String>) {
        let folder = self.folder(path);
        match folder.state {
            State::Loading => rows.push(format!("{path} loading")),
            State::Failed => rows.push(format!("{path} error")),
            State::Loaded => {
                for (child, directory) in &folder.children {
                    rows.push(format!(
                        "{child} {}",
                        if *directory { "directory" } else { "file" }
                    ));
                    if *directory && self.folder(child).expanded {
                        self.rows_under(child, rows);
                    }
                }
            }
            State::Unloaded => {}
        }
    }

    fn under(&self, folder: &str, folders: &[String], rows: &mut Vec<String>) {
        for child in FOLDERS {
            if parent_of(child) == folder && folders.iter().any(|f| f == child) {
                rows.push(format!("{child} directory"));
                self.under(child, folders, rows);
            }
        }
        let mut files: Vec<&String> = Vec::new();
        for found in &self.matches {
            if parent_of(found) == folder && !files.contains(&found) {
                files.push(found);
            }
        }
        files.sort_by_key(|file| file.to_lowercase());
        for file in files {
            rows.push(format!("{file} file"));
        }
    }

    /// The tree's rows as "path kind".
    fn rows(&self) -> Vec<String> {
        let mut rows = Vec::new();
        if !self.search_shown {
            if self.folder("").expanded {
                self.rows_under("", &mut rows);
            }
            return rows;
        }
        // The matches under their folders, folders first: the fixed disk's
        // folders all come before its files.
        let mut folders: Vec<String> = Vec::new();
        for found in &self.matches {
            let mut folder = parent_of(found);
            while !folder.is_empty() {
                if !folders.iter().any(|f| f == folder) {
                    folders.push(folder.into());
                }
                folder = parent_of(folder);
            }
        }
        self.under("", &folders, &mut rows);
        rows
    }

    fn root_status(&self) -> &'static str {
        if self.search_shown {
            return "ready";
        }
        match self.folder("").state {
            State::Loaded => "ready",
            State::Failed => "error",
            _ => "loading",
        }
    }

    fn pending_labels(&self) -> Vec<String> {
        let mut labels: Vec<String> = self.pending.iter().map(Request::label).collect();
        labels.sort();
        labels
    }
}

/// The real thing: the Files tab over a fake MC, and the requests it holds.
struct Sut {
    engine: Engine,
    window: TestWindow,
    mc: Rc<FakeMc>,
    files: ObjectId,
    tree: ObjectId,
    versions: HashMap<String, u32>,
    /// Held requests with the call that carries each, oldest first.
    held: Vec<(Request, usize)>,
    /// How many of the MC's calls were looked at.
    seen: usize,
}

impl Sut {
    fn new() -> Sut {
        let engine = App::new("test")
            .register(hal_c2_shell::register)
            .build_engine();
        // A window for its clock, before the shell starts its timers on it.
        let window = ljos::testing::TestWindow::new(&engine, 100.0, 100.0);
        let mc = Rc::new(FakeMc::default());
        hal_c2_shell::start(&engine, &Launch::default(), mc.clone());
        let files = WorkspaceFiles::create(&engine, None, mc.clone()).expect("the files");
        let tree = WorkspaceFiles::tree(&engine, files).expect("its tree");
        WorkspaceFiles::set_target(&engine, files, "env-a", "", "");
        Sut {
            engine,
            window,
            mc,
            files,
            tree,
            versions: HashMap::new(),
            held: Vec::new(),
            seen: 0,
        }
    }

    /// Lets the search pause pass, then takes in the calls made since: the
    /// disk is read as they come in.
    fn settle(&mut self) {
        self.window.advance(SEARCH_DELAY_MS as u64).unwrap();
        let calls = self.mc.calls.borrow().clone();
        for (index, (_, method, payload)) in calls.iter().enumerate().skip(self.seen) {
            let text = |key: &str| payload.get(key).and_then(Json::as_str).unwrap_or("");
            let (kind, key) = match method.as_str() {
                "projects.listEntries" => (Kind::List, text("directoryPath")),
                "projects.searchEntries" => (Kind::Search, text("query")),
                "projects.readFile" => (Kind::Read, text("relativePath")),
                _ => continue,
            };
            let root = text("cwd");
            let version = self.versions.get(root).copied().unwrap_or(0);
            let mut request = Request {
                kind,
                key: key.into(),
                root: root.into(),
                seq: 0,
                entries: Vec::new(),
                contents: String::new(),
            };
            match kind {
                Kind::List => request.entries = listing_of(root, version, key),
                Kind::Search => {
                    request.entries = matches_of(root, version, key)
                        .into_iter()
                        .map(|path| (path, false))
                        .collect();
                }
                Kind::Read => request.contents = contents_of(root, version, key),
            }
            self.held.push((request, index));
        }
        self.seen = calls.len();
    }

    fn answer(&mut self, like: &Request, rank: usize, ok: bool) {
        let at = self
            .held
            .iter()
            .enumerate()
            .filter(|(_, (r, _))| r.same(like))
            .nth(rank)
            .map(|(at, _)| at)
            .unwrap_or_else(|| panic!("the MC holds no {}", like.label()));
        let (request, index) = self.held.remove(at);
        let result = if !ok {
            Err(McError::new("no"))
        } else if request.kind == Kind::Read {
            Ok(json!({"contents": request.contents}))
        } else {
            Ok(json!({"entries": entries_json(&request.entries), "truncated": false}))
        };
        assert!(self.mc.reply(&self.engine, index, result));
    }

    fn rows(&self) -> Vec<String> {
        let text = |v: Value| match v {
            Value::String(s) => (*s).to_owned(),
            _ => String::new(),
        };
        FileTreeModel::read(&self.engine, self.tree, |t| {
            (0..t.row_count())
                .map(|r| format!("{} {}", text(t.data(r, "path")), text(t.data(r, "kind"))))
                .collect()
        })
        .unwrap()
    }

    fn tree_update<R>(
        &self,
        f: impl FnOnce(&mut hal_c2_shell::thread_view::file_tree::FileTree) -> R,
    ) {
        FileTreeModel::update(&self.engine, self.tree, f).expect("the tree");
    }
}

#[derive(Clone, Debug)]
enum Op {
    Target(usize),
    Active(bool),
    /// Index into the folders; skipped unless the tree shows it.
    Toggle(usize),
    /// Index into the pending requests, ok or refused.
    Answer(usize, bool),
    Change,
    /// Index into the failed folders.
    Retry(usize),
    Query(usize),
    /// Index into the files of the current disk.
    Open(usize),
    Close,
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        (0..ROOTS.len()).prop_map(Op::Target),
        any::<bool>().prop_map(Op::Active),
        (0..FOLDERS.len()).prop_map(Op::Toggle),
        (0..FOLDERS.len()).prop_map(Op::Toggle),
        (0..16usize, prop_oneof![4 => Just(true), 1 => Just(false)])
            .prop_map(|(i, ok)| Op::Answer(i, ok)),
        (0..16usize, prop_oneof![4 => Just(true), 1 => Just(false)])
            .prop_map(|(i, ok)| Op::Answer(i, ok)),
        (0..16usize, prop_oneof![4 => Just(true), 1 => Just(false)])
            .prop_map(|(i, ok)| Op::Answer(i, ok)),
        (0..16usize, prop_oneof![4 => Just(true), 1 => Just(false)])
            .prop_map(|(i, ok)| Op::Answer(i, ok)),
        Just(Op::Change),
        (0..4usize).prop_map(Op::Retry),
        (0..QUERIES.len()).prop_map(Op::Query),
        (0..3usize).prop_map(Op::Open),
        (0..3usize).prop_map(Op::Open),
        Just(Op::Close),
    ]
}

/// Compares the Files tab with the model; the failure says which part.
fn check(model: &Model, sut: &Sut) -> Result<(), String> {
    let same = |what: &str, got: String, want: String| {
        if got == want {
            Ok(())
        } else {
            Err(format!("{what}: got {got}, want {want}"))
        }
    };
    let held: Vec<Request> = sut.held.iter().map(|(r, _)| r.clone()).collect();
    let mut asked: Vec<String> = held.iter().map(Request::label).collect();
    asked.sort();
    same(
        "requests held",
        format!("{asked:?}"),
        format!("{:?}", model.pending_labels()),
    )?;
    let facts = WorkspaceFiles::read(&sut.engine, sut.files, |f| f.facts()).unwrap();
    let text = WorkspaceFiles::read(&sut.engine, sut.files, |f| f.text().to_owned()).unwrap();
    same("workspace", facts.root.clone(), model.root.clone())?;
    same(
        "rows",
        format!("{:?}", sut.rows()),
        format!("{:?}", model.rows()),
    )?;
    same(
        "root status",
        common::text(&sut.engine, sut.tree, "rootStatus"),
        model.root_status().into(),
    )?;
    same(
        "selected",
        common::text(&sut.engine, sut.tree, "selectedPath"),
        model.selected.clone(),
    )?;
    same(
        "filtered",
        format!("{:?}", common::read(&sut.engine, sut.tree, "filtered")),
        format!("{:?}", Value::Bool(model.search_shown)),
    )?;
    same("query", facts.query, model.query.clone())?;
    same(
        "searching",
        facts.searching.to_string(),
        model.searching.to_string(),
    )?;
    same("open file", facts.open_path, model.open_path.clone())?;
    same(
        "file status",
        facts.file_status.into(),
        model.file_status.into(),
    )?;
    if model.file_status != "loading" {
        same("text", text, model.text.clone())?;
    }
    Ok(())
}

fn run(ops: Vec<Op>) -> Result<(), TestCaseError> {
    let mut model = Model::new();
    let mut sut = Sut::new();
    for op in ops {
        let done = match op.clone() {
            Op::Target(i) => {
                model.set_target(ROOTS[i]);
                WorkspaceFiles::set_target(&sut.engine, sut.files, "env-a", ROOTS[i], "");
                true
            }
            Op::Active(active) => {
                model.set_active(active);
                WorkspaceFiles::set_active(&sut.engine, sut.files, active);
                true
            }
            Op::Toggle(i) => {
                let folder = FOLDERS[i];
                let parent = model.folder(parent_of(folder));
                let shown = !model.search_shown
                    && parent.state == State::Loaded
                    && parent.expanded
                    && parent.children.iter().any(|(path, _)| path == folder);
                if shown {
                    if model.folder(folder).expanded {
                        model.tree.get_mut(folder).unwrap().expanded = false;
                    } else {
                        model.expand(folder);
                    }
                    sut.tree_update(|t| t.toggle(folder));
                }
                shown
            }
            Op::Answer(i, ok) => {
                if model.pending.is_empty() {
                    false
                } else {
                    let at = i % model.pending.len();
                    let request = model.pending[at].clone();
                    let rank = model.pending[..at]
                        .iter()
                        .filter(|r| r.same(&request))
                        .count();
                    model.answer(&request, rank, ok);
                    sut.answer(&request, rank, ok);
                    true
                }
            }
            Op::Change => {
                if model.root.is_empty() {
                    false
                } else {
                    let root = model.root.clone();
                    *model.versions.entry(root.clone()).or_insert(0) += 1;
                    let mut loaded: Vec<String> = model
                        .tree
                        .iter()
                        .filter(|(_, f)| f.state == State::Loaded)
                        .map(|(path, _)| path.clone())
                        .collect();
                    loaded.sort();
                    for folder in loaded {
                        model.ask(Kind::List, &folder);
                    }
                    *sut.versions.entry(root).or_insert(0) += 1;
                    sut.tree_update(|t| t.refresh());
                    true
                }
            }
            Op::Retry(i) => {
                let mut failed: Vec<String> = model
                    .tree
                    .iter()
                    .filter(|(_, f)| f.state == State::Failed)
                    .map(|(path, _)| path.clone())
                    .collect();
                failed.sort();
                if model.search_shown || failed.is_empty() {
                    false
                } else {
                    let folder = failed[i % failed.len()].clone();
                    model.tree.get_mut(&folder).unwrap().state = State::Loading;
                    model.ask(Kind::List, &folder);
                    // The top folder's "Try again", or a folder's error row.
                    if folder.is_empty() {
                        common::call(&sut.engine, sut.files, "reload", &[]);
                    } else {
                        sut.tree_update(|t| t.retry(&folder));
                    }
                    true
                }
            }
            Op::Query(i) => {
                model.set_query(QUERIES[i]);
                sut.engine
                    .write_by_name(sut.files, "query", Value::from(QUERIES[i]))
                    .expect("query is writable");
                true
            }
            Op::Open(i) => {
                if model.root.is_empty() {
                    false
                } else {
                    let files = files_of(&model.root, model.version());
                    let path = files[i % files.len()].clone();
                    model.open(&path);
                    WorkspaceFiles::show_file(&sut.engine, sut.files, &path, 0);
                    true
                }
            }
            Op::Close => {
                model.close();
                common::call(&sut.engine, sut.files, "closeFile", &[]);
                true
            }
        };
        if !done {
            continue;
        }
        sut.settle();
        if let Err(problem) = check(&model, &sut) {
            return Err(TestCaseError::fail(format!("after {op:?}: {problem}")));
        }
    }
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    /// The Files tab shows the newest answers about the workspace on screen.
    #[test]
    fn the_files_tab_shows_the_newest_answers_about_the_workspace_on_screen(
        ops in proptest::collection::vec(op(), 1..40),
    ) {
        run(ops)?;
    }
}
