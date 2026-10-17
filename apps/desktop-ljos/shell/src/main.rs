//! `hal-c2-ljos`: the HAL-C2 desktop shell on Ljós.
//!
//!   hal-c2-ljos [--mc-origin URL --mc-token TOKEN | --pair LINK]
//!               [--home-dir DIR] [--dev] [--config-dir DIR]
//!               [--qml-dir DIR] [--allow-local-folder-import]
//!               [--action NAME[=JSON]]... [--key CHORD]...
//!               [--render PNG [--size WxH] [--settle MS]]
//!               [--screenshot PNG [--size WxH]]
//!   hal-c2-ljos --check [--qml-dir DIR]
//!
//! The MC is the one host/main.ts would hand desktop-qt: its origin and
//! token, also read from HAL_C2_MC_ORIGIN and HAL_C2_MC_TOKEN. `--pair`
//! spends a pairing link (`mix hal_c2.pair`) on a session and keeps it, so a
//! later start without an MC named reconnects to it. With none of these the
//! shell runs disconnected.
//!
//! What the shell keeps (the session, the client cache) is under
//! `--home-dir`, or the XDG directories (`hal-c2-dev` ones with `--dev`),
//! one `desktop-ljos` level down (src/storage.rs).
//!
//! `--action` dispatches a shell action, its JSON payload after a `=` or a
//! space (`settings.open`, `theme.mode={"mode":"dark"}`), and `--key`
//! presses a window shortcut (`Ctrl+B`; see src/scripted_run.rs for what a
//! chord reaches). They run in the order given, 1.5 s apart, once the MC's
//! first snapshot is in. `--screenshot` writes a picture 1.5 s after the
//! last of them, without opening a window (the steps run on a virtual
//! clock, so it does not wait), and exits 2 when it cannot: also when the
//! MC cannot be reached, in which case the picture is the shell
//! disconnected, with the reason in its error overlay.
//!
//! `--render` writes a picture the same way but dispatches its `--action`s
//! before the snapshot wait, for a render of a given place, and settles for
//! `--settle` ms. `--check` only compiles the QML, and fails when a file
//! does not compile.

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::rc::Rc;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use hal_c2_mc::pairing;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller;
use hal_c2_shell::controllers::alerts::AlertController;
use hal_c2_shell::mc::{Connection, Disconnected, Mc};
#[cfg(all(unix, not(target_os = "macos")))]
use hal_c2_shell::notifications::NativeNotifications;
use hal_c2_shell::qml::{self, Roots};
use hal_c2_shell::scripted_run::{self, Step};
use hal_c2_shell::session::{self, Session};
use hal_c2_shell::storage::{Profile, StoragePaths};
use hal_c2_shell::{Launch, store};
use ljos::CoalesceKey;
use ljos::prelude::{Engine, LogLevel};
use ljos::render::{Fonts, Picture};
use ljos::{App, ShellConfig};

const ROOT: &str = "Main";
/// How long a render waits for the MC's first snapshot before it shows what
/// the cache kept.
const SNAPSHOT_TIMEOUT: Duration = Duration::from_secs(10);

struct Options {
    launch: Launch,
    mc_token: String,
    roots: Roots,
    /// The `--action`s and `--key`s, in the order given.
    steps: Vec<Step>,
    check: bool,
    render: Option<PathBuf>,
    screenshot: Option<PathBuf>,
    size: (u32, u32),
    settle_ms: u64,
    home_dir: Option<PathBuf>,
    dev: bool,
    pair: Option<String>,
}

fn usage() -> ExitCode {
    eprintln!(
        "usage: hal-c2-ljos [--mc-origin URL --mc-token TOKEN | --pair LINK] [--home-dir DIR] [--dev]\n\
         \x20                  [--config-dir DIR] [--qml-dir DIR] [--licenses MANIFEST]\n\
         \x20                  [--allow-local-folder-import] [--action NAME[=JSON]]... [--key CHORD]...\n\
         \x20                  [--render PNG [--size WxH] [--settle MS]]\n\
         \x20                  [--screenshot PNG [--size WxH]]\n\
         \x20      hal-c2-ljos --check [--qml-dir DIR]"
    );
    ExitCode::from(2)
}

