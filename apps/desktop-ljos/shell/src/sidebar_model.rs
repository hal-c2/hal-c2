//! The native sidebar's rules, ported from desktop-qt's SidebarModel: the
//! MC's thread rows in, the `sidebar` view model out. Pure: every clock is
//! passed in.

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};

use chrono::{
    DateTime, Datelike, Duration, FixedOffset, Local, NaiveDate, NaiveDateTime, NaiveTime,
    SecondsFormat, TimeZone, Timelike, Utc,
};
use ljos::locale::{FormatType, Locale};
use serde_json::{Map, Value, json};

const MINUTE_MS: i64 = 60 * 1000;
const HOUR_MS: i64 = 60 * MINUTE_MS;
const DAY_MS: i64 = 24 * HOUR_MS;
const QUEUED_TURN_START_GRACE_MS: i64 = 2 * MINUTE_MS;

/// The settled rows the shelf lists at a time.
pub const SETTLED_PAGE: usize = 50;

pub type Nullable = Option<String>;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct RunSummary {
    pub run_id: String,
    pub status: String,
    pub requested_at: Nullable,
    pub started_at: Nullable,
    pub completed_at: Nullable,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct RuntimeSummary {
    pub status: String,
    pub active_run_id: Nullable,
    pub last_error_class: Nullable,
    pub updated_at: String,
}

/// One thread row of the MC's shell shape, as the sidebar and composer read it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Thread {
    pub environment_id: String,
    pub id: String,
    pub project_id: String,
    pub title: String,
    pub branch: Nullable,
    pub created_at: String,
    pub updated_at: String,
    pub latest_user_message_at: Nullable,
    pub archived_at: Nullable,
    pub subagent: bool,
    pub interaction_mode: String,
    pub runtime_mode: String,
    pub model_selection: Map<String, Value>,
    pub settled_override: Nullable,
    pub settled_at: Nullable,
    pub unsettled_at: Nullable,
    pub snoozed_until: Nullable,
    pub snoozed_at: Nullable,
    pub pinned_at: Nullable,
    pub pin_order_key: Nullable,
    pub active_order_key: Nullable,
    pub last_visited_at: Nullable,
    /// The machine the thread is on its way to, while a move is under way.
    pub moving_to: Nullable,
    pub latest_run_id: Nullable,
    pub active_run_id: Nullable,
    pub activity_run_status: Nullable,
    pub latest_run: Option<RunSummary>,
    pub runtime: Option<RuntimeSummary>,
    pub has_pending_approvals: bool,
    pub has_pending_user_input: bool,
    pub has_actionable_proposed_plan: bool,
    pub pending_background_tasks: usize,
    /// The plugin that started it and what kind of thread it is to that
    /// plugin; one it keeps unlisted opens by id but is not in the list.
    pub plugin_id: String,
    pub plugin_kind: String,
    pub listed: bool,
}

impl Thread {
    /// `environmentId:threadId`.
    pub fn key(&self) -> String {
        format!("{}:{}", self.environment_id, self.id)
    }

    pub fn project_key(&self) -> String {
        format!("{}:{}", self.environment_id, self.project_id)
    }
}

fn string_field(row: &Map<String, Value>, key: &str) -> Nullable {
    row.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn text(row: &Map<String, Value>, key: &str) -> String {
    string_field(row, key).unwrap_or_default()
}

fn present(row: &Map<String, Value>, key: &str) -> bool {
    row.get(key).is_some_and(|v| !v.is_null())
}

fn object<'a>(row: &'a Map<String, Value>, key: &str) -> Option<&'a Map<String, Value>> {
    row.get(key).and_then(Value::as_object)
}

fn terminal_run_status(status: &str) -> bool {
    matches!(
        status,
        "completed" | "interrupted" | "failed" | "cancelled" | "rolled_back"
    )
}

fn active_run_status(status: &str) -> bool {
    matches!(
        status,
        "preparing" | "queued" | "starting" | "running" | "waiting"
    )
}

fn nullable(value: &Nullable) -> Value {
    value.clone().map_or(Value::Null, Value::String)
}

/// Epoch milliseconds of an ISO timestamp, or nothing when it does not
/// parse. One without a zone is local time, as Qt reads it.
pub fn parse_iso(iso: Option<&str>) -> Option<i64> {
    let iso = iso.filter(|s| !s.is_empty())?;
    if let Ok(at) = DateTime::parse_from_rfc3339(iso) {
        return Some(at.timestamp_millis());
    }
    let naive = NaiveDateTime::parse_from_str(iso, "%Y-%m-%dT%H:%M:%S%.f")
        .or_else(|_| NaiveDateTime::parse_from_str(iso, "%Y-%m-%dT%H:%M"))
        .ok()
        .or_else(|| {
            NaiveDate::parse_from_str(iso, "%Y-%m-%d")
                .ok()
                .map(|d| d.and_time(NaiveTime::MIN))
        })?;
    Local
        .from_local_datetime(&naive)
        .earliest()
        .map(|at| at.timestamp_millis())
}

fn parse(iso: &Nullable) -> Option<i64> {
    parse_iso(iso.as_deref())
}

/// `2026-01-05T09:00:00.000Z`.
pub fn format_iso<Tz: TimeZone>(time: &DateTime<Tz>) -> String {
    time.with_timezone(&Utc)
        .to_rfc3339_opts(SecondsFormat::Millis, true)
}

pub fn thread_from_row(environment_id: &str, row: &Map<String, Value>) -> Thread {
    let empty = Map::new();
    let plugin = object(row, "plugin").unwrap_or(&empty);
    let mut thread = Thread {
        environment_id: environment_id.to_owned(),
        id: text(row, "id"),
        project_id: text(row, "projectId"),
        title: text(row, "title"),
        branch: string_field(row, "branch"),
        created_at: text(row, "createdAt"),
        updated_at: text(row, "updatedAt"),
        latest_user_message_at: string_field(row, "latestUserMessageAt"),
        archived_at: string_field(row, "archivedAt"),
        subagent: object(row, "lineage")
            .and_then(|l| l.get("relationshipToParent"))
            .and_then(Value::as_str)
            == Some("subagent"),
        interaction_mode: string_field(row, "interactionMode").unwrap_or_else(|| "default".into()),
        runtime_mode: text(row, "runtimeMode"),
        model_selection: object(row, "modelSelection").cloned().unwrap_or_default(),
        settled_override: string_field(row, "settledOverride"),
        settled_at: string_field(row, "settledAt"),
        unsettled_at: string_field(row, "unsettledAt"),
        snoozed_until: string_field(row, "snoozedUntil"),
        snoozed_at: string_field(row, "snoozedAt"),
        pinned_at: string_field(row, "pinnedAt"),
        pin_order_key: string_field(row, "pinOrderKey"),
        active_order_key: string_field(row, "activeOrderKey"),
        last_visited_at: string_field(row, "lastVisitedAt"),
        moving_to: object(row, "moving").and_then(|m| string_field(m, "label")),
        latest_run_id: string_field(row, "latestRunId"),
        active_run_id: string_field(row, "activeRunId"),
        activity_run_status: string_field(row, "activityRunStatus"),
        has_actionable_proposed_plan: row
            .get("hasActionableProposedPlan")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        pending_background_tasks: row
            .get("pendingBackgroundTasks")
            .and_then(Value::as_array)
            .map_or(0, Vec::len),
        plugin_id: text(plugin, "id"),
        plugin_kind: text(plugin, "kind"),
        listed: plugin
            .get("listed")
            .and_then(Value::as_bool)
            .unwrap_or(true),
        ..Thread::default()
    };
    let status = string_field(row, "status").unwrap_or_else(|| "idle".into());
    if let Some(run_id) = &thread.latest_run_id {
        let completed_at = if row.contains_key("latestRunCompletedAt") {
            string_field(row, "latestRunCompletedAt")
        } else if status == "idle" || terminal_run_status(&status) {
            // Rows from before the MC stamped completion close the run at updatedAt.
            Some(thread.updated_at.clone())
        } else {
            None
        };
        thread.latest_run = Some(RunSummary {
            run_id: run_id.clone(),
            status: if status == "idle" {
                "completed".into()
            } else {
                status.clone()
            },
            requested_at: string_field(row, "latestRunRequestedAt"),
            started_at: string_field(row, "latestRunStartedAt"),
            completed_at,
        });
    }
    if thread.latest_run_id.is_some() || present(row, "activeProviderThreadId") {
        thread.runtime = Some(RuntimeSummary {
            // Background tasks still open after the run park the runtime at
            // idle ("Waiting").
            status: if thread.pending_background_tasks > 0 {
                "idle".into()
            } else {
                thread.activity_run_status.clone().unwrap_or(status)
            },
            active_run_id: thread.active_run_id.clone(),
            last_error_class: string_field(row, "lastErrorClass"),
            updated_at: thread.updated_at.clone(),
        });
    }
    if let Some(request) = object(row, "pendingRuntimeRequest") {
        let kind = request.get("kind").and_then(Value::as_str).unwrap_or("");
        thread.has_pending_user_input = kind == "user_input";
        thread.has_pending_approvals = kind != "user_input" && kind != "auth_refresh";
    }
    thread
}

