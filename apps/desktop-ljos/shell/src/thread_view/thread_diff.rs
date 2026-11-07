//! desktop-qt's ThreadDiff: the Diff tab, what a thread's turns changed,
//! from the checkpoint each finished turn leaves (the stream's `checkpoint`
//! entities, turn N being the ready one with appRunOrdinal N). One turn's
//! diff is `orchestration.getTurnDiff` from N-1 to N, all changes
//! `orchestration.getFullThreadDiff` up to the latest turn; either lands in
//! `model` (a [`DiffModel`]) as rows.
//!
//! `selection` is -1 for the latest turn (the default, following new
//! turns), 0 for all changes, or a turn number. Only a shown tab loads; a
//! hidden one notes that it is stale and loads when shown again.
//!
//! The checkout itself can be reviewed too (`review.getDiffPreview`):
//! [`WORKING_TREE`] is its uncommitted changes, [`BRANCH`] the whole branch
//! against its base, which is the MC's choice until `baseRef` names another.
//! `baseChoices` offers the checkout's refs for it (`vcs.listRefs`). A
//! thread with no finished turn opens on the working tree. `reload()` asks
//! again.
//!
//! While the user has not picked the latest turn, a latest turn whose
//! checkpoint lists no changed files opens on all changes when an earlier
//! turn changed some.
//!
//! A review the MC cut short (`truncated`) but whose files it counted lists
//! those files without their changes, and each file's are loaded when it is
//! opened ([`DiffModel`]'s fileWanted): one file's patch is
//! `review.getDiffPreview` with `file`.
//!
//! Each thread keeps its own selection and base, for as long as the app
//! runs.
//!
//! Opening one changed file from a reply shows that file alone
//! (`focusPath`) until the user asks for all of the selection's files again
//! or picks another selection.
//!
//! Reverting asks first: `requestRevert(turn)` sets `revertTurn` until
//! `confirmRevert()` dispatches `checkpoint.rollback` or `cancelRevert()`
//! drops it. The outcome is told as a toast.
//!
//! [`DiffTab`] is the core: it takes the timeline's checkpoints and the MC's
//! replies and says what to ask as [`Effect`]s. [`ThreadDiff`] is the object
//! QML binds; it runs those effects on the shell's MC and follows the
//! thread's [`TimelineModel`].

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::rc::Rc;
use std::sync::LazyLock;

use ljos::prelude::QmlValue;
use ljos::prelude::{Atom, Cx, Engine, ObjectId, QmlObject, Value, qml_impl};
use ljos::prelude::{EngineError, RowKey};
use regex::Regex;
use serde_json::json;

use super::diff::{AsDiff, Diff, DiffModel, without_truncated_marker};
use super::rows::{ListRows, RowChange, RowSource, int};
use super::summary::Obj;
use super::timeline::{Out, Timeline};
use super::timeline_model::TimelineModel;
use crate::json::Json;
use crate::mc::{Mc, McError};

/// The selection that reviews the checkout's uncommitted changes.
pub const WORKING_TREE: i32 = -2;
/// The selection that reviews the whole branch against its base.
pub const BRANCH: i32 = -3;

const LOADING_TURNS: &str = "Loading checkpoint diff...";
const COULD_NOT_LOAD: &str = "Could not load the diff.";
const NO_PATCH: &str = "No patch available for this selection.";
const GONE: &str = "Diff no longer available. Refresh the comparison.";

/// What a reply answers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Then {
    /// A turn's diff, or all changes: request `request`.
    Turn { request: u64 },
    /// The checkout's diffs, `selection` the one shown.
    Review { request: u64, selection: i32 },
    /// The revert to after `turn` of `thread`.
    Revert { turn: i32, thread: String },
    /// The checkout's refs, for the base picker.
    Bases { request: u64 },
    /// One file of a review cut short, of the files listed `listing`.
    File { listing: u64, path: String },
}

/// What the tab asks of the world.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    Call {
        environment: String,
        method: &'static str,
        payload: Json,
        then: Then,
    },
    /// `orchestration.dispatchCommand`, through `Mc::dispatch_command`.
    Dispatch {
        environment: String,
        command: Json,
        then: Then,
    },
    /// A toast: type ("error", "success"), title, description.
    Notify {
        kind: &'static str,
        title: String,
        description: String,
    },
    /// The view should show `row` of the model at its top.
    Reveal(usize),
}

/// The tab's signals, each covering some properties: it fires once when
/// one of them changed and never otherwise.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Signal {
    /// choices, latestTurn, the latest checkpoint (its files can come after
    /// it is ready).
    Turns,
    /// selection, shownTurn, reviewing.
    Selection,
    /// status, message.
    Status,
    /// focusPath, fileTotal.
    Focus,
    /// baseRef, comparedBase, comparedHead, truncated.
    Review,
    /// canRevert, revertTurn, reverting.
    Revert,
    /// ignoreWhitespace, wrap.
    Options,
    /// baseChoices, baseQuery, basesLoading.
    Bases,
}

/// What the properties show; [`Facts::signals`] compares two.
#[derive(Clone, Debug, PartialEq)]
pub struct Facts {
    pub choices: Vec<(i32, String)>,
    pub latest_turn: i32,
    pub latest_checkpoint: Obj,
    pub selection: i32,
    pub shown_turn: i32,
    pub reviewing: bool,
    pub status: &'static str,
    pub message: String,
    pub focus: String,
    pub file_total: usize,
    pub base_ref: String,
    pub compared_base: String,
    pub compared_head: String,
    pub truncated: bool,
    pub can_revert: bool,
    pub revert_turn: i32,
    pub reverting: bool,
    pub ignore_whitespace: bool,
    pub wrap: bool,
    /// The refs read, what is searched, whether they are being read.
    pub bases: (u64, String, bool),
}

impl Facts {
    /// The signals that say what changed from `before` to `self`.
    pub fn signals(&self, before: &Facts) -> Vec<Signal> {
        let mut signals = Vec::new();
        let mut say = |changed: bool, signal| {
            if changed {
                signals.push(signal);
            }
        };
        say(
            self.choices != before.choices
                || self.latest_turn != before.latest_turn
                || self.latest_checkpoint != before.latest_checkpoint,
            Signal::Turns,
        );
        say(
            self.selection != before.selection
                || self.shown_turn != before.shown_turn
                || self.reviewing != before.reviewing,
            Signal::Selection,
        );
        say(
            self.status != before.status || self.message != before.message,
            Signal::Status,
        );
        say(
            self.focus != before.focus || self.file_total != before.file_total,
            Signal::Focus,
        );
        say(
            self.base_ref != before.base_ref
                || self.compared_base != before.compared_base
                || self.compared_head != before.compared_head
                || self.truncated != before.truncated,
            Signal::Review,
        );
        say(
            self.can_revert != before.can_revert
                || self.revert_turn != before.revert_turn
                || self.reverting != before.reverting,
            Signal::Revert,
        );
        say(
            self.ignore_whitespace != before.ignore_whitespace || self.wrap != before.wrap,
            Signal::Options,
        );
        // The branch under review is left out of the bases.
        say(
            self.bases != before.bases || self.compared_head != before.compared_head,
            Signal::Bases,
        );
        signals
    }
}

