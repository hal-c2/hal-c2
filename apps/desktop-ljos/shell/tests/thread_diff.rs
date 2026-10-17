//! `ThreadDiff` as the Diff tab binds it: the diffs asked of an MC that
//! answers when the test says, the thread's timeline followed, the
//! properties QML writes, the signals, comments, reveals and reverts.

mod common;

use std::cell::RefCell;
use std::rc::Rc;

use common::{call, number, read, text};
use hal_c2_shell::json::{self, Json};
use hal_c2_shell::mc::{Disconnected, Mc, McError, OnFrame, OnReady, Reply, Resume, SubId};
use hal_c2_shell::thread_view::thread_diff::ThreadDiff;
use hal_c2_shell::thread_view::timeline::Timeline;
use hal_c2_shell::thread_view::timeline_model::TimelineModel;
use ljos::prelude::{Engine, ObjectId, Value};
use serde_json::json;

const MAIN: &str = r#"
import QtQuick
import HalC2.Shell
Item {
    id: root
    property var tab: null
    property int turns: 0
    property int selections: 0
    property int statuses: 0
    property int focuses: 0
    property int reviews: 0
    property int reverts: 0
    property int revealed: -1
    property var comment: null
    readonly property string state: root.tab ? root.tab.status : "none"
    readonly property int files: root.tab && root.tab.model ? root.tab.model.fileCount : -1
    readonly property int shown: rows.count
    function choices() {
        return root.tab.choices.map(c => c.value + ":" + c.label).join("|");
    }
    function writeBase(base) {
        root.tab.baseRef = base;
    }
    function writeWhitespace(on) {
        root.tab.ignoreWhitespace = on;
    }
    Connections {
        target: root.tab
        ignoreUnknownSignals: true
        function onTurnsChanged() {
            root.turns += 1;
        }
        function onSelectionChanged() {
            root.selections += 1;
        }
        function onStatusChanged() {
            root.statuses += 1;
        }
        function onFocusChanged() {
            root.focuses += 1;
        }
        function onReviewChanged() {
            root.reviews += 1;
        }
        function onRevertChanged() {
            root.reverts += 1;
        }
        function onRevealRow(row) {
            root.revealed = row;
        }
        function onCommentRequested(comment) {
            root.comment = comment;
        }
    }
    Repeater {
        id: rows
        model: root.tab ? root.tab.model : null
        delegate: Item {}
    }
}
"#;

/// An MC that holds every answer until the test gives it.
#[derive(Default)]
struct HoldingMc {
    calls: RefCell<Vec<(String, Json, Reply)>>,
}

impl HoldingMc {
    /// Answers the latest `method` call held; returns what it asked.
    fn answer(&self, engine: &Engine, method: &str, result: Result<Json, &str>) -> Json {
        let at = self
            .calls
            .borrow()
            .iter()
            .rposition(|(m, _, _)| m == method)
            .unwrap_or_else(|| panic!("{method} was asked"));
        let (_, payload, reply) = self.calls.borrow_mut().remove(at);
        reply(
            engine,
            result.map_err(|message| McError {
                message: message.into(),
                detail: Json::Null,
            }),
        );
        payload
    }

    fn methods(&self) -> Vec<String> {
        self.calls
            .borrow()
            .iter()
            .map(|(m, _, _)| m.clone())
            .collect()
    }
}

impl Mc for HoldingMc {
    fn is_ready(&self) -> bool {
        true
    }

    fn environment(&self) -> String {
        "env-1".into()
    }

    fn call(&self, environment: &str, method: &str, payload: Json, reply: Reply) {
        assert_eq!(environment, "env-1");
        self.calls
            .borrow_mut()
            .push((method.into(), payload, reply));
    }

    fn subscribe(&self, _: Json, _: OnFrame, _: Option<Resume>) -> SubId {
        SubId(0)
    }

    fn unsubscribe(&self, _: SubId) {}

    fn more(&self, _: SubId, _: u32) {}

    fn on_ready_changed(&self, _: OnReady) {}
}

