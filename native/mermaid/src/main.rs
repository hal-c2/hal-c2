//! `hal-c2-mermaid`: reads one request as JSON on stdin and writes its result as JSON on
//! stdout. The MC (`HalC2.Mermaid`) runs it once per diagram it has not drawn before.
//!
//! The request is `{"source": "...", "format": "svg" | "text", "theme": "light" | "dark"}`.
//! The result is one of:
//!
//! - `{"status": "drawn", "kind", "svg", "width", "height"}`, or `{"status": "drawn",
//!   "kind", "text"}` for the terminal;
//! - `{"status": "unsupported", "kind", "reason"}` for a diagram type this does not draw
//!   (in that format);
//! - `{"status": "invalid", "kind", "reason", "line", "column"}` for a mistake in the
//!   source, `line` and `column` 1-based and null when unknown;
//! - `{"status": "failed", "kind", "reason"}` when a renderer gives up on the diagram.
//!
//! mmdr draws the SVG. It reads a broken flowchart leniently, dropping what it cannot
//! read, so flowcharts are first parsed by mmdflux, which says where the mistake is.
//! mmdflux also draws the terminal text for the types it knows.
//!
//! mmdr measures text with the system's fonts and keeps the face it found in
//! `$XDG_CACHE_HOME/mmdr`, so the first run on a machine is slow and the rest are not.

use std::io::{Read, Write};
use std::panic::{AssertUnwindSafe, catch_unwind};

use serde::Deserialize;
use serde_json::{Value, json};

/// The types drawn as SVG. mmdr knows more, but these are the ones checked to draw
/// legibly; block-beta, for one, loses its column spans.
const DRAWN: &[&str] = &[
    "flowchart",
    "flowchart-elk",
    "graph",
    "sequenceDiagram",
    "stateDiagram",
    "stateDiagram-v2",
    "gantt",
    "classDiagram",
    "classDiagram-v2",
    "erDiagram",
    "pie",
];

/// The types mmdflux draws as terminal text.
const TEXT: &[&str] = &[
    "flowchart",
    "graph",
    "sequenceDiagram",
    "stateDiagram",
    "stateDiagram-v2",
    "classDiagram",
    "classDiagram-v2",
];

/// Mermaid's other types: real diagrams this does not draw yet. Any other first word is
/// not a diagram at all.
const KNOWN: &[&str] = &[
    "architecture",
    "architecture-beta",
    "block",
    "block-beta",
    "C4Component",
    "C4Container",
    "C4Context",
    "C4Deployment",
    "C4Dynamic",
    "gitGraph",
    "info",
    "journey",
    "kanban",
    "mindmap",
    "packet",
    "packet-beta",
    "quadrantChart",
    "radar-beta",
    "requirementDiagram",
    "sankey",
    "sankey-beta",
    "timeline",
    "treemap",
    "treemap-beta",
    "xychart",
    "xychart-beta",
    "zenuml",
];

/// The types whose syntax mmdflux checks before mmdr draws them.
const CHECKED: &[&str] = &["flowchart", "graph"];

#[derive(Deserialize)]
struct Request {
    source: String,
    #[serde(default)]
    format: Format,
    #[serde(default)]
    theme: Theme,
}

#[derive(Deserialize, Default, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
enum Format {
    #[default]
    Svg,
    Text,
}

#[derive(Deserialize, Default, Clone, Copy)]
#[serde(rename_all = "lowercase")]
enum Theme {
    #[default]
    Light,
    Dark,
}

fn main() {
    let mut input = String::new();
    let result = match std::io::stdin().read_to_string(&mut input) {
        Ok(_) => match serde_json::from_str::<Request>(&input) {
            Ok(request) => draw(&request),
            Err(error) => failed(None, &format!("unreadable request: {error}")),
        },
        Err(error) => failed(None, &format!("unreadable request: {error}")),
    };
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(result.to_string().as_bytes());
    let _ = out.flush();
}