/// Missing and malformed timestamps sort as the epoch.
fn sortable_ms(iso: &Nullable) -> i64 {
    parse(iso).unwrap_or(0)
}

fn sortable(iso: &str) -> i64 {
    parse_iso(Some(iso)).unwrap_or(0)
}

fn compare_identity(left: &Thread, right: &Thread) -> Ordering {
    left.id
        .cmp(&right.id)
        .then_with(|| left.environment_id.cmp(&right.environment_id))
}

fn sort_pinned(threads: &mut [Thread]) {
    threads.sort_by(|left, right| {
        // User-arranged keys first, keyless pins newest-created below.
        match (&left.pin_order_key, &right.pin_order_key) {
            (Some(_), None) => return Ordering::Less,
            (None, Some(_)) => return Ordering::Greater,
            (Some(l), Some(r)) if l != r => return l.cmp(r),
            (None, None) => {
                let by = sortable(&right.created_at).cmp(&sortable(&left.created_at));
                if by != Ordering::Equal {
                    return by;
                }
            }
            _ => {}
        }
        compare_identity(left, right)
    });
}

fn sort_active(threads: &mut [Thread]) {
    let anchor = |t: &Thread| sortable(&t.created_at).max(sortable_ms(&t.unsettled_at));
    threads.sort_by(|left, right| {
        // New and reopened threads lead; arranged threads follow their keys.
        match (&left.active_order_key, &right.active_order_key) {
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(l), Some(r)) if l != r => return l.cmp(r),
            (None, None) => {
                let by = anchor(right).cmp(&anchor(left));
                if by != Ordering::Equal {
                    return by;
                }
            }
            _ => {}
        }
        compare_identity(left, right)
    });
}

/// Settled rows are history: they order by when the work ended.
fn settled_timestamp(thread: &Thread) -> Nullable {
    if parse(&thread.settled_at).is_some() {
        return thread.settled_at.clone();
    }
    let run = thread.latest_run.as_ref();
    let candidates = [
        thread.latest_user_message_at.clone(),
        run.and_then(|r| r.requested_at.clone()),
        run.and_then(|r| r.started_at.clone()),
        run.and_then(|r| r.completed_at.clone()),
    ];
    let mut latest: Option<(i64, String)> = None;
    for candidate in candidates.into_iter().flatten() {
        if let Some(at) = parse_iso(Some(&candidate))
            && latest.as_ref().is_none_or(|(ms, _)| at > *ms)
        {
            latest = Some((at, candidate));
        }
    }
    if let Some((_, latest)) = latest {
        return Some(latest);
    }
    parse_iso(Some(&thread.updated_at)).map(|_| thread.updated_at.clone())
}

fn sort_settled(threads: &mut [Thread]) {
    threads.sort_by(|left, right| {
        sortable_ms(&settled_timestamp(right))
            .cmp(&sortable_ms(&settled_timestamp(left)))
            .then_with(|| left.id.cmp(&right.id))
    });
}

fn latest_run_settled(thread: &Thread) -> bool {
    let Some(run) = &thread.latest_run else {
        return false;
    };
    if active_run_status(&run.status) {
        return false;
    }
    !thread
        .runtime
        .as_ref()
        .is_some_and(|r| r.active_run_id.as_deref() == Some(run.run_id.as_str()))
}

fn latest_run_completed_after_snooze(thread: &Thread) -> bool {
    let (Some(snoozed_at), Some(run)) = (parse(&thread.snoozed_at), &thread.latest_run) else {
        return false;
    };
    run.status == "completed" && parse(&run.completed_at).is_some_and(|at| at > snoozed_at)
}

pub fn has_queued_turn_start(thread: &Thread, now_ms: i64) -> bool {
    let runtime = thread.runtime.as_ref().map(|r| r.status.as_str());
    if matches!(runtime, Some("preparing" | "queued" | "starting")) {
        return true;
    }
    let Some(message_at) = parse(&thread.latest_user_message_at) else {
        return false;
    };
    if runtime == Some("error") {
        return false;
    }
    // Bounded both ways: the message clock may run ahead of this one.
    if (now_ms - message_at).abs() > QUEUED_TURN_START_GRACE_MS {
        return false;
    }
    let Some(run) = &thread.latest_run else {
        return true;
    };
    for candidate in [&run.requested_at, &run.started_at, &run.completed_at] {
        if candidate.is_none() {
            continue;
        }
        match parse(candidate) {
            Some(at) if at < message_at => {}
            _ => return false,
        }
    }
    true
}

pub fn raised_hand_while_snoozed(thread: &Thread) -> bool {
    if thread.has_pending_approvals || thread.has_pending_user_input {
        return true;
    }
    // Only a failure newer than the snooze raises the hand.
    if let Some(runtime) = &thread.runtime
        && (runtime.status == "error" || runtime.status == "failed")
    {
        if thread.snoozed_at.is_none() {
            return true;
        }
        if let (Some(failed), Some(snoozed)) = (
            parse_iso(Some(&runtime.updated_at)),
            parse(&thread.snoozed_at),
        ) && failed > snoozed
        {
            return true;
        }
    }
    latest_run_completed_after_snooze(thread)
}

pub fn can_snooze(thread: &Thread, now_ms: i64) -> bool {
    !(thread.has_pending_approvals || thread.has_pending_user_input)
        && !has_queued_turn_start(thread, now_ms)
}

pub fn effective_snoozed(thread: &Thread, now_ms: i64) -> bool {
    // Malformed data never hides a thread.
    match parse(&thread.snoozed_until) {
        Some(wake) if wake > now_ms => !raised_hand_while_snoozed(thread),
        _ => false,
    }
}

pub fn woke_at(thread: &Thread, now_ms: i64) -> Nullable {
    let wake = parse(&thread.snoozed_until)?;
    if raised_hand_while_snoozed(thread) {
        if latest_run_completed_after_snooze(thread) {
            return thread.latest_run.as_ref()?.completed_at.clone();
        }
        if let Some(runtime) = &thread.runtime {
            return Some(runtime.updated_at.clone());
        }
        return thread.snoozed_at.clone();
    }
    if wake <= now_ms {
        thread.snoozed_until.clone()
    } else {
        None
    }
}

