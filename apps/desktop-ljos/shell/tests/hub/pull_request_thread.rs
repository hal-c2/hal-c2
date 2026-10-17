//! `pullRequestThread`: starting a thread on a pull request, named, shown,
//! then checked out locally or in a worktree of its own
//! (PullRequestThreadController.cpp, PullRequestSteps.cpp,
//! features/source-control/pull-request-threads.feature).

use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::navigation::{self, Navigation, Route};
use hal_c2_shell::json::Json;
use serde_json::json;

use crate::Hub;
use crate::page::{answer, count, failure, last, toasts};
use crate::workspace::{clustered, on_thread};

const RESOLVE: &str = "git.resolvePullRequest";
const PREPARE: &str = "git.preparePullRequestThread";
const LAUNCH: &str = "orchestration.launchThread";

fn dialog(hub: &Hub) -> Json {
    hub.published("pullRequestThread")
}

fn resolved() -> Json {
    json!({"pullRequest": {"number": 42, "title": "Add tax to the cart",
        "headBranch": "feature/tax", "baseBranch": "main", "state": "open"}})
}

/// Opens the dialog from the palette and names `reference`.
fn ask(hub: &Hub, reference: &str) {
    assert!(Commands::of(&hub.engine).run(&hub.engine, "pullRequestThread.open"));
    assert_eq!(dialog(hub)["step"], "ask");
    hub.dispatch("pullRequestThread.resolve", json!({"reference": reference}));
}

#[test]
fn without_a_project_there_is_nothing_to_ask() {
    let hub = clustered(Default::default());
    crate::workspace::seed(&hub, "main", None);
    // On a page of no project.
    hub.with_controller::<Navigation, _>(|n, e| n.open(e, Route::Usage));
    hub.dispatch("pullRequestThread.open", json!({}));
    assert_eq!(dialog(&hub), Json::Null);
    assert_eq!(
        toasts(&hub),
        [(
            "Open a project to start a thread on one of its pull requests.".to_owned(),
            String::new()
        )]
    );
}

#[test]
fn a_named_pull_request_is_shown_then_started_in_a_worktree() {
    let hub = on_thread("main", None);
    ask(&hub, " https://github.com/acme/shop/pull/42 ");
    assert_eq!(dialog(&hub)["step"], "resolving");
    assert_eq!(
        last(&hub, "env-1", RESOLVE),
        json!({"cwd": "/w/p", "reference": "https://github.com/acme/shop/pull/42"})
    );
    answer(&hub, "env-1", RESOLVE, Ok(resolved()));
    let shown = dialog(&hub);
    assert_eq!(shown["step"], "choose");
    assert_eq!(shown["pullRequest"]["number"], 42);
    assert_eq!(shown["pullRequest"]["branches"], "feature/tax → main");
    // Nothing is checked out before the user chooses.
    assert_eq!(count(&hub, PREPARE), 0);
    hub.dispatch("pullRequestThread.start", json!({"mode": "worktree"}));
    assert_eq!(dialog(&hub)["step"], "starting");
    // Starting is not cancelled.
    hub.dispatch("pullRequestThread.cancel", json!({}));
    assert_eq!(dialog(&hub)["step"], "starting");
    let prepare = last(&hub, "env-1", PREPARE);
    assert_eq!(prepare["mode"], "worktree");
    assert_eq!(prepare["reference"], "https://github.com/acme/shop/pull/42");
    answer(
        &hub,
        "env-1",
        PREPARE,
        Ok(
            json!({"branch": "feature/tax", "worktreePath": "/w/worktrees/pr-42",
            "isOnPullRequestHead": false}),
        ),
    );
    let launch = last(&hub, "env-1", LAUNCH);
    assert_eq!(launch["threadId"], prepare["threadId"]);
    assert_eq!(launch["projectId"], "p1");
    assert_eq!(launch["title"], "#42 Add tax to the cart");
    assert_eq!(
        launch["workspaceStrategy"],
        json!({"type": "existing_worktree", "branch": "feature/tax",
            "worktreePath": "/w/worktrees/pr-42"})
    );
    answer(&hub, "env-1", LAUNCH, Ok(json!({})));
    assert_eq!(dialog(&hub), Json::Null);
    let key = format!("env-1:{}", launch["threadId"].as_str().unwrap());
    assert_eq!(navigation::shown(&hub.engine), Route::Thread(key));
    // The worktree kept its own commits.
    assert_eq!(
        toasts(&hub),
        [(
            "The checkout is not on the pull request's head".to_owned(),
            "Its local changes were kept.".to_owned()
        )]
    );
}

#[test]
fn a_local_checkout_starts_in_the_projects_root() {
    let hub = on_thread("main", None);
    ask(&hub, "#42");
    answer(&hub, "env-1", RESOLVE, Ok(resolved()));
    hub.dispatch("pullRequestThread.start", json!({"mode": "local"}));
    answer(
        &hub,
        "env-1",
        PREPARE,
        Ok(json!({"branch": "feature/tax", "worktreePath": null})),
    );
    assert_eq!(
        last(&hub, "env-1", LAUNCH)["workspaceStrategy"],
        json!({"type": "root", "branch": "feature/tax"})
    );
    answer(&hub, "env-1", LAUNCH, Ok(json!({})));
    assert!(toasts(&hub).is_empty(), "on the head, nothing to say");
}

#[test]
fn a_pull_request_not_found_is_asked_again() {
    let hub = on_thread("main", None);
    ask(&hub, "9999");
    answer(&hub, "env-1", RESOLVE, Err(failure("")));
    let shown = dialog(&hub);
    assert_eq!(shown["step"], "ask");
    assert_eq!(shown["error"], "The pull request was not found.");
    assert_eq!(shown["pullRequest"], Json::Null);
}

#[test]
fn a_failed_checkout_goes_back_to_choosing() {
    let hub = on_thread("main", None);
    ask(&hub, "42");
    answer(&hub, "env-1", RESOLVE, Ok(resolved()));
    hub.dispatch("pullRequestThread.start", json!({"mode": "worktree"}));
    answer(
        &hub,
        "env-1",
        PREPARE,
        Err(failure("Use the local checkout instead.")),
    );
    let shown = dialog(&hub);
    assert_eq!(shown["step"], "choose");
    assert_eq!(shown["error"], "Use the local checkout instead.");
    assert_eq!(count(&hub, LAUNCH), 0);
}

#[test]
fn cancelling_drops_what_was_asked() {
    let hub = on_thread("main", None);
    ask(&hub, "42");
    hub.dispatch("pullRequestThread.cancel", json!({}));
    assert_eq!(dialog(&hub), Json::Null);
    // Its answer, late, is not shown.
    answer(&hub, "env-1", RESOLVE, Ok(resolved()));
    assert_eq!(dialog(&hub), Json::Null);
}

#[test]
fn the_pull_requests_page_names_one_to_resolve_at_once() {
    let hub = clustered(Default::default());
    crate::workspace::seed(&hub, "main", None);
    hub.dispatch(
        "pullRequestThread.open",
        json!({"reference": "https://github.com/acme/shop/pull/42",
            "environmentId": "env-1", "projectId": "p1"}),
    );
    assert_eq!(dialog(&hub)["step"], "resolving");
    assert_eq!(last(&hub, "env-1", RESOLVE)["cwd"], "/w/p");
    // A project not open here is said so.
    hub.dispatch(
        "pullRequestThread.open",
        json!({"reference": "42", "environmentId": "env-1", "projectId": "gone"}),
    );
    assert!(
        toasts(&hub)
            .iter()
            .any(|(t, _)| t == "That pull request's project is not open on this device.")
    );
}
