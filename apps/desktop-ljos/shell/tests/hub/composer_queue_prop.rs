//! The composer's view of a queue the MC holds as a state machine
//! (tst_ComposerQueueProp.cpp): the queue is held while any queued run of
//! the shown thread is, and "Resume queue" asks the MC to resume it, once at
//! a time per thread (across windows) and only while it is held and the
//! thread's stream is current. The MC holds or releases queues, queues more
//! behind a held one (a run may reach the stream before its message), runs
//! and cancels queued messages, answers a resume late or refuses it, and the
//! connection drops with an answer outstanding and comes back before the
//! streams are caught up. A second window shows the same thread or another,
//! and may close with its request outstanding; a refusal shows in the window
//! that asked, else in the main one.

use std::collections::{BTreeMap, VecDeque};

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller;
use hal_c2_shell::json::Json;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::composer::{DISPATCH, on_threads, thread_row};
use crate::composer_queue::{FAILURE, NOT_CONNECTED, Streams, count, resumes};
use crate::page::failure;
use crate::workspace::{project, shell};

const THREADS: [&str; 2] = ["t1", "t2"];
const SECOND: &str = "two";

#[derive(Clone, Debug)]
enum Op {
    /// Both windows show the thread.
    Open(usize),
    /// The second window goes to another thread.
    OpenSecond(usize),
    /// A message queued behind the turn: held when the queue is.
    Enqueue(usize),
    /// A message queued whose run reaches the stream first.
    EnqueueRun(usize),
    /// The message of the oldest run listed without one arrives.
    MessageLands(usize),
    /// The MC restarted: what was queued waits for the user.
    HoldQueue(usize),
    /// The first queued message starts (a queue not held) or is cancelled
    /// from another device (any queue).
    Leave(usize, bool),
    /// "Resume queue" in the main window or the second.
    Resume(bool),
    CloseSecond,
    /// The connection drops and comes back before the MC catches the thread
    /// streams up.
    Reconnect,
    /// The MC answers the thread streams.
    CatchUp,
    /// The MC holds its answers from now on.
    Hold,
    Refuse(bool),
    /// The MC answers the resumes it held, in the order they came.
    AnswerHeld,
}

fn op() -> impl Strategy<Value = Op> {
    let thread = 0usize..2;
    prop_oneof![
        1 => thread.clone().prop_map(Op::Open),
        1 => thread.clone().prop_map(Op::OpenSecond),
        2 => thread.clone().prop_map(Op::Enqueue),
        1 => thread.clone().prop_map(Op::EnqueueRun),
        1 => thread.clone().prop_map(Op::MessageLands),
        2 => thread.clone().prop_map(Op::HoldQueue),
        1 => (thread, any::<bool>()).prop_map(|(t, cancel)| Op::Leave(t, cancel)),
        3 => any::<bool>().prop_map(Op::Resume),
        1 => Just(Op::CloseSecond),
        1 => Just(Op::Reconnect),
        1 => Just(Op::CatchUp),
        1 => Just(Op::Hold),
        1 => any::<bool>().prop_map(Op::Refuse),
        1 => Just(Op::AnswerHeld),
    ]
}

/// What the MC keeps of each thread's queue, and what each window was told.
#[derive(Default)]
struct Model {
    open: usize,
    second_at: usize,
    second_open: bool,
    /// The listed queued runs, each held or not.
    queued: [Vec<bool>; 2],
    /// Queued runs whose message has not reached the stream: held with the
    /// queue, but not listed, so a queue of only these shows no card.
    unlisted: [VecDeque<(bool, Json)>; 2],
    resumes: [usize; 2],
    /// The threads whose resume is outstanding: whether the MC will refuse
    /// it, and whether the second window asked.
    pending: BTreeMap<usize, (bool, bool)>,
    holding: bool,
    refusing: bool,
    failures: usize,
    second_failures: usize,
    /// "Not connected" warnings: one however often asked while it shows.
    warnings: usize,
    second_warnings: usize,
    /// Reconnected, but the thread streams are not caught up.
    stale: bool,
}

impl Model {
    fn held(&self, t: usize) -> bool {
        self.queued[t].contains(&true) || self.unlisted[t].iter().any(|(h, _)| *h)
    }

    /// The card shows held: held, with a run listed.
    fn shown(&self, t: usize) -> bool {
        self.held(t) && !self.queued[t].is_empty()
    }

    fn any(&self, t: usize) -> bool {
        !self.queued[t].is_empty() || !self.unlisted[t].is_empty()
    }

    fn fail(&mut self, in_second: bool) {
        if in_second && self.second_open {
            self.second_failures += 1;
        } else {
            self.failures += 1;
        }
    }