fn draw(request: &Request) -> Value {
    let Some(kind) = kind(&request.source) else {
        return invalid(None, "There is no diagram here.", None, None);
    };
    if !DRAWN.contains(&kind) && !KNOWN.contains(&kind) {
        return invalid(
            None,
            "This does not start with a Mermaid diagram type.",
            None,
            None,
        );
    }
    if !DRAWN.contains(&kind) {
        return unsupported(kind, &format!("{kind} diagrams cannot be drawn yet."));
    }
    // A renderer that panics on odd input fails this diagram, not the MC's request.
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let result = catch_unwind(AssertUnwindSafe(|| draw_kind(request, kind)))
        .unwrap_or_else(|_| failed(Some(kind), "The renderer could not draw this diagram."));
    std::panic::set_hook(previous);
    result
}

fn draw_kind(request: &Request, kind: &str) -> Value {
    if CHECKED.contains(&kind)
        && let Some(mistake) = flux_mistake(&request.source)
    {
        return mistake_value(kind, mistake);
    }
    let mut options = mermaid_rs_renderer::RenderOptions::modern();
    if let Theme::Dark = request.theme {
        options.theme = mermaid_rs_renderer::Theme::dark();
    }
    let svg = match mermaid_rs_renderer::render_strict(&request.source, options) {
        Ok(svg) => svg,
        Err(error) => return mistake_value(kind, mmdr_mistake(&error)),
    };
    match request.format {
        Format::Svg => {
            let (svg, width, height) = sized(&one_line_texts(&plain_colours(&svg)));
            json!({"status": "drawn", "kind": kind, "svg": svg, "width": width, "height": height})
        }
        Format::Text if TEXT.contains(&kind) => {
            match mmdflux::render_diagram(
                &request.source,
                mmdflux::OutputFormat::Text,
                &mmdflux::RenderConfig::default(),
            ) {
                Ok(text) => json!({"status": "drawn", "kind": kind, "text": text}),
                // mmdr read it, so it is not a mistake: mmdflux lacks something in it.
                Err(_) => unsupported(kind, "This diagram has no text drawing yet."),
            }
        }
        Format::Text => unsupported(kind, &format!("{kind} diagrams have no text drawing yet.")),
    }
}

/// The diagram's type: the first word after any front matter, blank lines and `%%`
/// comments or directives.
fn kind(source: &str) -> Option<&str> {
    let mut lines = source.lines().map(str::trim).peekable();
    if lines.peek() == Some(&"---") {
        lines.next();
        for line in lines.by_ref() {
            if line == "---" {
                break;
            }
        }
    }
    lines
        .find(|line| !line.is_empty() && !line.starts_with("%%"))
        .and_then(|line| line.split_whitespace().next())
        .map(|word| word.trim_end_matches([';', ':']))
        .filter(|word| !word.is_empty())
}

struct Mistake {
    reason: String,
    line: Option<u64>,
    column: Option<u64>,
}

fn mistake_value(kind: &str, mistake: Mistake) -> Value {
    invalid(Some(kind), &mistake.reason, mistake.line, mistake.column)
}

/// mmdflux's first error, without the position its message repeats.
fn flux_mistake(source: &str) -> Option<Mistake> {
    let report: Value = serde_json::from_str(&mmdflux::validate_diagram(source)).ok()?;
    if report["valid"] != Value::Bool(false) {
        return None;
    }
    let diagnostic = report["diagnostics"]
        .as_array()?
        .iter()
        .find(|d| d["severity"] == "error")?;
    let message = diagnostic["message"]
        .as_str()
        .unwrap_or("This diagram has a mistake.");
    Some(Mistake {
        reason: without_position(message),
        line: diagnostic["line"].as_u64(),
        column: diagnostic["column"].as_u64(),
    })
}

fn mmdr_mistake(error: &mermaid_rs_renderer::ParseError) -> Mistake {
    use mermaid_rs_renderer::ParseError as E;
    let (line, column) = match error {
        E::UnknownParticipant { line, .. } => (Some(*line), None),
        E::UnclosedSubgraph { opened_at } => (Some(*opened_at), None),
        E::UnexpectedToken { line, col, .. } | E::InvalidDirective { line, col, .. } => {
            (Some(*line), Some(*col))
        }
        _ => (None, None),
    };
    Mistake {
        reason: without_position(&error.to_string()),
        line: line.map(u64::from),
        column: column.map(u64::from),
    }
}

/// "Parse error at line 2, column 6: expected ..." becomes "expected ...": the line and
/// column travel as numbers.
fn without_position(message: &str) -> String {
    let message = message.trim();
    match message.split_once(": ") {
        Some((head, rest)) if head.contains("line") && !rest.is_empty() => rest.to_string(),
        _ => message.to_string(),
    }
}

