//! An agent's click reaches a page only where a user's would: what the app
//! puts over the page, and takes the press, keeps it (desktop-qt's
//! BrowserAutomationPage::onPage). Its keys reach the page only while the
//! page has the keyboard, and the user's own hand takes the page back.

mod common;

use std::rc::Rc;
use std::time::Duration;

use common::{Scene, call, shell, text};
use hal_c2_shell::mc::Disconnected;
use hal_c2_shell::page_input::{guard_keys, has_keys, on_page, takes_over};
use ljos::input::{
    Input, InputOrigin, KeyEvent, MouseButtons, PointerEvent, WheelEvent, post_input,
};
use ljos::item::kurbo::Point;
use ljos::prelude::{Engine, ObjectId, Value};

const MAIN: &str = r#"
import QtQuick
import QtQuick.Controls
import Ghostty
Item {
    width: 400; height: 300
    property alias page: page
    property alias menu: menu
    property alias pane: pane
    Rectangle { id: page; x: 0; y: 0; width: 400; height: 300 }
    // A picture over the page's top left: it takes no press.
    Rectangle { x: 0; y: 0; width: 100; height: 100; color: "red" }
    // A pane over its top right: it does.
    Rectangle {
        id: pane
        x: 300; y: 0; width: 100; height: 100
        MouseArea { anchors.fill: parent }
    }
    // A button whose box reaches over the page's bottom, clipped away.
    Item {
        x: 0; y: 200; width: 100; height: 20
        clip: true
        Button { y: 40; width: 100; height: 40 }
    }
    // A native item that takes the pointer itself, over the bottom middle.
    Terminal { x: 150; y: 220; width: 100; height: 60 }
    // A handler over the bottom right.
    Item {
        x: 300; y: 200; width: 100; height: 100
        TapHandler {}
    }
    Menu { id: menu; x: 150; y: 150; width: 50; height: 50; MenuItem { text: "Copy" } }
}
"#;

fn page() -> (Engine, ObjectId, Scene) {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    let mut scene = Scene::new(&engine, root, (400.0, 300.0));
    scene.settle();
    (engine, root, scene)
}

fn object(engine: &Engine, root: ObjectId, name: &str) -> ObjectId {
    match engine.read_by_name(root, name) {
        Value::Object(obj) => obj,
        other => panic!("{name}: {other:?}"),
    }
}

#[test]
fn a_click_reaches_the_page_through_what_takes_no_press() {
    let (engine, root, _scene) = page();
    let page = object(&engine, root, "page");
    assert!(
        on_page(&engine, page, Point::new(200.0, 50.0)),
        "nothing over it"
    );
    assert!(
        on_page(&engine, page, Point::new(50.0, 50.0)),
        "a picture over it"
    );
    assert!(
        on_page(&engine, page, Point::new(50.0, 250.0)),
        "a button clipped away from the point"
    );
}

#[test]
fn what_takes_a_press_over_the_page_keeps_it() {
    let (engine, root, _scene) = page();
    let page = object(&engine, root, "page");
    assert!(
        !on_page(&engine, page, Point::new(350.0, 50.0)),
        "a mouse area"
    );
    assert!(
        !on_page(&engine, page, Point::new(350.0, 250.0)),
        "a tap handler"
    );
    assert!(
        !on_page(&engine, page, Point::new(200.0, 250.0)),
        "a native item registered for the pointer"
    );
    assert!(
        !on_page(&engine, page, Point::new(500.0, 50.0)),
        "outside the page"
    );
}

#[test]
fn a_hidden_or_disabled_cover_lets_the_click_through() {
    let (engine, root, mut scene) = page();
    let (page, pane) = (object(&engine, root, "page"), object(&engine, root, "pane"));
    engine
        .write_by_name(pane, "enabled", Value::Bool(false))
        .unwrap();
    scene.settle();
    assert!(on_page(&engine, page, Point::new(350.0, 50.0)), "disabled");
    engine
        .write_by_name(pane, "enabled", Value::Bool(true))
        .unwrap();
    engine
        .write_by_name(pane, "visible", Value::Bool(false))
        .unwrap();
    scene.settle();
    assert!(on_page(&engine, page, Point::new(350.0, 50.0)), "hidden");
}

#[test]
fn an_open_popup_keeps_the_click_where_it_lies() {
    let (engine, root, mut scene) = page();
    let (page, menu) = (object(&engine, root, "page"), object(&engine, root, "menu"));
    assert!(
        on_page(&engine, page, Point::new(170.0, 170.0)),
        "the menu is shut"
    );
    call(&engine, menu, "open", &[]);
    scene.settle();
    assert!(
        !on_page(&engine, page, Point::new(170.0, 170.0)),
        "under the menu"
    );
    assert!(
        on_page(&engine, page, Point::new(200.0, 50.0)),
        "away from it"
    );
}

