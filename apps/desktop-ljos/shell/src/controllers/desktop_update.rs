//! `desktopUpdate`, desktop-qt's DesktopUpdateController (with
//! DesktopUpdater and DesktopRemoteUpdates): the desktop app updating
//! itself — checks the feed 15 s after launch and every 4 minutes,
//! downloads what the button asks for, and installs it by stopping the
//! MC, replacing the app and relaunching it. One step at a time; a
//! failed install starts the MC again. What it touches is behind seams
//! (the environment, the feed and the files, the clock: [`Platform`])
//! so tests drive it without a network or a sleep. It also tells the MC
//! where the update stands (`server.reportDesktopUpdateStatus`) and
//! takes the MC's update requests (`desktopUpdateControl`): a request
//! checks, downloads and prepares; a commit installs what it prepared,
//! within 5 minutes.
//!
//! Publishes `desktopUpdate`: {shown, state, status, channel, track,
//! currentVersion, action, label, details, disabled, canCheck,
//! canChangeTrack, downloadPercent, popover, warning}.
//!
//! Actions: `desktopUpdate.press` (what the button does now), `.check`,
//! `.menuCheck`, `.download`, `.install`, `.setTrack {channel}`,
//! `.openReleaseNotes {url}`.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, SecondsFormat, Utc};
use ljos::prelude::{Engine, Platform as Host};
use serde_json::json;

use crate::bridge::Bridge;
use crate::commands::Commands;
use crate::controller::{self, Controller, Init, Me};
use crate::controllers::menus::Menus;
use crate::controllers::settings::Settings;
use crate::controllers::toasts::Toasts;
use crate::desktop_update::{self as logic, Environment, Release, RemoteKind, State};
use crate::json::Json;
use crate::mc::{Mc, SubId};
use crate::settings_page;

const SETTINGS_KEY: &str = "desktopUpdate";
const REPORT: &str = "server.reportDesktopUpdateStatus";

pub const STARTUP_DELAY_MS: i64 = 15_000;
pub const POLL_INTERVAL_MS: i64 = 4 * 60_000;
pub const PREPARED_CHECK_WAIT_MS: i64 = 90_000;
pub const RETRY_MS: i64 = 250;
pub const PREPARED_TTL_MS: i64 = 5 * 60_000;

/// What a backend call or arrival changed.
#[derive(Debug)]
pub enum Event {
    Fetched(Result<Vec<Release>, String>),
    Progress(i64),
    Downloaded(Option<String>),
    Installed(Option<String>),
}

/// The feed and the files. A call starts its step; what it learns comes
/// back as [`Event`]s, at once from the call or later from
/// [`Backend::arrive`].
pub trait Backend {
    fn fetch(&mut self, environment: &Environment) -> Vec<Event>;
    /// Stages the release's asset, reporting progress in percent.
    fn download(&mut self, release: &Release) -> Vec<Event>;
    /// Whether the release is still staged.
    fn staged(&self, version: &str) -> bool;
    /// Replaces the running app with the staged release and starts it;
    /// the caller quits once it succeeds.
    fn install(&mut self, environment: &Environment, version: &str) -> Vec<Event>;
    /// What arrived since, handed over on the Engine thread.
    fn arrive(&mut self) -> Vec<Event> {
        Vec::new()
    }
}

/// The wall clock, and waiting on it.
pub trait Clock {
    fn now_ms(&self) -> i64;
    /// Runs `run` in `ms`.
    fn after(&self, engine: &Engine, ms: i64, run: Rc<dyn Fn(&Engine)>);
}

struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> i64 {
        Utc::now().timestamp_millis()
    }
    fn after(&self, engine: &Engine, ms: i64, run: Rc<dyn Fn(&Engine)>) {
        let at = engine.now() + Duration::from_millis(ms.max(0) as u64);
        engine.call_at(at, move |engine| run(engine));
    }
}

/// Opens a URL; false when the system could not.
pub type OpenUrl = Rc<dyn Fn(&str) -> bool>;
/// Stores a track; the reason it could not, when it could not.
pub type PersistTrack = Rc<dyn Fn(&str) -> Option<String>>;
type AfterCheck = Rc<dyn Fn(&Engine)>;

/// What the controller updates this process with: unset parts are the
/// system's (the environment as the process finds it, the feed over the
/// network, the wall clock, the platform's opener). main() hands it the
/// MC it runs; tests replace the rest before the shell starts
/// ([`set_platform`]).
#[derive(Default)]
pub struct Platform {
    pub environment: Option<Environment>,
    pub backend: Option<Rc<RefCell<dyn Backend>>>,
    pub clock: Option<Rc<dyn Clock>>,
    /// Stops and starts the MC this app runs.
    pub stop_mc: Option<Rc<dyn Fn()>>,
    pub start_mc: Option<Rc<dyn Fn()>>,
    /// Ends this process once the new version is running.
    pub quit: Option<Rc<dyn Fn()>>,
    /// Opens a release's notes; false when the system could not.
    pub open_url: Option<OpenUrl>,
    /// Stores the chosen track instead of this device's settings; says
    /// why it could not.
    pub persist_track: Option<PersistTrack>,
}

thread_local! {
    static PLATFORM: RefCell<Platform> = RefCell::new(Platform::default());
    static WAKE: RefCell<Option<Arc<dyn Fn() + Send + Sync>>> = const { RefCell::new(None) };
    static CACHE_DIR: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
}

/// Replaces what the next shell updates itself with (the tests').
pub fn set_platform(platform: Platform) {
    PLATFORM.with(|held| *held.borrow_mut() = platform);
}

fn with_platform<R>(f: impl FnOnce(&Platform) -> R) -> R {
    PLATFORM.with(|held| f(&held.borrow()))
}

/// Changes what the next shell updates itself with (the tests', between
/// a shell's restarts).
pub fn update_platform<R>(f: impl FnOnce(&mut Platform) -> R) -> R {
    PLATFORM.with(|held| f(&mut held.borrow_mut()))
}

/// What wakes the Engine thread when the system backend's threads have
/// something (main.rs and the tests').
pub fn set_wake(_engine: &Engine, wake: impl Fn() + Send + Sync + 'static) {
    WAKE.with(|held| *held.borrow_mut() = Some(Arc::new(wake)));
}

