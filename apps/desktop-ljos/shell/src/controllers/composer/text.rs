//! The composer's pure readings and writings of text: what a request is
//! titled, what a sent prompt can be recalled as, the links a send appends
//! for its excerpts, a stash entry's snippet. Lengths are UTF-16 units, as
//! desktop-qt's QString and QML's cursor count them.

use std::collections::{BTreeMap, HashSet};
use std::sync::LazyLock;

use regex::Regex;
use serde_json::json;

use super::kept::{Excerpt, StashEntry};
use crate::composer_model::{slice, utf16_len};
use crate::json::Json;
use crate::thread_view::summary::{Obj, text};

/// The prompt that has the provider implement a proposed plan.
pub const IMPLEMENT_PREFIX: &str = "PLEASE IMPLEMENT THIS PLAN:\n";
/// Why a request cannot be answered when its provider process has ended.
pub const PROVIDER_GONE: &str =
    "Provider process is gone — interrupt or restart the run to respond.";
/// How many prompts the stash keeps.
pub const MAX_STASH_ENTRIES: usize = 20;
/// packages/contracts/src/chatAttachment.ts PROVIDER_SEND_TURN_MAX_INPUT_CHARS.
pub const MAX_PROMPT_CHARS: usize = 120_000;
/// What Claude's ultrathink choice puts at the start of a prompt.
pub const ULTRATHINK_PREFIX: &str = "Ultrathink:\n";
/// packages/contracts/src/assistantCitations.ts: the longest quote or
/// comment, and how much of the reply on either side a citation keeps.
pub const MAX_CITATION_LENGTH: usize = 8000;
pub const CITATION_CONTEXT_LENGTH: usize = 32;

/// A number from a payload, which QML may send as a double.
pub fn number(value: &Json) -> f64 {
    match value {
        Json::Number(n) => n.as_f64().unwrap_or(0.0),
        Json::String(s) => s.trim().parse().unwrap_or(0.0),
        Json::Bool(b) => f64::from(u8::from(*b)),
        _ => 0.0,
    }
}

/// The first `n` UTF-16 units of `text` (QString::left).
pub fn left(text: &str, n: usize) -> &str {
    slice(text, 0, n)
}

/// The last `n` UTF-16 units of `text` (QString::right).
pub fn right(text: &str, n: usize) -> &str {
    let len = utf16_len(text);
    slice(text, len.saturating_sub(n), len)
}

/// `text` with each run of whitespace one space, trimmed (QString::simplified).
pub fn simplified(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The title of an approval whose request names none.
pub fn approval_title(kind: &str) -> &'static str {
    match kind {
        "mcp-elicitation" => "App access approval",
        "command" => "Command approval",
        "file-read" => "File read approval",
        "permission" => "App permission approval",
        _ => "File change approval",
    }
}

/// What is offered when the provider names no options, the primary one first.
pub fn default_approval_options() -> Json {
    let option =
        |decision: &str, label: &str| json!({"decision": decision, "label": label, "warning": ""});
    json!([
        option("accept", "Approve"),
        option("acceptForSession", "Always allow this session"),
        option("decline", "Decline"),
        option("cancel", "Cancel"),
    ])
}

/// A respond failure that means the request is gone (the MC's, and the
/// providers' words apps/tui/src/staleRequest.ts lists): the request closes.
pub fn stale_request(error: &str) -> bool {
    let normalized = error.to_lowercase();
    ["no pending request", "stale pending", "unknown pending"]
        .iter()
        .any(|words| normalized.contains(words))
}

/// The turn items of a kind, in timeline order.
pub fn items_of<'a>(items: &'a BTreeMap<String, Obj>, kind: &str) -> Vec<&'a Obj> {
    let mut found: Vec<&Obj> = items.values().filter(|i| text(i, "type") == kind).collect();
    let ordinal = |item: &Obj| item.get("ordinal").map_or(0.0, number);
    found.sort_by(|a, b| ordinal(a).total_cmp(&ordinal(b)));
    found
}

