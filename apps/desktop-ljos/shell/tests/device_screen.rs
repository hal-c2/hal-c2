//! `DeviceScreen` as DevicePanel uses it: a picture pushed in by the
//! stream, shown over the whole item, and gone when the stream changes.

mod common;

use std::rc::Rc;

use common::{Scene, call, read, shell};
use hal_c2_shell::device_screen::{drop_frame, show_frame};
use hal_c2_shell::mc::Disconnected;
use ljos::prelude::{Engine, ObjectId, Value};
use ljos_render::DrawOp;

const MAIN: &str = r#"
import QtQuick
import HalC2.Shell

Item {
    id: root
    width: 200
    height: 100
    property var source: null
    DeviceScreen {
        id: screen
        objectName: "deviceScreen"
        anchors.fill: parent
        stream: root.source
        visible: true
    }
    readonly property bool shown: screen.hasFrame
    function screenItem() { return screen }
    function setSource(v) { source = v }
}
"#;

fn screen(engine: &Engine, root: ObjectId) -> ObjectId {
    let Value::Object(s) = call(engine, root, "screenItem", &[]) else {
        panic!("the screen");
    };
    s
}

fn frame(w: u32, h: u32) -> Vec<u8> {
    [10, 20, 30, 255].repeat((w * h) as usize)
}

fn images(ops: &[DrawOp]) -> Vec<(u32, u32, (f64, f64))> {
    ops.iter()
        .filter_map(|op| match op {
            DrawOp::Image { image, dst, .. } => {
                Some((image.width(), image.height(), (dst.width(), dst.height())))
            }
            _ => None,
        })
        .collect()
}

#[test]
fn a_frame_is_stretched_over_the_item_and_dropping_it_clears_the_item() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    let s = screen(&engine, root);
    let mut scene = Scene::new(&engine, root, (200.0, 100.0));
    assert_eq!(read(&engine, root, "shown"), Value::Bool(false));
    assert!(images(&scene.ops(&engine, s)).is_empty());

    assert!(show_frame(&engine, s, 4, 8, frame(4, 8)));
    assert_eq!(read(&engine, root, "shown"), Value::Bool(true));
    assert_eq!(images(&scene.ops(&engine, s)), [(4, 8, (200.0, 100.0))]);

    // The next picture replaces it, whatever its size.
    assert!(show_frame(&engine, s, 8, 4, frame(8, 4)));
    assert_eq!(images(&scene.ops(&engine, s)), [(8, 4, (200.0, 100.0))]);

    drop_frame(&engine, s);
    assert_eq!(read(&engine, root, "shown"), Value::Bool(false));
    assert!(images(&scene.ops(&engine, s)).is_empty());
}

#[test]
fn pixels_that_do_not_fill_the_size_are_not_a_frame() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    let s = screen(&engine, root);
    assert!(!show_frame(&engine, s, 4, 4, vec![0; 10]));
    assert_eq!(read(&engine, root, "shown"), Value::Bool(false));
}

#[test]
fn a_new_stream_drops_the_picture_of_the_last() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    let s = screen(&engine, root);
    assert!(show_frame(&engine, s, 2, 2, frame(2, 2)));
    assert_eq!(read(&engine, root, "shown"), Value::Bool(true));
    let other = engine.create_by_name("QtQml", "QtObject", None).ok();
    call(
        &engine,
        root,
        "setSource",
        &[other.map_or(Value::Null, Value::Object)],
    );
    assert_eq!(read(&engine, root, "shown"), Value::Bool(false));
}
