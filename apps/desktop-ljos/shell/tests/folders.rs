//! `LocalFolderModel` as FolderExplorer uses it: a root's folders in a
//! `TreeView`, and the guarded changes to them. The folders are real, under
//! a temporary directory; a read is waited for by draining the platform
//! inbox, a change made outside by the watcher's waker.

mod common;

use std::fs;
use std::path::Path;
use std::rc::Rc;
use std::sync::mpsc;

use common::{call, shell, text};
use hal_c2_shell::folders::{deliver, set_trash, set_wake};
use hal_c2_shell::mc::Disconnected;
use ljos::prelude::{Engine, ObjectId, Platform, Value};
use tempfile::TempDir;

const MAIN: &str = r#"
import QtQuick
import QtQuick.Controls.Basic
import QtQml.Models
import HalC2.Shell

Item {
    id: root
    property bool enabled: false
    property string rootPath: ""
    property var protectedPaths: []
    property string selected: ""
    readonly property string error: folders.error
    readonly property bool rooted: folders.rootIndex.valid
    readonly property string modelRoot: folders.rootPath
    property int rootChanges: 0
    property int rootIndexChanges: 0

    LocalFolderModel {
        id: folders
        objectName: "folders"
        onRootIndexChanged: root.rootIndexChanges += 1
        enabled: root.enabled
        rootPath: root.rootPath
        protectedPaths: root.protectedPaths
        onRootChanged: root.rootChanges += 1
    }
    // The tree as FolderExplorer builds it.
    TreeView {
        id: tree
        width: 300
        height: 400
        model: folders.enabled && folders.rootPath.length > 0 ? folders : null
        rootIndex: folders.rootIndex
        selectionModel: ItemSelectionModel {
            model: tree.model
            onCurrentChanged: root.selected = folders.pathForIndex(currentIndex)
        }
        editTriggers: TableView.NoEditTriggers
        delegate: TreeViewDelegate {
            required property string fileName
            required property string filePath
            required property bool isDirectory
            implicitWidth: tree.width
            implicitHeight: 20
            text: fileName
        }
    }
    // A row each: indented by depth, a folder with `/` and its arrow, `+`
    // closed or `-` open.
    function rows() {
        var out = []
        for (var r = 0; r < tree.rows; r++) {
            var c = tree.itemAtCell(Qt.point(0, r))
            var pad = ""
            for (var d = 0; d < c.depth; d++) pad += "  "
            var arrow = c.hasChildren ? (c.expanded ? "-" : "+") : ""
            out.push(pad + c.fileName + (c.isDirectory ? "/" + arrow : ""))
        }
        return out.join("|")
    }
    function pathFor(row) { return folders.pathForIndex(tree.index(row, 0)) }
    function toggle(row) { tree.toggleExpanded(row) }
    function click(row) { tree.itemAtCell(Qt.point(0, row)).clicked() }
    function isDirectory(p) { return folders.isDirectory(p) }
    function canModify(p) { return folders.canModifyFolder(p) }
    function holdsProject(p) { return folders.holdsProject(p) }
    function create(parent, name) { return folders.createFolder(parent, name) }
    function rename(p, name) { return folders.renameFolder(p, name) }
    function move(p, to) { return folders.moveFolder(p, to) }
    function trash(p, confirm) { return folders.trashFolder(p, confirm) }
}
"#;

struct Fixture {
    engine: Engine,
    root: ObjectId,
    dir: TempDir,
}

fn plain_temp() -> TempDir {
    // The temporary directory is a real path, as the model requires.
    let base = fs::canonicalize(std::env::temp_dir()).expect("temp dir");
    tempfile::Builder::new()
        .prefix("tst-")
        .tempdir_in(base)
        .expect("temp dir")
}

impl Fixture {
    fn new() -> Fixture {
        let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
        // A machine's Trash is not used by a test.
        set_trash(&engine, |_| false);
        Fixture {
            engine,
            root,
            dir: plain_temp(),
        }
    }

    fn path(&self, relative: &str) -> String {
        self.dir
            .path()
            .join(relative)
            .to_string_lossy()
            .into_owned()
    }

    fn root_path(&self) -> String {
        self.dir.path().to_string_lossy().into_owned()
    }

    fn mkdir(&self, relative: &str) {
        fs::create_dir_all(self.path(relative)).expect("mkdir");
    }

