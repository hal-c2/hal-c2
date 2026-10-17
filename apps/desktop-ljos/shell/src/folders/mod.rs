//! `LocalFolderModel` in `HalC2.Shell`, desktop-qt's QFileSystemModel
//! subclass of the same name: the folders under a root the user chose, to
//! browse, and create, rename, move or trash a folder in, without ever
//! leaving the root, following a link, or touching a project's folder.
//!
//! The model is a tree (a Ljós `ItemTree`) shaped like QFileSystemModel's
//! with what is above the root cut to one row: the top level is the root
//! folder itself, and `rootIndex` is that row's index, so a `TreeView` shows
//! what is in the root. A folder is read off the Engine thread the first
//! time a view asks how many rows it has, and again when the OS says it
//! changed (see `watch.rs`) or the model changed it; its rows then come and
//! go one by one, so the rows a view shows and has open keep their place.
//!
//! Not ported: the system file icons (`QFileSystemModel` decoration), and a
//! write of `rootPath` to the path it already has does not clear `error`.

mod plain;
mod watch;

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use ljos::prelude::{
    Atom, Cx, Engine, EngineError, ItemTree, ObjectId, Platform, QmlObject, QtObject, TreeChange,
    TreeListener, TreeListeners, Value, qml_impl,
};

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
    /// The root folder's index: the top row. The invalid index while there
    /// is nothing to browse.
    #[qml(notify, readonly)]
    root_index: Value,
    #[qml(notify)]
    protected_paths: Vec<String>,
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
            root_index: Value::Undefined,
            protected_paths: Vec::new(),
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

    /// The real path of the entry at model index `index`, when it is a
    /// plain entry inside the root.
    #[qml(invokable)]
    fn path_for_index(cx: &Cx, index: Value) -> String {
        Model::of(cx).map_or_else(String::new, |m| m.path_for_index(&index))
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
}

/// An entry of a folder as it was read.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Node {
    name: String,
    path: String,
    is_dir: bool,
}

#[derive(Default)]
struct Tree {
    /// Folders that were read, by path: each folder's rows.
    children: HashMap<String, Vec<Node>>,
    /// Folders being read, or asked for and about to be.
    loading: HashSet<String>,
}

/// The model's own state: what lives beside the properties. The tree is
/// read through [`Entries`], which Ljós's views follow.
#[derive(Default)]
struct State {
    enabled: Cell<bool>,
    root: RefCell<String>,
    tree: RefCell<Tree>,
    listeners: TreeListeners,
    /// The object, and its engine's platform: what a view asking for a
    /// folder that was not read needs to have it read ([`State::want`]).
    obj: Cell<Option<ObjectId>>,
    platform: RefCell<Option<Rc<Platform>>>,
    /// Bumped whenever the tree starts over: a read that finishes later is
    /// for a tree that is gone.
    generation: Cell<u64>,
    watch: RefCell<Option<watch::Watch>>,
}

impl State {
    /// Browsing: enabled, with a root.
    fn active(&self) -> bool {
        self.enabled.get() && !self.root.borrow().is_empty()
    }

    /// The entry at `path` in the tree: `[0]` is the root folder.
    fn node_at(&self, path: &[usize]) -> Option<Node> {
        let (&0, rest) = path.split_first()? else {
            return None;
        };
        if !self.active() {
            return None;
        }
        let root = self.root.borrow().clone();
        let tree = self.tree.borrow();
        let mut node = None;
        let mut dir = root.as_str();
        for &row in rest {
            let entry = tree.children.get(dir)?.get(row)?;
            dir = &entry.path;
            node = Some(entry);
        }
        Some(match node {
            Some(node) => node.clone(),
            None => Node {
                name: root.rsplit('/').next().unwrap_or_default().to_owned(),
                path: root.clone(),
                is_dir: true,
            },
        })
    }

    /// Where the folder `dir` is in the tree, when it is there.
    fn place_of(&self, dir: &str) -> Option<Vec<usize>> {
        if !self.active() {
            return None;
        }
        let root = self.root.borrow().clone();
        let mut place = vec![0];
        if dir == root {
            return Some(place);
        }
        let rest = dir.strip_prefix(&root)?.strip_prefix('/')?;
        let tree = self.tree.borrow();
        let mut at = root;
        for name in rest.split('/') {
            let entries = tree.children.get(&at)?;
            place.push(entries.iter().position(|n| n.is_dir && n.name == name)?);
            at = join(&at, name);
        }
        Some(place)
    }

