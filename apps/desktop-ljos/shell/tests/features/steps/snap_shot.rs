//! Snap Shot on the desktop (SnapShot, desktop-qt's SnapShotSteps.cpp):
//! Settings, SnapShots and capturing a window into the draft
//! (features/settings/snap-shot.feature, source-control/snap-shot.feature).
//! The desktop portal is a fake backend, so no scenario touches the session
//! bus: its shortcut answers at once, and the Snap Shot shortcut is the fake
//! saying so.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controllers::composer::kept;
use hal_c2_shell::controllers::drafts;
use hal_c2_shell::controllers::keybindings::Keymap;
use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::controllers::snap_shot::{SnapShot, deliver};
use hal_c2_shell::snap_shot::{
    self, Backend, Captured, Check, Event, Mode, Platform, PortalFactory, Session, Shortcut,
};
use image::{Rgba, RgbaImage};
use serde_json::{Value, json};

use super::snap_shot_bus::{self, PortalDesktop};
use super::stream::{PROJECT, THREAD, look_at_thread};
use crate::expect;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;

pub(crate) const SECTION: &str = "/settings/snap-shot";

/// Qt's key codes and modifier masks, as the recorder receives them.
pub(crate) const KEY_AT: i64 = 0x40;
pub(crate) const KEY_O: i64 = 0x4f;
pub(crate) const KEY_L: i64 = 0x4c;
pub(crate) const CONTROL: i64 = 0x0400_0000;
pub(crate) const SHIFT: i64 = 0x0200_0000;
pub(crate) const META: i64 = 0x1000_0000;

/// What the desktop does, for the fake backend to read and record into.
#[derive(Default)]
pub(crate) struct Desktop {
    pub picker: bool,
    /// Why capture access is not ready, if it is not.
    pub message: String,
    /// The desktop turns down the shortcut with this.
    pub refuse: String,
    /// The next capture fails with this.
    pub failure: String,
    pub image: Option<RgbaImage>,
    pub binds: Vec<String>,
    pub releases: usize,
    pub configured: usize,
    /// Each capture: true when the user picked the window.
    pub captures: Vec<bool>,
    pub played: Vec<String>,
    /// Shortcut checks wait for [`answer_check`], counted here.
    pub hold_checks: bool,
    pub checks: usize,
    /// The desktop will not pause the capture shortcut, with this reason.
    pub refuse_pause: Option<String>,
    /// The desktop does not answer a shortcut's bind.
    pub hold_shortcuts: bool,
    /// What the backend's thread left for `arrive`.
    pub arrivals: Vec<Event>,
}

/// The trigger as a desktop names it: CTRL+SHIFT+2 is Ctrl+Shift+2.
fn describe_trigger(trigger: &str) -> String {
    trigger
        .split('+')
        .map(|part| match part {
            "CTRL" => "Ctrl",
            "SHIFT" => "Shift",
            "ALT" => "Alt",
            "LOGO" => "Super",
            other => other,
        })
        .collect::<Vec<_>>()
        .join("+")
}

/// desktop-qt's FakePortal: the portal of a desktop whose shortcut answers
/// at once, standing in for [`hal_c2_shell::snap_shot::portal`].
pub(crate) struct Fake {
    state: Rc<RefCell<Desktop>>,
    desktop: String,
    probed: bool,
    shortcut: Shortcut,
}

impl Fake {
    pub(crate) fn new(state: Rc<RefCell<Desktop>>, platform: &Platform) -> Fake {
        Fake {
            state,
            desktop: platform.desktop.clone(),
            probed: false,
            shortcut: Shortcut::default(),
        }
    }
}