    fn touch(&self, relative: &str) {
        fs::write(self.path(relative), "x").expect("touch");
    }

    fn set(&self, name: &str, value: Value) {
        self.engine
            .write_by_name(self.root, name, value)
            .expect("property is writable");
    }

    fn browse(&self) {
        self.set("rootPath", Value::string(self.root_path()));
        self.set("enabled", Value::Bool(true));
        self.settle();
    }

    /// Every read that was started has come back.
    fn settle(&self) {
        Platform::of(&self.engine).finish(&self.engine);
    }

    fn call(&self, name: &str, args: &[&str]) -> Value {
        let args: Vec<Value> = args.iter().map(|a| Value::string(*a)).collect();
        let value = call(&self.engine, self.root, name, &args);
        self.settle();
        value
    }

    fn toggle(&self, row: i32) {
        call(&self.engine, self.root, "toggle", &[Value::Int(row)]);
        self.settle();
    }

    fn path_for(&self, row: i32) -> String {
        let value = call(&self.engine, self.root, "pathFor", &[Value::Int(row)]);
        self.engine.to_js_string(&value).to_string()
    }

    fn string(&self, name: &str, args: &[&str]) -> String {
        self.engine.to_js_string(&self.call(name, args)).to_string()
    }

    fn truth(&self, name: &str, args: &[&str]) -> bool {
        self.call(name, args).to_boolean()
    }

    fn rows(&self) -> String {
        self.string("rows", &[])
    }

    fn error(&self) -> String {
        text(&self.engine, self.root, "error")
    }

    fn rooted(&self) -> bool {
        common::read(&self.engine, self.root, "rooted").to_boolean()
    }
}

#[test]
fn a_disabled_model_neither_browses_nor_changes_anything() {
    let f = Fixture::new();
    f.set("rootPath", Value::string(f.root_path()));
    f.settle();
    assert_eq!(f.rows(), "");
    assert!(!f.rooted());
    assert_eq!(f.string("create", &[&f.root_path(), "no"]), "");
    assert!(!Path::new(&f.path("no")).exists());
}

#[test]
fn browsing_lists_folders_first_and_disabling_hides_them() {
    let f = Fixture::new();
    f.mkdir("child");
    f.touch("plain-file");
    f.touch(".hidden");
    f.browse();
    // Every folder has an arrow, as in QFileSystemModel, until it is open.
    assert_eq!(f.rows(), "child/+|plain-file");
    assert!(f.rooted());
    assert_eq!(f.path_for(0), f.path("child"));
    assert!(f.truth("isDirectory", &[&f.root_path()]));
    assert!(f.truth("isDirectory", &[&f.path("child")]));
    assert!(!f.truth("isDirectory", &[&f.path("plain-file")]));
    f.set("enabled", Value::Bool(false));
    f.settle();
    assert_eq!(f.rows(), "");
    assert!(!f.rooted());
    assert_eq!(f.path_for(0), "");
    assert!(!f.truth("isDirectory", &[&f.root_path()]));
}

#[test]
fn folders_open_and_close_in_place() {
    let f = Fixture::new();
    f.mkdir("a/inner/deep");
    f.touch("a/a.txt");
    f.touch("z.txt");
    f.browse();
    assert_eq!(f.rows(), "a/+|z.txt");
    f.toggle(0);
    assert_eq!(f.rows(), "a/-|  inner/+|  a.txt|z.txt");
    f.toggle(1);
    assert_eq!(f.rows(), "a/-|  inner/-|    deep/+|  a.txt|z.txt");
    assert_eq!(f.path_for(2), f.path("a/inner/deep"));
    f.toggle(0);
    assert_eq!(f.rows(), "a/+|z.txt");
    // What was open stays open when its parent opens again.
    f.toggle(0);
    assert_eq!(f.rows(), "a/-|  inner/-|    deep/+|  a.txt|z.txt");
    // A folder read again keeps what is open in it open.
    f.string("create", &[&f.path("a"), "new"]);
    assert_eq!(f.rows(), "a/-|  inner/-|    deep/+|  new/+|  a.txt|z.txt");
    f.string("rename", &[&f.path("a/new"), "after"]);
    assert_eq!(f.rows(), "a/-|  after/+|  inner/-|    deep/+|  a.txt|z.txt");
}

