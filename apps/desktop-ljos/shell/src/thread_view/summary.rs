//! What a group of tool calls did, in a sentence (desktop-qt's
//! TimelineSummary): "Ran 2 commands and sent messages to 3 threads". At
//! most two kinds of work are named, changes before reads; the rest is
//! counted ("performed 2 other actions"). Failed calls are not counted as
//! work done. Also the small readings of turn items the timeline shares:
//! whether a call failed, a command's label, a subagent's detail, a notice.

use std::collections::HashSet;
use std::sync::LazyLock;

use regex::Regex;
use serde_json::Map;

use crate::json::Json;

pub type Obj = Map<String, Json>;

static EMPTY: LazyLock<Obj> = LazyLock::new(Obj::new);

/// A string field, or "" (QJsonValue::toString).
pub fn text<'a>(object: &'a Obj, field: &str) -> &'a str {
    object.get(field).and_then(Json::as_str).unwrap_or("")
}

/// An object field, or an empty one (QJsonValue::toObject).
pub fn object<'a>(object: &'a Obj, field: &str) -> &'a Obj {
    object
        .get(field)
        .and_then(Json::as_object)
        .unwrap_or(&EMPTY)
}

/// A value as an object, or an empty one.
pub fn as_object(value: &Json) -> &Obj {
    value.as_object().unwrap_or(&EMPTY)
}

/// A bool field, false unless it is `true` (QJsonValue::toBool).
pub fn flag(object: &Obj, field: &str) -> bool {
    object.get(field).and_then(Json::as_bool).unwrap_or(false)
}

/// What a group of calls did, and whether a call it names failed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GroupSummary {
    pub text: String,
    pub failed: bool,
}

fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).expect("a valid pattern")
}

/// One of HAL-C2's own MCP tools (halC2McpToolPresentation): what a summary
/// counts it as and what its row calls it ("Delegate a child task").
#[derive(Clone, Copy)]
struct HalC2Tool {
    action: &'static str,
    verb: &'static str,
    detail: &'static str,
}

/// [name, action, verb, detail]; a tool's summary action groups it.
const HAL_C2_TOOLS: &[[&str; 4]] = &[
    ["link_pull_request", "link-pr", "Link", "a pull request"],
    [
        "unlink_pull_request",
        "unlink-pr",
        "Unlink",
        "a pull request",
    ],
    [
        "list_thread_pull_requests",
        "list-prs",
        "Check",
        "linked pull requests",
    ],
    [
        "orchestrator_capabilities",
        "capabilities",
        "Get",
        "orchestration capabilities",
    ],
    ["delegate_task", "delegate", "Delegate", "a child task"],
    ["task_status", "task-status", "Get", "delegated task status"],
    ["task_cancel", "task-cancel", "Cancel", "delegated task"],
    [
        "schedule_task",
        "schedule-create",
        "Schedule",
        "a recurring task",
    ],
    [
        "list_scheduled_tasks",
        "schedule-list",
        "List",
        "scheduled tasks",
    ],
    [
        "update_scheduled_task",
        "schedule-update",
        "Update",
        "a scheduled task",
    ],
    [
        "delete_scheduled_task",
        "schedule-delete",
        "Delete",
        "a scheduled task",
    ],
    [
        "create_threads",
        "thread-create",
        "Create",
        "HAL-C2 threads",
    ],
    [
        "hal_c2_thread_start",
        "thread-create",
        "Start",
        "a HAL-C2 thread",
    ],
    [
        "hal_c2_thread_list",
        "thread-list",
        "List",
        "HAL-C2 threads",
    ],
    [
        "hal_c2_thread_read",
        "thread-read",
        "Read",
        "a HAL-C2 thread",
    ],
    [
        "hal_c2_thread_send",
        "thread-send",
        "Send",
        "to a HAL-C2 thread",
    ],
    [
        "hal_c2_thread_wait",
        "thread-wait",
        "Wait",
        "for a HAL-C2 thread",
    ],
    [
        "hal_c2_thread_interrupt",
        "thread-interrupt",
        "Interrupt",
        "a HAL-C2 thread",
    ],
    [
        "hal_c2_worktree_handoff",
        "worktree-handoff",
        "Hand off",
        "thread to a git worktree",
    ],
    [
        "hal_c2_worktree_status",
        "worktree-status",
        "Get",
        "thread worktree status",
    ],
    ["preview_status", "browser", "Get", "preview browser status"],
    [
        "preview_open",
        "browser",
        "Open",
        "a page in the preview browser",
    ],
    [
        "preview_navigate",
        "browser",
        "Navigate",
        "the preview browser",
    ],
    [
        "preview_snapshot",
        "browser",
        "Snapshot",
        "the preview page",
    ],
    [
        "preview_click",
        "browser",
        "Click",
        "in the preview browser",
    ],
    [
        "preview_press",
        "browser",
        "Press",
        "a key in the preview browser",
    ],
    ["preview_type", "browser", "Type", "in the preview browser"],
    ["preview_scroll", "browser", "Scroll", "the preview browser"],
    ["preview_resize", "browser", "Resize", "the preview browser"],
    [
        "preview_evaluate",
        "browser",
        "Evaluate",
        "script in the preview browser",
    ],
    [
        "preview_wait_for",
        "browser",
        "Wait",
        "for the preview page",
    ],
    [
        "preview_set_appearance",
        "browser",
        "Set",
        "preview browser appearance",
    ],
    [
        "preview_recording_start",
        "browser",
        "Start",
        "recording the preview browser",
    ],
    [
        "preview_recording_stop",
        "browser",
        "Stop",
        "recording the preview browser",
    ],
    ["device_list", "device", "List", "simulators and emulators"],
    [
        "device_open",
        "device",
        "Open",
        "a device in the Device panel",
    ],
    [
        "device_screenshot",
        "device",
        "Take a screenshot of",
        "the device",
    ],
    ["device_close", "device", "Close", "a device"],
    [
        "run_scheduled_task_now",
        "schedule-run",
        "Run",
        "a scheduled task",
    ],
    ["hal_c2_queue_list", "queue-list", "List", "queued messages"],
    [
        "hal_c2_queue_read",
        "queue-read",
        "Read",
        "a queued message",
    ],
    [
        "hal_c2_queue_edit",
        "queue-edit",
        "Edit",
        "a queued message",
    ],
    [
        "hal_c2_queue_cancel",
        "queue-cancel",
        "Cancel",
        "a queued run",
    ],
    [
        "hal_c2_queue_reorder",
        "queue-reorder",
        "Reorder",
        "a queued run",
    ],
    [
        "hal_c2_queue_promote_to_steer",
        "queue-steer",
        "Steer with",
        "a queued message",
    ],
    [
        "hal_c2_pending_request_list",
        "question-list",
        "List",
        "pending questions",
    ],
    [
        "hal_c2_pending_request_read",
        "question-read",
        "Read",
        "pending questions",
    ],
    [
        "hal_c2_pending_request_respond",
        "question-respond",
        "Answer",
        "pending questions",
    ],
    [
        "hal_c2_thread_configuration",
        "thread-configuration",
        "Read",
        "thread configuration",
    ],
    [
        "hal_c2_thread_configure",
        "thread-configure",
        "Set",
        "thread model",
    ],
    ["hal_c2_thread_fork", "thread-fork", "Fork", "this thread"],
    [
        "hal_c2_thread_merge_back",
        "thread-merge",
        "Merge",
        "thread context",
    ],
    [
        "hal_c2_thread_search",
        "thread-search",
        "Search",
        "thread content",
    ],
    [
        "hal_c2_thread_transfers",
        "thread-transfers",
        "Read",
        "thread transfers",
    ],
    [
        "hal_c2_thread_organize",
        "thread-organize",
        "Organize",
        "a thread",
    ],
    [
        "hal_c2_thread_update",
        "thread-update",
        "Update",
        "HAL-C2 thread metadata",
    ],
    [
        "hal_c2_worktree_list",
        "worktree-list",
        "List",
        "workspace branches",
    ],
    ["hal_c2_preview_list", "browser", "List", "preview tabs"],
    ["hal_c2_preview_close", "browser", "Close", "a preview tab"],
    [
        "hal_c2_environment_read",
        "environment-read",
        "Read",
        "environment preferences",
    ],
    [
        "hal_c2_environment_preferences_update",
        "environment-update",
        "Update",
        "environment preferences",
    ],
    [
        "hal_c2_thread_launch",
        "thread-create",
        "Launch",
        "a project thread",
    ],
    ["hal_c2_project_list", "project-list", "List", "projects"],
    ["hal_c2_project_read", "project-read", "Read", "a project"],
    [
        "hal_c2_project_create",
        "project-create",
        "Register",
        "a project",
    ],
    [
        "hal_c2_project_update",
        "project-update",
        "Update",
        "a project",
    ],
    [
        "hal_c2_project_delete",
        "project-delete",
        "Delete",
        "a project",
    ],
    [
        "hal_c2_project_clone",
        "project-clone",
        "Clone",
        "a repository",
    ],
    [
        "hal_c2_attachment_prepare_upload",
        "attachment-prepare",
        "Prepare",
        "an attachment upload",
    ],
    [
        "hal_c2_attachment_discard",
        "attachment-discard",
        "Discard",
        "a pending attachment",
    ],
    [
        "hal_c2_thread_send_attachments",
        "attachment-send",
        "Send",
        "attachments",
    ],
];

