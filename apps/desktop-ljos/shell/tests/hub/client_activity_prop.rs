//! The reports to the MC as a state machine: the route moving between two
//! threads, a draft and a page with none, the application gaining and
//! losing focus, the MC dropping and coming back, and the renewal timer.
//! Each report is made when the MC is there and something it says changed
//! (or it is renewed), and says exactly what the window shows and whether
//! it is focused at that moment; nothing is said while the MC is gone.

use hal_c2_shell::controllers::client_activity::REPORT_MS;
use ljos::prelude::ApplicationState;
use proptest::prelude::*;
use serde_json::json;

use crate::Hub;
use crate::client_activity::{hub, reports, watched};
use crate::composer::open;

#[derive(Clone, Copy, Debug)]
enum Op {
    Thread(usize),
    Draft,
    Page,
    Focus(bool),
    /// The MC drops, or says hello again (a hello on one that is there is
    /// the same hello).
    Ready(bool),
    Renew,
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        4 => (0usize..2).prop_map(Op::Thread),
        2 => Just(Op::Draft),
        2 => Just(Op::Page),
        3 => any::<bool>().prop_map(Op::Focus),
        2 => any::<bool>().prop_map(Op::Ready),
        2 => Just(Op::Renew),
    ]
}

/// What the window shows.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Shown {
    Thread(usize),
    Draft,
    Page,
}

impl Shown {
    /// The scopes a report names for it, beyond provider status.
    fn scopes(self) -> Vec<String> {
        match self {
            Shown::Thread(0) => vec!["thread:t1".into(), "vcs:/w/p".into()],
            Shown::Thread(_) => vec!["thread:t2".into(), "vcs:/w/wt".into()],
            Shown::Draft => vec!["vcs:/w/p".into()],
            Shown::Page => Vec::new(),
        }
    }
}

struct World {
    hub: Hub,
    shown: Shown,
    focused: bool,
    ready: bool,
    /// The reports the model expects after the setup, as scopes and focus.
    expected: Vec<(Vec<String>, bool)>,
    base: usize,
}

impl World {
    fn new() -> World {
        let hub = hub("client-activity-prop");
        let base = reports(&hub).len();
        World {
            hub,
            shown: Shown::Thread(0),
            focused: true,
            ready: true,
            expected: Vec::new(),
            base,
        }
    }

    fn report(&mut self) {
        self.expected.push((self.shown.scopes(), self.focused));
    }

    fn show(&mut self, shown: Shown) {
        // Asking for a draft while on one shows that draft.
        let changed = shown != self.shown;
        self.shown = shown;
        if changed && self.ready {
            self.report();
        }
    }

    fn step(&mut self, op: Op) {
        match op {
            Op::Thread(i) => {
                open(&self.hub, ["t1", "t2"][i]);
                self.show(Shown::Thread(i));
            }
            Op::Draft => {
                self.hub.dispatch("thread.new", json!(null));
                self.show(Shown::Draft);
            }
            Op::Page => {
                self.hub.dispatch("usage.open", json!({}));
                self.show(Shown::Page);
            }
            Op::Focus(focused) => {
                let state = if focused {
                    ApplicationState::Active
                } else {
                    ApplicationState::Inactive
                };
                ljos::testing::set_application_state(&self.hub.engine, state);
                let changed = focused != self.focused;
                self.focused = focused;
                if changed && self.ready {
                    self.report();
                }
            }
            Op::Ready(ready) => {
                self.hub.mc.set_ready(&self.hub.engine, ready);
                self.ready = ready;
                if ready {
                    self.report();
                }
            }
            Op::Renew => {
                self.hub.advance(REPORT_MS as u64);
                if self.ready {
                    self.report();
                }
            }
        }
    }

    fn check(&self) {
        let made: Vec<_> = reports(&self.hub)[self.base..]
            .iter()
            .map(|(_, report)| (watched(report), report["focused"] == json!(true)))
            .collect();
        assert_eq!(made, self.expected);
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 48, ..ProptestConfig::default() })]

    #[test]
    fn every_report_says_what_the_window_shows_and_whether_it_has_focus(
        ops in proptest::collection::vec(op(), 1..30)
    ) {
        let mut world = World::new();
        for op in ops {
            world.step(op);
            world.check();
        }
    }
}
