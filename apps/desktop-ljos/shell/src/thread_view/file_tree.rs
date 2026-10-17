//! desktop-qt's FileTreeModel: a project's folders as the rows of a tree a
//! ListView draws, each visible entry with its depth, a folder's children
//! under it while it is expanded.
//!
//! Folders load when first expanded (a [`TreeNote::Fetch`], answered with
//! [`FileTree::set_listing`] or [`FileTree::set_failed`]); a loading folder
//! shows a "loading" row, a failed one an "error" row the user can retry
//! from. Expanding, collapsing and a listing that lands insert and remove
//! only that folder's rows.
//!
//! A search swaps in a tree of its own made of the matches and their
//! folders, all expanded; ending it brings back the tree as the user left
//! it.
//!
//! [`FileTree`] is the core; [`FileTreeModel`] is the object QML binds.
//! Its owner (desktop-qt's WorkspaceFiles) lists the folders it asks for.

use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::rc::Rc;

use ljos::prelude::{Atom, Cx, Engine, ObjectId, QmlObject, Value, qml_impl};
use ljos::prelude::{EngineError, RowKey};
use serde_json::json;

use super::rows::{ListRows, RowChange, RowSource, int};
use crate::json::{self, Json};

pub const ROLES: &[&str] = &[
    "path", "name", "depth", "kind", "expanded", "ignored", "problem", "selected",
];

/// One entry of a folder's listing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub path: String,
    pub directory: bool,
    pub ignored: bool,
}

impl Entry {
    pub fn new(path: &str, directory: bool, ignored: bool) -> Entry {
        Entry {
            path: path.to_owned(),
            directory,
            ignored,
        }
    }
}

/// What the tree says besides its rows, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TreeNote {
    /// rootStatus, rootProblem or filtered.
    Root,
    /// selectedPath.
    Selected,
    AllExpanded,
    /// A folder's children landed (or failed); reveal walks on from here.
    Settled(String),
    /// List this folder ("" the top): answer with set_listing or set_failed.
    Fetch(String),
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum State {
    #[default]
    Unloaded,
    Loading,
    Loaded,
    Failed,
}

#[derive(Clone, Debug, Default)]
struct Folder {
    state: State,
    problem: String,
    children: Vec<Entry>,
    expanded: bool,
}

#[derive(Clone, Debug)]
struct Row {
    path: String,
    depth: usize,
    /// file, directory, loading or error
    kind: &'static str,
    ignored: bool,
    key: RowKey,
}

impl Row {
    fn new(path: &str, depth: usize, kind: &'static str, ignored: bool) -> Row {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        (path, kind).hash(&mut hasher);
        Row {
            path: path.to_owned(),
            depth,
            kind,
            ignored,
            key: hasher.finish(),
        }
    }

    fn is_entry(&self) -> bool {
        self.kind == "file" || self.kind == "directory"
    }
}

type Folders = HashMap<String, Folder>;

pub fn parent_of(path: &str) -> &str {
    path.rfind('/').map_or("", |slash| &path[..slash])
}

pub fn name_of(path: &str) -> &str {
    path.rfind('/').map_or(path, |slash| &path[slash + 1..])
}

/// Folders first, then by name as people read it.
fn sort_entries(entries: &mut [Entry]) {
    entries.sort_by(|a, b| {
        b.directory
            .cmp(&a.directory)
            .then_with(|| {
                name_of(&a.path)
                    .to_lowercase()
                    .cmp(&name_of(&b.path).to_lowercase())
            })
            .then_with(|| a.path.cmp(&b.path))
    });
}

/// The tree of a project's folders.
#[derive(Debug, Default)]
pub struct FileTree {
    folders: Folders,
    search: Folders,
    searching: bool,
    expand_all: bool,
    rows: Vec<Row>,
    selected: String,
    changes: Vec<RowChange>,
    notes: Vec<TreeNote>,
}

impl FileTree {
    pub fn new() -> FileTree {
        FileTree::default()
    }

    fn shown(&self) -> &Folders {
        if self.searching {
            &self.search
        } else {
            &self.folders
        }
    }

    fn shown_mut(&mut self) -> &mut Folders {
        if self.searching {
            &mut self.search
        } else {
            &mut self.folders
        }
    }

