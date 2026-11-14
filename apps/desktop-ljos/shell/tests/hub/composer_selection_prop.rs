//! What the composer shows is what runs (send_turn, forget_taken_picks,
//! dispatch_all), as a state machine against an MC that counts selection
//! revisions as the MC does (lib/hal_c2/orchestration): a command based on
//! a revision the thread has moved past is refused when what it sets
//! differs, and any change to the model, access or interaction mode moves
//! the revision on. desktop-qt's tst_ComposerSelectionProp.cpp.
//!
//! The property: a send carries exactly what the composer showed, and never
//! a model the user did not pick against the current revision; mode changes
//! go out at once and name no revision. Picks, sends, this client's own
//! access and interaction mode changes, changes made on another client,
//! held answers, rows that come before or after an answer or lag behind
//! them, refusals and reconnects are interleaved. Two MCs: one whose
//! answers name the revision they moved to, and one from before revisions
//! (a pick is saved to the thread before the send, and nothing carries a
//! base).

use std::cell::Cell;

use hal_c2_shell::controllers::composer;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use hal_c2_shell::store;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::composer::{DISPATCH, launch_in, on_threads_with, providers};
use crate::workspace::AT;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Kind {
    Named,
    Old,
}

const KEY: &str = "env-1:t1";
/// (instance, model) the picker offers: `providers`' catalogue.
const MODELS: [(&str, &str); 3] = [
    ("codex", "gpt-a"),
    ("codex", "gpt-b"),
    ("claudeAgent", "claude-a"),
];
/// The access this client picks, and the access another client picks:
/// never the same, so a change from elsewhere always moves the thread.
const OWN_ACCESS: [&str; 2] = ["approval-required", "full-access"];
const OTHER_ACCESS: [&str; 2] = ["auto-accept-edits", "auto"];
const INTERACTIONS: [&str; 2] = ["default", "plan"];

#[derive(Clone, Debug)]
enum Op {
    PickModel(usize),
    /// This client's own interaction mode change: goes at once, and moves
    /// the revision; the composer shows it while it is on its way.
    PickInteraction(usize, bool),
    PickAccess(usize, bool),
    /// Another client changes the model (0), access (1) or interaction
    /// mode (2).
    Elsewhere(usize, usize),
    Submit(bool),
    Hold,
    /// The held answers go, in the order their commands came.
    AnswerHeld,
    /// Rows wait while answers go: an answer reaches the client before
    /// its row.
    Lag,
    CatchUp,
    /// The connection drops with nothing on its way, and comes back.
    Reconnect,
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        2 => (0..MODELS.len()).prop_map(Op::PickModel),
        1 => (0..2usize, any::<bool>()).prop_map(|(m, a)| Op::PickInteraction(m, a)),
        2 => (0..2usize, any::<bool>()).prop_map(|(m, a)| Op::PickAccess(m, a)),
        2 => (0..3usize, 0..MODELS.len()).prop_map(|(f, i)| Op::Elsewhere(f, i)),
        3 => any::<bool>().prop_map(Op::Submit),
        1 => Just(Op::Hold),
        1 => Just(Op::AnswerHeld),
        1 => Just(Op::Lag),
        1 => Just(Op::CatchUp),
        1 => Just(Op::Reconnect),
    ]
}

fn selection_of(instance: &str, model: &str) -> Json {
    json!({"instanceId": instance, "model": model})
}

fn name_of(selection: &Json) -> String {
    format!(
        "{}/{}",
        selection["instanceId"].as_str().unwrap_or_default(),
        selection["model"].as_str().unwrap_or_default()
    )
}

/// A send the composer made: what it showed and what it knew then.
struct Submission {
    text: String,
    /// instance/model the composer showed.
    shown: String,
    /// The thread's model as this client had it.
    row: String,
    /// Whether this client had the MC's latest selection.
    current: bool,
    /// Changes made elsewhere by then.
    foreign: usize,
    refused: bool,
}

struct Sut {
    hub: Hub,
    kind: Kind,
    // The MC's thread.
    selection: Json,
    runtime: String,
    interaction: String,
    revision: i64,
    /// The revisions made elsewhere, in order.
    foreign: Vec<i64>,
    /// The shell's row revision.
    rev: i64,
    holding: bool,
    lagging: bool,
    lagged: Vec<Json>,
    /// The answer to a change reaches the client before its row.
    ack_first: bool,
    /// The revision this client had when the user picked a model.
    picked_at: Option<i64>,
    submission: Option<Submission>,
    decided: Vec<usize>,
    sent: u32,
    violations: Vec<String>,
}

