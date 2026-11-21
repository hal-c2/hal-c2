//! `hal-c2-mobile-ljos`: the HAL-C2 phone shell on Ljós.
//!
//!   hal-c2-mobile-ljos --home-dir DIR [--url LINK] [--size WxH]
//!                      [--action NAME[=JSON]]... [--key CHORD]...
//!                      [--render PNG [--settle MS] | --screenshot PNG]
//!   hal-c2-mobile-ljos --check
//!
//! As mobile-qt's main.cpp: a phone runs neither Node nor an MC, so
//! there is no host to find one — the app pairs itself (`pairing`), by a
//! link entered on its pairing screen or `--url`, which spends one as
//! entering it in the app does. A `hal-c2://pair?...` argument is a link
//! from outside the app: shown on the pairing screen, never spent.
//!
//! On a desktop host `--home-dir` is required: the default HAL-C2 home
//! there is the installed desktop app's, and this build must not write
//! its session, drafts and window state into it (`mise run mobile-ljos`
//! passes the checkout's `.hal-c2/mobile-ljos`). `HAL_C2_MOBILE_SIZE`
//! (or `--size`) opens the development window at another size than the
//! root's 412x915; from 736x480 up it is the desktop's layout.
//!
//! `--render` and `--screenshot` take a picture without a window, as
//! desktop-ljos's do: `--action` dispatches a shell action and `--key`
//! presses a window shortcut, in the order given. `--check` only
//! checks the QML, and fails when a file does not compile: the pack
//! build.rs made, or with the `dev-qml` feature the directories.
//!
//! The phone runs the QML build.rs compiled into it (its pack), with
//! the user's `<config>/qml` and `<config>/shell.qml` laid over it, as
//! desktop-ljos does: Main.qml is a ShellLoader of `shell.qml`, the
//! built-in MobileShell when there is none, and each save is applied
//! as the app runs (desktop-ljos's src/runtime.rs). A build with the
//! `dev-qml` feature compiles the QML at start-up instead, from this
//! checkout (`hal_c2_mobile::roots`), with the user's files as they
//! are then; it does not follow saves.

use std::path::PathBuf;
use std::process::ExitCode;
use std::rc::Rc;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::mc::Connection;
#[cfg(feature = "dev-qml")]
use hal_c2_shell::qml::{self, Roots};
use hal_c2_shell::scripted_run::{self, Step};
use hal_c2_shell::storage::{Profile, StoragePaths};
use hal_c2_shell::streams::Pump;
use hal_c2_shell::{Launch, store};
use ljos::prelude::{Engine, LogLevel, Platform};
use ljos::render::{Fonts, Picture};
use ljos::{App, ColorSpace, ShellConfig};

/// The entry: Main.qml, the ShellLoader (desktop-ljos's src/runtime.rs).
const ROOT: &str = hal_c2_shell::runtime::MAIN;
/// How long a render waits for a paired MC's first snapshot before it
/// shows what the cache kept.
const SNAPSHOT_TIMEOUT: Duration = Duration::from_secs(10);

struct Options {
    launch: Launch,
    /// Where a `dev-qml` build compiles the QML from.
    #[cfg(feature = "dev-qml")]
    roots: Roots,
    steps: Vec<Step>,
    check: bool,
    render: Option<PathBuf>,
    screenshot: Option<PathBuf>,
    size: (u32, u32),
    settle_ms: u64,
    home_dir: Option<PathBuf>,
    /// `--url`: pair with the MC this pairing link names, as entering it
    /// in the app does.
    url: Option<String>,
    /// A `hal-c2:` link the app was opened with: shown, never spent.
    offered: Option<String>,
}

fn usage() -> ExitCode {
    eprintln!(
        "usage: hal-c2-mobile-ljos --home-dir DIR [--url LINK] [--size WxH]\n\
         \x20                          [--action NAME[=JSON]]... [--key CHORD]...\n\
         \x20                          [--render PNG [--settle MS] | --screenshot PNG]\n\
         \x20      hal-c2-mobile-ljos --check"
    );
    ExitCode::from(2)
}

fn parse_size(text: &str) -> Option<(u32, u32)> {
    let (w, h) = text.split_once(['x', 'X'])?;
    let side = |s: &str| s.parse::<u32>().ok().filter(|n| (1..=16_384).contains(n));
    side(w).zip(side(h))
}

