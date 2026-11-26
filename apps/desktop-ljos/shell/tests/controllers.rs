//! The controller framework and the controllers ported so far, driven as
//! the bricks drive them: through `Shell.dispatch` and `Shell.state`.

mod common;

use std::cell::RefCell;
use std::rc::Rc;

use common::{FakeMc, shell, text};
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller::{self, Controller, Init, Registration, Scope};
use hal_c2_shell::controllers::client_activity::REPORT_MS;
use hal_c2_shell::controllers::layout::{
    CONTENT_MIN_WIDTH, Layout, RAIL_WIDTH, SIDEBAR_MIN_WIDTH, SIDEBAR_WIDTH,
};
use hal_c2_shell::controllers::navigation::{self, Navigation, Route};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::theme::{Mode, Themes, canonical_color};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Disconnected, Mc, McError};
use ljos::App;
use ljos::prelude::Engine;
use serde_json::json;

const EMPTY: &str = "import QtQuick\nItem {}\n";

fn disconnected() -> Rc<dyn Mc> {
    Rc::new(Disconnected::default())
}

fn published(engine: &Engine, key: &str) -> Json {
    Bridge::of(engine)
        .published(engine, key)
        .unwrap_or(Json::Null)
}

fn dispatch(engine: &Engine, action: &str, payload: Json) {
    Bridge::of(engine).dispatch(engine, action, payload);
}

// The framework, with controllers of its own that log what they are asked.

thread_local! {
    static LOG: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
}

fn log(entry: String) {
    LOG.with(|l| l.borrow_mut().push(entry));
}

fn take_log() -> Vec<String> {
    LOG.with(|l| std::mem::take(&mut *l.borrow_mut()))
}

macro_rules! logger {
    ($ty:ident, $name:literal, $claims:literal) => {
        struct $ty;
        impl Controller for $ty {
            fn new(init: Init<'_, Self>) -> Self {
                log(format!("new {}", $name));
                init.bridge.publish(init.engine, $name, json!("built"));
                $ty
            }
            fn activate(&mut self, _: &Engine) {
                log(format!("activate {}", $name));
            }
            fn attach(&mut self, _: &Engine, window: &controller::Window) {
                log(format!("attach {} {}", $name, window.id));
            }
            fn handle(&mut self, _: &Engine, action: &str, _: &Json) -> bool {
                log(format!("handle {} {action}", $name));
                action == $claims
            }
        }
    };
}

logger!(Alpha, "alpha", "a.do");
logger!(Beta, "beta", "b.do");
logger!(Gamma, "gamma", "g.do");

fn framework() -> Engine {
    take_log();
    let engine = App::new("test")
        .register(hal_c2_shell::register)
        .build_engine();
    controller::start(
        &engine,
        disconnected(),
        vec![
            Registration::new::<Gamma>("gamma", &["gamma"], Scope::Window),
            Registration::new::<Beta>("beta", &["beta"], Scope::Shared),
            Registration::new::<Alpha>("alpha", &["alpha"], Scope::Window),
        ],
    );
    engine
}

#[test]
fn controllers_build_shared_first_then_in_name_order() {
    let engine = framework();
    assert_eq!(take_log(), ["new beta", "new alpha", "new gamma"]);
    assert_eq!(controller::names(&engine), ["alpha", "beta", "gamma"]);
    assert_eq!(published(&engine, "gamma"), json!("built"));
}

#[test]
fn shared_controllers_activate_first_then_meet_the_window() {
    let engine = framework();
    take_log();
    controller::activate(&engine);
    assert_eq!(
        take_log(),
        [
            "activate beta",
            "activate alpha",
            "activate gamma",
            "attach beta main"
        ]
    );
}

#[test]
fn an_action_is_offered_in_name_order_until_one_takes_it() {
    let engine = framework();
    take_log();
    dispatch(&engine, "b.do", json!(null));
    assert_eq!(take_log(), ["handle alpha b.do", "handle beta b.do"]);
    dispatch(&engine, "nobody.does", json!(null));
    assert_eq!(
        take_log(),
        [
            "handle alpha nobody.does",
            "handle beta nobody.does",
            "handle gamma nobody.does"
        ]
    );
}