pub fn wake_label(snoozed_until: &str, now_ms: i64) -> String {
    let Some(wake) = parse_iso(Some(snoozed_until)) else {
        return "now".into();
    };
    let remaining = wake - now_ms;
    let ceil = |value: i64, unit: i64| (value + unit - 1) / unit;
    if remaining <= 0 {
        "now".into()
    } else if remaining < HOUR_MS {
        format!("{}m", ceil(remaining, MINUTE_MS).max(1))
    } else if remaining < DAY_MS {
        format!("{}h", ceil(remaining, HOUR_MS))
    } else {
        format!("{}d", ceil(remaining, DAY_MS))
    }
}

pub fn status(thread: &Thread) -> &'static str {
    if thread.has_pending_approvals {
        return "approval";
    }
    if thread.has_pending_user_input {
        return "input";
    }
    let Some(runtime) = &thread.runtime else {
        return "ready";
    };
    match runtime.status.as_str() {
        s if active_run_status(s) => "working",
        "idle" => "waiting",
        "failed" if runtime.last_error_class.as_deref() == Some("usage_limit") => "limited",
        "failed" => "failed",
        _ => "ready",
    }
}

/// The most urgent of `statuses` (approval, input, working, waiting, then
/// the rest); "ready" when none is.
pub fn most_urgent_status(statuses: &[&str]) -> &'static str {
    [
        "approval", "input", "working", "waiting", "limited", "failed",
    ]
    .into_iter()
    .find(|candidate| statuses.contains(candidate))
    .unwrap_or("ready")
}

/// How long a working thread's run has been going ("3m", "1h 5m"); empty
/// under a minute and for a thread that is not working.
pub fn working_label(thread: &Thread, now_ms: i64) -> String {
    let Some(run) = &thread.latest_run else {
        return String::new();
    };
    if status(thread) != "working" {
        return String::new();
    }
    let started = run.started_at.as_ref().or(run.requested_at.as_ref());
    let Some(started) = parse_iso(started.map(String::as_str)) else {
        return String::new();
    };
    let minutes = (now_ms - started).max(0) / MINUTE_MS;
    match minutes {
        0 => String::new(),
        1..60 => format!("{minutes}m"),
        _ => format!("{}h {}m", minutes / 60, minutes % 60),
    }
}

pub fn unread(thread: &Thread) -> bool {
    let Some(completed) = thread
        .latest_run
        .as_ref()
        .and_then(|r| parse(&r.completed_at))
    else {
        return false;
    };
    if thread.last_visited_at.as_deref().unwrap_or("").is_empty() {
        return false;
    }
    match parse(&thread.last_visited_at) {
        None => true,
        Some(visited) => completed > visited,
    }
}

pub fn status_label(thread: &Thread) -> Nullable {
    if thread.has_pending_approvals {
        return Some("Pending Approval".into());
    }
    if thread.has_pending_user_input {
        return Some("Awaiting Input".into());
    }
    let runtime = thread.runtime.as_ref().map_or("", |r| r.status.as_str());
    let label = match runtime {
        "running" | "waiting" => "Working",
        "preparing" | "starting" | "queued" => "Connecting",
        _ if thread.pending_background_tasks > 0 => "Waiting",
        _ if thread.interaction_mode == "plan"
            && latest_run_settled(thread)
            && thread.has_actionable_proposed_plan =>
        {
            "Plan Ready"
        }
        _ if unread(thread) => "Completed",
        _ => return None,
    };
    Some(label.into())
}

pub fn visible_woke_at(thread: &Thread, now_ms: i64) -> Nullable {
    // A thread settled by hand has nothing left to wake for.
    if thread.settled_override.as_deref() == Some("settled") {
        return None;
    }
    let woke = woke_at(thread, now_ms)?;
    if thread.last_visited_at.is_none() {
        return Some(woke);
    }
    match (parse(&thread.last_visited_at), parse_iso(Some(&woke))) {
        (None, _) => Some(woke),
        (Some(visited), Some(woke_ms)) if visited < woke_ms => Some(woke),
        _ => None,
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Capabilities {
    pub settlement: bool,
    pub snooze: bool,
    /// The MC keeps the visited watermark; without it there are no unread markers.
    pub visited_tracking: bool,
    pub pinning: bool,
    pub title_regeneration: bool,
}

impl Capabilities {
    /// From an environment descriptor's `capabilities` object.
    pub fn from_descriptor(environment: &Map<String, Value>) -> Capabilities {
        let empty = Map::new();
        let caps = object(environment, "capabilities").unwrap_or(&empty);
        let flag = |name: &str| caps.get(name).and_then(Value::as_bool).unwrap_or(false);
        Capabilities {
            settlement: flag("threadSettlement"),
            snooze: flag("threadSnooze"),
            visited_tracking: flag("threadVisitedTracking"),
            pinning: flag("threadPinning"),
            title_regeneration: flag("threadTitleRegeneration"),
        }
    }
}

pub type CapabilitiesFor<'a> = &'a dyn Fn(&str) -> Capabilities;

#[derive(Clone, Debug, Default)]
pub struct Partition {
    pub pinned: Vec<Thread>,
    pub active: Vec<Thread>,
    pub snoozed: Vec<Thread>,
    pub settled: Vec<Thread>,
}

/// `scoped_project_keys` holds `<environmentId>:<projectId>` keys; none
/// means every project.
pub fn partition(
    threads: &[Thread],
    scoped_project_keys: Option<&HashSet<String>>,
    capabilities_for: CapabilitiesFor,
    now_ms: i64,
) -> Partition {
    let mut result = Partition::default();
    for thread in threads {
        // Archived threads are hidden; subagents live in their parent's
        // Agents surface, and a plugin's unlisted threads in what the plugin
        // shows.
        if thread.archived_at.is_some() || thread.subagent || !thread.listed {
            continue;
        }
        if scoped_project_keys.is_some_and(|keys| !keys.contains(&thread.project_key())) {
            continue;
        }
        // Environments without the capability never shelve a thread the user
        // could not bring back.
        let capabilities = capabilities_for(&thread.environment_id);
        let section = if capabilities.snooze && effective_snoozed(thread, now_ms) {
            &mut result.snoozed
        } else if capabilities.settlement && thread.settled_override.as_deref() == Some("settled") {
            &mut result.settled
        } else if thread.pinned_at.is_some() {
            &mut result.pinned
        } else {
            &mut result.active
        };
        section.push(thread.clone());
    }
    sort_pinned(&mut result.pinned);
    sort_active(&mut result.active);
    // Soonest wake first; a tie reads the same whichever MC sent its rows first.
    result.snoozed.sort_by(|left, right| {
        sortable_ms(&left.snoozed_until)
            .cmp(&sortable_ms(&right.snoozed_until))
            .then_with(|| compare_identity(left, right))
    });
    sort_settled(&mut result.settled);
    result
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct RepositoryIdentity {
    pub canonical_key: String,
    pub root_path: Nullable,
    pub display_name: Nullable,
    pub name: Nullable,
}

/// One project row of the MC's shell shape.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Project {
    pub environment_id: String,
    pub id: String,
    pub title: String,
    pub workspace_root: String,
    pub created_at: String,
    pub updated_at: String,
    pub repository_identity: Option<RepositoryIdentity>,
}

impl Project {
    pub fn key(&self) -> String {
        format!("{}:{}", self.environment_id, self.id)
    }
}

pub fn project_from_row(environment_id: &str, row: &Map<String, Value>) -> Project {
    Project {
        environment_id: environment_id.to_owned(),
        id: text(row, "id"),
        title: text(row, "title"),
        workspace_root: text(row, "workspaceRoot"),
        created_at: text(row, "createdAt"),
        updated_at: text(row, "updatedAt"),
        repository_identity: object(row, "repositoryIdentity").map(|fields| RepositoryIdentity {
            canonical_key: text(fields, "canonicalKey"),
            root_path: string_field(fields, "rootPath"),
            display_name: string_field(fields, "displayName"),
            name: string_field(fields, "name"),
        }),
    }
}

fn is_windows_drive_path(value: &str) -> bool {
    let b = value.as_bytes();
    b.len() >= 2
        && b[0].is_ascii_alphabetic()
        && b[1] == b':'
        && (b.len() == 2 || matches!(b[2], b'/' | b'\\'))
}

fn trim_trailing_separators(value: &str) -> String {
    let b = value.as_bytes();
    let is_root = value == "/"
        || value == "\\"
        || (b.len() == 3
            && b[0].is_ascii_alphabetic()
            && b[1] == b':'
            && matches!(b[2], b'/' | b'\\'));
    if value.is_empty() || is_root {
        return value.to_owned();
    }
    let trimmed = if value.starts_with('/') {
        value.trim_end_matches('/')
    } else {
        value.trim_end_matches(['/', '\\'])
    };
    if trimmed.is_empty() {
        return value.to_owned();
    }
    let t = trimmed.as_bytes();
    if t.len() == 2 && t[0].is_ascii_alphabetic() && t[1] == b':' {
        format!("{trimmed}\\")
    } else {
        trimmed.to_owned()
    }
}

/// A workspace path in the form two paths compare in: trimmed, without
/// trailing separators, and Windows paths case- and separator-folded.
pub fn normalize_path(path: &str) -> String {
    let normalized = trim_trailing_separators(path.trim());
    if is_windows_drive_path(&normalized) || normalized.starts_with("\\\\") {
        normalized.replace('/', "\\").to_lowercase()
    } else {
        normalized
    }
}

/// `<environmentId>:<normalized workspace root>`: one folder on one machine.
pub fn physical_key(project: &Project) -> String {
    format!(
        "{}:{}",
        project.environment_id,
        normalize_path(&project.workspace_root)
    )
}

/// Where a project sits under its repository root, "" at the root itself,
/// or nothing when it is outside it.
fn repository_relative_path(project: &Project) -> Nullable {
    let identity = project.repository_identity.as_ref()?;
    let root_path = identity.root_path.as_deref().unwrap_or("").trim();
    if root_path.is_empty() {
        return None;
    }
    let project_path = normalize_path(&project.workspace_root);
    let root = normalize_path(root_path);
    if project_path.is_empty() || root.is_empty() {
        return None;
    }
    if project_path == root {
        return Some(String::new());
    }
    let prefix = format!("{root}{}", if root.contains('\\') { '\\' } else { '/' });
    project_path
        .strip_prefix(&prefix)
        .map(|rest| rest.replace('\\', "/"))
}

fn logical_key(project: &Project, mode: &str) -> String {
    let Some(identity) = project
        .repository_identity
        .as_ref()
        .filter(|i| mode != "separate" && !i.canonical_key.is_empty())
    else {
        return physical_key(project);
    };
    if mode == "repository" {
        return identity.canonical_key.clone();
    }
    match repository_relative_path(project) {
        Some(relative) if !relative.is_empty() => {
            format!("{}::{relative}", identity.canonical_key)
        }
        _ => identity.canonical_key.clone(),
    }
}

fn freshness(project: &Project) -> i64 {
    parse_iso(Some(&project.updated_at))
        .or_else(|| parse_iso(Some(&project.created_at)))
        .unwrap_or(0)
}

fn fresher(candidate: &Project, existing: &Project) -> bool {
    let delta = freshness(candidate) - freshness(existing);
    delta > 0 || (delta == 0 && candidate.id > existing.id)
}

fn unique_non_empty<'a>(values: impl Iterator<Item = &'a str>) -> Vec<&'a str> {
    let mut unique = Vec::new();
    for value in values.map(str::trim) {
        if !value.is_empty() && !unique.contains(&value) {
            unique.push(value);
        }
    }
    unique
}

