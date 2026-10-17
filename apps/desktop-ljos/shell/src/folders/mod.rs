//! `LocalFolderModel` in `HalC2.Shell`, desktop-qt's QFileSystemModel
//! subclass of the same name: the folders under a root the user chose, to
//! browse, and create, rename, move or trash a folder in, without ever
//! leaving the root, following a link, or touching a project's folder.
//!
//! Ljós has no tree models (its views read flat rows; TODO(ljos#27)), so the
//! model is the tree's *visible rows*: a row is an entry under the root whose
//! parents are all expanded, with its `depth` and whether it is `expanded`.
//! `toggleExpanded` and `setExpanded` open and close a folder, as the
//! tree view's expand arrow does. A folder is read when it is first opened,
//! off the Engine thread, and again when the OS says something changed in a
//! folder that is open (see `watch.rs`). QML's `rootIndex` is, here, `0`
//! while there is a root to show and `-1` otherwise, and a row is addressed
//! by its position (`pathForIndex(row)`).
//!
//! Not ported: the system file icons (`QFileSystemModel` decoration), and a
//! write of `rootPath` to the path it already has does not clear `error`.

mod plain;
mod watch;

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use ljos::prelude::{
    Atom, Cx, Engine, EngineError, ModelSignals, ObjectId, QmlListModel, QmlObject, QtObject,
    Value, qml_impl,
};

use crate::json::{self, Json};
use plain::{broad_directory, clean, occupied, plain_directory, plain_entry, within};
pub use watch::{deliver, set_wake};

const NO_ROOT: &str = "The selected root is no longer a plain local folder.";
const BAD_ROOT: &str = "Choose an existing local folder other than your home or a filesystem root. Symlinks are not supported.";
const DISABLED: &str = "Local folder access is disabled or no root folder is selected.";
const OUTSIDE: &str = "Choose a plain folder inside the selected root. The root itself, home, symlinks and outside paths cannot be changed.";
const BAD_NAME: &str =
    "Enter one folder name, without path separators or leading/trailing whitespace.";
const PROTECTED: &str = "This folder contains a registered project. Its location is protected because threads may still use that path.";
const EXISTS: &str = "A file or folder already exists with that name.";
const NOT_CREATED: &str = "The folder could not be created. Check permissions.";
const DESTINATION_EXISTS: &str = "The destination already exists. Nothing was overwritten.";
const NOT_MOVED: &str =
    "The folder could not be moved. Check permissions and keep it on the same filesystem.";
const INTO_ITSELF: &str = "A folder cannot be moved into itself or one of its descendants.";
const CONFIRM: &str = "Confirm by entering the exact full folder path.";
const NOT_TRASHED: &str =
    "The folder could not be moved to the system trash. It has not been permanently deleted.";

/// Adds the model to the `HalC2.Shell` module.
pub fn register(engine: &Engine) {
    engine.register_module(ljos::module!("HalC2.Shell" 1.0 => [LocalFolderModel]));
}

/// What moves a folder to the system Trash; false leaves it where it is.
type Trash = Rc<dyn Fn(&str) -> bool>;

#[derive(Default)]
struct Env {
    trash: RefCell<Option<Trash>>,
}

/// Replaces what moves a folder to the system Trash (a test's, or a
/// machine with none). Applies to every model of the engine.
pub fn set_trash(engine: &Engine, trash: impl Fn(&str) -> bool + 'static) {
    *engine.extension::<Env>().trash.borrow_mut() = Some(Rc::new(trash));
}

fn trash_of(engine: &Engine) -> Trash {
    engine
        .extension::<Env>()
        .trash
        .borrow()
        .clone()
        .unwrap_or_else(|| Rc::new(|path: &str| trash::delete(path).is_ok()))
}

#[derive(QmlObject)]
// TODO(ljos#46): a native type without `extends` has no `objectName`, which
// FolderExplorer.qml sets; QtObject as the base gives it one.
#[qml(module = "HalC2.Shell", name = "LocalFolderModel", extends = QtObject)]
pub struct LocalFolderModel {
    #[qml(base)]
    base: QtObject,
    #[qml(notify)]
    enabled: bool,
    /// The root as a real path: what is written is checked, and an
    /// unacceptable one gives the property back its last good value (none).
    #[qml(notify)]
    root_path: Atom,
    #[qml(notify, readonly)]
    root_index: i32,
    #[qml(notify)]
    protected_paths: Value,
    #[qml(notify, readonly)]
    error: Atom,
    #[qml(skip)]
    state: Rc<State>,
}

