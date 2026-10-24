//! Editing from one of the user's messages (desktop-qt's
//! CheckpointEditSteps.cpp; RewindController,
//! features/timeline/checkpoints.feature): the thread is the "three finished
//! turns", whose second message here has a prompt of its own and an image
//! the MC serves (`assets.createUrl`, then a GET of the signed URL). Driven
//! from the message's own button on the ThreadView brick and the "Edit from
//! here?" dialog.
//!
//! The Background step "a thread in ... with three finished turns" is
//! PanelSteps'.

use std::io::Write;

use hal_c2_shell::controllers::composer;
use serde_json::{Map, Value, json};

use super::settings::publish_providers;
use super::stream::{THREAD, describe, read, role, set};
use crate::brick::{Brick, shown};
use crate::harness::{Failure, Outcome, Q, Steps, show};
use crate::world::World;
use crate::{expect, fail};

const PROMPT: &str = "check the tax rate";
const IMAGE: &[u8] = b"\x89PNG\r\n\x1a\ncart";

/// What the MC was asked for while rewinding.
#[derive(Default)]
struct FakeRewind {
    /// The paths of the attachment bytes it served.
    downloaded: Vec<String>,
    prepared: bool,
    /// The second message's row.
    second: String,
}

/// The row of the user's second message.
fn second(world: &mut World) -> Outcome<String> {
    let known = world.mc.part::<FakeRewind>().second.clone();
    if !known.is_empty() {
        return Ok(known);
    }
    let rows = read(world, |t| t.row_count())?;
    let mine: Vec<String> = (0..rows)
        .filter(|&row| {
            role(world, row, "kind") == json!("message")
                && role(world, row, "author") == json!("user")
        })
        .map(|row| crate::harness::text(&role(world, row, "rowId")))
        .collect();
    expect!(
        mine.len() >= 3,
        "the thread has {} messages of the user's; {}",
        mine.len(),
        describe(world)
    );
    world.mc.part::<FakeRewind>().second = mine[1].clone();
    Ok(mine[1].clone())
}

fn thread_key(world: &World) -> String {
    format!("{}:{THREAD}", world.mc.environment_id)
}

fn draft(world: &World) -> String {
    composer::draft(world.engine(), &thread_key(world))
}

fn attachments(world: &World) -> Vec<Value> {
    composer::attachments(world.engine(), &thread_key(world))
}

/// The second message as the user sent it: its prompt and one image, which
/// the MC still holds.
fn prepare(world: &mut World) -> Outcome {
    if world.mc.part::<FakeRewind>().prepared {
        return Ok(());
    }
    world.mc.part::<FakeRewind>().prepared = true;
    let id = second(world)?;
    set(
        world,
        "turn-item",
        &id,
        json!({
            "text": PROMPT,
            "attachments": [{"type": "image", "id": "att-1", "name": "cart.png",
                             "mimeType": "image/png", "sizeBytes": IMAGE.len()}],
        }),
    )?;
    world.mc.on_rpc("assets.createUrl", |mc, rpc| {
        let id = crate::harness::text(&rpc.payload["resource"]["attachmentId"]);
        mc.reply(
            rpc,
            json!({"relativeUrl": format!("/assets/{id}?signature=abc"),
                   "expiresAt": 1790000000000.0_f64}),
        );
        Ok(())
    });
    world.mc.on_raw("/assets/", |mc, mut stream, head| {
        let path = head
            .lines()
            .next()
            .and_then(|line| line.split(' ').nth(1))
            .unwrap_or("");
        mc.part::<FakeRewind>().downloaded.push(path.to_owned());
        let _ = write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
            IMAGE.len()
        );
        let _ = stream.write_all(IMAGE);
        let _ = stream.flush();
        let _ = stream.shutdown(std::net::Shutdown::Both);
        Ok(())
    });
    Ok(())
}

/// The open thread with the dialog that asks before rewinding.
fn view(world: &mut World) -> Outcome<Brick> {
    if let Ok(brick) = shown(world) {
        return Ok(brick);
    }
    Brick::show(
        world,
        "import QtQuick\nimport HalC2.Bricks\nItem { anchors.fill: parent\n ThreadView { anchors.fill: parent }\n EditFromHereDialog {} }\n",
        820.0,
        1000.0,
    )?;
    shown(world)
}

