//! `Terminal` in module `Ghostty`: the terminal desktop-qt gets from
//! qml-ghostty (`GhosttyTerminal`), with the same QML surface. The bricks
//! `import Ghostty` for it, so it is registered under that name, not under
//! `HalC2.Shell`.
//!
//! A program's output goes in through `write` (or `restore`, for a
//! transcript: its queries are not answered) and what the user types comes
//! out of the `input` signal; the grid follows the item's size, `resized`
//! says to what.
//!
//! The terminal emulation is the `vt100` crate, not libghostty-vt. libghostty
//! is a C library (`native/libghostty-vt` here builds it with Zig), which
//! Cargo would have to build and link, and its grid is read through an FFI
//! that hands out pointers; `vt100` is plain Rust with the grid, scrollback,
//! alternate screen, mouse and bracketed-paste modes the item needs, and
//! it builds with the rest. What it lacks that Ghostty has: the kitty
//! keyboard protocol and graphics, reflow of wrapped lines on resize, a
//! mode report for DECRQM, and grapheme-accurate widths for every emoji.
//!
//! The item draws its cells as filled rectangles and glyph runs in its own
//! display list ([`paint`]), with no animation: the cursor does not blink.
//!
//! Not done: double and triple click selection, scrolling while a drag
//! passes the item's edge, hyperlinks, and the selection following its text
//! once history is full and its oldest lines are dropped.

mod keys;
mod paint;
mod vt;

use std::fmt;
use std::rc::Rc;

use ljos::prelude::{Atom, Cx, Engine, EngineError, ObjectId, QmlObject, Value, qml_impl};
use ljos_engine::{Color, Font, MetaRef, NodeId, QmlType, Version};
use ljos_platform::{ClipboardMode, Platform};
use ljos_quick::flickable::{WheelItem, register_wheel_item};
use ljos_quick::focus::{FocusReason, force_active_focus};
use ljos_quick::keys::{
    KeyItem, Surrounding, TextInputClient, register_key_item, register_text_input_client,
};
use ljos_quick::{
    Item, ItemPaint, KeyEvent, Modifiers, MouseButtons, PointerEvent, PointerItem, WheelEvent,
    register_hover_move, register_paint_item, register_pointer_item, text_engine, text_style,
};
use ljos_render::{DisplayListBuilder, kurbo};

use keys::{MouseAction, encode_key, encode_mouse};
use paint::{Look, Painted};
use vt::{Pos, Vt};

/// The module the bricks import.
pub const MODULE: &str = "Ghostty";

/// Adds `Terminal` to module `Ghostty`.
pub fn register(engine: &Engine) {
    let v = Version::new(1, 0);
    let meta = || MetaRef::Static(Terminal::static_meta());
    engine.register_type(MODULE, v, meta());
    register_paint_item(engine, meta(), read_paint);
    register_key_item(
        engine,
        meta(),
        KeyItem {
            shortcut_override: |_, _, _| false,
            press: key_press,
            release: |_, _, _| false,
        },
    );
    register_pointer_item(
        engine,
        meta(),
        PointerItem {
            press: pointer_press,
            moved: pointer_moved,
            release: pointer_release,
            cancel: pointer_cancel,
            hover: |_, _, _| {},
        },
    );
    // Motion with no button held reaches only this hook, and only without
    // modifiers or time.
    register_hover_move(engine, meta(), hover_moved);
    register_wheel_item(engine, meta(), WheelItem { wheel });
    register_text_input_client(engine, meta(), Rc::new(Ime));
}

/// What the item keeps besides its properties.
#[derive(Default)]
struct State {
    /// Made when first needed, so `scrollbackLimit` is read after the QML
    /// has set it.
    vt: Option<Vt>,
    /// Moves when the cells do, so the scene repaints the item.
    serial: Option<NodeId>,
    /// The grid has been sized to the item at least once.
    sized: bool,
    /// A selection is being dragged from this cell.
    drag: Option<Pos>,
    /// The button whose press was sent to the program as a mouse report.
    reported: Option<u8>,
    /// The cell last reported to a program that asked for any motion.
    hovered: Option<(u16, u16)>,
    /// A fraction of a wheel step, kept for the next event.
    wheel_remainder: f64,
}

