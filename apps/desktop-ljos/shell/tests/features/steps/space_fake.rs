//! The MC's `space.*` calls faked as the MC answers them, and its
//! `spacePresence` shape: desktop-qt's SpaceSteps.cpp's FakeSpaces and
//! decide(). The `spaces` and `space:<id>` streams are served as every
//! `stream` is (stream.rs); `put` writes them as the C++ does.

use std::collections::{HashMap, HashSet};

use serde_json::{Map, Value, json};

use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, text};
use crate::steps::fake_files::fake_files;
use crate::steps::stream::{Change, FakeStreams, deliver, iso, now};

pub const INDEX: &str = "spaces";
pub const SUMMARY_TITLE: &str = "Release plan";
pub const SUMMARY: &str = "Ship pages on Friday, once the Space streams are in.";
pub const GENERATED: &str = "generated";

pub fn stream_of(space_id: &str) -> String {
    format!("space:{space_id}")
}

pub struct Answer {
    pub result: Value,
    pub error: String,
    pub detail: Value,
}

impl Answer {
    fn ok(result: Value) -> Answer {
        Answer {
            result,
            error: String::new(),
            detail: Value::Null,
        }
    }
}

fn refused(reason: &str, message: &str) -> Answer {
    refused_tag(reason, message, "SpaceError")
}

fn refused_tag(reason: &str, message: &str, tag: &str) -> Answer {
    Answer {
        result: Value::Null,
        error: message.to_owned(),
        detail: json!({"_tag": tag, "reason": reason, "message": message}),
    }
}

#[derive(Clone)]
pub struct FakeVersion {
    pub version: i64,
    pub at: String,
    pub author: Value,
    pub restored_from_at: String,
    pub content: Value,
}

pub struct FakeSpaces {
    pub versions: HashMap<String, Vec<FakeVersion>>,
    pub paused: bool,
    pub ids: i64,
    pub clock: i64,
    pub talked: HashSet<String>,
    pub generation: String,
    pub writes: String,
    pub image_generation: String,
    pub grok: bool,
    pub signed_images: Vec<String>,
    pub cwd: String,
    pub summarised: String,
    pub refuse_ask: bool,
    pub kept_words: String,
    pub ignores_stop: bool,
    pub stops: i64,
    pub last_ask: Value,
    pub chart: Value,
    pub asked: String,
    pub last_method: String,
    pub last_error: String,
    pub last_result: Value,
    pub named: HashMap<String, String>,
    pub current: String,
    pub address: String,
    pub local_only: bool,
    pub tailnet: String,
    pub links: HashMap<String, String>,
    pub mark: usize,
    pub devices: HashMap<String, Vec<String>>,
    pub agents: HashMap<String, Vec<String>>,
    pub viewers_refused: bool,
    pub scan: String,
    pub syncs: i64,
    pub listings: i64,
    pub link: String,
    pub on_worktree: bool,
    pub project_files: HashMap<String, std::collections::BTreeMap<String, String>>,
}

impl Default for FakeSpaces {
    fn default() -> FakeSpaces {
        FakeSpaces {
            versions: HashMap::new(),
            paused: false,
            ids: 0,
            clock: 0,
            talked: HashSet::new(),
            generation: "available".into(),
            writes: String::new(),
            image_generation: "available".into(),
            grok: false,
            signed_images: Vec::new(),
            cwd: String::new(),
            summarised: String::new(),
            refuse_ask: false,
            kept_words: String::new(),
            ignores_stop: false,
            stops: 0,
            last_ask: Value::Null,
            chart: json!({}),
            asked: String::new(),
            last_method: String::new(),
            last_error: String::new(),
            last_result: Value::Null,
            named: HashMap::new(),
            current: String::new(),
            address: "http://192.168.1.20:3773".into(),
            local_only: false,
            tailnet: String::new(),
            links: HashMap::new(),
            mark: 0,
            devices: HashMap::new(),
            agents: HashMap::new(),
            viewers_refused: false,
            scan: "written".into(),
            syncs: 0,
            listings: 0,
            link: String::new(),
            on_worktree: false,
            project_files: HashMap::new(),
        }
    }
}

pub fn fake(mc: &mut FakeMc) -> &mut FakeSpaces {
    mc.part::<FakeSpaces>()
}

pub fn stamp(mc: &mut FakeMc) -> String {
    let clock = {
        let f = fake(mc);
        f.clock += 1;
        f.clock
    };
    iso(now() + chrono::Duration::seconds(clock))
}

pub fn new_id(mc: &mut FakeMc, kind: &str) -> String {
    let f = fake(mc);
    f.ids += 1;
    format!("{kind}-{}", f.ids)
}

pub fn all(mc: &mut FakeMc, stream: &str, kind: &str) -> Vec<Value> {
    let streams = mc.part::<FakeStreams>();
    let prefix = format!("{kind}\n");
    streams
        .threads
        .get(stream)
        .into_iter()
        .flat_map(|entities| entities.iter())
        .filter(|(key, _)| key.starts_with(&prefix))
        .map(|(_, entity)| entity.clone())
        .collect()
}

pub fn one(mc: &mut FakeMc, stream: &str, kind: &str, id: &str) -> Value {
    mc.part::<FakeStreams>()
        .threads
        .get(stream)
        .and_then(|entities| entities.get(&format!("{kind}\n{id}")))
        .cloned()
        .unwrap_or_else(|| json!({}))
}

pub fn sorted_by(mut rows: Vec<Value>, field: &str) -> Vec<Value> {
    rows.sort_by(|a, b| {
        text(&a[field])
            .cmp(&text(&b[field]))
            .then_with(|| text(&a["id"]).cmp(&text(&b["id"])))
    });
    rows
}

/// One change to an entity of `stream`, appended to its log and sent to
/// whoever follows it ({"s": set, "d": delete}).
pub fn put(mc: &mut FakeMc, stream: &str, kind: &str, id: &str, patch: Value) {
    let seq = {
        let streams = mc.part::<FakeStreams>();
        let entities = streams.threads.entry(stream.to_owned()).or_default();
        let key = format!("{kind}\n{id}");
        if patch["d"].as_bool() == Some(true) {
            entities.remove(&key);
        } else {
            let entity = entities.entry(key).or_insert_with(|| json!({}));
            if let Some(set) = patch["s"].as_object() {
                for (k, v) in set {
                    entity[k] = v.clone();
                }
            }
        }
        streams.seq += 1;
        let seq = streams.seq;
        streams
            .log
            .entry(stream.to_owned())
            .or_default()
            .push(Change {
                seq,
                kind: kind.to_owned(),
                id: id.to_owned(),
                patch: patch.clone(),
            });
        seq
    };
    for follower in mc.subscribers("stream") {
        if text(&mc.shape_of(follower)["stream"]) != stream {
            continue;
        }
        deliver(
            mc,
            json!({
                "t": "events",
                "offset": seq,
                "id": follower,
                "events": [[seq, kind, id, patch, iso(now())]],
            }),
        );
    }
}

pub fn set(mc: &mut FakeMc, stream: &str, kind: &str, id: &str, fields: Value) {
    put(mc, stream, kind, id, json!({"s": fields}));
}

pub fn remove(mc: &mut FakeMc, stream: &str, kind: &str, id: &str) {
    put(mc, stream, kind, id, json!({"d": true}));
}

pub fn user() -> Value {
    json!({"type": "user"})
}

pub fn schedule_author() -> Value {
    json!({"type": "schedule"})
}

pub fn file_author() -> Value {
    json!({"type": "file"})
}

pub fn agent_author(thread_id: &str) -> Value {
    json!({"type": "agent", "threadId": thread_id})
}

// HalC2.Space.Order.between: a key after `low` and before `high`.
fn mid_first(low: &[i64], high: Option<&[i64]>) -> Vec<i64> {
    let lo = low.first().copied().unwrap_or(0);
    let hi = high.map_or(36, |h| h[0]);
    if hi - lo > 1 {
        return vec![(lo + hi) / 2];
    }
    if high.is_some_and(|h| h.len() > 1) {
        return vec![hi];
    }
    let mut out = vec![lo];
    out.extend(mid(&low[1.min(low.len())..], None));
    out
}

fn mid(low: &[i64], high: Option<&[i64]>) -> Vec<i64> {
    let Some(high) = high else {
        return mid_first(low, high);
    };
    let mut common = 0;
    while common < high.len() && low.get(common).copied().unwrap_or(0) == high[common] {
        common += 1;
    }
    if common == 0 {
        return mid_first(low, Some(high));
    }
    let mut out: Vec<i64> = high[..common].to_vec();
    out.extend(mid(&low[common.min(low.len())..], Some(&high[common..])));
    out
}

pub fn between(low: &str, high: Option<&str>) -> String {
    const DIGITS: &[u8] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let to_digits = |key: &str| -> Vec<i64> {
        key.bytes()
            .map(|c| DIGITS.iter().position(|d| *d == c).unwrap_or(0) as i64)
            .collect()
    };
    let high_digits = high.map(to_digits);
    mid(&to_digits(low), high_digits.as_deref())
        .into_iter()
        .map(|d| DIGITS[d as usize] as char)
        .collect()
}

pub fn trashed(entity: &Value) -> bool {
    !text(&entity["trashedAt"]).is_empty()
}

pub fn live(mc: &mut FakeMc, space: &str, mut page: Value) -> bool {
    let mut seen: HashSet<String> = HashSet::new();
    while !page.as_object().is_none_or(Map::is_empty) {
        if trashed(&page) {
            return false;
        }
        let parent = text(&page["parentPageId"]);
        if parent.is_empty() || seen.contains(&parent) {
            break;
        }
        seen.insert(parent.clone());
        page = one(mc, &stream_of(space), "page", &parent);
    }
    true
}

pub fn within(mc: &mut FakeMc, space: &str, page_id: &str) -> Vec<String> {
    let mut found = vec![page_id.to_owned()];
    let mut i = 0;
    while i < found.len() {
        for page in all(mc, &stream_of(space), "page") {
            let id = text(&page["id"]);
            if text(&page["parentPageId"]) == found[i] && !found.contains(&id) {
                found.push(id);
            }
        }
        i += 1;
    }
    found
}

pub fn blocks_of(mc: &mut FakeMc, space: &str, page_id: &str) -> Vec<Value> {
    let blocks: Vec<Value> = all(mc, &stream_of(space), "block")
        .into_iter()
        .filter(|block| text(&block["pageId"]) == page_id)
        .collect();
    sorted_by(blocks, "order")
}

pub fn writable(mc: &mut FakeMc, space: &str, page_id: &str) -> Option<Answer> {
    let page = one(mc, &stream_of(space), "page", page_id);
    if page.as_object().is_none_or(Map::is_empty) {
        return Some(refused("notFound", &format!("There is no page {page_id}.")));
    }
    if !live(mc, space, page) {
        return Some(refused("trashed", "The page is in the trash."));
    }
    None
}

/// Where a row is placed: the payload's `afterBlockId` absent, null, or an id.
#[derive(Clone, Debug)]
pub enum After {
    Absent,
    First,
    After(String),
}

impl After {
    pub fn of(payload: &Value, field: &str) -> After {
        match payload.get(field) {
            None => After::Absent,
            Some(Value::Null) => After::First,
            Some(value) => After::After(text(value)),
        }
    }