/// The staged license manifest, in `licenses/` beside the QML directory.
fn licenses_beside(qml_dir: &std::path::Path) -> std::path::PathBuf {
    qml_dir.join("../licenses/third-party-licenses.json")
}

fn parse() -> Result<Options, String> {
    let mut o = Options {
        launch: Launch {
            mc_origin: std::env::var("HAL_C2_MC_ORIGIN")
                .ok()
                .filter(|s| !s.is_empty()),
            // `vp run licenses` stages it in apps/desktop-qt/licenses.
            licenses_manifest: Some(licenses_beside(&Roots::checkout().bricks)),
            ..Launch::default()
        },
        mc_token: std::env::var("HAL_C2_MC_TOKEN").unwrap_or_default(),
        roots: Roots::checkout(),
        steps: Vec::new(),
        check: false,
        render: None,
        screenshot: None,
        size: (1280, 800),
        settle_ms: 1500,
        home_dir: None,
        dev: false,
        pair: None,
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let (name, inline) = match arg.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n.to_owned(), Some(v.to_owned())),
            _ => (arg.clone(), None),
        };
        let mut value = || {
            inline
                .clone()
                .or_else(|| args.next())
                .ok_or_else(|| format!("{name} needs a value"))
        };
        match name.as_str() {
            "--mc-origin" => o.launch.mc_origin = Some(value()?),
            "--mc-token" => o.mc_token = value()?,
            "--pair" => o.pair = Some(value()?),
            "--home-dir" => o.home_dir = Some(value()?.into()),
            "--dev" => o.dev = true,
            "--config-dir" => o.launch.config_dir = Some(value()?.into()),
            "--qml-dir" => {
                o.roots = Roots::one(value()?.into());
                o.launch.licenses_manifest = Some(licenses_beside(&o.roots.bricks));
            }
            "--licenses" => o.launch.licenses_manifest = Some(value()?.into()),
            "--allow-local-folder-import" => o.launch.allow_local_folder_import = true,
            "--action" => {
                let (step, note) = Step::action(&value()?);
                if let Some(note) = note {
                    eprintln!("hal-c2-ljos: {note}");
                }
                o.steps.push(step);
            }
            "--key" => {
                let chord = value()?;
                scripted_run::sequence(&chord).map_err(|e| format!("--key {chord}: {e}"))?;
                o.steps.push(Step::Key(chord));
            }
            "--check" => o.check = true,
            "--render" => o.render = Some(value()?.into()),
            "--screenshot" => o.screenshot = Some(value()?.into()),
            "--size" => {
                let v = value()?;
                let (w, h) = v
                    .split_once(['x', 'X'])
                    .ok_or_else(|| format!("{v:?} is not WxH"))?;
                let side = |s: &str| s.parse::<u32>().ok().filter(|n| (1..=16_384).contains(n));
                o.size = side(w)
                    .zip(side(h))
                    .ok_or_else(|| format!("{v:?} is not WxH"))?;
            }
            "--settle" => {
                o.settle_ms = value()?
                    .parse()
                    .map_err(|_| "--settle takes milliseconds".to_owned())?
            }
            _ => return Err(format!("unknown option {arg}")),
        }
    }
    if o.render.is_some() && o.screenshot.is_some() {
        return Err("--render and --screenshot are two ways to take a picture; use one".into());
    }
    if o.render.is_some() && o.steps.iter().any(|s| matches!(s, Step::Key(_))) {
        return Err("--key needs the shell running: use --screenshot, not --render".into());
    }
    Ok(o)
}

