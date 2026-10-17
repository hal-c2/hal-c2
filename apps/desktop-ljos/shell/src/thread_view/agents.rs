//! desktop-qt's AgentsModel: the right panel's Agents tab, a thread's work
//! in two sections, as the sidebar keeps its threads. Active on top: the
//! subagents working, in the order they started, then the commands still
//! running. Finished below: the settled subagents, the latest to end first.
//! Read from the thread's timeline (its `subagent` entities and
//! `command_execution` turn items) and updated in place as they change,
//! rows moving between sections, so the list keeps its scroll.
//!
//! A running row's elapsed time moves once a second, and only while the tab
//! shows ([`AgentsModel::set_active`]) and something is running; a settled
//! one stays at the time it took. When each ended is redrawn at midnight,
//! when it shows.
//!
//! [`Agents`] is the core; [`AgentsModel`] is the object QML binds, which
//! follows a [`TimelineModel`]'s `agentsChanged` and `timesChanged` and runs
//! the core's two timers.
//!
//! The right panel owns one (`Panel.agents`): it gives it the shown thread
//! with [`AgentsModel::set_thread`] and says whether the Agents tab shows
//! with [`AgentsModel::set_active`].

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashSet};
use std::rc::Rc;

use chrono::{DateTime, Duration, NaiveTime, Utc};
use ljos::prelude::ConnectionId;
use ljos::prelude::{Atom, Cx, Engine, ObjectId, QmlObject, Value, qml_impl};
use ljos::prelude::{EngineError, RowKey};

use super::rows::{ListRows, RowChange, RowSource, int};
use super::summary::{Obj, subagent_detail};
use super::time::{self, Clock};
use super::timeline::Timeline;
use super::timeline_model::TimelineModel;
use crate::json::Json;

pub const ROLES: &[&str] = &[
    "agentId",
    "kind",
    "title",
    "status",
    "statusLabel",
    "running",
    "elapsed",
    "detail",
    "modelName",
    "childThreadKey",
    "section",
    "ended",
];

const ELAPSED: &[&str] = &["elapsed"];
const ENDED: &[&str] = &["ended"];

/// How often a running row's elapsed time moves.
pub const TICK_MS: i32 = 1000;

fn live(status: &str) -> bool {
    matches!(status, "pending" | "running" | "waiting")
}

fn text<'a>(entity: &'a Obj, field: &str) -> &'a str {
    entity.get(field).and_then(Json::as_str).unwrap_or("")
}

/// The label a lifecycle status reads as.
fn status_label(status: &str) -> &'static str {
    match status {
        s if live(s) => "Working",
        "idle" => "Idle · resumable",
        "completed" => "Completed",
        "failed" => "Failed",
        "cancelled" | "interrupted" => "Stopped",
        _ => "",
    }
}

/// 12s, 3m 04s, 1h 02m.
pub fn format_elapsed(total: i64) -> String {
    let seconds = total.max(0);
    let minutes = seconds / 60;
    if minutes == 0 {
        return format!("{seconds}s");
    }
    let hours = minutes / 60;
    if hours == 0 {
        return format!("{minutes}m {:02}s", seconds % 60);
    }
    format!("{hours}h {:02}m", minutes % 60)
}

/// One row the tab wants: a subagent or a running command.
#[derive(Clone, Debug, PartialEq)]
pub struct Wanted {
    pub id: String,
    /// subagent or command
    pub kind: &'static str,
    pub entity: Obj,
}

