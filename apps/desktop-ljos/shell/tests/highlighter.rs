//! `ComposerHighlighter` as the composer uses it: while `rich` is on the
//! markers of the draft's inline formatting are dimmed, and nothing else
//! about the text changes.

mod common;

use std::rc::Rc;

use common::{call, shell};
use hal_c2_shell::highlighter::marker_spans;
use hal_c2_shell::mc::Disconnected;
use ljos::prelude::{Color, Engine, ObjectId, Value};
use ljos_quick::text_input::highlights;

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
        .into_iter()
        .map(|s| (s.range, s.color))
        .collect()
}

fn marked(text: &str) -> Vec<String> {
    marker_spans(text, DIM)
        .into_iter()
        .map(|s| text[s.range].to_owned())
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
    assert_eq!(marked("with **bold *and* nested**"), ["**", "**", "*", "*"]);
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
    let found: Vec<_> = marker_spans(text, DIM)
        .into_iter()
        .map(|s| s.range)
        .collect();
    assert_eq!(found, [4..6, 7..9, 10..12, 13..15]);
    assert_eq!(marked("**a\nb**"), Vec::<String>::new());
}

#[test]
fn rich_turns_the_dimming_on_and_off() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    assert_eq!(
        spans(&engine, root),
        vec![(2..4, Some(DIM)), (5..7, Some(DIM))]
    );
    engine
        .write_by_name(root, "rich", Value::Bool(false))
        .unwrap();
    assert!(spans(&engine, root).is_empty());
    engine
        .write_by_name(root, "rich", Value::Bool(true))
        .unwrap();
    assert_eq!(spans(&engine, root).len(), 2);
}

#[test]
fn the_draft_changing_moves_the_markers() {
    let (engine, root) = shell(MAIN, Rc::new(Disconnected::default()));
    engine
        .write_by_name(root, "draft", Value::string("`x`"))
        .unwrap();
    assert_eq!(
        spans(&engine, root),
        vec![(0..1, Some(DIM)), (2..3, Some(DIM))]
    );
}
