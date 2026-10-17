//! `TimelineModel` as QML binds it: rows through a view, the row signals
//! the Timeline brick holds its place with, the properties, invokables and
//! the flush timer.

mod common;

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use common::{call, number, read};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::Disconnected;
use hal_c2_shell::thread_view::cache::{ThreadCache, ThreadUpdate};
use hal_c2_shell::thread_view::time::{Clock, Zone, parse_iso};
use hal_c2_shell::thread_view::timeline::{Out, Timeline};
use hal_c2_shell::thread_view::timeline_model::TimelineModel;
use ljos::prelude::ClipboardMode;
use ljos::prelude::{Engine, ObjectId, Platform, Value};
use ljos_runtime::{Clock as _, VirtualClock};
use serde_json::json;

const MAIN: &str = r#"
import QtQuick
import HalC2.Shell
Item {
    id: root
    property var model: null
    property int aboutToInsert: 0
    property int inserted: 0
    property int wanted: 0
    readonly property int shown: rows.count
    readonly property string status: root.model ? root.model.status : ""
    readonly property bool working: root.model !== null && root.model.working === true
    readonly property bool hasEarlier: root.model !== null && root.model.hasEarlier === true
    function labels() {
        const out = [];
        for (let i = 0; i < rows.count; ++i)
            out.push(rows.itemAt(i).label);
        return out.join("|");
    }
    Connections {
        target: root.model
        ignoreUnknownSignals: true
        function onRowsAboutToBeInserted(parent, first, last) {
            root.aboutToInsert += last - first + 1;
        }
        function onRowsInserted(parent, first, last) {
            root.inserted += last - first + 1;
        }
        function onEarlierWanted(items) {
            root.wanted = items;
        }
    }
    Column {
        Repeater {
            id: rows
            model: root.model
            delegate: Item {
                required property string rowId
                required property string kind
                required property var model
                readonly property string label: kind + ":" + (model.text ?? "")
            }
        }
    }
}
"#;

fn obj(value: Json) -> serde_json::Map<String, Json> {
    match value {
        Json::Object(o) => o,
        _ => panic!("not an object"),
    }
}

#[derive(Default)]
struct Stores(Cell<usize>);

impl ThreadCache for Stores {
    fn store_thread(&self, _update: ThreadUpdate) {
        self.0.set(self.0.get() + 1);
    }
    fn trim_thread(&self, _key: &str, _floor: i64) {}
}

struct Fixture {
    engine: Engine,
    root: ObjectId,
    model: ObjectId,
    clock: Arc<VirtualClock>,
    stores: Rc<Stores>,
}

fn fixture() -> Fixture {
    let engine = common::engine(
        common::compile(&[("Main", MAIN)], &[]),
        Rc::new(Disconnected::default()),
    );
    let clock = Arc::new(VirtualClock::new());
    engine.set_clock(Rc::new(clock.clone()));
    let root = engine
        .create_from_url("Main", None, Vec::new())
        .expect("Main is made");
    let mut timeline = Timeline::new("env:thread");
    timeline.set_clock(Clock::fixed(
        parse_iso("2026-09-23T10:00:00Z", Zone::utc()).unwrap(),
    ));
    let stores = Rc::new(Stores::default());
    timeline.set_cache(Some(stores.clone()));
    let model = TimelineModel::create(&engine, None, timeline).expect("the model is made");
    engine
        .write_by_name(root, "model", Value::Object(model))
        .unwrap();
    Fixture {
        engine,
        root,
        model,
        clock,
        stores,
    }
}

impl Fixture {
    fn receive(&self, frame: Json) {
        TimelineModel::update(&self.engine, self.model, |t| t.receive(&obj(frame)));
    }

    fn open(&self, rows: Json, floor: Json) {
        TimelineModel::update(&self.engine, self.model, |t| {
            t.subscribing();
        });
        self.receive(
            json!({"t": "snapshot", "part": 0, "rows": rows, "done": true,
                            "offset": 3, "handle": "log-1", "floor": floor}),
        );
        self.receive(json!({"t": "live", "offset": 3, "handle": "log-1"}));
    }

    fn labels(&self) -> String {
        text(&self.engine, call(&self.engine, self.root, "labels", &[]))
    }
}

fn thread(run: i64, status: &str) -> Json {
    let id = format!("run-{run}");
    json!([
        ["run", id, {"id": id, "ordinal": run, "status": status,
                     "startedAt": "2026-09-23T09:59:50Z"}],
        ["turn-item", format!("ask-{run}"), {"id": format!("ask-{run}"), "type": "user_message",
            "runId": id, "ordinal": run * 10, "status": "completed", "text": "Add a tax line"}],
        ["turn-item", format!("reply-{run}"), {"id": format!("reply-{run}"), "type": "assistant_message",
            "runId": id, "ordinal": run * 10 + 1, "status": "completed", "text": "Done"}],
    ])
}