/// The rows a timeline's entities make, in the tab's order: the working
/// subagents in spawn order, the running commands (not of a rolled-back
/// run) in turn order, then the settled subagents, the latest to end first.
pub fn wanted(
    subagents: &BTreeMap<String, Obj>,
    runs: &BTreeMap<String, Obj>,
    items: &BTreeMap<String, Obj>,
    clock: &Clock,
) -> Vec<Wanted> {
    let row = |id: &String, kind, entity: &Obj| Wanted {
        id: id.clone(),
        kind,
        entity: entity.clone(),
    };
    let (mut working, mut settled): (Vec<Wanted>, Vec<Wanted>) = subagents
        .iter()
        .map(|(id, entity)| row(id, "subagent", entity))
        .partition(|w| live(text(&w.entity, "status")));
    // Spawn order, which a sibling settling does not change.
    working.sort_by(|a, b| {
        text(&a.entity, "startedAt")
            .cmp(text(&b.entity, "startedAt"))
            .then_with(|| a.id.cmp(&b.id))
    });
    // The latest to end first.
    settled.sort_by(|a, b| {
        end_of(&b.entity, clock)
            .cmp(&end_of(&a.entity, clock))
            .then_with(|| a.id.cmp(&b.id))
    });
    let rolled_back: HashSet<&str> = runs
        .iter()
        .filter(|(_, run)| text(run, "status") == "rolled_back")
        .map(|(id, _)| id.as_str())
        .collect();
    let mut commands: Vec<Wanted> = items
        .iter()
        .filter(|(_, item)| {
            text(item, "type") == "command_execution"
                && live(text(item, "status"))
                && !rolled_back.contains(text(item, "runId"))
        })
        .map(|(id, item)| row(id, "command", item))
        .collect();
    let ordinal = |w: &Wanted| {
        w.entity
            .get("ordinal")
            .and_then(Json::as_f64)
            .unwrap_or(0.0)
    };
    commands.sort_by(|a, b| {
        ordinal(a)
            .total_cmp(&ordinal(b))
            .then_with(|| a.id.cmp(&b.id))
    });
    working.extend(commands);
    working.extend(settled);
    working
}

/// The rows of `timeline`.
pub fn wanted_of(timeline: &Timeline, clock: &Clock) -> Vec<Wanted> {
    wanted(
        timeline.entities("subagent"),
        timeline.entities("run"),
        timeline.entities("turn-item"),
        clock,
    )
}

/// When a settled subagent ended: its completedAt, else its last update.
fn end_of(entity: &Obj, clock: &Clock) -> Option<DateTime<Utc>> {
    time::time_of(entity.get("completedAt"), clock.zone)
        .or_else(|| time::time_of(entity.get("updatedAt"), clock.zone))
}

#[derive(Clone, Debug)]
struct Row {
    key: RowKey,
    id: String,
    kind: &'static str,
    entity: Obj,
}

/// What the core tells its object besides its rows.
#[derive(Clone, Debug, PartialEq)]
pub enum Note {
    /// count and agentCount.
    Count,
    /// Start (true) or stop the once-a-second tick.
    Ticking(bool),
    /// Wait this long, then [`Agents::redraw_ended`]; none: do not.
    Day(Option<i64>),
}

/// The tab's rows, as a core.
#[derive(Debug)]
pub struct Agents {
    environment: String,
    /// The timeline's timestampFormat; none without a timeline.
    timestamp_format: Option<String>,
    rows: Vec<Row>,
    next_key: RowKey,
    active: bool,
    ticking: bool,
    /// The local midnight the end times are next redrawn at, while armed.
    next_day: Option<DateTime<Utc>>,
    clock: Clock,
    changes: Vec<RowChange>,
    notes: Vec<Note>,
}

impl Agents {
    pub fn new(clock: Clock) -> Agents {
        Agents {
            environment: String::new(),
            timestamp_format: None,
            rows: Vec::new(),
            next_key: 1,
            active: false,
            ticking: false,
            next_day: None,
            clock,
            changes: Vec::new(),
            notes: Vec::new(),
        }
    }

    pub fn set_clock(&mut self, clock: Clock) {
        self.clock = clock;
    }

    pub fn clock(&self) -> &Clock {
        &self.clock
    }

    /// The environment that names the child threads.
    pub fn set_environment(&mut self, environment: &str) {
        if environment == self.environment {
            return;
        }
        self.environment = environment.to_owned();
        if !self.rows.is_empty() {
            self.changes.push(RowChange::Changed {
                first: 0,
                count: self.rows.len(),
                roles: &["childThreadKey"],
            });
        }
    }

    /// Takes the rows the timeline wants (none: there is no timeline) and
    /// the time format its stamps read in.
    pub fn read(&mut self, timeline: Option<(Vec<Wanted>, String)>) {
        let rows = match timeline {
            Some((rows, format)) => {
                self.timestamp_format = Some(format);
                rows
            }
            None => {
                self.timestamp_format = None;
                Vec::new()
            }
        };
        self.apply(rows);
        self.update_timer();
    }

