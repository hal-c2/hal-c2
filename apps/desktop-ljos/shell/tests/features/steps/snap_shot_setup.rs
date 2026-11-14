//! The Snap Shot panel's rows, its shortcut, setup and the desktop portal's
//! answers (desktop-qt's SnapShotSteps.cpp from "The panel's rows" on, and
//! SnapShotPortalSteps.cpp), for features/settings/snap-shot.feature. The
//! panel and the fake backend are [`super::snap_shot`]'s; a desktop that
//! "gives shortcuts through the desktop portal" is the portal backend itself
//! on [`super::snap_shot_bus`].

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::settings::Settings;
use ljos::prelude::ApplicationState;
use serde_json::{Value, json};

use super::snap_shot::{
    self as snap, ALT, CONTROL, KEY_AT, KEY_BACKTAB, KEY_CONTROL, KEY_HOME, KEY_TAB, KEY_UP,
    SECTION, SHIFT, answer_check, capture, ctrl_shift_1, ctrl_shift_2, desktop, environment,
    expect_off, field, has_wizard, open_panel, page, portal_desktop, press, press_named,
    record_ctrl_shift_2, reset_with, save, send, set_setting, setting, shortcut_setting,
    toast_saying, toast_titled, turn_on, turn_on_with, update, wait_for_field,
};
use super::snap_shot_bus::{Answer, PortalDesktop, bus};
use crate::expect;
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;

const CHECKING: &str = "Checking shortcut…";
const UNSURE: &str = "Your desktop could not say whether it can capture windows.";
const PROMPT: &str = "Approve the shortcut permission prompt to continue.";

fn describe(world: &World) -> String {
    show(&page(world))
}

/// Waits for the portal on the bus to hold its prompt open.
fn wait_prompting(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| {
            super::snap_shot_bus::settle(w.engine());
            bus().borrow().prompting()
        },
        |_| {
            format!(
                "the desktop to prompt for the shortcut; it was asked for {}",
                bus().borrow().triggers.join(",")
            )
        },
    )
}

fn expect_status(world: &World, status: &str, why: &str) -> Outcome {
    expect!(
        field(world, "shortcut.status") == status,
        "{why}; Snap Shot is {}",
        describe(world)
    );
    Ok(())
}

/// Records a shortcut whose check the desktop has not answered.
fn record_held(world: &mut World, key: i64, modifiers: i64) -> Outcome {
    desktop(world).borrow_mut().hold_checks = true;
    set_setting(world, "snapShotEnabled", json!(true))?;
    let asked = desktop(world).borrow().checks;
    send(world, "record.start", Value::Null)?;
    press(world, key, modifiers)?;
    expect!(
        desktop(world).borrow().checks == asked + 1,
        "the desktop to be asked about the shortcut; Snap Shot is {}",
        describe(world)
    );
    Ok(())
}

/// The wizard, after something it should have ignored.
fn expect_still(world: &World, step: &str, after: &str) -> Outcome {
    let wizard = field(world, "wizard");
    expect!(
        wizard["step"] == step && wizard["busy"].as_bool() == Some(true),
        "setup to stay on {step} while it works, after {after}; Snap Shot is {}",
        describe(world)
    );
    Ok(())
}

fn modifier_pair(world: &mut World) -> Outcome {
    for code in [50, 62] {
        send(
            world,
            "record.modifier",
            json!({"modifier": "shift", "code": code, "down": true}),
        )?;
    }
    Ok(())
}

fn open_settings(world: &mut World, section: Option<&str>) -> Outcome {
    let route = match section {
        Some(section) => Route::Settings(section.to_owned()),
        None => Route::Settings(String::new()),
    };
    world.with::<Navigation, _>(|navigation, engine| navigation.open(engine, route))?;
    world.pump()
}

fn choice_labels(world: &World) -> Vec<String> {
    field(world, "sound.choices")
        .as_array()
        .into_iter()
        .flatten()
        .map(|choice| text(&choice["label"]))
        .collect()
}