thread_local! {
    static RUNS: Cell<u32> = const { Cell::new(0) };
}

impl Sut {
    fn new(kind: Kind) -> Sut {
        let run = RUNS.with(|r| {
            r.set(r.get() + 1);
            r.get()
        });
        let hub = on_threads_with(launch_in(&format!("selection-prop-{run}")), &["t1"]);
        providers(&hub);
        Settings::of(&hub.engine).write_device(&hub.engine, "planModeEnabled", json!(true));
        let mut sut = Sut {
            hub,
            kind,
            selection: selection_of("codex", "gpt-a"),
            runtime: "full-access".into(),
            interaction: "default".into(),
            revision: 1,
            foreign: Vec::new(),
            rev: 1,
            holding: false,
            lagging: false,
            lagged: Vec::new(),
            ack_first: true,
            picked_at: None,
            submission: None,
            decided: Vec::new(),
            sent: 0,
            violations: Vec::new(),
        };
        sut.publish();
        assert_eq!(sut.shown_model(), name_of(&sut.selection));
        sut
    }

    fn row(&self) -> Json {
        let mut thread = json!({"id": "t1", "projectId": "p1", "title": "Tax line",
            "branch": "main", "worktreePath": null, "createdAt": AT, "updatedAt": AT,
            "modelSelection": self.selection, "runtimeMode": self.runtime,
            "interactionMode": self.interaction});
        if self.kind != Kind::Old {
            thread["selectionRevision"] = json!(self.revision);
        }
        thread
    }

    fn publish(&mut self) {
        self.rev += 1;
        let frame = json!({"t": "shell.rows", "mc": "a", "epoch": "e", "rev": self.rev,
            "rows": [["t1", "thread", self.row()]]});
        if self.lagging {
            self.lagged.push(frame);
        } else {
            self.hub.mc.frame(&self.hub.engine, "shell", "", frame);
        }
    }

    fn catch_up(&mut self) {
        self.lagging = false;
        for frame in std::mem::take(&mut self.lagged) {
            self.hub.mc.frame(&self.hub.engine, "shell", "", frame);
        }
        self.answer_all();
    }

    fn shown(&self) -> Json {
        self.hub.published("composer")
    }

    fn shown_model(&self) -> String {
        let composer = self.shown();
        format!(
            "{}/{}",
            composer["selectedInstanceId"].as_str().unwrap_or_default(),
            composer["selectedModel"].as_str().unwrap_or_default()
        )
    }

    /// The revision of the thread this client holds; -1 for an MC without
    /// them.
    fn seen(&self) -> i64 {
        store::with(&self.hub.engine, |s| s.thread(KEY))
            .and_then(|thread| thread.selection_revision)
            .unwrap_or(-1)
    }

    fn seen_model(&self) -> String {
        store::with(&self.hub.engine, |s| s.thread(KEY))
            .map(|thread| name_of(&Json::Object(thread.model_selection)))
            .unwrap_or_default()
    }

    fn foreign_within(&self, after: i64, up_to: i64) -> bool {
        self.foreign.iter().any(|&f| f > after && f <= up_to)
    }

    fn violate(&mut self, what: String) {
        self.violations.push(what);
    }

    /// Decides every dispatch not yet answered, and those their answers
    /// make, unless the answers are held.
    fn answer_all(&mut self) {
        if self.holding {
            return;
        }
        loop {
            let next = {
                let calls = self.hub.mc.calls.borrow();
                (0..calls.len()).find(|&i| {
                    calls[i].1 == DISPATCH
                        && !self.decided.contains(&i)
                        && self.hub.mc.is_pending(i)
                })
            };
            let Some(index) = next else {
                break;
            };
            self.decided.push(index);
            self.decide(index);
        }
        self.check_refused();
    }