fn unsupported(kind: &str, reason: &str) -> Value {
    json!({"status": "unsupported", "kind": kind, "reason": reason})
}

fn invalid(kind: Option<&str>, reason: &str, line: Option<u64>, column: Option<u64>) -> Value {
    json!({"status": "invalid", "kind": kind, "reason": reason, "line": line, "column": column})
}

fn failed(kind: Option<&str>, reason: &str) -> Value {
    json!({"status": "failed", "kind": kind, "reason": reason})
}

/// The root element's `width` and `height`.
/// The drawing with a width and height in pixels on its root, and those sizes. Some
/// types (pie) are written `width="100%"` with only a `viewBox`, which leaves a client
/// with no size to lay out; their size is the `viewBox`'s.
fn sized(svg: &str) -> (String, f64, f64) {
    let Some(start) = svg.find("<svg") else {
        return (svg.to_owned(), 0.0, 0.0);
    };
    let end = start + svg[start..].find('>').unwrap_or(svg.len() - start);
    let root = &svg[start..end];
    let (width, height) = (attribute(root, "width"), attribute(root, "height"));
    if width > 0.0 && height > 0.0 {
        return (svg.to_owned(), width, height);
    }
    let view: Vec<f64> = text_attribute(root, "viewBox")
        .unwrap_or_default()
        .split([' ', ','])
        .filter_map(|n| n.parse().ok())
        .collect();
    let [_, _, width, height] = view[..] else {
        return (svg.to_owned(), 0.0, 0.0);
    };
    let root = without_attributes(root, &["width", "height", "style"]);
    let root = root.replacen(
        "<svg",
        &format!("<svg width=\"{width}\" height=\"{height}\""),
        1,
    );
    (
        format!("{}{root}{}", &svg[..start], &svg[end..]),
        width,
        height,
    )
}

fn text_attribute<'a>(tag: &'a str, name: &str) -> Option<&'a str> {
    let key = format!(" {name}=\"");
    let rest = &tag[tag.find(&key)? + key.len()..];
    Some(&rest[..rest.find('"')?])
}

fn attribute(tag: &str, name: &str) -> f64 {
    text_attribute(tag, name)
        .and_then(|v| v.parse().ok())
        .unwrap_or(0.0)
}