    fn reset(&mut self) {
        let keys = self.rows.iter().map(|r| r.key).collect();
        self.changes.push(RowChange::Reset(keys));
    }

    fn redraw(&mut self, row: Option<usize>, role: &'static [&'static str]) {
        if let Some(first) = row {
            self.changes.push(RowChange::Changed {
                first,
                count: 1,
                roles: role,
            });
        }
    }

    /// Forgets every folder without loading anything.
    pub fn clear(&mut self) {
        self.folders.clear();
        self.search.clear();
        self.searching = false;
        self.rows.clear();
        let selected = !std::mem::take(&mut self.selected).is_empty();
        self.reset();
        if std::mem::replace(&mut self.expand_all, false) {
            self.notes.push(TreeNote::AllExpanded);
        }
        self.notes.push(TreeNote::Root);
        if selected {
            self.notes.push(TreeNote::Selected);
        }
    }

    /// Forgets every folder and loads the top one again; a search on screen
    /// stays.
    pub fn reload(&mut self) {
        if self.searching {
            // Only the user's tree, behind the search's rows.
            self.folders.clear();
            if std::mem::replace(&mut self.expand_all, false) {
                self.notes.push(TreeNote::AllExpanded);
            }
        } else {
            self.clear();
        }
        self.folders.entry(String::new()).or_default().expanded = true;
        self.load("");
        if !self.searching {
            self.refill("");
        }
    }

    /// Asks for a folder of the user's tree.
    fn load(&mut self, folder: &str) {
        // Always the user's tree: a search's folders show what it lists.
        let entry = self.folders.entry(folder.to_owned()).or_default();
        entry.state = State::Loading;
        entry.problem.clear();
        if folder.is_empty() {
            self.notes.push(TreeNote::Root);
        }
        self.notes.push(TreeNote::Fetch(folder.to_owned()));
    }

    /// Shows a folder's listing (or failure) that just landed in the user's
    /// tree.
    fn settle(&mut self, folder: &str) {
        if self.searching {
            // A folder the search opened is waiting on the user's tree's
            // listing.
            let listed = self.folders.get(folder).cloned().unwrap_or_default();
            let Some(shown) = self.search.get_mut(folder) else {
                return;
            };
            if shown.state != State::Loading {
                return;
            }
            shown.state = listed.state;
            shown.problem = listed.problem;
            shown.children = listed.children;
        }
        self.refill(folder);
    }

    pub fn set_listing(&mut self, folder: &str, entries: Vec<Entry>) {
        let entry = self.folders.entry(folder.to_owned()).or_default();
        entry.state = State::Loaded;
        entry.problem.clear();
        entry.children = entries;
        sort_entries(&mut entry.children);
        self.settle(folder);
        if self.expand_all {
            self.expand_under(folder);
        }
        if folder.is_empty() {
            self.notes.push(TreeNote::Root);
        }
        self.notes.push(TreeNote::Settled(folder.to_owned()));
    }

    pub fn set_failed(&mut self, folder: &str, problem: &str) {
        let entry = self.folders.entry(folder.to_owned()).or_default();
        entry.state = State::Failed;
        entry.problem = problem.to_owned();
        entry.children.clear();
        self.settle(folder);
        if folder.is_empty() {
            self.notes.push(TreeNote::Root);
        }
        self.notes.push(TreeNote::Settled(folder.to_owned()));
    }

    /// The matches of a search as the tree, or the user's tree again (None).
    pub fn set_search(&mut self, matches: Option<Vec<Entry>>) {
        self.searching = matches.is_some();
        self.search.clear();
        if let Some(matches) = matches {
            let root = self.search.entry(String::new()).or_default();
            root.state = State::Loaded;
            root.expanded = true;
            let mut listed = HashSet::new();
            let search = &mut self.search;
            let mut add = |entry: Entry| {
                if listed.insert(entry.path.clone()) {
                    let parent = parent_of(&entry.path).to_owned();
                    search.entry(parent).or_default().children.push(entry);
                }
            };
            for found in matches {
                // Its folders, so the match shows where it lives.
                let mut folder = parent_of(&found.path).to_owned();
                while !folder.is_empty() {
                    add(Entry::new(&folder, true, false));
                    folder = parent_of(&folder).to_owned();
                }
                add(found);
            }
            for folder in self.search.values_mut() {
                folder.state = State::Loaded;
                folder.expanded = true;
                sort_entries(&mut folder.children);
            }
        }
        self.rows = self.rows_under("", 0);
        self.reset();
        self.notes.push(TreeNote::Root);
    }

    /// The top folder's: loading, ready or error.
    pub fn root_status(&self) -> &'static str {
        match self.shown().get("").map(|f| f.state) {
            Some(State::Loaded) => "ready",
            Some(State::Failed) => "error",
            _ => "loading",
        }
    }

    pub fn root_problem(&self) -> &str {
        self.shown().get("").map_or("", |f| f.problem.as_str())
    }

    pub fn selected_path(&self) -> &str {
        &self.selected
    }

    /// A search's tree is on screen.
    pub fn filtered(&self) -> bool {
        self.searching
    }

    /// Every folder is kept open (expandAll), down to the ones still
    /// loading.
    pub fn all_expanded(&self) -> bool {
        self.expand_all
    }

    pub fn loaded(&self, folder: &str) -> bool {
        self.folders
            .get(folder)
            .is_some_and(|f| f.state == State::Loaded)
    }

    /// Whether the folder was asked for since the tree was last cleared.
    pub fn requested(&self, folder: &str) -> bool {
        self.folders
            .get(folder)
            .is_some_and(|f| f.state != State::Unloaded)
    }

    pub fn is_expanded(&self, folder: &str) -> bool {
        self.shown().get(folder).is_some_and(|f| f.expanded)
    }

    fn rows_under(&self, folder: &str, depth: usize) -> Vec<Row> {
        let mut rows = Vec::new();
        self.push_rows_under(folder, depth, &mut rows);
        rows
    }

    fn push_rows_under(&self, folder: &str, depth: usize, rows: &mut Vec<Row>) {
        let Some(entry) = self.shown().get(folder) else {
            return;
        };
        match entry.state {
            State::Loading => rows.push(Row::new(folder, depth, "loading", false)),
            State::Failed => rows.push(Row::new(folder, depth, "error", false)),
            State::Loaded => {
                for child in &entry.children {
                    let kind = if child.directory { "directory" } else { "file" };
                    rows.push(Row::new(&child.path, depth, kind, child.ignored));
                    if child.directory && self.is_expanded(&child.path) {
                        self.push_rows_under(&child.path, depth + 1, rows);
                    }
                }
            }
            State::Unloaded => {}
        }
    }

    /// The rows under `folder`'s row (or every row, for the top).
    fn child_range(&self, folder: &str) -> Option<(usize, usize)> {
        if folder.is_empty() {
            return Some((0, self.rows.len()));
        }
        let row = self.row_of(folder)?;
        let depth = self.rows[row].depth;
        let end = self.rows[row + 1..]
            .iter()
            .position(|r| r.depth <= depth)
            .map_or(self.rows.len(), |n| row + 1 + n);
        Some((row + 1, end))
    }

    /// Redraws a visible folder's children after its state changed.
    fn refill(&mut self, folder: &str) {
        // A folder shows its children only when it and every folder above
        // it is open.
        if !self.is_expanded(folder) {
            return;
        }
        let Some((first, end)) = self.child_range(folder) else {
            return;
        };
        let depth = if folder.is_empty() {
            0
        } else {
            self.rows[first - 1].depth + 1
        };
        let rows = self.rows_under(folder, depth);
        if end > first {
            self.rows.drain(first..end);
            self.changes.push(RowChange::Removed {
                first,
                count: end - first,
            });
        }
        if !rows.is_empty() {
            let keys = rows.iter().map(|r| r.key).collect();
            self.rows.splice(first..first, rows);
            self.changes.push(RowChange::Inserted { first, keys });
        }
    }

    pub fn toggle(&mut self, path: &str) {
        if self.is_expanded(path) {
            self.collapse(path);
        } else {
            self.expand(path);
        }
    }

    pub fn expand(&mut self, path: &str) {
        let searching = self.searching;
        let entry = self.shown_mut().entry(path.to_owned()).or_default();
        if entry.expanded {
            return;
        }
        entry.expanded = true;
        if entry.state == State::Unloaded {
            // A folder the search did not list shows the user's tree's
            // listing of it, and shares its load.
            if self
                .folders
                .get(path)
                .is_none_or(|f| f.state == State::Unloaded)
            {
                self.load(path);
            }
            if searching {
                let listed = self.folders.get(path).cloned().unwrap_or_default();
                let entry = self.search.entry(path.to_owned()).or_default();
                entry.state = listed.state;
                entry.problem = listed.problem;
                entry.children = listed.children;
            }
        }
        self.refill(path);
        self.redraw(self.row_of(path), &["expanded"]);
    }

    pub fn collapse(&mut self, path: &str) {
        if path.is_empty() {
            return;
        }
        let range = self.child_range(path);
        let entry = self.shown_mut().entry(path.to_owned()).or_default();
        if !entry.expanded {
            return;
        }
        entry.expanded = false;
        if let Some((first, end)) = range.filter(|(first, end)| end > first) {
            self.rows.drain(first..end);
            self.changes.push(RowChange::Removed {
                first,
                count: end - first,
            });
        }
        self.redraw(self.row_of(path), &["expanded"]);
    }

    /// Opens `folder`'s folders, as expandAll asks.
    fn expand_under(&mut self, folder: &str) {
        let children = self
            .folders
            .get(folder)
            .map(|f| f.children.clone())
            .unwrap_or_default();
        for child in children {
            if !child.directory || child.ignored {
                continue;
            }
            if self.searching {
                // The search's rows are on screen: the user's tree opens
                // behind them.
                let entry = self.folders.entry(child.path.clone()).or_default();
                entry.expanded = true;
                if entry.state == State::Unloaded {
                    entry.state = State::Loading;
                    self.notes.push(TreeNote::Fetch(child.path.clone()));
                }
            } else {
                self.expand(&child.path);
            }
            self.expand_under(&child.path);
        }
    }

    /// Opens every folder, loading each as it becomes known; folders git
    /// ignores stay closed (a dependency tree is not what the user asked
    /// for).
    pub fn expand_all(&mut self) {
        if !self.expand_all {
            self.expand_all = true;
            self.notes.push(TreeNote::AllExpanded);
        }
        self.expand_under("");
    }

    /// Closes every folder: only the top level shows.
    pub fn collapse_all(&mut self) {
        if self.expand_all {
            self.expand_all = false;
            self.notes.push(TreeNote::AllExpanded);
        }
        for (path, folder) in &mut self.folders {
            folder.expanded = path.is_empty();
        }
        self.rows = self.rows_under("", 0);
        self.reset();
    }

    /// Lists every folder already loaded again, in place: what is open
    /// stays open.
    pub fn refresh(&mut self) {
        let mut loaded: Vec<String> = self
            .folders
            .iter()
            .filter(|(_, f)| f.state == State::Loaded)
            .map(|(path, _)| path.clone())
            .collect();
        loaded.sort();
        self.notes.extend(loaded.into_iter().map(TreeNote::Fetch));
    }

    /// Lists a folder that failed again.
    pub fn retry(&mut self, folder: &str) {
        if self.folders.get(folder).map(|f| f.state) != Some(State::Failed) {
            return;
        }
        self.load(folder);
        if self.searching
            && let Some(shown) = self.search.get_mut(folder)
            && shown.state == State::Failed
        {
            shown.state = State::Loading;
            shown.problem.clear();
        }
        self.refill(folder);
    }

    pub fn select(&mut self, path: &str) {
        if path == self.selected {
            return;
        }
        let before = self.row_of(&self.selected);
        path.clone_into(&mut self.selected);
        let after = self.row_of(&self.selected);
        self.redraw(before, &["selected"]);
        self.redraw(after, &["selected"]);
        self.notes.push(TreeNote::Selected);
    }

    /// The row showing `path` (an entry, not a placeholder).
    pub fn row_of(&self, path: &str) -> Option<usize> {
        if path.is_empty() {
            return None;
        }
        self.rows
            .iter()
            .position(|r| r.path == path && r.is_entry())
    }

    /// A loaded folder's entries ("" the top) as `{path, name, directory}`,
    /// folders first: what the viewer's path trail offers beside a file.
    pub fn entries_in(&self, folder: &str) -> Vec<Json> {
        let Some(listed) = self
            .folders
            .get(folder)
            .filter(|f| f.state == State::Loaded)
        else {
            return Vec::new();
        };
        listed
            .children
            .iter()
            .map(|c| json!({"path": c.path, "name": name_of(&c.path), "directory": c.directory}))
            .collect()
    }

    /// The visible paths, in order, for tests and keyboard walking.
    pub fn visible_paths(&self) -> Vec<String> {
        self.rows
            .iter()
            .filter(|r| r.is_entry())
            .map(|r| r.path.clone())
            .collect()
    }

    pub fn take_notes(&mut self) -> Vec<TreeNote> {
        std::mem::take(&mut self.notes)
    }
}

