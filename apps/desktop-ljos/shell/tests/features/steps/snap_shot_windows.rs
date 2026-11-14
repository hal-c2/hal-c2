//! Snap Shot on Windows (WindowsSnapShot) in features/settings/snap-shot.feature,
//! with Windows itself faked as desktop-qt's SnapShotWindowsSteps.cpp fakes
//! it. The Win32 half only builds on Windows.
//!
//! The steps the macOS rows share are registered in snap_shot_mac.rs, which
//! asks [`on_windows`] and comes here.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::{Rc, Weak};

use hal_c2_shell::controllers::snap_shot::deliver;
use hal_c2_shell::snap_shot::mac::Rect;
use hal_c2_shell::snap_shot::windows::{
    self, CAPTURE_TIMEOUT_MS, COULD_NOT_CAPTURE, Grab, Inbox, NO_WINDOW, Signal, Window,
    WindowsSystem,
};
use image::{Rgba, RgbaImage};
use serde_json::{Value, json};

use super::snap_shot::{
    attachments, expect_toast, field, open_panel, open_thread, page, reset_with, send, setting,
    thread_key,
};
use super::snap_shot_mac::{attached_size, press_both};
use crate::expect;
use crate::harness::{Outcome, Q, Steps, at, show};
use crate::world::World;

/// What Windows does, for the fake to read and record into.
struct Machine {
    window: Option<Window>,
    image: RgbaImage,
    played: Vec<String>,
    answer_grabs: bool,
    grab_running: bool,
    refuse_pairs: bool,
    animations: bool,
    flashes: usize,
    flights: usize,
    flights_with_flash: usize,
    inbox: Option<Inbox>,
}

impl Default for Machine {
    fn default() -> Machine {
        Machine {
            window: Some(Window {
                id: 7,
                title: "npm test".into(),
                bounds: Rect::new(10, 20, 800, 600),
                program: "C:\\Tools\\Terminal.exe".into(),
            }),
            image: RgbaImage::from_pixel(320, 200, Rgba([0, 139, 139, 255])),
            played: Vec::new(),
            answer_grabs: true,
            grab_running: false,
            refuse_pairs: false,
            animations: true,
            flashes: 0,
            flights: 0,
            flights_with_flash: 0,
            inbox: None,
        }
    }
}

/// The scenario's Windows, none until a step says the app runs on it. Its
/// factory holds only a weak hold on `alive`, so a later scenario's shell
/// never meets this one's machine.
#[derive(Default)]
struct StandIn {
    machine: Rc<RefCell<Machine>>,
    alive: Rc<()>,
    on: bool,
}

struct FakeWindows {
    machine: Rc<RefCell<Machine>>,
}

impl WindowsSystem for FakeWindows {
    fn foreground(&mut self) -> Option<Window> {
        self.machine.borrow().window.clone()
    }
    fn grab(&mut self, _bounds: Rect) -> Grab {
        let mut machine = self.machine.borrow_mut();
        if machine.answer_grabs {
            return Grab::Now(machine.image.clone());
        }
        machine.grab_running = true;
        Grab::Later
    }
    fn grabbing(&self) -> bool {
        self.machine.borrow().grab_running
    }
    fn cancel_grab(&mut self) {}
    fn hold_hot_key(&mut self, _modifiers: u32, _key: u32) -> bool {
        true
    }
    fn release_hot_key(&mut self) {}
    fn can_hold_hot_key(&mut self, _modifiers: u32, _key: u32) -> bool {
        true
    }
    fn watch_pair(&mut self, _left: u32, _right: u32) -> bool {
        !self.machine.borrow().refuse_pairs
    }
    fn stop_watching(&mut self) {}
    fn can_watch_pair(&mut self, _left: u32, _right: u32) -> bool {
        !self.machine.borrow().refuse_pairs
    }
    fn animations_enabled(&self) -> bool {
        self.machine.borrow().animations
    }
    fn flash(&mut self, _bounds: Rect, _animated: bool) {
        self.machine.borrow_mut().flashes += 1;
    }
    fn fly(&mut self, _image: &RgbaImage, _bounds: Rect, flash: bool) {
        let mut machine = self.machine.borrow_mut();
        machine.flights += 1;
        if flash {
            machine.flights_with_flash += 1;
        }
    }
    fn cue_showing(&self) -> bool {
        false
    }
    fn play(&mut self, sound: &str) {
        self.machine.borrow_mut().played.push(sound.to_owned());
    }
}

fn stand_in(world: &mut World) -> &mut StandIn {
    world.part::<StandIn>()
}

fn machine(world: &mut World) -> Rc<RefCell<Machine>> {
    stand_in(world).machine.clone()
}

/// Whether the scenario's app runs on its Windows.
pub(crate) fn on_windows(world: &mut World) -> bool {
    stand_in(world).on
}

