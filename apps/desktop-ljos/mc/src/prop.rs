//! A state machine property over the whole connection: the owner's
//! [`McClient`], the [`Core`] behind it, and the two queues between their
//! threads, pumped in any order against an MC played by the test. It checks
//! what reaches the MC (no subscription twice on one socket, nothing before
//! hello, each `sub` resumed from where its owner is) and what the owner hears
//! (frames only for live subscriptions, every call answered once and rightly).

use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::rc::Rc;
use std::time::{Duration, Instant};

use proptest::prelude::*;
use serde_json::{Value, json};
use tokio::sync::mpsc::{UnboundedReceiver, unbounded_channel};
use url::Url;

use crate::core::{Command, Core, Effect, HttpAnswer, Input, NetError, SocketEnd};
use crate::{CallError, McClient, McEvent, McHandle, Phase};

#[derive(Debug, Clone)]
enum Action {
    // The owner, on its thread.
    Open,
    Close,
    Reconnect,
    Subscribe {
        resume: bool,
    },
    Unsubscribe(usize),
    More(usize),
    Call,
    Wake,
    RetryNow,
    SetOnline(bool),
    // The two queues between the threads.
    PumpCommand,
    PumpEvent,
    /// Both queues run dry.
    Settle,
    // The MC.
    /// Whatever the connection waits on goes well: the descriptor, the
    /// ticket, the socket and its hello.
    Advance,
    Descriptor(Described),
    Ticket(Ticketed),
    HandshakeFails,
    Hello,
    Frame(usize),
    Resync(usize),
    End(usize),
    Reply(usize, bool),
    Drop,
    Revoke,
    Pong,
    Tick,
}

#[derive(Debug, Clone, Copy)]
enum Described {
    Ours,
    OtherProtocol,
    Unreachable,
    NotFound,
}

#[derive(Debug, Clone, Copy)]
enum Ticketed {
    Issued,
    Refused,
    Fails,
}

fn action() -> impl Strategy<Value = Action> {
    prop_oneof![
        1 => Just(Action::Open),
        1 => Just(Action::Close),
        1 => Just(Action::Reconnect),
        4 => any::<bool>().prop_map(|resume| Action::Subscribe { resume }),
        2 => any::<usize>().prop_map(Action::Unsubscribe),
        1 => any::<usize>().prop_map(Action::More),
        3 => Just(Action::Call),
        1 => Just(Action::Wake),
        1 => Just(Action::RetryNow),
        1 => any::<bool>().prop_map(Action::SetOnline),
        8 => Just(Action::PumpCommand),
        8 => Just(Action::PumpEvent),
        3 => Just(Action::Settle),
        10 => Just(Action::Advance),
        2 => prop_oneof![
            1 => Just(Described::OtherProtocol),
            1 => Just(Described::Unreachable),
            1 => Just(Described::NotFound),
        ]
        .prop_map(Action::Descriptor),
        1 => prop_oneof![
            1 => Just(Ticketed::Refused),
            1 => Just(Ticketed::Fails),
        ]
        .prop_map(Action::Ticket),
        1 => Just(Action::HandshakeFails),
        6 => any::<usize>().prop_map(Action::Frame),
        2 => any::<usize>().prop_map(Action::Resync),
        1 => any::<usize>().prop_map(Action::End),
        4 => (any::<usize>(), any::<bool>()).prop_map(|(i, ok)| Action::Reply(i, ok)),
        1 => Just(Action::Drop),
        1 => Just(Action::Revoke),
        1 => Just(Action::Pong),
        2 => Just(Action::Tick),
    ]
}

/// What the owner's callbacks saw.
#[derive(Default)]
struct Heard {
    /// Frames each subscription's handler got.
    frames: HashMap<u64, u64>,
    /// Subscriptions the owner ended, or whose `end` its handler got.
    gone: BTreeSet<u64>,
    /// Each call's replies, by the order the calls were made.
    replies: HashMap<usize, Vec<Result<Value, CallError>>>,
    /// The offset each resuming subscription last said it continues from.
    resumed: HashMap<u64, u64>,
}