/// Where downloads are staged (the launch's cache directory).
pub fn set_cache_dir(_engine: &Engine, dir: PathBuf) {
    CACHE_DIR.with(|held| *held.borrow_mut() = Some(dir));
}

/// Hands the controller what its backend's threads left. On the Engine
/// thread, when main.rs is woken.
pub fn deliver(engine: &Engine) {
    controller::with::<DesktopUpdate, _>(engine, |c, e| c.arrive(e));
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Ask {
    User,
    Remote,
}

struct Run {
    request_id: String,
    checks: i32,
    downloads: i32,
}

struct Prepared {
    request_id: String,
    version: String,
    /// prepared, committing, failed
    status: String,
    failure_reason: String,
    expires_at: i64,
}

fn base(environment: &Environment, channel: &str) -> State {
    let mut state = logic::initial(
        &environment.app_version,
        channel,
        logic::enabled_for(environment),
    );
    state.host_arch = environment.host_arch.clone();
    state.app_arch = environment.app_arch.clone();
    state.running_under_arm64_translation = environment.translated;
    if !state.enabled {
        state.message = logic::disabled_reason(environment);
    }
    state
}

fn track_name(channel: &str) -> &'static str {
    if channel == logic::NIGHTLY {
        "Nightly"
    } else {
        "Stable"
    }
}

pub struct DesktopUpdate {
    bridge: Bridge,
    me: Me<DesktopUpdate>,
    mc: Rc<dyn Mc>,
    /// The updater is made: activate ran.
    made: bool,
    environment: Environment,
    backend: Option<Rc<RefCell<dyn Backend>>>,
    clock: Option<Rc<dyn Clock>>,
    state: State,
    /// check, download, install, install-recovery, channel; empty when idle.
    active_action: String,
    quitting: bool,
    started: bool,
    /// Switching track may go back in version.
    track_switched: bool,
    offer: Option<Release>,
    check_run: i32,
    /// The check's toast, when a check is running: whether it came from
    /// the menu (the palette).
    check_from_menu: Option<bool>,
    download_ask: Option<Ask>,
    install_ask: Option<Ask>,
    /// An install waiting for the check before it.
    after_check: Option<AfterCheck>,
    // What a server asked for.
    run: Option<Run>,
    step_queued: bool,
    cancelled_before_start: HashSet<String>,
    /// A commit that joined an install the user started: told if that
    /// install fails.
    joined: bool,
    prepared: Option<Prepared>,
    control: Option<SubId>,
    unsent_failure: Option<Json>,
}

impl Controller for DesktopUpdate {
    fn new(init: Init<'_, Self>) -> Self {
        DesktopUpdate {
            bridge: init.bridge,
            me: init.me,
            mc: init.mc,
            made: false,
            environment: Environment::default(),
            backend: None,
            clock: None,
            state: State::default(),
            active_action: String::new(),
            quitting: false,
            started: false,
            track_switched: false,
            offer: None,
            check_run: 0,
            check_from_menu: None,
            download_ask: None,
            install_ask: None,
            after_check: None,
            run: None,
            step_queued: false,
            cancelled_before_start: HashSet::new(),
            joined: false,
            prepared: None,
            control: None,
            unsent_failure: None,
        }
    }

    fn activate(&mut self, engine: &Engine) {
        if self.made {
            return;
        }
        let (environment, backend, clock) = with_platform(|platform| {
            (
                platform
                    .environment
                    .clone()
                    .unwrap_or_else(Environment::system),
                platform.backend.clone(),
                platform.clock.clone(),
            )
        });
        self.environment = environment;
        self.backend = Some(backend.unwrap_or_else(system_backend));
        self.clock = Some(clock.unwrap_or_else(|| Rc::new(SystemClock) as Rc<dyn Clock>));
        // The track is read before `made`, which makes it the state's.
        self.state = base(&self.environment, &self.channel(engine));
        self.made = true;
        // Where the update stands, for an MC that (re)connects; the MC
        // asks for updates on its own subscription, which the client
        // sends again itself.
        let me = self.me.clone();
        self.mc.on_ready_changed(Box::new(move |engine, ready| {
            if !ready {
                return;
            }
            me.run(engine, |c, engine| {
                // First: a connect report with no request would end the
                // install this failure is about.
                if let Some(failure) = c.unsent_failure.clone() {
                    c.report(engine, failure);
                }
                let active = c.active_request_id();
                let report = c.status_report(&active, "", "");
                c.report(engine, report);
            });
        }));
        let me = self.me.clone();
        self.control = Some(self.mc.subscribe(
            json!({"type": "desktopUpdateControl"}),
            Box::new(move |engine, frame| {
                let frame = Json::Object(frame.clone());
                me.run(engine, |c, engine| c.on_control(engine, &frame));
            }),
            None,
        ));
        if self.mc.is_ready() {
            let report = self.status_report("", "", "");
            self.report(engine, report);
        }
        self.publish(engine);
        self.start(engine);
    }

    fn attach(&mut self, engine: &Engine, _window: &crate::controller::Window) {
        Commands::of(engine).add(
            engine,
            "desktopUpdate.check",
            "Check for Updates",
            |engine| {
                controller::with::<DesktopUpdate, _>(engine, |c, engine| {
                    if c.made {
                        c.check_from(engine, true);
                    }
                });
            },
        );
    }

    fn handle(&mut self, engine: &Engine, action: &str, payload: &Json) -> bool {
        if !action.starts_with("desktopUpdate.") {
            return false;
        }
        if !self.made {
            return true;
        }
        match action {
            "desktopUpdate.press" => match logic::button_action(&self.state) {
                "download" => self.download(engine, Ask::User),
                "install" => self.confirm_install(engine),
                _ => self.check_from(engine, false),
            },
            "desktopUpdate.check" => self.check_from(engine, false),
            "desktopUpdate.menuCheck" => self.check_from(engine, true),
            "desktopUpdate.download" => self.download(engine, Ask::User),
            "desktopUpdate.install" => self.confirm_install(engine),
            "desktopUpdate.setTrack" => {
                let channel = settings_page::text(payload, "channel").to_owned();
                self.set_track(engine, &channel);
            }
            "desktopUpdate.openReleaseNotes" => {
                let url = settings_page::text(payload, "url").to_owned();
                if !self.open_url(engine, &url) {
                    self.toast_error(engine, "Unable to open release notes", "");
                }
            }
            _ => return false,
        }
        true
    }
}

