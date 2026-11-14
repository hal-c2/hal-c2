//! A state machine property over `pairing::exchange`, ported from
//! apps/desktop-qt/tests/prop/tst_PairingExchangeProp.cpp: exchanges against
//! MCs the model scripts (real sockets on 127.0.0.1), that describe
//! themselves or not, speak another protocol, take a token, turn it down, hang
//! up or hold on, with addresses ahead of them that nothing answers at,
//! several exchanges at once (each on a thread of its own, as the screen
//! runs it), and some left behind by the screen that started them. It checks
//! what each exchange comes to, what every MC was sent (the token only ever
//! reaches an MC this client speaks to), and which tokens are spent.
//!
//! An abandoned exchange cannot be called off, since it is a blocking call on
//! a thread: it runs to its end and its result goes nowhere. So the model
//! still has it spend its token, and the property checks it finishes the same
//! and does not trouble the others.

use std::io::{Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, TryRecvError, channel};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::JoinHandle;

use proptest::prelude::*;
use serde_json::{Value, json};

use crate::PROTOCOL;
use crate::pairing::{Client, Link, Outcome, Pairing, exchange};

const MCS: usize = 2;
const MOST_EXCHANGES: usize = 12;
/// Held on to, an exchange runs into its transfer timeout in time.
const MOST_HELD: usize = 3;

/// Where a link's origin leads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum At {
    Mc(usize),
    Nothing,
    HangsUp,
    WebServer,
}

/// How an MC answers who it is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Describes {
    Mc,
    NotFound,
    NoEnvironment,
    ProtocolAsText,
    OtherProtocol,
}

/// How it answers a token.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Takes {
    Spends,
    Refuses,
    /// 200, and no session in it.
    NoSession,
    HangsUp,
    Holds,
}

/// Which token a started exchange carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Token {
    /// A fresh one the MC issues for it.
    Fresh(usize),
    /// The last one a issued, spent or not.
    LastOfA,
    /// One nobody issued.
    Forged,
}

#[derive(Clone, Debug)]
enum Action {
    /// The MC answers from now on as set.
    Set(usize, Describes, Takes),
    /// An exchange from a link whose origins are tried in order.
    Start(Vec<At>, Token),
    /// The MC answers the nth token it holds, or hangs up on it.
    Release {
        mc: usize,
        nth: usize,
        hang_up: bool,
    },
    /// The screen that started the nth exchange goes, answered or not.
    Leave(usize),
}

fn action() -> impl Strategy<Value = Action> {
    let at = prop_oneof![
        3 => Just(At::Mc(0)),
        2 => Just(At::Mc(1)),
        2 => Just(At::Nothing),
        1 => Just(At::HangsUp),
        1 => Just(At::WebServer),
    ];
    prop_oneof![
        3 => (
            0..MCS,
            prop_oneof![
                4 => Just(Describes::Mc),
                1 => Just(Describes::NotFound),
                1 => Just(Describes::NoEnvironment),
                1 => Just(Describes::ProtocolAsText),
                1 => Just(Describes::OtherProtocol),
            ],
            prop_oneof![
                3 => Just(Takes::Spends),
                1 => Just(Takes::Refuses),
                1 => Just(Takes::NoSession),
                1 => Just(Takes::HangsUp),
                2 => Just(Takes::Holds),
            ],
        )
            .prop_map(|(mc, describes, takes)| Action::Set(mc, describes, takes)),
        6 => (
            proptest::collection::vec(at, 1..4),
            prop_oneof![
                3 => Just(Token::Fresh(0)),
                2 => Just(Token::Fresh(1)),
                1 => Just(Token::LastOfA),
                1 => Just(Token::Forged),
            ],
        )
            .prop_map(|(origins, token)| Action::Start(origins, token)),
        3 => (0..MCS, 0..3usize, prop_oneof![2 => Just(false), 1 => Just(true)])
            .prop_map(|(mc, nth, hang_up)| Action::Release { mc, nth, hang_up }),
        1 => any::<usize>().prop_map(Action::Leave),
    ]
}

// ---- The model -------------------------------------------------------------

/// What an exchange came to, or will.
#[derive(Clone, Debug, PartialEq)]
struct Expected {
    outcome: Outcome,
    origin: At,
    /// The MC's nth session sold, when paired.
    session: usize,
}

