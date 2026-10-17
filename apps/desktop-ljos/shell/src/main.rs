//! `hal-c2-ljos`: the HAL-C2 desktop shell on Ljós.
//!
//!   hal-c2-ljos [--mc-origin URL --mc-token TOKEN | --pair LINK]
//!               [--home-dir DIR] [--dev] [--config-dir DIR]
//!               [--qml-dir DIR] [--allow-local-folder-import]
//!               [--action NAME]... [--render PNG [--size WxH] [--settle MS]]
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
//! one `desktop-ljos` level down (src/storage.rs). `--action` dispatches a shell action once the
//! controllers are up, its JSON payload after a space
//! (`settings.open`, `theme.mode {"mode":"dark"}`), for a render of a given
//! place.
//! `--render` writes a picture without opening a window, once the MC's
//! first snapshot is in when there is one. `--check` only
//! compiles the QML, and fails when a file does not compile.

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
use hal_c2_shell::session::{self, Session};
use hal_c2_shell::storage::{Profile, StoragePaths};
use hal_c2_shell::{Launch, store};
use ljos::dev::OnError;
use ljos::prelude::{Engine, LogLevel};
use ljos::render::{Fonts, Picture};
use ljos::{App, ShellConfig};
use ljos_runtime::CoalesceKey;

const ROOT: &str = "Main";
/// How long a render waits for the MC's first snapshot before it shows what
/// the cache kept.
const SNAPSHOT_TIMEOUT: Duration = Duration::from_secs(10);

struct Options {
    launch: Launch,
    mc_token: String,
    roots: Roots,
    actions: Vec<String>,
    check: bool,
    render: Option<PathBuf>,
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
         \x20                  [--allow-local-folder-import] [--action NAME]...\n\
         \x20                  [--render PNG [--size WxH] [--settle MS]]\n\
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
        actions: Vec::new(),
        check: false,
        render: None,
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
            "--action" => o.actions.push(value()?),
            "--check" => o.check = true,
            "--render" => o.render = Some(value()?.into()),
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
    if !options.check
        && let Err(e) = connect_to(&mut options)
    {
        eprintln!("hal-c2-ljos: {e}");
        return ExitCode::FAILURE;
    }
    if options.check {
        return check(&options.roots);
    }
    let source = match qml::compile(&options.roots, OnError::Record) {
        Ok(source) => source,
        Err(e) => {
            eprintln!("hal-c2-ljos: {e}");
            return ExitCode::FAILURE;
        }
    };
    let app = App::new("HAL-C2")
        .register(hal_c2_shell::register)
        .source(source)
        .root(ROOT);
    let result = match &options.render {
        Some(out) => render_to(app, &options, out),
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

/// `--check`: whether every QML file compiles, each error on a line.
fn check(roots: &Roots) -> ExitCode {
    let files = qml::count(roots);
    match qml::compile(roots, OnError::Fail).and(files) {
        Ok(files) => {
            eprintln!("hal-c2-ljos: {files} of {files} QML files compiled");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("hal-c2-ljos: {e}");
            ExitCode::FAILURE
        }
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

fn dispatch_actions(engine: &Engine, actions: &[String]) {
    let bridge = Bridge::of(engine);
    for action in actions {
        let (name, payload) = action.split_once(' ').unwrap_or((action, ""));
        let payload = serde_json::from_str(payload).unwrap_or_else(|e| {
            if !payload.is_empty() {
                eprintln!("hal-c2-ljos: --action {name}: the payload is not JSON ({e}), so none");
            }
            serde_json::Value::Null
        });
        bridge.dispatch(engine, name, payload);
    }
}

/// A picture without a window: the shell once its MC's first snapshot is in
/// (what the cache kept, when the MC does not answer in time), or as it
/// shows disconnected.
fn render_to(app: App, options: &Options, out: &PathBuf) -> Result<(), String> {
    // The bundled font: the same picture on every machine.
    ljos::render::set_fonts(Fonts::Bundled);
    let engine = app.build_engine();
    let picture = Picture::new(options.size.0, options.size.1)
        .settle(options.settle_ms)
        .on_scene_message(|message| eprintln!("scene: {message}"));
    picture.install(&engine);
    report_warnings(&engine);
    let root = match &options.launch.mc_origin {
        Some(origin) => {
            let (woken, wakes) = mpsc::channel();
            let connection = Rc::new(Connection::spawn(move || {
                let _ = woken.send(());
            }));
            connection.open(origin, &options.mc_token)?;
            hal_c2_shell::start(&engine, &options.launch, connection.clone());
            dispatch_actions(&engine, &options.actions);
            let root = engine
                .create_from_url(ROOT, None, Vec::new())
                .map_err(|e| e.to_string())?;
            let deadline = Instant::now() + SNAPSHOT_TIMEOUT;
            while !hal_c2_shell::active(&engine) {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero()
                    || wakes.recv_timeout(left) == Err(mpsc::RecvTimeoutError::Disconnected)
                {
                    let status = connection.client().status();
                    eprintln!(
                        "hal-c2-ljos: no snapshot from {origin} ({:?} {}), so what the cache kept",
                        status.phase, status.failure
                    );
                    break;
                }
                engine.turn(None, || connection.deliver(&engine));
            }
            root
        }
        None => {
            let mc = Rc::new(Disconnected::default());
            hal_c2_shell::start(&engine, &options.launch, mc.clone());
            dispatch_actions(&engine, &options.actions);
            let root = engine
                .create_from_url(ROOT, None, Vec::new())
                .map_err(|e| e.to_string())?;
            mc.deliver(&engine);
            root
        }
    };
    let png = picture.png(&engine, root)?;
    store::flush(&engine);
    if let Some(dir) = out.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::fs::write(out, png).map_err(|e| format!("{}: {e}", out.display()))?;
    eprintln!("hal-c2-ljos: wrote {}", out.display());
    Ok(())
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
                }
                Message::Activated(key) => {
                    controller::with::<AlertController, _>(engine, |alerts, engine| {
                        alerts.open_thread(engine, &key)
                    });
                }
            });
            hal_c2_shell::start(&engine, &options.launch, mc);
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
            dispatch_actions(&engine, &options.actions);
            engine
                .create_from_url(ROOT, None, Vec::new())
                .map_err(|e| e.to_string().into())
        })
        .map_err(|e| e.to_string())
}