impl DesktopUpdate {
    /// The track this device follows: the installed build's until the
    /// user picks one (this device's `desktopUpdate` settings).
    pub fn channel(&self, engine: &Engine) -> String {
        if self.made {
            return self.state.channel.clone();
        }
        let version = with_platform(|platform| {
            platform.environment.as_ref().map_or_else(
                || env!("CARGO_PKG_VERSION").to_owned(),
                |e| e.app_version.clone(),
            )
        });
        let stored = Settings::of(engine)
            .device_value(SETTINGS_KEY)
            .unwrap_or(Json::Null);
        let chosen = stored
            .get("channel")
            .and_then(Json::as_str)
            .unwrap_or_default();
        if stored.get("channelChosen").and_then(Json::as_bool) == Some(true)
            && (chosen == logic::NIGHTLY || chosen == logic::STABLE)
        {
            return chosen.to_owned();
        }
        logic::channel_of(&version).to_owned()
    }

    fn now(&self) -> String {
        let ms = self.clock.as_ref().map_or(0, |clock| clock.now_ms());
        DateTime::<Utc>::from_timestamp_millis(ms)
            .map(|time| time.to_rfc3339_opts(SecondsFormat::Millis, true))
            .unwrap_or_default()
    }

    fn toast_error(&self, engine: &Engine, title: &str, description: &str) {
        let (title, description) = (title.to_owned(), description.to_owned());
        controller::with::<Toasts, _>(engine, move |t, e| {
            t.error(e, &title, &description);
        });
    }

    fn publish(&self, engine: &Engine) {
        if !self.made {
            return;
        }
        let state = &self.state;
        let busy = state.status == "checking" || state.status == "downloading";
        let warning = if logic::shows_intel_warning(state) {
            json!({"title": "Intel build on Apple Silicon",
                   "description": logic::intel_warning(state)})
        } else {
            Json::Null
        };
        let popover = logic::popover(state);
        let view = json!({
            "shown": self.environment.platform == "linux" || self.environment.platform == "macos",
            "state": state.to_json(),
            "status": state.status,
            "channel": state.channel,
            "track": track_name(&state.channel),
            "currentVersion": state.current_version,
            "action": logic::button_action(state),
            "label": logic::label(state),
            "details": logic::shows_details(state),
            // The button: busy while it checks or downloads, and nothing
            // to press in a build that cannot update.
            "disabled": busy || (!logic::shows_details(state) && !logic::can_check(state)),
            // Settings' check: open to a build that cannot, to say why.
            "canCheck": !busy,
            "canChangeTrack": self.active_action.is_empty(),
            "downloadPercent": state.download_percent,
            "popover": if popover.as_object().is_some_and(|o| o.is_empty()) { Json::Null } else { popover },
            "warning": warning,
        });
        self.bridge.publish(engine, "desktopUpdate", view);
    }

    fn apply(&mut self, engine: &Engine, state: State) {
        if state == self.state {
            return;
        }
        self.state = state;
        self.publish(engine);
        let active = self.active_request_id();
        let report = self.status_report(&active, "", "");
        self.report(engine, report);
        // A server's run follows the state, a step behind it.
        if self.run.is_some() && !self.step_queued {
            self.step_queued = true;
            let me = self.me.clone();
            self.bridge.defer(engine, move |engine| {
                me.run(engine, |c, engine| {
                    c.step_queued = false;
                    c.step(engine);
                });
            });
        }
    }

    fn report(&mut self, _engine: &Engine, payload: Json) {
        // A failed install comes with the MC just stopped for it: its
        // report waits for the MC to hear it, here or once it is back.
        let failure = payload.get("outcome").and_then(Json::as_str) == Some("failed");
        if failure {
            self.unsent_failure = Some(payload.clone());
        }
        if !self.mc.is_ready() {
            return;
        }
        // An MC the desktop app did not start refuses it; nothing to
        // tell anyone.
        let me = self.me.clone();
        let sent = payload.clone();
        self.mc.call(
            &self.mc.environment(),
            REPORT,
            payload,
            Box::new(move |engine, result| {
                if failure && result.is_ok() {
                    me.run(engine, |c, _| {
                        if c.unsent_failure.as_ref() == Some(&sent) {
                            c.unsent_failure = None;
                        }
                    });
                }
            }),
        );
    }

    fn on_control(&mut self, engine: &Engine, frame: &Json) {
        let event = frame.get("event").unwrap_or(frame);
        let kind = event.get("type").and_then(Json::as_str).unwrap_or_default();
        let request_id = event
            .get("requestId")
            .and_then(Json::as_str)
            .unwrap_or_default();
        if request_id.is_empty() {
            return;
        }
        match kind {
            "requestDesktopUpdate" => self.request(engine, request_id),
            "commitDesktopUpdate" => self.commit(engine, request_id),
            "cancelDesktopUpdate" => self.cancel(request_id),
            _ => {}
        }
    }

    // --- The updater ---------------------------------------------------

    fn start(&mut self, engine: &Engine) {
        if self.started || !self.state.enabled {
            return;
        }
        self.started = true;
        let me = self.me.clone();
        self.after(
            engine,
            STARTUP_DELAY_MS,
            Rc::new(move |engine| me.run(engine, |c, engine| c.poll(engine))),
        );
    }

    fn after(&self, engine: &Engine, ms: i64, run: Rc<dyn Fn(&Engine)>) {
        if let Some(clock) = &self.clock {
            clock.after(engine, ms, run);
        }
    }

    fn poll(&mut self, engine: &Engine) {
        self.check(engine, None);
        let me = self.me.clone();
        self.after(
            engine,
            POLL_INTERVAL_MS,
            Rc::new(move |engine| me.run(engine, |c, engine| c.poll(engine))),
        );
    }