impl RowSource for FileTree {
    fn roles(&self) -> &'static [&'static str] {
        ROLES
    }

    fn row_count(&self) -> usize {
        self.rows.len()
    }

    fn row_key(&self, row: usize) -> RowKey {
        self.rows.get(row).map_or(row as RowKey, |r| r.key)
    }

    fn data(&self, row: usize, role: &str) -> Value {
        let Some(row) = self.rows.get(row) else {
            return Value::Undefined;
        };
        match role {
            "path" => Value::from(row.path.as_str()),
            "name" => Value::from(name_of(&row.path)),
            "depth" => Value::Int(int(row.depth)),
            "kind" => Value::from(row.kind),
            "expanded" => Value::Bool(row.kind == "directory" && self.is_expanded(&row.path)),
            "ignored" => Value::Bool(row.ignored),
            "problem" if row.kind == "error" => Value::from(
                self.shown()
                    .get(&row.path)
                    .map_or("", |f| f.problem.as_str()),
            ),
            "problem" => Value::from(""),
            "selected" => Value::Bool(
                !self.selected.is_empty() && row.path == self.selected && row.is_entry(),
            ),
            _ => Value::Undefined,
        }
    }

    fn take_changes(&mut self) -> Vec<RowChange> {
        std::mem::take(&mut self.changes)
    }
}

