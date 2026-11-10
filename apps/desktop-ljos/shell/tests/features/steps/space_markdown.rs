//! Markdown drawn by the SpacePage brick, Mermaid, tables, code, lists, and charts (features/space/markdown.feature, visualize.feature), ported from desktop-qt's SpaceSteps.cpp. Shared helpers live in
//! space.rs, the MC's side in space_fake.rs.

use hal_c2_shell::controller;
use ljos::prelude::{Engine, ObjectId, Value as JsValue};
use serde_json::{Value, json};

use crate::brick::{Brick, Shown};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::mermaid;
use crate::steps::space::{
    act, act_on_page, column, current, describe, expect_shown, find_block, given, given_block,
    given_page, id_of_page, look, look_at_page, rows_of, with_space,
};
use crate::steps::space_fake as fake;
use crate::world::World;
use crate::{expect, fail};

/// A table the page does not model, kept as written.
const TABLE: &str = "| Step | Owner |\n| ---- | ----- |\n|   MC | Ada   |";
/// A table and a code block: drawn by the chat's Markdown while read, edited
/// as their source (#854).
const MODELLED_TABLE: &str = "| Step | Owner |\n| ---- | ----- |\n| MC   | Ada   |";
const CODE: &str = "run()\n    done()";
const ALIGNED_TABLE: &str =
    "| Step | Owner | Done |\n| :--- | :---: | ---: |\n| **MC** | a \\| b | 3 |";
const LINKING: &str =
    "[the docs](https://example.com/docs) hold ![Signups](https://example.com/signups.png)";
const FROM_THIS_PAGE: &str = "Numbers from this page";

/// The diagram a page holds, as its block's text is now.
#[derive(Default)]
struct Diagram {
    source: String,
}

/// Mermaid diagrams on a page: imported as the MC reads a "mermaid" fence (a
/// code block in "mermaid" holding the bare source), and drawn by the page
/// through the fake renderer (mermaid.rs).
fn diagram(kind: &str) -> Option<&'static str> {
    Some(match kind {
        "flowchart" => mermaid::FLOWCHART,
        "graph" => "graph TD\n  Cart --> Pay",
        "sequenceDiagram" => "sequenceDiagram\n  Cart->>Pay: order",
        "stateDiagram-v2" => "stateDiagram-v2\n  [*] --> Cart",
        "gantt" => "gantt\n  title Launch\n  section Build\n  MC :a1, 2026-11-01, 3d",
        "block-beta" => "block-beta\n  columns 2\n  Cart Pay",
        _ => return None,
    })
}

/// Inline formatting (markdown.feature): a paragraph is drawn by the chat's
/// Markdown brick, each kind of formatting as the brick writes it, with none
/// of its markers left.
fn inline(formatting: &str) -> Option<(&'static str, &'static [&'static str])> {
    Some(match formatting {
        "bold and italic text" => ("**Bold** and _italic_", &["<b>Bold</b>", "<i>italic</i>"]),
        "struck-through text" => ("~~struck~~", &["<s>struck</s>"]),
        "inline code" => ("`mix test`", &["class=\"c\"", "mix test"]),
        "a link with a title" => (
            "a [link](https://example.com \"Title\")",
            &["href=\"https://example.com\">link</a>"],
        ),
        "an autolinked address and a bare www link" => (
            "<https://example.com> and www.example.com",
            &[
                "href=\"https://example.com\">https://example.com</a>",
                "href=\"http://www.example.com\">www.example.com</a>",
            ],
        ),
        _ => return None,
    })
}

/// Lists (markdown.feature): each item is a block the brick draws as a list
/// of one, its marker the one its depth takes, nested by the indent before it.
struct Nested {
    kind: &'static str,
    text: &'static str,
    depth: i64,
    /// What the brick draws it in.
    list: &'static str,
}

const NESTED: [Nested; 5] = [
    Nested {
        kind: "bullet",
        text: "Plan the release",
        depth: 0,
        list: "<ul style=\"-qt-list-indent:0;list-style-type:disc;",
    },
    Nested {
        kind: "numbered",
        text: "Tag",
        depth: 1,
        list: "<ol style=\"-qt-list-indent:0;list-style-type:decimal;",
    },
    Nested {
        kind: "numbered",
        text: "Ship",
        depth: 1,
        list: "<ol start=\"2\" style=\"-qt-list-indent:0;list-style-type:decimal;",
    },
    Nested {
        kind: "bullet",
        text: "Notes",
        depth: 2,
        list: "<ul style=\"-qt-list-indent:0;list-style-type:circle;",
    },
    Nested {
        kind: "bullet",
        text: "Announce",
        depth: 0,
        list: "<ul style=\"-qt-list-indent:0;list-style-type:disc;",
    },
];

/// The page as the Space view draws it, from the rows the MC's blocks make.
fn draw_page(world: &mut World) -> Outcome<Brick> {
    Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nSpacePage { width: 900; height: 700 }\n",
        900.0,
        700.0,
    )
}

/// Draws the page and keeps it as the world's brick.
fn show_page(world: &mut World) -> Outcome<Brick> {
    let brick = draw_page(world)?;
    world.part::<Shown>().0 = Some(brick);
    Ok(brick)
}

fn kept_page(world: &mut World) -> Outcome<Brick> {
    match world.part::<Shown>().0 {
        Some(brick) => Ok(brick),
        None => fail!("no page is drawn"),
    }
}

fn find_editor(world: &World, brick: Brick, item: ObjectId, name: &str) -> Option<ObjectId> {
    brick.find_in(world, item, name).ok().flatten()
}

fn find_on_page(world: &World, brick: Brick, name: &str) -> Option<ObjectId> {
    brick
        .root(world)
        .and_then(|root| find_editor(world, brick, root, name))
}

fn visible(world: &World, item: ObjectId) -> bool {
    world.engine().read_by_name(item, "visible") == JsValue::Bool(true)
}

fn string_of(world: &World, item: ObjectId, name: &str) -> String {
    match world.engine().read_by_name(item, name) {
        JsValue::String(s) => s.as_str().to_owned(),
        JsValue::Undefined | JsValue::Null => String::new(),
        other => world.engine().to_js_string(&other).to_string(),
    }
}

