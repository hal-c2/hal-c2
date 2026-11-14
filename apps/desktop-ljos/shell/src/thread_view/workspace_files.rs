//! desktop-qt's WorkspaceFiles and TextLinesModel: the right panel's Files
//! tab. A thread's workspace (its worktree, else its project's folder) is
//! browsed through the MC's `projects.listEntries`, searched with
//! `projects.searchEntries` and read with `projects.readFile`, so a thread on
//! a remote environment browses that machine's files.
//!
//! The tree loads the top folder when the tab is first shown, and each
//! folder when first expanded. Typing a query searches after a short pause
//! and shows the matches with their folders; clearing it restores the tree.
//! A file opens in the viewer below `lines` (one row per line, so a ListView
//! lays out only the lines on screen), at a line when asked (past the end:
//! the last line); the tree reveals it.
//!
//! Markdown, CSV and HTML files show rendered (`renderedText`) until the user
//! asks for their source; the choice is kept per kind (the source kinds,
//! which the owner saves on this device). A file the MC read whole from
//! inside the workspace can be edited: an edit is written with
//! `projects.writeFile` half a second after the last one, and at once when
//! the file closes or another opens. A write the MC refuses keeps the edit
//! and says why (`saveProblem`, `saveFailed`). A Markdown task ticked in the
//! rendered view (`toggleTask`) is written at once. A file outside the
//! workspace is written back by its full path; a session paired without
//! terminal access may not, and once the MC refuses one, that environment's
//! other outside files open read-only.
//!
//! A media file ([`media_kind_of`]) is never read as text: its environment
//! signs a URL for it with `assets.createUrl` (`mediaUrl`), which the viewer
//! loads. The URL stops working a minute before the MC says, so the file
//! signs again when opened or shown after that, and when the viewer says it
//! failed (`mediaFailed`). `openMedia` hands a working URL to the browser
//! (`mediaOpened`).
//!
//! [`Files`] is the core of the viewer, the search and the save: it takes
//! MC replies and records the [`Effect`]s (calls, timers, the lines, the
//! tree's search) and [`Sig`]s it wants. [`WorkspaceFiles`] is the object QML
//! binds; it owns a [`FileTreeModel`] (which it lists the folders of) and a
//! [`TextLinesModel`], runs the core's effects, and follows a thread's
//! [`TimelineModel`] to list the tree again when the agent changes the
//! workspace.
//!
//! The right panel owns one (`Panel.files`): it gives it the workspace with
//! [`WorkspaceFiles::set_target`] and the thread's timeline with
//! [`WorkspaceFiles::set_timeline`], and says whether the tab shows with
//! [`WorkspaceFiles::set_active`]. The composer's `@` menu searches with
//! [`search_entries`].

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, VecDeque};
use std::rc::Rc;

use ljos::prelude::{Atom, Cx, Engine, ObjectId, QmlObject, Value, qml_impl};
use ljos::prelude::{ConnectionId, EngineError, QmlValue, RowKey};
use serde_json::json;

use super::file_render::{self, CSV_ROW_LIMIT};
use super::file_tree::{Entry, FileTree, FileTreeModel, name_of};
use super::rows::{ListRows, RowChange, RowSource, int};
use super::timeline_model::TimelineModel;
use crate::json::Json;
use crate::mc::{Mc, McError};

/// How long typing pauses before the search goes out.
pub const SEARCH_DELAY_MS: i32 = 120;
pub const SEARCH_LIMIT: u32 = 200;
/// How long after the last edit it is written.
pub const SAVE_DELAY_MS: i32 = 500;

// --- TextLinesModel -------------------------------------------------------

/// The most of a text that is read for its colours, in UTF-16 units as Qt
/// counts them; past it, code stays plain (desktop-qt's
/// `codereader::kMaxChars`).
const MAX_UNITS: usize = 512 * 1024;

/// A file's text as a list of offsets into one string, coloured by its
/// language (desktop-qt's TextLinesModel over codereader): a row's
/// `styled` is its line as StyledText for the theme `background` picks,
/// cut at `column_limit` characters; empty while the line is plain. The
/// text is read here, at once, for both themes, so a theme switch reads
/// nothing again.
#[derive(Debug)]
pub struct Lines {
    text: String,
    /// (offset, length) in bytes.
    spans: Vec<(usize, usize)>,
    /// (offset, length) in UTF-16 units, as the colour runs count.
    units: Vec<(u32, u32)>,
    longest: usize,
    changes: Vec<RowChange>,
    /// The file's path, whose name picks its syntax.
    path: String,
    /// What reading the text made, light (0) and dark (1); none while it
    /// is plain.
    runs: Option<[Vec<hal_c2_syntax::Span>; 2]>,
    /// Which colouring `styled` reads: 0 light, 1 dark.
    theme: usize,
    /// The most of a line `styled` holds; past it, "…".
    column_limit: i32,
}

impl Default for Lines {
    fn default() -> Lines {
        Lines {
            text: String::new(),
            spans: Vec::new(),
            units: Vec::new(),
            longest: 0,
            changes: Vec::new(),
            path: String::new(),
            runs: None,
            // An invalid background takes the dark colouring, as Qt's.
            theme: 1,
            column_limit: 2000,
        }
    }
}

impl Lines {
    pub fn set_text(&mut self, text: &str) {
        self.set_text_at(text, "");
    }

    /// `path` is the file's, whose name picks its syntax; none leaves it
    /// plain.
    pub fn set_text_at(&mut self, text: &str, path: &str) {
        // The same file again (written back as it was) keeps its colours.
        let same = path == self.path && text == self.text;
        self.text = text.to_owned();
        self.path = path.to_owned();
        (self.spans, self.longest) = file_render::line_spans(text);
        self.units = unit_spans(text, &self.spans);
        if !same {
            self.runs = read_runs(text, path);
        }
        let keys = (0..self.spans.len()).map(|r| r as RowKey).collect();
        self.changes.push(RowChange::Reset(keys));
    }

    /// Whether the lines show coloured now.
    pub fn coloured(&self) -> bool {
        self.runs
            .as_ref()
            .is_some_and(|runs| !runs[self.theme].is_empty())
    }

    /// Picks the colouring for `theme` (0 light, 1 dark): `styled` alone
    /// changes, with nothing read again.
    pub fn set_theme(&mut self, theme: usize) {
        if theme == self.theme {
            return;
        }
        self.theme = theme;
        if self.runs.is_some() {
            self.restyle();
        }
    }

    pub fn set_column_limit(&mut self, limit: i32) {
        if limit == self.column_limit {
            return;
        }
        self.column_limit = limit;
        if self.runs.is_some() {
            self.restyle();
        }
    }

    fn restyle(&mut self) {
        if !self.spans.is_empty() {
            self.changes.push(RowChange::Changed {
                first: 0,
                count: self.spans.len(),
                roles: &["styled"],
            });
        }
    }

    /// Row `row` as its `styled` role reads.
    pub fn styled(&self, row: usize) -> String {
        if row >= self.spans.len() || !self.coloured() {
            return String::new();
        }
        let Some(runs) = &self.runs else {
            return String::new();
        };
        let (offset, length) = self.units[row];
        // Cut as the viewer cuts a plain line, so no colour reaches past
        // the cut.
        let limit = u32::try_from(self.column_limit).unwrap_or(0);
        let cut = length > limit;
        let mut out = styled_line(
            self.line(row),
            offset,
            if cut { limit } else { length },
            &runs[self.theme],
        );
        if cut {
            out.push('…');
        }
        out
    }

    pub fn count(&self) -> usize {
        self.spans.len()
    }

    /// The longest line, in characters.
    pub fn max_columns(&self) -> usize {
        self.longest
    }

    pub fn line(&self, row: usize) -> &str {
        self.spans
            .get(row)
            .map_or("", |&(at, length)| &self.text[at..at + length])
    }
}

/// Each byte span's (offset, length) in UTF-16 units from the start of
/// `text`.
fn unit_spans(text: &str, spans: &[(usize, usize)]) -> Vec<(u32, u32)> {
    // The unit offset of each char boundary, asked for in order.
    let mut units = Vec::with_capacity(spans.len());
    let mut chars = text.char_indices().peekable();
    let mut at_units = 0u32;
    let mut at_byte = 0usize;
    let mut unit_at = |byte: usize, chars: &mut std::iter::Peekable<std::str::CharIndices>| {
        while at_byte < byte {
            match chars.next() {
                Some((_, c)) => {
                    at_byte += c.len_utf8();
                    at_units += c.len_utf16() as u32;
                }
                None => break,
            }
        }
        at_units
    };
    for &(offset, length) in spans {
        let from = unit_at(offset, &mut chars);
        let to = unit_at(offset + length, &mut chars);
        units.push((from, to - from));
    }
    units
}

/// What reading `text` as the file `path` makes, light (0) and dark (1);
/// none when it stays plain: no name to know it by, nothing in it, or past
/// the most that is read.
fn read_runs(text: &str, path: &str) -> Option<[Vec<hal_c2_syntax::Span>; 2]> {
    if path.is_empty() || text.is_empty() || text.encode_utf16().count() > MAX_UNITS {
        return None;
    }
    let mut syntax = hal_c2_syntax::Highlighter::for_path(path)?;
    let mut runs: [Vec<hal_c2_syntax::Span>; 2] = [Vec::new(), Vec::new()];
    syntax.feed(text, |span| runs[span.theme as usize].push(span));
    Some(runs)
}

fn escape_into(out: &mut String, text: &str) {
    for c in text.chars() {
        match c {
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '&' => out.push_str("&amp;"),
            // StyledText runs spaces together and drops tabs; these keep
            // them as plain text draws them.
            ' ' => out.push_str("&nbsp;"),
            '\t' => out.push_str("&#9;"),
            c => out.push(c),
        }
    }
}

/// `length` UTF-16 units of `line` (which starts `from` units into its
/// text) as StyledText, coloured by `runs` (desktop-qt's
/// `codereader::styled`).
fn styled_line(line: &str, from: u32, length: u32, runs: &[hal_c2_syntax::Span]) -> String {
    // The byte offset of each unit boundary of the line.
    let mut boundaries: Vec<(u32, usize)> = Vec::new();
    let mut units = 0u32;
    for (byte, c) in line.char_indices() {
        boundaries.push((units, byte));
        units += c.len_utf16() as u32;
    }
    boundaries.push((units, line.len()));
    let byte_at = |unit: u32| -> usize {
        boundaries
            .binary_search_by_key(&unit, |&(u, _)| u)
            .map_or(line.len(), |i| boundaries[i].1)
    };
    let slice = |start: u32, end: u32| -> &str {
        let (start, end) = (byte_at(start), byte_at(end));
        line.get(start..end).unwrap_or("")
    };
    let mut out = String::with_capacity(line.len() * 2);
    let to = from + length;
    let mut at = from;
    // The runs are in order; the first that ends past `from`.
    let first = runs.partition_point(|run| run.start + run.len <= from);
    for run in &runs[first..] {
        if run.start >= to {
            break;
        }
        let start = run.start.max(at);
        let end = (run.start + run.len).min(to);
        if end <= start {
            continue;
        }
        escape_into(&mut out, slice(at - from, start - from));
        let [a, r, g, b] = run.color.to_be_bytes();
        if a == 0xFF {
            out.push_str(&format!("<font color=\"#{r:02x}{g:02x}{b:02x}\">"));
        } else {
            out.push_str(&format!("<font color=\"#{a:02x}{r:02x}{g:02x}{b:02x}\">"));
        }
        if run.bold {
            out.push_str("<b>");
        }
        if run.italic {
            out.push_str("<i>");
        }
        if run.underline {
            out.push_str("<u>");
        }
        escape_into(&mut out, slice(start - from, end - from));
        if run.underline {
            out.push_str("</u>");
        }
        if run.italic {
            out.push_str("</i>");
        }
        if run.bold {
            out.push_str("</b>");
        }
        out.push_str("</font>");
        at = end;
    }
    escape_into(&mut out, slice(at - from, to - from));
    out
}

