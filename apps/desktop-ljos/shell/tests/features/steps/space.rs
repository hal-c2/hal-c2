//! The Space view: its bricks, its `Spaces` rows, and what the MC is
//! asked (features/space), desktop-qt's SpaceSteps.cpp. The MC's side is
//! space_fake.rs.

use hal_c2_shell::controller;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::space::Space;
use hal_c2_shell::controllers::space::rows::Row;
use ljos::prelude::Engine;
use serde_json::{Map, Value, json};

use crate::harness::{Failure, Outcome, Q, Steps, show, text};
use crate::steps::space_fake as fake;
use crate::world::World;
use crate::{expect, fail};

pub fn row_text(row: &Row, field: &str) -> String {
    text(row.get(field).unwrap_or(&Value::Null))
}

pub fn listed(names: &str) -> Vec<String> {
    if names.is_empty() {
        Vec::new()
    } else {
        names.split(", ").map(str::to_owned).collect()
    }
}

pub fn with_space<R>(
    world: &World,
    f: impl FnOnce(&mut Space, &ljos::prelude::Engine) -> R,
) -> Outcome<R> {
    world.with::<Space, _>(f)
}

pub fn rows_of(world: &World, name: &str) -> Vec<Row> {
    with_space(world, |space, _| space.rows(name)).unwrap_or_default()
}

pub fn column(world: &World, rows_name: &str, role: &str) -> Vec<String> {
    rows_of(world, rows_name)
        .iter()
        .map(|row| row_text(row, role))
        .collect()
}

pub fn row_of(rows: &[Row], id: &str) -> Option<Row> {
    rows.iter().find(|row| row_text(row, "id") == id).cloned()
}

pub fn describe(world: &World) -> String {
    let (name, status) = with_space(world, |s, _| (s.space_name(), s.status())).unwrap_or_default();
    format!(
        "the Space view shows {name} ({status}): spaces {:?}, pages {:?}, trash {:?}, blocks {}, comments {}; it says {}; the error is {}",
        column(world, "spaces", "name"),
        column(world, "pages", "title"),
        column(world, "trash", "title"),
        show(&Value::Array(
            rows_of(world, "blocks")
                .into_iter()
                .map(Value::Object)
                .collect()
        )),
        show(&Value::Array(
            rows_of(world, "comments")
                .into_iter()
                .map(Value::Object)
                .collect()
        )),
        show(&world.state("space")),
        with_space(world, |s, _| s.error().to_owned()).unwrap_or_default(),
    )
}

pub fn expect_shown(world: &mut World, what: &str, condition: impl Fn(&World) -> bool) -> Outcome {
    world.wait_for_with(condition, |w| format!("{what}; {}", describe(w)))
}

pub fn current(world: &mut World) -> Outcome<String> {
    let space = fake::fake(&mut world.mc).current.clone();
    if space.is_empty() {
        fail!("no Space was made for the scenario")
    } else {
        Ok(space)
    }
}

pub fn id_of_space(world: &mut World, name: &str) -> Outcome<String> {
    for space in fake::all(&mut world.mc, fake::INDEX, "space") {
        if text(&space["name"]) == name {
            return Ok(text(&space["id"]));
        }
    }
    fail!("the MC has no Space {name}")
}

pub fn find_page(world: &mut World, title: &str) -> Outcome<String> {
    let space = current(world)?;
    for page in fake::all(&mut world.mc, &fake::stream_of(&space), "page") {
        if text(&page["title"]) == title {
            return Ok(text(&page["id"]));
        }
    }
    Ok(String::new())
}

pub fn id_of_page(world: &mut World, title: &str) -> Outcome<String> {
    let id = find_page(world, title)?;
    if id.is_empty() {
        fail!("the Space has no page {title}")
    } else {
        Ok(id)
    }
}

pub fn find_block(world: &mut World, said: &str) -> Outcome<Value> {
    let space = current(world)?;
    for block in fake::all(&mut world.mc, &fake::stream_of(&space), "block") {
        if text(&block["text"]) == said {
            return Ok(block);
        }
    }
    Ok(json!({}))
}

pub fn block_saying(world: &mut World, said: &str) -> Outcome<Value> {
    let block = find_block(world, said)?;
    if block.as_object().is_none_or(Map::is_empty) {
        fail!("the Space has no block {said}")
    } else {
        Ok(block)
    }
}

pub fn id_of_comment(world: &mut World, body: &str) -> Outcome<String> {
    let space = current(world)?;
    for comment in fake::all(&mut world.mc, &fake::stream_of(&space), "comment") {
        if text(&comment["body"]) == body {
            return Ok(text(&comment["id"]));
        }
    }
    fail!("the Space has no comment {body}")
}

/// What the MC is told by the scenario's setting up, as a client would ask it.
pub fn given(world: &mut World, method: &str, mut input: Value) -> Outcome<Value> {
    if method != "create" && input.get("spaceId").is_none() {
        let space = current(world)?;
        input["spaceId"] = json!(space);
    }
    let answer = fake::call(&mut world.mc, method, &input);
    if !answer.error.is_empty() {
        fail!("the MC refused space.{method}: {}", answer.error);
    }
    world.sync()?;
    Ok(answer.result)
}

pub fn given_space(world: &mut World, name: &str) -> Outcome {
    let made = given(world, "create", json!({"name": name}))?;
    fake::fake(&mut world.mc).current = text(&made["space"]["id"]);
    Ok(())
}

pub fn given_page(world: &mut World, title: &str, parent: &str) -> Outcome<String> {
    let id = find_page(world, title)?;
    if !id.is_empty() {
        return Ok(id);
    }
    let made = given(
        world,
        "page.create",
        json!({
            "title": title,
            "parentPageId": if parent.is_empty() { Value::Null } else { json!(parent) },
        }),
    )?;
    let id = text(&made["page"]["id"]);
    fake::fake(&mut world.mc)
        .named
        .insert(format!("page\n{title}"), id.clone());
    Ok(id)
}

pub fn given_block(
    world: &mut World,
    page: &str,
    kind: &str,
    said: &str,
    checked: bool,
) -> Outcome {
    let page = given_page(world, page, "")?;
    given(
        world,
        "block.insert",
        json!({"pageId": page, "kind": kind, "text": said, "checked": checked}),
    )?;
    Ok(())
}

pub fn open_spaces(world: &mut World) -> Outcome {
    if world.shell_subscriptions() == 0 {
        world.connect()?;
    }
    if world.state("route")["kind"] != "space" {
        world.dispatch("space.open", json!({}))?;
    }
    expect_shown(world, "the Space view to follow the Spaces", |w| {
        with_space(w, |s, _| {
            s.stream_live("index") && s.rows("spaces").len() > 0
        })
        .unwrap_or(false)
    })
}

pub fn look(world: &mut World, id: &str) -> Outcome {
    open_spaces(world)?;
    expect_shown(world, "the Space to be listed", |w| {
        w.with::<Space, _>(|s, _| s.rows("spaces").iter().any(|row| row_text(row, "id") == id))
            .unwrap_or(false)
    })?;
    if with_space(world, |s, _| s.space_id().to_owned()).unwrap_or_default() != id {
        world.dispatch("space.select", json!({"spaceId": id}))?;
    }
    let on = id.to_owned();
    expect_shown(world, "the Space to be followed", move |w| {
        w.with::<Space, _>(|s, _| s.space_id() == on && s.stream_live("space"))
            .unwrap_or(false)
    })
}

pub fn look_at_page(world: &mut World, id: &str) -> Outcome {
    let space = current(world)?;
    look(world, &space)?;
    let page = id.to_owned();
    expect_shown(world, "the Space's copy to hold the page", move |w| {
        w.with::<Space, _>(|s, _| !s.stream_entity("space", "page", &page).is_empty())
            .unwrap_or(false)
    })?;
    let (open_page, open_deck) = with_space(world, |s, _| {
        (s.page_id().to_owned(), s.deck_id().to_owned())
    })
    .unwrap_or_default();
    if open_page != id || !open_deck.is_empty() {
        world.dispatch("space.selectPage", json!({"pageId": id}))?;
    }
    let page = id.to_owned();
    expect_shown(world, "the page to open", move |w| {
        w.with::<Space, _>(|s, _| s.page_id() == page && s.deck_id().is_empty())
            .unwrap_or(false)
    })
}

