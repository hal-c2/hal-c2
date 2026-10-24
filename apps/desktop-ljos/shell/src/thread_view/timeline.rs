//! One thread's timeline (desktop-qt's TimelineModel): the MC's `stream`
//! shape folded into its entities and projected into rows, as
//! apps/tui/src/timeline.ts does.
//!
//! Rows are messages, groups of consecutive tool calls (the latest shown,
//! the rest behind "+N previous tool calls"), folds of settled turns
//! ("Worked for 2m"), plan cards, subagents, errors and context markers.
//! Each row keeps its id across updates. Streamed text and output only
//! touch the row that shows the item ([`Out::DataChanged`]); new items,
//! visibility and run changes derive the row list again and apply it as
//! removes, inserts and moves.
//!
//! The timeline owns where its copy of the thread stands ([`Cursor`]): the
//! MC log it follows, the offset it reflects and the window it holds. A
//! thread opens as its newest turns ([`WINDOW_ITEMS`]); `load_earlier`
//! adds the ones before. Every frame leaves the copy whole as of its
//! offset, and what changed goes to the [`ThreadCache`] with that offset,
//! so a thread opened again is restored and sent only what it lacks.
//!
//! This is the model without Qt or Ljós: what it would signal goes to
//! [`Timeline::take_out`], in order. `timeline_model` is the QML object
//! over it.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::rc::Rc;
use std::sync::LazyLock;

use chrono::{DateTime, Utc};
use regex::Regex;

use super::cache::{self, Cursor, ThreadCache};
use super::file_render::extension_of;
use super::summary::{self, Obj, as_object, flag, object, text};
use super::time::{self, Clock};
use crate::controllers::composer::text::data_size;
use crate::json::Json;

/// Calls shown per collapsed work group.
pub const VISIBLE_WORK_ENTRIES: usize = 1;
/// The turn items a thread opens with, and that each load of earlier turns
/// adds; the MC rounds both up to whole runs.
pub const WINDOW_ITEMS: i64 = 200;
/// How long changes wait for more before they go to the cache.
pub const FLUSH_DELAY_MS: i32 = 500;

/// The entity kinds the timeline reads; the stream's others (nodes,
/// provider sessions, ...) are left out. Plans and the user's messages are
/// kept for the composer (turnChanged), checkpoints for the diff panel
/// (checkpointsChanged) and a reply's revert (checkpointOf), subagents for
/// the Agents tab (agentsChanged); they draw no rows.
pub const KINDS: [&str; 8] = [
    "turn-item",
    "run",
    "run-attempt",
    "runtime-request",
    "plan",
    "message",
    "checkpoint",
    "subagent",
];
/// The kinds a window bounds (HalC2.Streams.View): the client holds those
/// of the runs from its floor on. The rest are held whole.
const WINDOWED: [&str; 2] = ["turn-item", "message"];
/// Turn items the composer's turn state reads (requests).
const TURN_ITEMS: [&str; 2] = ["approval_request", "user_input_request"];
/// Turn item fields that move, regroup or refold rows. Anything else
/// (text, output, status) only redraws the row showing the item.
const STRUCTURAL: [&str; 6] = [
    "type",
    "runId",
    "ordinal",
    "streaming",
    "inputIntent",
    "nodeId",
];
const SETTLED: [&str; 4] = ["completed", "failed", "interrupted", "cancelled"];
const RUNNING: [&str; 4] = ["preparing", "starting", "running", "waiting"];

static NONE: LazyLock<Obj> = LazyLock::new(Obj::new);
static NO_ENTITIES: LazyLock<BTreeMap<String, Obj>> = LazyLock::new(BTreeMap::new);

/// A row's roles, as QML names them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Role {
    Id,
    /// message, work, fold, plan, subagent, error or marker
    Kind,
    /// A message's: user or assistant.
    Author,
    /// A message's text, a plan's markdown under its title, an error's
    /// message, a marker's or subagent's detail.
    Text,
    Streaming,
    /// A fold's, plan's, marker's or subagent's heading.
    Title,
    Status,
    /// What the row's status reads as ("Working", "Failed", ...).
    StatusLabel,
    /// How a user message reached the agent, when not as a new turn.
    Marker,
    /// A work group's calls on screen: [{id, type, label, detail, command,
    /// status, statusLabel, exitCode, path, icon, time}].
    Entries,
    /// A work group's calls behind "+N previous tool calls", a fold's rows.
    HiddenCount,
    Expanded,
    /// The files an assistant reply's turn changed: [{path, additions,
    /// deletions}].
    Files,
    /// When the row happened, in the device's timestampFormat.
    Time,
    /// The lucide icon of a marker, error or subagent row.
    Icon,
    /// A user message's inputIntent.
    Intent,
    /// Who sent a user message when not the user.
    Attribution,
    /// Whether an assistant reply carries its time and actions.
    Meta,
    /// What a settled turn's group of calls did, in a sentence.
    Summary,
    /// Whether a call the group's summary counts failed.
    SummaryFailed,
    /// The id of the thread a row leads to.
    Thread,
    /// The model a subagent runs on.
    Model,
    /// The first pull (or merge) request address a message mentions.
    PullRequestUrl,
    /// An assistant reply's message.
    MessageId,
    /// A user message's images: [{id, name, url}].
    Attachments,
    /// A user message's other attachments, listed by name: [{id, name,
    /// detail}]. `detail` is a file's kind and size ("PDF · 2.0 MiB"), empty
    /// for a kind this client does not know.
    SentFiles,
    /// Whether an error row is a wait rather than a failure.
    Warning,
}

impl Role {
    pub const ALL: [Role; 27] = [
        Role::Id,
        Role::Kind,
        Role::Author,
        Role::Text,
        Role::Streaming,
        Role::Title,
        Role::Status,
        Role::StatusLabel,
        Role::Marker,
        Role::Entries,
        Role::HiddenCount,
        Role::Expanded,
        Role::Files,
        Role::Time,
        Role::Icon,
        Role::Intent,
        Role::Attribution,
        Role::Meta,
        Role::Summary,
        Role::SummaryFailed,
        Role::Thread,
        Role::Model,
        Role::PullRequestUrl,
        Role::MessageId,
        Role::Attachments,
        Role::SentFiles,
        Role::Warning,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Role::Id => "rowId",
            Role::Kind => "kind",
            Role::Author => "author",
            Role::Text => "text",
            Role::Streaming => "streaming",
            Role::Title => "title",
            Role::Status => "status",
            Role::StatusLabel => "statusLabel",
            Role::Marker => "marker",
            Role::Entries => "entries",
            Role::HiddenCount => "hiddenCount",
            Role::Expanded => "expanded",
            Role::Files => "files",
            Role::Time => "time",
            Role::Icon => "icon",
            Role::Intent => "intent",
            Role::Attribution => "attribution",
            Role::Meta => "meta",
            Role::Summary => "summary",
            Role::SummaryFailed => "summaryFailed",
            Role::Thread => "thread",
            Role::Model => "agentModel",
            Role::PullRequestUrl => "pullRequestUrl",
            Role::MessageId => "messageId",
            Role::Attachments => "attachments",
            Role::SentFiles => "sentFiles",
            Role::Warning => "warning",
        }
    }

    pub fn from_name(name: &str) -> Option<Role> {
        Role::ALL.into_iter().find(|r| r.name() == name)
    }
}

/// What the timeline tells its views and its owner, in order: desktop-qt's
/// row signals and the model's own.
#[derive(Clone, Debug, PartialEq)]
pub enum Out {
    /// The `count` rows from `first` went.
    Removed {
        first: usize,
        count: usize,
    },
    /// Rows with these ids now start at `first`.
    Inserted {
        first: usize,
        ids: Vec<String>,
    },
    /// The row at `from` is now at `to` (`to < from`).
    Moved {
        from: usize,
        to: usize,
    },
    /// Rows `first..=last` read differently in `roles` (none: any).
    DataChanged {
        first: usize,
        last: usize,
        roles: Vec<Role>,
    },
    CountChanged,
    StatusChanged,
    WorkingChanged,
    /// After a snapshot, or events that touched runs, requests, plans or
    /// the request and user message items: what `entities()` gives the
    /// composer.
    TurnChanged,
    /// After a snapshot, or events that touched checkpoints.
    CheckpointsChanged,
    /// After a snapshot, or events that touched subagents, runs or
    /// commands starting and settling.
    AgentsChanged,
    /// After a snapshot, or a command or file change starting or settling.
    WorkspaceChanged,
    /// After the time format changed: stamps read differently.
    TimesChanged,
    EarlierChanged,
    /// An image on screen has no address yet (`load_attachment`).
    AttachmentWanted(String),
    /// `load_earlier`: the runs before the window holding this many turn
    /// items are wanted.
    EarlierWanted(i64),
    /// Start (true) or stop the flush timer: `flush` once it fires, after
    /// [`FLUSH_DELAY_MS`].
    FlushTimer(bool),
}

#[derive(Clone, Debug, Default, PartialEq)]
struct Row {
    id: String,
    kind: &'static str,
    /// The turn items it shows, oldest first: a message's one, a group's
    /// calls.
    items: Vec<String>,
    /// A reply's: the checkpoint item whose files it lists.
    checkpoint: String,
    /// A fold's.
    label: String,
    hidden: usize,
    expanded: bool,
    /// A fold's: when its turn started.
    at: Option<DateTime<Utc>>,
    /// A reply's: whether it is its settled turn's last.
    meta: bool,
    /// A work group's: its turn settled and it has several calls, so it
    /// collapses into its summary.
    summarized: bool,
    /// A work group's: its run was stopped here, so it starts open.
    starts_open: bool,
}

/// An image's signed address; no `expires_at` while it is asked for.
#[derive(Clone, Debug, Default)]
struct AttachmentUrl {
    url: String,
    expires_at: Option<DateTime<Utc>>,
}

type Entities = BTreeMap<String, BTreeMap<String, Obj>>;

/// Names another thread of this one's environment by id; empty when it is
/// not known.
pub type ThreadTitles = Rc<dyn Fn(&str) -> String>;
/// Where the thread works (its worktree, else its project's root); empty
/// when it is not known.
pub type WorkspaceRoot = Rc<dyn Fn() -> String>;

