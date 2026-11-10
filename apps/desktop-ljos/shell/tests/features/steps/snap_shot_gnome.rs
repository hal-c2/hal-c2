//! Snap Shot on GNOME (GnomeSnapShot, desktop-qt's SnapShotGnomeSteps.cpp):
//! setup of the extension bundled with the app, against a GNOME Shell that
//! answers here and a scratch XDG_DATA_HOME. Nothing reaches the session bus
//! or the real gnome-shell folder. The panel and the fake portal come from
//! snap_shot.rs.

use std::cell::RefCell;
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use hal_c2_shell::snap_shot::gnome::{
    self, Capture, Extension, GnomeFactory, GnomeShell, GnomeSnapShot, Paths, Reply,
};
use hal_c2_shell::snap_shot::{Backend, unsupported_setup};
use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
use serde_json::{Value, json};
use tempfile::TempDir;

use super::snap_shot::{
    self as shot, attachments, capture, desktop, environment, expect_toast, field, on_reset,
    open_panel, open_thread, reset_with, send, thread_key, turn_on,
};
use super::snap_shot_helper::{
    helper_conflicts_kept, helper_in_use, helper_nothing_installed, helper_on_kde, scratch_root,
    setup_action,
};
use crate::expect;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;

/// What GNOME answers, and what it was asked.
#[derive(Default)]
struct FakeGnome {
    extension: Extension,
    capture: Capture,
    enabled: Vec<bool>,
    captures: Vec<String>,
    flashes: Vec<bool>,
    home: Option<TempDir>,
    /// The files before the step under test.
    before: Vec<PathBuf>,
}

thread_local! {
    static GNOME: Rc<RefCell<FakeGnome>> = Rc::new(RefCell::new(FakeGnome::default()));
    /// The factory the next desktop reset hands the shell.
    static PENDING: RefCell<Option<GnomeFactory>> = const { RefCell::new(None) };
}

fn gnome_state() -> Rc<RefCell<FakeGnome>> {
    GNOME.with(Rc::clone)
}

/// Answers at once, as GNOME Shell would after a moment.
struct FakeShell {
    state: Rc<RefCell<FakeGnome>>,
    replies: Vec<Reply>,
}

impl GnomeShell for FakeShell {
    fn inspect(&mut self) {
        let extension = self.state.borrow().extension.clone();
        self.replies.push(Reply::Inspected(extension));
    }
    fn set_enabled(&mut self, on: bool) {
        let mut g = self.state.borrow_mut();
        g.enabled.push(on);
        g.extension.state = Some(if on { 1 } else { 2 });
        g.extension.service = if on { 2 } else { 0 };
        self.replies.push(Reply::Enabled(String::new()));
    }
    fn capture(&mut self, bus_name: &str, flash: bool) {
        let mut g = self.state.borrow_mut();
        g.captures.push(bus_name.to_owned());
        g.flashes.push(flash);
        self.replies.push(Reply::Captured(g.capture.clone()));
    }
    fn replies(&mut self) -> Vec<Reply> {
        std::mem::take(&mut self.replies)
    }
}

fn bundle() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../native/gnome-snap-shot")
}

fn data_home() -> PathBuf {
    gnome_state()
        .borrow()
        .home
        .as_ref()
        .map(|home| home.path().to_owned())
        .unwrap_or_default()
}

fn paths() -> Paths {
    Paths {
        bundle: bundle(),
        data_home: data_home(),
        rename: None,
    }
}

fn target() -> PathBuf {
    paths().target()
}

fn write_installed(version: f64) -> Outcome {
    let dir = target();
    let written = fs::create_dir_all(&dir).and_then(|_| {
        fs::write(
            dir.join("metadata.json"),
            json!({"uuid": gnome::UUID, "version": version, "shell-version": ["47"]}).to_string(),
        )
    });
    expect!(
        written.is_ok(),
        "the installed extension to be writable: {written:?}"
    );
    Ok(())
}

fn bundled() -> f64 {
    gnome::metadata(&bundle()).map_or(0.0, |m| m.version)
}