fn group_label(representative: &Project, members: &[Project]) -> String {
    let titles = unique_non_empty(members.iter().map(|m| m.title.as_str()));
    let identities = || {
        members
            .iter()
            .filter_map(|m| m.repository_identity.as_ref())
    };
    let display_names =
        unique_non_empty(identities().map(|i| i.display_name.as_deref().unwrap_or("")));
    let names = unique_non_empty(identities().map(|i| i.name.as_deref().unwrap_or("")));
    if titles.len() == 1 && !display_names.contains(&titles[0]) && !names.contains(&titles[0]) {
        return titles[0].to_owned();
    }
    if display_names.len() == 1 {
        return display_names[0].to_owned();
    }
    if names.len() == 1 {
        return names[0].to_owned();
    }
    representative.title.clone()
}

const NEVER: f64 = f64::NEG_INFINITY;

fn timestamp(iso: &str) -> f64 {
    parse_iso(Some(iso)).map_or(NEVER, |ms| ms as f64)
}

fn first_timestamp(first: Option<&str>, second: &str) -> f64 {
    parse_iso(first).map_or_else(|| timestamp(second), |ms| ms as f64)
}

fn thread_sort_timestamp(thread: &Thread, sort_order: &str) -> f64 {
    if sort_order == "created_at" {
        return first_timestamp(Some(&thread.created_at), &thread.updated_at);
    }
    if let Some(ms) = parse(&thread.latest_user_message_at) {
        return ms as f64;
    }
    first_timestamp(Some(&thread.updated_at), &thread.created_at)
}

/// QString::localeAwareCompare, without a locale: case folded first.
// TODO(ljos#75): Settings::locale — collation by the user's locale; Ljós
// has no collator yet, so titles compare case-insensitively, then exactly.
pub(crate) fn locale_compare(left: &str, right: &str) -> Ordering {
    left.to_lowercase()
        .cmp(&right.to_lowercase())
        .then_with(|| left.cmp(right))
}

/// The client settings grouping and ordering read: sidebarProjectGroupingMode
/// ("repository", "repository_path" or "separate"), its per-folder overrides
/// keyed by physical key, and sidebarProjectSortOrder ("updated_at",
/// "created_at" or "manual").
#[derive(Clone, Debug, PartialEq)]
pub struct GroupingSettings {
    pub mode: String,
    pub overrides: HashMap<String, String>,
    pub sort_order: String,
}

impl Default for GroupingSettings {
    fn default() -> Self {
        GroupingSettings {
            mode: "repository".into(),
            overrides: HashMap::new(),
            sort_order: "updated_at".into(),
        }
    }
}

/// A logical project: the folders grouped as one, across environments.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ProjectGroup {
    pub key: String,
    /// key, displayName, environmentId, projectId, workspaceRoot
    pub summary: Map<String, Value>,
    /// Every `<environmentId>:<projectId>` the group covers.
    pub member_keys: Vec<String>,
    /// One winning project per folder, the navigation and creation targets.
    pub members: Vec<Project>,
}

