//! One MC of protocol 3 (apps/server-ex lib/hal_c2/web/protocol.ex), as
//! desktop-qt's FakeMc (apps/desktop-qt/tests/native/features/FakeMc.cpp):
//! hello, the shell shape, and `orchestration.dispatchCommand`, which it
//! records and answers (or refuses, or holds until told to answer). Any other
//! call is answered with null unless a domain handles it.
//!
//! It is a real server on loopback, so the shell talks to it through its
//! real connection (hal_c2_mc's McClient): the socket's and HTTP's bytes are
//! moved on a thread of its own, and everything the MC decides runs on the
//! scenario's thread, in [`FakeMc::pump`], which the world calls while it
//! waits. A handler may fail the step it runs under: the world reports the
//! first failure.
//!
//! The shell's rows carry versions as the MC's do (lib/hal_c2/shell.ex): each
//! MC's rows are at [`epoch`, rev], and a `sub` whose `have` names the version
//! the client was last told is answered with the rows changed since, any other
//! with all of them, marked `reset`.
//!
//! A domain's fake lives with its steps: an extension registers its RPC and
//! shape handlers on every new MC, and keeps its state in a part:
//!
//! ```ignore
//! #[derive(Default)]
//! struct FakeGit { calls: Vec<Value> }
//! steps.extension(|mc| {
//!     mc.on_rpc("git.", |mc, rpc| {
//!         mc.part::<FakeGit>().calls.push(rpc.payload.clone());
//!         mc.reply(rpc, Value::Null);
//!         Ok(())
//!     });
//! });
//! ```

use std::any::{Any, TypeId};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::rc::Rc;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};

use futures_util::{SinkExt, StreamExt};
use serde_json::{Map, Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};

use crate::harness::{Failure, Outcome};
use crate::world::Signal;

/// What the MC answers a request for a member it cannot reach (socket.ex).
const UNAVAILABLE: &str = "MC unavailable: noconnection";

/// A call, and the connection it came on: an answer to a dropped one is
/// not sent.
#[derive(Clone, Debug)]
pub struct Rpc {
    pub id: i64,
    pub method: String,
    pub payload: Value,
    pub socket: u64,
    /// The environment it is for ("" for the MC's own).
    pub environment: String,
}

pub type RpcHandler = Rc<dyn Fn(&mut FakeMc, &Rpc) -> Outcome>;
/// `id` is the subscription's; the shape is live until unsubscribed,
/// forgotten or the connection drops.
pub type ShapeHandler = Rc<dyn Fn(&mut FakeMc, i64, &Value) -> Outcome>;
/// A client frame the MC itself does not read (`more`).
pub type FrameHandler = Rc<dyn Fn(&mut FakeMc, &Value) -> Outcome>;
/// A request to the MC's HTTP API: `respond(status, body)` answers it.
pub type HttpHandler = Rc<dyn Fn(&mut FakeMc, &Value, Respond) -> Outcome>;
/// Any request under a prefix (`/api/device-hub/`), HTTP or a socket's
/// handshake: the handler gets the connection with the request unread (`head`
/// is its request line and headers) and answers it itself.
pub type RawHandler = Rc<dyn Fn(&mut FakeMc, std::net::TcpStream, &str) -> Outcome>;
/// What an accepted command does to the MC's rows (the real MC's
/// projection), run before it is answered.
pub type Effect = Rc<dyn Fn(&mut FakeMc, &Value)>;
type Held = Box<dyn FnOnce(&mut FakeMc)>;

/// Answers one HTTP request, once.
pub struct Respond(oneshot::Sender<(u16, String)>);

impl Respond {
    pub fn send(self, status: u16, answer: &Value) {
        let _ = self.0.send((status, answer.to_string()));
    }

    /// A body that is not JSON (a download's bytes as text).
    pub fn send_text(self, status: u16, body: &str) {
        let _ = self.0.send((status, body.to_owned()));
    }
}

/// What the I/O thread saw, for [`FakeMc::pump`].
enum Inbound {
    Opened {
        socket: u64,
        url: String,
    },
    Text {
        socket: u64,
        text: String,
    },
    Closed {
        socket: u64,
    },
    Http {
        path: String,
        body: String,
        respond: Respond,
    },
    Raw {
        stream: std::net::TcpStream,
        head: String,
        prefix: String,
    },
}

enum Control {
    Send(String),
    Drop,
}

enum Listen {
    Stop,
    Start,
    Shutdown,
}

/// What the scenario's thread and the I/O thread share.
struct Io {
    inbound: Mutex<Sender<Inbound>>,
    signal: Arc<Signal>,
    sockets: Mutex<HashMap<u64, UnboundedSender<Control>>>,
    /// The prefixes raw handlers take, read as a request arrives.
    raw_prefixes: Mutex<Vec<String>>,
    next_socket: Mutex<u64>,
}

