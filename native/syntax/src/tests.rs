use super::*;

fn runs(language: &str, code: &str, theme: Theme) -> Vec<(String, u32)> {
    let units: Vec<u16> = code.encode_utf16().collect();
    highlight(language, code)
        .into_iter()
        .filter(|span| span.theme == theme)
        .map(|span| {
            let piece = &units[span.start as usize..(span.start + span.len) as usize];
            (String::from_utf16_lossy(piece), span.color)
        })
        .collect()
}

fn colour_of(language: &str, code: &str, piece: &str, theme: Theme) -> Option<u32> {
    runs(language, code, theme).into_iter().find(|(text, _)| text == piece).map(|(_, color)| color)
}

#[test]
fn the_languages_replies_name_are_known() {
    for language in [
        "ts", "tsx", "js", "jsx", "py", "sh", "bash", "ex", "exs", "elixir", "heex", "qml", "rs", "json", "yaml",
        "toml", "go", "c", "cpp", "java", "kotlin", "swift", "sql", "html", "css", "md", "diff", "dockerfile",
        "ruby", "lua", "zig", "nix", "Rust", "TypeScript",
    ] {
        assert!(Highlighter::for_language(language).is_some(), "{language} has no syntax");
    }
}

#[test]
fn plain_text_and_unknown_languages_are_not_coloured() {
    for language in ["", "text", "plain", "mermaid", "no-such-language"] {
        assert!(Highlighter::for_language(language).is_none(), "{language} has a syntax");
        assert!(highlight(language, "let x = 1;\n").is_empty());
    }
}

#[test]
fn keywords_strings_and_comments_take_the_pierre_colours() {
    let code = "const greeting = \"hi\"; // hello\n";
    // Pierre's keyword colour, dark and light.
    assert_eq!(colour_of("ts", code, "const", Theme::Dark), Some(0xffff678d));
    assert_eq!(colour_of("ts", code, "const", Theme::Light), Some(0xffd32a61));
    assert!(runs("ts", code, Theme::Dark).iter().any(|(text, color)| text.contains("hi") && *color == 0xff5ecc71));
    assert!(runs("ts", code, Theme::Dark).iter().any(|(text, _)| text.contains("hello")));
}

#[test]
fn elixir_and_qml_are_coloured() {
    let elixir = "defmodule Cart do\n  def total(items), do: Enum.sum(items)\nend\n";
    assert!(colour_of("ex", elixir, "defmodule", Theme::Dark).is_some());
    let qml = "import QtQuick\nRectangle {\n    width: 10\n}\n";
    assert!(!runs("qml", qml, Theme::Dark).is_empty());
}

#[test]
fn reading_line_by_line_matches_reading_at_once() {
    let code = "/* a\n   comment */\nfn main() {\n    let s = \"x\";\n}\n";
    let mut whole = Vec::new();
    Highlighter::for_language("rs").unwrap().feed(code, |span| whole.push(span));
    let mut parts = Vec::new();
    let mut highlighter = Highlighter::for_language("rs").unwrap();
    for line in code.split_inclusive('\n') {
        highlighter.feed(line, |span| parts.push(span));
    }
    assert_eq!(whole, parts);
}

#[test]
fn offsets_count_utf16_units() {
    let code = "// 🎉 é\nlet x = 1\n";
    let units: Vec<u16> = code.encode_utf16().collect();
    let spans = highlight("rs", code);
    let span = spans.iter().find(|span| span.theme == Theme::Dark && span.start >= 8).unwrap();
    let piece = String::from_utf16_lossy(&units[span.start as usize..(span.start + span.len) as usize]);
    assert_eq!(piece, "let");
}

#[test]
fn a_line_too_long_stops_the_colouring() {
    let code = format!("let a = 1;\nlet b = \"{}\";\nlet c = 2;\n", "x".repeat(MAX_LINE_BYTES));
    let mut highlighter = Highlighter::for_language("rs").unwrap();
    let mut spans = Vec::new();
    highlighter.feed(&code, |span| spans.push(span));
    assert!(highlighter.stopped());
    assert!(spans.iter().all(|span| span.start < 11));
    assert!(!spans.is_empty());
}

#[test]
fn files_are_known_by_their_names() {
    for path in ["src/app.ts", "lib/cart.ex", "Main.qml", "Dockerfile", "Makefile", "a/b/c.rs", "x.heex"] {
        assert!(Highlighter::for_path(path).is_some(), "{path} has no syntax");
    }
    assert!(Highlighter::for_path("notes.txt").is_none());
}



/// Rewrites SYNTAXES-NOTICE.md, the licences of the syntaxes two-face bundles,
/// for the Open source licenses page: `cargo test write_notice -- --ignored`.
#[test]
#[ignore]
fn write_notice() {
    let notice = two_face::acknowledgement::listing().to_md();
    // Its themes are not used.
    let notice = notice.split("\n# Themes").next().unwrap_or_default();
    std::fs::write(concat!(env!("CARGO_MANIFEST_DIR"), "/SYNTAXES-NOTICE.md"), notice).unwrap();
}
