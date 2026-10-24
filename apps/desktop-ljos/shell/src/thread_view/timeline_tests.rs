//! The timeline's behaviour (features/timeline, desktop-qt's TimelineSteps
//! and tst_TimelineRepaintRegression), against the core on a fixed clock.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use chrono::{DateTime, Duration, Utc};
use serde_json::json;

use super::cache::{self, ThreadCache};
use super::summary::Obj;
use super::time::{Clock, Zone, parse_iso};
use super::timeline::*;
use crate::json::Json;

pub(super) fn at(text: &str) -> DateTime<Utc> {
    parse_iso(text, Zone::utc()).expect("a time")
}

pub(super) fn iso(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

pub(super) fn obj(value: Json) -> Obj {
    match value {
        Json::Object(o) => o,
        _ => panic!("not an object"),
    }
}

/// A view of the rows, kept only by what the timeline signals: the ids a
/// delegate list would hold, and every row whose roles it was told to read
/// again.
#[derive(Debug, Default)]
pub(super) struct Mirror {
    pub ids: Vec<String>,
    /// (row id, roles; none: all)
    pub redrawn: Vec<(String, Vec<Role>)>,
}

impl Mirror {
    pub fn apply(&mut self, out: &[Out]) {
        for o in out {
            match o {
                Out::Removed { first, count } => {
                    assert!(
                        first + count <= self.ids.len(),
                        "removed past the end: {o:?}"
                    );
                    self.ids.drain(*first..first + count);
                }
                Out::Inserted { first, ids } => {
                    assert!(*first <= self.ids.len(), "inserted past the end: {o:?}");
                    self.ids.splice(*first..*first, ids.iter().cloned());
                }
                Out::Moved { from, to } => {
                    assert!(to < from && *from < self.ids.len(), "a bad move: {o:?}");
                    let id = self.ids.remove(*from);
                    self.ids.insert(*to, id);
                }
                Out::DataChanged { first, last, roles } => {
                    assert!(
                        first <= last && *last < self.ids.len(),
                        "redrew past the end: {o:?}"
                    );
                    for id in &self.ids[*first..=*last] {
                        self.redrawn.push((id.clone(), roles.clone()));
                    }
                }
                _ => {}
            }
        }
    }
}

/// What a cache does with a timeline's calls (desktop-qt's LocalCache),
/// in memory.
#[derive(Debug, Default)]
pub(super) struct MemoryCache {
    pub threads: RefCell<std::collections::BTreeMap<String, cache::Thread>>,
    pub stores: Cell<usize>,
}

impl ThreadCache for MemoryCache {
    fn store_thread(&self, update: cache::ThreadUpdate) {
        self.stores.set(self.stores.get() + 1);
        let mut threads = self.threads.borrow_mut();
        if update.replace {
            threads.insert(
                update.key.clone(),
                cache::Thread {
                    cursor: update.cursor.clone(),
                    entities: Vec::new(),
                },
            );
        } else {
            let Some(thread) = threads.get_mut(&update.key) else {
                return;
            };
            thread.cursor = update.cursor.clone();
        }
        let thread = threads.get_mut(&update.key).expect("stored");
        thread
            .entities
            .retain(|e| !update.gone.iter().any(|(k, i)| *k == e.kind && *i == e.id));
        for entity in update.put {
            thread
                .entities
                .retain(|e| !(e.kind == entity.kind && e.id == entity.id));
            thread.entities.push(entity);
        }
    }

    fn trim_thread(&self, key: &str, floor: i64) {
        let mut threads = self.threads.borrow_mut();
        let Some(thread) = threads.get_mut(key) else {
            return;
        };
        if thread.cursor.floor.is_some_and(|held| held >= floor) {
            return;
        }
        thread.cursor.floor = Some(floor);
        thread
            .entities
            .retain(|e| e.run.is_none_or(|run| run >= floor));
    }
}

impl MemoryCache {
    pub fn load(&self, key: &str) -> cache::Thread {
        self.threads.borrow().get(key).cloned().unwrap_or_default()
    }
}

/// A thread on a fake MC, and the timeline following it.
struct World {
    tl: Timeline,
    now: Rc<Cell<DateTime<Utc>>>,
    seq: i64,
    ordinal: i64,
    runs: i64,
    run: String,
    run_started: Option<DateTime<Utc>>,
    view: Mirror,
}

impl World {
    fn new() -> World {
        let now = Rc::new(Cell::new(at("2026-09-23T10:00:00Z")));
        let mut tl = Timeline::new("env:thread");
        let clock_now = now.clone();
        tl.set_clock(Clock {
            now: Rc::new(move || clock_now.get()),
            zone: Zone::utc(),
        });
        World {
            tl,
            now,
            seq: 0,
            ordinal: 0,
            runs: 0,
            run: String::new(),
            run_started: None,
            view: Mirror::default(),
        }
    }

    /// The thread as an empty snapshot, then live.
    fn open(&mut self) -> &mut Self {
        self.snapshot(Vec::new());
        self
    }

    fn snapshot(&mut self, rows: Vec<Json>) {
        self.tl.subscribing();
        self.tl.receive(&obj(json!({
            "t": "snapshot", "part": 0, "rows": rows, "done": true,
            "offset": self.seq, "handle": "log-1", "floor": null,
        })));
        self.tl.receive(&obj(
            json!({"t": "live", "offset": self.seq, "handle": "log-1"}),
        ));
        self.drain();
    }

    fn drain(&mut self) -> Vec<Out> {
        let out = self.tl.take_out();
        self.view.apply(&out);
        let ids: Vec<String> = (0..self.tl.row_count())
            .map(|r| self.tl.row_id(r).unwrap().to_owned())
            .collect();
        assert_eq!(self.view.ids, ids, "the view follows the rows");
        out
    }

    fn change(&mut self, kind: &str, id: &str, patch: Json) -> Vec<Out> {
        self.seq += 1;
        let frame = json!({
            "t": "events", "offset": self.seq,
            "events": [[self.seq, kind, id, patch, iso(self.now.get())]],
        });
        self.tl.receive(&obj(frame));
        self.drain()
    }

    fn set(&mut self, kind: &str, id: &str, fields: Json) -> Vec<Out> {
        self.change(kind, id, json!({"s": fields}))
    }

    /// A run started `ago` seconds ago (none: not yet), and the user's
    /// message that asked for it.
    fn start_run(&mut self, ago: Option<i64>, status: &str) -> String {
        self.runs += 1;
        self.ordinal += 1;
        self.run = format!("run-{}", self.runs);
        let started = ago.map(|s| self.now.get() - Duration::seconds(s));
        self.run_started = started;
        let mut run = json!({"id": self.run, "ordinal": self.runs, "status": status});
        if let Some(started) = started {
            run["startedAt"] = json!(iso(started));
        }
        let run_id = self.run.clone();
        self.set("run", &run_id, run);
        let message = format!("message:{run_id}");
        let sent = iso(started.unwrap_or(self.now.get()));
        self.set(
            "turn-item",
            &message.clone(),
            json!({"id": message, "type": "user_message", "runId": run_id, "ordinal": self.ordinal,
                   "status": "completed", "text": "Add a tax line", "startedAt": sent, "updatedAt": sent}),
        );
        run_id
    }

    fn add_item(&mut self, kind: &str, fields: Json) -> String {
        self.ordinal += 1;
        let id = fields["id"]
            .as_str()
            .map_or_else(|| format!("{kind}-{}", self.ordinal), str::to_owned);
        let now = iso(self.now.get());
        let mut item = json!({"id": id, "type": kind, "runId": self.run, "ordinal": self.ordinal,
                              "status": "completed", "startedAt": now, "updatedAt": now});
        for (k, v) in obj(fields) {
            item[k] = v;
        }
        self.set("turn-item", &id.clone(), item);
        id
    }

    fn add_command(&mut self, n: i64, status: &str) -> String {
        self.add_item(
            "command_execution",
            json!({"id": format!("cmd-{n}"), "input": format!("bun test {n}"), "status": status}),
        )
    }

    fn settle(&mut self, status: &str, after: i64) {
        let mut fields = json!({"status": status});
        let start = self.run_started.unwrap_or(self.now.get());
        if self.run_started.is_some() {
            fields["completedAt"] = json!(iso(start + Duration::seconds(after)));
        }
        let run = self.run.clone();
        self.set("run", &run, fields);
    }

    fn row(&self, id: &str) -> usize {
        self.tl
            .index_of(id)
            .unwrap_or_else(|| panic!("no row {id}; {:?}", self.view.ids))
    }

    fn rows_of(&self, kind: &str) -> Vec<usize> {
        (0..self.tl.row_count())
            .filter(|&r| self.role(r, Role::Kind) == kind)
            .collect()
    }

    fn last_of(&self, kind: &str) -> usize {
        *self
            .rows_of(kind)
            .last()
            .unwrap_or_else(|| panic!("no {kind} row; {:?}", self.view.ids))
    }

    fn role(&self, row: usize, role: Role) -> Json {
        self.tl.data(row, role).unwrap_or(Json::Null)
    }

    fn last_entry(&self) -> Obj {
        let entries = self.role(self.last_of("work"), Role::Entries);
        obj(entries
            .as_array()
            .and_then(|e| e.last())
            .cloned()
            .expect("an entry"))
    }
}

#[test]
fn a_thread_opens_loading_then_live() {
    let mut w = World::new();
    assert_eq!(w.tl.status(), "loading");
    let sub = w.tl.subscribing();
    assert_eq!(
        sub,
        json!({"offset": null, "window": {"items": WINDOW_ITEMS}})
    );
    w.open();
    assert_eq!(w.tl.status(), "live");
    assert_eq!(w.tl.cursor().handle, "log-1");
    assert_eq!(
        w.tl.subscribing(),
        json!({"offset": 0, "window": {"floor": null}, "handle": "log-1"})
    );
}

// streaming.feature: "Reasoning is shown while it streams".
#[test]
fn streaming_reasoning_redraws_only_its_entries() {
    let mut w = World::new();
    w.open();
    w.start_run(Some(1), "running");
    let id = w.add_item(
        "reasoning",
        json!({"streaming": true, "status": "running", "text": "The cart total needs"}),
    );
    assert_eq!(w.last_entry()["label"], "Thinking");
    let out = w.change("turn-item", &id, json!({"a": {"text": " a tax line"}}));
    let changes: Vec<&Out> = out
        .iter()
        .filter(|o| {
            matches!(
                o,
                Out::DataChanged { .. }
                    | Out::Inserted { .. }
                    | Out::Removed { .. }
                    | Out::Moved { .. }
            )
        })
        .collect();
    assert_eq!(
        changes,
        vec![&Out::DataChanged {
            first: w.last_of("work"),
            last: w.last_of("work"),
            roles: vec![Role::Entries],
        }]
    );
    w.set(
        "turn-item",
        &id,
        json!({"streaming": false, "status": "completed"}),
    );
    assert_eq!(w.last_entry()["label"], "The cart total needs a tax line");
}

#[test]
fn markdown_reasoning_is_labelled_by_its_words() {
    let mut w = World::new();
    w.open();
    w.start_run(Some(1), "running");
    w.add_item(
        "reasoning",
        json!({"text": "**Checking** the [cart](https://shop.example/cart) `total`\n\n![a chart](chart.png)"}),
    );
    assert_eq!(w.last_entry()["label"], "Checking the cart total a chart");
}

#[test]
fn a_working_thread_counts_its_time() {
    let mut w = World::new();
    w.open();
    assert!(!w.tl.working());
    w.start_run(Some(12), "running");
    assert!(w.tl.working());
    assert_eq!(w.tl.working_label(), "Working for 12s");
    w.now.set(w.now.get() + Duration::seconds(5));
    assert_eq!(w.tl.working_label(), "Working for 17s");
    w.settle("completed", 17);
    assert!(!w.tl.working());
    assert_eq!(w.tl.working_label(), "");
}

// streaming.feature: "A finished turn folds its tool calls" and "A folded
// turn can be opened and closed again".
#[test]
fn a_settled_turn_folds_behind_how_long_it_took() {
    let mut w = World::new();
    w.open();
    w.start_run(Some(0), "running");
    for n in 1..=4 {
        w.add_command(n, "completed");
    }
    let answer = w.add_item(
        "assistant_message",
        json!({"text": "The cart now shows tax."}),
    );
    assert!(!w.role(w.row(&answer), Role::Meta).as_bool().unwrap());
    w.settle("completed", 120);
    let fold = w.last_of("fold");
    assert_eq!(w.role(fold, Role::Title), "Worked for 2m");
    assert_eq!(w.role(fold, Role::Expanded), false);
    assert_eq!(w.role(fold, Role::HiddenCount), 4);
    assert!(w.rows_of("work").is_empty());
    assert_eq!(
        w.role(w.row(&answer), Role::Text),
        "The cart now shows tax."
    );
    assert_eq!(w.role(w.row(&answer), Role::Meta), true);

    let fold_id = w.tl.row_id(fold).unwrap().to_owned();
    w.tl.toggle(&fold_id);
    w.drain();
    let work = w.last_of("work");
    let calls = w.role(work, Role::Entries).as_array().unwrap().len() as u64
        + w.role(work, Role::HiddenCount).as_u64().unwrap();
    assert_eq!(calls, 4);
    // Settled with several calls: it reads as its summary.
    assert_eq!(w.role(work, Role::Summary), "Ran 4 commands");
    w.tl.toggle(&fold_id);
    w.drain();
    assert!(w.rows_of("work").is_empty());
}

#[test]
fn only_a_settled_turns_answer_carries_its_meta() {
    let mut w = World::new();
    w.open();
    w.start_run(Some(0), "running");
    w.add_item(
        "assistant_message",
        json!({"id": "comment", "text": "Looking at the cart first."}),
    );
    w.add_command(1, "completed");
    w.add_item(
        "assistant_message",
        json!({"id": "answer", "text": "The cart now shows tax."}),
    );
    assert_eq!(w.role(w.row("comment"), Role::Meta), false);
    assert_eq!(w.role(w.row("answer"), Role::Meta), false);
    w.settle("completed", 30);
    // The comment folded away with the call; open the fold to read it.
    let fold = w.tl.row_id(w.last_of("fold")).unwrap().to_owned();
    w.tl.toggle(&fold);
    w.drain();
    assert_eq!(w.role(w.row("answer"), Role::Meta), true);
    assert_eq!(w.role(w.row("comment"), Role::Meta), false);
}

// streaming.feature: "A stopped turn says who stopped it".
#[test]
fn a_stopped_turn_says_who_stopped_it() {
    let mut w = World::new();
    w.open();
    w.start_run(Some(40), "running");
    w.add_command(1, "interrupted");
    w.settle("interrupted", 40);
    assert_eq!(
        w.role(w.last_of("fold"), Role::Title),
        "You stopped after 40s"
    );

    let mut w = World::new();
    w.open();
    w.start_run(None, "starting");
    w.add_item(
        "run_interrupt_result",
        json!({"message": "Interrupted by the user"}),
    );
    w.settle("interrupted", 0);
    assert_eq!(
        w.role(w.last_of("fold"), Role::Title),
        "You stopped this response"
    );
}

// tool-calls.feature: "Earlier tool calls of a running turn are behind
// a toggle".
#[test]
fn a_running_group_shows_its_latest_call() {
    let mut w = World::new();
    w.open();
    w.start_run(Some(0), "running");
    for n in 1..=5 {
        w.add_command(n, "completed");
    }
    let work = w.last_of("work");
    assert_eq!(w.role(work, Role::Entries).as_array().unwrap().len(), 1);
    assert_eq!(w.last_entry()["id"], "cmd-5");
    assert_eq!(w.role(work, Role::HiddenCount), 4);
    let id = w.tl.row_id(work).unwrap().to_owned();
    w.tl.toggle(&id);
    let out = w.drain();
    assert_eq!(
        out,
        vec![Out::DataChanged {
            first: work,
            last: work,
            roles: vec![Role::Entries, Role::HiddenCount, Role::Expanded],
        }]
    );
    assert_eq!(w.role(work, Role::Entries).as_array().unwrap().len(), 5);
    w.tl.toggle(&id);
    w.drain();
    assert_eq!(w.role(work, Role::Entries).as_array().unwrap().len(), 1);
}

// tool-calls.feature: "A tool call says how it ended".
#[test]
fn a_call_says_how_it_ended() {
    for (status, label) in [
        ("running", "Running"),
        ("failed", "Failed"),
        ("interrupted", "Stopped"),
        ("completed", ""),
    ] {
        let mut w = World::new();
        w.open();
        w.start_run(Some(0), "running");
        w.add_command(1, status);
        assert_eq!(w.last_entry()["statusLabel"], label, "{status}");
    }
    let mut w = World::new();
    w.open();
    w.start_run(Some(0), "running");
    w.set(
        "runtime-request",
        "request-1",
        json!({"id": "request-1", "status": "resolved", "decision": "decline"}),
    );
    w.add_item(
        "approval_request",
        json!({"requestId": "request-1", "prompt": "Run rm -rf dist?"}),
    );
    let entry = w.last_entry();
    assert_eq!(entry["statusLabel"], "Declined");
    assert_eq!(entry["label"], "Approval requested");
    assert_eq!(entry["detail"], "Run rm -rf dist?");
}

// tool-calls.feature: "A tool call's icon says what kind of work it was".
#[test]
fn a_call_has_its_kinds_icon() {
    for (kind, icon) in [
        ("command_execution", "terminal"),
        ("file_change", "square-pen"),
        ("file_search", "search"),
        ("web_search", "globe"),
        ("dynamic_tool", "wrench"),
        ("approval_request", "message-circle"),
    ] {
        let mut w = World::new();
        w.open();
        w.start_run(Some(0), "running");
        w.add_item(kind, json!({}));
        assert_eq!(w.last_entry()["icon"], icon, "{kind}");
    }
}

#[test]
fn a_calls_entry_reads_its_item() {
    let mut w = World::new();
    w.tl.set_workspace_root(Some(Rc::new(|| "/work/shop/".to_owned())));
    w.open();
    w.start_run(Some(0), "running");
    w.add_item(
        "file_change",
        json!({"fileName": "/work/shop/src/cart.ts", "additions": 3, "deletions": 1}),
    );
    let entry = w.last_entry();
    assert_eq!(entry["label"], "src/cart.ts");
    assert_eq!(entry["path"], "/work/shop/src/cart.ts");
    assert_eq!(entry["detail"], "+3 -1");
    w.add_item(
        "dynamic_tool",
        json!({"toolName": "lookup", "input": {"query": "tax", "n": 2}}),
    );
    let entry = w.last_entry();
    assert_eq!(entry["label"], "lookup");
    assert_eq!(
        entry["detail"],
        "{\n    \"n\": 2,\n    \"query\": \"tax\"\n}"
    );
    w.add_item(
        "command_execution",
        json!({"input": "bun test", "output": "ok", "exitCode": 0, "title": " Tests "}),
    );
    let entry = w.last_entry();
    assert_eq!(entry["label"], "Tests");
    assert_eq!(entry["command"], "bun test");
    assert_eq!(entry["exitCode"], 0);
    assert_eq!(entry["time"], "10:00 AM");
}

// checkpoints.feature: "A reply lists the files its turn changed".
#[test]
fn a_reply_lists_the_files_its_turn_changed() {
    let mut w = World::new();
    w.open();
    w.start_run(Some(60), "running");
    w.add_item("file_change", json!({"fileName": "src/cart.ts"}));
    w.add_item("file_change", json!({"fileName": "src/tax.ts"}));
    let reply = w.add_item(
        "assistant_message",
        json!({"text": "Both files are updated."}),
    );
    w.add_item(
        "checkpoint",
        json!({"files": [
            {"path": "src/cart.ts", "kind": "modified", "additions": 10, "deletions": 1},
            {"path": "src/tax.ts", "kind": "modified", "additions": 20, "deletions": 2},
        ]}),
    );
    w.settle("completed", 60);
    assert_eq!(
        w.role(w.row(&reply), Role::Files),
        json!([
            {"path": "src/cart.ts", "additions": 10, "deletions": 1},
            {"path": "src/tax.ts", "additions": 20, "deletions": 2},
        ])
    );
}

// runs-and-queue.feature: "A message says how it reached the agent".
#[test]
fn a_message_says_how_it_reached_the_agent() {
    for (intent, marker) in [
        ("queued_turn", "Queued behind the active turn"),
        ("steer", "Steered the active turn"),
        (
            "promoted_queued_to_steer",
            "Originally queued, then promoted to steer the active turn",
        ),
    ] {
        let mut w = World::new();
        w.open();
        let run = w.start_run(Some(0), "queued");
        let message = format!("message:{run}");
        w.set("turn-item", &message, json!({"inputIntent": intent}));
        assert_eq!(w.role(w.row(&message), Role::Marker), marker);
        assert_eq!(w.role(w.row(&message), Role::Intent), intent);
    }
}

// streaming.feature: the stamps and the full time.
#[test]
fn a_message_is_stamped_by_its_day() {
    for (sent, format, stamp, full) in [
        (
            "2026-09-23T09:05:00Z",
            "locale",
            "9:05 AM",
            "9:05 AM, 23rd September 2026",
        ),
        (
            "2026-09-23T09:05:00Z",
            "12-hour",
            "9:05 AM",
            "9:05 AM, 23rd September 2026",
        ),
        (
            "2026-09-23T09:05:00Z",
            "24-hour",
            "09:05",
            "09:05, 23rd September 2026",
        ),
        (
            "2026-09-22T09:05:00Z",
            "locale",
            "yesterday at 9:05 AM",
            "9:05 AM, 22nd September 2026",
        ),
        (
            "2026-09-20T09:05:00Z",
            "locale",
            "9/20 9:05 AM",
            "9:05 AM, 20th September 2026",
        ),
        (
            "2025-12-30T09:05:00Z",
            "locale",
            "12/30/2025 9:05 AM",
            "9:05 AM, 30th December 2025",
        ),
    ] {
        let mut w = World::new();
        w.tl.set_timestamp_format(format);
        w.open();
        let ago = (w.now.get() - at(sent)).num_seconds();
        let run = w.start_run(Some(ago), "running");
        let message = format!("message:{run}");
        assert_eq!(
            w.role(w.row(&message), Role::Time),
            stamp,
            "{sent} {format}"
        );
        assert_eq!(w.tl.time_title(&message, ""), full, "{sent} {format}");
    }
}

#[test]
fn a_new_time_format_redraws_every_time() {
    let mut w = World::new();
    w.open();
    w.start_run(Some(0), "running");
    w.tl.set_timestamp_format("24-hour");
    let out = w.drain();
    assert_eq!(
        out,
        vec![
            Out::TimesChanged,
            Out::DataChanged {
                first: 0,
                last: 0,
                roles: vec![Role::Time, Role::Entries],
            },
        ]
    );
    w.tl.set_timestamp_format("24-hour");
    assert!(w.drain().is_empty());
}

// plans-and-subagents.feature: plan cards.
#[test]
fn a_plan_is_a_card_titled_by_its_heading() {
    let mut w = World::new();
    w.open();
    w.start_run(Some(0), "running");
    w.add_item(
        "proposed_plan",
        json!({"markdown": "Here is the plan.\n\n## Add a tax line\n\n- Add the line\n- Test it"}),
    );
    assert_eq!(w.role(w.last_of("plan"), Role::Title), "Add a tax line");
    w.add_item(
        "proposed_plan",
        json!({"markdown": "# Add a tax line\n\n## Summary\n\n- Add the line\n- Test it"}),
    );
    let plan = w.last_of("plan");
    assert_eq!(w.role(plan, Role::Title), "Add a tax line");
    assert_eq!(w.role(plan, Role::Text), "- Add the line\n- Test it");
    assert_eq!(w.role(plan, Role::Icon), "");
    w.add_item(
        "proposed_plan",
        json!({"markdown": "Add the line, then test it."}),
    );
    assert_eq!(w.role(w.last_of("plan"), Role::Title), "Proposed plan");
}

// plans-and-subagents.feature: "A subagent's status is shown in the parent".
#[test]
fn a_subagent_shows_its_status() {
    for (status, label) in [
        ("running", "Working"),
        ("waiting", "Working"),
        ("idle", "Idle · resumable"),
        ("completed", "Completed"),
        ("failed", "Failed"),
        ("cancelled", "Stopped"),
    ] {
        let mut w = World::new();
        w.open();
        w.start_run(Some(0), "running");
        w.add_item(
            "subagent",
            json!({"status": status, "title": "Tax tests", "prompt": "write the tax tests",
                   "childThreadId": "thread-child"}),
        );
        let row = w.last_of("subagent");
        assert_eq!(w.role(row, Role::StatusLabel), label, "{status}");
        assert_eq!(w.role(row, Role::Title), "Tax tests");
        assert_eq!(w.role(row, Role::Thread), "thread-child");
        assert_eq!(w.role(row, Role::Icon), "bot");
    }
}

// plans-and-subagents.feature: context markers.
#[test]
fn context_changes_are_marked() {
    for (fields, title, detail) in [
        (
            json!({"type": "fork", "targetThreadId": "thread-2"}),
            "Conversation fork",
            "Continues in thread-2",
        ),
        (
            json!({"type": "handoff", "summary": "Cart tax so far"}),
            "Context handoff",
            "",
        ),
        (
            json!({"type": "thread_created", "title": "Tax tests"}),
            "Created thread",
            "Tax tests",
        ),
        (
            json!({"type": "compaction", "summary": "Earlier turns"}),
            "Context compacted",
            "",
        ),
    ] {
        let mut w = World::new();
        w.open();
        w.start_run(Some(0), "running");
        let kind = fields["type"].as_str().unwrap().to_owned();
        w.add_item(&kind, fields);
        let row = w.last_of("marker");
        assert_eq!(w.role(row, Role::Title), title);
        assert_eq!(w.role(row, Role::Text), detail);
    }
}

#[test]
fn a_delegated_result_is_a_notification() {
    let mut w = World::new();
    w.open();
    w.start_run(Some(0), "running");
    let id = w.add_item(
        "user_message",
        json!({"createdBy": "system", "creationSource": "server",
               "text": "<delegated_task_result taskId=\"task:1\" title=\"Tax tests\" status=\"failed\" childThreadId=\"thread:2\">\nno\n</delegated_task_result>"}),
    );
    let row = w.row(&id);
    assert_eq!(w.role(row, Role::Kind), "marker");
    assert_eq!(w.role(row, Role::Title), "Tax tests failed");
    assert_eq!(w.role(row, Role::Icon), "circle-alert");
    assert_eq!(w.role(row, Role::Attribution), "");
}

#[test]
fn a_message_from_another_agent_names_its_thread() {
    let mut w = World::new();
    w.tl.set_thread_titles(Some(Rc::new(|id: &str| {
        if id == "thread-9" {
            "Release".into()
        } else {
            String::new()
        }
    })));
    w.open();
    w.start_run(Some(0), "running");
    let known = w.add_item(
        "user_message",
        json!({"createdBy": "agent", "senderThreadId": "thread-9", "text": "Ready"}),
    );
    let unknown = w.add_item(
        "user_message",
        json!({"createdBy": "agent", "senderThreadId": "thread-8", "text": "Ready"}),
    );
    let scheduled = w.add_item(
        "user_message",
        json!({"scheduledTaskId": "task-1", "text": "Daily"}),
    );
    assert_eq!(w.role(w.row(&known), Role::Attribution), "From Release");
    assert_eq!(w.role(w.row(&known), Role::Thread), "thread-9");
    assert_eq!(
        w.role(w.row(&unknown), Role::Attribution),
        "Sent by another agent"
    );
    assert_eq!(
        w.role(w.row(&scheduled), Role::Attribution),
        "Sent by automation"
    );
}

#[test]
fn a_usage_limit_is_a_wait_until_it_resets() {
    let mut w = World::new();
    w.open();
    w.start_run(Some(0), "running");
    w.add_item(
        "error",
        json!({"failure": {"class": "usage_limit", "message": "You hit the limit",
                           "resetAt": "2026-09-24T09:41:00Z"}}),
    );
    let row = w.last_of("error");
    assert_eq!(
        w.role(row, Role::Title),
        "Usage limit reached. Retry after tomorrow at 9:41 AM."
    );
    assert_eq!(w.role(row, Role::Text), "");
    assert_eq!(w.role(row, Role::Warning), true);
    w.add_item("error", json!({"failure": {"message": "Boom"}}));
    let row = w.last_of("error");
    assert_eq!(w.role(row, Role::Title), "Error");
    assert_eq!(w.role(row, Role::Text), "Boom");
    assert_eq!(w.role(row, Role::Warning), false);
}

#[test]
fn a_message_links_its_pull_request() {
    let mut w = World::new();
    w.open();
    w.start_run(Some(0), "running");
    let reply = w.add_item(
        "assistant_message",
        json!({"text": "Opened https://github.com/o/r/pull/12 for it.", "messageId": "m-1"}),
    );
    let row = w.row(&reply);
    assert_eq!(
        w.role(row, Role::PullRequestUrl),
        "https://github.com/o/r/pull/12"
    );
    assert_eq!(w.role(row, Role::MessageId), "m-1");
    assert_eq!(
        w.tl.copy_text(&reply).as_deref(),
        Some("Opened https://github.com/o/r/pull/12 for it.")
    );
}

// streaming.feature: "A user message shows its images".
#[test]
fn an_image_is_asked_for_once_until_it_expires() {
    let mut w = World::new();
    w.open();
    let run = w.start_run(Some(0), "running");
    let message = format!("message:{run}");
    w.set(
        "turn-item",
        &message,
        json!({"attachments": [{"type": "image", "id": "image-1", "name": "cart.png"}]}),
    );
    let row = w.row(&message);
    assert_eq!(
        w.role(row, Role::Attachments),
        json!([{"id": "image-1", "name": "cart.png", "url": ""}])
    );
    w.tl.load_attachment("image-1");
    w.tl.load_attachment("image-1");
    assert_eq!(w.drain(), vec![Out::AttachmentWanted("image-1".into())]);
    let expires = w.now.get() + Duration::hours(1);
    w.tl.set_attachment_url("image-1", "https://mc/a/1.png", Some(expires));
    assert_eq!(
        w.drain(),
        vec![Out::DataChanged {
            first: row,
            last: row,
            roles: vec![Role::Attachments],
        }]
    );
    assert_eq!(
        w.role(row, Role::Attachments)[0]["url"],
        "https://mc/a/1.png"
    );
    w.now.set(w.now.get() + Duration::seconds(3660));
    assert_eq!(w.role(row, Role::Attachments)[0]["url"], "");
    w.tl.load_attachment("image-1");
    assert_eq!(w.drain(), vec![Out::AttachmentWanted("image-1".into())]);
}

// runs-and-queue.feature: "A sent file shows its name, kind and size" and
// "A sent attachment of a kind this client does not know is listed by name
// only".
#[test]
fn a_sent_file_is_listed_by_name_kind_and_size() {
    let mut w = World::new();
    w.open();
    let run = w.start_run(Some(0), "running");
    let message = format!("message:{run}");
    w.set(
        "turn-item",
        &message,
        json!({"attachments": [
            {"type": "image", "id": "image-1", "name": "cart.png"},
            {"type": "file", "id": "file-1", "name": "report.pdf",
             "mimeType": "application/pdf", "sizeBytes": 2 * 1024 * 1024},
            {"type": "file", "id": "file-2", "name": "Makefile", "sizeBytes": 512},
        ]}),
    );
    let row = w.row(&message);
    assert_eq!(
        w.role(row, Role::SentFiles),
        json!([
            {"id": "file-1", "name": "report.pdf", "detail": "PDF · 2.0 MiB"},
            {"id": "file-2", "name": "Makefile", "detail": "512 bytes"},
        ])
    );
    assert_eq!(w.role(row, Role::Attachments).as_array().unwrap().len(), 1);

    let run = w.start_run(Some(0), "running");
    let message = format!("message:{run}");
    w.set(
        "turn-item",
        &message,
        json!({"attachments": [{"type": "hologram", "id": "other-1", "name": "scene.holo"}]}),
    );
    let row = w.row(&message);
    assert_eq!(
        w.role(row, Role::SentFiles),
        json!([{"id": "other-1", "name": "scene.holo", "detail": ""}])
    );
    // There is nothing to open.
    assert_eq!(w.role(row, Role::Attachments), json!([]));
    // Only a user message sends files.
    let reply = w.add_item(
        "assistant_message",
        json!({"text": "Done", "attachments": [{"type": "file", "id": "f", "name": "a.txt"}]}),
    );
    assert_eq!(w.role(w.row(&reply), Role::SentFiles), json!([]));
}

// checkpoints.feature: reverting to a turn and editing from a message.
#[test]
fn a_reply_reverts_to_its_checkpoint_and_a_message_rewinds() {
    let mut w = World::new();
    w.open();
    let first = w.start_run(Some(30), "running");
    w.set(
        "checkpoint",
        "cp-0",
        json!({"runId": first, "status": "ready", "scopeId": "scope", "appRunOrdinal": null}),
    );
    let reply1 = w.add_item("assistant_message", json!({"text": "one"}));
    assert!(w.tl.checkpoint_of(&reply1).is_empty(), "not while it runs");
    w.settle("completed", 10);
    w.set(
        "checkpoint",
        "cp-1",
        json!({"runId": first, "status": "ready", "scopeId": "scope", "appRunOrdinal": 1}),
    );
    assert_eq!(
        Json::Object(w.tl.checkpoint_of(&reply1)),
        json!({"checkpointId": "cp-0", "scopeId": "scope", "turn": 1})
    );
    assert_eq!(w.tl.finished_run_of(&reply1), first);

    let second = w.start_run(Some(5), "running");
    let point = w.tl.rewind_point_of(&format!("message:{second}"));
    assert_eq!(point["turn"], 2);
    assert_eq!(point["checkpointId"], "cp-1");
    assert_eq!(point["text"], "Add a tax line");
    // The first turn rewinds to the thread's baseline.
    let point = w.tl.rewind_point_of(&format!("message:{first}"));
    assert_eq!(point["turn"], 1);
    assert_eq!(point["checkpointId"], "cp-0");
    assert!(w.tl.rewind_point_of(&reply1).is_empty());
}

// --- tst_TimelineRepaintRegression -------------------------------------------------

fn item(id: &str, kind: &str, ordinal: i64, fields: Json) -> Json {
    let mut item = json!({"id": id, "type": kind, "runId": "run-1", "ordinal": ordinal, "status": "completed"});
    for (k, v) in obj(fields) {
        item[k] = v;
    }
    item
}

fn row(kind: &str, entity: Json) -> Json {
    json!([kind, entity["id"], entity])
}

fn run(status: &str) -> Json {
    json!({"id": "run-1", "ordinal": 1, "status": status})
}

fn redraws(out: &[Out]) -> usize {
    out.iter()
        .filter(|o| matches!(o, Out::DataChanged { .. }))
        .count()
}

#[test]
fn an_unchanged_copy_redraws_no_row() {
    let mut w = World::new();
    let rows = vec![
        row("run", run("running")),
        row(
            "turn-item",
            item("ask", "user_message", 2, json!({"text": "ask"})),
        ),
    ];
    w.seq = 2;
    w.snapshot(rows.clone());
    w.tl.subscribing();
    w.tl.receive(&obj(
        json!({"t": "snapshot", "part": 0, "rows": rows, "done": true,
                              "offset": 2, "handle": "log-2", "floor": null}),
    ));
    assert_eq!(redraws(&w.drain()), 0);
}

#[test]
fn text_a_hidden_call_streams_redraws_no_group() {
    let mut w = World::new();
    w.seq = 3;
    w.snapshot(vec![
        row("run", run("running")),
        row(
            "turn-item",
            item("reas-2", "reasoning", 2, json!({"text": "t"})),
        ),
        row(
            "turn-item",
            item(
                "cmd-3",
                "command_execution",
                3,
                json!({"status": "running"}),
            ),
        ),
    ]);
    let out = w.change("turn-item", "reas-2", json!({"a": {"text": "more"}}));
    assert_eq!(redraws(&out), 0);
}

#[test]
fn an_event_sent_again_is_applied_once() {
    let mut w = World::new();
    w.seq = 2;
    w.snapshot(vec![
        row("run", run("running")),
        row(
            "turn-item",
            item(
                "reply",
                "assistant_message",
                2,
                json!({"text": "a", "streaming": true}),
            ),
        ),
    ]);
    let delta = obj(json!({"t": "events", "offset": 3,
                           "events": [[3, "turn-item", "reply", {"a": {"text": "b"}}, "x"]]}));
    w.tl.receive(&delta);
    w.tl.receive(&delta);
    w.drain();
    assert_eq!(w.role(w.row("reply"), Role::Text), "ab");
}

#[test]
fn a_subagent_row_redraws_its_model_only_when_it_changes() {
    let mut w = World::new();
    w.seq = 2;
    w.snapshot(vec![
        row("run", run("running")),
        row("subagent", json!({"id": "agent-1", "model": "opus"})),
        row(
            "turn-item",
            item("suba-2", "subagent", 2, json!({"subagentId": "agent-1"})),
        ),
    ]);
    w.view.redrawn.clear();
    let model_redrawn = |w: &World| {
        w.view
            .redrawn
            .iter()
            .any(|(id, roles)| id == "suba-2" && roles.contains(&Role::Model))
    };
    w.set("run", "run-1", json!({"status": "failed"}));
    assert!(!model_redrawn(&w));
    w.set("subagent", "agent-1", json!({"model": "sonnet"}));
    assert!(model_redrawn(&w));
    assert_eq!(w.role(w.row("suba-2"), Role::Model), "sonnet");
}

#[test]
fn a_subagent_model_changed_back_redraws_nothing() {
    let mut w = World::new();
    w.seq = 2;
    w.snapshot(vec![
        row("run", run("running")),
        row("subagent", json!({"id": "agent-1", "model": "opus"})),
        row(
            "turn-item",
            item("suba-2", "subagent", 2, json!({"subagentId": "agent-1"})),
        ),
    ]);
    w.tl.receive(&obj(json!({"t": "events", "offset": 4, "events": [
        [3, "subagent", "agent-1", {"s": {"model": "sonnet"}}, "x"],
        [4, "subagent", "agent-1", {"s": {"model": "opus"}}, "x"],
    ]})));
    assert_eq!(redraws(&w.drain()), 0);
}

#[test]
fn a_catch_up_that_adds_and_removes_an_item_redraws_nothing() {
    let mut w = World::new();
    w.seq = 2;
    w.snapshot(vec![
        row("run", run("running")),
        row(
            "turn-item",
            item("reas-2", "reasoning", 2, json!({"text": "t"})),
        ),
    ]);
    w.tl.subscribing();
    let added = item("reas-3", "reasoning", 3, json!({"text": "u"}));
    w.tl.receive(&obj(json!({"t": "events", "offset": 2,
        "events": [[3, "turn-item", "reas-3", {"d": true, "s": added}, "x"]]})));
    w.tl.receive(&obj(json!({"t": "events", "offset": 4,
        "events": [[4, "turn-item", "reas-3", {"d": true}, "x"]]})));
    w.tl.receive(&obj(json!({"t": "live", "offset": 4, "handle": "log-1"})));
    assert_eq!(redraws(&w.drain()), 0);
    assert_eq!(w.tl.cursor().offset, 4);
}

// streaming.feature: "A catch-up cut off part-way is not applied twice".
#[test]
fn a_catch_up_cut_off_part_way_is_dropped() {
    let mut w = World::new();
    w.seq = 2;
    w.snapshot(vec![
        row("run", run("running")),
        row(
            "turn-item",
            item(
                "reply",
                "assistant_message",
                2,
                json!({"text": "The cart", "streaming": true}),
            ),
        ),
    ]);
    w.tl.subscribing();
    w.tl.receive(&obj(json!({"t": "events", "offset": 2,
        "events": [[3, "turn-item", "reply", {"a": {"text": " now"}}, "x"]]})));
    // The connection drops before the rest; the client asks again.
    assert_eq!(
        w.tl.subscribing(),
        json!({"offset": 2, "window": {"floor": null}, "handle": "log-1"})
    );
    w.tl.receive(&obj(json!({"t": "events", "offset": 4, "events": [
        [3, "turn-item", "reply", {"a": {"text": " now"}}, "x"],
        [4, "turn-item", "reply", {"a": {"text": " shows tax."}, "s": {"streaming": false}}, "x"],
    ]})));
    w.tl.receive(&obj(json!({"t": "live", "offset": 4, "handle": "log-1"})));
    w.drain();
    assert_eq!(
        w.role(w.row("reply"), Role::Text),
        "The cart now shows tax."
    );
}

#[test]
fn a_resync_only_moves_the_offset_on() {
    let mut w = World::new();
    w.seq = 5;
    w.open();
    w.tl.receive(&obj(json!({"t": "resync", "offset": 3})));
    assert_eq!(w.tl.cursor().offset, 5);
    w.tl.receive(&obj(json!({"t": "resync", "offset": 9})));
    assert_eq!(w.tl.cursor().offset, 9);
}

// --- The window and the cache ------------------------------------------------------

/// Run `n` with one user message and `items` replies.
fn turn(n: i64, items: i64) -> Vec<Json> {
    let id = format!("run-{n}");
    let mut rows = vec![json!(["run", id, {"id": id, "ordinal": n, "status": "completed"}])];
    for k in 0..=items {
        let item_id = format!("item-{n}-{k}");
        let kind = if k == 0 {
            "user_message"
        } else {
            "assistant_message"
        };
        rows.push(json!(["turn-item", item_id, {"id": item_id, "type": kind, "runId": id,
                                                 "ordinal": n * 1000 + k, "text": format!("{n}.{k}")}]));
    }
    rows
}

#[test]
fn earlier_turns_load_above_the_window() {
    let mut w = World::new();
    w.tl.subscribing();
    w.tl.receive(&obj(
        json!({"t": "snapshot", "part": 0, "rows": turn(2, 1), "done": true,
                              "offset": 7, "handle": "log-1", "floor": 2}),
    ));
    w.tl.receive(&obj(json!({"t": "live", "offset": 7, "handle": "log-1"})));
    w.drain();
    assert!(w.tl.has_earlier());
    let held = w.view.ids.clone();
    w.tl.load_earlier();
    w.tl.load_earlier();
    let out = w.drain();
    assert_eq!(
        out,
        vec![Out::EarlierChanged, Out::EarlierWanted(WINDOW_ITEMS)]
    );
    assert!(w.tl.loading_earlier());
    w.tl.receive(&obj(
        json!({"t": "page", "rows": turn(1, 1), "offset": 7, "floor": null, "done": true}),
    ));
    let out = w.drain();
    assert!(out.contains(&Out::Inserted {
        first: 0,
        ids: vec!["item-1-0".into(), "item-1-1".into()],
    }));
    assert!(!w.tl.has_earlier() && !w.tl.loading_earlier());
    assert_eq!(&w.view.ids[2..], &held[..]);
}

#[test]
fn a_dropped_stream_stops_loading_earlier() {
    let mut w = World::new();
    w.tl.subscribing();
    w.tl.receive(&obj(
        json!({"t": "snapshot", "part": 0, "rows": turn(2, 1), "done": true,
                              "offset": 7, "handle": "log-1", "floor": 2}),
    ));
    w.tl.receive(&obj(json!({"t": "live", "offset": 7, "handle": "log-1"})));
    w.tl.load_earlier();
    w.tl.set_status("unreachable", "gone");
    assert!(!w.tl.loading_earlier());
    w.drain();
}

/// A run the user stopped, its items, and a second run `other`; the
/// stopped turn's fold title.
fn stopped_fold_title(other: Json, items: Vec<Json>, fold: &str) -> Json {
    let mut w = World::new();
    let mut rows = vec![row("run", run("interrupted")), row("run", other)];
    rows.extend(items.into_iter().map(|item| row("turn-item", item)));
    w.seq = 8;
    w.snapshot(rows);
    let fold = w.row(fold);
    w.role(fold, Role::Title)
}

fn stopped_turn() -> Vec<Json> {
    vec![
        item("ask", "user_message", 1, json!({"text": "ask"})),
        item("reas-2", "reasoning", 2, json!({"text": "t"})),
        item("reply", "assistant_message", 3, json!({"text": "a"})),
    ]
}

// A turn the user stopped read "Worked" once a held queued message it passed
// was numbered above it: the held run is not the thread's latest.
#[test]
fn a_stopped_turn_above_a_held_queue_says_the_user_stopped_it() {
    let held = json!({"id": "run-2", "ordinal": 2, "status": "queued", "queueHeld": true});
    assert_eq!(
        stopped_fold_title(held, stopped_turn(), "fold:run-1"),
        "You stopped this response"
    );
}

// The same held run cancelled instead of resumed: it never started, so the
// stopped turn it waited behind is still the thread's latest.
#[test]
fn a_stopped_turn_above_a_cancelled_held_run_says_the_user_stopped_it() {
    let held = json!({"id": "run-2", "ordinal": 2, "status": "cancelled", "queueHeld": true});
    assert_eq!(
        stopped_fold_title(held, stopped_turn(), "fold:run-1"),
        "You stopped this response"
    );
}

// Legacy runs stored without an ordinal both read 0: the tie goes to the
// later-starting run (its first item is later in timeline order), so the
// stopped turn still reads as the thread's latest.
#[test]
fn a_stopped_turn_with_no_stored_ordinals_says_the_user_stopped_it() {
    let mut w = World::new();
    let second = |id: &str, kind: &str, ordinal: i64, text: &str| {
        item(id, kind, ordinal, json!({"text": text, "runId": "run-2"}))
    };
    let rows = vec![
        row("run", json!({"id": "run-1", "status": "completed"})),
        row("run", json!({"id": "run-2", "status": "interrupted"})),
        row(
            "turn-item",
            item("ask-1", "user_message", 1, json!({"text": "ask"})),
        ),
        row(
            "turn-item",
            item("reas-1", "reasoning", 2, json!({"text": "t"})),
        ),
        row(
            "turn-item",
            item("reply-1", "assistant_message", 3, json!({"text": "a"})),
        ),
        row("turn-item", second("ask-2", "user_message", 4, "ask")),
        row("turn-item", second("reas-2", "reasoning", 5, "t")),
        row("turn-item", second("reply-2", "assistant_message", 6, "b")),
    ];
    w.seq = 8;
    w.snapshot(rows);
    let fold = w.row("fold:run-2");
    assert_eq!(w.role(fold, Role::Title), "You stopped this response");
}

// A run renumbered at start left its items' cached run ordinal at the old
// one, so a cold-start copy filtered and trimmed by it.
#[test]
fn a_renumbered_run_recaches_its_items() {
    let cache = Rc::new(MemoryCache::default());
    let mut w = World::new();
    w.tl.set_cache(Some(cache.clone()));
    w.seq = 3;
    w.snapshot(vec![
        row("run", run("running")),
        row(
            "turn-item",
            item("ask", "user_message", 1, json!({"text": "ask"})),
        ),
        row(
            "turn-item",
            item("reply", "assistant_message", 2, json!({"text": "a"})),
        ),
    ]);
    w.tl.flush();
    w.change("run", "run-1", json!({"s": {"ordinal": 7}}));
    w.tl.flush();
    w.drain();
    let items: Vec<_> = cache
        .load("env:thread")
        .entities
        .into_iter()
        .filter(|e| e.kind == "turn-item")
        .collect();
    assert_eq!(items.len(), 2);
    assert!(items.iter().all(|e| e.run == Some(7)), "{items:?}");
}

#[test]
fn a_copy_is_cached_and_restored() {
    let cache = Rc::new(MemoryCache::default());
    let mut w = World::new();
    w.tl.set_cache(Some(cache.clone()));
    let mut rows = turn(1, 1);
    rows.extend(turn(2, 1));
    w.seq = 4;
    w.snapshot(rows);
    let held = cache.load("env:thread");
    assert_eq!(held.cursor.offset, 4);
    assert_eq!(held.entities.len(), 6);
    assert!(held
        .entities
        .iter()
        .all(|e| e.kind == "run" && e.run.is_none() || e.kind == "turn-item" && e.run.is_some()));

    // A delta waits for the flush timer.
    let out = w.change("turn-item", "item-2-1", json!({"a": {"text": "!"}}));
    assert!(out.contains(&Out::FlushTimer(true)));
    assert_eq!(cache.load("env:thread").cursor.offset, 4);
    w.tl.flush();
    assert_eq!(w.drain(), vec![Out::FlushTimer(false)]);
    let held = cache.load("env:thread");
    assert_eq!(held.cursor.offset, 5);

    // A new timeline shows the copy at once, loading, and resumes from it.
    let mut again = World::new();
    again.tl.restore(&held);
    again.drain();
    assert_eq!(again.tl.status(), "loading");
    assert_eq!(again.view.ids, w.view.ids);
    assert_eq!(again.role(again.row("item-2-1"), Role::Text), "2.1!");
    assert_eq!(
        again.tl.subscribing(),
        json!({"offset": 5, "window": {"floor": null}, "handle": "log-1"})
    );
}

// timeline_prop's seed 39f43f3d: a page is taken at the log's head, so it
// moves the copy's offset past a change outside the window that was never
// sent, and the copy a restart restores resumes from there.
#[test]
fn a_page_moves_the_cached_offset_past_changes_it_was_not_sent() {
    let cache = Rc::new(MemoryCache::default());
    let mut w = World::new();
    w.tl.set_cache(Some(cache.clone()));
    // Five turns, then a window on the newest three.
    let mut rows: Vec<Json> = (1..=2).map(|n| turn(n, 0).remove(0)).collect();
    for n in 3..=5 {
        rows.extend(turn(n, 0));
    }
    w.tl.subscribing();
    w.tl.receive(&obj(
        json!({"t": "snapshot", "part": 0, "rows": rows, "done": true,
                              "offset": 10, "handle": "log-1", "floor": 3}),
    ));
    w.tl.receive(&obj(json!({"t": "live", "offset": 10, "handle": "log-1"})));
    w.drain();
    // A reply in the first turn (offset 11) is outside the window: the MC
    // sends nothing. The page of earlier turns holds it.
    w.tl.load_earlier();
    let mut page: Vec<Json> = turn(1, 1).into_iter().skip(1).collect();
    page.extend(turn(2, 0).into_iter().skip(1));
    w.tl.receive(&obj(
        json!({"t": "page", "rows": page, "offset": 11, "floor": null, "done": true}),
    ));
    w.drain();
    assert_eq!(w.tl.cursor().offset, 11);

    w.tl.park();
    let mut again = World::new();
    again.tl.set_cache(Some(cache.clone()));
    again.tl.restore(&cache.load("env:thread"));
    again.drain();
    assert_eq!(again.tl.cursor().offset, 11);
    assert_eq!(again.view.ids, w.view.ids);
    assert_eq!(
        again.tl.subscribing(),
        json!({"offset": 11, "window": {"floor": null}, "handle": "log-1"})
    );
}

#[test]
fn parking_trims_the_copy_to_the_window() {
    let cache = Rc::new(MemoryCache::default());
    let mut w = World::new();
    w.tl.set_cache(Some(cache.clone()));
    let mut rows = Vec::new();
    for n in 1..=3 {
        rows.extend(turn(n, WINDOW_ITEMS - 1));
    }
    w.seq = 4;
    w.snapshot(rows);
    w.tl.park();
    let held = cache.load("env:thread");
    assert_eq!(held.cursor.floor, Some(3));
    assert!(held.entities.iter().all(|e| e.run.is_none_or(|r| r >= 3)));
}

#[test]
fn patches_set_unset_append_and_replace() {
    let base = obj(json!({"a": "x", "b": 1}));
    let p = |v: Json| patched(Some(&base), &obj(v));
    assert_eq!(
        p(json!({"s": {"c": 2}, "u": ["b"], "a": {"a": "y", "d": "z"}})),
        Some(obj(json!({"a": "xy", "c": 2, "d": "z"})))
    );
    assert_eq!(p(json!({"d": true})), None);
    assert_eq!(
        p(json!({"d": true, "s": {"c": 2}})),
        Some(obj(json!({"c": 2})))
    );
    assert_eq!(
        patched(None, &obj(json!({"a": {"t": "x"}}))),
        Some(obj(json!({"t": "x"})))
    );
}

#[test]
fn stream_kinds_name_the_folded_entities() {
    let kinds = Timeline::stream_kinds();
    assert_eq!(kinds["message"], json!({"role": "user"}));
    assert_eq!(kinds["turn-item"], json!({}));
    assert_eq!(kinds.as_object().unwrap().len(), KINDS.len());
}
