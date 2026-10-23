//! `Keybindings`: the keymap the window's shortcuts follow, the rows
//! Settings → Keybindings edits, and keybindings.json
//! (features/navigation/keybindings.feature, keybinding-settings.feature,
//! keybinding-customisation.feature, desktop/native-keybindings.feature).

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use hal_c2_shell::Launch;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::commands::Commands;
use hal_c2_shell::controllers::keybindings::{Focus, KeybindingsObject, Keymap};
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::settings_scope::{Environment, SettingsScope};
use hal_c2_shell::controllers::terminals::Terminals;
use hal_c2_shell::controllers::toasts::Toasts;
use hal_c2_shell::json::{self, Json};
use hal_c2_shell::keybindings::{command_label, qt};
use hal_c2_shell::mc::McError;
use ljos::keys::{KeyEvent, Modifiers};
use ljos::prelude::ApplicationState;
use ljos::prelude::QmlValue;
use ljos::prelude::{Atom, Cx, Value};
use serde_json::json;

use crate::Hub;
use crate::common::call;
use crate::page::last;
use crate::workspace::{clustered, on_thread, project, shell, thread};

const UPSERT: &str = "hal-c2.upsertKeybinding";
const REMOVE: &str = "hal-c2.removeKeybinding";
const OPEN: &str = "shell.openInEditor";
const PATH: &str = "/home/me/.config/hal-c2/keybindings.json";

type Log = Rc<RefCell<Vec<String>>>;
/// The jump keys shown, and whether.
type Hints = (Vec<String>, bool);

const CHROME: Focus = Focus {
    terminal: false,
    composer: false,
    editable: false,
};
const TERMINAL: Focus = Focus {
    terminal: true,
    composer: false,
    editable: false,
};
const COMPOSER: Focus = Focus {
    terminal: false,
    composer: true,
    editable: true,
};

/// A shell whose chords read as Linux ones ("Ctrl+…").
fn hub() -> (Hub, Keymap) {
    linux(Hub::new())
}

/// One that keeps this device's preferences (the editor last used) in a
/// directory of its own, over an MC on this machine (editors start only
/// here).
fn hub_in(test: &str) -> (Hub, Keymap) {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("hub-keybindings")
        .join(test);
    let _ = std::fs::remove_dir_all(&dir);
    linux(Hub::here(Launch {
        config_dir: Some(dir),
        ..Launch::default()
    }))
}

fn linux(hub: Hub) -> (Hub, Keymap) {
    let keymap = Keymap::of(&hub.engine);
    keymap.set_mac(&hub.engine, false);
    (hub, keymap)
}

/// The MC's config snapshot.
fn config(hub: &Hub, config: Json) {
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config", "config": config}),
    );
}

/// The MC reloaded keybindings.json.
fn push(hub: &Hub, rules: Json) {
    hub.mc.frame(
        &hub.engine,
        "config",
        "env-1",
        json!({"t": "config.keybindings", "rules": rules}),
    );
}

/// Adds `command` to the registry, noting each run in `log`.
fn native(hub: &Hub, log: &Log, command: &str) {
    let entry = command.to_owned();
    let log = log.clone();
    Commands::of(&hub.engine).add(&hub.engine, command, command, move |_| {
        log.borrow_mut().push(entry.clone());
    });
}

/// Every action dispatched and every one sent to the bricks, as
/// "action payload".
fn actions(hub: &Hub) -> Log {
    let log = Log::default();
    let bridge = Bridge::of(&hub.engine);
    let seen = log.clone();
    bridge.add_interceptor(
        &hub.engine,
        Rc::new(move |_, action, payload| {
            seen.borrow_mut().push(format!("{action} {payload}"));
            true
        }),
    );
    let seen = log.clone();
    hub.engine
        .connect_by_name(bridge.object(), "actionRequested", move |engine, args| {
            let action = match &args[0] {
                Value::String(a) => a.to_string(),
                other => format!("{other:?}"),
            };
            let payload = json::from_value(engine, &args[1]);
            seen.borrow_mut().push(format!("bricks:{action} {payload}"));
        })
        .unwrap();
    log
}

fn toasts(hub: &Hub) -> Vec<(String, String, String)> {
    hub.published("toasts")["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| {
            (
                i["type"].as_str().unwrap_or_default().to_owned(),
                i["title"].as_str().unwrap_or_default().to_owned(),
                i["description"].as_str().unwrap_or_default().to_owned(),
            )
        })
        .collect()
}

fn shortcut(keymap: &Keymap, sequence: &str) -> Json {
    keymap
        .shortcuts()
        .into_iter()
        .find(|s| s["sequence"] == sequence)
        .unwrap_or_else(|| panic!("no shortcut {sequence}"))
}

