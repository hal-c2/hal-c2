//! What a row of the thread list does besides opening: telling the MC a
//! thread was read, the preview on hover, the jump keys while the modifier is
//! held, and files dropped on it (features/threads/unread-and-status.feature,
//! threads/sidebar-list.feature, threads/pinning-and-order.feature).
//! desktop-qt's ThreadRowSteps.cpp.

use chrono::Duration;
use hal_c2_shell::attachment_files;
use hal_c2_shell::controllers::composer;
use hal_c2_shell::controllers::keybindings::Keymap;
use serde_json::{Value, json};

use super::stream::iso;
use super::thread_menu::{id_in, key_of, update_row};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

#[derive(Default)]
struct RowScene {
    subject: String,
}

fn rows(world: &World) -> Vec<Value> {
    let sidebar = world.state("sidebar");
    ["pinned", "active", "snoozed", "settled"]
        .into_iter()
        .flat_map(|section| sidebar[section].as_array().cloned().unwrap_or_default())
        .collect()
}

fn row_of(world: &World, key: &str) -> Value {
    rows(world)
        .into_iter()
        .find(|row| text(&row["key"]) == key)
        .unwrap_or(Value::Null)
}

fn toasts(world: &World) -> Vec<Value> {
    world.state("toasts")["items"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|item| text(&item["title"]) == "Your threads were brought over")
        .collect()
}

/// Whether the first row carries a jump label (a string, not null).
fn first_labelled(world: &World) -> bool {
    rows(world)
        .first()
        .is_some_and(|row| row["jumpLabel"].is_string())
}

fn hold_jump_modifier(world: &mut World, held: bool) -> Outcome {
    let engine = world.engine().clone();
    Keymap::of(&engine).set_jump_modifier_held(&engine, held);
    world.pump()
}

