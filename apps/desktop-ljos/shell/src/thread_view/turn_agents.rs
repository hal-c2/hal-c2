//! `TurnAgents`, mobile-qt's TurnAgents: the subagents of a thread's
//! latest turn, which the phone's thread shows above its composer
//! (packages/client-runtime/src/state/threadSubagents.ts): the
//! running turn's, else the turn of the subagent heard from last, in
//! the order they started. `summary` reads "2 of 3 agents working"
//! while any works, "3 agents done" once all finished and the turn
//! has not, and nothing once the turn settled with none working. Its
//! rows are the list the summary opens (ThreadAgentsSheet): a
//! provider-managed subagent has no thread to open.
//!
//! Read again from the timeline whenever its subagents or runs
//! change (`agentsChanged`, as the shell's AgentsModel follows it).
//! A working row's elapsed time moves once a second, only while the
//! list shows (`active`). [`TurnAgents`] is the core;
//! [`TurnAgentsObject`] is the creatable `HalC2.Shell` type
//! ThreadScreen makes, with the shell's ListRows under it.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;

use crate::json::Json;
use crate::schedule::{self, Held};
use crate::thread_view::agents::format_elapsed;
use crate::thread_view::rows::{ListRows, RowChange, RowSource};
use crate::thread_view::summary::{Obj, subagent_live, subagent_title};
use crate::thread_view::time::{Clock, time_of};
use crate::thread_view::timeline_model::TimelineModel;
use ljos::prelude::{
    Atom, ConnectionId, Cx, Engine, EngineError, ObjectId, QmlObject, RowKey, Value, qml_impl,
};
use serde_json::json;

const ROLES: &[&str] = &[
    "agentId",
    "title",
    "status",
    "statusLabel",
    "running",
    "elapsed",
    "thread",
];

fn text<'a>(object: &'a Obj, field: &str) -> &'a str {
    object.get(field).and_then(Json::as_str).unwrap_or_default()
}

/// Working, Idle · resumable, Completed, Failed or Stopped.
fn status_label(status: &str) -> &'static str {
    if subagent_live(status) {
        return "Working";
    }
    match status {
        "idle" => "Idle · resumable",
        "completed" => "Completed",
        "failed" => "Failed",
        "cancelled" | "interrupted" => "Stopped",
        _ => "",
    }
}

fn run_active(status: &str) -> bool {
    matches!(status, "preparing" | "starting" | "running")
}

struct Row {
    key: RowKey,
    agent: Obj,
}

/// The latest turn's subagents as a pure core: feed it a timeline's
/// `subagent` and `run` entities with [`TurnAgents::read`].
#[derive(Default)]
pub struct TurnAgents {
    rows: Vec<Row>,
    environment: String,
    summary: String,
    live: usize,
    active: bool,
    clock: Clock,
    keys: HashMap<String, RowKey>,
    next_key: RowKey,
    changes: Vec<RowChange>,
}

impl std::fmt::Debug for TurnAgents {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TurnAgents")
            .field("rows", &self.rows.len())
            .field("summary", &self.summary)
            .finish_non_exhaustive()
    }
}

impl TurnAgents {
    pub fn new(clock: Clock) -> TurnAgents {
        TurnAgents {
            clock,
            ..TurnAgents::default()
        }
    }

    pub fn set_clock(&mut self, clock: Clock) {
        self.clock = clock;
    }

    pub fn count(&self) -> usize {
        self.rows.len()
    }

    pub fn summary(&self) -> &str {
        &self.summary
    }

    /// The turn's agents still working.
    pub fn live(&self) -> usize {
        self.live
    }

    pub fn active(&self) -> bool {
        self.active
    }

    /// Whether the elapsed times move: shown, with work running.
    pub fn ticking(&self) -> bool {
        self.active && self.live > 0
    }

    pub fn set_active(&mut self, active: bool) {
        if active == self.active {
            return;
        }
        self.active = active;
        // Shown again, the times catch up at once.
        if active && !self.rows.is_empty() {
            self.changes.push(RowChange::Changed {
                first: 0,
                count: self.rows.len(),
                roles: &["elapsed"],
            });
        }
    }