fn row(keymap: &Keymap, command: &str, key: &str) -> Json {
    keymap
        .rows()
        .into_iter()
        .find(|r| r["command"] == command && r["key"] == key)
        .unwrap_or_else(|| panic!("no row {command} {key}"))
}

/// The payloads of every call to `method`, by environment.
fn calls(hub: &Hub, method: &str) -> Vec<(String, Json)> {
    hub.mc
        .calls
        .borrow()
        .iter()
        .filter(|(_, m, _)| m == method)
        .map(|(e, _, p)| (e.clone(), p.clone()))
        .collect()
}

fn open_thread(hub: &Hub, key: &str) {
    hub.with_controller::<Navigation, _>(|n, e| n.open(e, Route::Thread(key.into())));
}

fn route_thread(hub: &Hub) -> String {
    hub.published("route")["threadKey"]
        .as_str()
        .unwrap_or_default()
        .to_owned()
}

fn object(hub: &Hub) -> ljos::prelude::ObjectId {
    hub.engine.singleton::<KeybindingsObject>().unwrap()
}

#[test]
fn a_default_binding_runs_its_native_command() {
    let (hub, keymap) = hub();
    let log = Log::default();
    native(&hub, &log, "sidebar.toggle");
    assert_eq!(
        shortcut(&keymap, "Ctrl+B"),
        json!({"sequence": "Ctrl+B", "autoRepeat": true, "chrome": true,
               "composer": true, "editable": true, "terminal": true})
    );
    assert!(keymap.press(&hub.engine, "Ctrl+B", CHROME));
    assert_eq!(*log.borrow(), ["sidebar.toggle"]);
}

#[test]
fn a_key_the_shell_has_no_command_for_stays_with_the_focused_control() {
    let (hub, keymap) = hub();
    // preview.refresh is no one's command here.
    assert_eq!(shortcut(&keymap, "Ctrl+R")["chrome"], false);
    assert!(!keymap.press(&hub.engine, "Ctrl+R", CHROME));
    // A key nothing binds.
    assert!(!keymap.press(&hub.engine, "Ctrl+Shift+Q", CHROME));
}

#[test]
fn a_terminal_keeps_every_key_but_the_terminal_commands() {
    // A build that draws terminals has their commands.
    let (hub, keymap) = linux(on_thread("main", None));
    let split = shortcut(&keymap, "Ctrl+D");
    assert_eq!(split["terminal"], true);
    // Outside a terminal it is the right panel's diff.toggle.
    assert_eq!(split["chrome"], true);
    assert_eq!(shortcut(&keymap, "Ctrl+[")["terminal"], false);
    assert_eq!(shortcut(&keymap, "Ctrl+[")["chrome"], true);

    hub.dispatch("terminal.toggle", json!(null));
    assert!(keymap.press(&hub.engine, "Ctrl+D", TERMINAL));
    assert!(!keymap.press(&hub.engine, "Ctrl+[", TERMINAL));
    assert_eq!(
        hub.with_controller::<Terminals, _>(|t, _| t.terminal_ids()),
        ["term-1", "term-2"]
    );
}

#[test]
fn held_down_the_appearance_toggle_does_not_repeat() {
    let (_hub, keymap) = hub();
    assert_eq!(shortcut(&keymap, "Ctrl+Alt+Shift+A")["autoRepeat"], false);
    assert_eq!(shortcut(&keymap, "Ctrl+Alt+A")["autoRepeat"], true);
}

#[test]
fn the_open_palette_holds_every_key_but_its_own_and_the_windows() {
    let (hub, keymap) = hub();
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+[", CHROME),
        "navigation.back"
    );
    keymap.set_palette_open(&hub.engine, true);
    assert_eq!(keymap.resolve(&hub.engine, "Ctrl+[", CHROME), "");
    assert_eq!(keymap.resolve(&hub.engine, "Ctrl+Shift+]", CHROME), "");
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+K", CHROME),
        "commandPalette.toggle"
    );
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+B", CHROME),
        "sidebar.toggle"
    );
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+,", CHROME),
        "settings.open"
    );
    keymap.set_palette_open(&hub.engine, false);
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+[", CHROME),
        "navigation.back"
    );
}