#[derive(QmlObject)]
#[qml(module = "Ghostty", name = "Terminal", extends = Item, default = "data")]
pub struct Terminal {
    #[qml(base)]
    pub item: Item,
    #[qml(notify)]
    pub font: Font,
    #[qml(notify)]
    pub foreground_color: Color,
    #[qml(notify)]
    pub background_color: Color,
    /// Fully transparent (the default) draws the cursor in the foreground
    /// colour.
    #[qml(notify)]
    pub cursor_color: Color,
    /// Fully transparent (the default) shows a selection by swapping the
    /// colours of its cells.
    #[qml(notify)]
    pub selection_color: Color,
    /// Colours for the first palette entries (the 16 ANSI ones, and on to
    /// 256); only colour values count.
    #[qml(notify)]
    pub ansi_colors: Value,
    /// Space between the item's edge and the cells, in pixels.
    #[qml(notify)]
    pub padding: f64,
    /// Lines of history kept; read once, before the first output.
    #[qml(notify)]
    pub scrollback_limit: i32,
    #[qml(notify, readonly)]
    pub columns: i32,
    #[qml(notify, readonly)]
    pub rows: i32,
    #[qml(notify, readonly)]
    pub cell_width: f64,
    #[qml(notify, readonly)]
    pub cell_height: f64,
    #[qml(notify, readonly)]
    pub title: Atom,
    /// As the shell reported it: OSC 7 sends a `file://` URI.
    #[qml(notify, readonly)]
    pub working_directory: Atom,
    #[qml(notify, readonly)]
    pub has_selection: bool,
    /// History and screen in rows: the view shows
    /// `[scrollOffset, scrollOffset + rows)` of `scrollTotal`.
    #[qml(notify, readonly)]
    pub scroll_total: f64,
    #[qml(notify, readonly)]
    pub scroll_offset: f64,
    #[qml(notify, readonly)]
    pub at_bottom: bool,
    #[qml(skip)]
    state: State,
}

impl fmt::Debug for Terminal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Terminal")
            .field("columns", &self.columns)
            .field("rows", &self.rows)
            .finish_non_exhaustive()
    }
}

impl Default for Terminal {
    fn default() -> Self {
        Terminal {
            item: Item::default(),
            font: Font::default(),
            foreground_color: Color::from_rgba8(0xd8, 0xd8, 0xd8, 0xff),
            background_color: Color::from_rgba8(0x1d, 0x1f, 0x21, 0xff),
            cursor_color: Color::TRANSPARENT,
            selection_color: Color::TRANSPARENT,
            ansi_colors: Value::Undefined,
            padding: 4.0,
            scrollback_limit: 10_000,
            columns: 80,
            rows: 24,
            cell_width: 0.0,
            cell_height: 0.0,
            title: Atom::from(""),
            working_directory: Atom::from(""),
            has_selection: false,
            scroll_total: 24.0,
            scroll_offset: 0.0,
            at_bottom: true,
            state: State::default(),
        }
    }
}

#[qml_impl]
impl Terminal {
    /// What the user typed, pasted or the terminal answered, as the bytes
    /// of a UTF-8 string, for the program.
    #[qml(signal)]
    fn input(data: Atom);

    /// The grid changed size, because the item did or the font did.
    #[qml(signal)]
    fn resized(columns: i32, rows: i32);

    #[qml(signal)]
    fn bell();

    #[qml(on_complete)]
    fn completed(cx: &Cx) -> Result<(), EngineError> {
        let (e, me) = (cx.engine, cx.this);
        let scope = e.object_scope(me).unwrap_or_else(|| e.graph().root());
        let serial = e.graph().property(scope, Value::Int(0)).ok();
        e.with_mut::<Terminal, _>(me, |t| t.state.serial = serial)?;
        // The grid follows the item's size and font.
        e.effect_in(me, move |e| {
            let w = e.read(me, Item::WIDTH.index).to_number();
            let h = e.read(me, Item::HEIGHT.index).to_number();
            let font = e.read(me, Self::FONT.index);
            let padding = e.read(me, Self::PADDING.index).to_number();
            e.untrack(|| relayout(e, me, (w, h), &font, padding));
        })?;
        Ok(())
    }

    /// Program output: a string (taken as UTF-8) or a list of byte values.
    #[qml(invokable)]
    fn write(cx: &Cx, data: Value) {
        feed(cx.engine, cx.this, &bytes_of(&data), true);
    }

