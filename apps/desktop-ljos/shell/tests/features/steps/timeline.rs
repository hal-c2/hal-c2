//! The thread's timeline (features/timeline/*): desktop-qt's
//! TimelineSteps.cpp. The MC's `stream` shape for the open thread is faked
//! in stream.rs; these steps change what it holds and read what the
//! thread's timeline shows of it. The helpers that read the rows are for
//! every domain that drives a thread.

use std::cell::RefCell;
use std::rc::Rc;

use chrono::{Duration, NaiveDate, NaiveTime, TimeZone, Utc};
use hal_c2_shell::thread_view::timeline::{Out, Role};
use hal_c2_shell::thread_view::timeline_model::TimelineModel;
use serde_json::{Value, json};

use super::stream::{
    FakeStreams, PEER, PEER_ENVIRONMENT, PEER_THREAD, PROJECT, add_command, add_item,
    answer_waiting, change, describe, followers, iso, look, look_at_thread, now, read, role,
    sent_since, set, settle_run, start_run, status, timeline_object,
};
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;
use crate::{expect, fail};

/// The addresses the MC signed for a thread's images (`assets.createUrl`),
/// each good for an hour from `at`.
struct FakeAssets {
    at: chrono::DateTime<Utc>,
    signed_ids: Vec<String>,
}

impl Default for FakeAssets {
    fn default() -> FakeAssets {
        FakeAssets {
            at: now(),
            signed_ids: Vec::new(),
        }
    }
}

/// The rows the timeline showed when a step kept them, followed through the
/// changes made after (desktop-qt's QPersistentModelIndex): the position of
/// each, none once it went.
#[derive(Default)]
struct Kept(Rc<RefCell<Vec<Option<usize>>>>);

/// Registered for `assets.`: FilesIdentitySteps answers `assets.createUrl`
/// for a project's favicon and passes every other resource on to here.
fn extension(mc: &mut crate::fake_mc::FakeMc) {
    mc.on_rpc("assets.", |mc, rpc| {
        // A project's favicon is FilesIdentitySteps' to answer, not an image.
        if rpc.method != "assets.createUrl"
            || text(&rpc.payload["resource"]["_tag"]) != "attachment"
        {
            mc.reply(rpc, Value::Null);
            return Ok(());
        }
        let fake = mc.part::<FakeAssets>();
        fake.signed_ids
            .push(text(&rpc.payload["resource"]["attachmentId"]));
        let token = fake.signed_ids.len();
        let expires = fake.at + Duration::seconds(3600);
        mc.reply(
            rpc,
            json!({"relativeUrl": format!("/api/assets/token-{token}/cart.png"),
                   "expiresAt": expires.timestamp_millis() as f64}),
        );
        Ok(())
    });
}

/// Rows of a kind, newest last.
pub fn rows_of(world: &World, kind: &str) -> Outcome<Vec<usize>> {
    let count = super::stream::row_count(world)?;
    Ok((0..count)
        .filter(|row| role(world, *row, "kind") == kind)
        .collect())
}

pub fn last_row_of(world: &World, kind: &str) -> Outcome<usize> {
    let rows = rows_of(world, kind)?;
    match rows.last() {
        Some(row) => Ok(*row),
        None => fail!("no {kind} row; {}", describe(world)),
    }
}

/// The row showing this item.
pub fn row_showing(world: &World, item_id: &str) -> Outcome<usize> {
    for row in 0..super::stream::row_count(world)? {
        if role(world, row, "rowId") == item_id {
            return Ok(row);
        }
        let entries = role(world, row, "entries");
        if entries
            .as_array()
            .into_iter()
            .flatten()
            .any(|entry| entry["id"] == item_id)
        {
            return Ok(row);
        }
    }
    fail!("no row shows {item_id}; {}", describe(world))
}

/// The last call of the last work row.
pub fn last_entry(world: &World) -> Outcome<Value> {
    let row = last_row_of(world, "work")?;
    match role(world, row, "entries")
        .as_array()
        .and_then(|e| e.last())
    {
        Some(entry) => Ok(entry.clone()),
        None => fail!("the work row shows no calls; {}", describe(world)),
    }
}

/// Some row shows this answer.
pub fn expect_answer(world: &World, answer: &str) -> Outcome {
    for row in rows_of(world, "message")? {
        if role(world, row, "text") == answer {
            return Ok(());
        }
    }
    fail!("\"{answer}\" is not shown; {}", describe(world))
}

/// Opens the timeline's views onto the changes it tells, recorded.
fn record(world: &World) -> Outcome<Rc<RefCell<Vec<Out>>>> {
    let told = Rc::new(RefCell::new(Vec::new()));
    let into = told.clone();
    let obj = timeline_object(world)?;
    TimelineModel::observe(world.engine(), obj, move |_, out| {
        into.borrow_mut().push(out.clone())
    });
    Ok(told)
}