fn hal_c2_tool_named(name: &str) -> Option<HalC2Tool> {
    HAL_C2_TOOLS
        .iter()
        .find(|tool| tool[0] == name)
        .map(|&[_, action, verb, detail]| HalC2Tool {
            action,
            verb,
            detail,
        })
}

/// resolveHalC2McpToolName: agents prefix the HAL-C2 server's tools their
/// own way (`mcp__hal-c2__x`, `hal-c2.x`, `hal-c2 · x`, a bare `x`). Only a
/// name in the inventory counts, and another server's same-named tool is not
/// HAL-C2's.
fn hal_c2_tool(tool_name: &str) -> Option<HalC2Tool> {
    static DONE: LazyLock<Regex> = LazyLock::new(|| regex(r"(?i)\s+(?:complete|completed)\s*$"));
    static MCP: LazyLock<Regex> = LazyLock::new(|| regex(r"(?i)^mcp__(.+?)__(.+)$"));
    static SCOPED: LazyLock<Regex> =
        LazyLock::new(|| regex(r"(?i)^hal[-_]?c2(?:[.:/]|\s*·\s*)(.+)$"));
    static PREFIXED: LazyLock<Regex> =
        LazyLock::new(|| regex(r"(?i)^(?:mcp[-_]{1,2})?hal[-_ ]?c2(?:__|[-_.:/ ])(.+)$"));
    let label = DONE.replace_all(tool_name, "");
    let label = label.trim();
    let name = if let Some(m) = MCP.captures(label) {
        let server = m[1].to_lowercase();
        if !["hal-c2", "hal_c2", "halc2"].contains(&server.as_str()) {
            return None;
        }
        m.get(2).map_or("", |m| m.as_str())
    } else if let Some(m) = SCOPED.captures(label) {
        m.get(1).map_or("", |m| m.as_str())
    } else if hal_c2_tool_named(label).is_some() {
        label
    } else {
        // Bare names start with `hal_c2_` themselves: an exact match wins
        // over the prefix.
        PREFIXED
            .captures(label)
            .and_then(|m| m.get(1))
            .map_or("", |m| m.as_str())
    };
    hal_c2_tool_named(name)
}

fn orchestration_action(tool_name: &str) -> &'static str {
    hal_c2_tool(tool_name).map_or("", |tool| tool.action)
}

/// What a HAL-C2 tool call is called on its row ("Send to a HAL-C2
/// thread"), whichever provider prefix its name carries. Empty for any
/// other tool, including another MCP server's tool of the same name.
pub fn hal_c2_tool_display_name(tool_name: &str) -> String {
    hal_c2_tool(tool_name).map_or_else(String::new, |tool| format!("{} {}", tool.verb, tool.detail))
}

/// An MCP result as the provider adapters keep it: the data it carries and
/// whether it reports an error.
#[derive(Default)]
struct ToolResult {
    data: Obj,
    failed: bool,
}

fn read_result(value: Option<&Json>, depth: u32) -> ToolResult {
    static ERROR_TAG: LazyLock<Regex> = LazyLock::new(|| regex(r"(?:Error|Failure)$"));
    if depth > 4 {
        return ToolResult::default();
    }
    match value {
        Some(Json::String(s)) => match serde_json::from_str::<Json>(s) {
            Ok(parsed @ (Json::Array(_) | Json::Object(_))) => {
                read_result(Some(&parsed), depth + 1)
            }
            Ok(_) => read_result(Some(&Json::Object(Obj::new())), depth + 1),
            Err(_) => ToolResult::default(),
        },
        Some(Json::Array(blocks)) => {
            let mut result = ToolResult::default();
            for block in blocks {
                let record = as_object(block);
                let inner = match record.get("text") {
                    Some(t) => Some(t),
                    None => object(record, "content").get("text"),
                };
                let read = read_result(inner, depth + 1);
                if result.data.is_empty() {
                    result.data = read.data;
                }
                result.failed = result.failed || read.failed;
            }
            result
        }
        Some(Json::Object(record)) => {
            let failed = flag(record, "isError")
                || flag(record, "is_error")
                || ERROR_TAG.is_match(text(record, "_tag"))
                || record.get("error").is_some_and(|e| !e.is_null());
            let content = record
                .get("structuredContent")
                .or_else(|| record.get("content"));
            if let Some(content) = content {
                let mut result = read_result(Some(content), depth + 1);
                result.failed = result.failed || failed;
                return result;
            }
            ToolResult {
                data: record.clone(),
                failed,
            }
        }
        _ => ToolResult::default(),
    }
}