pub fn act(world: &mut World, action: &str, payload: Value) -> Outcome {
    world.dispatch(action, payload)?;
    world.sync()
}

pub fn act_on_page(world: &mut World, page_id: &str, action: &str, mut payload: Value) -> Outcome {
    look_at_page(world, page_id)?;
    payload["pageId"] = json!(page_id);
    act(world, action, payload)
}

pub fn act_on_block(world: &mut World, said: &str, action: &str, mut payload: Value) -> Outcome {
    let block = block_saying(world, said)?;
    look_at_page(world, &text(&block["pageId"]))?;
    payload["blockId"] = json!(text(&block["id"]));
    act(world, action, payload)
}

pub fn block_texts(world: &World) -> Vec<String> {
    column(world, "blocks", "text")
}

pub fn thread_named(world: &mut World, title: &str) -> Outcome<String> {
    for (id, thread) in world.mc.threads.iter() {
        if text(&thread["title"]) == title {
            return Ok(id.clone());
        }
    }
    fail!("the MC has no thread {title}")
}

pub fn register(steps: &mut Steps) {
    steps.extension(fake::extension);

    steps.step("the user lists their Spaces", |world, _, _| {
        open_spaces(world)
    });
    steps.step("the user has listed their Spaces", |world, _, _| {
        open_spaces(world)?;
        world.restart()?;
        world.connect()
    });
    steps.step(&format!("the Spaces are {Q}"), |world, c, _| {
        open_spaces(world)?;
        expect_shown(world, &format!("the Spaces to be {}", c[0]), |w| {
            column(w, "spaces", "name") == listed(&c[0])
        })
    });
    steps.step(&format!("the Space {Q}"), |world, c, _| {
        given_space(world, &c[0])
    });
    steps.step(
        &format!("the Space {Q} with the page {Q}"),
        |world, c, _| {
            given_space(world, &c[0])?;
            given_page(world, &c[1], "").map(|_| ())
        },
    );
    steps.step(&format!("the user makes the Space {Q}"), |world, c, _| {
        open_spaces(world)?;
        act(world, "space.create", json!({"name": c[0]}))
    });
    steps.step(
        &format!("the user renames the Space {Q} to {Q}"),
        |world, c, _| {
            let id = id_of_space(world, &c[0])?;
            look(world, &id)?;
            act(world, "space.rename", json!({"spaceId": id, "name": c[1]}))
        },
    );
    steps.step(&format!("the user deletes the Space {Q}"), |world, c, _| {
        let id = id_of_space(world, &c[0])?;
        look(world, &id)?;
        act(world, "space.delete", json!({"spaceId": id}))
    });
    steps.step(
        "(?:the (?:Space|page|deck) request is refused|the user is told only a checklist item can be ticked)",
        |world, _, _| {
            let (method, error) = {
                let spaces = fake::fake(&mut world.mc);
                (spaces.last_method.clone(), spaces.last_error.clone())
            };
            expect!(!error.is_empty(), "the MC answered {method} with no error");
            let said = text(&world.state("space")["error"]);
            expect!(
                said == error && told_of(world, &said),
                "the user is not told \"{error}\": {}, toasts {}",
                describe(world),
                show(&world.state("toasts"))
            );
            Ok(())
        },
    );

    // Pages and their places.
    steps.step(&format!("the page {Q}"), |world, c, _| {
        given_page(world, &c[0], "").map(|_| ())
    });
    steps.step(&format!("the pages {Q} and {Q}"), |world, c, _| {
        given_page(world, &c[0], "")?;
        given_page(world, &c[1], "").map(|_| ())
    });
    steps.step(&format!("the page {Q} inside {Q}"), |world, c, _| {
        let parent = given_page(world, &c[1], "")?;
        given_page(world, &c[0], &parent).map(|_| ())
    });
    steps.step(
        &format!("the user makes the page {Q}(?: inside {Q})?"),
        |world, c, _| {
            let space = current(world)?;
            look(world, &space)?;
            let parent = if c.len() > 1 && !c[1].is_empty() {
                id_of_page(world, &c[1])?
            } else {
                String::new()
            };
            act(
                world,
                "space.page.create",
                json!({"title": c[0], "parentPageId": parent}),
            )
        },
    );
    steps.step(&format!("the pages of {Q} are {Q}"), |world, c, _| {
        let id = id_of_space(world, &c[0])?;
        look(world, &id)?;
        expect_shown(world, &format!("the pages to be {}", c[1]), |w| {
            column(w, "pages", "title") == listed(&c[1])
        })
    });
    steps.step(&format!("{Q} is a subpage of {Q}"), |world, c, _| {
        let space = current(world)?;
        look(world, &space)?;
        let child = id_of_page(world, &c[0])?;
        let parent = id_of_page(world, &c[1])?;
        expect_shown(
            world,
            &format!("{} to sit inside {}", c[0], c[1]),
            move |w| {
                let pages = rows_of(w, "pages");
                match (row_of(&pages, &child), row_of(&pages, &parent)) {
                    (Some(row), Some(above)) => {
                        row_text(&row, "parentPageId") == parent
                            && row.get("depth").and_then(Value::as_i64)
                                == above.get("depth").and_then(Value::as_i64).map(|d| d + 1)
                    }
                    _ => false,
                }
            },
        )
    });
    steps.step(&format!("{Q} is not inside another page"), |world, c, _| {
        let space = current(world)?;
        look(world, &space)?;
        let page = id_of_page(world, &c[0])?;
        expect_shown(
            world,
            &format!("{} to sit at the top of the Space", c[0]),
            move |w| {
                row_of(&rows_of(w, "pages"), &page).is_some_and(|row| {
                    row_text(&row, "parentPageId").is_empty()
                        && row.get("depth").and_then(Value::as_i64) == Some(0)
                })
            },
        )
    });
    steps.step(
        &format!("the user renames the page {Q} to {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.page.rename", json!({"title": c[1]}))
        },
    );
    steps.step(
        &format!("the user moves the page {Q} to the top of the Space"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.page.move", json!({"parentPageId": ""}))
        },
    );
    steps.step(
        &format!("the user moves the page {Q} into {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            let parent = id_of_page(world, &c[1])?;
            act_on_page(
                world,
                &page,
                "space.page.move",
                json!({"parentPageId": parent}),
            )
        },
    );
    steps.step(&format!("the page {Q} reads {Q}"), |world, c, _| {
        given_block(world, &c[0], "paragraph", &c[1], false)
    });
    steps.step("the MC restarts", |world, _, _| {
        let space = current(world)?;
        look(world, &space)?;
        world.mc.part::<crate::steps::stream::FakeStreams>().handle = "log-2.1".into();
        world.mc.drop_connection();
        world.wait_for("the shell to see the MC go", |w| {
            w.client().phase() != hal_c2_shell::mc::Phase::Ready
        })
    });
    steps.step(&format!("the page {Q} still reads {Q}"), |world, c, _| {
        world.wait_for("the shell to reconnect", |w| {
            w.client().phase() == hal_c2_shell::mc::Phase::Ready
        })?;
        let page = id_of_page(world, &c[0])?;
        look_at_page(world, &page)?;
        expect_shown(world, &format!("{} to read {}", c[0], c[1]), move |w| {
            block_texts(w).contains(&c[1])
        })
    });

    // Trash.
    steps.step(
        &format!("the user moves the page {Q} to the trash"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.page.trash", json!({}))
        },
    );
    steps.step(&format!("the page {Q} is in the trash"), |world, c, _| {
        let page = given_page(world, &c[0], "")?;
        given(world, "page.trash", json!({"pageId": page})).map(|_| ())
    });
    steps.step(&format!("the trash of {Q} holds {Q}"), |world, c, _| {
        let id = id_of_space(world, &c[0])?;
        look(world, &id)?;
        expect_shown(world, &format!("the trash to hold {}", c[1]), |w| {
            let mut held = column(w, "trash", "title");
            held.extend(column(w, "deckTrash", "title"));
            held == listed(&c[1])
        })
    });
    steps.step(&format!("the user restores the page {Q}"), |world, c, _| {
        let page = id_of_page(world, &c[0])?;
        act_on_page(world, &page, "space.page.restore", json!({}))
    });
    steps.step(
        &format!("the user writes {Q} on the page {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[1])?;
            act_on_page(
                world,
                &page,
                "space.block.insert",
                json!({"kind": "paragraph", "text": c[0]}),
            )
        },
    );
    steps.step(
        &format!("the user deletes the page {Q} for good"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.page.delete", json!({}))
        },
    );
    steps.step(
        &format!("no blocks or comments of {Q} or {Q} remain"),
        |world, c, _| {
            let gone: Vec<String> = [&c[0], &c[1]]
                .iter()
                .map(|title| {
                    fake::fake(&mut world.mc)
                        .named
                        .get(&format!("page\n{title}"))
                        .cloned()
                        .unwrap_or_default()
                })
                .collect();
            let space = current(world)?;
            look(world, &space)?;
            let mut left: Vec<String> = Vec::new();
            for (kind, name) in [("page", "space"), ("block", "space"), ("comment", "space")] {
                let _ = name;
                let entities = fake::all(&mut world.mc, &fake::stream_of(&space), kind);
                for entity in entities {
                    let page_ref = if kind == "page" {
                        text(&entity["id"])
                    } else {
                        text(&entity["pageId"])
                    };
                    if gone.contains(&page_ref) {
                        left.push(format!("{kind} {}", show(&entity)));
                    }
                }
            }
            expect!(
                left.is_empty(),
                "the client still holds {}",
                left.join("; ")
            );
            Ok(())
        },
    );

    // Blocks.
    steps.step(
        &format!("the user adds a (paragraph|heading|checklist|callout) block {Q} to {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[2])?;
            act_on_page(
                world,
                &page,
                "space.block.insert",
                json!({"kind": c[0], "text": c[1]}),
            )
        },
    );
    steps.step(
        &format!("{Q} has a (paragraph|heading|checklist|callout) block {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            look_at_page(world, &page)?;
            expect_shown(world, &format!("a {} block {}", c[1], c[2]), move |w| {
                rows_of(w, "blocks")
                    .iter()
                    .any(|row| row_text(row, "kind") == c[1] && row_text(row, "text") == c[2])
            })
        },
    );
    steps.step(&format!("the user links {Q} from {Q}"), |world, c, _| {
        let linked = id_of_page(world, &c[0])?;
        let page = id_of_page(world, &c[1])?;
        act_on_page(
            world,
            &page,
            "space.block.insert",
            json!({"kind": "subpage_link", "text": c[0], "linkedPageId": linked}),
        )
    });
    steps.step(&format!("{Q} links to {Q}"), |world, c, _| {
        let page = id_of_page(world, &c[0])?;
        let linked = id_of_page(world, &c[1])?;
        look_at_page(world, &page)?;
        expect_shown(world, &format!("{} to link to {}", c[0], c[1]), move |w| {
            rows_of(w, "blocks").iter().any(|row| {
                row_text(row, "kind") == "subpage_link" && row_text(row, "linkedPageId") == linked
            })
        })
    });
    steps.step(
        &format!("the user makes the subpage {Q} from a link on {Q}"),
        |world, c, _| {
            let parent = id_of_page(world, &c[1])?;
            act_on_page(
                world,
                &parent,
                "space.page.create",
                json!({"title": c[0], "parentPageId": parent, "link": true}),
            )
        },
    );
    steps.step(&format!("{Q} has the blocks {Q}"), |world, c, _| {
        for said in listed(&c[1]) {
            given_block(world, &c[0], "paragraph", &said, false)?;
        }
        Ok(())
    });
    steps.step(&format!("{Q} has the checklist item {Q}"), |world, c, _| {
        given_block(world, &c[0], "checklist", &c[1], false)
    });
    steps.step(
        &format!("the user adds {Q} after {Q} on {Q}"),
        |world, c, _| {
            let after = block_saying(world, &c[1])?;
            let page = id_of_page(world, &c[2])?;
            act_on_page(
                world,
                &page,
                "space.block.insert",
                json!({
                    "kind": "paragraph",
                    "text": c[0],
                    "afterBlockId": text(&after["id"]),
                }),
            )
        },
    );
    steps.step(&format!("the blocks of {Q} read {Q}"), |world, c, _| {
        let page = id_of_page(world, &c[0])?;
        look_at_page(world, &page)?;
        expect_shown(world, &format!("the blocks to read {}", c[1]), move |w| {
            block_texts(w) == listed(&c[1])
        })
    });
    steps.step(
        &format!("the user changes the block {Q} to {Q}"),
        |world, c, _| act_on_block(world, &c[0], "space.block.update", json!({"text": c[1]})),
    );
    steps.step(&format!("{Q} is ticked"), |world, c, _| {
        ticked(world, &c[0], true)
    });
    steps.step(&format!("{Q} is not ticked"), |world, c, _| {
        ticked(world, &c[0], false)
    });
    steps.step(
        &format!("the user moves the block {Q} before {Q}"),
        |world, c, _| {
            let block = block_saying(world, &c[0])?;
            let before = block_saying(world, &c[1])?;
            let page = text(&block["pageId"]);
            look_at_page(world, &page)?;
            let space = current(world)?;
            let rows = fake::blocks_of(&mut world.mc, &space, &page);
            let at = rows
                .iter()
                .position(|b| text(&b["id"]) == text(&before["id"]))
                .unwrap_or(0);
            let after = if at == 0 {
                Value::Null
            } else {
                json!(text(&rows[at - 1]["id"]))
            };
            // What the move changes, on the MC and in the client's rows.
            let space = current(world)?;
            fake::fake(&mut world.mc).mark = world
                .mc
                .part::<crate::steps::stream::FakeStreams>()
                .log
                .get(&fake::stream_of(&space))
                .map_or(0, Vec::len);
            if let Ok(Some(rows)) = with_space(world, |s, _| s.rows_object("blocks")) {
                rows.clear_changes();
            }
            act_on_block(
                world,
                &c[0],
                "space.block.move",
                json!({"afterBlockId": after}),
            )
        },
    );
    steps.step(&format!("only the block {Q} changed"), |world, c, _| {
        let block = block_saying(world, &c[0])?;
        let id = text(&block["id"]);
        let space = current(world)?;
        let mark = fake::fake(&mut world.mc).mark;
        let log: Vec<(String, String)> = world
            .mc
            .part::<crate::steps::stream::FakeStreams>()
            .log
            .get(&fake::stream_of(&space))
            .into_iter()
            .flat_map(|changes| changes.iter().skip(mark))
            .map(|change| (change.kind.clone(), change.id.clone()))
            .collect();
        expect!(!log.is_empty(), "the MC wrote nothing");
        for (kind, changed) in &log {
            expect!(
                kind == "block" && changed == &id,
                "the MC also wrote the {kind} {changed}"
            );
        }
        let rows = with_space(world, |s, _| {
            s.rows_object("blocks").map(|rows| rows.changes())
        })?
        .unwrap_or_default();
        expect!(
            rows == vec![format!("moved {id}")],
            "the client's blocks: {rows:?}"
        );
        Ok(())
    });
    steps.step(&format!("the user deletes the block {Q}"), |world, c, _| {
        act_on_block(world, &c[0], "space.block.delete", json!({}))
    });

    // Comments.
    steps.step(
        &format!("the user comments {Q} on the block {Q}"),
        |world, c, _| act_on_block(world, &c[1], "space.comment.add", json!({"body": c[0]})),
    );
    steps.step(
        &format!("the block {Q} has the open comment {Q}"),
        |world, c, _| {
            let block = block_saying(world, &c[0])?;
            look_at_page(world, &text(&block["pageId"]))?;
            expect_shown(world, &format!("the comment {}", c[1]), move |w| {
                rows_of(w, "comments").iter().any(|row| {
                    row_text(row, "body") == c[1]
                        && row.get("resolved").and_then(Value::as_bool) != Some(true)
                })
            })
        },
    );
    steps.step(
        &format!("the comment {Q} on the block {Q}"),
        |world, c, _| {
            let block = block_saying(world, &c[1])?;
            given(
                world,
                "comment.add",
                json!({
                    "pageId": text(&block["pageId"]),
                    "blockId": text(&block["id"]),
                    "body": c[0],
                }),
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the user resolves the comment {Q}"),
        |world, c, _| {
            let comment = id_of_comment(world, &c[0])?;
            let space = current(world)?;
            let page = text(
                &fake::one(&mut world.mc, &fake::stream_of(&space), "comment", &comment)["pageId"],
            );
            look_at_page(world, &page)?;
            act(
                world,
                "space.comment.resolve",
                json!({"commentId": comment}),
            )
        },
    );
    steps.step(
        &format!("the user reopens the comment {Q}"),
        |world, c, _| {
            let comment = id_of_comment(world, &c[0])?;
            let space = current(world)?;
            let page = text(
                &fake::one(&mut world.mc, &fake::stream_of(&space), "comment", &comment)["pageId"],
            );
            look_at_page(world, &page)?;
            act(world, "space.comment.reopen", json!({"commentId": comment}))
        },
    );
    steps.step(&format!("the comment {Q} is resolved"), |world, c, _| {
        expect_shown(world, "the comment to be resolved", move |w| {
            rows_of(w, "comments").iter().any(|row| {
                row_text(row, "body") == c[0]
                    && row.get("resolved").and_then(Value::as_bool) == Some(true)
            })
        })
    });
    steps.step(
        &format!("the comment {Q} is resolved already"),
        |world, c, _| {
            let comment = id_of_comment(world, &c[0])?;
            given(world, "comment.resolve", json!({"commentId": comment})).map(|_| ())
        },
    );

    register_rest(steps);
}

pub fn ticked(world: &mut World, said: &str, wanted: bool) -> Outcome {
    let block = block_saying(world, said)?;
    let id = text(&block["id"]);
    look_at_page(world, &text(&block["pageId"]))?;
    expect_shown(
        world,
        &format!(
            "\"{said}\" to be {}",
            if wanted { "ticked" } else { "unticked" }
        ),
        move |w| {
            // What the MC wrote, not only what the user asked for.
            w.with::<Space, _>(|s, _| {
                let row = row_of(&s.rows("blocks"), &id);
                row.as_ref()
                    .is_some_and(|row| row.get("checked").and_then(Value::as_bool) == Some(wanted))
                    && !s.pending(&id, "checked")
                    && s.stream_entity("space", "block", &id)
                        .get("checked")
                        .and_then(Value::as_bool)
                        == Some(wanted)
            })
            .unwrap_or(false)
        },
    )
}

/// The title was said to the user, in a toast.
pub fn told_of(world: &World, start: &str) -> bool {
    world.state("toasts")["items"]
        .as_array()
        .is_some_and(|items| {
            items
                .iter()
                .any(|item| text(&item["title"]).starts_with(start))
        })
}

pub fn find_deck(world: &mut World, title: &str) -> Outcome<String> {
    let space = current(world)?;
    for deck in fake::all(&mut world.mc, &fake::stream_of(&space), "deck") {
        if text(&deck["title"]) == title {
            return Ok(text(&deck["id"]));
        }
    }
    Ok(String::new())
}

pub fn id_of_deck(world: &mut World, title: &str) -> Outcome<String> {
    let id = find_deck(world, title)?;
    if id.is_empty() {
        fail!("the Space has no deck {title}")
    } else {
        Ok(id)
    }
}

pub fn given_deck(world: &mut World, title: &str) -> Outcome<String> {
    let id = find_deck(world, title)?;
    if !id.is_empty() {
        return Ok(id);
    }
    let made = given(world, "deck.create", json!({"title": title}))?;
    Ok(text(&made["deck"]["id"]))
}

pub fn look_at_deck(world: &mut World, id: &str) -> Outcome {
    let space = current(world)?;
    look(world, &space)?;
    let deck = id.to_owned();
    expect_shown(world, "the Space's copy to hold the deck", move |w| {
        w.with::<Space, _>(|s, _| !s.stream_entity("space", "deck", &deck).is_empty())
            .unwrap_or(false)
    })?;
    world.dispatch("space.selectDeck", json!({"deckId": id}))?;
    let deck = id.to_owned();
    expect_shown(world, "the deck to open", move |w| {
        w.with::<Space, _>(|s, _| s.deck_id() == deck)
            .unwrap_or(false)
    })
}

pub fn act_on_deck(world: &mut World, title: &str, action: &str, mut payload: Value) -> Outcome {
    let id = id_of_deck(world, title)?;
    look_at_deck(world, &id)?;
    payload["deckId"] = json!(id);
    act(world, action, payload)
}

/// The window of the second client, a second window with its own Space view.
pub fn second(world: &World) -> Outcome<String> {
    match controller::windows(world.engine()).get(1) {
        Some(window) => Ok(window.clone()),
        None => fail!("no second client is watching"),
    }
}

/// Runs `f` on the second client's Space view.
pub fn with_second<R>(world: &World, f: impl FnOnce(&mut Space, &Engine) -> R) -> Outcome<R> {
    let window = second(world)?;
    let engine = world.engine().clone();
    controller::in_window(&engine, &window, || {
        controller::with::<Space, R>(&engine, f)
    })
    .flatten()
    .ok_or_else(|| Failure("the second client's Space view is busy".into()))
}

fn in_second(world: &mut World, action: &str, payload: Value) -> Outcome {
    let window = second(world)?;
    let engine = world.engine().clone();
    let Some(bridge) = controller::window_bridge(&engine, &window) else {
        fail!("the second client's window closed")
    };
    bridge.dispatch(&engine, action, payload);
    if let Some(main) = controller::window_bridge(&engine, controller::MAIN) {
        main.set_front(&engine);
    }
    world.pump()
}

/// A second client following the Spaces, and the Space `id` when there is one.
pub fn watch(world: &mut World, id: &str) -> Outcome {
    if controller::windows(world.engine()).len() < 2 {
        // The headless opener shows nothing: the window is its controllers.
        controller::set_window_opener(world.engine(), |_, _| {});
        world.dispatch("window.new", json!({}))?;
        world.pump()?;
    }
    second(world)?;
    in_second(world, "space.open", json!({}))?;
    world.wait_for_with(
        |w| {
            with_second(w, |s, _| {
                s.stream_live("index") && !s.rows("spaces").is_empty()
            })
            .unwrap_or(false)
        },
        |w| format!("the second client to follow the Spaces; {}", describe(w)),
    )?;
    if id.is_empty() {
        return Ok(());
    }
    in_second(world, "space.select", json!({"spaceId": id}))?;
    let on = id.to_owned();
    world.wait_for_with(
        move |w| {
            with_second(w, |s, _| s.space_id() == on && s.stream_live("space")).unwrap_or(false)
        },
        |_| "the second client did not follow the Space".to_owned(),
    )
}

/// What the second client lists in `rows` under `field`.
fn second_column(world: &World, rows: &str, field: &str) -> Vec<String> {
    with_second(world, |s, _| {
        s.rows(rows)
            .iter()
            .map(|row| row_text(row, field))
            .collect()
    })
    .unwrap_or_default()
}

/// Who the page shows as on it besides the user, devices and agents.
fn viewers_of(world: &World) -> (Vec<String>, Vec<String>) {
    let viewers = with_space(world, |s, _| s.viewers()).unwrap_or_default();
    let strings = |key: &str| -> Vec<String> {
        viewers
            .get(key)
            .and_then(Value::as_array)
            .map(|list| list.iter().map(text).collect())
            .unwrap_or_default()
    };
    (strings("devices"), strings("agents"))
}

fn shows(world: &mut World, devices: Vec<String>, agents: Vec<String>) -> Outcome {
    let what = format!(
        "the page to show the devices {} and the agents {}",
        devices.join(","),
        agents.join(",")
    );
    expect_shown(world, &what, move |w| {
        viewers_of(w) == (devices.clone(), agents.clone())
    })
}

fn arrive(world: &mut World, device: &str, title: &str) -> Outcome {
    let page = id_of_page(world, title)?;
    fake::fake(&mut world.mc)
        .devices
        .entry(page.clone())
        .or_default()
        .push(device.to_owned());
    fake::show_viewers(&mut world.mc, &page);
    world.sync()
}

fn gone(world: &mut World, device: &str) -> Outcome {
    let pages: Vec<String> = {
        let spaces = fake::fake(&mut world.mc);
        let mut left = Vec::new();
        for (page, devices) in spaces.devices.iter_mut() {
            let had = devices.len();
            devices.retain(|d| d != device);
            if devices.len() != had {
                left.push(page.clone());
            }
        }
        left
    };
    for page in pages {
        fake::show_viewers(&mut world.mc, &page);
    }
    world.sync()
}

/// The page `title`'s agent as the MC has it.
pub fn asked_on(world: &mut World, title: &str) -> Outcome<Value> {
    let space = current(world)?;
    let page = id_of_page(world, title)?;
    Ok(fake::one(
        &mut world.mc,
        &fake::stream_of(&space),
        "pageAgent",
        &page,
    ))
}

/// That the page `title`, open, says of its agent what `says` wants.
pub fn expect_agent(
    world: &mut World,
    title: &str,
    wanted: &str,
    says: impl Fn(&Row) -> bool + 'static,
) -> Outcome {
    let page = id_of_page(world, title)?;
    look_at_page(world, &page)?;
    world.wait_for_with(
        move |w| with_space(w, |s, e| says(&s.agent(e))).unwrap_or(false),
        |w| {
            let agent = with_space(w, |s, e| s.agent(e)).unwrap_or_default();
            format!(
                "the page's agent to be {wanted}, it says {}",
                show(&Value::Object(agent))
            )
        },
    )
}

fn field_is(row: &Row, field: &str, value: &str) -> bool {
    row.get(field).map(text).as_deref() == Some(value)
}

fn flag(row: &Row, field: &str) -> bool {
    row.get(field).and_then(Value::as_bool).unwrap_or(false)
}

/// Sets fields of the page `title`'s agent on the MC.
fn agent_says(world: &mut World, title: &str, mut fields: Value) -> Outcome {
    let space = current(world)?;
    let page = id_of_page(world, title)?;
    if fields.get("endedAt").is_some() {
        fields["endedAt"] = json!(fake::stamp(&mut world.mc));
    }
    fake::set(
        &mut world.mc,
        &fake::stream_of(&space),
        "pageAgent",
        &page,
        fields,
    );
    world.sync()
}

pub fn settle_history(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| with_space(w, |s, _| !s.history().loading()).unwrap_or(false),
        |w| format!("the history to come; {}", describe(w)),
    )
}

