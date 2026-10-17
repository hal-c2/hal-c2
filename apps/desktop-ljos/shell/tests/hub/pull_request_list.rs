//! `pullRequestList`: the pull requests page, one `pullRequests.list` per
//! environment merged into groups (PullRequestListController.cpp,
//! features/source-control/).

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use serde_json::json;

use crate::Hub;

const LIST: &str = "pullRequests.list";
const AT: &str = "2026-03-01T00:00:00Z";

/// `env-1` and `env-2` online with a project each, and `env-3` offline.
fn cluster(hub: &Hub, third_online: bool) {
    let mc = |name: &str, environment: &str, online: bool| {
        json!({"mc": name, "online": online, "epoch": "e", "rev": 1,
            "environment": {"environmentId": environment, "label": format!("Env {environment}")}})
    };
    let project = |mc: &str, id: &str| json!([mc, id, "project", {"id": id, "title": format!("Project {id}"), "workspaceRoot": format!("/w/{id}"), "createdAt": AT, "updatedAt": AT}]);
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell",
            "mcs": [mc("a", "env-1", true), mc("b", "env-2", true), mc("c", "env-3", third_online)],
            "rows": [project("a", "p1"), project("b", "p2")]}),
    );
}

fn page(hub: &Hub) -> Json {
    hub.published("pullRequestList")
}

fn open(hub: &Hub) {
    hub.dispatch("pullRequests.open", json!({}));
}

fn entry(number: u32, title: &str, author: &str, updated: &str) -> Json {
    json!({
        "host": "github.com", "repository": "acme/app", "number": number, "title": title,
        "url": format!("https://github.com/acme/app/pull/{number}"), "state": "open",
        "author": {"login": author}, "updatedAt": updated, "projectId": "p1", "projectTitle": "Project p1",
        "labels": [{"name": "bug"}],
    })
}

fn listed(entries: Vec<Json>) -> Json {
    json!({"entries": entries, "viewers": {"github.com": "me"}, "errors": []})
}

fn keys(group: &Json) -> Vec<String> {
    group["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["key"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn the_page_asks_every_environment_when_opened_and_merges_newest_first_into_groups() {
    let hub = Hub::clustered();
    cluster(&hub, false);
    assert!(hub.mc.pending(LIST).is_none());
    open(&hub);
    assert_eq!(page(&hub)["loading"], true);
    let asked = hub
        .mc
        .calls
        .borrow()
        .iter()
        .filter(|(_, m, _)| m == LIST)
        .map(|(e, _, p)| (e.clone(), p.clone()))
        .collect::<Vec<_>>();
    assert_eq!(asked.len(), 2, "env-3 is offline and is not asked");
    assert_eq!(
        asked[0].1,
        json!({"state": "open", "involvement": "all", "limit": 99})
    );

    let mut review = entry(3, "Review me", "bob", "2026-03-03T00:00:00Z");
    review["viewerReviewRequested"] = json!(true);
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        LIST,
        Ok(listed(vec![
            entry(1, "Mine", "me", "2026-03-02T00:00:00Z"),
            entry(2, "Other", "carol", "2026-03-04T00:00:00Z"),
            review,
        ])),
    );
    assert_eq!(page(&hub)["loading"], true, "env-2 has not answered");
    hub.mc.answer_on(
        &hub.engine,
        "env-2",
        LIST,
        Ok(listed(vec![entry(
            4,
            "Remote",
            "me",
            "2026-03-05T00:00:00Z",
        )])),
    );
    let state = page(&hub);
    assert_eq!(state["loading"], false);
    assert_eq!(state["count"], 4);
    let groups = state["groups"].as_array().unwrap();
    let ids: Vec<&str> = groups.iter().map(|g| g["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["authored", "reviewRequested", "others"]);
    assert_eq!(
        keys(&groups[0]),
        ["env-2:github.com:acme/app#4", "env-1:github.com:acme/app#1"]
    );
    assert_eq!(groups[0]["rows"][0]["environmentLabel"], "Env env-2");
    assert_eq!(groups[0]["rows"][0]["labels"], json!(["bug"]));
    assert_eq!(state["empty"], Json::Null);
    // The offline one is said, not hidden.
    assert_eq!(state["environments"][2]["status"], "offline");
    assert_eq!(
        state["problems"][0],
        "Env env-3 cannot be reached; its pull requests are not listed."
    );
}

#[test]
fn a_failing_environment_does_not_hide_the_others_and_all_failing_is_an_error() {
    let hub = Hub::clustered();
    cluster(&hub, true);
    open(&hub);
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        LIST,
        Err(McError::new("GitHub is down.")),
    );
    hub.mc.answer_on(
        &hub.engine,
        "env-2",
        LIST,
        Ok(listed(vec![entry(9, "Fine", "me", AT)])),
    );
    hub.mc
        .answer_on(&hub.engine, "env-3", LIST, Ok(listed(vec![])));
    let state = page(&hub);
    assert_eq!(state["count"], 1);
    assert_eq!(state["problems"][0], "Env env-1: GitHub is down.");
    assert_eq!(state["error"], Json::Null);

    // Every one failing, nothing is listed.
    hub.dispatch(
        "pullRequestList.filter",
        json!({"name": "environmentId", "value": "env-1"}),
    );
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        LIST,
        Err(McError::new("GitHub is down.")),
    );
    let state = page(&hub);
    assert_eq!(state["error"]["title"], "Could not load pull requests");
    assert_eq!(state["error"]["message"], "GitHub is down.");
}

