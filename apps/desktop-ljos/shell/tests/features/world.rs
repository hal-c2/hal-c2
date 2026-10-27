//! The shell as main.rs builds it, a recorder of what reaches the bricks, and
//! the MC: one per scenario, as desktop-qt's World
//! (apps/desktop-qt/tests/native/features/World.cpp).
//!
//! The shell starts unconnected, as desktop-qt's World does, and
//! [`World::connect`] opens the scenario's [`FakeMc`] over a real socket. Its clock is a test window's virtual one, which moves with the
//! real time a step spends waiting ([`World::wait_for`]), as Qt's timers do
//! under `QTest::qWaitFor`; the wall clock the controllers read stays at
//! [`World::now`] until a step sets it.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use hal_c2_shell::bridge::Bridge;
use hal_c2_shell::controller;
use hal_c2_shell::controllers::archived_threads::ArchivedThreads;
use hal_c2_shell::controllers::panel::RightPanel;
use hal_c2_shell::controllers::threads::ThreadStore;
use hal_c2_shell::controllers::toasts::Toasts;
use hal_c2_shell::controllers::usage::Usage;
use hal_c2_shell::json::{self, Json};
use hal_c2_shell::mc::{Connection, Mc};
use hal_c2_shell::session::Session;
use hal_c2_shell::thread_view::time::Clock;
use hal_c2_shell::{Launch, this_machine};
use ljos::App;
use ljos::prelude::{
    ClipboardError, ClipboardImage, ClipboardMode, ClipboardService, Engine, OpenUrlService,
    Platform, Value,
};
use ljos::testing::TestWindow;
use serde_json::json;

use crate::fake_mc::FakeMc;
use crate::harness::{Captures, Extension, Failure, Outcome, show};

/// The id of the machine the scenarios run on (this_machine::id()), as an MC
/// on it serves it as `platform.machineId`.
pub const THIS_MACHINE: &str = "5e1f00000000000000000000000000000000000000000000000000000000c0de";
/// A machine that is not that one.
pub const OTHER_MACHINE: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";

/// The longest a step waits for anything, as desktop-qt's qWaitFor.
const WAIT: Duration = Duration::from_secs(5);
/// The test window's size until a brick gives it its own (Brick::new).
const WINDOW: (f64, f64) = (1280.0, 800.0);

/// The longest a wait sleeps before it lets the shell's clock catch up.
const FRAME: Duration = Duration::from_millis(16);

/// Raised by whatever has something for the scenario's thread: the fake
/// MC's socket, the shell's connection, its cache and its other threads.
#[derive(Default)]
pub struct Signal {
    raised: Mutex<bool>,
    woken: Condvar,
}

impl Signal {
    pub fn notify(&self) {
        *self.raised.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.woken.notify_all();
    }

    /// Waits until raised or `timeout` passes; lowers it.
    fn wait(&self, timeout: Duration) {
        let raised = self.raised.lock().unwrap_or_else(|e| e.into_inner());
        let (mut raised, _) = self
            .woken
            .wait_timeout_while(raised, timeout, |raised| !*raised)
            .unwrap_or_else(|e| e.into_inner());
        *raised = false;
    }
}

/// An action no controller handled, or one native code sent the bricks
/// (`actionRequested`).
#[derive(Clone, Debug)]
pub struct BrickAction {
    pub kind: String,
    pub payload: Json,
}

/// What the shell did that the scenario reads instead of the desktop: the
/// bricks' actions, the clipboard, the addresses opened in a browser.
#[derive(Default)]
struct Recorded {
    brick_actions: RefCell<Vec<BrickAction>>,
    clipboard: RefCell<String>,
    /// What a copy put on the clipboard beside its text, as a screenshot
    /// tool or a file manager copies.
    clipboard_image: RefCell<Option<ClipboardImage>>,
    clipboard_files: RefCell<Vec<PathBuf>>,
    clipboard_fails: Cell<bool>,
    opened_urls: RefCell<Vec<String>>,
}

impl Recorded {
    /// A copy replaces all the clipboard held.
    fn copy(&self, text: &str, image: Option<ClipboardImage>, files: Vec<PathBuf>) {
        *self.clipboard.borrow_mut() = text.to_owned();
        *self.clipboard_image.borrow_mut() = image;
        *self.clipboard_files.borrow_mut() = files;
    }
}

struct Urls(Rc<Recorded>);

impl OpenUrlService for Urls {
    fn open(&self, url: &str) -> bool {
        self.0.opened_urls.borrow_mut().push(url.to_owned());
        true
    }
}

