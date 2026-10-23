//! The timeline of one thread as the MC streams it, against a model of the
//! rows a user should see: desktop-qt's tst_TimelineModelProp.
//!
//! The model keeps the MC's thread (runs and turn items) and its log, and
//! what the client holds of it: its offset, its window's floor and whether
//! it is caught up. The fake MC in it answers the client's `sub` as
//! HalC2.Streams.Server does: a snapshot of the window when the copy is new
//! or of another log, else the log's events since the offset, then `live`;
//! pages of earlier runs; and every change to what the client holds while it
//! follows. Answers can be cut off part-way, events can come twice, and the
//! client can restart from its cache.
//!
//! After each step the rows equal the model's projection, a view kept only
//! by the row signals ([`Mirror`]) holds the same rows, every row whose
//! roles changed was redrawn for them, and no row that stayed the same was
//! redrawn.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::rc::Rc;

use proptest::prelude::*;
use serde_json::json;

use super::summary::{self, Obj};
use super::time::Clock;
use super::timeline::{Out, Role, Timeline, WINDOW_ITEMS};
use super::timeline_tests::{MemoryCache, Mirror, at, obj};
use crate::json::Json;

const KEY: &str = "env-1:thread-1";
/// The turn items a window or page of the fake MC holds at least (it rounds
/// up to whole runs), whatever the client asks for: small, so threads page.
const WINDOW: usize = 3;
const MAX_RUNS: usize = 5;
const MAX_ITEMS: usize = 16;
const AGENTS: [&str; 2] = ["agent-1", "agent-2"];
const STAMP: &str = "2026-09-23T10:00:00Z";

fn settled_status(status: &str) -> bool {
    matches!(status, "completed" | "failed" | "interrupted")
}

/// One of `values`, by a generated index.
fn pick<T: Clone>(values: &[T], at: usize) -> Option<T> {
    (!values.is_empty()).then(|| values[at % values.len()].clone())
}

// --- What a group of calls did ------------------------------------------------------

/// A tool call as a work group summarizes it.
#[derive(Clone, Debug, Default)]
struct Call {
    /// command_execution, file_change, file_search, web_search, todo_list,
    /// dynamic_tool or reasoning
    kind: String,
    /// completed, failed, declined or running
    status: String,
    exit_code: Option<i64>,
    /// A change's file, a search's pattern (and, read, its one result).
    file: String,
    read: bool,
    /// A tool's name: "Read" reads a file.
    tool: String,
}

fn call_json(call: &Call) -> Obj {
    let mut item = obj(json!({"type": call.kind, "status": call.status}));
    if let Some(code) = call.exit_code {
        item.insert("exitCode".into(), json!(code));
    }
    if call.kind == "file_change" && !call.file.is_empty() {
        item.insert("fileName".into(), json!(call.file));
    }
    if call.kind == "file_search" {
        item.insert("pattern".into(), json!(call.file));
        if call.read {
            item.insert("results".into(), json!([{"fileName": call.file}]));
        }
    }
    if call.kind == "dynamic_tool" {
        item.insert("toolName".into(), json!(call.tool));
    }
    item
}

fn call_strategy() -> impl Strategy<Value = Call> {
    let kind = prop_oneof![
        3 => Just("command_execution"),
        3 => Just("file_change"),
        2 => Just("file_search"),
        1 => Just("web_search"),
        1 => Just("todo_list"),
        2 => Just("dynamic_tool"),
        2 => Just("reasoning"),
    ];
    let status = prop_oneof![
        6 => Just("completed"),
        2 => Just("failed"),
        1 => Just("declined"),
        1 => Just("running"),
    ];
    (
        kind,
        status,
        any::<bool>(),
        0..3i64,
        0..3usize,
        any::<bool>(),
        any::<bool>(),
    )
        .prop_map(|(kind, status, coded, code, file, read, read_tool)| {
            let mut call = Call {
                kind: kind.into(),
                status: status.into(),
                ..Call::default()
            };
            if kind == "command_execution" && coded {
                call.exit_code = Some(code % 2);
            }
            if kind == "file_change" {
                call.file = ["", "a.cpp", "b.h"][file].into();
            }
            if kind == "file_search" {
                call.file = ["a.cpp", "b.h"][file % 2].into();
                call.read = read;
            }
            if kind == "dynamic_tool" {
                call.tool = if read_tool { "Read" } else { "lint" }.into();
            }
            call
        })
}

/// The kind of work a call was.
fn action_of(call: &Call) -> &'static str {
    match call.kind.as_str() {
        "command_execution" => "command",
        "file_change" => "edit",
        "file_search" if call.read => "read",
        "file_search" => "code-search",
        "web_search" => "search",
        "todo_list" => "update",
        _ if call.tool == "Read" => "read",
        _ => "other",
    }
}

fn label_of(action: &str, count: usize) -> String {
    let plural = |verb: &str, noun: &str| {
        format!("{verb} {count} {noun}{}", if count == 1 { "" } else { "s" })
    };
    match action {
        "command" => plural("Ran", "command"),
        "edit" => plural("Changed", "file"),
        "read" => plural("Read", "file"),
        "code-search" => plural("Searched code", "time"),
        "search" => plural("Searched the web", "time"),
        "update" => plural("Received", "update"),
        _ => plural("Used", "tool"),
    }
}

/// Calls that change something are named before reads and searches, and
/// those before tools and updates.
fn rank(action: &str) -> u8 {
    match action {
        "command" | "edit" => 0,
        "other" | "update" => 2,
        _ => 1,
    }
}

