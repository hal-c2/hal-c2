//! Viewing attachments (features/files/file-viewer-and-editing.feature,
//! desktop-qt's AttachmentViewerSteps.cpp): a message's images large over
//! the ThreadView brick, a sent file fetched into the AttachmentViewer
//! brick, and a draft's attachment opened from its chip.

use std::collections::{HashMap, HashSet};
use std::io::Write as _;
use std::path::PathBuf;

use base64::Engine as _;
use hal_c2_shell::controllers::attachment_viewer::AttachmentViewer;
use ljos::item::{MouseButtons, PointerEvent};
use ljos::prelude::{ObjectId, Value};
use serde_json::json;

use super::fake_files::media_fixture;
use super::stream::{PROJECT, look_at_thread, set, start_run};
use crate::brick::{Brick, shown as brick_shown};
use crate::harness::{self, Outcome, Q, Steps, at, show};
use crate::world::World;
use crate::{expect, fail};

/// `key`'s text in a JSON object.
fn text(value: &serde_json::Value, key: &str) -> String {
    harness::text(&value[key])
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// What the MC serves as attachments: bytes by id, the ids it no longer
/// has, the signatures it made, and whether it is cut off.
#[derive(Default)]
struct FakeAttachments {
    bytes: HashMap<String, Vec<u8>>,
    gone: HashSet<String>,
    unsigned: HashSet<String>,
    broken: HashSet<String>,
    unreachable: bool,
    signatures: usize,
    saves: Option<tempfile::TempDir>,
}

/// The sent attachment a scenario talks about before it is opened.
#[derive(Default)]
struct FakeSent {
    name: String,
}

/// A 200x100 picture, as bytes.
fn picture() -> Vec<u8> {
    use image::ImageEncoder as _;
    let image = image::RgbImage::from_pixel(200, 100, image::Rgb([0, 139, 139]));
    let mut png = std::io::Cursor::new(Vec::new());
    let _ = image::codecs::png::PngEncoder::new(&mut png).write_image(
        image.as_raw(),
        200,
        100,
        image::ExtendedColorType::Rgb8,
    );
    png.into_inner()
}

fn serve(world: &mut World) {
    world.mc.on_rpc("assets.createUrl", |mc, rpc| {
        let id = harness::text(&rpc.payload["resource"]["attachmentId"]);
        if id.is_empty() {
            // Not an attachment: another domain's signing answers it in
            // its own scenarios; here it is refused as the MC would.
            mc.refuse(rpc, "No such attachment.");
            return Ok(());
        }
        let fake = mc.part::<FakeAttachments>();
        // McClient's own word for a call with no connection to carry it.
        if fake.unreachable {
            mc.refuse(rpc, "not connected");
            return Ok(());
        }
        if fake.unsigned.contains(&id) {
            mc.refuse(rpc, "No such attachment.");
            return Ok(());
        }
        fake.signatures += 1;
        let signatures = fake.signatures;
        mc.reply(
            rpc,
            json!({
                "relativeUrl": format!("/api/assets/attachment/{id}/{signatures}"),
                "expiresAt": (now_ms() + 3_600_000) as f64,
            }),
        );
        Ok(())
    });
    world
        .mc
        .on_raw("/api/assets/attachment/", |mc, mut stream, head| {
            let path = head
                .lines()
                .next()
                .and_then(|line| line.split(' ').nth(1))
                .unwrap_or("");
            let id = path.split('/').nth(4).unwrap_or("").to_owned();
            let fake = mc.part::<FakeAttachments>();
            if fake.gone.contains(&id) || fake.broken.contains(&id) || !fake.bytes.contains_key(&id)
            {
                let _ = stream.write_all(
                    b"HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
                );
            } else {
                let body = fake.bytes[&id].clone();
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(&body);
            }
            let _ = stream.flush();
            // Closing with the request unread resets the connection, which
            // cuts off a large body still on its way: end the reply and read
            // until the client hangs up.
            let _ = stream.shutdown(std::net::Shutdown::Write);
            let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(5)));
            let _ = std::io::copy(&mut stream, &mut std::io::sink());
            Ok(())
        });
}

fn conversation(world: &mut World) -> Outcome<Brick> {
    if world
        .peek_part::<crate::brick::Shown>()
        .and_then(|s| s.0)
        .is_none()
    {
        Brick::show(
            world,
            "import QtQuick\nimport HalC2.Bricks\nItem { ThreadView { anchors.fill: parent }\n AttachmentViewer {} }\n",
            1000.0,
            800.0,
        )?;
    }
    brick_shown(world)
}

/// A message carrying `count` images (and what `first` adds to the first),
/// on show in the conversation.
fn message_with_images(world: &mut World, count: usize, first: serde_json::Value) -> Outcome {
    serve(world);
    look_at_thread(world, PROJECT)?;
    let run = start_run(world, 0, "running")?;
    let mut images = Vec::new();
    for n in 1..=count {
        world
            .mc
            .part::<FakeAttachments>()
            .bytes
            .insert(format!("image-{n}"), picture());
        let mut image = json!({
            "type": "image", "id": format!("image-{n}"),
            "name": format!("shot-{n}.png"), "mimeType": "image/png",
            "sizeBytes": 2048,
        });
        if n == 1
            && let (serde_json::Value::Object(extra), serde_json::Value::Object(map)) =
                (&first, &mut image)
        {
            for (key, value) in extra {
                map.insert(key.clone(), value.clone());
            }
        }
        images.push(image);
    }
    set(
        world,
        "turn-item",
        &format!("message:{run}"),
        json!({"attachments": images}),
    )?;
    conversation(world)?;
    world.sync()
}

fn viewer(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    let brick = conversation(world)?;
    let item = brick.item(world, "imageViewer")?;
    Ok((brick, item))
}

fn of(world: &World, brick: Brick, item: ObjectId, name: &str) -> Value {
    brick.read(world, item, name)
}

fn number(world: &World, brick: Brick, item: ObjectId, name: &str) -> f64 {
    match brick.read(world, item, name) {
        Value::Int(n) => n as f64,
        Value::Real(r) => r,
        _ => brick.text_of(world, item, name).parse().unwrap_or(0.0),
    }
}

