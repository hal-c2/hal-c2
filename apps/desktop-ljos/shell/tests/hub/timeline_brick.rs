//! The real Timeline brick over a thread's timeline, headless: a view kept
//! at the end of a running turn stays there, still, while the turn's rows
//! and its "Working for" line change (features/timeline/timeline.feature).

use std::cell::Cell;
use std::rc::Rc;

use chrono::{DateTime, Duration, Utc};
use hal_c2_shell::controllers::threads::ThreadStore;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::SubId;
use hal_c2_shell::qml::Roots;
use hal_c2_shell::thread_view::time::{Clock, Zone};
use ljos::item::{ScrollPhase, WheelEvent};
use ljos::keys::{KeyEvent, key};
use ljos::prelude::{ObjectId, Value};
use serde_json::json;

use crate::{Hub, Window};

const PROBE: &str = r#"
import QtQuick
import HalC2.Shell
import HalC2.Bricks

Item {
    id: root
    width: 900
    height: 700
    property alias timeline: timeline
    readonly property var rows: find(timeline, "timelineRows")
    readonly property var jump: find(timeline, "jumpToLatest")
    readonly property string working: label(find(timeline, "workingLabel"))
    // The rows in view, top to bottom: "rowId@y" with y from the view's top.
    function shown() {
        const out = [];
        const kids = rows.contentItem.children;
        for (let i = 0; i < kids.length; i++) {
            const k = kids[i];
            if (k.rowId === undefined || !k.visible)
                continue;
            const y = k.y - rows.contentY;
            if (y + k.height > 0 && y < rows.height)
                out.push([y, k.rowId + "@" + Math.round(y) + "+" + Math.round(k.height)]);
        }
        out.sort((a, b) => a[0] - b[0]);
        return out.map(p => p[1]).join(" ");
    }
    // Where a click in the conversation puts the keyboard.
    function focusRows() { rows.forceActiveFocus() }
    function label(item) { return item ? item.text : "" }
    function find(item, name) {
        if (item.objectName === name)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const found = find(item.children[i], name);
            if (found)
                return found;
        }
        return null;
    }

    Timeline {
        id: timeline
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: composerStandIn.top
        model: Threads.timeline
    }
    Rectangle {
        id: composerStandIn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // The composer below the timeline, as the window lays them out: it
        // folds to its resting height while the rows are scrolled away
        // (Settings, "Collapse composer on scroll", on by default).
        height: timeline.scrolledAway ? 88 : 125
    }
}
"#;

const STARTED: &str = "2026-10-24T10:00:00Z";

/// The checkout's bricks and the probe, compiled as the app compiles them.
fn probe(hub: &Hub) -> (ObjectId, Window) {
    let dir = tempfile::tempdir().expect("a directory for the probe");
    std::fs::write(dir.path().join("TimelineProbe.qml"), PROBE).expect("the probe");
    let mut dirs = Roots::checkout().dirs().expect("the roots are there");
    dirs.push(dir.path().to_path_buf());
    let snapshot = ljos::engine();
    hal_c2_shell::register(&snapshot);
    let paths: Vec<&std::path::Path> = dirs.iter().map(|p| p.as_path()).collect();
    let compiled = ljos::dev::compile_quiet(&paths, Some(&snapshot)).expect("the bricks compile");
    hub.show(compiled.source, "TimelineProbe")
}

/// The thread's stream subscription.
fn stream(hub: &Hub) -> SubId {
    hub.mc
        .subscriptions()
        .into_iter()
        .find(|(_, shape)| shape["type"] == "stream" && shape["stream"] == "t1")
        .map(|(id, _)| id)
        .expect("the thread is followed")
}

/// A long reply, a few lines at the brick's width.
fn prose(n: usize) -> String {
    format!(
        "Reply {n}. The theme port is merged, and the worker got every QML file \
         compiling on its own branch. The full check is running now on the combined \
         tree, with the timeline, composer, small fixes and theme branches all merged \
         in. I'll push if it passes."
    )
}