/// One socket on the MC's side.
struct Served {
    attempt: u64,
    subs: BTreeSet<u64>,
    /// Subscriptions it resynced or ended: the owner may still say `unsub` or
    /// `more` for them, crossing on the wire, and the MC ignores those.
    dropped: BTreeSet<u64>,
    /// Calls it received and has not answered.
    calls: Vec<u64>,
    pinged: bool,
    seq: u64,
}

struct World {
    core: Core,
    now: Instant,
    commands: UnboundedReceiver<Command>,
    events: VecDeque<McEvent>,
    client: McClient,
    heard: Rc<RefCell<Heard>>,
    /// The owner's subscriptions, live or not, in the order made.
    subs: Vec<u64>,
    /// Which made subscriptions resume.
    resuming: BTreeSet<u64>,
    calls_made: usize,
    /// Wire id of the n-th call, as its command reaches the core.
    call_ids: Vec<u64>,
    expected: HashMap<u64, Result<Value, CallError>>,
    descriptor: Option<u64>,
    ticket: Option<u64>,
    opening: Option<u64>,
    socket: Option<Served>,
}

impl World {
    fn new() -> Self {
        let (sender, commands) = unbounded_channel();
        let now = Instant::now();
        let client = McClient::new(McHandle::new(sender));
        Self {
            core: Core::new(now),
            now,
            commands,
            events: VecDeque::new(),
            client,
            heard: Rc::default(),
            subs: Vec::new(),
            resuming: BTreeSet::new(),
            calls_made: 0,
            call_ids: Vec::new(),
            expected: HashMap::new(),
            descriptor: None,
            ticket: None,
            opening: None,
            socket: None,
        }
    }

    fn input(&mut self, input: Input) {
        let effects = self.core.handle(input, self.now);
        for effect in effects {
            self.effect(effect);
        }
    }

    fn effect(&mut self, effect: Effect) {
        match effect {
            Effect::Emit(event) => self.events.push_back(event),
            Effect::GetDescriptor { attempt, url, .. } => {
                assert_eq!(url.path(), "/.well-known/hal-c2/environment");
                self.descriptor = Some(attempt);
            }
            Effect::PostTicket { attempt, url, .. } => {
                assert_eq!(url.path(), "/api/auth/websocket-ticket");
                self.ticket = Some(attempt);
            }
            Effect::OpenSocket { attempt, url, .. } => {
                assert!(self.socket.is_none(), "a second socket while one is open");
                let query: Vec<_> = url.query_pairs().map(|(k, _)| k.into_owned()).collect();
                assert!(
                    query == ["token"] || query == ["wsTicket"],
                    "socket query {query:?}"
                );
                self.opening = Some(attempt);
            }
            Effect::Send { attempt, text } => self.received(attempt, &text),
            Effect::CloseSocket { attempt } => {
                if self.opening == Some(attempt) {
                    self.opening = None;
                }
                if self.socket.as_ref().is_some_and(|s| s.attempt == attempt) {
                    self.socket_gone();
                }
            }
            Effect::Http { .. } => unreachable!("not exercised"),
        }
    }

    /// The MC got `text` on socket `attempt`.
    fn received(&mut self, attempt: u64, text: &str) {
        let served = self
            .socket
            .as_mut()
            .filter(|s| s.attempt == attempt)
            .unwrap_or_else(|| panic!("{text} sent before hello or on a closed socket"));
        let frame: Value = serde_json::from_str(text).unwrap();
        let id = frame["id"].as_u64();
        match frame["t"].as_str().unwrap() {
            "sub" => {
                let id = id.unwrap();
                assert!(served.subs.insert(id), "sub {id} sent twice on one socket");
                served.dropped.remove(&id);
                assert_eq!(frame["shape"], shape());
                let heard = self.heard.borrow();
                if self.resuming.contains(&id) {
                    // Asked afresh for this send, not remembered from an earlier one.
                    assert_eq!(
                        frame["offset"],
                        json!(heard.resumed[&id]),
                        "sub {id} resumed stale"
                    );
                    assert_eq!(frame["handle"], "h");
                } else {
                    assert_eq!(frame["offset"], Value::Null);
                }
            }
            "unsub" => {
                let id = id.unwrap();
                assert!(
                    served.subs.remove(&id) || served.dropped.contains(&id),
                    "unsub {id} the MC never had"
                );
            }
            "more" => {
                let id = id.unwrap();
                assert!(
                    served.subs.contains(&id) || served.dropped.contains(&id),
                    "more for {id} the MC never had"
                );
            }
            "rpc" => served.calls.push(id.unwrap()),
            "ping" => served.pinged = true,
            other => panic!("unexpected {other}"),
        }
    }

