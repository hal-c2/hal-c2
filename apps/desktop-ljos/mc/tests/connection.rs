//! The connection against a fake MC over real sockets: what reaches the MC,
//! and what the owner hears, waited on as events in the order they happened.

mod fake_mc;

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::rc::Rc;
use std::sync::mpsc::{Receiver, channel};
use std::time::Duration;

use fake_mc::{Event, FakeMc, Seen, TOKEN};
use hal_c2_mc::{CallError, Frame, McClient, Phase};
use serde_json::{Value, json};

/// How long anything may take before the test counts it as never coming.
const PATIENCE: Duration = Duration::from_secs(10);

struct Harness {
    client: McClient,
    mc: FakeMc,
    events: Receiver<Event>,
    /// What the MC saw that no wait has taken yet, in order.
    seen: RefCell<VecDeque<Seen>>,
}

impl Harness {
    fn new() -> Self {
        let (sender, events) = channel();
        let mc = FakeMc::start(sender.clone());
        let handle = hal_c2_mc::spawn(move |event| {
            let _ = sender.send(Event::Client(event));
        });
        let client = McClient::new(handle);
        client.set_retry_delays(vec![Duration::from_millis(1)]);
        Self {
            client,
            mc,
            events,
            seen: RefCell::default(),
        }
    }

    fn open(&self) {
        self.client.open(self.mc.origin.clone(), TOKEN);
    }

    /// Hands the owner what the connection says until the MC sees what
    /// `wanted` matches.
    fn mc_sees(&self, mut wanted: impl FnMut(&Seen) -> bool) -> Seen {
        let mut seen = self.seen.borrow_mut();
        if let Some(at) = seen.iter().position(&mut wanted) {
            return seen.remove(at).unwrap();
        }
        drop(seen);
        loop {
            match self.next() {
                Event::Client(event) => self.client.deliver(event),
                Event::Mc(seen) if wanted(&seen) => return seen,
                Event::Mc(seen) => self.seen.borrow_mut().push_back(seen),
            }
        }
    }

    /// The next text frame the MC gets of kind `t`.
    fn mc_gets(&self, t: &str) -> (u64, Value) {
        match self.mc_sees(|seen| matches!(seen, Seen::Text { frame, .. } if frame["t"] == t)) {
            Seen::Text { socket, frame } => (socket, frame),
            _ => unreachable!(),
        }
    }

    /// Hands the owner what the connection says until `done` holds.
    fn until(&self, mut done: impl FnMut(&McClient) -> bool) {
        while !done(&self.client) {
            match self.next() {
                Event::Client(event) => self.client.deliver(event),
                Event::Mc(seen) => self.seen.borrow_mut().push_back(seen),
            }
        }
    }

    fn ready(&self) -> u64 {
        let socket = match self.mc_sees(|seen| matches!(seen, Seen::Socket { .. })) {
            Seen::Socket { socket, .. } => socket,
            _ => unreachable!(),
        };
        self.until(McClient::is_ready);
        socket
    }

    fn next(&self) -> Event {
        self.events
            .recv_timeout(PATIENCE)
            .expect("the connection or the MC said nothing")
    }
}

fn frames() -> (Rc<RefCell<Vec<Frame>>>, impl FnMut(&Frame) + 'static) {
    let got = Rc::new(RefCell::new(Vec::new()));
    let sink = got.clone();
    (got, move |frame: &Frame| {
        sink.borrow_mut().push(frame.clone())
    })
}

fn resume_at(offset: &Rc<Cell<u64>>) -> impl FnMut() -> Frame + 'static {
    let offset = offset.clone();
    move || {
        let mut fields = Frame::new();
        fields.insert("offset".into(), json!(offset.get()));
        fields.insert("handle".into(), json!("thread-1"));
        fields
    }
}

type Slot = Rc<RefCell<Option<Result<Value, CallError>>>>;
type Downloads = Rc<RefCell<Vec<Result<Vec<u8>, CallError>>>>;

fn reply_slot() -> (Slot, impl FnOnce(Result<Value, CallError>) + 'static) {
    let slot = Rc::new(RefCell::new(None));
    let sink = slot.clone();
    (slot, move |result| *sink.borrow_mut() = Some(result))
}

