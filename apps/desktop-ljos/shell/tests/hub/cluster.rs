//! Settings → Cluster (`cluster`).

use std::cell::RefCell;
use std::collections::BTreeMap;
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
    Bridge::of(&hub.engine).set_clipboard_writer(&hub.engine, move |t| {
        sink.borrow_mut().push(t.to_owned());
        true
    });
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

/// This machine runs 2.0 and is clustered with `studio`, connected on 1.3.
fn behind() -> serde_json::Value {
    json!({"clustered": true, "version": "2.0", "members": [
        {"id": "id-studio", "label": "studio", "version": "1.3", "connected": true}]})
}

#[test]
fn sending_this_machines_version_says_how_each_member_took_it_and_reads_again() {
    let hub = opened();
    answer(&hub, "env-1", "cluster.status", Ok(behind()));
    hub.dispatch("cluster.update", json!({}));
    assert_eq!(state(&hub)["busy"], true);
    assert_eq!(
        crate::page::last(&hub, "env-1", "cluster.update"),
        json!({})
    );
    answer(
        &hub,
        "env-1",
        "cluster.update",
        Ok(json!({"version": "2.0", "members": [
            {"id": "id-studio", "label": "studio", "from": "1.3", "outcome": "updated"}]})),
    );
    assert_eq!(state(&hub)["busy"], false);
    assert_eq!(
        state(&hub)["notice"],
        json!({"kind": "success", "text": "studio updated to 2.0."})
    );
    // The cluster is read again for the versions members now run.
    assert_eq!(count(&hub, "cluster.status"), 2);
}

#[test]
fn a_member_that_cannot_take_the_version_says_why() {
    let hub = opened();
    answer(&hub, "env-1", "cluster.status", Ok(behind()));
    hub.dispatch("cluster.update", json!({}));
    answer(
        &hub,
        "env-1",
        "cluster.update",
        Ok(json!({"version": "2.0", "members": [
            {"label": "studio", "outcome": "This MC cannot update itself."},
            {"label": "box", "outcome": "restarting on it"},
            {"label": "den", "outcome": "has not finished"},
            {"label": "hub", "outcome": "updated"}]})),
    );
    assert_eq!(
        state(&hub)["notice"],
        json!({"kind": "error", "text": "studio could not update: This MC cannot update itself. \
            box is restarting on 2.0. den is still updating. hub updated to 2.0."})
    );
}

#[test]
fn nobody_to_update_and_a_refused_update_are_told() {
    let hub = opened();
    answer(&hub, "env-1", "cluster.status", Ok(members(&["a"])));
    hub.dispatch("cluster.update", json!({}));
    answer(
        &hub,
        "env-1",
        "cluster.update",
        Ok(json!({"version": "2.0", "members": []})),
    );
    assert_eq!(
        state(&hub)["notice"],
        json!({"kind": "success", "text": "No connected machine needs an update to 2.0."})
    );
    hub.dispatch("cluster.update", json!({}));
    answer(
        &hub,
        "env-1",
        "cluster.update",
        Err(failure("access denied")),
    );
    assert_eq!(state(&hub)["busy"], false);
    assert_eq!(
        state(&hub)["notice"],
        json!({"kind": "error", "text": "Update failed: access denied"})
    );
    assert_eq!(count(&hub, "cluster.status"), 3);
}

/// The machines the MC's cluster has, by label: connected, and the version.
type Machines = BTreeMap<&'static str, (bool, &'static str)>;

const MACHINES: [&str; 2] = ["laptop", "studio"];
const VERSIONS: [&str; 2] = ["1.0", "2.0"];
/// The machine that cannot take a version from another one.
const STUCK: &str = "laptop";
const REFUSAL: &str = "This MC cannot update itself.";

fn together() -> Machines {
    MACHINES.iter().map(|m| (*m, (true, "1.0"))).collect()
}

/// What the update the MC answers did to the machines, as the page says it:
/// the notice's kind and text.
fn updated(machines: &mut Machines) -> (&'static str, String) {
    let mut lines = Vec::new();
    let mut failed = false;
    for (label, (connected, version)) in machines.iter_mut() {
        if !*connected || *version == "2.0" {
            continue;
        }
        if *label == STUCK {
            failed = true;
            lines.push(format!("{label} could not update: {REFUSAL}"));
        } else {
            lines.push(format!("{label} updated to 2.0."));
            *version = "2.0";
        }
    }
    if lines.is_empty() {
        lines.push("No connected machine needs an update to 2.0.".to_owned());
    }
    (if failed { "error" } else { "success" }, lines.join(" "))
}

/// A call the MC holds: the `asked`th request, a read of the cluster or the
/// update.
#[derive(Clone, Debug)]
struct Held {
    update: bool,
    asked: u32,
}

/// The page as the interleaving of reads, sendings and answers must leave it.
#[derive(Clone, Debug)]
struct Model {
    mc: Machines,
    open: bool,
    shown: Machines,
    notice: Option<(&'static str, String)>,
    busy: bool,
    /// Every read and update is a request; only the latest read's answer counts.
    asked: u32,
    held: Vec<Held>,
}

impl Model {
    fn read(&mut self) {
        self.asked += 1;
        self.held.push(Held {
            update: false,
            asked: self.asked,
        });
    }

