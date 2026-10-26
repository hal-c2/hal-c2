//! The real Markdown brick, headless: what its rich text draws
//! (features/timeline/markdown.feature).

use hal_c2_shell::qml::Roots;
use ljos::item::{CharFormatSpan, char_formats};
use ljos::prelude::{ColorScheme, ObjectId, Value};

use crate::{Hub, Window};

const PROBE: &str = r#"
import QtQuick
import HalC2.Shell
import HalC2.Bricks

Item {
    width: 700
    height: 400
    property color link: Theme.link
    property color text: md.textColor
    property color heading: md.headingColor
    // The first rich text segment.
    readonly property var prose: find(md)
    function find(item) {
        if (item.textFormat === TextEdit.RichText && item.hoveredLink !== undefined)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const found = find(item.children[i]);
            if (found)
                return found;
        }
        return null;
    }

    Markdown {
        id: md
        width: 600
        text: MARKDOWN
    }
}
"#;

/// The checkout's bricks and the probe showing `markdown`, compiled as the
/// app compiles them.
fn probe(hub: &Hub, markdown: &str) -> (ObjectId, Window) {
    let dir = tempfile::tempdir().expect("a directory for the probe");
    let probe = PROBE.replace("MARKDOWN", &serde_json::to_string(markdown).unwrap());
    std::fs::write(dir.path().join("MarkdownProbe.qml"), probe).expect("the probe");
    let mut dirs = Roots::checkout().dirs().expect("the roots are there");
    dirs.push(dir.path().to_path_buf());
    let snapshot = ljos::engine();
    hal_c2_shell::register(&snapshot);
    let paths: Vec<&std::path::Path> = dirs.iter().map(|p| p.as_path()).collect();
    let compiled = ljos::dev::compile_quiet(&paths, Some(&snapshot)).expect("the bricks compile");
    hub.show(compiled.source, "MarkdownProbe")
}

fn rgba(hub: &Hub, root: ObjectId, name: &str) -> [u8; 4] {
    match hub.engine.read_by_name(root, name) {
        Value::Color(c) => c.to_rgba8(),
        other => panic!("{name} is a colour: {other:?}"),
    }
}

/// How the first rich text segment is drawn, stretch by stretch.
fn drawn(hub: &Hub, root: ObjectId) -> Vec<CharFormatSpan> {
    let Value::Object(prose) = hub.engine.read_by_name(root, "prose") else {
        panic!("the brick drew no rich text");
    };
    char_formats(&hub.engine, prose, 0..usize::MAX).expect("the prose is an editor")
}

/// Each link of the prose as drawn: its address, colour and underline.
fn links(hub: &Hub, root: ObjectId) -> Vec<(String, [u8; 4], bool)> {
    drawn(hub, root)
        .into_iter()
        .filter_map(|span| {
            let link = span.link?;
            Some((link.to_string(), span.color.to_rgba8(), span.font.underline))
        })
        .collect()
}

fn system_dark(hub: &Hub, dark: bool) {
    ljos::testing::update_system_prefs(&hub.engine, |p| {
        p.color_scheme = if dark {
            ColorScheme::Dark
        } else {
            ColorScheme::Light
        }
    });
    hub.advance(0);
}

// A link in a reply is in the theme's link colour and not underlined, in
// either appearance, as desktop-qt draws it: a pasted address and a named one.
#[test]
fn links_take_the_themes_link_colour() {
    let hub = Hub::new();
    let (root, _window) = probe(
        &hub,
        "See [the PR](https://example.com/pull/135) or https://example.com/issues/1 now.",
    );
    let mut seen = Vec::new();
    for dark in [false, true] {
        system_dark(&hub, dark);
        let link = rgba(&hub, root, "link");
        assert_ne!(
            link,
            rgba(&hub, root, "text"),
            "a link stands out from the text"
        );
        let drawn = links(&hub, root);
        let addresses: Vec<&str> = drawn.iter().map(|(href, ..)| href.as_str()).collect();
        assert_eq!(
            addresses,
            [
                "https://example.com/pull/135",
                "https://example.com/issues/1"
            ]
        );
        for (href, color, underline) in &drawn {
            assert_eq!(
                *color, link,
                "{href} in the theme's link colour (dark: {dark})"
            );
            assert!(!underline, "{href} is not underlined");
        }
        seen.push(link);
    }
    assert_ne!(seen[0], seen[1], "each appearance has its own link colour");
}

// A heading is set larger, bolder and in the heading colour, and inline code
// is small on its fill, as desktop-qt draws them.
#[test]
fn headings_and_inline_code_keep_their_look() {
    let hub = Hub::new();
    let (root, _window) = probe(&hub, "## Heading two\n\nSome `code` here.");
    let spans = drawn(&hub, root);
    let at = |byte: usize| {
        spans
            .iter()
            .find(|s| s.range.contains(&byte))
            .expect("a stretch at the byte")
    };
    let heading = at(0);
    assert_eq!(heading.font.pixel_size, 18, "{heading:?}");
    assert!(heading.font.weight >= 600, "{heading:?}");
    assert_eq!(heading.color.to_rgba8(), rgba(&hub, root, "heading"));
    let body = at(spans.last().unwrap().range.end - 1);
    assert_eq!(body.font.pixel_size, 14, "{body:?}");
    assert!(body.background.is_none());
    let code = spans
        .iter()
        .find(|s| s.background.is_some() && s.font.pixel_size == 12)
        .unwrap_or_else(|| panic!("inline code on its fill: {spans:?}"));
    assert_eq!(code.color.to_rgba8(), rgba(&hub, root, "heading"));
}
