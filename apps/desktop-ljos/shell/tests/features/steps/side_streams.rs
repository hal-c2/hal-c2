//! The shell's side streams (src/streams.rs): what its own threads hand the
//! window, bounded, each with a name someone watching the app sees it by
//! (features/desktop/side-streams.feature). Only this shell has them, so the
//! file names this runner in its sources and no desktop-qt steps file twins
//! this one.
//!
//! "The window" is [`World::pump`]'s frames; holding them leaves what the
//! threads send in the streams, as a window that draws nothing would.

use std::cell::RefCell;
use std::rc::Rc;

use hal_c2_shell::device::decoder::{Decode, Decoded, Notify, Picture};
use hal_c2_shell::device::stream::DeviceStream;
use ljos::DrainBudget;
use ljos::prelude::ObjectId;
use ljos_runtime::observe::MailboxSample;
use serde_json::json;

use crate::harness::{Failure, Q, Steps};
use crate::world::{QueueWatch, World};
use crate::{expect, fail};

/// The MC's frames to the window.
const MC: &str = "mc";
const DEVICE_FRAMES: &str = "device-frames";

/// What the MC's queue had handled when a burst began.
#[derive(Default)]
struct Burst {
    frames_before: usize,
}

/// A device screen whose decoder is the scenario's: it decodes when told.
#[derive(Default)]
struct Screen {
    stream: Option<ObjectId>,
    notify: Rc<RefCell<Option<Notify>>>,
}

/// A decoder with nothing to decode: it only tells the shell it has a
/// picture, as a real one does from its own thread.
struct Told;

impl Decode for Told {
    fn reset(&mut self, _: Option<Vec<u8>>) {}
    fn push(&mut self, _: Vec<u8>, _: usize, _: bool) -> bool {
        true
    }
    fn push_jpeg(&mut self, _: Vec<u8>) {}
    fn set_maximum_size(&mut self, _: (u32, u32)) {}
    fn take_events(&mut self) -> Vec<Decoded> {
        Vec::new()
    }
    fn take_frame(&mut self) -> Option<Picture> {
        None
    }
    fn source_size(&self) -> (u32, u32) {
        (0, 0)
    }
}

fn watch(world: &mut World) -> Result<&mut QueueWatch, Failure> {
    world
        .queues
        .as_mut()
        .ok_or_else(|| Failure("nobody is watching the shell's queues".into()))
}

/// The stream named `name` now: the newest of that name, should an earlier
/// scenario's shell still hold one.
fn sample(world: &mut World, name: &str) -> Result<MailboxSample, Failure> {
    let samples = watch(world)?.look();
    samples
        .into_iter()
        .rev()
        .find(|s| s.name == name)
        .ok_or_else(|| Failure(format!("no queue is named {name:?}")))
}

fn describe(s: &MailboxSample) -> String {
    format!(
        "{}: {}/{} queued, {} sent, {} refused, {} replaced, {} dropped, {} handled",
        s.name, s.depth, s.capacity, s.sent, s.refused, s.replaced, s.evicted, s.drained
    )
}

