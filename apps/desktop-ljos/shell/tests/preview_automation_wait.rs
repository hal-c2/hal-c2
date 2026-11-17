//! An agent's wait for a condition on a page looks at the page once, then
//! when the page says it changed, at most once a frame, and else every
//! BACKSTOP_MS for what a page cannot report, and at its one deadline looks
//! a last time before it gives up. Nothing is armed once the wait ends,
//! however it ends.

mod common;

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

use common::FakeMc;
use hal_c2_shell::Launch;
use hal_c2_shell::mc::SubId;
use hal_c2_shell::preview_automation::{
    AutomationPage, BACKSTOP_MS, Changed, PreviewAutomationHost, ScriptDone, tag,
};
use ljos::App;
use ljos::prelude::Engine;
use ljos::testing::TestWindow;
use serde_json::{Value as Json, json};

/// A page whose condition holds once `shows` is set, and which tells the
/// host when it changed.
#[derive(Default)]
struct Page {
    shows: Cell<bool>,
    /// How many times the condition was looked at.
    looks: Cell<u32>,
    /// Its runtime answers this many ms after it is asked.
    answers_after: Cell<u64>,
    changed: RefCell<Option<Changed>>,
}

impl Page {
    fn change(&self, engine: &Engine, shows: bool) {
        self.shows.set(shows);
        let changed = self.changed.borrow().clone();
        changed.expect("the host listens for changes")(engine);
    }
}

impl AutomationPage for Page {
    fn run_script(&self, engine: &Engine, script: &str, done: ScriptDone) {
        if !script.contains("(\"check\", ") {
            done(engine, Some(json!({"ok": true, "value": {}}).to_string()));
            return;
        }
        self.looks.set(self.looks.get() + 1);
        let answer = Some(json!({"ok": true, "value": self.shows.get()}).to_string());
        match self.answers_after.get() {
            0 => done(engine, answer),
            ms => {
                let at = engine.now() + Duration::from_millis(ms);
                engine.call_at(at, move |engine| done(engine, answer));
            }
        }
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
    fn set_on_change(&self, _: &Engine, changed: Changed) {
        *self.changed.borrow_mut() = Some(changed);
    }
}

struct Sut {
    engine: Engine,
    window: TestWindow,
    mc: Rc<FakeMc>,
    subscription: SubId,
    page: Rc<Page>,
    host: PreviewAutomationHost,
}

impl Sut {
    fn new() -> Sut {
        let engine = App::new("test")
            .register(hal_c2_shell::register)
            .build_engine();
        let window = TestWindow::new(&engine, 100.0, 100.0);
        let mc = Rc::new(FakeMc::default());
        hal_c2_shell::start(&engine, &Launch::default(), mc.clone());
        let host = PreviewAutomationHost::new(mc.clone(), "wait");
        host.set_mcs(&[("mc".into(), "env".into())]);
        let subscription = mc
            .subscriptions()
            .into_iter()
            .find(|(_, shape)| shape["host"]["clientId"] == json!("wait"))
            .map(|(id, _)| id)
            .expect("the host is offered to the MC");
        mc.frame_to(
            &engine,
            subscription,
            json!({"t": "previewAutomation",
                   "event": {"type": "connected", "connectionId": "c1"}}),
        );
        let page = Rc::new(Page::default());
        host.attach(&engine, "thread-1", "tab-1", page.clone());
        Sut {
            engine,
            window,
            mc,
            subscription,
            page,
            host,
        }
    }

    /// An agent waits up to `wait_ms` for `#ready`.
    fn wait_for_ready(&self, wait_ms: u64) {
        let request = json!({
            "requestId": "request-1", "threadId": "thread-1", "tabId": "tab-1",
            "tabIdExplicit": true, "operation": "waitFor",
            "input": {"selector": "#ready", "timeoutMs": wait_ms},
            "timeoutMs": 60_000,
        });
        self.mc.frame_to(
            &self.engine,
            self.subscription,
            json!({"t": "previewAutomation",
                   "event": {"type": "request", "connectionId": "c1", "request": request}}),
        );
    }

    fn advance(&mut self, ms: u64) {
        self.window.advance(ms).unwrap();
    }

    fn answer(&self) -> Option<Json> {
        self.mc
            .calls
            .borrow()
            .iter()
            .find(|(_, method, _)| method == "previewAutomation.respond")
            .map(|(_, _, payload)| payload.clone())
    }

    fn looks(&self) -> u32 {
        self.page.looks.get()
    }

    /// The wait's own schedules still armed.
    fn armed(&self) -> Vec<&'static str> {
        hal_c2_shell::schedule::pending(&self.engine)
            .into_iter()
            .map(|(name, _)| name)
            .filter(|name| name.starts_with("preview wait"))
            .collect()
    }
}

const BACKSTOP: u64 = BACKSTOP_MS as u64;

#[test]
fn an_unchanged_page_is_looked_at_only_at_the_backstop() {
    let mut sut = Sut::new();
    sut.wait_for_ready(10_000);
    sut.advance(5_000);
    assert_eq!(sut.looks() as u64, 1 + 5_000 / BACKSTOP);
    assert!(sut.answer().is_none());
}

#[test]
fn a_change_is_looked_at_within_a_frame() {
    let mut sut = Sut::new();
    sut.wait_for_ready(10_000);
    sut.advance(BACKSTOP / 2);
    let looks = sut.looks();
    sut.page.change(&sut.engine, true);
    let answer = sut.answer().expect("answered once the page changed");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert_eq!(sut.looks(), looks + 1);
    assert!(sut.armed().is_empty(), "{:?} still armed", sut.armed());
}

