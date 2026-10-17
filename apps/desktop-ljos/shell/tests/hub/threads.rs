//! `Threads`: each open thread followed through the MC's `stream` shape
//! into its timeline, the left ones kept warm a while, their copies kept in
//! the client cache (ThreadStore.cpp, tst_SyncThreadRegression.cpp,
//! features/threads/timeline.feature).

use hal_c2_shell::Launch;
use hal_c2_shell::controllers::threads::{self, ThreadStore, ThreadsObject};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{McError, SubId};
use hal_c2_shell::thread_view::timeline::Timeline;
use hal_c2_shell::thread_view::timeline_model::TimelineModel;
use serde_json::json;

use crate::Hub;

/// A cluster of one MC, `a`, serving `env-1` with project `p1` and
/// `threads`, the connection up.
pub fn hub(threads: &[&str]) -> Hub {
    let hub = Hub::clustered();
    hub.mc.set_ready(&hub.engine, true);
    shell(&hub, threads, true);
    hub
}

/// The MC's `shell` frame: `threads` listed, `online` or not.
pub fn shell(hub: &Hub, threads: &[&str], online: bool) {
    let mut rows =
        vec![json!(["a", "p1", "project", {"id": "p1", "title": "P", "workspaceRoot": "/work/p"}])];
    for id in threads {
        rows.push(
            json!(["a", id, "thread", {"id": id, "projectId": "p1", "title": id.to_uppercase()}]),
        );
    }
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell", "mcs": [{"mc": "a", "online": online, "epoch": "e", "rev": 1,
            "environment": {"environmentId": "env-1", "label": "Here"}}], "rows": rows}),
    );
}

fn key(thread: &str) -> String {
    format!("env-1:{thread}")
}

fn open(hub: &Hub, thread: &str) {
    hub.dispatch("thread.open", json!({"key": key(thread)}));
}

/// The stream subscription of `thread`, if it is followed.
fn stream(hub: &Hub, thread: &str) -> Option<SubId> {
    hub.mc
        .subscriptions()
        .into_iter()
        .find(|(_, shape)| shape["type"] == "stream" && shape["stream"] == thread)
        .map(|(id, _)| id)
}

fn streams(hub: &Hub) -> Vec<String> {
    let mut followed: Vec<String> = hub
        .mc
        .subscriptions()
        .into_iter()
        .filter(|(_, shape)| shape["type"] == "stream")
        .map(|(_, shape)| shape["stream"].as_str().unwrap().to_owned())
        .collect();
    followed.sort();
    followed
}

fn read<R>(hub: &Hub, thread: &str, f: impl FnOnce(&Timeline) -> R) -> R {
    let model = threads::timeline_of(&hub.engine, &key(thread)).expect("the thread is open");
    TimelineModel::read(&hub.engine, model, f).expect("a timeline")
}

fn status(hub: &Hub, thread: &str) -> (String, String) {
    read(hub, thread, |t| {
        (t.status().to_owned(), t.problem().to_owned())
    })
}

fn plans(hub: &Hub, thread: &str) -> Vec<(String, i64)> {
    read(hub, thread, |t| {
        t.entities("plan")
            .iter()
            .map(|(id, plan)| (id.clone(), plan["n"].as_i64().unwrap_or(-1)))
            .collect()
    })
}

fn open_threads(hub: &Hub) -> Vec<String> {
    hub.with_controller::<ThreadStore, _>(|s, _| s.open_threads())
}

/// The MC sends `thread` whole, as of `offset` of log `handle`, then says
/// it is live.
fn snapshot(hub: &Hub, thread: &str, plans: &[(&str, i64)], offset: i64, floor: Option<i64>) {
    let id = stream(hub, thread).expect("the thread is followed");
    let rows: Vec<Json> = plans
        .iter()
        .map(|(plan, n)| json!(["plan", plan, {"id": plan, "n": n}]))
        .collect();
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "snapshot", "part": 0, "rows": rows, "done": true, "offset": offset,
            "handle": "log-1", "floor": floor}),
    );
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "live", "offset": offset, "handle": "log-1"}),
    );
}