    /// Takes `rows` row by row: gone ones removed, new ones inserted, the
    /// rest moved to their place and redrawn when they changed. Never a
    /// reset, which would throw the list back to the top.
    fn apply(&mut self, rows: Vec<Wanted>) {
        let wanted: HashSet<&str> = rows.iter().map(|r| r.id.as_str()).collect();
        let mut counted = false;
        for i in (0..self.rows.len()).rev() {
            if wanted.contains(self.rows[i].id.as_str()) {
                continue;
            }
            self.rows.remove(i);
            self.changes.push(RowChange::Removed { first: i, count: 1 });
            counted = true;
        }
        for (i, row) in rows.into_iter().enumerate() {
            let Some(at) = (i..self.rows.len()).find(|j| self.rows[*j].id == row.id) else {
                let key = self.next_key;
                self.next_key += 1;
                self.rows.insert(
                    i,
                    Row {
                        key,
                        id: row.id,
                        kind: row.kind,
                        entity: row.entity,
                    },
                );
                self.changes.push(RowChange::Inserted {
                    first: i,
                    keys: vec![key],
                });
                counted = true;
                continue;
            };
            if at != i {
                let moved = self.rows.remove(at);
                self.rows.insert(i, moved);
                self.changes.push(RowChange::Moved { from: at, to: i });
            }
            let held = &mut self.rows[i];
            if held.entity == row.entity && held.kind == row.kind {
                continue;
            }
            held.kind = row.kind;
            held.entity = row.entity;
            self.changes.push(RowChange::Changed {
                first: i,
                count: 1,
                roles: &[],
            });
        }
        if counted {
            self.notes.push(Note::Count);
        }
    }

    /// Whether the tab shows. Hidden, the times stand still; shown, they
    /// catch up at once.
    pub fn set_active(&mut self, active: bool) {
        if active == self.active {
            return;
        }
        self.active = active;
        if active {
            self.tick();
            self.redraw_ended();
        }
        self.update_timer();
    }

    /// One second passing: running rows show their new elapsed time.
    pub fn tick(&mut self) {
        for (i, row) in self.rows.iter().enumerate() {
            if live(text(&row.entity, "status")) {
                self.changes.push(RowChange::Changed {
                    first: i,
                    count: 1,
                    roles: ELAPSED,
                });
            }
        }
    }

    /// The end times read anew: the day, the time format or the locale
    /// changed.
    pub fn redraw_ended(&mut self) {
        self.redraw_all_ended();
        self.update_timer();
    }

    /// The midnight timer fired: it is spent (one is armed again for the
    /// next midnight), and the end times read anew.
    pub fn day_turned(&mut self) {
        self.next_day = None;
        self.redraw_ended();
    }

    /// The timeline's time format changed.
    pub fn set_timestamp_format(&mut self, format: &str) {
        if self.timestamp_format.is_some() {
            self.timestamp_format = Some(format.to_owned());
        }
        self.redraw_ended();
    }

    fn redraw_all_ended(&mut self) {
        if !self.rows.is_empty() {
            self.changes.push(RowChange::Changed {
                first: 0,
                count: self.rows.len(),
                roles: ENDED,
            });
        }
    }

    fn update_timer(&mut self) {
        let running = self.rows.iter().any(|r| live(text(&r.entity, "status")));
        let ticking = self.active && running;
        if ticking != self.ticking {
            self.ticking = ticking;
            self.notes.push(Note::Ticking(ticking));
        }
        let now = self.clock.now();
        // Past midnight before the timer fired (the desktop slept):
        // yesterday's end times are redrawn before it waits for the next.
        if self.next_day.is_some_and(|next| next <= now) {
            self.redraw_all_ended();
        }
        let next = if self.active && !self.rows.is_empty() {
            let tomorrow = self.clock.zone.local(now).date() + Duration::days(1);
            self.clock
                .zone
                .utc_of(tomorrow.and_time(NaiveTime::MIN))
                // A zone without that midnight (a change at 00:00): its
                // first hour.
                .or_else(|| {
                    self.clock
                        .zone
                        .utc_of(tomorrow.and_hms_opt(1, 0, 0).unwrap_or_default())
                })
        } else {
            None
        };
        if next != self.next_day {
            self.next_day = next;
            let wait = next.map(|next| (next - now).num_milliseconds().max(1000));
            self.notes.push(Note::Day(wait));
        }
    }

