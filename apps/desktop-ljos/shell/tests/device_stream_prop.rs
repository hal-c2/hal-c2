//! A device stream's connections and timers against the host that runs its
//! effects: any order of targets, showing and hiding, reconnects, the hub's
//! answers (current or stale), timers firing, decoder news and input keeps
//! the stream's account of what is open and running equal to the host's,
//! sends only on a connected socket, and leaves nothing behind once it
//! stops.

#[path = "support/device_fixture.rs"]
mod device_fixture;
#[path = "support/device_mc.rs"]
mod device_mc;

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use device_fixture::{android_video, ios_video};
use device_mc::{Makes, Script, Scripted};
use hal_c2_shell::device::decoder::Decoded;
use hal_c2_shell::device::stream::{Conn, Core, Effect, Timer};
use hal_c2_shell::mc::{StreamEnd, StreamEvent};
use proptest::prelude::*;

const TARGETS: [(&str, &str, &str); 3] = [
    ("", "", ""),
    ("/api/device-hub/mcs/mc-1", "ios", "UDID-1"),
    ("/api/device-hub/mcs/mc-1", "android", "emulator-5554"),
];
const CONNS: [Conn; 3] = [Conn::Video, Conn::Prime, Conn::Socket];
const TIMERS: [Timer; 5] = [
    Timer::FirstFrame,
    Timer::ReadStall,
    Timer::VideoRetry,
    Timer::InputRetry,
    Timer::Prime,
];

#[derive(Clone, Debug)]
enum Op {
    Target(usize),
    Active(bool),
    Reconnect,
    Makes(Makes, bool),
    /// The hub answers `conn` with a status; `stale`: an older one's.
    Opened {
        conn: usize,
        status: u16,
        stale: bool,
    },
    /// iOS video bytes, the first `cut` of the fixture's body.
    Data {
        cut: usize,
        stale: bool,
    },
    /// One of serve-emu's frames.
    Frame {
        index: usize,
        stale: bool,
    },
    VideoSession,
    Ended {
        conn: usize,
        refused: bool,
        stale: bool,
    },
    Fire {
        timer: usize,
        stale: bool,
    },
    Decoded(u8),
    Touch(f64, f64),
    Key(bool),
    Button(usize),
    Rotate,
}

fn op() -> impl Strategy<Value = Op> {
    let makes = prop_oneof![
        Just(Makes::Pictures(72, 160)),
        Just(Makes::Pictures(160, 72)),
        Just(Makes::Nothing),
        Just(Makes::Broken),
    ];
    prop_oneof![
        2 => (0..3usize).prop_map(Op::Target),
        1 => any::<bool>().prop_map(Op::Active),
        1 => Just(Op::Reconnect),
        1 => (makes, any::<bool>()).prop_map(|(m, k)| Op::Makes(m, k)),
        4 => (0..3usize, prop_oneof![Just(200u16), Just(101), Just(401), Just(502)], prop::bool::weighted(0.2))
            .prop_map(|(conn, status, stale)| Op::Opened { conn, status, stale }),
        3 => (0..400usize, prop::bool::weighted(0.2)).prop_map(|(cut, stale)| Op::Data { cut, stale }),
        3 => (0..8usize, prop::bool::weighted(0.2)).prop_map(|(index, stale)| Op::Frame { index, stale }),
        1 => Just(Op::VideoSession),
        2 => (0..3usize, prop::bool::weighted(0.2), prop::bool::weighted(0.2))
            .prop_map(|(conn, refused, stale)| Op::Ended { conn, refused, stale }),
        3 => (0..5usize, prop::bool::weighted(0.2)).prop_map(|(timer, stale)| Op::Fire { timer, stale }),
        2 => (0..3u8).prop_map(Op::Decoded),
        1 => (0.0..1.0f64, 0.0..1.0f64).prop_map(|(x, y)| Op::Touch(x, y)),
        1 => any::<bool>().prop_map(Op::Key),
        1 => (0..4usize).prop_map(Op::Button),
        1 => Just(Op::Rotate),
    ]
}