/// A condition that holds with no change the page reports (a script set a
/// box's `checked`; layout moved by itself) is still seen, at the backstop.
#[test]
fn a_condition_met_with_no_change_heard_is_seen_at_the_backstop() {
    let mut sut = Sut::new();
    sut.wait_for_ready(10_000);
    sut.advance(100);
    sut.page.shows.set(true);
    sut.advance(BACKSTOP - 101);
    assert!(sut.answer().is_none(), "looked before the backstop");
    sut.advance(1);
    let answer = sut.answer().expect("answered at the backstop");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert!(sut.armed().is_empty(), "{:?} still armed", sut.armed());
}

/// A wait shorter than the backstop whose condition comes true with no
/// change the page reports is still met: the deadline looks once more
/// before it gives up.
#[test]
fn a_condition_met_silently_before_a_short_deadline_ends_as_met() {
    let mut sut = Sut::new();
    sut.wait_for_ready(200);
    sut.advance(100);
    sut.page.shows.set(true);
    sut.advance(99);
    assert!(sut.answer().is_none(), "answered before the deadline");
    sut.advance(1);
    let answer = sut.answer().expect("answered at the deadline");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert_eq!(sut.looks(), 2, "one look at the start, one at the deadline");
    assert!(sut.armed().is_empty(), "{:?} still armed", sut.armed());
}

/// The look the deadline makes still decides when it answers late.
#[test]
fn a_slow_last_look_at_the_deadline_decides() {
    let mut sut = Sut::new();
    sut.page.answers_after.set(100);
    sut.wait_for_ready(300);
    sut.advance(150);
    sut.page.shows.set(true);
    sut.advance(150);
    assert!(sut.answer().is_none(), "answered before the last look did");
    sut.advance(100);
    let answer = sut.answer().expect("answered by the last look");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert!(sut.armed().is_empty(), "{:?} still armed", sut.armed());
}

/// A change heard just after a look arms a relook a frame later; a
/// deadline before that frame looks in its place, so one look decides.
#[test]
fn the_deadline_looks_in_place_of_a_pending_relook() {
    let mut sut = Sut::new();
    sut.wait_for_ready(10);
    assert_eq!(sut.looks(), 1, "looked at once");
    sut.page.change(&sut.engine, false);
    assert!(
        sut.armed().contains(&"preview wait look"),
        "{:?} armed",
        sut.armed()
    );
    sut.page.answers_after.set(50);
    sut.advance(100);
    let answer = sut.answer().expect("answered at the deadline");
    assert_eq!(answer["ok"], json!(false), "{answer}");
    assert_eq!(sut.looks(), 2, "one look at the start, one at the deadline");
    assert!(sut.armed().is_empty(), "{:?} still armed", sut.armed());
}

#[test]
fn a_condition_that_never_comes_fails_at_its_deadline() {
    let mut sut = Sut::new();
    sut.wait_for_ready(2_000);
    sut.advance(1_999);
    assert!(sut.answer().is_none(), "gave up before its deadline");
    sut.advance(1);
    let answer = sut.answer().expect("answered at the deadline");
    assert_eq!(answer["ok"], json!(false), "{answer}");
    let error = answer["error"].to_string();
    assert!(
        error.contains(tag::CONDITION_TIMEOUT) && error.contains("did not match within 2000ms"),
        "{answer}"
    );
    assert!(
        sut.looks() as u64 <= 1 + 2_000 / BACKSTOP,
        "looked at an unchanged page {} times",
        sut.looks()
    );
    assert!(sut.armed().is_empty(), "{:?} still armed", sut.armed());
}

#[test]
fn changes_in_a_burst_are_looked_at_once_a_frame() {
    let mut sut = Sut::new();
    sut.wait_for_ready(10_000);
    sut.advance(BACKSTOP / 2);
    let looks = sut.looks();
    for _ in 0..10 {
        sut.page.change(&sut.engine, false);
    }
    sut.advance(100);
    // The first change is looked at at once; the rest wait out the frame
    // and are one look.
    assert_eq!(sut.looks(), looks + 2);
    assert!(sut.answer().is_none());
}

#[test]
fn a_look_still_running_at_the_deadline_counts() {
    let mut sut = Sut::new();
    sut.page.answers_after.set(100);
    sut.wait_for_ready(1_000);
    sut.advance(950);
    sut.page.change(&sut.engine, true);
    sut.advance(150);
    let answer = sut.answer().expect("answered");
    assert_eq!(answer["ok"], json!(true), "{answer}");
}

#[test]
fn a_change_after_the_wait_ended_looks_at_nothing() {
    let mut sut = Sut::new();
    sut.wait_for_ready(500);
    sut.advance(500);
    assert!(sut.answer().is_some());
    let looks = sut.looks();
    sut.page.change(&sut.engine, true);
    sut.advance(100);
    assert_eq!(sut.looks(), looks);
}

/// A tab that goes while a wait runs ends the wait, and with it its looks
/// and its deadline: nothing holds the page until the deadline would have
/// come.
#[test]
fn a_wait_whose_tab_goes_keeps_nothing_armed() {
    let mut sut = Sut::new();
    sut.wait_for_ready(10_000);
    sut.advance(100);
    sut.host.detach(&sut.engine, "tab-1");
    let answer = sut.answer().expect("answered when the tab went");
    assert_eq!(answer["ok"], json!(false), "{answer}");
    assert!(
        answer["error"].to_string().contains(tag::TAB_UNAVAILABLE),
        "{answer}"
    );
    assert!(sut.armed().is_empty(), "{:?} still armed", sut.armed());
    let looks = sut.looks();
    sut.advance(10_000);
    assert_eq!(sut.looks(), looks);
}
