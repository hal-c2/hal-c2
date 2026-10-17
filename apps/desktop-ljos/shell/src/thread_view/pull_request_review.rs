//! desktop-qt's PullRequestReview: a review tab, one pull request read from
//! its host through the MC: its description and checks
//! (`pullRequests.detail`), its conversation and review threads
//! (`pullRequests.activity`), its stack (`pullRequests.stack`), the files
//! the viewer marked viewed (`pullRequests.filesViewed`) and its code, a
//! patch read in slices over HTTP (`POST /api/pull-requests/diff`, too large
//! for the socket) into a [`DiffModel`] of its own.
//!
//! What it changes on the host (a comment, a review, a merge, a stack merge
//! or rebase, a thread resolved) is sent once, then the pull request is read
//! again; marking a file viewed shows at once and is taken back if the host
//! refuses it.
//!
//! [`Review`] is the core: it takes the MC's replies and says what to ask of
//! the MC and of its diff as [`Effect`]s. [`PullRequestReview`] is the object
//! QML binds (`Panel.review`); the right panel points it at the review tab
//! shown.

use std::collections::BTreeSet;
use std::rc::Rc;

use ljos::prelude::{Atom, Cx, Engine, ObjectId, QmlObject, Value, qml_impl};
use ljos_engine::EngineError;
use serde_json::json;

use super::diff::DiffModel;
use super::rows::int;
use crate::json::{self, Json};
use crate::mc::{Mc, McError};

/// Where a pull request's code is read, a slice at a time.
pub const DIFF_PATH: &str = "/api/pull-requests/diff";

fn text<'a>(object: &'a Json, key: &str) -> &'a str {
    object.get(key).and_then(Json::as_str).unwrap_or("")
}

fn flag(object: &Json, key: &str) -> bool {
    object.get(key).and_then(Json::as_bool).unwrap_or(false)
}

/// QJsonValue::toInt().
fn int_of(object: &Json, key: &str) -> i64 {
    object
        .get(key)
        .and_then(Json::as_i64)
        .filter(|n| i32::try_from(*n).is_ok())
        .unwrap_or(0)
}

fn login(actor: Option<&Json>) -> &str {
    actor.map_or("", |a| text(a, "login"))
}

fn array<'a>(object: &'a Json, key: &str) -> &'a [Json] {
    object
        .get(key)
        .and_then(Json::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
}

fn offers_merge(actions: Option<&Json>) -> bool {
    actions
        .and_then(Json::as_array)
        .is_some_and(|a| a.iter().any(|x| x.as_str() == Some("merge")))
}

/// What the host offers, narrowed to what the repository allows (one that
/// says nothing allows them all): allowedPullRequestMergeMethods.
fn merge_methods(detail: &Json) -> Vec<String> {
    let allowed = detail.get("mergeCapabilities").and_then(Json::as_object);
    detail
        .get("capabilities")
        .map(|c| array(c, "mergeMethods"))
        .unwrap_or_default()
        .iter()
        .map(|m| m.as_str().unwrap_or("").to_owned())
        .filter(|m| {
            allowed.is_none_or(|a| a.is_empty() || a.get(m).and_then(Json::as_bool) == Some(true))
        })
        .collect()
}

/// The host can merge and this viewer may (a permission the host says
/// nothing of is granted).
fn viewer_may_merge(detail: &Json) -> bool {
    let permissions = detail.get("viewerPermissions").filter(|p| p.is_object());
    offers_merge(detail.get("capabilities").and_then(|c| c.get("actions")))
        && permissions.is_none_or(|p| offers_merge(p.get("actions")))
}

/// What the review shows of `detail` (`pullRequests.detail`'s answer).
pub fn detail_of(detail: &Json) -> Json {
    let state = text(detail, "state");
    let draft = flag(detail, "isDraft");
    let checks: Vec<Json> = array(detail, "checks")
        .iter()
        .map(|check| {
            json!({
                "name": text(check, "name"),
                "status": text(check, "status"),
                "description": text(check, "description"),
                "url": text(check, "url"),
            })
        })
        .collect();
    let labels: Vec<&str> = array(detail, "labels")
        .iter()
        .map(|l| text(l, "name"))
        .collect();
    let reviewers: Vec<&str> = array(detail, "reviewers")
        .iter()
        .map(|r| login(Some(r)))
        .collect();
    let state_label = match state {
        "merged" => "Merged",
        "closed" => "Closed",
        _ if draft => "Draft",
        _ => "Open",
    };
    json!({
        "title": text(detail, "title"),
        "body": text(detail, "body"),
        "url": text(detail, "url"),
        "author": login(detail.get("author")),
        "state": if draft && state == "open" { "draft" } else { state },
        "stateLabel": state_label,
        "branches": format!("{} → {}", text(detail, "headBranch"), text(detail, "baseBranch")),
        "labels": labels,
        "reviewers": reviewers,
        "mergeability": text(detail, "mergeability"),
        "behindBy": int_of(detail, "behindBy"),
        "checks": checks,
        "canMerge": state == "open" && !draft && viewer_may_merge(detail),
        "mergeMethods": merge_methods(detail),
    })
}

/// What runs once a change lands.
#[derive(Clone, Debug, PartialEq)]
pub enum Done {
    Nothing,
    StackMerged,
    StackRebased,
    Merged,
    Reviewed(String),
}

