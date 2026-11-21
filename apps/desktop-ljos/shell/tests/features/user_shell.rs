//! How the app runs the user's shell layout, `<config>/shell.qml`, for
//! steps/user_shell.rs: as main.rs starts it, the shell's pack with the
//! user's files over it (`App::user_qml`, whose session runs here at each
//! frame), and a host that shows in the test window the window Main.qml's
//! ShellLoader stands for.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use hal_c2_shell::runtime::{self, ShellRuntime};
use ljos::prelude::{Engine, LogLevel, ObjectId, Value};
use ljos::testing::TestWindow;
use ljos_dev::{Host, UserQml, UserSession};
use ljos_quick::roots::RootSwaps;
use ljos_runtime::SystemClock;

use crate::harness::{Failure, Outcome};
use crate::world::World;

/// How long a change may take to show: a compile of the shell's QML.
pub const PATIENCE: Duration = Duration::from_secs(20);

/// How the app was built.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum App {
    /// As `mise run dev` runs it.
    Running,
    /// A release build.
    Released,
}

/// What the host saw.
#[derive(Default)]
struct Run {
    /// The root the window shows.
    shown: Rc<Cell<Option<ObjectId>>>,
    /// How often the host opened a window, not counting a root put in one
    /// it had.
    opened: Rc<Cell<usize>>,
    /// The script errors logged since [`mark_log`].
    errors: Rc<RefCell<Vec<String>>>,
    counting: Rc<Cell<bool>>,
    /// The files the shell asked for and did not find, since it started.
    missing: Rc<RefCell<Vec<String>>>,
    /// What the app compiled while it started.
    compiled: String,
}

fn shell_path(world: &World) -> PathBuf {
    world.config_dir().join("shell.qml")
}

/// The user's layout is `text`, written as an editor saves it (a whole
/// file put in place), or there is none.
pub fn write(world: &mut World, text: Option<&str>) -> Outcome {
    let path = shell_path(world);
    let io = |e: std::io::Error| Failure(format!("{}: {e}", path.display()));
    match text {
        Some(text) => {
            std::fs::create_dir_all(path.parent().expect("in the config dir")).map_err(io)?;
            let part = path.with_extension("qml.part");
            std::fs::write(&part, text).map_err(io)?;
            std::fs::rename(&part, &path).map_err(io)?;
        }
        None => {
            if path.exists() {
                std::fs::remove_file(&path).map_err(io)?;
            }
        }
    }
    Ok(())
}

/// The user saves `text` over their layout while the app runs, or
/// removes it.
pub fn save(world: &mut World, text: Option<&str>) -> Outcome {
    write(world, text)?;
    world.pump()
}

/// Starts the shell's window as main.rs does.
pub fn open(world: &mut World, _app: App) -> Outcome {
    let config = world.config_dir();
    let engine = world.engine().clone();
    // The app's shell gives every Window a platform window of its own, as
    // here: without that, the shell's Window would stay an item of the
    // loader, which the window does not show, and its popups would find no
    // overlay (`parent: Overlay.overlay` reads null). Before any Window is
    // made: one made earlier is an item for good.
    ljos_controls::WindowSystem::of(&engine).set_host(|| {});
    runtime::install(&engine, Some(&config));
    // main.rs: the pack build.rs made, and `App::user_qml` over it.
    engine.set_component_source(hal_c2_shell::pack());
    let user = UserQml::dir(config).modules("qml").theme(false).watch(true);
    let mut session = UserSession::start(
        &engine,
        hal_c2_shell::pack(),
        user,
        ljos::dev::EngineOracle::from_engine,
        Arc::new(world.waker()),
    );
    listen(world);
    let run = world.part::<Run>();
    run.compiled = if session.is_compiling() {
        "the user's files".into()
    } else {
        String::new()
    };
    let (shown, opened) = (run.shown.clone(), run.opened.clone());
    runtime::set_hot_reload_enabled(&engine, true);
    let loader = runtime::open(&engine).map_err(Failure)?;
    session.set_root(loader);
    let swaps = RootSwaps::of(&engine);
    swaps.shows(&engine, None, loader);
    world
        .with_window(|_, window| window.show(loader))?
        .map_err(|e| Failure(e.to_string()))?;
    shown.set(Some(loader));
    opened.set(opened.get() + 1);
    let clock = SystemClock::new();
    // The host's frame: what the user saved, then the window the loader
    // stands for now.
    world.on_frame(move |engine, window| {
        let mut host = TestHost {
            window: &mut *window,
            swaps: &swaps,
            shown: &shown,
        };
        let reports = session.pump(engine, &clock, &mut host);
        if !reports.is_empty() {
            runtime::reloaded(engine);
        }
        let mut any = !reports.is_empty();
        if swaps.is_pending()
            && let Some(old) = shown.get()
        {
            let (now, _) = swaps.swap_in(engine, old, &mut |_, new| window.show(new).is_ok());
            any |= now != old;
            shown.set(Some(now));
        }
        Ok(any)
    })?;
    world.pump()
}

/// Where a reload that made the root again shows it: in the test window,
/// as the shell's own host does.
struct TestHost<'a> {
    window: &'a mut TestWindow,
    swaps: &'a RootSwaps,
    shown: &'a Cell<Option<ObjectId>>,
}

impl Host for TestHost<'_> {
    fn window(&self) -> Option<ObjectId> {
        self.shown.get()
    }

    fn show(&mut self, engine: &Engine, old: Option<ObjectId>, new: ObjectId) {
        self.swaps.shows(engine, old, new);
        if self.window.show(new).is_ok() {
            self.shown.set(Some(new));
        }
    }
}