/// Cursor keeps its MCP arguments in an envelope; other adapters keep them
/// as they are.
fn read_input(value: Option<&Json>) -> Obj {
    let input = read_result(value, 0).data;
    if input.get("toolName").is_some_and(Json::is_string) {
        object(&input, "args").clone()
    } else {
        input
    }
}

fn id_of(value: Option<&Json>) -> Option<String> {
    value
        .and_then(Json::as_str)
        .filter(|s| !s.trim().is_empty())
        .map(str::to_owned)
}

/// Distinct ids, plus every call that named none.
fn count_entities(ids: &[Option<String>]) -> usize {
    let known: HashSet<&String> = ids.iter().flatten().collect();
    known.len() + ids.iter().filter(|id| id.is_none()).count()
}

fn quantity(count: usize, noun: &str) -> String {
    format!("{count} {noun}{}", if count == 1 { "" } else { "s" })
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Completed,
    Failed,
    Unfinished,
}

struct Call {
    input: Obj,
    output: Obj,
    outcome: Outcome,
}

fn orchestration_call(item: &Obj) -> Call {
    let result = read_result(item.get("output"), 0);
    let status = text(item, "status");
    let outcome = if result.failed || status == "failed" || status == "declined" {
        Outcome::Failed
    } else if status == "completed" {
        Outcome::Completed
    } else {
        Outcome::Unfinished
    };
    Call {
        input: read_input(item.get("input")),
        output: result.data,
        outcome,
    }
}