    fn answer(&mut self, at: usize) {
        let call = self.held.remove(at);
        if !call.update {
            if call.asked == self.asked {
                self.shown = self.mc.clone();
            }
            return;
        }
        self.busy = false;
        self.notice = Some(updated(&mut self.mc));
        self.read();
    }
}

#[derive(Clone, Debug)]
enum Move {
    Open(bool),
    Refresh,
    Update,
    /// A machine connects, drops or moves to a version on its own.
    Elsewhere(usize, bool, usize),
    /// The MC answers the held call at this position (modulo how many).
    Answer(usize),
}

fn moves() -> impl Strategy<Value = Move> {
    prop_oneof![
        2 => any::<bool>().prop_map(Move::Open),
        2 => Just(Move::Refresh),
        3 => Just(Move::Update),
        2 => (0..MACHINES.len(), any::<bool>(), 0..VERSIONS.len())
            .prop_map(|(m, c, v)| Move::Elsewhere(m, c, v)),
        5 => (0..8usize).prop_map(Move::Answer),
    ]
}

/// The cluster as the MC answers a read now.
fn status_of(mc: &Machines) -> serde_json::Value {
    json!({"clustered": true, "version": "2.0", "members": mc.iter()
        .map(|(label, (connected, version))| json!({"id": format!("id-{label}"), "label": label,
            "version": version, "connected": connected}))
        .collect::<Vec<_>>()})
}

/// What the page shows of the cluster.
fn shown_machines(hub: &Hub) -> BTreeMap<String, (bool, String)> {
    state(hub)["status"]["members"]
        .as_array()
        .map(|members| {
            members
                .iter()
                .map(|m| {
                    (
                        m["label"].as_str().unwrap().to_owned(),
                        (
                            m["connected"].as_bool().unwrap(),
                            m["version"].as_str().unwrap().to_owned(),
                        ),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The calls the MC holds, oldest first: their indexes in the hub's calls.
fn held_calls(hub: &Hub) -> Vec<usize> {
    let calls = hub.mc.calls.borrow();
    (0..calls.len())
        .filter(|&i| calls[i].1.starts_with("cluster.") && hub.mc.is_pending(i))
        .collect()
}

proptest! {
    /// The page shows the cluster as the latest read found it, says what the
    /// last sending did, and is busy exactly while one is out, however reads,
    /// sendings and the MC's answers interleave.
    #[test]
    fn the_page_is_what_reads_and_the_version_sent_leave_it(
        steps in proptest::collection::vec(moves(), 1..40),
    ) {
        let hub = opened();
        let mc = together();
        answer(&hub, "env-1", "cluster.status", Ok(status_of(&mc)));
        let mut model = Model {
            mc: mc.clone(),
            open: true,
            shown: mc.clone(),
            notice: None,
            busy: false,
            asked: 1,
            held: Vec::new(),
        };
        for step in steps {
            match step {
                Move::Open(open) => {
                    if model.open != open {
                        model.open = open;
                        if open {
                            model.notice = None;
                            model.read();
                        }
                        if open {
                            hub.dispatch("cluster.open", json!({}));
                        } else {
                            hub.dispatch("settings.navigate", json!({"to": "/settings/general"}));
                        }
                    }
                }
                Move::Refresh => {
                    model.read();
                    hub.dispatch("cluster.refresh", json!({}));
                }
                Move::Update => {
                    if model.open && !model.busy {
                        model.busy = true;
                        model.asked += 1;
                        model.held.push(Held { update: true, asked: model.asked });
                        hub.dispatch("cluster.update", json!({}));
                    }
                }
                Move::Elsewhere(machine, connected, version) => {
                    model.mc.insert(MACHINES[machine], (connected, VERSIONS[version]));
                }
                Move::Answer(at) => {
                    if !model.held.is_empty() {
                        let at = at % model.held.len();
                        let index = held_calls(&hub)[at];
                        // The MC answers with the cluster as it is when it answers.
                        let result = if model.held[at].update {
                            let members: Vec<_> = model
                                .mc
                                .iter()
                                .filter(|(_, (c, v))| *c && *v != "2.0")
                                .map(|(label, _)| json!({"id": format!("id-{label}"), "label": label,
                                    "outcome": if *label == STUCK { REFUSAL } else { "updated" }}))
                                .collect();
                            json!({"version": "2.0", "members": members})
                        } else {
                            status_of(&model.mc)
                        };
                        model.answer(at);
                        prop_assert!(hub.mc.reply(&hub.engine, index, Ok(result)));
                    }
                }
            }
            let page = state(&hub);
            prop_assert_eq!(
                shown_machines(&hub),
                model.shown.iter().map(|(l, (c, v))| ((*l).to_owned(), (*c, (*v).to_owned()))).collect::<BTreeMap<_, _>>()
            );
            let notice = model.notice.as_ref().map(|(kind, text)| json!({"kind": kind, "text": text}));
            prop_assert_eq!(page["notice"].clone(), notice.unwrap_or(serde_json::Value::Null));
            prop_assert_eq!(page["busy"] == true, model.busy);
            prop_assert_eq!(held_calls(&hub).len(), model.held.len());
        }
    }
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