/// Where each kept row is after `out`.
fn follow(kept: &mut [Option<usize>], out: &Out) {
    for position in kept.iter_mut() {
        let Some(at) = *position else { continue };
        *position = match out {
            Out::Removed { first, count } if at >= *first && at < first + count => None,
            Out::Removed { first, count } if at >= first + count => Some(at - count),
            Out::Inserted { first, ids } if at >= *first => Some(at + ids.len()),
            Out::Moved { from, to } if at == *from => Some(*to),
            Out::Moved { from, to } if at >= *to && at < *from => Some(at + 1),
            _ => Some(at),
        };
    }
}

fn keep_rows(world: &mut World) -> Outcome {
    let count = super::stream::row_count(world)?;
    let kept = world.part::<Kept>().0.clone();
    *kept.borrow_mut() = (0..count).map(Some).collect();
    let obj = timeline_object(world)?;
    TimelineModel::observe(world.engine(), obj, move |_, out| {
        follow(&mut kept.borrow_mut(), out)
    });
    Ok(())
}

/// The image of the current run's message, once the brick showing it has
/// asked for its address and the MC has signed the `count`th one.
fn expect_image(world: &mut World, name: &str, count: usize) -> Outcome {
    let run = world.mc.part::<FakeStreams>().run.clone();
    let row = row_showing(world, &format!("message:{run}"))?;
    let address = format!(
        "{}/api/assets/token-{count}/cart.png",
        world.mc.origin().trim_end_matches('/')
    );
    let obj = timeline_object(world)?;
    let wanted = name.to_owned();
    let shown = address.clone();
    world.wait_for_with(
        |w| {
            let image = role(w, row, "attachments")
                .as_array()
                .and_then(|a| a.first().cloned())
                .unwrap_or(Value::Null);
            if text(&image["url"]).is_empty() {
                let id = text(&image["id"]);
                TimelineModel::update(w.engine(), obj, |t| t.load_attachment(&id));
            }
            text(&image["name"]) == wanted && text(&image["url"]) == shown
        },
        |w| {
            let image = role(w, row, "attachments")
                .as_array()
                .and_then(|a| a.first().cloned())
                .unwrap_or(Value::Null);
            format!("the image at {address}; the message shows {}", show(&image))
        },
    )?;
    let asked = world.mc.part::<FakeAssets>().signed_ids.clone();
    expect!(
        asked == vec!["image-1".to_owned(); count],
        "the MC signed [{}]",
        asked.join(", ")
    );
    Ok(())
}

fn sent_files(world: &mut World) -> Outcome<Vec<Value>> {
    let run = world.mc.part::<FakeStreams>().run.clone();
    let row = row_showing(world, &format!("message:{run}"))?;
    Ok(role(world, row, "sentFiles")
        .as_array()
        .cloned()
        .unwrap_or_default())
}

fn expect_folded(world: &World, label: &str) -> Outcome {
    let fold = last_row_of(world, "fold")?;
    let title = text(&role(world, fold, "title"));
    expect!(title == label, "the work folds behind \"{title}\"");
    expect!(
        role(world, fold, "expanded") != true && rows_of(world, "work")?.is_empty(),
        "the work is not folded away; {}",
        describe(world)
    );
    Ok(())
}

fn four_calls_and_answer(world: &mut World) -> Outcome {
    start_run(world, 0, "running")?;
    for n in 1..=4 {
        add_command(world, n, "completed")?;
    }
    add_item(
        world,
        "assistant_message",
        json!({"text": "The cart now shows tax."}),
    )?;
    Ok(())
}

fn carries_meta(world: &World, id: &str) -> Outcome<bool> {
    Ok(role(world, row_showing(world, id)?, "meta") == true)
}

fn toggle(world: &mut World, kind: &str) -> Outcome {
    let row = last_row_of(world, kind)?;
    let id = text(&role(world, row, "rowId"));
    let obj = timeline_object(world)?;
    TimelineModel::update(world.engine(), obj, |t| t.toggle(&id));
    world.pump()
}

fn count_of(value: &Value) -> usize {
    value.as_array().map_or(0, Vec::len)
}

fn set_peer(world: &mut World, online: bool) -> Outcome {
    let (thread, environment) = {
        let fake = world.mc.part::<FakeStreams>();
        (fake.thread.clone(), fake.environment.clone())
    };
    if online {
        world.mc.part::<FakeStreams>().offline.remove(&environment);
    } else {
        world
            .mc
            .part::<FakeStreams>()
            .offline
            .insert(environment.clone());
        for id in followers(&world.mc, &thread) {
            world
                .mc
                .send(&json!({"t": "error", "id": id, "reason": "unknown MC"}));
            world.mc.forget(id);
        }
    }
    let shell = world.mc.subscribers("shell").first().copied().unwrap_or(0);
    world
        .mc
        .send(&json!({"t": "shell.mc", "id": shell, "mc": PEER, "online": online}));
    world.sync()
}