/// The running shell: the engine, the window whose clock it runs on, and its
/// connection to the MC.
struct Shell {
    engine: Engine,
    window: TestWindow,
    connection: Rc<Connection>,
}

pub type Question = Rc<dyn Fn(&mut World, bool) -> Outcome>;
pub type ToldInPlace = Rc<dyn Fn(&World) -> Vec<String>>;
pub type PageStep = Rc<dyn Fn(&mut World, &Captures) -> Outcome>;

pub struct World {
    pub mc: FakeMc,
    /// The draft the last new thread opened.
    pub draft_id: String,
    /// The command the last "receives" step found.
    pub command: Option<usize>,
    pub checked_commands: HashSet<usize>,
    pub next_edit: i32,
    /// The running step is an outcome (Step::outcome).
    pub checking: bool,
    /// What the theme editor holds (ThemeController::draft).
    pub theme_draft: Json,
    /// The settings row the scenario is about.
    pub setting_row: String,
    /// A question a brick asks in a dialog of its own: "the user confirms"
    /// and "the user cancels" answer it.
    pub answer_question: Option<Question>,
    /// What else a page tells the user in place (an inline error), for "the
    /// user is told".
    pub told_in_place: Option<ToldInPlace>,
    /// Steps two pages share the words of: what they check on the settings
    /// page, by a name the two files agree on ("hasAction",
    /// "invalidProjectFile", "isShown", "openResult", "inView"), set while a
    /// scenario is on that page.
    pub on_settings_page: HashMap<String, PageStep>,
    /// The scenario's own state, beside the MC's parts.
    parts: HashMap<std::any::TypeId, Box<dyn std::any::Any>>,
    now: DateTime<Utc>,
    signal: Arc<Signal>,
    recorded: Rc<Recorded>,
    /// Where the shell keeps its files (the last route, config), across
    /// restarts.
    home: tempfile::TempDir,
    shell: Option<Shell>,
}

impl World {
    pub fn new(extensions: &[Extension]) -> World {
        let signal = Arc::new(Signal::default());
        let home = tempfile::tempdir_in(env!("CARGO_TARGET_TMPDIR")).expect("a home for the shell");
        for dir in ["config", "state", "data", "cache"] {
            std::fs::create_dir_all(home.path().join(dir)).expect("the shell's directories");
        }
        // The machine the scenarios run on, whatever runs them; the fake MC
        // has no id unless a scenario gives it one (THIS_MACHINE for this one).
        this_machine::set_id_for_testing(Some(THIS_MACHINE.into()));
        let mut world = World {
            mc: FakeMc::start(signal.clone(), extensions),
            draft_id: String::new(),
            command: None,
            checked_commands: HashSet::new(),
            next_edit: 1,
            checking: false,
            theme_draft: Json::Null,
            setting_row: String::new(),
            answer_question: None,
            told_in_place: None,
            on_settings_page: HashMap::new(),
            parts: HashMap::new(),
            now: DateTime::parse_from_rfc3339("2026-09-23T10:00:00Z")
                .expect("the scenarios' time")
                .with_timezone(&Utc),
            signal,
            recorded: Rc::default(),
            home,
            shell: None,
        };
        world.start();
        world
    }