/// Thread `t1` of six settled turns and a seventh running: a prompt, a
/// reply of one to four paragraphs (rows of different heights, which a
/// view estimates until it lays them out), and a command still running.
/// Its clock reads `now`.
fn running_turn(now: Rc<Cell<DateTime<Utc>>>) -> (Hub, i64) {
    turns(now, 7, None)
}

/// Thread `t1` of `count` turns, as [`running_turn`], the last running;
/// the MC sends those from `floor` on, and the ones before when asked.
fn turns(now: Rc<Cell<DateTime<Utc>>>, count: usize, floor: Option<usize>) -> (Hub, i64) {
    let hub = Hub::clustered();
    hub.mc.set_ready(&hub.engine, true);
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
        "environment": {"environmentId": "env-1", "label": "Here"}}],
        "rows": [
            ["a", "p1", "project", {"id": "p1", "title": "P", "workspaceRoot": "/work/p"}],
            ["a", "t1", "thread", {"id": "t1", "projectId": "p1", "title": "T1"}],
        ]}),
    );
    hub.with_controller::<ThreadStore, _>(|s, e| {
        s.set_clock(
            e,
            Clock {
                now: Rc::new(move || now.get()),
                zone: Zone::Fixed(chrono::FixedOffset::east_opt(0).unwrap()),
            },
        )
    });
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    let id = stream(&hub);
    let rows: Vec<Json> = (floor.unwrap_or(1)..=count)
        .flat_map(|turn| turn_rows(turn, turn == count))
        .collect();
    let offset = rows.len() as i64;
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "snapshot", "part": 0, "rows": rows, "done": true, "offset": offset,
            "handle": "log-1", "floor": floor}),
    );
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "live", "offset": offset, "handle": "log-1"}),
    );
    (hub, offset)
}

/// Turn `turn`'s run and rows: a prompt, a command and a reply.
fn turn_rows(turn: usize, running: bool) -> Vec<Json> {
    let run = format!("run-{turn}");
    let status = if running { "running" } else { "completed" };
    vec![
        json!(["run", run, {"id": run, "ordinal": turn, "status": status,
            "startedAt": STARTED}]),
        json!(["turn-item", format!("ask-{turn}"), {"id": format!("ask-{turn}"),
            "type": "user_message", "runId": run, "ordinal": turn * 10, "status": "completed",
            "text": format!("Prompt {turn}"), "createdAt": STARTED}]),
        json!(["turn-item", format!("cmd-{turn}"), {"id": format!("cmd-{turn}"),
            "type": "command_execution", "runId": run, "ordinal": turn * 10 + 1,
            "status": status, "command": "cargo test -p hal_c2_shell", "createdAt": STARTED}]),
        json!(["turn-item", format!("reply-{turn}"), {"id": format!("reply-{turn}"),
            "type": "assistant_message", "runId": run, "ordinal": turn * 10 + 2,
            "status": "completed", "text": prose(turn).repeat(1 + turn % 4),
            "createdAt": STARTED}]),
    ]
}

/// Where the view stands on a frame.
#[derive(Clone, Debug, PartialEq)]
struct Frame {
    content_y: f64,
    content_height: f64,
    origin_y: f64,
    at_end: bool,
    following: bool,
    jump: bool,
    working: String,
    shown: String,
}

fn num(hub: &Hub, obj: ObjectId, name: &str) -> f64 {
    hub.engine.read_by_name(obj, name).to_number()
}

fn object(hub: &Hub, obj: ObjectId, name: &str) -> ObjectId {
    match hub.engine.read_by_name(obj, name) {
        Value::Object(o) => o,
        other => panic!("{name}: {other:?}"),
    }
}