impl Expected {
    fn of(outcome: Outcome, origin: At) -> Self {
        Self {
            outcome,
            origin,
            session: 0,
        }
    }
}

#[derive(Clone, Debug)]
struct ExchangeModel {
    origins: Vec<At>,
    token: String,
    /// Waiting on the MC's answer to its token.
    held_at: Option<usize>,
    /// The screen that started it is gone.
    left: bool,
    done: Option<Expected>,
}

#[derive(Clone, Debug)]
struct McModel {
    describes: Describes,
    takes: Takes,
    unspent: Vec<String>,
    issued: usize,
    sold: usize,
    /// Every token it was sent, in order.
    sent: Vec<String>,
    /// Exchanges it holds, oldest first.
    held: Vec<usize>,
}

#[derive(Clone, Debug)]
struct Model {
    mcs: [McModel; MCS],
    exchanges: Vec<ExchangeModel>,
}

impl Model {
    fn new() -> Self {
        let mc = McModel {
            describes: Describes::Mc,
            takes: Takes::Spends,
            unspent: Vec::new(),
            issued: 0,
            sold: 0,
            sent: Vec::new(),
            held: Vec::new(),
        };
        Self {
            mcs: [mc.clone(), mc],
            exchanges: Vec::new(),
        }
    }

    fn held_count(&self) -> usize {
        self.mcs.iter().map(|mc| mc.held.len()).sum()
    }

    /// Runs the exchange through its origins as `exchange` does, up to its
    /// answer or the MC holding on to its token.
    fn start(&mut self, index: usize) {
        let origins = self.exchanges[index].origins.clone();
        let token = self.exchanges[index].token.clone();
        for at in &origins {
            let at = *at;
            let done = match at {
                At::Nothing | At::HangsUp => continue,
                At::WebServer => Expected::of(Outcome::NotMc, at),
                At::Mc(mc) => match self.mcs[mc].describes {
                    Describes::Mc => {
                        self.mcs[mc].sent.push(token.clone());
                        match self.mcs[mc].takes {
                            Takes::Spends => self.spent(mc, &token),
                            Takes::Refuses => Expected::of(Outcome::Refused, at),
                            Takes::NoSession => {
                                // The MC spends it, and gives nothing for it.
                                self.mcs[mc].unspent.retain(|t| *t != token);
                                Expected::of(Outcome::Refused, at)
                            }
                            Takes::HangsUp => Expected::of(Outcome::Unreachable, at),
                            Takes::Holds => {
                                self.exchanges[index].held_at = Some(mc);
                                self.mcs[mc].held.push(index);
                                return;
                            }
                        }
                    }
                    Describes::OtherProtocol => Expected::of(Outcome::Incompatible, at),
                    _ => Expected::of(Outcome::NotMc, at),
                },
            };
            self.exchanges[index].done = Some(done);
            return;
        }
        self.exchanges[index].done = Some(Expected::of(Outcome::Unreachable, origins[0]));
    }

    /// The answer to a token the MC takes: a session if it was its own and
    /// unspent.
    fn spent(&mut self, mc: usize, token: &str) -> Expected {
        let model = &mut self.mcs[mc];
        let Some(at) = model.unspent.iter().position(|t| t == token) else {
            return Expected::of(Outcome::Refused, At::Mc(mc));
        };
        model.unspent.remove(at);
        model.sold += 1;
        Expected {
            outcome: Outcome::Paired,
            origin: At::Mc(mc),
            session: model.sold,
        }
    }
}

// ---- The MCs ---------------------------------------------------------------

/// Sends a whole response and hangs up, as an HTTP/1.1 server told to close.
fn respond(mut stream: TcpStream, status: u16, content_type: &str, body: &str) {
    let reason = if status < 300 { "OK" } else { "Refused" };
    let _ = write!(
        stream,
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.shutdown(Shutdown::Both);
}

/// The request's path, and its body once all of it is in.
fn read_request(stream: &mut TcpStream) -> Option<(String, Vec<u8>)> {
    let mut received = Vec::new();
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        if let Some(at) = received.windows(4).position(|w| w == b"\r\n\r\n") {
            break at + 4;
        }
        let n = stream.read(&mut chunk).ok().filter(|n| *n > 0)?;
        received.extend_from_slice(&chunk[..n]);
    };
    let head = String::from_utf8_lossy(&received[..head_end]).into_owned();
    let path = head.lines().next()?.split(' ').nth(1)?.to_owned();
    let length = head
        .lines()
        .filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
        .and_then(|(_, value)| value.trim().parse::<usize>().ok())
        .unwrap_or(0);
    while received.len() < head_end + length {
        let n = stream.read(&mut chunk).ok().filter(|n| *n > 0)?;
        received.extend_from_slice(&chunk[..n]);
    }
    Some((path, received[head_end..head_end + length].to_vec()))
}

