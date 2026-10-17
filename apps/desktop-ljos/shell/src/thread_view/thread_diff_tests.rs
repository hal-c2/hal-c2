//! ThreadDiff's core: tst_WorkspaceDiffRegression's ThreadDiff cases, the
//! comment and revert flows, and tst_WorkspaceThreadDiffProp's state
//! machine against an MC that answers in any order.

use std::collections::BTreeMap;

use proptest::prelude::*;
use serde_json::json;

use super::super::rows::Mirror;
use super::super::summary::Obj;
use super::super::timeline::{Out, Timeline};
use super::{BRANCH, DiffTab, Effect, Json, Signal, Then, WORKING_TREE};

const ENV: &str = "env-a";

fn obj(value: Json) -> Obj {
    match value {
        Json::Object(object) => object,
        _ => panic!("an object"),
    }
}

/// A finished turn's checkpoint as the stream has it.
fn checkpoint(id: &str, turn: i32, status: &str, files: usize) -> Obj {
    let files: Vec<Json> = (0..files)
        .map(|i| json!({"path": format!("f{i}.txt"), "additions": 1, "deletions": 1}))
        .collect();
    obj(json!({"id": id, "appRunOrdinal": turn, "status": status, "files": files}))
}

fn patch_of<S: AsRef<str>>(files: &[S]) -> String {
    files
        .iter()
        .map(|f| {
            let f = f.as_ref();
            format!("diff --git a/{f} b/{f}\n--- a/{f}\n+++ b/{f}\n@@ -1 +1 @@\n-old\n+new\n")
        })
        .collect()
}

/// The calls the tab made since last asked.
fn asked(tab: &mut DiffTab) -> Vec<(&'static str, Json, Then)> {
    tab.take_effects()
        .into_iter()
        .filter_map(|effect| match effect {
            Effect::Call {
                method,
                payload,
                then,
                ..
            } => Some((method, payload, then)),
            _ => None,
        })
        .collect()
}

fn only(tab: &mut DiffTab) -> (&'static str, Json, Then) {
    let mut calls = asked(tab);
    assert_eq!(calls.len(), 1, "one call: {calls:?}");
    calls.remove(0)
}

fn diff(files: &[&str]) -> Result<Json, String> {
    Ok(json!({"diff": patch_of(files)}))
}

/// t1's tab, shown, its timeline holding `checkpoints`.
fn shown(checkpoints: Vec<Obj>) -> DiffTab {
    let mut tab = DiffTab::new();
    tab.set_active(true);
    tab.set_thread(ENV, "t1", Some((checkpoints, false)));
    tab
}

fn ready(id: &str, turn: i32) -> Obj {
    checkpoint(id, turn, "ready", 0)
}

#[test]
fn a_late_file_summary_says_turns_changed() {
    let mut tab = shown(vec![ready("cp-1", 1)]);
    let (_, _, then) = only(&mut tab);
    tab.answer(then, diff(&["a.txt"]));
    let before = tab.facts();
    tab.set_checkpoints(vec![checkpoint("cp-1", 1, "ready", 2)]);
    assert_eq!(tab.facts().signals(&before), [Signal::Turns]);
    assert_eq!(
        tab.latest_checkpoint()["files"].as_array().map(Vec::len),
        Some(2)
    );
    // The same diff is not asked for again.
    assert!(asked(&mut tab).is_empty());
}

#[test]
fn a_turn_is_diffed_again_when_the_turn_before_it_is_ready() {
    let mut tab = shown(vec![checkpoint("cp-1", 1, "pending", 0), ready("cp-2", 2)]);
    let (method, payload, then) = only(&mut tab);
    assert_eq!(method, "orchestration.getTurnDiff");
    assert_eq!(
        payload,
        json!({"threadId": "t1", "ignoreWhitespace": true, "fromTurnCount": 1, "toTurnCount": 2})
    );
    tab.answer(then, diff(&["a.txt"]));
    assert_eq!(tab.status(), "ready");
    tab.set_checkpoints(vec![ready("cp-1", 1), ready("cp-2", 2)]);
    let (method, payload, _) = only(&mut tab);
    assert_eq!(method, "orchestration.getTurnDiff");
    assert_eq!(payload["toTurnCount"], 2);
}

#[test]
fn a_rewound_turns_diff_is_not_shown_for_the_turn_that_took_its_number() {
    let mut tab = shown(vec![ready("cp-1", 1), ready("cp-2", 2)]);
    let (_, _, old) = only(&mut tab);
    tab.set_checkpoints(vec![
        ready("cp-1", 1),
        checkpoint("cp-2", 2, "stale", 0),
        ready("cp-3", 2),
    ]);
    let (_, payload, new) = only(&mut tab);
    assert_eq!(payload["toTurnCount"], 2);
    tab.answer(old, diff(&["old.txt"]));
    assert_eq!(tab.status(), "loading");
    assert!(tab.diff().paths().is_empty());
    tab.answer(new, diff(&["new.txt"]));
    assert_eq!(tab.diff().paths(), ["new.txt"]);
}

#[test]
fn all_changes_is_not_selected_without_a_turn() {
    let mut tab = shown(Vec::new());
    tab.select(0);
    assert_eq!(tab.selection(), -1);
    assert_eq!(
        (tab.status(), tab.message()),
        ("empty", "No completed turns yet.")
    );
    tab.set_checkpoints(vec![ready("cp-1", 1)]);
    tab.select(0);
    assert_eq!(tab.selection(), 0);
    let (method, payload, _) = asked(&mut tab).pop().expect("all changes are asked for");
    assert_eq!(method, "orchestration.getFullThreadDiff");
    assert_eq!(payload["toTurnCount"], 1);
    // The turn is rewound: all changes go with it.
    tab.set_checkpoints(vec![checkpoint("cp-1", 1, "stale", 0)]);
    assert_eq!(tab.selection(), -1);
    assert!(tab.choices().is_empty());
}

