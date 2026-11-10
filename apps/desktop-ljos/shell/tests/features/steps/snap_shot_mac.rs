//! Snap Shot on macOS (MacSnapShot and its permission helper) in
//! features/settings/snap-shot.feature, on a MacPlatform that answers as the
//! scenario's Mac does (desktop-qt's SnapShotMacosSteps.cpp). The native
//! platform itself only builds on Apple.
//!
//! The steps the Windows rows of a scenario share are registered here once
//! and answered by snap_shot_windows.rs when the scenario runs on Windows.

use std::cell::RefCell;
use std::rc::{Rc, Weak};

use hal_c2_shell::controllers::keybindings::Keymap;
use hal_c2_shell::controllers::snap_shot::{SnapShot, deliver};
use hal_c2_shell::snap_shot;
use hal_c2_shell::snap_shot::Permissions;
use hal_c2_shell::snap_shot::mac::{
    self, ACCESSIBILITY, Capture, Helper, Inbox, MacPlatform, Rect, SCREEN_RECORDING,
    SettingsWindow, Signal,
};
use image::{Rgba, RgbaImage};
use serde_json::{Value, json};

use super::snap_shot::{
    SECTION, attachments, field, install, open_panel, open_thread, page, send, set_setting,
    setting, snap, thread_key, toast_titled,
};
use super::snap_shot_windows as windows;
use crate::expect;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;

/// What this Mac allows and what it was asked.
pub(crate) struct FakeMac {
    allowed: Permissions,
    read_fails: bool,
    refuse_watch: bool,
    capture_failure: String,
    empty_image: bool,
    window: (u32, u32),
    requested: Vec<String>,
    watched: Vec<String>,
    captures: usize,
    settings: Option<SettingsWindow>,
    helper_text: String,
    helper_bounds: Rect,
    helper_shown: bool,
    helper_closes: usize,
    reveals: usize,
    focuses: usize,
    /// Where the running backend hears from this Mac.
    inbox: Option<Inbox>,
}

impl Default for FakeMac {
    fn default() -> FakeMac {
        FakeMac {
            allowed: Permissions::default(),
            read_fails: false,
            refuse_watch: false,
            capture_failure: String::new(),
            empty_image: false,
            window: (320, 200),
            requested: Vec::new(),
            watched: Vec::new(),
            captures: 0,
            settings: None,
            helper_text: String::new(),
            helper_bounds: Rect::default(),
            helper_shown: false,
            helper_closes: 0,
            reveals: 0,
            focuses: 0,
            inbox: None,
        }
    }
}

/// The scenario's Mac: none until a step says the app runs on macOS. The
/// factory it gives holds only a weak hold on `alive`, so a later scenario's
/// shell never meets this one's Mac.
#[derive(Default)]
struct StandIn {
    fake: Rc<RefCell<FakeMac>>,
    alive: Rc<()>,
    on: bool,
}

struct FakePlatform {
    mac: Rc<RefCell<FakeMac>>,
}

