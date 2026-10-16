//! `FileTreeModel` as the Files tab binds it: rows through a view, folders
//! asked of the owner and answered late, the invokables, the properties and
//! the signals.

mod common;

use std::cell::RefCell;
use std::rc::Rc;

use common::{call, number, read, text};
use hal_c2_shell::mc::Disconnected;
use hal_c2_shell::thread_view::file_tree::{Entry, FileTreeModel};
use ljos::prelude::{Engine, ObjectId, Value};

const MAIN: &str = r#"
import QtQuick
import HalC2.Shell
Item {
    id: root
    property var tree: null
    property int settled: 0
    property string lastSettled: "-"
    property int selections: 0
    readonly property string rootStatus: root.tree ? root.tree.rootStatus : "none"
    readonly property bool allExpanded: root.tree !== null && root.tree.allExpanded === true
    readonly property bool filtered: root.tree !== null && root.tree.filtered === true
    readonly property int shown: rows.count
    function labels() {
        const out = [];
        for (let i = 0; i < rows.count; ++i)
            out.push(rows.itemAt(i).label);
        return out.join("|");
    }
    function names(folder) {
        return root.tree.entriesIn(folder).map(e => e.name + (e.directory ? "/" : "")).join(",");
    }
    Connections {
        target: root.tree
        ignoreUnknownSignals: true
        function onFolderSettled(folder) {
            root.settled += 1;
            root.lastSettled = folder;
        }
        function onSelectedChanged() {
            root.selections += 1;
        }
    }
    Column {
        Repeater {
            id: rows
            model: root.tree
            delegate: Item {
                required property string path
                required property string kind
                required property int depth
                required property bool expanded
                required property bool selected
                readonly property string label: "  ".repeat(depth) + kind + ":" + path
                    + (expanded ? " open" : "") + (selected ? " *" : "")
            }
        }
    }
}
"#;

struct Fixture {
    engine: Engine,
    root: ObjectId,
    tree: ObjectId,
    asked: Rc<RefCell<Vec<String>>>,
}

fn fixture() -> Fixture {
    let engine = common::engine(
        common::compile(&[("Main", MAIN)], &[]),
        Rc::new(Disconnected::default()),
    );
    let root = engine
        .create_from_url("Main", None, Vec::new())
        .expect("Main is made");
    let asked = Rc::new(RefCell::new(Vec::new()));
    let log = asked.clone();
    let tree = FileTreeModel::create(&engine, None, move |_, _, folder| {
        log.borrow_mut().push(folder.to_owned());
    })
    .expect("the tree is made");
    engine
        .write_by_name(root, "tree", Value::Object(tree))
        .unwrap();
    Fixture {
        engine,
        root,
        tree,
        asked,
    }
}

impl Fixture {
    fn labels(&self) -> String {
        self.engine
            .to_js_string(&call(&self.engine, self.root, "labels", &[]))
            .to_string()
    }

    fn list(&self, folder: &str, entries: &[(&str, bool)]) {
        let entries = entries
            .iter()
            .map(|(path, directory)| Entry::new(path, *directory, false))
            .collect();
        FileTreeModel::update(&self.engine, self.tree, |t| {
            t.set_listing(folder, entries);
        });
    }

    fn asked(&self) -> Vec<String> {
        std::mem::take(&mut self.asked.borrow_mut())
    }
}