    /// Replays retained history. Queries in it (device status, attributes)
    /// are not answered: the program that sent them is gone, and the reply
    /// would land at the new shell's prompt.
    #[qml(invokable)]
    fn restore(cx: &Cx, data: Value) {
        feed(cx.engine, cx.this, &bytes_of(&data), false);
    }

    /// Back to a blank screen with no history, as for a restarted shell.
    #[qml(invokable)]
    fn reset(cx: &Cx) {
        let (e, me) = (cx.engine, cx.this);
        if vt_mut(e, me, Vt::reset).is_some() {
            put(e, me, Self::TITLE, Atom::from(""));
            put(e, me, Self::WORKING_DIRECTORY, Atom::from(""));
            sync(e, me);
        }
    }

    /// Sends text as a paste: bracketed when the program asked for it, with
    /// control bytes that could end the paste early defused.
    #[qml(invokable)]
    fn paste(cx: &Cx, text: Atom) {
        let (e, me) = (cx.engine, cx.this);
        let Some(bracketed) = vt_mut(e, me, |vt| vt.bracketed_paste()) else {
            return;
        };
        if let Some(bytes) = paste_bytes(text.as_str(), bracketed) {
            send(e, me, &bytes, true);
        }
    }

    /// Puts the selected text on the clipboard.
    #[qml(invokable)]
    fn copy(cx: &Cx) {
        let text = Self::selected_text(cx);
        if !text.is_empty() {
            Platform::of(cx.engine)
                .clipboard()
                .set_text(ClipboardMode::Clipboard, &text);
        }
    }

    #[qml(invokable)]
    fn select_all(cx: &Cx) {
        vt_mut(cx.engine, cx.this, Vt::select_all);
        sync(cx.engine, cx.this);
    }

    #[qml(invokable)]
    fn clear_selection(cx: &Cx) {
        vt_mut(cx.engine, cx.this, Vt::clear_selection);
        sync(cx.engine, cx.this);
    }

    #[qml(invokable)]
    fn selected_text(cx: &Cx) -> String {
        vt_mut(cx.engine, cx.this, Vt::selected_text).unwrap_or_default()
    }

    /// Scrollback and screen as plain text, soft wraps joined.
    #[qml(invokable)]
    fn text(cx: &Cx) -> String {
        vt_mut(cx.engine, cx.this, Vt::text).unwrap_or_default()
    }

    /// Scrolls the view by `delta` rows; negative goes back into history.
    #[qml(invokable)]
    fn scroll_lines(cx: &Cx, delta: i32) {
        scroll(cx.engine, cx.this, i64::from(delta));
    }

    /// Puts row `offset` (of `scrollTotal`) at the top of the view.
    #[qml(invokable)]
    fn scroll_to(cx: &Cx, offset: f64) {
        let top = if offset.is_finite() {
            offset.round().max(0.0) as usize
        } else {
            0
        };
        vt_mut(cx.engine, cx.this, |vt| vt.scroll_to(top));
        sync(cx.engine, cx.this);
    }

    #[qml(invokable)]
    fn scroll_to_bottom(cx: &Cx) {
        vt_mut(cx.engine, cx.this, Vt::scroll_to_bottom);
        sync(cx.engine, cx.this);
    }
}

// The vt and the properties that mirror it.

/// Runs `f` on the terminal's state, making it first if need be. None when
/// `me` is not a terminal. `f` must not call back into the engine.
fn vt_mut<R>(e: &Engine, me: ObjectId, f: impl FnOnce(&mut Vt) -> R) -> Option<R> {
    e.with_mut::<Terminal, _>(me, |t| {
        let (rows, cols) = (
            t.rows.clamp(1, 1000) as u16,
            t.columns.clamp(1, 1000) as u16,
        );
        let limit = t.scrollback_limit.max(0) as usize;
        f(t.state.vt.get_or_insert_with(|| Vt::new(rows, cols, limit)))
    })
    .ok()
}

/// Sets a readonly property, notifying only when it changes.
fn put<T: PartialEq + ljos_engine::QmlValue>(
    e: &Engine,
    me: ObjectId,
    p: ljos_engine::Prop<T>,
    v: T,
) {
    if e.get(me, p).ok().as_ref() != Some(&v) {
        let _ = e.set_internal(me, p, v);
    }
}