/// The Diff tab of one thread at a time.
#[derive(Debug)]
pub struct DiffTab {
    diff: Diff,
    environment: String,
    thread: String,
    /// The thread's timeline is there to read checkpoints from.
    timeline: bool,
    working: bool,
    /// Turn number -> its ready checkpoint.
    turns: BTreeMap<i32, Obj>,
    selection: i32,
    /// The user picked the latest turn, so it is shown even when it changed
    /// nothing.
    latest_picked: bool,
    /// What each other thread shows ("environment:thread"): selection,
    /// base, latest picked.
    remembered: HashMap<String, (i32, String, bool)>,
    cwd: String,
    /// The checkout's refs for the base picker, and how often they were
    /// read.
    refs: Vec<Json>,
    refs_read: u64,
    base_query: String,
    bases_loading: bool,
    bases_request: u64,
    /// A load following the checkout keeps what is shown until answered.
    quiet: bool,
    /// The review's source shown, by its kind and hash: the same answer
    /// again leaves the diff (opened files, loaded patches) alone.
    source_key: String,
    /// The focus the diff was last filled for.
    presented: String,
    /// The files are listed without their changes, each loaded when opened.
    lazy: bool,
    /// Counts the files listed, for an answer to tell its own.
    listing: u64,
    lazy_kind: &'static str,
    base_ref: String,
    compared_base: String,
    compared_head: String,
    truncated: bool,
    active: bool,
    ignore_whitespace: Option<bool>,
    default_ignore_whitespace: bool,
    wrap: Option<bool>,
    default_wrap: bool,
    status: &'static str,
    message: String,
    /// What `diff` shows (or is loading), so a repeat asks nothing.
    loaded: String,
    request: u64,
    pending_reveal: String,
    /// The selection's whole patch, and the one file of it shown.
    patch: String,
    focus: String,
    file_total: usize,
    revert_turn: i32,
    reverting: bool,
    effects: Vec<Effect>,
}

impl Default for DiffTab {
    fn default() -> DiffTab {
        DiffTab {
            diff: Diff::new(),
            environment: String::new(),
            thread: String::new(),
            timeline: false,
            working: false,
            turns: BTreeMap::new(),
            selection: -1,
            latest_picked: false,
            remembered: HashMap::new(),
            cwd: String::new(),
            refs: Vec::new(),
            refs_read: 0,
            base_query: String::new(),
            bases_loading: false,
            bases_request: 0,
            quiet: false,
            source_key: String::new(),
            presented: String::new(),
            lazy: false,
            listing: 0,
            lazy_kind: "",
            base_ref: String::new(),
            compared_base: String::new(),
            compared_head: String::new(),
            truncated: false,
            active: false,
            ignore_whitespace: None,
            default_ignore_whitespace: true,
            wrap: None,
            default_wrap: false,
            status: "idle",
            message: String::new(),
            loaded: String::new(),
            request: 0,
            pending_reveal: String::new(),
            patch: String::new(),
            focus: String::new(),
            file_total: 0,
            revert_turn: 0,
            reverting: false,
            effects: Vec::new(),
        }
    }
}

fn text<'a>(object: &'a Obj, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or("")
}

static FILE_HEADER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^diff --git ").expect("the header pattern"));

impl DiffTab {
    pub fn new() -> DiffTab {
        DiffTab::default()
    }

    pub fn facts(&self) -> Facts {
        Facts {
            choices: self.choices(),
            latest_turn: self.latest_turn(),
            latest_checkpoint: self.latest_checkpoint(),
            selection: self.selection(),
            shown_turn: self.shown_turn(),
            reviewing: self.reviewing(),
            status: self.status,
            message: self.message.clone(),
            focus: self.focus.clone(),
            file_total: self.file_total,
            base_ref: self.base_ref.clone(),
            compared_base: self.compared_base.clone(),
            compared_head: self.compared_head.clone(),
            truncated: self.truncated,
            can_revert: self.can_revert(),
            revert_turn: self.revert_turn,
            reverting: self.reverting,
            ignore_whitespace: self.ignore_whitespace(),
            wrap: self.wrap(),
            bases: (self.refs_read, self.base_query.clone(), self.bases_loading),
        }
    }

    /// The thread shown, its timeline's checkpoints and whether it is
    /// working (`None`: the timeline is not there yet), and its checkout.
    /// Another thread's selection and base are checked against its own
    /// checkout. The caller passes only the checkout when neither the thread
    /// nor its timeline changed.
    pub fn set_thread(
        &mut self,
        environment: &str,
        thread: &str,
        timeline: Option<(Vec<Obj>, bool)>,
        cwd: &str,
    ) {
        if environment != self.environment || thread != self.thread {
            if !self.thread.is_empty() {
                self.remembered.insert(
                    format!("{}:{}", self.environment, self.thread),
                    (self.selection, self.base_ref.clone(), self.latest_picked),
                );
            }
            let (selection, base_ref, latest_picked) = self
                .remembered
                .remove(&format!("{environment}:{thread}"))
                .unwrap_or((-1, String::new(), false));
            environment.clone_into(&mut self.environment);
            thread.clone_into(&mut self.thread);
            self.request += 1;
            self.loaded.clear();
            self.pending_reveal.clear();
            self.patch.clear();
            self.focus.clear();
            self.file_total = 0;
            self.diff.clear();
            self.compared_base.clear();
            self.compared_head.clear();
            self.truncated = false;
            self.revert_turn = 0;
            self.reverting = false;
            self.selection = selection;
            self.base_ref = base_ref;
            self.latest_picked = latest_picked;
            self.source_key.clear();
            self.lazy = false;
            self.refs.clear();
            self.refs_read += 1;
            self.base_query.clear();
            self.bases_request += 1;
            self.bases_loading = false;
            self.set_status("idle", "");
        }
        cwd.clone_into(&mut self.cwd);
        self.timeline = timeline.is_some();
        let (checkpoints, working) = timeline.unwrap_or_default();
        self.working = working;
        self.take_checkpoints(checkpoints);
    }

    /// The timeline's checkpoints changed.
    pub fn set_checkpoints(&mut self, checkpoints: Vec<Obj>) {
        if self.timeline {
            self.take_checkpoints(checkpoints);
        }
    }

    /// The thread started or stopped working.
    pub fn set_working(&mut self, working: bool) {
        self.working = working;
    }

    /// The thread's checkout, for reviewing it; empty when it has none.
    pub fn set_checkout(&mut self, cwd: &str) {
        if cwd == self.cwd {
            return;
        }
        cwd.clone_into(&mut self.cwd);
        // Without a checkout there is nothing to review.
        if self.cwd.is_empty() && self.selection <= WORKING_TREE {
            self.selection = -1;
        }
        self.load();
    }

    /// The agent changed the checkout: what is shown of it is asked for
    /// again, keeping a shown diff until the answer comes (the same answer
    /// leaves it as it is).
    pub fn follow(&mut self) {
        if !self.reviewing() {
            return;
        }
        // A hidden tab loads when it is shown again.
        self.loaded.clear();
        self.quiet = self.status == "ready";
        self.load();
        self.quiet = false;
    }

    pub fn set_active(&mut self, active: bool) {
        self.active = active;
        self.load();
    }

    fn take_checkpoints(&mut self, checkpoints: Vec<Obj>) {
        let mut counted = Vec::new();
        for checkpoint in checkpoints {
            // The thread's baseline has no turn; one that failed or went
            // missing has no diff.
            let Some(ordinal) = checkpoint.get("appRunOrdinal").and_then(Json::as_f64) else {
                continue;
            };
            if text(&checkpoint, "status") != "ready" {
                continue;
            }
            counted.push((ordinal, checkpoint));
        }
        // As the MC counts getTurnDiff's turns: the ready checkpoints in
        // order, one still being written having no number yet.
        counted.sort_by(|a, b| a.0.total_cmp(&b.0));
        let turns: BTreeMap<i32, Obj> = (1..).zip(counted.into_iter().map(|(_, c)| c)).collect();
        self.turns = turns;
        // A turn that went away (rewound) leaves the picker on the latest
        // one, as does all changes once no turn is left, and the checkout's
        // choices without one.
        if (self.selection > 0 && !self.turns.contains_key(&self.selection))
            || (self.selection == 0 && self.turns.is_empty())
            || (self.selection <= WORKING_TREE && self.cwd.is_empty())
        {
            self.selection = -1;
        }
        self.load();
    }

