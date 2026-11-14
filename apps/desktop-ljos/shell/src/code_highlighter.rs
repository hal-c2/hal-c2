//! `CodeHighlighter` in `HalC2.Shell`, desktop-qt's of the same name
//! (src/native/CodeHighlighter.h): code in a `TextEdit` coloured by its
//! language (`language`, a fence's) or its file's name (`path`), through
//! the hal-c2-syntax crate desktop-qt links (native/syntax), in the theme
//! for its `background`. While `streaming`, only finished lines are read,
//! each once, as the text grows. Unknown languages, and code past the
//! first `MAX_BYTES`, stay plain.
//!
//! Ljós asks a highlighter for spans as it paints, on the GUI thread, so
//! nothing is read in the background: `reading` is always false, and
//! `coloured` says whether the code's language has a syntax.

use std::cell::Cell;
use std::ops::Range;

use hal_c2_syntax::{Highlighter as Syntax, Span, Theme};
use ljos::item::{HighlightSpan, Highlighter, set_highlighter};
use ljos::prelude::{Atom, Color, Cx, Engine, EngineError, ObjectId, QmlObject, Value, qml_impl};

/// Code past this many bytes is left plain, as desktop-qt's `kMaxChars`.
const MAX_BYTES: usize = 512 * 1024;

pub fn register(engine: &Engine) {
    engine.register_module(ljos::module!("HalC2.Shell" 1.0 => [CodeHighlighter]));
}

#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "CodeHighlighter")]
pub struct CodeHighlighter {
    /// The `textDocument` of the `TextEdit` the code is in.
    #[qml(notify)]
    document: Value,
    /// A fence's language (`ts`, `elixir`); read before `path`.
    #[qml(notify)]
    language: Atom,
    /// A file's name, for its kind.
    #[qml(notify)]
    path: Atom,
    /// What the code is drawn on: a light one takes the light colouring.
    #[qml(notify)]
    background: Color,
    /// The code is still being written: its unfinished last line waits.
    #[qml(notify)]
    streaming: bool,
    /// Whether the code's language has a syntax to colour it by.
    #[qml(notify, readonly)]
    coloured: bool,
    /// Always false: the code is read as it is painted.
    #[qml(constant, readonly)]
    reading: bool,
    #[qml(skip)]
    installed: Cell<Option<ObjectId>>,
}

impl Default for CodeHighlighter {
    fn default() -> Self {
        CodeHighlighter {
            document: Value::Undefined,
            language: Atom::from(""),
            path: Atom::from(""),
            background: Color::INVALID,
            streaming: false,
            coloured: false,
            reading: false,
            installed: Cell::new(None),
        }
    }
}

#[qml_impl]
impl CodeHighlighter {
    #[qml(on_complete)]
    fn completed(cx: &Cx) -> Result<(), EngineError> {
        let obj = cx.this;
        for prop in [
            Self::DOCUMENT.index,
            Self::LANGUAGE.index,
            Self::PATH.index,
            Self::BACKGROUND.index,
            Self::STREAMING.index,
        ] {
            cx.engine.watch(obj, prop, move |e, _| apply(e, obj))?;
        }
        apply(cx.engine, obj);
        Ok(())
    }
}