/// Brings the scroll, selection and size properties in line with the vt and
/// asks for a repaint.
fn sync(e: &Engine, me: ObjectId) {
    let Some((total, top, at_bottom, selected, (rows, cols))) = vt_mut(e, me, |vt| {
        (
            vt.total(),
            vt.top(),
            vt.at_bottom(),
            vt.has_selection(),
            vt.size(),
        )
    }) else {
        return;
    };
    let serial = e.with::<Terminal, _>(me, |t| t.state.serial).ok().flatten();
    e.batch(|| {
        put(e, me, Terminal::SCROLL_TOTAL, total as f64);
        put(e, me, Terminal::SCROLL_OFFSET, top as f64);
        put(e, me, Terminal::AT_BOTTOM, at_bottom);
        put(e, me, Terminal::HAS_SELECTION, selected);
        put(e, me, Terminal::ROWS, i32::from(rows));
        put(e, me, Terminal::COLUMNS, i32::from(cols));
        if let Some(n) = serial {
            let next = e.graph().get_untracked(n).to_number() as i32 + 1;
            e.graph().set(n, Value::Int(next));
        }
    });
}

fn bytes_of(data: &Value) -> Vec<u8> {
    match data {
        Value::String(s) => s.as_str().as_bytes().to_vec(),
        Value::List(items) => items.iter().map(|v| v.to_number() as u8).collect(),
        _ => Vec::new(),
    }
}

/// Gives the vt program output and carries out what came of it.
fn feed(e: &Engine, me: ObjectId, bytes: &[u8], answer: bool) {
    if bytes.is_empty() {
        return;
    }
    let Some(fed) = vt_mut(e, me, |vt| vt.feed(bytes, answer)) else {
        return;
    };
    if let Some(title) = fed.title {
        put(e, me, Terminal::TITLE, Atom::from(title.as_str()));
    }
    if let Some(cwd) = fed.cwd {
        put(e, me, Terminal::WORKING_DIRECTORY, Atom::from(cwd.as_str()));
    }
    sync(e, me);
    if !fed.replies.is_empty() {
        send(e, me, &fed.replies, false);
    }
    if fed.bells > 0 {
        let _ = e.emit_by_name(me, "bell", &[]);
    }
}

/// Emits `input`. What the user typed brings the view back to the prompt.
fn send(e: &Engine, me: ObjectId, bytes: &[u8], user: bool) {
    if bytes.is_empty() {
        return;
    }
    if user && vt_mut(e, me, |vt| !vt.at_bottom()) == Some(true) {
        vt_mut(e, me, Vt::scroll_to_bottom);
        sync(e, me);
    }
    let text = String::from_utf8_lossy(bytes);
    let _ = e.emit_by_name(me, "input", &[Value::String(Atom::from(&*text))]);
}

fn scroll(e: &Engine, me: ObjectId, delta: i64) {
    if delta != 0 {
        vt_mut(e, me, |vt| vt.scroll_by(delta));
        sync(e, me);
    }
}

/// The bytes of a paste, or none for nothing to paste. Control bytes other
/// than tab and line breaks become spaces, so that a pasted escape cannot
/// end a bracketed paste or run as a command.
fn paste_bytes(text: &str, bracketed: bool) -> Option<Vec<u8>> {
    if text.is_empty() {
        return None;
    }
    let mut out = String::with_capacity(text.len() + 12);
    if bracketed {
        out.push_str("\x1b[200~");
    }
    for c in text.chars() {
        match c {
            '\n' if !bracketed => out.push('\r'),
            '\n' | '\r' | '\t' => out.push(c),
            c if c.is_control() => out.push(' '),
            c => out.push(c),
        }
    }
    if bracketed {
        out.push_str("\x1b[201~");
    }
    Some(out.into_bytes())
}

// The grid follows the item.

fn font_style(font: &Value) -> ljos_quick::TextStyle {
    match font {
        Value::Font(f) => text_style(f),
        _ => text_style(&Font::default()),
    }
}

