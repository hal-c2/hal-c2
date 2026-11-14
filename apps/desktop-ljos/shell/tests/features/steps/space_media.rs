//! Decks and slides, presenting, images, self-updating pages and a page from
//! a thread (features/space/slides.feature, images.feature,
//! self-updating-pages.feature), ported from desktop-qt's SpaceSteps.cpp.
//! Shared helpers live in space.rs, the MC's side in space_fake.rs.

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::space::rows::Row;
use serde_json::{Map, Value, json};

use crate::harness::{Outcome, Q, Steps, show, text};
use crate::steps::space::{
    act, act_on_block, act_on_deck, act_on_page, column, current, describe, expect_shown, given,
    given_deck, given_space, id_of_deck, id_of_page, id_of_space, listed, look, look_at_deck,
    look_at_page, row_of, row_text, rows_of, thread_named, with_second, with_space,
};
use crate::steps::space_fake as fake;
use crate::world::World;
use crate::{expect, fail};

/// A 4 by 3 red PNG, as desktop-qt's pngBytes() draws it.
const PNG: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x03, 0x08, 0x02, 0x00, 0x00, 0x00, 0x3b, 0x96, 0x39,
    0x91, 0x00, 0x00, 0x00, 0x11, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
    0x47, 0x08, 0x16, 0x3a, 0x07, 0x00, 0xf5, 0x31, 0x0b, 0xf5, 0x5b, 0x93, 0x71, 0xad, 0x00, 0x00,
    0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];

fn toasts(world: &World) -> Value {
    world.state("toasts")["items"].clone()
}

/// A toast whose title starts with `start` was shown (desktop-qt's toldOf).
fn told(world: &World, start: &str) -> bool {
    toasts(world).as_array().is_some_and(|items| {
        items
            .iter()
            .any(|item| text(&item["title"]).starts_with(start))
    })
}

fn expect_told(world: &mut World, start: &str) -> Outcome {
    let want = start.to_owned();
    world.wait_for_with(
        move |w| told(w, &want),
        |w| {
            format!(
                "the user to be told \"{start}\"; toasts {}",
                show(&toasts(w))
            )
        },
    )
}

fn space_state(world: &World, field: &str) -> bool {
    world.state("space")[field].as_bool().unwrap_or(false)
}

// --- Self-updating pages ----------------------------------------------------

fn every_hours(hours: &str) -> Value {
    json!({"type": "interval", "everyMs": hours.parse::<f64>().unwrap_or(0.0) * 3_600_000.0})
}

fn every_day_at(time: &str) -> Value {
    json!({"type": "fixed_time", "timeOfDay": time, "weekdays": []})
}

fn set_update(world: &mut World, page: &str, instruction: &str, cadence: Value) -> Outcome {
    let id = id_of_page(world, page)?;
    act_on_page(
        world,
        &id,
        "space.page.schedule.set",
        json!({"instruction": instruction, "cadence": cadence}),
    )
}

fn given_update(world: &mut World, page: &str, mut rest: Value, method: &str) -> Outcome {
    rest["pageId"] = json!(id_of_page(world, page)?);
    given(world, method, rest).map(|_| ())
}

fn open_page(world: &World) -> Row {
    with_space(world, |s, e| s.page(e)).unwrap_or_default()
}

/// `shown` holds of the page's update (its `schedule`) and the page, as the
/// open page shows them, in time.
fn expect_update(
    world: &mut World,
    page: &str,
    wanted: &str,
    shown: impl Fn(&Map<String, Value>, &Row) -> bool + 'static,
) -> Outcome {
    let id = id_of_page(world, page)?;
    look_at_page(world, &id)?;
    world.wait_for_with(
        move |w| {
            let open = open_page(w);
            let schedule = open
                .get("schedule")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            shown(&schedule, &open)
        },
        |w| {
            format!(
                "{page} to show {wanted}; the page is {}",
                show(&Value::Object(open_page(w)))
            )
        },
    )
}

/// What the open page's generated part says, when it has one.
fn generated_text(world: &World) -> Option<String> {
    rows_of(world, "blocks")
        .iter()
        .find(|block| row_text(block, "kind") == fake::GENERATED)
        .map(|block| row_text(block, "text"))
}

// --- Decks and slides ------------------------------------------------------

fn slide_titled(world: &mut World, title: &str) -> Outcome<Value> {
    let space = current(world)?;
    for slide in fake::all(&mut world.mc, &fake::stream_of(&space), "slide") {
        if text(&slide["title"]) == title {
            return Ok(slide);
        }
    }
    fail!("the Space has no slide {title}")
}

fn id_of_slide(world: &mut World, title: &str) -> Outcome<String> {
    Ok(text(&slide_titled(world, title)?["id"]))
}

fn act_on_slide(world: &mut World, title: &str, action: &str, mut payload: Value) -> Outcome {
    let slide = slide_titled(world, title)?;
    look_at_deck(world, &text(&slide["deckId"]))?;
    payload["slideId"] = json!(text(&slide["id"]));
    act(world, action, payload)
}

/// The open deck's slides as rows of title and body, the body's lines
/// written apart with " / ".
fn slide_table(world: &World) -> Vec<Vec<String>> {
    rows_of(world, "slides")
        .iter()
        .map(|slide| {
            vec![
                row_text(slide, "title"),
                row_text(slide, "body").replace('\n', " / "),
            ]
        })
        .collect()
}

