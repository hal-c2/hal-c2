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
//! rendered view (`toggleTask`) is written at once.
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
use std::collections::HashMap;
use std::rc::Rc;

use ljos::prelude::{Atom, Cx, Engine, ObjectId, QmlObject, Value, qml_impl};
use ljos_engine::{ConnectionId, EngineError, RowKey};
use serde_json::json;

use super::file_render::{self, CSV_ROW_LIMIT};
use super::file_tree::{Entry, FileTree, FileTreeModel};
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

/// A file's text as a list of offsets into one string.
#[derive(Debug, Default)]
pub struct Lines {
    text: String,
    /// (offset, length) in bytes.
    spans: Vec<(usize, usize)>,
    longest: usize,
    changes: Vec<RowChange>,
}

impl Lines {
    pub fn set_text(&mut self, text: &str) {
        self.text = text.to_owned();
        (self.spans, self.longest) = file_render::line_spans(text);
        let keys = (0..self.spans.len()).map(|r| r as RowKey).collect();
        self.changes.push(RowChange::Reset(keys));
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

impl RowSource for Lines {
    fn roles(&self) -> &'static [&'static str] {
        &["text", "number"]
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
            rows: rows.clone(),
        };
        let obj = engine.create_native(model, owner)?;
        rows.attach(engine, obj)?;
        Ok(obj)
    }

    /// Shows `text` as its lines.
    pub fn set_text(engine: &Engine, obj: ObjectId, text: &str) {
        let Ok(rows) = engine.with::<TextLinesModel, _>(obj, |m| m.rows.clone()) else {
            return;
        };
        let (count, columns) = rows.update(engine, |l| {
            l.set_text(text);
            (l.count(), l.max_columns())
        });
        let result = engine
            .set_internal(obj, TextLinesModel::COUNT, int(count))
            .and_then(|()| engine.set_internal(obj, TextLinesModel::MAX_COLUMNS, int(columns)));
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
    Write {
        path: String,
        root: String,
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
    pub reveal_line: i32,
    pub wrap: bool,
    pub text_version: u32,
    pub render_kind: &'static str,
    pub tsv: bool,
    pub rendered: bool,
    pub editable: bool,
    pub read_only_reason: &'static str,
    pub editing: bool,
    pub unsaved: bool,
    pub save_problem: String,
}

/// The viewer, the search and the save of the Files tab.
#[derive(Debug)]
pub struct Files {
    environment: String,
    root: String,
    active: bool,
    query: String,
    search_request: u32,
    searching: bool,
    search_truncated: bool,
    search_problem: String,
    open_path: String,
    open_line: i32,
    file_request: u32,
    file_status: &'static str,
    file_problem: String,
    truncated_notice: String,
    reveal_line: i32,
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
    revision: u32,
    save_problem: String,
    wrap: Option<bool>,
    default_wrap: bool,
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
            active: false,
            query: String::new(),
            search_request: 0,
            searching: false,
            search_truncated: false,
            search_problem: String::new(),
            open_path: String::new(),
            open_line: 0,
            file_request: 0,
            file_status: "none",
            file_problem: String::new(),
            truncated_notice: String::new(),
            reveal_line: 0,
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
            revision: 0,
            save_problem: String::new(),
            wrap: None,
            default_wrap: false,
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
            file_empty: self.file_status == "ready" && self.lines == 0,
            reveal_line: self.reveal_line,
            wrap: self.wrap(),
            text_version: self.text_version,
            render_kind: kind,
            tsv: file_render::extension_of(&self.open_path) == "tsv",
            rendered: self.rendered(),
            editable: self.editable(),
            read_only_reason: self.read_only_reason(),
            editing: self.editing,
            unsaved: self.pending,
            save_problem: self.save_problem.clone(),
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
        !kind.is_empty() && !self.editing && !self.source_kinds.iter().any(|k| k == kind)
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
            _ => self.text.clone(),
        }
    }

    pub fn set_rendered(&mut self, rendered: bool) {
        let kind = self.render_kind();
        let source = self.source_kinds.iter().any(|k| k == kind);
        if kind.is_empty() || rendered == !source {
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
        self.read_only_reason().is_empty() && self.file_status == "ready"
    }

    /// Why the file cannot be edited, or "".
    pub fn read_only_reason(&self) -> &'static str {
        if self.file_status != "ready" {
            ""
        } else if self.truncated {
            "Files larger than 1 MB open read-only."
        } else if self.open_path.starts_with('/') || self.open_path.contains(":\\") {
            // Only a path inside the workspace can be written back.
            "Files outside the project open read-only."
        } else {
            ""
        }
    }

