//! Settings → Cluster (`cluster`).

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller;
use hal_c2_shell::controllers::cluster::Cluster;
use hal_c2_shell::controllers::drafts;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::page::{answer, count, failure, hub_with};

fn state(hub: &Hub) -> serde_json::Value {
    hub.published("cluster")
}

fn members(labels: &[&str]) -> serde_json::Value {
    json!({"members": labels.iter().map(|l| json!({"id": format!("id-{l}"), "label": l})).collect::<Vec<_>>()})
}

fn opened() -> Hub {
    let hub = hub_with(json!({"settings": {}}));
    hub.dispatch("cluster.open", json!({}));
    hub
}

#[test]
fn opening_reads_the_status_and_shows_it() {
    let hub = opened();
    assert_eq!(count(&hub, "cluster.status"), 1);
    answer(&hub, "env-1", "cluster.status", Ok(members(&["box"])));
    assert_eq!(state(&hub)["status"], members(&["box"]));
    assert_eq!(state(&hub)["needsAdmin"], false);
}

#[test]
fn a_missing_scope_is_not_an_error_but_a_prompt() {
    let hub = opened();
    answer(
        &hub,
        "env-1",
        "cluster.status",
        Err(failure("access:cluster is required")),
    );
    let shown = state(&hub);
    assert_eq!(shown["needsAdmin"], true);
    assert_eq!(shown["error"], serde_json::Value::Null);
    assert_eq!(shown["status"], serde_json::Value::Null);

    hub.dispatch("cluster.refresh", json!({}));
    answer(&hub, "env-1", "cluster.status", Err(failure("unreachable")));
    assert_eq!(state(&hub)["needsAdmin"], false);
    assert_eq!(state(&hub)["error"], "unreachable");
}

#[test]
fn a_change_overtakes_a_read_sent_before_it() {
    let hub = opened();
    answer(&hub, "env-1", "cluster.status", Ok(members(&["a", "b"])));
    hub.dispatch("cluster.refresh", json!({}));
    hub.dispatch("cluster.remove", json!({"id": "id-b"}));
    assert_eq!(state(&hub)["busy"], true);
    // The change answers first; the older read then lands stale.
    answer(&hub, "env-1", "cluster.remove", Ok(members(&["a"])));
    answer(&hub, "env-1", "cluster.status", Ok(members(&["a", "b"])));
    assert_eq!(state(&hub)["status"], members(&["a"]));
    assert_eq!(state(&hub)["busy"], false);
    assert_eq!(
        state(&hub)["notice"],
        json!({"kind": "success", "text": "Removed b from the cluster."})
    );
}

#[test]
fn a_failed_change_says_so_and_reads_again() {
    let hub = opened();
    answer(&hub, "env-1", "cluster.status", Ok(members(&["a"])));
    hub.dispatch("cluster.join", json!({"link": " "}));
    assert_eq!(count(&hub, "cluster.join"), 0);
    assert_eq!(state(&hub)["notice"]["kind"], "error");
    hub.dispatch("cluster.join", json!({"link": " hal://x "}));
    assert_eq!(
        crate::page::last(&hub, "env-1", "cluster.join"),
        json!({"link": "hal://x"})
    );
    answer(&hub, "env-1", "cluster.join", Err(failure("bad link")));
    assert_eq!(state(&hub)["notice"]["text"], "Join failed: bad link");
    assert_eq!(count(&hub, "cluster.status"), 2);
}

#[test]
fn an_invite_is_copied_and_a_loopback_one_is_flagged() {
    let hub = opened();
    let copied = Rc::new(RefCell::new(Vec::<String>::new()));
    let sink = copied.clone();
    Bridge::of(&hub.engine)
        .set_clipboard_writer(&hub.engine, move |t| sink.borrow_mut().push(t.to_owned()));
    hub.dispatch("cluster.invite", json!({"tailscale": true}));
    assert_eq!(
        crate::page::last(&hub, "env-1", "cluster.invite"),
        json!({"tailscale": true})
    );
    answer(
        &hub,
        "env-1",
        "cluster.invite",
        Ok(json!({"link": "hal://l", "localOnly": true})),
    );
    assert_eq!(*copied.borrow(), ["hal://l"]);
    let notice = state(&hub)["notice"].clone();
    assert_eq!(notice["kind"], "error");
    assert!(notice["text"].as_str().unwrap().contains("Tailscale"));
    hub.dispatch("cluster.invite.copy", json!({}));
    assert_eq!(copied.borrow().len(), 2);
}