// A text helper that reads a returned value, not a property.
fn text(engine: &Engine, value: Value) -> String {
    engine.to_js_string(&value).to_string()
}

#[test]
fn a_view_shows_the_rows_and_follows_them() {
    let f = fixture();
    assert_eq!(common::text(&f.engine, f.root, "status"), "loading");
    f.open(thread(1, "running"), Json::Null);
    assert_eq!(common::text(&f.engine, f.root, "status"), "live");
    assert_eq!(number(&f.engine, f.root, "shown"), 2.0);
    assert_eq!(number(&f.engine, f.model, "count"), 2.0);
    assert_eq!(f.labels(), "message:Add a tax line|message:Done");
    assert_eq!(read(&f.engine, f.root, "working"), Value::Bool(true));
    assert_eq!(number(&f.engine, f.root, "inserted"), 2.0);
    assert_eq!(number(&f.engine, f.root, "aboutToInsert"), 2.0);

    // A delta redraws the row it touched.
    f.receive(json!({"t": "events", "offset": 4,
                     "events": [[4, "turn-item", "reply-1", {"a": {"text": " for now"}}, "x"]]}));
    assert_eq!(f.labels(), "message:Add a tax line|message:Done for now");

    f.receive(json!({"t": "events", "offset": 5,
                     "events": [[5, "run", "run-1", {"s": {"status": "completed",
                                                           "completedAt": "2026-09-23T10:00:00Z"}}, "x"]]}));
    assert_eq!(read(&f.engine, f.root, "working"), Value::Bool(false));
}

#[test]
fn the_invokables_answer_from_the_rows() {
    let f = fixture();
    f.open(thread(1, "completed"), Json::Null);
    let e = &f.engine;
    let index = call(e, f.model, "indexOf", &[Value::from("reply-1")]);
    assert_eq!(index.to_number(), 1.0);
    let missing = call(e, f.model, "indexOf", &[Value::from("nope")]);
    assert_eq!(missing.to_number(), -1.0);
    assert_eq!(
        text(
            e,
            call(e, f.model, "finishedRunOf", &[Value::from("reply-1")])
        ),
        "run-1"
    );
    let point = call(e, f.model, "rewindPointOf", &[Value::from("ask-1")]);
    assert_eq!(
        text(
            e,
            e.eval_js("(p) => p.turn")
                .ok()
                .and_then(|g| e.call_js(&g, &[point]))
                .unwrap()
        ),
        "1"
    );
    assert_eq!(text(e, call(e, f.model, "workingLabel", &[])), "");
    assert_eq!(
        call(e, f.model, "copy", &[Value::from("reply-1")]),
        Value::Bool(true)
    );
    assert_eq!(
        Platform::of(e)
            .clipboard()
            .text(ClipboardMode::Clipboard)
            .as_deref(),
        Some("Done")
    );
    assert_eq!(
        call(e, f.model, "copy", &[Value::from("nope")]),
        Value::Bool(false)
    );
}

#[test]
fn earlier_turns_are_asked_for_and_held_above() {
    let f = fixture();
    f.open(thread(2, "completed"), json!(2));
    assert_eq!(read(&f.engine, f.root, "hasEarlier"), Value::Bool(true));
    let seen = Rc::new(RefCell::new(Vec::new()));
    let log = seen.clone();
    TimelineModel::observe(&f.engine, f.model, move |_, out| {
        if let Out::EarlierWanted(n) = out {
            log.borrow_mut().push(*n);
        }
    });
    call(&f.engine, f.model, "loadEarlier", &[]);
    assert_eq!(*seen.borrow(), vec![200]);
    assert_eq!(number(&f.engine, f.root, "wanted"), 200.0);
    assert_eq!(
        read(&f.engine, f.model, "loadingEarlier"),
        Value::Bool(true)
    );
    let before = number(&f.engine, f.root, "inserted");
    f.receive(
        json!({"t": "page", "rows": thread(1, "completed"), "offset": 3,
                     "floor": null, "done": true}),
    );
    assert_eq!(number(&f.engine, f.root, "inserted") - before, 2.0);
    assert_eq!(
        f.labels(),
        "message:Add a tax line|message:Done|message:Add a tax line|message:Done"
    );
    assert_eq!(read(&f.engine, f.root, "hasEarlier"), Value::Bool(false));
}

#[test]
fn changes_reach_the_cache_after_the_flush_delay() {
    let f = fixture();
    f.open(thread(1, "running"), Json::Null);
    let after_snapshot = f.stores.0.get();
    f.receive(json!({"t": "events", "offset": 4,
                     "events": [[4, "turn-item", "reply-1", {"a": {"text": "!"}}, "x"]]}));
    assert_eq!(f.stores.0.get(), after_snapshot, "it waits for more");
    f.clock.set(f.clock.now() + Duration::from_millis(600));
    f.engine.advance_timers(f.clock.now());
    assert_eq!(f.stores.0.get(), after_snapshot + 1);
}