fn main() -> ExitCode {
    let mut options = match parse() {
        Ok(o) => o,
        Err(e) => {
            eprintln!("hal-c2-ljos: {e}");
            return usage();
        }
    };
    if options.check {
        return check(&options.roots);
    }
    // A failed start still gets its picture when one was asked for.
    let failure = connect_to(&mut options).err();
    if let Some(e) = &failure {
        eprintln!("hal-c2-ljos: {e}");
        if options.screenshot.is_none() {
            return ExitCode::FAILURE;
        }
    }
    // A brick with an error fails only what makes an object of it, as in Qt.
    let app = match options.roots.dirs().and_then(|dirs| {
        App::new("HAL-C2")
            .register(hal_c2_shell::register)
            .qml_dirs(dirs, ROOT)
    }) {
        Ok(app) => app,
        Err(e) => {
            eprintln!("hal-c2-ljos: {e}");
            return ExitCode::FAILURE;
        }
    };
    if let Some(out) = &options.screenshot {
        // ScriptedRun's codes: 0 for a picture, 2 for none, or for the
        // picture of a start that failed.
        return match render_to(app, &options, out, Capture::scripted(&options, failure)) {
            Ok(false) => ExitCode::SUCCESS,
            Ok(true) => ExitCode::from(2),
            Err(e) => {
                eprintln!("hal-c2-ljos: {e}");
                ExitCode::from(2)
            }
        };
    }
    let result = match &options.render {
        Some(out) => render_to(app, &options, out, Capture::render(&options)).map(drop),
        None => run(app, options),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("hal-c2-ljos: {e}");
            ExitCode::FAILURE
        }
    }
}

/// `--check`: whether every QML file compiles, what the compiler said a
/// line each, then how many of the files compiled.
fn check(roots: &Roots) -> ExitCode {
    let compiled = match qml::compile(roots) {
        Ok(compiled) => compiled,
        Err(e) => {
            eprintln!("hal-c2-ljos: {e}");
            return ExitCode::FAILURE;
        }
    };
    for d in &compiled.diagnostics {
        eprintln!("{d}");
    }
    let failed = compiled.source.failures().count();
    let files = compiled.source.keys().count() + failed;
    eprintln!(
        "hal-c2-ljos: {} of {files} QML files compiled",
        files - failed
    );
    if failed == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

/// Which MC the shell connects to and where it keeps what it was sent: the
/// one named, else the one `--pair` pairs with, else the one paired last.
fn connect_to(options: &mut Options) -> Result<(), String> {
    let profile = if options.dev {
        Profile::Development
    } else {
        Profile::Installed
    };
    let paths = StoragePaths::resolve(options.home_dir.as_deref(), profile);
    if let Some(link) = &options.pair {
        let kept = pair(link, &paths.data)?;
        options.launch.mc_origin = Some(kept.origin);
        options.mc_token = kept.token;
    } else if options.launch.mc_origin.is_none()
        && let Some(kept) = session::load(&paths.data)
    {
        options.launch.mc_origin = Some(kept.origin);
        options.mc_token = kept.token;
    }
    options.launch.cache_dir = Some(paths.cache);
    options.launch.data_dir = Some(paths.data);
    options.launch.state_dir = Some(paths.state);
    Ok(())
}

/// Spends `link` on a session with its MC and keeps it in `data_dir`.
fn pair(link: &str, data_dir: &Path) -> Result<Session, String> {
    let parsed = pairing::read_invitation(link)
        .and_then(|i| pairing::read_link(&i.link))
        .or_else(|| pairing::read_link(link))
        .ok_or_else(|| format!("{link:?} is not a pairing link"))?;
    let client = pairing::Client {
        label: format!("HAL-C2 desktop on {}", host_name()),
        device_type: "desktop".into(),
        os: match std::env::consts::OS {
            "linux" => "Linux",
            "macos" => "macOS",
            "windows" => "Windows",
            other => other,
        }
        .into(),
    };
    let result = pairing::exchange(&parsed, &client);
    let said = |key: &str| {
        result
            .descriptor
            .get(key)
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_owned()
    };
    match result.outcome {
        pairing::Outcome::Paired => {}
        pairing::Outcome::Unreachable => {
            return Err(format!("no MC answered at {}", result.origin));
        }
        pairing::Outcome::NotMc => return Err(format!("{} is not an MC", result.origin)),
        pairing::Outcome::Incompatible => {
            return Err(format!(
                "the MC at {} speaks another protocol; update one of them",
                result.origin
            ));
        }
        pairing::Outcome::Refused => {
            return Err(format!(
                "the MC at {} refused the link: it was used or expired",
                result.origin
            ));
        }
    }
    let kept = Session {
        origin: result.origin.clone(),
        token: result.token.clone(),
        label: said("label"),
        environment_id: said("environmentId"),
    };
    session::save(data_dir, &kept).map_err(|e| format!("{}: {e}", data_dir.display()))?;
    eprintln!("hal-c2-ljos: paired with {} at {}", kept.label, kept.origin);
    Ok(kept)
}

fn host_name() -> String {
    std::fs::read_to_string("/etc/hostname")
        .ok()
        .or_else(|| std::env::var("HOSTNAME").ok())
        .or_else(|| std::env::var("COMPUTERNAME").ok())
        .map(|h| h.trim().to_owned())
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "this computer".into())
}