/// A fold of the calls: each kind of work by first appearance, the two that
/// rank first named (an edit by the files it touched), the rest counted;
/// thinking alone is "Thought"; failed when any call did.
fn expected_summary(all: &[Call]) -> summary::GroupSummary {
    let calls: Vec<&Call> = all.iter().filter(|c| c.kind != "reasoning").collect();
    if calls.is_empty() {
        let text = match all.len() {
            0 => String::new(),
            1 => "Thought".into(),
            n => format!("Thought (×{n})"),
        };
        return summary::GroupSummary {
            text,
            failed: false,
        };
    }
    let mut order: Vec<&str> = Vec::new();
    let mut counts: HashMap<&str, usize> = HashMap::new();
    let mut files: HashMap<&str, BTreeSet<&str>> = HashMap::new();
    let mut unnamed: HashMap<&str, usize> = HashMap::new();
    let mut failed = false;
    for call in &calls {
        let action = action_of(call);
        if !order.contains(&action) {
            order.push(action);
        }
        *counts.entry(action).or_default() += 1;
        if call.file.is_empty() {
            *unnamed.entry(action).or_default() += 1;
        } else {
            files.entry(action).or_default().insert(&call.file);
        }
        failed = failed
            || call.status == "failed"
            || call.status == "declined"
            || (call.kind == "command_execution" && call.exit_code.unwrap_or(0) != 0);
    }
    let mut named: Vec<&str> = Vec::new();
    for wanted in 0..=2 {
        for action in &order {
            if rank(action) == wanted && named.len() < 2 {
                named.push(action);
            }
        }
    }
    let mut labels: Vec<String> = Vec::new();
    let mut counted = 0;
    for action in &order {
        if !named.contains(action) {
            continue;
        }
        let amount = if *action == "edit" {
            files.get(action).map_or(0, BTreeSet::len) + unnamed.get(action).copied().unwrap_or(0)
        } else {
            counts[action]
        };
        let label = label_of(action, amount);
        labels.push(if labels.is_empty() {
            label
        } else {
            let mut chars = label.chars();
            let first = chars.next().map(|c| c.to_lowercase().to_string());
            first.unwrap_or_default() + chars.as_str()
        });
        counted += counts[action];
    }
    let rest = calls.len() - counted;
    if rest > 0 {
        labels.push(format!(
            "performed {rest} other action{}",
            if rest == 1 { "" } else { "s" }
        ));
    }
    let text = if labels.len() < 3 {
        labels.join(" and ")
    } else {
        format!(
            "{}, and {}",
            labels[..labels.len() - 1].join(", "),
            labels.last().unwrap()
        )
    };
    summary::GroupSummary { text, failed }
}

// --- The model ------------------------------------------------------------------------

#[derive(Clone, Debug, Default, PartialEq)]
struct Run {
    id: String,
    ordinal: i64,
    /// running, completed, failed, interrupted, rolled_back, queued or
    /// cancelled
    status: String,
    /// A queued run held for the user, numbered above the run that passed
    /// it.
    held: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
struct Item {
    id: String,
    /// user_message, assistant_message, command_execution, reasoning,
    /// proposed_plan, subagent, error or notification
    kind: String,
    run: String,
    ordinal: i64,
    /// What the row reads: a message's text, a call's output, a plan's
    /// markdown, a subagent's progress, an error's message.
    text: String,
    streaming: bool,
    status: String,
    /// A subagent's agent.
    agent: String,
    /// The message that started its run: the user's, or one the MC sent
    /// the agent for itself, a notification.
    opener: bool,
    /// A user_message a thread stored before the MC recorded those as
    /// notifications: "envelope", a delegated task's result as the agent
    /// reads it (its text is the task's title), or "wake", the provider
    /// waking itself.
    legacy: String,
}

#[derive(Clone, Debug, Default, PartialEq)]
struct Thread {
    runs: BTreeMap<String, Run>,
    items: BTreeMap<String, Item>,
    /// Each subagent's model, by agent id.
    agents: BTreeMap<String, String>,
}

impl Thread {
    fn run(&self, id: &str) -> Run {
        self.runs.get(id).cloned().unwrap_or_default()
    }
}

#[derive(Clone, Debug)]
struct Event {
    seq: i64,
    kind: String,
    id: String,
    patch: Json,
    /// The run of a turn item, for whether a window holds it.
    run: String,
}

#[derive(Clone, Debug)]
struct Model {
    // The MC's.
    mc: Thread,
    log: Vec<Event>,
    seq: i64,
    ordinal: i64,
    handle: i64,
    // The client's: what it holds, the offset and handle it holds them as
    // of, and its window's floor.
    held: Thread,
    offset: i64,
    held_handle: i64,
    floor: Option<i64>,
    /// Following the stream and caught up: changes reach it.
    live: bool,
    /// The last events frame it was sent.
    last_events: Option<Json>,
    /// What the user opened, by run and by work group row.
    folds_open: BTreeSet<String>,
    groups_toggled: BTreeSet<String>,
}

impl Default for Model {
    fn default() -> Self {
        Model {
            mc: Thread::default(),
            log: Vec::new(),
            seq: 0,
            ordinal: 0,
            handle: 1,
            held: Thread::default(),
            offset: -1,
            held_handle: 0,
            floor: None,
            live: false,
            last_events: None,
            folds_open: BTreeSet::new(),
            groups_toggled: BTreeSet::new(),
        }
    }
}

fn field(kind: &str) -> &'static str {
    match kind {
        "command_execution" => "output",
        "proposed_plan" => "markdown",
        "subagent" => "progress",
        "notification" => "summary",
        _ => "text",
    }
}

fn run_json(run: &Run) -> Json {
    let mut entity = json!({"id": run.id, "ordinal": run.ordinal, "status": run.status});
    if run.held {
        entity["queueHeld"] = json!(true);
    }
    entity
}

fn item_json(item: &Item) -> Json {
    let mut entity = json!({"id": item.id, "type": item.kind, "runId": item.run,
                            "ordinal": item.ordinal, "status": item.status,
                            "streaming": item.streaming});
    if item.kind == "error" {
        let mut failure = json!({"message": item.text});
        // A usage limit has its own text, "limit" here.
        if item.text == "limit" {
            failure["class"] = json!("usage_limit");
        }
        entity["failure"] = failure;
    } else if item.legacy == "envelope" {
        entity["createdBy"] = json!("system");
        entity["creationSource"] = json!("server");
        entity["text"] = json!(format!(
            "<delegated_task_result taskId=\"task:1\" title=\"{}\" status=\"failed\" childThreadId=\"thread:2\">\nno\n</delegated_task_result>",
            item.text
        ));
    } else if item.legacy == "wake" {
        entity["createdBy"] = json!("agent");
        entity["creationSource"] = json!("provider");
        entity["text"] = json!(item.text);
    } else {
        entity[field(&item.kind)] = json!(item.text);
    }
    if !item.agent.is_empty() {
        entity["subagentId"] = json!(item.agent);
    }
    entity
}

/// Whether a window from `floor` holds a turn item of `run`.
fn holds(thread: &Thread, run: &str, floor: Option<i64>) -> bool {
    floor.is_none_or(|floor| thread.run(run).ordinal >= floor)
}

/// What a client with the window from `floor` holds of `thread`.
fn window(thread: &Thread, floor: Option<i64>) -> Thread {
    Thread {
        runs: thread.runs.clone(),
        items: thread
            .items
            .iter()
            .filter(|(_, item)| holds(thread, &item.run, floor))
            .map(|(id, item)| (id.clone(), item.clone()))
            .collect(),
        agents: thread.agents.clone(),
    }
}