    /// `{value, label}` for the picker: the latest turn, all changes, then
    /// each finished turn, newest first; then the checkout's.
    pub fn choices(&self) -> Vec<(i32, String)> {
        let mut choices = Vec::new();
        if !self.turns.is_empty() {
            choices.push((-1, "Latest turn".to_owned()));
            choices.push((0, "All changes".to_owned()));
            for turn in self.turns.keys().rev() {
                choices.push((*turn, format!("Turn {turn}")));
            }
        }
        if !self.cwd.is_empty() {
            choices.push((WORKING_TREE, "Working tree".to_owned()));
            choices.push((BRANCH, "Branch changes".to_owned()));
        }
        choices
    }

    pub fn latest_turn(&self) -> i32 {
        self.turns.keys().next_back().copied().unwrap_or(0)
    }

    /// The latest finished turn's checkpoint (its `id` and the `files` it
    /// changed); empty when none.
    pub fn latest_checkpoint(&self) -> Obj {
        self.turns.values().next_back().cloned().unwrap_or_default()
    }

    pub fn selection(&self) -> i32 {
        if self.selection == -1 && self.opens_on_all_changes() {
            0
        } else {
            self.selection
        }
    }

    /// The default shows all changes: the latest turn changed no files, an
    /// earlier one did, and the user has not picked the latest turn.
    fn opens_on_all_changes(&self) -> bool {
        if self.latest_picked || self.turns.len() < 2 {
            return false;
        }
        let changed = |checkpoint: &Obj| {
            checkpoint
                .get("files")
                .and_then(Json::as_array)
                .is_some_and(|files| !files.is_empty())
        };
        if self.turns.values().next_back().is_some_and(changed) {
            return false;
        }
        self.turns.values().any(changed)
    }

    /// The selection shown: the working tree stands in for the latest turn
    /// of a thread that has none, and all changes for one that changed
    /// nothing.
    fn effective_selection(&self) -> i32 {
        if self.selection == -1 && self.turns.is_empty() && !self.cwd.is_empty() {
            WORKING_TREE
        } else {
            self.selection()
        }
    }

    pub fn select(&mut self, selection: i32) {
        if selection > 0 && !self.turns.contains_key(&selection) {
            return;
        }
        let selection = if selection < BRANCH
            || (selection <= WORKING_TREE && self.cwd.is_empty())
            || (selection == 0 && self.turns.is_empty())
        {
            -1
        } else {
            selection
        };
        // Picking the latest turn shows it from then on, even when it
        // changed nothing.
        if selection == self.selection && !(selection == -1 && self.opens_on_all_changes()) {
            if selection == -1 {
                self.latest_picked = true;
            }
            return;
        }
        self.selection = selection;
        self.latest_picked = selection == -1;
        // Another selection is shown whole, even when it is the same diff.
        if !self.focus.is_empty() {
            self.focus.clear();
            if self.status == "ready" {
                self.present();
            }
        }
        self.load();
    }

    /// Selects the turn the run (a turn id) finished; unknown runs change
    /// nothing.
    pub fn select_run(&mut self, run: &str) {
        let turn = self
            .turns
            .iter()
            .find(|(_, checkpoint)| text(checkpoint, "runId") == run)
            .map(|(turn, _)| *turn);
        if let Some(turn) = turn {
            self.select(turn);
        }
    }

    /// The turn shown (0: all changes, or the checkout).
    pub fn shown_turn(&self) -> i32 {
        let selection = self.effective_selection();
        if selection == 0 || self.reviewing() {
            0
        } else if selection > 0 {
            selection
        } else {
            self.latest_turn()
        }
    }

    /// The checkout is what is shown, not a turn.
    pub fn reviewing(&self) -> bool {
        self.effective_selection() <= WORKING_TREE
    }

    pub fn base_ref(&self) -> &str {
        &self.base_ref
    }

    /// The ref the branch is compared against ("" lets the MC pick).
    pub fn set_base_ref(&mut self, base: &str) {
        let base = base.trim();
        if base == self.base_ref {
            return;
        }
        base.clone_into(&mut self.base_ref);
        self.load();
    }

    pub fn compared_base(&self) -> &str {
        &self.compared_base
    }

    pub fn compared_head(&self) -> &str {
        &self.compared_head
    }

    /// The MC cut the patch short; the files' counts are still whole.
    pub fn truncated(&self) -> bool {
        self.truncated
    }

    /// idle, loading, ready, empty (nothing to show, `message` says why) or
    /// error (`message` is the MC's reason).
    pub fn status(&self) -> &'static str {
        self.status
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    /// Whether whitespace-only edits are left out: what the user chose
    /// here, else the "Hide whitespace changes" setting.
    pub fn ignore_whitespace(&self) -> bool {
        self.ignore_whitespace
            .unwrap_or(self.default_ignore_whitespace)
    }

    pub fn set_ignore_whitespace(&mut self, ignore: bool) {
        if ignore == self.ignore_whitespace() {
            return;
        }
        self.ignore_whitespace = Some(ignore);
        self.load();
    }

    pub fn set_default_ignore_whitespace(&mut self, ignore: bool) {
        let was = self.ignore_whitespace();
        self.default_ignore_whitespace = ignore;
        if self.ignore_whitespace() != was {
            self.load();
        }
    }

    /// Whether long lines wrap: what the user chose here, else the word
    /// wrap setting.
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

    pub fn focus_path(&self) -> &str {
        &self.focus
    }

    /// How many files the selection changed, the focused one among them.
    pub fn file_total(&self) -> usize {
        self.file_total
    }

    pub fn diff(&self) -> &Diff {
        &self.diff
    }

    fn set_status(&mut self, status: &'static str, message: &str) {
        self.status = status;
        message.clone_into(&mut self.message);
    }

    fn load_key(&self) -> String {
        let whitespace = self.ignore_whitespace();
        let (environment, thread) = (&self.environment, &self.thread);
        if self.reviewing() {
            let selection = self.effective_selection();
            let base = if selection == BRANCH {
                self.base_ref.as_str()
            } else {
                ""
            };
            return format!(
                "{environment}:{thread} review {selection} {} {base} {whitespace}",
                self.cwd
            );
        }
        // The checkpoints the diff is between: a rewound turn's number comes
        // back with another checkpoint, and one being written becomes ready
        // later.
        let all = self.effective_selection() == 0;
        let to = if all {
            self.latest_turn()
        } else {
            self.shown_turn()
        };
        let id = |turn: i32| self.turns.get(&turn).map_or("", |c| text(c, "id"));
        let from = if all { "" } else { id(to - 1) };
        let kind = if all { "all" } else { "turn" };
        format!(
            "{environment}:{thread} {kind} {to} {from} {} {whitespace}",
            id(to)
        )
    }

    /// Loads the selection again.
    pub fn reload(&mut self) {
        self.loaded.clear();
        self.load();
    }

    fn forget(&mut self) {
        self.request += 1;
        self.loaded.clear();
    }

