//! The subagents of a thread's latest turn against a model of the
//! turns and subagents the MC streams, as mobile-qt's RapidCheck
//! prop holds its C++ (tests/prop/tst_TurnAgentsProp): turns start
//! and settle, subagents spawn into the running turn, move between
//! states and are heard from again, and the list opens and closes.
//! After each step the list holds the turn the roster names (the
//! running turn, else that of the subagent heard from last) in the
//! order its subagents started, and the summary reads as the model's.
//! The C++ drives a TimelineModel with patches; the core here is fed
//! the entities those patches make, which is what it reads.

use std::collections::BTreeMap;

use chrono::{TimeZone, Utc};
use hal_c2_shell::thread_view::turn_agents::TurnAgents;
use hal_c2_shell::thread_view::summary::Obj;
use hal_c2_shell::thread_view::time::Clock;
use proptest::prelude::*;
use serde_json::json;

const KEY: &str = "env-1:thread-1";
const MAX_RUNS: usize = 3;
const MAX_AGENTS: usize = 6;
const STATUSES: &[&str] = &[
    "pending", "running", "waiting", "idle", "completed", "failed", "cancelled",
];

fn live(status: &str) -> bool {
    matches!(status, "pending" | "running" | "waiting")
}

fn at(seconds: i64) -> String {
    (Utc.with_ymd_and_hms(2026, 9, 23, 10, 0, 0).unwrap() + chrono::Duration::seconds(seconds))
        .format("%Y-%m-%dT%H:%M:%S%.3fZ")
        .to_string()
}

#[derive(Clone, Debug)]
struct Agent {
    run: usize,
    status: &'static str,
    started: i64,
    updated: i64,
    native: bool,
}

#[derive(Clone, Default)]
struct Model {
    runs: usize,
    running: bool,
    agents: BTreeMap<usize, Agent>,
    clock: i64,
    active: bool,
}

fn agent_id(n: usize) -> String {
    format!("agent-{n:02}")
}

fn run_id(n: usize) -> String {
    format!("run-{n}")
}

/// The rows the list should show, as (id, status, thread), and its
/// summary.
fn expected(model: &Model) -> (Vec<(String, String, String)>, String) {
    let mut run: Option<usize> = None;
    if model.running {
        run = Some(model.runs - 1);
    } else {
        let mut latest: Option<i64> = None;
        let mut latest_id = String::new();
        for (n, agent) in &model.agents {
            if latest_id.is_empty()
                || Some(agent.updated) > latest
                || (Some(agent.updated) == latest && agent_id(*n) > latest_id)
            {
                latest = Some(agent.updated);
                latest_id = agent_id(*n);
                run = Some(agent.run);
            }
        }
    }
    let mut rows = Vec::new();
    let mut live_count = 0;
    for (n, agent) in &model.agents {
        if Some(agent.run) != run {
            continue;
        }
        rows.push((
            agent_id(*n),
            agent.status.to_owned(),
            if agent.native {
                String::new()
            } else {
                format!("env-1:child-{n}")
            },
        ));
        if live(agent.status) {
            live_count += 1;
        }
    }
    let total = rows.len();
    let summary = if total > 0 && (model.running || live_count > 0) {
        if live_count > 0 {
            format!("{live_count} of {total} agents working")
        } else if total == 1 {
            "1 agent done".into()
        } else {
            format!("{total} agents done")
        }
    } else {
        String::new()
    };
    (rows, summary)
}