#[test]
fn the_branch_is_not_selected_without_a_checkout() {
    let mut tab = shown(vec![ready("cp-1", 1)]);
    asked(&mut tab);
    for selection in [BRANCH, WORKING_TREE, -4] {
        tab.select(selection);
        assert_eq!(tab.selection(), -1);
    }
    tab.set_checkout("/c");
    tab.select(BRANCH);
    assert_eq!(tab.selection(), BRANCH);
    assert!(tab.reviewing());
    assert_eq!(tab.shown_turn(), 0);
    let (method, payload, _) = only(&mut tab);
    assert_eq!(method, "review.getDiffPreview");
    assert_eq!(payload, json!({"cwd": "/c", "ignoreWhitespace": true}));
    tab.set_base_ref(" dev ");
    assert_eq!(tab.base_ref(), "dev");
    let (_, payload, _) = only(&mut tab);
    assert_eq!(payload["baseRef"], "dev");
    tab.set_checkout("");
    assert_eq!(tab.selection(), -1);
    assert!(!tab.reviewing());
}

#[test]
fn a_timeline_that_comes_back_loads_again() {
    let mut tab = shown(vec![ready("cp-1", 1)]);
    let (_, _, then) = only(&mut tab);
    tab.answer(then, diff(&["a.txt"]));
    tab.set_thread(ENV, "t1", None);
    assert_eq!(
        (tab.status(), tab.message()),
        ("loading", "Loading checkpoint diff...")
    );
    assert!(asked(&mut tab).is_empty());
    tab.set_thread(ENV, "t1", Some((vec![ready("cp-1", 1)], false)));
    let (method, _, then) = only(&mut tab);
    assert_eq!(method, "orchestration.getTurnDiff");
    tab.answer(then, diff(&["a.txt"]));
    assert_eq!(tab.status(), "ready");
}

#[test]
fn another_thread_forgets_the_compared_refs() {
    let mut tab = shown(Vec::new());
    tab.set_checkout("/c");
    // A thread with no turn opens on the working tree.
    assert!(tab.reviewing());
    asked(&mut tab);
    tab.select(BRANCH);
    let (_, _, then) = only(&mut tab);
    let source = json!({"kind": "branch-range", "diff": patch_of(&["a.txt"]), "baseRef": "main", "headRef": "feature", "truncated": true});
    tab.answer(then, Ok(json!({"sources": [source]})));
    assert_eq!(
        (tab.compared_base(), tab.compared_head(), tab.truncated()),
        ("main", "feature", true)
    );
    let before = tab.facts();
    tab.set_thread(ENV, "t2", Some((Vec::new(), false)));
    assert!(tab.facts().signals(&before).contains(&Signal::Review));
    assert_eq!(
        (tab.compared_base(), tab.compared_head(), tab.truncated()),
        ("", "", false)
    );
}

#[test]
fn a_branch_with_nothing_to_compare_says_why() {
    let mut tab = shown(Vec::new());
    tab.set_checkout("/c");
    tab.select(BRANCH);
    let (_, _, then) = asked(&mut tab).pop().expect("the branch is asked for");
    let source = json!({"kind": "branch-range", "diff": ""});
    tab.answer(then, Ok(json!({"sources": [source]})));
    assert_eq!(
        (tab.status(), tab.message()),
        ("empty", "This branch has no base to compare against.")
    );
    tab.set_base_ref("main");
    let (_, _, then) = only(&mut tab);
    let source = json!({"kind": "branch-range", "diff": "", "baseRef": "main"});
    tab.answer(then, Ok(json!({"sources": [source]})));
    assert_eq!(tab.message(), "No changes against main.");
    tab.select(WORKING_TREE);
    let (_, _, then) = only(&mut tab);
    tab.answer(then, Ok(json!({"sources": [source]})));
    assert_eq!(tab.message(), "No uncommitted changes.");
}

#[test]
fn picking_the_same_diff_shows_all_its_files() {
    let mut tab = shown(vec![ready("cp-1", 1), ready("cp-2", 2)]);
    let (_, _, then) = only(&mut tab);
    tab.answer(then, diff(&["a.txt", "two.txt"]));
    tab.focus_file("two.txt");
    assert_eq!(tab.diff().paths(), ["two.txt"]);
    assert_eq!(tab.file_total(), 2);
    // Turn 2 is the latest turn: the same diff, shown whole.
    tab.select(2);
    assert!(asked(&mut tab).is_empty());
    assert_eq!(tab.focus_path(), "");
    assert_eq!(tab.diff().paths(), ["a.txt", "two.txt"]);
    // A file the selection did not change shows every file.
    tab.focus_file("gone.txt");
    assert_eq!(tab.focus_path(), "");
    assert_eq!(tab.diff().paths(), ["a.txt", "two.txt"]);
}

#[test]
fn another_thread_in_the_same_state_changes_nothing() {
    let mut tab = shown(Vec::new());
    assert_eq!(tab.status(), "empty");
    let before = tab.facts();
    tab.set_thread(ENV, "t2", Some((Vec::new(), false)));
    assert_eq!(tab.facts().signals(&before), []);
}