    fn load(&mut self) {
        if !self.active || self.thread.is_empty() {
            return;
        }
        if !self.timeline {
            // What is shown is asked for again once the timeline comes.
            self.forget();
            return self.set_status("loading", LOADING_TURNS);
        }
        if self.reviewing() {
            return self.load_review(self.effective_selection());
        }
        if self.turns.is_empty() {
            self.forget();
            self.patch.clear();
            self.lazy = false;
            self.source_key.clear();
            self.file_total = 0;
            self.diff.clear();
            return self.set_status("empty", "No completed turns yet.");
        }
        let key = self.load_key();
        if key == self.loaded {
            return;
        }
        self.loaded = key;
        self.request += 1;
        let turn = self.shown_turn();
        let mut payload =
            json!({"threadId": self.thread, "ignoreWhitespace": self.ignore_whitespace()});
        let method = if self.effective_selection() == 0 {
            payload["toTurnCount"] = json!(self.latest_turn());
            "orchestration.getFullThreadDiff"
        } else {
            payload["fromTurnCount"] = json!(turn - 1);
            payload["toTurnCount"] = json!(turn);
            "orchestration.getTurnDiff"
        };
        self.set_status("loading", LOADING_TURNS);
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method,
            payload,
            then: Then::Turn {
                request: self.request,
            },
        });
    }

    // review.getDiffPreview answers with both sources; the one selected is
    // shown.
    fn load_review(&mut self, selection: i32) {
        let key = self.load_key();
        if key == self.loaded {
            return;
        }
        self.loaded = key;
        self.request += 1;
        let mut payload = json!({"cwd": self.cwd, "ignoreWhitespace": self.ignore_whitespace()});
        if selection == BRANCH && !self.base_ref.is_empty() {
            payload["baseRef"] = json!(self.base_ref);
        }
        if !self.quiet {
            self.set_status("loading", "Loading changes...");
        }
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "review.getDiffPreview",
            payload,
            then: Then::Review {
                request: self.request,
                selection,
            },
        });
    }

    /// What the MC answered.
    pub fn answer(&mut self, then: Then, result: Result<Json, String>) {
        match then {
            Then::Turn { request } | Then::Review { request, .. } if request != self.request => {}
            Then::Turn { .. } | Then::Review { .. } => {
                let result = match result {
                    Ok(result) => result,
                    Err(error) => return self.failed(&error),
                };
                let selection = match then {
                    Then::Review { selection, .. } => Some(selection),
                    _ => None,
                };
                self.listed(&result, selection);
                let reveal = std::mem::take(&mut self.pending_reveal);
                if !reveal.is_empty() {
                    self.reveal_file(&reveal);
                }
            }
            Then::Revert { turn, thread } => {
                if thread == self.thread {
                    self.reverting = false;
                }
                let effect = match result {
                    Err(error) => Effect::Notify {
                        kind: "error",
                        title: format!("Could not revert to turn {turn}"),
                        description: if error.is_empty() {
                            "An error occurred.".to_owned()
                        } else {
                            error
                        },
                    },
                    Ok(_) => Effect::Notify {
                        kind: "success",
                        title: format!("Reverted to turn {turn}."),
                        description: String::new(),
                    },
                };
                self.effects.push(effect);
            }
            Then::Bases { request } => {
                if request != self.bases_request {
                    return;
                }
                self.bases_loading = false;
                if let Ok(result) = result {
                    self.refs = result
                        .get("refs")
                        .and_then(Json::as_array)
                        .cloned()
                        .unwrap_or_default();
                }
                self.refs_read += 1;
            }
            Then::File { listing, path } => self.file_listed(listing, &path, result),
        }
    }

    // One file's patch of a review cut short came.
    fn file_listed(&mut self, listing: u64, path: &str, result: Result<Json, String>) {
        // Another diff is shown meanwhile.
        if listing != self.listing || !self.lazy {
            return;
        }
        let Some(file) = self.diff.file_of(path) else {
            return;
        };
        let result = match result {
            Ok(result) => result,
            Err(error) => {
                let error = if error.is_empty() {
                    COULD_NOT_LOAD
                } else {
                    &error
                };
                return self.diff.set_file_state(file, "error", error);
            }
        };
        let kind = self.lazy_kind;
        let source = result
            .get("sources")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
            .filter_map(Json::as_object)
            .find(|s| text(s, "kind") == kind);
        // The checkout no longer has what was listed.
        let Some(source) = source else {
            return self.diff.set_file_state(file, "gone", GONE);
        };
        let partial = source.get("truncated").and_then(Json::as_bool) == Some(true);
        let patch = without_truncated_marker(text(source, "diff"));
        if !self.diff.set_file_patch(file, &patch, partial) {
            self.diff
                .set_file_state(file, "missing", "No patch available for this file.");
        }
    }

    /// Loads one file's changes of a review cut short, as its opening asks.
    pub fn load_file(&mut self, file: usize) {
        if !self.lazy || file >= self.diff.file_count() {
            return;
        }
        let path = self.diff.path(file).unwrap_or_default().to_owned();
        let previous = self.diff.previous_path(file).unwrap_or_default();
        let previous = if previous.is_empty() {
            Json::Null
        } else {
            json!(previous)
        };
        let mut payload = json!({
            "cwd": self.cwd,
            "ignoreWhitespace": self.ignore_whitespace(),
            "file": {"path": path, "previousPath": previous, "sourceKind": self.lazy_kind},
        });
        if self.lazy_kind == "branch-range" && !self.base_ref.is_empty() {
            payload["baseRef"] = json!(self.base_ref);
        }
        self.diff.set_file_state(file, "loading", "");
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "review.getDiffPreview",
            payload,
            then: Then::File {
                listing: self.listing,
                path,
            },
        });
    }

    /// Loads one file's changes of a review cut short again (after an
    /// error).
    pub fn retry_file(&mut self, path: &str) {
        if let Some(file) = self.diff.file_of(path) {
            self.load_file(file);
        }
    }

    /// The refs the branch can be compared against, as `base_query` filters
    /// them: `{id, label, ref, remoteOnly}`, "Automatic" (id "automatic",
    /// ref "") first while nothing is searched. A local branch and its
    /// remote one are one choice, compared as the local; the branch under
    /// review is not offered.
    pub fn base_choices(&self) -> Vec<Json> {
        let name = |r: &Json| {
            r.get("name")
                .and_then(Json::as_str)
                .unwrap_or("")
                .to_owned()
        };
        let remote_of = |r: &Json| {
            r.get("remoteName")
                .and_then(Json::as_str)
                .unwrap_or("")
                .to_owned()
        };
        // "origin/release" -> "release".
        let branch = |r: &Json| {
            let (name, remote) = (name(r), remote_of(r));
            match name.strip_prefix(&format!("{remote}/")) {
                Some(rest) if !remote.is_empty() => rest.to_owned(),
                _ => name,
            }
        };
        let (remotes, locals): (Vec<&Json>, Vec<&Json>) = self
            .refs
            .iter()
            .partition(|r| r.get("isRemote").and_then(Json::as_bool) == Some(true));
        let mut used = vec![false; remotes.len()];
        // (id, label, local, remote)
        let mut entries: Vec<(String, String, String, String)> = Vec::new();
        for local in locals.into_iter().filter(|r| name(r) != self.compared_head) {
            let local = name(local);
            // Its remote one, origin's first.
            let mut found: Option<usize> = None;
            for (i, remote) in remotes.iter().enumerate() {
                if used[i] || branch(remote) != local {
                    continue;
                }
                if found.is_none() || remote_of(remote) == "origin" {
                    found = Some(i);
                }
            }
            let remote = found.map_or_else(String::new, |i| {
                used[i] = true;
                name(remotes[i])
            });
            entries.push((format!("local:{local}"), local.clone(), local, remote));
        }
        for (i, remote) in remotes.iter().enumerate() {
            if !used[i] {
                let remote = name(remote);
                entries.push((
                    format!("remote:{remote}"),
                    remote.clone(),
                    String::new(),
                    remote,
                ));
            }
        }
        let query = self.base_query.trim().to_lowercase();
        let mut out = Vec::new();
        if query.is_empty() {
            out.push(
                json!({"id": "automatic", "label": "Automatic", "ref": "", "remoteOnly": false}),
            );
        }
        for (id, label, local, remote) in entries {
            let matches = [&label, &local, &remote]
                .iter()
                .any(|s| s.to_lowercase().contains(&query));
            if !query.is_empty() && !matches {
                continue;
            }
            let remote_only = local.is_empty();
            let reference = if remote_only { remote } else { local };
            out.push(
                json!({"id": id, "label": label, "ref": reference, "remoteOnly": remote_only}),
            );
        }
        out
    }

    pub fn base_query(&self) -> &str {
        &self.base_query
    }

    pub fn set_base_query(&mut self, query: &str) {
        query.clone_into(&mut self.base_query);
    }

    pub fn bases_loading(&self) -> bool {
        self.bases_loading
    }

    /// Asks the checkout for its refs again (the base picker opening).
    pub fn load_bases(&mut self) {
        if self.cwd.is_empty() || self.thread.is_empty() {
            return;
        }
        self.bases_request += 1;
        self.bases_loading = true;
        // Every ref at once, filtered here: "origin/release" finds the
        // local "release".
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "vcs.listRefs",
            payload: json!({"cwd": self.cwd, "limit": 500, "includeMatchingRemoteRefs": true}),
            then: Then::Bases {
                request: self.bases_request,
            },
        });
    }

    /// Compares against the choice `id` of [`DiffTab::base_choices`].
    pub fn choose_base(&mut self, id: &str) {
        let choice = self.base_choices().into_iter().find(|c| c["id"] == id);
        if let Some(choice) = choice {
            self.set_base_ref(choice["ref"].as_str().unwrap_or(""));
        }
    }

    /// What the user typed: the choice labelled so, else the ref as typed.
    pub fn choose_typed_base(&mut self, typed: &str) {
        let typed = typed.trim();
        if typed.is_empty() || typed.eq_ignore_ascii_case("automatic") {
            return self.set_base_ref("");
        }
        let choice = self
            .base_choices()
            .into_iter()
            .find(|c| c["label"] == typed);
        match choice {
            Some(choice) => self.set_base_ref(choice["ref"].as_str().unwrap_or("")),
            None => self.set_base_ref(typed),
        }
    }

    fn failed(&mut self, error: &str) {
        // Asking again (reload, another turn) tries once more.
        self.loaded.clear();
        self.patch.clear();
        self.lazy = false;
        self.source_key.clear();
        self.file_total = 0;
        self.diff.clear();
        let error = if error.is_empty() {
            COULD_NOT_LOAD
        } else {
            error
        };
        self.set_status("error", error);
    }

    /// A diff came: a turn's (`selection` none) or the checkout's.
    fn listed(&mut self, result: &Json, selection: Option<i32>) {
        let Some(selection) = selection else {
            let diff = result
                .get("diff")
                .and_then(Json::as_str)
                .unwrap_or_default();
            // Something came back, but no file of it can be shown.
            let why = if diff.trim().is_empty() {
                "No net changes in this selection."
            } else {
                NO_PATCH
            };
            self.patch = diff.to_owned();
            self.lazy = false;
            self.source_key.clear();
            self.present();
            if self.diff.file_count() == 0 {
                self.set_status("empty", why);
            } else {
                self.set_status("ready", "");
            }
            return;
        };
        let kind = if selection == BRANCH {
            "branch-range"
        } else {
            "working-tree"
        };
        let none = Obj::new();
        let source = result
            .get("sources")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
            .filter_map(Json::as_object)
            .rfind(|s| text(s, "kind") == kind);
        let found = source.is_some();
        let source = source.unwrap_or(&none);
        text(source, "baseRef").clone_into(&mut self.compared_base);
        text(source, "headRef").clone_into(&mut self.compared_head);
        self.truncated = source.get("truncated").and_then(Json::as_bool) == Some(true);
        let files = source
            .get("files")
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        let diff = text(source, "diff");
        let hash = text(source, "diffHash");
        let key = if found && !hash.is_empty() {
            format!("{kind} {hash} {}", self.truncated)
        } else {
            String::new()
        };
        // The same answer again leaves what the user opened as it is; a
        // file focused or let go meanwhile changes what is shown of it.
        if key.is_empty() || key != self.source_key || self.focus != self.presented {
            self.source_key = key;
            // Cut short with every file counted: each file's changes come
            // when it is opened.
            self.lazy = self.truncated && !files.is_empty();
            self.lazy_kind = kind;
            if self.lazy {
                self.patch.clear();
                self.listing += 1;
                self.diff.set_files(&files);
                self.file_total = self.diff.file_count();
            } else {
                self.patch = without_truncated_marker(diff);
            }
            self.present();
        }
        if self.diff.file_count() > 0 {
            self.set_status("ready", "");
        } else if !found {
            self.set_status("empty", NO_PATCH);
        } else if selection == BRANCH && self.compared_base.is_empty() {
            self.set_status("empty", "This branch has no base to compare against.");
        } else if !diff.trim().is_empty() {
            // Something came back, but no file of it can be shown.
            self.set_status("empty", NO_PATCH);
        } else if selection == BRANCH {
            let why = format!("No changes against {}.", self.compared_base);
            self.set_status("empty", &why);
        } else {
            self.set_status("empty", "No uncommitted changes.");
        }
    }

    /// Puts the loaded patch, or its focused file, in the diff.
    fn present(&mut self) {
        // A review cut short lists every file and shows none alone.
        if self.lazy {
            self.focus.clear();
            self.presented.clear();
            return;
        }
        self.diff.set_patch(&self.patch);
        self.file_total = self.diff.file_count();
        if self.focus.is_empty() {
            self.presented.clear();
            return;
        }
        // The focused file's part of the patch: from its header to the next
        // one.
        let starts: Vec<usize> = FILE_HEADER
            .find_iter(&self.patch)
            .map(|m| m.start())
            .collect();
        match self.diff.file_of(&self.focus) {
            Some(file) if file < starts.len() => {
                let end = starts.get(file + 1).copied().unwrap_or(self.patch.len());
                let part = self.patch[starts[file]..end].to_owned();
                self.diff.set_patch(&part);
                self.diff.set_expanded(0, true);
            }
            _ => self.focus.clear(),
        }
        self.presented.clone_from(&self.focus);
    }

    /// Shows only `path`'s file of the selection; one the selection did not
    /// change leaves every file shown.
    pub fn focus_file(&mut self, path: &str) {
        if path == self.focus {
            return;
        }
        path.clone_into(&mut self.focus);
        if self.status == "ready" {
            self.present();
        }
    }

    pub fn show_all_files(&mut self) {
        self.focus_file("");
    }

    /// Asks the view to scroll to `path`'s file, expanding it; once the
    /// diff is there when it is on its way.
    pub fn reveal_file(&mut self, path: &str) {
        if path.is_empty() {
            return;
        }
        if self.status != "ready" {
            path.clone_into(&mut self.pending_reveal);
            return;
        }
        let Some(file) = self.diff.file_of(path) else {
            return;
        };
        self.diff.set_expanded(file, true);
        if let Some(row) = self.diff.row_of_file(file) {
            self.effects.push(Effect::Reveal(row));
        }
    }

    /// A note on lines `first` to `last` of `path` as the diff shows them
    /// (`side` "old" for removed lines), for the prompt: a review comment
    /// (the composer's `composer.reviewComment.add`). None when the diff
    /// shows no such lines or the note is blank.
    pub fn comment(
        &mut self,
        path: &str,
        side: &str,
        first: i32,
        last: i32,
        note: &str,
    ) -> Option<Json> {
        let note = note.trim();
        if note.is_empty() || self.status != "ready" {
            return None;
        }
        let (first, last) = if last < first {
            (last, first)
        } else {
            (first, last)
        };
        let file = self.diff.file_of(path)?;
        let mut comment = self.diff.excerpt(file, side, first, last);
        let object = comment.as_object_mut()?;
        if object.is_empty() {
            return None;
        }
        // What is being reviewed, as the picker names it.
        let selection = self.effective_selection();
        let section = self
            .choices()
            .into_iter()
            .find(|(value, _)| *value == selection)
            .map_or_else(|| "Diff".to_owned(), |(_, label)| label);
        object.insert("sectionTitle".into(), json!(section));
        object.insert("sectionId".into(), json!(format!("diff:{selection}")));
        object.insert("filePath".into(), json!(path));
        object.insert("lineStart".into(), json!(first));
        object.insert("lineEnd".into(), json!(last));
        object.insert("text".into(), json!(note));
        Some(comment)
    }

    /// A turn can be reverted to: the thread is not working and has a
    /// checkpoint.
    pub fn can_revert(&self) -> bool {
        !self.turns.is_empty() && !self.reverting && !(self.timeline && self.working)
    }

    /// The turn the user is asked to confirm reverting to, or 0.
    pub fn revert_turn(&self) -> i32 {
        self.revert_turn
    }

    pub fn reverting(&self) -> bool {
        self.reverting
    }

    /// Asks to revert to the checkpoint after `turn` (0: the turn shown, or
    /// the latest).
    pub fn request_revert(&mut self, turn: i32) {
        let turn = if turn > 0 {
            turn
        } else if self.shown_turn() > 0 {
            self.shown_turn()
        } else {
            self.latest_turn()
        };
        if self.can_revert() && self.turns.contains_key(&turn) {
            self.revert_turn = turn;
        }
    }

    pub fn cancel_revert(&mut self) {
        self.revert_turn = 0;
    }

    pub fn confirm_revert(&mut self, restore_files: bool) {
        let turn = std::mem::take(&mut self.revert_turn);
        if turn == 0 || !self.can_revert() {
            return;
        }
        let Some(checkpoint) = self.turns.get(&turn) else {
            return;
        };
        let command = json!({
            "type": "checkpoint.rollback",
            "threadId": self.thread,
            "checkpointId": checkpoint.get("id").cloned().unwrap_or(Json::Null),
            "scopeId": checkpoint.get("scopeId").cloned().unwrap_or(Json::Null),
            "restoreFiles": restore_files,
        });
        self.reverting = true;
        self.effects.push(Effect::Dispatch {
            environment: self.environment.clone(),
            command,
            then: Then::Revert {
                turn,
                thread: self.thread.clone(),
            },
        });
    }

    /// A diff path as the thread's workspace has it: the diff's paths are
    /// the repository's, and the shell knows no folder of the project
    /// inside its repository yet, so every path is the workspace's.
    pub fn workspace_path<'a>(&self, path: &'a str) -> &'a str {
        path
    }

    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
    }
}

