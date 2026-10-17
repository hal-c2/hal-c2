//! `snapShot`: capturing a window into the composer, and the page and setup
//! wizard around it (SnapShotController.cpp, features/source-control/
//! snap-shot.feature, features/settings/snap-shot.feature), against a fake
//! backend: nothing here captures a real screen.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::snap_shot::{SnapShot, deliver};
use hal_c2_shell::json::Json;
use hal_c2_shell::snap_shot::{Backend, Captured, Event, Mode, Session, Shortcut};
use image::RgbaImage;
use serde_json::json;

use crate::Hub;
use crate::composer::{launch_in, on_threads_with};
use crate::page::toasts;
use crate::workspace::{clustered, project, shell};

/// 2026-09-21T14:13:20Z.
const NOW_MS: f64 = 1_790_000_000_000.0;

/// What the fake desktop holds and was asked.
#[derive(Default)]
pub struct Desktop {
    pub session: Session,
    pub shortcut: Shortcut,
    /// Every call, in order: `probe`, `bind CTRL+SHIFT+2`, `release`, ...
    pub calls: Vec<String>,
    pub bound: Option<String>,
    /// What `capture()` answers at once.
    pub on_capture: Vec<Event>,
    /// What the backend's thread left, taken by `arrive()`.
    pub arrivals: Vec<Event>,
    pub on_probe: Vec<Event>,
    pub played: Vec<String>,
    pub timeouts: Vec<u64>,
}

pub struct Fake(pub Rc<RefCell<Desktop>>);

impl Backend for Fake {
    fn session(&self) -> Session {
        self.0.borrow().session.clone()
    }
    fn shortcut(&self) -> Shortcut {
        self.0.borrow().shortcut.clone()
    }
    fn probe(&mut self) -> Vec<Event> {
        let mut d = self.0.borrow_mut();
        d.calls.push("probe".into());
        std::mem::take(&mut d.on_probe)
    }
    fn bind(&mut self, trigger: &str) -> Vec<Event> {
        let mut d = self.0.borrow_mut();
        d.calls.push(format!("bind {trigger}"));
        d.bound = Some(trigger.to_owned());
        d.shortcut.pending = true;
        d.shortcut.registered = false;
        vec![Event::Changed]
    }
    fn release(&mut self) -> Vec<Event> {
        let mut d = self.0.borrow_mut();
        d.calls.push("release".into());
        d.bound = None;
        d.shortcut = Shortcut::default();
        vec![Event::Changed]
    }
    fn configure(&mut self) -> Vec<Event> {
        self.0.borrow_mut().calls.push("configure".into());
        Vec::new()
    }
    fn capture(&mut self) -> Vec<Event> {
        let mut d = self.0.borrow_mut();
        d.calls.push("capture".into());
        std::mem::take(&mut d.on_capture)
    }
    fn play(&mut self, sound: &str) {
        self.0.borrow_mut().played.push(sound.to_owned());
    }
    fn arrive(&mut self) -> Vec<Event> {
        std::mem::take(&mut self.0.borrow_mut().arrivals)
    }
    fn timeout(&mut self, token: u64) -> Vec<Event> {
        self.0.borrow_mut().timeouts.push(token);
        Vec::new()
    }
}

/// A portal session that is ready, on the desktop `desktop`.
pub fn portal(desktop: &str) -> Session {
    Session {
        ready: true,
        mode: Mode::Portal,
        backend: "screenshot-portal".into(),
        desktop: desktop.into(),
        ..Session::default()
    }
}

/// A window picture of 4 by 3, from `app` titled `title`.
pub fn window(app: &str, title: &str) -> Event {
    Event::Captured(Captured {
        image: RgbaImage::new(4, 3),
        app_name: app.into(),
        window_title: title.into(),
    })
}

/// The shell showing thread t1 of project p1, with the fake as its desktop.
pub fn rig(test: &str, session: Session) -> (Hub, Rc<RefCell<Desktop>>) {
    let hub = on_threads_with(launch_in(test), &["t1"]);
    hub.engine.set_wall_clock_origin(Some(NOW_MS));
    let desktop = Rc::new(RefCell::new(Desktop {
        session,
        ..Desktop::default()
    }));
    install(&hub, &desktop);
    (hub, desktop)
}