#[test]
fn paths_stay_inside_the_root_and_files_are_not_folders() {
    let f = Fixture::new();
    let outside = plain_temp();
    fs::write(outside.path().join("outside.txt"), "").unwrap();
    f.touch("example.txt");
    f.browse();
    let file = f.path("example.txt");
    assert!(!f.truth("canModify", &[&file]));
    assert_eq!(f.string("create", &[&file, "child"]), "");
    assert_eq!(f.string("rename", &[&file, "renamed.txt"]), "");
    assert_eq!(f.string("move", &[&file, &f.root_path()]), "");
    assert!(!f.truth("trash", &[&file, &file]));
    assert!(!f.truth("isDirectory", &[&outside.path().to_string_lossy()]));
    assert!(!f.truth("isDirectory", &[&f.path("../")]));
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(outside.path(), f.path("linked-directory")).unwrap();
        std::os::unix::fs::symlink(&file, f.path("linked-file")).unwrap();
        f.settle();
        assert!(!f.truth("isDirectory", &[&f.path("linked-directory")]));
        // Links are not shown at all.
        assert_eq!(f.rows(), "example.txt");
    }
    assert_eq!(fs::read_to_string(&file).unwrap(), "x");
}

#[test]
fn create_rename_and_move_keep_the_contents() {
    let f = Fixture::new();
    f.browse();
    let source = f.string("create", &[&f.root_path(), "新 folder"]);
    assert_eq!(source, f.path("新 folder"));
    fs::write(Path::new(&source).join("keep.txt"), "preserved").unwrap();
    assert_eq!(f.rows(), "新 folder/+");
    let renamed = f.string("rename", &[&source, "renamed"]);
    assert_eq!(renamed, f.path("renamed"));
    assert!(!Path::new(&source).exists());
    assert_eq!(f.rows(), "renamed/+");
    let destination = f.string("create", &[&f.root_path(), "destination"]);
    assert_eq!(f.rows(), "destination/+|renamed/+");
    let moved = f.string("move", &[&renamed, &destination]);
    assert_eq!(moved, f.path("destination/renamed"));
    assert_eq!(
        fs::read_to_string(Path::new(&moved).join("keep.txt")).unwrap(),
        "preserved"
    );
    assert_eq!(f.rows(), "destination/+");
    assert_eq!(f.error(), "");
}

#[test]
fn a_change_shows_in_the_folders_that_are_open() {
    let f = Fixture::new();
    f.mkdir("parent");
    f.browse();
    f.toggle(0);
    f.string("create", &[&f.path("parent"), "kid"]);
    assert_eq!(f.rows(), "parent/-|  kid/+");
    f.string("rename", &[&f.path("parent/kid"), "kid2"]);
    assert_eq!(f.rows(), "parent/-|  kid2/+");
}

#[test]
fn names_and_collisions_never_overwrite() {
    let f = Fixture::new();
    f.browse();
    let a = f.string("create", &[&f.root_path(), "a"]);
    let b = f.string("create", &[&f.root_path(), "b"]);
    assert!(!a.is_empty() && !b.is_empty());
    for name in ["", ".", "..", "x/y", "x\\y", " x", "x ", "\0"] {
        assert_eq!(f.string("create", &[&f.root_path(), name]), "", "{name:?}");
        assert_eq!(f.string("rename", &[&a, name]), "", "{name:?}");
    }
    assert_eq!(f.string("create", &[&f.root_path(), "a"]), "");
    assert_eq!(f.string("rename", &[&a, "b"]), "");
    assert_eq!(f.string("move", &[&a, &f.root_path()]), "");
    assert_eq!(f.string("create", &[&b, "a"]), f.path("b/a"));
    assert_eq!(f.string("move", &[&a, &b]), "");
    f.touch("file");
    assert_eq!(f.string("create", &[&f.root_path(), "file"]), "");
    assert_eq!(f.string("rename", &[&a, "file"]), "");
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(f.path("missing-target"), f.path("dangling")).unwrap();
        assert_eq!(f.string("create", &[&f.root_path(), "dangling"]), "");
        assert_eq!(f.string("rename", &[&a, "dangling"]), "");
    }
    assert!(Path::new(&a).is_dir() && Path::new(&b).is_dir());
    assert!(Path::new(&f.path("b/a")).is_dir());
    assert_eq!(fs::read_to_string(f.path("file")).unwrap(), "x");
}