impl RowSource for DiffTab {
    fn roles(&self) -> &'static [&'static str] {
        self.diff.roles()
    }

    fn row_count(&self) -> usize {
        self.diff.row_count()
    }

    fn row_key(&self, row: usize) -> RowKey {
        self.diff.row_key(row)
    }

    fn data(&self, row: usize, role: &str) -> Value {
        self.diff.data(row, role)
    }

    fn take_changes(&mut self) -> Vec<RowChange> {
        self.diff.take_changes()
    }
}

impl AsDiff for DiffTab {
    fn diff(&self) -> &Diff {
        &self.diff
    }

    fn diff_mut(&mut self) -> &mut Diff {
        &mut self.diff
    }
}

/// A toast: type, title, description.
pub type Notify = Rc<dyn Fn(&Engine, &str, &str, &str)>;

struct Inner {
    rows: Rc<ListRows<DiffTab>>,
    mc: Rc<dyn Mc>,
    notify: Notify,
    model: Cell<Option<ObjectId>>,
    /// The thread shown: environment, thread, its timeline.
    shown: RefCell<(String, String, Option<ObjectId>)>,
    /// The timelines followed: observers stay, so each is followed once
    /// and heard only while it is the one shown.
    observed: RefCell<HashSet<ObjectId>>,
    /// What the agent last did to the shown thread's checkout
    /// ([`workspace_mutation`]).
    mutation: RefCell<String>,
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ThreadDiff")
            .field("rows", &self.rows)
            .finish_non_exhaustive()
    }
}