impl RowSource for Lines {
    fn roles(&self) -> &'static [&'static str] {
        &["text", "number", "styled"]
    }

    fn row_count(&self) -> usize {
        self.spans.len()
    }

    fn row_key(&self, row: usize) -> RowKey {
        row as RowKey
    }

    fn data(&self, row: usize, role: &str) -> Value {
        if row >= self.spans.len() {
            return Value::Undefined;
        }
        match role {
            "text" => Value::from(self.line(row)),
            "number" => Value::Int(int(row + 1)),
            "styled" => Value::from(self.styled(row).as_str()),
            _ => Value::Undefined,
        }
    }

    fn take_changes(&mut self) -> Vec<RowChange> {
        std::mem::take(&mut self.changes)
    }
}

/// The lines of the open file: `Files.lines`.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "TextLinesModel", uncreatable)]
pub struct TextLinesModel {
    #[qml(readonly, notify)]
    count: i32,
    /// The longest line, in characters.
    #[qml(readonly, notify)]
    max_columns: i32,
    /// What the lines are drawn on: a light one takes the light colouring.
    #[qml(notify)]
    background: ljos::prelude::Color,
    /// The most of a line `styled` holds; past it, "…".
    #[qml(notify)]
    column_limit: i32,
    /// Whether the lines show coloured now.
    #[qml(notify, readonly)]
    coloured: bool,
    /// Always false: the text is read as it is set.
    #[qml(constant, readonly)]
    reading: bool,
    #[qml(skip)]
    rows: Rc<ListRows<Lines>>,
}

impl TextLinesModel {
    /// An empty model owned by `owner`.
    pub fn create(engine: &Engine, owner: Option<ObjectId>) -> Result<ObjectId, EngineError> {
        let rows = ListRows::new(Lines::default());
        let model = TextLinesModel {
            count: 0,
            max_columns: 0,
            background: ljos::prelude::Color::INVALID,
            column_limit: 2000,
            coloured: false,
            reading: false,
            rows: rows.clone(),
        };
        let obj = engine.create_native(model, owner)?;
        rows.attach(engine, obj)?;
        // What QML writes picks the colouring and the cut.
        engine.connect_by_name(obj, "backgroundChanged", move |engine, _| {
            if let Ok(background) = engine.get(obj, TextLinesModel::BACKGROUND) {
                TextLinesModel::set_background(engine, obj, background);
            }
        })?;
        engine.connect_by_name(obj, "columnLimitChanged", move |engine, _| {
            if let Ok(limit) = engine.get(obj, TextLinesModel::COLUMN_LIMIT) {
                TextLinesModel::set_column_limit(engine, obj, limit);
            }
        })?;
        Ok(obj)
    }

    fn set_background(engine: &Engine, obj: ObjectId, background: ljos::prelude::Color) {
        let Ok(rows) = engine.with::<TextLinesModel, _>(obj, |m| m.rows.clone()) else {
            return;
        };
        let theme = crate::code_highlighter::theme_for(background) as usize;
        let coloured = rows.update(engine, |l| {
            l.set_theme(theme);
            l.coloured()
        });
        let _ = engine.set_internal(obj, TextLinesModel::COLOURED, coloured);
    }

    fn set_column_limit(engine: &Engine, obj: ObjectId, limit: i32) {
        let Ok(rows) = engine.with::<TextLinesModel, _>(obj, |m| m.rows.clone()) else {
            return;
        };
        rows.update(engine, |l| l.set_column_limit(limit));
    }

    /// Shows `text` as its lines; `path` is the file's, whose name picks
    /// its syntax.
    pub fn set_text(engine: &Engine, obj: ObjectId, text: &str) {
        TextLinesModel::set_text_at(engine, obj, text, "");
    }

    pub fn set_text_at(engine: &Engine, obj: ObjectId, text: &str, path: &str) {
        let Ok(rows) = engine.with::<TextLinesModel, _>(obj, |m| m.rows.clone()) else {
            return;
        };
        let (count, columns, coloured) = rows.update(engine, |l| {
            l.set_text_at(text, path);
            (l.count(), l.max_columns(), l.coloured())
        });
        let result = engine
            .set_internal(obj, TextLinesModel::COUNT, int(count))
            .and_then(|()| engine.set_internal(obj, TextLinesModel::MAX_COLUMNS, int(columns)))
            .and_then(|()| engine.set_internal(obj, TextLinesModel::COLOURED, coloured));
        if let Err(e) = result {
            warn(engine, &e);
        }
    }

    /// The lines now, for tests and callers that read them.
    pub fn read<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&Lines) -> R) -> Option<R> {
        let rows = engine
            .with::<TextLinesModel, _>(obj, |m| m.rows.clone())
            .ok()?;
        Some(rows.read(f))
    }
}

#[qml_impl]
impl TextLinesModel {
    /// The text of `row`, or "".
    #[qml(invokable)]
    fn line(cx: &Cx, row: i32) -> String {
        let row = usize::try_from(row).unwrap_or(usize::MAX);
        TextLinesModel::read(cx.engine, cx.this, |l| l.line(row).to_owned()).unwrap_or_default()
    }
}

// --- The core -------------------------------------------------------------

/// What an MC reply answers.
#[derive(Clone, Debug, PartialEq)]
pub enum Then {
    Search(u32),
    Read(u32),
    /// A following read of the open file, from revision `revision`.
    Refresh {
        request: u32,
        revision: u32,
    },
    /// The folder the path trail lists, for the listing `request`.
    Trail(u32),
    /// A media file's URL, for the file read `request`.
    Sign(u32),
    /// The open file's URL for the preview browser.
    Preview,
    Write {
        path: String,
        root: String,
        environment: String,
        revision: u32,
        request: u32,
        closing: bool,
    },
}

/// What the core wants done outside itself.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    Call {
        environment: String,
        method: &'static str,
        payload: Json,
        then: Then,
    },
    /// Fetch a signed document's bytes to a local file Qt PDF can open,
    /// for the file read `request`.
    DownloadDocument { relative: String, request: u32 },
    /// Start (again) or stop the search's pause.
    SearchTimer(bool),
    /// Start (again) or stop the wait before an edit is written.
    SaveTimer(bool),
    /// The viewer's lines are now this text.
    Lines(String),
    /// The tree shows the matches, or its own folders again.
    SetSearch(Option<Vec<Entry>>),
}

/// What the object says besides its properties' own signals.
#[derive(Clone, Debug, PartialEq)]
pub enum Sig {
    RevealRequested,
    SourceKinds,
    /// `renderedChanged`, which the file, the source choice and editing all
    /// share (desktop-qt's FilesPanel loads its editor when it hears it).
    Rendered,
    SaveFailed {
        path: String,
        problem: String,
    },
    /// The browser is to open this URL, the open media file's.
    MediaOpened(String),
    /// The preview browser is to show this URL, the open file's.
    PreviewReady(String),
    /// The environment would not serve the open file to the preview.
    PreviewRefused(String),
}

/// The properties, as the core has them. The text and what it renders as
/// are versions and kinds here: the strings are read when these change.
#[derive(Clone, Debug, PartialEq)]
pub struct Facts {
    pub root: String,
    pub query: String,
    pub searching: bool,
    pub search_truncated: bool,
    pub search_problem: String,
    pub open_path: String,
    pub file_status: &'static str,
    pub file_problem: String,
    pub truncated_notice: String,
    pub file_empty: bool,
    pub media_kind: &'static str,
    pub media_url: String,
    pub media_document: String,
    pub reveal_line: i32,
    pub wrap: bool,
    pub text_version: u32,
    pub render_kind: &'static str,
    pub tsv: bool,
    pub rendered: bool,
    pub editable: bool,
    pub read_only_reason: &'static str,
    pub outside_project: bool,
    pub editing: bool,
    pub unsaved: bool,
    pub save_problem: String,
    pub trail_folder: String,
    pub trail_status: &'static str,
    pub trail_entries: Vec<Json>,
    pub trail_problem: String,
}

/// The viewer, the search and the save of the Files tab.
#[derive(Debug)]
pub struct Files {
    environment: String,
    root: String,
    /// The thread the workspace is for, which media URLs are signed for.
    thread: String,
    active: bool,
    query: String,
    search_request: u32,
    searching: bool,
    search_truncated: bool,
    search_problem: String,
    open_path: String,
    open_line: i32,
    /// Opened at a line: the source shows, whatever the kind is usually
    /// read as, until the user picks a view.
    line_source: bool,
    file_request: u32,
    file_status: &'static str,
    file_problem: String,
    truncated_notice: String,
    reveal_line: i32,
    media_url: String,
    /// The local copy of a document, as a file URL; Qt PDF opens local
    /// files alone.
    media_document: String,
    /// When the MC stops serving `media_url`, a minute early (epoch ms).
    media_expires_ms: i64,
    /// The signing whose URL `open_media` waits for; else 0.
    open_on_sign: u32,
    /// The environment that refused a write by full path.
    host_writes_refused_on: String,
    /// The MC's http(s) origin, which signed URLs are relative to, and the
    /// wall clock now (epoch ms); the owner keeps them current.
    origin: String,
    now_ms: i64,
    /// The file the tree is to show once its folders are listed.
    revealing: String,
    mutation: String,
    /// The workspace changed while the tab was hidden.
    stale: bool,
    text: String,
    text_version: u32,
    lines: usize,
    truncated: bool,
    source_kinds: Vec<String>,
    editing: bool,
    /// An edit waits to be written; a write is on its way.
    pending: bool,
    saving: bool,
    /// Writes waiting their turn: one is under way at a time, as the MC
    /// answers each call on its own and two under way could land in either
    /// order, older text over newer.
    writes: VecDeque<QueuedWrite>,
    /// The file (environment, root, path) of the write under way.
    under_way: Option<(String, String, String)>,
    revision: u32,
    /// The workspace changed while the user's text or a read was on its
    /// way: the file is read again once that settles.
    reread_later: bool,
    /// A read of the open file waits for its writes to land first.
    read_after_writes: bool,
    /// Task ticks waiting on the read that says the file did not change
    /// underneath.
    waiting_ticks: Vec<usize>,
    /// The newest change names the open media file: its preview is read
    /// again, where another file's change leaves it alone.
    media_rewritten: bool,
    save_problem: String,
    wrap: Option<bool>,
    default_wrap: bool,
    /// The folder the path trail lists: loading, ready, gone or error ("" when
    /// it lists none), its `{path, name, directory}` entries, folders first,
    /// and why it has none.
    trail_request: u32,
    trail_folder: String,
    trail_status: &'static str,
    trail_entries: Vec<Json>,
    trail_problem: String,
    effects: Vec<Effect>,
    signals: Vec<Sig>,
}

impl Default for Files {
    fn default() -> Files {
        Files::new()
    }
}

/// What the tree is to do about the workspace having changed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Followed {
    Nothing,
    Refresh,
}

fn defaulted(message: &str, default: &str) -> String {
    if message.is_empty() { default } else { message }.to_owned()
}

