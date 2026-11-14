//! The preview automation host against an MC that sends agents' actions in
//! any order: pages answer their scripts when the run says, and time passes
//! in steps. One page does one action at a time, in the order asked; an
//! action whose caller gave up is never started; every action is answered
//! once, before the MC's own deadline.

mod common;

use std::cell::RefCell;
use std::rc::Rc;

use common::FakeMc;
use hal_c2_shell::Launch;
use hal_c2_shell::mc::SubId;
use hal_c2_shell::preview_automation::{AutomationPage, PreviewAutomationHost, ScriptDone};
use ljos::App;
use ljos::prelude::Engine;
use ljos::testing::TestWindow;
use proptest::prelude::*;
use serde_json::json;

const TABS: [&str; 2] = ["tab-a", "tab-b"];

#[derive(Clone, Debug)]
enum Act {
    /// An agent evaluates in tab `0`, giving up after `1` ms.
    Ask(usize, i64),
    /// Tab `0`'s oldest unanswered script answers.
    Answer(usize),
    /// Time passes.
    Wait(u64),
}

fn act() -> impl Strategy<Value = Act> {
    prop_oneof![
        3 => (0..TABS.len(), prop_oneof![Just(400i64), Just(1_000), Just(5_000)])
            .prop_map(|(tab, timeout)| Act::Ask(tab, timeout)),
        3 => (0..TABS.len()).prop_map(Act::Answer),
        2 => (50u64..2_000).prop_map(Act::Wait),
    ]
}

/// A script a page was given: the request it is for, and its answer.
struct Script {
    request: usize,
    done: Option<ScriptDone>,
}

/// What every page saw, and what was wrong when it saw it.
#[derive(Default)]
struct Seen {
    /// Each tab's scripts, in the order they were run.
    scripts: Vec<Vec<Script>>,
    broken: Vec<String>,
}

struct Page {
    tab: usize,
    mc: Rc<FakeMc>,
    seen: Rc<RefCell<Seen>>,
    /// The tab each request was for.
    asked: Rc<RefCell<Vec<usize>>>,
}

fn answered(mc: &FakeMc, request: usize) -> usize {
    let id = format!("request-{request}");
    mc.calls
        .borrow()
        .iter()
        .filter(|(_, method, payload)| {
            method == "previewAutomation.respond" && payload["requestId"] == json!(id)
        })
        .count()
}

impl AutomationPage for Page {
    fn run_script(&self, _: &Engine, script: &str, done: ScriptDone) {
        let request = (0..self.asked.borrow().len())
            .find(|n| script.contains(&format!("'req-{n}'")))
            .unwrap_or(usize::MAX);
        let mut seen = self.seen.borrow_mut();
        if answered(&self.mc, request) > 0 {
            seen.broken
                .push(format!("request {request} ran after it was answered"));
        }
        // One action at a time, in the order asked.
        let asked = self.asked.borrow();
        for earlier in (0..request).filter(|n| asked[*n] == self.tab) {
            if answered(&self.mc, earlier) == 0 {
                seen.broken.push(format!(
                    "request {request} ran while {earlier} was unanswered"
                ));
            }
        }
        if let Some(last) = seen.scripts[self.tab].last().map(|s| s.request)
            && last >= request
        {
            seen.broken
                .push(format!("request {request} ran after {last}"));
        }
        seen.scripts[self.tab].push(Script {
            request,
            done: Some(done),
        });
    }
    fn url(&self, _: &Engine) -> String {
        "http://localhost:5173/".into()
    }
    fn title(&self, _: &Engine) -> String {
        String::new()
    }
    fn loading(&self, _: &Engine) -> bool {
        false
    }
    fn load(&self, _: &Engine, _: &str) {}
    fn dev_tools_open(&self, _: &Engine) -> bool {
        false
    }
    fn on_screen(&self, _: &Engine) -> bool {
        true
    }
    fn viewport(&self, _: &Engine) -> (i32, i32) {
        (1280, 800)
    }
}