impl Io {
    fn tell(&self, inbound: Inbound) {
        let _ = self
            .inbound
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .send(inbound);
        self.signal.notify();
    }
}

/// What the client was last told of each MC's rows, and the rev that made.
#[derive(Default, Clone)]
struct Told {
    rev: i64,
    rows: BTreeMap<String, Value>,
}

/// What a faked checkout's `vcs` snapshot is made from.
pub type Checkout = Rc<dyn Fn(&mut FakeMc) -> Value>;

pub struct FakeMc {
    pub name: String,
    pub environment_id: String,
    /// The MC's environment's label, when it has one ("This machine" otherwise).
    pub label: String,
    /// The MC's environment's `platform` (its `machineId`), when a scenario gives it one.
    pub platform: Map<String, Value>,
    pub threads: BTreeMap<String, Value>,
    pub projects: BTreeMap<String, Value>,
    /// Every socket's address (`ws://127.0.0.1:<port>/ws?token=...`), in order.
    pub connections: Vec<String>,
    /// Every `sub` frame, in order.
    pub subscriptions: Vec<Value>,
    /// Every `shell` frame it answered one with, in order.
    pub shell_frames: Vec<Value>,
    /// Names this run of the MC's shell: after a restart (another epoch) what
    /// a client holds of its rows is of no use.
    pub epoch: String,
    /// False for an MC from before rows had versions: its frames carry none.
    pub versioned: bool,
    pub commands: Vec<Value>,
    /// The environment each of `commands` was sent to ("" for the MC's own).
    pub command_environments: Vec<String>,
    /// Every call, in order, whoever answers it.
    pub calls: Vec<Rpc>,
    /// A refusal is for every command of a type, or (`type:threadId`) one thread's.
    pub refusals: HashMap<String, String>,
    pub effects: Vec<Effect>,
    /// Checkouts whose whole status a domain fakes, by folder: the `vcs`
    /// snapshot (`local`, `remote`) the workspace's `vcs` shape sends for them.
    pub checkouts: HashMap<String, Checkout>,
    pub capabilities: Value,
    pub hold_snapshot: bool,
    /// False: the MC has stopped answering, its socket still open.
    pub answer_pings: bool,
    /// The cluster's other members, in the order they joined, and the MC
    /// serving each environment.
    pub members: Vec<String>,
    pub peers: HashMap<String, String>,
    /// A member's label, when its environment has one.
    pub peer_labels: HashMap<String, String>,
    /// A member's `platform` (its `machineId`), when it has one; join() again
    /// announces a change.
    pub peer_platforms: HashMap<String, Value>,
    /// Members whose MC is down: their rows stay, and requests for them fail.
    pub offline: HashSet<String>,
    /// Each member's rows, by environment then id: [id, kind, row].
    pub peer_rows: HashMap<String, BTreeMap<String, Value>>,

    port: u16,
    io: Arc<Io>,
    inbound: Receiver<Inbound>,
    listen: UnboundedSender<Listen>,
    thread: Option<std::thread::JoinHandle<()>>,
    socket: Option<u64>,
    shell_subscription: i64,
    /// The `have` of the shell subscription being answered.
    have: Value,
    told: HashMap<String, Told>,
    frames: HashMap<String, FrameHandler>,
    live: BTreeMap<i64, Value>,
    rpc: HashMap<String, RpcHandler>,
    shapes: HashMap<String, ShapeHandler>,
    http: HashMap<String, HttpHandler>,
    raw: Vec<(String, RawHandler)>,
    holds: HashSet<String>,
    held: Vec<Held>,
    parts: HashMap<TypeId, Box<dyn Any>>,
    failure: Option<Failure>,
}