/// summarizeHalC2ToolCalls: what the calls that went through did; "Tried
/// to" when none did.
fn orchestration_label(action: &str, calls: &[Call]) -> String {
    let completed: Vec<&Call> = calls
        .iter()
        .filter(|c| c.outcome == Outcome::Completed)
        .collect();
    let selected: Vec<&Call> = if completed.is_empty() {
        calls.iter().collect()
    } else {
        completed.clone()
    };
    let phrase = |past: &str, infinitive: &str, object: &str| {
        if completed.is_empty() {
            format!("Tried to {infinitive} {object}")
        } else {
            format!("{past} {object}")
        }
    };
    let threads: Vec<Option<String>> = selected
        .iter()
        .map(|call| {
            id_of(call.output.get("threadId"))
                .or_else(|| id_of(object(&call.output, "thread").get("threadId")))
                .or_else(|| id_of(call.input.get("threadId")))
        })
        .collect();
    let targets_known = threads.iter().all(Option::is_some);
    let distinct_threads = || threads.iter().flatten().collect::<HashSet<_>>().len();
    let count = selected.len();
    let times = quantity(count, "time");
    // The ids the calls name under `key`, from their result or else their
    // arguments.
    let entities = |key: &str, noun: &str| {
        let ids: Vec<Option<String>> = selected
            .iter()
            .map(|c| id_of(c.output.get(key)).or_else(|| id_of(c.input.get(key))))
            .collect();
        quantity(count_entities(&ids), noun)
    };

    match action {
        "thread-send" => {
            let ids: Vec<Option<String>> = selected
                .iter()
                .map(|c| id_of(c.output.get("messageId")))
                .collect();
            let messages = count_entities(&ids);
            if !targets_known {
                return phrase("Sent", "send", &quantity(messages, "message"));
            }
            let targets = distinct_threads();
            let object = if messages == targets && messages > 1 {
                format!("messages to {}", quantity(targets, "thread"))
            } else {
                format!(
                    "{} to {}",
                    quantity(messages, "message"),
                    quantity(targets, "thread")
                )
            };
            return phrase("Sent", "send", &object);
        }
        "thread-create" => {
            let mut created = HashSet::new();
            let mut known = !completed.is_empty();
            for call in &completed {
                let outputs: Vec<Json> = match call.output.get("threads") {
                    Some(Json::Array(list)) => list.clone(),
                    _ => vec![Json::Object(call.output.clone())],
                };
                for value in &outputs {
                    let thread = as_object(value);
                    if text(thread, "status") == "rolled_back" {
                        continue;
                    }
                    match id_of(thread.get("threadId")) {
                        Some(id) => {
                            created.insert(id);
                        }
                        None => known = false,
                    }
                }
            }
            return if known {
                format!("Created {}", quantity(created.len(), "thread"))
            } else {
                format!("Requested thread creation {times}")
            };
        }
        "thread-read" | "thread-wait" => {
            let targets = if targets_known {
                quantity(distinct_threads(), "thread")
            } else {
                format!("threads {times}")
            };
            return if action == "thread-read" {
                phrase("Read", "read", &targets)
            } else {
                phrase("Waited on", "wait on", &targets)
            };
        }
        "project-read" | "project-create" | "project-update" | "project-delete" => {
            let projects: Vec<Option<String>> = selected
                .iter()
                .map(|c| {
                    id_of(c.output.get("id"))
                        .or_else(|| id_of(c.output.get("projectId")))
                        .or_else(|| id_of(c.input.get("projectId")))
                })
                .collect();
            let object = quantity(count_entities(&projects), "project");
            let (past, infinitive) = match action {
                "project-read" => ("Read", "read"),
                "project-create" => ("Registered", "register"),
                "project-update" => ("Updated", "update"),
                _ => ("Deleted", "delete"),
            };
            return phrase(past, infinitive, &object);
        }
        "attachment-send" => {
            // A message can carry several attachments; retries count by the
            // message.
            let mut messages: Vec<(String, &Call)> = Vec::new();
            for (index, call) in selected.iter().enumerate() {
                let id =
                    id_of(call.output.get("messageId")).unwrap_or_else(|| format!("call-{index}"));
                match messages.iter_mut().find(|(known, _)| *known == id) {
                    Some(entry) => entry.1 = call,
                    None => messages.push((id, call)),
                }
            }
            let mut attachments = 0;
            let mut counts_known = true;
            for (_, call) in &messages {
                let listed = call
                    .input
                    .get("attachments")
                    .and_then(Json::as_array)
                    .map_or(0, Vec::len);
                attachments += listed;
                counts_known = counts_known && listed > 0;
            }
            let targets = if targets_known {
                format!(" to {}", quantity(distinct_threads(), "thread"))
            } else {
                String::new()
            };
            let object = if counts_known {
                quantity(attachments, "attachment") + &targets
            } else {
                format!("attachments{targets} {times}")
            };
            return phrase("Sent", "send", &object);
        }
        "project-clone" => {
            let ids: Vec<Option<String>> = selected
                .iter()
                .map(|c| id_of(c.output.get("cwd")).or_else(|| id_of(c.input.get("cwd"))))
                .collect();
            let repositories = count_entities(&ids);
            let noun = if repositories == 1 {
                "repository"
            } else {
                "repositories"
            };
            return phrase("Cloned", "clone", &format!("{repositories} {noun}"));
        }
        "list-prs" => {
            let object = if count == 1 {
                "linked pull requests".to_owned()
            } else {
                format!("linked pull requests {times}")
            };
            return phrase("Checked", "check", &object);
        }
        "thread-interrupt" | "thread-update" => {
            let object = quantity(count_entities(&threads), "thread");
            return if action == "thread-interrupt" {
                phrase("Requested interrupts for", "interrupt", &object)
            } else {
                phrase("Updated", "update", &object)
            };
        }
        _ => {}
    }

    // The rest name what they acted on by id, by count, or by how often.
    let by_id = match action {
        "delegate" => Some(("taskId", "Delegated", "delegate", "task")),
        "task-cancel" => Some(("taskId", "Requested cancellation of", "cancel", "task")),
        "schedule-create" => Some(("scheduledTaskId", "Scheduled", "schedule", "task")),
        "schedule-update" => Some(("scheduledTaskId", "Updated", "update", "scheduled task")),
        // A delete can report deleted:false; it was still asked for.
        "schedule-delete" => Some((
            "scheduledTaskId",
            "Requested deletion of",
            "delete",
            "scheduled task",
        )),
        "queue-read" => Some(("queuedRunId", "Read", "read", "queued message")),
        "queue-edit" => Some(("queuedRunId", "Edited", "edit", "queued message")),
        "queue-cancel" => Some((
            "queuedRunId",
            "Requested cancellation of",
            "cancel",
            "queued run",
        )),
        "queue-reorder" => Some(("queuedRunId", "Reordered", "reorder", "queued run")),
        "queue-steer" => Some((
            "queuedRunId",
            "Requested steering with",
            "steer with",
            "queued message",
        )),
        "question-read" => Some(("requestId", "Read", "read", "pending question request")),
        "question-respond" => Some((
            "requestId",
            "Answered",
            "answer",
            "pending question request",
        )),
        "worktree-handoff" => Some(("worktreePath", "Handed off to", "hand off to", "worktree")),
        "attachment-prepare" => Some(("attachmentId", "Prepared", "prepare", "attachment upload")),
        "attachment-discard" => {
            Some(("attachmentId", "Discarded", "discard", "pending attachment"))
        }
        _ => None,
    };
    if let Some((key, past, infinitive, noun)) = by_id {
        return phrase(past, infinitive, &entities(key, noun));
    }
    let counted = match action {
        "schedule-run" => Some(("Requested", "request", "scheduled task run")),
        "thread-fork" => Some(("Requested", "request", "thread fork")),
        "thread-merge" => Some(("Requested", "request", "context merge")),
        "link-pr" => Some(("Linked", "link", "pull request")),
        "unlink-pr" => Some(("Unlinked", "unlink", "pull request")),
        _ => None,
    };
    if let Some((past, infinitive, noun)) = counted {
        return phrase(past, infinitive, &quantity(count, noun));
    }
    let (past, infinitive, noun) = match action {
        "thread-list" => ("Listed", "list", "threads"),
        "task-status" => ("Checked", "check", "task status"),
        "schedule-list" => ("Listed", "list", "scheduled tasks"),
        "thread-configuration" => ("Checked", "check", "thread configuration"),
        "thread-configure" => ("Set", "set", "thread model"),
        "thread-search" => ("Searched", "search", "threads"),
        "thread-transfers" => ("Checked", "check", "thread transfers"),
        "thread-organize" => ("Organized", "organize", "threads"),
        "queue-list" => ("Listed", "list", "queued messages"),
        "question-list" => ("Listed", "list", "pending questions"),
        "worktree-list" => ("Listed", "list", "workspace branches"),
        "worktree-status" => ("Checked", "check", "worktree status"),
        "project-list" => ("Listed", "list", "projects"),
        "environment-read" => ("Checked", "check", "environment preferences"),
        "environment-update" => ("Updated", "update", "environment preferences"),
        "browser" => ("Used", "use", "browser"),
        "device" => ("Used", "use", "device controls"),
        "capabilities" => ("Checked", "check", "orchestration capabilities"),
        _ => ("Used", "use", "HAL-C2 tools"),
    };
    phrase(past, infinitive, &format!("{noun} {times}"))
}

/// toolGroupAction: what kind of work a call was.
fn action_of(item: &Obj) -> &'static str {
    static READ: LazyLock<Regex> = LazyLock::new(|| regex(r"(?i)^read(?:\s+file)?$"));
    let kind = text(item, "type");
    if kind == "thread_created" {
        return "thread-create";
    }
    if kind == "approval_request" && text(item, "requestKind") == "file-read" {
        return "read";
    }
    if kind == "dynamic_tool" {
        let title = text(item, "title").trim();
        let name = if title.is_empty() {
            text(item, "toolName").trim()
        } else {
            title
        };
        return if item.contains_key("viewedImagePath") || READ.is_match(name) {
            "read"
        } else {
            "other"
        };
    }
    if is_file_read(item) {
        return "read";
    }
    match kind {
        "file_change" => "edit",
        "command_execution" => "command",
        "file_search" => "code-search",
        "web_search" => "search",
        // Notices and plan updates are news, not tools.
        "system_notice" | "todo_list" | "run_interrupt_request" | "run_interrupt_result" => {
            "update"
        }
        _ => "other",
    }
}

/// toolGroupActionLabel.
fn action_label(action: &str, count: usize) -> String {
    let one = count == 1;
    let (verb, noun, nouns) = match action {
        "read" => ("Read", "file", "files"),
        "edit" => ("Changed", "file", "files"),
        "command" => ("Ran", "command", "commands"),
        "thread-create" => ("Created", "thread", "threads"),
        "search" => ("Searched the web", "time", "times"),
        "code-search" => ("Searched code", "time", "times"),
        "update" => ("Received", "update", "updates"),
        _ => ("Used", "tool", "tools"),
    };
    format!("{verb} {count} {}", if one { noun } else { nouns })
}