    /// The MC's socket is gone: its unanswered calls are owed "disconnected".
    fn socket_gone(&mut self) {
        if let Some(served) = self.socket.take() {
            for id in served.calls {
                self.expected.insert(id, Err(CallError::disconnected()));
            }
        }
    }

    fn server_frame(&mut self, frame: Value) {
        let attempt = self.socket.as_ref().unwrap().attempt;
        self.input(Input::SocketText {
            attempt,
            text: frame.to_string(),
        });
    }

    fn pick_sub(&self, i: usize) -> Option<u64> {
        let served = self.socket.as_ref()?;
        served
            .subs
            .iter()
            .nth(i % served.subs.len().max(1))
            .copied()
    }

    fn step(&mut self, action: Action) {
        match action {
            Action::Open => self
                .client
                .open(Url::parse("https://mc.example").unwrap(), "token"),
            Action::Close => self.client.close(),
            Action::Reconnect => self.client.reconnect(),
            Action::Subscribe { resume } => {
                let id = self.subscribe(resume);
                self.subs.push(id);
            }
            Action::Unsubscribe(i) => {
                if !self.subs.is_empty() {
                    let id = self.subs[i % self.subs.len()];
                    self.heard.borrow_mut().gone.insert(id);
                    self.client.unsubscribe(id);
                }
            }
            Action::More(i) => {
                if !self.subs.is_empty() {
                    self.client.more(self.subs[i % self.subs.len()], 10);
                }
            }
            Action::Call => {
                let n = self.calls_made;
                self.calls_made += 1;
                let heard = self.heard.clone();
                self.client
                    .call("env", "server.getConfig", json!({}), move |result| {
                        heard
                            .borrow_mut()
                            .replies
                            .entry(n)
                            .or_default()
                            .push(result);
                    });
            }
            Action::Wake => self.client.wake(),
            Action::RetryNow => self.client.retry_now(),
            Action::SetOnline(online) => self.client.set_online(online),
            Action::PumpCommand => {
                if let Ok(command) = self.commands.try_recv() {
                    if let Command::Call { id, .. } = &command {
                        self.call_ids.push(*id);
                    }
                    self.input(Input::Command(command));
                }
            }
            Action::PumpEvent => {
                if let Some(event) = self.events.pop_front() {
                    self.client.deliver(event);
                }
            }
            Action::Settle => self.drain(),
            Action::Advance => {
                if self.descriptor.is_some() {
                    self.step(Action::Descriptor(Described::Ours));
                } else if self.ticket.is_some() {
                    self.step(Action::Ticket(Ticketed::Issued));
                } else if self.opening.is_some() {
                    self.step(Action::Hello);
                }
            }
            Action::Descriptor(described) => {
                if let Some(attempt) = self.descriptor.take() {
                    let answer = match described {
                        Described::Ours => body(200, json!({"orchestrationProtocolVersion": 3})),
                        Described::OtherProtocol => {
                            body(200, json!({"orchestrationProtocolVersion": 4}))
                        }
                        Described::NotFound => body(404, json!({})),
                        Described::Unreachable => HttpAnswer {
                            error: Some(NetError::Unreachable("Connection refused".into())),
                            ..HttpAnswer::default()
                        },
                    };
                    let current = attempt == self.core.attempt();
                    self.input(Input::Descriptor { attempt, answer });
                    if matches!(described, Described::OtherProtocol) && current {
                        assert_eq!(self.core.status().phase, Phase::Blocked);
                        assert_eq!(self.core.status().blocked_protocol, Some(4));
                    }
                }
            }
            Action::Ticket(ticketed) => {
                if let Some(attempt) = self.ticket.take() {
                    let answer = match ticketed {
                        Ticketed::Issued => body(200, json!({"ticket": "t"})),
                        Ticketed::Refused => body(401, json!({})),
                        Ticketed::Fails => body(500, json!({})),
                    };
                    let current = attempt == self.core.attempt();
                    self.input(Input::Ticket { attempt, answer });
                    if matches!(ticketed, Ticketed::Refused) && current {
                        assert_eq!(self.core.status().phase, Phase::Refused);
                    }
                }
            }
            Action::HandshakeFails => {
                if let Some(attempt) = self.opening.take() {
                    let end = SocketEnd {
                        error: Some("HTTP error: 401 Unauthorized".into()),
                        ..SocketEnd::default()
                    };
                    self.input(Input::SocketClosed { attempt, end });
                }
            }
            Action::Hello => {
                if let Some(attempt) = self.opening.take() {
                    self.socket = Some(Served {
                        attempt,
                        subs: BTreeSet::new(),
                        dropped: BTreeSet::new(),
                        calls: Vec::new(),
                        pinged: false,
                        seq: 0,
                    });
                    self.server_frame(
                        json!({"t": "hello", "protocol": 3, "mc": "mc@host", "environment": "env"}),
                    );
                    assert_eq!(self.core.status().phase, Phase::Ready);
                }
            }
            Action::Frame(i) => {
                if let Some(id) = self.pick_sub(i) {
                    let served = self.socket.as_mut().unwrap();
                    served.seq += 1;
                    let seq = served.seq;
                    self.server_frame(json!({"t": "events", "id": id, "seq": seq}));
                }
            }
            Action::Resync(i) => {
                if let Some(id) = self.pick_sub(i) {
                    let served = self.socket.as_mut().unwrap();
                    served.subs.remove(&id);
                    served.dropped.insert(id);
                    self.server_frame(json!({"t": "resync", "id": id, "offset": 7}));
                }
            }
            Action::End(i) => {
                if let Some(id) = self.pick_sub(i) {
                    let served = self.socket.as_mut().unwrap();
                    served.subs.remove(&id);
                    served.dropped.insert(id);
                    self.server_frame(json!({"t": "end", "id": id}));
                }
            }
            Action::Reply(i, ok) => {
                let Some(served) = self.socket.as_mut() else {
                    return;
                };
                if served.calls.is_empty() {
                    return;
                }
                let id = served.calls.remove(i % served.calls.len());
                let (frame, expected) = if ok {
                    (
                        json!({"t": "rpc.result", "id": id, "result": id}),
                        Ok(json!(id)),
                    )
                } else {
                    (
                        json!({"t": "rpc.error", "id": id, "error": "nope", "detail": {"_tag": "Nope"}}),
                        Err(CallError {
                            message: "nope".into(),
                            detail: json!({"_tag": "Nope"}),
                        }),
                    )
                };
                self.expected.insert(id, expected);
                self.server_frame(frame);
            }
            Action::Drop | Action::Revoke => {
                if let Some(served) = &self.socket {
                    let attempt = served.attempt;
                    let revoke = matches!(action, Action::Revoke);
                    self.socket_gone();
                    let end = if revoke {
                        SocketEnd {
                            code: Some(4401),
                            reason: "session revoked".into(),
                            ..SocketEnd::default()
                        }
                    } else {
                        SocketEnd {
                            code: Some(1001),
                            ..SocketEnd::default()
                        }
                    };
                    self.input(Input::SocketClosed { attempt, end });
                    let status = self.core.status();
                    if revoke {
                        assert_eq!(status.phase, Phase::Refused);
                        assert_eq!(status.failure, "session revoked");
                    } else {
                        assert!(
                            matches!(status.phase, Phase::Retrying | Phase::Offline),
                            "{status:?}"
                        );
                        assert_eq!(status.failure, "closed");
                    }
                }
            }
            Action::Pong => {
                if self.socket.as_ref().is_some_and(|s| s.pinged) {
                    self.socket.as_mut().unwrap().pinged = false;
                    self.server_frame(json!({"t": "pong"}));
                }
            }
            Action::Tick => {
                if let Some(deadline) = self.core.next_deadline() {
                    self.now = self.now.max(deadline);
                    self.input(Input::Tick);
                }
            }
        }
    }

