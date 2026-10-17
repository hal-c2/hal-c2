//! `worktreeSetup`: how the open thread's new worktree is being prepared
//! (WorktreeSetupController.cpp, features/threads/worktree-setup.feature).

use hal_c2_shell::json::Json;
use serde_json::json;

use crate::Hub;
use crate::page::{failure, last, toasts};
use crate::workspace::{on_thread, project, shell, thread};

fn followed(hub: &Hub) -> Vec<Json> {
    hub.mc
        .subscriptions()
        .into_iter()
        .map(|(_, shape)| shape)
        .filter(|shape| shape["type"] == "worktreeSetup")
        .collect()
}

fn setup(hub: &Hub, event: Json) {
    hub.mc.frame(
        &hub.engine,
        "worktreeSetup",
        "",
        json!({"t": "worktreeSetup", "event": event}),
    );
}

fn running() -> Json {
    json!({"threadId": "t1", "phase": "running", "branch": "hal/feature", "baseRef": "main",
    "worktreePath": "/w/p-feature", "setupScript": {"name": "Install"},
    "stages": [
        {"id": "fetch", "status": "done", "detail": "origin/main"},
        {"id": "checkout", "status": "running", "tail": ["Updating files: 50%", 3]},
        {"id": "setup-script", "status": "pending"},
        {"id": "agent", "status": "pending"},
    ]})
}

fn state(hub: &Hub) -> Json {
    hub.published("worktreeSetup")
}

#[test]
fn the_thread_follows_its_setup_on_the_member_serving_it() {
    let hub = on_thread("main", None);
    assert_eq!(
        followed(&hub),
        [json!({"type": "worktreeSetup", "mc": "a", "threadId": "t1"})]
    );
    assert_eq!(state(&hub), Json::Null);

    setup(&hub, running());
    assert_eq!(
        state(&hub),
        json!({"threadKey": "env-1:t1", "phase": "running", "label": "Setting up worktree…",
        "error": "", "branch": "hal/feature", "baseRef": "main", "worktreePath": "/w/p-feature",
        "script": "Install", "canCancel": true, "detailsOpen": false,
        "stages": [
            {"id": "fetch", "label": "Fetch base branch", "status": "done", "detail": "origin/main", "tail": []},
            {"id": "checkout", "label": "Check out files", "status": "running", "detail": "",
             "tail": ["Updating files: 50%", "3"]},
            {"id": "setup-script", "label": "Run setup script", "status": "pending", "detail": "", "tail": []},
            {"id": "agent", "label": "Start agent", "status": "pending", "detail": "", "tail": []},
        ]})
    );

    // No setup tracked any more.
    setup(&hub, json!(null));
    assert_eq!(state(&hub), Json::Null);
}

#[test]
fn the_headline_says_how_the_setup_ended() {
    let hub = on_thread("main", None);
    let ended = |phase: &str, stage: &str| {
        let mut event = running();
        event["phase"] = phase.into();
        event["stages"] = json!([{"id": "setup-script", "status": stage}]);
        event
    };
    for (phase, stage, label) in [
        ("done", "done", "Worktree ready"),
        ("done", "failed", "Worktree ready, setup script failed"),
        ("failed", "failed", "Worktree setup failed"),
        ("cancelled", "pending", "Worktree setup cancelled"),
    ] {
        setup(&hub, ended(phase, stage));
        assert_eq!(state(&hub)["label"], label, "{phase} {stage}");
        assert_eq!(state(&hub)["canCancel"], false);
    }
    let mut failed = ended("failed", "failed");
    failed["error"] = "git fetch failed".into();
    setup(&hub, failed);
    assert_eq!(state(&hub)["error"], "git fetch failed");
}

#[test]
fn the_details_open_and_close_and_start_closed_on_another_thread() {
    let hub = Hub::clustered();
    shell(
        &hub,
        vec![
            project(json!({})),
            thread("t1", "main", None),
            thread("t2", "main", None),
        ],
    );
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    setup(&hub, running());
    hub.dispatch("worktreeSetup.details", json!({"open": true}));
    assert_eq!(state(&hub)["detailsOpen"], true);
    hub.dispatch("worktreeSetup.details", json!({"open": false}));
    assert_eq!(state(&hub)["detailsOpen"], false);
    hub.dispatch("worktreeSetup.details", json!({"open": true}));

    hub.dispatch("thread.open", json!({"key": "env-1:t2"}));
    assert_eq!(state(&hub), Json::Null);
    assert_eq!(
        followed(&hub),
        [json!({"type": "worktreeSetup", "mc": "a", "threadId": "t2"})]
    );
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    assert_eq!(state(&hub), Json::Null);
    setup(&hub, running());
    assert_eq!(state(&hub)["detailsOpen"], false);

    // Off a thread nothing is followed.
    hub.dispatch("usage.open", json!({}));
    assert!(followed(&hub).is_empty());
    assert_eq!(state(&hub), Json::Null);
}

