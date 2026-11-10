//! The capture shortcut kept in the compositor's config, and Niri capture
//! (desktop-qt's SnapShotConfigSteps.cpp; features/settings/snap-shot.feature,
//! source-control/snap-shot.feature): the SnapShot controller and
//! [`config`] on real files in a scratch HOME under the target's tmp, with
//! `niri` and `hyprctl` stood in for. Niri capture is the Niri backend
//! itself, on a fake IPC socket and a dbus-daemon of the test's own.

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Write as _};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use hal_c2_shell::controllers::navigation::{Navigation, Route};
use hal_c2_shell::controllers::snap_shot::{SnapShot, deliver};
use hal_c2_shell::snap_shot::config::{self, HyprlandBind, NIRI_INTERFACE, NIRI_PATH, Tools};
use hal_c2_shell::snap_shot::{self, Backend, Event, Platform, Session, Shortcut, niri};
use serde_json::{Value, json};
use zbus::blocking::Connection;
use zbus::blocking::connection::Builder;
use zbus::fdo::RequestNameFlags;

use super::snap_shot::{
    ALT, CONTROL, Desktop, SECTION, SHIFT, attached, attachments, capture, desktop, field,
    open_thread, page, reset_with, send, set_setting, thread_key, toast_saying, update,
};
use crate::expect;
use crate::harness::{Outcome, Q, Steps, show, text};
use crate::world::World;

const KEY_K: i64 = 0x4b;
const KEY_EXCLAM: i64 = 0x21;
const KEY_NUMBER_SIGN: i64 = 0x23;
const KEY_COMMA: i64 = 0x2c;
/// The endpoint's bus name.
const NAME: &str = "hal-c2.SnapShot";
const UNPREPARED: &str = "Couldn't prepare the changes. Check Advanced for help.";
const NO_RELOAD: &str = "Config saved, but Hyprland couldn't reload it. Run hyprctl reload.";

// --- `niri` and `hyprctl` ----------------------------------------------------------

/// What `niri` and `hyprctl` answer, and what they were asked. The config's
/// tools run on its thread, so this is shared.
struct Compositor {
    niri_valid: bool,
    binds: Option<Vec<HyprlandBind>>,
    reload: String,
    validated: Vec<String>,
    reloads: usize,
    /// A step holds the tool until it has looked at the panel.
    hold: bool,
    waiting: usize,
    released: usize,
}

static COMPOSITOR: Mutex<Compositor> = Mutex::new(Compositor {
    niri_valid: true,
    binds: Some(Vec::new()),
    reload: String::new(),
    validated: Vec::new(),
    reloads: 0,
    hold: false,
    waiting: 0,
    released: 0,
});
static SIGNAL: Condvar = Condvar::new();
const HOLD_LIMIT: Duration = Duration::from_secs(10);

fn compositor() -> MutexGuard<'static, Compositor> {
    COMPOSITOR.lock().unwrap_or_else(|e| e.into_inner())
}

fn reset_compositor() {
    *compositor() = Compositor {
        niri_valid: true,
        binds: Some(Vec::new()),
        reload: String::new(),
        validated: Vec::new(),
        reloads: 0,
        hold: false,
        waiting: 0,
        released: 0,
    };
}

/// On the config's thread: waits while a step holds the tools.
fn held() {
    let mut c = compositor();
    if !c.hold {
        return;
    }
    c.waiting += 1;
    SIGNAL.notify_all();
    let deadline = Instant::now() + HOLD_LIMIT;
    while c.hold && c.released == 0 {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        c = SIGNAL
            .wait_timeout(c, left)
            .unwrap_or_else(|e| e.into_inner())
            .0;
    }
    c.released = c.released.saturating_sub(1);
}

/// Waits for the config's thread to be held in a tool.
fn wait_held() -> Outcome {
    let mut c = compositor();
    let deadline = Instant::now() + HOLD_LIMIT;
    while c.waiting == 0 {
        let left = deadline.saturating_duration_since(Instant::now());
        expect!(!left.is_zero(), "the config's thread to ask the compositor");
        c = SIGNAL
            .wait_timeout(c, left)
            .unwrap_or_else(|e| e.into_inner())
            .0;
    }
    c.waiting -= 1;
    Ok(())
}

/// Lets the held tool answer.
fn release() {
    let mut c = compositor();
    c.hold = false;
    c.released += 1;
    SIGNAL.notify_all();
}

fn tools() -> Tools {
    Tools {
        validate_niri: Arc::new(|path: &str| {
            held();
            let mut c = compositor();
            c.validated.push(path.to_owned());
            c.niri_valid
        }),
        hyprland_bindings: Arc::new(|| {
            held();
            compositor().binds.clone()
        }),
        reload_hyprland: Arc::new(|| {
            let mut c = compositor();
            c.reloads += 1;
            c.reload.clone()
        }),
    }
}

// --- Niri's IPC socket ---------------------------------------------------------------

#[derive(Default)]
struct NiriState {
    version: String,
    focused: bool,
    shots: usize,
    stream: Option<UnixStream>,
}

/// Niri's IPC: one JSON line in, one out, and the event stream.
struct NiriServer {
    folder: PathBuf,
    socket: PathBuf,
    stop: Arc<AtomicBool>,
    state: Arc<Mutex<NiriState>>,
}

impl NiriServer {
    fn start(version: &str) -> Result<NiriServer, String> {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        // A socket's path has a length limit the target's tmp passes.
        let runtime = std::env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .filter(|dir| dir.is_absolute())
            .unwrap_or_else(std::env::temp_dir);
        let folder = runtime.join(format!(
            "hal-c2-niri-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&folder);
        fs::create_dir_all(&folder).map_err(|e| format!("cannot make {folder:?}: {e}"))?;
        let socket = folder.join("s");
        let listener =
            UnixListener::bind(&socket).map_err(|e| format!("cannot listen as Niri: {e}"))?;
        let stop = Arc::new(AtomicBool::new(false));
        let state = Arc::new(Mutex::new(NiriState {
            version: version.to_owned(),
            focused: true,
            ..NiriState::default()
        }));
        let (stopping, serving) = (stop.clone(), state.clone());
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                if stopping.load(Ordering::Relaxed) {
                    break;
                }
                let Ok(stream) = stream else { break };
                let state = serving.clone();
                std::thread::spawn(move || serve(stream, &state));
            }
        });
        Ok(NiriServer {
            folder,
            socket,
            stop,
            state,
        })
    }

    fn state(&self) -> std::sync::MutexGuard<'_, NiriState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl Drop for NiriServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        // Wakes the accepting thread to see it.
        let _ = UnixStream::connect(&self.socket);
        let _ = fs::remove_dir_all(&self.folder);
    }
}

