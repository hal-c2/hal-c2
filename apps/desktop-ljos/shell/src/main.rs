//! `hal-c2-ljos`: the HAL-C2 desktop shell on Ljós.
//!
//!   hal-c2-ljos [--url LINK | --mc-origin URL --mc-token TOKEN | --pair LINK]
//!               [--home-dir DIR] [--dev] [--app-id ID] [--config-dir DIR]
//!               [--qml-dir DIR] [--host-entry FILE] [--node PATH]
//!               [--allow-local-folder-import]
//!               [--action NAME[=JSON]]... [--key CHORD]...
//!               [--render PNG [--size WxH] [--settle MS]]
//!               [--screenshot PNG [--size WxH]] [FOLDER | HOST-ARGUMENT]...
//!   hal-c2-ljos --check [--qml-dir DIR]
//!
//! As desktop-qt's main.cpp, the shell runs the desktop host
//! (`apps/desktop-qt/host/main.ts`, `--host-entry`, under `--node`, else
//! HAL_C2_NODE_BIN, else `node`), which finds or starts the MC on this
//! machine and names it once it answers (src/desktop_host.rs). `--url`
//! has the host pair with the MC a pairing link names instead. What the
//! command line passes that is not a folder goes to the host.
//!
//! `--mc-origin` and `--mc-token` (HAL_C2_MC_ORIGIN, HAL_C2_MC_TOKEN)
//! connect to an MC without a host, and `--pair` spends a pairing link on
//! a session here; both are this shell's own, for tests and renders.
//!
//! A folder named while the app already runs on this home goes to that
//! window, which adds it as a project (or finds it) and starts a thread
//! there, and this launch ends (src/single_instance.rs). The app's own
//! folders open once the MC's first snapshot is in.
//!
//! What the shell keeps (the client cache, its drafts) is under
//! `--home-dir`, or the XDG directories (`hal-c2-dev` ones with `--dev`),
//! one `desktop-ljos` level down (src/storage.rs). A shell built from
//! source (no HAL_C2_RELEASE when it was built) or started with `--dev`
//! is Dev: its own icon and app id (`hal-c2-dev`, unless `--app-id`).
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
//!
//! The QML is read from `--qml-dir` (a release's), else HAL_C2_QML_DIR,
//! else this checkout, with the user's `<config>/qml` and `<config>/shell.qml`.
//! The window makes its shell again as they change (src/runtime.rs).

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::rc::Rc;
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use hal_c2_mc::pairing;
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller;
use hal_c2_shell::controllers::alerts::AlertController;
use hal_c2_shell::controllers::connection_health::ConnectionHealth;
use hal_c2_shell::controllers::desktop_update;
use hal_c2_shell::controllers::onboarding::Onboarding;
use hal_c2_shell::desktop_host::DesktopHost;
use hal_c2_shell::mc::{Connection, Disconnected, Mc};
#[cfg(all(unix, not(target_os = "macos")))]
use hal_c2_shell::notifications::NativeNotifications;
use hal_c2_shell::qml::{self, Roots};
use hal_c2_shell::scripted_run::{self, Step};
use hal_c2_shell::session::Session;
use hal_c2_shell::storage::{Profile, StoragePaths};
use hal_c2_shell::{Launch, desktop_host, single_instance, store};
use ljos::CoalesceKey;
use ljos::prelude::{Engine, LogLevel};
use ljos::render::{Fonts, Picture};
use ljos::{App, ColorSpace, ShellConfig};

const ROOT: &str = qml::DEFAULT_SHELL;
/// The desktop entry the release installs (hal-c2.desktop), as desktop-qt
/// names it.
const APP_ID: &str = "hal-c2";
/// A development shell's (main.cpp).
const DEV_APP_ID: &str = "hal-c2-dev";
/// A packaged build sets HAL_C2_RELEASE as it builds, as CMake's Release
/// configuration is desktop-qt's; any other build is a development shell.
const RELEASE: bool = option_env!("HAL_C2_RELEASE").is_some();
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
    /// `--dev`: the development profile's files.
    dev: bool,
    pair: Option<String>,
    /// `--url`: the pairing link the host attaches to.
    url: Option<String>,
    app_id: Option<String>,
    host: desktop_host::Options,
    /// `--licenses`, which the manifest beside the host does not replace.
    licenses_given: bool,
    /// The folders the launch names, as absolute paths.
    folders: Vec<String>,
    /// Where later launches reach this one (the home's state directory).
    state_dir: PathBuf,
}