/// The logical grouping and sidebar order of every project the shell sees.
pub fn group_projects(
    projects: &[Project],
    settings: &GroupingSettings,
    preferred_environment_id: &str,
    threads: &[Thread],
) -> Vec<ProjectGroup> {
    // Folders in first-seen order, each with every project row claiming it.
    let mut folder_order: Vec<String> = Vec::new();
    let mut by_folder: HashMap<String, Vec<&Project>> = HashMap::new();
    for project in projects {
        let folder = physical_key(project);
        by_folder
            .entry(folder.clone())
            .or_insert_with(|| {
                folder_order.push(folder);
                Vec::new()
            })
            .push(project);
    }

    let mut group_order: Vec<String> = Vec::new();
    let mut members: HashMap<String, Vec<Project>> = HashMap::new();
    let mut logical_by_folder: HashMap<String, String> = HashMap::new();
    for folder in &folder_order {
        let claims = &by_folder[folder];
        let mut winner = claims[0];
        for candidate in claims {
            if fresher(candidate, winner) {
                winner = candidate;
            }
        }
        // The winner names the repository unless only an older row knows it.
        let mut identity_source = winner;
        if winner.repository_identity.is_none() {
            let mut identified: Option<&Project> = None;
            for candidate in claims {
                if candidate.repository_identity.is_some()
                    && identified.is_none_or(|i| fresher(candidate, i))
                {
                    identified = Some(candidate);
                }
            }
            if let Some(identified) = identified {
                identity_source = identified;
            }
        }
        let mode = settings.overrides.get(folder).unwrap_or(&settings.mode);
        let key = logical_key(identity_source, mode);
        logical_by_folder.insert(folder.clone(), key.clone());
        members
            .entry(key.clone())
            .or_insert_with(|| {
                group_order.push(key);
                Vec::new()
            })
            .push(winner.clone());
    }

    let mut member_keys: HashMap<String, Vec<String>> = HashMap::new();
    let mut seen = HashSet::new();
    for project in projects {
        if !seen.insert(project.key()) {
            continue;
        }
        let logical = logical_by_folder
            .get(&physical_key(project))
            .cloned()
            .unwrap_or_default();
        member_keys.entry(logical).or_default().push(project.key());
    }

    struct Sorted {
        group: ProjectGroup,
        title: String,
        at: f64,
    }
    let mut sorted: Vec<Sorted> = Vec::new();
    let mut index_by_project_key: HashMap<String, usize> = HashMap::new();
    for key in &group_order {
        let grouped = &members[key];
        let representative = grouped
            .iter()
            .find(|m| {
                !preferred_environment_id.is_empty() && m.environment_id == preferred_environment_id
            })
            .unwrap_or(&grouped[0]);
        let keys = member_keys.get(key).cloned().unwrap_or_default();
        for member in &keys {
            index_by_project_key.insert(member.clone(), sorted.len());
        }
        let display_name = if grouped.len() > 1 {
            group_label(representative, grouped)
        } else {
            representative.title.clone()
        };
        sorted.push(Sorted {
            group: ProjectGroup {
                key: key.clone(),
                summary: json!({
                    "key": key,
                    "displayName": display_name,
                    "environmentId": representative.environment_id,
                    "projectId": representative.id,
                    "workspaceRoot": representative.workspace_root,
                })
                .as_object()
                .cloned()
                .unwrap_or_default(),
                member_keys: keys,
                members: grouped.clone(),
            },
            title: representative.title.clone(),
            // A group without threads sorts by the representative's own stamps.
            at: if settings.sort_order == "created_at" {
                timestamp(&representative.created_at)
            } else {
                first_timestamp(Some(&representative.updated_at), &representative.created_at)
            },
        });
    }

    // "manual" keeps the given order.
    if settings.sort_order != "manual" {
        let mut with_threads = HashSet::new();
        for thread in threads {
            if thread.archived_at.is_some() {
                continue;
            }
            let Some(&index) = index_by_project_key.get(&thread.project_key()) else {
                continue;
            };
            let at = thread_sort_timestamp(thread, &settings.sort_order);
            let entry = &mut sorted[index];
            entry.at = if with_threads.insert(index) {
                at
            } else {
                entry.at.max(at)
            };
        }
        sorted.sort_by(|left, right| {
            right
                .at
                .partial_cmp(&left.at)
                .unwrap_or(Ordering::Equal)
                .then_with(|| locale_compare(&left.title, &right.title))
                .then_with(|| locale_compare(&left.group.key, &right.group.key))
        });
    }
    sorted.into_iter().map(|s| s.group).collect()
}

/// The project a window with no thread lands in: the first of every project
/// the shell sees in "updated_at" order, whatever order the sidebar is set to.
pub fn most_recent_project(projects: &[Project], threads: &[Thread]) -> Option<Project> {
    let mut latest: HashMap<String, f64> = HashMap::new();
    for thread in threads.iter().filter(|t| t.archived_at.is_none()) {
        let at = thread_sort_timestamp(thread, "updated_at");
        latest
            .entry(thread.project_key())
            .and_modify(|v| *v = v.max(at))
            .or_insert(at);
    }
    let stamp = |p: &Project| {
        latest
            .get(&p.key())
            .copied()
            .unwrap_or_else(|| first_timestamp(Some(&p.updated_at), &p.created_at))
    };
    // Ties go by title, then environment, then id.
    let before = |l: &Project, r: &Project| {
        locale_compare(&l.title, &r.title)
            .then_with(|| l.environment_id.cmp(&r.environment_id))
            .then_with(|| l.id.cmp(&r.id))
            == Ordering::Less
    };
    let mut best: Option<(&Project, f64)> = None;
    for project in projects {
        let at = stamp(project);
        if best.is_none_or(|(b, best_at)| at > best_at || (at == best_at && before(project, b))) {
            best = Some((project, at));
        }
    }
    best.map(|(p, _)| p.clone())
}

/// Where a window that showed the deleted thread `key` goes: the first other
/// thread of its project on its environment in `sort_order`, leaving out the
/// archived and subagent rows the sidebar does not list either.
pub fn fallback_after_delete(threads: &[Thread], key: &str, sort_order: &str) -> Option<String> {
    let deleted = threads.iter().find(|t| t.key() == key)?;
    let mut best: Option<(&Thread, f64)> = None;
    for thread in threads {
        if thread.environment_id != deleted.environment_id
            || thread.project_id != deleted.project_id
            || thread.id == deleted.id
            || thread.archived_at.is_some()
            || thread.subagent
            || !thread.listed
        {
            continue;
        }
        // Ties go to the greater id, as sortThreads.
        let at = thread_sort_timestamp(thread, sort_order);
        if best.is_none_or(|(b, best_at)| at > best_at || (at == best_at && thread.id > b.id)) {
            best = Some((thread, at));
        }
    }
    best.map(|(t, _)| t.key())
}

pub type DescribeWake<'a> = Box<dyn Fn(&str) -> String + 'a>;

/// What `build` reads besides the threads.
pub struct Input<'a> {
    pub projects: Vec<ProjectGroup>,
    /// The environment of the MC the shell runs against; its folders are the
    /// ones the folder explorer lists.
    pub local_environment_id: Nullable,
    /// Whether that MC runs on this machine (`this_machine::hosts`), so a
    /// folder picked here is one of its folders.
    pub local_folders: bool,
    /// Environments that are listed but unreachable; their rows stay, marked
    /// offline, with the actions that need the environment off.
    pub offline_environments: HashSet<String>,
    /// Drafts as the sidebar lists them: draftId, projectKey (logical), label.
    pub drafts: Vec<Value>,
    pub active_thread_key: Nullable,
    pub active_draft_id: Value,
    /// The shortcut labels of the first rows' jump commands (thread.jump.1..9),
    /// in order; each row carries its own while `show_jump_hints`.
    pub jump_labels: Vec<String>,
    pub show_jump_hints: bool,
    /// The rows selected for a bulk action.
    pub selected_keys: HashSet<String>,
    /// A snoozed row's wake time in the user's clock format ("tomorrow
    /// 9:00"); the row has none when unset.
    pub describe_wake: Option<DescribeWake<'a>>,
    /// How many settled rows are listed, and how many more `sidebar.more`
    /// lists (`settledPage` in the view); the open thread is listed past them
    /// besides.
    pub settled_limit: usize,
    pub settled_page: usize,
    /// Whether Settled lists the settled threads a plugin started, such as
    /// code reviews (`sidebarShowSettledPluginThreads`); the open one is
    /// listed either way.
    pub show_settled_plugin_threads: bool,
}