    /// Starts a check; false when none can start (disabled, quitting,
    /// busy). `from_menu` is the toast to show once it has an answer,
    /// for a check the user asked for.
    fn check(&mut self, engine: &Engine, from_menu: Option<bool>) -> bool {
        if self.quitting
            || !self.state.enabled
            || self.state.status == "downloading"
            || !self.active_action.is_empty()
        {
            return false;
        }
        self.active_action = "check".into();
        self.check_run += 1;
        let run = self.check_run;
        self.check_from_menu = from_menu;
        let state = logic::on_check_start(self.state.clone(), &self.now());
        self.apply(engine, state);
        let events = match &self.backend {
            Some(backend) => backend.borrow_mut().fetch(&self.environment),
            None => Vec::new(),
        };
        self.on_events(engine, events, run);
        true
    }

    fn on_events(&mut self, engine: &Engine, events: Vec<Event>, run: i32) {
        for event in events {
            match event {
                Event::Fetched(result) => {
                    if self.check_run != run || self.active_action != "check" {
                        continue;
                    }
                    match result {
                        Err(error) => {
                            let state =
                                logic::on_check_failure(self.state.clone(), &error, &self.now());
                            self.apply(engine, state);
                        }
                        Ok(releases) => {
                            let offer = logic::select(
                                &releases,
                                &self.environment.app_version.clone(),
                                &self.state.channel.clone(),
                                self.state.channel == logic::NIGHTLY || self.track_switched,
                            );
                            match offer {
                                Some(offer) => {
                                    self.offer = Some(offer.release.clone());
                                    let state = logic::on_update_available(
                                        self.state.clone(),
                                        &offer.release.version,
                                        &self.now(),
                                        offer.notes,
                                        offer.omitted,
                                    );
                                    self.apply(engine, state);
                                }
                                None => {
                                    let state =
                                        logic::on_no_update(self.state.clone(), &self.now());
                                    self.apply(engine, state);
                                }
                            }
                        }
                    }
                    self.active_action.clear();
                    if let Some(from_menu) = self.check_from_menu.take() {
                        self.told_check(engine, from_menu);
                    }
                    if let Some(after) = self.after_check.take() {
                        after(engine);
                    }
                }
                Event::Progress(percent) => {
                    if self.active_action != "download" {
                        continue;
                    }
                    if logic::shows_progress(&self.state, percent) {
                        let state = logic::on_download_progress(self.state.clone(), percent);
                        self.apply(engine, state);
                    }
                }
                Event::Downloaded(error) => {
                    if self.active_action != "download" {
                        continue;
                    }
                    self.active_action.clear();
                    let ask = self.download_ask.take();
                    match error {
                        Some(error) => {
                            let state = logic::on_download_failure(self.state.clone(), &error);
                            self.apply(engine, state);
                            self.told_download(engine, ask, true);
                        }
                        None => {
                            let version = self.offer.as_ref().map_or_else(
                                || self.state.available_version.clone(),
                                |o| o.version.clone(),
                            );
                            let state = logic::on_download_complete(self.state.clone(), &version);
                            self.apply(engine, state);
                            self.told_download(engine, ask, false);
                        }
                    }
                }
                Event::Installed(error) => {
                    if self.active_action != "install" {
                        continue;
                    }
                    let ask = self.install_ask.take();
                    match error {
                        None => {
                            self.told_install(engine, ask, None);
                            // The new version is installed and running:
                            // this process quits.
                            let quit = with_platform(|p| p.quit.clone());
                            match quit {
                                Some(quit) => quit(),
                                None => self.bridge.defer(engine, |engine| engine.request_quit()),
                            }
                        }
                        Some(error) => {
                            // The app stays: its MC comes back, and the
                            // update can be installed again.
                            self.active_action = "install-recovery".into();
                            self.quitting = false;
                            if let Some(start) = with_platform(|p| p.start_mc.clone()) {
                                start();
                            }
                            let state = logic::on_install_failure(self.state.clone(), &error);
                            self.apply(engine, state);
                            self.active_action.clear();
                            if std::mem::take(&mut self.joined) {
                                self.commit_failed(engine, &error);
                            }
                            self.told_install(engine, ask, Some(error));
                        }
                    }
                }
            }
        }
    }

    /// What the backend's own threads left.
    pub fn arrive(&mut self, engine: &Engine) {
        let Some(backend) = &self.backend else { return };
        let events = backend.borrow_mut().arrive();
        let run = self.check_run;
        self.on_events(engine, events, run);
    }

    fn download(&mut self, engine: &Engine, ask: Ask) {
        if self.quitting
            || self.state.status != "available"
            || !self.active_action.is_empty()
            || self.offer.is_none()
        {
            if ask == Ask::User {
                self.toast_error(
                    engine,
                    "Could not start update download",
                    "There is no update to download right now.",
                );
            } else if let Some(run) = &mut self.run {
                // Not a try: the remote run counts it back and retries.
                run.downloads -= 1;
                self.retry_later(engine);
            }
            return;
        }
        self.active_action = "download".into();
        self.download_ask = Some(ask);
        let state = logic::on_download_start(self.state.clone());
        self.apply(engine, state);
        let release = self.offer.clone().unwrap_or_default();
        let events = match &self.backend {
            Some(backend) => backend.borrow_mut().download(&release),
            None => Vec::new(),
        };
        let run = self.check_run;
        self.on_events(engine, events, run);
    }

    /// Installs the downloaded update (of `expected`, when given: a
    /// check running first is waited for, up to 90 s). Whether it was
    /// accepted; the outcome lands in `told_install`.
    fn install(&mut self, engine: &Engine, expected: &str, ask: Ask) -> bool {
        if self.quitting
            || !self.state.enabled
            || self.state.downloaded_version.is_empty()
            || (!expected.is_empty() && expected != self.state.downloaded_version)
        {
            self.told_install_refused(engine, ask);
            return false;
        }
        // A check that started first (the 4-minute one) ends before a
        // prepared install.
        if self.active_action == "check" && !expected.is_empty() && self.after_check.is_none() {
            let pending = Rc::new(Cell::new(true));
            let expected = expected.to_owned();
            let me = self.me.clone();
            let again = pending.clone();
            self.after_check = Some(Rc::new(move |engine| {
                if !again.replace(false) {
                    return;
                }
                let expected = expected.clone();
                me.run_after(engine, move |c, engine| {
                    c.install(engine, &expected, ask);
                });
            }));
            let me = self.me.clone();
            self.after(
                engine,
                PREPARED_CHECK_WAIT_MS,
                Rc::new(move |engine| {
                    if !pending.replace(false) {
                        return;
                    }
                    me.run(engine, |c, engine| {
                        c.after_check = None;
                        c.told_install_refused(engine, ask);
                    });
                }),
            );
            return true;
        }
        if !self.active_action.is_empty() || !logic::installable(&self.state) {
            self.told_install_refused(engine, ask);
            return false;
        }
        self.install_now(engine, ask);
        true
    }

