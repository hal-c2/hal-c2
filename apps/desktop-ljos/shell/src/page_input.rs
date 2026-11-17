//! Where a press in the window lands, for input the app gives one of its
//! items as the user's would come (desktop-qt's BrowserAutomationPage
//! pressTarget): the agent clicks a page only where a user's click would
//! reach it, never the app's menu, dialog or pane over it. Its keys reach
//! the item only while it has the keyboard, and the user's own hand in the
//! item takes it back.

use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use ljos::input::{Input, InputOrigin, KeyEvent, KeyKind, PointerKind};
use ljos::item::{self, kurbo};
use ljos::keys::{self, KeyFilterId};
use ljos::prelude::{Engine, ObjectId, Value};

/// Types whose items stop a press as the window delivers it. Beside Qt
/// Quick's own, the native items that register for the pointer with
/// `item::register_pointer_item`: Ljós's controls (`Control`) and the
/// shell's `Terminal` (terminal/mod.rs). A native item the shell registers
/// for the pointer is named here too.
const TAKE_PRESSES: [&str; 6] = [
    "MouseArea",
    "Flickable",
    "Control",
    "TextInput",
    "TextEdit",
    "Terminal",
];
/// Handlers that make their item stop a press.
const PRESS_HANDLERS: [&str; 5] = [
    "TapHandler",
    "DragHandler",
    "PointHandler",
    "PinchHandler",
    "WheelHandler",
];

/// Whether a press at `at`, in `target`'s coordinates, would reach
/// `target`: it is inside it, no open popup lies over it, and nothing above
/// it in the window takes the press first.
pub fn on_page(engine: &Engine, target: ObjectId, at: kurbo::Point) -> bool {
    // The cheap check first: the walk below visits the whole window.
    let scene = item::map_to_scene(engine, target, at);
    if !item::scene_rect(engine, target).contains(scene) {
        return false;
    }
    // Open popups lie above the window's content, outside the walk from its
    // root; a modal one's shade covers all of it.
    let covered = item::overlay(engine, target).is_some_and(|overlay| {
        item::child_items(engine, overlay)
            .into_iter()
            .any(|popup| shown(engine, popup) && item::scene_rect(engine, popup).contains(scene))
    });
    if covered {
        return false;
    }
    press_target(engine, root(engine, target), scene, target) == Some(target)
}

/// Whether `item` has the keyboard.
pub fn has_keys(engine: &Engine, item: ObjectId) -> bool {
    engine.is_alive(item) && matches!(engine.read_by_name(item, "activeFocus"), Value::Bool(true))
}

/// Keeps the press and release of `key` the app is about to post for `item`
/// from whatever has the keyboard when they arrive, unless it is still
/// `item`. Posted input arrives with the next frame, by when the keyboard
/// may have gone elsewhere (the app's own field); it comes before the
/// window system's in that frame, so the first press and release of `key`
/// the window then gets are the posted ones. A key kept never reaches the
/// item. Gone after `within`, so keys that never arrive (the window closed
/// first) leave nothing behind; lifted at once when they are not posted.
/// Only keys given to `item`'s window are judged.
pub fn guard_keys(engine: &Engine, item: ObjectId, key: i32, within: Duration) -> KeyGuard {
    let guard = KeyGuard::default();
    let filter = {
        let guard = guard.clone();
        move |engine: &Engine, window: ObjectId, event: &KeyEvent| {
            // Another window's key is the user's there, whatever its key:
            // the posted ones come to the item's window.
            if event.key != key || !engine.is_alive(item) || root(engine, item) != window {
                return false;
            }
            match (event.kind, guard.kept.get()) {
                (KeyKind::Press, None) => {
                    let keep = !has_keys(engine, item);
                    guard.kept.set(Some(keep));
                    keep
                }
                // The release goes where its press went.
                (KeyKind::Release, Some(keep)) => {
                    guard.lift(engine);
                    keep
                }
                _ => false,
            }
        }
    };
    guard.filter.set(Some(keys::add_key_filter(engine, filter)));
    let late = guard.clone();
    engine.call_at(engine.now() + within, move |engine| late.lift(engine));
    guard
}

