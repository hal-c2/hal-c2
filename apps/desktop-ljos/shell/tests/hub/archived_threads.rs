//! `archivedThreads`: the Archive settings section, fetched when it opens
//! (ArchivedThreadsController.cpp, features/threads/archive.feature).

use std::path::PathBuf;

use chrono::{DateTime, Utc};
use hal_c2_shell::Launch;
use hal_c2_shell::controllers::archived_threads::ArchivedThreads;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::McError;
use serde_json::json;

use crate::Hub;

const METHOD: &str = "orchestration.getArchivedShellSnapshot";

fn hub() -> Hub {
    let hub = Hub::clustered();
    hub.with_controller::<ArchivedThreads, _>(|a, _| {
        a.set_clock(|| "2026-03-10T12:00:00Z".parse::<DateTime<Utc>>().unwrap())
    });
    hub
}

/// The cluster: `env-1` and `env-2` online, `env-3` not.
fn cluster(hub: &Hub) {
    let mc = |name: &str, environment: &str, online: bool| {
        json!({"mc": name, "online": online, "epoch": "e", "rev": 1,
            "environment": {"environmentId": environment, "label": environment}})
    };
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [mc("a", "env-1", true), mc("b", "env-2", true), mc("c", "env-3", false)], "rows": []}),
    );
}

fn open(hub: &Hub) {
    hub.dispatch("settings.navigate", json!({"to": "/settings/archived"}));
}

fn page(hub: &Hub) -> Json {
    hub.published("archivedThreads")
}

fn snapshot() -> Json {
    json!({
        "projects": [{"id": "p1", "title": "Alpha"}, {"id": "p2", "title": "Beta"}],
        "threads": [
            {"id": "t1", "projectId": "p1", "title": "Old one", "createdAt": "2026-03-01T12:00:00Z", "archivedAt": "2026-03-05T12:00:00Z"},
            {"id": "t2", "projectId": "p1", "title": "Newer", "createdAt": "2026-03-09T00:00:00Z", "archivedAt": "2026-03-10T11:59:30Z"},
            {"id": "t3", "projectId": "gone", "title": "Orphan", "createdAt": "2026-03-10T09:00:00Z", "archivedAt": "2026-03-10T10:00:00Z"},
        ],
    })
}

/// The commands of `kind` dispatched so far.
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

