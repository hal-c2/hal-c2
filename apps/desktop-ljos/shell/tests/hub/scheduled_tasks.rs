//! Settings → Scheduled Tasks (`scheduledTasks`).

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::scheduled_tasks::{relative_label, schedule_label};
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::page::{answer, count, failure, last, open, send_config, toasts};

const SECTION: &str = "/settings/scheduled-tasks";
const UPSERT: &str = "scheduledTasks.upsert";

fn state(hub: &Hub) -> serde_json::Value {
    hub.published("scheduledTasks")
}

/// A hub in a cluster of one MC with a project, so the editor has somewhere
/// to put a task.
fn clustered() -> (Hub, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let hub = Hub::with(Launch {
        mc_origin: Some("http://127.0.0.1:3773".into()),
        cache_dir: Some(dir.path().to_owned()),
        ..Launch::default()
    });
    hub.mc.set_ready(&hub.engine, true);
    send_config(&hub, json!({"settings": {}, "providers": []}), 1);
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell",
               "mcs": [{"mc": "mc-1",
                        "environment": {"environmentId": "env-1", "label": "Laptop", "capabilities": {}},
                        "online": true, "epoch": "e1", "rev": 1}],
               "rows": [["mc-1", "p1", "project",
                         {"id": "p1", "title": "Ljos", "workspaceRoot": "/w/ljos"}]]}),
    );
    (hub, dir)
}

fn task(id: &str, enabled: bool) -> serde_json::Value {
    json!({"id": id, "title": format!("Task {id}"), "prompt": "do it", "enabled": enabled,
           "schedule": {"type": "fixed_time", "timeOfDay": "09:00", "weekdays": [1, 2, 3, 4, 5]},
           "projectId": "p1", "workspaceStrategy": {"type": "root"},
           "modelSelection": {"instanceId": "codex", "model": "gpt-x"},
           "lastRunStatus": ""})
}

fn listed(hub: &Hub, tasks: &[serde_json::Value]) {
    hub.mc.frame(
        &hub.engine,
        "scheduledTasks",
        "",
        json!({"t": "scheduledTasks", "tasks": tasks}),
    );
}

fn ready(tasks: &[serde_json::Value]) -> (Hub, tempfile::TempDir) {
    let (hub, dir) = clustered();
    open(&hub, SECTION);
    listed(&hub, tasks);
    (hub, dir)
}

fn draft(editor_state: &serde_json::Value) -> serde_json::Value {
    let mut draft = editor_state["draft"].clone();
    draft["title"] = json!("Nightly");
    draft["prompt"] = json!("Run the tests");
    draft["modelKey"] = json!("codex:gpt-x");
    draft
}

#[test]
fn schedules_and_times_read_as_the_page_shows_them() {
    assert_eq!(
        schedule_label(&json!({"type": "interval", "everyMs": 900_000})),
        "Every 15 min"
    );
    assert_eq!(
        schedule_label(&json!({"type": "interval", "everyMs": 30_000})),
        "Every 30 sec"
    );
    assert_eq!(
        schedule_label(
            &json!({"type": "fixed_time", "timeOfDay": "09:00", "weekdays": [1, 2, 3, 4, 5]})
        ),
        "Weekdays at 09:00"
    );
    assert_eq!(
        schedule_label(&json!({"type": "fixed_time", "timeOfDay": "07:30"})),
        "Daily at 07:30"
    );
    assert_eq!(
        schedule_label(&json!({"type": "fixed_time", "timeOfDay": "07:30", "weekdays": [0, 6]})),
        "Sun, Sat at 07:30"
    );
    let now = 1_700_000_000_000;
    let at = |ms: i64| {
        chrono::DateTime::from_timestamp_millis(now + ms)
            .unwrap()
            .to_rfc3339()
    };
    assert_eq!(relative_label(&at(5 * 60_000), now), "in 5m");
    assert_eq!(relative_label(&at(10_000), now), "in under a minute");
    assert_eq!(relative_label(&at(3 * 3_600_000), now), "in 3h");
    assert_eq!(relative_label(&at(-2 * 3_600_000), now), "2h ago");
    assert_eq!(relative_label(&at(-1000), now), "just now");
    assert_eq!(relative_label("", now), "Not scheduled");
}

