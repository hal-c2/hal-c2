//! The user's own shell layout (`<config>/shell.qml`) followed while the
//! desktop runs (features/desktop/user-shell.feature): saved changes keep
//! what the window holds, a change that does not load keeps the layout and
//! says why, removing the file gives the window back to the built-in layout,
//! and that layout is built with the app. How the app runs the files is
//! user_shell.rs beside world.rs.

use ljos::prelude::{ObjectId, Value};
use serde_json::json;

use crate::harness::{Outcome, Q, Steps};
use crate::user_shell::{self, App};
use crate::world::World;
use crate::{expect, fail};

/// What the scenario did to the user's layout, for the outcomes to check.
#[derive(Default)]
struct Layout {
    /// What the layout's marker says in the last version saved.
    mark: String,
    /// How many versions were saved.
    saves: usize,
    /// How far the user scrolled its list.
    scrolled: Option<f64>,
    /// The window's size when the layout was first shown.
    size: Option<(f64, f64)>,
}

/// A layout the user may write: the shell's window with a field to type
/// in and a list to scroll, and a marker that says which version it is.
fn layout(mark: &str) -> String {
    format!(
        r#"import QtQuick
import QtQuick.Controls
import HalC2.Bricks

ShellWindow {{
    firstRunGate: false

    Column {{
        anchors.fill: parent

        Text {{ objectName: "userShellMark"; text: "{mark}" }}
        TextField {{ objectName: "note"; width: 300 }}
        ListView {{
            objectName: "list"
            width: 300
            height: 200
            clip: true
            model: 100
            delegate: Text {{ height: 20; text: "row " + index }}
        }}
    }}
}}
"#
    )
}

/// A version of [`layout`] that does not compile.
const BROKEN: &str =
    "import QtQuick\nimport HalC2.Bricks\n\nShellWindow {\n    Text { text: \"the edit\"\n";

fn save(world: &mut World, mark: &str) -> Outcome {
    let text = layout(mark);
    {
        let state = world.part::<Layout>();
        state.mark = mark.to_owned();
        state.saves += 1;
    }
    user_shell::save(world, Some(&text))
}

fn next_change(world: &mut World) -> Outcome {
    let n = world.part::<Layout>().saves + 1;
    save(world, &format!("change {n}"))
}

fn named(world: &World, name: &str) -> Outcome<ObjectId> {
    let Some(window) = user_shell::window(world) else {
        fail!("the app shows no window")
    };
    match user_shell::find(world, window, name) {
        Some(item) => Ok(item),
        None => fail!("the window has no {name}"),
    }
}

fn read_text(world: &World, item: ObjectId, name: &str) -> String {
    let engine = world.engine();
    engine
        .to_js_string(&engine.read_by_name(item, name))
        .to_string()
}

fn number(world: &World, item: ObjectId, name: &str) -> f64 {
    world.engine().read_by_name(item, name).to_number()
}

fn mark_shown(world: &World) -> Option<String> {
    let window = user_shell::window(world)?;
    let mark = user_shell::find(world, window, "userShellMark")?;
    Some(read_text(world, mark, "text"))
}

