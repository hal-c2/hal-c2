//! An agent's click reaches a page only where a user's would: what the app
//! puts over the page, and takes the press, keeps it (desktop-qt's
//! BrowserAutomationPage::onPage).

mod common;

use std::rc::Rc;

use common::{Scene, call, shell};
use hal_c2_shell::mc::Disconnected;
use hal_c2_shell::page_input::on_page;
use ljos::item::kurbo::Point;
use ljos::prelude::{Engine, ObjectId, Value};

const MAIN: &str = r#"
import QtQuick
import QtQuick.Controls
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
