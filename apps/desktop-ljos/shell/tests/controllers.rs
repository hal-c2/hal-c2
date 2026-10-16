//! The controller framework and the controllers ported so far, driven as
//! the bricks drive them: through `Shell.dispatch` and `Shell.state`.

mod common;

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use common::{FakeMc, shell, text};
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller::{self, Controller, Init, Registration, Scope};
use hal_c2_shell::controllers::client_activity::REPORT_MS;
use hal_c2_shell::controllers::layout::{
    CONTENT_MIN_WIDTH, Layout, SIDEBAR_MIN_WIDTH, SIDEBAR_WIDTH,
};
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::theme::{Mode, Themes, canonical_color};
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::{Disconnected, Mc};
use ljos::App;
use ljos::prelude::Engine;
use ljos_runtime::{Clock as _, VirtualClock};
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
    let layout = published(&engine, "layout");
    assert_eq!(
        (&layout["sidebarOverlay"], &layout["sidebarCollapsed"]),
        (&json!(true), &json!(true))
    );
    dispatch(&engine, "sidebar.toggle", json!(null));
    assert_eq!(
        published(&engine, "layout")["sidebarCollapsed"],
        json!(false)
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

#[test]
fn the_appearance_cycles_system_light_dark() {
    let (engine, _) = shell(EMPTY, disconnected());
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
    let clock = Arc::new(VirtualClock::new());
    engine.set_clock(Rc::new(clock.clone()));
    hal_c2_shell::start(&engine, &hal_c2_shell::Launch::default(), mc.clone());
    assert!(
        mc.methods().is_empty(),
        "nothing to tell an MC that is not there"
    );
    mc.set_ready(&engine, true);
    assert_eq!(mc.methods(), ["server.reportClientActivity"]);
    let (environment, _, payload) = mc.calls.borrow()[0].clone();
    assert_eq!(environment, "env-1");
    assert_eq!(payload["clientKind"], json!("desktop-renderer"));
    assert_eq!(payload["environmentId"], json!("env-1"));
    clock.set(clock.now() + Duration::from_millis(REPORT_MS as u64));
    engine.advance_timers(clock.now());
    assert_eq!(mc.methods().len(), 2);
    // Gone: the timer keeps running and says nothing.
    mc.set_ready(&engine, false);
    clock.set(clock.now() + Duration::from_millis(REPORT_MS as u64));
    engine.advance_timers(clock.now());
    assert_eq!(mc.methods().len(), 2);
}
