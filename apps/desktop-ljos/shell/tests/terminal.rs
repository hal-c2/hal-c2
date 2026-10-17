//! `Terminal` as the bricks use it: output goes in through `write` and
//! `restore`, what the user types comes out of `input`, and the grid
//! follows the item.

mod common;

use std::rc::Rc;

use common::{Scene, call, number, read, shell, text};
use hal_c2_shell::mc::Disconnected;
use ljos::item::WheelEvent;
use ljos::item::{DrawOp, MouseButtons, Paint, PointerEvent, Rgba, kurbo};
use ljos::keys::{KeyEvent, KeyKind, Modifiers, key};
use ljos::prelude::{ClipboardMode, Color, Engine, ObjectId, Platform, Value};

const MAIN: &str = r##"
import QtQuick
import Ghostty

Item {
    id: root
    width: 400
    height: 200
    property string typed: ""
    property string sizes: ""
    property int bells: 0
    Terminal {
        id: term
        anchors.fill: parent
        focus: true
        padding: 4
        scrollbackLimit: 50
        font.pixelSize: 16
        selectionColor: "#336699"
        ansiColors: [Qt.rgba(1, 0, 0, 1)]
        onInput: data => root.typed += data
        onResized: (columns, rows) => root.sizes += columns + "x" + rows + " "
        onBell: root.bells += 1
    }
    function terminal() { return term }
    function clearTyped() { typed = "" }
    function blur() { term.focus = false }
}
"##;

const PAD: f64 = 4.0;

struct Rig {
    engine: Engine,
    root: ObjectId,
    term: ObjectId,
    scene: Scene,
    cw: f64,
    ch: f64,
}

impl Rig {
    fn new() -> Rig {
        let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
        let Value::Object(term) = call(&engine, root, "terminal", &[]) else {
            panic!("the terminal");
        };
        let scene = Scene::new(&engine, root, (400.0, 200.0));
        let cw = number(&engine, term, "cellWidth");
        let ch = number(&engine, term, "cellHeight");
        Rig {
            engine,
            root,
            term,
            scene,
            cw,
            ch,
        }
    }

    fn write(&mut self, s: &str) {
        call(&self.engine, self.term, "write", &[Value::from(s)]);
    }

    fn typed(&self) -> String {
        text(&self.engine, self.root, "typed")
    }

    fn clear_typed(&self) {
        call(&self.engine, self.root, "clearTyped", &[]);
    }

    fn num(&self, name: &str) -> f64 {
        number(&self.engine, self.term, name)
    }

    fn flag(&self, name: &str) -> bool {
        read(&self.engine, self.term, name) == Value::Bool(true)
    }

    fn string(&self, name: &str) -> String {
        text(&self.engine, self.term, name)
    }

    fn method(&self, name: &str) -> String {
        text_of(&call(&self.engine, self.term, name, &[]), &self.engine)
    }

    /// The middle of a cell, in the scene.
    fn centre(&self, row: u16, col: u16) -> (f64, f64) {
        (
            PAD + (f64::from(col) + 0.5) * self.cw,
            PAD + (f64::from(row) + 0.5) * self.ch,
        )
    }

    fn type_key(&mut self, ev: KeyEvent) -> bool {
        let mut up = ev.clone();
        up.kind = KeyKind::Release;
        let taken = self.scene.window.key(&ev);
        self.scene.window.key(&up);
        taken
    }

    fn drag(&mut self, from: (u16, u16), to: (u16, u16)) {
        let (x0, y0) = self.centre(from.0, from.1);
        let (x1, y1) = self.centre(to.0, to.1);
        let w = &mut self.scene.window;
        let now = w.now();
        w.pointer(&PointerEvent::press(x0, y0, now));
        w.pointer(&PointerEvent::moved(x1, y1, MouseButtons::LEFT, now));
        w.pointer(&PointerEvent::release(x1, y1, now));
    }

    fn wheel(&mut self, notches: f64) -> bool {
        let (x, y) = self.centre(1, 1);
        let now = self.scene.window.now();
        self.scene
            .window
            .wheel(&WheelEvent::notches(x, y, 0.0, notches, now))
    }

    fn ops(&mut self) -> Vec<DrawOp> {
        self.scene.ops(self.term)
    }
}

fn text_of(v: &Value, engine: &Engine) -> String {
    engine.to_js_string(v).to_string()
}

fn near(a: Rgba, b: Rgba) -> bool {
    [a.r - b.r, a.g - b.g, a.b - b.b, a.a - b.a]
        .iter()
        .all(|d| d.abs() < 0.01)
}

fn rgb(hex: u32) -> Rgba {
    Rgba::rgb((hex >> 16) as u8, (hex >> 8) as u8, hex as u8)
}