/// A token the MC holds on to, with the connection it waits on.
struct Held {
    stream: TcpStream,
    token: String,
}

struct McState {
    describes: Describes,
    takes: Takes,
    unspent: Vec<String>,
    issued: usize,
    sold: usize,
    /// Every form it was sent, as pairs.
    forms: Vec<Vec<(String, String)>>,
    held: Vec<Held>,
}

/// An MC whose answers the model sets.
struct Mc {
    environment_id: String,
    state: Mutex<McState>,
    /// Tells that a token is held.
    held_arrived: Condvar,
}

impl Mc {
    fn new(name: &str) -> Arc<Self> {
        Arc::new(Self {
            environment_id: format!("env-{name}"),
            state: Mutex::new(McState {
                describes: Describes::Mc,
                takes: Takes::Spends,
                unspent: Vec::new(),
                issued: 0,
                sold: 0,
                forms: Vec::new(),
                held: Vec::new(),
            }),
            held_arrived: Condvar::new(),
        })
    }

    fn lock(&self) -> MutexGuard<'_, McState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn session(&self, n: usize) -> String {
        format!("session-{}-{n}", self.environment_id)
    }

    fn issue(&self) -> String {
        let mut state = self.lock();
        state.issued += 1;
        let token = format!("pair-{}-{}", self.environment_id, state.issued);
        state.unspent.push(token.clone());
        token
    }

    fn serve(&self, mut stream: TcpStream) {
        let Some((path, body)) = read_request(&mut stream) else {
            return;
        };
        let mut state = self.lock();
        match path.as_str() {
            "/.well-known/hal-c2/environment" => {
                let mut descriptor = json!({
                    "environmentId": self.environment_id,
                    "label": format!("Mac {}", self.environment_id),
                    "orchestrationProtocolVersion": PROTOCOL,
                });
                match state.describes {
                    Describes::Mc => {}
                    Describes::NotFound => {
                        return respond(stream, 404, "text/html", "<html>Not found</html>");
                    }
                    Describes::NoEnvironment => {
                        descriptor.as_object_mut().unwrap().remove("environmentId");
                    }
                    Describes::ProtocolAsText => {
                        descriptor["orchestrationProtocolVersion"] = json!(PROTOCOL.to_string());
                    }
                    Describes::OtherProtocol => {
                        descriptor["orchestrationProtocolVersion"] = json!(PROTOCOL + 1);
                    }
                }
                respond(stream, 200, "application/json", &descriptor.to_string());
            }
            "/oauth/token" => {
                let form: Vec<(String, String)> =
                    url::form_urlencoded::parse(&body).into_owned().collect();
                let token = form
                    .iter()
                    .find(|(name, _)| name == "subject_token")
                    .map(|(_, value)| value.clone())
                    .unwrap_or_default();
                state.forms.push(form);
                match state.takes {
                    Takes::Spends => self.answer(&mut state, stream, &token),
                    Takes::Refuses => respond_invalid(stream),
                    Takes::NoSession => {
                        state.unspent.retain(|t| *t != token);
                        respond(
                            stream,
                            200,
                            "application/json",
                            &json!({"token_type": "Bearer"}).to_string(),
                        );
                    }
                    Takes::HangsUp => {
                        let _ = stream.shutdown(Shutdown::Both);
                    }
                    Takes::Holds => {
                        state.held.push(Held { stream, token });
                        self.held_arrived.notify_all();
                    }
                }
            }
            _ => respond(stream, 404, "text/html", "<html>Not found</html>"),
        }
    }

    /// Spends `token` on a session, if it is one of ours and unspent.
    fn answer(&self, state: &mut McState, stream: TcpStream, token: &str) {
        let Some(at) = state.unspent.iter().position(|t| t == token) else {
            return respond_invalid(stream);
        };
        state.unspent.remove(at);
        state.sold += 1;
        let session = self.session(state.sold);
        respond(
            stream,
            200,
            "application/json",
            &json!({"access_token": session, "token_type": "Bearer"}).to_string(),
        );
    }
}

