//! The phone's state machines under every order of calls, as
//! mobile-qt's RapidCheck props hold their C++ (tests/prop/
//! tst_PairingProp, tst_MobileTerminalProp, tst_ResumeProp): the
//! pairing's phases, the terminal context's chosen lines, and the
//! resume decision. A failure a property finds also gets a plain
//! regression test beside its class.

use hal_c2_mobile::mobile_terminal::{Context, HeldInput, apply_held};
use hal_c2_mobile::pairing::{Begun, Core, Environment, Offered};
use hal_c2_mobile::resume::{AppState, Decision, Resume};
use proptest::prelude::*;

fn environment(id: &str) -> Environment {
    Environment {
        origin: "http://mc.example:3780".into(),
        token: "session".into(),
        label: "My MacBook".into(),
        environment_id: id.into(),
    }
}

#[derive(Clone, Debug)]
enum PairAction {
    Add,
    Cancel,
    Begin(bool),
    OfferValid,
    OfferInvalid,
    FailStale,
    FailCurrent,
    PairOwnStale,
    Forget,
}

fn pair_action() -> impl Strategy<Value = PairAction> {
    prop_oneof![
        Just(PairAction::Add),
        Just(PairAction::Cancel),
        any::<bool>().prop_map(PairAction::Begin),
        Just(PairAction::OfferValid),
        Just(PairAction::OfferInvalid),
        Just(PairAction::FailStale),
        Just(PairAction::FailCurrent),
        Just(PairAction::PairOwnStale),
        Just(PairAction::Forget),
    ]
}

