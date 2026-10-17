//! `alerts`: what a thread's change tells the user, and how
//! (features/timeline/notifications.feature,
//! settings/notifications.feature). The store's threads go in as the store
//! hands them over; the platform is a fake presenter and badge.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::alerts::{
    AlertController, AlertRun, AlertThread, MUTED_KEY, Presenter, TOGGLE_MUTE,
};
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::settings::Settings;
use ljos::prelude::{BadgeService, Platform};
use serde_json::json;

use crate::Hub;

/// What the platform was asked, in order.
#[derive(Default)]
struct Fake {
    calls: RefCell<Vec<String>>,
    /// `None`: the system never refuses.
    permitted: Cell<Option<bool>>,
}

impl Presenter for Fake {
    fn show(&self, key: &str, title: &str, body: &str, silent: bool) -> bool {
        self.calls
            .borrow_mut()
            .push(format!("show {key} {title}: {body} silent={silent}"));
        true
    }
    fn clear(&self) {
        self.calls.borrow_mut().push("clear".into());
    }
    fn set_enabled(&self, enabled: bool) {
        self.calls.borrow_mut().push(format!("enabled {enabled}"));
    }
    fn play(&self, kind: &str) {
        self.calls.borrow_mut().push(format!("play {kind}"));
    }
    fn permitted(&self) -> Option<bool> {
        self.permitted.get()
    }
}

impl BadgeService for Fake {
    fn show(&self, count: u32) {
        self.calls.borrow_mut().push(format!("badge {count}"));
    }
}

struct Alerts {
    hub: Hub,
    fake: Rc<Fake>,
}

const TAX: &str = "env-a:tax";
const DOCS: &str = "env-a:docs";

/// A connected shell whose alerts are `mode`, in-app ones `in_app`, with the
/// window unfocused, following "Tax fix" and "Docs" while they work.
fn alerts(test: &str, mode: &str, in_app: bool) -> Alerts {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("hub-alerts")
        .join(test);
    let _ = std::fs::remove_dir_all(&dir);
    let hub = Hub::with(Launch {
        config_dir: Some(dir),
        ..Launch::default()
    });
    let fake = Rc::new(Fake::default());
    let presenter: Rc<dyn Presenter> = fake.clone();
    Platform::of(&hub.engine).set_badge(fake.clone());
    hub.with_controller::<AlertController, _>(|alerts, engine| {
        alerts.set_presenter(presenter);
        alerts.set_focused(engine, false);
    });
    let a = Alerts { hub, fake };
    a.set("notificationMode", json!(mode));
    a.set("inAppNotificationsEnabled", json!(in_app));
    a.hub.mc.set_ready(&a.hub.engine, true);
    a.threads(vec![working(TAX, "Tax fix"), working(DOCS, "Docs")]);
    a.fake.calls.borrow_mut().clear();
    a
}

fn working(key: &str, title: &str) -> AlertThread {
    AlertThread {
        key: key.into(),
        title: title.into(),
        status: "working".into(),
        latest_run: Some(AlertRun {
            run_id: "run-1".into(),
            status: "running".into(),
            completed_at: None,
        }),
        ..AlertThread::default()
    }
}

fn completed(key: &str, title: &str, at: i64) -> AlertThread {
    AlertThread {
        status: "ready".into(),
        latest_run: Some(AlertRun {
            run_id: "run-1".into(),
            status: "completed".into(),
            completed_at: Some(at),
        }),
        ..working(key, title)
    }
}

fn waiting(key: &str, title: &str, status: &str) -> AlertThread {
    AlertThread {
        status: status.into(),
        ..working(key, title)
    }
}

fn failed(key: &str, title: &str) -> AlertThread {
    AlertThread {
        status: "ready".into(),
        latest_run: Some(AlertRun {
            run_id: "run-1".into(),
            status: "failed".into(),
            completed_at: Some(5),
        }),
        ..working(key, title)
    }
}

impl Alerts {
    fn set(&self, key: &str, value: serde_json::Value) {
        Settings::of(&self.hub.engine).set(&self.hub.engine, key, value);
    }

    fn threads(&self, threads: Vec<AlertThread>) {
        self.hub
            .with_controller::<AlertController, _>(|alerts, engine| {
                alerts.set_threads(engine, threads)
            });
    }

