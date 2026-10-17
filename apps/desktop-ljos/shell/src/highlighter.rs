//! `ComposerHighlighter` in `HalC2.Shell`, desktop-qt's QSyntaxHighlighter
//! of the same name (src/native/ComposerHighlighter.h): the composer's draft
//! stays Markdown, and while `rich` is on its inline formatting shows as
//! what it marks (bold, italic, struck-through, code in `codeFont`, a bold
//! heading), with the markers beside it in `markerColor`.
//!
//! `document` is the `textDocument` of the composer's `TextEdit`.

use std::cell::Cell;
use std::sync::{Arc, LazyLock};

use fancy_regex::Regex;
use ljos::item::{HighlightSpan, Highlighter, set_highlighter};
use ljos::prelude::{Atom, Color, Cx, Engine, EngineError, ObjectId, QmlObject, Value, qml_impl};

/// What the text between a rule's markers reads as.
#[derive(Clone, Copy)]
enum Style {
    Code,
    Bold,
    Strikeout,
    Italic,
}

/// The Qt highlighter's rules, in its order. Each: the pattern, how wide
/// its marker is, and what the text between reads as.
static RULES: LazyLock<Vec<(Regex, usize, Style)>> = LazyLock::new(|| {
    [
        (r"`[^`\n]+`", 1, Style::Code),
        (r"(\*\*|__)(?=\S)(.+?)(?<=\S)\1", 2, Style::Bold),
        (r"~~(?=\S)(.+?)(?<=\S)~~", 2, Style::Strikeout),
        (
            r"(?<![\*\w])\*(?=[^\s\*])([^\*\n]+?)(?<=[^\s\*])\*(?![\*\w])|(?<![_\w])_(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?![_\w])",
            1,
            Style::Italic,
        ),
    ]
    .into_iter()
    .filter_map(|(pattern, width, style)| Regex::new(pattern).ok().map(|r| (r, width, style)))
    .collect()
});

static HEADING: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"^ {0,3}#{1,6} +\S.*$").ok());

/// A byte's QTextCharFormat, of what the highlighter sets.
#[derive(Clone, Debug, Default, PartialEq)]
struct Format {
    color: Option<Color>,
    bold: bool,
    italic: bool,
    strikeout: bool,
    family: Option<Arc<str>>,
}

/// How `text` reads with `rich` on: one span per stretch that differs from
/// the editor's own text. Markers are in `marker` (as the editor's text
/// when `None`, Qt's invalid colour), code in `code_font` (any fixed-pitch
/// face when empty). Line by line, as a QSyntaxHighlighter reads a
/// document; ranges count bytes.
pub fn spans(text: &str, marker: Option<Color>, code_font: &str) -> Vec<HighlightSpan> {
    let code: Arc<str> = if code_font.is_empty() {
        // Qt's `setFontFixedPitch(true)`: the generic family.
        Arc::from("monospace")
    } else {
        Arc::from(code_font)
    };
    let marker = Format {
        color: marker,
        ..Format::default()
    };
    let mut spans = Vec::new();
    let mut offset = 0;
    for line in text.split('\n') {
        let formats = line_formats(line, &marker, &code);
        let mut at = 0;
        while at < formats.len() {
            let end = (at..formats.len())
                .find(|&i| formats[i] != formats[at])
                .unwrap_or(formats.len());
            let f = &formats[at];
            if *f != Format::default() {
                spans.push(HighlightSpan {
                    range: offset + at..offset + end,
                    color: f.color,
                    weight: f.bold.then_some(700),
                    italic: f.italic,
                    strikeout: f.strikeout,
                    family: f.family.clone(),
                    ..HighlightSpan::default()
                });
            }
            at = end;
        }
        offset += line.len() + 1;
    }
    spans
}