    /// One second passing: a working row's elapsed time moves.
    pub fn tick(&mut self) {
        for (index, row) in self.rows.iter().enumerate() {
            if subagent_live(text(&row.agent, "status")) {
                self.changes.push(RowChange::Changed {
                    first: index,
                    count: 1,
                    roles: &["elapsed"],
                });
            }
        }
    }

    /// Reads the timeline's entities again (TurnAgents::read):
    /// `thread_key` names the child threads' environment.
    pub fn read(
        &mut self,
        agents: &BTreeMap<String, Obj>,
        runs: &BTreeMap<String, Obj>,
        thread_key: &str,
    ) {
        self.environment = thread_key
            .split_once(':')
            .map_or("", |(environment, _)| environment)
            .to_owned();
        let zone = self.clock.zone;
        let at = |agent: &Obj, field: &str| time_of(agent.get(field), zone);
        // The running turn, the latest when several are.
        let mut run_id = String::new();
        let mut ordinal = -1.0f64;
        for (id, run) in runs {
            if !run_active(text(run, "status")) {
                continue;
            }
            let at = run
                .get("ordinal")
                .and_then(Json::as_f64)
                .unwrap_or_default();
            if at > ordinal || (at == ordinal && id.as_str() > run_id.as_str()) {
                ordinal = at;
                run_id = id.clone();
            }
        }
        let turn_active = !run_id.is_empty();
        // Else the turn of the subagent heard from last: a turn that
        // just ended leaves results the user has not read yet.
        if !turn_active {
            let mut latest: Option<chrono::DateTime<chrono::Utc>> = None;
            let mut latest_id = String::new();
            for (id, agent) in agents {
                let updated = at(agent, "updatedAt");
                if latest_id.is_empty()
                    || updated > latest
                    || (updated == latest && id.as_str() > latest_id.as_str())
                {
                    latest = updated;
                    latest_id = id.clone();
                    run_id = text(agent, "runId").to_owned();
                }
            }
        }
        let mut rows: Vec<Obj> = Vec::new();
        for (id, agent) in agents {
            if run_id.is_empty() || text(agent, "runId") != run_id {
                continue;
            }
            let mut agent = agent.clone();
            agent.insert("id".into(), json!(id));
            rows.push(agent);
        }
        // When it started, else when it was last heard from.
        let order_of = |agent: &Obj| at(agent, "startedAt").or_else(|| at(agent, "updatedAt"));
        rows.sort_by(|a, b| {
            order_of(a)
                .cmp(&order_of(b))
                .then_with(|| text(a, "id").cmp(text(b, "id")))
        });
        let live = rows
            .iter()
            .filter(|agent| subagent_live(text(agent, "status")))
            .count();
        let summary = if !rows.is_empty() && (turn_active || live > 0) {
            let total = rows.len();
            if live > 0 {
                format!("{live} of {total} agents working")
            } else if total == 1 {
                "1 agent done".into()
            } else {
                format!("{total} agents done")
            }
        } else {
            String::new()
        };
        // A handful of rows, read anew: the list is small and opened
        // for a glance.
        let changed = rows.len() != self.rows.len()
            || rows
                .iter()
                .zip(&self.rows)
                .any(|(next, held)| next != &held.agent);
        if changed {
            let mut keys = Vec::with_capacity(rows.len());
            let mut held: Vec<Row> = Vec::with_capacity(rows.len());
            for agent in rows {
                let id = text(&agent, "id").to_owned();
                let key = *self.keys.entry(id).or_insert_with(|| {
                    self.next_key += 1;
                    self.next_key
                });
                keys.push(key);
                held.push(Row { key, agent });
            }
            self.rows = held;
            self.changes.push(RowChange::Reset(keys));
        }
        self.summary = summary;
        self.live = live;
    }

