//! The Notifications controller over a fake push system and a fake MC
//! (#1877): what a distributor switch, a registration, forgetting the
//! environment, the activity card and a tapped notification do, through
//! the actions and links the app itself takes.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;

use hal_c2_mobile::notifications;
use hal_c2_mobile::pairing::{self, Environment};
use hal_c2_mobile::push_inbox::Inbox;
use hal_c2_mobile::push_system::{Answered, Changed, Distributor, Permission, PushSystem};
use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller as shell_controller;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Mc, McError, OnFrame, OnReady, Reply, Resume, SubId};
use ljos::App;
use ljos::prelude::{ApplicationState, Engine};
use ljos::testing::TestWindow;
use serde_json::json;

/// 2026-09-23T10:10:00Z, the fake system's wall clock.
const NOW: i64 = 1_790_158_200_000;
const UPDATED: &str = "2026-09-23T10:00:00.000Z";

/// A push system the test drives: granted, on a fixed clock, with the
/// distributors it is given. Every subscribe and unsubscribe is recorded
/// in order, and everything it was asked to show is kept.
#[derive(Default)]
struct FakePush {
    distributors: RefCell<Vec<Distributor>>,
    now: Cell<i64>,
    events: RefCell<Vec<String>>,
    shown: RefCell<Vec<Json>>,
    changed: RefCell<Option<Changed>>,
}

impl FakePush {
    fn new(distributors: &[&str]) -> Rc<FakePush> {
        Rc::new(FakePush {
            distributors: RefCell::new(
                distributors
                    .iter()
                    .map(|id| Distributor {
                        id: (*id).into(),
                        label: (*id).into(),
                    })
                    .collect(),
            ),
            now: Cell::new(NOW),
            ..FakePush::default()
        })
    }

    fn events(&self) -> Vec<String> {
        self.events.borrow().clone()
    }

    fn shown(&self) -> Vec<Json> {
        self.shown.borrow().clone()
    }

    /// The last effects carrying an activity card, if any were shown.
    fn last_card(&self) -> Option<Json> {
        self.shown
            .borrow()
            .iter()
            .rev()
            .find_map(|effects| effects.get("card").cloned())
    }

    /// The distributor's endpoint changed (or went), as the system tells it.
    fn fire_changed(&self, engine: &Engine) {
        let changed = self.changed.borrow().clone().expect("a changed hook");
        changed(engine);
    }
}

impl PushSystem for FakePush {
    fn supported(&self) -> bool {
        true
    }

    fn sdk(&self) -> i32 {
        36
    }

    fn permission(&self) -> Permission {
        Permission::Granted
    }

    fn request_permission(&self, engine: &Engine, answered: Answered) {
        answered(engine, Permission::Granted);
    }

    fn open_settings(&self) {}

    fn open_live_update_settings(&self) {}

    fn distributors(&self) -> Vec<Distributor> {
        self.distributors.borrow().clone()
    }

    fn subscribe(&self, distributor: &str) {
        self.events
            .borrow_mut()
            .push(format!("subscribe:{distributor}"));
    }

    fn unsubscribe(&self) {
        self.events.borrow_mut().push("unsubscribe".into());
    }

    fn show(&self, effects: &Json) {
        self.shown.borrow_mut().push(effects.clone());
    }

    fn now(&self) -> i64 {
        self.now.get()
    }

    fn set_changed(&self, changed: Changed) {
        *self.changed.borrow_mut() = Some(changed);
    }
}

/// An MC that answers nothing on its own: the test says when it is ready,
/// sends its shell frames, and reads and answers what was called.
#[derive(Default)]
struct FakeMc {
    ready: Cell<bool>,
    next: Cell<u64>,
    on_ready: RefCell<Vec<OnReady>>,
    subs: RefCell<Vec<(SubId, Json, Option<OnFrame>)>>,
    calls: RefCell<Vec<(String, String, Json)>>,
    replies: RefCell<Vec<Option<Reply>>>,
}

impl FakeMc {
    fn hello(&self, engine: &Engine) {
        self.ready.set(true);
        let mut told = self.on_ready.take();
        for f in &mut told {
            f(engine, true);
        }
        self.on_ready.borrow_mut().extend(told);
    }

    fn calls(&self, method: &str) -> Vec<(String, Json)> {
        self.calls
            .borrow()
            .iter()
            .filter(|(_, m, _)| m == method)
            .map(|(env, _, payload)| (env.clone(), payload.clone()))
            .collect()
    }

