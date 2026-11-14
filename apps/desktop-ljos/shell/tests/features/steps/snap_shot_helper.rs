//! The capture helpers of KDE Plasma and Hyprland (HelperSnapShot,
//! CaptureHelper; desktop-qt's SnapShotHelperSteps.cpp) against a fake helper
//! in a scratch directory: a shell script that does what its mode file says
//! and logs how it was called. No real helper or KDE service tool can run
//! from here, because the paths are replaced before any desktop starts.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

use hal_c2_shell::snap_shot::helper::{self, CaptureHelper, Kind, Paths};
use image::{Rgba, RgbaImage};
use serde_json::{Value, json};
use tempfile::TempDir;

use super::snap_shot::{
    self as shot, attachments, capture, field, on_reset, open_panel, open_thread, reset_with, send,
    set_setting, setting, thread_key, wait_for_field,
};
use super::snap_shot_bus::{self, Answer, PortalDesktop};
use crate::expect;
use crate::harness::{Outcome, Steps, show, text};
use crate::world::World;

/// Where the scenarios' scratch files go: the build's own, never /tmp.
pub(crate) fn scratch_root() -> PathBuf {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../target/tmp/snap-gnome-home");
    let _ = fs::create_dir_all(&root);
    root
}

/// The fake helpers, their data home and their log, made once.
struct Scratch {
    root: TempDir,
}

impl Scratch {
    fn path(&self, name: &str) -> PathBuf {
        self.root.path().join(name)
    }
    fn bundle(&self, kind: Kind) -> PathBuf {
        self.path("bundle").join(kind.executable_name())
    }
    fn data_home(&self) -> PathBuf {
        self.path("data")
    }
    fn tools(&self) -> PathBuf {
        self.path("tools")
    }
    fn no_tools(&self) -> PathBuf {
        self.path("no-tools")
    }
}

fn write(path: &Path, bytes: &[u8], executable: bool) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::remove_file(path);
    let _ = fs::write(path, bytes);
    #[cfg(unix)]
    if executable {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o755));
    }
    #[cfg(not(unix))]
    let _ = executable;
}

/// Exits with what the mode file asks for; every call is logged.
fn helper_script(root: &Path) -> String {
    format!(
        r#"#!/bin/sh
root='{}'
echo "$*" >> "$root/calls"
case "$(cat "$root/mode")" in
  hang) exec sleep 30 ;;
  silent) exit 1 ;;
  denied-kde) echo 'org.kde.KWin.ScreenShot2.Error.NoAuthorized' >&2; exit 1 ;;
  denied-capture) [ "$1" = capture ] && {{ echo 'Hyprland denied screen capture. Allow HAL-C2 in the screen-sharing prompt, then try again.' >&2; exit 1; }} ;;
esac
case "$1" in
  check) echo '{{"feedbackAvailable":false}}' ;;
  capture) cp "$root/capture.png" "$2/capture.png"; echo '{{"window":{{"appName":"Browser","title":"Docs"}}}}' ;;
esac
"#,
        root.display()
    )
}

fn make_scratch() -> Scratch {
    let root = tempfile::Builder::new()
        .prefix("helpers-")
        .tempdir_in(scratch_root())
        .expect("a scratch directory for the capture helpers");
    let scratch = Scratch { root };
    let _ = fs::create_dir_all(scratch.no_tools());
    let script = helper_script(scratch.root.path());
    for kind in [Kind::Kde, Kind::Hyprland] {
        write(&scratch.bundle(kind), script.as_bytes(), true);
    }
    for tool in ["kbuildsycoca6", "systemd-run"] {
        write(&scratch.tools().join(tool), b"#!/bin/sh\nexit 0\n", true);
    }
    let mut image = RgbaImage::new(320, 200);
    for pixel in image.pixels_mut() {
        *pixel = Rgba([0, 139, 139, 255]);
    }
    let _ = image.save(scratch.path("capture.png"));
    scratch
}