    /// As main.rs wires it.
    fn start(&mut self) {
        // en-US, as desktop-qt's World sets the sidebar's locale.
        let engine = App::new("features")
            .locale("en_US")
            .register(hal_c2_shell::register)
            .build_engine();
        // What `App::qml_dirs` gives main.rs: a plugin page is QML text.
        let dirs = hal_c2_shell::qml::Roots::checkout()
            .dirs()
            .expect("the shell's QML");
        let paths: Vec<&Path> = dirs.iter().map(PathBuf::as_path).collect();
        ljos::dev::install_text_compiler(&engine, &paths);
        // Before the shell starts, for its timers to start on the window's clock.
        let window = TestWindow::new(&engine, WINDOW.0, WINDOW.1);
        let wake = |signal: &Arc<Signal>| {
            let signal = signal.clone();
            move || signal.notify()
        };
        hal_c2_shell::folders::set_wake(&engine, wake(&self.signal));
        hal_c2_shell::device::set_wake(&engine, wake(&self.signal));
        hal_c2_shell::controllers::plugin::set_wake(&engine, wake(&self.signal));
        hal_c2_shell::local_transcriber::set_wake(&engine, wake(&self.signal));
        hal_c2_shell::theme::set_wake(&engine, wake(&self.signal));
        Platform::of(&engine).set_waker(wake(&self.signal));
        // A real host fetches an Image's http source; the fake MC serves it.
        Platform::of(&engine).set_fetcher(Arc::new(LocalFetcher));
        let connection = Rc::new(Connection::spawn(wake(&self.signal)));
        connection
            .client()
            .set_retry_delays(vec![Duration::from_millis(20)]);
        let home = self.home.path();
        let launch = Launch {
            config_dir: Some(home.join("config")),
            // desktop-qt's NativeShell has its store from the start and
            // activates on the MC's first snapshot, once `connect` opens it;
            // a shell started with no origin would be active at once.
            mc_origin: Some(self.mc.origin()),
            // The shell runs its own local MC, so local folders are its to open.
            allow_local_folder_import: true,
            cache_dir: Some(home.join("cache")),
            data_dir: Some(home.join("data")),
            state_dir: Some(home.join("state")),
            ..Launch::default()
        };
        hal_c2_shell::start(&engine, &launch, connection.clone() as Rc<dyn Mc>);
        hal_c2_shell::controllers::threads::set_wake(&engine, wake(&self.signal));
        hal_c2_shell::controllers::sidebar::set_time_zone(
            &engine,
            hal_c2_shell::time_zone::Zone::named("UTC"),
        );
        let recorded = self.recorded.clone();
        Bridge::of(&engine).set_clipboard_writer(&engine, move |text| {
            if recorded.clipboard_fails.get() {
                return false;
            }
            *recorded.clipboard.borrow_mut() = text.to_owned();
            true
        });
        Platform::of(&engine).set_open_url(Rc::new(Urls(self.recorded.clone())));
        Platform::of(&engine).set_clipboard(Rc::new(RecordedClipboard(self.recorded.clone())));
        let recorded = self.recorded.clone();
        let _ = engine.connect_by_name(
            Bridge::of(&engine).object(),
            "actionRequested",
            move |engine, args| {
                let kind = match args.first() {
                    Some(Value::String(kind)) => kind.to_string(),
                    _ => String::new(),
                };
                let payload = args
                    .get(1)
                    .map(|p| json::from_value(engine, p))
                    .unwrap_or(Json::Null);
                recorded
                    .brick_actions
                    .borrow_mut()
                    .push(BrickAction { kind, payload });
            },
        );
        self.shell = Some(Shell {
            engine,
            window,
            connection,
        });
        let now = self.now;
        self.set_time(now);
    }

    pub fn engine(&self) -> &Engine {
        &self.shell.as_ref().expect("the app is running").engine
    }

    pub fn running(&self) -> bool {
        self.shell.is_some()
    }

    /// The shell's client of the MC (desktop-qt's `native().client()`).
    pub fn client(&self) -> &hal_c2_mc::McClient {
        self.shell
            .as_ref()
            .expect("the app is running")
            .connection
            .client()
    }

    /// The client has its MC's hello and is following it.
    pub fn client_ready(&self) -> bool {
        self.shell
            .as_ref()
            .is_some_and(|shell| shell.connection.client().is_ready())
    }

    /// The shell has started over its MC (NativeShell::isActive).
    pub fn active(&self) -> bool {
        self.shell
            .as_ref()
            .is_some_and(|shell| hal_c2_shell::active(&shell.engine))
    }

    /// The shell's config directory (theme.json, preferences.json), fresh
    /// per scenario and kept across restarts.
    pub fn config_dir(&self) -> PathBuf {
        self.home.path().join("config")
    }

    /// Where the shell keeps its state (`state/`), data (`data/`) and its
    /// cache of the MC (`cache/`).
    pub fn home_dir(&self) -> &Path {
        self.home.path()
    }

    /// What `Shell.state[key]` holds; null while the app is closed.
    pub fn state(&self, key: &str) -> Json {
        self.shell
            .as_ref()
            .and_then(|shell| Bridge::of(&shell.engine).published(&shell.engine, key))
            .unwrap_or(Json::Null)
    }

    /// `Shell.dispatch(action, payload)`, as a brick sends it.
    pub fn dispatch(&mut self, action: &str, payload: Json) -> Outcome {
        let engine = self.engine().clone();
        Bridge::of(&engine).dispatch(&engine, action, payload);
        self.pump()
    }

    /// Runs `f` on the controller `C`, as another controller would.
    pub fn with<C: controller::Controller, R>(
        &self,
        f: impl FnOnce(&mut C, &Engine) -> R,
    ) -> Outcome<R> {
        controller::with::<C, R>(self.engine(), f)
            .ok_or_else(|| Failure("the controller is busy".into()))
    }