/// The guard [`guard_keys`] put up for keys about to be posted.
#[derive(Clone, Default)]
#[must_use = "lift the guard when the keys are not posted"]
pub struct KeyGuard {
    filter: Rc<Cell<Option<KeyFilterId>>>,
    /// Whether the press was kept from what had the keyboard, once it came.
    kept: Rc<Cell<Option<bool>>>,
}

impl KeyGuard {
    /// Takes the guard down now, for keys that were never posted: up, it
    /// would keep the user's own next press of the key elsewhere.
    pub fn lift(&self, engine: &Engine) {
        if let Some(id) = self.filter.take() {
            keys::remove_key_filter(engine, id);
        }
    }

    /// Whether the guarded press reached the item: None until it came (or
    /// when it never did), false when it was kept from what had the
    /// keyboard instead.
    pub fn reached(&self) -> Option<bool> {
        self.kept.get().map(|kept| !kept)
    }
}

/// Whether input an item got takes it over from the app driving it: the
/// user's own press, turn of the wheel or key (desktop-qt's eventFilter).
/// Hovering does not, and nor does input posted or driven.
pub fn takes_over(origin: InputOrigin, input: &Input) -> bool {
    origin == InputOrigin::User
        && match input {
            Input::Pointer(p) => p.kind == PointerKind::Press,
            Input::Wheel(_) => true,
            Input::Key(k) => k.kind == KeyKind::Press,
        }
}

/// The window's root item `item` lies in.
fn root(engine: &Engine, mut item: ObjectId) -> ObjectId {
    while let Some(parent) = engine.visual_parent(item) {
        item = parent;
    }
    item
}

/// The item a press at `scene` would land on under `item`, as the window
/// delivers it: the topmost visible, enabled item there that takes a press,
/// not one a clipping ancestor hides. `target` takes every press on it.
fn press_target(
    engine: &Engine,
    item: ObjectId,
    scene: kurbo::Point,
    target: ObjectId,
) -> Option<ObjectId> {
    if !shown(engine, item) || !flag(engine, item, "enabled") {
        return None;
    }
    let inside = item::scene_rect(engine, item).contains(scene);
    if item == target {
        return inside.then_some(item);
    }
    if !inside && matches!(engine.read_by_name(item, "clip"), Value::Bool(true)) {
        return None;
    }
    let mut children = item::child_items(engine, item);
    // Painted, and so hit, from the highest z down, the later sibling first.
    children.reverse();
    let z = |child: &ObjectId| number(engine.read_by_name(*child, "z"));
    children.sort_by(|a, b| z(b).total_cmp(&z(a)));
    children
        .into_iter()
        .find_map(|child| press_target(engine, child, scene, target))
        .or_else(|| (inside && takes_press(engine, item)).then_some(item))
}

/// Whether a press on `item` stops at it: a mouse area, a control, a
/// pointer handler. Other items let it through to what is under them.
fn takes_press(engine: &Engine, item: ObjectId) -> bool {
    let is = |obj: ObjectId, names: &[&str]| {
        engine
            .meta_of(obj)
            .is_some_and(|meta| names.iter().any(|name| meta.inherits_name(name)))
    };
    is(item, &TAKE_PRESSES)
        || item::resources(engine, item)
            .into_iter()
            .any(|handler| is(handler, &PRESS_HANDLERS))
}

/// Visible, as presses find items: one at opacity 0 still takes them.
fn shown(engine: &Engine, item: ObjectId) -> bool {
    flag(engine, item, "visible")
}

/// A flag an item has unless it says otherwise.
fn flag(engine: &Engine, item: ObjectId, name: &str) -> bool {
    !matches!(engine.read_by_name(item, name), Value::Bool(false))
}

fn number(value: Value) -> f64 {
    match value {
        Value::Int(n) => f64::from(n),
        Value::Real(n) => n,
        _ => 0.0,
    }
}
