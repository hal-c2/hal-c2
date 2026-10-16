//! `DiffModel` as the diff panel binds it: rows through a view, `split`
//! written from QML, the invokables, and the signals.

mod common;

use std::rc::Rc;

use common::{call, number, read};
use hal_c2_shell::mc::Disconnected;
use hal_c2_shell::thread_view::diff::DiffModel;
use ljos::prelude::{Engine, ObjectId, Value};

const MAIN: &str = r#"
import QtQuick
import HalC2.Shell
Item {
    id: root
    property var model: null
    property int patches: 0
    property int expansions: 0
    readonly property int shown: rows.count
    readonly property int files: root.model ? root.model.fileCount : 0
    readonly property bool split: root.model !== null && root.model.split === true
    readonly property bool allExpanded: root.model !== null && root.model.allExpanded === true
    function labels() {
        const out = [];
        for (let i = 0; i < rows.count; ++i)
            out.push(rows.itemAt(i).label);
        return out.join("|");
    }
    function writeSplit(on) {
        root.model.split = on;
    }
    function treeNames() {
        return root.model.tree().map(n => n.kind + ":" + n.path).join("|");
    }
    function excerptLabel() {
        return root.model.excerpt(0, "new", 1, 1).rangeLabel;
    }
    Connections {
        target: root.model
        ignoreUnknownSignals: true
        function onPatchChanged() {
            root.patches += 1;
        }
        function onExpansionChanged() {
            root.expansions += 1;
        }
    }
    Column {
        Repeater {
            id: rows
            model: root.model
            delegate: Item {
                required property string kind
                required property var model
                readonly property string label: kind + ":" + (model.sign ?? "") + (model.text ?? "")
                    + (model.rightSign ? "|" + model.rightSign + model.rightText : "")
            }
        }
    }
}
"#;

const PATCH: &str = "\
diff --git a/src/a.txt b/src/a.txt
--- a/src/a.txt
+++ b/src/a.txt
@@ -1 +1 @@
-old
+new
diff --git a/b.txt b/b.txt
--- a/b.txt
+++ b/b.txt
@@ -1 +1,2 @@
 same
+more
";

fn fixture() -> (Engine, ObjectId, ObjectId) {
    let engine = common::engine(
        common::compile(&[("Main", MAIN)], &[]),
        Rc::new(Disconnected::default()),
    );
    let root = engine
        .create_from_url("Main", None, Vec::new())
        .expect("Main is made");
    let model = DiffModel::create(&engine, None).expect("the model is made");
    engine
        .write_by_name(root, "model", Value::Object(model))
        .unwrap();
    DiffModel::update(&engine, model, |d| d.set_patch(PATCH));
    (engine, root, model)
}

fn labels(engine: &Engine, root: ObjectId) -> String {
    engine
        .to_js_string(&call(engine, root, "labels", &[]))
        .to_string()
}

#[test]
fn a_view_shows_the_patch_and_follows_expansion() {
    let (e, root, model) = fixture();
    assert_eq!(number(&e, root, "files"), 2.0);
    assert_eq!(number(&e, root, "patches"), 1.0);
    assert_eq!(read(&e, root, "allExpanded"), Value::Bool(true));
    assert_eq!(
        labels(&e, root),
        "file:|hunk:@@ -1 +1 @@|line:-old|line:+new|file:|hunk:@@ -1 +1,2 @@|line: same|line:+more"
    );
    call(&e, model, "toggle", &[Value::Int(0)]);
    assert_eq!(number(&e, root, "shown"), 5.0);
    assert_eq!(read(&e, root, "allExpanded"), Value::Bool(false));
    assert_eq!(number(&e, root, "expansions"), 1.0);
    call(&e, model, "expandAll", &[]);
    assert_eq!(number(&e, root, "shown"), 8.0);
    assert_eq!(number(&e, root, "expansions"), 2.0);
    let row = call(&e, model, "rowOfFile", &[Value::Int(1)]);
    assert_eq!(row.to_number(), 4.0);
    let file = call(&e, model, "fileOf", &[Value::from("b.txt")]);
    assert_eq!(file.to_number(), 1.0);
}

#[test]
fn split_written_from_qml_pairs_the_lines() {
    let (e, root, model) = fixture();
    call(&e, root, "writeSplit", &[Value::Bool(true)]);
    assert_eq!(read(&e, root, "split"), Value::Bool(true));
    assert_eq!(DiffModel::read(&e, model, |d| d.split()), Some(true));
    assert_eq!(
        labels(&e, root),
        "file:|hunk:@@ -1 +1 @@|line:-old|+new|file:|hunk:@@ -1 +1,2 @@|line: same| same|line:|+more"
    );
    // And back, from Rust: the property follows.
    DiffModel::update(&e, model, |d| d.set_split(false));
    assert_eq!(read(&e, root, "split"), Value::Bool(false));
    assert_eq!(number(&e, root, "shown"), 8.0);
}

#[test]
fn the_tree_and_an_excerpt_come_back_as_script_values() {
    let (e, root, _model) = fixture();
    let tree = call(&e, root, "treeNames", &[]);
    assert_eq!(
        e.to_js_string(&tree).to_string(),
        "folder:src|file:src/a.txt|file:b.txt"
    );
    let label = call(&e, root, "excerptLabel", &[]);
    assert_eq!(e.to_js_string(&label).to_string(), "+1");
}
