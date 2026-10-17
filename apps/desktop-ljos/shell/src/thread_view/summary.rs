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

/// The orchestration tools a summary describes by what they did. The rest
/// of HAL-C2's tools are counted as tools used.
fn orchestration_actions(name: &str) -> &'static str {
    match name {
        "hal_c2_thread_send" => "thread-send",
        "create_threads" | "hal_c2_thread_start" | "hal_c2_thread_launch" => "thread-create",
        "delegate_task" => "delegate",
        "hal_c2_thread_read" => "thread-read",
        "hal_c2_thread_wait" => "thread-wait",
        _ => "",
    }
}

/// resolveHalC2McpToolName: agents prefix the HAL-C2 server's tools their
/// own way (`mcp__hal-c2__x`, `hal-c2.x`, a bare `x`).
fn orchestration_action(tool_name: &str) -> &'static str {
    static DONE: LazyLock<Regex> = LazyLock::new(|| regex(r"(?i)\s+(?:complete|completed)\s*$"));
    static MCP: LazyLock<Regex> = LazyLock::new(|| regex(r"(?i)^mcp__(.+?)__(.+)$"));
    static SCOPED: LazyLock<Regex> =
        LazyLock::new(|| regex(r"(?i)^hal[-_]?c2(?:[.:/]|\s*·\s*)(.+)$"));
    let label = DONE.replace_all(tool_name, "");
    let label = label.trim();
    if let Some(m) = MCP.captures(label) {
        let server = m[1].to_lowercase();
        return if ["hal-c2", "hal_c2", "halc2"].contains(&server.as_str()) {
            orchestration_actions(&m[2])
        } else {
            ""
        };
    }
    if let Some(m) = SCOPED.captures(label) {
        return orchestration_actions(&m[1]);
    }
    orchestration_actions(label)
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
    let times = quantity(selected.len(), "time");

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
            let count = distinct_threads();
            let object = if messages == count && messages > 1 {
                format!("messages to {}", quantity(count, "thread"))
            } else {
                format!(
                    "{} to {}",
                    quantity(messages, "message"),
                    quantity(count, "thread")
                )
            };
            phrase("Sent", "send", &object)
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
            if known {
                format!("Created {}", quantity(created.len(), "thread"))
            } else {
                format!("Requested thread creation {times}")
            }
        }
        "delegate" => {
            let tasks: Vec<Option<String>> = selected
                .iter()
                .map(|c| id_of(c.output.get("taskId")).or_else(|| id_of(c.input.get("taskId"))))
                .collect();
            phrase(
                "Delegated",
                "delegate",
                &quantity(count_entities(&tasks), "task"),
            )
        }
        _ => {
            let targets = if targets_known {
                quantity(distinct_threads(), "thread")
            } else {
                format!("threads {times}")
            };
            if action == "thread-read" {
                phrase("Read", "read", &targets)
            } else {
                phrase("Waited on", "wait on", &targets)
            }
        }
    }
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
        "command" | "edit" | "delegate" | "thread-create" | "thread-send" => 0,
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
    for item in &items {
        let orchestration = if text(item, "type") == "dynamic_tool" {
            orchestration_action(text(item, "toolName"))
        } else {
            ""
        };
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

    let mut labels: Vec<String> = selected.iter().map(|n| n.label.clone()).collect();
    let counted: usize = selected.iter().map(|n| n.count).sum();
    if let Some(remaining) = items.len().checked_sub(counted).filter(|r| *r > 0) {
        labels.push(format!(
            "Performed {remaining} other {}",
            if remaining == 1 { "action" } else { "actions" }
        ));
    }
    for label in labels.iter_mut().skip(1) {
        *label = lower_first(label);
    }
    let sentence = if labels.len() < 3 {
        labels.join(" and ")
    } else {
        let (last, rest) = labels.split_last().expect("three or more");
        format!("{}, and {last}", rest.join(", "))
    };
    GroupSummary {
        text: sentence,
        failed: named.iter().any(|n| n.failed),
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

/// Whether a subagent has stopped working: anything but pending, running
/// or waiting (an idle one has said its piece and waits to be resumed).
pub fn subagent_settled(status: &str) -> bool {
    !matches!(status, "pending" | "running" | "waiting")
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
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Notice {
    pub summary: String,
    pub outcome: String,
}

pub fn notice_of(item: &Obj) -> Option<Notice> {
    static ENVELOPE: LazyLock<Regex> = LazyLock::new(|| {
        regex(
            r#"\A<delegated_task_result taskId="[^"]*" title="([^\n]*)" status="(\w+)" childThreadId="[^"\n]*">"#,
        )
    });
    let kind = text(item, "type");
    if kind == "notification" {
        return Some(Notice {
            summary: text(item, "summary").trim().to_owned(),
            outcome: text(item, "outcome").to_owned(),
        });
    }
    let notification = object(item, "notification");
    if kind.is_empty() && !notification.is_empty() {
        return Some(Notice {
            summary: text(notification, "summary").trim().to_owned(),
            outcome: text(notification, "outcome").to_owned(),
        });
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
                outcome: "cancelled".into()
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
    }
}