/// The entities the model's patches leave in the timeline.
fn entities(model: &Model) -> (BTreeMap<String, Obj>, BTreeMap<String, Obj>) {
    let mut runs = BTreeMap::new();
    for n in 0..model.runs {
        let status = if model.running && n == model.runs - 1 {
            "running"
        } else {
            "completed"
        };
        let mut run = Obj::new();
        run.insert("status".into(), json!(status));
        run.insert("ordinal".into(), json!(n));
        runs.insert(run_id(n), run);
    }
    let mut agents = BTreeMap::new();
    for (n, agent) in &model.agents {
        let mut entity = Obj::new();
        entity.insert("runId".into(), json!(run_id(agent.run)));
        entity.insert("title".into(), json!(format!("Agent {n}")));
        entity.insert("status".into(), json!(agent.status));
        entity.insert("startedAt".into(), json!(at(agent.started)));
        entity.insert("updatedAt".into(), json!(at(agent.updated)));
        if !agent.native {
            entity.insert("childThreadId".into(), json!(format!("child-{n}")));
        }
        agents.insert(agent_id(*n), entity);
    }
    (agents, runs)
}

#[derive(Clone, Debug)]
enum Action {
    StartRun,
    SettleRun,
    Spawn { status: &'static str, native: bool },
    Move { pick: usize, status: &'static str },
    Show(bool),
}

fn action() -> impl Strategy<Value = Action> {
    prop_oneof![
        Just(Action::StartRun),
        Just(Action::SettleRun),
        (prop_oneof![Just("pending"), Just("running")], any::<bool>())
            .prop_map(|(status, native)| Action::Spawn { status, native }),
        (0usize..MAX_AGENTS, prop::sample::select(STATUSES))
            .prop_map(|(pick, status)| Action::Move { pick, status }),
        any::<bool>().prop_map(Action::Show),
    ]
}

fn check(core: &TurnAgents, model: &Model) -> Result<(), TestCaseError> {
    let (rows, summary) = expected(model);
    prop_assert_eq!(core.count(), rows.len());
    for (index, (id, status, thread)) in rows.iter().enumerate() {
        prop_assert_eq!(core.value(index, "agentId"), Some(json!(id)));
        prop_assert_eq!(core.value(index, "status"), Some(json!(status)));
        prop_assert_eq!(core.value(index, "thread"), Some(json!(thread)));
        prop_assert_eq!(core.value(index, "running"), Some(json!(live(status))));
    }
    prop_assert_eq!(core.summary(), summary.as_str());
    prop_assert_eq!(core.active(), model.active);
    Ok(())
}

proptest! {
    #[test]
    fn the_list_holds_the_latest_turns_subagents(
        actions in prop::collection::vec(action(), 0..40),
    ) {
        let clock = Clock::fixed(
            Utc.with_ymd_and_hms(2026, 9, 23, 11, 0, 0).unwrap(),
        );
        let mut core = TurnAgents::new(clock);
        let mut model = Model::default();
        check(&core, &model)?;
        for action in actions {
            // The C++ commands' preconditions: one whose does not
            // hold is not applied, as RapidCheck's state machine
            // never runs it.
            let applied = match action {
                Action::StartRun if model.runs < MAX_RUNS => {
                    model.running = true;
                    model.runs += 1;
                    model.clock += 1;
                    true
                }
                Action::SettleRun if model.running => {
                    model.running = false;
                    model.clock += 1;
                    true
                }
                Action::Spawn { status, native }
                    if model.running && model.agents.len() < MAX_AGENTS =>
                {
                    model.clock += 1;
                    let n = model.agents.len();
                    model.agents.insert(n, Agent {
                        run: model.runs - 1,
                        status,
                        started: model.clock,
                        updated: model.clock,
                        native,
                    });
                    true
                }
                Action::Move { pick, status } if model.agents.contains_key(&pick) => {
                    model.clock += 1;
                    let agent = model.agents.get_mut(&pick).unwrap();
                    agent.status = status;
                    agent.updated = model.clock;
                    true
                }
                Action::Show(active) => {
                    model.active = active;
                    core.set_active(active);
                    false
                }
                _ => false,
            };
            if applied {
                let (agents, runs) = entities(&model);
                core.read(&agents, &runs, KEY);
            }
            check(&core, &model)?;
        }
    }
}