    pub fn said(&self) -> String {
        match self {
            After::After(id) => id.clone(),
            _ => String::new(),
        }
    }
}

/// The order key of a row placed after `after` among `rows` (sorted by
/// order), without the row `moving`.
pub fn place_in(rows: &[Value], after: &After, moving: &str) -> Option<String> {
    let rows: Vec<&Value> = rows
        .iter()
        .filter(|row| text(&row["id"]) != moving)
        .collect();
    let orders: Vec<String> = rows.iter().map(|row| text(&row["order"])).collect();
    match after {
        After::Absent => Some(between(orders.last().map_or("", String::as_str), None)),
        After::First => Some(between("", orders.first().map(String::as_str))),
        After::After(id) => rows
            .iter()
            .position(|row| &text(&row["id"]) == id)
            .map(|i| between(&orders[i], orders.get(i + 1).map(String::as_str))),
    }
}

pub fn place(
    mc: &mut FakeMc,
    space: &str,
    page_id: &str,
    after: &After,
    moving: &str,
) -> Option<String> {
    place_in(&blocks_of(mc, space, page_id), after, moving)
}

pub fn title_of(mc: &mut FakeMc, space: &str, page_id: &str) -> String {
    text(&one(mc, &stream_of(space), "page", page_id)["title"])
}

// --- Markdown, as HalC2.Space.Markdown reads and writes it (CodeFence.h) ----

fn fence_opens(line: &str) -> String {
    let trimmed = line
        .strip_prefix("   ")
        .or_else(|| line.strip_prefix("  "))
        .or_else(|| line.strip_prefix(' '))
        .unwrap_or(line);
    if line.len() - trimmed.len() > 3 {
        return String::new();
    }
    let first = trimmed.chars().next();
    if first != Some('`') && first != Some('~') {
        return String::new();
    }
    let marks: String = trimmed.chars().take_while(|c| Some(*c) == first).collect();
    if marks.len() < 3 {
        return String::new();
    }
    if first == Some('`') && trimmed[marks.len()..].contains('`') {
        return String::new();
    }
    marks
}

fn fence_closes(line: &str, marks: &str) -> bool {
    let trimmed = line.trim_start_matches(' ');
    if line.len() - trimmed.len() > 3 {
        return false;
    }
    let Some(first) = marks.chars().next() else {
        return false;
    };
    let run: String = trimmed.chars().take_while(|c| *c == first).collect();
    run.len() >= 3 && run.len() >= marks.len() && trimmed[run.len()..].trim().is_empty()
}

pub fn fence_write(code: &Value) -> String {
    let said = text(&code["text"]);
    let lines: Vec<&str> = if said.is_empty() {
        Vec::new()
    } else {
        said.split('\n').collect()
    };
    let mut marks = text(&code["fence"]);
    if marks.is_empty() {
        marks = "```".into();
    }
    while lines.iter().any(|line| fence_closes(line, &marks)) {
        marks.push(marks.chars().next().unwrap_or('`'));
    }
    let open = format!("{marks}{}{}", text(&code["language"]), text(&code["info"]));
    let mut out = vec![open];
    out.extend(lines.iter().map(|l| (*l).to_owned()));
    out.push(marks);
    out.join("\n")
}

fn fence_read(lines: &[String], at: usize) -> (Value, usize) {
    let block = |kind: &str, said: &str| json!({"kind": kind, "text": said, "checked": false, "linkedPageId": Value::Null});
    let marks = fence_opens(&lines[at]);
    let mut end = at + 1;
    while end < lines.len() && !fence_closes(&lines[end], &marks) {
        end += 1;
    }
    if end == lines.len() {
        let mut last = end;
        while last > at + 1 && lines[last - 1].trim().is_empty() {
            last -= 1;
        }
        return (block("raw", &lines[at..last].join("\n")), lines.len());
    }
    let written = lines[at..=end].join("\n");
    // The opening must be at the line's start to be code.
    let opening = &lines[at];
    let Some(first) = opening.chars().next() else {
        return (block("raw", &written), end + 1);
    };
    if first != '`' && first != '~' {
        return (block("raw", &written), end + 1);
    }
    let run: String = opening.chars().take_while(|c| *c == first).collect();
    if run.len() < 3 {
        return (block("raw", &written), end + 1);
    }
    let rest = &opening[run.len()..];
    let (language, info) = match rest.find(|c: char| c.is_whitespace()) {
        _ if rest.is_empty() => ("", ""),
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, ""),
    };
    // A language word must be one non-space run; everything else is raw.
    if language.is_empty() && !rest.is_empty() {
        return (block("raw", &written), end + 1);
    }
    let mut fenced = block("code", &lines[at + 1..end].join("\n"));
    if run != "```" {
        fenced["fence"] = json!(run);
    }
    if !language.is_empty() {
        fenced["language"] = json!(language);
    }
    if !info.is_empty() {
        fenced["info"] = json!(info);
    }
    if fence_write(&fenced) == written {
        (fenced, end + 1)
    } else {
        (block("raw", &written), end + 1)
    }
}

/// HalC2.Space.Markdown.export.
pub fn export_markdown(mc: &mut FakeMc, space: &str, page: &Value) -> String {
    let mut parts: Vec<String> = vec![format!("# {}", text(&page["title"]))];
    let mut in_list = false;
    for block in blocks_of(mc, space, &text(&page["id"])) {
        let kind = text(&block["kind"]);
        let said = text(&block["text"]);
        let line = match kind.as_str() {
            "heading" => format!("## {said}"),
            "checklist" => format!(
                "{} {said}",
                if block["checked"].as_bool() == Some(true) {
                    "- [x]"
                } else {
                    "- [ ]"
                }
            ),
            "callout" => said
                .split('\n')
                .map(|part| format!("> {part}").trim().to_owned())
                .collect::<Vec<_>>()
                .join("\n"),
            "code" => fence_write(&block),
            "subpage_link" => {
                let linked = text(&block["linkedPageId"]);
                let title = title_of(mc, space, &linked);
                format!(
                    "[{}](#{linked})",
                    if title.is_empty() { &said } else { &title }
                )
            }
            _ => said.clone(),
        };
        let item = kind == "checklist";
        if item && in_list {
            let last = parts.last_mut().expect("a part");
            last.push('\n');
            last.push_str(&line);
        } else {
            parts.push(line);
        }
        in_list = item;
    }
    parts.join("\n\n") + "\n"
}

/// HalC2.Space.Markdown.parse: the title, and each block.
pub fn parse_markdown(markdown: &str) -> (Option<String>, Vec<Value>) {
    let block = |kind: &str, said: &str| json!({"kind": kind, "text": said, "checked": false, "linkedPageId": Value::Null});
    let lines: Vec<String> = markdown
        .replace("\r\n", "\n")
        .split('\n')
        .map(str::to_owned)
        .collect();
    let mut blocks: Vec<Value> = Vec::new();
    let mut page_title: Option<String> = None;
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i].clone();
        let trimmed = line.trim();
        if trimmed.is_empty() {
            i += 1;
        } else if !fence_opens(&line).is_empty() {
            let (fenced, next) = fence_read(&lines, i);
            blocks.push(fenced);
            i = next;
        } else if let Some(heading) = heading_text(&line, 1) {
            if blocks.is_empty() && page_title.is_none() {
                page_title = Some(heading.trim().to_owned());
            } else {
                blocks.push(block("heading", heading.trim()));
            }
            i += 1;
        } else if (2..=6).any(|level| heading_text(&line, level).is_some()) {
            let level = (2..=6)
                .find(|l| heading_text(&line, *l).is_some())
                .expect("found");
            blocks.push(block(
                "heading",
                heading_text(&line, level).expect("found").trim(),
            ));
            i += 1;
        } else if let Some((checked, said)) = checklist_item(&line) {
            let mut item = block("checklist", &said);
            item["checked"] = json!(checked);
            blocks.push(item);
            i += 1;
        } else if let Some((label, target)) = page_link(trimmed) {
            let mut linked = block("subpage_link", &label);
            linked["linkedPageId"] = json!(target);
            blocks.push(linked);
            i += 1;
        } else if line.starts_with('>') {
            let mut quote: Vec<String> = Vec::new();
            while i < lines.len() && lines[i].starts_with('>') {
                let mut part = lines[i][1..].to_owned();
                if let Some(rest) = part.strip_prefix(' ') {
                    part = rest.to_owned();
                }
                quote.push(part);
                i += 1;
            }
            blocks.push(block("callout", &quote.join("\n")));
        } else {
            let mut paragraph: Vec<String> = Vec::new();
            while i < lines.len()
                && !lines[i].trim().is_empty()
                && !not_paragraph(&lines[i])
                && fence_opens(&lines[i]).is_empty()
            {
                paragraph.push(lines[i].clone());
                i += 1;
            }
            blocks.push(block("paragraph", &paragraph.join("\n")));
        }
    }
    (page_title, blocks)
}

fn heading_text(line: &str, level: usize) -> Option<&str> {
    let marks = "#".repeat(level);
    let rest = line.strip_prefix(&marks)?;
    if rest.starts_with('#') || !rest.chars().next().is_some_and(|c| c.is_whitespace()) {
        return None;
    }
    Some(
        &rest[rest
            .find(|c: char| !c.is_whitespace())
            .unwrap_or(rest.len())..],
    )
}

fn checklist_item(line: &str) -> Option<(bool, String)> {
    let line = line.trim_start();
    let rest = line
        .strip_prefix("- ")
        .or_else(|| line.strip_prefix("* "))?;
    let rest = rest.trim_start_matches(|c: char| c.is_whitespace() && c != '\n');
    let inner = rest.strip_prefix('[')?;
    let mark = inner.chars().next()?;
    if mark != ' ' && mark != 'x' && mark != 'X' {
        return None;
    }
    let after = inner[1..].strip_prefix(']')?;
    let said = after.strip_prefix(' ').unwrap_or(after);
    Some((mark != ' ', said.to_owned()))
}

fn page_link(line: &str) -> Option<(String, String)> {
    let inner = line.strip_prefix('[')?.strip_suffix(')')?;
    let (label, target) = inner.split_once("](#")?;
    if label.is_empty()
        || target.is_empty()
        || !target
            .chars()
            .all(|c| c.is_alphanumeric() || c == '_' || c == '-')
    {
        return None;
    }
    Some((label.to_owned(), target.to_owned()))
}

fn not_paragraph(line: &str) -> bool {
    (1..=6).any(|level| heading_text(line, level).is_some())
        || line.starts_with('>')
        || checklist_item(line).is_some()
}

pub fn create_page(
    mc: &mut FakeMc,
    space: &str,
    title: &str,
    parent: &Value,
    extra: &Value,
) -> Answer {
    if title.trim().is_empty() {
        return refused("invalid", "A page needs a title.");
    }
    if let Some(parent) = parent.as_str()
        && let Some(why) = writable(mc, space, parent)
    {
        return why;
    }
    let id = new_id(mc, "page");
    let at = stamp(mc);
    let mut page = json!({
        "id": id,
        "spaceId": space,
        "title": title.trim(),
        "parentPageId": if parent.is_string() { parent.clone() } else { Value::Null },
        "sourceThreadId": Value::Null,
        "trashedAt": Value::Null,
        "createdAt": at,
        "updatedAt": at,
    });
    if let Some(extra) = extra.as_object() {
        for (k, v) in extra {
            page[k] = v.clone();
        }
    }
    set(mc, &stream_of(space), "page", &id.clone(), page.clone());
    Answer::ok(json!({"page": page}))
}