fn run_on_windows(world: &mut World) -> Outcome {
    let machine = machine(world);
    *machine.borrow_mut() = Machine::default();
    let alive: Weak<()> = Rc::downgrade(&stand_in(world).alive);
    stand_in(world).on = true;
    windows::set_factory(Some(Rc::new(move |inbox: Inbox| {
        alive.upgrade()?;
        machine.borrow_mut().inbox = Some(inbox);
        Some(Box::new(FakeWindows {
            machine: machine.clone(),
        }) as Box<dyn WindowsSystem>)
    })));
    let env = HashMap::from([("OS".to_owned(), "Windows_NT".to_owned())]);
    reset_with(world, env, None)?;
    open_panel(world)
}

pub(crate) fn turn_on(world: &mut World) -> Outcome {
    send(world, "enable", json!({"on": true}))
}

fn enabled_without_setup(world: &World) -> bool {
    setting(world, "snapShotEnabled").as_bool() == Some(true)
        && field(world, "wizard.step").is_null()
}

fn draft(world: &World) -> Vec<Value> {
    attachments(world, &thread_key(world))
}

/// What Windows says on its own, handed to the shell.
fn post(world: &mut World, signal: Signal) -> Outcome {
    let inbox = machine(world).borrow().inbox.clone();
    let Some(inbox) = inbox else {
        crate::fail!("the desktop to run on Windows");
    };
    inbox.post(signal);
    deliver(world.engine());
    world.pump()
}

/// The shortcut pressed on this Windows, for snap_shot.rs's own press.
pub(crate) fn windows_press(world: &mut World) -> Outcome {
    if setting(world, "snapShotEnabled").as_bool() != Some(true) {
        turn_on(world)?;
    }
    open_thread(world)?;
    post(world, Signal::Pressed)
}

fn capture(world: &mut World) -> Outcome {
    windows_press(world)?;
    world.wait_for_with(
        |w| !draft(w).is_empty(),
        |w| format!("the capture on the draft; Snap Shot is {}", show(&page(w))),
    )
}

/// Both Super or Alt keys, saved as the shortcut.
pub(crate) fn choose_pair(world: &mut World, key: &str) -> Outcome {
    turn_on(world)?;
    let modifier = match key {
        "Super" => "meta",
        "Alt" => "alt",
        _ => crate::fail!("{key} pairs on macOS, not Windows"),
    };
    press_both(world, modifier, "left", "right")?;
    send(world, "shortcut.save", Value::Null)
}

/// Both Alt keys, which Windows will not let HAL-C2 watch.
pub(crate) fn refuse_pair(world: &mut World) -> Outcome {
    machine(world).borrow_mut().refuse_pairs = true;
    turn_on(world)?;
    press_both(world, "alt", "left", "right")?;
    // Escape, as Qt names it.
    send(
        world,
        "record.key",
        json!({"key": 0x0100_0000, "modifiers": 0}),
    )
}

/// Snap Shot on and a thread open, for a capture step to change Windows.
fn ready(world: &mut World) -> Outcome {
    open_thread(world)?;
    turn_on(world)
}

/// The Windows rows of the steps snap_shot_mac.rs registers for both.
pub(crate) fn no_window(world: &mut World) -> Outcome {
    ready(world)?;
    machine(world).borrow_mut().window = None;
    Ok(())
}

/// The capture ended with nothing attached and the toast saying why. A
/// grab that never answers is given up on at its deadline.
pub(crate) fn told(world: &mut World, could_not_capture: bool) -> Outcome {
    let stuck = {
        let machine = machine(world);
        let m = machine.borrow();
        m.grab_running && !m.answer_grabs
    };
    if stuck {
        world.advance(CAPTURE_TIMEOUT_MS)?;
        world.pump()?;
    }
    let images = draft(world);
    expect!(
        images.is_empty(),
        "nothing attached; the draft has {}",
        show(&Value::Array(images))
    );
    let said = if could_not_capture {
        COULD_NOT_CAPTURE
    } else {
        NO_WINDOW
    };
    expect_toast(world, "Snapshot failed", said)
}

/// The press after the stuck grab ends works.
pub(crate) fn none_kept(world: &mut World) -> Outcome {
    {
        let machine = machine(world);
        let mut m = machine.borrow_mut();
        m.grab_running = false;
        m.answer_grabs = true;
    }
    capture(world)?;
    let images = draft(world);
    expect!(
        images.len() == 1,
        "the next capture to attach; the draft has {}",
        show(&Value::Array(images))
    );
    Ok(())
}

pub(crate) fn large_window(world: &mut World) -> Outcome {
    ready(world)?;
    machine(world).borrow_mut().image = RgbaImage::from_pixel(5120, 2000, Rgba([0, 139, 139, 255]));
    Ok(())
}

