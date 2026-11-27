//! `TerminalEvents`, mobile-qt's TerminalEvents (MobileTerminal.h):
//! sends a Terminal item the events its own encoders read, so a key
//! the screen draws goes out as the program in the shell asked keys
//! to (application cursor keys and the like), and a finger scrolls
//! and selects as a wheel and a mouse would. The C++ sent Qt events
//! through QCoreApplication::sendEvent; here they are Ljós's
//! ([`ljos::input::send_input`], hal-c2/ljos-ui#622), handed to the
//! item at once in its own coordinates.
//!
//! The phone's TerminalScreen is its caller: the key row's keys, a
//! drag turned into wheel pixels, and a long press into the mouse
//! events of a word selection (Shift held, so a program with the
//! mouse does not take it for its own).

use ljos::input::{self, Input, KeyEvent, Modifiers, MouseButtons, PointerEvent, WheelEvent};
use ljos::item::kurbo;
use ljos::prelude::{Cx, ObjectId, QmlObject, QtObject, Value, qml_impl};

#[derive(Debug, Default, QmlObject)]
#[qml(module = "HalC2.Shell", name = "TerminalEvents", extends = QtObject)]
pub struct TerminalEvents {
    #[qml(base)]
    base: QtObject,
}

fn object(value: &Value) -> Option<ObjectId> {
    match value {
        Value::Object(id) => Some(*id),
        _ => None,
    }
}

fn held_modifiers(qt: i32) -> Modifiers {
    Modifiers::from_bits_truncate(qt as u32)
}

fn number(engine: &ljos::prelude::Engine, item: ObjectId, name: &str) -> f64 {
    match engine.read_by_name(item, name) {
        Value::Int(n) => f64::from(n),
        Value::Real(n) => n,
        _ => 0.0,
    }
}

#[qml_impl]
impl TerminalEvents {
    /// A key press and release, as the row's drawn keys send.
    #[qml(invokable)]
    fn key(cx: &Cx, item: Value, key: i32, modifiers: i32) {
        let Some(item) = object(&item) else {
            return;
        };
        let engine = cx.engine;
        let held = held_modifiers(modifiers);
        input::send_input(
            engine,
            item,
            &Input::Key(KeyEvent::press(key).with_modifiers(held)),
        );
        input::send_input(
            engine,
            item,
            &Input::Key(KeyEvent::release(key).with_modifiers(held)),
        );
    }

    /// `pixels` as a wheel has them: positive scrolls towards older
    /// output, at the item's centre, its angle as Qt counts it
    /// (120 per 15 pixels).
    #[qml(invokable)]
    fn wheel(cx: &Cx, item: Value, pixels: f64) {
        let Some(item) = object(&item) else {
            return;
        };
        let engine = cx.engine;
        let centre = kurbo::Point::new(
            number(engine, item, "width") / 2.0,
            number(engine, item, "height") / 2.0,
        );
        let event = WheelEvent {
            pos: centre,
            angle_delta: kurbo::Vec2::new(0.0, pixels * 120.0 / 15.0),
            pixel_delta: kurbo::Vec2::new(0.0, pixels),
            phase: ljos::item::ScrollPhase::None,
            modifiers: Modifiers::empty(),
            time: engine.now(),
        };
        input::send_input(engine, item, &Input::Wheel(event));
    }

    /// The left button, in the item's coordinates: "press", "move"
    /// or "release" (anything else is a move, as the C++ read it).
    #[qml(invokable)]
    fn mouse(cx: &Cx, item: Value, what: String, x: f64, y: f64, modifiers: i32) {
        let Some(item) = object(&item) else {
            return;
        };
        let engine = cx.engine;
        let now = engine.now();
        let mut event = match what.as_str() {
            "press" => PointerEvent::press(x, y, now),
            "release" => PointerEvent::release(x, y, now),
            _ => PointerEvent::moved(x, y, MouseButtons::LEFT, now),
        };
        event.modifiers = held_modifiers(modifiers);
        input::send_input(engine, item, &Input::Pointer(event));
    }
}