/// HalC2.Streams.View.take_runs: the runs before `before` (none: the
/// newest) that hold `count` turn items, and the floor once they are held
/// (none when no run is left before them).
fn take_runs(
    thread: &Thread,
    before: Option<i64>,
    count: usize,
) -> (BTreeSet<String>, Option<i64>) {
    let mut counts: HashMap<&str, usize> = HashMap::new();
    for item in thread.items.values() {
        *counts.entry(&item.run).or_default() += 1;
    }
    let mut runs: Vec<(i64, &str)> = thread
        .runs
        .values()
        .filter(|r| r.status != "rolled_back" && before.is_none_or(|b| r.ordinal < b))
        .map(|r| (r.ordinal, r.id.as_str()))
        .collect();
    runs.sort_by(|a, b| b.cmp(a));
    let mut taken = BTreeSet::new();
    let mut held = 0;
    for (i, (_, id)) in runs.iter().enumerate() {
        taken.insert((*id).to_owned());
        held += counts.get(id).copied().unwrap_or(0);
        if held >= count {
            return (taken, (i + 1 < runs.len()).then_some(runs[i].0));
        }
    }
    (taken, None)
}

// --- The rows a user should see ---------------------------------------------------------

#[derive(Clone, Debug, Default, PartialEq)]
struct Row {
    id: String,
    kind: String,
    title: String,
    text: String,
    streaming: bool,
    meta: bool,
    expanded: bool,
    hidden: i64,
    /// A work group's calls on screen.
    entries: Vec<String>,
    summarized: bool,
    /// What a summarized group did, and whether a call of it failed.
    summary: String,
    summary_failed: bool,
    agent_model: String,
}

/// What the MC sent the agent for itself shows as a marker naming it, not
/// as a message of the user's.
fn notice_of(item: &Item) -> String {
    match item.legacy.as_str() {
        "envelope" => return format!("{} failed", item.text),
        "wake" => return "Background activity updated".into(),
        _ => {}
    }
    if item.kind != "notification" {
        return String::new();
    }
    if item.text.is_empty() {
        "Notification".into()
    } else {
        item.text.clone()
    }
}

fn kind_of(item: &Item) -> &'static str {
    if !notice_of(item).is_empty() {
        return "marker";
    }
    match item.kind.as_str() {
        "user_message" | "assistant_message" => "message",
        "proposed_plan" => "plan",
        "subagent" => "subagent",
        "error" => "error",
        _ => "work",
    }
}

/// A settled turn folds its calls and commentary behind "Worked" ("You
/// stopped this response" for the latest, interrupted), leaving its last
/// reply and any call still running in view; while one of its replies
/// streams it stays open. Consecutive calls of a turn make one group, which
/// a settled turn with several calls summarizes; a group shows its latest
/// call until opened.
fn project(model: &Model) -> Vec<Row> {
    let thread = &model.held;
    let mut shown: Vec<&Item> = thread
        .items
        .values()
        .filter(|item| thread.run(&item.run).status != "rolled_back")
        .collect();
    shown.sort_by(|a, b| (a.ordinal, &a.id).cmp(&(b.ordinal, &b.id)));
    let mut latest: Option<&Run> = None;
    for run in thread.runs.values() {
        // Held for the user and never started: still queued, or cancelled
        // while held.
        if run.held && matches!(run.status.as_str(), "queued" | "cancelled") {
            continue;
        }
        // Runs are in the order they were made, so `>=` would give equal
        // ordinals to the newest made. The generators only ever make unique
        // ordinals, so no tie arises here; the timeline's tie-break is
        // later-starting (first item in timeline order), covered by
        // timeline_tests instead.
        if latest.is_none_or(|l| run.ordinal >= l.ordinal) {
            latest = Some(run);
        }
    }
    let latest = latest.map(|r| r.id.clone()).unwrap_or_default();

    let mut terminal: HashMap<&str, &str> = HashMap::new();
    let mut streaming: BTreeSet<&str> = BTreeSet::new();
    let mut first: HashMap<&str, &str> = HashMap::new();
    for item in &shown {
        if item.opener {
            continue;
        }
        first.entry(&item.run).or_insert(&item.id);
        if item.kind == "assistant_message" {
            terminal.insert(&item.run, &item.id);
            if item.streaming {
                streaming.insert(&item.run);
            }
        }
    }
    // By the item it goes above: (run, rows hidden).
    let mut fold_before: HashMap<&str, (&str, i64)> = HashMap::new();
    let mut folded: BTreeSet<&str> = BTreeSet::new();
    for run in thread.runs.values() {
        if !settled_status(&run.status) || streaming.contains(run.id.as_str()) {
            continue;
        }
        let Some(&above) = first.get(run.id.as_str()) else {
            continue;
        };
        let last_reply = terminal.get(run.id.as_str()).copied().unwrap_or("");
        let hidden: Vec<&str> = shown
            .iter()
            .filter(|item| item.run == run.id && !item.opener && item.id != last_reply)
            .filter(|item| {
                let kind = kind_of(item);
                (kind == "work" && item.status != "running") || kind == "message"
            })
            .map(|item| item.id.as_str())
            .collect();
        if hidden.is_empty() {
            continue;
        }
        fold_before.insert(above, (&run.id, hidden.len() as i64));
        if !model.folds_open.contains(&run.id) {
            folded.extend(hidden);
        }
    }

    let mut rows = Vec::new();
    let mut i = 0;
    while i < shown.len() {
        let item = shown[i];
        if let Some(&(run_id, hidden)) = fold_before.get(item.id.as_str()) {
            let run = thread.run(run_id);
            rows.push(Row {
                id: format!("fold:{run_id}"),
                kind: "fold".into(),
                title: if run.status == "interrupted" && run.id == latest {
                    "You stopped this response".into()
                } else {
                    "Worked".into()
                },
                hidden,
                expanded: model.folds_open.contains(run_id),
                ..Row::default()
            });
        }
        if folded.contains(item.id.as_str()) {
            i += 1;
            continue;
        }
        let kind = kind_of(item);
        if kind == "work" {
            let mut row = Row {
                id: format!("work:{}", item.id),
                kind: kind.into(),
                ..Row::default()
            };
            let mut calls: Vec<&Item> = Vec::new();
            while i < shown.len() {
                let call = shown[i];
                if !calls.is_empty() && fold_before.contains_key(call.id.as_str()) {
                    break;
                }
                if kind_of(call) != "work"
                    || folded.contains(call.id.as_str())
                    || call.run != item.run
                {
                    break;
                }
                calls.push(call);
                i += 1;
            }
            row.summarized = calls.len() > 1 && settled_status(&thread.run(&item.run).status);
            if row.summarized {
                let work: Vec<Call> = calls
                    .iter()
                    .map(|c| Call {
                        kind: c.kind.clone(),
                        status: c.status.clone(),
                        ..Call::default()
                    })
                    .collect();
                let summary = expected_summary(&work);
                row.summary = summary.text;
                row.summary_failed = summary.failed;
            }
            row.expanded = model.groups_toggled.contains(&row.id);
            let visible = usize::from(!row.summarized);
            row.hidden = (calls.len() - visible) as i64;
            let on_screen = if row.expanded {
                &calls[..]
            } else {
                &calls[calls.len() - visible..]
            };
            row.entries = on_screen.iter().map(|c| c.id.clone()).collect();
            rows.push(row);
            continue;
        }
        let mut row = Row {
            id: item.id.clone(),
            kind: kind.into(),
            text: if kind == "marker" {
                String::new()
            } else {
                item.text.clone()
            },
            streaming: item.streaming,
            ..Row::default()
        };
        match kind {
            "marker" => row.title = notice_of(item),
            "plan" => row.title = "Proposed plan".into(),
            "subagent" => {
                row.title = "Subagent".into();
                row.agent_model = thread.agents.get(&item.agent).cloned().unwrap_or_default();
            }
            "error" => {
                // A usage limit is one line naming the wait, with no body.
                let limit = item.text == "limit";
                row.title = if limit {
                    "Usage limit reached.".into()
                } else {
                    "Error".into()
                };
                if limit {
                    row.text.clear();
                }
            }
            _ => {}
        }
        if terminal.get(item.run.as_str()) == Some(&item.id.as_str()) {
            row.meta = !streaming.contains(item.run.as_str())
                && settled_status(&thread.run(&item.run).status);
        }
        rows.push(row);
        i += 1;
    }
    rows
}