pub(crate) fn expect_shrunk(world: &mut World) -> Outcome {
    let size = attached_size(world)?;
    expect!(
        draft(world).len() == 1 && size == (2560, 1000),
        "2560x1000 with its shape kept; it is {}x{}",
        size.0,
        size.1
    );
    Ok(())
}

pub fn register(steps: &mut Steps) {
    steps.step("the desktop app runs on Windows", |world, _, _| {
        run_on_windows(world)
    });
    steps.step("capture is on and no setup is opened", |world, _, _| {
        expect!(
            enabled_without_setup(world),
            "capture on with no setup; Snap Shot is {}",
            show(&page(world))
        );
        Ok(())
    });
    steps.step("the setup button is not shown", |world, _, _| {
        expect!(
            field(world, "setupLabel")
                .as_str()
                .unwrap_or_default()
                .is_empty(),
            "no setup button; Snap Shot is {}",
            show(&page(world))
        );
        Ok(())
    });
    steps.step("the user is asked for nothing", |world, _, _| {
        expect!(
            enabled_without_setup(world),
            "nothing to allow; Snap Shot is {}",
            show(&page(world))
        );
        Ok(())
    });

    // The cues.
    steps.step("the user turns (flash|animation) off", |world, c, _| {
        run_on_windows(world)?;
        open_thread(world)?;
        turn_on(world)?;
        let key = if c[0] == "flash" {
            "flash"
        } else {
            "animations"
        };
        send(world, "set", json!({"key": key, "value": false}))
    });
    steps.step(
        "captures happen without a flash on the captured window",
        |world, _, _| {
            capture(world)?;
            let machine = machine(world);
            let m = machine.borrow();
            expect!(
                draft(world).len() == 1
                    && m.flashes == 0
                    && m.flights_with_flash == 0
                    && m.flights == 1,
                "a flight with no flash: {} flashes, {} of {} flights flashed",
                m.flashes,
                m.flights_with_flash,
                m.flights
            );
            Ok(())
        },
    );
    steps.step(
        "captures happen without the image flying into the draft",
        |world, _, _| {
            capture(world)?;
            let machine = machine(world);
            let m = machine.borrow();
            expect!(
                draft(world).len() == 1 && m.flights == 0 && m.flashes == 1,
                "a still flash and no flight: {} flashes, {} flights",
                m.flashes,
                m.flights
            );
            Ok(())
        },
    );
    steps.step("the sound, flash and animation are on", |world, _, _| {
        run_on_windows(world)?;
        ready(world)
    });
    steps.step(
        "the sound plays, the captured window flashes and the image flies into the draft",
        |world, _, _| {
            let machine = machine(world);
            let m = machine.borrow();
            expect!(
                m.played.len() == 1 && m.flights_with_flash == 1 && draft(world).len() == 1,
                "the sound and a flight with its flash: played {}, {} flights flashed",
                m.played.join(","),
                m.flights_with_flash
            );
            Ok(())
        },
    );
    steps.step("the system asks for reduced motion", |world, _, _| {
        run_on_windows(world)?;
        ready(world)?;
        machine(world).borrow_mut().animations = false;
        Ok(())
    });
    steps.step(
        "the image lands in the draft without animating",
        |world, _, _| {
            let flights = machine(world).borrow().flights;
            expect!(
                draft(world).len() == 1 && flights == 0,
                "no flight; {flights} flights"
            );
            Ok(())
        },
    );

    // source-control/snap-shot.feature: capturing.
    steps.step(
        "the Windows window capture does not answer in time",
        |world, _, _| {
            ready(world)?;
            machine(world).borrow_mut().answer_grabs = false;
            Ok(())
        },
    );
    steps.step(
        "an earlier Windows window capture is still running",
        |world, _, _| {
            ready(world)?;
            machine(world).borrow_mut().grab_running = true;
            Ok(())
        },
    );
    steps.step(
        &format!("the window belongs to the program {Q}"),
        |world, c, _| {
            ready(world)?;
            if let Some(window) = &mut machine(world).borrow_mut().window {
                window.program = format!("C:\\Program Files\\{}", c[0]);
            }
            Ok(())
        },
    );
    steps.step("the window reports no program name", |world, _, _| {
        ready(world)?;
        if let Some(window) = &mut machine(world).borrow_mut().window {
            window.program.clear();
        }
        Ok(())
    });
    steps.step("the user captures it", |world, _, _| capture(world));
    steps.step(
        &format!("the attachment names the app {Q}"),
        |world, c, _| {
            let images = draft(world);
            expect!(
                images.len() == 1 && at(&images[0], "source.appName") == c[0].as_str(),
                "the app {}; the draft has {}",
                c[0],
                show(&Value::Array(images.clone()))
            );
            Ok(())
        },
    );
}