/// What a link conflict must leave as it found it.
struct Conflict {
    path: PathBuf,
    bytes: Vec<u8>,
}

thread_local! {
    static SCRATCH: Rc<Scratch> = Rc::new(make_scratch());
    static BUNDLE_MISSING: Cell<bool> = const { Cell::new(false) };
    /// A session reads the helper's files as they are, not as a new
    /// scenario's.
    static KEEP_HELPER: Cell<bool> = const { Cell::new(false) };
    static KDE_SCENARIO: Cell<bool> = const { Cell::new(false) };
    static CONFLICTS: RefCell<Vec<Conflict>> = const { RefCell::new(Vec::new()) };
}

fn scratch() -> Rc<Scratch> {
    SCRATCH.with(Rc::clone)
}

fn set_mode(mode: &str) {
    write(
        &scratch().path("mode"),
        format!("{mode}\n").as_bytes(),
        false,
    );
}

fn kind_of(desktop: &str) -> Kind {
    if desktop == "KDE Plasma" {
        Kind::Kde
    } else {
        Kind::Hyprland
    }
}

fn environment_named(desktop: &str) -> HashMap<String, String> {
    HashMap::from([
        ("XDG_SESSION_TYPE".to_owned(), "wayland".to_owned()),
        ("WAYLAND_DISPLAY".to_owned(), "wayland-1".to_owned()),
        ("XDG_CURRENT_DESKTOP".to_owned(), desktop.to_owned()),
        (
            "HOME".to_owned(),
            scratch().path("home").display().to_string(),
        ),
    ])
}

fn environment_of(kind: Kind) -> HashMap<String, String> {
    environment_named(match kind {
        Kind::Kde => "KDE",
        Kind::Hyprland => "Hyprland",
    })
}

fn installed(kind: Kind) -> PathBuf {
    CaptureHelper::new(
        kind,
        Paths {
            bundle: PathBuf::new(),
            data_home: scratch().data_home(),
        },
    )
    .executable()
}

fn entry() -> PathBuf {
    scratch()
        .data_home()
        .join("applications/io.github.halc2.HalC2.KdeCapture.desktop")
}

/// Installs through a helper of its own, as setup would, and waits for it.
fn install(kind: Kind) -> Outcome {
    let mut helper = CaptureHelper::new(
        kind,
        Paths {
            bundle: scratch().bundle(kind),
            data_home: scratch().data_home(),
        },
    );
    helper.perform(kind.install_action());
    helper.wait();
    expect!(
        installed(kind).exists(),
        "the helper to install; it says {}",
        helper.state().message
    );
    Ok(())
}

fn uninstall() {
    let _ = fs::remove_dir_all(scratch().data_home());
}

fn calls() -> Vec<String> {
    fs::read_to_string(scratch().path("calls"))
        .unwrap_or_default()
        .lines()
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect()
}

/// No path a helper comes from is ever real.
fn seams() {
    helper::set_paths(Some(Rc::new(|kind: Kind| {
        let scratch = scratch();
        Paths {
            bundle: if BUNDLE_MISSING.get() {
                PathBuf::new()
            } else {
                scratch.bundle(kind)
            },
            data_home: scratch.data_home(),
        }
    })));
}

/// Every scenario starts with the helper installed, as if setup had been
/// done before; the steps take it away.
fn reset() {
    seams();
    if KEEP_HELPER.get() {
        return;
    }
    KDE_SCENARIO.set(false);
    CONFLICTS.with(|conflicts| conflicts.borrow_mut().clear());
    BUNDLE_MISSING.set(false);
    helper::set_tool_path(Some(vec![scratch().tools()]));
    helper::set_timeout(None);
    set_mode("ok");
    let _ = fs::remove_file(scratch().path("calls"));
    uninstall();
    // A failed install shows in the scenario that needs the helper.
    let _ = install(Kind::Kde);
    let _ = install(Kind::Hyprland);
}