/// The entries of a `projects.listEntries` or `projects.searchEntries`
/// reply.
pub fn entries_of(result: &Json) -> Vec<Entry> {
    result
        .get("entries")
        .and_then(Json::as_array)
        .map(|entries| {
            entries
                .iter()
                .map(|entry| {
                    let text = |key| entry.get(key).and_then(Json::as_str).unwrap_or("");
                    Entry::new(
                        text("path"),
                        text("kind") == "directory",
                        entry
                            .get("ignored")
                            .and_then(Json::as_bool)
                            .unwrap_or(false),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

impl Files {
    pub fn new() -> Files {
        Files {
            environment: String::new(),
            root: String::new(),
            thread: String::new(),
            active: false,
            query: String::new(),
            search_request: 0,
            searching: false,
            search_truncated: false,
            search_problem: String::new(),
            open_path: String::new(),
            open_line: 0,
            line_source: false,
            file_request: 0,
            file_status: "none",
            file_problem: String::new(),
            truncated_notice: String::new(),
            reveal_line: 0,
            media_url: String::new(),
            media_document: String::new(),
            media_expires_ms: 0,
            open_on_sign: 0,
            host_writes_refused_on: String::new(),
            origin: String::new(),
            now_ms: 0,
            revealing: String::new(),
            mutation: String::new(),
            stale: false,
            text: String::new(),
            text_version: 0,
            lines: 0,
            truncated: false,
            source_kinds: Vec::new(),
            editing: false,
            pending: false,
            saving: false,
            writes: VecDeque::new(),
            under_way: None,
            revision: 0,
            reread_later: false,
            read_after_writes: false,
            waiting_ticks: Vec::new(),
            media_rewritten: false,
            save_problem: String::new(),
            wrap: None,
            default_wrap: false,
            trail_request: 0,
            trail_folder: String::new(),
            trail_status: "",
            trail_entries: Vec::new(),
            trail_problem: String::new(),
            effects: Vec::new(),
            signals: Vec::new(),
        }
    }

    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
    }

    pub fn take_signals(&mut self) -> Vec<Sig> {
        std::mem::take(&mut self.signals)
    }

    pub fn environment(&self) -> &str {
        &self.environment
    }

    pub fn root(&self) -> &str {
        &self.root
    }

    pub fn is_active(&self) -> bool {
        self.active
    }

    pub fn query(&self) -> &str {
        &self.query
    }

    pub fn open_path(&self) -> &str {
        &self.open_path
    }

    pub fn file_status(&self) -> &'static str {
        self.file_status
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn revealing(&self) -> &str {
        &self.revealing
    }

    pub fn source_kinds(&self) -> &[String] {
        &self.source_kinds
    }

    pub fn truncated_notice(&self) -> &str {
        &self.truncated_notice
    }

    /// The MC's http(s) origin and the wall clock now (epoch ms).
    pub fn set_context(&mut self, origin: &str, now_ms: i64) {
        if origin != self.origin {
            self.origin = origin.to_owned();
        }
        self.now_ms = now_ms;
    }

    pub fn facts(&self) -> Facts {
        let kind = self.render_kind();
        Facts {
            root: self.root.clone(),
            query: self.query.clone(),
            searching: self.searching,
            search_truncated: self.search_truncated,
            search_problem: self.search_problem.clone(),
            open_path: self.open_path.clone(),
            file_status: self.file_status,
            file_problem: self.file_problem.clone(),
            truncated_notice: self.truncated_notice.clone(),
            file_empty: self.file_status == "ready"
                && self.media_kind().is_empty()
                && self.lines == 0,
            media_kind: self.media_kind(),
            media_url: self.media_url.clone(),
            media_document: self.media_document.clone(),
            reveal_line: self.reveal_line,
            wrap: self.wrap(),
            text_version: self.text_version,
            render_kind: kind,
            tsv: file_render::extension_of(&self.open_path) == "tsv",
            rendered: self.rendered(),
            editable: self.editable(),
            read_only_reason: self.read_only_reason(),
            outside_project: host_path(&self.open_path),
            editing: self.editing,
            unsaved: self.pending,
            save_problem: self.save_problem.clone(),
            trail_folder: self.trail_folder.clone(),
            trail_status: self.trail_status,
            trail_entries: self.trail_entries.clone(),
            trail_problem: self.trail_problem.clone(),
        }
    }

    /// Lists `folder` ("" the workspace) for the path trail.
    pub fn list_trail(&mut self, folder: &str) {
        self.trail_request += 1;
        folder.clone_into(&mut self.trail_folder);
        self.trail_status = "loading";
        self.trail_problem.clear();
        self.trail_entries.clear();
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "projects.listEntries",
            payload: json!({"cwd": self.root, "directoryPath": folder}),
            then: Then::Trail(self.trail_request),
        });
    }

    /// The path trail lists nothing; a listing on its way is dropped.
    fn clear_trail(&mut self) {
        self.trail_request += 1;
        self.trail_folder.clear();
        self.trail_status = "";
        self.trail_problem.clear();
        self.trail_entries.clear();
    }

    fn trail_listed(&mut self, result: Result<Json, McError>) {
        match result {
            Err(e) => {
                let gone =
                    e.detail.get("failure").and_then(Json::as_str) == Some("directory_not_found");
                self.trail_status = if gone { "gone" } else { "error" };
                self.trail_problem = if gone {
                    "This folder is no longer available.".to_owned()
                } else {
                    defaulted(&e.message, "Unable to load folder.")
                };
            }
            Ok(reply) => {
                let mut entries = entries_of(&reply);
                entries.sort_by(|a, b| {
                    b.directory.cmp(&a.directory).then_with(|| {
                        name_of(&a.path)
                            .to_lowercase()
                            .cmp(&name_of(&b.path).to_lowercase())
                    })
                });
                self.trail_entries = entries
                    .iter()
                    .map(|e| json!({"path": e.path, "name": name_of(&e.path), "directory": e.directory}))
                    .collect();
                self.trail_status = "ready";
                if self.trail_entries.is_empty() {
                    let truncated = reply
                        .get("truncated")
                        .and_then(Json::as_bool)
                        .unwrap_or(false);
                    self.trail_problem = if truncated {
                        "No entries from this folder are available in the partial workspace index."
                    } else {
                        "This folder is empty."
                    }
                    .to_owned();
                }
            }
        }
    }

    // --- Viewer ---

    /// Whether long lines wrap: what the user chose here, else the word wrap
    /// setting.
    pub fn wrap(&self) -> bool {
        self.wrap.unwrap_or(self.default_wrap)
    }

    pub fn set_wrap(&mut self, wrap: bool) {
        if wrap != self.wrap() {
            self.wrap = Some(wrap);
        }
    }

    pub fn set_default_wrap(&mut self, wrap: bool) {
        self.default_wrap = wrap;
    }

    /// What the open file renders as: markdown, csv, html, or "" for plain
    /// text and a file not loaded.
    pub fn render_kind(&self) -> &'static str {
        if self.file_status == "ready" {
            file_render::kind_of(&file_render::extension_of(&self.open_path))
        } else {
            ""
        }
    }

    pub fn rendered(&self) -> bool {
        let kind = self.render_kind();
        !kind.is_empty()
            && !self.editing
            && !self.line_source
            && !self.source_kinds.iter().any(|k| k == kind)
    }

    /// What the rendered view draws: Markdown (a CSV file's as a table, task
    /// boxes as `task:<n>` links) or the HTML itself.
    pub fn rendered_text(&self) -> String {
        match self.render_kind() {
            "csv" => {
                let tsv = file_render::extension_of(&self.open_path) == "tsv";
                file_render::markdown_table(&self.text, if tsv { '\t' } else { ',' })
            }
            "markdown" => file_render::with_task_links(&self.text),
            "mermaid" => file_render::mermaid_block(&self.text),
            _ => self.text.clone(),
        }
    }

    pub fn set_rendered(&mut self, rendered: bool) {
        let kind = self.render_kind();
        let source = self.source_kinds.iter().any(|k| k == kind);
        let left_line = std::mem::take(&mut self.line_source);
        if kind.is_empty() || rendered == !source {
            if left_line {
                self.signals.push(Sig::Rendered);
            }
            return;
        }
        if rendered {
            self.source_kinds.retain(|k| k != kind);
            if std::mem::take(&mut self.editing) {
                self.save(false);
            }
        } else {
            self.source_kinds.push(kind.to_owned());
        }
        self.signals.push(Sig::SourceKinds);
        self.signals.push(Sig::Rendered);
    }

    /// The kinds the user reads as source rather than rendered.
    pub fn set_source_kinds(&mut self, kinds: &[String]) {
        if kinds != self.source_kinds {
            self.source_kinds = kinds.to_vec();
            self.signals.push(Sig::Rendered);
        }
    }

    pub fn editable(&self) -> bool {
        self.read_only_reason().is_empty()
            && self.file_status == "ready"
            && self.media_kind().is_empty()
    }

    /// Why the file cannot be edited, or "".
    pub fn read_only_reason(&self) -> &'static str {
        if self.file_status != "ready" {
            ""
        } else if self.truncated {
            "Files larger than 1 MB open read-only."
        } else if self.host_writes_refused() {
            // A file outside the workspace is written back by its full path,
            // by the MC that read it. Such a write reaches any file on that
            // machine, so it needs the terminal access this device may have
            // been paired without; once refused, the others there open
            // read-only too.
            HOST_WRITE_REFUSAL
        } else {
            ""
        }
    }

    /// The open file is outside the workspace, on an environment that
    /// refused such a write.
    fn host_writes_refused(&self) -> bool {
        !self.host_writes_refused_on.is_empty()
            && self.host_writes_refused_on == self.environment
            && host_path(&self.open_path)
    }

    // --- Media ---

    /// What the open file previews as: image, video, audio, pdf, or "" for
    /// text.
    pub fn media_kind(&self) -> &'static str {
        media_kind_of(&self.open_path)
    }

    pub fn media_url(&self) -> &str {
        &self.media_url
    }

    /// The open media file has no URL that still works.
    fn media_expired(&self) -> bool {
        !self.media_kind().is_empty()
            && (self.media_url.is_empty() || self.now_ms >= self.media_expires_ms)
    }

    /// The open file as an `assets.createUrl` resource: a path in the
    /// workspace is the thread's file; a full path is served only as a
    /// media file. With no thread, the workspace folder names itself. The
    /// path is the thread's machine's, so a Windows one counts here too.
    fn file_resource(&self) -> Json {
        if self.thread.is_empty() {
            json!({"_tag": "draft-workspace-file", "cwd": self.root, "path": self.open_path})
        } else {
            let tag = if full_path(&self.open_path) {
                "media-file"
            } else {
                "workspace-file"
            };
            json!({"_tag": tag, "threadId": self.thread, "path": self.open_path})
        }
    }

    /// Asks the environment for the open media file's URL.
    fn sign_media(&mut self, request: u32) {
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "assets.createUrl",
            payload: json!({"resource": self.file_resource()}),
            then: Then::Sign(request),
        });
    }

    /// Asks the environment to serve the open file to the preview browser
    /// (`Sig::PreviewReady`), or says why it would not
    /// (`Sig::PreviewRefused`).
    pub fn open_in_preview(&mut self) {
        if self.open_path.is_empty() {
            return;
        }
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "assets.createUrl",
            payload: json!({"resource": self.file_resource()}),
            then: Then::Preview,
        });
    }

    /// Hands the open media file's URL to the browser (`Sig::MediaOpened`),
    /// signing a new one first when it ran out.
    pub fn open_media(&mut self) {
        if self.media_kind().is_empty() {
            return;
        }
        if self.file_status == "ready" && !self.media_expired() {
            self.signals.push(Sig::MediaOpened(self.media_url.clone()));
            return;
        }
        self.reload_file();
        self.open_on_sign = self.file_request;
    }

    fn media_ready(&mut self, request: u32) {
        self.file_status = "ready";
        if std::mem::take(&mut self.open_on_sign) == request {
            self.signals.push(Sig::MediaOpened(self.media_url.clone()));
        }
    }

    /// The signed document's bytes were fetched and kept at `document` (a
    /// file URL), or not at all (`None`); for the file read `request`.
    pub fn document_ready(&mut self, request: u32, document: Option<String>) {
        if request != self.file_request {
            return;
        }
        match document {
            Some(document) => {
                self.media_document = document;
                self.media_ready(request);
            }
            None => {
                self.file_status = "ready";
                let url = self.media_url.clone();
                self.media_failed(&url);
            }
        }
    }

    /// The viewer could not load `url`: the file says so until read again.
    pub fn media_failed(&mut self, url: &str) {
        if url.is_empty() || url != self.media_url || self.file_status != "ready" {
            return;
        }
        let noun = match self.media_kind() {
            "pdf" => "document",
            "" => "file",
            kind => kind,
        };
        self.media_url.clear();
        self.file_status = "error";
        self.file_problem = format!("The {noun} could not be loaded.");
        self.signals.push(Sig::Rendered);
    }

    // --- Workspace ---

    /// The workspace to browse: the environment it is on and its folder
    /// there. A new one forgets the search and the open file (the owner
    /// forgets the tree). False when it is the one already shown.
    pub fn set_target(&mut self, environment: &str, root: &str, thread: &str) -> bool {
        thread.clone_into(&mut self.thread);
        if environment == self.environment && root == self.root {
            return false;
        }
        // An edit of the workspace being left is written there.
        self.save(true);
        self.environment = environment.to_owned();
        self.root = root.to_owned();
        // Answers about the workspace left are dropped.
        self.search_request += 1;
        self.clear_trail();
        self.revealing.clear();
        self.query.clear();
        self.effects.push(Effect::SearchTimer(false));
        self.searching = false;
        self.search_truncated = false;
        self.search_problem.clear();
        self.close_file();
        true
    }

    pub fn set_active(&mut self, active: bool) {
        self.active = active;
        if active && self.stale {
            self.follow_open_file();
        }
        // The preview loads again when the tab shows, so needs a URL that
        // works.
        if active && self.file_status == "ready" && self.media_expired() {
            self.reload_file();
        }
    }

    /// Takes the note that the workspace changed while the tab was hidden.
    pub fn take_stale(&mut self) -> bool {
        std::mem::take(&mut self.stale)
    }

    /// Follows a new thread: its mutation is the baseline, nothing is stale.
    pub fn set_mutation(&mut self, mutation: String) {
        self.stale = false;
        self.mutation = mutation;
    }

    /// The thread's latest mutation: the tree lists its loaded folders
    /// again once the agent's command or file change settles or a
    /// checkpoint lands, at once while the tab shows, else when it next
    /// does.
    pub fn follow(&mut self, mutation: String) -> Followed {
        self.follow_named(mutation, false)
    }

    /// As [`Files::follow`], with whether the newest change names the open
    /// file: only that reads a media file's preview again.
    pub fn follow_named(&mut self, mutation: String, newest_names_open: bool) -> Followed {
        if mutation == self.mutation {
            return Followed::Nothing;
        }
        self.mutation = mutation;
        self.media_rewritten = self.media_rewritten || newest_names_open;
        if self.active {
            self.follow_open_file();
            Followed::Refresh
        } else {
            self.stale = true;
            Followed::Nothing
        }
    }

    // --- Search ---

    pub fn set_query(&mut self, query: &str) {
        if query == self.query {
            return;
        }
        self.query = query.to_owned();
        // A search on its way is for another query.
        self.search_request += 1;
        if self.query.trim().is_empty() || self.root.is_empty() {
            self.effects.push(Effect::SearchTimer(false));
            self.searching = false;
            self.search_truncated = false;
            self.search_problem.clear();
            self.effects.push(Effect::SetSearch(None));
            return;
        }
        // The user looks for something else than the file being revealed.
        self.revealing.clear();
        self.searching = true;
        self.effects.push(Effect::SearchTimer(true));
    }

    /// The pause after typing is over: asks for the matches.
    pub fn search(&mut self) {
        if self.root.is_empty() {
            return;
        }
        self.search_request += 1;
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "projects.searchEntries",
            payload: json!({
                "cwd": self.root,
                "query": self.query.trim(),
                "limit": SEARCH_LIMIT,
            }),
            then: Then::Search(self.search_request),
        });
    }

    /// Wants the tree to show `path` once its folders are listed; the owner
    /// walks there.
    pub fn reveal(&mut self, path: &str) -> bool {
        // A file outside the workspace (opened by its full path) is not in
        // the tree.
        if path.is_empty() || path.starts_with('/') {
            return false;
        }
        // Revealing is about the user's tree, not a search's.
        if !self.query.is_empty() {
            self.set_query("");
        }
        self.revealing = path.to_owned();
        true
    }

    /// The reveal is done (or no longer wanted); the path it was for.
    pub fn take_revealing(&mut self) -> String {
        std::mem::take(&mut self.revealing)
    }

    // --- File ---

    /// Opens a file in the viewer, at `line` when above 0. False when there
    /// is nothing to open it in; the owner then reveals the path.
    pub fn open_file(&mut self, path: &str, line: i32) -> bool {
        if path.is_empty() || self.root.is_empty() {
            return false;
        }
        if path != self.open_path {
            self.save(true);
            if std::mem::take(&mut self.editing) {
                self.signals.push(Sig::Rendered);
            }
        }
        self.open_line = line;
        // A line is in the source, whatever the kind is usually read as.
        if std::mem::replace(&mut self.line_source, line > 0) != (line > 0) {
            self.signals.push(Sig::Rendered);
        }
        if path == self.open_path && self.file_status == "ready" && !self.media_expired() {
            // Already here: just go to the line.
            self.reveal_line = self.clamped(line);
            self.signals.push(Sig::RevealRequested);
        } else {
            self.open_path = path.to_owned();
            self.reload_file();
        }
        true
    }

    fn clamped(&self, line: i32) -> i32 {
        if line > 0 {
            line.clamp(1, int(self.lines.max(1)))
        } else {
            0
        }
    }

    /// Reads the open file again.
    pub fn reload_file(&mut self) {
        if self.open_path.is_empty() {
            return;
        }
        self.save(true);
        self.waiting_ticks.clear();
        self.file_request += 1;
        self.file_status = "loading";
        self.file_problem.clear();
        self.truncated_notice.clear();
        self.truncated = false;
        self.media_url.clear();
        self.media_document.clear();
        self.media_rewritten = false;
        self.reread_later = false;
        self.read_after_writes = false;
        self.signals.push(Sig::Rendered);
        if !self.media_kind().is_empty() {
            self.sign_media(self.file_request);
            return;
        }
        // A read now would show the text from before the writes still to
        // land.
        if self.writing_open_file() {
            self.read_after_writes = true;
            return;
        }
        self.read_open_file();
    }

    /// What a read of the file says of how much of it came.
    fn note_truncation(&mut self, file: &Json) {
        self.truncated = file
            .get("truncated")
            .and_then(Json::as_bool)
            .unwrap_or(false);
        if self.truncated {
            let bytes = file.get("byteLength").and_then(Json::as_f64).unwrap_or(0.0);
            self.truncated_notice = format!(
                "Preview limited to the first 1 MB of a {} byte file.",
                file_render::grouped(bytes as i64)
            );
        } else {
            self.truncated_notice.clear();
        }
    }

    /// The read a reload held for its writes, once none is on its way.
    fn read_after_writes_if_waiting(&mut self) {
        if self.read_after_writes && !self.writing_open_file() {
            self.read_after_writes = false;
            self.read_open_file();
        }
    }

    /// Whether a write of the open file waits or is under way.
    fn writing_open_file(&self) -> bool {
        let open = |environment: &str, root: &str, path: &str| {
            environment == self.environment && root == self.root && path == self.open_path
        };
        self.under_way
            .as_ref()
            .is_some_and(|(environment, root, path)| open(environment, root, path))
            || self
                .writes
                .iter()
                .any(|w| open(&w.environment, &w.root, &w.path))
    }

    fn read_open_file(&mut self) {
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "projects.readFile",
            payload: json!({"cwd": self.root, "relativePath": self.open_path}),
            then: Then::Read(self.file_request),
        });
    }

    /// Reads the open file as the workspace has it now, for the ticks
    /// waiting and the agent's changes; the user's text is kept.
    fn refresh_file(&mut self) {
        // The read waiting on the writes will show what is there.
        if self.read_after_writes {
            return;
        }
        self.file_request += 1;
        let request = self.file_request;
        let revision = self.revision;
        self.reread_later = false;
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "projects.readFile",
            payload: json!({"cwd": self.root, "relativePath": self.open_path}),
            then: Then::Refresh { request, revision },
        });
    }

    fn reread_if_due(&mut self) {
        if self.reread_later
            && !self.pending
            && !self.saving
            && !self.editing
            && self.file_status == "ready"
            && self.media_kind().is_empty()
        {
            self.refresh_file();
        }
    }

    fn follow_open_file(&mut self) {
        if self.open_path.is_empty() {
            return;
        }
        if !self.media_kind().is_empty() {
            if std::mem::take(&mut self.media_rewritten) {
                self.reload_file();
            }
            return;
        }
        // A path that could not be read may be a file now (a folder the
        // agent replaced).
        if self.file_status != "ready" {
            if self.file_status == "error" {
                self.reload_file();
            } else if self.file_status == "loading" {
                // The read under way may be from before this change.
                self.reread_later = true;
            }
            return;
        }
        // The user's own text stays: the file is read once it is written.
        if self.pending || self.saving || self.editing {
            self.reread_later = true;
            return;
        }
        self.refresh_file();
    }

    pub fn close_file(&mut self) {
        // What the user typed is written before the file goes.
        self.save(true);
        if std::mem::take(&mut self.editing) {
            self.signals.push(Sig::Rendered);
        }
        self.file_request += 1;
        self.waiting_ticks.clear();
        self.read_after_writes = false;
        let had = !self.open_path.is_empty() || self.file_status != "none";
        self.clear_trail();
        self.open_path.clear();
        self.open_line = 0;
        self.reveal_line = 0;
        self.file_status = "none";
        self.file_problem.clear();
        self.truncated_notice.clear();
        self.truncated = false;
        self.media_url.clear();
        self.media_document.clear();
        self.set_text("");
        self.save_problem.clear();
        if had {
            self.signals.push(Sig::Rendered);
        }
    }

    fn set_text(&mut self, text: &str) {
        self.effects.push(Effect::SaveTimer(false));
        self.pending = false;
        self.revision += 1;
        self.text = text.to_owned();
        self.text_version += 1;
        self.lines = file_render::line_count(text);
        self.effects.push(Effect::Lines(text.to_owned()));
    }

    // --- Editing ---

    pub fn set_editing(&mut self, editing: bool) {
        let editing = editing && self.editable();
        if editing == self.editing {
            return;
        }
        self.editing = editing;
        if !self.editing {
            self.save(false);
        }
        self.signals.push(Sig::Rendered);
        self.reread_if_due();
    }

    /// The open file's text as the user changed it.
    pub fn edit(&mut self, contents: &str) {
        if !self.editable() || contents == self.text {
            return;
        }
        self.text = contents.to_owned();
        self.text_version += 1;
        self.revision += 1;
        // A waiting tick counted the boxes of the text that was just
        // replaced.
        self.waiting_ticks.clear();
        self.pending = true;
        self.save_problem.clear();
        self.effects.push(Effect::SaveTimer(true));
    }

    /// Ticks or unticks the open Markdown file's `index`th task (from 0).
    pub fn toggle_task(&mut self, index: usize) {
        if !self.editable() || self.render_kind() != "markdown" {
            return;
        }
        // The file may have changed underneath what the user is looking
        // at, unless what they see is their own edit not written yet.
        if self.pending || self.saving {
            self.apply_task(index);
        } else {
            self.waiting_ticks.push(index);
            self.refresh_file();
        }
    }

    fn apply_task(&mut self, index: usize) {
        let Some(next) = file_render::toggled(&self.text, index) else {
            return;
        };
        self.text = next;
        self.text_version += 1;
        self.effects.push(Effect::Lines(self.text.clone()));
        self.revision += 1;
        self.pending = true;
        self.save(false);
    }

    /// Writes a pending edit now; `closing` when the file is going away, so
    /// nothing but a failure is heard of it.
    pub fn save(&mut self, closing: bool) {
        self.effects.push(Effect::SaveTimer(false));
        if !self.pending || self.open_path.is_empty() || self.root.is_empty() {
            return;
        }
        if self.host_writes_refused() {
            // Refused already: the edit stays on screen, unsaved, until the
            // file goes, and is never written to the file opened next.
            if closing {
                self.pending = false;
                self.saving = false;
            }
            return;
        }
        // One write at a time: the next goes when this one is answered.
        if self.saving && !closing {
            return;
        }
        self.saving = !closing;
        if closing {
            self.pending = false;
        }
        self.writes.push_back(QueuedWrite {
            environment: self.environment.clone(),
            root: self.root.clone(),
            path: self.open_path.clone(),
            contents: self.text.clone(),
            revision: self.revision,
            request: self.file_request,
            closing,
        });
        self.write_next();
    }

    /// Sends the next write waiting, once none is under way.
    fn write_next(&mut self) {
        if self.under_way.is_some() {
            return;
        }
        while let Some(write) = self.writes.pop_front() {
            if self.host_writes_refused_on == write.environment && host_path(&write.path) {
                // Refused while this one waited. The edit stays on screen,
                // if it still is.
                if !write.closing && write.request == self.file_request {
                    self.saving = false;
                }
                continue;
            }
            self.under_way = Some((
                write.environment.clone(),
                write.root.clone(),
                write.path.clone(),
            ));
            self.effects.push(Effect::Call {
                environment: write.environment.clone(),
                method: "projects.writeFile",
                payload: json!({
                    "cwd": write.root,
                    "relativePath": write.path,
                    "contents": write.contents,
                }),
                then: Then::Write {
                    path: write.path,
                    root: write.root,
                    environment: write.environment,
                    revision: write.revision,
                    request: write.request,
                    closing: write.closing,
                },
            });
            break;
        }
        self.read_after_writes_if_waiting();
    }

    /// Whether a write is on its way, unanswered (desktop-qt's `writing()`).
    pub fn writing(&self) -> bool {
        self.under_way.is_some() || !self.writes.is_empty()
    }

    /// Writes what waits, now: the window is closing, or the app is
    /// quitting. [`WorkspaceFiles::on_writes_finished`] says when every
    /// write is answered.
    pub fn finish_writes(&mut self) {
        self.save(true);
    }

    pub fn save_due(&mut self) {
        self.save(false);
    }

    // --- Replies ---

    /// The MC answered a call this asked for (`Err`: its message, which may
    /// be empty, and detail); an answer for something since replaced is
    /// dropped.
    pub fn answer(&mut self, then: Then, result: Result<Json, McError>) {
        match then {
            Then::Trail(request) => {
                if request == self.trail_request {
                    self.trail_listed(result);
                }
            }
            Then::Search(request) => {
                if request != self.search_request {
                    return;
                }
                self.searching = false;
                match result {
                    Ok(reply) => {
                        self.search_problem.clear();
                        self.search_truncated = reply
                            .get("truncated")
                            .and_then(Json::as_bool)
                            .unwrap_or(false);
                        self.effects
                            .push(Effect::SetSearch(Some(entries_of(&reply))));
                    }
                    Err(e) => {
                        self.search_problem = defaulted(&e.message, "Unable to search files.");
                        self.search_truncated = false;
                        self.effects.push(Effect::SetSearch(Some(Vec::new())));
                    }
                }
            }
            Then::Read(request) => {
                if request != self.file_request {
                    return;
                }
                match result {
                    Err(e) => {
                        // The file changed since this read began: it may
                        // be readable now.
                        if self.reread_later {
                            self.reload_file();
                            return;
                        }
                        self.file_status = "error";
                        self.file_problem = read_problem(&e);
                        self.set_text("");
                        self.signals.push(Sig::Rendered);
                    }
                    Ok(file) => {
                        let contents = file.get("contents").and_then(Json::as_str).unwrap_or("");
                        self.set_text(contents);
                        self.file_status = "ready";
                        self.note_truncation(&file);
                        self.signals.push(Sig::Rendered);
                        self.reveal_line = self.clamped(self.open_line);
                        self.signals.push(Sig::RevealRequested);
                        self.reread_if_due();
                    }
                }
            }
            Then::Refresh { request, revision } => {
                if request != self.file_request {
                    return;
                }
                // Read before the user's edit, so older than what they see.
                if revision != self.revision || self.pending || self.saving || self.editing {
                    self.reread_later = true;
                    self.reread_if_due();
                    return;
                }
                // Every tick waited on this read; older ones lost theirs to it.
                let ticks = std::mem::take(&mut self.waiting_ticks);
                match result {
                    Err(e) => {
                        self.file_status = "error";
                        self.file_problem = read_problem(&e);
                        self.truncated = false;
                        self.truncated_notice.clear();
                        self.set_text("");
                        self.signals.push(Sig::Rendered);
                    }
                    Ok(file) => {
                        let contents = file.get("contents").and_then(Json::as_str).unwrap_or("");
                        let notice = self.truncated_notice.clone();
                        self.note_truncation(&file);
                        if contents != self.text {
                            // A task ticked against other text is not
                            // ticked: the user sees what is there now.
                            self.set_text(contents);
                            self.signals.push(Sig::Rendered);
                        } else {
                            if notice != self.truncated_notice {
                                self.signals.push(Sig::Rendered);
                            }
                            // Saving what a cut-off read shows would drop
                            // the rest of the file.
                            if !self.truncated {
                                for task in ticks {
                                    self.apply_task(task);
                                }
                            }
                        }
                    }
                }
            }
            Then::Preview => {
                let relative = result
                    .as_ref()
                    .ok()
                    .and_then(|r| r.get("relativeUrl"))
                    .and_then(Json::as_str)
                    .unwrap_or("")
                    .to_owned();
                if result.is_err() || relative.is_empty() {
                    let message = result.err().map(|e| e.message).unwrap_or_default();
                    self.signals.push(Sig::PreviewRefused(defaulted(
                        &message,
                        "The environment did not serve the file.",
                    )));
                    return;
                }
                let url = resolved(&self.origin, &relative);
                self.signals.push(Sig::PreviewReady(url));
            }
            Then::Sign(request) => {
                if request != self.file_request {
                    return;
                }
                let reply = result.as_ref().ok();
                let relative = reply
                    .and_then(|r| r.get("relativeUrl"))
                    .and_then(Json::as_str)
                    .unwrap_or("")
                    .to_owned();
                self.set_text("");
                self.signals.push(Sig::Rendered);
                if result.is_err() || relative.is_empty() {
                    self.file_status = "error";
                    let message = result.err().map(|e| e.message).unwrap_or_default();
                    self.file_problem = defaulted(&message, "Unable to load this file.");
                    return;
                }
                // The cluster hands the address to the member that signed it.
                // It stops working a minute before the MC says, so a preview
                // asked for at the last moment still loads.
                self.media_url = resolved(&self.origin, &relative);
                let expires = reply
                    .and_then(|r| r.get("expiresAt"))
                    .and_then(Json::as_f64)
                    .unwrap_or(0.0);
                self.media_expires_ms = expires as i64 - 60_000;
                if self.media_kind() == "pdf" {
                    // Qt PDF opens local files alone: fetch the document
                    // first, and only then is the file ready.
                    self.effects
                        .push(Effect::DownloadDocument { relative, request });
                    return;
                }
                self.media_ready(request);
            }
            then @ Then::Write { .. } => {
                self.under_way = None;
                self.write_answered(then, result);
                self.write_next();
            }
        }
    }

    /// A write's answer, the next write going after it whatever it was.
    fn write_answered(&mut self, then: Then, result: Result<Json, McError>) {
        let Then::Write {
            path,
            root,
            environment,
            revision,
            request,
            closing,
        } = then
        else {
            return;
        };
        // A session without terminal access may not write outside the
        // workspace (Rpc.required_scope/2).
        let host_refused = result.as_ref().err().is_some_and(|e| {
            e.detail.get("_tag").and_then(Json::as_str) == Some("EnvironmentScopeRequiredError")
                && e.detail.get("requiredScope").and_then(Json::as_str) == Some("terminal:operate")
        });
        if host_refused {
            self.host_writes_refused_on = environment;
        }
        let failed = result.as_ref().err().map(|e| {
            if host_refused {
                HOST_WRITE_REFUSAL.to_owned()
            } else {
                defaulted(&e.message, "Unable to save this file.")
            }
        });
        if let Some(problem) = &failed {
            self.signals.push(Sig::SaveFailed {
                path: path.clone(),
                problem: problem.clone(),
            });
        }
        // The file closed, or another opened, meanwhile.
        if closing || path != self.open_path || root != self.root || request != self.file_request {
            return;
        }
        self.saving = false;
        if let Some(problem) = failed {
            self.save_problem = problem;
            if host_refused {
                // The file is read-only now; the view shows the edit
                // that was not saved, to copy.
                self.editing = false;
                self.effects.push(Effect::Lines(self.text.clone()));
                self.signals.push(Sig::Rendered);
            }
            // Else the edit stays, to be written with the next one.
            return;
        }
        self.save_problem.clear();
        if revision == self.revision {
            self.pending = false;
            if !self.editing {
                self.effects.push(Effect::Lines(self.text.clone()));
            }
        } else {
            self.effects.push(Effect::SaveTimer(true));
        }
        self.reread_if_due();
    }
}

