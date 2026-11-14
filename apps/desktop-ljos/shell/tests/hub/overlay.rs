//! Popups centred in the overlay (`parent: Overlay.overlay`, x and y from
//! the parent's size), as the Git and plan dialogs are. The bindings first
//! run while the popup is not yet in a window, where `Overlay.overlay` is
//! null (and the QML logs a TypeError once for each); they must run again
//! once the item is in the window, so the dialog opens centred.
//!
//! The hub's window is 100 by 100, so a popup of width w and height h is
//! at ((100 - w) / 2, (100 - h) / 2) once it is open.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::qml::Roots;
use ljos::prelude::{ObjectId, Value};

use crate::Hub;

const MINIMAL: &str = r#"
import QtQuick
import QtQuick.Controls.Basic

Item {
    id: probe
    width: 640
    height: 480

    function popup(name) { return dialog }

    Item {
        Popup {
            id: dialog
            parent: Overlay.overlay
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            width: 200
            height: 50
            modal: true
        }
    }
}
"#;

/// The Git pill and the turn requests, with `popup(name)` finding a
/// popup of theirs by `objectName` among the things they declare.
const BRICKS: &str = r#"
import QtQuick
import HalC2.Bricks

Item {
    id: probe
    width: 640
    height: 480

    function popup(name) {
        return find(git, name) ?? find(requests, name);
    }
    function find(item, name) {
        for (let i = 0; i < item.data.length; ++i) {
            const child = item.data[i];
            if (child.objectName === name) return child;
            if (child.data !== undefined) {
                const found = find(child, name);
                if (found) return found;
            }
        }
        return null;
    }

    GitActions { id: git }
    TurnRequests { id: requests }
}
"#;

fn probe(hub: &Hub, qml: &str) -> ObjectId {
    let dir = tempfile::tempdir().expect("a directory for the probe");
    std::fs::write(dir.path().join("OverlayProbe.qml"), qml).expect("the probe");
    let mut dirs = Roots::checkout().dirs().expect("the roots are there");
    dirs.push(dir.path().to_path_buf());
    let snapshot = ljos::engine();
    hal_c2_shell::register(&snapshot);
    let paths: Vec<&std::path::Path> = dirs.iter().map(|p| p.as_path()).collect();
    let compiled = ljos::dev::compile_quiet(&paths, Some(&snapshot)).expect("the bricks compile");
    hub.show(compiled.source, "OverlayProbe").0
}

fn num(hub: &Hub, obj: ObjectId, name: &str) -> f64 {
    hub.engine.read_by_name(obj, name).to_number()
}

/// The popup `name` of the probe, opened after the start-up, and where
/// it is.
fn opened(hub: &Hub, root: ObjectId, name: &str) -> (ObjectId, (f64, f64)) {
    let Value::Object(dialog) = hub
        .engine
        .invoke_by_name(root, "popup", &[Value::from(name)])
        .expect("the popup")
    else {
        panic!("no popup {name}");
    };
    hub.advance(0);
    hub.engine
        .invoke_by_name(dialog, "open", &[])
        .expect("open it");
    hub.advance(0);
    (dialog, (num(hub, dialog, "x"), num(hub, dialog, "y")))
}

/// Where `Math.round((100 - size * scale) / 2)` puts the popup (JS rounds
/// halves up).
fn centred(hub: &Hub, dialog: ObjectId) -> (f64, f64) {
    let scale = num(hub, dialog, "scale");
    let at = |size: &str| ((100.0 - num(hub, dialog, size) * scale) / 2.0 + 0.5).floor();
    (at("width"), at("height"))
}

#[test]
fn a_popup_centred_in_the_overlay_opens_centred() {
    let hub = Hub::new();
    let root = probe(&hub, MINIMAL);
    let (dialog, at) = opened(&hub, root, "dialog");
    assert_eq!(at, (-50.0, 25.0));
    assert_eq!(at, centred(&hub, dialog));
}

#[test]
fn the_git_and_plan_dialogs_open_centred() {
    let hub = Hub::new();
    let root = probe(&hub, BRICKS);
    for name in ["commitDialog", "publishDialog", "planSaveDialog"] {
        let (dialog, at) = opened(&hub, root, name);
        assert_eq!(at, centred(&hub, dialog), "{name}");
    }
}

const WINDOW: &str = r#"
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Window

Window {
    width: 640
    height: 480

    Item {
        anchors.fill: parent

        Popup {
            parent: Overlay.overlay
            x: Math.round((parent.width - width) / 2)
            y: Math.round((parent.height - height) / 2)
            width: 200
            height: 100
        }
    }
}
"#;

/// `Overlay.overlay` is there when the bindings of a `Window`'s tree first
/// run, as in Qt, so nothing is logged.
#[test]
fn a_popup_centred_in_a_window_logs_nothing_at_start_up() {
    let hub = Hub::new();
    let logs = Rc::new(RefCell::new(Vec::<String>::new()));
    let sink = logs.clone();
    hub.engine
        .set_log_handler(move |entry| sink.borrow_mut().push(entry.message.clone()));
    probe(&hub, WINDOW);
    hub.advance(0);
    let logged = logs.borrow().clone();
    assert!(logged.is_empty(), "start-up logged {logged:#?}");
}