pub fn install(hub: &Hub, desktop: &Rc<RefCell<Desktop>>) {
    let fake = Fake(desktop.clone());
    hub.with_controller::<SnapShot, _>(|c, e| c.set_backend(e, Box::new(fake)));
}

pub fn set(hub: &Hub, key: &str, value: Json) {
    Settings::of(&hub.engine).set(&hub.engine, key, value);
}

pub fn setting(hub: &Hub, key: &str) -> Json {
    Settings::of(&hub.engine)
        .setting(&hub.engine, key)
        .unwrap_or(Json::Null)
}

fn page(hub: &Hub) -> Json {
    hub.published("snapShot")
}

/// The chips of the shown composer.
pub fn chips(hub: &Hub) -> Vec<Json> {
    hub.published("composer")["attachments"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

/// The backend's thread reports `events`, and the window is woken for them.
pub fn arrive(hub: &Hub, desktop: &Rc<RefCell<Desktop>>, events: Vec<Event>) {
    desktop.borrow_mut().arrivals.extend(events);
    deliver(&hub.engine);
}

/// The capture shortcut chord ctrl+shift+2, as the page stores it.
pub fn chord() -> Json {
    json!({"key": "2", "metaKey": false, "ctrlKey": false, "shiftKey": true, "altKey": false,
        "modKey": true})
}

fn calls(desktop: &Rc<RefCell<Desktop>>) -> Vec<String> {
    desktop.borrow().calls.clone()
}

#[test]
fn the_page_waits_for_the_desktop_to_answer() {
    let (hub, _) = rig("checking", Session::default());
    assert_eq!(page(&hub)["status"], "Checking snapshots…");
    assert_eq!(page(&hub)["available"], false);
    // Setup cannot open before the desktop has been asked.
    hub.dispatch("snapShot.setup.open", json!({}));
    assert!(page(&hub)["wizard"].is_null());
    assert_eq!(setting(&hub, "snapShotEnabled"), json!(false));
}

#[test]
fn an_unsupported_session_says_why() {
    let (hub, _) = rig(
        "unsupported",
        Session {
            ready: true,
            message: "SnapShots require a Wayland session. X11 capture is not supported.".into(),
            ..Session::default()
        },
    );
    let page = page(&hub);
    assert_eq!(page["available"], false);
    assert_eq!(
        page["status"],
        "SnapShots require a Wayland session. X11 capture is not supported."
    );
    assert_eq!(page["rows"], false);
}

#[test]
fn opening_setup_is_the_opt_in_and_closing_it_unfinished_undoes_it() {
    let (hub, desktop) = rig("opt-in", portal("hyprland"));
    hub.dispatch("snapShot.enable", json!({"on": true}));
    assert_eq!(setting(&hub, "snapShotEnabled"), json!(true));
    let wizard = page(&hub)["wizard"].clone();
    assert_eq!(wizard["step"], "shortcut");
    assert_eq!(wizard["title"], "Set up snapshots for Hyprland");
    assert_eq!(wizard["closeLabel"], "Finish later");
    assert_eq!(page(&hub)["switchOn"], true);
    assert!(calls(&desktop).contains(&"probe".to_owned()));

    hub.dispatch("snapShot.setup.close", json!({"completed": false}));
    assert_eq!(setting(&hub, "snapShotEnabled"), json!(false));
    assert!(page(&hub)["wizard"].is_null());
    assert_eq!(page(&hub)["switchOn"], false);
}

#[test]
fn setup_stays_on_access_while_the_desktop_needs_attention() {
    let (hub, desktop) = rig(
        "attention",
        Session {
            message: "The desktop refused.".into(),
            ..portal("gnome")
        },
    );
    hub.dispatch("snapShot.enable", json!({"on": true}));
    // Not enabled until the user goes on from the access step.
    assert_eq!(setting(&hub, "snapShotEnabled"), json!(false));
    let wizard = page(&hub)["wizard"].clone();
    assert_eq!(wizard["step"], "access");
    assert_eq!(wizard["heading"], "Let's try that again");
    assert_eq!(wizard["details"], "The desktop refused.");
    assert_eq!(wizard["continueLabel"], "Try again");

    hub.dispatch("snapShot.setup.continue", json!({}));
    assert_eq!(setting(&hub, "snapShotEnabled"), json!(true));
    assert_eq!(page(&hub)["wizard"]["step"], "access");

    desktop.borrow_mut().session.message.clear();
    hub.dispatch("snapShot.setup.continue", json!({}));
    assert_eq!(page(&hub)["wizard"]["step"], "shortcut");
    hub.dispatch("snapShot.setup.back", json!({}));
    assert_eq!(page(&hub)["wizard"]["step"], "access");
}

#[test]
fn a_picker_desktop_asks_for_a_window_each_time() {
    let (hub, _) = rig(
        "picker",
        Session {
            backend: "picker".into(),
            ..portal("")
        },
    );
    hub.dispatch("snapShot.enable", json!({"on": true}));
    let wizard = page(&hub)["wizard"].clone();
    assert_eq!(wizard["step"], "access");
    assert_eq!(wizard["heading"], "Choose a window each time");
    assert_eq!(
        page(&hub)["description"],
        "Automatic capture isn't available here. Choose a window instead."
    );
}

#[test]
fn a_recorded_shortcut_is_checked_saved_and_bound() {
    let (hub, desktop) = rig("record", portal("hyprland"));
    hub.dispatch("snapShot.enable", json!({"on": true}));
    // The saved pair cannot be bound on a portal.
    assert!(desktop.borrow().bound.is_none());
    assert_eq!(
        page(&hub)["shortcut"]["status"],
        "Try a shortcut such as Ctrl+Shift+2."
    );

    hub.dispatch("snapShot.record.start", json!({}));
    assert_eq!(page(&hub)["shortcut"]["keys"], "Press shortcut…");
    assert_eq!(
        page(&hub)["shortcut"]["status"],
        "Press your shortcut. Esc cancels."
    );
    // Both Shift keys make a pair, which a portal refuses.
    for code in ["ShiftLeft", "ShiftRight"] {
        hub.dispatch(
            "snapShot.record.modifier",
            json!({"modifier": "shift", "code": code, "down": true}),
        );
    }
    assert_eq!(
        page(&hub)["shortcut"]["status"],
        "Add a letter, number, or function key to your shortcut."
    );
    assert_eq!(page(&hub)["shortcut"]["canSave"], false);

    // Ctrl+Shift+2, as Qt reports the press.
    hub.dispatch(
        "snapShot.record.key",
        json!({"key": 0x32, "modifiers": 0x0400_0000 | 0x0200_0000}),
    );
    let shortcut = page(&hub)["shortcut"].clone();
    assert_eq!(shortcut["recording"], false);
    assert_eq!(shortcut["keys"], "Ctrl+Shift+2");
    assert_eq!(shortcut["status"], "Ready to save.");
    assert_eq!(shortcut["canSave"], true);
    assert_eq!(page(&hub)["wizard"]["doneLabel"], "Save and finish");

    hub.dispatch("snapShot.setup.done", json!({}));
    assert_eq!(setting(&hub, "snapShotShortcut")["key"], "2");
    assert_eq!(desktop.borrow().bound.as_deref(), Some("CTRL+SHIFT+2"));
    // The desktop's prompt is still open, which setup accepts.
    assert!(page(&hub)["wizard"].is_null());
    assert_eq!(page(&hub)["status"], "Waiting for shortcut permission");
}

#[test]
fn a_shortcut_the_system_or_the_app_uses_cannot_be_saved() {
    let (hub, _) = rig("conflicts", portal("hyprland"));
    hub.dispatch("snapShot.enable", json!({"on": true}));
    hub.dispatch("snapShot.record.start", json!({}));
    // Ctrl+C alone: the terminals' interrupt.
    hub.dispatch(
        "snapShot.record.key",
        json!({"key": 0x43, "modifiers": 0x0400_0000}),
    );
    assert_eq!(
        page(&hub)["shortcut"]["status"],
        "This shortcut is Copy in most apps."
    );
    assert_eq!(page(&hub)["shortcut"]["canSave"], false);
    hub.dispatch("snapShot.shortcut.save", json!({}));
    assert_eq!(setting(&hub, "snapShotShortcut")["kind"], "both-shift-keys");

    // A key HAL-C2 binds itself (the palette's Ctrl+K).
    hub.dispatch("snapShot.record.start", json!({}));
    hub.dispatch(
        "snapShot.record.key",
        json!({"key": 0x4b, "modifiers": 0x0400_0000}),
    );
    let status = page(&hub)["shortcut"]["status"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        status.starts_with("HAL-C2 already uses this for"),
        "{status}"
    );

    hub.dispatch("snapShot.shortcut.discard", json!({}));
    assert_eq!(page(&hub)["shortcut"]["changed"], false);
}

#[test]
fn escape_stops_recording_and_a_press_while_recording_is_not_a_capture() {
    let (hub, desktop) = rig("escape", portal("hyprland"));
    set(&hub, "snapShotEnabled", json!(true));
    hub.dispatch("snapShot.record.start", json!({}));
    arrive(&hub, &desktop, vec![Event::Activated]);
    assert!(!calls(&desktop).contains(&"capture".to_owned()));
    hub.dispatch(
        "snapShot.record.key",
        json!({"key": 0x0100_0000, "modifiers": 0}),
    );
    assert_eq!(page(&hub)["shortcut"]["recording"], false);
    arrive(&hub, &desktop, vec![Event::Activated]);
    assert!(calls(&desktop).contains(&"capture".to_owned()));
}

#[test]
fn the_toggles_and_the_sound_are_device_settings() {
    let (hub, desktop) = rig("toggles", portal("niri"));
    let page0 = page(&hub);
    assert_eq!(
        page0["accessibility"]["status"],
        "This desktop only provides a screenshot."
    );
    assert_eq!(page0["accessibility"]["checked"], false);
    assert_eq!(
        page0["flash"]["status"],
        "Capture effects aren't available on Niri."
    );
    assert_eq!(page0["sound"]["value"], "soft-pop");
    assert_eq!(page0["sound"]["label"], "Whoosh (Default)");

    hub.dispatch("snapShot.sound", json!({"value": "camera-shutter"}));
    assert_eq!(page(&hub)["sound"]["label"], "Click");
    hub.dispatch("snapShot.sound", json!({"value": "off"}));
    assert_eq!(page(&hub)["sound"]["value"], "off");
    assert_eq!(setting(&hub, "snapShotPlaySound"), json!(false));
    hub.dispatch("snapShot.set", json!({"key": "flash", "value": false}));
    assert_eq!(setting(&hub, "snapShotFlash"), json!(false));
    hub.dispatch("snapShot.set", json!({"key": "nothing", "value": true}));
    hub.dispatch("snapShot.sound.play", json!({"sound": "camera-shutter"}));
    assert_eq!(desktop.borrow().played, ["camera-shutter"]);
}

#[test]
fn the_shortcut_is_bound_only_while_capture_is_on() {
    let (hub, desktop) = rig("binding", portal("hyprland"));
    set(&hub, "snapShotShortcut", chord());
    assert!(desktop.borrow().bound.is_none());
    set(&hub, "snapShotEnabled", json!(true));
    assert_eq!(desktop.borrow().bound.as_deref(), Some("CTRL+SHIFT+2"));
    let binds = calls(&desktop)
        .iter()
        .filter(|c| c.starts_with("bind"))
        .count();
    // Following again changes nothing.
    set(&hub, "snapShotFlash", json!(false));
    assert_eq!(
        calls(&desktop)
            .iter()
            .filter(|c| c.starts_with("bind"))
            .count(),
        binds
    );
    hub.dispatch("snapShot.enable", json!({"on": false}));
    assert!(desktop.borrow().bound.is_none());
    assert_eq!(page(&hub)["enabled"], false);
}

#[test]
fn a_capture_joins_the_shown_thread_draft() {
    let (hub, desktop) = rig("capture", portal("hyprland"));
    set(&hub, "snapShotEnabled", json!(true));
    desktop.borrow_mut().on_capture = vec![window("  Terminal ", "make test ")];
    arrive(&hub, &desktop, vec![Event::Activated]);
    assert_eq!(desktop.borrow().played, ["soft-pop"]);
    let chips = chips(&hub);
    assert_eq!(chips.len(), 1);
    assert_eq!(chips[0]["name"], "window-2026-09-21T14-13-20.000Z.png");
    assert_eq!(chips[0]["source"]["appName"], "Terminal");
    assert_eq!(chips[0]["source"]["windowTitle"], "make test");
    assert!(toasts(&hub).is_empty());
}

#[test]
fn a_capture_from_the_picker_arrives_later() {
    let (hub, desktop) = rig("later", portal("hyprland"));
    set(&hub, "snapShotEnabled", json!(true));
    set(&hub, "snapShotPlaySound", json!(false));
    arrive(&hub, &desktop, vec![Event::Activated]);
    assert!(chips(&hub).is_empty());
    arrive(&hub, &desktop, vec![window("", "")]);
    let chips = chips(&hub);
    assert_eq!(chips.len(), 1);
    // The portal names neither app nor title.
    assert_eq!(chips[0]["source"]["appName"], "Window");
    assert!(desktop.borrow().played.is_empty());
}

#[test]
fn a_capture_goes_to_the_draft_the_window_shows() {
    let (hub, desktop) = rig("draft", portal("hyprland"));
    set(&hub, "snapShotEnabled", json!(true));
    hub.dispatch("thread.new", json!(null));
    assert_eq!(hub.published("route")["kind"], "draft");
    desktop.borrow_mut().on_capture = vec![window("Editor", "main.rs")];
    arrive(&hub, &desktop, vec![Event::Activated]);
    assert_eq!(hub.published("route")["kind"], "draft");
    assert_eq!(chips(&hub).len(), 1);
    assert!(toasts(&hub).is_empty());
}

#[test]
fn a_capture_whose_thread_is_gone_starts_a_draft() {
    let (hub, desktop) = rig("gone", portal("hyprland"));
    set(&hub, "snapShotEnabled", json!(true));
    // The thread the window showed is no longer in the cluster, and the
    // window is somewhere else.
    hub.dispatch("settings.open", json!({}));
    hub.mc.frame(
        &hub.engine,
        "shell",
        "",
        json!({"t": "shell",
            "mcs": [{"mc": "a", "online": true, "epoch": "e", "rev": 2,
                     "environment": {"environmentId": "env-1", "label": "env-1"}}],
            "rows": [project(json!({}))]}),
    );
    desktop.borrow_mut().on_capture = vec![window("Editor", "main.rs")];
    arrive(&hub, &desktop, vec![Event::Activated]);
    assert_eq!(hub.published("route")["kind"], "draft");
    assert_eq!(chips(&hub).len(), 1);
}

#[test]
fn a_capture_with_no_project_says_so() {
    let hub = clustered(launch_in("no-project"));
    hub.mc.set_ready(&hub.engine, true);
    shell(&hub, vec![]);
    let desktop = Rc::new(RefCell::new(Desktop {
        session: portal("hyprland"),
        ..Desktop::default()
    }));
    install(&hub, &desktop);
    set(&hub, "snapShotEnabled", json!(true));
    desktop.borrow_mut().on_capture = vec![window("Editor", "main.rs")];
    arrive(&hub, &desktop, vec![Event::Activated]);
    assert_eq!(
        toasts(&hub),
        [(
            "Snapshot taken, but no project is available".to_owned(),
            "Add a project, then capture the window again.".to_owned()
        )]
    );
}

#[test]
fn a_failed_capture_is_a_toast() {
    let (hub, desktop) = rig("failed", portal("hyprland"));
    set(&hub, "snapShotEnabled", json!(true));
    arrive(
        &hub,
        &desktop,
        vec![Event::Failed("The portal said no.".into())],
    );
    assert_eq!(
        toasts(&hub),
        [(
            "Snapshot failed".to_owned(),
            "The portal said no.".to_owned()
        )]
    );
}

#[test]
fn a_capture_too_big_to_attach_is_a_failure() {
    let (hub, desktop) = rig("too-big", portal("hyprland"));
    set(&hub, "snapShotEnabled", json!(true));
    hub.with_controller::<SnapShot, _>(|c, _| c.set_max_image_bytes(8));
    arrive(&hub, &desktop, vec![window("Editor", "main.rs")]);
    assert!(chips(&hub).is_empty());
    assert_eq!(
        toasts(&hub),
        [(
            "Snapshot failed".to_owned(),
            "The captured window is too large to attach.".to_owned()
        )]
    );
}

#[test]
fn the_backend_is_called_back_when_it_asked_and_not_when_it_cancelled() {
    let (hub, desktop) = rig("timers", portal("hyprland"));
    arrive(
        &hub,
        &desktop,
        vec![
            Event::After {
                token: 1,
                ms: 5_000,
            },
            Event::After {
                token: 2,
                ms: 8_000,
            },
            Event::Cancel(2),
        ],
    );
    hub.advance(4_999);
    assert!(desktop.borrow().timeouts.is_empty());
    hub.advance(1);
    assert_eq!(desktop.borrow().timeouts, [1]);
    hub.advance(10_000);
    assert_eq!(desktop.borrow().timeouts, [1]);
}