/// A fresh desktop in `env` that keeps the helper's files as they are.
fn load(world: &mut World, env: HashMap<String, String>) -> Outcome {
    KEEP_HELPER.set(true);
    let reset = reset_with(world, env, None);
    KEEP_HELPER.set(false);
    reset?;
    open_panel(world)
}

fn tell_in_place(world: &mut World) {
    world.told_in_place = Some(Rc::new(|w: &World| {
        [
            "wizard.details",
            "flash.status",
            "animations.status",
            "shortcut.status",
        ]
        .iter()
        .map(|path| text(&field(w, path)))
        .collect()
    }));
}

/// A desktop with the helper in `state`, and the panel open.
fn desktop_with(world: &mut World, kind: Kind, state: &str) -> Outcome {
    uninstall();
    if state != "not installed" {
        install(kind)?;
    }
    if state == "out of date" {
        write(&installed(kind), b"#!/bin/sh\n# an older build\n", true);
    }
    if state == "failing its check" || state == "failing" {
        set_mode("silent");
    }
    load(world, environment_of(kind))?;
    tell_in_place(world);
    Ok(())
}

fn describe(world: &World) -> String {
    show(&shot::page(world))
}

fn wait_for_helper(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| field(w, "checking").as_bool() != Some(true),
        |w| format!("the helper to answer; Snap Shot is {}", describe(w)),
    )
}

fn expect_wizard_tells(world: &mut World, wanted: &str) -> Outcome {
    let wanted = wanted.to_owned();
    world.wait_for_with(
        |w| text(&field(w, "wizard.details")).contains(&wanted),
        |w| {
            format!(
                "setup to tell the user {wanted}; Snap Shot is {}",
                describe(w)
            )
        },
    )
}

fn expect_toast_containing(world: &mut World, wanted: &str) -> Outcome {
    let wanted = wanted.to_owned();
    world.wait_for_with(
        |w| {
            w.state("toasts")["items"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|toast| text(&toast["description"]).contains(&wanted))
        },
        |w| {
            format!(
                "a toast saying {wanted}; the shell shows {}",
                show(&w.state("toasts"))
            )
        },
    )
}

fn link(original: &Path, link: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    return std::os::unix::fs::symlink(original, link);
    #[cfg(not(unix))]
    {
        let _ = (original, link);
        Err(std::io::ErrorKind::Unsupported.into())
    }
}

fn link_instead(path: &Path) -> Outcome {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let target = scratch().path(&format!("elsewhere-{name}"));
    write(&target, b"not the helper\n", false);
    let _ = fs::remove_file(path);
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let linked = link(&target, path);
    expect!(linked.is_ok(), "to link {}: {linked:?}", path.display());
    CONFLICTS.with(|conflicts| {
        conflicts.borrow_mut().push(Conflict {
            path: path.to_owned(),
            bytes: b"not the helper\n".to_vec(),
        })
    });
    Ok(())
}

fn expect_conflicts_kept() -> Outcome {
    CONFLICTS.with(|conflicts| {
        let conflicts = conflicts.borrow();
        expect!(!conflicts.is_empty(), "a conflict to keep");
        for conflict in conflicts.iter() {
            expect!(
                fs::read(&conflict.path).is_ok_and(|bytes| bytes == conflict.bytes),
                "{} to be left as it was",
                conflict.path.display()
            );
        }
        Ok(())
    })
}

fn action_for(step: &str) -> &'static str {
    match step {
        "install the KDE Plasma capture helper" => "install-kde-helper",
        "install the Hyprland capture helper" => "install-hyprland-helper",
        "install the GNOME extension" => "install-extension",
        "allow screen recording the way macOS does" => "allow-screen-recording",
        _ => "test-mac-capture",
    }
}