fn parse() -> Result<Options, String> {
    let mut o = Options {
        launch: Launch::default(),
        #[cfg(feature = "dev-qml")]
        roots: hal_c2_mobile::roots(),
        steps: Vec::new(),
        check: false,
        render: None,
        screenshot: None,
        size: std::env::var("HAL_C2_MOBILE_SIZE")
            .ok()
            .and_then(|size| parse_size(&size))
            .unwrap_or((412, 915)),
        settle_ms: 1500,
        home_dir: None,
        url: None,
        offered: None,
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg.starts_with("hal-c2:") {
            o.offered = Some(arg);
            continue;
        }
        if !arg.starts_with('-') || arg == "-" {
            return Err(format!("unexpected argument {arg}"));
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
            "--home-dir" => o.home_dir = Some(value()?.into()),
            "--url" => o.url = Some(value()?),
            "--check" => o.check = true,
            "--render" => o.render = Some(value()?.into()),
            "--screenshot" => o.screenshot = Some(value()?.into()),
            "--size" => {
                let v = value()?;
                o.size = parse_size(&v).ok_or_else(|| format!("{v:?} is not WxH"))?;
            }
            "--settle" => {
                o.settle_ms = value()?
                    .parse()
                    .map_err(|_| "--settle takes milliseconds".to_owned())?
            }
            "--action" => {
                let (step, note) = Step::action(&value()?);
                if let Some(note) = note {
                    eprintln!("hal-c2-mobile-ljos: {note}");
                }
                o.steps.push(step);
            }
            "--key" => {
                let chord = value()?;
                scripted_run::sequence(&chord).map_err(|e| format!("--key {chord}: {e}"))?;
                o.steps.push(Step::Key(chord));
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
            eprintln!("hal-c2-mobile-ljos: {e}");
            return usage();
        }
    };
    if options.check {
        return check(&options);
    }
    // A phone keeps everything in the app's own storage. On a desktop
    // the binary is a development build of the phone's UI, and the
    // default HAL-C2 home there is the installed desktop app's: it must
    // be told where to keep its files.
    let Some(home) = options.home_dir.clone() else {
        eprintln!(
            "hal-c2-mobile-ljos: --home-dir is needed on a desktop: the default home there belongs to the desktop app."
        );
        return ExitCode::from(2);
    };
    if let Err(stranded) = connect_to(&mut options, home) {
        for what in stranded {
            eprintln!("hal-c2-mobile-ljos: {what}");
        }
        eprintln!(
            "hal-c2-mobile-ljos: not starting, so nothing opens a database without its journal; \
             move the files named together, or delete them all"
        );
        return ExitCode::FAILURE;
    }
    // Browser tabs in a Space or a thread draw through CEF where it can
    // run, as the desktop's do; without it they open in the system
    // browser, which is the phone's way out too.
    match ljos_webengine::unavailable() {
        None => hal_c2_shell::browser::set_supported(true),
        Some(why) => {
            eprintln!("hal-c2-mobile-ljos: browser tabs open in the system browser: {why}")
        }
    }
    let app = App::new("HAL-C2")
        .desktop_file_name("hal-c2-mobile")
        .quit_on_last_window_closed(false)
        .register(hal_c2_mobile::register);
    let app = match with_qml(app, &options) {
        Ok(app) => app,
        Err(e) => {
            eprintln!("hal-c2-mobile-ljos: {e}");
            return ExitCode::FAILURE;
        }
    };
    if let Some(out) = options.screenshot.clone().or(options.render.clone()) {
        return match render_to(app, &options, &out) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("hal-c2-mobile-ljos: {e}");
                ExitCode::from(2)
            }
        };
    }
    match run(app, options) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("hal-c2-mobile-ljos: {e}");
            ExitCode::FAILURE
        }
    }
}

/// The QML the phone runs: the pack build.rs compiled, which the run
/// lays the user's files over (run).
#[cfg(not(feature = "dev-qml"))]
fn with_qml(app: App, options: &Options) -> Result<App, String> {
    // A picture is of the shell as built: only a run follows the user's
    // files, and a picture taken here would pass as the user's shell.
    let picture = options.screenshot.is_some() || options.render.is_some();
    if let Some(config) = options.launch.config_dir.as_deref()
        && picture
        && config.join(hal_c2_shell::runtime::USER_SHELL).is_file()
    {
        eprintln!(
            "hal-c2-mobile-ljos: the picture is of the built-in shell, not {}",
            config.join(hal_c2_shell::runtime::USER_SHELL).display()
        );
    }
    Ok(app.source(hal_c2_mobile::pack()).root(ROOT))
}