#[test]
fn a_controller_reaches_another_by_type() {
    let engine = framework();
    assert!(controller::controller::<Beta>(&engine).is_some());
    assert!(controller::controller::<Gamma>(&engine).is_some());
    assert!(controller::controller::<Layout>(&engine).is_none());
}

// layout

#[test]
fn the_sidebar_toggles_and_keeps_the_thread_its_room() {
    let (engine, _) = shell(EMPTY, disconnected());
    assert_eq!(
        published(&engine, "layout")["sidebarWidth"],
        json!(SIDEBAR_WIDTH)
    );
    dispatch(&engine, "sidebar.toggle", json!(null));
    assert_eq!(
        published(&engine, "layout")["sidebarCollapsed"],
        json!(true)
    );
    dispatch(&engine, "sidebar.toggle", json!(null));
    dispatch(&engine, "layout.window", json!({"width": 1000}));
    dispatch(&engine, "sidebar.resize", json!({"width": 900}));
    assert_eq!(
        published(&engine, "layout")["sidebarWidth"],
        json!(1000 - CONTENT_MIN_WIDTH)
    );
    dispatch(&engine, "sidebar.resize", json!({"width": 10}));
    assert_eq!(
        published(&engine, "layout")["sidebarWidth"],
        json!(SIDEBAR_MIN_WIDTH)
    );
}

#[test]
fn a_narrow_window_shows_the_sidebar_over_the_thread() {
    let (engine, _) = shell(EMPTY, disconnected());
    dispatch(
        &engine,
        "layout.window",
        json!({"width": SIDEBAR_MIN_WIDTH + CONTENT_MIN_WIDTH - 1}),
    );
    // The rail stays beside the thread; its toggle opens the list over it.
    let layout = published(&engine, "layout");
    assert_eq!(
        (
            &layout["sidebarMode"],
            &layout["sidebarWidth"],
            &layout["sidebarOverlay"]
        ),
        (&json!("rail"), &json!(RAIL_WIDTH), &json!(false))
    );
    dispatch(&engine, "sidebar.toggle", json!(null));
    let layout = published(&engine, "layout");
    assert_eq!(
        (
            &layout["sidebarOverlay"],
            &layout["sidebarCollapsed"],
            &layout["sidebarWidth"]
        ),
        (&json!(true), &json!(false), &json!(SIDEBAR_MIN_WIDTH))
    );
    // Widening forgets the overlay was open; the docked sidebar was never collapsed.
    dispatch(&engine, "layout.window", json!({"width": 1400}));
    let layout = published(&engine, "layout");
    assert_eq!(
        (&layout["sidebarOverlay"], &layout["sidebarCollapsed"]),
        (&json!(false), &json!(false))
    );
}

// navigation

fn route(engine: &Engine) -> Route {
    controller::controller::<Navigation>(engine)
        .unwrap()
        .borrow()
        .route()
        .clone()
}

#[test]
fn back_returns_through_the_places_visited_but_not_home() {
    let (engine, _) = shell(EMPTY, disconnected());
    assert_eq!(published(&engine, "route")["kind"], json!("home"));
    dispatch(&engine, "thread.open", json!({"key": "e:t1"}));
    dispatch(&engine, "usage.open", json!(null));
    dispatch(&engine, "settings.open", json!(null));
    dispatch(&engine, "keybindings.open", json!(null));
    assert_eq!(
        route(&engine),
        Route::Settings("/settings/keybindings".into())
    );
    assert_eq!(published(&engine, "route")["canGoBack"], json!(true));
    // Settings to settings does not stack.
    dispatch(&engine, "settings.back", json!(null));
    assert_eq!(route(&engine), Route::Usage);
    dispatch(&engine, "settings.back", json!(null));
    assert_eq!(route(&engine), Route::Thread("e:t1".into()));
    dispatch(&engine, "settings.back", json!(null));
    assert_eq!(route(&engine), Route::Home);
    assert_eq!(published(&engine, "route")["canGoBack"], json!(false));
}