const KEYS: &str = r#"
import QtQuick
Item {
    width: 200; height: 100
    property alias view: view
    property alias field: field
    TextInput { id: view; width: 100; height: 100 }
    // The app's own field beside it.
    TextInput { id: field; x: 100; width: 100; height: 100 }
}
"#;

const KEY_A: i32 = 0x41;

/// The view with the keyboard, and the app's field beside it.
fn keys() -> (Engine, ObjectId, ObjectId, Scene) {
    let (engine, root) = shell(KEYS, Rc::new(Disconnected::default()));
    let mut scene = Scene::new(&engine, root, (200.0, 100.0));
    let (view, field) = (
        object(&engine, root, "view"),
        object(&engine, root, "field"),
    );
    call(&engine, view, "forceActiveFocus", &[]);
    scene.settle();
    assert!(has_keys(&engine, view), "the view has the keyboard");
    (engine, view, field, scene)
}

/// Posts a press and release of A for `view`, as the agent's would come.
fn post_a(engine: &Engine, view: ObjectId) {
    for key in [KeyEvent::press(KEY_A), KeyEvent::release(KEY_A)] {
        post_input(engine, view, Input::Key(key.with_text("a"))).unwrap();
    }
}

fn user_types_a(scene: &mut Scene) {
    scene.window.key(&KeyEvent::press(KEY_A).with_text("a"));
    scene.window.key(&KeyEvent::release(KEY_A).with_text("a"));
}

#[test]
fn a_guarded_key_reaches_the_view_that_kept_the_keyboard() {
    let (engine, view, field, mut scene) = keys();
    guard_keys(&engine, view, KEY_A, Duration::from_secs(5));
    post_a(&engine, view);
    scene.settle();
    assert_eq!(text(&engine, view, "text"), "a");
    assert_eq!(text(&engine, field, "text"), "");
}

/// The page saw its view had the keyboard, but the app's field took it
/// before the posted keys came: they would have typed into the field.
#[test]
fn a_guarded_key_is_kept_from_what_took_the_keyboard_since() {
    let (engine, view, field, mut scene) = keys();
    guard_keys(&engine, view, KEY_A, Duration::from_secs(5));
    post_a(&engine, view);
    call(&engine, field, "forceActiveFocus", &[]);
    scene.settle();
    assert_eq!(text(&engine, field, "text"), "", "the agent's key");
    assert_eq!(text(&engine, view, "text"), "");
    // The guard went with the agent's release: the user's own keys type.
    user_types_a(&mut scene);
    assert_eq!(text(&engine, field, "text"), "a", "the user's key");
}

#[test]
fn a_guard_whose_keys_never_came_lets_the_users_through() {
    let (engine, view, field, mut scene) = keys();
    guard_keys(&engine, view, KEY_A, Duration::from_millis(100));
    scene.window.advance(200).unwrap();
    call(&engine, field, "forceActiveFocus", &[]);
    scene.settle();
    user_types_a(&mut scene);
    assert_eq!(text(&engine, field, "text"), "a");
}

#[test]
fn only_the_users_press_wheel_or_key_takes_a_page_over() {
    let (engine, _root) = shell(KEYS, Rc::new(Disconnected::default()));
    let t = engine.now();
    let press = Input::Pointer(PointerEvent::press(5.0, 5.0, t));
    let user = InputOrigin::User;
    assert!(takes_over(user, &press), "a press");
    assert!(
        takes_over(
            user,
            &Input::Wheel(WheelEvent::notches(5.0, 5.0, 0.0, 1.0, t))
        ),
        "the wheel"
    );
    assert!(
        takes_over(user, &Input::Key(KeyEvent::press(KEY_A))),
        "a key"
    );
    let hover = Input::Pointer(PointerEvent::moved(5.0, 5.0, MouseButtons::empty(), t));
    assert!(!takes_over(user, &hover), "hovering");
    assert!(
        !takes_over(user, &Input::Pointer(PointerEvent::release(5.0, 5.0, t))),
        "a release"
    );
    assert!(
        !takes_over(user, &Input::Key(KeyEvent::release(KEY_A))),
        "a key's release"
    );
    assert!(
        !takes_over(InputOrigin::Synthetic, &press),
        "the agent's own press"
    );
}