pub fn insert_block(
    mc: &mut FakeMc,
    space: &str,
    page_id: &str,
    spec: &Value,
    after: &After,
    author: &Value,
) -> Answer {
    if let Some(why) = writable(mc, space, page_id) {
        return why;
    }
    const KINDS: [&str; 15] = [
        "paragraph",
        "heading",
        "checklist",
        "bullet",
        "numbered",
        "callout",
        "divider",
        "subpage_link",
        "image",
        "raw",
        "table",
        "code",
        "footnote",
        "details",
        "details_end",
    ];
    let kind = text(&spec["kind"]);
    if !KINDS.contains(&kind.as_str()) {
        return refused("invalid", &format!("There is no block kind {kind}."));
    }
    let level = &spec["level"];
    if kind == "heading"
        && !matches!(level, Value::Null)
        && spec.get("level").is_some()
        && !(1..=6).contains(&level.as_i64().unwrap_or(0))
    {
        return refused("invalid", "A heading's level is 1 to 6.");
    }
    let linked = text(&spec["linkedPageId"]);
    if kind == "subpage_link"
        && one(mc, &stream_of(space), "page", &linked)
            .as_object()
            .is_none_or(Map::is_empty)
    {
        return refused("notFound", "A subpage link needs a page to link to.");
    }
    let image_id = text(&spec["imageId"]);
    let image = one(mc, &stream_of(space), "image", &image_id);
    let url = text(&spec["url"]);
    if kind == "image" && url.is_empty() {
        if image.as_object().is_none_or(Map::is_empty) {
            return refused(
                "notFound",
                &format!("There is no image {image_id} in this Space."),
            );
        }
        if trashed(&image) {
            return refused(
                "trashed",
                &format!("The image \"{}\" is in the trash.", text(&image["name"])),
            );
        }
    }
    let Some(order) = place(mc, space, page_id, after, "") else {
        return refused(
            "notFound",
            &format!("There is no block {} on the page.", after.said()),
        );
    };
    let id = new_id(mc, "block");
    let at = stamp(mc);
    let mut block = json!({
        "id": id,
        "pageId": page_id,
        "kind": kind,
        "text": text(&spec["text"]),
        "order": order,
        "createdBy": author.clone(),
        "updatedBy": author.clone(),
        "createdAt": at,
        "updatedAt": at,
    });
    if kind == "checklist" {
        block["checked"] = json!(spec["checked"].as_bool().unwrap_or(false));
    }
    if kind == "subpage_link" {
        block["linkedPageId"] = json!(linked);
    }
    if kind == "heading" && spec.get("level").is_some() && !level.is_null() {
        block["level"] = json!(level.as_i64().unwrap_or(2));
    }
    if kind == "image" && !url.is_empty() {
        block["url"] = json!(url);
    } else if kind == "image" {
        block["imageId"] = json!(image_id);
        if text(&block["text"]).is_empty() {
            block["text"] = image["name"].clone();
        }
    }
    let code = kind == "code";
    let item = matches!(kind.as_str(), "bullet" | "numbered" | "checklist");
    let extras: [(&str, bool); 9] = [
        ("language", code),
        ("fence", code),
        ("info", code),
        ("depth", item && spec["depth"].as_i64().unwrap_or(0) != 0),
        ("indent", item),
        (
            "marker",
            matches!(
                kind.as_str(),
                "bullet" | "numbered" | "divider" | "callout" | "details"
            ),
        ),
        (
            "start",
            kind == "numbered" && spec["start"].as_i64().unwrap_or(1) != 1,
        ),
        ("alert", kind == "callout"),
        ("label", kind == "footnote"),
    ];
    for (field, kept) in extras {
        if kept && spec.get(field).is_some_and(|v| !v.is_null()) {
            block[field] = spec[field].clone();
        }
    }
    if let Some(chart) = spec.get("chart") {
        block["chart"] = chart.clone();
    }
    set(mc, &stream_of(space), "block", &id.clone(), block.clone());
    Answer::ok(json!({"block": block}))
}

pub fn import_markdown(
    mc: &mut FakeMc,
    space: &str,
    markdown: &str,
    title: &str,
    parent: &Value,
    extra: &Value,
    author: &Value,
) -> Answer {
    let (parsed, blocks) = parse_markdown(markdown);
    let named = if !title.trim().is_empty() {
        title.to_owned()
    } else if let Some(parsed) = &parsed
        && !parsed.trim().is_empty()
    {
        parsed.clone()
    } else {
        "Untitled".into()
    };
    let made = create_page(mc, space, &named, parent, extra);
    if !made.error.is_empty() {
        return made;
    }
    let page_id = text(&made.result["page"]["id"]);
    for block in &blocks {
        insert_block(mc, space, &page_id.clone(), block, &After::Absent, author);
    }
    made
}

// --- Project files as pages ---------------------------------------------------

pub fn space_file(path: &str) -> bool {
    path.ends_with(".md")
}

pub fn hash_of(contents: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    contents.hash(&mut hasher);
    format!("{:x}", hasher.finish())
}

/// What the files of `project` say, by path (the scenario's project's are
/// the Files tab's).
pub fn files_of(mc: &mut FakeMc, project: &str) -> std::collections::BTreeMap<String, String> {
    if project == "shop" {
        fake_files(mc).files.clone()
    } else {
        fake(mc)
            .project_files
            .get(project)
            .cloned()
            .unwrap_or_default()
    }
}

pub fn set_file(mc: &mut FakeMc, project: &str, path: &str, contents: &str) {
    if project == "shop" {
        fake_files(mc).files.insert(path.into(), contents.into());
    } else {
        fake(mc)
            .project_files
            .entry(project.into())
            .or_default()
            .insert(path.into(), contents.into());
    }
}

pub fn remove_file(mc: &mut FakeMc, project: &str, path: &str) {
    if project == "shop" {
        fake_files(mc).files.remove(path);
    } else if let Some(files) = fake(mc).project_files.get_mut(project) {
        files.remove(path);
    }
}

pub fn project_space(mc: &mut FakeMc, project: &str, make: bool) -> String {
    for space in all(mc, INDEX, "projectSpace") {
        if text(&space["projectId"]) == project {
            return text(&space["id"]);
        }
    }
    if !make {
        return String::new();
    }
    let id = new_id(mc, "space");
    let at = stamp(mc);
    let title = mc
        .projects
        .get(project)
        .map_or(String::new(), |p| text(&p["title"]));
    set(
        mc,
        INDEX,
        "projectSpace",
        &id.clone(),
        json!({"id": id, "name": title, "projectId": project, "createdAt": at, "updatedAt": at}),
    );
    id
}

pub fn page_of_file(mc: &mut FakeMc, project: &str, path: &str) -> (String, Value) {
    for space in all(mc, INDEX, "projectSpace") {
        let id = text(&space["id"]);
        for page in all(mc, &stream_of(&id), "page") {
            let file = &page["file"];
            if text(&file["projectId"]) == project && text(&file["path"]) == path {
                return (id.clone(), page);
            }
        }
    }
    (String::new(), json!({}))
}

pub fn take_file(mc: &mut FakeMc, space: &str, page_id: &str, changes: &Value) {
    let page = one(mc, &stream_of(space), "page", page_id);
    let mut file = page["file"].as_object().cloned().unwrap_or_default();
    let contents = files_of(mc, &text(&file["projectId"]))
        .get(&text(&file["path"]))
        .cloned()
        .unwrap_or_default();
    for block in blocks_of(mc, space, page_id) {
        remove(mc, &stream_of(space), "block", &text(&block["id"]));
    }
    for block in parse_markdown(&contents).1 {
        insert_block(mc, space, page_id, &block, &After::Absent, &file_author());
    }
    file.insert("hash".into(), json!(hash_of(&contents)));
    file.insert("size".into(), json!(contents.len()));
    file.insert("missing".into(), json!(false));
    if let Some(changes) = changes.as_object() {
        for (k, v) in changes {
            file.insert(k.clone(), v.clone());
        }
    }
    let at = stamp(mc);
    set(
        mc,
        &stream_of(space),
        "page",
        page_id,
        json!({"file": Value::Object(file), "updatedAt": at}),
    );
}

pub fn lose_file(mc: &mut FakeMc, space: &str, page: &Value) {
    let mut file = page["file"].as_object().cloned().unwrap_or_default();
    if file.get("missing").and_then(Value::as_bool) == Some(true) {
        return;
    }
    file.insert("missing".into(), json!(true));
    set(
        mc,
        &stream_of(space),
        "page",
        &text(&page["id"]),
        json!({"file": Value::Object(file)}),
    );
}

fn files_call(mc: &mut FakeMc, method: &str, input: &Value) -> Answer {
    let project = text(&input["projectId"]);
    if !mc.projects.contains_key(&project) {
        return refused(
            "notFound",
            &format!("There is no project {project} on this MC."),
        );
    }
    if method == "files.list" {
        fake(mc).listings += 1;
        let mut files: Vec<Value> = Vec::new();
        for path in files_of(mc, &project).keys() {
            if !space_file(path) {
                continue;
            }
            let (space, page) = page_of_file(mc, &project, path);
            let open = if page.as_object().is_none_or(Map::is_empty) {
                Value::Null
            } else {
                json!({"spaceId": space, "pageId": page["id"], "title": page["title"]})
            };
            files.push(json!({"relativePath": path, "kind": "page", "page": open}));
        }
        let space = project_space(mc, &project, false);
        return Answer::ok(json!({
            "config": "default",
            "files": files,
            "spaceId": if space.is_empty() { Value::Null } else { json!(space) },
        }));
    }
    if method == "files.scan" {
        let status = fake(mc).scan.clone();
        return Answer::ok(json!({
            "status": status,
            "entries": [{"path": "**/*.md", "kind": "page"}],
        }));
    }
    refused(
        "invalid",
        &format!("space.{method} is missing a required field."),
    )
}

fn sync_file(mc: &mut FakeMc, space: &str, page: &Value) -> Answer {
    fake(mc).syncs += 1;
    let file = page["file"].as_object().cloned().unwrap_or_default();
    if file.is_empty() {
        return refused("invalid", "The page is not a project file.");
    }
    let id = text(&page["id"]);
    let files = files_of(mc, &text(&file["projectId"]));
    let path = text(&file["path"]);
    if !files.contains_key(&path) {
        lose_file(mc, space, page);
    } else if hash_of(&files[&path]) != text(&file["hash"])
        || file.get("missing").and_then(Value::as_bool) == Some(true)
    {
        take_file(mc, space, &id.clone(), &json!({}));
    }
    Answer::ok(json!({"page": one(mc, &stream_of(space), "page", &id)}))
}

