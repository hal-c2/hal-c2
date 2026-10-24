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

/// The link under the middle of `needle` in a rich text segment, and the
/// point the user would click in the window.
fn link_at(
    world: &World,
    brick: Brick,
    edit: ObjectId,
    needle: &str,
) -> Outcome<(String, (f64, f64))> {
    let all = plain(world, edit)?;
    let Some(byte) = all.find(needle) else {
        fail!("\"{needle}\" is not shown in \"{all}\"");
    };
    let at = all[..byte].encode_utf16().count() + needle.encode_utf16().count() / 2;
    let rect = match world
        .engine()
        .invoke_by_name(edit, "positionToRectangle", &[Value::Int(at as i32)])
    {
        Ok(Value::Rect(rect)) => rect,
        Ok(other) => fail!("positionToRectangle gave {other:?}"),
        Err(error) => fail!("positionToRectangle: {error}"),
    };
    let (x, y) = (rect.x + 1.0, rect.y + rect.height / 2.0);
    let link = match world
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

fn click_link(world: &mut World, point: (f64, f64), button: MouseButtons, with: Modifiers) -> Outcome {
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
    steps.step("the heading and the list are shown as text", |world, _, _| {
        let message = reply(world, 4)?;
        let prose = within(world, message, "markdownProse");
        let Some(&first) = prose.first() else {
            fail!("the reply has no text");
        };
        let shown = plain(world, first)?;
        expect!(
            shown.contains("Cart totals") && shown.contains("Tax second") && !shown.contains('#'),
            "the reply reads \"{shown}\""
        );
        Ok(())
    });
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
    steps.step("the code block's source is on the clipboard", |world, _, _| {
        let clipboard = world.clipboard();
        expect!(clipboard == SOURCE, "the clipboard holds \"{clipboard}\"");
        Ok(())
    });
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
            let checked = |w: &World| w.engine().read_by_name(toggle, "checked") == Value::Bool(true);
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
        let (code_width, block_width) = (int_of(world, code, "width"), int_of(world, block, "width"));
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
    steps.step("the agent's reply has a table", |world, _, _| answer(world, TABLE));
    steps.step(
        "the user copies the table as (Markdown|CSV)",
        |world, c, _| {
            world.set_clipboard("");
            let message = reply(world, 1)?;
            let copy = one(world, message, "copyTable")?;
            click(world, copy)?;
            let name = if c[0] == "CSV" { "copyTableCsv" } else { "copyTableMarkdown" };
            let brick = timeline_brick(world)?;
            let entry = move |w: &World| -> Option<ObjectId> {
                let mut found = Vec::new();
                named(w.engine(), brick.root(w)?, name, &mut found);
                (found.len() == 1 && brick.flag(w, found[0], "visible")).then(|| found[0])
            };
            world.wait_for_with(|w| entry(w).is_some(), |_| format!("the copy menu to offer {}", c[0]))?;
            match entry(world) {
                Some(item) => click(world, item),
                None => fail!("the copy menu went away"),
            }
        },
    );
    steps.step("the table is on the clipboard as (Markdown|CSV)", |world, c, _| {
        let expected = if c[0] == "CSV" {
            "Region,Rate\n\"EU, north\",21%\na|b,\"\"\"q\"\"\""
        } else {
            "| Region | Rate |\n| --- | ---: |\n| EU, north | 21% |\n| a\\|b | \"q\" |"
        };
        let clipboard = world.clipboard();
        expect!(clipboard == expected, "the clipboard holds \"{clipboard}\"");
        Ok(())
    });
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
    steps.step("the user (collapses|expands) the table cells", |world, c, _| {
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
    });
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
    steps.step(&format!("the agent answers with a link to {Q}"), |world, c, _| {
        answer(world, &format!("Open [the pricing docs]({}) now.", c[0]))
    });
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
            expect!(opened.is_empty(), "the click opened {}", show(&json!(opened)));
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
            expect!(
                shown == "def refund(order):\n    return order.total",
                "the code reads \"{shown}\""
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

    // Alerts.
    steps.step(&format!("the agent answers with a {Q} alert"), |world, c, _| {
        answer(world, &format!("> [!{}]\n> Refunds reuse the old rate.", c[0]))
    });
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
        world.wait_for_with(|w| edit(w).is_some(), |_| "the user's message to be shown".into())?;
        let Some(edit) = edit(world) else {
            fail!("the message went away");
        };
        let lines = int_of(world, edit, "lineCount");
        expect!(lines == 2, "the message takes {lines} lines");
        Ok(())
    });

    // Bare web addresses (scrolling-and-links.feature).
    steps.step(&format!("the agent writes {Q}"), |world, c, _| answer(world, &c[0]));
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