fn active(hub: &Hub) -> String {
    let obj = hub.engine.singleton::<ThreadsObject>().unwrap();
    hub.engine
        .to_js_string(&hub.engine.read_by_name(obj, "activeThread"))
        .to_string()
}

#[test]
fn opening_a_thread_follows_its_stream_into_its_timeline() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    assert_eq!(active(&hub), "env-1:t1");
    assert_eq!(threads::active(&hub.engine), "env-1:t1");
    let (_, shape) = hub
        .mc
        .subscriptions()
        .into_iter()
        .find(|(_, shape)| shape["type"] == "stream")
        .expect("the stream is followed");
    assert_eq!(shape["environment"], "env-1");
    assert_eq!(shape["stream"], "t1");
    assert_eq!(shape["kinds"]["message"], json!({"role": "user"}));
    // Nothing held yet: the whole thread, from the window's start.
    let resume = hub.mc.resume(stream(&hub, "t1").unwrap()).unwrap();
    assert_eq!(resume["offset"], Json::Null);
    assert!(resume["window"]["items"].as_i64().unwrap() > 0);
    assert_eq!(status(&hub, "t1").0, "loading");
    assert!(threads::loading(&hub.engine));

    snapshot(&hub, "t1", &[("a", 1)], 3, None);
    assert_eq!(status(&hub, "t1").0, "live");
    assert!(!threads::loading(&hub.engine));
    assert_eq!(plans(&hub, "t1"), vec![("a".into(), 1)]);
    // A resubscription resumes where it stands.
    let resume = hub.mc.resume(stream(&hub, "t1").unwrap()).unwrap();
    assert_eq!(resume["offset"], 3);
    assert_eq!(resume["handle"], "log-1");
}

#[test]
fn a_thread_the_sidebar_does_not_list_yet_is_followed_once_it_does() {
    let hub = hub(&[]);
    open(&hub, "t1");
    assert_eq!(streams(&hub), Vec::<String>::new());
    assert_eq!(open_threads(&hub), vec![key("t1")]);
    shell(&hub, &["t1"], true);
    assert_eq!(streams(&hub), vec!["t1"]);
}

#[test]
fn an_ended_stream_is_unreachable_until_its_mc_is_back() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    snapshot(&hub, "t1", &[("a", 1)], 3, None);
    // Its MC is offline: the stream ends.
    shell(&hub, &["t1"], false);
    let id = stream(&hub, "t1").unwrap();
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "error", "reason": "The machine holding this thread is offline."}),
    );
    assert_eq!(
        status(&hub, "t1"),
        (
            "unreachable".into(),
            "The machine holding this thread is offline.".into()
        )
    );
    assert_eq!(stream(&hub, "t1"), None);
    // What was shown stays.
    assert_eq!(plans(&hub, "t1"), vec![("a".into(), 1)]);
    // Still offline: nothing to ask for.
    shell(&hub, &["t1"], false);
    assert_eq!(stream(&hub, "t1"), None);
    // Back: followed again from where it stood.
    shell(&hub, &["t1"], true);
    let id = stream(&hub, "t1").expect("followed again");
    assert_eq!(hub.mc.resume(id).unwrap()["offset"], 3);
}

#[test]
fn an_ended_stream_without_a_reason_says_the_mc_stopped() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    hub.mc.frame_to(
        &hub.engine,
        stream(&hub, "t1").unwrap(),
        json!({"t": "end"}),
    );
    assert_eq!(
        status(&hub, "t1"),
        (
            "unreachable".into(),
            "The MC stopped sending this thread.".into()
        )
    );
    // Its MC is online: the next change of the store asks again.
    shell(&hub, &["t1"], true);
    assert!(stream(&hub, "t1").is_some());
}

#[test]
fn retry_follows_an_unreachable_thread_again() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    snapshot(&hub, "t1", &[("a", 1)], 3, None);
    let first = stream(&hub, "t1").unwrap();
    hub.mc.frame_to(&hub.engine, first, json!({"t": "end"}));
    let obj = hub.engine.singleton::<ThreadsObject>().unwrap();
    hub.engine
        .invoke_by_name(obj, "reload", &[hub.engine.eval_js("'env-1:t1'").unwrap()])
        .unwrap();
    let again = stream(&hub, "t1").expect("followed again");
    assert_ne!(again, first);
    assert_eq!(status(&hub, "t1").0, "loading");
}