    fn release(&mut self, t: usize) {
        self.queued[t].fill(false);
        for (held, _) in &mut self.unlisted[t] {
            *held = false;
        }
    }
}

struct World {
    hub: Hub,
    streams: Streams,
    model: Model,
}

impl World {
    fn new() -> World {
        let hub = on_threads(&THREADS);
        controller::set_window_opener(&hub.engine, |_, _| {});
        controller::open_window(&hub.engine, Some(SECOND)).expect("the shell is started");
        let mut world = World {
            hub,
            streams: Streams::default(),
            model: Model {
                second_open: true,
                ..Model::default()
            },
        };
        world.open(0);
        world
    }

    fn second(&self) -> Bridge {
        controller::window_bridge(&self.hub.engine, SECOND).expect("the second window")
    }

    /// The main window's bridge: `Hub::dispatch` and `Hub::published` follow
    /// the window acted in last.
    fn main(&self) -> Bridge {
        controller::window_bridge(&self.hub.engine, controller::MAIN).expect("the main window")
    }

    fn open(&mut self, t: usize) {
        self.main().dispatch(
            &self.hub.engine,
            "thread.open",
            json!({"key": format!("env-1:{}", THREADS[t])}),
        );
        if self.model.second_open {
            self.open_second(t);
        }
        self.streams.answer(&self.hub);
    }

    fn open_second(&mut self, t: usize) {
        self.second().dispatch(
            &self.hub.engine,
            "thread.open",
            json!({"key": format!("env-1:{}", THREADS[t])}),
        );
        self.streams.answer(&self.hub);
    }

    /// The MC answers `thread`'s resume: it releases the queue first, as
    /// its effect, unless it refuses.
    fn answer(&mut self, t: usize, refuse: bool) {
        let index = self
            .hub
            .mc
            .pending_where(DISPATCH, |c| {
                c["type"] == "queue.resume" && c["threadId"] == THREADS[t]
            })
            .expect("the resume is outstanding");
        if refuse {
            self.hub.mc.reply(
                &self.hub.engine,
                index,
                Err(failure("The thread is archived.")),
            );
        } else {
            self.streams.hold(&self.hub, THREADS[t], false);
            self.hub.mc.reply(&self.hub.engine, index, Ok(json!({})));
        }
    }

    fn step(&mut self, op: Op) {
        let stale = self.model.stale;
        match op {
            Op::Open(t) if !stale => {
                self.open(t);
                self.model.open = t;
                self.model.second_at = t;
            }
            Op::OpenSecond(t) if !stale && self.model.second_open => {
                self.open_second(t);
                self.model.second_at = t;
            }
            Op::Enqueue(t) if !stale && self.model.queued[t].len() < 3 => {
                let held = self.model.held(t);
                self.streams.enqueue(&self.hub, THREADS[t], held, false);
                self.model.queued[t].push(held);
            }
            Op::EnqueueRun(t)
                if !stale && self.model.queued[t].len() + self.model.unlisted[t].len() < 3 =>
            {
                let held = self.model.held(t);
                let message = self.streams.enqueue(&self.hub, THREADS[t], held, true);
                self.model.unlisted[t].push_back((held, message));
            }
            Op::MessageLands(t) if !stale && !self.model.unlisted[t].is_empty() => {
                let (held, message) = self.model.unlisted[t].pop_front().unwrap();
                self.streams.land(&self.hub, THREADS[t], message);
                self.model.queued[t].push(held);
            }
            Op::HoldQueue(t) if !stale && self.model.any(t) => {
                self.streams.hold(&self.hub, THREADS[t], true);
                self.model.queued[t].fill(true);
                for (held, _) in &mut self.model.unlisted[t] {
                    *held = true;
                }
            }
            Op::Leave(t, cancel)
                if !stale
                    && !self.model.queued[t].is_empty()
                    && self.model.unlisted[t].is_empty()
                    && (cancel || !self.model.held(t)) =>
            {
                let status = if cancel { "cancelled" } else { "running" };
                self.streams.leave(&self.hub, THREADS[t], status);
                self.model.queued[t].remove(0);
            }
            Op::Resume(second) => {
                let in_second = second && self.model.second_open;
                if in_second {
                    self.second()
                        .dispatch(&self.hub.engine, "composer.queue.resume", json!({}));
                } else {
                    self.main()
                        .dispatch(&self.hub.engine, "composer.queue.resume", json!({}));
                }
                let m = &mut self.model;
                let t = if in_second { m.second_at } else { m.open };
                if m.stale && m.shown(t) {
                    *(if in_second {
                        &mut m.second_warnings
                    } else {
                        &mut m.warnings
                    }) = 1;
                }
                if m.stale || !m.shown(t) || m.pending.contains_key(&t) {
                    return;
                }
                m.resumes[t] += 1;
                if m.holding {
                    m.pending.insert(t, (m.refusing, in_second));
                } else if m.refusing {
                    self.answer(t, true);
                    self.model.fail(in_second);
                } else {
                    self.answer(t, false);
                    self.model.release(t);
                }
            }
            Op::CloseSecond if self.model.second_open => {
                controller::close_window(&self.hub.engine, SECOND);
                self.hub.engine.process_deferred_deletes();
                let m = &mut self.model;
                m.second_open = false;
                m.second_failures = 0;
                m.second_warnings = 0;
            }
            Op::Reconnect if !stale => {
                // The answers outstanding never come: each resume failed.
                for (t, (_, in_second)) in std::mem::take(&mut self.model.pending) {
                    let index = self
                        .hub
                        .mc
                        .pending_where(DISPATCH, |c| {
                            c["type"] == "queue.resume" && c["threadId"] == THREADS[t]
                        })
                        .expect("the resume is outstanding");
                    self.hub
                        .mc
                        .reply(&self.hub.engine, index, Err(failure("disconnected")));
                    self.model.fail(in_second);
                }
                self.model.holding = false;
                self.model.stale = true;
                self.hub.mc.set_ready(&self.hub.engine, false);
                self.streams.dropped();
                self.streams.holding = true;
                self.hub.mc.set_ready(&self.hub.engine, true);
                let mut rows = vec![project(json!({}))];
                rows.extend(THREADS.iter().map(|id| thread_row(id)));
                shell(&self.hub, rows);
            }
            Op::CatchUp if stale => {
                self.streams.holding = false;
                self.streams.answer(&self.hub);
                self.model.stale = false;
            }
            Op::Hold if !self.model.holding => self.model.holding = true,
            Op::Refuse(on) => self.model.refusing = on,
            Op::AnswerHeld if self.model.holding => {
                self.model.holding = false;
                for (t, (refuse, in_second)) in std::mem::take(&mut self.model.pending) {
                    self.answer(t, refuse);
                    if refuse {
                        self.model.fail(in_second);
                    } else {
                        self.model.release(t);
                    }
                }
            }
            _ => {}
        }
    }