/// summaryActionPriority: what changed something comes before what only
/// looked.
fn priority(action: &str) -> u8 {
    match action {
        "command" | "edit" | "delegate" | "task-cancel" | "thread-create" | "thread-send"
        | "thread-interrupt" | "schedule-create" | "schedule-update" | "schedule-delete"
        | "schedule-run" | "thread-configure" | "thread-fork" | "thread-merge"
        | "thread-organize" | "thread-update" | "queue-edit" | "queue-cancel" | "queue-reorder"
        | "queue-steer" | "question-respond" | "worktree-handoff" | "project-create"
        | "project-update" | "project-delete" | "project-clone" | "environment-update"
        | "attachment-prepare" | "attachment-discard" | "attachment-send" => 0,
        "other" | "update" => 2,
        _ => 1,
    }
}

/// A file the agent read: an ACP `read` call, which the MC projects as a
/// file search with the file as its one result.
pub fn is_file_read(item: &Obj) -> bool {
    if text(item, "type") != "file_search" {
        return false;
    }
    let pattern = text(item, "pattern");
    match item.get("results") {
        Some(Json::Array(results)) => {
            results.len() == 1
                && !pattern.is_empty()
                && text(as_object(&results[0]), "fileName") == pattern
        }
        _ => false,
    }
}

/// Whether a call failed: its status, a command's exit code, or an MCP
/// result that carries an error.
pub fn call_failed(item: &Obj) -> bool {
    let status = text(item, "status");
    if status == "failed" || status == "declined" {
        return true;
    }
    let kind = text(item, "type");
    if kind == "command_execution" {
        // QJsonValue::toInt: a whole number, else 0.
        let exit = item
            .get("exitCode")
            .and_then(Json::as_f64)
            .filter(|n| n.fract() == 0.0)
            .unwrap_or(0.0);
        return flag(item, "outputIndicatesFailure") || exit != 0.0;
    }
    kind == "dynamic_tool"
        && !orchestration_action(text(item, "toolName")).is_empty()
        && read_result(item.get("output"), 0).failed
}

/// `items` are the group's turn items, oldest first.
pub fn summarize<'a>(all: impl IntoIterator<Item = &'a Obj>) -> GroupSummary {
    let all: Vec<&Obj> = all.into_iter().collect();
    let items: Vec<&Obj> = all
        .iter()
        .copied()
        .filter(|i| text(i, "type") != "reasoning")
        .collect();
    if items.is_empty() {
        return match all.len() {
            0 => GroupSummary::default(),
            1 => GroupSummary {
                text: "Thought".into(),
                failed: false,
            },
            n => GroupSummary {
                text: format!("Thought (×{n})"),
                failed: false,
            },
        };
    }

    struct Group<'a> {
        key: &'static str,
        orchestration: bool,
        items: Vec<&'a Obj>,
    }
    let mut groups: Vec<Group> = Vec::new();
    // Calls through a browser, the computer or an integration the MC named
    // (`toolSource`) are summed up by what they went through.
    let mut source_keys: Vec<&str> = Vec::new();
    let mut source_names: Vec<String> = Vec::new();
    let mut integrations = true;
    let mut sourced = 0;
    for item in &items {
        let orchestration = if text(item, "type") == "dynamic_tool" {
            orchestration_action(text(item, "toolName"))
        } else {
            ""
        };
        let source = object(item, "toolSource");
        if orchestration.is_empty() && !source.is_empty() {
            sourced += 1;
            let key = text(source, "key");
            if !source_keys.contains(&key) {
                source_keys.push(key);
                source_names.push(text(source, "name").to_owned());
                integrations = integrations && text(source, "kind") == "integration";
            }
            continue;
        }
        let key = if orchestration.is_empty() {
            action_of(item)
        } else {
            orchestration
        };
        match groups.iter_mut().find(|g| g.key == key) {
            Some(group) => group.items.push(item),
            None => groups.push(Group {
                key,
                orchestration: !orchestration.is_empty(),
                items: vec![item],
            }),
        }
    }

    struct Named {
        index: usize,
        count: usize,
        priority: u8,
        label: String,
        failed: bool,
    }
    let named: Vec<Named> = groups
        .iter()
        .enumerate()
        .map(|(index, group)| {
            let (label, failed) = if group.orchestration {
                let calls: Vec<Call> = group.items.iter().map(|i| orchestration_call(i)).collect();
                (
                    orchestration_label(group.key, &calls),
                    calls.iter().any(|c| c.outcome == Outcome::Failed),
                )
            } else {
                let mut count = group.items.len();
                if group.key == "edit" {
                    // Edits count the files they touched.
                    let mut files = HashSet::new();
                    let mut unnamed = 0;
                    for item in &group.items {
                        match text(item, "fileName") {
                            "" => unnamed += 1,
                            file => {
                                files.insert(file);
                            }
                        }
                    }
                    count = files.len() + unnamed;
                }
                (
                    action_label(group.key, count),
                    group.items.iter().any(|i| call_failed(i)),
                )
            };
            Named {
                index,
                count: group.items.len(),
                priority: priority(group.key),
                label,
                failed,
            }
        })
        .collect();

    let mut selected: Vec<&Named> = named.iter().collect();
    selected.sort_by_key(|n| n.priority); // stable
    selected.truncate(2);
    selected.sort_by_key(|n| n.index);

    let mut labels: Vec<String> = Vec::new();
    if !source_names.is_empty() {
        let kind = match (integrations, source_names.len()) {
            (false, _) => "",
            (true, 1) => " integration",
            (true, _) => " integrations",
        };
        labels.push(format!("Used {}{kind}", listed(&source_names)));
    }
    labels.extend(selected.iter().map(|n| n.label.clone()));
    let counted: usize = sourced + selected.iter().map(|n| n.count).sum::<usize>();
    if let Some(remaining) = items.len().checked_sub(counted).filter(|r| *r > 0) {
        labels.push(format!(
            "Performed {remaining} other {}",
            if remaining == 1 { "action" } else { "actions" }
        ));
    }
    for label in labels.iter_mut().skip(1) {
        *label = lower_first(label);
    }
    GroupSummary {
        text: listed(&labels),
        failed: named.iter().any(|n| n.failed),
    }
}

/// "Chrome", "Chrome and Slack", "Chrome, Slack, and Linear".
fn listed(names: &[String]) -> String {
    match names.split_last() {
        Some((last, rest)) if rest.len() >= 2 => format!("{}, and {last}", rest.join(", ")),
        _ => names.join(" and "),
    }
}