#[test]
fn a_dropped_connection_leaves_what_was_loaded_without_passing_for_live() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    snapshot(&hub, "t1", &[("a", 1)], 3, None);
    hub.mc.set_ready(&hub.engine, false);
    assert_eq!(
        status(&hub, "t1"),
        (
            "unreachable".into(),
            "The connection to its environment dropped.".into()
        )
    );
    assert_eq!(plans(&hub, "t1"), vec![("a".into(), 1)]);
    // The reconnect resends the subscription, from where it stood.
    hub.mc.set_ready(&hub.engine, true);
    let id = stream(&hub, "t1").unwrap();
    assert_eq!(hub.mc.resume(id).unwrap()["offset"], 3);
    hub.mc.frame_to(
        &hub.engine,
        id,
        json!({"t": "live", "offset": 3, "handle": "log-1"}),
    );
    assert_eq!(status(&hub, "t1").0, "live");
}

#[test]
fn three_threads_left_stay_followed_and_the_one_before_closes() {
    let hub = hub(&["t1", "t2", "t3", "t4", "t5"]);
    for thread in ["t1", "t2", "t3", "t4"] {
        open(&hub, thread);
    }
    assert_eq!(streams(&hub), vec!["t1", "t2", "t3", "t4"]);
    open(&hub, "t5");
    assert_eq!(streams(&hub), vec!["t2", "t3", "t4", "t5"]);
    assert_eq!(threads::timeline_of(&hub.engine, &key("t1")), None);
    // Going back to a warm one keeps its timeline.
    let warm = threads::timeline_of(&hub.engine, &key("t3"));
    open(&hub, "t3");
    assert_eq!(threads::timeline(&hub.engine), warm);
}

#[test]
fn a_thread_left_five_minutes_ago_closes() {
    let hub = hub(&["t1", "t2"]);
    open(&hub, "t1");
    hub.advance(60_000);
    open(&hub, "t2");
    hub.advance(299_000);
    assert_eq!(streams(&hub), vec!["t1", "t2"]);
    hub.advance(1_000);
    assert_eq!(streams(&hub), vec!["t2"]);
    // The active one never idles.
    hub.advance(600_000);
    assert_eq!(streams(&hub), vec!["t2"]);
}

#[test]
fn a_thread_the_mc_deletes_closes() {
    let hub = hub(&["t1", "t2"]);
    open(&hub, "t1");
    open(&hub, "t2");
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell.rows", "mc": "a", "epoch": "e", "rev": 2,
            "rows": [["t1", "thread", {"id": "t1", "deletedAt": "2026-10-08T10:00:00Z"}]]}),
    );
    assert_eq!(open_threads(&hub), vec![key("t2")]);
    assert_eq!(streams(&hub), vec!["t2"]);
}

#[test]
fn an_attachment_is_signed_by_the_mc_that_holds_it() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    snapshot(&hub, "t1", &[], 1, None);
    let model = threads::timeline(&hub.engine).unwrap();
    TimelineModel::update(&hub.engine, model, |t| t.load_attachment("img-1"));
    let index = signing(&hub).expect("asked to sign");
    let (environment, _, payload) = hub.mc.calls.borrow()[index].clone();
    assert_eq!(environment, "env-1");
    assert_eq!(
        payload,
        json!({"resource": {"_tag": "attachment", "attachmentId": "img-1", "disposition": "inline"}})
    );
    // Signed until long after the clock's now: asking again asks no more.
    hub.mc.reply(
        &hub.engine,
        index,
        Ok(json!({"relativeUrl": "/a/img-1?sig=x", "expiresAt": 4_102_444_800_000_i64})),
    );
    TimelineModel::update(&hub.engine, model, |t| t.load_attachment("img-1"));
    assert_eq!(signing(&hub), None);
    // A failure lets the next ask try again.
    TimelineModel::update(&hub.engine, model, |t| t.load_attachment("img-2"));
    hub.mc.reply(
        &hub.engine,
        signing(&hub).expect("asked to sign"),
        Err(McError::new("not found")),
    );
    TimelineModel::update(&hub.engine, model, |t| t.load_attachment("img-2"));
    assert!(signing(&hub).is_some());
}