/// A write waiting its turn ([`Files::write_next`]).
#[derive(Debug)]
struct QueuedWrite {
    environment: String,
    root: String,
    path: String,
    contents: String,
    revision: u32,
    request: u32,
    closing: bool,
}

/// Why a read failed, worded for the viewer: a file that is not text says
/// so itself, whatever the MC's words were.
fn read_problem(error: &McError) -> String {
    match error.detail.get("failure").and_then(Json::as_str) {
        Some("binary_file") => {
            "This file contains binary data and cannot be shown as text.".to_owned()
        }
        Some("not_utf8") => {
            "This file is not UTF-8 text. Open it in another app to view its contents.".to_owned()
        }
        _ => defaulted(&error.message, "Unable to read this file."),
    }
}

const HOST_WRITE_REFUSAL: &str = "Saving a file outside the project needs terminal access, which this device was not paired with.";

/// A file outside the workspace, opened by its full path (written back by
/// it).
fn host_path(path: &str) -> bool {
    path.starts_with('/') || path.contains(":\\")
}

/// A full path on the thread's machine, whichever it is: `/…`, `\\share…`
/// or `C:/…`, `C:\…`.
fn full_path(path: &str) -> bool {
    let bytes = path.as_bytes();
    path.starts_with('/')
        || path.starts_with("\\\\")
        || (bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && matches!(bytes[2], b'/' | b'\\'))
}