fn rects(ops: &[DrawOp]) -> Vec<(kurbo::Rect, Rgba)> {
    ops.iter()
        .filter_map(|op| match op {
            DrawOp::Rect {
                rect,
                fill: Paint::Solid(c),
                ..
            } => Some((*rect, *c)),
            _ => None,
        })
        .collect()
}

/// Each run of glyphs: where, in what colour, and how many.
fn glyphs(ops: &[DrawOp]) -> Vec<(kurbo::Vec2, Rgba, usize)> {
    ops.iter()
        .filter_map(|op| match op {
            DrawOp::Glyphs {
                run,
                origin,
                paint: Paint::Solid(c),
                ..
            } => Some((*origin, *c, run.glyphs.len())),
            _ => None,
        })
        .collect()
}

#[test]
fn the_grid_follows_the_item_and_says_so() {
    let rig = Rig::new();
    let cols = ((400.0 - 2.0 * PAD) / rig.cw).floor();
    let rows = ((200.0 - 2.0 * PAD) / rig.ch).floor();
    assert_eq!((rig.num("columns"), rig.num("rows")), (cols, rows));
    assert_eq!(
        text(&rig.engine, rig.root, "sizes"),
        format!("{cols}x{rows} ")
    );
    assert!(rig.cw > 1.0 && rig.ch > 1.0);
}

#[test]
fn the_cells_follow_the_systems_text_size() {
    let rig = Rig::new();
    let columns = rig.num("columns");
    ljos::testing::update_system_prefs(&rig.engine, |p| p.font_scale = 2.0);
    assert!(rig.num("cellWidth") > rig.cw, "wider cells");
    assert!(rig.num("columns") < columns, "fewer of them");
}

#[test]
fn output_is_read_back_as_text_and_painted_as_cells() {
    let mut rig = Rig::new();
    rig.write("hello\r\nworld");
    assert_eq!(rig.method("text"), "hello\nworld");

    let ops = rig.ops();
    // The item is filled with the background first.
    let fills = rects(&ops);
    assert_eq!(fills[0].0, kurbo::Rect::new(0.0, 0.0, 400.0, 200.0));
    assert!(near(fills[0].1, rgb(0x1d1f21)));
    // Each row is one run, in the foreground colour, at its cell.
    let runs = glyphs(&ops);
    assert_eq!(runs.len(), 2);
    assert_eq!((runs[0].0.x, runs[0].0.y, runs[0].2), (PAD, PAD, 5));
    assert_eq!((runs[1].0.y, runs[1].2), (PAD + rig.ch, 5));
    assert!(near(runs[0].1, rgb(0xd8d8d8)));
    // The cursor is a block after the last character, as the focus is here.
    let cursor = kurbo::Rect::new(
        PAD + 5.0 * rig.cw,
        PAD + rig.ch,
        PAD + 6.0 * rig.cw,
        PAD + 2.0 * rig.ch,
    );
    assert!(
        fills
            .iter()
            .any(|(r, c)| *r == cursor && near(*c, rgb(0xd8d8d8)))
    );
}

#[test]
fn a_transparent_cursor_colour_is_one_and_not_the_default() {
    let mut rig = Rig::new();
    rig.write("hi");
    let cursor = kurbo::Rect::new(PAD + 2.0 * rig.cw, PAD, PAD + 3.0 * rig.cw, PAD + rig.ch);
    let fill = |rig: &mut Rig| {
        rects(&rig.ops())
            .into_iter()
            .find(|(r, _)| *r == cursor)
            .map(|(_, c)| c)
    };
    // Unset, the cursor is in the foreground colour.
    assert!(near(fill(&mut rig).expect("a cursor"), rgb(0xd8d8d8)));
    rig.engine
        .write_by_name(rig.term, "cursorColor", Value::Color(Color::TRANSPARENT))
        .unwrap();
    assert_eq!(fill(&mut rig).expect("a cursor").a, 0.0);
}

#[test]
fn colours_come_from_the_palette_and_the_item() {
    let mut rig = Rig::new();
    // ansiColors replaces entry 0 (black) with red; 34 is the palette's blue.
    rig.write("\x1b[30mA\x1b[34mB\x1b[0m\x1b[42m \x1b[0m");
    let ops = rig.ops();
    let runs = glyphs(&ops);
    assert_eq!(runs.len(), 2);
    assert!(near(runs[0].1, rgb(0xff0000)));
    assert!(near(runs[1].1, rgb(0x81a2be)));
    // The green background is a rectangle of its own at the third cell.
    let green = rects(&ops)
        .into_iter()
        .find(|(_, c)| near(*c, rgb(0xb5bd68)))
        .expect("a green cell")
        .0;
    assert_eq!(green.x0, PAD + 2.0 * rig.cw);
}