/// The format of each byte of `line`, as the Qt highlighter's
/// `highlightBlock` sets them: a later rule reads what an earlier one set,
/// and a marker's format replaces what its bytes had.
fn line_formats(line: &str, marker: &Format, code: &Arc<str>) -> Vec<Format> {
    let mut formats = vec![Format::default(); line.len()];
    let heading = HEADING
        .as_ref()
        .is_some_and(|h| h.is_match(line).unwrap_or(false));
    if heading && let Some(hash) = line.find('#') {
        for f in &mut formats {
            f.bold = true;
        }
        let end = line[hash..].find(' ').map_or(line.len(), |at| hash + at);
        formats[..end].fill(marker.clone());
    }
    for (rule, width, style) in RULES.iter() {
        for found in rule.find_iter(line).flatten() {
            let (start, end) = (found.start(), found.end());
            for f in &mut formats[start + width..end - width] {
                match style {
                    Style::Code => f.family = Some(code.clone()),
                    Style::Bold => f.bold = true,
                    Style::Strikeout => f.strikeout = true,
                    Style::Italic => f.italic = true,
                }
            }
            formats[start..start + width].fill(marker.clone());
            formats[end - width..end].fill(marker.clone());
        }
    }
    formats
}

/// Adds the type to the `HalC2.Shell` module.
pub fn register(engine: &Engine) {
    engine.register_module(ljos::module!("HalC2.Shell" 1.0 => [ComposerHighlighter]));
}

#[derive(QmlObject)]
#[qml(module = "HalC2.Shell", name = "ComposerHighlighter")]
pub struct ComposerHighlighter {
    /// The composer's `TextEdit.textDocument`.
    #[qml(notify)]
    document: Value,
    #[qml(notify)]
    rich: bool,
    /// The markers' colour; invalid, the default, leaves them as the
    /// text is.
    #[qml(notify)]
    marker_color: Color,
    /// The family of code; empty, the default, is any fixed-pitch face.
    #[qml(notify)]
    code_font: Atom,
    /// The document that has this one's highlighter.
    #[qml(skip)]
    installed: Cell<Option<ObjectId>>,
}

impl Default for ComposerHighlighter {
    fn default() -> Self {
        ComposerHighlighter {
            document: Value::Undefined,
            rich: false,
            marker_color: Color::INVALID,
            code_font: Atom::from(""),
            installed: Cell::new(None),
        }
    }
}

#[qml_impl]
impl ComposerHighlighter {
    #[qml(on_complete)]
    fn completed(cx: &Cx) -> Result<(), EngineError> {
        let obj = cx.this;
        for prop in [
            Self::DOCUMENT.index,
            Self::RICH.index,
            Self::MARKER_COLOR.index,
            Self::CODE_FONT.index,
        ] {
            cx.engine.watch(obj, prop, move |e, _| apply(e, obj))?;
        }
        apply(cx.engine, obj);
        Ok(())
    }
}

/// Gives the document the highlighter its properties say, or none.
fn apply(engine: &Engine, obj: ObjectId) {
    let cx = Cx::new(engine, obj);
    let (Ok(document), Ok(rich), Ok(color), Ok(code_font)) = (
        cx.get(ComposerHighlighter::DOCUMENT),
        cx.get(ComposerHighlighter::RICH),
        cx.get(ComposerHighlighter::MARKER_COLOR),
        cx.get(ComposerHighlighter::CODE_FONT),
    ) else {
        return;
    };
    let target = document.as_object();
    let previous = engine
        .with(obj, |h: &ComposerHighlighter| h.installed.replace(target))
        .ok()
        .flatten();
    if let Some(previous) = previous
        && Some(previous) != target
    {
        set_highlighter(engine, previous, None);
    }
    let Some(target) = target else {
        return;
    };
    let marker = color.is_valid().then_some(color);
    let highlighter =
        rich.then(|| Box::new(move |text: &str| spans(text, marker, &code_font)) as Highlighter);
    set_highlighter(engine, target, highlighter);
}
