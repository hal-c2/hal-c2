//! Where a press in the window lands, for input the app gives one of its
//! items as the user's would come (desktop-qt's BrowserAutomationPage
//! pressTarget): the agent clicks a page only where a user's click would
//! reach it, never the app's menu, dialog or pane over it.

use ljos::item::{self, kurbo};
use ljos::prelude::{Engine, ObjectId, Value};

/// Types whose items stop a press as the window delivers it.
const TAKE_PRESSES: [&str; 5] = ["MouseArea", "Flickable", "Control", "TextInput", "TextEdit"];
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