/// Sizes the grid to the item: as many whole cells as fit inside the
/// padding. A grid with nothing to show on, an item of no size, keeps its
/// last size.
fn relayout(e: &Engine, me: ObjectId, (w, h): (f64, f64), font: &Value, padding: f64) {
    let style = font_style(font);
    let (cw, ch) = {
        let te = text_engine();
        let mut te = te.borrow_mut();
        paint::cell_size(&mut te, &style)
    };
    put(e, me, Terminal::CELL_WIDTH, cw);
    put(e, me, Terminal::CELL_HEIGHT, ch);
    if w <= 0.0 || h <= 0.0 {
        return;
    }
    let fit = |extent: f64, cell: f64| {
        ((extent - 2.0 * padding) / cell).floor().clamp(1.0, 1000.0) as u16
    };
    let (cols, rows) = (fit(w, cw), fit(h, ch));
    let Some((was, first)) = e
        .with_mut::<Terminal, _>(me, |t| {
            (
                t.rows != i32::from(rows) || t.columns != i32::from(cols),
                !std::mem::replace(&mut t.state.sized, true),
            )
        })
        .ok()
    else {
        return;
    };
    vt_mut(e, me, |vt| vt.resize(rows, cols));
    sync(e, me);
    if was || first {
        let _ = e.emit_by_name(
            me,
            "resized",
            &[Value::Int(i32::from(cols)), Value::Int(i32::from(rows))],
        );
    }
}

// Painting.

/// The palette and colours the properties say.
fn look(e: &Engine, me: ObjectId, style: ljos_quick::TextStyle, cell: (f64, f64)) -> Look {
    let color = |p: ljos_engine::PropIndex| -> paint::Color {
        match e.read(me, p) {
            Value::Color(c) => {
                let [r, g, b, a] = c.to_rgba_f();
                [r as f32, g as f32, b as f32, a as f32]
            }
            _ => [0.0; 4],
        }
    };
    let optional = |p| Some(color(p)).filter(|c| c[3] > 0.0);
    let mut palette = paint::default_palette();
    if let Value::List(items) = e.read(me, Terminal::ANSI_COLORS.index) {
        for (slot, v) in palette.iter_mut().zip(items.iter()) {
            if let Value::Color(c) = v {
                let [r, g, b, a] = c.to_rgba_f();
                *slot = [r as f32, g as f32, b as f32, a as f32];
            }
        }
    }
    Look {
        foreground: color(Terminal::FOREGROUND_COLOR.index),
        background: color(Terminal::BACKGROUND_COLOR.index),
        cursor: optional(Terminal::CURSOR_COLOR.index),
        selection: optional(Terminal::SELECTION_COLOR.index),
        palette,
        padding: e.read(me, Terminal::PADDING.index).to_number(),
        style,
        cell,
        focused: e.read(me, Item::ACTIVE_FOCUS.index).to_boolean(),
    }
}

#[derive(Debug)]
struct Screen(Painted);

impl ItemPaint for Screen {
    fn paint(&self, size: kurbo::Size, out: &mut DisplayListBuilder) {
        self.0.paint(size, out);
    }
}

/// Read tracked: the cells, the colours, the font and the focus repaint the
/// item.
fn read_paint(e: &Engine, me: ObjectId) -> Rc<dyn ItemPaint> {
    if let Some(n) = e.with::<Terminal, _>(me, |t| t.state.serial).ok().flatten() {
        let _ = e.graph().get(n);
    }
    let style = font_style(&e.read(me, Terminal::FONT.index));
    let te = text_engine();
    let cell = paint::cell_size(&mut te.borrow_mut(), &style);
    let look = look(e, me, style, cell);
    let background = look.background;
    // The engine's store is borrowed in `vt_mut`, and the text engine must
    // be free for anything that reads properties: lay out last.
    let painted = vt_mut(e, me, |vt| paint::build(vt, &look, &mut te.borrow_mut()));
    Rc::new(Screen(painted.unwrap_or_else(|| Painted {
        background,
        ..Default::default()
    })))
}

// Keys.

fn key_press(e: &Engine, me: ObjectId, ev: &KeyEvent) -> bool {
    // Shift+PageUp and Shift+PageDown page through history, as in xterm.
    if ev.modifiers == Modifiers::SHIFT
        && (ev.key == ljos_quick::keys::key::PAGE_UP || ev.key == ljos_quick::keys::key::PAGE_DOWN)
    {
        let page = vt_mut(e, me, |vt| i64::from(vt.size().0).saturating_sub(1).max(1)).unwrap_or(1);
        scroll(
            e,
            me,
            if ev.key == ljos_quick::keys::key::PAGE_UP {
                -page
            } else {
                page
            },
        );
        return true;
    }
    let app = vt_mut(e, me, |vt| vt.application_cursor()).unwrap_or(false);
    match encode_key(ev.key, ev.modifiers, &ev.text, app) {
        Some(bytes) => {
            send(e, me, &bytes, true);
            true
        }
        None => false,
    }
}

