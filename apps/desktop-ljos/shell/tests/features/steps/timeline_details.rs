//! What a tool call's details show and how a turn's changed files read
//! (features/timeline/tool-calls.feature): a command's exit, a search's
//! matches and results, a plan's steps, a changed file and its diff, an
//! image the agent looked at, an answered question, a long group's
//! place, and the changed-files card's counts, folders and right click.
//! The stream is stream.rs's; the rows are read from the Timeline brick
//! (a call's details) and the ThreadView brick (the changed files)
//! drawing them: desktop-qt's TimelineDetailsSteps.cpp.

use std::io::Write as _;

use ljos::item::{Modifiers, MouseButtons};
use ljos::prelude::{Engine, ObjectId, Value};
use serde_json::{Value as Json, json};

use super::stream::{
    PROJECT, THREAD, add_command, add_item, describe, look, read, role, set, settle_run, start_run,
    timeline_object,
};
use crate::brick::{self, Brick};
use crate::fake_mc::Download;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

const ROOT: &str = "/work/shop";

/// The open thread's timeline as the Timeline brick draws it; it records
/// the links and files the user activates.
fn timeline_brick(world: &mut World) -> Outcome<Brick> {
    if world.part::<brick::Shown>().0.is_none() {
        let brick = Brick::new(
            world,
            "import QtQuick\nimport HalC2.Bricks\n\
             Timeline { property string links: \"[]\"\n\
               property string files: \"[]\"\n\
               onLinkActivated: (link, external) => links = JSON.stringify(JSON.parse(links).concat([link]))\n\
               onFileActivated: (path, tab, rowId) => files = JSON.stringify(JSON.parse(files).concat([[path, tab, rowId]])) }\n",
            820.0,
            1400.0,
        )?;
        world.part::<brick::Shown>().0 = Some(brick);
        let timeline = timeline_object(world)?;
        let Some(root) = brick.root(world) else {
            fail!("the timeline brick has no root");
        };
        brick.write(world, root, "model", Value::Object(timeline))?;
    }
    brick::shown(world)
}

/// The open thread as the ThreadView brick draws it.
fn thread_brick(world: &mut World) -> Outcome<Brick> {
    if world.part::<brick::Shown>().0.is_none() {
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n",
            820.0,
            1200.0,
        )?;
    }
    brick::shown(world)
}

