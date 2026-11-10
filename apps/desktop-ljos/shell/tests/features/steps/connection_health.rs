//! How the desktop's one connection to its MC behaves when things go wrong
//! (McClient, ConnectionHealth, ThreadStore): desktop-qt's
//! ConnectionHealthSteps.cpp, for the @desktop and @shared scenarios of
//! features/connections/connection-health.feature and of
//! mc/platform/websocket-protocol.feature. The client's environment is the
//! MC the shell connects to; a second paired environment is one the MC
//! links to.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream};
use std::rc::Rc;
use std::time::Duration;

use chrono::Duration as Span;
use hal_c2_mc::{DEFAULT_RETRY_DELAYS, PROTOCOL, Phase};
use hal_c2_shell::controllers::connection_health::{ConnectionHealth, Network};
use hal_c2_shell::controllers::drafts;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::threads::{self, ThreadStore};
use hal_c2_shell::store;
use hal_c2_shell::thread_view::timeline_model::TimelineModel;
use serde_json::{Map, Value, json};

use super::stream::{
    FakeStreams, PROJECT, THREAD, add_item, describe, followers, iso, kept_copy, look,
    look_at_thread, now, role, row_count, set, start_running, status,
};
use crate::brick::Brick;
use crate::fake_mc::FakeMc;
use crate::harness::{Failure, Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};
use ljos::prelude::ObjectId;

/// The MC's HTTP side of a connection: its descriptor
/// (`/.well-known/hal-c2/environment`), the socket tickets it issues, and
/// the sessions it revoked, whose sockets it turns away with a 401 as
/// apps/server-ex router.ex does.
pub struct FakeHealth {
    protocol: i64,
    server_version: String,
    revoked: HashSet<String>,
    /// Socket tickets it issued.
    tickets: Vec<String>,
    /// Pairing tokens it took at `/oauth/token`, and the session each bought.
    pairing_tokens: HashMap<String, String>,
}

impl Default for FakeHealth {
    fn default() -> FakeHealth {
        FakeHealth {
            protocol: PROTOCOL,
            server_version: String::new(),
            revoked: HashSet::new(),
            tickets: Vec::new(),
            pairing_tokens: HashMap::new(),
        }
    }
}

/// What the scenario watches.
#[derive(Default)]
struct Watched {
    /// The delay of each retry the client scheduled, in ms.
    retry_delays: Rc<RefCell<Vec<u64>>>,
    connections_before: usize,
    stream_subs_before: usize,
    /// Each connection check's verdict, once the app came to the foreground.
    checks: Option<Rc<RefCell<Vec<bool>>>>,
    call_error: Rc<RefCell<String>>,
    /// Each followed thread's last offset.
    offsets: HashMap<String, i64>,
    /// The thread the scenario is about.
    thread: String,
    /// The cluster member the scenario removes.
    saved_environment: String,
    rows_before: usize,
    /// Every `connection` the shell published while watching.
    down: Rc<Down>,
}

/// What the shell said of the connection while a step watched it.
#[derive(Default)]
struct Down {
    watching: Cell<bool>,
    /// The controller saw the client leave Ready.
    saw_down: Cell<bool>,
    /// A surface said the connection was down.
    shown_down: Cell<bool>,
    /// A surface said the connection was up.
    said_connected: Cell<bool>,
}

fn watched(world: &mut World) -> &mut Watched {
    world.part::<Watched>()
}

/// Watches every `connection` the shell publishes, not only those a poll
/// lands on, while `down.watching`.
fn watch_connection(world: &World, down: Rc<Down>) {
    let engine = world.engine();
    hal_c2_shell::bridge::Bridge::of(engine).watch(engine, "connection", move |_, said| {
        if !down.watching.get() {
            return;
        }
        let settling = said["settling"].as_bool().unwrap_or(false);
        if said["phase"] == "connected" || settling {
            down.said_connected.set(true);
        }
        if said["phase"] != "connected" {
            down.saw_down.set(true);
            if !settling {
                down.shown_down.set(true);
            }
        }
    });
}

fn health(mc: &mut FakeMc) -> &mut FakeHealth {
    mc.part::<FakeHealth>()
}

/// The whole of an HTTP request, head and body.
fn read_request(stream: &mut TcpStream) -> String {
    // Bounded: a client that never finishes its request fails its own step.
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 8192];
    loop {
        let n = stream.read(&mut buffer).unwrap_or(0);
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

fn respond(mut stream: TcpStream, status: u16, body: &str, kind: &str) {
    let reason = if status < 300 { "OK" } else { "Refused" };
    let _ = write!(
        stream,
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.flush();
    let _ = stream.shutdown(Shutdown::Both);
}

fn answer(mut stream: TcpStream, status: u16, body: &str, kind: &str) {
    read_request(&mut stream);
    respond(stream, status, body, kind);
}

fn extension(mc: &mut FakeMc) {
    mc.on_raw("/.well-known/hal-c2/environment", |mc, stream, _| {
        let label = if mc.label.is_empty() {
            "Workstation".to_owned()
        } else {
            mc.label.clone()
        };
        let mut descriptor = json!({
            "environmentId": mc.environment_id,
            "label": label,
            "orchestrationProtocolVersion": health(mc).protocol,
            "mc": mc.name,
        });
        let version = health(mc).server_version.clone();
        if !version.is_empty() {
            descriptor["serverVersion"] = json!(version);
        }
        answer(stream, 200, &descriptor.to_string(), "application/json");
        Ok(())
    });
    // A socket ticket for a credential the MC knows (router.ex
    // `/api/auth/websocket-ticket`).
    mc.on_raw("/api/auth/websocket-ticket", |mc, stream, head| {
        let token = head
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                let value = value.trim();
                (name.eq_ignore_ascii_case("authorization"))
                    .then(|| value.strip_prefix("Bearer ").map(str::to_owned))?
            })
            .unwrap_or_default();
        let fake = health(mc);
        if fake.revoked.contains(&token) {
            let refusal =
                json!({"_tag": "EnvironmentAuthInvalidError", "reason": "invalid_credential"});
            answer(stream, 401, &refusal.to_string(), "application/json");
            return Ok(());
        }
        let ticket = format!("ticket-{}", fake.tickets.len() + 1);
        fake.tickets.push(ticket.clone());
        answer(
            stream,
            200,
            &json!({"ticket": ticket}).to_string(),
            "application/json",
        );
        Ok(())
    });
}

/// The MC turns away the socket of a session it revoked.
fn refuse_socket(mc: &mut FakeMc, token: &str) {
    mc.on_raw(&format!("/ws?token={token}"), |_, stream, _| {
        answer(stream, 401, "unauthorized", "text/plain");
        Ok(())
    });
}

fn connection(world: &World) -> Value {
    world.state("connection")
}

fn field(world: &World, name: &str) -> String {
    text(&connection(world)[name])
}

fn phase(world: &World) -> String {
    field(world, "phase")
}

fn needs_pairing(world: &World) -> bool {
    connection(world)["needsPairing"].as_bool().unwrap_or(false)
}

fn wait_for_phase(world: &mut World, phases: &[&str]) -> Outcome {
    let wanted: Vec<String> = phases.iter().map(|p| (*p).to_owned()).collect();
    let said = wanted.join(" or ");
    world.wait_for_with(
        move |w| wanted.contains(&phase(w)),
        move |w| {
            format!(
                "the connection to be {said}; it is {}",
                show(&connection(w))
            )
        },
    )
}

fn ensure_connected(world: &mut World) -> Outcome {
    if world.shell_subscriptions() == 0 {
        world.connect()?;
    }
    wait_for_phase(world, &["connected"])
}

fn ms(delays: &[u64]) -> Vec<Duration> {
    delays.iter().map(|d| Duration::from_millis(*d)).collect()
}

/// The MC goes away: it takes no new connection and drops the one it has.
/// The client's next retry is `delays` off.
fn go_down(world: &mut World, delays: &[u64]) -> Outcome {
    world.client().set_retry_delays(ms(delays));
    world.mc.stop_accepting();
    world.mc.drop_connection();
    world.wait_for_with(
        |w| w.client().phase() == Phase::Retrying,
        |w| {
            format!(
                "a retry to be scheduled; the connection is {}",
                show(&connection(w))
            )
        },
    )
}

fn wait_for_reconnect(world: &mut World, connections: usize) -> Outcome {
    world.wait_for_with(
        move |w| w.mc.connections.len() >= connections && phase(w) == "connected",
        move |w| {
            format!(
                "connection {connections}; there were {} and it is {}",
                w.mc.connections.len(),
                show(&connection(w))
            )
        },
    )
}

/// The MC as a client on another machine reaches it: at an address that is
/// not loopback's. The any-address is not, and the system routes it to this
/// machine.
fn remote_origin(world: &World) -> String {
    world.mc.origin().replace("127.0.0.1", "0.0.0.0")
}

/// Pairs the client anew, with the MC at `origin`.
fn open_at(world: &mut World, origin: &str) -> Outcome {
    let session = hal_c2_shell::session::Session {
        origin: origin.to_owned(),
        token: "mc-token".into(),
        label: String::new(),
        environment_id: String::new(),
    };
    hal_c2_shell::open(world.engine(), &session).map_err(Failure)?;
    world.pump()
}

/// Connects the client again, and waits for the connection it had to go:
/// the client drops it on its own thread, so until then the old one still
/// reads as ready. A client the scenario never paired is paired now.
fn reconnect(world: &mut World) -> Outcome {
    if world.shell_subscriptions() == 0 {
        let origin = world.mc.origin();
        return open_at(world, &origin);
    }
    let before = world.client().status().connection;
    world.client().reconnect();
    world.wait_for("the old connection to go", move |w| {
        before.is_none() || w.client().status().connection != before
    })
}

/// What the system says of the device's network from here on, and that it
/// changed.
fn set_network(world: &mut World, disconnected: bool, interface_up: bool) -> Outcome {
    world.with::<ConnectionHealth, _>(|c, engine| {
        c.set_network(Network {
            disconnected: Rc::new(move |_| disconnected),
            interface_up: Rc::new(move |_| interface_up),
        });
        c.network_changed(engine);
    })?;
    world.pump()
}

/// The notice every window shows over its layout, its panel opened from its
/// icon when it shows one. A reconnect younger than its grace shows nothing,
/// so the grace is waited out first.
fn notice(world: &mut World) -> Outcome<Brick> {
    world.wait_for_with(
        |w| !settling(w),
        |w| {
            format!(
                "the reconnect to be past its grace; the connection is {}",
                show(&connection(w))
            )
        },
    )?;
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nItem { ConnectionNotice {} }\n",
        900.0,
        600.0,
    )?;
    world.part::<crate::brick::Shown>().0 = Some(brick);
    let item = brick.item(world, "connectionNotice")?;
    if brick.flag(world, item, "visible") {
        brick.click(world, "connectionNoticeButton")?;
    }
    Ok(brick)
}

fn settling(world: &World) -> bool {
    connection(world)["settling"].as_bool().unwrap_or(false)
}

fn notice_shows(world: &mut World, text: &str) -> Outcome<bool> {
    let brick = notice(world)?;
    brick.shows(world, text)
}

fn stream_subscriptions(world: &World, thread: &str) -> usize {
    world
        .mc
        .subscriptions
        .iter()
        .filter(|sub| {
            sub.pointer("/shape/type").and_then(Value::as_str) == Some("stream")
                && sub.pointer("/shape/stream").and_then(Value::as_str) == Some(thread)
        })
        .count()
}

/// Whether a row of the shown thread reads `text`.
fn shows(world: &World, text: &str) -> bool {
    let rows = row_count(world).unwrap_or(0);
    (0..rows).any(|row| role(world, row, "text").as_str() == Some(text))
}

/// A thread of the MC's own, with an answer in it, opened and followed.
fn follow_thread(world: &mut World) -> Outcome {
    let project = json!({"id": PROJECT, "title": PROJECT, "workspaceRoot": format!("/work/{PROJECT}"), "scripts": []});
    world.mc.projects.insert(PROJECT.into(), project.clone());
    world.mc.send_row_of(PROJECT, &project, "project");
    look_at_thread(world, PROJECT)?;
    start_running(world)?;
    add_item(
        world,
        "assistant_message",
        json!({"text": "The cart total includes tax now."}),
    )?;
    let thread = format!("{}:{THREAD}", world.mc.environment_id);
    let rows = row_count(world)?;
    let watched = watched(world);
    watched.thread = thread;
    watched.rows_before = rows;
    expect!(rows > 0, "the thread shows nothing: {}", describe(world));
    Ok(())
}

fn leave_thread(world: &mut World) -> Outcome {
    world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Home))?;
    world.wait_for("the thread to be left", |w| {
        threads::active(w.engine()).is_empty()
    })
}

/// A cluster member with a project and one thread, online.
fn join_member(world: &mut World, mc: &str, environment: &str) -> Outcome {
    world.mc.join(mc, environment);
    let thread = format!("thread-{environment}");
    let project_id = format!("project-{environment}");
    world.mc.send_rows(
        mc,
        vec![
            json!([project_id, "project", {"id": project_id, "title": environment,
                   "workspaceRoot": format!("/work/{environment}"), "scripts": []}]),
            json!([thread, "thread", {"id": thread, "title": format!("On {environment}"),
                   "projectId": project_id, "createdAt": "2026-09-23T09:00:00Z",
                   "updatedAt": "2026-09-23T09:00:00Z"}]),
        ],
    );
    for id in world.mc.subscribers("shell") {
        world
            .mc
            .send(&json!({"t": "shell.mc", "id": id, "mc": mc, "online": true}));
    }
    // What its thread holds.
    world
        .mc
        .part::<FakeStreams>()
        .threads
        .entry(thread)
        .or_default()
        .insert(
            format!("turn-item\nmessage:{environment}"),
            json!({"id": format!("message:{environment}"), "type": "user_message", "ordinal": 1,
               "status": "completed", "text": format!("Hello from {environment}"),
               "updatedAt": iso(now())}),
        );
    world.sync()
}

/// Opens the member's thread and waits for what it holds.
fn follow_member(world: &mut World, environment: &str) -> Outcome {
    look(world, &format!("{environment}:thread-{environment}"), true)?;
    let hello = format!("Hello from {environment}");
    let environment = environment.to_owned();
    world.wait_for_with(
        move |w| shows(w, &hello),
        move |w| format!("the thread of {environment} to arrive; {}", describe(w)),
    )
}

fn has_thread(world: &World, key: &str) -> bool {
    store::with(world.engine(), |s| s.thread(key).is_some())
}

fn environments(world: &World) -> Vec<String> {
    store::with(world.engine(), |s| s.environments())
}

