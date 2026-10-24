//! What the client keeps between connections and runs (LocalCache): the
//! thread list and the threads the user opened, shown before the MC answers
//! and resumed from where they stood. The scenarios of
//! connections/local-cache.feature, the long thread ones of
//! timeline/scrolling-and-links.feature, and the steps other files'
//! scenarios share to say what a thread cost the MC. desktop-qt's
//! LocalCacheSteps.cpp.

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::threads::ThreadStore;
use hal_c2_shell::session::Session;
use hal_c2_shell::thread_view::timeline::WINDOW_ITEMS;
use ljos::prelude::Value as Lv;
use serde_json::{Value, json};

use super::stream::{
    FakeStreams, THREAD, add_item, answer_to, describe, kept_copy, look, look_at_thread, read,
    role, row_count, sent_since, seed_turns, settle_run, start_run, status, timeline_object,
};
use super::thread_list::title_id;
use super::thread_menu::section_of;
use crate::brick::{Brick, Shown};
use crate::fake_mc::FakeMc;
use crate::harness::{Failure, Outcome, Q, Steps, at, show, text};
use crate::world::World;
use crate::{expect, fail};

const TOKEN: &str = "mc-token";
const KEPT_ANSWER: &str = "The cart total includes tax now.";
const AT: &str = "2026-09-23T09:00:00Z";
// A long thread: more turn items than a client opens a thread with
// (WINDOW_ITEMS), in turns of 25 (a question, 23 calls, an answer).
const TURNS: i64 = 12;
const CALLS: i64 = 23;
const TURN_ITEMS: i64 = CALLS + 2;
// A settled turn shows its question, its folded work and its answer.
const ROWS_PER_TURN: usize = 3;
const WINDOW_TURNS: i64 = WINDOW_ITEMS / TURN_ITEMS;

/// What a scenario watches across the app closing or a thread being left.
#[derive(Default)]
struct Kept {
    /// The key of the thread it is about.
    thread: String,
    /// The rows it showed.
    rows: usize,
    /// `shell` frames the MC had sent before the app started again.
    shells: usize,
    /// `sub` frames it had read by then.
    subs: usize,
    /// Frames it had sent followers by then.
    sent: usize,
    /// The row the user was reading, and where it was drawn.
    reading: String,
    reading_y: f64,
}

fn kept(world: &mut World) -> &mut Kept {
    world.mc.part::<Kept>()
}

fn streams(world: &mut World) -> &mut FakeStreams {
    world.mc.part::<FakeStreams>()
}

fn key_of(world: &World, title: &str) -> String {
    format!("{}:{}", world.mc.environment_id, title_id(title))
}

fn shows(world: &World, text: &str) -> bool {
    (0..row_count(world).unwrap_or(0)).any(|row| role(world, row, "text") == json!(text))
}

/// The cache has answered what the shell asked of it, and the copies it
/// loaded are shown.
fn drain_cache(world: &World) {
    hal_c2_shell::controllers::threads::drain(world.engine());
}

/// The app starts on the files it left, and reads what it kept.
fn launch(world: &mut World) {
    let (shells, subs) = (world.mc.shell_frames.len(), world.mc.subscriptions.len());
    let sent = streams(world).sent.len();
    let state = kept(world);
    (state.shells, state.subs, state.sent) = (shells, subs, sent);
    world.launch();
    drain_cache(world);
}

/// Points the app at an MC, as the desktop's host does once the MC is up.
fn point_at(world: &mut World, origin: String) -> Outcome {
    let session = Session {
        origin,
        token: TOKEN.into(),
        label: String::new(),
        environment_id: String::new(),
    };
    hal_c2_shell::open(world.engine(), &session).map_err(Failure)?;
    drain_cache(world);
    Ok(())
}

fn start(world: &mut World) -> Outcome {
    launch(world);
    let origin = world.mc.origin();
    point_at(world, origin)
}

/// The MC has answered the shell and the thread's stream, and the client has read the answers.
fn settle(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| w.active() && timeline_object(w).is_ok() && status(w) == "live",
        |w| {
            format!(
                "the thread to follow its MC; {}",
                if timeline_object(w).is_ok() {
                    describe(w)
                } else {
                    "none is open".into()
                }
            )
        },
    )?;
    world.sync()
}