    // --- Workspace ---

    /// The workspace to browse: the environment it is on and its folder
    /// there. A new one forgets the search and the open file (the owner
    /// forgets the tree). False when it is the one already shown.
    pub fn set_target(&mut self, environment: &str, root: &str) -> bool {
        if environment == self.environment && root == self.root {
            return false;
        }
        // An edit of the workspace being left is written there.
        self.save(true);
        self.environment = environment.to_owned();
        self.root = root.to_owned();
        // Answers about the workspace left are dropped.
        self.search_request += 1;
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
        if mutation == self.mutation {
            return Followed::Nothing;
        }
        self.mutation = mutation;
        if self.active {
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
        if path == self.open_path && self.file_status == "ready" {
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
        self.file_request += 1;
        self.file_status = "loading";
        self.file_problem.clear();
        self.truncated_notice.clear();
        self.truncated = false;
        self.signals.push(Sig::Rendered);
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "projects.readFile",
            payload: json!({"cwd": self.root, "relativePath": self.open_path}),
            then: Then::Read(self.file_request),
        });
    }

    pub fn close_file(&mut self) {
        // What the user typed is written before the file goes.
        self.save(true);
        if std::mem::take(&mut self.editing) {
            self.signals.push(Sig::Rendered);
        }
        self.file_request += 1;
        let had = !self.open_path.is_empty() || self.file_status != "none";
        self.open_path.clear();
        self.open_line = 0;
        self.reveal_line = 0;
        self.file_status = "none";
        self.file_problem.clear();
        self.truncated_notice.clear();
        self.truncated = false;
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
    }

    /// The open file's text as the user changed it.
    pub fn edit(&mut self, contents: &str) {
        if !self.editable() || contents == self.text {
            return;
        }
        self.text = contents.to_owned();
        self.text_version += 1;
        self.revision += 1;
        self.pending = true;
        self.save_problem.clear();
        self.effects.push(Effect::SaveTimer(true));
    }

    /// Ticks or unticks the open Markdown file's `index`th task (from 0).
    pub fn toggle_task(&mut self, index: usize) {
        if !self.editable() || self.render_kind() != "markdown" {
            return;
        }
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
        // One write at a time: the next goes when this one is answered.
        if self.saving && !closing {
            return;
        }
        self.saving = !closing;
        if closing {
            self.pending = false;
        }
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "projects.writeFile",
            payload: json!({
                "cwd": self.root,
                "relativePath": self.open_path,
                "contents": self.text,
            }),
            then: Then::Write {
                path: self.open_path.clone(),
                root: self.root.clone(),
                revision: self.revision,
                request: self.file_request,
                closing,
            },
        });
    }

    /// The edit waited long enough.
    pub fn save_due(&mut self) {
        self.save(false);
    }

    // --- Replies ---

    /// The MC answered a call this asked for (`Err`: its message, which may
    /// be empty); an answer for something since replaced is dropped.
    pub fn answer(&mut self, then: Then, result: Result<Json, String>) {
        match then {
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
                    Err(message) => {
                        self.search_problem = defaulted(&message, "Unable to search files.");
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
                    Err(message) => {
                        self.file_status = "error";
                        self.file_problem = defaulted(&message, "Unable to read this file.");
                        self.set_text("");
                        self.signals.push(Sig::Rendered);
                    }
                    Ok(file) => {
                        let contents = file.get("contents").and_then(Json::as_str).unwrap_or("");
                        self.set_text(contents);
                        self.file_status = "ready";
                        self.truncated = file
                            .get("truncated")
                            .and_then(Json::as_bool)
                            .unwrap_or(false);
                        if self.truncated {
                            let bytes =
                                file.get("byteLength").and_then(Json::as_f64).unwrap_or(0.0);
                            self.truncated_notice = format!(
                                "Preview limited to the first 1 MB of a {} byte file.",
                                file_render::grouped(bytes as i64)
                            );
                        }
                        self.signals.push(Sig::Rendered);
                        self.reveal_line = self.clamped(self.open_line);
                        self.signals.push(Sig::RevealRequested);
                    }
                }
            }
            Then::Write {
                path,
                root,
                revision,
                request,
                closing,
            } => {
                let failed = result
                    .as_ref()
                    .err()
                    .map(|m| defaulted(m, "Unable to save this file."));
                if let Some(problem) = &failed {
                    self.signals.push(Sig::SaveFailed {
                        path: path.clone(),
                        problem: problem.clone(),
                    });
                }
                // The file closed, or another opened, meanwhile.
                if closing
                    || path != self.open_path
                    || root != self.root
                    || request != self.file_request
                {
                    return;
                }
                self.saving = false;
                if let Some(problem) = failed {
                    // The edit stays, to be written with the next one.
                    self.save_problem = problem;
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
            }
        }
    }
}