#[test]
fn the_section_follows_the_tasks_while_it_shows() {
    let (hub, _dir) = clustered();
    assert!(
        hub.mc
            .subscriptions()
            .iter()
            .all(|(_, s)| s["type"] != "scheduledTasks")
    );
    open(&hub, SECTION);
    assert_eq!(state(&hub)["environments"][0]["status"], "loading");
    listed(&hub, &[task("a", false)]);
    let shown = state(&hub)["environments"][0].clone();
    assert_eq!(shown["status"], "ready");
    assert_eq!(shown["tasks"][0]["schedule"], "Weekdays at 09:00");
    assert_eq!(shown["tasks"][0]["when"], "Paused");
    assert_eq!(shown["tasks"][0]["lastRunStatus"], "never");

    hub.dispatch("settings.navigate", json!({"to": "/settings/general"}));
    assert!(
        hub.mc
            .subscriptions()
            .iter()
            .all(|(_, s)| s["type"] != "scheduledTasks")
    );
    assert_eq!(state(&hub)["open"], false);
}

#[test]
fn the_next_run_reads_against_the_shells_clock() {
    let (hub, _dir) = clustered();
    hub.engine.set_wall_clock_origin(Some(1_700_000_000_000.0));
    open(&hub, SECTION);
    let mut due = task("a", true);
    due["nextRunAt"] = json!(
        chrono::DateTime::from_timestamp_millis(1_700_000_000_000 + 3 * 3_600_000)
            .unwrap()
            .to_rfc3339()
    );
    listed(&hub, &[due]);
    assert_eq!(
        state(&hub)["environments"][0]["tasks"][0]["when"],
        "Next run in 3h"
    );
}

#[test]
fn a_task_is_enabled_run_and_deleted_one_call_at_a_time() {
    let (hub, _dir) = ready(&[task("a", false)]);
    hub.dispatch(
        "scheduledTasks.enable",
        json!({"environmentId": "env-1", "id": "a", "enabled": true}),
    );
    assert_eq!(
        last(&hub, "env-1", "scheduledTasks.setEnabled"),
        json!({"id": "a", "enabled": true})
    );
    assert_eq!(state(&hub)["environments"][0]["tasks"][0]["busy"], true);
    hub.dispatch(
        "scheduledTasks.run",
        json!({"environmentId": "env-1", "id": "a"}),
    );
    assert_eq!(count(&hub, "scheduledTasks.runNow"), 0);
    answer(
        &hub,
        "env-1",
        "scheduledTasks.setEnabled",
        Err(failure("gone")),
    );
    assert!(
        toasts(&hub)
            .iter()
            .any(|(t, d)| t == "Could not update scheduled task" && d == "gone")
    );
    assert_eq!(state(&hub)["environments"][0]["tasks"][0]["busy"], false);

    hub.dispatch(
        "scheduledTasks.run",
        json!({"environmentId": "env-1", "id": "a"}),
    );
    assert_eq!(count(&hub, "scheduledTasks.runNow"), 1);
    // A task not listed is not acted on.
    hub.dispatch(
        "scheduledTasks.delete",
        json!({"environmentId": "env-1", "id": "zz"}),
    );
    assert_eq!(count(&hub, "scheduledTasks.delete"), 0);
}