fn lower_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(first) => first.to_lowercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// One line of a markdown result: list bullets, code ticks and link
/// targets dropped.
pub fn plain_detail(markdown: &str) -> String {
    static LINK: LazyLock<Regex> = LazyLock::new(|| regex(r"\[([^\]]+)\]\([^)]*\)"));
    static BULLET: LazyLock<Regex> = LazyLock::new(|| regex(r"(?m)^[ \t]*[-*][ \t]+"));
    static SPACE: LazyLock<Regex> = LazyLock::new(|| regex(r"\s+"));
    let plain = LINK.replace_all(markdown, "$1").replace('`', "");
    let plain = BULLET.replace_all(&plain, "");
    SPACE.replace_all(&plain, " ").trim().to_owned()
}

/// A subagent's model the way a person writes it (desktop-qt's
/// SubagentDisplay formatModelSlugName): "gpt-5.4-mini" reads
/// "GPT-5.4-Mini", "claude-opus-4-6" "Claude Opus 4.6"; a provider prefix
/// stays as it is, and a model it does not know keeps its slug.
pub fn subagent_model_name(slug: &str) -> String {
    static CODEX: LazyLock<Regex> = LazyLock::new(|| regex(r"(?i)^gpt-[0-9]"));
    static GPT: LazyLock<Regex> = LazyLock::new(|| regex(r"(?i)^gpt"));
    static DASHED: LazyLock<Regex> = LazyLock::new(|| regex(r"-([a-z])"));
    static KNOWN: LazyLock<Regex> = LazyLock::new(|| {
        regex(r"(?i)^(claude-(opus|sonnet|haiku|fable)|gemini|grok|composer)-[0-9]")
    });
    static VERSION: LazyLock<Regex> =
        LazyLock::new(|| regex(r"(?i)^(claude-[a-z]+-[0-9]+)-([0-9]{1,2})"));
    let separator = slug.rfind('/').map_or(0, |i| i + 1);
    let (prefix, name) = slug.split_at(separator);
    if CODEX.is_match(name) {
        let name = GPT.replace(name, "GPT");
        let name = DASHED.replace_all(&name, |c: &regex::Captures| {
            format!("-{}", c[1].to_uppercase())
        });
        return format!("{prefix}{name}");
    }
    if !KNOWN.is_match(name) {
        return slug.to_owned();
    }
    // "-4-6" is version 4.6 when the minor ends the slug or a part.
    let name = match VERSION.captures(name) {
        Some(c) if matches!(name[c[0].len()..].chars().next(), None | Some('-' | '[')) => {
            format!("{}.{}{}", &c[1], &c[2], &name[c[0].len()..])
        }
        _ => name.to_owned(),
    };
    let parts: Vec<String> = name
        .split('-')
        .map(|part| {
            let mut chars = part.chars();
            chars.next().map_or_else(String::new, |first| {
                first.to_uppercase().chain(chars).collect()
            })
        })
        .collect();
    format!("{prefix}{}", parts.join(" "))
}

/// A subagent's title as shown (desktop-qt's SubagentDisplay displayTitle):
/// without a "Subagent:" prefix, and a "/root/team/review_docs" path as
/// its last part in words, "Review Docs".
pub fn subagent_title(title: &str) -> String {
    static PREFIX: LazyLock<Regex> = LazyLock::new(|| regex(r"(?i)^Subagent:\s*"));
    static PATH: LazyLock<Regex> = LazyLock::new(|| regex(r"^/root/(?:[^/]+/)*([^/]+)/?$"));
    static SPACES: LazyLock<Regex> = LazyLock::new(|| regex(r"[_\s]+"));
    let shown = PREFIX.replace(title, "");
    let Some(found) = PATH.captures(&shown) else {
        return shown.into_owned();
    };
    let words: Vec<String> = SPACES
        .replace_all(&found[1], " ")
        .split_whitespace()
        .map(|word| {
            let mut chars = word.chars();
            chars.next().map_or_else(String::new, |first| {
                first.to_uppercase().chain(chars).collect()
            })
        })
        .collect();
    if words.is_empty() {
        return shown.into_owned();
    }
    words.join(" ")
}

/// Whether a subagent has stopped working: anything but pending, running
/// or waiting (an idle one has said its piece and waits to be resumed).
pub fn subagent_settled(status: &str) -> bool {
    !matches!(status, "pending" | "running" | "waiting")
}

/// Whether a lifecycle status is still working (pending, running,
/// waiting).
pub fn subagent_live(status: &str) -> bool {
    matches!(status, "pending" | "running" | "waiting")
}

/// A group's states counted in the order a reader scans them, what still
/// works first and then the outcomes: "2 working · 1 done · 1 failed"
/// (desktop-qt's subagents::summarizeStatuses).
pub fn summarize_statuses(statuses: &[&str]) -> String {
    let (mut working, mut done, mut failed, mut stopped, mut idle) = (0, 0, 0, 0, 0);
    for status in statuses {
        if subagent_live(status) {
            working += 1;
        } else if *status == "completed" {
            done += 1;
        } else if *status == "failed" {
            failed += 1;
        } else if *status == "idle" {
            idle += 1;
        } else {
            stopped += 1;
        }
    }
    let mut parts = Vec::new();
    for (count, word) in [
        (working, "working"),
        (done, "done"),
        (failed, "failed"),
        (stopped, "stopped"),
        (idle, "idle"),
    ] {
        if count > 0 {
            parts.push(format!("{count} {word}"));
        }
    }
    parts.join(" · ")
}

/// 12s, 3m 04s, 1h 02m (desktop-qt's subagents::formatElapsed).
pub fn format_elapsed(total: i64) -> String {
    let seconds = total.max(0);
    let minutes = seconds / 60;
    if minutes == 0 {
        return format!("{seconds}s");
    }
    let hours = minutes / 60;
    if hours == 0 {
        return format!("{minutes}m {:02}s", seconds % 60);
    }
    format!("{hours}h {:02}m", minutes % 60)
}

/// One span for a group, from its first launch to its last finish: no
/// `end` while a member works or a finished one has no end time, when
/// the span is withheld (or runs to now while it works).
pub struct Span {
    pub start: Option<chrono::DateTime<chrono::Utc>>,
    pub end: Option<chrono::DateTime<chrono::Utc>>,
    pub live: bool,
}

fn time_of(object: &Obj, field: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    let raw = text(object, field);
    chrono::DateTime::parse_from_rfc3339(raw)
        .ok()
        .map(|at| at.with_timezone(&chrono::Utc))
}