/// Lists a folder the tree asked for ("" the top); the answer comes back
/// through [`FileTreeModel::update`].
pub type Fetch = Rc<dyn Fn(&Engine, ObjectId, &str)>;

struct Inner {
    rows: Rc<ListRows<FileTree>>,
    fetch: Fetch,
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FileTree")
            .field("rows", &self.rows)
            .finish_non_exhaustive()
    }
}

/// A project's folders as rows: the Files tab's tree.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "FileTreeModel", uncreatable)]
pub struct FileTreeModel {
    /// loading, ready or error (with rootProblem).
    #[qml(readonly, notify)]
    root_status: Atom,
    #[qml(readonly, notify)]
    root_problem: Atom,
    #[qml(readonly, notify)]
    selected_path: Atom,
    /// A search's tree is on screen.
    #[qml(readonly, notify)]
    filtered: bool,
    #[qml(readonly, notify)]
    all_expanded: bool,
    #[qml(skip)]
    inner: Inner,
}

fn inner_of(engine: &Engine, obj: ObjectId) -> Option<(Rc<ListRows<FileTree>>, Fetch)> {
    engine
        .with::<FileTreeModel, _>(obj, |m| (m.inner.rows.clone(), m.inner.fetch.clone()))
        .ok()
}

impl FileTreeModel {
    /// An empty tree owned by `owner`, which lists the folders it asks for
    /// with `fetch`.
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        fetch: impl Fn(&Engine, ObjectId, &str) + 'static,
    ) -> Result<ObjectId, EngineError> {
        let rows = ListRows::new(FileTree::new());
        let model = FileTreeModel {
            root_status: Atom::new("loading"),
            root_problem: Atom::new(""),
            selected_path: Atom::new(""),
            filtered: false,
            all_expanded: false,
            inner: Inner {
                rows: rows.clone(),
                fetch: Rc::new(fetch),
            },
        };
        let obj = engine.create_native(model, owner)?;
        rows.attach(engine, obj)?;
        Ok(obj)
    }

    /// Runs `f` on the tree of `obj`, then tells the views, the properties,
    /// the signals and the fetch what it changed. None when `obj` is not a
    /// live FileTreeModel.
    pub fn update<R>(
        engine: &Engine,
        obj: ObjectId,
        f: impl FnOnce(&mut FileTree) -> R,
    ) -> Option<R> {
        let (rows, fetch) = inner_of(engine, obj)?;
        let result = rows.update(engine, f);
        loop {
            let notes = rows.update(engine, FileTree::take_notes);
            if notes.is_empty() {
                break;
            }
            for note in notes {
                tell(engine, obj, &rows, &fetch, note);
            }
        }
        Some(result)
    }

    /// Reads the tree of `obj`. `f` must not call back into it.
    pub fn read<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&FileTree) -> R) -> Option<R> {
        let (rows, _) = inner_of(engine, obj)?;
        Some(rows.read(f))
    }
}