fn shows_mark(world: &mut World, mark: &str) -> Outcome {
    let wanted = mark.to_owned();
    world.wait_within(
        user_shell::PATIENCE,
        |w| mark_shown(w).as_deref() == Some(wanted.as_str()),
        |w| {
            format!(
                "the window to show \"{mark}\"; it shows {:?}; {}",
                mark_shown(w),
                user_shell::describe(w)
            )
        },
    )
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the app is using the user's own shell layout",
        |world, _, _| {
            user_shell::write(world, Some(&layout("one")))?;
            world.part::<Layout>().mark = "one".into();
            user_shell::open(world, App::Running)?;
            shows_mark(world, "one")?;
            let size = user_shell::window_size(world);
            world.part::<Layout>().size = size;
            expect!(
                !user_shell::built_in(world),
                "the built-in layout is shown; {}",
                user_shell::describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the HAL-C2 home has no shell layout of the user's",
        |world, _, _| user_shell::write(world, None),
    );
    steps.step("the released app starts", |world, _, _| {
        user_shell::open(world, App::Released)
    });
    steps.step(
        &format!("the user typed {Q} in the layout's note field"),
        |world, c, _| {
            let note = named(world, "note")?;
            world
                .engine()
                .invoke_by_name(note, "forceActiveFocus", &[])
                .map_err(|e| crate::harness::Failure(format!("forceActiveFocus: {e:?}")))?;
            world.type_text(&c[0])?;
            let typed = read_text(world, note, "text");
            expect!(typed == c[0], "the note field reads \"{typed}\"");
            Ok(())
        },
    );
    // DECISION: the list is scrolled by its contentY, as a flick leaves it:
    // the wheel's distance depends on the platform's scroll speed, and the
    // scenario is about what a reload keeps, not how the list scrolls.
    steps.step("the user scrolled the layout's list down", |world, _, _| {
        let list = named(world, "list")?;
        world
            .engine()
            .write_by_name(list, "contentY", Value::Real(300.0))
            .map_err(|e| crate::harness::Failure(format!("contentY: {e:?}")))?;
        world.pump()?;
        let at = number(world, list, "contentY");
        expect!(at > 0.0, "the list did not scroll: contentY {at}");
        world.part::<Layout>().scrolled = Some(at);
        Ok(())
    });
    steps.step(
        "the user saves a change to their shell layout(?: that loads)?",
        |world, _, _| next_change(world),
    );
    steps.step(
        "the user has saved changes to it (\\d+) times",
        |world, c, _| {
            let times: usize = c[0].parse().unwrap_or(0);
            for _ in 0..times {
                next_change(world)?;
                let mark = world.part::<Layout>().mark.clone();
                shows_mark(world, &mark)?;
            }
            Ok(())
        },
    );
    steps.step(
        "the user saves a change to their shell layout that does not load",
        |world, _, _| user_shell::save(world, Some(BROKEN)),
    );
    steps.step("the user removes their shell layout", |world, _, _| {
        user_shell::mark_log(world);
        user_shell::save(world, None)
    });
    steps.step("the window shows the change", |world, _, _| {
        let mark = world.part::<Layout>().mark.clone();
        shows_mark(world, &mark)
    });
    steps.step(
        "the window still shows the user's layout as it was",
        |world, _, _| {
            let mark = world.part::<Layout>().mark.clone();
            shows_mark(world, &mark)?;
            expect!(
                !user_shell::built_in(world),
                "the built-in layout is shown; {}",
                user_shell::describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the layout's note field reads {Q}"),
        |world, c, _| {
            let note = named(world, "note")?;
            let text = read_text(world, note, "text");
            expect!(text == c[0], "the note field reads \"{text}\"");
            Ok(())
        },
    );
    steps.step("the layout's list is still scrolled down", |world, _, _| {
        let list = named(world, "list")?;
        let at = number(world, list, "contentY");
        let was = world.part::<Layout>().scrolled.unwrap_or(f64::NAN);
        expect!(
            at > 0.0 && (at - was).abs() < 0.5,
            "the list is at contentY {at}, it was at {was}"
        );
        Ok(())
    });
    steps.step("the window was not opened again", |world, _, _| {
        let windows = user_shell::windows(world);
        expect!(
            windows == 1,
            "the app shows {windows} windows; {}",
            user_shell::describe(world)
        );
        let opened = user_shell::opened(world);
        expect!(
            opened == 1,
            "the app opened a window {opened} times; {}",
            user_shell::describe(world)
        );
        let size = user_shell::window_size(world);
        let was = world.part::<Layout>().size;
        expect!(size == was, "the window is {size:?}, it was {was:?}");
        Ok(())
    });
    steps.step(
        "the shell layout's error is shown to the user",
        |world, _, _| {
            world.wait_within(
                user_shell::PATIENCE,
                |w| user_shell::error_shown(w).is_some_and(|e| !e.is_empty()),
                |w| format!("the layout's error to show; {}", user_shell::describe(w)),
            )
        },
    );
    steps.step(
        "no shell layout error is shown to the user",
        |world, _, _| {
            let shown = user_shell::error_shown(world);
            expect!(
                shown.is_none(),
                "the window shows the error {shown:?}; {}",
                user_shell::describe(world)
            );
            Ok(())
        },
    );
    steps.step("the built-in layout is used", |world, _, _| {
        world.wait_within(user_shell::PATIENCE, user_shell::built_in, |w| {
            format!("the built-in layout; {}", user_shell::describe(w))
        })
    });
    steps.step("the sidebar lists the threads of the MC", |world, _, _| {
        if world.shell_subscriptions() == 0 {
            world.connect()?;
            world.sync()?;
        }
        world.wait_for_with(
            |w| {
                let Some(window) = user_shell::window(w) else {
                    return false;
                };
                user_shell::find_prefix(w, window, "threadRow:")
                    .into_iter()
                    .any(|row| user_shell::shows_text(w, row, "One"))
            },
            |w| {
                format!(
                    "the sidebar to list the thread \"One\"; the sidebar is {}; {}",
                    crate::harness::show(&w.state("sidebar")),
                    user_shell::describe(w)
                )
            },
        )
    });
    steps.step("no script error was logged", |world, _, _| {
        world.pump()?;
        let errors = user_shell::logged_errors(world);
        expect!(
            errors.is_empty(),
            "{} script errors were logged, the first: {}",
            errors.len(),
            json!(errors.iter().take(5).collect::<Vec<_>>())
        );
        Ok(())
    });
    steps.step(
        "every file the built-in layout loads besides its QML is there",
        |world, _, _| {
            world.pump()?;
            let missing = user_shell::missing_files(world);
            expect!(
                missing.is_empty(),
                "{} files were not found, the first: {}",
                missing.len(),
                json!(missing.iter().take(5).collect::<Vec<_>>())
            );
            Ok(())
        },
    );
    steps.step("no QML was compiled while it started", |world, _, _| {
        let compiled = user_shell::compiled_at_start(world);
        expect!(
            compiled.is_empty(),
            "the app compiled QML while it started: {compiled}"
        );
        Ok(())
    });
}