impl Default for LocalFolderModel {
    fn default() -> Self {
        LocalFolderModel {
            base: QtObject::default(),
            enabled: false,
            root_path: Atom::from(""),
            root_index: -1,
            protected_paths: Value::Undefined,
            error: Atom::from(""),
            state: Rc::default(),
        }
    }
}

#[qml_impl]
impl LocalFolderModel {
    #[qml(signal)]
    fn root_changed();

    #[qml(on_complete)]
    fn completed(cx: &Cx) -> Result<(), EngineError> {
        let model = Model::of(cx).ok_or(EngineError::DeadObject(cx.this))?;
        model.start()
    }

    /// The real path of row `row`, when it is a plain entry inside the root.
    #[qml(invokable)]
    fn path_for_index(cx: &Cx, row: i32) -> String {
        Model::of(cx).map_or_else(String::new, |m| m.path_for_index(row))
    }

    #[qml(invokable)]
    fn is_directory(cx: &Cx, path: Atom) -> bool {
        Model::of(cx).is_some_and(|m| m.is_directory(&path))
    }

    #[qml(invokable)]
    fn can_modify_folder(cx: &Cx, path: Atom) -> bool {
        Model::of(cx).is_some_and(|m| m.can_modify_folder(&path))
    }

    /// Whether a folder inside the root is, or holds, a registered project.
    #[qml(invokable)]
    fn holds_project(cx: &Cx, path: Atom) -> bool {
        Model::of(cx).is_some_and(|m| m.holds_project(&path))
    }

    #[qml(invokable)]
    fn create_folder(cx: &Cx, parent_path: Atom, name: Atom) -> String {
        Model::of(cx).map_or_else(String::new, |m| m.create_folder(&parent_path, &name))
    }

    #[qml(invokable)]
    fn rename_folder(cx: &Cx, path: Atom, new_name: Atom) -> String {
        Model::of(cx).map_or_else(String::new, |m| m.rename_folder(&path, &new_name))
    }

    #[qml(invokable)]
    fn move_folder(cx: &Cx, path: Atom, destination_directory: Atom) -> String {
        Model::of(cx).map_or_else(String::new, |m| {
            m.move_folder(&path, &destination_directory)
        })
    }

    #[qml(invokable)]
    fn trash_folder(cx: &Cx, path: Atom, confirmation_path: Atom) -> bool {
        Model::of(cx).is_some_and(|m| m.trash_folder(&path, &confirmation_path))
    }

    /// Opens or closes the folder at `row`.
    #[qml(invokable)]
    fn set_expanded(cx: &Cx, row: i32, expanded: bool) {
        if let Some(m) = Model::of(cx) {
            m.set_expanded(row, expanded);
        }
    }

    #[qml(invokable)]
    fn toggle_expanded(cx: &Cx, row: i32) {
        if let Some(m) = Model::of(cx) {
            m.toggle_expanded(row);
        }
    }
}

/// An entry of a folder as it was read.
#[derive(Clone, Debug, PartialEq)]
struct Node {
    name: String,
    path: String,
    is_dir: bool,
}

/// A visible row.
#[derive(Clone, Debug, PartialEq)]
struct Row {
    node: Node,
    depth: usize,
}

#[derive(Default)]
struct Tree {
    /// Folders that were read, by path.
    children: HashMap<String, Vec<Node>>,
    /// Folders that are open, whether or not they are shown.
    expanded: HashSet<String>,
    /// Folders being read.
    loading: HashSet<String>,
    rows: Vec<Row>,
}

impl Tree {
    /// The rows under `dir` (at `depth`): its entries, each followed by its
    /// own when open and read.
    fn flatten(&self, dir: &str, depth: usize, out: &mut Vec<Row>) {
        for node in self.children.get(dir).into_iter().flatten() {
            out.push(Row {
                node: node.clone(),
                depth,
            });
            if node.is_dir && self.expanded.contains(&node.path) {
                self.flatten(&node.path, depth + 1, out);
            }
        }
    }

