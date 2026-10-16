//! The command registry: what a key, the palette or a menu runs.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::commands::{Choice, Commands, Row};
use hal_c2_shell::controllers::menus::Menus;
use ljos::prelude::Engine;

use crate::Hub;
use crate::common::js_value;

type Log = Rc<RefCell<Vec<String>>>;

fn logged(log: &Log, entry: &str) -> impl Fn(&Engine) + 'static {
    let (log, entry) = (log.clone(), entry.to_owned());
    move |_| log.borrow_mut().push(entry.clone())
}

#[test]
fn a_command_runs_by_its_id_and_an_unknown_one_says_so() {
    let hub = Hub::new();
    let commands = Commands::of(&hub.engine);
    let log = Log::default();
    commands.add(
        &hub.engine,
        "sidebar.toggle",
        "Toggle sidebar",
        logged(&log, "toggled"),
    );
    assert!(commands.contains(&hub.engine, "sidebar.toggle"));
    assert!(commands.run(&hub.engine, "sidebar.toggle"));
    assert!(!commands.run(&hub.engine, "nope"));
    assert_eq!(*log.borrow(), ["toggled"]);
}

#[test]
fn a_replaced_command_keeps_how_it_is_presented() {
    let hub = Hub::new();
    let commands = Commands::of(&hub.engine);
    let log = Log::default();
    commands.add(
        &hub.engine,
        "theme.select",
        "Change theme",
        logged(&log, "old"),
    );
    commands.set_description(&hub.engine, "theme.select", "Pick one");
    commands.set_enabled(&hub.engine, "theme.select", false);
    commands.set_listed(&hub.engine, "theme.select", false);
    commands.set_terms("theme.select", &["colour"]);
    commands.add(&hub.engine, "theme.select", "Theme", logged(&log, "new"));
    assert_eq!(
        commands.rows(),
        [Row {
            command: "theme.select".into(),
            title: "Theme".into(),
            description: "Pick one".into(),
            terms: vec!["colour".into()],
            ..Row::default()
        }]
    );
    // Disabled: registered, so true, but nothing runs.
    assert!(commands.run(&hub.engine, "theme.select"));
    assert!(log.borrow().is_empty());
    commands.set_enabled(&hub.engine, "theme.select", true);
    commands.run(&hub.engine, "theme.select");
    assert_eq!(*log.borrow(), ["new"]);
    commands.remove(&hub.engine, "theme.select");
    assert!(commands.rows().is_empty());
}

#[test]
fn a_command_run_from_a_controller_runs_once_the_controller_is_done() {
    let hub = Hub::new();
    let commands = Commands::of(&hub.engine);
    let log = Log::default();
    // The command reaches back into the controller that ran it.
    let reached = log.clone();
    commands.add(&hub.engine, "menu.close", "Close", move |engine| {
        let free = hal_c2_shell::controller::with::<Menus, _>(engine, |_, _| ()).is_some();
        reached.borrow_mut().push(format!("free: {free}"));
    });
    hub.with_controller::<Menus, _>(|_, engine| {
        assert!(Commands::of(engine).run(engine, "menu.close"));
        log.borrow_mut().push("ran".into());
    });
    assert_eq!(*log.borrow(), ["ran", "free: true"]);
}

#[test]
fn ran_failed_and_menu_hooks_follow_a_run() {
    let hub = Hub::new();
    let commands = Commands::of(&hub.engine);
    let log = Log::default();
    let (ran, failed, menu) = (log.clone(), log.clone(), log.clone());
    commands.on_ran(move |_, c| ran.borrow_mut().push(format!("ran {c}")));
    commands.on_failed(move |_, c, m| failed.borrow_mut().push(format!("failed {c} '{m}'")));
    commands.on_menu_requested(move |_, c| menu.borrow_mut().push(format!("menu {c}")));
    commands.add_menu(&hub.engine, "theme.select", "Change theme", |_| {
        vec![Choice::new("dark", "Dark", |_| {})]
    });
    let throws = js_value(&hub.engine, "(() => { throw new Error('no') })");
    commands.add_js(&hub.engine, "broken", "Broken", throws, None);
    assert!(commands.is_menu("theme.select"));
    assert_eq!(commands.choices(&hub.engine, "theme.select")[0].id, "dark");
    assert!(commands.choices(&hub.engine, "broken").is_empty());
    commands.run(&hub.engine, "theme.select");
    commands.run(&hub.engine, "broken");
    assert_eq!(
        *log.borrow(),
        [
            "menu theme.select",
            "ran theme.select",
            "ran broken",
            "failed broken ''"
        ]
    );
}

#[test]
fn a_qml_command_runs_its_callback_and_goes_with_its_owner() {
    let hub = Hub::new();
    let commands = Commands::of(&hub.engine);
    js_value(&hub.engine, "globalThis.runs = 0");
    let callback = js_value(&hub.engine, "(() => { globalThis.runs += 1 })");
    let owner = hub
        .engine
        .create_native(hal_c2_shell::commands::CommandRegistry::default(), None)
        .expect("an owner");
    commands.add_js(
        &hub.engine,
        "panel.toggle",
        "Toggle panel",
        callback,
        Some(owner),
    );
    // Not a function: nothing is added.
    commands.add_js(
        &hub.engine,
        "nope",
        "Nope",
        js_value(&hub.engine, "3"),
        None,
    );
    assert!(!commands.contains(&hub.engine, "nope"));
    assert!(commands.run(&hub.engine, "panel.toggle"));
    assert_eq!(js_value(&hub.engine, "runs").to_number(), 1.0);
    hub.engine.destroy_now(owner);
    assert!(!commands.contains(&hub.engine, "panel.toggle"));
    assert!(!commands.run(&hub.engine, "panel.toggle"));
}

#[test]
fn shortcuts_label_each_row_now_and_later() {
    let hub = Hub::new();
    let commands = Commands::of(&hub.engine);
    let changes = Rc::new(RefCell::new(0));
    let counted = changes.clone();
    commands.add(&hub.engine, "sidebar.toggle", "Toggle sidebar", |_| {});
    commands.add(&hub.engine, "settings.open", "Settings", |_| {});
    commands.on_changed(move |_| *counted.borrow_mut() += 1);
    commands.set_shortcuts(
        &hub.engine,
        Rc::new(|_, c: &str| {
            if c == "sidebar.toggle" {
                "Ctrl+B".into()
            } else {
                String::new()
            }
        }),
    );
    // Only the row whose label changed.
    assert_eq!(*changes.borrow(), 1);
    commands.add(&hub.engine, "sidebar.toggle", "Sidebar", |_| {});
    let shortcuts: Vec<_> = commands
        .rows()
        .into_iter()
        .map(|r| (r.command, r.shortcut))
        .collect();
    assert_eq!(
        shortcuts,
        [
            ("sidebar.toggle".into(), "Ctrl+B".into()),
            ("settings.open".into(), String::new())
        ]
    );
}

#[test]
fn qml_reads_the_registry_as_a_model_with_a_count() {
    let hub = Hub::new();
    let commands = Commands::of(&hub.engine);
    commands.add(&hub.engine, "a", "A", |_| {});
    commands.add(&hub.engine, "b", "B", |_| {});
    let obj = commands.object().expect("the registry's object");
    assert_eq!(hub.engine.read_by_name(obj, "count").to_number(), 2.0);
    commands.remove(&hub.engine, "a");
    assert_eq!(hub.engine.read_by_name(obj, "count").to_number(), 1.0);
}
