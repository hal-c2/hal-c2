//! The terminal's state: a grid of cells fed with a program's output, the
//! history that scrolled off it, a viewport into both, and a selection.
//!
//! The VT parsing is the `vt100` crate (see the module doc of
//! [`super`] for why not libghostty-vt). This wrapper adds what the item
//! needs and the crate does not give: replies to the queries a program asks
//! (and silence while history is replayed), the title and working
//! directory, the bell, the kitty keyboard flags a program sets, and rows addressed from the oldest line of history,
//! which is how a selection stays put while the viewport scrolls.

use vt100::{Callbacks, Parser, Screen};

/// What the parser's callbacks gather while bytes are processed.
#[derive(Default)]
struct Hook {
    /// Answer device queries (a program is on the other end) or not (the
    /// bytes are a replayed transcript of one that is gone).
    answer: bool,
    replies: Vec<u8>,
    title: Option<String>,
    cwd: Option<String>,
    bells: u32,
    /// The kitty keyboard protocol's stack of flags, for the main screen
    /// and the alternate one.
    kitty: [Vec<u8>; 2],
}

/// How many entries a kitty flags stack keeps; a push past it drops the
/// oldest, as the protocol allows.
const KITTY_STACK: usize = 16;

impl Hook {
    /// `CSI > f u` pushes, `CSI < n u` pops, `CSI = f ; m u` sets (1),
    /// adds (2) or removes (3) bits of the current flags, and `CSI ? u`
    /// asks for them.
    fn kitty_keyboard(&mut self, screen: &Screen, mark: u8, params: &[&[u16]]) {
        let param = |i: usize| params.get(i).and_then(|p| p.first()).copied();
        let stack = &mut self.kitty[usize::from(screen.alternate_screen())];
        let current = stack.last().copied().unwrap_or(0);
        match mark {
            b'>' => {
                if stack.len() == KITTY_STACK {
                    stack.remove(0);
                }
                stack.push(param(0).unwrap_or(0) as u8 & 0x1f);
            }
            b'<' => {
                let n = usize::from(param(0).unwrap_or(1).max(1));
                stack.truncate(stack.len().saturating_sub(n));
            }
            b'=' => {
                let flags = param(0).unwrap_or(0) as u8 & 0x1f;
                let next = match param(1).unwrap_or(1) {
                    2 => current | flags,
                    3 => current & !flags,
                    _ => flags,
                };
                match stack.last_mut() {
                    Some(top) => *top = next,
                    None => stack.push(next),
                }
            }
            b'?' if self.answer => {
                self.replies
                    .extend_from_slice(format!("\x1b[?{current}u").as_bytes());
            }
            _ => {}
        }
    }
}

impl Callbacks for Hook {
    fn audible_bell(&mut self, _: &mut Screen) {
        self.bells += 1;
    }

    fn visual_bell(&mut self, _: &mut Screen) {
        self.bells += 1;
    }

    fn set_window_title(&mut self, _: &mut Screen, title: &[u8]) {
        self.title = Some(String::from_utf8_lossy(title).into_owned());
    }

    /// OSC 7: the shell says where it is, as a `file://` URI.
    fn unhandled_osc(&mut self, _: &mut Screen, params: &[&[u8]]) {
        if let [b"7", uri, ..] = params {
            self.cwd = Some(String::from_utf8_lossy(uri).into_owned());
        }
    }

    /// The queries programs ask a terminal: device status, cursor position
    /// and device attributes.
    fn unhandled_csi(
        &mut self,
        screen: &mut Screen,
        i1: Option<u8>,
        _i2: Option<u8>,
        params: &[&[u16]],
        c: char,
    ) {
        if c == 'u'
            && let Some(mark @ (b'>' | b'<' | b'=' | b'?')) = i1
        {
            self.kitty_keyboard(screen, mark, params);
            return;
        }
        if !self.answer {
            return;
        }
        let first = params.first().and_then(|p| p.first()).copied().unwrap_or(0);
        let reply = match (i1, c, first) {
            (None, 'n', 5) => "\x1b[0n".to_string(),
            (None, 'n', 6) => {
                let (row, col) = screen.cursor_position();
                format!("\x1b[{};{}R", row + 1, col + 1)
            }
            (Some(b'?'), 'n', 6) => {
                let (row, col) = screen.cursor_position();
                format!("\x1b[?{};{}R", row + 1, col + 1)
            }
            (None, 'c', 0) => "\x1b[?62;22c".to_string(),
            (Some(b'>'), 'c', 0) => "\x1b[>1;10;0c".to_string(),
            _ => return,
        };
        self.replies.extend_from_slice(reply.as_bytes());
    }
}

