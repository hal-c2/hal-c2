//! What the MC writes around a block's text, as SpaceController.cpp's
//! `markdownFrame` and `listItems` say it: a list item's place, and each
//! block's Markdown frame (above, lead, tail, below).

use serde_json::{Value, json};

use super::rows::Row;
use super::stream::{Entity, text};

/// A list item where the MC writes it (`HalC2.Space.Markdown.list_items/1`):
/// under the open items above it, at most one deeper than the deepest, a
/// numbered item counting on from the one before it at its depth in the
/// same list, else from its `start` or 1.
#[derive(Clone)]
pub struct ListItem {
    depth: usize,
    pub indent: i64,
    marker: String,
    number: i64,
    column: i64,
    list: String,
    /// The bulleted (checklists among them) and numbered lists it sits in.
    bullets: i64,
    numbers: i64,
}

pub fn list_items(blocks: &[Entity]) -> Vec<Option<ListItem>> {
    const LISTS: [&str; 3] = ["bullet", "numbered", "checklist"];
    let mut items: Vec<Option<ListItem>> = Vec::new();
    let mut open: Vec<ListItem> = Vec::new(); // deepest first
    for block in blocks {
        let kind = text(block, "kind");
        if !LISTS.contains(&kind.as_str()) {
            items.push(None);
            open.clear();
            continue;
        }
        let wanted = block
            .get("depth")
            .and_then(Value::as_i64)
            .unwrap_or(0)
            .max(0) as usize;
        let depth = wanted.min(open.len());
        let mut closed = 0;
        while closed < open.len() && open[closed].depth >= depth {
            closed += 1;
        }
        let sibling = (closed > 0).then(|| open[closed - 1].clone());
        let parents: Vec<ListItem> = open[closed..].to_vec();
        let floor = parents.first().map_or(0, |p| p.column);
        let marker_field = text(block, "marker");
        let numbered = kind == "numbered";
        let list_marker = if numbered {
            if marker_field == ")" { ")" } else { "." }.to_owned()
        } else if kind == "bullet" && (marker_field == "*" || marker_field == "+") {
            marker_field.clone()
        } else {
            "-".to_owned()
        };
        let mut item = ListItem {
            depth,
            indent: floor,
            marker: list_marker.clone(),
            number: 0,
            column: 0,
            list: if numbered {
                format!("numbered{list_marker}")
            } else {
                list_marker.clone()
            },
            bullets: 0,
            numbers: 0,
        };
        if numbered {
            let start = block.get("start");
            let from = match start.and_then(Value::as_i64) {
                Some(n) if (0..=999_999_999).contains(&n) => n,
                _ => 1,
            };
            item.number = match &sibling {
                Some(s) if s.list == item.list => s.number + 1,
                _ => from,
            };
            item.marker = format!("{}{}", item.number, list_marker);
        }
        let ceiling = sibling
            .as_ref()
            .map_or(floor + 3, |s| (floor + 3).min(s.column - 1));
        if let Some(indent) = block.get("indent").and_then(Value::as_i64)
            && indent >= floor
            && indent <= ceiling
        {
            item.indent = indent;
        }
        item.column = item.indent + item.marker.chars().count() as i64 + 1;
        item.numbers = parents
            .iter()
            .filter(|p| p.list.starts_with("numbered"))
            .count() as i64;
        item.bullets = parents.len() as i64 - item.numbers;
        items.push(Some(item.clone()));
        open = std::iter::once(item).chain(parents).collect();
    }
    items
}

/// Whether `line` closes code fenced by `fence`, as the MC reads it.
fn closes_fence(line: &str, fence: &str) -> bool {
    let trimmed = line.trim_start();
    if line.len() - trimmed.len() > 3 {
        return false;
    }
    let Some(first) = fence.chars().next() else {
        return false;
    };
    let run: String = trimmed.chars().take_while(|c| *c == first).collect();
    run.len() >= 3 && run.as_str() >= fence && trimmed[run.len()..].trim().is_empty()
}

/// The block's Markdown frame: {markdownAbove, markdownLead, markdownTail,
/// markdownBelow, listBullets, listNumbers}.
pub fn markdown_frame(block: &Entity, item: Option<&ListItem>) -> Row {
    let (mut above, mut lead, mut tail, mut below) =
        (String::new(), String::new(), String::new(), String::new());
    let kind = text(block, "kind");
    if let Some(item) = item {
        lead = " ".repeat(item.indent.max(0) as usize);
        if kind != "checklist" {
            lead.push_str(&item.marker);
            lead.push(' ');
        }
    } else if kind == "callout" {
        const ALERTS: [&str; 5] = ["note", "tip", "important", "warning", "caution"];
        let alert = text(block, "alert");
        if ALERTS.contains(&alert.as_str()) {
            above = format!("[!{}]", alert.to_uppercase());
        }
    } else if kind == "divider" {
        lead = if block.contains_key("marker") {
            text(block, "marker")
        } else {
            "---".into()
        };
    } else if kind == "footnote" {
        lead = format!("[^{}]: ", text(block, "label"));
    } else if kind == "details" {
        let opening = if block.contains_key("marker") {
            text(block, "marker")
        } else {
            "<details>\n<summary>".into()
        };
        let newline = opening.rfind('\n');
        above = opening[..newline.unwrap_or(0)].to_owned();
        lead = opening[newline.map_or(0, |n| n + 1)..].to_owned();
        // When there is no newline, all of it leads.
        if newline.is_none() {
            above.clear();
            lead = opening;
        }
        tail = "</summary>".into();
    } else if kind == "details_end" {
        lead = "</details>".into();
    } else if kind == "code" && text(block, "language") == "math" {
        let code = text(block, "text");
        let lines: Vec<&str> = if code.is_empty() {
            Vec::new()
        } else {
            code.split('\n').collect()
        };
        let mut fence = text(block, "fence");
        let dollars = fence == "$$"
            && lines
                .iter()
                .all(|l| l.trim() != "$$" && !l.trim().is_empty());
        if dollars {
            above = fence.clone();
            below = fence;
        } else {
            if fence.is_empty() || fence == "$$" {
                fence = "```".into();
            }
            while lines.iter().any(|l| closes_fence(l, &fence)) {
                let first = fence.chars().next().unwrap_or('`');
                fence.push(first);
            }
            above = format!("{fence}math{}", text(block, "info"));
            below = fence;
        }
    } else if kind == "image" && block.contains_key("url") {
        lead = "![".into();
        tail = format!("]({})", text(block, "url"));
    }
    let mut frame = Row::new();
    frame.insert("markdownAbove".into(), json!(above));
    frame.insert("markdownLead".into(), json!(lead));
    frame.insert("markdownTail".into(), json!(tail));
    frame.insert("markdownBelow".into(), json!(below));
    frame.insert("listBullets".into(), json!(item.map_or(0, |i| i.bullets)));
    frame.insert("listNumbers".into(), json!(item.map_or(0, |i| i.numbers)));
    frame
}