#[test]
fn conditions_follow_the_composer_the_route_and_the_turn() {
    let (hub, keymap) = hub();
    // composer.sendAlternate: composerFocus && turnRunning.
    assert_eq!(keymap.resolve(&hub.engine, "Ctrl+Return", COMPOSER), "");
    Bridge::of(&hub.engine).publish(&hub.engine, "turn", json!({"running": true}));
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+Return", COMPOSER),
        "composer.sendAlternate"
    );
    assert_eq!(keymap.resolve(&hub.engine, "Ctrl+Return", CHROME), "");
    // composer.sendBackground: composerFocus && draftThreadRoute.
    assert_eq!(keymap.resolve(&hub.engine, "Ctrl+Alt+Return", COMPOSER), "");
    Bridge::of(&hub.engine).publish(&hub.engine, "route", json!({"kind": "draft"}));
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+Alt+Return", COMPOSER),
        "composer.sendBackground"
    );
    // A rule on composerDraft.
    push(
        &hub,
        json!([{"key": "mod+shift+y", "command": "thread.stop", "when": "composerDraft"}]),
    );
    assert_eq!(keymap.resolve(&hub.engine, "Ctrl+Shift+Y", CHROME), "");
    Bridge::of(&hub.engine).publish(&hub.engine, "composer", json!({"text": "  hi "}));
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+Shift+Y", CHROME),
        "thread.stop"
    );
}

#[test]
fn the_composer_keys_reach_the_composer_brick() {
    let (hub, keymap) = hub();
    let log = actions(&hub);
    Bridge::of(&hub.engine).publish(&hub.engine, "turn", json!({"running": true}));
    for sequence in [
        "Ctrl+Return",
        "Ctrl+S",
        "Ctrl+Shift+M",
        "Ctrl+Shift+E",
        "Alt+Up",
    ] {
        assert!(keymap.press(&hub.engine, sequence, COMPOSER), "{sequence}");
    }
    // The steer key's composer.queue.steer is the composer controller's.
    assert!(keymap.press(&hub.engine, "Ctrl+Shift+Return", CHROME));
    assert_eq!(
        *log.borrow(),
        [
            r#"bricks:composer.submit.key {"intent":"alternate"}"#,
            "bricks:composer.stash.key null",
            "bricks:composer.modelPicker.toggle null",
            r#"bricks:composer.control.open {"command":"composer.effort"}"#,
            "bricks:composer.queue.editLast null",
        ]
    );
}

#[test]
fn a_project_script_runs_from_its_key() {
    let (hub, keymap) = linux(clustered(Launch::default()));
    let scripts = json!({"scripts": [{"id": "test", "name": "Test", "command": "npm test",
        "icon": "test", "runOnWorktreeCreate": false}]});
    shell(&hub, vec![project(scripts), thread("t1", "main", None)]);
    hub.dispatch("thread.open", json!({"key": "env-1:t1"}));
    push(
        &hub,
        json!([{"key": "mod+shift+u", "command": "script.test.run"}]),
    );
    assert_eq!(shortcut(&keymap, "Ctrl+Shift+U")["chrome"], true);
    assert!(keymap.press(&hub.engine, "Ctrl+Shift+U", CHROME));
    // It runs in a terminal of its own, as its action does.
    assert_eq!(hub.published("workspace")["preferredScriptId"], "test");
    assert_eq!(last(&hub, "env-1", "terminal.open")["terminalId"], "term-1");
    let row = row(&keymap, "script.test.run", "mod+shift+u");
    assert_eq!(row["source"], "Project");
    assert_eq!(row["canRemove"], true);
}

#[test]
fn the_menu_accelerators_come_after_every_binding() {
    let (hub, keymap) = hub();
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+0", CHROME),
        "view.resetZoom"
    );
    assert_eq!(
        keymap.shortcut_label(&hub.engine, "settings.open"),
        "Ctrl+,"
    );
    assert_eq!(keymap.shortcut_label(&hub.engine, "view.zoomIn"), "Ctrl+=");
    // Not rows.
    assert!(
        keymap
            .rows()
            .iter()
            .all(|r| r["command"] != "settings.open")
    );
    push(&hub, json!([{"key": "mod+,", "command": "thread.next"}]));
    assert_eq!(keymap.resolve(&hub.engine, "Ctrl+,", CHROME), "thread.next");
    assert_eq!(keymap.shortcut_label(&hub.engine, "settings.open"), "");
}

#[test]
fn a_pushed_rule_applies_at_once_and_is_confirmed_once_in_two_seconds() {
    let (hub, keymap) = hub();
    assert_eq!(keymap.shortcut_label(&hub.engine, "thread.undo"), "Ctrl+Z");
    push(
        &hub,
        json!([{"key": "mod+shift+y", "command": "thread.undo"}]),
    );
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+Shift+Y", CHROME),
        "thread.undo"
    );
    assert_eq!(
        keymap.shortcut_label(&hub.engine, "thread.undo"),
        "Ctrl+Shift+Y"
    );
    assert_eq!(keymap.custom_count(), 1);
    let updated = (
        "success".to_owned(),
        "Keybindings updated".to_owned(),
        "Keybindings configuration reloaded successfully.".to_owned(),
    );
    assert_eq!(toasts(&hub), std::slice::from_ref(&updated));

    hub.advance(1999);
    push(&hub, json!([]));
    assert_eq!(keymap.custom_count(), 0);
    assert_eq!(toasts(&hub), std::slice::from_ref(&updated));

    hub.advance(2000);
    push(
        &hub,
        json!([{"key": "mod+shift+y", "command": "thread.next"}]),
    );
    assert_eq!(toasts(&hub), [updated.clone(), updated]);
}