#[test]
fn hello_sends_every_subscription_and_frames_reach_their_handler() {
    let harness = Harness::new();
    let (shell_frames, on_shell) = frames();
    let shell = harness.client.subscribe(json!({"type": "shell"}), on_shell);
    let offset = Rc::new(Cell::new(5));
    let (_, on_thread) = frames();
    let thread = harness.client.subscribe_resuming(
        json!({"type": "thread", "threadId": "t1"}),
        on_thread,
        resume_at(&offset),
    );
    harness.open();
    let socket = harness.ready();
    assert_eq!(harness.client.mc(), "mc@fake");
    assert_eq!(harness.client.environment(), "env-1");

    let (_, first) = harness.mc_gets("sub");
    let (_, second) = harness.mc_gets("sub");
    assert_eq!(
        first,
        json!({"t": "sub", "id": shell, "shape": {"type": "shell"}, "offset": null})
    );
    assert_eq!(
        second,
        json!({"t": "sub", "id": thread, "shape": {"type": "thread", "threadId": "t1"}, "offset": 5, "handle": "thread-1"})
    );

    harness.mc.send(
        socket,
        json!({"t": "snapshot", "id": shell, "projects": []}),
    );
    harness.until(|_| !shell_frames.borrow().is_empty());
    assert_eq!(shell_frames.borrow()[0]["t"], "snapshot");

    // Once subscribed on a ready connection, it goes out at once.
    let late = harness.client.subscribe(json!({"type": "late"}), |_| {});
    let (_, frame) = harness.mc_gets("sub");
    assert_eq!(frame["id"], json!(late));

    harness.client.unsubscribe(shell);
    let (_, frame) = harness.mc_gets("unsub");
    assert_eq!(frame, json!({"t": "unsub", "id": shell}));
}

#[test]
fn a_call_gets_its_reply_or_the_mcs_error() {
    let harness = Harness::new();
    harness.open();
    let socket = harness.ready();

    let (answer, reply) = reply_slot();
    harness
        .client
        .call("env-1", "server.getConfig", json!({"x": 1}), reply);
    let (_, rpc) = harness.mc_gets("rpc");
    assert_eq!(rpc["environment"], "env-1");
    assert_eq!(rpc["method"], "server.getConfig");
    assert_eq!(rpc["payload"], json!({"x": 1}));
    harness.mc.send(
        socket,
        json!({"t": "rpc.result", "id": rpc["id"], "result": {"ok": true}}),
    );
    harness.until(|_| answer.borrow().is_some());
    assert_eq!(answer.take(), Some(Ok(json!({"ok": true}))));

    let (answer, reply) = reply_slot();
    harness.client.call("env-1", "git.pull", json!({}), reply);
    let (_, rpc) = harness.mc_gets("rpc");
    harness.mc.send(
        socket,
        json!({"t": "rpc.error", "id": rpc["id"], "error": "no upstream", "detail": {"_tag": "GitError"}}),
    );
    harness.until(|_| answer.borrow().is_some());
    let error = answer.take().unwrap().unwrap_err();
    assert_eq!(error.message, "no upstream");
    assert_eq!(error.detail, json!({"_tag": "GitError"}));
}

#[test]
fn a_get_carries_the_token_and_answers_with_the_json() {
    let harness = Harness::new();
    let (answer, reply) = reply_slot();
    harness.client.get("/api/auth/session", reply);
    harness.until(|_| answer.borrow().is_some());
    assert!(
        answer.take().unwrap().is_err(),
        "nothing to GET before open"
    );

    harness.open();
    harness.ready();
    let (answer, reply) = reply_slot();
    harness.client.get("/api/auth/session", reply);
    harness.until(|_| answer.borrow().is_some());
    assert_eq!(
        answer.take(),
        Some(Ok(
            json!({"authenticated": true, "scopes": ["orchestration:read"]})
        ))
    );

    let (answer, reply) = reply_slot();
    harness.client.get("/api/nothing-here", reply);
    harness.until(|_| answer.borrow().is_some());
    assert!(answer.take().unwrap().is_err());
}

#[test]
fn a_new_socket_is_sent_every_subscription_from_where_its_owner_got_to() {
    let harness = Harness::new();
    let offset = Rc::new(Cell::new(0));
    let thread =
        harness
            .client
            .subscribe_resuming(json!({"type": "thread"}), |_| {}, resume_at(&offset));
    harness.open();
    let first = harness.ready();
    let (_, sub) = harness.mc_gets("sub");
    assert_eq!(sub["offset"], 0);

    offset.set(42);
    harness.mc.drop_socket(first);
    harness.until(|client| !client.is_ready());
    let second = harness.ready();
    assert_ne!(first, second);
    let (socket, sub) = harness.mc_gets("sub");
    assert_eq!(socket, second);
    assert_eq!(sub["id"], json!(thread));
    assert_eq!(sub["offset"], 42);

    // reconnect() does the same, on purpose.
    offset.set(43);
    harness.client.reconnect();
    let third = harness.ready();
    let (socket, sub) = harness.mc_gets("sub");
    assert_eq!((socket, sub["offset"].clone()), (third, json!(43)));
}

#[test]
fn a_resync_asks_for_the_shape_again_from_the_offset_the_owner_took() {
    let harness = Harness::new();
    let offset = Rc::new(Cell::new(3));
    let on_frame = {
        let offset = offset.clone();
        move |frame: &Frame| {
            if frame["t"] == "resync" {
                offset.set(frame["offset"].as_u64().unwrap());
            }
        }
    };
    let thread =
        harness
            .client
            .subscribe_resuming(json!({"type": "thread"}), on_frame, resume_at(&offset));
    harness.open();
    let socket = harness.ready();
    harness.mc_gets("sub");

    harness
        .mc
        .send(socket, json!({"t": "resync", "id": thread, "offset": 9}));
    let (again_on, sub) = harness.mc_gets("sub");
    assert_eq!(again_on, socket);
    assert_eq!(sub["id"], json!(thread));
    assert_eq!(sub["offset"], 9);
}

