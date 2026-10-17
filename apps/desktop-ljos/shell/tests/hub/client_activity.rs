//! `clientActivity`: what the window tells the MC it is looking at, and
//! when (ClientActivityController.cpp, features/background/).

use hal_c2_shell::controllers::client_activity::REPORT_MS;
use hal_c2_shell::json::Json;
use ljos::prelude::ApplicationState;
use serde_json::json;

use crate::Hub;
use crate::composer::{open, thread_row};
use crate::workspace::{clustered, project, shell, thread};

const REPORT: &str = "server.reportClientActivity";

/// A hub with the MC up, project p1 at /w/p, its thread t1 there and its
/// thread t2 in the worktree /w/wt, showing t1.
pub fn hub(test: &str) -> Hub {
    let hub = clustered(crate::composer::launch_in(test));
    hub.mc.set_ready(&hub.engine, true);
    shell(
        &hub,
        vec![
            project(json!({})),
            thread_row("t1"),
            thread("t2", "main", Some("/w/wt")),
        ],
    );
    open(&hub, "t1");
    hub
}

/// Every report the window made, oldest first.
pub fn reports(hub: &Hub) -> Vec<(String, Json)> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .filter(|(_, method, _)| method == REPORT)
        .map(|(environment, _, payload)| (environment.clone(), payload.clone()))
        .collect()
}

/// The scopes of `report`, as `thread:<id>` or `vcs:<cwd>`; provider
/// status is in every one and left out.
pub fn watched(report: &Json) -> Vec<String> {
    report["scopes"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|scope| match scope["type"].as_str()? {
            "thread" => Some(format!("thread:{}", scope["threadId"].as_str()?)),
            "vcs-status" => Some(format!("vcs:{}", scope["cwd"].as_str()?)),
            "provider-status" => None,
            other => panic!("a scope the MC does not know: {other}"),
        })
        .collect()
}

#[test]
fn the_shown_thread_and_its_checkout_are_watched_and_reported_again_as_they_change() {
    let hub = hub("scopes");
    let last = || reports(&hub).pop().expect("a report");
    let (environment, report) = last();
    assert_eq!(environment, "env-1");
    assert_eq!(report["scopes"][0], json!({"type": "provider-status"}));
    assert_eq!(watched(&report), ["thread:t1", "vcs:/w/p"]);

    // The other thread is checked out in its own worktree.
    let before = reports(&hub).len();
    open(&hub, "t2");
    assert_eq!(reports(&hub).len(), before + 1);
    assert_eq!(watched(&last().1), ["thread:t2", "vcs:/w/wt"]);

    // Showing what is shown says nothing.
    open(&hub, "t2");
    assert_eq!(reports(&hub).len(), before + 1);

    // A draft is no thread to the MC, though it has a checkout.
    hub.dispatch("thread.new", json!(null));
    assert_eq!(reports(&hub).len(), before + 2);
    assert_eq!(watched(&last().1), ["vcs:/w/p"]);

    // A page that shows no thread watches providers alone.
    hub.dispatch("usage.open", json!({}));
    assert_eq!(reports(&hub).len(), before + 3);
    assert_eq!(watched(&last().1), Vec::<String>::new());
    assert_eq!(last().0, "env-1");
}

#[test]
fn focus_follows_the_application_state() {
    let hub = hub("focus");
    let last = || reports(&hub).pop().expect("a report").1;
    assert_eq!(last()["focused"], json!(true));
    assert_eq!(last()["appState"], json!("active"));

    let before = reports(&hub).len();
    ljos::testing::set_application_state(&hub.engine, ApplicationState::Inactive);
    assert_eq!(reports(&hub).len(), before + 1);
    let report = last();
    assert_eq!(report["focused"], json!(false));
    assert_eq!(report["recentlyInteracted"], json!(false));
    assert_eq!(report["appState"], json!("inactive"));
    assert_eq!(report["visible"], json!(true));
    // What is shown stays watched while the window is behind another.
    assert_eq!(watched(&report), ["thread:t1", "vcs:/w/p"]);

    // Hidden is no more focused; Qt tells each state.
    ljos::testing::set_application_state(&hub.engine, ApplicationState::Hidden);
    assert_eq!(reports(&hub).len(), before + 2);
    assert_eq!(last()["focused"], json!(false));

    ljos::testing::set_application_state(&hub.engine, ApplicationState::Active);
    assert_eq!(reports(&hub).len(), before + 3);
    assert_eq!(last()["focused"], json!(true));
    assert_eq!(last()["appState"], json!("active"));

    // The same state again is no change.
    ljos::testing::set_application_state(&hub.engine, ApplicationState::Active);
    assert_eq!(reports(&hub).len(), before + 3);
}

#[test]
fn nothing_is_said_to_an_mc_that_is_not_there_and_all_of_it_when_it_is_back() {
    let hub = hub("gone");
    hub.mc.set_ready(&hub.engine, false);
    let before = reports(&hub).len();
    open(&hub, "t2");
    ljos::testing::set_application_state(&hub.engine, ApplicationState::Inactive);
    hub.advance(REPORT_MS as u64);
    assert_eq!(reports(&hub).len(), before);

    // A new connection holds none of this client's leases: the one report
    // says what the window shows now.
    hub.mc.set_ready(&hub.engine, true);
    assert_eq!(reports(&hub).len(), before + 1);
    let report = reports(&hub).pop().unwrap().1;
    assert_eq!(watched(&report), ["thread:t2", "vcs:/w/wt"]);
    assert_eq!(report["focused"], json!(false));
}