#[test]
fn starting_with_custom_keybindings_is_not_announced() {
    let (hub, keymap) = hub();
    config(
        &hub,
        json!({"keybindingRules": [{"key": "mod+shift+y", "command": "thread.next"}],
               "keybindingsConfigPath": PATH}),
    );
    assert_eq!(keymap.custom_count(), 1);
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+Shift+Y", CHROME),
        "thread.next"
    );
    assert_eq!(keymap.file_path(), PATH);
    assert!(toasts(&hub).is_empty());
    assert_eq!(
        common_read(&hub, "customCount"),
        Value::Int(1),
        "the singleton shows it"
    );
    assert_eq!(
        common_read(&hub, "filePath"),
        Value::String(Atom::from(PATH))
    );
}

fn common_read(hub: &Hub, name: &str) -> Value {
    hub.engine.read_by_name(object(hub), name)
}

#[test]
fn the_rows_say_where_each_binding_comes_from() {
    let (hub, keymap) = hub();
    let undo = row(&keymap, "thread.undo", "mod+z");
    assert_eq!(undo["source"], "Default");
    assert_eq!(undo["keyLabel"], "Ctrl+Z");
    assert_eq!(undo["when"], "!terminalFocus && !editableFocus");
    assert_eq!(undo["canReset"], false);
    assert_eq!(undo["canRemove"], false);
    assert_eq!(undo["label"], command_label("thread.undo"));

    // A command with no default binding can still be bound.
    push(
        &hub,
        json!([{"key": "mod+shift+z", "command": "thread.undo"},
               {"key": "mod+shift+y", "command": "thread.stop"}]),
    );
    let custom = row(&keymap, "thread.undo", "mod+shift+z");
    assert_eq!(custom["source"], "Custom");
    assert_eq!(custom["defaultKey"], "mod+z");
    assert_eq!(custom["defaultWhen"], "!terminalFocus && !editableFocus");
    assert_eq!(custom["canReset"], true);
    assert_eq!(
        custom["rule"],
        json!({"key": "mod+shift+z", "command": "thread.undo"})
    );
    let unbound = row(&keymap, "thread.stop", "mod+shift+y");
    assert_eq!(unbound["defaultKey"], "");
    assert_eq!(unbound["canReset"], false);

    // Sorted by command, then key.
    let order: Vec<(String, String)> = keymap
        .rows()
        .iter()
        .map(|r| {
            (
                r["command"].as_str().unwrap().to_lowercase(),
                r["key"].as_str().unwrap().to_lowercase(),
            )
        })
        .collect();
    let mut sorted = order.clone();
    sorted.sort();
    assert_eq!(order, sorted);
    // The singleton lists the same rows.
    let shown = json::from_value(&hub.engine, &common_read(&hub, "bindings"));
    assert_eq!(shown, Json::Array(keymap.rows()));
}

#[test]
fn a_key_two_bindings_share_is_a_conflict_unless_their_conditions_differ() {
    let (hub, keymap) = hub();
    push(&hub, json!([{"key": "mod+b", "command": "thread.next"}]));
    let next = row(&keymap, "thread.next", "mod+b");
    assert_eq!(next["conflicts"], json!([command_label("sidebar.toggle")]));
    // mod+w: terminal.close (terminalFocus) and rightPanel.close
    // (!terminalFocus) — different conditions.
    assert_eq!(
        row(&keymap, "terminal.close", "mod+w")["conflicts"],
        json!([])
    );
    assert_eq!(keymap.conflicts("new", "mod+w", ""), {
        let mut labels = vec![
            command_label("rightPanel.close"),
            command_label("terminal.close"),
        ];
        labels.sort();
        labels
    });
    assert_eq!(
        keymap.conflicts("new", "mod+shift+q", ""),
        Vec::<String>::new()
    );
    assert_eq!(keymap.conflicts("new", "  ", ""), Vec::<String>::new());
}

