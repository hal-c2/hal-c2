//! The MC's `stream` shape for a thread, faked as entity rows steps change,
//! and the ThreadStore's timeline showing it: desktop-qt's Stream.h and the
//! extension of TimelineSteps.cpp that serves it. Shared by the steps files
//! that drive a thread.

use std::collections::{BTreeMap, HashMap, HashSet};

use chrono::{DateTime, Duration, Utc};
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::threads;
use hal_c2_shell::thread_view::timeline::{Role, Timeline};
use hal_c2_shell::thread_view::timeline_model::TimelineModel;
use serde_json::{Map, Value, json};

use crate::fake_mc::FakeMc;
use crate::harness::{Failure, Outcome, Steps, show, text};
use crate::world::World;

pub const PROJECT: &str = "shop";
pub const THREAD: &str = "thread-1";
pub const PEER: &str = "mc-b";
pub const PEER_ENVIRONMENT: &str = "env-b";
pub const PEER_THREAD: &str = "thread-remote";

pub type Entities = BTreeMap<String, Value>;

/// What one follower of a stream holds, and so what it is sent
/// (lib/hal_c2/streams/view.ex): the entity `kinds` its `sub` named, and
/// its window, whose `floor` is the ordinal of its first run (null: it
/// reaches the start of the thread).
#[derive(Clone, Default)]
pub struct View {
    pub kinds: Map<String, Value>,
    pub windowed: bool,
    pub floor: Value,
}

pub struct Change {
    pub seq: i64,
    pub kind: String,
    pub id: String,
    pub patch: Value,
}

/// Every `sub` to a stream as it was answered: its frame, and how many
/// frames had been sent to followers before it.
pub struct Asked {
    pub thread: String,
    pub sub: Value,
    pub sent_before: usize,
    /// The changes made to the thread while nobody followed it, until then.
    pub lacked: i64,
}

/// Every stream the MC serves: the entities of each thread, by
/// "kind\nid", and the log of the changes that made them, which a
/// follower's offset counts. A change made while nobody follows the thread
/// (the connection is down) is in the log all the same, so a follower that
/// resumes is sent it.
pub struct FakeStreams {
    pub threads: HashMap<String, Entities>,
    pub log: HashMap<String, Vec<Change>>,
    /// Names the MC's log: an offset only resumes with the handle it came with.
    pub handle: String,
    pub views: HashMap<i64, View>,
    pub asked: Vec<Asked>,
    /// Changes made to each thread since anyone last followed it.
    pub unfollowed: HashMap<String, i64>,
    /// Every frame sent to a follower, in order.
    pub sent: Vec<Value>,
    /// A catch-up is sent in two parts, and the connection drops after the
    /// first, once.
    pub cut_catch_up: bool,
    /// While set, a `sub` to a stream waits for its answer in `waiting`:
    /// the thread loads slowly.
    pub slow: bool,
    pub waiting: Vec<(i64, Value, Value)>,
    /// Environments that are down: a stream on one is refused.
    pub offline: HashSet<String>,
    /// The thread the steps write to, and its environment.
    pub thread: String,
    pub environment: String,
    pub ordinal: i64,
    pub seq: i64,
    pub run: String,
    pub run_started: Option<DateTime<Utc>>,
    /// The files the current turn changed, for the checkpoint it leaves.
    pub changed_files: Vec<String>,
}

impl Default for FakeStreams {
    fn default() -> FakeStreams {
        FakeStreams {
            threads: HashMap::new(),
            log: HashMap::new(),
            handle: "log-1.1".into(),
            views: HashMap::new(),
            asked: Vec::new(),
            unfollowed: HashMap::new(),
            sent: Vec::new(),
            cut_catch_up: false,
            slow: false,
            waiting: Vec::new(),
            offline: HashSet::new(),
            thread: String::new(),
            environment: String::new(),
            ordinal: 0,
            seq: 0,
            run: String::new(),
            run_started: None,
            changed_files: Vec::new(),
        }
    }
}

