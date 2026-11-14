//! desktop-qt's DiffModel: a unified git patch (the MC's
//! `orchestration.getTurnDiff`) as rows a ListView draws one line at a
//! time: a header per file, and under an expanded file its hunks and lines.
//!
//! The patch is kept whole and rows point into it, so a 10 MB diff costs one
//! scan (files and counts) up front and a file's lines are only split when
//! it is expanded. Expanding and collapsing a file inserts and removes its
//! rows; nothing else moves.
//!
//! A review cut short lists its files without their changes
//! ([`Diff::set_files`]): opening one asks for them ([`DiffNote::FileWanted`])
//! and they come with [`Diff::set_file_patch`], or the file says why not
//! ([`Diff::set_file_state`]).
//!
//! `split` pairs each run of removed lines with the added lines that follow
//! it, for a side-by-side view: a line row then has a left (old) and a right
//! (new) side.
//!
//! [`Diff`] is the core; [`DiffModel`] is the object QML binds, over a
//! [`Diff`] of its own ([`DiffModel::create`], what PullRequestReview owns)
//! or one another core holds ([`DiffModel::create_over`], ThreadDiff's).

use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use ljos::prelude::QmlValue;
use ljos::prelude::{Atom, Cx, Engine, ObjectId, QmlObject, Value, qml_impl};
use ljos::prelude::{EngineError, RowKey};
use serde_json::json;

use super::rows::{ListRows, RowChange, RowSource, int};
use crate::json::Json;

/// Up to this many changed and context lines, every file starts expanded.
pub const AUTO_EXPAND_LINES: usize = 4000;

pub const ROLES: &[&str] = &[
    "kind",
    "file",
    "path",
    "previousPath",
    "change",
    "binary",
    "additions",
    "deletions",
    "expanded",
    "text",
    "sign",
    "oldLine",
    "newLine",
    "rightText",
    "rightSign",
    "state",
    "note",
    "partial",
];

/// What changed besides the rows: the object's properties and signals.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiffNote {
    /// fileCount, additions, deletions and maxColumns.
    Patch,
    Split,
    /// allExpanded.
    Expansion,
    /// A folder of the tree was opened or closed.
    Tree,
    /// The file, listed without its changes, was opened.
    FileWanted(usize),
}

#[derive(Clone, Copy, Debug)]
struct Line {
    /// Into the patch, at the sign.
    offset: usize,
    /// With the sign, in bytes.
    length: usize,
    /// `+`, `-`, ` `, `\`, or `@` for a hunk header.
    sign: u8,
    old_line: i32,
    new_line: i32,
}

/// A line row: indexes into `File::lines`; none for an empty side.
#[derive(Clone, Copy, Debug)]
struct Pair {
    left: Option<usize>,
    right: Option<usize>,
}

#[derive(Clone, Debug)]
struct File {
    path: String,
    previous_path: String,
    change: &'static str,
    binary: bool,
    /// The first hunk's offset, or the end when it has none.
    body: usize,
    end: usize,
    additions: usize,
    deletions: usize,
    line_count: usize,
    expanded: bool,
    /// A file listed without its changes: "unloaded", "loading", "error",
    /// "missing" (no patch for it) or "gone" (the checkout no longer has
    /// this diff); "" once they are here.
    state: String,
    /// Why the file shows no changes, for its state.
    note: String,
    /// Its changes are cut short; its counts are whole.
    partial: bool,
    /// Split on first expansion.
    parsed: bool,
    lines: Vec<Line>,
    pairs: Vec<Pair>,
}