fn number_of(world: &World, item: ObjectId, name: &str) -> f64 {
    match world.engine().read_by_name(item, name) {
        JsValue::Int(n) => f64::from(n),
        JsValue::Real(r) => r,
        _ => f64::NAN,
    }
}

/// The family (the head of Ljós's CSS-like list) and pixel size of an item's font.
fn font_of(world: &World, item: ObjectId) -> (String, f64) {
    match world.engine().read_by_name(item, "font") {
        JsValue::Font(f) => (
            f.family
                .split(',')
                .next()
                .unwrap_or_default()
                .trim()
                .trim_matches('"')
                .to_owned(),
            f.pixel_size as f64,
        ),
        _ => (String::new(), 0.0),
    }
}

/// The theme's code face: Ljós's CSS-like family list.
fn mono_face(world: &World) -> String {
    let mono = text(&world.state("theme")["fontMono"]);
    if mono.is_empty() {
        "monospace".to_owned()
    } else {
        mono
    }
}

/// Whether `family` (an item's resolved head) is one of the list's.
fn in_face(mono: &str, family: &str) -> bool {
    mono.split(',').any(|name| name.trim().trim_matches('"') == family)
}

fn code_size(world: &World) -> f64 {
    world.state("theme")["fontSizes"]["code"]
        .as_f64()
        .unwrap_or(0.0)
}

/// The item `name` + `said` of the drawn page; a block's source is
/// "spaceBlockEditor:", its text drawn as Markdown "spaceBlockText:".
fn shown_of(world: &mut World, brick: Brick, name: &str, said: &str) -> Outcome<ObjectId> {
    let wanted = format!("{name}{said}");
    let looking = wanted.clone();
    world.wait_for_with(
        move |w| find_on_page(w, brick, &looking).is_some(),
        |w| format!("the page to show the block {said:?}; {}", describe(w)),
    )?;
    match find_on_page(world, brick, &wanted) {
        Some(item) => Ok(item),
        None => fail!("the page no longer shows {wanted}"),
    }
}

fn editor_of(world: &mut World, brick: Brick, said: &str) -> Outcome<ObjectId> {
    shown_of(world, brick, "spaceBlockEditor:", said)
}

/// The grid of a drawn table, or the box of a drawn code block, once it is laid out.
fn drawn_part(world: &mut World, brick: Brick, said: &str, part: &str) -> Outcome<ObjectId> {
    let drawn = shown_of(world, brick, "spaceBlockText:", said)?;
    let wanted = part.to_owned();
    let laid_out = move |w: &World| {
        find_editor(w, brick, drawn, &wanted).filter(|&found| {
            let height = number_of(w, found, "height");
            visible(w, found) && height > 0.0 && number_of(w, drawn, "height") >= height
        })
    };
    world.wait_for_with(
        {
            let laid_out = laid_out.clone();
            move |w| laid_out(w).is_some()
        },
        |w| format!("{said:?} to draw {part}; {}", describe(w)),
    )?;
    match laid_out(world) {
        Some(found) => Ok(found),
        None => fail!("{said:?} no longer draws {part}"),
    }
}

/// Clicks `item` at (fx, fy) of its size.
fn click(world: &mut World, brick: Brick, item: ObjectId, fx: f64, fy: f64) -> Outcome {
    let (x, y) = brick.at(world, item, fx, fy)?;
    world.click_at(x, y)
}

fn focused(world: &World, item: ObjectId) -> bool {
    world.engine().read_by_name(item, "activeFocus") == JsValue::Bool(true)
}