impl Default for Input<'_> {
    fn default() -> Self {
        Input {
            projects: Vec::new(),
            local_environment_id: None,
            local_folders: false,
            offline_environments: HashSet::new(),
            drafts: Vec::new(),
            active_thread_key: None,
            active_draft_id: Value::Null,
            jump_labels: Vec::new(),
            show_jump_hints: false,
            selected_keys: HashSet::new(),
            describe_wake: None,
            settled_limit: SETTLED_PAGE,
            settled_page: SETTLED_PAGE,
            show_settled_plugin_threads: false,
        }
    }
}

impl Input<'_> {
    pub fn group(&self, key: &str) -> Option<&ProjectGroup> {
        self.projects.iter().find(|g| g.key == key)
    }
}

#[derive(Clone, Debug, Default)]
pub struct View {
    pub state: Value,
    /// Rows in the order they render (pinned, active, snoozed, settled), and
    /// which of them are parked (snoozed or settled).
    pub ordered_keys: Vec<String>,
    pub parked_keys: HashSet<String>,
}

/// "5m ago", as the rows' own ages.
fn ago(iso: &str, now_ms: i64) -> String {
    let Some(at) = parse_iso(Some(iso)) else {
        return String::new();
    };
    let seconds = (now_ms - at).max(0) / 1000;
    match seconds {
        0..60 => "just now".into(),
        60..3600 => format!("{}m ago", seconds / 60),
        3600..86400 => format!("{}h ago", seconds / 3600),
        _ => format!("{}d ago", seconds / 86400),
    }
}

pub fn build(
    threads: &[Thread],
    input: &Input,
    scope_project_key: &Nullable,
    capabilities_for: CapabilitiesFor,
    now_ms: i64,
) -> View {
    let mut logical_by_physical: HashMap<&str, &str> = HashMap::new();
    for group in &input.projects {
        for member in &group.member_keys {
            logical_by_physical.insert(member, &group.key);
        }
    }
    let mut thread_counts: HashMap<&str, i64> = HashMap::new();
    let mut thread_statuses: HashMap<&str, Vec<&str>> = HashMap::new();
    for thread in threads.iter().filter(|t| t.archived_at.is_none()) {
        let Some(&logical) = logical_by_physical.get(thread.project_key().as_str()) else {
            continue;
        };
        *thread_counts.entry(logical).or_default() += 1;
        if !thread.subagent && thread.listed {
            thread_statuses
                .entry(logical)
                .or_default()
                .push(status(thread));
        }
    }

    let scoped = scope_project_key.as_deref().and_then(|k| input.group(k));
    let scoped_keys: Option<HashSet<String>> =
        scoped.map(|g| g.member_keys.iter().cloned().collect());
    let mut sections = partition(threads, scoped_keys.as_ref(), capabilities_for, now_ms);
    // Hidden before the shelf pages and counts; search and the plugin's page
    // still find them.
    if !input.show_settled_plugin_threads {
        let open = input.active_thread_key.clone().unwrap_or_default();
        sections
            .settled
            .retain(|thread| thread.plugin_id.is_empty() || thread.key() == open);
    }

    let project_names: HashMap<&str, &str> = input
        .projects
        .iter()
        .map(|g| {
            (
                g.key.as_str(),
                g.summary
                    .get("displayName")
                    .and_then(Value::as_str)
                    .unwrap_or(""),
            )
        })
        .collect();
    let active_key = input.active_thread_key.clone().unwrap_or_default();
    let mut view = View::default();
    let mut convert = |section: &[Thread], snoozed: bool, parked: bool, limit: usize| {
        let mut rows = Vec::new();
        for thread in section {
            let key = thread.key();
            let place = view.ordered_keys.len();
            view.ordered_keys.push(key.clone());
            if parked {
                view.parked_keys.insert(key.clone());
            }
            // The open thread keeps its row past the cap, so opening one
            // from search shows it.
            if rows.len() >= limit && key != active_key {
                continue;
            }
            let physical = thread.project_key();
            let project_key = logical_by_physical
                .get(physical.as_str())
                .map_or(physical.clone(), |k| (*k).to_owned());
            let capabilities = capabilities_for(&thread.environment_id);
            let offline = input.offline_environments.contains(&thread.environment_id);
            let label = status_label(thread);
            let activity = match &label {
                Some(label) => format!("{label} · {}", ago(&thread.updated_at, now_ms)),
                None => format!("Active {}", ago(&thread.updated_at, now_ms)),
            };
            let time_at = if parked && !snoozed {
                nullable(&settled_timestamp(thread))
            } else {
                Value::String(
                    thread
                        .latest_user_message_at
                        .clone()
                        .unwrap_or_else(|| thread.updated_at.clone()),
                )
            };
            let snoozed_until = thread.snoozed_until.as_deref().filter(|_| snoozed);
            rows.push(json!({
                "key": key,
                "threadId": thread.id,
                "environmentId": thread.environment_id,
                "projectKey": project_key,
                "title": thread.title,
                "status": status(thread),
                "statusLabel": nullable(&label),
                "unread": unread(thread),
                "branch": nullable(&thread.branch),
                "createdAt": thread.created_at,
                "latestUserMessageAt": nullable(&thread.latest_user_message_at),
                "updatedAt": thread.updated_at,
                // The time the row's age counts from: a settled row's is the
                // one that orders its shelf, any other's its last message.
                // Never just `updatedAt`, which pinning, snoozing and settling
                // also move.
                "timeAt": time_at,
                "pinned": thread.pinned_at.is_some(),
                "snoozedUntil": nullable(&thread.snoozed_until),
                "wakeLabel": snoozed_until.map_or(Value::Null, |u| wake_label(u, now_ms).into()),
                "wakeDescription": snoozed_until
                    .and_then(|u| input.describe_wake.as_ref().map(|d| d(u)))
                    .map_or(Value::Null, Value::String),
                "workingLabel": working_label(thread, now_ms),
                "selected": input.selected_keys.contains(&key),
                "jumpLabel": if input.show_jump_hints {
                    input.jump_labels.get(place).map_or(Value::Null, |l| l.clone().into())
                } else {
                    Value::Null
                },
                // What resting the pointer on the row shows: its project,
                // branch and latest activity.
                "preview": {
                    "project": project_names.get(project_key.as_str()).copied().unwrap_or(""),
                    "branch": nullable(&thread.branch),
                    "activity": activity,
                },
                "wokeAt": nullable(&visible_woke_at(thread, now_ms)),
                "offline": offline,
                "movingTo": nullable(&thread.moving_to),
                "canSettle": !offline && capabilities.settlement,
                "canSnooze": !offline && capabilities.snooze && can_snooze(thread, now_ms),
                "plugin": if thread.plugin_id.is_empty() {
                    Value::Null
                } else {
                    json!({"id": thread.plugin_id, "kind": thread.plugin_kind})
                },
            }));
        }
        Value::Array(rows)
    };
    let pinned = convert(&sections.pinned, false, false, usize::MAX);
    let active = convert(&sections.active, false, false, usize::MAX);
    let snoozed = convert(&sections.snoozed, true, true, usize::MAX);
    let settled = convert(&sections.settled, false, true, input.settled_limit);

    let projects: Vec<Value> = input
        .projects
        .iter()
        .map(|group| {
            let mut project = group.summary.clone();
            project.insert(
                "threadCount".into(),
                thread_counts
                    .get(group.key.as_str())
                    .copied()
                    .unwrap_or(0)
                    .into(),
            );
            let statuses = thread_statuses
                .get(group.key.as_str())
                .map_or(&[][..], Vec::as_slice);
            project.insert("status".into(), most_urgent_status(statuses).into());
            Value::Object(project)
        })
        .collect();
    let drafts: Vec<Value> = input
        .drafts
        .iter()
        .filter(|draft| {
            scoped.is_none_or(|g| draft.get("projectKey").and_then(Value::as_str) == Some(&g.key))
        })
        .cloned()
        .collect();
    let mut local_projects = Vec::new();
    if let Some(local) = &input.local_environment_id {
        for group in &input.projects {
            for member in group.members.iter().filter(|m| &m.environment_id == local) {
                local_projects.push(json!({
                    "key": member.key(),
                    "logicalProjectKey": group.key,
                    "displayName": member.title,
                    "environmentId": member.environment_id,
                    "projectId": member.id,
                    "workspaceRoot": member.workspace_root,
                }));
            }
        }
    }
    // In the order the rows render.
    let selected: Vec<&String> = view
        .ordered_keys
        .iter()
        .filter(|k| input.selected_keys.contains(*k))
        .collect();
    view.state = json!({
        "localEnvironmentId": nullable(&input.local_environment_id),
        "localProjects": local_projects,
        "localFolders": input.local_folders,
        "projects": projects,
        "scopeProjectKey": nullable(scope_project_key),
        "pinned": pinned,
        "active": active,
        "snoozed": snoozed,
        "settled": settled,
        "settledTotal": sections.settled.len(),
        "settledPage": input.settled_page,
        "drafts": drafts,
        "activeThreadKey": nullable(&input.active_thread_key),
        "activeDraftId": input.active_draft_id,
        "selectedKeys": selected,
    });
    view
}

