//! `git`, desktop-qt's GitController: the header's git pill for the route's
//! checkout. Publishes `git` in the ShellGitState shape (packages/contracts
//! shell.ts) the GitActions brick draws, from the workspace's `vcs` status,
//! and runs what the brick sends.
//!
//! The recommended action and the menu follow the checkout as the TUI's
//! gitActions.logic.ts decides them (features/source-control/git-actions.feature),
//! named for the host's change requests. Commit, push and pull request run
//! once each through the MC's `gitAction` shape, whose stages update one
//! loading toast, and `git.progress` ({stage, elapsed, hookLine}: the stage,
//! how long the action has run and the last line a hook printed) for the pill,
//! republished once a second while it runs; anything that would land on the
//! default branch waits for `git.defaultBranch`. Pull is `vcs.pull`,
//! Initialize Git `vcs.init`, and Publish repository
//! `sourceControl.publishRepository` from the brick's own dialog
//! (`git.publish` opens it), which walks through the host (with whether it is
//! installed and signed in, from `server.discoverSourceControl`), the
//! repository and a summary to confirm. Actions on another machine of the
//! cluster run there; one that is unreachable says why.
//!
//! Actions: `git.quick`, `git.menu {id}`, `git.commit {message, filePaths?,
//! featureBranch?}`, `git.defaultBranch {choice: continue | featureBranch}`,
//! `git.init`, `git.publish`, `git.publish.cancel`, `git.publish.submit
//! {provider, repository, visibility, remoteName, protocol}`, `git.refresh`.

use ljos::prelude::{Engine, ObjectId};
use serde_json::json;

use crate::bridge::Bridge;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::thread_menu::ThreadMenu;
use crate::controllers::toasts::{Action, Toasts};
use crate::controllers::workspace;
use crate::json::Json;
use crate::mc::{Frame, Mc, McError, SubId};
use crate::store;

/// How long a finished action's result stays (GIT_ACTION_SUCCESS_VISIBLE_MS).
const RESULT_MS: i64 = 10_000;
const NO_REASON: &str = "An error occurred.";

type Status = serde_json::Map<String, Json>;

