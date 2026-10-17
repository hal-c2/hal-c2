//! `workspace`: the route thread's checkout, git status and editors
//! (WorkspaceController.cpp, features/source-control/, features/threads/).

use std::path::PathBuf;
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::thread_menu::COPY_REFERENCE;
use hal_c2_shell::controllers::workspace::{self, Checkout};
use hal_c2_shell::json::Json;
use ljos::prelude::{Platform, RecordedUrls};
use serde_json::json;

use crate::Hub;
use crate::page::{failure, last, toasts};

pub const AT: &str = "2026-03-01T00:00:00Z";

/// Member `a` serving env-1 with `rows` ([mc, id, kind, row]).
pub fn shell(hub: &Hub, rows: Vec<Json>) {
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell",
            "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
                     "environment": {"environmentId": "env-1", "label": "env-1"}}],
            "rows": rows}),
    );
}

/// Project p1 at /w/p, with `extra` fields.
pub fn project(extra: Json) -> Json {
    let mut row = json!({"id": "p1", "title": "Project", "workspaceRoot": "/w/p",
        "createdAt": AT, "updatedAt": AT});
    if let Json::Object(extra) = extra {
        row.as_object_mut().unwrap().extend(extra);
    }
    json!(["a", "p1", "project", row])
}

/// Thread `id` of p1 on `branch`, in `worktree` when given.
pub fn thread(id: &str, branch: &str, worktree: Option<&str>) -> Json {
    json!(["a", id, "thread", {"id": id, "projectId": "p1", "title": format!("Thread {id}"),
        "branch": branch, "worktreePath": worktree, "createdAt": AT, "updatedAt": AT}])
}

/// The cluster's member `a` serving env-1 with project p1 at /w/p and its
/// thread t1 (on `branch`, in `worktree` when given).
pub fn seed(hub: &Hub, branch: &str, worktree: Option<&str>) {
    shell(
        hub,
        vec![project(json!({})), thread("t1", branch, worktree)],
    );
}

