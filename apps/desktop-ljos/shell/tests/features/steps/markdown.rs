//! Formatted messages (features/timeline/markdown.feature) and bare web
//! addresses (scrolling-and-links.feature) as the desktop draws them
//! (desktop-qt's MarkdownSteps.cpp): the fake MC's thread goes through the
//! ThreadStore's TimelineModel into the Timeline brick, whose messages are
//! Markdown bricks. Steps click what the user clicks and read back the
//! segments the brick draws.

use ljos::item::{Modifiers, MouseButtons};
use ljos::prelude::{Engine, ObjectId, Value};
use serde_json::{Value as Json, json};

use super::fake_files::fake_files;
use super::stream::{add_item, change, set, settle_run, start_run};
use crate::brick::{self, Brick};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::composer_brick::text_menu_item;
use crate::world::World;
use crate::{expect, fail};

const SOURCE: &str = "const total = cart.lines.reduce((sum, line) => sum + line.price, 0);\nreturn roundToCent(total * (1 + rate));";
const TABLE: &str = "| Region | Rate |\n|---|---:|\n| EU, north | 21% |\n| a\\|b | \"q\" |";
const SENTENCE: &str = "Cache keys include the tenant.";

/// What a step saw, for a later step to compare with.
#[derive(Default)]
struct Seen {
    link: String,
    item: Option<ObjectId>,
    segments: i32,
    // The code a diagram or a reply being written has.
    code: String,
    // The code block's colours: its fence, and the colours it had before.
    fence: String,
    colours: Vec<Option<ljos::prelude::Color>>,
}