// --- The client ---------------------------------------------------------------------------

struct Sut {
    cache: Rc<MemoryCache>,
    tl: Timeline,
    view: Mirror,
    /// Each row's roles when the step began, by id.
    before: HashMap<String, Vec<Json>>,
    earlier_wanted: usize,
}

impl Sut {
    fn new() -> Sut {
        let cache = Rc::new(MemoryCache::default());
        let tl = Sut::timeline(&cache);
        Sut {
            cache,
            tl,
            view: Mirror::default(),
            before: HashMap::new(),
            earlier_wanted: 0,
        }
    }

    fn timeline(cache: &Rc<MemoryCache>) -> Timeline {
        let mut tl = Timeline::new(KEY);
        tl.set_clock(Clock::fixed(at(STAMP)));
        tl.set_cache(Some(cache.clone()));
        tl
    }

    /// A new model on the same cache, as the app makes after a restart.
    fn make(&mut self) {
        self.tl = Sut::timeline(&self.cache);
        self.view = Mirror::default();
    }

    /// Hands what the timeline said to its view.
    fn drain(&mut self) {
        let out = self.tl.take_out();
        self.earlier_wanted += out
            .iter()
            .filter(|o| matches!(o, Out::EarlierWanted(_)))
            .count();
        self.view.apply(&out);
        let ids: Vec<&str> = (0..self.tl.row_count())
            .map(|r| self.tl.row_id(r).unwrap())
            .collect();
        assert_eq!(self.view.ids, ids, "the row signals keep the view in step");
    }

    fn send(&mut self, frame: &Json) {
        self.tl.receive(frame.as_object().expect("a frame"));
        self.drain();
    }

    fn roles(&self, row: usize) -> Vec<Json> {
        Role::ALL
            .iter()
            .map(|role| self.tl.data(row, *role).unwrap_or(Json::Null))
            .collect()
    }

    fn begin(&mut self) {
        self.drain();
        self.view.redrawn.clear();
        self.before = (0..self.tl.row_count())
            .map(|r| (self.tl.row_id(r).unwrap().to_owned(), self.roles(r)))
            .collect();
    }

    fn row(&self, at: usize) -> Row {
        let value = |role| self.tl.data(at, role).unwrap_or(Json::Null);
        let text = |role| value(role).as_str().unwrap_or_default().to_owned();
        let flag = |role| value(role).as_bool().unwrap_or(false);
        let summary = text(Role::Summary);
        Row {
            id: text(Role::Id),
            kind: text(Role::Kind),
            title: text(Role::Title),
            text: text(Role::Text),
            streaming: flag(Role::Streaming),
            meta: flag(Role::Meta),
            expanded: flag(Role::Expanded),
            hidden: value(Role::HiddenCount).as_i64().unwrap_or(0),
            entries: value(Role::Entries)
                .as_array()
                .map(|entries| {
                    entries
                        .iter()
                        .map(|e| e["id"].as_str().unwrap_or_default().to_owned())
                        .collect()
                })
                .unwrap_or_default(),
            summarized: !summary.is_empty(),
            summary,
            summary_failed: flag(Role::SummaryFailed),
            agent_model: text(Role::Model),
        }
    }

    /// The rows equal what `expected` says the user should see, and the
    /// step redrew exactly the rows that changed, for the roles that did.
    fn check(&mut self, expected: &Model) -> Result<(), TestCaseError> {
        self.drain();
        let want = project(expected);
        let rows: Vec<Row> = (0..self.tl.row_count()).map(|r| self.row(r)).collect();
        prop_assert_eq!(&rows, &want);
        prop_assert_eq!(self.tl.has_earlier(), expected.floor.is_some());
        prop_assert!(!self.tl.loading_earlier());
        let working = expected.held.runs.values().any(|r| r.status == "running");
        prop_assert_eq!(self.tl.working(), working);
        for row in 0..self.tl.row_count() {
            let id = self.tl.row_id(row).unwrap();
            let Some(was) = self.before.get(id) else {
                continue;
            };
            let now = self.roles(row);
            let changed: Vec<Role> = Role::ALL
                .iter()
                .zip(was.iter().zip(&now))
                .filter(|(_, (a, b))| a != b)
                .map(|(role, _)| *role)
                .collect();
            let redrawn: Vec<&Vec<Role>> = self
                .view
                .redrawn
                .iter()
                .filter(|(r, _)| r == id)
                .map(|(_, roles)| roles)
                .collect();
            if changed.is_empty() {
                prop_assert!(redrawn.is_empty(), "{id} redrawn unchanged: {redrawn:?}");
                continue;
            }
            let all = redrawn.iter().any(|roles| roles.is_empty());
            for role in changed {
                prop_assert!(
                    all || redrawn.iter().any(|roles| roles.contains(&role)),
                    "{id} changed {role:?} unredrawn: {redrawn:?}"
                );
            }
        }
        Ok(())
    }
}