    /// A domain's state for the scenario, made on first use.
    pub fn part<T: Default + 'static>(&mut self) -> &mut T {
        self.parts
            .entry(std::any::TypeId::of::<T>())
            .or_insert_with(|| Box::new(T::default()))
            .downcast_mut::<T>()
            .expect("a part of its own type")
    }

    pub fn brick_actions(&self) -> Vec<BrickAction> {
        self.recorded.brick_actions.borrow().clone()
    }

    pub fn clear_brick_actions(&self) {
        self.recorded.brick_actions.borrow_mut().clear();
    }

    pub fn actions_of(&self, kind: &str) -> Vec<BrickAction> {
        self.recorded
            .brick_actions
            .borrow()
            .iter()
            .filter(|a| a.kind == kind)
            .cloned()
            .collect()
    }

    pub fn describe_brick_actions(&self) -> String {
        let actions = self.recorded.brick_actions.borrow();
        if actions.is_empty() {
            return "(nothing)".into();
        }
        actions
            .iter()
            .map(|a| format!("{} {}", a.kind, show(&a.payload)))
            .collect::<Vec<_>>()
            .join("; ")
    }

    pub fn describe_commands(&self) -> String {
        if self.mc.commands.is_empty() {
            return "(none)".into();
        }
        self.mc
            .commands
            .iter()
            .map(show)
            .collect::<Vec<_>>()
            .join("; ")
    }

    /// The shell's clipboard, recorded instead of touching the desktop's.
    pub fn clipboard(&self) -> String {
        self.recorded.clipboard.borrow().clone()
    }

    pub fn set_clipboard(&self, text: &str) {
        self.recorded.copy(text, None, Vec::new());
    }

    /// Puts what one copy does on the clipboard: `files` as a file manager
    /// copies them, with `text` beside them.
    pub fn copy_files(&self, files: Vec<PathBuf>, text: &str) {
        self.recorded.copy(text, None, files);
    }

    /// From here on the clipboard refuses what it is given.
    pub fn set_clipboard_fails(&self, fails: bool) {
        self.recorded.clipboard_fails.set(fails);
    }

    /// The addresses the shell opened in the browser, in order.
    pub fn opened_urls(&self) -> Vec<String> {
        self.recorded.opened_urls.borrow().clone()
    }

    pub fn now(&self) -> DateTime<Utc> {
        self.now
    }

    pub fn set_time_iso(&mut self, iso: &str) -> Outcome {
        let time = DateTime::parse_from_rfc3339(iso)
            .map_err(|e| Failure(format!("{iso}: {e}")))?
            .with_timezone(&Utc);
        self.set_time(time);
        Ok(())
    }

    /// Every clock the shell reads stops at `time`.
    pub fn set_time(&mut self, time: DateTime<Utc>) {
        self.now = time;
        let Some(shell) = &self.shell else { return };
        let engine = shell.engine.clone();
        engine.set_wall_clock_origin(Some(time.timestamp_millis() as f64));
        let _ = controller::with::<ThreadStore, _>(&engine, |c, engine| {
            c.set_clock(engine, Clock::fixed(time))
        });
        let _ = controller::with::<RightPanel, _>(&engine, |c, engine| {
            c.set_clock(engine, Clock::fixed(time))
        });
        let _ = controller::with::<Usage, _>(&engine, |c, _| c.set_clock(move || time));
        let _ = controller::with::<ArchivedThreads, _>(&engine, |c, _| c.set_clock(move || time));
        let _ = controller::with::<Toasts, _>(&engine, |c, engine| c.expire(engine));
    }

    /// The desktop quits and starts again: a new shell, the same files.
    pub fn restart(&mut self) -> Outcome {
        self.quit()?;
        self.launch();
        Ok(())
    }

    /// The two halves, for what happens while the app is closed: no step may
    /// reach for the shell between them.
    pub fn quit(&mut self) -> Outcome {
        if let Some(shell) = self.shell.take() {
            hal_c2_shell::store::flush(&shell.engine);
            shell.connection.client().close();
            drop(shell);
        }
        self.recorded.brick_actions.borrow_mut().clear();
        // The MC sees its client go.
        self.wait_for("the MC to see the app quit", |w| !w.mc.connected())
    }

    pub fn launch(&mut self) {
        self.start();
    }

    /// Dispatches `thread.new`; the draft it opens (if any) becomes draft_id.
    pub fn start_new_thread(&mut self, payload: Json) -> Outcome {
        self.dispatch("thread.new", payload)?;
        let route = self.state("route");
        if route.get("kind").and_then(Json::as_str) == Some("draft") {
            self.draft_id = crate::harness::text(&route["draftId"]);
        }
        Ok(())
    }

    /// Opens the draft of the MC's project `project_id`, which becomes draft_id.
    pub fn open_draft(&mut self, project_id: &str) -> Outcome {
        let environment = self.mc.environment_id.clone();
        self.draft_id =
            hal_c2_shell::controllers::drafts::start(self.engine(), &environment, project_id)
                .unwrap_or_default();
        self.pump()
    }

    /// The key of the sidebar's project named `name`; `name` itself when
    /// none is.
    pub fn project_key(&self, name: &str) -> String {
        let sidebar = self.state("sidebar");
        sidebar
            .get("projects")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
            .find(|p| p.get("displayName").and_then(Json::as_str) == Some(name))
            .and_then(|p| p.get("key").and_then(Json::as_str))
            .unwrap_or(name)
            .to_owned()
    }

    /// Pairs the shell with the scenario's MC, and waits for it to follow
    /// the MC's shell.
    pub fn connect(&mut self) -> Outcome {
        self.connect_with("mc-token")
    }

    pub fn connect_with(&mut self, token: &str) -> Outcome {
        let session = Session {
            origin: self.mc.origin(),
            token: token.to_owned(),
            label: String::new(),
            environment_id: String::new(),
        };
        hal_c2_shell::open(self.engine(), &session).map_err(Failure)?;
        self.wait_for("the shell to subscribe", |w| w.shell_subscriptions() >= 1)
    }

    pub fn shell_subscriptions(&self) -> usize {
        self.mc
            .subscriptions
            .iter()
            .filter(|s| s.pointer("/shape/type").and_then(Json::as_str) == Some("shell"))
            .count()
    }

    /// A round trip through the cache and then the MC: everything the MC
    /// sent before, and every answer to a command sent before, has been
    /// handled once it returns.
    pub fn sync(&mut self) -> Outcome {
        // Nothing is on its way to an app that is closed.
        let Some(shell) = &self.shell else {
            return Ok(());
        };
        self.mc.pump();
        // What the shell asked of its cache first: a thread is followed once
        // its kept copy is read, so that subscription goes out before the
        // barrier.
        hal_c2_shell::controllers::threads::drain(&shell.engine);
        let done = Rc::new(Cell::new(false));
        let answered = done.clone();
        shell.connection.call(
            &self.mc.environment_id,
            "test.barrier",
            Json::Null,
            Box::new(move |_, _| answered.set(true)),
        );
        self.wait_for("a round trip through the MC", move |_| done.get())
    }

    /// The MC serves its environment from `machine` (its
    /// `platform.machineId`), and the shell has heard it.
    pub fn served_from(&mut self, machine: &str) -> Outcome {
        self.mc.platform = serde_json::Map::from_iter([("machineId".to_owned(), json!(machine))]);
        self.mc.announce_environment();
        self.sync()
    }

    /// Round trips through the MC until `condition` holds: for a state the
    /// shell reaches only by what it asks of the MC and what the MC answers
    /// (a settings write, the snapshots of the shapes it follows), so the
    /// wait ends on those and not on the clock. Gives up once two round
    /// trips in a row brought the MC no new call or subscription: a call the
    /// shell makes as it handles a round trip's answers goes out after that
    /// round's barrier, so it shows only on the next; after two, nothing
    /// more is on its way. `what` describes the state it gave up on.
    pub fn sync_until_with(
        &mut self,
        mut condition: impl FnMut(&World) -> bool,
        what: impl Fn(&World) -> String,
    ) -> Outcome {
        let mut idle = 0;
        loop {
            self.pump()?;
            if condition(self) {
                return Ok(());
            }
            if idle == 2 {
                return Err(Failure(format!(
                    "the MC was asked nothing more while waiting for {}",
                    what(self)
                )));
            }
            let asked = self.asked();
            self.sync()?;
            idle = if self.asked() == asked { idle + 1 } else { 0 };
        }
    }

    /// How many calls (less sync's barriers) and subscriptions the MC has
    /// had.
    fn asked(&self) -> usize {
        let calls = self.mc.calls.iter();
        calls.filter(|c| c.method != "test.barrier").count() + self.mc.subscriptions.len()
    }

    pub fn wait_for(&mut self, what: &str, condition: impl FnMut(&World) -> bool) -> Outcome {
        self.wait_for_with(condition, |_| what.to_owned())
    }

    /// Hands everything waiting to whoever it is for until `condition`
    /// holds, for up to five seconds; `what` describes the state the wait
    /// gave up on. The shell's clock moves with the time it takes.
    pub fn wait_for_with(
        &mut self,
        mut condition: impl FnMut(&World) -> bool,
        what: impl Fn(&World) -> String,
    ) -> Outcome {
        let started = Instant::now();
        let mut moved = Duration::ZERO;
        loop {
            self.pump()?;
            if condition(self) {
                return Ok(());
            }
            let waited = started.elapsed();
            if waited >= WAIT {
                return Err(Failure(format!("timed out waiting for {}", what(self))));
            }
            // As much real time as has passed, on the shell's clock.
            let behind = waited.saturating_sub(moved);
            let whole = Duration::from_millis(behind.as_millis() as u64);
            if !whole.is_zero() {
                moved += whole;
                self.advance(whole.as_millis() as u64)?;
                continue;
            }
            // Until something arrives, or the shell's next timer is due.
            // An animation is no timer, so a frame at a time: the shell's
            // clock moves only when this loop moves it.
            let mut timeout = (WAIT - waited).min(FRAME);
            if let Some(shell) = &self.shell
                && let Some(due) = shell.engine.next_timer_deadline()
            {
                timeout = timeout.min(
                    due.saturating_since(shell.engine.now())
                        .max(Duration::from_millis(1)),
                );
            }
            self.signal.wait(timeout);
        }
    }

    /// What a screen reader is told of the inputs (text fields, combo
    /// boxes) inside `item`: their names, in the tree's order. Turns the
    /// accessibility tree on, as a screen reader starting up does.
    pub fn accessible_input_names(&mut self, item: ljos::ObjectId) -> Outcome<Vec<String>> {
        fn walk(
            node: &ljos::testing::AccessibleNode,
            within: &dyn Fn(ljos::testing::NodeKey) -> bool,
            names: &mut Vec<String>,
        ) {
            let input = matches!(
                node.role.as_str(),
                "textinput" | "multilinetextinput" | "combobox" | "editablecombobox" | "spinbutton"
            );
            if input && node.key.is_some_and(within) {
                names.push(node.name.clone());
            }
            for child in &node.children {
                walk(child, within, names);
            }
        }
        let Some(shell) = &mut self.shell else {
            return Err(Failure("the app is not running".into()));
        };
        shell
            .window
            .set_accessibility_active(true)
            .map_err(|e| Failure(e.to_string()))?;
        let (engine, window) = (&shell.engine, &shell.window);
        let within = |key| {
            let mut at = window.accessible_item(key);
            while let Some(each) = at {
                if each == item {
                    return true;
                }
                at = engine.visual_parent(each);
            }
            false
        };
        let mut names = Vec::new();
        walk(&window.accessibility_tree(), &within, &mut names);
        Ok(names)
    }

    /// Lets `ms` pass on the shell's clock, the wall clock staying put.
    pub fn advance(&mut self, ms: u64) -> Outcome {
        self.await_answers()?;
        let Some(shell) = &mut self.shell else {
            return Ok(());
        };
        shell
            .window
            .advance(ms)
            .map_err(|e| Failure(e.to_string()))?;
        shell
            .engine
            .set_wall_clock_origin(Some(self.now.timestamp_millis() as f64));
        Ok(())
    }

    /// Serves the fake MC until the shell's promised platform answers (a
    /// task such as pairing's HTTP exchange) have come back. TestWindow's
    /// advance waits for them on this thread first, and this thread is the
    /// one that answers the fake MC: waiting there would leave a request to
    /// it unanswered until the client's own timeout. Held answers are a
    /// step's to release; one still out after WAIT is TestWindow's to wait
    /// for and give up on.
    fn await_answers(&mut self) -> Outcome {
        let started = Instant::now();
        loop {
            let Some(shell) = &self.shell else {
                return Ok(());
            };
            let platform = Platform::of(&shell.engine);
            if platform.pending() == 0 || platform.is_held() || started.elapsed() >= WAIT {
                return Ok(());
            }
            self.pump()?;
            self.signal.wait(FRAME);
        }
    }

    /// Shows the component `root` of `source` in the shell's window, in
    /// place of what it showed (a brick: brick.rs).
    pub fn show_root(&mut self, source: ljos::MapSource, root: &str) -> Outcome<ljos::ObjectId> {
        let Some(shell) = &mut self.shell else {
            return Err(Failure("the app is not running".into()));
        };
        let item = ljos::create_root(&shell.engine, source, root)
            .map_err(|e| Failure(format!("{root} cannot be made: {e:?}")))?;
        shell
            .window
            .show(item)
            .map_err(|e| Failure(e.to_string()))?;
        self.pump()?;
        Ok(item)
    }

    /// How many things the window painted for `item` itself (its glyphs,
    /// fills and borders) at its last frame.
    pub fn painted(&self, item: ljos::ObjectId) -> usize {
        self.shell
            .as_ref()
            .and_then(|shell| shell.window.painted(item))
            .map_or(0, |list| list.ops().len())
    }

    /// Makes the window `width` by `height`, as a user dragging its edge
    /// does.
    pub fn resize(&mut self, width: f64, height: f64) -> Outcome {
        let Some(shell) = &mut self.shell else {
            return Err(Failure("the app is not running".into()));
        };
        shell
            .window
            .resize(width, height)
            .map_err(|e| Failure(e.to_string()))?;
        self.pump()
    }

    /// The user presses and releases the primary button at (x, y) of the
    /// window.
    pub fn click_at(&mut self, x: f64, y: f64) -> Outcome {
        use ljos::item::PointerEvent;
        let Some(shell) = &mut self.shell else {
            return Err(Failure("the app is not running".into()));
        };
        let now = shell.window.now();
        shell.window.pointer(&PointerEvent::press(x, y, now));
        shell.window.pointer(&PointerEvent::release(x, y, now));
        self.pump()
    }

    /// The pointer moves to (x, y) of the window, no button held: what
    /// shows on hover shows.
    pub fn hover_at(&mut self, x: f64, y: f64) -> Outcome {
        use ljos::item::{MouseButtons, PointerEvent};
        let Some(shell) = &mut self.shell else {
            return Err(Failure("the app is not running".into()));
        };
        let now = shell.window.now();
        shell
            .window
            .pointer(&PointerEvent::moved(x, y, MouseButtons::empty(), now));
        self.pump()
    }

    /// The user types `text` in the window, into whatever has the keyboard
    /// focus.
    pub fn type_text(&mut self, text: &str) -> Outcome {
        let Some(shell) = &mut self.shell else {
            return Err(Failure("the app is not running".into()));
        };
        shell.window.commit(text);
        self.pump()
    }

    /// The user presses a key in the window. Whether an item took it.
    pub fn key(&mut self, event: &ljos::item::KeyEvent) -> Outcome<bool> {
        let Some(shell) = &mut self.shell else {
            return Err(Failure("the app is not running".into()));
        };
        let taken = shell.window.key(event);
        self.pump()?;
        Ok(taken)
    }

    /// Hands what arrived to whoever it is for: the MC what the shell sent,
    /// the shell what the MC and its own threads did; then lets the shell
    /// come to rest. A handler's failure fails the step.
    pub fn pump(&mut self) -> Outcome {
        loop {
            let mut any = self.mc.pump();
            if let Some(failure) = self.mc.take_failure() {
                return Err(failure);
            }
            if let Some(shell) = &mut self.shell {
                let engine = &shell.engine;
                let connection = &shell.connection;
                engine.turn(None, || {
                    connection.deliver(engine);
                    hal_c2_shell::folders::deliver(engine);
                    hal_c2_shell::device::deliver(engine);
                    hal_c2_shell::controllers::plugin::deliver(engine);
                    hal_c2_shell::local_transcriber::deliver(engine);
                    hal_c2_shell::theme::deliver(engine);
                    hal_c2_shell::controllers::threads::deliver(engine);
                    hal_c2_shell::controllers::snap_shot::deliver(engine);
                });
                any |= Platform::of(engine).deliver(engine) > 0;
                shell.window.settle().map_err(|e| Failure(e.to_string()))?;
            }
            if !any {
                return Ok(());
            }
        }
    }
}