/// What a reply is for. A generation is the pull request's read: a reply
/// for one read before is dropped.
#[derive(Clone, Debug, PartialEq)]
pub enum Then {
    Detail {
        generation: u64,
    },
    Activity {
        generation: u64,
    },
    FilesViewed {
        generation: u64,
    },
    Stack {
        generation: u64,
    },
    /// A slice of the code; `patch` is the slices before it.
    Code {
        generation: u64,
        patch: String,
    },
    /// A file marked (or unmarked) viewed, to take back on a refusal.
    Viewed {
        generation: u64,
        path: String,
        viewed: bool,
    },
    Change {
        generation: u64,
        failure: String,
        done: Done,
    },
}

/// What the review asks of its owner, in order.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// An RPC where the pull request's environment is served.
    Call {
        environment: String,
        method: &'static str,
        payload: Json,
        then: Then,
    },
    /// A POST to the MC's HTTP API.
    Post {
        path: &'static str,
        body: Json,
        then: Then,
    },
    /// A toast: type, title, description.
    Notify {
        kind: &'static str,
        title: String,
        description: String,
    },
    /// A page for the user's browser.
    Open(String),
    /// Text for the clipboard, toasted as the PR number copied (or not).
    CopyNumber(String),
    /// The diff shows this patch.
    Patch(String),
    /// The diff shows nothing.
    Clear,
    /// The diff opens or folds this file.
    Expand { path: String, expanded: bool },
    /// The diff folds every file marked viewed.
    FoldViewed,
}

/// What changed besides the diff.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Note {
    /// key, number.
    Target,
    /// online, status, message, busy, problem.
    State,
    /// detail, conversation, reviewThreads.
    Detail,
    /// stack, stackConfirmation.
    Stack,
    /// codeStatus, codeMessage.
    Code,
    /// viewedPaths, viewedCount.
    Viewed,
}

/// One pull request under review.
#[derive(Debug)]
pub struct Review {
    environment: String,
    project: String,
    host: String,
    repository: String,
    number: i64,
    generation: u64,
    loaded: bool,
    active: bool,
    online: bool,
    status: &'static str,
    message: String,
    /// detail_of the host's answer; `{}` before one.
    detail: Json,
    may_merge: bool,
    may_rebase: bool,
    conversation: Vec<Json>,
    threads: Vec<Json>,
    /// `pullRequests.stack`'s answer; `{}` before one.
    stack: Json,
    stale: bool,
    confirmation: Json,
    stack_method: String,
    code_status: &'static str,
    code_message: String,
    viewed: BTreeSet<String>,
    busy: usize,
    problem: String,
    notes: Vec<Note>,
    effects: Vec<Effect>,
}

impl Default for Review {
    fn default() -> Self {
        Review {
            environment: String::new(),
            project: String::new(),
            host: String::new(),
            repository: String::new(),
            number: 0,
            generation: 0,
            loaded: false,
            active: false,
            online: false,
            status: "idle",
            message: String::new(),
            detail: json!({}),
            may_merge: false,
            may_rebase: false,
            conversation: Vec::new(),
            threads: Vec::new(),
            stack: json!({}),
            stale: false,
            confirmation: json!({}),
            stack_method: String::new(),
            code_status: "idle",
            code_message: String::new(),
            viewed: BTreeSet::new(),
            busy: 0,
            problem: String::new(),
            notes: Vec::new(),
            effects: Vec::new(),
        }
    }
}

impl Review {
    pub fn new() -> Review {
        Review::default()
    }

    /// `host/repository#number`, or empty with none.
    pub fn key(&self) -> String {
        if self.number > 0 {
            format!("{}/{}#{}", self.host, self.repository, self.number)
        } else {
            String::new()
        }
    }

    pub fn number(&self) -> i64 {
        self.number
    }

    pub fn online(&self) -> bool {
        self.online
    }

    pub fn active(&self) -> bool {
        self.active
    }

    pub fn status(&self) -> &'static str {
        self.status
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    pub fn detail(&self) -> &Json {
        &self.detail
    }

    pub fn conversation(&self) -> &[Json] {
        &self.conversation
    }

    pub fn review_threads(&self) -> &[Json] {
        &self.threads
    }

    pub fn stack_confirmation(&self) -> &Json {
        &self.confirmation
    }

