//! A brick of qml/HalC2/Bricks shown over the scenario's shell, as
//! desktop-qt's Brick (features/Brick.h): its singletons (Shell, Theme,
//! the controllers') are the world's, because it is made in the world's
//! engine and shown in the world's window. Steps drive it as the user
//! would, with the pointer and keys on that window, and read back what it
//! shows.
//!
//! A brick's document (`import QtQuick\nimport HalC2.Bricks\nHomePage {}`)
//! is compiled with the checkout's QML roots once per process and document,
//! inside a probe that knows how to find its items, popups included.

use std::cell::RefCell;
use std::collections::HashMap;

use ljos::MapSource;
use ljos::item::{KeyEvent, Modifiers, key};
use ljos::prelude::{ObjectId, Value};

use crate::harness::{Failure, Outcome};
use crate::world::World;
use crate::{expect, fail};

/// What wraps a brick's document: its root at `size`, and the functions
/// the steps reach its items through (an item's popup is the overlay's,
/// beside the brick, as in Qt).
const PROBE: &str = r#"
Item {
    id: brickProbe
    width: %W%
    height: %H%
    readonly property Item brickRoot: children.length > 0 ? children[0] : null
    function brickTrees() {
        var trees = [brickProbe]
        var overlay = brickProbe.Overlay.overlay
        if (overlay) trees.push(overlay)
        return trees
    }
    function brickFindIn(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            var found = brickFindIn(kids[i], name)
            if (found) return found
        }
        return null
    }
    function brickFind(name) {
        var trees = brickTrees()
        for (var i = 0; i < trees.length; i++) {
            var found = brickFindIn(trees[i], name)
            if (found) return found
        }
        return null
    }
    function brickShowsIn(item, text) {
        if (!item || !item.visible) return false
        if (item.text !== undefined && String(item.text) === text) return true
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            if (brickShowsIn(kids[i], text)) return true
        }
        return false
    }
    function brickShows(text) {
        var trees = brickTrees()
        for (var i = 0; i < trees.length; i++) {
            if (brickShowsIn(trees[i], text)) return true
        }
        return false
    }
    function brickAt(item, fx, fy) {
        return item.mapToItem(null, item.width * fx, item.height * fy)
    }
%BODY%
}
"#;

thread_local! {
    /// Each document's compiled roots and probe, packed, by its text and
    /// size: a `MapSource` is used up by the root it makes.
    static COMPILED: RefCell<HashMap<String, Vec<u8>>> = RefCell::new(HashMap::new());
}

/// The probe for `qml` at `width` by `height`: its imports first, then
/// the document's root inside the probe item.
fn probe_source(qml: &str, width: f64, height: f64) -> String {
    let (imports, body): (Vec<&str>, Vec<&str>) = qml
        .lines()
        .partition(|line| line.trim_start().starts_with("import "));
    let mut source = imports.join("\n");
    source.push_str("\nimport QtQuick\nimport QtQuick.Controls\n");
    source.push_str(
        &PROBE
            .replace("%W%", &width.to_string())
            .replace("%H%", &height.to_string())
            .replace("%BODY%", &body.join("\n")),
    );
    source
}

fn compile(qml: &str, width: f64, height: f64) -> Outcome<MapSource> {
    let key = format!("{width}x{height}\n{qml}");
    let unpack = |pack: &[u8]| {
        MapSource::from_pack(pack).map_err(|e| Failure(format!("the brick's pack: {e:?}")))
    };
    if let Some(pack) = COMPILED.with(|c| c.borrow().get(&key).cloned()) {
        return unpack(&pack);
    }
    let dir = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR"))
        .map_err(|e| Failure(format!("a directory for the brick: {e}")))?;
    std::fs::write(
        dir.path().join("BrickProbe.qml"),
        probe_source(qml, width, height),
    )
    .map_err(|e| Failure(format!("the brick's probe: {e}")))?;
    let mut dirs = hal_c2_shell::qml::Roots::checkout()
        .dirs()
        .map_err(Failure)?;
    dirs.push(dir.path().to_path_buf());
    let snapshot = ljos::engine();
    hal_c2_shell::register(&snapshot);
    let paths: Vec<&std::path::Path> = dirs.iter().map(|p| p.as_path()).collect();
    let compiled = ljos::dev::compile_quiet(&paths, Some(&snapshot)).map_err(Failure)?;
    let errors: Vec<String> = compiled
        .diagnostics
        .iter()
        .filter(|d| d.key == "BrickProbe" && matches!(d.severity, ljos::dev::Severity::Error))
        .map(|d| format!("{}:{}: {}", d.line, d.column, d.message))
        .collect();
    expect!(
        errors.is_empty(),
        "the brick does not compile: {}",
        errors.join("; ")
    );
    let pack = compiled
        .source
        .to_pack()
        .map_err(|e| Failure(format!("the brick's pack: {e:?}")))?;
    COMPILED.with(|c| c.borrow_mut().insert(key, pack.clone()));
    unpack(&pack)
}