/// The second message's own "Edit from here".
/// Hovers the second message, then clicks its "Edit from here" as the user
/// does (the actions fade in over the message the pointer is on).
///
/// The click does not reach `rewind.request` yet: the Timeline's IconButton
/// calls `button.clicked()` from `TapHandler.onTapped`, and Ljós hands the
/// handler its `button` parameter in place of the `id: button`
/// (TODO(ljos#104)). The scenarios that edit from a message fail here until
/// Ljós resolves the id.
fn edit_from_second(world: &mut World) -> Outcome {
    prepare(world)?;
    let brick = view(world)?;
    world.wait_for("the second message to be drawn", |w| {
        matches!(
            brick.find_holding(w, "userMessageBody", PROMPT),
            Ok(Some(_))
        )
    })?;
    let Some(body) = brick.find_holding(world, "userMessageBody", PROMPT)? else {
        fail!("the second message went away");
    };
    let (x, y) = brick.at(world, body, 0.5, 0.5)?;
    world.hover_at(x, y + 4.0)?;
    world.hover_at(x, y)?;
    world.wait_for("the message to offer Edit from here", |w| {
        matches!(brick.visible_beside(w, body, "editFromHere"), Ok(Some(_)))
    })?;
    let Some(button) = brick.visible_beside(world, body, "editFromHere")? else {
        fail!("the message withdrew Edit from here");
    };
    world.advance(300)?;
    let (x, y) = brick.at(world, button, 0.5, 0.5)?;
    world.click_at(x, y)?;
    world.sync()?;
    Ok(())
}

fn rollbacks(world: &World) -> Vec<Value> {
    world
        .mc
        .commands
        .iter()
        .filter(|command| command["type"] == "checkpoint.rollback")
        .cloned()
        .collect()
}

fn answers(world: &World) -> Vec<String> {
    let rows = read(world, |t| t.row_count()).unwrap_or(0);
    (0..rows)
        .map(|row| crate::harness::text(&role(world, row, "text")))
        .filter(|text| text.starts_with("Answer "))
        .collect()
}

/// Answers "Cancel" to the question of a rewind, as the scenarios of other
/// domains do; false when none was asked.
pub fn cancel_rewind_question(world: &mut World) -> Outcome<bool> {
    if world.state("rewind").is_null() {
        return Ok(false);
    }
    let brick = view(world)?;
    brick.click(world, "editFromHereCancel")?;
    world.sync()?;
    Ok(true)
}