fn open_file(mc: &mut FakeMc, input: &Value) -> Answer {
    let project = text(&input["projectId"]);
    let path = text(&input["relativePath"]);
    if path.starts_with('/') || path.split('/').any(|part| part == "..") {
        return refused("invalid", &format!("{path} is outside the project."));
    }
    if !mc.projects.contains_key(&project) {
        return refused(
            "notFound",
            &format!("There is no project {project} on this MC."),
        );
    }
    if !space_file(&path) {
        return refused(
            "notSpaceFile",
            &format!("{path} is not in the spaces section of the project."),
        );
    }
    let (where_, page) = page_of_file(mc, &project, &path);
    if !page.as_object().is_none_or(Map::is_empty) {
        let synced = sync_file(mc, &where_, &page).result["page"].clone();
        return Answer::ok(json!({"spaceId": where_, "page": synced, "created": false}));
    }
    let files = files_of(mc, &project);
    let Some(contents) = files.get(&path) else {
        return refused(
            "notFound",
            &format!("There is no file {path} in the project {project}."),
        );
    };
    let contents = contents.clone();
    let space = project_space(mc, &project, true);
    let file = json!({
        "projectId": project,
        "path": path,
        "hash": hash_of(&contents),
        "size": contents.len(),
        "missing": false,
        "conflictAt": Value::Null,
    });
    let mut made = import_markdown(
        mc,
        &space.clone(),
        &contents,
        "",
        &Value::Null,
        &json!({"file": file}),
        &file_author(),
    );
    if !made.error.is_empty() {
        return made;
    }
    if let Some(result) = made.result.as_object_mut() {
        result.insert("spaceId".into(), json!(space));
        result.insert("created".into(), json!(true));
    }
    made
}

pub fn space_of(mc: &mut FakeMc, id: &str) -> Value {
    one(mc, INDEX, "space", id)
}

pub fn any_space(mc: &mut FakeMc, id: &str) -> bool {
    !space_of(mc, id).as_object().is_none_or(Map::is_empty)
        || !one(mc, INDEX, "projectSpace", id)
            .as_object()
            .is_none_or(Map::is_empty)
}

pub fn make_space(mc: &mut FakeMc, name: &str) -> Value {
    let id = new_id(mc, "space");
    let at = stamp(mc);
    let space = json!({"id": id, "name": name, "createdAt": at, "updatedAt": at});
    set(mc, INDEX, "space", &id.clone(), space.clone());
    space
}

fn seed(mc: &mut FakeMc) {
    if all(mc, INDEX, "space").is_empty() {
        make_space(mc, "Personal");
    }
}

fn keep_image(
    mc: &mut FakeMc,
    space: &str,
    name: &str,
    prompt: Value,
    generated_by: Value,
) -> Answer {
    let id = new_id(mc, "image");
    let at = stamp(mc);
    let image = json!({
        "id": id,
        "spaceId": space,
        "name": name,
        "mimeType": "image/png",
        "sizeBytes": 64,
        "width": 4,
        "height": 3,
        "prompt": prompt,
        "generatedBy": generated_by,
        "trashedAt": Value::Null,
        "createdBy": user(),
        "createdAt": at,
        "updatedAt": at,
    });
    set(mc, &stream_of(space), "image", &id.clone(), image.clone());
    Answer::ok(json!({"image": image}))
}