/// The index of the last `sub` the MC answered for the scenario's thread.
fn last_asked(world: &mut World) -> Outcome<usize> {
    let fake = streams(world);
    match fake.asked.iter().rposition(|a| a.thread == fake.thread) {
        Some(index) => Ok(index),
        None => fail!("the MC was never asked for {}", fake.thread),
    }
}

fn sub_of(world: &mut World, asked: usize) -> Value {
    streams(world).asked[asked].sub.clone()
}

fn events_in(frames: &[Value]) -> usize {
    frames
        .iter()
        .map(|frame| frame["events"].as_array().map_or(0, Vec::len))
        .sum()
}

/// The last `shell` frame the MC sent since the app started, once it has.
fn shell_frame(world: &mut World) -> Outcome<Value> {
    let from = kept(world).shells;
    world.wait_for("the MC to send its thread list", move |w| {
        w.mc.shell_frames.len() > from
    })?;
    Ok(world.mc.shell_frames.last().cloned().unwrap_or(Value::Null))
}

/// The MC's own entry of a `shell` frame.
fn own_mc(world: &World, frame: &Value) -> Value {
    frame["mcs"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|mc| mc["mc"] == json!(world.mc.name))
        .cloned()
        .unwrap_or(Value::Null)
}

fn list_thread(world: &mut World, title: &str) {
    let id = title_id(title);
    let project = world.mc.projects.keys().next().cloned().unwrap_or_default();
    world.mc.threads.insert(
        id.clone(),
        json!({"id": id, "title": title, "projectId": project,
               "createdAt": AT, "updatedAt": AT}),
    );
}

/// The app is up on the MC's own rows.
fn wait_for_list(world: &mut World) -> Outcome {
    world.wait_for("the shell to start on its MC's rows", |w| {
        w.active() && hal_c2_shell::store::with(w.engine(), |s| s.synchronized())
    })?;
    world.sync()
}

fn home(world: &mut World) -> Outcome {
    world.with::<Navigation, _>(|n, engine| n.open(engine, Route::Home))
}

/// Leaves the scenario's thread, forgets what the client holds of it, and
/// gives it more turns than a client opens a thread with.
fn make_long(world: &mut World) -> Outcome {
    let thread = format!("{}:{THREAD}", world.mc.environment_id);
    kept(world).thread.clone_from(&thread);
    home(world)?;
    world.with::<ThreadStore, _>(|t, engine| t.close(engine, &thread))?;
    if let Some(cache) = hal_c2_shell::store::cache(world.engine()) {
        cache.forget_thread(&thread);
        cache.drain();
    }
    world.sync()?;
    seed_turns(world, TURNS, CALLS)
}

fn open_again(world: &mut World) -> Outcome {
    let sent = streams(world).sent.len();
    kept(world).sent = sent;
    let thread = kept(world).thread.clone();
    look(world, &thread, true)?;
    world.sync()
}

fn first_text(world: &World) -> String {
    text(&role(world, 0, "text"))
}

fn expect_newest_turns(world: &World) -> Outcome {
    let rows = row_count(world)?;
    let earlier = read(world, |t| t.has_earlier())?;
    expect!(
        earlier
            && rows == WINDOW_TURNS as usize * ROWS_PER_TURN
            && first_text(world) == format!("Question {}", TURNS - WINDOW_TURNS + 1),
        "the thread shows {rows} rows from \"{}\" and {} earlier turns",
        first_text(world),
        if earlier { "has" } else { "has no" }
    );
    Ok(())
}

fn expect_every_turn(world: &mut World) -> Outcome {
    world.wait_for("the earlier turns to arrive", |w| {
        read(w, |t| !t.loading_earlier() && !t.has_earlier()).unwrap_or(false)
    })?;
    let rows = row_count(world)?;
    expect!(
        rows == TURNS as usize * ROWS_PER_TURN && first_text(world) == "Question 1",
        "the thread shows {rows} rows from \"{}\"",
        first_text(world)
    );
    Ok(())
}

fn load_earlier(world: &World) -> Outcome {
    let obj = timeline_object(world)?;
    hal_c2_shell::thread_view::timeline_model::TimelineModel::update(
        world.engine(),
        obj,
        |t| t.load_earlier(),
    );
    Ok(())
}