/// What came of feeding bytes.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Fed {
    /// Answers to the program's queries, to send back to it.
    pub replies: Vec<u8>,
    pub bells: u32,
    /// The new title, if the bytes changed it.
    pub title: Option<String>,
    /// The new working directory, if the bytes changed it.
    pub cwd: Option<String>,
}

/// A cell of the whole text, counted from the oldest line of history.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Pos {
    pub row: usize,
    pub col: u16,
}

pub struct Vt {
    parser: Parser<Hook>,
    limit: usize,
    /// Lines of history; kept here because finding it moves the viewport.
    history: usize,
    selection: Option<(Pos, Pos)>,
}

impl Vt {
    pub fn new(rows: u16, cols: u16, limit: usize) -> Vt {
        let mut vt = Vt {
            parser: Parser::new_with_callbacks(rows, cols, limit, Hook::default()),
            limit,
            history: 0,
            selection: None,
        };
        vt.refresh();
        vt
    }

    /// Takes bytes of a program's output. `answer` says whether its queries
    /// are replied to.
    pub fn feed(&mut self, bytes: &[u8], answer: bool) -> Fed {
        self.parser.callbacks_mut().answer = answer;
        self.parser.process(bytes);
        self.refresh();
        let hook = self.parser.callbacks_mut();
        Fed {
            replies: std::mem::take(&mut hook.replies),
            bells: std::mem::take(&mut hook.bells),
            title: hook.title.take(),
            cwd: hook.cwd.take(),
        }
    }

    /// A blank screen and no history, in the same size.
    pub fn reset(&mut self) {
        let (rows, cols) = self.size();
        *self = Vt::new(rows, cols, self.limit);
    }

    pub fn resize(&mut self, rows: u16, cols: u16) {
        if (rows, cols) == self.size() {
            return;
        }
        self.selection = None;
        self.parser.screen_mut().set_size(rows, cols);
        self.refresh();
    }

    /// `(rows, columns)`.
    pub fn size(&self) -> (u16, u16) {
        self.parser.screen().size()
    }

    fn screen(&self) -> &Screen {
        self.parser.screen()
    }

    fn refresh(&mut self) {
        let screen = self.parser.screen_mut();
        let offset = screen.scrollback();
        screen.set_scrollback(usize::MAX);
        self.history = screen.scrollback();
        screen.set_scrollback(offset);
    }

    // The viewport.

    /// Rows of history and screen together.
    pub fn total(&self) -> usize {
        self.history + usize::from(self.size().0)
    }

    /// The first row in view, counted from the oldest line.
    pub fn top(&self) -> usize {
        self.history - self.screen().scrollback().min(self.history)
    }

    pub fn at_bottom(&self) -> bool {
        self.screen().scrollback() == 0
    }

    /// Moves the view by `delta` rows; positive goes towards the newest.
    pub fn scroll_by(&mut self, delta: i64) {
        let now = self.screen().scrollback() as i64;
        let offset = (now - delta).clamp(0, self.history as i64) as usize;
        self.parser.screen_mut().set_scrollback(offset);
    }

    /// Puts row `top` (counted from the oldest line) first in view.
    pub fn scroll_to(&mut self, top: usize) {
        let offset = self.history - top.min(self.history);
        self.parser.screen_mut().set_scrollback(offset);
    }

    pub fn scroll_to_bottom(&mut self) {
        self.parser.screen_mut().set_scrollback(0);
    }

    // The modes a program set.

    pub fn bracketed_paste(&self) -> bool {
        self.screen().bracketed_paste()
    }

    pub fn application_cursor(&self) -> bool {
        self.screen().application_cursor()
    }

    pub fn alternate_screen(&self) -> bool {
        self.screen().alternate_screen()
    }

    /// The kitty keyboard protocol's flags the program on this screen set.
    pub fn kitty_keyboard(&self) -> u8 {
        let screen = usize::from(self.screen().alternate_screen());
        self.parser.callbacks().kitty[screen]
            .last()
            .copied()
            .unwrap_or(0)
    }

    /// Whether the program asked for mouse reports.
    pub fn mouse_tracking(&self) -> bool {
        self.screen().mouse_protocol_mode() != vt100::MouseProtocolMode::None
    }

    /// Whether the program wants the mouse moved with a button held.
    pub fn mouse_drag(&self) -> bool {
        matches!(
            self.screen().mouse_protocol_mode(),
            vt100::MouseProtocolMode::ButtonMotion | vt100::MouseProtocolMode::AnyMotion
        )
    }

    /// Whether the program wants every move, with no button held too.
    pub fn mouse_any_motion(&self) -> bool {
        self.screen().mouse_protocol_mode() == vt100::MouseProtocolMode::AnyMotion
    }