fn usage() -> ExitCode {
    eprintln!(
        "usage: hal-c2-ljos [--url LINK | --mc-origin URL --mc-token TOKEN | --pair LINK]\n\
         \x20                  [--home-dir DIR] [--dev] [--app-id ID] [--config-dir DIR]\n\
         \x20                  [--qml-dir DIR] [--host-entry FILE] [--node PATH] [--licenses MANIFEST]\n\
         \x20                  [--allow-local-folder-import] [--action NAME[=JSON]]... [--key CHORD]...\n\
         \x20                  [--render PNG [--size WxH] [--settle MS]]\n\
         \x20                  [--screenshot PNG [--size WxH]] [FOLDER | HOST-ARGUMENT]...\n\
         \x20      hal-c2-ljos --check [--qml-dir DIR]"
    );
    ExitCode::from(2)
}

fn parse() -> Result<Options, String> {
    // main.cpp: `--qml-dir`, else HAL_C2_QML_DIR, else the source tree.
    let roots = std::env::var_os("HAL_C2_QML_DIR")
        .filter(|d| !d.is_empty())
        .map_or_else(Roots::checkout, |dir| Roots::one(dir.into()));
    let mut o = Options {
        launch: Launch {
            mc_origin: std::env::var("HAL_C2_MC_ORIGIN")
                .ok()
                .filter(|s| !s.is_empty()),
            ..Launch::default()
        },
        mc_token: std::env::var("HAL_C2_MC_TOKEN").unwrap_or_default(),
        roots,
        steps: Vec::new(),
        check: false,
        render: None,
        screenshot: None,
        size: (1280, 800),
        settle_ms: 1500,
        home_dir: None,
        dev: false,
        pair: None,
        url: None,
        app_id: None,
        host: desktop_host::Options::default(),
        licenses_given: false,
        folders: Vec::new(),
        state_dir: PathBuf::new(),
    };
    let executable_dir = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(Path::to_path_buf))
        .unwrap_or_default();
    let mut host_entry = None;
    let mut node = None;
    let mut positional = Vec::new();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        // Not an option: a folder to open, or the host's.
        if arg == "--" {
            positional.extend(args.by_ref());
            break;
        }
        if !arg.starts_with('-') || arg == "-" {
            positional.push(arg);
            continue;
        }
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
            "--url" => o.url = Some(value()?),
            "--app-id" => o.app_id = Some(value()?).filter(|id| !id.trim().is_empty()),
            "--host-entry" => host_entry = Some(PathBuf::from(value()?)),
            "--node" => node = Some(PathBuf::from(value()?)),
            "--mc-origin" => o.launch.mc_origin = Some(value()?),
            "--mc-token" => o.mc_token = value()?,
            "--pair" => o.pair = Some(value()?),
            "--home-dir" => o.home_dir = Some(value()?.into()),
            "--dev" => o.dev = true,
            "--config-dir" => o.launch.config_dir = Some(value()?.into()),
            "--qml-dir" => o.roots = Roots::one(value()?.into()),
            "--licenses" => {
                o.launch.licenses_manifest = Some(value()?.into());
                o.licenses_given = true;
            }
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
    if o.url.is_some() && (o.pair.is_some() || o.launch.mc_origin.is_some()) {
        return Err(
            "--url has the host attach to an MC; --pair and --mc-origin name one without it".into(),
        );
    }
    o.host.entry =
        host_entry.unwrap_or_else(|| desktop_host::default_entry(&executable_dir, RELEASE));
    o.host.node = node.unwrap_or_else(|| {
        let from_env = std::env::var("HAL_C2_NODE_BIN").ok();
        desktop_host::default_node(&executable_dir, RELEASE, from_env.as_deref())
    });
    // Staged beside the host (scripts/stage-runtime.mjs), or `vp run
    // licenses`'s apps/desktop-qt/licenses/ in a checkout.
    if !o.licenses_given {
        o.launch.licenses_manifest = Some(desktop_host::licenses_beside(&o.host.entry));
    }
    // The folders are the shell's own; the rest is the host's (connect_to).
    let (folders, rest) = hal_c2_shell::launch_folders(&positional);
    o.folders = folders;
    o.host.arguments = rest;
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
    // A folder named while the app already runs on this home goes to that
    // window, and this launch ends here: no second MC starts.
    if !options.folders.is_empty() && single_instance::forward(&options.state_dir, &options.folders)
    {
        return ExitCode::SUCCESS;
    }
    // Pages draw in the panel's browser tabs where CEF can run.
    match ljos_webengine::unavailable() {
        None => hal_c2_shell::browser::set_supported(true),
        Some(why) => eprintln!("hal-c2-ljos: browser tabs open in the system browser: {why}"),
    }
    // A brick with an error fails only what makes an object of it, as in Qt.
    let app = match options.roots.dirs().and_then(|dirs| {
        // The shell says when closing a window ends the app
        // (controller::attach_root).
        App::new("HAL-C2")
            // The Wayland app id and X11 class by which docks find the
            // entry's icon and compositor rules find the window.
            .desktop_file_name(app_id(&options))
            .quit_on_last_window_closed(false)
            .register(hal_c2_shell::register)
            .qml_dirs(dirs, ROOT)
            .map_err(|e| e.to_string())
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
/// one named, else the one `--pair` pairs with, else the one the desktop
/// host names (main.cpp's BackendProcess).
fn connect_to(options: &mut Options) -> Result<(), String> {
    // A shell built from source, or one on the development profile, is
    // Dev (StageController), so it is never mistaken for the installed app.
    hal_c2_shell::controllers::stage::set_app_stage(if dev(options) { "Dev" } else { "" });
    let profile = if options.dev {
        Profile::Development
    } else {
        Profile::Installed
    };
    let paths = StoragePaths::resolve(options.home_dir.as_deref(), profile);
    // The user's theme, plugins, preferences and shell sit in the config
    // home's `shell`, desktop-qt's too, unless `--config-dir` names another.
    // Made up front so their watchers are live from the start (main.cpp).
    let config_dir = options
        .launch
        .config_dir
        .take()
        .unwrap_or_else(|| paths.shell.clone());
    let _ = std::fs::create_dir_all(&config_dir);
    // Its `qml` and `shell.qml` join the QML the shell is made of.
    options.roots = options.roots.clone().with_user(config_dir.clone());
    options.launch.qml = Some(options.roots.clone());
    options.launch.config_dir = Some(config_dir);
    if let Some(link) = &options.pair {
        let kept = pair(link)?;
        options.launch.mc_origin = Some(kept.origin);
        options.mc_token = kept.token;
    }
    // main.cpp's host arguments: the link to attach to, the development
    // profile (the host starts no MC release for one without a root), the
    // root, and the rest of the command line.
    let passed = std::mem::take(&mut options.host.arguments);
    options.host.arguments = desktop_host::arguments(
        options.url.as_deref(),
        options.dev,
        paths.root.as_deref(),
        &passed,
    );
    options.launch.hosted = options.launch.mc_origin.is_none();
    options.state_dir = paths.state.clone();
    options.launch.cache_dir = Some(paths.cache);
    options.launch.data_dir = Some(paths.data);
    options.launch.state_dir = Some(paths.state);
    Ok(())
}

/// A shell built from source or started with `--dev` (main.cpp).
fn dev(options: &Options) -> bool {
    !RELEASE || options.dev
}

/// The app id: `--app-id`, else a development shell's, else the release's.
fn app_id(options: &Options) -> &str {
    match &options.app_id {
        Some(id) => id.trim(),
        None if dev(options) => DEV_APP_ID,
        None => APP_ID,
    }
}

/// Spends `link` on a session with its MC.
fn pair(link: &str) -> Result<Session, String> {
    let parsed = pairing::read_invitation(link)
        .and_then(|i| pairing::read_link(&i.link))
        .or_else(|| pairing::read_link(link))
        .ok_or_else(|| format!("{link:?} is not a pairing link"))?;
    let result = pairing::exchange(&parsed, &pairing_client());
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
    eprintln!("hal-c2-ljos: paired with {} at {}", kept.label, kept.origin);
    Ok(kept)
}

/// What this desktop says it is to the MC it pairs with.
fn pairing_client() -> pairing::Client {
    pairing::Client {
        label: format!("HAL-C2 desktop on {}", host_name()),
        device_type: "desktop".into(),
        os: match std::env::consts::OS {
            "linux" => "Linux",
            "macos" => "macOS",
            "windows" => "Windows",
            other => other,
        }
        .into(),
    }
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

/// What the QML says that is wrong, on stderr, each message once, and which
/// window each generation of a reloaded shell took (`hal_c2.shell`).
fn report_warnings(engine: &Engine) {
    let seen = std::cell::RefCell::new(std::collections::HashSet::new());
    engine.set_log_handler(move |entry| {
        if entry.level == LogLevel::Info && entry.category == "hal_c2.shell" {
            eprintln!("shell: {}", entry.message);
        } else if matches!(entry.level, LogLevel::Warning | LogLevel::Critical) {
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
    let picture = Picture::new(options.size.0, options.size.1).settle(capture.settle_ms);
    picture.install(&engine);
    report_warnings(&engine);
    let mut launch = options.launch.clone();
    // TODO(#1572): a picture is of the MC named, not one the
    // desktop host finds; without one it is the shell with none.
    launch.hosted = false;
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
            hal_c2_shell::theme::set_application_font(&engine);
            let root = hal_c2_shell::runtime::open(&engine, false)?;
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
            hal_c2_shell::theme::set_application_font(&engine);
            let root = hal_c2_shell::runtime::open(&engine, false)?;
            // Once the bricks are there, as with an MC: what opens on a
            // signal (the palette's popup) misses one sent before.
            if !capture.play_after_snapshot {
                play(&engine, &capture.steps);
            }
            mc.deliver(&engine);
            root
        }
    };
    // The window as large as the picture: ShellWindow says a size of its own,
    // which the picture would otherwise crop or leave blank around.
    for (side, length) in [("width", options.size.0), ("height", options.size.1)] {
        engine
            .write_by_name(root, side, ljos::prelude::Value::Real(f64::from(length)))
            .map_err(|e| format!("the window's {side}: {e:?}"))?;
    }
    if capture.play_after_snapshot {
        // On the picture's virtual clock: they all run while it settles.
        scripted_run::play(&engine, capture.steps.clone());
    }
    let png = picture.png(&engine, root).map_err(|e| e.to_string())?;
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
    /// What the desktop host said: the MC it found or started, or why it
    /// has none.
    Host(desktop_host::Event),
    /// The folders a later launch handed over (src/single_instance.rs).
    Folders(Vec<String>),
    /// The updater's quit, queued as main.cpp's is: not inside the call
    /// that asked for it.
    Quit,
}

/// The window, until it closes.
fn run(app: App, options: Options) -> Result<(), String> {
    // An inspected shell lets any of the user's processes sample its stacks
    // (eu-stack -p PID), not only its parent as Yama's ptrace_scope=1 has it:
    // a UI thread stuck in a turn answers no inspector tool.
    #[cfg(all(feature = "mcp", target_os = "linux"))]
    // SAFETY: prctl with these arguments only changes who may ptrace this process.
    unsafe {
        libc::prctl(libc::PR_SET_PTRACER, libc::PR_SET_PTRACER_ANY, 0, 0, 0);
    }
    // Read once and kept. On macOS and Windows that runs a command, which
    // the UI thread's first ask would otherwise wait for.
    std::thread::spawn(hal_c2_shell::this_machine::id);
    // Untagged, as Qt Quick's windows are, so the shell's colours look on a
    // wide-gamut display as desktop-qt's do (LJOS_COLOR_SPACE overrides).
    // main.cpp: a launch from source gets its own desktop entry, so its
    // windows have the dev icon in docks and switchers.
    #[cfg(all(unix, not(target_os = "macos")))]
    if dev(&options) && options.app_id.is_none() {
        install_dev_desktop_entry();
    }
    // The host outlives the window: it is stopped once the app has quit
    // (main.cpp's aboutToQuit).
    let hosted: Rc<std::cell::RefCell<Option<Arc<DesktopHost>>>> = Rc::default();
    let host_slot = hosted.clone();
    // A software EGL draws with the CPU painter on its own (ljos_shell's
    // software.rs, LJOS_PAINTER overrides), main.cpp's Software API.
    // TODO(hal-c2/ljos-ui#458): with no display at all main.cpp runs on
    // Qt's offscreen platform; ljos::App has no headless run to choose.
    let config = ShellConfig::new("HAL-C2")
        .with_size(options.size.0 as f32, options.size.1 as f32)
        .with_color_space(ColorSpace::Untagged);
    let result = app
        .shell_config(config)
        .on_message(|_: &Engine, _: Message| {})
        .run_with(move |setup| {
            let handle = setup.handle();
            let engine = setup.engine().clone();
            report_warnings(&engine);
            // A turn that runs long says which of these it ran.
            setup.name_messages(|message| match message {
                Message::Wake => "Wake",
                Message::Activated(_) => "Activated",
                Message::Host(_) => "Host",
                Message::Folders(_) => "Folders",
                Message::Quit => "Quit",
            });
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
            let theme_handle = handle.clone();
            hal_c2_shell::theme::set_wake(&engine, move || {
                let _ = theme_handle.send_coalesced(CoalesceKey(1), Message::Wake);
            });
            let runtime_handle = handle.clone();
            hal_c2_shell::runtime::set_wake(&engine, move || {
                let _ = runtime_handle.send_coalesced(CoalesceKey(1), Message::Wake);
            });
            let update_handle = handle.clone();
            hal_c2_shell::controllers::desktop_update::set_wake(&engine, move || {
                let _ = update_handle.send_coalesced(CoalesceKey(1), Message::Wake);
            });
            let settings_handle = handle.clone();
            hal_c2_shell::controllers::settings::set_wake(&engine, move || {
                let _ = settings_handle.send_coalesced(CoalesceKey(1), Message::Wake);
            });
            // A connection even without an MC to open it at: the welcome
            // wizard or Connections settings may pair with one later
            // (hal_c2_shell::open).
            let wake = handle.clone();
            let connection = Rc::new(Connection::spawn(move || {
                let _ = wake.send_coalesced(CoalesceKey(1), Message::Wake);
            }));
            if let Some(origin) = &options.launch.mc_origin {
                connection.open(origin, &options.mc_token)?;
            }
            let mc: Rc<dyn Mc> = connection.clone();
            // Later launches on this home hand their folders to this window.
            let folders_handle = handle.clone();
            let listener = single_instance::listen(&options.state_dir, move |folders| {
                let _ = folders_handle.send_blocking(Message::Folders(folders));
            });
            if listener.is_none() {
                eprintln!("[shell] later launches cannot reach this window");
            }
            setup.on_message(move |engine: &Engine, message| match message {
                Message::Wake => {
                    connection.deliver(engine);
                    hal_c2_shell::folders::deliver(engine);
                    hal_c2_shell::device::deliver(engine);
                    hal_c2_shell::controllers::plugin::deliver(engine);
                    hal_c2_shell::local_transcriber::deliver(engine);
                    hal_c2_shell::theme::deliver(engine);
                    hal_c2_shell::runtime::deliver(engine);
                    hal_c2_shell::controllers::threads::deliver(engine);
                    hal_c2_shell::controllers::snap_shot::deliver(engine);
                    hal_c2_shell::controllers::desktop_update::deliver(engine);
                    hal_c2_shell::controllers::settings::deliver(engine);
                }
                Message::Activated(key) => {
                    controller::with::<AlertController, _>(engine, |alerts, engine| {
                        alerts.open_thread(engine, &key)
                    });
                }
                Message::Host(event) => hosted_said(engine, event),
                Message::Folders(folders) => {
                    // Kept for as long as messages come: the socket closes
                    // with it.
                    let _ = &listener;
                    hal_c2_shell::open_folders(engine, &folders);
                }
                Message::Quit => engine.request_quit(),
            });
            hal_c2_shell::start(&engine, &options.launch, mc);
            if options.url.is_some() {
                // main.cpp: an MC a link names may be another machine's, so
                // this one's folders are imported only when told.
                Bridge::of(&engine).set_local_folder_import_enabled(
                    &engine,
                    options.launch.allow_local_folder_import,
                );
            }
            let icon = PathBuf::from(hal_c2_shell::platform_window::DEV_ICON);
            hal_c2_shell::platform_window::give_application_icon(
                &engine,
                (dev(&options) && icon.is_file()).then_some(icon),
            );
            if options.launch.hosted {
                let said = handle.clone();
                let host = Arc::new(DesktopHost::new(options.host.clone(), move |event| {
                    let _ = said.send_blocking(Message::Host(event));
                }));
                // The updater stops the MC to replace it, starts it again
                // when it could not, and quits to restart (main.cpp).
                let (stopping, starting, quitting) = (host.clone(), host.clone(), handle.clone());
                desktop_update::update_platform(|platform| {
                    platform.stop_mc = Some(Rc::new(move || stopping.stop()));
                    platform.start_mc = Some(Rc::new(move || starting.start()));
                    platform.quit = Some(Rc::new(move || {
                        let _ = quitting.send(Message::Quit);
                    }));
                });
                host.start();
                *host_slot.borrow_mut() = Some(host);
            }
            // The app's own folders, once the MC's first snapshot is in.
            let folders = options.folders.clone();
            if !folders.is_empty() {
                hal_c2_shell::when_active(&engine, move |engine| {
                    hal_c2_shell::open_folders(engine, &folders)
                });
            }
            // desktop-qt's ShellWindows: `window.new`, the "New window"
            // command and the saved windows each show a root of their own.
            controller::set_window_opener(&engine, hal_c2_shell::runtime::open_window);
            // An in-app pairing names this desktop as `--pair` does.
            controller::with::<ConnectionHealth, _>(&engine, |health, _| {
                health.set_pairing_client(pairing_client())
            });
            controller::with::<Onboarding, _>(&engine, |onboarding, _| {
                onboarding.set_pairing_client(pairing_client())
            });
            // The client cache answers a thread's copy on its own thread.
            let threads_handle = handle.clone();
            hal_c2_shell::controllers::threads::set_wake(&engine, move || {
                let _ = threads_handle.send_coalesced(CoalesceKey(1), Message::Wake);
            });
            // Snapshots capture through the desktop session's portals; what
            // they learn on their own threads wakes the window's.
            let snap_shot_handle = handle.clone();
            let snap_shot =
                hal_c2_shell::snap_shot::system(options.launch.cache_dir.clone(), move || {
                    let _ = snap_shot_handle.send_coalesced(CoalesceKey(1), Message::Wake);
                });
            controller::with::<hal_c2_shell::controllers::snap_shot::SnapShot, _>(
                &engine,
                |c, e| c.set_backend(e, snap_shot),
            );
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
            // The saved theme's interface font, for all the root makes.
            hal_c2_shell::theme::set_application_font(&engine);
            // The user's shell or the built-in one, made again as their
            // files change.
            let root = hal_c2_shell::runtime::open(&engine, true);
            // The others saved open reopen once the first shows
            // (NativeShell::restoreWindows after windows.start()).
            if root.is_ok() {
                controller::restore_windows(&engine);
            }
            root.map_err(Into::into)
        })
        .map_err(|e| e.to_string());
    if let Some(host) = hosted.borrow_mut().take() {
        host.stop();
    }
    result
}

/// BackendProcess's signals as NativeShell takes them: the MC the host
/// named is opened, and why there is none shows in ShellErrorOverlay.
fn hosted_said(engine: &Engine, event: desktop_host::Event) {
    let failure = match event {
        desktop_host::Event::Ready { origin, token } => {
            let session = Session {
                origin,
                token,
                label: String::new(),
                environment_id: String::new(),
            };
            hal_c2_shell::attach(engine, &session).err()
        }
        desktop_host::Event::Failed(message) => Some(message),
    };
    if let Some(message) = failure {
        eprintln!("[shell] {message}");
        Bridge::of(engine).publish(engine, "backendError", message.into());
    }
}

/// main.cpp's installDevDesktopEntry: `hal-c2-dev.desktop` and its icon in
/// the user's data home, naming this binary.
#[cfg(all(unix, not(target_os = "macos")))]
fn install_dev_desktop_entry() {
    let icon = Path::new(hal_c2_shell::platform_window::DEV_ICON);
    let data = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|d| d.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")));
    let (Some(data), Ok(binary)) = (data, std::env::current_exe()) else {
        return;
    };
    if !icon.is_file() {
        return;
    }
    if let Err(e) =
        hal_c2_shell::platform_window::install_dev_desktop_entry(&data, DEV_APP_ID, icon, &binary)
    {
        eprintln!("hal-c2-ljos: the dev desktop entry: {e}");
    }
}
