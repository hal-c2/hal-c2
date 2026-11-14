//! FileTreeModel's core: tst_WorkspaceTreeRegression's cases and
//! tst_WorkspaceTreeProp's state machine.

use std::collections::{BTreeMap, BTreeSet};

use ljos::prelude::Value;
use proptest::prelude::*;

use super::super::rows::{Mirror, RowSource};
use super::{Entry, FileTree, TreeNote, name_of, parent_of};

fn s(v: &Value) -> String {
    match v {
        Value::String(a) => (**a).to_owned(),
        _ => String::new(),
    }
}

fn n(v: &Value) -> usize {
    match v {
        Value::Int(i) => usize::try_from(*i).unwrap_or(0),
        _ => 0,
    }
}

fn b(v: &Value) -> bool {
    matches!(v, Value::Bool(true))
}

/// "path kind" per row, as the regression tests compare them.
fn kinds(tree: &FileTree) -> Vec<String> {
    (0..tree.row_count())
        .map(|r| format!("{} {}", s(&tree.data(r, "path")), s(&tree.data(r, "kind"))))
        .collect()
}

fn fetches(tree: &mut FileTree) -> Vec<String> {
    tree.take_notes()
        .into_iter()
        .filter_map(|note| match note {
            TreeNote::Fetch(folder) => Some(folder),
            _ => None,
        })
        .collect()
}

fn folder(path: &str) -> Entry {
    Entry::new(path, true, false)
}

fn file(path: &str) -> Entry {
    Entry::new(path, false, false)
}

// Reloading showed no rows at all until the top folder was listed, where a
// folder loading anywhere else (and the top one after collapseAll) shows a
// "loading" row.
#[test]
fn reload_shows_the_top_folder_loading() {
    let mut tree = FileTree::new();
    tree.reload();
    assert_eq!(kinds(&tree), [" loading"]);
    assert_eq!(fetches(&mut tree), [""]);
    assert_eq!(tree.root_status(), "loading");
}

// A folder the search matched but did not list, expanded during the search,
// asked for its children and then kept its "loading" row: the listing
// landed only in the user's tree.
#[test]
fn a_folder_opened_during_a_search_shows_its_listing() {
    let mut tree = FileTree::new();
    tree.reload();
    tree.set_listing("", vec![folder("a")]);
    tree.set_search(Some(vec![folder("a")]));
    tree.take_notes();
    tree.expand("a");
    assert_eq!(fetches(&mut tree), ["a"]);
    tree.set_listing("a", vec![file("a/x")]);
    assert_eq!(kinds(&tree), ["a directory", "a/x file"]);
}

// The same folder already listed in the user's tree was asked for again
// rather than shown.
#[test]
fn a_folder_opened_during_a_search_reuses_the_users_listing() {
    let mut tree = FileTree::new();
    tree.reload();
    tree.set_listing("", vec![folder("a")]);
    tree.expand("a");
    tree.set_listing("a", vec![file("a/x")]);
    tree.set_search(Some(vec![folder("a")]));
    tree.take_notes();
    tree.expand("a");
    assert!(fetches(&mut tree).is_empty());
    assert_eq!(kinds(&tree), ["a directory", "a/x file"]);
}

// Retrying a folder during a search marked the search's copy loading and
// left the user's tree failed, so the listing never showed in either.
#[test]
fn retry_during_a_search_lists_the_folder_again() {
    let mut tree = FileTree::new();
    tree.reload();
    tree.set_listing("", vec![folder("a")]);
    tree.expand("a");
    tree.set_failed("a", "no such folder");
    tree.set_search(Some(vec![folder("a")]));
    tree.expand("a");
    assert_eq!(kinds(&tree), ["a directory", "a error"]);
    assert_eq!(s(&tree.data(1, "problem")), "no such folder");
    tree.retry("a");
    assert_eq!(kinds(&tree), ["a directory", "a loading"]);
    tree.set_listing("a", vec![file("a/x")]);
    assert_eq!(kinds(&tree), ["a directory", "a/x file"]);
    tree.set_search(None);
    assert_eq!(kinds(&tree), ["a directory", "a/x file"]);
}

