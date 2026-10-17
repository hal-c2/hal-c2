//! `limitRecovery`: continuing or snoozing a thread whose agent stopped on
//! a usage limit (LimitRecoveryController.cpp, ThreadLimitSteps.cpp,
//! features/threads/usage-limits.feature).

use hal_c2_shell::json::Json;
use serde_json::json;

use crate::Hub;
use crate::page::failure;

/// The wall clock: 2026-09-21T14:13:20Z.
const NOW_MS: f64 = 1_790_000_000_000.0;
const STOPPED: &str = "2026-09-21T13:13:20Z";
const RESET: &str = "2026-09-21T15:13:20Z";

/// Thread `t1`, stopped on a usage limit that resets at `reset` (none: the
/// agent did not say), with `extra` fields; `t2` beside it, ready.
fn hub(reset: Option<&str>, extra: Json) -> Hub {
    let hub = Hub::clustered();
    hub.engine.set_wall_clock_origin(Some(NOW_MS));
    hub.mc.set_ready(&hub.engine, true);
    list(&hub, reset, extra, 1);
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    hub
}

fn list(hub: &Hub, reset: Option<&str>, extra: Json, rev: i64) {
    let mut limited = json!({"id": "t1", "projectId": "p1", "title": "T1", "latestRunId": "run-1",
        "status": "failed", "lastErrorClass": "usage_limit", "latestRunCompletedAt": STOPPED,
        "updatedAt": STOPPED});
    if let Some(reset) = reset {
        limited["usageLimitResetAt"] = json!(reset);
    }
    for (k, v) in extra.as_object().cloned().unwrap_or_default() {
        limited[k] = v;
    }
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": rev,
        "environment": {"environmentId": "env-1", "label": "Here"}}],
        "rows": [
            ["a", "p1", "project", {"id": "p1", "title": "P", "workspaceRoot": "/work/p"}],
            ["a", "t1", "thread", limited],
            ["a", "t2", "thread", {"id": "t2", "projectId": "p1", "title": "T2"}],
        ]}),
    );
}

fn banner(hub: &Hub) -> Json {
    hub.published("limitRecovery")
}

/// The `limitRecovery` the last `thread.metadata.update` asked for, and its
/// index in the MC's calls.
fn last_update(hub: &Hub) -> Option<(usize, Json)> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .enumerate()
        .rev()
        .find(|(_, (_, m, p))| {
            m == "orchestration.dispatchCommand" && p["type"] == "thread.metadata.update"
        })
        .map(|(i, (e, _, p))| {
            assert_eq!(e, "env-1");
            assert_eq!(p["threadId"], "t1");
            (i, p["limitRecovery"].clone())
        })
}

#[test]
fn a_limited_thread_offers_to_continue_or_snooze_until_the_reset() {
    let hub = hub(Some(RESET), json!({}));
    let shown = banner(&hub);
    assert_eq!(shown["threadKey"], "env-1:t1");
    assert_eq!(shown["title"], "Usage limit reached");
    assert!(
        shown["description"]
            .as_str()
            .unwrap()
            .starts_with("Resets "),
        "{shown}"
    );
    assert_eq!(shown["canSchedule"], true);
    assert_eq!(shown["canSnooze"], true);
    assert_eq!(shown["scheduled"], false);
    assert_eq!(shown["snoozed"], false);
    assert_eq!(shown["error"], "");

    // Another thread has no banner.
    hub.dispatch("thread.open", json!({"key": "env-1:t2"}));
    assert_eq!(banner(&hub), Json::Null);
}

#[test]
fn continuing_and_snoozing_are_armed_by_the_mc_and_disarmed_again() {
    let hub = hub(Some(RESET), json!({}));
    hub.dispatch("limitRecovery.resume", json!({}));
    let (index, update) = last_update(&hub).expect("the MC was asked");
    assert_eq!(
        update,
        json!({"runId": "run-1", "resetAt": RESET, "autoResume": true})
    );
    hub.mc.reply(&hub.engine, index, Ok(json!({})));
    // The row says what is armed.
    list(
        &hub,
        Some(RESET),
        json!({"limitRecovery": {"runId": "run-1", "resetAt": RESET, "autoResume": true}}),
        2,
    );
    assert_eq!(banner(&hub)["scheduled"], true);
    hub.dispatch("limitRecovery.resume", json!({}));
    assert_eq!(last_update(&hub).unwrap().1["autoResume"], false);

    hub.dispatch("limitRecovery.snooze", json!({}));
    assert_eq!(
        last_update(&hub).unwrap().1,
        json!({"runId": "run-1", "resetAt": RESET, "snooze": true})
    );
    list(
        &hub,
        Some(RESET),
        json!({"snoozedUntil": RESET,
               "limitRecovery": {"runId": "run-1", "resetAt": RESET, "snooze": true}}),
        3,
    );
    assert_eq!(banner(&hub)["snoozed"], true);
    hub.dispatch("limitRecovery.snooze", json!({}));
    assert_eq!(last_update(&hub).unwrap().1["snooze"], false);
}

#[test]
fn what_another_run_armed_is_not_this_ones() {
    let hub = hub(
        Some(RESET),
        json!({"limitRecovery": {"runId": "run-0", "resetAt": RESET, "autoResume": true}}),
    );
    assert_eq!(banner(&hub)["scheduled"], false);
}

#[test]
fn a_refused_change_is_shown_until_the_next_one() {
    let hub = hub(Some(RESET), json!({}));
    hub.dispatch("limitRecovery.resume", json!({}));
    let (index, _) = last_update(&hub).unwrap();
    hub.mc
        .reply(&hub.engine, index, Err(failure("The thread is gone")));
    assert_eq!(banner(&hub)["error"], "The thread is gone");
    hub.dispatch("limitRecovery.resume", json!({}));
    assert_eq!(banner(&hub)["error"], "");
}

#[test]
fn without_a_reset_time_nothing_can_be_armed() {
    let hub = hub(None, json!({}));
    let shown = banner(&hub);
    assert_eq!(
        shown["description"],
        "Reset time unavailable; retry manually"
    );
    assert_eq!(shown["canSchedule"], false);
    assert_eq!(shown["canSnooze"], false);
    hub.dispatch("limitRecovery.resume", json!({}));
    hub.dispatch("limitRecovery.snooze", json!({}));
    assert!(last_update(&hub).is_none());
}

#[test]
fn once_the_reset_has_passed_the_thread_is_not_snoozed() {
    // The limit reset ten minutes ago.
    let hub = hub(Some("2026-09-21T14:03:20Z"), json!({}));
    assert_eq!(banner(&hub)["canSnooze"], false);
    hub.dispatch("limitRecovery.snooze", json!({}));
    assert!(last_update(&hub).is_none());
    assert_eq!(
        banner(&hub)["error"],
        "The reset time has passed. Retry the thread manually."
    );
    // Continuing at the reset is still asked for.
    hub.dispatch("limitRecovery.resume", json!({}));
    assert_eq!(last_update(&hub).unwrap().1["autoResume"], true);
}