fn current() -> Kind {
    if KDE_SCENARIO.get() {
        Kind::Kde
    } else {
        Kind::Hyprland
    }
}

fn enable(world: &mut World) -> Outcome {
    set_setting(world, "snapShotEnabled", json!(true))
}

fn draft_images(world: &World) -> Vec<Value> {
    attachments(world, &thread_key(world))
}

fn wait_for_attached(world: &mut World) -> Outcome {
    world.wait_for_with(
        |w| !draft_images(w).is_empty(),
        |w| format!("the capture attached; Snap Shot is {}", describe(w)),
    )
}

/// The helper installed and Hyprland's shortcuts through the portal,
/// answering as `portal` says.
fn hyprland(world: &mut World, portal: PortalDesktop) -> Outcome {
    uninstall();
    install(Kind::Hyprland)?;
    {
        let bus = snap_shot_bus::bus();
        let mut bus = bus.borrow_mut();
        bus.reset();
        bus.desktop = portal;
    }
    KEEP_HELPER.set(true);
    let reset = reset_with(
        world,
        environment_of(Kind::Hyprland),
        Some(snap_shot_bus::factory()),
    );
    KEEP_HELPER.set(false);
    reset?;
    open_panel(world)?;
    enable(world)?;
    tell_in_place(world);
    Ok(())
}

