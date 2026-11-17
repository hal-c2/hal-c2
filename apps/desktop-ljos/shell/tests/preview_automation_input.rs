//! An agent's click and key reach a page as the user's would, and the host
//! answers by what the page saw: a click the page never saw is done by
//! script, a key it never saw fails, and a load the input started is the
//! page seeing it (the document that would say so is gone), but a load
//! long after it is not, and nor is one after a key kept from the page.

mod common;

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

use common::FakeMc;
use hal_c2_shell::Launch;
use hal_c2_shell::mc::SubId;
use hal_c2_shell::preview_automation::{AutomationPage, PreviewAutomationHost, ScriptDone, tag};
use ljos::App;
use ljos::input::Modifiers;
use ljos::prelude::{Engine, Time};
use ljos::testing::TestWindow;
use serde_json::{Value as Json, json};

/// The runtime's operations the host asks the page for.
const OPS: [&str; 6] = [
    "clickTarget",
    "clickScript",
    "clicked",
    "armKey",
    "keyScript",
    "key",
];

/// What the page does with the input it is given.
#[derive(Clone, Copy)]
struct Takes {
    /// It can take input: it is on screen, nothing of the app covers it.
    input: bool,
    /// Its runtime sees the input once it came.
    sees: bool,
    /// A load starts this many ms after the input: a link, a form sent
    /// with Enter, or a reload that only happens to come after it.
    loads: Option<u64>,
    /// The key was kept from the page: what took the keyboard first had it.
    kept: bool,
    /// Its runtime answers this many ms after it is asked: a page
    /// navigating away is slow to.
    answers_after: u64,
}

struct Page {
    takes: Takes,
    /// The runtime's operations, in the order the host asked for them.
    ops: RefCell<Vec<String>>,
    given: Cell<bool>,
    loads: Rc<Cell<u64>>,
    load_starts: Rc<RefCell<Vec<Time>>>,
}

impl Page {
    fn give(&self, engine: &Engine) -> bool {
        if !self.takes.input {
            return false;
        }
        self.given.set(true);
        if let Some(ms) = self.takes.loads {
            let (loads, starts) = (self.loads.clone(), self.load_starts.clone());
            engine.call_at(engine.now() + Duration::from_millis(ms), move |engine| {
                loads.set(loads.get() + 1);
                starts.borrow_mut().push(engine.now());
            });
        }
        true
    }
}

/// The runtime operation `script` calls: its name is the last call's.
fn op(script: &str) -> &'static str {
    OPS.into_iter()
        .filter_map(|op| script.rfind(&format!("(\"{op}\", ")).map(|at| (at, op)))
        .max()
        .map_or("", |(_, op)| op)
}

