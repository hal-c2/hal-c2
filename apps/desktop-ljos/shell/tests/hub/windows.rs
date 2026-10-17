//! More than one window (features/navigation/windows.feature, "More than
//! one window"): each has its own window controllers and `Shell.state`, the
//! shared controllers serve all of them, closing one drops what was its
//! own, and closing the last quits. Headless: the opener shows nothing.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controller::{self, MAIN, NEW_WINDOW};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::json::Json;
use hal_c2_shell::mc::Mc;
use hal_c2_shell::window_mc::WindowMc;
use serde_json::json;

use crate::Hub;

/// A hub whose windows open as `window.new` asks, the ids the opener was
/// given logged.
fn opening(launch: Launch) -> (Hub, Rc<RefCell<Vec<String>>>) {
    let hub = Hub::with(launch);
    let shown = Rc::new(RefCell::new(Vec::new()));
    let log = shown.clone();
    controller::set_window_opener(&hub.engine, move |_, window| {
        log.borrow_mut().push(window.id.clone());
    });
    (hub, shown)
}

fn state_dir(test: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("hub-windows")
        .join(test);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn in_state_dir(dir: &std::path::Path) -> Launch {
    Launch {
        state_dir: Some(dir.to_owned()),
        ..Launch::default()
    }
}

fn open(hub: &Hub, id: &str) -> String {
    controller::open_window(&hub.engine, Some(id)).expect("the shell is started")
}

fn bridge(hub: &Hub, id: &str) -> Bridge {
    controller::window_bridge(&hub.engine, id).expect("the window is open")
}

fn published(hub: &Hub, id: &str, key: &str) -> Json {
    bridge(hub, id)
        .published(&hub.engine, key)
        .unwrap_or(Json::Null)
}

fn dispatch(hub: &Hub, id: &str, action: &str, payload: Json) {
    bridge(hub, id).dispatch(&hub.engine, action, payload);
}

fn saved(dir: &std::path::Path) -> Json {
    let text = std::fs::read_to_string(dir.join("shell-windows.json")).unwrap();
    serde_json::from_str(&text).unwrap()
}

#[test]
fn a_route_change_in_one_window_leaves_the_other_where_it_was() {
    let (hub, _) = opening(Launch::default());
    open(&hub, "two");
    assert_eq!(controller::windows(&hub.engine), vec![MAIN, "two"]);

    dispatch(
        &hub,
        "two",
        "settings.navigate",
        json!({"to": "/settings/archived"}),
    );

    assert_eq!(published(&hub, "two", "route")["kind"], "settings");
    assert_eq!(published(&hub, MAIN, "route")["kind"], "home");
    // The other way round, too.
    dispatch(
        &hub,
        MAIN,
        "settings.navigate",
        json!({"to": "/settings/general"}),
    );
    assert_eq!(
        published(&hub, MAIN, "route")["section"],
        "/settings/general"
    );
    assert_eq!(
        published(&hub, "two", "route")["section"],
        "/settings/archived"
    );
}

#[test]
fn an_action_reaches_the_controllers_of_the_window_it_came_from() {
    let (hub, _) = opening(Launch::default());
    open(&hub, "two");

    // A narrow window lays its sidebar over the content; a wide one not.
    dispatch(&hub, MAIN, "layout.window", json!({"width": 1400}));
    dispatch(&hub, "two", "layout.window", json!({"width": 500}));

    assert_eq!(published(&hub, MAIN, "layout")["sidebarOverlay"], false);
    assert_eq!(published(&hub, "two", "layout")["sidebarOverlay"], true);
}

#[test]
fn what_the_shared_controllers_publish_every_window_shows() {
    let (hub, _) = opening(Launch::default());
    open(&hub, "two");
    let first = published(&hub, MAIN, "connection");
    assert_ne!(first, Json::Null);
    assert_eq!(published(&hub, "two", "connection"), first);

    // Published later, on whichever bridge, it still reaches both.
    bridge(&hub, "two").publish(&hub.engine, "backendError", json!("down"));
    assert_eq!(published(&hub, MAIN, "backendError"), json!("down"));
    assert_eq!(published(&hub, "two", "backendError"), json!("down"));
}

#[test]
fn a_window_later_shows_what_was_shared_before_it_opened() {
    let (hub, _) = opening(Launch::default());
    Bridge::main(&hub.engine).publish(&hub.engine, "backendError", json!("down"));
    open(&hub, "two");
    assert_eq!(published(&hub, "two", "backendError"), json!("down"));
}

#[test]
fn new_window_opens_one_under_a_fresh_id_and_shows_it() {
    let (hub, shown) = opening(Launch::default());

    hub.dispatch(NEW_WINDOW, Json::Null);

    let ids = controller::windows(&hub.engine);
    assert_eq!(ids.len(), 2);
    assert_eq!(ids[1].len(), 12);
    assert!(controller::valid_window_id(&ids[1]));
    assert_eq!(*shown.borrow(), vec![ids[1].clone()]);
    // The new window is in front: what comes from no window goes to it.
    assert_eq!(Bridge::of(&hub.engine), bridge(&hub, &ids[1]));
}

#[test]
fn new_window_is_a_command_in_every_window() {
    let (hub, _) = opening(Launch::default());
    open(&hub, "two");
    for id in [MAIN, "two"] {
        let commands =
            controller::in_window(&hub.engine, id, || Commands::of(&hub.engine)).unwrap();
        assert!(commands.contains(&hub.engine, NEW_WINDOW), "in {id}");
    }
    let commands = controller::in_window(&hub.engine, "two", || Commands::of(&hub.engine)).unwrap();
    assert!(commands.run(&hub.engine, NEW_WINDOW));
    assert_eq!(controller::windows(&hub.engine).len(), 3);
}

#[test]
fn without_an_opener_the_shell_keeps_to_one_window() {
    let hub = Hub::new();
    assert!(!Commands::of(&hub.engine).contains(&hub.engine, NEW_WINDOW));
    hub.dispatch(NEW_WINDOW, Json::Null);
    assert_eq!(controller::windows(&hub.engine), vec![MAIN]);
}

#[test]
fn an_id_that_could_leave_its_directory_is_replaced() {
    let (hub, _) = opening(Launch::default());
    hub.dispatch(NEW_WINDOW, json!({"id": "../escape"}));
    let ids = controller::windows(&hub.engine);
    assert_eq!(ids.len(), 2);
    assert_ne!(ids[1], "../escape");
    assert_eq!(ids[1].len(), 12);
}

#[test]
fn opening_a_window_that_is_open_raises_it() {
    let (hub, shown) = opening(Launch::default());
    open(&hub, "two");
    let raised = Rc::new(RefCell::new(Vec::new()));
    let log = raised.clone();
    hub.engine
        .connect_by_name(
            bridge(&hub, "two").object(),
            "windowCommandRequested",
            move |engine, args| {
                log.borrow_mut()
                    .push(engine.to_js_string(&args[0]).to_string());
            },
        )
        .unwrap();

    hub.dispatch(NEW_WINDOW, json!({"id": "two"}));

    assert_eq!(controller::windows(&hub.engine), vec![MAIN, "two"]);
    assert_eq!(shown.borrow().len(), 1);
    assert_eq!(*raised.borrow(), ["raise"]);
}

#[test]
fn closing_a_window_drops_its_controllers_and_what_they_followed() {
    let (hub, _) = opening(Launch::default());
    let engine = &hub.engine;
    // What the first window's own timers start, before counting.
    hub.advance(5000);
    engine.process_deferred_deletes();
    let subscriptions: Vec<Json> = hub.mc.subscriptions().into_iter().map(|(_, s)| s).collect();
    let objects = engine.object_count();

    open(&hub, "two");
    let two = bridge(&hub, "two");
    // A window's own subscriptions and a timer of one of its controllers.
    let followed = hub.mc.subscriptions().len();
    assert!(followed >= subscriptions.len());
    let ticks = Rc::new(Cell::new(0));
    let t = ticks.clone();
    let timer = controller::in_window(engine, "two", || {
        controller::every(engine, None, 100, move |_| t.set(t.get() + 1))
    })
    .flatten()
    .expect("a timer");
    hub.advance(100);
    assert_eq!(ticks.get(), 1);

    controller::close_window(engine, "two");
    engine.process_deferred_deletes();

    assert_eq!(controller::windows(engine), vec![MAIN]);
    assert!(!two.is_open(engine));
    assert!(controller::window_bridge(engine, "two").is_none());
    assert!(!engine.is_alive(timer));
    hub.advance(1000);
    assert_eq!(ticks.get(), 1, "the timer went with the window");
    let left: Vec<Json> = hub.mc.subscriptions().into_iter().map(|(_, s)| s).collect();
    assert_eq!(left, subscriptions);
    assert_eq!(engine.object_count(), objects);
    // The window left still works.
    dispatch(
        &hub,
        MAIN,
        "settings.navigate",
        json!({"to": "/settings/general"}),
    );
    assert_eq!(hub.published("route")["kind"], "settings");
}

#[test]
fn a_shared_controllers_answer_outlives_the_window_that_asked() {
    let (hub, _) = opening(Launch::default());
    open(&hub, "two");
    let engine = &hub.engine;
    let answered = Rc::new(Cell::new(false));
    let a = answered.clone();
    let mc = controller::mc(engine).unwrap();
    // A shared controller's call made from window two answers as two, or
    // as it comes once two is gone.
    controller::in_window(engine, "two", || {
        mc.call(
            "local",
            "probe.call",
            Json::Null,
            Box::new(move |engine, _| {
                a.set(true);
                assert_eq!(Bridge::of(engine), Bridge::main(engine));
            }),
        );
    });
    controller::close_window(engine, "two");
    hub.mc.answer(engine, "probe.call", Ok(Json::Null));
    assert!(answered.get(), "a shared controller still hears its answer");
}

#[test]
fn closing_the_last_window_quits_and_keeps_it_to_reopen() {
    let dir = state_dir("last");
    let (hub, _) = opening(in_state_dir(&dir));
    open(&hub, "two");
    controller::close_window(&hub.engine, MAIN);
    assert!(!hub.engine.quit_requested());
    assert_eq!(saved(&dir), json!({"open": ["two"]}));

    controller::close_window(&hub.engine, "two");

    assert_eq!(hub.engine.quit_requested(), !cfg!(target_os = "macos"));
    assert_eq!(controller::windows(&hub.engine), vec!["two"]);
    assert_eq!(saved(&dir), json!({"open": ["two"]}));
}

#[test]
fn the_open_windows_are_saved_and_restored_with_their_own_files() {
    let dir = state_dir("restore");
    {
        let (hub, _) = opening(in_state_dir(&dir));
        open(&hub, "two");
        assert_eq!(saved(&dir), json!({"open": [MAIN, "two"]}));
        // A window keeps its files in its own directory.
        let file = controller::in_window(&hub.engine, "two", || {
            controller::state_file(&hub.engine, "shell-panel.json")
        })
        .flatten()
        .unwrap();
        assert_eq!(file, dir.join("shell-windows/two/shell-panel.json"));
        let main = controller::in_window(&hub.engine, MAIN, || {
            controller::state_file(&hub.engine, "shell-panel.json")
        })
        .flatten();
        assert_eq!(main, Some(dir.join("shell-panel.json")));
        std::fs::create_dir_all(dir.join("shell-windows/two")).unwrap();
        std::fs::write(&file, "{}").unwrap();
    }

    let (hub, shown) = opening(in_state_dir(&dir));
    controller::restore_windows(&hub.engine);
    assert_eq!(controller::windows(&hub.engine), vec![MAIN, "two"]);
    assert_eq!(*shown.borrow(), vec!["two".to_owned()]);

    // Closing one that is not the last forgets it and its files.
    controller::close_window(&hub.engine, "two");
    assert_eq!(saved(&dir), json!({"open": [MAIN]}));
    assert!(!dir.join("shell-windows/two").exists());
}

#[test]
fn the_first_window_is_the_first_saved_one() {
    let dir = state_dir("first");
    std::fs::write(
        dir.join("shell-windows.json"),
        r#"{"open": ["../bad", "front", "front", "back"]}"#,
    )
    .unwrap();
    let (hub, _) = opening(in_state_dir(&dir));
    assert_eq!(controller::windows(&hub.engine), vec!["front"]);
    controller::restore_windows(&hub.engine);
    assert_eq!(controller::windows(&hub.engine), vec!["front", "back"]);
}

#[test]
fn a_window_controllers_mc_answers_as_its_window_and_not_once_it_is_gone() {
    let (hub, _) = opening(Launch::default());
    open(&hub, "two");
    let engine = &hub.engine;
    let two = bridge(&hub, "two");
    let mc = WindowMc::for_window(hub.mc.clone(), two);
    let ran_as = Rc::new(RefCell::new(Vec::new()));
    let call = |method: &str| {
        let log = ran_as.clone();
        // Asked from the first window: the answer is still two's.
        controller::in_window(engine, MAIN, || {
            mc.call(
                "local",
                method,
                Json::Null,
                Box::new(move |engine, _| log.borrow_mut().push(Bridge::of(engine))),
            );
        });
    };
    call("probe.before");
    hub.mc.answer(engine, "probe.before", Ok(Json::Null));
    assert_eq!(*ran_as.borrow(), vec![two]);

    let before = hub.mc.subscriptions().len();
    mc.subscribe(json!({"kind": "probe"}), Box::new(|_, _| {}), None);
    assert_eq!(hub.mc.subscriptions().len(), before + 1);
    call("probe.after");
    controller::close_window(engine, "two");
    hub.mc.answer(engine, "probe.after", Ok(Json::Null));
    assert_eq!(ran_as.borrow().len(), 1, "nothing reaches a closed window");

    mc.close();
    assert_eq!(hub.mc.subscriptions().len(), before);
}

#[test]
fn a_setting_that_fails_to_save_says_so_in_the_window_that_changed_it() {
    let dir = state_dir("setting-not-saved");
    std::fs::write(dir.join("preferences.json"), "[1, 2").unwrap();
    let (hub, _) = opening(Launch {
        config_dir: Some(dir),
        ..Launch::default()
    });
    open(&hub, "two");
    let settings = Settings::of(&hub.engine);

    let saved = controller::in_window(&hub.engine, "two", || {
        settings.write_device(&hub.engine, "diffLayout", json!("split"))
    });

    assert_eq!(saved, Some(false));
    let titles = |id: &str| -> Vec<Json> {
        published(&hub, id, "toasts")["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["title"].clone())
            .collect()
    };
    assert_eq!(titles("two"), [json!("Setting not saved")]);
    assert_eq!(titles(MAIN), Vec::<Json>::new());
}