fn frame(hub: &Hub, root: ObjectId) -> Frame {
    let rows = object(hub, root, "rows");
    let jump = object(hub, root, "jump");
    Frame {
        content_y: num(hub, rows, "contentY"),
        content_height: num(hub, rows, "contentHeight"),
        origin_y: num(hub, rows, "originY"),
        at_end: hub.engine.read_by_name(rows, "atYEnd") == Value::Bool(true),
        following: hub.engine.read_by_name(rows, "following") == Value::Bool(true),
        jump: hub.engine.read_by_name(jump, "visible") == Value::Bool(true),
        working: hub
            .engine
            .to_js_string(&hub.engine.read_by_name(root, "working"))
            .to_string(),
        shown: {
            let v = hub.engine.invoke_by_name(root, "shown", &[]).unwrap();
            hub.engine.to_js_string(&v).to_string()
        },
    }
}

/// Moves the clock on `ms` a 60 Hz frame at a time, recording each.
fn frames(hub: &Hub, root: ObjectId, ms: u64, out: &mut Vec<Frame>) {
    for _ in 0..ms.div_ceil(16) {
        hub.advance(16);
        out.push(frame(hub, root));
    }
}

/// The MC's `events` frame setting each entity's fields in `patch`, and
/// bringing the log to `offset`.
fn events(hub: &Hub, offset: &mut i64, events: Vec<(&str, String, Json)>) {
    let mut list = Vec::new();
    for (kind, id, patch) in events {
        *offset += 1;
        list.push(json!([*offset, kind, id, {"s": patch}]));
    }
    hub.mc.frame_to(
        &hub.engine,
        stream(hub),
        json!({"t": "events", "events": list, "offset": *offset}),
    );
}

/// A view at the end of a running turn stays put, the "Scroll to end"
/// button hidden, while the working line ticks each second and the turn's
/// running command and notices change.
#[test]
fn a_followed_end_stays_still_while_the_turn_runs() {
    let start: DateTime<Utc> = STARTED.parse().unwrap();
    let now = Rc::new(Cell::new(start + Duration::seconds(257)));
    let (hub, mut offset) = running_turn(now.clone());
    let (root, _window) = probe(&hub);
    let mut settle = Vec::new();
    frames(&hub, root, 2000, &mut settle);
    let rest = frame(&hub, root);
    assert!(rest.following && !rest.jump, "{rest:?}");
    assert!(rest.working.starts_with("Working for"), "{rest:?}");

    let mut seen = Vec::new();
    for tick in 0..12 {
        now.set(now.get() + Duration::seconds(1));
        match tick % 4 {
            // The running command's output grows.
            1 => events(
                &hub,
                &mut offset,
                vec![(
                    "turn-item",
                    "cmd-7".into(),
                    json!({"aggregatedOutput": "ok\n".repeat(tick + 1)}),
                )],
            ),
            // The agent was woken by background work: a notice row.
            3 => events(
                &hub,
                &mut offset,
                vec![(
                    "turn-item",
                    format!("wake-{tick}"),
                    json!({"id": format!("wake-{tick}"), "type": "user_message",
                        "runId": "run-7", "ordinal": 100 + tick, "status": "completed",
                        "createdBy": "agent", "creationSource": "provider",
                        "text": "<task-notification>done</task-notification>",
                        "createdAt": STARTED}),
                )],
            ),
            _ => {}
        }
        frames(&hub, root, 1000, &mut seen);
    }
    let moved: Vec<(usize, &Frame)> = seen
        .iter()
        .enumerate()
        .filter(|(_, f)| !f.following || f.jump || !f.at_end)
        .collect();
    assert!(
        moved.is_empty(),
        "{} of {} frames left the end; first {:?}",
        moved.len(),
        seen.len(),
        moved.first()
    );
    // Between changes the end does not move: contentY moves only with the
    // extents of the rows (a row added at the end moves originY as the
    // rows above it are estimated again, not contentHeight).
    let jumps: Vec<(usize, f64, f64)> = seen
        .windows(2)
        .enumerate()
        .filter(|(_, w)| {
            w[0].content_height == w[1].content_height
                && w[0].origin_y == w[1].origin_y
                && w[0].content_y != w[1].content_y
        })
        .map(|(i, w)| (i, w[0].content_y, w[1].content_y))
        .collect();
    assert!(jumps.is_empty(), "contentY moved alone: {jumps:?}");
}