pub fn register(steps: &mut Steps) {
    // The panel's rows.
    steps.step(
        "Snap Shot is (still being checked|on with only a manual window picker available|\
         on and waiting for the user to approve the shortcut|on with a shortcut that has been seen to work|\
         on with no shortcut chosen yet|on but the desktop reports a problem)",
        |world, c, _| {
            let which = c[0].as_str();
            if which == "still being checked" {
                portal_desktop_closed(
                    world,
                    PortalDesktop {
                        hold_screenshot: true,
                        ..PortalDesktop::default()
                    },
                )?;
                // The panel asks, and the desktop has not answered.
                open_settings(world, Some(SECTION))?;
                world.wait_for_with(
                    |w| at(&w.state("route"), "section") == SECTION,
                    |w| {
                        format!(
                            "Settings, SnapShots to open; the route is {}",
                            show(&w.state("route"))
                        )
                    },
                )
            } else if which.contains("window picker") {
                desktop(world).borrow_mut().picker = true;
                turn_on(world)
            } else if which.contains("approve") {
                portal_desktop(
                    world,
                    PortalDesktop {
                        bind: Answer::Hold,
                        ..PortalDesktop::default()
                    },
                )?;
                turn_on_with(world, ctrl_shift_2())?;
                wait_prompting(world)
            } else if which.contains("seen to work") {
                turn_on(world)
            } else if which.contains("no shortcut") {
                set_setting(world, "snapShotEnabled", json!(true))
            } else {
                turn_on(world)?;
                desktop(world).borrow_mut().message = UNSURE.into();
                update(world)
            }
        },
    );
    steps.step(&format!("the capture row reads {Q}"), |world, c, _| {
        wait_for_field(world, "status", json!(c[0]))
    });
    steps.step(
        "the desktop reports that capture is not supported on this platform",
        |world, _, _| {
            reset_with(world, environment("x11", ""), None)?;
            open_panel(world)
        },
    );
    steps.step(
        "the capture row says the desktop's reason, or \"Not supported on this platform\\.\"",
        |world, _, _| {
            expect!(
                field(world, "available").as_bool() != Some(true)
                    && !text(&field(world, "status")).is_empty(),
                "the row to say why capture is not supported; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("capture cannot be turned on", |world, _, _| {
        send(world, "enable", json!({"on": true}))?;
        expect!(
            setting(world, "snapShotEnabled").as_bool() != Some(true)
                && !has_wizard(world)
                && field(world, "switchOn").as_bool() != Some(true),
            "capture to stay off with no setup; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "Snap Shot is on and setup is not finished on (GNOME|KDE Plasma|a desktop HAL-C2 cannot name)",
        |world, c, _| {
            let current = match c[0].as_str() {
                "GNOME" => "GNOME",
                "KDE Plasma" => "KDE",
                _ => "sway",
            };
            reset_with(world, environment("wayland", current), None)?;
            // KDE's setup is its capture helper.
            if current == "KDE" {
                super::snap_shot_helper::uninstall_capture_helpers(world)?;
            }
            open_panel(world)?;
            desktop(world).borrow_mut().message = UNSURE.into();
            turn_on(world)?;
            update(world)
        },
    );
    steps.step(&format!("the setup button reads {Q}"), |world, c, _| {
        wait_for_field(world, "setupLabel", json!(c[0]))
    });
    steps.step("capture access is in place", |world, _, _| turn_on(world));
    steps.step(
        "it reopens setup to revisit access or the shortcut",
        |world, _, _| {
            send(world, "setup.open", Value::Null)?;
            expect!(
                field(world, "wizard.step") == "shortcut",
                "setup to open on the shortcut; Snap Shot is {}",
                describe(world)
            );
            send(world, "setup.back", Value::Null)?;
            expect!(
                field(world, "wizard.step") == "access",
                "setup to go back to access; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );

    // The shortcut.
    steps.step(
        "Snap Shot is on with the shortcut Ctrl\\+Shift\\+1",
        |world, _, _| {
            turn_on_with(world, ctrl_shift_1())?;
            wait_for_field(world, "shortcut.registered", json!(true))
        },
    );
    steps.step(
        "the panel shows Ctrl\\+Shift\\+2 with Save and Cancel",
        |world, _, _| {
            expect!(
                field(world, "shortcut.keys") == "Ctrl+Shift+2"
                    && field(world, "shortcut.changed").as_bool() == Some(true)
                    && field(world, "shortcut.canSave").as_bool() == Some(true),
                "Ctrl+Shift+2 to wait for Save or Cancel; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the shortcut in use is still Ctrl\\+Shift\\+1",
        |world, _, _| {
            let binds = desktop(world).borrow().binds.clone();
            expect!(
                shortcut_setting(world) == ctrl_shift_1() && binds == ["CTRL+SHIFT+1"],
                "Ctrl+Shift+1 to stay in use; the desktop holds {}",
                binds.join(",")
            );
            Ok(())
        },
    );
    steps.step(
        "the panel shows Ctrl\\+Shift\\+1 again and nothing changed",
        |world, _, _| {
            let binds = desktop(world).borrow().binds.clone();
            expect!(
                field(world, "shortcut.keys") == "Ctrl+Shift+1"
                    && field(world, "shortcut.changed").as_bool() != Some(true)
                    && binds == ["CTRL+SHIFT+1"],
                "Ctrl+Shift+1 back with nothing changed; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the user is changing the shortcut", |world, _, _| {
        set_setting(world, "snapShotEnabled", json!(true))?;
        send(world, "record.start", Value::Null)
    });
    steps.step(
        "(recording starts|the desktop says the shortcut is free|the shortcut is one HAL-C2 uses for \"Terminal: Toggle\"|\
         the user presses only modifier keys on a Wayland desktop)",
        |world, c, _| {
            if c[0].contains("free") {
                press(world, KEY_AT, CONTROL | SHIFT)
            } else if c[0].contains("Terminal: Toggle") {
                press(world, 0x4a, CONTROL)
            } else if c[0].contains("modifier") {
                modifier_pair(world)
            } else {
                Ok(())
            }
        },
    );
    steps.step("the shortcut row says \"(.*)\"", |world, c, _| {
        let said = c[0].clone();
        world.wait_for_with(
            |w| {
                super::snap_shot_bus::settle(w.engine());
                field(w, "shortcut.status") == said.as_str()
                    || field(w, "shortcut.description") == said.as_str()
            },
            |w| {
                format!(
                    "the shortcut row to say {}; Snap Shot is {}",
                    c[0],
                    describe(w)
                )
            },
        )
    });
    steps.step(
        "a desktop that gives shortcuts through the desktop portal",
        |world, _, _| portal_desktop(world, PortalDesktop::default()),
    );
    steps.step("no shortcut is saved yet", |world, _, _| {
        let saved = shortcut_setting(world);
        expect!(
            saved.is_null() || saved["kind"] == "both-shift-keys",
            "a shortcut is saved"
        );
        set_setting(world, "snapShotEnabled", json!(true))
    });
    steps.step(
        "the shortcut row suggests a shortcut such as Ctrl\\+Shift\\+2",
        |world, _, _| {
            wait_for_field(
                world,
                "shortcut.status",
                json!("Try a shortcut such as Ctrl+Shift+2."),
            )
        },
    );
    steps.step(
        "pressing both Shift keys is not offered as the shortcut",
        |world, _, _| {
            let triggers = bus().borrow().triggers.clone();
            expect!(
                field(world, "shortcut.keys") == "Choose shortcut" && triggers.is_empty(),
                "no shortcut to be offered; the desktop was asked for {}, Snap Shot is {}",
                triggers.join(","),
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user starts recording a new shortcut and presses the current one",
        |world, _, _| {
            send(world, "record.start", Value::Null)?;
            capture(world)
        },
    );
    steps.step("no capture starts", |world, _, _| {
        let captures = desktop(world).borrow().captures.len();
        expect!(captures == 0, "no capture; {captures} were taken");
        Ok(())
    });
    steps.step(
        "pausing the capture shortcut ends when recording ends, is cancelled, or the panel closes",
        |world, _, _| {
            fn captures(world: &mut World, count: usize, after: &str) -> Outcome {
                capture(world)?;
                let taken = desktop(world).borrow().captures.len();
                expect!(
                    taken == count,
                    "the shortcut to capture again once {after}; {taken} captures"
                );
                Ok(())
            }
            press_named(world, "Ctrl+Alt+K")?;
            captures(world, 1, "recording ends")?;
            send(world, "record.start", Value::Null)?;
            send(world, "record.cancel", Value::Null)?;
            captures(world, 2, "recording is cancelled")?;
            send(world, "record.start", Value::Null)?;
            open_settings(world, None)?;
            captures(world, 3, "the panel closes")
        },
    );
    steps.step(
        "the user presses Tab, holds a key down, or presses a modifier on its own",
        |world, _, _| {
            press(world, KEY_TAB, 0)?;
            press(world, KEY_BACKTAB, SHIFT)?;
            send(
                world,
                "record.key",
                json!({"key": KEY_AT, "modifiers": CONTROL | SHIFT, "repeat": true}),
            )?;
            press(world, KEY_CONTROL, CONTROL)?;
            send(
                world,
                "record.modifier",
                json!({"modifier": "control", "code": 37, "down": true}),
            )
        },
    );
    steps.step("no shortcut is recorded", |world, _, _| {
        expect!(
            field(world, "shortcut.recording").as_bool() == Some(true)
                && field(world, "shortcut.changed").as_bool() != Some(true)
                && field(world, "shortcut.status") == "Press your shortcut. Esc cancels.",
            "the recorder to keep listening; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the desktop shows a portal shortcut that was refused or never granted",
        |world, _, _| {
            portal_desktop(
                world,
                PortalDesktop {
                    bind: Answer::Refuse,
                    ..PortalDesktop::default()
                },
            )?;
            turn_on_with(world, ctrl_shift_2())?;
            wait_for_field(
                world,
                "shortcut.status",
                json!("Shortcut permission wasn't granted. Open shortcut permissions to allow it."),
            )?;
            expect!(
                field(world, "shortcut.permissions").as_bool() == Some(true),
                "Shortcut permissions to be offered; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the user chooses Shortcut permissions", |world, _, _| {
        bus().borrow_mut().desktop.bind = Answer::Hold;
        send(world, "shortcut.permissions", Value::Null)
    });
    steps.step("the desktop asks for the shortcut again", |world, _, _| {
        wait_prompting(world)?;
        let triggers = bus().borrow().triggers.clone();
        expect!(
            triggers.len() == 2,
            "a second request; the desktop was asked for {}",
            triggers.join(",")
        );
        Ok(())
    });
    steps.step(
        "the button is disabled while its prompt is pending",
        |world, _, _| {
            expect!(
                field(world, "shortcut.permissions").as_bool() == Some(true)
                    && field(world, "shortcut.permissionsEnabled").as_bool() != Some(true),
                "Shortcut permissions to wait on the prompt; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("the row says {Q} while it is"), |world, c, _| {
        expect!(
            field(world, "shortcut.pending").as_bool() == Some(true)
                && field(world, "shortcut.status") == c[0].as_str(),
            "the row to say {} while the prompt is open; Snap Shot is {}",
            c[0],
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the shortcut is a modifier pair, or the desktop says asking again changes nothing",
        |world, _, _| {
            // The first portal version cannot show its shortcut permissions again.
            portal_desktop(
                world,
                PortalDesktop {
                    shortcuts_version: 1,
                    bind: Answer::Refuse,
                    ..PortalDesktop::default()
                },
            )?;
            turn_on_with(world, ctrl_shift_2())?;
            wait_for_field(
                world,
                "shortcut.status",
                json!(
                    "Shortcut permission wasn't granted. Allow HAL-C2 in your desktop's shortcut settings."
                ),
            )
        },
    );
    steps.step("there is no Shortcut permissions button", |world, _, _| {
        expect!(
            field(world, "shortcut.permissions").as_bool() != Some(true),
            "no Shortcut permissions where the desktop cannot ask again; Snap Shot is {}",
            describe(world)
        );
        set_setting(
            world,
            "snapShotShortcut",
            json!({"kind": "both-shift-keys"}),
        )?;
        expect!(
            field(world, "shortcut.permissions").as_bool() != Some(true),
            "no Shortcut permissions for a modifier pair; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the desktop reports a shortcut HAL-C2 cannot read",
        |world, _, _| turn_on_with(world, json!({"trigger": "…"})),
    );
    steps.step(
        "the shortcut row says \"Change shortcut\" instead of showing keys",
        |world, _, _| wait_for_field(world, "shortcut.keys", json!("Change shortcut")),
    );
    steps.step("recording a new one replaces it", |world, _, _| {
        record_ctrl_shift_2(world)?;
        save(world)?;
        expect!(
            shortcut_setting(world) == ctrl_shift_2()
                && field(world, "shortcut.keys") == "Ctrl+Shift+2",
            "Ctrl+Shift+2 to replace it; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });

    // App text and the capture cues.
    steps.step(
        "a Linux desktop that only provides a screenshot",
        |world, _, _| set_setting(world, "snapShotEnabled", json!(true)),
    );
    steps.step(
        "including app text is off and cannot be turned on",
        |world, _, _| {
            let before = setting(world, "snapShotIncludeAccessibility");
            send(world, "set", json!({"key": "accessibility", "value": true}))?;
            expect!(
                field(world, "accessibility.checked").as_bool() != Some(true)
                    && field(world, "accessibility.enabled").as_bool() != Some(true)
                    && setting(world, "snapShotIncludeAccessibility") == before,
                "app text to stay off; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("the panel says {Q}"), |world, c, _| {
        let said = c[0].clone();
        world.wait_for_with(
            |w| {
                super::snap_shot_bus::settle(w.engine());
                field(w, "accessibility.status") == said.as_str()
                    || field(w, "shortcut.status") == said.as_str()
            },
            |w| format!("the panel to say {}; Snap Shot is {}", c[0], describe(w)),
        )
    });
    steps.step("the user's settings cannot be written", |world, _, _| {
        // A file where the preferences' folder would be.
        let dir = world.config_dir();
        let blocker = dir.join("not-a-folder");
        std::fs::create_dir_all(&dir).map_err(|e| format!("cannot make {dir:?}: {e}"))?;
        std::fs::write(&blocker, b"").map_err(|e| format!("cannot write {blocker:?}: {e}"))?;
        Settings::of(world.engine())
            .set_device_path(world.engine(), Some(blocker.join("preferences.json")));
        world.pump()
    });
    steps.step("the user turns off the capture sound", |world, _, _| {
        send(world, "sound", json!({"value": "off"}))
    });
    steps.step("the sound is still on", |world, _, _| {
        expect!(
            field(world, "sound.value") == "soft-pop"
                && setting(world, "snapShotPlaySound").as_bool() == Some(true),
            "the sound to stay on; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user is told the save failed with the reason",
        |world, _, _| {
            let toast = toast_titled(world, "Setting not saved");
            expect!(
                toast.is_some_and(|toast| text(&toast["description"]).starts_with("Cannot save ")),
                "the save's failure and why; the shell shows {}",
                show(&world.state("toasts"))
            );
            Ok(())
        },
    );
    steps.step("the user opens the capture sound choices", |_, _, _| Ok(()));
    steps.step(
        "the choices are Off, \"Whoosh \\(Default\\)\" and Click",
        |world, _, _| {
            let labels = choice_labels(world);
            expect!(
                labels == ["Off", "Whoosh (Default)", "Click"],
                "Off, Whoosh and Click; the choices are {}",
                labels.join(",")
            );
            Ok(())
        },
    );
    steps.step(
        "the current choice is shown on the row as (Off|Whoosh \\(Default\\)|Click)",
        |world, c, _| {
            let value = field(world, "sound.choices")
                .as_array()
                .into_iter()
                .flatten()
                .find(|choice| choice["label"] == c[0].as_str())
                .map(|choice| choice["value"].clone());
            if let Some(value) = value {
                send(world, "sound", json!({ "value": value }))?;
            }
            expect!(
                field(world, "sound.label") == c[0].as_str(),
                "the row to show {}; Snap Shot is {}",
                c[0],
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "a Linux session where any other desktop but Niri",
        |world, _, _| {
            reset_with(world, environment("wayland", "sway"), None)?;
            set_setting(world, "snapShotEnabled", json!(true))?;
            open_panel(world)?;
            // The flash and animation rows say it (TurnSteps' "the user is told").
            world.told_in_place = Some(std::rc::Rc::new(|w: &World| {
                vec![
                    text(&field(w, "flash.status")),
                    text(&field(w, "animations.status")),
                ]
            }));
            Ok(())
        },
    );
    steps.step(
        "a desktop that gives only a window picker",
        |world, _, _| {
            desktop(world).borrow_mut().picker = true;
            turn_on(world)?;
            update(world)
        },
    );
    steps.step(&format!("the capture row says {Q}"), |world, c, _| {
        expect!(
            field(world, "description") == c[0].as_str(),
            "the capture row to say {}; Snap Shot is {}",
            c[0],
            describe(world)
        );
        Ok(())
    });

    // Catching up with the desktop.
    steps.step("the panel is open", |world, _, _| {
        portal_desktop(world, PortalDesktop::default())?;
        turn_on_with(world, ctrl_shift_2())?;
        wait_for_field(world, "shortcut.registered", json!(true))?;
        expect!(
            field(world, "status") == "Ready to capture",
            "capture to be ready; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user returns to the app after changing capture access or the shortcut outside it",
        |world, _, _| {
            bus().borrow_mut().desktop.window_capture = false;
            ljos::testing::set_application_state(world.engine(), ApplicationState::Inactive);
            ljos::testing::set_application_state(world.engine(), ApplicationState::Active);
            snap::settle(world)
        },
    );
    steps.step(
        "the panel shows the current state without being reopened",
        |world, _, _| {
            wait_for_field(
                world,
                "status",
                json!("Manual capture only — you'll choose a window each time"),
            )
        },
    );
    steps.step(
        "it does the same when the desktop reports the shortcut changed",
        |world, _, _| {
            bus().borrow_mut().change_shortcut("Ctrl+Alt+S")?;
            wait_for_field(world, "shortcut.keys", json!("Ctrl+Alt+S"))?;
            expect_status(
                world,
                "Desktop shortcut: Ctrl+Alt+S",
                "the row to show the desktop's shortcut",
            )
        },
    );
    steps.step(
        "the user asked for shortcut permission and the desktop failed",
        |world, _, _| {
            portal_desktop(
                world,
                PortalDesktop {
                    session_fails: true,
                    ..PortalDesktop::default()
                },
            )?;
            turn_on_with(world, ctrl_shift_2())?;
            wait_for_field(
                world,
                "shortcut.status",
                json!("Your desktop could not create a capture shortcut session."),
            )
        },
    );
    steps.step("the user is told what went wrong once", |world, _, _| {
        expect!(
            toast_saying(
                world,
                "Your desktop could not create a capture shortcut session."
            )
            .is_none()
                && !has_wizard(world),
            "the failure on the shortcut row alone; the shell shows {}",
            show(&world.state("toasts"))
        );
        Ok(())
    });
    steps.step(
        "the user can ask (?:again|for the shortcut again)",
        |world, _, _| {
            expect!(
                field(world, "shortcut.permissions").as_bool() == Some(true),
                "a way to ask again; Snap Shot is {}",
                describe(world)
            );
            // The desktop works again.
            bus().borrow_mut().reset();
            send(world, "shortcut.permissions", Value::Null)?;
            wait_for_field(world, "shortcut.registered", json!(true))
        },
    );

    // Setup.
    steps.step("setup is open and a step fails", |world, _, _| {
        portal_desktop(
            world,
            PortalDesktop {
                screenshot_fails: true,
                ..PortalDesktop::default()
            },
        )?;
        send(world, "setup.open", Value::Null)
    });
    steps.step("the error is shown in setup", |world, _, _| {
        expect!(
            field(world, "wizard.step") == "access" && field(world, "wizard.details") == UNSURE,
            "setup to show the failure; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "closing setup does not repeat it in the panel",
        |world, _, _| {
            send(world, "setup.close", Value::Null)?;
            expect!(
                !has_wizard(world)
                    && toast_saying(world, UNSURE).is_none()
                    && field(world, "status") == "Turn this on to set up snapshots.",
                "the failure to go with setup; Snap Shot is {}, the shell shows {}",
                describe(world),
                show(&world.state("toasts"))
            );
            Ok(())
        },
    );
    steps.step(
        "Snap Shot was off and the user opened setup",
        |world, _, _| {
            send(world, "setup.open", Value::Null)?;
            expect!(
                has_wizard(world),
                "setup to open; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("capture is off again", |world, _, _| expect_off(world));
    steps.step(
        "Snap Shot was on and the user opened setup to change something",
        |world, _, _| {
            turn_on(world)?;
            send(world, "setup.open", Value::Null)?;
            expect!(
                has_wizard(world),
                "setup to open; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("capture is still on", |world, _, _| {
        expect!(
            !has_wizard(world)
                && setting(world, "snapShotEnabled").as_bool() == Some(true)
                && field(world, "shortcut.registered").as_bool() == Some(true),
            "capture to stay on; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "turning it on succeeds but the following status check fails",
        |world, _, _| {
            desktop(world).borrow_mut().message = UNSURE.into();
            update(world)
        },
    );
    steps.step("the user opens setup", |world, _, _| {
        send(world, "setup.open", Value::Null)
    });
    steps.step("setup opens at its first step", |world, _, _| {
        expect!(
            field(world, "wizard.step") == "access"
                && field(world, "wizard.closeLabel") == "Finish later",
            "setup to open on access; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step("finishing later turns capture back off", |world, _, _| {
        // Trying again turns capture on, and the check still fails.
        send(world, "setup.continue", Value::Null)?;
        expect!(
            setting(world, "snapShotEnabled").as_bool() == Some(true)
                && field(world, "wizard.step") == "access",
            "capture on and setup still on access; Snap Shot is {}",
            describe(world)
        );
        send(world, "setup.close", Value::Null)?;
        expect_off(world)
    });
    steps.step(
        "the title says \"Set up snapshots for\" the user's desktop, or just \"Set up snapshots\"",
        |world, _, _| {
            expect!(
                field(world, "wizard.title") == "Set up snapshots",
                "setup's title on an unnamed desktop; Snap Shot is {}",
                describe(world)
            );
            reset_with(world, environment("wayland", "GNOME"), None)?;
            open_panel(world)?;
            send(world, "setup.open", Value::Null)?;
            expect!(
                field(world, "wizard.title") == "Set up snapshots for GNOME",
                "setup's title on GNOME; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the steps are capture access and the shortcut",
        |world, _, _| {
            expect!(
                field(world, "wizard.step") == "shortcut",
                "setup on the shortcut; Snap Shot is {}",
                describe(world)
            );
            send(world, "setup.back", Value::Null)?;
            expect!(
                field(world, "wizard.step") == "access",
                "access before it; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user can go back to access but cannot jump ahead to the shortcut",
        |world, _, _| {
            desktop(world).borrow_mut().message = UNSURE.into();
            update(world)?;
            send(world, "setup.continue", Value::Null)?;
            expect!(
                field(world, "wizard.step") == "access",
                "setup to stay on access; Snap Shot is {}",
                describe(world)
            );
            send(world, "setup.close", Value::Null)?;
            send(world, "setup.open", json!({"step": "shortcut"}))?;
            expect!(
                field(world, "wizard.step") == "access",
                "setup to open on access; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "Snap Shot was (on|off) when the user opened setup",
        |world, c, _| {
            if c[0] == "on" {
                turn_on(world)?;
            }
            send(world, "setup.open", Value::Null)
        },
    );
    steps.step(&format!("the setup footer offers {Q}"), |world, c, _| {
        expect!(
            field(world, "wizard.closeLabel") == c[0].as_str(),
            "setup to offer {}; Snap Shot is {}",
            c[0],
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the desktop cannot report whether capture is supported",
        |world, _, _| {
            portal_desktop(
                world,
                PortalDesktop {
                    screenshot_fails: true,
                    ..PortalDesktop::default()
                },
            )
        },
    );
    steps.step("the user checks capture access", |world, _, _| {
        send(world, "setup.open", Value::Null)?;
        send(world, "setup.continue", Value::Null)
    });
    steps.step(&format!("setup says {Q} and {Q}"), |world, c, _| {
        expect!(
            field(world, "wizard.heading") == c[0].as_str()
                && field(world, "wizard.body") == c[1].as_str(),
            "setup to say {} and {}; Snap Shot is {}",
            c[0],
            c[1],
            describe(world)
        );
        Ok(())
    });
    steps.step("capture access is not reported as ready", |world, _, _| {
        wait_for_field(world, "wizard.busy", json!(false))?;
        expect!(
            field(world, "wizard.step") == "access"
                && field(world, "wizard.continueLabel") == "Try again"
                && field(world, "status") == "Capture needs attention",
            "access not to be ready; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user is on the shortcut step(?: with a saved shortcut| on a desktop that gives shortcuts by portal)?",
        |world, _, _| {
            turn_on(world)?;
            send(world, "setup.open", Value::Null)?;
            expect!(
                field(world, "wizard.step") == "shortcut",
                "setup on the shortcut; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user is on the shortcut step on while recording",
        |world, _, _| {
            turn_on(world)?;
            send(world, "setup.open", Value::Null)?;
            send(world, "record.start", Value::Null)
        },
    );
    steps.step("capture access is lost", |world, _, _| {
        desktop(world).borrow_mut().message = UNSURE.into();
        update(world)
    });
    steps.step(&format!("setup says {Q}"), |world, c, _| {
        let wizard = field(world, "wizard");
        let says = wizard
            .as_object()
            .is_some_and(|wizard| wizard.values().any(|value| value == c[0].as_str()));
        expect!(says, "setup to say {}; it shows {}", c[0], show(&wizard));
        Ok(())
    });
    steps.step(
        "the user cannot finish until access is back",
        |world, _, _| {
            send(world, "setup.done", Value::Null)?;
            expect!(
                has_wizard(world) && field(world, "wizard.doneEnabled").as_bool() != Some(true),
                "setup to stay open without access; Snap Shot is {}",
                describe(world)
            );
            desktop(world).borrow_mut().message.clear();
            update(world)?;
            expect!(
                field(world, "wizard.doneEnabled").as_bool() == Some(true),
                "finishing once access is back; Snap Shot is {}",
                describe(world)
            );
            send(world, "setup.done", Value::Null)?;
            expect!(
                !has_wizard(world),
                "setup to finish; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the user records a different one", |world, _, _| {
        send(world, "record.start", Value::Null)?;
        press_named(world, "Ctrl+Alt+K")
    });
    steps.step(
        "the finishing button reads \"Save and finish\" and is available only when the shortcut can be saved",
        |world, _, _| {
            expect!(
                field(world, "wizard.doneLabel") == "Save and finish"
                    && field(world, "wizard.doneEnabled").as_bool() == Some(true)
                    && field(world, "shortcut.canSave").as_bool() == Some(true),
                "Save and finish, available; Snap Shot is {}",
                describe(world)
            );
            // One the desktop reserves cannot be saved, so setup cannot finish with it.
            send(world, "record.start", Value::Null)?;
            press_named(world, "Super+L")?;
            expect!(
                field(world, "wizard.doneLabel") == "Save and finish"
                    && field(world, "wizard.doneEnabled").as_bool() != Some(true),
                "Save and finish, unavailable; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the user records nothing", |world, _, _| {
        send(world, "shortcut.discard", Value::Null)
    });
    steps.step(&format!("the button reads {Q}"), |world, c, _| {
        expect!(
            field(world, "wizard.doneLabel") == c[0].as_str()
                && field(world, "wizard.doneEnabled").as_bool() == Some(true),
            "the button to read {}; Snap Shot is {}",
            c[0],
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "setup asked the desktop for a shortcut and its prompt is pending",
        |world, _, _| {
            portal_desktop(
                world,
                PortalDesktop {
                    bind: Answer::Hold,
                    ..PortalDesktop::default()
                },
            )?;
            set_setting(world, "snapShotShortcut", ctrl_shift_2())?;
            send(world, "setup.open", Value::Null)?;
            wait_prompting(world)
        },
    );
    steps.step(
        "the user can finish setup and approve the prompt later",
        |world, _, _| {
            expect!(
                field(world, "wizard.doneEnabled").as_bool() == Some(true),
                "setup to finish while the prompt is open; Snap Shot is {}",
                describe(world)
            );
            send(world, "setup.done", Value::Null)?;
            expect!(
                !has_wizard(world) && setting(world, "snapShotEnabled").as_bool() == Some(true),
                "setup to finish with capture on; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the desktop has refused the shortcut", |world, _, _| {
        bus().borrow_mut().answer(false)?;
        wait_for_field(world, "shortcut.pending", json!(false))?;
        send(world, "setup.open", Value::Null)
    });
    steps.step(
        "the user cannot finish until it is allowed or changed",
        |world, _, _| {
            send(world, "setup.done", Value::Null)?;
            expect!(
                has_wizard(world)
                    && field(world, "wizard.doneEnabled").as_bool() != Some(true)
                    && field(world, "wizard.permissions").as_bool() == Some(true),
                "setup to wait on the refused shortcut; Snap Shot is {}",
                describe(world)
            );
            send(world, "record.start", Value::Null)?;
            press_named(world, "Ctrl+Alt+K")?;
            expect!(
                field(world, "wizard.doneEnabled").as_bool() == Some(true),
                "a changed shortcut to finish setup; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );

    // The desktop portal's answers.
    steps.step(
        "(the desktop grants the shortcut and shows it as \"Ctrl\\+Alt\\+S\"|\
         the user refuses the permission prompt on a desktop that (?:can|cannot) ask again|\
         the desktop grants the shortcut but assigns no keys, and (?:can|cannot) ask again)",
        |world, c, _| {
            {
                let bus = bus();
                let mut bus = bus.borrow_mut();
                let portal = &mut bus.desktop;
                if c[0].contains("cannot ask") {
                    portal.shortcuts_version = 1;
                }
                if c[0].contains("Ctrl+Alt+S") {
                    portal.label = "Ctrl+Alt+S".into();
                }
                if c[0].contains("refuses") {
                    portal.bind = Answer::Refuse;
                }
                if c[0].contains("no keys") {
                    portal.bind = Answer::Unassigned;
                }
            }
            turn_on_with(world, ctrl_shift_2())
        },
    );
    steps.step(
        "the desktop's shortcut permission prompt is open",
        |world, _, _| {
            bus().borrow_mut().desktop.bind = Answer::Hold;
            turn_on_with(world, ctrl_shift_2())?;
            wait_prompting(world)
        },
    );
    steps.step(
        "the user takes up to two minutes to answer it",
        |world, _, _| {
            // Just short of the portal's two minutes.
            world.advance(119_000)?;
            snap::settle(world)
        },
    );
    steps.step(
        "HAL-C2 keeps waiting and the shortcut row keeps asking for the prompt to be approved",
        |world, _, _| {
            expect!(
                field(world, "shortcut.pending").as_bool() == Some(true)
                    && field(world, "shortcut.status") == PROMPT
                    && bus().borrow().prompting(),
                "the row to wait on the prompt; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the shortcut is registered as soon as the user approves",
        |world, _, _| {
            bus().borrow_mut().answer(true)?;
            wait_for_field(world, "shortcut.registered", json!(true))
        },
    );
    steps.step(
        "(the desktop's shortcut service restarts|the desktop closes HAL-C2's shortcut session|\
         the permission prompt is not answered in time|the desktop's shortcut service cannot be reached)",
        |world, c, _| {
            if c[0].contains("in time") {
                bus().borrow_mut().desktop.bind = Answer::Hold;
                turn_on_with(world, ctrl_shift_2())?;
                wait_prompting(world)?;
                world.advance(120_001)?;
                return snap::settle(world);
            }
            if c[0].contains("cannot be reached") {
                bus().borrow_mut().drop_service();
                return turn_on_with(world, ctrl_shift_2());
            }
            turn_on_with(world, ctrl_shift_2())?;
            wait_for_field(world, "shortcut.registered", json!(true))?;
            if c[0].contains("restarts") {
                bus().borrow_mut().restart_service();
            } else {
                bus().borrow_mut().close_session()?;
            }
            snap::settle(world)
        },
    );
    steps.step(
        "the user records (Shift\\+K|Ctrl\\+C|Ctrl\\+S|Ctrl\\+Z|Alt\\+Tab|Super\\+L)",
        |world, c, _| press_named(world, &c[0]),
    );
    steps.step("Save is not available", |world, _, _| {
        expect!(
            field(world, "shortcut.canSave").as_bool() != Some(true),
            "Save to be unavailable; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "Snap Shot is on and its shortcut is registered",
        |world, _, _| {
            portal_desktop(world, PortalDesktop::default())?;
            turn_on_with(world, ctrl_shift_2())?;
            wait_for_field(world, "shortcut.registered", json!(true))
        },
    );
    steps.step(
        "the user changes a setting that is not about Snap Shot",
        |world, _, _| {
            let wrap = setting(world, "wordWrap").as_bool() == Some(true);
            set_setting(world, "wordWrap", json!(!wrap))?;
            world.sync()
        },
    );
    steps.step(
        "the shortcut stays registered without being released and set up again",
        |world, _, _| {
            let (creates, binds, closes) = {
                let bus = bus();
                let bus = bus.borrow();
                (bus.creates, bus.triggers.len(), bus.closes)
            };
            expect!(
                field(world, "shortcut.registered").as_bool() == Some(true)
                    && creates == 1
                    && binds == 1
                    && closes == 0,
                "one session, never closed; {creates} sessions, {binds} binds, {closes} closed"
            );
            Ok(())
        },
    );
    steps.step(
        "an approved desktop shortcut session is not dropped",
        |_, _, _| {
            expect!(
                bus().borrow().session_open(),
                "the desktop's session to stay open"
            );
            Ok(())
        },
    );

    // SnapShotPortalSteps.cpp: the shortcut check.
    steps.step(
        "the desktop is being asked if the shortcut is free",
        |world, _, _| {
            desktop(world).borrow_mut().hold_checks = true;
            press(world, KEY_AT, CONTROL | SHIFT)
        },
    );
    steps.step(
        "the user recorded (?:a new shortcut|a shortcut and its check is still running)",
        |world, _, _| record_held(world, KEY_AT, CONTROL | SHIFT),
    );
    steps.step("the desktop fails while checking it", |world, _, _| {
        expect_status(
            world,
            CHECKING,
            "the row to say the shortcut is being checked",
        )?;
        answer_check(world, false, "")
    });
    steps.step(
        "the shortcut row shows the failure, or \"Could not check this shortcut\\.\"",
        |world, _, _| {
            expect_status(
                world,
                "Could not check this shortcut.",
                "a check that failed to say so",
            )?;
            // A failure with a reason shows the reason.
            record_held(world, 0x4b, CONTROL | ALT)?;
            answer_check(world, false, "The desktop shortcut service restarted.")?;
            expect_status(
                world,
                "The desktop shortcut service restarted.",
                "the desktop's reason",
            )
        },
    );
    steps.step("the user records another shortcut", |world, _, _| {
        record_held(world, 0x4b, CONTROL | ALT)
    });
    steps.step("the answer to the first check is ignored", |world, _, _| {
        answer_first_check(world, false, "The first shortcut is taken.")?;
        expect_status(world, CHECKING, "the first answer to change nothing")?;
        expect!(
            field(world, "shortcut.canSave").as_bool() != Some(true),
            "Save to wait on the second check"
        );
        Ok(())
    });
    steps.step(
        "the second shortcut's answer decides whether Save is available",
        |world, _, _| {
            answer_check(
                world,
                true,
                "Your desktop will confirm this shortcut when you save it.",
            )?;
            expect_status(world, "Ready to save.", "the second answer to count")?;
            expect!(
                field(world, "shortcut.canSave").as_bool() == Some(true)
                    && field(world, "shortcut.keys") == "Ctrl+Alt+K",
                "Ctrl+Alt+K to be ready to save; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );

    // Pausing the capture shortcut.
    steps.step(
        "the desktop fails to pause the capture shortcut",
        |world, _, _| {
            desktop(world).borrow_mut().refuse_pause = Some(String::new());
            set_setting(world, "snapShotEnabled", json!(true))
        },
    );
    steps.step("the user starts recording a shortcut", |world, _, _| {
        send(world, "record.start", Value::Null)
    });
    steps.step("recording does not start", |world, _, _| {
        expect!(
            field(world, "shortcut.recording").as_bool() != Some(true),
            "no recording; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user is told \"Could not start shortcut recording\\.\" or the desktop's reason",
        |world, _, _| {
            expect_status(
                world,
                "Could not start shortcut recording.",
                "recording that could not start to say so",
            )?;
            desktop(world).borrow_mut().refuse_pause =
                Some("Another app is holding the keyboard.".into());
            send(world, "record.start", Value::Null)?;
            expect_status(
                world,
                "Another app is holding the keyboard.",
                "the desktop's reason",
            )
        },
    );

    // Setup while the desktop is asked again.
    steps.step("setup is checking access or saving", |world, _, _| {
        portal_desktop(
            world,
            PortalDesktop {
                screenshot_fails: true,
                ..PortalDesktop::default()
            },
        )?;
        send(world, "enable", json!({"on": true}))?;
        wait_for_field(world, "wizard.continueLabel", json!("Try again"))?;
        {
            let bus = bus();
            let mut bus = bus.borrow_mut();
            bus.desktop.screenshot_fails = false;
            bus.desktop.hold_screenshot = true;
        }
        send(world, "setup.continue", Value::Null)?;
        wait_for_field(world, "wizard.busy", json!(true))
    });
    steps.step(
        "the user cannot close setup or move between its steps until it has finished",
        |world, _, _| {
            send(world, "setup.close", Value::Null)?;
            expect_still(world, "access", "closing")?;
            send(world, "enable", json!({"on": false}))?;
            expect_still(world, "access", "turning capture off")?;
            send(world, "setup.continue", Value::Null)?;
            expect_still(world, "access", "continuing")?;
            send(world, "record.start", Value::Null)?;
            expect!(
                field(world, "shortcut.recording").as_bool() != Some(true),
                "no recording while setup works"
            );
            world.wait_for("the desktop to be asked again", |_| {
                bus().borrow().screenshot_held()
            })?;
            bus().borrow_mut().answer_screenshot()?;
            wait_for_field(world, "wizard.busy", json!(false))?;
            send(world, "setup.continue", Value::Null)?;
            wait_for_field(world, "wizard.step", json!("shortcut"))?;
            send(world, "setup.close", Value::Null)?;
            expect!(
                !has_wizard(world),
                "setup to close once it has finished; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );

    // The capture sound.
    steps.step("the capture sound choices are open", |world, _, _| {
        set_setting(world, "snapShotEnabled", json!(true))?;
        send(world, "sound", json!({"value": "soft-pop"}))
    });
    steps.step(
        "the user plays Click without selecting it",
        |world, _, _| send(world, "sound.play", json!({"sound": "camera-shutter"})),
    );
    steps.step("Click plays once", |world, _, _| {
        let played = desktop(world).borrow().played.clone();
        expect!(
            played == ["camera-shutter"],
            "Click once; the desktop played {}",
            played.join(",")
        );
        Ok(())
    });
    // The popup staying open is the page's (tst_SnapShotSettings.qml).
    steps.step(
        "the choices stay open and the sound in use does not change",
        |world, _, _| {
            expect!(
                field(world, "sound.value") == "soft-pop"
                    && setting(world, "snapShotSound") == "soft-pop",
                "Whoosh to stay the sound; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );

    // The portal's shortcut session.
    steps.step(
        "the desktop's shortcut session could not be started",
        |world, _, _| {
            bus().borrow_mut().desktop.session_fails = true;
            set_setting(
                world,
                "snapShotShortcut",
                json!({"key": "2", "ctrlKey": true, "shiftKey": true}),
            )?;
            set_setting(world, "snapShotEnabled", json!(true))?;
            wait_for_field(
                world,
                "shortcut.status",
                json!("Your desktop could not create a capture shortcut session."),
            )?;
            expect!(
                field(world, "shortcut.permissions").as_bool() == Some(true),
                "asking again to be offered without a session; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "a new shortcut session asks the desktop for the shortcut",
        |world, _, _| {
            wait_prompting(world)?;
            let creates = bus().borrow().creates;
            expect!(
                creates == 2,
                "a second session; the desktop created {creates}"
            );
            wait_for_field(world, "shortcut.status", json!(PROMPT))
        },
    );
    steps.step(
        "the user asks for shortcut permission again",
        |world, _, _| {
            {
                let bus = bus();
                let mut bus = bus.borrow_mut();
                bus.desktop.session_fails = false;
                bus.desktop.bind = Answer::Hold;
            }
            send(world, "shortcut.permissions", Value::Null)
        },
    );

    // Keys the portal names.
    steps.step("the user records Ctrl\\+Alt\\+(Up|Home)", |world, c, _| {
        set_setting(world, "snapShotEnabled", json!(true))?;
        send(world, "record.start", Value::Null)?;
        let key = if c[0] == "Up" { KEY_UP } else { KEY_HOME };
        press(world, key, CONTROL | ALT)
    });
    steps.step(
        &format!("saving asks the desktop for {Q}"),
        |world, c, _| {
            send(world, "shortcut.save", Value::Null)?;
            let trigger = c[0].clone();
            world.wait_for_with(
                |w| {
                    super::snap_shot_bus::settle(w.engine());
                    bus().borrow().triggers.contains(&trigger)
                },
                |_| {
                    format!(
                        "the desktop to be asked for {}; it was asked for {}",
                        c[0],
                        bus().borrow().triggers.join(",")
                    )
                },
            )
        },
    );
    steps.step(
        "the saved shortcut is pressing both Shift keys",
        |world, _, _| {
            set_setting(
                world,
                "snapShotShortcut",
                json!({"kind": "both-shift-keys"}),
            )?;
            set_setting(world, "snapShotEnabled", json!(true))
        },
    );
}

/// A portal desktop whose panel is not opened yet: the panel's own asking
/// is what the scenario watches.
fn portal_desktop_closed(world: &mut World, portal: PortalDesktop) -> Outcome {
    {
        let bus = bus();
        let mut bus = bus.borrow_mut();
        bus.reset();
        bus.desktop = portal;
    }
    reset_with(
        world,
        environment("wayland", ""),
        Some(super::snap_shot_bus::factory()),
    )
}

/// The fake backend answers the first shortcut check it holds, of two:
/// it answers in the order it was asked.
fn answer_first_check(world: &mut World, available: bool, message: &str) -> Outcome {
    answer_check(world, available, message)
}