pub fn iso(time: DateTime<Utc>) -> String {
    time.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

pub fn now() -> DateTime<Utc> {
    DateTime::parse_from_rfc3339("2026-09-23T10:00:00Z")
        .expect("the scenarios' time")
        .with_timezone(&Utc)
}

fn int(value: &Value) -> i64 {
    value
        .as_i64()
        .or_else(|| value.as_f64().map(|f| f as i64))
        .unwrap_or(0)
}

/// Whether the follower holds this entity of `entities` (a thread's).
pub fn holds(view: &View, entities: &Entities, kind: &str, entity: &Value) -> bool {
    if !view.kinds.is_empty() {
        let Some(filter) = view.kinds.get(kind) else {
            return false;
        };
        if let Some(filter) = filter.as_object()
            && filter
                .iter()
                .any(|(k, v)| entity.get(k).unwrap_or(&Value::Null) != v)
        {
            return false;
        }
    }
    if !view.windowed || !matches!(kind, "turn-item" | "message" | "node") {
        return true;
    }
    let Some(run) = entities.get(&format!("run\n{}", text(&entity["runId"]))) else {
        return true;
    };
    if run["status"] == "rolled_back" {
        return false;
    }
    view.floor.is_null() || int(&run["ordinal"]) >= int(&view.floor)
}

/// The runs before `before` (null: the newest) that together hold at least
/// `items` turn items, and the floor of a window once it holds them too:
/// null when no run is left before them (HalC2.Streams.View.take_runs).
pub fn take_runs(entities: &Entities, before: &Value, items: i64) -> (HashSet<String>, Value) {
    let mut counts: HashMap<String, i64> = HashMap::new();
    let mut runs: Vec<(i64, String)> = Vec::new();
    for (key, entity) in entities {
        if key.starts_with("turn-item\n") {
            *counts.entry(text(&entity["runId"])).or_default() += 1;
        }
        if !key.starts_with("run\n") || entity["status"] == "rolled_back" {
            continue;
        }
        let ordinal = int(&entity["ordinal"]);
        if before.is_null() || ordinal < int(before) {
            runs.push((ordinal, key[4..].to_owned()));
        }
    }
    runs.sort_by(|a, b| b.cmp(a));
    let mut taken = HashSet::new();
    let mut count = 0;
    for (i, (_, run)) in runs.iter().enumerate() {
        taken.insert(run.clone());
        count += counts.get(run).copied().unwrap_or(0);
        if count >= items {
            let floor = runs.get(i + 1).map_or(Value::Null, |_| json!(runs[i].0));
            return (taken, floor);
        }
    }
    (taken, Value::Null)
}

/// A frame for a follower of a stream; false when no client is there.
pub fn deliver(mc: &mut FakeMc, frame: Value) -> bool {
    if !mc.connected() {
        return false;
    }
    mc.send(&frame);
    mc.part::<FakeStreams>().sent.push(frame);
    true
}

/// The frames of type `t` sent to followers since the first `from` of them.
pub fn sent_since(world: &mut World, from: usize, t: &str) -> Vec<Value> {
    let sent = &world.mc.part::<FakeStreams>().sent;
    sent.iter()
        .skip(from)
        .filter(|f| f["t"] == t)
        .cloned()
        .collect()
}

/// What the MC answered the `sub` with: the frames of type `t` it sent that
/// subscription up to its `live`.
pub fn answer_to(world: &mut World, asked: usize, t: &str) -> Vec<Value> {
    let fake = world.mc.part::<FakeStreams>();
    let Some(asked) = fake.asked.get(asked) else {
        return Vec::new();
    };
    let id = asked.sub["id"].clone();
    let mut frames = Vec::new();
    for frame in fake.sent.iter().skip(asked.sent_before) {
        if frame["id"] != id {
            continue;
        }
        if frame["t"] == "live" {
            break;
        }
        if frame["t"] == t {
            frames.push(frame.clone());
        }
    }
    frames
}

pub fn followers(mc: &FakeMc, thread: &str) -> Vec<i64> {
    mc.subscribers("stream")
        .into_iter()
        .filter(|id| text(&mc.shape_of(*id)["stream"]) == thread)
        .collect()
}

/// One change to the current thread, as the MC's `events` frame carries it
/// ({"s": set, "a": append, "u": unset, "d": delete}). `quiet` changes only
/// the MC's copy, as if the frame were lost.
pub fn change_quietly(
    world: &mut World,
    kind: &str,
    id: &str,
    patch: Value,
    quiet: bool,
) -> Outcome {
    let connected = world.mc.connected();
    let following = {
        let thread = world.mc.part::<FakeStreams>().thread.clone();
        if quiet || !connected {
            Vec::new()
        } else {
            followers(&world.mc, &thread)
        }
    };
    let fake = world.mc.part::<FakeStreams>();
    let thread = fake.thread.clone();
    let entity = fake
        .threads
        .entry(thread.clone())
        .or_default()
        .entry(format!("{kind}\n{id}"))
        .or_insert_with(|| json!({}));
    if let Some(set) = patch["s"].as_object() {
        for (k, v) in set {
            entity[k] = v.clone();
        }
    }
    if let Some(append) = patch["a"].as_object() {
        for (k, v) in append {
            entity[k] = json!(format!("{}{}", text(&entity[k]), text(v)));
        }
    }
    let entity = entity.clone();
    fake.seq += 1;
    let seq = fake.seq;
    fake.log.entry(thread.clone()).or_default().push(Change {
        seq,
        kind: kind.to_owned(),
        id: id.to_owned(),
        patch: patch.clone(),
    });
    if following.is_empty() {
        *fake.unfollowed.entry(thread.clone()).or_default() += 1;
    }
    if quiet {
        return Ok(());
    }
    for follower in following {
        let fake = world.mc.part::<FakeStreams>();
        let view = fake.views.get(&follower).cloned().unwrap_or_default();
        let entities = fake.threads.get(&thread).cloned().unwrap_or_default();
        // A follower is only sent changes to what it holds.
        if !holds(&view, &entities, kind, &entity) {
            continue;
        }
        deliver(
            &mut world.mc,
            json!({"t": "events", "id": follower, "offset": seq,
                   "events": [[seq, kind, id, patch, iso(now())]]}),
        );
    }
    world.sync()
}

pub fn change(world: &mut World, kind: &str, id: &str, patch: Value) -> Outcome {
    change_quietly(world, kind, id, patch, false)
}

pub fn set(world: &mut World, kind: &str, id: &str, fields: Value) -> Outcome {
    change(world, kind, id, json!({"s": fields}))
}

/// A new run of the current thread, started `since` seconds ago (not
/// started when negative), with the user message that asked for it.
pub fn start_run(world: &mut World, since: i64, status: &str) -> Outcome<String> {
    let fake = world.mc.part::<FakeStreams>();
    let run = format!("run-{}", fake.ordinal + 1);
    fake.run = run.clone();
    fake.run_started = (since >= 0).then(|| now() - Duration::seconds(since));
    fake.ordinal += 1;
    let requested = iso(now() - Duration::seconds(since.max(0)));
    let mut fields =
        json!({"id": run, "ordinal": fake.ordinal, "status": status, "requestedAt": requested});
    if let Some(started) = fake.run_started {
        fields["startedAt"] = json!(iso(started));
    }
    set(world, "run", &run, fields)?;
    let ordinal = {
        let fake = world.mc.part::<FakeStreams>();
        fake.ordinal += 1;
        fake.ordinal
    };
    let message = format!("message:{run}");
    set(
        world,
        "turn-item",
        &message,
        json!({"id": message, "type": "user_message", "runId": run, "ordinal": ordinal,
               "status": "completed", "text": "Add a tax line to the cart", "updatedAt": requested}),
    )?;
    Ok(run)
}

/// A running run started now.
pub fn start_running(world: &mut World) -> Outcome<String> {
    start_run(world, 0, "running")
}

/// A turn item of the current run; `fields` adds to and overrides the
/// defaults.
pub fn add_item(world: &mut World, kind: &str, fields: Value) -> Outcome<String> {
    let fake = world.mc.part::<FakeStreams>();
    fake.ordinal += 1;
    let id = format!("{kind}:{}", fake.ordinal);
    let mut item = json!({"id": id, "type": kind, "runId": fake.run, "ordinal": fake.ordinal,
                          "status": "completed", "updatedAt": iso(now())});
    if let Some(fields) = fields.as_object() {
        for (k, v) in fields {
            item[k] = v.clone();
        }
    }
    let id = text(&item["id"]);
    set(world, "turn-item", &id, item)?;
    Ok(id)
}

pub fn add_command(world: &mut World, n: i64, status: &str) -> Outcome<String> {
    add_item(
        world,
        "command_execution",
        json!({"input": format!("bun test cart-{n}"), "status": status, "exitCode": 0}),
    )
}

pub fn settle_run(world: &mut World, status: &str, after: i64) -> Outcome {
    let fake = world.mc.part::<FakeStreams>();
    let mut fields = json!({"status": status});
    if let Some(started) = fake.run_started {
        fields["completedAt"] = json!(iso(started + Duration::seconds(after)));
    }
    let run = fake.run.clone();
    set(world, "run", &run, fields)
}

/// `runs` settled turns of the current thread, each a question, `calls`
/// tool calls and "Answer <n>", as they were before anyone followed it.
pub fn seed_turns(world: &mut World, runs: i64, calls: i64) -> Outcome {
    fn put(world: &mut World, kind: &str, id: &str, mut fields: Value) -> Outcome {
        fields["id"] = json!(id);
        change_quietly(world, kind, id, json!({"s": fields}), true)
    }
    fn next(world: &mut World) -> i64 {
        let fake = world.mc.part::<FakeStreams>();
        fake.ordinal += 1;
        fake.ordinal
    }
    for n in 1..=runs {
        let started = now() - Duration::seconds(3600 - n * 60);
        let run = format!("run-{}", world.mc.part::<FakeStreams>().ordinal + 1);
        let ordinal = next(world);
        put(
            world,
            "run",
            &run,
            json!({"ordinal": ordinal, "status": "completed", "requestedAt": iso(started),
                   "startedAt": iso(started), "completedAt": iso(started + Duration::seconds(30))}),
        )?;
        let item = |world: &mut World, kind: &str, more: Value| -> Outcome {
            let ordinal = next(world);
            let mut fields = json!({"type": kind, "runId": run, "status": "completed",
                                    "updatedAt": iso(started), "ordinal": ordinal});
            if let Some(more) = more.as_object() {
                for (k, v) in more {
                    fields[k] = v.clone();
                }
            }
            put(world, "turn-item", &format!("{kind}:{ordinal}"), fields)
        };
        item(
            world,
            "user_message",
            json!({"text": format!("Question {n}")}),
        )?;
        for call in 1..=calls {
            item(
                world,
                "command_execution",
                json!({"input": format!("bun test {call}"), "exitCode": 0}),
            )?;
        }
        item(
            world,
            "assistant_message",
            json!({"text": format!("Answer {n}")}),
        )?;
        world.mc.part::<FakeStreams>().run = run;
    }
    Ok(())
}

/// The shown thread's timeline object.
pub fn timeline_object(world: &World) -> Outcome<ljos::ObjectId> {
    threads::timeline(world.engine()).ok_or_else(|| Failure("no thread is open".into()))
}

/// Reads the shown thread's timeline.
pub fn read<R>(world: &World, f: impl FnOnce(&Timeline) -> R) -> Outcome<R> {
    let obj = timeline_object(world)?;
    TimelineModel::read(world.engine(), obj, f)
        .ok_or_else(|| Failure("the timeline is busy".into()))
}

pub fn row_count(world: &World) -> Outcome<usize> {
    read(world, Timeline::row_count)
}

pub fn status(world: &World) -> String {
    read(world, |t| t.status().to_owned()).unwrap_or_default()
}

/// A row's role, by its QML name; null where the row has none.
pub fn role(world: &World, row: usize, name: &str) -> Value {
    let Some(role) = Role::from_name(name) else {
        return Value::Null;
    };
    read(world, |t| t.data(row, role))
        .ok()
        .flatten()
        .unwrap_or(Value::Null)
}

pub fn describe_timeline(timeline: &Timeline) -> String {
    let rows: Vec<String> = (0..timeline.row_count())
        .map(|row| {
            let shown: Map<String, Value> = Role::ALL
                .into_iter()
                .filter_map(|role| {
                    let value = timeline.data(row, role)?;
                    let empty = matches!(&value, Value::Null | Value::Bool(false))
                        || value == json!(0)
                        || value.as_str().is_some_and(str::is_empty);
                    (!empty).then(|| (role.name().to_owned(), value))
                })
                .collect();
            show(&Value::Object(shown))
        })
        .collect();
    format!(
        "status {}, rows: {}",
        timeline.status(),
        if rows.is_empty() {
            "(none)".to_owned()
        } else {
            rows.join("; ")
        }
    )
}

pub fn describe(world: &World) -> String {
    read(world, describe_timeline).unwrap_or_else(|f| f.0)
}

/// Opens `thread_key`'s route, and waits for its stream.
pub fn look(world: &mut World, thread_key: &str, live: bool) -> Outcome {
    let route = Route::Thread(thread_key.to_owned());
    world.with::<Navigation, _>(|n, engine| n.open(engine, route))?;
    world.pump()?;
    let key = thread_key.to_owned();
    world.wait_for("the thread to open", move |w| {
        threads::active(w.engine()) == key && threads::timeline(w.engine()).is_some()
    })?;
    if !live {
        return Ok(());
    }
    world.wait_for_with(
        |w| status(w) == "live",
        |w| format!("the thread to follow its MC; {}", describe(w)),
    )
}

/// What the client's cache holds of the thread `key`.
pub fn kept_copy(world: &World, key: &str) -> hal_c2_shell::cache::Thread {
    let Some(cache) = hal_c2_shell::store::cache(world.engine()) else {
        return hal_c2_shell::cache::Thread::default();
    };
    let copy = std::rc::Rc::new(std::cell::RefCell::new(
        hal_c2_shell::cache::Thread::default(),
    ));
    let into = copy.clone();
    cache.load_thread(key, move |thread| *into.borrow_mut() = thread);
    cache.drain();
    copy.take()
}

/// The thread "thread-1" of `project`, opened and followed.
pub fn look_at_thread(world: &mut World, project: &str) -> Outcome {
    let row = json!({"id": THREAD, "title": "Tax line", "projectId": project,
                     "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
    world.mc.threads.insert(THREAD.into(), row.clone());
    world.mc.send_row(THREAD, &row);
    world.sync()?;
    let environment = world.mc.environment_id.clone();
    let fake = world.mc.part::<FakeStreams>();
    fake.thread = THREAD.into();
    fake.environment = environment.clone();
    look(world, &format!("{environment}:{THREAD}"), true)
}

/// Answers a `sub` to a thread's stream as the MC does
/// (lib/hal_c2/streams/server.ex): the events since its offset when it
/// resumes the MC's log, else a snapshot of what its view holds; then
/// `live`.
pub fn answer(mc: &mut FakeMc, id: i64, shape: &Value, sub: &Value) {
    let thread = text(&shape["stream"]);
    let fake = mc.part::<FakeStreams>();
    let lacked = fake.unfollowed.remove(&thread).unwrap_or(0);
    let sent_before = fake.sent.len();
    fake.asked.push(Asked {
        thread: thread.clone(),
        sub: sub.clone(),
        sent_before,
        lacked,
    });
    let entities = fake.threads.get(&thread).cloned().unwrap_or_default();
    let window = &sub["window"];
    let opens = window["items"].is_number();
    let mut view = View {
        kinds: shape["kinds"].as_object().cloned().unwrap_or_default(),
        ..View::default()
    };
    if opens {
        view.windowed = true;
        view.floor = take_runs(&entities, &Value::Null, int(&window["items"])).1;
    } else if window.get("floor").is_some() {
        view.windowed = true;
        view.floor = window["floor"].clone();
    }
    fake.views.insert(id, view.clone());
    let offset = &sub["offset"];
    let resumes = !opens
        && offset.is_number()
        && int(offset) <= fake.seq
        && sub.get("handle").is_none_or(|h| *h == json!(fake.handle));
    let (seq, handle) = (fake.seq, fake.handle.clone());
    if resumes {
        let events: Vec<Value> = fake
            .log
            .get(&thread)
            .into_iter()
            .flatten()
            .filter(|change| change.seq > int(offset))
            .filter(|change| {
                let entity = entities
                    .get(&format!("{}\n{}", change.kind, change.id))
                    .cloned()
                    .unwrap_or(Value::Null);
                holds(&view, &entities, &change.kind, &entity)
            })
            .map(|c| json!([c.seq, c.kind, c.id, c.patch, iso(now())]))
            .collect();
        if std::mem::take(&mut fake.cut_catch_up) && events.len() > 1 {
            // The first part of two carries the offset the client is at; the
            // connection goes before the second.
            deliver(
                mc,
                json!({"t": "events", "id": id, "offset": offset, "events": [events[0]]}),
            );
            mc.drop_connection();
            return;
        }
        if let Some(last) = events.last() {
            let last = last[0].clone();
            deliver(
                mc,
                json!({"t": "events", "id": id, "offset": last, "events": events}),
            );
        }
    } else {
        let rows: Vec<Value> = entities
            .iter()
            .filter_map(|(key, entity)| {
                let (kind, entity_id) = key.split_once('\n')?;
                holds(&view, &entities, kind, entity).then(|| json!([kind, entity_id, entity]))
            })
            .collect();
        let mut snapshot = json!({"t": "snapshot", "id": id, "offset": seq, "at": iso(now()),
                                  "part": 0, "rows": rows, "done": true, "handle": handle});
        if view.windowed {
            snapshot["floor"] = view.floor.clone();
        }
        deliver(mc, snapshot);
    }
    deliver(
        mc,
        json!({"t": "live", "id": id, "offset": seq, "handle": handle}),
    );
}

/// Answers `more`: the runs before the follower's window, as a page that
/// moves its floor down. Held while the scenario holds `pages`.
fn send_page(mc: &mut FakeMc, id: i64, items: i64) {
    let thread = text(&mc.shape_of(id)["stream"]);
    let fake = mc.part::<FakeStreams>();
    let Some(view) = fake.views.get(&id).cloned() else {
        return;
    };
    let entities = fake.threads.get(&thread).cloned().unwrap_or_default();
    let mut rows = Vec::new();
    let mut floor = Value::Null;
    if view.windowed && !view.floor.is_null() {
        let (runs, lower) = take_runs(&entities, &view.floor, items);
        floor = lower;
        let page = View {
            kinds: view.kinds.clone(),
            ..View::default()
        };
        for (key, entity) in &entities {
            let Some((kind, entity_id)) = key.split_once('\n') else {
                continue;
            };
            if !matches!(kind, "turn-item" | "message" | "node") {
                continue;
            }
            if runs.contains(&text(&entity["runId"])) && holds(&page, &entities, kind, entity) {
                rows.push(json!([kind, entity_id, entity]));
            }
        }
        if let Some(view) = fake.views.get_mut(&id) {
            view.floor = floor.clone();
        }
    }
    let seq = fake.seq;
    deliver(
        mc,
        json!({"t": "page", "id": id, "offset": seq, "rows": rows, "floor": floor, "done": true}),
    );
}

fn extension(mc: &mut FakeMc) {
    mc.on_shape("stream", |mc, id, shape| {
        let target = text(&shape["environment"]);
        let sub = mc.subscriptions.last().cloned().unwrap_or(Value::Null);
        let fake = mc.part::<FakeStreams>();
        if fake.offline.contains(&target) {
            mc.send(&json!({"t": "error", "id": id, "reason": "unknown environment"}));
            mc.forget(id);
            return Ok(());
        }
        if fake.slow {
            fake.waiting.push((id, shape.clone(), sub));
            return Ok(());
        }
        answer(mc, id, shape, &sub);
        Ok(())
    });
    mc.on_frame("more", |mc, frame| {
        let id = int(&frame["id"]);
        let items = int(&frame["items"]);
        mc.part::<FakeStreams>().sent.push(frame.clone());
        if mc.holding("pages") {
            mc.defer(move |mc| send_page(mc, id, items));
        } else {
            send_page(mc, id, items);
        }
        Ok(())
    });
}

/// The slow thread loads: every `sub` held answers.
pub fn answer_waiting(world: &mut World) -> Outcome {
    let waiting = std::mem::take(&mut world.mc.part::<FakeStreams>().waiting);
    for (id, shape, sub) in waiting {
        answer(&mut world.mc, id, &shape, &sub);
    }
    world.sync()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);
}