fn tell(engine: &Engine, obj: ObjectId, rows: &ListRows<FileTree>, fetch: &Fetch, note: TreeNote) {
    let cx = Cx::new(engine, obj);
    let result = match note {
        TreeNote::Root => {
            let (status, problem, filtered) = rows.read(|t| {
                (
                    Atom::new(t.root_status()),
                    Atom::new(t.root_problem()),
                    t.filtered(),
                )
            });
            engine
                .set_internal(obj, FileTreeModel::ROOT_STATUS, status)
                .and_then(|()| engine.set_internal(obj, FileTreeModel::ROOT_PROBLEM, problem))
                .and_then(|()| engine.set_internal(obj, FileTreeModel::FILTERED, filtered))
                .and_then(|()| FileTreeModel::emit_root_changed(&cx))
        }
        TreeNote::Selected => {
            let path = rows.read(|t| Atom::new(t.selected_path()));
            engine
                .set_internal(obj, FileTreeModel::SELECTED_PATH, path)
                .and_then(|()| FileTreeModel::emit_selected_changed(&cx))
        }
        TreeNote::AllExpanded => {
            let all = rows.read(FileTree::all_expanded);
            engine.set_internal(obj, FileTreeModel::ALL_EXPANDED, all)
        }
        TreeNote::Settled(folder) => FileTreeModel::emit_folder_settled(&cx, Atom::new(&folder)),
        TreeNote::Fetch(folder) => {
            fetch(engine, obj, &folder);
            Ok(())
        }
    };
    if let Err(e) = result {
        engine.log(
            ljos::prelude::LogLevel::Warning,
            "FileTreeModel",
            e.to_string(),
        );
    }
}