/// Gives the document a reader for what the properties say, or none.
fn apply(engine: &Engine, obj: ObjectId) {
    let cx = Cx::new(engine, obj);
    let (Ok(document), Ok(language), Ok(path), Ok(background), Ok(streaming)) = (
        cx.get(CodeHighlighter::DOCUMENT),
        cx.get(CodeHighlighter::LANGUAGE),
        cx.get(CodeHighlighter::PATH),
        cx.get(CodeHighlighter::BACKGROUND),
        cx.get(CodeHighlighter::STREAMING),
    ) else {
        return;
    };
    let target = document.as_object();
    let previous = engine
        .with(obj, |h: &CodeHighlighter| h.installed.replace(target))
        .ok()
        .flatten();
    if let Some(previous) = previous
        && Some(previous) != target
    {
        set_highlighter(engine, previous, None);
    }
    let syntax = if language.is_empty() {
        Syntax::for_path(&path)
    } else {
        Syntax::for_language(&language)
    };
    let _ = cx.set(CodeHighlighter::COLOURED, syntax.is_some());
    let Some(target) = target else {
        return;
    };
    let highlighter = syntax.map(|syntax| {
        let mut reader = Reader::new(syntax, theme_for(background), streaming);
        Box::new(move |text: &str| reader.spans(text)) as Highlighter
    });
    set_highlighter(engine, target, highlighter);
}

/// desktop-qt's `codereader::themeFor`: light from half lightness up.
pub(crate) fn theme_for(background: Color) -> Theme {
    let [r, g, b, _] = background.to_rgba_f();
    let lightness = (r.max(g).max(b) + r.min(g).min(b)) / 2.0;
    if background.is_valid() && lightness >= 0.5 {
        Theme::Light
    } else {
        Theme::Dark
    }
}

/// One document's code, read a whole line at a time as it grows: a text
/// that carries on from what was read is read from where it stopped.
struct Reader {
    /// Where the whole lines read so far left the syntax.
    syntax: Syntax,
    /// The start the syntax was made with, for a text that does not carry on.
    fresh: Syntax,
    theme: Theme,
    streaming: bool,
    /// The whole lines read so far, their UTF-16 units, and their spans.
    read: String,
    units: u32,
    spans: Vec<HighlightSpan>,
}

impl Reader {
    fn new(syntax: Syntax, theme: Theme, streaming: bool) -> Reader {
        Reader {
            fresh: syntax.clone(),
            syntax,
            theme,
            streaming,
            read: String::new(),
            units: 0,
            spans: Vec::new(),
        }
    }

    fn spans(&mut self, text: &str) -> Vec<HighlightSpan> {
        let text = &text[..floor_char_boundary(text, MAX_BYTES)];
        if !text.starts_with(self.read.as_str()) {
            self.syntax = self.fresh.clone();
            self.read.clear();
            self.units = 0;
            self.spans.clear();
        }
        // A rich text's `<br/>` reads as a line separator.
        let lines = text.rfind(['\n', '\u{2028}', '\u{2029}']).map_or(0, |at| {
            at + text[at..].chars().next().map_or(1, char::len_utf8)
        });
        if lines > self.read.len() {
            let new = &text[self.read.len()..lines];
            let start = self.read.len();
            let found = read(&mut self.syntax, new, self.units, self.theme);
            self.spans
                .extend(found.into_iter().map(|s| shifted(s, start)));
            self.read.push_str(new);
            self.units += new.encode_utf16().count() as u32;
        }
        let mut spans = self.spans.clone();
        // The unfinished last line, read from a copy so the next text
        // reads it again whole; while the code is written it waits.
        if !self.streaming && lines < text.len() {
            let mut last = self.syntax.clone();
            let found = read(&mut last, &text[lines..], self.units, self.theme);
            spans.extend(found.into_iter().map(|s| shifted(s, lines)));
        }
        spans
    }
}

fn shifted(mut span: HighlightSpan, by: usize) -> HighlightSpan {
    span.range = span.range.start + by..span.range.end + by;
    span
}