impl Backend for Fake {
    fn session(&self) -> Session {
        let d = self.state.borrow();
        Session {
            ready: self.probed,
            mode: Mode::Portal,
            backend: if d.picker {
                "picker"
            } else {
                "screenshot-portal"
            }
            .into(),
            desktop: self.desktop.clone(),
            message: d.message.clone(),
            ..Session::default()
        }
    }
    fn shortcut(&self) -> Shortcut {
        self.shortcut.clone()
    }
    fn probe(&mut self) -> Vec<Event> {
        if self.probed {
            return Vec::new();
        }
        self.probed = true;
        vec![Event::Changed]
    }
    fn bind(&mut self, trigger: &str) -> Vec<Event> {
        let mut d = self.state.borrow_mut();
        d.binds.push(trigger.to_owned());
        self.shortcut = Shortcut::default();
        if d.hold_shortcuts {
            self.shortcut.pending = true;
        } else if d.refuse.is_empty() {
            self.shortcut.registered = true;
            self.shortcut.label = describe_trigger(trigger);
        } else {
            self.shortcut.message = d.refuse.clone();
        }
        vec![Event::Changed]
    }
    fn release(&mut self) -> Vec<Event> {
        self.state.borrow_mut().releases += 1;
        self.shortcut = Shortcut::default();
        vec![Event::Changed]
    }
    fn configure(&mut self) -> Vec<Event> {
        self.state.borrow_mut().configured += 1;
        Vec::new()
    }
    fn check_shortcut(&mut self, shortcut: &Value) -> Option<Check> {
        {
            let mut d = self.state.borrow_mut();
            if d.hold_checks {
                d.checks += 1;
                return None;
            }
        }
        // The portal's own check (the Backend default).
        Some(match snap_shot::portal_trigger(shortcut) {
            Err(problem) => Check {
                available: false,
                message: problem,
            },
            Ok(_) => Check {
                available: true,
                message: "Your desktop will confirm this shortcut when you save it.".into(),
            },
        })
    }
    fn pause(&mut self, paused: bool) -> Result<(), String> {
        match &self.state.borrow().refuse_pause {
            Some(reason) if paused => Err(reason.clone()),
            _ => Ok(()),
        }
    }
    fn capture(&mut self) -> Vec<Event> {
        let mut d = self.state.borrow_mut();
        let picked = d.picker;
        d.captures.push(picked);
        if !d.failure.is_empty() {
            return vec![Event::Failed(std::mem::take(&mut d.failure))];
        }
        // The portal names no app.
        vec![Event::Captured(Captured {
            image: d.image.clone().unwrap_or_else(|| RgbaImage::new(1, 1)),
            app_name: "Window".into(),
            window_title: String::new(),
            context: Value::Null,
        })]
    }
    fn play(&mut self, sound: &str) {
        self.state.borrow_mut().played.push(sound.to_owned());
    }
    fn arrive(&mut self) -> Vec<Event> {
        std::mem::take(&mut self.state.borrow_mut().arrivals)
    }
}

/// The desktop of the running shell, and whether its backend is installed.
#[derive(Default)]
pub(crate) struct Snap {
    pub desktop: Rc<RefCell<Desktop>>,
    pub installed: bool,
    /// The window commands asked since the last capture.
    pub raised: Rc<RefCell<Vec<String>>>,
}

thread_local! {
    /// What the platforms' steps reset with the desktop (their stand-ins).
    static RESETS: RefCell<Vec<fn()>> = const { RefCell::new(Vec::new()) };
}

/// `reset` runs whenever a scenario starts a fresh desktop, before the
/// shell restarts: a platform's steps put their stand-ins away in it.
pub(crate) fn on_reset(reset: fn()) {
    RESETS.with(|resets| resets.borrow_mut().push(reset));
}

pub(crate) fn snap(world: &mut World) -> &mut Snap {
    world.part::<Snap>()
}

pub(crate) fn desktop(world: &mut World) -> Rc<RefCell<Desktop>> {
    snap(world).desktop.clone()
}

/// A process environment of session `kind` (wayland, x11) on `current`
/// (XDG_CURRENT_DESKTOP, none when empty).
pub(crate) fn environment(kind: &str, current: &str) -> HashMap<String, String> {
    let mut env = HashMap::from([("XDG_SESSION_TYPE".to_owned(), kind.to_owned())]);
    if !current.is_empty() {
        env.insert("XDG_CURRENT_DESKTOP".to_owned(), current.to_owned());
    }
    env
}

/// The shell's backend is the one [`snap_shot::create`] gives in the
/// stand-in environment: the fake portal, unless a platform's steps stand
/// in for something else.
pub(crate) fn install(world: &mut World) -> Outcome {
    if snap(world).installed {
        return Ok(());
    }
    world.connect()?;
    if !snap_shot::environment_overridden() {
        snap_shot::set_environment(Some(environment("wayland", "")));
    }
    let state = desktop(world);
    if !snap_shot::portal_overridden() {
        snap_shot::set_portal_factory(Some(Rc::new(move |platform: &Platform| {
            Box::new(Fake::new(state.clone(), platform)) as Box<dyn Backend>
        })));
    }
    let backend = snap_shot::create(None);
    world.with::<SnapShot, _>(|controller, engine| controller.set_backend(engine, backend))?;
    let raised = snap(world).raised.clone();
    let bridge = Bridge::of(world.engine()).object();
    let _ =
        world
            .engine()
            .connect_by_name(bridge, "windowCommandRequested", move |engine, args| {
                raised
                    .borrow_mut()
                    .push(engine.to_js_string(&args[0]).to_string());
            });
    snap(world).installed = true;
    world.pump()
}

pub(crate) fn page(world: &World) -> Value {
    world.state("snapShot")
}

pub(crate) fn field(world: &World, path: &str) -> Value {
    at(&page(world), path).clone()
}

pub(crate) fn send(world: &mut World, action: &str, payload: Value) -> Outcome {
    world.dispatch(&format!("snapShot.{action}"), payload)?;
    settle(world)
}

/// What the desktop portal said, handed to the shell.
pub(crate) fn settle(world: &mut World) -> Outcome {
    snap_shot_bus::settle(world.engine());
    world.pump()
}

pub(crate) fn setting(world: &World, key: &str) -> Value {
    Settings::of(world.engine())
        .setting(world.engine(), key)
        .unwrap_or(Value::Null)
}