#[test]
fn an_answer_to_an_older_read_is_dropped() {
    let hub = Hub::clustered();
    cluster(&hub, false);
    open(&hub);
    let stale = hub.mc.pending_on("env-1", LIST).unwrap();
    hub.dispatch(
        "pullRequestList.filter",
        json!({"name": "state", "value": "merged"}),
    );
    hub.mc.reply(
        &hub.engine,
        stale,
        Ok(listed(vec![entry(1, "Old", "me", AT)])),
    );
    assert_eq!(page(&hub)["count"], 0);
    assert_eq!(page(&hub)["loading"], true);
}

#[test]
fn filters_narrow_the_ask_are_validated_and_kept_on_this_device() {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("hub-pull-requests-filters");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let launch = || Launch {
        config_dir: Some(dir.clone()),
        mc_origin: Some("http://127.0.0.1:1".into()),
        ..Launch::default()
    };
    let hub = Hub::with(launch());
    cluster(&hub, false);
    open(&hub);
    for (name, value) in [
        ("state", "closed"),
        ("draft", "hide"),
        ("checks", "failing"),
        ("query", "  fix  "),
        ("projectKey", "env-2:p2"),
    ] {
        hub.dispatch(
            "pullRequestList.filter",
            json!({"name": name, "value": value}),
        );
    }
    // Nonsense changes nothing.
    hub.dispatch(
        "pullRequestList.filter",
        json!({"name": "state", "value": "bogus"}),
    );
    hub.dispatch(
        "pullRequestList.filter",
        json!({"name": "color", "value": "red"}),
    );
    let state = page(&hub);
    assert_eq!(state["filters"]["state"], "closed");
    assert_eq!(state["filtered"], true);
    let last = hub
        .mc
        .calls
        .borrow()
        .iter()
        .rev()
        .find(|(_, m, _)| m == LIST)
        .cloned()
        .unwrap();
    // The project names its environment: only that one is asked.
    assert_eq!(last.0, "env-2");
    assert_eq!(
        last.2,
        json!({
            "state": "closed", "involvement": "all", "limit": 99,
            "filters": {"draft": "hide", "checks": "failing"}, "query": "fix", "projectId": "p2",
        })
    );

    let again = Hub::with(launch());
    cluster(&again, false);
    open(&again);
    let state = page(&again);
    assert_eq!(state["filters"]["state"], "closed");
    assert_eq!(state["filters"]["projectKey"], "env-2:p2");
    assert_eq!(state["filters"]["involvement"], "all");
}

#[test]
fn nothing_listed_says_why() {
    let hub = Hub::clustered();
    cluster(&hub, false);
    open(&hub);
    hub.mc
        .answer_on(&hub.engine, "env-1", LIST, Ok(listed(vec![])));
    hub.mc
        .answer_on(&hub.engine, "env-2", LIST, Ok(listed(vec![])));
    assert_eq!(page(&hub)["empty"]["title"], "No pull requests");
    hub.dispatch(
        "pullRequestList.filter",
        json!({"name": "review", "value": "approved"}),
    );
    hub.mc
        .answer_on(&hub.engine, "env-1", LIST, Ok(listed(vec![])));
    hub.mc
        .answer_on(&hub.engine, "env-2", LIST, Ok(listed(vec![])));
    assert_eq!(page(&hub)["empty"]["title"], "Nothing under these filters");
    hub.dispatch(
        "pullRequestList.filter",
        json!({"name": "query", "value": "needle"}),
    );
    hub.mc
        .answer_on(&hub.engine, "env-1", LIST, Ok(listed(vec![])));
    hub.mc
        .answer_on(&hub.engine, "env-2", LIST, Ok(listed(vec![])));
    assert_eq!(page(&hub)["empty"]["title"], "Nothing matches “needle”");
}

