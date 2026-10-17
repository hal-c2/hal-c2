//! `git`: the header's git pill for the route's checkout and what its buttons
//! run (GitController.cpp, features/source-control/git-actions.feature).

use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::workspace::{self, project, thread};

/// The route on thread t1 of `env-1`'s project p1 (t2 is its sibling), in a
/// checkout whose status is `local` and `remote`.
fn hub(local: Json, remote: Json) -> Hub {
    let hub = Hub::clustered();
    workspace::shell(
        &hub,
        vec![
            project(json!({})),
            thread("t1", "feature", None),
            thread("t2", "feature", None),
        ],
    );
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    status(&hub, local, remote);
    hub
}

/// The MC's `vcs` shape says the checkout is now `local` and `remote`.
fn status(hub: &Hub, local: Json, remote: Json) {
    hub.mc.frame(
        &hub.engine,
        "vcs",
        "env-1",
        json!({"t": "vcs", "event": {"_tag": "snapshot", "local": local, "remote": remote}}),
    );
    // The pill follows once the controller is free.
    hub.advance(0);
}

/// The route leaves the thread: no checkout is followed.
fn leave(hub: &Hub) {
    hub.dispatch("usage.open", json!({}));
    hub.advance(0);
}

/// How many times the shell asked the MC to read the checkout again.
fn refreshes(hub: &Hub) -> usize {
    hub.mc
        .methods()
        .iter()
        .filter(|m| *m == "vcs.refreshStatus")
        .count()
}

fn local(changes: bool, default_ref: bool) -> Json {
    json!({"refName": "feature", "isRepo": true, "hasWorkingTreeChanges": changes,
        "hasPrimaryRemote": true, "isDefaultRef": default_ref})
}

fn remote(ahead: i64, behind: i64) -> Json {
    json!({"hasUpstream": true, "aheadCount": ahead, "behindCount": behind, "pr": null})
}

fn pill(hub: &Hub) -> Json {
    hub.published("git")
}

fn toasts(hub: &Hub) -> Vec<Json> {
    hub.published("toasts")["items"].as_array().unwrap().clone()
}

fn titles(hub: &Hub) -> Vec<String> {
    toasts(hub)
        .iter()
        .map(|t| t["title"].as_str().unwrap().to_owned())
        .collect()
}

fn actions(hub: &Hub) -> Vec<Json> {
    hub.mc
        .subscriptions()
        .into_iter()
        .map(|(_, shape)| shape)
        .filter(|shape| shape["type"] == "gitAction")
        .collect()
}

fn frame(hub: &Hub, event: Json) {
    hub.mc.frame(
        &hub.engine,
        "gitAction",
        "env-1",
        json!({"t": "gitAction", "event": event}),
    );
}

fn finished(title: &str) -> Json {
    json!({"kind": "action_finished", "result": {"toast": {"title": title, "description": "Done."}}})
}

#[test]
fn the_pill_offers_what_the_checkout_needs_next() {
    let hub = hub(local(true, false), remote(0, 0));
    let state = pill(&hub);
    assert_eq!(state["available"], true);
    assert_eq!(state["branch"], "feature");
    assert_eq!(state["quickAction"]["label"], "Commit, push & PR");
    assert_eq!(state["quickAction"]["kind"], "run_action");
    assert_eq!(state["menu"][0]["id"], "commit");
    assert_eq!(state["menu"][0]["disabledReason"], Json::Null);
    assert_eq!(
        state["menu"][1]["disabledReason"],
        "No local commits to push."
    );

    status(&hub, local(false, false), remote(0, 2));
    let state = pill(&hub);
    assert_eq!(state["quickAction"]["label"], "Pull");
    assert_eq!(state["quickAction"]["kind"], "run_pull");
    assert_eq!(
        state["hints"],
        json!(["Behind upstream by 2 \u{2014} pull or rebase before pushing."])
    );

    status(&hub, local(false, false), remote(1, 0));
    assert_eq!(pill(&hub)["quickAction"]["label"], "Push & create PR");

    let mut gitlab = local(false, false);
    gitlab["sourceControlProvider"] = json!({"kind": "gitlab"});
    status(&hub, gitlab, remote(1, 0));
    assert_eq!(pill(&hub)["quickAction"]["label"], "Push & create MR");
}

#[test]
fn off_a_checkout_or_an_unreachable_machine_there_is_no_pill() {
    let hub = hub(local(true, false), remote(0, 0));
    hub.mc.frame(
        &hub.engine,
        "vcs",
        "env-1",
        json!({"t": "error", "reason": "Build box is not reachable."}),
    );
    hub.advance(0);
    assert_eq!(
        pill(&hub),
        json!({"available": false, "unavailableReason": "Build box is not reachable."})
    );
    leave(&hub);
    assert_eq!(pill(&hub), json!({"available": false}));
}