/// A fresh folder for `test`'s files, under the target's.
pub fn scratch(test: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("hub-workspace")
        .join(test);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A hub started with `launch` that follows the cluster.
pub fn clustered(launch: Launch) -> Hub {
    Hub::with(Launch {
        mc_origin: Some("http://127.0.0.1:1".into()),
        ..launch
    })
}

/// A hub showing env-1:t1.
pub fn on_thread(branch: &str, worktree: Option<&str>) -> Hub {
    on_thread_with(Launch::default(), branch, worktree)
}

/// A hub started with `launch` (following the cluster) showing env-1:t1.
pub fn on_thread_with(launch: Launch, branch: &str, worktree: Option<&str>) -> Hub {
    let hub = clustered(launch);
    seed(&hub, branch, worktree);
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    hub
}

fn vcs(hub: &Hub) -> Vec<Json> {
    hub.mc
        .subscriptions()
        .into_iter()
        .map(|(_, shape)| shape)
        .filter(|shape| shape["type"] == "vcs")
        .collect()
}

pub fn snapshot(hub: &Hub, branch: &str, pr: Json) {
    hub.mc.frame(
        &hub.engine,
        "vcs",
        "env-1",
        json!({"t": "vcs", "event": {"_tag": "snapshot",
            "local": {"isRepo": true, "refName": branch, "hasWorkingTreeChanges": true},
            "remote": {"hasUpstream": true, "aheadCount": 2, "behindCount": 1, "pr": pr}}}),
    );
}

pub fn editors(hub: &Hub, available: &[&str]) {
    hub.mc.frame(
        &hub.engine,
        "config",
        "",
        json!({"t": "config", "config": {"availableEditors": available, "keybindingRules": []}}),
    );
}

#[test]
fn the_route_thread_publishes_its_project_and_follows_its_checkout() {
    let hub = on_thread("main", None);
    let state = hub.published("workspace");
    assert_eq!(state["threadKey"], "env-1:t1");
    assert_eq!(state["projectTitle"], "Project");
    assert_eq!(state["projectRoot"], "/w/p");
    assert_eq!(state["threadTitle"], "Thread t1");
    assert_eq!(state["isDraft"], false);
    assert_eq!(state["branch"], "main");
    assert_eq!(state["git"], Json::Null);
    let place = workspace::place(&hub.engine).expect("a place");
    assert_eq!(place.cwd(), "/w/p");
    assert_eq!(
        vcs(&hub),
        [json!({"type": "vcs", "environment": "env-1", "cwd": "/w/p"})]
    );

    // Leaving the thread stops following it.
    hub.dispatch("usage.open", json!({}));
    assert_eq!(hub.published("workspace"), Json::Null);
    assert!(workspace::place(&hub.engine).is_none());
    assert!(vcs(&hub).is_empty());
}

#[test]
fn a_worktree_thread_follows_its_worktree() {
    let hub = on_thread("feature", Some("/w/p-feature"));
    assert_eq!(
        vcs(&hub),
        [json!({"type": "vcs", "environment": "env-1", "cwd": "/w/p-feature"})]
    );
    assert_eq!(hub.published("workspace")["worktreePath"], "/w/p-feature");
    assert_eq!(hub.published("workspace")["envModeLabel"], "Worktree");
}

#[test]
fn the_checkout_status_fills_git_and_its_pull_request_opens_in_the_browser() {
    let hub = on_thread("main", None);
    let opened = RecordedUrls::default();
    Platform::of(&hub.engine).set_open_url(Rc::new(opened.clone()));
    snapshot(
        &hub,
        "feature",
        json!({"number": 7, "title": "Add it", "url": "https://github.com/a/b/pull/7", "state": "open"}),
    );
    let state = hub.published("workspace");
    assert_eq!(state["branch"], "feature");
    assert_eq!(
        state["git"],
        json!({"isRepo": true, "hasWorkingTreeChanges": true, "aheadCount": 2, "behindCount": 1,
               "hasUpstream": true,
               "pullRequest": {"number": 7, "title": "Add it", "url": "https://github.com/a/b/pull/7", "state": "open"}})
    );
    assert_eq!(state["canOpenPullRequest"], true);
    hub.dispatch("workspace.openPullRequest", json!({}));
    assert_eq!(opened.urls(), ["https://github.com/a/b/pull/7"]);

    // A remote update keeps the local half.
    hub.mc.frame(
        &hub.engine,
        "vcs",
        "env-1",
        json!({"t": "vcs", "event": {"_tag": "remoteUpdated", "remote": {"hasUpstream": false}}}),
    );
    let state = hub.published("workspace");
    assert_eq!(state["branch"], "feature");
    assert_eq!(state["git"]["pullRequest"], Json::Null);
    assert_eq!(state["canOpenPullRequest"], false);

    // An unreachable member ends the watch with its reason.
    hub.mc.frame(
        &hub.engine,
        "vcs",
        "env-1",
        json!({"t": "error", "reason": "member a is offline"}),
    );
    assert_eq!(workspace::git_error(&hub.engine), "member a is offline");
    assert_eq!(hub.published("workspace")["git"], Json::Null);
}

#[test]
fn copy_reference_offers_the_branch_pull_request_of_the_route_thread() {
    let hub = on_thread("main", None);
    let title = |hub: &Hub| {
        Commands::of(&hub.engine)
            .rows()
            .into_iter()
            .find(|r| r.command == COPY_REFERENCE)
            .map(|r| (r.title, r.description))
            .unwrap()
    };
    assert_eq!(title(&hub), ("Copy thread ID".into(), "t1".into()));
    snapshot(
        &hub,
        "main",
        json!({"number": 7, "title": "Add it", "url": "https://github.com/a/b/pull/7", "state": "open"}),
    );
    assert_eq!(
        title(&hub),
        (
            "Copy PR link".into(),
            "https://github.com/a/b/pull/7".into()
        )
    );
}

#[test]
fn open_in_editor_uses_the_environments_editors_and_remembers_the_choice() {
    let launch = Launch {
        config_dir: Some(scratch("editors")),
        ..Launch::default()
    };
    let hub = on_thread_with(launch, "main", None);
    hub.mc.set_ready(&hub.engine, true);
    editors(&hub, &["zed", "cursor", "file-manager"]);
    let state = hub.published("workspace");
    assert_eq!(
        state["editors"],
        json!([{"id": "cursor", "label": "Cursor"}, {"id": "zed", "label": "Zed"},
               {"id": "file-manager", "label": "File Manager"}])
    );
    assert_eq!(state["preferredEditorId"], "cursor");

    hub.dispatch("workspace.openInEditor", json!({"editorId": "zed"}));
    assert_eq!(
        last(&hub, "env-1", "shell.openInEditor"),
        json!({"cwd": "/w/p", "editor": "zed"})
    );
    assert_eq!(hub.published("workspace")["preferredEditorId"], "zed");

    // A file of the checkout opens in the preferred editor.
    hub.dispatch("workspace.openFile", json!({"path": "src/a.rs"}));
    assert_eq!(
        last(&hub, "env-1", "shell.openInEditor"),
        json!({"cwd": "/w/p/src/a.rs", "editor": "zed"})
    );

    // One the machine lacks is not asked for.
    let before = hub.mc.methods().len();
    hub.dispatch("workspace.openInEditor", json!({"editorId": "vscode"}));
    assert_eq!(hub.mc.methods().len(), before);

    hub.mc
        .answer(&hub.engine, "shell.openInEditor", Err(failure("no zed")));
    assert!(toasts(&hub).contains(&("Failed to open in editor.".into(), "no zed".into())));
}

#[test]
fn a_file_with_no_editor_to_open_it_says_so() {
    let hub = on_thread("main", None);
    editors(&hub, &[]);
    hub.dispatch("workspace.openFile", json!({"path": "src/a.rs"}));
    assert!(!hub.mc.methods().iter().any(|m| m == "shell.openInEditor"));
    assert!(toasts(&hub).contains(&(
        "Editor opening is unavailable.".into(),
        "An error occurred.".into()
    )));
}

#[test]
fn the_title_menu_is_the_threads_and_a_drafts_own() {
    let hub = on_thread("main", None);
    hub.dispatch("workspace.titleMenu", json!({"x": 4, "y": 8}));
    let menu = hub.published("menu");
    assert!(
        menu["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|i| i["id"] == "new-thread-on-branch")
    );

    // "New thread on this branch" starts a draft there, on the thread's
    // branch.
    hub.dispatch(
        "menu.select",
        json!({"requestId": menu["requestId"], "id": "new-thread-on-branch"}),
    );
    let state = hub.published("workspace");
    assert_eq!(state["isDraft"], true);
    assert_eq!(state["branch"], "main");
    assert_eq!(state["envMode"], "local");
    let draft = workspace::place(&hub.engine).unwrap().draft_id;
    assert_eq!(
        workspace::checkout(&hub.engine, &draft),
        Checkout {
            branch: Some("main".into()),
            ..Checkout::default()
        }
    );

    // A draft's is the drafts' menu.
    hub.dispatch("workspace.titleMenu", json!({"x": 4, "y": 8}));
    let menu = hub.published("menu");
    assert_eq!(menu["items"][0]["label"], "Delete draft");
    assert_eq!(menu["items"].as_array().unwrap().len(), 1);
}

#[test]
fn a_worktree_threads_branch_starts_a_draft_in_that_worktree() {
    let hub = on_thread("feature", Some("/w/p-feature"));
    hub.dispatch("workspace.titleMenu", json!({"x": 0, "y": 0}));
    let menu = hub.published("menu");
    hub.dispatch(
        "menu.select",
        json!({"requestId": menu["requestId"], "id": "new-thread-on-branch"}),
    );
    let place = workspace::place(&hub.engine).unwrap();
    assert_eq!(place.worktree_path, "/w/p-feature");
    let launch = workspace::launch(&hub.engine, &place.draft_id);
    assert_eq!(
        Json::Object(launch.strategy),
        json!({"type": "existing_worktree", "worktreePath": "/w/p-feature", "branch": "feature"})
    );
}

#[test]
fn a_new_worktree_draft_needs_a_base_branch() {
    let hub = Hub::clustered();
    seed(&hub, "main", None);
    hub.dispatch("thread.new", json!(null));
    let draft = workspace::place(&hub.engine).expect("a draft").draft_id;
    assert!(!draft.is_empty());
    hub.dispatch("workspace.envMode.set", json!({"mode": "worktree"}));
    assert_eq!(hub.published("workspace")["envModeLabel"], "New worktree");
    assert_eq!(
        workspace::launch(&hub.engine, &draft).problem,
        "Select a base branch before sending in New worktree mode."
    );
    snapshot(&hub, "main", json!(null));
    hub.dispatch("workspace.startFromOrigin.set", json!({"enabled": true}));
    assert_eq!(
        Json::Object(workspace::launch(&hub.engine, &draft).strategy),
        json!({"type": "worktree", "baseRef": "main", "startFromOrigin": true})
    );
    workspace::forget_draft(&hub.engine, &draft);
    assert_eq!(
        workspace::checkout(&hub.engine, &draft),
        Checkout::default()
    );
}

#[test]
fn picking_a_branch_switches_the_checkout_and_names_it_on_the_thread() {
    let hub = on_thread("main", None);
    snapshot(&hub, "main", json!(null));
    hub.dispatch("workspace.branch.search", json!({"query": "fea"}));
    assert_eq!(
        last(&hub, "env-1", "vcs.listRefs"),
        json!({"cwd": "/w/p", "limit": 100, "query": "fea"})
    );
    assert_eq!(hub.published("workspace")["branchesLoading"], true);
    hub.mc.answer(
        &hub.engine,
        "vcs.listRefs",
        Ok(
            json!({"refs": [{"name": "feature"}, {"name": "origin/fix", "isRemote": true}],
                  "totalCount": 2}),
        ),
    );
    let state = hub.published("workspace");
    assert_eq!(state["branchesLoading"], false);
    assert_eq!(state["branches"][1]["name"], "origin/fix");

    hub.dispatch("workspace.branch.select", json!({"name": "origin/fix"}));
    assert_eq!(
        last(&hub, "env-1", "vcs.switchRef"),
        json!({"cwd": "/w/p", "refName": "origin/fix"})
    );
    let state = hub.published("workspace");
    assert_eq!(state["branchSwitchPending"], true);
    assert_eq!(state["branch"], "fix");
    // One switch at a time.
    hub.dispatch("workspace.branch.select", json!({"name": "feature"}));
    assert_eq!(
        hub.mc
            .methods()
            .iter()
            .filter(|m| *m == "vcs.switchRef")
            .count(),
        1
    );

    hub.mc
        .answer(&hub.engine, "vcs.switchRef", Ok(json!({"refName": "fix"})));
    let mut command = last(&hub, "env-1", "orchestration.dispatchCommand");
    command.as_object_mut().unwrap().remove("commandId");
    assert_eq!(
        command,
        json!({"type": "thread.metadata.update", "threadId": "t1", "branch": "fix", "worktreePath": null})
    );
    assert_eq!(hub.published("workspace")["branchSwitchPending"], false);
    assert_eq!(hub.published("workspace")["branch"], "fix");
}

#[test]
fn a_refused_switch_goes_back_to_the_branch_before() {
    let hub = on_thread("main", None);
    snapshot(&hub, "main", json!(null));
    hub.dispatch("workspace.branch.search", json!({"query": ""}));
    hub.mc.answer(
        &hub.engine,
        "vcs.listRefs",
        Ok(json!({"refs": [{"name": "feature"}]})),
    );
    hub.dispatch("workspace.branch.select", json!({"name": "feature"}));
    assert_eq!(hub.published("workspace")["branch"], "feature");
    hub.mc
        .answer(&hub.engine, "vcs.switchRef", Err(failure("dirty tree")));
    assert_eq!(hub.published("workspace")["branch"], "main");
    assert!(toasts(&hub).contains(&("Failed to switch ref.".into(), "dirty tree".into())));
}