#[test]
fn a_failed_diff_says_why_and_is_asked_again() {
    let mut tab = shown(vec![ready("cp-1", 1)]);
    let (_, _, then) = only(&mut tab);
    tab.answer(then, Err(String::new()));
    assert_eq!(
        (tab.status(), tab.message()),
        ("error", "Could not load the diff.")
    );
    tab.reload();
    let (_, _, then) = only(&mut tab);
    tab.answer(then, Err("Turn 1 has no checkpoint.".into()));
    assert_eq!(tab.message(), "Turn 1 has no checkpoint.");
    // Unchanged checkpoints ask again too.
    tab.set_checkpoints(vec![ready("cp-1", 1)]);
    let (_, _, then) = only(&mut tab);
    tab.answer(then, diff(&[]));
    assert_eq!(
        (tab.status(), tab.message()),
        ("empty", "No net changes in this selection.")
    );
}

#[test]
fn a_hidden_tab_loads_when_shown() {
    let mut tab = DiffTab::new();
    tab.set_thread(ENV, "t1", Some((vec![ready("cp-1", 1)], false)));
    tab.set_ignore_whitespace(false);
    assert!(asked(&mut tab).is_empty());
    assert_eq!(tab.status(), "idle");
    tab.set_active(true);
    let (_, payload, _) = only(&mut tab);
    assert_eq!(payload["ignoreWhitespace"], false);
    // The setting no longer decides once the user chose here.
    tab.set_default_ignore_whitespace(true);
    assert!(!tab.ignore_whitespace());
    assert!(asked(&mut tab).is_empty());
}

#[test]
fn whitespace_and_wrap_follow_the_settings_until_chosen() {
    let mut tab = shown(vec![ready("cp-1", 1)]);
    asked(&mut tab);
    tab.set_default_ignore_whitespace(false);
    let (_, payload, _) = only(&mut tab);
    assert_eq!(payload["ignoreWhitespace"], false);
    assert!(!tab.wrap());
    tab.set_default_wrap(true);
    assert!(tab.wrap());
    tab.set_wrap(false);
    tab.set_default_wrap(true);
    assert!(!tab.wrap());
    assert!(asked(&mut tab).is_empty());
}

#[test]
fn a_reveal_waits_for_the_diff() {
    let mut tab = shown(vec![ready("cp-1", 1)]);
    let (_, _, then) = only(&mut tab);
    tab.reveal_file("b.txt");
    tab.answer(then, diff(&["a.txt", "b.txt"]));
    let reveals: Vec<Effect> = tab
        .take_effects()
        .into_iter()
        .filter(|e| matches!(e, Effect::Reveal(_)))
        .collect();
    let row = tab.diff().row_of_file(1).expect("b.txt has rows");
    assert_eq!(reveals, [Effect::Reveal(row)]);
    tab.reveal_file("nope.txt");
    assert!(tab.take_effects().is_empty());
}

#[test]
fn a_comment_names_what_is_reviewed_and_the_lines() {
    let mut tab = shown(vec![ready("cp-1", 1)]);
    assert_eq!(tab.comment("a.txt", "new", 1, 1, "why"), None);
    let (_, _, then) = only(&mut tab);
    tab.answer(then, diff(&["a.txt"]));
    assert_eq!(tab.comment("a.txt", "new", 1, 1, "  "), None);
    assert_eq!(tab.comment("a.txt", "new", 7, 9, "why"), None);
    assert_eq!(tab.comment("gone.txt", "new", 1, 1, "why"), None);
    let comment = tab
        .comment("a.txt", "new", 1, 1, " why \n")
        .expect("a comment on a shown line");
    assert_eq!(comment["sectionTitle"], "Latest turn");
    assert_eq!(comment["sectionId"], "diff:-1");
    assert_eq!(comment["filePath"], "a.txt");
    assert_eq!(
        (&comment["lineStart"], &comment["lineEnd"]),
        (&json!(1), &json!(1))
    );
    assert_eq!(comment["text"], "why");
}

#[test]
fn reverting_asks_first_and_says_how_it_went() {
    let mut checkpoints = vec![ready("cp-1", 1), ready("cp-2", 2)];
    checkpoints[0].insert("scopeId".into(), json!("scope-1"));
    let mut tab = shown(checkpoints);
    asked(&mut tab);
    assert!(tab.can_revert());
    tab.request_revert(7);
    assert_eq!(tab.revert_turn(), 0);
    tab.request_revert(0);
    assert_eq!(tab.revert_turn(), 2);
    tab.cancel_revert();
    assert_eq!(tab.revert_turn(), 0);
    tab.request_revert(1);
    tab.confirm_revert(false);
    assert!(tab.reverting() && !tab.can_revert());
    assert_eq!(tab.revert_turn(), 0);
    let Some(Effect::Dispatch {
        environment,
        command,
        then,
    }) = tab.take_effects().pop()
    else {
        panic!("the rollback is dispatched");
    };
    assert_eq!(environment, ENV);
    assert_eq!(
        command,
        json!({"type": "checkpoint.rollback", "threadId": "t1", "checkpointId": "cp-1", "scopeId": "scope-1", "restoreFiles": false})
    );
    tab.answer(then.clone(), Err(String::new()));
    assert!(!tab.reverting());
    assert_eq!(
        tab.take_effects(),
        [Effect::Notify {
            kind: "error",
            title: "Could not revert to turn 1".into(),
            description: "An error occurred.".into(),
        }]
    );
    tab.answer(then, Ok(json!({})));
    assert_eq!(
        tab.take_effects(),
        [Effect::Notify {
            kind: "success",
            title: "Reverted to turn 1.".into(),
            description: String::new(),
        }]
    );
    // Not while the thread works.
    tab.set_working(true);
    assert!(!tab.can_revert());
    tab.request_revert(1);
    assert_eq!(tab.revert_turn(), 0);
}