#[test]
fn roots_outside_links_and_self_moves_are_refused() {
    let f = Fixture::new();
    let outside = plain_temp();
    let outside_path = outside.path().to_string_lossy().into_owned();
    f.browse();
    let a = f.string("create", &[&f.root_path(), "a"]);
    let child = f.string("create", &[&a, "child"]);
    assert_eq!(f.string("rename", &[&f.root_path(), "changed"]), "");
    assert_eq!(f.string("create", &[&outside_path, "escape"]), "");
    assert_eq!(f.string("move", &[&a, &outside_path]), "");
    assert_eq!(f.string("move", &[&a, &a]), "");
    assert_eq!(f.string("move", &[&a, &child]), "");
    assert_eq!(f.string("create", &[&f.path("a/../a"), "escape"]), "");
    f.touch("plain-file");
    assert_eq!(
        f.string("rename", &[&f.path("plain-file"), "not-a-folder"]),
        ""
    );
    #[cfg(unix)]
    {
        let link = f.path("link");
        std::os::unix::fs::symlink(outside.path(), &link).unwrap();
        assert_eq!(f.string("create", &[&link, "escape"]), "");
        assert_eq!(f.string("rename", &[&link, "renamed-link"]), "");
        assert!(!f.truth("trash", &[&link, &link]));
    }
    assert!(!outside.path().join("escape").exists());
}

#[test]
fn a_root_that_is_not_a_plain_folder_is_not_taken() {
    let f = Fixture::new();
    f.browse();
    assert_eq!(f.error(), "");
    let outside = plain_temp();
    #[cfg(unix)]
    {
        let link = f.path("link");
        std::os::unix::fs::symlink(outside.path(), &link).unwrap();
        f.set("rootPath", Value::string(&link));
        f.settle();
        assert_eq!(text(&f.engine, f.root, "modelRoot"), "");
        assert_ne!(f.error(), "");
        assert_eq!(f.rows(), "");
        assert!(!f.rooted());
    }
    f.set("rootPath", Value::string("/"));
    f.settle();
    assert_ne!(f.error(), "");
    let home = std::env::var("HOME").unwrap_or_default();
    if !home.is_empty() {
        f.set("rootPath", Value::string(&home));
        f.settle();
        assert_ne!(f.error(), "");
    }
    // A good root is taken again, and the failure forgotten.
    f.set("rootPath", Value::string(f.root_path()));
    f.settle();
    assert_eq!(f.error(), "");
    assert!(f.rooted());
}

#[test]
#[ignore = "TODO(ljos#78): a write of an equal value is not seen by the model"]
fn writing_the_root_it_already_has_forgets_the_last_failure() {
    let f = Fixture::new();
    f.browse();
    f.string("create", &[&f.root_path(), "a"]);
    assert_eq!(f.string("create", &[&f.root_path(), "a"]), "");
    assert_ne!(f.error(), "");
    // setBrowseRootPath clears the error before it sees the root is the same.
    f.set("rootPath", Value::string(f.root_path()));
    f.settle();
    assert_eq!(f.error(), "");
    assert!(f.rooted());
}

#[test]
fn every_new_root_tells_its_index_though_the_index_is_the_same() {
    let f = Fixture::new();
    f.mkdir("one/inside");
    f.mkdir("two");
    f.set("enabled", Value::Bool(true));
    f.set("rootPath", Value::string(f.path("one")));
    f.settle();
    let count = || common::number(&f.engine, f.root, "rootIndexChanges");
    let before = count();
    assert_eq!(f.rows(), "inside/+");
    // The top row's index either way: what reads it reads it again.
    f.set("rootPath", Value::string(f.path("two")));
    f.settle();
    assert_eq!(count(), before + 1.0);
    assert_eq!(f.rows(), "");
    assert!(f.rooted());
}

#[cfg(unix)]
#[test]
fn a_root_replaced_by_a_link_is_given_up() {
    let f = Fixture::new();
    let outside = plain_temp();
    f.mkdir("selected-root");
    let selected = f.path("selected-root");
    f.set("rootPath", Value::string(&selected));
    f.set("enabled", Value::Bool(true));
    f.settle();
    fs::rename(&selected, f.path("original-root")).unwrap();
    std::os::unix::fs::symlink(outside.path(), &selected).unwrap();
    assert_eq!(f.string("create", &[&selected, "escape"]), "");
    assert!(!f.truth("canModify", &[&selected]));
    assert!(!outside.path().join("escape").exists());
    f.set("enabled", Value::Bool(false));
    f.set("enabled", Value::Bool(true));
    f.settle();
    assert_eq!(text(&f.engine, f.root, "modelRoot"), "");
    assert!(!f.rooted());
}