proptest! {
    /// Whatever order pairing is driven in, what the screen reads stays
    /// consistent: pairing with another only over an environment, an
    /// offered address only with the link it came with, no attempt in
    /// flight while unpaired-and-idle claims to pair, and a stale
    /// exchange never changes anything.
    #[test]
    fn pairing_core_stays_consistent(
        starts_paired: bool,
        actions in prop::collection::vec(pair_action(), 0..40),
    ) {
        let mut core = Core {
            paired: starts_paired.then(|| environment("env-1")),
            ..Core::default()
        };
        for action in actions {
            let before = core.clone();
            match action {
                PairAction::Add => {
                    core.add();
                    if before.paired.is_none() {
                        prop_assert!(!core.adding);
                    }
                }
                PairAction::Cancel => {
                    core.cancel();
                    prop_assert_eq!(&core.paired, &before.paired, "cancel loses nothing");
                    if before.pairing {
                        prop_assert_eq!(
                            core.adding, before.adding,
                            "no way back while a link is spent"
                        );
                    }
                }
                PairAction::Begin(read) => {
                    let begun = core.begin("http://mc.example:3780/pair#token=t", read);
                    if before.pairing {
                        prop_assert_eq!(begun, Begun::Refused);
                        prop_assert_eq!(core.attempt, before.attempt);
                    }
                    if !read && !before.pairing {
                        prop_assert!(!core.error.is_empty());
                        prop_assert!(!core.pairing);
                    }
                }
                PairAction::OfferValid => {
                    let offered = core.offer(Some((
                        "http://other.example/pair#token=t".into(),
                        "http://other.example".into(),
                    )));
                    if before.pairing {
                        prop_assert_eq!(offered, Offered::Busy);
                        prop_assert_eq!(&core.link, &before.link);
                    } else {
                        prop_assert_eq!(offered, Offered::Shown);
                        prop_assert_eq!(core.offered.as_str(), "http://other.example");
                        prop_assert_eq!(core.adding, core.paired.is_some());
                    }
                }
                PairAction::OfferInvalid => {
                    let offered = core.offer(None);
                    if !before.pairing {
                        prop_assert_eq!(&core.paired, &before.paired);
                        prop_assert!(offered == Offered::Said || offered == Offered::Toast);
                    }
                }
                PairAction::FailStale => {
                    let stale = core.attempt.wrapping_add(1);
                    prop_assert!(!core.fail(stale, "late".into()));
                    prop_assert_eq!(core.pairing, before.pairing);
                    prop_assert_eq!(&core.error, &before.error);
                }
                PairAction::FailCurrent => {
                    core.fail(core.attempt, "no".into());
                    prop_assert!(!core.pairing);
                    prop_assert_eq!(&core.paired, &before.paired);
                }
                PairAction::PairOwnStale => {
                    let stale = core.attempt.wrapping_add(1);
                    prop_assert!(!core.paired_own(stale, environment("env-2")));
                    prop_assert_eq!(&core.paired, &before.paired);
                }
                PairAction::Forget => {
                    core.forgotten();
                    prop_assert!(core.paired.is_none());
                    prop_assert!(!core.pairing);
                    prop_assert!(!core.adding);
                    prop_assert!(core.link.is_empty() && core.offered.is_empty());
                    prop_assert_eq!(core.attempt, before.attempt + 1);
                }
            }
            prop_assert!(!core.adding || core.paired.is_some(), "adding over nothing");
            prop_assert!(core.offered.is_empty() || !core.link.is_empty());
            prop_assert_eq!(
                core.phase(),
                if core.pairing {
                    "pairing"
                } else if core.paired.is_some() {
                    "paired"
                } else {
                    "unpaired"
                }
            );
        }
    }

    /// Two taps bound the chosen lines, in order, and the text is
    /// always a run of the lines the terminal showed.
    #[test]
    fn context_taps_bound_a_run_of_lines(
        lines in prop::collection::vec("[a-z ]{0,8}", 1..12),
        taps in prop::collection::vec(0usize..16, 0..20),
    ) {
        let Some(mut context) = Context::open(lines.clone()) else {
            return Ok(());
        };
        for tap in taps {
            context.tap(tap);
            prop_assert!(context.start <= context.end);
            prop_assert!(context.end < context.lines.len());
            prop_assert_eq!(
                context.text(),
                context.lines[context.start..=context.end].join("\n")
            );
        }
    }

    /// A held modifier is spent by the transformation itself: ctrl
    /// makes control codes of letters, the paste chord pastes, meta
    /// prefixes Escape, and nothing comes out empty from a key.
    #[test]
    fn held_modifiers_write_keys(
        held in prop_oneof![Just("ctrl"), Just("alt"), Just("cmd")],
        data in "[a-zA-Z0-9?@]{1}",
        darwin: bool,
    ) {
        match apply_held(held, &data, darwin) {
            HeldInput::Paste => {
                prop_assert!(data.eq_ignore_ascii_case("v"));
                prop_assert_eq!(held, if darwin { "cmd" } else { "ctrl" });
            }
            HeldInput::Write(keys) => prop_assert!(!keys.is_empty()),
        }
    }

    /// The resume decision: a long enough stay away replaces a ready
    /// connection once, and no other order of states does.
    #[test]
    fn resume_replaces_only_after_a_long_ready_stay(
        threshold in 0i64..60_000,
        stays in prop::collection::vec((0i64..120_000, any::<bool>()), 0..12),
    ) {
        let mut resume = Resume::new();
        resume.set_threshold(threshold);
        let mut now = 0i64;
        for (stay, ready) in stays {
            prop_assert_eq!(
                resume.state_changed(AppState::Hidden, now, ready),
                Decision::Keep
            );
            prop_assert_eq!(
                resume.state_changed(AppState::Inactive, now + stay / 2, ready),
                Decision::Keep
            );
            let back = now + stay;
            let decision = resume.state_changed(AppState::Active, back, ready);
            prop_assert_eq!(
                decision,
                if ready && stay >= threshold {
                    Decision::Reconnect
                } else {
                    Decision::Keep
                }
            );
            // Back and staying back never replaces it twice.
            prop_assert_eq!(
                resume.state_changed(AppState::Active, back + 1, ready),
                Decision::Keep
            );
            now = back + 2;
        }
    }
}