    /// Answers the oldest unanswered call to `method`.
    fn answer(&self, engine: &Engine, method: &str, result: Result<Json, McError>) {
        let index = {
            let calls = self.calls.borrow();
            let replies = self.replies.borrow();
            (0..calls.len()).find(|&i| calls[i].1 == method && replies[i].is_some())
        }
        .unwrap_or_else(|| panic!("no unanswered {method}"));
        let reply = self.replies.borrow_mut()[index].take().expect("unanswered");
        reply(engine, result);
    }

    /// Sends `frame` to the shell's subscriptions, as the MC would.
    fn send(&self, engine: &Engine, frame: Json) {
        let frame = frame.as_object().expect("a frame is an object").clone();
        let shells: Vec<SubId> = self
            .subs
            .borrow()
            .iter()
            .filter(|(_, shape, _)| shape["type"] == "shell")
            .map(|(id, _, _)| *id)
            .collect();
        assert!(!shells.is_empty(), "nothing follows the shell");
        for id in shells {
            let handler = self
                .subs
                .borrow_mut()
                .iter_mut()
                .find(|sub| sub.0 == id)
                .and_then(|sub| sub.2.take());
            let Some(mut handler) = handler else { continue };
            handler(engine, &frame);
            if let Some(sub) = self.subs.borrow_mut().iter_mut().find(|sub| sub.0 == id) {
                sub.2 = Some(handler);
            }
        }
    }
}

impl Mc for FakeMc {
    fn is_ready(&self) -> bool {
        self.ready.get()
    }

    fn environment(&self) -> String {
        "env-1".into()
    }

    fn call(&self, environment: &str, method: &str, payload: Json, reply: Reply) {
        self.calls
            .borrow_mut()
            .push((environment.into(), method.into(), payload));
        self.replies.borrow_mut().push(Some(reply));
    }

    fn subscribe(&self, shape: Json, on_frame: OnFrame, _resume: Option<Resume>) -> SubId {
        self.next.set(self.next.get() + 1);
        let id = SubId(self.next.get());
        self.subs.borrow_mut().push((id, shape, Some(on_frame)));
        id
    }

    fn unsubscribe(&self, id: SubId) {
        self.subs.borrow_mut().retain(|sub| sub.0 != id);
    }

    fn more(&self, _id: SubId, _items: u32) {}

    fn on_ready_changed(&self, f: OnReady) {
        self.on_ready.borrow_mut().push(f);
    }

    fn open(&self, _origin: &str, _token: &str) -> Result<(), String> {
        Ok(())
    }
}

/// The phone started, paired with env-1, over `push` and a push inbox
/// holding `distributor` and `endpoint` (either may be empty for none).
struct Phone {
    engine: Engine,
    window: TestWindow,
    mc: Rc<FakeMc>,
    push: Rc<FakePush>,
    data: PathBuf,
    _home: tempfile::TempDir,
}

impl Phone {
    fn start(name: &str, push: Rc<FakePush>, distributor: &str, endpoint: &str) -> Phone {
        let home = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).expect("a home");
        let dir = |part: &str| Some(home.path().join(part));
        let data = home.path().join("data");
        assert!(pairing::save(
            &data.join("pairing.json"),
            &Environment {
                origin: "http://127.0.0.1:9".into(),
                token: "session".into(),
                label: "env-1".into(),
                environment_id: "env-1".into(),
                expires_at: String::new(),
            },
        ));
        let inbox = Inbox::new(&data);
        if !distributor.is_empty() {
            inbox.set_value("distributor", json!(distributor));
        }
        if !endpoint.is_empty() {
            inbox.set_value("endpoint", json!(endpoint));
        }
        drop(inbox);