#[test]
fn a_stacked_action_runs_in_the_mcs_git_action_stream_and_one_toast_follows_its_stages() {
    let hub = hub(local(true, false), remote(0, 0));
    hub.dispatch("git.commit", json!({"message": "  Fix it  "}));
    let shapes = actions(&hub);
    assert_eq!(shapes.len(), 1);
    let input = &shapes[0]["input"];
    assert_eq!(input["action"], "commit");
    assert_eq!(input["cwd"], "/w/p");
    assert_eq!(input["commitMessage"], "Fix it");
    assert_eq!(input["threadId"], "t1");
    assert_eq!(shapes[0]["environment"], "env-1");
    assert_eq!(pill(&hub)["busy"], true);
    assert_eq!(titles(&hub), ["Starting source control action..."]);
    // One at a time.
    hub.dispatch("git.commit", json!({"message": "again"}));
    assert_eq!(actions(&hub).len(), 1);

    frame(
        &hub,
        json!({"kind": "phase_started", "label": "Committing..."}),
    );
    assert_eq!(titles(&hub), ["Committing..."]);
    assert_eq!(pill(&hub)["progress"]["stage"], "Committing...");
    frame(
        &hub,
        json!({"kind": "hook_output", "text": "lint\nall good\n"}),
    );
    assert_eq!(toasts(&hub)[0]["description"], "all good");
    assert_eq!(pill(&hub)["progress"]["hookLine"], "all good");
    hub.advance(3000);
    assert_eq!(pill(&hub)["progress"]["elapsed"], "3s");

    let before = refreshes(&hub);
    frame(&hub, finished("Committed"));
    assert!(actions(&hub).is_empty());
    assert_eq!(pill(&hub)["busy"], false);
    assert_eq!(pill(&hub)["progress"], Json::Null);
    assert_eq!(titles(&hub), ["Committed"]);
    assert_eq!(refreshes(&hub), before + 1);
}

#[test]
fn a_failed_action_says_why_and_a_dropped_connection_does_not_resend_it() {
    let hub = hub(local(true, false), remote(0, 0));
    hub.dispatch("git.commit", json!({"message": "m"}));
    frame(
        &hub,
        json!({"kind": "action_failed", "message": "hook rejected"}),
    );
    assert_eq!(titles(&hub), ["Action failed"]);
    assert_eq!(toasts(&hub)[0]["description"], "hook rejected");
    assert_eq!(pill(&hub)["busy"], false);

    hub.dispatch("git.commit", json!({"message": "m"}));
    hub.mc.set_ready(&hub.engine, false);
    assert!(actions(&hub).is_empty());
    assert_eq!(pill(&hub)["busy"], false);
    assert!(
        titles(&hub)
            .iter()
            .filter(|t| *t == "Action failed")
            .count()
            >= 1
    );
}

#[test]
fn landing_on_the_default_branch_asks_first_and_the_answer_decides_where_it_runs() {
    let hub = hub(local(true, true), remote(0, 0));
    hub.dispatch("git.quick", json!({}));
    assert!(actions(&hub).is_empty());
    let question = pill(&hub)["pendingDefaultBranch"].clone();
    assert_eq!(question["title"], "Commit & push to default ref?");
    assert_eq!(question["continueLabel"], "Commit & push to feature");
    hub.dispatch("git.defaultBranch", json!({"choice": "featureBranch"}));
    let shapes = actions(&hub);
    assert_eq!(shapes[0]["input"]["action"], "commit_push");
    assert_eq!(shapes[0]["input"]["featureBranch"], true);
    assert_eq!(pill(&hub)["pendingDefaultBranch"], Json::Null);

    // Asking again and walking away leaves it unrun.
    frame(&hub, finished("Pushed"));
    hub.dispatch("git.quick", json!({}));
    hub.dispatch("git.defaultBranch", json!({"choice": "cancel"}));
    assert!(actions(&hub).is_empty());
    assert_eq!(pill(&hub)["pendingDefaultBranch"], Json::Null);
}

#[test]
fn a_question_about_one_checkout_does_not_follow_the_route() {
    let hub = hub(local(true, true), remote(0, 0));
    hub.dispatch("git.quick", json!({}));
    assert_ne!(pill(&hub)["pendingDefaultBranch"], Json::Null);
    hub.dispatch("thread.open", json!({"key": "env-1:t2"}));
    hub.advance(0);
    assert_eq!(pill(&hub)["pendingDefaultBranch"], Json::Null);
    hub.dispatch("git.defaultBranch", json!({"choice": "continue"}));
    assert!(actions(&hub).is_empty());
}

