//! The composer's turn against the MC: the route the composer shows, what
//! the user types, picks, attaches and sends (as the brick dispatches it),
//! the images the MC stores, the text the shell's composer holds, and what
//! became of a send the app quit on (desktop-qt's ComposerSteps.cpp,
//! features/composer/sending-turns.feature, desktop/native-composer.feature).

use std::io::Cursor;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use hal_c2_shell::controllers::composer;
use hal_c2_shell::controllers::drafts;
use hal_c2_shell::controllers::navigation::Navigation;
use serde_json::{Value, json};

use crate::fake_mc::FakeMc;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::settings::{fake_config, publish_providers};
use crate::steps::stream::{self, FakeStreams};
use crate::world::World;
use crate::{expect, fail};

/// The chat images the MC stored (`assets.persistChatAttachments`); refused
/// like a command, by `the MC refuses "assets.persistChatAttachments" ...`.
#[derive(Default)]
struct FakeUploads {
    stored: Vec<Value>,
}

fn extension(mc: &mut FakeMc) {
    mc.on_rpc("assets.persistChatAttachments", |mc, rpc| {
        let method = "assets.persistChatAttachments";
        if let Some(refusal) = mc.refusals.get(method).cloned() {
            mc.refuse(rpc, &refusal);
            return Ok(());
        }
        let mut stored = Vec::new();
        for value in rpc.payload["attachments"].as_array().into_iter().flatten() {
            let mut image = value.clone();
            image["threadId"] = rpc.payload["threadId"].clone();
            mc.part::<FakeUploads>().stored.push(image.clone());
            let number = mc.part::<FakeUploads>().stored.len();
            if let Some(fields) = image.as_object_mut() {
                fields.remove("threadId");
                fields.remove("dataUrl");
            }
            image["id"] = json!(format!("image-{number}"));
            stored.push(image);
        }
        mc.reply(rpc, json!({"attachments": stored}));
        Ok(())
    });
}

/// The text the shell's composer keeps for the thread or draft.
fn text_of(world: &World, target: &str) -> String {
    composer::draft(world.engine(), target)
}

/// What the composer brick is shown.
fn shown(world: &World) -> Value {
    world.state("composer")
}

fn route(world: &World) -> String {
    world
        .with::<Navigation, _>(|n, _| n.thread_key().to_owned())
        .unwrap_or_default()
}

fn edit(world: &mut World) -> Value {
    let revision = world.next_edit;
    world.next_edit += 1;
    json!({"clientId": "qml", "revision": revision})
}