/// One touchpad event over the rows: `dy` logical pixels, positive toward
/// the top, then a frame.
fn swipe(hub: &Hub, window: &Window, dy: f64, phase: ScrollPhase) {
    let ev = WheelEvent::pixels(450.0, 350.0, 0.0, dy, window.now()).with_phase(phase);
    window.wheel(&ev);
    hub.advance(8);
}

/// The MC's changes to a running turn, one kind a second as in
/// [`a_followed_end_stays_still_while_the_turn_runs`].
fn change(hub: &Hub, offset: &mut i64, tick: usize) {
    match tick % 4 {
        1 => events(
            hub,
            offset,
            vec![(
                "turn-item",
                "cmd-7".into(),
                json!({"aggregatedOutput": "ok\n".repeat(tick + 1)}),
            )],
        ),
        3 => events(
            hub,
            offset,
            vec![(
                "turn-item",
                format!("wake-{tick}"),
                json!({"id": format!("wake-{tick}"), "type": "user_message",
                    "runId": "run-7", "ordinal": 100 + tick, "status": "completed",
                    "createdBy": "agent", "creationSource": "provider",
                    "text": "<task-notification>done</task-notification>",
                    "createdAt": STARTED}),
            )],
        ),
        _ => {}
    }
}

/// Scrolled back from the end by a touchpad, the rows move only with the
/// fingers: a slow swipe toward the top never steps back toward the end
/// while the turn's rows and working line change, and a view left alone
/// stays where it was put.
#[test]
fn a_view_scrolled_back_moves_only_with_the_fingers() {
    let start: DateTime<Utc> = STARTED.parse().unwrap();
    let now = Rc::new(Cell::new(start + Duration::seconds(257)));
    let (hub, mut offset) = running_turn(now.clone());
    let (root, window) = probe(&hub);
    let mut settle = Vec::new();
    frames(&hub, root, 2000, &mut settle);

    // Away from the end, as a reader does.
    swipe(&hub, &window, 0.0, ScrollPhase::Begin);
    for _ in 0..40 {
        swipe(&hub, &window, 6.0, ScrollPhase::Update);
    }
    swipe(&hub, &window, 0.0, ScrollPhase::End);
    frames(&hub, root, 500, &mut settle);
    let away = frame(&hub, root);
    assert!(!away.following && away.jump && !away.at_end, "{away:?}");

    let mut seen = vec![away.clone()];
    let mut tick = 0;
    let mut clock = 0;
    for _ in 0..4 {
        // Left alone for a while.
        for _ in 0..60 {
            hub.advance(16);
            clock += 16;
            if clock >= 1000 {
                clock -= 1000;
                now.set(now.get() + Duration::seconds(1));
                change(&hub, &mut offset, tick);
                tick += 1;
            }
            seen.push(frame(&hub, root));
        }
        // A slow swipe toward the top, then its momentum.
        swipe(&hub, &window, 0.0, ScrollPhase::Begin);
        for step in 0..30 {
            let phase = if step < 20 {
                ScrollPhase::Update
            } else {
                ScrollPhase::Momentum
            };
            swipe(&hub, &window, if step < 20 { 3.0 } else { 1.0 }, phase);
            clock += 8;
            if clock >= 1000 {
                clock -= 1000;
                now.set(now.get() + Duration::seconds(1));
                change(&hub, &mut offset, tick);
                tick += 1;
            }
            seen.push(frame(&hub, root));
        }
        swipe(&hub, &window, 0.0, ScrollPhase::End);
    }
    let back: Vec<(usize, f64, f64)> = seen
        .windows(2)
        .enumerate()
        .filter(|(_, w)| w[1].content_y > w[0].content_y)
        .map(|(i, w)| (i, w[0].content_y, w[1].content_y))
        .collect();
    assert!(
        back.is_empty(),
        "the rows stepped back toward the end: {back:?}"
    );
}