impl Drop for World {
    fn drop(&mut self) {
        if let Some(shell) = self.shell.take() {
            shell.connection.client().close();
        }
        this_machine::set_id_for_testing(None);
    }
}

impl World {
    /// A domain's state when a step made it, for closures that hold
    /// `&World`.
    pub fn peek_part<T: 'static>(&self) -> Option<&T> {
        self.parts
            .get(&std::any::TypeId::of::<T>())
            .and_then(|part| part.downcast_ref::<T>())
    }

    /// The user presses and releases `button` at (x, y) of the window while
    /// holding `modifiers`.
    pub fn click_at_with(
        &mut self,
        x: f64,
        y: f64,
        button: ljos::item::MouseButtons,
        modifiers: ljos::item::Modifiers,
    ) -> Outcome {
        use ljos::item::PointerEvent;
        let Some(shell) = &mut self.shell else {
            return Err(Failure("the app is not running".into()));
        };
        let now = shell.window.now();
        let mut press = PointerEvent::press(x, y, now);
        press.button = Some(button);
        press.buttons = button;
        press.modifiers = modifiers;
        let mut release = PointerEvent::release(x, y, now);
        release.button = Some(button);
        release.modifiers = modifiers;
        shell.window.pointer(&press);
        shell.window.pointer(&release);
        self.pump()
    }

    /// What the window painted for `item` itself at its last frame, op by op.
    pub fn painted_ops(&self, item: ljos::ObjectId) -> Vec<ljos::item::DrawOp> {
        self.shell
            .as_ref()
            .and_then(|shell| shell.window.painted(item))
            .map_or_else(Vec::new, |list| list.ops().to_vec())
    }

    /// The user's pointer does what `event` makes of the window's time.
    /// Whether an item took it.
    pub fn pointer(
        &mut self,
        event: impl FnOnce(ljos::prelude::Time) -> ljos::item::PointerEvent,
    ) -> Outcome<bool> {
        let Some(shell) = &mut self.shell else {
            return Err(Failure("the app is not running".into()));
        };
        let taken = shell.window.pointer(&event(shell.window.now()));
        self.pump()?;
        Ok(taken)
    }

    /// The user turns the mouse wheel `notches` over (x, y) of the window
    /// (positive: away from the user, showing what is further up). Whether
    /// an item used it.
    pub fn wheel(&mut self, x: f64, y: f64, notches: f64) -> Outcome<bool> {
        let Some(shell) = &mut self.shell else {
            return Err(Failure("the app is not running".into()));
        };
        let event = ljos::item::WheelEvent::notches(x, y, 0.0, notches, shell.window.now());
        let taken = shell.window.wheel(&event);
        self.pump()?;
        Ok(taken)
    }
}

