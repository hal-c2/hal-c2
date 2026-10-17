//! `threadLineage`: the open thread's source and forks, merging a fork back
//! and forking from a response (ThreadLineageController.cpp,
//! ThreadForkSteps.cpp, features/threads/forks.feature).

use hal_c2_shell::controllers::thread_lineage::ARRIVAL_TIMEOUT_MS;
use hal_c2_shell::json::Json;
use serde_json::json;

use crate::Hub;
use crate::page::{failure, toasts};

/// A thread row: `id`, its latest run's `status` (none: never ran), and
/// what else it carries.
fn thread(id: &str, status: Option<&str>, extra: Json) -> Json {
    let mut row = json!({"id": id, "projectId": "p1", "title": id.to_uppercase()});
    if let Some(status) = status {
        row["latestRunId"] = json!(format!("r-{id}"));
        row["status"] = json!(status);
        row["latestRunCompletedAt"] = if status == "completed" {
            json!("2026-09-21T14:00:00Z")
        } else {
            Json::Null
        };
    }
    for (k, v) in extra.as_object().cloned().unwrap_or_default() {
        row[k] = v;
    }
    row
}

fn fork_of(parent: &str) -> Json {
    json!({"lineage": {"relationshipToParent": "fork", "parentThreadId": parent, "rootThreadId": parent},
           "forkedFrom": {"threadId": parent, "runId": format!("r-{parent}")}})
}

/// A cluster of one MC, `a`, serving `env-1` with project `p1` and `rows`.
fn hub(rows: &[Json]) -> Hub {
    let hub = Hub::clustered();
    hub.mc.set_ready(&hub.engine, true);
    let mut listed =
        vec![json!(["a", "p1", "project", {"id": "p1", "title": "P", "workspaceRoot": "/work/p"}])];
    for row in rows {
        listed.push(json!(["a", row["id"], "thread", row]));
    }
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 1,
            "environment": {"environmentId": "env-1", "label": "Here"}}], "rows": listed}),
    );
    hub
}

/// The MC lists `row` too.
fn arrive(hub: &Hub, row: Json) {
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell.rows", "mc": "a", "epoch": "e", "rev": 2,
               "rows": [[row["id"], "thread", row]]}),
    );
}

fn family() -> Vec<Json> {
    vec![
        thread("t1", Some("completed"), json!({})),
        thread("t2", Some("running"), fork_of("t1")),
        thread("t3", Some("completed"), fork_of("t1")),
        thread("t4", None, json!({})),
    ]
}

fn open(hub: &Hub, thread: &str) {
    hub.dispatch("thread.open", json!({"key": format!("env-1:{thread}")}));
}

fn lineage(hub: &Hub) -> Json {
    hub.published("lineage")
}

fn shown(hub: &Hub) -> String {
    hub.published("route")["threadKey"]
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

/// The commands of `kind` sent so far, as indexes into the MC's calls.
fn commands(hub: &Hub, kind: &str) -> Vec<usize> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .enumerate()
        .filter(|(_, (_, m, p))| m == "orchestration.dispatchCommand" && p["type"] == kind)
        .map(|(i, _)| i)
        .collect()
}

fn payload(hub: &Hub, index: usize) -> Json {
    hub.mc.calls.borrow()[index].2.clone()
}

#[test]
fn a_source_lists_its_forks_and_counts_the_running_ones() {
    let hub = hub(&family());
    open(&hub, "t1");
    let shown = lineage(&hub);
    assert_eq!(shown["threadKey"], "env-1:t1");
    assert_eq!(shown["title"], "Lineage · 1 running");
    assert_eq!(shown["runningCount"], 1);
    assert_eq!(shown["parent"], Json::Null);
    let mut forks: Vec<Json> = shown["forks"].as_array().unwrap().clone();
    forks.sort_by_key(|f| f["key"].as_str().unwrap().to_owned());
    assert_eq!(
        forks,
        [
            json!({"key": "env-1:t2", "title": "T2", "running": true}),
            json!({"key": "env-1:t3", "title": "T3", "running": false}),
        ]
    );
    assert_eq!(shown["canMerge"], false);
    assert_eq!(shown["mergeHint"], "");

    // A thread with no relatives shows none.
    open(&hub, "t4");
    assert_eq!(lineage(&hub), Json::Null);
}

#[test]
fn a_fork_merges_back_once_it_has_finished_a_run() {
    let hub = hub(&family());
    open(&hub, "t2");
    let running = lineage(&hub);
    assert_eq!(
        running["parent"],
        json!({"key": "env-1:t1", "title": "T1", "missing": false, "subagent": false})
    );
    assert_eq!(running["canMerge"], false);
    assert_eq!(
        running["mergeHint"],
        "Complete a run in this fork before merging it back"
    );
    // Asked anyway, nothing is sent.
    hub.dispatch("lineage.mergeBack", json!({}));
    assert!(commands(&hub, "thread.merge_back").is_empty());

    open(&hub, "t3");
    let finished = lineage(&hub);
    assert_eq!(finished["canMerge"], true);
    assert_eq!(
        finished["mergeHint"],
        "Merge this conversation back into T1"
    );
    assert_eq!(finished["title"], "Lineage");

    hub.dispatch("lineage.mergeBack", json!({}));
    let sent = commands(&hub, "thread.merge_back");
    assert_eq!(sent.len(), 1);
    let command = payload(&hub, sent[0]);
    assert_eq!(command["sourceThreadId"], "t3");
    assert_eq!(command["targetThreadId"], "t1");
    assert_eq!(
        command["sourcePoint"],
        json!({"type": "run", "runId": "r-t3"})
    );
    assert_eq!(shown(&hub), "env-1:t3");
    // Merged, the window shows where it went.
    hub.mc.reply(&hub.engine, sent[0], Ok(json!({})));
    assert_eq!(shown(&hub), "env-1:t1");
}