    pub fn mouse_encoding(&self) -> super::keys::MouseEncoding {
        use super::keys::MouseEncoding as E;
        match self.screen().mouse_protocol_encoding() {
            vt100::MouseProtocolEncoding::Default => E::Default,
            vt100::MouseProtocolEncoding::Utf8 => E::Utf8,
            vt100::MouseProtocolEncoding::Sgr => E::Sgr,
        }
    }

    // What is in view.

    pub fn cell(&self, row: u16, col: u16) -> Option<&vt100::Cell> {
        self.screen().cell(row, col)
    }

    /// Where the cursor is on screen, when it is shown: not hidden by the
    /// program and not scrolled out of view.
    pub fn cursor(&self) -> Option<(u16, u16)> {
        let s = self.screen();
        (!s.hide_cursor() && s.scrollback() == 0).then(|| s.cursor_position())
    }

    // Selection.

    pub fn has_selection(&self) -> bool {
        self.selection.is_some()
    }

    pub fn select(&mut self, anchor: Pos, head: Pos) {
        self.selection = Some((anchor, head));
    }

    /// Everything up to the last line with something on it.
    pub fn select_all(&mut self) {
        let (_, cols) = self.size();
        let last = cols.saturating_sub(1);
        let mut row = self.total().saturating_sub(1);
        while row > 0 && self.read_row(row, 0, last).0.trim().is_empty() {
            row -= 1;
        }
        let end = Pos { row, col: last };
        self.selection = Some((Pos { row: 0, col: 0 }, end));
    }

    pub fn clear_selection(&mut self) {
        self.selection = None;
    }

    /// The selection from its first cell to its last, both inside it.
    pub fn selection(&self) -> Option<(Pos, Pos)> {
        self.selection
            .map(|(a, b)| if a <= b { (a, b) } else { (b, a) })
    }

    pub fn is_selected(&self, row: usize, col: u16) -> bool {
        self.selection()
            .is_some_and(|(a, b)| a <= Pos { row, col } && Pos { row, col } <= b)
    }

    /// The selected text; soft-wrapped lines joined, trailing blanks cut.
    pub fn selected_text(&mut self) -> String {
        let Some((start, end)) = self.selection() else {
            return String::new();
        };
        let (_, cols) = self.size();
        let last = end.row.min(self.total().saturating_sub(1));
        let mut out = String::new();
        for row in start.row..=last {
            let from = if row == start.row { start.col } else { 0 };
            let to = if row == end.row {
                end.col
            } else {
                cols.saturating_sub(1)
            };
            let (text, wrapped) = self.read_row(row, from, to);
            if wrapped && row != end.row {
                out.push_str(&text);
            } else if row == last {
                out.push_str(text.trim_end());
            } else {
                out.push_str(text.trim_end());
                out.push('\n');
            }
        }
        out
    }

    /// All the text, history first; soft-wrapped lines joined, trailing blank
    /// lines cut.
    pub fn text(&mut self) -> String {
        let (_, cols) = self.size();
        let mut out = String::new();
        for row in 0..self.total() {
            let (text, wrapped) = self.read_row(row, 0, cols.saturating_sub(1));
            if wrapped {
                out.push_str(&text);
            } else {
                out.push_str(text.trim_end());
                out.push('\n');
            }
        }
        out.truncate(out.trim_end_matches('\n').len());
        out
    }