/// The platform clipboard the shell's own items (a terminal's copy, a paste
/// through `Shell.clipboardText`) read and write: the one `World::clipboard`
/// and `set_clipboard` see, so a copy by any route lands where steps look.
struct RecordedClipboard(Rc<Recorded>);

impl ClipboardService for RecordedClipboard {
    fn text(&self, mode: ClipboardMode) -> Option<String> {
        (mode == ClipboardMode::Clipboard).then(|| self.0.clipboard.borrow().clone())
    }

    fn set_text(&self, mode: ClipboardMode, text: &str) -> Result<(), ClipboardError> {
        if mode != ClipboardMode::Clipboard {
            return Err(ClipboardError::Unavailable);
        }
        if self.0.clipboard_fails.get() {
            return Err(ClipboardError::Denied);
        }
        self.0.copy(text, None, Vec::new());
        Ok(())
    }

    fn html(&self) -> Option<String> {
        None
    }

    fn set_html(&self, _: &str, alt_text: &str) -> Result<(), ClipboardError> {
        self.set_text(ClipboardMode::Clipboard, alt_text)
    }

    fn image(&self) -> Option<ClipboardImage> {
        self.0.clipboard_image.borrow().clone()
    }

    fn set_image(&self, image: ClipboardImage) -> Result<(), ClipboardError> {
        self.0.copy("", Some(image), Vec::new());
        Ok(())
    }