fn name_of(engine: &Engine, item: ObjectId) -> String {
    match engine.read_by_name(item, "objectName") {
        Value::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

fn has(engine: &Engine, item: ObjectId, property: &str) -> bool {
    !matches!(engine.read_by_name(item, property), Value::Undefined)
}

fn is_markdown(engine: &Engine, item: ObjectId) -> bool {
    has(engine, item, "lineBreaks") && has(engine, item, "segmentCount")
}

/// Items named `name` under `item`, in the order they are drawn. From the
/// brick's probe this includes open menus, which live in its overlay.
fn named(engine: &Engine, item: ObjectId, name: &str, out: &mut Vec<ObjectId>) {
    if name_of(engine, item) == name {
        out.push(item);
    }
    for child in engine.children(item) {
        named(engine, child, name, out);
    }
}

/// Items named `name` in one message, not in the messages a quote nests.
fn own(engine: &Engine, item: ObjectId, name: &str, out: &mut Vec<ObjectId>) {
    if name_of(engine, item) == name {
        out.push(item);
    }
    for child in engine.children(item) {
        if !is_markdown(engine, child) {
            own(engine, child, name, out);
        }
    }
}

fn within(world: &World, message: ObjectId, name: &str) -> Vec<ObjectId> {
    let mut out = Vec::new();
    own(world.engine(), message, name, &mut out);
    out
}

/// The Markdown bricks the timeline shows: user messages keep their line
/// breaks, agent replies do not.
fn collect_markdown(engine: &Engine, item: ObjectId, out: &mut Vec<ObjectId>) {
    if is_markdown(engine, item) {
        out.push(item);
        return;
    }
    for child in engine.children(item) {
        collect_markdown(engine, child, out);
    }
}

fn messages(world: &World, brick: Brick, user: bool) -> Vec<ObjectId> {
    let mut all = Vec::new();
    if let Some(root) = brick.root(world) {
        collect_markdown(world.engine(), root, &mut all);
    }
    all.into_iter()
        .filter(|&m| (world.engine().read_by_name(m, "lineBreaks") == Value::Bool(true)) == user)
        .collect()
}

/// The timeline of the open thread (Threads.timeline, as ThreadView shows
/// it); it records the links the user activates.
fn timeline_brick(world: &mut World) -> Outcome<Brick> {
    if world.part::<brick::Shown>().0.is_none() {
        let brick = Brick::new(
            world,
            "import QtQuick\nimport HalC2.Bricks\n\
             Timeline { property string activated: \"[]\"\n\
               property string quotes: \"[]\"\n\
               citable: true\n\
               onCited: (messageId, selector) => quotes = JSON.stringify(JSON.parse(quotes).concat([Object.assign({ messageId: messageId }, selector)]))\n\
               onLinkActivated: link => activated = JSON.stringify(JSON.parse(activated).concat([link])) }\n",
            820.0,
            1400.0,
        )?;
        world.part::<brick::Shown>().0 = Some(brick);
        let timeline = super::stream::timeline_object(world)?;
        let Some(root) = brick.root(world) else {
            fail!("the timeline brick has no root");
        };
        brick.write(world, root, "model", Value::Object(timeline))?;
    }
    brick::shown(world)
}

fn int_of(world: &World, item: ObjectId, name: &str) -> i32 {
    match world.engine().read_by_name(item, name) {
        Value::Int(n) => n,
        Value::Real(r) => r as i32,
        _ => 0,
    }
}

fn str_of(world: &World, item: ObjectId, name: &str) -> String {
    match world.engine().read_by_name(item, name) {
        Value::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

/// The newest reply once it shows `segments` segments or more.
fn reply(world: &mut World, segments: i32) -> Outcome<ObjectId> {
    let brick = timeline_brick(world)?;
    let newest = move |w: &World| {
        messages(w, brick, false)
            .last()
            .copied()
            .filter(|&m| int_of(w, m, "segmentCount") >= segments)
    };
    world.wait_for_with(
        |w| newest(w).is_some(),
        |w| {
            format!(
                "a reply of {segments} segments; {}",
                super::stream::describe(w)
            )
        },
    )?;
    match newest(world) {
        Some(m) => Ok(m),
        None => fail!("the reply went away"),
    }
}

fn one(world: &World, scope: ObjectId, name: &str) -> Outcome<ObjectId> {
    let found = within(world, scope, name);
    expect!(found.len() == 1, "{} {name} are shown", found.len());
    Ok(found[0])
}

/// A rich text segment's text, with its line separators as line breaks.
fn plain(world: &World, edit: ObjectId) -> Outcome<String> {
    let length = int_of(world, edit, "length");
    match world
        .engine()
        .invoke_by_name(edit, "getText", &[Value::Int(0), Value::Int(length)])
    {
        Ok(Value::String(s)) => Ok(s.as_str().replace('\u{2028}', "\n")),
        Ok(other) => fail!("getText gave {other:?}"),
        Err(error) => fail!("getText: {error}"),
    }
}

/// Where `needle`, as the reader sees it, lies in `raw`, a reply's drawn
/// text, as UTF-16 [start, end). Inline code is drawn with word joiners
/// holding it together, and no-break spaces.
fn drawn_range(raw: &str, needle: &str) -> Option<(usize, usize)> {
    let mut at = Vec::new();
    let mut read = Vec::new();
    for (i, unit) in raw.encode_utf16().enumerate() {
        if unit == 0x2060 {
            continue;
        }
        at.push(i);
        read.push(if unit == 0x00a0 {
            u16::from(b' ')
        } else {
            unit
        });
    }
    let needle: Vec<u16> = needle.encode_utf16().collect();
    if needle.is_empty() {
        return None;
    }
    let found = read
        .windows(needle.len())
        .position(|w| w == needle.as_slice())?;
    Some((at[found], at[found + needle.len() - 1] + 1))
}

/// Drawn text as the reader means it.
fn readable(text: &str) -> String {
    text.replace('\u{2060}', "").replace('\u{a0}', " ")
}

/// The link under the middle of `needle` in a rich text segment, and the
/// point the user would click in the window.
fn link_at(
    world: &World,
    brick: Brick,
    edit: ObjectId,
    needle: &str,
) -> Outcome<(String, (f64, f64))> {
    let all = plain(world, edit)?;
    let Some((start, end)) = drawn_range(&all, needle) else {
        fail!("\"{needle}\" is not shown in \"{}\"", readable(&all));
    };
    let at = (start + end) / 2;
    let rect =
        match world
            .engine()
            .invoke_by_name(edit, "positionToRectangle", &[Value::Int(at as i32)])
        {
            Ok(Value::Rect(rect)) => rect,
            Ok(other) => fail!("positionToRectangle gave {other:?}"),
            Err(error) => fail!("positionToRectangle: {error}"),
        };
    let (x, y) = (rect.x + 1.0, rect.y + rect.height / 2.0);
    let link =
        match world
            .engine()
            .invoke_by_name(edit, "linkAt", &[Value::from(x), Value::from(y)])
        {
            Ok(Value::String(s)) => s.as_str().to_owned(),
            Ok(_) => String::new(),
            Err(error) => fail!("linkAt: {error}"),
        };
    let (width, height) = (
        f64::from(int_of(world, edit, "width")).max(1.0),
        f64::from(int_of(world, edit, "height")).max(1.0),
    );
    let point = brick.at(world, edit, x / width, y / height)?;
    Ok((link, point))
}

fn kinds_of(world: &World, message: ObjectId) -> Vec<String> {
    within(world, message, "markdownSegment")
        .into_iter()
        .map(|segment| str_of(world, segment, "kind"))
        .collect()
}

fn click(world: &mut World, item: ObjectId) -> Outcome {
    let brick = timeline_brick(world)?;
    let usable = brick.flag(world, item, "visible") && brick.flag(world, item, "enabled");
    expect!(
        usable,
        "{} cannot be clicked",
        name_of(world.engine(), item)
    );
    let (x, y) = brick.at(world, item, 0.5, 0.5)?;
    world.click_at(x, y)
}

/// Right-clicks `edit`, a reply's text, near its start; the text's menu
/// (TextEditMenu) is then open.
fn open_text_menu(world: &mut World, edit: ObjectId) -> Outcome {
    let brick = timeline_brick(world)?;
    let (x, y) = brick.at(world, edit, 0.05, 0.5)?;
    world.click_at_with(
        x.trunc(),
        y.trunc(),
        MouseButtons::RIGHT,
        Modifiers::empty(),
    )?;
    // An item takes clicks once its menu has finished opening.
    world.wait_for("the text's menu to open", move |w| {
        let Ok(Some(item)) = brick.find_visible(w, "selectAllText") else {
            return false;
        };
        match brick.read(w, item, "menu") {
            Value::Object(menu) => brick.flag(w, menu, "opened"),
            _ => false,
        }
    })
}

/// Chooses `said` from the open text menu.
fn choose_in_text_menu(world: &mut World, said: &str) -> Outcome {
    let name = text_menu_item(said)?;
    let brick = timeline_brick(world)?;
    let Some(item) = brick.find_visible(world, name)? else {
        fail!("the text's menu offers no {said}");
    };
    expect!(brick.flag(world, item, "enabled"), "{said} is greyed out");
    let (x, y) = brick.at(world, item, 0.5, 0.5)?;
    world.click_at(x, y)?;
    // What it chose is done once the menu has gone.
    world.wait_for("the text's menu to close", move |w| {
        matches!(brick.find_visible(w, name), Ok(None))
    })
}

/// A finished reply of the current thread.
fn answer(world: &mut World, text: &str) -> Outcome {
    start_run(world, 30, "running")?;
    add_item(world, "assistant_message", json!({"text": text}))?;
    settle_run(world, "completed", 30)
}

/// A reply the agent is still writing.
fn start_writing(world: &mut World, text: &str) -> Outcome {
    start_run(world, 30, "running")?;
    add_item(
        world,
        "assistant_message",
        json!({"id": "reply", "streaming": true, "text": text}),
    )?;
    Ok(())
}

/// And more of it.
fn write(world: &mut World, more: &str) -> Outcome {
    change(world, "turn-item", "reply", json!({"a": {"text": more}}))
}

fn json_list(raw: &str) -> Vec<Json> {
    match serde_json::from_str(raw) {
        Ok(Json::Array(items)) => items,
        _ => Vec::new(),
    }
}

fn activated(world: &mut World) -> Outcome<Vec<Json>> {
    let brick = timeline_brick(world)?;
    let Some(root) = brick.root(world) else {
        fail!("the timeline brick has no root");
    };
    Ok(json_list(&str_of(world, root, "activated")))
}

fn click_link(
    world: &mut World,
    point: (f64, f64),
    button: MouseButtons,
    with: Modifiers,
) -> Outcome {
    world.click_at_with(point.0, point.1, button, with)
}

fn primary() -> Modifiers {
    if cfg!(target_os = "macos") {
        Modifiers::META
    } else {
        Modifiers::CONTROL
    }
}

/// The point of the link the scenario named, in the newest reply.
fn link_point(world: &mut World) -> Outcome<(f64, f64)> {
    let link = world.part::<Seen>().link.clone();
    let brick = timeline_brick(world)?;
    let message = reply(world, 1)?;
    let prose = one(world, message, "markdownProse")?;
    let (found, point) = link_at(world, brick, prose, &link)?;
    expect!(found == link, "\"{link}\" links to \"{found}\"");
    Ok(point)
}

/// Code in a language, and a word it starts with that the language colours.
fn sample(fence: &str) -> (&'static str, &'static str) {
    match fence {
        "py" => ("def refund(order):\n    return order.total", "def"),
        "exs" => (
            "defmodule Cart do\n  def total(cart), do: 0\nend",
            "defmodule",
        ),
        "qml" => ("import QtQuick\n\nItem {\n  id: root\n}", "import"),
        _ => (SOURCE, "const"),
    }
}

const LANGUAGES: [(&str, &str); 4] = [
    ("TypeScript", "ts"),
    ("Python", "py"),
    ("Elixir", "exs"),
    ("QML", "qml"),
];

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

fn highlighter_of(world: &World, message: ObjectId) -> Outcome<ObjectId> {
    let code = one(world, message, "codeText")?;
    match find_child(world, code, "codeHighlighter") {
        Some(found) => Ok(found),
        None => fail!("the code block has no highlighter"),
    }
}

fn flag_of(world: &World, item: ObjectId, name: &str) -> bool {
    world.engine().read_by_name(item, name) == Value::Bool(true)
}

/// The colour the highlighter gave a line's first character, or none where
/// it gave none.
fn line_colour(world: &World, code: ObjectId, line: usize) -> Option<ljos::prelude::Color> {
    // The spans count bytes of the editor's own text, where a `<br/>` is a
    // three-byte line separator.
    let length = int_of(world, code, "length");
    let Ok(Value::String(shown)) =
        world
            .engine()
            .invoke_by_name(code, "getText", &[Value::Int(0), Value::Int(length)])
    else {
        return None;
    };
    let shown = shown.as_str();
    let mut at = 0;
    for _ in 0..line {
        let (end, separator) = shown[at..]
            .char_indices()
            .find(|(_, c)| matches!(c, '\n' | '\u{2028}' | '\u{2029}'))?;
        at += end + separator.len_utf8();
    }
    if at >= shown.len() {
        return None;
    }
    ljos::item::highlights(world.engine(), code)?
        .iter()
        .find(|span| span.range.start == at && span.range.end > span.range.start)
        .and_then(|span| span.color)
}

fn coloured_ranges(world: &World, code: ObjectId) -> usize {
    ljos::item::highlights(world.engine(), code).map_or(0, |spans| spans.len())
}

/// The newest reply's code block once its highlighter has read what it will.
fn read_code(world: &mut World) -> Outcome<ObjectId> {
    let message = reply(world, 1)?;
    let highlighter = highlighter_of(world, message)?;
    world.wait_for("the code to be read", move |w| {
        !flag_of(w, highlighter, "reading")
    })?;
    let message = reply(world, 1)?;
    one(world, message, "codeText")
}

pub fn register(steps: &mut Steps) {
    // Formatting.
    steps.step(
        "the agent answers with a heading, a list, a quote, a code block and a table",
        |world, _, _| {
            answer(
                world,
                &format!("# Cart totals\n\n- Discounts first\n- Tax second\n\n> Old carts keep their totals.\n\n```ts\n{SOURCE}\n```\n\n{TABLE}"),
            )
        },
    );
    steps.step(
        "the heading and the list are shown as text",
        |world, _, _| {
            let message = reply(world, 4)?;
            let prose = within(world, message, "markdownProse");
            let Some(&first) = prose.first() else {
                fail!("the reply has no text");
            };
            let shown = plain(world, first)?;
            expect!(
                shown.contains("Cart totals")
                    && shown.contains("Tax second")
                    && !shown.contains('#'),
                "the reply reads \"{shown}\""
            );
            Ok(())
        },
    );
    steps.step(
        "the quote, the code block and the table are each shown in their own form",
        |world, _, _| {
            let message = reply(world, 4)?;
            let kinds = kinds_of(world, message);
            expect!(
                kinds == ["prose", "quote", "code", "table"],
                "the reply is drawn as {}",
                kinds.join(", ")
            );
            let code = one(world, message, "codeText")?;
            let source = plain(world, code)?;
            expect!(source == SOURCE, "the code block reads \"{source}\"");
            let label = one(world, message, "codeLabel")?;
            expect!(
                str_of(world, label, "text") == "ts",
                "the code block is not labelled ts"
            );
            let cells = within(world, message, "tableCell").len();
            expect!(cells == 6, "the table has {cells} cells");
            Ok(())
        },
    );

    // Code colours (CodeHighlighter), from the fence's language.
    steps.step(
        &format!("the agent's reply has a code block whose fence reads {Q}"),
        |world, c, _| {
            world.part::<Seen>().fence = c[0].clone();
            answer(world, &format!("```{}\n{}\n```", c[0], sample(&c[0]).0))
        },
    );
    steps.step("the user reads the reply", |world, _, _| {
        reply(world, 1)?;
        Ok(())
    });
    steps.step(
        "the code block is shown coloured as (TypeScript|Python|Elixir|QML)",
        |world, c, _| {
            let fence = LANGUAGES
                .iter()
                .find(|(name, _)| *name == c[0])
                .map_or("", |(_, fence)| *fence);
            let seen_fence = world.part::<Seen>().fence.clone();
            expect!(seen_fence == fence, "the fence reads \"{seen_fence}\"");
            let code = read_code(world)?;
            let message = reply(world, 1)?;
            let highlighter = highlighter_of(world, message)?;
            expect!(
                flag_of(world, highlighter, "coloured"),
                "the code is not coloured"
            );
            let shown = plain(world, code)?;
            let keyword = sample(fence).1;
            expect!(
                shown.starts_with(keyword) && line_colour(world, code, 0).is_some(),
                "\"{keyword}\" is not coloured in \"{shown}\""
            );
            Ok(())
        },
    );
    steps.step("the code block is shown as plain text", |world, _, _| {
        let code = read_code(world)?;
        let shown = plain(world, code)?;
        expect!(shown == SOURCE, "the code reads \"{shown}\"");
        let message = reply(world, 1)?;
        let highlighter = highlighter_of(world, message)?;
        let ranges = coloured_ranges(world, code);
        expect!(
            !flag_of(world, highlighter, "coloured") && ranges == 0,
            "the code has {ranges} coloured runs"
        );
        Ok(())
    });
    steps.step(
        "the agent is writing a code block whose fence reads \"ts\"",
        |world, _, _| {
            start_writing(
                world,
                "Totals:\n\n```ts\nconst a = 1;\nconst b = 2;\nconst c = 3;\n",
            )
        },
    );
    steps.step("its first three lines are coloured", |world, _, _| {
        let message = reply(world, 2)?;
        let code = one(world, message, "codeText")?;
        world.wait_for_with(
            move |w| {
                line_colour(w, code, 0).is_some()
                    && line_colour(w, code, 1).is_some()
                    && line_colour(w, code, 2).is_some()
            },
            move |w| {
                let spans: Vec<String> = ljos::item::highlights(w.engine(), code)
                    .unwrap_or_default()
                    .iter()
                    .map(|span| format!("{:?}", span.range))
                    .collect();
                format!(
                    "three coloured lines in \"{}\"; spans {}",
                    plain(w, code).unwrap_or_default(),
                    spans.join(" ")
                )
            },
        )?;
        let colours = (0..3).map(|line| line_colour(world, code, line)).collect();
        let seen = world.part::<Seen>();
        seen.item = Some(code);
        seen.colours = colours;
        Ok(())
    });
    steps.step("the agent adds a fourth line", |world, _, _| {
        write(world, "const d = 4;")
    });
    steps.step(
        "the first three lines stay coloured while the new line waits to be coloured",
        |world, _, _| {
            let code = world.part::<Seen>().item;
            let Some(code) = code else {
                fail!("the code block was drawn anew");
            };
            let message = reply(world, 2)?;
            expect!(
                one(world, message, "codeText")? == code,
                "the code block was drawn anew"
            );
            world.wait_for_with(
                move |w| plain(w, code).is_ok_and(|shown| shown.ends_with("const d = 4;")),
                move |w| {
                    format!(
                        "the fourth line; the code reads \"{}\"",
                        plain(w, code).unwrap_or_default()
                    )
                },
            )?;
            let message = reply(world, 2)?;
            let highlighter = highlighter_of(world, message)?;
            world.wait_for("the code to be read", move |w| {
                !flag_of(w, highlighter, "reading")
            })?;
            let now: Vec<_> = (0..3).map(|line| line_colour(world, code, line)).collect();
            expect!(
                now == world.part::<Seen>().colours,
                "the first three lines changed colour"
            );
            expect!(
                line_colour(world, code, 3).is_none(),
                "the line being written is coloured"
            );
            Ok(())
        },
    );
    steps.step(
        "the block does not flash back to plain text",
        |world, _, _| {
            // Ljós colours as it paints, so there is no plain interval to spy:
            // the block is still the coloured one its lines were read from.
            let message = reply(world, 2)?;
            let highlighter = highlighter_of(world, message)?;
            expect!(
                flag_of(world, highlighter, "coloured"),
                "the block went plain"
            );
            Ok(())
        },
    );
    steps.step(
        "the user switches the app from light to dark",
        |world, _, _| {
            use hal_c2_shell::controllers::settings::Settings;
            use hal_c2_shell::controllers::theme::{Mode, Themes};
            let appearance = world.with::<Themes, _>(|t, _| t.appearance())?;
            expect!(appearance == "light", "the app is drawn {appearance}");
            let code = read_code(world)?;
            let colour = line_colour(world, code, 0);
            let seen = world.part::<Seen>();
            seen.item = Some(code);
            seen.colours = vec![colour];
            let set = world.with::<Themes, _>(|t, e| {
                t.set_mode(e, Mode::parse("dark").unwrap_or(Mode::Dark))
            })?;
            expect!(set, "{}", Settings::of(world.engine()).device_error());
            world.wait_for("the app to be drawn dark", |w| {
                w.with::<Themes, _>(|t, _| t.appearance() == "dark")
                    .unwrap_or(false)
            })
        },
    );
    steps.step(
        "the code block is coloured for the dark theme",
        |world, _, _| {
            let Some(code) = world.part::<Seen>().item else {
                fail!("the code block was drawn anew");
            };
            let before = world.part::<Seen>().colours.first().copied().flatten();
            world.wait_for_with(
                move |w| line_colour(w, code, 0).is_some_and(|now| Some(now) != before),
                move |w| {
                    format!(
                        "\"const\" in another colour than {before:?}; it is {:?}",
                        line_colour(w, code, 0)
                    )
                },
            )
        },
    );
    steps.step("its code was not read again", |world, _, _| {
        // Reading is synchronous with painting (code_highlighter.rs):
        // nothing is ever being read in the background.
        let message = reply(world, 1)?;
        let highlighter = highlighter_of(world, message)?;
        expect!(
            !flag_of(world, highlighter, "reading"),
            "the code is being read again"
        );
        Ok(())
    });

    // Citing: the selection's Cite, and the action ThreadView sends for it.
    steps.step(
        "the user selects a sentence in the agent's reply and cites it",
        |world, _, _| {
            start_run(world, 30, "running")?;
            add_item(
                world,
                "assistant_message",
                json!({"messageId": "message:caching",
                       "text": format!("{SENTENCE} Refunds reuse the old rate.")}),
            )?;
            settle_run(world, "completed", 30)?;
            let message = reply(world, 1)?;
            let prose = one(world, message, "markdownProse")?;
            let engine = world.engine().clone();
            let _ = engine.invoke_by_name(prose, "forceActiveFocus", &[]);
            if let Err(error) = engine.invoke_by_name(
                prose,
                "select",
                &[Value::Int(0), Value::Int(SENTENCE.len() as i32)],
            ) {
                fail!("select: {error}");
            }
            world.pump()?;
            let button = one(world, message, "citeSelection")?;
            let brick = timeline_brick(world)?;
            world.wait_for_with(
                |w| brick.flag(w, button, "visible"),
                |w| {
                    format!(
                        "Cite on the selection {} (citable {})",
                        str_of(w, prose, "selectedText"),
                        brick.flag(w, message, "citable")
                    )
                },
            )?;
            click(world, button)?;
            let Some(root) = brick.root(world) else {
                fail!("the timeline brick has no root");
            };
            let quotes = json_list(&str_of(world, root, "quotes"));
            expect!(
                quotes.len() == 1 && quotes[0]["messageId"] == json!("message:caching"),
                "the timeline cited {}",
                show(&json!(quotes))
            );
            world.dispatch("composer.citation.add", quotes[0].clone())
        },
    );
    steps.step(
        "the composer holds a citation of that sentence",
        |world, _, _| {
            let held = |w: &World| -> Vec<Json> {
                at(&w.state("composer"), "citations")
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
            };
            world.wait_for_with(
                |w| {
                    let held = held(w);
                    held.len() == 1 && text(&held[0]["text"]) == SENTENCE
                },
                |w| {
                    format!(
                        "a quote of the sentence; the composer shows {}",
                        show(&json!(held(w)))
                    )
                },
            )
        },
    );

    // The right-click menu on a reply's text.
    steps.step(&format!("the agent answers {Q}"), |world, c, _| {
        answer(world, &c[0])
    });
    steps.step(
        &format!("the user selects {Q} in the reply"),
        |world, c, _| {
            let message = reply(world, 1)?;
            let prose = one(world, message, "markdownProse")?;
            let all = plain(world, prose)?;
            let Some((start, end)) = drawn_range(&all, &c[0]) else {
                fail!("\"{}\" is not shown in \"{all}\"", c[0]);
            };
            if let Err(error) = world.engine().invoke_by_name(
                prose,
                "select",
                &[Value::Int(start as i32), Value::Int(end as i32)],
            ) {
                fail!("select: {error}");
            }
            world.pump()
        },
    );
    steps.step(&format!("the reply's words read {Q}"), |world, c, _| {
        let message = reply(world, 1)?;
        let prose = one(world, message, "markdownProse")?;
        let read = readable(&plain(world, prose)?);
        expect!(read == c[0], "the reply reads \"{read}\"");
        Ok(())
    });
    steps.step(
        &format!("{Q} stays on one line however narrow the timeline is"),
        |world, c, _| {
            let brick = timeline_brick(world)?;
            let Some(timeline) = brick.root(world) else {
                fail!("the timeline brick has no root");
            };
            let wide = f64::from(int_of(world, timeline, "width"));
            let mut wrapped = 0;
            let mut width = wide;
            while width >= 320.0 {
                brick.write(world, timeline, "width", Value::from(width))?;
                world.sync()?;
                let message = reply(world, 1)?;
                let prose = one(world, message, "markdownProse")?;
                let all = plain(world, prose)?;
                let Some((start, end)) = drawn_range(&all, &c[0]) else {
                    fail!("\"{}\" is not shown in \"{all}\"", c[0]);
                };
                let rect_at = |world: &World, at: usize| -> Outcome<f64> {
                    match world.engine().invoke_by_name(
                        prose,
                        "positionToRectangle",
                        &[Value::Int(at as i32)],
                    ) {
                        Ok(Value::Rect(rect)) => Ok(rect.y),
                        Ok(other) => fail!("positionToRectangle gave {other:?}"),
                        Err(error) => fail!("positionToRectangle: {error}"),
                    }
                };
                expect!(
                    rect_at(world, start)? == rect_at(world, end - 1)?,
                    "it splits across lines at {width} wide"
                );
                if int_of(world, prose, "lineCount") > 1 {
                    wrapped += 1;
                }
                width -= 7.0;
            }
            brick.write(world, timeline, "width", Value::from(wide))?;
            world.sync()?;
            expect!(wrapped > 0, "the reply never wrapped");
            Ok(())
        },
    );
    steps.step(
        &format!("the user chooses {Q} from the reply's right-click menu"),
        |world, c, _| {
            let message = reply(world, 1)?;
            let prose = one(world, message, "markdownProse")?;
            open_text_menu(world, prose)?;
            choose_in_text_menu(world, &c[0])
        },
    );
    steps.step("the user right-clicks the reply's text", |world, _, _| {
        let message = reply(world, 1)?;
        let prose = one(world, message, "markdownProse")?;
        open_text_menu(world, prose)
    });
    steps.step(
        &format!("the menu offers {Q} and {Q} only"),
        |world, c, _| {
            let brick = timeline_brick(world)?;
            let mut offered = Vec::new();
            for said in ["Cut", "Copy", "Paste", "Select All"] {
                let shown = brick
                    .find_visible(world, text_menu_item(said)?)?
                    .is_some_and(|item| int_of(world, item, "height") > 0);
                if shown {
                    offered.push(said);
                }
            }
            expect!(
                offered == [c[0].as_str(), c[1].as_str()],
                "the menu offers {}",
                offered.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user chooses {Q} from the code block's right-click menu"),
        |world, c, _| {
            let message = reply(world, 2)?;
            let code = one(world, message, "codeText")?;
            open_text_menu(world, code)?;
            choose_in_text_menu(world, &c[0])
        },
    );
    steps.step("the code block's source is selected", |world, _, _| {
        let message = reply(world, 2)?;
        let code = one(world, message, "codeText")?;
        // Line breaks in a selection are paragraph separators, as in Qt.
        let selected = str_of(world, code, "selectedText").replace(['\u{2028}', '\u{2029}'], "\n");
        expect!(
            selected.trim_end() == SOURCE,
            "the selection is \"{selected}\""
        );
        Ok(())
    });

    // Code blocks.
    steps.step("the agent's reply has a code block", |world, _, _| {
        answer(world, &format!("Here it is:\n\n```ts\n{SOURCE}\n```"))
    });
    steps.step("the user copies the code block", |world, _, _| {
        world.set_clipboard("");
        let message = reply(world, 2)?;
        let copy = one(world, message, "copyCode")?;
        click(world, copy)
    });
    steps.step(
        "the code block's source is on the clipboard",
        |world, _, _| {
            let clipboard = world.clipboard();
            expect!(clipboard == SOURCE, "the clipboard holds \"{clipboard}\"");
            Ok(())
        },
    );
    steps.step("the code block shows it was copied", |world, _, _| {
        let message = reply(world, 2)?;
        let button = one(world, message, "copyCode")?;
        let icon = str_of(world, button, "iconName");
        expect!(
            icon == "check" && str_of(world, button, "label") == "Copied",
            "the copy button shows {icon}"
        );
        world.wait_for("the copy button to come back", |w| {
            str_of(w, button, "iconName") == "copy"
        })
    });
    steps.step(
        "the agent's reply has a code block with a long line",
        |world, _, _| answer(world, &format!("```\n{}\n```", "word ".repeat(80))),
    );
    steps.step(
        "the user turns line wrap (off|on) for the code block",
        |world, c, _| {
            let message = reply(world, 1)?;
            let toggle = one(world, message, "wrapCode")?;
            let on = c[0] == "on";
            let checked =
                |w: &World| w.engine().read_by_name(toggle, "checked") == Value::Bool(true);
            expect!(checked(world) != on, "line wrap is already {}", c[0]);
            click(world, toggle)?;
            expect!(checked(world) == on, "line wrap did not turn {}", c[0]);
            Ok(())
        },
    );
    steps.step("the long line (scrolls sideways|wraps)", |world, c, _| {
        let message = reply(world, 1)?;
        let code = one(world, message, "codeText")?;
        let block = one(world, message, "markdownCode")?;
        let lines = int_of(world, code, "lineCount");
        let (code_width, block_width) =
            (int_of(world, code, "width"), int_of(world, block, "width"));
        if c[0] == "wraps" {
            expect!(
                lines > 1 && code_width <= block_width,
                "the line is {code_width} wide in {lines} lines"
            );
        } else {
            expect!(
                lines == 1 && code_width > block_width,
                "the line is {code_width} wide in {lines} lines"
            );
        }
        Ok(())
    });

    // Tables.
    steps.step("the agent's reply has a table", |world, _, _| {
        answer(world, TABLE)
    });
    steps.step(
        "the user copies the table as (Markdown|CSV)",
        |world, c, _| {
            world.set_clipboard("");
            let message = reply(world, 1)?;
            let copy = one(world, message, "copyTable")?;
            click(world, copy)?;
            let name = if c[0] == "CSV" {
                "copyTableCsv"
            } else {
                "copyTableMarkdown"
            };
            let brick = timeline_brick(world)?;
            // An entry takes clicks once its menu has finished opening.
            let entry = move |w: &World| -> Option<ObjectId> {
                let mut found = Vec::new();
                named(w.engine(), brick.root(w)?, name, &mut found);
                let opened = match found[..] {
                    [item] => match brick.read(w, item, "menu") {
                        Value::Object(menu) => brick.flag(w, menu, "opened"),
                        _ => false,
                    },
                    _ => false,
                };
                opened.then(|| found[0])
            };
            world.wait_for_with(
                |w| entry(w).is_some(),
                |_| format!("the copy menu to offer {}", c[0]),
            )?;
            match entry(world) {
                Some(item) => click(world, item),
                None => fail!("the copy menu went away"),
            }
        },
    );
    steps.step(
        "the table is on the clipboard as (Markdown|CSV)",
        |world, c, _| {
            let expected = if c[0] == "CSV" {
                "Region,Rate\n\"EU, north\",21%\na|b,\"\"\"q\"\"\""
            } else {
                "| Region | Rate |\n| --- | ---: |\n| EU, north | 21% |\n| a\\|b | \"q\" |"
            };
            let clipboard = world.clipboard();
            expect!(clipboard == expected, "the clipboard holds \"{clipboard}\"");
            Ok(())
        },
    );
    steps.step(
        "the agent's reply has a table with a long cell",
        |world, _, _| {
            answer(
                world,
                &format!(
                    "| Region | Rounding |\n|---|---|\n| EU | {}|",
                    "per line, then once more ".repeat(8)
                ),
            )
        },
    );
    steps.step(
        "the user (collapses|expands) the table cells",
        |world, c, _| {
            let message = reply(world, 1)?;
            let toggle = one(world, message, "expandTable")?;
            let expand = c[0] == "expands";
            let checked = world.engine().read_by_name(toggle, "checked") == Value::Bool(true);
            expect!(
                checked != expand,
                "the table cells are already {}",
                if expand { "expanded" } else { "collapsed" }
            );
            click(world, toggle)
        },
    );
    steps.step("the long cell (stays on one line|wraps)", |world, c, _| {
        let message = reply(world, 1)?;
        let cells = within(world, message, "tableCell");
        let Some(&cell) = cells.last() else {
            fail!("the table has no cells");
        };
        let lines = int_of(world, cell, "lineCount");
        let wraps = c[0] == "wraps";
        expect!(
            if wraps { lines > 1 } else { lines == 1 },
            "the long cell takes {lines} lines"
        );
        Ok(())
    });

    steps.step(
        "every row of the table holds its cells' text",
        |world, _, _| {
            let message = reply(world, 1)?;
            let cells = within(world, message, "tableCell");
            expect!(!cells.is_empty(), "the table has no cells");
            let real = |item: ObjectId, name: &str| match world.engine().read_by_name(item, name) {
                Value::Real(r) => r,
                Value::Int(n) => f64::from(n),
                _ => f64::NAN,
            };
            for (i, cell) in cells.into_iter().enumerate() {
                // The cell's box is its row's height and clips the text.
                let Value::Object(cell_box) = world.engine().read_by_name(cell, "parent") else {
                    fail!("a table cell has no box");
                };
                let bottom = real(cell, "y") + real(cell, "height");
                let row = real(cell_box, "height");
                expect!(
                    real(cell, "y") >= 0.0 && bottom <= row,
                    "cell {i}'s text ends at {bottom} in a row {row} tall"
                );
            }
            Ok(())
        },
    );

    // Untrusted text.
    steps.step("the agent answers with HTML and an image", |world, _, _| {
        answer(
            world,
            "<script>alert(1)</script> <b>bold?</b> <img src=\"https://example.com/x.png\">\n\n![pic](https://example.com/y.png)",
        )
    });
    steps.step("the HTML is shown as written", |world, _, _| {
        let message = reply(world, 1)?;
        let prose = one(world, message, "markdownProse")?;
        let shown = plain(world, prose)?;
        expect!(
            shown.contains("<script>alert(1)</script>")
                && shown.contains("<b>bold?</b>")
                && shown.contains("<img src=\"https://example.com/x.png\">"),
            "the reply reads \"{shown}\""
        );
        Ok(())
    });
    steps.step(
        "the image is a link to its address and nothing is loaded from the web",
        |world, _, _| {
            let brick = timeline_brick(world)?;
            let message = reply(world, 1)?;
            let edit = one(world, message, "markdownProse")?;
            expect!(
                !str_of(world, edit, "text").contains("<img"),
                "the reply draws an image"
            );
            let (link, _) = link_at(world, brick, edit, "pic")?;
            expect!(
                link == "https://example.com/y.png",
                "the image links to \"{link}\""
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the agent answers with a link to {Q}"),
        |world, c, _| answer(world, &format!("Open [the pricing docs]({}) now.", c[0])),
    );
    steps.step(
        "the link's text is shown and nothing can be opened",
        |world, _, _| {
            let brick = timeline_brick(world)?;
            let message = reply(world, 1)?;
            let edit = one(world, message, "markdownProse")?;
            let (link, point) = link_at(world, brick, edit, "pricing docs")?;
            expect!(link.is_empty(), "\"the pricing docs\" links to \"{link}\"");
            expect!(
                !str_of(world, edit, "text").contains("javascript:"),
                "the reply carries the script"
            );
            click_link(world, point, MouseButtons::LEFT, Modifiers::empty())?;
            let opened = activated(world)?;
            expect!(
                opened.is_empty(),
                "the click opened {}",
                show(&json!(opened))
            );
            Ok(())
        },
    );

    // A reply being written.
    steps.step(
        "the agent is writing a reply of several paragraphs",
        |world, _, _| {
            start_writing(world, "Discounts apply first.\n\nTax rounds to the cent.")?;
            let message = reply(world, 2)?;
            let prose = within(world, message, "markdownProse");
            let segments = int_of(world, message, "segmentCount");
            let seen = world.part::<Seen>();
            seen.item = prose.first().copied();
            seen.segments = segments;
            Ok(())
        },
    );
    steps.step("the reply grows by another paragraph", |world, _, _| {
        write(world, " Per line for VAT.")?;
        write(world, "\n\nTotals are cached")?;
        write(world, " until the cart changes.")
    });
    steps.step(
        "the paragraphs already shown are not drawn again",
        |world, _, _| {
            let segments = world.part::<Seen>().segments;
            let first = world.part::<Seen>().item;
            let message = reply(world, segments + 1)?;
            let prose = within(world, message, "markdownProse");
            let Some(&last_item) = prose.last() else {
                fail!("the reply has no text");
            };
            let last = plain(world, last_item)?;
            expect!(
                last.contains("until the cart changes."),
                "the reply ends \"{last}\""
            );
            expect!(
                first.is_some() && prose.first().copied() == first,
                "the first paragraph was drawn anew"
            );
            Ok(())
        },
    );
    steps.step("the agent is writing a code block", |world, _, _| {
        world.part::<Seen>().code = "def refund(order):\n    return order.total".to_owned();
        start_writing(
            world,
            "Checking the refund path:\n\n```py\ndef refund(order):\n    return order.total",
        )
    });
    steps.step(
        "the code written so far is shown as a code block",
        |world, _, _| {
            let message = reply(world, 2)?;
            let segments = within(world, message, "markdownSegment");
            let Some(&segment) = segments.last() else {
                fail!("the reply shows no segments");
            };
            expect!(
                str_of(world, segment, "kind") == "code"
                    && world.engine().read_by_name(segment, "open") == Value::Bool(true),
                "the reply is drawn as {}",
                kinds_of(world, message).join(", ")
            );
            let code = one(world, message, "codeText")?;
            let shown = plain(world, code)?;
            let wanted = world.part::<Seen>().code.clone();
            expect!(
                flag_of(world, code, "visible") && shown == wanted,
                "the code reads \"{shown}\""
            );
            // A diagram not finished yet is not drawn, nor asked for.
            expect!(
                super::mermaid::asked(world)? == 0,
                "the MC was asked to draw a diagram being written"
            );
            world.part::<Seen>().item = Some(code);
            Ok(())
        },
    );
    steps.step("the agent closes the code block", |world, _, _| {
        write(world, "\n```")
    });
    steps.step("the same code block is shown, finished", |world, _, _| {
        let message = reply(world, 2)?;
        let segments = within(world, message, "markdownSegment");
        let Some(&segment) = segments.last() else {
            fail!("the reply shows no segments");
        };
        world.wait_for("the code block to close", |w| {
            w.engine().read_by_name(segment, "open") != Value::Bool(true)
        })?;
        let code = one(world, message, "codeText")?;
        expect!(
            Some(code) == world.part::<Seen>().item,
            "the code block was drawn anew"
        );
        Ok(())
    });

    steps.step(
        "the agent is still writing a \"mermaid\" code block",
        |world, _, _| {
            world.part::<Seen>().code = super::mermaid::FLOWCHART.to_owned();
            start_writing(
                world,
                &format!(
                    "How an order is paid:\n\n```mermaid\n{}",
                    super::mermaid::FLOWCHART
                ),
            )
        },
    );

    // Mermaid diagrams (the mermaid steps answer the MC's part).
    steps.step(
        "the agent answers with a \"mermaid\" code block holding a flowchart( with an unclosed bracket)?",
        |world, c, _| {
            let code = if c[0].is_empty() {
                super::mermaid::FLOWCHART
            } else {
                super::mermaid::BROKEN_FLOWCHART
            };
            world.part::<Seen>().code = code.to_owned();
            answer(
                world,
                &format!("How an order is paid:\n\n```mermaid\n{code}\n```"),
            )
        },
    );
    steps.step(
        "on the desktop and the phone the flowchart is drawn in place of the code block",
        |world, _, _| {
            let brick = timeline_brick(world)?;
            let message = reply(world, 2)?;
            world.wait_for_with(
                move |w| super::mermaid::drawn(w, brick).len() == 1,
                move |w| {
                    let images: Vec<String> = super::mermaid::shown(w, brick, "mermaidImage")
                        .into_iter()
                        .map(|image| format!("{:?}", w.engine().read_by_name(image, "status")))
                        .collect();
                    format!(
                        "the diagram to be drawn; the MC was asked {} times, images [{}]",
                        w.mc.calls
                            .iter()
                            .filter(|rpc| rpc.method == "mermaid.render")
                            .count(),
                        images.join(", ")
                    )
                },
            )?;
            let code = one(world, message, "codeText")?;
            expect!(
                !flag_of(world, code, "visible"),
                "the diagram's source shows beside it"
            );
            let asked = super::mermaid::asked(world)?;
            expect!(asked == 1, "the MC was asked {asked} times");
            Ok(())
        },
    );
    steps.step(
        "the user can switch to the diagram's source and copy it",
        |world, _, _| {
            let brick = timeline_brick(world)?;
            let message = reply(world, 2)?;
            let toggle = one(world, message, "diagramSource")?;
            click(world, toggle)?;
            let code = one(world, message, "codeText")?;
            world.wait_for("the source to be shown in place of the diagram", move |w| {
                flag_of(w, code, "visible") && super::mermaid::drawn(w, brick).is_empty()
            })?;
            let wanted = world.part::<Seen>().code.clone();
            let shown = plain(world, code)?;
            expect!(shown == wanted, "the source reads \"{shown}\"");
            world.set_clipboard("");
            let copy = one(world, message, "copyCode")?;
            click(world, copy)?;
            world.wait_for_with(
                move |w| w.clipboard() == wanted,
                move |w| {
                    format!(
                        "the source to be copied; the clipboard has \"{}\"",
                        w.clipboard()
                    )
                },
            )
        },
    );
    steps.step(
        "the diagram's source is shown as a code block",
        |world, _, _| {
            let brick = timeline_brick(world)?;
            let message = reply(world, 2)?;
            let code = one(world, message, "codeText")?;
            world.wait_for("the MC to answer", move |w| {
                w.mc.calls
                    .iter()
                    .filter(|rpc| rpc.method == "mermaid.render")
                    .count()
                    == 1
                    && !brick.shows(w, "Drawing the diagram…").unwrap_or(false)
            })?;
            let wanted = world.part::<Seen>().code.clone();
            let shown = plain(world, code)?;
            expect!(
                flag_of(world, code, "visible") && shown == wanted,
                "the code block reads \"{shown}\""
            );
            let toggle = one(world, message, "diagramSource")?;
            expect!(
                !flag_of(world, toggle, "visible"),
                "a diagram that was not drawn offers to show its source"
            );
            Ok(())
        },
    );

    // Alerts.
    steps.step(
        &format!("the agent answers with a {Q} alert"),
        |world, c, _| {
            answer(
                world,
                &format!("> [!{}]\n> Refunds reuse the old rate.", c[0]),
            )
        },
    );
    steps.step(&format!("the quote is titled {Q}"), |world, c, _| {
        let message = reply(world, 1)?;
        let quote = one(world, message, "markdownQuote")?;
        let title = one(world, quote, "alertTitle")?;
        let shown = str_of(world, title, "text");
        expect!(
            world.engine().read_by_name(title, "visible") == Value::Bool(true) && shown == c[0],
            "the quote is titled \"{shown}\""
        );
        Ok(())
    });

    // The user's own message.
    steps.step("the user's message has two lines", |world, _, _| {
        let run = start_run(world, 30, "running")?;
        set(
            world,
            "turn-item",
            &format!("message:{run}"),
            json!({"text": "Thanks!\nWhat about refunds?"}),
        )
    });
    steps.step("the message is shown on two lines", |world, _, _| {
        let brick = timeline_brick(world)?;
        let edit = move |w: &World| -> Option<ObjectId> {
            let users = messages(w, brick, true);
            let prose = within(w, *users.last()?, "markdownProse");
            let edit = *prose.first()?;
            plain(w, edit).ok()?.contains("refunds").then_some(edit)
        };
        world.wait_for_with(
            |w| edit(w).is_some(),
            |_| "the user's message to be shown".into(),
        )?;
        let Some(edit) = edit(world) else {
            fail!("the message went away");
        };
        let lines = int_of(world, edit, "lineCount");
        expect!(lines == 2, "the message takes {lines} lines");
        Ok(())
    });

    // Bare web addresses (scrolling-and-links.feature).
    steps.step(&format!("the agent writes {Q}"), |world, c, _| {
        answer(world, &c[0])
    });
    steps.step(&format!("{Q} can be opened as a link"), |world, c, _| {
        let brick = timeline_brick(world)?;
        let message = reply(world, 1)?;
        let edit = one(world, message, "markdownProse")?;
        let (link, point) = link_at(world, brick, edit, &c[0])?;
        expect!(link == c[0], "\"{}\" links to \"{link}\"", c[0]);
        // Ctrl (Cmd on macOS) opens it; a plain click selects.
        click_link(world, point, MouseButtons::LEFT, primary())?;
        let opened = activated(world)?;
        expect!(
            opened == [json!(c[0])],
            "the click opened {}",
            show(&json!(opened))
        );
        Ok(())
    });

    // A link in a reply, followed with the mouse or from its menu.
    steps.step(&format!("the agent's reply links to {Q}"), |world, c, _| {
        answer(world, &format!("See [{0}]({0}) for the details.", c[0]))?;
        world.part::<Seen>().link = c[0].clone();
        Ok(())
    });
    // A file of the project's workspace, linked by its path.
    steps.step(
        &format!("the agent's reply links to the file {Q}"),
        |world, c, _| {
            fake_files(&mut world.mc)
                .files
                .entry(c[0].clone())
                .or_default();
            answer(world, &format!("See [{0}]({0}).", c[0]))?;
            world.part::<Seen>().link = c[0].clone();
            Ok(())
        },
    );
    steps.step(
        "the user clicks the link (without holding Ctrl|holding Ctrl \\(Cmd on macOS\\))",
        |world, c, _| {
            let point = link_point(world)?;
            let with = if c[0].starts_with("without") {
                Modifiers::empty()
            } else {
                primary()
            };
            click_link(world, point, MouseButtons::LEFT, with)?;
            world.sync()
        },
    );
    steps.step(&format!("{Q} is opened"), |world, c, _| {
        let opened = activated(world)?;
        expect!(
            opened == [json!(c[0])],
            "the click opened {}",
            show(&json!(opened))
        );
        Ok(())
    });
    steps.step("the user opens the menu on the link", |world, _, _| {
        let point = link_point(world)?;
        click_link(world, point, MouseButtons::RIGHT, Modifiers::empty())?;
        world.wait_for("the link's menu to open", |w| {
            at(&w.state("menu"), "items")
                .as_array()
                .is_some_and(|items| !items.is_empty())
        })
    });
    // The same address in inline code and in a code block, in the next reply.
    steps.step(
        "web addresses inside code are left as text",
        |world, _, _| {
            let address = "https://example.com/docs";
            answer(
                world,
                &format!("Try `{address}` or:\n\n```\ncurl {address}\n```"),
            )?;
            let brick = timeline_brick(world)?;
            let message = reply(world, 2)?;
            let prose = one(world, message, "markdownProse")?;
            let (link, _) = link_at(world, brick, prose, address)?;
            expect!(link.is_empty(), "inline code links to \"{link}\"");
            let code = one(world, message, "codeText")?;
            let (code_link, _) = link_at(world, brick, code, address)?;
            expect!(
                code_link.is_empty() && !str_of(world, code, "text").contains("href"),
                "the code block links to \"{code_link}\""
            );
            Ok(())
        },
    );
}