    fn subscribe(&mut self, resume: bool) -> u64 {
        // The handlers learn their id once `subscribe` returns it.
        let id_cell = Rc::new(RefCell::new(0u64));
        let on_frame = {
            let (heard, id_cell) = (self.heard.clone(), id_cell.clone());
            move |frame: &crate::Frame| {
                let id = *id_cell.borrow();
                let mut heard = heard.borrow_mut();
                assert!(!heard.gone.contains(&id), "frame for ended sub {id}");
                assert_eq!(frame["id"], json!(id));
                if frame["t"] == "end" {
                    heard.gone.insert(id);
                }
                *heard.frames.entry(id).or_default() += 1;
            }
        };
        let id = if resume {
            let (heard, id_cell) = (self.heard.clone(), id_cell.clone());
            let id = self.client.subscribe_resuming(shape(), on_frame, move || {
                let id = *id_cell.borrow();
                let mut heard = heard.borrow_mut();
                let frames = heard.frames.get(&id).copied().unwrap_or(0);
                heard.resumed.insert(id, frames);
                let mut fields = crate::Frame::new();
                fields.insert("offset".into(), json!(frames));
                fields.insert("handle".into(), json!("h"));
                fields
            });
            self.resuming.insert(id);
            id
        } else {
            self.client.subscribe(shape(), on_frame)
        };
        *id_cell.borrow_mut() = id;
        // A ready connection sends the sub, and asks resume, before the id is known.
        let mut heard = self.heard.borrow_mut();
        if let Some(offset) = heard.resumed.remove(&0) {
            heard.resumed.insert(id, offset);
        }
        id
    }