/// The history of the page `id`, open beside it.
pub fn show_history(world: &mut World, id: &str) -> Outcome {
    look_at_page(world, id)?;
    if with_space(world, |s, _| s.history().page_id().to_owned())? != id {
        act(world, "space.history.open", json!({"pageId": id}))?;
    }
    settle_history(world)
}

fn versions(world: &World) -> Vec<Row> {
    with_space(world, |s, _| s.history().versions()).unwrap_or_default()
}

pub fn history_blocks(world: &World) -> Vec<Row> {
    with_space(world, |s, _| s.history_blocks()).unwrap_or_default()
}

/// The version `back` versions before the newest of the page `title`.
pub fn version_back(world: &mut World, title: &str, back: usize) -> Outcome<Value> {
    let page = id_of_page(world, title)?;
    show_history(world, &page)?;
    world.wait_for_with(
        move |w| versions(w).len() > back,
        move |w| {
            format!(
                "{} versions; {}",
                back + 1,
                show(&Value::Array(
                    versions(w).into_iter().map(Value::Object).collect()
                ))
            )
        },
    )?;
    Ok(versions(world)[back]
        .get("version")
        .cloned()
        .unwrap_or(Value::Null))
}

pub fn read_version(world: &mut World, version: Value) -> Outcome {
    act(world, "space.history.read", json!({"version": version}))?;
    world.wait_for_with(
        |w| with_space(w, |s, _| !s.history().version().is_empty()).unwrap_or(false),
        |w| format!("the version to come; {}", describe(w)),
    )
}