/// Where each row in view is, by id, from the view's top.
fn places(shown: &str) -> std::collections::HashMap<String, f64> {
    shown
        .split_whitespace()
        .filter_map(|r| {
            let (id, rest) = r.split_once('@')?;
            let y = rest.split('+').next()?.parse().ok()?;
            Some((id.to_owned(), y))
        })
        .collect()
}

/// The turns before the ones loaded, arriving while the reader is at the
/// top of a long thread (Home), go in above it and leave what is on screen
/// where it is, frame after frame, while the rows above settle their
/// heights (features/timeline/timeline.feature).
#[test]
fn earlier_turns_leave_the_rows_in_view_in_place() {
    let start: DateTime<Utc> = STARTED.parse().unwrap();
    let now = Rc::new(Cell::new(start + Duration::seconds(257)));
    let (hub, offset) = turns(now, 40, Some(21));
    let (root, window) = probe(&hub);
    frames(&hub, root, 2000, &mut Vec::new());
    hub.engine.invoke_by_name(root, "focusRows", &[]).unwrap();
    assert!(
        window.key(&KeyEvent::press(key::HOME)),
        "the rows took Home"
    );
    frames(&hub, root, 500, &mut Vec::new());
    let before = frame(&hub, root);
    assert!(
        !before.following && before.shown.contains("ask-21@"),
        "{before:?}"
    );

    let rows: Vec<Json> = (1..=20).flat_map(|turn| turn_rows(turn, false)).collect();
    hub.mc.frame_to(
        &hub.engine,
        stream(&hub),
        json!({"t": "page", "rows": rows, "offset": offset, "floor": null, "done": true}),
    );
    let mut seen = Vec::new();
    frames(&hub, root, 1000, &mut seen);
    let was = places(&before.shown);
    let moved: Vec<(usize, &String, f64, f64)> = seen
        .iter()
        .enumerate()
        .flat_map(|(i, f)| {
            let is = places(&f.shown);
            was.iter()
                .filter_map(move |(id, y)| Some((i, id, *y, *is.get(id)?)))
                .collect::<Vec<_>>()
        })
        .filter(|(_, _, was, is)| (was - is).abs() > 0.5)
        .collect();
    assert!(
        moved.is_empty(),
        "{before:?}\nthen {:?}\nmoved (frame, row, was, is): {:?}",
        seen.last(),
        &moved[..moved.len().min(8)]
    );
}

/// One long touchpad swipe from the end of a thread toward its top moves
/// the rows only toward the top: no step moves them back toward the end as
/// the rows coming into view take their heights.
#[test]
#[ignore = "TODO(ljos#109): an attached ScrollBar writes a stale position back into its \
            ListView when a layout pass in the bar's own update changes originY or \
            contentHeight"]
fn a_long_swipe_moves_the_rows_only_toward_the_top() {
    let start: DateTime<Utc> = STARTED.parse().unwrap();
    let now = Rc::new(Cell::new(start + Duration::seconds(257)));
    let (hub, _offset) = turns(now, 20, None);
    let (root, window) = probe(&hub);
    frames(&hub, root, 2000, &mut Vec::new());
    let rows = object(&hub, root, "rows");
    let mut ys = vec![num(&hub, rows, "contentY")];
    swipe(&hub, &window, 0.0, ScrollPhase::Begin);
    for _ in 0..1200 {
        swipe(&hub, &window, 6.0, ScrollPhase::Update);
        ys.push(num(&hub, rows, "contentY"));
    }
    swipe(&hub, &window, 0.0, ScrollPhase::End);
    let top = num(&hub, rows, "originY") - 12.0;
    assert!(
        (ys[ys.len() - 1] - top).abs() < 0.5,
        "the swipe reached the top: {:?}",
        &ys[ys.len() - 5..]
    );
    let back: Vec<(usize, f64, f64)> = ys
        .windows(2)
        .enumerate()
        .filter(|(_, w)| w[1] > w[0])
        .map(|(i, w)| (i, w[0], w[1]))
        .collect();
    assert!(
        back.is_empty(),
        "steps toward the end (step, before, after): {back:?}"
    );
}