impl File {
    fn new(body: usize) -> File {
        File {
            path: String::new(),
            previous_path: String::new(),
            change: "modified",
            binary: false,
            body,
            end: 0,
            additions: 0,
            deletions: 0,
            line_count: 0,
            expanded: false,
            state: String::new(),
            note: String::new(),
            partial: false,
            parsed: false,
            lines: Vec::new(),
            pairs: Vec::new(),
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct Row {
    file: usize,
    /// None for the header, else into lines (or pairs, when split).
    line: Option<usize>,
}

fn key_of(row: Row) -> RowKey {
    ((row.file as u64) << 32) | row.line.map_or(0, |l| l as u64 + 1)
}

/// "@@ -12,3 +14,5 @@ ..." -> 12 and 14.
fn hunk_start(header: &str) -> (i32, i32) {
    let number_after = |sign: char| {
        let Some(at) = header.get(2..).and_then(|rest| rest.find(sign)) else {
            return 0;
        };
        let digits: String = header[2 + at + 1..]
            .chars()
            .take_while(char::is_ascii_digit)
            .collect();
        digits.parse().unwrap_or(0)
    };
    (number_after('-'), number_after('+'))
}

fn strip_prefix(path: &str) -> String {
    path.strip_prefix("a/")
        .or_else(|| path.strip_prefix("b/"))
        .unwrap_or(path)
        .to_owned()
}

/// A patch as rows.
#[derive(Debug, Default)]
pub struct Diff {
    patch: String,
    files: Vec<File>,
    rows: Vec<Row>,
    additions: usize,
    deletions: usize,
    max_columns: usize,
    split: bool,
    collapsed_by_default: bool,
    closed_folders: HashSet<String>,
    changes: Vec<RowChange>,
    notes: Vec<DiffNote>,
}

impl Diff {
    pub fn new() -> Diff {
        Diff::default()
    }

    /// Replaces the patch; files start expanded when the whole patch is
    /// small, unless diffs open collapsed.
    pub fn set_patch(&mut self, patch: &str) {
        let listed = self.files.iter().any(|f| !f.state.is_empty() || f.partial);
        if patch == self.patch && !listed {
            return;
        }
        let all_before = self.all_expanded();
        self.patch = patch.to_owned();
        self.parse();
        let total: usize = self.files.iter().map(|f| f.line_count).sum();
        let open = !self.collapsed_by_default && total <= AUTO_EXPAND_LINES;
        for f in 0..self.files.len() {
            self.files[f].expanded = open;
            if open {
                self.ensure_lines(f);
            }
        }
        self.rebuild_rows();
        self.reset();
        self.notes.push(DiffNote::Patch);
        if self.all_expanded() != all_before {
            self.notes.push(DiffNote::Expansion);
        }
    }

    /// The "Default diff file state" setting: the next patch opens with
    /// every file collapsed.
    pub fn set_collapsed_by_default(&mut self, collapsed: bool) {
        self.collapsed_by_default = collapsed;
    }

    pub fn clear(&mut self) {
        self.set_patch("");
    }

    pub fn patch(&self) -> &str {
        &self.patch
    }

    pub fn file_count(&self) -> usize {
        self.files.len()
    }

    pub fn additions(&self) -> usize {
        self.additions
    }

    pub fn deletions(&self) -> usize {
        self.deletions
    }

    /// The longest line in the patch, in characters: how wide a row can get.
    pub fn max_columns(&self) -> usize {
        self.max_columns
    }

    pub fn split(&self) -> bool {
        self.split
    }

    pub fn set_split(&mut self, split: bool) {
        if split == self.split {
            return;
        }
        self.split = split;
        self.rebuild_rows();
        self.reset();
        self.notes.push(DiffNote::Split);
    }

    pub fn all_expanded(&self) -> bool {
        // A file still waiting for its changes is only opened by hand.
        self.files.iter().all(|f| f.expanded || waiting(f))
    }

    /// A review's files without their changes: `[{path, previousPath,
    /// additions, deletions}]`, each closed until opened.
    pub fn set_files(&mut self, files: &[Json]) {
        let all_before = self.all_expanded();
        self.patch.clear();
        self.files.clear();
        self.additions = 0;
        self.deletions = 0;
        self.max_columns = 0;
        for stat in files {
            let text = |key: &str| {
                stat.get(key)
                    .and_then(Json::as_str)
                    .unwrap_or("")
                    .to_owned()
            };
            let count = |key: &str| stat.get(key).and_then(Json::as_u64).unwrap_or(0) as usize;
            let mut file = File::new(0);
            file.path = text("path");
            file.previous_path = text("previousPath");
            if !file.previous_path.is_empty() && file.previous_path != file.path {
                file.change = "renamed";
            } else {
                file.previous_path.clear();
            }
            file.additions = count("additions");
            file.deletions = count("deletions");
            file.state = "unloaded".to_owned();
            file.parsed = true;
            self.additions += file.additions;
            self.deletions += file.deletions;
            self.files.push(file);
        }
        self.rebuild_rows();
        self.reset();
        self.notes.push(DiffNote::Patch);
        if self.all_expanded() != all_before {
            self.notes.push(DiffNote::Expansion);
        }
    }

    /// `file`'s changes, from a patch that has them (one of `patch`'s files
    /// has its path); false when none does. `partial`: they are cut short.
    pub fn set_file_patch(&mut self, file: usize, patch: &str, partial: bool) -> bool {
        // A file whose changes are here keeps them.
        if !self.files.get(file).is_some_and(waiting) {
            return false;
        }
        let from = self.patch.len();
        // Its own part of the patch, after every other file's.
        self.patch.push_str(patch);
        if !self.patch.ends_with('\n') {
            self.patch.push('\n');
        }
        let (parsed, columns) = parse_from(&self.patch, from);
        let Some(found) = parsed.into_iter().find(|f| f.path == self.files[file].path) else {
            self.patch.truncate(from);
            return false;
        };
        self.max_columns = self.max_columns.max(columns);
        let all_before = self.all_expanded();
        let header = self.row_of_file(file).unwrap_or(0);
        let entry = &mut self.files[file];
        // The counts listed are whole; the patch may not be.
        let (additions, deletions, expanded) = (entry.additions, entry.deletions, entry.expanded);
        *entry = found;
        entry.additions = additions;
        entry.deletions = deletions;
        entry.partial = partial;
        entry.expanded = expanded;
        if expanded {
            self.ensure_lines(file);
            let shown = self.lines_shown(&self.files[file]);
            if shown > 0 {
                let rows: Vec<Row> = (0..shown)
                    .map(|l| Row {
                        file,
                        line: Some(l),
                    })
                    .collect();
                let keys = rows.iter().map(|r| key_of(*r)).collect();
                self.rows.splice(header + 1..header + 1, rows);
                self.changes.push(RowChange::Inserted {
                    first: header + 1,
                    keys,
                });
            }
        }
        self.changes.push(RowChange::Changed {
            first: header,
            count: 1,
            roles: ROLES,
        });
        self.notes.push(DiffNote::Patch);
        if self.all_expanded() != all_before {
            self.notes.push(DiffNote::Expansion);
        }
        true
    }

    pub fn set_file_state(&mut self, file: usize, state: &str, note: &str) {
        // A file whose changes are here keeps them.
        let Some(entry) = self.files.get_mut(file).filter(|f| waiting(f)) else {
            return;
        };
        entry.state = state.to_owned();
        entry.note = note.to_owned();
        if let Some(header) = self.row_of_file(file) {
            self.changes.push(RowChange::Changed {
                first: header,
                count: 1,
                roles: &["state", "note"],
            });
        }
    }

    /// The file's state: "" once its changes are here.
    pub fn state(&self, file: usize) -> &str {
        self.files.get(file).map_or("", |f| f.state.as_str())
    }

    pub fn previous_path(&self, file: usize) -> Option<&str> {
        self.files.get(file).map(|f| f.previous_path.as_str())
    }

    /// Closes or opens a folder of the tree; it stays so across patches.
    pub fn toggle_folder(&mut self, path: &str) {
        if !self.closed_folders.remove(path) {
            self.closed_folders.insert(path.to_owned());
        }
        self.notes.push(DiffNote::Tree);
    }

    pub fn folder_open(&self, path: &str) -> bool {
        !self.closed_folders.contains(path)
    }

    pub fn paths(&self) -> Vec<String> {
        self.files.iter().map(|f| f.path.clone()).collect()
    }

    /// The file's path (its new one when renamed).
    pub fn path(&self, file: usize) -> Option<&str> {
        self.files.get(file).map(|f| f.path.as_str())
    }

    pub fn expanded(&self, file: usize) -> bool {
        self.files.get(file).is_some_and(|f| f.expanded)
    }

    /// The header row of `file`.
    pub fn row_of_file(&self, file: usize) -> Option<usize> {
        (file < self.files.len()).then(|| self.rows.partition_point(|r| r.file < file))
    }

    pub fn file_of(&self, path: &str) -> Option<usize> {
        self.files.iter().position(|f| f.path == path)
    }

    /// The changed files by folder, for a tree beside the diff, in the
    /// order the diff has them: a folder where its first file is. A path the
    /// diff has twice (a file replaced by a link) is listed once, as
    /// modified. `[{kind: "folder"|"file", name, path, depth, file (a
    /// file's index), change, additions, deletions, open (a folder's), shown
    /// (no folder above it is closed)}]`.
    pub fn tree(&self) -> Vec<Json> {
        struct Node {
            name: String,
            path: String,
            /// A file's index; none for a folder.
            file: Option<usize>,
            change: &'static str,
            additions: usize,
            deletions: usize,
            children: Vec<usize>,
        }
        let folder = |name: &str, path: &str| Node {
            name: name.to_owned(),
            path: path.to_owned(),
            file: None,
            change: "",
            additions: 0,
            deletions: 0,
            children: Vec::new(),
        };
        let mut nodes = vec![folder("", "")];
        let mut folders: HashMap<String, usize> = HashMap::new();
        let mut files: HashMap<&str, usize> = HashMap::new();
        for (index, file) in self.files.iter().enumerate() {
            if let Some(&known) = files.get(file.path.as_str()) {
                // The same path twice: a file replaced by a link.
                let node = &mut nodes[known];
                node.change = "modified";
                node.additions += file.additions;
                node.deletions += file.deletions;
                continue;
            }
            let parts: Vec<&str> = file.path.split('/').collect();
            let mut parent = 0;
            let mut prefix = String::new();
            for part in &parts[..parts.len() - 1] {
                prefix.push_str(part);
                let at = match folders.get(&prefix) {
                    Some(&at) => at,
                    None => {
                        nodes.push(folder(part, &prefix));
                        let at = nodes.len() - 1;
                        folders.insert(prefix.clone(), at);
                        nodes[parent].children.push(at);
                        at
                    }
                };
                parent = at;
                prefix.push('/');
            }
            nodes.push(Node {
                name: parts[parts.len() - 1].to_owned(),
                path: file.path.clone(),
                file: Some(index),
                change: file.change,
                additions: file.additions,
                deletions: file.deletions,
                children: Vec::new(),
            });
            let at = nodes.len() - 1;
            files.insert(file.path.as_str(), at);
            nodes[parent].children.push(at);
        }
        fn walk(
            diff: &Diff,
            nodes: &[Node],
            node: usize,
            depth: usize,
            shown: bool,
            out: &mut Vec<Json>,
        ) {
            for &child in &nodes[node].children {
                let each = &nodes[child];
                match each.file {
                    None => {
                        let open = diff.folder_open(&each.path);
                        out.push(
                            json!({"kind": "folder", "name": each.name, "path": each.path,
                                        "depth": depth, "open": open, "shown": shown}),
                        );
                        walk(diff, nodes, child, depth + 1, shown && open, out);
                    }
                    Some(file) => out.push(json!({"kind": "file", "name": each.name,
                                                  "path": each.path, "depth": depth, "file": file,
                                                  "change": each.change,
                                                  "additions": each.additions,
                                                  "deletions": each.deletions, "shown": shown})),
                }
            }
        }
        let mut out = Vec::new();
        walk(self, &nodes, 0, 0, true, &mut out);
        out
    }

    /// The lines `first` to `last` of one side of `file` ("old": removed
    /// lines by their old numbers; else added and unchanged lines by their
    /// new ones), for a comment on them: `{startIndex, endIndex (among the
    /// file's lines), diff (the lines with their signs), rangeLabel ("+10
    /// to +12", the sign when every line has the same)}`. Empty when the
    /// file shows none of them.
    pub fn excerpt(&mut self, file: usize, side: &str, first: i32, last: i32) -> Json {
        let empty = Json::Object(serde_json::Map::new());
        if file >= self.files.len() || first <= 0 {
            return empty;
        }
        let (first, last) = if last < first {
            (last, first)
        } else {
            (first, last)
        };
        self.ensure_lines(file);
        let old = side == "old";
        let mut picked: Vec<&str> = Vec::new();
        let (mut start, mut end, mut index) = (None, 0usize, None::<usize>);
        let mut same = b' ';
        let mut mixed = false;
        for line in &self.files[file].lines {
            if line.sign == b'@' || line.sign == b'\\' {
                continue;
            }
            let at = index.map_or(0, |i| i + 1);
            index = Some(at);
            let number = if old { line.old_line } else { line.new_line };
            let wrong_side = if old {
                line.sign != b'-'
            } else {
                line.sign == b'-'
            };
            if wrong_side || number < first || number > last {
                continue;
            }
            start.get_or_insert(at);
            end = at;
            if picked.is_empty() {
                same = line.sign;
            } else if line.sign != same {
                mixed = true;
            }
            picked.push(&self.patch[line.offset..line.offset + line.length]);
        }
        let Some(start) = start else {
            return empty;
        };
        let marker = if mixed || same == b' ' {
            String::new()
        } else {
            char::from(same).to_string()
        };
        let label = if first == last {
            format!("{marker}{first}")
        } else {
            format!("{marker}{first} to {marker}{last}")
        };
        json!({"startIndex": start, "endIndex": end, "diff": picked.join("\n"),
               "rangeLabel": label})
    }

    pub fn toggle(&mut self, file: usize) {
        let expand = !self.expanded(file);
        self.set_expanded(file, expand);
    }

    pub fn set_expanded(&mut self, file: usize, expand: bool) {
        let all_before = self.all_expanded();
        self.expand_one(file, expand);
        if self.all_expanded() != all_before {
            self.notes.push(DiffNote::Expansion);
        }
    }

    pub fn expand_all(&mut self) {
        let all_before = self.all_expanded();
        for f in 0..self.files.len() {
            if !waiting(&self.files[f]) {
                self.expand_one(f, true);
            }
        }
        if !all_before {
            self.notes.push(DiffNote::Expansion);
        }
    }

    pub fn collapse_all(&mut self) {
        let all_before = self.all_expanded();
        for f in 0..self.files.len() {
            self.expand_one(f, false);
        }
        if self.all_expanded() != all_before {
            self.notes.push(DiffNote::Expansion);
        }
    }

    /// What changed besides the rows since the last call, in order.
    pub fn take_notes(&mut self) -> Vec<DiffNote> {
        std::mem::take(&mut self.notes)
    }

    fn reset(&mut self) {
        let keys = self.rows.iter().map(|r| key_of(*r)).collect();
        self.changes.push(RowChange::Reset(keys));
    }

    fn parse(&mut self) {
        let (files, columns) = parse_from(&self.patch, 0);
        self.files = files;
        self.max_columns = columns;
        self.additions = self.files.iter().map(|f| f.additions).sum();
        self.deletions = self.files.iter().map(|f| f.deletions).sum();
    }

    fn ensure_lines(&mut self, index: usize) {
        let text = self.patch.as_str();
        let file = &mut self.files[index];
        if file.parsed {
            return;
        }
        file.parsed = true;
        file.lines.reserve(file.line_count);
        let (mut old_line, mut new_line) = (0, 0);
        let mut at = file.body;
        while at < file.end {
            let end = text[at..]
                .find('\n')
                .map_or(file.end, |n| (at + n).min(file.end));
            let line = &text[at..end];
            let mut row = Line {
                offset: at,
                length: line.len(),
                sign: b' ',
                old_line: 0,
                new_line: 0,
            };
            if line.starts_with("@@") {
                row.sign = b'@';
                (old_line, new_line) = hunk_start(line);
            } else if line.starts_with('+') {
                row.sign = b'+';
                row.new_line = new_line;
                new_line += 1;
            } else if line.starts_with('-') {
                row.sign = b'-';
                row.old_line = old_line;
                old_line += 1;
            } else if line.starts_with('\\') {
                row.sign = b'\\';
            } else if line.is_empty() && end >= file.end {
                break; // the patch's trailing newline
            } else {
                row.old_line = old_line;
                row.new_line = new_line;
                old_line += 1;
                new_line += 1;
            }
            file.lines.push(row);
            at = end + 1;
        }
        pair_lines(file);
    }

    fn lines_shown(&self, file: &File) -> usize {
        match (file.expanded, self.split) {
            (false, _) => 0,
            (true, true) => file.pairs.len(),
            (true, false) => file.lines.len(),
        }
    }

    fn rebuild_rows(&mut self) {
        let mut rows = Vec::new();
        for (f, file) in self.files.iter().enumerate() {
            rows.push(Row {
                file: f,
                line: None,
            });
            for l in 0..self.lines_shown(file) {
                rows.push(Row {
                    file: f,
                    line: Some(l),
                });
            }
        }
        self.rows = rows;
    }

    /// Inserts or removes the file's rows; the callers note when
    /// allExpanded changes.
    fn expand_one(&mut self, file: usize, expand: bool) {
        if file >= self.files.len() || self.files[file].expanded == expand {
            return;
        }
        let header = self.row_of_file(file).unwrap_or(0);
        if expand {
            self.ensure_lines(file);
            self.files[file].expanded = true;
            if matches!(self.files[file].state.as_str(), "unloaded" | "error") {
                self.notes.push(DiffNote::FileWanted(file));
            }
            let shown = self.lines_shown(&self.files[file]);
            if shown > 0 {
                let rows: Vec<Row> = (0..shown)
                    .map(|l| Row {
                        file,
                        line: Some(l),
                    })
                    .collect();
                let keys = rows.iter().map(|r| key_of(*r)).collect();
                self.rows.splice(header + 1..header + 1, rows);
                self.changes.push(RowChange::Inserted {
                    first: header + 1,
                    keys,
                });
            }
        } else {
            let shown = self.lines_shown(&self.files[file]);
            self.files[file].expanded = false;
            if shown > 0 {
                self.rows.drain(header + 1..header + 1 + shown);
                self.changes.push(RowChange::Removed {
                    first: header + 1,
                    count: shown,
                });
            }
        }
        self.changes.push(RowChange::Changed {
            first: header,
            count: 1,
            roles: &["expanded"],
        });
    }

    fn text_of(&self, file: &File, line: Option<usize>) -> String {
        let Some(line) = line else {
            return String::new();
        };
        let entry = file.lines[line];
        let text = &self.patch[entry.offset..entry.offset + entry.length];
        if entry.sign == b'@' {
            return text.to_owned();
        }
        let mut chars = text.chars();
        chars.next();
        chars.as_str().to_owned()
    }
}

fn waiting(file: &File) -> bool {
    !file.state.is_empty()
}

/// The MC's patch without the mark it ends a cut patch with.
pub fn without_truncated_marker(patch: &str) -> String {
    match patch.strip_suffix("\n\n[truncated]") {
        Some(kept) => format!("{kept}\n"),
        None => patch.to_owned(),
    }
}

/// The files of `text` from `from` on, and the longest line among them.
fn parse_from(text: &str, from: usize) -> (Vec<File>, usize) {
    let mut files: Vec<File> = Vec::new();
    let mut max_columns = 0;
    let mut in_hunk = false;
    let mut at = from;
    while at < text.len() {
        let end = text[at..].find('\n').map_or(text.len(), |n| at + n);
        let line = &text[at..end];
        if line.starts_with("diff --git ") {
            if let Some(file) = files.last_mut() {
                file.end = at;
            }
            let mut file = File::new(end + 1);
            in_hunk = false;
            // "diff --git a/x b/x": good enough until ---/+++ or rename
            // lines say.
            if let Some(split) = line.rfind(" b/").filter(|s| *s > 0) {
                file.path = line[split + 3..].to_owned();
            }
            files.push(file);
        } else if let Some(file) = files.last_mut() {
            if line.starts_with("@@") {
                if !in_hunk {
                    file.body = at;
                }
                in_hunk = true;
                file.line_count += 1;
            } else if in_hunk {
                file.line_count += 1;
                if line.starts_with('+') {
                    file.additions += 1;
                } else if line.starts_with('-') {
                    file.deletions += 1;
                }
                max_columns = max_columns.max(line.chars().count());
            } else if line.starts_with("+++ ") && !line.ends_with("/dev/null") {
                file.path = strip_prefix(&line[4..]);
            } else if line.starts_with("--- ") && !line.ends_with("/dev/null") {
                file.previous_path = strip_prefix(&line[4..]);
            } else if line.starts_with("new file") {
                file.change = "added";
            } else if line.starts_with("deleted file") {
                file.change = "deleted";
            } else if let Some(from) = line.strip_prefix("rename from ") {
                file.change = "renamed";
                file.previous_path = from.to_owned();
            } else if let Some(to) = line.strip_prefix("rename to ") {
                file.path = to.to_owned();
            } else if line.starts_with("Binary files") || line.starts_with("GIT binary patch") {
                file.binary = true;
            }
        }
        // Anything before the first file header is not ours to show.
        at = end + 1;
    }
    if let Some(file) = files.last_mut() {
        file.end = text.len();
    }
    for file in &mut files {
        // A file with no hunks has its body at its end.
        if file.line_count == 0 {
            file.body = file.end;
        }
        if file.change != "renamed" && file.previous_path == file.path {
            file.previous_path.clear();
        }
        if file.change == "deleted" && file.path.is_empty() {
            file.path = file.previous_path.clone();
        }
    }
    (files, max_columns)
}

fn pair_lines(file: &mut File) {
    file.pairs.clear();
    let count = file.lines.len();
    let sign = |i: usize| file.lines[i].sign;
    let mut pairs = Vec::new();
    let mut i = 0;
    while i < count {
        let s = sign(i);
        if s != b'-' && s != b'+' {
            pairs.push(Pair {
                left: Some(i),
                right: (s != b'\\').then_some(i),
            });
            i += 1;
            continue;
        }
        // A run of removals and the additions after it, side by side.
        let mut removed = i;
        while removed < count && sign(removed) == b'-' {
            removed += 1;
        }
        let mut added = removed;
        while added < count && sign(added) == b'+' {
            added += 1;
        }
        let (left, right) = (removed - i, added - removed);
        for k in 0..left.max(right) {
            pairs.push(Pair {
                left: (k < left).then_some(i + k),
                right: (k < right).then_some(removed + k),
            });
        }
        i = added;
    }
    file.pairs = pairs;
}

/// What a row has for a role that is not its kind's: the role type's empty
/// value, so a delegate's typed required property gets one.
fn blank(role: &str) -> Value {
    match role {
        "file" | "additions" | "deletions" | "oldLine" | "newLine" => Value::Int(0),
        "binary" | "expanded" | "partial" => Value::Bool(false),
        _ if ROLES.contains(&role) => Value::from(""),
        _ => Value::Undefined,
    }
}

impl RowSource for Diff {
    fn roles(&self) -> &'static [&'static str] {
        ROLES
    }

    fn row_count(&self) -> usize {
        self.rows.len()
    }

    fn row_key(&self, row: usize) -> RowKey {
        self.rows.get(row).map_or(row as RowKey, |r| key_of(*r))
    }

    fn data(&self, row: usize, role: &str) -> Value {
        let Some(row) = self.rows.get(row).copied() else {
            return Value::Undefined;
        };
        let file = &self.files[row.file];
        if role == "file" {
            return Value::Int(int(row.file));
        }
        let Some(line) = row.line else {
            return match role {
                "kind" => Value::from("file"),
                "path" => Value::from(file.path.as_str()),
                "previousPath" => Value::from(file.previous_path.as_str()),
                "change" => Value::from(file.change),
                "binary" => Value::Bool(file.binary),
                "additions" => Value::Int(int(file.additions)),
                "deletions" => Value::Int(int(file.deletions)),
                "expanded" => Value::Bool(file.expanded),
                "state" => Value::from(file.state.as_str()),
                "note" => Value::from(file.note.as_str()),
                "partial" => Value::Bool(file.partial),
                _ => blank(role),
            };
        };
        let (left, right) = if self.split {
            let pair = file.pairs[line];
            (pair.left, pair.right)
        } else {
            (Some(line), None)
        };
        let sign_of = |line: Option<usize>| {
            line.map_or_else(String::new, |l| char::from(file.lines[l].sign).to_string())
        };
        let any = left.or(right).unwrap_or(0);
        let hunk = file.lines[any].sign == b'@';
        let text = |s: String| Value::from(s.as_str());
        match role {
            "kind" => Value::from(if hunk { "hunk" } else { "line" }),
            "path" if hunk => text(self.text_of(file, Some(any))),
            "path" => Value::from(file.path.as_str()),
            "text" => text(self.text_of(file, left)),
            "sign" if hunk => Value::from(""),
            "sign" => text(sign_of(left)),
            "oldLine" => Value::Int(left.map_or(0, |l| file.lines[l].old_line)),
            "newLine" => {
                let line = if self.split { right } else { left };
                Value::Int(line.map_or(0, |l| file.lines[l].new_line))
            }
            "rightText" if self.split && !hunk => text(self.text_of(file, right)),
            "rightSign" if self.split && !hunk => text(sign_of(right)),
            "rightText" | "rightSign" => Value::from(""),
            "expanded" => Value::Bool(file.expanded),
            _ => blank(role),
        }
    }

    fn take_changes(&mut self) -> Vec<RowChange> {
        std::mem::take(&mut self.changes)
    }
}

/// A core that holds a [`Diff`] and shows its rows.
pub trait AsDiff {
    fn diff(&self) -> &Diff;
    fn diff_mut(&mut self) -> &mut Diff;
}

impl AsDiff for Diff {
    fn diff(&self) -> &Diff {
        self
    }

    fn diff_mut(&mut self) -> &mut Diff {
        self
    }
}

/// Where a [`DiffModel`] finds its [`Diff`]: the rows of a core that holds
/// one.
pub trait DiffHost {
    /// Runs `f` on the diff, then tells the views what it changed.
    fn update_diff(&self, engine: &Engine, f: &mut dyn FnMut(&mut Diff));
    fn read_diff(&self, f: &mut dyn FnMut(&Diff));
}

impl<S: RowSource + AsDiff + 'static> DiffHost for ListRows<S> {
    fn update_diff(&self, engine: &Engine, f: &mut dyn FnMut(&mut Diff)) {
        self.update(engine, |core| f(core.diff_mut()));
    }

    fn read_diff(&self, f: &mut dyn FnMut(&Diff)) {
        self.read(|core| f(core.diff()));
    }
}

struct Host(Rc<dyn DiffHost>);

impl std::fmt::Debug for Host {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DiffHost")
    }
}

