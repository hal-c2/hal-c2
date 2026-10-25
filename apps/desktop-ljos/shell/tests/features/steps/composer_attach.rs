//! What a draft carries besides its text, as the composer brick on screen
//! takes it (desktop-qt's ComposerAttachSteps.cpp): images and files chosen,
//! dropped and pasted, their uploads, and removing them
//! (features/composer/attachments.feature).

use std::path::PathBuf;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::composer;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use ljos::prelude::{
    ClipboardImage, ClipboardMode, ExternalDrag, ObjectId, Platform, Value as QmlValue,
    external_drag, file_url,
};
use serde_json::{Value, json};

use crate::fake_mc::FakeMc;
use crate::harness::{Failure, Outcome, Q, Steps, show, text};
use crate::steps::composer_brick::{
    composer_brick, composer_brick_shown, composer_item, composer_part, editor, press_in_composer,
    settle_composer, type_in_composer,
};
use crate::steps::stream;
use crate::world::{OTHER_MACHINE, World};
use crate::{expect, fail};

/// `attachments.createUploadUrl` and the upload it hands out, as the MC's
/// (apps/server-ex lib/hal_c2/attachments.ex): an id for the pending upload
/// and a signed URL that takes its bytes. `refuse` fails the upload itself.
#[derive(Default)]
struct FakeFileUploads {
    asked: Vec<Value>,
    /// The ids whose bytes arrived.
    stored: Vec<String>,
    deleted: Vec<String>,
    refuse: String,
}

fn extension(mc: &mut FakeMc) {
    mc.on_rpc("attachments.createUploadUrl", |mc, rpc| {
        let fake = mc.part::<FakeFileUploads>();
        fake.asked.push(rpc.payload.clone());
        let number = fake.asked.len();
        let id = format!("pending-{number}");
        let url = format!("/api/attachments/upload/token-{number}");
        let stored_id = id.clone();
        mc.on_http(&url, move |mc, _, respond| {
            let fake = mc.part::<FakeFileUploads>();
            if !fake.refuse.is_empty() {
                respond.send(502, &json!({"message": fake.refuse}));
                return Ok(());
            }
            fake.stored.push(stored_id.clone());
            respond.send(204, &json!({}));
            Ok(())
        });
        let rpc = rpc.clone();
        let answer = move |mc: &mut FakeMc| {
            mc.reply(
                &rpc,
                json!({"attachmentId": id, "relativeUrl": url, "expiresAt": 4102444800000.0}),
            );
        };
        if mc.holding("uploads") {
            mc.defer(answer);
        } else {
            answer(mc);
        }
        Ok(())
    });
    mc.on_rpc("attachments.delete", |mc, rpc| {
        let id = text(&rpc.payload["attachmentId"]);
        mc.part::<FakeFileUploads>().deleted.push(id);
        mc.reply(rpc, Value::Null);
        Ok(())
    });
}

/// What the draft read before the user took something off it.
#[derive(Default)]
struct Typed {
    text: String,
}

fn composer_state(world: &World) -> Value {
    world.state("composer")
}

fn carried(world: &World) -> Vec<String> {
    composer_state(world)["attachments"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|attachment| text(&attachment["name"]))
        .collect()
}

fn carried_text(world: &World) -> String {
    carried(world).join(", ")
}

/// A real image file of that name on this machine.
fn image_file(world: &World, name: &str) -> Outcome<PathBuf> {
    let dir = world.home_dir().join("pictures");
    std::fs::create_dir_all(&dir)
        .map_err(|e| Failure(format!("could not make {}: {e}", dir.display())))?;
    let image = image::RgbImage::from_pixel(4, 4, image::Rgb([0, 139, 139]));
    let path = dir.join(name);
    image
        .save(&path)
        .map_err(|e| Failure(format!("could not write {name}: {e}")))?;
    Ok(path)
}

/// A file of that name on this machine.
fn plain_file(world: &World, name: &str) -> Outcome<PathBuf> {
    let dir = world.home_dir().join("documents");
    std::fs::create_dir_all(&dir)
        .map_err(|e| Failure(format!("could not make {}: {e}", dir.display())))?;
    let path = dir.join(name);
    std::fs::write(&path, "create table carts (id integer);\n")
        .map_err(|e| Failure(format!("could not write {name}: {e}")))?;
    Ok(path)
}

/// What the picker's accept hands the composer.
fn choose(world: &mut World, files: &[PathBuf]) -> Outcome {
    let item = composer_item(world)?;
    let urls: Vec<QmlValue> = files
        .iter()
        .map(|file| QmlValue::from(file_url(file).as_str()))
        .collect();
    world
        .engine()
        .invoke_by_name(item, "attach", &[QmlValue::List(std::sync::Arc::new(urls))])
        .map_err(|e| Failure(format!("attach: {e:?}")))?;
    world.sync()
}