/// One thread's timeline. See the module.
pub struct Timeline {
    thread_key: String,
    status: String,
    problem: String,
    entities: Entities,
    /// A snapshot arriving in parts.
    incoming: Entities,
    /// Turn item ids by (ordinal, id).
    order: Vec<String>,
    rows: Vec<Row>,
    row_of_item: HashMap<String, usize>,
    /// The turn items of the events being applied that changed in more
    /// than streamed text.
    reshaped: HashSet<String>,
    /// Run ids.
    expanded_folds: HashSet<String>,
    /// Work groups the user toggled, by row id: open ones, or closed ones
    /// of a run stopped here (`Row::starts_open`).
    expanded_groups: HashSet<String>,
    kept_open: HashSet<String>,
    attachment_urls: HashMap<String, AttachmentUrl>,
    working_since: Option<DateTime<Utc>>,
    turn_touched: bool,
    checkpoints_touched: bool,
    agents_touched: bool,
    workspace_touched: bool,
    /// The subagents the events being applied touch, each as it was before
    /// them.
    agent_models: HashMap<String, Obj>,
    clock: Clock,
    thread_titles: Option<ThreadTitles>,
    workspace_root: Option<WorkspaceRoot>,
    timestamp_format: String,
    cursor: Cursor,
    /// Between a `sub` frame and the `live` that answers it.
    catching_up: bool,
    /// `events` frames of a catch-up whose last part has not come: its
    /// parts only make sense together, so none is applied before it.
    catch_up: Vec<Vec<Json>>,
    /// The rows of a page whose last part has not come.
    page: Vec<Vec<Json>>,
    loading_earlier: bool,
    cache: Option<Rc<dyn ThreadCache>>,
    /// What the cache has not been handed: entities by (kind, id),
    /// everything after a snapshot, or the cursor alone.
    dirty: BTreeSet<(String, String)>,
    dirty_all: bool,
    cursor_dirty: bool,
    flush_armed: bool,
    out: Vec<Out>,
}

impl std::fmt::Debug for Timeline {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Timeline")
            .field("thread_key", &self.thread_key)
            .field("status", &self.status)
            .field("rows", &self.rows.len())
            .field("cursor", &self.cursor)
            .finish_non_exhaustive()
    }
}

// --- Reading entities ---------------------------------------------------------------

/// A number field, or 0 (QJsonValue::toDouble).
fn number(obj: &Obj, field: &str) -> f64 {
    obj.get(field).and_then(Json::as_f64).unwrap_or(0.0)
}

fn is_number(value: Option<&Json>) -> bool {
    matches!(value, Some(Json::Number(_)))
}

/// A whole number field, or 0 (QJsonValue::toInt).
fn int(obj: &Obj, field: &str) -> i64 {
    match obj.get(field) {
        Some(Json::Number(n)) => n.as_i64().unwrap_or_else(|| {
            let f = n.as_f64().unwrap_or(0.0);
            if f.fract() == 0.0 && f.abs() < i32::MAX as f64 {
                f as i64
            } else {
                0
            }
        }),
        _ => 0,
    }
}

fn array<'a>(obj: &'a Obj, field: &str) -> &'a [Json] {
    obj.get(field)
        .and_then(Json::as_array)
        .map_or(&[], Vec::as_slice)
}

/// A frame field as an offset: a number, else none.
fn offset_of(frame: &Obj, field: &str) -> Option<i64> {
    frame.get(field).and_then(Json::as_f64).map(|v| v as i64)
}

fn settled(status: &str) -> bool {
    SETTLED.contains(&status)
}

/// HalC2.Patch: `s` sets, `u` unsets, `a` appends to strings, `d` deletes
/// (alone) or replaces (with `s`/`a`). None when the entity is gone.
pub fn patched(entity: Option<&Obj>, patch: &Obj) -> Option<Obj> {
    let replace = flag(patch, "d");
    if replace && !patch.contains_key("s") && !patch.contains_key("a") {
        return None;
    }
    let mut next = if replace {
        Obj::new()
    } else {
        entity.cloned().unwrap_or_default()
    };
    for (field, value) in object(patch, "s") {
        next.insert(field.clone(), value.clone());
    }
    for field in array(patch, "u") {
        next.remove(field.as_str().unwrap_or(""));
    }
    for (field, value) in object(patch, "a") {
        let grown = format!("{}{}", text(&next, field), value.as_str().unwrap_or(""));
        next.insert(field.clone(), Json::String(grown));
    }
    Some(next)
}

fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).expect("a valid pattern")
}

/// When a turn item happened: its start, else its last update.
fn item_time(item: &Obj, clock: &Clock) -> Option<DateTime<Utc>> {
    time::time_of(item.get("startedAt"), clock.zone)
        .or_else(|| time::time_of(item.get("updatedAt"), clock.zone))
}

/// A changed file as the row labels it: relative to the workspace, when it
/// is inside it.
fn workspace_path(path: &str, root: &str) -> String {
    let mut base = root;
    while base.len() > 1 && base.ends_with('/') {
        base = &base[..base.len() - 1];
    }
    if base.is_empty() || base == "/" {
        return path.to_owned();
    }
    match path
        .strip_prefix(base)
        .and_then(|rest| rest.strip_prefix('/'))
    {
        Some(inside) => inside.to_owned(),
        None => path.to_owned(),
    }
}

/// A thought as its row labels it: the words of its Markdown on one line,
/// which the row elides. Only its start is read, and the lines are kept: a
/// row asks for its labels again each time it redraws.
pub fn thought_line(thought: &str) -> String {
    use pulldown_cmark::{Event, Options, Parser, TagEnd};
    static SPACE: LazyLock<Regex> = LazyLock::new(|| regex(r"\s+"));
    thread_local! {
        static LINES: RefCell<HashMap<String, String>> = RefCell::new(HashMap::new());
    }
    let start: String = thought.chars().take(600).collect();
    if let Some(kept) = LINES.with(|lines| lines.borrow().get(&start).cloned()) {
        return kept;
    }
    // QTextDocument's markdown as plain text: each block's text (an
    // image's alt text) and a space after it.
    let mut line = String::new();
    let options =
        Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    for event in Parser::new_ext(&start, options) {
        match event {
            Event::Text(t) | Event::Code(t) => line.push_str(&t),
            Event::SoftBreak | Event::HardBreak => line.push(' '),
            Event::End(
                TagEnd::Paragraph
                | TagEnd::Heading(_)
                | TagEnd::CodeBlock
                | TagEnd::Item
                | TagEnd::TableCell
                | TagEnd::HtmlBlock,
            )
            | Event::Rule => line.push(' '),
            _ => {}
        }
    }
    let line: String = SPACE
        .replace_all(&line, " ")
        .trim()
        .chars()
        .take(200)
        .collect();
    LINES.with(|lines| {
        let mut lines = lines.borrow_mut();
        // QCache's 256; all go at once rather than the least used.
        if lines.len() >= 256 {
            lines.clear();
        }
        lines.insert(start, line.clone());
    });
    line
}

/// The icon of a turn item the timeline shows as a call or a row.
fn icon_of(item: &Obj) -> &'static str {
    match text(item, "type") {
        "command_execution" => return "terminal",
        "file_change" => return "square-pen",
        _ => {}
    }
    if summary::is_file_read(item) {
        return "eye";
    }
    match text(item, "type") {
        "file_search" => return "search",
        "web_search" => return "globe",
        "dynamic_tool" => return "wrench",
        "reasoning" => return "brain",
        "approval_request" | "user_input_request" => return "message-circle",
        "subagent" => return "bot",
        "error" => return "circle-alert",
        _ => {}
    }
    if let Some(notice) = summary::notice_of(item) {
        return if notice.outcome == "failed" {
            "circle-alert"
        } else {
            "zap"
        };
    }
    // V2LifecycleRow's dividers and interrupt request; the info tone.
    match text(item, "type") {
        "compaction" => "minus",
        "fork" => "git-fork",
        "handoff" => "arrow-right-left",
        "thread_created" => "message-square",
        "run_interrupt_request" => "square",
        "run_interrupt_result" => "x",
        _ => "check",
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Message,
    Work,
    Plan,
    Subagent,
    Error,
    Marker,
    Checkpoint,
}

fn classify(item: &Obj) -> Kind {
    if summary::notice_of(item).is_some() {
        return Kind::Marker;
    }
    match text(item, "type") {
        "user_message" | "assistant_message" => Kind::Message,
        "proposed_plan" => Kind::Plan,
        "subagent" => Kind::Subagent,
        "error" => Kind::Error,
        "checkpoint" => Kind::Checkpoint,
        "fork" | "handoff" | "compaction" | "thread_created" => Kind::Marker,
        _ => Kind::Work,
    }
}

fn kind_name(kind: Kind) -> &'static str {
    match kind {
        Kind::Message => "message",
        Kind::Work => "work",
        Kind::Plan => "plan",
        Kind::Subagent => "subagent",
        Kind::Error => "error",
        Kind::Marker | Kind::Checkpoint => "marker",
    }
}

/// apps/tui/src/worklog.ts: how a tool call ended; empty once it completed.
fn call_status_label(status: &str) -> &'static str {
    match status {
        "failed" => "Failed",
        "cancelled" | "interrupted" => "Stopped",
        "completed" => "",
        _ => "Running",
    }
}

fn subagent_status_label(status: &str) -> &'static str {
    match status {
        "idle" => "Idle · resumable",
        "completed" => "Completed",
        "failed" => "Failed",
        "cancelled" | "interrupted" => "Stopped",
        _ => "Working",
    }
}

fn intent_marker(intent: &str) -> &'static str {
    match intent {
        "queued_turn" => "Queued behind the active turn",
        "steer" => "Steered the active turn",
        "promoted_queued_to_steer" => "Originally queued, then promoted to steer the active turn",
        _ => "",
    }
}

/// apps/tui/src/proposedPlan.ts: the first heading, else "Proposed plan".
pub fn plan_title(markdown: &str) -> String {
    static HEADING: LazyLock<Regex> = LazyLock::new(|| regex(r"(?m)^\s{0,3}#{1,6}\s+(.+)$"));
    let title = HEADING
        .captures(markdown)
        .and_then(|c| c.get(1))
        .map_or("", |m| m.as_str().trim());
    if title.is_empty() {
        "Proposed plan".into()
    } else {
        title.to_owned()
    }
}

/// The plan's markdown without the heading it opens with (the card's
/// title) or a "Summary" heading after it.
pub fn plan_body(markdown: &str) -> String {
    static HEADING: LazyLock<Regex> = LazyLock::new(|| regex(r"^\s{0,3}#{1,6}\s+(.+)$"));
    static LINES: LazyLock<Regex> = LazyLock::new(|| regex(r"\r?\n"));
    let mut lines: Vec<&str> = LINES.split(markdown.trim_end()).collect();
    let mut at = 0;
    let drop_blank = |at: &mut usize, lines: &[&str]| {
        while *at < lines.len() && lines[*at].trim().is_empty() {
            *at += 1;
        }
    };
    if !lines.is_empty() && HEADING.is_match(lines[0]) {
        at = 1;
    }
    drop_blank(&mut at, &lines);
    let summary_heading = lines
        .get(at)
        .and_then(|line| HEADING.captures(line))
        .is_some_and(|c| {
            c.get(1)
                .is_some_and(|m| m.as_str().trim().eq_ignore_ascii_case("summary"))
        });
    if summary_heading {
        at += 1;
        drop_blank(&mut at, &lines);
    }
    lines.drain(..at);
    lines.join("\n")
}