pub fn register(steps: &mut Steps) {
    // Why a rewind cannot happen.
    steps.step("the provider cannot rewind its history", |world, _, _| {
        let row = world
            .mc
            .threads
            .get_mut(THREAD)
            .ok_or_else(|| Failure(format!("the MC has no thread {THREAD}")))?;
        row["modelSelection"] = json!({"instanceId": "opencode", "model": "big-pickle"});
        let row = row.clone();
        world.mc.send_row(THREAD, &row);
        publish_providers(
            &mut world.mc,
            vec![json!({
                "instanceId": "opencode", "driver": "opencode", "status": "ready",
                "models": [], "supportsConversationRollback": false,
            })],
        );
        world.sync()
    });
    steps.step(
        &format!("the composer holds the draft {Q}"),
        |world, c, _| {
            let key = thread_key(world);
            world.dispatch(
                "composer.text.set",
                json!({"target": key, "text": c[0], "cursor": c[0].encode_utf16().count()}),
            )?;
            expect!(draft(world) == c[0], "the draft reads \"{}\"", draft(world));
            Ok(())
        },
    );
    steps.step(
        "the user edits from the second message and reverts the files too",
        |world, _, _| {
            edit_from_second(world)?;
            let brick = view(world)?;
            world.wait_for("the question of a rewind", |w| {
                brick.shows(w, "Edit from here?").unwrap_or(false)
            })?;
            expect!(
                rollbacks(world).is_empty(),
                "the thread was rewound before the user answered"
            );
            brick.click(world, "editFromHereRevertFiles")
        },
    );
    steps.step(
        "the conversation rewinds to before the second message",
        |world, _, _| {
            world.wait_for_with(
                |w| rollbacks(w).len() == 1,
                |w| {
                    format!(
                        "the rollback; the MC has {}; the shell shows {}",
                        w.describe_commands(),
                        show(&w.state("toasts"))
                    )
                },
            )?;
            let rollback = rollbacks(world).remove(0);
            expect!(
                rollback["threadId"] == THREAD
                    && rollback["checkpointId"] == "cp-1"
                    && rollback["scopeId"] == "scope-1"
                    && rollback["restoreFiles"] == true,
                "the rollback was {}",
                show(&rollback)
            );
            // Turn 1 stays; the second message and what followed are gone.
            world.wait_for_with(|w| answers(w) == ["Answer 1"], describe)?;
            let id = second(world)?;
            expect!(
                read(world, |t| t.index_of(&id))?.is_none(),
                "the second message is still shown"
            );
            Ok(())
        },
    );
    steps.step(
        "the second message's prompt and attachments are added to the draft",
        |world, _, _| {
            let wanted = format!("also check tax\n\n{PROMPT}");
            world.wait_for_with(
                |w| draft(w) == wanted && attachments(w).len() == 1,
                |w| {
                    format!(
                        "the draft reads \"{}\" with {} attachments",
                        draft(w),
                        attachments(w).len()
                    )
                },
            )?;
            let image = attachments(world).remove(0);
            expect!(
                image["name"] == "cart.png"
                    && image["mimeType"] == "image/png"
                    && image["sizeBytes"] == IMAGE.len(),
                "the draft carries {}",
                show(&image)
            );
            // Read from the MC by the address it signed.
            let downloaded = world.mc.part::<FakeRewind>().downloaded.clone();
            expect!(
                downloaded == ["/assets/att-1?signature=abc"],
                "the MC served {}",
                downloaded.join(", ")
            );
            Ok(())
        },
    );

    steps.step(
        "the user starts editing from the second message",
        |world, _, _| {
            edit_from_second(world)?;
            let brick = view(world)?;
            world.wait_for("the question to be asked", |w| {
                brick.shows(w, "Edit from here?").unwrap_or(false)
            })
        },
    );
    steps.step(
        "the conversation and the workspace are unchanged",
        |world, _, _| {
            world.sync()?;
            expect!(
                world.state("rewind").is_null() && rollbacks(world).is_empty(),
                "the MC has {}",
                world.describe_commands()
            );
            let id = second(world)?;
            expect!(
                answers(world).len() == 3 && read(world, |t| t.index_of(&id))?.is_some(),
                "{}",
                describe(world)
            );
            expect!(
                draft(world).is_empty() && world.mc.part::<FakeRewind>().downloaded.is_empty(),
                "the draft or the attachments were touched"
            );
            Ok(())
        },
    );

    // Why a rewind cannot happen.
    steps.step(
        "the message's attachments are still preparing",
        |world, _, _| {
            // A message with an image is on its way: the MC has not answered
            // for its upload yet.
            world.mc.hold("answers");
            world.mc.on_rpc("assets.persistChatAttachments", |mc, rpc| {
                let rpc = rpc.clone();
                mc.defer(move |mc| mc.reply(&rpc, json!({"attachments": []})));
                Ok(())
            });
            let key = thread_key(world);
            composer::attach_image(
                world.engine(),
                &key,
                "receipt.png",
                "image/png",
                IMAGE,
                Map::new(),
            );
            world.dispatch(
                "composer.submit",
                json!({"text": "and this receipt", "intent": "foreground"}),
            )?;
            expect!(
                composer::attachments_pending(world.engine(), &key),
                "no attachment is on its way"
            );
            Ok(())
        },
    );
    steps.step(
        "the composer has no room for the attachments",
        |world, _, _| {
            let key = thread_key(world);
            for n in 0..100 {
                composer::attach_image(
                    world.engine(),
                    &key,
                    &format!("shot-{n}.png"),
                    "image/png",
                    IMAGE,
                    Map::new(),
                );
            }
            world.pump()?;
            expect!(
                attachments(world).len() == 100,
                "the draft carries {} attachments",
                attachments(world).len()
            );
            Ok(())
        },
    );
    steps.step("the user edits from the second message", |world, _, _| {
        edit_from_second(world)?;
        // Asked, the user keeps the files as they are.
        if !world.state("rewind").is_null() {
            let brick = view(world)?;
            world.wait_for("the question to be asked", |w| {
                matches!(brick.find(w, "editFromHereKeepFiles"), Ok(Some(item)) if brick.flag(w, item, "visible"))
            })?;
            brick.click(world, "editFromHereKeepFiles")?;
            world.sync()?;
        }
        // Refused, nothing was rewound.
        expect!(
            rollbacks(world).is_empty(),
            "the thread was rewound: {}",
            world.describe_commands()
        );
        Ok(())
    });
}
