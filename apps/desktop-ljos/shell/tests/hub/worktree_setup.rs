//! `worktreeSetup`: how the open thread's new worktree is being prepared
//! (WorktreeSetupController.cpp, features/threads/worktree-setup.feature).

use hal_c2_shell::json::Json;
use serde_json::json;

use crate::Hub;
use crate::page::{failure, last, toasts};
use crate::workspace::{on_thread, project, shell, thread};

fn followed(hub: &Hub) -> Vec<Json> {
    hub.mc
        .subscriptions()
        .into_iter()
        .map(|(_, shape)| shape)
        .filter(|shape| shape["type"] == "worktreeSetup")
        .collect()
}

fn setup(hub: &Hub, event: Json) {
    hub.mc.frame(
        &hub.engine,
        "worktreeSetup",
        "",
        json!({"t": "worktreeSetup", "event": event}),
    );
}

fn running() -> Json {
    json!({"threadId": "t1", "phase": "running", "branch": "hal/feature", "baseRef": "main",
    "worktreePath": "/w/p-feature", "setupScript": {"name": "Install"},
    "stages": [
        {"id": "fetch", "status": "done", "detail": "origin/main"},
        {"id": "checkout", "status": "running", "tail": ["Updating files: 50%", 3]},
        {"id": "setup-script", "status": "pending"},
        {"id": "agent", "status": "pending"},
    ]})
}

fn state(hub: &Hub) -> Json {
    hub.published("worktreeSetup")
}

#[test]
fn the_thread_follows_its_setup_on_the_member_serving_it() {
    let hub = on_thread("main", None);
    assert_eq!(
        followed(&hub),
        [json!({"type": "worktreeSetup", "mc": "a", "threadId": "t1"})]
    );
    assert_eq!(state(&hub), Json::Null);

    setup(&hub, running());
    assert_eq!(
        state(&hub),
        json!({"threadKey": "env-1:t1", "phase": "running", "label": "Setting up worktree…",
        "error": "", "branch": "hal/feature", "baseRef": "main", "worktreePath": "/w/p-feature",
        "script": "Install", "canCancel": true, "detailsOpen": false,
        "stages": [
            {"id": "fetch", "label": "Fetch base branch", "status": "done", "detail": "origin/main", "tail": []},
            {"id": "checkout", "label": "Check out files", "status": "running", "detail": "",
             "tail": ["Updating files: 50%", "3"]},
            {"id": "setup-script", "label": "Run setup script", "status": "pending", "detail": "", "tail": []},
            {"id": "agent", "label": "Start agent", "status": "pending", "detail": "", "tail": []},
        ]})
    );

    // No setup tracked any more.
    setup(&hub, json!(null));
    assert_eq!(state(&hub), Json::Null);
}

#[test]
fn the_headline_says_how_the_setup_ended() {
    let hub = on_thread("main", None);
    let ended = |phase: &str, stage: &str| {
        let mut event = running();
        event["phase"] = phase.into();
        event["stages"] = json!([{"id": "setup-script", "status": stage}]);
        event
    };
    for (phase, stage, label) in [
        ("done", "done", "Worktree ready"),
        ("done", "failed", "Worktree ready, setup script failed"),
        ("failed", "failed", "Worktree setup failed"),
        ("cancelled", "pending", "Worktree setup cancelled"),
    ] {
        setup(&hub, ended(phase, stage));
        assert_eq!(state(&hub)["label"], label, "{phase} {stage}");
        assert_eq!(state(&hub)["canCancel"], false);
    }
    let mut failed = ended("failed", "failed");
    failed["error"] = "git fetch failed".into();
    setup(&hub, failed);
    assert_eq!(state(&hub)["error"], "git fetch failed");
}

#[test]
fn the_details_open_and_close_and_start_closed_on_another_thread() {
    let hub = Hub::clustered();
    shell(
        &hub,
        vec![
            project(json!({})),
            thread("t1", "main", None),
            thread("t2", "main", None),
        ],
    );
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    setup(&hub, running());
    hub.dispatch("worktreeSetup.details", json!({"open": true}));
    assert_eq!(state(&hub)["detailsOpen"], true);
    hub.dispatch("worktreeSetup.details", json!({"open": false}));
    assert_eq!(state(&hub)["detailsOpen"], false);
    hub.dispatch("worktreeSetup.details", json!({"open": true}));

    hub.dispatch("thread.open", json!({"key": "env-1:t2"}));
    assert_eq!(state(&hub), Json::Null);
    assert_eq!(
        followed(&hub),
        [json!({"type": "worktreeSetup", "mc": "a", "threadId": "t2"})]
    );
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    assert_eq!(state(&hub), Json::Null);
    setup(&hub, running());
    assert_eq!(state(&hub)["detailsOpen"], false);

    // Off a thread nothing is followed.
    hub.dispatch("usage.open", json!({}));
    assert!(followed(&hub).is_empty());
    assert_eq!(state(&hub), Json::Null);
}

#[test]
fn cancelling_asks_the_mc_and_says_when_it_cannot() {
    let hub = on_thread("main", None);
    setup(&hub, running());
    hub.dispatch("worktreeSetup.cancel", json!({}));
    assert_eq!(
        last(&hub, "env-1", "worktreeSetup.cancel"),
        json!({"threadId": "t1"})
    );
    hub.mc.answer(
        &hub.engine,
        "worktreeSetup.cancel",
        Ok(json!({"cancelled": true})),
    );
    assert!(toasts(&hub).is_empty());

    hub.dispatch("worktreeSetup.cancel", json!({}));
    hub.mc.answer(
        &hub.engine,
        "worktreeSetup.cancel",
        Ok(json!({"cancelled": false})),
    );
    hub.dispatch("worktreeSetup.cancel", json!({}));
    hub.mc
        .answer(&hub.engine, "worktreeSetup.cancel", Err(failure("MC gone")));
    // Newest first.
    assert_eq!(
        toasts(&hub),
        [
            (
                "Could not cancel the worktree setup".to_owned(),
                "MC gone".to_owned()
            ),
            (
                "Could not cancel the worktree setup".to_owned(),
                "The agent has already started.".to_owned()
            ),
        ]
    );
}