fn serve(stream: UnixStream, state: &Mutex<NiriState>) {
    let Ok(reading) = stream.try_clone() else {
        return;
    };
    let mut writer = stream;
    let lock = || state.lock().unwrap_or_else(|e| e.into_inner());
    let window = json!({"id": 7, "pid": 70, "app_id": "firefox", "title": "Docs"});
    for line in BufReader::new(reading).lines() {
        let Ok(line) = line else { return };
        let Ok(request) = serde_json::from_str::<Value>(&line) else {
            return;
        };
        let reply = |writer: &mut UnixStream, ok: Value| {
            let _ = writer.write_all(format!("{}\n", json!({"Ok": ok})).as_bytes());
        };
        if request == "Version" {
            let version = lock().version.clone();
            reply(&mut writer, json!({"Version": version}));
        } else if request == "EventStream" {
            let _ =
                writer.write_all(b"{\"Ok\":\"Handled\"}\n{\"WindowsChanged\":{\"windows\":[]}}\n");
            lock().stream = writer.try_clone().ok();
        } else if request == "FocusedWindow" {
            let focused = lock().focused;
            let window = if focused { window.clone() } else { Value::Null };
            reply(&mut writer, json!({"FocusedWindow": window}));
        } else if request == "Windows" {
            reply(&mut writer, json!({"Windows": [window.clone()]}));
        } else if request.is_object() {
            let path = text(&request["Action"]["ScreenshotWindow"]["path"]);
            let image = image::RgbaImage::from_pixel(32, 20, image::Rgba([0, 100, 0, 255]));
            let _ = image.save_with_format(&path, image::ImageFormat::Png);
            let mut state = lock();
            state.shots += 1;
            reply(&mut writer, json!({"Handled": true}));
            if let Some(stream) = &mut state.stream {
                let event = json!({"ScreenshotCaptured": {"path": path}});
                let _ = stream.write_all(format!("{event}\n").as_bytes());
            }
        }
    }
}

// --- The test's session bus ------------------------------------------------------------

/// A dbus-daemon of the test's own, stopped by the PID it was started with.
struct Bus {
    daemon: Child,
    address: String,
}

impl Bus {
    fn start(home: &Path) -> Result<Bus, String> {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let config = home.join("bus.conf");
        // Abstract, so no socket file; named for this process, so no other
        // bus is it.
        let socket = format!(
            "hal-c2-niri-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        fs::write(
            &config,
            format!(
                r#"<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:abstract={socket}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
"#
            ),
        )
        .map_err(|e| format!("cannot write {config:?}: {e}"))?;
        let mut daemon = Command::new("dbus-daemon")
            .arg(format!("--config-file={}", config.display()))
            .args(["--nofork", "--print-address"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .spawn()
            .map_err(|e| format!("cannot start dbus-daemon: {e}"))?;
        // Printed once it listens.
        let mut address = String::new();
        if let Some(out) = daemon.stdout.take() {
            let _ = BufReader::new(out).read_line(&mut address);
        }
        Ok(Bus {
            daemon,
            address: address.trim().to_owned(),
        })
    }

    fn connect(&self) -> Result<Connection, String> {
        Builder::address(self.address.as_str())
            .and_then(Builder::build)
            .map_err(|e| format!("cannot reach the test's bus: {e}"))
    }
}

impl Drop for Bus {
    fn drop(&mut self) {
        let _ = self.daemon.kill();
        let _ = self.daemon.wait();
    }
}

/// The Niri backend, also hearing the fake desktop's presses: the Snap Shot
/// shortcut of the shared steps is the fake saying so.
struct Pressed {
    inner: Box<dyn Backend>,
    desktop: Rc<RefCell<Desktop>>,
}

impl Backend for Pressed {
    fn session(&self) -> Session {
        self.inner.session()
    }

    fn shortcut(&self) -> Shortcut {
        self.inner.shortcut()
    }

    fn probe(&mut self) -> Vec<Event> {
        self.inner.probe()
    }

    fn capture(&mut self) -> Vec<Event> {
        self.inner.capture()
    }

    fn arrive(&mut self) -> Vec<Event> {
        let mut events = std::mem::take(&mut self.desktop.borrow_mut().arrivals);
        events.extend(self.inner.arrive());
        events
    }
}

// --- The scene -------------------------------------------------------------------------

/// The scratch home, and the file a scenario reviews.
#[derive(Default)]
struct Scene {
    home: PathBuf,
    file: PathBuf,
    before: Vec<u8>,
    chosen: PathBuf,
    stale_id: String,
    backup: String,
    niri: Option<NiriServer>,
    bus: Option<Bus>,
    endpoint_error: String,
}

impl Drop for Scene {
    fn drop(&mut self) {
        scrub(&self.home);
    }
}

fn scene(world: &mut World) -> &mut Scene {
    world.part::<Scene>()
}

fn shots(world: &mut World) -> usize {
    scene(world)
        .niri
        .as_ref()
        .map_or(0, |niri| niri.state().shots)
}

/// Removes a scratch home, unreadable files and all.
fn scrub(path: &Path) {
    if path.as_os_str().is_empty() {
        return;
    }
    fn open_up(path: &Path) {
        let Ok(meta) = fs::symlink_metadata(path) else {
            return;
        };
        if meta.file_type().is_symlink() {
            return;
        }
        let mode = if meta.is_dir() { 0o700 } else { 0o600 };
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(mode));
        if meta.is_dir()
            && let Ok(entries) = fs::read_dir(path)
        {
            for entry in entries.flatten() {
                open_up(&entry.path());
            }
        }
    }
    open_up(path);
    let _ = fs::remove_dir_all(path);
}

/// A fresh scratch home under the target's tmp, never the real one.
fn fresh_home(world: &mut World) -> Result<PathBuf, String> {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let old = std::mem::take(&mut scene(world).home);
    scrub(&old);
    let home = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
        .join("snap-niri-home")
        .join(format!(
            "{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
    scrub(&home);
    fs::create_dir_all(home.join(".config")).map_err(|e| format!("cannot make {home:?}: {e}"))?;
    Ok(home)
}

fn environment_for(home: &Path, desktop: &str) -> HashMap<String, String> {
    HashMap::from([
        ("XDG_SESSION_TYPE".to_owned(), "wayland".to_owned()),
        ("XDG_CURRENT_DESKTOP".to_owned(), desktop.to_owned()),
        ("HOME".to_owned(), home.display().to_string()),
        (
            "XDG_CONFIG_HOME".to_owned(),
            home.join(".config").display().to_string(),
        ),
    ])
}

fn write(path: &Path, bytes: &[u8]) -> Outcome {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("cannot make {parent:?}: {e}"))?;
    }
    if path.exists() {
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    fs::write(path, bytes).map_err(|e| format!("cannot write {path:?}: {e}"))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("cannot set {path:?}'s mode: {e}"))?;
    Ok(())
}

fn read(path: &Path) -> Vec<u8> {
    fs::read(path).unwrap_or_default()
}

fn contains(path: &Path, needle: &str) -> bool {
    String::from_utf8_lossy(&read(path)).contains(needle)
}

fn shown(path: &Path) -> String {
    String::from_utf8_lossy(&read(path)).into_owned()
}

fn chmod(path: &Path, mode: u32) {
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(mode));
}