/// mmdr writes some colours as `hsl(h, s%, l%)`, which Qt's SVG renderer (SVG Tiny 1.2)
/// reads as black. Every client draws hex, so they are written as hex here.
fn plain_colours(svg: &str) -> String {
    let mut out = String::with_capacity(svg.len());
    let mut rest = svg;
    while let Some(start) = rest.find("hsl(") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 4..];
        match after
            .find(')')
            .and_then(|end| Some((hsl_hex(&after[..end])?, end)))
        {
            Some((hex, end)) => {
                out.push_str(&hex);
                rest = &after[end + 1..];
            }
            None => {
                out.push_str("hsl(");
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// mmdr writes a label of several lines as one `<text>` holding a `<tspan x dy>` per
/// line. Qt's SVG renderer ignores a tspan's `x` and `dy`, running the lines together, so
/// each line becomes its own `<text>` at the place the tspan put it.
fn one_line_texts(svg: &str) -> String {
    let mut out = String::with_capacity(svg.len());
    let mut rest = svg;
    while let Some(start) = rest.find("<text ") {
        out.push_str(&rest[..start]);
        let element = &rest[start..];
        let Some(end) = element.find("</text>") else {
            break;
        };
        let whole = &element[..end + "</text>".len()];
        match split_lines(&element[..end]) {
            Some(lines) => out.push_str(&lines),
            None => out.push_str(whole),
        }
        rest = &element[whole.len()..];
    }
    out.push_str(rest);
    out
}

/// One `<text>` per tspan of `element` (a `<text ...>` without its close), or None when it
/// holds anything but tspans.
fn split_lines(element: &str) -> Option<String> {
    let open_end = element.find('>')?;
    let open = &element[..open_end];
    let mut body = &element[open_end + 1..];
    if !body.trim_start().starts_with("<tspan") {
        return None;
    }
    let mut x = attribute(open, "x");
    let mut y = attribute(open, "y");
    let base = without_attributes(open, &["x", "y"]);
    let mut out = String::new();
    while let Some(start) = body.find("<tspan") {
        if !body[..start].trim().is_empty() {
            return None;
        }
        let tag_end = start + body[start..].find('>')?;
        let tag = &body[start..tag_end];
        let close = tag_end + body[tag_end..].find("</tspan>")?;
        let content = &body[tag_end + 1..close];
        if content.contains('<') {
            return None;
        }
        if tag.contains(" x=\"") {
            x = attribute(tag, "x");
        }
        y += attribute(tag, "dy");
        let extra = without_attributes(&tag["<tspan".len()..], &["x", "dy"]);
        out.push_str(&format!(
            "{base} x=\"{x:.2}\" y=\"{y:.2}\"{extra}>{content}</text>"
        ));
        body = &body[close + "</tspan>".len()..];
    }
    body.trim().is_empty().then_some(out)
}

/// `tag` without the named attributes.
fn without_attributes(tag: &str, names: &[&str]) -> String {
    let mut tag = tag.to_owned();
    for name in names {
        let key = format!(" {name}=\"");
        if let Some(start) = tag.find(&key)
            && let Some(len) = tag[start + key.len()..].find('"')
        {
            tag.replace_range(start..start + key.len() + len + 1, "");
        }
    }
    tag
}

fn hsl_hex(args: &str) -> Option<String> {
    let parts: Vec<f64> = args
        .split(',')
        .map(|part| part.trim().trim_end_matches('%').trim().parse().ok())
        .collect::<Option<_>>()?;
    let [h, s, l] = parts[..] else { return None };
    let (s, l) = ((s / 100.0).clamp(0.0, 1.0), (l / 100.0).clamp(0.0, 1.0));
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let h = h.rem_euclid(360.0) / 60.0;
    let x = c * (1.0 - (h % 2.0 - 1.0).abs());
    let (r, g, b) = match h as u32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = l - c / 2.0;
    let byte = |v: f64| ((v + m) * 255.0).round().clamp(0.0, 255.0) as u8;
    Some(format!("#{:02x}{:02x}{:02x}", byte(r), byte(g), byte(b)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(source: &str, format: Format) -> Value {
        draw(&Request {
            source: source.into(),
            format,
            theme: Theme::Light,
        })
    }

    #[test]
    fn a_flowchart_is_drawn_with_its_size() {
        let result = request("flowchart LR\n  A[Start] --> B[End]\n", Format::Svg);
        assert_eq!(result["status"], "drawn");
        assert_eq!(result["kind"], "flowchart");
        assert!(result["svg"].as_str().unwrap().contains("<svg"));
        assert!(result["width"].as_f64().unwrap() > 0.0);
        assert!(result["height"].as_f64().unwrap() > 0.0);
    }

    #[test]
    fn every_type_drawn_has_its_size() {
        for (kind, source) in [
            ("graph", "graph TD;\n  A-->B\n"),
            (
                "sequenceDiagram",
                "sequenceDiagram\n  A->>B: hi\n  B-->>A: hello\n",
            ),
            (
                "stateDiagram-v2",
                "stateDiagram-v2\n  [*] --> Idle\n  Idle --> [*]\n",
            ),
            (
                "gantt",
                "gantt\n  dateFormat YYYY-MM-DD\n  section Build\n  Draw :a1, 2026-01-01, 3d\n",
            ),
            ("classDiagram", "classDiagram\n  Animal <|-- Dog\n"),
            ("erDiagram", "erDiagram\n  CUSTOMER ||--o{ ORDER : places\n"),
            ("pie", "pie title Pets\n  \"Dogs\" : 9\n  \"Cats\" : 2\n"),
        ] {
            let result = request(source, Format::Svg);
            assert_eq!(result["status"], "drawn", "{kind}: {result}");
            assert_eq!(result["kind"], kind);
            assert!(!result["svg"].as_str().unwrap().contains("hsl("), "{kind}");
            assert!(result["width"].as_f64() > Some(0.0), "{kind} has no width");
            assert!(
                result["height"].as_f64() > Some(0.0),
                "{kind} has no height"
            );
        }
    }

    #[test]
    fn an_unclosed_bracket_is_a_mistake_with_its_place() {
        let result = request(
            "flowchart TD\n    A[Start --> B\n    B --> C\n",
            Format::Svg,
        );
        assert_eq!(result["status"], "invalid");
        assert_eq!(result["kind"], "flowchart");
        assert_eq!(result["line"], 2);
        assert!(result["column"].as_u64().is_some());
        assert!(!result["reason"].as_str().unwrap().contains("line 2"));
    }

    #[test]
    fn a_type_not_drawn_says_so() {
        let result = request("block-beta\n  columns 2\n  A B\n", Format::Svg);
        assert_eq!(result["status"], "unsupported");
        assert_eq!(result["kind"], "block-beta");
        assert_eq!(result["reason"], "block-beta diagrams cannot be drawn yet.");
    }

    #[test]
    fn a_drawing_sized_only_by_its_view_box_gets_its_size() {
        let (svg, width, height) = sized(
            r#"<svg xmlns="x" width="100%" viewBox="0 0 409.5 360" style="max-width: 409.5px;"><rect/></svg>"#,
        );
        assert_eq!((width, height), (409.5, 360.0));
        assert_eq!(
            svg,
            r#"<svg width="409.5" height="360" xmlns="x" viewBox="0 0 409.5 360"><rect/></svg>"#
        );

        let fixed = r#"<svg width="10" height="20"><rect/></svg>"#;
        assert_eq!(sized(fixed), (fixed.to_owned(), 10.0, 20.0));
    }

    #[test]
    fn words_that_are_no_diagram_are_a_mistake() {
        let result = request("just some words\n", Format::Svg);
        assert_eq!(result["status"], "invalid");
        assert_eq!(result["kind"], Value::Null);
    }

    #[test]
    fn nothing_to_draw_is_a_mistake() {
        let result = request("\n%% only a comment\n", Format::Svg);
        assert_eq!(result["status"], "invalid");
        assert_eq!(result["kind"], Value::Null);
    }

    #[test]
    fn the_terminal_gets_text_where_there_is_one() {
        let result = request("flowchart LR\n  A[Start] --> B[End]\n", Format::Text);
        assert_eq!(result["status"], "drawn");
        assert!(result["text"].as_str().unwrap().contains("Start"));

        let gantt = "gantt\n  dateFormat YYYY-MM-DD\n  section S\n  T :a1, 2026-01-01, 3d\n";
        assert_eq!(request(gantt, Format::Text)["status"], "unsupported");
    }

    #[test]
    fn the_type_comes_after_front_matter_and_comments() {
        assert_eq!(
            kind("---\ntitle: x\n---\n%%{init: {}}%%\n\ngraph LR\n"),
            Some("graph")
        );
        assert_eq!(kind("  sequenceDiagram\n"), Some("sequenceDiagram"));
        assert_eq!(kind(""), None);
    }

    #[test]
    fn hsl_becomes_hex() {
        assert_eq!(hsl_hex("0, 100%, 50%").as_deref(), Some("#ff0000"));
        assert_eq!(hsl_hex("120.0, 100.0%, 25.0%").as_deref(), Some("#008000"));
        assert_eq!(hsl_hex("0, 0%, 100%").as_deref(), Some("#ffffff"));
        assert_eq!(
            plain_colours(r##"<rect fill="hsl(240, 100%, 50%)"/><g fill="hsl(bad)"/>"##),
            r##"<rect fill="#0000ff"/><g fill="hsl(bad)"/>"##
        );
    }

    #[test]
    fn each_line_of_a_label_is_its_own_text() {
        assert_eq!(
            one_line_texts(
                r##"<g><text x="10.00" y="20.00" fill="#000"><tspan x="10.00" dy="0.00" font-weight="600">one</tspan><tspan x="10.00" dy="21.00">two</tspan></text></g>"##
            ),
            r##"<g><text fill="#000" x="10.00" y="20.00" font-weight="600">one</text><text fill="#000" x="10.00" y="41.00">two</text></g>"##
        );
    }

    #[test]
    fn a_text_without_tspans_is_left_alone() {
        let svg = r##"<text x="1" y="2">plain</text><text x="1" y="2"><tspan>a</tspan>b</text>"##;
        assert_eq!(one_line_texts(svg), svg);
    }

    #[test]
    fn a_dark_theme_is_drawn_too() {
        let result = draw(&Request {
            source: "flowchart LR\n  A --> B\n".into(),
            format: Format::Svg,
            theme: Theme::Dark,
        });
        assert_eq!(result["status"], "drawn");
    }
}