    /// One role of one row as JSON, for tests as for the views.
    pub fn value(&self, row: usize, role: &str) -> Option<Json> {
        let agent = &self.rows.get(row)?.agent;
        let status = text(agent, "status");
        Some(match role {
            "agentId" => json!(text(agent, "id")),
            "title" => {
                let title = subagent_title(text(agent, "title").trim());
                if !title.is_empty() {
                    json!(title)
                } else {
                    let prompt = text(agent, "prompt")
                        .trim()
                        .split('\n')
                        .next()
                        .unwrap_or_default();
                    json!(if prompt.is_empty() {
                        "Subagent"
                    } else {
                        prompt
                    })
                }
            }
            "status" => json!(status),
            "statusLabel" => json!(status_label(status)),
            "running" => json!(subagent_live(status)),
            "elapsed" => {
                let zone = self.clock.zone;
                let Some(started) = time_of(agent.get("startedAt"), zone) else {
                    return Some(json!(""));
                };
                let ended = if subagent_live(status) {
                    Some(self.clock.now())
                } else {
                    time_of(agent.get("completedAt"), zone)
                        .or_else(|| time_of(agent.get("updatedAt"), zone))
                };
                json!(ended.map_or_else(String::new, |ended| format_elapsed(
                    (ended - started).num_seconds()
                )))
            }
            "thread" => {
                let child = text(agent, "childThreadId");
                json!(if child.is_empty() {
                    String::new()
                } else {
                    format!("{}:{child}", self.environment)
                })
            }
            _ => return None,
        })
    }
}

impl RowSource for TurnAgents {
    fn roles(&self) -> &'static [&'static str] {
        ROLES
    }

    fn row_count(&self) -> usize {
        self.rows.len()
    }

    fn row_key(&self, row: usize) -> RowKey {
        self.rows.get(row).map_or(row as RowKey, |held| held.key)
    }

    fn data(&self, row: usize, role: &str) -> Value {
        match self.value(row, role) {
            Some(Json::String(s)) => Value::from(s.as_str()),
            Some(Json::Bool(b)) => Value::Bool(b),
            _ => Value::Undefined,
        }
    }

    fn take_changes(&mut self) -> Vec<RowChange> {
        std::mem::take(&mut self.changes)
    }
}

/// What the object holds besides its properties.
struct Inner {
    rows: Rc<ListRows<TurnAgents>>,
    /// The TimelineModel followed, and its connections.
    timeline: Cell<Option<ObjectId>>,
    connections: RefCell<Vec<ConnectionId>>,
    /// The elapsed times' second, while the list shows a working row.
    tick: Held,
    /// What the properties were last told: count, summary, ticking.
    told: RefCell<(i32, String, bool)>,
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TurnAgents")
            .field("rows", &self.rows)
            .finish_non_exhaustive()
    }
}

/// The phone thread's latest turn's subagents: `TurnAgents {}` in
/// ThreadScreen. A TimelineModel is followed through `timeline`;
/// `active` says the list shows.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "TurnAgents")]
pub struct TurnAgentsObject {
    #[qml(notify)]
    timeline: Value,
    #[qml(notify)]
    active: bool,
    #[qml(readonly, notify)]
    count: i32,
    #[qml(readonly, notify)]
    summary: Atom,
    #[qml(skip)]
    inner: Rc<Inner>,
}

impl Default for TurnAgentsObject {
    fn default() -> Self {
        TurnAgentsObject {
            timeline: Value::Null,
            active: false,
            count: 0,
            summary: Atom::from(""),
            inner: Rc::new(Inner {
                rows: ListRows::new(TurnAgents::new(Clock::default())),
                timeline: Cell::new(None),
                connections: RefCell::default(),
                tick: Held::default(),
                told: RefCell::new((0, String::new(), false)),
            }),
        }
    }
}

fn inner_of(engine: &Engine, obj: ObjectId) -> Option<Rc<Inner>> {
    engine
        .with::<TurnAgentsObject, _>(obj, |m| m.inner.clone())
        .ok()
}

