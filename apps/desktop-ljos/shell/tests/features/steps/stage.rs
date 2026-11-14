//! The stage in a whole window (features/desktop/stage.feature): the
//! default shell or one of desktop-qt's example shells
//! (`apps/desktop-qt/examples`) drawing the thread's centre, whose
//! CentreHost draws the stage: desktop-qt's SpaceSteps.cpp `shellWindow`
//! and "the window shows the … tab in the centre".

use std::path::PathBuf;

use ljos::prelude::{Engine, ObjectId, Value as Qml};

use crate::brick::{self, Brick};
use crate::harness::{Failure, Outcome, Q, Steps};
use crate::world::World;
use crate::{expect, fail};

/// The window's size, as desktop-qt's default shell.qml sizes it.
const SIZE: (f64, f64) = (1200.0, 800.0);

fn examples() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../desktop-qt/examples")
}

/// `shell` ("default", or an example's name) as the window: the example's
/// shell.qml, made on the checkout's bricks in the world's engine.
fn shell_window(world: &mut World, shell: &str) -> Outcome<Brick> {
    expect!(
        world.part::<brick::Shown>().0.is_none(),
        "the window is already drawn"
    );
    let qml = if shell == "default" {
        "import HalC2.Bricks\nDefaultShell { width: 1200; height: 800 }\n".to_owned()
    } else {
        let path = examples().join(shell).join("shell.qml");
        std::fs::read_to_string(&path)
            .map_err(|e| Failure(format!("no example shell at {}: {e}", path.display())))?
    };
    if !world.client_ready() {
        world.connect()?;
    }
    let brick = Brick::new(world, &qml, SIZE.0, SIZE.1)?;
    world.part::<brick::Shown>().0 = Some(brick);
    world.sync()?;
    Ok(brick)
}

fn visible(engine: &Engine, item: ObjectId) -> bool {
    engine.read_by_name(item, "visible") == Qml::Bool(true)
}

fn real(engine: &Engine, item: ObjectId, name: &str) -> f64 {
    match engine.read_by_name(item, name) {
        Qml::Real(n) => n,
        Qml::Int(n) => f64::from(n),
        _ => 0.0,
    }
}

/// The items named `name` at or under `item` that are on screen.
fn shown_items(engine: &Engine, item: ObjectId, name: &str, out: &mut Vec<ObjectId>) {
    if !visible(engine, item) {
        return;
    }
    if matches!(engine.read_by_name(item, "objectName"), Qml::String(ref s) if s.as_str() == name) {
        out.push(item);
    }
    for child in engine.children(item) {
        shown_items(engine, child, name, out);
    }
}

/// What the window's stage shows of the tab's body (PanelBodies'
/// `panelBody-<kind>`, moved into a pane's slot): on screen with a size,
/// or why not.
fn on_stage(world: &World, brick: Brick, body: &str) -> Result<(), String> {
    let Some(root) = brick.root(world) else {
        return Err("the window has no root".into());
    };
    let engine = world.engine();
    let mut stages = Vec::new();
    shown_items(engine, root, "stage", &mut stages);
    if stages.is_empty() {
        return Err("the stage is not shown".into());
    }
    let mut why = Vec::new();
    for stage in stages {
        match brick.find_under(world, stage, body) {
            Ok(Some(item)) => {
                let (w, h) = (real(engine, item, "width"), real(engine, item, "height"));
                if visible(engine, item) && w > 0.0 && h > 0.0 {
                    return Ok(());
                }
                why.push(format!(
                    "its body is there, {}, {w}x{h}",
                    if visible(engine, item) {
                        "visible"
                    } else {
                        "hidden"
                    }
                ));
            }
            Ok(None) => why.push("the stage has no such body".into()),
            Err(e) => why.push(e.0),
        }
    }
    Err(why.join("; "))
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the window is drawn by (?:the (default) shell|the ([\\w-]+) example shell)",
        |world, c, _| {
            let shell = if c[0].is_empty() { &c[1] } else { &c[0] };
            shell_window(world, shell).map(|_| ())
        },
    );
    steps.step(
        &format!("the window shows the {Q} tab in the centre"),
        |world, c, _| {
            let Some(brick) = world.part::<brick::Shown>().0 else {
                fail!("no window is drawn");
            };
            let body = format!("panelBody-{}", c[0].to_lowercase());
            let tab = c[0].clone();
            world.wait_for_with(
                |w| on_stage(w, brick, &body).is_ok(),
                |w| {
                    format!(
                        "the {tab} tab to show on the window's stage: {}",
                        on_stage(w, brick, &body).err().unwrap_or_default()
                    )
                },
            )
        },
    );
}
