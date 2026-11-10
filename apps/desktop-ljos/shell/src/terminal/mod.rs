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
//! The terminal is libghostty-vt, through Ljós Hof's `hof_vt`: a
//! [`Session::remote`] whose program is wherever the MC runs it, its output
//! fed in and its input collected by an [`Outlet`] for the signal. Ghostty
//! encodes keys (the whole kitty keyboard protocol), mouse reports and
//! pastes, answers queries (DECRQM among them), reflows wrapped lines on
//! resize, and finds links and words for the selection.
//!
//! The item draws hof_vt's [`Grid`] as filled rectangles and glyph runs in
//! its own display list ([`paint`]), with no animation: the cursor is drawn
//! steady (hal-c2/hal-c2#1193). Keys and the pointer follow Ljós Hof's
//! `hof_qml` terminal (`keys.rs`, `pointer.rs`, MIT), which [`keys`] copies
//! and the pointer handlers here adapt; links are opened by the bricks, so a
//! Control+click is left to them.
//!
//! Not done: scrolling while a drag passes the item's edge, and images
//! (kitty graphics, sixel).

mod keys;
mod paint;

use std::fmt;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use hof_vt::libghostty_vt::screen::Screen as Active;
use hof_vt::libghostty_vt::terminal::Mode;
use hof_vt::{
    CursorShape, Grid, MouseAction, MouseButton, MouseInput, Options, Outlet, Rgb, Scroll,
    Selecting, Session, Size, Theme,
};
use ljos::item::{
    self, DisplayListBuilder, FocusReason, Font, Item, ItemPaint, KeyEvent, KeyItem, Modifiers,
    MouseButtons, PointerEvent, PointerItem, Surrounding, TextEngine, TextInputClient, TextStyle,
    WheelEvent, WheelItem, force_active_focus, key, kurbo,
};
use ljos::prelude::{
    Atom, ClipboardMode, Color, Cx, Engine, EngineError, ObjectId, Platform, Prop, QmlObject,
    QmlValue, Time, Value, qml_impl,
};

use paint::{Look, Painted};