        ljos::render::set_fonts(ljos::render::Fonts::Bundled);
        let engine = App::new(name)
            .register(hal_c2_mobile::register)
            .source(hal_c2_mobile::pack())
            .root("Main")
            .build_engine();
        // Before the shell starts, for its timers to start on the window's clock.
        let mut window = TestWindow::new(&engine, 412.0, 915.0);
        let mc = Rc::new(FakeMc::default());
        let launch = Launch {
            config_dir: dir("config"),
            cache_dir: dir("cache"),
            data_dir: dir("data"),
            state_dir: dir("state"),
            ..Launch::default()
        };
        hal_c2_mobile::install(&engine, launch.data_dir.clone(), launch.config_dir.clone());
        notifications::set_system(&engine, push.clone());
        hal_c2_shell::start_with(&engine, &launch, mc.clone(), hal_c2_mobile::registrations());
        hal_c2_mobile::start(&engine);
        let root = hal_c2_shell::runtime::open(&engine).expect("the phone's shell is made");
        window.show(root).expect("a root");
        window.advance(100).expect("at rest");
        Phone {
            engine,
            window,
            mc,
            push,
            data,
            _home: home,
        }
    }

    fn inbox(&self, key: &str) -> Json {
        Inbox::new(&self.data).value(key)
    }

    fn dispatch(&mut self, action: &str, payload: Json) {
        Bridge::of(&self.engine).dispatch(&self.engine, action, payload);
        self.window.advance(10).expect("at rest");
    }

    fn published(&self) -> Json {
        Bridge::of(&self.engine)
            .published(&self.engine, "notifications")
            .expect("the notifications state")
    }

    /// The app coming to the front, as the system tells it.
    fn come_to_front(&mut self) {
        ljos::testing::set_application_state(&self.engine, ApplicationState::Inactive);
        ljos::testing::set_application_state(&self.engine, ApplicationState::Active);
        self.window.advance(10).expect("at rest");
    }
}

fn thread_row(title: &str, updated: &str) -> Json {
    json!({
        "id": "t1", "projectId": "p1", "title": title,
        "createdAt": UPDATED, "updatedAt": updated,
        "runtimeMode": "full-access", "interactionMode": "default",
        "latestRunId": "r1", "status": "running",
    })
}

/// A shell snapshot: env-1 (on mc-a) with one project and its rows beside it.
fn snapshot(rows: Vec<Json>) -> Json {
    let mut all = vec![json!(["mc-a", "p1", "project",
        {"id": "p1", "title": "Proj", "workspaceRoot": "/work/proj",
         "createdAt": UPDATED, "updatedAt": UPDATED}])];
    all.extend(rows);
    json!({
        "t": "shell",
        "mcs": [{"mc": "mc-a", "environment": {"environmentId": "env-1"},
                 "online": true, "epoch": "e1", "rev": 1}],
        "rows": all,
    })
}

#[test]
fn enabling_on_the_only_distributor_clears_the_old_ones_endpoint() {
    // Saved a.example is gone and b.example is the only one installed:
    // enabling lands on b as a switch, so a's endpoint goes until b
    // gives its own, and the phone does not read as enabled on it.
    let push = FakePush::new(&["b.example"]);
    let mut phone = Phone::start("notif-switch", push, "a.example", "https://a.example/old");

    phone.dispatch("notifications.enable", json!({}));

    assert_eq!(phone.inbox("distributor"), json!("b.example"));
    assert_eq!(
        phone.inbox("endpoint"),
        json!(""),
        "the old distributor's endpoint was kept for the new one"
    );
    assert_eq!(
        phone.push.events().last().map(String::as_str),
        Some("subscribe:b.example")
    );
    let state = phone.published();
    assert_eq!(state["distributor"], json!("b.example"), "{state}");
    assert_eq!(state["enabled"], json!(false), "{state}");
}

#[test]
fn registering_sends_once_and_an_error_lets_it_send_again() {
    let push = FakePush::new(&["b.example"]);
    let phone = Phone::start("notif-register", push, "b.example", "https://b.example/ep");

    phone.mc.hello(&phone.engine);
    let sent = phone.mc.calls("hal-c2.registerPush");
    assert_eq!(sent.len(), 1, "registered: {sent:?}");
    assert_eq!(sent[0].0, "env-1");
    assert_eq!(sent[0].1["endpoint"], json!("https://b.example/ep"));
    assert_eq!(sent[0].1["distributor"], json!("b.example"));
    assert!(
        !sent[0].1["keys"]["p256dh"]
            .as_str()
            .unwrap_or_default()
            .is_empty(),
        "no push keys sent: {}",
        sent[0].1
    );

    // The same registration is not sent twice on one connection.
    phone.push.fire_changed(&phone.engine);
    assert_eq!(phone.mc.calls("hal-c2.registerPush").len(), 1);

    phone.mc.answer(
        &phone.engine,
        "hal-c2.registerPush",
        Err(McError::new("no route")),
    );
    let state = phone.published();
    assert!(
        state["message"]
            .as_str()
            .unwrap_or_default()
            .contains("could not be registered for notifications: no route"),
        "{state}"
    );

    // The error cleared what was sent, so the next word registers again.
    phone.push.fire_changed(&phone.engine);
    assert_eq!(phone.mc.calls("hal-c2.registerPush").len(), 2);
}