fn warn(engine: &Engine, e: &EngineError) {
    engine.log(
        ljos::prelude::LogLevel::Warning,
        "TurnAgents",
        e.to_string(),
    );
}

impl TurnAgentsObject {
    /// Reads the followed timeline again.
    fn read(engine: &Engine, obj: ObjectId) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        // Read out first: the timeline is not borrowed while views
        // hear of the rows.
        let read = inner.timeline.get().and_then(|timeline| {
            TimelineModel::read(engine, timeline, |t| {
                (
                    t.entities("subagent").clone(),
                    t.entities("run").clone(),
                    t.thread_key().to_owned(),
                )
            })
        });
        let (agents, runs, thread_key) = read.unwrap_or_default();
        Self::update(engine, obj, |core| core.read(&agents, &runs, &thread_key));
    }

    /// One second passing, as the model's own timer says it.
    fn tick(engine: &Engine, obj: ObjectId) {
        Self::update(engine, obj, TurnAgents::tick);
    }

    /// Runs `f` on the core of `obj`, then tells the views, the
    /// properties and the timer what changed.
    fn update(engine: &Engine, obj: ObjectId, f: impl FnOnce(&mut TurnAgents)) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        inner.rows.update(engine, f);
        let (count, summary, ticking) = inner.rows.read(|core| {
            (
                core.count() as i32,
                core.summary().to_owned(),
                core.ticking(),
            )
        });
        let told = {
            let mut told = inner.told.borrow_mut();
            if *told == (count, summary.clone(), ticking) {
                return;
            }
            let was_ticking = told.2;
            *told = (count, summary.clone(), ticking);
            was_ticking
        };
        let told = told;
        let result = engine
            .set_internal(obj, TurnAgentsObject::COUNT, count)
            .and_then(|()| {
                engine.set_internal(obj, TurnAgentsObject::SUMMARY, Atom::from(summary.as_str()))
            });
        if let Err(e) = result {
            warn(engine, &e);
        }
        if ticking != told {
            inner.tick.cancel(engine);
            if ticking {
                let tick = schedule::every(
                    engine,
                    "turn agents elapsed",
                    Some(obj),
                    std::time::Duration::from_secs(1),
                    move |engine| TurnAgentsObject::tick(engine, obj),
                );
                inner.tick.hold(engine, tick);
            }
        }
    }

    /// The written `timeline` and `active`, taken together.
    fn apply(engine: &Engine, obj: ObjectId) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        let timeline = match engine.read_by_name(obj, "timeline") {
            Value::Object(id) => Some(id),
            _ => None,
        };
        if timeline != inner.timeline.get() {
            for connection in inner.connections.take() {
                engine.disconnect(connection);
            }
            inner.timeline.set(timeline);
            if let Some(timeline) = timeline {
                let connected = engine
                    .signal_index(timeline, "agentsChanged")
                    .and_then(|s| {
                        engine.connect_to(timeline, s, obj, move |e, _| {
                            TurnAgentsObject::read(e, obj)
                        })
                    });
                match connected {
                    Ok(id) => {
                        inner.connections.replace(vec![id]);
                    }
                    Err(e) => warn(engine, &e),
                }
            }
            Self::read(engine, obj);
        }
        let active = matches!(engine.read_by_name(obj, "active"), Value::Bool(true));
        Self::update(engine, obj, |core| core.set_active(active));
    }
}

#[qml_impl]
impl TurnAgentsObject {
    #[qml(on_complete)]
    fn completed(cx: &Cx) -> Result<(), EngineError> {
        let obj = cx.this;
        let inner = inner_of(cx.engine, obj).ok_or(EngineError::DeadObject(obj))?;
        inner.rows.attach(cx.engine, obj)?;
        for prop in [Self::TIMELINE.index, Self::ACTIVE.index] {
            cx.engine.watch(obj, prop, move |engine, _| {
                TurnAgentsObject::apply(engine, obj);
            })?;
        }
        TurnAgentsObject::apply(cx.engine, obj);
        Ok(())
    }
}