/// The spans of `text` in `theme`, read on from where `syntax` stopped
/// (`before` UTF-16 units in, as its spans count), with byte ranges from
/// the start of `text`.
fn read(syntax: &mut Syntax, text: &str, before: u32, theme: Theme) -> Vec<HighlightSpan> {
    let mut found: Vec<Span> = Vec::new();
    // Separators are one UTF-16 unit, as `\n` is, so spans still count in `text`.
    let fed = text.replace(['\u{2028}', '\u{2029}'], "\n");
    syntax.feed(&fed, |span| {
        if span.theme == theme {
            found.push(span);
        }
    });
    let mut bytes = Utf16Bytes::new(text);
    found
        .into_iter()
        .filter_map(|span| {
            let start = span.start.checked_sub(before)? as usize;
            let range = bytes.range(start..start + span.len as usize)?;
            let [a, r, g, b] = span.color.to_be_bytes();
            Some(HighlightSpan {
                range,
                color: Some(Color::from_rgba8(r, g, b, a)),
                weight: span.bold.then_some(700),
                italic: span.italic,
                underline: span.underline,
                ..HighlightSpan::default()
            })
        })
        .collect()
}

/// UTF-16 offsets into `text` as byte offsets, for spans in order.
struct Utf16Bytes<'a> {
    chars: std::str::CharIndices<'a>,
    len: usize,
    units: usize,
    byte: usize,
}

impl<'a> Utf16Bytes<'a> {
    fn new(text: &'a str) -> Self {
        Utf16Bytes {
            chars: text.char_indices(),
            len: text.len(),
            units: 0,
            byte: 0,
        }
    }

    /// The byte offset of the `units`th unit, `units` no less than the last
    /// asked for.
    fn byte_at(&mut self, units: usize) -> Option<usize> {
        while self.units < units {
            let (_, c) = self.chars.next()?;
            self.units += c.len_utf16();
            self.byte += c.len_utf8();
        }
        (self.units == units && self.byte <= self.len).then_some(self.byte)
    }

    fn range(&mut self, units: Range<usize>) -> Option<Range<usize>> {
        let start = self.byte_at(units.start)?;
        let end = self.byte_at(units.end)?;
        Some(start..end)
    }
}

fn floor_char_boundary(text: &str, at: usize) -> usize {
    if at >= text.len() {
        return text.len();
    }
    (0..=at)
        .rev()
        .find(|&i| text.is_char_boundary(i))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::{Reader, Syntax, Theme};

    #[test]
    fn code_is_coloured_in_bytes_past_wide_characters() {
        let mut reader = Reader::new(Syntax::for_language("rust").unwrap(), Theme::Dark, false);
        let text = "// é😀\nfn main() {}\n";
        let spans = reader.spans(text);
        let words: Vec<&str> = spans.iter().map(|s| &text[s.range.clone()]).collect();
        assert!(words.contains(&"fn"), "{words:?}");
        assert!(words.contains(&"main"), "{words:?}");
    }

    #[test]
    fn a_rich_texts_finished_lines_are_coloured_while_it_is_written() {
        let mut reader = Reader::new(Syntax::for_language("ts").unwrap(), Theme::Dark, true);
        let spans = reader.spans("const a = 1;\u{2028}const b = 2;\u{2028}const c");
        assert!(spans.iter().any(|s| s.range.start == 0));
        let second = "const a = 1;\u{2028}".len();
        assert!(spans.iter().any(|s| s.range.start == second));
        let last = "const a = 1;\u{2028}const b = 2;\u{2028}".len();
        assert!(spans.iter().all(|s| s.range.start < last));
    }

    #[test]
    fn a_growing_text_reads_on_and_a_new_one_starts_again() {
        let mut reader = Reader::new(Syntax::for_language("rust").unwrap(), Theme::Light, true);
        // Streaming: the unfinished line waits.
        assert!(
            reader.spans("fn a() {}\nfn b").len() < reader.spans("fn a() {}\nfn b() {}\n").len()
        );
        let grown = reader.spans("fn a() {}\nfn b() {}\n");
        let fresh = Reader::new(Syntax::for_language("rust").unwrap(), Theme::Light, true)
            .spans("fn a() {}\nfn b() {}\n");
        assert_eq!(grown, fresh);
        let other = reader.spans("let x = 1;\n");
        assert!(other.iter().all(|s| s.range.end <= "let x = 1;\n".len()));
    }
}