pub fn register(steps: &mut Steps) {
    steps.step("someone is watching the shell's queues", |world, _, _| {
        world.queues = Some(QueueWatch::start());
        Ok(())
    });
    steps.step(
        "the window handles at most (\\d+) messages from each queue a frame",
        |world, c, _| {
            let most: usize = c[0].parse().map_err(|_| Failure("a count".into()))?;
            world.streams().budget = DrainBudget::count(most);
            Ok(())
        },
    );
    steps.step("the window draws no frames", |world, _, _| {
        world.frames_held = true;
        Ok(())
    });
    steps.step("the window draws frames again", |world, _, _| {
        world.frames_held = false;
        world.pump()
    });

    // The MC.
    steps.step(
        &format!("the MC sends (\\d+) updates to the thread {Q}, the last titled {Q}"),
        |world, c, _| {
            let count: usize = c[0].parse().map_err(|_| Failure("a count".into()))?;
            let frames_before = watch(world)?.seen.get(MC).map_or(0, |w| w.frames);
            world.part::<Burst>().frames_before = frames_before;
            for update in 1..=count {
                let title = if update == count {
                    c[2].clone()
                } else {
                    format!("Update {update}")
                };
                let row = world
                    .mc
                    .threads
                    .entry(c[1].clone())
                    .or_insert_with(|| json!({}));
                row["title"] = json!(title);
                let row = row.clone();
                world.mc.send_row(&c[1], &row);
            }
            Ok(())
        },
    );
    steps.step(
        "the shell handled the MC's messages over more than one frame",
        |world, _, _| {
            world.sync()?;
            let before = world.part::<Burst>().frames_before;
            let watched = watch(world)?.seen.get(MC).copied().unwrap_or_default();
            let frames = watched.frames - before;
            expect!(frames > 1, "the burst was handled in {frames} frame(s)");
            Ok(())
        },
    );
    steps.step(
        "the MC's queue never held more than it has room for",
        |world, _, _| {
            let now = sample(world, MC)?;
            let peak = watch(world)?.seen.get(MC).map_or(0, |w| w.peak);
            expect!(
                peak <= now.capacity,
                "it held {peak} of the MC's messages, with room for {}",
                now.capacity
            );
            Ok(())
        },
    );
    steps.step("no message from the MC was dropped", |world, _, _| {
        world.sync()?;
        let mc = sample(world, MC)?;
        expect!(
            mc.refused == 0
                && mc.replaced == 0
                && mc.evicted == 0
                && mc.drained + mc.depth as u64 == mc.sent,
            "{}",
            describe(&mc)
        );
        Ok(())
    });
    steps.step(
        "the MC's queue fills to its size and grows no further",
        |world, _, _| {
            world.wait_for_with(
                |_| {
                    ljos_runtime::observe::mailboxes(0)
                        .iter()
                        .rev()
                        .find(|s| s.name == MC)
                        .is_some_and(|s| s.depth == s.capacity)
                },
                |_| {
                    ljos_runtime::observe::mailboxes(0)
                        .iter()
                        .rev()
                        .find(|s| s.name == MC)
                        .map_or_else(|| "the MC's queue".into(), describe)
                },
            )?;
            // Full, and the MC's connection waits for room: nothing it
            // sent was refused, replaced or dropped to fit.
            let mc = sample(world, MC)?;
            expect!(
                mc.depth == mc.capacity && mc.refused == 0 && mc.replaced == 0 && mc.evicted == 0,
                "{}",
                describe(&mc)
            );
            Ok(())
        },
    );

    // A device screen.
    steps.step("a device screen is open", |world, _, _| {
        let notify = world.part::<Screen>().notify.clone();
        hal_c2_shell::device::set_decoders(world.engine(), move |told| {
            *notify.borrow_mut() = Some(told);
            Box::new(Told)
        });
        let stream = DeviceStream::create(world.engine(), None, world.connection())
            .map_err(|e| Failure(format!("the screen did not open: {e}")))?;
        world.part::<Screen>().stream = Some(stream);
        Ok(())
    });
    steps.step(
        "the device screen decodes (\\d+) pictures",
        |world, c, _| {
            let count: usize = c[0].parse().map_err(|_| Failure("a count".into()))?;
            let Some(notify) = world.part::<Screen>().notify.borrow().clone() else {
                fail!("no device screen is open");
            };
            // From a thread of its own, as a decoder tells it.
            std::thread::spawn(move || {
                for _ in 0..count {
                    notify();
                }
            })
            .join()
            .map_err(|_| Failure("the decoder's thread panicked".into()))?;
            Ok(())
        },
    );
    steps.step(
        "one notice of a new picture waits for the window",
        |world, _, _| {
            let frames = sample(world, DEVICE_FRAMES)?;
            expect!(frames.depth == 1, "{}", describe(&frames));
            Ok(())
        },
    );
    steps.step(
        "(\\d+) of the screen's notices were replaced by newer ones",
        |world, c, _| {
            let count: u64 = c[0].parse().map_err(|_| Failure("a count".into()))?;
            let frames = sample(world, DEVICE_FRAMES)?;
            expect!(
                frames.replaced == count && frames.refused == 0,
                "{}",
                describe(&frames)
            );
            Ok(())
        },
    );
    steps.step(
        "nothing waits for the window in the device screens' queue",
        |world, _, _| {
            let frames = sample(world, DEVICE_FRAMES)?;
            expect!(
                frames.depth == 0 && frames.drained >= 1,
                "{}",
                describe(&frames)
            );
            Ok(())
        },
    );

    // What someone watching sees.
    steps.step(
        "the shell's queues are listed with these sizes:",
        |world, _, table| {
            let samples = watch(world)?.look();
            for row in table.iter().skip(1) {
                let (name, size) = (&row[0], &row[1]);
                let Some(found) = samples.iter().rev().find(|s| s.name == name) else {
                    fail!(
                        "{name:?} is not listed; the queues are {:?}",
                        samples.iter().map(|s| s.name).collect::<Vec<_>>()
                    );
                };
                expect!(
                    found.capacity.to_string() == *size && found.kind.as_str() == "batch",
                    "{name:?} is a {} of {}, not a batch of {size}",
                    found.kind.as_str(),
                    found.capacity
                );
            }
            Ok(())
        },
    );
    steps.step(
        &format!("the {Q} queue counts what was sent to the window and what the window handled"),
        |world, c, _| {
            world.sync()?;
            let queue = sample(world, &c[0])?;
            expect!(
                queue.sent > 0
                    && queue.drained > 0
                    && queue.drained + queue.depth as u64 == queue.sent,
                "{}",
                describe(&queue)
            );
            Ok(())
        },
    );
}