fn picture_item(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    let brick = conversation(world)?;
    let item = brick.item(world, "imageViewerPicture")?;
    Ok((brick, item))
}

/// Opens image `n`, and waits for its picture (unless it is not to load).
fn open_image(world: &mut World, n: usize, loads: bool) -> Outcome {
    let brick = conversation(world)?;
    let name = format!("attachmentOpenLarge-image-{n}");
    world.wait_for_with(
        |w| matches!(brick.find(w, &name), Ok(Some(_))),
        |_| "the image in the conversation".to_owned(),
    )?;
    // A picture widens its square as it loads, moving its neighbours.
    if loads {
        world.wait_for_with(
            |w| {
                let mut other = 1;
                loop {
                    match brick.find(w, &format!("attachment-image-{other}")) {
                        Ok(Some(square)) => {
                            if !brick.flag(w, square, "pictured") {
                                return false;
                            }
                            other += 1;
                        }
                        _ => return true,
                    }
                }
            },
            |_| "the pictures in the conversation".to_owned(),
        )?;
    }
    brick.click(world, &name)?;
    let (_, item) = viewer(world)?;
    world.wait_for_with(
        |w| brick.flag(w, item, "visible"),
        |_| "the image viewer to open".to_owned(),
    )?;
    if loads {
        let (_, picture) = picture_item(world)?;
        world.wait_for_with(
            |w| {
                number(w, brick, picture, "status") == 1.0
                    && number(w, brick, picture, "width") > 0.0
            },
            |w| {
                format!(
                    "the picture to load; its status is {}",
                    number(w, brick, picture, "status")
                )
            },
        )?;
    }
    Ok(())
}

fn expect_zoom(world: &mut World, wanted: f64) -> Outcome {
    let (brick, item) = viewer(world)?;
    let zoom = number(world, brick, item, "zoom");
    expect!(
        (zoom - wanted).abs() < 0.001,
        "the image is at {zoom} times its fitted size, not {wanted}"
    );
    let (_, picture) = picture_item(world)?;
    let drawn = number(world, brick, picture, "width") / 200.0;
    expect!(
        (drawn - wanted).abs() < 0.001,
        "the picture is drawn at {drawn} times, not {wanted}"
    );
    Ok(())
}

fn expect_showing(world: &mut World, n: usize) -> Outcome {
    let (brick, item) = viewer(world)?;
    world.wait_for_with(
        |w| number(w, brick, item, "index") as usize + 1 == n,
        |w| {
            format!(
                "image {n}; the viewer shows image {}",
                number(w, brick, item, "index") as usize + 1
            )
        },
    )?;
    let name_item = brick.item(world, "imageViewerName")?;
    let name = brick.text_of(world, name_item, "text");
    expect!(
        name.starts_with(&format!("shot-{n}.png")),
        "the viewer is named {name}"
    );
    Ok(())
}

fn picture_at(world: &mut World, fx: f64, fy: f64) -> Outcome<(f64, f64)> {
    let (brick, picture) = picture_item(world)?;
    brick.at(world, picture, fx, fy)
}

fn click_picture(world: &mut World) -> Outcome {
    let (x, y) = picture_at(world, 0.5, 0.5)?;
    world.click_at(x, y)?;
    world.sync()
}

fn wheel(world: &mut World, x: f64, y: f64, delta: f64) -> Outcome {
    world.wheel(x, y, delta / 120.0)?;
    world.sync()
}

fn wheel_ctrl(world: &mut World, x: f64, y: f64) -> Outcome {
    // A pinch reads as the wheel with Control held.
    let taken = world.wheel_with(x, y, 1.0, ljos::item::Modifiers::CONTROL)?;
    let _ = taken;
    world.sync()
}

fn key(world: &mut World, name: &str) -> Outcome {
    let brick = conversation(world)?;
    brick.press(world, name)?;
    world.sync()
}

fn viewed(world: &World) -> serde_json::Value {
    world.state("attachmentViewer")
}

fn saves(world: &mut World) -> PathBuf {
    if world.mc.part::<FakeAttachments>().saves.is_none() {
        world.mc.part::<FakeAttachments>().saves = tempfile::TempDir::new().ok();
        let folder = world
            .mc
            .part::<FakeAttachments>()
            .saves
            .as_ref()
            .map(|dir| dir.path().to_path_buf());
        let _ = world.with::<AttachmentViewer, _>(|viewer, _| {
            viewer.set_save_folder(folder.clone());
        });
    }
    world
        .mc
        .part::<FakeAttachments>()
        .saves
        .as_ref()
        .map(|dir| dir.path().to_path_buf())
        .unwrap_or_default()
}

/// A draft's attachment opened from its chip in the composer.
fn open_draft(world: &mut World, mut file: serde_json::Value) -> Outcome {
    // A file comes from where it was picked; only an image is taken as bytes.
    let mime = text(&file, "mimeType").to_owned();
    if !mime.starts_with("image/") {
        let folder = saves(world);
        let path = folder.join(text(&file, "name"));
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(text(&file, "base64"))
            .unwrap_or_default();
        std::fs::write(&path, &bytes).map_err(|e| crate::harness::Failure(e.to_string()))?;
        if let serde_json::Value::Object(map) = &mut file {
            map.remove("base64");
        }
        file["path"] = json!(path.to_string_lossy());
        serve(world);
        world.mc.on_rpc("attachments.createUploadUrl", |mc, rpc| {
            mc.reply(
                rpc,
                json!({"attachmentId": "up-1", "relativeUrl": "/api/assets/attachment/up-1/0"}),
            );
            Ok(())
        });
    }
    world.dispatch("composer.attach", json!({"files": [file.clone()]}))?;
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Bricks\nItem {\n  Composer { width: parent.width; anchors.bottom: parent.bottom }\n  AttachmentViewer {}\n}\n",
        900.0,
        700.0,
    )?;
    world.sync()?;
    let name = text(&file, "name").to_owned();
    brick_shown(world)?.click(world, &format!("attachmentOpen:{name}"))?;
    world.wait_for_with(
        |w| text(&viewed(w), "name") == name,
        |_| "the attachment to open".to_owned(),
    )
}