/// Drops `files` on the composer's card, as the platform delivers a drag.
fn drop_files(world: &mut World, files: Vec<PathBuf>) -> Outcome {
    let (brick, field) = editor(world)?;
    let at = brick.at(world, field, 0.5, 0.5)?;
    for drag in [
        ExternalDrag::Entered {
            files: files.clone(),
            at: Some(at),
        },
        ExternalDrag::Moved { at },
        ExternalDrag::Dropped {
            files,
            at: Some(at),
        },
    ] {
        external_drag(world.engine(), &drag);
    }
    world.sync()
}

/// A drag from another application over the conversation, while it lasts:
/// what it carries and where it is.
#[derive(Default)]
struct Dragged {
    files: Vec<PathBuf>,
    at: Option<(f64, f64)>,
}

/// Over the timeline's part of the conversation, above the composer.
fn over_conversation(world: &mut World) -> Outcome<(f64, f64)> {
    let brick = composer_brick(world)?;
    let area = brick.item(world, "conversationDrop")?;
    brick.at(world, area, 0.5, 0.2)
}

/// Drags `files` from outside the window to `at`, as the platform delivers
/// it.
fn drag_files(world: &mut World, files: Vec<PathBuf>, at: (f64, f64)) -> Outcome {
    composer_brick(world)?;
    for drag in [
        ExternalDrag::Entered {
            files: files.clone(),
            at: Some(at),
        },
        ExternalDrag::Moved { at },
    ] {
        external_drag(world.engine(), &drag);
    }
    *world.part::<Dragged>() = Dragged {
        files,
        at: Some(at),
    };
    world.sync()
}

/// The drag leaves the window.
fn drag_leave(world: &mut World) -> Outcome {
    external_drag(world.engine(), &ExternalDrag::Left);
    *world.part::<Dragged>() = Dragged::default();
    world.sync()
}

fn drop_hint_shown(world: &mut World) -> Outcome<bool> {
    let brick = composer_brick(world)?;
    Ok(brick.find_visible(world, "conversationDropHint")?.is_some()
        && brick.shows(world, "Drop files to attach")?)
}

/// Drags the composer brick's selected text to `at` in the window.
fn drag_text(world: &mut World, at: (f64, f64)) -> Outcome {
    let brick = composer_brick(world)?;
    let root = brick.item(world, "composerBrick")?;
    let origin = brick.at(world, root, 0.0, 0.0)?;
    let item = brick.item(world, "textDrag")?;
    // Moves are told on a later turn; turning the drag on tells the area
    // under it at once.
    brick.write(world, item, "dragging", QmlValue::from(false))?;
    brick.write(world, item, "x", QmlValue::from(at.0 - origin.0))?;
    brick.write(world, item, "y", QmlValue::from(at.1 - origin.1))?;
    brick.write(world, item, "dragging", QmlValue::from(true))?;
    world.sync()
}

fn attachment(world: &World, name: &str) -> Value {
    composer_state(world)["attachments"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|entry| entry["name"] == json!(name))
        .cloned()
        .unwrap_or(Value::Null)
}

fn wait_for_upload(world: &mut World, name: &str, status: &str) -> Outcome {
    world.wait_for_with(
        |w| {
            let entry = attachment(w, name);
            !entry.is_null() && text(&entry["status"]) == status
        },
        |w| {
            format!(
                "{name}'s upload to be \"{status}\"; the draft carries {}",
                show(&composer_state(w)["attachments"])
            )
        },
    )
}

fn commands_of(world: &mut World, kind: &str) -> Outcome<Vec<Value>> {
    world.sync()?;
    Ok(world
        .mc
        .commands
        .iter()
        .filter(|command| command["type"] == json!(kind))
        .cloned()
        .collect())
}