fn respond_invalid(stream: TcpStream) {
    respond(
        stream,
        400,
        "application/json",
        &json!({"error": "invalid_grant"}).to_string(),
    );
}

/// A server on 127.0.0.1 running `handle` for each connection on a thread of
/// its own; stopped, and its accept thread joined, when dropped.
struct Server {
    origin: String,
    address: SocketAddr,
    stop: Arc<AtomicBool>,
    accepting: Option<JoinHandle<()>>,
}

impl Server {
    fn start(handle: impl Fn(TcpStream) + Send + Sync + 'static) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("a free port");
        let address = listener.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let handle = Arc::new(handle);
        let accepting = std::thread::spawn({
            let stop = stop.clone();
            move || {
                for stream in listener.incoming() {
                    if stop.load(Ordering::SeqCst) {
                        break;
                    }
                    let Ok(stream) = stream else { continue };
                    let handle = handle.clone();
                    std::thread::spawn(move || handle(stream));
                }
            }
        });
        Self {
            origin: format!("http://{address}"),
            address,
            stop,
            accepting: Some(accepting),
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // Wakes the accept thread to see it.
        let _ = TcpStream::connect(self.address);
        if let Some(accepting) = self.accepting.take() {
            let _ = accepting.join();
        }
    }
}

/// An origin nothing listens at.
fn closed_origin() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("a free port");
    format!("http://{}", listener.local_addr().unwrap())
}

// ---- The system under test -------------------------------------------------

/// One exchange as the screen runs it: on a thread of its own, its result
/// sent back unless the screen has gone.
struct Running {
    /// What the harness waits on, whoever is looking.
    finished: Receiver<Pairing>,
    /// The screen's end; none once it left.
    screen: Option<Receiver<Pairing>>,
    thread: Option<JoinHandle<bool>>,
    result: Option<Pairing>,
}

struct World {
    model: Model,
    mcs: [Arc<Mc>; MCS],
    // Kept for their listeners.
    servers: Vec<Server>,
    addresses: Addresses,
    client: Client,
    running: Vec<Running>,
}

struct Addresses {
    mcs: [String; MCS],
    nothing: String,
    hangs_up: String,
    web: String,
}

impl World {
    fn new(os: &str) -> Self {
        let mcs = [Mc::new("a"), Mc::new("b")];
        let mut servers: Vec<Server> = mcs
            .iter()
            .map(|mc| {
                let mc = mc.clone();
                Server::start(move |stream| mc.serve(stream))
            })
            .collect();
        let hangs_up = Server::start(|mut stream| {
            let _ = read_request(&mut stream);
            let _ = stream.shutdown(Shutdown::Both);
        });
        let web = Server::start(|mut stream| {
            if read_request(&mut stream).is_some() {
                respond(stream, 404, "text/html", "<html>Not found</html>");
            }
        });
        // Once the others listen, so that none of them comes to answer there.
        let addresses = Addresses {
            mcs: [servers[0].origin.clone(), servers[1].origin.clone()],
            nothing: closed_origin(),
            hangs_up: hangs_up.origin.clone(),
            web: web.origin.clone(),
        };
        servers.extend([hangs_up, web]);
        Self {
            model: Model::new(),
            mcs,
            servers,
            addresses,
            client: Client {
                label: "HAL-C2 desk & top=é".into(),
                device_type: "desktop".into(),
                os: os.into(),
            },
            running: Vec::new(),
        }
    }

    fn origin(&self, at: At) -> &str {
        match at {
            At::Mc(mc) => &self.addresses.mcs[mc],
            At::Nothing => &self.addresses.nothing,
            At::HangsUp => &self.addresses.hangs_up,
            At::WebServer => &self.addresses.web,
        }
    }