/// A sent message's file, opened from the conversation.
fn open_sent(
    world: &mut World,
    name: &str,
    mime_type: &str,
    bytes: Vec<u8>,
    wait: bool,
) -> Outcome {
    serve(world);
    saves(world);
    world
        .mc
        .part::<FakeAttachments>()
        .bytes
        .insert("file-1".to_owned(), bytes.clone());
    look_at_thread(world, PROJECT)?;
    let run = start_run(world, 0, "running")?;
    let file = json!({
        "type": "file", "id": "file-1", "name": name,
        "mimeType": mime_type, "sizeBytes": bytes.len(),
    });
    set(
        world,
        "turn-item",
        &format!("message:{run}"),
        json!({"attachments": [file]}),
    )?;
    let brick = conversation(world)?;
    world.wait_for_with(
        |w| matches!(brick.find(w, "sentFileOpen-file-1"), Ok(Some(_))),
        |_| "the file in the conversation".to_owned(),
    )?;
    brick.click(world, "sentFileOpen-file-1")?;
    if wait {
        world.wait_for_with(
            |w| {
                let kind = text(&viewed(w), "kind");
                !kind.is_empty() && kind != "loading"
            },
            |_| "the attachment to load".to_owned(),
        )?;
    }
    Ok(())
}

fn expect_toast(world: &mut World, kind: &str, title: &str) -> Outcome {
    world.wait_for_with(
        |w| {
            w.state("toasts")
                .get("items")
                .and_then(serde_json::Value::as_array)
                .is_some_and(|toasts| {
                    toasts.iter().any(|toast| {
                        text(toast, "type") == kind && text(toast, "title").starts_with(title)
                    })
                })
        },
        |w| {
            format!(
                "a {kind} toast \"{title}\"; toasts are {}",
                show(&w.state("toasts"))
            )
        },
    )
}

const PAGE: &[u8] = b"<html><body><h1>Report</h1></body></html>";

/// The viewer's video, once it plays.
fn playing_video(world: &mut World) -> Outcome<(Brick, ObjectId)> {
    let brick = conversation(world)?;
    world.wait_for_with(
        |w| {
            matches!(brick.find(w, "mediaPlayerView"), Ok(Some(player))
                if brick.flag(w, player, "playing"))
        },
        |w| format!("the video to play; {}", show(&viewed(w))),
    )?;
    let player = brick.item(world, "mediaPlayerView")?;
    Ok((brick, player))
}

/// The attachment's text and its highlighter, once it has read the text.
fn attachment_text(world: &mut World) -> Outcome<(ObjectId, ObjectId)> {
    let brick = brick_shown(world)?;
    let found = |w: &World| -> Option<(ObjectId, ObjectId)> {
        let text = brick.find(w, "attachmentViewerText").ok().flatten()?;
        let highlighter = brick
            .find_in(w, text, "attachmentViewerHighlighter")
            .ok()
            .flatten()?;
        (!flag(w, highlighter, "reading")).then_some((text, highlighter))
    };
    world.wait_for("the attachment's text", move |w| found(w).is_some())?;
    match found(world) {
        Some(pair) => Ok(pair),
        None => fail!("the attachment's text is gone"),
    }
}

fn flag(world: &World, item: ObjectId, name: &str) -> bool {
    matches!(world.engine().read_by_name(item, name), Value::Bool(true))
}

fn coloured_runs(world: &World, text: ObjectId) -> usize {
    ljos::item::highlights(world.engine(), text).map_or(0, |spans| {
        spans.iter().filter(|span| span.color.is_some()).count()
    })
}