/// `relative` against the MC's `origin`; as it is when either is not a URL.
pub fn resolved(origin: &str, relative: &str) -> String {
    url::Url::parse(origin)
        .and_then(|o| o.join(relative))
        .map_or_else(|_| relative.to_owned(), String::from)
}

/// What a file previews as, by its extension: image, video, audio, pdf, or
/// "" for text. The MC's media extensions, less HTML, which renders as text.
pub fn media_kind_of(path: &str) -> &'static str {
    match file_render::extension_of(path).as_str() {
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "svg" | "bmp" | "avif" | "ico" => "image",
        "mp4" | "webm" | "mov" | "m4v" => "video",
        "mp3" | "wav" | "ogg" | "oga" | "opus" | "m4a" | "aac" | "flac" => "audio",
        "pdf" => "pdf",
        _ => "",
    }
}

/// The maximum rows a CSV table shows, for the tab's callers.
pub const CSV_ROWS: usize = CSV_ROW_LIMIT;

// --- The object -----------------------------------------------------------

type SaveFailedHook = Rc<dyn Fn(&Engine, &str, &str)>;
type KindsHook = Rc<dyn Fn(&Engine)>;
type PreviewHook = Rc<dyn Fn(&Engine, &str)>;

#[derive(Default)]
struct Hooks {
    save_failed: Vec<SaveFailedHook>,
    writes_finished: Vec<KindsHook>,
    source_kinds: Vec<KindsHook>,
    preview_ready: Vec<PreviewHook>,
    preview_refused: Vec<PreviewHook>,
}

/// The newest listing asked for of each folder: any other answer is stale.
#[derive(Default)]
struct Lists {
    last: u32,
    by_folder: HashMap<String, u32>,
}

struct Inner {
    core: RefCell<Files>,
    mc: Rc<dyn Mc>,
    tree: Cell<Option<ObjectId>>,
    lines: Cell<Option<ObjectId>>,
    lists: RefCell<Lists>,
    search_timer: Cell<Option<ObjectId>>,
    save_timer: Cell<Option<ObjectId>>,
    /// The pause after a keystroke that saves; a test stretches it.
    save_delay: Cell<i32>,
    /// The thread's TimelineModel followed, and its connection.
    timeline: Cell<Option<ObjectId>>,
    connections: RefCell<Vec<ConnectionId>>,
    hooks: RefCell<Hooks>,
    /// The temp file holding a fetched document, removed when replaced.
    media_document_file: RefCell<Option<std::path::PathBuf>>,
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Files").finish_non_exhaustive()
    }
}