/// What the QML says that is wrong, on stderr, each message once.
fn report_warnings(engine: &Engine) {
    let seen = std::cell::RefCell::new(std::collections::HashSet::new());
    engine.set_log_handler(move |entry| {
        if matches!(entry.level, LogLevel::Warning | LogLevel::Critical) {
            let first = entry.message.lines().next().unwrap_or("").trim().to_owned();
            if seen.borrow_mut().insert(first.clone()) {
                eprintln!("qml: {first}");
            }
        }
    });
}

/// What a picture is of: the steps before it, how long the shell settles,
/// and why the start failed when it did.
struct Capture {
    steps: Vec<Step>,
    /// `--render` dispatches its actions before it waits for the snapshot;
    /// `--screenshot` plays its steps after it, spaced out on the clock.
    play_after_snapshot: bool,
    settle_ms: u64,
    failure: Option<String>,
}

impl Capture {
    /// `--render`: the actions at once, the `--settle` time.
    fn render(options: &Options) -> Capture {
        Capture {
            steps: options.steps.clone(),
            play_after_snapshot: false,
            settle_ms: options.settle_ms,
            failure: None,
        }
    }

    /// `--screenshot`: the steps one and a half seconds apart, then the
    /// picture one and a half after the last; or, for a start that failed,
    /// the shell disconnected showing why, a picture one and a half seconds
    /// in.
    fn scripted(options: &Options, failure: Option<String>) -> Capture {
        let (steps, settle) = match failure {
            Some(_) => (Vec::new(), scripted_run::SPACING),
            None => (
                options.steps.clone(),
                scripted_run::timetable(options.steps.len()).1,
            ),
        };
        Capture {
            steps,
            play_after_snapshot: true,
            settle_ms: settle.as_millis() as u64,
            failure,
        }
    }
}

