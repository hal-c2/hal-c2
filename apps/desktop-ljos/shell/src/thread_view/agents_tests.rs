//! The Agents tab's behaviour (features/timeline/plans-and-subagents.feature,
//! desktop-qt's AgentsSteps), against the core on a fixed clock.

use std::cell::Cell;
use std::collections::BTreeMap;
use std::rc::Rc;

use chrono::{DateTime, Duration, Utc};
use proptest::prelude::*;
use serde_json::json;

use super::agents::*;
use super::rows::{Mirror, RowSource};
use super::summary::Obj;
use super::time::{Clock, Zone, parse_iso};
use crate::json::Json;

fn at(text: &str) -> DateTime<Utc> {
    parse_iso(text, Zone::utc()).expect("a time")
}

fn iso(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

fn obj(value: Json) -> Obj {
    match value {
        Json::Object(o) => o,
        _ => panic!("not an object"),
    }
}

/// A thread's subagents, runs and turn items, and the tab following them.
struct World {
    now: Rc<Cell<DateTime<Utc>>>,
    subagents: BTreeMap<String, Obj>,
    runs: BTreeMap<String, Obj>,
    items: BTreeMap<String, Obj>,
    format: String,
    agents: Agents,
    view: Mirror,
    notes: Vec<Note>,
    ordinal: i64,
}

impl World {
    fn new() -> World {
        let now = Rc::new(Cell::new(at("2026-09-23T10:00:00Z")));
        let clock_now = now.clone();
        let mut agents = Agents::new(Clock {
            now: Rc::new(move || clock_now.get()),
            zone: Zone::utc(),
            locale: ljos::locale::Locale::named("en_US"),
        });
        agents.set_environment("env-1");
        let view = Mirror::of(&mut agents);
        World {
            now,
            subagents: BTreeMap::new(),
            runs: BTreeMap::new(),
            items: BTreeMap::new(),
            format: "locale".into(),
            agents,
            view,
            notes: Vec::new(),
            ordinal: 0,
        }
    }

    /// The tab reads the timeline again, as `agentsChanged` makes it.
    fn read(&mut self) {
        let wanted = wanted(
            &self.subagents,
            &self.runs,
            &self.items,
            self.agents.clock(),
        );
        self.agents.read(Some((wanted, self.format.clone())));
        self.follow();
    }

    fn follow(&mut self) {
        self.view.follow(&mut self.agents);
        self.notes.extend(self.agents.take_notes());
    }

    fn open(&mut self) {
        self.read();
        self.agents.set_active(true);
        self.follow();
    }

    fn start(&mut self, title: &str, since: i64) -> String {
        let slug = title.to_lowercase().replace(' ', "-");
        let id = format!("task-{slug}");
        let started = iso(self.now.get() - Duration::seconds(since));
        self.subagents.insert(
            id.clone(),
            obj(
                json!({"id": id, "runId": "run-1", "childThreadId": format!("thread-{slug}"),
                       "prompt": format!("write the {}", title.to_lowercase()), "title": title,
                       "model": "gpt-5.5", "status": "running", "startedAt": started,
                       "completedAt": null, "updatedAt": started}),
            ),
        );
        id
    }

    fn set(&mut self, id: &str, fields: Json) {
        let entity = self.subagents.get_mut(id).expect("a subagent");
        for (k, v) in obj(fields) {
            entity.insert(k, v);
        }
    }

    fn finish_after(&mut self, id: &str, seconds: i64) {
        let started = at(self.subagents[id]["startedAt"].as_str().unwrap());
        self.set(
            id,
            json!({"status": "completed", "completedAt": iso(started + Duration::seconds(seconds))}),
        );
    }

    fn command(&mut self, input: &str, run: &str) -> String {
        self.ordinal += 1;
        let id = format!("cmd-{}", self.ordinal);
        self.items.insert(
            id.clone(),
            obj(
                json!({"id": id, "type": "command_execution", "runId": run, "ordinal": self.ordinal,
                       "input": input, "status": "running", "startedAt": iso(self.now.get())}),
            ),
        );
        id
    }

    fn row(&self, title: &str) -> usize {
        (0..self.agents.count())
            .find(|r| self.value(*r, "title") == title)
            .unwrap_or_else(|| panic!("no row {title}: {}", self.describe()))
    }

    fn value(&self, row: usize, role: &str) -> String {
        match self.agents.value(row, role) {
            Some(Json::String(s)) => s,
            Some(other) => other.to_string(),
            None => String::new(),
        }
    }

    fn of(&self, title: &str, role: &str) -> String {
        self.value(self.row(title), role)
    }

    fn describe(&self) -> String {
        (0..self.agents.count())
            .map(|r| {
                format!(
                    "{} {} \"{}\" {} ({}) \"{}\"",
                    self.value(r, "section"),
                    self.value(r, "kind"),
                    self.value(r, "title"),
                    self.value(r, "statusLabel"),
                    self.value(r, "elapsed"),
                    self.value(r, "ended")
                )
            })
            .collect::<Vec<_>>()
            .join("; ")
    }

    fn order(&self) -> Vec<(String, String)> {
        (0..self.agents.count())
            .map(|r| (self.value(r, "title"), self.value(r, "section")))
            .collect()
    }

    /// The rows told to redraw `role` since the view was last cleared.
    fn redrawn(&self, role: &str) -> usize {
        self.view
            .redrawn
            .iter()
            .filter(|(_, roles)| roles.contains(&role))
            .count()
    }
}

fn pairs(rows: &[(&str, &str)]) -> Vec<(String, String)> {
    rows.iter()
        .map(|(a, b)| ((*a).to_owned(), (*b).to_owned()))
        .collect()
}

#[test]
fn the_tab_lists_the_threads_subagents() {
    let mut w = World::new();
    w.start("Tax tests", 90);
    let docs = w.start("Docs", 80);
    w.finish_after(&docs, 75);
    w.open();
    let (tax, docs_row) = (w.row("Tax tests"), w.row("Docs"));
    assert!(tax < docs_row, "{}", w.describe());
    assert_eq!(w.value(tax, "statusLabel"), "Working");
    assert_eq!(w.value(docs_row, "statusLabel"), "Completed");
    assert_eq!(w.of("Docs", "elapsed"), "1m 15s");
    assert_eq!(w.of("Tax tests", "elapsed"), "1m 30s");
    assert_eq!(
        w.of("Tax tests", "childThreadKey"),
        "env-1:thread-tax-tests"
    );
    assert_eq!(w.of("Tax tests", "modelName"), "gpt-5.5");
    assert_eq!(w.agents.agent_count(), 2);
    assert!(w.notes.contains(&Note::Count));
}

#[test]
fn what_is_running_stays_above_what_has_finished() {
    let mut w = World::new();
    let docs = w.start("Docs", 90);
    w.start("Tax tests", 80);
    w.finish_after(&docs, 75);
    w.command("  bun test cart \n", "run-1");
    w.open();
    assert_eq!(
        w.order(),
        pairs(&[
            ("Tax tests", "active"),
            ("bun test cart", "active"),
            ("Docs", "finished")
        ])
    );
    assert_eq!(w.agents.agent_count(), 2);
    assert_eq!(w.agents.count(), 3);
}

#[test]
fn each_subagent_says_when_it_finished_latest_first() {
    let mut w = World::new();
    let lint = w.start("Lint", 90000);
    w.finish_after(&lint, 60);
    let tax = w.start("Tax tests", 90);
    let docs = w.start("Docs", 80);
    w.finish_after(&docs, 30);
    w.finish_after(&tax, 85);
    w.open();
    assert_eq!(
        w.order(),
        pairs(&[
            ("Tax tests", "finished"),
            ("Docs", "finished"),
            ("Lint", "finished")
        ])
    );
    assert_eq!(w.of("Tax tests", "ended"), "Completed at 9:59 AM");
    assert_eq!(w.of("Lint", "ended"), "Completed yesterday at 9:01 AM");
}

#[test]
fn the_end_times_follow_the_day_over_midnight() {
    let mut w = World::new();
    let tax = w.start("Tax tests", 120);
    w.finish_after(&tax, 85);
    w.open();
    let midnight = at("2026-09-24T00:00:00Z");
    assert_eq!(w.agents.next_day(), Some(midnight));
    assert!(w.notes.contains(&Note::Day(Some(14 * 3600 * 1000))));
    w.view.redrawn.clear();
    w.notes.clear();
    w.now.set(midnight + Duration::seconds(1));
    // The model's own midnight timer.
    w.agents.redraw_ended();
    w.follow();
    assert!(w.redrawn("ended") > 0);
    assert_eq!(w.of("Tax tests", "ended"), "Completed yesterday at 9:59 AM");
}

#[test]
fn the_end_times_follow_the_day_when_the_desktop_wakes_after_midnight() {
    let mut w = World::new();
    let tax = w.start("Tax tests", 120);
    w.finish_after(&tax, 85);
    let lint = w.start("Lint", 5);
    w.open();
    w.view.redrawn.clear();
    // Midnight passed, and the midnight timer has yet to fire.
    w.now.set(at("2026-09-24T00:00:01Z"));
    w.set(
        &lint,
        json!({"status": "completed", "result": "lint clean", "completedAt": iso(w.now.get())}),
    );
    w.read();
    assert!(
        w.view
            .redrawn
            .iter()
            .any(|(key, roles)| *roles == ["ended"] && *key == w.agents.row_key(w.row("Tax tests"))),
        "{:?}",
        w.view.redrawn
    );
    assert_eq!(w.of("Tax tests", "ended"), "Completed yesterday at 9:59 AM");
    assert_eq!(w.of("Lint", "ended"), "Completed at 12:00 AM");
    // Waiting again, for the next midnight.
    assert_eq!(w.agents.next_day(), Some(at("2026-09-25T00:00:00Z")));
}

#[test]
fn the_tab_tells_the_time_as_the_user_set_it() {
    let mut w = World::new();
    let docs = w.start("Docs", 90);
    w.finish_after(&docs, 75);
    w.open();
    assert_eq!(w.of("Docs", "ended"), "Completed at 9:59 AM");
    w.view.redrawn.clear();
    w.agents.set_timestamp_format("24-hour");
    w.follow();
    assert!(w.redrawn("ended") > 0);
    assert_eq!(w.of("Docs", "ended"), "Completed at 09:59");
}

#[test]
fn rows_are_kept_as_work_starts_and_ends() {
    let mut w = World::new();
    let tax = w.start("Tax tests", 90);
    let docs = w.start("Docs", 80);
    w.open();
    let cmd = w.command("bun test cart", "run-1");
    w.read();
    w.items.get_mut(&cmd).unwrap()["status"] = json!("completed");
    w.read();
    w.set(
        &tax,
        json!({"status": "completed", "result": "tests written", "completedAt": iso(w.now.get())}),
    );
    w.read();
    // Tax tests moved below Docs, in place.
    assert_eq!(
        w.order(),
        pairs(&[("Docs", "active"), ("Tax tests", "finished")])
    );
    assert_eq!(w.view.resets, 0);
    assert!(w.view.moves > 0);
    let _ = docs;
}

#[test]
fn elapsed_times_move_only_while_the_tab_shows() {
    let mut w = World::new();
    w.start("Tax tests", 12);
    w.open();
    assert_eq!(w.of("Tax tests", "elapsed"), "12s");
    assert!(w.agents.ticking());
    assert!(w.notes.contains(&Note::Ticking(true)));
    w.view.redrawn.clear();
    w.now.set(w.now.get() + Duration::seconds(1));
    w.agents.tick();
    w.follow();
    assert_eq!(w.redrawn("elapsed"), 1);
    assert_eq!(w.of("Tax tests", "elapsed"), "13s");
    w.notes.clear();
    w.agents.set_active(false);
    w.follow();
    assert!(!w.agents.ticking());
    assert_eq!(w.notes, vec![Note::Ticking(false), Note::Day(None)]);
    // Shown again, the times catch up at once.
    w.view.redrawn.clear();
    w.agents.set_active(true);
    w.follow();
    assert_eq!(w.redrawn("elapsed"), 1);
}

#[test]
fn the_tab_follows_a_subagent_as_it_finishes() {
    let mut w = World::new();
    let tax = w.start("Tax tests", 12);
    w.open();
    w.set(
        &tax,
        json!({"status": "completed", "progress": "writing tests", "result": "12 tests added",
               "completedAt": iso(w.now.get())}),
    );
    w.read();
    assert_eq!(w.of("Tax tests", "statusLabel"), "Completed");
    assert_eq!(w.of("Tax tests", "detail"), "12 tests added");
    assert!(!w.agents.ticking());
}

#[test]
fn the_commands_still_running_are_listed() {
    let mut w = World::new();
    let cmd = w.command("bun test cart", "run-1");
    w.open();
    assert_eq!(w.of("bun test cart", "kind"), "command");
    assert_eq!(w.of("bun test cart", "running"), "true");
    assert_eq!(w.of("bun test cart", "childThreadKey"), "");
    assert_eq!(w.of("bun test cart", "ended"), "");
    assert_eq!(w.agents.agent_count(), 0);
    w.items.get_mut(&cmd).unwrap()["status"] = json!("completed");
    w.read();
    assert_eq!(w.agents.count(), 0);
    assert!(!w.agents.ticking());
}

#[test]
fn a_rolled_back_runs_commands_are_not_running() {
    let mut w = World::new();
    w.command("bun test cart", "run-1");
    w.command("bun lint", "run-2");
    w.runs.insert(
        "run-1".into(),
        obj(json!({"id": "run-1", "status": "rolled_back"})),
    );
    w.open();
    assert_eq!(w.order(), pairs(&[("bun lint", "active")]));
}

#[test]
fn a_subagent_reads_its_status_and_what_it_came_to() {
    let mut w = World::new();
    let a = w.start("A", 50);
    let b = w.start("B", 40);
    let c = w.start("C", 30);
    let d = w.start("D", 20);
    w.set(
        &a,
        json!({"status": "idle", "title": "", "prompt": "  look around\nthen report  ",
                     "updatedAt": iso(w.now.get() - Duration::seconds(10))}),
    );
    w.set(
        &b,
        json!({"status": "failed", "title": "", "prompt": "",
                     "completedAt": iso(w.now.get() - Duration::seconds(5))}),
    );
    w.set(
        &c,
        json!({"status": "cancelled", "result": "Child task ended with status cancelled"}),
    );
    w.set(
        &d,
        json!({"status": "waiting", "progress": "reading files"}),
    );
    w.open();
    assert_eq!(w.of("look around", "statusLabel"), "Idle · resumable");
    assert_eq!(
        w.of("look around", "ended"),
        "Idle since 9:59 AM · resumable"
    );
    assert_eq!(w.of("look around", "elapsed"), "40s");
    assert_eq!(w.of("Subagent", "statusLabel"), "Failed");
    assert_eq!(w.of("Subagent", "ended"), "Failed at 9:59 AM");
    assert_eq!(w.of("C", "statusLabel"), "Stopped");
    assert_eq!(w.of("C", "detail"), "");
    assert_eq!(w.of("D", "statusLabel"), "Working");
    assert_eq!(w.of("D", "detail"), "reading files");
    assert_eq!(w.of("D", "section"), "active");
    assert_eq!(w.agents.index_of(&d), Some(0));
    assert_eq!(w.agents.index_of("nope"), None);
}

#[test]
fn without_a_timeline_the_tab_is_empty_and_says_no_end_times() {
    let mut w = World::new();
    let docs = w.start("Docs", 90);
    w.finish_after(&docs, 75);
    w.open();
    assert_eq!(w.agents.count(), 1);
    w.agents.read(None);
    w.follow();
    assert_eq!(w.agents.count(), 0);
    assert_eq!(w.agents.next_day(), None);
}

#[test]
fn elapsed_times_read_as_the_tab_shows_them() {
    assert_eq!(format_elapsed(-3), "0s");
    assert_eq!(format_elapsed(12), "12s");
    assert_eq!(format_elapsed(184), "3m 04s");
    assert_eq!(format_elapsed(3720), "1h 02m");
}

/// One thing that happens to a thread's work, or to the tab.
#[derive(Clone, Debug)]
enum Step {
    Start(u8),
    Settle(u8, &'static str),
    Command(u8),
    Finish(u8),
    RollBack,
    Active(bool),
    Tick,
    Later(i64),
    Format(bool),
    Midnight,
    Read,
}

fn step() -> impl Strategy<Value = Step> {
    let settled = prop_oneof![
        Just("completed"),
        Just("failed"),
        Just("idle"),
        Just("cancelled"),
        Just("running"),
    ];
    prop_oneof![
        4 => (0u8..6).prop_map(Step::Start),
        4 => ((0u8..6), settled).prop_map(|(n, s)| Step::Settle(n, s)),
        3 => (0u8..4).prop_map(Step::Command),
        3 => (0u8..4).prop_map(Step::Finish),
        1 => Just(Step::RollBack),
        2 => any::<bool>().prop_map(Step::Active),
        2 => Just(Step::Tick),
        2 => (1i64..50_000).prop_map(Step::Later),
        1 => any::<bool>().prop_map(Step::Format),
        1 => Just(Step::Midnight),
        2 => Just(Step::Read),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    /// However work starts and settles and the tab shows and hides, the
    /// view follows by row signals alone (never a reset), the active rows
    /// stay above the finished ones in their order, and the timers run
    /// exactly while they should.
    #[test]
    fn the_tab_keeps_its_rows_in_order_and_its_timers_honest(
        steps in prop::collection::vec(step(), 1..60)
    ) {
        let mut w = World::new();
        for step in steps {
            match step {
                Step::Start(n) => {
                    let title = format!("Agent {n}");
                    let id = format!("task-agent-{n}");
                    if !w.subagents.contains_key(&id) {
                        w.start(&title, 5);
                    }
                }
                Step::Settle(n, status) => {
                    let id = format!("task-agent-{n}");
                    if w.subagents.contains_key(&id) {
                        let done = iso(w.now.get());
                        w.set(&id, json!({"status": status, "completedAt": done, "updatedAt": done}));
                    }
                }
                Step::Command(n) => {
                    let run = if n % 2 == 0 { "run-1" } else { "run-2" };
                    w.command(&format!("cmd {n}"), run);
                }
                Step::Finish(n) => {
                    if let Some(item) = w.items.values_mut().find(|i| i["input"] == json!(format!("cmd {n}"))) {
                        item.insert("status".into(), json!("completed"));
                    }
                }
                Step::RollBack => {
                    w.runs.insert("run-2".into(), obj(json!({"id": "run-2", "status": "rolled_back"})));
                }
                Step::Active(on) => w.agents.set_active(on),
                Step::Tick => w.agents.tick(),
                Step::Later(s) => {
                    w.now.set(w.now.get() + Duration::seconds(s));
                    // The model's own timers fire as the time passes.
                    if w.agents.next_day().is_some_and(|next| next <= w.now.get()) {
                        w.agents.day_turned();
                    }
                    if w.agents.ticking() {
                        w.agents.tick();
                    }
                }
                Step::Format(h24) => {
                    w.format = if h24 { "24-hour" } else { "12-hour" }.into();
                    w.agents.set_timestamp_format(&w.format.clone());
                }
                Step::Midnight => w.agents.redraw_ended(),
                Step::Read => {}
            }
            // Every change to the work is told as agentsChanged.
            if !matches!(step, Step::Active(_) | Step::Tick | Step::Later(_) | Step::Format(_) | Step::Midnight) {
                w.read();
            } else if matches!(step, Step::Later(_)) && !w.agents.active() {
                // Hidden, its times stand still: the view holds what it
                // was last told, and reads anew once shown.
                w.notes.extend(w.agents.take_notes());
                w.view = Mirror::of(&mut w.agents);
            } else {
                w.follow();
            }
            prop_assert_eq!(w.view.resets, 0);
            let sections: Vec<String> = (0..w.agents.count()).map(|r| w.value(r, "section")).collect();
            let first_finished = sections.iter().position(|s| s == "finished").unwrap_or(sections.len());
            prop_assert!(sections[first_finished..].iter().all(|s| s == "finished"), "{}", w.describe());
            let running = (0..w.agents.count()).any(|r| w.value(r, "running") == "true");
            prop_assert_eq!(w.agents.ticking(), w.agents.active() && running);
            prop_assert_eq!(w.agents.next_day().is_some(), w.agents.active() && w.agents.count() > 0);
            if let Some(next) = w.agents.next_day() {
                prop_assert!(next > w.now.get());
            }
            // The timers the notes leave running are the core's.
            let ticking = w.notes.iter().rev().find_map(|n| match n { Note::Ticking(on) => Some(*on), _ => None });
            prop_assert_eq!(ticking.unwrap_or(false), w.agents.ticking());
            let day = w.notes.iter().rev().find_map(|n| match n { Note::Day(wait) => Some(wait.is_some()), _ => None });
            prop_assert_eq!(day.unwrap_or(false), w.agents.next_day().is_some());
        }
    }
}
