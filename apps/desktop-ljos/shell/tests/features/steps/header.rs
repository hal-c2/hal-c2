//! The header strip as the desktop draws it (qml/HalC2/Bricks/Workspace.qml)
//! over the scenario's shell (navigation/layout.feature's header): the brick
//! is loaded into an offscreen window, laid out at a width and read, then
//! thrown away. desktop-qt's HeaderSteps.cpp.

use serde_json::json;

use super::stream::THREAD;
use crate::brick::Brick;
use crate::expect;
use crate::harness::{Outcome, Steps, at};
use crate::world::World;

const LONG_TITLE: &str = "Move the checkout of every thread onto the MC that owns its project, keeping the agent's session";

/// The width the header is laid out at, set by the "When" steps.
#[derive(Default)]
struct HeaderWidth(f64);

/// The header's thread title laid out at the header's width.
struct Title {
    text: String,
    truncated: bool,
    width: f64,
}

fn lay_out_title(world: &mut World) -> Outcome<Title> {
    let width = world.part::<HeaderWidth>().0;
    let header = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nWorkspace { height: 52 }\n",
        width,
        52.0,
    )?;
    let label = header.item(world, "threadLabel")?;
    // Layouts settle on the window's polish, before its next frame.
    world.wait_for("the header to lay out the thread title", |w| {
        let wide = header.read(w, label, "width").as_number().unwrap_or(0.0) > 0.0;
        wide && header.text_of(w, label, "text") != "No thread"
    })?;
    world.pump()?;
    let width = header
        .read(world, label, "width")
        .as_number()
        .unwrap_or(0.0);
    Ok(Title {
        text: header.text_of(world, label, "text"),
        truncated: header.flag(world, label, "truncated"),
        width,
    })
}

pub fn register(steps: &mut Steps) {
    steps.step("a long thread title", |world, _, _| {
        // The thread the background looks at, renamed.
        let mut row = world.mc.threads.get(THREAD).cloned().unwrap_or(json!({}));
        row["title"] = json!(LONG_TITLE);
        world.mc.threads.insert(THREAD.into(), row.clone());
        world.mc.send_row(THREAD, &row);
        world.wait_for_with(
            |w| at(&w.state("workspace"), "threadTitle") == LONG_TITLE,
            |w| {
                format!(
                    "the header to show the long title; it shows {}",
                    crate::harness::show(&w.state("workspace"))
                )
            },
        )
    });
    steps.step("the window is wide", |world, _, _| {
        world.part::<HeaderWidth>().0 = 1600.0;
        Ok(())
    });
    steps.step("the header is narrow", |world, _, _| {
        world.part::<HeaderWidth>().0 = 480.0;
        Ok(())
    });
    steps.step("the whole title is shown", |world, _, _| {
        let title = lay_out_title(world)?;
        expect!(
            title.text == LONG_TITLE && !title.truncated,
            "the header shows \"{}\" (shortened: {})",
            title.text,
            title.truncated
        );
        Ok(())
    });
    steps.step("the title is shortened with an ellipsis", |world, _, _| {
        let title = lay_out_title(world)?;
        expect!(
            title.text == LONG_TITLE && title.truncated,
            "the header shows \"{}\" (shortened: {})",
            title.text,
            title.truncated
        );
        Ok(())
    });
    steps.step("the start of the title still shows", |world, _, _| {
        // Room for a few letters, not a bare ellipsis (40 px).
        let title = lay_out_title(world)?;
        expect!(title.width >= 40.0, "the title has {} px", title.width);
        Ok(())
    });
}