    fn install_now(&mut self, engine: &Engine, ask: Ask) {
        self.active_action = "install".into();
        self.install_ask = Some(ask);
        self.quitting = true;
        if let Some(stop) = with_platform(|p| p.stop_mc.clone()) {
            stop();
        }
        let version = self.state.downloaded_version.clone();
        let events = match &self.backend {
            Some(backend) => backend.borrow_mut().install(&self.environment, &version),
            None => Vec::new(),
        };
        let run = self.check_run;
        self.on_events(engine, events, run);
    }

    /// Switches the track and checks it; why it could not otherwise.
    fn set_channel(
        &mut self,
        engine: &Engine,
        channel: &str,
        persist: &dyn Fn(&str) -> Option<String>,
    ) -> Option<String> {
        if !self.active_action.is_empty() {
            let step = if self.active_action.starts_with("install") {
                "install"
            } else {
                &self.active_action.clone()
            };
            return Some(format!(
                "The update track cannot change while an update {step} is in progress."
            ));
        }
        if channel == self.state.channel {
            return None;
        }
        self.active_action = "channel".into();
        if let Some(error) = persist(channel) {
            self.active_action.clear();
            return Some(error);
        }
        self.track_switched = true;
        self.offer = None;
        self.active_action.clear();
        let state = base(&self.environment, channel);
        self.apply(engine, state);
        self.check(engine, None);
        None
    }

    fn staged(&self, version: &str) -> bool {
        self.backend
            .as_ref()
            .is_some_and(|backend| backend.borrow().staged(version))
    }

    // --- The user's own asks --------------------------------------------

    // The button's and Settings' check say only when it could not run or
    // failed; the menu's (the palette's) also say when the app is current.
    fn check_from(&mut self, engine: &Engine, from_menu: bool) {
        if self.check(engine, Some(from_menu)) {
            return;
        }
        let state = &self.state;
        if state.status == "checking" || state.status == "downloading" {
            return;
        }
        if from_menu && !state.enabled {
            let message = if state.message.is_empty() {
                "Automatic updates are not available right now.".to_owned()
            } else {
                state.message.clone()
            };
            controller::with::<Toasts, _>(engine, move |t, e| {
                t.show(
                    e,
                    "warning",
                    "Updates unavailable",
                    &message,
                    None,
                    crate::controllers::toasts::DEFAULT_TIMEOUT_MS,
                );
            });
            return;
        }
        let message = if state.message.is_empty() {
            "Automatic updates are not available in this build.".to_owned()
        } else {
            state.message.clone()
        };
        self.toast_error(engine, "Could not check for updates", &message);
    }

    fn told_check(&mut self, engine: &Engine, from_menu: bool) {
        let state = self.state.clone();
        if state.status == "error" && state.error_context == "check" {
            if from_menu {
                let message = if state.message.is_empty() {
                    "An unknown error occurred. Please try again later.".to_owned()
                } else {
                    state.message.clone()
                };
                self.toast_error(engine, "Update check failed", &message);
            } else {
                let message = if state.message.is_empty() {
                    "Update check failed.".to_owned()
                } else {
                    state.message.clone()
                };
                self.toast_error(engine, "Could not check for updates", &message);
            }
        } else if from_menu && state.status == "up-to-date" {
            let description = format!(
                "HAL-C2 {} is currently the newest version available.",
                state.current_version
            );
            controller::with::<Toasts, _>(engine, move |t, e| {
                t.show(
                    e,
                    "info",
                    "You're up to date!",
                    &description,
                    None,
                    crate::controllers::toasts::DEFAULT_TIMEOUT_MS,
                );
            });
        }
    }

    fn told_download(&mut self, engine: &Engine, ask: Option<Ask>, failed: bool) {
        if ask != Some(Ask::User) {
            return;
        }
        if !failed {
            self.told_downloaded(engine);
            return;
        }
        let message = self.state.message.trim().to_owned();
        self.toast_error(engine, "Could not download update", &message);
    }

    fn told_downloaded(&mut self, engine: &Engine) {
        let version = if self.state.downloaded_version.is_empty() {
            self.state.available_version.clone()
        } else {
            self.state.downloaded_version.clone()
        };
        let url = logic::release_url(&version);
        let me = self.me.clone();
        let action = (!url.is_empty()).then(|| {
            crate::controllers::toasts::Action::new("Read more", move |engine| {
                let url = url.clone();
                me.run(engine, move |c, engine| {
                    if !c.open_url(engine, &url) {
                        c.toast_error(engine, "Unable to open release notes", "");
                    }
                });
            })
        });
        controller::with::<Toasts, _>(engine, move |t, e| {
            t.show(
                e,
                "success",
                "Update downloaded",
                "Restart the app from the update button to install it.",
                action,
                crate::controllers::toasts::DEFAULT_TIMEOUT_MS,
            );
        });
    }

    fn confirm_install(&mut self, engine: &Engine) {
        let title = logic::confirmation_title(&self.state);
        let me = self.me.clone();
        let asked = controller::with::<Menus, _>(engine, move |menus, engine| {
            menus.confirm(
                engine,
                &title,
                logic::CONFIRMATION_DETAIL,
                "Restart and install",
                false,
                Some(Rc::new(move |engine: &Engine| {
                    me.run(engine, |c, engine| {
                        c.install(engine, "", Ask::User);
                    });
                })),
                None,
            );
        });
        if asked.is_none() {
            self.toast_error(
                engine,
                "Could not confirm update",
                "Update confirmation failed.",
            );
        }
    }