// The order of the pinned and the active threads is kept as one key per
// thread (pinOrderKey, activeOrderKey): base-26 strings that sort as text,
// so moving a thread writes its own key only.

const ORDER_DIGITS: &[u8] = b"abcdefghijklmnopqrstuvwxyz";

fn valid_order_key(key: &str) -> bool {
    // A trailing lowest digit leaves no room for a key just before this one.
    !key.is_empty()
        && key.bytes().all(|c| c.is_ascii_lowercase())
        && !key.ends_with(ORDER_DIGITS[0] as char)
}

fn digit(c: u8) -> usize {
    (c - b'a') as usize
}

/// The midpoint of two digit strings read as fractions; "" is the open bound.
fn order_midpoint(a: &[u8], b: &[u8]) -> String {
    if !b.is_empty() {
        let mut n = 0;
        while n < b.len() && a.get(n).copied().unwrap_or(ORDER_DIGITS[0]) == b[n] {
            n += 1;
        }
        if n > 0 {
            let head = String::from_utf8_lossy(&b[..n]).into_owned();
            return head + &order_midpoint(a.get(n..).unwrap_or(&[]), &b[n..]);
        }
    }
    let digit_a = a.first().map_or(0, |&c| digit(c));
    let digit_b = b.first().map_or(ORDER_DIGITS.len(), |&c| digit(c));
    if digit_b - digit_a > 1 {
        return (ORDER_DIGITS[(digit_a + digit_b).div_ceil(2)] as char).to_string();
    }
    if b.len() > 1 {
        return (b[0] as char).to_string();
    }
    (ORDER_DIGITS[digit_a] as char).to_string() + &order_midpoint(a.get(1..).unwrap_or(&[]), &[])
}

/// A key strictly between two neighbours; no bound is the section's edge.
/// Nothing when the bounds are corrupt or out of order.
pub fn order_key_between(before: Option<&str>, after: Option<&str>) -> Nullable {
    let a = before.unwrap_or("");
    let b = after.unwrap_or("");
    if (!a.is_empty() && !valid_order_key(a))
        || (!b.is_empty() && !valid_order_key(b))
        || (!b.is_empty() && a >= b)
    {
        return None;
    }
    Some(order_midpoint(a.as_bytes(), b.as_bytes()))
}

/// `count` evenly spaced keys, for a section whose threads have none yet.
pub fn spread_order_keys(count: usize) -> Vec<String> {
    let base = ORDER_DIGITS.len() as f64;
    let mut width = 2;
    let mut space = base * base;
    while space <= ((count + 1) * 2) as f64 {
        width += 1;
        space *= base;
    }
    let step = space / (count + 1) as f64;
    (0..count)
        .map(|index| {
            let mut value = (step * (index + 1) as f64).round() as i64;
            if value % ORDER_DIGITS.len() as i64 == 0 {
                value += 1;
            }
            let mut key = Vec::with_capacity(width);
            for _ in 0..width {
                key.push(ORDER_DIGITS[(value % ORDER_DIGITS.len() as i64) as usize]);
                value /= ORDER_DIGITS.len() as i64;
            }
            key.reverse();
            String::from_utf8_lossy(&key).into_owned()
        })
        .collect()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OrderAssignment {
    /// The thread's key.
    pub key: String,
    pub order_key: String,
}

/// The writes that put `moved_key` where `ordered_keys` (the section as it
/// should read) has it: one for the moved thread between keyed neighbours,
/// or fresh keys for the whole section when a neighbour has none.
/// `order_keys` holds every thread of the section, the ones not shown too,
/// whose keys stay.
pub fn plan_reorder(
    ordered_keys: &[String],
    order_keys: &HashMap<String, Nullable>,
    moved_key: &str,
) -> Vec<OrderAssignment> {
    let Some(moved) = ordered_keys.iter().position(|k| k == moved_key) else {
        return Vec::new();
    };
    let reserved: HashSet<&str> = order_keys
        .iter()
        .filter(|(k, _)| !ordered_keys.contains(k))
        .filter_map(|(_, v)| v.as_deref())
        .collect();
    let key_of = |k: &String| order_keys.get(k).cloned().flatten();
    let has_before = moved > 0;
    let has_after = moved + 1 < ordered_keys.len();
    let before = has_before
        .then(|| key_of(&ordered_keys[moved - 1]))
        .flatten();
    let after = has_after
        .then(|| key_of(&ordered_keys[moved + 1]))
        .flatten();
    if (!has_before || before.is_some()) && (!has_after || after.is_some()) {
        let mut key = order_key_between(before.as_deref(), after.as_deref());
        while let Some(k) = key.as_deref().filter(|k| reserved.contains(k)) {
            key = order_key_between(Some(k), after.as_deref());
        }
        if let Some(key) = key {
            return vec![OrderAssignment {
                key: moved_key.to_owned(),
                order_key: key,
            }];
        }
    }
    // A neighbour without a key (or corrupt ones): the section gets fresh
    // keys in the new order.
    let fresh: Vec<String> = spread_order_keys(ordered_keys.len() + reserved.len())
        .into_iter()
        .filter(|k| !reserved.contains(k.as_str()))
        .collect();
    ordered_keys
        .iter()
        .zip(fresh)
        .filter(|(key, fresh)| key_of(key).as_deref() != Some(fresh.as_str()))
        .map(|(key, fresh)| OrderAssignment {
            key: key.clone(),
            order_key: fresh,
        })
        .collect()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SnoozePreset {
    pub id: String,
    pub label: String,
    pub when_label: String,
    pub snoozed_until: String,
}

/// A wake time the user wrote: a date and a time of day in a zone
/// ("2026-09-25", "08:30"), or an amount of minutes, hours or days from now.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CustomSnooze {
    /// "date" or "duration"
    pub mode: String,
    pub date: String,
    pub time: String,
    pub amount: String,
    /// "minutes", "hours" or "days"
    pub unit: String,
}

/// Nothing for what cannot be read, is not in the future, or is a time of
/// day the zone skips (a daylight saving change).
pub fn resolve_custom_snooze<Tz: TimeZone>(
    input: &CustomSnooze,
    now: DateTime<Utc>,
    zone: &Tz,
) -> Nullable {
    let wake: DateTime<Utc> = if input.mode == "duration" {
        let amount: f64 = input.amount.trim().parse().ok()?;
        if !amount.is_finite() || amount <= 0.0 {
            return None;
        }
        let unit = match input.unit.as_str() {
            "minutes" => MINUTE_MS,
            "days" => DAY_MS,
            _ => HOUR_MS,
        };
        now + Duration::milliseconds((amount * unit as f64).round() as i64)
    } else {
        let digits = |s: &str, shape: &str| {
            s.len() == shape.len()
                && s.bytes().zip(shape.bytes()).all(|(c, p)| {
                    if p == b'9' {
                        c.is_ascii_digit()
                    } else {
                        c == p
                    }
                })
        };
        if !digits(&input.date, "9999-99-99") || !digits(&input.time, "99:99") {
            return None;
        }
        let date = NaiveDate::parse_from_str(&input.date, "%Y-%m-%d").ok()?;
        let time = NaiveTime::parse_from_str(&input.time, "%H:%M").ok()?;
        // A time of day the zone skips resolves to another one: that is not
        // what was asked.
        zone.from_local_datetime(&date.and_time(time))
            .earliest()?
            .with_timezone(&Utc)
    };
    (wake > now).then(|| format_iso(&wake))
}

/// Locale AM/PM separators as plain spaces. Newer CLDR data puts a narrow
/// no-break space (U+202F) before AM and PM, which all but vanishes in the
/// monospace meta lines ("8:46AM"), and some locales use a no-break space
/// (U+00A0) for the same separator. The stamp and the snooze labels built
/// from it are short, so a break at that space costs nothing. The QML stamps
/// that cannot call this (ComposerUsageLimits.qml, ConnectionsSettings.qml)
/// repeat the same character set in a regex; extend both if this set grows.
pub fn plain_spaces(text: &str) -> String {
    text.replace(['\u{202F}', '\u{00A0}'], " ")
}

/// The time of day in the timestampFormat setting, with plain spaces.
pub fn time_of_day<Tz: TimeZone>(local: &DateTime<Tz>, timestamp_format: &str) -> String {
    plain_spaces(&locale_time(local, timestamp_format))
}

/// "12-hour", "24-hour" or "locale", the timestampFormat setting.
fn locale_time<Tz: TimeZone>(local: &DateTime<Tz>, timestamp_format: &str) -> String {
    let (hour, minute) = (local.hour(), local.minute());
    match timestamp_format {
        "12-hour" => {
            let h = match hour % 12 {
                0 => 12,
                h => h,
            };
            format!("{h}:{minute:02} {}", if hour < 12 { "AM" } else { "PM" })
        }
        "24-hour" => format!("{hour:02}:{minute:02}"),
        _ => short_time(hour, minute),
    }
}

thread_local! {
    /// The application's locale, which the "locale" time format writes by;
    /// the shell keeps it ([`use_locale`]). Unit tests read en-US, as
    /// desktop-qt's do.
    static LOCALE: std::cell::RefCell<Locale> = std::cell::RefCell::new(if cfg!(test) {
        Locale::named("en_US")
    } else {
        Locale::system()
    });
}

/// The locale the "locale" time format writes by, as
/// SidebarModel::setLocale sets it.
pub fn use_locale(locale: &Locale) {
    LOCALE.with(|l| *l.borrow_mut() = locale.clone());
}

/// A time of day in the application locale's short time format, with
/// plain spaces: QLocale::toString(time, QLocale::ShortFormat).
pub fn short_time(hour: u32, minute: u32) -> String {
    let at = ljos::locale::DateTime {
        hour,
        minute,
        ..ljos::locale::DateTime::from_unix_ms(0, 0)
    };
    LOCALE.with(|l| plain_spaces(&l.borrow().format_time(&at, FormatType::Short)))
}

/// `date` at `hour`:00 in `zone`; an hour a daylight saving change skips
/// lands on the next one, as QDateTime moves it.
fn local_at<Tz: TimeZone>(zone: &Tz, date: NaiveDate, hour: u32) -> Option<DateTime<Tz>> {
    (hour..24).find_map(|h| {
        zone.from_local_datetime(&date.and_hms_opt(h, 0, 0)?)
            .earliest()
    })
}

const WEEKDAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

fn short_weekday(date: NaiveDate) -> &'static str {
    WEEKDAYS[date.weekday().num_days_from_sunday() as usize]
}