// --- tst_WorkspaceThreadDiffProp -------------------------------------------------------

const THREADS: [&str; 2] = ["t1", "t2"];
const CHECKOUTS: [&str; 3] = ["", "/c1", "/c2"];
const BASES: [&str; 3] = ["", "main", " dev "];
// Every non-empty diff changes `two.txt`; no diff changes `gone.txt`.
const FOCUS: [&str; 3] = ["", "two.txt", "gone.txt"];

/// A finished turn's checkpoint on the MC.
#[derive(Clone, Debug, PartialEq)]
struct Cp {
    id: String,
    turn: i32,
    /// ready, pending (not written yet) or stale (rewound).
    status: &'static str,
    /// How many files its summary lists; it can come after it is ready.
    files: usize,
}

type Mcs = BTreeMap<String, Vec<Cp>>;

/// Turn number -> the ready checkpoint's id.
fn ready_turns(checkpoints: &[Cp]) -> BTreeMap<i32, String> {
    checkpoints
        .iter()
        .filter(|c| c.status == "ready")
        .map(|c| (c.turn, c.id.clone()))
        .collect()
}

/// What the MC is asked. `selection` only says which source of a review
/// answer the client shows; the MC never sees it.
#[derive(Clone, Debug, Default)]
struct Req {
    method: String,
    thread: String,
    from: i64,
    to: i64,
    whitespace: bool,
    cwd: String,
    base: String,
    selection: i32,
    /// Which of the client's requests it was: only the newest is shown.
    number: u64,
}

impl Req {
    fn asked(&self) -> String {
        format!(
            "{} {} {}..{} ws={} cwd={} base={}",
            self.method, self.thread, self.from, self.to, self.whitespace, self.cwd, self.base
        )
    }
}

#[derive(Debug, Default)]
struct Answer {
    error: Option<String>,
    files: Vec<String>,
    base: String,
    head: String,
    truncated: bool,
}

/// What the MC answers to `req` from the checkpoints it has now.
fn answer_of(req: &Req, mc: &Mcs) -> Answer {
    let ws = if req.whitespace { "-ws" } else { "" };
    if req.method == "review.getDiffPreview" {
        let branch = req.selection == BRANCH;
        let base = if req.base.is_empty() {
            "main".to_owned()
        } else {
            req.base.clone()
        };
        // Nothing uncommitted in /c2, and nothing against an explicit main.
        let empty = if branch {
            req.base == "main"
        } else {
            req.cwd == "/c2"
        };
        let files = if empty {
            Vec::new()
        } else {
            let kind = if branch { "br" } else { "wt" };
            vec![
                format!("{kind}{}-{base}{ws}.txt", &req.cwd[1..]),
                "two.txt".to_owned(),
            ]
        };
        return Answer {
            error: None,
            files,
            base,
            head: "feature".into(),
            truncated: req.cwd == "/c2",
        };
    }
    let turns = ready_turns(mc.get(&req.thread).map_or(&[][..], Vec::as_slice));
    #[allow(clippy::cast_possible_truncation)]
    let (from, to) = (req.from as i32, req.to as i32);
    let Some(to_id) = turns.get(&to) else {
        return Answer {
            error: Some(format!("Turn {to} has no checkpoint.")),
            ..Answer::default()
        };
    };
    // A diff to a checkpoint whose number divides by 3 changed nothing.
    if to_id[3..].parse::<u32>().unwrap_or(0) % 3 == 0 {
        return Answer::default();
    }
    let tag = if req.method == "orchestration.getFullThreadDiff" {
        format!("all-{to_id}")
    } else {
        let from_id = turns.get(&from).cloned().unwrap_or_else(|| {
            if from == 0 {
                "base".into()
            } else {
                "none".into()
            }
        });
        format!("{from_id}_{to_id}")
    };
    Answer {
        files: vec![
            format!("{}-{tag}{ws}.txt", req.thread),
            "two.txt".to_owned(),
        ],
        ..Answer::default()
    }
}

/// What the user should see.
#[derive(Clone, Debug)]
struct Model {
    mc: Mcs,
    serial: u32,
    thread: String,
    timeline: bool,
    active: bool,
    selection: i32,
    cwd: String,
    base: String,
    whitespace: bool,
    status: &'static str,
    message: String,
    files: Vec<String>,
    focus: String,
    file_total: usize,
    compared_base: String,
    compared_head: String,
    truncated: bool,
    loaded: Option<String>,
    request: u64,
    pending: Vec<Req>,
}

impl Default for Model {
    fn default() -> Model {
        Model {
            mc: Mcs::new(),
            serial: 0,
            thread: String::new(),
            timeline: false,
            active: false,
            selection: -1,
            cwd: String::new(),
            base: String::new(),
            whitespace: true,
            status: "idle",
            message: String::new(),
            files: Vec::new(),
            focus: String::new(),
            file_total: 0,
            compared_base: String::new(),
            compared_head: String::new(),
            truncated: false,
            loaded: None,
            request: 0,
            pending: Vec::new(),
        }
    }
}

/// The facts each signal covers.
#[derive(Debug, PartialEq)]
struct MFacts {
    choices: Vec<i32>,
    latest_turn: i32,
    latest_checkpoint: Option<Cp>,
    selection: i32,
    shown_turn: i32,
    reviewing: bool,
    status: &'static str,
    message: String,
    focus: String,
    file_total: usize,
    base: String,
    compared_base: String,
    compared_head: String,
    truncated: bool,
}