#[test]
fn a_condition_is_checked_before_it_is_saved() {
    let (hub, _keymap) = hub();
    assert_eq!(Keymap::when_error(""), "");
    assert_eq!(Keymap::when_error("terminalFocus && !previewOpen"), "");
    assert_eq!(
        Keymap::when_error("terminalFocus &&"),
        "Use variables with !, &&, ||, and parentheses."
    );
    assert_eq!(
        Keymap::unknown_variables("zeta || terminalFocus && alpha || zeta"),
        ["alpha", "zeta"]
    );
    // The page reaches the same through the singleton.
    let obj = object(&hub);
    let unknown = call(
        &hub.engine,
        obj,
        "unknownVariables",
        &[Value::String(Atom::from("nope"))],
    );
    assert_eq!(json::from_value(&hub.engine, &unknown), json!(["nope"]));
    assert_eq!(
        call(
            &hub.engine,
            obj,
            "keyLabel",
            &[Value::String(Atom::from("mod+shift+y"))]
        ),
        Value::String(Atom::from("Ctrl+Shift+Y"))
    );
    assert_eq!(
        call(
            &hub.engine,
            obj,
            "recordKey",
            &[Value::Int(0x59), Value::Int(qt::CONTROL | qt::SHIFT)]
        ),
        Value::String(Atom::from("mod+shift+y"))
    );
}

#[test]
fn every_command_can_be_picked_by_its_label() {
    let (hub, keymap) = hub();
    push(
        &hub,
        json!([{"key": "mod+shift+u", "command": "script.lint.run"}]),
    );
    let options = keymap.command_options();
    assert!(options.contains(&"thread.undo".to_owned()));
    assert!(options.contains(&"script.lint.run".to_owned()));
    let labels: Vec<String> = options
        .iter()
        .map(|c| command_label(c).to_lowercase())
        .collect();
    let mut sorted = labels.clone();
    sorted.sort();
    assert_eq!(labels, sorted);
}

/// The MC up, with env-2 online and env-3 offline.
fn cluster(hub: &Hub) {
    hub.mc.set_ready(&hub.engine, true);
    SettingsScope::of(&hub.engine).set_sources(
        &hub.engine,
        Rc::new(|_| {
            ["env-1", "env-2", "env-3"]
                .iter()
                .map(|id| Environment {
                    id: (*id).into(),
                    label: String::new(),
                    online: *id != "env-3",
                })
                .collect()
        }),
        Rc::new(|_| Vec::new()),
    );
}

#[test]
fn a_save_reaches_every_online_environment_and_a_failure_is_told() {
    let (hub, keymap) = hub();
    cluster(&hub);
    keymap.save(&hub.engine, "thread.next", " mod+shift+y ", "", None);
    let input = json!({"command": "thread.next", "key": "mod+shift+y"});
    assert_eq!(
        calls(&hub, UPSERT),
        [
            ("env-1".to_owned(), input.clone()),
            ("env-2".to_owned(), input)
        ]
    );
    assert!(keymap.saving());
    assert_eq!(common_read(&hub, "saving"), Value::Bool(true));

    hub.mc.answer(&hub.engine, UPSERT, Ok(json!({})));
    assert!(keymap.saving());
    hub.mc.answer(
        &hub.engine,
        UPSERT,
        Err(McError {
            message: String::new(),
            detail: Json::Null,
        }),
    );
    assert!(!keymap.saving());
    assert_eq!(common_read(&hub, "saving"), Value::Bool(false));
    assert_eq!(
        toasts(&hub),
        [(
            "error".to_owned(),
            "Unable to save keybinding".to_owned(),
            "The keybinding was not saved.".to_owned()
        )]
    );
}

#[test]
fn an_edited_row_replaces_its_rule() {
    let (hub, keymap) = hub();
    push(
        &hub,
        json!([{"key": "mod+shift+y", "command": "thread.next", "when": "isDesktop"}]),
    );
    let edited = row(&keymap, "thread.next", "mod+shift+y");
    keymap.save(
        &hub.engine,
        "thread.next",
        "mod+shift+u",
        " terminalOpen ",
        Some(&edited),
    );
    assert_eq!(
        calls(&hub, UPSERT),
        [(
            "env-1".to_owned(),
            json!({"command": "thread.next", "key": "mod+shift+u", "when": "terminalOpen",
                   "replace": {"key": "mod+shift+y", "command": "thread.next", "when": "isDesktop"}})
        )]
    );
    // From the page: an empty `when` and a row.
    let obj = object(&hub);
    let row_value = edited.to_value();
    call(
        &hub.engine,
        obj,
        "save",
        &[
            Value::String(Atom::from("thread.next")),
            Value::String(Atom::from("mod+shift+i")),
            Value::Undefined,
            row_value,
        ],
    );
    assert_eq!(
        calls(&hub, UPSERT)[1].1,
        json!({"command": "thread.next", "key": "mod+shift+i",
               "replace": {"key": "mod+shift+y", "command": "thread.next", "when": "isDesktop"}})
    );
}