fn attachments(world: &World) -> Vec<Value> {
    shown(world)["attachments"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn attachment_names(world: &World) -> Vec<String> {
    attachments(world)
        .iter()
        .map(|attachment| text(&attachment["name"]))
        .collect()
}

/// A user message in the stream of `thread`, as the MC's projection keeps
/// it; only the MC's copy changes while no app is connected.
fn add_user_message(world: &mut World, thread: &str, id: &str, message: &str) -> Outcome {
    let current = std::mem::replace(
        &mut world.mc.part::<FakeStreams>().thread,
        thread.to_owned(),
    );
    let quiet = !world.mc.connected();
    let created = stream::iso(world.now());
    let done = stream::change_quietly(
        world,
        "message",
        id,
        json!({"s": {"id": id, "role": "user", "createdBy": "user", "text": message,
                     "createdAt": created}}),
        quiet,
    );
    world.mc.part::<FakeStreams>().thread = current;
    done
}

/// The messages a carried-out send made, for the world to apply once the MC
/// has answered (an effect runs inside the fake MC, which has no world).
#[derive(Default)]
struct Carried {
    messages: Vec<(String, String, String)>,
}

fn picture() -> Vec<u8> {
    let image = image::RgbImage::from_pixel(400, 200, image::Rgb([0, 139, 139]));
    let mut png = Cursor::new(Vec::new());
    image
        .write_to(&mut png, image::ImageFormat::Png)
        .expect("a picture encodes");
    png.into_inner()
}

fn stored_names(world: &mut World) -> Vec<String> {
    world
        .mc
        .part::<FakeUploads>()
        .stored
        .iter()
        .map(|image| text(&image["name"]))
        .collect()
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // The composer.
    steps.step(&format!("the composer shows {Q}"), |world, c, _| {
        world.dispatch("thread.open", json!({"key": c[0]}))
    });
    // The thread open and its stream live, so the shell knows its messages.
    steps.step(&format!("the user is reading {Q}"), |world, c, _| {
        stream::look(world, &c[0], true)
    });
    steps.step("the user stops the turn", |world, _, _| {
        world.dispatch("composer.interrupt", json!({}))
    });
    steps.step(&format!("the user sends {Q}"), |world, c, _| {
        let edit = edit(world);
        world.dispatch(
            "composer.submit",
            json!({"edit": edit, "text": c[0], "intent": "foreground"}),
        )
    });
    steps.step(
        &format!("the user sends the opposite way {Q}"),
        |world, c, _| {
            let edit = edit(world);
            world.dispatch(
                "composer.submit",
                json!({"edit": edit, "text": c[0], "intent": "alternate"}),
            )
        },
    );
    steps.step(
        &format!("the user types {Q} into the composer"),
        |world, c, _| {
            let (target, edit) = (route(world), edit(world));
            world.dispatch(
                "composer.text.set",
                json!({"target": target, "edit": edit, "text": c[0],
                       "cursor": c[0].chars().count()}),
            )
        },
    );
    steps.step(
        &format!("the user picks the model {Q} of {Q}"),
        |world, c, _| {
            // The picker offers what the MC's providers list.
            let offered = fake_config(&mut world.mc)
                .config
                .get("providers")
                .and_then(Value::as_array)
                .is_some_and(|list| list.iter().any(|entry| entry["instanceId"] == json!(c[1])));
            if !offered {
                publish_providers(
                    &mut world.mc,
                    vec![json!({"instanceId": c[1], "driver": c[1], "enabled": true,
                                "status": "ready", "models": [{"slug": c[0]}]})],
                );
                world.sync()?;
            }
            world.dispatch(
                "composer.model.select",
                json!({"instanceId": c[1], "model": c[0]}),
            )
        },
    );
    steps.step(
        &format!("the user switches to the {Q} and {Q} modes"),
        |world, c, _| {
            world.dispatch("composer.runtimeMode.set", json!({"mode": c[0]}))?;
            world.dispatch("composer.interactionMode.set", json!({"mode": c[1]}))
        },
    );
    steps.step(
        &format!("the composer offers the draft {Q}"),
        |world, c, _| {
            let composer = shown(world);
            expect!(
                composer["target"] == json!(route(world)) && composer["text"] == json!(c[0]),
                "the composer shows {}",
                show(&composer)
            );
            Ok(())
        },
    );

    steps.step(&format!("the suggestion list says {Q}"), |world, c, _| {
        world.wait_for_with(
            |w| shown(w)["suggestionsEmptyText"] == json!(c[0]),
            |w| {
                format!(
                    "the suggestion list to say \"{}\"; the composer shows {}",
                    c[0],
                    show(&shown(w))
                )
            },
        )
    });

    steps.step(&format!("the composer is in {Q} mode"), |world, c, _| {
        world.wait_for_with(
            |w| shown(w)["interactionMode"] == json!(c[0]),
            |w| format!("the mode; the composer shows {}", show(&shown(w))),
        )
    });

    // A new thread's draft (DraftSteps names it).
    steps.step(
        &format!("the user types {Q} into the new thread"),
        |world, c, _| {
            let (target, edit) = (world.draft_id.clone(), edit(world));
            world.dispatch(
                "composer.text.set",
                json!({"target": target, "edit": edit, "text": c[0],
                       "cursor": c[0].chars().count()}),
            )
        },
    );
    steps.step("the user goes back to the new thread", |world, _, _| {
        let id = world.draft_id.clone();
        world.dispatch("draft.open", json!({"draftId": id}))
    });
    steps.step(
        &format!("the composer offers the new thread's text {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| shown(w)["target"] == json!(w.draft_id) && shown(w)["text"] == json!(c[0]),
                |w| format!("the draft's text; the composer shows {}", show(&shown(w))),
            )
        },
    );

    // Images.
    steps.step(
        &format!("the user attaches the image {Q}"),
        |world, c, _| {
            world.dispatch(
                "composer.attach",
                json!({"files": [{"name": c[0], "mimeType": "image/png",
                                  "base64": STANDARD.encode(picture())}]}),
            )
        },
    );
    steps.step(
        &format!("the composer shows a thumbnail of {Q}"),
        |world, c, _| {
            // The thumbnail is made off the Engine thread and publishes when
            // it arrives; the check below judges what it came to.
            let name = json!(c[0]);
            let _ = world.wait_for("the thumbnail to be made", |w| {
                attachments(w)
                    .iter()
                    .any(|a| a["name"] == name && !text(&a["preview"]).is_empty())
            });
            for attachment in attachments(world) {
                if attachment["name"] != json!(c[0]) {
                    continue;
                }
                let preview = text(&attachment["preview"]);
                let data = preview.split_once(',').map_or("", |(_, data)| data);
                let size = STANDARD
                    .decode(data)
                    .ok()
                    .and_then(|bytes| image::load_from_memory(&bytes).ok())
                    .map_or((0, 0), |thumbnail| {
                        (
                            image::GenericImageView::width(&thumbnail),
                            image::GenericImageView::height(&thumbnail),
                        )
                    });
                // The middle square of the 400x200 picture, scaled down.
                expect!(
                    preview.starts_with("data:image/png;base64,") && size == (128, 128),
                    "the thumbnail is {}x{}",
                    size.0,
                    size.1
                );
                return Ok(());
            }
            fail!(
                "the composer lists {}",
                show(&Value::Array(attachments(world)))
            )
        },
    );
    steps.step(
        &format!("the user removes the attachment {Q}"),
        |world, c, _| {
            for attachment in attachments(world) {
                if attachment["name"] == json!(c[0]) {
                    return world.dispatch(
                        "composer.attachment.remove",
                        json!({"id": attachment["id"]}),
                    );
                }
            }
            fail!(
                "the composer lists {}",
                show(&Value::Array(attachments(world)))
            )
        },
    );
    steps.step(
        &format!("the composer lists the attachment {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| attachment_names(w) == [c[0].clone()],
                |w| {
                    format!(
                        "the attachment; the composer lists {}",
                        show(&Value::Array(attachments(w)))
                    )
                },
            )
        },
    );
    steps.step("the composer lists no attachments", |world, _, _| {
        expect!(
            attachments(world).is_empty(),
            "the composer lists {}",
            show(&Value::Array(attachments(world)))
        );
        Ok(())
    });
    steps.step(
        &format!("the MC stores the image {Q} for {Q}"),
        |world, c, _| {
            world.sync()?;
            let stored = world.mc.part::<FakeUploads>().stored.clone();
            let found = stored.iter().any(|image| {
                image["name"] == json!(c[0])
                    && text(&image["dataUrl"]).starts_with("data:image/png;base64,")
            });
            expect!(found, "the MC stored [{}]", stored_names(world).join(", "));
            Ok(())
        },
    );
    steps.step(
        &format!("the MC stores the image {Q} for the draft's thread"),
        |world, c, _| {
            // The draft's thread id, or once it launched, the thread the window moved to.
            let draft = drafts::draft(world.engine(), &world.draft_id);
            world.wait_for("an image stored", |w| {
                !w.mc
                    .peek::<FakeUploads>()
                    .is_none_or(|u| u.stored.is_empty())
            })?;
            let thread_id = draft.map_or_else(
                || {
                    route(world)
                        .split_once(':')
                        .map_or(String::new(), |(_, id)| id.to_owned())
                },
                |draft| draft.thread_id,
            );
            let stored = world.mc.part::<FakeUploads>().stored.clone();
            let found = stored
                .iter()
                .any(|image| image["name"] == json!(c[0]) && image["threadId"] == json!(thread_id));
            let seen: Vec<String> = stored
                .iter()
                .map(|image| format!("{} for {}", text(&image["name"]), text(&image["threadId"])))
                .collect();
            expect!(
                found && !thread_id.is_empty(),
                "the MC stored [{}], not for {thread_id}",
                seen.join(", ")
            );
            Ok(())
        },
    );
    steps.step("the MC stores no images", |world, _, _| {
        world.sync()?;
        expect!(
            world.mc.part::<FakeUploads>().stored.is_empty(),
            "the MC stored images"
        );
        Ok(())
    });
    steps.step(
        &format!("the message carries the image {Q}"),
        |world, c, _| {
            let Some(index) = world.command else {
                fail!("no command was found before");
            };
            let images = world.mc.commands[index]["attachments"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let found = images
                .iter()
                .any(|image| image["name"] == json!(c[0]) && !text(&image["id"]).is_empty());
            expect!(found, "the message carries {}", show(&Value::Array(images)));
            Ok(())
        },
    );

    // A send the MC still held when the app quit: it carries it out (its message
    // is in the thread), or drops it as if it never arrived.
    steps.step("the MC carries out the send", |world, _, _| {
        world.mc.effects.push(std::rc::Rc::new(|mc, command| {
            if command["type"] != json!("message.dispatch") {
                return;
            }
            mc.part::<Carried>().messages.push((
                text(&command["threadId"]),
                text(&command["messageId"]),
                text(&command["text"]),
            ));
        }));
        world.mc.answer_held();
        world.mc.effects.pop();
        let carried = std::mem::take(&mut world.mc.part::<Carried>().messages);
        for (thread, id, message) in carried {
            add_user_message(world, &thread, &id, &message)?;
        }
        Ok(())
    });
    steps.step("the MC drops the send", |world, _, _| {
        world.mc.drop_held();
        Ok(())
    });
    // Settled, not left waiting: shell-composer.json keeps no send to reconcile.
    steps.step("the desktop keeps no unsent prompts", |world, _, _| {
        let path = world.home_dir().join("data/shell-composer.json");
        let unsent = move || -> Vec<Value> {
            std::fs::read(&path)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                .and_then(|kept| kept["unsent"].as_array().cloned())
                .unwrap_or_default()
        };
        world.wait_for_with(
            |_| unsent().is_empty(),
            |_| {
                format!(
                    "no unsent prompts; the desktop keeps {}",
                    show(&Value::Array(unsent()))
                )
            },
        )
    });
    steps.step(
        &format!("the thread {Q} gets the user message {Q} from another device"),
        |world, c, _| add_user_message(world, &c[0], &format!("message-{}", c[1]), &c[1]),
    );

    // The text the composer keeps.
    steps.step(
        &format!("the composer's text for {Q} is {Q}"),
        |world, c, _| {
            world.wait_for_with(
                |w| text_of(w, &c[0]) == c[1],
                |w| {
                    format!(
                        "the composer's text; it is {}",
                        show(&json!(text_of(w, &c[0])))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the composer's text for {Q} is the prompts:"),
        |world, c, table| {
            let prompts: Vec<&str> = table
                .iter()
                .skip(1)
                .map(|row| row.first().map_or("", String::as_str))
                .collect();
            let wanted = prompts.join("\n\n");
            world.wait_for_with(
                |w| text_of(w, &c[0]) == wanted,
                |w| {
                    format!(
                        "the composer's text; it is {}",
                        show(&json!(text_of(w, &c[0])))
                    )
                },
            )
        },
    );
}
