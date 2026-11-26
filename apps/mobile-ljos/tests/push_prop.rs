//! The push inbox against a model of what it must show, as
//! mobile-qt's RapidCheck prop holds its C++ (tests/prop/
//! tst_PushInboxProp): MC messages and the app's own that arrive
//! late, early, twice, out of order, while the app is open or the
//! system forbids notifications, with the user dismissing the
//! activity card, turning live activity off and on and forgetting
//! the environment, as time passes. An alert shows once, only when
//! it is fresh, allowed and the app is away; the card follows the
//! newest activity, stays away once dismissed until a run starts
//! again, and goes when its lifetime ends.

use std::collections::HashSet;

use hal_c2_mobile::push_inbox::{ActivityRow, Device, Inbox, activity};
use proptest::prelude::*;
use serde_json::{Map, Value as Json, json};

const MINUTE: i64 = 60 * 1000;
const START: i64 = 1_790_000_000_000;

#[derive(Clone, Default)]
struct Model {
    now: i64,
    seen: HashSet<String>,
    last_update: i64,
    last_local_update: i64,
    last_active: bool,
    dismissed: bool,
    live: bool,
    /// The card on screen: whether it is for work in progress, and
    /// until when.
    card: Option<(bool, i64)>,
}

impl Model {
    fn new() -> Model {
        Model {
            now: START,
            live: true,
            ..Model::default()
        }
    }
}

/// When a message was sent, from where the phone's clock is.
#[derive(Clone, Copy, Debug)]
enum Sent {
    Now,
    Earlier,
    Later,
    Stale,
    Future,
}

fn sent_at(sent: Sent, now: i64) -> i64 {
    match sent {
        Sent::Now => now,
        Sent::Earlier => now - MINUTE,
        Sent::Later => now + 30 * 1000,
        Sent::Stale => now - 11 * MINUTE,
        Sent::Future => now + 60 * MINUTE,
    }
}

fn fresh(sent: Sent) -> bool {
    !matches!(sent, Sent::Stale | Sent::Future)
}

#[derive(Clone, Debug)]
enum Action {
    Alert {
        thread: u8,
        sent: Sent,
        foreground: bool,
        permitted: bool,
    },
    Activity {
        active: bool,
        sent: Sent,
        permitted: bool,
        local: bool,
    },
    Dismiss,
    Live(bool),
    Forget,
    Wait(i64),
}

fn sent() -> impl Strategy<Value = Sent> {
    prop_oneof![
        Just(Sent::Now),
        Just(Sent::Now),
        Just(Sent::Earlier),
        Just(Sent::Later),
        Just(Sent::Stale),
        Just(Sent::Future),
    ]
}

fn action() -> impl Strategy<Value = Action> {
    prop_oneof![
        (1u8..4, sent(), any::<bool>(), any::<bool>()).prop_map(|(thread, sent, fg, ok)| {
            Action::Alert {
                thread,
                sent,
                foreground: fg,
                permitted: ok,
            }
        }),
        (1u8..4, sent(), any::<bool>(), any::<bool>()).prop_map(|(thread, sent, fg, ok)| {
            Action::Alert {
                thread,
                sent,
                foreground: fg,
                permitted: ok,
            }
        }),
        (any::<bool>(), sent(), any::<bool>(), any::<bool>()).prop_map(
            |(active, sent, ok, local)| {
                Action::Activity {
                    active,
                    sent,
                    permitted: ok,
                    local,
                }
            }
        ),
        (any::<bool>(), sent(), any::<bool>(), any::<bool>()).prop_map(
            |(active, sent, ok, local)| {
                Action::Activity {
                    active,
                    sent,
                    permitted: ok,
                    local,
                }
            }
        ),
        (any::<bool>(), sent(), any::<bool>(), any::<bool>()).prop_map(
            |(active, sent, ok, local)| {
                Action::Activity {
                    active,
                    sent,
                    permitted: ok,
                    local,
                }
            }
        ),
        Just(Action::Dismiss),
        any::<bool>().prop_map(Action::Live),
        Just(Action::Forget),
        prop_oneof![
            Just(1000i64),
            Just(5 * MINUTE),
            Just(14 * MINUTE),
            Just(16 * MINUTE),
            Just(121 * MINUTE),
        ]
        .prop_map(Action::Wait),
        prop_oneof![Just(1000i64), Just(5 * MINUTE)].prop_map(Action::Wait),
    ]
}

fn object_of(value: &Json) -> Map<String, Json> {
    value.as_object().cloned().unwrap_or_default()
}

/// What the system shows, as the effects say.
struct Shown {
    card: Option<(Json, i64)>,
    last_alert: Json,
}

impl Shown {
    fn show(&mut self, effects: &Json, now: i64) {
        assert_eq!(effects["channels"].as_array().map(Vec::len), Some(2));
        self.last_alert = effects.get("alert").cloned().unwrap_or(Json::Null);
        if effects.get("cancelCard").and_then(Json::as_bool) == Some(true) {
            self.card = None;
        }
        if let Some(card) = effects.get("card").filter(|card| card.is_object()) {
            for (key, value) in card.as_object().unwrap() {
                assert!(!value.is_null(), "card {key} is null");
            }
            self.card = Some((card.clone(), now));
        }
    }