fn patch_of(files: &[&str]) -> String {
    files
        .iter()
        .map(|f| format!("diff --git a/{f} b/{f}\n--- a/{f}\n+++ b/{f}\n@@ -1 +1 @@\n-old\n+new\n"))
        .collect()
}

struct Fixture {
    engine: Engine,
    root: ObjectId,
    tab: ObjectId,
    timeline: ObjectId,
    mc: Rc<HoldingMc>,
    toasts: Rc<RefCell<Vec<String>>>,
}

fn fixture() -> Fixture {
    let engine = common::engine(
        common::compile(&[("Main", MAIN)], &[]),
        Rc::new(Disconnected::default()),
    );
    let root = engine
        .create_from_url("Main", None, Vec::new())
        .expect("Main is made");
    let mc = Rc::new(HoldingMc::default());
    let toasts = Rc::new(RefCell::new(Vec::new()));
    let told = toasts.clone();
    let tab = ThreadDiff::create(
        &engine,
        None,
        mc.clone(),
        move |_, kind, title, description| {
            told.borrow_mut()
                .push(format!("{kind}: {title}: {description}"));
        },
    )
    .expect("the tab is made");
    let timeline = TimelineModel::create(&engine, None, Timeline::new("env-1:t1"))
        .expect("the timeline is made");
    engine
        .write_by_name(root, "tab", Value::Object(tab))
        .unwrap();
    Fixture {
        engine,
        root,
        tab,
        timeline,
        mc,
        toasts,
    }
}

impl Fixture {
    /// The thread's checkpoints, (id, turn), all ready, as its stream sends
    /// them.
    fn stream(&self, checkpoints: &[(&str, i32)]) {
        let rows: Vec<Json> = checkpoints
            .iter()
            .map(|(id, turn)| {
                json!(["checkpoint", id, {"id": id, "appRunOrdinal": turn, "status": "ready", "scopeId": "s"}])
            })
            .collect();
        let frame = json!({"t": "snapshot", "part": 0, "done": true, "rows": rows, "offset": rows.len(), "handle": "log"});
        let Json::Object(frame) = frame else {
            unreachable!()
        };
        TimelineModel::update(&self.engine, self.timeline, |t| t.receive(&frame));
    }

    fn count(&self, name: &str) -> f64 {
        number(&self.engine, self.root, name)
    }

    /// Shows t1 with its turn 1 diffed: a.txt and b.txt.
    fn show(&self) {
        self.stream(&[("cp-1", 1)]);
        ThreadDiff::update(&self.engine, self.tab, |t| t.set_active(true));
        ThreadDiff::set_thread(&self.engine, self.tab, "env-1", "t1", Some(self.timeline));
        assert_eq!(text(&self.engine, self.root, "state"), "loading");
        let asked = self.mc.answer(
            &self.engine,
            "orchestration.getTurnDiff",
            Ok(json!({"diff": patch_of(&["a.txt", "b.txt"])})),
        );
        assert_eq!(
            asked,
            json!({"threadId": "t1", "ignoreWhitespace": true, "fromTurnCount": 0, "toTurnCount": 1})
        );
        assert_eq!(text(&self.engine, self.root, "state"), "ready");
    }
}