    fn told_install_refused(&mut self, engine: &Engine, ask: Ask) {
        match ask {
            Ask::User => {
                self.toast_error(
                    engine,
                    "Could not install update",
                    "The update is not ready to install.",
                );
            }
            Ask::Remote => {
                // The user already started this install: the commit
                // rides along.
                let version = self
                    .prepared
                    .as_ref()
                    .map(|p| p.version.clone())
                    .unwrap_or_default();
                if self.active_action == "install" && self.state.downloaded_version == version {
                    self.join_commit(engine);
                    return;
                }
                let message = self.state.message.trim().to_owned();
                let reason = if message.is_empty() {
                    "The desktop app could not start the install.".to_owned()
                } else {
                    message
                };
                self.commit_failed(engine, &reason);
            }
        }
    }

    fn told_install(&mut self, engine: &Engine, ask: Option<Ask>, error: Option<String>) {
        match (ask, error) {
            (Some(Ask::User), Some(error)) => {
                self.toast_error(engine, "Could not install update", &error);
            }
            (Some(Ask::Remote), Some(error)) => {
                let message = self.state.message.trim().to_owned();
                let reason = if message.is_empty() { error } else { message };
                self.commit_failed(engine, &reason);
            }
            _ => {}
        }
    }

    fn set_track(&mut self, engine: &Engine, channel: &str) {
        if channel != logic::NIGHTLY && channel != logic::STABLE {
            return;
        }
        let stored = with_platform(|p| p.persist_track.clone());
        let persist = |next: &str| -> Option<String> {
            if let Some(store) = &stored {
                return store(next);
            }
            let settings = Settings::of(engine);
            if !settings.write_device(
                engine,
                SETTINGS_KEY,
                json!({"channel": next, "channelChosen": true}),
            ) {
                return Some(settings.device_error());
            }
            None
        };
        if let Some(error) = self.set_channel(engine, channel, &persist) {
            self.toast_error(engine, "Could not change update track", &error);
        }
        self.publish(engine);
    }

    fn open_url(&self, engine: &Engine, url: &str) -> bool {
        if !url.starts_with("https://") {
            return false;
        }
        if let Some(open) = with_platform(|p| p.open_url.clone()) {
            return open(url);
        }
        Host::of(engine).open_url().open(url)
    }

    // --- A server's asks -------------------------------------------------

    /// The request the next status report belongs to.
    fn active_request_id(&self) -> String {
        if let Some(run) = &self.run {
            return run.request_id.clone();
        }
        if let Some(prepared) = &self.prepared
            && prepared.status == "committing"
        {
            return prepared.request_id.clone();
        }
        String::new()
    }

    /// `server.reportDesktopUpdateStatus`'s payload.
    fn status_report(&self, request_id: &str, outcome: &str, reason: &str) -> Json {
        let mut report = json!({
            "version": 1,
            "type": "desktopUpdateStatus",
            "state": self.state.to_json(),
        });
        if !request_id.is_empty() {
            report["requestId"] = json!(request_id);
        }
        if !outcome.is_empty() {
            report["outcome"] = json!(outcome);
        }
        if !reason.trim().is_empty() {
            report["reason"] = json!(reason.trim());
        }
        report
    }

    fn request(&mut self, engine: &Engine, request_id: &str) {
        if self.cancelled_before_start.remove(request_id) {
            return;
        }
        // Only an install under way refuses: a prepared run its MC never
        // committed (the app's socket dropped) gives way to this one.
        if self
            .prepared
            .as_ref()
            .is_some_and(|p| p.status == "committing")
        {
            let report = self.status_report(
                request_id,
                "failed",
                "A prepared desktop update is already in progress.",
            );
            self.report(engine, report);
            return;
        }
        self.prepared = None;
        self.run = Some(Run {
            request_id: request_id.to_owned(),
            checks: 0,
            downloads: 0,
        });
        self.step(engine);
    }

    fn retry_later(&mut self, engine: &Engine) {
        let Some(run) = &self.run else { return };
        let request_id = run.request_id.clone();
        let me = self.me.clone();
        self.after(
            engine,
            RETRY_MS,
            Rc::new(move |engine| {
                let request_id = request_id.clone();
                me.run(engine, move |c, engine| {
                    if c.run.as_ref().is_some_and(|r| r.request_id == request_id) {
                        c.step(engine);
                    }
                });
            }),
        );
    }

    fn step(&mut self, engine: &Engine) {
        let Some(run) = &self.run else { return };
        let (checks, downloads) = (run.checks, run.downloads);
        let next = logic::next_remote_step(
            &self.state,
            checks,
            downloads,
            &logic::disabled_reason(&self.environment),
        );
        match next.kind {
            RemoteKind::Wait => {}
            RemoteKind::Check => {
                // Counted before it starts; one that is refused is not a try.
                if let Some(run) = &mut self.run {
                    run.checks += 1;
                }
                if !self.check(engine, None) {
                    if let Some(run) = &mut self.run {
                        run.checks -= 1;
                    }
                    self.retry_later(engine);
                }
            }
            RemoteKind::Download => {
                if let Some(run) = &mut self.run {
                    run.downloads += 1;
                }
                self.download(engine, Ask::Remote);
            }
            RemoteKind::Install => {
                if !self.active_action.is_empty() {
                    self.retry_later(engine);
                    return;
                }
                if self.state.downloaded_version.is_empty()
                    || !self.staged(&self.state.downloaded_version.clone())
                {
                    self.finish(
                        engine,
                        "failed",
                        "The desktop app lost the downloaded update.",
                    );
                    return;
                }
                let now = self.clock.as_ref().map_or(0, |c| c.now_ms());
                self.prepared = Some(Prepared {
                    request_id: self
                        .run
                        .as_ref()
                        .map(|r| r.request_id.clone())
                        .unwrap_or_default(),
                    version: self.state.downloaded_version.clone(),
                    status: "prepared".into(),
                    failure_reason: String::new(),
                    expires_at: now + PREPARED_TTL_MS,
                });
                self.finish(engine, "ready-to-install", "");
            }
            RemoteKind::Done => self.finish(engine, &next.reason.clone(), ""),
            RemoteKind::Failed => {
                let reason = next.reason.clone();
                self.finish(engine, "failed", &reason);
            }
        }
    }