/// The maximum rows a CSV table shows, for the tab's callers.
pub const CSV_ROWS: usize = CSV_ROW_LIMIT;

// --- The object -----------------------------------------------------------

type SaveFailedHook = Rc<dyn Fn(&Engine, &str, &str)>;
type KindsHook = Rc<dyn Fn(&Engine)>;

#[derive(Default)]
struct Hooks {
    save_failed: Vec<SaveFailedHook>,
    source_kinds: Vec<KindsHook>,
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
    /// The thread's TimelineModel followed, and its connection.
    timeline: Cell<Option<ObjectId>>,
    connections: RefCell<Vec<ConnectionId>>,
    hooks: RefCell<Hooks>,
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
    /// QML writes it.
    #[qml(notify)]
    editing: bool,
    /// An edit is not written yet.
    #[qml(readonly, notify)]
    unsaved: bool,
    #[qml(readonly, notify)]
    save_problem: Atom,
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
        ljos_engine::LogLevel::Warning,
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
            timeline: Cell::new(None),
            connections: RefCell::default(),
            hooks: RefCell::default(),
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
            reveal_line: facts.reveal_line,
            wrap: facts.wrap,
            text: atom(""),
            render_kind: atom(facts.render_kind),
            rendered: facts.rendered,
            rendered_text: atom(""),
            editable: facts.editable,
            read_only_reason: atom(facts.read_only_reason),
            editing: facts.editing,
            unsaved: facts.unsaved,
            save_problem: atom(&facts.save_problem),
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

    /// The workspace to browse: the environment it is on and its folder
    /// there. A new one forgets the tree, the search and the open file.
    pub fn set_target(engine: &Engine, obj: ObjectId, environment: &str, root: &str) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        let changed = WorkspaceFiles::update(engine, obj, |f| f.set_target(environment, root));
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
        let (result, before, after, strings, effects, signals) = {
            let mut core = inner.core.borrow_mut();
            let before = core.facts();
            let result = f(&mut core);
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
        let mut rendered = false;
        for signal in &signals {
            match signal {
                Sig::RevealRequested => warned(engine, WorkspaceFiles::emit_reveal_requested(&cx)),
                Sig::SourceKinds => {
                    warned(engine, WorkspaceFiles::emit_source_kinds_changed(&cx));
                    hooks.extend(inner.hooks.borrow().source_kinds.iter().cloned());
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
        for effect in others {
            run(engine, obj, &inner, effect);
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
    set!(unsaved, UNSAVED, after.unsaved);
    set!(save_problem, SAVE_PROBLEM, atom(&after.save_problem));
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
                let result = result.map_err(|e| e.message);
                WorkspaceFiles::update(engine, obj, |f| f.answer(then, result));
            }),
        ),
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
            start.then_some(SAVE_DELAY_MS),
            |e, obj| {
                WorkspaceFiles::update(e, obj, Files::save_due);
            },
        ),
        Effect::Lines(text) => {
            if let Some(lines) = inner.lines.get() {
                TextLinesModel::set_text(engine, lines, &text);
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
    let native = ljos_engine::Timer {
        interval,
        repeat: false,
        running: true,
        ..ljos_engine::Timer::default()
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
fn follow(engine: &Engine, obj: ObjectId) {
    let Some(inner) = inner_of(engine, obj) else {
        return;
    };
    let Some(timeline) = inner.timeline.get() else {
        return;
    };
    let now = mutation_of(engine, timeline);
    let followed = WorkspaceFiles::update(engine, obj, |f| f.follow(now));
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