    /// Whether the elapsed times are moving.
    pub fn ticking(&self) -> bool {
        self.ticking
    }

    /// When the tab next redraws its end times by itself: at local
    /// midnight, while it shows; none when it will not.
    pub fn next_day(&self) -> Option<DateTime<Utc>> {
        self.next_day
    }

    pub fn active(&self) -> bool {
        self.active
    }

    pub fn count(&self) -> usize {
        self.rows.len()
    }

    /// Subagents listed (commands aside).
    pub fn agent_count(&self) -> usize {
        self.rows.iter().filter(|r| r.kind == "subagent").count()
    }

    pub fn index_of(&self, id: &str) -> Option<usize> {
        self.rows.iter().position(|r| r.id == id)
    }

    /// What `role` of `row` reads; None for a row or role there is not.
    pub fn value(&self, row: usize, role: &str) -> Option<Json> {
        let row = self.rows.get(row)?;
        let entity = &row.entity;
        let status = text(entity, "status");
        let running = live(status);
        let agent = row.kind == "subagent";
        let zone = self.clock.zone;
        Some(match role {
            "agentId" => Json::from(row.id.as_str()),
            "kind" => Json::from(row.kind),
            "title" => {
                if !agent {
                    return Some(Json::from(text(entity, "input").trim()));
                }
                let title = text(entity, "title").trim();
                if !title.is_empty() {
                    return Some(Json::from(title));
                }
                let prompt = text(entity, "prompt").trim();
                let first = prompt.split('\n').next().unwrap_or("");
                Json::from(if first.is_empty() { "Subagent" } else { first })
            }
            "status" => Json::from(status),
            "statusLabel" => Json::from(status_label(status)),
            "running" => Json::Bool(running),
            "elapsed" => {
                let Some(started) = time::time_of(entity.get("startedAt"), zone) else {
                    return Some(Json::from(""));
                };
                let ended = if running {
                    Some(self.clock.now())
                } else {
                    time::time_of(entity.get("completedAt"), zone)
                }
                .or_else(|| time::time_of(entity.get("updatedAt"), zone));
                Json::from(ended.map_or_else(String::new, |ended| {
                    format_elapsed((ended - started).num_seconds())
                }))
            }
            "detail" if agent => Json::from(subagent_detail(
                !running,
                text(entity, "progress"),
                text(entity, "result"),
            )),
            "detail" => Json::from(""),
            "modelName" => Json::from(text(entity, "model")),
            "childThreadKey" => {
                let child = text(entity, "childThreadId");
                Json::from(if agent && !child.is_empty() {
                    format!("{}:{child}", self.environment)
                } else {
                    String::new()
                })
            }
            "section" => Json::from(if running { "active" } else { "finished" }),
            "ended" => Json::from(self.ended(entity, status, running, agent)),
            _ => return None,
        })
    }

    /// When a settled subagent ended, with its status: "Completed at 9:41
    /// AM", "Failed yesterday at 9:41 AM"; empty while it works.
    fn ended(&self, entity: &Obj, status: &str, running: bool, agent: bool) -> String {
        let Some(format) = self.timestamp_format.as_deref() else {
            return String::new();
        };
        if running || !agent {
            return String::new();
        }
        let ended = end_of(entity, &self.clock);
        let at = time::stamp(ended, &self.clock, format);
        let Some(ended) = ended.filter(|_| !at.is_empty()) else {
            return String::new();
        };
        if status == "idle" {
            return format!("Idle since {at} · resumable");
        }
        // "9:41 AM" today reads "at 9:41 AM"; "yesterday at ..." and "9/20
        // ..." read as they are.
        let zone = self.clock.zone;
        let today = zone.local(ended).date() == zone.local(self.clock.now()).date();
        let when = if today { format!("at {at}") } else { at };
        format!("{} {when}", status_label(status))
    }

