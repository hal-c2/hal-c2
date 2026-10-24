//! The real Composer brick over the composer controller: wrapping, new
//! lines, dropped files and the attach dialog, headless.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use hal_c2_shell::qml::Roots;
use ljos::keys::{KeyEvent, Modifiers, key};
use ljos::prelude::{
    DialogAnswer, DialogKind, DialogReply, DialogRequest, DialogService, ObjectId, Platform, Value,
};
use serde_json::json;

use crate::composer::on_threads;
use crate::{Hub, Window};

const PROBE: &str = r#"
import QtQuick
import HalC2.Bricks

Item {
    id: probe
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

    // Presses the attach button, as a click does; false when it is not
    // there or not enabled.
    function clickAttach() {
        const button = find(composer);
        if (!button || !button.enabled) return false;
        button.clicked();
        return true;
    }
    function find(item) {
        if (item.iconName === "paperclip") return item;
        for (let i = 0; i < item.children.length; ++i) {
            const found = find(item.children[i]);
            if (found) return found;
        }
        return null;
    }

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

/// The system's dialogs as a test sees them: each one asked for, with the
/// way to answer it.
#[derive(Clone, Default)]
struct SystemDialogs(Rc<RefCell<Vec<(DialogRequest, DialogAnswer)>>>);

impl DialogService for SystemDialogs {
    fn can_show(&self, _request: &DialogRequest) -> bool {
        true
    }

    fn show(&self, request: DialogRequest, answer: DialogAnswer) {
        self.0.borrow_mut().push((request, answer));
    }

    fn close(&self, _ticket: u64) {}
}

/// A short QuickTime movie's first box, under `name` in `dir`: all the
/// composer reads of a screen recording is its name and its bytes.
fn movie(dir: &Path, name: &str) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, b"\0\0\0\x14ftypqt  \0\0\0\0qt  ").expect("the movie");
    path
}

/// What the platform and the composer owe: the dialog's answer, the file
/// read on the compute pool, and what each deferred.
fn deliver(hub: &crate::Hub) {
    Platform::of(&hub.engine).finish(&hub.engine);
    hub.advance(0);
}

/// The file `name` of `size` bytes goes to the MC as a video, and its chip
/// shows a file uploaded.
fn uploads_as_a_video(hub: &crate::Hub, name: &str, size: u64) {
    let asked = hub
        .mc
        .pending("attachments.createUploadUrl")
        .expect("the composer asks where to upload");
    let payload = hub.mc.calls.borrow()[asked].2.clone();
    assert_eq!(
        payload,
        json!({"type": "file", "name": name, "mimeType": "video/quicktime", "sizeBytes": size})
    );
    hub.mc.reply(
        &hub.engine,
        asked,
        Ok(json!({"relativeUrl": "/api/attachments/upload/token", "attachmentId": "pending-1"})),
    );
    hub.advance(0);
    let upload = hub
        .mc
        .pending("http.upload")
        .expect("the bytes go to the MC");
    assert_eq!(
        hub.mc.calls.borrow()[upload].2,
        json!({"relativeUrl": "/api/attachments/upload/token", "mimeType": "video/quicktime", "sizeBytes": size})
    );
    hub.mc
        .reply(&hub.engine, upload, Ok(serde_json::Value::Null));
    hub.advance(0);
    let attachments = hub.published("composer")["attachments"].clone();
    assert_eq!(
        attachments.as_array().map(Vec::len),
        Some(1),
        "{attachments}"
    );
    assert_eq!(attachments[0]["name"], name);
    assert_eq!(attachments[0]["kind"], "file");
    assert_eq!(attachments[0]["status"], "", "{attachments}");
}

/// The attach button's dialog lets the user pick any file, not only the
/// images of its second filter, and a screen recording picked there is
/// uploaded as a video, as desktop-qt does.
#[test]
fn a_recording_picked_in_the_attach_dialog_is_uploaded() {
    let hub = on_threads(&["t1"]);
    let system = SystemDialogs::default();
    Platform::of(&hub.engine).set_dialogs(Rc::new(system.clone()));
    hal_c2_shell::file_dialogs::install(&hub.engine);
    let (root, _window) = probe(&hub);
    let dir = tempfile::tempdir().expect("a directory for the movie");
    let recording = movie(
        dir.path(),
        "Screen Recording 2026-10-24 at 10.37.12\u{202f}AM.mov",
    );

    assert_eq!(
        crate::common::call(&hub.engine, root, "clickAttach", &[]),
        Value::Bool(true)
    );
    hub.advance(0);
    let (request, answer) = system
        .0
        .borrow_mut()
        .pop()
        .expect("the system's dialog is shown");
    assert_eq!(request.kind, Some(DialogKind::OpenFiles));
    assert!(
        request.filters.is_empty(),
        "every file can be chosen: {:?}",
        request.filters
    );
    answer.send(DialogReply::Files(vec![recording.clone()]));
    deliver(&hub);
    deliver(&hub);

    let name = recording
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    uploads_as_a_video(&hub, &name, 20);
}

/// A dialog whose filters all name extensions keeps them.
#[test]
fn a_dialog_of_some_files_keeps_its_filters() {
    let hub = on_threads(&["t1"]);
    let system = SystemDialogs::default();
    Platform::of(&hub.engine).set_dialogs(Rc::new(system.clone()));
    hal_c2_shell::file_dialogs::install(&hub.engine);
    let source = crate::common::compile(
        &[(
            "Picker",
            r#"
import QtQuick
import QtQuick.Dialogs

Item {
    function pick() { dialog.open() }
    FileDialog { id: dialog; nameFilters: ["Theme files (*.json)"] }
}
"#,
        )],
        &[],
    );
    let (picker, _window) = hub.show(source, "Picker");
    crate::common::call(&hub.engine, picker, "pick", &[]);
    hub.advance(0);
    let (request, _answer) = system
        .0
        .borrow_mut()
        .pop()
        .expect("the system's dialog is shown");
    assert_eq!(request.filters.len(), 1);
    assert_eq!(request.filters[0].patterns, vec!["*.json".to_owned()]);
}

/// A screen recording dropped on the card is uploaded as a video.
#[test]
fn a_recording_dropped_on_the_card_is_uploaded() {
    let hub = on_threads(&["t1"]);
    let (root, _window) = probe(&hub);
    let dir = tempfile::tempdir().expect("a directory for the movie");
    let recording = movie(dir.path(), "rec.mov");
    let at = match hub.engine.read_by_name(root, "beside") {
        Value::Point(p) => (p.x, p.y),
        other => panic!("a point: {other:?}"),
    };
    assert!(ljos::prelude::external_drag(
        &hub.engine,
        &ljos::prelude::ExternalDrag::Dropped {
            files: vec![recording],
            at: Some(at),
        },
    ));
    deliver(&hub);
    uploads_as_a_video(&hub, "rec.mov", 20);
}
