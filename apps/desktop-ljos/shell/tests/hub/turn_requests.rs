//! The TurnRequests brick as a turn's last question or queued message goes:
//! one write hides its card and empties the Repeater inside it, which on Ljós
//! once never returned (hal-c2/ljos-ui#162).

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::qml::Roots;
use ljos::prelude::ObjectId;
use serde_json::json;

use crate::Hub;

const PROBE: &str = r#"
import QtQuick
import HalC2.Bricks

Item {
    width: 640
    height: 480
    readonly property bool pending: requests.pending

    TurnRequests { id: requests; anchors.fill: parent }
}
"#;

fn probe(hub: &Hub) -> ObjectId {
    let dir = tempfile::tempdir().expect("a directory for the probe");
    std::fs::write(dir.path().join("TurnRequestsProbe.qml"), PROBE).expect("the probe");
    let mut dirs = Roots::checkout().dirs().expect("the roots are there");
    dirs.push(dir.path().to_path_buf());
    let snapshot = ljos::engine();
    hal_c2_shell::register(&snapshot);
    let paths: Vec<&std::path::Path> = dirs.iter().map(|p| p.as_path()).collect();
    let compiled = ljos::dev::compile_quiet(&paths, Some(&snapshot)).expect("the bricks compile");
    hub.show(compiled.source, "TurnRequestsProbe").0
}

fn publish(hub: &Hub, turn: serde_json::Value) {
    let bridge = Bridge::main(&hub.engine);
    bridge.publish(&hub.engine, "composer", json!({"target": "t1"}));
    bridge.publish(&hub.engine, "turn", turn);
    hub.advance(0);
}

fn turn(questions: serde_json::Value, queue: serde_json::Value) -> serde_json::Value {
    json!({
        "threadKey": "t1",
        "approvals": [],
        "questions": questions,
        "queue": queue,
        "waiting": [],
    })
}

#[test]
fn the_last_question_and_queued_message_going_in_one_write_returns() {
    let hub = Hub::new();
    let root = probe(&hub);
    let question = json!({
        "requestId": "r1",
        "canRespond": true,
        "responding": false,
        "questions": [{
            "id": "q1",
            "question": "Start now?",
            "options": [{"label": "Yes"}, {"label": "Later"}],
        }],
    });
    let queued = json!([{"runId": "run-2", "text": "and then the tests"}]);
    publish(&hub, turn(json!([question]), queued));
    assert!(hub.engine.read_by_name(root, "pending").to_boolean());

    publish(&hub, turn(json!([]), json!([])));
    assert!(!hub.engine.read_by_name(root, "pending").to_boolean());
}