// --- What the MC sends ------------------------------------------------------------------------

fn events_frame(events: &[Event], offset: i64) -> Json {
    let list: Vec<Json> = events
        .iter()
        .map(|e| json!([e.seq, e.kind, e.id, e.patch, STAMP]))
        .collect();
    json!({"t": "events", "offset": offset, "events": list})
}

/// The entity rows of `thread` a window from `floor` holds, or only the
/// turn items of `runs`.
fn entity_rows(thread: &Thread, floor: Option<i64>, runs: Option<&BTreeSet<String>>) -> Vec<Json> {
    let mut rows = Vec::new();
    if runs.is_none() {
        for run in thread.runs.values() {
            rows.push(json!(["run", run.id, run_json(run)]));
        }
        for (id, model) in &thread.agents {
            rows.push(json!(["subagent", id, {"id": id, "model": model}]));
        }
    }
    for item in thread.items.values() {
        let held = match runs {
            Some(runs) => runs.contains(&item.run),
            None => holds(thread, &item.run, floor),
        };
        if held {
            rows.push(json!(["turn-item", item.id, item_json(item)]));
        }
    }
    rows
}

/// Splits `rows` into `parts` frames' worth.
fn split(rows: Vec<Json>, parts: usize) -> Vec<Vec<Json>> {
    if parts <= 1 || rows.len() < 2 {
        return vec![rows];
    }
    let mut first = rows;
    let second = first.split_off(first.len() / 2);
    vec![first, second]
}

/// Changes to the MC's thread, sent to the client when it follows and holds
/// what they touch.
fn commit(model: &mut Model, events: Vec<Event>) {
    model.log.extend(events.iter().cloned());
    if !model.live {
        return;
    }
    let sent: Vec<Event> = events
        .into_iter()
        .filter(|e| e.kind != "turn-item" || holds(&model.mc, &e.run, model.floor))
        .collect();
    model.held = window(&model.mc, model.floor);
    // A commit that touches nothing the client holds is not sent
    // (HalC2.Streams.Server), so its offset stays.
    if sent.is_empty() {
        return;
    }
    model.offset = model.seq;
    model.last_events = Some(events_frame(&sent, model.seq));
}

fn event(model: &mut Model, kind: &str, id: &str, patch: Json, run: &str) -> Event {
    model.seq += 1;
    Event {
        seq: model.seq,
        kind: kind.into(),
        id: id.into(),
        patch,
        run: run.into(),
    }
}

/// The MC numbers runs in start order: a run that starts takes the ordinal
/// after every run that left the queue (a held run cancelled while held
/// left it too and keeps its number).
fn start_ordinal(model: &Model) -> i64 {
    model
        .mc
        .runs
        .values()
        .filter(|run| !(run.held && run.status == "queued"))
        .map(|run| run.ordinal)
        .max()
        .unwrap_or(0)
        + 1
}

/// The held runs still waiting move up behind the run that started at
/// `after`, each renumber a patch on a live run.
fn renumber_waiting(model: &mut Model, mut after: i64) -> Vec<Event> {
    let mut events = Vec::new();
    // Runs are keyed in the order they were made (run-1, run-2, ...).
    for id in held_waiting(model) {
        after += 1;
        let run = model.mc.runs.get_mut(&id).unwrap();
        if run.ordinal == after {
            continue;
        }
        run.ordinal = after;
        events.push(event(
            model,
            "run",
            &id,
            json!({"s": {"ordinal": after}}),
            "",
        ));
    }
    model.ordinal = model.ordinal.max(after);
    events
}

/// The queued runs held for the user, in the order they were made.
fn held_waiting(model: &Model) -> Vec<String> {
    model
        .mc
        .runs
        .values()
        .filter(|run| run.held && run.status == "queued")
        .map(|run| run.id.clone())
        .collect()
}

fn running(model: &Model) -> Vec<String> {
    model
        .mc
        .runs
        .values()
        .filter(|r| r.status == "running")
        .map(|r| r.id.clone())
        .collect()
}

fn items_where(model: &Model, keep: impl Fn(&Item) -> bool) -> Vec<String> {
    model
        .mc
        .items
        .values()
        .filter(|item| model.mc.run(&item.run).status == "running" && keep(item))
        .map(|item| item.id.clone())
        .collect()
}

fn streams(item: &Item) -> bool {
    match item.kind.as_str() {
        "assistant_message" => item.streaming,
        "command_execution" => item.status == "running",
        "reasoning" | "proposed_plan" | "subagent" => true,
        _ => false,
    }
}

// --- Commands ---------------------------------------------------------------------------------