impl MFacts {
    fn signals(&self, before: &MFacts) -> Vec<Signal> {
        let mut out = Vec::new();
        if self.choices != before.choices
            || self.latest_turn != before.latest_turn
            || self.latest_checkpoint != before.latest_checkpoint
        {
            out.push(Signal::Turns);
        }
        if self.selection != before.selection
            || self.shown_turn != before.shown_turn
            || self.reviewing != before.reviewing
        {
            out.push(Signal::Selection);
        }
        if self.status != before.status || self.message != before.message {
            out.push(Signal::Status);
        }
        if self.focus != before.focus || self.file_total != before.file_total {
            out.push(Signal::Focus);
        }
        if self.base != before.base
            || self.compared_base != before.compared_base
            || self.compared_head != before.compared_head
            || self.truncated != before.truncated
        {
            out.push(Signal::Review);
        }
        out
    }
}

impl Model {
    fn turns(&self) -> BTreeMap<i32, String> {
        if self.timeline {
            ready_turns(self.mc.get(&self.thread).map_or(&[][..], Vec::as_slice))
        } else {
            BTreeMap::new()
        }
    }

    fn latest_turn(&self) -> i32 {
        self.turns().keys().next_back().copied().unwrap_or(0)
    }

    fn latest_checkpoint(&self) -> Option<Cp> {
        let id = self.turns().get(&self.latest_turn()).cloned()?;
        self.mc
            .get(&self.thread)?
            .iter()
            .find(|c| c.id == id)
            .cloned()
    }

    fn effective(&self) -> i32 {
        if self.selection == -1 && self.turns().is_empty() && !self.cwd.is_empty() {
            WORKING_TREE
        } else {
            self.selection
        }
    }

    fn reviewing(&self) -> bool {
        self.effective() <= WORKING_TREE
    }

    fn shown_turn(&self) -> i32 {
        if self.selection == 0 || self.reviewing() {
            0
        } else if self.selection > 0 {
            self.selection
        } else {
            self.latest_turn()
        }
    }

    fn choices(&self) -> Vec<i32> {
        let mut values = Vec::new();
        let turns = self.turns();
        if !turns.is_empty() {
            values.extend([-1, 0]);
            values.extend(turns.keys().rev());
        }
        if !self.cwd.is_empty() {
            values.extend([WORKING_TREE, BRANCH]);
        }
        values
    }

    fn facts(&self) -> MFacts {
        MFacts {
            choices: self.choices(),
            latest_turn: self.latest_turn(),
            latest_checkpoint: self.latest_checkpoint(),
            selection: self.selection,
            shown_turn: self.shown_turn(),
            reviewing: self.reviewing(),
            status: self.status,
            message: self.message.clone(),
            focus: self.focus.clone(),
            file_total: self.file_total,
            base: self.base.clone(),
            compared_base: self.compared_base.clone(),
            compared_head: self.compared_head.clone(),
            truncated: self.truncated,
        }
    }

    /// What the selection asks the MC.
    fn wanted(&self) -> Req {
        let mut req = Req {
            thread: self.thread.clone(),
            from: -1,
            to: -1,
            whitespace: self.whitespace,
            ..Req::default()
        };
        if self.reviewing() {
            req.method = "review.getDiffPreview".into();
            req.thread.clear();
            req.cwd = self.cwd.clone();
            req.selection = self.effective();
            if req.selection == BRANCH {
                req.base = self.base.clone();
            }
        } else if self.selection == 0 {
            req.method = "orchestration.getFullThreadDiff".into();
            req.to = self.latest_turn().into();
        } else {
            req.method = "orchestration.getTurnDiff".into();
            req.from = (self.shown_turn() - 1).into();
            req.to = self.shown_turn().into();
        }
        req
    }

    /// The request with the checkpoints it is between.
    fn key_of(&self, req: &Req) -> String {
        let turns = self.turns();
        #[allow(clippy::cast_possible_truncation)]
        let id = |turn: i64| turns.get(&(turn as i32)).cloned().unwrap_or_default();
        format!(
            "{} {} {} {}",
            req.asked(),
            req.selection,
            id(req.from),
            id(req.to)
        )
    }

    fn set_status(&mut self, status: &'static str, why: &str) {
        self.status = status;
        why.clone_into(&mut self.message);
    }

    fn clear_diff(&mut self) {
        self.files.clear();
        self.file_total = 0;
    }

    fn load(&mut self) {
        if !self.active || self.thread.is_empty() {
            return;
        }
        if !self.timeline {
            self.request += 1;
            self.loaded = None;
            return self.set_status("loading", "Loading checkpoint diff...");
        }
        if !self.reviewing() && self.turns().is_empty() {
            self.request += 1;
            self.loaded = None;
            self.clear_diff();
            return self.set_status("empty", "No completed turns yet.");
        }
        let mut next = self.wanted();
        let key = self.key_of(&next);
        if self.loaded.as_ref() == Some(&key) {
            return;
        }
        self.loaded = Some(key);
        self.request += 1;
        next.number = self.request;
        self.pending.push(next);
        let why = if self.reviewing() {
            "Loading changes..."
        } else {
            "Loading checkpoint diff..."
        };
        self.set_status("loading", why);
    }

    fn present(&mut self, files: Vec<String>) {
        self.file_total = files.len();
        if !self.focus.is_empty() && !files.contains(&self.focus) {
            self.focus.clear();
        }
        self.files = files;
    }

    fn shown(&self) -> Vec<String> {
        if self.focus.is_empty() {
            self.files.clone()
        } else {
            vec![self.focus.clone()]
        }
    }