#[test]
fn cancelling_asks_the_mc_and_says_when_it_cannot() {
    let hub = on_thread("main", None);
    setup(&hub, running());
    hub.dispatch("worktreeSetup.cancel", json!({}));
    assert_eq!(
        last(&hub, "env-1", "worktreeSetup.cancel"),
        json!({"threadId": "t1"})
    );
    hub.mc.answer(
        &hub.engine,
        "worktreeSetup.cancel",
        Ok(json!({"cancelled": true})),
    );
    assert!(toasts(&hub).is_empty());

    hub.dispatch("worktreeSetup.cancel", json!({}));
    hub.mc.answer(
        &hub.engine,
        "worktreeSetup.cancel",
        Ok(json!({"cancelled": false})),
    );
    hub.dispatch("worktreeSetup.cancel", json!({}));
    hub.mc
        .answer(&hub.engine, "worktreeSetup.cancel", Err(failure("MC gone")));
    // Newest first.
    assert_eq!(
        toasts(&hub),
        [
            (
                "Could not cancel the worktree setup".to_owned(),
                "MC gone".to_owned()
            ),
            (
                "Could not cancel the worktree setup".to_owned(),
                "The agent has already started.".to_owned()
            ),
        ]
    );
}

// --- Against its model --------------------------------------------------------

mod model {
    use hal_c2_shell::controllers::worktree_setup;
    use hal_c2_shell::json::Json;
    use proptest::prelude::*;
    use serde_json::{Map, json};

    use super::{followed, running, setup, state};
    use crate::Hub;
    use crate::page::{failure, toasts};
    use crate::workspace::{AT, project};

    const THREADS: [&str; 2] = ["t1", "t2"];
    const MEMBERS: [&str; 2] = ["a", "b"];
    const CANNOT: &str = "Could not cancel the worktree setup";

    #[derive(Clone, Debug)]
    enum Op {
        Open(usize),
        Away,
        /// The cluster's member `MEMBERS[i]` serves env-1 now.
        Serve(usize),
        Setup(Json),
        Details(bool),
        Cancel,
        /// The oldest cancel is answered: cancelled, too late, or failed.
        Answer(Option<bool>),
    }

    fn event() -> impl Strategy<Value = Json> {
        let ended = |phase: &'static str, stage: &'static str| {
            let mut event = running();
            event["phase"] = phase.into();
            event["error"] = "why".into();
            event["stages"] =
                json!([{"id": "setup-script", "status": stage, "tail": [true, null]}]);
            event
        };
        prop_oneof![
            Just(running()),
            Just(ended("done", "done")),
            Just(ended("done", "failed")),
            Just(ended("failed", "failed")),
            Just(ended("cancelled", "pending")),
            Just(json!(null)),
            // What no MC sends, and the shell must not fall over on.
            Just(json!({"phase": 3, "stages": [1, null, {"tail": "x"}], "setupScript": "Install"})),
            Just(json!({"stages": {}})),
            Just(json!("running")),
        ]
    }

    fn op() -> impl Strategy<Value = Op> {
        prop_oneof![
            3 => (0usize..2).prop_map(Op::Open),
            1 => Just(Op::Away),
            1 => (0usize..2).prop_map(Op::Serve),
            4 => event().prop_map(Op::Setup),
            2 => any::<bool>().prop_map(Op::Details),
            2 => Just(Op::Cancel),
            2 => proptest::option::of(any::<bool>()).prop_map(Op::Answer),
        ]
    }

    #[derive(Debug, Default)]
    struct Model {
        thread: Option<usize>,
        member: usize,
        snapshot: Map<String, Json>,
        details: bool,
        /// Cancels asked and not answered yet.
        cancels: usize,
        asked: Vec<Json>,
        /// Newest first.
        toasts: Vec<(String, String)>,
    }