/// The Diff tab QML binds: `model` is its rows; the properties below.
/// Each of the C++ class's grouped signals is here too, for whoever
/// connects to one (RightPanelController opens the panel on turnsChanged).
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "ThreadDiff", uncreatable)]
pub struct ThreadDiff {
    #[qml(readonly, notify)]
    model: Value,
    /// `[{value, label}]` for the picker: the latest turn, all changes,
    /// then each finished turn, newest first; the checkout's after.
    #[qml(readonly, notify)]
    choices: Value,
    #[qml(readonly, notify)]
    latest_turn: i32,
    /// -1 the latest turn, 0 all changes, a turn, -2 the working tree, -3
    /// the branch: `select()` it.
    #[qml(readonly, notify)]
    selection: i32,
    /// The turn shown (0: all changes).
    #[qml(readonly, notify)]
    shown_turn: i32,
    #[qml(readonly, notify)]
    reviewing: bool,
    #[qml(readonly, notify)]
    status: Atom,
    #[qml(readonly, notify)]
    message: Atom,
    /// The one file shown of the selection's `fileTotal`, or empty for all.
    #[qml(readonly, notify)]
    focus_path: Atom,
    #[qml(readonly, notify)]
    file_total: i32,
    /// QML writes it.
    #[qml(notify)]
    base_ref: Atom,
    #[qml(readonly, notify)]
    compared_base: Atom,
    #[qml(readonly, notify)]
    compared_head: Atom,
    /// `[{id, label, ref, remoteOnly}]`: [`DiffTab::base_choices`].
    #[qml(readonly, notify)]
    base_choices: Value,
    /// QML writes it.
    #[qml(notify)]
    base_query: Atom,
    #[qml(readonly, notify)]
    bases_loading: bool,
    #[qml(readonly, notify)]
    truncated: bool,
    /// QML writes it.
    #[qml(notify)]
    ignore_whitespace: bool,
    /// QML writes it.
    #[qml(notify)]
    wrap: bool,
    #[qml(readonly, notify)]
    can_revert: bool,
    #[qml(readonly, notify)]
    revert_turn: i32,
    #[qml(readonly, notify)]
    reverting: bool,
    #[qml(skip)]
    inner: Rc<Inner>,
}

fn inner_of(engine: &Engine, obj: ObjectId) -> Option<Rc<Inner>> {
    engine.with::<ThreadDiff, _>(obj, |d| d.inner.clone()).ok()
}

fn checkpoints_of(engine: &Engine, timeline: ObjectId) -> Option<(Vec<Obj>, bool)> {
    TimelineModel::read(engine, timeline, |t| {
        let runs = t.entities("run");
        // A checkpoint counts as a diff turn only for a completed run, as the
        // MC counts getTurnDiff's turns; a run the timeline does not hold is
        // not evidence against it.
        let counted = t
            .entities("checkpoint")
            .values()
            .filter(|c| {
                runs.get(text(c, "runId"))
                    .is_none_or(|run| text(run, "status") == "completed")
            })
            .cloned()
            .collect();
        (counted, t.working())
    })
}

/// The agent's last finished command or file change and every checkpoint's
/// status: when it changes, the checkout may have.
pub(super) fn mutation_of(t: &Timeline) -> String {
    let mut item = "";
    let mut ordinal = -1.0;
    for (id, entry) in t.entities("turn-item") {
        if !matches!(text(entry, "type"), "command_execution" | "file_change")
            || matches!(text(entry, "status"), "pending" | "running" | "waiting")
        {
            continue;
        }
        let at = entry.get("ordinal").and_then(Json::as_f64).unwrap_or(0.0);
        if at > ordinal {
            ordinal = at;
            item = id;
        }
    }
    let mut checkpoints: Vec<String> = t
        .entities("checkpoint")
        .iter()
        .map(|(id, c)| format!("{id}={}", text(c, "status")))
        .collect();
    checkpoints.sort();
    format!("{item}\n{}", checkpoints.join(","))
}

/// [`mutation_of`] the timeline shown; empty without one.
fn workspace_mutation(engine: &Engine, timeline: Option<ObjectId>) -> String {
    timeline
        .and_then(|timeline| TimelineModel::read(engine, timeline, mutation_of))
        .unwrap_or_default()
}