/// The QML compiled from the directories now, with the user's files as
/// they are: a `dev-qml` build's, which does not follow saves.
#[cfg(feature = "dev-qml")]
fn with_qml(app: App, options: &Options) -> Result<App, String> {
    // A brick with an error fails only what makes an object of it, as in Qt.
    let dirs = options.roots.dirs()?;
    app.qml_dirs(dirs, ROOT).map_err(|e| e.to_string())
}

/// `--check` of a phone built without `dev-qml`: whether the pack
/// build.rs made holds every QML file build.rs found.
#[cfg(not(feature = "dev-qml"))]
fn check(_: &Options) -> ExitCode {
    let pack = hal_c2_mobile::pack();
    let failed = hal_c2_mobile::unpacked(&pack);
    for (key, why) in &failed {
        eprintln!("hal-c2-mobile-ljos: {key}: {why}");
    }
    let files = hal_c2_mobile::QML_FILES
        .len()
        .max(pack.keys().count() + failed.len());
    eprintln!(
        "hal-c2-mobile-ljos: {} of {files} QML files compiled",
        files - failed.len()
    );
    if failed.is_empty() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

/// `--check`: whether every QML file compiles, what the compiler said a
/// line each, then how many of the files compiled.
#[cfg(feature = "dev-qml")]
fn check(options: &Options) -> ExitCode {
    let compiled = match qml::compile(&options.roots) {
        Ok(compiled) => compiled,
        Err(e) => {
            eprintln!("hal-c2-mobile-ljos: {e}");
            return ExitCode::FAILURE;
        }
    };
    for d in &compiled.diagnostics {
        eprintln!("{d}");
    }
    let failed = compiled.source.failures().count();
    let files = compiled.source.keys().count() + failed;
    eprintln!(
        "hal-c2-mobile-ljos: {} of {files} QML files compiled",
        files - failed
    );
    if failed == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

/// Where the phone keeps what it was sent: one root, `--home-dir`, as
/// mobile-qt resolves it (<home>/config, data, state, cache).
fn connect_to(options: &mut Options, home: PathBuf) -> Result<(), Vec<String>> {
    let paths = StoragePaths::resolve(Some(&home), Profile::Installed);
    let stranded = hal_c2_shell::storage::carry_over(&paths);
    if !stranded.is_empty() {
        return Err(stranded);
    }
    let config_dir = paths.shell.clone();
    let _ = std::fs::create_dir_all(&config_dir);
    // A `dev-qml` build compiles its `qml` and `shell.qml` with the rest;
    // otherwise the run lays them over the pack (run).
    #[cfg(feature = "dev-qml")]
    {
        options.roots = options.roots.clone().with_user(config_dir.clone());
    }
    options.launch.config_dir = Some(config_dir);
    options.launch.cache_dir = Some(paths.cache);
    options.launch.data_dir = Some(paths.data);
    options.launch.state_dir = Some(paths.state);
    Ok(())
}

/// Starts the shell over a connection the pairing opens: no MC until the
/// phone pairs with one (or remembers one), so the controllers show the
/// pairing screen's world at once, as the Qt client's do.
fn start_shell(engine: &Engine, options: &Options, mc: Rc<dyn hal_c2_shell::mc::Mc>) {
    hal_c2_mobile::install(
        engine,
        options.launch.data_dir.clone(),
        options.launch.config_dir.clone(),
    );
    hal_c2_shell::start_with(engine, &options.launch, mc, hal_c2_mobile::registrations());
    // The MC's folders are never this device's (MobileApp).
    Bridge::of(engine).set_local_folder_import_enabled(engine, false);
    // An in-app pairing and a refused session name this device.
    hal_c2_shell::controller::with::<
        hal_c2_shell::controllers::connection_health::ConnectionHealth,
        _,
    >(engine, |health, _| {
        health.set_pairing_client(hal_c2_mobile::device())
    });
    hal_c2_mobile::start(engine);
    if let Some(link) = &options.url {
        Bridge::of(engine).dispatch(engine, "pairing.pair", serde_json::json!({"link": link}));
    }
    if let Some(link) = &options.offered {
        hal_c2_mobile::pairing::offer_link(engine, link);
    }
}

/// What the QML says that is wrong, on stderr, each message once.
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

/// A picture without a window: the pairing screen when the phone has no
/// environment, else the shell once its MC's first snapshot is in (what
/// the cache kept, when the MC does not answer in time).
fn render_to(app: App, options: &Options, out: &PathBuf) -> Result<(), String> {
    ljos::render::set_fonts(Fonts::Bundled);
    let engine = app.build_engine();
    // As the window's shell does: the `Window` Main.qml's loader shows
    // gets a window of its own, where its popups find their overlay.
    // Before it is made: a `Window` made unhosted stays an item of the
    // loader for good.
    ljos_controls::WindowSystem::of(&engine).set_host(|| {});
    let settle = if options.screenshot.is_some() {
        scripted_run::timetable(options.steps.len()).1.as_millis() as u64
    } else {
        options.settle_ms
    };
    let picture = Picture::new(options.size.0, options.size.1).settle(settle);
    picture.install(&engine);
    report_warnings(&engine);
    let (woken, wakes) = mpsc::channel();
    // The pairing exchange answers through the platform's inbox (an
    // `ljos::task`), which a window drains each frame; here the wait
    // below drains it, woken as the side streams wake it.
    let answered = woken.clone();
    Platform::of(&engine).set_waker(move || {
        let _ = answered.send(());
    });
    let mut pump = Pump::new(move || {
        let _ = woken.send(());
    });
    let wired = hal_c2_shell::streams::wire(&engine, &mut pump);
    let connection = Connection::spawn(&wired.mc);
    start_shell(&engine, options, connection.clone());
    hal_c2_shell::controllers::threads::set_wake(&engine, wired.local_cache.waker());
    hal_c2_shell::theme::set_application_font(&engine);
    hal_c2_shell::runtime::open(&engine)?;
    // The window a picture is of: what Main.qml's ShellLoader shows.
    let root = hal_c2_shell::runtime::window(&engine).ok_or_else(|| {
        let why = hal_c2_shell::runtime::user_shell_failed(&engine).unwrap_or_default();
        format!("no shell to draw: {why}")
    })?;
    // A paired phone waits for its MC's first snapshot (or a `--url`
    // pairing to land); the pairing screen is all an unpaired one shows.
    // The shell starts with no MC of its own (the phone opens the one it
    // paired with), so it is active at once: the store's first
    // synchronization is the snapshot to wait for, not activation.
    let paired = |engine: &Engine| {
        Bridge::of(engine)
            .published(engine, "pairing")
            .and_then(|pairing| pairing.get("phase").cloned())
            .and_then(|phase| phase.as_str().map(|p| p == "paired"))
            .unwrap_or(false)
    };
    // A `--url` pairing that failed (unreachable, refused, not saved)
    // is back on the pairing screen with its error: nothing to wait for.
    let pairing_error = |engine: &Engine| {
        Bridge::of(engine)
            .published(engine, "pairing")
            .and_then(|pairing| pairing.get("error").cloned())
            .and_then(|error| error.as_str().map(str::to_owned))
            .unwrap_or_default()
    };
    let deadline = Instant::now() + SNAPSHOT_TIMEOUT;
    loop {
        Platform::of(&engine).deliver(&engine);
        pump.pump(&engine);
        let pairing_busy = Bridge::of(&engine)
            .published(&engine, "pairing")
            .and_then(|pairing| pairing.get("phase").cloned())
            .and_then(|phase| phase.as_str().map(|p| p == "pairing"))
            .unwrap_or(false);
        // Paired or not: a device that keeps a session stays paired with
        // it when the link fails, and the picture would hide that.
        if !pairing_busy && options.url.is_some() {
            let error = pairing_error(&engine);
            if !error.is_empty() {
                return Err(format!("pairing failed: {error}"));
            }
        }
        let waiting = pairing_busy
            || options.url.is_some() && !paired(&engine)
            || paired(&engine)
                && (!store::with(&engine, |s| s.synchronized())
                    || hal_c2_shell::controllers::threads::loading(&engine));
        if !waiting {
            break;
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() || wakes.recv_timeout(left) == Err(mpsc::RecvTimeoutError::Disconnected) {
            let status = connection.client().status();
            eprintln!(
                "hal-c2-mobile-ljos: no snapshot yet ({:?} {}), so what the shell shows now",
                status.phase, status.failure
            );
            hal_c2_shell::controllers::threads::drain(&engine);
            break;
        }
    }
    for (side, length) in [("width", options.size.0), ("height", options.size.1)] {
        engine
            .write_by_name(root, side, ljos::prelude::Value::Real(f64::from(length)))
            .map_err(|e| format!("the window's {side}: {e:?}"))?;
    }
    if options.screenshot.is_some() {
        scripted_run::play(&engine, options.steps.clone());
    } else {
        for step in &options.steps {
            scripted_run::run(&engine, step);
        }
        // What a step asked the MC for (thread.open's thread) is waited
        // for as the snapshot was, so the picture shows it.
        let deadline = Instant::now() + SNAPSHOT_TIMEOUT;
        loop {
            Platform::of(&engine).deliver(&engine);
            pump.pump(&engine);
            if !hal_c2_shell::controllers::threads::loading(&engine) {
                break;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero()
                || wakes.recv_timeout(left) == Err(mpsc::RecvTimeoutError::Disconnected)
            {
                eprintln!(
                    "hal-c2-mobile-ljos: a step's thread did not load, so what the shell shows now"
                );
                hal_c2_shell::controllers::threads::drain(&engine);
                break;
            }
        }
    }
    let png = picture.png(&engine, root).map_err(|e| e.to_string())?;
    store::flush(&engine);
    if let Some(dir) = out.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::fs::write(out, png).map_err(|e| format!("{}: {e}", out.display()))?;
    eprintln!("hal-c2-mobile-ljos: wrote {}", out.display());
    Ok(())
}

/// The window, until it closes.
fn run(app: App, options: Options) -> Result<(), String> {
    #[derive(Debug)]
    enum Message {}
    let config = ShellConfig::new("HAL-C2")
        .with_size(options.size.0 as f32, options.size.1 as f32)
        .with_color_space(ColorSpace::Untagged);
    let headless = std::env::var("QT_QPA_PLATFORM").is_ok_and(|v| v == "offscreen");
    let app = with_user_files(app, &options)
        .shell_config(config)
        .on_message(|_: &Engine, _: Message| {});
    let options = Rc::new(options);
    let setup = move |setup: &mut ljos::Setup<'_, Message>| {
        let engine = setup.engine().clone();
        report_warnings(&engine);
        let wired = hal_c2_shell::streams::wire(&engine, setup);
        hal_c2_shell::clock::set_wake(&engine, wired.clock.waker());
        let connection = Connection::spawn(&wired.mc);
        start_shell(&engine, &options, connection.clone());
        hal_c2_shell::controllers::threads::set_wake(&engine, wired.local_cache.waker());
        // ScriptedRun: once the shell shows, each step in turn, 1.5 s
        // apart; an unpaired phone has no snapshot to wait for.
        let steps = options.steps.clone();
        hal_c2_shell::when_active(&engine, move |engine| scripted_run::play(engine, steps));
        hal_c2_shell::theme::set_application_font(&engine);
        // Each save of the user's files that was applied, or failed:
        // Runtime's lastError and the window's shell follow it.
        let weak = engine.downgrade();
        setup.on_user_report(move |_| {
            if let Some(engine) = weak.upgrade() {
                hal_c2_shell::runtime::reloaded(&engine);
            }
        });
        hal_c2_shell::runtime::set_hot_reload_enabled(&engine, cfg!(not(feature = "dev-qml")));
        // Main.qml's ShellLoader: the user's shell or the built-in one.
        hal_c2_shell::runtime::open(&engine).map_err(Into::into)
    };
    let result = if headless {
        app.run_headless_with(setup)
    } else {
        app.run_with(setup)
    };
    result.map_err(|e| e.to_string())
}

/// The user's `<config>` over the pack, followed as it is saved
/// (`hal_c2_shell::user_qml`), as desktop-ljos's run lays it.
#[cfg(not(feature = "dev-qml"))]
fn with_user_files(app: App, options: &Options) -> App {
    match hal_c2_shell::user_qml(&options.launch) {
        Some(user) => {
            app.user_qml(user.on_fault(|fault| eprintln!("hal-c2-mobile-ljos: {fault}")))
        }
        None => app,
    }
}

/// A `dev-qml` build compiled the user's files with the rest (with_qml).
#[cfg(feature = "dev-qml")]
fn with_user_files(app: App, _: &Options) -> App {
    app
}