/// Removes the cluster member the scenario saved, as Cluster settings does;
/// the MC then drops the member for every client. False when there is none.
pub fn remove_saved_environment(world: &mut World) -> Outcome<bool> {
    let environment = watched(world).saved_environment.clone();
    if environment.is_empty() {
        return Ok(false);
    }
    world.dispatch("cluster.remove", json!({"id": environment}))?;
    world.mc.remove(&environment);
    Ok(true)
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);
    register_client(steps);
    register_slow(steps);
    register_computer(steps);
    register_kept(steps);
    register_window(steps);
    register_renewal(steps);
    register_slow_mc(steps);

    steps.step(
        "(?:a client paired with an environment|a paired client)",
        |world, _, _| ensure_connected(world),
    );
    steps.step(
        "(?:a connected (?:client|environment)|an established connection)",
        |world, _, _| ensure_connected(world),
    );

    // Retrying.
    steps.step("the environment stops answering", |world, _, _| {
        record_retries(world);
        // The shape of the real delays, a hundredth of their length.
        world.client().set_retry_delays(ms(&[5, 10, 20, 40, 80]));
        world.mc.stop_accepting();
        Ok(())
    });
    steps.step("the connection drops", |world, _, _| {
        world.mc.drop_connection();
        world.wait_for("the client to see the drop", |w| !w.client().is_ready())
    });
    steps.step(
        "the client retries with delays that grow up to a cap",
        |world, _, _| {
            let expected: Vec<u64> = vec![5, 10, 20, 40, 80, 80, 80];
            let delays = watched(world).retry_delays.clone();
            let count = expected.len();
            let seen = delays.clone();
            world.wait_for_with(
                move |_| seen.borrow().len() >= count,
                move |w| {
                    format!(
                        "{count} retries; the connection is {}",
                        show(&connection(w))
                    )
                },
            )?;
            let got: Vec<u64> = delays.borrow().iter().take(count).copied().collect();
            expect!(got == expected, "the delays were {got:?}");
            // And the delays a client starts with grow the same way.
            let real = DEFAULT_RETRY_DELAYS;
            let sorted = real.windows(2).all(|w| w[0] <= w[1]);
            expect!(
                real.len() > 2 && sorted && real[0] < real[real.len() - 1],
                "the default delays are {real:?}"
            );
            Ok(())
        },
    );
    steps.step(
        "reconnects when the environment answers again",
        |world, _, _| {
            world.mc.start_accepting();
            wait_for_reconnect(world, 2)
        },
    );

    // No network.
    steps.step("the device has no network", |world, _, _| {
        world.client().set_online(false);
        world.pump()
    });
    steps.step(
        "the client waits for the network to return before trying again",
        |world, _, _| {
            wait_for_phase(world, &["offline"])?;
            // The environment would answer; nothing is asked of it while offline.
            world.pump()?;
            expect!(
                world.client().phase() == Phase::Offline && world.mc.connections.len() == 1,
                "the client tried again: {} connections, {}",
                world.mc.connections.len(),
                show(&connection(world))
            );
            world.client().set_online(true);
            wait_for_reconnect(world, 2)
        },
    );

    // The device's network as the system reports it, for an MC that needs one.
    steps.step("the environment is on another machine", |world, _, _| {
        let connections = world.mc.connections.len();
        let origin = remote_origin(world);
        open_at(world, &origin)?;
        wait_for_reconnect(world, connections + 1)
    });
    steps.step("the device loses one of its two networks", |world, _, _| {
        // As Android has it: disconnected, says the system, with a network still up.
        set_network(world, true, true)
    });
    steps.step("the device loses every network", |world, _, _| {
        set_network(world, true, false)
    });
    steps.step("the client is waiting for the network", |world, _, _| {
        set_network(world, true, false)?;
        world.mc.drop_connection();
        wait_for_phase(world, &["offline"])
    });
    steps.step("a network comes back", |world, _, _| {
        watched(world).connections_before = world.mc.connections.len();
        set_network(world, false, true)
    });
    steps.step(
        "the user pairs the client with an environment on this machine",
        |world, _, _| {
            watched(world).connections_before = world.mc.connections.len();
            let origin = world.mc.origin();
            open_at(world, &origin)
        },
    );
    steps.step(
        "the client is opened at an environment on another machine",
        |world, _, _| {
            // Which a device with no network does not reach.
            world.mc.stop_accepting();
            let origin = remote_origin(world);
            open_at(world, &origin)
        },
    );
    steps.step("the client keeps retrying", |world, _, _| {
        let delays = watched(world).retry_delays.clone();
        let seen = delays.clone();
        world.wait_for_with(
            move |_| seen.borrow().len() >= 3,
            move |w| {
                format!(
                    "three retries; there were {} and the connection is {}",
                    delays.borrow().len(),
                    show(&connection(w))
                )
            },
        )
    });
    steps.step("does not say the device is offline", |world, _, _| {
        let offline = notice_shows(world, "This device is offline")?;
        expect!(
            phase(world) == "reconnecting" && !offline,
            "the connection is {}",
            show(&connection(world))
        );
        Ok(())
    });
    steps.step("the client waits for the network", |world, _, _| {
        wait_for_phase(world, &["offline"])?;
        // Nothing is asked of the environment while the device has no network.
        let connections = world.mc.connections.len();
        world.pump()?;
        expect!(
            world.client().phase() == Phase::Offline && world.mc.connections.len() == connections,
            "the client tried again: {} connections, {}",
            world.mc.connections.len(),
            show(&connection(world))
        );
        Ok(())
    });
    steps.step("says the device is offline", |world, _, _| {
        let offline = notice_shows(world, "This device is offline")?;
        expect!(
            field(world, "status") == "Offline" && offline,
            "the connection is {}",
            show(&connection(world))
        );
        Ok(())
    });

    // A refused credential.
    steps.step(
        "the environment refuses the client's credential",
        |world, _, _| {
            health(&mut world.mc).revoked.insert("mc-token".into());
            refuse_socket(&mut world.mc, "mc-token");
            Ok(())
        },
    );
    steps.step(
        "(?:the|a) client (?:connects|tries to connect)",
        |world, _, _| {
            watched(world).connections_before = world.mc.connections.len();
            reconnect(world)?;
            wait_for_phase(world, &["connected", "refused", "blocked"])
        },
    );
    // Refused waits for the user to pair again; blocked, for an update or the user.
    steps.step("the client stops retrying", |world, _, _| {
        wait_for_phase(world, &["refused", "blocked"])?;
        world.pump()?;
        let before = watched(world).connections_before;
        let now = world.client().phase();
        expect!(
            matches!(now, Phase::Refused | Phase::Blocked) && world.mc.connections.len() == before,
            "the client went on: {}",
            show(&connection(world))
        );
        Ok(())
    });
    steps.step("asks the user to pair again", |world, _, _| {
        expect!(
            needs_pairing(world),
            "the connection is {}",
            show(&connection(world))
        );
        let shown = notice(world)?;
        // After what the environment said of the credential, when it said it.
        let detail = field(world, "detail");
        let item = shown.item(world, "connectionNotice")?;
        let asks = shown.flag(world, item, "visible")
            && shown.shows(world, "Pair again")?
            && detail.ends_with("Pair again with a fresh pairing link from the environment.")
            && shown.shows(world, &detail)?;
        expect!(asks, "the window does not ask for a pairing link");
        Ok(())
    });

    // Pairing again (connections/pairing.feature).
    steps.step("a device whose session was revoked", |world, _, _| {
        ensure_connected(world)?;
        follow_thread(world)?;
        health(&mut world.mc).revoked.insert("mc-token".into());
        refuse_socket(&mut world.mc, "mc-token");
        world.mc.drop_connection();
        wait_for_phase(world, &["refused"])
    });
    steps.step(
        "the user pairs it again with a fresh link",
        |world, _, _| {
            // The MC sells a new session for the link's token (`/oauth/token`), once.
            world.mc.on_raw("/oauth/token", |mc, mut stream, _| {
                let request = read_request(&mut stream);
                let fake = health(mc);
                let fresh =
                    request.contains("subject_token=fresh-1&") && fake.pairing_tokens.is_empty();
                if fresh {
                    fake.pairing_tokens
                        .insert("fresh-1".into(), "session-2".into());
                    respond(
                        stream,
                        200,
                        &json!({"access_token": "session-2"}).to_string(),
                        "application/json",
                    );
                } else {
                    respond(
                        stream,
                        400,
                        &json!({"error": "invalid_grant"}).to_string(),
                        "application/json",
                    );
                }
                Ok(())
            });
            // A session's token does not open the socket itself, as on the real
            // MC: it buys a ticket.
            refuse_socket(&mut world.mc, "session-2");
            watched(world).connections_before = world.mc.connections.len();
            let shown = notice(world)?;
            let link = shown.item(world, "connectionPairingLink")?;
            let url = format!("{}/pair#token=fresh-1", world.mc.origin());
            shown.write(
                world,
                link,
                "text",
                ljos::prelude::Value::from(url.as_str()),
            )?;
            shown.click(world, "connectionPair")
        },
    );
    steps.step("it reconnects with a new session", |world, _, _| {
        let before = watched(world).connections_before;
        wait_for_reconnect(world, before + 1)?;
        // The new session was bought with the link, and its ticket opened the socket.
        let last = world.mc.connections.last().cloned().unwrap_or_default();
        let ticket = url::Url::parse(&format!("ws://mc{last}"))
            .ok()
            .and_then(|url| {
                url.query_pairs()
                    .find(|(k, _)| k == "wsTicket")
                    .map(|(_, v)| v.into_owned())
            })
            .unwrap_or_default();
        let fake = health(&mut world.mc);
        let bought = fake.pairing_tokens.get("fresh-1").map(String::as_str) == Some("session-2");
        let issued = !ticket.is_empty() && fake.tickets.contains(&ticket);
        expect!(
            bought && issued && !needs_pairing(world),
            "it connected to {last}; the connection is {}",
            show(&connection(world))
        );
        Ok(())
    });
    steps.step("keeps its local view of the environment", |world, _, _| {
        // The thread it showed is still the one it shows, with what it held,
        // and live again.
        world.wait_for_with(|w| status(w) == "live", describe)?;
        let (thread, rows) = (watched(world).thread.clone(), watched(world).rows_before);
        let kept = threads::active(world.engine()) == thread
            && row_count(world)? == rows
            && shows(world, "The cart total includes tax now.")
            && has_thread(world, &thread);
        expect!(
            kept,
            "the window shows {}: {}",
            threads::active(world.engine()),
            describe(world)
        );
        Ok(())
    });

    // Coming to the foreground.
    steps.step("the client is waiting to retry", |world, _, _| {
        go_down(world, &[600_000])?;
        world.mc.start_accepting();
        Ok(())
    });
    steps.step(
        "the app comes to the foreground(?: after a moment)?",
        |world, _, _| {
            let checks = Rc::new(RefCell::new(Vec::new()));
            let heard = checks.clone();
            world
                .client()
                .on_checked(move |alive| heard.borrow_mut().push(alive));
            let connections = world.mc.connections.len();
            let watched = watched(world);
            watched.checks = Some(checks);
            watched.connections_before = connections;
            // Away, then back: the shell's Application.activeChanged runs this.
            world.with::<ConnectionHealth, _>(|c, _| c.wake())?;
            world.pump()
        },
    );
    steps.step("it (?:tries again|connects) at once", |world, _, _| {
        // Ten minutes were left on the retry, or no network to wait for.
        let before = watched(world).connections_before;
        wait_for_reconnect(world, before + 1)
    });
    steps.step("the client checks the connection", |world, _, _| {
        let Some(checks) = watched(world).checks.clone() else {
            fail!("the app never came to the foreground");
        };
        let seen = checks.clone();
        world.wait_for("the connection to be checked", move |_| {
            !seen.borrow().is_empty()
        })?;
        expect!(checks.borrow()[0], "the check found the connection dead");
        Ok(())
    });
    steps.step("keeps it when it answers", |world, _, _| {
        world.sync()?;
        let before = watched(world).connections_before;
        expect!(
            world.mc.connections.len() == before && phase(world) == "connected",
            "the connection was replaced: {} connections, {}",
            world.mc.connections.len(),
            show(&connection(world))
        );
        Ok(())
    });

    // What the client says of its connection.
    steps.step("the socket opens", |world, _, _| {
        world.mc.hold_snapshot = true;
        reconnect(world)?;
        world.wait_for("the socket to open", |w| w.client().is_ready())
    });
    steps.step(
        "the client reports connecting until the environment's configuration arrives",
        |world, _, _| {
            world.sync()?;
            expect!(
                phase(world) == "connecting" && field(world, "status") == "Connecting",
                "before the environment described itself the connection is {}",
                show(&connection(world))
            );
            world.mc.send_snapshot();
            wait_for_phase(world, &["connected"])
        },
    );
    steps.step("its shell subscription fails", |world, _, _| {
        watched(world).connections_before = world.mc.connections.len();
        for id in world.mc.subscribers("shell") {
            world
                .mc
                .send(&json!({"t": "error", "id": id, "reason": "the shell is unavailable"}));
        }
        world.sync()
    });
    steps.step("the client reports the data problem", |world, _, _| {
        wait_for_phase(world, &["problem"])?;
        let said = notice_shows(world, "Could not load projects and threads")?;
        // The MC's own words stay out of it.
        let quiet = !show(&connection(world)).contains("the shell is unavailable");
        expect!(
            field(world, "status") == "Can't load data" && quiet && said,
            "the connection is {}",
            show(&connection(world))
        );
        Ok(())
    });
    steps.step("does not claim to be reconnecting", |world, _, _| {
        let before = watched(world).connections_before;
        expect!(
            world.client().is_ready()
                && world.mc.connections.len() == before
                && !field(world, "status").contains("econnecting")
                && !field(world, "title").contains("econnecting"),
            "the connection is {}",
            show(&connection(world))
        );
        Ok(())
    });
    steps.step(
        "the connection dropped because of a timeout",
        |world, _, _| {
            // The MC's socket stays open and says nothing more; nothing listens
            // for the retry. Whatever it was sending has arrived: any frame
            // answers a ping.
            ensure_connected(world)?;
            world.sync()?;
            world.client().set_retry_delays(ms(&[600_000]));
            world.client().set_pong_timeout(Duration::from_millis(20));
            world.mc.answer_pings = false;
            world.mc.stop_accepting();
            // The client checks one ping at a time: a ping still on its way
            // (the shell's own, on open) keeps its longer deadline, and its
            // late pong answers for this one. Each answer is asked again.
            let answered = Rc::new(Cell::new(false));
            let seen = answered.clone();
            let listener = world.client().on_checked(move |alive| {
                if alive {
                    seen.set(true);
                }
            });
            world.client().wake();
            let dropped = world.wait_for_with(
                |w| {
                    if answered.replace(false) {
                        w.client().wake();
                    }
                    w.client().phase() == Phase::Retrying
                },
                |w| {
                    format!(
                        "the unanswered connection to be dropped; it is {}",
                        show(&connection(w))
                    )
                },
            );
            world.client().remove_listener(listener);
            dropped
        },
    );
    steps.step(&format!("the environment reads {Q}"), |world, c, _| {
        // Once the reconnect is past its grace: until then it reads as connected.
        world.wait_for_with(
            |w| !settling(w),
            |w| {
                format!(
                    "the reconnect to be past its grace; the connection is {}",
                    show(&connection(w))
                )
            },
        )?;
        expect!(
            field(world, "status") == c[0],
            "the connection is {}",
            show(&connection(world))
        );
        // As Connections settings lists it.
        let row = Brick::new(
            world,
            "import QtQuick\nimport HalC2.Bricks\nConnectionStatusRow {}\n",
            640.0,
            40.0,
        )?;
        world.part::<crate::brick::Shown>().0 = Some(row);
        expect!(
            row.shows(world, &c[0])?,
            "Connections settings does not read \"{}\"",
            c[0]
        );
        Ok(())
    });
    steps.step(&format!("the notice says why: {Q}"), |world, c, _| {
        let said = field(world, "detail") == c[0];
        let shown = notice_shows(world, &c[0])?;
        expect!(
            said && shown,
            "the connection is {}",
            show(&connection(world))
        );
        Ok(())
    });
    steps.step(
        &format!("no surface shows the client's own reason {Q}"),
        |world, c, _| {
            let reason = c[0].to_lowercase();
            for key in ["status", "title", "detail"] {
                expect!(
                    !field(world, key).to_lowercase().contains(&reason),
                    "its {key} says {}",
                    show(&connection(world))
                );
            }
            Ok(())
        },
    );

    // The icon. What the controller says of each state is the other
    // scenarios'; these say it as it would and read the window.
    steps.step(
        "the connection is (connecting|retrying after a drop|waiting for the network|refused its credential|on another protocol)",
        |world, c, _| {
            let (phase, state, status) = match c[0].as_str() {
                "connecting" => ("connecting", "connecting", "Connecting"),
                "retrying after a drop" => ("reconnecting", "retrying", "Reconnecting"),
                "waiting for the network" => ("offline", "offline", "Offline"),
                "refused its credential" => ("refused", "needsPairing", "Needs pairing"),
                _ => ("blocked", "blocked", "Update needed"),
            };
            let said = json!({
                "phase": phase, "state": state, "status": status,
                "title": format!("About {}", c[0]), "detail": "What to do.",
                "settling": false, "traceId": "", "canRetry": false,
                "needsPairing": state == "needsPairing", "pairing": false,
                "pairingError": "", "versionWarning": null,
            });
            let engine = world.engine();
            hal_c2_shell::bridge::Bridge::of(engine).publish(engine, "connection", said);
            world.pump()?;
            let brick = Brick::new(
                world,
                "import QtQuick\nimport HalC2.Bricks\nItem { ConnectionNotice {} }\n",
                900.0,
                600.0,
            )?;
            world.part::<crate::brick::Shown>().0 = Some(brick);
            Ok(())
        },
    );
    steps.step(
        &format!("the window shows the (\\S+) icon with {Q}"),
        |world, c, _| {
            let shown = crate::brick::shown(world)?;
            let notice = shown.item(world, "connectionNotice")?;
            let icon_item = shown.item(world, "connectionNoticeIcon")?;
            let icon = shown.text_of(world, icon_item, "name");
            let status_item = shown.item(world, "connectionNoticeStatus")?;
            let status = shown.text_of(world, status_item, "text");
            expect!(
                shown.flag(world, notice, "visible") && icon == c[0] && status == c[1],
                "the notice shows {icon} with \"{status}\""
            );
            Ok(())
        },
    );
    steps.step("hovering it says what is going on", |world, _, _| {
        let shown = crate::brick::shown(world)?;
        let notice = shown.item(world, "connectionNotice")?;
        let tip = shown.text_of(world, notice, "tip");
        expect!(
            tip.starts_with("About ") && tip.ends_with("What to do."),
            "hovering says \"{tip}\""
        );
        Ok(())
    });

    // A reconnect over before its grace is never shown.
    steps.step(
        "the connection drops and comes back at once",
        |world, _, _| {
            world.client().set_retry_delays(ms(&[20]));
            let connections = world.mc.connections.len();
            // Every connection published, not only those a poll lands on.
            let seen = watched(world).down.clone();
            seen.watching.set(true);
            watch_connection(world, seen.clone());
            world.mc.drop_connection();
            world.wait_for_with(
                move |w| w.mc.connections.len() > connections && phase(w) == "connected",
                |w| {
                    format!(
                        "the client to be back; the connection is {}",
                        show(&connection(w))
                    )
                },
            )?;
            seen.watching.set(false);
            expect!(
                seen.saw_down.get(),
                "the controller never saw the connection drop"
            );
            Ok(())
        },
    );
    steps.step("no surface said the connection was down", |world, _, _| {
        let brick = Brick::new(
            world,
            "import QtQuick\nimport HalC2.Bricks\nItem { ConnectionNotice {} }\n",
            900.0,
            600.0,
        )?;
        world.part::<crate::brick::Shown>().0 = Some(brick);
        let notice = brick.item(world, "connectionNotice")?;
        let shown_down = watched(world).down.shown_down.get();
        expect!(
            !shown_down && !brick.flag(world, notice, "visible"),
            "the connection was shown down; it is {}",
            show(&connection(world))
        );
        Ok(())
    });
    // A fresh launch, its first connection never coming up.
    steps.step("the environment takes no connections", |world, _, _| {
        world.mc.stop_accepting();
        Ok(())
    });
    steps.step("the app starts and connects to it", |world, _, _| {
        world.restart()?;
        // A grace long enough that nothing in the scenario could outlast it.
        world.with::<ConnectionHealth, _>(|h, _| h.set_grace(600_000))?;
        let seen = watched(world).down.clone();
        seen.watching.set(true);
        watch_connection(world, seen);
        let origin = world.mc.origin();
        open_at(world, &origin)
    });
    steps.step(
        "within a second and a half the window shows it is not connected",
        |world, _, _| {
            let brick = Brick::new(
                world,
                "import QtQuick\nimport HalC2.Bricks\nItem { ConnectionNotice {} }\n",
                900.0,
                600.0,
            )?;
            world.part::<crate::brick::Shown>().0 = Some(brick);
            let notice = brick.item(world, "connectionNotice")?;
            world.wait_for_with(
                move |w| brick.flag(w, notice, "visible"),
                |w| {
                    format!(
                        "the notice to show; the connection is {}",
                        show(&connection(w))
                    )
                },
            )?;
            let status = field(world, "status");
            let status_item = brick.item(world, "connectionNoticeStatus")?;
            let read = brick.text_of(world, status_item, "text");
            expect!(read == status, "the notice does not read \"{status}\"");
            // And Connections settings reads the same.
            let row = Brick::new(
                world,
                "import QtQuick\nimport HalC2.Bricks\nConnectionStatusRow {}\n",
                640.0,
                40.0,
            )?;
            world.part::<crate::brick::Shown>().0 = Some(row);
            expect!(
                row.shows(world, &status)? && !row.shows(world, "Connected")?,
                "Connections settings does not read \"{status}\"; the connection is {}",
                show(&connection(world))
            );
            Ok(())
        },
    );
    steps.step("nothing said it was connected", |world, _, _| {
        let said = watched(world).down.said_connected.get();
        expect!(
            !said && !settling(world),
            "a surface said it was connected; the connection is {}",
            show(&connection(world))
        );
        Ok(())
    });
    steps.step("a connection that failed", |world, _, _| {
        go_down(world, &[600_000])
    });
    steps.step("the user copies its trace id", |world, _, _| {
        // From the notice's own button; the world records the clipboard.
        let shown = notice(world)?;
        shown.click(world, "connectionCopyTraceId")
    });
    steps.step("the trace id is on the clipboard", |world, _, _| {
        let clipboard = world.clipboard();
        let hex = clipboard.len() == 32
            && clipboard
                .chars()
                .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c));
        expect!(
            hex && clipboard == world.client().status().failure_trace_id
                && clipboard == field(world, "traceId"),
            "the clipboard holds \"{clipboard}\"; the connection is {}",
            show(&connection(world))
        );
        Ok(())
    });

    // What was loaded stays readable.
    steps.step(
        "threads were loaded before the connection dropped",
        |world, _, _| {
            follow_thread(world)?;
            leave_thread(world)?;
            go_down(world, &[600_000])
        },
    );
    steps.step("the user opens one offline", |world, _, _| {
        let thread = watched(world).thread.clone();
        look(world, &thread, false)
    });
    steps.step("the thread shows its cached content", |world, _, _| {
        let rows = watched(world).rows_before;
        expect!(
            row_count(world)? == rows && shows(world, "The cart total includes tax now."),
            "the thread shows {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the client does not claim a live connection",
        |world, _, _| {
            expect!(
                status(world) == "unreachable" && phase(world) == "reconnecting",
                "the thread is {} and the connection {}",
                status(world),
                show(&connection(world))
            );
            Ok(())
        },
    );

    // Removing an environment.
    steps.step(
        "a saved environment with cached threads and drafts",
        |world, _, _| {
            let environment = "Build box";
            let thread = "thread-ops";
            world.mc.join_named(environment);
            world.mc.send_peer_row_of(
                environment,
                "ops",
                &json!({"id": "ops", "title": "ops", "workspaceRoot": "/work/ops", "scripts": []}),
                "project",
            );
            world.mc.send_peer_row(
                environment,
                thread,
                &json!({"id": thread, "title": "Deploy", "projectId": "ops",
                    "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"}),
            );
            world.sync()?;
            // A thread of it loaded and left, and a draft with unsent text.
            let key = format!("{environment}:{thread}");
            {
                let watched = watched(world);
                watched.saved_environment = environment.into();
                watched.thread = key.clone();
            }
            look(world, &key, true)?;
            leave_thread(world)?;
            let draft = drafts::start(world.engine(), environment, "ops").unwrap_or_default();
            drafts::set_text(world.engine(), &draft, "roll back the deploy");
            world.pump()?;
            leave_thread(world)?;
            let opened = {
                let key = key.clone();
                world.with::<ThreadStore, _>(move |c, _| c.timeline(&key).is_some())?
            };
            let kept = opened
                && drafts::draft(world.engine(), &draft).is_some()
                && kept_copy(world, &key).found();
            expect!(kept, "nothing was kept for {environment}");
            Ok(())
        },
    );
    steps.step(
        "its credential, cached data and drafts are cleared",
        |world, _, _| {
            let environment = "Build box";
            world.wait_for("the environment to go", move |w| {
                !store::with(w.engine(), |s| s.serves_environment(environment))
            })?;
            world.sync()?;
            // The credential is the MC's, which is told to drop the member.
            let forgotten = world.mc.calls.iter().any(|rpc| {
                rpc.method == "cluster.remove" && text(&rpc.payload["id"]) == environment
            });
            expect!(
                forgotten && !world.mc.members.iter().any(|m| m == environment),
                "the MC still holds the member"
            );
            let thread = watched(world).thread.clone();
            let rows = store::with(world.engine(), |s| s.project_rows(environment).len());
            let (opened, open) = {
                let key = thread.clone();
                world.with::<ThreadStore, _>(move |c, _| {
                    (c.timeline(&key).is_some(), c.open_threads().contains(&key))
                })?
            };
            expect!(
                !has_thread(world, &thread) && rows == 0 && !opened && !open,
                "its threads are still kept"
            );
            // Its drafts go once the MC has answered the removal.
            let left = move |w: &World| -> Vec<String> {
                drafts::all(w.engine())
                    .into_iter()
                    .filter(|d| d.environment_id == environment)
                    .map(|d| format!("{:?}", d.text))
                    .collect()
            };
            world.wait_for_with(
                |w| left(w).is_empty(),
                |w| format!("its drafts are still kept: {}", left(w).join(", ")),
            )?;
            expect!(
                !kept_copy(world, &thread).found(),
                "the client still keeps a copy of {thread}"
            );
            Ok(())
        },
    );

    // Leaving a thread and coming back.
    steps.step(
        "the user left a thread( more than five minutes ago)?",
        |world, c, _| {
            follow_thread(world)?;
            leave_thread(world)?;
            let subs = stream_subscriptions(world, THREAD);
            watched(world).stream_subs_before = subs;
            if !c[0].is_empty() {
                // On the wall clock and on the shell's, where the thread
                // left is let go.
                let later = world.now() + Span::minutes(6);
                world.set_time(later);
                world.advance(6 * 60 * 1000)?;
            }
            Ok(())
        },
    );
    steps.step(
        "the user returns(?: within five minutes)?",
        |world, _, _| {
            if world.now() == now() {
                let later = world.now() + Span::minutes(4);
                world.set_time(later);
                world.advance(4 * 60 * 1000)?;
            }
            let thread = watched(world).thread.clone();
            look(world, &thread, true)
        },
    );
    steps.step(
        "the client resumes the thread from where it stopped",
        |world, _, _| {
            world.sync()?;
            let (subs, rows) = (
                watched(world).stream_subs_before,
                watched(world).rows_before,
            );
            expect!(
                stream_subscriptions(world, THREAD) == subs && row_count(world)? == rows,
                "the thread was asked for {} times; {}",
                stream_subscriptions(world, THREAD),
                describe(world)
            );
            // And it is still followed: what the agent says next arrives.
            add_item(
                world,
                "assistant_message",
                json!({"text": "Shipping is next."}),
            )?;
            expect!(
                shows(world, "Shipping is next."),
                "the thread shows {}",
                describe(world)
            );
            Ok(())
        },
    );

    // A replaced connection.
    steps.step("a client subscribed to a thread", |world, _, _| {
        follow_thread(world)
    });
    steps.step("the connection is replaced", |world, _, _| {
        let subs = stream_subscriptions(world, THREAD);
        watched(world).stream_subs_before = subs;
        world.mc.drop_connection();
        wait_for_reconnect(world, 2)
    });
    steps.step(
        "the subscription continues on the new connection",
        |world, _, _| {
            let subs = watched(world).stream_subs_before;
            world.wait_for_with(
                move |w| {
                    stream_subscriptions(w, THREAD) == subs + 1
                        && !followers(&w.mc, THREAD).is_empty()
                        && status(w) == "live"
                },
                |w| format!("the thread to be followed again; {}", describe(w)),
            )?;
            add_item(
                world,
                "assistant_message",
                json!({"text": "Shipping is next."}),
            )?;
            expect!(
                shows(world, "Shipping is next."),
                "the thread shows {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user sent a command just before the connection dropped",
        |world, _, _| {
            world.mc.hold("answers");
            let error = watched(world).call_error.clone();
            let environment = world.mc.environment_id.clone();
            let mut command = Map::new();
            command.insert("type".into(), json!("thread.archive"));
            command.insert("threadId".into(), json!(THREAD));
            world
                .client()
                .dispatch_command(&environment, command, move |result| {
                    *error.borrow_mut() = match result {
                        Ok(_) => "answered".into(),
                        Err(e) => e.message,
                    };
                });
            world.wait_for("the command to reach the MC", |w| w.mc.commands.len() == 1)?;
            world.mc.drop_connection();
            world.wait_for("the client to see the drop", |w| !w.client().is_ready())
        },
    );
    steps.step(
        "the command is not sent again automatically",
        |world, _, _| {
            wait_for_reconnect(world, 2)?;
            world.sync()?;
            let error = watched(world).call_error.borrow().clone();
            expect!(
                world.mc.commands.len() == 1 && error == "disconnected",
                "{} commands reached the MC; the sender was told \"{error}\"",
                world.mc.commands.len()
            );
            Ok(())
        },
    );

    // Protocols and versions.
    steps.step(
        "an environment whose MC speaks (a newer|an older) protocol than the client",
        |world, c, _| {
            health(&mut world.mc).protocol = PROTOCOL + if c[0] == "a newer" { 1 } else { -1 };
            Ok(())
        },
    );
    steps.step(
        "an environment whose descriptor declares an unsupported protocol",
        |world, _, _| {
            health(&mut world.mc).protocol = PROTOCOL + 4;
            Ok(())
        },
    );
    steps.step(
        "(?:the connection|it) is blocked(?: before opening a socket)?",
        |world, _, _| {
            wait_for_phase(world, &["blocked"])?;
            world.pump()?;
            let before = watched(world).connections_before;
            expect!(
                world.mc.connections.len() == before && world.client().phase() == Phase::Blocked,
                "a socket was opened: {} connections, {before} before",
                world.mc.connections.len()
            );
            Ok(())
        },
    );
    steps.step(
        "the client says (update HAL-C2 on this device|update HAL-C2 on that environment)",
        |world, c, _| {
            let detail = field(world, "detail");
            let said = notice_shows(world, &detail)?;
            expect!(
                detail.to_lowercase().contains(&c[0].to_lowercase()) && said,
                "the client says \"{detail}\""
            );
            Ok(())
        },
    );
    steps.step("it says which side to update", |world, _, _| {
        let detail = field(world, "detail");
        let said = notice_shows(world, &detail)?;
        expect!(
            detail == "Update HAL-C2 on this device to connect." && said,
            "the client says \"{detail}\""
        );
        Ok(())
    });
    steps.step("this client runs HAL-C2 (\\S+)", |world, c, _| {
        let version = c[0].clone();
        world
            .with::<ConnectionHealth, _>(move |h, engine| h.set_client_version(engine, &version))?;
        world.pump()
    });
    steps.step("the environment's MC runs HAL-C2 (\\S+)", |world, c, _| {
        health(&mut world.mc).server_version = c[0].clone();
        Ok(())
    });
    steps.step("the connection is used as normal", |world, _, _| {
        wait_for_phase(world, &["connected"])?;
        world.sync()?;
        expect!(
            world.client().is_ready() && field(world, "title").is_empty(),
            "the connection is {}",
            show(&connection(world))
        );
        Ok(())
    });
    steps.step(
        "the client (warns of a version mismatch|does not warn)",
        |world, c, _| {
            let warning = connection(world)["versionWarning"].clone();
            let shown = notice(world)?;
            if c[0] == "does not warn" {
                let item = shown.item(world, "connectionNotice")?;
                expect!(
                    warning.is_null() && !shown.flag(world, item, "visible"),
                    "the client warns: {}",
                    show(&warning)
                );
                return Ok(());
            }
            let said = text(&warning["text"]);
            let version = health(&mut world.mc).server_version.clone();
            expect!(
                said.starts_with("Version mismatch")
                    && said.contains(&version)
                    && shown.shows(world, &said)?,
                "the warning is {}",
                show(&warning)
            );
            // Dismissed, it stays away for this pair of versions.
            shown.click(world, "connectionDismissWarning")?;
            expect!(
                connection(world)["versionWarning"].is_null(),
                "the warning stayed"
            );
            Ok(())
        },
    );

    // Events the client does not know.
    steps.step(
        "a connected client does not recognize an event type the MC publishes",
        |world, _, _| {
            ensure_connected(world)?;
            follow_thread(world)?;
            watched(world).connections_before = world.mc.connections.len();
            Ok(())
        },
    );
    steps.step("the MC publishes an event of that type", |world, _, _| {
        // A frame type, a shell change and a thread entity from a later MC.
        for id in world.mc.subscribers("shell") {
            world
                .mc
                .send(&json!({"t": "shell.holograms", "id": id, "holograms": [1, 2]}));
        }
        for id in followers(&world.mc, THREAD) {
            world
                .mc
                .send(&json!({"t": "hologram", "id": id, "event": {}}));
        }
        set(
            world,
            "hologram",
            "hologram-1",
            json!({"id": "hologram-1", "shape": "cube"}),
        )
    });
    steps.step("the client skips the event", |world, _, _| {
        world.sync()?;
        let rows = watched(world).rows_before;
        expect!(
            row_count(world)? == rows && status(world) == "live",
            "the thread shows {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "it keeps its connection and processes the later events it knows",
        |world, _, _| {
            add_item(
                world,
                "assistant_message",
                json!({"text": "Shipping is next."}),
            )?;
            world.mc.send_row(
                "thread-later",
                &json!({"id": "thread-later", "title": "Later", "projectId": PROJECT,
                        "createdAt": "2026-09-23T09:30:00Z", "updatedAt": "2026-09-23T09:30:00Z"}),
            );
            world.sync()?;
            let before = watched(world).connections_before;
            let later = format!("{}:thread-later", world.mc.environment_id);
            expect!(
                world.mc.connections.len() == before
                    && phase(world) == "connected"
                    && shows(world, "Shipping is next.")
                    && has_thread(world, &later),
                "the connection is {} and the thread shows {}",
                show(&connection(world)),
                describe(world)
            );
            Ok(())
        },
    );

    // A cluster over one connection.
    steps.step(
        "a client connected to a cluster of three MCs",
        |world, _, _| {
            ensure_connected(world)?;
            follow_thread(world)?;
            join_member(world, "mc-b", "env-b")?;
            join_member(world, "mc-c", "env-c")
        },
    );
    steps.step(
        "the client keeps one connection for the cluster",
        |world, _, _| {
            let environments = environments(world);
            expect!(
                world.mc.connections.len() == 1 && environments.len() == 3,
                "{} connections for {}",
                world.mc.connections.len(),
                environments.join(", ")
            );
            Ok(())
        },
    );
    steps.step("streams from every MC arrive over it", |world, _, _| {
        follow_member(world, "env-b")?;
        follow_member(world, "env-c")?;
        let followed: HashSet<String> = world
            .mc
            .subscribers("stream")
            .into_iter()
            .map(|id| text(&world.mc.shape_of(id)["environment"]))
            .collect();
        let wanted: HashSet<String> = [
            world.mc.environment_id.clone(),
            "env-b".into(),
            "env-c".into(),
        ]
        .into_iter()
        .collect();
        expect!(
            followed == wanted && world.mc.connections.len() == 1,
            "streams of {followed:?} over {} connections",
            world.mc.connections.len()
        );
        Ok(())
    });
    steps.step(
        "a client paired with a cluster of two machines",
        |world, _, _| {
            ensure_connected(world)?;
            join_member(world, "mc-b", "env-b")
        },
    );
    steps.step("a third machine joins the cluster", |world, _, _| {
        join_member(world, "mc-c", "env-c")
    });
    steps.step(
        "the client lists the third machine's environment within a minute",
        |world, _, _| {
            // As soon as the cluster announces it: nothing is polled for.
            let environments = environments(world);
            expect!(
                environments.iter().any(|e| e == "env-c")
                    && has_thread(world, "env-c:thread-env-c"),
                "the client knows {}",
                environments.join(", ")
            );
            let projects: Vec<String> = world.state("sidebar")["projects"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|p| text(&p["displayName"]))
                .collect();
            expect!(
                projects.iter().any(|p| p == "env-c"),
                "the sidebar lists {}",
                projects.join(", ")
            );
            Ok(())
        },
    );
    steps.step("reaches it with the same credential", |world, _, _| {
        follow_member(world, "env-c")?;
        let first = world.mc.connections.first().cloned().unwrap_or_default();
        let token = url::Url::parse(&format!("ws://mc{first}"))
            .ok()
            .and_then(|url| {
                url.query_pairs()
                    .find(|(k, _)| k == "token")
                    .map(|(_, v)| v.into_owned())
            })
            .unwrap_or_default();
        expect!(
            world.mc.connections.len() == 1 && token == "mc-token",
            "it took {} connections",
            world.mc.connections.len()
        );
        Ok(())
    });
    steps.step(
        "a client following threads on two cluster members",
        |world, _, _| {
            ensure_connected(world)?;
            follow_thread(world)?;
            let seq = world.mc.part::<FakeStreams>().seq;
            watched(world).offsets.insert(THREAD.into(), seq);
            join_member(world, "mc-b", "env-b")?;
            follow_member(world, "env-b")?;
            // The member's thread moves on, past where the first one stopped.
            {
                let streams = world.mc.part::<FakeStreams>();
                streams.thread = "thread-env-b".into();
                streams.environment = "env-b".into();
            }
            add_item(world, "assistant_message", json!({"text": "Deployed."}))?;
            let seq = world.mc.part::<FakeStreams>().seq;
            let watched = watched(world);
            watched.offsets.insert("thread-env-b".into(), seq);
            let first = watched.offsets.get(THREAD).copied().unwrap_or_default();
            expect!(first != seq, "both threads stopped at {seq}");
            Ok(())
        },
    );
    steps.step("the cluster connection drops and returns", |world, _, _| {
        // Here it counts the subscriptions before, not the connections.
        watched(world).connections_before = world.mc.subscriptions.len();
        world.mc.drop_connection();
        wait_for_reconnect(world, 2)?;
        world.sync()
    });
    steps.step(
        "each thread stream resumes from its last offset",
        |world, _, _| {
            let from = watched(world).connections_before;
            let mut resumed: HashMap<String, Value> = HashMap::new();
            for sub in world.mc.subscriptions.iter().skip(from) {
                if sub.pointer("/shape/type").and_then(Value::as_str) == Some("stream") {
                    resumed.insert(text(&sub["shape"]["stream"]), sub["offset"].clone());
                }
            }
            let offsets = watched(world).offsets.clone();
            for (thread, offset) in offsets {
                let got = resumed.get(&thread).cloned().unwrap_or(Value::Null);
                expect!(
                    got.as_i64() == Some(offset),
                    "{thread} stopped at {offset} and resumed from {}",
                    show(&got)
                );
            }
            Ok(())
        },
    );
    steps.step("the thread list asks only for the rows changed since", |world, _, _| {
        let from = watched(world).connections_before;
        let shell = world
            .mc
            .subscriptions
            .iter()
            .skip(from)
            .rfind(|sub| sub.pointer("/shape/type").and_then(Value::as_str) == Some("shell"))
            .cloned()
            .unwrap_or(Value::Null);
        // It says what it holds of each member, and none of them sends its
        // rows again.
        let have = &shell["have"];
        let answer = world.mc.shell_frames.last().cloned().unwrap_or(Value::Null);
        let resets = answer["mcs"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|mc| mc["reset"].as_bool() == Some(true))
            .count();
        let rows_empty = answer["rows"].as_array().is_none_or(Vec::is_empty);
        let snapshots = store::with(world.engine(), |s| s.snapshots());
        expect!(
            have.get(&world.mc.name).is_some()
                && have.get("mc-b").is_some()
                && resets == 0
                && rows_empty
                && snapshots == 2,
            "the thread list was asked for with {} and answered with {} ({snapshots} snapshots)",
            show(&shell),
            show(&answer)
        );
        // What it held is still there.
        let own = format!("{}:{THREAD}", world.mc.environment_id);
        expect!(
            has_thread(world, "env-b:thread-env-b") && has_thread(world, &own),
            "a thread went missing"
        );
        Ok(())
    });
}

/// What one scenario of desktop-qt's ConnectionClientSteps.h keeps between
/// its steps.
#[derive(Default)]
struct ClientScenario {
    /// Whether the retry recorder is on.
    recording: bool,
    /// The last retry delay before the client connected, in ms.
    last_delay: u64,
    /// Retries seen before the step acting.
    delays_before: usize,
    /// Attempts the client started (Connecting).
    attempts: Option<Rc<Cell<u32>>>,
    attempts_before: u32,
    /// What the client said when it stopped.
    message: String,
    pings: Rc<Cell<u32>>,
}

fn client_scenario(world: &mut World) -> &mut ClientScenario {
    world.part::<ClientScenario>()
}

/// From now on every retry the client schedules is in `retry_delays`.
fn record_retries(world: &mut World) {
    if std::mem::replace(&mut client_scenario(world).recording, true) {
        return;
    }
    let delays = watched(world).retry_delays.clone();
    let last = Cell::new(0u32);
    world.client().on_status(move |status| {
        if status.phase == Phase::Retrying && status.retries != last.get() {
            last.set(status.retries);
            delays
                .borrow_mut()
                .push(status.retry_delay.as_millis() as u64);
        }
    });
}

/// From now on each attempt the client starts is counted.
fn count_attempts(world: &mut World) -> Rc<Cell<u32>> {
    if let Some(attempts) = client_scenario(world).attempts.clone() {
        return attempts;
    }
    let attempts = Rc::new(Cell::new(0u32));
    let counted = attempts.clone();
    let was = Cell::new(world.client().phase());
    world.client().on_status(move |status| {
        if status.phase == Phase::Connecting && was.get() != Phase::Connecting {
            counted.set(counted.get() + 1);
        }
        was.set(status.phase);
    });
    client_scenario(world).attempts = Some(attempts.clone());
    attempts
}

fn retries_seen(world: &mut World) -> Vec<u64> {
    watched(world).retry_delays.borrow().clone()
}

/// What the client says of its connections: the environment it started
/// with, then each saved environment that is not connected.
fn said(world: &World) -> String {
    let now = connection(world);
    let mut words = vec![
        text(&now["status"]),
        text(&now["title"]),
        text(&now["detail"]),
    ];
    let saved = world.state("savedEnvironments");
    for environment in saved["environments"].as_array().into_iter().flatten() {
        let message = text(&environment["message"]);
        if !message.is_empty() {
            words.push(message);
        }
    }
    words.join(" | ")
}

fn describe_client(world: &World) -> String {
    let status = world.client().status();
    format!(
        "{} (client {:?}, failure \"{}\", message \"{}\", {} sockets)",
        said(world),
        status.phase,
        status.failure,
        status.failure_message,
        world.mc.connections.len()
    )
}

fn wait_for_client(world: &mut World, phases: &'static [Phase]) -> Outcome {
    world.wait_for_with(
        move |w| phases.contains(&w.client().phase()),
        move |w| format!("the client to be {phases:?}; it is {}", describe_client(w)),
    )
}

/// From now on the client's credential needs a socket ticket, and the MC
/// answers the ticket request with `status` and `body`.
fn answer_tickets(world: &mut World, status: u16, body: &'static str, kind: &'static str) {
    world.mc.on_raw("/ws?token=", |_, stream, _| {
        answer(stream, 401, "unauthorized", "text/plain");
        Ok(())
    });
    world
        .mc
        .on_raw("/api/auth/websocket-ticket", move |_, stream, _| {
            answer(stream, status, body, kind);
            Ok(())
        });
}

/// A thread of `environment`'s, opened, and renamed: a command for that
/// environment.
fn ask_to_do_something(world: &mut World, environment: &str) -> Outcome {
    ensure_connected(world)?;
    let project = format!("project-{environment}");
    let thread = format!("thread-{environment}");
    world.mc.send_peer_row_of(
        environment,
        &project,
        &json!({"id": project, "title": project, "workspaceRoot": format!("/work/{project}"),
                "scripts": []}),
        "project",
    );
    world.mc.send_peer_row(
        environment,
        &thread,
        &json!({"id": thread, "title": "Tax line", "projectId": project,
                "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"}),
    );
    let key = format!("{environment}:{thread}");
    let listed = key.clone();
    world.wait_for_with(
        move |w| has_thread(w, &listed),
        move |w| {
            format!(
                "the thread of {} to be listed; {}",
                w.mc.members.join(", "),
                describe_client(w)
            )
        },
    )?;
    let route = Route::Thread(key.clone());
    world.with::<Navigation, _>(|n, engine| n.open(engine, route))?;
    world.wait_for("the thread to open", move |w| {
        threads::active(w.engine()) == key
    })?;
    world.dispatch("workspace.rename", json!({"title": "Tax line, itemised"}))
}

fn renames(world: &World, environment: &str) -> usize {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| {
            rpc.method == "orchestration.dispatchCommand"
                && rpc.environment == environment
                && rpc.payload["type"] == "thread.metadata.update"
        })
        .count()
}

fn wait_for_rename(world: &mut World, environment: &str) -> Outcome {
    let environment = environment.to_owned();
    world.wait_for_with(
        move |w| renames(w, &environment) == 1,
        |w| {
            format!(
                "the command to reach the MC; it was asked {:?}",
                w.mc.calls
                    .iter()
                    .map(|rpc| rpc.method.clone())
                    .collect::<Vec<_>>()
            )
        },
    )
}

fn toasted(world: &World, description: &str) -> bool {
    world.state("toasts")["items"]
        .as_array()
        .into_iter()
        .flatten()
        .any(|toast| toast["description"] == description)
}
/// The opening traffic is over, answers and all, so any frame the MC
/// sends from here on is a new one: a round trip that brings no new
/// request leaves none in flight.
fn quiet(world: &mut World) -> Outcome {
    let asked = |w: &World| {
        let calls = w.mc.calls.iter();
        calls.filter(|c| c.method != "test.barrier").count() + w.mc.subscriptions.len()
    };
    for _ in 0..20 {
        let before = asked(world);
        world.sync()?;
        if asked(world) == before {
            return Ok(());
        }
    }
    fail!("the MC is still asked something new at every round trip")
}

fn register_client(steps: &mut Steps) {
    // What the environment answers.
    steps.step(
        "the client is connecting to an environment",
        |world, _, _| {
            record_retries(world);
            // The real delays' shape, short enough to watch three of.
            world.client().set_retry_delays(ms(&[5, 10, 20, 40, 80]));
            Ok(())
        },
    );
    steps.step(
        "the environment (says the credential is invalid|rejects the authentication request|has no such authentication endpoint|answers with an internal error|answers with something that is not a reply)|the credential lacks a scope the connection needs",
        |world, c, _| {
            let answer = c.first().cloned().unwrap_or_default();
            if answer.is_empty() {
                answer_tickets(world, 403, r#"{"_tag":"EnvironmentScopeRequiredError"}"#, "application/json");
            } else if answer.starts_with("says") {
                answer_tickets(world, 401, r#"{"_tag":"EnvironmentAuthInvalidError"}"#, "application/json");
            } else if answer.starts_with("rejects") {
                answer_tickets(world, 400, r#"{"_tag":"EnvironmentAuthRequestError"}"#, "application/json");
            } else if answer.starts_with("has no") {
                answer_tickets(world, 404, "<html>Not found</html>", "text/html");
            } else if answer.contains("internal error") {
                answer_tickets(world, 500, r#"{"_tag":"InternalError"}"#, "application/json");
            } else {
                answer_tickets(world, 200, "<html>Sign in</html>", "text/html");
            }
            watched(world).connections_before = world.mc.connections.len();
            reconnect(world)
        },
    );
    steps.step(&format!("the status says {Q}"), |world, c, _| {
        let wanted = c[0].clone();
        let shown = wanted.clone();
        world.wait_for_with(
            move |w| said(w).contains(&wanted),
            move |w| format!("\"{shown}\"; the status is {}", describe_client(w)),
        )
    });

    // An address that answers as another environment.
    steps.step(&format!("{Q} was saved at an address"), |world, _, _| {
        record_retries(world);
        ensure_connected(world)
    });
    steps.step(
        "a different environment now answers at that address",
        |world, _, _| {
            world.mc.environment_id = "env-elsewhere".into();
            Ok(())
        },
    );
    steps.step(
        "the status says the connected environment does not match the saved one",
        |world, _, _| {
            world.wait_for_with(
                |w| said(w).contains("Connected environment env-elsewhere does not match"),
                |w| format!("the mismatch; the status is {}", describe_client(w)),
            )
        },
    );
    steps.step("the client does not keep retrying", |world, _, _| {
        let delays = retries_seen(world).len();
        world.pump()?;
        let before = watched(world).connections_before;
        expect!(
            world.client().phase() == Phase::Blocked
                && retries_seen(world).len() == delays
                && world.mc.connections.len() == before,
            "the client went on: {}",
            describe_client(world)
        );
        Ok(())
    });

    // The foreground check.
    steps.step(
        "an established connection that has silently died",
        |world, _, _| {
            record_retries(world);
            ensure_connected(world)?;
            quiet(world)?;
            // Ten minutes to any retry: a new connection before then was not one.
            world.client().set_retry_delays(ms(&[600_000]));
            world.client().set_pong_timeout(Duration::from_secs(600));
            world.client().set_probe_timeout(Duration::from_millis(50));
            // Dead, not slow: it says nothing more on this socket, since any
            // frame would answer the check.
            world.mc.answer_pings = false;
            world.mc.silent = true;
            Ok(())
        },
    );
    steps.step(
        "the environment does not answer the check within 15 seconds",
        |world, _, _| {
            expect!(
                hal_c2_mc::DEFAULT_PROBE_TIMEOUT == Duration::from_secs(15),
                "the check waits {:?}",
                hal_c2_mc::DEFAULT_PROBE_TIMEOUT
            );
            let Some(checks) = watched(world).checks.clone() else {
                fail!("the app never came to the foreground");
            };
            let seen = checks.clone();
            world.wait_for_with(
                move |_| seen.borrow().contains(&false),
                move |w| {
                    format!(
                        "the check to fail; checks {:?}; {}",
                        checks.borrow(),
                        describe_client(w)
                    )
                },
            )
        },
    );
    steps.step(
        "the client opens a new connection without waiting out a retry delay",
        |world, _, _| {
            let before = watched(world).connections_before;
            wait_for_reconnect(world, before + 1)?;
            let failure = world.client().status().failure;
            expect!(
                failure.is_empty(),
                "the client is {}",
                describe_client(world)
            );
            Ok(())
        },
    );
    steps.step(
        "a second failure in a row goes back to the growing delays",
        |world, _, _| {
            // The replacement fails its check too, and the one after it
            // cannot connect.
            let delays = retries_seen(world).len();
            quiet(world)?;
            world.mc.silent = true;
            world.mc.stop_accepting();
            world.with::<ConnectionHealth, _>(|c, _| c.wake())?;
            let recorded = watched(world).retry_delays.clone();
            world.wait_for_with(
                move |_| recorded.borrow().len() > delays,
                |w| {
                    format!(
                        "a retry to be scheduled; the client is {}",
                        describe_client(w)
                    )
                },
            )?;
            let delay = retries_seen(world)[delays];
            expect!(
                delay == 600_000 && world.client().phase() == Phase::Retrying,
                "the retry waits {delay} ms; the client is {}",
                describe_client(world)
            );
            Ok(())
        },
    );

    // The setup timer.
    steps.step(
        "the environment accepts the connection but never finishes introducing itself",
        |world, _, _| {
            record_retries(world);
            ensure_connected(world)?;
            world.client().set_retry_delays(ms(&[600_000, 1_200_000]));
            world.client().set_setup_timeout(Duration::from_millis(50));
            world.mc.say_hello = false;
            watched(world).connections_before = world.mc.connections.len();
            world.client().reconnect();
            Ok(())
        },
    );
    // "15 seconds pass" is toast.rs' clock step; the client's own setup
    // timer, shortened above, is what this waits out.
    steps.step(
        "the attempt is abandoned and reported as a timeout",
        |world, _, _| {
            expect!(
                hal_c2_mc::DEFAULT_SETUP_TIMEOUT == Duration::from_secs(15),
                "the setup waits {:?}",
                hal_c2_mc::DEFAULT_SETUP_TIMEOUT
            );
            wait_for_client(world, &[Phase::Retrying])?;
            world.wait_for_with(
                |w| phase(w) == "reconnecting",
                |w| format!("the shell to say reconnecting; {}", describe_client(w)),
            )?;
            let before = watched(world).connections_before;
            expect!(
                world.mc.connections.len() > before
                    && world.client().status().failure == "timeout"
                    && said(world).contains("It stopped answering."),
                "the client is {}",
                describe_client(world)
            );
            Ok(())
        },
    );
    steps.step("the client retries after the usual delay", |world, _, _| {
        let delay = world.client().status().retry_delay;
        expect!(
            delay == Duration::from_millis(600_000),
            "the retry waits {delay:?}"
        );
        Ok(())
    });

    // The steady timer.
    steps.step(
        "the client has already failed to connect several times",
        |world, _, _| {
            record_retries(world);
            ensure_connected(world)?;
            world
                .client()
                .set_retry_delays(ms(&[5, 10, 20, 40, 80, 160, 320, 640, 1280, 2560]));
            let delays = retries_seen(world).len();
            world.mc.stop_accepting();
            world.mc.drop_connection();
            let recorded = watched(world).retry_delays.clone();
            world.wait_for_with(
                move |_| recorded.borrow().len() >= delays + 3,
                |w| format!("three retries; the client is {}", describe_client(w)),
            )
        },
    );
    steps.step("it connects", |world, _, _| {
        let connections = world.mc.connections.len();
        world.mc.start_accepting();
        wait_for_reconnect(world, connections + 1)?;
        let last = retries_seen(world).last().copied().unwrap_or_default();
        client_scenario(world).last_delay = last;
        Ok(())
    });
    steps.step(
        "the connection drops after (40|5) seconds",
        |world, c, _| {
            expect!(
                hal_c2_mc::DEFAULT_STEADY_AFTER == Duration::from_secs(30),
                "a connection holds after {:?}",
                hal_c2_mc::DEFAULT_STEADY_AFTER
            );
            if c[0] == "40" {
                // The 30 s have run out: the timer, restarted at nothing, goes
                // off before the drop reaches the client.
                world.client().set_steady_after(Duration::ZERO);
            } else {
                world.client().set_steady_after(Duration::from_secs(600));
            }
            let before = retries_seen(world).len();
            client_scenario(world).delays_before = before;
            world.mc.stop_accepting();
            world.mc.drop_connection();
            Ok(())
        },
    );
    steps.step(
        "the next retry waits (the shortest delay|the next longer delay than before)",
        |world, c, _| {
            let before = client_scenario(world).delays_before;
            let recorded = watched(world).retry_delays.clone();
            world.wait_for_with(
                move |_| recorded.borrow().len() > before,
                |w| format!("a retry; the client is {}", describe_client(w)),
            )?;
            let delay = retries_seen(world)[before];
            let last = client_scenario(world).last_delay;
            let ok = if c[0] == "the shortest delay" {
                delay == 5
            } else {
                delay > last
            };
            expect!(
                ok,
                "the retry waits {delay} ms; the last before connecting waited {last}"
            );
            Ok(())
        },
    );

    // Tried again on foregrounding.
    steps.step("the client stopped retrying", |world, _, _| {
        count_attempts(world);
        watched(world).connections_before = world.mc.connections.len();
        reconnect(world)?;
        wait_for_client(world, &[Phase::Refused, Phase::Blocked])?;
        let attempts = count_attempts(world).get();
        let message = said(world);
        let scenario = client_scenario(world);
        scenario.attempts_before = attempts;
        scenario.message = message;
        Ok(())
    });
    steps.step("the client tries to connect once more", |world, _, _| {
        let attempts = count_attempts(world);
        let before = client_scenario(world).attempts_before;
        let seen = attempts.clone();
        world.wait_for_with(
            move |w| {
                seen.get() == before + 1
                    && matches!(w.client().phase(), Phase::Refused | Phase::Blocked)
            },
            move |w| {
                format!(
                    "one more attempt; there were {} and the client is {}",
                    attempts.get() - before,
                    describe_client(w)
                )
            },
        )
    });
    steps.step(
        "stays blocked with the same reason if the environment still refuses",
        |world, _, _| {
            world.pump()?;
            let attempts = count_attempts(world).get();
            let scenario = client_scenario(world);
            let (before, message) = (scenario.attempts_before, scenario.message.clone());
            let connections = watched(world).connections_before;
            expect!(
                attempts == before + 1
                    && said(world) == message
                    && world.mc.connections.len() == connections,
                "it said \"{message}\" before, and is {}",
                describe_client(world)
            );
            Ok(())
        },
    );

    // Calls.
    steps.step(
        &format!("the user asks {Q} to do something"),
        |world, c, _| {
            ask_to_do_something(world, &c[0])?;
            wait_for_rename(world, &c[0])
        },
    );
    steps.step("the request is not queued for later", |world, _, _| {
        let environment = world.mc.members.last().cloned().unwrap_or_default();
        world.mc.set_online(&environment, true);
        world.sync()?;
        let asked = renames(world, &environment);
        expect!(asked == 1, "{environment} was asked {asked} times");
        Ok(())
    });
    // "25 seconds pass" is toast.rs' clock step; the client's ping interval,
    // shortened here once its default is checked, is what the Then waits out.
    steps.step(
        "a connected client with nothing open that streams",
        |world, _, _| {
            ensure_connected(world)?;
            expect!(
                hal_c2_mc::DEFAULT_PING_INTERVAL == Duration::from_secs(25),
                "the client pings every {:?}",
                hal_c2_mc::DEFAULT_PING_INTERVAL
            );
            let pings = client_scenario(world).pings.clone();
            world.mc.on_frame("ping", move |mc, _| {
                pings.set(pings.get() + 1);
                mc.send(&json!({"t": "pong"}));
                Ok(())
            });
            world.client().set_ping_interval(Duration::from_millis(10));
            Ok(())
        },
    );
    steps.step("the client has pinged the MC", |world, _, _| {
        let pings = client_scenario(world).pings.clone();
        world.wait_for("a ping", move |_| pings.get() > 0)
    });
    steps.step(
        &format!("the user asked {Q} to do something and it has not answered"),
        |world, c, _| {
            record_retries(world);
            ensure_connected(world)?;
            world.mc.join_named(&c[0]);
            world.mc.hold("answers");
            ask_to_do_something(world, &c[0])?;
            wait_for_rename(world, &c[0])
        },
    );
    steps.step(&format!("the connection to {Q} drops"), |world, _, _| {
        watched(world).connections_before = world.mc.connections.len();
        world.mc.drop_connection();
        Ok(())
    });
    steps.step("the action fails as disconnected", |world, _, _| {
        world.wait_for_with(
            |w| toasted(w, "disconnected"),
            |w| {
                format!(
                    "the rename to fail; the toasts are {}",
                    show(&w.state("toasts"))
                )
            },
        )
    });
    steps.step(
        "it is not sent again on the new connection",
        |world, _, _| {
            let before = watched(world).connections_before;
            wait_for_reconnect(world, before + 1)?;
            world.mc.answer_held();
            world.sync()?;
            let environment = world.mc.members.last().cloned().unwrap_or_default();
            let asked = renames(world, &environment);
            expect!(asked == 1, "{environment} was asked {asked} times");
            Ok(())
        },
    );
}

// Slow requests: the "Some requests are slow" warning (SlowRequests).

const SLOW: &str = "Some requests are slow";

/// The calls the scenario leaves unanswered, and when each was asked.
#[derive(Default)]
struct HeldCalls {
    held: Vec<crate::fake_mc::Rpc>,
    asked_at: HashMap<String, chrono::DateTime<chrono::Utc>>,
}

fn slow_controller<R>(
    world: &World,
    f: impl FnOnce(&hal_c2_shell::controllers::slow_requests::SlowRequests) -> R,
) -> Option<R> {
    hal_c2_shell::controller::with::<hal_c2_shell::controllers::slow_requests::SlowRequests, _>(
        world.engine(),
        |c, _| f(c),
    )
}

/// The MC leaves `method` unanswered from here on, and the shell asks it.
fn ask(world: &mut World, method: &str) -> Outcome {
    world.mc.on_rpc(method, |mc, rpc| {
        mc.part::<HeldCalls>().held.push(rpc.clone());
        Ok(())
    });
    let now = world.now();
    world
        .mc
        .part::<HeldCalls>()
        .asked_at
        .insert(method.to_owned(), now);
    let Some(mc) = hal_c2_shell::controller::mc(world.engine()) else {
        fail!("the shell has no MC");
    };
    let environment = world.client().environment();
    mc.call(&environment, method, json!({}), Box::new(|_, _| {}));
    let wanted = method.to_owned();
    world.wait_for_with(
        |w| {
            w.mc.peek::<HeldCalls>()
                .is_some_and(|h| h.held.iter().any(|rpc| rpc.method == wanted))
        },
        |_| format!("the MC to be asked {method}"),
    )
}

/// The wall clock and the shell's move on `seconds`.
/// The shell's timers run through `seconds` first, its wall clock moving
/// with them, and then every clock stops at the end: pinning the wall clock
/// first would have the timers read it that much later again.
fn pass(world: &mut World, seconds: i64) -> Outcome {
    let later = world.now() + Span::seconds(seconds);
    world.advance(seconds.unsigned_abs() * 1000)?;
    world.set_time(later);
    world.pump()
}

fn slow_warning(world: &World) -> Option<Value> {
    world.state("toasts")["items"]
        .as_array()?
        .iter()
        .find(|t| t["title"] == SLOW)
        .cloned()
}

fn describe_toasts(world: &World) -> String {
    let slow = slow_controller(world, |c| {
        c.requests()
            .slow()
            .iter()
            .map(|r| r.method.clone())
            .collect::<Vec<_>>()
            .join(", ")
    })
    .unwrap_or_default();
    format!(
        "the toasts are {}; the slow requests are {slow}",
        show(&world.state("toasts"))
    )
}

fn wait_for_warning(world: &mut World) -> Outcome<Value> {
    world.wait_for_with(|w| slow_warning(w).is_some(), describe_toasts)?;
    Ok(slow_warning(world).unwrap_or(Value::Null))
}

fn answer_held(world: &mut World, index: usize) -> Outcome {
    let held = world.mc.part::<HeldCalls>().held.clone();
    let Some(rpc) = held.get(index) else {
        fail!("only {} requests wait", held.len());
    };
    world.mc.reply(rpc, Value::Null);
    world.pump()
}

fn environment_label(world: &World) -> String {
    let environment = world.client().environment();
    let label = store::with(world.engine(), |s| {
        s.environment(&environment)
            .get("label")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned()
    });
    if label.is_empty() { environment } else { label }
}

fn register_slow(steps: &mut Steps) {
    steps.step("the client is connected to the MC", |world, _, _| {
        // The clock is the scenario's from here on.
        let now = world.now();
        world.set_time(now);
        ensure_connected(world)?;
        // The client's own startup calls are answered before the clock moves.
        world.wait_for_with(
            |w| slow_controller(w, |c| c.requests().tracking() == 0).unwrap_or(false),
            |_| "the client's startup calls to be answered".to_owned(),
        )
    });
    steps.step(
        "a request to the MC is not answered for 15 seconds",
        |world, _, _| {
            ask(world, "projects.searchEntries")?;
            pass(world, 15)?;
            wait_for_warning(world)?;
            let slow = slow_controller(world, |c| c.requests().slow().len()).unwrap_or(0);
            expect!(slow == 1, "{}", describe_toasts(world));
            Ok(())
        },
    );
    steps.step(
        "two requests to the MC have not been answered for 15 seconds",
        |world, _, _| {
            let now = world.now();
            world.set_time(now);
            ensure_connected(world)?;
            ask(world, "projects.searchEntries")?;
            ask(world, "git.listBranches")?;
            pass(world, 15)?;
            wait_for_warning(world).map(|_| ())
        },
    );
    steps.step("(\\d+) minutes? pass(?:es)?", |world, c, _| {
        pass(world, c[0].parse::<i64>().unwrap_or(0) * 60)
    });
    steps.step("(\\d+) minutes? and (\\d+) seconds? pass", |world, c, _| {
        let seconds = c[0].parse::<i64>().unwrap_or(0) * 60 + c[1].parse::<i64>().unwrap_or(0);
        pass(world, seconds)
    });
    steps.step("(\\d+) more seconds? pass(?:es)?", |world, c, _| {
        pass(world, c[0].parse().unwrap_or(0))
    });
    steps.step(
        "the warning is still shown until the request is answered",
        |world, _, _| {
            world.sync()?;
            let warning = slow_warning(world);
            expect!(
                warning.is_some_and(|w| w["description"] == "1 request waiting longer than 15s."),
                "{}",
                describe_toasts(world)
            );
            answer_held(world, 0)?;
            world.wait_for_with(|w| slow_warning(w).is_none(), describe_toasts)
        },
    );
    steps.step(
        "the user shows the requests in the warning",
        |world, _, _| {
            let warning = wait_for_warning(world)?;
            let action = warning["actions"]
                .as_array()
                .and_then(|a| a.iter().find(|a| a["label"] == "Show requests"))
                .cloned();
            let Some(action) = action else {
                fail!("the warning offers no Show requests: {}", show(&warning));
            };
            world.dispatch(
                "notification.action",
                json!({"id": warning["id"], "actionId": action["id"]}),
            )
        },
    );
    steps.step(
        "the warning lists each request by its method and environment",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    slow_warning(w)
                        .is_some_and(|t| t["rows"].as_array().is_some_and(|r| r.len() == 2))
                },
                describe_toasts,
            )?;
            let label = environment_label(world);
            let warning = slow_warning(world).unwrap_or(Value::Null);
            let mut methods = Vec::new();
            for row in warning["rows"].as_array().into_iter().flatten() {
                methods.push(text(&row["label"]));
                expect!(
                    text(&row["text"]).starts_with(&format!("{label} · ")),
                    "the row {} does not name {label}",
                    show(row)
                );
            }
            methods.sort();
            expect!(
                methods == ["git.listBranches", "projects.searchEntries"],
                "{}",
                describe_toasts(world)
            );
            Ok(())
        },
    );
    steps.step("says when each request started", |world, _, _| {
        let warning = slow_warning(world).unwrap_or(Value::Null);
        let asked = world.mc.part::<HeldCalls>().asked_at.clone();
        for row in warning["rows"].as_array().into_iter().flatten() {
            let Some(at) = asked.get(&text(&row["label"])) else {
                fail!("the row {} is no request asked", show(row));
            };
            let when =
                hal_c2_shell::controllers::slow_requests::started_text(at.timestamp_millis());
            expect!(
                text(&row["text"]).ends_with(&when),
                "the row {} does not say \"{when}\"",
                show(row)
            );
        }
        Ok(())
    });
    steps.step("one of them is answered", |world, _, _| {
        answer_held(world, 0)
    });
    steps.step("the other is answered", |world, _, _| answer_held(world, 1));
    steps.step(&format!("the warning says {Q}"), |world, c, _| {
        let wanted = c[0].clone();
        world.wait_for_with(
            |w| slow_warning(w).is_some_and(|t| t["description"] == wanted.as_str()),
            describe_toasts,
        )
    });
    steps.step("the warning is gone", |world, _, _| {
        world.wait_for_with(|w| slow_warning(w).is_none(), describe_toasts)
    });
    steps.step("the user updates a provider", |world, _, _| {
        let now = world.now();
        world.set_time(now);
        ensure_connected(world)?;
        // What Providers settings' Update asks; it installs before it answers.
        ask(world, "server.updateProvider")
    });
    steps.step("the user sees no warning", |world, _, _| {
        world.sync()?;
        expect!(slow_warning(world).is_none(), "{}", describe_toasts(world));
        Ok(())
    });
    steps.step(
        "a pull request lookup is not answered for (\\d+) minutes",
        |world, c, _| {
            let now = world.now();
            world.set_time(now);
            ensure_connected(world)?;
            ask(world, "pullRequests.detail")?;
            pass(world, c[0].parse::<i64>().unwrap_or(0) * 60)
        },
    );
    steps.step(
        "a live subscription is not answered for (\\d+) minutes",
        |world, c, _| {
            // A shape the MC never answers.
            let Some(mc) = hal_c2_shell::controller::mc(world.engine()) else {
                fail!("the shell has no MC");
            };
            mc.subscribe(json!({"type": "pending"}), Box::new(|_, _| {}), None);
            world.sync()?;
            pass(world, c[0].parse::<i64>().unwrap_or(0) * 60)
        },
    );
}

// --- The thread's notice about its computer ----------------------------------
// ComputerSwitchSteps.cpp and ConnectionNoticeSteps.cpp's computers: a
// cluster member's thread, drawn by the ThreadView brick, and the notice
// ComputerNotice publishes as `threadComputer`.

/// The computer whose thread the scenario opened last, what the notice
/// offered a second before its 20 seconds, and the ThreadView drawn.
#[derive(Default)]
struct ComputerShown {
    name: String,
    offered: (bool, bool),
    view: Option<Brick>,
    answering: bool,
}

const RECONNECT: &str = "threadComputerReconnect";
const DISCONNECT: &str = "threadComputerDisconnect";

fn computer_shown(world: &mut World) -> &mut ComputerShown {
    world.part::<ComputerShown>()
}

fn computer_view(world: &mut World) -> Outcome<Brick> {
    if let Some(view) = computer_shown(world).view {
        return Ok(view);
    }
    let view = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n",
        820.0,
        560.0,
    )?;
    computer_shown(world).view = Some(view);
    Ok(view)
}

fn computer(world: &World) -> Value {
    world.state("threadComputer")
}

fn describe_computer(world: &World) -> String {
    format!(
        "threadComputer is {}; the toasts are {}",
        show(&computer(world)),
        show(&world.state("toasts"))
    )
}

/// The MC's cluster answers a switch and a reconnect: off drops the member
/// as the shell is told, a reconnect has the MC try it again.
fn answer_switches(world: &mut World) {
    if std::mem::replace(&mut computer_shown(world).answering, true) {
        return;
    }
    world.mc.on_rpc("cluster.switch", |mc, rpc| {
        let id = text(&rpc.payload["id"]);
        if rpc.payload["on"] == json!(false) {
            mc.remove(&id);
        }
        mc.reply(rpc, json!({}));
        Ok(())
    });
    world.mc.on_rpc("cluster.reconnect", |mc, rpc| {
        let id = text(&rpc.payload["id"]);
        mc.set_trying(&id, true);
        mc.reply(rpc, json!({"status": "reconnecting"}));
        Ok(())
    });
}

/// The MC refuses `method` from here on, saying `reason`, as the thread's
/// notice reports it.
fn refuse_switch(world: &mut World, method: &str, reason: &str) {
    answer_switches(world);
    let said = reason.to_owned();
    world.mc.on_rpc(method, move |mc, rpc| {
        mc.refuse_with(
            rpc,
            &said,
            json!({"_tag": "ClusterError", "reason": "unreachable"}),
        );
        Ok(())
    });
    // "the user is told ... with the reason" reads the one refusal.
    world.mc.refusals.clear();
    world
        .mc
        .refusals
        .insert(method.to_owned(), reason.to_owned());
}

/// The cluster member `name` (its environment's id and label), with a
/// thread of it open.
fn look_at_computer(world: &mut World, name: &str) -> Outcome {
    ensure_connected(world)?;
    computer_view(world)?;
    answer_switches(world);
    world
        .mc
        .peer_labels
        .insert(name.to_owned(), name.to_owned());
    join_member(world, &format!("mc-{name}"), name)?;
    follow_member(world, name)?;
    computer_shown(world).name = name.to_owned();
    Ok(())
}

/// `name`'s MC goes down or comes back, as the shell is told.
fn set_computer_online(world: &mut World, name: &str, online: bool) -> Outcome {
    world.mc.set_online(name, online);
    let (name, shown) = (name.to_owned(), name.to_owned());
    world.wait_for_with(
        move |w| store::with(w.engine(), |s| s.environment_online(&name)) == online,
        move |w| {
            format!(
                "{} to be {}; {}",
                shown,
                if online { "online" } else { "offline" },
                describe_computer(w)
            )
        },
    )
}

/// `name` has been down, the MC still trying it, for `seconds`, with its
/// thread open.
fn down_for(world: &mut World, name: &str, seconds: i64) -> Outcome {
    if computer_shown(world).name != name {
        look_at_computer(world, name)?;
    }
    set_computer_online(world, name, false)?;
    pass(world, seconds)
}

fn computer_button(world: &mut World, name: &str) -> Outcome<bool> {
    let view = computer_view(world)?;
    world.sync()?;
    Ok(view.find_visible(world, name)?.is_some())
}

fn wait_for_button(world: &mut World, name: &'static str, shown: bool) -> Outcome {
    let view = computer_view(world)?;
    world.wait_for_with(
        move |w| view.find_visible(w, name).ok().flatten().is_some() == shown,
        move |w| {
            format!(
                "{name} to be {}; {}",
                if shown { "shown" } else { "hidden" },
                describe_computer(w)
            )
        },
    )
}

fn click_button(world: &mut World, name: &'static str) -> Outcome {
    wait_for_button(world, name, true)?;
    let view = computer_view(world)?;
    view.click(world, name)?;
    world.sync()
}

fn computer_asked(world: &World, method: &str) -> Option<Value> {
    world
        .mc
        .calls
        .iter()
        .find(|rpc| rpc.method == method)
        .map(|rpc| rpc.payload.clone())
}

fn route_kind(world: &World) -> String {
    text(&world.state("route")["kind"])
}

/// The thread's notice about its computer, once its title reads `title`.
fn computer_notice(world: &mut World, title: &str) -> Outcome {
    let view = computer_view(world)?;
    let wanted = title.to_owned();
    world.wait_for_with(
        move |w| {
            view.find_visible(w, "threadComputerNotice")
                .ok()
                .flatten()
                .is_some()
                && view
                    .find_visible(w, "threadComputerTitle")
                    .ok()
                    .flatten()
                    .is_some_and(|item| view.text_of(w, item, "text") == wanted)
        },
        |w| format!("the thread to say \"{title}\"; {}", describe_computer(w)),
    )
}

/// Whether the open thread's notice about its computer says `title` (the
/// run notice steps' "the thread says" asks it when the notice is not about
/// background work).
pub fn computer_notice_says(world: &mut World, title: &str) -> Outcome {
    computer_notice(world, title)
}

fn machine(world: &World, name: &str) -> Value {
    world.state("serverUpdates")["machines"]
        .as_array()
        .and_then(|machines| {
            machines
                .iter()
                .find(|m| m["environmentId"] == json!(name))
                .cloned()
        })
        .unwrap_or(Value::Null)
}

/// `name` runs `version`, and this app 1.4.0; `self_update` is how it
/// updates itself, empty to leave it to its user.
fn runs(world: &mut World, name: &str, version: &str, self_update: &str) -> Outcome {
    let mut capabilities = json!({"desktopAppUpdate": true});
    if !self_update.is_empty() {
        capabilities["serverSelfUpdate"] = json!(self_update);
    }
    world.mc.descriptor_fields.insert(
        name.to_owned(),
        json!({"serverVersion": version, "capabilities": capabilities}),
    );
    world.mc.join(&format!("mc-{name}"), name);
    world.with::<ConnectionHealth, _>(|h, engine| h.set_client_version(engine, "1.4.0"))?;
    let (name, version) = (name.to_owned(), version.to_owned());
    world.wait_for_with(
        |w| {
            machine(w, &name)["version"] == json!(version)
                && w.state("serverUpdates")["appVersion"] == json!("1.4.0")
        },
        |w| {
            format!(
                "{name} on {version}; serverUpdates is {}",
                show(&w.state("serverUpdates"))
            )
        },
    )
}

fn no_toasts(world: &World) -> bool {
    world.state("toasts")["items"]
        .as_array()
        .is_none_or(Vec::is_empty)
}

fn register_computer(steps: &mut Steps) {
    steps.step(
        &format!("the user is looking at a thread on the saved computer {Q}"),
        |world, c, _| look_at_computer(world, &c[0]),
    );
    steps.step(
        &format!("{Q} has been offline or reconnecting for 20 seconds"),
        |world, c, _| {
            down_for(world, &c[0], 0)?;
            world.mc.set_trying(&c[0], false);
            pass(world, 19)?;
            wait_for_button(world, RECONNECT, true)?;
            let offered = (
                computer_button(world, RECONNECT)?,
                computer_button(world, DISCONNECT)?,
            );
            computer_shown(world).offered = offered;
            pass(world, 1)
        },
    );
    steps.step(
        &format!("the notice about {Q} offers to disconnect it"),
        |world, c, _| {
            wait_for_button(world, DISCONNECT, true)?;
            expect!(
                computer(world)["environmentId"] == json!(c[0]),
                "{}",
                describe_computer(world)
            );
            Ok(())
        },
    );
    steps.step(
        "before 20 seconds it offers only to reconnect",
        |world, _, _| {
            let (reconnect, disconnect) = computer_shown(world).offered;
            expect!(
                reconnect && !disconnect,
                "at 19 seconds the notice offered reconnect {reconnect}, disconnect {disconnect}"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user is looking at a thread on {Q} that has been unavailable for 15 seconds"),
        |world, c, _| down_for(world, &c[0], 15),
    );
    steps.step(
        &format!("the user opens a thread on {Q} that is also unavailable"),
        |world, c, _| {
            look_at_computer(world, &c[0])?;
            set_computer_online(world, &c[0], false)
        },
    );
    steps.step(
        &format!("disconnecting {Q} is offered only 20 seconds after it became unavailable"),
        |world, c, _| {
            // Past the 20 seconds of the computer shown before it.
            pass(world, 5)?;
            wait_for_button(world, DISCONNECT, false)?;
            pass(world, 14)?;
            wait_for_button(world, DISCONNECT, false)?;
            pass(world, 1)?;
            wait_for_button(world, DISCONNECT, true)?;
            expect!(
                computer(world)["environmentId"] == json!(c[0]),
                "{}",
                describe_computer(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("a thread on {Q} which has been unavailable for 10 seconds"),
        |world, c, _| down_for(world, &c[0], 10),
    );
    steps.step(&format!("{Q} connects again"), |world, c, _| {
        set_computer_online(world, &c[0], true)
    });
    steps.step(
        &format!("no offer to disconnect {Q} is shown"),
        |world, _, _| {
            // Past 20 seconds from when it first dropped.
            pass(world, 15)?;
            let offered = computer_button(world, DISCONNECT)?;
            expect!(
                !offered && computer(world).is_null(),
                "{}",
                describe_computer(world)
            );
            Ok(())
        },
    );
    steps.step(
        "if it drops again the 20 seconds start over",
        |world, _, _| {
            let name = computer_shown(world).name.clone();
            set_computer_online(world, &name, false)?;
            pass(world, 19)?;
            wait_for_button(world, DISCONNECT, false)?;
            pass(world, 1)?;
            wait_for_button(world, DISCONNECT, true)
        },
    );
    steps.step(
        "the user is looking at a thread on (the computer serving this client|a backend running on this same desktop)",
        |world, c, _| {
            if c[0].starts_with("the computer") {
                ensure_connected(world)?;
                computer_view(world)?;
                let project = json!({"id": PROJECT, "title": PROJECT,
                                     "workspaceRoot": format!("/work/{PROJECT}"), "scripts": []});
                world.mc.projects.insert(PROJECT.into(), project.clone());
                world.mc.send_row_of(PROJECT, &project, "project");
                return look_at_thread(world, PROJECT);
            }
            // Another MC of the cluster that says it runs on this machine.
            world.mc.peer_platforms.insert(
                "desk".into(),
                json!({"machineId": crate::world::THIS_MACHINE}),
            );
            look_at_computer(world, "desk")
        },
    );
    steps.step(
        "(the computer serving this client|a backend running on this same desktop) has been unavailable for more than 20 seconds",
        |world, c, _| {
            if c[0].starts_with("the computer") {
                go_down(world, &[600_000])?;
            } else {
                set_computer_online(world, "desk", false)?;
            }
            pass(world, 25)
        },
    );
    steps.step(
        "the notice does not offer to disconnect it",
        |world, _, _| {
            let offered = computer_button(world, DISCONNECT)?;
            let notice = computer(world);
            expect!(
                !offered && notice["canDisconnect"] != json!(true),
                "{}",
                describe_computer(world)
            );
            // A backend of the cluster still has its notice: it is only the
            // offer that is missing.
            if !notice.is_null() {
                expect!(
                    !text(&notice["kind"]).is_empty(),
                    "{}",
                    describe_computer(world)
                );
            }
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} has been unavailable for 20 seconds"),
        |world, c, _| {
            down_for(world, &c[0], 20)?;
            wait_for_button(world, DISCONNECT, true)
        },
    );
    steps.step(&format!("switching {Q} off will fail"), |world, c, _| {
        refuse_switch(
            world,
            "cluster.switch",
            &format!("{} could not be told it is switched off.", c[0]),
        );
        Ok(())
    });
    steps.step(
        "the user chooses to disconnect it from the thread's notice",
        |world, _, _| click_button(world, DISCONNECT),
    );
    steps.step(
        &format!("{Q} is switched off in connections"),
        |world, c, _| {
            let name = c[0].clone();
            world.wait_for_with(
                |w| {
                    computer_asked(w, "cluster.switch")
                        .is_some_and(|p| p["id"] == json!(name) && p["on"] == json!(false))
                },
                |w| {
                    format!(
                        "the MC to be asked to switch {} off; it was asked {}",
                        c[0],
                        show(&computer_asked(w, "cluster.switch").unwrap_or(Value::Null))
                    )
                },
            )
        },
    );
    steps.step("its threads are hidden", |world, _, _| {
        let name = computer_shown(world).name.clone();
        world.wait_for_with(
            |w| !name.is_empty() && !store::with(w.engine(), |s| s.serves_environment(&name)),
            |w| format!("the shell to drop it; {}", describe_computer(w)),
        )
    });
    steps.step("the user is taken to the home screen", |world, _, _| {
        world.wait_for_with(
            |w| route_kind(w) == "home",
            |w| format!("the route is {}", show(&w.state("route"))),
        )
    });
    steps.step("the user stays on the thread", |world, _, _| {
        world.sync()?;
        expect!(
            route_kind(world) == "thread",
            "the route is {}",
            show(&world.state("route"))
        );
        Ok(())
    });
    // "{Q} is offline" (the usage steps) leaves the computer down; its
    // thread is opened here.
    steps.step("reconnecting will fail", |world, _, _| {
        refuse_switch(world, "cluster.reconnect", "This machine is not clustered.");
        let name = world.mc.offline.iter().next().cloned().unwrap_or_default();
        if !name.is_empty() && computer_shown(world).name != name {
            // Its thread opens while it answers, then it is given up on.
            world.mc.set_online(&name, true);
            ensure_connected(world)?;
            down_for(world, &name, 0)?;
            world.mc.set_trying(&name, false);
        }
        wait_for_button(world, RECONNECT, true)
    });
    steps.step(
        "the user chooses to reconnect it from the thread's notice",
        |world, _, _| click_button(world, RECONNECT),
    );
    steps.step(&format!("{Q} stops trying to connect"), |world, c, _| {
        set_computer_online(world, &c[0], false)?;
        world.mc.set_trying(&c[0], false);
        world.sync()
    });
    steps.step("the user can ask it to reconnect", |world, _, _| {
        let name = text(&computer(world)["environmentId"]);
        click_button(world, RECONNECT)?;
        world.wait_for("the MC to be asked to reconnect", |w| {
            computer_asked(w, "cluster.reconnect").is_some()
        })?;
        let asked = computer_asked(world, "cluster.reconnect").unwrap_or(Value::Null);
        expect!(
            asked["id"] == json!(name),
            "it was asked to reconnect {} for {name}",
            show(&asked)
        );
        // Trying again, the notice no longer says it is offline.
        world.wait_for_with(
            |w| computer(w)["kind"] != json!("offline"),
            describe_computer,
        )
    });
    steps.step(
        &format!("the user is looking at a thread on {Q}"),
        |world, c, _| look_at_computer(world, &c[0]),
    );
    steps.step(
        &format!("{Q} drops and reconnects within two seconds"),
        |world, c, _| {
            set_computer_online(world, &c[0], false)?;
            pass(world, 1)?;
            set_computer_online(world, &c[0], true)?;
            // Past when a notice would have shown.
            pass(world, 5)
        },
    );
    steps.step(
        &format!("the thread shows no notice about {Q}"),
        |world, _, _| {
            let notice = computer_button(world, "threadComputerNotice")?;
            let problem = computer_button(world, "threadProblem")?;
            expect!(
                computer(world).is_null() && !notice && !problem,
                "{}",
                describe_computer(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("{Q} has been reconnecting for more than two seconds"),
        |world, c, _| {
            set_computer_online(world, &c[0], false)?;
            // Inside the two seconds the thread says nothing.
            pass(world, 1)?;
            let notice = computer_button(world, "threadComputerNotice")?;
            let problem = computer_button(world, "threadProblem")?;
            expect!(
                !notice && !problem,
                "a second in: {}",
                describe_computer(world)
            );
            pass(world, 2)
        },
    );
    steps.step(
        "reconnecting by hand is not offered while it is already trying",
        |world, _, _| {
            let notice = computer_button(world, "threadComputerNotice")?;
            let reconnect = computer_button(world, RECONNECT)?;
            let disconnect = computer_button(world, DISCONNECT)?;
            let retry = computer_button(world, "threadRetry")?;
            expect!(notice, "{}", describe_computer(world));
            expect!(
                !reconnect && !disconnect && !retry,
                "a reconnect is offered; {}",
                describe_computer(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("an update of {Q} is running"), |world, c, _| {
        runs(world, &c[0], "1.3.0", "boot-service")?;
        // Its Update in Connections settings; the MC holds the answer until
        // the update is done.
        world.mc.on_rpc("server.updateServer", |_, _| Ok(()));
        world.dispatch("serverUpdates.update", json!({"environmentId": c[0]}))?;
        let name = c[0].clone();
        world.wait_for_with(
            |w| {
                machine(w, &name)["updating"] == json!(true)
                    && w.mc
                        .calls
                        .iter()
                        .any(|rpc| rpc.method == "server.updateServer" && rpc.environment == name)
            },
            |w| {
                format!(
                    "the update of {}; serverUpdates is {}",
                    c[0],
                    show(&w.state("serverUpdates"))
                )
            },
        )
    });
    steps.step(
        &format!("{Q} drops and starts reconnecting"),
        |world, c, _| {
            set_computer_online(world, &c[0], false)?;
            // Long enough for a reconnect warning to show, were it to.
            pass(world, 5)
        },
    );
    steps.step("the thread shows the update's progress", |world, _, _| {
        let id = text(&computer(world)["environmentId"]);
        let label = text(&machine(world, &id)["label"]);
        let name = if label.is_empty() {
            "studio".to_owned()
        } else {
            label
        };
        computer_notice(world, &format!("Updating {name}"))
    });
    steps.step(
        &format!("no notice says {Q} is reconnecting"),
        |world, c, _| {
            let problem = computer_button(world, "threadProblem")?;
            let title = text(&computer(world)["title"]);
            expect!(
                title != format!("{} is reconnecting", c[0])
                    && !problem
                    && slow_warning(world).is_none()
                    && no_toasts(world),
                "{}",
                describe_computer(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!(
            "{Q} runs a different version than this client and no update is known to be running"
        ),
        |world, c, _| {
            // Newer than this app: the restart of an update made elsewhere.
            runs(world, &c[0], "1.5.0", "")?;
            expect!(
                machine(world, &c[0])["updating"] != json!(true),
                "an update of {} is running",
                c[0]
            );
            Ok(())
        },
    );
    steps.step(&format!("no notice says {Q}"), |world, c, _| {
        world.sync()?;
        let notice = computer(world);
        let view = computer_view(world)?;
        let said = view.shows(world, &c[0])?;
        expect!(
            !text(&notice["title"]).contains(&c[0])
                && !text(&notice["detail"]).contains(&c[0])
                && !said
                && no_toasts(world),
            "{}",
            describe_computer(world)
        );
        Ok(())
    });
}

// A kept copy the client cannot read (desktop-qt's ConnectionCacheSteps.cpp).

const OLD_ANSWER: &str = "The cart total includes tax.";
const NEW_ANSWER: &str = "The cart total includes tax and shipping.";
const GARBLED: &str = "{\"id\": \"assistant_message:";

/// The thread a cache scenario kept, the turn item it garbled, and how many
/// `sub` frames the MC had read when the app started again.
#[derive(Default)]
struct KeptThread {
    thread: String,
    item: String,
    /// How many `sub`s the MC had answered when live data arrived.
    asked_before: usize,
    /// Where the live data stood.
    live: i64,
}

fn kept_thread(world: &mut World) -> &mut KeptThread {
    world.mc.part::<KeptThread>()
}

/// Runs `sql` with `values` on the client's cache file, from outside the
/// app: the rows it changed, or the first column of a count.
fn on_kept_file(world: &World, sql: &str, values: &[&dyn rusqlite::ToSql]) -> Outcome<i64> {
    let path = world.home_dir().join("cache/client-cache.sqlite");
    let db = rusqlite::Connection::open(&path).map_err(|e| Failure(format!("{path:?}: {e}")))?;
    let result = if sql.trim_start().starts_with("SELECT") {
        db.query_row(sql, values, |row| row.get::<_, i64>(0))
    } else {
        db.execute(sql, values).map(|n| n as i64)
    };
    result.map_err(|e| Failure(format!("{sql}: {e}")))
}

/// The cache has answered what the shell asked of it.
fn drain_cache(world: &World) {
    threads::drain(world.engine());
}

/// The scenario's thread, listed as `title` and followed, with one settled
/// turn; then left, so the app does not open it when it starts, and kept.
fn keep_thread(world: &mut World, title: &str) -> Outcome {
    look_at_thread(world, PROJECT)?;
    let mut row = world.mc.threads.get(THREAD).cloned().unwrap_or(Value::Null);
    row["title"] = json!(title);
    world.mc.threads.insert(THREAD.into(), row.clone());
    world.mc.send_row(THREAD, &row);
    world.sync()?;
    super::stream::start_run(world, 60, "running")?;
    let item = add_item(world, "assistant_message", json!({"text": OLD_ANSWER}))?;
    super::stream::settle_run(world, "completed", 30)?;
    world.sync()?;
    let thread = format!("{}:{THREAD}", world.mc.environment_id);
    *kept_thread(world) = KeptThread {
        thread: thread.clone(),
        item,
        asked_before: 0,
        live: 0,
    };
    world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Home))?;
    world.sync()?;
    world.advance(store::FLUSH_DELAY_MS + 100)?;
    drain_cache(world);
    expect!(
        kept_copy(world, &thread).found(),
        "the client kept no copy of {thread}"
    );
    Ok(())
}

/// The app starts on the files it left and is pointed at its MC, and is up on its rows.
fn start_on_mc(world: &mut World) -> Outcome {
    world.launch();
    drain_cache(world);
    let session = hal_c2_shell::session::Session {
        origin: world.mc.origin(),
        token: "mc-token".into(),
        label: String::new(),
        environment_id: String::new(),
    };
    hal_c2_shell::open(world.engine(), &session).map_err(Failure)?;
    drain_cache(world);
    world.wait_for("the shell to start on its MC's rows", |w| {
        w.active() && store::with(w.engine(), |s| s.synchronized())
    })?;
    world.sync()
}

/// The thread follows its MC again, and the client has read what it was sent.
fn settle_thread(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| w.active() && super::stream::timeline_object(w).is_ok() && status(w) == "live",
        |w| format!("the thread to follow its MC; {}", describe(w)),
    )?;
    world.sync()
}

fn last_asked_kept(world: &mut World) -> Outcome<usize> {
    let fake = world.mc.part::<FakeStreams>();
    match fake.asked.iter().rposition(|a| a.thread == fake.thread) {
        Some(index) => Ok(index),
        None => fail!("the MC was never asked for {}", fake.thread),
    }
}

fn shows_text(world: &World, text: &str) -> bool {
    (0..row_count(world).unwrap_or(0)).any(|row| role(world, row, "text") == json!(text))
}

/// The MC's answer to a `sub` of the whole scenario thread, as it frames it.
fn whole_answer(world: &mut World) -> Vec<Value> {
    let fake = world.mc.part::<FakeStreams>();
    let rows: Vec<Value> = fake
        .threads
        .get(THREAD)
        .into_iter()
        .flatten()
        .filter_map(|(key, entity)| {
            let (kind, id) = key.split_once('\n')?;
            Some(json!([kind, id, entity]))
        })
        .collect();
    vec![
        json!({"t": "snapshot", "offset": fake.seq, "rows": rows, "done": true, "handle": fake.handle}),
        json!({"t": "live", "offset": fake.seq, "handle": fake.handle}),
    ]
}

fn register_kept(steps: &mut Steps) {
    // Cached data against live data.
    steps.step(
        "the client reconnects while cached data loads",
        |world, _, _| {
            keep_thread(world, "Tax line")?;
            world.quit()?;
            // While the app was closed the answer changed on the MC.
            let item = kept_thread(world).item.clone();
            set(world, "turn-item", &item, json!({"text": NEW_ANSWER}))?;
            start_on_mc(world)
        },
    );
    steps.step("live data arrives first", |world, _, _| {
        // The thread opens: its kept copy is being read. Here, not in the
        // step before: the pump after each step hands back what the cache
        // read, and the live data comes first.
        let thread = kept_thread(world).thread.clone();
        world.with::<ThreadStore, _>(move |s, engine| s.open(engine, &thread))?;
        expect!(
            super::stream::timeline_object(world).is_ok() && row_count(world)? == 0,
            "the kept copy was read at once: {}",
            describe(world)
        );
        let model = super::stream::timeline_object(world)?;
        let live = world.mc.part::<FakeStreams>().seq;
        kept_thread(world).live = live;
        for frame in whole_answer(world) {
            let frame = frame.as_object().cloned().unwrap_or_default();
            TimelineModel::update(world.engine(), model, |t| t.receive(&frame));
        }
        // What the MC was asked before: the client follows the thread once
        // the copy is in.
        let asked = world.mc.part::<FakeStreams>().asked.len();
        kept_thread(world).asked_before = asked;
        // Then the copy the cache read.
        drain_cache(world);
        world.sync()
    });
    steps.step(
        "the older cached data is not applied over it",
        |world, _, _| {
            // The live data shows the thread as live already: it is followed
            // once the MC is asked for it.
            let before = kept_thread(world).asked_before;
            world.wait_for("the client to follow the thread", move |w| {
                w.mc.peek::<FakeStreams>()
                    .is_some_and(|fake| fake.asked.len() > before)
            })?;
            settle_thread(world)?;
            expect!(
                shows_text(world, NEW_ANSWER) && !shows_text(world, OLD_ANSWER),
                "the thread shows {}",
                describe(world)
            );
            // And the client goes on from where the live data stands, not the copy.
            let asked = last_asked_kept(world)?;
            let fake = world.mc.part::<FakeStreams>();
            let sub = fake.asked[asked].sub.clone();
            let offsets: Vec<_> = fake
                .asked
                .iter()
                .map(|a| a.sub["offset"].clone())
                .collect();
            let live = kept_thread(world).live;
            let fake = world.mc.part::<FakeStreams>();
            expect!(
                sub["offset"].as_i64() == Some(live),
                "it asked with offset {} where the live data stood at {live} (the MC at {}; asked {offsets:?}, {before} before): {}",
                sub["offset"],
                fake.seq,
                show(&sub)
            );
            Ok(())
        },
    );

    steps.step(
        &format!("the client kept a copy of {Q} that it can no longer read"),
        |world, c, _| {
            keep_thread(world, &c[0])?;
            world.quit()?;
            let KeptThread { thread, item, .. } = std::mem::take(kept_thread(world));
            let garbled = on_kept_file(
                world,
                "UPDATE entities SET json = ? WHERE thread = ? AND kind = 'turn-item' AND id = ?",
                &[&GARBLED.as_bytes(), &thread, &item],
            )?;
            *kept_thread(world) = KeptThread {
                thread,
                item,
                asked_before: 0,
                live: 0,
            };
            expect!(garbled == 1, "{garbled} rows of the copy were garbled");
            start_on_mc(world)
        },
    );
    steps.step(
        &format!("the user opens {Q} while connected"),
        |world, c, _| {
            let thread = kept_thread(world).thread.clone();
            let title = store::with(world.engine(), |s| {
                s.thread_row(&thread)
                    .and_then(|row| row.get("title"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned()
            });
            expect!(
                title == c[0],
                "the thread list holds no {} ({thread} is {title:?})",
                c[0]
            );
            look(world, &thread, false)
        },
    );
    steps.step("the kept copy is removed", |world, _, _| {
        settle_thread(world)?;
        // The copy was never resumed from: the client asked for the thread whole.
        let asked = last_asked_kept(world)?;
        let sub = world.mc.part::<FakeStreams>().asked[asked].sub.clone();
        expect!(
            !sub["offset"].is_number() && sub["handle"].as_str().unwrap_or_default().is_empty(),
            "it asked with {}",
            show(&sub)
        );
        drain_cache(world);
        let left = on_kept_file(
            world,
            "SELECT count(*) FROM entities WHERE json = ?",
            &[&GARBLED.as_bytes()],
        )?;
        expect!(left == 0, "{left} unreadable rows are still kept");
        Ok(())
    });
    steps.step(
        &format!("{Q} loads from the MC as if nothing had been kept"),
        |world, _, _| {
            settle_thread(world)?;
            let asked = last_asked_kept(world)?;
            let snapshots = super::stream::answer_to(world, asked, "snapshot");
            expect!(
                snapshots.len() == 1
                    && shows_text(world, OLD_ANSWER)
                    && shows_text(world, "Add a tax line to the cart"),
                "the MC sent {} snapshots and the thread shows {}",
                snapshots.len(),
                describe(world)
            );
            Ok(())
        },
    );
}

/// The whole window as the user's shell draws it, `qml` being that shell;
/// connected, with a project so the welcome wizard stays away.
fn window(world: &mut World, qml: &str) -> Outcome<Brick> {
    if let Some(brick) = world.part::<crate::brick::Shown>().0 {
        return Ok(brick);
    }
    if world.shell_subscriptions() == 0 {
        if world.mc.projects.is_empty() {
            world.mc.projects.insert(
                "p1".to_owned(),
                json!({"id": "p1", "title": "p1", "workspaceRoot": "/work/p1", "scripts": []}),
            );
        }
        world.connect()?;
        world.sync()?;
    }
    Brick::show(world, qml, 1200.0, 800.0)?;
    crate::brick::shown(world)
}

const DEFAULT_SHELL: &str = "import HalC2.Bricks\nDefaultShell { width: 1200; height: 800 }\n";

/// The visible items named `name`, in document order.
fn shown_named(world: &World, brick: Brick, name: &str) -> Outcome<Vec<ObjectId>> {
    let mut found = Vec::new();
    while let Some(item) = brick.find_visible_nth(world, name, found.len())? {
        found.push(item);
    }
    Ok(found)
}

/// From here on the MC takes no connection: a drop stays a drop, and the
/// client is slow to try again.
fn stays_away(world: &mut World) {
    world.client().set_retry_delays(ms(&[600_000]));
    world.mc.stop_accepting();
}

/// The window's notice, once the drop is past its grace and it shows.
fn reconnecting_notice(world: &mut World, brick: Brick) -> Outcome<ObjectId> {
    world.wait_for_with(
        move |w| {
            field(w, "state") == "retrying"
                && shown_named(w, brick, "connectionNotice").is_ok_and(|f| !f.is_empty())
        },
        |w| {
            format!(
                "the notice of a reconnect; the connection is {}",
                show(&connection(w))
            )
        },
    )?;
    let found = shown_named(world, brick, "connectionNotice")?;
    expect!(
        found.len() == 1,
        "{} connection notices are shown",
        found.len()
    );
    Ok(found[0])
}

/// `item`'s rectangle in the window: left, top, right, bottom.
fn rect(world: &World, brick: Brick, item: ObjectId) -> Outcome<(f64, f64, f64, f64)> {
    let (left, top) = brick.at_px(world, item, 0.0, 0.0)?;
    let size = |name: &str| match brick.read(world, item, name) {
        ljos::prelude::Value::Int(n) => f64::from(n),
        ljos::prelude::Value::Real(r) => r,
        _ => 0.0,
    };
    Ok((left, top, left + size("width"), top + size("height")))
}

fn register_window(steps: &mut Steps) {
    // A dropped connection, in the real window.
    steps.step("the user is reading a thread", |world, _, _| {
        window(world, DEFAULT_SHELL)?;
        let project = json!({"id": PROJECT, "title": PROJECT,
                             "workspaceRoot": format!("/work/{PROJECT}"), "scripts": []});
        world.mc.projects.insert(PROJECT.into(), project.clone());
        world.mc.send_row_of(PROJECT, &project, "project");
        look_at_thread(world, PROJECT)?;
        stays_away(world);
        Ok(())
    });
    steps.step(
        "the user's shell fills its window with the built-in layout",
        |world, _, _| {
            // As DefaultLayout's own comment tells a user to.
            window(
                world,
                "import QtQuick\nimport HalC2.Bricks\n\
                 ShellWindow { id: root; width: 1200; height: 800; \
                 DefaultLayout { anchors.fill: parent; window: root } }\n",
            )?;
            stays_away(world);
            Ok(())
        },
    );
    steps.step(
        "one notice says the environment is being reconnected(, with one Try again)?",
        |world, c, _| {
            let brick = window(world, DEFAULT_SHELL)?;
            let notice = reconnecting_notice(world, brick)?;
            if c[0].is_empty() {
                return Ok(());
            }
            // Its panel, as a click on its icon opens it.
            brick.write(world, notice, "open", ljos::prelude::Value::Bool(true))?;
            world.wait_for("the notice to offer Try again", move |w| {
                shown_named(w, brick, "connectionRetry").is_ok_and(|f| !f.is_empty())
            })?;
            let retries = shown_named(world, brick, "connectionRetry")?.len()
                + shown_named(world, brick, "threadRetry")?.len();
            expect!(retries == 1, "{retries} ways to retry are shown");
            Ok(())
        },
    );
    steps.step(
        "the thread does not say its MC cannot be reached",
        |world, _, _| {
            let brick = window(world, DEFAULT_SHELL)?;
            world.sync()?;
            expect!(
                shown_named(world, brick, "threadProblem")?.is_empty(),
                "the thread says its MC cannot be reached"
            );
            Ok(())
        },
    );
    steps.step(
        "the notice covers neither the window controls, the header nor the thread",
        |world, _, _| {
            let brick = window(world, DEFAULT_SHELL)?;
            let notice = reconnecting_notice(world, brick)?;
            // Its icon and the panel opened from it alike.
            for open in [false, true] {
                brick.write(world, notice, "open", ljos::prelude::Value::Bool(open))?;
                world.wait_for_with(
                    move |w| rect(w, brick, notice).is_ok_and(|r| (r.3 - r.1 > 40.0) == open),
                    move |_| {
                        format!(
                            "the notice's panel to be {}",
                            if open { "open" } else { "closed" }
                        )
                    },
                )?;
                let (l, t, r, b) = rect(world, brick, notice)?;
                for name in ["workspace", "routeView", "threadSidebar"] {
                    let others = shown_named(world, brick, name)?;
                    let Some(other) = others.first() else {
                        fail!("the window has no {name}");
                    };
                    let (ol, ot, or, ob) = rect(world, brick, *other)?;
                    expect!(
                        !(l < or && ol < r && t < ob && ot < b),
                        "the {} notice lies over {name}",
                        if open { "open" } else { "closed" }
                    );
                }
            }
            Ok(())
        },
    );
}

/// Renewing a credential for an HTTP request: what one scenario counted.
#[derive(Default)]
struct Renewal {
    /// Renewals the MC was asked for.
    renewals: usize,
    /// Requests that reached the MC past their renewal.
    reached: usize,
    connections_before: usize,
    /// The request's answer: None while it has none, then its error ("" if none).
    answered: Rc<RefCell<Option<String>>>,
}

/// The client asks something of the MC over HTTP, its credential about to
/// run out, and the MC answers the renewal with `status`.
fn request_while_expiring(world: &mut World, status: u16) -> Outcome {
    ensure_connected(world)?;
    world
        .mc
        .on_raw("/api/auth/session/renew", move |mc, stream, _| {
            mc.part::<Renewal>().renewals += 1;
            let body = if status >= 300 {
                json!({"_tag": "EnvironmentAuthInvalidError", "reason": "auth_invalid"})
            } else {
                json!({"expiresAt": (chrono::Utc::now() + Span::days(30)).to_rfc3339()})
            };
            answer(stream, status, &body.to_string(), "application/json");
            Ok(())
        });
    world.mc.on_http("/api/catalog/probe", |mc, _, respond| {
        mc.part::<Renewal>().reached += 1;
        respond.send(200, &json!({"ok": true}));
        Ok(())
    });
    world
        .client()
        .set_credential_expiry(Some(chrono::Utc::now() + Span::seconds(60)));
    let before = world.mc.connections.len();
    let answered = Rc::new(RefCell::new(None));
    {
        let renewal = world.mc.part::<Renewal>();
        renewal.connections_before = before;
        renewal.answered = answered.clone();
    }
    let reply = answered.clone();
    world
        .client()
        .post("/api/catalog/probe", json!({}), move |result| {
            *reply.borrow_mut() = Some(result.err().map(|e| e.message).unwrap_or_default());
        });
    world.wait_for("the request to be answered", move |_| {
        answered.borrow().is_some()
    })
}

fn register_renewal(steps: &mut Steps) {
    steps.step(
        "a connected client whose credential is about to expire",
        |world, _, _| ensure_connected(world),
    );
    steps.step("the client renews it for an HTTP request", |world, _, _| {
        request_while_expiring(world, 200)?;
        let expires_at = world.client().credential_expiry();
        let renewal = world.mc.part::<Renewal>();
        let error = renewal.answered.borrow().clone().unwrap_or_default();
        expect!(
            renewal.renewals == 1
                && renewal.reached == 1
                && error.is_empty()
                && expires_at.is_some_and(|at| at > chrono::Utc::now() + Span::days(29)),
            "{} renewals, {} requests reached the MC, error {error:?}, the credential runs out at {expires_at:?}",
            renewal.renewals,
            renewal.reached
        );
        Ok(())
    });
    steps.step(
        "renewing its credential fails for an HTTP request",
        |world, _, _| request_while_expiring(world, 401),
    );
    steps.step("only that request fails", |world, _, _| {
        let renewal = world.mc.part::<Renewal>();
        let error = renewal.answered.borrow().clone().unwrap_or_default();
        expect!(
            renewal.renewals == 1 && renewal.reached == 0 && error.contains("could not be renewed"),
            "{} renewals, {} requests reached the MC, error {error:?}",
            renewal.renewals,
            renewal.reached
        );
        // The connection did not take the failure as its own.
        expect!(
            world.client().status().failure.is_empty() && phase(world) == "connected",
            "the connection is {}",
            show(&connection(world))
        );
        Ok(())
    });
    steps.step("the connection stays open", |world, _, _| {
        let before = world.mc.part::<Renewal>().connections_before;
        expect!(
            world.client().is_ready()
                && world.mc.connected()
                && world.mc.connections.len() == before,
            "the client is {:?} with {} sockets opened ({before} before)",
            world.client().status().phase,
            world.mc.connections.len()
        );
        Ok(())
    });
}

/// A slow MC's seconds become milliseconds here: 12 seconds of work take
/// 120 ms, and the client's deadlines shrink by as much, so the race is the
/// real one.
const SCALE: u64 = 100;

/// What a slow-MC scenario watches.
#[derive(Default)]
struct Slow {
    /// `sub` frames the MC had read before the scenario's step.
    subs: usize,
    /// Connections the MC had taken by then.
    connections: usize,
    /// `shell` frames it had sent by then.
    shells: usize,
    /// The key of a thread the MC lists only once it is asked.
    listed: String,
}

/// The client's deadlines, shrunk by SCALE, after checking that the real
/// ones leave a busy MC `seconds` to answer: a ping sent while it works is
/// answered once it is done, so the pong deadline is what bounds it. The
/// client pings every few milliseconds, so one is always waiting while the
/// MC works.
fn slow_mc(world: &mut World, seconds: u64) -> Outcome {
    let pong = hal_c2_mc::DEFAULT_PONG_TIMEOUT;
    expect!(
        pong.as_millis() as u64 > seconds * 1000,
        "the client gives up on an unanswered ping after {} ms, before a {seconds} s load is done",
        pong.as_millis()
    );
    world.client().set_pong_timeout(pong / SCALE as u32);
    world.client().set_ping_interval(Duration::from_millis(10));
    let (subs, connections, shells) = (
        world.mc.subscriptions.len(),
        world.mc.connections.len(),
        world.mc.shell_frames.len(),
    );
    let slow = world.mc.part::<Slow>();
    slow.subs = subs;
    slow.connections = connections;
    slow.shells = shells;
    Ok(())
}

/// The `sub` frames the MC read since the scenario's step, of `kind`.
fn subs_since(world: &mut World, kind: &str) -> Vec<Value> {
    let from = world.mc.part::<Slow>().subs;
    world.mc.subscriptions[from.min(world.mc.subscriptions.len())..]
        .iter()
        .filter(|sub| sub["shape"]["type"] == json!(kind))
        .cloned()
        .collect()
}

fn register_slow_mc(steps: &mut Steps) {
    // A slow MC's thread list.
    steps.step(
        r"the MC takes (\d+) seconds to build the thread list",
        |world, c, _| {
            let seconds: u64 = c[0].parse().unwrap_or(0);
            slow_mc(world, seconds)?;
            world.mc.build_ms = seconds * 1000 / SCALE;
            // Built anew, as after the MC restarted: the whole list is the work.
            world.mc.epoch = "epoch-slow".into();
            let id = "t-built-slowly";
            world.mc.threads.insert(
                id.into(),
                json!({"id": id, "title": "Built slowly", "projectId": PROJECT,
                       "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"}),
            );
            let listed = format!("{}:{id}", world.mc.environment_id);
            world.mc.part::<Slow>().listed = listed;
            Ok(())
        },
    );
    steps.step(
        "the thread list shows once the MC answers",
        |world, _, _| {
            let listed = world.mc.part::<Slow>().listed.clone();
            world.wait_for_with(
                |w| {
                    store::with(w.engine(), |s| s.synchronized())
                        && !super::thread_menu::section_of(w, &listed).is_empty()
                },
                |w| {
                    format!(
                        "the thread list to show {listed}: {}",
                        show(&w.state("sidebar"))
                    )
                },
            )
        },
    );
    steps.step("the MC builds the thread list once", |world, _, _| {
        world.sync()?;
        let asked = subs_since(world, "shell").len();
        let (connections, shells) = (world.mc.connections.len(), world.mc.shell_frames.len());
        let slow = world.mc.part::<Slow>();
        expect!(
            asked == 1 && connections == slow.connections + 1 && shells == slow.shells + 1,
            "the MC was asked for its thread list {asked} times over {} connections, and sent it {} times",
            connections - slow.connections,
            shells - slow.shells
        );
        Ok(())
    });

    // A slow MC's thread.
    steps.step(
        r"the MC takes (\d+) seconds to load a thread",
        |world, c, _| {
            let seconds: u64 = c[0].parse().unwrap_or(0);
            // A thread the client has not opened, with a turn in it.
            let row = json!({"id": THREAD, "title": "Tax line", "projectId": PROJECT,
                             "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"});
            world.mc.threads.insert(THREAD.into(), row.clone());
            world.mc.send_row(THREAD, &row);
            let environment = world.mc.environment_id.clone();
            let fake = world.mc.part::<FakeStreams>();
            fake.thread = THREAD.into();
            fake.environment = environment;
            super::stream::start_run(world, 60, "running")?;
            add_item(world, "assistant_message", json!({"text": OLD_ANSWER}))?;
            super::stream::settle_run(world, "completed", 30)?;
            world.sync()?;
            slow_mc(world, seconds)?;
            world.mc.part::<FakeStreams>().load_ms = seconds * 1000 / SCALE;
            Ok(())
        },
    );
    steps.step("the user opens the thread", |world, _, _| {
        let key = format!("{}:{THREAD}", world.mc.environment_id);
        look(world, &key, false)
    });
    steps.step("the thread shows once the MC answers", |world, _, _| {
        settle_thread(world)?;
        expect!(
            shows_text(world, OLD_ANSWER),
            "the thread shows {}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the MC loads the thread once", |world, _, _| {
        let asked = subs_since(world, "stream")
            .iter()
            .filter(|sub| sub["shape"]["stream"] == json!(THREAD))
            .count();
        let before = world.mc.part::<Slow>().connections;
        expect!(
            asked == 1 && world.mc.connections.len() == before,
            "the MC was asked for the thread {asked} times, and took {} connections meanwhile",
            world.mc.connections.len() - before
        );
        Ok(())
    });
}