    pub fn code_status(&self) -> &'static str {
        self.code_status
    }

    pub fn code_message(&self) -> &str {
        &self.code_message
    }

    pub fn busy(&self) -> bool {
        self.busy > 0
    }

    pub fn problem(&self) -> &str {
        &self.problem
    }

    pub fn is_viewed(&self, path: &str) -> bool {
        self.viewed.contains(path)
    }

    /// Of `paths` (the diff's files, in order), those marked viewed.
    pub fn viewed_of(&self, paths: &[String]) -> Vec<String> {
        paths
            .iter()
            .filter(|p| self.viewed.contains(*p))
            .cloned()
            .collect()
    }

    /// Reviews another pull request (none: `number` 0): what was read of
    /// the last goes.
    pub fn set_pull_request(
        &mut self,
        environment: &str,
        project: &str,
        host: &str,
        repository: &str,
        number: i64,
    ) {
        if environment == self.environment
            && project == self.project
            && host == self.host
            && repository == self.repository
            && number == self.number
        {
            return;
        }
        self.environment = environment.to_owned();
        self.project = project.to_owned();
        self.host = host.to_owned();
        self.repository = repository.to_owned();
        self.number = number;
        self.generation += 1;
        self.loaded = false;
        self.detail = json!({});
        self.stack = json!({});
        self.stale = false;
        self.confirmation = json!({});
        self.notes.push(Note::Stack);
        self.conversation.clear();
        self.threads.clear();
        self.viewed.clear();
        self.problem.clear();
        self.effects.push(Effect::Clear);
        self.set_status("idle", "");
        self.set_code("idle", "");
        self.notes
            .extend([Note::Target, Note::State, Note::Detail, Note::Viewed]);
        if self.active {
            self.load();
        }
    }

    pub fn clear(&mut self) {
        self.set_pull_request("", "", "", "", 0);
    }

    /// The environment went offline or came back: back online, what could
    /// not be read is read now.
    pub fn set_online(&mut self, online: bool) {
        if online == self.online {
            return;
        }
        self.online = online;
        self.notes.extend([Note::State, Note::Stack]);
        if online && self.active && (!self.loaded || self.status == "error") {
            self.load();
        }
    }

    /// Whether its tab shows: it reads the pull request the first time.
    pub fn set_active(&mut self, active: bool) {
        if active == self.active {
            return;
        }
        self.active = active;
        if active && !self.loaded {
            self.load();
        }
    }

    fn reference(&self) -> Json {
        json!({
            "projectId": self.project,
            "host": self.host,
            "repository": self.repository,
            "number": self.number,
        })
    }

    fn with_reference(&self, fields: Json) -> Json {
        let mut input = self.reference();
        if let (Some(input), Json::Object(fields)) = (input.as_object_mut(), fields) {
            input.extend(fields);
        }
        input
    }

    fn call(&mut self, method: &'static str, payload: Json, then: Then) {
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method,
            payload,
            then,
        });
    }

    fn notify(
        &mut self,
        kind: &'static str,
        title: impl Into<String>,
        description: impl Into<String>,
    ) {
        self.effects.push(Effect::Notify {
            kind,
            title: title.into(),
            description: description.into(),
        });
    }

    fn set_status(&mut self, status: &'static str, message: &str) {
        if status == self.status && message == self.message {
            return;
        }
        self.status = status;
        self.message = message.to_owned();
        self.notes.push(Note::State);
    }

    fn set_code(&mut self, status: &'static str, message: &str) {
        if status == self.code_status && message == self.code_message {
            return;
        }
        self.code_status = status;
        self.code_message = message.to_owned();
        self.notes.push(Note::Code);
    }

    fn set_problem(&mut self, problem: &str) {
        if problem == self.problem {
            return;
        }
        self.problem = problem.to_owned();
        self.notes.push(Note::State);
    }

    /// Reads it all again.
    pub fn reload(&mut self) {
        if self.number > 0 {
            self.load();
        }
    }

    fn load(&mut self) {
        if self.number <= 0 || !self.online {
            return;
        }
        self.loaded = true;
        self.generation += 1;
        self.read_detail();
        self.set_code("loading", "");
        self.read_code("", String::new());
    }

    fn read_detail(&mut self) {
        let generation = self.generation;
        if self.status != "ready" {
            self.set_status("loading", "");
        }
        self.call(
            "pullRequests.detail",
            self.reference(),
            Then::Detail { generation },
        );
        self.read_stack();
        self.call(
            "pullRequests.activity",
            self.reference(),
            Then::Activity { generation },
        );
        self.call(
            "pullRequests.filesViewed",
            self.reference(),
            Then::FilesViewed { generation },
        );
    }

    /// Slices are whole files, so each one shows as it lands.
    fn read_code(&mut self, cursor: &str, patch: String) {
        let body = if cursor.is_empty() {
            self.reference()
        } else {
            self.with_reference(json!({"cursor": cursor}))
        };
        self.effects.push(Effect::Post {
            path: DIFF_PATH,
            body,
            then: Then::Code {
                generation: self.generation,
                patch,
            },
        });
    }

    fn read_stack(&mut self) {
        self.call(
            "pullRequests.stack",
            self.reference(),
            Then::Stack {
                generation: self.generation,
            },
        );
    }

    /// Reads the stack again, after it could not be.
    pub fn retry_stack(&mut self) {
        if self.number > 0 {
            self.read_stack();
        }
    }

    /// Marks `path` viewed or not on the host; shown at once, taken back
    /// if the host refuses it.
    pub fn set_viewed(&mut self, path: &str, viewed: bool) {
        if !self.online || self.number <= 0 || self.viewed.contains(path) == viewed {
            return;
        }
        if viewed {
            self.viewed.insert(path.to_owned());
        } else {
            self.viewed.remove(path);
        }
        self.effects.push(Effect::Expand {
            path: path.to_owned(),
            expanded: !viewed,
        });
        self.notes.push(Note::Viewed);
        let input = self.with_reference(json!({"files": [{"path": path, "viewed": viewed}]}));
        self.call(
            "pullRequests.setFilesViewed",
            input,
            Then::Viewed {
                generation: self.generation,
                path: path.to_owned(),
                viewed,
            },
        );
    }

    fn layers(&self) -> &[Json] {
        array(&self.stack, "layers")
    }

    fn unmerged_layers(&self) -> Vec<&Json> {
        self.layers()
            .iter()
            .filter(|l| text(l, "state") != "merged")
            .collect()
    }

    /// The layers a merge here takes: the unmerged ones up to this one.
    fn merge_layers(&self) -> Vec<&Json> {
        let mut layers = Vec::new();
        for layer in self.layers() {
            if text(layer, "state") != "merged" {
                layers.push(layer);
            }
            if int_of(layer, "number") == self.number {
                return layers;
            }
        }
        Vec::new()
    }

    /// What the stack is and what can be done with it; `{}` with none.
    pub fn stack(&self) -> Json {
        let all = self.layers();
        if all.is_empty() {
            return json!({});
        }
        let mut position = 0;
        let layers: Vec<Json> = all
            .iter()
            .enumerate()
            .map(|(at, layer)| {
                let current = int_of(layer, "number") == self.number;
                if current {
                    position = at + 1;
                }
                json!({
                    "number": int_of(layer, "number"),
                    "title": text(layer, "title"),
                    "state": text(layer, "state"),
                    "current": current,
                })
            })
            .collect();
        let ready = |chosen: &[&Json]| {
            !chosen.is_empty()
                && chosen
                    .iter()
                    .all(|l| text(l, "state") == "open" && !text(l, "headSha").is_empty())
        };
        let merging = self.merge_layers();
        let no_drafts = !merging.iter().any(|l| flag(l, "isDraft"));
        let fresh = self.online && !self.stale;
        json!({
            "number": int_of(&self.stack, "number"),
            "base": text(&self.stack, "base"),
            "position": position,
            "size": all.len(),
            "layers": layers,
            "mergeCount": merging.len(),
            "canMerge": fresh && self.may_merge && ready(&merging) && no_drafts,
            "canRebase": fresh && self.may_rebase && ready(&self.unmerged_layers()),
            "stale": self.stale,
            "notice": if self.stale { "Stack data may be stale. We couldn’t refresh it." } else { "" },
        })
    }

    fn merge_methods(&self) -> Vec<String> {
        array(&self.detail, "mergeMethods")
            .iter()
            .filter_map(|m| m.as_str().map(str::to_owned))
            .collect()
    }

    fn requests(count: usize) -> &'static str {
        if count == 1 { "request" } else { "requests" }
    }

    /// Asks to confirm merging this layer and the unmerged ones below it.
    pub fn request_stack_merge(&mut self, method: &str) -> bool {
        let shown = self.stack();
        if !flag(&shown, "canMerge") {
            return false;
        }
        self.stack_method = if method.is_empty() {
            self.merge_methods()
                .into_iter()
                .next()
                .unwrap_or_else(|| "merge".into())
        } else {
            method.to_owned()
        };
        let count = int_of(&shown, "mergeCount") as usize;
        self.confirmation = json!({
            "action": "merge",
            "title": format!("Merge {count} pull {}?", Review::requests(count)),
            "description": format!(
                "Merge #{} and its unmerged layers below into {} using {}. GitHub checks their rules before merging or queueing them and rebases the remaining stack after merging.",
                self.number,
                text(&shown, "base"),
                self.stack_method
            ),
            "confirmLabel": "Merge stack",
        });
        self.notes.push(Note::Stack);
        true
    }

    /// Asks to confirm rebasing the unmerged layers onto the stack's base.
    pub fn request_stack_rebase(&mut self) -> bool {
        let shown = self.stack();
        if !flag(&shown, "canRebase") {
            return false;
        }
        let count = self.unmerged_layers().len();
        self.confirmation = json!({
            "action": "rebase",
            "title": format!("Rebase {count} pull {}?", Review::requests(count)),
            "description": format!(
                "Rebase the remote branches from bottom to top onto {}. This rewrites branch history and may restart checks. If a layer fails, earlier updates remain.",
                text(&shown, "base")
            ),
            "confirmLabel": "Rebase stack",
        });
        self.notes.push(Note::Stack);
        true
    }

    pub fn cancel_stack(&mut self) {
        if self.confirmation.as_object().is_none_or(|c| c.is_empty()) {
            return;
        }
        self.confirmation = json!({});
        self.notes.push(Note::Stack);
    }

    /// Runs what the user confirmed, on the heads they saw: the host
    /// refuses a stack that moved since.
    pub fn confirm_stack(&mut self) {
        if self.confirmation.as_object().is_none_or(|c| c.is_empty()) {
            return;
        }
        let merging = text(&self.confirmation, "action") == "merge";
        self.confirmation = json!({});
        self.notes.push(Note::Stack);
        let layers = if merging {
            self.merge_layers()
        } else {
            self.unmerged_layers()
        };
        let Some(last) = layers.last() else {
            return;
        };
        let heads: Vec<Json> = layers
            .iter()
            .map(|l| {
                json!({
                    "number": l.get("number").cloned().unwrap_or(Json::Null),
                    "headSha": l.get("headSha").cloned().unwrap_or(Json::Null),
                })
            })
            .collect();
        // A merge is asked at this layer, a rebase at the stack's top.
        let number = if merging {
            self.number
        } else {
            int_of(last, "number")
        };
        let mut fields = json!({
            "number": number,
            "stackNumber": self.stack.get("number").cloned().unwrap_or(Json::Null),
            "expectedStackHeads": heads,
            "action": if merging { "merge" } else { "update-branch" },
        });
        if merging {
            fields["mergeMethod"] = json!(self.stack_method);
        } else {
            fields["updateMethod"] = json!("rebase");
        }
        let input = self.with_reference(fields);
        let done = if merging {
            Done::StackMerged
        } else {
            Done::StackRebased
        };
        self.change(
            "pullRequests.runAction",
            input,
            "Stack operation did not complete",
            done,
        );
    }

    /// Merges it with `method` (empty: the first the repository allows).
    pub fn merge(&mut self, method: &str) -> bool {
        if !flag(&self.detail, "canMerge") {
            self.set_problem("This pull request cannot be merged from here.");
            return false;
        }
        let methods = self.merge_methods();
        let chosen = if method.is_empty() {
            methods.first().cloned().unwrap_or_default()
        } else {
            method.to_owned()
        };
        if !chosen.is_empty() && !methods.contains(&chosen) {
            self.set_problem("This repository does not allow that merge method.");
            return false;
        }
        // No method leaves it to the host's default.
        let fields = if chosen.is_empty() {
            json!({"action": "merge"})
        } else {
            json!({"action": "merge", "mergeMethod": chosen})
        };
        let input = self.with_reference(fields);
        self.change(
            "pullRequests.runAction",
            input,
            "Could not merge the pull request",
            Done::Merged,
        )
    }

    pub fn comment(&mut self, body: &str) -> bool {
        if body.trim().is_empty() {
            self.set_problem("A comment cannot be empty.");
            return false;
        }
        let input = self.with_reference(json!({"body": body}));
        self.change(
            "pullRequests.comment",
            input,
            "Could not comment",
            Done::Nothing,
        )
    }

    /// `verdict` is comment, approve or request-changes.
    pub fn submit_review(&mut self, verdict: &str, body: &str) -> bool {
        if !matches!(verdict, "comment" | "approve" | "request-changes") {
            return false;
        }
        // Only an approval may say nothing (the MC's own rule).
        if verdict != "approve" && body.trim().is_empty() {
            self.set_problem("A review needs a summary or at least one comment.");
            return false;
        }
        let input = self.with_reference(json!({"verdict": verdict, "body": body, "comments": []}));
        self.change(
            "pullRequests.submitReview",
            input,
            "Could not submit the review",
            Done::Reviewed(verdict.to_owned()),
        )
    }

    pub fn set_thread_resolved(&mut self, thread_id: &str, resolved: bool) {
        let input = self.with_reference(json!({"threadId": thread_id, "resolved": resolved}));
        let failure = if resolved {
            "Could not resolve the thread"
        } else {
            "Could not reopen the thread"
        };
        self.change(
            "pullRequests.setThreadResolution",
            input,
            failure,
            Done::Nothing,
        );
    }

    /// Sends a change; once it lands `done` runs and the pull request is
    /// read again.
    fn change(&mut self, method: &'static str, input: Json, failure: &str, done: Done) -> bool {
        if self.number <= 0 {
            return false;
        }
        if !self.online {
            self.set_problem("The environment is offline.");
            return false;
        }
        self.set_problem("");
        self.busy += 1;
        self.notes.push(Note::State);
        let then = Then::Change {
            generation: self.generation,
            failure: failure.to_owned(),
            done,
        };
        self.call(method, input, then);
        true
    }

    /// Copies `#N`.
    pub fn copy_number(&mut self) {
        if self.number <= 0 {
            return;
        }
        self.effects
            .push(Effect::CopyNumber(format!("#{}", self.number)));
    }

    pub fn open_on_host(&mut self) {
        let url = text(&self.detail, "url").to_owned();
        if !url.is_empty() {
            self.effects.push(Effect::Open(url));
        }
    }

    /// The MC answered what `then` asked.
    pub fn answer(&mut self, then: Then, result: Result<Json, String>) {
        match then {
            Then::Detail { generation } => {
                if generation != self.generation {
                    return;
                }
                let detail = match result {
                    Ok(detail) => detail,
                    Err(e) => return self.set_status("error", &e),
                };
                self.detail = detail_of(&detail);
                // A permission the host says nothing of is granted.
                let permissions = detail.get("viewerPermissions").filter(|p| p.is_object());
                self.may_merge = viewer_may_merge(&detail);
                self.may_rebase = permissions
                    .is_none_or(|p| p.get("stackRebase").and_then(Json::as_bool).unwrap_or(true));
                self.set_status("ready", "");
                self.notes.extend([Note::Detail, Note::Stack]);
            }
            Then::Activity { generation } => {
                let Ok(activity) = result.as_ref() else {
                    return;
                };
                if generation != self.generation {
                    return;
                }
                self.conversation = array(activity, "comments")
                    .iter()
                    .map(|c| {
                        json!({
                            "id": text(c, "id"),
                            "kind": text(c, "kind"),
                            "author": login(c.get("author")),
                            "body": text(c, "body"),
                            "createdAt": text(c, "createdAt"),
                            "reviewState": text(c, "reviewState"),
                            "path": text(c, "path"),
                        })
                    })
                    .collect();
                self.threads = array(activity, "reviewThreads")
                    .iter()
                    .map(|t| {
                        let comments: Vec<Json> = array(t, "comments")
                            .iter()
                            .map(|c| json!({"author": login(c.get("author")), "body": text(c, "body")}))
                            .collect();
                        json!({
                            "id": text(t, "id"),
                            "path": text(t, "path"),
                            "line": int_of(t, "line"),
                            "resolved": flag(t, "isResolved"),
                            "outdated": flag(t, "isOutdated"),
                            "comments": comments,
                        })
                    })
                    .collect();
                self.notes.push(Note::Detail);
            }
            Then::FilesViewed { generation } => {
                let (Ok(result), true) = (result, generation == self.generation) else {
                    return;
                };
                self.viewed = array(&result, "files")
                    .iter()
                    .filter(|f| text(f, "state") == "viewed")
                    .map(|f| text(f, "path").to_owned())
                    .collect();
                self.effects.push(Effect::FoldViewed);
                self.notes.push(Note::Viewed);
            }
            Then::Stack { generation } => {
                if generation != self.generation {
                    return;
                }
                match result {
                    // What was read before stays, marked as possibly stale.
                    Err(_) => {
                        self.stale = self.stack.as_object().is_some_and(|s| !s.is_empty());
                    }
                    Ok(stack) => {
                        self.stack = if stack.is_object() { stack } else { json!({}) };
                        self.stale = false;
                    }
                }
                self.notes.push(Note::Stack);
            }
            Then::Code { generation, patch } => {
                if generation != self.generation {
                    return;
                }
                let slice = match result {
                    Ok(slice) => slice,
                    Err(e) => return self.set_code("error", &e),
                };
                let mut whole = patch;
                if !whole.is_empty() && !whole.ends_with('\n') {
                    whole.push('\n');
                }
                whole.push_str(text(&slice, "patch"));
                self.effects.push(Effect::Patch(whole.clone()));
                let next = text(&slice, "nextCursor");
                if next.is_empty() {
                    self.set_code("ready", "");
                } else {
                    let next = next.to_owned();
                    self.read_code(&next, whole);
                }
            }
            Then::Viewed {
                generation,
                path,
                viewed,
            } => {
                let Err(e) = result else {
                    return;
                };
                if generation != self.generation {
                    return;
                }
                if viewed {
                    self.viewed.remove(&path);
                } else {
                    self.viewed.insert(path.clone());
                }
                self.effects.push(Effect::Expand {
                    path,
                    expanded: viewed,
                });
                self.notes.push(Note::Viewed);
                self.notify("error", "Could not mark the file viewed", e);
            }
            Then::Change {
                generation,
                failure,
                done,
            } => {
                self.busy = self.busy.saturating_sub(1);
                self.notes.push(Note::State);
                if generation != self.generation {
                    return;
                }
                if let Err(e) = result {
                    self.set_problem(&e);
                    self.notify("error", failure, e);
                    return;
                }
                let number = format!("#{}", self.number);
                match done {
                    Done::Nothing => {}
                    Done::StackMerged => self.notify(
                        "success",
                        "Stack merge request completed",
                        "GitHub merged the stack or added it to its merge queue.",
                    ),
                    Done::StackRebased => self.notify("success", "Stack rebased", ""),
                    Done::Merged => self.notify("success", "Merged", number),
                    Done::Reviewed(verdict) => {
                        let title = match verdict.as_str() {
                            "approve" => "Approved",
                            "request-changes" => "Changes requested",
                            _ => "Review submitted",
                        };
                        self.notify("success", title, number);
                    }
                }
                self.read_detail();
            }
        }
    }

    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
    }

    pub fn take_notes(&mut self) -> Vec<Note> {
        std::mem::take(&mut self.notes)
    }
}