#[test]
fn an_unfocused_terminal_outlines_its_cursor() {
    let mut rig = Rig::new();
    let (cw, ch) = (rig.cw, rig.ch);
    let solid = |rects: &[(kurbo::Rect, Rgba)]| {
        rects
            .iter()
            .filter(|(r, _)| (r.width() - cw).abs() < 0.01 && (r.height() - ch).abs() < 0.01)
            .count()
    };
    assert_eq!(solid(&rects(&rig.ops())), 1);
    call(&rig.engine, rig.root, "blur", &[]);
    let after = rects(&rig.ops());
    assert_eq!(solid(&after), 0);
    // Four one-pixel sides.
    assert_eq!(
        after
            .iter()
            .filter(|(r, _)| r.width().min(r.height()) == 1.0 && r.x0 >= PAD)
            .count(),
        4
    );
}

#[test]
fn keys_become_input() {
    let mut rig = Rig::new();
    assert!(rig.type_key(KeyEvent::press(key::A).with_text("a")));
    assert!(rig.type_key(KeyEvent::press(key::RETURN).with_text("\r")));
    assert!(
        rig.type_key(
            KeyEvent::press(key::A + 2)
                .with_modifiers(Modifiers::CONTROL)
                .with_text("\u{3}")
        )
    );
    assert!(rig.type_key(KeyEvent::press(key::UP)));
    assert_eq!(rig.typed(), "a\r\u{3}\u{1b}[A");
    // The program asked for application cursor keys.
    rig.write("\x1b[?1h");
    rig.clear_typed();
    rig.type_key(KeyEvent::press(key::UP));
    assert_eq!(rig.typed(), "\u{1b}OA");
    // A modifier alone is not a key.
    assert!(!rig.type_key(KeyEvent::press(key::SHIFT).with_modifiers(Modifiers::SHIFT)));
}

#[test]
fn the_input_method_types_at_the_cursor() {
    let mut rig = Rig::new();
    rig.write("ab");
    assert_eq!(rig.scene.window.input_method_item(), Some(rig.term));
    // Its candidate window goes over the cursor's cell.
    let cursor = rig.scene.window.input_method_cursor().expect("a cursor");
    assert_eq!(
        cursor,
        kurbo::Rect::new(PAD + 2.0 * rig.cw, PAD, PAD + 3.0 * rig.cw, PAD + rig.ch)
    );
    assert!(rig.scene.window.commit("é"));
    assert_eq!(rig.typed(), "é");
}

#[test]
fn queries_are_answered_on_write_and_not_on_restore() {
    let mut rig = Rig::new();
    rig.write("\x1b[6n");
    assert_eq!(rig.typed(), "\u{1b}[1;1R");
    rig.clear_typed();
    call(
        &rig.engine,
        rig.term,
        "restore",
        &[Value::from("\x1b[6n\x1b[5n")],
    );
    assert_eq!(rig.typed(), "");
    // The replayed bytes are on the screen all the same.
    rig.write("x");
    assert_eq!(rig.method("text"), "x");
}

#[test]
fn a_paste_is_bracketed_when_the_program_asked_for_it() {
    let rig = Rig::new();
    call(&rig.engine, rig.term, "paste", &[Value::from("a\nb")]);
    assert_eq!(rig.typed(), "a\rb");
    let mut rig = rig;
    rig.write("\x1b[?2004h");
    rig.clear_typed();
    call(&rig.engine, rig.term, "paste", &[Value::from("a\nb")]);
    assert_eq!(rig.typed(), "\u{1b}[200~a\nb\u{1b}[201~");
}

#[test]
fn history_scrolls_and_typing_returns_to_the_prompt() {
    let mut rig = Rig::new();
    let rows = rig.num("rows");
    let lines: String = (0..100).map(|i| format!("line {i}\r\n")).collect();
    rig.write(&lines);
    // scrollbackLimit is 50.
    assert_eq!(rig.num("scrollTotal"), 50.0 + rows);
    assert!(rig.flag("atBottom"));
    let bottom = rig.num("scrollOffset");

    call(&rig.engine, rig.term, "scrollLines", &[Value::Int(-5)]);
    assert_eq!(rig.num("scrollOffset"), bottom - 5.0);
    assert!(!rig.flag("atBottom"));

    // A wheel notch is three rows.
    assert!(rig.wheel(1.0));
    assert_eq!(rig.num("scrollOffset"), bottom - 8.0);
    assert!(rig.wheel(-1.0));
    assert_eq!(rig.num("scrollOffset"), bottom - 5.0);

    call(&rig.engine, rig.term, "scrollTo", &[Value::Real(0.0)]);
    assert_eq!(rig.num("scrollOffset"), 0.0);

    rig.type_key(KeyEvent::press(key::A).with_text("a"));
    assert!(rig.flag("atBottom"));
    assert_eq!(rig.num("scrollOffset"), bottom);

    // Output while scrolled up leaves the view on the same lines. The
    // history is full, so the oldest line goes and every offset drops by one.
    call(&rig.engine, rig.term, "scrollLines", &[Value::Int(-10)]);
    let seen = rig.num("scrollOffset");
    rig.write("more\r\n");
    assert_eq!(rig.num("scrollOffset"), seen - 1.0);
    call(&rig.engine, rig.term, "scrollToBottom", &[]);
    assert!(rig.flag("atBottom"));
}