/// A patch as the diff panel's rows: `ThreadDiff.model`, and the pull
/// request review's.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "DiffModel", uncreatable)]
pub struct DiffModel {
    #[qml(readonly, notify)]
    file_count: i32,
    #[qml(readonly, notify)]
    additions: i32,
    #[qml(readonly, notify)]
    deletions: i32,
    /// The longest line in the patch, in characters.
    #[qml(readonly, notify)]
    max_columns: i32,
    /// Side by side; QML writes it.
    #[qml(notify)]
    split: bool,
    #[qml(readonly, notify)]
    all_expanded: bool,
    #[qml(skip)]
    host: Host,
}

fn host_of(engine: &Engine, obj: ObjectId) -> Option<Rc<dyn DiffHost>> {
    engine.with::<DiffModel, _>(obj, |m| m.host.0.clone()).ok()
}

impl DiffModel {
    /// A model over a diff of its own, owned by `owner`.
    pub fn create(engine: &Engine, owner: Option<ObjectId>) -> Result<ObjectId, EngineError> {
        DiffModel::create_over(engine, owner, ListRows::new(Diff::new()))
    }

    /// A model over the diff `rows`' core holds, owned by `owner`. Whoever
    /// changes that diff other than through [`DiffModel::update`] calls
    /// [`DiffModel::sync`] after.
    pub fn create_over<S: RowSource + AsDiff + 'static>(
        engine: &Engine,
        owner: Option<ObjectId>,
        rows: Rc<ListRows<S>>,
    ) -> Result<ObjectId, EngineError> {
        let model = DiffModel {
            file_count: 0,
            additions: 0,
            deletions: 0,
            max_columns: 0,
            split: false,
            all_expanded: true,
            host: Host(rows.clone()),
        };
        let obj = engine.create_native(model, owner)?;
        rows.attach(engine, obj)?;
        // QML writes `split`; the diff follows.
        engine.connect_by_name(obj, "splitChanged", move |engine, _| {
            let split = engine.get(obj, DiffModel::SPLIT);
            if let Ok(split) = split {
                DiffModel::update(engine, obj, |d| d.set_split(split));
            }
        })?;
        DiffModel::sync(engine, obj);
        Ok(obj)
    }

    /// Runs `f` on the diff of `obj`, then tells the views and the
    /// properties what it changed. None when `obj` is not a live DiffModel.
    pub fn update<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&mut Diff) -> R) -> Option<R> {
        let host = host_of(engine, obj)?;
        let mut f = Some(f);
        let mut result = None;
        host.update_diff(engine, &mut |d| {
            if let Some(f) = f.take() {
                result = Some(f(d));
            }
        });
        DiffModel::sync(engine, obj);
        result
    }

    /// Reads the diff of `obj`. `f` must not call back into it.
    pub fn read<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&Diff) -> R) -> Option<R> {
        let host = host_of(engine, obj)?;
        let mut f = Some(f);
        let mut result = None;
        host.read_diff(&mut |d| {
            if let Some(f) = f.take() {
                result = Some(f(d));
            }
        });
        result
    }

    /// Reads what the diff changed into the properties, and says so.
    pub fn sync(engine: &Engine, obj: ObjectId) {
        let Some(host) = host_of(engine, obj) else {
            return;
        };
        let mut notes = Vec::new();
        let mut facts = (0, 0, 0, 0, false, true);
        host.update_diff(engine, &mut |d| {
            notes = d.take_notes();
            facts = (
                int(d.file_count()),
                int(d.additions()),
                int(d.deletions()),
                int(d.max_columns()),
                d.split(),
                d.all_expanded(),
            );
        });
        let (files, additions, deletions, columns, split, all) = facts;
        let cx = Cx::new(engine, obj);
        let result = engine
            .set_internal(obj, DiffModel::FILE_COUNT, files)
            .and_then(|()| engine.set_internal(obj, DiffModel::ADDITIONS, additions))
            .and_then(|()| engine.set_internal(obj, DiffModel::DELETIONS, deletions))
            .and_then(|()| engine.set_internal(obj, DiffModel::MAX_COLUMNS, columns))
            .and_then(|()| engine.set_internal(obj, DiffModel::SPLIT, split))
            .and_then(|()| engine.set_internal(obj, DiffModel::ALL_EXPANDED, all));
        let result = result.and_then(|()| {
            notes.iter().try_for_each(|note| match note {
                DiffNote::Patch => DiffModel::emit_patch_changed(&cx),
                DiffNote::Expansion => DiffModel::emit_expansion_changed(&cx),
                DiffNote::Tree => DiffModel::emit_tree_changed(&cx),
                DiffNote::FileWanted(file) => DiffModel::emit_file_wanted(&cx, int(*file)),
                // splitChanged is the property's own.
                DiffNote::Split => Ok(()),
            })
        });
        if let Err(e) = result {
            engine.log(ljos::prelude::LogLevel::Warning, "DiffModel", e.to_string());
        }
    }
}

