//! The composer's sends as a state machine (tst_ComposerProp.cpp): prompts
//! typed and sent on two threads, the MC answering each thread's oldest
//! dispatch in any order, taking it, refusing it or dropping the answer.
//! Each thread has one dispatch in flight and its messages reach the MC in
//! the order they were sent; a refused prompt and the ones behind it come
//! back to an empty draft or wait behind a toast; nothing else moves.

use std::collections::VecDeque;

use hal_c2_shell::mc::McError;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::composer::{DISPATCH, draft, on_threads, open, pending_to};

const THREADS: [&str; 2] = ["t1", "t2"];

#[derive(Clone, Copy, Debug)]
enum Answer {
    Take,
    Refuse,
    /// The connection went before the answer came.
    Drop,
}

#[derive(Clone, Debug)]
enum Op {
    /// Replaces the shown draft with a new prompt, or empties it.
    Type {
        empty: bool,
    },
    Send,
    Answer {
        thread: usize,
        answer: Answer,
    },
    Open {
        thread: usize,
    },
    /// Clicks the newest toast's action, if it has one.
    Click,
}

fn op() -> impl Strategy<Value = Op> {
    let answer = prop_oneof![
        4 => Just(Answer::Take),
        2 => Just(Answer::Refuse),
        1 => Just(Answer::Drop),
    ];
    prop_oneof![
        4 => (0u8..5).prop_map(|n| Op::Type { empty: n == 0 }),
        4 => Just(Op::Send),
        5 => (0usize..2, answer).prop_map(|(thread, answer)| Op::Answer { thread, answer }),
        2 => (0usize..2).prop_map(|thread| Op::Open { thread }),
        1 => Just(Op::Click),
    ]
}

#[derive(Clone, Debug, PartialEq)]
struct Toast {
    title: String,
    /// What "Restore prompt" gives back, and to which thread.
    restores: Option<(usize, String)>,
}

#[derive(Default)]
struct Model {
    open: usize,
    drafts: [String; 2],
    /// The thread's sends, the oldest at the MC.
    queues: [VecDeque<String>; 2],
    /// What reached the MC, per thread, in order.
    dispatched: [Vec<String>; 2],
    /// Newest first.
    toasts: Vec<Toast>,
    typed: u32,
}

struct World {
    hub: Hub,
    model: Model,
}

impl World {
    fn new() -> World {
        World {
            hub: on_threads(&THREADS),
            model: Model::default(),
        }
    }

    fn target(thread: usize) -> String {
        format!("env-1:{}", THREADS[thread])
    }

    fn step(&mut self, op: Op) {
        let (hub, model) = (&self.hub, &mut self.model);
        match op {
            Op::Type { empty } => {
                let text = if empty {
                    String::new()
                } else {
                    model.typed += 1;
                    format!("p{}", model.typed)
                };
                hub.dispatch(
                    "composer.text.set",
                    json!({"target": Self::target(model.open), "text": text,
                        "cursor": text.encode_utf16().count()}),
                );
                model.drafts[model.open] = text;
            }
            Op::Send => {
                hub.dispatch("composer.submit", json!({}));
                let t = model.open;
                let prompt = std::mem::take(&mut model.drafts[t]);
                if !prompt.trim().is_empty() {
                    model.queues[t].push_back(prompt.clone());
                    if model.queues[t].len() == 1 {
                        model.dispatched[t].push(prompt);
                    }
                }
            }
            Op::Answer { thread: t, answer } => {
                let Some(index) = pending_to(hub, THREADS[t]) else {
                    return;
                };
                let result = match answer {
                    Answer::Take => Ok(json!({})),
                    Answer::Refuse => Err(McError::new("refused")),
                    Answer::Drop => Err(McError::new("disconnected")),
                };
                hub.mc.reply(&hub.engine, index, result);
                match answer {
                    Answer::Take => {
                        model.queues[t].pop_front();
                        if let Some(next) = model.queues[t].front() {
                            model.dispatched[t].push(next.clone());
                        }
                    }
                    // Kept for the thread's messages to settle.
                    Answer::Drop => model.queues[t].clear(),
                    Answer::Refuse => {
                        let restored = model.queues[t].drain(..).collect::<Vec<_>>().join("\n\n");
                        let restores = if model.drafts[t].is_empty() {
                            model.drafts[t] = restored;
                            None
                        } else {
                            Some((t, restored))
                        };
                        model.toasts.insert(
                            0,
                            Toast {
                                title: "Failed to send message".into(),
                                restores,
                            },
                        );
                    }
                }
            }
            Op::Open { thread } => {
                open(hub, THREADS[thread]);
                model.open = thread;
            }
            Op::Click => {
                let Some(newest) = model.toasts.first() else {
                    return;
                };
                if newest.restores.is_none() {
                    return;
                }
                let id = hub.published("toasts")["items"][0]["id"].clone();
                hub.dispatch(
                    "notification.action",
                    json!({"id": id, "actionId": "primary"}),
                );
                let Some((t, text)) = model.toasts.remove(0).restores else {
                    return;
                };
                // Only into an emptied draft, which it then shows.
                if model.drafts[t].is_empty() {
                    model.drafts[t] = text;
                    model.open = t;
                }
            }
        }
    }

    fn check(&self) {
        let (hub, model) = (&self.hub, &self.model);
        assert_eq!(
            hub.published("composer")["target"],
            Self::target(model.open).as_str()
        );
        let calls = hub.mc.calls.borrow();
        for (t, thread) in THREADS.iter().enumerate() {
            assert_eq!(draft(hub, thread), model.drafts[t], "{thread}'s draft");
            let dispatches: Vec<usize> = (0..calls.len())
                .filter(|&i| calls[i].1 == DISPATCH && calls[i].2["threadId"] == *thread)
                .collect();
            let texts: Vec<&str> = dispatches
                .iter()
                .map(|&i| calls[i].2["text"].as_str().unwrap_or_default())
                .collect();
            assert_eq!(
                texts, model.dispatched[t],
                "what reached the MC for {thread}"
            );
            let in_flight = dispatches.iter().filter(|&&i| hub.mc.is_pending(i)).count();
            assert_eq!(
                in_flight,
                usize::from(!model.queues[t].is_empty()),
                "{thread}'s dispatches in flight"
            );
        }
        let toasts: Vec<(String, bool)> = hub.published("toasts")["items"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .iter()
            .map(|t| {
                (
                    t["title"].as_str().unwrap_or_default().to_owned(),
                    t["actions"][0]["label"] == "Restore prompt",
                )
            })
            .collect();
        let expected: Vec<(String, bool)> = model
            .toasts
            .iter()
            .map(|t| (t.title.clone(), t.restores.is_some()))
            .collect();
        assert_eq!(toasts, expected);
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 128, ..ProptestConfig::default() })]

    #[test]
    fn sends_follow_their_model(ops in proptest::collection::vec(op(), 1..40)) {
        let mut world = World::new();
        world.check();
        for op in ops {
            world.step(op);
            world.check();
        }
    }
}