/// A brick shown in the world's window. A brick that outlives a step lives
/// in the world's part `Shown`, which the next brick replaces.
#[derive(Clone, Copy)]
pub struct Brick {
    probe: ObjectId,
    /// The scenario's key presses ("the user presses Escape") go to this
    /// brick's window, to whatever has its keyboard focus.
    pub takes_keys: bool,
}

/// The brick the world shows, for steps that come back to it.
#[derive(Default)]
pub struct Shown(pub Option<Brick>);

impl Brick {
    /// `qml` is a document importing HalC2.Bricks, whose root is laid out
    /// at `width` by `height`.
    pub fn new(world: &mut World, qml: &str, width: f64, height: f64) -> Outcome<Brick> {
        let source = compile(qml, width, height)?;
        let probe = world.show_root(source, "BrickProbe")?;
        let brick = Brick {
            probe,
            takes_keys: false,
        };
        expect!(brick.root(world).is_some(), "the brick did not load: {qml}");
        Ok(brick)
    }

    /// Shows `qml` and keeps it as the world's brick.
    pub fn show(world: &mut World, qml: &str, width: f64, height: f64) -> Outcome {
        let brick = Brick::new(world, qml, width, height)?;
        world.part::<Shown>().0 = Some(brick);
        Ok(())
    }

    /// The document's root item.
    pub fn root(&self, world: &World) -> Option<ObjectId> {
        match world.engine().read_by_name(self.probe, "brickRoot") {
            Value::Object(root) => Some(root),
            _ => None,
        }
    }

    fn call(&self, world: &World, function: &str, args: &[Value]) -> Outcome<Value> {
        world
            .engine()
            .invoke_by_name(self.probe, function, args)
            .map_err(|e| Failure(format!("{function}: {e:?}")))
    }

    /// The item named `object_name`, popups included.
    pub fn find(&self, world: &World, object_name: &str) -> Outcome<Option<ObjectId>> {
        Ok(
            match self.call(world, "brickFind", &[Value::from(object_name)])? {
                Value::Object(item) => Some(item),
                _ => None,
            },
        )
    }

    /// The item named `object_name` (fails the step when there is none).
    pub fn item(&self, world: &World, object_name: &str) -> Outcome<ObjectId> {
        match self.find(world, object_name)? {
            Some(item) => Ok(item),
            None => fail!("the brick has no {object_name}"),
        }
    }

    /// `item`'s point at (fx, fy) of its size, in window coordinates.
    pub fn at(&self, world: &World, item: ObjectId, fx: f64, fy: f64) -> Outcome<(f64, f64)> {
        match self.call(
            world,
            "brickAt",
            &[Value::Object(item), Value::from(fx), Value::from(fy)],
        )? {
            Value::Point(p) => Ok((p.x, p.y)),
            other => fail!("no point for the item: {other:?}"),
        }
    }

    pub fn read(&self, world: &World, item: ObjectId, name: &str) -> Value {
        world.engine().read_by_name(item, name)
    }

    /// Sets `item`'s property `name`, as the user typing into it or a test's
    /// `setProperty` would.
    pub fn write(&self, world: &mut World, item: ObjectId, name: &str, value: Value) -> Outcome {
        world
            .engine()
            .write_by_name(item, name, value)
            .map_err(|e| Failure(format!("{name} cannot be set: {e:?}")))?;
        world.pump()
    }

    pub fn flag(&self, world: &World, item: ObjectId, name: &str) -> bool {
        matches!(self.read(world, item, name), Value::Bool(true))
    }

    pub fn text_of(&self, world: &World, item: ObjectId, name: &str) -> String {
        let engine = world.engine();
        engine
            .to_js_string(&engine.read_by_name(item, name))
            .to_string()
    }