fn describe(world: &World) -> String {
    show(&page(world))
}

fn folder(world: &mut World) -> PathBuf {
    let file = scene(world).file.clone();
    file.parent().map(Path::to_path_buf).unwrap_or_default()
}

/// A session of `kind` (niri, hyprland) with an ordinary config, Snap Shot
/// on, in setup's shortcut step.
fn open(world: &mut World, kind: &str, hold_bind: bool) -> Outcome {
    reset_compositor();
    let home = fresh_home(world)?;
    let env = environment_for(&home, kind);
    let lookup = |name: &str| env.get(name).cloned();
    let niri = kind == "niri";
    let file = PathBuf::from(if niri {
        config::niri_config_path(&lookup)
    } else {
        config::hyprland_config_path(&lookup)
    });
    let before: &[u8] = if niri {
        b"binds {\n    Mod+T { spawn \"foot\"; }\n}\n"
    } else {
        b"bind = SUPER, T, exec, foot\n"
    };
    write(&file, before)?;
    {
        let scene = scene(world);
        scene.niri = None;
        scene.bus = None;
        scene.home = home;
        scene.file = file;
        scene.before = before.to_vec();
        scene.chosen = PathBuf::new();
        scene.stale_id.clear();
        scene.backup.clear();
    }
    reset_with(world, env, None)?;
    world.with::<SnapShot, _>(|c, _| c.set_config_tools(Some(tools())))?;
    if hold_bind {
        desktop(world).borrow_mut().hold_shortcuts = true;
    }
    set_setting(world, "snapShotEnabled", json!(true))?;
    open_panel(world)?;
    send(world, "setup.open", json!({"step": "shortcut"}))?;
    world.told_in_place = Some(Rc::new(|w: &World| {
        [
            "config.error",
            "config.details",
            "config.intro",
            "shortcut.status",
        ]
        .iter()
        .map(|path| text(&field(w, path)))
        .collect()
    }));
    Ok(())
}

/// Settings, SnapShots, once the backend says it is ready.
fn open_panel(world: &mut World) -> Outcome {
    world.with::<Navigation, _>(|navigation, engine| {
        navigation.open(engine, Route::Settings(SECTION.to_owned()))
    })?;
    world.wait_for_with(
        |w| {
            deliver(w.engine());
            field(w, "ready") == true
        },
        |w| format!("Snap Shot to be ready; it is {}", describe(w)),
    )
}

/// Waits, handing the shell what the backend's threads left, until `holds`.
fn wait(world: &mut World, what: &str, holds: impl Fn(&World) -> bool) -> Outcome {
    world.wait_for_with(
        |w| {
            deliver(w.engine());
            holds(w)
        },
        |w| format!("{what}; Snap Shot is {}", describe(w)),
    )
}

/// The config's thread has answered.
fn settle(world: &mut World) -> Outcome {
    wait(world, "the config change to settle", |w| {
        field(w, "config.canReview") == true
            || !field(w, "config.review").is_null()
            || field(w, "config").is_null()
    })?;
    wait(world, "the config change to finish", |w| {
        field(w, "config.reviewLabel") == "Review changes"
            && !text(&field(w, "config.review.saveLabel")).ends_with('…')
    })
}

fn review(world: &mut World, payload: Value) -> Outcome {
    send(world, "config.review", payload)?;
    settle(world)
}

fn reviewed(world: &mut World) -> Outcome {
    review(world, json!({}))?;
    expect!(
        field(world, "config.review.changed") == true,
        "a diff; Snap Shot is {}",
        describe(world)
    );
    Ok(())
}

fn config_save(world: &mut World) -> Outcome {
    send(world, "config.save", json!({}))?;
    settle(world)?;
    let backup = text(&field(world, "config.backup"));
    if !backup.is_empty() {
        scene(world).backup = backup;
    }
    Ok(())
}

fn expect_unchanged(world: &mut World) -> Outcome {
    let (file, before) = {
        let scene = scene(world);
        (scene.file.clone(), scene.before.clone())
    };
    if fs::File::open(&file).is_err() {
        chmod(&file, 0o600);
    }
    expect!(
        read(&file) == before,
        "the config not to change; it holds {}; Snap Shot is {}",
        shown(&file),
        describe(world)
    );
    Ok(())
}

fn expect_details(world: &World, reason: &str) -> Outcome {
    expect!(
        field(world, "config.details") == reason,
        "the reason \"{reason}\"; Snap Shot is {}",
        describe(world)
    );
    Ok(())
}

fn details_contain(world: &World, part: &str) -> Outcome {
    expect!(
        text(&field(world, "config.details")).contains(part),
        "a reason saying \"{part}\"; Snap Shot is {}",
        describe(world)
    );
    Ok(())
}

fn diff_text(world: &World, kind: &str) -> String {
    field(world, "config.review.lines")
        .as_array()
        .into_iter()
        .flatten()
        .filter(|line| line["kind"] == kind)
        .map(|line| text(&line["text"]))
        .collect::<Vec<_>>()
        .join("\n")
}

fn press(world: &mut World, key: i64, modifiers: i64) -> Outcome {
    super::snap_shot::press(world, key, modifiers)
}

fn record(world: &mut World, key: i64, modifiers: i64) -> Outcome {
    send(world, "record.start", Value::Null)?;
    press(world, key, modifiers)
}

fn wizard_on_shortcut(world: &World) -> bool {
    field(world, "wizard.step") == "shortcut"
}

/// Writes the scenario's config as `bytes`, and remembers it.
fn rewrite(world: &mut World, bytes: &[u8]) -> Outcome {
    let file = scene(world).file.clone();
    write(&file, bytes)?;
    scene(world).before = bytes.to_vec();
    Ok(())
}

/// Reviews against `path`, which the scenario chose.
fn choose(world: &mut World, path: PathBuf, bytes: &[u8]) -> Outcome {
    write(&path, bytes)?;
    let chosen = path.display().to_string();
    scene(world).chosen = path;
    send(world, "config.review", json!({"file": chosen}))
}