    fn answer(&mut self, req: &Req, answer: Answer) {
        if req.number != self.request {
            return;
        }
        if let Some(error) = answer.error {
            self.loaded = None;
            self.clear_diff();
            return self.set_status("error", &error);
        }
        let review = req.method == "review.getDiffPreview";
        if review {
            self.compared_base = answer.base;
            self.compared_head = answer.head;
            self.truncated = answer.truncated;
        }
        let empty = answer.files.is_empty();
        self.present(answer.files);
        if !empty {
            self.set_status("ready", "");
        } else if !review {
            self.set_status("empty", "No net changes in this selection.");
        } else if req.selection == BRANCH {
            let why = format!("No changes against {}.", self.compared_base);
            self.set_status("empty", &why);
        } else {
            self.set_status("empty", "No uncommitted changes.");
        }
    }

    /// The shown thread's timeline read its checkpoints again.
    fn read_checkpoints(&mut self) {
        let turns = self.turns();
        if (self.selection > 0 && !turns.contains_key(&self.selection))
            || (self.selection == 0 && turns.is_empty())
        {
            self.selection = -1;
        }
        self.load();
    }
}

/// The tab, each thread's timeline, and the MC holding what it is asked.
struct Sut {
    tab: DiffTab,
    mirror: Mirror,
    timelines: BTreeMap<String, Timeline>,
    shown: Option<(String, bool)>,
    held: Vec<(Req, Then)>,
    mc: Mcs,
}

impl Sut {
    fn new() -> Sut {
        let mut tab = DiffTab::new();
        let mirror = Mirror::of(&mut tab);
        Sut {
            tab,
            mirror,
            timelines: THREADS
                .iter()
                .map(|t| ((*t).to_owned(), Timeline::new(&format!("{ENV}:{t}"))))
                .collect(),
            shown: None,
            held: Vec::new(),
            mc: Mcs::new(),
        }
    }

    /// Takes what the tab asked.
    fn hold(&mut self) {
        for effect in self.tab.take_effects() {
            let Effect::Call {
                environment,
                method,
                payload,
                then,
            } = effect
            else {
                panic!("only diffs are asked for: {effect:?}");
            };
            assert_eq!(environment, ENV);
            let text = |key: &str| payload[key].as_str().unwrap_or_default().to_owned();
            let req = Req {
                method: method.to_owned(),
                thread: text("threadId"),
                from: payload["fromTurnCount"].as_i64().unwrap_or(-1),
                to: payload["toTurnCount"].as_i64().unwrap_or(-1),
                whitespace: payload["ignoreWhitespace"].as_bool().unwrap_or(false),
                cwd: text("cwd"),
                base: text("baseRef"),
                ..Req::default()
            };
            self.held.push((req, then));
        }
    }

    fn checkpoints(&self, thread: &str) -> Vec<Obj> {
        self.timelines[thread]
            .entities("checkpoint")
            .values()
            .cloned()
            .collect()
    }

    /// The thread's checkpoints as one snapshot of its stream.
    fn stream(&mut self, thread: &str, next: Vec<Cp>) {
        let rows: Vec<Json> = next
            .iter()
            .map(|c| {
                json!([
                    "checkpoint",
                    c.id,
                    checkpoint(&c.id, c.turn, c.status, c.files)
                ])
            })
            .collect();
        let frame = obj(
            json!({"t": "snapshot", "part": 0, "done": true, "rows": rows, "offset": next.len(), "handle": "log"}),
        );
        self.mc.insert(thread.to_owned(), next);
        let timeline = self.timelines.get_mut(thread).expect("a thread");
        timeline.receive(&frame);
        let out = timeline.take_out();
        // ThreadDiff hears the timeline it was given.
        if self.shown == Some((thread.to_owned(), true)) && out.contains(&Out::CheckpointsChanged) {
            let checkpoints = self.checkpoints(thread);
            self.tab.set_checkpoints(checkpoints);
        }
    }

    fn set_thread(&mut self, thread: &str, timeline: bool) {
        let next = Some((thread.to_owned(), timeline));
        if self.shown == next {
            return;
        }
        self.shown = next;
        let checkpoints = timeline.then(|| (self.checkpoints(thread), false));
        self.tab.set_thread(ENV, thread, checkpoints);
    }

    fn answer(&mut self, req: &Req, mut rank: usize, ok: bool) {
        let at = self
            .held
            .iter()
            .position(|(held, _)| {
                if held.asked() != req.asked() {
                    return false;
                }
                let this = rank == 0;
                rank = rank.saturating_sub(1);
                this
            })
            .expect("the MC holds it");
        let (asked, then) = self.held.remove(at);
        let result = if !ok {
            Err("no".to_owned())
        } else if asked.method == "review.getDiffPreview" {
            let source = |kind: &str, selection: i32| {
                let answer = answer_of(
                    &Req {
                        selection,
                        ..asked.clone()
                    },
                    &self.mc,
                );
                json!({"kind": kind, "diff": patch_of(&answer.files), "baseRef": answer.base, "headRef": answer.head, "truncated": answer.truncated})
            };
            Ok(
                json!({"sources": [source("working-tree", WORKING_TREE), source("branch-range", BRANCH)]}),
            )
        } else {
            let answer = answer_of(&asked, &self.mc);
            match answer.error {
                Some(error) => Err(error),
                None => Ok(json!({"diff": patch_of(&answer.files)})),
            }
        };
        self.tab.answer(then, result);
    }
}

#[derive(Clone, Debug)]
enum Action {
    /// A turn of the thread finishes: its checkpoint is ready, or still
    /// being written.
    NewTurn(usize, bool),
    /// A checkpoint being written is ready, out of order.
    Ready(usize, usize),
    /// A checkpoint's summary lists the files its turn changed.
    Summarize(usize, usize, usize),
    /// The thread is rewound to after the turn.
    Rewind(usize, i32),
    SetThread(usize, bool),
    SetActive(bool),
    SetCheckout(usize),
    Select(i32),
    SetBase(usize),
    SetWhitespace(bool),
    Focus(usize),
    Reload,
    AnswerOne(usize, bool),
}