fn name_of(engine: &Engine, item: ObjectId) -> String {
    match engine.read_by_name(item, "objectName") {
        Value::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

fn collect(engine: &Engine, item: ObjectId, name: &str, out: &mut Vec<ObjectId>) {
    if name_of(engine, item) == name && engine.read_by_name(item, "visible") == Value::Bool(true) {
        out.push(item);
    }
    for child in engine.children(item) {
        collect(engine, child, name, out);
    }
}

fn drawn_all(world: &World, brick: Brick, name: &str) -> Vec<ObjectId> {
    let mut items = Vec::new();
    if let Some(root) = brick.root(world) {
        collect(world.engine(), root, name, &mut items);
    }
    items
}

/// The visible item named `name` drawn lowest that `matches`.
fn drawn(
    world: &mut World,
    brick: Brick,
    name: &str,
    matches: impl Fn(&World, ObjectId) -> bool,
) -> Outcome<ObjectId> {
    let mut found = None;
    world.wait_for(&format!("the timeline to draw {name}"), |w| {
        found = None;
        let mut lowest = f64::MIN;
        for item in drawn_all(w, brick, name) {
            if !matches(w, item) {
                continue;
            }
            let Ok((_, y)) = brick.at(w, item, 0.0, 0.0) else {
                continue;
            };
            if y >= lowest {
                lowest = y;
                found = Some(item);
            }
        }
        found.is_some()
    })?;
    match found {
        Some(item) => Ok(item),
        None => fail!("the timeline did not draw {name}"),
    }
}

fn click(world: &mut World, brick: Brick, item: ObjectId) -> Outcome {
    let (x, y) = brick.at(world, item, 0.3, 0.5)?;
    world.click_at(x, y)
}

fn click_with(world: &mut World, brick: Brick, item: ObjectId, button: MouseButtons) -> Outcome {
    let (x, y) = brick.at(world, item, 0.3, 0.5)?;
    world.click_at_with(x, y, button, Modifiers::empty())
}

/// The texts a visible item shows, in the order drawn.
fn texts_of(world: &World, item: ObjectId, texts: &mut Vec<String>) {
    if world.engine().read_by_name(item, "visible") != Value::Bool(true) {
        return;
    }
    if let Value::String(s) = world.engine().read_by_name(item, "text")
        && !s.as_str().is_empty()
    {
        texts.push(s.as_str().to_owned());
    }
    for child in world.engine().children(item) {
        texts_of(world, child, texts);
    }
}

/// Every text the brick shows.
fn shown(world: &World, brick: Brick) -> Vec<String> {
    let mut texts = Vec::new();
    if let Some(root) = brick.root(world) {
        texts_of(world, root, &mut texts);
    }
    texts
}

fn str_of(world: &World, item: ObjectId, name: &str) -> String {
    match world.engine().read_by_name(item, name) {
        Value::String(s) => s.as_str().to_owned(),
        _ => String::new(),
    }
}

fn real(world: &World, item: ObjectId, name: &str) -> f64 {
    match world.engine().read_by_name(item, name) {
        Value::Real(r) => r,
        Value::Int(n) => f64::from(n),
        _ => 0.0,
    }
}

fn model_data(world: &World, item: ObjectId) -> Json {
    let engine = world.engine();
    hal_c2_shell::json::from_value(engine, &engine.read_by_name(item, "modelData"))
}

/// A call line's field: its delegate's `modelData` is the calls list
/// model's entry object, whose roles read as properties.
fn call_field(world: &World, item: ObjectId, name: &str) -> String {
    let engine = world.engine();
    let data = engine.read_by_name(item, "modelData");
    let json = hal_c2_shell::json::from_value(engine, &data);
    if let Some(found) = json.get(name) {
        return text(found);
    }
    match data {
        Value::Object(entry) => match engine.read_by_name(entry, name) {
            Value::String(s) => s.as_str().to_owned(),
            _ => String::new(),
        },
        _ => String::new(),
    }
}

fn parent_of(world: &World, item: ObjectId) -> Option<ObjectId> {
    match world.engine().read_by_name(item, "parent") {
        Value::Object(parent) => Some(parent),
        _ => None,
    }
}

fn entries_of(world: &World, row: usize) -> Vec<Json> {
    role(world, row, "entries")
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn last_call(world: &World) -> Outcome<Json> {
    let rows = read(world, |t| t.row_count())?;
    for row in (0..rows).rev() {
        if text(&role(world, row, "kind")) != "work" {
            continue;
        }
        if let Some(call) = entries_of(world, row).pop() {
            return Ok(call);
        }
    }
    fail!("no call is shown; {}", describe(world))
}

fn call_count(world: &World) -> usize {
    let rows = read(world, |t| t.row_count()).unwrap_or(0);
    for row in (0..rows).rev() {
        if text(&role(world, row, "kind")) == "work" {
            return entries_of(world, row).len();
        }
    }
    0
}

/// Opens the newest call's details, as the user clicks its line; a
/// settled turn's fold is opened first.
fn open_details(world: &mut World) -> Outcome {
    let rows = read(world, |t| t.row_count())?;
    for row in (0..rows).rev() {
        if text(&role(world, row, "kind")) != "fold" {
            continue;
        }
        if role(world, row, "expanded") != json!(true) {
            let id = text(&role(world, row, "rowId"));
            let timeline = timeline_object(world)?;
            world
                .engine()
                .invoke_by_name(timeline, "toggle", &[Value::from(id.as_str())])
                .map_err(|e| crate::harness::Failure(format!("toggle: {e:?}")))?;
        }
        break;
    }
    let brick = timeline_brick(world)?;
    let id = text(&last_call(world)?["id"]);
    let line = drawn(world, brick, "workCall", |w, item| {
        parent_of(w, item).is_some_and(|parent| call_field(w, parent, "id") == id)
    })?;
    click(world, brick, line)
}

/// An image's bytes, as the MC serves a workspace file.
fn picture() -> Vec<u8> {
    let image = image::RgbImage::from_pixel(40, 20, image::Rgb([0, 139, 139]));
    let mut png = std::io::Cursor::new(Vec::new());
    let _ = image.write_to(&mut png, image::ImageFormat::Png);
    png.into_inner()
}

/// `assets.createUrl` for a thread's workspace file, and the file
/// behind it.
fn serve_workspace_files(world: &mut World) {
    let expires = (world.now() + chrono::Duration::hours(1)).timestamp_millis() as f64;
    world.mc.on_rpc("assets.createUrl", move |mc, rpc| {
        let path = text(&rpc.payload["resource"]["path"]);
        mc.reply(
            rpc,
            json!({"relativeUrl": format!("/api/assets/workspace/{path}"),
                   "expiresAt": expires}),
        );
        Ok(())
    });
    let bytes = picture();
    world
        .mc
        .on_download("/api/assets/workspace/", move |_| Download {
            status: 200,
            content_type: "image/png",
            body: bytes.clone(),
        });
}

/// The files the client asked the MC to sign.
fn signed_files(world: &World) -> Vec<Json> {
    world
        .mc
        .calls
        .iter()
        .filter(|rpc| {
            rpc.method == "assets.createUrl"
                && text(&rpc.payload["resource"]["_tag"]).ends_with("-file")
        })
        .map(|rpc| rpc.payload["resource"].clone())
        .collect()
}

/// A settled turn that changed `files` ({path, additions, deletions}),
/// as its reply lists them.
fn finish_turn_with(world: &mut World, files: Vec<Json>) -> Outcome {
    start_run(world, 60, "running")?;
    for file in &files {
        add_item(
            world,
            "file_change",
            json!({"fileName": file["path"].clone()}),
        )?;
    }
    add_item(world, "assistant_message", json!({"text": "Done."}))?;
    add_item(
        world,
        "checkpoint",
        json!({"checkpointId": "cp-1", "scopeId": "scope-1", "files": files}),
    )?;
    settle_run(world, "completed", 60)?;
    thread_brick(world)?;
    Ok(())
}

fn changed(path: &str, additions: i64, deletions: i64) -> Json {
    json!({"path": path, "kind": "modified", "additions": additions, "deletions": deletions})
}

/// The changed-files rows named `name` ("changedFolder" or
/// "changedFile"), each as the texts it shows ("src +5").
fn changed_rows(world: &World, brick: Brick, name: &str) -> Vec<String> {
    let mut rows: Vec<String> = drawn_all(world, brick, name)
        .into_iter()
        .map(|item| {
            let mut texts = Vec::new();
            texts_of(world, item, &mut texts);
            texts.join(" ")
        })
        .collect();
    rows.sort();
    rows.dedup();
    rows
}

fn changed_row(world: &mut World, name: &str, label: &str) -> Outcome<ObjectId> {
    let brick = thread_brick(world)?;
    let label = label.to_owned();
    drawn(world, brick, name, move |w, item| {
        text(&model_data(w, item)["name"]) == label
    })
}

/// The open group's window of calls.
fn calls_view(world: &mut World) -> Outcome<ObjectId> {
    let brick = timeline_brick(world)?;
    drawn(world, brick, "workCalls", |w, item| {
        w.engine().read_by_name(item, "interactive") == Value::Bool(true)
    })
}

fn end_of(world: &World, view: ObjectId) -> f64 {
    real(world, view, "contentHeight") - real(world, view, "height")
}

/// Opens the newest group's every call, as the user clicks its toggle.
fn open_group(world: &mut World, calls: usize) -> Outcome {
    let brick = timeline_brick(world)?;
    let toggle = drawn(world, brick, "workGroupToggle", |_, _| true)?;
    click(world, brick, toggle)?;
    world.wait_for_with(
        move |w| call_count(w) == calls,
        |w| format!("the group to open; {}", describe(w)),
    )
}

fn add_commands(world: &mut World, from: i64, to: i64) -> Outcome {
    for n in from..=to {
        add_command(world, n, "completed")?;
    }
    Ok(())
}

fn set_content_y(world: &mut World, view: ObjectId, y: f64) -> Outcome {
    world
        .engine()
        .write_by_name(view, "contentY", Value::from(y))
        .map_err(|e| crate::harness::Failure(format!("contentY cannot be set: {e:?}")))?;
    world.sync()
}

fn answered(world: &mut World, answer: Json) -> Outcome {
    start_run(world, 30, "running")?;
    let mut full = json!({"requestId": "request-1", "answers": {},
                          "attachmentsByQuestionId": {}});
    if let Some(extra) = answer.as_object() {
        for (k, v) in extra {
            full[k] = v.clone();
        }
    }
    add_item(
        world,
        "user_input_request",
        json!({"requestId": "request-1",
               "questions": [{"id": "q1", "question": "Which database?"}],
               "questionAnswer": full}),
    )?;
    Ok(())
}

fn register_details(steps: &mut Steps) {
    steps.step(
        "the agent ran a command that exited with code (\\d+)",
        |world, c, _| {
            start_run(world, 30, "running")?;
            let code: i64 = c[0].parse().unwrap_or(0);
            add_item(
                world,
                "command_execution",
                json!({"input": "bun lint", "output": "checked 12 files",
                       "status": if code == 0 { "completed" } else { "failed" },
                       "exitCode": code}),
            )?;
            Ok(())
        },
    );
    steps.step("the agent's command is still running", |world, _, _| {
        start_run(world, 30, "running")?;
        add_item(
            world,
            "command_execution",
            json!({"input": "bun lint", "output": "checking", "status": "running"}),
        )?;
        Ok(())
    });
    steps.step(
        "the user opens the (command|search|plan|file change|call)'s details",
        |world, _, _| open_details(world),
    );
    steps.step("the details show its input", |world, _, _| {
        let brick = timeline_brick(world)?;
        world.wait_for_with(
            move |w| brick.shows(w, "$ bun lint").unwrap_or(false),
            move |w| {
                format!(
                    "the command; the timeline shows {}",
                    shown(w, brick).join(" | ")
                )
            },
        )
    });
    steps.step(
        &format!("they say {Q} as (a success|a failure)"),
        |world, c, _| {
            let brick = timeline_brick(world)?;
            let status = drawn(world, brick, "exitStatus", |_, _| true)?;
            let colour = if c[1] == "a success" {
                "successColor"
            } else {
                "errorColor"
            };
            let said = str_of(world, status, "text");
            expect!(said == c[0], "the details say {said}");
            let Some(root) = brick.root(world) else {
                fail!("the timeline brick has no root");
            };
            let got = world.engine().read_by_name(status, "color");
            let wanted = world.engine().read_by_name(root, colour);
            expect!(got == wanted, "the exit reads in {got:?}, not {colour}");
            Ok(())
        },
    );
    steps.step("no exit code is shown", |world, _, _| {
        let call = last_call(world)?;
        let brick = timeline_brick(world)?;
        expect!(
            call.get("exitCode").is_none() && drawn_all(world, brick, "exitStatus").is_empty(),
            "the call is {}",
            show(&call)
        );
        Ok(())
    });
    steps.step(
        &format!("the agent searched the files and found {Q} in {Q} at line (\\d+) column (\\d+)"),
        |world, c, _| {
            start_run(world, 30, "running")?;
            add_item(
                world,
                "file_search",
                json!({"pattern": c[0],
                       "results": [{"fileName": format!("{ROOT}/{}", c[1]),
                                    "line": c[2].parse::<i64>().unwrap_or(0),
                                    "column": c[3].parse::<i64>().unwrap_or(0),
                                    "preview": "  return cart.total * rate;"}]}),
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the match is listed as {Q} with its preview line"),
        |world, c, _| {
            let brick = timeline_brick(world)?;
            let wanted = c[0].clone();
            world.wait_for_with(
                move |w| {
                    drawn_all(w, brick, "searchMatch").iter().any(|&found| {
                        let mut texts = Vec::new();
                        texts_of(w, found, &mut texts);
                        texts == [wanted.as_str(), "return cart.total * rate;"]
                    })
                },
                move |w| {
                    format!(
                        "the match; the timeline shows {}",
                        shown(w, brick).join(" | ")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the agent searched the web and a result has the address {Q}"),
        |world, c, _| {
            start_run(world, 30, "running")?;
            add_item(
                world,
                "web_search",
                json!({"patterns": ["vat rates"],
                       "results": [{"title": "VAT rates", "url": c[0]}]}),
            )?;
            Ok(())
        },
    );
    steps.step(
        "the result is (a link titled with the page's title|its title as plain text with no link)",
        |world, c, _| {
            let brick = timeline_brick(world)?;
            let result = drawn(world, brick, "webResult", |_, _| true)?;
            let read = str_of(world, result, "text");
            expect!(read == "VAT rates", "the result reads {read}");
            click(world, brick, result)?;
            world.sync()?;
            let Some(root) = brick.root(world) else {
                fail!("the timeline brick has no root");
            };
            let opened: Vec<Json> =
                serde_json::from_str(&str_of(world, root, "links")).unwrap_or_default();
            if c[0].starts_with("a link") {
                expect!(
                    opened == [json!("https://example.com/tax")],
                    "the result opened {} links",
                    opened.len()
                );
            } else {
                let font = world.engine().read_by_name(result, "font");
                let underlined = hal_c2_shell::json::from_value(world.engine(), &font)["underline"]
                    == json!(true);
                expect!(opened.is_empty() && !underlined, "the result is a link");
            }
            Ok(())
        },
    );
    steps.step(
        "the agent searched the web and a result has no title",
        |world, _, _| {
            start_run(world, 30, "running")?;
            add_item(
                world,
                "web_search",
                json!({"patterns": ["vat rates"],
                       "results": [{"url": "https://example.com/tax"}, {}]}),
            )?;
            Ok(())
        },
    );
    steps.step("the result shows its address", |world, _, _| {
        let brick = timeline_brick(world)?;
        world.wait_for("the two results", move |w| {
            drawn_all(w, brick, "webResult").len() == 2
        })?;
        let results = drawn_all(world, brick, "webResult");
        let mut texts = Vec::new();
        texts_of(world, results[0], &mut texts);
        expect!(
            texts == ["https://example.com/tax"],
            "the results read {}",
            shown(world, brick).join(" | ")
        );
        Ok(())
    });
    steps.step(
        &format!("a result with neither is called {Q}"),
        |world, c, _| {
            let brick = timeline_brick(world)?;
            let results = drawn_all(world, brick, "webResult");
            let Some(&last) = results.last() else {
                fail!("no web result is drawn");
            };
            let mut texts = Vec::new();
            texts_of(world, last, &mut texts);
            expect!(
                texts == [c[0].as_str()],
                "the results read {}",
                shown(world, brick).join(" | ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the agent's plan has one finished step {Q} and one open step {Q}"),
        |world, c, _| {
            start_run(world, 30, "running")?;
            add_item(
                world,
                "todo_list",
                json!({"steps": [{"text": c[0], "status": "completed"},
                                 {"text": c[1], "status": "pending"}]}),
            )?;
            Ok(())
        },
    );
    steps.step(
        "the finished step is marked done and the open step is marked not done",
        |world, _, _| {
            let brick = timeline_brick(world)?;
            world.wait_for_with(
                move |w| {
                    brick
                        .shows(w, "✓ Add the tax line\n○ Write tests")
                        .unwrap_or(false)
                },
                move |w| {
                    format!(
                        "the plan; the timeline shows {}",
                        shown(w, brick).join(" | ")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the agent changed {Q} adding (\\d+) lines and removing (\\d+)"),
        |world, c, _| {
            start_run(world, 30, "running")?;
            add_item(
                world,
                "file_change",
                json!({"fileName": c[0],
                       "additions": c[1].parse::<i64>().unwrap_or(0),
                       "deletions": c[2].parse::<i64>().unwrap_or(0)}),
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the details show {Q} with {Q} and {Q}"),
        |world, c, _| {
            let brick = timeline_brick(world)?;
            let diff = drawn(world, brick, "openCallDiff", |_, _| true)?;
            let Some(parent) = parent_of(world, diff) else {
                fail!("the diff button has no parent");
            };
            let mut texts = Vec::new();
            texts_of(world, parent, &mut texts);
            expect!(
                texts == [c[0].as_str(), c[1].as_str(), c[2].as_str(), "Open diff"],
                "the details show {}",
                texts.join(" | ")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the details offer {Q} for that file"),
        |world, c, _| {
            let brick = timeline_brick(world)?;
            let diff = drawn(world, brick, "openCallDiff", |_, _| true)?;
            let offered = str_of(world, diff, "text");
            expect!(offered == c[0], "the details offer {offered}");
            click(world, brick, diff)?;
            world.sync()?;
            let Some(root) = brick.root(world) else {
                fail!("the timeline brick has no root");
            };
            let opened: Vec<Json> =
                serde_json::from_str(&str_of(world, root, "files")).unwrap_or_default();
            expect!(
                opened.len() == 1
                    && opened[0][0] == json!("src/cart.ts")
                    && opened[0][1] == json!("diff"),
                "Open diff asked for {}",
                opened.first().map_or("nothing".into(), show)
            );
            Ok(())
        },
    );
    steps.step(&format!("the agent renamed {Q} to {Q}"), |world, c, _| {
        start_run(world, 30, "running")?;
        add_item(
            world,
            "file_change",
            json!({"fileName": format!("{ROOT}/{}", c[1]),
                       "changes": [{"operation": "rename",
                                    "path": format!("{ROOT}/{}", c[1]),
                                    "oldPath": format!("{ROOT}/{}", c[0])}]}),
        )?;
        Ok(())
    });
    steps.step(
        &format!("the details list the rename as {Q}"),
        |world, c, _| {
            let brick = timeline_brick(world)?;
            let wanted = format!("rename {}", c[0]);
            world.wait_for_with(
                {
                    let wanted = wanted.clone();
                    move |w| brick.shows(w, &wanted).unwrap_or(false)
                },
                move |w| {
                    format!(
                        "the rename; the timeline shows {}",
                        shown(w, brick).join(" | ")
                    )
                },
            )
        },
    );
    steps.step(
        &format!(
            "the provider reported the command {Q} with no output but its own text as the detail"
        ),
        |world, c, _| {
            start_run(world, 30, "running")?;
            add_item(
                world,
                "command_execution",
                json!({"input": c[0], "output": c[0], "exitCode": 0}),
            )?;
            Ok(())
        },
    );
    steps.step("the details show the command once", |world, _, _| {
        let brick = timeline_brick(world)?;
        world.wait_for("the command in the details", move |w| {
            brick.shows(w, "$ npm test").unwrap_or(false)
        })?;
        // The call's own line (a live one named by its program), and its
        // command in the details.
        let texts = shown(world, brick);
        let labelled = text(&last_call(world)?["label"]) == "npm test";
        let plain = texts.iter().filter(|t| *t == "npm test").count();
        let shelled = texts.iter().filter(|t| *t == "$ npm test").count();
        expect!(
            plain == usize::from(labelled) && shelled == 1,
            "the timeline shows {}",
            texts.join(" | ")
        );
        Ok(())
    });
    steps.step("no output is shown", |world, _, _| {
        let call = last_call(world)?;
        expect!(
            text(&call["detail"]).is_empty(),
            "the call is {}",
            show(&call)
        );
        Ok(())
    });
}

fn register_viewed(steps: &mut Steps) {
    steps.step(
        &format!("the agent viewed {Q} in the thread's workspace"),
        |world, c, _| viewed(world, &format!("{ROOT}/{}", c[0])),
    );
    steps.step(
        &format!("the agent viewed {Q} outside the workspace"),
        |world, c, _| viewed(world, &c[0]),
    );
    steps.step("the path is shown and no image is loaded", |world, _, _| {
        let path = text(&last_call(world)?["viewedPath"]);
        let brick = timeline_brick(world)?;
        let named = drawn(world, brick, "viewedImagePath", |_, _| true)?;
        world.sync()?;
        let shown_path = str_of(world, named, "text");
        expect!(
            !path.is_empty() && shown_path == path,
            "the details show {shown_path}"
        );
        expect!(
            signed_files(world).is_empty() && drawn_all(world, brick, "viewedImage").is_empty(),
            "an image was loaded"
        );
        Ok(())
    });
    steps.step(
        &format!("the agent asked a question that the user answered with {Q} and {Q}"),
        |world, c, _| answered(world, json!({"answers": {"q1": c[0], "q2": [c[1]]}})),
    );
    steps.step(
        &format!(
            "the agent asked a question that the user answered with only the files {Q} and {Q}"
        ),
        |world, c, _| {
            answered(
                world,
                json!({"attachmentsByQuestionId":
                       {"q1": [{"name": c[0]}, {"name": c[1]}]}}),
            )
        },
    );
    steps.step(
        &format!(
            "the agent asked a question that the user answered with nothing but the question {Q}"
        ),
        |world, c, _| answered(world, json!({"questionTextById": {"q1": c[0]}})),
    );
    steps.step(&format!("the call's row previews {Q}"), |world, c, _| {
        let brick = timeline_brick(world)?;
        let preview = drawn(world, brick, "workCallPreview", |_, _| true)?;
        let read = str_of(world, preview, "text");
        expect!(read == c[0], "the row previews {read}");
        Ok(())
    });
}

fn viewed(world: &mut World, path: &str) -> Outcome {
    serve_workspace_files(world);
    start_run(world, 30, "running")?;
    add_item(
        world,
        "dynamic_tool",
        json!({"toolName": "Read", "input": {"file_path": path},
               "viewedImagePath": path}),
    )?;
    Ok(())
}

/// "the image is shown" for an image a tool call viewed; the files
/// media steps own the step and ask here first. False when the brick
/// is not a timeline.
pub fn expect_viewed_image(world: &mut World) -> Outcome<bool> {
    let Ok(brick) = brick::shown(world) else {
        return Ok(false);
    };
    let Some(root) = brick.root(world) else {
        return Ok(false);
    };
    if matches!(
        world.engine().read_by_name(root, "groupAnchors"),
        Value::Undefined
    ) {
        return Ok(false);
    }
    world.wait_for_with(
        move |w| {
            let images = drawn_all(w, brick, "viewedImage");
            images.first().is_some_and(|&image| {
                matches!(
                    w.engine().read_by_name(image, "status"),
                    Value::Int(1) | Value::Real(1.0)
                ) && real(w, image, "height") > 0.0
            })
        },
        |w| {
            format!(
                "the image to load; the client signed {}",
                signed_files(w).len()
            )
        },
    )?;
    let files = signed_files(world);
    expect!(
        files.len() == 1
            && files[0]["_tag"] == json!("workspace-file")
            && files[0]["path"] == json!("assets/logo.png")
            && files[0]["threadId"] == json!(THREAD),
        "the client signed {} files",
        files.len()
    );
    Ok(true)
}

fn register_groups(steps: &mut Steps) {
    steps.step(
        "a long group of tool calls that the user scrolled partway down",
        |world, _, _| {
            start_run(world, 30, "running")?;
            add_commands(world, 1, 30)?;
            timeline_brick(world)?;
            open_group(world, 30)?;
            let view = calls_view(world)?;
            world.wait_for("the group to scroll", move |w| end_of(w, view) > 200.0)?;
            set_content_y(world, view, 150.5)
        },
    );
    steps.step(
        "the user closes the group and opens it again",
        |world, _, _| {
            let brick = timeline_brick(world)?;
            let toggle = drawn(world, brick, "workGroupToggle", |_, _| true)?;
            click(world, brick, toggle)?;
            world.wait_for("the group to close", |w| call_count(w) < 30)?;
            // A running turn's closed group folds into its live row, which
            // draws no calls of its own.
            world.wait_for("the group to stop scrolling", move |w| {
                let views = drawn_all(w, brick, "workCalls");
                views.is_empty()
                    || (views.len() == 1
                        && w.engine().read_by_name(views[0], "interactive") != Value::Bool(true))
            })?;
            open_group(world, 30)
        },
    );
    steps.step(
        "the group shows the call the user was reading at the same place",
        |world, _, _| {
            let view = calls_view(world)?;
            world.wait_for_with(
                move |w| (real(w, view, "contentY") - 150.5).abs() < 0.5,
                move |w| {
                    format!(
                        "the group to open at 150.5, not {}",
                        real(w, view, "contentY")
                    )
                },
            )
        },
    );
    steps.step(
        "the user has a long group of tool calls open and is looking at its last call",
        |world, _, _| {
            start_run(world, 30, "running")?;
            add_commands(world, 1, 30)?;
            timeline_brick(world)?;
            open_group(world, 30)?;
            let view = calls_view(world)?;
            world.wait_for("the group to scroll", move |w| end_of(w, view) > 200.0)?;
            let end = end_of(world, view);
            set_content_y(world, view, end)
        },
    );
    steps.step("the agent adds another call to the group", |world, _, _| {
        add_command(world, 31, "completed")?;
        world.wait_for("the new call", |w| call_count(w) == 31)
    });
    steps.step("the group scrolls to show the new call", |world, _, _| {
        let brick = timeline_brick(world)?;
        let view = calls_view(world)?;
        world.wait_for_with(
            move |w| {
                drawn_all(w, brick, "workCall").len() >= 31
                    && (real(w, view, "contentY") - end_of(w, view)).abs() < 1.0
            },
            move |w| {
                format!(
                    "the group at {} of {}",
                    real(w, view, "contentY"),
                    end_of(w, view)
                )
            },
        )
    });
    steps.step(
        "the user has scrolled up in the group and the agent adds another call",
        |world, _, _| {
            let view = calls_view(world)?;
            set_content_y(world, view, 100.0)?;
            add_command(world, 32, "completed")?;
            let brick = timeline_brick(world)?;
            world.wait_for("the new call", move |w| {
                call_count(w) == 32 && drawn_all(w, brick, "workCall").len() >= 32
            })
        },
    );
    steps.step("the group stays where it is", |world, _, _| {
        world.sync()?;
        let view = calls_view(world)?;
        let y = real(world, view, "contentY");
        expect!(y == 100.0, "the group moved to {y}");
        Ok(())
    });
    steps.step(
        "a call changing its status or output never moves the group",
        |world, _, _| {
            // From the end too: only a call added follows it.
            let view = calls_view(world)?;
            let end = end_of(world, view);
            set_content_y(world, view, end)?;
            let before = real(world, view, "contentY");
            let id = text(&last_call(world)?["id"]);
            set(
                world,
                "turn-item",
                &id,
                json!({"status": "failed", "output": "1 test failed"}),
            )?;
            world.wait_for("the call to change", |w| {
                last_call(w).is_ok_and(|call| call["status"] == json!("failed"))
            })?;
            world.sync()?;
            let now = real(world, view, "contentY");
            expect!(now == before, "the group moved from {before} to {now}");
            Ok(())
        },
    );
}

fn register_changed(steps: &mut Steps) {
    steps.step(
        &format!("a turn changed {Q} with (\\d+) lines added and (\\d+) removed"),
        |world, c, _| {
            finish_turn_with(
                world,
                vec![changed(
                    &c[0],
                    c[1].parse().unwrap_or(0),
                    c[2].parse().unwrap_or(0),
                )],
            )
        },
    );
    steps.step(
        &format!("a turn changed {Q} and {Q} with (\\d+) lines added in all"),
        |world, c, _| {
            let all: i64 = c[2].parse().unwrap_or(0);
            finish_turn_with(
                world,
                vec![changed(&c[0], all - all / 2, 0), changed(&c[1], all / 2, 0)],
            )
        },
    );
    steps.step(
        &format!("a turn changed {Q} and {Q} with no line counts"),
        |world, c, _| finish_turn_with(world, vec![changed(&c[0], 0, 0), changed(&c[1], 0, 0)]),
    );
    steps.step(
        &format!("a turn changed {Q} with (\\d+) lines added and {Q} with (\\d+) lines added"),
        |world, c, _| {
            finish_turn_with(
                world,
                vec![
                    changed(&c[0], c[1].parse().unwrap_or(0), 0),
                    changed(&c[2], c[3].parse().unwrap_or(0), 0),
                ],
            )
        },
    );
    steps.step(&format!("a turn changed {Q}"), |world, c, _| {
        finish_turn_with(world, vec![changed(&c[0], 2, 0)])
    });
    steps.step(
        &format!("the changed files' heading reads {Q}"),
        |world, c, _| {
            let brick = thread_brick(world)?;
            world.wait_for("the changed files", move |w| {
                !drawn_all(w, brick, "changedFilesHeading").is_empty()
            })?;
            let heading_item = drawn(world, brick, "changedFilesHeading", |_, _| true)?;
            let mut texts = Vec::new();
            texts_of(world, heading_item, &mut texts);
            let heading = texts.join(" ");
            expect!(heading == c[0], "the heading reads \"{heading}\"");
            Ok(())
        },
    );
    steps.step(
        &format!("the folder {Q} is listed with {Q}"),
        |world, c, _| {
            let brick = thread_brick(world)?;
            let wanted = vec![format!("{} {}", c[0], c[1])];
            world.wait_for_with(
                {
                    let wanted = wanted.clone();
                    move |w| changed_rows(w, brick, "changedFolder") == wanted
                },
                move |w| {
                    format!(
                        "the folder; the card lists {}",
                        changed_rows(w, brick, "changedFolder").join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        "each file is listed with its own line counts",
        |world, _, _| {
            let folder = changed_row(world, "changedFolder", "src")?;
            let brick = thread_brick(world)?;
            click(world, brick, folder)?;
            let wanted = vec!["cart.ts +3".to_owned(), "checkout.ts +2".to_owned()];
            world.wait_for_with(
                {
                    let wanted = wanted.clone();
                    move |w| changed_rows(w, brick, "changedFile") == wanted
                },
                move |w| {
                    format!(
                        "the files; the card lists {}",
                        changed_rows(w, brick, "changedFile").join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user opens the folder {Q} of the changed files"),
        |world, c, _| {
            thread_brick(world)?;
            let folder = changed_row(world, "changedFolder", &c[0])?;
            let brick = thread_brick(world)?;
            click(world, brick, folder)
        },
    );
    steps.step(
        &format!("\"([^\"]*\\.[^\"]*)\" is listed under {Q}"),
        |world, c, _| {
            let file = changed_row(world, "changedFile", &c[0])?;
            let row = model_data(world, file);
            expect!(
                row["depth"] == json!(1) && text(&row["path"]).starts_with(&format!("{}/", c[1])),
                "{} is listed as {}",
                c[0],
                show(&row)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the folder {Q} is still shown with its files hidden"),
        |world, c, _| {
            let folder = changed_row(world, "changedFolder", &c[0])?;
            let brick = thread_brick(world)?;
            let files = changed_rows(world, brick, "changedFile");
            expect!(
                model_data(world, folder)["expanded"] != json!(true) && files.len() == 1,
                "the card lists {}",
                files.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        "a turn's changed files have all their folders expanded",
        |world, _, _| {
            finish_turn_with(
                world,
                vec![
                    changed("src/cart.ts", 2, 0),
                    changed("test/cart.test.ts", 1, 0),
                ],
            )?;
            let brick = thread_brick(world)?;
            let toggle = drawn(world, brick, "changedFoldersToggle", |_, _| true)?;
            click(world, brick, toggle)?;
            world.wait_for("the folders to open", move |w| {
                drawn_all(w, brick, "changedFile").len() == 2
            })
        },
    );
    steps.step(
        "the user opens another thread and comes back",
        |world, _, _| {
            let other = "thread-2";
            let row = json!({"id": other, "title": "Checkout", "projectId": PROJECT,
                         "createdAt": "2026-09-23T09:00:00Z",
                         "updatedAt": "2026-09-23T09:00:00Z"});
            world.mc.threads.insert(other.into(), row.clone());
            world.mc.send_row(other, &row);
            world.sync()?;
            let environment = world.mc.environment_id.clone();
            look(world, &format!("{environment}:{other}"), false)?;
            let brick = thread_brick(world)?;
            world.wait_for("the other thread to show", move |w| {
                drawn_all(w, brick, "changedFolder").is_empty()
            })?;
            look(world, &format!("{environment}:{THREAD}"), false)
        },
    );
    steps.step(
        "the turn's changed files still have all their folders expanded",
        |world, _, _| {
            let brick = thread_brick(world)?;
            let wanted = vec!["cart.test.ts +1".to_owned(), "cart.ts +2".to_owned()];
            world.wait_for_with(
                {
                    let wanted = wanted.clone();
                    move |w| changed_rows(w, brick, "changedFile") == wanted
                },
                move |w| {
                    format!(
                        "the files; the card lists {}",
                        changed_rows(w, brick, "changedFile").join(", ")
                    )
                },
            )
        },
    );
    steps.step(
        "the changed files are listed without a control to expand or collapse folders",
        |world, _, _| {
            let brick = thread_brick(world)?;
            let wanted = vec!["README.md +2".to_owned(), "package.json +2".to_owned()];
            world.wait_for_with(
                {
                    let wanted = wanted.clone();
                    move |w| changed_rows(w, brick, "changedFile") == wanted
                },
                move |w| {
                    format!(
                        "the files; the card lists {}",
                        changed_rows(w, brick, "changedFile").join(", ")
                    )
                },
            )?;
            // The turn before it changed a folder; only this turn's card
            // counts.
            let heading = drawn(world, brick, "changedFilesHeading", |_, _| true)?;
            let top = brick.at(world, heading, 0.0, 0.0)?.1 - 40.0;
            for name in ["changedFoldersToggle", "changedFolder"] {
                for item in drawn_all(world, brick, name) {
                    let y = brick.at(world, item, 0.0, 0.0)?.1;
                    expect!(y < top, "the card offers to open folders");
                }
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the user right-clicks {Q} in the changed files"),
        |world, c, _| right_click(world, &c[0]),
    );
    steps.step(
        "the menu offers what the environment can do with that file",
        |world, _, _| {
            let brick = thread_brick(world)?;
            let menu = find_child(world, brick, "fileEntryMenu")?;
            world.wait_for("the file's menu", move |w| {
                w.engine().read_by_name(menu, "visible") == Value::Bool(true)
            })?;
            let path = str_of(world, menu, "path");
            expect!(path == "src/cart.ts", "the menu is for {path}");
            let count = real(world, menu, "count") as i32;
            let mut offered = Vec::new();
            for index in 0..count {
                if let Ok(Value::Object(item)) =
                    world
                        .engine()
                        .invoke_by_name(menu, "itemAt", &[Value::Int(index)])
                    && world.engine().read_by_name(item, "visible") == Value::Bool(true)
                {
                    offered.push(name_of(world.engine(), item));
                }
            }
            expect!(
                [
                    "fileEntryOpen",
                    "fileEntryCopyMention",
                    "fileEntryAddToChat"
                ]
                .iter()
                .all(|name| offered.iter().any(|o| o == name)),
                "the menu offers {}",
                offered.join(", ")
            );
            world
                .engine()
                .invoke_by_name(menu, "close", &[])
                .map_err(|e| crate::harness::Failure(format!("close: {e:?}")))?;
            world.wait_for("the menu to close", move |w| {
                w.engine().read_by_name(menu, "visible") != Value::Bool(true)
            })
        },
    );
    steps.step(
        "a file that cannot be located on the environment's machine offers nothing",
        |world, _, _| {
            // The project's folder is not on the environment's machine.
            let mut project = world.mc.projects.get(PROJECT).cloned().unwrap_or(json!({}));
            if let Some(object) = project.as_object_mut() {
                object.remove("workspaceRoot");
            }
            world.mc.projects.insert(PROJECT.into(), project.clone());
            world.mc.send_row_of(PROJECT, &project, "project");
            world.sync()?;
            let brick = thread_brick(world)?;
            let timeline = find_child(world, brick, "threadTimeline")?;
            world.wait_for("the workspace to be gone", move |w| {
                w.engine().read_by_name(timeline, "locatable") != Value::Bool(true)
            })?;
            right_click(world, "src/cart.ts")?;
            let menu = find_child(world, brick, "fileEntryMenu")?;
            expect!(
                world.engine().read_by_name(menu, "visible") != Value::Bool(true),
                "the menu opened"
            );
            Ok(())
        },
    );
}

fn find_child(world: &World, brick: Brick, name: &str) -> Outcome<ObjectId> {
    match brick.find(world, name)? {
        Some(found) => Ok(found),
        None => fail!("the brick has no {name}"),
    }
}

fn right_click(world: &mut World, path: &str) -> Outcome {
    let brick = thread_brick(world)?;
    if path.contains('/') && drawn_all(world, brick, "changedFile").is_empty() {
        let toggle = drawn(world, brick, "changedFoldersToggle", |_, _| true)?;
        click(world, brick, toggle)?;
    }
    let wanted = path.to_owned();
    let file = drawn(world, brick, "changedFile", move |w, item| {
        text(&model_data(w, item)["path"]) == wanted
    })?;
    click_with(world, brick, file, MouseButtons::RIGHT)?;
    world.sync()
}

pub fn register(steps: &mut Steps) {
    register_details(steps);
    register_viewed(steps);
    register_groups(steps);
    register_changed(steps);
}