#[test]
fn project_folders_and_their_ancestors_are_protected() {
    let f = Fixture::new();
    f.browse();
    let parent = f.string("create", &[&f.root_path(), "parent"]);
    let project = f.string("create", &[&parent, "project"]);
    let child = f.string("create", &[&project, "ordinary-child"]);
    f.set(
        "protectedPaths",
        f.engine.eval_js(&format!("[{project:?}]")).unwrap(),
    );
    assert!(!f.truth("canModify", &[&parent]));
    assert!(!f.truth("canModify", &[&project]));
    assert!(f.truth("canModify", &[&child]));
    assert!(f.truth("holdsProject", &[&parent]));
    assert!(!f.truth("holdsProject", &[&child]));
    assert_eq!(f.string("rename", &[&parent, "elsewhere"]), "");
    assert_eq!(f.string("move", &[&project, &f.root_path()]), "");
    assert!(!f.truth("trash", &[&parent, &parent]));
    let error = f.error();
    assert!(!error.is_empty());
    assert_eq!(
        f.string("rename", &[&child, "safe"]),
        Path::new(&project).join("safe").to_string_lossy()
    );
    f.set("protectedPaths", f.engine.eval_js("[]").unwrap());
    assert!(f.truth("canModify", &[&project]));
    assert_eq!(
        f.string("rename", &[&project, "unregistered"]),
        Path::new(&parent).join("unregistered").to_string_lossy()
    );
}

#[test]
fn trash_needs_the_exact_path_and_keeps_the_folder_when_it_fails() {
    let f = Fixture::new();
    let trashed = Rc::new(std::cell::RefCell::new(Vec::new()));
    f.browse();
    let victim = f.string("create", &[&f.root_path(), "discarded"]);
    fs::write(Path::new(&victim).join("keep.txt"), "recover me").unwrap();
    // A name is not a confirmation.
    assert!(!f.truth("trash", &[&victim, "discarded"]));
    assert!(Path::new(&victim).is_dir());
    assert!(!trashed.borrow().iter().any(|p| p == &victim));
    // The Trash failing leaves it where it was, and says so.
    assert!(!f.truth("trash", &[&victim, &victim]));
    assert!(Path::new(&victim).join("keep.txt").is_file());
    assert!(!f.error().is_empty());
    // It works: the folder goes, through what trashes.
    let record = trashed.clone();
    set_trash(&f.engine, move |path| {
        record.borrow_mut().push(path.to_owned());
        fs::remove_dir_all(path).is_ok()
    });
    assert!(f.truth("trash", &[&victim, &victim]));
    assert_eq!(&*trashed.borrow(), std::slice::from_ref(&victim));
    assert!(!Path::new(&victim).exists());
    assert_eq!(f.rows(), "");
    assert_eq!(f.error(), "");
}

#[test]
fn what_changes_outside_is_shown_once_the_watcher_says_so() {
    let f = Fixture::new();
    f.mkdir("a");
    f.browse();
    f.toggle(0);
    // An empty folder opens.
    assert_eq!(f.rows(), "a/-");
    let (tx, rx) = mpsc::channel();
    set_wake(&f.engine, move || {
        let _ = tx.send(());
    });
    fs::create_dir(f.path("a/made-elsewhere")).unwrap();
    // The OS tells the waker; the Engine thread then delivers. A wake can come
    // before the change is readable, so each one is delivered until it shows.
    while f.rows() != "a/-|  made-elsewhere/+" {
        rx.recv().expect("the watcher saw the change");
        deliver(&f.engine);
        f.settle();
    }
}

#[test]
fn a_clicked_row_is_the_selected_path() {
    let f = Fixture::new();
    f.mkdir("a");
    f.touch("a/file.txt");
    f.browse();
    f.toggle(0);
    assert_eq!(f.rows(), "a/-|  file.txt");
    call(&f.engine, f.root, "click", &[Value::Int(1)]);
    assert_eq!(text(&f.engine, f.root, "selected"), f.path("a/file.txt"));
    // An index of no row, or of nothing, has no path.
    assert_eq!(f.path_for(5), "");
    f.set("enabled", Value::Bool(false));
    f.settle();
    assert_eq!(f.path_for(0), "");
}