fn installed_version() -> f64 {
    gnome::metadata(&target()).map_or(0.0, |m| m.version)
}

fn png() -> Vec<u8> {
    let mut image = RgbaImage::new(64, 48);
    for pixel in image.pixels_mut() {
        *pixel = Rgba([0, 139, 139, 255]);
    }
    let mut bytes = Vec::new();
    let _ =
        DynamicImage::ImageRgba8(image).write_to(&mut Cursor::new(&mut bytes), ImageFormat::Png);
    bytes
}

/// Puts the stand-ins away with the desktop, but for the one the next
/// session asked for.
fn reset() {
    gnome::set_gnome_factory(PENDING.with(|pending| pending.borrow_mut().take()));
}

/// A GNOME session where GNOME 47 has answered nothing about the extension.
fn session(world: &mut World, picker: bool) -> Outcome {
    prepare()?;
    start(world, picker)
}

/// GNOME's answers and a scratch data home, before the desktop starts: the
/// shell looks at the extension once when it starts.
fn prepare() -> Outcome {
    let home = tempfile::Builder::new()
        .prefix("gnome-")
        .tempdir_in(scratch_root());
    expect!(home.is_ok(), "a scratch data home: {home:?}");
    {
        let state = gnome_state();
        let mut g = state.borrow_mut();
        *g = FakeGnome::default();
        g.home = home.ok();
        g.extension.shell_version = "47.2".into();
        g.capture.png = png();
        g.capture.metadata = r#"{"title":"Docs","appName":"Firefox"}"#.into();
    }
    let factory: GnomeFactory = Rc::new(|portal: Box<dyn Backend>| {
        Box::new(GnomeSnapShot::new(
            portal,
            Box::new(FakeShell {
                state: gnome_state(),
                replies: Vec::new(),
            }),
            paths(),
        )) as Box<dyn Backend>
    });
    PENDING.with(|pending| *pending.borrow_mut() = Some(factory));
    Ok(())
}

/// The desktop on GNOME, with what `prepare` and the steps since set up.
fn start(world: &mut World, picker: bool) -> Outcome {
    reset_with(world, environment("wayland", "GNOME"), None)?;
    desktop(world).borrow_mut().picker = picker;
    Ok(())
}

/// The extension loaded by GNOME, in the state GetExtensionInfo reports.
fn loaded(version: f64, state: i32) -> Outcome {
    write_installed(version)?;
    let g = gnome_state();
    let mut g = g.borrow_mut();
    g.extension.state = Some(state);
    g.extension.version = Some(version);
    Ok(())
}

fn enabled() -> Outcome {
    loaded(bundled(), 1)?;
    gnome_state().borrow_mut().extension.service = 2;
    Ok(())
}

/// What the session's extension folder and backups hold, to compare.
fn files() -> Vec<PathBuf> {
    fn walk(dir: &Path, found: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            found.push(path.clone());
            if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                walk(&path, found);
            }
        }
    }
    let mut found = Vec::new();
    walk(&data_home(), &mut found);
    found.sort();
    found
}

fn remember_files() {
    gnome_state().borrow_mut().before = files();
}

fn expect_files_kept() -> Outcome {
    let now = files();
    expect!(
        now == gnome_state().borrow().before,
        "the files as they were; they are {now:?}"
    );
    Ok(())
}

fn expect_wizard(world: &World, key: &str, value: &str) -> Outcome {
    expect!(
        field(world, &format!("wizard.{key}")) == value,
        "setup's {key} to be {value}; Snap Shot is {}",
        show(&shot::page(world))
    );
    Ok(())
}

fn wizard_says(world: &World, key: &str, part: &str) -> Outcome {
    expect!(
        text(&field(world, &format!("wizard.{key}"))).contains(part),
        "setup's {key} to say {part}; Snap Shot is {}",
        show(&shot::page(world))
    );
    Ok(())
}

fn on_access_step(world: &mut World) -> Outcome {
    open_panel(world)?;
    send(world, "setup.open", json!({"step": "access"}))
}