/// `members` are `subagent` entities or turn items (status, startedAt,
/// completedAt).
pub fn group_span(members: &[&Obj]) -> Span {
    let mut span = Span {
        start: None,
        end: None,
        live: false,
    };
    let mut end = None;
    let mut end_unknown = false;
    for member in members {
        if let Some(started) = time_of(member, "startedAt")
            && span.start.is_none_or(|start| started < start)
        {
            span.start = Some(started);
        }
        match time_of(member, "completedAt") {
            Some(completed) if end.is_none_or(|e| completed > e) => end = Some(completed),
            Some(_) => {}
            None => end_unknown = true,
        }
        span.live = span.live || subagent_live(text(member, "status"));
    }
    if !span.live && !end_unknown {
        span.end = end;
    }
    span
}

/// What a subagent's row says it did: a settled one its result, else its
/// last progress; a live one the reverse. The server's "Child task ended
/// with status ..." placeholder is dropped, the status already says it.
/// Empty when there is nothing to say.
pub fn subagent_detail(settled: bool, progress: &str, result: &str) -> String {
    static PLACEHOLDER: LazyLock<Regex> =
        LazyLock::new(|| regex(r"(?i)^Child task ended with status\b"));
    let (first, second) = if settled {
        (result.trim(), progress.trim())
    } else {
        (progress.trim(), result.trim())
    };
    let raw = if first.is_empty() { second } else { first };
    if raw.is_empty() || PLACEHOLDER.is_match(raw) {
        String::new()
    } else {
        plain_detail(raw)
    }
}

/// A command as its row labels it (client-runtime commandDisplayText): the
/// script of a lone `sh -c '<script>'` wrapper, its first line, whitespace
/// collapsed.
pub fn command_display_text(command: &str) -> String {
    // sh, bash, zsh, dash or ksh, flags such as -lc, then the script alone.
    static WRAPPER: LazyLock<Regex> = LazyLock::new(|| {
        regex(concat!(
            r#"(?s)^(?:\S*/)?(?:ba|z|da|k)?sh(?:\.exe)?(?:\s+-[A-Za-z]+)*?\s+-[A-Za-z]*c\s+"#,
            r#"(?:'((?:[^']|'\\'')*)'|"((?:[^"\\]|\\.)*)"|([^\s'"]+))$"#
        ))
    });
    static ESCAPED: LazyLock<Regex> = LazyLock::new(|| regex(r"\\(.)"));
    static SPACE: LazyLock<Regex> = LazyLock::new(|| regex(r"\s+"));
    let trimmed = command.trim();
    let mut shown = trimmed.to_owned();
    if let Some(m) = WRAPPER.captures(trimmed) {
        shown = if let Some(single) = m.get(1) {
            single.as_str().replace(r"'\''", "'")
        } else if let Some(double) = m.get(2) {
            ESCAPED.replace_all(double.as_str(), "$1").into_owned()
        } else {
            m.get(3).map_or("", |s| s.as_str()).to_owned()
        };
    }
    let mut shown = shown.trim();
    if shown.is_empty() {
        shown = trimmed;
    }
    let line = shown.split('\n').next().unwrap_or("");
    SPACE.replace_all(line, " ").trim().to_owned()
}

/// What the MC sent the agent for itself: that a delegated task ended, or
/// that the provider woke up for its background work. The MC records it as
/// a `notification` item (`summary`, `outcome`). Threads written before it
/// did hold the message as the user's instead, a delegated task's result as
/// the envelope the agent reads, and are read here as what they stand for.
/// `item` is a turn item, or a queued run's message (which has no `type`).
/// A delegated task's names its worker (`workerThreadId`, `workerTitle`)
/// and carries the worker's result (`detail`, capped by the MC); an older
/// record has none of the three.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Notice {
    pub summary: String,
    pub outcome: String,
    pub worker_thread_id: String,
    pub worker_title: String,
    pub detail: String,
}

fn notice_from(notification: &Obj) -> Notice {
    Notice {
        summary: text(notification, "summary").trim().to_owned(),
        outcome: text(notification, "outcome").to_owned(),
        worker_thread_id: text(notification, "workerThreadId").to_owned(),
        worker_title: text(notification, "workerTitle").trim().to_owned(),
        detail: text(notification, "detail").to_owned(),
    }
}