#[test]
fn removing_and_resetting_a_row() {
    let (hub, keymap) = hub();
    push(
        &hub,
        json!([{"key": "mod+shift+z", "command": "thread.undo"}]),
    );
    let custom = row(&keymap, "thread.undo", "mod+shift+z");
    keymap.reset(&hub.engine, &custom);
    assert_eq!(
        calls(&hub, UPSERT),
        [(
            "env-1".to_owned(),
            json!({"command": "thread.undo", "key": "mod+z",
                   "when": "!terminalFocus && !editableFocus",
                   "replace": {"key": "mod+shift+z", "command": "thread.undo"}})
        )]
    );
    keymap.remove(&hub.engine, &custom);
    assert_eq!(
        calls(&hub, REMOVE),
        [(
            "env-1".to_owned(),
            json!({"key": "mod+shift+z", "command": "thread.undo"})
        )]
    );
    hub.mc.answer(
        &hub.engine,
        REMOVE,
        Err(McError {
            message: "keybindings.json is read-only".into(),
            detail: Json::Null,
        }),
    );
    assert!(toasts(&hub).contains(&(
        "error".to_owned(),
        "Unable to remove keybinding".to_owned(),
        "keybindings.json is read-only".to_owned()
    )));
    // A row without its rule: as shown.
    keymap.remove(
        &hub.engine,
        &json!({"command": "thread.next", "key": "mod+shift+y", "when": ""}),
    );
    assert_eq!(
        calls(&hub, REMOVE)[1].1,
        json!({"command": "thread.next", "key": "mod+shift+y"})
    );
    // A row with no default does not reset.
    keymap.reset(
        &hub.engine,
        &json!({"command": "thread.stop", "defaultKey": ""}),
    );
    assert_eq!(calls(&hub, UPSERT).len(), 1);
}

#[test]
fn resetting_everything_asks_first() {
    let (hub, keymap) = hub();
    // Nothing to reset: nothing asked.
    keymap.reset_all(&hub.engine);
    assert_eq!(hub.published("confirmation"), Json::Null);

    push(
        &hub,
        json!([{"key": "mod+shift+z", "command": "thread.undo"},
               {"key": "mod+shift+y", "command": "thread.next"}]),
    );
    hub.dispatch("keybindings.resetAll", Json::Null);
    let question = hub.published("confirmation");
    assert_eq!(question["title"], "Reset every keybinding to its default?");
    assert_eq!(
        question["description"],
        "This removes your 2 custom keybindings."
    );
    assert_eq!(question["confirmLabel"], "Reset keybindings");
    assert_eq!(question["destructive"], true);
    assert!(calls(&hub, REMOVE).is_empty());

    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": true}),
    );
    assert_eq!(
        calls(&hub, REMOVE)
            .into_iter()
            .map(|(_, p)| p)
            .collect::<Vec<_>>(),
        [
            json!({"key": "mod+shift+z", "command": "thread.undo"}),
            json!({"key": "mod+shift+y", "command": "thread.next"})
        ]
    );
    hub.mc.answer(
        &hub.engine,
        REMOVE,
        Err(McError {
            message: String::new(),
            detail: Json::Null,
        }),
    );
    assert_eq!(toasts(&hub)[0].2, "A keybinding was not removed.");
}

#[test]
fn resetting_one_rule_says_so() {
    let (hub, keymap) = hub();
    push(
        &hub,
        json!([{"key": "mod+shift+z", "command": "thread.undo"}]),
    );
    keymap.reset_all(&hub.engine);
    let question = hub.published("confirmation");
    assert_eq!(
        question["description"],
        "This removes your 1 custom keybinding."
    );
    hub.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": false}),
    );
    assert!(calls(&hub, REMOVE).is_empty());
}

#[test]
fn the_file_opens_in_the_editor_last_used() {
    let (hub, keymap) = hub_in("editor-last-used");
    // Before the MC names the file: nothing.
    keymap.open_file(&hub.engine);
    assert!(calls(&hub, OPEN).is_empty());

    config(
        &hub,
        json!({"keybindingsConfigPath": PATH, "availableEditors": ["vscode", "zed"]}),
    );
    // None used yet: the first.
    hub.dispatch("keybindings.openFile", Json::Null);
    assert_eq!(
        calls(&hub, OPEN),
        [("env-1".to_owned(), json!({"cwd": PATH, "editor": "vscode"}))]
    );
    let settings = Settings::of(&hub.engine);
    assert_eq!(settings.device_value("lastEditor"), Some(json!("vscode")));
    hub.mc.answer(
        &hub.engine,
        OPEN,
        Err(McError {
            message: String::new(),
            detail: Json::Null,
        }),
    );
    assert_eq!(
        toasts(&hub),
        [(
            "error".to_owned(),
            "Unable to open keybindings file".to_owned(),
            "The keybindings file was not opened.".to_owned()
        )]
    );

    assert!(settings.write_device(&hub.engine, "lastEditor", json!("zed")));
    keymap.open_file(&hub.engine);
    assert_eq!(calls(&hub, OPEN)[1].1["editor"], "zed");
    // One this MC does not have: the first again.
    assert!(settings.write_device(&hub.engine, "lastEditor", json!("emacs")));
    keymap.open_file(&hub.engine);
    assert_eq!(calls(&hub, OPEN)[2].1["editor"], "vscode");
}