impl ThreadDiff {
    /// The Diff tab owned by `owner`, asking `mc`; `notify` raises a toast
    /// (type, title, description).
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        mc: Rc<dyn Mc>,
        notify: impl Fn(&Engine, &str, &str, &str) + 'static,
    ) -> Result<ObjectId, EngineError> {
        let rows = ListRows::new(DiffTab::new());
        let inner = Rc::new(Inner {
            rows: rows.clone(),
            mc,
            notify: Rc::new(notify),
            model: Cell::new(None),
            shown: RefCell::default(),
            observed: RefCell::default(),
            mutation: RefCell::default(),
        });
        let tab = ThreadDiff {
            model: Value::Null,
            choices: Value::Undefined,
            latest_turn: 0,
            selection: -1,
            shown_turn: 0,
            reviewing: false,
            status: Atom::new("idle"),
            message: Atom::new(""),
            focus_path: Atom::new(""),
            file_total: 0,
            base_ref: Atom::new(""),
            compared_base: Atom::new(""),
            compared_head: Atom::new(""),
            base_choices: Value::Undefined,
            base_query: Atom::new(""),
            bases_loading: false,
            truncated: false,
            ignore_whitespace: true,
            wrap: false,
            can_revert: false,
            revert_turn: 0,
            reverting: false,
            inner: inner.clone(),
        };
        let obj = engine.create_native(tab, owner)?;
        let model = DiffModel::create_over(engine, Some(obj), rows)?;
        inner.model.set(Some(model));
        engine.set_internal(obj, ThreadDiff::MODEL, Value::Object(model))?;
        let facts = inner.rows.read(DiffTab::facts);
        write(engine, obj, &facts);
        write_bases(engine, obj, &inner);
        // What QML writes goes through the tab, which may keep it as it
        // was (or trimmed).
        engine.connect_by_name(obj, "baseRefChanged", move |engine, _| {
            if let Ok(base) = engine.get(obj, ThreadDiff::BASE_REF) {
                let kept = ThreadDiff::update(engine, obj, |t| {
                    t.set_base_ref(&base);
                    t.base_ref().to_owned()
                });
                // " main " for "main" changes nothing but is still trimmed.
                if let Some(kept) = kept.filter(|kept| **kept != *base) {
                    let set = engine.set_internal(obj, ThreadDiff::BASE_REF, Atom::new(&kept));
                    warn(engine, set);
                }
            }
        })?;
        engine.connect_by_name(obj, "baseQueryChanged", move |engine, _| {
            if let Ok(query) = engine.get(obj, ThreadDiff::BASE_QUERY) {
                ThreadDiff::update(engine, obj, |t| t.set_base_query(&query));
            }
        })?;
        // A file opened without its changes asks for them.
        engine.connect_by_name(model, "fileWanted", move |engine, args| {
            let file = match args.first() {
                Some(Value::Int(i)) => usize::try_from(*i).ok(),
                _ => None,
            };
            if let Some(file) = file {
                ThreadDiff::update(engine, obj, |t| t.load_file(file));
            }
        })?;
        engine.connect_by_name(obj, "ignoreWhitespaceChanged", move |engine, _| {
            if let Ok(ignore) = engine.get(obj, ThreadDiff::IGNORE_WHITESPACE) {
                ThreadDiff::update(engine, obj, |t| t.set_ignore_whitespace(ignore));
            }
        })?;
        engine.connect_by_name(obj, "wrapChanged", move |engine, _| {
            if let Ok(wrap) = engine.get(obj, ThreadDiff::WRAP) {
                ThreadDiff::update(engine, obj, |t| t.set_wrap(wrap));
            }
        })?;
        Ok(obj)
    }

    /// The model of the tab's rows.
    pub fn model(engine: &Engine, obj: ObjectId) -> Option<ObjectId> {
        inner_of(engine, obj)?.model.get()
    }

    /// The thread shown, its timeline (for its checkpoints, whether it is
    /// working and what the agent does to the checkout; it may come later
    /// than the thread) and its checkout. The right panel passes these, and
    /// whether the tab shows and the whitespace and wrap settings through
    /// `update`.
    pub fn set_thread(
        engine: &Engine,
        obj: ObjectId,
        environment: &str,
        thread: &str,
        timeline: Option<ObjectId>,
        cwd: &str,
    ) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        let next = (environment.to_owned(), thread.to_owned(), timeline);
        if *inner.shown.borrow() == next {
            ThreadDiff::update(engine, obj, |t| t.set_checkout(cwd));
            return;
        }
        *inner.shown.borrow_mut() = next;
        *inner.mutation.borrow_mut() = workspace_mutation(engine, timeline);
        if let Some(timeline) = timeline
            && inner.observed.borrow_mut().insert(timeline)
        {
            TimelineModel::observe(engine, timeline, move |engine, out| {
                let Some(inner) = inner_of(engine, obj) else {
                    return;
                };
                if inner.shown.borrow().2 != Some(timeline) {
                    return;
                }
                match out {
                    Out::CheckpointsChanged => {
                        let (checkpoints, _) = checkpoints_of(engine, timeline).unwrap_or_default();
                        ThreadDiff::update(engine, obj, |t| t.set_checkpoints(checkpoints));
                    }
                    Out::WorkingChanged => {
                        let working = checkpoints_of(engine, timeline).is_some_and(|(_, w)| w);
                        ThreadDiff::update(engine, obj, |t| t.set_working(working));
                    }
                    Out::WorkspaceChanged => {
                        let now = workspace_mutation(engine, Some(timeline));
                        if now != std::mem::replace(&mut *inner.mutation.borrow_mut(), now.clone())
                        {
                            ThreadDiff::update(engine, obj, DiffTab::follow);
                        }
                    }
                    _ => {}
                }
            });
        }
        let facts = timeline.and_then(|timeline| checkpoints_of(engine, timeline));
        ThreadDiff::update(engine, obj, |t| {
            t.set_thread(environment, thread, facts, cwd)
        });
    }

    /// Runs `f` on the tab of `obj`, then tells the views and the
    /// properties what it changed and asks the MC what it said to. None when
    /// `obj` is not live.
    pub fn update<R>(
        engine: &Engine,
        obj: ObjectId,
        f: impl FnOnce(&mut DiffTab) -> R,
    ) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let (before, result, after, effects) = inner.rows.update(engine, |t| {
            let before = t.facts();
            let result = f(t);
            (before, result, t.facts(), t.take_effects())
        });
        if let Some(model) = inner.model.get() {
            DiffModel::sync(engine, model);
        }
        let signals = after.signals(&before);
        if !signals.is_empty() {
            write(engine, obj, &after);
        }
        if signals.contains(&Signal::Bases) {
            write_bases(engine, obj, &inner);
        }
        let cx = Cx::new(engine, obj);
        let told = signals.iter().try_for_each(|signal| match signal {
            Signal::Turns => ThreadDiff::emit_turns_changed(&cx),
            Signal::Review => ThreadDiff::emit_review_changed(&cx),
            Signal::Revert => ThreadDiff::emit_revert_changed(&cx),
            Signal::Options => ThreadDiff::emit_options_changed(&cx),
            Signal::Focus => ThreadDiff::emit_focus_changed(&cx),
            Signal::Bases => ThreadDiff::emit_bases_changed(&cx),
            // The properties' own signals.
            Signal::Selection | Signal::Status => Ok(()),
        });
        warn(engine, told);
        for effect in effects {
            run(engine, obj, &inner, effect);
        }
        Some(result)
    }

    /// Reads the tab of `obj`. `f` must not call back into it.
    pub fn read<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&DiffTab) -> R) -> Option<R> {
        Some(inner_of(engine, obj)?.rows.read(f))
    }
}

fn warn(engine: &Engine, result: Result<(), EngineError>) {
    if let Err(e) = result {
        engine.log(
            ljos::prelude::LogLevel::Warning,
            "ThreadDiff",
            e.to_string(),
        );
    }
}

/// Writes the base picker's properties.
fn write_bases(engine: &Engine, obj: ObjectId, inner: &Inner) {
    let (choices, query, loading) = inner.rows.read(|t| {
        (
            t.base_choices(),
            t.base_query().to_owned(),
            t.bases_loading(),
        )
    });
    let result = engine
        .set_internal(
            obj,
            ThreadDiff::BASE_CHOICES,
            Json::Array(choices).to_value(),
        )
        .and_then(|()| engine.set_internal(obj, ThreadDiff::BASE_QUERY, Atom::new(&query)))
        .and_then(|()| engine.set_internal(obj, ThreadDiff::BASES_LOADING, loading));
    warn(engine, result);
}