    fn finish(&mut self, engine: &Engine, outcome: &str, reason: &str) {
        let Some(run) = self.run.take() else { return };
        let report = self.status_report(&run.request_id, outcome, reason);
        self.report(engine, report);
    }

    fn cancel(&mut self, request_id: &str) {
        if self
            .run
            .as_ref()
            .is_some_and(|run| run.request_id == request_id)
        {
            self.run = None;
        } else if !self
            .prepared
            .as_ref()
            .is_some_and(|p| p.request_id == request_id)
        {
            self.cancelled_before_start.insert(request_id.to_owned());
        }
        if self
            .prepared
            .as_ref()
            .is_some_and(|p| p.request_id == request_id && p.status == "prepared")
        {
            self.prepared = None;
        }
    }

    fn commit_failed(&mut self, engine: &Engine, reason: &str) {
        let request_id = self
            .prepared
            .as_ref()
            .map(|p| p.request_id.clone())
            .unwrap_or_default();
        if let Some(prepared) = &mut self.prepared {
            prepared.status = "failed".into();
            prepared.failure_reason = reason.to_owned();
        }
        let report = self.status_report(&request_id, "failed", reason);
        self.report(engine, report);
    }

    /// The commit joins an install already running: it hears only if
    /// that install fails.
    fn join_commit(&mut self, _engine: &Engine) {
        self.joined = true;
    }

    fn commit(&mut self, engine: &Engine, request_id: &str) {
        let now = self.clock.as_ref().map_or(0, |c| c.now_ms());
        let expired = self
            .prepared
            .as_ref()
            .is_some_and(|p| p.status == "prepared" && p.expires_at <= now);
        let matches = self
            .prepared
            .as_ref()
            .is_some_and(|p| p.request_id == request_id);
        if !matches || expired {
            if expired {
                self.prepared = None;
            }
            let report = self.status_report(
                request_id,
                "failed",
                "This desktop update is no longer prepared.",
            );
            self.report(engine, report);
            return;
        }
        let (status, failure_reason, version) = {
            let prepared = self.prepared.as_ref().expect("a prepared update");
            (
                prepared.status.clone(),
                prepared.failure_reason.clone(),
                prepared.version.clone(),
            )
        };
        if status == "failed" {
            let reason = if failure_reason.is_empty() {
                "The desktop app failed to install the update.".to_owned()
            } else {
                failure_reason
            };
            let report = self.status_report(request_id, "failed", &reason);
            self.report(engine, report);
            return;
        }
        if status == "committing" {
            return;
        }
        if let Some(prepared) = &mut self.prepared {
            prepared.status = "committing".into();
        }
        if self.state.downloaded_version != version {
            self.commit_failed(engine, "This desktop update is no longer prepared.");
            return;
        }
        self.install(engine, &version, Ask::Remote);
    }
}

// --- The system's backend -------------------------------------------------
//
// The feed over the network and the staged files under the cache
// directory's `updates/<version>` (desktop-qt's DesktopUpdateSystem).
// Each step runs on its own thread; what it learns waits in `arrivals`
// for [`deliver`].

const FEED_TIMEOUT: Duration = Duration::from_secs(30);

// Waits for this process to end, then puts the new app in place and
// starts it. The swap waits because the running app is the file being
// replaced (macOS) and SingleInstance would hand a second copy's launch
// back to this one.
const RELAUNCH: &str = "pid=\"$1\"; target=\"$2\"; staged=\"$3\"; open_with=\"$4\"\n\
while kill -0 \"$pid\" 2>/dev/null; do sleep 0.2; done\n\
if [ -n \"$staged\" ]; then rm -rf \"$target\" && mv \"$staged\" \"$target\" || exit 1; fi\n\
if [ -n \"$open_with\" ]; then exec \"$open_with\" \"$target\"; else exec \"$target\"; fi\n";

#[derive(Default)]
struct SystemBackend {
    staged: HashMap<String, PathBuf>,
    arrivals: Arc<Mutex<Vec<Event>>>,
}

fn system_backend() -> Rc<RefCell<dyn Backend>> {
    Rc::new(RefCell::new(SystemBackend::default()))
}

fn staging_dir(version: &str) -> Option<PathBuf> {
    CACHE_DIR.with(|held| held.borrow().as_ref().map(|dir| dir.join(version)))
}

/// The wake for a backend thread: captured where the thread is spawned
/// (the Engine thread), since thread-locals do not cross threads.
fn wake() -> Option<Arc<dyn Fn() + Send + Sync>> {
    WAKE.with(|held| held.borrow().clone())
}

impl SystemBackend {
    fn spawn(&self, work: impl FnOnce(&dyn Fn(Event)) + Send + 'static) {
        let arrivals = self.arrivals.clone();
        let wake = wake();
        std::thread::spawn(move || {
            let send = |event: Event| {
                arrivals
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .push(event);
                if let Some(wake) = &wake {
                    wake();
                }
            };
            work(&send);
        });
    }
}

impl Backend for SystemBackend {
    fn fetch(&mut self, environment: &Environment) -> Vec<Event> {
        let environment = environment.clone();
        self.spawn(move |send| {
            let agent = ureq::Agent::config_builder()
                .timeout_global(Some(FEED_TIMEOUT))
                .build()
                .new_agent();
            let result = agent
                .get(&environment.feed_url)
                .header("Accept", "application/vnd.github+json")
                .call();
            match result {
                Err(error) => send(Event::Fetched(Err(error.to_string()))),
                Ok(mut response) => match response.body_mut().read_to_vec() {
                    Ok(bytes) => {
                        // The Apple Silicon build for a Mac running the
                        // Intel one.
                        send(Event::Fetched(Ok(logic::parse_feed(
                            &bytes,
                            &environment.platform,
                            &environment.host_arch,
                        ))));
                    }
                    Err(error) => send(Event::Fetched(Err(error.to_string()))),
                },
            }
        });
        Vec::new()
    }