#[test]
fn a_route_watcher_hears_the_route_change_but_not_a_new_title() {
    let (engine, _) = shell(EMPTY, disconnected());
    let heard = Rc::new(RefCell::new(Vec::new()));
    let log = heard.clone();
    navigation::on_route_changed(&engine, Bridge::of(&engine), move |_, route| {
        log.borrow_mut().push(route["threadKey"].clone());
    });
    dispatch(&engine, "thread.open", json!({"key": "e:t1"}));
    let mut renamed = published(&engine, "route");
    renamed["title"] = json!("Renamed");
    Bridge::of(&engine).publish(&engine, "route", renamed.clone());
    renamed["tab"] = json!("elsewhere");
    Bridge::of(&engine).publish(&engine, "route", renamed);
    dispatch(&engine, "thread.open", json!({"key": "e:t2"}));
    // The first publish (home) comes before the watcher; each thread once.
    assert_eq!(*heard.borrow(), vec![json!("e:t1"), json!("e:t2")]);
}

#[test]
fn forward_returns_where_back_left_until_somewhere_new() {
    let (engine, _) = shell(EMPTY, disconnected());
    dispatch(&engine, "thread.open", json!({"key": "e:t1"}));
    dispatch(&engine, "pullRequests.open", json!(null));
    dispatch(&engine, "settings.back", json!(null));
    let nav = controller::controller::<Navigation>(&engine).unwrap();
    nav.borrow_mut().forward(&engine);
    assert_eq!(route(&engine), Route::PullRequests);
    dispatch(&engine, "settings.back", json!(null));
    dispatch(&engine, "usage.open", json!(null));
    nav.borrow_mut().forward(&engine);
    assert_eq!(route(&engine), Route::Usage);
}

#[test]
fn a_settings_result_opens_its_section_and_reveals_its_row() {
    let (engine, _) = shell(EMPTY, disconnected());
    dispatch(
        &engine,
        "settings.openResult",
        json!({"to": "/settings/appearance", "targetId": "theme"}),
    );
    let state = published(&engine, "route");
    assert_eq!(state["section"], json!("/settings/appearance"));
    assert_eq!(
        (&state["target"], &state["targetSeq"]),
        (&json!("theme"), &json!(1))
    );
    dispatch(&engine, "settings.navigate", json!({"to": "/elsewhere"}));
    assert_eq!(
        published(&engine, "route")["section"],
        json!("/settings/appearance")
    );
}

#[test]
fn only_the_apps_thread_links_open() {
    let (engine, _) = shell(EMPTY, disconnected());
    dispatch(&engine, "link.open", json!({"url": "hal-c2://thread/env/"}));
    assert_eq!(route(&engine), Route::Home);
    dispatch(
        &engine,
        "link.open",
        json!({"url": "hal-c2://thread/env/t/extra"}),
    );
    assert_eq!(route(&engine), Route::Home);
    dispatch(
        &engine,
        "link.open",
        json!({"url": "hal-c2://thread/env/t"}),
    );
    assert_eq!(route(&engine), Route::Thread("env:t".into()));
}

// theme

/// The mode is kept in this device's preferences: a file of their own.
fn with_preferences(engine: &Engine) -> tempfile::TempDir {
    let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).unwrap();
    Settings::of(engine).set_device_path(engine, Some(dir.path().join("preferences.json")));
    dir
}

#[test]
fn the_appearance_cycles_system_light_dark() {
    let (engine, _) = shell(EMPTY, disconnected());
    let _dir = with_preferences(&engine);
    let themes = controller::controller::<Themes>(&engine).unwrap();
    assert_eq!(themes.borrow().mode(), Mode::System);
    // Headless, the system says light.
    assert_eq!(published(&engine, "theme")["appearance"], json!("light"));
    let light_canvas = published(&engine, "theme")["colors"]["canvas"].clone();
    dispatch(&engine, "appearance.cycle", json!(null));
    assert_eq!(themes.borrow().mode(), Mode::Light);
    dispatch(&engine, "appearance.cycle", json!(null));
    assert_eq!(published(&engine, "theme")["appearance"], json!("dark"));
    assert_ne!(
        published(&engine, "theme")["colors"]["canvas"],
        light_canvas
    );
    dispatch(&engine, "appearance.cycle", json!(null));
    assert_eq!(themes.borrow().mode(), Mode::System);
    dispatch(&engine, "theme.mode", json!({"mode": "dark"}));
    assert_eq!(themes.borrow().mode(), Mode::Dark);
    dispatch(&engine, "theme.mode", json!({"mode": "purple"}));
    assert_eq!(themes.borrow().mode(), Mode::Dark);
}