impl MacPlatform for FakePlatform {
    fn permissions(&mut self) -> Option<Permissions> {
        let mac = self.mac.borrow();
        (!mac.read_fails).then_some(mac.allowed)
    }
    fn request(&mut self, permission: &str) {
        self.mac.borrow_mut().requested.push(permission.to_owned());
    }
    fn open_settings(&mut self, _permission: &str) {
        self.mac.borrow_mut().settings = Some(SettingsWindow {
            open: true,
            frontmost: true,
            bounds: Rect::new(100, 100, 800, 600),
        });
    }
    fn watch_pair(&mut self, modifier: &str) -> bool {
        let mut mac = self.mac.borrow_mut();
        if mac.refuse_watch {
            return false;
        }
        mac.watched.push(modifier.to_owned());
        true
    }
    fn hold_chord(&mut self, _shortcut: &Value) -> bool {
        true
    }
    fn let_go(&mut self) {}
    fn capture(&mut self, include_text: bool) -> Option<Capture> {
        let mut mac = self.mac.borrow_mut();
        mac.captures += 1;
        let mut result = Capture {
            app: "Safari".into(),
            title: "Docs".into(),
            ..Capture::default()
        };
        if !mac.capture_failure.is_empty() {
            result.step = "capture-window".into();
            result.status = mac.capture_failure.clone();
            result.exit_code = 1;
            return Some(result);
        }
        if mac.empty_image {
            return Some(result);
        }
        let (width, height) = mac.window;
        result.image = Some(RgbaImage::from_pixel(
            width,
            height,
            Rgba([0, 139, 139, 255]),
        ));
        if include_text {
            let text = "Docs: Getting started";
            result.context = json!({"accessibleText": text,
                "accessibility": {"format": "flat-text", "text": text, "truncated": false}});
        }
        Some(result)
    }
    fn settings_window(&mut self) -> Option<SettingsWindow> {
        self.mac.borrow().settings
    }
    fn show_helper(&mut self, bounds: Rect, text: &str) {
        let mut mac = self.mac.borrow_mut();
        mac.helper_shown = true;
        mac.helper_bounds = bounds;
        mac.helper_text = text.to_owned();
    }
    fn hide_helper(&mut self) {
        self.mac.borrow_mut().helper_shown = false;
    }
    fn close_helper(&mut self) {
        let mut mac = self.mac.borrow_mut();
        mac.helper_shown = false;
        mac.helper_closes += 1;
    }
    fn helper_focused(&mut self) -> bool {
        false
    }
    fn reveal_app(&mut self) {
        self.mac.borrow_mut().reveals += 1;
    }
    fn focus_app(&mut self) {
        self.mac.borrow_mut().focuses += 1;
    }
    fn play(&mut self, _sound: &str) {}
}

fn stand_in(world: &mut World) -> &mut StandIn {
    world.part::<StandIn>()
}

fn mac_of(world: &mut World) -> Rc<RefCell<FakeMac>> {
    stand_in(world).fake.clone()
}

/// Whether the scenario's app runs on its Mac.
pub(crate) fn mac_overridden(world: &mut World) -> bool {
    stand_in(world).on
}

/// The app starts on the scenario's Mac.
fn start_app(world: &mut World) -> Outcome {
    let fake = mac_of(world);
    let alive: Weak<()> = Rc::downgrade(&stand_in(world).alive);
    stand_in(world).on = true;
    mac::set_factory(Some(Rc::new(move |inbox: Inbox| {
        alive.upgrade()?;
        fake.borrow_mut().inbox = Some(inbox);
        Some(Box::new(FakePlatform { mac: fake.clone() }) as Box<dyn MacPlatform>)
    })));
    world.restart()?;
    // The platform's backend is there before the controller first looks,
    // as main.rs gives it: a setup to resume is read from it.
    world.with::<SnapShot, _>(|controller, engine| {
        controller.set_backend(engine, snap_shot::create(None))
    })?;
    world.connect()?;
    world.sync()?;
    snap(world).installed = false;
    install(world)?;
    Keymap::of(world.engine()).set_mac(world.engine(), true);
    world.told_in_place = Some(Rc::new(|w: &World| {
        vec![text(&field(w, "wizard.permissionsError"))]
    }));
    world.pump()
}

fn include(world: &mut World, on: bool) -> Outcome {
    set_setting(world, "snapShotIncludeAccessibility", json!(on))
}

fn mac_desktop(world: &mut World) -> Outcome {
    *mac_of(world).borrow_mut() = FakeMac::default();
    start_app(world)?;
    // Scenarios say when app text is included; "macOS" alone means it is not.
    include(world, false)?;
    open_panel(world)
}

/// What the Mac says on its own, handed to the shell.
fn post(world: &mut World, signal: Signal) -> Outcome {
    let inbox = mac_of(world).borrow().inbox.clone();
    let Some(inbox) = inbox else {
        crate::fail!("the desktop to run on macOS");
    };
    inbox.post(signal);
    deliver(world.engine());
    world.pump()
}

