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
}

fn watched(world: &mut World) -> &mut Watched {
    world.part::<Watched>()
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
            disconnected: Rc::new(move || disconnected),
            interface_up: Rc::new(move || interface_up),
        });
        c.network_changed(engine);
    })?;
    world.pump()
}

/// The notice every window shows over its layout.
fn notice(world: &mut World) -> Outcome<Brick> {
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nItem { ConnectionNotice {} }\n",
        900.0,
        600.0,
    )?;
    world.part::<crate::brick::Shown>().0 = Some(brick);
    Ok(brick)
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
            field(world, "status") == "Waiting for the network" && offline,
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
    steps.step("the client stops retrying", |world, _, _| {
        wait_for_phase(world, &["refused"])?;
        world.pump()?;
        let before = watched(world).connections_before;
        expect!(
            world.client().phase() == Phase::Refused && world.mc.connections.len() == before,
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
        let item = shown.item(world, "connectionNotice")?;
        let asks = shown.flag(world, item, "visible")
            && shown.shows(world, "Pair again")?
            && shown.shows(
                world,
                "Pair again with a fresh pairing link from the environment.",
            )?;
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
        expect!(
            field(world, "status") == "Could not load its data: the shell is unavailable" && said,
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
            let left: Vec<String> = drafts::all(world.engine())
                .into_iter()
                .filter(|d| d.environment_id == environment)
                .map(|d| d.text)
                .collect();
            expect!(
                left.is_empty(),
                "its drafts are still kept: {}",
                left.join(", ")
            );
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