impl FakeMc {
    /// Starts listening on loopback; `signal` is raised whenever something
    /// waits for [`FakeMc::pump`]. `extensions` are the steps files' handlers.
    pub fn start(signal: Arc<Signal>, extensions: &[fn(&mut FakeMc)]) -> FakeMc {
        let std_listener = std::net::TcpListener::bind("127.0.0.1:0").expect("the fake MC listens");
        std_listener
            .set_nonblocking(true)
            .expect("a non-blocking listener");
        let port = std_listener.local_addr().expect("its port").port();
        let (sender, inbound) = channel();
        let io = Arc::new(Io {
            inbound: Mutex::new(sender),
            signal,
            sockets: Mutex::default(),
            raw_prefixes: Mutex::default(),
            next_socket: Mutex::new(1),
        });
        let (listen, listening) = unbounded_channel();
        let serving = io.clone();
        let thread = std::thread::Builder::new()
            .name("fake-mc".into())
            .spawn(move || serve(std_listener, port, listening, serving))
            .expect("the fake MC's thread");
        let mut mc = FakeMc {
            name: "mc-a".into(),
            environment_id: "env-a".into(),
            label: String::new(),
            platform: Map::new(),
            threads: BTreeMap::new(),
            projects: BTreeMap::new(),
            connections: Vec::new(),
            subscriptions: Vec::new(),
            shell_frames: Vec::new(),
            epoch: "epoch-1".into(),
            versioned: true,
            commands: Vec::new(),
            command_environments: Vec::new(),
            calls: Vec::new(),
            refusals: HashMap::new(),
            effects: Vec::new(),
            checkouts: HashMap::new(),
            capabilities: json!({
                "threadSettlement": true,
                "threadSnooze": true,
                "threadVisitedTracking": true,
                "threadPinning": true,
                "threadPinReorder": true,
                "threadActiveReorder": true,
                "threadTitleRegeneration": true,
                "pullRequests": true,
                "threadPullRequests": true,
                "threadPullRequestLinking": true,
            }),
            hold_snapshot: false,
            answer_pings: true,
            members: Vec::new(),
            peers: HashMap::new(),
            peer_labels: HashMap::new(),
            peer_platforms: HashMap::new(),
            offline: HashSet::new(),
            peer_rows: HashMap::new(),
            port,
            io,
            inbound,
            listen,
            thread: Some(thread),
            socket: None,
            shell_subscription: -1,
            have: Value::Null,
            told: HashMap::new(),
            frames: HashMap::new(),
            live: BTreeMap::new(),
            rpc: HashMap::new(),
            shapes: HashMap::new(),
            http: HashMap::new(),
            raw: Vec::new(),
            holds: HashSet::new(),
            held: Vec::new(),
            parts: HashMap::new(),
            failure: None,
        };
        mc.on_shape("shell", |mc, id, _| {
            mc.shell_subscription = id;
            mc.have = mc
                .subscriptions
                .last()
                .and_then(|s| s.get("have"))
                .cloned()
                .unwrap_or(Value::Null);
            if !mc.hold_snapshot {
                mc.send_snapshot();
            }
            Ok(())
        });
        mc.on_rpc("orchestration.dispatchCommand", |mc, rpc| {
            mc.dispatch_command(rpc);
            Ok(())
        });
        for extend in extensions {
            extend(&mut mc);
        }
        mc
    }

    pub fn origin(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// `method` is exact, or a namespace ("cluster." takes every `cluster.*`
    /// call); an exact match wins.
    pub fn on_rpc(
        &mut self,
        method: &str,
        handler: impl Fn(&mut FakeMc, &Rpc) -> Outcome + 'static,
    ) {
        self.rpc.insert(method.to_owned(), Rc::new(handler));
    }

    pub fn on_shape(
        &mut self,
        kind: &str,
        handler: impl Fn(&mut FakeMc, i64, &Value) -> Outcome + 'static,
    ) {
        self.shapes.insert(kind.to_owned(), Rc::new(handler));
    }

    pub fn on_frame(
        &mut self,
        kind: &str,
        handler: impl Fn(&mut FakeMc, &Value) -> Outcome + 'static,
    ) {
        self.frames.insert(kind.to_owned(), Rc::new(handler));
    }

    /// `path` is exact (`/api/pull-requests/diff`), without its query; an
    /// unknown one is a 404.
    pub fn on_http(
        &mut self,
        path: &str,
        handler: impl Fn(&mut FakeMc, &Value, Respond) -> Outcome + 'static,
    ) {
        self.http.insert(path.to_owned(), Rc::new(handler));
    }

    /// Takes every request whose path starts with `prefix`.
    pub fn on_raw(
        &mut self,
        prefix: &str,
        handler: impl Fn(&mut FakeMc, std::net::TcpStream, &str) -> Outcome + 'static,
    ) {
        self.raw.retain(|(p, _)| p != prefix);
        self.raw.push((prefix.to_owned(), Rc::new(handler)));
        let mut prefixes = self
            .io
            .raw_prefixes
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        prefixes.retain(|p| p != prefix);
        prefixes.push(prefix.to_owned());
    }

    /// Hands a call an exact handler does not take to its namespace's
    /// handler, when two domains fake one method for different callers.
    pub fn pass_on(&mut self, rpc: &Rpc) -> Outcome {
        let namespace = match rpc.method.find('.') {
            Some(dot) => &rpc.method[..=dot],
            None => "",
        };
        match self.rpc.get(namespace).cloned() {
            Some(handler) => handler(self, rpc),
            None => {
                self.reply(rpc, Value::Null);
                Ok(())
            }
        }
    }

    pub fn send(&self, frame: &Value) {
        let Some(socket) = self.socket else { return };
        if let Some(control) = self
            .io
            .sockets
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&socket)
        {
            let _ = control.send(Control::Send(frame.to_string()));
        }
    }