/// The oldest unanswered signing of an attachment; the project favicons are
/// signed through the same call.
fn signing(hub: &Hub) -> Option<usize> {
    hub.mc.pending_where("assets.createUrl", |payload| {
        payload["resource"]["_tag"] == "attachment"
    })
}

#[test]
fn earlier_turns_are_asked_of_the_stream() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    snapshot(&hub, "t1", &[], 7, Some(2));
    let model = threads::timeline(&hub.engine).unwrap();
    TimelineModel::update(&hub.engine, model, Timeline::load_earlier);
    let id = stream(&hub, "t1").unwrap();
    let mores = hub.mc.mores.borrow().clone();
    assert_eq!(mores.len(), 1);
    assert_eq!(mores[0].0, id);
    assert!(mores[0].1 > 0);
}

#[test]
fn leaving_every_thread_shows_none() {
    let hub = hub(&["t1"]);
    open(&hub, "t1");
    assert!(threads::timeline(&hub.engine).is_some());
    hub.dispatch("settings.navigate", json!({"to": "/settings"}));
    assert_eq!(active(&hub), "");
    assert_eq!(threads::timeline(&hub.engine), None);
    // Still warm.
    assert_eq!(streams(&hub), vec!["t1"]);
}

/// A shell whose client cache is `dir`.
fn cached_hub(dir: &std::path::Path, threads: &[&str]) -> Hub {
    let hub = Hub::with(Launch {
        mc_origin: Some("http://127.0.0.1:1".into()),
        cache_dir: Some(dir.to_owned()),
        ..Launch::default()
    });
    hub.mc.set_ready(&hub.engine, true);
    shell(&hub, threads, true);
    hub
}

#[test]
fn a_thread_shows_its_cached_copy_and_resumes_from_it() {
    let dir = tempfile::tempdir().unwrap();
    {
        let hub = cached_hub(dir.path(), &["t1"]);
        open(&hub, "t1");
        threads::drain(&hub.engine);
        snapshot(&hub, "t1", &[("a", 1), ("b", 2)], 5, None);
        // Kept as it was left.
        hub.dispatch("settings.navigate", json!({"to": "/settings"}));
        hub.with_controller::<ThreadStore, _>(|s, e| s.close(e, &key("t1")));
        threads::drain(&hub.engine);
    }
    let hub = cached_hub(dir.path(), &["t1"]);
    open(&hub, "t1");
    // The copy loads first; the MC is asked once it is in.
    assert_eq!(stream(&hub, "t1"), None);
    threads::drain(&hub.engine);
    assert_eq!(plans(&hub, "t1"), vec![("a".into(), 1), ("b".into(), 2)]);
    let id = stream(&hub, "t1").expect("followed from the copy");
    let resume = hub.mc.resume(id).unwrap();
    assert_eq!(resume["offset"], 5);
    assert_eq!(resume["handle"], "log-1");
}

/// tst_SyncThreadRegression: a thread opened while its copy loads, and
/// deleted on the MC meanwhile, closes once the MC says so.
#[test]
fn a_thread_deleted_while_its_copy_loads_closes() {
    let dir = tempfile::tempdir().unwrap();
    let hub = cached_hub(dir.path(), &["t1"]);
    open(&hub, "t1");
    assert_eq!(open_threads(&hub), vec![key("t1")]);
    shell(&hub, &[], true);
    threads::drain(&hub.engine);
    assert_eq!(open_threads(&hub), Vec::<String>::new());
    assert_eq!(streams(&hub), Vec::<String>::new());
}

/// One opened before the sidebar listed it, listed while its copy loads and
/// deleted before that is in, closes too.
#[test]
fn a_thread_listed_and_deleted_while_its_copy_loads_closes() {
    let dir = tempfile::tempdir().unwrap();
    let hub = cached_hub(dir.path(), &[]);
    open(&hub, "t1");
    shell(&hub, &["t1"], true);
    shell(&hub, &[], true);
    threads::drain(&hub.engine);
    assert_eq!(open_threads(&hub), Vec::<String>::new());
}

// -- The model ----------------------------------------------------------------