    /// Clicks the item named `object_name` at its centre.
    pub fn click(&self, world: &mut World, object_name: &str) -> Outcome {
        let button = self.item(world, object_name)?;
        let visible = self.flag(world, button, "visible");
        let enabled = self.flag(world, button, "enabled");
        expect!(
            visible && enabled,
            "{object_name} cannot be clicked (visible {visible}, enabled {enabled})"
        );
        let (x, y) = self.at(world, button, 0.5, 0.5)?;
        world.click_at(x, y)
    }

    /// Whether a visible item shows `text` (a Text or Label's `text`).
    pub fn shows(&self, world: &World, text: &str) -> Outcome<bool> {
        Ok(matches!(
            self.call(world, "brickShows", &[Value::from(text)])?,
            Value::Bool(true)
        ))
    }

    /// Presses a key as keybindings.json spells it ("escape", "mod+enter",
    /// "shift+tab", "arrowup"): mod is the platform's primary modifier.
    /// False when nothing in the window took it.
    pub fn press(&self, world: &mut World, spelt: &str) -> Outcome<bool> {
        let event = key_event(spelt)?;
        world.key(&event)
    }
}

/// A key as keybindings.json spells it, as a window is given it.
pub fn key_event(spelt: &str) -> Outcome<KeyEvent> {
    let mut modifiers = Modifiers::empty();
    let mut code = 0;
    let mut letter: Option<String> = None;
    // A key the scenario quotes ("/") is the key itself.
    let quoted = spelt.chars().count() == 3 && spelt.starts_with('"') && spelt.ends_with('"');
    let tokens: Vec<String> = if quoted {
        vec![spelt[1..spelt.len() - 1].to_owned()]
    } else {
        spelt.to_lowercase().split('+').map(str::to_owned).collect()
    };
    for token in tokens {
        match token.as_str() {
            "mod" => modifiers |= primary(),
            "ctrl" => modifiers |= Modifiers::CONTROL,
            "alt" => modifiers |= Modifiers::ALT,
            "shift" => modifiers |= Modifiers::SHIFT,
            "meta" | "cmd" => modifiers |= Modifiers::META,
            "escape" | "esc" => code = key::ESCAPE,
            "enter" | "return" => code = key::RETURN,
            "space" => code = key::SPACE,
            "tab" => code = key::TAB,
            "backspace" => code = key::BACKSPACE,
            "delete" => code = key::DELETE,
            "up" | "arrowup" => code = key::UP,
            "down" | "arrowdown" => code = key::DOWN,
            "left" | "arrowleft" => code = key::LEFT,
            "right" | "arrowright" => code = key::RIGHT,
            "home" => code = key::HOME,
            "end" => code = key::END,
            "pageup" => code = key::PAGE_UP,
            "pagedown" => code = key::PAGE_DOWN,
            single if single.chars().count() == 1 => {
                let c = single.chars().next().unwrap_or(' ');
                code = c.to_ascii_uppercase() as i32;
                letter = Some(single.to_owned());
            }
            "f1" | "f2" | "f3" | "f4" | "f5" | "f6" | "f7" | "f8" | "f9" | "f10" | "f11"
            | "f12" => {
                let n: i32 = token[1..].parse().unwrap_or(1);
                code = key::F1 + n - 1;
            }
            _ => fail!("{spelt} is not a key"),
        }
    }
    // Shift+Tab arrives as Backtab.
    if code == key::TAB && modifiers.contains(Modifiers::SHIFT) {
        code = key::BACKTAB;
    }
    let mut event = KeyEvent::press(code).with_modifiers(modifiers);
    if modifiers.is_empty() || modifiers == Modifiers::SHIFT {
        let text = match code {
            c if c == key::RETURN => Some("\r".to_owned()),
            c if c == key::SPACE => Some(" ".to_owned()),
            c if c == key::TAB => Some("\t".to_owned()),
            _ => letter.map(|l| {
                if modifiers.contains(Modifiers::SHIFT) {
                    l.to_uppercase()
                } else {
                    l
                }
            }),
        };
        if let Some(text) = text {
            event = event.with_text(&text);
        }
    }
    Ok(event)
}

/// The platform's primary modifier: Ctrl, Command on macOS.
fn primary() -> Modifiers {
    if cfg!(target_os = "macos") {
        Modifiers::META
    } else {
        Modifiers::CONTROL
    }
}

/// The world's brick (fails the step when none is shown).
pub fn shown(world: &mut World) -> Outcome<Brick> {
    match world.part::<Shown>().0 {
        Some(brick) => Ok(brick),
        None => fail!("no brick is shown"),
    }
}