fn status_label(world: &World, kind: &str) -> Outcome<String> {
    let row = last_row_of(world, kind)?;
    Ok(text(&role(world, row, "statusLabel")))
}

pub fn register(steps: &mut Steps) {
    steps.extension(extension);

    // Background.
    steps.step(
        &format!("a connected environment with the project {Q}"),
        |world, c, _| {
            let name = &c[0];
            world.mc.projects.insert(
                name.clone(),
                json!({"id": name, "title": name, "workspaceRoot": format!("/work/{name}"), "scripts": []}),
            );
            world.connect()?;
            world.sync()
        },
    );
    steps.step(
        &format!("the user is looking at a thread in {Q}"),
        |world, c, _| look_at_thread(world, &c[0]),
    );
    steps.step(
        &format!("the user is looking at a long thread in {Q}"),
        |world, c, _| look_at_thread(world, &c[0]),
    );

    // Streaming.
    steps.step("the agent is reasoning before it answers", |world, _, _| {
        start_run(world, 0, "running")?;
        add_item(
            world,
            "reasoning",
            json!({"streaming": true, "status": "running", "text": "The cart total needs"}),
        )?;
        Ok(())
    });
    steps.step("the reasoning is streaming", |world, _, _| {
        // Streamed text redraws its row; the row list stays as it is.
        let told = record(world)?;
        let id = text(&last_entry(world)?["id"]);
        change(
            world,
            "turn-item",
            &id,
            json!({"a": {"text": " a tax line"}}),
        )?;
        let told = told.borrow();
        let redrawn: Vec<&Out> = told
            .iter()
            .filter(|o| matches!(o, Out::DataChanged { .. }))
            .collect();
        let inserted = told
            .iter()
            .filter(|o| matches!(o, Out::Inserted { .. }))
            .count();
        let removed = told
            .iter()
            .filter(|o| matches!(o, Out::Removed { .. }))
            .count();
        expect!(
            redrawn.len() == 1 && inserted == 0 && removed == 0,
            "streamed text redrew {} rows, inserted {inserted}, removed {removed}",
            redrawn.len()
        );
        // And of that row only what shows the text: its delegate reads
        // nothing else again.
        let Out::DataChanged { roles, .. } = redrawn[0] else {
            unreachable!()
        };
        expect!(
            *roles == vec![Role::Entries],
            "streamed text redrew {} roles of its row",
            roles.len()
        );
        Ok(())
    });
    steps.step("the reasoning is finished", |world, _, _| {
        let id = text(&last_entry(world)?["id"]);
        set(
            world,
            "turn-item",
            &id,
            json!({"streaming": false, "status": "completed"}),
        )
    });
    steps.step("the agent reasoned in Markdown", |world, _, _| {
        start_run(world, 0, "running")?;
        add_item(
            world,
            "reasoning",
            json!({"streaming": false, "status": "completed",
                   "text": "**Checking** the [cart](https://shop.example/cart) `total`\n\n![a chart](chart.png)"}),
        )?;
        Ok(())
    });
    steps.step(&format!("the reasoning is labelled {Q}"), |world, c, _| {
        let label = text(&last_entry(world)?["label"]);
        expect!(label == c[0], "the reasoning is labelled \"{label}\"");
        Ok(())
    });

    steps.step(
        "the agent has been working for (\\d+) seconds",
        |world, c, _| {
            start_run(world, c[0].parse().unwrap_or(0), "running")?;
            Ok(())
        },
    );
    steps.step("the thread says the agent is working", |world, _, _| {
        let working = read(world, |t| (t.working(), t.working_label()))?;
        expect!(working.0, "the thread is not working; {}", describe(world));
        expect!(
            working.1 == "Working for 12s",
            "the thread says \"{}\"",
            working.1
        );
        Ok(())
    });
    steps.step("the elapsed time keeps counting", |world, _, _| {
        world.set_time_iso("2026-09-23T10:00:05Z")?;
        let label = read(world, |t| t.working_label())?;
        expect!(
            label == "Working for 17s",
            "five seconds later the thread says \"{label}\""
        );
        Ok(())
    });

    steps.step(
        "the agent ran four tool calls and then answered",
        |world, _, _| four_calls_and_answer(world),
    );
    steps.step("the turn completes after 2 minutes", |world, _, _| {
        settle_run(world, "completed", 120)
    });
    steps.step(&format!("the tool calls fold behind {Q}"), |world, c, _| {
        expect_folded(world, &c[0])
    });
    steps.step("the answer stays visible", |world, _, _| {
        expect_answer(world, "The cart now shows tax.")
    });
    steps.step(
        &format!("a finished turn is folded behind {Q}"),
        |world, c, _| {
            four_calls_and_answer(world)?;
            settle_run(world, "completed", 120)?;
            expect_folded(world, &c[0])
        },
    );
    steps.step(
        "the agent commented, ran a tool call and then answered",
        |world, _, _| {
            start_run(world, 0, "running")?;
            add_item(
                world,
                "assistant_message",
                json!({"id": "comment", "text": "Looking at the cart first."}),
            )?;
            add_command(world, 1, "completed")?;
            add_item(
                world,
                "assistant_message",
                json!({"id": "answer", "text": "The cart now shows tax."}),
            )?;
            Ok(())
        },
    );
    steps.step(
        "neither message shows its time and actions while the agent works",
        |world, _, _| {
            expect!(
                !carries_meta(world, "comment")? && !carries_meta(world, "answer")?,
                "a message of a running turn shows its time and actions"
            );
            Ok(())
        },
    );
    steps.step(
        "only the answer shows its time and actions",
        |world, _, _| {
            expect!(
                carries_meta(world, "answer")?,
                "the answer shows no time and actions"
            );
            expect!(
                !carries_meta(world, "comment")?,
                "the comment shows its time and actions"
            );
            Ok(())
        },
    );
    steps.step("the user opens the folded work", |world, _, _| {
        toggle(world, "fold")
    });
    steps.step("the user closes it again", |world, _, _| {
        toggle(world, "fold")
    });
    steps.step("its tool calls are shown", |world, _, _| {
        let work = last_row_of(world, "work")?;
        let calls = count_of(&role(world, work, "entries"))
            + role(world, work, "hiddenCount").as_u64().unwrap_or(0) as usize;
        expect!(
            calls == 4,
            "the open fold shows {calls} calls; {}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the tool calls fold away", |world, _, _| {
        expect!(
            rows_of(world, "work")?.is_empty(),
            "the calls are still shown; {}",
            describe(world)
        );
        Ok(())
    });

    steps.step(
        "the user interrupted a turn after (\\d+) seconds",
        |world, c, _| {
            start_run(world, c[0].parse().unwrap_or(0), "running")?;
            add_command(world, 1, "interrupted")?;
            Ok(())
        },
    );
    steps.step(
        "the user interrupted a turn before it did any work",
        |world, _, _| {
            start_run(world, -1, "starting")?;
            add_item(
                world,
                "run_interrupt_result",
                json!({"message": "Interrupted by the user"}),
            )?;
            Ok(())
        },
    );
    steps.step("the turn settles", |world, _, _| {
        let started = world.mc.part::<FakeStreams>().run_started;
        settle_run(
            world,
            "interrupted",
            started.map_or(0, |s| (now() - s).num_seconds()),
        )
    });
    steps.step(&format!("its work folds behind {Q}"), |world, c, _| {
        let row = last_row_of(world, "fold")?;
        let title = text(&role(world, row, "title"));
        expect!(title == c[0], "the work folds behind \"{title}\"");
        Ok(())
    });

    // Catching up.
    steps.step("the agent is writing a reply", |world, _, _| {
        start_run(world, 0, "running")?;
        add_command(world, 1, "completed")?;
        add_item(
            world,
            "assistant_message",
            json!({"id": "reply", "streaming": true, "text": "The cart"}),
        )?;
        keep_rows(world)
    });
    steps.step(
        "the agent finishes the reply while the shell is disconnected",
        |world, _, _| {
            change(
                world,
                "turn-item",
                "reply",
                json!({"a": {"text": " now shows tax."}, "s": {"streaming": false}}),
            )?;
            settle_run(world, "completed", 30)
        },
    );
    steps.step(
        "the agent finishes the reply while the MC cannot be reached",
        |world, _, _| {
            // No retry gets through until the MC is back, so the client
            // misses both changes.
            world.mc.stop_accepting();
            world.mc.drop_connection();
            world.wait_for("the shell to see the drop", |w| !w.client_ready())?;
            change(
                world,
                "turn-item",
                "reply",
                json!({"a": {"text": " now shows tax."}, "s": {"streaming": false}}),
            )?;
            settle_run(world, "completed", 30)
        },
    );
    steps.step(
        "the MC is back and the connection drops again part-way through the catch-up",
        |world, _, _| {
            // The first part of the catch-up arrives and the connection
            // goes; the next connection is sent all of it.
            let fake = world.mc.part::<FakeStreams>();
            fake.cut_catch_up = true;
            let asked = fake.asked.len();
            world.mc.start_accepting();
            world.wait_for_with(
                |w| {
                    let Some(fake) = w.mc.peek::<FakeStreams>() else {
                        return false;
                    };
                    !fake.cut_catch_up && fake.asked.len() >= asked + 2 && status(w) == "live"
                },
                |w| {
                    let times = w
                        .mc
                        .peek::<FakeStreams>()
                        .map_or(0, |f| f.asked.len() - asked);
                    format!(
                        "the thread to catch up on a second connection; it was asked for {times} times and {}",
                        describe(w)
                    )
                },
            )?;
            world.sync()
        },
    );
    // A thread opened while the MC is slow is shown loading until it sends it.
    steps.step("the MC is slow to send threads", |world, _, _| {
        world.mc.part::<FakeStreams>().slow = true;
        Ok(())
    });
    steps.step("the MC sends the thread", |world, _, _| {
        world.wait_for("the shell to ask for the thread", |w| {
            w.mc.peek::<FakeStreams>()
                .is_some_and(|f| !f.waiting.is_empty())
        })?;
        world.mc.part::<FakeStreams>().slow = false;
        answer_waiting(world)?;
        world.wait_for_with(
            |w| status(w) == "live",
            |w| format!("the thread to follow its MC; {}", describe(w)),
        )
    });
    steps.step("the client asked again from where it was", |world, _, _| {
        let (count, cut, again, sent_before, cut_sent_before) = {
            let fake = world.mc.part::<FakeStreams>();
            let count = fake.asked.len();
            expect!(count >= 3, "the thread was asked for {count} times");
            (
                count,
                fake.asked[count - 2].sub.clone(),
                fake.asked[count - 1].sub.clone(),
                fake.asked[count - 1].sent_before,
                fake.asked[count - 2].sent_before,
            )
        };
        let _ = count;
        // The part it was sent moved nothing: the same offset, and both
        // changes once more.
        let sent = sent_since(world, sent_before, "events");
        let snapshots = sent_since(world, cut_sent_before, "snapshot");
        expect!(
            cut["offset"].is_number()
                && again["offset"] == cut["offset"]
                && sent.len() == 1
                && count_of(&sent[0]["events"]) == 2
                && snapshots.is_empty(),
            "it asked with {} and then {}",
            show(&cut),
            show(&again)
        );
        Ok(())
    });
    steps.step(
        "the agent writes more than the shell has read",
        |world, _, _| {
            super::stream::change_quietly(
                world,
                "turn-item",
                "reply",
                json!({"a": {"text": " now shows tax."}}),
                true,
            )
        },
    );
    steps.step(
        "the MC tells the shell to resync the thread",
        |world, _, _| {
            let before = world.mc.subscriptions.len();
            let thread = world.mc.part::<FakeStreams>().thread.clone();
            // The MC drops the subscription and names the offset before the
            // first event it could not send (socket.ex): here, the last one
            // it did send.
            let sent = sent_since(world, 0, "events");
            let offset = sent.last().map_or(json!(0), |f| f["offset"].clone());
            for id in followers(&world.mc, &thread) {
                world
                    .mc
                    .send(&json!({"t": "resync", "id": id, "offset": offset}));
                world.mc.forget(id);
            }
            world.wait_for("the shell to subscribe again", |w| {
                w.mc.subscriptions.len() > before
            })?;
            world.sync()
        },
    );
    steps.step("the whole reply is shown", |world, _, _| {
        world.wait_for_with(
            |w| {
                let Ok(messages) = rows_of(w, "message") else {
                    return false;
                };
                messages
                    .last()
                    .is_some_and(|row| role(w, *row, "text") == "The cart now shows tax.")
            },
            |w| format!("the whole reply; {}", describe(w)),
        )
    });
    steps.step("the rows shown before are kept", |world, _, _| {
        let kept = world.part::<Kept>().0.borrow().clone();
        expect!(!kept.is_empty(), "no rows were shown before");
        let folded = !rows_of(world, "fold")?.is_empty();
        // Rows only go when the turn settles and folds its calls away; the
        // reply's row stays.
        for position in &kept {
            expect!(
                position.is_some() || folded,
                "a row was dropped; {}",
                describe(world)
            );
        }
        let index = read(world, |t| t.index_of("reply"))?;
        let last = kept.last().copied().flatten();
        expect!(
            index.is_some() && last.is_some_and(|row| role(world, row, "rowId") == "reply"),
            "the reply's row was replaced; {}",
            describe(world)
        );
        Ok(())
    });

    // A thread on another MC.
    steps.step(
        "the user is looking at a thread on another MC of the cluster",
        |world, _, _| {
            world.mc.join(PEER, PEER_ENVIRONMENT);
            let shell = world.mc.subscribers("shell").first().copied().unwrap_or(0);
            world.mc.send(&json!({
                "t": "shell.rows", "id": shell, "mc": PEER,
                "rows": [[PEER_THREAD, "thread", {
                    "id": PEER_THREAD, "title": "Remote", "projectId": PROJECT,
                    "createdAt": "2026-09-23T09:00:00Z", "updatedAt": "2026-09-23T09:00:00Z"}]]
            }));
            world.sync()?;
            let fake = world.mc.part::<FakeStreams>();
            fake.thread = PEER_THREAD.into();
            fake.environment = PEER_ENVIRONMENT.into();
            look(world, &format!("{PEER_ENVIRONMENT}:{PEER_THREAD}"), true)
        },
    );
    steps.step(&format!("the agent has answered {Q}"), |world, c, _| {
        start_run(world, 30, "running")?;
        add_item(world, "assistant_message", json!({"text": c[0]}))?;
        settle_run(world, "completed", 30)
    });
    steps.step("that MC leaves the cluster", |world, _, _| {
        set_peer(world, false)
    });
    steps.step("that MC rejoins the cluster", |world, _, _| {
        set_peer(world, true)
    });
    steps.step("the thread says its MC cannot be reached", |world, _, _| {
        world.wait_for_with(|w| status(w) == "unreachable", describe)?;
        let problem = read(world, |t| t.problem().to_owned())?;
        expect!(!problem.is_empty(), "the thread does not say why");
        Ok(())
    });
    steps.step(&format!("the answer {Q} is still shown"), |world, c, _| {
        expect_answer(world, &c[0])
    });
    steps.step("the thread follows its MC again", |world, _, _| {
        world.wait_for_with(|w| status(w) == "live", describe)
    });

    // Tool calls.
    steps.step(
        "the agent has run five tool calls in a row in the running turn",
        |world, _, _| {
            start_run(world, 0, "running")?;
            for n in 1..=5 {
                add_command(world, n, "completed")?;
            }
            Ok(())
        },
    );
    steps.step("the latest tool call is shown", |world, _, _| {
        let command = text(&last_entry(world)?["command"]);
        expect!(
            command == "bun test cart-5",
            "the call shown is \"{command}\""
        );
        Ok(())
    });
    steps.step(&format!("the other four are behind {Q}"), |world, c, _| {
        let work = last_row_of(world, "work")?;
        let hidden = role(world, work, "hiddenCount").as_u64().unwrap_or(0);
        let shown = count_of(&role(world, work, "entries"));
        expect!(
            format!("+{hidden} previous tool calls") == c[0] && shown == 1,
            "{shown} calls are shown, {hidden} behind; {}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the user shows the previous tool calls", |world, _, _| {
        toggle(world, "work")
    });
    steps.step("the user hides them again", |world, _, _| {
        toggle(world, "work")
    });
    steps.step("all five tool calls are shown", |world, _, _| {
        let work = last_row_of(world, "work")?;
        let shown = count_of(&role(world, work, "entries"));
        expect!(shown == 5, "{shown} calls are shown; {}", describe(world));
        Ok(())
    });

    steps.step("the agent's tool call is still running", |world, _, _| {
        start_run(world, 0, "running")?;
        add_command(world, 1, "running")?;
        Ok(())
    });
    steps.step("the agent's tool call failed", |world, _, _| {
        start_run(world, 0, "running")?;
        add_command(world, 1, "failed")?;
        Ok(())
    });
    steps.step("the agent's tool call was interrupted", |world, _, _| {
        start_run(world, 0, "running")?;
        add_command(world, 1, "interrupted")?;
        Ok(())
    });
    steps.step(
        "the agent's tool call was declined by the user",
        |world, _, _| {
            start_run(world, 0, "running")?;
            set(
                world,
                "runtime-request",
                "request-1",
                json!({"id": "request-1", "status": "resolved", "decision": "decline"}),
            )?;
            add_item(
                world,
                "approval_request",
                json!({"requestId": "request-1", "prompt": "Run rm -rf dist?"}),
            )?;
            Ok(())
        },
    );
    steps.step(&format!("the call is marked {Q}"), |world, c, _| {
        let label = text(&last_entry(world)?["statusLabel"]);
        expect!(label == c[0], "the call is marked \"{label}\"");
        Ok(())
    });
    steps.step("the agent's most recent tool call (.+)", |world, c, _| {
        let kind = match c[0].as_str() {
            "ran a command" => "command_execution",
            "changed a file" => "file_change",
            "searched the files" => "file_search",
            "searched the web" => "web_search",
            "called an MCP tool" => "dynamic_tool",
            "asked for approval" => "approval_request",
            other => fail!("unknown tool call: {other}"),
        };
        start_run(world, 0, "running")?;
        add_item(world, kind, json!({}))?;
        Ok(())
    });
    steps.step(
        &format!("the call is shown with the {Q} icon"),
        |world, c, _| {
            let icon = text(&last_entry(world)?["icon"]);
            expect!(icon == c[0], "the call is shown with the \"{icon}\" icon");
            Ok(())
        },
    );

    steps.step(
        &format!("the agent changed {Q} and {Q} in one turn"),
        |world, c, _| {
            start_run(world, 0, "running")?;
            for path in [&c[0], &c[1]] {
                add_item(world, "file_change", json!({"fileName": path}))?;
            }
            add_item(
                world,
                "assistant_message",
                json!({"text": "Both files are updated."}),
            )?;
            world.mc.part::<FakeStreams>().changed_files = vec![c[0].clone(), c[1].clone()];
            Ok(())
        },
    );
    steps.step("the turn completes", |world, _, _| {
        let files: Vec<Value> = world
            .mc
            .part::<FakeStreams>()
            .changed_files
            .iter()
            .enumerate()
            .map(|(i, path)| {
                let n = i as i64 + 1;
                json!({"path": path, "kind": "modified", "additions": 10 * n, "deletions": n})
            })
            .collect();
        add_item(world, "checkpoint", json!({"files": files}))?;
        settle_run(world, "completed", 60)
    });
    steps.step(
        "the reply lists both files with their added and removed lines",
        |world, _, _| {
            let reply = last_row_of(world, "message")?;
            let files = role(world, reply, "files")
                .as_array()
                .cloned()
                .unwrap_or_default();
            let changed = world.mc.part::<FakeStreams>().changed_files.clone();
            expect!(
                files.len() == changed.len(),
                "the reply lists {}",
                show(&Value::Array(files.clone()))
            );
            for (file, path) in files.iter().zip(&changed) {
                expect!(
                    file["path"] == json!(path)
                        && file["additions"].as_i64().unwrap_or(0) > 0
                        && file["deletions"].as_i64().unwrap_or(0) > 0,
                    "the reply lists {}",
                    show(&Value::Array(files.clone()))
                );
            }
            Ok(())
        },
    );

    // Runs and the queue.
    steps.step("the user's message was (.+)", |world, c, _| {
        let intent = match c[0].as_str() {
            "queued behind the active turn" => "queued_turn",
            "sent as a steer" => "steer",
            "queued and later promoted to a steer" => "promoted_queued_to_steer",
            other => fail!("unknown way of sending: {other}"),
        };
        let run = start_run(world, 0, "queued")?;
        set(
            world,
            "turn-item",
            &format!("message:{run}"),
            json!({"inputIntent": intent}),
        )
    });
    steps.step(
        &format!("the user sent the image {Q} with a message"),
        |world, c, _| {
            let run = start_run(world, 0, "running")?;
            let image = json!({"type": "image", "id": "image-1", "name": c[0],
                               "mimeType": "image/png", "sizeBytes": 2048});
            set(
                world,
                "turn-item",
                &format!("message:{run}"),
                json!({"attachments": [image]}),
            )
        },
    );
    steps.step(
        &format!("the message shows the image {Q} from its MC"),
        |world, c, _| expect_image(world, &c[0], 1),
    );
    steps.step(
        &format!("the user sent the file {Q} of 2 MB with a message"),
        |world, c, _| {
            let run = start_run(world, 0, "running")?;
            let file = json!({"type": "file", "id": "file-1", "name": c[0],
                              "mimeType": "application/pdf", "sizeBytes": 2 * 1024 * 1024});
            set(
                world,
                "turn-item",
                &format!("message:{run}"),
                json!({"attachments": [file]}),
            )
        },
    );
    steps.step(
        &format!("the message shows {Q} with its kind and size"),
        |world, c, _| {
            let files = sent_files(world)?;
            let file = files.first().cloned().unwrap_or(Value::Null);
            expect!(
                files.len() == 1 && file["name"] == c[0] && file["detail"] == "PDF · 2.0 MiB",
                "the message shows {}",
                show(&Value::Array(files))
            );
            Ok(())
        },
    );
    steps.step(
        "the message carries an attachment of a kind a newer environment added",
        |world, _, _| {
            let run = start_run(world, 0, "running")?;
            let other = json!({"type": "hologram", "id": "other-1", "name": "scene.holo"});
            set(
                world,
                "turn-item",
                &format!("message:{run}"),
                json!({"attachments": [other]}),
            )
        },
    );
    steps.step(
        "the message lists the attachment by its name",
        |world, _, _| {
            let files = sent_files(world)?;
            let file = files.first().cloned().unwrap_or(Value::Null);
            expect!(
                files.len() == 1
                    && file["name"] == "scene.holo"
                    && text(&file["detail"]).is_empty(),
                "the message lists {}",
                show(&Value::Array(files))
            );
            Ok(())
        },
    );
    steps.step("there is nothing to open", |world, _, _| {
        let run = world.mc.part::<FakeStreams>().run.clone();
        let row = row_showing(world, &format!("message:{run}"))?;
        let images = role(world, row, "attachments");
        expect!(
            count_of(&images) == 0,
            "the message shows the images {}",
            show(&images)
        );
        Ok(())
    });
    steps.step("more than an hour passes", |world, _, _| {
        let later = now() + Duration::seconds(3660);
        world.mc.part::<FakeAssets>().at = later;
        world.set_time_iso(&iso(later))
    });
    steps.step(
        &format!("the message shows the image {Q} from a new address"),
        |world, c, _| expect_image(world, &c[0], 2),
    );
    steps.step(&format!("the message is marked {Q}"), |world, c, _| {
        let run = world.mc.part::<FakeStreams>().run.clone();
        let row = row_showing(world, &format!("message:{run}"))?;
        let marker = text(&role(world, row, "marker"));
        expect!(marker == c[0], "the message is marked \"{marker}\"");
        Ok(())
    });

    // Timestamps, read on the scenarios' clock (2026-09-23 10:00, UTC).
    steps.step(
        "the user sent a message (today|yesterday|on .+) at 9:05 in the morning",
        |world, c, _| {
            world.set_time_iso(&iso(now()))?;
            let mut day = now().date_naive();
            if c[0] == "yesterday" {
                day = day.pred_opt().unwrap_or(day);
            } else if let Some(date) = c[0].strip_prefix("on ") {
                day = NaiveDate::parse_from_str(date, "%B %d, %Y")
                    .or_else(|_| NaiveDate::parse_from_str(&format!("{date}, 2026"), "%B %d, %Y"))
                    .map_err(|_| crate::harness::Failure(format!("unknown day: {date}")))?;
            }
            let sent = Utc.from_utc_datetime(
                &day.and_time(NaiveTime::from_hms_opt(9, 5, 0).expect("a time")),
            );
            start_run(world, (now() - sent).num_seconds(), "running")?;
            Ok(())
        },
    );
    steps.step(&format!("the message is stamped {Q}"), |world, c, _| {
        let run = world.mc.part::<FakeStreams>().run.clone();
        let row = row_showing(world, &format!("message:{run}"))?;
        let stamp = text(&role(world, row, "time"));
        expect!(stamp == c[0], "the message is stamped \"{stamp}\"");
        Ok(())
    });
    steps.step(&format!("its full time reads {Q}"), |world, c, _| {
        let run = world.mc.part::<FakeStreams>().run.clone();
        let row = format!("message:{run}");
        let title = read(world, |t| t.time_title(&row, ""))?;
        expect!(title == c[0], "its full time reads \"{title}\"");
        Ok(())
    });

    // Plans and subagents.
    steps.step(
        &format!("the agent proposes a plan whose first heading is {Q}"),
        |world, c, _| {
            start_run(world, 0, "running")?;
            add_item(
                world,
                "proposed_plan",
                json!({"markdown": format!("Here is the plan.\n\n## {}\n\n- Add the line\n- Test it", c[0])}),
            )?;
            Ok(())
        },
    );
    steps.step(&format!("the plan card is titled {Q}"), |world, c, _| {
        let title = text(&role(world, last_row_of(world, "plan")?, "title"));
        expect!(title == c[0], "the plan card is titled \"{title}\"");
        Ok(())
    });
    steps.step(
        &format!("the agent proposes a plan that opens with the heading {Q}"),
        |world, c, _| {
            start_run(world, 0, "running")?;
            add_item(
                world,
                "proposed_plan",
                json!({"markdown": format!("# {}\n\n## Summary\n\n- Add the line\n- Test it", c[0])}),
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the plan's text starts with {Q}"),
        |world, c, _| {
            let body = text(&role(world, last_row_of(world, "plan")?, "text"));
            expect!(body.starts_with(&c[0]), "the plan's text reads \"{body}\"");
            Ok(())
        },
    );
    steps.step(
        &format!("a plan without a heading is titled {Q}"),
        |world, c, _| {
            add_item(
                world,
                "proposed_plan",
                json!({"markdown": "Add the line, then test it."}),
            )?;
            let title = text(&role(world, last_row_of(world, "plan")?, "title"));
            expect!(title == c[0], "the plan card is titled \"{title}\"");
            Ok(())
        },
    );

    steps.step("the agent has a subagent that is (.+)", |world, c, _| {
        let status = match c[0].as_str() {
            "running" => "running",
            "waiting on a request" => "waiting",
            "idle and resumable" => "idle",
            "completed" => "completed",
            "failed" => "failed",
            "cancelled" => "cancelled",
            other => fail!("unknown subagent status: {other}"),
        };
        start_run(world, 0, "running")?;
        add_item(
            world,
            "subagent",
            json!({"status": status, "title": "Tax tests", "prompt": "write the tax tests",
                   "childThreadId": "thread-child"}),
        )?;
        Ok(())
    });
    steps.step(&format!("the subagent is shown as {Q}"), |world, c, _| {
        let label = status_label(world, "subagent")?;
        expect!(label == c[0], "the subagent is shown as \"{label}\"");
        Ok(())
    });

    let context_events = [
        (
            "the conversation is forked",
            json!({"type": "fork", "targetThreadId": "thread-2"}),
        ),
        (
            "the context is handed to another agent",
            json!({"type": "handoff", "summary": "Cart tax so far"}),
        ),
        (
            "the agent creates a thread",
            json!({"type": "thread_created", "title": "Tax tests"}),
        ),
        (
            "the context is compacted",
            json!({"type": "compaction", "summary": "Earlier turns"}),
        ),
    ];
    for (event, fields) in context_events {
        steps.step(event, move |world, _, _| {
            start_run(world, 0, "running")?;
            add_item(world, &text(&fields["type"]), fields.clone())?;
            Ok(())
        });
    }
    steps.step(&format!("the timeline marks {Q}"), |world, c, _| {
        let title = text(&role(world, last_row_of(world, "marker")?, "title"));
        expect!(title == c[0], "the timeline marks \"{title}\"");
        Ok(())
    });
}