    fn check(&self, model: &Model, now: i64) {
        let visible = self.card.as_ref().is_some_and(|(card, shown_at)| {
            now < shown_at + card["timeoutMs"].as_f64().unwrap_or_default() as i64
        });
        let expected = model.card.is_some_and(|(_, until)| now < until);
        assert_eq!(visible, expected, "card visibility at {now}");
        if visible {
            assert_eq!(
                self.card
                    .as_ref()
                    .map(|(card, _)| card["ongoing"].as_bool()),
                model.card.map(|(active, _)| Some(active))
            );
        }
    }
}

fn activity_at(active: bool, at: i64) -> Json {
    activity(
        vec![ActivityRow {
            phase: if active { "running" } else { "completed" }.into(),
            title: "Fix checkout".into(),
            project: "shop".into(),
            environment_id: "env-a".into(),
            thread_id: "thread-1".into(),
            at,
        }],
        at,
    )
}

proptest! {
    #[test]
    fn the_inbox_agrees_with_the_model(actions in prop::collection::vec(action(), 0..40)) {
        let dir = tempfile::tempdir().unwrap();
        let inbox = Inbox::new(dir.path());
        let mut model = Model::new();
        let mut now = START;
        let mut shown = Shown { card: None, last_alert: Json::Null };
        for action in actions {
            match action {
                Action::Alert { thread, sent, foreground, permitted } => {
                    let id = format!("env-a:thread-{thread}:completed:run-1");
                    let counts = fresh(sent) && permitted;
                    let message = object_of(&json!({
                        "v": 1,
                        "sentAt": sent_at(sent, now) as f64,
                        "alert": {
                            "id": id,
                            "kind": "completed",
                            "title": "Fix checkout",
                            "body": "Agent finished",
                            "environmentId": "env-a",
                            "threadId": format!("thread-{thread}"),
                        }
                    }));
                    let effects = inbox.deliver(&message, &Device { now, foreground, permitted, sdk: 35 });
                    shown.show(&effects, now);
                    let shows = counts && !foreground && !model.seen.contains(&id);
                    prop_assert_eq!(shown.last_alert.is_null(), !shows);
                    if shows {
                        let link = format!("hal-c2://threads/env-a/thread-{thread}");
                        prop_assert_eq!(shown.last_alert["link"].as_str(), Some(link.as_str()));
                    }
                    if counts {
                        model.seen.insert(id);
                    }
                }
                Action::Activity { active, sent, permitted, local } => {
                    let at = sent_at(sent, now);
                    let mut message = Map::new();
                    message.insert("v".into(), json!(1));
                    message.insert("sentAt".into(), json!(at as f64));
                    message.insert("activity".into(), activity_at(active, at));
                    if local {
                        message.insert("local".into(), json!(true));
                    }
                    let effects = inbox.deliver(&message, &Device { now, foreground: false, permitted, sdk: 36 });
                    shown.show(&effects, now);
                    prop_assert!(shown.last_alert.is_null());
                    // The model, as the C++ prop's Activity::apply.
                    let last = if local { &mut model.last_local_update } else { &mut model.last_update };
                    if fresh(sent) && permitted && at >= *last {
                        *last = at;
                        let was_active = std::mem::replace(&mut model.last_active, active);
                        // The expected expiry comes from the specified lifetimes
                        // (120 minutes active, 15 finished), not from the
                        // production `activity` the input was built with.
                        let until = at + if active { 120 * MINUTE } else { 15 * MINUTE };
                        if until <= model.now || !model.live {
                            model.card = None;
                            model.dismissed = false;
                        } else {
                            if active && !was_active {
                                model.dismissed = false;
                            }
                            if !model.dismissed {
                                model.card = Some((active, until));
                            }
                        }
                    }
                }
                Action::Dismiss => {
                    let effects = inbox.dismiss();
                    shown.show(&effects, now);
                    prop_assert!(inbox.dismissed());
                    model.dismissed = true;
                    model.card = None;
                }
                Action::Live(on) => {
                    let effects = inbox.set_live_activity(on);
                    shown.show(&effects, now);
                    prop_assert_eq!(inbox.live_activity(), on);
                    model.live = on;
                    model.dismissed = false;
                    if !on {
                        model.card = None;
                    }
                }
                Action::Forget => {
                    let before = inbox.keys().public_key;
                    let effects = inbox.forget();
                    shown.show(&effects, now);
                    prop_assert_eq!(inbox.value("endpoint"), Json::Null);
                    prop_assert_ne!(inbox.keys().public_key, before);
                    let live = model.live;
                    model = Model { now: model.now, live, ..Model::new() };
                    model.now = now;
                }
                Action::Wait(ms) => {
                    now += ms;
                    model.now = now;
                }
            }
            shown.check(&model, now);
        }
    }
}