// The input method: committed text is typed.

struct Ime;

impl TextInputClient for Ime {
    fn surrounding(&self, _: &Engine, _: ObjectId) -> Surrounding {
        Surrounding::default()
    }

    fn replace(&self, e: &Engine, item: ObjectId, _: std::ops::Range<usize>, text: &str) {
        send(e, item, text.as_bytes(), true);
    }

    fn set_selection(&self, _: &Engine, _: ObjectId, _: usize, _: usize) {}

    fn cursor_rect(&self, e: &Engine, item: ObjectId) -> kurbo::Rect {
        let (cw, ch, pad) = metrics(e, item);
        let (row, col) = vt_mut(e, item, |vt| vt.cursor())
            .flatten()
            .unwrap_or((0, 0));
        let (x, y) = (pad + f64::from(col) * cw, pad + f64::from(row) * ch);
        kurbo::Rect::new(x, y, x + cw, y + ch)
    }

    fn hints(&self, _: &Engine, _: ObjectId) -> i32 {
        0
    }
}

// The mouse.

/// Cell width, cell height and padding.
fn metrics(e: &Engine, me: ObjectId) -> (f64, f64, f64) {
    e.with::<Terminal, _>(me, |t| {
        (t.cell_width.max(1.0), t.cell_height.max(1.0), t.padding)
    })
    .unwrap_or((1.0, 1.0, 0.0))
}

/// The cell under `at` (in the item), the nearest one for a point outside
/// the grid, as `(row, column)` of the view.
fn cell_at(e: &Engine, me: ObjectId, at: kurbo::Point) -> (u16, u16) {
    let (cw, ch, pad) = metrics(e, me);
    let (rows, cols) = vt_mut(e, me, |vt| vt.size()).unwrap_or((1, 1));
    let col = ((at.x - pad) / cw).floor().clamp(0.0, f64::from(cols - 1)) as u16;
    let row = ((at.y - pad) / ch).floor().clamp(0.0, f64::from(rows - 1)) as u16;
    (row, col)
}

fn report(
    e: &Engine,
    me: ObjectId,
    action: MouseAction,
    button: u8,
    mods: Modifiers,
    at: (u16, u16),
) {
    let Some(encoding) = vt_mut(e, me, |vt| vt.mouse_encoding()) else {
        return;
    };
    let bytes = encode_mouse(encoding, action, button, mods, at.1, at.0);
    send(e, me, &bytes, false);
}

fn button_number(b: Option<MouseButtons>) -> Option<u8> {
    match b? {
        MouseButtons::LEFT => Some(0),
        MouseButtons::MIDDLE => Some(1),
        MouseButtons::RIGHT => Some(2),
        _ => None,
    }
}

fn pointer_press(e: &Engine, me: ObjectId, ev: &PointerEvent, at: kurbo::Point) -> bool {
    force_active_focus(e, me, FocusReason::Mouse);
    let tracking = vt_mut(e, me, |vt| vt.mouse_tracking()).unwrap_or(false);
    let cell = cell_at(e, me, at);
    if tracking && !ev.modifiers.contains(Modifiers::SHIFT) {
        let Some(button) = button_number(ev.button) else {
            return false;
        };
        let _ = e.with_mut::<Terminal, _>(me, |t| t.state.reported = Some(button));
        report(e, me, MouseAction::Press, button, ev.modifiers, cell);
        return true;
    }
    if ev.button != Some(MouseButtons::LEFT) {
        return false;
    }
    let top = vt_mut(e, me, |vt| {
        vt.clear_selection();
        vt.top()
    })
    .unwrap_or(0);
    let from = Pos {
        row: top + usize::from(cell.0),
        col: cell.1,
    };
    let _ = e.with_mut::<Terminal, _>(me, |t| t.state.drag = Some(from));
    sync(e, me);
    true
}

fn pointer_moved(e: &Engine, me: ObjectId, ev: &PointerEvent, at: kurbo::Point) {
    let cell = cell_at(e, me, at);
    let Ok((drag, reported)) = e.with::<Terminal, _>(me, |t| (t.state.drag, t.state.reported))
    else {
        return;
    };
    if let Some(button) = reported {
        if vt_mut(e, me, |vt| vt.mouse_drag()).unwrap_or(false) {
            report(e, me, MouseAction::Motion, button, ev.modifiers, cell);
        }
    } else if let Some(from) = drag {
        let moved = vt_mut(e, me, |vt| {
            let to = Pos {
                row: vt.top() + usize::from(cell.0),
                col: cell.1,
            };
            // A press that has not left its cell selects nothing.
            if to != from || vt.has_selection() {
                vt.select(from, to);
            }
        });
        if moved.is_some() {
            sync(e, me);
        }
    }
}