/// The open thread as the Timeline brick draws it, `height` tall. The
/// wrapper answers where a drawn row is.
fn timeline_brick(world: &mut World, height: f64) -> Outcome<Brick> {
    let brick = Brick::new(
        world,
        "import QtQuick\nimport HalC2.Bricks\n\
         Item {\n\
           property alias model: tl.model\n\
           width: 820\n\
           height: parent.height\n\
           Timeline { id: tl; anchors.fill: parent }\n\
           function rowsView(item) {\n\
             if (item.objectName === \"timelineRows\") return item\n\
             for (var i = 0; i < item.children.length; i++) {\n\
               var found = rowsView(item.children[i])\n\
               if (found) return found\n\
             }\n\
             return null\n\
           }\n\
           function drawnY(rowId) {\n\
             var view = rowsView(tl)\n\
             var kids = view.contentItem.children\n\
             for (var i = 0; i < kids.length; i++) {\n\
               if (kids[i].rowId === rowId) return kids[i].mapToItem(null, 0, 0).y\n\
             }\n\
             return -1\n\
           }\n\
         }\n",
        820.0,
        height,
    )?;
    world.part::<Shown>().0 = Some(brick);
    let timeline = timeline_object(world)?;
    let Some(root) = brick.root(world) else {
        fail!("the timeline brick has no root");
    };
    brick.write(world, root, "model", Lv::Object(timeline))?;
    Ok(brick)
}

fn rows_view(world: &World, brick: &Brick) -> Outcome<ljos::ObjectId> {
    brick.item(world, "timelineRows")
}

fn real(world: &World, item: ljos::ObjectId, name: &str) -> f64 {
    match world.engine().read_by_name(item, name) {
        Lv::Real(r) => r,
        Lv::Int(n) => f64::from(n),
        _ => 0.0,
    }
}

fn flag(world: &World, item: ljos::ObjectId, name: &str) -> bool {
    matches!(world.engine().read_by_name(item, name), Lv::Bool(true))
}

/// Where the row is drawn in the window, from its top; none while the list
/// has not made it.
fn drawn_at(world: &World, brick: &Brick, row_id: &str) -> Option<f64> {
    let root = brick.root(world)?;
    match world
        .engine()
        .invoke_by_name(root, "drawnY", &[Lv::from(row_id)])
    {
        Ok(Lv::Real(y)) if y >= 0.0 => Some(y),
        Ok(Lv::Int(y)) if y >= 0 => Some(f64::from(y)),
        _ => None,
    }
}

fn the_brick(world: &World) -> Outcome<Brick> {
    match world.peek_part::<Shown>().and_then(|s| s.0) {
        Some(brick) => Ok(brick),
        None => fail!("no brick is shown"),
    }
}