fn second_column(world: &World, rows: &str, field: &str) -> Vec<String> {
    with_second(world, |s, _| {
        s.rows(rows)
            .iter()
            .map(|row| row_text(row, field))
            .collect()
    })
    .unwrap_or_default()
}

// --- Images ------------------------------------------------------------------

/// The image the user calls `said`, in or out of the trash; it is
/// remembered after it goes.
fn id_of_image(world: &mut World, said: &str) -> Outcome<String> {
    let key = format!("image\n{said}");
    if let Some(known) = fake::fake(&mut world.mc).named.get(&key).cloned() {
        return Ok(known);
    }
    let space = current(world)?;
    for image in fake::all(&mut world.mc, &fake::stream_of(&space), "image") {
        if text(&image["name"]) == said {
            let id = text(&image["id"]);
            fake::fake(&mut world.mc).named.insert(key, id.clone());
            return Ok(id);
        }
    }
    fail!("the Space has no image {said}")
}

fn given_image(world: &mut World, said: &str) -> Outcome<String> {
    let made = given(
        world,
        "image.add",
        json!({"attachmentId": "given", "name": said}),
    )?;
    let id = text(&made["image"]["id"]);
    fake::fake(&mut world.mc)
        .named
        .insert(format!("image\n{said}"), id.clone());
    Ok(id)
}

/// A file in the scenario's home, as the user would pick it.
fn given_file(world: &mut World, said: &str, bytes: &[u8]) -> Outcome<String> {
    let path = world.home_dir().join(said);
    if let Err(error) = std::fs::write(&path, bytes) {
        fail!("could not write {}: {error}", path.display());
    }
    Ok(format!("file://{}", path.display()))
}

/// The image block of the open page saying `said`, once there is one.
fn image_block(world: &World, said: &str) -> Option<Row> {
    rows_of(world, "blocks")
        .into_iter()
        .find(|block| row_text(block, "kind") == "image" && row_text(block, "text") == said)
}

fn expect_image_state(world: &mut World, page: &str, said: &str, state: &str) -> Outcome {
    let id = id_of_page(world, page)?;
    look_at_page(world, &id)?;
    let (on, want) = (said.to_owned(), state.to_owned());
    expect_shown(
        world,
        &format!("{page} to show the image {said} as {state}"),
        move |w| image_block(w, &on).is_some_and(|block| row_text(&block, "imageState") == want),
    )
}

fn images_prompt(world: &World) -> Value {
    world.state("composer")
}

/// The images of the Space `id` open, with the prompt aimed at them and
/// knowing who can draw.
fn open_images_prompt(world: &mut World, id: &str) -> Outcome {
    look(world, id)?;
    world.dispatch("space.images.show", json!({"shown": true}))?;
    world.wait_for_with(
        |w| {
            text(&images_prompt(w)["routeKind"]) == "images"
                && w.state("space")["imageProviders"]
                    .get("providers")
                    .is_some()
        },
        |w| {
            format!(
                "the prompt to be the images', knowing who can draw; it is {}",
                show(&images_prompt(w))
            )
        },
    )
}

/// The user writes `prompt` in the images' prompt and sends it, with the
/// image model already picked.
fn generate_in_prompt(world: &mut World, prompt: &str) -> Outcome {
    let target = text(&images_prompt(world)["target"]);
    world.dispatch(
        "composer.text.set",
        json!({"target": target, "text": prompt, "cursor": prompt.encode_utf16().count()}),
    )?;
    world.dispatch(
        "composer.submit",
        json!({"text": prompt, "intent": "foreground"}),
    )?;
    world.sync()
}

/// The picker's instances: {instanceId: [model slugs]}, and who is available.
fn picker_offer(world: &World) -> (Map<String, Value>, Vec<String>) {
    let mut offer = Map::new();
    let mut available = Vec::new();
    let picker = world.state("modelPicker");
    for instance in picker["instances"].as_array().into_iter().flatten() {
        let id = text(&instance["instanceId"]);
        let slugs: Vec<Value> = instance["models"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|model| json!(text(&model["slug"])))
            .collect();
        offer.insert(id.clone(), Value::Array(slugs));
        if instance["isAvailable"].as_bool().unwrap_or(false) {
            available.push(id);
        }
    }
    (offer, available)
}

fn image_models() -> Map<String, Value> {
    let mut wanted = Map::new();
    wanted.insert("codex".into(), json!(["auto"]));
    wanted.insert(
        "grok".into(),
        json!(["auto", "grok-imagine-image-2.0", "grok-imagine-image"]),
    );
    wanted
}

pub fn register(steps: &mut Steps) {
    register_pages(steps);
    register_decks(steps);
    register_presenting(steps);
    register_images(steps);
}