/// A Niri session of `version` with its endpoint on the test's own bus,
/// Settings, SnapShots open; another HAL-C2 holds the endpoint's name while
/// it starts when `take_name`.
fn open_niri(world: &mut World, version: &str, take_name: bool) -> Outcome {
    reset_compositor();
    let home = fresh_home(world)?;
    let server = NiriServer::start(version)?;
    let bus = Bus::start(&home)?;
    let mut env = environment_for(&home, "niri");
    {
        let scene = scene(world);
        scene.niri = None;
        scene.bus = None;
        scene.home = home.clone();
        scene.file = PathBuf::new();
        scene.endpoint_error.clear();
    }
    // The fake portal first, then Niri over it, so the shared steps' presses reach it.
    reset_with(world, env.clone(), None)?;
    world.with::<SnapShot, _>(|c, _| c.set_config_tools(Some(tools())))?;
    let other = bus.connect()?;
    if take_name {
        other
            .request_name_with_flags(NAME, RequestNameFlags::DoNotQueue.into())
            .map_err(|e| format!("cannot hold the endpoint's name: {e}"))?;
    }
    env.insert("NIRI_SOCKET".into(), server.socket.display().to_string());
    env.insert("DBUS_SESSION_BUS_ADDRESS".into(), bus.address.clone());
    let runtime = home.join("run");
    fs::create_dir_all(&runtime).map_err(|e| format!("cannot make {runtime:?}: {e}"))?;
    env.insert("XDG_RUNTIME_DIR".into(), runtime.display().to_string());
    snap_shot::set_environment(Some(env));
    let platform = Platform {
        portal: true,
        desktop: "niri".into(),
        message: String::new(),
        sandboxed: false,
    };
    let inner = niri::create(&platform).ok_or("no Niri backend for the socket")?;
    let backend = Box::new(Pressed {
        inner,
        desktop: desktop(world),
    });
    world.with::<SnapShot, _>(|c, engine| c.set_backend(engine, backend))?;
    {
        let scene = scene(world);
        scene.niri = Some(server);
        scene.bus = Some(bus);
    }
    set_setting(world, "snapShotEnabled", json!(true))?;
    open_panel(world)?;
    if take_name {
        let _ = other.release_name(NAME);
    }
    Ok(())
}

fn expect_toast(world: &mut World, title: &str, description: &str) -> Outcome {
    wait(
        world,
        &format!("the toast \"{title}\": {description}"),
        |w| toast_saying(w, description).is_some_and(|toast| text(&toast["title"]) == title),
    )
}

pub fn register(steps: &mut Steps) {
    sessions(steps);
    review_steps(steps);
    saving(steps);
    refusals(steps);
    busy(steps);
    niri_steps(steps);
}