fn index(value: i32) -> usize {
    usize::try_from(value).unwrap_or(usize::MAX)
}

#[qml_impl]
impl DiffModel {
    /// fileCount, additions, deletions and maxColumns changed.
    #[qml(signal)]
    fn patch_changed();
    /// allExpanded changed.
    #[qml(signal)]
    fn expansion_changed();
    /// A folder of the tree opened or closed.
    #[qml(signal)]
    fn tree_changed();
    /// `file` was opened while its patch is not loaded.
    #[qml(signal)]
    fn file_wanted(file: i32);

    /// The changed files by folder, for a tree beside the diff.
    #[qml(invokable)]
    fn tree(cx: &Cx) -> Value {
        let tree = DiffModel::read(cx.engine, cx.this, Diff::tree).unwrap_or_default();
        Json::Array(tree).to_value()
    }

    #[qml(invokable)]
    fn toggle_folder(cx: &Cx, path: Atom) {
        DiffModel::update(cx.engine, cx.this, |d| d.toggle_folder(&path));
    }

    #[qml(invokable)]
    fn folder_open(cx: &Cx, path: Atom) -> bool {
        DiffModel::read(cx.engine, cx.this, |d| d.folder_open(&path)).unwrap_or(true)
    }

    /// Whether `file`'s patch is "" (here), "unloaded", "loading", "error",
    /// "missing" or "gone".
    #[qml(invokable)]
    fn state(cx: &Cx, file: i32) -> String {
        DiffModel::read(cx.engine, cx.this, |d| d.state(index(file)).to_owned()).unwrap_or_default()
    }