fn name_of(engine: &Engine, item: ObjectId) -> String {
    match engine.read_by_name(item, "objectName") {
        JsValue::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

/// The object named `name` among `scope`'s children (a highlighter is no item).
fn find_child(world: &World, scope: ObjectId, name: &str) -> Option<ObjectId> {
    for child in world.engine().children(scope) {
        if name_of(world.engine(), child) == name {
            return Some(child);
        }
        if let Some(found) = find_child(world, child, name) {
            return Some(found);
        }
    }
    None
}

/// The visible blocks of a page, top to bottom, each as the lines of Markdown it shows.
fn shown_markdown(world: &World, brick: Brick) -> Outcome<Vec<String>> {
    let Some(root) = brick.root(world) else {
        return Ok(Vec::new());
    };
    let engine = world.engine();
    let mut blocks = Vec::new();
    collect_blocks(engine, root, &mut blocks);
    let mut placed = Vec::new();
    for block in blocks {
        placed.push((brick.at(world, block, 0.0, 0.0)?.1, block));
    }
    placed.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut lines = Vec::new();
    for (_, block) in placed {
        let said = string_of(world, block, "text");
        let shown = |name: &str| {
            find_editor(world, brick, block, &format!("{name}{said}"))
                .filter(|&item| visible(world, item))
                .map(|item| string_of(world, item, "text"))
                .unwrap_or_default()
        };
        let tick = find_editor(world, brick, block, &format!("spaceTick:{said}"));
        let ticked = match tick {
            Some(tick) if visible(world, tick) => {
                if engine.read_by_name(block, "checked") == JsValue::Bool(true) {
                    "- [x] "
                } else {
                    "- [ ] "
                }
            }
            _ => "",
        };
        let mut own = Vec::new();
        let above = shown("spaceMarkdownAbove:");
        if !above.is_empty() {
            own.push(above);
        }
        let middle = format!(
            "{}{ticked}{}{}{}",
            shown("spaceMarkdownLead:"),
            shown("spaceBlockEditor:"),
            shown("spaceBlockText:"),
            shown("spaceMarkdownTail:")
        );
        own.extend(middle.split('\n').map(str::to_owned));
        let below = shown("spaceMarkdownBelow:");
        if !below.is_empty() {
            own.push(below);
        }
        let callout = string_of(world, block, "kind") == "callout";
        for line in own {
            if line.is_empty() {
                continue;
            }
            lines.push(if callout { format!("> {line}") } else { line });
        }
    }
    Ok(lines)
}

fn collect_blocks(engine: &Engine, item: ObjectId, out: &mut Vec<ObjectId>) {
    if name_of(engine, item).starts_with("spaceBlock:")
        && engine.read_by_name(item, "visible") == JsValue::Bool(true)
    {
        out.push(item);
    }
    for child in engine.children(item) {
        collect_blocks(engine, child, out);
    }
}

/// The cells of the aligned table as the Markdown brick holds them: a
/// header, rows, and an alignment a column.
fn grid_spec(world: &mut World) -> Outcome<Value> {
    let page = draw_page(world)?;
    let grid = drawn_part(world, page, ALIGNED_TABLE, "markdownTable")?;
    let spec = world.engine().read_by_name(grid, "spec");
    Ok(hal_c2_shell::json::from_value(world.engine(), &spec))
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .map(|list| list.iter().map(text).collect())
        .unwrap_or_default()
}

/// A code block, with its language when it has one.
fn given_code(world: &mut World, title: &str, language: &str) -> Outcome {
    let page = given_page(world, title, "")?;
    given(
        world,
        "block.insert",
        json!({"pageId": page, "kind": "code", "text": CODE, "language": language}),
    )?;
    Ok(())
}

/// The paragraph `said` drawn as prose, never trusted, its source not shown.
fn prose(world: &mut World, said: &str) -> Outcome<ObjectId> {
    let brick = kept_page(world)?;
    let drawn = shown_of(world, brick, "spaceBlockText:", said)?;
    expect!(
        find_on_page(world, brick, &format!("spaceBlockEditor:{said}")).is_none(),
        "the paragraph shows its source"
    );
    expect!(
        world.engine().read_by_name(drawn, "trusted") != JsValue::Bool(true),
        "the paragraph is drawn trusted"
    );
    match find_editor(world, brick, drawn, "markdownProse") {
        Some(html) => Ok(html),
        None => fail!("the paragraph is not drawn as prose"),
    }
}

/// Imports a page holding `source`, then `after` paragraphs, and shows it.
fn import_diagram(world: &mut World, source: &str, after: usize) -> Outcome {
    let mut markdown =
        format!("# Ordering\n\nHow an order is paid:\n\n```mermaid\n{source}\n```\n");
    for step in 1..=after {
        markdown.push_str(&format!("\nStep {step} of paying.\n"));
    }
    world.part::<Diagram>().source = source.to_owned();
    let space = current(world)?;
    look(world, &space)?;
    act(
        world,
        "space.page.importMarkdown",
        json!({"markdown": markdown}),
    )?;
    let wanted = source.to_owned();
    expect_shown(world, "the imported page", move |w| {
        column(w, "blocks", "text").contains(&wanted)
    })?;
    let page = show_page(world)?;
    // The page asks the MC to draw it once laid out: answer that first.
    world.sync_until_with(
        move |w| {
            !mermaid::drawn(w, page).is_empty()
                || mermaid::shown(w, page, "mermaidStatus")
                    .iter()
                    .any(|&note| !string_of(w, note, "text").starts_with("Drawing the diagram"))
        },
        move |w| {
            let asked = w.mc.calls.iter().filter(|c| c.method == "mermaid.render").count();
            let notes: Vec<String> = mermaid::shown(w, page, "mermaidStatus")
                .iter()
                .map(|&note| string_of(w, note, "text"))
                .collect();
            format!("the diagram to be drawn or refused (asked {asked}, notes {notes:?})")
        },
    )
}

fn diagram_source(world: &mut World) -> String {
    world.part::<Diagram>().source.clone()
}

fn source_editor(world: &World, brick: Brick, source: &str) -> Option<ObjectId> {
    find_on_page(world, brick, &format!("spaceBlockEditor:{source}"))
}

/// Waits, answering what the page asks the MC (`mermaid.render`), until
/// `count` diagrams are drawn.
fn wait_drawn(world: &mut World, brick: Brick, count: usize, what: &str) -> Outcome {
    world.sync_until_with(
        move |w| mermaid::drawn(w, brick).len() == count,
        |w| format!("{what}; {}", describe(w)),
    )
}

/// A chart with one series, as the MC stores it.
fn chart_of(kind: &str, title: &str, source: &str, points: &[(String, i64)]) -> Value {
    let labels: Vec<&str> = points.iter().map(|(label, _)| label.as_str()).collect();
    let values: Vec<i64> = points.iter().map(|(_, value)| *value).collect();
    json!({
        "type": kind,
        "title": title,
        "labels": labels,
        "series": [{"name": title, "values": values}],
        "request": "signups",
        "source": source,
    })
}

fn given_chart(world: &mut World, page: &str, chart: Value) -> Outcome {
    let asked = given_page(world, page, "")?;
    fake::fake(&mut world.mc).asked = asked.clone();
    fake::fake(&mut world.mc).chart = chart;
    given(
        world,
        "block.visualize",
        json!({"pageId": asked, "request": "/visualize signups"}),
    )?;
    fake::fake(&mut world.mc).chart = json!({});
    Ok(())
}

fn signups(first: &str, a: i64, next: &str, b: i64) -> Value {
    chart_of(
        "bar",
        "Signups",
        FROM_THIS_PAGE,
        &[(first.to_owned(), a), (next.to_owned(), b)],
    )
}

/// The chart row the open page shows, or none.
fn shown_chart(world: &World) -> Value {
    rows_of(world, "blocks")
        .into_iter()
        .find(|row| row.get("kind").map(text).as_deref() == Some("chart"))
        .map(Value::Object)
        .unwrap_or_else(|| json!({}))
}

fn has_chart(world: &World) -> bool {
    shown_chart(world)
        .as_object()
        .is_some_and(|c| !c.is_empty())
}

fn drawing(world: &World) -> bool {
    world.state("space")["drawing"].as_bool().unwrap_or(false)
}

fn asked_page(world: &mut World) -> String {
    fake::fake(&mut world.mc).asked.clone()
}

/// A toast whose title starts with `start`.
fn told_starting(world: &World, start: &str) -> bool {
    world.state("toasts")["items"]
        .as_array()
        .is_some_and(|items| {
            items
                .iter()
                .any(|item| text(&item["title"]).starts_with(start))
        })
}

/// The second client's window (space.rs's `watch` opened it).
fn in_second(world: &mut World, action: &str, payload: Value) -> Outcome {
    let Some(window) = controller::windows(world.engine()).get(1).cloned() else {
        fail!("no second client is watching")
    };
    let engine = world.engine().clone();
    let Some(bridge) = controller::window_bridge(&engine, &window) else {
        fail!("the second client's window closed")
    };
    bridge.dispatch(&engine, action, payload);
    if let Some(main) = controller::window_bridge(&engine, controller::MAIN) {
        main.set_front(&engine);
    }
    world.pump()
}

fn chart_numbers(chart: &Value) -> (Vec<String>, Vec<f64>) {
    let values = chart["series"][0]["values"]
        .as_array()
        .map(|list| list.iter().filter_map(Value::as_f64).collect())
        .unwrap_or_default();
    (strings(&chart["labels"]), values)
}

pub fn register(steps: &mut Steps) {
    register_markdown(steps);
    register_mermaid(steps);
    register_charts(steps);
}

fn register_markdown(steps: &mut Steps) {
    steps.step(
        &format!("the page {Q} holds a table the page does not model yet"),
        |world, c, _| given_block(world, &c[0], "raw", TABLE, false),
    );
    steps.step(
        &format!("the page {Q} holds a table and a code block"),
        |world, c, _| {
            given_block(world, &c[0], "table", MODELLED_TABLE, false)?;
            given_block(world, &c[0], "code", CODE, false)
        },
    );
    steps.step(
        "the user edits the table and the code each as its source, exactly as written",
        |world, _, _| {
            let page = draw_page(world)?;
            let mono = mono_face(world);
            for (said, part) in [(MODELLED_TABLE, "markdownTable"), (CODE, "codeText")] {
                // A click on what is drawn, clear of its buttons, edits it.
                let drawn = drawn_part(world, page, said, part)?;
                click(world, page, drawn, 0.05, 0.3)?;
                let editor = editor_of(world, page, said)?;
                world.wait_for_with(
                    move |w| focused(w, editor),
                    |_| format!("{said:?} to take the keyboard"),
                )?;
                let source = string_of(world, editor, "text");
                expect!(source == said, "the block's source reads {source:?}");
                let wrap = number_of(world, editor, "wrapMode");
                expect!(wrap == 0.0, "{said:?} wraps (wrapMode {wrap})");
                let (family, _) = font_of(world, editor);
                expect!(in_face(&mono, &family), "{said:?} is in {family}, not {mono}");
                // Left unchanged, it is drawn again.
                page.press(world, "escape")?;
                let name = format!("spaceBlockEditor:{said}");
                world.wait_for_with(
                    move |w| find_on_page(w, page, &name).is_none(),
                    |_| format!("{said:?} to be drawn again"),
                )?;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the page {Q} with a table whose columns are aligned left, centre and right"),
        |world, c, _| given_block(world, &c[0], "table", ALIGNED_TABLE, false),
    );
    steps.step(
        "the table is shown as a grid of its cells, its header row apart",
        |world, _, _| {
            let spec = grid_spec(world)?;
            expect!(
                strings(&spec["header"]) == ["Step", "Owner", "Done"],
                "the header is {}",
                show(&spec["header"])
            );
            expect!(
                spec["rows"].as_array().map(Vec::len) == Some(1),
                "the rows are {}",
                show(&spec["rows"])
            );
            Ok(())
        },
    );
    steps.step("each column is aligned as it was written", |world, _, _| {
        let align = strings(&grid_spec(world)?["align"]);
        expect!(
            align == ["left", "center", "right"],
            "the columns are aligned {}",
            align.join(", ")
        );
        Ok(())
    });
    steps.step(
        &format!("a cell's formatting is shown, a {Q} as a pipe"),
        |world, _, _| {
            let row = strings(&grid_spec(world)?["rows"][0]);
            let first = row.first().cloned().unwrap_or_default();
            expect!(
                first.contains("<b>MC</b>") || first.contains("<strong>MC</strong>"),
                "the bold cell is {first}"
            );
            let second = row.get(1).cloned().unwrap_or_default();
            expect!(second == "a | b", "the escaped pipe's cell is {second}");
            Ok(())
        },
    );
    steps.step(
        &format!("the page {Q} with a {Q} code block"),
        |world, c, _| given_code(world, &c[0], &c[1]),
    );
    steps.step(&format!("the page {Q} with a code block"), |world, c, _| {
        given_code(world, &c[0], "")
    });
    // Coloured as the brick colours a reply's code (timeline/markdown.feature
    // holds it to the languages and the theme).
    steps.step(
        "its text is shown in a fixed-width face, coloured for that language where the surface can",
        |world, _, _| {
            let page = draw_page(world)?;
            let code_box = drawn_part(world, page, CODE, "markdownCode")?;
            let code = string_of(world, code_box, "code");
            expect!(code == CODE, "the code reads {code:?}");
            let Some(code) = find_editor(world, page, code_box, "codeText") else {
                fail!("the code block has no codeText")
            };
            let (family, _) = font_of(world, code);
            let mono = mono_face(world);
            expect!(in_face(&mono, &family), "the code is in {family}, not {mono}");
            let Some(highlighter) = find_child(world, code, "codeHighlighter") else {
                fail!("the code block has no highlighter")
            };
            world.wait_for_with(
                move |w| w.engine().read_by_name(highlighter, "coloured") == JsValue::Bool(true),
                move |w| {
                    format!(
                        "the code to be coloured as {}",
                        string_of(w, highlighter, "language")
                    )
                },
            )
        },
    );
    steps.step("its language is named on it", |world, _, _| {
        let page = draw_page(world)?;
        let language = text(&find_block(world, CODE)?["language"]);
        let code_box = drawn_part(world, page, CODE, "markdownCode")?;
        let label = find_editor(world, page, code_box, "codeLabel")
            .map(|label| string_of(world, label, "text"))
            .unwrap_or_default();
        expect!(
            !language.is_empty() && label == language,
            "the code is named {label:?}, not {language}"
        );
        Ok(())
    });
    steps.step(
        "the user copies the code block on the page",
        |world, _, _| {
            let page = draw_page(world)?;
            let code_box = drawn_part(world, page, CODE, "markdownCode")?;
            let Some(copy) = find_editor(world, page, code_box, "copyCode") else {
                fail!("the code block has no copy button")
            };
            world.set_clipboard("");
            click(world, page, copy, 0.5, 0.5)?;
            world.wait_for("the code to be copied", |w| !w.clipboard().is_empty())?;
            expect!(
                find_on_page(world, page, &format!("spaceBlockEditor:{CODE}")).is_none(),
                "copying the code edits it"
            );
            Ok(())
        },
    );
    steps.step(
        "the code is on the clipboard without its fence",
        |world, _, _| {
            let held = world.clipboard();
            expect!(held == CODE, "the clipboard holds {held:?}");
            Ok(())
        },
    );
    // Blocks as the MC keeps them, a field per column; `-` is a field the block does not have.
    steps.step(
        &format!("the page {Q} holds the blocks:"),
        |world, c, table| {
            let page = given_page(world, &c[0], "")?;
            let header = table.first().cloned().unwrap_or_default();
            for row in table.iter().skip(1) {
                let mut block = json!({"pageId": page});
                for (i, field) in header.iter().enumerate() {
                    let cell = row.get(i).map(String::as_str).unwrap_or("-");
                    if cell == "-" {
                        if field == "text" {
                            block[field] = json!("");
                        }
                    } else if field == "checked" {
                        block[field] = json!(cell == "true");
                    } else if field == "depth" || field == "start" {
                        block[field] = json!(cell.parse::<i64>().unwrap_or(0));
                    } else {
                        block[field] = json!(cell);
                    }
                }
                given(world, "block.insert", block)?;
            }
            Ok(())
        },
    );
    // The page's lines as Markdown, from what each block shows: what the MC
    // writes around its text, then a tick standing for `- [ ]` and a
    // callout's tint for `> `.
    steps.step(
        "each block is shown as this Markdown, line for line:",
        |world, _, table| {
            let doc = table
                .first()
                .and_then(|row| row.first())
                .cloned()
                .unwrap_or_default();
            let wanted: Vec<String> = doc
                .split('\n')
                .filter(|line| !line.trim().is_empty())
                .map(str::to_owned)
                .collect();
            let page = Brick::new(
                world,
                "import QtQuick\nimport HalC2.Bricks\nSpacePage { width: 900; height: 1600 }\n",
                900.0,
                1600.0,
            )?;
            let expected = wanted.clone();
            world.wait_for_with(
                move |w| shown_markdown(w, page).is_ok_and(|shown| shown == expected),
                move |w| {
                    format!(
                        "the page to show\n{}\nbut it shows\n{}",
                        wanted.join("\n"),
                        shown_markdown(w, page).unwrap_or_default().join("\n")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the page {Q} with headings of every level from 1 to 6"),
        |world, c, _| {
            let page = given_page(world, &c[0], "")?;
            for level in 1..=6 {
                given(
                    world,
                    "block.insert",
                    json!({"pageId": page, "kind": "heading", "text": format!("Level {level}"), "level": level}),
                )?;
            }
            Ok(())
        },
    );
    steps.step(
        "the table is shown as its Markdown, exactly as written, in a fixed-width face",
        |world, _, _| {
            let page = draw_page(world)?;
            let editor = editor_of(world, page, TABLE)?;
            expect!(visible(world, editor), "the table's source is not shown");
            let said = string_of(world, editor, "text");
            expect!(said == TABLE, "the table reads {said:?}");
            // Its lines as written: never wrapped, and the text as plain text.
            let wrap = number_of(world, editor, "wrapMode");
            expect!(wrap == 0.0, "the table's lines wrap (wrapMode {wrap})");
            expect!(
                number_of(world, editor, "textFormat") == 0.0,
                "the table is not shown as plain text"
            );
            // In the code face, as code in a reply is.
            let (family, size) = font_of(world, editor);
            let mono = mono_face(world);
            let wanted = code_size(world);
            expect!(
                in_face(&mono, &family) && size == wanted,
                "the table is in {family} at {size}, not {mono} at {wanted}"
            );
            Ok(())
        },
    );
    steps.step("the user can edit it as text", |world, _, _| {
        let page = draw_page(world)?;
        let editor = editor_of(world, page, TABLE)?;
        click(world, page, editor, 0.05, 0.2)?;
        world.wait_for_with(
            move |w| focused(w, editor),
            |_| "the table to take the keyboard".to_owned(),
        )?;
        page.press(world, "ctrl+end")?;
        // Return starts a line in it; Ctrl+Return writes it.
        page.press(world, "return")?;
        world.type_text("| Ops  | Bo    |")?;
        page.press(world, "ctrl+return")?;
        let edited = format!("{TABLE}\n| Ops  | Bo    |");
        let wanted = edited.clone();
        world.wait_for_with(
            move |w| column(w, "blocks", "text").contains(&wanted),
            move |w| {
                format!(
                    "the MC to hold the edited table; it holds {:?}",
                    string_of(w, editor, "text")
                )
            },
        )?;
        let block = find_block(world, &edited)?;
        expect!(
            text(&block["kind"]) == "raw",
            "the edited table is no longer kept as written: {}",
            show(&block)
        );
        Ok(())
    });
    steps.step(
        "each heading is smaller than the one of the level above it",
        |world, _, _| {
            let page = draw_page(world)?;
            let mut sizes = Vec::new();
            for level in 1..=6 {
                let drawn = shown_of(world, page, "spaceBlockText:", &format!("Level {level}"))?;
                sizes.push(number_of(world, drawn, "fontSize"));
            }
            for i in 1..sizes.len() {
                expect!(
                    sizes[i] < sizes[i - 1],
                    "level {} is not smaller than level {}: {sizes:?}",
                    i + 1,
                    i
                );
            }
            Ok(())
        },
    );
    steps.step("a page with a paragraph holding (.+)", |world, c, _| {
        let Some((said, _)) = inline(&c[0]) else {
            fail!("no paragraph holds {}", c[0])
        };
        given_block(world, "Notes", "paragraph", said, false)
    });
    steps.step(
        "a page with a paragraph linking to a web address",
        |world, _, _| given_block(world, "Notes", "paragraph", LINKING, false),
    );
    steps.step("the user opens the page", |world, _, _| {
        let page = id_of_page(world, "Notes")?;
        look_at_page(world, &page)?;
        show_page(world).map(|_| ())
    });
    steps.step("the paragraph is shown with (.+)", |world, c, _| {
        let Some((said, wanted)) = inline(&c[0]) else {
            fail!("no paragraph holds {}", c[0])
        };
        let item = prose(world, said)?;
        let html = string_of(world, item, "text");
        for part in wanted {
            expect!(html.contains(part), "{part} is not drawn in {html}");
        }
        for marker in ["**", "~~", "`", "](", "Title"] {
            expect!(!html.contains(marker), "{marker} shows in {html}");
        }
        Ok(())
    });
    steps.step(
        "nothing is fetched until the user opens the link",
        |world, _, _| {
            let drawn = prose(world, LINKING)?;
            let html = string_of(world, drawn, "text");
            expect!(!html.contains("<img"), "the picture is loaded: {html}");
            expect!(
                html.contains("href=\"https://example.com/signups.png\">"),
                "the picture is no link: {html}"
            );
            let opened = world.opened_urls();
            expect!(opened.is_empty(), "the browser opened {opened:?}");
            // The link starts the paragraph: a click on its first letters follows it.
            let brick = kept_page(world)?;
            let (x, y) = brick.at_px(world, drawn, 4.0, number_of(world, drawn, "height") / 2.0)?;
            world.click_at(x, y)?;
            world.wait_for_with(
                |w| !w.opened_urls().is_empty(),
                |w| format!("the link to open; {}", describe(w)),
            )?;
            let opened = world.opened_urls();
            expect!(
                opened == ["https://example.com/docs"],
                "the browser opened {opened:?}"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the page {Q} with a bulleted list holding a numbered list"),
        |world, c, _| {
            let page = given_page(world, &c[0], "")?;
            for item in &NESTED {
                given(
                    world,
                    "block.insert",
                    json!({"pageId": page, "kind": item.kind, "text": item.text, "depth": item.depth}),
                )?;
            }
            Ok(())
        },
    );
    steps.step(
        "each item is shown with its bullet or its number, indented under its parent",
        |world, _, _| {
            let page = show_page(world)?;
            let mut left = std::collections::HashMap::new();
            for item in &NESTED {
                let drawn = shown_of(world, page, "spaceBlockText:", item.text)?;
                let Some(prose) = find_editor(world, page, drawn, "markdownProse") else {
                    fail!("{} is not drawn as prose", item.text)
                };
                let html = string_of(world, prose, "text");
                expect!(
                    html.contains(item.list) && html.contains(&format!(">{}</", item.text)),
                    "{} is drawn as {html}",
                    item.text
                );
                let lead = find_on_page(world, page, &format!("spaceMarkdownLead:{}", item.text));
                let lead_text = lead
                    .map(|l| string_of(world, l, "text"))
                    .unwrap_or_default();
                expect!(
                    lead.is_none_or(|l| !visible(world, l)) || lead_text.trim().is_empty(),
                    "{} shows its marker as text: {lead_text}",
                    item.text
                );
                left.insert(item.text, page.at(world, drawn, 0.0, 0.0)?.0);
            }
            let at = |name: &str| left.get(name).copied().unwrap_or_default();
            for (child, parent) in [("Tag", "Plan the release"), ("Notes", "Ship")] {
                expect!(
                    at(child) > at(parent),
                    "{child} (at {}) is not indented under {parent} (at {})",
                    at(child),
                    at(parent)
                );
            }
            expect!(
                (at("Tag") - at("Ship")).abs() < 0.01,
                "Tag and Ship are not at one depth"
            );
            expect!(
                (at("Announce") - at("Plan the release")).abs() < 0.01,
                "Announce is not back at the top"
            );
            Ok(())
        },
    );
}

fn register_mermaid(steps: &mut Steps) {
    steps.step(
        &format!("the user imports a page holding a {Q} Mermaid diagram"),
        |world, c, _| {
            let Some(source) = diagram(&c[0]) else {
                fail!("no {} diagram to import", c[0])
            };
            import_diagram(world, source, 0)
        },
    );
    steps.step(
        "the user imports a page holding a flowchart with an unclosed bracket",
        |world, _, _| import_diagram(world, mermaid::BROKEN_FLOWCHART, 0),
    );
    // Paragraphs after it, enough to scroll it out of the page.
    steps.step("a page with a flowchart", |world, _, _| {
        import_diagram(world, mermaid::FLOWCHART, 40)
    });
    steps.step(
        &format!("the page has a diagram block of the type {Q}"),
        |world, c, _| {
            let source = diagram_source(world);
            let kind = source
                .lines()
                .next()
                .unwrap_or_default()
                .split(' ')
                .next()
                .unwrap_or_default();
            expect!(
                kind == c[0],
                "the page holds a {} diagram, not {source}",
                c[0]
            );
            expect_shown(
                world,
                "a code block in \"mermaid\" holding the diagram",
                move |w| {
                    rows_of(w, "blocks").iter().any(|block| {
                        block.get("kind").map(text).as_deref() == Some("code")
                            && block.get("language").map(text).as_deref() == Some("mermaid")
                            && block.get("text").map(text).as_deref() == Some(source.as_str())
                    })
                },
            )
        },
    );
    steps.step(
        "on the desktop and the phone the diagram is drawn",
        |world, _, _| {
            let page = kept_page(world)?;
            wait_drawn(world, page, 1, "the diagram to be drawn")?;
            let image = mermaid::drawn(world, page)[0];
            expect!(
                number_of(world, image, "width") > 0.0,
                "the diagram is drawn with no width"
            );
            let source = diagram_source(world);
            expect!(
                source_editor(world, page, &source).is_none_or(|e| !visible(world, e)),
                "the diagram's source shows with its picture"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user is told {Q} diagrams cannot be drawn yet"),
        |world, c, _| {
            let page = kept_page(world)?;
            let wanted = format!("{} diagrams cannot be drawn yet.", c[0]);
            let said = wanted.clone();
            world.wait_for_with(
                move |w| {
                    let notes = mermaid::shown(w, page, "mermaidStatus");
                    notes.len() == 1 && string_of(w, notes[0], "text") == said
                },
                |_| format!("the user to be told {wanted:?}"),
            )
        },
    );
    // desktop-qt's FilesViewerSteps.cpp shares this step with the Files
    // viewer; only a page's half is ported here.
    steps.step("the diagram's source is shown", |world, _, _| {
        let page = kept_page(world)?;
        if find_on_page(world, page, "spaceBlocks").is_none() {
            return super::files_viewer::diagram_source_shown(world);
        }
        let source = diagram_source(world);
        let wanted = source.clone();
        let renders = |w: &World| {
            w.mc.calls
                .iter()
                .filter(|rpc| rpc.method == "mermaid.render")
                .count()
        };
        world.wait_for_with(
            move |w| {
                source_editor(w, page, &wanted).is_some_and(|editor| {
                    visible(w, editor) && string_of(w, editor, "text") == wanted
                }) && renders(w) == 1
            },
            |w| format!("the diagram's source; {}", describe(w)),
        )?;
        expect!(mermaid::drawn(world, page).is_empty(), "a picture is drawn");
        Ok(())
    });
    steps.step("the user adds a node to its source", |world, _, _| {
        let page = kept_page(world)?;
        let source = diagram_source(world);
        wait_drawn(world, page, 1, "the diagram to be drawn")?;
        let toggle = find_on_page(world, page, &format!("spaceDiagramSource:{source}"));
        let Some(toggle) = toggle.filter(|&t| visible(world, t)) else {
            fail!("no way to the diagram's source")
        };
        click(world, page, toggle, 0.5, 0.5)?;
        let Some(editor) = source_editor(world, page, &source) else {
            fail!("the diagram has no source editor")
        };
        world.wait_for_with(
            move |w| visible(w, editor),
            |_| "the diagram's source to show".to_owned(),
        )?;
        click(world, page, editor, 0.05, 0.2)?;
        world.wait_for_with(
            move |w| focused(w, editor),
            |_| "the source to take the keyboard".to_owned(),
        )?;
        page.press(world, "ctrl+end")?;
        page.press(world, "return")?;
        world.type_text("  Pay --> Done")?;
        page.press(world, "ctrl+return")?;
        world.part::<Diagram>().source.push_str("\n  Pay --> Done");
        Ok(())
    });
    steps.step(
        "the diagram is drawn again with the new node",
        |world, _, _| {
            let page = kept_page(world)?;
            let source = diagram_source(world);
            let wanted = source.clone();
            world.sync_until_with(
                move |w| {
                    mermaid::drawn(w, page).len() == 1
                        && find_on_page(w, page, &format!("spaceDiagram:{wanted}")).is_some()
                        && source_editor(w, page, &wanted).is_none_or(|e| !visible(w, e))
                },
                |w| format!("the new source to be drawn; {}", describe(w)),
            )?;
            let asked = mermaid::asked(world)?;
            expect!(
                asked == 2,
                "the MC was asked {asked} times, not for the first and the new source"
            );
            Ok(())
        },
    );
    steps.step("the export writes the new source", |world, _, _| {
        world.set_clipboard("");
        let page = with_space(world, |s, _| s.page_id().to_owned())?;
        act_on_page(world, &page, "space.page.copyMarkdown", json!({}))?;
        let fence = format!("```mermaid\n{}\n```", diagram_source(world));
        let wanted = fence.clone();
        world.wait_for_with(
            move |w| w.clipboard().contains(&wanted),
            move |w| format!("the export to hold {fence}; it holds {:?}", w.clipboard()),
        )
    });
    steps.step(
        "the user scrolls the page past it and back",
        |world, _, _| {
            let page = kept_page(world)?;
            wait_drawn(world, page, 1, "the diagram to be drawn")?;
            let Some(list) = find_on_page(world, page, "spaceBlocks") else {
                fail!("the page has no spaceBlocks")
            };
            invoke(world, list, "positionViewAtEnd")?;
            wait_drawn(world, page, 0, "the page to scroll past the diagram")?;
            invoke(world, list, "positionViewAtBeginning")?;
            wait_drawn(world, page, 1, "the diagram to be back")
        },
    );
    steps.step("the diagram is not drawn again", |world, _, _| {
        let asked = mermaid::asked(world)?;
        expect!(asked == 1, "the MC was asked to draw it {asked} times");
        Ok(())
    });
}

fn invoke(world: &mut World, item: ObjectId, method: &str) -> Outcome {
    world
        .engine()
        .invoke_by_name(item, method, &[])
        .map_err(|e| crate::harness::Failure(format!("{method}: {e:?}")))?;
    world.pump()
}

fn register_charts(steps: &mut Steps) {
    steps.step("this MC's threads took turns this week", |_, _, _| Ok(()));
    steps.step(
        "text generation charts the request from the MC's threads",
        |world, _, _| {
            fake::fake(&mut world.mc).chart = chart_of(
                "bar",
                "Weekly turns",
                "Counted by this MC from its 2 threads, 12 weeks to 2026-11-01",
                &[("10-26".to_owned(), 4), ("11-02".to_owned(), 7)],
            );
            Ok(())
        },
    );
    steps.step(
        &format!(
            "text generation answers with a (bar|line) chart of {Q} (\\d+)(?: and {Q} (\\d+))?"
        ),
        |world, c, _| {
            let mut points = vec![(c[1].clone(), c[2].parse().unwrap_or(0))];
            if !c[3].is_empty() {
                points.push((c[3].clone(), c[4].parse().unwrap_or(0)));
            }
            fake::fake(&mut world.mc).chart = chart_of(&c[0], "Signups", FROM_THIS_PAGE, &points);
            Ok(())
        },
    );
    steps.step(
        "text generation says the request cannot be answered",
        |world, _, _| {
            fake::fake(&mut world.mc).chart = json!({});
            Ok(())
        },
    );
    steps.step(
        &format!("the page {Q} has a chart of {Q} (\\d+) and {Q} (\\d+)"),
        |world, c, _| {
            let chart = signups(
                &c[1],
                c[2].parse().unwrap_or(0),
                &c[3],
                c[4].parse().unwrap_or(0),
            );
            given_chart(world, &c[0], chart)
        },
    );
    // The same page with a chart missing a number, which the MC would refuse.
    steps.step(
        &format!("the page {Q} has a chart with 2 labels and 1 number"),
        |world, c, _| {
            let mut chart = signups("May", 3, "June", 5);
            chart["series"] = json!([{"name": "Signups", "values": [3]}]);
            given_chart(world, &c[0], chart)
        },
    );
    steps.step(
        &format!("the page {Q} has the blocks {Q} and a chart of {Q} (\\d+) and {Q} (\\d+) and the blocks {Q}"),
        |world, c, _| {
            given_block(world, &c[0], "paragraph", &c[1], false)?;
            let chart = signups(&c[2], c[3].parse().unwrap_or(0), &c[4], c[5].parse().unwrap_or(0));
            given_chart(world, &c[0], chart)?;
            given_block(world, &c[0], "paragraph", &c[6], false)
        },
    );
    steps.step(&format!("{Q} also says {Q}"), |world, c, _| {
        given_block(world, &c[0], "paragraph", &c[1], false)
    });
    steps.step(
        &format!("the user asks for {Q} on the page {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[1])?;
            fake::fake(&mut world.mc).asked = page.clone();
            act_on_page(
                world,
                &page,
                "space.block.visualize",
                json!({"request": c[0]}),
            )
        },
    );
    steps.step(&format!("the user asks again for {Q}"), |world, c, _| {
        let page = asked_page(world);
        look_at_page(world, &page)?;
        let block = text(&shown_chart(world)["id"]);
        act_on_page(
            world,
            &page,
            "space.block.visualize",
            json!({"request": c[0], "blockId": block}),
        )
    });
    steps.step(
        &format!("the page shows a (bar|line) chart titled {Q}"),
        |world, c, _| {
            let page = asked_page(world);
            look_at_page(world, &page)?;
            let (kind, title) = (c[0].clone(), c[1].clone());
            expect_shown(
                world,
                &format!("a {} chart titled {}", c[0], c[1]),
                move |w| {
                    let chart = &shown_chart(w)["chart"];
                    text(&chart["type"]) == kind && text(&chart["title"]) == title
                },
            )?;
            expect!(
                !drawing(world),
                "the page still says a chart is being drawn"
            );
            Ok(())
        },
    );
    steps.step(
        "the chart says its numbers came from (this MC's threads|this page)",
        |world, c, _| {
            let source = text(&shown_chart(world)["chart"]["source"]);
            let start = if c[0] == "this page" {
                FROM_THIS_PAGE
            } else {
                "Counted by this MC"
            };
            expect!(
                source.starts_with(start),
                "the chart says its numbers came from {source:?}"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the second client sees a chart titled {Q}"),
        |world, c, _| {
            let page = asked_page(world);
            in_second(world, "space.selectPage", json!({"pageId": page}))?;
            let want = c[0].clone();
            let titles = |w: &World| -> Vec<String> {
                crate::steps::space::with_second(w, |s, _| {
                    s.rows("blocks")
                        .iter()
                        .map(|row| text(&row.get("chart").cloned().unwrap_or_default()["title"]))
                        .collect()
                })
                .unwrap_or_default()
            };
            world.wait_for_with(
                move |w| titles(w).contains(&want),
                move |w| format!("the second client shows the charts {:?}", titles(w)),
            )
        },
    );
    // The toggle is the brick's; tst_Space.qml presses it. What it reads is the row asserted below.
    steps.step(
        "the user asks to see the numbers behind the chart",
        |world, _, _| {
            let page = asked_page(world);
            look_at_page(world, &page)?;
            expect_shown(world, "a chart on the page", has_chart)
        },
    );
    steps.step("the chart's numbers are not shown", |world, _, _| {
        let page = asked_page(world);
        look_at_page(world, &page)?;
        expect_shown(world, "a chart on the page", has_chart)?;
        // Drawn by the brick from what the page holds, as the page draws it.
        let chart = shown_chart(world)["chart"].clone();
        let brick = Brick::new(
            world,
            &format!("import QtQuick\nimport HalC2.Bricks\nSpaceChart {{ width: 480; chart: ({chart}) }}\n"),
            480.0,
            320.0,
        )?;
        let unmatched = brick.item(world, "spaceChartUnmatched")?;
        expect!(
            visible(world, unmatched),
            "the chart does not say its numbers do not match"
        );
        let numbers = brick.item(world, "spaceChartNumbers")?;
        expect!(!visible(world, numbers), "the chart offers its numbers");
        Ok(())
    });
    steps.step(
        &format!("the numbers read {Q} (\\d+)(?: and {Q} (\\d+))?"),
        |world, c, _| {
            let page = asked_page(world);
            look_at_page(world, &page)?;
            let mut labels = vec![c[0].clone()];
            let mut values = vec![c[1].parse::<f64>().unwrap_or(0.0)];
            if !c[2].is_empty() {
                labels.push(c[2].clone());
                values.push(c[3].parse::<f64>().unwrap_or(0.0));
            }
            expect_shown(
                world,
                &format!("the numbers to read {}", c.join(" ")),
                move |w| {
                    let chart = &shown_chart(w)["chart"];
                    chart["series"].as_array().map(Vec::len) == Some(1)
                        && chart_numbers(chart) == (labels.clone(), values.clone())
                },
            )
        },
    );
    steps.step(
        &format!("the page shows one chart, between {Q} and {Q}"),
        |world, c, _| {
            let (before, after) = (c[0].clone(), c[1].clone());
            expect_shown(
                world,
                &format!("one chart between {} and {}", c[0], c[1]),
                move |w| {
                    let kinds = column(w, "blocks", "kind");
                    let texts = column(w, "blocks", "text");
                    let charts = kinds.iter().filter(|k| *k == "chart").count();
                    match kinds.iter().position(|k| k == "chart") {
                        Some(at) => {
                            charts == 1
                                && at > 0
                                && at + 1 < texts.len()
                                && texts[at - 1] == before
                                && texts[at + 1] == after
                        }
                        None => false,
                    }
                },
            )
        },
    );
    steps.step("the user deletes the chart", |world, _, _| {
        let page = asked_page(world);
        look_at_page(world, &page)?;
        let block = text(&shown_chart(world)["id"]);
        act(world, "space.block.delete", json!({"blockId": block}))
    });
    steps.step("the page shows no chart", |world, _, _| {
        let page = asked_page(world);
        look_at_page(world, &page)?;
        expect_shown(world, "no chart on the page", |w| !has_chart(w))
    });
    steps.step("the user is told no chart was drawn", |world, _, _| {
        let start = "No chart was drawn";
        world.wait_for_with(
            move |w| told_starting(w, start),
            move |w| {
                format!(
                    "the user to be told {start:?}; toasts {}",
                    show(&w.state("toasts")["items"])
                )
            },
        )?;
        expect!(
            !drawing(world),
            "the page still says a chart is being drawn"
        );
        Ok(())
    });
}
