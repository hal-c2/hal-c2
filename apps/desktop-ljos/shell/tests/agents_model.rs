//! `AgentsModel` as the Agents tab binds it: its rows through a view,
//! following a TimelineModel, and its two timers.

mod common;

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use chrono::{DateTime, Utc};
use common::{call, number};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::Disconnected;
use hal_c2_shell::thread_view::agents::{AgentsModel, TICK_MS};
use hal_c2_shell::thread_view::time::{Clock, Zone, parse_iso};
use hal_c2_shell::thread_view::timeline::Timeline;
use hal_c2_shell::thread_view::timeline_model::TimelineModel;
use ljos::prelude::{Engine, ObjectId, Value};
use ljos::testing::TestWindow;
use serde_json::json;

const MAIN: &str = r#"
import QtQuick
import HalC2.Shell
Item {
    id: root
    property var model: null
    readonly property int shown: rows.count
    readonly property int agents: root.model ? root.model.agentCount : -1
    function labels() {
        const out = [];
        for (let i = 0; i < rows.count; ++i)
            out.push(rows.itemAt(i).label);
        return out.join("|");
    }
    Column {
        Repeater {
            id: rows
            model: root.model
            delegate: Item {
                required property string title
                required property string section
                required property string statusLabel
                required property string elapsed
                required property string ended
                required property string childThreadKey
                readonly property string label: section + " " + title + " " + statusLabel
                    + " (" + elapsed + ")" + (ended ? " " + ended : "")
                    + (childThreadKey ? " -> " + childThreadKey : "")
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

fn at(text: &str) -> DateTime<Utc> {
    parse_iso(text, Zone::utc()).expect("a time")
}

struct Fixture {
    engine: Engine,
    root: ObjectId,
    timeline: ObjectId,
    agents: ObjectId,
    window: RefCell<TestWindow>,
    now: Rc<Cell<DateTime<Utc>>>,
    seq: Cell<i64>,
}

fn fixture() -> Fixture {
    let engine = common::engine(
        common::compile(&[("Main", MAIN)], &[]),
        Rc::new(Disconnected::default()),
    );
    // A window for its clock, before Main starts its timers on it.
    let window = RefCell::new(common::test_window(&engine, 100.0, 100.0));
    let root = engine
        .create_from_url("Main", None, Vec::new())
        .expect("Main is made");
    let now = Rc::new(Cell::new(at("2026-09-23T10:00:00Z")));
    let clock_now = now.clone();
    let clock = Clock {
        now: Rc::new(move || clock_now.get()),
        zone: Zone::utc(),
    };
    let mut core = Timeline::new("env-1:thread-1");
    core.set_clock(clock.clone());
    let timeline = TimelineModel::create(&engine, None, core).expect("the timeline is made");
    let agents = AgentsModel::create(&engine, None, clock).expect("the model is made");
    engine
        .write_by_name(root, "model", Value::Object(agents))
        .unwrap();
    let f = Fixture {
        engine,
        root,
        timeline,
        agents,
        window,
        now,
        seq: Cell::new(0),
    };
    TimelineModel::update(&f.engine, f.timeline, |t| {
        t.subscribing();
    });
    f.receive(json!({"t": "snapshot", "part": 0, "rows": [], "done": true,
                     "offset": 0, "handle": "log-1", "floor": null}));
    f.receive(json!({"t": "live", "offset": 0, "handle": "log-1"}));
    f
}

impl Fixture {
    fn receive(&self, frame: Json) {
        TimelineModel::update(&self.engine, self.timeline, |t| t.receive(&obj(frame)));
    }

    fn set(&self, kind: &str, id: &str, fields: Json) {
        let seq = self.seq.get() + 1;
        self.seq.set(seq);
        self.receive(json!({"t": "events", "offset": seq,
                            "events": [[seq, kind, id, {"s": fields}, "x"]]}));
    }

    fn start(&self, id: &str, title: &str, since: i64) {
        let started = self.now.get() - chrono::Duration::seconds(since);
        let started = started.to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        self.set(
            "subagent",
            id,
            json!({"id": id, "title": title, "status": "running", "childThreadId": format!("thread-{id}"),
                   "startedAt": started, "updatedAt": started}),
        );
    }

    fn labels(&self) -> String {
        let value = call(&self.engine, self.root, "labels", &[]);
        self.engine.to_js_string(&value).to_string()
    }

    fn ticking(&self) -> bool {
        AgentsModel::read_core(&self.engine, self.agents, |a| a.ticking()).unwrap()
    }

    /// `ms` pass, on the wall clock and the engine's timers.
    fn pass(&self, ms: u64) {
        self.now
            .set(self.now.get() + chrono::Duration::milliseconds(ms as i64));
        self.window.borrow_mut().advance(ms).unwrap();
    }
}

#[test]
fn the_tab_follows_its_threads_timeline() {
    let f = fixture();
    f.start("tax", "Tax tests", 12);
    // Nothing until it is given the thread.
    assert_eq!(number(&f.engine, f.root, "shown"), 0.0);
    AgentsModel::set_thread(&f.engine, f.agents, "env-1", Some(f.timeline));
    assert_eq!(
        f.labels(),
        "active Tax tests Working (12s) -> env-1:thread-tax"
    );
    assert_eq!(number(&f.engine, f.agents, "count"), 1.0);
    assert_eq!(number(&f.engine, f.root, "agents"), 1.0);

    f.start("docs", "Docs", 5);
    f.set(
        "subagent",
        "tax",
        json!({"status": "completed", "completedAt": "2026-09-23T10:00:00.000Z"}),
    );
    assert_eq!(
        f.labels(),
        "active Docs Working (5s) -> env-1:thread-docs|finished Tax tests Completed (12s) Completed at 10:00 AM -> env-1:thread-tax"
    );
    let index = call(&f.engine, f.agents, "indexOf", &[Value::from("tax")]);
    assert_eq!(index.to_number(), 1.0);

    // The Settings time format reaches the end times.
    TimelineModel::update(&f.engine, f.timeline, |t| t.set_timestamp_format("24-hour"));
    assert!(
        f.labels()
            .ends_with("Completed at 10:00 -> env-1:thread-tax"),
        "{}",
        f.labels()
    );

    // Another thread: the old timeline is no longer followed.
    AgentsModel::set_thread(&f.engine, f.agents, "env-2", None);
    assert_eq!(f.labels(), "");
    f.start("lint", "Lint", 1);
    assert_eq!(number(&f.engine, f.agents, "count"), 0.0);
}

#[test]
fn elapsed_times_move_once_a_second_only_while_the_tab_shows() {
    let f = fixture();
    f.start("tax", "Tax tests", 12);
    AgentsModel::set_thread(&f.engine, f.agents, "env-1", Some(f.timeline));
    assert!(!f.ticking());
    f.pass(3000);
    assert!(
        f.labels().contains("(12s)"),
        "hidden, it stands still: {}",
        f.labels()
    );

    AgentsModel::set_active(&f.engine, f.agents, true);
    assert!(f.ticking());
    assert!(
        f.labels().contains("(15s)"),
        "shown, it catches up: {}",
        f.labels()
    );
    f.pass(TICK_MS as u64);
    assert!(f.labels().contains("(16s)"), "{}", f.labels());

    AgentsModel::set_active(&f.engine, f.agents, false);
    assert!(!f.ticking());
    f.pass(TICK_MS as u64);
    assert!(f.labels().contains("(16s)"), "{}", f.labels());

    // Settled, nothing moves even while shown.
    AgentsModel::set_active(&f.engine, f.agents, true);
    f.set(
        "subagent",
        "tax",
        json!({"status": "completed", "completedAt": "2026-09-23T10:00:16.000Z"}),
    );
    assert!(!f.ticking());
}

#[test]
fn the_end_times_are_redrawn_at_midnight() {
    let f = fixture();
    f.now.set(at("2026-09-23T23:59:00Z"));
    f.start("tax", "Tax tests", 30);
    f.set(
        "subagent",
        "tax",
        json!({"status": "completed", "completedAt": "2026-09-23T23:58:50.000Z"}),
    );
    AgentsModel::set_thread(&f.engine, f.agents, "env-1", Some(f.timeline));
    AgentsModel::set_active(&f.engine, f.agents, true);
    assert!(
        f.labels().contains("Completed at 11:58 PM"),
        "{}",
        f.labels()
    );
    let midnight = at("2026-09-24T00:00:00Z");
    assert_eq!(
        AgentsModel::read_core(&f.engine, f.agents, |a| a.next_day()).unwrap(),
        Some(midnight)
    );
    // The model's own midnight timer.
    f.pass(60_000);
    assert!(
        f.labels().contains("Completed yesterday at 11:58 PM"),
        "{}",
        f.labels()
    );
    assert_eq!(
        AgentsModel::read_core(&f.engine, f.agents, |a| a.next_day()).unwrap(),
        Some(at("2026-09-25T00:00:00Z"))
    );
}

#[test]
fn a_subagent_settling_moves_its_row_in_place() {
    let f = fixture();
    f.start("tax", "Tax tests", 20);
    f.start("docs", "Docs", 10);
    AgentsModel::set_thread(&f.engine, f.agents, "env-1", Some(f.timeline));
    let before = f.engine.object_model(f.agents).unwrap().row_key(0);
    f.set(
        "subagent",
        "tax",
        json!({"status": "failed", "completedAt": "2026-09-23T10:00:00.000Z"}),
    );
    assert_eq!(
        f.labels(),
        "active Docs Working (10s) -> env-1:thread-docs|finished Tax tests Failed (20s) Failed at 10:00 AM -> env-1:thread-tax"
    );
    // The same row, moved: not removed and made again.
    assert_eq!(f.engine.object_model(f.agents).unwrap().row_key(1), before);
}
