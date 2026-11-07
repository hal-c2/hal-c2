//! What a terminal shows: the rows of hof_vt's [`Grid`] as filled rectangles
//! and glyph runs.
//!
//! Text is laid out here, when the item's paint is read, and not when it is
//! painted; the text engine keeps recent layouts, so an unchanged row is not
//! shaped again. What this returns only has to be drawn.
//!
//! How cells look (inverse and faint colours, the selection, the cursor's
//! shapes, blanks that draw nothing) follows Ljós Hof's
//! `crates/hof_qml/src/paint.rs` (MIT), drawn with plain glyph runs instead
//! of Hof's per-cluster glyph templates.

use std::sync::Arc;

use hof_vt::{Attrs, Cell, CursorShape, Grid, Line, Rgb};
use ljos::item::{
    Decorations, DisplayListBuilder, GlyphRun, LayoutParams, Rgba, TextEngine, TextStyle, kurbo,
};

/// Straight (not premultiplied) red, green, blue and alpha, each 0 to 1.
pub type Color = [f32; 4];

pub fn rgba(c: Color) -> Rgba {
    Rgba::from_straight(c[0], c[1], c[2], c[3])
}

pub fn opaque(c: Rgb) -> Color {
    [
        f32::from(c.r) / 255.0,
        f32::from(c.g) / 255.0,
        f32::from(c.b) / 255.0,
        1.0,
    ]
}

/// The first sixteen colours of the palette, as Ghostty draws them.
pub const ANSI: [Rgb; 16] = [
    Rgb::new(0x1d, 0x1f, 0x21),
    Rgb::new(0xcc, 0x66, 0x66),
    Rgb::new(0xb5, 0xbd, 0x68),
    Rgb::new(0xf0, 0xc6, 0x74),
    Rgb::new(0x81, 0xa2, 0xbe),
    Rgb::new(0xb2, 0x94, 0xbb),
    Rgb::new(0x8a, 0xbe, 0xb7),
    Rgb::new(0xc5, 0xc8, 0xc6),
    Rgb::new(0x66, 0x66, 0x66),
    Rgb::new(0xd5, 0x4e, 0x53),
    Rgb::new(0xb9, 0xca, 0x4a),
    Rgb::new(0xe7, 0xc5, 0x47),
    Rgb::new(0x7a, 0xa6, 0xda),
    Rgb::new(0xc3, 0x97, 0xd8),
    Rgb::new(0x70, 0xc0, 0xb1),
    Rgb::new(0xea, 0xea, 0xea),
];

/// The item's colours, as its properties set them: they keep their alpha
/// where the terminal's own colours have none.
pub struct Look {
    pub foreground: Color,
    pub background: Color,
    /// Invalid on the item draws the cursor in the text colour.
    pub cursor: Option<Color>,
    /// Invalid on the item swaps the selected cells' colours.
    pub selection: Option<Color>,
    pub padding: f64,
    /// The font at regular weight.
    pub style: TextStyle,
    pub cell: (f64, f64),
    /// The item has the keyboard: the cursor is solid, else an outline.
    pub focused: bool,
}

/// The size of a cell: the width of an "M" and the height of a line.
pub fn cell_size(te: &mut TextEngine, style: &TextStyle) -> (f64, f64) {
    let width = te.advance_width("M", style);
    let height = te.font_metrics(style).line_height;
    (width.max(1.0), height.max(1.0))
}

/// One display list: the background, the cells' fills, their text, and the
/// cursor over it all.
#[derive(Debug, Default)]
pub struct Painted {
    pub background: Color,
    pub fills: Vec<(kurbo::Rect, Color)>,
    pub glyphs: Vec<(Arc<GlyphRun>, kurbo::Vec2, Color, Decorations)>,
    pub cursor: Vec<(kurbo::Rect, Color)>,
    /// What an input method is composing, over everything else.
    pub composing: Option<Composing>,
}

/// An input method's composition: its background and its underlined text.
#[derive(Debug)]
pub struct Composing {
    pub rect: kurbo::Rect,
    pub background: Color,
    pub glyphs: Vec<(Arc<GlyphRun>, kurbo::Vec2, Color, Decorations)>,
}

impl Painted {
    pub fn paint(&self, size: kurbo::Size, out: &mut DisplayListBuilder) {
        out.fill_rect(
            kurbo::Rect::from_origin_size((0.0, 0.0), size),
            rgba(self.background),
        );
        for (rect, color) in self.fills.iter().chain(&self.cursor) {
            if rect.x0 < rect.x1 {
                out.fill_rect(*rect, rgba(*color));
            }
        }
        for (run, origin, color, decorations) in &self.glyphs {
            out.glyphs(Arc::clone(run), *origin, rgba(*color), *decorations);
        }
        if let Some(c) = &self.composing {
            out.fill_rect(c.rect, rgba(c.background));
            for (run, origin, color, decorations) in &c.glyphs {
                out.glyphs(Arc::clone(run), *origin, rgba(*color), *decorations);
            }
        }
    }
}