    fn step(&mut self, action: &Action) {
        match action {
            Action::Set(mc, describes, takes) => {
                self.model.mcs[*mc].describes = *describes;
                self.model.mcs[*mc].takes = *takes;
                let mut state = self.mcs[*mc].lock();
                state.describes = *describes;
                state.takes = *takes;
            }
            Action::Start(origins, token) => self.start(origins, *token),
            Action::Release { mc, nth, hang_up } => self.release(*mc, *nth, *hang_up),
            Action::Leave(nth) => self.leave(*nth),
        }
        self.check();
    }

    fn start(&mut self, origins: &[At], token: Token) {
        if self.model.exchanges.len() >= MOST_EXCHANGES || self.model.held_count() >= MOST_HELD {
            return;
        }
        let token = match token {
            Token::Fresh(mc) => {
                let issuer = &mut self.model.mcs[mc];
                issuer.issued += 1;
                let token = format!("pair-env-{}-{}", ["a", "b"][mc], issuer.issued);
                issuer.unspent.push(token.clone());
                assert_eq!(self.mcs[mc].issue(), token);
                token
            }
            Token::LastOfA => format!("pair-env-a-{}", self.model.mcs[0].issued),
            Token::Forged => "forged".to_owned(),
        };
        self.model.exchanges.push(ExchangeModel {
            origins: origins.to_vec(),
            token: token.clone(),
            held_at: None,
            left: false,
            done: None,
        });
        let index = self.model.exchanges.len() - 1;
        self.model.start(index);
        let held_at = self.model.exchanges[index].held_at;

        let link = Link {
            origins: origins
                .iter()
                .map(|at| self.origin(*at).to_owned())
                .collect(),
            token,
        };
        let client = self.client.clone();
        let (to_finished, finished) = channel();
        let (to_screen, screen) = channel();
        let thread = std::thread::spawn(move || {
            let pairing = exchange(&link, &client);
            let delivered = to_screen.send(pairing.clone()).is_ok();
            let _ = to_finished.send(pairing);
            delivered
        });
        self.running.push(Running {
            finished,
            screen: Some(screen),
            thread: Some(thread),
            result: None,
        });
        match held_at {
            // The MC has the token and says nothing yet.
            Some(mc) => {
                let wanted = self.model.mcs[mc].held.len();
                let mut state = self.mcs[mc].lock();
                while state.held.len() < wanted {
                    state = self.mcs[mc]
                        .held_arrived
                        .wait(state)
                        .unwrap_or_else(|e| e.into_inner());
                }
            }
            None => self.finish(index),
        }
    }

    fn release(&mut self, mc: usize, nth: usize, hang_up: bool) {
        let held = &self.model.mcs[mc].held;
        if held.is_empty() {
            return;
        }
        let nth = nth % held.len();
        let index = self.model.mcs[mc].held.remove(nth);
        self.model.exchanges[index].held_at = None;
        let token = self.model.exchanges[index].token.clone();
        self.model.exchanges[index].done = Some(if hang_up {
            Expected::of(Outcome::Unreachable, At::Mc(mc))
        } else {
            self.model.spent(mc, &token)
        });
        {
            let mut state = self.mcs[mc].lock();
            let waiting = state.held.remove(nth);
            assert_eq!(waiting.token, token, "the MC holds its tokens in order");
            if hang_up {
                let _ = waiting.stream.shutdown(Shutdown::Both);
            } else {
                let Held { stream, token } = waiting;
                self.mcs[mc].answer(&mut state, stream, &token);
            }
        }
        self.finish(index);
    }

    fn leave(&mut self, nth: usize) {
        let pending: Vec<usize> = (0..self.model.exchanges.len())
            .filter(|i| !self.model.exchanges[*i].left)
            .collect();
        if pending.is_empty() {
            return;
        }
        let index = pending[nth % pending.len()];
        self.model.exchanges[index].left = true;
        // What it would have been told goes nowhere.
        self.running[index].screen = None;
    }

    /// Waits on exchange `index`'s own result, which the model says is in.
    fn finish(&mut self, index: usize) {
        let running = &mut self.running[index];
        let pairing = running.finished.recv().expect("the exchange finished");
        let delivered = running.thread.take().unwrap().join().expect("no panic");
        // Once, and never to a screen that is gone.
        if let Some(screen) = &running.screen {
            assert_eq!(screen.try_recv().as_ref(), Ok(&pairing));
            assert_eq!(screen.try_recv(), Err(TryRecvError::Disconnected));
        }
        assert_eq!(delivered, running.screen.is_some(), "exchange {index}");
        running.result = Some(pairing);
    }