    /// A view asked what is in `dir`, which was not read: it is read from
    /// the next frame on, once.
    ///
    /// TODO(ljos): not filed yet. `ItemTree` has no `hasChildren` or
    /// `fetchMore`, and its `row_count` is given no engine: the view shows a
    /// row's arrow when the rows under it count more than none, so a folder
    /// is read when a view counts its rows, and the read is started through
    /// the platform's inbox. An empty folder has no arrow (QFileSystemModel
    /// gave every folder one until it was read).
    fn want(&self, dir: &str) {
        if !self.tree.borrow_mut().loading.insert(dir.to_owned()) {
            return;
        }
        let platform = self.platform.borrow().clone();
        let (Some(obj), Some(platform)) = (self.obj.get(), platform) else {
            return;
        };
        let generation = self.generation.get();
        let dir = dir.to_owned();
        platform.expect().send(move |engine: &Engine| {
            let state = engine.with::<LocalFolderModel, _>(obj, |m| m.state.clone());
            if let Ok(state) = state
                && state.generation.get() == generation
            {
                Model::new(engine, obj, state).list(&dir);
            }
        });
    }
}

/// `State` as the tree Ljós's views read.
struct Entries(Rc<State>);

impl ItemTree for Entries {
    fn row_count(&self, parent: &[usize]) -> usize {
        if parent.is_empty() {
            return usize::from(self.0.active());
        }
        let Some(node) = self.0.node_at(parent).filter(|n| n.is_dir) else {
            return 0;
        };
        let count = self.0.tree.borrow().children.get(&node.path).map(Vec::len);
        count.unwrap_or_else(|| {
            self.0.want(&node.path);
            0
        })
    }

    fn role_names(&self) -> Vec<Atom> {
        ["fileName", "filePath", "isDirectory"]
            .map(Atom::from)
            .to_vec()
    }

    fn data(&self, _: &Engine, path: &[usize], column: usize, role: &str) -> Value {
        let Some(node) = self.0.node_at(path).filter(|_| column == 0) else {
            return Value::Undefined;
        };
        match role {
            "fileName" => Value::from(node.name.as_str()),
            "filePath" => Value::from(node.path.as_str()),
            "isDirectory" => Value::Bool(node.is_dir),
            _ => Value::Undefined,
        }
    }

    fn subscribe(&self, listener: TreeListener) -> u64 {
        self.0.listeners.add(listener)
    }