pub fn register(steps: &mut Steps) {
    // --- Stepping through a message's images.
    steps.step(
        "a message carries (one image|three images)(?: and the user opened the (second|third))?",
        |world, c, _| {
            message_with_images(world, if c[0] == "one image" { 1 } else { 3 }, json!(null))?;
            if !c[1].is_empty() {
                open_image(world, if c[1] == "second" { 2 } else { 3 }, true)?;
            }
            Ok(())
        },
    );
    steps.step(
        "a message carries three images and the user zoomed the second",
        |world, _, _| {
            message_with_images(world, 3, json!(null))?;
            open_image(world, 2, true)?;
            click_picture(world)?;
            expect_zoom(world, 2.0)
        },
    );
    steps.step("the user opens the second image", |world, _, _| {
        open_image(world, 2, true)
    });
    steps.step("the user opens it", |world, _, _| {
        open_image(world, 1, true)
    });
    steps.step("it is shown large", |world, _, _| {
        let (brick, picture) = picture_item(world)?;
        let stage = brick.item(world, "imageViewerStage")?;
        expect!(
            brick.flag(world, picture, "visible") && number(world, brick, stage, "width") > 800.0,
            "the picture is not on a window-sized stage"
        );
        expect_showing(world, 2)
    });
    steps.step(
        "the user can step to the previous and next image",
        |world, _, _| {
            let brick = conversation(world)?;
            brick.click(world, "imageViewerPrevious")?;
            expect_showing(world, 1)?;
            brick.click(world, "imageViewerNext")?;
            expect_showing(world, 2)
        },
    );
    steps.step(&format!("its name is shown with {Q}"), |world, c, _| {
        let brick = conversation(world)?;
        let item = brick.item(world, "imageViewerName")?;
        let name = brick.text_of(world, item, "text");
        expect!(name.ends_with(&c[0]), "the viewer is named {name}");
        Ok(())
    });
    steps.step(
        "the user steps to the (next|previous) image",
        |world, c, _| {
            let brick = conversation(world)?;
            brick.click(
                world,
                if c[0] == "next" {
                    "imageViewerNext"
                } else {
                    "imageViewerPrevious"
                },
            )
        },
    );
    steps.step("the (first|third) image is shown", |world, c, _| {
        expect_showing(world, if c[0] == "first" { 1 } else { 3 })
    });
    steps.step("no previous or next image is offered", |world, _, _| {
        let brick = conversation(world)?;
        let offered = matches!(brick.find(world, "imageViewerNext"), Ok(Some(item))
            if brick.flag(world, item, "visible"));
        expect!(!offered, "a next button is offered");
        Ok(())
    });
    steps.step("the arrow keys do nothing", |world, _, _| {
        key(world, "right")?;
        key(world, "left")?;
        expect_showing(world, 1)?;
        let (brick, item) = viewer(world)?;
        expect!(brick.flag(world, item, "visible"), "the viewer closed");
        Ok(())
    });
    steps.step(
        "the user presses the (right|left) arrow key( twice)?",
        |world, c, _| {
            key(world, &c[0])?;
            if !c[1].is_empty() {
                key(world, &c[0])?;
            }
            Ok(())
        },
    );

    // --- Zooming.
    steps.step(
        "the user opened an image(?: that fits the window| with focus on it)?",
        |world, _, _| {
            message_with_images(world, 1, json!(null))?;
            open_image(world, 1, true)
        },
    );
    steps.step("the user clicks the image", |world, _, _| {
        click_picture(world)
    });
    steps.step(
        "the image is zoomed to twice its fitted size",
        |world, _, _| expect_zoom(world, 2.0),
    );
    steps.step("the user clicks the image again", |world, _, _| {
        click_picture(world)?;
        click_picture(world)
    });
    steps.step("the image is back to its fitted size", |world, _, _| {
        expect_zoom(world, 1.0)
    });
    steps.step("the user turns the wheel up over a point", |world, _, _| {
        // A picture within the window stays centred, so first make it wider.
        for _ in 0..8 {
            wheel(world, 500.0, 400.0, 120.0)?;
        }
        let (x, y) = picture_at(world, 0.5, 0.5)?;
        let (at_x, at_y) = (x + 100.0, y);
        let (brick, item) = viewer(world)?;
        let was = number(world, brick, item, "zoom");
        let (_, picture) = picture_item(world)?;
        let before = map_from_scene_x(world, brick, picture, at_x, at_y)? / was;
        wheel(world, at_x, at_y, 120.0)?;
        let zoom = number(world, brick, item, "zoom");
        let after = map_from_scene_x(world, brick, picture, at_x, at_y)? / zoom;
        // The picture grew about the point, which is still over the same
        // spot of it.
        expect!(
            zoom > was && (after - before).abs() < 1.0,
            "the point moved from {before} to {after} going from zoom {was} to {zoom}"
        );
        Ok(())
    });
    steps.step("the image is zoomed in around that point", |world, _, _| {
        let (brick, item) = viewer(world)?;
        expect!(
            number(world, brick, item, "zoom") > 1.0,
            "the image did not zoom"
        );
        Ok(())
    });
    steps.step(
        "the user turns the wheel down at its fitted size",
        |world, _, _| {
            let (x, y) = picture_at(world, 0.5, 0.5)?;
            wheel(world, x, y, -120.0)
        },
    );
    steps.step("the image is left at its fitted size", |world, _, _| {
        expect_zoom(world, 1.0)
    });
    steps.step(
        "the user pinches or holds Control and turns the wheel",
        |world, _, _| {
            let (x, y) = picture_at(world, 0.5, 0.5)?;
            wheel_ctrl(world, x, y)
        },
    );
    steps.step(
        "the image is zoomed faster than the wheel alone",
        |world, _, _| expect_zoom(world, 1.5),
    );
    steps.step("the user zooms in as far as it will go", |world, _, _| {
        for _ in 0..40 {
            let (x, y) = picture_at(world, 0.5, 0.5)?;
            wheel(world, x, y, 120.0)?;
        }
        Ok(())
    });
    steps.step("the image is eight times its fitted size", |world, _, _| {
        expect_zoom(world, 8.0)
    });
    steps.step("zooming further changes nothing", |world, _, _| {
        wheel(world, 500.0, 400.0, 120.0)?;
        expect_zoom(world, 8.0)
    });
    steps.step(
        "the user presses (Enter|Space|plus|minus|0) in the viewer",
        |world, c, _| {
            if c[0] == "minus" || c[0] == "0" {
                key(world, "\"+\"")?;
                key(world, "\"+\"")?;
            }
            key(world, &key_named(&c[0]))
        },
    );
    steps.step(
        "the image zooms to twice its fitted size or returns",
        |world, _, _| {
            expect_zoom(world, 2.0)?;
            key(world, "enter")?;
            expect_zoom(world, 1.0)
        },
    );
    steps.step("the image zooms in one step", |world, _, _| {
        expect_zoom(world, 1.25)
    });
    steps.step("the image zooms out one step", |world, _, _| {
        expect_zoom(world, 1.25)
    });
    steps.step("the image returns to its fitted size", |world, _, _| {
        expect_zoom(world, 1.0)
    });

    // --- Looking around.
    steps.step("the user zoomed an opened image", |world, _, _| {
        message_with_images(world, 1, json!(null))?;
        open_image(world, 1, true)?;
        // Far enough that the picture overflows its stage.
        for _ in 0..40 {
            let (x, y) = picture_at(world, 0.5, 0.5)?;
            wheel(world, x, y, 120.0)?;
        }
        expect_zoom(world, 8.0)
    });
    steps.step("the user drags it with the mouse", |world, _, _| {
        world.pointer(|now| PointerEvent::press(500.0, 400.0, now))?;
        world.pointer(|now| PointerEvent::moved(480.0, 390.0, MouseButtons::LEFT, now))?;
        world.pointer(|now| PointerEvent::moved(450.0, 380.0, MouseButtons::LEFT, now))?;
        world.pointer(|now| PointerEvent::release(450.0, 380.0, now))?;
        world.sync()
    });
    steps.step(
        "the part of the image shown moves with the pointer",
        |world, _, _| {
            let (brick, item) = viewer(world)?;
            let pan = number(world, brick, item, "panX");
            expect!((pan + 50.0).abs() < 1.0, "the image panned by {pan}");
            Ok(())
        },
    );
    steps.step(
        "letting go does not zoom the image back out",
        |world, _, _| expect_zoom(world, 8.0),
    );
    steps.step(
        "the user zooms in and presses the right arrow key",
        |world, _, _| {
            for _ in 0..40 {
                key(world, "\"+\"")?;
            }
            key(world, "right")
        },
    );
    steps.step(
        "the zoomed image moves to show more to its right",
        |world, _, _| {
            let (brick, item) = viewer(world)?;
            let pan = number(world, brick, item, "panX");
            expect!(pan == -40.0, "the image panned by {pan}");
            expect_showing(world, 2)
        },
    );
    steps.step(
        "the user returns the image to its fitted size and presses the right arrow key",
        |world, _, _| {
            key(world, "0")?;
            key(world, "right")
        },
    );
    steps.step(
        "the third image is shown at its fitted size",
        |world, _, _| {
            expect_showing(world, 3)?;
            let (brick, picture) = picture_item(world)?;
            world.wait_for_with(
                |w| {
                    number(w, brick, picture, "status") == 1.0
                        && number(w, brick, picture, "width") > 0.0
                },
                |_| "the third picture to load".to_owned(),
            )?;
            expect_zoom(world, 1.0)
        },
    );
    steps.step("the user zooms to twice its fitted size", |world, _, _| {
        click_picture(world)
    });
    steps.step(
        &format!("{Q} is announced to assistive technology"),
        |world, c, _| {
            let (brick, item) = viewer(world)?;
            let announced = brick.text_of(world, item, "announcement");
            expect!(announced == c[0], "announced {announced}");
            Ok(())
        },
    );

    // --- Closing.
    steps.step(
        "the user opened an image from the conversation",
        |world, _, _| {
            message_with_images(world, 1, json!(null))?;
            open_image(world, 1, true)
        },
    );
    steps.step("the user presses Escape in the viewer", |world, _, _| {
        key(world, "escape")
    });
    steps.step("the user clicks beside the image", |world, _, _| {
        world.click_at(20.0, 700.0)?;
        world.sync()
    });
    steps.step("the user uses the close button", |world, _, _| {
        let brick = conversation(world)?;
        brick.click(world, "imageViewerClose")
    });
    steps.step("the viewer closes", |world, _, _| {
        let (brick, item) = viewer(world)?;
        world.wait_for_with(
            |w| !brick.flag(w, item, "visible"),
            |_| "the image viewer to close".to_owned(),
        )
    });
    steps.step(
        "focus returns to what the user opened it from",
        |world, _, _| {
            let brick = conversation(world)?;
            expect!(
                brick.focused_named(world, "attachment-image-1")?,
                "focus is not on the image it was opened from"
            );
            Ok(())
        },
    );
    steps.step(
        "the user opened an image and right-clicked it to open its menu",
        |world, _, _| {
            message_with_images(world, 1, json!(null))?;
            open_image(world, 1, true)?;
            let (x, y) = picture_at(world, 0.5, 0.5)?;
            world.click_at_with(x, y, MouseButtons::RIGHT, ljos::item::Modifiers::empty())?;
            let brick = conversation(world)?;
            let menu = brick.item(world, "imageViewerMenu")?;
            world.wait_for_with(
                |w| brick.flag(w, menu, "opened"),
                |_| "the menu to open".to_owned(),
            )
        },
    );
    steps.step("the viewer's menu closes", |world, _, _| {
        let brick = conversation(world)?;
        let menu = brick.item(world, "imageViewerMenu")?;
        world.wait_for_with(
            |w| !brick.flag(w, menu, "visible"),
            |_| "the menu to close".to_owned(),
        )
    });
    steps.step("the image is still open", |world, _, _| {
        let (brick, item) = viewer(world)?;
        expect!(brick.flag(world, item, "visible"), "the viewer closed");
        Ok(())
    });

    // --- Failures.
    steps.step(
        "the user opened an image whose picture cannot be loaded(?: and that has (an|no) address on the web)?",
        |world, c, _| {
            if c[0] == "no" {
                world
                    .mc
                    .part::<FakeAttachments>()
                    .unsigned
                    .insert("image-1".to_owned());
            } else {
                world
                    .mc
                    .part::<FakeAttachments>()
                    .broken
                    .insert("image-1".to_owned());
            }
            message_with_images(world, 1, json!(null))?;
            open_image(world, 1, false)
        },
    );
    steps.step("the image has an address on the web", |world, _, _| {
        let (brick, item) = viewer(world)?;
        world.wait_for_with(
            |w| brick.flag(w, item, "webAddress"),
            |_| "a signed address".to_owned(),
        )
    });
    steps.step(&format!("the viewer says {Q}"), |world, c, _| {
        let brick = conversation(world)?;
        let (_, item) = viewer(world)?;
        world.wait_for_with(
            |w| {
                brick.flag(w, item, "failed")
                    && matches!(brick.find(w, "imageViewerProblem"), Ok(Some(problem))
                        if brick.text_of(w, problem, "text") == c[0])
            },
            |w| {
                let said = brick
                    .find(w, "imageViewerProblem")
                    .ok()
                    .flatten()
                    .map(|problem| brick.text_of(w, problem, "text"))
                    .unwrap_or_default();
                format!("the viewer says {said}")
            },
        )
    });
    steps.step("the viewer offers to open the original", |world, _, _| {
        let brick = conversation(world)?;
        let (_, item) = viewer(world)?;
        world.wait_for_with(
            |w| {
                brick.flag(w, item, "failed")
                    && matches!(brick.find(w, "imageViewerOriginal"), Ok(Some(offer))
                        if brick.flag(w, offer, "visible"))
            },
            |_| "the offer to open the original".to_owned(),
        )
    });

    // --- A Snap Shot's text.
    steps.step(
        "the user opened a Snap Shot (that has accessibility data|whose accessibility data is (text|JSON))",
        |world, c, _| {
            let accessibility = if c[1] == "JSON" {
                json!({"format": "tree", "root": {"role": "window"}})
            } else {
                json!({"format": "flat-text", "text": "Captured words", "truncated": false})
            };
            let source = json!({"kind": "snap-shot", "appName": "Files",
                                "accessibility": accessibility});
            message_with_images(world, 1, json!({"source": source}))?;
            open_image(world, 1, true)
        },
    );
    steps.step(
        "the user chooses to show its extracted text",
        |world, _, _| {
            let brick = conversation(world)?;
            brick.click(world, "imageViewerAccess")
        },
    );
    steps.step("the text takes the picture's place", |world, _, _| {
        world.sync()?;
        let brick = conversation(world)?;
        let text_item = brick.item(world, "imageViewerText")?;
        let (_, picture) = picture_item(world)?;
        expect!(
            brick.text_of(world, text_item, "text") == "Captured words"
                && !brick.flag(world, picture, "visible"),
            "the picture is still shown"
        );
        Ok(())
    });
    steps.step("the user chooses to show the screenshot", |world, _, _| {
        let brick = conversation(world)?;
        brick.click(world, "imageViewerAccess")
    });
    steps.step("the picture is shown again", |world, _, _| {
        world.sync()?;
        let (brick, picture) = picture_item(world)?;
        expect!(
            brick.flag(world, picture, "visible"),
            "the picture is not shown"
        );
        Ok(())
    });
    steps.step(
        &format!("the control to see it reads {Q}"),
        |world, c, _| {
            let brick = conversation(world)?;
            let control = brick.item(world, "imageViewerAccess")?;
            let label = brick.text_of(world, control, "text");
            expect!(label == c[0], "the control reads {label}");
            Ok(())
        },
    );

    // --- A draft's attachment by kind.
    steps.step(&format!("the user has attached {Q} to a draft"), |world, c, _| {
        let (mime, bytes): (&str, Vec<u8>) = match c[0].as_str() {
            "receipt.png" => ("image/png", picture()),
            "notes.md" => ("text/markdown", b"# Notes\n".to_vec()),
            "build.log" => ("text/plain", b"built\n".to_vec()),
            "cart.ts" => (
                "text/plain",
                b"export const total = (items: number[]) => items.length;\nexport const tax = 0.2;\n"
                    .to_vec(),
            ),
            "notes.txt" => ("text/plain", b"buy milk & eggs\n".to_vec()),
            "page.html" => ("text/html", PAGE.to_vec()),
            "invoice.pdf" => ("application/pdf", media_fixture("invoice.pdf")),
            other => fail!("no attachment {other}"),
        };
        open_draft(
            world,
            json!({
                "name": c[0], "mimeType": mime,
                "base64": base64::engine::general_purpose::STANDARD.encode(&bytes),
            }),
        )
    });
    steps.step("its text is shown coloured as TypeScript", |world, _, _| {
        let (text, highlighter) = attachment_text(world)?;
        let brick = brick_shown(world)?;
        let drawn = brick.text_of(world, text, "text");
        expect!(
            drawn == "export const total = (items: number[]) => items.length;\nexport const tax = 0.2;\n",
            "the text reads {drawn:?}"
        );
        let runs = coloured_runs(world, text);
        expect!(
            flag(world, highlighter, "coloured") && runs > 0,
            "the text has {runs} coloured runs"
        );
        Ok(())
    });
    steps.step("its text is shown plain", |world, _, _| {
        let (text, highlighter) = attachment_text(world)?;
        let brick = brick_shown(world)?;
        expect!(
            !brick.text_of(world, text, "text").is_empty(),
            "the text is empty"
        );
        let runs = coloured_runs(world, text);
        expect!(
            !flag(world, highlighter, "coloured") && runs == 0,
            "the text has {runs} coloured runs"
        );
        Ok(())
    });
    steps.step(
        "the user opens the attachment from the draft",
        |world, _, _| world.sync(),
    );
    steps.step("it is shown as an image", |world, _, _| {
        let brick = brick_shown(world)?;
        let image = brick.item(world, "attachmentViewerImage")?;
        expect!(
            text(&viewed(world), "kind") == "image" && brick.flag(world, image, "visible"),
            "the viewer is {}",
            show(&viewed(world))
        );
        Ok(())
    });
    steps.step(
        "it is shown as rendered Markdown that can switch to source",
        |world, _, _| {
            let brick = brick_shown(world)?;
            world.wait_for_with(
                |w| matches!(brick.find(w, "attachmentViewerMarkdown"), Ok(Some(_))),
                |_| "rendered Markdown".to_owned(),
            )?;
            brick.click(world, "attachmentViewerSource")?;
            world.wait_for_with(
                |w| matches!(brick.find(w, "attachmentViewerText"), Ok(Some(_))),
                |_| "the source".to_owned(),
            )
        },
    );
    steps.step("it is shown as text", |world, _, _| {
        let brick = brick_shown(world)?;
        world.wait_for_with(
            |w| {
                matches!(brick.find(w, "attachmentViewerText"), Ok(Some(item))
                    if brick.text_of(w, item, "text") == "built\n")
            },
            |_| "the text".to_owned(),
        )
    });
    steps.step(
        "it is shown as a document the user can page through",
        |world, _, _| {
            let brick = brick_shown(world)?;
            world.wait_for_with(
                |w| {
                    matches!(brick.find(w, "documentView"), Ok(Some(document))
                        if number(w, brick, document, "pageCount") == 2.0)
                },
                |_| "the document".to_owned(),
            )?;
            let document = brick.item(world, "documentView")?;
            world
                .engine()
                .invoke_by_name(document, "goTo", &[Value::Int(1)])
                .map_err(|e| crate::harness::Failure(e.to_string()))?;
            world.wait_for_with(
                |w| number(w, brick, document, "currentPage") == 1.0,
                |_| "the second page".to_owned(),
            )
        },
    );
    steps.step(
        &format!("a sent message carries the attachment {Q}"),
        |world, c, _| {
            world.mc.part::<FakeSent>().name.clone_from(&c[0]);
            Ok(())
        },
    );
    steps.step(
        "the user opens the attachment from the conversation",
        |world, _, _| {
            let name = world.mc.part::<FakeSent>().name.clone();
            open_sent(world, &name, "application/pdf", media_fixture(&name), true)
        },
    );
    steps.step(
        &format!("{Q} is shown as a document from the environment"),
        |world, c, _| {
            let brick = conversation(world)?;
            world.wait_for_with(
                |w| {
                    matches!(brick.find(w, "documentView"), Ok(Some(document))
                        if number(w, brick, document, "pageCount") == 2.0)
                },
                |_| "the document".to_owned(),
            )?;
            expect!(
                text(&viewed(world), "name") == c[0]
                    && world
                        .mc
                        .peek::<FakeAttachments>()
                        .is_some_and(|f| f.signatures > 0),
                "{}",
                show(&viewed(world))
            );
            Ok(())
        },
    );

    // --- A video in a message.
    steps.step("a message carries a video", |world, _, _| {
        world.mc.part::<FakeSent>().name = "clip.mp4".to_owned();
        Ok(())
    });
    steps.step(
        "a message carries a video and an image and the user opened the video",
        |world, _, _| {
            message_with_images(world, 1, json!(null))?;
            open_sent(
                world,
                "clip.mp4",
                "video/mp4",
                media_fixture("clip.mp4"),
                true,
            )?;
            playing_video(world).map(drop)
        },
    );
    steps.step("the user opens the video", |world, _, _| {
        open_sent(
            world,
            "clip.mp4",
            "video/mp4",
            media_fixture("clip.mp4"),
            true,
        )
    });
    steps.step("it starts playing in the viewer", |world, _, _| {
        playing_video(world).map(drop)
    });
    steps.step(
        "the user presses the right arrow key with focus on the video",
        |world, _, _| {
            let (brick, player) = playing_video(world)?;
            world.wait_for_with(
                |w| brick.flag(w, player, "activeFocus"),
                |_| "the video to have focus".to_owned(),
            )?;
            key(world, "right")?;
            world.sync()
        },
    );
    steps.step(
        "the key is left to the video and the viewer stays on the video",
        |world, _, _| {
            // The seek may have run the short clip to its end, so it need
            // not still be playing.
            let brick = conversation(world)?;
            let player = brick.item(world, "mediaPlayerView")?;
            expect!(
                brick.flag(world, player, "activeFocus")
                    && number(world, brick, player, "position") > 0.0
                    && text(&viewed(world), "kind") == "video",
                "{}",
                show(&viewed(world))
            );
            Ok(())
        },
    );

    // --- As captured.
    steps.step(
        &format!("the user attached {Q} and has since changed the project's {Q}"),
        |world, c, _| {
            let name = c[0].rsplit('/').next().unwrap_or(&c[0]).to_owned();
            open_draft(
                world,
                json!({
                    "name": name, "mimeType": "text/plain",
                    "base64": base64::engine::general_purpose::STANDARD.encode(b"captured"),
                }),
            )?;
            world.dispatch("attachment.viewer.close", json!({}))?;
            let folder = saves(world);
            std::fs::write(folder.join(&name), b"changed since")
                .map_err(|e| crate::harness::Failure(e.to_string()))?;
            Ok(())
        },
    );
    steps.step("the user opens the attachment", |world, _, _| {
        if !viewed(world).is_null() {
            return Ok(()); // A scenario's Given already opened it, failed or not.
        }
        brick_shown(world)?.click(world, "attachmentOpen:app.ts")
    });
    steps.step("the captured contents are shown", |world, _, _| {
        world.wait_for_with(
            |w| text(&viewed(w), "text") == "captured",
            |w| format!("the captured text; the viewer shows {}", show(&viewed(w))),
        )
    });

    // --- Whether a file is read as a table.
    steps.step(
        &format!("the user opens {Q} of type {Q} rendered"),
        |world, c, _| {
            open_draft(
                world,
                json!({
                    "name": c[0].rsplit('/').next().unwrap_or(&c[0]),
                    "mimeType": c[1],
                    "base64": base64::engine::general_purpose::STANDARD
                        .encode(b"a,b\tc\n1,2\t3\n"),
                }),
            )
        },
    );
    steps.step("the file is shown as a (comma|tab) table", |world, c, _| {
        expect!(
            text(&viewed(world), "kind") == "table",
            "the viewer is {}",
            show(&viewed(world))
        );
        let header = if c[0] == "comma" {
            "| a | b\tc |"
        } else {
            "| a,b | c |"
        };
        let rendered = text(&viewed(world), "rendered").to_owned();
        expect!(rendered.starts_with(header), "the table is {rendered}");
        Ok(())
    });
    steps.step("the file is not shown as a table", |world, _, _| {
        expect!(
            text(&viewed(world), "kind") != "table",
            "the viewer is {}",
            show(&viewed(world))
        );
        Ok(())
    });

    // --- A sent attachment.
    steps.step(
        "the user is viewing an attachment of a sent message",
        |world, _, _| {
            open_sent(world, "build.log", "text/plain", b"built\n".to_vec(), true)?;
            expect!(
                text(&viewed(world), "kind") == "text",
                "the viewer is {}",
                show(&viewed(world))
            );
            Ok(())
        },
    );
    steps.step(
        "the user saves it and closes the viewer before it has downloaded",
        |world, _, _| {
            world.dispatch("attachment.viewer.save", json!({}))?;
            world.dispatch("attachment.viewer.close", json!({}))
        },
    );
    steps.step("the source of the draft's page is shown", |world, _, _| {
        let brick = brick_shown(world)?;
        world.wait_for_with(
            |w| {
                matches!(brick.find(w, "attachmentViewerText"), Ok(Some(item))
                    if brick.text_of(w, item, "text").as_bytes() == PAGE)
            },
            |_| "the source".to_owned(),
        )
    });
    steps.step("the attachment fails to load", |world, _, _| {
        world.dispatch("attachment.viewer.mediaFailed", json!({}))?;
        world.wait_for_with(
            |w| text(&viewed(w), "kind") == "failed",
            |w| show(&viewed(w)),
        )
    });
    steps.step("the user tries it again", |world, _, _| {
        brick_shown(world)?.click(world, "attachmentViewerRetry")
    });
    steps.step("the user saves it", |world, _, _| {
        brick_shown(world)?.click(world, "attachmentViewerSave")
    });
    steps.step(
        "the file is downloaded under its own name",
        |world, _, _| {
            expect_toast(world, "success", "Saved build.log")?;
            let folder = saves(world);
            let read = std::fs::read(folder.join("build.log"));
            expect!(
                read.ok().as_deref() == Some(b"built\n".as_slice()),
                "the saved file is missing or differs"
            );
            Ok(())
        },
    );
    steps.step(
        "the attachment's environment is unreachable",
        |world, _, _| {
            serve(world);
            world.mc.part::<FakeAttachments>().unreachable = true;
            open_sent(world, "build.log", "text/plain", b"built\n".to_vec(), true)
        },
    );
    steps.step("the environment cannot be reached", |world, _, _| {
        world.mc.part::<FakeAttachments>().unreachable = true;
        Ok(())
    });
    steps.step(
        "the environment no longer has the attachment",
        |world, _, _| {
            serve(world);
            world
                .mc
                .part::<FakeAttachments>()
                .gone
                .insert("file-1".to_owned());
            open_sent(world, "build.log", "text/plain", b"built\n".to_vec(), true)
        },
    );
    steps.step(
        "the environment is reachable again and the user retries",
        |world, _, _| {
            {
                let fake = world.mc.part::<FakeAttachments>();
                fake.unreachable = false;
                fake.gone.clear();
            }
            brick_shown(world)?.click(world, "attachmentViewerRetry")
        },
    );
    steps.step("the attachment is shown", |world, _, _| {
        world.wait_for_with(
            |w| text(&viewed(w), "text") == "built\n",
            |w| format!("the attachment; the viewer is {}", show(&viewed(w))),
        )
    });
    steps.step(
        "the user is told the file could not be saved with the reason",
        |world, _, _| expect_toast(world, "error", "Could not save build.log"),
    );

    // --- A page.
    steps.step(
        "the user opened an attachment as a rendered page an hour ago",
        |world, _, _| {
            open_sent(world, "page.html", "text/html", PAGE.to_vec(), true)?;
            expect!(
                text(&viewed(world), "kind") == "page",
                "the viewer is {}",
                show(&viewed(world))
            );
            Ok(())
        },
    );
    steps.step("the user switches to its source", |world, _, _| {
        world.mc.part::<FakeAttachments>().signatures = 100;
        brick_shown(world)?.click(world, "attachmentViewerSource")
    });
    steps.step(
        "the source is shown without the user reconnecting",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    viewed(w).get("source").and_then(serde_json::Value::as_str)
                        == Some(std::str::from_utf8(PAGE).unwrap_or_default())
                },
                |w| format!("the source; the viewer is {}", show(&viewed(w))),
            )?;
            expect!(
                world
                    .mc
                    .peek::<FakeAttachments>()
                    .is_some_and(|f| f.signatures == 101),
                "the source was not read through a new address"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the attachment {Q} is not valid text"),
        |world, c, _| {
            open_sent(world, &c[0], "text/html", PAGE.to_vec(), true)?;
            world
                .mc
                .part::<FakeAttachments>()
                .bytes
                .insert("file-1".to_owned(), b"<h1>caf\xe9</h1>".to_vec());
            Ok(())
        },
    );
    steps.step(
        "the user is told the source could not be loaded",
        |world, _, _| {
            world.wait_for_with(
                |w| text(&viewed(w), "sourceProblem") == "The source could not be loaded.",
                |w| show(&viewed(w)),
            )
        },
    );
    steps.step(
        "the user switches back to the rendered page",
        |world, _, _| brick_shown(world)?.click(world, "attachmentViewerSource"),
    );
    steps.step("the page is shown", |world, _, _| {
        let brick = brick_shown(world)?;
        world.wait_for_with(
            |w| matches!(brick.find(w, "attachmentViewerPage"), Ok(Some(_))),
            |_| "the rendered page".to_owned(),
        )
    });

    // --- Copying.
    steps.step(
        "the user is viewing a text attachment that is (within|over) the preview limit",
        |world, c, _| {
            let bytes = if c[0] == "within" {
                b"short\n".to_vec()
            } else {
                vec![b'x'; 1024 * 1024 + 10]
            };
            world.set_clipboard("");
            open_sent(world, "build.log", "text/plain", bytes, true)
        },
    );
    steps.step("the user copies it", |world, _, _| {
        let brick = brick_shown(world)?;
        let shown = |w: &World| {
            brick
                .item(w, "attachmentViewerCopy")
                .is_ok_and(|copy| w.engine().read_by_name(copy, "visible") == Value::Bool(true))
        };
        if !shown(world) {
            let mut viewed = viewed(world);
            if let Some(text) = viewed.get_mut("text").filter(|t| t.is_string()) {
                *text = json!(format!(
                    "{} characters",
                    text.as_str().unwrap_or("").chars().count()
                ));
            }
            fail!("the copy action is hidden; the viewer has {viewed}");
        }
        brick.click(world, "attachmentViewerCopy")
    });
    steps.step("the copy is all of its text", |world, _, _| {
        let copied = world.clipboard();
        expect!(
            copied == "short\n",
            "the clipboard holds {} characters",
            copied.chars().count()
        );
        Ok(())
    });
    steps.step(
        "the copy is only the part shown, and the action says so",
        |world, _, _| {
            let copied = world.clipboard();
            expect!(
                copied.chars().count() == 1024 * 1024,
                "the clipboard holds {} characters",
                copied.chars().count()
            );
            let brick = brick_shown(world)?;
            let copy = brick.item(world, "attachmentViewerCopy")?;
            let label = brick.text_of(world, copy, "text");
            expect!(label == "Copy part shown", "the action reads {label}");
            Ok(())
        },
    );
}

fn key_named(name: &str) -> String {
    match name {
        "Enter" => "enter".to_owned(),
        "Space" => "space".to_owned(),
        "plus" => "\"+\"".to_owned(),
        "minus" => "\"-\"".to_owned(),
        other => other.to_lowercase(),
    }
}

/// The x of the scene point (`x`, `y`) in `item`'s own space.
fn map_from_scene_x(world: &World, brick: Brick, item: ObjectId, x: f64, y: f64) -> Outcome<f64> {
    let (origin_x, _) = brick.at_px(world, item, 0.0, 0.0)?;
    let _ = y;
    Ok(x - origin_x)
}