struct Sut {
    engine: Engine,
    window: TestWindow,
    mc: Rc<FakeMc>,
    subscription: SubId,
    seen: Rc<RefCell<Seen>>,
    asked: Rc<RefCell<Vec<usize>>>,
    /// When each request was sent, in ms of the run, and its time limit.
    sent: Vec<(u64, i64)>,
    now_ms: u64,
    _host: PreviewAutomationHost,
}

impl Sut {
    fn new() -> Sut {
        let engine = App::new("test")
            .register(hal_c2_shell::register)
            .build_engine();
        let window = TestWindow::new(&engine, 100.0, 100.0);
        let mc = Rc::new(FakeMc::default());
        hal_c2_shell::start(&engine, &Launch::default(), mc.clone());
        let host = PreviewAutomationHost::new(mc.clone(), "prop");
        host.set_mcs(&[("mc".into(), "env".into())]);
        let subscription = mc
            .subscriptions()
            .into_iter()
            .find(|(_, shape)| shape["host"]["clientId"] == json!("prop"))
            .map(|(id, _)| id)
            .expect("the host is offered to the MC");
        mc.frame_to(
            &engine,
            subscription,
            json!({"t": "previewAutomation",
                   "event": {"type": "connected", "connectionId": "c1"}}),
        );
        let seen = Rc::new(RefCell::new(Seen {
            scripts: TABS.iter().map(|_| Vec::new()).collect(),
            broken: Vec::new(),
        }));
        let asked = Rc::new(RefCell::new(Vec::new()));
        for (tab, id) in TABS.iter().enumerate() {
            let page = Rc::new(Page {
                tab,
                mc: mc.clone(),
                seen: seen.clone(),
                asked: asked.clone(),
            });
            host.attach(&engine, "thread-1", id, page);
        }
        Sut {
            engine,
            window,
            mc,
            subscription,
            seen,
            asked,
            sent: Vec::new(),
            now_ms: 0,
            _host: host,
        }
    }

    fn apply(&mut self, act: &Act) {
        match *act {
            Act::Ask(tab, timeout) => {
                let n = self.asked.borrow().len();
                self.asked.borrow_mut().push(tab);
                self.sent.push((self.now_ms, timeout));
                let request = json!({
                    "requestId": format!("request-{n}"), "threadId": "thread-1",
                    "tabId": TABS[tab], "tabIdExplicit": true, "operation": "evaluate",
                    "input": {"expression": format!("'req-{n}'")}, "timeoutMs": timeout,
                });
                self.mc.frame_to(
                    &self.engine,
                    self.subscription,
                    json!({"t": "previewAutomation",
                           "event": {"type": "request", "connectionId": "c1",
                                     "request": request}}),
                );
            }
            Act::Answer(tab) => {
                let done = self.seen.borrow_mut().scripts[tab]
                    .iter_mut()
                    .find_map(|s| s.done.take());
                if let Some(done) = done {
                    done(
                        &self.engine,
                        Some(r#"{"done":true,"value":"1"}"#.to_owned()),
                    );
                }
            }
            Act::Wait(ms) => {
                self.now_ms += ms;
                self.window.advance(ms).unwrap();
            }
        }
        // What the host queued for now.
        self.window.advance(0).unwrap();
    }

    fn check(&self) -> Result<(), TestCaseError> {
        let broken = self.seen.borrow().broken.clone();
        prop_assert!(broken.is_empty(), "{broken:?}");
        for (n, (sent, timeout)) in self.sent.iter().enumerate() {
            let times = answered(&self.mc, n);
            prop_assert!(times <= 1, "request {n} was answered {times} times");
            let waited = (self.now_ms - sent) as i64;
            prop_assert!(
                times == 1 || waited < *timeout,
                "request {n} is unanswered after {waited}ms of its {timeout}ms"
            );
        }
        Ok(())
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    #[test]
    fn agents_actions_take_turns_and_are_answered_in_time(
        acts in prop::collection::vec(act(), 1..40)
    ) {
        let mut sut = Sut::new();
        for act in &acts {
            sut.apply(act);
            sut.check()?;
        }
        // Every action is answered in the end.
        sut.apply(&Act::Wait(10_000));
        sut.check()?;
        for n in 0..sut.sent.len() {
            prop_assert_eq!(answered(&sut.mc, n), 1, "request {}", n);
        }
    }
}