    fn files(&self) -> Vec<PathBuf> {
        self.0.clipboard_files.borrow().clone()
    }

    fn set_files(&self, files: &[PathBuf]) -> Result<(), ClipboardError> {
        self.0.copy("", None, files.to_vec());
        Ok(())
    }

    fn clear(&self, mode: ClipboardMode) -> Result<(), ClipboardError> {
        if mode == ClipboardMode::Clipboard {
            self.0.copy("", None, Vec::new());
        }
        Ok(())
    }
}

/// The network of a headless host: plain `http:` GETs, answered by the fake
/// MC on this machine (ljos's own `HttpFetcher` is not exported by its facade).
struct LocalFetcher;

impl ljos::prelude::Fetcher for LocalFetcher {
    fn fetch(&self, url: &str) -> Result<Vec<u8>, ljos::prelude::FetchError> {
        use ljos::prelude::FetchError::{Failed, NoNetwork};
        use std::io::{Read, Write};
        let rest = url
            .strip_prefix("http://")
            .ok_or_else(|| NoNetwork(url.to_owned()))?;
        let (host, path) = rest.split_once('/').unwrap_or((rest, ""));
        let failed = |e: std::io::Error| Failed(format!("{url}: {e}"));
        let mut stream = std::net::TcpStream::connect(host).map_err(failed)?;
        write!(
            stream,
            "GET /{path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"
        )
        .map_err(failed)?;
        let mut reply = Vec::new();
        stream.read_to_end(&mut reply).map_err(failed)?;
        let split = reply
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .ok_or_else(|| Failed(format!("{url}: no reply")))?;
        let head = String::from_utf8_lossy(&reply[..split]).into_owned();
        let status: u16 = head
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        if !(200..300).contains(&status) {
            return Err(Failed(format!("{url}: {status}")));
        }
        Ok(reply[split + 4..].to_vec())
    }
}