/// Adds `Terminal` to module `Ghostty`.
pub fn register(engine: &Engine) {
    engine.register_module(ljos::module!("Ghostty" 1.0 => [Terminal]));
    item::register_paint_item::<Terminal>(engine, read_paint);
    item::register_key_item::<Terminal>(
        engine,
        KeyItem {
            shortcut_override: |_, _, _| false,
            press: key_press,
            release: |_, _, _| false,
        },
    );
    item::register_pointer_item::<Terminal>(
        engine,
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
    item::register_hover_move::<Terminal>(engine, hover_moved);
    item::register_wheel_item::<Terminal>(engine, WheelItem { wheel });
    item::register_text_input_client::<Terminal>(engine, Rc::new(Ime));
}

/// Clicks this close together, on the same cell, count as one more.
const MULTI_CLICK: Duration = Duration::from_millis(400);

/// Where the session's input goes: kept until the item emits it.
#[derive(Default)]
struct Pending(Mutex<Vec<u8>>);

impl Pending {
    fn take(&self) -> Vec<u8> {
        std::mem::take(&mut *self.0.lock().unwrap_or_else(|e| e.into_inner()))
    }
}

impl Outlet for Pending {
    fn input(&self, bytes: &[u8]) {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .extend_from_slice(bytes);
    }

    // The item says its size with `resized`, and the bricks pass it on.
    fn resize(&self, _: Size) {}

    fn closed(&self) {}
}

/// The terminal and what it last drew.
struct Vt {
    session: Session,
    grid: Grid,
    pending: Arc<Pending>,
}

impl Vt {
    fn new(size: Size, scrollback: usize, theme: Theme) -> Option<Vt> {
        let pending = Arc::new(Pending::default());
        let outlet = Arc::clone(&pending);
        let options = Options {
            size,
            scrollback,
            theme: Some(theme),
            cursor: CursorShape::Block,
            cursor_blink: false,
            ..Options::default()
        };
        let session = Session::remote(options, || {}, move |_| outlet as Arc<dyn Outlet>).ok()?;
        Some(Vt {
            session,
            grid: Grid::new().ok()?,
            pending,
        })
    }

    fn alternate(&self) -> bool {
        self.session
            .with_terminal(|t| t.active_screen().ok() == Some(Active::Alternate))
    }

    fn application_cursor(&self) -> bool {
        self.session
            .with_terminal(|t| t.mode(Mode::DECCKM).unwrap_or(false))
    }
}

/// What the item keeps besides its properties.
#[derive(Default)]
struct State {
    /// Made when first needed, so `scrollbackLimit` is read after the QML
    /// has set it.
    vt: Option<Vt>,
    /// The colours last given to the terminal.
    theme: Theme,
    /// A cell in device pixels, as mouse reports count them.
    cell_px: (u32, u32),
    /// The grid has been sized to the item at least once.
    sized: bool,
    /// A left press is selecting, from this cell.
    selecting: Option<(u16, u16)>,
    /// A selecting drag held past the top (-1) or bottom (1) edge scrolls
    /// the history a row at a time, by generation as the blink does.
    edge: i32,
    edge_generation: u64,
    /// Where the selecting drag last was.
    drag_at: kurbo::Point,
    /// The button whose press was sent to the program as a mouse report.
    reported: Option<MouseButton>,
    /// The cell last reported to a program that asked for any motion.
    hovered: Option<(u16, u16)>,
    /// A fraction of a wheel step, kept for the next event.
    wheel_remainder: f64,
    /// What an input method is composing, drawn at the cursor until it
    /// commits or cancels.
    preedit: String,
    last_click: Option<(Time, (u16, u16))>,
    clicks: u8,
    /// The cursor is in the off half of a blink.
    blink_off: bool,
    /// The blink timer due, by generation: a newer one supersedes it.
    blink_due: Option<u64>,
    blink_generation: u64,
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
    /// Invalid (the default) draws the cursor in the foreground colour.
    #[qml(notify)]
    pub cursor_color: Color,
    /// Invalid (the default) shows a selection by swapping the colours of
    /// its cells.
    #[qml(notify)]
    pub selection_color: Color,
    /// Colours for the first palette entries (the 16 ANSI ones, and on to
    /// 256); only colour values count.
    #[qml(notify)]
    pub ansi_colors: Value,
    /// Space between the item's edge and the cells, in pixels.
    #[qml(notify)]
    pub padding: f64,
    /// Lines of history kept.
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
    /// Why the terminal engine could not start; empty while it runs. A new
    /// Terminal tries again.
    #[qml(notify, readonly)]
    pub error: Atom,
    /// History and screen in rows: the view shows
    /// `[scrollOffset, scrollOffset + rows)` of `scrollTotal`.
    #[qml(notify, readonly)]
    pub scroll_total: f64,
    #[qml(notify, readonly)]
    pub scroll_offset: f64,
    #[qml(notify, readonly)]
    pub at_bottom: bool,
    /// A program in the terminal asked for mouse reports, so presses go
    /// to it rather than selecting (qml-ghostty's).
    #[qml(notify, readonly)]
    pub mouse_tracking: bool,
    /// Whether the cursor may blink (qml-ghostty's): it blinks while the
    /// item has the keyboard and the program asked for a blinking cursor.
    #[qml(notify)]
    pub cursor_blink: bool,
    /// The toolkit's macOS keys (Cmd reported as Control, Control as Meta)
    /// turned back into the real ones for the program: on by default on
    /// macOS.
    #[qml(notify)]
    pub mac_modifiers: bool,
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
            cursor_color: Color::INVALID,
            selection_color: Color::INVALID,
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
            error: Atom::from(""),
            scroll_total: 24.0,
            scroll_offset: 0.0,
            at_bottom: true,
            mouse_tracking: false,
            cursor_blink: true,
            mac_modifiers: cfg!(target_os = "macos"),
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
        // The grid follows the item's size, its font and the system's text
        // size.
        e.effect_in(me, move |e| {
            let w = e.read(me, Item::WIDTH.index).to_number();
            let h = e.read(me, Item::HEIGHT.index).to_number();
            let style = font_style(e, me);
            let padding = e.read(me, Self::PADDING.index).to_number();
            e.untrack(|| relayout(e, me, (w, h), &style, padding));
        })?;
        e.effect_in(me, move |e| follow_loader(e, me))?;
        // The colours and the history follow their properties.
        e.effect_in(me, move |e| {
            let theme = theme(e, me);
            let limit = item::prop(e, me, Self::SCROLLBACK_LIMIT).max(0) as usize;
            e.untrack(|| {
                vt_mut(e, me, |vt, state| {
                    if state.theme != theme {
                        let _ = vt.session.set_theme(&theme);
                        state.theme = theme;
                    }
                    let _ = vt.session.set_scrollback(limit);
                });
                flush(e, me);
            });
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
        if vt_mut(e, me, |vt, _| vt.session.reset()).is_some() {
            put(e, me, Self::WORKING_DIRECTORY, Atom::from(""));
            flush(e, me);
        }
    }

    /// Sends text as a paste, as the program asked for pastes: bracketed
    /// when it did, with control bytes that could end the paste early or
    /// run as a command defused.
    #[qml(invokable)]
    fn paste(cx: &Cx, text: Atom) {
        paste_text(cx.engine, cx.this, text.as_str());
    }

    /// Puts the selected text on the clipboard; false when nothing is
    /// selected or the clipboard refused it.
    #[qml(invokable)]
    fn copy(cx: &Cx) -> bool {
        copy_to(cx.engine, cx.this, ClipboardMode::Clipboard)
    }

    #[qml(invokable)]
    fn select_all(cx: &Cx) {
        vt_mut(cx.engine, cx.this, |vt, _| vt.session.select_all());
        flush(cx.engine, cx.this);
    }

    #[qml(invokable)]
    fn clear_selection(cx: &Cx) {
        vt_mut(cx.engine, cx.this, |vt, _| vt.session.clear_selection());
        flush(cx.engine, cx.this);
    }

    #[qml(invokable)]
    fn selected_text(cx: &Cx) -> String {
        vt_mut(cx.engine, cx.this, |vt, _| vt.session.selected_text())
            .flatten()
            .unwrap_or_default()
    }

    /// Scrollback and screen as plain text, soft wraps joined.
    #[qml(invokable)]
    fn text(cx: &Cx) -> String {
        vt_mut(cx.engine, cx.this, |vt, _| vt.session.text()).unwrap_or_default()
    }

    /// Scrolls the view by `delta` rows; negative goes back into history.
    #[qml(invokable)]
    fn scroll_lines(cx: &Cx, delta: i32) {
        scroll(cx.engine, cx.this, Scroll::Lines(delta as isize));
    }

    /// Puts row `offset` (of `scrollTotal`) at the top of the view.
    #[qml(invokable)]
    fn scroll_to(cx: &Cx, offset: f64) {
        let top = if offset.is_finite() {
            offset.round().max(0.0) as usize
        } else {
            0
        };
        scroll(cx.engine, cx.this, Scroll::Row(top));
    }

    #[qml(invokable)]
    fn scroll_to_bottom(cx: &Cx) {
        scroll(cx.engine, cx.this, Scroll::Bottom);
    }
}

// The session and the properties that mirror it.

/// Runs `f` on the terminal, making it first if need be. None when `me` is
/// not a terminal or the terminal could not be made. `f` must not call back
/// into the engine.
fn vt_mut<R>(e: &Engine, me: ObjectId, f: impl FnOnce(&Vt, &mut State) -> R) -> Option<R> {
    let mut failed = false;
    let out = e
        .with_mut::<Terminal, _>(me, |t| {
            if t.state.vt.is_none() && !t.error.is_empty() {
                return None;
            }
            if t.state.vt.is_none() {
                let (w, h) = t.state.cell_px;
                let size = Size::new(
                    t.columns.clamp(1, 1000) as u16,
                    t.rows.clamp(1, 1000) as u16,
                )
                .with_cell(w.max(1), h.max(1));
                let limit = t.scrollback_limit.max(0) as usize;
                t.state.vt = Vt::new(size, limit, t.state.theme.clone());
                failed = t.state.vt.is_none();
            }
            let vt = t.state.vt.take()?;
            let out = f(&vt, &mut t.state);
            t.state.vt = Some(vt);
            Some(out)
        })
        .ok()
        .flatten();
    if failed {
        fail(e, me, "Could not create a terminal");
    }
    out
}

/// Gives up on the terminal engine of `me`, saying `why` in its `error`:
/// it stops drawing and taking input until a new Terminal replaces it.
pub fn fail(e: &Engine, me: ObjectId, why: &str) {
    let _ = e.with_mut::<Terminal, _>(me, |t| t.state.vt = None);
    put(e, me, Terminal::ERROR, Atom::from(why));
}

/// Sets a readonly property, notifying only when it changes.
fn put<T: PartialEq + QmlValue>(e: &Engine, me: ObjectId, p: Prop<T>, v: T) {
    if e.get(me, p).ok().as_ref() != Some(&v) {
        let _ = e.set_internal(me, p, v);
    }
}

/// Carries out what the terminal did since the last time: sends what it
/// has for the program, brings the title, the scroll and the selection's
/// properties in line, rings the bell, and paints the cells again.
fn flush(e: &Engine, me: ObjectId) {
    let Some((input, changes, title, pwd, bar, selected, tracking)) = vt_mut(e, me, |vt, _| {
        let changes = vt.session.take_changes();
        (
            vt.pending.take(),
            changes,
            changes
                .contains(hof_vt::Changes::TITLE)
                .then(|| vt.session.title()),
            changes
                .contains(hof_vt::Changes::PWD)
                .then(|| vt.session.pwd()),
            vt.session.scrollbar(),
            vt.session.has_selection(),
            vt.session.mouse_tracking(),
        )
    }) else {
        return;
    };
    e.batch(|| {
        if let Some(title) = title {
            put(e, me, Terminal::TITLE, Atom::from(title.as_str()));
        }
        if let Some(pwd) = pwd {
            put(e, me, Terminal::WORKING_DIRECTORY, Atom::from(pwd.as_str()));
        }
        if bar.total > 0 {
            put(e, me, Terminal::SCROLL_TOTAL, bar.total as f64);
            put(e, me, Terminal::SCROLL_OFFSET, bar.offset as f64);
            put(e, me, Terminal::AT_BOTTOM, bar.at_bottom());
        }
        put(e, me, Terminal::HAS_SELECTION, selected);
        put(e, me, Terminal::MOUSE_TRACKING, tracking);
    });
    item::repaint(e, me);
    if !input.is_empty() {
        let text = String::from_utf8_lossy(&input);
        let _ = e.emit_by_name(me, "input", &[Value::String(Atom::from(&*text))]);
    }
    if changes.contains(hof_vt::Changes::BELL) {
        let _ = e.emit_by_name(me, "bell", &[]);
    }
}

fn bytes_of(data: &Value) -> Vec<u8> {
    match data {
        Value::String(s) => s.as_str().as_bytes().to_vec(),
        Value::List(items) => items.iter().map(|v| v.to_number() as u8).collect(),
        _ => Vec::new(),
    }
}

/// Gives the terminal program output; its answers go to the program only
/// when `answer`.
fn feed(e: &Engine, me: ObjectId, bytes: &[u8], answer: bool) {
    if bytes.is_empty() {
        return;
    }
    vt_mut(e, me, |vt, _| {
        vt.session.feed(bytes);
        if !answer {
            vt.pending.take();
        }
    });
    flush(e, me);
}

/// Has the terminal take something the user did, `f`, and brings the view
/// back to the prompt if it sent the program anything.
fn user<R>(e: &Engine, me: ObjectId, f: impl FnOnce(&Vt) -> R) -> Option<R> {
    let out = vt_mut(e, me, |vt, _| {
        let out = f(vt);
        if !vt
            .pending
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .is_empty()
            && !vt.session.scrollbar().at_bottom()
        {
            vt.session.scroll(Scroll::Bottom);
        }
        out
    });
    flush(e, me);
    out
}

fn paste_text(e: &Engine, me: ObjectId, text: &str) {
    if !text.is_empty() {
        // Pasting is asked for (a menu, a key), so a newline is meant.
        user(e, me, |vt| vt.session.paste(text, true));
    }
}

/// Puts the selected text on the clipboard `mode`.
fn copy_to(e: &Engine, me: ObjectId, mode: ClipboardMode) -> bool {
    let text = vt_mut(e, me, |vt, _| vt.session.selected_text())
        .flatten()
        .unwrap_or_default();
    !text.is_empty() && Platform::of(e).clipboard().set_text(mode, &text).is_ok()
}

fn scroll(e: &Engine, me: ObjectId, to: Scroll) {
    if to != Scroll::Lines(0) {
        vt_mut(e, me, |vt, _| vt.session.scroll(to));
        flush(e, me);
    }
}

/// The colours the properties give the terminal: the sixteen of
/// [`paint::ANSI`] and on with `ansiColors`. Tracked.
fn theme(e: &Engine, me: ObjectId) -> Theme {
    let rgb = |c: Color| {
        let [r, g, b, _] = c.to_rgba_f();
        let byte = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
        Rgb::new(byte(r), byte(g), byte(b))
    };
    let mut palette: Vec<(u8, Rgb)> = (0u8..).zip(paint::ANSI).collect();
    if let Value::List(items) = e.read(me, Terminal::ANSI_COLORS.index) {
        for (slot, v) in (0u8..=255).zip(items.iter()) {
            if let Value::Color(c) = v {
                match palette.get_mut(usize::from(slot)) {
                    Some(entry) => entry.1 = rgb(*c),
                    None => palette.push((slot, rgb(*c))),
                }
            }
        }
    }
    let cursor = item::prop(e, me, Terminal::CURSOR_COLOR);
    Theme {
        foreground: Some(rgb(item::prop(e, me, Terminal::FOREGROUND_COLOR))),
        background: Some(rgb(item::prop(e, me, Terminal::BACKGROUND_COLOR))),
        cursor: cursor.is_valid().then(|| rgb(cursor)),
        palette,
    }
}

// The grid follows the item.

/// The `font` as a `Text` lays it out. Tracked: it follows the font and the
/// system's text size.
fn font_style(e: &Engine, me: ObjectId) -> TextStyle {
    item::text_style(e, &item::prop(e, me, Terminal::FONT))
}

/// Sizes the grid to the item: as many whole cells as fit inside the
/// padding. A grid with nothing to show on, an item of no size, keeps its
/// last size.
fn relayout(e: &Engine, me: ObjectId, (w, h): (f64, f64), style: &TextStyle, padding: f64) {
    let Some((cw, ch)) = item::with_text_engine(|te| paint::cell_size(te, style)) else {
        return;
    };
    put(e, me, Terminal::CELL_WIDTH, cw);
    put(e, me, Terminal::CELL_HEIGHT, ch);
    let dpr = item::device_pixel_ratio(e, me).max(0.1);
    let px = |v: f64| ((v * dpr).round() as u32).max(1);
    let cell_px = (px(cw), px(ch));
    let _ = e.with_mut::<Terminal, _>(me, |t| t.state.cell_px = cell_px);
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
    e.batch(|| {
        put(e, me, Terminal::ROWS, i32::from(rows));
        put(e, me, Terminal::COLUMNS, i32::from(cols));
    });
    vt_mut(e, me, |vt, _| {
        let _ = vt
            .session
            .resize(Size::new(cols, rows).with_cell(cell_px.0, cell_px.1));
    });
    flush(e, me);
    if was || first {
        let _ = e.emit_by_name(
            me,
            "resized",
            &[Value::Int(i32::from(cols)), Value::Int(i32::from(rows))],
        );
    }
}

// Painting.

/// The colours the properties say.
fn look(e: &Engine, me: ObjectId, style: TextStyle, cell: (f64, f64)) -> Look {
    let color = |p: Prop<Color>| -> paint::Color {
        let [r, g, b, a] = item::prop(e, me, p).to_rgba_f();
        [r as f32, g as f32, b as f32, a as f32]
    };
    let optional = |p: Prop<Color>| item::prop(e, me, p).is_valid().then(|| color(p));
    Look {
        foreground: color(Terminal::FOREGROUND_COLOR),
        background: color(Terminal::BACKGROUND_COLOR),
        cursor: optional(Terminal::CURSOR_COLOR),
        selection: optional(Terminal::SELECTION_COLOR),
        padding: item::prop(e, me, Terminal::PADDING),
        style,
        cell,
        focused: item::prop(e, me, Item::ACTIVE_FOCUS),
        blink_off: false,
    }
}

#[derive(Debug)]
struct Screen(Painted);

impl ItemPaint for Screen {
    fn paint(&self, size: kurbo::Size, _: &mut TextEngine, out: &mut DisplayListBuilder) {
        self.0.paint(size, out);
    }
}

/// Read tracked: the colours, the font, the system's text size and the
/// focus repaint the item; [`flush`] repaints it when the cells change.
fn read_paint(e: &Engine, me: ObjectId) -> Rc<dyn ItemPaint> {
    let style = font_style(e, me);
    let cell = item::with_text_engine(|te| paint::cell_size(te, &style)).unwrap_or((0.0, 0.0));
    let mut look = look(e, me, style, cell);
    let background = look.background;
    let may_blink = look.focused && item::prop(e, me, Terminal::CURSOR_BLINK);
    // The engine's store is borrowed in `vt_mut`, and the text engine must
    // be free for anything that reads properties: lay out last.
    let painted = e
        .with_mut::<Terminal, _>(me, |t| {
            let state = &mut t.state;
            let vt = state.vt.as_mut()?;
            vt.grid.update(&vt.session).ok()?;
            let blinking = may_blink && vt.grid.cursor.blinking;
            if !blinking {
                state.blink_off = false;
            }
            look.blink_off = state.blink_off;
            let timer = (blinking && state.blink_due.is_none()).then(|| {
                state.blink_generation += 1;
                state.blink_due = Some(state.blink_generation);
                state.blink_generation
            });
            let preedit = &state.preedit;
            let painted = item::with_text_engine(|te| {
                let mut painted = paint::build(&vt.grid, &look, te);
                paint::compose(&mut painted, &vt.grid, &look, te, preedit);
                painted
            })?;
            Some((painted, timer))
        })
        .ok()
        .flatten()
        .map(|(painted, timer)| {
            if let Some(generation) = timer {
                blink_later(e, me, generation);
            }
            painted
        });
    Rc::new(Screen(painted.unwrap_or_else(|| Painted {
        background,
        ..Default::default()
    })))
}

/// The cursor flash time `Qt.styleHints` gives, in milliseconds: a whole
/// blink, on and off.
pub fn cursor_flash_ms(e: &Engine) -> u64 {
    let flash = ljos::style_hints(e).map_or(0, |hints| {
        item::prop(e, hints, ljos::prelude::StyleHints::CURSOR_FLASH_TIME)
    });
    u64::try_from(flash).unwrap_or(0).max(200)
}

/// Flips the cursor's blink in half the cursor flash time, if
/// timer `generation` is still the one due then. Painting again schedules
/// the next half while the cursor may still blink.
fn blink_later(e: &Engine, me: ObjectId, generation: u64) {
    let half = cursor_flash_ms(e) / 2;
    e.call_at(e.now() + Duration::from_millis(half), move |e| {
        let flipped = e
            .with_mut::<Terminal, _>(me, |t| {
                let state = &mut t.state;
                if state.blink_due != Some(generation) {
                    return false;
                }
                state.blink_due = None;
                state.blink_off = !state.blink_off;
                true
            })
            .unwrap_or(false);
        if flipped {
            item::repaint(e, me);
        }
    });
}

// Keys.

fn key_press(e: &Engine, me: ObjectId, ev: &KeyEvent) -> bool {
    // Shift+PageUp and Shift+PageDown page through history, as in xterm.
    if ev.modifiers == Modifiers::SHIFT && (ev.key == key::PAGE_UP || ev.key == key::PAGE_DOWN) {
        let page = (item::prop(e, me, Terminal::ROWS) as isize - 1).max(1);
        scroll(
            e,
            me,
            Scroll::Lines(if ev.key == key::PAGE_UP { -page } else { page }),
        );
        return true;
    }
    // The usual terminal chords, as qml-ghostty's item has them:
    // Ctrl+Shift+C copies, Ctrl+Shift+V and Shift+Insert paste.
    const C: i32 = key::A + 2;
    const V: i32 = key::A + 21;
    let ctrl_shift = Modifiers::CONTROL | Modifiers::SHIFT;
    if ev.modifiers == ctrl_shift && ev.key == C {
        copy_to(e, me, ClipboardMode::Clipboard);
        return true;
    }
    if (ev.modifiers == ctrl_shift && ev.key == V)
        || (ev.modifiers == Modifiers::SHIFT && ev.key == key::INSERT)
    {
        if let Some(text) = Platform::of(e).clipboard().text(ClipboardMode::Clipboard) {
            paste_text(e, me, &text);
        }
        return true;
    }
    let mac = item::prop(e, me, Terminal::MAC_MODIFIERS);
    let Some(input) = keys::translate(ev, mac) else {
        return false;
    };
    user(e, me, |vt| {
        let taken = vt.session.key(&input).unwrap_or(false);
        if taken {
            vt.session.clear_selection();
        }
        taken
    })
    .unwrap_or(false)
}

// The input method: committed text is typed.

struct Ime;

impl TextInputClient for Ime {
    fn surrounding(&self, _: &Engine, _: ObjectId) -> Surrounding {
        Surrounding::default()
    }

    fn replace(&self, e: &Engine, item: ObjectId, _: std::ops::Range<usize>, text: &str) {
        user(e, item, |vt| vt.session.write(text.as_bytes()));
    }

    /// Kept to be drawn at the cursor; none of it reaches the program until
    /// it is committed.
    fn set_preedit(&self, e: &Engine, item: ObjectId, text: &str, _: Option<usize>) -> bool {
        let changed = e
            .with_mut::<Terminal, _>(item, |t| {
                let changed = t.state.preedit != text;
                text.clone_into(&mut t.state.preedit);
                changed
            })
            .unwrap_or(false);
        if changed {
            item::repaint(e, item);
        }
        true
    }

    /// Ends what was being composed and types `text`.
    fn commit(&self, e: &Engine, item: ObjectId, text: &str) -> bool {
        self.set_preedit(e, item, "", None);
        if !text.is_empty() {
            user(e, item, |vt| vt.session.write(text.as_bytes()));
        }
        true
    }

    fn preedit(&self, e: &Engine, item: ObjectId) -> String {
        e.with::<Terminal, _>(item, |t| t.state.preedit.clone())
            .unwrap_or_default()
    }

    fn set_selection(&self, _: &Engine, _: ObjectId, _: usize, _: usize) {}

    fn cursor_rect(&self, e: &Engine, item: ObjectId) -> kurbo::Rect {
        let (cw, ch, pad) = metrics(e, item);
        let (col, row) = e
            .with::<Terminal, _>(item, |t| {
                t.state.vt.as_ref().and_then(|vt| vt.grid.cursor.at)
            })
            .ok()
            .flatten()
            .unwrap_or((0, 0));
        let (x, y) = (pad + f64::from(col) * cw, pad + f64::from(row) * ch);
        kurbo::Rect::new(x, y, x + cw, y + ch)
    }

    /// No prediction, no autocorrection, no capitals: a terminal wants the
    /// keys as they were typed.
    fn hints(&self, _: &Engine, _: ObjectId) -> i32 {
        0x2 | 0x40 | 0x200
    }
}

/// Takes the size of the Loader that loaded the terminal when the Loader
/// has a size of its own, as Qt's Loader gives it. Ljós's Loader does not
/// when that size comes from a `Binding on width` (TerminalSplits' cells),
/// and the terminal stayed 0x0 (hal-c2/ljos-ui#236). A Loader that follows
/// its item has the item's size as its implicit size, so nothing is
/// written then.
fn follow_loader(e: &Engine, me: ObjectId) {
    let Some(parent) = e.read(me, Item::PARENT.index).as_object() else {
        return;
    };
    let is_loader = e
        .lookup_type("QtQuick", "Loader")
        .is_some_and(|loader| e.inherits(parent, &loader));
    if !is_loader || e.read_by_name(parent, "item").as_object() != Some(me) {
        return;
    }
    let axes = [
        (Item::WIDTH.index, Item::IMPLICIT_WIDTH.index),
        (Item::HEIGHT.index, Item::IMPLICIT_HEIGHT.index),
    ];
    for (size, implicit) in axes {
        let own = e.read(parent, size).to_number();
        let follows = own == e.read(parent, implicit).to_number();
        if !follows && e.untrack(|| e.read(me, size).to_number()) != own {
            let _ = e.write_internal(me, size, own.into(), item::WriteKind::Imperative);
        }
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
/// the grid, as `(column, row)` of the view.
fn cell_at(e: &Engine, me: ObjectId, at: kurbo::Point) -> (u16, u16) {
    let (cw, ch, pad) = metrics(e, me);
    let (cols, rows) = e
        .with::<Terminal, _>(me, |t| (t.columns.max(1), t.rows.max(1)))
        .unwrap_or((1, 1));
    let col = ((at.x - pad) / cw).floor().clamp(0.0, f64::from(cols - 1)) as u16;
    let row = ((at.y - pad) / ch).floor().clamp(0.0, f64::from(rows - 1)) as u16;
    (col, row)
}

/// Reports the pointer at `cell` to a program that tracks it. The encoder
/// counts cells in the session's device pixels: a report names the middle
/// of the cell the item found, so the two agree.
fn report(
    e: &Engine,
    me: ObjectId,
    action: MouseAction,
    button: Option<MouseButton>,
    mods: Modifiers,
    (col, row): (u16, u16),
) -> bool {
    let mods = keys::mods(mods, item::prop(e, me, Terminal::MAC_MODIFIERS));
    let sent = vt_mut(e, me, |vt, state| {
        let (w, h) = state.cell_px;
        let input = MouseInput {
            action,
            button,
            mods,
            x: ((f64::from(col) + 0.5) * f64::from(w.max(1))) as f32,
            y: ((f64::from(row) + 0.5) * f64::from(h.max(1))) as f32,
        };
        vt.session.mouse(&input).unwrap_or(false)
    })
    .unwrap_or(false);
    flush(e, me);
    sent
}

/// Whether the program gets the pointer rather than the selection: Shift,
/// Ctrl or Cmd held always selects, so text can be copied from a program
/// that tracks (desktop-qt's).
fn reports(e: &Engine, me: ObjectId, mods: Modifiers) -> bool {
    !mods.intersects(Modifiers::SHIFT | Modifiers::CONTROL | Modifiers::META)
        && vt_mut(e, me, |vt, _| vt.session.mouse_tracking()).unwrap_or(false)
}

fn button_of(b: MouseButtons) -> Option<MouseButton> {
    Some(match b {
        MouseButtons::LEFT => MouseButton::Left,
        MouseButtons::MIDDLE => MouseButton::Middle,
        MouseButtons::RIGHT => MouseButton::Right,
        MouseButtons::BACK => MouseButton::Back,
        MouseButtons::FORWARD => MouseButton::Forward,
        _ => return None,
    })
}

fn pointer_press(e: &Engine, me: ObjectId, ev: &PointerEvent, at: kurbo::Point) -> bool {
    force_active_focus(e, me, FocusReason::Mouse);
    let Some(b) = ev.button.and_then(button_of) else {
        return false;
    };
    let cell = cell_at(e, me, at);
    if reports(e, me, ev.modifiers)
        && report(e, me, MouseAction::Press, Some(b), ev.modifiers, cell)
    {
        let _ = e.with_mut::<Terminal, _>(me, |t| t.state.reported = Some(b));
        return true;
    }
    match b {
        MouseButton::Left => {
            let shift = ev.modifiers.contains(Modifiers::SHIFT);
            let alt = ev.modifiers.contains(Modifiers::ALT);
            vt_mut(e, me, |vt, state| {
                let again = state.last_click.is_some_and(|(t, was)| {
                    was == cell && ev.time.saturating_since(t) <= MULTI_CLICK
                });
                state.clicks = if again { state.clicks % 3 + 1 } else { 1 };
                state.last_click = Some((ev.time, cell));
                state.selecting = Some(cell);
                let unit = match state.clicks {
                    2 => Selecting::Words,
                    3 => Selecting::Lines,
                    _ if alt => Selecting::Block,
                    _ => Selecting::Cells,
                };
                if shift && unit == Selecting::Cells && vt.session.has_selection() {
                    let _ = vt.session.select_extend(cell.0, cell.1);
                } else {
                    vt.session.clear_selection();
                    let _ = vt.session.select_start(cell.0, cell.1, unit);
                }
            });
            flush(e, me);
            true
        }
        // Middle-click pastes the primary selection, as X11 does.
        MouseButton::Middle => {
            if let Some(text) = Platform::of(e).clipboard().text(ClipboardMode::Selection) {
                paste_text(e, me, &text);
            }
            true
        }
        // Right-click is for the bricks' menu.
        _ => false,
    }
}

fn pointer_moved(e: &Engine, me: ObjectId, ev: &PointerEvent, at: kurbo::Point) {
    let cell = cell_at(e, me, at);
    let Ok((selecting, reported)) =
        e.with::<Terminal, _>(me, |t| (t.state.selecting, t.state.reported))
    else {
        return;
    };
    if let Some(b) = reported {
        report(e, me, MouseAction::Motion, Some(b), ev.modifiers, cell);
    } else if let Some(from) = selecting {
        vt_mut(e, me, |vt, _| {
            // A press that has not left its cell selects nothing.
            if cell != from || vt.session.has_selection() {
                let _ = vt.session.select_extend(cell.0, cell.1);
            }
        });
        flush(e, me);
        hold_at_edge(e, me, at);
    }
}

/// Starts or stops scrolling the history under a selecting drag, as the
/// pointer goes past an edge of the grid or comes back.
fn hold_at_edge(e: &Engine, me: ObjectId, at: kurbo::Point) {
    let (_, _, pad) = metrics(e, me);
    let height = e.read(me, Item::HEIGHT.index).to_number();
    let edge = if at.y < pad {
        -1
    } else if at.y > height - pad {
        1
    } else {
        0
    };
    let start = e
        .with_mut::<Terminal, _>(me, |t| {
            let state = &mut t.state;
            state.drag_at = at;
            if state.edge == edge {
                return None;
            }
            state.edge = edge;
            state.edge_generation += 1;
            (edge != 0).then_some(state.edge_generation)
        })
        .ok()
        .flatten();
    if let Some(generation) = start {
        edge_later(e, me, generation);
    }
}

/// Scrolls a row toward the held edge and extends the selection there,
/// while timer `generation` is still the one due.
fn edge_later(e: &Engine, me: ObjectId, generation: u64) {
    const EVERY: Duration = Duration::from_millis(50);
    e.call_at(e.now() + EVERY, move |e| {
        let held = e
            .with::<Terminal, _>(me, |t| {
                let state = &t.state;
                (state.edge_generation == generation && state.selecting.is_some())
                    .then_some((state.edge, state.drag_at))
            })
            .ok()
            .flatten();
        let Some((edge, at)) = held else {
            return;
        };
        scroll(e, me, Scroll::Lines(edge as isize));
        let cell = cell_at(e, me, at);
        vt_mut(e, me, |vt, _| {
            let _ = vt.session.select_extend(cell.0, cell.1);
        });
        flush(e, me);
        edge_later(e, me, generation);
    });
}

/// The pointer moved over the item with no button down: a program that asked
/// for any motion hears of each new cell; the encoder drops it for one that
/// didn't.
fn hover_moved(e: &Engine, me: ObjectId, at: kurbo::Point) {
    let cell = cell_at(e, me, at);
    let Ok(idle) = e.with_mut::<Terminal, _>(me, |t| {
        let idle = t.state.selecting.is_none() && t.state.reported.is_none();
        idle && t.state.hovered.replace(cell) != Some(cell)
    }) else {
        return;
    };
    if idle && reports(e, me, Modifiers::empty()) {
        report(e, me, MouseAction::Motion, None, Modifiers::empty(), cell);
    }
}

fn pointer_release(e: &Engine, me: ObjectId, ev: &PointerEvent, at: kurbo::Point) {
    let Ok((reported, selecting)) = e.with_mut::<Terminal, _>(me, |t| {
        t.state.edge = 0;
        t.state.edge_generation += 1;
        (t.state.reported.take(), t.state.selecting.take())
    }) else {
        return;
    };
    if let Some(b) = reported {
        report(
            e,
            me,
            MouseAction::Release,
            Some(b),
            ev.modifiers,
            cell_at(e, me, at),
        );
    } else if selecting.is_some() {
        // What is selected is the primary selection, as on X11.
        copy_to(e, me, ClipboardMode::Selection);
    }
}

fn pointer_cancel(e: &Engine, me: ObjectId) {
    let _ = e.with_mut::<Terminal, _>(me, |t| {
        t.state.selecting = None;
        t.state.reported = None;
        t.state.edge = 0;
        t.state.edge_generation += 1;
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
        steps as isize
    }) else {
        return false;
    };
    if steps == 0 {
        return true;
    }
    if reports(e, me, ev.modifiers) {
        // Steps are presses of the wheel's buttons.
        let b = if steps < 0 {
            MouseButton::WheelUp
        } else {
            MouseButton::WheelDown
        };
        let cell = cell_at(e, me, at);
        for _ in 0..steps.unsigned_abs().min(10) {
            report(e, me, MouseAction::Press, Some(b), ev.modifiers, cell);
        }
        return true;
    }
    let Some((alternate, app)) = vt_mut(e, me, |vt, _| (vt.alternate(), vt.application_cursor()))
    else {
        return false;
    };
    if alternate {
        // Full-screen programs without mouse support (less, man) see arrows.
        let arrow: &[u8] = match (steps < 0, app) {
            (true, true) => b"\x1bOA",
            (false, true) => b"\x1bOB",
            (true, false) => b"\x1b[A",
            (false, false) => b"\x1b[B",
        };
        let n = steps.unsigned_abs().min(100);
        vt_mut(e, me, |vt, _| vt.session.write(&arrow.repeat(n)));
        flush(e, me);
    } else {
        scroll(e, me, Scroll::Lines(steps));
    }
    true
}