    /// Whether a client's socket is open: a frame sent now reaches it.
    pub fn connected(&self) -> bool {
        self.socket.is_some()
    }

    /// Whether the call came on the connection still open.
    pub fn current(&self, rpc: &Rpc) -> bool {
        Some(rpc.socket) == self.socket
    }

    pub fn reply(&self, rpc: &Rpc, result: Value) {
        if !self.current(rpc) {
            return;
        }
        self.send(&json!({"t": "rpc.result", "id": rpc.id, "result": result}));
    }

    /// An `rpc.error`, with `detail` when given.
    pub fn refuse(&self, rpc: &Rpc, message: &str) {
        self.refuse_with(rpc, message, Value::Null);
    }

    pub fn refuse_with(&self, rpc: &Rpc, message: &str, detail: Value) {
        if !self.current(rpc) {
            return;
        }
        let mut frame = json!({"t": "rpc.error", "id": rpc.id, "error": message});
        if detail.as_object().is_some_and(|d| !d.is_empty()) {
            frame["detail"] = detail;
        }
        self.send(&frame);
    }

    /// Live subscriptions to the shape type, oldest first.
    pub fn subscribers(&self, kind: &str) -> Vec<i64> {
        self.live
            .iter()
            .filter(|(_, shape)| shape.get("type").and_then(Value::as_str) == Some(kind))
            .map(|(id, _)| *id)
            .collect()
    }

    pub fn shape_of(&self, id: i64) -> Value {
        self.live.get(&id).cloned().unwrap_or(Value::Null)
    }

    /// A subscription the MC turned down, which gets nothing more.
    pub fn forget(&mut self, id: i64) {
        self.live.remove(&id);
    }

    /// Named holds say which answers wait: `answers` holds commands and
    /// terminal calls; a domain may hold its own. Held answers are deferred
    /// until answer_held(), which lifts every hold.
    pub fn hold(&mut self, what: &str) {
        self.holds.insert(what.to_owned());
    }

    pub fn holding(&self, what: &str) -> bool {
        self.holds.contains(what)
    }

    pub fn defer(&mut self, answer: impl FnOnce(&mut FakeMc) + 'static) {
        self.held.push(Box::new(answer));
    }

    pub fn answer_held(&mut self) {
        self.holds.clear();
        for answer in std::mem::take(&mut self.held) {
            answer(self);
        }
    }

    /// Lifts every hold and forgets the held answers: what they answer never
    /// reached the MC.
    pub fn drop_held(&mut self) {
        self.holds.clear();
        self.held.clear();
    }