fn register_pages(steps: &mut Steps) {
    // A page from a thread.
    steps.step(
        &format!("the thread {Q} talked about a release plan"),
        |world, c, _| {
            let thread = thread_named(world, &c[0])?;
            fake::fake(&mut world.mc).talked.insert(thread);
            Ok(())
        },
    );
    steps.step("text generation is available", |world, _, _| {
        fake::fake(&mut world.mc).generation = "available".into();
        Ok(())
    });
    steps.step("no text generation provider is available", |world, _, _| {
        fake::fake(&mut world.mc).generation = "unavailable".into();
        Ok(())
    });
    steps.step("text generation fails", |world, _, _| {
        fake::fake(&mut world.mc).generation = "failed".into();
        Ok(())
    });
    steps.step(&format!("text generation writes {Q}"), |world, c, _| {
        let spaces = fake::fake(&mut world.mc);
        spaces.generation = "available".into();
        spaces.writes.clone_from(&c[0]);
        Ok(())
    });
    steps.step(
        &format!("the user makes a page in {Q} from the thread {Q}"),
        |world, c, _| {
            // The Space the page goes in is the one the user last had open.
            let space = id_of_space(world, &c[0])?;
            look(world, &space)?;
            let thread = thread_named(world, &c[1])?;
            let key = format!("{}:{thread}", world.mc.environment_id);
            world.with::<Navigation, _>(|navigation, engine| {
                navigation.open(engine, Route::Thread(key.clone()))
            })?;
            world.sync()?;
            // From the thread's menu.
            world.dispatch("thread.menu", json!({"key": key, "x": 40, "y": 120}))?;
            let menu = world.state("menu");
            expect!(menu.is_object(), "no thread menu opened");
            world.dispatch(
                "menu.select",
                json!({"requestId": menu["requestId"], "id": "page-from-thread"}),
            )?;
            world.sync()
        },
    );
    steps.step("the new page holds the generated summary", |world, _, _| {
        let space = current(world)?;
        expect_shown(world, "the summary to open as a page", move |w| {
            w.state("route")["kind"] == "space"
                && with_space(w, |s, _| s.space_id() == space).unwrap_or(false)
                && row_text(&open_page(w), "title") == fake::SUMMARY_TITLE
                && column(w, "blocks", "text") == vec![fake::SUMMARY.to_owned()]
        })?;
        let block = rows_of(world, "blocks")
            .into_iter()
            .next()
            .unwrap_or_default();
        expect!(
            block.get("byAgent").and_then(Value::as_bool) == Some(true),
            "the summary is not shown as the agent's: {}",
            show(&Value::Object(block))
        );
        Ok(())
    });
    steps.step(
        &format!("the new page remembers it came from {Q}"),
        |world, c, _| {
            let page = open_page(world);
            let thread = thread_named(world, &c[0])?;
            expect!(
                row_text(&page, "sourceThreadId") == thread
                    && row_text(&page, "sourceThreadTitle") == c[0],
                "the page shows {}",
                show(&Value::Object(page))
            );
            Ok(())
        },
    );
    steps.step(
        "the summary was written in the project's folder",
        |world, _, _| {
            // The client names the thread; the MC finds its folder.
            let (summarised, cwd) = {
                let spaces = fake::fake(&mut world.mc);
                (spaces.summarised.clone(), spaces.cwd.clone())
            };
            let project = world
                .mc
                .threads
                .get(&summarised)
                .map(|thread| text(&thread["projectId"]))
                .unwrap_or_default();
            let folder = world
                .mc
                .projects
                .get(&project)
                .map(|project| text(&project["workspaceRoot"]))
                .unwrap_or_default();
            expect!(
                !summarised.is_empty() && !folder.is_empty() && cwd == folder,
                "the summary of {summarised} was written in \"{cwd}\", not \"{folder}\""
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told text generation (is unavailable|failed)",
        |world, c, _| {
            let start = if c[0] == "failed" {
                "Text generation failed, so no page was written: The provider stopped answering."
            } else {
                "Text generation is unavailable, so no page was written."
            };
            expect_told(world, start)?;
            expect!(
                !space_state(world, "busy"),
                "the Space view still says it is writing"
            );
            Ok(())
        },
    );

    // A page that updates itself.
    steps.step(
        &format!("the user has {Q} update itself with {Q} every (\\d+) hours"),
        |world, c, _| set_update(world, &c[0], &c[1], every_hours(&c[2])),
    );
    steps.step(
        &format!("the user has {Q} update itself with {Q} every day at {Q}"),
        |world, c, _| set_update(world, &c[0], &c[1], every_day_at(&c[2])),
    );
    steps.step(
        &format!("{Q} updates itself with {Q} every (\\d+) hours"),
        |world, c, _| {
            given_update(
                world,
                &c[0],
                json!({"instruction": c[1], "cadence": every_hours(&c[2])}),
                "page.schedule.set",
            )
        },
    );
    steps.step(&format!("the updates of {Q} are paused"), |world, c, _| {
        given_update(
            world,
            &c[0],
            json!({"enabled": false}),
            "page.schedule.setEnabled",
        )
    });
    steps.step(&format!("the update of {Q} has run"), |world, c, _| {
        given_update(world, &c[0], json!({}), "page.schedule.runNow")
    });
    steps.step(
        &format!("the user pauses the updates of {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(
                world,
                &page,
                "space.page.schedule.setEnabled",
                json!({"enabled": false}),
            )
        },
    );
    steps.step(
        &format!("the user resumes the updates of {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(
                world,
                &page,
                "space.page.schedule.setEnabled",
                json!({"enabled": true}),
            )
        },
    );
    steps.step(
        &format!("the user runs the update of {Q} now"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.page.schedule.runNow", json!({}))
        },
    );
    steps.step(
        &format!("the user removes the update of {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.page.schedule.remove", json!({}))
        },
    );
    steps.step(
        &format!("the user tries to edit the generated part of {Q}"),
        |world, c, _| {
            let space = current(world)?;
            let page = id_of_page(world, &c[0])?;
            let block = fake::generated_of(&mut world.mc, &space, &page);
            expect!(
                block.as_object().is_some_and(|block| !block.is_empty()),
                "{} has no generated part",
                c[0]
            );
            act_on_block(
                world,
                &text(&block["text"]),
                "space.block.update",
                json!({"text": "Edited by hand"}),
            )
        },
    );
    steps.step(&format!("{Q} shows the instruction {Q}"), |world, c, _| {
        let want = c[1].clone();
        expect_update(
            world,
            &c[0],
            &format!("the instruction {}", c[1]),
            move |update, _| update.get("instruction") == Some(&json!(want)),
        )
    });
    steps.step(&format!("{Q} shows no instruction"), |world, c, _| {
        expect_update(world, &c[0], "no instruction", |update, _| {
            update.is_empty()
        })
    });
    steps.step(
        &format!("{Q} shows it updates every (\\d+) hours"),
        |world, c, _| {
            let label = format!("Every {} hours", c[1]);
            let want = label.clone();
            expect_update(world, &c[0], &label, move |update, _| {
                update.get("cadenceLabel") == Some(&json!(want))
            })
        },
    );
    steps.step(
        &format!("{Q} shows it updates every day at {Q}"),
        |world, c, _| {
            let label = format!("Every day at {}", c[1]);
            let want = label.clone();
            expect_update(world, &c[0], &label, move |update, _| {
                update.get("cadenceLabel") == Some(&json!(want))
            })
        },
    );
    steps.step(&format!("{Q} shows when it next runs"), |world, c, _| {
        expect_update(world, &c[0], "its next run", |update, _| {
            !text(update.get("nextRunAt").unwrap_or(&Value::Null)).is_empty()
        })
    });
    steps.step(&format!("{Q} shows no next run"), |world, c, _| {
        expect_update(world, &c[0], "no next run", |update, _| {
            text(update.get("nextRunAt").unwrap_or(&Value::Null)).is_empty()
        })
    });
    steps.step(&format!("{Q} has not been written yet"), |world, c, _| {
        expect_update(world, &c[0], "it has not been written", |_, page| {
            row_text(page, "writtenAt").is_empty()
        })
    });
    steps.step(
        &format!("{Q} shows when it was last written"),
        |world, c, _| {
            expect_update(world, &c[0], "when it was last written", |_, page| {
                !row_text(page, "writtenAt").is_empty()
            })
        },
    );
    steps.step(
        &format!("{Q} shows its updates are paused"),
        |world, c, _| {
            expect_update(world, &c[0], "it is paused", |update, _| {
                update.get("enabled") == Some(&json!(false))
            })
        },
    );
    steps.step(
        &format!("{Q} shows its updates are not paused"),
        |world, c, _| {
            expect_update(world, &c[0], "it is not paused", |update, _| {
                update.get("enabled") == Some(&json!(true))
            })
        },
    );
    steps.step(
        &format!("{Q} shows its last run failed with {Q}"),
        |world, c, _| {
            let want = c[1].clone();
            expect_update(
                world,
                &c[0],
                &format!("a failed run saying {}", c[1]),
                move |update, _| {
                    update.get("lastRunStatus") == Some(&json!("failed"))
                        && update.get("lastRunError") == Some(&json!(want))
                },
            )
        },
    );
    steps.step(
        &format!("the generated part of {Q} reads {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            look_at_page(world, &page)?;
            let want = c[1].clone();
            expect_shown(
                world,
                &format!("the generated part to read {}", c[1]),
                move |w| generated_text(w).as_deref() == Some(want.as_str()),
            )
        },
    );
    steps.step(&format!("{Q} has no generated part"), |world, c, _| {
        let page = id_of_page(world, &c[0])?;
        look_at_page(world, &page)?;
        expect_shown(world, "no generated part", |w| generated_text(w).is_none())
    });
}