pub(crate) fn set_setting(world: &mut World, key: &str, value: Value) -> Outcome {
    Settings::of(world.engine()).set(world.engine(), key, value);
    world.pump()?;
    settle(world)
}

/// Waits for the page's `path` to be `value`.
pub(crate) fn wait_for_field(world: &mut World, path: &str, value: Value) -> Outcome {
    let path = path.to_owned();
    world.wait_for_with(
        |w| {
            snap_shot_bus::settle(w.engine());
            field(w, &path) == value
        },
        |w| {
            format!(
                "{path} to be {}; Snap Shot is {}",
                show(&value),
                show(&page(w))
            )
        },
    )
}

/// A fresh desktop in `env`, nothing bound yet, its shell restarted: the
/// platforms' stand-ins are put away first, and the portal is the fake
/// unless `portal` stands in for it.
pub(crate) fn reset_with(
    world: &mut World,
    env: HashMap<String, String>,
    portal: Option<PortalFactory>,
) -> Outcome {
    let mut image = RgbaImage::new(320, 200);
    for pixel in image.pixels_mut() {
        *pixel = Rgba([0, 139, 139, 255]);
    }
    RESETS.with(|resets| {
        for reset in resets.borrow().iter() {
            reset();
        }
    });
    // A new state: the shell being dropped may still release the old one.
    let fresh = Desktop {
        image: Some(image),
        ..Desktop::default()
    };
    let state = snap(world);
    state.desktop = Rc::new(RefCell::new(fresh));
    state.installed = false;
    state.raised = Rc::new(RefCell::new(Vec::new()));
    snap_shot_bus::bus().borrow_mut().active = portal.is_some();
    snap_shot::set_environment(Some(env));
    snap_shot::set_portal_factory(portal);
    world.restart()?;
    // The shell's controllers start once the MC has answered.
    world.connect()?;
    world.sync()?;
    install(world)?;
    // Snap Shot is Linux's, so its shortcuts are too, whatever runs the
    // tests.
    Keymap::of(world.engine()).set_mac(world.engine(), false);
    world.pump()
}

/// A fresh Wayland desktop on `desktop` (no named compositor when empty),
/// or an X11 one.
fn reset_desktop(world: &mut World, desktop: &str, x11: bool) -> Outcome {
    let kind = if x11 { "x11" } else { "wayland" };
    reset_with(world, environment(kind, desktop), None)
}

/// The fake portal answers the oldest shortcut check it holds.
pub(crate) fn answer_check(world: &mut World, available: bool, message: &str) -> Outcome {
    let state = desktop(world);
    {
        let mut d = state.borrow_mut();
        expect!(d.checks > 0, "a shortcut check to answer");
        d.checks -= 1;
        d.arrivals.push(Event::Checked(Check {
            available,
            message: message.to_owned(),
        }));
    }
    deliver(world.engine());
    world.pump()
}

pub(crate) fn project_row(id: &str) -> Value {
    json!({"id": id, "title": id, "workspaceRoot": format!("/work/{id}"),
        "scripts": []})
}

/// A thread of "shop", open in the window.
pub(crate) fn open_thread(world: &mut World) -> Outcome {
    if !world
        .mc
        .part::<super::stream::FakeStreams>()
        .thread
        .is_empty()
    {
        return Ok(());
    }
    install(world)?;
    let project = project_row(PROJECT);
    world
        .mc
        .projects
        .insert(PROJECT.to_owned(), project.clone());
    world.mc.send_row_of(PROJECT, &project, "project");
    world.sync()?;
    look_at_thread(world, PROJECT)
}

pub(crate) fn open_panel(world: &mut World) -> Outcome {
    install(world)?;
    world.with::<Navigation, _>(|navigation, engine| {
        navigation.open(engine, Route::Settings(SECTION.to_owned()))
    })?;
    world.wait_for_with(
        |w| field(w, "ready").as_bool() == Some(true),
        |w| format!("Snap Shot to be ready; it is {}", show(&page(w))),
    )
}

pub(crate) fn ctrl_shift_2() -> Value {
    json!({"key": "2", "metaKey": false, "ctrlKey": false, "shiftKey": true,
        "altKey": false, "modKey": true})
}

/// Snap Shot on and holding Ctrl+Shift+2.
pub(crate) fn turn_on(world: &mut World) -> Outcome {
    install(world)?;
    set_setting(world, "snapShotShortcut", ctrl_shift_2())?;
    set_setting(world, "snapShotEnabled", json!(true))?;
    if desktop(world).borrow().hold_shortcuts {
        return Ok(());
    }
    world.wait_for_with(
        |w| field(w, "shortcut.registered").as_bool() == Some(true),
        |w| format!("the shortcut to be held; Snap Shot is {}", show(&page(w))),
    )
}

pub(crate) fn press(world: &mut World, key: i64, modifiers: i64) -> Outcome {
    send(
        world,
        "record.key",
        json!({"key": key, "modifiers": modifiers}),
    )
}