#[test]
fn folders_come_first_and_names_sort_as_people_read_them() {
    let mut tree = FileTree::new();
    tree.reload();
    tree.set_listing("", vec![file("b"), folder("Z"), file("A"), folder("c")]);
    assert_eq!(
        kinds(&tree),
        ["c directory", "Z directory", "A file", "b file"]
    );
    let entries = tree.entries_in("");
    assert_eq!(entries[0]["name"], "c");
    assert_eq!(entries[0]["directory"], true);
    assert!(tree.entries_in("c").is_empty(), "c is not listed yet");
}

// tst_WorkspaceTreeProp: the Files tab's tree as the user sees it while
// folders are expanded, collapsed and listed in any order, listings land
// late (for a folder already collapsed, or under one that is), fail and are
// retried, the workspace changes on disk and is listed again, a search swaps
// its own tree in and out, and every folder is expanded or collapsed at
// once.

const DIRECTORIES: &[&str] = &["a", "a/b", "c", "n"];
const FILES: &[&str] = &["R", "a/x", "a/b/y", "c/z", "n/q"];
/// Files the agent creates and deletes.
const OPTIONAL: &[&str] = &["a/new", "Z", "c/Big"];

fn is_directory(path: &str) -> bool {
    DIRECTORIES.contains(&path)
}

/// Git ignores `n`, so expanding everything leaves it closed.
fn is_ignored(path: &str) -> bool {
    path == "n" || path.starts_with("n/")
}

fn entry_of(path: &str) -> Entry {
    Entry::new(path, is_directory(path), is_ignored(path))
}

fn sorted(mut entries: Vec<Entry>) -> Vec<Entry> {
    super::sort_entries(&mut entries);
    entries
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
    children: Vec<Entry>,
    expanded: bool,
}

#[derive(Clone, Debug)]
struct Model {
    /// The files on disk.
    present: BTreeSet<String>,
    user: BTreeMap<String, Folder>,
    search: BTreeMap<String, Folder>,
    searching: bool,
    expand_all: bool,
    /// Folders asked for and not answered, as a multiset.
    pending: Vec<String>,
    selected: String,
}