/// What the host has open and running, by the stream's ids.
#[derive(Default)]
struct Host {
    /// conn -> (id, connected)
    open: HashMap<Conn, (u64, bool)>,
    timers: HashMap<Timer, u64>,
    /// Every id the stream has used: a stale event carries an older one.
    used: Vec<u64>,
}

impl Host {
    /// Runs `effects` as the shell does. Sends only on a connected socket.
    fn run(&mut self, effects: Vec<Effect>) -> Result<(), TestCaseError> {
        for effect in effects {
            match effect {
                Effect::Open { conn, id, .. } => {
                    self.used.push(id);
                    self.open.insert(conn, (id, false));
                }
                Effect::Close(conn) => {
                    prop_assert!(self.open.remove(&conn).is_some(), "{conn:?} closed twice");
                }
                Effect::Send { .. } => {
                    prop_assert!(
                        matches!(self.open.get(&Conn::Socket), Some((_, true))),
                        "a send without a connected socket"
                    );
                }
                Effect::StartTimer { timer, id, .. } => {
                    self.used.push(id);
                    self.timers.insert(timer, id);
                }
                Effect::StopTimer(timer) => {
                    prop_assert!(
                        self.timers.remove(&timer).is_some(),
                        "{timer:?} stopped twice"
                    );
                }
            }
        }
        Ok(())
    }

    /// An id the stream used for something else, or none it knows.
    fn stale(&self, current: Option<u64>) -> u64 {
        self.used
            .iter()
            .copied()
            .find(|id| Some(*id) != current)
            .unwrap_or(u64::MAX)
    }
}

fn sorted<T: Ord>(mut v: Vec<T>) -> Vec<T> {
    v.sort();
    v
}

fn key(c: &Conn) -> u8 {
    *c as u8
}