/// A colour of the terminal's, with the item's alpha when it is the item's
/// colour: a program that set its own (OSC 10, 11) gets it opaque.
fn prefer(item: Color, terminal: Rgb) -> Color {
    let theirs = opaque(terminal);
    let same = item[..3]
        .iter()
        .zip(&theirs[..3])
        .all(|(a, b)| (a - b).abs() < 0.5 / 255.0);
    if same { item } else { theirs }
}

fn mix(a: Color, b: Color, t: f32) -> Color {
    [
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3],
    ]
}

/// What a run of cells' text looks like; neighbours that look the same
/// share a layout.
#[derive(Clone, PartialEq)]
struct Ink {
    fg: Color,
    bold: bool,
    italic: bool,
    underline: bool,
    strike: bool,
}

struct Run {
    col: u16,
    text: String,
    ink: Ink,
}

/// A cell's colours, after inverse (done by the grid), faint and selection.
fn colours(cell: &Cell, look: &Look, fg: Color, bg: Color) -> (Color, Option<Color>) {
    let mut ink = opaque(cell.fg);
    let mut fill = cell.bg.map(opaque);
    if ink[..3] == fg[..3] {
        ink = fg;
    }
    if cell.attrs.contains(Attrs::SELECTED) {
        match look.selection {
            Some(s) => fill = Some(s),
            None => {
                let behind = fill.unwrap_or(bg);
                fill = Some(ink);
                ink = behind;
            }
        }
    }
    if cell.attrs.contains(Attrs::FAINT) {
        ink = mix(ink, fill.unwrap_or(bg), 0.5);
    }
    (ink, fill)
}

/// Whether a cell writes anything: blanks and hidden text (SGR 8) don't.
fn draws(line: &Line, cell: &Cell) -> bool {
    let text = line.cell_text(cell);
    cell.width > 0
        && !cell.attrs.contains(Attrs::INVISIBLE)
        && !text.is_empty()
        && text.chars().any(|c| c != ' ')
}

fn style_of(base: &TextStyle, ink: &Ink) -> TextStyle {
    let mut style = base.clone();
    if ink.bold {
        style.weight = 700.0;
    }
    style.italic = ink.italic;
    style.underline = ink.underline;
    style.strikeout = ink.strike;
    style
}

/// Where the cursor is drawn, and how.
struct Caret {
    col: u16,
    row: usize,
    width: u16,
    colour: Color,
    shape: CursorShape,
}

/// The cursor, steady: a solid block (or the program's bar or underline)
/// while the item has the keyboard, an outline while it hasn't.
fn caret(grid: &Grid, look: &Look, fg: Color, bg: Color) -> Option<Caret> {
    let (col, row) = grid.cursor.at?;
    let col = if grid.cursor.wide_tail {
        col.saturating_sub(1)
    } else {
        col
    };
    let row = usize::from(row);
    let cell = grid.lines.get(row).and_then(|l| cell_at(l, col));
    let colour = match (look.cursor, grid.colors.cursor) {
        (Some(c), Some(theirs)) => prefer(c, theirs),
        (Some(c), None) => c,
        (None, Some(theirs)) => opaque(theirs),
        (None, None) => cell.map_or(fg, |c| colours(c, look, fg, bg).0),
    };
    Some(Caret {
        col,
        row,
        width: cell.map_or(1, |c| u16::from(c.width.max(1))),
        colour,
        shape: if look.focused {
            grid.cursor.shape
        } else {
            CursorShape::BlockHollow
        },
    })
}