/// A new thread's title: the prompt, else the first image, cut to 50.
pub fn launch_title(text: &str, first_image: &str) -> String {
    let mut seed = text.trim().to_owned();
    if seed.is_empty() {
        seed = if first_image.is_empty() {
            "New thread".into()
        } else {
            format!("Image: {first_image}")
        };
    }
    if utf16_len(&seed) > 50 {
        format!("{}...", left(&seed, 50))
    } else {
        seed
    }
}

/// What stands for the kept images: an image never changes in place, so its
/// target and id do. `targets` maps a key to its list of kept attachments.
pub fn images_signature(targets: &serde_json::Map<String, Json>) -> String {
    let mut signature = Vec::new();
    for (key, list) in targets {
        for image in list.as_array().into_iter().flatten() {
            let field = |name: &str| image.get(name).and_then(Json::as_str).unwrap_or("");
            signature.push(format!(
                "{key}/{}/{}{}",
                field("id"),
                field("remoteId"),
                field("upload")
            ));
        }
    }
    signature.join("\n")
}

/// The id of the newest of a thread's `message` entities the user sent (not
/// an agent or automation), leaving out `except`; empty for none.
pub fn newest_user_message(messages: &BTreeMap<String, Obj>, except: &HashSet<String>) -> String {
    let mut newest = "";
    let mut newest_at = "";
    for (key, message) in messages {
        let by = text(message, "createdBy");
        if except.contains(key)
            || text(message, "role") != "user"
            || (!by.is_empty() && by != "user")
        {
            continue;
        }
        // The MC's ISO times, to the millisecond, read in order as text.
        let at = text(message, "createdAt");
        if newest.is_empty() || at > newest_at || (at == newest_at && key.as_str() > newest) {
            newest = key;
            newest_at = at;
        }
    }
    newest.to_owned()
}

/// What the user typed of a sent message: without the Ultrathink prefix and
/// the context links a send appends; a plan the app asked to implement is
/// not a prompt.
pub fn recallable(prompt: &str) -> String {
    static CONTEXT_LINK: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r" ?\[[^\]]*\]\(hal-c2-context://[^)]*\)").unwrap());
    let prompt = prompt.trim();
    let prompt = prompt.strip_prefix(ULTRATHINK_PREFIX).unwrap_or(prompt);
    let prompt = CONTEXT_LINK.replace_all(prompt, "");
    let prompt = prompt.trim();
    if prompt.starts_with(IMPLEMENT_PREFIX.trim()) {
        String::new()
    } else {
        prompt.to_owned()
    }
}