    /// A domain's state on this MC, made on first use.
    pub fn part<T: Default + 'static>(&mut self) -> &mut T {
        self.parts
            .entry(TypeId::of::<T>())
            .or_insert_with(|| Box::new(T::default()))
            .downcast_mut::<T>()
            .expect("a part of its own type")
    }

    /// A domain's state on this MC, when it has been made.
    pub fn peek<T: 'static>(&self) -> Option<&T> {
        self.parts
            .get(&TypeId::of::<T>())
            .and_then(|part| part.downcast_ref::<T>())
    }

    /// Fails the step under way, as a handler's failure does.
    pub fn fail(&mut self, failure: Failure) {
        if self.failure.is_none() {
            self.failure = Some(failure);
        }
    }

    /// The first failure of a handler since the last call.
    pub fn take_failure(&mut self) -> Option<Failure> {
        self.failure.take()
    }

    /// The MC's rows as they are now, by id: [id, kind, row].
    fn rows_of(&self, mc: &str) -> BTreeMap<String, Value> {
        if mc != self.name {
            let environment = self
                .peers
                .iter()
                .find(|(_, m)| m.as_str() == mc)
                .map(|(e, _)| e.clone())
                .unwrap_or_default();
            return self
                .peer_rows
                .get(&environment)
                .cloned()
                .unwrap_or_default();
        }
        let mut rows = BTreeMap::new();
        for (id, row) in &self.threads {
            rows.insert(id.clone(), json!([id, "thread", row]));
        }
        for (id, row) in &self.projects {
            rows.insert(id.clone(), json!([id, "project", row]));
        }
        rows
    }

    /// One MC of a `shell` frame, and its rows the client lacks appended to `rows`.
    fn shell_mc(
        &mut self,
        mc: &str,
        online: bool,
        environment: Value,
        rows: &mut Vec<Value>,
    ) -> Value {
        let mut member = json!({"mc": mc, "online": online, "environment": environment});
        let current = self.rows_of(mc);
        let held = self
            .have
            .get(mc)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let told = self.told.entry(mc.to_owned()).or_default();
        // Only the version the client was last told can be told apart from now.
        let resumes = self.versioned
            && held.len() == 2
            && held[0].as_str() == Some(self.epoch.as_str())
            && held[1].as_i64() == Some(told.rev);
        let mut changed = !resumes;
        for (id, row) in &current {
            if resumes && told.rows.get(id) == Some(row) {
                continue;
            }
            changed = true;
            rows.push(json!([mc, row[0], row[1], row[2]]));
        }
        if resumes {
            // A row that went leaves a deleted one behind, as a thread does.
            for (id, row) in &told.rows {
                if current.contains_key(id) {
                    continue;
                }
                changed = true;
                rows.push(json!([mc, id, row[1], {"id": id, "deletedAt": "2026-09-23T10:00:00Z"}]));
            }
        }
        if changed {
            told.rev += 1;
        }
        told.rows = current;
        if self.versioned {
            member["epoch"] = json!(self.epoch);
            member["rev"] = json!(told.rev);
            member["reset"] = json!(!resumes);
        }
        member
    }

    pub fn send_snapshot(&mut self) {
        if self.socket.is_none() || self.shell_subscription < 0 {
            return;
        }
        let mut rows = Vec::new();
        let name = self.name.clone();
        let own = self.own_environment();
        let mut mcs = vec![self.shell_mc(&name, true, own, &mut rows)];
        for environment in self.members.clone() {
            let peer = self.peers.get(&environment).cloned().unwrap_or_default();
            let online = !self.offline.contains(&environment);
            let descriptor = self.peer_environment(&environment);
            mcs.push(self.shell_mc(&peer, online, descriptor, &mut rows));
        }
        let frame = json!({"t": "shell", "id": self.shell_subscription, "mcs": mcs, "rows": rows});
        self.shell_frames.push(frame.clone());
        self.send(&frame);
    }

    fn own_environment(&self) -> Value {
        let mut own =
            json!({"environmentId": self.environment_id, "capabilities": self.capabilities});
        if !self.label.is_empty() {
            own["label"] = json!(self.label);
        }
        if !self.platform.is_empty() {
            own["platform"] = Value::Object(self.platform.clone());
        }
        own
    }

    /// The MC's own environment changed (`shell.environment`): its label or platform.
    pub fn announce_environment(&self) {
        if self.socket.is_none() || self.shell_subscription < 0 {
            return;
        }
        self.send(&json!({
            "t": "shell.environment",
            "id": self.shell_subscription,
            "mc": self.name,
            "environment": self.own_environment(),
        }));
    }

    fn peer_environment(&self, environment: &str) -> Value {
        let mut descriptor =
            json!({"environmentId": environment, "capabilities": self.capabilities});
        if let Some(label) = self.peer_labels.get(environment) {
            descriptor["label"] = json!(label);
        }
        if let Some(platform) = self.peer_platforms.get(environment) {
            descriptor["platform"] = platform.clone();
        }
        descriptor
    }

    /// Another MC joins this one's cluster, announced as the shell announces
    /// it on nodeup: its environment, whether it is online, and its rows.
    pub fn join(&mut self, peer: &str, peer_environment: &str) {
        if !self.members.iter().any(|m| m == peer_environment) {
            self.members.push(peer_environment.to_owned());
        }
        self.peers
            .insert(peer_environment.to_owned(), peer.to_owned());
        if self.socket.is_none() || self.shell_subscription < 0 {
            return;
        }
        self.send(&json!({
            "t": "shell.environment",
            "id": self.shell_subscription,
            "mc": peer,
            "environment": self.peer_environment(peer_environment),
        }));
        let rows: Vec<Value> = self
            .peer_rows
            .get(peer_environment)
            .map(|rows| rows.values().cloned().collect())
            .unwrap_or_default();
        if !rows.is_empty() {
            self.send_rows(peer, rows);
        }
        let online = !self.offline.contains(peer_environment);
        self.set_online(peer_environment, online);
    }

    /// The same for a machine known by one name, its environment's id and label.
    pub fn join_named(&mut self, name: &str) {
        self.peer_labels.insert(name.to_owned(), name.to_owned());
        self.join(&format!("mc-{name}"), name);
    }

    pub fn send_row(&mut self, id: &str, row: &Value) {
        self.send_row_of(id, row, "thread");
    }

    pub fn send_row_of(&mut self, id: &str, row: &Value, kind: &str) {
        let name = self.name.clone();
        self.send_rows(&name, vec![json!([id, kind, row])]);
    }

    /// Rows of the cluster member `mc` as `shell.rows`: each [id, kind, fields].
    pub fn send_rows(&mut self, mc: &str, rows: Vec<Value>) {
        if self.socket.is_none() || self.shell_subscription < 0 {
            return;
        }
        let mut frame =
            json!({"t": "shell.rows", "id": self.shell_subscription, "mc": mc, "rows": rows});
        if self.versioned {
            // They bring the client's copy of the MC's rows to the next version.
            let told = self.told.entry(mc.to_owned()).or_default();
            for row in &rows {
                told.rows
                    .insert(row[0].as_str().unwrap_or_default().to_owned(), row.clone());
            }
            told.rev += 1;
            let rev = told.rev;
            // A member's rows are the ones it was last said to have.
            let environment = self
                .peers
                .iter()
                .find(|(_, m)| m.as_str() == mc)
                .map(|(e, _)| e.clone());
            if let Some(environment) = environment {
                let kept = self.peer_rows.entry(environment).or_default();
                for row in &rows {
                    kept.insert(row[0].as_str().unwrap_or_default().to_owned(), row.clone());
                }
            }
            frame["epoch"] = json!(self.epoch);
            frame["rev"] = json!(rev);
            frame["reset"] = json!(false);
        }
        self.send(&frame);
    }

    /// A member's row, kept and sent as its `shell.rows` once it has joined.
    pub fn send_peer_row(&mut self, environment: &str, id: &str, row: &Value) {
        self.send_peer_row_of(environment, id, row, "thread");
    }

    pub fn send_peer_row_of(&mut self, environment: &str, id: &str, row: &Value, kind: &str) {
        let entry = json!([id, kind, row]);
        self.peer_rows
            .entry(environment.to_owned())
            .or_default()
            .insert(id.to_owned(), entry.clone());
        if let Some(peer) = self.peers.get(environment).cloned() {
            self.send_rows(&peer, vec![entry]);
        }
    }

    /// A member's MC goes down or comes back (`shell.mc`).
    pub fn set_online(&mut self, environment: &str, online: bool) {
        if online {
            self.offline.remove(environment);
        } else {
            self.offline.insert(environment.to_owned());
        }
        if self.socket.is_none() || self.shell_subscription < 0 {
            return;
        }
        let peer = self.peers.get(environment).cloned().unwrap_or_default();
        self.send(
            &json!({"t": "shell.mc", "id": self.shell_subscription, "mc": peer, "online": online}),
        );
    }

    /// A member is removed from the cluster: the shell drops it and its rows
    /// (`shell.mc` with `removed`).
    pub fn remove(&mut self, environment: &str) {
        let peer = self.peers.remove(environment).unwrap_or_default();
        self.told.remove(&peer);
        self.members.retain(|m| m != environment);
        self.offline.remove(environment);
        self.peer_rows.remove(environment);
        if self.socket.is_none() || self.shell_subscription < 0 {
            return;
        }
        self.send(&json!({
            "t": "shell.mc",
            "id": self.shell_subscription,
            "mc": peer,
            "online": false,
            "removed": true,
        }));
    }

    /// A request for a member whose MC is down, by its environment or its MC.
    fn down(&self, environment: &str, mc: &str) -> bool {
        self.offline.contains(environment)
            || (!mc.is_empty()
                && self
                    .peers
                    .iter()
                    .any(|(e, m)| m == mc && self.offline.contains(e)))
    }

    /// Closes the client's connection: from here on it is sent nothing and
    /// nothing it says is read, whatever the socket still does on its way out.
    pub fn drop_connection(&mut self) {
        let Some(socket) = self.socket.take() else {
            return;
        };
        self.shell_subscription = -1;
        self.live.clear();
        if let Some(control) = self
            .io
            .sockets
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&socket)
        {
            let _ = control.send(Control::Drop);
        }
    }

    pub fn stop_accepting(&self) {
        let _ = self.listen.send(Listen::Stop);
    }

    pub fn start_accepting(&self) {
        let _ = self.listen.send(Listen::Start);
    }

    /// Handles everything the I/O thread has seen since the last call;
    /// true when there was anything.
    pub fn pump(&mut self) -> bool {
        let mut any = false;
        while let Ok(inbound) = self.inbound.try_recv() {
            any = true;
            match inbound {
                Inbound::Opened { socket, url } => self.accept(socket, url),
                Inbound::Text { socket, text } => self.on_message(socket, &text),
                Inbound::Closed { socket } => {
                    if self.socket == Some(socket) {
                        self.socket = None;
                    }
                }
                Inbound::Http {
                    path,
                    body,
                    respond,
                } => {
                    let body = serde_json::from_str(&body).unwrap_or(Value::Null);
                    match self.http.get(&path).cloned() {
                        Some(handler) => {
                            if let Err(failure) = handler(self, &body, respond) {
                                self.fail(failure);
                            }
                        }
                        None => respond.send(404, &json!({"_tag": "NotFound"})),
                    }
                }
                Inbound::Raw {
                    stream,
                    head,
                    prefix,
                } => {
                    let handler = self
                        .raw
                        .iter()
                        .find(|(p, _)| *p == prefix)
                        .map(|(_, h)| h.clone());
                    if let Some(handler) = handler
                        && let Err(failure) = handler(self, stream, &head)
                    {
                        self.fail(failure);
                    }
                }
            }
        }
        any
    }

    fn accept(&mut self, socket: u64, url: String) {
        self.connections.push(url);
        self.socket = Some(socket);
        self.shell_subscription = -1;
        self.live.clear();
        self.send(&json!({"t": "hello", "protocol": 3, "mc": self.name, "environment": self.environment_id}));
    }

    fn on_message(&mut self, socket: u64, text: &str) {
        if self.socket != Some(socket) {
            return;
        }
        let Ok(message) = serde_json::from_str::<Value>(text) else {
            return;
        };
        let kind = message
            .get("t")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        let id = message.get("id").and_then(Value::as_i64).unwrap_or(0);
        let outcome = if kind == "sub" {
            self.subscriptions.push(message.clone());
            let shape = message.get("shape").cloned().unwrap_or(Value::Null);
            let environment = shape
                .get("environment")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let mc = shape.get("mc").and_then(Value::as_str).unwrap_or_default();
            if self.down(environment, mc) {
                self.send(&json!({"t": "error", "id": id, "reason": UNAVAILABLE}));
                return;
            }
            let kind = shape
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let Some(handler) = self.shapes.get(kind).cloned() else {
                return;
            };
            self.live.insert(id, shape.clone());
            handler(self, id, &shape)
        } else if kind == "unsub" {
            self.live.remove(&id);
            Ok(())
        } else if let Some(read) = self.frames.get(&kind).cloned() {
            read(self, &message)
        } else if kind == "ping" {
            if self.answer_pings {
                self.send(&json!({"t": "pong"}));
            }
            Ok(())
        } else if kind == "rpc" {
            let rpc = Rpc {
                id,
                method: message
                    .get("method")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                payload: message.get("payload").cloned().unwrap_or(Value::Null),
                socket,
                environment: message
                    .get("environment")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            };
            self.calls.push(rpc.clone());
            if self.down(&rpc.environment, "") {
                self.refuse(&rpc, UNAVAILABLE);
                return;
            }
            let handler = self.rpc.get(&rpc.method).cloned().or_else(|| {
                let dot = rpc.method.find('.').filter(|&d| d > 0)?;
                self.rpc.get(&rpc.method[..=dot]).cloned()
            });
            match handler {
                Some(handler) => handler(self, &rpc),
                None => {
                    self.reply(&rpc, Value::Null);
                    Ok(())
                }
            }
        } else {
            Ok(())
        };
        if let Err(failure) = outcome {
            self.fail(failure);
        }
    }

    fn dispatch_command(&mut self, rpc: &Rpc) {
        self.commands.push(rpc.payload.clone());
        self.command_environments.push(rpc.environment.clone());
        let kind = rpc
            .payload
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let thread = rpc
            .payload
            .get("threadId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let one = format!("{kind}:{thread}");
        let refused = if self.refusals.contains_key(&one) {
            one
        } else {
            kind.to_owned()
        };
        let refusal = self.refusals.get(&refused).cloned();
        let rpc = rpc.clone();
        let answer = move |mc: &mut FakeMc| match &refusal {
            Some(refusal) => mc.refuse(&rpc, refusal),
            None => {
                for effect in mc.effects.clone() {
                    effect(mc, &rpc.payload);
                }
                let sequence = mc.commands.len();
                mc.reply(&rpc, json!({"sequence": sequence}));
            }
        };
        if self.holding("answers") {
            self.defer(answer);
        } else {
            answer(self);
        }
    }
}