#[derive(Clone, Debug)]
enum Action {
    /// A new turn: its run and the message that asked for it, in one
    /// frame. The message is the user's, or the MC's to the agent: a
    /// notification, or what a thread stored of one before the MC recorded
    /// them so.
    StartRun(&'static str),
    /// A queued message held for the user (it waited behind a stop) that a
    /// newer run passed: it waits, numbered above the runs that started,
    /// with nothing shown yet.
    Hold,
    /// The user cancels a held message instead of resuming the queue: the
    /// run keeps its hold and its number, and never started.
    CancelHeld(usize),
    /// The user resumes the queue and a held run starts: it takes the
    /// ordinal after every run that left the queue (a renumber patch on a
    /// live run), its hold clears, the runs still waiting move up behind it,
    /// and its message appears.
    ResumeHeld(usize),
    /// The agent starts a reply, a call, a plan, a subagent or an error in
    /// a running turn.
    AddItem {
        run: usize,
        kind: &'static str,
        agent: usize,
        limit: bool,
    },
    /// Streamed text (or output) appended to an item of a running turn.
    Delta { item: usize, chunk: &'static str },
    /// A reply finishes streaming, or a call ends.
    Finish { item: usize, failed: bool },
    /// The MC takes back an item of a running turn.
    DeleteItem(usize),
    /// A turn settles, in one frame with its replies finishing (before or
    /// after the run's status), or with them left streaming.
    Settle {
        run: usize,
        status: &'static str,
        finish: bool,
        finish_first: bool,
    },
    /// A settled turn rolled back (the user rewound past it): its rows go.
    RollBack(usize),
    /// The client (re)subscribes, answered in `parts` frames; `cut`: the
    /// connection drops after the first part.
    Subscribe { parts: usize, cut: bool },
    /// The connection drops; changes go on without the client.
    Drop,
    /// The MC restarts on a new log: offsets into the old one mean nothing.
    NewLog,
    /// The last events frame arrives again.
    Duplicate,
    /// The user scrolls to the top: the runs before the window come as a
    /// page, in `parts` frames; `cut`: the connection drops after the first.
    LoadEarlier { parts: usize, cut: bool },
    /// The user opens or closes a fold or a work group.
    Toggle(usize),
    /// The app restarts: the thread parks into the cache, and a new model
    /// restores it from there.
    Restart,
    /// A subagent's model is learned or changes (or is set again to the
    /// same).
    AgentModel { agent: usize, opus: bool },
}

fn action() -> impl Strategy<Value = Action> {
    let parts = || (1..=2usize, prop_oneof![4 => Just(false), 1 => Just(true)]);
    prop_oneof![
        1 => prop_oneof![
            4 => Just("user"),
            2 => Just("notification"),
            1 => Just("envelope"),
            1 => Just("wake"),
        ]
        .prop_map(Action::StartRun),
        1 => Just(Action::Hold),
        1 => any::<usize>().prop_map(Action::CancelHeld),
        1 => any::<usize>().prop_map(Action::ResumeHeld),
        2 => (
            any::<usize>(),
            prop_oneof![
                4 => Just("assistant_message"),
                4 => Just("command_execution"),
                2 => Just("reasoning"),
                1 => Just("proposed_plan"),
                1 => Just("subagent"),
                1 => Just("error"),
                1 => Just("notification"),
            ],
            any::<usize>(),
            any::<bool>(),
        )
            .prop_map(|(run, kind, agent, limit)| Action::AddItem { run, kind, agent, limit }),
        3 => (any::<usize>(), prop_oneof![Just("a"), Just("bc"), Just("d")])
            .prop_map(|(item, chunk)| Action::Delta { item, chunk }),
        2 => (any::<usize>(), any::<bool>()).prop_map(|(item, failed)| Action::Finish { item, failed }),
        1 => any::<usize>().prop_map(Action::DeleteItem),
        2 => (
            any::<usize>(),
            prop_oneof![Just("completed"), Just("failed"), Just("interrupted")],
            prop_oneof![4 => Just(true), 1 => Just(false)],
            any::<bool>(),
        )
            .prop_map(|(run, status, finish, finish_first)| Action::Settle {
                run,
                status,
                finish,
                finish_first
            }),
        1 => any::<usize>().prop_map(Action::RollBack),
        2 => parts().prop_map(|(parts, cut)| Action::Subscribe { parts, cut }),
        1 => Just(Action::Drop),
        1 => Just(Action::NewLog),
        1 => Just(Action::Duplicate),
        1 => parts().prop_map(|(parts, cut)| Action::LoadEarlier { parts, cut }),
        1 => any::<usize>().prop_map(Action::Toggle),
        1 => Just(Action::Restart),
        1 => (any::<usize>(), any::<bool>()).prop_map(|(agent, opus)| Action::AgentModel { agent, opus }),
    ]
}

/// A change to the MC's thread, made on the model; None when it cannot be
/// made now.
fn change(model: &mut Model, action: &Action) -> Option<()> {
    match action {
        Action::StartRun(how) => {
            if model.mc.runs.len() >= MAX_RUNS {
                return None;
            }
            // A run that passes a held queue is numbered below it: the held
            // runs are renumbered up behind it in the same commit, as the MC
            // does.
            let run = Run {
                id: format!("run-{}", model.mc.runs.len() + 1),
                ordinal: start_ordinal(model),
                status: "running".into(),
                held: false,
            };
            model.mc.runs.insert(run.id.clone(), run.clone());
            let mut events = vec![event(
                model,
                "run",
                &run.id,
                json!({"s": run_json(&run)}),
                "",
            )];
            events.extend(renumber_waiting(model, run.ordinal));
            model.ordinal += 1;
            let message = Item {
                id: format!("ask-{}", run.id),
                kind: if *how == "notification" {
                    "notification"
                } else {
                    "user_message"
                }
                .into(),
                run: run.id.clone(),
                ordinal: model.ordinal,
                text: "ask".into(),
                status: "completed".into(),
                opener: true,
                legacy: if matches!(*how, "envelope" | "wake") {
                    (*how).into()
                } else {
                    String::new()
                },
                ..Item::default()
            };
            model.mc.items.insert(message.id.clone(), message.clone());
            let e = event(
                model,
                "turn-item",
                &message.id,
                json!({"s": item_json(&message)}),
                &run.id,
            );
            events.push(e);
            commit(model, events);
        }
        Action::Hold => {
            if model.mc.runs.len() >= MAX_RUNS {
                return None;
            }
            model.ordinal += 1;
            let run = Run {
                id: format!("run-{}", model.mc.runs.len() + 1),
                ordinal: model.ordinal,
                status: "queued".into(),
                held: true,
            };
            model.mc.runs.insert(run.id.clone(), run.clone());
            let e = event(model, "run", &run.id, json!({"s": run_json(&run)}), "");
            commit(model, vec![e]);
        }
        Action::CancelHeld(run) => {
            let run = pick(&held_waiting(model), *run)?;
            model.mc.runs.get_mut(&run).unwrap().status = "cancelled".into();
            let e = event(
                model,
                "run",
                &run,
                json!({"s": {"status": "cancelled"}}),
                "",
            );
            commit(model, vec![e]);
        }
        Action::ResumeHeld(run) => {
            let run = pick(&held_waiting(model), *run)?;
            if model.mc.items.len() >= MAX_ITEMS {
                return None;
            }
            let ordinal = start_ordinal(model);
            let started = model.mc.runs.get_mut(&run).unwrap();
            started.ordinal = ordinal;
            started.status = "running".into();
            started.held = false;
            let mut events = vec![event(
                model,
                "run",
                &run,
                json!({"s": {"ordinal": ordinal, "status": "running", "queueHeld": false}}),
                "",
            )];
            events.extend(renumber_waiting(model, ordinal));
            model.ordinal += 1;
            let message = Item {
                id: format!("ask-{run}"),
                kind: "user_message".into(),
                run: run.clone(),
                ordinal: model.ordinal,
                text: "ask".into(),
                status: "completed".into(),
                opener: true,
                ..Item::default()
            };
            model.mc.items.insert(message.id.clone(), message.clone());
            let e = event(
                model,
                "turn-item",
                &message.id,
                json!({"s": item_json(&message)}),
                &run,
            );
            events.push(e);
            commit(model, events);
        }
        Action::AddItem {
            run,
            kind,
            agent,
            limit,
        } => {
            let run = pick(&running(model), *run)?;
            if model.mc.items.len() >= MAX_ITEMS {
                return None;
            }
            model.ordinal += 1;
            let limit = *kind == "error" && *limit;
            let item = Item {
                id: format!("{}-{}", &kind[..4], model.ordinal),
                kind: (*kind).into(),
                run: run.clone(),
                ordinal: model.ordinal,
                text: if *kind == "command_execution" {
                    String::new()
                } else if limit {
                    "limit".into()
                } else {
                    "t".into()
                },
                streaming: *kind == "assistant_message",
                status: if *kind == "command_execution" {
                    "running"
                } else {
                    "completed"
                }
                .into(),
                agent: if *kind == "subagent" {
                    pick(&AGENTS, *agent).unwrap().into()
                } else {
                    String::new()
                },
                ..Item::default()
            };
            model.mc.items.insert(item.id.clone(), item.clone());
            let e = event(
                model,
                "turn-item",
                &item.id,
                json!({"s": item_json(&item)}),
                &run,
            );
            commit(model, vec![e]);
        }
        Action::Delta { item, chunk } => {
            let id = pick(&items_where(model, streams), *item)?;
            let target = model.mc.items.get_mut(&id).unwrap();
            target.text.push_str(chunk);
            let (run, patch) = (
                target.run.clone(),
                json!({"a": {field(&target.kind): chunk}}),
            );
            let e = event(model, "turn-item", &id, patch, &run);
            commit(model, vec![e]);
        }
        Action::Finish { item, failed } => {
            let id = pick(
                &items_where(model, |i| i.streaming || i.status == "running"),
                *item,
            )?;
            let target = model.mc.items.get_mut(&id).unwrap();
            let set = if target.streaming {
                target.streaming = false;
                json!({"streaming": false})
            } else {
                target.status = if *failed { "failed" } else { "completed" }.into();
                json!({"status": target.status})
            };
            let run = target.run.clone();
            let e = event(model, "turn-item", &id, json!({"s": set}), &run);
            commit(model, vec![e]);
        }
        Action::DeleteItem(item) => {
            let id = pick(&items_where(model, |i| !i.opener), *item)?;
            let run = model.mc.items.remove(&id).unwrap().run;
            let e = event(model, "turn-item", &id, json!({"d": true}), &run);
            commit(model, vec![e]);
        }
        Action::Settle {
            run,
            status,
            finish,
            finish_first,
        } => {
            let run = pick(&running(model), *run)?;
            let mut events = Vec::new();
            let finish_replies = |model: &mut Model, events: &mut Vec<Event>| {
                if !finish {
                    return;
                }
                let streaming: Vec<String> = model
                    .mc
                    .items
                    .values()
                    .filter(|i| i.run == run && i.streaming)
                    .map(|i| i.id.clone())
                    .collect();
                for id in streaming {
                    model.mc.items.get_mut(&id).unwrap().streaming = false;
                    let e = event(
                        model,
                        "turn-item",
                        &id,
                        json!({"s": {"streaming": false}}),
                        &run,
                    );
                    events.push(e);
                }
            };
            if *finish_first {
                finish_replies(model, &mut events);
            }
            model.mc.runs.get_mut(&run).unwrap().status = (*status).into();
            let e = event(model, "run", &run, json!({"s": {"status": status}}), "");
            events.push(e);
            if !finish_first {
                finish_replies(model, &mut events);
            }
            commit(model, events);
        }
        Action::RollBack(run) => {
            let settled: Vec<String> = model
                .mc
                .runs
                .values()
                .filter(|r| settled_status(&r.status))
                .map(|r| r.id.clone())
                .collect();
            let run = pick(&settled, *run)?;
            model.mc.runs.get_mut(&run).unwrap().status = "rolled_back".into();
            let e = event(
                model,
                "run",
                &run,
                json!({"s": {"status": "rolled_back"}}),
                "",
            );
            commit(model, vec![e]);
        }
        Action::AgentModel { agent, opus } => {
            let agent = pick(&AGENTS, *agent).unwrap();
            let name = if *opus { "opus" } else { "sonnet" };
            model.mc.agents.insert(agent.into(), name.into());
            let e = event(
                model,
                "subagent",
                agent,
                json!({"s": {"id": agent, "model": name}}),
                "",
            );
            commit(model, vec![e]);
        }
        _ => return None,
    }
    Some(())
}

/// Runs one step on the client and the model; Ok(false) when it could not
/// be taken now.
fn step(model: &mut Model, sut: &mut Sut, action: &Action) -> Result<bool, TestCaseError> {
    match action {
        Action::StartRun(_)
        | Action::Hold
        | Action::CancelHeld(_)
        | Action::ResumeHeld(_)
        | Action::AddItem { .. }
        | Action::Delta { .. }
        | Action::Finish { .. }
        | Action::DeleteItem(_)
        | Action::Settle { .. }
        | Action::RollBack(_)
        | Action::AgentModel { .. } => {
            // The frame this change made, if any: one not sent leaves the
            // last one standing, as the model's own apply does.
            let mut sent = model.clone();
            sent.last_events = None;
            if change(&mut sent, action).is_none() {
                return Ok(false);
            }
            change(model, action);
            sut.begin();
            if sent.live
                && let Some(frame) = &sent.last_events
            {
                sut.send(frame);
            }
            sut.check(model)?;
        }
        Action::Subscribe { parts, cut } => {
            if model.live {
                return Ok(false);
            }
            let was = model.clone();
            let fresh = was.offset < 0 || was.held_handle != was.handle;
            if !cut {
                if fresh && was.offset < 0 {
                    model.floor = take_runs(&was.mc, None, WINDOW).1;
                }
                model.live = true;
                model.offset = was.seq;
                model.held_handle = was.handle;
                model.held = window(&model.mc, model.floor);
                model.last_events = None;
            }
            sut.begin();
            let sub = sut.tl.subscribing();
            // Where the copy stands, or the window to open with.
            if was.offset < 0 {
                prop_assert!(sub["offset"].is_null());
                prop_assert_eq!(sub["window"]["items"].as_i64(), Some(WINDOW_ITEMS));
            } else {
                prop_assert_eq!(sub["offset"].as_i64(), Some(was.offset));
                prop_assert_eq!(&sub["handle"], &json!(format!("log-{}", was.held_handle)));
                prop_assert_eq!(&sub["window"]["floor"], &json!(was.floor));
            }
            let handle = format!("log-{}", was.handle);
            let mut frames = Vec::new();
            if fresh {
                // A new copy opens with the newest runs; one of another log
                // keeps its window.
                let floor = if was.offset < 0 {
                    take_runs(&was.mc, None, WINDOW).1
                } else {
                    was.floor
                };
                let chunks = split(entity_rows(&was.mc, floor, None), *parts);
                let n = chunks.len();
                for (i, rows) in chunks.into_iter().enumerate() {
                    frames.push(json!({"t": "snapshot", "part": i, "rows": rows,
                                       "done": i + 1 == n, "offset": was.seq,
                                       "handle": handle, "floor": floor}));
                }
            } else {
                let missed: Vec<Event> = was
                    .log
                    .iter()
                    .filter(|e| e.seq > was.offset)
                    .filter(|e| e.kind != "turn-item" || holds(&was.mc, &e.run, was.floor))
                    .cloned()
                    .collect();
                // Parts before the last carry the offset the client is at;
                // the last the one they bring it to.
                if *parts > 1 && missed.len() > 1 {
                    let half = missed.len() / 2;
                    frames.push(events_frame(&missed[..half], was.offset));
                    frames.push(events_frame(&missed[half..], was.seq));
                } else if !missed.is_empty() {
                    frames.push(events_frame(&missed, was.seq));
                }
            }
            frames.push(json!({"t": "live", "offset": was.seq, "handle": handle}));
            if *cut {
                // Only a first part that is not the whole answer arrives.
                if frames.len() > 2 {
                    sut.send(&frames[0]);
                }
            } else {
                for frame in &frames {
                    sut.send(frame);
                }
                prop_assert_eq!(sut.tl.status(), "live");
                prop_assert_eq!(sut.tl.cursor().offset, model.offset);
            }
            sut.check(model)?;
        }
        Action::Drop | Action::NewLog => {
            if matches!(action, Action::Drop) && !model.live {
                return Ok(false);
            }
            model.live = false;
            model.last_events = None;
            if matches!(action, Action::NewLog) {
                model.handle += 1;
            }
            sut.begin();
            sut.check(model)?;
        }
        Action::Duplicate => {
            let Some(frame) = model.last_events.clone().filter(|_| model.live) else {
                return Ok(false);
            };
            sut.begin();
            sut.send(&frame);
            sut.check(model)?;
        }
        Action::LoadEarlier { parts, cut } => {
            if !model.live || model.floor.is_none() {
                return Ok(false);
            }
            let was = model.clone();
            if *cut {
                model.live = false;
                model.last_events = None;
            } else {
                // The page is taken at the log's head, as the window is
                // lowered (HalC2.Streams.Server): the client was sent every
                // change to its window before it, so its copy is whole as of
                // the page's offset, even past changes it was not sent.
                model.floor = take_runs(&was.mc, was.floor, WINDOW).1;
                model.held = window(&model.mc, model.floor);
                model.offset = was.seq;
            }
            sut.begin();
            sut.earlier_wanted = 0;
            sut.tl.load_earlier();
            sut.drain();
            prop_assert_eq!(sut.earlier_wanted, 1);
            prop_assert!(sut.tl.loading_earlier());
            // Asked again while it comes, it is not asked for twice.
            sut.tl.load_earlier();
            sut.drain();
            prop_assert_eq!(sut.earlier_wanted, 1);
            let (runs, floor) = take_runs(&was.mc, was.floor, WINDOW);
            let chunks = split(entity_rows(&was.mc, None, Some(&runs)), *parts);
            let n = chunks.len();
            for (i, rows) in chunks.into_iter().enumerate() {
                // Cut off, only a first part that is not the whole page
                // arrives.
                if *cut && i + 1 == n {
                    break;
                }
                sut.send(&json!({"t": "page", "rows": rows, "done": i + 1 == n,
                                 "offset": was.seq, "floor": floor}));
            }
            if *cut {
                // ThreadStore says it is no longer live; a page cut off is
                // dropped with the subscription.
                sut.tl.set_status("unreachable", "");
                sut.tl.set_status("loading", "");
            }
            sut.check(model)?;
        }
        Action::Toggle(at) => {
            let ids: Vec<String> = project(model)
                .into_iter()
                .filter(|r| r.kind == "fold" || r.kind == "work")
                .map(|r| r.id)
                .collect();
            let Some(row) = pick(&ids, *at) else {
                return Ok(false);
            };
            match row.strip_prefix("fold:") {
                Some(run) => toggle_in(&mut model.folds_open, run),
                None => toggle_in(&mut model.groups_toggled, &row),
            }
            sut.begin();
            sut.tl.toggle(&row);
            sut.check(model)?;
        }
        Action::Restart => {
            model.live = false;
            model.last_events = None;
            model.folds_open.clear();
            model.groups_toggled.clear();
            if model.offset < 0 {
                model.held = Thread::default();
            }
            sut.tl.park();
            sut.make();
            let kept = sut.cache.load(KEY);
            sut.begin();
            sut.tl.restore(&kept);
            sut.drain();
            prop_assert_eq!(sut.tl.cursor().offset, model.offset);
            sut.check(model)?;
        }
    }
    Ok(true)
}

fn toggle_in(set: &mut BTreeSet<String>, key: &str) {
    if !set.remove(key) {
        set.insert(key.to_owned());
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 512, ..ProptestConfig::default() })]

    /// The rows are the MC's thread as the client holds it, redrawn only
    /// where they changed.
    #[test]
    fn the_rows_follow_the_stream(actions in prop::collection::vec(action(), 1..60)) {
        let mut model = Model::default();
        let mut sut = Sut::new();
        for action in &actions {
            step(&mut model, &mut sut, action)?;
        }
    }

    /// A group's summary is a fold of its calls.
    #[test]
    fn a_groups_summary_is_a_fold_of_its_calls(calls in prop::collection::vec(call_strategy(), 0..9)) {
        let items: Vec<Obj> = calls.iter().map(call_json).collect();
        let want = expected_summary(&calls);
        let got = summary::summarize(&items);
        prop_assert_eq!(got.text, want.text);
        prop_assert_eq!(got.failed, want.failed);
    }
}