#[test]
fn an_mc_on_another_protocol_blocks_without_a_socket() {
    let harness = Harness::new();
    harness.mc.set_protocol(4);
    harness.open();
    harness.until(|client| client.phase() == Phase::Blocked);
    let status = harness.client.status();
    assert_eq!(status.blocked_protocol, Some(4));
    assert_eq!(status.descriptor["environmentId"], "env-1");
    // It stays put: no socket, no retry. Wake asks nothing either.
    harness.client.wake();
    harness.client.close();
    harness.until(|client| client.phase() == Phase::Closed);
    let opened = |seen: &Seen| matches!(seen, Seen::Socket { .. } | Seen::Rejected { .. });
    assert!(!harness.seen.borrow().iter().any(opened));
    while let Ok(event) = harness.events.try_recv() {
        assert!(
            !matches!(&event, Event::Mc(seen) if opened(seen)),
            "{event:?}"
        );
    }
}

#[test]
fn a_download_gets_the_bytes_of_a_signed_url_or_why_not() {
    let harness = Harness::new();
    harness.open();
    harness.ready();

    let got: Downloads = Rc::default();
    for url in ["/attachments/a1.png?sig=ok", "/attachments/gone.png?sig=ok"] {
        let sink = got.clone();
        harness
            .client
            .download(url, move |result| sink.borrow_mut().push(result));
    }
    harness.until(|_| got.borrow().len() == 2);
    let mut got = got.take();
    got.sort_by_key(|r| r.is_err());
    assert_eq!(got[0], Ok(b"png-bytes".to_vec()));
    assert_eq!(got[1].as_ref().unwrap_err().message, "HTTP 404");
}

#[test]
fn a_token_the_socket_refuses_gets_a_ticket_for_it() {
    let harness = Harness::new();
    harness.mc.set_token_on_socket(false);
    harness.open();
    assert_eq!(
        harness.mc_sees(|seen| matches!(seen, Seen::Rejected { .. })),
        Seen::Rejected {
            query: format!("token={TOKEN}")
        }
    );
    assert_eq!(
        harness.mc_sees(|seen| matches!(seen, Seen::Ticket { .. })),
        Seen::Ticket {
            authorization: format!("Bearer {TOKEN}")
        }
    );
    let Seen::Socket { socket, query } =
        harness.mc_sees(|seen| matches!(seen, Seen::Socket { .. }))
    else {
        unreachable!()
    };
    assert_eq!(query, "wsTicket=tk-1");
    harness.until(McClient::is_ready);

    // A ticketed session takes a fresh ticket for every socket after.
    harness.mc.drop_socket(socket);
    harness.mc_sees(|seen| matches!(seen, Seen::Ticket { .. }));
    let Seen::Socket { query, .. } = harness.mc_sees(|seen| matches!(seen, Seen::Socket { .. }))
    else {
        unreachable!()
    };
    assert_eq!(query, "wsTicket=tk-2");
    harness.until(McClient::is_ready);
}

#[test]
fn a_refused_ticket_is_a_refused_credential() {
    let harness = Harness::new();
    harness.mc.set_token_on_socket(false);
    harness.mc.set_refuse_tickets(true);
    harness.open();
    harness.until(|client| client.phase() == Phase::Refused);
}

#[test]
fn a_revoked_session_is_refused_and_not_retried() {
    let harness = Harness::new();
    harness.open();
    let socket = harness.ready();
    harness.mc.close(socket, 4401, "session revoked");
    harness.until(|client| client.phase() == Phase::Refused);
    assert_eq!(harness.client.status().failure, "session revoked");
    harness.mc_sees(|seen| matches!(seen, Seen::Closed { .. }));
    // retry_now() is the way back.
    harness.client.retry_now();
    harness.ready();
}

#[test]
fn a_dropped_socket_fails_the_calls_on_it_and_none_go_out_before_hello() {
    let harness = Harness::new();
    let (early, reply) = reply_slot();
    harness
        .client
        .call("env-1", "server.getConfig", json!({}), reply);
    harness.until(|_| early.borrow().is_some());
    assert_eq!(early.take().unwrap().unwrap_err().message, "not connected");

    harness.open();
    let socket = harness.ready();
    let (in_flight, reply) = reply_slot();
    harness
        .client
        .call("env-1", "server.getConfig", json!({}), reply);
    harness.mc_gets("rpc");
    harness.mc.drop_socket(socket);
    harness.until(|_| in_flight.borrow().is_some());
    assert_eq!(
        in_flight.take().unwrap().unwrap_err().message,
        "disconnected"
    );
}