    /// The rows after row `at` that are inside it.
    fn subtree_end(&self, at: usize) -> usize {
        let depth = self.rows[at].depth;
        self.rows[at + 1..]
            .iter()
            .position(|r| r.depth <= depth)
            .map_or(self.rows.len(), |n| at + 1 + n)
    }
}

/// The model's own state: what lives beside the properties. The rows are
/// read through [`Rows`], which Ljós's views follow.
struct State {
    enabled: Cell<bool>,
    root: RefCell<String>,
    tree: RefCell<Tree>,
    signals: RefCell<Option<ModelSignals>>,
    /// Bumped whenever the rows start over: a read that finishes later is
    /// for rows that are gone.
    generation: Cell<u64>,
    watch: RefCell<Option<watch::Watch>>,
}

impl Default for State {
    fn default() -> Self {
        State {
            enabled: Cell::new(false),
            root: RefCell::default(),
            tree: RefCell::default(),
            signals: RefCell::default(),
            generation: Cell::new(0),
            watch: RefCell::default(),
        }
    }
}

/// `State` as the rows Ljós's views read.
struct Rows(Rc<State>);

impl QmlListModel for Rows {
    fn row_count(&self) -> usize {
        self.0.tree.borrow().rows.len()
    }

    fn role_names(&self) -> Vec<Atom> {
        [
            "fileName",
            "filePath",
            "isDirectory",
            "hasChildren",
            "depth",
            "expanded",
        ]
        .map(Atom::from)
        .to_vec()
    }

    fn data(&self, row: usize, role: &str) -> Value {
        let tree = self.0.tree.borrow();
        let Some(row) = tree.rows.get(row) else {
            return Value::Undefined;
        };
        match role {
            "fileName" => Value::from(row.node.name.as_str()),
            "filePath" => Value::from(row.node.path.as_str()),
            "isDirectory" | "hasChildren" => Value::Bool(row.node.is_dir),
            "depth" => Value::Int(row.depth as i32),
            "expanded" => Value::Bool(row.node.is_dir && tree.expanded.contains(&row.node.path)),
            _ => Value::Undefined,
        }
    }

    fn row_key(&self, row: usize) -> u64 {
        let tree = self.0.tree.borrow();
        let mut hasher = std::hash::DefaultHasher::new();
        tree.rows.get(row).map(|r| &r.node.path).hash(&mut hasher);
        hasher.finish()
    }
}

/// One object's model, for the length of a call.
struct Model<'e> {
    engine: &'e Engine,
    obj: ObjectId,
    state: Rc<State>,
}

impl<'e> Model<'e> {
    fn new(engine: &'e Engine, obj: ObjectId, state: Rc<State>) -> Self {
        Model { engine, obj, state }
    }

    fn of(cx: &Cx<'e>) -> Option<Self> {
        let state = cx.with::<LocalFolderModel, _>(|m| m.state.clone()).ok()?;
        Some(Model::new(cx.engine, cx.this, state))
    }