fn marker_title(item: &Obj) -> String {
    match text(item, "type") {
        "fork" => "Conversation fork".into(),
        "handoff" => "Context handoff".into(),
        "compaction" => "Context compacted".into(),
        "thread_created" => "Created thread".into(),
        // A notification's work row is its summary alone.
        _ => match summary::notice_of(item) {
            Some(notice) if !notice.summary.is_empty() => notice.summary,
            _ => "Notification".into(),
        },
    }
}

fn marker_detail(item: &Obj) -> String {
    match text(item, "type") {
        "fork" => format!("Continues in {}", text(item, "targetThreadId")),
        "thread_created" => text(item, "title").to_owned(),
        _ => String::new(),
    }
}

/// The first pull (or merge) request address in `text`: GitHub and
/// Forgejo pulls, GitLab merge requests, Bitbucket and Azure pull requests.
fn pull_request_url(text: &str) -> String {
    static ADDRESS: LazyLock<Regex> = LazyLock::new(|| {
        regex(
            r#"https?://[^\s<>()\[\]"']+/(?:pull|pulls|merge_requests|pull-requests|pullrequest)/\d+"#,
        )
    });
    ADDRESS
        .find(text)
        .map_or_else(String::new, |m| m.as_str().to_owned())
}

/// A JSON object written as QJsonDocument::Indented writes it: four
/// spaces a level. (A string holds no raw line breaks, so each line's
/// leading spaces are its indent.)
fn indented(value: &Obj) -> String {
    let pretty = serde_json::to_string_pretty(value).unwrap_or_default();
    pretty
        .lines()
        .map(|line| {
            let body = line.trim_start_matches(' ');
            format!("{}{body}", " ".repeat(2 * (line.len() - body.len())))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

impl Timeline {
    pub fn new(thread_key: &str) -> Timeline {
        Timeline {
            thread_key: thread_key.to_owned(),
            status: "loading".into(),
            problem: String::new(),
            entities: Entities::new(),
            incoming: Entities::new(),
            order: Vec::new(),
            rows: Vec::new(),
            row_of_item: HashMap::new(),
            reshaped: HashSet::new(),
            expanded_folds: HashSet::new(),
            expanded_groups: HashSet::new(),
            kept_open: HashSet::new(),
            attachment_urls: HashMap::new(),
            working_since: None,
            turn_touched: false,
            checkpoints_touched: false,
            agents_touched: false,
            workspace_touched: false,
            agent_models: HashMap::new(),
            clock: Clock::default(),
            thread_titles: None,
            workspace_root: None,
            timestamp_format: "locale".into(),
            cursor: Cursor::default(),
            catching_up: false,
            catch_up: Vec::new(),
            page: Vec::new(),
            loading_earlier: false,
            cache: None,
            dirty: BTreeSet::new(),
            dirty_all: false,
            cursor_dirty: false,
            flush_armed: false,
            out: Vec::new(),
        }
    }

    /// What the timeline said since this was last asked, in order.
    pub fn take_out(&mut self) -> Vec<Out> {
        std::mem::take(&mut self.out)
    }

    pub fn thread_key(&self) -> &str {
        &self.thread_key
    }

    /// loading until the first snapshot lands, live, or unreachable (with
    /// the MC's reason in `problem`). Rows stay while it reloads or is
    /// unreachable.
    pub fn status(&self) -> &str {
        &self.status
    }

    pub fn problem(&self) -> &str {
        &self.problem
    }

    pub fn set_status(&mut self, status: &str, problem: &str) {
        if status == self.status && problem == self.problem {
            return;
        }
        self.status = status.to_owned();
        self.problem = problem.to_owned();
        // Earlier turns only come over a stream that is live.
        if status != "live" && std::mem::take(&mut self.loading_earlier) {
            self.out.push(Out::EarlierChanged);
        }
        self.out.push(Out::StatusChanged);
    }

    pub fn working(&self) -> bool {
        self.working_since.is_some()
    }

    pub fn working_since(&self) -> Option<DateTime<Utc>> {
        self.working_since
    }

    /// "Working for 12s", from the clock; the brick asks once a second.
    pub fn working_label(&self) -> String {
        let Some(since) = self.working_since else {
            return String::new();
        };
        let seconds = (self.clock.now() - since).num_seconds().max(0);
        if seconds < 1 {
            "Working".into()
        } else {
            format!("Working for {}", time::format_duration(seconds * 1000))
        }
    }

    pub fn set_clock(&mut self, clock: Clock) {
        self.clock = clock;
    }

    /// Names another thread of this one's environment, for messages its
    /// agent sent here.
    pub fn set_thread_titles(&mut self, titles: Option<ThreadTitles>) {
        self.thread_titles = titles;
    }

    /// Where a changed file's label is read from.
    pub fn set_workspace_root(&mut self, root: Option<WorkspaceRoot>) {
        self.workspace_root = root;
    }

    /// The device's timestampFormat the rows' times read in.
    pub fn timestamp_format(&self) -> &str {
        &self.timestamp_format
    }

    /// The device's timestampFormat (locale, 12-hour, 24-hour); a change
    /// redraws every row's time.
    pub fn set_timestamp_format(&mut self, format: &str) {
        let next = if format.is_empty() { "locale" } else { format };
        if next == self.timestamp_format {
            return;
        }
        self.timestamp_format = next.to_owned();
        self.redraw_times();
    }

    /// The locale its times are written in (ThreadStore's).
    pub fn set_locale(&mut self, locale: &ljos::locale::Locale) {
        if locale.name() == self.clock.locale.name() {
            return;
        }
        self.clock.locale = locale.clone();
        self.redraw_times();
    }

    fn redraw_times(&mut self) {
        self.out.push(Out::TimesChanged);
        if self.rows.is_empty() {
            return;
        }
        self.out.push(Out::DataChanged {
            first: 0,
            last: self.rows.len() - 1,
            roles: vec![Role::Time, Role::Entries],
        });
    }

    fn entity(&self, kind: &str, id: &str) -> &Obj {
        self.entities
            .get(kind)
            .and_then(|m| m.get(id))
            .unwrap_or(&NONE)
    }

    /// The thread's entities of one stream kind (run, runtime-request,
    /// plan, turn-item, ...) by id, for the composer's turn state.
    pub fn entities(&self, kind: &str) -> &BTreeMap<String, Obj> {
        self.entities.get(kind).unwrap_or(&NO_ENTITIES)
    }

    fn row_time(&self, row: &Row) -> Option<DateTime<Utc>> {
        if row.kind == "fold" {
            return row.at;
        }
        if row.kind == "work" || row.items.is_empty() {
            return None;
        }
        let item = self.entity("turn-item", &row.items[0]);
        // A reply is stamped when it finished, so not while it streams.
        if text(item, "type") == "assistant_message" {
            if flag(item, "streaming") {
                return None;
            }
            return time::time_of(item.get("updatedAt"), self.clock.zone);
        }
        item_time(item, &self.clock)
    }

    /// A time as the rows show theirs; empty for none.
    pub fn stamp(&self, at: Option<DateTime<Utc>>) -> String {
        time::stamp(at, &self.clock, &self.timestamp_format)
    }

    /// A time that may be ahead, as a usage limit's reset reads.
    pub fn upcoming(&self, at: Option<DateTime<Utc>>) -> String {
        time::upcoming_stamp(at, &self.clock, &self.timestamp_format)
    }

    /// The long form of a row's time, or of one of its calls' (`entry_id`),
    /// for its tooltip: "9:41 AM, 23rd September 2026".
    pub fn time_title(&self, row_id: &str, entry_id: &str) -> String {
        let Some(at) = self.index_of(row_id) else {
            return String::new();
        };
        let row = &self.rows[at];
        let when = if entry_id.is_empty() {
            self.row_time(row)
        } else if row.items.iter().any(|i| i == entry_id) {
            item_time(self.entity("turn-item", entry_id), &self.clock)
        } else {
            None
        };
        when.map_or_else(String::new, |when| {
            time::long_time(when, &self.clock, &self.timestamp_format)
        })
    }

    // --- The fold --------------------------------------------------------------------

    /// The `kinds` a subscription to a thread's stream names: the entities
    /// the timeline folds, so the MC sends no others.
    pub fn stream_kinds() -> Json {
        let mut kinds = Obj::new();
        for kind in KINDS {
            kinds.insert(kind.into(), Json::Object(Obj::new()));
        }
        // The agent's replies are their turn items'; only the user's
        // messages are kept.
        kinds.insert("message".into(), serde_json::json!({"role": "user"}));
        Json::Object(kinds)
    }

    fn folds(kind: &str, entity: &Obj) -> bool {
        KINDS.contains(&kind) && (kind != "message" || text(entity, "role") == "user")
    }

    /// What a `sub` frame for the thread carries besides its shape: where
    /// the copy stands (`offset`, `handle`) and the window it holds, or the
    /// window to open with. Asked as each is sent, which starts the
    /// subscription over: a catch-up or a page cut off part-way is dropped.
    pub fn subscribing(&mut self) -> Json {
        self.catching_up = true;
        self.catch_up.clear();
        self.page.clear();
        self.incoming.clear();
        if std::mem::take(&mut self.loading_earlier) {
            self.out.push(Out::EarlierChanged);
        }
        if self.cursor.offset < 0 {
            return serde_json::json!({"offset": null, "window": {"items": WINDOW_ITEMS}});
        }
        let mut resume = serde_json::json!({
            "offset": self.cursor.offset,
            "window": {"floor": self.cursor.floor},
        });
        if !self.cursor.handle.is_empty() {
            resume["handle"] = Json::String(self.cursor.handle.clone());
        }
        resume
    }

    /// A frame of the thread's stream: `snapshot` (part 0 starts over,
    /// `done` swaps it in), `events` ([[seq, kind, id, patch, at]]),
    /// `live`, `page` (earlier turns, added above) or `resync`.
    pub fn receive(&mut self, frame: &Obj) {
        match text(frame, "t") {
            "snapshot" => self.snapshot(frame),
            "events" => self.events_frame(frame),
            "live" => self.live(frame),
            "page" => self.page(frame),
            "resync" => {
                // The MC dropped events it could not send: the
                // resubscription that follows continues from the offset it
                // names, never from an earlier one.
                if let Some(offset) = offset_of(frame, "offset")
                    && self.cursor.offset >= 0
                    && offset > self.cursor.offset
                {
                    self.cursor.offset = offset;
                    self.cursor_dirty = true;
                }
            }
            _ => {}
        }
    }

    fn snapshot(&mut self, frame: &Obj) {
        if int(frame, "part") == 0 {
            self.incoming.clear();
        }
        for row in array(frame, "rows") {
            let row = row.as_array().map_or(&[][..], Vec::as_slice);
            let kind = row.first().and_then(Json::as_str).unwrap_or("");
            let entity = row.get(2).map_or(&*NONE, as_object);
            if Self::folds(kind, entity) {
                let id = row.get(1).and_then(Json::as_str).unwrap_or("");
                self.incoming
                    .entry(kind.to_owned())
                    .or_default()
                    .insert(id.to_owned(), entity.clone());
            }
        }
        if !flag(frame, "done") {
            return;
        }
        // The rows keep their ids; only the ones that read differently are
        // redrawn.
        let incoming = std::mem::take(&mut self.incoming);
        let before = std::mem::replace(&mut self.entities, incoming);
        self.catch_up.clear();
        let had_earlier = self.has_earlier();
        self.cursor.handle = text(frame, "handle").to_owned();
        self.cursor.offset = offset_of(frame, "offset").unwrap_or(0);
        self.cursor.floor = offset_of(frame, "floor");
        let changed = self.changed_since(&before);
        self.everything_changed(&changed);
        if self.has_earlier() != had_earlier {
            self.out.push(Out::EarlierChanged);
        }
        self.dirty_all = true;
        self.flush();
    }

    /// The turn items whose rows read differently than they did with
    /// `before`: the item itself, or the request or subagent it shows.
    fn changed_since(&self, before: &Entities) -> HashSet<String> {
        let was = |kind: &str, id: &str| before.get(kind).and_then(|m| m.get(id));
        let differs = |kind: &str, id: &str| {
            !id.is_empty() && was(kind, id).unwrap_or(&NONE) != self.entity(kind, id)
        };
        self.entities("turn-item")
            .iter()
            .filter(|(id, item)| {
                was("turn-item", id).unwrap_or(&NONE) != *item
                    || differs("runtime-request", text(item, "requestId"))
                    || differs("subagent", text(item, "subagentId"))
            })
            .map(|(id, _)| id.clone())
            .collect()
    }

    fn everything_changed(&mut self, changed: &HashSet<String>) {
        self.sort_items();
        self.restructure(changed);
        self.out.extend([
            Out::TurnChanged,
            Out::CheckpointsChanged,
            Out::AgentsChanged,
            Out::WorkspaceChanged,
        ]);
    }

    fn events_frame(&mut self, frame: &Obj) {
        let reached = offset_of(frame, "offset").unwrap_or(-1);
        let events = array(frame, "events").to_vec();
        // A catch-up that takes several frames is one set of merged
        // changes: its parts carry the offset the client is at, the last
        // one the offset they bring it to. Applied part-way and cut off, it
        // would be applied again.
        if self.catching_up && reached >= 0 && reached <= self.cursor.offset {
            self.catch_up.push(events);
            return;
        }
        // As one change: an item added and removed again while away redraws
        // nothing.
        self.catch_up.push(events);
        let all = self.caught_up();
        self.events(&all);
        // Only a copy has an offset to move: events before any snapshot do
        // not make one.
        if self.cursor.offset >= 0 && reached > self.cursor.offset {
            self.cursor.offset = reached;
        }
        self.cursor_dirty = true;
        if !self.flush_armed {
            self.flush_armed = true;
            self.out.push(Out::FlushTimer(true));
        }
    }

    /// The catch-up parts held so far, as one list of events.
    fn caught_up(&mut self) -> Vec<Json> {
        std::mem::take(&mut self.catch_up)
            .into_iter()
            .flatten()
            .collect()
    }

    fn live(&mut self, frame: &Obj) {
        self.catching_up = false;
        if !self.catch_up.is_empty() {
            let all = self.caught_up();
            self.events(&all);
        }
        if let Some(offset) = offset_of(frame, "offset")
            && self.cursor.offset >= 0
            && offset > self.cursor.offset
        {
            self.cursor.offset = offset;
            self.cursor_dirty = true;
        }
        // An MC that names its log now did not when the copy was taken: the
        // copy is the log's from here on, and the cache has none of it yet.
        let handle = text(frame, "handle");
        if !handle.is_empty() && handle != self.cursor.handle {
            self.cursor.handle = handle.to_owned();
            self.dirty_all = true;
        }
        self.flush();
        self.set_status("live", "");
    }

    fn page(&mut self, frame: &Obj) {
        self.page.push(array(frame, "rows").to_vec());
        if !flag(frame, "done") {
            return;
        }
        for row in std::mem::take(&mut self.page).into_iter().flatten() {
            let row = row.as_array().map_or(&[][..], Vec::as_slice);
            let kind = row.first().and_then(Json::as_str).unwrap_or("");
            let entity = row.get(2).map_or(&*NONE, as_object);
            if !Self::folds(kind, entity) {
                continue;
            }
            let id = row.get(1).and_then(Json::as_str).unwrap_or("");
            self.entities
                .entry(kind.to_owned())
                .or_default()
                .insert(id.to_owned(), entity.clone());
            self.dirty.insert((kind.to_owned(), id.to_owned()));
        }
        if let Some(offset) = offset_of(frame, "offset")
            && offset > self.cursor.offset
        {
            self.cursor.offset = offset;
        }
        self.cursor.floor = offset_of(frame, "floor");
        self.cursor_dirty = true;
        self.loading_earlier = false;
        // The earlier turns' rows go in above; the ones held keep their
        // place.
        self.sort_items();
        self.restructure(&HashSet::new());
        self.out
            .extend([Out::TurnChanged, Out::AgentsChanged, Out::EarlierChanged]);
        self.flush();
    }

    /// Whether the thread has turns before the ones held.
    pub fn has_earlier(&self) -> bool {
        self.cursor.floor.is_some()
    }

    /// Whether those are on their way.
    pub fn loading_earlier(&self) -> bool {
        self.loading_earlier
    }

    /// Asks for the turns before the ones held ([`Out::EarlierWanted`]).
    /// Their rows are inserted above the first; the rows held keep their
    /// ids.
    pub fn load_earlier(&mut self) {
        if !self.has_earlier() || self.loading_earlier || self.status != "live" {
            return;
        }
        self.loading_earlier = true;
        self.out.push(Out::EarlierChanged);
        self.out.push(Out::EarlierWanted(WINDOW_ITEMS));
    }

    // --- The cache -------------------------------------------------------------------

    /// Where the copy is kept between runs; without one nothing is.
    pub fn set_cache(&mut self, cache: Option<Rc<dyn ThreadCache>>) {
        self.cache = cache;
    }

    pub fn cursor(&self) -> &Cursor {
        &self.cursor
    }

    fn cached(&self, kind: &str, id: &str, fields: &Obj) -> cache::Entity {
        let mut entity = cache::Entity {
            kind: kind.to_owned(),
            id: id.to_owned(),
            fields: fields.clone(),
            run: None,
        };
        if WINDOWED.contains(&kind) {
            let run = self.entity("run", text(fields, "runId"));
            if !run.is_empty() {
                entity.run = Some(number(run, "ordinal") as i64);
            }
        }
        entity
    }

    /// The copy the cache held, for a timeline that has none yet: its rows
    /// show at once, `loading` until the MC says the thread is live.
    pub fn restore(&mut self, thread: &cache::Thread) {
        // Without the handle its offset came with, a copy cannot say what
        // it is a copy of.
        if !thread.found() || thread.cursor.handle.is_empty() || self.cursor.offset >= 0 {
            return;
        }
        let before = self.entities.clone();
        for entity in &thread.entities {
            if !Self::folds(&entity.kind, &entity.fields) {
                continue;
            }
            // Another window on the thread may have held more of it than
            // the cursor says.
            if let (Some(run), Some(floor)) = (entity.run, thread.cursor.floor)
                && run < floor
            {
                continue;
            }
            self.entities
                .entry(entity.kind.clone())
                .or_default()
                .insert(entity.id.clone(), entity.fields.clone());
        }
        self.cursor = thread.cursor.clone();
        let changed = self.changed_since(&before);
        self.everything_changed(&changed);
        if self.has_earlier() {
            self.out.push(Out::EarlierChanged);
        }
    }

    /// Hands the cache what changed since the last time, with the cursor it
    /// reflects.
    pub fn flush(&mut self) {
        if std::mem::take(&mut self.flush_armed) {
            self.out.push(Out::FlushTimer(false));
        }
        let all = std::mem::take(&mut self.dirty_all);
        let dirty = std::mem::take(&mut self.dirty);
        let cursor = std::mem::take(&mut self.cursor_dirty);
        let Some(cache) = self.cache.clone() else {
            return;
        };
        if self.cursor.offset < 0 || self.cursor.handle.is_empty() {
            return;
        }
        if !all && !cursor && dirty.is_empty() {
            return;
        }
        let mut update = cache::ThreadUpdate {
            key: self.thread_key.clone(),
            cursor: self.cursor.clone(),
            replace: all,
            put: Vec::new(),
            gone: Vec::new(),
        };
        if all {
            for (kind, entities) in &self.entities {
                for (id, fields) in entities {
                    update.put.push(self.cached(kind, id, fields));
                }
            }
        } else {
            for (kind, id) in dirty {
                match self.entities.get(&kind).and_then(|m| m.get(&id)) {
                    Some(fields) => update.put.push(self.cached(&kind, &id, fields)),
                    None => update.gone.push((kind, id)),
                }
            }
        }
        cache.store_thread(update);
    }

    /// The thread is closing: flushes, and trims the cached copy back to
    /// the window a thread opens with.
    pub fn park(&mut self) {
        self.flush();
        let Some(cache) = self.cache.clone() else {
            return;
        };
        if self.cursor.offset < 0 || self.cursor.handle.is_empty() {
            return;
        }
        // The newest runs of the window that together hold WINDOW_ITEMS
        // turn items (HalC2.Streams.View.take_runs); the runs before them
        // leave the copy.
        let mut counts: HashMap<&str, i64> = HashMap::new();
        for item in self.entities("turn-item").values() {
            *counts.entry(text(item, "runId")).or_default() += 1;
        }
        let mut runs: Vec<(i64, &str)> = self
            .entities("run")
            .iter()
            .filter(|(_, run)| text(run, "status") != "rolled_back")
            .map(|(id, run)| (number(run, "ordinal") as i64, id.as_str()))
            .filter(|(ordinal, _)| self.cursor.floor.is_none_or(|floor| *ordinal >= floor))
            .collect();
        runs.sort_by(|a, b| b.cmp(a));
        let mut count = 0;
        for (ordinal, id) in runs.iter().take(runs.len().saturating_sub(1)) {
            count += counts.get(*id).copied().unwrap_or(0);
            if count < WINDOW_ITEMS {
                continue;
            }
            cache.trim_thread(&self.thread_key, *ordinal);
            return;
        }
    }

    // --- Events ----------------------------------------------------------------------

    /// One `events` frame's events, applied.
    fn events(&mut self, events: &[Json]) {
        let mut changed = HashSet::new();
        let mut structural = false;
        self.turn_touched = false;
        self.checkpoints_touched = false;
        self.agents_touched = false;
        self.workspace_touched = false;
        self.reshaped.clear();
        self.agent_models.clear();
        for event in events {
            let event = event.as_array().map_or(&[][..], Vec::as_slice);
            // An event the copy already holds (a frame sent again on a
            // reconnect) would append its text twice.
            if self.cursor.offset >= 0
                && let Some(seq) = event.first().and_then(Json::as_f64)
                && seq as i64 <= self.cursor.offset
            {
                continue;
            }
            let kind = event.get(1).and_then(Json::as_str).unwrap_or("");
            let id = event.get(2).and_then(Json::as_str).unwrap_or("");
            let patch = event.get(3).map_or(&*NONE, as_object);
            structural |= self.apply(kind, id, patch, &mut changed);
        }
        if self.turn_touched {
            self.out.push(Out::TurnChanged);
        }
        if self.checkpoints_touched {
            self.out.push(Out::CheckpointsChanged);
        }
        if self.agents_touched {
            self.out.push(Out::AgentsChanged);
        }
        // A subagent's row shows its entity's model, status and latest
        // words.
        if !self.agent_models.is_empty() {
            for row in 0..self.rows.len() {
                if self.rows[row].kind != "subagent" {
                    continue;
                }
                let first = self.rows[row].items.first().map_or("", String::as_str);
                let agent = text(self.entity("turn-item", first), "subagentId");
                let Some(was) = self.agent_models.get(agent) else {
                    continue;
                };
                let now = self.entity("subagent", agent);
                let moved = ["model", "status", "progress", "result"]
                    .iter()
                    .any(|field| was.get(*field) != now.get(*field));
                if moved {
                    self.out.push(Out::DataChanged {
                        first: row,
                        last: row,
                        roles: vec![Role::Model, Role::Status, Role::StatusLabel, Role::Text],
                    });
                }
            }
        }
        if self.workspace_touched {
            self.out.push(Out::WorkspaceChanged);
        }
        if structural {
            self.restructure(&changed);
            return;
        }
        // A row whose items only grew by streamed text says which role that
        // is, so a delta does not make its delegate read every other one
        // again.
        let mut redraw: BTreeMap<usize, bool> = BTreeMap::new(); // row -> only its text grew
        for id in &changed {
            let Some(&row) = self.row_of_item.get(id) else {
                continue;
            };
            if !self.shows(&self.rows[row], id) {
                continue;
            }
            let text_only = !self.reshaped.contains(id);
            redraw
                .entry(row)
                .and_modify(|only| *only = *only && text_only)
                .or_insert(text_only);
        }
        for (row, text_only) in redraw {
            let roles = match (text_only, self.rows[row].kind) {
                (true, "message") => vec![Role::Text],
                (true, "work") => vec![Role::Entries],
                _ => Vec::new(),
            };
            self.out.push(Out::DataChanged {
                first: row,
                last: row,
                roles,
            });
        }
    }

    /// Whether `row` draws anything of turn item `item`.
    fn shows(&self, row: &Row, item: &str) -> bool {
        // A collapsed work group draws its last entries and, summarized, a
        // summary of all of them.
        if row.kind != "work"
            || row.summarized
            || self.expanded_groups.contains(&row.id) != row.starts_open
        {
            return true;
        }
        row.items
            .iter()
            .position(|i| i == item)
            .is_some_and(|at| at + VISIBLE_WORK_ENTRIES >= row.items.len())
    }

    fn store(&mut self, kind: &str, id: &str, next: Option<Obj>) {
        let by_kind = self.entities.entry(kind.to_owned()).or_default();
        match next {
            Some(next) => {
                by_kind.insert(id.to_owned(), next);
            }
            None => {
                by_kind.remove(id);
            }
        }
    }

    /// Applies one event; true when the row list has to be derived again.
    fn apply(&mut self, kind: &str, id: &str, patch: &Obj, changed: &mut HashSet<String>) -> bool {
        if !KINDS.contains(&kind) {
            return false;
        }
        self.dirty.insert((kind.to_owned(), id.to_owned()));
        let current = self.entities.get(kind).and_then(|m| m.get(id)).cloned();
        let existed = current.is_some();
        let next = patched(current.as_ref(), patch);
        if kind == "checkpoint" || kind == "subagent" {
            if kind == "subagent" {
                self.agents_touched = true;
                if !self.agent_models.contains_key(id) {
                    self.agent_models
                        .insert(id.to_owned(), current.clone().unwrap_or_default());
                }
            } else {
                self.checkpoints_touched = true;
                self.workspace_touched = true;
            }
            self.store(kind, id, next);
            return false;
        }
        if kind == "plan" || kind == "message" {
            // The agent's streamed replies are the turn items'; only the
            // user's messages (a queued run's text) are kept.
            if kind == "message" && text(next.as_ref().unwrap_or(&NONE), "role") != "user" {
                self.store(kind, id, None);
                return false;
            }
            self.turn_touched = true;
            self.store(kind, id, next);
            return false;
        }
        if kind != "turn-item" {
            self.turn_touched = true;
            // A run rolled back drops its commands from the Agents tab.
            if kind == "run" {
                self.agents_touched = true;
            }
            // A renumbered run (it took its start ordinal) moves its
            // windowed entities' cached run ordinal with it: cache them
            // again, or restore() and park() would filter and trim by the
            // stale ordinal until they next change.
            let renumbered = kind == "run"
                && next
                    .as_ref()
                    .zip(current.as_ref())
                    .is_some_and(|(next, current)| next.get("ordinal") != current.get("ordinal"));
            // Runs, attempts and requests change fold labels, visibility
            // and the working state; they change far less often than items.
            self.store(kind, id, next);
            if renumbered {
                for windowed in WINDOWED {
                    let ids: Vec<String> = self
                        .entities(windowed)
                        .iter()
                        .filter(|(_, entity)| text(entity, "runId") == id)
                        .map(|(key, _)| key.clone())
                        .collect();
                    for key in ids {
                        self.dirty.insert((windowed.to_owned(), key));
                    }
                }
            }
            return true;
        }
        changed.insert(id.to_owned());
        let shape = next.as_ref().or(current.as_ref()).unwrap_or(&NONE);
        let kind_of_item = text(shape, "type").to_owned();
        if TURN_ITEMS.contains(&kind_of_item.as_str()) {
            self.turn_touched = true;
        }
        let is_command = kind_of_item == "command_execution";
        if (is_command || kind_of_item == "file_change") && !patch.contains_key("a") {
            self.workspace_touched = true;
        }
        let replaced = flag(patch, "d");
        // A command starting, settling or going away; not its streamed
        // output.
        if is_command
            && (!existed
                || next.is_none()
                || replaced
                || patch.contains_key("s")
                || patch.contains_key("u"))
        {
            self.agents_touched = true;
        }
        let mut fields: Vec<&str> = object(patch, "s").keys().map(String::as_str).collect();
        fields.extend(array(patch, "u").iter().map(|f| f.as_str().unwrap_or("")));
        let structural =
            !existed || next.is_none() || replaced || fields.iter().any(|f| STRUCTURAL.contains(f));
        // Anything but text appended to the item as it streams.
        let appended = object(patch, "a");
        if !existed
            || next.is_none()
            || replaced
            || !fields.is_empty()
            || appended.len() != 1
            || !appended.contains_key("text")
        {
            self.reshaped.insert(id.to_owned());
        }
        let moves = !existed || next.is_none() || replaced || fields.contains(&"ordinal");
        if existed && moves {
            self.unplace(id);
        }
        let placed = next.is_some();
        self.store(kind, id, next);
        if placed && moves {
            self.place(id);
        }
        structural
    }

    fn ordinal_of(&self, item: &str) -> f64 {
        number(self.entity("turn-item", item), "ordinal")
    }

    fn place(&mut self, item: &str) {
        let ordinal = self.ordinal_of(item);
        let at = self.order.partition_point(|other| {
            let theirs = self.ordinal_of(other);
            if theirs != ordinal {
                theirs < ordinal
            } else {
                other.as_str() < item
            }
        });
        self.order.insert(at, item.to_owned());
    }

    fn unplace(&mut self, item: &str) {
        if let Some(at) = self.order.iter().position(|i| i == item) {
            self.order.remove(at);
        }
    }

    /// Turn items are shown in ordinal order, as the MC sends them.
    fn sort_items(&mut self) {
        let mut order: Vec<(f64, String)> = self
            .entities("turn-item")
            .iter()
            .map(|(id, item)| (number(item, "ordinal"), id.clone()))
            .collect();
        order.sort_by(|a, b| a.0.total_cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
        self.order = order.into_iter().map(|(_, id)| id).collect();
    }

    // --- The projection --------------------------------------------------------------

    /// Derives the rows again, redrawing the ones `changed` shows.
    fn restructure(&mut self, changed: &HashSet<String>) {
        let rows = self.project();
        self.apply_rows(rows, changed);
        self.row_of_item.clear();
        for (at, row) in self.rows.iter().enumerate() {
            for item in &row.items {
                self.row_of_item.insert(item.clone(), at);
            }
            if !row.checkpoint.is_empty() {
                self.row_of_item.insert(row.checkpoint.clone(), at);
            }
        }
        self.update_working();
    }

    fn project(&self) -> Vec<Row> {
        let items = self.entities("turn-item");
        let runs = self.entities("run");
        let item = |id: &str| items.get(id).unwrap_or(&NONE);
        let run = |id: &str| runs.get(id).unwrap_or(&NONE);

        // Items of a rolled-back run, queued messages of a cancelled run,
        // and the interrupt result a plain steer leaves behind are hidden.
        let superseded: HashSet<String> = self
            .entities("run-attempt")
            .values()
            .filter(|attempt| text(attempt, "status") == "superseded")
            .map(|attempt| {
                format!(
                    "{}\n{}",
                    text(attempt, "runId"),
                    text(attempt, "rootNodeId")
                )
            })
            .collect();
        let interrupt_requested: HashSet<&str> = items
            .values()
            .filter(|item| text(item, "type") == "run_interrupt_request")
            .map(|item| text(item, "runId"))
            .collect();
        let visible = |item: &Obj| {
            let run_id = text(item, "runId");
            let kind = text(item, "type");
            let status = text(run(run_id), "status");
            if status == "rolled_back" {
                return false;
            }
            if status == "cancelled"
                && kind == "user_message"
                && text(item, "inputIntent") == "queued_turn"
            {
                return false;
            }
            !(kind == "run_interrupt_result"
                && !run_id.is_empty()
                && superseded.contains(&format!("{run_id}\n{}", text(item, "nodeId")))
                && !interrupt_requested.contains(run_id))
        };

        // The thread's latest run, as the MC's (HalC2.Projection.Shell
        // latest_run/1): a run held for the user that never started (still
        // queued, or cancelled while held) waits numbered above the run that
        // passed it. Equal ordinals (legacy runs stored without one read 0)
        // go to the later-starting run for runs with an item here: a run is
        // as new as its first item in timeline order. That is start order,
        // where the MC's tie-break is newest *made*; for legacy ties where a
        // later-made run passed an earlier-made one the two can disagree on
        // the pick. Runs with no item here (none created yet, or outside the
        // window) are settled by id instead. The item index is built only
        // when the highest ordinal actually ties, so the common case is one
        // pass over the runs.
        let held_never_started = |run: &Obj| {
            matches!(text(run, "status"), "queued" | "cancelled") && flag(run, "queueHeld")
        };
        let mut latest_run = "";
        let mut latest_ordinal = -1.0;
        let mut latest_tied = false;
        for (id, r) in runs {
            if held_never_started(r) {
                continue;
            }
            let ordinal = number(r, "ordinal");
            if ordinal > latest_ordinal {
                latest_ordinal = ordinal;
                latest_run = id;
                latest_tied = false;
            } else if ordinal == latest_ordinal {
                latest_tied = true;
            }
        }
        if latest_tied {
            let mut first_item: HashMap<&str, i64> = HashMap::new();
            for (i, id) in self.order.iter().enumerate() {
                let run_id = text(item(id), "runId");
                if !run_id.is_empty() {
                    first_item.entry(run_id).or_insert(i as i64);
                }
            }
            let mut latest_first = -1;
            for (id, r) in runs {
                if held_never_started(r) || number(r, "ordinal") != latest_ordinal {
                    continue;
                }
                let first = first_item.get(id.as_str()).copied().unwrap_or(-1);
                if first > latest_first || (first == latest_first && id.as_str() > latest_run) {
                    latest_first = first;
                    latest_run = id;
                }
            }
        }

        // Each run's items after the user message that started it.
        #[derive(Default)]
        struct Turn {
            items: Vec<String>,
            /// Its last assistant message.
            terminal: String,
            /// Its latest checkpoint with files.
            checkpoint: String,
            streaming: bool,
            boundary: Option<DateTime<Utc>>,
        }
        let mut shown: Vec<&Obj> = Vec::new();
        let mut turns: HashMap<String, Turn> = HashMap::new();
        let mut turn_order: Vec<String> = Vec::new();
        let mut asked: HashSet<&str> = HashSet::new(); // runs whose opening message came by
        let mut boundary: Option<DateTime<Utc>> = None;
        for id in &self.order {
            let it = item(id);
            if !visible(it) {
                continue;
            }
            shown.push(it);
            let kind = text(it, "type");
            let run_id = text(it, "runId");
            // A run begins at the user's message, or at what the MC sent in
            // its place: a notification ahead of everything else of its run.
            if kind == "user_message"
                || (kind == "notification"
                    && !run_id.is_empty()
                    && !asked.contains(run_id)
                    && !turns.contains_key(run_id))
            {
                asked.insert(run_id);
                boundary = time::time_of(it.get("startedAt"), self.clock.zone)
                    .or_else(|| time::time_of(it.get("updatedAt"), self.clock.zone));
                continue;
            }
            if run_id.is_empty() {
                continue;
            }
            let turn = turns.entry(run_id.to_owned()).or_insert_with(|| {
                turn_order.push(run_id.to_owned());
                Turn {
                    boundary: boundary.take(),
                    ..Turn::default()
                }
            });
            turn.items.push(id.clone());
            if kind == "assistant_message" {
                turn.terminal = id.clone();
                turn.streaming = turn.streaming || flag(it, "streaming");
            } else if kind == "checkpoint" && !array(it, "files").is_empty() {
                turn.checkpoint = id.clone();
            }
        }

        // A settled turn folds its work (tool calls, commentary) behind how
        // long it took, leaving its last reply in view.
        struct Fold {
            run_id: String,
            label: String,
            hidden: usize,
            open: bool,
            at: Option<DateTime<Utc>>,
        }
        let mut fold_at: HashMap<&str, Fold> = HashMap::new(); // by the turn's first item
        let mut folded: HashSet<&str> = HashSet::new(); // hidden items
        for run_id in &turn_order {
            let turn = &turns[run_id];
            let r = run(run_id);
            let status = text(r, "status");
            if !settled(status) || turn.streaming {
                continue;
            }
            let hidden: Vec<&str> = turn
                .items
                .iter()
                .filter(|id| **id != turn.terminal)
                .filter(|id| {
                    let it = item(id);
                    match classify(it) {
                        // Work a turn left running (a background command)
                        // stays in view.
                        Kind::Work => text(it, "status") != "running",
                        Kind::Message => true,
                        _ => false,
                    }
                })
                .map(String::as_str)
                .collect();
            if hidden.is_empty() {
                continue;
            }
            let interrupted = run_id == latest_run && status == "interrupted";
            let started = time::time_of(r.get("startedAt"), self.clock.zone);
            let completed = time::time_of(r.get("completedAt"), self.clock.zone);
            let elapsed = match (started, completed) {
                (Some(started), Some(completed)) => Some((completed - started).num_milliseconds()),
                _ if !interrupted => {
                    // No run times: from the user's message to the last
                    // item's update.
                    let first = item(&turn.items[0]);
                    let from = turn
                        .boundary
                        .or_else(|| time::time_of(first.get("startedAt"), self.clock.zone));
                    let to = turn
                        .items
                        .iter()
                        .map(|id| time::time_of(item(id).get("updatedAt"), self.clock.zone))
                        .max()
                        .flatten();
                    match (from, to) {
                        (Some(from), Some(to)) => Some((to - from).num_milliseconds().max(0)),
                        _ => None,
                    }
                }
                _ => None,
            };
            // A run stopped before it started has no duration.
            let label = match (interrupted, elapsed) {
                (true, Some(ms)) => format!("You stopped after {}", time::format_duration(ms)),
                (true, None) => "You stopped this response".into(),
                (false, Some(ms)) => format!("Worked for {}", time::format_duration(ms)),
                (false, None) => "Worked".into(),
            };
            let open = self.expanded_folds.contains(run_id) != self.kept_open.contains(run_id);
            // A turn fold reads the user's message's time, else its first
            // item's.
            let at = turn
                .boundary
                .or_else(|| item_time(item(&turn.items[0]), &self.clock));
            fold_at.insert(
                turn.items[0].as_str(),
                Fold {
                    run_id: run_id.clone(),
                    label,
                    hidden: hidden.len(),
                    open,
                    at,
                },
            );
            if !open {
                folded.extend(hidden);
            }
        }

        let mut rows = Vec::new();
        let mut i = 0;
        while i < shown.len() {
            let it = shown[i];
            let id = text(it, "id");
            if let Some(fold) = fold_at.get(id) {
                rows.push(Row {
                    id: format!("fold:{}", fold.run_id),
                    kind: "fold",
                    label: fold.label.clone(),
                    hidden: fold.hidden,
                    expanded: fold.open,
                    at: fold.at,
                    ..Row::default()
                });
            }
            let kind = classify(it);
            if folded.contains(id) || kind == Kind::Checkpoint {
                i += 1;
                continue;
            }
            let run_id = text(it, "runId");
            if kind == Kind::Work {
                // Consecutive calls of one turn make a group.
                let mut row = Row {
                    id: format!("work:{id}"),
                    kind: "work",
                    ..Row::default()
                };
                let mut next = i;
                while next < shown.len() {
                    let call = shown[next];
                    let call_id = text(call, "id");
                    if next > i && fold_at.contains_key(call_id) {
                        break;
                    }
                    let call_kind = classify(call);
                    if call_kind == Kind::Checkpoint {
                        next += 1;
                        continue;
                    }
                    if call_kind != Kind::Work
                        || folded.contains(call_id)
                        || text(call, "runId") != run_id
                    {
                        break;
                    }
                    row.items.push(call_id.to_owned());
                    next += 1;
                }
                row.summarized = row.items.len() > 1 && settled(text(run(run_id), "status"));
                row.starts_open = self.kept_open.contains(run_id);
                rows.push(row);
                i = next;
                continue;
            }
            let mut row = Row {
                id: id.to_owned(),
                kind: kind_name(kind),
                items: vec![id.to_owned()],
                ..Row::default()
            };
            if kind == Kind::Message
                && !run_id.is_empty()
                && let Some(turn) = turns.get(run_id)
                && turn.terminal == id
            {
                row.checkpoint = turn.checkpoint.clone();
                row.meta = !turn.streaming && settled(text(run(run_id), "status"));
            }
            rows.push(row);
            i += 1;
        }
        rows
    }

    /// Whether `row` shows an item `changed` names, or the checkpoint it
    /// lists.
    fn dirty_row(&self, row: &Row, changed: &HashSet<String>) -> bool {
        row.items
            .iter()
            .any(|item| changed.contains(item) && self.shows(row, item))
            || (!row.checkpoint.is_empty() && changed.contains(&row.checkpoint))
    }

    /// Brings the rows in line with `rows` by id: removes, inserts and
    /// moves them, and redraws the ones whose shape or items changed.
    fn apply_rows(&mut self, rows: Vec<Row>, changed: &HashSet<String>) {
        let before = self.rows.len();
        let wanted: HashSet<&str> = rows.iter().map(|r| r.id.as_str()).collect();
        let mut last = self.rows.len();
        while last > 0 {
            if wanted.contains(self.rows[last - 1].id.as_str()) {
                last -= 1;
                continue;
            }
            let mut first = last - 1;
            while first > 0 && !wanted.contains(self.rows[first - 1].id.as_str()) {
                first -= 1;
            }
            self.rows.drain(first..last);
            self.out.push(Out::Removed {
                first,
                count: last - first,
            });
            last = first;
        }
        let present: HashSet<String> = self.rows.iter().map(|r| r.id.clone()).collect();
        let mut i = 0;
        while i < rows.len() {
            let want = &rows[i];
            if !present.contains(&want.id) {
                let mut end = i + 1;
                while end < rows.len() && !present.contains(&rows[end].id) {
                    end += 1;
                }
                self.rows.splice(i..i, rows[i..end].iter().cloned());
                self.out.push(Out::Inserted {
                    first: i,
                    ids: rows[i..end].iter().map(|r| r.id.clone()).collect(),
                });
                i = end;
                continue;
            }
            if self.rows[i].id != want.id {
                let from = (i + 1..self.rows.len())
                    .find(|&from| self.rows[from].id == want.id)
                    .expect("a row present is further down");
                let row = self.rows.remove(from);
                self.rows.insert(i, row);
                self.out.push(Out::Moved { from, to: i });
            }
            if self.rows[i] != *want || self.dirty_row(want, changed) {
                self.rows[i] = want.clone();
                self.out.push(Out::DataChanged {
                    first: i,
                    last: i,
                    roles: Vec::new(),
                });
            }
            i += 1;
        }
        if self.rows.len() != before {
            self.out.push(Out::CountChanged);
        }
    }

    /// The thread works while a run is under way, since the earliest one
    /// started.
    fn update_working(&mut self) {
        let mut since: Option<DateTime<Utc>> = None;
        for run in self.entities("run").values() {
            if !RUNNING.contains(&text(run, "status")) {
                continue;
            }
            let started = time::time_of(run.get("startedAt"), self.clock.zone)
                .or_else(|| time::time_of(run.get("requestedAt"), self.clock.zone))
                .unwrap_or_else(|| self.clock.now());
            if since.is_none_or(|since| started < since) {
                since = Some(started);
            }
        }
        if since == self.working_since {
            return;
        }
        self.working_since = since;
        self.out.push(Out::WorkingChanged);
    }

    /// The user stopped this run here: once it settles its work stays
    /// open, fold and calls, so they see where it stopped. A stop from
    /// elsewhere, or one a restart forgot, folds as any turn does; `toggle`
    /// still closes it.
    pub fn keep_open(&mut self, run_id: &str) {
        if run_id.is_empty() || !self.kept_open.insert(run_id.to_owned()) {
            return;
        }
        self.restructure(&HashSet::new());
    }

    /// Opens or closes a fold ("fold:<runId>") or a work group
    /// ("work:<itemId>").
    pub fn toggle(&mut self, row_id: &str) {
        if let Some(run_id) = row_id.strip_prefix("fold:") {
            if !self.expanded_folds.remove(run_id) {
                self.expanded_folds.insert(run_id.to_owned());
            }
            self.restructure(&HashSet::new());
            return;
        }
        let Some(row) = self.index_of(row_id) else {
            return;
        };
        if self.rows[row].kind != "work" {
            return;
        }
        if !self.expanded_groups.remove(row_id) {
            self.expanded_groups.insert(row_id.to_owned());
        }
        self.out.push(Out::DataChanged {
            first: row,
            last: row,
            roles: vec![Role::Entries, Role::HiddenCount, Role::Expanded],
        });
    }

    pub fn index_of(&self, row_id: &str) -> Option<usize> {
        self.rows.iter().position(|r| r.id == row_id)
    }

    pub fn row_count(&self) -> usize {
        self.rows.len()
    }

    pub fn row_id(&self, row: usize) -> Option<&str> {
        self.rows.get(row).map(|r| r.id.as_str())
    }

    /// The text `copy` puts on the clipboard: a message's; none for any
    /// other row.
    pub fn copy_text(&self, row_id: &str) -> Option<String> {
        let at = self.index_of(row_id)?;
        if self.rows[at].kind != "message" {
            return None;
        }
        Some(
            self.data(at, Role::Text)
                .and_then(|v| v.as_str().map(str::to_owned))
                .unwrap_or_default(),
        )
    }

    /// A message row's turn item of `kind` (user_message or
    /// assistant_message).
    fn message_item(&self, row_id: &str, kind: &str) -> Option<&Obj> {
        let row = &self.rows[self.index_of(row_id)?];
        if row.kind != "message" || row.items.is_empty() {
            return None;
        }
        let item = self.entity("turn-item", &row.items[0]);
        (text(item, "type") == kind).then_some(item)
    }

    /// The run an assistant reply's row belongs to once it has finished (a
    /// fork can start from it), else empty.
    pub fn finished_run_of(&self, row_id: &str) -> String {
        let Some(item) = self.message_item(row_id, "assistant_message") else {
            return String::new();
        };
        let run_id = text(item, "runId");
        if text(self.entity("run", run_id), "status") == "completed" {
            run_id.to_owned()
        } else {
            String::new()
        }
    }

    /// Where the thread rewinds to when the user edits from their message
    /// `row_id`: {turn (from 1), checkpointId and scopeId (the checkpoint
    /// the turn before it left), text, attachments}. Empty for any other
    /// row, and without `checkpointId` when no checkpoint precedes it.
    pub fn rewind_point_of(&self, row_id: &str) -> Obj {
        let Some(item) = self.message_item(row_id, "user_message") else {
            return Obj::new();
        };
        let run_id = text(item, "runId");
        let runs = self.entities("run");
        let checkpoints = self.entities("checkpoint");
        // The turn's number: its checkpoint's, else its place among the
        // runs still shown.
        let mut turn = 0;
        for checkpoint in checkpoints.values() {
            if text(checkpoint, "runId") == run_id {
                turn = int(checkpoint, "appRunOrdinal");
            }
        }
        if turn <= 0 {
            let ordinal = number(runs.get(run_id).unwrap_or(&NONE), "ordinal");
            turn = runs
                .values()
                .filter(|other| {
                    number(other, "ordinal") <= ordinal && text(other, "status") != "rolled_back"
                })
                .count() as i64;
        }
        let mut point = Obj::new();
        point.insert("turn".into(), Json::from(turn));
        point.insert("text".into(), Json::from(text(item, "text")));
        point.insert(
            "attachments".into(),
            Json::Array(array(item, "attachments").to_vec()),
        );
        for (id, checkpoint) in checkpoints {
            if text(checkpoint, "status") != "ready" || int(checkpoint, "appRunOrdinal") != turn - 1
            {
                continue;
            }
            // Before the first turn it is the thread's baseline, which has
            // no turn.
            if turn == 1
                && (is_number(checkpoint.get("appRunOrdinal"))
                    || text(checkpoint, "runId") != run_id)
            {
                continue;
            }
            point.insert("checkpointId".into(), Json::from(id.as_str()));
            point.insert("scopeId".into(), Json::from(text(checkpoint, "scopeId")));
        }
        point
    }

    /// The checkpoint an agent reply's settled turn left, to revert the
    /// thread to: {checkpointId, scopeId, turn} (turn counts from 1), or
    /// empty.
    pub fn checkpoint_of(&self, row_id: &str) -> Obj {
        let Some(item) = self.message_item(row_id, "assistant_message") else {
            return Obj::new();
        };
        let run_id = text(item, "runId");
        let run = self.entity("run", run_id);
        if !settled(text(run, "status")) {
            return Obj::new();
        }
        for (id, checkpoint) in self.entities("checkpoint") {
            if text(checkpoint, "runId") != run_id || text(checkpoint, "status") != "ready" {
                continue;
            }
            // The MC's turn number (the diff panel's), else the turn's
            // number among the runs still shown.
            let mut turn = int(checkpoint, "appRunOrdinal");
            if turn <= 0 {
                let ordinal = int(run, "ordinal");
                turn = self
                    .entities("run")
                    .values()
                    .filter(|other| {
                        int(other, "ordinal") <= ordinal && text(other, "status") != "rolled_back"
                    })
                    .count() as i64;
            }
            let mut point = Obj::new();
            point.insert("checkpointId".into(), Json::from(id.as_str()));
            point.insert("scopeId".into(), Json::from(text(checkpoint, "scopeId")));
            point.insert("turn".into(), Json::from(turn));
            return point;
        }
        Obj::new()
    }

    /// Asks for an image's address ([`Out::AttachmentWanted`]) unless one
    /// that still works is known or on its way; its row's `attachments`
    /// carry it once `set_attachment_url` lands.
    pub fn load_attachment(&mut self, id: &str) {
        if let Some(known) = self.attachment_urls.get(id)
            && known
                .expires_at
                .is_none_or(|expires| expires > self.clock.now())
        {
            return;
        }
        self.attachment_urls
            .insert(id.to_owned(), AttachmentUrl::default());
        self.out.push(Out::AttachmentWanted(id.to_owned()));
    }

    /// The address the MC signed for an image and when it stops working;
    /// an empty one when the MC had none, so the next ask tries again.
    pub fn set_attachment_url(&mut self, id: &str, url: &str, expires_at: Option<DateTime<Utc>>) {
        if url.is_empty() {
            self.attachment_urls.remove(id);
            return;
        }
        self.attachment_urls.insert(
            id.to_owned(),
            AttachmentUrl {
                url: url.to_owned(),
                expires_at,
            },
        );
        for (at, row) in self.rows.iter().enumerate() {
            if row.kind != "message" {
                continue;
            }
            let first = row.items.first().map_or("", String::as_str);
            let item = self.entity("turn-item", first);
            if array(item, "attachments")
                .iter()
                .any(|a| text(as_object(a), "id") == id)
            {
                self.out.push(Out::DataChanged {
                    first: at,
                    last: at,
                    roles: vec![Role::Attachments],
                });
                return;
            }
        }
    }

    // --- Rows ------------------------------------------------------------------------

    /// One tool call of a work group (apps/tui/src/orchestrationV2Adapter.ts
    /// itemSummary).
    fn entry(&self, item: &Obj) -> Json {
        let kind = text(item, "type");
        let status = text(item, "status");
        let title = text(item, "title").trim();
        let mut entry = Obj::new();
        entry.insert("id".into(), Json::from(text(item, "id")));
        entry.insert("type".into(), Json::from(kind));
        entry.insert("status".into(), Json::from(status));
        entry.insert("statusLabel".into(), Json::from(call_status_label(status)));
        entry.insert("icon".into(), Json::from(icon_of(item)));
        entry.insert(
            "time".into(),
            Json::from(self.stamp(item_time(item, &self.clock))),
        );
        let mut label: String;
        let mut detail = String::new();
        match kind {
            "reasoning" => {
                let thinking = flag(item, "streaming") || status == "running";
                detail = text(item, "text").to_owned();
                let line = if thinking {
                    String::new()
                } else {
                    thought_line(&detail)
                };
                label = if thinking {
                    "Thinking".into()
                } else if line.is_empty() {
                    "Thought".into()
                } else {
                    line
                };
            }
            "command_execution" => {
                let command = summary::command_display_text(text(item, "input"));
                label = if command.is_empty() {
                    "Ran command".into()
                } else {
                    command
                };
                detail = text(item, "output").to_owned();
                entry.insert("command".into(), Json::from(text(item, "input")));
                if is_number(item.get("exitCode")) {
                    entry.insert("exitCode".into(), Json::from(int(item, "exitCode")));
                }
            }
            "file_change" => {
                let root = self
                    .workspace_root
                    .as_ref()
                    .map(|root| root())
                    .unwrap_or_default();
                label = workspace_path(text(item, "fileName"), &root);
                entry.insert("path".into(), Json::from(text(item, "fileName")));
                detail = format!("+{} -{}", int(item, "additions"), int(item, "deletions"));
            }
            "file_search" => {
                // What it looked for; a read's file (an ACP agent's `read`).
                label = if summary::is_file_read(item) {
                    "Read file"
                } else {
                    "Searched files"
                }
                .into();
                detail = text(item, "pattern").to_owned();
            }
            "web_search" => {
                label = "Searched the web".into();
                detail = array(item, "patterns")
                    .iter()
                    .map(|p| p.as_str().unwrap_or(""))
                    .collect::<Vec<_>>()
                    .join("\n");
            }
            "dynamic_tool" => {
                label = match item.get("toolName") {
                    Some(Json::String(name)) => name.clone(),
                    _ => "Used tool".into(),
                };
                // Its input; a result's body is not shown.
                match item.get("input") {
                    Some(Json::Object(input)) if !input.is_empty() => {
                        detail = indented(input).trim().to_owned();
                    }
                    Some(Json::String(input)) => detail = input.clone(),
                    _ => {}
                }
            }
            "approval_request" | "user_input_request" => {
                // Answered in the composer; the row records the ask.
                let approval = kind == "approval_request";
                label = if approval {
                    "Approval requested"
                } else {
                    "Input requested"
                }
                .into();
                detail = if approval {
                    text(item, "prompt").to_owned()
                } else {
                    array(item, "questions")
                        .iter()
                        .map(|q| text(as_object(q), "question"))
                        .collect::<Vec<_>>()
                        .join("\n")
                };
                let request = self.entity("runtime-request", text(item, "requestId"));
                if text(request, "decision") == "decline" {
                    entry.insert("statusLabel".into(), Json::from("Declined"));
                } else if text(request, "status") == "pending" {
                    entry.insert(
                        "statusLabel".into(),
                        Json::from(if approval {
                            "Waiting for approval"
                        } else {
                            "Waiting for an answer"
                        }),
                    );
                }
            }
            "todo_list" => {
                label = "Updated plan".into();
                detail = array(item, "steps")
                    .iter()
                    .map(|step| {
                        let step = as_object(step);
                        format!("{}: {}", text(step, "status"), text(step, "text"))
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
            }
            "run_interrupt_request" => {
                label = "Interrupt requested".into();
                detail = text(item, "message").to_owned();
            }
            "run_interrupt_result" => {
                label = "Run interrupted".into();
                detail = text(item, "message").to_owned();
            }
            "system_notice" => label = text(item, "message").to_owned(),
            _ => label = kind.to_owned(),
        }
        if !title.is_empty() && kind != "reasoning" {
            label = title.to_owned();
        }
        entry.insert("label".into(), Json::from(label));
        entry.insert("detail".into(), Json::from(detail));
        Json::Object(entry)
    }

    /// A row's role; None (undefined) where the row has none.
    pub fn data(&self, at: usize, role: Role) -> Option<Json> {
        let row = self.rows.get(at)?;
        match role {
            Role::Id => return Some(Json::from(row.id.as_str())),
            Role::Kind => return Some(Json::from(row.kind)),
            _ => {}
        }
        if row.kind == "fold" {
            return match role {
                Role::Title => Some(Json::from(row.label.as_str())),
                Role::HiddenCount => Some(Json::from(row.hidden)),
                Role::Expanded => Some(Json::from(row.expanded)),
                Role::Time => Some(Json::from(self.stamp(row.at))),
                _ => None,
            };
        }
        if row.kind == "work" {
            let expanded = self.expanded_groups.contains(&row.id) != row.starts_open;
            // A summarized group collapses into its summary alone.
            let shown = if row.summarized {
                0
            } else {
                VISIBLE_WORK_ENTRIES
            };
            return match role {
                Role::Expanded => Some(Json::from(expanded)),
                Role::HiddenCount => Some(Json::from(row.items.len().saturating_sub(shown))),
                Role::Entries => {
                    let first = if expanded {
                        0
                    } else {
                        row.items.len().saturating_sub(shown)
                    };
                    Some(Json::Array(
                        row.items[first..]
                            .iter()
                            .map(|id| self.entry(self.entity("turn-item", id)))
                            .collect(),
                    ))
                }
                Role::Summary | Role::SummaryFailed => {
                    let summary = if row.summarized {
                        summary::summarize(row.items.iter().map(|id| self.entity("turn-item", id)))
                    } else {
                        summary::GroupSummary::default()
                    };
                    Some(if role == Role::Summary {
                        Json::from(summary.text)
                    } else {
                        Json::from(summary.failed)
                    })
                }
                _ => None,
            };
        }

        let item = self.entity("turn-item", row.items.first().map_or("", String::as_str));
        let kind = text(item, "type");
        // A subagent's row follows its entity, which moves on after the
        // turn item.
        let agent = if row.kind == "subagent" {
            self.entity("subagent", text(item, "subagentId"))
        } else {
            &NONE
        };
        let status = text(
            if agent.contains_key("status") {
                agent
            } else {
                item
            },
            "status",
        );
        let failure = object(item, "failure");
        let usage_limit = text(failure, "class") == "usage_limit";
        let value: Json = match role {
            Role::Author => Json::from(if kind == "user_message" {
                "user"
            } else {
                "assistant"
            }),
            Role::Streaming => Json::from(flag(item, "streaming")),
            Role::Status => Json::from(status),
            Role::Marker => Json::from(intent_marker(text(item, "inputIntent"))),
            Role::Intent => Json::from(text(item, "inputIntent")),
            Role::Attribution => {
                // Only a user message has a sender. Nor is what the agent
                // was sent for itself anyone's message (notice_of).
                if kind != "user_message" || row.kind != "message" {
                    Json::from("")
                } else if !text(item, "scheduledTaskId").is_empty() {
                    Json::from("Sent by automation")
                } else if text(item, "createdBy") == "agent" {
                    let sender = text(item, "senderThreadId");
                    let title = match &self.thread_titles {
                        Some(title_of) if !sender.is_empty() => title_of(sender),
                        _ => String::new(),
                    };
                    Json::from(if title.is_empty() {
                        "Sent by another agent".to_owned()
                    } else {
                        format!("From {title}")
                    })
                } else {
                    Json::from("")
                }
            }
            Role::Thread => {
                if row.kind == "subagent" {
                    Json::from(text(item, "childThreadId"))
                } else if kind == "user_message" && text(item, "createdBy") == "agent" {
                    Json::from(text(item, "senderThreadId"))
                } else {
                    Json::from("")
                }
            }
            Role::PullRequestUrl => Json::from(if row.kind == "message" {
                pull_request_url(text(item, "text"))
            } else {
                String::new()
            }),
            Role::Model => Json::from(if row.kind == "subagent" {
                text(agent, "model")
            } else {
                ""
            }),
            Role::Meta => Json::from(row.meta),
            Role::MessageId => Json::from(if kind == "assistant_message" {
                text(item, "messageId")
            } else {
                ""
            }),
            Role::Icon => Json::from(if row.kind == "message" || row.kind == "plan" {
                ""
            } else {
                icon_of(item)
            }),
            Role::Time => Json::from(self.stamp(self.row_time(row))),
            Role::StatusLabel => Json::from(if row.kind == "subagent" {
                subagent_status_label(status)
            } else {
                ""
            }),
            Role::Title => match row.kind {
                "plan" => Json::from(plan_title(text(item, "markdown"))),
                "marker" => Json::from(marker_title(item)),
                // The MC names what it recorded ("Provider retry"); a plain
                // failure is an error.
                "error" if usage_limit => {
                    // One line, the wait named by when it ends.
                    let reset =
                        self.upcoming(time::time_of(failure.get("resetAt"), self.clock.zone));
                    Json::from(if reset.is_empty() {
                        "Usage limit reached.".to_owned()
                    } else {
                        format!("Usage limit reached. Retry after {reset}.")
                    })
                }
                "error" => Json::from(match text(item, "title") {
                    "" => "Error",
                    title => title,
                }),
                "subagent" => Json::from(match text(item, "title").trim() {
                    "" => "Subagent",
                    title => title,
                }),
                _ => return None,
            },
            Role::Text => match row.kind {
                "plan" => Json::from(plan_body(text(item, "markdown"))),
                "marker" => Json::from(marker_detail(item)),
                // The agent's own sentence stays in the conversation.
                "error" if usage_limit => Json::from(""),
                "error" => Json::from(text(failure, "message")),
                "subagent" => {
                    let field = |name: &str| {
                        if agent.contains_key(name) {
                            text(agent, name)
                        } else {
                            text(item, name)
                        }
                    };
                    let detail = summary::subagent_detail(
                        summary::subagent_settled(status),
                        field("progress"),
                        field("result"),
                    );
                    Json::from(if detail.is_empty() {
                        summary::plain_detail(text(item, "prompt"))
                    } else {
                        detail
                    })
                }
                _ => Json::from(text(item, "text")),
            },
            Role::Warning => Json::from(row.kind == "error" && usage_limit),
            Role::Attachments => {
                let mut images = Vec::new();
                if kind == "user_message" {
                    for attachment in array(item, "attachments") {
                        let attachment = as_object(attachment);
                        if text(attachment, "type") != "image" {
                            continue;
                        }
                        let id = text(attachment, "id");
                        let url = self
                            .attachment_urls
                            .get(id)
                            .filter(|known| known.expires_at.is_some_and(|e| e > self.clock.now()))
                            .map_or("", |known| known.url.as_str());
                        images.push(serde_json::json!({
                            "id": id,
                            "name": text(attachment, "name"),
                            "url": url,
                        }));
                    }
                }
                Json::Array(images)
            }
            Role::SentFiles => {
                let mut files = Vec::new();
                if kind == "user_message" {
                    for attachment in array(item, "attachments") {
                        let attachment = as_object(attachment);
                        let kind = text(attachment, "type");
                        if kind == "image" {
                            continue;
                        }
                        let name = text(attachment, "name");
                        let detail = if kind == "file" {
                            let size = data_size(int(attachment, "sizeBytes"));
                            match extension_of(name).to_uppercase() {
                                suffix if suffix.is_empty() => size,
                                suffix => format!("{suffix} · {size}"),
                            }
                        } else {
                            String::new()
                        };
                        files.push(serde_json::json!({
                            "id": text(attachment, "id"),
                            "name": name,
                            "detail": detail,
                        }));
                    }
                }
                Json::Array(files)
            }
            Role::Files => {
                let checkpoint = self.entity("turn-item", &row.checkpoint);
                Json::Array(
                    array(checkpoint, "files")
                        .iter()
                        .map(|file| {
                            let file = as_object(file);
                            serde_json::json!({
                                "path": text(file, "path"),
                                "additions": int(file, "additions"),
                                "deletions": int(file, "deletions"),
                            })
                        })
                        .collect(),
                )
            }
            Role::Expanded
            | Role::HiddenCount
            | Role::Entries
            | Role::Summary
            | Role::SummaryFailed
            | Role::Id
            | Role::Kind => return None,
        };
        Some(value)
    }
}