use std::collections::{BTreeMap, BTreeSet, HashSet};

use proptest::prelude::*;

const THREADS: [&str; 5] = ["t1", "t2", "t3", "t4", "t5"];
const IDLE_MS: u64 = 300_000;

/// What the user, the MC and the connection do, in any order; the MC
/// answers a subscription or a `more` when the test says.
#[derive(Clone, Debug)]
enum Op {
    /// The user opens a thread, listed or not.
    Open(usize),
    /// The user goes to Settings.
    Leave,
    /// `Threads.close`.
    Close(usize),
    /// A plan of a thread changes (`Some`) or goes.
    Change(usize, u8, Option<u8>),
    /// The thread is deleted, or comes back.
    Delete(usize),
    Restore(usize),
    /// The MC answers the oldest subscription it has not answered, or the
    /// oldest `more`.
    Answer,
    AnswerMore,
    /// The active thread asks for its earlier turns.
    Earlier,
    /// The connection drops; comes back to the same run of the MC, or to a
    /// new one, whose log no offset resumes.
    Drop,
    ComeBack(bool),
    /// The cache answers what it was asked.
    Deliver,
    /// Time passes.
    Advance(u64),
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        4 => (0..THREADS.len()).prop_map(Op::Open),
        1 => Just(Op::Leave),
        1 => (0..THREADS.len()).prop_map(Op::Close),
        4 => (0..THREADS.len(), 0u8..2, proptest::option::weighted(0.75, 0u8..100))
            .prop_map(|(t, p, n)| Op::Change(t, p, n)),
        1 => (0..THREADS.len()).prop_map(Op::Delete),
        1 => (0..THREADS.len()).prop_map(Op::Restore),
        4 => Just(Op::Answer),
        1 => Just(Op::AnswerMore),
        1 => Just(Op::Earlier),
        1 => Just(Op::Drop),
        1 => any::<bool>().prop_map(Op::ComeBack),
        2 => Just(Op::Deliver),
        1 => prop_oneof![Just(60_000u64), Just(IDLE_MS), Just(1_000)].prop_map(Op::Advance),
    ]
}

type Plans = BTreeMap<String, i64>;

/// The MC: its threads and their plans, the log of the changes that made
/// them (`seq`, thread, plan, value), and the run its offsets count in.
#[derive(Default)]
struct Server {
    listed: BTreeSet<String>,
    plans: BTreeMap<String, Plans>,
    log: Vec<(i64, String, String, Option<i64>)>,
    seq: i64,
    handle: u32,
    up: bool,
}

impl Server {
    fn handle(&self) -> String {
        format!("log-{}", self.handle)
    }

    fn event((seq, _, plan, n): &(i64, String, String, Option<i64>)) -> Json {
        let patch = match n {
            Some(n) => json!({"s": {"id": plan, "n": n}}),
            None => json!({"d": true}),
        };
        json!([seq, "plan", plan, patch, "2026-10-08T10:00:00Z"])
    }
}

/// What the store should hold: ThreadStore's rules, written out.
#[derive(Default)]
struct Expected {
    /// The route's thread: the store opens a thread as the route changes.
    route: String,
    active: String,
    /// Most recently opened first.
    recent: Vec<String>,
    open: BTreeSet<String>,
    left_at: BTreeMap<String, u64>,
    /// The open threads the store has seen listed.
    seen_listed: BTreeSet<String>,
    /// What the store lists: the MC's word as last sent.
    listed: BTreeSet<String>,
    now: u64,
}

impl Expected {
    fn close(&mut self, thread: &str) {
        self.open.remove(thread);
        self.recent.retain(|t| t != thread);
        self.left_at.remove(thread);
        self.seen_listed.remove(thread);
        if self.active == thread {
            self.active.clear();
        }
    }

    fn evict_idle(&mut self) {
        let idle: Vec<String> = self
            .left_at
            .iter()
            .filter(|(_, at)| self.now - **at >= IDLE_MS)
            .map(|(t, _)| t.clone())
            .collect();
        for thread in idle {
            self.close(&thread);
        }
    }

    /// The route goes to `thread` (none when empty); a closed thread the
    /// route still shows stays closed.
    fn route_to(&mut self, thread: &str) {
        if self.route != thread {
            thread.clone_into(&mut self.route);
            self.open(thread);
        }
    }