pub(crate) fn record_ctrl_shift_2(world: &mut World) -> Outcome {
    if setting(world, "snapShotEnabled").as_bool() != Some(true) {
        set_setting(world, "snapShotEnabled", json!(true))?;
    }
    send(world, "record.start", Value::Null)?;
    press(world, KEY_AT, CONTROL | SHIFT)
}

pub(crate) fn expect_off(world: &World) -> Outcome {
    expect!(
        setting(world, "snapShotEnabled").as_bool() != Some(true)
            && field(world, "switchOn").as_bool() != Some(true)
            && field(world, "status") == "Turn this on to set up snapshots.",
        "capture to be off and invite turning it on; Snap Shot is {}",
        show(&page(world))
    );
    Ok(())
}

/// The user presses the Snap Shot shortcut.
pub(crate) fn capture(world: &mut World) -> Outcome {
    install(world)?;
    snap(world).raised.borrow_mut().clear();
    if snap_shot_bus::bus().borrow().active {
        snap_shot_bus::bus().borrow_mut().press();
        return settle(world);
    }
    // The backend's thread says the shortcut was pressed.
    desktop(world).borrow_mut().arrivals.push(Event::Activated);
    deliver(world.engine());
    world.pump()
}

pub(crate) fn thread_key(world: &World) -> String {
    format!("{}:{THREAD}", world.mc.environment_id)
}

pub(crate) fn attachments(world: &World, target: &str) -> Vec<Value> {
    kept::attachments(world.engine(), target)
}

/// The one capture `target`'s draft holds.
pub(crate) fn attached(world: &World, target: &str) -> Outcome<Value> {
    let images = attachments(world, target);
    expect!(
        images.len() == 1,
        "one capture on {target}'s draft, not {}",
        show(&Value::Array(images.clone()))
    );
    let image = images[0].clone();
    expect!(
        at(&image, "source.kind") == "snap-shot",
        "the attachment to be a snapshot; it is {}",
        show(&image)
    );
    Ok(image)
}

pub(crate) fn toast_titled(world: &World, title: &str) -> Option<Value> {
    world.state("toasts")["items"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|toast| text(&toast["title"]) == title)
        .cloned()
}

pub(crate) fn expect_toast(world: &World, title: &str, description: &str) -> Outcome {
    let toast = toast_titled(world, title);
    expect!(
        toast.is_some_and(|toast| text(&toast["description"]) == description),
        "the toast \"{title}\": {description}; the shell shows {}",
        show(&world.state("toasts"))
    );
    Ok(())
}

/// A capture of noise: no image format makes it small.
pub(crate) fn noise(width: u32, height: u32) -> RgbaImage {
    let mut state: u64 = 0x9e37_79b9_7f4a_7c15;
    let mut image = RgbaImage::new(width, height);
    for pixel in image.pixels_mut() {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let bytes = state.to_le_bytes();
        *pixel = Rgba([bytes[0], bytes[1], bytes[2], 255]);
    }
    image
}

pub(crate) fn shortcut_setting(world: &World) -> Value {
    setting(world, "snapShotShortcut")
}

pub(crate) fn binds_end_with(world: &mut World, trigger: &str) -> bool {
    desktop(world)
        .borrow()
        .binds
        .last()
        .is_some_and(|last| last == trigger)
}

/// The user saves the shortcut they recorded.
pub(crate) fn save(world: &mut World) -> Outcome {
    expect!(
        field(world, "shortcut.canSave").as_bool() == Some(true),
        "the shortcut to be ready to save; Snap Shot is {}",
        show(&page(world))
    );
    world.answer_question = None;
    send(world, "shortcut.save", Value::Null)
}

pub(crate) fn ctrl_shift_1() -> Value {
    json!({"key": "1", "metaKey": false, "ctrlKey": false, "shiftKey": true,
        "altKey": false, "modKey": true})
}

/// Snap Shot on with `shortcut`, without waiting on the desktop's answer.
pub(crate) fn turn_on_with(world: &mut World, shortcut: Value) -> Outcome {
    install(world)?;
    set_setting(world, "snapShotShortcut", shortcut)?;
    set_setting(world, "snapShotEnabled", json!(true))
}

/// A desktop that captures and gives shortcuts through the desktop portal,
/// answering as `portal` says, with Settings, SnapShots open.
pub(crate) fn portal_desktop(world: &mut World, portal: PortalDesktop) -> Outcome {
    {
        let bus = snap_shot_bus::bus();
        let mut bus = bus.borrow_mut();
        bus.reset();
        bus.desktop = portal;
    }
    reset_with(
        world,
        environment("wayland", ""),
        Some(snap_shot_bus::factory()),
    )?;
    open_panel(world)
}

/// The desktop's answers to the fake backend changed.
pub(crate) fn update(world: &mut World) -> Outcome {
    desktop(world).borrow_mut().arrivals.push(Event::Changed);
    deliver(world.engine());
    world.pump()
}

pub(crate) fn has_wizard(world: &World) -> bool {
    field(world, "wizard").get("step").is_some()
}