/// The Files tab QML binds: `tree` and `lines` are its models; the
/// properties below.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "WorkspaceFiles", uncreatable)]
pub struct WorkspaceFiles {
    #[qml(readonly)]
    tree: Value,
    #[qml(readonly)]
    lines: Value,
    /// The workspace folder on its environment; empty when the thread has
    /// none.
    #[qml(readonly, notify)]
    root: Atom,
    /// QML writes it.
    #[qml(notify)]
    query: Atom,
    /// A search is on its way.
    #[qml(readonly, notify)]
    searching: bool,
    /// The MC had more matches than it sent.
    #[qml(readonly, notify)]
    search_truncated: bool,
    #[qml(readonly, notify)]
    search_problem: Atom,
    /// The file in the viewer, and how it is: none, loading, ready or error.
    #[qml(readonly, notify)]
    open_path: Atom,
    #[qml(readonly, notify)]
    file_status: Atom,
    #[qml(readonly, notify)]
    file_problem: Atom,
    /// "Preview limited to the first 1 MB of a 3,145,728 byte file.", when
    /// only the start of the file came.
    #[qml(readonly, notify)]
    truncated_notice: Atom,
    #[qml(readonly, notify)]
    file_empty: bool,
    /// What the file previews as: image, video, audio, pdf, or "" for text.
    #[qml(readonly, notify)]
    media_kind: Atom,
    /// Where the preview loads a media file from, once signed; else "".
    #[qml(readonly, notify)]
    media_url: Atom,
    /// The local copy of a document, as a file URL, once fetched; else "".
    #[qml(readonly, notify)]
    media_document: Atom,
    /// The line the viewer was asked to show (1-based, within the file), or 0.
    #[qml(readonly, notify)]
    reveal_line: i32,
    /// QML writes it: whether long lines wrap.
    #[qml(notify)]
    wrap: bool,
    /// The file's text, as read or as last edited.
    #[qml(readonly, notify)]
    text: Atom,
    /// What the file renders as: markdown, csv, html, or "" for plain text.
    #[qml(readonly, notify)]
    render_kind: Atom,
    /// QML writes it: source or rendered, for the file's kind.
    #[qml(notify)]
    rendered: bool,
    /// What the rendered view draws.
    #[qml(readonly, notify)]
    rendered_text: Atom,
    #[qml(readonly, notify)]
    editable: bool,
    /// Why the file cannot be edited, or "".
    #[qml(readonly, notify)]
    read_only_reason: Atom,
    /// The open file is outside the project, opened by its full path; it
    /// has no place in the project's tree.
    #[qml(readonly, notify)]
    outside_project: bool,
    /// QML writes it.
    #[qml(notify)]
    editing: bool,
    /// An edit is not written yet.
    #[qml(readonly, notify)]
    unsaved: bool,
    #[qml(readonly, notify)]
    save_problem: Atom,
    /// The folder the path trail lists (`listTrail`), how it is (loading,
    /// ready, gone, error, or "" when none), its `{path, name, directory}`
    /// entries, folders first, and why it has none.
    #[qml(readonly, notify)]
    trail_folder: Atom,
    #[qml(readonly, notify)]
    trail_status: Atom,
    #[qml(readonly, notify)]
    trail_entries: Value,
    #[qml(readonly, notify)]
    trail_problem: Atom,
    #[qml(skip)]
    inner: Rc<Inner>,
}

fn inner_of(engine: &Engine, obj: ObjectId) -> Option<Rc<Inner>> {
    engine
        .with::<WorkspaceFiles, _>(obj, |f| f.inner.clone())
        .ok()
}

fn warn(engine: &Engine, e: &EngineError) {
    engine.log(
        ljos::prelude::LogLevel::Warning,
        "WorkspaceFiles",
        e.to_string(),
    );
}

fn warned(engine: &Engine, result: Result<(), EngineError>) {
    if let Err(e) = result {
        warn(engine, &e);
    }
}

impl WorkspaceFiles {
    /// The Files tab owned by `owner`, asking `mc`.
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        mc: Rc<dyn Mc>,
    ) -> Result<ObjectId, EngineError> {
        let core = Files::new();
        let facts = core.facts();
        let inner = Rc::new(Inner {
            core: RefCell::new(core),
            mc,
            tree: Cell::new(None),
            lines: Cell::new(None),
            lists: RefCell::default(),
            search_timer: Cell::new(None),
            save_timer: Cell::new(None),
            save_delay: Cell::new(SAVE_DELAY_MS),
            timeline: Cell::new(None),
            connections: RefCell::default(),
            hooks: RefCell::default(),
            media_document_file: RefCell::default(),
        });
        let atom = |s: &str| Atom::new(s);
        let files = WorkspaceFiles {
            tree: Value::Null,
            lines: Value::Null,
            root: atom(&facts.root),
            query: atom(&facts.query),
            searching: facts.searching,
            search_truncated: facts.search_truncated,
            search_problem: atom(&facts.search_problem),
            open_path: atom(&facts.open_path),
            file_status: atom(facts.file_status),
            file_problem: atom(&facts.file_problem),
            truncated_notice: atom(&facts.truncated_notice),
            file_empty: facts.file_empty,
            media_kind: atom(facts.media_kind),
            media_url: atom(&facts.media_url),
            media_document: atom(&facts.media_document),
            reveal_line: facts.reveal_line,
            wrap: facts.wrap,
            text: atom(""),
            render_kind: atom(facts.render_kind),
            rendered: facts.rendered,
            rendered_text: atom(""),
            editable: facts.editable,
            read_only_reason: atom(facts.read_only_reason),
            outside_project: facts.outside_project,
            editing: facts.editing,
            unsaved: facts.unsaved,
            save_problem: atom(&facts.save_problem),
            trail_folder: atom(&facts.trail_folder),
            trail_status: atom(facts.trail_status),
            trail_entries: Json::Array(Vec::new()).to_value(),
            trail_problem: atom(&facts.trail_problem),
            inner: inner.clone(),
        };
        let obj = engine.create_native(files, owner)?;
        let tree = FileTreeModel::create(engine, Some(obj), move |engine, _, folder| {
            list(engine, obj, folder);
        })?;
        let lines = TextLinesModel::create(engine, Some(obj))?;
        inner.tree.set(Some(tree));
        inner.lines.set(Some(lines));
        engine.set_internal(obj, WorkspaceFiles::TREE, Value::Object(tree))?;
        engine.set_internal(obj, WorkspaceFiles::LINES, Value::Object(lines))?;
        // A folder's listing landing walks a reveal on.
        let settled = engine
            .signal_index(tree, "folderSettled")
            .and_then(|s| engine.connect_to(tree, s, obj, move |e, _| walk_reveal(e, obj)));
        settled?;
        // What QML writes goes through the core, which may keep it as it
        // was; the property then reads what the core has.
        engine.connect_by_name(obj, "queryChanged", move |engine, _| {
            if let Ok(query) = engine.get(obj, WorkspaceFiles::QUERY) {
                WorkspaceFiles::written(engine, obj, |f| {
                    f.query() != &*query && {
                        f.set_query(&query);
                        true
                    }
                });
            }
        })?;
        engine.connect_by_name(obj, "wrapChanged", move |engine, _| {
            if let Ok(wrap) = engine.get(obj, WorkspaceFiles::WRAP) {
                WorkspaceFiles::written(engine, obj, |f| {
                    f.wrap() != wrap && {
                        f.set_wrap(wrap);
                        true
                    }
                });
            }
        })?;
        engine.connect_by_name(obj, "renderedChanged", move |engine, _| {
            if let Ok(rendered) = engine.get(obj, WorkspaceFiles::RENDERED) {
                WorkspaceFiles::written(engine, obj, |f| {
                    f.rendered() != rendered && {
                        f.set_rendered(rendered);
                        true
                    }
                });
            }
        })?;
        engine.connect_by_name(obj, "editingChanged", move |engine, _| {
            if let Ok(editing) = engine.get(obj, WorkspaceFiles::EDITING) {
                WorkspaceFiles::written(engine, obj, |f| {
                    f.facts().editing != editing && {
                        f.set_editing(editing);
                        true
                    }
                });
            }
        })?;
        Ok(obj)
    }

    /// The tree of the folders.
    pub fn tree(engine: &Engine, obj: ObjectId) -> Option<ObjectId> {
        inner_of(engine, obj)?.tree.get()
    }

    /// The lines of the open file.
    pub fn lines(engine: &Engine, obj: ObjectId) -> Option<ObjectId> {
        inner_of(engine, obj)?.lines.get()
    }

    /// The workspace to browse: the environment it is on, its folder there
    /// and the thread it is for ("" for a draft's), which media URLs are
    /// signed for. A new workspace forgets the tree, the search and the open
    /// file.
    pub fn set_target(engine: &Engine, obj: ObjectId, environment: &str, root: &str, thread: &str) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        let changed =
            WorkspaceFiles::update(engine, obj, |f| f.set_target(environment, root, thread));
        if changed != Some(true) {
            return;
        }
        // Answers about the workspace left are dropped.
        inner.lists.borrow_mut().by_folder.clear();
        if let Some(tree) = inner.tree.get() {
            FileTreeModel::update(engine, tree, FileTree::clear);
        }
        let active = inner.core.borrow().is_active();
        WorkspaceFiles::set_active(engine, obj, active);
    }

    /// Whether the Files tab shows: only a shown tab loads anything.
    pub fn set_active(engine: &Engine, obj: ObjectId, active: bool) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        let Some(tree) = inner.tree.get() else {
            return;
        };
        let has_root = WorkspaceFiles::update(engine, obj, |f| {
            f.set_active(active);
            !f.root().is_empty()
        })
        .unwrap_or(false);
        // The first look at a workspace lists its top folder.
        let requested = FileTreeModel::read(engine, tree, |t| t.requested("")).unwrap_or(true);
        if active && has_root && !requested {
            FileTreeModel::update(engine, tree, FileTree::reload);
        } else if active && inner.core.borrow_mut().take_stale() {
            FileTreeModel::update(engine, tree, FileTree::refresh);
        }
    }

    /// The thread whose agent changes the workspace (its TimelineModel,
    /// which may come later than the thread).
    pub fn set_timeline(engine: &Engine, obj: ObjectId, timeline: Option<ObjectId>) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        if inner.timeline.get() == timeline {
            return;
        }
        for connection in inner.connections.take() {
            engine.disconnect(connection);
        }
        inner.timeline.set(timeline);
        let now = timeline.map_or_else(String::new, |t| mutation_of(engine, t));
        inner.core.borrow_mut().set_mutation(now);
        if let Some(timeline) = timeline {
            let connected = engine
                .signal_index(timeline, "workspaceChanged")
                .and_then(|s| engine.connect_to(timeline, s, obj, move |e, _| follow(e, obj)));
            match connected {
                Ok(id) => inner.connections.borrow_mut().push(id),
                Err(e) => warn(engine, &e),
            }
        }
    }

    /// How long an edit waits for the next keystroke before it is saved.
    pub fn set_save_delay(engine: &Engine, obj: ObjectId, ms: i32) {
        if let Some(inner) = inner_of(engine, obj) {
            inner.save_delay.set(ms);
        }
    }

    /// The word wrap setting: how long lines show until the user chooses.
    pub fn set_default_wrap(engine: &Engine, obj: ObjectId, wrap: bool) {
        WorkspaceFiles::update(engine, obj, |f| f.set_default_wrap(wrap));
    }

    /// The kinds the user reads as source rather than rendered (the owner
    /// keeps them on this device).
    pub fn source_kinds(engine: &Engine, obj: ObjectId) -> Vec<String> {
        inner_of(engine, obj)
            .map(|inner| inner.core.borrow().source_kinds().to_vec())
            .unwrap_or_default()
    }

    pub fn set_source_kinds(engine: &Engine, obj: ObjectId, kinds: &[String]) {
        WorkspaceFiles::update(engine, obj, |f| f.set_source_kinds(kinds));
    }

    /// Runs `f` after the user chose source kinds (`Files::set_rendered`).
    pub fn on_source_kinds_changed(engine: &Engine, obj: ObjectId, f: impl Fn(&Engine) + 'static) {
        if let Some(inner) = inner_of(engine, obj) {
            inner.hooks.borrow_mut().source_kinds.push(Rc::new(f));
        }
    }

    /// Runs `f(engine, url)` when the environment serves the open file to
    /// the preview browser.
    pub fn on_preview_ready(engine: &Engine, obj: ObjectId, f: impl Fn(&Engine, &str) + 'static) {
        if let Some(inner) = inner_of(engine, obj) {
            inner.hooks.borrow_mut().preview_ready.push(Rc::new(f));
        }
    }

    /// Runs `f(engine, reason)` when the environment would not serve the
    /// open file to the preview browser.
    pub fn on_preview_refused(engine: &Engine, obj: ObjectId, f: impl Fn(&Engine, &str) + 'static) {
        if let Some(inner) = inner_of(engine, obj) {
            inner.hooks.borrow_mut().preview_refused.push(Rc::new(f));
        }
    }

    /// Runs `f(engine, path, problem)` when the MC would not write `path`.
    pub fn on_save_failed(
        engine: &Engine,
        obj: ObjectId,
        f: impl Fn(&Engine, &str, &str) + 'static,
    ) {
        if let Some(inner) = inner_of(engine, obj) {
            inner.hooks.borrow_mut().save_failed.push(Rc::new(f));
        }
    }

    /// Writes what waits, now (desktop-qt's `finishWrites`): its window is
    /// closing, or the app quitting.
    pub fn finish_writes(engine: &Engine, obj: ObjectId) {
        WorkspaceFiles::update(engine, obj, Files::finish_writes);
    }

    /// Whether a write of `obj` is on its way, unanswered.
    pub fn writing(engine: &Engine, obj: ObjectId) -> bool {
        WorkspaceFiles::read(engine, obj, Files::writing).unwrap_or(false)
    }

    /// `f` runs each time the last write on its way is answered
    /// (desktop-qt's `writesFinished`).
    pub fn on_writes_finished(engine: &Engine, obj: ObjectId, f: impl Fn(&Engine) + 'static) {
        if let Some(inner) = inner_of(engine, obj) {
            inner.hooks.borrow_mut().writes_finished.push(Rc::new(f));
        }
    }

    /// Opens a file in the viewer, at `line` when above 0, and reveals it in
    /// the tree.
    pub fn show_file(engine: &Engine, obj: ObjectId, path: &str, line: i32) {
        let opened = WorkspaceFiles::update(engine, obj, |f| f.open_file(path, line));
        if opened == Some(true) {
            WorkspaceFiles::reveal_path(engine, obj, path);
        }
    }

    /// Expands the folders above `path` (loading them as needed) and selects
    /// it.
    pub fn reveal_path(engine: &Engine, obj: ObjectId, path: &str) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        let wanted = WorkspaceFiles::update(engine, obj, |f| f.reveal(path));
        if wanted != Some(true) {
            return;
        }
        let Some(tree) = inner.tree.get() else {
            return;
        };
        if !FileTreeModel::read(engine, tree, |t| t.requested("")).unwrap_or(true) {
            FileTreeModel::update(engine, tree, FileTree::reload);
            return;
        }
        walk_reveal(engine, obj);
    }

    /// Runs `f` on the core of `obj`, then tells the properties, the
    /// signals and the models what it changed and runs what it asked for.
    /// None when `obj` is not a live WorkspaceFiles.
    pub fn update<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&mut Files) -> R) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let origin = inner.mc.origin().unwrap_or_default();
        let now = crate::controllers::sidebar::now_ms(engine);
        let (result, before, after, strings, effects, signals, finished) = {
            let mut core = inner.core.borrow_mut();
            core.set_context(&origin, now);
            let before = core.facts();
            let was_writing = core.writing();
            let result = f(&mut core);
            let finished = was_writing && !core.writing();
            let after = core.facts();
            let moved = after.text_version != before.text_version
                || after.render_kind != before.render_kind
                || after.tsv != before.tsv;
            let strings = moved.then(|| (core.text().to_owned(), core.rendered_text()));
            (
                result,
                before,
                after,
                strings,
                core.take_effects(),
                core.take_signals(),
                finished,
            )
        };
        // The lines first: a view told the file is ready finds them.
        let (lines, others): (Vec<_>, Vec<_>) = effects
            .into_iter()
            .partition(|e| matches!(e, Effect::Lines(_)));
        for effect in lines {
            run(engine, obj, &inner, effect);
        }
        let rendered_moved = write(engine, obj, &before, &after, strings);
        let cx = Cx::new(engine, obj);
        let mut hooks: Vec<KindsHook> = Vec::new();
        let mut failures: Vec<(SaveFailedHook, String, String)> = Vec::new();
        let mut previews: Vec<(PreviewHook, String)> = Vec::new();
        let mut rendered = false;
        for signal in &signals {
            match signal {
                Sig::RevealRequested => warned(engine, WorkspaceFiles::emit_reveal_requested(&cx)),
                Sig::MediaOpened(url) => {
                    warned(
                        engine,
                        WorkspaceFiles::emit_media_opened(&cx, Atom::new(url)),
                    );
                }
                Sig::SourceKinds => {
                    warned(engine, WorkspaceFiles::emit_source_kinds_changed(&cx));
                    hooks.extend(inner.hooks.borrow().source_kinds.iter().cloned());
                }
                Sig::PreviewReady(url) => {
                    warned(
                        engine,
                        WorkspaceFiles::emit_preview_ready(&cx, Atom::new(url)),
                    );
                    for hook in inner.hooks.borrow().preview_ready.iter() {
                        previews.push((hook.clone(), url.clone()));
                    }
                }
                Sig::PreviewRefused(reason) => {
                    warned(
                        engine,
                        WorkspaceFiles::emit_preview_refused(&cx, Atom::new(reason)),
                    );
                    for hook in inner.hooks.borrow().preview_refused.iter() {
                        previews.push((hook.clone(), reason.clone()));
                    }
                }
                Sig::Rendered => rendered = true,
                Sig::SaveFailed { path, problem } => {
                    warned(
                        engine,
                        WorkspaceFiles::emit_save_failed(&cx, Atom::new(path), Atom::new(problem)),
                    );
                    for hook in inner.hooks.borrow().save_failed.iter() {
                        failures.push((hook.clone(), path.clone(), problem.clone()));
                    }
                }
            }
        }
        // Heard once, by whichever came first.
        if rendered && !rendered_moved {
            warned(engine, engine.emit_by_name(obj, "renderedChanged", &[]));
        }
        for hook in hooks {
            hook(engine);
        }
        for (hook, path, problem) in failures {
            hook(engine, &path, &problem);
        }
        for (hook, url) in previews {
            hook(engine, &url);
        }
        for effect in others {
            run(engine, obj, &inner, effect);
        }
        if finished {
            let hooks = inner.hooks.borrow().writes_finished.clone();
            for hook in hooks {
                hook(engine);
            }
        }
        Some(result)
    }

    /// Reads the core of `obj`. `f` must not call back into it.
    pub fn read<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&Files) -> R) -> Option<R> {
        Some(f(&inner_of(engine, obj)?.core.borrow()))
    }

    /// A write from QML: `f` applies it to the core and says whether it
    /// did; the property then reads what the core has.
    fn written(engine: &Engine, obj: ObjectId, f: impl FnOnce(&mut Files) -> bool) {
        let Some(applied) = WorkspaceFiles::update(engine, obj, f) else {
            return;
        };
        if !applied {
            return;
        }
        let Some(facts) = WorkspaceFiles::read(engine, obj, Files::facts) else {
            return;
        };
        let kept = engine
            .set_internal(obj, WorkspaceFiles::QUERY, Atom::new(&facts.query))
            .and_then(|()| engine.set_internal(obj, WorkspaceFiles::WRAP, facts.wrap))
            .and_then(|()| engine.set_internal(obj, WorkspaceFiles::EDITING, facts.editing))
            .and_then(|()| engine.set_internal(obj, WorkspaceFiles::RENDERED, facts.rendered));
        warned(engine, kept);
    }
}

