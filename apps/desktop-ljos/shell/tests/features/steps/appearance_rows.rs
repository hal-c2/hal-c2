//! The Settings → Appearance rows that change how the thread is drawn
//! (features/navigation/appearance.feature): the composer's context strip
//! after a thread starts, fonts, the Nightly marks in the sidebar, panel
//! motion, and word wrap in code, tables, diffs and file previews.
//! desktop-qt's AppearanceRowsSteps.cpp.

use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::thread_view::thread_diff::ThreadDiff;
use hal_c2_shell::thread_view::workspace_files::WorkspaceFiles;
use ljos::prelude::Value as JsValue;
use ljos::system::{HostPrefs, report_system_prefs};
use serde_json::{Value, json};

use crate::brick::{Brick, Shown, shown};
use crate::expect;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::steps::stream::{self, look_at_thread};
use crate::world::World;

const CONTEXT: &str = "persistComposerContextStrip";
const WRAP: &str = "wordWrap";

fn setting(world: &World, key: &str) -> Value {
    Settings::of(world.engine())
        .setting(world.engine(), key)
        .unwrap_or(Value::Null)
}

/// Sets a row as its control does, and waits for it to be kept.
fn set(world: &mut World, key: &str, value: Value) -> Outcome {
    let engine = world.engine().clone();
    Settings::of(&engine).set(&engine, key, value.clone());
    world.pump()?;
    let key = key.to_owned();
    let what = format!("{key} to be saved");
    world.wait_for(&what, move |w| setting(w, &key) == value)
}

fn composer(world: &World) -> Value {
    world.state("composer")
}

/// Whether the composer shows the strip, once the window is on the thread.
fn strip_shown(world: &mut World) -> Outcome<bool> {
    world.sync()?;
    let route = world.state("route");
    let composer = composer(world);
    expect!(
        at(&route, "kind") == "thread" && at(&composer, "routeKind") == "server",
        "the route is {}, the composer {}",
        show(&route),
        show(&composer["routeKind"])
    );
    Ok(composer["showContextStrip"].as_bool().unwrap_or(false))
}

/// The family (the head of Ljós's CSS-like list) and pixel size of an item's font.
fn font_of(brick: Brick, world: &World, name: &str) -> Outcome<(String, i64)> {
    let item = brick.item(world, name)?;
    Ok(match brick.read(world, item, "font") {
        JsValue::Font(f) => (
            f.family
                .split(',')
                .next()
                .unwrap_or_default()
                .trim()
                .to_owned(),
            f.pixel_size as i64,
        ),
        _ => (String::new(), 0),
    })
}

/// A number a QML property holds.
fn num(value: JsValue) -> Option<f64> {
    match value {
        JsValue::Int(n) => Some(f64::from(n)),
        JsValue::Real(r) => Some(r),
        _ => None,
    }
}

fn theme(world: &World) -> Value {
    world.state("theme")
}

fn size(world: &World, part: &str) -> i64 {
    theme(world)["fontSizes"][part].as_i64().unwrap_or(0)
}

/// The parts a row leaves alone keep the theme's fonts and their own sizes.
fn untouched(world: &World, parts: &[&str]) -> Outcome {
    let theme = theme(world);
    let ui = text(&theme["fontUi"]);
    let mono = text(&theme["fontMono"]);
    for part in parts {
        let family = |key: &str| text(&theme[key]);
        let same = match *part {
            "interface" => size(world, "interface") == 16 && ui != "Inter",
            "prompt" => {
                size(world, "prompt") == 14
                    && (family("fontPrompt").is_empty() || family("fontPrompt") == ui)
            }
            "code" => size(world, "code") == 13 && mono != "JetBrains Mono",
            _ => {
                size(world, "terminal") == 12
                    && (family("fontTerminal").is_empty() || family("fontTerminal") == mono)
            }
        };
        expect!(same, "the {part} font changed too");
    }
    Ok(())
}