#[test]
fn the_tab_diffs_the_latest_turn_and_follows_the_timeline() {
    let f = fixture();
    f.show();
    assert_eq!(f.count("files"), 2.0);
    assert!(f.count("shown") > 0.0);
    assert_eq!(f.count("turns"), 1.0);
    // idle -> loading -> ready
    assert_eq!(f.count("statuses"), 2.0);
    assert_eq!(number(&f.engine, f.tab, "shownTurn"), 1.0);
    assert_eq!(
        f.engine
            .to_js_string(&call(&f.engine, f.root, "choices", &[]))
            .to_string(),
        "-1:Latest turn|0:All changes|1:Turn 1"
    );

    // Another turn finishes: the picker has it and the latest diff is asked.
    f.stream(&[("cp-1", 1), ("cp-2", 2)]);
    assert_eq!(f.count("turns"), 2.0);
    assert_eq!(f.mc.methods(), ["orchestration.getTurnDiff"]);
    assert_eq!(number(&f.engine, f.tab, "latestTurn"), 2.0);

    // The whitespace option asks again; the base is kept trimmed.
    call(&f.engine, f.root, "writeWhitespace", &[Value::Bool(false)]);
    let asked = f.mc.answer(
        &f.engine,
        "orchestration.getTurnDiff",
        Ok(json!({"diff": patch_of(&["c.txt"])})),
    );
    assert_eq!(asked["ignoreWhitespace"], false);
    // The first answer is stale.
    f.mc.answer(
        &f.engine,
        "orchestration.getTurnDiff",
        Ok(json!({"diff": patch_of(&["a.txt", "b.txt"])})),
    );
    assert_eq!(f.count("files"), 1.0);
    call(&f.engine, f.root, "writeBase", &[Value::from(" dev ")]);
    assert_eq!(text(&f.engine, f.tab, "baseRef"), "dev");
    assert_eq!(f.count("reviews"), 1.0);
    call(&f.engine, f.root, "writeBase", &[Value::from("dev ")]);
    assert_eq!(text(&f.engine, f.tab, "baseRef"), "dev");
    assert_eq!(f.count("reviews"), 1.0);

    // Picking turn 1 changes the selection once.
    call(&f.engine, f.tab, "select", &[Value::Int(1)]);
    assert_eq!(f.count("selections"), 1.0);
    assert_eq!(number(&f.engine, f.tab, "selection"), 1.0);
}

#[test]
fn a_comment_a_reveal_and_a_revert() {
    let f = fixture();
    f.show();
    call(&f.engine, f.tab, "revealFile", &[Value::from("b.txt")]);
    assert!(f.count("revealed") > 0.0);

    let commented = call(
        &f.engine,
        f.tab,
        "comment",
        &[
            Value::from("a.txt"),
            Value::from("new"),
            Value::Int(1),
            Value::Int(1),
            Value::from("why"),
        ],
    );
    assert!(matches!(commented, Value::Bool(true)));
    let comment = json::from_value(&f.engine, &read(&f.engine, f.root, "comment"));
    assert_eq!(comment["sectionTitle"], "Latest turn");
    assert_eq!(comment["sectionId"], "diff:-1");
    assert_eq!(comment["filePath"], "a.txt");
    assert_eq!(comment["text"], "why");

    call(&f.engine, f.tab, "focusFile", &[Value::from("b.txt")]);
    assert_eq!(text(&f.engine, f.tab, "focusPath"), "b.txt");
    assert_eq!(f.count("files"), 1.0);
    assert_eq!(f.count("focuses"), 2.0);

    // The diff came with a checkpoint to revert to: canRevert said so.
    assert_eq!(f.count("reverts"), 1.0);
    call(&f.engine, f.tab, "requestRevert", &[Value::Int(0)]);
    assert_eq!(number(&f.engine, f.tab, "revertTurn"), 1.0);
    assert_eq!(f.count("reverts"), 2.0);
    call(&f.engine, f.tab, "confirmRevert", &[Value::Bool(true)]);
    assert_eq!(read(&f.engine, f.tab, "reverting"), Value::Bool(true));
    let asked =
        f.mc.answer(&f.engine, "orchestration.dispatchCommand", Ok(json!({})));
    assert_eq!(asked["type"], "checkpoint.rollback");
    assert_eq!(asked["checkpointId"], "cp-1");
    assert_eq!(asked["scopeId"], "s");
    assert_eq!(asked["restoreFiles"], true);
    let id = asked["commandId"].as_str().unwrap_or_default();
    let uuid =
        regex::Regex::new(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
            .unwrap();
    assert!(uuid.is_match(id), "{id} is a v4 UUID");
    assert_eq!(read(&f.engine, f.tab, "reverting"), Value::Bool(false));
    assert_eq!(*f.toasts.borrow(), ["success: Reverted to turn 1.: "]);
}