fn sessions(steps: &mut Steps) {
    steps.step("a Niri or Hyprland session", |world, _, _| {
        open(world, "niri", false)
    });
    steps.step(
        "a Niri or Hyprland session with a saved shortcut",
        |world, _, _| {
            open(world, "hyprland", false)?;
            reviewed(world)?;
            config_save(world)?;
            send(world, "setup.open", json!({"step": "shortcut"}))?;
            let file = scene(world).file.clone();
            scene(world).before = read(&file);
            Ok(())
        },
    );
    // Its tool waits, so a step can see what shows while it runs.
    steps.step("a Hyprland session", |world, _, _| {
        open(world, "hyprland", false)?;
        compositor().hold = true;
        Ok(())
    });
    steps.step(
        "a Niri or Hyprland session where HAL-C2 keeps the binding in the compositor config",
        |world, _, _| {
            open(world, "niri", false)?;
            send(world, "setup.close", json!({"completed": true}))
        },
    );
    steps.step(&format!("the shortcut row offers {Q}"), |world, c, _| {
        expect!(
            field(world, "shortcut.keys") == c[0].as_str()
                && field(world, "shortcut.managed") == true,
            "the row to offer {}; Snap Shot is {}",
            c[0],
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "choosing it opens setup at the shortcut step",
        |world, _, _| {
            send(world, "setup.open", json!({"step": "shortcut"}))?;
            expect!(
                wizard_on_shortcut(world),
                "the shortcut step; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
}

fn review_steps(steps: &mut Steps) {
    steps.step(
        "the user records a shortcut and chooses Review changes",
        |world, _, _| {
            record(world, KEY_K, CONTROL | ALT)?;
            review(world, json!({}))
        },
    );
    steps.step(
        &format!("the config's changes are shown as a diff with {Q}"),
        |world, c, _| {
            expect!(
                field(world, "config.review.note") == c[0].as_str()
                    && diff_text(world, "added").contains("Ctrl+Alt+K"),
                "the diff and {}; Snap Shot is {}",
                c[0],
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "nothing is written until the user chooses Save shortcut",
        |world, _, _| {
            expect_unchanged(world)?;
            expect!(
                field(world, "config.review.saveLabel") == "Save shortcut",
                "Save shortcut; Snap Shot is {}",
                describe(world)
            );
            config_save(world)?;
            let file = scene(world).file.clone();
            expect!(
                contains(&file, "Ctrl+Alt+K"),
                "the file to gain the binding: {}; Snap Shot is {}",
                shown(&file),
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the user chooses Review changes", |world, _, _| {
        if compositor().hold {
            send(world, "config.review", json!({}))?;
            return wait_held();
        }
        review(world, json!({}))
    });
    steps.step(
        &format!("the button reads {Q} until the proposal arrives"),
        |world, c, _| {
            expect!(
                field(world, "config.reviewLabel") == c[0].as_str()
                    && field(world, "config.canReview") != true,
                "{}; Snap Shot is {}",
                c[0],
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the desktop cannot prepare the changes", |world, _, _| {
        compositor().binds = None;
        release();
        settle(world)
    });
    steps.step("the technical reason is under Advanced", |world, _, _| {
        expect!(
            !text(&field(world, "config.details")).is_empty(),
            "a reason; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the user can try the review again", |world, _, _| {
        expect!(
            field(world, "config.canReview") == true,
            "Review changes to be offered; Snap Shot is {}",
            describe(world)
        );
        compositor().binds = Some(Vec::new());
        reviewed(world)
    });
    steps.step(
        "the user is reviewing a diff for the shortcut Ctrl\\+Shift\\+1",
        |world, _, _| {
            open(world, "niri", false)?;
            record(world, KEY_EXCLAM, CONTROL | SHIFT)?;
            reviewed(world)
        },
    );
    steps.step("the user records Ctrl\\+Shift\\+3", |world, _, _| {
        record(world, KEY_NUMBER_SIGN, CONTROL | SHIFT)
    });
    steps.step(
        "the old diff is withdrawn and the user reviews again",
        |world, _, _| {
            expect!(
                field(world, "config.review").is_null(),
                "no diff; Snap Shot is {}",
                describe(world)
            );
            reviewed(world)?;
            expect!(
                diff_text(world, "added").contains("Ctrl+Shift+3"),
                "the new keys; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the user is reviewing a diff", |world, _, _| {
        open(world, "niri", false)?;
        reviewed(world)?;
        world.answer_question = Some(Rc::new(|w: &mut World, _| {
            send(w, "config.cancel", json!({}))
        }));
        Ok(())
    });
    steps.step(
        "the config is not written and setup is not finished",
        |world, _, _| {
            expect_unchanged(world)?;
            expect!(
                wizard_on_shortcut(world) && field(world, "config.review").is_null(),
                "setup still open, no diff; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the config already holds the shortcut", |world, _, _| {
        open(world, "niri", false)?;
        reviewed(world)?;
        config_save(world)?;
        send(world, "setup.open", json!({"step": "shortcut"}))?;
        let file = scene(world).file.clone();
        scene(world).before = read(&file);
        Ok(())
    });
    steps.step("the user reviews changes", |world, _, _| {
        review(world, json!({}))
    });
    steps.step("the user can choose Done", |world, _, _| {
        expect_unchanged(world)?;
        expect!(
            field(world, "wizard.doneEnabled") == true,
            "Done; Snap Shot is {}",
            describe(world)
        );
        send(world, "setup.done", json!({}))?;
        expect!(
            field(world, "wizard").is_null(),
            "setup closed; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
}

fn saving(steps: &mut Steps) {
    steps.step("the user reviewed a diff and saves it", |world, _, _| {
        open(world, "hyprland", false)?;
        reviewed(world)
    });
    steps.step(
        "the config is written and the desktop reloaded",
        |world, _, _| {
            config_save(world)?;
            let file = scene(world).file.clone();
            let reloads = compositor().reloads;
            expect!(
                contains(&file, "global, hal-c2") && reloads == 1,
                "the binding and a reload ({reloads}): {}; Snap Shot is {}",
                shown(&file),
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user is told \"Shortcut saved\" and to use the shortcut from another app",
        |world, _, _| {
            expect_toast(
                world,
                "Shortcut saved",
                "Use Ctrl+Shift+2 from another app.",
            )
        },
    );
    steps.step("setup closes", |world, _, _| {
        expect!(
            field(world, "wizard").is_null(),
            "setup closed; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the config is written but the desktop could not reload",
        |world, _, _| {
            compositor().reload = NO_RELOAD.into();
            config_save(world)
        },
    );
    steps.step("setup does not finish", |world, _, _| {
        expect!(
            wizard_on_shortcut(world) && field(world, "wizard.doneEnabled") != true,
            "setup open and unfinished; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the write fails", |world, _, _| {
        // The file the review read has changed, so nothing may be written.
        let mut edited = scene(world).before.clone();
        edited.extend_from_slice(b"# edited\n");
        rewrite(world, &edited)?;
        config_save(world)?;
        expect_unchanged(world)
    });
    steps.step("the old diff is withdrawn", |world, _, _| {
        expect!(
            field(world, "config.review").is_null(),
            "no diff; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user chooses Remove shortcut under Advanced and reviews the change",
        |world, _, _| review(world, json!({"remove": true})),
    );
    steps.step("the diff removes only HAL-C2's binding", |world, _, _| {
        let removed = diff_text(world, "removed");
        expect!(
            diff_text(world, "added").is_empty()
                && removed.contains("global, hal-c2")
                && !removed.contains("foot"),
            "only the binding removed; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(&format!("saving says {Q}"), |world, c, _| {
        config_save(world)?;
        expect!(
            field(world, "config.intro") == c[0].as_str(),
            "{}; Snap Shot is {}",
            c[0],
            describe(world)
        );
        let file = scene(world).file.clone();
        expect!(
            !contains(&file, "hal-c2"),
            "the binding gone: {}",
            shown(&file)
        );
        Ok(())
    });
    steps.step(
        &format!("with no binding to remove the user is told {Q}"),
        |world, c, _| {
            review(world, json!({"remove": true}))?;
            expect!(
                field(world, "config.intro") == c[0].as_str(),
                "{}; Snap Shot is {}",
                c[0],
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user opens Advanced and chooses a different file",
        |world, _, _| {
            let (home, before) = {
                let scene = scene(world);
                (scene.home.clone(), scene.before.clone())
            };
            let real = home.join("dotfiles/niri.kdl");
            write(&real, &before)?;
            let chosen = home.join(".config/mine.kdl");
            symlink(&real, &chosen).map_err(|e| format!("cannot link {chosen:?}: {e}"))?;
            {
                let scene = scene(world);
                scene.before = read(&real);
                scene.file = real;
                scene.chosen = chosen.clone();
            }
            review(world, json!({"file": chosen.display().to_string()}))
        },
    );
    steps.step(
        "the changes are prepared against that file",
        |world, _, _| {
            expect!(
                field(world, "config.review.changed") == true,
                "a diff; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the panel shows which settings file is in use, including a link's target and that it will be kept",
        |world, _, _| {
            let (chosen, file) = {
                let scene = scene(world);
                (scene.chosen.clone(), scene.file.clone())
            };
            let target = fs::canonicalize(&file).unwrap_or(file);
            expect!(
                field(world, "config.file") == chosen.display().to_string().as_str()
                    && field(world, "config.review.linked")
                        == format!("Linked to {}. The link will be kept.", target.display())
                            .as_str(),
                "the file and its link; Snap Shot is {}",
                describe(world)
            );
            config_save(world)?;
            expect!(
                fs::symlink_metadata(&chosen).is_ok_and(|m| m.file_type().is_symlink()),
                "the link to be kept"
            );
            Ok(())
        },
    );
    steps.step("the user opens Advanced", |_, _, _| Ok(()));
    steps.step(
        "the binding is shown with where to paste it and a way to copy it",
        |world, _, _| {
            expect!(
                text(&field(world, "config.binding")).contains("--dest\" \"hal-c2.SnapShot\"")
                    && text(&field(world, "config.manual")).starts_with("Paste this inside binds"),
                "the binding and where it goes; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("copying says {Q}"), |world, c, _| {
        send(world, "config.copy", json!({}))?;
        let binding = text(&field(world, "config.binding"));
        expect!(
            field(world, "config.copyLabel") == c[0].as_str() && world.clipboard() == binding,
            "{} and the binding on the clipboard (it holds {}); Snap Shot is {}",
            c[0],
            world.clipboard(),
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user saved the shortcut into the config",
        |world, _, _| {
            open(world, "hyprland", false)?;
            compositor().reload = NO_RELOAD.into();
            reviewed(world)?;
            let file = scene(world).file.clone();
            scene(world).before = read(&file);
            config_save(world)
        },
    );
    steps.step("the backup file's path is shown", |world, _, _| {
        let backup = text(&field(world, "config.backup"));
        let path = backup
            .strip_prefix("Backup: ")
            .unwrap_or_default()
            .to_owned();
        let before = scene(world).before.clone();
        expect!(
            !path.is_empty() && read(Path::new(&path)) == before,
            "a backup with the old config; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "a Hyprland session where HAL-C2's shortcut action is not registered yet",
        |world, _, _| open(world, "hyprland", true),
    );
    steps.step(
        &format!("setup says {Q} while it connects"),
        |world, c, _| {
            expect!(
                field(world, "config.connecting") == c[0].as_str(),
                "{}; Snap Shot is {}",
                c[0],
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("{Q} when it is not coming"), |world, c, _| {
        set_setting(world, "snapShotEnabled", json!(false))?;
        {
            let state = desktop(world);
            let mut d = state.borrow_mut();
            d.hold_shortcuts = false;
            d.refuse = "no answer".into();
        }
        set_setting(world, "snapShotEnabled", json!(true))?;
        let said = c[0].clone();
        wait(world, &format!("setup to say {said}"), move |w| {
            field(w, "config.connecting") == said.as_str()
        })
    });
}

fn refusals(steps: &mut Steps) {
    steps.step("the settings file cannot be read", |world, _, _| {
        let file = scene(world).file.clone();
        chmod(&file, 0);
        Ok(())
    });
    steps.step(
        "the settings file belongs to another user or to Omarchy defaults",
        |world, _, _| {
            open(world, "hyprland", false)?;
            let home = scene(world).home.clone();
            choose(
                world,
                home.join(".local/share/omarchy/default/hypr/bindings.conf"),
                b"bind = SUPER, T, exec, foot\n",
            )
        },
    );
    steps.step(
        "the settings file has an unexpected extension",
        |world, _, _| {
            let (home, before) = {
                let scene = scene(world);
                (scene.home.clone(), scene.before.clone())
            };
            choose(world, home.join(".config/niri/config.txt"), &before)
        },
    );
    steps.step(
        "a Niri config includes files by pattern or variable",
        |world, _, _| rewrite(world, b"include \"parts/*.kdl\"\nbinds {\n}\n"),
    );
    steps.step(
        "a Niri config includes more than 64 files or nests deeper than 10 levels",
        |world, _, _| {
            let dir = folder(world);
            let mut config = String::new();
            for i in 0..65 {
                let name = format!("part{i}.kdl");
                write(&dir.join(&name), b"")?;
                config += &format!("include \"{name}\"\n");
            }
            config += "binds {\n}\n";
            rewrite(world, config.as_bytes())
        },
    );
    steps.step("a Niri include cannot be read", |world, _, _| {
        let part = folder(world).join("part.kdl");
        write(&part, b"")?;
        chmod(&part, 0);
        rewrite(world, b"include \"part.kdl\"\nbinds {\n}\n")
    });
    steps.step(
        "a Hyprland Lua config returns early or uses long strings",
        |world, _, _| {
            open(world, "hyprland", false)?;
            let home = scene(world).home.clone();
            choose(
                world,
                home.join(".config/hypr/hyprland.lua"),
                b"return {}\n",
            )
        },
    );
    steps.step(
        "a Niri config has more than one binds section",
        |world, _, _| rewrite(world, b"binds {\n}\nbinds {\n}\n"),
    );
    steps.step(
        &format!("nothing is changed and the user is told {Q}"),
        |world, c, _| {
            settle(world)?;
            expect_unchanged(world)?;
            expect!(
                field(world, "config.error") == UNPREPARED,
                "a refusal; Snap Shot is {}",
                describe(world)
            );
            expect_details(world, &c[0])
        },
    );
    steps.step(
        "the chosen keys are already bound in the config, in a file it includes, or by Hyprland itself",
        |world, _, _| {
            let part = folder(world).join("part.kdl");
            write(&part, b"binds {\n    Ctrl+Shift+2 { spawn \"foot\"; }\n}\n")?;
            rewrite(world, b"include \"part.kdl\"\nbinds {\n}\n")
        },
    );
    steps.step(
        "nothing is changed and the user is told the keys are already used and to choose another shortcut",
        |world, _, _| {
            expect_unchanged(world)?;
            details_contain(world, "already")?;
            // Hyprland's own binds count too.
            open(world, "hyprland", false)?;
            compositor().binds = Some(vec![HyprlandBind {
                modmask: 5,
                key: "2".into(),
                dispatcher: "exec".into(),
                arg: "foot".into(),
            }]);
            review(world, json!({}))?;
            expect_unchanged(world)?;
            details_contain(world, "already")
        },
    );
    steps.step(
        "a Hyprland session that cannot report its current shortcuts",
        |world, _, _| {
            open(world, "hyprland", false)?;
            compositor().binds = None;
            Ok(())
        },
    );
    steps.step(
        "the user is told to try again from the Hyprland session",
        |world, _, _| details_contain(world, "Hyprland session"),
    );
    steps.step("nothing is changed", |world, _, _| expect_unchanged(world));
}

fn busy(steps: &mut Steps) {
    steps.step(
        "the desktop is saving a reviewed shortcut change",
        |world, _, _| {
            open(world, "niri", false)?;
            reviewed(world)?;
            compositor().hold = true;
            send(world, "config.save", json!({}))?;
            wait_held()
        },
    );
    steps.step(
        "the user tries to cancel the review, record other keys, go back, turn capture off and close setup",
        |world, _, _| {
            send(world, "config.cancel", json!({}))?;
            send(world, "record.start", Value::Null)?;
            send(world, "setup.back", json!({}))?;
            send(world, "enable", json!({"on": false}))?;
            send(world, "setup.close", json!({"completed": false}))?;
            send(world, "config.complete", json!({}))?;
            send(world, "setup.done", json!({}))
        },
    );
    steps.step(
        "setup stays open on the review until the save finishes",
        |world, _, _| {
            expect!(
                field(world, "config.busy") == true
                    && !text(&field(world, "config.review.id")).is_empty()
                    && wizard_on_shortcut(world)
                    && field(world, "switchOn") == true,
                "the review to stay; Snap Shot is {}",
                describe(world)
            );
            release();
            settle(world)?;
            let file = scene(world).file.clone();
            expect!(
                contains(&file, "hal-c2"),
                "the save to land: {}",
                shown(&file)
            );
            Ok(())
        },
    );
    steps.step(
        "the desktop is saving a reviewed shortcut change the user was still recording over",
        |world, _, _| {
            open(world, "niri", false)?;
            reviewed(world)?;
            send(world, "record.start", Value::Null)?;
            expect!(
                field(world, "shortcut.recording") == true,
                "recording; Snap Shot is {}",
                describe(world)
            );
            compositor().hold = true;
            send(world, "config.save", json!({}))?;
            wait_held()
        },
    );
    steps.step("the user presses other keys", |world, _, _| {
        press(world, KEY_K, CONTROL | ALT)?;
        expect!(
            field(world, "shortcut.recording") != true,
            "the save to end the recording; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user has a shortcut change under review",
        |world, _, _| reviewed(world),
    );
    steps.step("the user turns capture off and on again", |world, _, _| {
        send(world, "enable", json!({"on": false}))?;
        send(world, "enable", json!({"on": true}))
    });
    steps.step("no config change is under review", |world, _, _| {
        expect!(
            wizard_on_shortcut(world) && field(world, "config.review").is_null(),
            "setup without the review; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step("the user asks to review another change", |world, _, _| {
        send(world, "config.review", json!({}))
    });
    steps.step(
        "the user is told to wait for the current config change to finish",
        |world, _, _| {
            expect_details(world, "Wait for the current config change to finish.")?;
            release();
            settle(world)
        },
    );
    const CHOOSE_KEYS: &str = "Choose a letter, number, or function key with Ctrl, Alt, or Super.";
    steps.step(
        "the user records a shortcut of Shift and a letter, or of a punctuation key",
        |world, _, _| {
            for (key, modifiers) in [(KEY_K, SHIFT), (KEY_COMMA, CONTROL | ALT)] {
                record(world, key, modifiers)?;
                expect!(
                    field(world, "shortcut.status") == CHOOSE_KEYS,
                    "the keys refused; Snap Shot is {}",
                    describe(world)
                );
            }
            Ok(())
        },
    );
    steps.step(
        "the user is told to choose a letter, number or function key with Ctrl, Alt or Super",
        |world, _, _| {
            review(world, json!({}))?;
            expect_unchanged(world)?;
            expect_details(world, CHOOSE_KEYS)
        },
    );
    steps.step(
        "the user reviewed a change to the Niri config",
        |world, _, _| {
            open(world, "niri", false)?;
            reviewed(world)
        },
    );
    steps.step("Niri validates the new config first", |world, _, _| {
        let file = scene(world).file.display().to_string();
        let validated = compositor().validated.clone();
        expect!(
            validated.len() == 1 && validated[0] != file,
            "a stand-in validated: {}",
            validated.join(",")
        );
        expect!(
            !Path::new(&validated[0]).exists(),
            "the stand-in to be gone"
        );
        Ok(())
    });
    steps.step("a config Niri rejects is not saved", |world, _, _| {
        let file = scene(world).file.clone();
        scene(world).before = read(&file);
        record(world, KEY_K, CONTROL | ALT)?;
        reviewed(world)?;
        compositor().niri_valid = false;
        config_save(world)?;
        expect_unchanged(world)?;
        expect!(
            text(&field(world, "config.details")).starts_with("Niri couldn't validate"),
            "Niri's refusal; Snap Shot is {}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "the user reviewed a change to a config that uses Windows line endings and is readable only by the user",
        |world, _, _| {
            open(world, "niri", false)?;
            rewrite(world, b"binds {\r\n    Mod+T { spawn \"foot\"; }\r\n}\r\n")?;
            reviewed(world)
        },
    );
    steps.step(
        "the new binding uses the same line endings",
        |world, _, _| {
            let file = scene(world).file.clone();
            let after = shown(&file);
            expect!(
                after.contains("Ctrl+Shift+2")
                    && after.matches('\n').count() == after.matches("\r\n").count(),
                "CRLF throughout: {after:?}"
            );
            Ok(())
        },
    );
    steps.step("the file keeps its permissions", |world, _, _| {
        let file = scene(world).file.clone();
        let mode = fs::metadata(&file).map(|m| m.permissions().mode() & 0o777);
        expect!(
            mode.as_ref().is_ok_and(|m| *m == 0o600),
            "0600 on the file, not {mode:?}"
        );
        Ok(())
    });
    steps.step("the settings file is larger than 1 MB", |world, _, _| {
        rewrite(world, &vec![b' '; 1024 * 1024 + 1])
    });
    steps.step(
        "the settings file and its included files add up to more than 1 MB",
        |world, _, _| {
            let dir = folder(world);
            let mut config = String::new();
            for i in 0..3 {
                let name = format!("big{i}.kdl");
                write(&dir.join(&name), &vec![b' '; 500 * 1024])?;
                config += &format!("include \"{name}\"\n");
            }
            config += "binds {\n}\n";
            rewrite(world, config.as_bytes())
        },
    );
    steps.step("the settings file is not a text file", |world, _, _| {
        rewrite(world, b"binds {\0}\n")
    });
    steps.step(
        "the user reviewed a change to the Hyprland config and saves it",
        |world, _, _| {
            open(world, "hyprland", false)?;
            reviewed(world)
        },
    );
    steps.step("Hyprland reloads and reports errors in its config", |world, _, _| {
        compositor().reload = "Config saved, but Hyprland reported config errors. Check hyprctl configerrors, then run hyprctl reload.".into();
        config_save(world)
    });
    steps.step(
        "the user is told Hyprland reported config errors",
        |world, _, _| {
            expect!(
                field(world, "config.intro")
                    == "Saved, but the shortcut needs attention. Check Advanced for help."
                    && text(&field(world, "config.details")).contains("reported config errors"),
                "config errors; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user reviewed a change to the Niri or Hyprland config",
        |world, _, _| {
            open(world, "niri", false)?;
            reviewed(world)?;
            scene(world).stale_id = text(&field(world, "config.review.id"));
            Ok(())
        },
    );
    steps.step(
        "the user has since reviewed another change, or the change was already saved",
        |world, _, _| reviewed(world),
    );
    steps.step("the user saves the earlier review", |world, _, _| {
        let stale = scene(world).stale_id.clone();
        send(world, "config.save", json!({"id": stale}))?;
        settle(world)
    });
    steps.step("nothing is written", |world, _, _| expect_unchanged(world));
    steps.step(
        "the user is told the preview expired and to review the changes again",
        |world, _, _| details_contain(world, "expired"),
    );
    steps.step(
        "the user reviewed a change to a Niri config that includes an optional file that does not exist",
        |world, _, _| {
            open(world, "niri", false)?;
            rewrite(world, b"include optional=true \"maybe.kdl\"\nbinds {\n}\n")?;
            reviewed(world)
        },
    );
    steps.step(
        "that file has been created since the review",
        |world, _, _| {
            let maybe = folder(world).join("maybe.kdl");
            write(&maybe, b"")
        },
    );
    steps.step(
        "nothing is written and the user is asked to review again",
        |world, _, _| {
            expect_unchanged(world)?;
            expect!(
                field(world, "config.error")
                    == "Couldn't save your shortcut. Review the changes and try again.",
                "to review again; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("the user saves", |world, _, _| config_save(world));

    // The compositor keeps the shortcut.
    steps.step("the user checks a shortcut in HAL-C2", |world, _, _| {
        record(world, KEY_K, CONTROL | ALT)
    });
    steps.step(
        "the shortcut row says to configure the capture shortcut in the compositor's config and save it",
        |world, _, _| {
            expect!(
                field(world, "shortcut.status")
                    == "Configure the capture shortcut in your Niri config, not in HAL-C2."
                    && field(world, "shortcut.canSave") != true,
                "to configure it there; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "HAL-C2 does not register the shortcut itself",
        |world, _, _| {
            let binds = desktop(world).borrow().binds.clone();
            expect!(
                binds.is_empty(),
                "no shortcut bound; bound {}; Snap Shot is {}",
                binds.join(","),
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "the user reviewed the changes to the Niri config",
        |world, _, _| {
            open(world, "niri", false)?;
            reviewed(world)
        },
    );
    steps.step(
        "the Niri config changed on disk afterwards",
        |world, _, _| {
            let mut edited = scene(world).before.clone();
            edited.extend_from_slice(b"# edited\n");
            rewrite(world, &edited)
        },
    );
    steps.step(
        "the user reviews the changes to the Hyprland config and saves them",
        |world, _, _| {
            compositor().hold = false;
            reviewed(world)?;
            config_save(world)
        },
    );
    steps.step(
        "the config is written in one step after checking it did not change since review",
        |world, _, _| {
            let file = scene(world).file.clone();
            expect!(
                contains(&file, "global, hal-c2"),
                "the binding: {}",
                shown(&file)
            );
            let left = files_in(&folder(world));
            expect!(
                left.len() == 2,
                "only the config and its backup: {}",
                left.join(",")
            );
            Ok(())
        },
    );
    steps.step("a backup of the previous config is kept", |world, _, _| {
        let dir = folder(world);
        let (file, before) = {
            let scene = scene(world);
            (scene.file.clone(), scene.before.clone())
        };
        let name = file
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let backups: Vec<String> = files_in(&dir).into_iter().filter(|f| *f != name).collect();
        expect!(
            backups.len() == 1 && read(&dir.join(&backups[0])) == before,
            "the old config kept; found {}",
            backups.join(",")
        );
        Ok(())
    });
}

/// The files (not folders) in `dir`.
fn files_in(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| entry.file_type().is_ok_and(|t| t.is_file()))
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

fn niri_steps(steps: &mut Steps) {
    steps.step("a Niri session of version 25\\.11 or newer", |_, _, _| {
        Ok(())
    });
    steps.step(
        "another HAL-C2 instance already owns the endpoint",
        |world, _, _| open_niri(world, "25.11.0", true),
    );
    steps.step(
        "the endpoint disconnects while HAL-C2 is running",
        |world, _, _| {
            open_niri(world, "25.11.0", false)?;
            // The bus goes, and the endpoint's name with it.
            scene(world).bus = None;
            wait(world, "the endpoint to go", |w| {
                field(w, "shortcut.registered") != true
            })
        },
    );
    steps.step(
        "the endpoint is up and the binding is not in the config yet",
        |world, _, _| open_niri(world, "25.11.0", false),
    );
    steps.step(
        "a Niri session older than version 25\\.11",
        |world, _, _| open_niri(world, "25.8.0", false),
    );
    steps.step(
        "nothing is attached and the user is told SnapShots require Niri 25\\.11 or newer",
        |world, _, _| {
            wait(world, "the failure", |w| {
                toast_saying(w, "SnapShots require Niri 25.11 or newer.").is_some()
            })?;
            let shots = shots(world);
            expect!(shots == 0, "no capture taken; {shots} taken");
            Ok(())
        },
    );
    steps.step(
        "a Niri session with the capture binding set up",
        |world, _, _| open_niri(world, "25.11.0", false),
    );
    steps.step(
        "another program calls the capture endpoint with arguments",
        |world, _, _| {
            wait(world, "the endpoint", |w| {
                field(w, "shortcut.registered") == true
            })?;
            let other = scene(world).bus.as_ref().ok_or("no test bus")?.connect()?;
            let called = other.call_method(
                Some(NAME),
                NIRI_PATH,
                Some(NIRI_INTERFACE),
                "Capture",
                &("extra",),
            );
            scene(world).endpoint_error = match called {
                Err(zbus::Error::MethodError(name, _, _)) => name.as_str().to_owned(),
                Err(error) => format!("{error}"),
                Ok(_) => "no error".to_owned(),
            };
            world.pump()
        },
    );
    steps.step("the call is refused as invalid", |world, _, _| {
        let name = scene(world).endpoint_error.clone();
        expect!(
            name == "org.freedesktop.DBus.Error.InvalidArgs",
            "InvalidArgs, not {name}"
        );
        Ok(())
    });
    steps.step("no capture is taken", |world, _, _| {
        deliver(world.engine());
        world.pump()?;
        let shots = shots(world);
        expect!(shots == 0, "no capture; {shots} taken");
        Ok(())
    });
    steps.step(
        "(?:the desktop app runs on Linux on Niri|a Linux Wayland session on Niri)",
        |world, _, _| {
            open_niri(world, "25.11.0", false)?;
            open_thread(world)
        },
    );
    steps.step("Niri has no focused window", |world, _, _| {
        if let Some(niri) = &scene(world).niri {
            niri.state().focused = false;
        }
        Ok(())
    });
    steps.step("capture works through a Niri binding", |world, _, _| {
        expect!(
            field(world, "shortcut.managed") == true && field(world, "shortcut.registered") == true,
            "the endpoint up; Snap Shot is {}",
            describe(world)
        );
        capture(world)?;
        let target = thread_key(world);
        wait(world, "the capture", |w| {
            !attachments(w, &target).is_empty()
        })?;
        let image = attached(world, &target)?;
        let shots = shots(world);
        expect!(
            shots == 1 && image["mimeType"] == "image/png",
            "one PNG from Niri; {shots} taken, attached {}",
            show(&image)
        );
        Ok(())
    });
    steps.step(
        "HAL-C2 runs inside a (\\S+) sandbox on a (\\S+(?: Plasma)?) Wayland session",
        |world, c, _| {
            let home = fresh_home(world)?;
            let kind = if c[1] == "KDE Plasma" {
                "kde".to_owned()
            } else {
                c[1].to_lowercase()
            };
            let mut env = environment_for(&home, &kind);
            let sandbox = if c[0] == "Snap" { "SNAP" } else { "FLATPAK_ID" };
            env.insert(sandbox.into(), "hal-c2".into());
            // Even with Niri's socket in reach.
            env.insert("NIRI_SOCKET".into(), home.join("s").display().to_string());
            {
                let scene = scene(world);
                scene.niri = None;
                scene.bus = None;
                scene.home = home;
            }
            reset_with(world, env, None)
        },
    );
    steps.step(
        "capture works through the desktop portal when it can capture a window",
        |world, _, _| {
            expect!(
                field(world, "backend") == "screenshot-portal"
                    && field(world, "shortcut.managed") != true,
                "the portal; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "otherwise the user picks the window each time",
        |world, _, _| {
            desktop(world).borrow_mut().picker = true;
            update(world)?;
            expect!(
                field(world, "status") == "Manual capture only — you'll choose a window each time",
                "the picker; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "no compositor config, extension or capture helper is offered",
        |world, _, _| {
            expect!(
                field(world, "config").is_null(),
                "no config; Snap Shot is {}",
                describe(world)
            );
            Ok(())
        },
    );
}
