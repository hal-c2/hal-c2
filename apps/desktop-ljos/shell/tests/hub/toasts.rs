//! `toasts`: what the Notifications brick shows, how long, and what its
//! buttons do (features/navigation/toasts.feature, desktop/native-toasts).

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::controllers::toasts::{Action, DEFAULT_TIMEOUT_MS, Run, Toasts};
use ljos::prelude::Engine;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;

type Log = Rc<RefCell<Vec<String>>>;

fn logging(log: &Log, entry: &str) -> impl Fn(&Engine) + 'static {
    let log = log.clone();
    let entry = entry.to_owned();
    move |_| log.borrow_mut().push(entry.clone())
}

fn show(hub: &Hub, kind: &str, title: &str, description: &str, timeout: i64) -> String {
    hub.with_controller::<Toasts, _>(|t, e| t.show(e, kind, title, description, None, timeout))
}

fn titles(hub: &Hub) -> Vec<String> {
    hub.published("toasts")["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["title"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn a_toast_shows_newest_first_with_its_actions_lesser_first() {
    let hub = Hub::new();
    assert_eq!(
        hub.published("toasts"),
        json!({"items": [], "expanded": false})
    );
    show(&hub, "info", "Older", "", DEFAULT_TIMEOUT_MS);
    let log = Log::default();
    hub.with_controller::<Toasts, _>(|t, e| {
        t.show_actions(
            e,
            "warning",
            "Newer",
            "Why",
            vec![
                Action::new("Retry", logging(&log, "retry")),
                Action::new("Remove project", logging(&log, "remove")),
                Action::new("Third", logging(&log, "third")),
            ],
            0,
        )
    });
    assert_eq!(
        hub.published("toasts"),
        json!({"expanded": false, "items": [
            {"id": "native:2", "type": "warning", "title": "Newer", "description": "Why", "updateKey": 0,
             "actions": [
                {"id": "secondary", "label": "Remove project", "primary": false},
                {"id": "primary", "label": "Retry", "primary": true},
             ]},
            {"id": "native:1", "type": "info", "title": "Older", "description": null, "updateKey": 0, "actions": []},
        ]})
    );
}

#[test]
fn a_failure_without_a_reason_still_says_something_went_wrong() {
    let hub = Hub::new();
    hub.with_controller::<Toasts, _>(|t, e| t.error(e, "Failed to settle thread", ""));
    let item = &hub.published("toasts")["items"][0];
    assert_eq!(item["type"], "error");
    assert_eq!(item["description"], "An error occurred.");
}

#[test]
fn a_toast_goes_away_on_its_own_after_five_seconds() {
    let hub = Hub::new();
    show(&hub, "error", "Failed", "No", DEFAULT_TIMEOUT_MS);
    show(&hub, "info", "Kept", "", 0);
    hub.advance(4999);
    assert_eq!(titles(&hub), ["Kept", "Failed"]);
    hub.advance(1);
    assert_eq!(titles(&hub), ["Kept"]);
    hub.advance(60_000);
    assert_eq!(titles(&hub), ["Kept"]);
}

#[test]
fn dismissing_a_toast_tells_who_follows_it_only_when_it_was_there() {
    let hub = Hub::new();
    let closed = Log::default();
    hub.with_controller::<Toasts, _>(|t, _| {
        let closed = closed.clone();
        t.on_closed_by_user(move |_, id| closed.borrow_mut().push(id.to_owned()));
    });
    let id = show(&hub, "error", "Failed", "No", DEFAULT_TIMEOUT_MS);
    hub.dispatch("notification.dismiss", json!({"id": id}));
    assert!(titles(&hub).is_empty());
    hub.dispatch("notification.dismiss", json!({"id": id}));
    assert_eq!(*closed.borrow(), [id]);
}

#[test]
fn an_action_dismisses_its_toast_and_may_show_another() {
    let hub = Hub::new();
    let engine_log = Log::default();
    let log = engine_log.clone();
    let retry = Action::new("Retry", move |engine: &Engine| {
        log.borrow_mut().push("retry".into());
        // Back into the controller that ran it.
        hal_c2_shell::controller::with::<Toasts, _>(engine, |t, e| {
            t.show(e, "loading", "Retrying", "", None, 0)
        })
        .expect("toasts are free when an action runs");
    });
    let cancel = Action::new("Cancel", logging(&engine_log, "cancel")).keeping_toast();
    let id = hub.with_controller::<Toasts, _>(|t, e| {
        t.show_actions(e, "error", "Clone failed", "", vec![retry, cancel], 0)
    });
    hub.dispatch(
        "notification.action",
        json!({"id": id, "actionId": "secondary"}),
    );
    assert_eq!(titles(&hub), ["Clone failed"]);
    hub.dispatch(
        "notification.action",
        json!({"id": id, "actionId": "primary"}),
    );
    assert_eq!(*engine_log.borrow(), ["cancel", "retry"]);
    assert_eq!(titles(&hub), ["Retrying"]);
    // An action the toast no longer offers is left be.
    hub.dispatch(
        "notification.action",
        json!({"id": "native:2", "actionId": "secondary"}),
    );
    assert_eq!(titles(&hub), ["Retrying"]);
}

#[test]
fn toasts_wait_while_the_user_looks_them_over() {
    let hub = Hub::new();
    show(&hub, "error", "Failed", "No", DEFAULT_TIMEOUT_MS);
    hub.advance(4000);
    hub.dispatch("notification.expand", json!({"expanded": true}));
    assert_eq!(hub.published("toasts")["expanded"], true);
    hub.advance(30_000);
    assert_eq!(titles(&hub), ["Failed"]);
    hub.dispatch("notification.expand", json!({"expanded": false}));
    hub.advance(999);
    assert_eq!(titles(&hub), ["Failed"]);
    hub.advance(1);
    assert!(titles(&hub).is_empty());
}

#[test]
fn an_empty_stack_does_not_expand_and_collapses_when_the_last_goes() {
    let hub = Hub::new();
    hub.dispatch("notification.expand", json!({"expanded": true}));
    assert_eq!(hub.published("toasts")["expanded"], false);
    let id = show(&hub, "info", "One", "", 0);
    hub.dispatch("notification.expand", json!({"expanded": true}));
    assert_eq!(hub.published("toasts")["expanded"], true);
    hub.dispatch("notification.dismiss", json!({"id": id}));
    assert_eq!(hub.published("toasts")["expanded"], false);
    assert!(!hub.with_controller::<Toasts, _>(|t, _| t.expanded()));
}

#[test]
fn a_toast_shown_while_expanded_starts_its_time_on_collapse() {
    let hub = Hub::new();
    show(&hub, "info", "First", "", 0);
    hub.dispatch("notification.expand", json!({"expanded": true}));
    show(&hub, "info", "Second", "", 1000);
    hub.advance(10_000);
    assert_eq!(titles(&hub), ["Second", "First"]);
    hub.dispatch("notification.expand", json!({"expanded": false}));
    hub.advance(1000);
    assert_eq!(titles(&hub), ["First"]);
}

#[test]
fn update_changes_the_text_in_place_and_replace_starts_the_time_afresh() {
    let hub = Hub::new();
    let id = show(&hub, "loading", "Cloning", "", DEFAULT_TIMEOUT_MS);
    assert!(hub.with_controller::<Toasts, _>(|t, e| t.update(e, &id, "Cloning", "")));
    assert_eq!(hub.published("toasts")["items"][0]["updateKey"], 0);
    assert!(hub.with_controller::<Toasts, _>(|t, e| t.update(e, &id, "Cloning", "Fetching")));
    assert_eq!(hub.published("toasts")["items"][0]["updateKey"], 1);
    hub.advance(4000);
    assert!(hub.with_controller::<Toasts, _>(|t, e| {
        t.replace(
            e,
            &id,
            "success",
            "Cloned",
            "",
            Vec::new(),
            DEFAULT_TIMEOUT_MS,
        )
    }));
    let item = hub.published("toasts")["items"][0].clone();
    assert_eq!(
        (item["type"].clone(), item["updateKey"].clone()),
        (json!("success"), json!(2))
    );
    hub.advance(4000);
    assert_eq!(titles(&hub), ["Cloned"]);
    hub.advance(1000);
    assert!(titles(&hub).is_empty());
    assert!(!hub.with_controller::<Toasts, _>(|t, e| t.update(e, &id, "x", "")));
}

fn undo(log: &Log, entry: &str) -> Run {
    Rc::new(logging(log, entry))
}

#[test]
fn undo_notices_of_one_group_join_and_undo_together() {
    let hub = Hub::new();
    let log = Log::default();
    let first = hub.with_controller::<Toasts, _>(|t, e| {
        t.show_undo(e, "Settled", "Settled First", undo(&log, "t1"))
    });
    let second = hub.with_controller::<Toasts, _>(|t, e| {
        t.show_undo(e, "Settled", "Settled Two", undo(&log, "t2"))
    });
    assert_eq!(first, second);
    assert_eq!(titles(&hub), ["Settled 2 threads"]);
    let third = hub.with_controller::<Toasts, _>(|t, e| {
        t.show_undo(e, "Settled", "Settled Three", undo(&log, "t3"))
    });
    assert_eq!(titles(&hub), ["Settled 3 threads"]);
    assert_eq!(third, first);
    hub.with_controller::<Toasts, _>(|t, e| {
        t.show_undo(e, "Snoozed", "Snoozed Four", undo(&log, "t4"))
    });
    assert_eq!(titles(&hub), ["Snoozed Four", "Settled 3 threads"]);
    assert!(hub.with_controller::<Toasts, _>(|t, e| t.run_action(e, "Undo")));
    assert_eq!(*log.borrow(), ["t4"]);
    assert!(hub.with_controller::<Toasts, _>(|t, e| t.run_action(e, "Undo")));
    assert_eq!(*log.borrow(), ["t4", "t3", "t2", "t1"]);
    assert!(!hub.with_controller::<Toasts, _>(|t, e| t.run_action(e, "Undo")));
}

#[test]
fn run_action_takes_the_newest_offering_it_and_the_same_group_straight_after() {
    let hub = Hub::new();
    let log = Log::default();
    let toast = |title: &str, actions: Vec<Action>| {
        hub.with_controller::<Toasts, _>(|t, e| {
            t.show_actions(e, "success", title, "", actions, 0)
        });
    };
    toast(
        "a",
        vec![Action::new("Undo", logging(&log, "a")).in_group("Archived")],
    );
    toast(
        "b",
        vec![Action::new("Undo", logging(&log, "b")).in_group("Settled")],
    );
    toast(
        "c",
        vec![
            Action::new("Open", logging(&log, "no")),
            Action::new("Undo", logging(&log, "c")).in_group("Settled"),
        ],
    );
    toast("d", vec![Action::new("Open", logging(&log, "no"))]);
    assert!(hub.with_controller::<Toasts, _>(|t, e| t.run_action(e, "Undo")));
    assert_eq!(*log.borrow(), ["c", "b"]);
    assert_eq!(titles(&hub), ["d", "a"]);
}

#[test]
fn run_action_with_no_group_runs_only_the_newest() {
    let hub = Hub::new();
    let log = Log::default();
    for name in ["x", "y"] {
        hub.with_controller::<Toasts, _>(|t, e| {
            t.show(
                e,
                "info",
                name,
                "",
                Some(Action::new("Retry", logging(&log, name))),
                0,
            )
        });
    }
    assert!(hub.with_controller::<Toasts, _>(|t, e| t.run_action(e, "Retry")));
    assert_eq!(*log.borrow(), ["y"]);
}

// The property: any sequence of shows, clicks, dismissals, expansions and
// time passing leaves the published stack as a plain model of it says, and
// runs each chosen action once, in order.

#[derive(Clone, Debug)]
struct ActionSpec {
    label: &'static str,
    group: &'static str,
    keeps: bool,
}

#[derive(Clone, Debug)]
enum Op {
    Show {
        timeout: i64,
        actions: Vec<ActionSpec>,
    },
    ShowUndo {
        group: &'static str,
    },
    Click {
        index: usize,
        secondary: bool,
    },
    Dismiss {
        index: usize,
    },
    Expand(bool),
    Advance(u64),
    RunAction(&'static str),
    Update {
        index: usize,
        same: bool,
    },
    Replace {
        index: usize,
        timeout: i64,
        actions: Vec<ActionSpec>,
    },
}

fn action_spec() -> impl Strategy<Value = ActionSpec> {
    (
        prop_oneof![Just("Undo"), Just("Retry")],
        prop_oneof![Just(""), Just("Settled"), Just("Snoozed")],
        any::<bool>(),
    )
        .prop_map(|(label, group, keeps)| ActionSpec {
            label,
            group,
            keeps,
        })
}

fn timeout() -> impl Strategy<Value = i64> {
    prop_oneof![Just(0), Just(1000), Just(DEFAULT_TIMEOUT_MS), Just(-1)]
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        4 => (timeout(), proptest::collection::vec(action_spec(), 0..4))
            .prop_map(|(timeout, actions)| Op::Show { timeout, actions }),
        2 => prop_oneof![Just(""), Just("Settled"), Just("Snoozed")].prop_map(|group| Op::ShowUndo { group }),
        3 => (0usize..6, any::<bool>()).prop_map(|(index, secondary)| Op::Click { index, secondary }),
        2 => (0usize..6).prop_map(|index| Op::Dismiss { index }),
        2 => any::<bool>().prop_map(Op::Expand),
        3 => prop_oneof![Just(1u64), Just(999), Just(1000), Just(2500), Just(5000), Just(7000)].prop_map(Op::Advance),
        2 => prop_oneof![Just("Undo"), Just("Retry")].prop_map(Op::RunAction),
        1 => (0usize..6, any::<bool>()).prop_map(|(index, same)| Op::Update { index, same }),
        1 => (0usize..6, timeout(), proptest::collection::vec(action_spec(), 0..3))
            .prop_map(|(index, timeout, actions)| Op::Replace { index, timeout, actions }),
    ]
}

#[derive(Clone, Debug)]
struct ModelAction {
    label: &'static str,
    group: String,
    keeps: bool,
    /// What clicking it logs, in order.
    runs: Vec<String>,
}

#[derive(Clone, Debug)]
struct ModelToast {
    id: String,
    kind: String,
    title: String,
    description: String,
    actions: Vec<ModelAction>,
    deadline: Option<u64>,
    remaining: u64,
    revision: u64,
    count: u32,
}

#[derive(Default)]
struct Model {
    toasts: Vec<ModelToast>,
    expanded: bool,
    now: u64,
    next_id: u64,
    log: Vec<String>,
}

impl Model {
    fn start_time(&self, toast: &mut ModelToast, timeout: i64) {
        toast.deadline = None;
        toast.remaining = 0;
        if timeout <= 0 {
            return;
        }
        if self.expanded {
            toast.remaining = timeout as u64;
        } else {
            toast.deadline = Some(self.now + timeout as u64);
        }
    }

    fn expire(&mut self) {
        let now = self.now;
        self.toasts.retain(|t| t.deadline.is_none_or(|d| d > now));
    }

    fn click(&mut self, id: &str, index: usize) {
        let Some(chosen) = self
            .toasts
            .iter()
            .find(|t| t.id == id)
            .and_then(|t| t.actions.get(index))
            .cloned()
        else {
            return;
        };
        if !chosen.keeps {
            self.toasts.retain(|t| t.id != id);
        }
        self.log.extend(chosen.runs);
    }

    fn settle(&mut self) {
        if self.toasts.is_empty() {
            self.expanded = false;
        }
    }

    fn published(&self) -> serde_json::Value {
        let items: Vec<_> = self
            .toasts
            .iter()
            .map(|t| {
                let actions: Vec<_> = t
                    .actions
                    .iter()
                    .take(2)
                    .enumerate()
                    .rev()
                    .map(|(i, a)| json!({"id": if i == 0 {"primary"} else {"secondary"}, "label": a.label, "primary": i == 0}))
                    .collect();
                json!({"id": t.id, "type": t.kind, "title": t.title,
                       "description": if t.description.is_empty() { serde_json::Value::Null } else { json!(t.description) },
                       "updateKey": t.revision, "actions": actions})
            })
            .collect();
        json!({"items": items, "expanded": self.expanded})
    }
}

struct World {
    hub: Hub,
    model: Model,
    log: Log,
    next_action: u64,
}

impl World {
    fn new() -> World {
        World {
            hub: Hub::new(),
            model: Model {
                next_id: 1,
                ..Model::default()
            },
            log: Log::default(),
            next_action: 0,
        }
    }

    fn actions(&mut self, specs: &[ActionSpec]) -> (Vec<Action>, Vec<ModelAction>) {
        specs
            .iter()
            .map(|spec| {
                self.next_action += 1;
                let name = format!("a{}", self.next_action);
                let mut action =
                    Action::new(spec.label, logging(&self.log, &name)).in_group(spec.group);
                action.keeps_toast = spec.keeps;
                let model = ModelAction {
                    label: spec.label,
                    group: spec.group.into(),
                    keeps: spec.keeps,
                    runs: vec![name],
                };
                (action, model)
            })
            .unzip()
    }

    fn id_at(&self, index: usize) -> String {
        self.model
            .toasts
            .get(index)
            .map_or_else(|| "native:0".into(), |t| t.id.clone())
    }

    fn step(&mut self, op: Op) {
        match op {
            Op::Show { timeout, actions } => {
                let (actions, model_actions) = self.actions(&actions);
                let id = self.hub.with_controller::<Toasts, _>(|t, e| {
                    t.show_actions(e, "info", "shown", "", actions, timeout)
                });
                let m = &mut self.model;
                let mut toast = ModelToast {
                    id: format!("native:{}", m.next_id),
                    kind: "info".into(),
                    title: "shown".into(),
                    description: String::new(),
                    actions: model_actions,
                    deadline: None,
                    remaining: 0,
                    revision: 0,
                    count: 1,
                };
                m.next_id += 1;
                assert_eq!(id, toast.id);
                m.start_time(&mut toast, timeout);
                m.toasts.insert(0, toast);
            }
            Op::ShowUndo { group } => {
                self.next_action += 1;
                let name = format!("u{}", self.next_action);
                let run: Run = Rc::new(logging(&self.log, &name));
                let title = format!("{group} one");
                let m = &mut self.model;
                self.hub
                    .with_controller::<Toasts, _>(|t, e| t.show_undo(e, group, &title, run));
                let joins = m
                    .toasts
                    .first()
                    .and_then(|t| t.actions.first())
                    .is_some_and(|a| a.label == "Undo" && a.group == group);
                if joins {
                    let mut newest = m.toasts.remove(0);
                    let count = newest.count + 1;
                    let mut runs = vec![name];
                    runs.extend(newest.actions[0].runs.clone());
                    newest.title = format!("{group} {count} threads");
                    newest.actions = vec![ModelAction {
                        label: "Undo",
                        group: group.into(),
                        keeps: false,
                        runs,
                    }];
                    m.start_time(&mut newest, DEFAULT_TIMEOUT_MS);
                    newest.revision += 1;
                    newest.count = count;
                    m.toasts.insert(0, newest);
                } else {
                    let mut toast = ModelToast {
                        id: format!("native:{}", m.next_id),
                        kind: "success".into(),
                        title,
                        description: String::new(),
                        actions: vec![ModelAction {
                            label: "Undo",
                            group: group.into(),
                            keeps: false,
                            runs: vec![name],
                        }],
                        deadline: None,
                        remaining: 0,
                        revision: 0,
                        count: 1,
                    };
                    m.next_id += 1;
                    m.start_time(&mut toast, DEFAULT_TIMEOUT_MS);
                    m.toasts.insert(0, toast);
                }
            }
            Op::Click { index, secondary } => {
                let id = self.id_at(index);
                let action_id = if secondary { "secondary" } else { "primary" };
                self.hub.dispatch(
                    "notification.action",
                    json!({"id": id, "actionId": action_id}),
                );
                self.model.click(&id, usize::from(secondary));
            }
            Op::Dismiss { index } => {
                let id = self.id_at(index);
                self.hub.dispatch("notification.dismiss", json!({"id": id}));
                self.model.toasts.retain(|t| t.id != id);
            }
            Op::Expand(expanded) => {
                self.hub
                    .dispatch("notification.expand", json!({"expanded": expanded}));
                let m = &mut self.model;
                if expanded != m.expanded
                    && !(expanded && {
                        m.expire();
                        m.toasts.is_empty()
                    })
                {
                    m.expanded = expanded;
                    let now = m.now;
                    for t in &mut m.toasts {
                        if expanded && let Some(d) = t.deadline.take() {
                            t.remaining = d - now;
                        } else if !expanded && t.remaining > 0 {
                            t.deadline = Some(now + t.remaining);
                            t.remaining = 0;
                        }
                    }
                }
            }
            Op::Advance(ms) => {
                self.hub.advance(ms);
                let m = &mut self.model;
                m.now += ms;
                m.expire();
            }
            Op::RunAction(label) => {
                let ran = self
                    .hub
                    .with_controller::<Toasts, _>(|t, e| t.run_action(e, label));
                let m = &self.model;
                let mut chosen: Vec<(String, usize)> = Vec::new();
                let mut group = String::new();
                for t in &m.toasts {
                    let Some(found) = t.actions.iter().take(2).position(|a| a.label == label)
                    else {
                        if chosen.is_empty() {
                            continue;
                        }
                        break;
                    };
                    let its = &t.actions[found].group;
                    if !chosen.is_empty() && (group.is_empty() || *its != group) {
                        break;
                    }
                    group = its.clone();
                    chosen.push((t.id.clone(), found));
                }
                assert_eq!(ran, !chosen.is_empty());
                for (id, index) in chosen {
                    self.model.click(&id, index);
                }
            }
            Op::Update { index, same } => {
                let id = self.id_at(index);
                let title = if same {
                    self.model
                        .toasts
                        .get(index)
                        .map_or("x".into(), |t| t.title.clone())
                } else {
                    format!("updated {}", self.next_action)
                };
                self.next_action += 1;
                let found = self
                    .hub
                    .with_controller::<Toasts, _>(|t, e| t.update(e, &id, &title, ""));
                let m = &mut self.model;
                let toast = m.toasts.iter_mut().find(|t| t.id == id);
                assert_eq!(found, toast.is_some());
                if let Some(t) = toast
                    && !(t.title == title && t.description.is_empty())
                {
                    t.title = title;
                    t.description.clear();
                    t.revision += 1;
                }
            }
            Op::Replace {
                index,
                timeout,
                actions,
            } => {
                let id = self.id_at(index);
                let (actions, model_actions) = self.actions(&actions);
                let found = self.hub.with_controller::<Toasts, _>(|t, e| {
                    t.replace(e, &id, "success", "replaced", "", actions, timeout)
                });
                let m = &mut self.model;
                let pos = m.toasts.iter().position(|t| t.id == id);
                assert_eq!(found, pos.is_some());
                if let Some(pos) = pos {
                    let mut t = m.toasts[pos].clone();
                    t.kind = "success".into();
                    t.title = "replaced".into();
                    t.description.clear();
                    t.actions = model_actions;
                    t.count = 1;
                    m.start_time(&mut t, timeout);
                    t.revision += 1;
                    m.toasts[pos] = t;
                }
            }
        }
        self.model.settle();
    }

    fn check(&self) {
        let mut published = self.hub.published("toasts");
        // The undo hint is the keymap's to say.
        for item in published["items"].as_array_mut().unwrap() {
            item["description"] = serde_json::Value::Null;
        }
        let mut expected = self.model.published();
        for item in expected["items"].as_array_mut().unwrap() {
            item["description"] = serde_json::Value::Null;
        }
        assert_eq!(published, expected);
        assert_eq!(*self.log.borrow(), self.model.log);
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 256, ..ProptestConfig::default() })]

    #[test]
    fn toasts_follow_their_model(ops in proptest::collection::vec(op(), 1..60)) {
        let mut world = World::new();
        for op in ops {
            world.step(op);
            world.check();
        }
    }
}