#[test]
fn without_an_editor_the_file_does_not_open() {
    let (hub, keymap) = hub();
    config(
        &hub,
        json!({"keybindingsConfigPath": PATH, "availableEditors": []}),
    );
    keymap.open_file(&hub.engine);
    assert!(calls(&hub, OPEN).is_empty());
    assert_eq!(
        toasts(&hub),
        [(
            "error".to_owned(),
            "Unable to open keybindings file".to_owned(),
            "No available editors found.".to_owned()
        )]
    );
}

#[test]
fn an_unreadable_file_is_told_once_with_a_way_to_open_it() {
    let (hub, keymap) = hub_in("unreadable-file");
    let issue =
        json!({"kind": "keybindings.malformed-config", "message": "Unexpected token at 3:4"});
    let snapshot = |editors: Json| {
        json!({"keybindingsConfigPath": PATH, "availableEditors": editors,
               "issues": [{"kind": "other", "message": "no"}, issue]})
    };
    config(&hub, snapshot(json!(["zed"])));
    let warning = (
        "warning".to_owned(),
        "Invalid keybindings configuration".to_owned(),
        "Unexpected token at 3:4".to_owned(),
    );
    assert_eq!(toasts(&hub), std::slice::from_ref(&warning));
    // The same problem in a later snapshot.
    config(&hub, snapshot(json!(["zed", "vscode"])));
    assert_eq!(toasts(&hub), std::slice::from_ref(&warning));
    // The defaults stay in force.
    assert_eq!(keymap.custom_count(), 0);
    assert_eq!(keymap.resolve(&hub.engine, "Ctrl+Z", CHROME), "thread.undo");

    let ran = hub.with_controller::<Toasts, _>(|t, e| t.run_action(e, "Open keybindings.json"));
    assert!(ran);
    assert_eq!(
        calls(&hub, OPEN),
        [("env-1".to_owned(), json!({"cwd": PATH, "editor": "zed"}))]
    );
    // The action took the warning away.
    assert!(toasts(&hub).is_empty());
    // Fixed, then broken again: told again.
    config(&hub, json!({"keybindingsConfigPath": PATH}));
    assert!(toasts(&hub).is_empty());
    config(&hub, snapshot(json!(["zed"])));
    assert_eq!(toasts(&hub), [warning]);
}

#[test]
fn threads_go_next_previous_and_by_number_in_sidebar_order() {
    let (hub, keymap) = hub();
    keymap.set_threads(Rc::new(|_| {
        Some(vec!["env-1:a".into(), "env-1:b".into(), "env-1:c".into()])
    }));
    // From no thread: the first, or the last.
    assert!(keymap.press(&hub.engine, "Ctrl+Shift+[", CHROME));
    assert_eq!(route_thread(&hub), "env-1:c");
    open_thread(&hub, "env-1:b");
    keymap.press(&hub.engine, "Ctrl+Shift+]", CHROME);
    assert_eq!(route_thread(&hub), "env-1:c");
    // Nothing past the end.
    keymap.press(&hub.engine, "Ctrl+Shift+]", CHROME);
    assert_eq!(route_thread(&hub), "env-1:c");
    keymap.press(&hub.engine, "Ctrl+1", CHROME);
    assert_eq!(route_thread(&hub), "env-1:a");
    keymap.press(&hub.engine, "Ctrl+Shift+[", CHROME);
    assert_eq!(route_thread(&hub), "env-1:a");
    // A number past the list does nothing.
    keymap.press(&hub.engine, "Ctrl+9", CHROME);
    assert_eq!(route_thread(&hub), "env-1:a");
    // A thread the sidebar does not list: nowhere to go from.
    open_thread(&hub, "env-1:z");
    keymap.press(&hub.engine, "Ctrl+Shift+]", CHROME);
    assert_eq!(route_thread(&hub), "env-1:z");
}

#[test]
fn an_inactive_sidebar_moves_nothing() {
    let (hub, keymap) = hub();
    keymap.press(&hub.engine, "Ctrl+Shift+]", CHROME);
    keymap.set_threads(Rc::new(|_| None));
    keymap.press(&hub.engine, "Ctrl+2", CHROME);
    assert_eq!(route_thread(&hub), "");
}