#[test]
fn every_published_colour_is_hex() {
    let (engine, _) = shell(EMPTY, disconnected());
    let _dir = with_preferences(&engine);
    for mode in ["light", "dark"] {
        dispatch(&engine, "theme.mode", json!({"mode": mode}));
        let theme = published(&engine, "theme");
        let colors = theme["colors"].as_object().unwrap();
        assert!(colors.len() > 10, "{mode}: {colors:?}");
        for (role, value) in colors {
            let value = value.as_str().unwrap();
            assert!(
                value.starts_with('#') && matches!(value.len(), 7 | 9),
                "{mode} {role}: {value}"
            );
        }
    }
}

#[test]
fn css_colours_become_hex() {
    assert_eq!(canonical_color("#FFF").as_deref(), Some("#ffffff"));
    assert_eq!(canonical_color("#a1b2c3").as_deref(), Some("#a1b2c3"));
    assert_eq!(canonical_color("oklch(1 0 0)").as_deref(), Some("#ffffff"));
    assert_eq!(canonical_color("oklch(0 0 0)").as_deref(), Some("#000000"));
    assert_eq!(
        canonical_color("oklch(100% 0 0)").as_deref(),
        Some("#ffffff")
    );
    // QColor's names: SVG 1.1's, so not CSS 4's rebeccapurple.
    assert_eq!(canonical_color("Tomato").as_deref(), Some("#ff6347"));
    assert_eq!(canonical_color("alice blue").as_deref(), Some("#f0f8ff"));
    assert_eq!(canonical_color("rebeccapurple"), None);
}

const THEMED: &str = r##"
import QtQuick
import HalC2.Shell

Item {
    property var icon: null
    readonly property color known: Theme.palette.color("canvas", "#010203")
    readonly property color unknown: Theme.palette.color("noSuchRole", "#8b8b93")
    readonly property color tint: icon?.tint ?? Theme.palette.color("textMuted", "#8b8b93")
    property var tinted: ({"tint": "#ff0000"})
    readonly property color ownTint: tinted?.tint ?? Theme.palette.color("textMuted", "#8b8b93")
    readonly property string appearance: Theme.appearance
}
"##;