/// QUrl::toPercentEncoding: all but `A-Za-z0-9-._~` as %XX of its UTF-8.
fn percent_encoded(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// `[Assistant quote](hal-c2-citation://v1/<environment>/<thread>/<message>?text=...)`.
pub fn citation_link(citation: &Obj) -> String {
    let path: Vec<String> = ["environmentId", "threadId", "messageId"]
        .iter()
        .map(|key| percent_encoded(text(citation, key)))
        .collect();
    let mut query = Vec::new();
    for key in ["text", "start", "end", "prefix", "suffix", "comment"] {
        let Some(value) = citation.get(key) else {
            continue;
        };
        let value = match value {
            Json::String(s) => s.clone(),
            other => (number(other) as i64).to_string(),
        };
        query.push(format!(
            "{key}={}",
            percent_encoded(&value).replace("%20", "+")
        ));
    }
    format!(
        "[Assistant quote](hal-c2-citation://v1/{}?{})",
        path.join("/"),
        query.join("&")
    )
}

/// `n` with en-US thousands grouping: 120,000.
fn grouped(n: usize) -> String {
    let digits = n.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// Why a prompt cannot be sent for its length, else None.
pub fn prompt_problem(text: &str) -> Option<String> {
    let length = utf16_len(text.trim());
    let excess = length.checked_sub(MAX_PROMPT_CHARS).filter(|e| *e > 0)?;
    Some(format!(
        "Prompt is {} {} over the {}-character limit. Shorten or split it before sending.",
        grouped(excess),
        if excess == 1 {
            "character"
        } else {
            "characters"
        },
        grouped(MAX_PROMPT_CHARS)
    ))
}

/// The chip's and the record's name for a note: "src/cart.ts L10-12".
pub fn review_label(file_path: &str, first: i64, last: i64) -> String {
    if first == last {
        format!("{file_path} L{first}")
    } else {
        format!("{file_path} L{first}-{last}")
    }
}

/// A context link's label: no brackets, backslashes or line breaks, one
/// space between words, at most 200 units.
fn link_label(label: &str) -> String {
    static UNSAFE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\[\]\\\r\n]").unwrap());
    let label = UNSAFE.replace_all(label, " ");
    left(&simplified(&label), 200).to_owned()
}

/// Each excerpt is an inline link in the message's text and a record in its
/// `context`; the MC swaps the links for the excerpts when it hands the
/// message to the provider. A quoted reply is only a link, which holds all
/// of it.
pub fn with_excerpts(message: &mut Obj, excerpts: &[Excerpt]) {
    if excerpts.is_empty() {
        return;
    }
    let mut links = Vec::new();
    let mut records = Vec::new();
    for excerpt in excerpts {
        if !excerpt.citation.is_empty() {
            links.push(citation_link(&excerpt.citation));
            continue;
        }
        if !excerpt.review.is_empty() {
            // reviewCommentRecord: the note with the file, the lines and their text.
            let file_path = text(&excerpt.review, "filePath");
            let label = link_label(&review_label(
                file_path,
                excerpt.line_start,
                excerpt.line_end,
            ));
            let context_id = format!("review_{}", excerpt.id);
            links.push(format!(
                "[{label}](hal-c2-context://v1/review-comment/{context_id})"
            ));
            let mut record = excerpt.review.clone();
            record.insert("version".into(), json!(1));
            record.insert("contextId".into(), json!(context_id));
            record.insert("kind".into(), json!("review-comment"));
            record.insert("label".into(), json!(label));
            record.insert("text".into(), json!(excerpt.text));
            records.push(Json::Object(record));
            continue;
        }
        // An excerpt whose text is gone has nothing to send.
        if excerpt.text.trim().is_empty() {
            continue;
        }
        let range = if excerpt.line_start == excerpt.line_end {
            format!("line {}", excerpt.line_start)
        } else {
            format!("lines {}-{}", excerpt.line_start, excerpt.line_end)
        };
        let label = link_label(&format!("{} {range}", excerpt.terminal_label));
        let context_id = format!("terminal_{}", excerpt.id);
        links.push(format!(
            "[{label}](hal-c2-context://v1/terminal/{context_id})"
        ));
        records.push(json!({
            "version": 1,
            "contextId": context_id,
            "kind": "terminal",
            "label": label,
            "terminalId": excerpt.terminal_id,
            "terminalLabel": excerpt.terminal_label,
            "lineStart": excerpt.line_start,
            "lineEnd": excerpt.line_end,
            "text": excerpt.text,
        }));
    }
    // A quote is a link with no record, so the links decide whether anything is added.
    if links.is_empty() {
        return;
    }
    let joined = links.join(" ");
    let current = text(message, "text").to_owned();
    let next = if current.is_empty() {
        joined
    } else {
        format!("{current}\n\n{joined}")
    };
    message.insert("text".into(), json!(next));
    if records.is_empty() {
        return;
    }
    let mut context = message
        .get("context")
        .and_then(Json::as_object)
        .cloned()
        .unwrap_or_default();
    let mut existing = context
        .get("records")
        .and_then(Json::as_array)
        .cloned()
        .unwrap_or_default();
    existing.extend(records);
    context.insert("version".into(), json!(1));
    context.insert("records".into(), Json::Array(existing));
    message.insert("context".into(), Json::Object(context));
}

/// What the stash menu shows of an entry: its text (a quote reads as its
/// text and comment, assistantCitationsToPlainText) on one line, cut to 90;
/// "(empty)" or "(N images)" with none.
pub fn stash_snippet(entry: &StashEntry) -> String {
    let mut snippet = entry.text.clone();
    for excerpt in &entry.excerpts {
        if excerpt.citation.is_empty() {
            continue;
        }
        snippet.push(' ');
        snippet.push_str(text(&excerpt.citation, "text"));
        let comment = text(&excerpt.citation, "comment");
        if !comment.is_empty() {
            snippet.push_str(" Comment: ");
            snippet.push_str(comment);
        }
    }
    let snippet = simplified(&snippet);
    if utf16_len(&snippet) > 90 {
        return format!("{}…", left(&snippet, 90));
    }
    if !snippet.is_empty() {
        return snippet;
    }
    match entry.attachments.len() {
        0 => "(empty)".into(),
        1 => "(1 image)".into(),
        n => format!("({n} images)"),
    }
}

/// QLocale::formattedDataSize with one decimal in IEC units: "512 bytes",
/// "1.5 KiB".
pub fn data_size(bytes: i64) -> String {
    const UNITS: [&str; 6] = ["KiB", "MiB", "GiB", "TiB", "PiB", "EiB"];
    let magnitude = bytes.unsigned_abs();
    if magnitude < 1024 {
        return format!("{bytes} bytes");
    }
    let power = ((63 - magnitude.leading_zeros()) / 10).min(6) as i32;
    let value = bytes as f64 / 1024f64.powi(power);
    format!("{value:.1} {}", UNITS[power as usize - 1])
}

/// What a draft shows in the sidebar: its text's first line, else how many
/// attachments and excerpts it carries; None for an empty draft.
pub fn preview_of(text: &str, carried: usize) -> Option<String> {
    let text = text.trim();
    if !text.is_empty() {
        return Some(text.split('\n').next().unwrap_or_default().to_owned());
    }
    match carried {
        0 => None,
        1 => Some("1 attachment".into()),
        n => Some(format!("{n} attachments")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::controllers::composer::kept::Attachment;

    fn obj(value: Json) -> Obj {
        value.as_object().cloned().unwrap()
    }

    #[test]
    fn approval_titles_name_the_kind() {
        assert_eq!(approval_title("command"), "Command approval");
        assert_eq!(approval_title("mcp-elicitation"), "App access approval");
        assert_eq!(approval_title("file-read"), "File read approval");
        assert_eq!(approval_title("permission"), "App permission approval");
        assert_eq!(approval_title("file-change"), "File change approval");
        assert_eq!(default_approval_options()[0]["decision"], "accept");
        assert_eq!(default_approval_options().as_array().unwrap().len(), 4);
    }

    #[test]
    fn a_stale_request_reads_as_gone() {
        assert!(stale_request("No pending request req-1"));
        assert!(stale_request("Stale pending approval"));
        assert!(stale_request("unknown pending user input"));
        assert!(!stale_request("provider crashed"));
    }

    #[test]
    fn items_come_in_ordinal_order() {
        let mut items = BTreeMap::new();
        items.insert(
            "a".into(),
            obj(json!({"type": "user_message", "ordinal": 3})),
        );
        items.insert(
            "b".into(),
            obj(json!({"type": "user_message", "ordinal": 1.5})),
        );
        items.insert(
            "c".into(),
            obj(json!({"type": "assistant_message", "ordinal": 0})),
        );
        let found = items_of(&items, "user_message");
        assert_eq!(found.len(), 2);
        assert_eq!(found[0]["ordinal"], 1.5);
    }

    #[test]
    fn a_launch_title_is_the_prompt_cut_to_fifty() {
        assert_eq!(launch_title("  fix it ", ""), "fix it");
        assert_eq!(launch_title("", "shot.png"), "Image: shot.png");
        assert_eq!(launch_title(" ", ""), "New thread");
        let long = "x".repeat(60);
        assert_eq!(launch_title(&long, ""), format!("{}...", "x".repeat(50)));
        // UTF-16 units: an emoji is two.
        let emoji = "😀".repeat(30);
        assert_eq!(launch_title(&emoji, ""), format!("{}...", "😀".repeat(25)));
    }

    #[test]
    fn the_images_signature_names_each_image() {
        let targets = obj(json!({
            "t2": [{"id": "b", "remoteId": "", "upload": "failed"}],
            "t1": [{"id": "a", "remoteId": "r1"}],
        }));
        assert_eq!(images_signature(&targets), "t1/a/r1\nt2/b/failed");
    }

    #[test]
    fn the_newest_user_message_skips_agents_and_the_excepted() {
        let mut messages = BTreeMap::new();
        messages.insert(
            "m1".into(),
            obj(json!({"role": "user", "createdAt": "2026-01-01T00:00:01.000Z"})),
        );
        messages.insert(
            "m2".into(),
            obj(json!({"role": "user", "createdAt": "2026-01-01T00:00:03.000Z"})),
        );
        messages.insert(
            "m3".into(),
            obj(json!({"role": "user", "createdBy": "agent", "createdAt": "2026-01-01T00:00:09.000Z"})),
        );
        messages.insert(
            "m4".into(),
            obj(json!({"role": "assistant", "createdAt": "2026-01-01T00:00:09.000Z"})),
        );
        messages.insert(
            "m5".into(),
            obj(json!({"role": "user", "createdAt": "2026-01-01T00:00:03.000Z"})),
        );
        assert_eq!(newest_user_message(&messages, &HashSet::new()), "m5");
        let except = HashSet::from(["m5".to_owned(), "m2".to_owned()]);
        assert_eq!(newest_user_message(&messages, &except), "m1");
        assert_eq!(newest_user_message(&BTreeMap::new(), &HashSet::new()), "");
    }

    #[test]
    fn a_recalled_prompt_is_what_the_user_typed() {
        assert_eq!(recallable("  Ultrathink:\nfix the bug "), "fix the bug");
        assert_eq!(
            recallable("look [Terminal 1 line 2](hal-c2-context://v1/terminal/terminal_x)"),
            "look"
        );
        assert_eq!(recallable("PLEASE IMPLEMENT THIS PLAN:\n# Plan"), "");
    }

    #[test]
    fn a_citation_link_encodes_its_parts() {
        let citation = obj(json!({
            "environmentId": "env 1", "threadId": "t/1", "messageId": "m1",
            "text": "a b&c", "start": 3, "end": 7.0, "comment": "é",
        }));
        assert_eq!(
            citation_link(&citation),
            "[Assistant quote](hal-c2-citation://v1/env%201/t%2F1/m1?text=a+b%26c&start=3&end=7&comment=%C3%A9)"
        );
    }

    #[test]
    fn a_prompt_over_the_limit_says_by_how_much() {
        assert_eq!(prompt_problem(&"a".repeat(MAX_PROMPT_CHARS)), None);
        assert_eq!(
            prompt_problem(&"a".repeat(MAX_PROMPT_CHARS + 1)).unwrap(),
            "Prompt is 1 character over the 120,000-character limit. Shorten or split it before sending."
        );
        assert!(
            prompt_problem(&format!("  {}  ", "a".repeat(MAX_PROMPT_CHARS + 1234)))
                .unwrap()
                .starts_with("Prompt is 1,234 characters over")
        );
    }

    #[test]
    fn a_review_label_names_the_lines() {
        assert_eq!(review_label("src/a.ts", 4, 4), "src/a.ts L4");
        assert_eq!(review_label("src/a.ts", 4, 9), "src/a.ts L4-9");
    }

    fn excerpt(id: &str) -> Excerpt {
        Excerpt {
            id: id.into(),
            line_start: 1,
            line_end: 1,
            ..Excerpt::default()
        }
    }

    #[test]
    fn excerpts_become_links_and_records() {
        let mut message = obj(json!({"text": "look"}));
        let terminal = Excerpt {
            terminal_id: "term-1".into(),
            terminal_label: "Terminal [1]".into(),
            line_start: 2,
            line_end: 4,
            text: "ls".into(),
            ..excerpt("x")
        };
        let blank = Excerpt {
            terminal_label: "T".into(),
            text: "  ".into(),
            ..excerpt("blank")
        };
        let review = Excerpt {
            text: "rename".into(),
            line_start: 10,
            line_end: 10,
            review: obj(json!({"filePath": "src/a.ts", "diff": "+x"})),
            ..excerpt("r")
        };
        let quote = Excerpt {
            citation: obj(
                json!({"environmentId": "e", "threadId": "t", "messageId": "m", "text": "q"}),
            ),
            ..excerpt("c")
        };
        with_excerpts(&mut message, &[terminal, blank, review, quote]);
        assert_eq!(
            message["text"],
            "look\n\n[Terminal 1 lines 2-4](hal-c2-context://v1/terminal/terminal_x) \
             [src/a.ts L10](hal-c2-context://v1/review-comment/review_r) \
             [Assistant quote](hal-c2-citation://v1/e/t/m?text=q)"
        );
        let records = message["context"]["records"].as_array().unwrap();
        assert_eq!(records.len(), 2);
        assert_eq!(records[0]["kind"], "terminal");
        assert_eq!(records[0]["label"], "Terminal 1 lines 2-4");
        assert_eq!(records[1]["kind"], "review-comment");
        assert_eq!(records[1]["diff"], "+x");
        assert_eq!(message["context"]["version"], 1);
    }

    #[test]
    fn a_quote_alone_adds_only_its_link() {
        let mut message = obj(json!({"text": ""}));
        let quote = Excerpt {
            citation: obj(json!({"text": "q"})),
            ..excerpt("c")
        };
        with_excerpts(&mut message, &[quote]);
        assert_eq!(
            message["text"],
            "[Assistant quote](hal-c2-citation://v1///?text=q)"
        );
        assert!(message.get("context").is_none());
    }

    #[test]
    fn a_stash_snippet_reads_on_one_line() {
        let mut entry = StashEntry {
            text: "fix\n\n  the   bug".into(),
            ..StashEntry::default()
        };
        assert_eq!(stash_snippet(&entry), "fix the bug");
        entry.excerpts.push(Excerpt {
            citation: obj(json!({"text": "quoted", "comment": "why"})),
            ..excerpt("c")
        });
        assert_eq!(stash_snippet(&entry), "fix the bug quoted Comment: why");
        entry.text = "y".repeat(100);
        entry.excerpts.clear();
        assert_eq!(stash_snippet(&entry), format!("{}…", "y".repeat(90)));
        entry.text.clear();
        assert_eq!(stash_snippet(&entry), "(empty)");
        entry.attachments.push(Attachment::default());
        assert_eq!(stash_snippet(&entry), "(1 image)");
        entry.attachments.push(Attachment::default());
        assert_eq!(stash_snippet(&entry), "(2 images)");
    }

    #[test]
    fn data_sizes_read_as_qt_writes_them() {
        assert_eq!(data_size(512), "512 bytes");
        assert_eq!(data_size(1024), "1.0 KiB");
        assert_eq!(data_size(1536), "1.5 KiB");
        assert_eq!(data_size(3 * 1024 * 1024), "3.0 MiB");
    }

    #[test]
    fn a_draft_preview_is_its_first_line_or_its_count() {
        assert_eq!(preview_of("  first\nsecond", 3).as_deref(), Some("first"));
        assert_eq!(preview_of("", 1).as_deref(), Some("1 attachment"));
        assert_eq!(preview_of(" ", 2).as_deref(), Some("2 attachments"));
        assert_eq!(preview_of("", 0), None);
    }

    #[test]
    fn left_and_right_count_utf16_units() {
        assert_eq!(left("a😀b", 3), "a😀");
        assert_eq!(right("abcdef", 2), "ef");
        assert_eq!(right("ab", 5), "ab");
    }
}