/// A picture without a window: the shell once its MC's first snapshot is in
/// (what the cache kept, when the MC does not answer in time), or as it
/// shows disconnected. True when it is the picture of a start that failed
/// (`capture.failure`, or the MC refusing the connection here), which
/// ScriptedRun's `captureFailure` takes for exit code 2.
fn render_to(
    app: App,
    options: &Options,
    out: &PathBuf,
    mut capture: Capture,
) -> Result<bool, String> {
    // The bundled font: the same picture on every machine.
    ljos::render::set_fonts(Fonts::Bundled);
    let engine = app.build_engine();
    let picture = Picture::new(options.size.0, options.size.1)
        .settle(capture.settle_ms)
        .on_scene_message(|message| eprintln!("scene: {message}"));
    picture.install(&engine);
    report_warnings(&engine);
    let mut launch = options.launch.clone();
    let connection = match (&launch.mc_origin, &capture.failure) {
        (Some(origin), None) => {
            let (woken, wakes) = mpsc::channel();
            let woken_by_cache = woken.clone();
            let connection = Rc::new(Connection::spawn(move || {
                let _ = woken.send(());
            }));
            match connection.open(origin, &options.mc_token) {
                Ok(()) => Some((connection, wakes, woken_by_cache)),
                Err(e) if capture.play_after_snapshot => {
                    eprintln!("hal-c2-ljos: {e}");
                    capture = Capture::scripted(options, Some(e));
                    None
                }
                Err(e) => return Err(e),
            }
        }
        _ => None,
    };
    if capture.failure.is_some() {
        // The shell that has no MC to wait for.
        launch.mc_origin = None;
    }
    let play = |engine: &Engine, steps: &[Step]| {
        for step in steps {
            scripted_run::run(engine, step);
        }
    };
    let root = match connection {
        Some((connection, wakes, woken_by_cache)) => {
            hal_c2_shell::start(&engine, &launch, connection.clone());
            hal_c2_shell::controllers::threads::set_wake(&engine, move || {
                let _ = woken_by_cache.send(());
            });
            let root = engine
                .create_from_url(ROOT, None, Vec::new())
                .map_err(|e| e.to_string())?;
            let deadline = Instant::now() + SNAPSHOT_TIMEOUT;
            // `--screenshot` plays its steps on the picture's clock instead.
            let mut played = capture.play_after_snapshot;
            let mut active = false;
            loop {
                // The steps once the shell is active: navigation follows a
                // route only from then on.
                if !active && hal_c2_shell::active(&engine) {
                    active = true;
                    if !played {
                        played = true;
                        play(&engine, &capture.steps);
                    }
                }
                if active && !hal_c2_shell::controllers::threads::loading(&engine) {
                    break;
                }
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero()
                    || wakes.recv_timeout(left) == Err(mpsc::RecvTimeoutError::Disconnected)
                {
                    let status = connection.client().status();
                    eprintln!(
                        "hal-c2-ljos: no snapshot from {} ({:?} {}), so what the cache kept",
                        launch.mc_origin.as_deref().unwrap_or_default(),
                        status.phase,
                        status.failure
                    );
                    if !played {
                        play(&engine, &capture.steps);
                    }
                    hal_c2_shell::controllers::threads::drain(&engine);
                    break;
                }
                engine.turn(None, || {
                    connection.deliver(&engine);
                    hal_c2_shell::controllers::threads::deliver(&engine);
                });
            }
            root
        }
        None => {
            let mc = Rc::new(Disconnected::default());
            hal_c2_shell::start(&engine, &launch, mc.clone());
            if let Some(why) = &capture.failure {
                // What ShellErrorOverlay shows.
                Bridge::of(&engine).publish(&engine, "backendError", why.clone().into());
            }
            let root = engine
                .create_from_url(ROOT, None, Vec::new())
                .map_err(|e| e.to_string())?;
            // Once the bricks are there, as with an MC: what opens on a
            // signal (the palette's popup) misses one sent before.
            if !capture.play_after_snapshot {
                play(&engine, &capture.steps);
            }
            mc.deliver(&engine);
            root
        }
    };
    if capture.play_after_snapshot {
        // On the picture's virtual clock: they all run while it settles.
        scripted_run::play(&engine, capture.steps.clone());
    }
    let png = picture.png(&engine, root)?;
    store::flush(&engine);
    if let Some(dir) = out.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::fs::write(out, png).map_err(|e| format!("{}: {e}", out.display()))?;
    eprintln!("hal-c2-ljos: wrote {}", out.display());
    Ok(capture.failure.is_some())
}