fn register_decks(steps: &mut Steps) {
    steps.step(&format!("the user makes the deck {Q}"), |world, c, _| {
        let space = current(world)?;
        look(world, &space)?;
        act(world, "space.deck.create", json!({"title": c[0]}))
    });
    steps.step(
        &format!("the user makes a deck from the page {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.deck.createFromPage", json!({}))
        },
    );
    steps.step(&format!("the deck {Q}"), |world, c, _| {
        given_deck(world, &c[0]).map(|_| ())
    });
    steps.step(
        &format!("the deck {Q} with the slides {Q}"),
        |world, c, _| {
            let deck = given_deck(world, &c[0])?;
            let space = current(world)?;
            for slide in fake::slides_of(&mut world.mc, &fake::stream_of(&space), &deck) {
                given(
                    world,
                    "slide.delete",
                    json!({"slideId": text(&slide["id"])}),
                )?;
            }
            for title in listed(&c[1]) {
                given(
                    world,
                    "slide.insert",
                    json!({"deckId": deck, "title": title}),
                )?;
            }
            Ok(())
        },
    );
    steps.step(&format!("the deck {Q} is in the trash"), |world, c, _| {
        let deck = given_deck(world, &c[0])?;
        given(world, "deck.trash", json!({"deckId": deck})).map(|_| ())
    });
    steps.step(&format!("the decks of {Q} are {Q}"), |world, c, _| {
        let space = id_of_space(world, &c[0])?;
        look(world, &space)?;
        let want = listed(&c[1]);
        expect_shown(world, &format!("the decks to be {}", c[1]), move |w| {
            column(w, "decks", "title") == want
        })
    });
    steps.step(
        &format!("the deck {Q} has the slides:"),
        |world, c, table| {
            let deck = id_of_deck(world, &c[0])?;
            look_at_deck(world, &deck)?;
            let wanted: Vec<Vec<String>> = table
                .iter()
                .skip(1)
                .map(|row| {
                    (0..2)
                        .map(|i| row.get(i).cloned().unwrap_or_default())
                        .collect()
                })
                .collect();
            let what = wanted.clone();
            world.wait_for_with(
                move |w| slide_table(w) == wanted,
                move |w| format!("the slides {what:?}, shown {:?}", slide_table(w)),
            )
        },
    );
    steps.step(
        &format!("the slides of {Q} are(?: still)? {Q}"),
        |world, c, _| {
            world.wait_for("the shell to reconnect", |w| w.client_ready())?;
            let deck = id_of_deck(world, &c[0])?;
            look_at_deck(world, &deck)?;
            let want = listed(&c[1]);
            let what = c[1].clone();
            world.wait_for_with(
                move |w| column(w, "slides", "title") == want,
                move |w| {
                    format!(
                        "the slides to be {what}, shown {:?}; {}",
                        column(w, "slides", "title"),
                        describe(w)
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the user renames the deck {Q} to {Q}"),
        |world, c, _| act_on_deck(world, &c[0], "space.deck.rename", json!({"title": c[1]})),
    );
    steps.step(
        &format!("the title {Q} written for the deck {Q} lands once the Space {Q} is on show"),
        |world, c, _| {
            let deck = id_of_deck(world, &c[1])?;
            let space = current(world)?;
            given_space(world, &c[2])?;
            let other = id_of_space(world, &c[2])?;
            look(world, &other)?;
            act(
                world,
                "space.deck.rename",
                json!({"spaceId": space, "deckId": deck, "title": c[0]}),
            )
        },
    );
    steps.step(
        &format!("the user moves the deck {Q} to the trash"),
        |world, c, _| act_on_deck(world, &c[0], "space.deck.trash", json!({})),
    );
    steps.step(&format!("the user restores the deck {Q}"), |world, c, _| {
        act_on_deck(world, &c[0], "space.deck.restore", json!({}))
    });
    steps.step(
        &format!("the user deletes the deck {Q} for good"),
        |world, c, _| act_on_deck(world, &c[0], "space.deck.delete", json!({})),
    );
    steps.step(&format!("no slides remain in {Q}"), |world, c, _| {
        let space = id_of_space(world, &c[0])?;
        look(world, &space)?;
        expect_shown(world, "no slides to remain", |w| {
            with_space(w, |s, _| s.stream_ids("space", "slide").is_empty()).unwrap_or(false)
        })
    });
    steps.step(
        &format!("the user adds the slide {Q} to {Q}"),
        |world, c, _| {
            act_on_deck(
                world,
                &c[1],
                "space.slide.insert",
                json!({"title": c[0], "body": ""}),
            )
        },
    );
    steps.step(
        &format!("the user adds the slide {Q} after {Q} in {Q}"),
        |world, c, _| {
            let after = id_of_slide(world, &c[1])?;
            act_on_deck(
                world,
                &c[2],
                "space.slide.insert",
                json!({"title": c[0], "body": "", "afterSlideId": after}),
            )
        },
    );
    steps.step(
        &format!("the user changes the slide {Q} to {Q} reading {Q}"),
        |world, c, _| {
            act_on_slide(
                world,
                &c[0],
                "space.slide.update",
                json!({"title": c[1], "body": c[2]}),
            )
        },
    );
    steps.step(
        &format!("the user moves the slide {Q} before {Q}"),
        |world, c, _| {
            let before = slide_titled(world, &c[1])?;
            let space = current(world)?;
            let mut after = String::new();
            for slide in fake::slides_of(
                &mut world.mc,
                &fake::stream_of(&space),
                &text(&before["deckId"]),
            ) {
                if text(&slide["id"]) == text(&before["id"]) {
                    break;
                }
                after = text(&slide["id"]);
            }
            act_on_slide(
                world,
                &c[0],
                "space.slide.move",
                json!({"afterSlideId": after}),
            )
        },
    );
    steps.step(&format!("the user deletes the slide {Q}"), |world, c, _| {
        act_on_slide(world, &c[0], "space.slide.delete", json!({}))
    });
    steps.step(
        &format!("the second client sees the deck {Q}"),
        |world, c, _| {
            let titles = second_column(world, "decks", "title");
            expect!(
                titles.contains(&c[0]),
                "the second client shows the decks {titles:?}"
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the second client sees the slide {Q}"),
        |world, c, _| {
            let deck = text(&slide_titled(world, &c[0])?["deckId"]);
            with_second(world, |s, e| s.select_deck(e, &deck))?;
            let titles = second_column(world, "slides", "title");
            expect!(
                titles.contains(&c[0]),
                "the second client shows the slides {titles:?}"
            );
            Ok(())
        },
    );
}

fn register_presenting(steps: &mut Steps) {
    steps.step(&format!("the user presents the deck {Q}"), |world, c, _| {
        let space = current(world)?;
        look(world, &space)?;
        let id = id_of_deck(world, &c[0])?;
        let deck = id.clone();
        world.wait_for("the Space's copy to hold the deck", move |w| {
            with_space(w, |s, _| {
                !s.stream_entity("space", "deck", &deck).is_empty()
            })
            .unwrap_or(false)
        })?;
        act(world, "space.deck.present", json!({"deckId": id}))
    });
    steps.step(
        &format!("the presenter shows {Q}, slide (\\d+) of (\\d+)"),
        |world, c, _| {
            let title = c[0].clone();
            let number: i32 = c[1].parse().unwrap_or(-1);
            let count: i32 = c[2].parse().unwrap_or(-1);
            let what = format!("the presenter to show {}, {} of {}", c[0], c[1], c[2]);
            world.wait_for_with(
                move |w| {
                    with_space(w, |s, _| {
                        s.presenting()
                            && row_text(&s.slide(), "title") == title
                            && s.slide_number() == number
                            && s.slide_count() == count
                    })
                    .unwrap_or(false)
                },
                move |w| {
                    let (slide, number, count) =
                        with_space(w, |s, _| (s.slide(), s.slide_number(), s.slide_count()))
                            .unwrap_or_default();
                    format!(
                        "{what}; it shows {}, {number} of {count}",
                        show(&Value::Object(slide))
                    )
                },
            )
        },
    );
    steps.step("the user steps (forward|back)", |world, c, _| {
        let by = if c[0] == "back" { -1 } else { 1 };
        act(world, "space.deck.step", json!({"by": by}))
    });
    steps.step("the user leaves the presenter", |world, _, _| {
        act(world, "space.deck.leave", json!({}))
    });
    steps.step("nothing is being presented", |world, _, _| {
        expect_shown(world, "the presenter to be closed", |w| {
            !with_space(w, |s, _| s.presenting()).unwrap_or(true)
        })
    });
    steps.step("the user is told the deck has no slides", |world, _, _| {
        expect_told(world, "This deck has no slides")
    });
    steps.step(
        &format!("another client changes the slide {Q} to {Q}"),
        |world, c, _| {
            let slide = id_of_slide(world, &c[0])?;
            given(
                world,
                "slide.update",
                json!({"slideId": slide, "title": c[1]}),
            )
            .map(|_| ())
        },
    );
    steps.step(
        &format!("another client moves the slide {Q} after {Q}"),
        |world, c, _| {
            let slide = id_of_slide(world, &c[0])?;
            let after = id_of_slide(world, &c[1])?;
            given(
                world,
                "slide.move",
                json!({"slideId": slide, "afterSlideId": after}),
            )
            .map(|_| ())
        },
    );
    steps.step(
        &format!("another client deletes the slide {Q}"),
        |world, c, _| {
            let slide = id_of_slide(world, &c[0])?;
            given(world, "slide.delete", json!({"slideId": slide})).map(|_| ())
        },
    );
    steps.step(
        &format!("another client moves the deck {Q} to the trash"),
        |world, c, _| {
            let deck = id_of_deck(world, &c[0])?;
            given(world, "deck.trash", json!({"deckId": deck})).map(|_| ())
        },
    );
}

fn register_images(steps: &mut Steps) {
    steps.step(
        &format!("the user adds the image {Q} to {Q}"),
        |world, c, _| {
            let space = id_of_space(world, &c[1])?;
            look(world, &space)?;
            let url = given_file(world, &c[0], PNG)?;
            act(world, "space.image.addFile", json!({"url": url}))
        },
    );
    steps.step(
        &format!("the user adds the file {Q} holding plain text to {Q}"),
        |world, c, _| {
            let space = id_of_space(world, &c[1])?;
            look(world, &space)?;
            let url = given_file(world, &c[0], b"Plain words, whatever the name says.")?;
            act(world, "space.image.addFile", json!({"url": url}))
        },
    );
    steps.step("the image request is refused", |world, _, _| {
        world.wait_for_with(
            |w| {
                let said = text(&w.state("space")["error"]);
                !said.is_empty() && told(w, &said)
            },
            |w| {
                format!(
                    "the user to be told why; {}, toasts {}",
                    describe(w),
                    show(&toasts(w))
                )
            },
        )
    });
    steps.step(&format!("the images of {Q} are {Q}"), |world, c, _| {
        let space = id_of_space(world, &c[0])?;
        look(world, &space)?;
        let want = listed(&c[1]);
        expect_shown(world, &format!("the images to be {}", c[1]), move |w| {
            column(w, "images", "name") == want
        })
    });
    steps.step(
        &format!("the image trash of {Q} holds {Q}"),
        |world, c, _| {
            let space = id_of_space(world, &c[0])?;
            look(world, &space)?;
            let want = listed(&c[1]);
            expect_shown(
                world,
                &format!("the image trash to hold {}", c[1]),
                move |w| column(w, "imageTrash", "name") == want,
            )
        },
    );
    steps.step(
        &format!("the second client sees the image {Q}"),
        |world, c, _| {
            let want = c[0].clone();
            let what = format!("the second client to show the image {}", c[0]);
            world.wait_for_with(
                move |w| second_column(w, "images", "name").contains(&want),
                move |_| what.clone(),
            )
        },
    );
    steps.step("image generation is available", |world, _, _| {
        fake::fake(&mut world.mc).image_generation = "available".into();
        Ok(())
    });
    steps.step(
        "no image generation provider is available",
        |world, _, _| {
            fake::fake(&mut world.mc).image_generation = "unavailable".into();
            Ok(())
        },
    );
    steps.step("image generation fails", |world, _, _| {
        fake::fake(&mut world.mc).image_generation = "failed".into();
        Ok(())
    });
    steps.step(
        &format!("the user generates an image of {Q} in {Q}"),
        |world, c, _| {
            let space = id_of_space(world, &c[1])?;
            open_images_prompt(world, &space)?;
            generate_in_prompt(world, &c[0])
        },
    );
    steps.step(
        "(\\w+) is installed and can generate images",
        |world, c, _| {
            let spaces = fake::fake(&mut world.mc);
            spaces.image_generation = "available".into();
            if c[0] == "grok" {
                spaces.grok = true;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the user generates an image of {Q} in {Q} with (\\w+) using {Q}"),
        |world, c, _| {
            let space = id_of_space(world, &c[1])?;
            open_images_prompt(world, &space)?;
            let (instance, model) = (c[2].clone(), c[3].clone());
            let offered = (instance.clone(), model.clone());
            world.wait_for_with(
                move |w| {
                    picker_offer(w).0.get(&offered.0).is_some_and(|models| {
                        models
                            .as_array()
                            .is_some_and(|m| m.contains(&json!(offered.1)))
                    })
                },
                |w| {
                    format!(
                        "the picker to offer the model; it offers {}",
                        show(&Value::Object(picker_offer(w).0))
                    )
                },
            )?;
            world.dispatch(
                "composer.model.select",
                json!({"instanceId": instance, "model": model}),
            )?;
            let picked = (c[2].clone(), c[3].clone());
            world.wait_for_with(
                move |w| {
                    let prompt = images_prompt(w);
                    text(&prompt["selectedInstanceId"]) == picked.0
                        && text(&prompt["selectedModel"]) == picked.1
                },
                |w| {
                    format!(
                        "the prompt to be on the chosen model; it is {}",
                        show(&images_prompt(w))
                    )
                },
            )?;
            generate_in_prompt(world, &c[0])
        },
    );
    steps.step(
        &format!("the image remembers it was made by (\\w+) using {Q}"),
        |world, c, _| {
            world.sync()?;
            let space = current(world)?;
            let images = fake::all(&mut world.mc, &fake::stream_of(&space), "image");
            expect!(
                images.iter().any(|image| {
                    text(&image["generatedBy"]["instanceId"]) == c[0]
                        && text(&image["generatedBy"]["model"]) == c[1]
                }),
                "no image was made by {} using {}: {}",
                c[0],
                c[1],
                show(&Value::Array(images.clone()))
            );
            Ok(())
        },
    );
    steps.step(
        "only the providers that can generate are offered, with their image models",
        |world, _, _| {
            let space = current(world)?;
            open_images_prompt(world, &space)?;
            let wanted = image_models();
            let what = wanted.clone();
            world.wait_for_with(
                move |w| picker_offer(w) == (wanted.clone(), vec!["codex".to_owned()]),
                move |w| {
                    let (offer, available) = picker_offer(w);
                    format!(
                        "the picker to offer {} with only codex available; it offers {} with {}",
                        show(&Value::Object(what.clone())),
                        show(&Value::Object(offer)),
                        available.join(",")
                    )
                },
            )?;
            let prompt = images_prompt(world);
            expect!(
                text(&prompt["selectedInstanceId"]) == "codex"
                    && text(&prompt["selectedModel"]) == "auto",
                "the prompt is not on Codex's own pick: {}",
                show(&prompt)
            );
            Ok(())
        },
    );
    steps.step(
        "the prompt area asks what the image should show",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let prompt = images_prompt(w);
                    text(&prompt["routeKind"]) == "images"
                        && text(&prompt["placeholder"]) == "What should the image show?"
                },
                |w| {
                    format!(
                        "the prompt to ask what the image should show; it is {}",
                        show(&images_prompt(w))
                    )
                },
            )?;
            let prompt = images_prompt(world);
            let empty = |field: &str| prompt[field].as_array().is_none_or(Vec::is_empty);
            expect!(
                empty("attachments")
                    && empty("options")
                    && empty("runtimeModes")
                    && !prompt["showInteractionModeToggle"]
                        .as_bool()
                        .unwrap_or(false),
                "the images' prompt offers what a turn carries: {}",
                show(&prompt)
            );
            Ok(())
        },
    );
    steps.step(
        "its model picker offers only image models",
        |world, _, _| {
            world.wait_for_with(
                |w| picker_offer(w).0 == image_models(),
                |w| {
                    format!(
                        "the picker to offer only image models; it offers {}",
                        show(&Value::Object(picker_offer(w).0))
                    )
                },
            )?;
            expect!(
                !world.state("modelPicker")["favorites"]
                    .as_bool()
                    .unwrap_or(false),
                "the picker stars image models"
            );
            Ok(())
        },
    );
    steps.step(
        "the prompt area says no provider can generate images",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    let prompt = images_prompt(w);
                    text(&prompt["placeholder"])
                        == "No provider here can generate images. Set up Codex or Grok in Settings."
                        && text(&prompt["sendDisabledReason"]) == "No provider can generate images"
                        && !prompt["canSend"].as_bool().unwrap_or(false)
                },
                |w| {
                    format!(
                        "the prompt to say no provider can generate images; it is {}",
                        show(&images_prompt(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the prompt area still holds {Q}"),
        |world, c, _| {
            let want = c[0].clone();
            let what = c[0].clone();
            world.wait_for_with(
                move |w| {
                    let prompt = images_prompt(w);
                    !prompt["isSendBusy"].as_bool().unwrap_or(false)
                        && text(&prompt["text"]) == want
                        && !space_state(w, "generatingImage")
                },
                move |w| {
                    format!(
                        "the prompt to still hold \"{what}\" once the answer came; it is {}",
                        show(&images_prompt(w))
                    )
                },
            )
        },
    );
    steps.step(
        &format!("{Q} has a generated image of {Q}"),
        |world, c, _| {
            let space = id_of_space(world, &c[0])?;
            look(world, &space)?;
            let want = c[1].clone();
            expect_shown(world, &format!("a generated image of {}", c[1]), move |w| {
                column(w, "images", "prompt").contains(&want)
            })?;
            expect!(
                !space_state(world, "generatingImage"),
                "the Space view still says it is generating"
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told image generation (is unavailable|failed)",
        |world, c, _| {
            let start = if c[0] == "failed" {
                "Image generation failed, so no image was made: The provider left no image."
            } else {
                "Image generation is unavailable, so no image was made."
            };
            expect_told(world, start)?;
            expect!(
                !space_state(world, "generatingImage"),
                "the Space view still says it is generating"
            );
            Ok(())
        },
    );
    steps.step(&format!("the image {Q} in {Q}"), |world, c, _| {
        let space = id_of_space(world, &c[1])?;
        expect!(
            space == current(world)?,
            "{} is not the scenario's Space",
            c[1]
        );
        given_image(world, &c[0]).map(|_| ())
    });
    steps.step(
        &format!("the user places the image {Q} on {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[1])?;
            let image = id_of_image(world, &c[0])?;
            act_on_page(
                world,
                &page,
                "space.block.insert",
                json!({"kind": "image", "text": c[0], "imageId": image}),
            )
        },
    );
    steps.step(
        &format!("{Q} shows the image {Q} already"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            let image = id_of_image(world, &c[1])?;
            given(
                world,
                "block.insert",
                json!({"pageId": page, "kind": "image", "text": c[1], "imageId": image}),
            )
            .map(|_| ())
        },
    );
    steps.step(&format!("{Q} shows the image {Q}"), |world, c, _| {
        expect_image_state(world, &c[0], &c[1], "shown")?;
        // Its bytes come by a signed address, on the MC this client talks to.
        let said = c[1].clone();
        expect_shown(world, "the image to have an address", move |w| {
            image_block(w, &said)
                .is_some_and(|block| row_text(&block, "imageUrl").contains("/assets/space/"))
        })
    });
    steps.step(
        &format!("{Q} says the image {Q} is in the trash"),
        |world, c, _| expect_image_state(world, &c[0], &c[1], "trashed"),
    );
    steps.step(
        &format!("{Q} says the image {Q} was deleted"),
        |world, c, _| expect_image_state(world, &c[0], &c[1], "deleted"),
    );
    steps.step(
        &format!("the image {Q} is in the image trash"),
        |world, c, _| {
            let image = id_of_image(world, &c[0])?;
            given(world, "image.trash", json!({"imageId": image})).map(|_| ())
        },
    );
    for (pattern, action) in [
        (
            "the user moves the image {Q} to the trash",
            "space.image.trash",
        ),
        ("the user restores the image {Q}", "space.image.restore"),
        (
            "the user deletes the image {Q} for good",
            "space.image.delete",
        ),
    ] {
        steps.step(&pattern.replace("{Q}", Q), move |world, c, _| {
            let space = current(world)?;
            look(world, &space)?;
            let image = id_of_image(world, &c[0])?;
            act(world, action, json!({"imageId": image}))
        });
    }
    steps.step(
        &format!("the user opens the images of {Q}"),
        |world, c, _| {
            let space = id_of_space(world, &c[0])?;
            open_images_prompt(world, &space)
        },
    );
    steps.step("the user closes the images", |world, _, _| {
        act(world, "space.images.show", json!({"shown": false}))
    });
    steps.step(
        &format!("the user sees the image {Q} with its name"),
        |world, c, _| {
            let image = id_of_image(world, &c[0])?;
            let name = c[0].clone();
            expect_shown(
                world,
                &format!("the image {} with a name and an address", c[0]),
                move |w| {
                    row_of(&rows_of(w, "images"), &image).is_some_and(|row| {
                        row_text(&row, "name") == name && !row_text(&row, "url").is_empty()
                    })
                },
            )
        },
    );
    steps.step(
        &format!("no address has been signed for {Q}"),
        |world, c, _| {
            world.sync()?;
            let image = id_of_image(world, &c[0])?;
            expect!(
                !fake::fake(&mut world.mc).signed_images.contains(&image),
                "the client signed an address for {} before it was shown",
                c[0]
            );
            Ok(())
        },
    );
    steps.step(
        &format!("an address has been signed for {Q}"),
        |world, c, _| {
            let image = id_of_image(world, &c[0])?;
            let what = format!("an address to be signed for {}", c[0]);
            world.wait_for_with(
                move |w| {
                    w.mc.peek::<fake::FakeSpaces>()
                        .is_some_and(|s| s.signed_images.contains(&image))
                },
                move |_| what.clone(),
            )
        },
    );
}