#[qml_impl]
impl FileTreeModel {
    /// rootStatus, rootProblem or filtered changed.
    #[qml(signal)]
    fn root_changed();
    #[qml(signal)]
    fn selected_changed();
    /// A folder's children landed (or failed).
    #[qml(signal)]
    fn folder_settled(folder: Atom);

    #[qml(invokable)]
    fn toggle(cx: &Cx, path: Atom) {
        FileTreeModel::update(cx.engine, cx.this, |t| t.toggle(&path));
    }

    #[qml(invokable)]
    fn expand(cx: &Cx, path: Atom) {
        FileTreeModel::update(cx.engine, cx.this, |t| t.expand(&path));
    }

    #[qml(invokable)]
    fn collapse(cx: &Cx, path: Atom) {
        FileTreeModel::update(cx.engine, cx.this, |t| t.collapse(&path));
    }

    #[qml(invokable)]
    fn expand_all(cx: &Cx) {
        FileTreeModel::update(cx.engine, cx.this, FileTree::expand_all);
    }

    #[qml(invokable)]
    fn collapse_all(cx: &Cx) {
        FileTreeModel::update(cx.engine, cx.this, FileTree::collapse_all);
    }

    #[qml(invokable)]
    fn retry(cx: &Cx, folder: Atom) {
        FileTreeModel::update(cx.engine, cx.this, |t| t.retry(&folder));
    }

    #[qml(invokable)]
    fn select(cx: &Cx, path: Atom) {
        FileTreeModel::update(cx.engine, cx.this, |t| t.select(&path));
    }

    /// The row showing `path`, or -1.
    #[qml(invokable)]
    fn row_of(cx: &Cx, path: Atom) -> i32 {
        FileTreeModel::read(cx.engine, cx.this, |t| t.row_of(&path))
            .flatten()
            .map_or(-1, int)
    }

    /// A loaded folder's entries as `{path, name, directory}`.
    #[qml(invokable)]
    fn entries_in(cx: &Cx, folder: Atom) -> Value {
        let entries = FileTreeModel::read(cx.engine, cx.this, |t| t.entries_in(&folder));
        json::to_value(cx.engine, &Json::Array(entries.unwrap_or_default()))
    }
}

#[cfg(test)]
#[path = "file_tree_tests.rs"]
mod tests;