/// Writes the properties that changed from `before` to `after`; whether
/// `rendered` was one of them (it says so itself).
fn write(
    engine: &Engine,
    obj: ObjectId,
    before: &Facts,
    after: &Facts,
    strings: Option<(String, String)>,
) -> bool {
    let atom = |s: &str| Atom::new(s);
    let mut result = Ok(());
    macro_rules! set {
        ($field:ident, $prop:ident, $value:expr) => {
            if result.is_ok() && before.$field != after.$field {
                result = engine.set_internal(obj, WorkspaceFiles::$prop, $value);
            }
        };
    }
    if let Some((text, rendered_text)) = strings {
        result = engine
            .set_internal(obj, WorkspaceFiles::TEXT, atom(&text))
            .and_then(|()| {
                engine.set_internal(obj, WorkspaceFiles::RENDERED_TEXT, atom(&rendered_text))
            });
    }
    set!(editing, EDITING, after.editing);
    set!(root, ROOT, atom(&after.root));
    set!(query, QUERY, atom(&after.query));
    set!(searching, SEARCHING, after.searching);
    set!(search_truncated, SEARCH_TRUNCATED, after.search_truncated);
    set!(search_problem, SEARCH_PROBLEM, atom(&after.search_problem));
    set!(open_path, OPEN_PATH, atom(&after.open_path));
    // Each write notifies at once, and a viewer made when the file is ready
    // reads its media then: the media first.
    set!(media_kind, MEDIA_KIND, atom(after.media_kind));
    set!(media_url, MEDIA_URL, atom(&after.media_url));
    set!(media_document, MEDIA_DOCUMENT, atom(&after.media_document));
    set!(file_status, FILE_STATUS, atom(after.file_status));
    set!(file_problem, FILE_PROBLEM, atom(&after.file_problem));
    set!(
        truncated_notice,
        TRUNCATED_NOTICE,
        atom(&after.truncated_notice)
    );
    set!(file_empty, FILE_EMPTY, after.file_empty);
    set!(reveal_line, REVEAL_LINE, after.reveal_line);
    set!(wrap, WRAP, after.wrap);
    set!(render_kind, RENDER_KIND, atom(after.render_kind));
    set!(editable, EDITABLE, after.editable);
    set!(
        read_only_reason,
        READ_ONLY_REASON,
        atom(after.read_only_reason)
    );
    set!(outside_project, OUTSIDE_PROJECT, after.outside_project);
    set!(unsaved, UNSAVED, after.unsaved);
    set!(save_problem, SAVE_PROBLEM, atom(&after.save_problem));
    set!(trail_folder, TRAIL_FOLDER, atom(&after.trail_folder));
    set!(
        trail_entries,
        TRAIL_ENTRIES,
        Json::Array(after.trail_entries.clone()).to_value()
    );
    set!(trail_problem, TRAIL_PROBLEM, atom(&after.trail_problem));
    // After the entries and the problem: the trail's menu reads them on it.
    set!(trail_status, TRAIL_STATUS, atom(after.trail_status));
    // Last: its signal finds the rest in place.
    set!(rendered, RENDERED, after.rendered);
    warned(engine, result);
    before.rendered != after.rendered
}

/// Runs what the core asked for.
fn run(engine: &Engine, obj: ObjectId, inner: &Inner, effect: Effect) {
    match effect {
        Effect::Call {
            environment,
            method,
            payload,
            then,
        } => inner.mc.call(
            &environment,
            method,
            payload,
            Box::new(move |engine, result: Result<Json, McError>| {
                WorkspaceFiles::update(engine, obj, |f| f.answer(then, result));
            }),
        ),
        Effect::DownloadDocument { relative, request } => {
            inner.mc.download(
                &relative,
                Box::new(move |engine, result| {
                    let kept = result.ok().and_then(|bytes| {
                        let inner = inner_of(engine, obj)?;
                        static NEXT: std::sync::atomic::AtomicU64 =
                            std::sync::atomic::AtomicU64::new(0);
                        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        let path = std::env::temp_dir()
                            .join(format!("hal-c2-{}-{n}.pdf", std::process::id()));
                        std::fs::write(&path, &bytes).ok()?;
                        if let Some(old) = inner.media_document_file.replace(Some(path.clone()))
                            && old != path
                        {
                            let _ = std::fs::remove_file(old);
                        }
                        Some(format!("file://{}", path.display()))
                    });
                    WorkspaceFiles::update(engine, obj, |f| f.document_ready(request, kept));
                }),
            );
        }
        Effect::SearchTimer(start) => restart(
            engine,
            obj,
            &inner.search_timer,
            start.then_some(SEARCH_DELAY_MS),
            |e, obj| {
                WorkspaceFiles::update(e, obj, Files::search);
            },
        ),
        Effect::SaveTimer(start) => restart(
            engine,
            obj,
            &inner.save_timer,
            start.then_some(inner.save_delay.get()),
            |e, obj| {
                WorkspaceFiles::update(e, obj, Files::save_due);
            },
        ),
        Effect::Lines(text) => {
            if let Some(lines) = inner.lines.get() {
                let path = inner.core.borrow().open_path().to_owned();
                TextLinesModel::set_text_at(engine, lines, &text, &path);
            }
        }
        Effect::SetSearch(matches) => {
            if let Some(tree) = inner.tree.get() {
                FileTreeModel::update(engine, tree, |t| t.set_search(matches));
            }
        }
    }
}