    fn matches(&self, pairing: &Pairing, expected: &Expected) {
        assert_eq!(pairing.outcome, expected.outcome);
        assert_eq!(pairing.origin, self.origin(expected.origin));
        let paired = match (expected.origin, expected.outcome) {
            (At::Mc(mc), Outcome::Paired) => self.mcs[mc].session(expected.session),
            _ => String::new(),
        };
        assert_eq!(pairing.token, paired);
        let described = match expected.origin {
            At::Mc(mc) if expected.outcome != Outcome::NotMc => {
                Some(Value::from(self.mcs[mc].environment_id.clone()))
            }
            _ => None,
        };
        assert_eq!(pairing.descriptor.get("environmentId"), described.as_ref());
        if expected.outcome == Outcome::NotMc || described.is_none() {
            assert!(pairing.descriptor.is_empty());
        }
    }

    fn check(&self) {
        for (i, model) in self.model.mcs.iter().enumerate() {
            let state = self.mcs[i].lock();
            assert_eq!(state.unspent, model.unspent, "mc {i} unspent");
            assert_eq!(state.sold, model.sold, "mc {i} sold");
            assert_eq!(state.held.len(), model.held.len(), "mc {i} held");
            // The token goes only to an MC this client speaks to.
            let sent: Vec<&str> = state
                .forms
                .iter()
                .map(|form| field(form, "subject_token").unwrap_or_default())
                .collect();
            assert_eq!(sent, model.sent, "mc {i} sent");
            for form in &state.forms {
                self.says_who_the_client_is(form);
            }
        }
        assert_eq!(self.running.len(), self.model.exchanges.len());
        for (running, model) in self.running.iter().zip(&self.model.exchanges) {
            match &model.done {
                Some(expected) => {
                    let pairing = running.result.as_ref().expect("an exchange that finished");
                    self.matches(pairing, expected);
                }
                // The MC holds on to its token: nothing comes back.
                None => {
                    assert!(running.result.is_none());
                    assert_eq!(running.finished.try_recv().err(), Some(TryRecvError::Empty));
                }
            }
        }
    }

    fn says_who_the_client_is(&self, form: &[(String, String)]) {
        assert_eq!(
            field(form, "grant_type"),
            Some("urn:ietf:params:oauth:grant-type:token-exchange")
        );
        assert_eq!(
            field(form, "subject_token_type"),
            Some("urn:hal-c2:params:oauth:token-type:environment-bootstrap")
        );
        assert_eq!(
            field(form, "client_label"),
            Some(self.client.label.as_str())
        );
        assert_eq!(field(form, "client_device_type"), Some("desktop"));
        let os = (!self.client.os.is_empty()).then_some(self.client.os.as_str());
        assert_eq!(field(form, "client_os"), os);
    }

    /// The MCs hang up on whatever they still hold, and every exchange ends:
    /// held ones as an MC that went away mid-answer.
    fn finish_all(&mut self) {
        for mc in 0..MCS {
            let held = std::mem::take(&mut self.mcs[mc].lock().held);
            for waiting in held {
                let _ = waiting.stream.shutdown(Shutdown::Both);
            }
            for index in std::mem::take(&mut self.model.mcs[mc].held) {
                self.model.exchanges[index].held_at = None;
                self.model.exchanges[index].done =
                    Some(Expected::of(Outcome::Unreachable, At::Mc(mc)));
                self.finish(index);
            }
        }
        self.check();
        // Nobody is left running.
        assert!(self.running.iter().all(|r| r.thread.is_none()));
        drop(std::mem::take(&mut self.servers));
    }
}

fn field<'a>(form: &'a [(String, String)], name: &str) -> Option<&'a str> {
    form.iter()
        .find(|(n, _)| n == name)
        .map(|(_, value)| value.as_str())
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 48, ..ProptestConfig::default() })]

    #[test]
    fn exchanges_agree_with_the_model_of_the_mcs_they_meet(
        os in prop_oneof![Just("linux"), Just("")],
        actions in proptest::collection::vec(action(), 1..24),
    ) {
        let mut world = World::new(os);
        for action in &actions {
            world.step(action);
        }
        world.finish_all();
    }
}
