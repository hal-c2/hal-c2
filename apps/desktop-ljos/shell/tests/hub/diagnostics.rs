//! Settings → Diagnostics (`diagnostics`).

use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::page::{answer, count, failure, hub_with, last, open, toasts};

const SECTION: &str = "/settings/diagnostics";
const PROCESSES: &str = "server.getProcessDiagnostics";
const HISTORY: &str = "server.getProcessResourceHistory";
const TRACES: &str = "server.getTraceDiagnostics";

fn state(hub: &Hub) -> serde_json::Value {
    hub.published("diagnostics")
}

fn listing() -> serde_json::Value {
    json!({
        "serverPid": 10, "processCount": 2, "totalCpuPercent": 12.5, "totalRssBytes": 2048,
        "processes": [
            {"pid": 10, "ppid": 1, "depth": 0, "command": "/usr/bin/hal-c2-mc", "cpuPercent": 1.0, "rssBytes": 1024, "startTimeMs": 100},
            {"pid": 11, "ppid": 10, "depth": 1, "command": "node", "cpuPercent": 2.0, "rssBytes": 1024, "startTimeMs": 200}
        ]
    })
}

fn opened() -> Hub {
    let hub = hub_with(json!({"settings": {}}));
    open(&hub, SECTION);
    hub
}

#[test]
fn opening_reads_all_three_and_shows_dots_until_they_land() {
    let hub = opened();
    for m in [PROCESSES, HISTORY, TRACES] {
        assert_eq!(count(&hub, m), 1, "{m}");
    }
    assert_eq!(state(&hub)["processes"]["loading"], true);
    assert_eq!(state(&hub)["processes"]["count"], "...");
    answer(&hub, "env-1", PROCESSES, Ok(listing()));
    let processes = state(&hub)["processes"].clone();
    assert_eq!(processes["loading"], false);
    assert_eq!(processes["serverPid"], "10");
    assert_eq!(processes["rows"].as_array().unwrap().len(), 2);
    assert!(!processes["groups"].as_array().unwrap().is_empty());
}

#[test]
fn only_the_latest_read_lands() {
    let hub = opened();
    hub.dispatch("diagnostics.refresh", json!({}));
    // The first answer (older) comes after the second's request was sent:
    // the oldest pending is generation 1, which no longer counts.
    answer(
        &hub,
        "env-1",
        PROCESSES,
        Ok(json!({"serverPid": 1, "processes": []})),
    );
    assert_eq!(state(&hub)["processes"]["loading"], true);
    answer(&hub, "env-1", PROCESSES, Ok(listing()));
    assert_eq!(state(&hub)["processes"]["serverPid"], "10");
}

#[test]
fn a_window_rereads_only_the_history_with_its_bucket() {
    let hub = opened();
    hub.dispatch("diagnostics.window", json!({"windowMs": 12345}));
    assert_eq!(count(&hub, HISTORY), 1);
    hub.dispatch("diagnostics.window", json!({"windowMs": 300_000}));
    assert_eq!(count(&hub, HISTORY), 2);
    assert_eq!(
        last(&hub, "env-1", HISTORY),
        json!({"windowMs": 300_000, "bucketMs": 30_000})
    );
    assert_eq!(count(&hub, PROCESSES), 1);
}

#[test]
fn a_failed_read_shows_why_and_a_group_folds() {
    let hub = opened();
    answer(&hub, "env-1", TRACES, Err(failure("no traces")));
    assert_eq!(state(&hub)["traces"]["error"], "no traces");
    answer(&hub, "env-1", PROCESSES, Ok(listing()));
    let id = state(&hub)["processes"]["groups"][0]["id"].clone();
    assert_eq!(state(&hub)["processes"]["groups"][0]["collapsed"], false);
    hub.dispatch("diagnostics.group", json!({"id": id}));
    assert_eq!(state(&hub)["processes"]["groups"][0]["collapsed"], true);
    hub.dispatch("diagnostics.group", json!({"id": id}));
    assert_eq!(state(&hub)["processes"]["groups"][0]["collapsed"], false);
}

