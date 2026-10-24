//! The real SidebarThreadRow brick, headless: hovering a row swaps its
//! status for its actions without moving its lines.

use hal_c2_shell::qml::Roots;
use ljos::prelude::{ObjectId, Value};

use crate::{Hub, Window};

const PROBE: &str = r#"
import QtQuick
import HalC2.Bricks

Item {
    width: 300
    height: 120
    property alias row: row
    property bool slim: false

    SidebarThreadRow {
        id: row
        width: 280
        height: implicitHeight
        active: false
        slim: parent.slim
        projectName: "project"
        section: "active"
        item: ({
            threadId: "t1",
            title: "A thread title",
            branch: "main",
            canSnooze: true,
            canSettle: true,
            jumpLabel: "1",
            updatedAt: "2026-01-01T00:00:00Z",
            wokeAt: null
        })
    }
}
"#;

/// The checkout's bricks and the probe, compiled as the app compiles them.
fn probe(hub: &Hub) -> (ObjectId, Window) {
    let dir = tempfile::tempdir().expect("a directory for the probe");
    std::fs::write(dir.path().join("RowProbe.qml"), PROBE).expect("the probe");
    let mut dirs = Roots::checkout().dirs().expect("the roots are there");
    dirs.push(dir.path().to_path_buf());
    let snapshot = ljos::engine();
    hal_c2_shell::register(&snapshot);
    let paths: Vec<&std::path::Path> = dirs.iter().map(|p| p.as_path()).collect();
    let compiled = ljos::dev::compile_quiet(&paths, Some(&snapshot)).expect("the bricks compile");
    hub.show(compiled.source, "RowProbe")
}

/// The first object under `obj` whose objectName is `name`.
fn named(hub: &Hub, obj: ObjectId, name: &str) -> Option<ObjectId> {
    let e = &hub.engine;
    e.children(obj).into_iter().find_map(|c| {
        if e.to_js_string(&e.read_by_name(c, "objectName")) == name {
            Some(c)
        } else {
            named(hub, c, name)
        }
    })
}

/// Where `obj` is in the probe, and how tall: (y, height).
fn placed(hub: &Hub, root: ObjectId, obj: ObjectId) -> (f64, f64) {
    let at = hub
        .engine
        .invoke_by_name(
            obj,
            "mapToItem",
            &[Value::Object(root), Value::Real(0.0), Value::Real(0.0)],
        )
        .expect("mapToItem");
    let y = match at {
        Value::Point(p) => p.y,
        other => panic!("a point: {other:?}"),
    };
    (y, hub.engine.read_by_name(obj, "height").to_number())
}

fn shows(hub: &Hub, obj: ObjectId) -> bool {
    hub.engine.read_by_name(obj, "visible").to_boolean()
}

fn row_of(hub: &Hub, root: ObjectId) -> ObjectId {
    match hub.engine.read_by_name(root, "row") {
        Value::Object(o) => o,
        other => panic!("the row: {other:?}"),
    }
}

/// The pointer over the row, or below it.
fn hover(hub: &Hub, window: &Window, over: bool) {
    window.hover(50.0, if over { 18.0 } else { 95.0 });
    hub.advance(0);
}

/// Hovering a card row shows its snooze and settle buttons (22 px) where
/// its age was. The header asks for 22 px either way, so the project line,
/// title and branch stay where they were, level with the jump hint.
#[test]
fn a_card_row_keeps_its_lines_when_hover_shows_its_actions() {
    let hub = Hub::new();
    let (root, window) = probe(&hub);
    hub.advance(0);
    let row = row_of(&hub, root);
    let mark = named(&hub, row, "cardProjectMark").expect("the card's project mark");
    let header = hub.engine.owner(mark).expect("the card's header");
    let title = named(&hub, row, "cardTitle").expect("the card's title");
    let card = hub.engine.owner(title).expect("the card");
    let branch = {
        let lines = hub.engine.children(card);
        let at = lines.iter().position(|c| *c == title).expect("the title");
        lines[at + 1]
    };
    let snooze = named(&hub, header, "snoozeAction").expect("the card's snooze button");
    let lines = || [header, title, branch].map(|l| placed(&hub, root, l));

    let resting = lines();
    hover(&hub, &window, true);
    assert!(shows(&hub, snooze), "hover shows the actions");
    let hovered = lines();
    hover(&hub, &window, false);
    assert!(!shows(&hub, snooze));

    assert_eq!(resting[0].1, 22.0, "the header asks for 22 px");
    assert_eq!(hovered, resting, "hover moves the card's lines");
    assert_eq!(lines(), resting);
}

/// A slim row's title stays put as its actions come and go.
#[test]
fn a_slim_row_keeps_its_title_when_hover_shows_its_actions() {
    let hub = Hub::new();
    let (root, window) = probe(&hub);
    hub.engine
        .write_by_name(root, "slim", Value::Bool(true))
        .expect("slim");
    hub.advance(0);
    let row = row_of(&hub, root);
    let mark = named(&hub, row, "projectMark").expect("the slim project mark");
    let line = hub.engine.owner(mark).expect("the slim line");
    let title = hub.engine.children(line)[1];
    let snooze = named(&hub, line, "snoozeAction").expect("the slim snooze button");

    let resting = placed(&hub, root, title);
    hover(&hub, &window, true);
    assert!(shows(&hub, snooze), "hover shows the actions");
    assert_eq!(placed(&hub, root, title), resting);
}

/// A layout in a layout keeps the `Layout.preferredHeight` it is given
/// though its children are shorter, and so does what follows it: the
/// numbers are Qt's (qml6 6.11.2).
#[test]
fn a_nested_layout_keeps_its_preferred_height_over_shorter_children() {
    let hub = Hub::new();
    let source = crate::common::compile(&[("Nested", NESTED)], &[]);
    let (root, _window) = hub.show(source, "Nested");
    let mut seen = Vec::new();
    for tall in [false, true, false] {
        hub.engine
            .write_by_name(root, "tall", Value::Bool(tall))
            .expect("tall");
        hub.advance(0);
        let n = |p: &str| hub.engine.read_by_name(root, p).to_number();
        seen.push([n("headerY"), n("headerHeight"), n("secondY"), n("thirdY")]);
    }
    assert_eq!(seen, vec![[2.0, 22.0, 26.0, 46.0]; 3]);
}

const NESTED: &str = r#"
import QtQuick
import QtQuick.Layouts

Item {
    id: root
    width: 200
    height: 62
    property bool tall: false
    readonly property real headerY: header.y
    readonly property real headerHeight: header.height
    readonly property real secondY: second.y
    readonly property real thirdY: third.y

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            id: header
            Layout.fillWidth: true
            Layout.preferredHeight: 22
            Rectangle { implicitWidth: 16; implicitHeight: 16 }
            Rectangle { visible: root.tall; implicitWidth: 22; implicitHeight: 22 }
        }
        Rectangle { id: second; Layout.fillWidth: true; implicitHeight: 18 }
        Rectangle { id: third; Layout.fillWidth: true; implicitHeight: 15 }
    }
}
"#;