impl Drop for FakeMc {
    fn drop(&mut self) {
        let _ = self.listen.send(Listen::Shutdown);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// The I/O thread: accepts until told to stop, and moves each connection's
/// bytes.
fn serve(
    std_listener: std::net::TcpListener,
    port: u16,
    mut listening: tokio::sync::mpsc::UnboundedReceiver<Listen>,
    io: Arc<Io>,
) {
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    else {
        return;
    };
    runtime.block_on(async move {
        let mut listener = TcpListener::from_std(std_listener).ok();
        loop {
            let accepted = async {
                match &listener {
                    Some(l) => l.accept().await.ok(),
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                control = listening.recv() => match control {
                    Some(Listen::Stop) => listener = None,
                    Some(Listen::Start) => {
                        if listener.is_none() {
                            listener = TcpListener::bind(("127.0.0.1", port)).await.ok();
                        }
                    }
                    Some(Listen::Shutdown) | None => return,
                },
                Some((stream, _)) = accepted => {
                    tokio::spawn(connection(stream, port, io.clone()));
                }
            }
        }
    });
}

/// The request's head (its line and headers), left in the stream.
async fn peek_head(stream: &TcpStream) -> Option<String> {
    let mut buffer = vec![0u8; 16 * 1024];
    loop {
        let n = stream.peek(&mut buffer).await.ok()?;
        if n == 0 {
            return None;
        }
        let text = String::from_utf8_lossy(&buffer[..n]);
        if let Some(end) = text.find("\r\n\r\n") {
            return Some(text[..end + 4].to_owned());
        }
        if n == buffer.len() {
            return None;
        }
        stream.readable().await.ok()?;
    }
}

/// The whole request, head and body.
async fn read_request(stream: &mut TcpStream) -> String {
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 8192];
    loop {
        let n = stream.read(&mut buffer).await.unwrap_or(0);
        if n == 0 {
            break;
        }
        bytes.extend_from_slice(&buffer[..n]);
        let text = String::from_utf8_lossy(&bytes);
        if let Some(end) = text.find("\r\n\r\n") {
            let length = text[..end]
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse().ok())?
                })
                .unwrap_or(0usize);
            if bytes.len() >= end + 4 + length {
                break;
            }
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

async fn connection(mut stream: TcpStream, port: u16, io: Arc<Io>) {
    let Some(head) = peek_head(&stream).await else {
        return;
    };
    let target = head
        .split_whitespace()
        .nth(1)
        .unwrap_or_default()
        .to_owned();
    let prefixes = io
        .raw_prefixes
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone();
    if let Some(prefix) = prefixes
        .into_iter()
        .find(|p| target.starts_with(p.as_str()))
    {
        if let Ok(stream) = stream.into_std() {
            let _ = stream.set_nonblocking(false);
            io.tell(Inbound::Raw {
                stream,
                head,
                prefix,
            });
        }
        return;
    }
    let upgrade = head.lines().any(|line| {
        line.split_once(':').is_some_and(|(name, value)| {
            name.eq_ignore_ascii_case("upgrade") && value.trim().eq_ignore_ascii_case("websocket")
        })
    });
    if upgrade {
        socket(stream, port, io).await;
        return;
    }
    let request = read_request(&mut stream).await;
    let body = request
        .split_once("\r\n\r\n")
        .map(|(_, body)| body.to_owned())
        .unwrap_or_default();
    let path = target.split('?').next().unwrap_or_default().to_owned();
    let (sender, answer) = oneshot::channel();
    io.tell(Inbound::Http {
        path,
        body,
        respond: Respond(sender),
    });
    let Ok((status, json)) = answer.await else {
        return;
    };
    let response = format!(
        "HTTP/1.1 {status} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{json}",
        if status < 300 { "OK" } else { "Error" },
        json.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

// tungstenite's handshake callback returns its refusal unboxed.
#[allow(clippy::result_large_err)]
async fn socket(stream: TcpStream, port: u16, io: Arc<Io>) {
    let mut target = String::new();
    let accepting = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        target = request
            .uri()
            .path_and_query()
            .map(|p| p.as_str().to_owned())
            .unwrap_or_default();
        Ok(response)
    };
    let Ok(mut ws) = tokio_tungstenite::accept_hdr_async(stream, accepting).await else {
        return;
    };
    let id = {
        let mut next = io.next_socket.lock().unwrap_or_else(|e| e.into_inner());
        let id = *next;
        *next += 1;
        id
    };
    let (control, mut controls) = unbounded_channel();
    io.sockets
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(id, control);
    io.tell(Inbound::Opened {
        socket: id,
        url: format!("ws://127.0.0.1:{port}{target}"),
    });
    loop {
        tokio::select! {
            message = ws.next() => match message {
                Some(Ok(Message::Text(text))) => io.tell(Inbound::Text { socket: id, text: text.as_str().to_owned() }),
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            },
            control = controls.recv() => match control {
                Some(Control::Send(text)) => {
                    if ws.send(Message::text(text)).await.is_err() {
                        break;
                    }
                }
                Some(Control::Drop) | None => {
                    let _ = ws.close(None).await;
                    break;
                }
            },
        }
    }
    io.sockets
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .remove(&id);
    io.tell(Inbound::Closed { socket: id });
}

impl FakeMc {
    /// What the scenario's thread waits on: a domain whose own threads
    /// (a fake device hub's sockets) have something to pump raises it.
    pub fn signal(&self) -> Arc<Signal> {
        self.io.signal.clone()
    }
}