#[test]
fn dragging_selects_and_copy_puts_it_on_the_clipboard() {
    let mut rig = Rig::new();
    rig.write("hello world");
    assert!(!rig.flag("hasSelection"));
    rig.drag((0, 0), (0, 4));
    assert!(rig.flag("hasSelection"));
    assert_eq!(rig.method("selectedText"), "hello");
    // The selected cells are filled with selectionColor.
    let chosen = rects(&rig.ops())
        .into_iter()
        .filter(|(_, c)| near(*c, rgb(0x336699)))
        .count();
    assert_eq!(chosen, 5);

    call(&rig.engine, rig.term, "copy", &[]);
    assert_eq!(
        Platform::of(&rig.engine)
            .clipboard()
            .text(ClipboardMode::Clipboard),
        Some("hello".to_string())
    );

    // A click that does not move clears it.
    rig.drag((0, 2), (0, 2));
    assert!(!rig.flag("hasSelection"));
    assert_eq!(rig.method("selectedText"), "");

    call(&rig.engine, rig.term, "selectAll", &[]);
    assert!(rig.flag("hasSelection"));
    assert_eq!(rig.method("selectedText"), "hello world");
    call(&rig.engine, rig.term, "clearSelection", &[]);
    assert!(!rig.flag("hasSelection"));
}

#[test]
fn a_program_that_asks_for_the_mouse_gets_reports() {
    let mut rig = Rig::new();
    rig.write("\x1b[?1000h\x1b[?1006h");
    rig.drag((2, 3), (2, 3));
    assert_eq!(rig.typed(), "\u{1b}[<0;4;3M\u{1b}[<0;4;3m");
    assert!(!rig.flag("hasSelection"));

    rig.clear_typed();
    assert!(rig.wheel(1.0));
    // Three steps up are three presses of button four.
    assert_eq!(rig.typed().matches("\u{1b}[<64;2;2M").count(), 3);
}

#[test]
fn any_motion_reports_each_new_cell_the_pointer_enters() {
    let mut rig = Rig::new();
    let hover = |rig: &mut Rig, row, col| {
        let (x, y) = rig.centre(row, col);
        let now = rig.scene.window.now();
        rig.scene
            .window
            .pointer(&PointerEvent::moved(x, y, MouseButtons::empty(), now));
    };
    // Button-only tracking hears nothing of a move with no button.
    rig.write("\x1b[?1002h\x1b[?1006h");
    hover(&mut rig, 1, 1);
    assert_eq!(rig.typed(), "");
    rig.write("\x1b[?1003h");
    hover(&mut rig, 1, 2);
    hover(&mut rig, 1, 2);
    hover(&mut rig, 2, 2);
    // Button 3 (none) plus 32 for motion is 35.
    assert_eq!(rig.typed(), "\u{1b}[<35;3;2M\u{1b}[<35;3;3M");
}

#[test]
fn the_wheel_is_arrow_keys_on_an_alternate_screen() {
    let mut rig = Rig::new();
    rig.write("\x1b[?1049h");
    assert!(rig.wheel(1.0));
    assert_eq!(rig.typed(), "\u{1b}[A".repeat(3));
}

#[test]
fn title_directory_and_bell_are_reported() {
    let mut rig = Rig::new();
    rig.write("\x1b]2;build\x07\x1b]7;file://host/tmp\x1b\\");
    assert_eq!(rig.string("title"), "build");
    assert_eq!(rig.string("workingDirectory"), "file://host/tmp");
    // The BEL that ended the title is not a bell.
    assert_eq!(number(&rig.engine, rig.root, "bells"), 0.0);
    rig.write("\x07");
    assert_eq!(number(&rig.engine, rig.root, "bells"), 1.0);
}

#[test]
fn reset_is_a_blank_screen_with_no_history() {
    let mut rig = Rig::new();
    rig.write("\x1b]2;build\x07text\r\n");
    call(&rig.engine, rig.term, "reset", &[]);
    assert_eq!(rig.method("text"), "");
    assert_eq!(rig.string("title"), "");
    assert_eq!(rig.num("scrollTotal"), rig.num("rows"));
    assert!(glyphs(&rig.ops()).is_empty());
}