pub fn register(steps: &mut Steps) {
    on_reset(reset);

    steps.step(
        "the user installed the capture helper during setup",
        |world, _, _| {
            desktop_with(world, Kind::Kde, "not installed")?;
            send(world, "enable", json!({"on": true}))?;
            wait_for_field(world, "wizard.action", json!("install-kde-helper"))?;
            send(
                world,
                "setup.action",
                json!({"action": "install-kde-helper"}),
            )?;
            wait_for_field(world, "wizard.action", json!(""))?;
            world.wait_for_with(
                |w| {
                    installed(Kind::Kde).exists() && field(w, "wizard.busy").as_bool() != Some(true)
                },
                |w| format!("the helper installed; Snap Shot is {}", describe(w)),
            )
        },
    );
    steps.step(
        "capture is off and the helper stays installed",
        |world, _, _| {
            expect!(
                setting(world, "snapShotEnabled").as_bool() != Some(true)
                    && installed(Kind::Kde).exists()
                    && entry().exists(),
                "capture off and the helper kept; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "Snap Shot is on but the capture helper is not installed",
        |world, _, _| {
            desktop_with(world, Kind::Kde, "not installed")?;
            enable(world)
        },
    );
    steps.step(
        "Snap Shot is on but the capture helper's access check failed",
        |world, _, _| {
            desktop_with(world, Kind::Kde, "failing")?;
            enable(world)
        },
    );
    steps.step(
        "a Linux session where (Hyprland|KDE Plasma) has its helper ready but no effects",
        |world, c, _| {
            desktop_with(world, kind_of(&c[0]), "ready")?;
            enable(world)
        },
    );
    steps.step(
        "a Linux session where (Hyprland|KDE Plasma) has no helper or an outdated one",
        |world, c, _| {
            desktop_with(world, kind_of(&c[0]), "not installed")?;
            enable(world)
        },
    );

    // The access step.
    steps.step(
        "a (KDE Plasma|Hyprland) session where the capture helper is (not installed|out of date|failing its check)",
        |world, c, _| desktop_with(world, kind_of(&c[0]), &c[1]),
    );
    steps.step(
        "setup offers \"Install the capture helper\"",
        |world, _, _| {
            expect!(
                field(world, "wizard.continueLabel") == "Install helper"
                    && text(&field(world, "wizard.action")).starts_with("install-"),
                "setup to offer installing; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "setup offers \"Update the capture helper\"",
        |world, _, _| {
            expect!(
                field(world, "wizard.continueLabel") == "Update helper"
                    && text(&field(world, "wizard.action")).starts_with("install-"),
                "setup to offer updating; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("setup offers \"Check again\"", |world, _, _| {
        expect!(
            field(world, "wizard.continueLabel") == "Check again"
                && text(&field(world, "wizard.action")).is_empty(),
            "setup to offer checking again; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "a KDE Plasma session where the capture helper fails its access check",
        |world, _, _| {
            desktop_with(world, Kind::Kde, "failing")?;
            send(world, "setup.open", Value::Null)
        },
    );
    steps.step("the user checks again and it still fails", |world, _, _| {
        send(world, "setup.continue", Value::Null)?;
        world.wait_for_with(
            |w| !text(&field(w, "wizard.checkMessage")).is_empty(),
            |w| format!("the check to be answered; Snap Shot is {}", describe(w)),
        )
    });
    steps.step(
        "suggests reinstalling the capture helper and checking again",
        |world, _, _| {
            let advanced = field(world, "wizard.advanced");
            let offered = advanced
                .get(0)
                .is_some_and(|o| o["label"] == "Reinstall helper");
            expect!(
                field(world, "wizard.body")
                    == "Try reinstalling the capture helper, then check again."
                    && offered,
                "setup to suggest reinstalling; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "a Hyprland session with the capture helper installed",
        |world, _, _| desktop_with(world, Kind::Hyprland, "ready"),
    );
    steps.step(
        "setup says the desktop may ask for permission when the user first captures",
        |world, _, _| {
            expect!(
                text(&field(world, "wizard.details"))
                    .contains("may ask for screen-sharing permission on your first capture"),
                "setup to warn about the first capture; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "a session whose capture helper was installed by setup",
        |world, _, _| {
            desktop_with(world, Kind::Hyprland, "ready")?;
            send(world, "setup.open", Value::Null)?;
            send(world, "setup.back", Value::Null)
        },
    );
    steps.step(
        "the user opens Advanced on the access step",
        |world, _, _| {
            expect!(
                field(world, "wizard.step") == "access",
                "the access step; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("they can remove the capture helper", |world, _, _| {
        let option = field(world, "wizard.advanced")
            .get(0)
            .cloned()
            .unwrap_or(Value::Null);
        expect!(
            option["action"] == "remove-hyprland-helper",
            "a way to remove the helper; it is {}",
            show(&option)
        );
        send(world, "setup.action", json!({"action": option["action"]}))?;
        world.wait_for_with(
            |_| !installed(Kind::Hyprland).exists(),
            |w| format!("the helper removed; Snap Shot is {}", describe(w)),
        )?;
        write(
            &scratch().path("note"),
            text(&option["note"]).as_bytes(),
            false,
        );
        Ok(())
    });
    steps.step(
        "the helper's own note says it is included with HAL-C2 and needs no download",
        |_, _, _| {
            let note = fs::read_to_string(scratch().path("note")).unwrap_or_default();
            expect!(
                note == "Included with HAL-C2. No download needed.",
                "the helper's note; it is {note}"
            );
            Ok(())
        },
    );

    steps.step(
        "a Linux Wayland session on (KDE Plasma|Hyprland)",
        |world, c, _| desktop_with(world, kind_of(&c[0]), "ready"),
    );

    // Hyprland's shortcut session.
    steps.step(
        "a Hyprland session where the binding is kept in the Hyprland config",
        |_, _, _| Ok(()),
    );
    steps.step(
        "HAL-C2 is still connecting to Hyprland's shortcuts",
        |world, _, _| {
            hyprland(
                world,
                PortalDesktop {
                    bind: Answer::Hold,
                    ..PortalDesktop::default()
                },
            )
        },
    );
    steps.step("Hyprland registers the capture action", |world, _, _| {
        hyprland(world, PortalDesktop::default())
    });
    steps.step(
        "Hyprland does not register the capture action",
        |world, _, _| {
            hyprland(
                world,
                PortalDesktop {
                    bind: Answer::Nothing,
                    ..PortalDesktop::default()
                },
            )
        },
    );
    steps.step(
        "Hyprland's shortcut session cannot be reached",
        |world, _, _| {
            hyprland(
                world,
                PortalDesktop {
                    session_fails: true,
                    ..PortalDesktop::default()
                },
            )
        },
    );
    steps.step(
        "the user asks for the shortcut permission",
        |world, _, _| {
            hyprland(world, PortalDesktop::default())?;
            wait_for_field(world, "shortcut.registered", json!(true))?;
            expect!(
                field(world, "shortcut.permissions").as_bool() != Some(true),
                "asking again not to be offered; Snap Shot is {}",
                describe(world)
            );
            send(world, "shortcut.permissions", Value::Null)
        },
    );
    steps.step(
        "the user is told to change the capture binding in the Hyprland config and save it",
        |world, _, _| {
            wait_for_field(
                world,
                "shortcut.status",
                json!("Change the capture binding in your Hyprland config, then save it."),
            )
        },
    );

    // What setup refuses to touch. "a Hyprland session" is
    // snap_shot_config.rs's; the helper it starts with is installed.
    steps.step("a KDE Plasma session", |world, _, _| {
        desktop_with(world, Kind::Kde, "ready")?;
        KDE_SCENARIO.set(true);
        Ok(())
    });
    steps.step("the helper or its launcher entry is a link", |_, _, _| {
        link_instead(&installed(current()))
    });
    steps.step("the helper is a link", |_, _, _| {
        link_instead(&installed(current()))
    });
    steps.step("the helper's folder is a link", |_, _, _| {
        let helper = installed(current());
        let folder = helper.parent().map(Path::to_owned).unwrap_or_default();
        let elsewhere = scratch().path("elsewhere-folder");
        let _ = fs::remove_dir_all(&elsewhere);
        let moved = fs::rename(&folder, &elsewhere);
        expect!(moved.is_ok(), "to move {}: {moved:?}", folder.display());
        let linked = link(&elsewhere, &folder);
        expect!(linked.is_ok(), "to link {}: {linked:?}", folder.display());
        let name = helper.file_name().map(Path::new).unwrap_or(Path::new(""));
        let bytes = fs::read(elsewhere.join(name));
        expect!(bytes.is_ok(), "the helper moved");
        CONFLICTS.with(|conflicts| {
            conflicts.borrow_mut().push(Conflict {
                path: helper.clone(),
                bytes: bytes.unwrap_or_default(),
            })
        });
        Ok(())
    });
    steps.step(
        "another program's launcher entry has the helper's name",
        |_, _, _| {
            let other = b"[Desktop Entry]\nType=Application\nName=Someone else\n";
            write(&entry(), other, false);
            CONFLICTS.with(|conflicts| {
                conflicts.borrow_mut().push(Conflict {
                    path: entry(),
                    bytes: other.to_vec(),
                })
            });
            Ok(())
        },
    );
    steps.step(
        "the user installs or removes the capture helper",
        |world, _, _| {
            let kind = current();
            load(world, environment_of(kind))?;
            wait_for_helper(world)?;
            world.told_in_place =
                Some(Rc::new(|w: &World| vec![text(&field(w, "wizard.details"))]));
            send(world, "setup.open", Value::Null)?;
            send(
                world,
                "setup.action",
                json!({"action": kind.remove_action()}),
            )?;
            wait_for_helper(world)?;
            send(
                world,
                "setup.action",
                json!({"action": kind.install_action()}),
            )?;
            wait_for_helper(world)
        },
    );

    steps.step(
        "the app was built without its capture helper",
        |world, _, _| {
            BUNDLE_MISSING.set(true);
            load(world, environment_of(current()))?;
            send(world, "setup.open", Value::Null)?;
            send(world, "setup.back", Value::Null)
        },
    );
    steps.step(
        "the user checks capture access or installs the helper",
        |world, _, _| {
            wait_for_helper(world)?;
            expect_wizard_tells(world, "missing from this build")?;
            uninstall();
            send(world, "setup.continue", Value::Null)?;
            wait_for_helper(world)?;
            send(
                world,
                "setup.action",
                json!({"action": current().install_action()}),
            )
        },
    );
    steps.step(
        "the user is told the helper is missing from this build and to update or reinstall HAL-C2",
        |world, _, _| {
            expect_wizard_tells(
                world,
                "missing from this build. Update or reinstall HAL-C2.",
            )?;
            expect!(!installed(current()).exists(), "nothing to be installed");
            Ok(())
        },
    );
    steps.step("KDE's service tools are not installed", |world, _, _| {
        uninstall();
        helper::set_tool_path(Some(vec![scratch().no_tools()]));
        load(world, environment_of(Kind::Kde))?;
        wait_for_helper(world)?;
        send(world, "setup.open", Value::Null)?;
        send(
            world,
            "setup.action",
            json!({"action": "install-kde-helper"}),
        )?;
        wait_for_helper(world)
    });
    steps.step(
        "KDE has not granted the helper screen capture access",
        |world, _, _| {
            set_mode("denied-kde");
            load(world, environment_of(Kind::Kde))?;
            wait_for_helper(world)?;
            send(world, "setup.open", Value::Null)
        },
    );
    steps.step("the helper does not answer a check", |world, _, _| {
        set_mode("silent");
        load(world, environment_of(Kind::Kde))?;
        wait_for_helper(world)?;
        send(world, "setup.open", Value::Null)
    });

    // Capturing.
    steps.step(
        "a KDE Plasma or Hyprland session where the capture helper is not ready",
        |world, _, _| {
            desktop_with(world, Kind::Kde, "not installed")?;
            enable(world)?;
            open_thread(world)
        },
    );
    steps.step(
        "the user is told what is missing and to open Settings, SnapShots to continue setup",
        |world, _, _| {
            expect_toast_containing(
                world,
                "Install the bundled helper to capture the window you're using without a picker. Open Settings → SnapShots to continue setup.",
            )
        },
    );
    steps.step(
        "the helper does not answer within twenty seconds",
        |world, _, _| {
            expect!(
                helper::TIMEOUT == Duration::from_secs(20),
                "the wait to be twenty seconds"
            );
            helper::set_timeout(Some(Duration::from_millis(200)));
            set_mode("hang");
            enable(world)?;
            open_thread(world)
        },
    );
    steps.step(
        "the user is told Hyprland capture did not respond and to check capture setup and try again",
        |world, _, _| {
            expect_toast_containing(
                world,
                "Hyprland capture did not respond. Check capture setup and try again.",
            )
        },
    );

    // Setup only writes what it was asked to.
    steps.step("a KDE Plasma or Hyprland session", |world, _, _| {
        desktop_with(world, Kind::Kde, "not installed")
    });
    steps.step(
        "the user checks capture access without choosing to install",
        |world, _, _| {
            send(world, "setup.open", Value::Null)?;
            send(world, "setup.continue", Value::Null)?;
            wait_for_helper(world)
        },
    );
    steps.step("nothing is written to the user's files", |_, _, _| {
        expect!(
            !scratch().data_home().exists(),
            "no files before installing"
        );
        Ok(())
    });
    steps.step(
        "files are written only after the user chooses to install the helper",
        |world, _, _| {
            send(
                world,
                "setup.action",
                json!({"action": "install-kde-helper"}),
            )?;
            world.wait_for_with(
                |w| {
                    installed(Kind::Kde).exists()
                        && entry().exists()
                        && field(w, "checking").as_bool() != Some(true)
                },
                |w| format!("the helper installed; Snap Shot is {}", describe(w)),
            )?;
            expect!(
                fs::read(entry()).is_ok() && runs(&installed(Kind::Kde)),
                "the installed helper to run"
            );
            Ok(())
        },
    );

    // source-control/snap-shot.feature.
    steps.step(
        "a Hyprland session whose capture helper fails",
        |world, _, _| {
            desktop_with(world, Kind::Hyprland, "ready")?;
            enable(world)?;
            open_thread(world)?;
            set_mode("denied-capture");
            Ok(())
        },
    );
    steps.step(
        "the capture fails and no other capture method is tried",
        |world, _, _| {
            expect_toast_containing(world, "Hyprland denied screen capture")?;
            expect!(draft_images(world).is_empty(), "nothing attached");
            expect!(field(world, "backend") != "picker", "no picker");
            Ok(())
        },
    );
    steps.step(
        "capture works through the capture helper(?: and a Hyprland binding)?",
        |world, _, _| {
            let before = calls().len();
            enable(world)?;
            open_thread(world)?;
            capture(world)?;
            wait_for_attached(world)?;
            let calls = calls();
            expect!(
                calls[before.min(calls.len())..]
                    .join(" ")
                    .contains("capture"),
                "the helper to capture; it was called {}",
                calls.join(", ")
            );
            Ok(())
        },
    );
    steps.step(
        "Hyprland refuses screen capture to HAL-C2",
        |world, _, _| {
            desktop_with(world, Kind::Hyprland, "ready")?;
            enable(world)?;
            open_thread(world)?;
            set_mode("denied-capture");
            Ok(())
        },
    );
    steps.step(
        "the user is shown the capture was denied and how to allow it",
        |world, _, _| {
            expect_toast_containing(
                world,
                "Hyprland denied screen capture. Allow HAL-C2 in the screen-sharing prompt, then try again.",
            )
        },
    );
    steps.step(
        "the flash and animation are on and the desktop's capture helper cannot show them",
        |world, _, _| {
            desktop_with(world, Kind::Hyprland, "ready")?;
            set_setting(world, "snapShotFlash", json!(true))?;
            enable(world)?;
            set_setting(world, "snapShotAnimations", json!(true))?;
            open_thread(world)
        },
    );
    steps.step(
        "the image is attached without waiting for the effects",
        |world, _, _| wait_for_attached(world),
    );
    steps.step("the capture is not reported as failed", |world, _, _| {
        for toast in world.state("toasts")["items"]
            .as_array()
            .into_iter()
            .flatten()
        {
            expect!(toast["type"] != "error", "no failure; {}", show(toast));
        }
        Ok(())
    });
}

#[cfg(unix)]
fn runs(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path).is_ok_and(|info| info.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn runs(path: &Path) -> bool {
    path.is_file()
}

// The GNOME scenarios share these words (snap_shot_gnome.rs holds the steps).

/// The shell captures through a capture helper.
pub(crate) fn helper_in_use(world: &World) -> bool {
    field(world, "backend") == "helper"
}

pub(crate) fn helper_conflicts_kept() -> Outcome {
    expect_conflicts_kept()
}

/// A KDE Plasma session with no helper, its setup open.
pub(crate) fn helper_on_kde(world: &mut World) -> Outcome {
    uninstall();
    load(world, environment_named("KDE"))?;
    send(world, "setup.open", Value::Null)?;
    tell_in_place(world);
    Ok(())
}

pub(crate) fn helper_nothing_installed() -> Outcome {
    expect!(!scratch().data_home().exists(), "nothing installed");
    Ok(())
}

/// The setup action a feature names.
pub(crate) fn setup_action(step: &str) -> &'static str {
    action_for(step)
}

/// No helper installed, on a fresh KDE Plasma desktop (the leader's
/// "setup is not finished on KDE Plasma").
#[allow(dead_code)]
pub(crate) fn uninstall_capture_helpers(world: &mut World) -> Outcome {
    uninstall();
    load(world, environment_of(Kind::Kde))
}