impl Default for Model {
    fn default() -> Model {
        Model {
            present: FILES.iter().map(|f| (*f).to_owned()).collect(),
            user: BTreeMap::new(),
            search: BTreeMap::new(),
            searching: false,
            expand_all: false,
            pending: Vec::new(),
            selected: String::new(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Row {
    path: String,
    depth: usize,
    kind: String,
    expanded: bool,
    ignored: bool,
    selected: bool,
}

impl Model {
    fn shown(&self) -> &BTreeMap<String, Folder> {
        if self.searching {
            &self.search
        } else {
            &self.user
        }
    }

    fn shown_mut(&mut self) -> &mut BTreeMap<String, Folder> {
        if self.searching {
            &mut self.search
        } else {
            &mut self.user
        }
    }

    fn listing(&self, folder: &str) -> Vec<Entry> {
        let entries = DIRECTORIES
            .iter()
            .copied()
            .chain(self.present.iter().map(String::as_str))
            .filter(|path| parent_of(path) == folder)
            .map(entry_of)
            .collect();
        sorted(entries)
    }

    fn fetch(&mut self, folder: &str) {
        self.pending.push(folder.to_owned());
    }

    fn expand(&mut self, path: &str) {
        let searching = self.searching;
        let folder = self.shown_mut().entry(path.to_owned()).or_default();
        if folder.expanded {
            return;
        }
        folder.expanded = true;
        if folder.state != State::Unloaded {
            return;
        }
        if !searching {
            folder.state = State::Loading;
            self.fetch(path);
            return;
        }
        // A folder the search did not list shows what the user's tree has
        // of it, listed once for both.
        let listed = self.user.entry(path.to_owned()).or_default();
        if listed.state == State::Unloaded {
            listed.state = State::Loading;
            self.fetch(path);
        }
        let listed = self.user[path].clone();
        let folder = self.search.get_mut(path).unwrap();
        folder.state = listed.state;
        folder.children = listed.children;
    }

    fn expand_under(&mut self, path: &str) {
        let children = self
            .user
            .get(path)
            .map(|f| f.children.clone())
            .unwrap_or_default();
        for child in children {
            if !child.directory || child.ignored {
                continue;
            }
            if self.searching {
                let folder = self.user.entry(child.path.clone()).or_default();
                folder.expanded = true;
                if folder.state == State::Unloaded {
                    folder.state = State::Loading;
                    self.fetch(&child.path);
                }
            } else {
                self.expand(&child.path);
            }
            self.expand_under(&child.path);
        }
    }

    fn answer(&mut self, path: &str, ok: bool) {
        if let Some(at) = self.pending.iter().position(|p| p == path) {
            self.pending.remove(at);
        }
        let children = if ok { self.listing(path) } else { Vec::new() };
        let folder = self.user.entry(path.to_owned()).or_default();
        folder.state = if ok { State::Loaded } else { State::Failed };
        folder.children = children;
        let folder = folder.clone();
        if self.searching
            && let Some(shown) = self.search.get_mut(path)
            && shown.state == State::Loading
        {
            shown.state = folder.state;
            shown.children = folder.children;
        }
        if ok && self.expand_all {
            self.expand_under(path);
        }
    }

    fn is_open(&self, path: &str) -> bool {
        self.shown().get(path).is_some_and(|f| f.expanded)
    }

    fn rows_under(&self, path: &str, depth: usize, rows: &mut Vec<Row>) {
        let folder = self.shown().get(path).cloned().unwrap_or_default();
        let placeholder = |kind: &str| Row {
            path: path.to_owned(),
            depth,
            kind: kind.to_owned(),
            expanded: false,
            ignored: false,
            selected: false,
        };
        match folder.state {
            State::Loading => rows.push(placeholder("loading")),
            State::Failed => rows.push(placeholder("error")),
            State::Loaded => {
                for child in &folder.children {
                    let open = child.directory && self.is_open(&child.path);
                    rows.push(Row {
                        path: child.path.clone(),
                        depth,
                        kind: if child.directory { "directory" } else { "file" }.to_owned(),
                        expanded: open,
                        ignored: child.ignored,
                        selected: !self.selected.is_empty() && child.path == self.selected,
                    });
                    if open {
                        self.rows_under(&child.path, depth + 1, rows);
                    }
                }
            }
            State::Unloaded => {}
        }
    }

    fn rows(&self) -> Vec<Row> {
        let mut rows = Vec::new();
        if self.is_open("") {
            self.rows_under("", 0, &mut rows);
        }
        rows
    }

    fn root_status(&self) -> &'static str {
        match self.shown().get("").map(|f| f.state) {
            Some(State::Loaded) => "ready",
            Some(State::Failed) => "error",
            _ => "loading",
        }
    }
}

fn rows_of(tree: &FileTree) -> Vec<Row> {
    (0..tree.row_count())
        .map(|r| Row {
            path: s(&tree.data(r, "path")),
            depth: n(&tree.data(r, "depth")),
            kind: s(&tree.data(r, "kind")),
            expanded: b(&tree.data(r, "expanded")),
            ignored: b(&tree.data(r, "ignored")),
            selected: b(&tree.data(r, "selected")),
        })
        .collect()
}

#[derive(Clone, Debug)]
enum Action {
    Reload,
    Expand(&'static str),
    Collapse(&'static str),
    /// The MC answers one of the folders asked for, as the disk is now, or
    /// fails.
    Answer(prop::sample::Index, bool),
    Retry(&'static str),
    /// The agent changed the workspace: every listed folder is asked for
    /// again.
    Refresh,
    /// A file appears on disk or goes.
    Touch(&'static str),
    ExpandAll,
    CollapseAll,
    Search(Vec<&'static str>),
    EndSearch,
    Select(&'static str),
}

fn action() -> impl Strategy<Value = Action> {
    let directory = prop::sample::select(DIRECTORIES);
    let anything: Vec<&'static str> = DIRECTORIES
        .iter()
        .chain(FILES)
        .chain(OPTIONAL)
        .copied()
        .collect();
    let touched: Vec<&'static str> = OPTIONAL.iter().copied().chain(["R"]).collect();
    let retried: Vec<&'static str> = [""]
        .into_iter()
        .chain(DIRECTORIES.iter().copied())
        .collect();
    let selected: Vec<&'static str> = DIRECTORIES
        .iter()
        .chain(FILES)
        .copied()
        .chain([""])
        .collect();
    prop_oneof![
        1 => Just(Action::Reload),
        2 => directory.clone().prop_map(Action::Expand),
        1 => directory.prop_map(Action::Collapse),
        3 => (any::<prop::sample::Index>(), prop::bool::weighted(0.8))
            .prop_map(|(at, ok)| Action::Answer(at, ok)),
        1 => prop::sample::select(retried).prop_map(Action::Retry),
        1 => Just(Action::Refresh),
        1 => prop::sample::select(touched).prop_map(Action::Touch),
        1 => Just(Action::ExpandAll),
        1 => Just(Action::CollapseAll),
        1 => prop::collection::vec(prop::sample::select(anything), 0..4).prop_map(Action::Search),
        1 => Just(Action::EndSearch),
        1 => prop::sample::select(selected).prop_map(Action::Select),
    ]
}

fn step(
    model: &mut Model,
    tree: &mut FileTree,
    fetched: &mut Vec<String>,
    mirror: &mut Mirror,
    action: &Action,
) -> Result<(), TestCaseError> {
    let before = model.clone();
    match action {
        Action::Reload => {
            // A search on screen stays; the user's tree starts over behind
            // it.
            model.user.clear();
            model.expand_all = false;
            if !model.searching {
                model.selected.clear();
            }
            // The owner drops answers to what it asked before
            // (WorkspaceFiles' generation).
            model.pending.clear();
            let root = model.user.entry(String::new()).or_default();
            root.expanded = true;
            root.state = State::Loading;
            model.fetch("");
            fetched.clear();
            tree.reload();
        }
        Action::Expand(path) => {
            model.expand(path);
            tree.expand(path);
        }
        Action::Collapse(path) => {
            model
                .shown_mut()
                .entry((*path).to_owned())
                .or_default()
                .expanded = false;
            tree.collapse(path);
        }
        Action::Answer(at, ok) => {
            if model.pending.is_empty() {
                return Ok(());
            }
            let path = model.pending[at.index(model.pending.len())].clone();
            let listing = model.listing(&path);
            model.answer(&path, *ok);
            if let Some(at) = fetched.iter().position(|p| *p == path) {
                fetched.remove(at);
            }
            if *ok {
                tree.set_listing(&path, listing);
            } else {
                tree.set_failed(&path, "no such folder");
            }
        }
        Action::Retry(path) => {
            if model.user.get(*path).map(|f| f.state) == Some(State::Failed) {
                model.user.get_mut(*path).unwrap().state = State::Loading;
                model.fetch(path);
                if model.searching
                    && let Some(shown) = model.search.get_mut(*path)
                    && shown.state == State::Failed
                {
                    shown.state = State::Loading;
                }
            }
            tree.retry(path);
        }
        Action::Refresh => {
            let loaded: Vec<String> = model
                .user
                .iter()
                .filter(|(_, f)| f.state == State::Loaded)
                .map(|(p, _)| p.clone())
                .collect();
            for folder in loaded {
                model.fetch(&folder);
            }
            tree.refresh();
        }
        Action::Touch(path) => {
            if !model.present.remove(*path) {
                model.present.insert((*path).to_owned());
            }
        }
        Action::ExpandAll => {
            model.expand_all = true;
            model.expand_under("");
            tree.expand_all();
        }
        Action::CollapseAll => {
            model.expand_all = false;
            for (path, folder) in &mut model.user {
                folder.expanded = path.is_empty();
            }
            tree.collapse_all();
        }
        Action::Search(matches) => {
            model.searching = true;
            model.search.clear();
            model.search.insert(
                String::new(),
                Folder {
                    state: State::Loaded,
                    children: Vec::new(),
                    expanded: true,
                },
            );
            let mut listed = BTreeSet::new();
            let mut add = |search: &mut BTreeMap<String, Folder>, entry: Entry| {
                if listed.insert(entry.path.clone()) {
                    let parent = parent_of(&entry.path).to_owned();
                    search.entry(parent).or_default().children.push(entry);
                }
            };
            for found in matches {
                // A match's folders are listed as plain folders.
                let mut folder = parent_of(found);
                while !folder.is_empty() {
                    add(&mut model.search, Entry::new(folder, true, false));
                    folder = parent_of(folder);
                }
                add(&mut model.search, entry_of(found));
            }
            for folder in model.search.values_mut() {
                folder.state = State::Loaded;
                folder.expanded = true;
                folder.children = sorted(std::mem::take(&mut folder.children));
            }
            tree.set_search(Some(matches.iter().map(|m| entry_of(m)).collect()));
        }
        Action::EndSearch => {
            model.searching = false;
            model.search.clear();
            tree.set_search(None);
        }
        Action::Select(path) => {
            (*path).clone_into(&mut model.selected);
            tree.select(path);
        }
    }
    // The rows, the folders asked for, the tree's properties and their
    // signals.
    let notes = tree.take_notes();
    for note in &notes {
        if let TreeNote::Fetch(folder) = note {
            fetched.push(folder.clone());
        }
    }
    prop_assert_eq!(rows_of(tree), model.rows());
    let mut asked = fetched.clone();
    let mut pending = model.pending.clone();
    asked.sort();
    pending.sort();
    prop_assert_eq!(asked, pending);
    prop_assert_eq!(tree.root_status(), model.root_status());
    prop_assert_eq!(tree.selected_path(), model.selected.as_str());
    prop_assert_eq!(tree.filtered(), model.searching);
    prop_assert_eq!(tree.all_expanded(), model.expand_all);
    let count = |wanted: &TreeNote| notes.iter().filter(|n| *n == wanted).count();
    prop_assert_eq!(
        count(&TreeNote::Selected),
        usize::from(before.selected != model.selected)
    );
    prop_assert_eq!(
        count(&TreeNote::AllExpanded),
        usize::from(before.expand_all != model.expand_all)
    );
    if before.root_status() != model.root_status() || before.searching != model.searching {
        prop_assert!(count(&TreeNote::Root) > 0, "the root changed unsaid");
    }
    mirror.follow(tree);
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 256, ..ProptestConfig::default() })]

    /// The file tree shows what was listed of the folders the user opened.
    #[test]
    fn the_tree_shows_what_was_listed_of_the_folders_the_user_opened(
        actions in prop::collection::vec(action(), 1..50)
    ) {
        let mut model = Model::default();
        let mut tree = FileTree::new();
        let mut fetched = Vec::new();
        let mut mirror = Mirror::of(&mut tree);
        for action in &actions {
            step(&mut model, &mut tree, &mut fetched, &mut mirror, action)?;
        }
    }
}

#[test]
fn names_are_the_last_part_of_a_path() {
    assert_eq!(name_of("a/b/c.txt"), "c.txt");
    assert_eq!(name_of("top"), "top");
    assert_eq!(parent_of("a/b/c.txt"), "a/b");
    assert_eq!(parent_of("top"), "");
}