    fn check(&self) {
        let (hub, m) = (&self.hub, &self.model);
        for (t, thread) in THREADS.iter().enumerate() {
            assert_eq!(resumes(hub, thread), m.resumes[t], "resumes of {thread}");
        }
        let main = self.main();
        let toasts = main.published(&hub.engine, "toasts").unwrap_or(Json::Null);
        assert_eq!(count(&toasts, FAILURE), m.failures, "failures");
        assert_eq!(count(&toasts, NOT_CONNECTED), m.warnings, "warnings");
        let second = m.second_open.then(|| self.second());
        assert_eq!(
            controller::window_bridge(&hub.engine, SECOND).is_some(),
            m.second_open
        );
        let second_turn = second.map(|b| b.published(&hub.engine, "turn").unwrap_or(Json::Null));
        if let Some(b) = second {
            let toasts = b.published(&hub.engine, "toasts").unwrap_or(Json::Null);
            assert_eq!(
                count(&toasts, FAILURE),
                m.second_failures,
                "second's failures"
            );
            assert_eq!(
                count(&toasts, NOT_CONNECTED),
                m.second_warnings,
                "second's warnings"
            );
        }
        // Until the streams catch up the windows show what they last knew,
        // but whether a resume is outstanding is the app's own.
        let agrees = |turn: &Json, t: usize| {
            assert_eq!(turn["queueResuming"], m.pending.contains_key(&t), "{turn}");
            if m.stale {
                return;
            }
            assert_eq!(turn["threadKey"], format!("env-1:{}", THREADS[t]));
            assert_eq!(turn["queueHeld"], m.shown(t), "{turn}");
            assert_eq!(
                turn["queue"].as_array().map_or(0, Vec::len),
                m.queued[t].len(),
                "{turn}"
            );
        };
        agrees(
            &main.published(&hub.engine, "turn").unwrap_or(Json::Null),
            m.open,
        );
        if let Some(turn) = &second_turn {
            agrees(turn, m.second_at);
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 128, ..ProptestConfig::default() })]

    #[test]
    fn a_held_queue_is_resumed_once_at_a_time_and_only_while_held(
        ops in proptest::collection::vec(op(), 1..40)
    ) {
        let mut world = World::new();
        world.check();
        for op in ops {
            world.step(op);
            world.check();
        }
    }
}