fn image_call(mc: &mut FakeMc, space: &str, method: &str, input: &Value) -> Answer {
    let stream = stream_of(space);
    if method == "image.add" {
        if text(&input["attachmentId"]).is_empty() {
            return refused("invalid", "There is no such upload.");
        }
        return keep_image(mc, space, &text(&input["name"]), Value::Null, Value::Null);
    }
    if method == "image.generate" {
        let how = fake(mc).image_generation.clone();
        if how == "unavailable" {
            return refused_tag(
                "unavailable",
                "No provider that can make an image is set up.",
                "SpaceImageGenerationError",
            );
        }
        if how == "failed" {
            return refused_tag(
                "failed",
                "The provider left no image.",
                "SpaceImageGenerationError",
            );
        }
        let prompt = text(&input["prompt"]);
        let chosen = input["modelSelection"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        let by = if chosen.is_empty() {
            json!({"instanceId": "codex", "model": "auto"})
        } else {
            Value::Object(chosen)
        };
        return keep_image(mc, space, &format!("{prompt}.png"), json!(prompt), by);
    }
    let id = text(&input["imageId"]);
    let image = one(mc, &stream, "image", &id);
    if image.as_object().is_none_or(Map::is_empty) {
        return refused(
            "notFound",
            &format!("There is no image {id} in this Space."),
        );
    }
    let name = text(&image["name"]);
    match method {
        "image.trash" => {
            if trashed(&image) {
                return refused("trashed", &format!("The image \"{name}\" is in the trash."));
            }
            let at = stamp(mc);
            set(
                mc,
                &stream,
                "image",
                &id,
                json!({"trashedAt": at, "updatedAt": at}),
            );
        }
        "image.restore" => {
            if !trashed(&image) {
                return refused(
                    "invalid",
                    &format!("The image \"{name}\" is not in the trash."),
                );
            }
            let at = stamp(mc);
            set(
                mc,
                &stream,
                "image",
                &id,
                json!({"trashedAt": Value::Null, "updatedAt": at}),
            );
        }
        "image.delete" => {
            if !trashed(&image) {
                return refused(
                    "invalid",
                    &format!(
                        "Only an image in the trash can be deleted; move \"{name}\" there first."
                    ),
                );
            }
            remove(mc, &stream, "image", &id);
            return Answer::ok(json!({"imageId": id}));
        }
        _ => {
            return refused(
                "invalid",
                &format!("space.{method} is missing a required field."),
            );
        }
    }
    Answer::ok(json!({"image": one(mc, &stream, "image", &id)}))
}

// --- History -------------------------------------------------------------------

fn versioned(mut block: Value) -> Value {
    if let Some(map) = block.as_object_mut() {
        map.remove("updatedBy");
        map.remove("updatedAt");
    }
    block
}

pub fn content_of(mc: &mut FakeMc, space: &str, page: &Value) -> Value {
    let blocks: Vec<Value> = blocks_of(mc, space, &text(&page["id"]))
        .into_iter()
        .map(versioned)
        .collect();
    json!({"title": page["title"], "blocks": blocks})
}

pub fn note_edits(mc: &mut FakeMc, space: &str, author: &Value) {
    for page in all(mc, &stream_of(space), "page") {
        let content = content_of(mc, space, &page);
        let page_id = text(&page["id"]);
        let grows = {
            let spaces = fake(mc);
            let versions = spaces.versions.entry(page_id.clone()).or_default();
            if versions.last().is_some_and(|v| v.content == content) {
                continue;
            }
            let grows = versions.last().is_some_and(|v| {
                !spaces.paused && v.restored_from_at.is_empty() && &v.author == author
            });
            if !grows {
                versions.push(FakeVersion {
                    version: 0,
                    at: String::new(),
                    author: Value::Null,
                    restored_from_at: String::new(),
                    content: Value::Null,
                });
            }
            grows
        };
        let _ = grows;
        let spaces = fake(mc);
        spaces.ids += 1;
        let version = spaces.ids;
        spaces.paused = false;
        let at = stamp(mc);
        let spaces = fake(mc);
        let last = spaces
            .versions
            .get_mut(&page_id)
            .and_then(|v| v.last_mut())
            .expect("a version");
        *last = FakeVersion {
            version,
            at,
            author: author.clone(),
            restored_from_at: String::new(),
            content,
        };
    }
}

fn history_call(mc: &mut FakeMc, method: &str, input: &Value) -> Answer {
    let space = text(&input["spaceId"]);
    let page_id = text(&input["pageId"]);
    let page = one(mc, &stream_of(&space), "page", &page_id);
    if page.as_object().is_none_or(Map::is_empty) {
        return refused(
            "notFound",
            &format!("There is no page {page_id} in this Space."),
        );
    }
    if method == "page.history" {
        let before = input["before"].as_i64().unwrap_or(-1);
        let limit = input["limit"].as_i64().unwrap_or(30);
        let versions = fake(mc).versions.get(&page_id).cloned().unwrap_or_default();
        let mut shown: Vec<Value> = Vec::new();
        let mut next = Value::Null;
        for version in versions.iter().rev() {
            if before >= 0 && version.version >= before {
                continue;
            }
            if shown.len() as i64 == limit {
                next = shown
                    .last()
                    .map_or(Value::Null, |row| row["version"].clone());
                break;
            }
            let thread = text(&version.author["threadId"]);
            let thread_title = if thread.is_empty() {
                Value::Null
            } else {
                json!(
                    mc.threads
                        .get(&thread)
                        .map_or(String::new(), |row| text(&row["title"]))
                )
            };
            shown.push(json!({
                "version": version.version,
                "at": version.at,
                "author": version.author,
                "threadTitle": thread_title,
                "restoredFromAt": if version.restored_from_at.is_empty() {
                    Value::Null
                } else {
                    json!(version.restored_from_at)
                },
            }));
        }
        return Answer::ok(json!({"versions": shown, "nextBefore": next}));
    }
    let wanted = input["version"].as_i64().unwrap_or(-1);
    let versions = fake(mc).versions.get(&page_id).cloned().unwrap_or_default();
    let Some(version) = versions.iter().find(|v| v.version == wanted).cloned() else {
        return refused("notFound", &format!("This page has no version {wanted}."));
    };
    if method == "page.version" {
        return Answer::ok(json!({
            "version": version.version,
            "at": version.at,
            "title": version.content["title"],
            "blocks": version.content["blocks"],
        }));
    }
    if let Some(why) = writable(mc, &space, &page_id) {
        return why;
    }
    let before = content_of(mc, &space, &page);
    let stream = stream_of(&space);
    let updates = page["schedule"].is_object();
    let mut kept: HashSet<String> = HashSet::new();
    let blocks = version.content["blocks"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    for mut block in blocks {
        if text(&block["kind"]) == GENERATED {
            if updates {
                continue;
            }
            let parsed = parse_markdown(&text(&block["text"])).1;
            let first = parsed.first().cloned().unwrap_or_else(|| json!({}));
            block["kind"] = json!(text(&first["kind"]));
            block["text"] = json!(text(&first["text"]));
        }
        let id = text(&block["id"]);
        kept.insert(id.clone());
        if versioned(one(mc, &stream, "block", &id)) == block {
            continue;
        }
        block["updatedBy"] = user();
        block["updatedAt"] = json!(stamp(mc));
        set(mc, &stream.clone(), "block", &id, block);
    }
    for block in blocks_of(mc, &space, &page_id) {
        let id = text(&block["id"]);
        if text(&block["kind"]) != GENERATED && !kept.contains(&id) {
            remove(mc, &stream, "block", &id);
        }
    }
    if page["title"] != version.content["title"] {
        set(
            mc,
            &stream,
            "page",
            &page_id,
            json!({"title": version.content["title"]}),
        );
    }
    let page = one(mc, &stream, "page", &page_id);
    let after = content_of(mc, &space, &page);
    if after != before {
        let spaces = fake(mc);
        spaces.ids += 1;
        let number = spaces.ids;
        let at = stamp(mc);
        fake(mc)
            .versions
            .entry(page_id.clone())
            .or_default()
            .push(FakeVersion {
                version: number,
                at,
                author: user(),
                restored_from_at: version.at.clone(),
                content: after,
            });
    }
    Answer::ok(json!({"page": one(mc, &stream, "page", &page_id)}))
}

// --- Decks -----------------------------------------------------------------------

pub fn generated_of(mc: &mut FakeMc, space: &str, page_id: &str) -> Value {
    all(mc, &stream_of(space), "block")
        .into_iter()
        .find(|block| text(&block["pageId"]) == page_id && text(&block["kind"]) == GENERATED)
        .unwrap_or_else(|| json!({}))
}

pub fn slides_of(mc: &mut FakeMc, stream: &str, deck_id: &str) -> Vec<Value> {
    let slides: Vec<Value> = all(mc, stream, "slide")
        .into_iter()
        .filter(|slide| text(&slide["deckId"]) == deck_id)
        .collect();
    sorted_by(slides, "order")
}

fn deck_refusal(mc: &mut FakeMc, stream: &str, deck_id: &str) -> Option<Answer> {
    let deck = one(mc, stream, "deck", deck_id);
    if deck.as_object().is_none_or(Map::is_empty) {
        return Some(refused(
            "notFound",
            &format!("There is no deck {deck_id} in this Space."),
        ));
    }
    if trashed(&deck) {
        return Some(refused(
            "trashed",
            &format!("The deck \"{}\" is in the trash.", text(&deck["title"])),
        ));
    }
    None
}

fn make_slide(
    mc: &mut FakeMc,
    stream: &str,
    deck_id: &str,
    title: &str,
    body: &str,
    order: &str,
) -> Value {
    let id = new_id(mc, "slide");
    let at = stamp(mc);
    let slide = json!({
        "id": id, "deckId": deck_id, "title": title, "body": body,
        "order": order, "createdAt": at, "updatedAt": at,
    });
    set(mc, stream, "slide", &id.clone(), slide.clone());
    slide
}

fn make_deck(mc: &mut FakeMc, space: &str, title: &str, specs: &[(String, String)]) -> Answer {
    let id = new_id(mc, "deck");
    let at = stamp(mc);
    let deck = json!({
        "id": id, "spaceId": space, "title": title, "trashedAt": Value::Null,
        "createdAt": at, "updatedAt": at,
    });
    set(mc, &stream_of(space), "deck", &id.clone(), deck.clone());
    for (slide_title, body) in specs {
        let order =
            place_in(&slides_of(mc, &stream_of(space), &id), &After::Absent, "").expect("a place");
        make_slide(
            mc,
            &stream_of(space),
            &id.clone(),
            slide_title,
            body,
            &order,
        );
    }
    Answer::ok(json!({"deck": deck}))
}

fn slide_line(mc: &mut FakeMc, space: &str, block: &Value) -> String {
    let kind = text(&block["kind"]);
    let said = text(&block["text"]);
    match kind.as_str() {
        "checklist" => format!(
            "{} {said}",
            if block["checked"].as_bool() == Some(true) {
                "- [x]"
            } else {
                "- [ ]"
            }
        ),
        "callout" => format!("> {said}"),
        "subpage_link" => {
            let linked = one(mc, &stream_of(space), "page", &text(&block["linkedPageId"]));
            if linked.as_object().is_none_or(Map::is_empty) {
                said
            } else {
                text(&linked["title"])
            }
        }
        _ => said,
    }
}

fn deck_from_page(mc: &mut FakeMc, space: &str, page_id: &str) -> Answer {
    if let Some(why) = writable(mc, space, page_id) {
        return why;
    }
    let title = title_of(mc, space, page_id);
    let mut sections: Vec<(String, Vec<String>)> = Vec::new();
    for block in blocks_of(mc, space, page_id) {
        if text(&block["kind"]) == "heading" {
            sections.push((text(&block["text"]), Vec::new()));
            continue;
        }
        if sections.is_empty() {
            sections.push((title.clone(), Vec::new()));
        }
        let line = slide_line(mc, space, &block);
        sections.last_mut().expect("a section").1.push(line);
    }
    if sections.is_empty() {
        sections.push((title.clone(), Vec::new()));
    }
    let specs: Vec<(String, String)> = sections
        .into_iter()
        .map(|(title, lines)| (title, lines.join("\n")))
        .collect();
    make_deck(mc, space, &title, &specs)
}

fn deck_call(mc: &mut FakeMc, space: &str, method: &str, input: &Value) -> Answer {
    let stream = stream_of(space);
    if method == "deck.create" {
        let title = text(&input["title"]);
        if title.trim().is_empty() {
            return refused("invalid", "A deck needs a title.");
        }
        return make_deck(mc, space, title.trim(), &[(String::new(), String::new())]);
    }
    if method == "deck.createFromPage" {
        return deck_from_page(mc, space, &text(&input["pageId"]));
    }
    if method.starts_with("slide.") {
        if method == "slide.insert" {
            let deck_id = text(&input["deckId"]);
            if let Some(why) = deck_refusal(mc, &stream, &deck_id) {
                return why;
            }
            let after = After::of(input, "afterSlideId");
            let Some(order) = place_in(&slides_of(mc, &stream, &deck_id), &after, "") else {
                return refused(
                    "notFound",
                    &format!("There is no slide {} in the deck.", after.said()),
                );
            };
            let slide = make_slide(
                mc,
                &stream,
                &deck_id,
                &text(&input["title"]),
                &text(&input["body"]),
                &order,
            );
            return Answer::ok(json!({"slide": slide}));
        }
        let slide_id = text(&input["slideId"]);
        let slide = one(mc, &stream, "slide", &slide_id);
        if slide.as_object().is_none_or(Map::is_empty) {
            return refused(
                "notFound",
                &format!("There is no slide {slide_id} in this Space."),
            );
        }
        let deck_id = text(&slide["deckId"]);
        if let Some(why) = deck_refusal(mc, &stream, &deck_id) {
            return why;
        }
        return match method {
            "slide.update" => {
                let mut patch = json!({});
                if input.get("title").is_some() {
                    patch["title"] = input["title"].clone();
                }
                if input.get("body").is_some() {
                    patch["body"] = input["body"].clone();
                }
                patch["updatedAt"] = json!(stamp(mc));
                set(mc, &stream, "slide", &slide_id, patch);
                Answer::ok(json!({"slide": one(mc, &stream, "slide", &slide_id)}))
            }
            "slide.delete" => {
                remove(mc, &stream, "slide", &slide_id);
                Answer::ok(json!({"slideId": slide_id}))
            }
            "slide.move" => {
                let after = After::of(input, "afterSlideId");
                let Some(order) = place_in(&slides_of(mc, &stream, &deck_id), &after, &slide_id)
                else {
                    return refused(
                        "notFound",
                        &format!("There is no slide {} in the deck.", after.said()),
                    );
                };
                set(mc, &stream, "slide", &slide_id, json!({"order": order}));
                Answer::ok(json!({"slide": one(mc, &stream, "slide", &slide_id)}))
            }
            _ => refused(
                "invalid",
                &format!("space.{method} is missing a required field."),
            ),
        };
    }
    let deck_id = text(&input["deckId"]);
    let deck = one(mc, &stream, "deck", &deck_id);
    if deck.as_object().is_none_or(Map::is_empty) {
        return refused(
            "notFound",
            &format!("There is no deck {deck_id} in this Space."),
        );
    }
    let title = text(&deck["title"]);
    let at = stamp(mc);
    match method {
        "deck.rename" => {
            if let Some(why) = deck_refusal(mc, &stream, &deck_id) {
                return why;
            }
            if text(&input["title"]).trim().is_empty() {
                return refused("invalid", "A deck needs a title.");
            }
            set(
                mc,
                &stream,
                "deck",
                &deck_id,
                json!({"title": text(&input["title"]).trim(), "updatedAt": at}),
            );
        }
        "deck.trash" => {
            if trashed(&deck) {
                return refused("trashed", &format!("The deck \"{title}\" is in the trash."));
            }
            set(
                mc,
                &stream,
                "deck",
                &deck_id,
                json!({"trashedAt": at, "updatedAt": at}),
            );
        }
        "deck.restore" => {
            if !trashed(&deck) {
                return refused(
                    "invalid",
                    &format!("The deck \"{title}\" is not in the trash."),
                );
            }
            set(
                mc,
                &stream,
                "deck",
                &deck_id,
                json!({"trashedAt": Value::Null, "updatedAt": at}),
            );
        }
        "deck.delete" => {
            if !trashed(&deck) {
                return refused(
                    "invalid",
                    &format!(
                        "Only a deck in the trash can be deleted; move \"{title}\" there first."
                    ),
                );
            }
            for slide in slides_of(mc, &stream, &deck_id) {
                remove(mc, &stream, "slide", &text(&slide["id"]));
            }
            remove(mc, &stream, "deck", &deck_id);
            return Answer::ok(json!({"deckId": deck_id}));
        }
        _ => {
            return refused(
                "invalid",
                &format!("space.{method} is missing a required field."),
            );
        }
    }
    Answer::ok(json!({"deck": one(mc, &stream, "deck", &deck_id)}))
}

// --- The page's agent ------------------------------------------------------------

pub fn say(mc: &mut FakeMc, space: &str, page_id: &str, fields: &Value) {
    let at = stamp(mc);
    let mut patch = json!({"pageId": page_id});
    if fields.get("status").is_some() {
        patch["status"] = fields["status"].clone();
    }
    if fields.get("request").is_some() {
        patch["request"] = fields["request"].clone();
    }
    if fields.get("edited").is_some() {
        patch["edited"] = fields["edited"].clone();
    }
    if fields.get("threadId").is_some() {
        patch["threadId"] = fields["threadId"].clone();
    }
    if fields.get("error").is_some() {
        patch["error"] = fields["error"].clone();
    }
    patch["updatedAt"] = json!(at);
    set(mc, &stream_of(space), "pageAgent", page_id, patch);
}

pub fn run_updates(mc: &mut FakeMc, space: &str, page_id: &str, author: &Value) {
    let stream = stream_of(space);
    let mut agent = one(mc, &stream, "pageAgent", page_id);
    let prior = text(&agent["written"]);
    let request = text(&agent["request"]);
    let said = if request.contains("Nothing new") {
        "Nothing new to report.".to_owned()
    } else if let Some(quote) = request.split('"').nth(1) {
        quote.to_owned()
    } else {
        format!("Updated for: {request}")
    };
    let generated = generated_of(mc, space, page_id);
    let at = stamp(mc);
    if generated.as_object().is_none_or(Map::is_empty) {
        let spec = json!({"kind": GENERATED, "text": said});
        let order = place(mc, space, page_id, &After::Absent, "").expect("a place");
        let id = new_id(mc, "block");
        let mut block = spec.clone();
        block["id"] = json!(id);
        block["pageId"] = json!(page_id);
        block["order"] = json!(order);
        block["createdBy"] = author.clone();
        block["updatedBy"] = author.clone();
        block["createdAt"] = json!(at.clone());
        block["updatedAt"] = json!(at.clone());
        set(mc, &stream, "block", &id.clone(), block);
    } else {
        set(
            mc,
            &stream,
            "block",
            &text(&generated["id"]),
            json!({"text": said, "updatedBy": author.clone(), "updatedAt": at.clone()}),
        );
    }
    let changed =
        generated.as_object().is_none_or(Map::is_empty) || text(&generated["text"]) != said;
    agent["status"] = json!("done");
    agent["written"] = json!(said);
    if changed && !prior.is_empty() {
        agent["edited"] = json!(true);
    }
    if !changed && !prior.is_empty() {
        agent["edited"] = json!(false);
    }
    let fields = json!({
        "status": "done",
        "edited": agent["edited"].as_bool().unwrap_or(false),
    });
    say(mc, space, page_id, &fields);
    set(
        mc,
        &stream,
        "pageAgent",
        page_id,
        json!({"written": agent["written"]}),
    );
    let at = stamp(mc);
    set(mc, &stream, "page", page_id, json!({"writtenAt": at}));
    note_edits(mc, space, author);
}

// --- Schedules and sites ------------------------------------------------------------

pub fn slug(title: &str) -> String {
    let mut out = String::new();
    for c in title.chars() {
        if c == '/' {
            out.push_str("-2f-");
        } else if c == ' ' {
            out.push('-');
        } else if c.is_alphanumeric() || c == '-' || c == '_' || c == '.' {
            out.push(c);
        } else {
            for byte in c.to_string().bytes() {
                out.push_str(&format!("%{byte:02X}"));
            }
        }
    }
    if out.is_empty() {
        "untitled".into()
    } else {
        out
    }
}

pub fn address(mc: &mut FakeMc) -> String {
    let spaces = fake(mc);
    if spaces.tailnet.is_empty() {
        spaces.address.clone()
    } else {
        let port = spaces
            .address
            .rsplit(':')
            .next()
            .unwrap_or("3773")
            .to_owned();
        format!("https://{}:{port}", spaces.tailnet)
    }
}

fn boolean(page: &Value, field: &str) -> bool {
    page["schedule"][field].as_bool().unwrap_or(false)
}

/// A page's update (lib/hal_c2/space/schedule.ex). The fake has no clock to wait
/// on, so a run ends within its `runNow`.
fn schedule_call(mc: &mut FakeMc, method: &str, input: &Value) -> Answer {
    let space = text(&input["spaceId"]);
    let page_id = text(&input["pageId"]);
    let stream = stream_of(&space);
    let page = one(mc, &stream, "page", &page_id);
    let answer = |mc: &mut FakeMc| Answer::ok(json!({"page": one(mc, &stream, "page", &page_id)}));
    let next_run = |mc: &mut FakeMc| {
        let spaces = fake(mc);
        spaces.clock += 1;
        iso(now() + chrono::Duration::seconds(3600 + spaces.clock))
    };
    let mut shown = page["schedule"].as_object().cloned().unwrap_or_default();
    let show = |mc: &mut FakeMc, shown: &mut Map<String, Value>, fields: Value| {
        if let Value::Object(fields) = fields {
            shown.extend(fields);
        }
        set(
            mc,
            &stream,
            "page",
            &page_id,
            json!({"schedule": Value::Object(shown.clone())}),
        );
    };
    if method == "page.schedule.set" {
        let instruction = text(&input["instruction"]).trim().to_owned();
        if instruction.is_empty() {
            return refused("invalid", "A page's update needs an instruction.");
        }
        let enabled = shown.is_empty()
            || shown
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or(false);
        let last = shown
            .get("lastRunStatus")
            .and_then(Value::as_str)
            .unwrap_or("never")
            .to_owned();
        let next = next_run(mc);
        show(
            mc,
            &mut shown,
            json!({"instruction": instruction, "cadence": input["cadence"], "enabled": enabled,
                   "nextRunAt": next, "lastRunStatus": last}),
        );
        return answer(mc);
    }
    if shown.is_empty() {
        return refused("notFound", "This page has no update.");
    }
    if method == "page.schedule.setEnabled" {
        let enabled = input["enabled"].as_bool().unwrap_or(false);
        let next = if enabled {
            json!(next_run(mc))
        } else {
            Value::Null
        };
        show(
            mc,
            &mut shown,
            json!({"enabled": enabled, "nextRunAt": next}),
        );
        return answer(mc);
    }
    let block = generated_of(mc, &space, &page_id);
    let has_block = block.as_object().is_some_and(|b| !b.is_empty());
    if method == "page.schedule.remove" {
        if has_block {
            let parsed = parse_markdown(&text(&block["text"])).1;
            let first = parsed.into_iter().next().unwrap_or_else(|| json!({}));
            set(
                mc,
                &stream,
                "block",
                &text(&block["id"]),
                json!({"kind": text(&first["kind"]), "text": text(&first["text"])}),
            );
        }
        set(
            mc,
            &stream,
            "page",
            &page_id,
            json!({"schedule": Value::Null, "writtenAt": Value::Null}),
        );
        return answer(mc);
    }
    let at = stamp(mc);
    let generation = fake(mc).generation.clone();
    if generation != "available" {
        let error = if generation == "failed" {
            "the model is overloaded"
        } else {
            "No text generation provider is set up."
        };
        show(
            mc,
            &mut shown,
            json!({"lastRunAt": at, "lastRunStatus": "failed", "lastRunError": error}),
        );
        return answer(mc);
    }
    let writes = fake(mc).writes.clone();
    if !has_block {
        let inserted = insert_block(
            mc,
            &space,
            &page_id,
            &json!({"kind": "paragraph", "text": writes}),
            &After::Absent,
            &schedule_author(),
        );
        let id = text(&inserted.result["block"]["id"]);
        set(mc, &stream, "block", &id, json!({"kind": GENERATED}));
    } else {
        set(
            mc,
            &stream,
            "block",
            &text(&block["id"]),
            json!({"text": writes, "updatedBy": schedule_author(), "updatedAt": at}),
        );
    }
    set(mc, &stream, "page", &page_id, json!({"writtenAt": at}));
    show(
        mc,
        &mut shown,
        json!({"lastRunAt": at, "lastRunStatus": "succeeded", "lastRunError": Value::Null}),
    );
    answer(mc)
}

/// The MC's side of a page's agent: its thread is a row like any other, and how its run ends
/// is the scenario's.
fn agent_call(mc: &mut FakeMc, method: &str, input: &Value) -> Answer {
    let stream = stream_of(&text(&input["spaceId"]));
    let page_id = text(&input["pageId"]);
    let asked = one(mc, &stream, "pageAgent", &page_id);
    let status = text(&asked["status"]);
    let active = status == "running" || status == "stopping";
    if method == "page.askAgent" {
        let spaces = fake(mc);
        spaces.last_ask = input.clone();
        if std::mem::take(&mut spaces.refuse_ask) {
            return refused("invalid", "An agent is already working on this page.");
        }
        let mut request = text(&input["request"]).trim().to_owned();
        if let Some(rest) = request.strip_prefix("@agent") {
            request = rest.trim().to_owned();
        }
        if request.is_empty() {
            return refused("invalid", "Say what the agent should do.");
        }
        if active {
            return refused("invalid", "An agent is already working on this page.");
        }
        let thread = new_id(mc, "agent-thread");
        let mut row = mc
            .threads
            .values()
            .next()
            .cloned()
            .unwrap_or_else(|| json!({}));
        row["id"] = json!(thread);
        row["title"] = json!("Page agent");
        mc.threads.insert(thread.clone(), row.clone());
        mc.send_row(&thread, &row);
        let at = stamp(mc);
        let agent = json!({
            "id": page_id, "pageId": page_id, "threadId": thread, "request": request,
            "status": "running", "edited": false, "error": Value::Null,
            "startedAt": at, "endedAt": Value::Null,
        });
        set(mc, &stream, "pageAgent", &page_id, agent.clone());
        return Answer::ok(json!({"agent": agent}));
    }
    if asked.as_object().is_none_or(Map::is_empty) {
        return refused("notFound", "No agent was asked on this page.");
    }
    if method == "page.stopAgent" {
        fake(mc).stops += 1;
        if active && fake(mc).ignores_stop {
            set(
                mc,
                &stream,
                "pageAgent",
                &page_id,
                json!({"status": "stopping"}),
            );
        } else if active {
            let at = stamp(mc);
            set(
                mc,
                &stream,
                "pageAgent",
                &page_id,
                json!({"status": "stopped", "endedAt": at}),
            );
        }
        return Answer::ok(json!({"agent": one(mc, &stream, "pageAgent", &page_id)}));
    }
    if active {
        return refused("invalid", "The agent is still working on this page.");
    }
    remove(mc, &stream, "pageAgent", &page_id);
    Answer::ok(json!({"pageId": page_id}))
}

/// What a site shows of the page: its title and its blocks' text.
pub fn site_snapshot(mc: &mut FakeMc, space: &str, page: &Value) -> Value {
    let page_id = text(&page["id"]);
    let mut shown = vec![page["title"].clone()];
    for block in sorted_by(all(mc, &stream_of(space), "block"), "order") {
        if text(&block["pageId"]) == page_id {
            shown.push(json!(text(&block["text"])));
        }
    }
    Value::Array(shown)
}

/// The site of the page `page_id`, or `{}`.
pub fn site_of_page(mc: &mut FakeMc, space: &str, page_id: &str) -> Value {
    all(mc, &stream_of(space), "site")
        .into_iter()
        .find(|site| text(&site["pageId"]) == page_id)
        .unwrap_or_else(|| json!({}))
}

fn publish_call(mc: &mut FakeMc, method: &str, input: &Value) -> Answer {
    let space = text(&input["spaceId"]);
    let page_id = text(&input["pageId"]);
    let stream = stream_of(&space);
    let page = one(mc, &stream, "page", &page_id);
    if method == "page.unpublish" {
        for site in all(mc, &stream, "site") {
            if text(&site["pageId"]) == page_id {
                remove(mc, &stream, "site", &text(&site["id"]));
            }
        }
        return Answer::ok(json!({"pageId": page_id}));
    }
    if !live(mc, &space, page.clone()) {
        return refused("trashed", "The page is in the trash.");
    }
    let tailscale = input["tailscale"].as_bool() == Some(true);
    let (tailnet, known, local) = {
        let spaces = fake(mc);
        (
            spaces.tailnet.clone(),
            spaces.address.clone(),
            spaces.local_only,
        )
    };
    if tailscale && tailnet.is_empty() {
        return refused("unavailable", "Tailscale is not running on this machine.");
    }
    let base = text(&input["baseUrl"]);
    let address = if tailscale {
        format!("https://{tailnet}")
    } else if !base.is_empty() {
        base.clone()
    } else {
        known
    };
    let local_only = !tailscale && base.is_empty() && local;
    let before = site_of_page(mc, &space, &page_id);
    let had = before.as_object().is_some_and(|b| !b.is_empty());
    // Published again it keeps its token, and an address only this machine can open never replaces one others reach.
    let id = if had {
        text(&before["id"])
    } else {
        new_id(mc, "token")
    };
    let keeps_address = had && local_only && before["localOnly"] != json!(true);
    let url = if keeps_address {
        text(&before["url"])
    } else {
        format!("{address}/sites/{space}/{id}")
    };
    let at = stamp(mc);
    let snapshot = site_snapshot(mc, &space, &page);
    set(
        mc,
        &stream,
        "site",
        &id,
        json!({
            "id": id, "spaceId": space, "pageId": page_id, "url": url,
            "localOnly": if keeps_address { false } else { local_only },
            "publishedAt": at, "behind": false, "snapshot": snapshot,
        }),
    );
    fake(mc).links.insert(page_id, url);
    Answer::ok(json!({"site": one(mc, &stream, "site", &id)}))
}

fn required(input: &Value, kind: &str) -> bool {
    input.get(kind).is_some_and(|v| !v.is_null())
}

pub fn decide(mc: &mut FakeMc, method: &str, input: &Value) -> Answer {
    seed(mc);
    if method == "list" {
        return Answer::ok(json!({"spaces": sorted_by(all(mc, INDEX, "space"), "createdAt")}));
    }
    if method == "create" {
        let name = text(&input["name"]);
        if name.trim().is_empty() {
            return refused("invalid", "A Space needs a name.");
        }
        return Answer::ok(json!({"space": make_space(mc, name.trim())}));
    }
    if method == "files.list" || method == "files.scan" {
        return files_call(mc, method, input);
    }
    if method == "page.openFile" {
        return open_file(mc, input);
    }
    if method == "page.agentTarget" {
        return agent_target(mc, true);
    }
    if method == "page.history" || method == "page.version" || method == "page.restoreVersion" {
        return history_call(mc, method, input);
    }
    let space_id = text(&input["spaceId"]);
    if method == "image.providers" {
        // As the MC's (lib/hal_c2/space/image_generation.ex): only who can
        // draw, each with its image models.
        let model = |slug: &str, name: &str| json!({"slug": slug, "name": name, "description": null});
        let provider = |id: &str, ready: bool, missing: &str, models: Vec<Value>| {
            json!({
                "instanceId": id,
                "driver": id,
                "status": (if ready { "ready" } else { "unavailable" }),
                "message": (if ready { Value::Null } else { json!(missing) }),
                "models": models,
            })
        };
        let spaces = fake(mc);
        let able = spaces.image_generation != "unavailable";
        let grok = able && spaces.grok;
        return Answer::ok(json!({
            "providers": [
                provider("codex", able, "Codex is not installed.", vec![model("auto", "GPT Image")]),
                provider("grok", grok, "Grok is not installed.", vec![
                    model("auto", "Grok Imagine"),
                    model("grok-imagine-image-2.0", "Grok Imagine Image 2.0"),
                    model("grok-imagine-image", "Grok Imagine Image"),
                ]),
            ],
            "selection": (if able { json!({"instanceId": "codex", "model": "auto"}) } else { Value::Null }),
        }));
    }
    if !any_space(mc, &space_id) {
        return refused(
            "invalid",
            &format!("space.{method} is missing a required field."),
        );
    }
    let space = &space_id;
    let stream = stream_of(space);
    if method == "rename" || method == "delete" {
        let target = space_of(mc, &space_id);
        let found = !target.as_object().is_none_or(Map::is_empty);
        if method == "delete" {
            for scope in all(mc, INDEX, "projectSpace") {
                if text(&scope["id"]) == space_id {
                    return refused(
                        "readonly",
                        "Spaces belonging to a project are managed by the project.",
                    );
                }
            }
            if !all(mc, &stream, "page").is_empty()
                || !all(mc, &stream, "deck").is_empty()
                || !all(mc, &stream, "image").is_empty()
            {
                return refused(
                    "notEmpty",
                    "A Space with pages, decks or images cannot be deleted; delete them first.",
                );
            }
            remove(mc, INDEX, "space", &space_id);
            return Answer::ok(json!({"spaceId": space_id}));
        }
        if !found {
            return refused("notFound", &format!("There is no Space {space_id}."));
        }
        let name = text(&input["name"]);
        if name.trim().is_empty() {
            return refused("invalid", "A Space needs a name.");
        }
        set(mc, INDEX, "space", &space_id, json!({"name": name.trim()}));
        return Answer::ok(json!({"space": space_of(mc, &space_id)}));
    }
    if method == "page.create" {
        if !input.get("title").is_some() {
            return refused("invalid", "space.page.create is missing a required field.");
        }
        return create_page(
            mc,
            space,
            &text(&input["title"]),
            &input["parentPageId"],
            &json!({}),
        );
    }
    if method == "page.createFromThread" {
        // As SpaceSteps.cpp's: the thread's folder, then the summary as an imported page.
        let thread_id = text(&input["threadId"]);
        let thread = mc.threads.get(&thread_id).cloned().unwrap_or(Value::Null);
        let mut root = text(&thread["worktreePath"]);
        if root.is_empty() {
            let project = text(&thread["projectId"]);
            root = mc
                .projects
                .get(&project)
                .map_or(String::new(), |p| text(&p["workspaceRoot"]));
        }
        if thread.is_null() || root.is_empty() {
            return refused(
                "notFound",
                &format!("There is no thread {thread_id} with a project folder on this MC."),
            );
        }
        if !fake(mc).talked.contains(&thread_id) {
            return refused("invalid", "The thread has nothing to summarise yet.");
        }
        fake(mc).cwd = root;
        fake(mc).summarised = thread_id.clone();
        let tag = "SpaceTextGenerationError";
        match fake(mc).generation.as_str() {
            "unavailable" => {
                return refused_tag("unavailable", "No text generation provider is set up.", tag);
            }
            "failed" => return refused_tag("failed", "The provider stopped answering.", tag),
            _ => {}
        }
        return import_markdown(
            mc,
            space,
            &format!("# {SUMMARY_TITLE}\n\n{SUMMARY}\n"),
            SUMMARY_TITLE,
            &input.get("parentPageId").cloned().unwrap_or(Value::Null),
            &json!({"sourceThreadId": thread_id}),
            &agent_author(&thread_id),
        );
    }
    if method == "page.publish" || method == "page.unpublish" {
        return publish_call(mc, method, input);
    }
    if method == "page.schedule.set"
        || method == "page.schedule.setEnabled"
        || method == "page.schedule.runNow"
        || method == "page.schedule.remove"
    {
        return schedule_call(mc, method, input);
    }
    if method.starts_with("image.") {
        return image_call(mc, space, method, input);
    }
    if method.starts_with("deck.") || method.starts_with("slide.") {
        return deck_call(mc, space, method, input);
    }
    let page_id = text(&input["pageId"]);
    if method == "page.syncFile" {
        let page = one(mc, &stream, "page", &page_id);
        return sync_file(mc, space, &page);
    }
    match method {
        "page.importMarkdown" => {
            let made = import_markdown(
                mc,
                space,
                &text(&input["markdown"]),
                &text(&input["title"]),
                &Value::Null,
                &json!({}),
                &user(),
            );
            if made.error.is_empty() {
                note_edits(mc, space, &user());
            }
            made
        }
        "page.exportMarkdown" => {
            let page = one(mc, &stream, "page", &page_id);
            if page.as_object().is_none_or(Map::is_empty) {
                return refused(
                    "notFound",
                    &format!("There is no page {page_id} in this Space."),
                );
            }
            Answer::ok(json!({"markdown": export_markdown(mc, space, &page)}))
        }
        "page.rename" => {
            if let Some(why) = writable(mc, space, &page_id) {
                return why;
            }
            if text(&input["title"]).trim().is_empty() {
                return refused("invalid", "A page needs a title.");
            }
            set(
                mc,
                &stream,
                "page",
                &page_id,
                json!({"title": text(&input["title"])}),
            );
            Answer::ok(json!({"page": one(mc, &stream, "page", &page_id)}))
        }
        "page.move" => {
            if let Some(why) = writable(mc, space, &page_id) {
                return why;
            }
            let parent = &input["parentPageId"];
            if let Some(parent) = parent.as_str() {
                if parent == page_id {
                    return refused("invalid", "A page cannot be its own subpage.");
                }
                if within(mc, space, &page_id).iter().any(|id| id == parent) {
                    return refused(
                        "invalid",
                        "A page cannot move under one of its own subpages.",
                    );
                }
                if let Some(why) = writable(mc, space, parent) {
                    return Answer {
                        error: why.error.replace("previewId", parent),
                        ..why
                    };
                }
            }
            set(
                mc,
                &stream,
                "page",
                &page_id,
                json!({"parentPageId": parent}),
            );
            Answer::ok(json!({"page": one(mc, &stream, "page", &page_id)}))
        }
        "page.trash" => {
            let page = one(mc, &stream, "page", &page_id);
            if page.as_object().is_none_or(Map::is_empty) {
                return refused("notFound", &format!("There is no page {page_id}."));
            }
            if trashed(&page) {
                return refused("trashed", "The page is in the trash.");
            }
            let at = stamp(mc);
            set(mc, &stream, "page", &page_id, json!({"trashedAt": at}));
            Answer::ok(json!({"page": one(mc, &stream, "page", &page_id)}))
        }
        "page.restore" => {
            let mut page = one(mc, &stream, "page", &page_id);
            let mut seen: HashSet<String> = HashSet::new();
            while !page.as_object().is_none_or(Map::is_empty) {
                if trashed(&page) {
                    set(
                        mc,
                        &stream,
                        "page",
                        &text(&page["id"]),
                        json!({"trashedAt": Value::Null}),
                    );
                }
                let parent = text(&page["parentPageId"]);
                if parent.is_empty() || seen.contains(&parent) {
                    break;
                }
                seen.insert(parent.clone());
                page = one(mc, &stream, "page", &parent);
            }
            Answer::ok(json!({"page": one(mc, &stream, "page", &page_id)}))
        }
        "page.delete" => {
            let page = one(mc, &stream, "page", &page_id);
            if page.as_object().is_none_or(Map::is_empty) || live(mc, space, page.clone()) {
                return refused("invalid", "Only pages in the trash can be deleted.");
            }
            for id in within(mc, space, &page_id) {
                for block in blocks_of(mc, space, &id) {
                    remove(mc, &stream, "block", &text(&block["id"]));
                }
                remove(mc, &stream, "page", &id);
            }
            Answer::ok(json!({"pageId": page_id}))
        }
        "block.insert" => {
            let after = After::of(input, "afterBlockId");
            insert_block(mc, space, &page_id, input, &after, &user())
        }
        "block.update" | "block.setChecked" => {
            let block_id = text(&input["blockId"]);
            let block = one(mc, &stream, "block", &block_id);
            if block.as_object().is_none_or(Map::is_empty) {
                return refused(
                    "notFound",
                    &format!("There is no block {block_id} in this Space."),
                );
            }
            if let Some(why) = writable(mc, space, &text(&block["pageId"])) {
                return why;
            }
            let kind = text(&block["kind"]);
            if method == "block.setChecked" {
                if kind != "checklist" {
                    return refused("invalid", "Only a checklist item can be ticked.");
                }
                let at = stamp(mc);
                set(
                    mc,
                    &stream,
                    "block",
                    &block_id,
                    json!({"checked": input["checked"], "updatedAt": at, "updatedBy": user()}),
                );
                return Answer::ok(json!({"block": one(mc, &stream, "block", &block_id)}));
            }
            if kind == GENERATED {
                return refused(
                    "invalid",
                    "What a page's update wrote cannot be edited by hand.",
                );
            }
            if input.get("level").is_some()
                && (kind != "heading" || !(1..=6).contains(&input["level"].as_i64().unwrap_or(0)))
            {
                return refused("invalid", "A heading's level is 1 to 6.");
            }
            let mut patch = json!({"text": input["text"], "updatedBy": user()});
            let code = kind == "code";
            let item = matches!(kind.as_str(), "bullet" | "numbered" | "checklist");
            let fields: [(&str, bool); 10] = [
                ("level", kind == "heading"),
                ("chart", input.get("chart").is_some()),
                ("language", code),
                ("fence", code),
                ("info", code),
                ("depth", item),
                ("indent", item),
                (
                    "marker",
                    matches!(
                        kind.as_str(),
                        "bullet" | "numbered" | "divider" | "callout" | "details"
                    ),
                ),
                ("start", kind == "numbered"),
                ("alert", kind == "callout"),
            ];
            for (field, kept) in fields {
                if kept && input.get(field).is_some() {
                    patch[field] = input[field].clone();
                }
            }
            patch["updatedAt"] = json!(stamp(mc));
            set(mc, &stream, "block", &block_id, patch);
            Answer::ok(json!({"block": one(mc, &stream, "block", &block_id)}))
        }
        "block.move" => {
            let block_id = text(&input["blockId"]);
            let block = one(mc, &stream, "block", &block_id);
            if block.as_object().is_none_or(Map::is_empty) {
                return refused(
                    "notFound",
                    &format!("There is no block {block_id} in this Space."),
                );
            }
            let block_page = text(&block["pageId"]);
            if let Some(why) = writable(mc, space, &block_page) {
                return why;
            }
            let after = After::of(input, "afterBlockId");
            let Some(order) = place(mc, space, &block_page, &after, &block_id) else {
                return refused(
                    "notFound",
                    &format!("There is no block {} on the page.", after.said()),
                );
            };
            set(mc, &stream, "block", &block_id, json!({"order": order}));
            Answer::ok(json!({"block": one(mc, &stream, "block", &block_id)}))
        }
        "block.delete" => {
            let block_id = text(&input["blockId"]);
            let block = one(mc, &stream, "block", &block_id);
            if block.as_object().is_none_or(Map::is_empty) {
                return refused(
                    "notFound",
                    &format!("There is no block {block_id} in this Space."),
                );
            }
            if let Some(why) = writable(mc, space, &text(&block["pageId"])) {
                return why;
            }
            remove(mc, &stream, "block", &block_id);
            Answer::ok(json!({"blockId": block_id}))
        }
        "block.visualize" => {
            if let Some(why) = writable(mc, space, &page_id) {
                return why;
            }
            let tag = "SpaceChartError";
            let chart = fake(mc).chart.clone();
            match fake(mc).generation.as_str() {
                "unavailable" => {
                    return refused_tag(
                        "unavailable",
                        "No chart was drawn: no text generation provider is set up.",
                        tag,
                    );
                }
                "failed" => {
                    return refused_tag(
                        "failed",
                        "No chart was drawn: the provider stopped answering.",
                        tag,
                    );
                }
                _ => {}
            }
            if chart.as_object().is_none_or(Map::is_empty) {
                return refused_tag(
                    "unanswerable",
                    "No chart was drawn: the page and this MC's threads cannot answer that.",
                    tag,
                );
            }
            let summary = format!(
                "{} (a chart; {})",
                text(&chart["title"]),
                text(&chart["source"])
            );
            let fields = json!({"kind": "chart", "text": summary, "chart": chart});
            let mut id = text(&input["blockId"]);
            if id.is_empty() {
                let after = After::of(input, "afterBlockId");
                let made = insert_block(
                    mc,
                    space,
                    &page_id,
                    &json!({"kind": "paragraph", "text": summary}),
                    &after,
                    &user(),
                );
                if !made.error.is_empty() {
                    return made;
                }
                id = text(&made.result["block"]["id"]);
            } else if text(&one(mc, &stream, "block", &id)["kind"]) != "chart" {
                return refused("invalid", "Only a chart can be asked for again.");
            }
            set(mc, &stream, "block", &id, fields);
            Answer::ok(json!({"block": one(mc, &stream, "block", &id)}))
        }
        "comment.add" => {
            if let Some(why) = writable(mc, space, &page_id) {
                return why;
            }
            let block_id = &input["blockId"];
            if block_id.is_string()
                && one(mc, &stream, "block", &text(block_id))
                    .as_object()
                    .is_none_or(Map::is_empty)
            {
                return refused(
                    "notFound",
                    &format!("There is no block {} in this Space.", text(block_id)),
                );
            }
            if text(&input["body"]).trim().is_empty() {
                return refused("invalid", "A comment needs some words.");
            }
            let comment_id = new_id(mc, "comment");
            let at = stamp(mc);
            let comment = json!({
                "id": comment_id, "pageId": page_id,
                "blockId": if block_id.is_string() { block_id.clone() } else { Value::Null },
                "body": input["body"],
                "author": user(),
                "createdAt": at, "updatedAt": at, "resolvedAt": Value::Null,
            });
            set(mc, &stream, "comment", &comment_id.clone(), comment.clone());
            Answer::ok(json!({"comment": comment}))
        }
        "comment.resolve" | "comment.reopen" => {
            let comment_id = text(&input["commentId"]);
            let comment = one(mc, &stream, "comment", &comment_id);
            if comment.as_object().is_none_or(Map::is_empty) {
                return refused(
                    "notFound",
                    &format!("There is no comment {comment_id} in this Space."),
                );
            }
            let resolved = !text(&comment["resolvedAt"]).is_empty();
            if method.ends_with("resolve") != !resolved {
                return refused(
                    "invalid",
                    if resolved {
                        "The comment is already resolved."
                    } else {
                        "The comment is already open."
                    },
                );
            }
            let at = stamp(mc);
            set(
                mc,
                &stream,
                "comment",
                &comment_id,
                json!({"resolvedAt": if method.ends_with("resolve") { json!(at) } else { Value::Null }}),
            );
            Answer::ok(json!({"comment": one(mc, &stream, "comment", &comment_id)}))
        }
        _ => refused(
            "invalid",
            &format!("space.{method} is missing a required field."),
        ),
    }
}

/// One `space.*` call, as the client sends it, written as the MC writes it:
/// a page change lands on its stream, is noted as a version, and marks its
/// site behind.
pub fn call(mc: &mut FakeMc, name: &str, input: &Value) -> Answer {
    let name = name.strip_prefix("space.").unwrap_or(name);
    seed(mc);
    let mut input = input.clone();
    if text(&input["spaceId"]).is_empty()
        && !matches!(
            name,
            "list" | "create" | "page.agentTarget" | "page.openFile" | "image.providers"
        )
    {
        seed(mc);
        input["spaceId"] = json!(
            sorted_by(all(mc, INDEX, "space"), "createdAt")
                .first()
                .map_or(String::new(), |s| text(&s["id"]))
        );
    }
    if name != "page.agentTarget" && name.ends_with("Agent") {
        return agent_call(mc, name, &input);
    }
    let answer = decide(mc, name, &input);
    let space = text(&input["spaceId"]);
    if answer.error.is_empty()
        && name != "page.restoreVersion"
        && name != "page.importMarkdown"
        && name != "page.createFromThread"
    {
        let author = if name == "page.schedule.runNow" {
            schedule_author()
        } else {
            user()
        };
        note_edits(mc, &space.clone(), &author);
    }
    // A change, with what it means for the Space's sites: the site of a page gone or
    // in the trash comes down, and the others are behind when publishing would change them.
    if !space.is_empty() {
        let stream = stream_of(&space);
        for site in all(mc, &stream, "site") {
            let page = one(mc, &stream, "page", &text(&site["pageId"]));
            let id = text(&site["id"]);
            let gone = page.as_object().is_none_or(Map::is_empty);
            if gone || !live(mc, &space, page.clone()) {
                remove(mc, &stream, "site", &id);
                continue;
            }
            let behind = site_snapshot(mc, &space, &page) != site["snapshot"];
            if behind != (site["behind"] == json!(true)) {
                set(mc, &stream, "site", &id, json!({"behind": behind}));
            }
        }
    }
    answer
}

// --- Whis is on the page ---------------------------------------------------------

pub fn viewers_frame(mc: &mut FakeMc, page_id: &str) -> Value {
    let mut viewers: Vec<Value> = Vec::new();
    let spaces = fake(mc);
    let mut devices = spaces.devices.get(page_id).cloned().unwrap_or_default();
    devices.sort();
    if !devices.is_empty() {
        viewers.push(json!({"type": "user", "devices": devices}));
    }
    for title in spaces.agents.get(page_id).into_iter().flatten() {
        viewers
            .push(json!({"type": "agent", "threadId": format!("thread-{title}"), "title": title}));
    }
    json!({"t": "spacePresence", "viewers": viewers})
}

pub fn show_viewers(mc: &mut FakeMc, page_id: &str) {
    for follower in mc.subscribers("spacePresence") {
        if text(&mc.shape_of(follower)["pageId"]) == page_id {
            let mut frame = viewers_frame(mc, page_id);
            frame["id"] = json!(follower);
            deliver(mc, frame);
        }
    }
}

/// The MC cannot say who is on a page: it answers an error and keeps nothing.
pub fn refuse_viewers(mc: &mut FakeMc, id: i64) {
    deliver(
        mc,
        json!({"t": "error", "id": id, "reason": "MC unavailable: noconnection"}),
    );
    mc.forget(id);
}

fn presence(mc: &mut FakeMc, id: i64, shape: &Value) -> Outcome {
    if fake(mc).viewers_refused {
        refuse_viewers(mc, id);
        return Ok(());
    }
    let mut frame = viewers_frame(mc, &text(&shape["pageId"]));
    frame["id"] = json!(id);
    deliver(mc, frame);
    Ok(())
}

pub fn extension(mc: &mut FakeMc) {
    // Every `space.*` call.
    mc.on_rpc("space.", |mc, rpc| {
        let name = rpc.method.clone();
        fake(mc).last_method.clone_from(&name);
        let answer = call(mc, &name, &rpc.payload);
        fake(mc).last_error.clone_from(&answer.error);
        fake(mc).last_result.clone_from(&answer.result);
        if answer.error.is_empty() {
            mc.reply(rpc, answer.result);
        } else if answer.detail.is_null() {
            mc.refuse(rpc, &answer.error);
        } else {
            mc.refuse_with(rpc, &answer.error, answer.detail);
        }
        Ok(())
    });
    mc.on_rpc("assets.createUrl", |mc, rpc| {
        let resource = &rpc.payload["resource"];
        if text(&resource["_tag"]) == "space-image" {
            let id = text(&resource["imageId"]);
            fake(mc).signed_images.push(id.clone());
            mc.reply(
                rpc,
                json!({
                    "relativeUrl": format!("/assets/space/{id}?signature=x"),
                    "expiresAt": 4_102_444_800_000_i64,
                }),
            );
            return Ok(());
        }
        super::files_identity::create_url(mc, rpc)
    });
    mc.on_shape("spacePresence", presence);
}

pub fn agent_target(mc: &mut FakeMc, accepted: bool) -> Answer {
    let threads = mc.threads.clone();
    let project = threads
        .values()
        .find(|thread| thread["archivedAt"].is_null() && thread["projectId"].is_string())
        .map(|thread| text(&thread["projectId"]))
        .unwrap_or_default();
    if project.is_empty() {
        return refused(
            "noTarget",
            "Agents have no project to work in. Add a project on this machine and try again.",
        );
    }
    if !accepted {
        return Answer::ok(json!({"projectId": Value::Null}));
    }
    Answer::ok(json!({"projectId": project}))
}