    fn download(&mut self, release: &Release) -> Vec<Event> {
        use sha2::Digest as _;
        use std::io::Read as _;
        let Some(dir) = staging_dir(&release.version) else {
            return vec![Event::Downloaded(Some(
                "Could not create the staging folder.".into(),
            ))];
        };
        // The staged path is the download's, known before it lands.
        if let Some(dir) = staging_dir(&release.version) {
            let file_name = release.asset.rsplit('/').next().unwrap_or("update");
            self.staged
                .insert(release.version.clone(), dir.join(file_name));
        }
        let release = release.clone();
        self.spawn(move |send| {
            let fail = |message: String| send(Event::Downloaded(Some(message)));
            let _ = std::fs::remove_dir_all(&dir);
            if let Err(error) = std::fs::create_dir_all(&dir) {
                fail(format!("Could not create {}.", dir.display()));
                let _ = error;
                return;
            }
            let file_name = release
                .asset
                .rsplit('/')
                .next()
                .unwrap_or("update")
                .to_owned();
            let path = dir.join(format!("{file_name}.part"));
            let agent = ureq::Agent::config_builder()
                .timeout_global(Some(Duration::from_secs(60)))
                .build()
                .new_agent();
            let response = match agent.get(&release.asset).call() {
                Ok(response) => response,
                Err(error) => return fail(error.to_string()),
            };
            let total = response
                .headers()
                .get("content-length")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.parse::<i64>().ok())
                .filter(|t| *t > 0)
                .unwrap_or(release.size);
            // Hashed as it arrives: a whole AppImage at the end would
            // freeze the window.
            let mut file = match std::fs::File::create(&path) {
                Ok(file) => file,
                Err(error) => return fail(error.to_string()),
            };
            let mut hasher = sha2::Sha256::new();
            let mut reader = response.into_body().into_reader();
            let mut buffer = [0u8; 64 * 1024];
            let mut received: i64 = 0;
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => {
                        use std::io::Write as _;
                        if file.write_all(&buffer[..count]).is_err() {
                            let _ = std::fs::remove_file(&path);
                            return fail("Could not write the download.".into());
                        }
                        hasher.update(&buffer[..count]);
                        received += count as i64;
                        if total > 0 {
                            send(Event::Progress((received * 100 / total).min(100)));
                        }
                    }
                    Err(error) => {
                        let _ = std::fs::remove_file(&path);
                        return fail(error.to_string());
                    }
                }
            }
            drop(file);
            if release.size > 0 && received != release.size {
                let _ = std::fs::remove_file(&path);
                return fail(format!(
                    "The download of {} was incomplete.",
                    release.version
                ));
            }
            if logic::digest_hex(&hasher) != release.sha256 {
                let _ = std::fs::remove_file(&path);
                return fail(format!(
                    "The download of {} does not match its published digest.",
                    release.version
                ));
            }
            let staged = dir.join(&file_name);
            let _ = std::fs::remove_file(&staged);
            if std::fs::rename(&path, &staged).is_err() {
                return fail("Could not stage the update.".into());
            }
            send(Event::Downloaded(None));
        });
        Vec::new()
    }

    fn staged(&self, version: &str) -> bool {
        self.staged.get(version).is_some_and(|path| path.exists())
    }

    fn install(&mut self, environment: &Environment, version: &str) -> Vec<Event> {
        if !self.staged(version) {
            return vec![Event::Installed(Some(
                "The downloaded update is gone.".into(),
            ))];
        }
        let file = self.staged.get(version).cloned().unwrap_or_default();
        let environment = environment.clone();
        self.spawn(move |send| {
            let done = |error: Option<String>| send(Event::Installed(error));
            match environment.platform.as_str() {
                "linux" => done(install_app_image(&environment.app_image, &file)),
                "macos" => done(install_bundle(&file)),
                _ => done(Some("This platform cannot install updates.".into())),
            }
        });
        Vec::new()
    }

    fn arrive(&mut self) -> Vec<Event> {
        std::mem::take(&mut *self.arrivals.lock().unwrap_or_else(|e| e.into_inner()))
    }
}

fn relaunch(target: &str, staged: &str, open_with: &str) -> bool {
    std::process::Command::new("/bin/sh")
        .args([
            "-c",
            RELAUNCH,
            "hal-c2-update",
            &std::process::id().to_string(),
            target,
            staged,
            open_with,
        ])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .is_ok()
}

/// The new AppImage beside the old one, then renamed over it: the
/// running copy keeps its open file.
fn install_app_image(app_image: &str, staged: &PathBuf) -> Option<String> {
    if app_image.is_empty() {
        return Some("The app is not running from an AppImage.".into());
    }
    let next = format!("{app_image}.update");
    let _ = std::fs::remove_file(&next);
    if std::fs::copy(staged, &next).is_err() {
        return Some(format!("Could not write {next}."));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        if let Ok(metadata) = std::fs::metadata(app_image) {
            let mode = metadata.permissions().mode() | 0o100;
            let _ = std::fs::set_permissions(&next, std::fs::Permissions::from_mode(mode));
        }
    }
    if std::fs::rename(&next, app_image).is_err() {
        let _ = std::fs::remove_file(&next);
        return Some(format!("Could not replace {app_image}."));
    }
    if !relaunch(app_image, "", "") {
        return Some("Could not start the updated app.".into());
    }
    None
}

/// Unzips the new bundle beside the staged zip; the helper swaps it in
/// once this process is gone.
fn install_bundle(zip: &PathBuf) -> Option<String> {
    let exe = std::env::current_exe().unwrap_or_default();
    let shown = exe.to_string_lossy();
    let Some(end) = shown.find(".app/") else {
        return Some("The app is not running from its bundle.".into());
    };
    let bundle = shown[..end + 4].to_owned();
    let unpacked = zip.parent().map(|dir| dir.join("unpacked"))?;
    let _ = std::fs::remove_dir_all(&unpacked);
    let status = std::process::Command::new("/usr/bin/ditto")
        .args(["-x", "-k"])
        .arg(zip)
        .arg(&unpacked)
        .status();
    if !matches!(status, Ok(status) if status.success()) {
        return Some("Could not unpack the update.".into());
    }
    let app = std::fs::read_dir(&unpacked)
        .ok()?
        .flatten()
        .find(|entry| entry.file_name().to_string_lossy().ends_with(".app"))?;
    if !relaunch(&bundle, &app.path().to_string_lossy(), "/usr/bin/open") {
        return Some("Could not start the updated app.".into());
    }
    None
}