#[test]
fn interrupting_a_listed_process_signals_it_once_and_reads_again() {
    let hub = opened();
    answer(&hub, "env-1", PROCESSES, Ok(listing()));
    // Not listed: nothing is sent.
    hub.dispatch("diagnostics.signal", json!({"pid": 99, "signal": "SIGINT"}));
    hub.dispatch(
        "diagnostics.signal",
        json!({"pid": 11, "signal": "SIGTERM"}),
    );
    assert_eq!(count(&hub, "server.signalProcess"), 0);

    hub.dispatch("diagnostics.signal", json!({"pid": 11, "signal": "SIGINT"}));
    assert_eq!(
        last(&hub, "env-1", "server.signalProcess"),
        json!({"pid": 11, "startTimeMs": 200, "signal": "SIGINT"})
    );
    // One at a time.
    hub.dispatch("diagnostics.signal", json!({"pid": 10, "signal": "SIGINT"}));
    assert_eq!(count(&hub, "server.signalProcess"), 1);
    answer(
        &hub,
        "env-1",
        "server.signalProcess",
        Ok(json!({"signaled": true})),
    );
    assert_eq!(count(&hub, PROCESSES), 2);
}

#[test]
fn killing_asks_first_and_a_refusal_is_a_toast() {
    let hub = opened();
    answer(&hub, "env-1", PROCESSES, Ok(listing()));
    hub.dispatch(
        "diagnostics.signal",
        json!({"pid": 11, "signal": "SIGKILL"}),
    );
    assert_eq!(count(&hub, "server.signalProcess"), 0);
    let request = hub.published("confirmation")["requestId"].clone();
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": request, "accepted": true}),
    );
    assert_eq!(count(&hub, "server.signalProcess"), 1);
    answer(
        &hub,
        "env-1",
        "server.signalProcess",
        Ok(
            json!({"signaled": false, "message": {"_tag": "Some", "value": "That process has already exited."}}),
        ),
    );
    assert!(
        toasts(&hub)
            .iter()
            .any(|(t, _)| t == "Process already exited")
    );
}

#[derive(Clone, Debug)]
enum Step {
    Refresh,
    Window(bool),
    Answer(usize, bool),
}

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        Just(Step::Refresh),
        any::<bool>().prop_map(Step::Window),
        (0usize..40, any::<bool>()).prop_map(|(i, ok)| Step::Answer(i, ok)),
    ]
}

proptest! {
    /// Reads are answered in any order: a slot is loading exactly while its
    /// latest read is unanswered.
    #[test]
    fn loading_means_the_latest_read_is_unanswered(steps in proptest::collection::vec(step(), 1..24)) {
        let hub = opened();
        for step in steps {
            match step {
                Step::Refresh => hub.dispatch("diagnostics.refresh", json!({})),
                Step::Window(wide) => hub.dispatch(
                    "diagnostics.window",
                    json!({"windowMs": if wide { 3_600_000 } else { 300_000 }}),
                ),
                Step::Answer(i, ok) => {
                    let asked = hub.mc.calls.borrow().len();
                    let result = if ok { Ok(listing()) } else { Err(failure("no")) };
                    hub.mc.reply(&hub.engine, i % asked, result);
                }
            }
            for (slot, method) in [("processes", PROCESSES), ("history", HISTORY), ("traces", TRACES)] {
                let calls = hub.mc.calls.borrow();
                let latest = calls.iter().rposition(|(_, m, _)| m == method).unwrap();
                drop(calls);
                // The latest call of this slot is unanswered iff loading.
                let unanswered = hub.mc.is_pending(latest);
                prop_assert_eq!(state(&hub)[slot]["loading"] == true, unanswered, "{}", slot);
            }
        }
    }
}