    fn focus(&self, focused: bool) {
        self.hub
            .with_controller::<AlertController, _>(|alerts, engine| {
                alerts.set_focused(engine, focused)
            });
    }

    fn calls(&self) -> Vec<String> {
        std::mem::take(&mut *self.fake.calls.borrow_mut())
    }

    fn view(&self, key: &str) {
        self.hub
            .with_controller::<Navigation, _>(|n, e| n.open(e, Route::Thread(key.into())));
    }

    fn toasts(&self) -> Vec<serde_json::Value> {
        self.hub.published("toasts")["items"]
            .as_array()
            .cloned()
            .unwrap_or_default()
    }

    fn mute(&self) {
        assert!(Commands::of(&self.hub.engine).run(&self.hub.engine, TOGGLE_MUTE));
    }

    fn mute_row(&self) -> (String, bool) {
        let row = Commands::of(&self.hub.engine)
            .rows()
            .into_iter()
            .find(|r| r.command == TOGGLE_MUTE)
            .expect("the mute command is there");
        (row.title, row.listed)
    }
}

/// The thread the window shows.
fn shown(hub: &Hub) -> String {
    hub.published("route")["threadKey"]
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

#[test]
fn a_thread_that_changes_state_raises_an_alert() {
    let cases = [
        (completed(TAX, "Tax fix", 10), "Thread completed"),
        (waiting(TAX, "Tax fix", "approval"), "Approval needed"),
        (waiting(TAX, "Tax fix", "input"), "Input needed"),
        (failed(TAX, "Tax fix"), "Thread failed"),
        (waiting(TAX, "Tax fix", "limited"), "Usage limit reached"),
    ];
    for (i, (change, title)) in cases.into_iter().enumerate() {
        let a = alerts(&format!("changes-{i}"), "notifications", false);
        a.threads(vec![change, working(DOCS, "Docs")]);
        let mut expected = vec![format!("show {TAX} {title}: Tax fix silent=true")];
        if i == 0 {
            // An unseen completion counts on the badge.
            expected.insert(0, "badge 1".into());
        }
        assert_eq!(a.calls(), expected);
    }
}

#[test]
fn threads_first_seen_do_not_alert() {
    let a = alerts("first-seen", "notifications-and-sound", true);
    // Finished while the client was closed; a machine that joins with its
    // threads.
    a.threads(vec![
        working(TAX, "Tax fix"),
        working(DOCS, "Docs"),
        completed("env-b:new", "Joined", 10),
    ]);
    assert!(a.calls().is_empty());
}

#[test]
fn an_alert_comes_once_per_change() {
    let a = alerts("once", "notifications", false);
    a.threads(vec![waiting(TAX, "Tax fix", "approval")]);
    assert_eq!(a.calls().len(), 1);
    a.threads(vec![waiting(TAX, "Tax fix", "approval")]);
    assert!(a.calls().is_empty(), "the same wait alerts once");
    // A new run waiting again alerts again.
    let mut again = waiting(TAX, "Tax fix", "approval");
    again.latest_run.as_mut().unwrap().run_id = "run-2".into();
    a.threads(vec![again]);
    assert_eq!(a.calls().len(), 1);
    // Completing alerts, and only a later completion alerts again.
    a.threads(vec![completed(TAX, "Tax fix", 10)]);
    a.threads(vec![completed(TAX, "Tax fix", 10)]);
    a.threads(vec![working(TAX, "Tax fix")]);
    a.threads(vec![completed(TAX, "Tax fix", 20)]);
    let shows: Vec<_> = a
        .calls()
        .into_iter()
        .filter(|c| c.starts_with("show"))
        .collect();
    assert_eq!(shows.len(), 2);
}

#[test]
fn the_thread_being_viewed_does_not_raise_an_in_app_alert() {
    let a = alerts("viewed", "off", true);
    a.focus(true);
    a.view(TAX);
    a.calls();
    a.threads(vec![completed(TAX, "Tax fix", 10), working(DOCS, "Docs")]);
    assert!(a.toasts().is_empty());
    assert!(a.calls().is_empty());
}

#[test]
fn an_in_app_alert_opens_its_thread() {
    let a = alerts("in-app", "notifications", true);
    a.focus(true);
    a.view(DOCS);
    a.threads(vec![
        waiting(TAX, "Tax fix", "approval"),
        working(DOCS, "Docs"),
    ]);
    let toasts = a.toasts();
    assert_eq!(toasts.len(), 1);
    assert_eq!(toasts[0]["type"], "warning");
    assert_eq!(toasts[0]["title"], "Approval needed");
    assert_eq!(toasts[0]["description"], "Tax fix");
    assert_eq!(toasts[0]["actions"][0]["label"], "Open thread");
    // While the window has focus, no system notification.
    assert!(a.calls().iter().all(|c| !c.starts_with("show")));
    let id = toasts[0]["id"].clone();
    a.hub.dispatch(
        "notification.action",
        json!({"id": id, "actionId": "primary"}),
    );
    assert_eq!(shown(&a.hub), TAX);
    assert!(a.toasts().is_empty(), "the alert is gone");
}

#[test]
fn in_app_alerts_say_what_happened() {
    let a = alerts("in-app-kinds", "off", true);
    a.focus(true);
    a.threads(vec![completed(TAX, "Tax fix", 10), failed(DOCS, "Docs")]);
    let kinds: Vec<_> = a
        .toasts()
        .iter()
        .map(|t| {
            format!(
                "{} {}",
                t["type"].as_str().unwrap(),
                t["title"].as_str().unwrap()
            )
        })
        .collect();
    // Newest first.
    assert_eq!(kinds, ["error Thread failed", "success Thread completed"]);
}

#[test]
fn dismissing_an_in_app_alert_opens_nothing() {
    let a = alerts("dismiss", "off", true);
    a.focus(true);
    a.threads(vec![completed(TAX, "Tax fix", 10)]);
    let id = a.toasts()[0]["id"].clone();
    a.hub.dispatch("notification.dismiss", json!({"id": id}));
    assert!(a.toasts().is_empty());
    assert_eq!(shown(&a.hub), "");
}

#[test]
fn the_mode_decides_between_a_notification_and_a_sound() {
    let cases = [
        ("off", vec![]),
        ("notifications", vec!["badge 1", "show"]),
        ("sound", vec!["play completion", "badge 1"]),
        (
            "notifications-and-sound",
            vec!["play completion", "badge 1", "show"],
        ),
    ];
    for (mode, expected) in cases {
        let a = alerts(&format!("mode-{mode}"), mode, false);
        a.threads(vec![completed(TAX, "Tax fix", 10)]);
        let calls: Vec<String> = a
            .calls()
            .into_iter()
            .map(|c| {
                if c.starts_with("show") {
                    "show".into()
                } else {
                    c
                }
            })
            .collect();
        assert_eq!(calls, expected, "{mode}");
    }
}

#[test]
fn an_input_alert_plays_the_input_sound() {
    let a = alerts("input-sound", "sound", false);
    a.threads(vec![waiting(TAX, "Tax fix", "input")]);
    assert_eq!(a.calls(), ["play input"]);
}

#[test]
fn a_newer_alert_for_a_thread_goes_to_the_same_notification() {
    let a = alerts("replace", "notifications", false);
    a.threads(vec![completed(TAX, "Tax fix", 10)]);
    let mut asks = waiting(TAX, "Tax fix", "approval");
    asks.latest_run.as_mut().unwrap().run_id = "run-2".into();
    a.threads(vec![asks]);
    let shows: Vec<_> = a
        .calls()
        .into_iter()
        .filter(|c| c.starts_with("show"))
        .collect();
    // The presenter replaces a key's notification with its newer one.
    assert_eq!(
        shows,
        [
            format!("show {TAX} Thread completed: Tax fix silent=true"),
            format!("show {TAX} Approval needed: Tax fix silent=true"),
        ]
    );
}

#[test]
fn turning_system_notifications_off_clears_them() {
    let a = alerts("off", "notifications", false);
    a.set("notificationMode", json!("sound"));
    assert_eq!(a.calls(), ["clear", "enabled false"]);
    a.set("notificationMode", json!("notifications"));
    assert_eq!(a.calls(), ["clear", "enabled true"]);
}

#[test]
fn the_presenter_starts_as_the_mode_says() {
    let a = alerts("presenter", "notifications", false);
    let fake = Rc::new(Fake::default());
    let presenter: Rc<dyn Presenter> = fake.clone();
    Platform::of(&a.hub.engine).set_badge(fake.clone());
    a.hub
        .with_controller::<AlertController, _>(|alerts, _| alerts.set_presenter(presenter));
    assert_eq!(*fake.calls.borrow(), ["enabled true"]);
}

#[test]
fn notifications_need_the_systems_permission() {
    let a = alerts("permission", "off", false);
    a.fake.permitted.set(Some(false));
    a.set("notificationMode", json!("notifications"));
    let settings = Settings::of(&a.hub.engine);
    assert_eq!(
        settings.setting(&a.hub.engine, "notificationMode"),
        Some(json!("off")),
        "the mode is unchanged"
    );
    let toasts = a.toasts();
    assert_eq!(toasts[0]["type"], "warning");
    assert_eq!(toasts[0]["title"], "Notifications are not allowed");
    assert!(
        toasts[0]["description"]
            .as_str()
            .unwrap()
            .contains("Sound only is still available")
    );
    // Sound alone needs no permission.
    a.set("notificationMode", json!("sound"));
    assert_eq!(
        settings.setting(&a.hub.engine, "notificationMode"),
        Some(json!("sound"))
    );
}

#[test]
fn without_permission_in_app_alerts_and_sounds_still_come() {
    let a = alerts("no-permission", "sound", true);
    a.fake.permitted.set(Some(false));
    a.focus(true);
    a.calls();
    a.threads(vec![completed(TAX, "Tax fix", 10)]);
    assert_eq!(a.calls(), ["play completion"]);
    assert_eq!(a.toasts().len(), 1);
}

#[test]
fn coming_back_to_the_window_clears_notifications_and_the_badge() {
    let a = alerts("focus", "notifications", false);
    a.threads(vec![
        completed(TAX, "Tax fix", 10),
        completed(DOCS, "Docs", 10),
    ]);
    let badges: Vec<_> = a
        .calls()
        .into_iter()
        .filter(|c| c.starts_with("badge"))
        .collect();
    assert_eq!(badges, ["badge 1", "badge 2"]);
    a.focus(true);
    assert_eq!(a.calls(), ["clear", "badge 0"]);
    // Focused, nothing more is counted.
    a.threads(vec![
        completed(TAX, "Tax fix", 20),
        completed(DOCS, "Docs", 10),
    ]);
    assert!(a.calls().is_empty());
}

#[test]
fn threads_that_finished_while_the_connection_was_down_do_not_alert() {
    let a = alerts("reconnect", "notifications", true);
    a.hub.mc.set_ready(&a.hub.engine, false);
    a.hub.mc.set_ready(&a.hub.engine, true);
    // The snapshot after reconnecting is a new baseline.
    a.threads(vec![completed(TAX, "Tax fix", 10), working(DOCS, "Docs")]);
    assert!(a.calls().is_empty());
    assert!(a.toasts().is_empty());
    // What changes after it alerts.
    a.threads(vec![
        completed(TAX, "Tax fix", 10),
        completed(DOCS, "Docs", 10),
    ]);
    assert_eq!(a.calls().len(), 2);
}

#[test]
fn threads_of_other_machines_alert_like_the_mcs_own() {
    let a = alerts("cluster", "notifications", false);
    let other = "env-b:tax";
    a.threads(vec![working(TAX, "Tax fix"), working(other, "Tax fix")]);
    a.threads(vec![
        working(TAX, "Tax fix"),
        completed(other, "Tax fix", 10),
    ]);
    assert!(a.calls().contains(&format!(
        "show {other} Thread completed: Tax fix silent=true"
    )));
}

#[test]
fn archived_threads_and_subagents_do_not_alert() {
    let a = alerts("archived", "notifications", true);
    let mut archived = completed(TAX, "Tax fix", 10);
    archived.archived = true;
    let mut sub = completed(DOCS, "Docs", 10);
    sub.subagent = true;
    a.threads(vec![archived, sub]);
    assert!(a.calls().is_empty());
}

#[test]
fn with_every_alert_off_nothing_is_followed() {
    let a = alerts("all-off", "off", false);
    a.threads(vec![completed(TAX, "Tax fix", 10)]);
    assert!(a.calls().is_empty());
    // Turning alerts on starts afresh: what is there now is the baseline.
    a.set("notificationMode", json!("notifications"));
    a.calls();
    a.threads(vec![completed(TAX, "Tax fix", 10)]);
    assert!(a.calls().is_empty());
    a.threads(vec![completed(TAX, "Tax fix", 20)]);
    assert!(a.calls().iter().any(|c| c.starts_with("show")));
}

#[test]
fn the_user_mutes_and_unmutes_one_thread() {
    let a = alerts("mute", "notifications", false);
    assert_eq!(a.mute_row(), ("Mute alerts for this thread".into(), false));
    a.view(TAX);
    assert_eq!(a.mute_row(), ("Mute alerts for this thread".into(), true));
    a.mute();
    assert_eq!(a.mute_row().0, "Unmute alerts for this thread");
    let settings = Settings::of(&a.hub.engine);
    assert_eq!(settings.device_value(MUTED_KEY), Some(json!([TAX])));

    a.threads(vec![
        completed(TAX, "Tax fix", 10),
        completed(DOCS, "Docs", 10),
    ]);
    let shows: Vec<_> = a
        .calls()
        .into_iter()
        .filter(|c| c.starts_with("show"))
        .collect();
    assert_eq!(
        shows,
        [format!("show {DOCS} Thread completed: Docs silent=true")]
    );

    // Unmuted, only what changes after alerts.
    a.mute();
    assert_eq!(a.mute_row().0, "Mute alerts for this thread");
    assert_eq!(settings.device_value(MUTED_KEY), Some(json!([])));
    a.threads(vec![
        completed(TAX, "Tax fix", 10),
        completed(DOCS, "Docs", 10),
    ]);
    assert!(a.calls().is_empty());
    a.threads(vec![
        completed(TAX, "Tax fix", 20),
        completed(DOCS, "Docs", 10),
    ]);
    assert!(a.calls().iter().any(|c| c.contains(TAX)));
}

#[test]
fn muted_threads_follow_this_devices_preferences() {
    let a = alerts("mute-file", "notifications", false);
    assert!(Settings::of(&a.hub.engine).write_device(&a.hub.engine, MUTED_KEY, json!([TAX])));
    a.view(TAX);
    assert_eq!(a.mute_row().0, "Unmute alerts for this thread");
    let muted = a
        .hub
        .with_controller::<AlertController, _>(|alerts, _| alerts.is_muted(TAX));
    assert!(muted);
}

#[test]
fn clicking_a_system_notification_opens_its_thread_and_raises_the_window() {
    let a = alerts("click", "notifications", false);
    let raised = Rc::new(RefCell::new(Vec::<String>::new()));
    let r = raised.clone();
    let bridge = Bridge::of(&a.hub.engine).object();
    a.hub
        .engine
        .connect_by_name(bridge, "windowCommandRequested", move |engine, args| {
            r.borrow_mut()
                .push(engine.to_js_string(&args[0]).to_string());
        })
        .unwrap();
    let open = |key: &str| {
        a.hub
            .with_controller::<AlertController, _>(|alerts, engine| alerts.open_thread(engine, key))
    };
    assert!(open(TAX));
    assert_eq!(shown(&a.hub), TAX);
    assert_eq!(*raised.borrow(), ["raise"]);
    // An older notification opens its own thread.
    assert!(open(DOCS));
    assert_eq!(shown(&a.hub), DOCS);
    // A thread that is gone opens nothing.
    assert!(!open("env-a:gone"));
    assert_eq!(shown(&a.hub), DOCS);
}

#[test]
fn a_notification_of_a_moved_thread_opens_it_where_it_lives_now() {
    let a = alerts("moved", "notifications", false);
    a.hub.with_controller::<AlertController, _>(|alerts, _| {
        alerts.set_locate(Rc::new(|_, key| {
            if key == "env-old:tax" {
                TAX.to_owned()
            } else {
                key.to_owned()
            }
        }));
    });
    assert!(
        a.hub.with_controller::<AlertController, _>(
            |alerts, engine| alerts.open_thread(engine, "env-old:tax")
        )
    );
    assert_eq!(shown(&a.hub), TAX);
}

#[test]
fn with_system_notifications_off_a_click_opens_nothing() {
    let a = alerts("click-off", "sound", false);
    let opened = a
        .hub
        .with_controller::<AlertController, _>(|alerts, engine| alerts.open_thread(engine, TAX));
    assert!(!opened);
    assert_eq!(shown(&a.hub), "");
}