/// A permission changed in System Settings, and the app has looked.
fn looked(world: &mut World) -> Outcome {
    post(world, Signal::Refresh)
}

fn allow_all(world: &mut World) {
    mac_of(world).borrow_mut().allowed = Permissions {
        screen_recording: true,
        accessibility: true,
    };
}

fn enabled(world: &World) -> bool {
    setting(world, "snapShotEnabled").as_bool() == Some(true)
}

fn turn_on(world: &mut World) -> Outcome {
    allow_all(world);
    set_setting(world, "snapShotEnabled", json!(true))?;
    looked(world)?;
    world.wait_for_with(
        |w| field(w, "shortcut.registered").as_bool() == Some(true),
        |w| format!("the shortcut to be held; Snap Shot is {}", show(&page(w))),
    )
}

fn row(world: &World, id: &str) -> Outcome<Value> {
    let rows = field(world, "wizard.permissionRows");
    match rows
        .as_array()
        .into_iter()
        .flatten()
        .find(|row| text(&row["id"]) == id)
    {
        Some(row) => Ok(row.clone()),
        None => crate::fail!("no {id} row; Snap Shot is {}", show(&page(world))),
    }
}

fn granted(world: &World, id: &str) -> Outcome<bool> {
    Ok(row(world, id)?["granted"].as_bool() == Some(true))
}

fn expect_can_continue(world: &World, can: bool) -> Outcome {
    expect!(
        field(world, "wizard.continueEnabled").as_bool() == Some(can),
        "Continue to be {}; Snap Shot is {}",
        if can { "available" } else { "unavailable" },
        show(&page(world))
    );
    Ok(())
}

fn expect_step(world: &World, name: &str) -> Outcome {
    expect!(
        field(world, "wizard.step") == name,
        "setup on the {name} step; Snap Shot is {}",
        show(&page(world))
    );
    Ok(())
}

fn show_helper(world: &mut World) -> Outcome {
    send(world, "setup.open", Value::Null)?;
    send(world, "permission.allow", json!({"id": SCREEN_RECORDING}))
}

/// Both of `modifier`'s keys, with the recorder listening.
pub(crate) fn press_both(world: &mut World, modifier: &str, left: &str, right: &str) -> Outcome {
    send(world, "record.start", Value::Null)?;
    for code in [left, right] {
        send(
            world,
            "record.modifier",
            json!({"modifier": modifier, "code": code, "down": true}),
        )?;
    }
    Ok(())
}

fn draft(world: &World) -> Vec<Value> {
    attachments(world, &thread_key(world))
}

/// The shortcut pressed with a thread open.
fn capture(world: &mut World) -> Outcome {
    open_thread(world)?;
    post(world, Signal::Pressed)?;
    world.wait_for_with(
        |w| !draft(w).is_empty(),
        |w| format!("the capture on the draft; Snap Shot is {}", show(&page(w))),
    )
}

/// The shortcut pressed on this Mac, turning Snap Shot on first if the
/// scenario has not, for snap_shot.rs's own press.
pub(crate) fn mac_press(world: &mut World) -> Outcome {
    if !enabled(world) {
        turn_on(world)?;
    }
    open_thread(world)?;
    post(world, Signal::Pressed)
}

fn expect_text_on_capture(world: &World) -> Outcome {
    let images = draft(world);
    let source = images.first().map(|image| image["source"].clone());
    let source = source.unwrap_or(Value::Null);
    expect!(
        source["accessibleText"] == "Docs: Getting started"
            && at(&source, "accessibility.format") == "flat-text",
        "the window's text on the capture; it is {}",
        show(&source)
    );
    Ok(())
}