#[test]
fn forgetting_unregisters_then_subscribes_afresh() {
    let push = FakePush::new(&["b.example"]);
    let mut phone = Phone::start("notif-forget", push, "b.example", "https://b.example/ep");
    phone.mc.hello(&phone.engine);
    assert_eq!(phone.mc.calls("hal-c2.registerPush").len(), 1);
    let before = phone.push.events().len();

    phone.dispatch("pairing.forget", json!({"id": "env-1"}));

    // The MC is told while it still hears the phone.
    let unregistered = phone.mc.calls("hal-c2.unregisterPush");
    assert_eq!(unregistered.len(), 1, "unregistered: {unregistered:?}");
    assert_eq!(unregistered[0].0, "env-1");
    // The distributor lets go, then is asked again for a fresh endpoint
    // for whatever environment is paired next; the old endpoint is gone
    // and the user's distributor choice stays.
    assert_eq!(
        phone.push.events()[before..].to_vec(),
        ["unsubscribe".to_string(), "subscribe:b.example".to_string()]
    );
    assert_eq!(phone.inbox("endpoint"), Json::Null);
    assert_eq!(phone.inbox("distributor"), json!("b.example"));
}

#[test]
fn the_activity_card_comes_from_the_rows_and_expiry_alone_republishes_nothing() {
    let push = FakePush::new(&["b.example"]);
    let mut phone = Phone::start("notif-activity", push, "b.example", "https://b.example/ep");
    phone.come_to_front();
    let shown_before = phone.push.shown().len();

    phone.mc.send(
        &phone.engine,
        snapshot(vec![json!([
            "mc-a",
            "t1",
            "thread",
            thread_row("Fix bug", UPDATED)
        ])]),
    );
    phone.window.advance(10).expect("at rest");

    let card = phone.push.last_card().expect("a card was shown");
    assert_eq!(card["title"], json!("Fix bug"), "{card}");
    assert_eq!(card["text"], json!("Working · Proj"), "{card}");
    assert_eq!(card["ongoing"], json!(true), "{card}");
    assert_eq!(card["link"], json!("hal-c2://threads/env-1/t1"), "{card}");

    // Five minutes on, the same work: only the card's expiry moved, so
    // nothing new goes up.
    phone.push.now.set(NOW + 5 * 60 * 1000);
    let shown = phone.push.shown().len();
    phone.mc.send(
        &phone.engine,
        json!({"t": "shell.rows", "mc": "mc-a", "epoch": "e1", "rev": 2,
               "rows": [["t1", "thread", thread_row("Fix bug", "2026-09-23T10:05:00.000Z")]]}),
    );
    phone.window.advance(10).expect("at rest");
    assert_eq!(
        phone.push.shown().len(),
        shown,
        "an expiry-only change was shown again"
    );
    assert!(shown > shown_before, "the first card never went up");

    // A change the card shows does go up again.
    phone.mc.send(
        &phone.engine,
        json!({"t": "shell.rows", "mc": "mc-a", "epoch": "e1", "rev": 3,
               "rows": [["t1", "thread", thread_row("Fix bug harder", "2026-09-23T10:06:00.000Z")]]}),
    );
    phone.window.advance(10).expect("at rest");
    let card = phone.push.last_card().expect("a card was shown");
    assert_eq!(card["title"], json!("Fix bug harder"), "{card}");
}

#[test]
fn a_tapped_notification_opens_a_moved_thread_where_it_lives_now() {
    let push = FakePush::new(&["b.example"]);
    let phone = Phone::start("notif-moved", push, "b.example", "https://b.example/ep");

    // t1 moved from env-old to env-new: env-old's row only forwards,
    // env-new's is the live one.
    phone.mc.send(
        &phone.engine,
        json!({
            "t": "shell",
            "mcs": [
                {"mc": "mc-a", "environment": {"environmentId": "env-old"},
                 "online": true, "epoch": "e1", "rev": 1},
                {"mc": "mc-b", "environment": {"environmentId": "env-new"},
                 "online": true, "epoch": "e1", "rev": 1},
            ],
            "rows": [
                ["mc-a", "t1", "thread", {"id": "t1", "movedTo": {"environmentId": "env-new"}}],
                ["mc-b", "t1", "thread", thread_row("Moved work", UPDATED)],
            ],
        }),
    );

    notifications::open_link(&phone.engine, "hal-c2://threads/env-old/t1");

    let route =
        shell_controller::with::<Navigation, _>(&phone.engine, |nav, _| nav.route().clone());
    assert_eq!(
        route,
        Some(Route::Thread("env-new:t1".into())),
        "the tapped notification did not open the moved thread"
    );
}