fn titles(group: &Json) -> Vec<String> {
    group["threads"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["title"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn nothing_is_asked_until_the_section_opens_then_each_online_environment_is() {
    let hub = hub();
    cluster(&hub);
    assert_eq!(page(&hub)["open"], false);
    assert!(hub.mc.methods().iter().all(|m| m != METHOD));
    open(&hub);
    let asked: Vec<String> = hub
        .mc
        .calls
        .borrow()
        .iter()
        .filter(|(_, m, _)| m == METHOD)
        .map(|(e, _, _)| e.clone())
        .collect();
    assert_eq!(asked, ["env-1", "env-2"]);
    let loading = page(&hub);
    assert_eq!(loading["status"], "loading");
    assert_eq!(loading["title"], "Loading archived threads");
}

#[test]
fn threads_group_by_project_newest_archived_first_with_their_ages() {
    let hub = hub();
    cluster(&hub);
    open(&hub);
    hub.mc
        .answer_on(&hub.engine, "env-1", METHOD, Ok(snapshot()));
    hub.mc.answer_on(
        &hub.engine,
        "env-2",
        METHOD,
        Ok(json!({"projects": [], "threads": []})),
    );
    let state = page(&hub);
    assert_eq!(state["status"], "ready");
    let groups = state["groups"].as_array().unwrap();
    assert_eq!(groups.len(), 2);
    assert_eq!(groups[0]["title"], "Alpha");
    assert_eq!(titles(&groups[0]), ["Newer", "Old one"]);
    assert_eq!(
        groups[0]["threads"][0]["description"],
        "Archived just now · Created 1d ago"
    );
    assert_eq!(
        groups[0]["threads"][1]["description"],
        "Archived 5d ago · Created 9d ago"
    );
    // A thread whose project is gone groups under the project's id.
    assert_eq!(groups[1]["title"], "gone");
    assert_eq!(groups[1]["threads"][0]["key"], "env-1:t3");
}

#[test]
fn no_archived_threads_says_so_and_a_failing_environment_says_why() {
    let hub = hub();
    cluster(&hub);
    open(&hub);
    hub.mc
        .answer_on(&hub.engine, "env-1", METHOD, Ok(json!({})));
    hub.mc.answer_on(
        &hub.engine,
        "env-2",
        METHOD,
        Err(McError::new("Not reachable.")),
    );
    let state = page(&hub);
    assert_eq!(state["status"], "error");
    assert_eq!(state["title"], "Could not load archived threads");
    assert_eq!(state["description"], "Not reachable.");
    hub.dispatch("archivedThreads.refresh", json!({}));
    hub.mc
        .answer_on(&hub.engine, "env-1", METHOD, Ok(json!({})));
    hub.mc
        .answer_on(&hub.engine, "env-2", METHOD, Ok(json!({})));
    assert_eq!(page(&hub)["status"], "empty");
    assert_eq!(page(&hub)["title"], "No archived threads");
}

#[test]
fn an_answer_to_an_earlier_load_is_dropped() {
    let hub = hub();
    cluster(&hub);
    open(&hub);
    let stale = hub.mc.pending_on("env-1", METHOD).unwrap();
    hub.dispatch("archivedThreads.refresh", json!({}));
    hub.mc.reply(&hub.engine, stale, Ok(snapshot()));
    assert_eq!(page(&hub)["groups"], json!([]));
    assert_eq!(page(&hub)["status"], "loading");
}

#[test]
fn unarchiving_removes_the_row_at_once_and_loads_again() {
    let hub = hub();
    cluster(&hub);
    open(&hub);
    hub.mc
        .answer_on(&hub.engine, "env-1", METHOD, Ok(snapshot()));
    hub.mc
        .answer_on(&hub.engine, "env-2", METHOD, Ok(json!({})));
    hub.dispatch(
        "archivedThreads.unarchive",
        json!({"environmentId": "env-1", "threadId": "t2"}),
    );
    assert_eq!(page(&hub)["groups"][0]["threads"][0]["busy"], true);
    // Twice is once.
    hub.dispatch(
        "archivedThreads.unarchive",
        json!({"environmentId": "env-1", "threadId": "t2"}),
    );
    let sent = commands(&hub, "thread.unarchive");
    assert_eq!(sent.len(), 1);
    let index = sent[0];
    assert_eq!(hub.mc.calls.borrow()[index].2["threadId"], "t2");
    hub.mc.reply(&hub.engine, index, Ok(json!({})));
    assert_eq!(titles(&page(&hub)["groups"][0]), ["Old one"]);
    assert!(hub.mc.pending_on("env-1", METHOD).is_some(), "listed again");
}

#[test]
fn a_failed_unarchive_toasts_and_frees_the_row() {
    let hub = hub();
    cluster(&hub);
    open(&hub);
    hub.mc
        .answer_on(&hub.engine, "env-1", METHOD, Ok(snapshot()));
    hub.mc
        .answer_on(&hub.engine, "env-2", METHOD, Ok(json!({})));
    hub.dispatch(
        "archivedThreads.unarchive",
        json!({"environmentId": "env-1", "threadId": "t2"}),
    );
    let index = commands(&hub, "thread.unarchive")[0];
    hub.mc.reply(&hub.engine, index, Err(McError::new("Nope.")));
    assert_eq!(page(&hub)["groups"][0]["threads"][0]["busy"], false);
    let toast = hub.published("toasts")["items"][0].clone();
    assert_eq!(toast["title"], "Failed to unarchive thread");
    assert_eq!(toast["description"], "Nope.");
}

#[test]
fn deleting_asks_first_when_the_user_wants_deletes_confirmed() {
    let hub = hub();
    cluster(&hub);
    open(&hub);
    hub.mc
        .answer_on(&hub.engine, "env-1", METHOD, Ok(snapshot()));
    hub.mc
        .answer_on(&hub.engine, "env-2", METHOD, Ok(json!({})));
    hub.dispatch(
        "archivedThreads.delete",
        json!({"environmentId": "env-1", "threadId": "t1"}),
    );
    let question = hub.published("confirmation");
    assert_eq!(question["title"], "Delete thread \"Old one\"?");
    assert_eq!(question["destructive"], true);
    assert!(commands(&hub, "thread.delete").is_empty());
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": true}),
    );
    assert_eq!(commands(&hub, "thread.delete").len(), 1);
}

#[test]
fn deleting_goes_straight_through_when_the_confirmation_is_off() {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("hub-archived-delete");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let hub = Hub::with(Launch {
        config_dir: Some(dir),
        mc_origin: Some("http://127.0.0.1:1".into()),
        ..Launch::default()
    });
    Settings::of(&hub.engine).write_device(&hub.engine, "confirmThreadDelete", json!(false));
    cluster(&hub);
    open(&hub);
    hub.mc
        .answer_on(&hub.engine, "env-1", METHOD, Ok(snapshot()));
    hub.mc
        .answer_on(&hub.engine, "env-2", METHOD, Ok(json!({})));
    hub.dispatch(
        "archivedThreads.delete",
        json!({"environmentId": "env-1", "threadId": "t1"}),
    );
    assert_eq!(hub.published("confirmation"), Json::Null);
    assert_eq!(commands(&hub, "thread.delete").len(), 1);
}

#[test]
fn an_environment_that_comes_online_is_listed_and_closing_forgets_the_lists() {
    let hub = hub();
    cluster(&hub);
    open(&hub);
    hub.mc
        .answer_on(&hub.engine, "env-1", METHOD, Ok(snapshot()));
    hub.mc
        .answer_on(&hub.engine, "env-2", METHOD, Ok(json!({})));
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [
            {"mc": "a", "online": true, "epoch": "e", "rev": 1, "environment": {"environmentId": "env-1", "label": "env-1"}},
            {"mc": "b", "online": true, "epoch": "e", "rev": 1, "environment": {"environmentId": "env-2", "label": "env-2"}},
            {"mc": "c", "online": true, "epoch": "e", "rev": 1, "environment": {"environmentId": "env-3", "label": "env-3"}},
        ], "rows": []}),
    );
    assert!(hub.mc.pending_on("env-3", METHOD).is_some());

    hub.dispatch("settings.navigate", json!({"to": "/settings/general"}));
    let closed = page(&hub);
    assert_eq!(closed["open"], false);
    assert_eq!(closed["groups"], json!([]));
}