/// A toast: type, title, description.
pub type Notify = Rc<dyn Fn(&Engine, &str, &str, &str)>;
/// A page for the user's browser.
pub type Hand = Rc<dyn Fn(&Engine, &str)>;
/// Text for the clipboard: whether it took it.
pub type Copy = Rc<dyn Fn(&Engine, &str) -> bool>;

struct Inner {
    review: std::cell::RefCell<Review>,
    model: ObjectId,
    mc: Rc<dyn Mc>,
    notify: Notify,
    open: Hand,
    copy: Copy,
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PullRequestReview")
            .field("model", &self.model)
            .finish_non_exhaustive()
    }
}

/// A pull request under review: a review tab.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "PullRequestReview", uncreatable)]
pub struct PullRequestReview {
    /// Its code: a DiffModel of its own, for the whole of its life.
    #[qml(readonly)]
    model: Value,
    /// `host/repository#number`, or "" with none.
    #[qml(readonly, notify)]
    key: Atom,
    #[qml(readonly, notify)]
    number: i32,
    #[qml(readonly, notify)]
    online: bool,
    /// idle, loading, ready or error: the detail's.
    #[qml(readonly, notify)]
    status: Atom,
    #[qml(readonly, notify)]
    message: Atom,
    /// {title, body, url, author, state, stateLabel, branches, labels,
    /// reviewers, mergeability, behindBy, checks, canMerge, mergeMethods};
    /// {} before it is read.
    #[qml(readonly, notify)]
    detail: Value,
    /// [{id, kind, author, body, createdAt, reviewState, path}]
    #[qml(readonly, notify)]
    conversation: Value,
    /// [{id, path, line, resolved, outdated, comments: [{author, body}]}]
    #[qml(readonly, notify)]
    review_threads: Value,
    /// {number, base, position, size, layers, mergeCount, canMerge,
    /// canRebase, stale, notice}; {} outside a stack.
    #[qml(readonly, notify)]
    stack: Value,
    /// {action, title, description, confirmLabel} while a stack merge or
    /// rebase waits to be confirmed; {} otherwise.
    #[qml(readonly, notify)]
    stack_confirmation: Value,
    #[qml(readonly, notify)]
    code_status: Atom,
    #[qml(readonly, notify)]
    code_message: Atom,
    /// The diff's files marked viewed, in its order.
    #[qml(readonly, notify)]
    viewed_paths: Value,
    #[qml(readonly, notify)]
    viewed_count: i32,
    /// A change is on its way to the host.
    #[qml(readonly, notify)]
    busy: bool,
    /// Why the last change was refused, or could not be sent.
    #[qml(readonly, notify)]
    problem: Atom,
    #[qml(skip)]
    inner: Rc<Inner>,
}