    fn open(&mut self, thread: &str) {
        if self.active == thread {
            return;
        }
        if !self.active.is_empty() && self.open.contains(&self.active) {
            self.left_at.insert(self.active.clone(), self.now);
        }
        self.active.clear();
        self.evict_idle();
        thread.clone_into(&mut self.active);
        self.left_at.remove(thread);
        if thread.is_empty() {
            return;
        }
        self.recent.retain(|t| t != thread);
        self.recent.insert(0, thread.to_owned());
        if self.open.insert(thread.to_owned()) && self.listed.contains(thread) {
            self.seen_listed.insert(thread.to_owned());
        }
        while self.recent.len() > 4 {
            let last = self.recent.last().cloned().unwrap();
            self.close(&last);
        }
    }

    /// The store heard the MC's list.
    fn listed(&mut self, listed: &BTreeSet<String>) {
        self.listed = listed.clone();
        for thread in &self.open {
            if listed.contains(thread) {
                self.seen_listed.insert(thread.clone());
            }
        }
        let gone: Vec<String> = self
            .seen_listed
            .iter()
            .filter(|t| !listed.contains(*t))
            .cloned()
            .collect();
        for thread in gone {
            self.close(&thread);
        }
    }
}

struct World {
    hub: Hub,
    _dir: tempfile::TempDir,
    server: Server,
    expected: Expected,
    /// The subscriptions the MC has answered on this connection.
    answered: HashSet<SubId>,
    /// The `more`s not answered yet, as many as were recorded before.
    mores: usize,
}

impl World {
    fn new() -> World {
        let dir = tempfile::tempdir().unwrap();
        let hub = Hub::with(Launch {
            mc_origin: Some("http://127.0.0.1:1".into()),
            cache_dir: Some(dir.path().to_owned()),
            ..Launch::default()
        });
        hub.mc.set_ready(&hub.engine, true);
        let mut world = World {
            hub,
            _dir: dir,
            server: Server {
                listed: ["t1", "t2", "t3"].iter().map(|t| t.to_string()).collect(),
                handle: 1,
                up: true,
                ..Server::default()
            },
            expected: Expected::default(),
            answered: HashSet::new(),
            mores: 0,
        };
        world.send_shell();
        world
    }

    fn key(thread: &str) -> String {
        format!("env-1:{thread}")
    }

    fn send_shell(&mut self) {
        let threads: Vec<&str> = self.server.listed.iter().map(String::as_str).collect();
        shell(&self.hub, &threads, true);
        self.expected.listed(&self.server.listed.clone());
    }

    fn send_row(&mut self, thread: &str, gone: bool) {
        if !self.server.up {
            return;
        }
        let fields = if gone {
            json!({"id": thread, "deletedAt": "2026-10-08T10:00:00Z"})
        } else {
            json!({"id": thread, "projectId": "p1", "title": thread})
        };
        self.hub.mc.frame(
            &self.hub.engine,
            "shell",
            "",
            json!({"t": "shell.rows", "mc": "a", "epoch": "e", "rev": 2, "rows": [[thread, "thread", fields]]}),
        );
        self.expected.listed(&self.server.listed.clone());
    }

    /// The stream subscriptions: id and thread.
    fn streams(&self) -> Vec<(SubId, String)> {
        self.hub
            .mc
            .subscriptions()
            .into_iter()
            .filter(|(_, shape)| shape["type"] == "stream")
            .map(|(id, shape)| (id, shape["stream"].as_str().unwrap().to_owned()))
            .collect()
    }