#[test]
fn a_new_task_is_checked_before_it_is_sent() {
    let (hub, _dir) = ready(&[]);
    hub.dispatch("scheduledTasks.new", json!({}));
    let editor = state(&hub)["editor"].clone();
    assert_eq!(editor["draft"]["projectId"], "p1");
    assert_eq!(editor["connected"], true);

    // No title, prompt or model yet.
    hub.dispatch("scheduledTasks.save", json!({"draft": editor["draft"]}));
    assert!(
        toasts(&hub)
            .iter()
            .any(|(t, _)| t == "Scheduled task is incomplete")
    );
    assert_eq!(count(&hub, UPSERT), 0);

    let mut bad = draft(&editor);
    bad["scheduleMode"] = json!("interval");
    bad["intervalMinutes"] = json!("0.5");
    hub.dispatch("scheduledTasks.save", json!({"draft": bad}));
    assert!(toasts(&hub).iter().any(|(t, _)| t == "Invalid interval"));

    let mut bad = draft(&editor);
    bad["workspaceMode"] = json!("existing_worktree");
    hub.dispatch("scheduledTasks.save", json!({"draft": bad}));
    assert!(
        toasts(&hub)
            .iter()
            .any(|(t, _)| t == "Checkout path is required")
    );
    assert_eq!(count(&hub, UPSERT), 0);
}

#[test]
fn saving_sends_the_task_once_and_closes_the_editor_when_saved() {
    let (hub, _dir) = ready(&[]);
    hub.dispatch("scheduledTasks.new", json!({}));
    let editor = state(&hub)["editor"].clone();
    hub.dispatch("scheduledTasks.save", json!({"draft": draft(&editor)}));
    let sent = last(&hub, "env-1", UPSERT);
    assert_eq!(sent["title"], "Nightly");
    assert_eq!(
        sent["schedule"],
        json!({"type": "fixed_time", "timeOfDay": "09:00", "weekdays": [1, 2, 3, 4, 5]})
    );
    assert_eq!(
        sent["modelSelection"],
        json!({"instanceId": "codex", "model": "gpt-x"})
    );
    assert_eq!(sent["workspaceStrategy"]["type"], "worktree");
    assert_eq!(state(&hub)["editor"]["saving"], true);

    // Saving, so neither a second save nor a close lands.
    hub.dispatch("scheduledTasks.save", json!({"draft": draft(&editor)}));
    hub.dispatch("scheduledTasks.close", json!({}));
    assert_eq!(count(&hub, UPSERT), 1);
    assert_eq!(state(&hub)["editor"]["saving"], true);

    answer(&hub, "env-1", UPSERT, Ok(json!({})));
    assert_eq!(state(&hub)["editor"], serde_json::Value::Null);
}

#[test]
fn a_failed_save_keeps_the_draft_and_an_old_reply_leaves_a_new_editor_alone() {
    let (hub, _dir) = ready(&[task("a", true)]);
    hub.dispatch("scheduledTasks.new", json!({}));
    let editor = state(&hub)["editor"].clone();
    hub.dispatch("scheduledTasks.save", json!({"draft": draft(&editor)}));
    answer(&hub, "env-1", UPSERT, Err(failure("db down")));
    assert!(
        toasts(&hub)
            .iter()
            .any(|(t, d)| t == "Could not save scheduled task" && d == "db down")
    );
    assert_eq!(state(&hub)["editor"]["saving"], false);
    assert_eq!(state(&hub)["editor"]["draft"]["title"], "Nightly");

    // Edit saves with the task's id; a reply after the editor moved on does
    // not close the one that replaced it.
    hub.dispatch(
        "scheduledTasks.edit",
        json!({"environmentId": "env-1", "id": "a"}),
    );
    let editing = state(&hub)["editor"].clone();
    assert_eq!(editing["editing"], true);
    hub.dispatch("scheduledTasks.save", json!({"draft": draft(&editing)}));
    assert_eq!(last(&hub, "env-1", UPSERT)["id"], "a");
    assert_eq!(last(&hub, "env-1", UPSERT)["requireExisting"], true);
    hub.dispatch("scheduledTasks.editorEnvironment", json!({"id": "env-1"})); // ignored: not a new task
    answer(&hub, "env-1", UPSERT, Ok(json!({})));
    assert_eq!(state(&hub)["editor"], serde_json::Value::Null);
}