    /// The MC decides a command: refuses one based on a revision the thread
    /// has moved past when what it sets differs, else takes it.
    fn decide(&mut self, index: usize) {
        let command = self.hub.mc.calls.borrow()[index].2.clone();
        let kind = command["type"].as_str().unwrap_or_default().to_owned();
        let access = (kind == "thread.runtime-mode.set").then(|| {
            command["runtimeMode"]
                .as_str()
                .unwrap_or_default()
                .to_owned()
        });
        let mode = (kind == "thread.interaction-mode.set").then(|| {
            command["interactionMode"]
                .as_str()
                .unwrap_or_default()
                .to_owned()
        });
        let carries_model = command.get("modelSelection").is_some();
        // Today's MC runs a plain send on the message's model and takes it.
        let model = (kind == "provider.switch"
            || kind == "thread.model-selection.set"
            || (kind == "message.dispatch" && self.kind != Kind::Old && carries_model))
            .then(|| command["modelSelection"].clone());
        let moves_model = model
            .as_ref()
            .is_some_and(|m| name_of(m) != name_of(&self.selection));
        let moves_access = access.as_ref().is_some_and(|a| *a != self.runtime);
        let moves_mode = mode.as_ref().is_some_and(|m| *m != self.interaction);
        let moves = moves_model || moves_access || moves_mode;
        let base = command.get("selectionBase").and_then(Json::as_i64);
        if base.is_some() && self.kind == Kind::Old {
            self.violate(format!("{kind} carries a base to an MC without revisions"));
        }
        if base.is_some() && (access.is_some() || mode.is_some()) {
            self.violate(format!("{kind} carries a base: a mode change goes as made"));
        }
        if kind == "thread.model-selection.set" && self.kind != Kind::Old {
            self.violate("a model saved apart from the send to an MC that counts revisions".into());
        }
        if let Some(base) = base
            && base != self.revision
            && moves
        {
            // Only a change made elsewhere makes a pick stale.
            if !self.foreign_within(base, self.revision) {
                self.violate(format!(
                    "{kind} on {base} refused at {} for changes of this client's own",
                    self.revision
                ));
            }
            if let Some(submission) = &mut self.submission {
                submission.refused = true;
            }
            let error = McError {
                message: "The thread's selection changed".into(),
                detail: json!({"code": "selection-stale", "selectionRevision": self.revision,
                    "modelSelection": self.selection,
                    "providerInstanceId": self.selection["instanceId"],
                    "runtimeMode": self.runtime, "interactionMode": self.interaction}),
            };
            self.hub.mc.reply(&self.hub.engine, index, Err(error));
            return;
        }
        // A model that moves the thread is the user's pick, made against
        // what they saw.
        if moves_model && self.kind != Kind::Old {
            match self.picked_at {
                None => self.violate(format!("{kind} sets a model the user never picked")),
                Some(at) if self.foreign_within(at, self.revision) => self.violate(format!(
                    "{kind} sets the model picked at {at} over a change made elsewhere by {}",
                    self.revision
                )),
                Some(_) => {}
            }
        }
        if moves_model && let Some(model) = &model {
            self.selection = selection_of(
                model["instanceId"].as_str().unwrap_or_default(),
                model["model"].as_str().unwrap_or_default(),
            );
        }
        if moves_access && let Some(access) = access {
            self.runtime = access;
        }
        if moves_mode && let Some(mode) = mode {
            self.interaction = mode;
        }
        if moves {
            self.revision += 1;
        }
        if kind == "message.dispatch" {
            self.took(&command);
        }
        let mut answer = json!({"sequence": index});
        if self.kind == Kind::Named && moves {
            answer["selectionRevision"] = json!(self.revision);
        }
        if !moves {
            self.hub.mc.reply(&self.hub.engine, index, Ok(answer));
        } else if self.ack_first {
            self.hub.mc.reply(&self.hub.engine, index, Ok(answer));
            self.publish();
        } else {
            self.publish();
            self.hub.mc.reply(&self.hub.engine, index, Ok(answer));
        }
    }

    /// The thread took a message: it runs what the composer showed.
    fn took(&mut self, command: &Json) {
        let Some(sent) = self.submission.take() else {
            return self.violate("a message nobody sent, or one sent again after a refusal".into());
        };
        let carried = command.get("modelSelection").map(name_of);
        if let Some(carried) = &carried
            && *carried != sent.shown
        {
            self.violate(format!(
                "the composer showed {} and sent {carried}",
                sent.shown
            ));
        }
        if carried.is_none() && sent.shown != sent.row {
            self.violate(format!(
                "the composer showed {} and sent no model on {}",
                sent.shown, sent.row
            ));
        }
        // A send with no pick runs on what the thread holds, a change from
        // elsewhere included; an MC without revisions cannot keep a send's
        // pick from one made elsewhere while it was on its way.
        let elsewhere = self.foreign.len() > sent.foreign || !sent.current;
        if name_of(&self.selection) != sent.shown
            && !((carried.is_none() || self.kind == Kind::Old) && elsewhere)
        {
            self.violate(format!(
                "the composer showed {} and the thread runs {}",
                sent.shown,
                name_of(&self.selection)
            ));
        }
    }