    pub fn take_notes(&mut self) -> Vec<Note> {
        std::mem::take(&mut self.notes)
    }
}

impl RowSource for Agents {
    fn roles(&self) -> &'static [&'static str] {
        ROLES
    }

    fn row_count(&self) -> usize {
        self.rows.len()
    }

    fn row_key(&self, row: usize) -> RowKey {
        self.rows.get(row).map_or(row as RowKey, |r| r.key)
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
    rows: Rc<ListRows<Agents>>,
    /// The TimelineModel followed, and its connections.
    timeline: Cell<Option<ObjectId>>,
    connections: RefCell<Vec<ConnectionId>>,
    tick: Cell<Option<ObjectId>>,
    day: Cell<Option<ObjectId>>,
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Agents")
            .field("rows", &self.rows)
            .finish_non_exhaustive()
    }
}

/// The Agents tab's rows: `RightPanel.agents`.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "AgentsModel", uncreatable)]
pub struct AgentsModel {
    #[qml(readonly, notify)]
    count: i32,
    /// Subagents listed (commands aside).
    #[qml(readonly, notify)]
    agent_count: i32,
    #[qml(skip)]
    inner: Rc<Inner>,
}

fn inner_of(engine: &Engine, obj: ObjectId) -> Option<Rc<Inner>> {
    engine.with::<AgentsModel, _>(obj, |m| m.inner.clone()).ok()
}

impl AgentsModel {
    /// An empty tab owned by `owner`, reading times on `clock`.
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        clock: Clock,
    ) -> Result<ObjectId, EngineError> {
        let rows = ListRows::new(Agents::new(clock));
        let model = AgentsModel {
            count: 0,
            agent_count: 0,
            inner: Rc::new(Inner {
                rows: rows.clone(),
                timeline: Cell::new(None),
                connections: RefCell::default(),
                tick: Cell::new(None),
                day: Cell::new(None),
            }),
        };
        let obj = engine.create_native(model, owner)?;
        rows.attach(engine, obj)?;
        Ok(obj)
    }

    /// The thread shown (its environment names the child threads) and its
    /// TimelineModel, which may come later than the thread.
    pub fn set_thread(
        engine: &Engine,
        obj: ObjectId,
        environment_id: &str,
        timeline: Option<ObjectId>,
    ) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        let same_environment = inner.rows.read(|a| a.environment == environment_id);
        if same_environment && inner.timeline.get() == timeline {
            return;
        }
        for connection in inner.connections.take() {
            engine.disconnect(connection);
        }
        inner.timeline.set(timeline);
        if let Some(timeline) = timeline {
            let mut connections = Vec::new();
            for (signal, then) in [
                ("agentsChanged", AgentsModel::read as fn(&Engine, ObjectId)),
                // The Settings time format or the locale changed: the end
                // times read anew.
                ("timesChanged", AgentsModel::times_changed),
            ] {
                let connected = engine
                    .signal_index(timeline, signal)
                    .and_then(|s| engine.connect_to(timeline, s, obj, move |e, _| then(e, obj)));
                match connected {
                    Ok(id) => connections.push(id),
                    Err(e) => warn(engine, &e),
                }
            }
            inner.connections.replace(connections);
        }
        AgentsModel::update(engine, obj, |a| a.set_environment(environment_id));
        AgentsModel::read(engine, obj);
    }

    /// Whether the Agents tab shows.
    pub fn set_active(engine: &Engine, obj: ObjectId, active: bool) {
        AgentsModel::update(engine, obj, |a| a.set_active(active));
    }

    /// One second passing, as the model's own timer says it.
    pub fn tick(engine: &Engine, obj: ObjectId) {
        AgentsModel::update(engine, obj, Agents::tick);
    }

    /// The end times read anew, as the model's own midnight timer says it.
    pub fn redraw_ended(engine: &Engine, obj: ObjectId) {
        AgentsModel::update(engine, obj, Agents::redraw_ended);
    }

    /// Reads the followed timeline again.
    fn read(engine: &Engine, obj: ObjectId) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        let clock = inner.rows.read(|a| a.clock.clone());
        // Read out first: the timeline is not borrowed while views hear of
        // the rows.
        let wanted = inner.timeline.get().and_then(|timeline| {
            TimelineModel::read(engine, timeline, |t| {
                (wanted_of(t, &clock), t.timestamp_format().to_owned())
            })
        });
        AgentsModel::update(engine, obj, |a| a.read(wanted));
    }

    fn times_changed(engine: &Engine, obj: ObjectId) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        let format = inner.timeline.get().and_then(|timeline| {
            TimelineModel::read(engine, timeline, |t| t.timestamp_format().to_owned())
        });
        AgentsModel::update(engine, obj, |a| match format {
            Some(format) => a.set_timestamp_format(&format),
            None => a.redraw_ended(),
        });
    }

    /// Runs `f` on the core of `obj`, then tells the views, the properties
    /// and the timers what it changed. None when `obj` is not a live
    /// AgentsModel.
    pub fn update<R>(
        engine: &Engine,
        obj: ObjectId,
        f: impl FnOnce(&mut Agents) -> R,
    ) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let result = inner.rows.update(engine, f);
        loop {
            let notes = inner.rows.update(engine, Agents::take_notes);
            if notes.is_empty() {
                break;
            }
            for note in notes {
                tell(engine, obj, &inner, note);
            }
        }
        Some(result)
    }

    /// Reads the core of `obj`. `f` must not call back into it.
    pub fn read_core<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&Agents) -> R) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        Some(inner.rows.read(f))
    }
}