#[test]
fn a_link_opens_the_section_and_then_the_task() {
    let (hub, _dir) = clustered();
    hub.dispatch(
        "scheduledTasks.open",
        json!({"environmentId": "env-1", "taskId": "a"}),
    );
    assert_eq!(hub.published("route")["section"], SECTION);
    listed(&hub, &[task("a", true)]);
    assert_eq!(state(&hub)["editor"]["editing"], true);
    assert_eq!(state(&hub)["editor"]["draft"]["title"], "Task a");

    // One that is gone is said to be.
    let (hub, _dir) = clustered();
    hub.dispatch(
        "scheduledTasks.open",
        json!({"environmentId": "env-1", "taskId": "nope"}),
    );
    listed(&hub, &[task("a", true)]);
    assert_eq!(state(&hub)["environments"][0]["linkMissing"], true);
    assert_eq!(state(&hub)["editor"], serde_json::Value::Null);
}

#[test]
fn branches_are_listed_for_the_editors_project_and_the_latest_ask_wins() {
    let (hub, _dir) = ready(&[]);
    hub.dispatch("scheduledTasks.new", json!({}));
    hub.dispatch(
        "scheduledTasks.branches",
        json!({"projectId": "p1", "query": ""}),
    );
    hub.dispatch(
        "scheduledTasks.branches",
        json!({"projectId": "p1", "query": " fea "}),
    );
    assert_eq!(
        last(&hub, "env-1", "vcs.listRefs"),
        json!({"cwd": "/w/ljos", "limit": 20, "query": "fea"})
    );
    answer(
        &hub,
        "env-1",
        "vcs.listRefs",
        Ok(json!({"refs": [{"name": "old"}]})),
    );
    assert_eq!(state(&hub)["editor"]["branchesLoading"], true);
    answer(
        &hub,
        "env-1",
        "vcs.listRefs",
        Ok(json!({"refs": [{"name": "feature", "isDefault": false}], "totalCount": 9})),
    );
    let editor = state(&hub)["editor"].clone();
    assert_eq!(editor["branches"][0]["name"], "feature");
    assert_eq!(editor["branchesTotal"], 9);
    assert_eq!(editor["branchesLoading"], false);
    // A project the MC has no root for lists nothing.
    hub.dispatch(
        "scheduledTasks.branches",
        json!({"projectId": "none", "query": ""}),
    );
    assert_eq!(count(&hub, "vcs.listRefs"), 2);
    assert_eq!(state(&hub)["editor"]["branches"], json!([]));
}

#[derive(Clone, Debug)]
enum Step {
    New,
    Save,
    Close,
    Answer(usize, bool),
}

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        Just(Step::New),
        Just(Step::Save),
        Just(Step::Close),
        (0usize..30, any::<bool>()).prop_map(|(i, ok)| Step::Answer(i, ok)),
    ]
}

proptest! {
    /// Whatever the order of saves, closes and replies, the editor is saving
    /// only while it is open, and a save in flight is never closed under it.
    #[test]
    fn saving_only_while_open(steps in proptest::collection::vec(step(), 1..24)) {
        let (hub, _dir) = ready(&[]);
        for step in steps {
            match step {
                Step::New => hub.dispatch("scheduledTasks.new", json!({})),
                Step::Save => {
                    let editor = state(&hub)["editor"].clone();
                    if !editor.is_null() {
                        hub.dispatch("scheduledTasks.save", json!({"draft": draft(&editor)}));
                    }
                }
                Step::Close => hub.dispatch("scheduledTasks.close", json!({})),
                Step::Answer(i, ok) => {
                    let asked = hub.mc.calls.borrow().len();
                    let result = if ok { Ok(json!({})) } else { Err(failure("no")) };
                    hub.mc.reply(&hub.engine, i % asked, result);
                }
            }
            let editor = state(&hub)["editor"].clone();
            if editor.is_null() {
                continue;
            }
            if editor["saving"] == true {
                let in_flight = hub.mc.calls.borrow().iter().enumerate()
                    .any(|(i, (_, m, _))| m == UPSERT && hub.mc.is_pending(i));
                prop_assert!(in_flight);
            }
        }
    }
}