    /// A refused send comes back to the composer with a toast, and nothing
    /// goes on its own.
    fn check_refused(&mut self) {
        let Some(submission) = self.submission.take_if(|s| s.refused) else {
            return;
        };
        let toasted = self.hub.published("toasts")["items"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|toast| {
                toast["title"] == "Message not sent"
                    && toast["description"]
                        .as_str()
                        .is_some_and(|d| d.ends_with("elsewhere. Check it and send again."))
            });
        let text = composer::draft(&self.hub.engine, KEY);
        if text != submission.text || !toasted {
            self.violate(format!(
                "a refused send left the composer with {text:?} (sent {:?}), toasted {toasted}",
                submission.text
            ));
        }
    }

    fn elsewhere(&mut self, field: usize, index: usize) {
        match field {
            0 => {
                let mut next = index;
                let (instance, model) = MODELS[next];
                if name_of(&selection_of(instance, model)) == name_of(&self.selection) {
                    next = (next + 1) % MODELS.len();
                }
                let (instance, model) = MODELS[next];
                self.selection = selection_of(instance, model);
            }
            1 => {
                let access = OTHER_ACCESS[index % 2];
                self.runtime = if access == self.runtime {
                    OTHER_ACCESS[1 - index % 2]
                } else {
                    access
                }
                .into();
            }
            _ => {
                self.interaction = if self.interaction == "plan" {
                    "default"
                } else {
                    "plan"
                }
                .into();
            }
        }
        self.revision += 1;
        self.foreign.push(self.revision);
        self.publish();
    }

    fn step(&mut self, op: Op) {
        match op {
            Op::PickModel(index) => {
                let (instance, model) = MODELS[index];
                self.picked_at = Some(self.seen());
                self.hub.dispatch(
                    "composer.model.select",
                    json!({"instanceId": instance, "model": model}),
                );
                assert_eq!(self.shown_model(), format!("{instance}/{model}"));
            }
            Op::PickInteraction(mode, ack_first) => {
                self.ack_first = ack_first;
                let mode = INTERACTIONS[mode];
                self.hub
                    .dispatch("composer.interactionMode.set", json!({"mode": mode}));
                assert_eq!(self.shown()["interactionMode"], mode);
            }
            Op::PickAccess(mode, ack_first) => {
                self.ack_first = ack_first;
                self.hub.dispatch(
                    "composer.runtimeMode.set",
                    json!({"mode": OWN_ACCESS[mode]}),
                );
            }
            Op::Elsewhere(field, index) => self.elsewhere(field, index),
            Op::Submit(ack_first) => {
                // One send on its way at a time.
                if self.submission.is_some() {
                    return;
                }
                self.ack_first = ack_first;
                self.sent += 1;
                let text = format!("go {}", self.sent);
                self.submission = Some(Submission {
                    text: text.clone(),
                    shown: self.shown_model(),
                    row: self.seen_model(),
                    current: name_of(&self.selection) == self.seen_model(),
                    foreign: self.foreign.len(),
                    refused: false,
                });
                self.hub.dispatch(
                    "composer.text.set",
                    json!({"target": KEY, "text": text, "cursor": text.encode_utf16().count()}),
                );
                self.hub
                    .dispatch("composer.submit", json!({"intent": "foreground"}));
            }
            Op::Hold => self.holding = true,
            Op::AnswerHeld => self.holding = false,
            Op::Lag => self.lagging = true,
            Op::CatchUp => return self.catch_up(),
            Op::Reconnect => {
                if self.holding || self.lagging || self.submission.is_some() {
                    return;
                }
                self.hub.mc.set_ready(&self.hub.engine, false);
                self.hub.mc.set_ready(&self.hub.engine, true);
            }
        }
        self.answer_all();
    }

    /// Whatever was held goes, and still holds.
    fn finish(&mut self) {
        self.holding = false;
        self.catch_up();
        // A send the composer kept (a mode change still on its way, say)
        // has gone by now.
        if self.submission.as_ref().is_some_and(|s| !s.refused) {
            self.answer_all();
        }
    }
}

fn run(kind: Kind, ops: Vec<Op>) -> Result<(), TestCaseError> {
    let mut sut = Sut::new(kind);
    for op in ops {
        sut.step(op);
        prop_assert!(sut.violations.is_empty(), "{}", sut.violations.join("\n"));
    }
    sut.finish();
    prop_assert!(sut.violations.is_empty(), "{}", sut.violations.join("\n"));
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 96, ..ProptestConfig::default() })]

    #[test]
    fn a_send_carries_what_the_composer_showed(ops in proptest::collection::vec(op(), 1..30)) {
        run(Kind::Named, ops)?;
    }

    #[test]
    fn a_send_carries_what_the_composer_showed_to_an_mc_without_revisions(
        ops in proptest::collection::vec(op(), 1..30)
    ) {
        run(Kind::Old, ops)?;
    }
}