/// Lays the grid's rows out.
pub fn build(grid: &Grid, look: &Look, te: &mut TextEngine) -> Painted {
    let (cw, ch) = look.cell;
    let pad = look.padding;
    let fg = prefer(look.foreground, grid.colors.foreground);
    let bg = prefer(look.background, grid.colors.background);
    let caret = caret(grid, look, fg, bg);
    // A solid block hides the character under it unless it is written again
    // in the background's colour.
    let block = caret
        .as_ref()
        .filter(|c| c.shape == CursorShape::Block)
        .map(|c| (c.col, c.row));
    let mut painted = Painted {
        background: bg,
        ..Default::default()
    };

    for (row, line) in grid.lines.iter().enumerate() {
        let y = pad + row as f64 * ch;
        let mut runs: Vec<Run> = Vec::new();
        let mut open: Option<Run> = None;
        // The fill being drawn along the row: where it starts, and its colour.
        let mut fill: Option<(u16, Color)> = None;
        let mut col: u16 = 0;
        for cell in &line.cells {
            let width = u16::from(cell.width);
            if width == 0 {
                continue;
            }
            let (mut ink, behind) = colours(cell, look, fg, bg);
            if block == Some((col, row)) {
                ink = bg;
            }
            if let Some((from, c)) = fill
                && Some(c) != behind
            {
                painted.fills.push((span(pad, cw, y, ch, from, col), c));
                fill = None;
            }
            if fill.is_none()
                && let Some(c) = behind
            {
                fill = Some((col, c));
            }

            if draws(line, cell) {
                let this = Ink {
                    fg: ink,
                    bold: cell.attrs.contains(Attrs::BOLD),
                    italic: cell.attrs.contains(Attrs::ITALIC),
                    underline: cell.attrs.intersects(Attrs::UNDERLINES),
                    strike: cell.attrs.contains(Attrs::STRIKETHROUGH),
                };
                let text = line.cell_text(cell);
                match &mut open {
                    // A wide character gets a run of its own, so that a font
                    // whose advance is not the cell's does not push the rest.
                    Some(r) if r.ink == this && width == 1 => r.text.push_str(text),
                    _ => {
                        runs.extend(open.take());
                        open = Some(Run {
                            col,
                            text: text.to_owned(),
                            ink: this,
                        });
                        if width > 1 {
                            runs.extend(open.take());
                        }
                    }
                }
            } else {
                // A blank ends the run before it: the next starts at its cell.
                runs.extend(open.take());
            }
            col += width;
        }
        runs.extend(open.take());
        if let Some((from, c)) = fill {
            painted.fills.push((span(pad, cw, y, ch, from, col), c));
        }

        for run in runs {
            let layout = te.layout(
                run.text.trim_end(),
                &style_of(&look.style, &run.ink),
                &LayoutParams::default(),
            );
            let at = kurbo::Vec2::new(pad + f64::from(run.col) * cw, y);
            if let Some(line) = layout.lines.first() {
                for r in &line.runs {
                    painted
                        .glyphs
                        .push((Arc::clone(&r.glyphs), at, run.ink.fg, r.decorations));
                }
            }
        }
    }
    if let Some(caret) = caret {
        painted.cursor = shape(&caret, look);
    }
    painted
}

/// Draws what an input method is composing at the cursor, underlined on
/// the background, in place of the cursor: Hof's `paint_preedit`
/// (`crates/hof_qml/src/paint.rs`).
pub fn compose(painted: &mut Painted, grid: &Grid, look: &Look, te: &mut TextEngine, text: &str) {
    let Some((col, row)) = grid.cursor.at else {
        return;
    };
    if text.is_empty() {
        return;
    }
    let (cw, ch) = look.cell;
    let mut style = look.style.clone();
    style.underline = true;
    let layout = te.layout(text, &style, &LayoutParams::default());
    let at = kurbo::Vec2::new(
        look.padding + f64::from(col) * cw,
        look.padding + f64::from(row) * ch,
    );
    let fg = prefer(look.foreground, grid.colors.foreground);
    let glyphs = layout
        .lines
        .first()
        .map(|line| {
            line.runs
                .iter()
                .map(|r| (Arc::clone(&r.glyphs), at, fg, r.decorations))
                .collect()
        })
        .unwrap_or_default();
    painted.cursor.clear();
    painted.composing = Some(Composing {
        rect: kurbo::Rect::new(at.x, at.y, at.x + layout.advance.max(cw), at.y + ch),
        background: prefer(look.background, grid.colors.background),
        glyphs,
    });
}

fn span(pad: f64, cw: f64, y: f64, ch: f64, from: u16, to: u16) -> kurbo::Rect {
    kurbo::Rect::new(
        pad + f64::from(from) * cw,
        y,
        pad + f64::from(to) * cw,
        y + ch,
    )
}

fn shape(caret: &Caret, look: &Look) -> Vec<(kurbo::Rect, Color)> {
    let (cw, ch) = look.cell;
    let x = look.padding + f64::from(caret.col) * cw;
    let y = look.padding + caret.row as f64 * ch;
    let (x1, y1) = (x + cw * f64::from(caret.width), y + ch);
    let c = caret.colour;
    match caret.shape {
        CursorShape::Block => vec![(kurbo::Rect::new(x, y, x1, y1), c)],
        CursorShape::BlockHollow => vec![
            (kurbo::Rect::new(x, y, x1, y + 1.0), c),
            (kurbo::Rect::new(x, y1 - 1.0, x1, y1), c),
            (kurbo::Rect::new(x, y, x + 1.0, y1), c),
            (kurbo::Rect::new(x1 - 1.0, y, x1, y1), c),
        ],
        CursorShape::Bar => vec![(kurbo::Rect::new(x, y, x + 2.0, y1), c)],
        CursorShape::Underline => vec![(kurbo::Rect::new(x, y1 - 2.0, x1, y1), c)],
    }
}

/// The cell that starts at column `col`.
fn cell_at(line: &Line, col: u16) -> Option<&Cell> {
    let mut at = 0u16;
    for cell in &line.cells {
        if at == col && cell.width > 0 {
            return Some(cell);
        }
        at += u16::from(cell.width);
        if at > col {
            return None;
        }
    }
    None
}