#[test]
fn a_branch_the_action_made_becomes_the_threads() {
    let hub = hub(local(true, false), remote(0, 0));
    hub.dispatch("git.commit", json!({"message": "m", "featureBranch": true}));
    frame(
        &hub,
        json!({"kind": "action_finished", "result": {
            "branch": {"status": "created", "name": "hal/fix"},
            "toast": {"title": "Committed", "description": ""}}}),
    );
    let index = hub
        .mc
        .pending("orchestration.dispatchCommand")
        .expect("branch saved");
    let mut command = hub.mc.calls.borrow()[index].2.clone();
    assert!(
        command
            .as_object_mut()
            .unwrap()
            .remove("commandId")
            .is_some()
    );
    assert_eq!(
        command,
        json!({"type": "thread.metadata.update", "threadId": "t1", "branch": "hal/fix"})
    );
}

#[test]
fn pull_toasts_its_progress_and_reads_the_status_again() {
    let hub = hub(local(false, false), remote(0, 3));
    hub.dispatch("git.quick", json!({}));
    assert_eq!(pill(&hub)["busy"], true);
    assert_eq!(titles(&hub), ["Pulling latest changes..."]);
    let before = refreshes(&hub);
    hub.mc.answer(
        &hub.engine,
        "vcs.pull",
        Ok(json!({"status": "pulled", "refName": "feature", "upstreamRef": "origin/feature"})),
    );
    assert_eq!(titles(&hub), ["Pulled"]);
    assert_eq!(
        toasts(&hub)[0]["description"],
        "Updated feature from origin/feature"
    );
    assert_eq!(pill(&hub)["busy"], false);
    assert_eq!(refreshes(&hub), before + 1);

    hub.dispatch("git.quick", json!({}));
    hub.mc
        .answer(&hub.engine, "vcs.pull", Err(McError::new("diverged")));
    assert!(titles(&hub).contains(&"Pull failed".to_owned()));
}

#[test]
fn initialize_git_runs_once_and_reports_a_refusal() {
    let hub = hub(json!({"isRepo": false}), json!({}));
    assert_eq!(pill(&hub)["isRepo"], false);
    hub.dispatch("git.init", json!({}));
    hub.dispatch("git.init", json!({}));
    assert_eq!(
        hub.mc.methods().iter().filter(|m| *m == "vcs.init").count(),
        1
    );
    assert_eq!(pill(&hub)["initPending"], true);
    hub.mc
        .answer(&hub.engine, "vcs.init", Err(McError::new("read-only")));
    assert_eq!(pill(&hub)["initPending"], false);
    assert_eq!(titles(&hub), ["Git initialization failed"]);
}

#[test]
fn publishing_walks_the_hosts_then_the_repository_and_keeps_the_dialog_on_failure() {
    let mut no_remote = local(false, false);
    no_remote["hasPrimaryRemote"] = false.into();
    let hub = hub(no_remote, json!({"hasUpstream": false}));
    assert_eq!(pill(&hub)["canPublish"], true);
    assert_eq!(pill(&hub)["quickAction"]["kind"], "open_publish");
    hub.dispatch("git.publish", json!({}));
    let dialog = pill(&hub)["publishing"].clone();
    assert_eq!(dialog["hosts"][0]["hint"], "Checking GitHub...");
    hub.mc.answer(
        &hub.engine,
        "server.discoverSourceControl",
        Ok(json!({"sourceControlProviders": [
            {"kind": "github", "label": "GitHub", "status": "available",
             "auth": {"status": "authenticated", "account": {"_tag": "Some", "value": "me"}}}]})),
    );
    let hosts = pill(&hub)["publishing"]["hosts"].clone();
    assert_eq!(hosts[0]["ready"], true);
    assert_eq!(hosts[0]["account"], "me");
    assert_eq!(hosts[1]["ready"], false);
    assert_eq!(
        hosts[1]["hint"],
        "Provider status unavailable. Open Settings -> Source Control and rescan."
    );

    hub.dispatch("git.publish.submit", json!({"repository": "nobody"}));
    assert_eq!(
        pill(&hub)["publishing"]["error"],
        "Name the repository as owner/name."
    );
    hub.dispatch("git.publish.submit", json!({"repository": "me/app"}));
    assert_eq!(pill(&hub)["publishing"]["busy"], true);
    hub.dispatch("git.publish.cancel", json!({}));
    assert_ne!(pill(&hub)["publishing"], Json::Null);
    let index = hub.mc.pending("sourceControl.publishRepository").unwrap();
    assert_eq!(hub.mc.calls.borrow()[index].2["remoteName"], "origin");
    hub.mc
        .reply(&hub.engine, index, Err(McError::new("name taken")));
    assert_eq!(pill(&hub)["publishing"]["error"], "name taken");
    hub.dispatch("git.publish.submit", json!({"repository": "me/app"}));
    hub.mc.answer(
        &hub.engine,
        "sourceControl.publishRepository",
        Ok(
            json!({"status": "pushed", "branch": "feature", "remoteName": "origin",
            "repository": {"nameWithOwner": "me/app", "url": "https://github.com/me/app"}}),
        ),
    );
    assert_eq!(pill(&hub)["publishing"], Json::Null);
    assert_eq!(titles(&hub), ["Published me/app"]);
    assert_eq!(toasts(&hub)[0]["description"], "Pushed feature to origin.");
}