impl AutomationPage for Page {
    fn run_script(&self, engine: &Engine, script: &str, done: ScriptDone) {
        let op = op(script);
        self.ops.borrow_mut().push(op.to_owned());
        let value = match op {
            "clickTarget" => json!({"x": 10, "y": 20}),
            "clicked" | "key" if self.given.get() && self.takes.sees => json!({}),
            "clicked" | "key" => Json::Null,
            _ => json!({}),
        };
        let answer = Some(json!({"ok": true, "value": value}).to_string());
        match self.takes.answers_after {
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
    fn loads_started(&self, _: &Engine) -> u64 {
        self.loads.get()
    }
    fn load_started_at(&self, _: &Engine, load: u64) -> Option<Time> {
        let at = usize::try_from(load.checked_sub(1)?).ok()?;
        self.load_starts.borrow().get(at).copied()
    }
    fn click(&self, engine: &Engine, _: f64, _: f64) -> bool {
        self.give(engine)
    }
    fn key(&self, engine: &Engine, _: i32, _: Modifiers, _: &str) -> bool {
        self.give(engine)
    }
    fn input_reached(&self, _: &Engine) -> Option<bool> {
        self.given.get().then_some(!self.takes.kept)
    }
}

struct Sut {
    engine: Engine,
    window: TestWindow,
    mc: Rc<FakeMc>,
    subscription: SubId,
    page: Rc<Page>,
    _host: PreviewAutomationHost,
}

impl Sut {
    fn new(takes: Takes) -> Sut {
        let engine = App::new("test")
            .register(hal_c2_shell::register)
            .build_engine();
        let window = TestWindow::new(&engine, 100.0, 100.0);
        let mc = Rc::new(FakeMc::default());
        hal_c2_shell::start(&engine, &Launch::default(), mc.clone());
        let host = PreviewAutomationHost::new(mc.clone(), "input");
        host.set_mcs(&[("mc".into(), "env".into())]);
        let subscription = mc
            .subscriptions()
            .into_iter()
            .find(|(_, shape)| shape["host"]["clientId"] == json!("input"))
            .map(|(id, _)| id)
            .expect("the host is offered to the MC");
        mc.frame_to(
            &engine,
            subscription,
            json!({"t": "previewAutomation",
                   "event": {"type": "connected", "connectionId": "c1"}}),
        );
        let page = Rc::new(Page {
            takes,
            ops: RefCell::default(),
            given: Cell::new(false),
            loads: Rc::default(),
            load_starts: Rc::default(),
        });
        host.attach(&engine, "thread-1", "tab-1", page.clone());
        Sut {
            engine,
            window,
            mc,
            subscription,
            page,
            _host: host,
        }
    }

    /// Asks for `operation` with `input`, then lets `ms` pass; the answer.
    fn ask(&mut self, operation: &str, input: Json, ms: u64) -> Option<Json> {
        let request = json!({
            "requestId": "request-1", "threadId": "thread-1", "tabId": "tab-1",
            "tabIdExplicit": true, "operation": operation, "input": input,
            "timeoutMs": 10_000,
        });
        self.mc.frame_to(
            &self.engine,
            self.subscription,
            json!({"t": "previewAutomation",
                   "event": {"type": "request", "connectionId": "c1", "request": request}}),
        );
        let mut left = ms;
        while left > 0 && self.answer().is_none() {
            let step = left.min(50);
            self.window.advance(step).unwrap();
            left -= step;
        }
        self.answer()
    }

    fn answer(&self) -> Option<Json> {
        self.mc
            .calls
            .borrow()
            .iter()
            .find(|(_, method, _)| method == "previewAutomation.respond")
            .map(|(_, _, payload)| payload.clone())
    }

    fn asked(&self, op: &str) -> bool {
        self.page.ops.borrow().iter().any(|o| o == op)
    }
}

fn click() -> Json {
    json!({"selector": "#go"})
}

fn enter() -> Json {
    json!({"key": "Enter"})
}

#[test]
fn a_click_the_page_saw_is_done() {
    let mut sut = Sut::new(Takes {
        input: true,
        sees: true,
        loads: None,
        kept: false,
        answers_after: 0,
    });
    let answer = sut.ask("click", click(), 2_000).expect("answered");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert!(sut.asked("clicked"));
    assert!(!sut.asked("clickScript"), "clicked once, by the user's way");
}

#[test]
fn a_click_the_page_never_saw_is_done_by_script() {
    let mut sut = Sut::new(Takes {
        input: true,
        sees: false,
        loads: None,
        kept: false,
        answers_after: 0,
    });
    let answer = sut.ask("click", click(), 3_000).expect("answered");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert!(sut.asked("clickScript"));
}

#[test]
fn a_click_the_page_cannot_take_is_done_by_script_at_once() {
    let mut sut = Sut::new(Takes {
        input: false,
        sees: false,
        loads: None,
        kept: false,
        answers_after: 0,
    });
    let answer = sut.ask("click", click(), 200).expect("answered at once");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert!(sut.asked("clickScript"));
}

/// A link: the new document's runtime was never armed, so it never says it
/// saw the click, and clicking again by script would follow the link twice.
#[test]
fn a_click_that_starts_a_load_is_done_once() {
    let mut sut = Sut::new(Takes {
        input: true,
        sees: false,
        loads: Some(100),
        kept: false,
        answers_after: 0,
    });
    let answer = sut.ask("click", click(), 600).expect("answered at once");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert!(!sut.asked("clickScript"));
}

#[test]
fn a_key_the_page_saw_is_done() {
    let mut sut = Sut::new(Takes {
        input: true,
        sees: true,
        loads: None,
        kept: false,
        answers_after: 0,
    });
    let answer = sut.ask("press", enter(), 2_000).expect("answered");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert!(!sut.asked("keyScript"));
}

/// The key went to whatever took the keyboard: pressing it again by script
/// would press it twice where it did reach.
#[test]
fn a_key_the_page_never_saw_fails() {
    let mut sut = Sut::new(Takes {
        input: true,
        sees: false,
        loads: None,
        kept: false,
        answers_after: 0,
    });
    let answer = sut.ask("press", enter(), 8_000).expect("answered");
    assert_eq!(answer["ok"], json!(false), "{answer}");
    assert_eq!(answer["error"]["_tag"], json!(tag::CONDITION_TIMEOUT));
    assert!(!sut.asked("keyScript"));
}

/// Enter sent a form: the new document has nothing to say about the key.
#[test]
fn a_key_that_starts_a_load_is_done() {
    let mut sut = Sut::new(Takes {
        input: true,
        sees: false,
        loads: Some(0),
        kept: false,
        answers_after: 0,
    });
    let answer = sut.ask("press", enter(), 600).expect("answered at once");
    assert_eq!(answer["ok"], json!(true), "{answer}");
}

#[test]
fn a_key_the_page_cannot_take_is_pressed_by_script() {
    let mut sut = Sut::new(Takes {
        input: false,
        sees: false,
        loads: None,
        kept: false,
        answers_after: 0,
    });
    let answer = sut.ask("press", enter(), 200).expect("answered at once");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert!(sut.asked("keyScript"));
}

/// The dev server reloads the page well after a click that went nowhere:
/// the click is still done, by script.
#[test]
fn a_load_long_after_a_click_is_not_the_click() {
    let mut sut = Sut::new(Takes {
        input: true,
        sees: false,
        loads: Some(800),
        kept: false,
        answers_after: 0,
    });
    let answer = sut.ask("click", click(), 3_000).expect("answered");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert!(sut.asked("clickScript"));
}

#[test]
fn a_load_long_after_a_key_is_not_the_key() {
    let mut sut = Sut::new(Takes {
        input: true,
        sees: false,
        loads: Some(800),
        kept: false,
        answers_after: 0,
    });
    let answer = sut.ask("press", enter(), 8_000).expect("answered");
    assert_eq!(answer["ok"], json!(false), "{answer}");
    assert_eq!(answer["error"]["_tag"], json!(tag::CONDITION_TIMEOUT));
}

/// The key was kept from the page, and the page reloads on its own just
/// after: the reload is not the key's.
#[test]
fn a_load_after_a_key_kept_from_the_page_is_not_the_key() {
    let mut sut = Sut::new(Takes {
        input: true,
        sees: false,
        loads: Some(100),
        kept: true,
        answers_after: 0,
    });
    let answer = sut.ask("press", enter(), 8_000).expect("answered");
    assert_eq!(answer["ok"], json!(false), "{answer}");
    assert_eq!(answer["error"]["_tag"], json!(tag::CONDITION_TIMEOUT));
}

/// A link whose navigation starts at once, on a page slow to answer while
/// it navigates away: the load is the click's, though the check that finds
/// it comes after the half second.
#[test]
fn a_load_a_slow_page_reports_late_is_still_the_clicks() {
    let mut sut = Sut::new(Takes {
        input: true,
        sees: false,
        loads: Some(50),
        kept: false,
        answers_after: 600,
    });
    let answer = sut.ask("click", click(), 3_000).expect("answered");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert!(!sut.asked("clickScript"), "not clicked a second time");
}

#[test]
fn a_load_a_slow_page_reports_late_is_still_the_keys() {
    let mut sut = Sut::new(Takes {
        input: true,
        sees: false,
        loads: Some(50),
        kept: false,
        answers_after: 600,
    });
    let answer = sut.ask("press", enter(), 3_000).expect("answered");
    assert_eq!(answer["ok"], json!(true), "{answer}");
}

/// The page answers only after the click's wait is over, and the link's
/// load started while it was answering: the click is done, not clicked
/// again by script.
#[test]
fn a_load_a_page_reports_after_the_wait_is_still_the_clicks() {
    let mut sut = Sut::new(Takes {
        input: true,
        sees: false,
        loads: Some(50),
        kept: false,
        answers_after: 1200,
    });
    let answer = sut.ask("click", click(), 3_000).expect("answered");
    assert_eq!(answer["ok"], json!(true), "{answer}");
    assert!(!sut.asked("clickScript"), "not clicked a second time");
}