/// The sidebar's brand band, shown once.
fn sidebar(world: &mut World) -> Outcome<Brick> {
    if let Some(brick) = world.part::<Shown>().0 {
        return Ok(brick);
    }
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nSidebar { showBrand: true; height: 600 }\n",
        256.0,
        600.0,
    )?;
    world.part::<Shown>().0 = Some(brick);
    Ok(brick)
}

fn marks(world: &mut World, artwork: bool, pill: bool) -> Outcome {
    let brick = sidebar(world)?;
    world.pump()?;
    let drawn_artwork = brick.flag(world, brick.item(world, "stageArtwork")?, "visible");
    let drawn_pill = brick.flag(world, brick.item(world, "stagePill")?, "visible")
        && brick.shows(world, "Nightly")?;
    expect!(
        drawn_artwork == artwork && drawn_pill == pill,
        "the sidebar draws the artwork: {drawn_artwork}, the pill: {drawn_pill}; the stage is {}",
        show(&world.state("stage"))
    );
    Ok(())
}

/// The right panel as the desktop draws it, on a thread.
fn panel_brick(world: &mut World) -> Outcome<Brick> {
    if let Some(brick) = world.part::<Shown>().0 {
        return Ok(brick);
    }
    let row = json!({"id": stream::PROJECT, "title": stream::PROJECT,
                     "workspaceRoot": "/work/shop", "scripts": []});
    world
        .mc
        .projects
        .insert(stream::PROJECT.into(), row.clone());
    world.mc.send_row_of(stream::PROJECT, &row, "project");
    world.sync()?;
    look_at_thread(world, stream::PROJECT)?;
    world.wait_for("the thread's panel", |w| {
        text(&w.state("panel")["threadKey"]).ends_with(stream::THREAD)
    })?;
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\nRightPanel { objectName: \"panel\"; ownToggle: false; height: 600 }\n",
        900.0,
        600.0,
    )?;
    world.part::<Shown>().0 = Some(brick);
    Ok(brick)
}

fn real(brick: Brick, world: &World, name: &str) -> f64 {
    let root = brick.root(world);
    root.and_then(|r| num(brick.read(world, r, name)))
        .unwrap_or(0.0)
}

fn sliding(brick: Brick, world: &World) -> Outcome<bool> {
    Ok(match brick.find(world, "panelSlide")? {
        Some(slide) => brick.flag(world, slide, "running"),
        None => false,
    })
}

fn settled(brick: Brick, world: &World) -> bool {
    real(brick, world, "shownWidth") == real(brick, world, "targetWidth")
}