pub fn register(steps: &mut Steps) {
    steps.step(
        &format!("the environment is told {Q} was seen up to its latest work"),
        |world, c, _| {
            let id = id_in(&key_of(world, &c[0])?).to_owned();
            let updated_at = text(&world.mc.threads[&id]["updatedAt"]);
            let (wanted, at) = (id.clone(), updated_at.clone());
            world.wait_for_with(
                move |w| {
                    w.mc.commands.iter().any(|command| {
                        text(&command["type"]) == "thread.visit"
                            && text(&command["threadId"]) == wanted
                            && text(&command["visitedAt"]) == at
                    })
                },
                move |w| {
                    format!(
                        "a visit up to {updated_at}; the MC has {}",
                        w.describe_commands()
                    )
                },
            )
        },
    );

    // Threads from the first version.
    steps.step(
        "threads were migrated from the first version",
        |world, _, _| {
            for title in ["Legacy work", "Older legacy work"] {
                let id = format!("t-{}", title.to_lowercase().replace(' ', "-"));
                world.mc.threads.insert(
                    id.clone(),
                    json!({"id": id, "title": title, "projectId": "legacy",
                       "historyOrigin": "v1_import",
                       "createdAt": "2026-09-01T09:00:00Z", "updatedAt": "2026-09-01T09:00:00Z"}),
                );
            }
            world.connect()
        },
    );
    steps.step(
        "the user is told the threads were brought over",
        |world, _, _| {
            world.wait_for_with(
                |w| !toasts(w).is_empty(),
                |w| format!("the notice; the shell shows {}", show(&w.state("toasts"))),
            )?;
            let told = toasts(world);
            expect!(
                told.len() == 1 && text(&told[0]["description"]).starts_with("2 threads"),
                "the shell shows {}",
                show(&world.state("toasts"))
            );
            // Once: the next start says nothing.
            world.restart()?;
            world.connect()?;
            world.sync()?;
            expect!(toasts(world).is_empty(), "the notice is shown again");
            Ok(())
        },
    );

    // The age.
    steps.step(
        &format!("the last message in {Q} was 3 hours ago"),
        |world, c, _| {
            let at = iso(world.now() - Duration::hours(3));
            let id = id_in(&key_of(world, &c[0])?).to_owned();
            update_row(world, &id, |row| {
                row.insert("latestUserMessageAt".into(), json!(at));
                row.insert("updatedAt".into(), json!(at));
            })
        },
    );
    steps.step(
        &format!("the environment records that {Q} was pinned just now"),
        |world, c, _| {
            // As the MC's row after a pin: the update time moves with it.
            let at = iso(world.now());
            let id = id_in(&key_of(world, &c[0])?).to_owned();
            update_row(world, &id, |row| {
                row.insert("pinnedAt".into(), json!(at));
                row.insert("updatedAt".into(), json!(at));
            })
        },
    );
    steps.step(
        &format!("the row for {Q} counts its age from that message"),
        |world, c, _| {
            world.sync()?;
            let key = key_of(world, &c[0])?;
            let row = row_of(world, &key);
            let wanted = text(&world.mc.threads[id_in(&key)]["latestUserMessageAt"]);
            expect!(
                row["pinned"] == json!(true) && text(&row["timeAt"]) == wanted,
                "the row is {}",
                show(&row)
            );
            Ok(())
        },
    );

    // The preview.
    steps.step(
        &format!("the user rests the pointer on {Q}"),
        |world, c, _| {
            let key = key_of(world, &c[0])?;
            world.part::<RowScene>().subject = key.clone();
            // A thread at work on a branch, so the preview has one to show.
            update_row(world, id_in(&key), |row| {
                row.insert("branch".into(), json!("feature/search"));
            })
        },
    );
    steps.step(
        "a preview shows the thread's project, branch and latest activity",
        |world, _, _| {
            // SidebarThreadRow.qml shows these lines after the pointer rests on the row.
            let subject = world.part::<RowScene>().subject.clone();
            let row = row_of(world, &subject);
            let preview = &row["preview"];
            let project = text(&world.mc.threads[id_in(&subject)]["projectId"]);
            expect!(
                text(&preview["project"]) == project
                    && text(&preview["branch"]) == "feature/search"
                    && text(&preview["activity"]).starts_with("Active "),
                "the row is {}",
                show(&row)
            );
            Ok(())
        },
    );

    // Jump hints.
    steps.step("the user holds the thread jump modifier", |world, _, _| {
        // Ten threads, so one is past the ninth.
        let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
        for index in 0..10 {
            let id = format!("t-jump-{index}");
            let at = format!("2026-09-23T09:{}:00Z", 10 + index);
            let row = json!({"id": id, "title": format!("Jump {index}"), "projectId": project,
                             "createdAt": at, "updatedAt": at});
            world.mc.threads.insert(id.clone(), row.clone());
            world.mc.send_row(&id, &row);
        }
        world.sync()?;
        for row in rows(world) {
            expect!(
                !row["jumpLabel"].is_string(),
                "a hint shows before the modifier is held"
            );
        }
        hold_jump_modifier(world, true)?;
        // Not at once: a quick shortcut shows nothing.
        expect!(!first_labelled(world), "the hints show without a delay");
        Ok(())
    });
    steps.step(
        "the first nine threads show their jump numbers after a short delay",
        |world, _, _| {
            world.wait_for("the jump hints", first_labelled)?;
            let listed = rows(world);
            expect!(
                listed.len() >= 10,
                "only {} threads are listed",
                listed.len()
            );
            for (index, row) in listed.iter().enumerate() {
                let label = &row["jumpLabel"];
                if index < 9 {
                    expect!(
                        text(label).ends_with(&(index + 1).to_string()),
                        "row {} shows \"{}\"",
                        index + 1,
                        text(label)
                    );
                } else {
                    expect!(
                        !label.is_string(),
                        "row {} shows \"{}\"",
                        index + 1,
                        text(label)
                    );
                }
            }
            // Letting go hides them.
            hold_jump_modifier(world, false)?;
            expect!(!first_labelled(world), "the hints stay");
            Ok(())
        },
    );

    // Files dropped on a row.
    steps.step(
        &format!("the user drops two files onto {Q} in the thread list"),
        |world, c, _| {
            let mut files = Vec::new();
            for name in ["cart.png", "totals.png"] {
                let path = world.home_dir().join(name);
                if std::fs::write(&path, b"\x89PNG\r\n\x1a\n").is_err() {
                    fail!("cannot write {name}");
                }
                if let Some(file) = attachment_files::read_image(&path.to_string_lossy()) {
                    files.push(file);
                }
            }
            // As Sidebar.qml: the composer's own reader, with its limits.
            let key = key_of(world, &c[0])?;
            world.dispatch(
                "thread.attachFiles",
                json!({"key": key.clone(), "files": files}),
            )?;
            world.part::<RowScene>().subject = key;
            Ok(())
        },
    );
    steps.step(
        "the files are attached to its composer with the usual attachment limits",
        |world, _, _| {
            let subject = world.part::<RowScene>().subject.clone();
            let names: Vec<String> = composer::attachments(world.engine(), &subject)
                .iter()
                .map(|a| text(&a["name"]))
                .collect();
            expect!(
                names == ["cart.png", "totals.png"],
                "the composer holds {}",
                names.join(", ")
            );
            // The limits are the reader's: what is not an image is left out.
            let notes = world.home_dir().join("notes.txt");
            if std::fs::write(&notes, "plain text").is_err() {
                fail!("cannot write notes.txt");
            }
            expect!(
                attachment_files::read_image(&notes.to_string_lossy()).is_none(),
                "a text file was read as an image"
            );
            Ok(())
        },
    );
}