/// The pointer moved over the item with no button down: a program that asked
/// for any motion hears of each new cell (button 3 is "none").
fn hover_moved(e: &Engine, me: ObjectId, at: kurbo::Point) {
    let cell = cell_at(e, me, at);
    let Ok(idle) = e.with_mut::<Terminal, _>(me, |t| {
        let idle = t.state.drag.is_none() && t.state.reported.is_none();
        idle && t.state.hovered.replace(cell) != Some(cell)
    }) else {
        return;
    };
    if idle && vt_mut(e, me, |vt| vt.mouse_any_motion()).unwrap_or(false) {
        report(e, me, MouseAction::Motion, 3, Modifiers::empty(), cell);
    }
}

fn pointer_release(e: &Engine, me: ObjectId, ev: &PointerEvent, at: kurbo::Point) {
    let reported = e
        .with_mut::<Terminal, _>(me, |t| {
            t.state.drag = None;
            t.state.reported.take()
        })
        .ok()
        .flatten();
    if let Some(button) = reported {
        report(
            e,
            me,
            MouseAction::Release,
            button,
            ev.modifiers,
            cell_at(e, me, at),
        );
    }
}

fn pointer_cancel(e: &Engine, me: ObjectId) {
    let _ = e.with_mut::<Terminal, _>(me, |t| {
        t.state.drag = None;
        t.state.reported = None;
    });
}

/// Rows a wheel event asks for: a touchpad's pixels, or three rows to a
/// notch.
fn wheel_rows(ev: &WheelEvent, cell_height: f64) -> f64 {
    if ev.pixel_delta.y != 0.0 {
        -ev.pixel_delta.y / cell_height
    } else {
        -ev.angle_delta.y / WheelEvent::NOTCH * 3.0
    }
}

fn wheel(e: &Engine, me: ObjectId, ev: &WheelEvent, at: kurbo::Point) -> bool {
    let (_, ch, _) = metrics(e, me);
    let Ok(steps) = e.with_mut::<Terminal, _>(me, |t| {
        t.state.wheel_remainder += wheel_rows(ev, ch);
        let steps = t.state.wheel_remainder.trunc();
        t.state.wheel_remainder -= steps;
        steps as i64
    }) else {
        return false;
    };
    if steps == 0 {
        return true;
    }
    let Some((tracking, alternate, app)) = vt_mut(e, me, |vt| {
        (
            vt.mouse_tracking(),
            vt.alternate_screen(),
            vt.application_cursor(),
        )
    }) else {
        return false;
    };
    if tracking && !ev.modifiers.contains(Modifiers::SHIFT) {
        // Steps are presses of buttons four (up) and five (down).
        let button = if steps < 0 { 4 } else { 5 };
        let cell = cell_at(e, me, at);
        for _ in 0..steps.unsigned_abs().min(10) {
            report(e, me, MouseAction::Press, button, ev.modifiers, cell);
        }
    } else if alternate {
        // Full-screen programs without mouse support (less, man) see arrows.
        let arrow: &[u8] = match (steps < 0, app) {
            (true, true) => b"\x1bOA",
            (false, true) => b"\x1bOB",
            (true, false) => b"\x1b[A",
            (false, false) => b"\x1b[B",
        };
        let n = steps.unsigned_abs().min(100) as usize;
        send(e, me, &arrow.repeat(n), false);
    } else {
        scroll(e, me, steps);
    }
    true
}

#[cfg(test)]
mod tests {
    use super::paste_bytes;

    #[test]
    fn a_paste_is_bracketed_when_asked_and_defused() {
        assert_eq!(paste_bytes("", true), None);
        assert_eq!(paste_bytes("a\nb", false).unwrap(), b"a\rb");
        assert_eq!(
            paste_bytes("a\nb", true).unwrap(),
            b"\x1b[200~a\nb\x1b[201~"
        );
        let defused = paste_bytes("x\x1b[201~y", true).unwrap();
        assert_eq!(defused, b"\x1b[200~x [201~y\x1b[201~");
    }
}