fn inner_of(engine: &Engine, obj: ObjectId) -> Option<Rc<Inner>> {
    engine
        .with::<PullRequestReview, _>(obj, |p| p.inner.clone())
        .ok()
}

fn warn(engine: &Engine, result: Result<(), EngineError>) {
    if let Err(e) = result {
        engine.log(
            ljos_engine::LogLevel::Warning,
            "PullRequestReview",
            e.to_string(),
        );
    }
}

impl PullRequestReview {
    /// The review owned by `owner`, asking `mc`; `notify` raises a toast,
    /// `open` hands a page to the browser and `copy` text to the clipboard,
    /// saying whether it took it.
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        mc: Rc<dyn Mc>,
        notify: impl Fn(&Engine, &str, &str, &str) + 'static,
        open: impl Fn(&Engine, &str) + 'static,
        copy: impl Fn(&Engine, &str) -> bool + 'static,
    ) -> Result<ObjectId, EngineError> {
        let model = DiffModel::create(engine, owner)?;
        let inner = Rc::new(Inner {
            review: std::cell::RefCell::new(Review::new()),
            model,
            mc,
            notify: Rc::new(notify),
            open: Rc::new(open),
            copy: Rc::new(copy),
        });
        let object = PullRequestReview {
            model: Value::Object(model),
            key: Atom::new(""),
            number: 0,
            online: false,
            status: Atom::new("idle"),
            message: Atom::new(""),
            detail: Value::Undefined,
            conversation: Value::Undefined,
            review_threads: Value::Undefined,
            stack: Value::Undefined,
            stack_confirmation: Value::Undefined,
            code_status: Atom::new("idle"),
            code_message: Atom::new(""),
            viewed_paths: Value::Undefined,
            viewed_count: 0,
            busy: false,
            problem: Atom::new(""),
            inner,
        };
        let obj = engine.create_native(object, owner)?;
        // A file read again keeps the mark it had.
        engine.connect_by_name(model, "patchChanged", move |engine, _| {
            fold_viewed(engine, obj);
        })?;
        tell(engine, obj, &[Note::Detail, Note::Stack, Note::Viewed]);
        Ok(obj)
    }

    /// The review's DiffModel.
    pub fn model(engine: &Engine, obj: ObjectId) -> Option<ObjectId> {
        Some(inner_of(engine, obj)?.model)
    }

    /// Runs `f` on the review of `obj`, then tells the properties what it
    /// changed and asks the MC and the diff what it said to. None when
    /// `obj` is not live.
    pub fn update<R>(
        engine: &Engine,
        obj: ObjectId,
        f: impl FnOnce(&mut Review) -> R,
    ) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let (result, notes, effects) = {
            let mut review = inner.review.borrow_mut();
            let result = f(&mut review);
            (result, review.take_notes(), review.take_effects())
        };
        tell(engine, obj, &notes);
        for effect in effects {
            run(engine, obj, &inner, effect);
        }
        Some(result)
    }

    /// Reads the review of `obj`. `f` must not call back into it.
    pub fn read<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&Review) -> R) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let review = inner.review.borrow();
        Some(f(&review))
    }
}