/// The flash and animation rows say it (the turn steps' "the user is told").
fn told_by_effects(world: &mut World) -> Outcome {
    open_panel(world)?;
    world.told_in_place = Some(Rc::new(|w: &World| {
        vec![
            text(&field(w, "flash.status")),
            text(&field(w, "animations.status")),
        ]
    }));
    Ok(())
}

fn choose_step(world: &mut World, action: &str) -> Outcome {
    on_access_step(world)?;
    remember_files();
    send(world, "setup.action", json!({"action": action}))
}

/// The shell's thread is open and Settings, SnapShots with it.
fn open_thread_for_capture(world: &mut World) -> Outcome {
    open_thread(world)?;
    open_panel(world)
}

fn portal_captures(world: &mut World) -> usize {
    desktop(world).borrow().captures.len()
}

pub fn register(steps: &mut Steps) {
    on_reset(reset);

    steps.step(
        "a GNOME session where the extension (?:is )?(not installed|was just installed|installed but waiting for a new login|installed but too old|installed while GNOME extensions are off|installed but turned off|enabled and answering|failing to start)",
        |world, c, _| {
            prepare()?;
            let state = c[0].as_str();
            if state == "was just installed" || state.ends_with("new login") {
                write_installed(bundled())?;
            } else if state.ends_with("too old") {
                loaded(bundled() - 1.0, 2)?;
            } else if state.ends_with("are off") {
                loaded(bundled(), 2)?;
                gnome_state().borrow_mut().extension.user_extensions_enabled = false;
            } else if state.ends_with("turned off") {
                loaded(bundled(), 2)?;
            } else if state.starts_with("enabled") {
                enabled()?;
            } else if state.starts_with("failing") {
                loaded(bundled(), 3)?;
                gnome_state().borrow_mut().extension.error = "JS ERROR".into();
            }
            start(world, true)?;
            open_panel(world)
        },
    );
    steps.step(
        &format!("setup says {Q} with the action {Q}"),
        |world, c, _| {
            expect_wizard(world, "heading", &c[0])?;
            expect_wizard(world, "continueLabel", &c[1])
        },
    );
    steps.step("the user continues setup", |world, _, _| {
        on_access_step(world)
    });
    steps.step(
        "the user is asked to sign out and back in, and setup waits for that",
        |world, _, _| {
            expect_wizard(world, "heading", "Extension installed")?;
            expect_wizard(world, "step", "access")?;
            wizard_says(world, "body", "sign out")
        },
    );

    steps.step(
        "a GNOME version the extension does not support",
        |world, _, _| {
            prepare()?;
            gnome_state().borrow_mut().extension.shell_version = "44.1".into();
            start(world, true)?;
            open_panel(world)
        },
    );
    steps.step(
        "it points to Take snapshot in the command palette to choose a window",
        |world, _, _| wizard_says(world, "body", "Take snapshot from the command palette"),
    );
    steps.step("the user can still finish setup", |world, _, _| {
        send(world, "setup.continue", Value::Null)?;
        expect_wizard(world, "step", "shortcut")?;
        expect!(
            field(world, "backend") == "picker",
            "the picker to capture; Snap Shot is {}",
            show(&shot::page(world))
        );
        Ok(())
    });

    steps.step(
        "the GNOME extension is (enabled|installed but turned off)",
        |world, c, _| {
            prepare()?;
            if c[0] == "enabled" {
                enabled()?;
            } else {
                loaded(bundled(), 2)?;
            }
            start(world, true)?;
            open_panel(world)
        },
    );
    steps.step(
        "the user opens Advanced for the GNOME extension",
        |world, _, _| on_access_step(world),
    );
    steps.step(
        "they can disable the extension, and turn it back on",
        |world, _, _| {
            let option = field(world, "wizard.advanced")
                .get(0)
                .cloned()
                .unwrap_or(Value::Null);
            expect!(
                option["action"] == "disable-extension"
                    && text(&option["note"]).contains("No download needed"),
                "a way to disable the extension; Snap Shot is {}",
                show(&shot::page(world))
            );
            send(world, "setup.action", json!({"action": option["action"]}))?;
            expect!(
                gnome_state().borrow().enabled == [false],
                "GNOME to be asked to disable it"
            );
            expect_wizard(world, "action", "enable-extension")?;
            send(world, "setup.action", json!({"action": "enable-extension"}))?;
            expect!(
                gnome_state().borrow().enabled == [false, true],
                "GNOME to be asked to enable it"
            );
            expect_wizard(world, "heading", "Capture is ready")
        },
    );

    steps.step(
        "a GNOME session that still needs a new login",
        |world, _, _| {
            prepare()?;
            write_installed(bundled())?;
            start(world, true)?;
            on_access_step(world)
        },
    );
    steps.step("the user checks again", |world, _, _| {
        send(world, "setup.continue", Value::Null)
    });
    steps.step(
        "the answer is acknowledged and setup keeps asking for the login",
        |world, _, _| {
            expect_wizard(
                world,
                "checkMessage",
                "Still waiting for you to sign out and back in.",
            )?;
            expect_wizard(world, "heading", "Extension installed")
        },
    );

    steps.step(
        "a GNOME session with an older HAL-C2 extension installed",
        |world, _, _| {
            prepare()?;
            loaded(bundled() - 1.0, 1)?;
            start(world, true)
        },
    );
    steps.step("the user updates the extension in setup", |world, _, _| {
        choose_step(world, "install-extension")
    });
    steps.step(
        "the new extension is put in place in one step",
        |_, _, _| {
            expect!(
                installed_version() == bundled(),
                "the bundled version in place; it is {}",
                installed_version()
            );
            expect!(
                target().join("captureService.js").exists(),
                "the bundle's files in place"
            );
            let staged: Vec<String> = fs::read_dir(target().parent().unwrap_or(Path::new("")))
                .into_iter()
                .flatten()
                .flatten()
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .filter(|name| name.starts_with(".hal-c2-capture-install-"))
                .collect();
            expect!(staged.is_empty(), "no staging left; found {staged:?}");
            Ok(())
        },
    );
    steps.step(
        "the replaced version is kept in a backup folder",
        |_, _, _| {
            let backups = data_home().join("hal-c2/extension-backups");
            let boxes: Vec<PathBuf> = fs::read_dir(&backups)
                .into_iter()
                .flatten()
                .flatten()
                .filter(|entry| entry.file_name().to_string_lossy().starts_with("capture-"))
                .map(|entry| entry.path())
                .collect();
            expect!(boxes.len() == 1, "one backup; found {boxes:?}");
            let kept = gnome::metadata(&boxes[0].join(gnome::UUID));
            expect!(
                kept.is_some_and(|kept| kept.version == bundled() - 1.0),
                "the old version in the backup"
            );
            Ok(())
        },
    );
    steps.step("a failed update puts the old version back", |_, _, _| {
        write_installed(bundled() - 1.0)?;
        let mut failing = paths();
        let place = target();
        failing.rename = Some(Rc::new(move |from: &Path, to: &Path| {
            to != place && fs::rename(from, to).is_ok()
        }));
        expect!(!gnome::install(&failing).is_empty(), "the update to fail");
        expect!(
            installed_version() == bundled() - 1.0,
            "the old version back; it is {}",
            installed_version()
        );
        Ok(())
    });

    steps.step(
        "a GNOME session with a newer HAL-C2 extension installed than the one bundled with the app",
        |world, _, _| {
            prepare()?;
            loaded(bundled() + 1.0, 1)?;
            start(world, true)
        },
    );
    steps.step(
        "the HAL-C2 extension's folder is a link or not a regular folder",
        |world, _, _| {
            prepare()?;
            let place = target();
            let parent = place.parent().map(Path::to_owned).unwrap_or_default();
            let _ = fs::create_dir_all(&parent);
            // A link to nowhere counts too.
            let linked = link(&parent.join("elsewhere/gone"), &place);
            expect!(linked.is_ok(), "the link to be made: {linked:?}");
            start(world, true)
        },
    );
    steps.step("the user installs the extension in setup", |world, _, _| {
        choose_step(world, "install-extension")
    });
    steps.step("nothing is replaced", |world, _, _| {
        if helper_in_use(world) {
            return helper_conflicts_kept();
        }
        expect_files_kept()
    });
    steps.step(
        "the user is told a newer extension is installed and to update HAL-C2 instead",
        |world, _, _| {
            expect_wizard(
                world,
                "details",
                "A newer extension is installed. Update HAL-C2 instead of replacing it.",
            )
        },
    );
    steps.step(
        "the user is told to manage it in GNOME Extensions instead",
        |world, _, _| {
            expect_wizard(
                world,
                "details",
                "The extension installation is not a regular directory. Manage it in GNOME Extensions instead.",
            )
        },
    );

    steps.step(
        "a GNOME session where the user has turned off all user extensions",
        |world, _, _| {
            prepare()?;
            loaded(bundled(), 2)?;
            gnome_state().borrow_mut().extension.user_extensions_enabled = false;
            start(world, true)?;
            open_panel(world)
        },
    );
    steps.step(
        "setup tells the user to turn on Extensions in the GNOME Extensions app",
        |world, _, _| {
            expect_wizard(world, "heading", "Allow GNOME extensions")?;
            wizard_says(world, "body", "turn on Extensions")
        },
    );
    steps.step(
        "HAL-C2 does not enable the user's other extensions",
        |_, _, _| {
            expect!(
                gnome_state().borrow().enabled.is_empty(),
                "GNOME not to be asked to enable anything"
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told to turn on HAL-C2 SnapShots in GNOME Extensions",
        |world, _, _| {
            expect_wizard(world, "heading", "Enable the extension")?;
            wizard_says(world, "body", "HAL-C2 SnapShots")
        },
    );

    steps.step(
        "the extension bundled with the app is copied for this user only",
        |_, _, _| {
            let list: Value = fs::read(bundle().join("bundle.json"))
                .ok()
                .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                .unwrap_or(Value::Null);
            let names = list["files"].as_array().cloned().unwrap_or_default();
            expect!(!names.is_empty(), "a bundle with files");
            for name in names {
                let name = text(&name);
                expect!(
                    target().join(&name).exists(),
                    "{name} in the user's extensions"
                );
            }
            Ok(())
        },
    );
    steps.step(
        "nothing is downloaded and no administrator password is asked",
        |world, _, _| {
            // Local files and nothing else: GNOME wasn't asked for anything
            // but its answers.
            expect!(
                gnome_state().borrow().enabled.is_empty(),
                "GNOME not to be asked to enable it before a login"
            );
            expect_wizard(world, "heading", "Extension installed")
        },
    );

    steps.step(
        "Snap Shot is on with the GNOME extension not enabled",
        |world, _, _| {
            prepare()?;
            loaded(bundled(), 2)?;
            start(world, true)?;
            turn_on(world)
        },
    );
    steps.step(
        "a Linux session where the GNOME extension is installed but is the first version",
        |world, _, _| {
            prepare()?;
            loaded(1.0, 1)?;
            gnome_state().borrow_mut().extension.service = 1;
            start(world, true)?;
            turn_on(world)?;
            told_by_effects(world)
        },
    );
    steps.step(
        "a Linux session where GNOME setup has not been finished",
        |world, _, _| {
            prepare()?;
            loaded(bundled(), 2)?;
            start(world, true)?;
            turn_on(world)?;
            told_by_effects(world)
        },
    );

    steps.step(
        "the desktop app runs (on a GNOME session|on a KDE Plasma session|on Linux without GNOME|on Linux)",
        |world, c, _| {
            session(world, true)?;
            if c[0] == "on a KDE Plasma session" {
                helper_on_kde(world)?;
            } else {
                if c[0] != "on a GNOME session" {
                    reset_with(world, environment("wayland", ""), None)?;
                    world.sync()?;
                }
                on_access_step(world)?;
            }
            remember_files();
            Ok(())
        },
    );
    steps.step("setup is asked to (.*)", |world, c, _| {
        let action = setup_action(&c[0]);
        send(world, "setup.action", json!({"action": action}))?;
        gnome_state().borrow_mut().capture.error = unsupported_setup(action);
        Ok(())
    });
    steps.step("nothing is installed, removed or changed", |world, _, _| {
        if helper_in_use(world) {
            helper_nothing_installed()?;
        }
        expect_files_kept()?;
        expect!(
            gnome_state().borrow().enabled.is_empty(),
            "GNOME not to be asked for anything"
        );
        Ok(())
    });
    steps.step(
        "the user is told this step is not available in this session",
        |world, _, _| {
            let told = gnome_state().borrow().capture.error.clone();
            expect_wizard(world, "details", &told)
        },
    );

    steps.step("a Linux Wayland session on GNOME", |world, _, _| {
        prepare()?;
        enabled()?;
        start(world, true)
    });
    steps.step(
        "capture works through the HAL-C2 GNOME extension",
        |world, _, _| {
            open_panel(world)?;
            expect!(
                field(world, "backend") == "gnome-extension"
                    && field(world, "status") == "Ready to capture",
                "capture through the extension; Snap Shot is {}",
                show(&shot::page(world))
            );
            Ok(())
        },
    );

    steps.step(
        "a GNOME session with the HAL-C2 extension enabled",
        |world, _, _| {
            prepare()?;
            enabled()?;
            start(world, true)?;
            open_thread_for_capture(world)?;
            turn_on(world)
        },
    );
    steps.step(
        "the desktop portal can capture a single window",
        |world, _, _| {
            prepare()?;
            enabled()?;
            start(world, false)?;
            open_thread_for_capture(world)?;
            turn_on(world)
        },
    );
    steps.step(
        "the capture goes through the desktop portal",
        |world, _, _| {
            let captures = portal_captures(world);
            expect!(
                captures == 1,
                "the portal to capture once; it did {captures} times"
            );
            Ok(())
        },
    );
    steps.step(
        "the extension is not asked for the screenshot",
        |_, _, _| {
            expect!(
                gnome_state().borrow().captures.is_empty(),
                "no capture through the extension"
            );
            Ok(())
        },
    );

    steps.step(
        "a GNOME session with two HAL-C2 instances running",
        |world, _, _| {
            prepare()?;
            enabled()?;
            start(world, true)?;
            open_thread_for_capture(world)?;
            turn_on(world)
        },
    );
    steps.step("one instance is capturing a window", |_, _, _| {
        // The name is held by the other instance: the session bus's
        // GNOME Shell answers this.
        gnome_state().borrow_mut().capture.error =
            "Another HAL-C2 instance is capturing a window. Try again.".into();
        Ok(())
    });
    steps.step(
        "the other instance's user presses the Snap Shot shortcut",
        |world, _, _| capture(world),
    );
    steps.step(
        "that capture fails and the user is told another HAL-C2 instance is capturing and to try again",
        |world, _, _| {
            let extension = gnome_state().borrow().captures.len();
            let portal = portal_captures(world);
            expect!(
                extension == 1 && portal == 0,
                "no other capture tried; the extension took {extension}, the portal {portal}"
            );
            let key = thread_key(world);
            expect!(attachments(world, &key).is_empty(), "nothing attached");
            expect_toast(
                world,
                "Snapshot failed",
                "Another HAL-C2 instance is capturing a window. Try again.",
            )
        },
    );
}

#[cfg(unix)]
fn link(original: &Path, link: &Path) -> std::io::Result<()> {
    std::os::unix::fs::symlink(original, link)
}

#[cfg(not(unix))]
fn link(_original: &Path, _link: &Path) -> std::io::Result<()> {
    Err(std::io::ErrorKind::Unsupported.into())
}