#[test]
fn a_refresh_makes_the_hosts_forget_then_reads_once_after_the_last() {
    let hub = Hub::clustered();
    cluster(&hub, false);
    open(&hub);
    hub.mc
        .answer_on(&hub.engine, "env-1", LIST, Ok(listed(vec![])));
    hub.mc
        .answer_on(&hub.engine, "env-2", LIST, Ok(listed(vec![])));
    let reads = |hub: &Hub| hub.mc.methods().iter().filter(|m| *m == LIST).count();
    hub.dispatch("pullRequestList.refresh", json!({}));
    assert_eq!(reads(&hub), 2);
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        "pullRequests.invalidate",
        Ok(json!({})),
    );
    assert_eq!(reads(&hub), 2, "env-2 has not forgotten yet");
    hub.mc.answer_on(
        &hub.engine,
        "env-2",
        "pullRequests.invalidate",
        Ok(json!({})),
    );
    assert_eq!(reads(&hub), 4);
}

#[test]
fn a_changed_revision_reads_again_but_the_first_frame_is_only_where_the_mc_is() {
    let hub = Hub::clustered();
    cluster(&hub, false);
    open(&hub);
    hub.mc
        .answer_on(&hub.engine, "env-1", LIST, Ok(listed(vec![])));
    hub.mc
        .answer_on(&hub.engine, "env-2", LIST, Ok(listed(vec![])));
    let reads = |hub: &Hub| hub.mc.methods().iter().filter(|m| *m == LIST).count();
    let send = |revision: u32| {
        hub.mc.frame(
            &hub.engine,
            "pullRequestRefreshes",
            "env-1",
            json!({"t": "pullRequestRefreshes", "revision": revision}),
        )
    };
    send(5);
    assert_eq!(reads(&hub), 2);
    send(5);
    assert_eq!(reads(&hub), 2);
    // News from one environment reads them all.
    send(6);
    assert_eq!(reads(&hub), 4);
}

#[test]
fn closing_the_page_stops_following_and_an_environment_coming_online_is_read() {
    let hub = Hub::clustered();
    cluster(&hub, false);
    open(&hub);
    let followed = |hub: &Hub| {
        hub.mc
            .subscriptions()
            .into_iter()
            .filter(|(_, s)| s["type"] == "pullRequestRefreshes")
            .count()
    };
    assert_eq!(followed(&hub), 2);
    cluster(&hub, true);
    assert!(hub.mc.pending_on("env-3", LIST).is_some());
    assert_eq!(followed(&hub), 3);
    hub.dispatch("settings.open", json!({}));
    assert_eq!(followed(&hub), 0);
    assert_eq!(page(&hub)["open"], false);
}

#[test]
fn a_row_opens_its_thread_and_on_its_host() {
    let hub = Hub::clustered();
    let opened = Rc::new(RefCell::new(Vec::<String>::new()));
    let sink = opened.clone();
    Bridge::of(&hub.engine).set_url_opener(&hub.engine, move |url| {
        sink.borrow_mut().push(url.to_owned())
    });
    cluster(&hub, false);
    open(&hub);
    hub.mc.answer_on(
        &hub.engine,
        "env-1",
        LIST,
        Ok(listed(vec![entry(1, "Mine", "me", AT)])),
    );
    hub.mc
        .answer_on(&hub.engine, "env-2", LIST, Ok(listed(vec![])));
    let key = "env-1:github.com:acme/app#1";

    hub.dispatch("pullRequestList.openOnHost", json!({"key": key}));
    assert_eq!(*opened.borrow(), ["https://github.com/acme/app/pull/1"]);

    // A failed lookup is said beside the row.
    hub.dispatch("pullRequestList.open", json!({"key": key}));
    let index = hub
        .mc
        .pending_on("env-1", "pullRequests.linkedThreads")
        .unwrap();
    hub.mc
        .reply(&hub.engine, index, Err(McError::new("Lost it.")));
    assert_eq!(
        page(&hub)["notice"],
        json!({"key": key, "kind": "error", "text": "Lost it."})
    );

    hub.dispatch("pullRequestList.open", json!({"key": key}));
    let index = hub
        .mc
        .pending_on("env-1", "pullRequests.linkedThreads")
        .unwrap();
    assert_eq!(
        hub.mc.calls.borrow()[index].2,
        json!({"projectId": "p1", "repository": "acme/app", "number": 1, "host": "github.com"})
    );
    // Newest first, an archived one only when there is no other.
    hub.mc.reply(
        &hub.engine,
        index,
        Ok(json!({"threads": [
            {"id": "t-archived", "archivedAt": AT}, {"id": "t-live"}, {"id": "t-older"},
        ]})),
    );
    let route = hub.published("route");
    assert_eq!(route["kind"], "thread");
    assert_eq!(route["threadKey"], "env-1:t-live");
}