#[test]
fn the_theme_singleton_follows_the_published_theme() {
    let (engine, root) = shell(THEMED, disconnected());
    let _dir = with_preferences(&engine);
    let canvas = |engine: &Engine| {
        published(engine, "theme")["colors"]["canvas"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    assert_eq!(text(&engine, root, "known"), canvas(&engine));
    assert_eq!(text(&engine, root, "unknown"), "#8b8b93");
    assert_eq!(
        text(&engine, root, "tint"),
        published(&engine, "theme")["colors"]["textMuted"]
            .as_str()
            .unwrap()
    );
    assert_eq!(text(&engine, root, "ownTint"), "#ff0000");
    dispatch(&engine, "theme.mode", json!({"mode": "dark"}));
    assert_eq!(text(&engine, root, "appearance"), "dark");
    assert_eq!(text(&engine, root, "known"), canvas(&engine));
}

// clientActivity

#[test]
fn the_window_reports_itself_when_the_mc_is_ready_and_every_report_interval() {
    let mc = Rc::new(FakeMc::default());
    let engine = App::new("test")
        .register(hal_c2_shell::register)
        .build_engine();
    // A window for its clock, before the shell starts its timers on it.
    let mut window = ljos::testing::TestWindow::new(&engine, 100.0, 100.0);
    hal_c2_shell::start(&engine, &hal_c2_shell::Launch::default(), mc.clone());
    assert!(
        mc.methods().is_empty(),
        "nothing to tell an MC that is not there"
    );
    // What the window says of itself; the desktop's update status is
    // reported on ready too, by its own controller.
    let reports = |mc: &FakeMc| {
        mc.calls
            .borrow()
            .iter()
            .filter(|(_, method, _)| method == "server.reportClientActivity")
            .cloned()
            .collect::<Vec<_>>()
    };
    mc.set_ready(&engine, true);
    assert_eq!(reports(&mc).len(), 1);
    let (environment, _, payload) = reports(&mc)[0].clone();
    assert_eq!(environment, "env-1");
    assert_eq!(payload["clientKind"], json!("desktop-renderer"));
    assert_eq!(payload["environmentId"], json!("env-1"));
    window.advance(REPORT_MS as u64).unwrap();
    assert_eq!(reports(&mc).len(), 2);
    // Gone: nothing is renewed, and nothing wakes for it.
    mc.set_ready(&engine, false);
    window.advance(REPORT_MS as u64).unwrap();
    assert_eq!(reports(&mc).len(), 2);
}

// sandboxSettings: desktop-qt's tst_SandboxSettingsRegression cases (what
// its tst_SandboxSettingsProp found), against common's FakeMc, which holds
// every reply until the test answers it and sends frames only when told:
// which of a run's reply and its frame lands second settles it, a frame
// from before the run must not reopen the actions, a frame numbered below
// the last one means the MC's clock went back across a restart, and closing
// the page forgets what it asked. The fake MC has a gateway it runs and one
// of its reviews on it, so an uninstall's outcome asks before stopping it.

const LOST: &str = "The MC lost track of the run; check the status before trying again.";

fn sandbox_status() -> Json {
    json!({"supported": true, "ready": true, "mode": "managed",
           "version": "0.1.7", "pinnedVersion": "0.1.7", "problems": [],
           "actions": [{"operation": "check", "label": "Check"},
                       {"operation": "uninstall", "label": "Uninstall"}],
           "canManage": true, "manageReason": null})
}

fn sandbox_idle(run: i64) -> Json {
    json!({"operation": null, "run": run, "running": false, "steps": [], "result": null})
}

fn sandbox_running(operation: &str, run: i64) -> Json {
    json!({"operation": operation, "run": run, "running": true, "steps": [], "result": null})
}

fn sandbox_ended(operation: &str, run: i64, result: Json) -> Json {
    json!({"operation": operation, "run": run, "running": false, "steps": [], "result": result})
}

fn sandbox_stops() -> Json {
    json!({"ok": false, "code": "sandboxes-running",
           "message": "1 of this MC's review sandboxes is on the gateway.",
           "sandboxes": 1, "drain": ["review-1"]})
}

fn sandbox_ok() -> Json {
    json!({"ok": true, "code": null, "message": "Done.", "sandboxes": null})
}

fn sandbox_frame(engine: &Engine, mc: &FakeMc, operation: Json) {
    mc.frame(
        engine,
        "openShell",
        "env-1",
        json!({"t": "openShell", "operation": operation}),
    );
}

fn sandbox(engine: &Engine) -> Json {
    published(engine, "sandboxSettings")
}

fn sandbox_reads(mc: &FakeMc) -> usize {
    mc.calls
        .borrow()
        .iter()
        .filter(|(_, method, _)| method == "server.getOpenShellStatus")
        .count()
}

fn sandbox_runs(mc: &FakeMc) -> Vec<Json> {
    mc.calls
        .borrow()
        .iter()
        .filter(|(_, method, _)| method == "server.runOpenShellOperation")
        .map(|(_, _, payload)| payload.clone())
        .collect()
}

/// The page open, its first frame (nothing run) and its status landed.
fn sandbox_open(first: Json) -> (Engine, Rc<FakeMc>) {
    let mc = Rc::new(FakeMc::default());
    let (engine, _) = shell(EMPTY, mc.clone());
    dispatch(
        &engine,
        "settings.navigate",
        json!({"to": "/settings/sandboxes"}),
    );
    sandbox_frame(&engine, &mc, first);
    mc.answer(&engine, "server.getOpenShellStatus", Ok(sandbox_status()));
    assert_eq!(sandbox(&engine)["state"], json!("ready"));
    (engine, mc)
}

/// Presses Uninstall; the run's reply is the test's to land, or hold.
fn sandbox_press(engine: &Engine) {
    dispatch(
        engine,
        "sandboxSettings.run",
        json!({"operation": "uninstall"}),
    );
}

fn sandbox_reply(engine: &Engine, mc: &FakeMc, run: i64) {
    mc.answer(
        engine,
        "server.runOpenShellOperation",
        Ok(sandbox_running("uninstall", run)),
    );
}

/// Answers the status read a landing frame asked for, if it asked.
fn sandbox_reread(engine: &Engine, mc: &FakeMc) {
    if mc.pending("server.getOpenShellStatus").is_some() {
        mc.answer(engine, "server.getOpenShellStatus", Ok(sandbox_status()));
    }
}

// Leaving the page forgot the question about stopping reviews but did not
// say so: the section kept showing it until something else published.
#[test]
fn leaving_the_page_takes_its_question_away() {
    let (engine, mc) = sandbox_open(sandbox_idle(0));
    sandbox_press(&engine);
    sandbox_reply(&engine, &mc, 1);
    sandbox_frame(&engine, &mc, sandbox_running("uninstall", 1));
    sandbox_frame(&engine, &mc, sandbox_ended("uninstall", 1, sandbox_stops()));
    assert_ne!(sandbox(&engine)["confirm"], Json::Null);

    dispatch(
        &engine,
        "settings.navigate",
        json!({"to": "/settings/general"}),
    );
    assert_eq!(sandbox(&engine)["confirm"], Json::Null);
}

// A second press before the first run's frame sent a second run, the MC
// refused it as busy, and that refusal forgot the page had asked: the first
// run's outcome then asked nothing before stopping the review.
#[test]
fn a_second_press_before_the_first_frame_keeps_the_question() {
    let (engine, mc) = sandbox_open(sandbox_idle(0));
    sandbox_press(&engine);
    sandbox_press(&engine);
    sandbox_reply(&engine, &mc, 1);
    sandbox_frame(&engine, &mc, sandbox_running("uninstall", 1));
    assert_eq!(sandbox(&engine)["operation"]["running"], json!(true));

    sandbox_frame(&engine, &mc, sandbox_ended("uninstall", 1, sandbox_stops()));
    assert_ne!(sandbox(&engine)["confirm"], Json::Null);
    assert_eq!(sandbox_runs(&mc).len(), 1);
    assert_eq!(sandbox(&engine)["refusal"], Json::Null);
}

// A frame from before the run (another device's last uninstall, or the
// shape's first frame) cleared what kept the actions off: a second press
// then sent a second run, the MC refused it as busy, and the first run's
// outcome asked nothing before stopping the review. The stale frame's own
// outcome was also taken for this run's.
#[test]
fn a_frame_from_before_the_run_keeps_the_actions_off() {
    let (engine, mc) = sandbox_open(sandbox_idle(0));
    sandbox_press(&engine);
    sandbox_reply(&engine, &mc, 1);
    // From before the run: no number of its own, so below the run's.
    sandbox_frame(
        &engine,
        &mc,
        json!({"operation": "uninstall", "running": false, "steps": [],
               "result": sandbox_stops()}),
    );
    assert_ne!(sandbox(&engine)["operation"]["result"], Json::Null);
    assert_eq!(sandbox(&engine)["confirm"], Json::Null);
    assert_eq!(sandbox(&engine)["busy"], json!(true));
    sandbox_press(&engine);

    sandbox_frame(&engine, &mc, sandbox_running("uninstall", 1));
    assert_eq!(sandbox(&engine)["operation"]["running"], json!(true));
    sandbox_frame(&engine, &mc, sandbox_ended("uninstall", 1, sandbox_stops()));
    assert_ne!(sandbox(&engine)["confirm"], Json::Null);
    assert_eq!(sandbox_runs(&mc).len(), 1);
    assert_eq!(sandbox(&engine)["refusal"], Json::Null);
}

// The connection dropped after the run's reply and before its first frame,
// and the run ended before the page followed the shape again: the first
// frame after reconnecting, the run ended, was taken for one from before
// the run, so the page stayed busy and its outcome asked nothing.
#[test]
fn a_run_that_ended_while_the_connection_was_down_settles() {
    let (engine, mc) = sandbox_open(sandbox_idle(0));
    sandbox_press(&engine);
    sandbox_reply(&engine, &mc, 1);
    assert_eq!(sandbox_runs(&mc).len(), 1);
    // No running frame ever lands; the next frame is the run ended.
    sandbox_frame(&engine, &mc, sandbox_ended("uninstall", 1, sandbox_stops()));

    assert_ne!(sandbox(&engine)["confirm"], Json::Null);
    assert_eq!(sandbox(&engine)["busy"], json!(false));
    assert_eq!(sandbox(&engine)["operation"]["running"], json!(false));
    assert_eq!(sandbox_runs(&mc).len(), 1);
}

// A refusal of a press made before the page was left landed after it was
// opened again and pressed again: it took the new press for its own, and
// forgot the page had asked, so the new run's outcome asked nothing.
#[test]
fn a_refusal_from_before_the_page_closed_leaves_the_new_press_alone() {
    let (engine, mc) = sandbox_open(sandbox_idle(0));
    sandbox_press(&engine); // its reply is held
    assert_eq!(sandbox_runs(&mc).len(), 1);

    dispatch(
        &engine,
        "settings.navigate",
        json!({"to": "/settings/general"}),
    );
    dispatch(
        &engine,
        "settings.navigate",
        json!({"to": "/settings/sandboxes"}),
    );
    sandbox_frame(&engine, &mc, sandbox_idle(0));
    mc.answer(&engine, "server.getOpenShellStatus", Ok(sandbox_status()));
    sandbox_press(&engine);
    // The new press answered first, though it was asked second.
    let held = mc
        .pending("server.runOpenShellOperation")
        .expect("the held run");
    let second = (0..mc.calls.borrow().len())
        .rev()
        .find(|&i| mc.is_pending(i) && mc.calls.borrow()[i].1 == "server.runOpenShellOperation")
        .expect("the new run");
    assert_ne!(held, second);
    mc.reply(&engine, second, Ok(sandbox_running("uninstall", 2)));
    sandbox_frame(&engine, &mc, sandbox_running("uninstall", 2));
    assert_eq!(sandbox(&engine)["operation"]["running"], json!(true));
    assert_eq!(sandbox_runs(&mc).len(), 2);

    mc.answer(
        &engine,
        "server.runOpenShellOperation",
        Err(McError::new("OpenShell's status did not answer in time.")),
    );
    assert_eq!(sandbox(&engine)["refusal"], Json::Null);
    sandbox_frame(&engine, &mc, sandbox_ended("uninstall", 2, sandbox_stops()));
    assert_ne!(sandbox(&engine)["confirm"], Json::Null);
}

// The MC restarted during a run, before its first frame or after: the
// frames after it never carried the run's number, so the page stayed busy
// until another run started. With its clock gone back, the restarted MC
// numbers below the run.
#[test]
fn an_mc_that_restarted_during_the_run_settles_it() {
    for (seen, back) in [(false, false), (true, false), (true, true)] {
        let (engine, mc) = sandbox_open(sandbox_idle(0));
        sandbox_press(&engine);
        sandbox_reply(&engine, &mc, 1);
        assert_eq!(sandbox_runs(&mc).len(), 1, "seen {seen} back {back}");
        if seen {
            sandbox_frame(&engine, &mc, sandbox_running("uninstall", 1));
            assert_eq!(sandbox(&engine)["operation"]["running"], json!(true));
        } else {
            // A frame from before the run, with no operation, keeps the
            // page waiting.
            sandbox_frame(&engine, &mc, sandbox_idle(0));
            assert_eq!(sandbox(&engine)["busy"], json!(true));
            assert_eq!(sandbox(&engine)["refusal"], Json::Null);
        }
        // It restarts and loses what it ran: no operation, numbered when
        // it started — above the run, or below it with its clock back.
        sandbox_frame(&engine, &mc, sandbox_idle(if back { 0 } else { 1001 }));

        assert_eq!(
            sandbox(&engine)["refusal"],
            json!(LOST),
            "seen {seen} back {back}"
        );
        assert_eq!(sandbox(&engine)["busy"], json!(false));
        assert_eq!(sandbox(&engine)["operation"], Json::Null);
        assert_eq!(sandbox_reads(&mc), 2, "seen {seen} back {back}");
    }
}

// Another device installed while the connection was down, and the first
// frame after reconnecting showed its run ended: the outcome showed, but
// the status still offered what it had before, as only a run the page saw
// going read it again.
#[test]
fn a_run_another_device_ended_while_the_connection_was_down_reads_the_status() {
    // The read the page opens with covers the run its first frame shows.
    let (engine, mc) = sandbox_open(sandbox_ended("uninstall", 5, sandbox_ok()));
    assert_eq!(sandbox_reads(&mc), 1);

    sandbox_frame(&engine, &mc, sandbox_ended("install", 6, sandbox_ok()));
    assert_eq!(sandbox(&engine)["operation"]["operation"], json!("install"));
    assert_eq!(sandbox_reads(&mc), 2);
    sandbox_reread(&engine, &mc);

    // The same run again reads nothing more.
    sandbox_frame(&engine, &mc, sandbox_ended("install", 6, sandbox_ok()));
    assert_eq!(sandbox_reads(&mc), 2);
}

// The question about stopping reviews was open when another device's
// operation started: a yes then sent the run anyway, the MC refused it as
// busy, and the question was gone. The yes waits, and the question stays.
#[test]
fn confirming_while_another_runs_keeps_the_question() {
    let (engine, mc) = sandbox_open(sandbox_idle(0));
    sandbox_press(&engine);
    sandbox_reply(&engine, &mc, 1);
    sandbox_frame(&engine, &mc, sandbox_running("uninstall", 1));
    sandbox_frame(&engine, &mc, sandbox_ended("uninstall", 1, sandbox_stops()));
    assert_ne!(sandbox(&engine)["confirm"], Json::Null);
    sandbox_reread(&engine, &mc);

    sandbox_frame(&engine, &mc, sandbox_running("check", 2));
    assert_eq!(sandbox(&engine)["busy"], json!(true));
    dispatch(&engine, "sandboxSettings.confirm", json!(null));
    assert_eq!(sandbox_runs(&mc).len(), 1);
    assert_ne!(sandbox(&engine)["confirm"], Json::Null);
    assert_eq!(sandbox(&engine)["refusal"], Json::Null);

    sandbox_frame(&engine, &mc, sandbox_ended("check", 2, sandbox_ok()));
    assert_eq!(sandbox(&engine)["busy"], json!(false));
    sandbox_reread(&engine, &mc);
    dispatch(&engine, "sandboxSettings.confirm", json!(null));
    let runs = sandbox_runs(&mc);
    assert_eq!(runs.len(), 2);
    assert_eq!(
        runs[1],
        json!({"operation": "uninstall", "drain": ["review-1"]})
    );
}

// The MC restarted with its clock gone back while nothing ran and no run
// had been seen going: its idle frame's number below the last frame's told
// the restart, but the status the old MC read stood until a refresh.
#[test]
fn a_restart_with_the_clock_back_while_idle_reads_the_status() {
    let (engine, mc) = sandbox_open(sandbox_ended("install", 5, sandbox_ok()));
    assert_eq!(sandbox_reads(&mc), 1);

    sandbox_frame(&engine, &mc, sandbox_idle(0));
    assert_eq!(sandbox_reads(&mc), 2);
    assert_eq!(sandbox(&engine)["operation"], Json::Null);
}

// This page's run ended while the connection was down and another device's
// followed it: the first frame after reconnecting was the later run's
// (ended, or still going), and the page said nothing of its own, whose
// outcome it never saw.
#[test]
fn a_later_run_replacing_the_requested_one_says_its_outcome_is_unknown() {
    let (engine, mc) = sandbox_open(sandbox_idle(0));
    sandbox_press(&engine);
    sandbox_reply(&engine, &mc, 1);
    sandbox_frame(&engine, &mc, sandbox_ended("check", 2, sandbox_ok()));

    assert_eq!(sandbox(&engine)["refusal"], json!(LOST));
    assert_eq!(sandbox(&engine)["busy"], json!(false));
    assert_eq!(sandbox(&engine)["confirm"], Json::Null);
    // What it asked for is forgotten: its own run's frame, arriving after,
    // asks nothing.
    sandbox_frame(&engine, &mc, sandbox_ended("uninstall", 1, sandbox_stops()));
    assert_eq!(sandbox(&engine)["confirm"], Json::Null);

    let (engine, mc) = sandbox_open(sandbox_idle(0));
    sandbox_press(&engine);
    sandbox_reply(&engine, &mc, 1);
    sandbox_frame(&engine, &mc, sandbox_running("check", 2));
    assert_eq!(sandbox(&engine)["refusal"], json!(LOST));
    assert_eq!(sandbox(&engine)["busy"], json!(true)); // the later run's
    assert_eq!(sandbox(&engine)["confirm"], Json::Null);
}