/// Writes the properties; each says so only when it changed.
fn write(engine: &Engine, obj: ObjectId, facts: &Facts) {
    let choices: Vec<Json> = facts
        .choices
        .iter()
        .map(|(value, label)| json!({"value": value, "label": label}))
        .collect();
    let choices = Json::Array(choices).to_value();
    let atom = |s: &str| Atom::new(s);
    let result = engine
        .set_internal(obj, ThreadDiff::CHOICES, choices)
        .and_then(|()| engine.set_internal(obj, ThreadDiff::LATEST_TURN, facts.latest_turn))
        .and_then(|()| engine.set_internal(obj, ThreadDiff::SELECTION, facts.selection))
        .and_then(|()| engine.set_internal(obj, ThreadDiff::SHOWN_TURN, facts.shown_turn))
        .and_then(|()| engine.set_internal(obj, ThreadDiff::REVIEWING, facts.reviewing))
        .and_then(|()| engine.set_internal(obj, ThreadDiff::STATUS, atom(facts.status)))
        .and_then(|()| engine.set_internal(obj, ThreadDiff::MESSAGE, atom(&facts.message)))
        .and_then(|()| engine.set_internal(obj, ThreadDiff::FOCUS_PATH, atom(&facts.focus)))
        .and_then(|()| engine.set_internal(obj, ThreadDiff::FILE_TOTAL, int(facts.file_total)))
        .and_then(|()| engine.set_internal(obj, ThreadDiff::BASE_REF, atom(&facts.base_ref)))
        .and_then(|()| {
            engine.set_internal(obj, ThreadDiff::COMPARED_BASE, atom(&facts.compared_base))
        })
        .and_then(|()| {
            engine.set_internal(obj, ThreadDiff::COMPARED_HEAD, atom(&facts.compared_head))
        })
        .and_then(|()| engine.set_internal(obj, ThreadDiff::TRUNCATED, facts.truncated))
        .and_then(|()| {
            engine.set_internal(obj, ThreadDiff::IGNORE_WHITESPACE, facts.ignore_whitespace)
        })
        .and_then(|()| engine.set_internal(obj, ThreadDiff::WRAP, facts.wrap))
        .and_then(|()| engine.set_internal(obj, ThreadDiff::CAN_REVERT, facts.can_revert))
        .and_then(|()| engine.set_internal(obj, ThreadDiff::REVERT_TURN, facts.revert_turn))
        .and_then(|()| engine.set_internal(obj, ThreadDiff::REVERTING, facts.reverting));
    warn(engine, result);
}

fn run(engine: &Engine, obj: ObjectId, inner: &Inner, effect: Effect) {
    let reply = move |then: Then| -> crate::mc::Reply {
        Box::new(move |engine, result: Result<Json, McError>| {
            let result = result.map_err(|e| e.message);
            ThreadDiff::update(engine, obj, |t| t.answer(then, result));
        })
    };
    match effect {
        Effect::Call {
            environment,
            method,
            payload,
            then,
        } => inner.mc.call(&environment, method, payload, reply(then)),
        Effect::Dispatch {
            environment,
            command,
            then,
        } => inner
            .mc
            .dispatch_command(&environment, command, reply(then)),
        Effect::Notify {
            kind,
            title,
            description,
        } => (inner.notify)(engine, kind, &title, &description),
        Effect::Reveal(row) => warn(
            engine,
            ThreadDiff::emit_reveal_row(&Cx::new(engine, obj), int(row)),
        ),
    }
}

#[qml_impl]
impl ThreadDiff {
    #[qml(signal)]
    fn turns_changed();
    #[qml(signal)]
    fn focus_changed();
    #[qml(signal)]
    fn review_changed();
    #[qml(signal)]
    fn revert_changed();
    #[qml(signal)]
    fn options_changed();
    /// baseChoices, baseQuery or basesLoading changed.
    #[qml(signal)]
    fn bases_changed();
    /// A review comment for the composer (`composer.reviewComment.add`).
    #[qml(signal)]
    fn comment_requested(comment: Value);
    /// The view should show `row` of the model at its top.
    #[qml(signal)]
    fn reveal_row(row: i32);

    #[qml(invokable)]
    fn select(cx: &Cx, selection: i32) {
        ThreadDiff::update(cx.engine, cx.this, |t| t.select(selection));
    }

    /// Selects the turn the run (a turn id) finished.
    #[qml(invokable)]
    fn select_run(cx: &Cx, run_id: Atom) {
        ThreadDiff::update(cx.engine, cx.this, |t| t.select_run(&run_id));
    }

    #[qml(invokable)]
    fn reload(cx: &Cx) {
        ThreadDiff::update(cx.engine, cx.this, DiffTab::reload);
    }

    /// Asks the checkout for its refs again (the base picker opening).
    #[qml(invokable)]
    fn load_bases(cx: &Cx) {
        ThreadDiff::update(cx.engine, cx.this, DiffTab::load_bases);
    }

    /// Compares against the choice `id` of baseChoices.
    #[qml(invokable)]
    fn choose_base(cx: &Cx, id: Atom) {
        ThreadDiff::update(cx.engine, cx.this, |t| t.choose_base(&id));
    }

    /// What the user typed: the choice labelled so, else the ref as typed.
    #[qml(invokable)]
    fn choose_typed_base(cx: &Cx, text: Atom) {
        ThreadDiff::update(cx.engine, cx.this, |t| t.choose_typed_base(&text));
    }

    /// Loads one file's changes of a review cut short again.
    #[qml(invokable)]
    fn retry_file(cx: &Cx, path: Atom) {
        ThreadDiff::update(cx.engine, cx.this, |t| t.retry_file(&path));
    }

    /// A diff path as the thread's workspace has it, or empty for a file
    /// outside it.
    #[qml(invokable)]
    fn workspace_path(cx: &Cx, path: Atom) -> String {
        ThreadDiff::read(cx.engine, cx.this, |t| t.workspace_path(&path).to_owned())
            .unwrap_or_default()
    }

    /// Scrolls the view to `path`'s file, expanding it.
    #[qml(invokable)]
    fn reveal_file(cx: &Cx, path: Atom) {
        ThreadDiff::update(cx.engine, cx.this, |t| t.reveal_file(&path));
    }

    #[qml(invokable)]
    fn focus_file(cx: &Cx, path: Atom) {
        ThreadDiff::update(cx.engine, cx.this, |t| t.focus_file(&path));
    }

    #[qml(invokable)]
    fn show_all_files(cx: &Cx) {
        ThreadDiff::update(cx.engine, cx.this, DiffTab::show_all_files);
    }

    /// A note on lines `first` to `last` of `path`: commentRequested
    /// carries it. False when the diff shows no such lines or the note is
    /// blank.
    #[qml(invokable)]
    fn comment(cx: &Cx, path: Atom, side: Atom, first: i32, last: i32, note: Atom) -> bool {
        let comment = ThreadDiff::update(cx.engine, cx.this, |t| {
            t.comment(&path, &side, first, last, &note)
        })
        .flatten();
        let Some(comment) = comment else {
            return false;
        };
        let value = comment.to_value();
        warn(cx.engine, ThreadDiff::emit_comment_requested(cx, value));
        true
    }

    /// Asks to revert to the checkpoint after `turn` (0: the turn shown, or
    /// the latest).
    #[qml(invokable)]
    fn request_revert(cx: &Cx, turn: i32) {
        ThreadDiff::update(cx.engine, cx.this, |t| t.request_revert(turn));
    }

    #[qml(invokable)]
    fn confirm_revert(cx: &Cx, restore_files: bool) {
        ThreadDiff::update(cx.engine, cx.this, |t| t.confirm_revert(restore_files));
    }

    #[qml(invokable)]
    fn cancel_revert(cx: &Cx) {
        ThreadDiff::update(cx.engine, cx.this, DiffTab::cancel_revert);
    }
}

#[cfg(test)]
#[path = "thread_diff_tests.rs"]
mod tests;
