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
        // data, not children: a closed Popup is no visual child, as
        // findChild finds it in Qt.
        var kids = item.data || item.children || []
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
    function brickFindVisibleIn(item, name) {
        if (!item || !item.visible) return null
        if (item.objectName === name) return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            var found = brickFindVisibleIn(kids[i], name)
            if (found) return found
        }
        return null
    }
    function brickFindVisible(name) {
        var trees = brickTrees()
        for (var i = 0; i < trees.length; i++) {
            var found = brickFindVisibleIn(trees[i], name)
            if (found) return found
        }
        return null
    }
    function brickFindAllVisibleIn(item, name, out) {
        if (!item || !item.visible) return
        if (item.objectName === name) out.push(item)
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) brickFindAllVisibleIn(kids[i], name, out)
    }
    function brickFindVisibleNth(name, n) {
        var out = []
        var trees = brickTrees()
        for (var i = 0; i < trees.length; i++) brickFindAllVisibleIn(trees[i], name, out)
        return n < out.length ? out[n] : null
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
    function brickHolds(item, text) {
        if (!item) return false
        if (item.text !== undefined && String(item.text) === text) return true
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            if (brickHolds(kids[i], text)) return true
        }
        return false
    }
    function brickFindHoldingIn(item, name, text) {
        if (!item) return null
        if (item.objectName === name && brickHolds(item, text)) return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            var found = brickFindHoldingIn(kids[i], name, text)
            if (found) return found
        }
        return null
    }
    function brickFindHolding(name, text) {
        var trees = brickTrees()
        for (var i = 0; i < trees.length; i++) {
            var found = brickFindHoldingIn(trees[i], name, text)
            if (found) return found
        }
        return null
    }
    function brickVisibleIn(item, name) {
        if (!item || !item.visible) return null
        if (item.objectName === name) return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            var found = brickVisibleIn(kids[i], name)
            if (found) return found
        }
        return null
    }
    function brickVisibleBeside(item, name) {
        return brickVisibleIn(item.parent, name)
    }
    function brickAt(item, fx, fy) {
        return item.mapToItem(null, item.width * fx, item.height * fy)
    }
    function brickAtPx(item, x, y) {
        return item.mapToItem(null, x, y)
    }
    function brickTopIndex(view) {
        return view.indexAt(view.contentX, view.contentY + 1)
    }
    function brickTreeNodeIn(item, path) {
        if (!item) return null
        if (item.objectName === "diffTreeNode" && item.modelData && item.modelData.path === path) return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            var found = brickTreeNodeIn(kids[i], path)
            if (found) return found
        }
        return null
    }
    function brickTreeNode(path) {
        return brickTreeNodeIn(brickProbe, path)
    }
    function brickLineCommentIn(item, file, line) {
        if (!item) return null
        if (item.objectName === "diffLineComment" && item.row && item.row.newLine === line
            && item.row.sign === "+" && item.row.file === file) return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
            var found = brickLineCommentIn(kids[i], file, line)
            if (found) return found
        }
        return null
    }
    function brickLineComment(file, line) {
        return brickLineCommentIn(brickProbe, file, line)
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
        let Some(root) = brick.root(world) else {
            fail!("the brick did not load: {qml}");
        };
        // desktop-qt's Brick sizes its root to the brick, as a Loader or an
        // anchored host sizes a page in the app.
        brick.write(world, root, "width", Value::from(width))?;
        brick.write(world, root, "height", Value::from(height))?;
        Ok(brick)
    }

    /// Where the window point (x, y) of the brick is once the brick has
    /// moved so the point lies inside the window. desktop-qt's window takes
    /// the brick's size, so a point far down a tall page is in it; a test
    /// window keeps its size (ljos-ui: TestWindow cannot change size), so
    /// the brick moves under it instead, as a page scrolls.
    pub fn reach(&self, world: &mut World, x: f64, y: f64) -> Outcome<(f64, f64)> {
        let (width, height) = crate::world::WINDOW;
        let shift = |at: f64, size: f64| {
            if (0.0..size).contains(&at) {
                0.0
            } else {
                size / 2.0 - at
            }
        };
        let (dx, dy) = (shift(x, width), shift(y, height));
        if dx == 0.0 && dy == 0.0 {
            return Ok((x, y));
        }
        for (name, by) in [("x", dx), ("y", dy)] {
            if by != 0.0 {
                let now = world.engine().read_by_name(self.probe, name).to_number();
                self.write(world, self.probe, name, Value::from(now + by))?;
            }
        }
        Ok((x + dx, y + dy))
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

    /// The first visible item named `object_name` (several delegates may share
    /// a name and only some show), popups included.
    pub fn find_visible(&self, world: &World, object_name: &str) -> Outcome<Option<ObjectId>> {
        Ok(
            match self.call(world, "brickFindVisible", &[Value::from(object_name)])? {
                Value::Object(item) => Some(item),
                _ => None,
            },
        )
    }

    /// The item named `object_name` at or under `root`, if any.
    pub fn find_under(
        &self,
        world: &World,
        root: ObjectId,
        object_name: &str,
    ) -> Outcome<Option<ObjectId>> {
        let found = self.call(
            world,
            "brickFindIn",
            &[Value::Object(root), Value::from(object_name)],
        )?;
        Ok(match found {
            Value::Object(item) => Some(item),
            _ => None,
        })
    }

    /// Whether `item`, or a visible item under it, shows `text`.
    pub fn shows_under(&self, world: &World, item: ObjectId, text: &str) -> Outcome<bool> {
        Ok(matches!(
            self.call(
                world,
                "brickShowsIn",
                &[Value::Object(item), Value::from(text)]
            )?,
            Value::Bool(true)
        ))
    }

    /// The item named `object_name` (fails the step when there is none).
    pub fn item(&self, world: &World, object_name: &str) -> Outcome<ObjectId> {
        match self.find(world, object_name)? {
            Some(item) => Ok(item),
            None => fail!("the brick has no {object_name}"),
        }
    }

    /// The item named `object_name` that has a Text or Label showing `text`
    /// somewhere inside it.
    pub fn find_holding(
        &self,
        world: &World,
        object_name: &str,
        text: &str,
    ) -> Outcome<Option<ObjectId>> {
        Ok(
            match self.call(
                world,
                "brickFindHolding",
                &[Value::from(object_name), Value::from(text)],
            )? {
                Value::Object(item) => Some(item),
                _ => None,
            },
        )
    }

    /// The visible item named `object_name` within `item`'s parent: the
    /// actions that show beside a row while the pointer is over it.
    pub fn visible_beside(
        &self,
        world: &World,
        item: ObjectId,
        object_name: &str,
    ) -> Outcome<Option<ObjectId>> {
        Ok(
            match self.call(
                world,
                "brickVisibleBeside",
                &[Value::Object(item), Value::from(object_name)],
            )? {
                Value::Object(found) => Some(found),
                _ => None,
            },
        )
    }

    /// The Diff panel's tree entry of `path`, if the tree draws it.
    pub fn tree_node(&self, world: &World, path: &str) -> Outcome<Option<ObjectId>> {
        Ok(
            match self.call(world, "brickTreeNode", &[Value::from(path)])? {
                Value::Object(item) => Some(item),
                _ => None,
            },
        )
    }

    /// The comment button of the added line `line` of file `file` (its
    /// index in the diff), if the list has drawn that line.
    pub fn line_comment(&self, world: &World, file: usize, line: i32) -> Outcome<Option<ObjectId>> {
        Ok(
            match self.call(
                world,
                "brickLineComment",
                &[Value::from(file as i32), Value::from(line)],
            )? {
                Value::Object(item) => Some(item),
                _ => None,
            },
        )
    }

    /// The index of the row at the top of the list `view`.
    pub fn top_index(&self, world: &World, view: ObjectId) -> Outcome<i32> {
        let value = self.call(world, "brickTopIndex", &[Value::Object(view)])?;
        let engine = world.engine();
        match engine.to_js_string(&value).to_string().parse::<f64>() {
            Ok(index) => Ok(index as i32),
            Err(_) => fail!("the list has no top row: {value:?}"),
        }
    }

    /// The point (x, y), in `item`'s own pixels, in window coordinates.
    pub fn at_px(&self, world: &World, item: ObjectId, x: f64, y: f64) -> Outcome<(f64, f64)> {
        match self.call(
            world,
            "brickAtPx",
            &[Value::Object(item), Value::from(x), Value::from(y)],
        )? {
            Value::Point(p) => Ok((p.x, p.y)),
            other => fail!("no point for the item: {other:?}"),
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

impl Brick {
    /// The item named `object_name` in `item`'s tree, `item` included.
    pub fn find_in(
        &self,
        world: &World,
        item: ObjectId,
        object_name: &str,
    ) -> Outcome<Option<ObjectId>> {
        Ok(
            match self.call(
                world,
                "brickFindIn",
                &[Value::Object(item), Value::from(object_name)],
            )? {
                Value::Object(found) => Some(found),
                _ => None,
            },
        )
    }
}

impl Brick {
    /// The `n`th visible item named `object_name`, in document order.
    pub fn find_visible_nth(
        &self,
        world: &World,
        object_name: &str,
        n: usize,
    ) -> Outcome<Option<ObjectId>> {
        Ok(
            match self.call(
                world,
                "brickFindVisibleNth",
                &[Value::from(object_name), Value::Int(n as i32)],
            )? {
                Value::Object(found) => Some(found),
                _ => None,
            },
        )
    }
}