pub fn register(steps: &mut Steps) {
    steps.step(
        "the desktop app runs on (macOS|macOS with app text included)",
        |world, c, _| {
            mac_desktop(world)?;
            if c[0] == "macOS with app text included" {
                include(world, true)?;
            }
            Ok(())
        },
    );
    steps.step(
        "Snap Shot is on and the desktop app runs on macOS",
        |world, _, _| {
            mac_desktop(world)?;
            mac_of(world).borrow_mut().allowed.screen_recording = true;
            set_setting(world, "snapShotEnabled", json!(true))?;
            looked(world)
        },
    );

    // Setup.
    steps.step("the user allows capture during setup", |world, _, _| {
        if windows::on_windows(world) {
            return windows::turn_on(world);
        }
        send(world, "setup.open", Value::Null)?;
        let rows = field(world, "wizard.permissionRows");
        for row in rows.as_array().into_iter().flatten() {
            if row["required"].as_bool() == Some(true) {
                send(world, "permission.allow", json!({"id": row["id"]}))?;
            }
        }
        Ok(())
    });
    steps.step(
        "the user is asked for (Screen Recording and Accessibility|Screen Recording|Accessibility)",
        |world, c, _| {
            let mut wanted = Vec::new();
            if c[0].contains("Screen Recording") {
                wanted.push(SCREEN_RECORDING.to_owned());
            }
            if c[0].contains("Accessibility") {
                wanted.push(ACCESSIBILITY.to_owned());
            }
            let requested = mac_of(world).borrow().requested.clone();
            expect!(
                requested == wanted,
                "macOS asked for {}, not {}",
                wanted.join(","),
                requested.join(",")
            );
            Ok(())
        },
    );
    steps.step(
        "the user finishes setup without changing the shortcut",
        |world, _, _| {
            allow_all(world);
            send(world, "setup.open", Value::Null)?;
            send(world, "setup.continue", Value::Null)?;
            expect_step(world, "shortcut")?;
            send(world, "setup.done", Value::Null)
        },
    );
    steps.step("the shortcut is pressing both Shift keys", |world, _, _| {
        let saved = setting(world, "snapShotShortcut");
        expect!(
            saved["kind"] == "both-shift-keys",
            "both Shift keys; the shortcut is {}",
            show(&saved)
        );
        Ok(())
    });
    steps.step("the desktop watches for the shortcut", |world, _, _| {
        turn_on(world)
    });
    steps.step("the Dock lists the desktop app once", |world, _, _| {
        // The Dock shows apps, and the watch starts none: it runs in this one.
        let watched = mac_of(world).borrow().watched.clone();
        expect!(
            watched.iter().any(|m| m == "shift"),
            "Shift watched in the app itself; watched {}",
            watched.join(",")
        );
        Ok(())
    });

    // Each permission on its own.
    steps.step("the user is on the access step", |world, _, _| {
        send(world, "setup.open", json!({"step": "access"}))?;
        expect_step(world, "access")
    });
    steps.step(
        &format!("Screen Recording is shown with {Q}"),
        |world, c, _| {
            let screen = row(world, SCREEN_RECORDING)?;
            expect!(
                screen["title"] == "Screen Recording"
                    && text(&screen["description"]) == c[0]
                    && screen["required"].as_bool() == Some(true),
                "{}",
                show(&screen)
            );
            Ok(())
        },
    );
    steps.step(
        "Accessibility is shown as optional text and controls",
        |world, _, _| {
            let row = row(world, ACCESSIBILITY)?;
            expect!(
                row["description"] == "Optional. Include text and controls from the captured app."
                    && row["required"].as_bool() != Some(true),
                "{}",
                show(&row)
            );
            Ok(())
        },
    );
    steps.step(&format!("Continue is {Q}"), |world, c, _| {
        expect!(
            text(&field(world, "wizard.continueLabel")) == c[0],
            "Continue to read {}; Snap Shot is {}",
            c[0],
            show(&page(world))
        );
        Ok(())
    });
    steps.step(
        "Accessibility only gates Continue when app text is included",
        |world, _, _| {
            mac_of(world).borrow_mut().allowed = Permissions {
                screen_recording: true,
                accessibility: false,
            };
            looked(world)?;
            expect_can_continue(world, true)?;
            include(world, true)?;
            expect_can_continue(world, false)?;
            mac_of(world).borrow_mut().allowed.accessibility = true;
            looked(world)?;
            expect_can_continue(world, true)
        },
    );
    steps.step(
        "setup asks for two permissions and one is allowed",
        |world, _, _| {
            mac_desktop(world)?;
            include(world, true)?;
            mac_of(world).borrow_mut().allowed = Permissions {
                screen_recording: true,
                accessibility: false,
            };
            send(world, "setup.open", Value::Null)
        },
    );
    steps.step(
        "the allowed permission is marked as allowed",
        |world, _, _| {
            expect!(granted(world, SCREEN_RECORDING)?, "{}", show(&page(world)));
            Ok(())
        },
    );
    steps.step("the other offers to be allowed", |world, _, _| {
        expect!(!granted(world, ACCESSIBILITY)?, "{}", show(&page(world)));
        Ok(())
    });
    steps.step("setup does not let the user continue", |world, _, _| {
        expect_can_continue(world, false)
    });
    steps.step("setup lets the user continue", |world, _, _| {
        expect_can_continue(world, true)
    });
    steps.step(
        "the user allows the other permission in system settings and returns to the app",
        |world, _, _| {
            mac_of(world).borrow_mut().allowed.accessibility = true;
            looked(world)
        },
    );
    steps.step("both are marked as allowed", |world, _, _| {
        expect!(
            granted(world, SCREEN_RECORDING)? && granted(world, ACCESSIBILITY)?,
            "{}",
            show(&page(world))
        );
        Ok(())
    });
    steps.step("setup is waiting on a permission", |world, _, _| {
        mac_desktop(world)?;
        send(world, "setup.open", Value::Null)?;
        expect_step(world, "access")
    });
    steps.step(
        "the check of the permission's state fails",
        |world, _, _| {
            mac_of(world).borrow_mut().read_fails = true;
            looked(world)
        },
    );
    steps.step("the next check succeeds", |world, _, _| {
        mac_of(world).borrow_mut().read_fails = false;
        allow_all(world);
        looked(world)
    });
    steps.step("the message goes away", |world, _, _| {
        expect!(
            text(&field(world, "wizard.permissionsError")).is_empty(),
            "{}",
            show(&page(world))
        );
        expect_can_continue(world, true)
    });

    // The test capture.
    steps.step(
        "the user allows capture in setup and the test capture fails",
        |world, _, _| {
            allow_all(world);
            mac_of(world).borrow_mut().capture_failure = "exited".into();
            send(world, "setup.open", Value::Null)?;
            send(world, "setup.continue", Value::Null)
        },
    );
    steps.step(
        &format!("capture stays off, the user is told {Q} with the reason"),
        |world, c, _| {
            let details = text(&field(world, "wizard.details"));
            expect!(
                !enabled(world)
                    && details.starts_with(&c[0])
                    && details.contains("screencapture exited with code 1"),
                "capture off and why; Snap Shot is {}",
                show(&page(world))
            );
            expect_step(world, "access")
        },
    );
    steps.step("the user can try again", |world, _, _| {
        expect_can_continue(world, true)?;
        mac_of(world).borrow_mut().capture_failure.clear();
        send(world, "setup.continue", Value::Null)?;
        expect_step(world, "shortcut")?;
        expect!(enabled(world), "capture on once the test works");
        Ok(())
    });
    steps.step("the user continues past the access step", |world, _, _| {
        allow_all(world);
        send(world, "setup.open", Value::Null)?;
        looked(world)?;
        let body = text(&field(world, "wizard.body"));
        expect!(
            body.contains("bypass its window picker") && body.contains("choose Allow"),
            "setup to warn of macOS's prompt; it says {body}"
        );
        send(world, "setup.continue", Value::Null)
    });
    steps.step(
        "the user is told macOS may ask to bypass its window picker and to choose Allow",
        |world, _, _| {
            // Read before continuing: setup moves on once the test works.
            let captures = mac_of(world).borrow().captures;
            expect!(captures == 1, "one test capture, not {captures}");
            Ok(())
        },
    );
    steps.step("the test image is discarded", |world, _, _| {
        // A test capture never reaches the controller as a capture.
        expect!(
            draft(world).is_empty(),
            "no capture kept; the draft has {}",
            show(&Value::Array(draft(world)))
        );
        expect_step(world, "shortcut")
    });

    // Coming back to setup.
    steps.step(
        "the user allowed Screen Recording and the app had to quit and reopen",
        |world, _, _| {
            send(world, "setup.open", Value::Null)?;
            send(world, "permission.allow", json!({"id": SCREEN_RECORDING}))?;
            mac_of(world).borrow_mut().allowed.screen_recording = true;
            start_app(world)?;
            world.wait_for_with(
                |w| at(&w.state("route"), "section") == SECTION,
                |w| {
                    format!(
                        "Settings, SnapShots to open; the route is {}, Snap Shot is {}, resume is {}",
                        show(&w.state("route")),
                        show(&page(w)),
                        show(&setting(w, "snapShotSetupResume"))
                    )
                },
            )
        },
    );
    steps.step(
        "setup resumes where the user left it, with capture on or off as it was",
        |world, _, _| {
            world.wait_for_with(
                |w| !field(w, "wizard").is_null() && field(w, "wizard.step") == "access",
                |w| {
                    format!(
                        "setup at access; resume is {}; Snap Shot is {}",
                        show(&setting(w, "snapShotSetupResume")),
                        show(&page(w))
                    )
                },
            )?;
            expect!(!enabled(world), "capture still off");
            // Closing it for good ends the resuming.
            send(world, "setup.close", Value::Null)?;
            start_app(world)?;
            expect!(
                field(world, "wizard").is_null(),
                "no setup on the next start; Snap Shot is {}",
                show(&page(world))
            );
            Ok(())
        },
    );

    steps.step(
        "the user is on the shortcut step on a desktop that records modifier pairs",
        |world, _, _| {
            mac_desktop(world)?;
            allow_all(world);
            send(world, "setup.open", Value::Null)?;
            send(world, "setup.continue", Value::Null)?;
            expect_step(world, "shortcut")
        },
    );

    // Done, and undone.
    steps.step(
        "Screen Recording is allowed, and Accessibility too when app text is included",
        |world, _, _| {
            allow_all(world);
            Ok(())
        },
    );
    steps.step("a shortcut is saved", |world, _, _| turn_on(world));
    steps.step(
        "no setup button is shown and the shortcut stays editable in the panel",
        |world, _, _| {
            expect!(
                text(&field(world, "setupLabel")).is_empty()
                    && field(world, "shortcut.registered").as_bool() == Some(true)
                    && !text(&field(world, "shortcut.keys")).is_empty(),
                "no setup button; Snap Shot is {}",
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step("the user revokes a permission", |world, _, _| {
        mac_of(world).borrow_mut().allowed.screen_recording = false;
        looked(world)
    });
    steps.step(
        &format!("the setup button returns as {Q}"),
        |world, c, _| {
            expect!(
                text(&field(world, "setupLabel")) == c[0],
                "the button to read {}; Snap Shot is {}",
                c[0],
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step(
        "Snap Shot is on and a permission was revoked so capture needs attention",
        |world, _, _| {
            turn_on(world)?;
            mac_of(world).borrow_mut().allowed.screen_recording = false;
            looked(world)?;
            expect!(
                field(world, "status") == "Capture needs attention"
                    && field(world, "shortcut.registered").as_bool() != Some(true),
                "capture to need attention; Snap Shot is {}",
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step("the user allows the permission again", |world, _, _| {
        mac_of(world).borrow_mut().allowed.screen_recording = true;
        looked(world)
    });
    steps.step(
        "the panel clears the message and the shortcut works again",
        |world, _, _| {
            expect!(
                field(world, "status") != "Capture needs attention"
                    && field(world, "shortcut.registered").as_bool() == Some(true),
                "{}",
                show(&page(world))
            );
            capture(world)
        },
    );
    steps.step("no restart of HAL-C2 is needed", |_, _, _| Ok(()));

    // The panel beside System Settings.
    steps.step(
        "the user is sent to System Settings to allow Screen Recording or Accessibility",
        |world, _, _| show_helper(world),
    );
    steps.step(
        "a small panel beside System Settings says to drag HAL-C2 into the list",
        |world, _, _| {
            let mac = mac_of(world);
            let mac = mac.borrow();
            let beside = mac.settings.map(|s| Helper::bounds_beside(s.bounds));
            expect!(
                mac.helper_shown
                    && mac.helper_text == Helper::TEXT
                    && Some(mac.helper_bounds) == beside,
                "the panel beside Settings; it says {:?} at {:?}",
                mac.helper_text,
                mac.helper_bounds
            );
            Ok(())
        },
    );
    steps.step(
        "the user can drag the app from it or choose to reveal the app in Finder",
        |world, _, _| {
            post(world, Signal::HelperRevealRequested)?;
            let reveals = mac_of(world).borrow().reveals;
            expect!(reveals == 1, "the app shown in Finder");
            Ok(())
        },
    );
    steps.step(
        "the permission panel is showing beside System Settings",
        |world, _, _| {
            mac_desktop(world)?;
            show_helper(world)?;
            expect!(mac_of(world).borrow().helper_shown, "the panel to show");
            Ok(())
        },
    );
    steps.step("the permission is granted", |world, _, _| {
        mac_of(world).borrow_mut().allowed.screen_recording = true;
        post(world, Signal::CheckHelper)
    });
    steps.step("the panel closes itself", |world, _, _| {
        let mac = mac_of(world);
        let mac = mac.borrow();
        expect!(
            !mac.helper_shown && mac.helper_closes >= 1 && mac.focuses == 1,
            "the panel gone and HAL-C2 back in front"
        );
        Ok(())
    });
    steps.step(
        "instead the user closes System Settings or brings another app forward",
        |world, _, _| {
            mac_of(world).borrow_mut().allowed.screen_recording = false;
            show_helper(world)?;
            expect!(
                mac_of(world).borrow().helper_shown,
                "the panel to show again"
            );
            if let Some(settings) = mac_of(world).borrow_mut().settings.as_mut() {
                settings.frontmost = false;
            }
            post(world, Signal::TrackHelper)
        },
    );
    steps.step("the panel closes or hides with it", |world, _, _| {
        let closes = mac_of(world).borrow().helper_closes;
        expect!(
            !mac_of(world).borrow().helper_shown,
            "the panel hidden while another app is in front"
        );
        if let Some(settings) = mac_of(world).borrow_mut().settings.as_mut() {
            settings.frontmost = true;
        }
        post(world, Signal::TrackHelper)?;
        expect!(
            mac_of(world).borrow().helper_shown && mac_of(world).borrow().helper_closes == closes,
            "the panel back with Settings, never closed"
        );
        if let Some(settings) = mac_of(world).borrow_mut().settings.as_mut() {
            settings.open = false;
        }
        post(world, Signal::TrackHelper)?;
        let mac = mac_of(world);
        let mac = mac.borrow();
        expect!(
            !mac.helper_shown && mac.helper_closes > closes,
            "the panel closed with Settings"
        );
        Ok(())
    });

    // App text.
    steps.step("the user turns on including app text", |world, _, _| {
        send(world, "set", json!({"key": "accessibility", "value": true}))
    });
    steps.step("the permission is refused", |world, _, _| {
        expect!(
            !mac_of(world).borrow().allowed.accessibility,
            "Accessibility not to be allowed"
        );
        looked(world)
    });
    steps.step(
        &format!("app text stays off and the user is told {Q} with the reason"),
        |world, c, _| {
            expect!(
                field(world, "accessibility.checked").as_bool() != Some(true),
                "{}",
                show(&page(world))
            );
            let toast = toast_titled(world, &c[0]);
            expect!(
                toast.is_some_and(|t| text(&t["description"]).contains("Accessibility")),
                "the toast {}; the shell shows {}",
                c[0],
                show(&world.state("toasts"))
            );
            Ok(())
        },
    );
    steps.step(
        "captures carry the app's text and controls when the app makes them available",
        |world, _, _| {
            // No permission yet, so nothing changed; allowed, it turns on.
            expect!(
                field(world, "accessibility.checked").as_bool() != Some(true),
                "{}",
                show(&page(world))
            );
            allow_all(world);
            looked(world)?;
            send(world, "set", json!({"key": "accessibility", "value": true}))?;
            expect!(
                field(world, "accessibility.checked").as_bool() == Some(true),
                "{}",
                show(&page(world))
            );
            capture(world)?;
            expect_text_on_capture(world)
        },
    );

    // The shortcut: the rows macOS and Windows share.
    steps.step(
        "the user chooses the shortcut of pressing both (Shift|Super|Alt) keys",
        |world, c, _| {
            if windows::on_windows(world) {
                return windows::choose_pair(world, &c[0]);
            }
            expect!(c[0] == "Shift", "the desktop app to run on Windows");
            set_setting(
                world,
                "snapShotShortcut",
                json!({"key": "k", "modKey": true}),
            )?;
            turn_on(world)?;
            press_both(world, "shift", "ShiftLeft", "ShiftRight")
        },
    );
    steps.step(
        "the shortcut row says it is observed and cannot be reserved exclusively",
        |world, _, _| {
            let status = text(&field(world, "shortcut.status"));
            let observed = if windows::on_windows(world) {
                status.contains("is observed and cannot be reserved exclusively.")
            } else {
                status == "Shift + Shift is observed and cannot be reserved exclusively."
            };
            expect!(
                observed,
                "the row to say it is observed; Snap Shot is {}",
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step(
        "it adds \"(no further note|This key .*)\"",
        |world, c, _| {
            if c[0] == "no further note" {
                return Ok(());
            }
            expect!(
                text(&field(world, "shortcut.status")).ends_with(&c[0]),
                "the note \"{}\"; Snap Shot is {}",
                c[0],
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step(
        "the user chooses a shortcut of pressing both of a modifier key and the system refuses to let HAL-C2 watch it",
        |world, _, _| {
            if windows::on_windows(world) {
                return windows::refuse_pair(world);
            }
            set_setting(world, "snapShotShortcut", json!({"key": "k", "modKey": true}))?;
            turn_on(world)?;
            mac_of(world).borrow_mut().refuse_watch = true;
            press_both(world, "alt", "AltLeft", "AltRight")
        },
    );
    steps.step(
        "the shortcut row says that key is not available on this system",
        |world, _, _| {
            let status = text(&field(world, "shortcut.status"));
            let said = if windows::on_windows(world) {
                // The saved both-Shift shortcut is refused too, so the row
                // reads as its own.
                status.ends_with("is not available on this system.")
            } else {
                status == "Option + Option is not available on this system."
            };
            expect!(
                said,
                "the row to say the key is not available; Snap Shot is {}",
                show(&page(world))
            );
            Ok(())
        },
    );
    steps.step(
        "capture does not claim the shortcut is registered",
        |world, _, _| {
            expect!(
                field(world, "shortcut.canSave").as_bool() != Some(true),
                "nothing to save; Snap Shot is {}",
                show(&page(world))
            );
            if !windows::on_windows(world) {
                // Nor when it is the saved one the system stops letting through.
                set_setting(
                    world,
                    "snapShotShortcut",
                    json!({"kind": "modifier-pair", "modifier": "alt"}),
                )?;
            }
            expect!(
                field(world, "shortcut.registered").as_bool() != Some(true),
                "the shortcut not to be registered; Snap Shot is {}",
                show(&page(world))
            );
            Ok(())
        },
    );
}