    /// Runs both queues dry.
    fn drain(&mut self) {
        loop {
            if let Ok(command) = self.commands.try_recv() {
                if let Command::Call { id, .. } = &command {
                    self.call_ids.push(*id);
                }
                self.input(Input::Command(command));
            } else if let Some(event) = self.events.pop_front() {
                self.client.deliver(event);
            } else {
                break;
            }
        }
    }

    /// With both queues dry, the owner and the MC agree.
    fn check_settled(&mut self) {
        if !self.commands.is_empty() || !self.events.is_empty() {
            return;
        }
        let ready = self.client.is_ready();
        assert_eq!(ready, self.core.status().is_ready());
        assert_eq!(self.client.status(), self.core.status());
        if ready {
            let served = self.socket.as_ref().expect("ready without a socket");
            let gone = &self.heard.borrow().gone;
            let live: BTreeSet<u64> = self
                .subs
                .iter()
                .copied()
                .filter(|id| !gone.contains(id))
                .collect();
            assert_eq!(
                served.subs, live,
                "the MC's subscriptions are not the owner's"
            );
        }
    }

    /// Closes, runs dry, and checks every call was answered once, as the MC
    /// saw it: its reply, "disconnected" for one in flight when the socket
    /// went, "not connected" for one it never got.
    fn finish(mut self) {
        self.client.close();
        self.drain();
        assert!(self.socket.is_none());
        let heard = self.heard.borrow();
        assert_eq!(self.call_ids.len(), self.calls_made);
        for (n, id) in self.call_ids.iter().enumerate() {
            let replies = heard.replies.get(&n).map(Vec::as_slice).unwrap_or_default();
            assert_eq!(
                replies.len(),
                1,
                "call {id} answered {} times",
                replies.len()
            );
            let expected = self
                .expected
                .get(id)
                .cloned()
                .unwrap_or_else(|| Err(CallError::not_connected()));
            assert_eq!(replies[0], expected, "call {id}");
        }
    }
}

fn shape() -> Value {
    json!({"type": "shell"})
}

fn body(status: u16, body: Value) -> HttpAnswer {
    HttpAnswer {
        status: Some(status),
        body: body.to_string().into_bytes(),
        error: None,
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 512, ..ProptestConfig::default() })]

    #[test]
    fn connection_keeps_owner_and_mc_in_step(actions in proptest::collection::vec(action(), 1..120)) {
        let mut world = World::new();
        world.client.set_retry_delays(vec![Duration::from_millis(5), Duration::from_millis(10)]);
        world.step(Action::Open);
        world.drain();
        for action in actions {
            world.step(action);
            world.check_settled();
        }
        world.drain();
        world.check_settled();
        world.finish();
    }
}