    /// Answers subscription `id` of `thread`: from its offset when it names
    /// this run's log, else whole; then live.
    fn answer(&mut self, id: SubId, thread: &str) {
        self.answered.insert(id);
        let resume = self.hub.mc.resume(id).unwrap_or_default();
        let engine = &self.hub.engine;
        let offset = resume.get("offset").and_then(Json::as_i64);
        let handle = self.server.handle();
        let resumes = resume.get("handle").and_then(Json::as_str) == Some(handle.as_str())
            && offset.is_some_and(|o| o <= self.server.seq);
        if resumes {
            let events: Vec<Json> = self
                .server
                .log
                .iter()
                .filter(|e| e.1 == thread && Some(e.0) > offset)
                .map(Server::event)
                .collect();
            if !events.is_empty() {
                self.hub.mc.frame_to(
                    engine,
                    id,
                    json!({"t": "events", "offset": self.server.seq, "events": events}),
                );
            }
        } else {
            let plans = self.server.plans.get(thread).cloned().unwrap_or_default();
            let rows: Vec<Json> = plans
                .iter()
                .map(|(plan, n)| json!(["plan", plan, {"id": plan, "n": n}]))
                .collect();
            // A thread with plans has earlier turns to page in.
            let floor = if plans.is_empty() {
                Json::Null
            } else {
                json!(0)
            };
            self.hub.mc.frame_to(
                engine,
                id,
                json!({"t": "snapshot", "part": 0, "rows": rows, "done": true,
                    "offset": self.server.seq, "handle": handle, "floor": floor}),
            );
        }
        self.hub.mc.frame_to(
            engine,
            id,
            json!({"t": "live", "offset": self.server.seq, "handle": handle}),
        );
    }

    fn answer_one(&mut self) {
        if !self.server.up {
            return;
        }
        let next = self
            .streams()
            .into_iter()
            .find(|(id, _)| !self.answered.contains(id));
        if let Some((id, thread)) = next {
            self.answer(id, &thread);
        }
    }

    fn answer_more(&mut self) {
        let asked = self.hub.mc.mores.borrow().len();
        if !self.server.up || self.mores >= asked {
            return;
        }
        let (id, _) = self.hub.mc.mores.borrow()[self.mores];
        self.mores += 1;
        if !self.answered.contains(&id) {
            return;
        }
        self.hub.mc.frame_to(
            &self.hub.engine,
            id,
            json!({"t": "page", "rows": [], "offset": self.server.seq, "floor": null, "done": true}),
        );
    }

    fn step(&mut self, op: &Op) {
        let engine = self.hub.engine.clone();
        match *op {
            Op::Open(t) => {
                open(&self.hub, THREADS[t]);
                self.expected.route_to(THREADS[t]);
            }
            Op::Leave => {
                self.hub
                    .dispatch("settings.navigate", json!({"to": "/settings"}));
                self.expected.route_to("");
            }
            Op::Close(t) => {
                self.hub
                    .with_controller::<ThreadStore, _>(|s, e| s.close(e, &Self::key(THREADS[t])));
                self.expected.close(THREADS[t]);
            }
            Op::Change(t, plan, n) => {
                let (thread, plan) = (THREADS[t].to_owned(), format!("p{plan}"));
                let n = n.map(i64::from);
                let plans = self.server.plans.entry(thread.clone()).or_default();
                match n {
                    Some(n) => plans.insert(plan.clone(), n),
                    None => plans.remove(&plan),
                };
                self.server.seq += 1;
                let change = (self.server.seq, thread.clone(), plan, n);
                if self.server.up {
                    let event = Server::event(&change);
                    for (id, followed) in self.streams() {
                        if followed == thread && self.answered.contains(&id) {
                            self.hub.mc.frame_to(
                                &engine,
                                id,
                                json!({"t": "events", "offset": self.server.seq, "events": [event]}),
                            );
                        }
                    }
                }
                self.server.log.push(change);
            }
            Op::Delete(t) => {
                if self.server.listed.remove(THREADS[t]) {
                    self.send_row(THREADS[t], true);
                }
            }
            Op::Restore(t) => {
                if self.server.listed.insert(THREADS[t].to_owned()) {
                    self.send_row(THREADS[t], false);
                }
            }
            Op::Answer => self.answer_one(),
            Op::AnswerMore => self.answer_more(),
            Op::Earlier => {
                let before = self.hub.mc.mores.borrow().len();
                if let Some(model) = threads::timeline(&engine) {
                    TimelineModel::update(&engine, model, Timeline::load_earlier);
                }
                let mores = self.hub.mc.mores.borrow().clone();
                assert!(mores.len() <= before + 1);
                if let Some((id, _)) = mores.get(before) {
                    // Asked of the active thread's live stream.
                    let thread = self.streams().into_iter().find(|(i, _)| i == id);
                    assert_eq!(
                        thread.map(|(_, t)| Self::key(&t)),
                        Some(threads::active(&engine))
                    );
                    assert!(self.answered.contains(id));
                }
            }
            Op::Drop => {
                if self.server.up {
                    self.server.up = false;
                    self.answered.clear();
                    self.mores = self.hub.mc.mores.borrow().len();
                    self.hub.mc.set_ready(&engine, false);
                }
            }
            Op::ComeBack(restarted) => {
                if !self.server.up {
                    self.server.up = true;
                    if restarted {
                        self.server.handle += 1;
                    }
                    self.hub.mc.set_ready(&engine, true);
                    self.send_shell();
                }
            }
            Op::Deliver => threads::drain(&engine),
            Op::Advance(ms) => {
                self.hub.advance(ms);
                self.expected.now += ms;
                self.expected.evict_idle();
            }
        }
    }