/// Folds the files marked viewed, then tells which of the diff's files
/// they are.
fn fold_viewed(engine: &Engine, obj: ObjectId) {
    let Some(inner) = inner_of(engine, obj) else {
        return;
    };
    let viewed: BTreeSet<String> = inner.review.borrow().viewed.clone();
    DiffModel::update(engine, inner.model, |d| {
        for file in 0..d.file_count() {
            if d.path(file).is_some_and(|p| viewed.contains(p)) && d.expanded(file) {
                d.set_expanded(file, false);
            }
        }
    });
    tell(engine, obj, &[Note::Viewed]);
}

fn tell(engine: &Engine, obj: ObjectId, notes: &[Note]) {
    let Some(inner) = inner_of(engine, obj) else {
        return;
    };
    let mut told: Vec<Note> = Vec::new();
    for note in notes {
        if told.contains(note) {
            continue;
        }
        told.push(*note);
        let to_value = |json: Json| json::to_value(engine, &json);
        // Read first, then set: setting may run QML that reads it back.
        let result = match note {
            Note::Target => {
                let (key, number) = {
                    let r = inner.review.borrow();
                    (r.key(), r.number())
                };
                engine
                    .set_internal(obj, PullRequestReview::KEY, Atom::new(&key))
                    .and_then(|()| {
                        engine.set_internal(
                            obj,
                            PullRequestReview::NUMBER,
                            i32::try_from(number).unwrap_or(0),
                        )
                    })
            }
            Note::State => {
                let (online, status, message, busy, problem) = {
                    let r = inner.review.borrow();
                    (
                        r.online(),
                        r.status(),
                        r.message().to_owned(),
                        r.busy(),
                        r.problem().to_owned(),
                    )
                };
                engine
                    .set_internal(obj, PullRequestReview::ONLINE, online)
                    .and_then(|()| {
                        engine.set_internal(obj, PullRequestReview::STATUS, Atom::new(status))
                    })
                    .and_then(|()| {
                        engine.set_internal(obj, PullRequestReview::MESSAGE, Atom::new(&message))
                    })
                    .and_then(|()| engine.set_internal(obj, PullRequestReview::BUSY, busy))
                    .and_then(|()| {
                        engine.set_internal(obj, PullRequestReview::PROBLEM, Atom::new(&problem))
                    })
            }
            Note::Detail => {
                let (detail, conversation, threads) = {
                    let r = inner.review.borrow();
                    (
                        r.detail().clone(),
                        Json::Array(r.conversation().to_vec()),
                        Json::Array(r.review_threads().to_vec()),
                    )
                };
                engine
                    .set_internal(obj, PullRequestReview::DETAIL, to_value(detail))
                    .and_then(|()| {
                        engine.set_internal(
                            obj,
                            PullRequestReview::CONVERSATION,
                            to_value(conversation),
                        )
                    })
                    .and_then(|()| {
                        engine.set_internal(
                            obj,
                            PullRequestReview::REVIEW_THREADS,
                            to_value(threads),
                        )
                    })
            }
            Note::Stack => {
                let (stack, confirmation) = {
                    let r = inner.review.borrow();
                    (r.stack(), r.stack_confirmation().clone())
                };
                engine
                    .set_internal(obj, PullRequestReview::STACK, to_value(stack))
                    .and_then(|()| {
                        engine.set_internal(
                            obj,
                            PullRequestReview::STACK_CONFIRMATION,
                            to_value(confirmation),
                        )
                    })
            }
            Note::Code => {
                let (status, message) = {
                    let r = inner.review.borrow();
                    (r.code_status(), r.code_message().to_owned())
                };
                engine
                    .set_internal(obj, PullRequestReview::CODE_STATUS, Atom::new(status))
                    .and_then(|()| {
                        engine.set_internal(
                            obj,
                            PullRequestReview::CODE_MESSAGE,
                            Atom::new(&message),
                        )
                    })
            }
            Note::Viewed => {
                let paths = DiffModel::read(engine, inner.model, |d| d.paths()).unwrap_or_default();
                let viewed = inner.review.borrow().viewed_of(&paths);
                let count = int(viewed.len());
                let list = Json::Array(viewed.into_iter().map(Json::String).collect());
                engine
                    .set_internal(obj, PullRequestReview::VIEWED_PATHS, to_value(list))
                    .and_then(|()| engine.set_internal(obj, PullRequestReview::VIEWED_COUNT, count))
            }
        };
        warn(engine, result);
    }
}