pub fn version_image(world: &World, said: &str) -> Row {
    history_blocks(world)
        .into_iter()
        .find(|block| field_is(block, "kind", "image") && field_is(block, "text", said))
        .unwrap_or_default()
}

/// That the page `title`, open, shows of its site what `shown` wants.
pub fn expect_site(
    world: &mut World,
    title: &str,
    wanted: &str,
    shown: impl Fn(&Map<String, Value>) -> bool + 'static,
) -> Outcome {
    let page = id_of_page(world, title)?;
    look_at_page(world, &page)?;
    let what = format!("{title} to {wanted}");
    expect_shown(world, &what, move |w| {
        let site = with_space(w, |s, e| s.page(e).get("site").cloned()).unwrap_or_default();
        shown(
            site.as_ref()
                .and_then(Value::as_object)
                .unwrap_or(&Map::new()),
        )
    })
}

/// The link the page was last published on, working or not.
pub fn link_of(world: &mut World, title: &str) -> Outcome<String> {
    let page = id_of_page(world, title)?;
    let link = fake::fake(&mut world.mc)
        .links
        .get(&page)
        .cloned()
        .unwrap_or_default();
    if link.is_empty() {
        fail!("the page {title} was never published")
    } else {
        Ok(link)
    }
}

fn site_of_page(world: &mut World, title: &str) -> Outcome<Value> {
    let space = current(world)?;
    let page = id_of_page(world, title)?;
    Ok(fake::site_of_page(&mut world.mc, &space, &page))
}