pub fn snooze_presets<Tz: TimeZone>(
    now: &DateTime<Tz>,
    timestamp_format: &str,
) -> Vec<SnoozePreset> {
    let zone = now.timezone();
    let time = |at: &DateTime<Tz>| time_of_day(at, timestamp_format);
    let preset = |id: &str, label: &str, when: String, at: &DateTime<Tz>| SnoozePreset {
        id: id.into(),
        label: label.into(),
        when_label: when,
        snoozed_until: format_iso(at),
    };
    let in_an_hour = now.clone() + Duration::milliseconds(HOUR_MS);
    let in_three_hours = now.clone() + Duration::milliseconds(3 * HOUR_MS);
    let mut presets = vec![
        preset("hour", "In 1 hour", time(&in_an_hour), &in_an_hour),
        preset(
            "three-hours",
            "In 3 hours",
            time(&in_three_hours),
            &in_three_hours,
        ),
    ];
    let today = now.date_naive();
    // "This evening" only while it is meaningfully ahead.
    if let Some(evening) = local_at(&zone, today, 18)
        && (evening.clone() - now.clone()).num_milliseconds() > HOUR_MS
    {
        presets.push(preset("evening", "This evening", time(&evening), &evening));
    }
    // Calendar-day steps, not 24h offsets, so DST days land on the right date.
    let tomorrow = today.succ_opt().and_then(|d| local_at(&zone, d, 9));
    if let Some(tomorrow) = &tomorrow {
        presets.push(preset("tomorrow", "Tomorrow", time(tomorrow), tomorrow));
    }
    let weekday = today.weekday().num_days_from_sunday() as i64; // Sunday = 0, as JavaScript counts
    let until_monday = match (1 - weekday + 7) % 7 {
        0 => 7,
        days => days,
    };
    let next_week = today
        .checked_add_signed(Duration::days(until_monday))
        .and_then(|d| local_at(&zone, d, 9));
    // On Sundays "Tomorrow" already is next week.
    if let Some(next_week) = next_week
        && Some(&next_week) != tomorrow.as_ref()
    {
        let when = format!(
            "{} {}",
            short_weekday(next_week.date_naive()),
            time(&next_week)
        );
        presets.push(preset("next-week", "Next week", when, &next_week));
    }
    presets
}

/// "17:30" today, "tomorrow 9:00", "Mon 9:00", "Jan 5, 9:00".
pub fn wake_description<Tz: TimeZone>(
    snoozed_until: &str,
    now: &DateTime<Tz>,
    timestamp_format: &str,
) -> String {
    let Some(wake_ms) = parse_iso(Some(snoozed_until)) else {
        return String::new();
    };
    let zone = now.timezone();
    let Some(wake) = zone.timestamp_millis_opt(wake_ms).single() else {
        return String::new();
    };
    let time = time_of_day(&wake, timestamp_format);
    let Some(start_of_today) = local_at(&zone, now.date_naive(), 0) else {
        return time;
    };
    let since = (wake.clone() - start_of_today).num_milliseconds();
    let day_delta = since.div_euclid(DAY_MS);
    let date = wake.date_naive();
    match day_delta {
        0 => time,
        1 => format!("tomorrow {time}"),
        d if d < 7 => format!("{} {time}", short_weekday(date)),
        _ => format!("{} {}, {time}", MONTHS[date.month0() as usize], date.day()),
    }
}

/// The local zone's offset now, for callers that hold a UTC clock.
pub fn local_now(now_ms: i64) -> DateTime<FixedOffset> {
    Local
        .timestamp_millis_opt(now_ms)
        .single()
        .map(|t| t.fixed_offset())
        .unwrap_or_else(|| Utc.timestamp_millis_opt(now_ms).unwrap().fixed_offset())
}

#[cfg(test)]
mod tests;