fn run(engine: &Engine, obj: ObjectId, inner: &Inner, effect: Effect) {
    let answer = move |then: Then| -> crate::mc::Reply {
        Box::new(move |engine, result: Result<Json, McError>| {
            let result = result.map_err(|e| e.message);
            PullRequestReview::update(engine, obj, |r| r.answer(then, result));
        })
    };
    match effect {
        Effect::Call {
            environment,
            method,
            payload,
            then,
        } => inner.mc.call(&environment, method, payload, answer(then)),
        Effect::Post { path, body, then } => inner.mc.post(path, body, answer(then)),
        Effect::Notify {
            kind,
            title,
            description,
        } => (inner.notify)(engine, kind, &title, &description),
        Effect::Open(url) => (inner.open)(engine, &url),
        Effect::CopyNumber(text) => {
            if (inner.copy)(engine, &text) {
                (inner.notify)(engine, "success", "PR number copied", "");
            } else {
                (inner.notify)(engine, "error", "Failed to copy PR number", "");
            }
        }
        Effect::Patch(patch) => {
            DiffModel::update(engine, inner.model, |d| d.set_patch(&patch));
        }
        Effect::Clear => {
            DiffModel::update(engine, inner.model, |d| d.clear());
        }
        Effect::Expand { path, expanded } => {
            DiffModel::update(engine, inner.model, |d| {
                if let Some(file) = d.file_of(&path) {
                    d.set_expanded(file, expanded);
                }
            });
        }
        Effect::FoldViewed => fold_viewed(engine, obj),
    }
}