pub fn register(steps: &mut Steps) {
    // The app closing and starting.
    steps.step(
        &format!("the user was reading a thread in {Q} when the app quit"),
        |world, c, _| {
            look_at_thread(world, &c[0])?;
            start_run(world, 60, "running")?;
            add_item(world, "assistant_message", json!({"text": KEPT_ANSWER}))?;
            settle_run(world, "completed", 30)?;
            let thread = format!("{}:{THREAD}", world.mc.environment_id);
            let rows = row_count(world)?;
            let state = kept(world);
            state.thread = thread;
            state.rows = rows;
            // The client writes what it holds a moment after it changes.
            world.advance(hal_c2_shell::store::FLUSH_DELAY_MS + 100)?;
            drain_cache(world);
            world.quit()
        },
    );
    steps.step("the app starts again", |world, _, _| start(world));
    steps.step(
        "the app starts while its MC is not answering",
        |world, _, _| {
            world.mc.stop_accepting();
            start(world)
        },
    );
    steps.step(
        "the app starts and has not been told where its MC is",
        |world, _, _| {
            launch(world);
            Ok(())
        },
    );
    steps.step(
        "the app starts and its MC has not sent its thread list yet",
        |world, _, _| {
            world.mc.hold_snapshot = true;
            start(world)?;
            // The MC has heard the client ask for its thread list, and holds its answer.
            let from = kept(world).subs;
            world.wait_for("the client to ask for the thread list", move |w| {
                w.mc.subscriptions.len() > from
            })?;
            world.sync()
        },
    );
    steps.step("the MC has not been asked for the thread", |world, _, _| {
        let from = kept(world).subs;
        let asked: Vec<String> = world.mc.subscriptions[from..]
            .iter()
            .map(|sub| text(&sub["shape"]["type"]))
            .collect();
        let synchronized = hal_c2_shell::store::with(world.engine(), |s| s.synchronized());
        expect!(
            asked == ["shell"] && !synchronized,
            "since it started the client asked for {}",
            asked.join(", ")
        );
        Ok(())
    });
    steps.step("the MC sends its thread list", |world, _, _| {
        world.mc.hold_snapshot = false;
        world.mc.send_snapshot();
        Ok(())
    });
    steps.step("the app starts pointed at another MC", |world, _, _| {
        launch(world);
        let thread = kept(world).thread.clone();
        expect!(
            !section_of(world, &thread).is_empty(),
            "nothing was kept to show"
        );
        // Nobody answers there.
        point_at(world, "http://127.0.0.1:9".into())
    });
    steps.step(
        "nothing the client kept of the first MC is shown",
        |world, _, _| {
            let thread = kept(world).thread.clone();
            let (environments, row) = hal_c2_shell::store::with(world.engine(), |s| {
                (s.environments(), s.thread(&thread).is_some())
            });
            expect!(
                section_of(world, &thread).is_empty() && environments.is_empty() && !row,
                "the thread list is {}",
                show(&world.state("sidebar"))
            );
            // Nor the conversation that was open on it.
            let open = world.with::<ThreadStore, _>(|t, _| t.open_threads())?;
            expect!(
                timeline_object(world).is_err() && open.is_empty(),
                "the first MC's thread {thread} is still open"
            );
            // Nor is its thread list kept for a later start.
            let origin = hal_c2_shell::store::cache(world.engine())
                .map(|cache| cache.shell("").origin)
                .unwrap_or_default();
            expect!(origin.is_empty(), "the first MC's thread list is still kept");
            Ok(())
        },
    );
    steps.step("what the client kept was deleted", |world, _, _| {
        let cache = world.home_dir().join("cache");
        expect!(
            cache.join(hal_c2_shell::cache::FILE).exists()
                && std::fs::remove_dir_all(&cache).is_ok(),
            "there was no cache to delete in {}",
            cache.display()
        );
        Ok(())
    });

    // What happens meanwhile: while the app is closed, or the thread is not followed.
    steps.step(
        &format!("the agent answered {Q} meanwhile"),
        |world, c, _| {
            // The MC has heard that the thread is no longer followed.
            world.sync()?;
            start_run(world, 20, "running")?;
            add_item(world, "assistant_message", json!({"text": c[0]}))?;
            settle_run(world, "completed", 10)
        },
    );
    steps.step(
        "the thread moved to an MC that keeps another log",
        |world, _, _| {
            streams(world).handle = "log-2.1".into();
            Ok(())
        },
    );
    steps.step(
        "the thread was deleted while the app was closed",
        |world, _, _| {
            world.mc.threads.remove(THREAD);
            Ok(())
        },
    );

    // The thread, as kept and as resumed.
    steps.step(
        "the thread shows the conversation it kept",
        |world, _, _| {
            let (thread, rows) = {
                let state = kept(world);
                (state.thread.clone(), state.rows)
            };
            world.wait_for_with(
                |w| {
                    hal_c2_shell::controllers::threads::active(w.engine()) == thread
                        && row_count(w).is_ok_and(|n| n == rows)
                },
                |w| {
                    let copy = kept_copy(w, &thread);
                    format!(
                        "{rows} rows of {thread} (the cache holds {} entities at {:?}); {}",
                        copy.entities.len(),
                        copy.cursor,
                        if timeline_object(w).is_ok() {
                            describe(w)
                        } else {
                            "no thread is open".into()
                        }
                    )
                },
            )?;
            expect!(
                shows(world, KEPT_ANSWER),
                "the thread shows {}",
                describe(world)
            );
            // And the window draws it, whether or not the MC has answered.
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n",
                820.0,
                700.0,
            )?;
            let brick = the_brick(world)?;
            world.wait_for("the window to draw the conversation", |w| {
                brick.shows(w, KEPT_ANSWER).unwrap_or(false)
            })?;
            let placeholder = brick.item(world, "threadPlaceholder")?;
            expect!(
                !brick.flag(world, placeholder, "visible"),
                "the window says the thread is loading"
            );
            Ok(())
        },
    );
    steps.step(
        "the thread list shows what the client kept",
        |world, _, _| {
            let thread = kept(world).thread.clone();
            expect!(
                !section_of(world, &thread).is_empty(),
                "the thread list is {}",
                show(&world.state("sidebar"))
            );
            Brick::show(
                world,
                "import QtQuick\nimport HalC2.Bricks\nSidebar { height: 600 }\n",
                256.0,
                600.0,
            )?;
            let brick = the_brick(world)?;
            world.wait_for("the window to draw the thread list", |w| {
                brick.shows(w, "Tax line").unwrap_or(false)
            })
        },
    );
    steps.step(
        "the first-run screen does not cover them",
        |world, _, _| {
            // WelcomeWizard covers the window for any gate but "app".
            let onboarding = world.state("onboarding");
            expect!(
                onboarding["gate"] == json!("app") && text(&onboarding["recovery"]).is_empty(),
                "the first-run gate is \"{}\"",
                text(&onboarding["gate"])
            );
            Ok(())
        },
    );
    steps.step("neither is shown as live", |world, _, _| {
        let (online, synchronized) = hal_c2_shell::store::with(world.engine(), |s| {
            let online = s
                .environments()
                .into_iter()
                .filter(|e| s.environment_online(e))
                .count();
            (online, s.synchronized())
        });
        let phase = text(&world.state("connection")["phase"]);
        let timeline = if timeline_object(world).is_ok() {
            status(world)
        } else {
            String::new()
        };
        expect!(
            timeline != "live" && online == 0 && !synchronized && phase != "connected" && !world.active(),
            "the thread is {timeline}, the connection {phase}, and {online} environments read as online"
        );
        // And nothing was heard from the MC to show it.
        let shells = kept(world).shells;
        expect!(
            world.mc.shell_frames.len() == shells,
            "the MC sent its thread list"
        );
        Ok(())
    });
    steps.step(
        "the client asks for the thread from where its copy stands",
        |world, _, _| {
            settle(world)?;
            let asked = last_asked(world)?;
            let sub = sub_of(world, asked);
            let handle = streams(world).handle.clone();
            expect!(
                sub["offset"].is_number()
                    && sub["handle"] == json!(handle)
                    && sub["window"].get("floor").is_some(),
                "it asked with {}",
                show(&sub)
            );
            Ok(())
        },
    );
    steps.step("the MC sends only what the client lacks", |world, _, _| {
        settle(world)?;
        let asked = last_asked(world)?;
        let snapshots = answer_to(world, asked, "snapshot").len();
        let events = events_in(&answer_to(world, asked, "events"));
        let (lacked, sub) = (streams(world).asked[asked].lacked, sub_of(world, asked));
        expect!(
            snapshots == 0 && events as i64 == lacked,
            "the MC sent {snapshots} snapshots and {events} events for the {lacked} changes the client lacked; it was asked with {}",
            show(&sub)
        );
        Ok(())
    });
    steps.step(
        &format!("the thread shows {Q} after the conversation it kept"),
        |world, c, _| {
            settle(world)?;
            let rows = row_count(world)?;
            let (mut kept_at, mut new_at) = (None, None);
            for row in 0..rows {
                let text = text(&role(world, row, "text"));
                if text == KEPT_ANSWER {
                    kept_at = Some(row);
                }
                if text == c[0] {
                    new_at = Some(row);
                }
            }
            expect!(
                matches!((kept_at, new_at), (Some(k), Some(n)) if n > k),
                "the thread shows {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the MC sends the thread whole", |world, _, _| {
        settle(world)?;
        let asked = last_asked(world)?;
        let snapshots = answer_to(world, asked, "snapshot");
        let events = answer_to(world, asked, "events");
        let sub = sub_of(world, asked);
        expect!(
            snapshots.len() == 1
                && snapshots[0]["rows"].as_array().is_some_and(|r| !r.is_empty())
                && events.is_empty(),
            "the MC sent {} snapshots; it was asked with {}",
            snapshots.len(),
            show(&sub)
        );
        Ok(())
    });
    steps.step(
        "the client resumes from the new log after a reconnect",
        |world, _, _| {
            let before = streams(world).asked.len();
            world.mc.drop_connection();
            world.wait_for_with(
                move |w| {
                    w.mc.peek::<FakeStreams>().is_some_and(|f| f.asked.len() > before)
                        && timeline_object(w).is_ok()
                        && status(w) == "live"
                },
                |w| format!("the thread to be followed again; {}", describe(w)),
            )?;
            let asked = last_asked(world)?;
            let sub = sub_of(world, asked);
            expect!(
                sub["handle"] == json!("log-2.1")
                    && sub["offset"].is_number()
                    && answer_to(world, asked, "snapshot").is_empty(),
                "it asked with {}",
                show(&sub)
            );
            Ok(())
        },
    );
    steps.step(
        "the client keeps nothing of its conversation",
        |world, _, _| {
            wait_for_list(world)?;
            let thread = kept(world).thread.clone();
            let open = world.with::<ThreadStore, _>(|t, _| t.timeline(&thread).is_some())?;
            expect!(
                !kept_copy(world, &thread).found() && !open,
                "the client still holds {thread}"
            );
            Ok(())
        },
    );

    // The thread list, as kept and as resumed.
    steps.step(
        &format!("the app quit with the threads {Q} and {Q} in the list"),
        |world, c, _| {
            for title in c.iter() {
                list_thread(world, title);
                let id = title_id(title);
                let row = world.mc.threads[&id].clone();
                world.mc.send_row(&id, &row);
            }
            world.sync()?;
            for title in c.iter() {
                let key = key_of(world, title);
                expect!(
                    !section_of(world, &key).is_empty(),
                    "\"{title}\" is not in the list"
                );
            }
            world.advance(hal_c2_shell::store::FLUSH_DELAY_MS + 100)?;
            world.quit()
        },
    );
    steps.step(
        &format!("the thread {Q} was created while the app was closed"),
        |world, c, _| {
            list_thread(world, &c[0]);
            Ok(())
        },
    );
    steps.step(
        &format!("the MC restarted and lost {Q} while the app was closed"),
        |world, c, _| {
            world.mc.epoch = "epoch-2".into();
            world.mc.threads.remove(&title_id(&c[0]));
            Ok(())
        },
    );
    steps.step(
        "the client says which thread list it holds",
        |world, _, _| {
            shell_frame(world)?;
            let from = kept(world).subs;
            let sub = world.mc.subscriptions[from..]
                .iter()
                .rfind(|sub| sub["shape"]["type"] == json!("shell"))
                .cloned()
                .unwrap_or(Value::Null);
            let held = sub["have"][&world.mc.name].as_array().cloned().unwrap_or_default();
            expect!(
                held.len() == 2
                    && held[0] == json!(world.mc.epoch)
                    && held[1].as_i64().unwrap_or(0) > 0,
                "it asked with {}",
                show(&sub)
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the MC sends only the row of {Q}"),
        |world, c, _| {
            let frame = shell_frame(world)?;
            let sent = frame["rows"].as_array().cloned().unwrap_or_default();
            expect!(
                own_mc(world, &frame)["reset"] == json!(false)
                    && sent.len() == 1
                    && sent[0][3]["title"] == json!(c[0]),
                "the MC sent {}",
                show(&frame)
            );
            Ok(())
        },
    );
    steps.step("the MC sends its whole thread list", |world, _, _| {
        let frame = shell_frame(world)?;
        let rows = world.mc.threads.len() + world.mc.projects.len();
        expect!(
            own_mc(world, &frame)["reset"] == json!(true)
                && frame["rows"].as_array().map(Vec::len) == Some(rows),
            "the MC holds {rows} rows and sent {}",
            show(&frame)
        );
        Ok(())
    });
    steps.step(
        &format!("the thread list shows {Q}, {Q} and {Q}"),
        |world, c, _| {
            wait_for_list(world)?;
            for title in c.iter() {
                let key = key_of(world, title);
                expect!(
                    !section_of(world, &key).is_empty(),
                    "\"{title}\" is not in the list: {}",
                    show(&world.state("sidebar"))
                );
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the thread list shows {Q} but not {Q}"),
        |world, c, _| {
            wait_for_list(world)?;
            let (shown, gone) = (key_of(world, &c[0]), key_of(world, &c[1]));
            expect!(
                !section_of(world, &shown).is_empty() && section_of(world, &gone).is_empty(),
                "the list is {}",
                show(&world.state("sidebar"))
            );
            Ok(())
        },
    );
    steps.step(
        "the thread list no longer shows the thread",
        |world, _, _| {
            wait_for_list(world)?;
            let thread = kept(world).thread.clone();
            expect!(
                section_of(world, &thread).is_empty(),
                "the list is {}",
                show(&world.state("sidebar"))
            );
            Ok(())
        },
    );

    // A long thread.
    steps.step(
        "the thread has more turns than a client loads at once",
        |world, _, _| make_long(world),
    );
    steps.step("the user opens it again", |world, _, _| open_again(world));
    steps.step(
        "the thread has more turns than are loaded",
        |world, _, _| {
            make_long(world)?;
            open_again(world)?;
            expect_newest_turns(world)
        },
    );
    steps.step(
        "the client asks its MC for the newest turns only",
        |world, _, _| {
            let asked = last_asked(world)?;
            let sub = sub_of(world, asked);
            expect!(
                sub["offset"].is_null()
                    && sub["window"]["items"].as_i64() == Some(WINDOW_ITEMS)
                    && sub["shape"]["kinds"].get("turn-item").is_some(),
                "it asked with {}",
                show(&sub)
            );
            Ok(())
        },
    );
    steps.step("only those turns are sent and shown", |world, _, _| {
        let from = kept(world).sent;
        let snapshots = sent_since(world, from, "snapshot");
        expect!(
            snapshots.len() == 1,
            "the MC sent {} snapshots",
            snapshots.len()
        );
        let items = snapshots[0]["rows"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|row| row[0] == json!("turn-item"))
            .count() as i64;
        expect!(
            items == WINDOW_TURNS * TURN_ITEMS && snapshots[0]["floor"].is_number(),
            "the MC sent {items} of the thread's {} turn items",
            TURNS * TURN_ITEMS
        );
        expect_newest_turns(world)
    });
    steps.step("the user loads earlier turns", |world, _, _| {
        // A view the newest turns overflow, at their end.
        let brick = timeline_brick(world, 480.0)?;
        let list = rows_view(world, &brick)?;
        world.wait_for_with(
            |w| {
                // As the brick reads its own end (Timeline.qml nearEnd).
                let end = real(w, list, "originY") + real(w, list, "contentHeight") - 4.0;
                real(w, list, "contentHeight") > real(w, list, "height")
                    && real(w, list, "contentY") + real(w, list, "height") >= end
            },
            |w| {
                format!(
                    "the view to show the end of the thread; it is at {} of {} from {}, {} high",
                    real(w, list, "contentY"),
                    real(w, list, "contentHeight"),
                    real(w, list, "originY"),
                    real(w, list, "height")
                )
            },
        )?;
        expect!(
            !read(world, |t| t.loading_earlier())?,
            "earlier turns were asked for before the user reached the top"
        );
        // The MC takes its time, so the user sees the wait.
        world.mc.hold("pages");
        // The wheel, up to the top of what is loaded.
        let (x, y) = brick.at(world, list, 0.5, 0.5)?;
        world.hover_at(x, y)?;
        for _ in 0..200 {
            if read(world, |t| t.loading_earlier())? {
                return Ok(());
            }
            let taken = world.wheel(x, y, 4.0)?;
            world.advance(50)?;
            if !taken {
                return Err(Failure(format!(
                    "the wheel at {x},{y} was not taken; the view is at {} (moving {})",
                    real(world, list, "contentY"),
                    flag(world, list, "moving")
                )));
            }
        }
        fail!(
            "the top of the thread; the view is at {} from {} of {}, {} high, wheel at {x},{y}",
            real(world, list, "contentY"),
            real(world, list, "originY"),
            real(world, list, "contentHeight"),
            real(world, list, "height")
        )
    });
    steps.step(
        "the user sees that earlier turns are loading",
        |world, _, _| {
            let brick = the_brick(world)?;
            let marker = brick.item(world, "loadingEarlier")?;
            expect!(
                brick.flag(world, marker, "visible")
                    && brick.shows(world, "Loading earlier turns…")?,
                "nothing says earlier turns are loading"
            );
            // Asked for once, however long the user stays at the top.
            world.sync()?;
            let from = kept(world).sent;
            let asked = sent_since(world, from, "more");
            expect!(
                asked.len() == 1 && asked[0]["items"].as_i64() == Some(WINDOW_ITEMS),
                "the MC was asked for earlier turns {} times",
                asked.len()
            );
            Ok(())
        },
    );
    steps.step(
        "the earlier turns appear above without moving the message being read",
        |world, _, _| {
            let brick = the_brick(world)?;
            let list = rows_view(world, &brick)?;
            // The scroll has come to rest on the first loaded row.
            world.wait_for("the view to come to rest", |w| !flag(w, list, "moving"))?;
            let reading = text(&role(world, 0, "rowId"));
            let Some(reading_y) = drawn_at(world, &brick, &reading) else {
                fail!("the message being read ({reading}) is not drawn");
            };
            let state = kept(world);
            state.reading.clone_from(&reading);
            state.reading_y = reading_y;
            let ids: Vec<Value> = (0..row_count(world)?).map(|r| role(world, r, "rowId")).collect();
            let obj = timeline_object(world)?;
            // One insert above the rows held, which keep their ids and their order.
            let changes = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
            let seen = changes.clone();
            hal_c2_shell::thread_view::timeline_model::TimelineModel::observe(
                world.engine(),
                obj,
                move |_, out| seen.borrow_mut().push(format!("{out:?}")),
            );
            world.mc.answer_held();
            expect_every_turn(world)?;
            let added = (TURNS - WINDOW_TURNS) as usize * ROWS_PER_TURN;
            let after: Vec<Value> = (added..row_count(world)?)
                .map(|r| role(world, r, "rowId"))
                .collect();
            expect!(after == ids, "the rows held changed");
            let told = changes.borrow().join("; ");
            expect!(
                !told.contains("Reset") && !told.contains("Remove") && !told.contains("Move"),
                "the earlier turns came as {told}"
            );
            // Drawn where it was, with the earlier turns above it to scroll to.
            world.wait_for_with(
                |w| {
                    drawn_at(w, &brick, &reading).is_some() && !flag(w, list, "atYBeginning")
                },
                |w| {
                    format!(
                        "the view to lay the earlier turns out above; it is at {} from {} of {}, the message {}",
                        real(w, list, "contentY"),
                        real(w, list, "originY"),
                        real(w, list, "contentHeight"),
                        drawn_at(w, &brick, &reading)
                            .map_or("not drawn".into(), |y| format!("at {y}, from {reading_y}"))
                    )
                },
            )?;
            let y = drawn_at(world, &brick, &reading).unwrap_or(-1.0);
            expect!(
                (y - reading_y).abs() < 1.0,
                "the message being read moved from {reading_y} to {y}"
            );
            let marker = brick.item(world, "loadingEarlier")?;
            expect!(
                !brick.flag(world, marker, "visible"),
                "the thread still says earlier turns are loading"
            );
            Ok(())
        },
    );
    steps.step(
        "what is loaded leaves room in the view",
        |world, _, _| {
            timeline_brick(world, 4000.0)?;
            Ok(())
        },
    );
    steps.step(
        "the earlier turns are loaded without the user scrolling",
        |world, _, _| {
            expect_every_turn(world)?;
            let from = kept(world).sent;
            expect!(
                !sent_since(world, from, "more").is_empty(),
                "the MC was not asked for earlier turns"
            );
            Ok(())
        },
    );

    // A long thread the user left.
    steps.step(
        &format!("the user loaded the earlier turns of a long thread in {Q}"),
        |world, c, _| {
            look_at_thread(world, &c[0])?;
            make_long(world)?;
            open_again(world)?;
            expect_newest_turns(world)?;
            load_earlier(world)?;
            expect_every_turn(world)
        },
    );
    steps.step(
        "the user leaves the thread for more than five minutes and returns",
        |world, _, _| {
            home(world)?;
            world.set_time(world.now() + chrono::Duration::seconds(6 * 60));
            world.advance(6 * 60 * 1000)?;
            let thread = kept(world).thread.clone();
            let held = world.with::<ThreadStore, _>(|t, _| t.timeline(&thread).is_some())?;
            expect!(!held, "the thread is still held");
            open_again(world)
        },
    );
    steps.step(
        "the thread comes back as its newest turns without being sent again",
        |world, _, _| {
            expect_newest_turns(world)?;
            let asked = last_asked(world)?;
            let sub = sub_of(world, asked);
            expect!(
                sub["offset"].is_number()
                    && sub["window"]["floor"].is_number()
                    && answer_to(world, asked, "snapshot").is_empty()
                    && answer_to(world, asked, "events").is_empty(),
                "it asked with {}",
                show(&sub)
            );
            Ok(())
        },
    );
    steps.step("its earlier turns can be loaded again", |world, _, _| {
        load_earlier(world)?;
        expect_every_turn(world)
    });
}

#[allow(dead_code)]
fn unused(_: &mut FakeMc, _: &Value) {
    let _ = at;
}