fn action() -> impl Strategy<Value = Action> {
    let thread = 0..THREADS.len();
    prop_oneof![
        2 => (thread.clone(), prop::bool::weighted(0.75)).prop_map(|(t, r)| Action::NewTurn(t, r)),
        1 => (thread.clone(), any::<usize>()).prop_map(|(t, at)| Action::Ready(t, at)),
        1 => (thread.clone(), any::<usize>(), 1..4usize)
            .prop_map(|(t, at, n)| Action::Summarize(t, at, n)),
        1 => (thread.clone(), 0..4i32).prop_map(|(t, turn)| Action::Rewind(t, turn)),
        1 => (thread, prop::bool::weighted(0.8)).prop_map(|(t, tl)| Action::SetThread(t, tl)),
        2 => any::<bool>().prop_map(Action::SetActive),
        1 => (0..CHECKOUTS.len()).prop_map(Action::SetCheckout),
        2 => (-4..5i32).prop_map(Action::Select),
        1 => (0..BASES.len()).prop_map(Action::SetBase),
        1 => any::<bool>().prop_map(Action::SetWhitespace),
        1 => (0..FOCUS.len()).prop_map(Action::Focus),
        1 => Just(Action::Reload),
        4 => (any::<usize>(), prop::bool::weighted(5.0 / 6.0))
            .prop_map(|(at, ok)| Action::AnswerOne(at, ok)),
    ]
}

/// The MC's checkpoints of a thread after `f`; the shown thread's timeline
/// reads them.
fn change(model: &mut Model, sut: &mut Sut, thread: &str, f: impl FnOnce(&mut Vec<Cp>)) {
    let mut next = model.mc.get(thread).cloned().unwrap_or_default();
    f(&mut next);
    model.mc.insert(thread.to_owned(), next.clone());
    if thread == model.thread {
        model.read_checkpoints();
    }
    sut.stream(thread, next);
}

/// Runs one action on both; false when it does not apply.
fn act(model: &mut Model, sut: &mut Sut, action: &Action) -> bool {
    match *action {
        Action::NewTurn(t, ready) => {
            let thread = THREADS[t];
            let checkpoints = model.mc.get(thread).cloned().unwrap_or_default();
            if checkpoints.len() >= 8 {
                return false;
            }
            let turn = checkpoints
                .iter()
                .filter(|c| c.status != "stale")
                .map(|c| c.turn + 1)
                .max()
                .unwrap_or(1);
            model.serial += 1;
            let id = format!("cp-{}", model.serial);
            let status = if ready { "ready" } else { "pending" };
            change(model, sut, thread, |c| {
                c.push(Cp {
                    id,
                    turn,
                    status,
                    files: 0,
                });
            });
        }
        Action::Ready(t, at) => {
            let thread = THREADS[t];
            let pending: Vec<String> = model
                .mc
                .get(thread)
                .into_iter()
                .flatten()
                .filter(|c| c.status == "pending")
                .map(|c| c.id.clone())
                .collect();
            if pending.is_empty() {
                return false;
            }
            let id = pending[at % pending.len()].clone();
            change(model, sut, thread, |c| {
                for checkpoint in c.iter_mut().filter(|c| c.id == id) {
                    checkpoint.status = "ready";
                }
            });
        }
        Action::Summarize(t, at, files) => {
            let thread = THREADS[t];
            let ids: Vec<String> = model
                .mc
                .get(thread)
                .into_iter()
                .flatten()
                .filter(|c| c.files != files)
                .map(|c| c.id.clone())
                .collect();
            if ids.is_empty() {
                return false;
            }
            let id = ids[at % ids.len()].clone();
            change(model, sut, thread, |c| {
                for checkpoint in c.iter_mut().filter(|c| c.id == id) {
                    checkpoint.files = files;
                }
            });
        }
        Action::Rewind(t, turn) => {
            change(model, sut, THREADS[t], |c| {
                for checkpoint in c.iter_mut().filter(|c| c.turn > turn) {
                    checkpoint.status = "stale";
                }
            });
        }
        Action::SetThread(t, timeline) => {
            let thread = THREADS[t];
            if thread != model.thread || timeline != model.timeline {
                if thread != model.thread {
                    thread.clone_into(&mut model.thread);
                    model.request += 1;
                    model.loaded = None;
                    model.clear_diff();
                    model.focus.clear();
                    model.compared_base.clear();
                    model.compared_head.clear();
                    model.truncated = false;
                    model.selection = -1;
                    model.set_status("idle", "");
                }
                model.timeline = timeline;
                model.read_checkpoints();
            }
            sut.set_thread(thread, timeline);
        }
        Action::SetActive(active) => {
            model.active = active;
            model.load();
            sut.tab.set_active(active);
        }
        Action::SetCheckout(at) => {
            let cwd = CHECKOUTS[at];
            if cwd != model.cwd {
                cwd.clone_into(&mut model.cwd);
                if cwd.is_empty() && model.selection <= WORKING_TREE {
                    model.selection = -1;
                }
                model.load();
            }
            sut.tab.set_checkout(cwd);
        }
        Action::Select(selection) => {
            let turns = model.turns();
            if selection <= 0 || turns.contains_key(&selection) {
                let next = if selection < BRANCH
                    || (selection <= WORKING_TREE && model.cwd.is_empty())
                    || (selection == 0 && turns.is_empty())
                {
                    -1
                } else {
                    selection
                };
                if next != model.selection {
                    model.selection = next;
                    model.focus.clear();
                    model.load();
                }
            }
            sut.tab.select(selection);
        }
        Action::SetBase(at) => {
            let base = BASES[at];
            if base.trim() != model.base {
                base.trim().clone_into(&mut model.base);
                model.load();
            }
            sut.tab.set_base_ref(base);
        }
        Action::SetWhitespace(ignore) => {
            if ignore != model.whitespace {
                model.whitespace = ignore;
                model.load();
            }
            sut.tab.set_ignore_whitespace(ignore);
        }
        Action::Focus(at) => {
            let path = FOCUS[at];
            if path != model.focus {
                path.clone_into(&mut model.focus);
                if model.status == "ready" {
                    let files = model.files.clone();
                    model.present(files);
                }
            }
            if path.is_empty() {
                sut.tab.show_all_files();
            } else {
                sut.tab.focus_file(path);
            }
        }
        Action::Reload => {
            model.loaded = None;
            model.load();
            sut.tab.reload();
        }
        Action::AnswerOne(at, ok) => {
            if model.pending.is_empty() {
                return false;
            }
            let at = at % model.pending.len();
            let req = model.pending.remove(at);
            let rank = model.pending[..at]
                .iter()
                .filter(|p| p.asked() == req.asked())
                .count();
            let answer = if ok {
                answer_of(&req, &model.mc)
            } else {
                Answer {
                    error: Some("no".into()),
                    ..Answer::default()
                }
            };
            model.answer(&req, answer);
            sut.answer(&req, rank, ok);
        }
    }
    sut.hold();
    true
}