#[qml_impl]
impl PullRequestReview {
    /// Reads it all again.
    #[qml(invokable)]
    fn reload(cx: &Cx) {
        PullRequestReview::update(cx.engine, cx.this, Review::reload);
    }

    /// Comments on the pull request; false when it was not sent.
    #[qml(invokable)]
    fn comment(cx: &Cx, body: Atom) -> bool {
        PullRequestReview::update(cx.engine, cx.this, |r| r.comment(&body)).unwrap_or(false)
    }

    /// Submits a review: `verdict` is comment, approve or request-changes.
    #[qml(invokable)]
    fn submit_review(cx: &Cx, verdict: Atom, body: Atom) -> bool {
        PullRequestReview::update(cx.engine, cx.this, |r| r.submit_review(&verdict, &body))
            .unwrap_or(false)
    }

    /// Merges it with `method` ("": the first the repository allows).
    #[qml(invokable)]
    fn merge(cx: &Cx, method: Atom) -> bool {
        PullRequestReview::update(cx.engine, cx.this, |r| r.merge(&method)).unwrap_or(false)
    }

    #[qml(invokable)]
    fn request_stack_merge(cx: &Cx, method: Atom) -> bool {
        PullRequestReview::update(cx.engine, cx.this, |r| r.request_stack_merge(&method))
            .unwrap_or(false)
    }

    #[qml(invokable)]
    fn request_stack_rebase(cx: &Cx) -> bool {
        PullRequestReview::update(cx.engine, cx.this, Review::request_stack_rebase).unwrap_or(false)
    }

    #[qml(invokable)]
    fn confirm_stack(cx: &Cx) {
        PullRequestReview::update(cx.engine, cx.this, Review::confirm_stack);
    }

    #[qml(invokable)]
    fn cancel_stack(cx: &Cx) {
        PullRequestReview::update(cx.engine, cx.this, Review::cancel_stack);
    }

    #[qml(invokable)]
    fn retry_stack(cx: &Cx) {
        PullRequestReview::update(cx.engine, cx.this, Review::retry_stack);
    }

    #[qml(invokable)]
    fn set_thread_resolved(cx: &Cx, thread_id: Atom, resolved: bool) {
        PullRequestReview::update(cx.engine, cx.this, |r| {
            r.set_thread_resolved(&thread_id, resolved)
        });
    }

    #[qml(invokable)]
    fn set_viewed(cx: &Cx, path: Atom, viewed: bool) {
        PullRequestReview::update(cx.engine, cx.this, |r| r.set_viewed(&path, viewed));
    }

    #[qml(invokable)]
    fn is_viewed(cx: &Cx, path: Atom) -> bool {
        PullRequestReview::read(cx.engine, cx.this, |r| r.is_viewed(&path)).unwrap_or(false)
    }

    /// Copies `#N`.
    #[qml(invokable)]
    fn copy_number(cx: &Cx) {
        PullRequestReview::update(cx.engine, cx.this, Review::copy_number);
    }

    #[qml(invokable)]
    fn open_on_host(cx: &Cx) {
        PullRequestReview::update(cx.engine, cx.this, Review::open_on_host);
    }
}

#[cfg(test)]
#[path = "pull_request_review_tests.rs"]
mod tests;