pub fn notice_of(item: &Obj) -> Option<Notice> {
    static ENVELOPE: LazyLock<Regex> = LazyLock::new(|| {
        regex(
            r#"\A<delegated_task_result taskId="[^"]*" title="([^\n]*)" status="(\w+)" childThreadId="[^"\n]*">"#,
        )
    });
    let kind = text(item, "type");
    if kind == "notification" {
        return Some(notice_from(item));
    }
    let notification = object(item, "notification");
    if kind.is_empty() && !notification.is_empty() {
        return Some(notice_from(notification));
    }
    if !kind.is_empty() && kind != "user_message" {
        return None;
    }
    match text(item, "createdBy") {
        "agent" => {
            // A message another agent sent names its thread, or came in over MCP.
            if text(item, "creationSource") != "provider"
                || !text(item, "senderThreadId").is_empty()
            {
                return None;
            }
            Some(Notice {
                summary: "Background activity updated".into(),
                outcome: "updated".into(),
                ..Notice::default()
            })
        }
        "system" => {
            let m = ENVELOPE.captures(text(item, "text"))?;
            let title = m[1].trim();
            let outcome = match &m[2] {
                s @ ("completed" | "failed") => s.to_owned(),
                _ => "cancelled".to_owned(),
            };
            let ended = match outcome.as_str() {
                "completed" => "finished",
                "failed" => "failed",
                _ => "stopped",
            };
            let title = if title.is_empty() {
                "Delegated task"
            } else {
                title
            };
            Some(Notice {
                summary: format!("{title} {ended}"),
                outcome,
                ..Notice::default()
            })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn obj(v: Json) -> Obj {
        v.as_object().cloned().unwrap()
    }

    fn summary_of(items: Vec<Json>) -> GroupSummary {
        let items: Vec<Obj> = items.into_iter().map(obj).collect();
        summarize(&items)
    }

    #[test]
    fn names_two_kinds_of_work_and_counts_the_rest() {
        let s = summary_of(vec![
            json!({"type": "file_search", "pattern": "x", "status": "completed"}),
            json!({"type": "command_execution", "status": "completed", "exitCode": 0}),
            json!({"type": "file_change", "fileName": "a.rs", "status": "completed"}),
            json!({"type": "file_change", "fileName": "a.rs", "status": "completed"}),
            json!({"type": "web_search", "status": "completed"}),
        ]);
        assert_eq!(
            s.text,
            "Ran 1 command, changed 1 file, and performed 2 other actions"
        );
        assert!(!s.failed);
    }

    #[test]
    fn thinking_alone_is_thought() {
        assert_eq!(summary_of(vec![]).text, "");
        assert_eq!(
            summary_of(vec![json!({"type": "reasoning"})]).text,
            "Thought"
        );
        assert_eq!(
            summary_of(vec![
                json!({"type": "reasoning"}),
                json!({"type": "reasoning"})
            ])
            .text,
            "Thought (×2)"
        );
    }

    #[test]
    fn a_failed_command_marks_the_summary() {
        let s = summary_of(vec![
            json!({"type": "command_execution", "status": "completed", "exitCode": 2}),
            json!({"type": "command_execution", "status": "completed"}),
        ]);
        assert_eq!(s.text, "Ran 2 commands");
        assert!(s.failed);
    }

    #[test]
    fn orchestration_calls_say_what_they_did() {
        let sent = |thread: &str, message: &str| {
            json!({"type": "dynamic_tool", "toolName": "mcp__hal-c2__hal_c2_thread_send", "status": "completed",
                   "output": {"structuredContent": {"threadId": thread, "messageId": message}}})
        };
        let s = summary_of(vec![sent("t1", "m1"), sent("t2", "m2"), sent("t3", "m3")]);
        assert_eq!(s.text, "Sent messages to 3 threads");
        let s = summary_of(vec![json!({
            "type": "dynamic_tool", "toolName": "hal-c2.delegate_task", "status": "failed",
            "input": {"taskId": "task-1"}
        })]);
        assert_eq!(s.text, "Tried to delegate 1 task");
        assert!(s.failed);
        let s = summary_of(vec![json!({
            "type": "dynamic_tool", "toolName": "create_threads", "status": "completed",
            "output": "{\"threads\": [{\"threadId\": \"a\"}, {\"threadId\": \"b\", \"status\": \"rolled_back\"}]}"
        })]);
        assert_eq!(s.text, "Created 1 thread");
        let s = summary_of(vec![json!({
            "type": "dynamic_tool", "toolName": "hal_c2_thread_wait", "status": "completed",
            "output": [{"text": "{\"isError\": true}"}]
        })]);
        assert_eq!(s.text, "Tried to wait on threads 1 time");
        assert!(s.failed);
    }

    #[test]
    fn reads_rank_after_changes() {
        let s = summary_of(vec![
            json!({"type": "dynamic_tool", "toolName": "Read", "status": "completed"}),
            json!({"type": "file_search", "pattern": "a.rs", "results": [{"fileName": "a.rs"}]}),
            json!({"type": "todo_list"}),
            json!({"type": "file_change", "status": "completed"}),
        ]);
        assert_eq!(
            s.text,
            "Read 2 files, changed 1 file, and performed 1 other action"
        );
    }

    #[test]
    fn plain_detail_drops_markdown() {
        assert_eq!(
            plain_detail("- Fixed [the bug](http://x)\n- Ran `cargo test`"),
            "Fixed the bug Ran cargo test"
        );
    }

    #[test]
    fn subagent_models_and_titles_read_as_a_person_writes_them() {
        for (slug, shown) in [
            ("gpt-5.4", "GPT-5.4"),
            ("openai/gpt-5.4-mini", "openai/GPT-5.4-Mini"),
            ("claude-opus-4-6", "Claude Opus 4.6"),
            ("claude-opus-4-6[1m]", "Claude Opus 4.6[1m]"),
            (
                "gemini-2.5-pro-preview-06-05",
                "Gemini 2.5 Pro Preview 06 05",
            ),
            ("custom/model-v2", "custom/model-v2"),
            ("My Custom Model", "My Custom Model"),
            ("claude-opus-4-123", "Claude Opus 4 123"),
        ] {
            assert_eq!(subagent_model_name(slug), shown, "{slug}");
        }
        assert_eq!(subagent_title("Subagent: Fix the cart"), "Fix the cart");
        assert_eq!(subagent_title("/root/baz_qux"), "Baz Qux");
        assert_eq!(subagent_title("/root/team/review_docs/"), "Review Docs");
        assert_eq!(subagent_title("Review the docs"), "Review the docs");
    }

    #[test]
    fn subagent_detail_prefers_result_once_settled() {
        assert_eq!(subagent_detail(true, "working", "done"), "done");
        assert_eq!(subagent_detail(false, "working", "done"), "working");
        assert_eq!(
            subagent_detail(true, "", "Child task ended with status failed"),
            ""
        );
        assert!(subagent_settled("idle"));
        assert!(!subagent_settled("waiting"));
    }

    #[test]
    fn command_display_text_unwraps_shells() {
        assert_eq!(
            command_display_text("/bin/bash -lc 'bun test cart'"),
            "bun test cart"
        );
        assert_eq!(
            command_display_text(r#"sh -c "echo \"hi\"""#),
            r#"echo "hi""#
        );
        assert_eq!(command_display_text("zsh -c ls"), "ls");
        assert_eq!(command_display_text("bash -lc 'it'\\''s'"), "it's");
        assert_eq!(command_display_text("git  status\nmore"), "git status");
        assert_eq!(command_display_text("bash -lc ''"), "bash -lc ''");
    }

    #[test]
    fn notices_of_the_mc_and_of_old_threads() {
        let n = notice_of(&obj(
            json!({"type": "notification", "summary": " Task done ", "outcome": "completed"}),
        ));
        assert_eq!(n.unwrap().summary, "Task done");
        let n = notice_of(&obj(json!({"type": "user_message", "createdBy": "system",
            "text": "<delegated_task_result taskId=\"t\" title=\"Fix it\" status=\"cancelled\" childThreadId=\"c\">\nno"})))
        .unwrap();
        assert_eq!(
            n,
            Notice {
                summary: "Fix it stopped".into(),
                outcome: "cancelled".into(),
                ..Notice::default()
            }
        );
        let n = notice_of(&obj(
            json!({"createdBy": "agent", "creationSource": "provider"}),
        ))
        .unwrap();
        assert_eq!(n.summary, "Background activity updated");
        assert!(notice_of(&obj(json!({"createdBy": "agent", "creationSource": "mcp"}))).is_none());
        assert!(notice_of(&obj(json!({"type": "assistant_message"}))).is_none());
        let n = notice_of(&obj(
            json!({"notification": {"summary": "Queued", "outcome": "x"}}),
        ))
        .unwrap();
        assert_eq!(n.summary, "Queued");
        // A delegated task's names its worker and carries its result.
        let n = notice_of(&obj(
            json!({"type": "notification", "summary": "Tax tests finished",
            "workerThreadId": "w", "workerTitle": " Tax tests ", "detail": "12 tests added"}),
        ))
        .unwrap();
        assert_eq!(
            (
                n.worker_thread_id.as_str(),
                n.worker_title.as_str(),
                n.detail.as_str()
            ),
            ("w", "Tax tests", "12 tests added")
        );
    }
}