/// Qt's key codes the recorder hears, past [`KEY_AT`] and friends.
pub(crate) const KEY_TAB: i64 = 0x0100_0001;
pub(crate) const KEY_BACKTAB: i64 = 0x0100_0002;
pub(crate) const KEY_CONTROL: i64 = 0x0100_0021;
pub(crate) const KEY_HOME: i64 = 0x0100_0010;
pub(crate) const KEY_UP: i64 = 0x0100_0013;
pub(crate) const ALT: i64 = 0x0800_0000;

/// The keys of a shortcut as the feature names it.
pub(crate) fn press_named(world: &mut World, name: &str) -> Outcome {
    let (key, modifiers) = match name {
        "Shift+K" => (0x4b, SHIFT),
        "Ctrl+C" => (0x43, CONTROL),
        "Ctrl+S" => (0x53, CONTROL),
        "Ctrl+Z" => (0x5a, CONTROL),
        "Alt+Tab" => (KEY_TAB, ALT),
        "Super+L" => (KEY_L, META),
        "Ctrl+Alt+K" => (0x4b, CONTROL | ALT),
        other => crate::fail!("no keys for {other}"),
    };
    press(world, key, modifiers)
}

pub(crate) fn toast_saying(world: &World, description: &str) -> Option<Value> {
    world.state("toasts")["items"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|toast| text(&toast["description"]) == description)
        .cloned()
}