#[test]
fn the_jump_keys_show_once_the_modifier_is_held() {
    let (hub, keymap) = hub();
    let shown: Rc<RefCell<Vec<Hints>>> = Rc::default();
    let log = shown.clone();
    keymap.on_jump_hints(move |_, labels, show| log.borrow_mut().push((labels.to_vec(), show)));
    // The keys as a window is given them; the keymap keeps none.
    let window = hub.window();
    let key = |ev: KeyEvent| assert!(!window.key(&ev));
    let ctrl = || KeyEvent::press(qt::KEY_CONTROL).with_modifiers(Modifiers::CONTROL);

    // A quick shortcut shows none.
    key(ctrl());
    hub.advance(199);
    key(KeyEvent::release(qt::KEY_CONTROL));
    hub.advance(1000);
    assert_eq!(*shown.borrow(), [(vec![], false)]);
    shown.borrow_mut().clear();

    key(ctrl());
    // Auto-repeat does not restart the wait.
    hub.advance(150);
    key(ctrl().repeated());
    hub.advance(50);
    let labels: Vec<String> = (1..=9).map(|n| format!("Ctrl+{n}")).collect();
    assert_eq!(*shown.borrow(), [(labels.clone(), true)]);
    // Another key with it held keeps them; letting go hides them.
    key(KeyEvent::release(qt::KEY_SHIFT).with_modifiers(Modifiers::CONTROL));
    key(KeyEvent::release(qt::KEY_CONTROL));
    assert_eq!(shown.borrow().last().unwrap(), &(vec![], false));

    // Held as the application loses the keyboard: the release goes to
    // another application, and the keys hide.
    shown.borrow_mut().clear();
    key(ctrl());
    hub.advance(200);
    assert_eq!(*shown.borrow(), [(labels, true)]);
    ljos::testing::set_application_state(&hub.engine, ApplicationState::Inactive);
    assert_eq!(shown.borrow().last().unwrap(), &(vec![], false));
}

#[test]
fn undo_is_the_newest_toasts_and_its_toast_names_the_key() {
    let (hub, keymap) = hub();
    let undone = Log::default();
    let log = undone.clone();
    hub.with_controller::<Toasts, _>(|t, e| {
        t.show_undo(
            e,
            "Settled",
            "Settled",
            Rc::new(move |_| log.borrow_mut().push("undone".into())),
        )
    });
    assert_eq!(toasts(&hub)[0].2, "Ctrl+Z to undo");
    // Not while typing.
    assert!(!keymap.press(&hub.engine, "Ctrl+Z", COMPOSER));
    assert!(keymap.press(&hub.engine, "Ctrl+Z", CHROME));
    assert_eq!(*undone.borrow(), ["undone"]);
}

#[test]
fn the_model_picker_says_when_it_is_open() {
    let (hub, keymap) = hub();
    let log = actions(&hub);
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+1", CHROME),
        "thread.jump.1"
    );
    // What the brick does: `Keybindings.modelPickerOpen = true`.
    Cx::new(&hub.engine, object(&hub))
        .set(KeybindingsObject::MODEL_PICKER_OPEN, true)
        .unwrap();
    assert!(keymap.model_picker_open());
    assert_eq!(common_read(&hub, "modelPickerOpen"), Value::Bool(true));
    assert_eq!(
        keymap.resolve(&hub.engine, "Ctrl+1", CHROME),
        "modelPicker.jump.1"
    );
    // No one registers modelPicker.jump.N natively: the brick keeps the key.
    assert_eq!(shortcut(&keymap, "Ctrl+1")["chrome"], false);
    keymap.set_model_picker_open(&hub.engine, false);
    assert_eq!(shortcut(&keymap, "Ctrl+1")["chrome"], true);
    assert!(log.borrow().is_empty());
}

#[test]
fn the_window_presses_through_the_singleton() {
    let (hub, _keymap) = hub();
    let log = Log::default();
    native(&hub, &log, "sidebar.toggle");
    let obj = object(&hub);
    let focus = json!({"terminal": false, "composer": true, "editable": true}).to_value();
    assert_eq!(
        call(
            &hub.engine,
            obj,
            "press",
            &[Value::String(Atom::from("Ctrl+B")), focus]
        ),
        Value::Bool(true)
    );
    assert_eq!(*log.borrow(), ["sidebar.toggle"]);
    let shown = json::from_value(&hub.engine, &common_read(&hub, "shortcuts"));
    assert!(
        shown
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["sequence"] == "Ctrl+B" && s["chrome"] == true)
    );
    // The registry is the singleton's `commands`.
    assert_eq!(
        common_read(&hub, "commands"),
        Value::Object(Commands::of(&hub.engine).object().unwrap())
    );
}