/// What other threads tell the window's.
enum Message {
    /// The I/O thread has events for [`Connection::deliver`].
    Wake,
    /// A system notification for this thread was clicked.
    #[cfg_attr(not(all(unix, not(target_os = "macos"))), allow(dead_code))]
    Activated(String),
}

/// The window, until it closes.
fn run(app: App, options: Options) -> Result<(), String> {
    let config = ShellConfig::new("HAL-C2").with_size(options.size.0 as f32, options.size.1 as f32);
    app.shell_config(config)
        .on_message(|_: &Engine, _: Message| {})
        .run_with(move |setup| {
            let handle = setup.handle();
            let engine = setup.engine().clone();
            report_warnings(&engine);
            // One wake-up however much waits: the events themselves queue
            // beside the inbox (see mc.rs, folders/watch.rs).
            let folders_handle = handle.clone();
            hal_c2_shell::folders::set_wake(&engine, move || {
                let _ = folders_handle.send_coalesced(CoalesceKey(1), Message::Wake);
            });
            let devices_handle = handle.clone();
            hal_c2_shell::device::set_wake(&engine, move || {
                let _ = devices_handle.send_coalesced(CoalesceKey(1), Message::Wake);
            });
            let plugins_handle = handle.clone();
            hal_c2_shell::controllers::plugin::set_wake(&engine, move || {
                let _ = plugins_handle.send_coalesced(CoalesceKey(1), Message::Wake);
            });
            let transcriber_handle = handle.clone();
            hal_c2_shell::local_transcriber::set_wake(&engine, move || {
                let _ = transcriber_handle.send_coalesced(CoalesceKey(1), Message::Wake);
            });
            let (mc, connection): (Rc<dyn Mc>, _) = match &options.launch.mc_origin {
                Some(origin) => {
                    let wake = handle.clone();
                    let connection = Rc::new(Connection::spawn(move || {
                        let _ = wake.send_coalesced(CoalesceKey(1), Message::Wake);
                    }));
                    connection.open(origin, &options.mc_token)?;
                    (connection.clone(), Some(connection))
                }
                None => (Rc::new(Disconnected::default()), None),
            };
            setup.on_message(move |engine: &Engine, message| match message {
                Message::Wake => {
                    if let Some(connection) = &connection {
                        connection.deliver(engine);
                    }
                    hal_c2_shell::folders::deliver(engine);
                    hal_c2_shell::device::deliver(engine);
                    hal_c2_shell::controllers::plugin::deliver(engine);
                    hal_c2_shell::local_transcriber::deliver(engine);
                    hal_c2_shell::controllers::threads::deliver(engine);
                }
                Message::Activated(key) => {
                    controller::with::<AlertController, _>(engine, |alerts, engine| {
                        alerts.open_thread(engine, &key)
                    });
                }
            });
            hal_c2_shell::start(&engine, &options.launch, mc);
            // The client cache answers a thread's copy on its own thread.
            let threads_handle = handle.clone();
            hal_c2_shell::controllers::threads::set_wake(&engine, move || {
                let _ = threads_handle.send_coalesced(CoalesceKey(1), Message::Wake);
            });
            // Alerts reach the desktop's notification service; a click shows
            // its thread.
            #[cfg(all(unix, not(target_os = "macos")))]
            {
                let clicked = handle.clone();
                // On the listener thread, which may wait for room: a click
                // is not dropped for a full inbox.
                let notifications = NativeNotifications::session(move |key| {
                    let _ = clicked.send_blocking(Message::Activated(key));
                });
                controller::with::<AlertController, _>(&engine, |alerts, _| {
                    alerts.set_presenter(Rc::new(notifications))
                });
            }
            // ScriptedRun: once the shell shows the MC's state, each step in
            // turn, 1.5 s apart.
            let steps = options.steps.clone();
            hal_c2_shell::when_active(&engine, move |engine| scripted_run::play(engine, steps));
            engine
                .create_from_url(ROOT, None, Vec::new())
                .map_err(|e| e.to_string().into())
        })
        .map_err(|e| e.to_string())
}