#[test]
fn a_refused_merge_says_why_and_stays() {
    let hub = hub(&family());
    open(&hub, "t3");
    hub.dispatch("lineage.mergeBack", json!({}));
    let sent = commands(&hub, "thread.merge_back");
    hub.mc.reply(
        &hub.engine,
        sent[0],
        Err(failure("The source thread is busy")),
    );
    assert_eq!(shown(&hub), "env-1:t3");
    assert_eq!(
        toasts(&hub),
        [(
            "Failed to merge back".to_owned(),
            "The source thread is busy".to_owned()
        )]
    );
}

#[test]
fn a_source_that_is_gone_is_shown_as_unavailable_and_a_subagent_is_never_merged() {
    let hub = hub(&[
        thread("t2", Some("completed"), fork_of("gone")),
        thread("t1", Some("completed"), json!({})),
        thread(
            "t5",
            Some("completed"),
            json!({"lineage": {"relationshipToParent": "subagent", "parentThreadId": "t1"}}),
        ),
    ]);
    open(&hub, "t2");
    let orphan = lineage(&hub);
    assert_eq!(
        orphan["parent"],
        json!({"key": "env-1:gone", "title": "This related thread is unavailable",
               "missing": true, "subagent": false})
    );
    assert_eq!(orphan["canMerge"], false);
    assert_eq!(
        orphan["mergeHint"],
        "Merge this conversation back into its source"
    );
    // Its source cannot be opened.
    hub.dispatch("lineage.open", json!({"key": "env-1:gone"}));
    assert_eq!(shown(&hub), "env-1:t2");

    open(&hub, "t5");
    let subagent = lineage(&hub);
    assert_eq!(subagent["parent"]["subagent"], true);
    assert_eq!(subagent["parent"]["title"], "T1");
    assert_eq!(subagent["canMerge"], false);
    assert_eq!(subagent["mergeHint"], "");
    // A subagent's thread is not its parent's fork.
    open(&hub, "t1");
    assert_eq!(lineage(&hub), Json::Null);

    open(&hub, "t5");
    hub.dispatch("lineage.open", json!({"key": "env-1:t1"}));
    assert_eq!(shown(&hub), "env-1:t1");
}

#[test]
fn forking_from_a_response_opens_the_fork_once_it_is_listed() {
    let hub = hub(&family());
    open(&hub, "t1");
    hub.dispatch("thread.forkFromRun", json!({"runId": "r-t1"}));
    let sent = commands(&hub, "thread.fork");
    assert_eq!(sent.len(), 1);
    let command = payload(&hub, sent[0]);
    assert_eq!(command["sourceThreadId"], "t1");
    assert_eq!(
        command["sourcePoint"],
        json!({"type": "run", "runId": "r-t1"})
    );
    assert_eq!(command["title"], "T1 fork");
    let target = command["targetThreadId"].as_str().unwrap().to_owned();
    assert!(!target.is_empty() && target != "t1");

    // Accepted, the fork is not listed yet: the window stays.
    hub.mc.reply(&hub.engine, sent[0], Ok(json!({})));
    assert_eq!(shown(&hub), "env-1:t1");
    arrive(&hub, thread(&target, None, fork_of("t1")));
    assert_eq!(shown(&hub), format!("env-1:{target}"));
    // Late, it is not given up on.
    hub.advance(ARRIVAL_TIMEOUT_MS);
    assert!(toasts(&hub).is_empty(), "{:?}", toasts(&hub));
}

#[test]
fn a_fork_that_never_arrives_is_said() {
    let hub = hub(&family());
    open(&hub, "t1");
    hub.dispatch("thread.forkFromRun", json!({"runId": "r-t1"}));
    let sent = commands(&hub, "thread.fork");
    hub.mc.reply(&hub.engine, sent[0], Ok(json!({})));
    hub.advance(ARRIVAL_TIMEOUT_MS - 1);
    assert!(toasts(&hub).is_empty());
    hub.advance(1);
    assert_eq!(
        toasts(&hub),
        [(
            "The fork was created, but it did not reach this client".to_owned(),
            "Reconnect and try opening it from the thread list.".to_owned()
        )]
    );
    assert_eq!(shown(&hub), "env-1:t1");
}

#[test]
fn a_refused_fork_says_why() {
    let hub = hub(&family());
    open(&hub, "t1");
    // A response with no run is not forked from.
    hub.dispatch("thread.forkFromRun", json!({"runId": ""}));
    assert!(commands(&hub, "thread.fork").is_empty());
    hub.dispatch("thread.forkFromRun", json!({"runId": "r-t1"}));
    let sent = commands(&hub, "thread.fork");
    hub.mc
        .reply(&hub.engine, sent[0], Err(failure("Provider unavailable")));
    assert_eq!(
        toasts(&hub),
        [(
            "Failed to fork this response.".to_owned(),
            "Provider unavailable".to_owned()
        )]
    );
}