    fn open_threads(&self) -> BTreeSet<String> {
        self.hub
            .with_controller::<ThreadStore, _>(|s, _| s.open_threads())
            .into_iter()
            .map(|k| k.trim_start_matches("env-1:").to_owned())
            .collect()
    }

    fn plans(&self, thread: &str) -> (String, Plans) {
        let model = threads::timeline_of(&self.hub.engine, &Self::key(thread)).unwrap();
        TimelineModel::read(&self.hub.engine, model, |t| {
            let plans = t
                .entities("plan")
                .iter()
                .map(|(id, plan)| (id.clone(), plan["n"].as_i64().unwrap_or(-1)))
                .collect();
            (t.status().to_owned(), plans)
        })
        .unwrap()
    }

    /// After every step: the threads the rules keep open, the route's
    /// active, each followed at most once.
    fn check(&self) -> Result<(), TestCaseError> {
        prop_assert_eq!(self.open_threads(), self.expected.open.clone());
        let active = threads::active(&self.hub.engine);
        let expected = if self.expected.active.is_empty() {
            String::new()
        } else {
            Self::key(&self.expected.active)
        };
        prop_assert_eq!(&active, &expected);
        prop_assert_eq!(
            threads::timeline(&self.hub.engine).is_some(),
            !active.is_empty()
        );
        let mut followed: Vec<String> = self.streams().into_iter().map(|(_, t)| t).collect();
        followed.sort();
        let distinct: BTreeSet<String> = followed.iter().cloned().collect();
        prop_assert_eq!(
            followed.len(),
            distinct.len(),
            "followed twice: {:?}",
            followed
        );
        prop_assert!(distinct.is_subset(&self.expected.open), "{:?}", distinct);
        if !self.server.up {
            for thread in &self.expected.open {
                prop_assert_ne!(
                    self.plans(thread).0,
                    "live",
                    "{} is live while away",
                    thread
                );
            }
        }
        Ok(())
    }

    /// Connected, every copy in and every subscription answered: each open
    /// thread the MC lists is followed once and holds what the MC holds.
    fn settle(&mut self) -> Result<(), TestCaseError> {
        if !self.server.up {
            self.step(&Op::ComeBack(false));
        }
        threads::drain(&self.hub.engine);
        while self
            .streams()
            .iter()
            .any(|(id, _)| !self.answered.contains(id))
        {
            self.answer_one();
            threads::drain(&self.hub.engine);
        }
        self.check()?;
        let followed: BTreeSet<String> = self.streams().into_iter().map(|(_, t)| t).collect();
        let expected: BTreeSet<String> = self
            .expected
            .open
            .intersection(&self.server.listed)
            .cloned()
            .collect();
        prop_assert_eq!(&followed, &expected);
        for thread in &expected {
            let held = self.server.plans.get(thread).cloned().unwrap_or_default();
            prop_assert_eq!(self.plans(thread), ("live".to_owned(), held), "{}", thread);
        }
        Ok(())
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 96, ..ProptestConfig::default() })]

    #[test]
    fn open_threads_hold_what_the_mc_holds(ops in proptest::collection::vec(op(), 1..40)) {
        let mut world = World::new();
        for op in &ops {
            world.step(op);
            world.check()?;
        }
        world.settle()?;
    }
}