#[test]
fn actions_wait_for_a_connected_checkout() {
    let hub = hub(local(true, false), remote(0, 0));
    leave(&hub);
    hub.dispatch("git.commit", json!({"message": "m"}));
    assert!(actions(&hub).is_empty());
}

#[derive(Clone, Debug)]
enum Op {
    Commit,
    Quick,
    Frame(u8),
    Disconnect,
    AnswerPull(bool),
    Init,
    AnswerInit,
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        4 => Just(Op::Commit),
        4 => Just(Op::Quick),
        4 => (0u8..4).prop_map(Op::Frame),
        1 => Just(Op::Disconnect),
        3 => any::<bool>().prop_map(Op::AnswerPull),
        1 => Just(Op::Init),
        1 => Just(Op::AnswerInit),
    ]
}

#[derive(Default)]
struct Model {
    running: bool,
    pulling: bool,
    pulls: usize,
    init: bool,
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 128, ..ProptestConfig::default() })]

    /// A checkout behind its upstream: Quick pulls and Commit runs the stacked
    /// action; only one of them is ever in flight, and whatever ends one
    /// (a result, a failure, the connection) leaves the pill free.
    #[test]
    fn the_pill_is_busy_exactly_while_an_action_or_a_pull_is_in_flight(
        ops in proptest::collection::vec(op(), 1..40)
    ) {
        let hub = hub(local(false, false), remote(0, 1));
        hub.mc.set_ready(&hub.engine, true);
        let mut model = Model::default();
        for op in ops {
            match op {
                Op::Commit => {
                    hub.dispatch("git.commit", json!({"message": "m"}));
                    if !model.running && !model.pulling {
                        model.running = true;
                    }
                }
                Op::Quick => {
                    hub.dispatch("git.quick", json!({}));
                    if !model.running && !model.pulling {
                        model.pulling = true;
                        model.pulls += 1;
                    }
                }
                Op::Frame(kind) => {
                    let event = match kind {
                        0 => json!({"kind": "phase_started", "label": "Pushing..."}),
                        1 => json!({"kind": "hook_output", "text": "hook"}),
                        2 => json!({"kind": "action_failed", "message": "no"}),
                        _ => finished("Done"),
                    };
                    frame(&hub, event);
                    if model.running && kind >= 2 {
                        model.running = false;
                    }
                }
                Op::Disconnect => {
                    hub.mc.set_ready(&hub.engine, false);
                    hub.mc.set_ready(&hub.engine, true);
                    model.running = false;
                }
                Op::AnswerPull(ok) => {
                    if let Some(index) = hub.mc.pending("vcs.pull") {
                        let result = if ok { Ok(json!({"status": "pulled", "refName": "feature"})) } else { Err(McError::new("no")) };
                        hub.mc.reply(&hub.engine, index, result);
                        model.pulling = false;
                    }
                }
                Op::Init => {
                    hub.dispatch("git.init", json!({}));
                    model.init = true;
                }
                Op::AnswerInit => {
                    if let Some(index) = hub.mc.pending("vcs.init") {
                        hub.mc.reply(&hub.engine, index, Ok(json!({})));
                        model.init = false;
                    }
                }
            }
            let state = pill(&hub);
            prop_assert_eq!(state["busy"].as_bool().unwrap(), model.running || model.pulling);
            prop_assert_eq!(actions(&hub).len(), usize::from(model.running));
            prop_assert_eq!(state["progress"].is_null(), !model.running);
            prop_assert_eq!(state["initPending"].as_bool().unwrap(), model.init);
            prop_assert_eq!(
                hub.mc.methods().iter().filter(|m| *m == "vcs.pull").count(),
                model.pulls
            );
        }
    }
}