pub fn register(steps: &mut Steps) {
    steps.step("the user turned on composer context", |world, _, _| {
        set(world, CONTEXT, json!(true))
    });
    steps.step("composer context is off", |world, _, _| {
        let engine = world.engine();
        expect!(
            setting(world, CONTEXT) != json!(true)
                && Settings::of(engine).is_default(engine, CONTEXT),
            "composer context is on"
        );
        Ok(())
    });
    steps.step(
        "the user sends the first message in a new thread",
        |world, _, _| {
            let row = json!({"id": "shop", "title": "shop", "workspaceRoot": "/work/shop", "scripts": []});
            world.mc.projects.insert("shop".into(), row.clone());
            if world.mc.connected() {
                world.mc.send_row_of("shop", &row, "project");
            } else {
                world.connect()?;
            }
            world.sync()?;
            if at(&world.state("route"), "kind") != "draft" {
                let key = world.project_key("shop");
                world.start_new_thread(json!({"projectKey": key}))?;
            }
            world.wait_for_with(
                |w| {
                    at(&w.state("route"), "kind") == "draft"
                        && at(&w.state("composer"), "routeKind") == "draft"
                },
                |w| {
                    format!(
                        "a new thread; the route is {}, the composer {}",
                        show(&w.state("route")),
                        show(&w.state("composer"))
                    )
                },
            )?;
            // A new thread always shows where it will run.
            let composer = composer(world);
            expect!(composer["showContextStrip"].as_bool().unwrap_or(false), "{}", show(&composer));
            world.dispatch(
                "composer.submit",
                json!({"text": "Add tax to the cart", "intent": "foreground"}),
            )?;
            world.wait_for("the thread to start", |w| at(&w.state("route"), "kind") == "thread")
        },
    );
    steps.step(
        "branch and worktree controls stay visible below the composer",
        |world, _, _| {
            let shown = strip_shown(world)?;
            expect!(shown, "{}", show(&composer(world)));
            Ok(())
        },
    );
    steps.step("branch and worktree controls are hidden", |world, _, _| {
        let shown = strip_shown(world)?;
        expect!(!shown, "{}", show(&composer(world)));
        Ok(())
    });

    // Fonts: each part of the app has its family and size.
    steps.step(
        &format!("the user sets the (interface|prompt|code|terminal) font to {Q} at (\\d+)"),
        |world, c, _| {
            let (family, size) = match c[0].as_str() {
                "interface" => ("fontFamilySans", "fontSizeInterface"),
                "prompt" => ("fontFamilyComposer", "fontSizePrompt"),
                "code" => ("fontFamilyCode", "fontSizeCode"),
                _ => ("fontFamilyTerminal", "fontSizeTerminal"),
            };
            set(world, family, json!(c[1]))?;
            set(world, size, json!(c[2].parse::<i64>().unwrap_or(0)))
        },
    );
    steps.step(
        &format!("everything outside code and the terminal uses {Q} at (\\d+)"),
        |world, c, _| {
            let family = c[0].clone();
            let points: i64 = c[1].parse().unwrap_or(0);
            let wanted = family.clone();
            world.wait_for("the interface font", move |w| text(&theme(w)["fontUi"]) == wanted)?;
            expect!(
                size(world, "interface") == points,
                "the interface is scaled to {}",
                size(world, "interface")
            );
            // A control and a message's prose, as the bricks draw them: their
            // own size, scaled. And a label that names no font.
            let brick = Brick::new(
                world,
                "import QtQuick\nimport HalC2.Bricks\nItem { ShellTextField { objectName: \"field\" }\n\
                 Markdown { objectName: \"message\"; y: 60; width: 400; text: \"Hello\" }\n\
                 Text { objectName: \"label\"; y: 120; text: \"Threads\" } }\n",
                400.0,
                200.0,
            )?;
            world.part::<Shown>().0 = Some(brick);
            let label = font_of(brick, world, "label")?;
            expect!(label.0 == family, "a label writes in {}", label.0);
            let scaled = |base: f64| (base * points as f64 / 16.0).round() as i64;
            let field = font_of(brick, world, "field")?;
            expect!(
                field.0 == family && field.1 == scaled(13.0),
                "a field writes in {} at {}",
                field.0,
                field.1
            );
            world.wait_for("the message to be drawn", move |w| {
                brick
                    .find(w, "message")
                    .ok()
                    .flatten()
                    .is_some_and(|m| num(brick.read(w, m, "segmentCount")).unwrap_or(0.0) >= 1.0)
            })?;
            let prose = font_of(brick, world, "markdownProse")?;
            expect!(
                prose.0 == family && prose.1 == scaled(14.0),
                "prose is in {} at {}",
                prose.0,
                prose.1
            );
            untouched(world, &["code", "terminal"])
        },
    );
    // The interface font is the application's, so text drawn before it
    // changed is rewritten.
    steps.step("a label that names no font is on screen", |world, _, _| {
        let brick = Brick::new(
            world,
            "import QtQuick\nItem { Text { objectName: \"label\"; text: \"Threads\" } }\n",
            200.0,
            60.0,
        )?;
        world.part::<Shown>().0 = Some(brick);
        Ok(())
    });
    steps.step(&format!("the label is written in {Q}"), |world, c, _| {
        let brick = shown(world)?;
        let wanted = c[0].clone();
        world.wait_for_with(
            move |w| font_of(brick, w, "label").is_ok_and(|f| f.0 == wanted),
            move |w| {
                format!(
                    "the label's font; it is {}",
                    font_of(brick, w, "label").unwrap_or_default().0
                )
            },
        )
    });
    steps.step(
        &format!("the composer uses {Q} at (\\d+)"),
        |world, c, _| {
            let family = c[0].clone();
            let points: i64 = c[1].parse().unwrap_or(0);
            let wanted = family.clone();
            world.wait_for("the prompt font", move |w| {
                text(&theme(w)["fontPrompt"]) == wanted && size(w, "prompt") == points
            })?;
            let brick = Brick::new(
                world,
                "import QtQuick\nimport HalC2.Bricks\nComposer { width: 700 }\n",
                700.0,
                400.0,
            )?;
            world.part::<Shown>().0 = Some(brick);
            let input = font_of(brick, world, "input")?;
            expect!(
                input.0 == family && input.1 == points,
                "the prompt is in {} at {}",
                input.0,
                input.1
            );
            untouched(world, &["interface", "code", "terminal"])
        },
    );
    steps.step(&format!("code blocks and diffs uses {Q} at (\\d+)"), |world, c, _| {
        let family = c[0].clone();
        let points: i64 = c[1].parse().unwrap_or(0);
        // Diffs and file previews draw in Theme.fontMono at Theme.fontSizeCode.
        let wanted = family.clone();
        world.wait_for("the code font", move |w| {
            text(&theme(w)["fontMono"]) == wanted && size(w, "code") == points
        })?;
        let brick = Brick::new(
            world,
            "import QtQuick\nimport HalC2.Bricks\nMarkdown { width: 560; text: \"```\\nconst total = 1;\\n```\\n\" }\n",
            560.0,
            300.0,
        )?;
        world.part::<Shown>().0 = Some(brick);
        world.wait_for("the code block to be drawn", move |w| real(brick, w, "segmentCount") >= 1.0)?;
        let code = font_of(brick, world, "codeText")?;
        expect!(
            code.0 == family && code.1 == points,
            "code is in {} at {}",
            code.0,
            code.1
        );
        untouched(world, &["interface", "prompt"])?;
        // The terminal follows the code font until it has its own.
        let terminal = text(&theme(world)["fontTerminal"]);
        expect!(
            terminal.is_empty() || terminal == family,
            "the terminal is in {terminal}"
        );
        Ok(())
    });
    steps.step(
        &format!("the terminal uses {Q} at (\\d+)"),
        |world, c, _| {
            // The terminals draw in Theme.fontTerminal at Theme.fontSizeTerminal.
            let family = c[0].clone();
            let points: i64 = c[1].parse().unwrap_or(0);
            world.wait_for_with(
                move |w| text(&theme(w)["fontTerminal"]) == family && size(w, "terminal") == points,
                |w| {
                    format!(
                        "the terminal font; it is {} at {}",
                        text(&theme(w)["fontTerminal"]),
                        size(w, "terminal")
                    )
                },
            )?;
            untouched(world, &["interface", "prompt", "code"])
        },
    );

    // Environment identification: how a Nightly MC marks the sidebar's brand band.
    steps.step(
        &format!("the user sets environment identification to {Q}"),
        |world, c, _| {
            let mode = match c[0].as_str() {
                "Artwork" => "artwork",
                "Version pill" => "pill",
                "None" => "none",
                other => crate::fail!("there is no \"{other}\" mode"),
            };
            set(world, "environmentIdentificationMode", json!(mode))
        },
    );
    steps.step("the environment is a Nightly build", |world, _, _| {
        // A release marks nothing, whatever the mode.
        let stage = world.state("stage");
        expect!(text(&stage["label"]).is_empty(), "{}", show(&stage));
        let id = world.mc.subscribers("shell").first().copied().unwrap_or(-1);
        let frame = json!({"t": "shell.environment", "id": id, "mc": world.mc.name,
            "environment": {"environmentId": world.mc.environment_id,
                            "serverVersion": "0.9.0-nightly.20260923.412",
                            "capabilities": world.mc.capabilities}});
        world.mc.send(&frame);
        world.sync()?;
        world.wait_for_with(
            |w| w.state("stage")["label"] == "Nightly",
            |w| format!("the Nightly stage; it is {}", show(&w.state("stage"))),
        )
    });
    steps.step("the app shows the Nightly artwork", |world, _, _| {
        marks(world, true, false)
    });
    steps.step("the app shows a Nightly version pill", |world, _, _| {
        marks(world, false, true)
    });
    steps.step("the app shows no environment marker", |world, _, _| {
        marks(world, false, false)
    });

    // Motion: the right panel as the desktop draws it, on a thread.
    steps.step(
        "(?:the user sets panel animations to|panel animations are set to) (\\d+) ms",
        |world, c, _| {
            set(
                world,
                "panelAnimationDurationMs",
                json!(c[0].parse::<i64>().unwrap_or(0)),
            )?;
            panel_brick(world).map(drop)
        },
    );
    steps.step(
        "the operating system asks for reduced motion",
        |world, _, _| {
            report_system_prefs(
                world.engine(),
                HostPrefs {
                    reduced_motion: Some(true),
                    ..HostPrefs::default()
                },
            );
            world.pump()
        },
    );
    steps.step(
        "the right panel slides open over (\\d+) ms",
        |world, c, _| {
            let ms: i64 = c[0].parse().unwrap_or(0);
            let brick = panel_brick(world)?;
            let panel = world.state("panel");
            expect!(
                panel["isOpen"].as_bool().unwrap_or(false)
                    && panel["transitionMs"].as_i64() == Some(ms),
                "{}",
                show(&panel)
            );
            // The brick slides to its open width in that time, then stops.
            let Some(slide) = brick.find(world, "panelSlide")? else {
                crate::fail!("the panel has no slide");
            };
            let duration = num(brick.read(world, slide, "duration")).unwrap_or(-1.0);
            expect!(
                duration == ms as f64
                    && num(brick.read(world, slide, "to"))
                        == Some(real(brick, world, "targetWidth"))
                    && num(brick.read(world, slide, "from")) == Some(0.0),
                "the panel's slide is {duration} ms from {:?} to {:?} (target {})",
                brick.read(world, slide, "from"),
                brick.read(world, slide, "to"),
                real(brick, world, "targetWidth")
            );
            world.wait_for("the panel to finish opening", move |w| {
                settled(brick, w) && !brick.flag(w, slide, "running")
            })?;
            expect!(
                real(brick, world, "shownWidth") > 0.0,
                "the panel is closed"
            );
            Ok(())
        },
    );
    steps.step("the right panel opens immediately", |world, _, _| {
        let brick = panel_brick(world)?;
        let panel = world.state("panel");
        expect!(
            panel["isOpen"].as_bool().unwrap_or(false) && panel["transitionMs"].as_i64() == Some(0),
            "{}",
            show(&panel)
        );
        expect!(
            settled(brick, world)
                && real(brick, world, "shownWidth") > 0.0
                && !sliding(brick, world)?,
            "the panel is still sliding"
        );
        Ok(())
    });
    steps.step(
        "the user switches to a thread with a different panel layout",
        |world, _, _| {
            let brick = panel_brick(world)?;
            // This thread's panel is open (and slid open); another's is closed.
            world.dispatch("rightPanel.toggle", json!({}))?;
            world.wait_for("the panel to open", move |w| {
                w.state("panel")["isOpen"].as_bool().unwrap_or(false)
                    && settled(brick, w)
                    && !sliding(brick, w).unwrap_or(true)
            })?;
            let row = json!({"id": "thread-2", "title": "Other", "projectId": stream::PROJECT,
                             "createdAt": "2026-09-23T08:00:00Z", "updatedAt": "2026-09-23T08:00:00Z"});
            world.mc.threads.insert("thread-2".into(), row.clone());
            world.mc.send_row("thread-2", &row);
            world.sync()?;
            let key = format!("{}:thread-2", world.mc.environment_id);
            world.dispatch("thread.open", json!({"key": key}))?;
            world.wait_for_with(
                |w| text(&w.state("panel")["threadKey"]).ends_with("thread-2"),
                |w| format!("the other thread's panel; it is {}", show(&w.state("panel"))),
            )
        },
    );
    steps.step("the panels snap to that thread's layout", |world, _, _| {
        let brick = panel_brick(world)?;
        let panel = world.state("panel");
        expect!(
            !panel["isOpen"].as_bool().unwrap_or(true) && panel["transitionMs"].as_i64() == Some(0),
            "{}",
            show(&panel)
        );
        expect!(
            settled(brick, world)
                && real(brick, world, "shownWidth") == 0.0
                && !sliding(brick, world)?,
            "the panel is sliding shut ({} wide)",
            real(brick, world, "shownWidth")
        );
        // And back: the first thread's open panel is there at once too.
        let key = format!("{}:{}", world.mc.environment_id, stream::THREAD);
        world.dispatch("thread.open", json!({"key": key}))?;
        world.wait_for("the first thread's panel", |w| {
            text(&w.state("panel")["threadKey"]).ends_with(stream::THREAD)
        })?;
        let panel = world.state("panel");
        expect!(
            panel["isOpen"].as_bool().unwrap_or(false)
                && panel["transitionMs"].as_i64() == Some(0)
                && settled(brick, world)
                && real(brick, world, "shownWidth") > 0.0
                && !sliding(brick, world)?,
            "coming back slid the panel open: {}",
            show(&panel)
        );
        Ok(())
    });

    steps.step("the user turns on word wrap", |world, _, _| {
        set(world, WRAP, json!(false))?;
        expect!(
            wraps(world) == (false, false),
            "diffs or file previews wrap with word wrap off"
        );
        set(world, WRAP, json!(true))
    });
    steps.step(
        "long lines in code blocks, tables, diffs and file previews wrap instead of scrolling",
        |world, _, _| {
            let (diff, files) = wraps(world);
            expect!(
                diff && files,
                "diffs wrap: {diff}, file previews wrap: {files}"
            );
            // Code blocks and tables, as the timeline draws a message.
            let qml = "import QtQuick\nimport HalC2.Bricks\n\
                Markdown { width: 560; text: \"```\\nconst total = price + tax;\\n```\\n\\n| a | b |\\n| - | - |\\n| 1 | 2 |\\n\" }\n";
            let message = Brick::new(world, qml, 560.0, 400.0)?;
            world.part::<Shown>().0 = Some(message);
            world.wait_for("the message to be drawn", move |w| real(message, w, "segmentCount") >= 2.0)?;
            let code = message.item(world, "markdownCode")?;
            let table = message.item(world, "markdownTable")?;
            expect!(
                message.flag(world, code, "wrapped") && message.flag(world, table, "expanded"),
                "the code block or the table does not wrap"
            );
            // And none of them with it off.
            set(world, WRAP, json!(false))?;
            let unwrapped = Brick::new(world, qml, 560.0, 400.0)?;
            world.part::<Shown>().0 = Some(unwrapped);
            world.wait_for("the message to be drawn", move |w| real(unwrapped, w, "segmentCount") >= 2.0)?;
            let code = unwrapped.item(world, "markdownCode")?;
            let table = unwrapped.item(world, "markdownTable")?;
            expect!(
                !unwrapped.flag(world, code, "wrapped")
                    && !unwrapped.flag(world, table, "expanded")
                    && wraps(world) == (false, false),
                "something still wraps with word wrap off"
            );
            Ok(())
        },
    );
}

/// Whether the panel's diff and its file previews wrap their lines.
fn wraps(world: &World) -> (bool, bool) {
    let (diff, files) = world
        .with::<RightPanel, _>(|panel, _| (panel.diff(), panel.files()))
        .unwrap_or_default();
    let engine = world.engine();
    (
        diff.and_then(|d| ThreadDiff::read(engine, d, |t| t.wrap()))
            .unwrap_or(false),
        files
            .and_then(|f| WorkspaceFiles::read(engine, f, |f| f.wrap()))
            .unwrap_or(false),
    )
}