fn text(row: &Json, key: &str) -> String {
    row.get(key)
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn count(status: &Status, key: &str) -> i64 {
    status
        .get(key)
        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
        .unwrap_or(0)
}

fn flag(status: &Status, key: &str) -> bool {
    status.get(key).and_then(Json::as_bool).unwrap_or(false)
}

/// Effect's Option on the wire: {_tag: "Some", value}.
fn some(option: Option<&Json>) -> String {
    option.map_or_else(String::new, |o| text(o, "value"))
}

/// What the checkout's host calls a change request (HalC2.SourceControl).
struct Terms {
    short_label: &'static str,
    singular: &'static str,
}

fn terms(status: &Status) -> Terms {
    let kind = status
        .get("sourceControlProvider")
        .map_or_else(String::new, |p| text(p, "kind"));
    match kind.as_str() {
        "gitlab" => Terms {
            short_label: "MR",
            singular: "merge request",
        },
        "unknown" => Terms {
            short_label: "change request",
            singular: "change request",
        },
        _ => Terms {
            short_label: "PR",
            singular: "pull request",
        },
    }
}

fn open_pr(status: &Status) -> bool {
    status
        .get("pr")
        .is_some_and(|pr| text(pr, "state") == "open")
}

fn has_branch(status: &Status) -> bool {
    status
        .get("refName")
        .and_then(Json::as_str)
        .is_some_and(|s| !s.is_empty())
}

fn ahead_of_default(status: &Status) -> i64 {
    match status.get("aheadOfDefaultCount") {
        Some(v) if v.is_number() => count(status, "aheadOfDefaultCount"),
        _ => count(status, "aheadCount"),
    }
}

fn includes_commit_step(action: &str) -> bool {
    matches!(action, "commit" | "commit_push" | "commit_push_pr")
}

/// The default-branch question (resolveDefaultBranchActionDialogCopy).
fn default_branch_copy(action: &str, branch: &str, includes_commit: bool, terms: &Terms) -> Json {
    let suffix = format!(
        " on \"{branch}\". You can continue on this ref or create a feature ref and run the same action there."
    );
    let (title, description, continue_label) = if matches!(action, "push" | "commit_push") {
        if includes_commit {
            (
                "Commit & push to default ref?".to_owned(),
                format!("This action will commit and push changes{suffix}"),
                format!("Commit & push to {branch}"),
            )
        } else {
            (
                "Push to default ref?".to_owned(),
                format!("This action will push local commits{suffix}"),
                format!("Push to {branch}"),
            )
        }
    } else if includes_commit {
        (
            format!(
                "Commit, push & create {} from default ref?",
                terms.short_label
            ),
            format!(
                "This action will commit, push, and create a {}{suffix}",
                terms.singular
            ),
            format!("Commit, push & create {}", terms.short_label),
        )
    } else {
        (
            format!("Push & create {} from default ref?", terms.short_label),
            format!(
                "This action will push local commits and create a {}{suffix}",
                terms.singular
            ),
            format!("Push & create {}", terms.short_label),
        )
    };
    json!({
        "title": title,
        "description": description,
        "continueLabel": continue_label,
        "featureBranchLabel": "Checkout feature branch & continue",
    })
}

/// What the pill's main button does.
#[derive(Clone, Debug, PartialEq)]
struct Quick {
    label: String,
    /// run_action, run_pull, open_publish, open_pr or show_hint.
    kind: &'static str,
    /// The stacked action of run_action.
    action: &'static str,
    /// Why it cannot run.
    hint: String,
}

impl Quick {
    fn run(label: impl Into<String>, action: &'static str) -> Quick {
        Quick {
            label: label.into(),
            kind: "run_action",
            action,
            hint: String::new(),
        }
    }

    fn of(label: impl Into<String>, kind: &'static str) -> Quick {
        Quick {
            label: label.into(),
            kind,
            action: "",
            hint: String::new(),
        }
    }

    fn hint(label: impl Into<String>, hint: impl Into<String>) -> Quick {
        Quick {
            label: label.into(),
            kind: "show_hint",
            action: "",
            hint: hint.into(),
        }
    }
}

/// resolveGitQuickAction (apps/tui/src/gitActions.logic.ts), in the host's
/// terms. `busy` while an action or a pull runs.
fn quick_action(status: Option<&Status>, busy: bool) -> Quick {
    if busy {
        return Quick::hint("Commit", "Git action in progress.");
    }
    let Some(s) = status else {
        return Quick::hint("Commit", "Git status is unavailable.");
    };
    let t = terms(s);
    let changes = flag(s, "hasWorkingTreeChanges");
    let pr = open_pr(s);
    let ahead = count(s, "aheadCount") > 0;
    let behind = count(s, "behindCount") > 0;
    let upstream = flag(s, "hasUpstream");
    let remote = flag(s, "hasPrimaryRemote");
    let default_ref = flag(s, "isDefaultRef");
    let view_pr = || Quick::of(format!("View {}", t.short_label), "open_pr");
    let push_and_create = || Quick::run(format!("Push & create {}", t.short_label), "create_pr");

    if !has_branch(s) {
        return Quick::hint(
            "Commit",
            format!(
                "Create and checkout a ref before pushing or opening a {}.",
                t.singular
            ),
        );
    }
    if changes {
        if !upstream && !remote {
            return Quick::run("Commit", "commit");
        }
        if pr || default_ref {
            return Quick::run("Commit & push", "commit_push");
        }
        return Quick::run(
            format!("Commit, push & {}", t.short_label),
            "commit_push_pr",
        );
    }
    if !upstream {
        if !remote {
            if pr && !ahead {
                return view_pr();
            }
            return Quick::of("Publish repository", "open_publish");
        }
        if !ahead {
            if pr {
                return view_pr();
            }
            return Quick::hint("Push", "No local commits to push.");
        }
        if pr || default_ref {
            return Quick::run("Push", "push");
        }
        return push_and_create();
    }
    if ahead && behind {
        return Quick::hint(
            "Sync ref",
            "Branch has diverged from upstream. Rebase/merge first.",
        );
    }
    if behind {
        return Quick::of("Pull", "run_pull");
    }
    if ahead {
        if pr || default_ref {
            return Quick::run("Push", "push");
        }
        return push_and_create();
    }
    if pr {
        return view_pr();
    }
    if ahead_of_default(s) > 0 && !default_ref {
        return Quick::run(format!("Create {}", t.short_label), "create_pr");
    }
    Quick::hint("Commit", "Branch is up to date. No action needed.")
}

/// Why a menu entry cannot run (menuItemDisabledHint).
fn menu_reason(status: Option<&Status>, busy: bool, id: &str) -> String {
    if busy {
        return "Git action in progress.".into();
    }
    let empty = Status::new();
    let s = status.unwrap_or(&empty);
    let t = terms(s);
    if id == "commit" {
        return "No uncommitted changes.".into();
    }
    let behind = count(s, "behindCount") > 0;
    if id == "push" {
        return if behind {
            "Pull or rebase before pushing."
        } else if !has_branch(s) {
            "Checkout a branch before pushing."
        } else if !flag(s, "hasPrimaryRemote") {
            "Publish the repository before pushing."
        } else {
            "No local commits to push."
        }
        .into();
    }
    if behind {
        return format!("Pull or rebase before creating a {}.", t.short_label);
    }
    if !has_branch(s) {
        return format!("Checkout a branch before creating a {}.", t.short_label);
    }
    if flag(s, "hasWorkingTreeChanges") {
        return format!("Commit changes before creating a {}.", t.short_label);
    }
    format!("No commits are ready for a {}.", t.short_label)
}

/// buildGitMenuItems (apps/tui/src/gitActions.logic.ts): commit, push, and
/// creating or viewing the change request; only commit without a remote.
/// Each is {id, label, disabledReason (null when it can run)}.
fn menu_items(status: Option<&Status>, busy: bool) -> Vec<Json> {
    let Some(s) = status else { return Vec::new() };
    let t = terms(s);
    let changes = flag(s, "hasWorkingTreeChanges");
    let pr = open_pr(s);
    let behind = count(s, "behindCount") > 0;
    let remote_ready = flag(s, "hasUpstream") || flag(s, "hasPrimaryRemote");
    let can_commit = !busy && changes;
    let can_push = !busy && has_branch(s) && !behind && count(s, "aheadCount") > 0 && remote_ready;
    let can_create_pr = !busy
        && has_branch(s)
        && !changes
        && !pr
        && ahead_of_default(s) > 0
        && !behind
        && remote_ready;
    let item = |id: &str, label: String, enabled: bool| {
        json!({
            "id": id,
            "label": label,
            "disabledReason": if enabled { Json::Null } else { json!(menu_reason(status, busy, id)) },
        })
    };
    let mut items = vec![item("commit", "Commit".into(), can_commit)];
    if !flag(s, "hasPrimaryRemote") {
        return items;
    }
    items.push(item("push", "Push".into(), can_push));
    items.push(if pr {
        item("pr", format!("View {}", t.short_label), !busy)
    } else {
        item("pr", format!("Create {}", t.short_label), can_create_pr)
    });
    items
}

/// The hosts the publish dialog offers.
const OFFERED: [(&str, &str); 2] = [("github", "GitHub"), ("gitlab", "GitLab")];

/// The dialog's hosts: [{value, label, ready, hint, account}], `hint` saying
/// how to make a host ready. `answered` once the MC has said which are
/// installed; until then none is ready.
fn publish_hosts(discovered: &[Json], answered: bool) -> Vec<Json> {
    let nullable = |s: String| if s.is_empty() { Json::Null } else { json!(s) };
    OFFERED
        .iter()
        .map(|(kind, name)| {
            let found = discovered.iter().find(|p| text(p, "kind") == *kind);
            let label = found
                .map(|f| text(f, "label"))
                .filter(|l| !l.is_empty())
                .unwrap_or_else(|| (*name).to_owned());
            let auth = found.and_then(|f| f.get("auth")).cloned().unwrap_or(Json::Null);
            let hint = if !answered {
                format!("Checking {label}...")
            } else if let Some(found) = found {
                if text(found, "status") != "available" {
                    let mut hint = some(found.get("installHint"));
                    if hint.is_empty() {
                        hint = text(found, "installHint");
                    }
                    if hint.is_empty() {
                        hint = format!(
                            "{label} is not installed. Open Settings -> Source Control for setup guidance."
                        );
                    }
                    hint
                } else if text(&auth, "status") == "unauthenticated" {
                    let hint = some(auth.get("detail"));
                    if hint.is_empty() {
                        format!(
                            "{label} is not authenticated. Open Settings -> Source Control for setup guidance."
                        )
                    } else {
                        hint
                    }
                } else {
                    String::new()
                }
            } else {
                "Provider status unavailable. Open Settings -> Source Control and rescan.".into()
            };
            json!({
                "value": kind,
                "label": label,
                "ready": hint.is_empty(),
                "hint": nullable(hint),
                "account": nullable(some(auth.get("account"))),
            })
        })
        .collect()
}

/// A stacked action waiting for the answer to the default-branch question.
#[derive(Clone, Debug)]
struct Pending {
    action: String,
    branch: String,
    includes_commit: bool,
    message: String,
    file_paths: Option<Vec<String>>,
}

/// The publish dialog, while open.
struct Publishing {
    busy: bool,
    error: String,
    hosts: Vec<Json>,
}

pub struct Git {
    bridge: Bridge,
    me: Me<Git>,
    mc: std::rc::Rc<dyn Mc>,
    active: bool,
    pulling: bool,
    init_pending: bool,
    /// The running stacked action: its `gitAction` subscription, and which
    /// run it is, so a frame of an earlier one is ignored.
    action: Option<SubId>,
    run_id: u64,
    /// The toast that shows its stage.
    progress_toast: String,
    stage: String,
    started_at: Option<ljos::prelude::Time>,
    hook_line: String,
    /// Redraws the elapsed time while an action runs.
    tick: Option<ObjectId>,
    pending: Option<Pending>,
    publishing: Option<Publishing>,
}

fn toast(
    engine: &Engine,
    kind: &str,
    title: &str,
    description: &str,
    action: Option<Action>,
    timeout_ms: i64,
) -> String {
    controller::with::<Toasts, _>(engine, |toasts, engine| {
        toasts.show(engine, kind, title, description, action, timeout_ms)
    })
    .unwrap_or_default()
}

fn dismiss_toast(engine: &Engine, id: &str) {
    controller::with::<Toasts, _>(engine, |toasts, engine| toasts.dismiss(engine, id));
}

fn reason(error: &McError) -> String {
    if error.message.is_empty() {
        NO_REASON.into()
    } else {
        error.message.clone()
    }
}

impl Controller for Git {
    fn new(init: Init<'_, Self>) -> Self {
        Git {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            active: false,
            pulling: false,
            init_pending: false,
            action: None,
            run_id: 0,
            progress_toast: String::new(),
            stage: String::new(),
            started_at: None,
            hook_line: String::new(),
            tick: None,
            pending: None,
            publishing: None,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.active {
            return;
        }
        self.active = true;
        let me = self.me.clone();
        workspace::on_git_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
        let me = self.me.clone();
        workspace::on_place_changed(engine, move |engine| {
            me.run(engine, |c, engine| {
                // A question or dialog about another checkout does not follow
                // the route.
                c.pending = None;
                c.publishing = None;
                c.publish(engine);
            });
        });
        // A stacked action that lost its connection is not resent: the MC
        // would run it a second time.
        let me = self.me.clone();
        self.mc.on_ready_changed(Box::new(move |engine, ready| {
            if ready {
                return;
            }
            me.run(engine, |c, engine| {
                if c.action.is_none() {
                    return;
                }
                c.finish_action(engine);
                toast(
                    engine,
                    "error",
                    "Action failed",
                    "The connection to the MC dropped while the action ran.",
                    None,
                    0,
                );
            });
        }));
        // Everything online or offline the pill shows follows the store too.
        let me = self.me.clone();
        store::on_changed(engine, move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
        self.publish(engine);
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !self.active || !action.starts_with("git.") {
            return false;
        }
        let ready = workspace::place(engine).is_some_and(|p| {
            !p.cwd().is_empty() && store::with(engine, |s| s.environment_online(&p.environment_id))
        });
        if !ready {
            return true;
        }
        let string = |key: &str| text(payload, key);
        match action {
            "git.quick" => self.run_quick(engine),
            "git.menu" => self.run_menu(engine, &string("id")),
            "git.commit" => {
                let file_paths = payload
                    .get("filePaths")
                    .and_then(Json::as_array)
                    .map(|paths| {
                        paths
                            .iter()
                            .filter_map(Json::as_str)
                            .map(str::to_owned)
                            .collect()
                    });
                let feature_branch = payload
                    .get("featureBranch")
                    .and_then(Json::as_bool)
                    .unwrap_or(false);
                self.run(
                    engine,
                    "commit",
                    string("message").trim(),
                    file_paths,
                    feature_branch,
                    feature_branch,
                );
            }
            "git.defaultBranch" => {
                let Some(pending) = self.pending.take() else {
                    return true;
                };
                match string("choice").as_str() {
                    "continue" => self.run(
                        engine,
                        &pending.action,
                        &pending.message,
                        pending.file_paths,
                        false,
                        true,
                    ),
                    "featureBranch" => self.run(
                        engine,
                        &pending.action,
                        &pending.message,
                        pending.file_paths,
                        true,
                        true,
                    ),
                    _ => self.publish(engine),
                }
            }
            "git.init" => self.init(engine),
            "git.publish" => self.open_publish(engine),
            "git.publish.cancel" => {
                if self.publishing.as_ref().is_some_and(|p| !p.busy) {
                    self.publishing = None;
                }
                self.publish(engine);
            }
            "git.publish.submit" => self.submit_publish(engine, payload),
            "git.refresh" => workspace::refresh_git(engine),
            _ => {}
        }
        true
    }
}

impl Git {
    fn busy(&self) -> bool {
        self.action.is_some() || self.pulling
    }

    /// The checkout's local and remote status as one (VcsStatusResult); none
    /// before the first local status.
    fn status(&self, engine: &Engine) -> Option<Status> {
        let git = workspace::git(engine)?;
        if git.local.is_empty() {
            return None;
        }
        let mut status = git.local;
        let remote = git.remote;
        let remote_flag = |key: &str| remote.get(key).and_then(Json::as_bool).unwrap_or(false);
        let remote_count = |key: &str| {
            remote
                .get(key)
                .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
                .unwrap_or(0)
        };
        status.insert("hasUpstream".into(), json!(remote_flag("hasUpstream")));
        status.insert("aheadCount".into(), json!(remote_count("aheadCount")));
        status.insert("behindCount".into(), json!(remote_count("behindCount")));
        status.insert(
            "pr".into(),
            remote
                .get("pr")
                .filter(|pr| pr.is_object())
                .cloned()
                .unwrap_or(Json::Null),
        );
        if let Some(ahead) = remote.get("aheadOfDefaultCount") {
            status.insert("aheadOfDefaultCount".into(), ahead.clone());
        }
        Some(status)
    }

    fn publish(&self, engine: &Engine) {
        if !self.active {
            return;
        }
        let place = workspace::place(engine);
        // An unreachable machine says why when the checkout's status is
        // followed.
        let unreachable = workspace::git_error(engine);
        if let Some(p) = &place
            && (!store::with(engine, |s| s.environment_online(&p.environment_id))
                || !unreachable.is_empty())
        {
            let mut git = json!({"available": false});
            if !unreachable.is_empty() {
                git["unavailableReason"] = json!(unreachable);
            }
            self.bridge.publish(engine, "git", git);
            return;
        }
        if place.as_ref().is_none_or(|p| p.cwd().is_empty()) {
            self.bridge
                .publish(engine, "git", json!({"available": false}));
            return;
        }
        let current = self.status(engine);
        let empty = Status::new();
        let s = current.as_ref().unwrap_or(&empty);
        let action = quick_action(current.as_ref(), self.busy());
        let mut hints = Vec::new();
        if current.is_some() && flag(s, "isRepo") && !has_branch(s) {
            hints.push(format!(
                "Detached HEAD: check out a branch to push or open a {}.",
                terms(s).singular
            ));
        }
        if count(s, "behindCount") > 0 {
            hints.push(format!(
                "Behind upstream by {} \u{2014} pull or rebase before pushing.",
                count(s, "behindCount")
            ));
        }
        let files: Vec<Json> = s
            .get("workingTree")
            .and_then(|w| w.get("files"))
            .and_then(Json::as_array)
            .map(|files| {
                files
                    .iter()
                    .map(|file| {
                        json!({
                            "path": text(file, "path"),
                            "insertions": file.get("insertions").and_then(Json::as_i64).unwrap_or(0),
                            "deletions": file.get("deletions").and_then(Json::as_i64).unwrap_or(0),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        let pending = self.pending.as_ref().map_or(Json::Null, |p| {
            default_branch_copy(&p.action, &p.branch, p.includes_commit, &terms(s))
        });
        // The elapsed time of the running action.
        let progress = match (self.action, self.started_at) {
            (Some(_), Some(started)) => {
                let seconds = engine.now().saturating_since(started).as_secs();
                json!({
                    "stage": self.stage,
                    "elapsed": if seconds < 60 {
                        format!("{seconds}s")
                    } else {
                        format!("{}m {}s", seconds / 60, seconds % 60)
                    },
                    "hookLine": if self.hook_line.is_empty() { Json::Null } else { json!(self.hook_line) },
                })
            }
            _ => Json::Null,
        };
        let publishing = self.publishing.as_ref().map_or(Json::Null, |p| {
            json!({
                "busy": p.busy,
                "error": if p.error.is_empty() { Json::Null } else { json!(p.error) },
                "hosts": p.hosts,
            })
        });
        self.bridge.publish(
            engine,
            "git",
            json!({
                "available": true,
                // Taken for a repository until the MC says otherwise, so
                // Initialize Git does not flash.
                "isRepo": if current.is_some() { flag(s, "isRepo") } else { true },
                "busy": self.busy(),
                "initPending": self.init_pending,
                "quickAction": {
                    "label": action.label,
                    "disabledReason": if action.kind == "show_hint" { json!(action.hint) } else { Json::Null },
                    "kind": action.kind,
                },
                "menu": menu_items(current.as_ref(), self.busy()),
                "canPublish": current.is_some() && flag(s, "isRepo") && !flag(s, "hasPrimaryRemote"),
                "hints": hints,
                "branch": if current.is_some() && has_branch(s) { json!(text(&Json::Object(s.clone()), "refName")) } else { Json::Null },
                "isDefaultRef": flag(s, "isDefaultRef"),
                "files": files,
                "pendingDefaultBranch": pending,
                "publishing": publishing,
                "progress": progress,
            }),
        );
    }

    fn run_quick(&mut self, engine: &Engine) {
        let current = self.status(engine);
        let action = quick_action(current.as_ref(), self.busy());
        match action.kind {
            "run_action" => self.run(engine, action.action, "", None, false, false),
            "run_pull" => self.pull(engine),
            "open_publish" => self.open_publish(engine),
            "open_pr" => self.open_pull_request(engine),
            _ => {
                toast(engine, "info", &action.label, &action.hint, None, 0);
            }
        }
    }

    /// "commit" opens the brick's dialog, which comes back as `git.commit`.
    fn run_menu(&mut self, engine: &Engine, id: &str) {
        let current = self.status(engine);
        let menu = menu_items(current.as_ref(), self.busy());
        for item in menu {
            if text(&item, "id") != id || !item["disabledReason"].is_null() {
                continue;
            }
            if id == "push" {
                self.run(engine, "push", "", None, false, false);
            } else if id == "pr" {
                if current.as_ref().is_some_and(open_pr) {
                    self.open_pull_request(engine);
                } else {
                    self.run(engine, "create_pr", "", None, false, false);
                }
            }
            return;
        }
    }

    fn open_pull_request(&self, engine: &Engine) {
        let url = self
            .status(engine)
            .and_then(|s| s.get("pr").map(|pr| text(pr, "url")))
            .unwrap_or_default();
        if !url.is_empty() {
            self.bridge.open_external(engine, &url);
        }
    }

    /// A stacked action; asks first when it would land on the default branch
    /// (`confirmed` when it has been asked).
    fn run(
        &mut self,
        engine: &Engine,
        action: &str,
        message: &str,
        file_paths: Option<Vec<String>>,
        feature_branch: bool,
        confirmed: bool,
    ) {
        if self.busy() {
            return;
        }
        let current = self.status(engine);
        let branch = current
            .as_ref()
            .filter(|s| has_branch(s))
            .map(|s| {
                s.get("refName")
                    .and_then(Json::as_str)
                    .unwrap_or_default()
                    .to_owned()
            })
            .unwrap_or_default();
        let default_ref =
            !feature_branch && current.as_ref().is_some_and(|s| flag(s, "isDefaultRef"));
        let lands_on_default = matches!(
            action,
            "push" | "create_pr" | "commit_push" | "commit_push_pr"
        );
        if !confirmed && default_ref && lands_on_default && !branch.is_empty() {
            let includes_commit = includes_commit_step(action)
                && (action == "commit"
                    || current
                        .as_ref()
                        .is_some_and(|s| flag(s, "hasWorkingTreeChanges")));
            self.pending = Some(Pending {
                action: action.to_owned(),
                branch,
                includes_commit,
                message: message.to_owned(),
                file_paths,
            });
            self.publish(engine);
            return;
        }
        let Some(place) = workspace::place(engine) else {
            return;
        };
        let mut input = json!({
            "actionId": hal_c2_mc::new_uuid(),
            "cwd": place.cwd(),
            "action": action,
        });
        if !message.is_empty() {
            input["commitMessage"] = json!(message);
        }
        if feature_branch {
            input["featureBranch"] = json!(true);
        }
        if let Some(paths) = file_paths {
            input["filePaths"] = json!(paths);
        }
        // A pull request the action opens is linked to the thread it ran
        // beside; a draft has no thread on the MC yet.
        if place.draft_id.is_empty() {
            input["threadId"] = json!(place.thread_id);
        } else {
            input["projectId"] = json!(place.project_id);
        }
        self.stage = "Starting source control action...".into();
        self.started_at = Some(engine.now());
        self.hook_line.clear();
        self.start_tick(engine);
        self.progress_toast = toast(engine, "loading", &self.stage, "", None, 0);
        self.run_id += 1;
        let run_id = self.run_id;
        let me = self.me.clone();
        let id = self.mc.subscribe(
            json!({"type": "gitAction", "environment": place.environment_id, "input": input}),
            Box::new(move |engine, frame| {
                let frame = frame.clone();
                me.run(engine, move |c, engine| {
                    if c.run_id == run_id && c.action.is_some() {
                        c.on_action_frame(engine, &frame);
                    }
                });
            }),
            None,
        );
        self.action = Some(id);
        self.publish(engine);
    }

    fn start_tick(&mut self, engine: &Engine) {
        self.stop_tick(engine);
        let me = self.me.clone();
        self.tick = controller::every(engine, None, 1000, move |engine| {
            me.run(engine, |c, engine| c.publish(engine));
        });
    }

    fn stop_tick(&mut self, engine: &Engine) {
        if let Some(tick) = self.tick.take() {
            controller::stop_timer(engine, tick);
        }
    }

    fn on_action_frame(&mut self, engine: &Engine, frame: &Frame) {
        let frame = Json::Object(frame.clone());
        let kind = text(&frame, "t");
        if kind == "error" {
            self.finish_action(engine);
            let description = frame
                .get("reason")
                .map(|r| r.as_str().map_or_else(|| r.to_string(), str::to_owned))
                .unwrap_or_default();
            toast(engine, "error", "Action failed", &description, None, 0);
            return;
        }
        if kind != "gitAction" {
            return;
        }
        let event = frame.get("event").cloned().unwrap_or(Json::Null);
        match text(&event, "kind").as_str() {
            "phase_started" => {
                let label = text(&event, "label");
                if !label.is_empty() && label != "Running source control action" {
                    self.stage = label;
                }
                self.update_toast(engine, "");
                self.publish(engine);
            }
            "hook_output" => {
                let output = text(&event, "text");
                let last = output.split('\n').rfind(|line| !line.is_empty());
                if let Some(line) = last {
                    self.hook_line = line.trim().to_owned();
                    let hook = self.hook_line.clone();
                    self.update_toast(engine, &hook);
                    self.publish(engine);
                }
            }
            "action_failed" => {
                self.finish_action(engine);
                let remedy = self.failure_remedy(&event);
                toast(
                    engine,
                    "error",
                    "Action failed",
                    &text(&event, "message"),
                    remedy,
                    0,
                );
            }
            "action_finished" => {
                let result = event.get("result").cloned().unwrap_or(Json::Null);
                self.finish_action(engine);
                self.sync_branch(engine, &result);
                let shown = result.get("toast").cloned().unwrap_or(Json::Null);
                let cta = shown.get("cta").cloned().unwrap_or(Json::Null);
                let next = match text(&cta, "kind").as_str() {
                    "open_pr" => {
                        let url = text(&cta, "url");
                        let bridge = self.bridge;
                        Some(Action::new(text(&cta, "label"), move |engine| {
                            bridge.open_external(engine, &url);
                        }))
                    }
                    "run_action" => {
                        let next = cta
                            .get("action")
                            .map_or_else(String::new, |a| text(a, "kind"));
                        let me = self.me.clone();
                        Some(Action::new(text(&cta, "label"), move |engine| {
                            let next = next.clone();
                            me.run(engine, move |c, engine| {
                                let next = next.clone();
                                c.run(engine, &next, "", None, false, false);
                            });
                        }))
                    }
                    _ => None,
                };
                toast(
                    engine,
                    "success",
                    &text(&shown, "title"),
                    &text(&shown, "description"),
                    next,
                    RESULT_MS,
                );
            }
            _ => {}
        }
    }

    /// A failure with a known remedy offers it (GitActionFailureCta): the page
    /// that fixes it, or the command that does, copied while the failure stays
    /// up to read.
    fn failure_remedy(&self, event: &Json) -> Option<Action> {
        let cta = event.get("cta").cloned().unwrap_or(Json::Null);
        match text(&cta, "kind").as_str() {
            "open_url" => {
                let url = text(&cta, "url");
                let bridge = self.bridge;
                Some(Action::new(text(&cta, "label"), move |engine| {
                    bridge.open_external(engine, &url);
                }))
            }
            "copy_command" => {
                let command = text(&cta, "command");
                Some(
                    Action::new(text(&cta, "label"), move |engine| {
                        controller::with::<ThreadMenu, _>(engine, |menu, engine| {
                            menu.copy(
                                engine,
                                &command,
                                "Command copied",
                                "Failed to copy the command",
                            )
                        });
                    })
                    .keeping_toast(),
                )
            }
            _ => None,
        }
    }

    fn update_toast(&self, engine: &Engine, description: &str) {
        controller::with::<Toasts, _>(engine, |toasts, engine| {
            toasts.update(engine, &self.progress_toast, &self.stage, description);
        });
    }

    fn finish_action(&mut self, engine: &Engine) {
        if let Some(id) = self.action.take() {
            self.mc.unsubscribe(id);
        }
        self.stop_tick(engine);
        self.started_at = None;
        if !self.progress_toast.is_empty() {
            dismiss_toast(engine, &self.progress_toast);
        }
        self.progress_toast.clear();
        workspace::refresh_git(engine);
        self.publish(engine);
    }

    /// A branch the action made is the thread's (or the draft's) from now on.
    fn sync_branch(&self, engine: &Engine, result: &Json) {
        let Some(branch) = result.get("branch") else {
            return;
        };
        let name = text(branch, "name");
        if text(branch, "status") != "created" || name.is_empty() {
            return;
        }
        let Some(place) = workspace::place(engine) else {
            return;
        };
        if !place.draft_id.is_empty() {
            let mut checkout = workspace::checkout(engine, &place.draft_id);
            checkout.branch = Some(name);
            workspace::set_checkout(engine, &place.draft_id, checkout);
            return;
        }
        self.mc.dispatch_command(
            &place.environment_id,
            json!({
                "type": "thread.metadata.update",
                "threadId": place.thread_id,
                "branch": name,
            }),
            Box::new(|_, _| {}),
        );
    }

    fn pull(&mut self, engine: &Engine) {
        if self.busy() {
            return;
        }
        let Some(place) = workspace::place(engine) else {
            return;
        };
        self.pulling = true;
        let shown = toast(engine, "loading", "Pulling latest changes...", "", None, 0);
        self.publish(engine);
        let me = self.me.clone();
        self.mc.call(
            &place.environment_id,
            "vcs.pull",
            json!({"cwd": place.cwd()}),
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    c.pulling = false;
                    dismiss_toast(engine, &shown);
                    match result {
                        Err(error) => {
                            toast(engine, "error", "Pull failed", &reason(&error), None, 0);
                        }
                        Ok(pulled) => {
                            let name = text(&pulled, "refName");
                            if text(&pulled, "status") == "pulled" {
                                let upstream = text(&pulled, "upstreamRef");
                                let upstream = if upstream.is_empty() {
                                    "upstream".to_owned()
                                } else {
                                    upstream
                                };
                                toast(
                                    engine,
                                    "success",
                                    "Pulled",
                                    &format!("Updated {name} from {upstream}"),
                                    None,
                                    RESULT_MS,
                                );
                            } else {
                                toast(
                                    engine,
                                    "success",
                                    "Already up to date",
                                    &format!("{name} is already synchronized."),
                                    None,
                                    RESULT_MS,
                                );
                            }
                        }
                    }
                    workspace::refresh_git(engine);
                    c.publish(engine);
                });
            }),
        );
    }

    fn init(&mut self, engine: &Engine) {
        if self.init_pending {
            return;
        }
        let Some(place) = workspace::place(engine) else {
            return;
        };
        self.init_pending = true;
        self.publish(engine);
        let me = self.me.clone();
        self.mc.call(
            &place.environment_id,
            "vcs.init",
            json!({"cwd": place.cwd()}),
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    c.init_pending = false;
                    if let Err(error) = result {
                        controller::with::<Toasts, _>(engine, |toasts, engine| {
                            toasts.error(engine, "Git initialization failed", &error.message);
                        });
                    }
                    workspace::refresh_git(engine);
                    c.publish(engine);
                });
            }),
        );
    }

    /// Opens the publish dialog and asks the MC which hosts are ready. The
    /// dialog stays open with the MC's reason when publishing fails.
    fn open_publish(&mut self, engine: &Engine) {
        self.publishing = Some(Publishing {
            busy: false,
            error: String::new(),
            hosts: publish_hosts(&[], false),
        });
        self.publish(engine);
        let Some(place) = workspace::place(engine) else {
            return;
        };
        let me = self.me.clone();
        self.mc.call(
            &place.environment_id,
            "server.discoverSourceControl",
            json!({}),
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| {
                    let Some(publishing) = &mut c.publishing else {
                        return;
                    };
                    // A refusal reads as no host found: each says to rescan.
                    let discovered = result
                        .ok()
                        .and_then(|r| r.get("sourceControlProviders").cloned())
                        .and_then(|p| p.as_array().cloned())
                        .unwrap_or_default();
                    publishing.hosts = publish_hosts(&discovered, true);
                    c.publish(engine);
                });
            }),
        );
    }

    fn submit_publish(&mut self, engine: &Engine, args: &Json) {
        let Some(publishing) = &mut self.publishing else {
            return;
        };
        if publishing.busy {
            return;
        }
        let repository = text(args, "repository").trim().to_owned();
        let named = repository
            .split_once('/')
            .is_some_and(|(owner, name)| !owner.is_empty() && !name.trim().is_empty());
        if !named {
            publishing.error = "Name the repository as owner/name.".into();
            self.publish(engine);
            return;
        }
        let remote_name = match text(args, "remoteName").trim() {
            "" => "origin".to_owned(),
            name => name.to_owned(),
        };
        let or = |key: &str, default: &str| match args.get(key).and_then(Json::as_str) {
            Some(value) => value.to_owned(),
            None => default.to_owned(),
        };
        publishing.busy = true;
        publishing.error.clear();
        self.publish(engine);
        let Some(place) = workspace::place(engine) else {
            return;
        };
        let me = self.me.clone();
        self.mc.call(
            &place.environment_id,
            "sourceControl.publishRepository",
            json!({
                "cwd": place.cwd(),
                "provider": or("provider", "github"),
                "repository": repository,
                "visibility": or("visibility", "private"),
                "remoteName": remote_name,
                "protocol": or("protocol", "ssh"),
            }),
            Box::new(move |engine, result| {
                me.run(engine, move |c, engine| c.published(engine, result));
            }),
        );
    }

    fn published(&mut self, engine: &Engine, result: Result<Json, McError>) {
        let Some(publishing) = &mut self.publishing else {
            return;
        };
        let published = match result {
            Err(error) => {
                publishing.busy = false;
                publishing.error = reason(&error);
                self.publish(engine);
                return;
            }
            Ok(published) => published,
        };
        self.publishing = None;
        let repository = published.get("repository").cloned().unwrap_or(Json::Null);
        let name = text(&repository, "nameWithOwner");
        let description = if text(&published, "status") == "pushed" {
            format!(
                "Pushed {} to {}.",
                text(&published, "branch"),
                text(&published, "remoteName")
            )
        } else {
            format!("Added the remote {}.", text(&published, "remoteName"))
        };
        let url = text(&repository, "url");
        let open = (!url.is_empty()).then(|| {
            let bridge = self.bridge;
            Action::new("Open repository", move |engine| {
                bridge.open_external(engine, &url);
            })
        });
        toast(
            engine,
            "success",
            &format!(
                "Published {}",
                if name.is_empty() {
                    "the repository"
                } else {
                    &name
                }
            ),
            &description,
            open,
            RESULT_MS,
        );
        workspace::refresh_git(engine);
        self.publish(engine);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(fields: Json) -> Status {
        let mut base = json!({
            "refName": "feature",
            "isRepo": true,
            "hasWorkingTreeChanges": false,
            "hasUpstream": true,
            "hasPrimaryRemote": true,
            "isDefaultRef": false,
            "aheadCount": 0,
            "behindCount": 0,
            "pr": null,
        });
        for (key, value) in fields.as_object().into_iter().flatten() {
            base[key] = value.clone();
        }
        base.as_object().cloned().unwrap_or_default()
    }

    fn quick(fields: Json) -> (String, &'static str, &'static str) {
        let action = quick_action(Some(&status(fields)), false);
        (action.label, action.kind, action.action)
    }

    #[test]
    fn the_quick_action_follows_the_checkout() {
        assert_eq!(
            quick(json!({"hasWorkingTreeChanges": true})).0,
            "Commit, push & PR"
        );
        assert_eq!(
            quick(json!({"hasWorkingTreeChanges": true, "isDefaultRef": true})).2,
            "commit_push"
        );
        assert_eq!(
            quick(json!({"hasWorkingTreeChanges": true, "hasUpstream": false, "hasPrimaryRemote": false})).2,
            "commit"
        );
        assert_eq!(
            quick(json!({"hasUpstream": false, "hasPrimaryRemote": false})).1,
            "open_publish"
        );
        assert_eq!(quick(json!({"behindCount": 2})).1, "run_pull");
        assert_eq!(quick(json!({"aheadCount": 1})).0, "Push & create PR");
        assert_eq!(
            quick(json!({"aheadCount": 1, "behindCount": 1})).0,
            "Sync ref"
        );
        assert_eq!(
            quick(json!({"pr": {"state": "open", "url": "https://x"}})).0,
            "View PR"
        );
        assert_eq!(quick(json!({"aheadOfDefaultCount": 3})).0, "Create PR");
        assert_eq!(quick(json!({})).1, "show_hint");
    }

    #[test]
    fn a_gitlab_host_calls_them_merge_requests() {
        let action = quick(json!({
            "aheadCount": 1,
            "sourceControlProvider": {"kind": "gitlab"},
        }));
        assert_eq!(action.0, "Push & create MR");
        let menu = menu_items(
            Some(&status(
                json!({"sourceControlProvider": {"kind": "gitlab"}}),
            )),
            false,
        );
        assert_eq!(menu[2]["label"], "Create MR");
        assert_eq!(menu[2]["disabledReason"], "No commits are ready for a MR.");
    }

    #[test]
    fn busy_and_unknown_say_why() {
        assert_eq!(
            quick_action(Some(&status(json!({}))), true).hint,
            "Git action in progress."
        );
        assert_eq!(quick_action(None, false).hint, "Git status is unavailable.");
        assert!(menu_items(None, false).is_empty());
    }

    #[test]
    fn the_menu_lists_only_commit_without_a_remote() {
        let s = status(json!({"hasPrimaryRemote": false, "hasWorkingTreeChanges": true}));
        let menu = menu_items(Some(&s), false);
        assert_eq!(menu.len(), 1);
        assert!(menu[0]["disabledReason"].is_null());
        let s = status(json!({"aheadCount": 1}));
        let menu = menu_items(Some(&s), false);
        assert_eq!(menu[0]["disabledReason"], "No uncommitted changes.");
        assert!(menu[1]["disabledReason"].is_null());
        assert!(menu[2]["disabledReason"].is_null());
    }

    #[test]
    fn the_hosts_say_how_to_get_ready() {
        let found = vec![json!({
            "kind": "github",
            "label": "GitHub CLI",
            "status": "available",
            "auth": {"status": "authenticated", "account": {"_tag": "Some", "value": "ada"}},
        })];
        let hosts = publish_hosts(&found, true);
        assert_eq!(hosts[0]["ready"], true);
        assert_eq!(hosts[0]["label"], "GitHub CLI");
        assert_eq!(hosts[0]["account"], "ada");
        assert_eq!(hosts[1]["ready"], false);
        assert_eq!(
            hosts[1]["hint"],
            "Provider status unavailable. Open Settings -> Source Control and rescan."
        );
        let waiting = publish_hosts(&[], false);
        assert_eq!(waiting[0]["hint"], "Checking GitHub...");
    }

    #[test]
    fn the_default_branch_question_names_the_action() {
        let t = terms(&Status::new());
        let copy = default_branch_copy("commit_push_pr", "main", true, &t);
        assert_eq!(copy["title"], "Commit, push & create PR from default ref?");
        assert_eq!(copy["continueLabel"], "Commit, push & create PR");
        let copy = default_branch_copy("push", "main", false, &t);
        assert_eq!(copy["continueLabel"], "Push to main");
    }
}
