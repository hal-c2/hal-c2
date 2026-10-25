//! `layout`: the sidebar and the zoom, kept in this device's preferences
//! (LayoutController.cpp, features/navigation/layout.feature and
//! features/navigation/windows.feature).

use std::path::{Path, PathBuf};

use hal_c2_shell::Launch;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::layout::{CONTENT_MIN_WIDTH, SIDEBAR_MIN_WIDTH, SIDEBAR_WIDTH};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use serde_json::json;

use crate::Hub;

fn config_dir(test: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("hub-layout")
        .join(test);
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn with_config(dir: &Path) -> Hub {
    Hub::with(Launch {
        config_dir: Some(dir.to_path_buf()),
        ..Launch::default()
    })
}

fn layout(hub: &Hub) -> Json {
    hub.published("layout")
}

fn run(hub: &Hub, command: &str) {
    assert!(
        Commands::of(&hub.engine).run(&hub.engine, command),
        "{command}"
    );
}

fn zoom(level: f64) -> Json {
    json!(1.2_f64.powf(level))
}

fn saved(dir: &Path) -> Json {
    serde_json::from_slice(&std::fs::read(dir.join("preferences.json")).unwrap()).unwrap()
}

#[test]
fn the_commands_are_in_the_registry_with_their_titles() {
    let hub = Hub::new();
    let rows = Commands::of(&hub.engine).rows();
    let title = |command: &str| {
        rows.iter()
            .find(|r| r.command == command)
            .map(|r| r.title.clone())
    };
    assert_eq!(title("view.zoomIn").as_deref(), Some("Zoom in"));
    assert_eq!(title("view.zoomOut").as_deref(), Some("Zoom out"));
    assert_eq!(title("view.resetZoom").as_deref(), Some("Actual size"));
    assert_eq!(
        title("sidebar.toggle"),
        Some(hal_c2_shell::keybindings::command_label("sidebar.toggle"))
    );
}

#[test]
fn the_zoom_commands_step_by_half_and_reset() {
    let hub = with_config(&config_dir("steps"));
    assert_eq!(layout(&hub)["zoom"], zoom(0.0));
    run(&hub, "view.zoomIn");
    run(&hub, "view.zoomIn");
    assert_eq!(layout(&hub)["zoom"], zoom(1.0));
    run(&hub, "view.zoomOut");
    assert_eq!(layout(&hub)["zoom"], zoom(0.5));
    run(&hub, "view.resetZoom");
    assert_eq!(layout(&hub)["zoom"], zoom(0.0));
}

#[test]
fn the_zoom_stops_at_twenty_five_and_five_hundred_percent() {
    let hub = with_config(&config_dir("range"));
    for _ in 0..40 {
        run(&hub, "view.zoomIn");
    }
    assert_eq!(layout(&hub)["zoom"], zoom(8.5));
    run(&hub, "view.zoomOut");
    assert_eq!(layout(&hub)["zoom"], zoom(8.0));
    for _ in 0..40 {
        run(&hub, "view.zoomOut");
    }
    assert_eq!(layout(&hub)["zoom"], zoom(-7.5));
}

#[test]
fn the_sidebar_command_toggles_like_the_action() {
    let hub = Hub::new();
    run(&hub, "sidebar.toggle");
    assert_eq!(layout(&hub)["sidebarCollapsed"], true);
    hub.dispatch("sidebar.toggle", Json::Null);
    assert_eq!(layout(&hub)["sidebarCollapsed"], false);
}

#[test]
fn the_choices_are_kept_on_this_device_and_a_default_is_not_written() {
    let dir = config_dir("kept");
    let hub = with_config(&dir);
    run(&hub, "view.zoomIn");
    run(&hub, "sidebar.toggle");
    hub.dispatch("sidebar.resize", json!({"width": 300}));
    assert_eq!(
        saved(&dir),
        json!({"zoomLevel": 0.5, "sidebarCollapsed": true, "sidebarWidth": 300})
    );

    // The next launch starts from them.
    let again = with_config(&dir);
    let state = layout(&again);
    assert_eq!(state["zoom"], zoom(0.5));
    assert_eq!(state["sidebarCollapsed"], true);
    assert_eq!(state["sidebarWidth"], 300);

    // Back to the defaults: the keys go (a collapse is written either way).
    run(&hub, "view.resetZoom");
    hub.dispatch("sidebar.resize", Json::Null);
    assert_eq!(saved(&dir), json!({"sidebarCollapsed": true}));
    assert_eq!(layout(&hub)["sidebarWidth"], SIDEBAR_WIDTH);
}

#[test]
fn a_saved_width_is_at_least_the_minimum_and_none_means_the_default() {
    let dir = config_dir("width");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("preferences.json"), r#"{"sidebarWidth": 100}"#).unwrap();
    assert_eq!(
        layout(&with_config(&dir))["sidebarWidth"],
        SIDEBAR_MIN_WIDTH
    );
    std::fs::write(dir.join("preferences.json"), r#"{"sidebarWidth": 0}"#).unwrap();
    assert_eq!(layout(&with_config(&dir))["sidebarWidth"], SIDEBAR_WIDTH);
    std::fs::write(dir.join("preferences.json"), "{}").unwrap();
    assert_eq!(layout(&with_config(&dir))["sidebarWidth"], SIDEBAR_WIDTH);
}

#[test]
fn a_collapse_over_the_thread_is_not_remembered() {
    let dir = config_dir("overlay");
    let hub = with_config(&dir);
    hub.dispatch(
        "layout.window",
        json!({"width": SIDEBAR_MIN_WIDTH + CONTENT_MIN_WIDTH - 1}),
    );
    run(&hub, "sidebar.toggle");
    assert_eq!(layout(&hub)["sidebarCollapsed"], false);
    assert!(!dir.join("preferences.json").exists());
}

#[test]
fn another_windows_zoom_is_followed_but_not_its_sidebar() {
    let dir = config_dir("follow");
    let hub = with_config(&dir);
    let settings = Settings::of(&hub.engine);
    settings.write_device(&hub.engine, "zoomLevel", json!(2.0));
    assert_eq!(layout(&hub)["zoom"], zoom(2.0));
    settings.write_device(&hub.engine, "sidebarCollapsed", json!(true));
    settings.write_device(&hub.engine, "sidebarWidth", json!(300));
    let state = layout(&hub);
    assert_eq!(state["sidebarCollapsed"], false);
    assert_eq!(state["sidebarWidth"], SIDEBAR_WIDTH);
    // The zoom it follows is the one the next command steps from.
    run(&hub, "view.zoomIn");
    assert_eq!(layout(&hub)["zoom"], zoom(2.5));
    settings.write_device(&hub.engine, "zoomLevel", Json::Null);
    assert_eq!(layout(&hub)["zoom"], zoom(0.0));
}

/// The real ShellWindow, which tells the layout the room it has.
fn shell_window(hub: &Hub) -> ljos::prelude::ObjectId {
    let dir = tempfile::tempdir().expect("a directory for the probe");
    std::fs::write(
        dir.path().join("WindowProbe.qml"),
        "import HalC2.Bricks\nShellWindow {}\n",
    )
    .expect("the probe");
    let mut dirs = hal_c2_shell::qml::Roots::checkout()
        .dirs()
        .expect("the roots are there");
    dirs.push(dir.path().to_path_buf());
    let snapshot = ljos::engine();
    hal_c2_shell::register(&snapshot);
    let paths: Vec<&Path> = dirs.iter().map(PathBuf::as_path).collect();
    let compiled = ljos::dev::compile_quiet(&paths, Some(&snapshot)).expect("the bricks compile");
    hub.show(compiled.source, "WindowProbe").0
}

fn resize(hub: &Hub, window: ljos::prelude::ObjectId, width: i32) {
    hub.engine
        .write_by_name(
            window,
            "width",
            ljos::prelude::Value::from(f64::from(width)),
        )
        .expect("the window's width");
    hub.advance(0);
}

#[test]
fn the_sidebar_follows_the_window_as_it_is_resized_and_zoomed() {
    let hub = with_config(&config_dir("window"));
    let window = shell_window(&hub);
    hub.advance(0);
    let overlay = |hub: &Hub| layout(hub)["sidebarOverlay"] == json!(true);
    assert!(!overlay(&hub), "{}", layout(&hub));

    // Made as small as it goes, and back.
    resize(&hub, window, 640);
    assert!(overlay(&hub), "{}", layout(&hub));
    resize(&hub, window, 1280);
    assert!(!overlay(&hub), "{}", layout(&hub));

    // Room beside the thread until a zoom takes it.
    let narrow = SIDEBAR_MIN_WIDTH + CONTENT_MIN_WIDTH + 40;
    resize(&hub, window, narrow);
    assert!(!overlay(&hub), "{}", layout(&hub));
    run(&hub, "view.zoomIn");
    run(&hub, "view.zoomIn");
    hub.advance(0);
    assert!(overlay(&hub), "{}", layout(&hub));
    run(&hub, "view.resetZoom");
    hub.advance(0);
    assert!(!overlay(&hub), "{}", layout(&hub));
}