    impl Model {
        /// Follows `thread` on `member`; anything else starts over.
        fn follow(&mut self, thread: Option<usize>, member: usize) {
            let moved = thread != self.thread || (thread.is_some() && member != self.member);
            self.thread = thread;
            self.member = member;
            if moved {
                self.snapshot = Map::new();
                self.details = false;
            }
        }

        fn key(&self) -> String {
            self.thread
                .map(|t| format!("env-1:{}", THREADS[t]))
                .unwrap_or_default()
        }
    }

    fn serve(hub: &Hub, member: &str) {
        let tagged = |row: Json| {
            let mut row = row;
            row[0] = member.into();
            row
        };
        let thread = |id: &str| {
            json!([member, id, "thread", {"id": id, "projectId": "p1", "title": id,
                "branch": "main", "createdAt": AT, "updatedAt": AT}])
        };
        hub.mc.frame(
            &hub.engine,
            "shell",
            "",
            json!({"t": "shell",
                "mcs": [{"mc": member, "online": true, "epoch": "e", "rev": 1,
                         "environment": {"environmentId": "env-1", "label": "env-1"}}],
                "rows": [tagged(project(json!({}))), thread("t1"), thread("t2")]}),
        );
    }

    struct World {
        hub: Hub,
        model: Model,
    }

    impl World {
        fn new() -> World {
            let hub = Hub::clustered();
            serve(&hub, MEMBERS[0]);
            World {
                hub,
                model: Model::default(),
            }
        }

        fn step(&mut self, op: Op) {
            let hub = &self.hub;
            let m = &mut self.model;
            match op {
                Op::Open(t) => {
                    hub.dispatch(
                        "thread.open",
                        json!({"key": format!("env-1:{}", THREADS[t])}),
                    );
                    m.follow(Some(t), m.member);
                }
                Op::Away => {
                    hub.dispatch("usage.open", json!({}));
                    m.follow(None, m.member);
                }
                Op::Serve(member) => {
                    serve(hub, MEMBERS[member]);
                    m.follow(m.thread, member);
                }
                Op::Setup(event) => {
                    setup(hub, event.clone());
                    if m.thread.is_some() {
                        m.snapshot = event.as_object().cloned().unwrap_or_default();
                    }
                }
                Op::Details(open) => {
                    hub.dispatch("worktreeSetup.details", json!({"open": open}));
                    m.details = open;
                }
                Op::Cancel => {
                    hub.dispatch("worktreeSetup.cancel", json!({}));
                    if let Some(t) = m.thread {
                        m.cancels += 1;
                        m.asked.push(json!({"threadId": THREADS[t]}));
                    }
                }
                Op::Answer(cancelled) => {
                    if m.cancels == 0 {
                        return;
                    }
                    let result = match cancelled {
                        Some(cancelled) => Ok(json!({"cancelled": cancelled})),
                        None => Err(failure("MC gone")),
                    };
                    hub.mc.answer(&hub.engine, "worktreeSetup.cancel", result);
                    m.cancels -= 1;
                    let why = match cancelled {
                        Some(true) => return,
                        Some(false) => "The agent has already started.",
                        None => "MC gone",
                    };
                    m.toasts.insert(0, (CANNOT.to_owned(), why.to_owned()));
                }
            }
        }

        fn check(&self) {
            let m = &self.model;
            let expected: Vec<Json> = m
                .thread
                .map(|t| json!({"type": "worktreeSetup", "mc": MEMBERS[m.member], "threadId": THREADS[t]}))
                .into_iter()
                .collect();
            assert_eq!(followed(&self.hub), expected);
            assert_eq!(
                state(&self.hub),
                worktree_setup::state(&m.key(), &m.snapshot, m.details)
            );
            let asked: Vec<Json> = self
                .hub
                .mc
                .calls
                .borrow()
                .iter()
                .filter(|(_, method, _)| method == "worktreeSetup.cancel")
                .inspect(|(environment, _, _)| assert_eq!(environment, "env-1"))
                .map(|(_, _, input)| input.clone())
                .collect();
            assert_eq!(asked, m.asked);
            assert_eq!(toasts(&self.hub), m.toasts);
        }
    }

    proptest! {
        #![proptest_config(ProptestConfig { cases: 256, ..ProptestConfig::default() })]

        #[test]
        fn the_setup_shown_follows_its_model(ops in proptest::collection::vec(op(), 1..40)) {
            let mut world = World::new();
            world.check();
            for op in ops {
                world.step(op);
                world.check();
            }
        }
    }
}
