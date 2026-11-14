//! `ComposerHighlighter` as the composer uses it: while `rich` is on the
//! draft's inline formatting shows as what it marks, its markers dimmed,
//! and the text itself does not change.

mod common;

use std::rc::Rc;

use common::{call, shell};
use hal_c2_shell::highlighter::spans as highlight;
use hal_c2_shell::mc::Disconnected;
use ljos::item::highlights;
use ljos::prelude::{Color, Engine, ObjectId, Value};

const DIM: Color = Color::from_rgba8(0x80, 0x80, 0x80, 0x99);

const MAIN: &str = r##"
import QtQuick
import HalC2.Shell

Item {
    id: root
    property bool rich: true
    property color dim: "#99808080"
    property string draft: "a **b** c"
    TextEdit { id: input; text: root.draft }
    ComposerHighlighter {
        document: input.textDocument
        rich: root.rich
        markerColor: root.dim
        codeFont: "monospace"
    }
    function document() { return input.textDocument }
    function edit() { return input }
}
"##;

fn spans(engine: &Engine, root: ObjectId) -> Vec<(std::ops::Range<usize>, Option<Color>)> {
    let Value::Object(document) = call(engine, root, "document", &[]) else {
        panic!("a text document");
    };
    highlights(engine, document)
        .expect("an editor's document")
        .iter()
        .map(|s| (s.range.clone(), s.color))
        .collect()
}

fn marked(text: &str) -> Vec<String> {
    highlight(text, Some(DIM), "mono")
        .into_iter()
        .filter(|s| s.color == Some(DIM))
        .map(|s| text[s.range].to_owned())
        .collect()
}

/// Each stretch that is not the editor's text, and how it reads: `b`old,
/// `i`talic, `s`truck out, `c`ode, `m`arker.
fn read(text: &str, marker: Option<Color>) -> Vec<(String, String)> {
    highlight(text, marker, "mono")
        .into_iter()
        .map(|s| {
            let mut how = String::new();
            for (on, c) in [
                (s.color.is_some(), 'm'),
                (s.weight == Some(700), 'b'),
                (s.italic, 'i'),
                (s.strikeout, 's'),
                (s.family.as_deref() == Some("mono"), 'c'),
            ] {
                if on {
                    how.push(c);
                }
            }
            (text[s.range].to_owned(), how)
        })
        .collect()
}

fn pairs(list: &[(&str, &str)]) -> Vec<(String, String)> {
    list.iter()
        .map(|(a, b)| ((*a).to_owned(), (*b).to_owned()))
        .collect()
}

#[test]
fn markers_are_dimmed_and_the_text_between_is_not() {
    assert_eq!(marked("a **b** c"), ["**", "**"]);
    assert_eq!(marked("`code` and `more`"), ["`", "`", "`", "`"]);
    assert_eq!(marked("~~gone~~"), ["~~", "~~"]);
    assert_eq!(marked("*it* and _it_"), ["*", "*", "_", "_"]);
    assert_eq!(marked("# Title"), ["#"]);
    assert_eq!(marked("  ### Title"), ["  ###"]);
    assert_eq!(marked("with **bold *and* nested**"), ["**", "*", "*", "**"]);
}

#[test]
fn the_text_between_reads_as_what_it_marks() {
    assert_eq!(
        read("a **b** c", Some(DIM)),
        pairs(&[("**", "m"), ("b", "b"), ("**", "m")])
    );
    assert_eq!(
        read("`x` *y* ~~z~~", Some(DIM)),
        pairs(&[
            ("`", "m"),
            ("x", "c"),
            ("`", "m"),
            ("*", "m"),
            ("y", "i"),
            ("*", "m"),
            ("~~", "m"),
            ("z", "s"),
            ("~~", "m"),
        ])
    );
    // A heading is bold; its marks are markers.
    assert_eq!(
        read("## Title", Some(DIM)),
        pairs(&[("##", "m"), (" Title", "b")])
    );
    // Rules nest, and a marker inside bold text is only a marker.
    assert_eq!(
        read("**a *b* c**", Some(DIM)),
        pairs(&[
            ("**", "m"),
            ("a ", "b"),
            ("*", "m"),
            ("b", "bi"),
            ("*", "m"),
            (" c", "b"),
            ("**", "m"),
        ])
    );
}

#[test]
fn with_no_marker_colour_the_markers_are_the_text_s() {
    assert_eq!(read("a **b** c", None), pairs(&[("b", "b")]));
    // No code font: a fixed-pitch one.
    let code = highlight("`x`", None, "");
    assert_eq!(code.len(), 1);
    assert_eq!(code[0].family.as_deref(), Some("monospace"));
}

#[test]
fn what_is_not_formatting_has_no_markers() {
    assert!(marked("2 * 3 * 4").is_empty());
    assert!(marked("snake_case_name").is_empty());
    assert!(marked("** not bold **").is_empty());
    assert!(marked("#nospace").is_empty());
    assert!(marked("").is_empty());
}

#[test]
fn lines_are_read_alone_and_ranges_count_bytes() {
    let text = "新 **b**\n**c**";
    let found: Vec<_> = highlight(text, Some(DIM), "mono")
        .into_iter()
        .map(|s| s.range)
        .collect();
    assert_eq!(found, [4..6, 6..7, 7..9, 10..12, 12..13, 13..15]);
    assert_eq!(marked("**a\nb**"), Vec::<String>::new());
}

#[test]
fn rich_turns_the_dimming_on_and_off() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    assert_eq!(
        spans(&engine, root),
        vec![(2..4, Some(DIM)), (4..5, None), (5..7, Some(DIM))]
    );
    engine
        .write_by_name(root, "rich", Value::Bool(false))
        .unwrap();
    assert!(spans(&engine, root).is_empty());
    engine
        .write_by_name(root, "rich", Value::Bool(true))
        .unwrap();
    assert_eq!(spans(&engine, root).len(), 3);
    // An invalid colour leaves the markers as the text is.
    engine
        .write_by_name(root, "dim", Value::Color(Color::INVALID))
        .unwrap();
    assert_eq!(spans(&engine, root), vec![(4..5, None)]);
}

#[test]
fn the_draft_changing_moves_the_markers() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    engine
        .write_by_name(root, "draft", Value::string("`x`"))
        .unwrap();
    assert_eq!(
        spans(&engine, root),
        vec![(0..1, Some(DIM)), (1..2, None), (2..3, Some(DIM))]
    );
}