fn tkey(t: &Timer) -> u8 {
    *t as u8
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    #[test]
    fn the_stream_and_its_host_agree(ops in prop::collection::vec(op(), 1..60)) {
        let script = Rc::new(RefCell::new(Script::default()));
        let mut core = Core::new(Box::new(Scripted(script.clone())));
        let mut host = Host::default();
        let body = ios_video(false);
        let frames = android_video();
        core.set_active(true);
        host.run(core.take_effects())?;

        for op in ops {
            let target_before = (core.platform().to_owned(), host.used.iter().max().copied());
            let mut is_stale = false;
            let mut retarget = false;
            match op {
                Op::Target(i) => {
                    let (base, platform, device) = TARGETS[i];
                    retarget = core.platform() != platform;
                    core.set_target(base, platform, device);
                }
                Op::Active(active) => core.set_active(active),
                Op::Reconnect => core.reconnect(),
                Op::Makes(makes, keeps_up) => {
                    let mut s = script.borrow_mut();
                    s.makes = makes;
                    s.keeps_up = keeps_up;
                }
                Op::Opened { conn, status, stale } => {
                    let conn = CONNS[conn];
                    let current = host.open.get(&conn).map(|(id, _)| *id);
                    if stale || current.is_none() {
                        is_stale = true;
                        core.on_event(conn, host.stale(current), StreamEvent::Opened { status });
                    } else if let Some(id) = current {
                        if conn == Conn::Socket {
                            host.open.insert(conn, (id, true));
                        }
                        core.on_event(conn, id, StreamEvent::Opened { status });
                    }
                }
                Op::Data { cut, stale } => {
                    let current = host.open.get(&Conn::Video).map(|(id, _)| *id);
                    let bytes = body[..cut.min(body.len())].to_vec();
                    match current {
                        Some(id) if !stale => core.on_event(Conn::Video, id, StreamEvent::Data(bytes)),
                        _ => {
                            is_stale = true;
                            core.on_event(Conn::Video, host.stale(current), StreamEvent::Data(bytes));
                        }
                    }
                }
                Op::Frame { index, stale } => {
                    let frame = frames[index % frames.len()].0.clone();
                    let current = host.open.get(&Conn::Socket).map(|(id, _)| *id);
                    match current {
                        Some(id) if !stale => core.on_event(Conn::Socket, id, StreamEvent::Binary(frame)),
                        _ => {
                            is_stale = true;
                            core.on_event(Conn::Socket, host.stale(current), StreamEvent::Binary(frame));
                        }
                    }
                }
                Op::VideoSession => {
                    if let Some((id, _)) = host.open.get(&Conn::Socket).copied() {
                        core.on_event(
                            Conn::Socket,
                            id,
                            StreamEvent::Text(r#"{"type":"video-session"}"#.into()),
                        );
                    }
                }
                Op::Ended { conn, refused, stale } => {
                    let conn = CONNS[conn];
                    let end = StreamEnd {
                        status: refused.then_some(401),
                        error: Some("gone".into()),
                        ..StreamEnd::default()
                    };
                    let current = host.open.get(&conn).map(|(id, _)| *id);
                    match current {
                        Some(id) if !stale => {
                            // Ended by itself: the host's stream is gone.
                            host.open.remove(&conn);
                            core.on_event(conn, id, StreamEvent::Ended(end));
                        }
                        _ => {
                            is_stale = true;
                            core.on_event(conn, host.stale(current), StreamEvent::Ended(end));
                        }
                    }
                }
                Op::Fire { timer, stale } => {
                    let timer = TIMERS[timer];
                    let current = host.timers.get(&timer).copied();
                    match current {
                        Some(id) if !stale => {
                            host.timers.remove(&timer);
                            core.on_timer(timer, id);
                        }
                        _ => {
                            is_stale = true;
                            core.on_timer(timer, host.stale(current));
                        }
                    }
                }
                Op::Decoded(n) => {
                    let events = core.decoder_mut().take_events();
                    let made = match n {
                        0 => Decoded::Frame,
                        1 => Decoded::Broken,
                        _ => Decoded::Unsupported("No H.264 decoder.".into()),
                    };
                    for event in events.into_iter().chain([made]) {
                        core.on_decoded(event);
                        host.run(core.take_effects())?;
                    }
                }
                Op::Touch(x, y) => core.touch("begin", x, y),
                Op::Key(down) => core.key(0x41, "a", false, down),
                Op::Button(i) => core.press_button(["home", "back", "recents", "power"][i]),
                Op::Rotate => core.rotate(),
            }
            let effects = core.take_effects();
            let notes = core.take_notes();
            if is_stale {
                // An older connection's or timer's news changes nothing.
                prop_assert!(effects.is_empty(), "stale: {effects:?}");
                prop_assert!(notes.is_empty(), "stale: {notes:?}");
            }
            if retarget {
                // Another device: whatever was open is closed before the
                // next opens, so every open connection is a new one.
                let (_, newest) = target_before;
                if let Some(newest) = newest {
                    for effect in &effects {
                        if let Effect::Open { id, .. } = effect {
                            prop_assert!(*id > newest);
                        }
                    }
                }
            }
            host.run(effects)?;
            if retarget {
                let (_, newest) = target_before;
                for (id, _) in host.open.values() {
                    prop_assert!(newest.is_none_or(|n| *id > n), "an old connection outlived its target");
                }
            }

            // The stream's account is the host's.
            let core_open = sorted(core.open().iter().map(key).collect());
            let host_open = sorted(host.open.keys().map(key).collect());
            prop_assert_eq!(core_open, host_open);
            let core_timers = sorted(core.timers().iter().map(tkey).collect());
            let host_timers = sorted(host.timers.keys().map(tkey).collect());
            prop_assert_eq!(core_timers, host_timers);

            if !core.running() {
                prop_assert!(host.open.is_empty(), "stopped with {:?} open", core.open());
                prop_assert!(host.timers.is_empty(), "stopped with {:?} running", core.timers());
                prop_assert!(!core.input_connected());
            }
            match core.status() {
                "error" | "idle" => prop_assert!(!core.running(), "{} while running", core.status()),
                "connecting" | "streaming" => prop_assert!(core.running()),
                other => prop_assert!(false, "status {other}"),
            }
            // Connecting always waits for a first picture.
            if core.status() == "connecting" {
                prop_assert!(core.timers().contains(&Timer::FirstFrame));
            }
        }
    }
}
