//! What a terminal shows: the cells in view as filled rectangles and glyph
//! runs.
//!
//! Text is laid out here, when the item's paint is read, and not when it is
//! painted: the scene holds the text engine while it paints. What this
//! returns only has to be drawn.

use std::sync::Arc;

use ljos::item::{
    Decorations, DisplayListBuilder, GlyphRun, LayoutParams, Rgba, TextEngine, TextStyle, kurbo,
};

use super::vt::Vt;

/// Straight (not premultiplied) red, green, blue and alpha, each 0 to 1.
pub type Color = [f32; 4];

pub fn rgba(c: Color) -> Rgba {
    Rgba::from_straight(c[0], c[1], c[2], c[3])
}

pub fn rgb8(r: u8, g: u8, b: u8) -> Color {
    [
        f32::from(r) / 255.0,
        f32::from(g) / 255.0,
        f32::from(b) / 255.0,
        1.0,
    ]
}

/// The first sixteen colours of the palette, as Ghostty draws them.
const ANSI: [(u8, u8, u8); 16] = [
    (0x1d, 0x1f, 0x21),
    (0xcc, 0x66, 0x66),
    (0xb5, 0xbd, 0x68),
    (0xf0, 0xc6, 0x74),
    (0x81, 0xa2, 0xbe),
    (0xb2, 0x94, 0xbb),
    (0x8a, 0xbe, 0xb7),
    (0xc5, 0xc8, 0xc6),
    (0x66, 0x66, 0x66),
    (0xd5, 0x4e, 0x53),
    (0xb9, 0xca, 0x4a),
    (0xe7, 0xc5, 0x47),
    (0x7a, 0xa6, 0xda),
    (0xc3, 0x97, 0xd8),
    (0x70, 0xc0, 0xb1),
    (0xea, 0xea, 0xea),
];

/// The 256 colours: the sixteen, a 6x6x6 cube, and 24 greys.
pub fn default_palette() -> Vec<Color> {
    let mut p: Vec<Color> = ANSI.iter().map(|&(r, g, b)| rgb8(r, g, b)).collect();
    let level = |n: u8| if n == 0 { 0 } else { 55 + 40 * n };
    for i in 0..216u16 {
        let (r, g, b) = ((i / 36) as u8, (i / 6 % 6) as u8, (i % 6) as u8);
        p.push(rgb8(level(r), level(g), level(b)));
    }
    for i in 0..24u8 {
        let v = 8 + 10 * i;
        p.push(rgb8(v, v, v));
    }
    p
}

/// Everything about how cells are drawn.
pub struct Look {
    pub foreground: Color,
    pub background: Color,
    /// The cursor's colour; the foreground when none.
    pub cursor: Option<Color>,
    /// The selection's colour; when none the selected cells swap colours.
    pub selection: Option<Color>,
    pub palette: Vec<Color>,
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

/// One display list: what to fill, then what to write.
#[derive(Debug, Default)]
pub struct Painted {
    pub background: Color,
    pub fills: Vec<(kurbo::Rect, Color)>,
    pub glyphs: Vec<(Arc<GlyphRun>, kurbo::Vec2, Color, Decorations)>,
}

impl Painted {
    pub fn paint(&self, size: kurbo::Size, out: &mut DisplayListBuilder) {
        out.fill_rect(
            kurbo::Rect::from_origin_size((0.0, 0.0), size),
            rgba(self.background),
        );
        for (rect, color) in &self.fills {
            out.fill_rect(*rect, rgba(*color));
        }
        for (run, origin, color, decorations) in &self.glyphs {
            out.glyphs(Arc::clone(run), *origin, rgba(*color), *decorations);
        }
    }
}

/// What a run of cells looks like; cells with the same look share a layout.
#[derive(Clone, PartialEq)]
struct Look1 {
    fg: Color,
    bold: bool,
    italic: bool,
    underline: bool,
}

struct Run {
    col: u16,
    text: String,
    look: Look1,
}

fn mix(a: Color, b: Color, t: f32) -> Color {
    [
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3],
    ]
}

fn resolve(c: vt100::Color, default: Color, palette: &[Color]) -> Color {
    match c {
        vt100::Color::Default => default,
        vt100::Color::Idx(i) => palette.get(usize::from(i)).copied().unwrap_or(default),
        vt100::Color::Rgb(r, g, b) => rgb8(r, g, b),
    }
}