fn listen(world: &mut World) {
    let run = world.part::<Run>();
    let (errors, counting) = (run.errors.clone(), run.counting.clone());
    let missing = run.missing.clone();
    world.engine().add_log_listener(move |entry| {
        // As FontLoader and Image say a file is not there.
        if entry.level == LogLevel::Warning
            && (entry.message.contains("Cannot load") || entry.message.contains("Cannot open"))
        {
            missing.borrow_mut().push(entry.message.clone());
        }
        if counting.get()
            && matches!(entry.level, LogLevel::Warning | LogLevel::Critical)
            && entry.message.contains("Error")
        {
            errors.borrow_mut().push(entry.message.clone());
        }
    });
}

/// Script errors count from here on.
pub fn mark_log(world: &mut World) {
    let run = world.part::<Run>();
    run.errors.borrow_mut().clear();
    run.counting.set(true);
}

/// The script errors logged since [`mark_log`].
pub fn logged_errors(world: &World) -> Vec<String> {
    world
        .peek_part::<Run>()
        .map(|run| run.errors.borrow().clone())
        .unwrap_or_default()
}

/// What the shell asked for and did not find since it started.
pub fn missing_files(world: &World) -> Vec<String> {
    world
        .peek_part::<Run>()
        .map(|run| run.missing.borrow().clone())
        .unwrap_or_default()
}

/// What the app compiled while it started; empty when nothing.
pub fn compiled_at_start(world: &World) -> String {
    world
        .peek_part::<Run>()
        .map(|run| run.compiled.clone())
        .unwrap_or_default()
}

/// The root the window shows.
pub fn window(world: &World) -> Option<ObjectId> {
    let shown = world.peek_part::<Run>()?.shown.get()?;
    world.engine().is_alive(shown).then_some(shown)
}

/// How often the host opened a window.
pub fn opened(world: &World) -> usize {
    world.peek_part::<Run>().map_or(0, |run| run.opened.get())
}

/// The app's visible windows.
pub fn windows(world: &World) -> usize {
    let engine = world.engine();
    ljos_controls::WindowSystem::of(engine)
        .windows(engine)
        .into_iter()
        .filter(|w| engine.read_by_name(*w, "visible") == Value::Bool(true))
        .count()
}

/// The size of the window shown.
pub fn window_size(world: &World) -> Option<(f64, f64)> {
    let root = window(world)?;
    let engine = world.engine();
    Some((
        engine.read_by_name(root, "width").to_number(),
        engine.read_by_name(root, "height").to_number(),
    ))
}

fn object_name(engine: &Engine, item: ObjectId) -> String {
    engine
        .to_js_string(&engine.read_by_name(item, "objectName"))
        .to_string()
}

/// Everything under `root`, what it owns and the items it shows.
fn under(engine: &Engine, root: ObjectId) -> Vec<ObjectId> {
    let mut seen = vec![root];
    let mut at = 0;
    while at < seen.len() {
        let each = seen[at];
        at += 1;
        for child in engine
            .children(each)
            .into_iter()
            .chain(ljos::item::child_items(engine, each))
        {
            if !seen.contains(&child) {
                seen.push(child);
            }
        }
    }
    seen
}

/// The item under `root` named `name`.
pub fn find(world: &World, root: ObjectId, name: &str) -> Option<ObjectId> {
    let engine = world.engine();
    under(engine, root)
        .into_iter()
        .find(|item| object_name(engine, *item) == name)
}

/// The items under `root` whose name starts with `prefix`.
pub fn find_prefix(world: &World, root: ObjectId, prefix: &str) -> Vec<ObjectId> {
    let engine = world.engine();
    under(engine, root)
        .into_iter()
        .filter(|item| object_name(engine, *item).starts_with(prefix))
        .collect()
}

/// Whether a text under `item` reads `text`.
pub fn shows_text(world: &World, item: ObjectId, text: &str) -> bool {
    let engine = world.engine();
    under(engine, item).into_iter().any(|each| {
        let value = engine.read_by_name(each, "text");
        matches!(value, Value::String(_)) && engine.to_js_string(&value) == text
    })
}

fn runtime_says(world: &World, name: &str) -> Value {
    let engine = world.engine();
    match engine.singleton::<ShellRuntime>() {
        Ok(runtime) => engine.read_by_name(runtime, name),
        Err(_) => Value::Undefined,
    }
}

fn last_error(world: &World) -> String {
    let engine = world.engine();
    engine
        .to_js_string(&runtime_says(world, "lastError"))
        .to_string()
}

/// Whether the window shows the built-in layout.
pub fn built_in(world: &World) -> bool {
    let Some(root) = window(world) else {
        return false;
    };
    runtime_says(world, "usingUserShell") == Value::Bool(false)
        && find(world, root, "userShellMark").is_none()
}

/// The layout's error, when the window shows one.
pub fn error_shown(world: &World) -> Option<String> {
    let root = window(world)?;
    let overlay = find(world, root, "shellError")?;
    let visible = world.engine().read_by_name(overlay, "visible") == Value::Bool(true);
    visible.then(|| last_error(world))
}

/// What the app shows, for a failure.
pub fn describe(world: &World) -> String {
    let engine = world.engine();
    let root = window(world);
    let kind = root
        .and_then(|r| engine.meta_of(r))
        .map(|m| m.name.to_string());
    format!(
        "the window shows {root:?} ({kind:?}), the user's layout: {:?}, generation {:?}, \
         lastError {:?}, {} windows",
        runtime_says(world, "usingUserShell"),
        runtime_says(world, "generation"),
        last_error(world),
        windows(world),
    )
}
