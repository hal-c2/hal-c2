//! `hal-c2-ljos`: the HAL-C2 desktop shell on Ljós.
//!
//!   hal-c2-ljos [--mc-origin URL --mc-token TOKEN] [--config-dir DIR]
//!               [--qml-dir DIR] [--allow-local-folder-import]
//!               [--action NAME]... [--render PNG [--size WxH] [--settle MS]]
//!   hal-c2-ljos --check [--qml-dir DIR]
//!
//! The MC is the one host/main.ts would hand desktop-qt: its origin and
//! token, also read from HAL_C2_MC_ORIGIN and HAL_C2_MC_TOKEN. With none the
//! shell runs disconnected. `--action` dispatches a shell action once the
//! controllers are up, its JSON payload after a space
//! (`settings.open`, `theme.mode {"mode":"dark"}`), for a render of a given
//! place.
//! `--render` writes a picture without opening a window. `--check` only
//! compiles the QML, and fails when a file does not compile.

use std::path::PathBuf;
use std::process::ExitCode;
use std::rc::Rc;

use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::mc::{Connection, Disconnected, Mc};
use hal_c2_shell::qml::{self, Roots};
use hal_c2_shell::{Launch, render};
use ljos::prelude::Engine;
use ljos::{App, ShellConfig};
use ljos_runtime::CoalesceKey;

const ROOT: &str = "Main";

struct Options {
    launch: Launch,
    mc_token: String,
    roots: Roots,
    actions: Vec<String>,
    check: bool,
    render: Option<PathBuf>,
    size: (u32, u32),
    settle_ms: u64,
}

fn usage() -> ExitCode {
    eprintln!(
        "usage: hal-c2-ljos [--mc-origin URL --mc-token TOKEN] [--config-dir DIR] [--qml-dir DIR]\n\
         \x20                  [--licenses MANIFEST] [--allow-local-folder-import] [--action NAME]...\n\
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
    let options = match parse() {
        Ok(o) => o,
        Err(e) => {
            eprintln!("hal-c2-ljos: {e}");
            return usage();
        }
    };
    let loaded = match qml::load(&options.roots) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("hal-c2-ljos: {e}");
            return ExitCode::FAILURE;
        }
    };
    eprintln!(
        "hal-c2-ljos: {} of {} QML files compiled",
        loaded.compiled, loaded.files
    );
    for (file, why) in &loaded.errors {
        eprintln!("  {file}.qml: {why}");
    }
    if options.check {
        return if loaded.errors.is_empty() {
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        };
    }
    let app = App::new("HAL-C2")
        .register(hal_c2_shell::register)
        .source(loaded.source)
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

/// What the QML says that is wrong, on stderr, each message once.
fn report_warnings(engine: &Engine) {
    let seen = std::cell::RefCell::new(std::collections::HashSet::new());
    engine.set_log_handler(move |entry| {
        if matches!(
            entry.level,
            ljos_engine::LogLevel::Warning | ljos_engine::LogLevel::Critical
        ) {
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

/// A picture without a window, and so without an MC: the shell as it shows
/// disconnected.
fn render_to(app: App, options: &Options, out: &PathBuf) -> Result<(), String> {
    let engine = app.build_engine();
    let clock = render::prepare(&engine);
    report_warnings(&engine);
    let mc = Rc::new(Disconnected::default());
    hal_c2_shell::start(&engine, &options.launch, mc.clone());
    dispatch_actions(&engine, &options.actions);
    let root = engine
        .create_from_url(ROOT, None, Vec::new())
        .map_err(|e| e.to_string())?;
    mc.deliver(&engine);
    let png = render::picture(&engine, &clock, root, options.size, options.settle_ms)?;
    if let Some(dir) = out.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::fs::write(out, png).map_err(|e| format!("{}: {e}", out.display()))?;
    eprintln!("hal-c2-ljos: wrote {}", out.display());
    Ok(())
}

/// The I/O thread has events for [`Connection::deliver`].
struct Wake;

/// The window, until it closes.
fn run(app: App, options: Options) -> Result<(), String> {
    let config = ShellConfig::new("HAL-C2").with_size(options.size.0 as f32, options.size.1 as f32);
    app.shell_config(config)
        .on_message(|_: &Engine, _: Wake| {})
        .run_with(move |setup| {
            let handle = setup.handle();
            let engine = setup.engine().clone();
            report_warnings(&engine);
            let mc: Rc<dyn Mc> = match &options.launch.mc_origin {
                Some(origin) => {
                    // One wake-up however much waits: the events themselves
                    // queue beside the inbox (see mc.rs).
                    let connection = Rc::new(Connection::spawn(move || {
                        let _ = handle.send_coalesced(CoalesceKey(1), Wake);
                    }));
                    connection.open(origin, &options.mc_token)?;
                    let deliver = connection.clone();
                    setup.on_message(move |engine: &Engine, Wake| {
                        // A panic here would drop the rest of the inbox's batch.
                        engine.turn(None, || deliver.deliver(engine));
                    });
                    connection
                }
                None => Rc::new(Disconnected::default()),
            };
            hal_c2_shell::start(&engine, &options.launch, mc);
            dispatch_actions(&engine, &options.actions);
            engine
                .create_from_url(ROOT, None, Vec::new())
                .map_err(|e| e.to_string().into())
        })
        .map_err(|e| e.to_string())
}