/// Stops the timer in `slot` and, with an interval, starts a single shot
/// of `then`. A shot that fired stays until the next restart.
fn restart(
    engine: &Engine,
    obj: ObjectId,
    slot: &Cell<Option<ObjectId>>,
    interval: Option<i32>,
    then: fn(&Engine, ObjectId),
) {
    if let Some(old) = slot.take() {
        let _ = engine.write_by_name(old, "running", Value::Bool(false));
        engine.destroy(old);
    }
    let Some(interval) = interval else {
        return;
    };
    let native = ljos::prelude::Timer {
        interval,
        repeat: false,
        running: true,
        ..ljos::prelude::Timer::default()
    };
    let made = engine.create_native(native, Some(obj)).and_then(|timer| {
        engine.connect_by_name(timer, "triggered", move |engine, _| then(engine, obj))?;
        engine.complete(timer)?;
        Ok(timer)
    });
    match made {
        Ok(timer) => slot.set(Some(timer)),
        Err(e) => warn(engine, &e),
    }
}

/// Asks the MC to list `folder` ("" the top) for the tree; the newest
/// listing of a folder is the one heard, as the MC runs each on its own.
fn list(engine: &Engine, obj: ObjectId, folder: &str) {
    let Some(inner) = inner_of(engine, obj) else {
        return;
    };
    let (environment, root) = {
        let core = inner.core.borrow();
        (core.environment().to_owned(), core.root().to_owned())
    };
    let request = {
        let mut lists = inner.lists.borrow_mut();
        lists.last += 1;
        let request = lists.last;
        lists.by_folder.insert(folder.to_owned(), request);
        request
    };
    let folder = folder.to_owned();
    inner.mc.call(
        &environment,
        "projects.listEntries",
        json!({"cwd": root, "directoryPath": folder}),
        Box::new(move |engine, result: Result<Json, McError>| {
            let Some(inner) = inner_of(engine, obj) else {
                return;
            };
            if inner.lists.borrow().by_folder.get(&folder) != Some(&request) {
                return;
            }
            let Some(tree) = inner.tree.get() else {
                return;
            };
            match result {
                Err(e) => {
                    let problem = defaulted(&e.message, "Unable to load folder.");
                    FileTreeModel::update(engine, tree, |t| t.set_failed(&folder, &problem));
                }
                Ok(reply) => {
                    let entries = entries_of(&reply);
                    FileTreeModel::update(engine, tree, |t| t.set_listing(&folder, entries));
                }
            }
        }),
    );
}

/// Expands the folders above the file being revealed, as their listings
/// land, and selects it.
fn walk_reveal(engine: &Engine, obj: ObjectId) {
    let Some(inner) = inner_of(engine, obj) else {
        return;
    };
    let revealing = inner.core.borrow().revealing().to_owned();
    let Some(tree) = inner.tree.get() else {
        return;
    };
    if revealing.is_empty() || !FileTreeModel::read(engine, tree, |t| t.loaded("")).unwrap_or(false)
    {
        return;
    }
    let parts: Vec<&str> = revealing.split('/').collect();
    let mut folder = String::new();
    for part in &parts[..parts.len() - 1] {
        if !folder.is_empty() {
            folder.push('/');
        }
        folder.push_str(part);
        let expanded = FileTreeModel::read(engine, tree, |t| t.is_expanded(&folder));
        if expanded != Some(true) {
            FileTreeModel::update(engine, tree, |t| t.expand(&folder));
        }
        // Walks on when the folder's listing lands (folderSettled).
        if FileTreeModel::read(engine, tree, |t| t.loaded(&folder)) != Some(true) {
            return;
        }
    }
    let path = inner.core.borrow_mut().take_revealing();
    FileTreeModel::update(engine, tree, |t| t.select(&path));
}

/// What the agent last did to the workspace: the latest finished command or
/// file change, and the checkpoints with their status. A different value
/// means the files may have changed.
pub fn mutation_of(engine: &Engine, timeline: ObjectId) -> String {
    TimelineModel::read(engine, timeline, |t| {
        let mut item = "";
        let mut ordinal = -1_i64;
        for (id, entity) in t.entities("turn-item") {
            let text = |key| entity.get(key).and_then(Json::as_str).unwrap_or("");
            if !matches!(text("type"), "command_execution" | "file_change") {
                continue;
            }
            if matches!(text("status"), "pending" | "running" | "waiting") {
                continue;
            }
            let at = entity
                .get("ordinal")
                .and_then(Json::as_f64)
                .map_or(0, |n| n as i64);
            if at > ordinal {
                ordinal = at;
                item = id;
            }
        }
        let mut checkpoints: Vec<String> = t
            .entities("checkpoint")
            .iter()
            .map(|(id, entity)| {
                let status = entity.get("status").and_then(Json::as_str).unwrap_or("");
                format!("{id}={status}")
            })
            .collect();
        checkpoints.sort();
        format!("{item}\n{}", checkpoints.join(","))
    })
    .unwrap_or_default()
}

/// The workspace may have changed: lists the tree again, or notes it for
/// when the tab shows.
/// Whether the newest file change of `timeline` names `path`.
fn newest_change_names(engine: &Engine, timeline: ObjectId, path: &str) -> bool {
    if path.is_empty() {
        return false;
    }
    TimelineModel::read(engine, timeline, |t| {
        let mut newest: Option<&serde_json::Map<String, Json>> = None;
        let mut ordinal = -1_i64;
        for entity in t.entities("turn-item").values() {
            if entity.get("type").and_then(Json::as_str) != Some("file_change") {
                continue;
            }
            let at = entity
                .get("ordinal")
                .and_then(Json::as_f64)
                .map_or(0, |n| n as i64);
            if at > ordinal {
                ordinal = at;
                newest = Some(entity);
            }
        }
        let Some(newest) = newest else {
            return false;
        };
        if newest.get("fileName").and_then(Json::as_str) == Some(path) {
            return true;
        }
        newest
            .get("changes")
            .and_then(Json::as_array)
            .is_some_and(|changes| {
                changes
                    .iter()
                    .any(|change| change.get("path").and_then(Json::as_str) == Some(path))
            })
    })
    .unwrap_or(false)
}

fn follow(engine: &Engine, obj: ObjectId) {
    let Some(inner) = inner_of(engine, obj) else {
        return;
    };
    let Some(timeline) = inner.timeline.get() else {
        return;
    };
    let now = mutation_of(engine, timeline);
    let open = inner.core.borrow().open_path().to_owned();
    let named = newest_change_names(engine, timeline, &open);
    let followed = WorkspaceFiles::update(engine, obj, |f| f.follow_named(now, named));
    if followed == Some(Followed::Refresh)
        && let Some(tree) = inner.tree.get()
    {
        FileTreeModel::update(engine, tree, FileTree::refresh);
    }
}

/// One `projects.searchEntries` for `query` under `cwd`: the Files tab's
/// search, and the composer's `@` menu. `done` gets the matches and whether
/// the MC had more, or the MC's message (empty when it gave none).
pub fn search_entries(
    mc: &dyn Mc,
    environment: &str,
    cwd: &str,
    query: &str,
    limit: u32,
    done: impl FnOnce(&Engine, Result<(Vec<Entry>, bool), String>) + 'static,
) {
    mc.call(
        environment,
        "projects.searchEntries",
        json!({"cwd": cwd, "query": query, "limit": limit}),
        Box::new(move |engine, result: Result<Json, McError>| {
            done(
                engine,
                result.map_err(|e| e.message).map(|reply| {
                    let truncated = reply
                        .get("truncated")
                        .and_then(Json::as_bool)
                        .unwrap_or(false);
                    (entries_of(&reply), truncated)
                }),
            );
        }),
    );
}

#[qml_impl]
impl WorkspaceFiles {
    #[qml(signal)]
    fn reveal_requested();
    /// The user chose source or rendered for a kind.
    #[qml(signal)]
    fn source_kinds_changed();
    /// The MC would not write `path`.
    #[qml(signal)]
    fn save_failed(path: Atom, problem: Atom);
    /// The browser is to open `url`, the open media file's (`openMedia`).
    #[qml(signal)]
    fn media_opened(url: Atom);
    /// The preview browser is to show `url`, the open file's.
    #[qml(signal)]
    fn preview_ready(url: Atom);
    /// The environment would not serve the open file to the preview.
    #[qml(signal)]
    fn preview_refused(reason: Atom);

    /// The viewer could not load `url`: the file shows why until reloaded,
    /// which signs a new URL.
    #[qml(invokable)]
    fn media_failed(cx: &Cx, url: Atom) {
        WorkspaceFiles::update(cx.engine, cx.this, |f| f.media_failed(&url));
    }

    /// Hands the open media file's URL to the browser (`mediaOpened`),
    /// signing a new one first when it ran out.
    #[qml(invokable)]
    fn open_media(cx: &Cx) {
        WorkspaceFiles::update(cx.engine, cx.this, Files::open_media);
    }

    /// Asks the environment to serve the open file to the preview browser.
    #[qml(invokable)]
    fn open_in_preview(cx: &Cx) {
        WorkspaceFiles::update(cx.engine, cx.this, Files::open_in_preview);
    }

    /// Opens a file in the viewer, at `line` when above 0, and reveals it
    /// in the tree.
    #[qml(invokable)]
    fn open_file(cx: &Cx, path: Atom, line: i32) {
        WorkspaceFiles::show_file(cx.engine, cx.this, &path, line);
    }

    #[qml(invokable)]
    fn close_file(cx: &Cx) {
        WorkspaceFiles::update(cx.engine, cx.this, Files::close_file);
    }

    /// Lists `folder` ("" the workspace) for the path trail.
    #[qml(invokable)]
    fn list_trail(cx: &Cx, folder: Atom) {
        WorkspaceFiles::update(cx.engine, cx.this, |f| f.list_trail(&folder));
    }

    /// Reads the open file again.
    #[qml(invokable)]
    fn reload_file(cx: &Cx) {
        WorkspaceFiles::update(cx.engine, cx.this, Files::reload_file);
    }

    /// Lists the top folder again (after it failed).
    #[qml(invokable)]
    fn reload(cx: &Cx) {
        let Some(inner) = inner_of(cx.engine, cx.this) else {
            return;
        };
        let Some(tree) = inner.tree.get() else {
            return;
        };
        if inner.core.borrow().root().is_empty() {
            return;
        }
        let failed =
            FileTreeModel::read(cx.engine, tree, |t| t.root_status() == "error").unwrap_or(false);
        if failed {
            FileTreeModel::update(cx.engine, tree, |t| t.retry(""));
        } else {
            FileTreeModel::update(cx.engine, tree, FileTree::reload);
        }
    }

    /// Expands the folders above `path` (loading them as needed) and
    /// selects it.
    #[qml(invokable)]
    fn reveal(cx: &Cx, path: Atom) {
        WorkspaceFiles::reveal_path(cx.engine, cx.this, &path);
    }

    /// The open file's text as the user changed it.
    #[qml(invokable)]
    fn edit(cx: &Cx, contents: Atom) {
        WorkspaceFiles::update(cx.engine, cx.this, |f| f.edit(&contents));
    }

    /// Ticks or unticks the open Markdown file's nth task (from 0).
    #[qml(invokable)]
    fn toggle_task(cx: &Cx, index: i32) {
        if let Ok(index) = usize::try_from(index) {
            WorkspaceFiles::update(cx.engine, cx.this, |f| f.toggle_task(index));
        }
    }
}

#[cfg(test)]
#[path = "workspace_files_tests.rs"]
mod tests;