fn sorted(requests: impl Iterator<Item = String>) -> Vec<String> {
    let mut out: Vec<String> = requests.collect();
    out.sort();
    out
}

fn check(
    before: &MFacts,
    tab_before: &super::Facts,
    model: &Model,
    sut: &mut Sut,
) -> Result<(), TestCaseError> {
    prop_assert_eq!(
        sorted(sut.held.iter().map(|(r, _)| r.asked())),
        sorted(model.pending.iter().map(Req::asked))
    );
    let tab = &sut.tab;
    let choices: Vec<i32> = tab.choices().iter().map(|(v, _)| *v).collect();
    prop_assert_eq!(&choices, &model.choices());
    prop_assert_eq!(tab.latest_turn(), model.latest_turn());
    prop_assert_eq!(tab.selection(), model.selection);
    // The picker shows the selection: one of the choices, or the first.
    prop_assert!(tab.selection() == -1 || choices.contains(&tab.selection()));
    prop_assert_eq!(tab.shown_turn(), model.shown_turn());
    prop_assert_eq!(tab.reviewing(), model.reviewing());
    prop_assert_eq!(tab.status(), model.status);
    prop_assert_eq!(tab.message(), model.message.as_str());
    prop_assert_eq!(tab.focus_path(), model.focus.as_str());
    prop_assert_eq!(tab.compared_base(), model.compared_base.as_str());
    prop_assert_eq!(tab.compared_head(), model.compared_head.as_str());
    prop_assert_eq!(tab.truncated(), model.truncated);
    prop_assert_eq!(tab.base_ref(), model.base.as_str());
    prop_assert_eq!(tab.ignore_whitespace(), model.whitespace);
    let paths = tab.diff().paths();
    if model.status == "ready" {
        prop_assert_eq!(tab.file_total(), model.file_total);
        prop_assert_eq!(&paths, &model.shown());
    }
    if matches!(model.status, "empty" | "error") {
        prop_assert!(paths.is_empty());
    }
    // What a shown tab settles on is what the MC says now.
    let settled = matches!(model.status, "ready" | "empty");
    if model.active && model.timeline && settled && (model.reviewing() || !model.turns().is_empty())
    {
        let now = answer_of(&model.wanted(), &model.mc);
        prop_assert_eq!(&now.error, &None);
        prop_assert_eq!(tab.file_total(), now.files.len());
        let want = if now.files.contains(&model.focus) {
            vec![model.focus.clone()]
        } else {
            now.files
        };
        prop_assert_eq!(&paths, &want);
    }
    // The latest checkpoint as the timeline has it.
    let after = model.facts();
    let latest = tab.latest_checkpoint();
    let id = latest.get("id").and_then(Json::as_str).unwrap_or("");
    let files = latest
        .get("files")
        .and_then(Json::as_array)
        .map_or(0, Vec::len);
    let want = after.latest_checkpoint.as_ref();
    prop_assert_eq!(id, want.map_or("", |c| c.id.as_str()));
    prop_assert_eq!(files, want.map_or(0, |c| c.files));
    // Each signal fires once when what it covers changed, never otherwise.
    let said: Vec<Signal> = tab
        .facts()
        .signals(tab_before)
        .into_iter()
        .filter(|s| !matches!(s, Signal::Revert | Signal::Options))
        .collect();
    prop_assert_eq!(said, after.signals(before));
    sut.mirror.follow(&mut sut.tab);
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 256, ..ProptestConfig::default() })]

    /// The Diff tab shows what the MC says of the selection, which is
    /// always one of the choices.
    #[test]
    fn the_diff_tab_shows_what_the_mc_says_of_the_selection(
        actions in prop::collection::vec(action(), 1..60)
    ) {
        let mut model = Model::default();
        let mut sut = Sut::new();
        for action in &actions {
            let before = model.facts();
            let tab_before = sut.tab.facts();
            if act(&mut model, &mut sut, action) {
                check(&before, &tab_before, &model, &mut sut)?;
            }
        }
    }
}