#[test]
fn a_removed_machine_is_announced_to_whoever_keeps_its_drafts() {
    let hub = opened();
    let removed = Rc::new(RefCell::new(Vec::<String>::new()));
    let sink = removed.clone();
    controller::with::<Cluster, _>(&hub.engine, |c, _| {
        c.on_removed(move |_, id| sink.borrow_mut().push(id.to_owned()));
    })
    .unwrap();
    hub.dispatch("cluster.remove", json!({"id": "id-b"}));
    answer(&hub, "env-1", "cluster.remove", Ok(members(&[])));
    assert_eq!(*removed.borrow(), ["id-b"]);
}

#[test]
fn a_removed_machines_drafts_go_with_it_once_the_mc_agrees() {
    let hub = opened();
    let kept = drafts::start(&hub.engine, "env-1", "p1").unwrap();
    drafts::start(&hub.engine, "id-b", "p1").unwrap();
    drafts::start(&hub.engine, "id-b", "p2").unwrap();
    let environments = || {
        let all = drafts::all(&hub.engine).into_iter();
        all.map(|d| d.environment_id).collect::<Vec<_>>()
    };
    hub.dispatch("cluster.remove", json!({"id": "id-b"}));
    answer(&hub, "env-1", "cluster.remove", Err(failure("no")));
    assert_eq!(environments(), ["env-1", "id-b", "id-b"]);
    hub.dispatch("cluster.remove", json!({"id": "id-b"}));
    answer(&hub, "env-1", "cluster.remove", Ok(members(&[])));
    assert_eq!(environments(), ["env-1"]);
    assert!(drafts::draft(&hub.engine, &kept).is_some());
}

#[derive(Clone, Debug)]
enum Step {
    Refresh,
    Remove,
    Join,
    AnswerOldest(bool),
    AnswerNewest(bool),
}

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        Just(Step::Refresh),
        Just(Step::Remove),
        Just(Step::Join),
        any::<bool>().prop_map(Step::AnswerOldest),
        any::<bool>().prop_map(Step::AnswerNewest),
    ]
}

proptest! {
    /// Answers come in any order; the page is busy only while a join or
    /// remove is unanswered.
    #[test]
    fn busy_means_a_change_is_unanswered(steps in proptest::collection::vec(step(), 1..20)) {
        let hub = opened();
        let mut serial = 0u32;
        for step in steps {
            match step {
                Step::Refresh => hub.dispatch("cluster.refresh", json!({})),
                Step::Remove => hub.dispatch("cluster.remove", json!({"id": "id-x"})),
                Step::Join => hub.dispatch("cluster.join", json!({"link": "hal://x"})),
                Step::AnswerOldest(ok) | Step::AnswerNewest(ok) => {
                    let newest = matches!(step, Step::AnswerNewest(_));
                    let asked = hub.mc.calls.borrow().len();
                    let order: Vec<usize> = if newest { (0..asked).rev().collect() } else { (0..asked).collect() };
                    for i in order {
                        serial += 1;
                        let result = if ok { Ok(members(&[&format!("m{serial}")])) } else { Err(failure("no")) };
                        if hub.mc.reply(&hub.engine, i, result) {
                            break;
                        }
                    }
                }
            }
            let busy = state(&hub)["busy"] == true;
            let change_in_flight = ["cluster.remove", "cluster.join"]
                .iter()
                .any(|m| hub.mc.pending_on("env-1", m).is_some());
            prop_assert!(!busy || change_in_flight);
        }
    }
}