fn toasts(world: &World) -> Vec<Value> {
    world.state("toasts")["items"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn told(world: &World, title: &str, description: &str) -> bool {
    toasts(world).iter().any(|toast| {
        toast["title"] == json!(title)
            && (description.is_empty() || toast["description"] == json!(description))
    })
}

fn route_target(world: &World) -> String {
    world
        .with::<Navigation, _>(|n, _| match n.route() {
            Route::Draft(id) => id.clone(),
            Route::Thread(key) => key.clone(),
            _ => String::new(),
        })
        .unwrap_or_default()
}

fn thread_target(world: &World) -> String {
    world
        .with::<Navigation, _>(|n, _| n.thread_key().to_owned())
        .unwrap_or_default()
}

fn draft_text(world: &World) -> String {
    composer::draft(world.engine(), &route_target(world))
}

fn set_draft(world: &mut World, typed: &str) -> Outcome {
    let target = thread_target(world);
    world.dispatch(
        "composer.text.set",
        json!({"target": target, "text": typed, "cursor": typed.chars().count()}),
    )
}

/// 40 KiB of log lines.
fn log_output() -> String {
    let mut log = String::new();
    let mut line = 1;
    while log.len() < 40 * 1024 {
        log += &format!("{line:5} PASS cart totals add up with the tax line\n");
        line += 1;
    }
    log.truncate(40 * 1024);
    log
}

fn paste(world: &mut World, as_text: bool) -> Outcome {
    composer_brick(world)?;
    let _ = Platform::of(world.engine())
        .clipboard()
        .set_text(ClipboardMode::Clipboard, &log_output());
    let took = press_in_composer(world, if as_text { "mod+shift+v" } else { "mod+v" })?;
    expect!(took, "the composer did not take the paste");
    Ok(())
}

fn expect_inserted(world: &mut World) -> Outcome {
    settle_composer(world)?;
    let (brick, field) = editor(world)?;
    let shown = brick.text_of(world, field, "text");
    expect!(
        shown == log_output() && draft_text(world) == log_output(),
        "the draft holds {} characters",
        draft_text(world).chars().count()
    );
    // Where it can be edited.
    type_in_composer(world, "!")?;
    let length = brick.text_of(world, field, "text").chars().count();
    expect!(
        length == log_output().chars().count() + 1,
        "the editor did not take a key"
    );
    Ok(())
}

fn chip(world: &mut World, name: &str) -> Outcome<ObjectId> {
    match composer_part(world, &format!("attachment:{name}"))? {
        Some(item) => Ok(item),
        None => fail!(
            "the composer shows no {name}; the draft carries {}",
            carried_text(world)
        ),
    }
}

/// Clicks `item` in the composer's window.
fn click(world: &mut World, item: ObjectId) -> Outcome {
    let brick = composer_brick(world)?;
    let (x, y) = brick.at(world, item, 0.5, 0.5)?;
    world.click_at(x, y)
}

fn visible(world: &mut World, item: ObjectId) -> Outcome<bool> {
    let brick = composer_brick(world)?;
    Ok(brick.flag(world, item, "visible"))
}

fn focus_input(world: &mut World) -> Outcome {
    let item = composer_item(world)?;
    world
        .engine()
        .invoke_by_name(item, "focusInput", &[])
        .map_err(|e| Failure(format!("focusInput: {e:?}")))?;
    Ok(())
}

fn first_message(world: &World) -> Value {
    world
        .mc
        .commands
        .iter()
        .find(|command| command["type"] == json!("message.dispatch"))
        .cloned()
        .unwrap_or(Value::Null)
}

fn drop_folder(world: &mut World, relative: &str) -> Outcome {
    let dir = world.home_dir().join("checkout").join(relative);
    std::fs::create_dir_all(&dir)
        .map_err(|e| Failure(format!("could not make {}: {e}", dir.display())))?;
    composer_brick(world)?;
    drop_files(world, vec![dir])
}

fn snap_shot(world: &mut World, source: Value) -> Outcome {
    let mut source = source;
    source["kind"] = json!("snap-shot");
    source["capturedAt"] = json!("2026-09-23T10:00:00Z");
    if source.get("appName").is_none() {
        source["appName"] = json!("Terminal");
    }
    if source.get("windowTitle").is_none() {
        source["windowTitle"] = json!("npm test");
    }
    let target = thread_target(world);
    composer::attach_image(
        world.engine(),
        &target,
        "window-terminal.png",
        "image/png",
        b"png",
        source.as_object().cloned().unwrap_or_default(),
    );
    world.sync()
}

fn question(world: &World) -> Value {
    world.state("turn")["questions"][0].clone()
}

fn answer_field(world: &mut World) -> Outcome<ObjectId> {
    match composer_part(world, "questionAnswer-database")? {
        Some(field) if visible(world, field)? => Ok(field),
        _ => fail!("the question takes no typed answer"),
    }
}

fn answer_files(world: &World) -> Vec<Value> {
    question(world)["questions"][0]["attachments"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn type_answer(world: &mut World, typed: &str) -> Outcome {
    let field = answer_field(world)?;
    click(world, field)?;
    let brick = composer_brick(world)?;
    expect!(
        brick.flag(world, field, "activeFocus"),
        "the answer field did not take the keyboard"
    );
    type_in_composer(world, typed)?;
    let read = brick.text_of(world, field, "text");
    expect!(read == typed, "the answer reads \"{read}\"");
    Ok(())
}

fn submit(world: &mut World) -> Outcome {
    let brick = composer_brick(world)?;
    let button = match composer_part(world, "questionSubmit")? {
        Some(button) => button,
        None => fail!("the answer cannot be submitted"),
    };
    expect!(
        brick.flag(world, button, "visible") && brick.flag(world, button, "enabled"),
        "the answer cannot be submitted"
    );
    click(world, button)?;
    world.sync()
}

fn stored(world: &mut World, id: &str) -> bool {
    world
        .mc
        .part::<FakeFileUploads>()
        .stored
        .iter()
        .any(|stored| stored == id)
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    steps.step(&format!("the user chooses {Q} to attach"), |world, c, _| {
        composer_brick(world)?;
        let file = image_file(world, &c[0])?;
        choose(world, &[file])
    });
    steps.step(
        &format!("the user drops {Q} and {Q} onto the composer"),
        |world, c, _| {
            composer_brick(world)?;
            let files = vec![image_file(world, &c[0])?, image_file(world, &c[1])?];
            drop_files(world, files)?;
            world.mc.part::<Typed>().text = format!("{}\n{}", c[0], c[1]);
            Ok(())
        },
    );
    steps.step(&format!("the draft carries {Q}"), |world, c, _| {
        if !world.checking {
            // With something typed beside it.
            set_draft(world, "What is wrong here?")?;
            composer_brick(world)?;
            let file = image_file(world, &c[0])?;
            choose(world, &[file])?;
        }
        world.wait_for_with(
            |w| carried(w) == [c[0].clone()],
            |w| {
                format!(
                    "the draft to carry {}; it carries {}",
                    c[0],
                    carried_text(w)
                )
            },
        )?;
        let item = chip(world, &c[0])?;
        expect!(visible(world, item)?, "{} is not shown", c[0]);
        Ok(())
    });
    steps.step("the draft carries both images", |world, _, _| {
        let dropped: Vec<String> = world
            .mc
            .part::<Typed>()
            .text
            .split('\n')
            .map(str::to_owned)
            .collect();
        world.wait_for_with(
            |w| carried(w) == dropped,
            |w| {
                format!(
                    "the draft to carry {}; it carries {}",
                    dropped.join(", "),
                    carried_text(w)
                )
            },
        )?;
        for name in &dropped {
            let item = chip(world, name)?;
            expect!(visible(world, item)?, "{name} is not shown");
        }
        Ok(())
    });
    steps.step(
        "sending the message sends the image with it",
        |world, _, _| {
            let names = carried(world);
            type_in_composer(world, "look")?;
            press_in_composer(world, "Enter")?;
            world.wait_for_with(
                |w| !first_message(w).is_null(),
                |w| format!("the message; the MC has {}", w.describe_commands()),
            )?;
            let sent = first_message(world)["attachments"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            expect!(
                sent.len() == 1
                    && sent[0]["name"] == json!(names.first())
                    && !text(&sent[0]["id"]).is_empty(),
                "the message carries {}",
                show(&Value::Array(sent))
            );
            Ok(())
        },
    );

    // A file's upload.
    steps.step(&format!("the upload of {Q} failed"), |world, c, _| {
        world.mc.part::<FakeFileUploads>().refuse =
            "The MC holding this upload is unavailable.".into();
        composer_brick(world)?;
        let file = plain_file(world, &c[0])?;
        drop_files(world, vec![file])?;
        wait_for_upload(world, &c[0], "failed")?;
        world.mc.part::<Typed>().text = c[0].clone();
        Ok(())
    });
    steps.step("the user tries to send the message", |world, _, _| {
        focus_input(world)?;
        type_in_composer(world, "Review this")?;
        press_in_composer(world, "Enter")?;
        Ok(())
    });
    steps.step(
        "the user is asked to retry or remove failed uploads before sending",
        |world, _, _| {
            expect!(
                told(world, "Retry or remove failed uploads before sending.", ""),
                "the toasts are {}",
                show(&Value::Array(toasts(world)))
            );
            let sent = commands_of(world, "message.dispatch")?;
            let (brick, field) = editor(world)?;
            expect!(
                sent.is_empty() && brick.text_of(world, field, "text") == "Review this",
                "the message went, or the draft was lost"
            );
            Ok(())
        },
    );
    steps.step(
        "the user retries the upload and it succeeds",
        |world, _, _| {
            let name = world.mc.part::<Typed>().text.clone();
            world.mc.part::<FakeFileUploads>().refuse.clear();
            let brick = composer_brick(world)?;
            let retry = composer_part(world, &format!("attachmentRetry:{name}"))?;
            let Some(retry) = retry.filter(|item| brick.flag(world, *item, "visible")) else {
                fail!("{name} offers no retry");
            };
            click(world, retry)?;
            wait_for_upload(world, &name, "")
        },
    );
    steps.step("the message can be sent", |world, _, _| {
        let name = world.mc.part::<Typed>().text.clone();
        focus_input(world)?;
        press_in_composer(world, "Enter")?;
        world.wait_for_with(
            |w| {
                w.mc.commands
                    .iter()
                    .any(|c| c["type"] == json!("message.dispatch"))
            },
            |w| {
                format!(
                    "the message; the toasts are {}",
                    show(&Value::Array(toasts(w)))
                )
            },
        )?;
        let sent = commands_of(world, "message.dispatch")?
            .last()
            .map(|command| command["attachments"].clone())
            .and_then(|list| list.as_array().cloned())
            .unwrap_or_default();
        let file = sent.first().cloned().unwrap_or(Value::Null);
        let kept = stored(world, &text(&file["id"]));
        expect!(
            sent.len() == 1 && file["type"] == json!("file") && file["name"] == json!(name) && kept,
            "the message carries {}; the MC stored {}",
            show(&Value::Array(sent)),
            world.mc.part::<FakeFileUploads>().stored.join(", ")
        );
        Ok(())
    });
    steps.step(
        "the draft carries a file that is still uploading",
        |world, _, _| {
            world.mc.hold("uploads");
            set_draft(world, "Read the schema")?;
            composer_brick(world)?;
            let file = plain_file(world, "schema.sql")?;
            drop_files(world, vec![file])?;
            wait_for_upload(world, "schema.sql", "uploading")
        },
    );
    steps.step(
        "the user is asked to wait for file uploads before stashing",
        |world, _, _| {
            expect!(
                told(
                    world,
                    "Wait for file uploads before stashing this prompt",
                    ""
                ),
                "the toasts are {}",
                show(&Value::Array(toasts(world)))
            );
            Ok(())
        },
    );
    steps.step("the draft is unchanged", |world, _, _| {
        let entries = world.state("composerStash")["entries"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        expect!(
            draft_text(world) == "Read the schema"
                && carried(world) == ["schema.sql"]
                && entries.is_empty(),
            "the draft reads \"{}\" with {}",
            draft_text(world),
            carried_text(world)
        );
        Ok(())
    });

    steps.step(
        "the user pastes a copied picture into the prompt with (\\S+)",
        |world, c, _| {
            composer_brick(world)?;
            let rgba = [255u8, 0, 0, 255].repeat(16);
            let _ = Platform::of(world.engine())
                .clipboard()
                .set_image(ClipboardImage {
                    width: 4,
                    height: 4,
                    rgba,
                });
            let took = press_in_composer(world, &c[0])?;
            expect!(took, "the composer did not take the paste");
            Ok(())
        },
    );

    // As a file manager copies a file: its address, and maybe some form of it as text.
    steps.step(
        &format!(
            "the user pastes {Q} copied with (no text|its path as text|its URL as text|its encoded URL as text) into the prompt"
        ),
        |world, c, _| {
            composer_brick(world)?;
            let path = plain_file(world, &c[0])?;
            let clipboard = Platform::of(world.engine()).clipboard();
            // Ljós's clipboard holds no URL list: what a file manager adds
            // beside the address is all that can be put on it.
            let copied = match c[1].as_str() {
                "its path as text" => path.display().to_string(),
                "its URL as text" => file_url(&path),
                "its encoded URL as text" => ljos::prelude::encoded_url(&file_url(&path)),
                _ => String::new(),
            };
            if copied.is_empty() {
                let _ = clipboard.clear(ClipboardMode::Clipboard);
            } else {
                let _ = clipboard.set_text(ClipboardMode::Clipboard, &copied);
            }
            let took = press_in_composer(world, "mod+v")?;
            expect!(took, "the composer did not take the paste");
            Ok(())
        },
    );

    // Large pastes.
    steps.step("the user pastes 40 KiB of log output", |world, _, _| {
        paste(world, false)
    });
    steps.step(
        "the user pastes 40 KiB of log output with Paste as Text",
        |world, _, _| paste(world, true),
    );
    steps.step(
        "the paste is attached as a text file instead of being inserted",
        |world, _, _| {
            wait_for_upload(world, "pasted-text.txt", "")?;
            let file = attachment(world, "pasted-text.txt");
            let asked = world
                .mc
                .part::<FakeFileUploads>()
                .asked
                .first()
                .cloned()
                .unwrap_or(Value::Null);
            let (brick, field) = editor(world)?;
            let typed = brick.text_of(world, field, "text");
            expect!(
                file["kind"] == json!("file")
                    && asked["sizeBytes"] == json!(40 * 1024)
                    && asked["mimeType"] == json!("text/plain")
                    && typed.is_empty(),
                "the draft carries {}, the MC was asked {}",
                show(&file),
                show(&asked)
            );
            Ok(())
        },
    );
    steps.step("the user is told the paste was attached", |world, _, _| {
        expect!(
            told(world, "Large paste attached as pasted-text.txt", ""),
            "the toasts are {}",
            show(&Value::Array(toasts(world)))
        );
        Ok(())
    });
    steps.step(
        "the user removes the attachment and pastes the log as plain text instead",
        |world, _, _| {
            let item = chip(world, "pasted-text.txt")?;
            click(world, item)?;
            world.sync()?;
            let deleted = world.mc.part::<FakeFileUploads>().deleted.clone();
            expect!(
                carried(world).is_empty() && deleted == ["pending-1"],
                "the draft carries {}; the MC dropped {}",
                carried_text(world),
                deleted.join(", ")
            );
            focus_input(world)?;
            paste(world, true)
        },
    );
    steps.step(
        "the text is inserted into the draft where it can be edited",
        |world, _, _| expect_inserted(world),
    );
    steps.step("nothing is attached", |world, _, _| {
        expect!(
            carried(world).is_empty() && world.mc.part::<FakeFileUploads>().asked.is_empty(),
            "the draft carries {}",
            carried_text(world)
        );
        Ok(())
    });

    // Folders.
    steps.step("the environment is (local|remote)", |world, c, _| {
        // Remote: the MC the shell is connected to runs on another machine.
        if c[0] == "remote" {
            world.served_from(OTHER_MACHINE)?;
        }
        let local = Bridge::of(world.engine()).local_folders(world.engine());
        expect!(local == (c[0] == "local"), "the shell's MC is not {}", c[0]);
        Ok(())
    });
    steps.step(
        &format!("the user drops the folder {Q} onto the composer"),
        |world, c, _| drop_folder(world, &c[0]),
    );
    steps.step(
        "the user drops a folder onto the composer",
        |world, _, _| drop_folder(world, "src/components"),
    );
    // Dragging over the conversation.
    steps.step(
        &format!("the user drags {Q} and the folder {Q} from the desktop over the conversation"),
        |world, c, _| {
            let dir = world.home_dir().join("checkout").join(&c[1]);
            std::fs::create_dir_all(&dir)
                .map_err(|e| Failure(format!("could not make {}: {e}", dir.display())))?;
            let files = vec![image_file(world, &c[0])?, dir];
            let at = over_conversation(world)?;
            drag_files(world, files, at)
        },
    );
    steps.step(
        &format!("the user is dragging {Q} over the conversation"),
        |world, c, _| {
            let files = vec![image_file(world, &c[0])?];
            let at = over_conversation(world)?;
            drag_files(world, files, at)?;
            expect!(
                drop_hint_shown(world)?,
                "the conversation does not offer the drop"
            );
            Ok(())
        },
    );
    steps.step("the user drops them there", |world, _, _| {
        let Dragged { files, at } = std::mem::take(world.part::<Dragged>());
        expect!(at.is_some(), "nothing is dragged");
        external_drag(world.engine(), &ExternalDrag::Dropped { files, at });
        world.sync()?;
        expect!(
            !drop_hint_shown(world)?,
            "the conversation still offers the drop"
        );
        Ok(())
    });
    steps.step(
        &format!("the draft carries {Q} and references the folder {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| carried(w) == [c[0].clone()],
                |w| {
                    format!(
                        "the draft to carry {}; it carries {}",
                        c[0],
                        carried_text(w)
                    )
                },
            )?;
            let item = chip(world, &c[0])?;
            expect!(visible(world, item)?, "{} is not shown", c[0]);
            settle_composer(world)?;
            let path = world.home_dir().join("checkout").join(&c[1]);
            let leaf = c[1].rsplit('/').next().unwrap_or("");
            let link = format!("[{leaf}]({})", path.display());
            let (brick, field) = editor(world)?;
            let typed = brick.text_of(world, field, "text");
            expect!(
                draft_text(world).contains(&link) && typed == draft_text(world),
                "the draft reads \"{}\"",
                draft_text(world)
            );
            Ok(())
        },
    );
    steps.step("the drag leaves the conversation", |world, _, _| {
        drag_leave(world)
    });
    steps.step(
        &format!("the conversation no longer says {Q}"),
        |world, c, _| {
            let brick = composer_brick(world)?;
            expect!(
                !drop_hint_shown(world)? && !brick.shows(world, &c[0])?,
                "the conversation still says \"{}\"",
                c[0]
            );
            Ok(())
        },
    );
    steps.step(
        "dragging selected text over the conversation never shows it",
        |world, _, _| {
            // Over the timeline, then over the composer.
            let at = over_conversation(world)?;
            drag_text(world, at)?;
            expect!(
                !drop_hint_shown(world)?,
                "the conversation offers to attach dragged text"
            );
            let (brick, field) = editor(world)?;
            let at = brick.at(world, field, 0.5, 0.5)?;
            drag_text(world, at)?;
            expect!(
                !drop_hint_shown(world)?,
                "the composer offers to attach dragged text"
            );
            let item = brick.item(world, "textDrag")?;
            brick.write(world, item, "dragging", QmlValue::from(false))?;
            world.sync()?;
            expect!(
                carried(world).is_empty(),
                "the draft carries {}",
                carried_text(world)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the draft references the folder {Q}"),
        |world, c, _| {
            settle_composer(world)?;
            let path = world.home_dir().join("checkout").join(&c[0]);
            let leaf = c[0].rsplit('/').next().unwrap_or("");
            let link = format!("[{leaf}]({})", path.display());
            let (brick, field) = editor(world)?;
            let typed = brick.text_of(world, field, "text");
            expect!(
                draft_text(world).contains(&link)
                    && carried(world).is_empty()
                    && typed == draft_text(world),
                "the draft reads \"{}\"",
                draft_text(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told folders cannot be dropped into remote environments",
        |world, _, _| {
            expect!(
                told(
                    world,
                    "Folders can't be dropped into remote environments",
                    ""
                ),
                "the toasts are {}",
                show(&Value::Array(toasts(world)))
            );
            expect!(
                draft_text(world).is_empty(),
                "the draft reads \"{}\"",
                draft_text(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told to type the folder path instead",
        |world, _, _| {
            expect!(
                told(
                    world,
                    "Folders can't be dropped into remote environments",
                    "Type the folder path with @ instead."
                ),
                "the toasts are {}",
                show(&Value::Array(toasts(world)))
            );
            Ok(())
        },
    );

    // Snap Shots on the draft.
    steps.step(
        &format!("the draft carries a Snap Shot of the {Q} window titled {Q}"),
        |world, c, _| snap_shot(world, json!({"appName": c[0], "windowTitle": c[1]})),
    );
    steps.step(
        "the draft carries a Snap Shot (with the window's accessibility text|with accessibility elements that have no names|without accessibility data)",
        |world, c, _| {
            let source = if c[0].starts_with("with the") {
                json!({"accessibleText": "Tests: 12 passed, 0 failed"})
            } else if c[0].starts_with("with accessibility") {
                let group = json!({"role": "group", "bounds": null, "children": []});
                json!({"accessibility": {
                    "format": "element-tree", "coordinateSpace": "captured-image",
                    "imageSize": {"width": 800, "height": 600}, "truncated": false,
                    "root": {"role": "window", "bounds": null, "children": [group, group]}}})
            } else {
                json!({})
            };
            snap_shot(world, source)
        },
    );
    steps.step("the user looks at the attachment", |world, _, _| {
        composer_brick(world)?;
        Ok(())
    });
    steps.step(
        &format!("it names the app {Q} and the window {Q}"),
        |world, c, _| {
            let item = chip(world, "window-terminal.png")?;
            let brick = composer_brick(world)?;
            let label = brick.text_of(world, item, "text");
            expect!(
                brick.flag(world, item, "visible") && label == format!("{} · {}", c[0], c[1]),
                "the attachment reads \"{label}\""
            );
            Ok(())
        },
    );
    steps.step(
        "the user opens the Snap Shot's accessibility data",
        |world, _, _| {
            let brick = composer_brick(world)?;
            let button = composer_part(world, "attachmentAccessibility:window-terminal.png")?;
            let Some(button) = button.filter(|item| brick.flag(world, *item, "visible")) else {
                fail!("the attachment offers no accessibility data");
            };
            click(world, button)?;
            let open = |w: &mut World| -> bool {
                match composer_part(w, "attachmentAccessibilityText") {
                    Ok(Some(item)) => brick.flag(w, item, "visible"),
                    _ => false,
                }
            };
            // The wait takes the world as it is polled.
            let mut seen = false;
            for _ in 0..200 {
                if open(world) {
                    seen = true;
                    break;
                }
                world.advance(25)?;
            }
            expect!(seen, "the accessibility data to open");
            Ok(())
        },
    );
    steps.step(
        "the user sees (the captured text|that the elements have no readable names or values|that the app did not provide accessibility data)",
        |world, c, _| {
            let wanted = match c[0].as_str() {
                "the captured text" => "Tests: 12 passed, 0 failed",
                "that the elements have no readable names or values" => {
                    "Structured accessibility elements were included, but they have no readable names or values."
                }
                _ => "The app or capture backend did not provide verified accessibility data.",
            };
            let brick = composer_brick(world)?;
            let Some(item) = composer_part(world, "attachmentAccessibilityText")? else {
                fail!("the composer shows no attachmentAccessibilityText");
            };
            let shown = brick.text_of(world, item, "text");
            expect!(shown == wanted, "the accessibility data reads \"{shown}\"");
            Ok(())
        },
    );

    // Answering the agent's question (question-answers.feature).
    steps.step(
        &format!("the user has a separate draft {Q}"),
        |world, c, _| set_draft(world, &c[0]),
    );
    steps.step(
        &format!("the user types {Q} and attaches {Q}"),
        |world, c, _| {
            type_answer(world, &c[0])?;
            // What the answer's file picker hands the question.
            let Some(requests) = composer_part(world, "turnRequests")? else {
                fail!("the composer shows no turnRequests");
            };
            let file = plain_file(world, &c[1])?;
            let urls = QmlValue::List(std::sync::Arc::new(vec![QmlValue::from(
                file_url(&file).as_str(),
            )]));
            world
                .engine()
                .invoke_by_name(requests, "attachTo", &[QmlValue::from("database"), urls])
                .map_err(|e| Failure(format!("attachTo: {e:?}")))?;
            world.wait_for_with(
                |w| {
                    let files = answer_files(w);
                    files.len() == 1 && text(&files[0]["status"]).is_empty()
                },
                |w| {
                    format!(
                        "{} to upload; the answer carries {}",
                        c[1],
                        show(&Value::Array(answer_files(w)))
                    )
                },
            )?;
            let shown = composer_part(world, &format!("attachment:{}", c[1]))?;
            let Some(shown) = shown.filter(|item| {
                composer_brick(world)
                    .map(|brick| brick.flag(world, *item, "visible"))
                    .unwrap_or(false)
            }) else {
                fail!("the answer does not show {}", c[1]);
            };
            let _ = shown;
            Ok(())
        },
    );
    steps.step("submits the answer", |world, _, _| submit(world));
    steps.step(
        &format!("the agent receives {Q} with {Q}"),
        |world, c, _| {
            let answers = commands_of(world, "runtime-request.respond")?;
            expect!(
                answers.len() == 1,
                "the MC has {}",
                world.describe_commands()
            );
            let files = answers[0]["attachmentsByQuestionId"]["database"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let file = files.first().cloned().unwrap_or(Value::Null);
            let kept = stored(world, &text(&file["id"]));
            expect!(
                answers[0]["answers"]["database"] == json!(c[0])
                    && files.len() == 1
                    && file["name"] == json!(c[1])
                    && file["type"] == json!("file")
                    && kept,
                "the agent received {}",
                show(&answers[0])
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the normal draft still reads {Q}"),
        |world, c, _| {
            let sent = commands_of(world, "message.dispatch")?;
            expect!(
                draft_text(world) == c[0] && carried(world).is_empty() && sent.is_empty(),
                "the draft reads \"{}\" with {}",
                draft_text(world),
                carried_text(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the question only allows its listed options",
        |world, _, _| {
            // The question as the agent asked it, again without a typed answer.
            let request = question(world);
            let mut asked = request["questions"][0].clone();
            asked["allowCustomAnswer"] = json!(false);
            if let Some(fields) = asked.as_object_mut() {
                fields.remove("attachments");
            }
            stream::set(
                world,
                "runtime-request",
                &text(&request["requestId"]),
                json!({"status": "resolved"}),
            )?;
            let id = "request-fixed";
            stream::set(
                world,
                "runtime-request",
                id,
                json!({"id": id, "status": "pending", "responseCapability": {"type": "live"}}),
            )?;
            stream::add_item(
                world,
                "user_input_request",
                json!({"requestId": id, "status": "waiting", "questions": [asked]}),
            )?;
            world.wait_for("the composer to see the question", |w| {
                composer_state(w)["editorDisabled"] == json!(true)
            })
        },
    );
    steps.step("the user tries to attach a file", |world, _, _| {
        composer_brick(world)?;
        let file = plain_file(world, "schema.sql")?;
        drop_files(world, vec![file])
    });
    steps.step(
        "the user is told this question cannot accept attachments",
        |world, _, _| {
            expect!(
                told(world, "This question cannot accept attachments.", ""),
                "the toasts are {}",
                show(&Value::Array(toasts(world)))
            );
            expect!(
                carried(world).is_empty() && world.mc.part::<FakeFileUploads>().asked.is_empty(),
                "the file was taken"
            );
            Ok(())
        },
    );
    steps.step(&format!("the user typed {Q}"), |world, c, _| {
        type_answer(world, &c[0])
    });
    steps.step("submitting the answer fails", |world, _, _| {
        world
            .mc
            .refusals
            .insert("runtime-request.respond".into(), "connection closed".into());
        submit(world)
    });
    steps.step(&format!("the answer still reads {Q}"), |world, c, _| {
        world.wait_for_with(
            |w| told(w, "Failed to submit answers.", ""),
            |w| {
                format!(
                    "the failure; the toasts are {}",
                    show(&Value::Array(toasts(w)))
                )
            },
        )?;
        let brick = composer_brick(world)?;
        let field = answer_field(world)?;
        let read = brick.text_of(world, field, "text");
        expect!(read == c[0], "the answer reads \"{read}\"");
        // And can be sent again.
        let Some(button) = composer_part(world, "questionSubmit")? else {
            fail!("the composer shows no questionSubmit");
        };
        world.wait_for("the answer to be offered again", |w| {
            brick.flag(w, button, "enabled")
        })
    });

    steps.step("the draft carries no attachments", |world, _, _| {
        expect!(
            carried(world).is_empty(),
            "the draft carries {}",
            carried_text(world)
        );
        Ok(())
    });
    steps.step("the typed text is unchanged", |world, _, _| {
        settle_composer(world)?;
        let typed = composer::draft(world.engine(), &thread_target(world));
        let (brick, field) = editor(world)?;
        let shown = brick.text_of(world, field, "text");
        expect!(
            !typed.is_empty() && typed == world.mc.part::<Typed>().text && shown == typed,
            "the draft reads \"{typed}\""
        );
        Ok(())
    });
}

/// "the conversation says X" while something is dragged over the
/// composer's conversation: checks that its drop hint says X and returns
/// true. False leaves the step to its own domain (the worktree setup card).
pub fn conversation_drop_says(world: &mut World, text: &str) -> Outcome<bool> {
    if !composer_brick_shown(world)
        || world
            .peek_part::<Dragged>()
            .is_none_or(|dragged| dragged.at.is_none())
    {
        return Ok(false);
    }
    let brick = composer_brick(world)?;
    world.wait_for(&format!("the conversation to say \"{text}\""), move |w| {
        matches!(brick.find_visible(w, "conversationDropHint"), Ok(Some(_)))
            && matches!(brick.shows(w, text), Ok(true))
    })?;
    Ok(true)
}

/// Takes `name` off the composer's draft by its chip, remembering the text.
pub fn remove_composer_attachment(world: &mut World, name: &str) -> Outcome<bool> {
    if !composer_brick_shown(world) || !carried(world).iter().any(|entry| entry == name) {
        return Ok(false);
    }
    settle_composer(world)?;
    let kept = composer::draft(world.engine(), &thread_target(world));
    world.mc.part::<Typed>().text = kept;
    let item = chip(world, name)?;
    click(world, item)?;
    world.sync()?;
    Ok(true)
}
