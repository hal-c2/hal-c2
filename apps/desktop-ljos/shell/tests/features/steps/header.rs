//! The header strip as the desktop draws it (qml/HalC2/Bricks/Workspace.qml)
//! over the scenario's shell (navigation/layout.feature's header): the brick
//! is loaded into an offscreen window, laid out at a width and read, then
//! thrown away. desktop-qt's HeaderSteps.cpp.

use serde_json::json;

use super::stream::THREAD;
use crate::brick::Brick;
use crate::expect;
use crate::harness::{Outcome, Q, Steps, at, show};
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

/// How much room the header has for its actions, set by the "When" steps:
/// a width, or just too little for their labels or their icons.
#[derive(Clone, Copy, Default, PartialEq)]
enum Fit {
    #[default]
    Width,
    NoLabels,
    NoIcons,
}

#[derive(Default)]
struct HeaderFit(Fit);

/// The header's run and open actions laid out at the fit.
struct Actions {
    run: String,
    open: String,
    pills: bool,
    project: bool,
    overflow: Vec<String>,
}

fn lay_out_actions(world: &mut World) -> Outcome<Actions> {
    let header = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nWorkspace { height: 52 }\n",
        1600.0,
        52.0,
    )?;
    let strip = header.root(world);
    let Some(strip) = strip else {
        crate::fail!("the header did not load");
    };
    world.wait_for_with(
        |w| header.flag(w, strip, "hasScripts") && header.flag(w, strip, "hasEditors"),
        |w| {
            format!(
                "the header to have actions and editors: {}",
                show(&w.state("workspace"))
            )
        },
    )?;
    // `room` is the strip less its margins; one pixel short of a level's
    // need.
    let margins = header
        .read(world, strip, "width")
        .as_number()
        .unwrap_or(0.0)
        - header.read(world, strip, "room").as_number().unwrap_or(0.0);
    let fit = world.part::<HeaderFit>().0;
    let width = world.part::<HeaderWidth>().0;
    let set_width = match fit {
        Fit::Width => Some(width),
        Fit::NoLabels => Some(
            (header
                .read(world, strip, "labelledNeed")
                .as_number()
                .unwrap_or(0.0)
                + margins)
                .ceil()
                - 1.0,
        ),
        Fit::NoIcons => Some(
            (header
                .read(world, strip, "iconNeed")
                .as_number()
                .unwrap_or(0.0)
                + margins)
                .ceil()
                - 1.0,
        ),
    };
    if let Some(w) = set_width {
        header.write(world, strip, "width", ljos::prelude::Value::from(w))?;
    }
    world.pump()?;
    let run = header.item(world, "runActionButton")?;
    let open = header.item(world, "openEditorButton")?;
    let pills = header.flag(world, run, "visible") && header.flag(world, open, "visible");
    let project = header.flag(world, header.item(world, "projectLabel")?, "visible");
    let run_text = header
        .find_under(world, run, "splitAction")?
        .map_or(String::new(), |item| header.text_of(world, item, "text"));
    let open_text = header
        .find_under(world, open, "splitAction")?
        .map_or(String::new(), |item| header.text_of(world, item, "text"));
    let mut overflow = Vec::new();
    if header.flag(world, header.item(world, "headerOverflow")?, "visible")
        && let Some(menu) = header.find_under(world, strip, "headerOverflowMenu")?
    {
        // A closed menu's entries are not visible: open it, as a click on
        // the button does.
        world
            .engine()
            .invoke_by_name(menu, "open", &[])
            .map_err(|e| crate::harness::Failure(format!("open: {e:?}")))?;
        world.pump()?;
        let count = match header.read(world, menu, "count") {
            ljos::prelude::Value::Int(n) => n,
            ljos::prelude::Value::Real(n) => n as i32,
            _ => 0,
        };
        for i in 0..count {
            let entry = world
                .engine()
                .invoke_by_name(menu, "itemAt", &[ljos::prelude::Value::Int(i)])
                .map_err(|e| crate::harness::Failure(format!("itemAt: {e:?}")))?;
            if let ljos::prelude::Value::Object(entry) = entry
                && header.flag(world, entry, "visible")
            {
                overflow.push(header.text_of(world, entry, "text"));
            }
        }
        let _ = world.engine().invoke_by_name(menu, "close", &[]);
    }
    Ok(Actions {
        run: run_text,
        open: open_text,
        pills,
        project,
        overflow,
    })
}

fn describe(actions: &Actions) -> String {
    format!(
        "the header shows run \"{}\" and open \"{}\" (pills shown: {}, project shown: {}), its overflow menu [{}]",
        actions.run,
        actions.open,
        actions.pills,
        actions.project,
        actions.overflow.join(", ")
    )
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
        world.part::<HeaderFit>().0 = Fit::Width;
        world.part::<HeaderWidth>().0 = 1600.0;
        Ok(())
    });
    steps.step(
        "the header is as wide as a 900 pixel window leaves it",
        |world, _, _| {
            // Beside the sidebar at its default width and the border
            // between them.
            world.part::<HeaderFit>().0 = Fit::Width;
            world.part::<HeaderWidth>().0 = 900.0 - 256.0 - 1.0;
            Ok(())
        },
    );
    steps.step(
        "the header has no room for its actions' labels",
        |world, _, _| {
            world.part::<HeaderFit>().0 = Fit::NoLabels;
            Ok(())
        },
    );
    steps.step(
        "the header has no room for its actions as icons",
        |world, _, _| {
            world.part::<HeaderFit>().0 = Fit::NoIcons;
            Ok(())
        },
    );
    steps.step(
        "the header actions show with their labels",
        |world, _, _| {
            let actions = lay_out_actions(world)?;
            expect!(
                actions.pills
                    && actions.run.starts_with("Run ")
                    && actions.open == "Open"
                    && actions.overflow.is_empty(),
                "{}",
                describe(&actions)
            );
            Ok(())
        },
    );
    steps.step(
        "the header actions show without their labels",
        |world, _, _| {
            let actions = lay_out_actions(world)?;
            expect!(
                actions.pills
                    && actions.run.is_empty()
                    && actions.open.is_empty()
                    && actions.overflow.is_empty(),
                "{}",
                describe(&actions)
            );
            Ok(())
        },
    );
    steps.step("the header shows the project's name", |world, _, _| {
        let actions = lay_out_actions(world)?;
        expect!(actions.project, "{}", describe(&actions));
        Ok(())
    });
    steps.step("the header leaves the project's name out", |world, _, _| {
        let actions = lay_out_actions(world)?;
        expect!(!actions.project, "{}", describe(&actions));
        Ok(())
    });
    steps.step(
        &format!("the header's {Q} menu runs {Q} and opens in {Q}"),
        |world, c, _| {
            let actions = lay_out_actions(world)?;
            expect!(
                !actions.pills
                    && actions.overflow.contains(&format!("Run {}", c[1]))
                    && actions.overflow.contains(&format!("Open in {}", c[2])),
                "{}",
                describe(&actions)
            );
            Ok(())
        },
    );
    steps.step("the header is narrow", |world, _, _| {
        world.part::<HeaderFit>().0 = Fit::Width;
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