    /// The text of row `row` (from the oldest line) between two columns
    /// inclusive, and whether the line goes on in the next row. The viewport
    /// is moved to read it and put back.
    fn read_row(&mut self, row: usize, from: u16, to: u16) -> (String, bool) {
        let (rows, cols) = self.size();
        let saved = self.screen().scrollback();
        let (offset, at) = if row < self.history {
            (self.history - row, 0)
        } else {
            (0, row - self.history)
        };
        let mut text = String::new();
        let mut wrapped = false;
        if at < usize::from(rows) && cols > 0 {
            let at = at as u16;
            self.parser.screen_mut().set_scrollback(offset);
            let screen = self.parser.screen();
            for col in from..=to.min(cols - 1) {
                match screen.cell(at, col) {
                    Some(c) if c.is_wide_continuation() => {}
                    Some(c) if c.has_contents() => text.push_str(c.contents()),
                    _ => text.push(' '),
                }
            }
            wrapped = screen.row_wrapped(at);
        }
        self.parser.screen_mut().set_scrollback(saved);
        (text, wrapped)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(n: usize) -> String {
        (0..n).map(|i| format!("line {i}\r\n")).collect()
    }

    #[test]
    fn a_program_sets_and_asks_for_the_kitty_keyboard_flags() {
        let mut vt = Vt::new(3, 20, 100);
        assert_eq!(vt.kitty_keyboard(), 0);
        vt.feed(b"\x1b[>1u", true);
        assert_eq!(vt.kitty_keyboard(), 1);
        let fed = vt.feed(b"\x1b[=8;2u\x1b[?u", true);
        assert_eq!(
            (vt.kitty_keyboard(), fed.replies),
            (9, b"\x1b[?9u".to_vec())
        );
        // The alternate screen keeps its own stack.
        vt.feed(b"\x1b[?1049h", true);
        assert_eq!(vt.kitty_keyboard(), 0);
        vt.feed(b"\x1b[?1049l\x1b[<u", true);
        assert_eq!(vt.kitty_keyboard(), 0);
        // A replayed transcript sets them but is not answered.
        let fed = vt.feed(b"\x1b[>3u\x1b[?u", false);
        assert_eq!((vt.kitty_keyboard(), fed.replies), (3, Vec::new()));
    }

    #[test]
    fn output_scrolls_into_history_and_the_text_keeps_it() {
        let mut vt = Vt::new(3, 20, 100);
        vt.feed(lines(6).as_bytes(), true);
        assert_eq!(vt.total(), 3 + 4);
        assert!(vt.at_bottom());
        assert_eq!(vt.text(), "line 0\nline 1\nline 2\nline 3\nline 4\nline 5");
    }

    #[test]
    fn scrolling_moves_the_top_and_clamps() {
        let mut vt = Vt::new(3, 20, 100);
        vt.feed(lines(6).as_bytes(), true);
        assert_eq!(vt.top(), 4);
        vt.scroll_by(-2);
        assert_eq!((vt.top(), vt.at_bottom()), (2, false));
        vt.scroll_by(-100);
        assert_eq!(vt.top(), 0);
        vt.scroll_to(3);
        assert_eq!(vt.top(), 3);
        vt.scroll_by(100);
        assert!(vt.at_bottom());
    }

    #[test]
    fn a_view_scrolled_up_stays_on_its_lines_as_output_arrives() {
        let mut vt = Vt::new(3, 20, 100);
        vt.feed(lines(6).as_bytes(), true);
        vt.scroll_to(1);
        vt.feed(lines(2).as_bytes(), true);
        assert_eq!(vt.top(), 1);
    }

    #[test]
    fn queries_are_answered_unless_the_output_is_a_replay() {
        let mut vt = Vt::new(24, 80, 10);
        let fed = vt.feed(b"ab\x1b[5n\x1b[6n\x1b[c\x1b[>c", true);
        assert_eq!(
            String::from_utf8(fed.replies).unwrap(),
            "\x1b[0n\x1b[1;3R\x1b[?62;22c\x1b[>1;10;0c"
        );
        let replayed = vt.feed(b"\x1b[5n\x1b[6n", false);
        assert!(replayed.replies.is_empty());
    }

    #[test]
    fn title_directory_and_bell_are_reported_once() {
        let mut vt = Vt::new(24, 80, 10);
        let fed = vt.feed(b"\x1b]2;build\x07\x1b]7;file://host/tmp\x1b\\\x07", true);
        assert_eq!(fed.title.as_deref(), Some("build"));
        assert_eq!(fed.cwd.as_deref(), Some("file://host/tmp"));
        assert_eq!(fed.bells, 1);
        assert_eq!(vt.feed(b"x", true), Fed::default());
    }

    #[test]
    fn a_selection_survives_scrolling_and_reads_across_history() {
        let mut vt = Vt::new(3, 20, 100);
        vt.feed(lines(6).as_bytes(), true);
        vt.select(Pos { row: 1, col: 5 }, Pos { row: 3, col: 5 });
        assert_eq!(vt.selected_text(), "1\nline 2\nline 3");
        vt.scroll_by(-3);
        assert_eq!(vt.selected_text(), "1\nline 2\nline 3");
        assert!(vt.is_selected(2, 0));
        assert!(!vt.is_selected(1, 4));
    }

    #[test]
    fn a_soft_wrapped_line_reads_as_one() {
        let mut vt = Vt::new(3, 5, 10);
        vt.feed(b"abcdefgh\r\nnext", true);
        assert_eq!(vt.text(), "abcdefgh\nnext");
        vt.select_all();
        assert_eq!(vt.selected_text(), "abcdefgh\nnext");
    }

    #[test]
    fn a_reset_forgets_history() {
        let mut vt = Vt::new(3, 20, 100);
        vt.feed(lines(6).as_bytes(), true);
        vt.reset();
        assert_eq!((vt.total(), vt.text().as_str()), (3, ""));
    }
}