/// Lays the cells in view out.
pub fn build(vt: &Vt, look: &Look, te: &mut TextEngine) -> Painted {
    let (rows, cols) = vt.size();
    let (cw, ch) = look.cell;
    let pad = look.padding;
    let top = vt.top();
    let cursor = vt.cursor();
    let mut painted = Painted {
        background: look.background,
        ..Default::default()
    };
    let mut cursor_fill = None;

    for row in 0..rows {
        let y = pad + f64::from(row) * ch;
        let mut runs: Vec<Run> = Vec::new();
        let mut open: Option<Run> = None;
        let mut col = 0;
        while col < cols {
            let Some(cell) = vt.cell(row, col) else {
                col += 1;
                continue;
            };
            if cell.is_wide_continuation() {
                col += 1;
                continue;
            }
            let width: u16 = if cell.is_wide() { 2 } else { 1 };
            let at_cursor = cursor == Some((row, col));
            let selected = vt.is_selected(top + usize::from(row), col);

            let mut fg = resolve(cell.fgcolor(), look.foreground, &look.palette);
            let mut bg = resolve(cell.bgcolor(), look.background, &look.palette);
            let mut has_bg = cell.bgcolor() != vt100::Color::Default;
            if cell.inverse() {
                std::mem::swap(&mut fg, &mut bg);
                has_bg = true;
            }
            if cell.dim() {
                fg = mix(fg, bg, 0.5);
            }
            if selected {
                match look.selection {
                    Some(s) => bg = s,
                    None => std::mem::swap(&mut fg, &mut bg),
                }
                has_bg = true;
            }
            if at_cursor && look.focused {
                bg = look.cursor.unwrap_or(look.foreground);
                fg = look.background;
                has_bg = true;
            }
            let x = pad + f64::from(col) * cw;
            if has_bg {
                let rect = kurbo::Rect::new(x, y, x + cw * f64::from(width), y + ch);
                if at_cursor && look.focused {
                    cursor_fill = Some((rect, bg));
                } else {
                    painted.fills.push((rect, bg));
                }
            }
            if at_cursor && !look.focused {
                let c = look.cursor.unwrap_or(look.foreground);
                let (x1, y1) = (x + cw * f64::from(width), y + ch);
                for rect in [
                    kurbo::Rect::new(x, y, x1, y + 1.0),
                    kurbo::Rect::new(x, y1 - 1.0, x1, y1),
                    kurbo::Rect::new(x, y, x + 1.0, y1),
                    kurbo::Rect::new(x1 - 1.0, y, x1, y1),
                ] {
                    painted.fills.push((rect, c));
                }
            }

            let text = cell.contents();
            if text.is_empty() || cell.contents().chars().all(|c| c == ' ') && !cell.underline() {
                // Blank: nothing to write, and it ends the run before it.
                runs.extend(open.take());
            } else {
                let this = Look1 {
                    fg,
                    bold: cell.bold(),
                    italic: cell.italic(),
                    underline: cell.underline(),
                };
                match &mut open {
                    // Wide glyphs get a run each, so that a font whose
                    // advance is not the cell's does not push the rest.
                    Some(r) if r.look == this && width == 1 => r.text.push_str(text),
                    _ => {
                        runs.extend(open.take());
                        open = Some(Run {
                            col,
                            text: text.to_string(),
                            look: this,
                        });
                        if width == 2 {
                            runs.extend(open.take());
                        }
                    }
                }
            }
            col += width;
        }
        runs.extend(open.take());

        for run in runs {
            let mut style = look.style.clone();
            if run.look.bold {
                style.weight = 700.0;
            }
            style.italic = run.look.italic;
            style.underline = run.look.underline;
            let layout = te.layout(
                run.text.trim_end_matches(' '),
                &style,
                &LayoutParams::default(),
            );
            let origin = kurbo::Vec2::new(pad + f64::from(run.col) * cw, y);
            if let Some(line) = layout.lines.first() {
                for r in &line.runs {
                    painted.glyphs.push((
                        Arc::clone(&r.glyphs),
                        origin,
                        run.look.fg,
                        r.decorations,
                    ));
                }
            }
        }
    }
    painted.fills.extend(cursor_fill);
    painted
}