    #[qml(invokable)]
    fn path(cx: &Cx, file: i32) -> String {
        DiffModel::read(cx.engine, cx.this, |d| {
            d.path(index(file)).unwrap_or_default().to_owned()
        })
        .unwrap_or_default()
    }

    /// The lines `first` to `last` of one side of `file`, for a comment.
    #[qml(invokable)]
    fn excerpt(cx: &Cx, file: i32, side: Atom, first: i32, last: i32) -> Value {
        let found = DiffModel::update(cx.engine, cx.this, |d| {
            d.excerpt(index(file), &side, first, last)
        });
        found.unwrap_or_else(|| json!({})).to_value()
    }

    /// The header row of `file`, or -1.
    #[qml(invokable)]
    fn row_of_file(cx: &Cx, file: i32) -> i32 {
        DiffModel::read(cx.engine, cx.this, |d| d.row_of_file(index(file)))
            .flatten()
            .map_or(-1, int)
    }

    #[qml(invokable)]
    fn file_of(cx: &Cx, path: Atom) -> i32 {
        DiffModel::read(cx.engine, cx.this, |d| d.file_of(&path))
            .flatten()
            .map_or(-1, int)
    }

    #[qml(invokable)]
    fn toggle(cx: &Cx, file: i32) {
        DiffModel::update(cx.engine, cx.this, |d| d.toggle(index(file)));
    }

    #[qml(invokable)]
    fn set_expanded(cx: &Cx, file: i32, expanded: bool) {
        DiffModel::update(cx.engine, cx.this, |d| {
            d.set_expanded(index(file), expanded)
        });
    }

    #[qml(invokable)]
    fn expand_all(cx: &Cx) {
        DiffModel::update(cx.engine, cx.this, Diff::expand_all);
    }

    #[qml(invokable)]
    fn collapse_all(cx: &Cx) {
        DiffModel::update(cx.engine, cx.this, Diff::collapse_all);
    }
}

#[cfg(test)]
#[path = "diff_tests.rs"]
mod tests;