    fn unsubscribe(&self, id: u64) {
        self.0.listeners.remove(id);
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

    /// Makes the object the tree's model and follows what QML writes.
    fn start(&self) -> Result<(), EngineError> {
        self.state.obj.set(Some(self.obj));
        *self.state.platform.borrow_mut() = Some(Platform::of(self.engine));
        self.engine
            .set_object_tree(self.obj, Rc::new(Entries(self.state.clone())))?;
        self.cx().set(
            LocalFolderModel::ROOT_INDEX,
            self.engine.invalid_model_index(),
        )?;
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

    fn active(&self) -> bool {
        self.state.active()
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
        self.cx()
            .get(LocalFolderModel::PROTECTED_PATHS)
            .unwrap_or_default()
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

    /// The root or `enabled` changed: the tree starts over.
    fn root_changed(&self) {
        let state = &self.state;
        state.generation.set(state.generation.get() + 1);
        *state.tree.borrow_mut() = Tree::default();
        let root = self.root();
        let cx = self.cx();
        // A new index each time, as QFileSystemModel's `rootIndex` is told
        // on every change of the root.
        let index = if self.active() {
            self.engine.model_index(Some(self.obj), &[(0, 0)])
        } else {
            self.engine.invalid_model_index()
        };
        self.tell(&TreeChange::ModelReset);
        self.engine.batch(|| {
            self.show_root(&root);
            let _ = cx.set(LocalFolderModel::ROOT_INDEX, index);
        });
        self.sync_watches();
        let _ = LocalFolderModel::emit_root_changed(&cx);
        if self.active() {
            self.list(&root);
        }
    }

    // ---- the tree

    fn tell(&self, change: &TreeChange) {
        self.state.listeners.emit(self.engine, change);
    }

    /// Reads `dir` off the Engine thread. What it finds is shown when the
    /// tree is still the one it was read for.
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

    /// `dir` was read: its rows are the entries. The rows that went and
    /// came are told one run at a time, so the rest keep their place.
    fn listed(&self, dir: &str, entries: Vec<Node>) {
        self.state.tree.borrow_mut().loading.remove(dir);
        // A folder its parent no longer has is not kept.
        let Some(place) = self.state.place_of(dir) else {
            return;
        };
        let old = self.state.tree.borrow().children.get(dir).cloned();
        let was_empty = old.as_ref().is_none_or(Vec::is_empty);
        let now_empty = entries.is_empty();
        let old = old.unwrap_or_default();
        let (removed, inserted) = {
            let kept: HashSet<&Node> = entries.iter().collect();
            let had: HashSet<&Node> = old.iter().collect();
            let removed: Vec<usize> = (0..old.len())
                .filter(|&i| !kept.contains(&old[i]))
                .collect();
            let inserted: Vec<usize> = (0..entries.len())
                .filter(|&i| !had.contains(&entries[i]))
                .collect();
            (removed, inserted)
        };
        self.state
            .tree
            .borrow_mut()
            .children
            .entry(dir.to_owned())
            .or_default();
        for (first, count) in runs(&removed).into_iter().rev() {
            {
                let mut tree = self.state.tree.borrow_mut();
                let rows = tree.children.entry(dir.to_owned()).or_default();
                let gone: Vec<Node> = rows.drain(first..first + count).collect();
                // What was read under a folder that went goes with it.
                tree.children
                    .retain(|path, _| !gone.iter().any(|g| g.is_dir && within(path, &g.path)));
            }
            self.tell(&TreeChange::RowsRemoved {
                parent: place.clone(),
                first,
                count,
            });
        }
        for (first, count) in runs(&inserted) {
            {
                let mut tree = self.state.tree.borrow_mut();
                let rows = tree.children.entry(dir.to_owned()).or_default();
                rows.splice(first..first, entries[first..first + count].iter().cloned());
            }
            self.tell(&TreeChange::RowsInserted {
                parent: place.clone(),
                first,
                count,
            });
        }
        // The view shows the folder's arrow from how many rows it has.
        if was_empty != now_empty {
            self.tell(&TreeChange::DataChanged {
                path: place,
                roles: vec![Atom::from("hasChildren")],
            });
        }
        self.sync_watches();
    }

    /// Watches the root, the folder it is in, and every folder read.
    fn sync_watches(&self) {
        let mut dirs = HashSet::new();
        if self.active() {
            let root = self.root();
            if let Some(parent) = watch::parent(Path::new(&root)) {
                dirs.insert(parent.to_owned());
            }
            dirs.insert(PathBuf::from(&root));
            let tree = self.state.tree.borrow();
            dirs.extend(tree.children.keys().map(PathBuf::from));
        }
        if let Some(watch) = self.state.watch.borrow_mut().as_mut() {
            watch.set(dirs);
        }
    }

    // ---- what QML asks

    fn path_for_index(&self, index: &Value) -> String {
        if !self.active() {
            return String::new();
        }
        let place = self.engine.model_index_place(index, Some(self.obj));
        let path: Option<Vec<usize>> = place
            .into_iter()
            .flatten()
            .map(|(row, _)| usize::try_from(row).ok())
            .collect();
        let Some(node) = path.and_then(|p| self.state.node_at(&p)) else {
            return String::new();
        };
        match plain_entry(&node.path, false) {
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

/// Indexes in order as runs of neighbours: `(first, count)`.
fn runs(indexes: &[usize]) -> Vec<(usize, usize)> {
    let mut out: Vec<(usize, usize)> = Vec::new();
    for &i in indexes {
        match out.last_mut() {
            Some((first, count)) if *first + *count == i => *count += 1,
            _ => out.push((i, 1)),
        }
    }
    out
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