/// The rows of a page's blocks, as the feature's tables write them.
pub fn block_table(world: &World) -> Vec<Vec<String>> {
    rows_of(world, "blocks")
        .iter()
        .map(|block| {
            let item = field_is(block, "kind", "checklist");
            vec![
                row_text(block, "kind"),
                row_text(block, "text"),
                if item {
                    if flag(block, "checked") { "yes" } else { "no" }.to_owned()
                } else {
                    String::new()
                },
            ]
        })
        .collect()
}

fn register_more(steps: &mut Steps) {
    // A page's agent.
    steps.step(
        &format!("the user asks {Q} on the page {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[1])?;
            let engine = world.engine().clone();
            let kept: std::rc::Rc<std::cell::RefCell<Option<String>>> = Default::default();
            let heard = kept.clone();
            hal_c2_shell::controllers::space::on_agent_ask_answered(
                &engine,
                move |_, _, request, taken| {
                    if !taken {
                        *heard.borrow_mut() = Some(request.to_owned());
                    }
                },
            );
            act_on_page(world, &page, "space.agent.ask", json!({"request": c[0]}))?;
            if let Some(words) = kept.borrow_mut().take() {
                fake::fake(&mut world.mc).kept_words = words;
            }
            Ok(())
        },
    );
    steps.step("the MC refuses the next ask", |world, _, _| {
        fake::fake(&mut world.mc).refuse_ask = true;
        Ok(())
    });
    steps.step(
        &format!("the words {Q} are kept to ask again"),
        |world, c, _| {
            let kept = fake::fake(&mut world.mc).kept_words.clone();
            expect!(kept == c[0], "the words kept are \"{kept}\"");
            Ok(())
        },
    );
    steps.step(
        &format!("the agent of {Q} does not stop when asked"),
        |world, _, _| {
            fake::fake(&mut world.mc).ignores_stop = true;
            Ok(())
        },
    );
    steps.step(&format!("{Q} says its agent is stopping"), |world, c, _| {
        expect_agent(world, &c[0], "stopping", |a| {
            field_is(a, "status", "stopping")
        })
    });
    steps.step(
        &format!("the user can stop the agent of {Q} again"),
        |world, c, _| {
            let before = fake::fake(&mut world.mc).stops;
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.agent.stop", json!({}))?;
            for _ in 0..50 {
                if fake::fake(&mut world.mc).stops == before + 1 {
                    return Ok(());
                }
                world.sync()?;
            }
            fail!("a second stop to reach the MC")
        },
    );
    steps.step(
        &format!("the thread of the agent of {Q} is deleted"),
        |world, c, _| {
            agent_says(
                world,
                &c[0],
                json!({"status": "stopped", "error": "its thread was deleted", "endedAt": ""}),
            )
        },
    );
    steps.step(
        &format!("{Q} says its agent stopped because {Q}"),
        |world, c, _| {
            let why = c[1].clone();
            expect_agent(world, &c[0], &format!("stopped because {why}"), move |a| {
                field_is(a, "status", "stopped") && field_is(a, "error", &why)
            })
        },
    );
    steps.step(
        &format!("{Q} says its agent is working on {Q}"),
        |world, c, _| {
            let on = c[1].clone();
            expect_agent(world, &c[0], &format!("working on {on}"), move |a| {
                field_is(a, "status", "running") && field_is(a, "request", &on)
            })
        },
    );
    steps.step(
        &format!("{Q} links to its agent's thread"),
        |world, c, _| {
            let thread = text(&asked_on(world, &c[0])?["threadId"]);
            let wanted = thread.clone();
            expect_agent(world, &c[0], "linked to its thread", move |a| {
                field_is(a, "threadId", &wanted) && field_is(a, "threadTitle", "Page agent")
            })?;
            act(world, "space.agent.openThread", json!({}))?;
            let key = text(&world.state("route")["threadKey"]);
            expect!(
                key.ends_with(&format!(":{thread}")),
                "the link opened {key}"
            );
            let page = id_of_page(world, &c[0])?;
            look_at_page(world, &page)
        },
    );
    steps.step(
        &format!("the agent of {Q} names a thread this client does not have"),
        |world, c, _| agent_says(world, &c[0], json!({"threadId": "gone"})),
    );
    steps.step(
        &format!("the user follows the agent of {Q} to its thread"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            look_at_page(world, &page)?;
            act(world, "space.agent.openThread", json!({}))
        },
    );
    steps.step(
        "the user is told the agent's thread is not available",
        |world, _, _| {
            expect!(
                told_of(world, "The agent's thread is not available."),
                "the user is not told: {}",
                show(&world.state("toasts"))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the agent of {Q} adds the block {Q}"),
        |world, c, _| {
            let space = current(world)?;
            let page = id_of_page(world, &c[0])?;
            let author = fake::agent_author(&text(&asked_on(world, &c[0])?["threadId"]));
            fake::insert_block(
                &mut world.mc,
                &space,
                &page,
                &json!({"kind": "paragraph", "text": c[1], "checked": false}),
                &fake::After::Absent,
                &author,
            );
            fake::note_edits(&mut world.mc, &space, &author);
            fake::set(
                &mut world.mc,
                &fake::stream_of(&space),
                "pageAgent",
                &page,
                json!({"edited": true}),
            );
            world.sync()
        },
    );
    steps.step(
        &format!("the block {Q} was written by the agent of {Q}"),
        |world, c, _| {
            let block = block_saying(world, &c[0])?;
            let author = fake::agent_author(&text(&asked_on(world, &c[1])?["threadId"]));
            expect!(
                block["createdBy"] == author,
                "the block says {}",
                show(&block)
            );
            Ok(())
        },
    );
    steps.step(&format!("the agent of {Q} finishes"), |world, c, _| {
        agent_says(world, &c[0], json!({"status": "completed", "endedAt": ""}))
    });
    steps.step(
        &format!("the agent of {Q} fails with {Q}"),
        |world, c, _| {
            agent_says(
                world,
                &c[0],
                json!({"status": "failed", "error": c[1], "endedAt": ""}),
            )
        },
    );
    steps.step(
        &format!("the user stops the agent of {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.agent.stop", json!({}))
        },
    );
    steps.step(
        &format!("the user dismisses the agent of {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.agent.dismiss", json!({}))
        },
    );
    steps.step(
        &format!("{Q} says its agent finished and changed the page"),
        |world, c, _| {
            expect_agent(world, &c[0], "finished with changes", |a| {
                field_is(a, "status", "completed") && flag(a, "edited")
            })
        },
    );
    steps.step(
        &format!("{Q} says its agent finished without changing the page"),
        |world, c, _| {
            expect_agent(world, &c[0], "finished without changes", |a| {
                field_is(a, "status", "completed") && !flag(a, "edited")
            })
        },
    );
    steps.step(&format!("{Q} says its agent was stopped"), |world, c, _| {
        expect_agent(world, &c[0], "stopped", |a| {
            field_is(a, "status", "stopped")
        })
    });
    steps.step(
        &format!("{Q} says its agent failed with {Q}"),
        |world, c, _| {
            let why = c[1].clone();
            expect_agent(world, &c[0], &format!("failed with {why}"), move |a| {
                field_is(a, "status", "failed") && field_is(a, "error", &why)
            })
        },
    );
    steps.step(
        &format!("{Q} says nothing about an agent"),
        |world, c, _| expect_agent(world, &c[0], "saying nothing", Row::is_empty),
    );

    // A page's history.
    steps.step("a while passes", |world, _, _| {
        fake::fake(&mut world.mc).paused = true;
        Ok(())
    });
    steps.step(
        &format!("the agent in {Q} adds the block {Q} to {Q}"),
        |world, c, _| {
            let space = current(world)?;
            let author = fake::agent_author(&thread_named(world, &c[0])?);
            let page = id_of_page(world, &c[2])?;
            fake::insert_block(
                &mut world.mc,
                &space,
                &page,
                &json!({"kind": "paragraph", "text": c[1], "checked": false}),
                &fake::After::Absent,
                &author,
            );
            fake::note_edits(&mut world.mc, &space, &author);
            world.sync()
        },
    );
    steps.step(
        &format!("the user opens the history of {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            show_history(world, &page)
        },
    );
    steps.step("the history has (\\d+) versions?", |world, c, _| {
        let count: usize = c[0].parse().unwrap_or(0);
        expect_shown(
            world,
            &format!("the history to have {count} versions"),
            move |w| versions(w).len() == count,
        )
    });
    steps.step(
        "each version says when it was written and by the user",
        |world, _, _| {
            for row in versions(world) {
                expect!(
                    !row_text(&row, "at").is_empty()
                        && !flag(&row, "byAgent")
                        && !flag(&row, "byUpdate"),
                    "a version says {}",
                    show(&Value::Object(row.clone()))
                );
            }
            Ok(())
        },
    );
    steps.step(
        "the newest version is the page as it is now",
        |world, _, _| {
            let newest = versions(world)
                .first()
                .and_then(|row| row.get("version").cloned());
            read_version(world, newest.unwrap_or(Value::Null))?;
            let read: Vec<String> = history_blocks(world)
                .iter()
                .map(|b| row_text(b, "text"))
                .collect();
            expect!(
                read == block_texts(world),
                "the newest version reads {read:?}"
            );
            act(world, "space.history.back", json!({}))
        },
    );
    steps.step(
        &format!("the newest version was written by the thread {Q}"),
        |world, c, _| {
            let newest = versions(world).first().cloned().unwrap_or_default();
            expect!(
                flag(&newest, "byAgent") && field_is(&newest, "threadTitle", &c[0]),
                "the newest version says {}",
                show(&Value::Object(newest.clone()))
            );
            Ok(())
        },
    );
    steps.step(
        "the newest version was written by the page's update",
        |world, _, _| {
            let newest = versions(world).first().cloned().unwrap_or_default();
            expect!(
                flag(&newest, "byUpdate") && !flag(&newest, "byAgent"),
                "the newest version says {}",
                show(&Value::Object(newest.clone()))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user reads the version (\\d+) back on {Q}"),
        |world, c, _| {
            let version = version_back(world, &c[1], c[0].parse().unwrap_or(0))?;
            read_version(world, version)
        },
    );
    steps.step(&format!("the version reads {Q}"), |world, c, _| {
        let read: Vec<String> = history_blocks(world)
            .iter()
            .map(|b| row_text(b, "text"))
            .collect();
        expect!(read == listed(&c[0]), "the version reads {read:?}");
        Ok(())
    });
    steps.step(
        &format!("the version draws a chart of {Q} (\\d+) and {Q} (\\d+)"),
        |world, c, _| {
            let labels = json!([c[0], c[2]]);
            let number = |s: &str| s.parse::<f64>().unwrap_or(0.0);
            let values = json!([number(&c[1]), number(&c[3])]);
            for row in history_blocks(world) {
                if !field_is(&row, "kind", "chart") {
                    continue;
                }
                let chart = row.get("chart").cloned().unwrap_or_default();
                let got: Vec<f64> = chart["series"][0]["values"]
                    .as_array()
                    .map(|v| v.iter().filter_map(Value::as_f64).collect())
                    .unwrap_or_default();
                expect!(
                    chart["labels"] == labels && json!(got) == values,
                    "the version's chart reads {}",
                    show(&chart["labels"])
                );
                return Ok(());
            }
            fail!("no chart in the version")
        },
    );
    steps.step(
        &format!("the version shows the image {Q}"),
        |world, c, _| {
            let said = c[0].clone();
            expect_shown(
                world,
                &format!("the version to show the image {said}"),
                move |w| {
                    let block = version_image(w, &said);
                    field_is(&block, "imageState", "shown")
                        && row_text(&block, "imageUrl").contains("/assets/space/")
                },
            )
        },
    );
    steps.step(
        &format!("the version says the image {Q} is in the trash"),
        |world, c, _| {
            let said = c[0].clone();
            expect_shown(
                world,
                &format!("the version to say the image {said} is in the trash"),
                move |w| field_is(&version_image(w, &said), "imageState", "trashed"),
            )
        },
    );
    steps.step(
        "the user goes back to the list of versions",
        |world, _, _| act(world, "space.history.back", json!({})),
    );
    steps.step("the history is closed", |world, _, _| {
        expect_shown(world, "the history to close", |w| {
            with_space(w, |s, _| !s.history().shown()).unwrap_or(false)
        })
    });
    steps.step("no version is being read", |world, _, _| {
        let reading = with_space(world, |s, _| s.history().reading())?;
        expect!(
            !reading && history_blocks(world).is_empty(),
            "a version is still being read"
        );
        Ok(())
    });
    steps.step(
        &format!("the user restores the version (\\d+) back on {Q}"),
        |world, c, _| {
            let version = version_back(world, &c[1], c[0].parse().unwrap_or(0))?;
            act(world, "space.history.restore", json!({"version": version}))?;
            settle_history(world)
        },
    );
    steps.step(
        "the newest version says it restored an earlier one",
        |world, _, _| {
            let newest = versions(world).first().cloned().unwrap_or_default();
            expect!(
                !row_text(&newest, "restoredFromAt").is_empty(),
                "the newest version says {}",
                show(&Value::Object(newest.clone()))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the user cannot restore a version of {Q}"),
        |world, c, _| {
            let trashed = with_space(world, |s, e| flag(&s.page(e), "trashed"))?;
            expect!(
                trashed,
                "the page does not say it is in the trash, which takes away its Restore"
            );
            let version = version_back(world, &c[0], 1)?;
            act(world, "space.history.restore", json!({"version": version}))?;
            let error = fake::fake(&mut world.mc).last_error.clone();
            expect!(
                !error.is_empty() && told_of(world, &error),
                "the user is not told the restore was refused; toasts {}",
                show(&world.state("toasts"))
            );
            Ok(())
        },
    );

    // Sites.
    steps.step(
        &format!("the user publishes the page {Q} as a site"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.page.publish", json!({}))
        },
    );
    steps.step(
        &format!("the user publishes the page {Q} over Tailscale"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(
                world,
                &page,
                "space.page.publish",
                json!({"tailscale": true}),
            )
        },
    );
    steps.step(
        &format!("the page {Q} is published as a site"),
        |world, c, _| {
            let page = given_page(world, &c[0], "")?;
            given(world, "page.publish", json!({"pageId": page}))?;
            let link = link_of(world, &c[0])?;
            fake::fake(&mut world.mc)
                .named
                .insert(format!("link\n{}", c[0]), link);
            Ok(())
        },
    );
    steps.step(
        &format!("the user unpublishes the page {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.page.unpublish", json!({}))
        },
    );
    steps.step(
        &format!("the user copies the site link of the page {Q}"),
        |world, c, _| {
            expect_site(world, &c[0], "show it is published", |site| {
                !site.is_empty()
            })?;
            world.set_clipboard("");
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.page.copySiteLink", json!({}))
        },
    );
    steps.step(
        &format!("the site link of the page {Q} is on the clipboard"),
        |world, c, _| {
            let link = link_of(world, &c[0])?;
            let held = world.clipboard();
            expect!(held == link, "the clipboard holds \"{held}\"");
            Ok(())
        },
    );
    steps.step(
        &format!("the page {Q} shows it is published with a link"),
        |world, c, _| {
            let link = link_of(world, &c[0])?;
            expect_site(world, &c[0], "show its link", move |site| {
                site.get("url").map(text).as_deref() == Some(link.as_str())
            })
        },
    );
    steps.step(
        &format!("the page {Q} shows it is not published"),
        |world, c, _| expect_site(world, &c[0], "show it is not published", Map::is_empty),
    );
    // The fake serves no pages, so what stops a link here is its site being gone from the MC.
    steps.step(
        &format!("the site link of the page {Q} no longer opens"),
        |world, c, _| {
            let site = site_of_page(world, &c[0])?;
            expect!(
                site.as_object().is_none_or(Map::is_empty),
                "the MC still has the site of {}",
                c[0]
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the second client sees the page {Q} published"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            let what = format!("the second client to show {} published", c[0]);
            world.wait_for_with(
                move |w| with_second(w, |s, _| !s.site_of(&page).is_empty()).unwrap_or(false),
                move |_| what.clone(),
            )
        },
    );
    steps.step(
        &format!("the page {Q} shows its site is behind"),
        |world, c, _| {
            expect_site(world, &c[0], "show its site is behind", |site| {
                site.get("behind").and_then(Value::as_bool).unwrap_or(false)
            })
        },
    );
    steps.step(
        &format!("the page {Q} shows its site is up to date"),
        |world, c, _| {
            expect_site(world, &c[0], "show its site is up to date", |site| {
                !site.is_empty() && !site.get("behind").and_then(Value::as_bool).unwrap_or(false)
            })
        },
    );
    steps.step(
        &format!("the page {Q} has the same site link"),
        |world, c, _| {
            let earlier = fake::fake(&mut world.mc)
                .named
                .get(&format!("link\n{}", c[0]))
                .cloned()
                .unwrap_or_default();
            expect!(!earlier.is_empty(), "the page {} had no link", c[0]);
            let wanted = format!("keep the link {earlier}");
            expect_site(world, &c[0], &wanted, move |site| {
                site.get("url").map(text).as_deref() == Some(earlier.as_str())
            })
        },
    );
    steps.step("the MC listens only on this machine", |world, _, _| {
        let origin = world.mc.origin();
        let spaces = fake::fake(&mut world.mc);
        spaces.address = origin;
        spaces.local_only = true;
        Ok(())
    });
    steps.step(
        &format!("the page {Q} says only this machine can open its site link"),
        |world, c, _| {
            expect_site(
                world,
                &c[0],
                "say only this machine can open its link",
                |site| {
                    site.get("localOnly")
                        .and_then(Value::as_bool)
                        .unwrap_or(false)
                },
            )
        },
    );
    steps.step(
        &format!("Tailscale names the MC's machine {Q}"),
        |world, c, _| {
            fake::fake(&mut world.mc).tailnet = c[0].clone();
            Ok(())
        },
    );
    steps.step(
        &format!("the site link of the page {Q} starts with {Q}"),
        |world, c, _| {
            let start = c[1].clone();
            expect_site(
                world,
                &c[0],
                &format!("have a link starting with {start}"),
                move |site| {
                    site.get("url")
                        .map(text)
                        .unwrap_or_default()
                        .starts_with(&start)
                },
            )
        },
    );

    // Markdown.
    steps.step(
        &format!("the page {Q} with the blocks:"),
        |world, c, table| {
            for row in table.iter().skip(1) {
                let cell = |i: usize| row.get(i).cloned().unwrap_or_default();
                given_block(world, &c[0], &cell(0), &cell(1), cell(2) == "yes")?;
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the user exports {Q} as Markdown"),
        |world, c, _| {
            world.set_clipboard("");
            let page = id_of_page(world, &c[0])?;
            act_on_page(world, &page, "space.page.copyMarkdown", json!({}))
        },
    );
    steps.step("the Markdown is:", |world, _, doc| {
        let wanted = format!(
            "{}\n",
            doc.first()
                .and_then(|r| r.first())
                .cloned()
                .unwrap_or_default()
        );
        let want = wanted.clone();
        world.wait_for_with(
            move |w| w.clipboard() == want,
            |w| {
                format!(
                    "the clipboard to hold the page; it holds \"{}\"",
                    w.clipboard()
                )
            },
        )?;
        expect!(
            told_of(world, "Page copied as Markdown"),
            "the user is not told: {}",
            show(&world.state("toasts"))
        );
        Ok(())
    });
    steps.step(
        &format!("the user imports this Markdown into {Q}:"),
        |world, c, doc| {
            let space = id_of_space(world, &c[0])?;
            look(world, &space)?;
            let markdown = doc
                .first()
                .and_then(|r| r.first())
                .cloned()
                .unwrap_or_default();
            act(
                world,
                "space.page.importMarkdown",
                json!({"markdown": markdown}),
            )
        },
    );
    steps.step(
        &format!("the page {Q} has the blocks:"),
        |world, c, table| {
            let page = id_of_page(world, &c[0])?;
            let space = current(world)?;
            look(world, &space)?;
            // The page imported is the one the user is shown.
            let on = page.clone();
            expect_shown(world, &format!("{} to open", c[0]), move |w| {
                with_space(w, |s, _| s.page_id() == on).unwrap_or(false)
            })?;
            let wanted: Vec<Vec<String>> = table
                .iter()
                .skip(1)
                .map(|row| {
                    (0..3)
                        .map(|i| row.get(i).cloned().unwrap_or_default())
                        .collect()
                })
                .collect();
            let what = format!("the blocks {wanted:?}");
            expect_shown(world, &what, move |w| block_table(w) == wanted)
        },
    );
}

fn register_rest(steps: &mut Steps) {
    register_more(steps);
    // Who else is on the page.
    steps.step(&format!("the user opens the page {Q}"), |world, c, _| {
        let page = id_of_page(world, &c[0])?;
        look_at_page(world, &page)?;
        let (mut devices, agents) = {
            let spaces = fake::fake(&mut world.mc);
            (
                spaces.devices.get(&page).cloned().unwrap_or_default(),
                spaces.agents.get(&page).cloned().unwrap_or_default(),
            )
        };
        devices.sort();
        expect_shown(world, "the page to hold who is on it", move |w| {
            viewers_of(w) == (devices.clone(), agents.clone())
        })
    });
    steps.step(&format!("the Space's page {Q}"), |world, c, _| {
        given_page(world, &c[0], "").map(|_| ())
    });
    steps.step(&format!("a thread {Q}"), |_, _, _| Ok(()));
    steps.step(
        &format!("the page {Q} is open on the device {Q}"),
        |world, c, _| arrive(world, &c[1], &c[0]),
    );
    steps.step(
        &format!("the device {Q} opens the page {Q}"),
        |world, c, _| arrive(world, &c[0], &c[1]),
    );
    steps.step(
        &format!("the device {Q} leaves the page {Q}"),
        |world, c, _| gone(world, &c[0]),
    );
    steps.step(
        &format!("the connection of the device {Q} drops"),
        |world, c, _| gone(world, &c[0]),
    );
    steps.step(
        &format!("the agent in {Q} is working on the page {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[1])?;
            fake::fake(&mut world.mc)
                .agents
                .entry(page.clone())
                .or_default()
                .push(c[0].clone());
            fake::show_viewers(&mut world.mc, &page);
            world.sync()
        },
    );
    steps.step(
        &format!("the turn of the agent in {Q} ends"),
        |world, c, _| {
            let pages: Vec<String> = {
                let spaces = fake::fake(&mut world.mc);
                let mut left = Vec::new();
                for (page, agents) in spaces.agents.iter_mut() {
                    let had = agents.len();
                    agents.retain(|a| *a != c[0]);
                    if agents.len() != had {
                        left.push(page.clone());
                    }
                }
                left
            };
            for page in pages {
                fake::show_viewers(&mut world.mc, &page);
            }
            world.sync()
        },
    );
    steps.step("the MC can say who is on a page", |_, _, _| Ok(()));
    steps.step(
        "the MC can no longer say who is on a page",
        |world, _, _| {
            fake::fake(&mut world.mc).viewers_refused = true;
            for id in world.mc.subscribers("spacePresence") {
                fake::refuse_viewers(&mut world.mc, id);
            }
            world.sync()
        },
    );
    steps.step("the MC can say who is on a page again", |world, _, _| {
        fake::fake(&mut world.mc).viewers_refused = false;
        Ok(())
    });
    steps.step("the page shows nobody else", |world, _, _| {
        shows(world, Vec::new(), Vec::new())
    });
    steps.step(
        &format!("the page shows the user also on {Q}"),
        |world, c, _| shows(world, vec![c[0].clone()], Vec::new()),
    );
    steps.step(
        &format!("the page shows one person, also on {Q} and {Q}"),
        |world, c, _| shows(world, vec![c[0].clone(), c[1].clone()], Vec::new()),
    );
    steps.step(
        &format!("the page shows the agent of {Q}"),
        |world, c, _| shows(world, Vec::new(), vec![c[0].clone()]),
    );
    steps.step("the user leaves the page", |world, _, _| {
        world.with::<Navigation, _>(|navigation, engine| navigation.open(engine, Route::Usage))?;
        world.sync()
    });
    steps.step(&format!("the user opens the deck {Q}"), |world, c, _| {
        let id = id_of_deck(world, &c[0])?;
        look_at_deck(world, &id)
    });
    steps.step(
        &format!("the user is no longer on the page {Q}"),
        |world, c, _| {
            let page = id_of_page(world, &c[0])?;
            expect_shown(
                world,
                "the client to stop following who is on the page",
                move |w| {
                    !w.mc
                        .subscribers("spacePresence")
                        .into_iter()
                        .any(|id| text(&w.mc.shape_of(id)["pageId"]) == page)
                },
            )?;
            expect!(viewers_of(world).0.is_empty(), "{}", describe(world));
            Ok(())
        },
    );

    // A second client.
    steps.step("a second client watching the Spaces", |world, _, _| {
        watch(world, "")
    });
    steps.step(
        &format!("a second client watching the Space {Q}"),
        |world, c, _| {
            let id = id_of_space(world, &c[0])?;
            watch(world, &id)
        },
    );
    steps.step(
        &format!("the second client sees the Space {Q}"),
        |world, c, _| {
            let want = c[0].clone();
            world.wait_for_with(
                move |w| second_column(w, "spaces", "name").contains(&want),
                |w| {
                    format!(
                        "the second client shows the Spaces {:?}",
                        second_column(w, "spaces", "name")
                    )
                },
            )
        },
    );
    steps.step(
        &format!("the second client sees the block {Q}"),
        |world, c, _| {
            let want = c[0].clone();
            world.wait_for_with(
                move |w| second_column(w, "blocks", "text").contains(&want),
                |w| {
                    format!(
                        "the second client shows the blocks {:?}",
                        second_column(w, "blocks", "text")
                    )
                },
            )
        },
    );
}

/// The Space side of "the user opens": the page `title` of the scenario's
/// Space, false when it has none.
pub fn space_opens(world: &mut World, title: &str) -> Outcome<bool> {
    if fake::fake(&mut world.mc).current.is_empty() {
        return Ok(false);
    }
    let id = find_page(world, title)?;
    if id.is_empty() {
        return Ok(false);
    }
    look_at_page(world, &id)?;
    Ok(true)
}

/// The Space side of "the user ticks": the checklist item `said` on the
/// open page, false when there is none.
pub fn space_tick(world: &mut World, said: &str, checked: bool) -> Outcome<bool> {
    if fake::fake(&mut world.mc).current.is_empty() {
        return Ok(false);
    }
    act_on_block(
        world,
        said,
        "space.block.setChecked",
        json!({"checked": checked}),
    )?;
    Ok(true)
}