pub fn register(steps: &mut Steps) {
    // settings/snap-shot.feature
    steps.step(
        "the user opens Settings, SnapShots in the desktop app",
        |world, _, _| {
            reset_desktop(world, "", false)?;
            open_panel(world)
        },
    );
    steps.step("the user never turned on Snap Shot", |world, _, _| {
        expect!(
            setting(world, "snapShotEnabled").as_bool() != Some(true),
            "Snap Shot is on"
        );
        Ok(())
    });
    steps.step(
        "capture is off and the user is invited to turn it on to set up snapshots",
        |world, _, _| expect_off(world),
    );
    steps.step("the user turns on snapshots", |world, _, _| {
        send(world, "enable", json!({"on": true}))
    });
    steps.step(
        "setup asks the user to allow capture and then to choose a shortcut",
        |world, _, _| {
            // The portal asks for capture at the first capture, so setup
            // opens on the shortcut with allowing capture the step before it.
            expect!(
                field(world, "wizard.step") == "shortcut"
                    && field(world, "wizard.heading") == "Choose your shortcut",
                "setup to ask for a shortcut; Snap Shot is {}",
                show(&page(world))
            );
            send(world, "setup.back", Value::Null)?;
            expect!(
                field(world, "wizard.step") == "access"
                    && field(world, "wizard.heading") == "Allow snapshots",
                "setup to ask to allow capture first; Snap Shot is {}",
                show(&page(world))
            );
            send(world, "setup.continue", Value::Null)?;
            expect!(
                field(world, "wizard.step") == "shortcut",
                "allowing capture to lead to the shortcut; Snap Shot is {}",
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step("the user chooses to finish later", |world, _, _| {
        // Close, once Snap Shot was on before setup opened.
        let close = field(world, "wizard.closeLabel");
        expect!(
            close == "Finish later" || close == "Close",
            "setup to offer finishing later; Snap Shot is {}",
            show(&page(world))
        );
        send(world, "setup.close", Value::Null)
    });
    steps.step("Snap Shot is on with a shortcut", |world, _, _| {
        turn_on(world)
    });
    steps.step("the user turns off snapshots", |world, _, _| {
        send(world, "enable", json!({"on": false}))
    });
    steps.step(
        "the shortcut is released and nothing that was installed is removed",
        |world, _, _| {
            let releases = desktop(world).borrow().releases;
            expect!(
                releases > 0 && field(world, "shortcut.registered").as_bool() != Some(true),
                "the shortcut to be released; Snap Shot is {}",
                show(&page(world))
            );
            expect!(
                shortcut_setting(world) == ctrl_shift_2(),
                "the shortcut to stay chosen for next time"
            );
            expect_off(world)
        },
    );
    steps.step(
        "the user changes the shortcut and presses Ctrl\\+Shift\\+2",
        |world, _, _| {
            record_ctrl_shift_2(world)?;
            // "the user cancels" (project.rs) discards the recorded keys.
            world.answer_question = Some(Rc::new(|world: &mut World, _| {
                send(world, "shortcut.discard", Value::Null)
            }));
            Ok(())
        },
    );
    steps.step(
        "the shortcut is saved as Ctrl\\+Shift\\+2",
        |world, _, _| {
            // The recorded keys are the shortcut once the user saves them.
            save(world)?;
            expect!(
                shortcut_setting(world) == ctrl_shift_2(),
                "the shortcut to be saved; it is {}",
                show(&shortcut_setting(world))
            );
            let binds = desktop(world).borrow().binds.join(",");
            expect!(
                binds_end_with(world, "CTRL+SHIFT+2")
                    && field(world, "shortcut.keys") == "Ctrl+Shift+2",
                "the desktop to hold Ctrl+Shift+2; it holds {binds}, Snap Shot is {}",
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step("the user is recording a new shortcut", |world, _, _| {
        set_setting(world, "snapShotEnabled", json!(true))?;
        send(world, "record.start", Value::Null)?;
        expect!(
            field(world, "shortcut.status") == "Press your shortcut. Esc cancels.",
            "the recorder to listen; Snap Shot is {}",
            show(&page(world))
        );
        Ok(())
    });
    steps.step("the previous shortcut is kept", |world, _, _| {
        expect!(
            field(world, "shortcut.recording").as_bool() != Some(true)
                && field(world, "shortcut.changed").as_bool() != Some(true),
            "recording to stop with nothing changed; Snap Shot is {}",
            show(&page(world))
        );
        expect!(
            shortcut_setting(world)["kind"] == "both-shift-keys",
            "the shortcut to stay both Shift keys"
        );
        Ok(())
    });
    steps.step(
        "the user records (a modifier with no key on Linux|a shortcut HAL-C2 already uses|a shortcut the system reserves)",
        |world, c, _| {
            set_setting(world, "snapShotEnabled", json!(true))?;
            send(world, "record.start", Value::Null)?;
            if c[0].starts_with("a modifier") {
                // Both Shift keys, and no key with them.
                for code in [50, 62] {
                    send(
                        world,
                        "record.modifier",
                        json!({"modifier": "shift", "code": code, "down": true}),
                    )?;
                }
                Ok(())
            } else if c[0].contains("HAL-C2") {
                press(world, KEY_O, CONTROL | SHIFT) // New thread
            } else {
                press(world, KEY_L, META) // Super+L locks the screen
            }
        },
    );
    steps.step("the shortcut is refused because (.+)", |world, c, _| {
        let reason = match c[0].as_str() {
            "Linux shortcuts need a letter, number or function key" => {
                "Add a letter, number, or function key to your shortcut."
            }
            "it collides with a HAL-C2 keybinding" => "HAL-C2 already uses this for \"",
            "the system reserves it" => "The system already uses this shortcut.",
            other => other,
        };
        let status = text(&field(world, "shortcut.status"));
        expect!(
            field(world, "shortcut.canSave").as_bool() != Some(true) && status.starts_with(reason),
            "the shortcut to be refused ({}); Snap Shot is {}",
            c[0],
            show(&page(world))
        );
        Ok(())
    });
    steps.step("the user turns sound off", |world, _, _| {
        send(world, "sound", json!({"value": "off"}))
    });
    steps.step("captures happen without a sound", |world, _, _| {
        expect!(
            field(world, "sound.label") == "Off",
            "the sound to show Off; Snap Shot is {}",
            show(&page(world))
        );
        open_thread(world)?;
        turn_on(world)?;
        capture(world)?;
        attached(world, &thread_key(world))?;
        let played = desktop(world).borrow().played.join(",");
        expect!(played.is_empty(), "no sound; {played} played");
        Ok(())
    });
    steps.step("the user picks the Click sound", |world, _, _| {
        send(world, "sound", json!({"value": "camera-shutter"}))
    });
    steps.step("captures play Click instead of Whoosh", |world, _, _| {
        expect!(
            field(world, "sound.label") == "Click",
            "the sound to show Click; Snap Shot is {}",
            show(&page(world))
        );
        open_thread(world)?;
        turn_on(world)?;
        capture(world)?;
        let played = desktop(world).borrow().played.clone();
        expect!(
            played == ["camera-shutter"],
            "Click; {} played",
            played.join(",")
        );
        Ok(())
    });
    steps.step("a Niri session", |world, _, _| {
        reset_desktop(world, "niri", false)?;
        set_setting(world, "snapShotEnabled", json!(true))?;
        open_panel(world)
    });
    steps.step(
        "the user is told capture effects are not available on Niri",
        |world, _, _| {
            for cue in ["flash", "animations"] {
                expect!(
                    field(world, &format!("{cue}.status"))
                        == "Capture effects aren't available on Niri."
                        && field(world, &format!("{cue}.enabled")).as_bool() != Some(true),
                    "{cue} to be unavailable on Niri; Snap Shot is {}",
                    show(&page(world))
                );
            }
            Ok(())
        },
    );
    steps.step("the desktop will not allow the shortcut", |world, _, _| {
        desktop(world).borrow_mut().refuse = "Your desktop did not allow the shortcut.".into();
        Ok(())
    });
    steps.step(
        "the user is told the desktop did not allow it and can ask again",
        |world, _, _| {
            save(world)?;
            expect!(
                field(world, "shortcut.status") == "Your desktop did not allow the shortcut."
                    && field(world, "shortcut.permissions").as_bool() == Some(true),
                "the refusal and a way to ask again; Snap Shot is {}",
                show(&page(world))
            );
            send(world, "shortcut.permissions", Value::Null)?;
            expect!(
                desktop(world).borrow().configured == 1,
                "the desktop to show its shortcut permissions again"
            );
            Ok(())
        },
    );

    // source-control/snap-shot.feature
    steps.step(
        "the desktop app with Snap Shot turned on and its shortcut set",
        |world, _, _| {
            reset_desktop(world, "", false)?;
            turn_on(world)
        },
    );
    steps.step(
        "(?:the user is working in a browser with a thread open in HAL-C2|HAL-C2 is the app in front|a Linux Wayland session with an app running under XWayland in front)",
        |world, _, _| open_thread(world),
    );
    steps.step(
        "the user presses the Snap Shot shortcut(?: from another app)?",
        |world, _, _| capture(world),
    );
    steps.step("the user captures a window", |world, _, _| {
        open_thread(world)?;
        capture(world)
    });
    steps.step(
        "(?:an image of the (?:browser|HAL-C2) window is attached to the (?:thread's )?draft|that app's window is captured)",
        |world, _, _| {
            let image = attached(world, &thread_key(world))?;
            expect!(
                image["mimeType"] == "image/png" && text(&image["name"]).starts_with("window-"),
                "a PNG of the window; the attachment is {}",
                show(&image)
            );
            expect!(
                world.actions_of("composer.focus").len() == 1,
                "the composer to take focus"
            );
            Ok(())
        },
    );
    steps.step("HAL-C2 comes to the front", |world, _, _| {
        let raised = snap(world).raised.borrow().clone();
        expect!(
            raised == ["raise"],
            "the window to come forward; asked {}",
            raised.join(",")
        );
        Ok(())
    });
    steps.step(
        &format!("no thread is open and the current project is {Q}"),
        |world, c, _| {
            let project = project_row(&c[0]);
            world.mc.projects.insert(c[0].clone(), project.clone());
            world.mc.send_row_of(&c[0], &project, "project");
            world.sync()
        },
    );
    steps.step(
        &format!("a new draft in {Q} holds the capture"),
        |world, c, _| {
            let route = world.state("route");
            expect!(
                at(&route, "kind") == "draft",
                "a draft to show; the route is {}",
                show(&route)
            );
            let id = text(&route["draftId"]);
            let draft = drafts::draft(world.engine(), &id);
            expect!(
                draft.is_some_and(|draft| draft.project_id == c[0]),
                "the draft to be in {}",
                c[0]
            );
            attached(world, &id)?;
            Ok(())
        },
    );
    steps.step(
        "a capture is attached to a draft that was not sent",
        |world, _, _| {
            open_thread(world)?;
            capture(world)?;
            attached(world, &thread_key(world))?;
            Ok(())
        },
    );
    steps.step("the user restarts HAL-C2", |world, _, _| {
        // The restarted shell has the same desktop, its own backend.
        snap(world).installed = false;
        world.restart()?;
        world.connect()?;
        world.sync()?;
        install(world)
    });
    steps.step(
        "the capture is still attached to the draft",
        |world, _, _| {
            let image = attached(world, &thread_key(world))?;
            expect!(
                at(&image, "source.appName") == "Window",
                "the capture to keep its source; it is {}",
                show(&image)
            );
            Ok(())
        },
    );
    steps.step("the window is too large to attach", |world, _, _| {
        open_thread(world)?;
        world.with::<SnapShot, _>(|controller, _| controller.set_max_image_bytes(20 * 1024))?;
        desktop(world).borrow_mut().image = Some(noise(800, 600));
        Ok(())
    });
    steps.step(
        "nothing is attached and the user is told the capture was too large",
        |world, _, _| {
            let held = attachments(world, &thread_key(world));
            expect!(
                held.is_empty(),
                "nothing attached; {}",
                show(&Value::Array(held.clone()))
            );
            expect_toast(
                world,
                "Snapshot failed",
                "The captured window is too large to attach.",
            )
        },
    );
    steps.step(
        "the desktop app runs in a Linux X11 session",
        |world, _, _| {
            reset_desktop(world, "", true)?;
            set_setting(world, "snapShotEnabled", json!(true))
        },
    );
    steps.step("the user opens Snap Shot settings", |world, _, _| {
        // On a fresh desktop when the scenario starts here
        // (composer/qt-shell-backlog.feature).
        if world.shell_subscriptions() == 0 {
            reset_desktop(world, "", false)?;
        }
        open_panel(world)
    });
    steps.step("the user can record the global shortcut", |world, _, _| {
        record_ctrl_shift_2(world)?;
        send(world, "shortcut.save", Value::Null)?;
        let binds = desktop(world).borrow().binds.join(",");
        expect!(
            shortcut_setting(world) == ctrl_shift_2()
                && binds_end_with(world, "CTRL+SHIFT+2")
                && field(world, "shortcut.keys") == "Ctrl+Shift+2",
            "the desktop to hold Ctrl+Shift+2; it holds {binds}, Snap Shot is {}",
            show(&page(world))
        );
        Ok(())
    });
    steps.step(
        "the user can see whether the desktop compositor supports it",
        |world, _, _| {
            // This desktop captures through its portal, and the page says so.
            expect!(
                field(world, "available").as_bool() == Some(true)
                    && field(world, "mode") == "portal"
                    && field(world, "status") == "Ready to capture",
                "the page to say capture is supported; Snap Shot is {}",
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step("the composer is focused in HAL-C2", |world, _, _| {
        // On a desktop whose own prompt asks what to capture.
        reset_desktop(world, "", false)?;
        turn_on(world)?;
        desktop(world).borrow_mut().picker = true;
        open_thread(world)
    });
    steps.step(
        "the user presses the global Snap Shot shortcut and selects a screen region",
        |world, _, _| {
            capture(world)?;
            expect!(
                desktop(world).borrow().captures == [true],
                "the desktop to ask what to capture"
            );
            Ok(())
        },
    );
    steps.step("the capture is attached to that composer", |world, _, _| {
        let target = thread_key(world);
        let image = attached(world, &target)?;
        let composer = world.state("composer");
        let shown = composer["attachments"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        expect!(
            image["mimeType"] == "image/png"
                && shown.len() == 1
                && shown[0]["id"] == image["id"]
                && text(&composer["target"]) == target,
            "the composer to show the capture; it shows {}",
            show(&Value::Array(shown.clone()))
        );
        expect!(
            world.actions_of("composer.focus").len() == 1,
            "the composer to take focus"
        );
        Ok(())
    });
    steps.step(
        "Snap Shot is shown as not supported on this platform",
        |world, _, _| {
            expect!(
                field(world, "available").as_bool() != Some(true)
                    && field(world, "rows").as_bool() != Some(true)
                    && text(&field(world, "status")).contains("not supported"),
                "Snap Shot to be unsupported; it is {}",
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step(
        "a Linux Wayland session on another compositor",
        |world, _, _| reset_desktop(world, "sway", false),
    );
    steps.step("the user sets up Snap Shot", |world, _, _| {
        open_panel(world)?;
        send(world, "enable", json!({"on": true}))?;
        record_ctrl_shift_2(world)?;
        send(world, "setup.done", Value::Null)?;
        expect!(
            field(world, "wizard").is_null(),
            "setup to finish; Snap Shot is {}",
            show(&page(world))
        );
        Ok(())
    });
    steps.step("capture works through the desktop portal", |world, _, _| {
        expect!(
            field(world, "mode") == "portal"
                && field(world, "status") == "Ready to capture"
                && binds_end_with(world, "CTRL+SHIFT+2"),
            "the portal to hold the shortcut; Snap Shot is {}",
            show(&page(world))
        );
        Ok(())
    });
    steps.step(
        "a Linux Wayland session on a compositor without automatic capture",
        |world, _, _| {
            desktop(world).borrow_mut().picker = true;
            open_thread(world)?;
            open_panel(world)?;
            expect!(
                field(world, "status") == "Manual capture only — you'll choose a window each time",
                "capture to be manual; Snap Shot is {}",
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step("the user picks the window to capture", |world, _, _| {
        expect!(
            desktop(world).borrow().captures == [true],
            "the desktop's window picker to open"
        );
        Ok(())
    });
    steps.step(
        "the attachment has no text or controls data",
        |world, _, _| {
            let image = attached(world, &thread_key(world))?;
            let mut keys: Vec<String> = image["source"]
                .as_object()
                .map(|source| source.keys().cloned().collect())
                .unwrap_or_default();
            keys.sort();
            expect!(
                keys == ["appName", "capturedAt", "kind", "windowTitle"],
                "only the capture's source; it is {}",
                show(&image["source"])
            );
            Ok(())
        },
    );
    steps.step(
        "the user cancels the desktop's capture prompt",
        |world, _, _| {
            desktop(world).borrow_mut().failure = "Snapshot was cancelled.".into();
            Ok(())
        },
    );
    steps.step(
        "nothing is attached and the user is told the snapshot was cancelled",
        |world, _, _| {
            let held = attachments(world, &thread_key(world));
            expect!(
                held.is_empty(),
                "nothing attached; {}",
                show(&Value::Array(held.clone()))
            );
            expect_toast(world, "Snapshot failed", "Snapshot was cancelled.")
        },
    );
    steps.step("no project has been added", |world, _, _| {
        expect!(world.mc.projects.is_empty(), "the MC has projects");
        Ok(())
    });
    steps.step(
        "nothing is attached and the user is asked to add a project first",
        |world, _, _| {
            expect!(
                desktop(world).borrow().captures.len() == 1,
                "the window to be captured"
            );
            expect_toast(
                world,
                "Snapshot taken, but no project is available",
                "Add a project, then capture the window again.",
            )
        },
    );
    steps.step("Snap Shot is off", |world, _, _| {
        set_setting(world, "snapShotEnabled", json!(false))
    });
    steps.step(
        "the desktop no longer holds the shortcut and nothing is captured",
        |world, _, _| {
            let (releases, captures) = {
                let d = desktop(world);
                let d = d.borrow();
                (d.releases, d.captures.len())
            };
            let held = attachments(world, &thread_key(world));
            expect!(
                releases > 0 && captures == 0 && held.is_empty(),
                "no capture after turning off; {captures} captures"
            );
            Ok(())
        },
    );
}
