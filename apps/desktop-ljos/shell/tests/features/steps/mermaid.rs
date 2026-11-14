//! Mermaid diagrams (features/timeline/markdown.feature,
//! features/files/file-viewer-and-editing.feature, and a page's in
//! features/space/markdown.feature, whose steps are the space steps') as
//! the desktop draws them: the fake MC answers `mermaid.render` the way
//! the MC's renderer does, the shell's Mermaid controller (the
//! `Diagrams` singleton) asks it, and the steps read back the
//! MermaidDiagram bricks of whatever brick the scenario shows (a reply
//! in the timeline, or the Files tab's rendered view):
//! desktop-qt's MermaidSteps.cpp and Mermaid.h.

use ljos::prelude::{Engine, ObjectId, Value};
use serde_json::{Value as Json, json};

use crate::brick::{self, Brick};
use crate::expect;
use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, text};
use crate::world::World;

/// A flowchart, and one with a bracket left open on its second line.
pub const FLOWCHART: &str = "flowchart LR\n  Cart --> Pay";
pub const BROKEN_FLOWCHART: &str = "flowchart LR\n  Cart[Cart --> Pay";

/// What the fake renderer draws: a box the Image can load.
const SVG: &str = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"160\" height=\"60\" viewBox=\"0 0 160 60\">\
                   <rect x=\"1\" y=\"1\" width=\"158\" height=\"58\" rx=\"6\" fill=\"none\" stroke=\"#888\"/></svg>";

/// packages/contracts mermaid.ts's answers: a bracket opened and not
/// closed is the mistake the scenarios make, on the line it is on;
/// "block-beta" is a type the renderer cannot draw (native/mermaid's
/// words); anything else is drawn.
fn extension(mc: &mut FakeMc) {
    mc.on_rpc("mermaid.render", |mc, rpc| {
        let source = text(&rpc.payload["source"]);
        let kind = source.split_whitespace().next().unwrap_or_default();
        if kind == "block-beta" {
            mc.reply(
                rpc,
                json!({"status": "unsupported", "kind": kind,
                       "reason": format!("{kind} diagrams cannot be drawn yet.")}),
            );
            return Ok(());
        }
        for (at, line) in source.lines().enumerate() {
            if line.matches('[').count() > line.matches(']').count() {
                mc.reply(
                    rpc,
                    json!({"status": "invalid", "kind": kind,
                           "reason": "A bracket is opened and not closed.",
                           "line": at + 1, "column": Json::Null}),
                );
                return Ok(());
            }
        }
        mc.reply(
            rpc,
            json!({"status": "drawn", "kind": kind, "svg": SVG, "width": 160, "height": 60}),
        );
        Ok(())
    });
}

fn collect_shown(engine: &Engine, item: ObjectId, name: &str, out: &mut Vec<ObjectId>) {
    if engine.read_by_name(item, "visible") != Value::Bool(true) {
        return;
    }
    if matches!(engine.read_by_name(item, "objectName"), Value::String(ref s) if s.as_str() == name)
    {
        out.push(item);
    }
    for child in engine.children(item) {
        collect_shown(engine, child, name, out);
    }
}

/// The visible items named `object_name` in the shown brick's window.
pub fn shown(world: &World, brick: Brick, object_name: &str) -> Vec<ObjectId> {
    let mut out = Vec::new();
    if let Some(root) = brick.root(world) {
        collect_shown(world.engine(), root, object_name, &mut out);
    }
    out
}

/// The diagrams the shown brick shows drawn: visible and loaded.
pub fn drawn(world: &World, brick: Brick) -> Vec<ObjectId> {
    shown(world, brick, "mermaidImage")
        .into_iter()
        // QQuickImageBase::Ready.
        .filter(|&image| {
            matches!(
                world.engine().read_by_name(image, "status"),
                Value::Int(1) | Value::Real(1.0)
            )
        })
        .collect()
}

/// How often the MC was asked to draw one.
pub fn asked(world: &mut World) -> Outcome<usize> {
    world.sync()?;
    Ok(world
        .mc
        .calls
        .iter()
        .filter(|rpc| rpc.method == "mermaid.render")
        .count())
}

fn describe_notes(world: &World, brick: Brick) -> String {
    let notes: Vec<String> = shown(world, brick, "mermaidStatus")
        .iter()
        .map(|&note| match world.engine().read_by_name(note, "text") {
            Value::String(s) => s.as_str().to_owned(),
            _ => String::new(),
        })
        .collect();
    format!(
        "{} diagrams drawn, {} notes [{}]",
        drawn(world, brick).len(),
        notes.len(),
        notes.join(", ")
    )
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);
    steps.step("the diagram is drawn", |world, _, _| {
        let brick = brick::shown(world)?;
        world.wait_for_with(
            move |w| drawn(w, brick).len() == 1,
            move |w| describe_notes(w, brick),
        )
    });
    // The terminal's; the desktop draws the diagram.
    steps.step(
        &format!(
            "in the terminal the diagram is drawn in characters, or its source is shown, named as a {Q} diagram"
        ),
        |_, _, _| Ok(()),
    );
    steps.step("the user is told where the mistake is", |world, _, _| {
        let brick = brick::shown(world)?;
        world.wait_for_with(
            move |w| {
                let notes = shown(w, brick, "mermaidStatus");
                notes.len() == 1
                    && matches!(w.engine().read_by_name(notes[0], "text"),
                                Value::String(ref s) if s.as_str() == "Line 2: A bracket is opened and not closed.")
            },
            move |w| describe_notes(w, brick),
        )
    });
    steps.step(
        "nothing claims the diagram is still being drawn",
        |world, _, _| {
            world.sync()?;
            let brick = brick::shown(world)?;
            expect!(
                !brick.shows(world, "Drawing the diagram…")? && drawn(world, brick).is_empty(),
                "{}",
                describe_notes(world, brick)
            );
            expect!(
                shown(world, brick, "mermaidRetry").is_empty(),
                "a mistake is offered to be drawn again"
            );
            Ok(())
        },
    );
}
