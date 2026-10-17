//! `ComposerHighlighter` in `HalC2.Shell`, desktop-qt's QSyntaxHighlighter
//! of the same name (src/native/ComposerHighlighter.h): the composer's draft
//! stays Markdown, and while `rich` is on the markers of its inline
//! formatting are drawn dimmed beside what they mark.
//!
//! Ljós gives an editor's text colours, backgrounds and an underline per
//! stretch ([`ljos_quick::text_input::set_highlighter`]) and no font
//! attributes, so of what the Qt highlighter does only the dimmed markers
//! (and heading marks) are here. Bold, italic, struck-through and code text,
//! and `codeFont`, wait for Ljós to paint them. `codeFont` is kept so QML
//! can set it. TODO(ljos#38).
//!
//! `document` is the `textDocument` of the composer's `TextEdit`.

use std::sync::LazyLock;

use fancy_regex::Regex;
use ljos::prelude::{Atom, Color, Cx, Engine, EngineError, ObjectId, QmlObject, Value, qml_impl};
use ljos_quick::text_input::{HighlightSpan, set_highlighter};
use std::cell::Cell;

/// What stands between the markers of a rule, read from the same patterns as
/// the Qt highlighter's. Each: the pattern and how wide its marker is.
static RULES: LazyLock<Vec<(Regex, usize)>> = LazyLock::new(|| {
    [
        (r"`[^`\n]+`", 1),
        (r"(\*\*|__)(?=\S)(.+?)(?<=\S)\1", 2),
        (r"~~(?=\S)(.+?)(?<=\S)~~", 2),
        (
            r"(?<![\*\w])\*(?=[^\s\*])([^\*\n]+?)(?<=[^\s\*])\*(?![\*\w])|(?<![_\w])_(?=[^\s_])([^_\n]+?)(?<=[^\s_])_(?![_\w])",
            1,
        ),
    ]
    .into_iter()
    .filter_map(|(pattern, width)| Regex::new(pattern).ok().map(|r| (r, width)))
    .collect()
});

static HEADING: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"^ {0,3}#{1,6} +\S.*$").ok());

/// The stretches of `text` that are markers (`**`, `` ` ``, `#`, ...), in
/// `color`. Line by line, as a QSyntaxHighlighter reads a document.
pub fn marker_spans(text: &str, color: Color) -> Vec<HighlightSpan> {
    let mut spans = Vec::new();
    let mut offset = 0;
    for line in text.split('\n') {
        line_markers(line, offset, color, &mut spans);
        offset += line.len() + 1;
    }
    spans
}

fn line_markers(line: &str, offset: usize, color: Color, spans: &mut Vec<HighlightSpan>) {
    let mut marker = |range: std::ops::Range<usize>| {
        spans.push(HighlightSpan {
            range: offset + range.start..offset + range.end,
            color: Some(color),
            ..HighlightSpan::default()
        });
    };
    let heading = HEADING
        .as_ref()
        .is_some_and(|h| h.is_match(line).unwrap_or(false));
    if heading && let Some(hash) = line.find('#') {
        let end = line[hash..].find(' ').map_or(line.len(), |at| hash + at);
        marker(0..end);
    }
    for (rule, width) in RULES.iter() {
        for found in rule.find_iter(line).flatten() {
            marker(found.start()..found.start() + width);
            marker(found.end() - width..found.end());
        }
    }
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
    /// Transparent, the default, leaves the markers as they are.
    #[qml(notify)]
    marker_color: Color,
    /// Kept for QML; not painted (see the module comment).
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
            marker_color: Color::TRANSPARENT,
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
    let (Ok(document), Ok(rich), Ok(color)) = (
        cx.get(ComposerHighlighter::DOCUMENT),
        cx.get(ComposerHighlighter::RICH),
        cx.get(ComposerHighlighter::MARKER_COLOR),
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
    let highlighter = (rich && color.a > 0).then(|| {
        Box::new(move |text: &str| marker_spans(text, color)) as ljos_quick::text_input::Highlighter
    });
    set_highlighter(engine, target, highlighter);
}
