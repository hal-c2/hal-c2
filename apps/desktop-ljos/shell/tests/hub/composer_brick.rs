//! The real Composer brick over the composer controller: wrapping, new
//! lines and dropped files, headless.

use hal_c2_shell::qml::Roots;
use ljos::keys::{KeyEvent, Modifiers, key};
use ljos::prelude::{ObjectId, Value};

use crate::composer::on_threads;
use crate::{Hub, Window};

const PROBE: &str = r#"
import QtQuick
import HalC2.Bricks

Item {
    width: 640
    height: 480
    property alias composer: composer
    readonly property var input: composer.editor
    readonly property real inputWidth: input.width
    readonly property real inputHeight: input.implicitHeight
    readonly property int lines: input.lineCount
    readonly property string text: input.text
    // A point on the card beside the input, in the probe.
    readonly property point beside: input.mapToItem(this, -8, -8)

    Composer {
        id: composer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: implicitHeight
    }
}
"#;

/// The checkout's bricks and the probe, compiled as the app compiles them.
fn probe(hub: &Hub) -> (ObjectId, Window) {
    let dir = tempfile::tempdir().expect("a directory for the probe");
    std::fs::write(dir.path().join("ComposerProbe.qml"), PROBE).expect("the probe");
    let mut dirs = Roots::checkout().dirs().expect("the roots are there");
    dirs.push(dir.path().to_path_buf());
    let snapshot = ljos::engine();
    hal_c2_shell::register(&snapshot);
    let paths: Vec<&std::path::Path> = dirs.iter().map(|p| p.as_path()).collect();
    let compiled = ljos::dev::compile_quiet(&paths, Some(&snapshot)).expect("the bricks compile");
    hub.show(compiled.source, "ComposerProbe")
}

fn num(hub: &Hub, obj: ObjectId, name: &str) -> f64 {
    hub.engine.read_by_name(obj, name).to_number()
}

fn text(hub: &Hub, obj: ObjectId, name: &str) -> String {
    hub.engine
        .to_js_string(&hub.engine.read_by_name(obj, name))
        .to_string()
}

fn input(hub: &Hub, root: ObjectId) -> ObjectId {
    match hub.engine.read_by_name(root, "input") {
        Value::Object(o) => o,
        other => panic!("the composer's input: {other:?}"),
    }
}

/// A long prompt wraps at the card's width and the input grows a line.
#[test]
fn a_long_prompt_wraps_inside_the_card_and_grows_it() {
    let hub = on_threads(&["t1"]);
    let (root, _window) = probe(&hub);
    let input = input(&hub, root);
    let one_line = num(&hub, root, "inputHeight");
    let long = "Read the plugin loader and the theme loader, find where each one looks \
                for its files, and make both read from the config home, not the cache.";
    hub.engine
        .write_by_name(input, "text", Value::from(long))
        .expect("the text");
    hub.advance(0);
    let width = num(&hub, root, "inputWidth");
    assert!(width <= 640.0, "the input is {width} wide in a 640 card");
    assert!(num(&hub, root, "lines") > 1.0);
    assert!(num(&hub, root, "inputHeight") > one_line);
}

/// Shift+Return is no send intent, so the editor takes it as a new line.
/// Return's text is "\r", as a window gives it.
#[test]
fn shift_return_starts_a_new_line() {
    let hub = on_threads(&["t1"]);
    let (root, window) = probe(&hub);
    let input = input(&hub, root);
    hub.engine
        .invoke_by_name(input, "forceActiveFocus", &[])
        .expect("focus");
    for c in ["a", "b"] {
        window.key(&KeyEvent::press(key::A).with_text(c));
    }
    window.key(
        &KeyEvent::press(key::RETURN)
            .with_modifiers(Modifiers::SHIFT)
            .with_text("\r"),
    );
    window.key(&KeyEvent::press(key::A).with_text("c"));
    hub.advance(0);
    assert_eq!(text(&hub, root, "text"), "ab\nc");
    assert_eq!(num(&hub, root, "lines"), 2.0);
}

/// A file dropped from another app on the card is read into the draft.
#[test]
fn a_file_dropped_on_the_card_joins_the_draft() {
    let hub = on_threads(&["t1"]);
    let (root, _window) = probe(&hub);
    let dir = tempfile::tempdir().expect("a directory for the file");
    let file = dir.path().join("notes.txt");
    std::fs::write(&file, "some notes").expect("the file");
    let at = match hub.engine.read_by_name(root, "beside") {
        Value::Point(p) => (p.x, p.y),
        other => panic!("a point: {other:?}"),
    };
    let taken = ljos::prelude::external_drag(
        &hub.engine,
        &ljos::prelude::ExternalDrag::Dropped {
            files: vec![file],
            at: Some(at),
        },
    );
    hub.advance(0);
    assert!(taken);
    let attachments = hub.published("composer")["attachments"].clone();
    assert_eq!(
        attachments.as_array().map(Vec::len),
        Some(1),
        "{attachments}"
    );
    assert_eq!(attachments[0]["name"], "notes.txt");
}