#[test]
fn folders_load_as_they_open_and_the_view_follows() {
    let f = fixture();
    FileTreeModel::update(&f.engine, f.tree, |t| t.reload());
    assert_eq!(f.asked(), [""]);
    assert_eq!(text(&f.engine, f.root, "rootStatus"), "loading");
    assert_eq!(f.labels(), "loading:");

    f.list("", &[("src", true), ("README.md", false)]);
    assert_eq!(text(&f.engine, f.root, "rootStatus"), "ready");
    assert_eq!(text(&f.engine, f.root, "lastSettled"), "");
    assert_eq!(f.labels(), "directory:src|file:README.md");

    call(&f.engine, f.tree, "toggle", &[Value::from("src")]);
    assert_eq!(f.asked(), ["src"]);
    assert_eq!(
        f.labels(),
        "directory:src open|  loading:src|file:README.md"
    );

    // The listing lands late: only src's rows change.
    f.list("src", &[("src/main.rs", false)]);
    assert_eq!(number(&f.engine, f.root, "settled"), 2.0);
    assert_eq!(text(&f.engine, f.root, "lastSettled"), "src");
    assert_eq!(
        f.labels(),
        "directory:src open|  file:src/main.rs|file:README.md"
    );

    call(&f.engine, f.tree, "select", &[Value::from("src/main.rs")]);
    assert_eq!(number(&f.engine, f.root, "selections"), 1.0);
    let row = call(&f.engine, f.tree, "rowOf", &[Value::from("src/main.rs")]);
    assert_eq!(row.to_number(), 1.0);
    assert!(f.labels().contains("file:src/main.rs *"));

    call(&f.engine, f.tree, "collapse", &[Value::from("src")]);
    assert_eq!(f.labels(), "directory:src|file:README.md");
    let row = call(&f.engine, f.tree, "rowOf", &[Value::from("src/main.rs")]);
    assert_eq!(row.to_number(), -1.0);

    let names = call(&f.engine, f.root, "names", &[Value::from("")]);
    assert_eq!(f.engine.to_js_string(&names).to_string(), "src/,README.md");
}

#[test]
fn a_failed_folder_is_retried_and_expand_all_follows_listings() {
    let f = fixture();
    FileTreeModel::update(&f.engine, f.tree, |t| t.reload());
    f.asked();
    FileTreeModel::update(&f.engine, f.tree, |t| t.set_failed("", "no such folder"));
    assert_eq!(text(&f.engine, f.root, "rootStatus"), "error");
    assert_eq!(text(&f.engine, f.tree, "rootProblem"), "no such folder");
    call(&f.engine, f.tree, "retry", &[Value::from("")]);
    assert_eq!(f.asked(), [""]);
    assert_eq!(text(&f.engine, f.root, "rootStatus"), "loading");

    f.list("", &[("a", true)]);
    call(&f.engine, f.tree, "expandAll", &[]);
    assert_eq!(read(&f.engine, f.root, "allExpanded"), Value::Bool(true));
    assert_eq!(f.asked(), ["a"]);
    // A folder that turns up while everything is open opens too.
    f.list("a", &[("a/b", true)]);
    assert_eq!(f.asked(), ["a/b"]);
    f.list("a/b", &[("a/b/c.txt", false)]);
    assert_eq!(
        f.labels(),
        "directory:a open|  directory:a/b open|    file:a/b/c.txt"
    );

    call(&f.engine, f.tree, "collapseAll", &[]);
    assert_eq!(read(&f.engine, f.root, "allExpanded"), Value::Bool(false));
    assert_eq!(f.labels(), "directory:a");
}

#[test]
fn a_search_swaps_its_tree_in_and_out() {
    let f = fixture();
    FileTreeModel::update(&f.engine, f.tree, |t| t.reload());
    f.list("", &[("a", true), ("z.txt", false)]);
    FileTreeModel::update(&f.engine, f.tree, |t| {
        t.set_search(Some(vec![Entry::new("a/b/hit.rs", false, false)]));
    });
    assert_eq!(read(&f.engine, f.root, "filtered"), Value::Bool(true));
    assert_eq!(
        f.labels(),
        "directory:a open|  directory:a/b open|    file:a/b/hit.rs"
    );
    FileTreeModel::update(&f.engine, f.tree, |t| t.set_search(None));
    assert_eq!(read(&f.engine, f.root, "filtered"), Value::Bool(false));
    assert_eq!(f.labels(), "directory:a|file:z.txt");
}
