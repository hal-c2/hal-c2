//! `Shell` as the bricks use it: state published from Rust reaches their
//! bindings, actions they dispatch reach the controllers or come back as
//! `actionRequested`.

mod common;

use std::cell::RefCell;
use std::rc::Rc;

use common::{call, number, shell, text};
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::mc::Disconnected;
use ljos::prelude::Value;
use serde_json::json;

const MAIN: &str = r#"
import QtQuick
import HalC2.Shell

Item {
    id: root
    property int changes: 0
    property string lastKey: ""
    property string requested: ""
    property string commands: ""
    readonly property string collapsed: Shell.state.layout ? String(Shell.state.layout.sidebarCollapsed) : "none"
    readonly property string routeKind: Shell.state.route ? Shell.state.route.kind : ""
    readonly property string threadKey: Shell.state.route?.threadKey ?? ""
    readonly property string later: Shell.state.later === undefined ? "unset" : String(Shell.state.later.n)

    Connections {
        target: Shell
        function onStateEntryChanged(key, value) { root.changes += 1; root.lastKey = key }
        function onActionRequested(action, payload) { root.requested += action + " " + JSON.stringify(payload) + ";" }
        function onWindowCommandRequested(command) { root.commands += command + ";" }
    }

    function dispatch(action, payload) { Shell.dispatch(action, payload) }
    function publish(key, value) { Shell.publish(key, value) }
    function openExternal(url) { Shell.openExternal(url) }
    function windowCommand(command) { Shell.windowCommand(command) }
    function pasteAttaches(text, length) { return Shell.pasteAttaches(text, length) }
}
"#;

#[test]
fn a_republish_of_the_same_value_changes_nothing() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    let bridge = Bridge::of(&engine);
    let before = number(&engine, root, "changes");
    bridge.publish(&engine, "git", json!({"branch": "main"}));
    bridge.publish(&engine, "git", json!({"branch": "main"}));
    assert_eq!(number(&engine, root, "changes"), before + 1.0);
    assert_eq!(text(&engine, root, "lastKey"), "git");
    bridge.publish(&engine, "git", json!({"branch": "dev"}));
    assert_eq!(number(&engine, root, "changes"), before + 2.0);
    assert_eq!(
        bridge.published(&engine, "git"),
        Some(json!({"branch": "dev"}))
    );
}

#[test]
fn qml_publishes_as_rust_does() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    let payload = common::js_value(&engine, r#"({"a": [1, "two", null], "b": {"c": true}})"#);
    call(&engine, root, "publish", &[Value::string("git"), payload]);
    assert_eq!(
        Bridge::of(&engine).published(&engine, "git"),
        Some(json!({"a": [1, "two", null], "b": {"c": true}}))
    );
}

#[test]
fn a_key_declared_before_the_bindings_follows_its_publishes() {
    let source = common::compile(&[("Main", MAIN)], &[]);
    let engine = common::engine(source, Rc::new(Disconnected::default()));
    let bridge = Bridge::of(&engine);
    bridge.declare_key(&engine, "later");
    let root = engine.create_from_url("Main", None, Vec::new()).unwrap();
    assert_eq!(text(&engine, root, "later"), "unset");
    bridge.publish(&engine, "later", json!({"n": 7}));
    assert_eq!(text(&engine, root, "later"), "7");
}

#[test]
fn an_action_no_controller_handles_reaches_the_bricks() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    let seen = Rc::new(RefCell::new(Vec::new()));
    let log = seen.clone();
    Bridge::of(&engine).add_interceptor(
        &engine,
        Rc::new(move |_, action: &str, payload: &serde_json::Value| {
            log.borrow_mut().push((action.to_owned(), payload.clone()));
            false
        }),
    );
    let payload = common::js_value(&engine, r#"({"id": "x", "n": 2})"#);
    call(
        &engine,
        root,
        "dispatch",
        &[Value::string("composer.focus"), payload],
    );
    assert_eq!(
        *seen.borrow(),
        vec![("composer.focus".to_owned(), json!({"id": "x", "n": 2}))]
    );
    assert_eq!(
        text(&engine, root, "requested"),
        r#"composer.focus {"id":"x","n":2};"#
    );
}

#[test]
fn an_action_a_controller_handles_stays_in_rust() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    assert_eq!(text(&engine, root, "collapsed"), "false");
    call(
        &engine,
        root,
        "dispatch",
        &[Value::string("sidebar.toggle"), Value::Undefined],
    );
    assert_eq!(text(&engine, root, "collapsed"), "true");
    assert_eq!(text(&engine, root, "requested"), "");
}

#[test]
fn an_action_dispatched_while_a_controller_runs_waits_for_it() {
    let (engine, _root) = shell(MAIN, Rc::new(Disconnected::default()));
    let bridge = Bridge::of(&engine);
    let seen = Rc::new(RefCell::new(Vec::new()));
    let log = seen.clone();
    bridge.add_interceptor(
        &engine,
        Rc::new(move |_, action: &str, _: &serde_json::Value| {
            log.borrow_mut().push(action.to_owned());
            true
        }),
    );
    bridge.hold(&engine, || {
        bridge.dispatch(&engine, "one", json!(null));
        bridge.hold(&engine, || bridge.dispatch(&engine, "two", json!(null)));
        assert!(
            seen.borrow().is_empty(),
            "nothing runs inside the controller"
        );
    });
    assert_eq!(*seen.borrow(), ["one", "two"]);
}

#[test]
fn the_apps_own_links_open_in_the_app_and_web_links_outside() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    let opened = Rc::new(RefCell::new(Vec::new()));
    let log = opened.clone();
    Bridge::of(&engine).set_url_opener(&engine, move |url| log.borrow_mut().push(url.to_owned()));
    call(
        &engine,
        root,
        "openExternal",
        &[Value::string("hal-c2://thread/env-1/t-9")],
    );
    assert_eq!(text(&engine, root, "routeKind"), "thread");
    assert_eq!(text(&engine, root, "threadKey"), "env-1:t-9");
    call(
        &engine,
        root,
        "openExternal",
        &[Value::string("https://example.com/a")],
    );
    call(
        &engine,
        root,
        "openExternal",
        &[Value::string("mailto:a@example.com")],
    );
    call(
        &engine,
        root,
        "openExternal",
        &[Value::string("file:///etc/passwd")],
    );
    call(
        &engine,
        root,
        "openExternal",
        &[Value::string("javascript:alert(1)")],
    );
    assert_eq!(
        *opened.borrow(),
        ["https://example.com/a", "mailto:a@example.com"]
    );
}

#[test]
fn a_window_command_reaches_the_window() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    call(&engine, root, "windowCommand", &[Value::string("minimize")]);
    assert_eq!(text(&engine, root, "commands"), "minimize;");
}

#[test]
fn a_long_paste_becomes_a_file() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    let attaches = |text: String, length: i32| {
        call(
            &engine,
            root,
            "pasteAttaches",
            &[Value::string(text), Value::Int(length)],
        )
        .to_boolean()
    };
    assert!(!attaches(String::new(), 0));
    assert!(!attaches("short".into(), 0));
    assert!(attaches("x".repeat(32 * 1024), 0));
    assert!(attaches("x".repeat(10), 119_995));
    assert!(!attaches("x".repeat(10), 119_990));
}