fn warn(engine: &Engine, e: &EngineError) {
    engine.log(
        ljos::prelude::LogLevel::Warning,
        "AgentsModel",
        e.to_string(),
    );
}

/// A timer owned by the model: `then` after `interval` ms, again and again
/// when `repeat`.
fn timer(
    engine: &Engine,
    obj: ObjectId,
    interval: i32,
    repeat: bool,
    then: fn(&Engine, ObjectId),
) -> Option<ObjectId> {
    let native = ljos::prelude::Timer {
        interval,
        repeat,
        running: true,
        ..ljos::prelude::Timer::default()
    };
    let made = engine.create_native(native, Some(obj)).and_then(|timer| {
        engine.connect_by_name(timer, "triggered", move |engine, _| then(engine, obj))?;
        engine.complete(timer)?;
        Ok(timer)
    });
    made.map_err(|e| warn(engine, &e)).ok()
}

/// Stops a timer at once (its destruction waits for the deferred deletes).
fn stop(engine: &Engine, timer: ObjectId) {
    let _ = engine.write_by_name(timer, "running", Value::Bool(false));
    engine.destroy(timer);
}

fn tell(engine: &Engine, obj: ObjectId, inner: &Inner, note: Note) {
    match note {
        Note::Count => {
            let (count, agents) = inner.rows.read(|a| (a.count(), a.agent_count()));
            let result = engine
                .set_internal(obj, AgentsModel::COUNT, int(count))
                .and_then(|()| engine.set_internal(obj, AgentsModel::AGENT_COUNT, int(agents)));
            if let Err(e) = result {
                warn(engine, &e);
            }
        }
        Note::Ticking(on) => {
            if let Some(old) = inner.tick.take() {
                stop(engine, old);
            }
            if on {
                inner
                    .tick
                    .set(timer(engine, obj, TICK_MS, true, AgentsModel::tick));
            }
        }
        Note::Day(wait) => {
            if let Some(old) = inner.day.take() {
                stop(engine, old);
            }
            if let Some(wait) = wait {
                let wait = i32::try_from(wait).unwrap_or(i32::MAX);
                inner
                    .day
                    .set(timer(engine, obj, wait, false, AgentsModel::day_turned));
            }
        }
    }
}

impl AgentsModel {
    fn day_turned(engine: &Engine, obj: ObjectId) {
        AgentsModel::update(engine, obj, Agents::day_turned);
    }
}

#[qml_impl]
impl AgentsModel {
    /// The row of `id`, or -1.
    #[qml(invokable)]
    fn index_of(cx: &Cx, id: Atom) -> i32 {
        AgentsModel::read_core(cx.engine, cx.this, |a| a.index_of(&id))
            .flatten()
            .map_or(-1, int)
    }
}