    fn cx(&self) -> Cx<'e> {
        Cx::new(self.engine, self.obj)
    }

    /// Makes the object the rows' model and follows what QML writes.
    fn start(&self) -> Result<(), EngineError> {
        let signals = self
            .engine
            .set_list_model(self.obj, Rc::new(Rows(self.state.clone())))?;
        *self.state.signals.borrow_mut() = Some(signals);
        *self.state.watch.borrow_mut() =
            Some(watch::Watch::new(self.engine, self.obj, &self.state));
        let (engine, obj) = (self.engine, self.obj);
        let again = move |e: &Engine, state: &dyn Fn(&Model)| {
            if let Some(state_of) = e
                .with::<LocalFolderModel, _>(obj, |m| m.state.clone())
                .ok()
                .map(|s| Model::new(e, obj, s))
            {
                state(&state_of);
            }
        };
        engine.watch(obj, LocalFolderModel::ROOT_PATH.index, move |e, v| {
            let path = e.to_js_string(v).to_string();
            again(e, &|m| m.write_root(&path));
        })?;
        engine.watch(obj, LocalFolderModel::ENABLED.index, move |e, v| {
            let enabled = v.to_boolean();
            again(e, &|m| m.write_enabled(enabled));
        })?;
        // What QML wrote while the object was made.
        let cx = self.cx();
        let root = cx.get(LocalFolderModel::ROOT_PATH)?;
        if !root.is_empty() {
            self.write_root(&root);
        }
        if cx.get(LocalFolderModel::ENABLED)? {
            self.write_enabled(true);
        }
        Ok(())
    }

    // ---- state

    fn enabled(&self) -> bool {
        self.state.enabled.get()
    }

    fn root(&self) -> String {
        self.state.root.borrow().clone()
    }

    /// Browsing: enabled, with a root.
    fn active(&self) -> bool {
        self.enabled() && !self.state.root.borrow().is_empty()
    }

    /// Gives `rootPath` the root this holds, which is not what was written
    /// when that was a link or a path with `..`. A binding on the property
    /// stays, as it does when C++ sets a property in Qt.
    fn show_root(&self, root: &str) {
        let _ = self.engine.write_derived(
            self.obj,
            LocalFolderModel::ROOT_PATH.index,
            Value::string(root),
        );
    }

    fn set_error(&self, error: &str) {
        let _ = self.cx().set(LocalFolderModel::ERROR, Atom::from(error));
    }

    fn protected_paths(&self) -> Vec<String> {
        let value = self.cx().read("protectedPaths");
        match json::from_value(self.engine, &value) {
            Json::Array(paths) => paths
                .into_iter()
                .filter_map(|p| p.as_str().map(str::to_owned))
                .collect(),
            _ => Vec::new(),
        }
    }

    // ---- the two properties QML writes

    /// A write of `rootPath`: setBrowseRootPath.
    fn write_root(&self, path: &str) {
        // The property giving back the root this chose is not a new write.
        if *self.state.root.borrow() == path {
            return;
        }
        self.set_error("");
        let directory = if path.is_empty() {
            Some(String::new())
        } else {
            plain_directory(path).filter(|d| !broad_directory(d))
        };
        match directory {
            None => {
                self.set_error(BAD_ROOT);
                if self.state.root.borrow().is_empty() {
                    self.show_root("");
                    return;
                }
                self.state.root.borrow_mut().clear();
            }
            Some(directory) => {
                if *self.state.root.borrow() == directory {
                    self.show_root(&directory);
                    return;
                }
                *self.state.root.borrow_mut() = directory;
            }
        }
        if self.enabled() {
            self.activate_root();
        }
        self.root_changed();
    }

    /// A write of `enabled`: setEnabled.
    fn write_enabled(&self, enabled: bool) {
        if self.enabled() == enabled {
            return;
        }
        self.state.enabled.set(enabled);
        if enabled {
            self.activate_root();
        }
        self.root_changed();
    }

    /// The root is still a plain folder, or it is given up.
    fn activate_root(&self) {
        if self.state.root.borrow().is_empty() {
            return;
        }
        if plain_directory(&self.root()).is_none() {
            self.state.root.borrow_mut().clear();
            self.set_error(NO_ROOT);
        }
    }

    /// The OS saw `path` change.
    fn changed(&self, path: &Path) {
        let Some(path) = path.to_str().map(plain::text_of) else {
            return;
        };
        let parent = path.rsplit_once('/').map(|(p, _)| p.to_owned());
        let root = self.root();
        let parent_of_root = root.rsplit_once('/').map(|(p, _)| p.to_owned());
        if self.enabled() && !root.is_empty() && (parent == parent_of_root || path == root) {
            self.check_root();
        }
        if !self.active() {
            return;
        }
        let known = |dir: &str| self.state.tree.borrow().children.contains_key(dir);
        for dir in [Some(path.clone()), parent].into_iter().flatten() {
            if known(&dir) && within(&dir, &self.root()) {
                self.list(&dir);
            }
        }
    }

    /// A root that was replaced by a link, or removed, is given up.
    fn check_root(&self) {
        if !self.active() || plain_directory(&self.root()).is_some() {
            return;
        }
        self.state.root.borrow_mut().clear();
        self.set_error(NO_ROOT);
        self.root_changed();
    }

    /// The root, `enabled` or what is shown changed: the rows start over.
    fn root_changed(&self) {
        let state = &self.state;
        state.generation.set(state.generation.get() + 1);
        let had_rows = {
            let mut tree = state.tree.borrow_mut();
            let had = !tree.rows.is_empty();
            *tree = Tree::default();
            had
        };
        let root = self.root();
        let cx = self.cx();
        let index = if self.active() { 0 } else { -1 };
        self.engine.batch(|| {
            self.show_root(&root);
            let _ = cx.set(LocalFolderModel::ROOT_INDEX, index);
        });
        if had_rows {
            self.reset();
        }
        self.sync_watches();
        let _ = LocalFolderModel::emit_root_changed(&cx);
        if self.active() {
            self.list(&root);
        }
    }

    // ---- the rows

    fn signals(&self) -> Option<ModelSignals> {
        self.state.signals.borrow().clone()
    }

    fn reset(&self) {
        if let Some(signals) = self.signals() {
            signals.model_reset(self.engine);
        }
    }

    /// Reads `dir` off the Engine thread. What it finds is shown when the
    /// rows are still the ones it was asked for.
    fn list(&self, dir: &str) {
        let generation = self.state.generation.get();
        self.state.tree.borrow_mut().loading.insert(dir.to_owned());
        let (obj, state) = (self.obj, self.state.clone());
        let path = dir.to_owned();
        let read = {
            let path = path.clone();
            move || list_directory(&path)
        };
        // A read that panicked (a fault the engine reports) lists as a
        // folder that could not be read: empty.
        let done = move |engine: &Engine, entries: Result<Vec<Node>, ljos::task::TaskPanic>| {
            if state.generation.get() == generation && engine.is_alive(obj) {
                Model::new(engine, obj, state).listed(&path, entries.unwrap_or_default());
            }
        };
        if let Err(_full) = ljos::task::spawn(self.engine, read, done) {
            // The pool is busy: the folder is read here, once.
            let entries = list_directory(dir);
            self.listed(dir, entries);
        }
    }

    /// `dir` was read: its rows are the entries, below its own row.
    fn listed(&self, dir: &str, entries: Vec<Node>) {
        let root = self.root();
        let (start, end, depth) = {
            let mut tree = self.state.tree.borrow_mut();
            tree.loading.remove(dir);
            let place = if dir == root {
                Some((0, tree.rows.len(), 0))
            } else {
                tree.rows
                    .iter()
                    .position(|r| r.node.path == dir)
                    .filter(|_| tree.expanded.contains(dir))
                    .map(|at| (at + 1, tree.subtree_end(at), tree.rows[at].depth + 1))
            };
            tree.children.insert(dir.to_owned(), entries);
            match place {
                Some(place) => place,
                None => return,
            }
        };
        let mut shown = Vec::new();
        self.state.tree.borrow().flatten(dir, depth, &mut shown);
        let unchanged = self.state.tree.borrow().rows[start..end] == shown[..];
        if !unchanged {
            self.replace(start, end, shown);
        }
        self.open_unread();
        self.sync_watches();
    }

    /// Takes rows `start..end` out and puts `rows` in their place.
    fn replace(&self, start: usize, end: usize, rows: Vec<Row>) {
        let signals = self.signals();
        if end > start {
            if let Some(s) = &signals {
                s.rows_about_to_be_removed(self.engine, start, end - start);
            }
            self.state.tree.borrow_mut().rows.drain(start..end);
            if let Some(s) = &signals {
                s.rows_removed(self.engine, start, end - start);
            }
        }
        if !rows.is_empty() {
            let count = rows.len();
            if let Some(s) = &signals {
                s.rows_about_to_be_inserted(self.engine, start, count);
            }
            self.state.tree.borrow_mut().rows.splice(start..start, rows);
            if let Some(s) = &signals {
                s.rows_inserted(self.engine, start, count);
            }
        }
    }

    /// Reads the open folders that are shown and were not read yet.
    fn open_unread(&self) {
        let unread: Vec<String> = {
            let tree = self.state.tree.borrow();
            tree.rows
                .iter()
                .filter(|r| {
                    r.node.is_dir
                        && tree.expanded.contains(&r.node.path)
                        && !tree.children.contains_key(&r.node.path)
                        && !tree.loading.contains(&r.node.path)
                })
                .map(|r| r.node.path.clone())
                .collect()
        };
        for dir in unread {
            self.list(&dir);
        }
    }

    fn toggle_expanded(&self, row: i32) {
        let open = self.row(row).is_some_and(|r| {
            r.node.is_dir && self.state.tree.borrow().expanded.contains(&r.node.path)
        });
        self.set_expanded(row, !open);
    }

    fn row(&self, row: i32) -> Option<Row> {
        let at = usize::try_from(row).ok()?;
        self.state.tree.borrow().rows.get(at).cloned()
    }

    fn set_expanded(&self, row: i32, expanded: bool) {
        let Some(row_data) = self.row(row) else {
            return;
        };
        if !row_data.node.is_dir {
            return;
        }
        let at = row as usize;
        let path = row_data.node.path.clone();
        let changed = {
            let mut tree = self.state.tree.borrow_mut();
            if expanded {
                tree.expanded.insert(path.clone())
            } else {
                tree.expanded.remove(&path)
            }
        };
        if !changed {
            return;
        }
        if let Some(signals) = self.signals() {
            signals.data_changed(self.engine, at, 1, &["expanded"]);
        }
        if expanded {
            let mut shown = Vec::new();
            self.state
                .tree
                .borrow()
                .flatten(&path, row_data.depth + 1, &mut shown);
            // What was read before is shown now, and read again below.
            self.replace(at + 1, at + 1, shown);
            self.open_unread();
            self.list(&path);
        } else {
            let end = self.state.tree.borrow().subtree_end(at);
            self.replace(at + 1, end, Vec::new());
        }
        self.sync_watches();
    }

    /// Watches the root, the folder it is in, and the folders shown open.
    fn sync_watches(&self) {
        let mut dirs = HashSet::new();
        if self.active() {
            let root = self.root();
            if let Some(parent) = watch::parent(Path::new(&root)) {
                dirs.insert(parent.to_owned());
            }
            dirs.insert(PathBuf::from(&root));
            let tree = self.state.tree.borrow();
            dirs.extend(
                tree.rows
                    .iter()
                    .filter(|r| r.node.is_dir && tree.expanded.contains(&r.node.path))
                    .map(|r| PathBuf::from(&r.node.path)),
            );
        }
        if let Some(watch) = self.state.watch.borrow_mut().as_mut() {
            watch.set(dirs);
        }
    }

    // ---- what QML asks

    fn path_for_index(&self, row: i32) -> String {
        if !self.active() {
            return String::new();
        }
        let Some(row) = self.row(row) else {
            return String::new();
        };
        match plain_entry(&row.node.path, false) {
            Some(path) if within(&path, &self.root()) => path,
            _ => String::new(),
        }
    }

    fn is_directory(&self, path: &str) -> bool {
        if !self.active() {
            return false;
        }
        plain_directory(path).is_some_and(|d| within(&d, &self.root()))
    }

    fn holds_project(&self, path: &str) -> bool {
        if !self.active() {
            return false;
        }
        plain_directory(path).is_some_and(|d| within(&d, &self.root()) && self.contains_project(&d))
    }

    fn can_modify_folder(&self, path: &str) -> bool {
        if !self.active() {
            return false;
        }
        let root = plain_directory(&self.root());
        let directory = plain_directory(path);
        match (root, directory) {
            (Some(root), Some(directory)) => {
                !broad_directory(&directory)
                    && !within(&root, &directory)
                    && within(&directory, &root)
                    && !self.contains_project(&directory)
            }
            _ => false,
        }
    }

    // ---- changing the disk

    /// The plain folder at `path` inside the root, or none and the reason.
    fn checked_directory(&self, path: &str, allow_root: bool) -> Option<String> {
        if !self.active() {
            self.set_error(DISABLED);
            return None;
        }
        let root = plain_directory(&self.root());
        let directory = plain_directory(path);
        match (root, directory) {
            (Some(root), Some(directory))
                if !broad_directory(&directory)
                    && within(&directory, &root)
                    && (allow_root || !within(&root, &directory)) =>
            {
                Some(directory)
            }
            _ => {
                self.set_error(OUTSIDE);
                None
            }
        }
    }

    fn valid_name(&self, name: &str) -> bool {
        let bad = name.is_empty()
            || name != name.trim()
            || name == "."
            || name == ".."
            || name.contains(['/', '\\', '\0']);
        if bad {
            self.set_error(BAD_NAME);
        }
        !bad
    }

    fn contains_project(&self, path: &str) -> bool {
        self.protected_paths().iter().any(|protected| {
            if !Path::new(protected).is_absolute() {
                return false;
            }
            let lexical = clean(&plain::text_of(protected));
            let canonical = std::fs::canonicalize(protected)
                .ok()
                .map(|p| plain::text(&p));
            within(&lexical, path) || canonical.is_some_and(|c| within(&c, path))
        })
    }

    fn can_relocate(&self, path: &str) -> bool {
        if !self.contains_project(path) {
            return true;
        }
        self.set_error(PROTECTED);
        false
    }

    fn create_folder(&self, parent_path: &str, name: &str) -> String {
        self.set_error("");
        let Some(parent) = self.checked_directory(parent_path, true) else {
            return String::new();
        };
        if !self.valid_name(name) {
            return String::new();
        }
        let destination = join(&parent, name);
        if occupied(&destination) {
            self.set_error(EXISTS);
            return String::new();
        }
        if std::fs::create_dir(&destination).is_err() {
            self.set_error(NOT_CREATED);
            return String::new();
        }
        self.refresh(&[&parent]);
        destination
    }

    /// Moves `source` to `destination`, which must not be there.
    fn relocate(&self, source: &str, destination: &str) -> String {
        if occupied(destination) {
            self.set_error(DESTINATION_EXISTS);
            return String::new();
        }
        if std::fs::rename(source, destination).is_err() {
            self.set_error(NOT_MOVED);
            return String::new();
        }
        let from = folder_of(source);
        let to = folder_of(destination);
        self.refresh(&[&from, &to]);
        destination.to_owned()
    }

    fn rename_folder(&self, path: &str, new_name: &str) -> String {
        self.set_error("");
        let Some(source) = self.checked_directory(path, false) else {
            return String::new();
        };
        if !self.valid_name(new_name) || !self.can_relocate(&source) {
            return String::new();
        }
        self.relocate(&source, &join(&folder_of(&source), new_name))
    }

    fn move_folder(&self, path: &str, destination_directory: &str) -> String {
        self.set_error("");
        let Some(source) = self.checked_directory(path, false) else {
            return String::new();
        };
        if !self.can_relocate(&source) {
            return String::new();
        }
        let Some(parent) = self.checked_directory(destination_directory, true) else {
            return String::new();
        };
        if within(&parent, &source) {
            self.set_error(INTO_ITSELF);
            return String::new();
        }
        let name = source.rsplit('/').next().unwrap_or_default();
        self.relocate(&source, &join(&parent, name))
    }

    fn trash_folder(&self, path: &str, confirmation_path: &str) -> bool {
        self.set_error("");
        let Some(source) = self.checked_directory(path, false) else {
            return false;
        };
        if !self.can_relocate(&source) {
            return false;
        }
        if confirmation_path != source {
            self.set_error(CONFIRM);
            return false;
        }
        if !(trash_of(self.engine))(&source) {
            self.set_error(NOT_TRASHED);
            return false;
        }
        self.refresh(&[&folder_of(&source)]);
        true
    }

    /// Reads again the folders a change was made in, those that are shown.
    fn refresh(&self, dirs: &[&str]) {
        if !self.active() {
            return;
        }
        let shown: Vec<String> = {
            let tree = self.state.tree.borrow();
            dirs.iter()
                .filter(|d| tree.children.contains_key(**d))
                .map(|d| (*d).to_owned())
                .collect()
        };
        for dir in shown {
            self.list(&dir);
        }
    }
}

fn join(dir: &str, name: &str) -> String {
    format!("{}/{name}", dir.trim_end_matches('/'))
}

fn folder_of(path: &str) -> String {
    match path.rsplit_once('/') {
        Some(("", _)) => "/".to_owned(),
        Some((parent, _)) => parent.to_owned(),
        None => String::new(),
    }
}

/// The entries QFileSystemModel showed here: folders and files, no links,
/// nothing hidden; folders first, then by name.
fn list_directory(dir: &str) -> Vec<Node> {
    let mut nodes: Vec<Node> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            let kind = entry.file_type().ok()?;
            if name.starts_with('.') || kind.is_symlink() || !(kind.is_dir() || kind.is_file()) {
                return None;
            }
            Some(Node {
                path: join(dir, &name),
                is_dir: kind.is_dir(),
                name,
            })
        })
        .collect();
    nodes.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            .then_with(|| a.name.cmp(&b.name))
    });
    nodes
}
