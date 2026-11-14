//! The desktop app's own updates (`desktopUpdate`): the @desktop
//! scenarios of features/settings/updates.feature's "Updating the
//! desktop app". The feed, the download, the install and the clock are
//! fakes in the platform seam, fresh for every scenario's MC; the app
//! is a packaged Linux AppImage on 1.3.0 unless a scenario says
//! otherwise. The MC side is the wire:
//! `server.reportDesktopUpdateStatus` calls are recorded and
//! `desktopUpdateControl` frames are sent as the MC sends them.
//! desktop-qt's DesktopUpdateSteps.cpp.

use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::rc::Rc;

use hal_c2_shell::controller;
use hal_c2_shell::controllers::desktop_update::{
    Backend, Clock, Event, PREPARED_TTL_MS, Platform, set_platform, update_platform,
};
use hal_c2_shell::controllers::settings::Settings;
use hal_c2_shell::desktop_update::{self as logic, Environment, Release, State};
use ljos::prelude::Engine;
use serde_json::{Value, json};
use sha2::Digest as _;

use crate::expect;
use crate::fake_mc::{FakeMc, Rpc};
use crate::harness::{Outcome, Q, Steps, at, show, text};
use crate::world::World;

struct Timer {
    due: i64,
    order: u64,
    run: Rc<dyn Fn(&Engine)>,
}

struct FakeClockInner {
    now: i64,
    next: u64,
    timers: Vec<Timer>,
}

#[derive(Clone)]
struct FakeClock(Rc<RefCell<FakeClockInner>>);

impl FakeClock {
    fn new() -> FakeClock {
        FakeClock(Rc::new(RefCell::new(FakeClockInner {
            now: chrono::DateTime::parse_from_rfc3339("2026-09-23T10:00:00Z")
                .expect("the scenarios' time")
                .timestamp_millis(),
            next: 0,
            timers: Vec::new(),
        })))
    }

    /// Runs every timer due by then, in order.
    fn advance(&self, engine: &Engine, ms: i64) {
        let end = self.0.borrow().now + ms;
        loop {
            let timer = {
                let mut inner = self.0.borrow_mut();
                let due = inner
                    .timers
                    .iter()
                    .enumerate()
                    .min_by(|(_, a), (_, b)| a.due.cmp(&b.due).then(a.order.cmp(&b.order)))
                    .map(|(index, _)| index);
                match due {
                    Some(index) if inner.timers[index].due <= end => {
                        let timer = inner.timers.remove(index);
                        inner.now = inner.now.max(timer.due);
                        timer
                    }
                    _ => break,
                }
            };
            (timer.run)(engine);
        }
        self.0.borrow_mut().now = end;
    }
}

impl Clock for FakeClock {
    fn now_ms(&self) -> i64 {
        self.0.borrow().now
    }
    fn after(&self, _engine: &Engine, ms: i64, run: Rc<dyn Fn(&Engine)>) {
        let mut inner = self.0.borrow_mut();
        let order = inner.next;
        inner.next += 1;
        let due = inner.now + ms;
        inner.timers.push(Timer { due, order, run });
    }
}

/// The feed, the download and the install. Each answers at once unless held.
#[derive(Default)]
struct FakeBackend {
    releases: Vec<Release>,
    fetch_error: Option<String>,
    hold_fetch: bool,
    fetches: i32,
    held_fetches: i32,
    download_error: Option<String>,
    hold_download: bool,
    downloads: i32,
    downloading: String,
    download_held: bool,
    staged_versions: HashSet<String>,
    install_error: Option<String>,
    hold_install: bool,
    installs: i32,
    installing: String,
    install_held: bool,
    installed: String,
    events: Vec<Event>,
}

impl FakeBackend {
    fn answer(&self) -> Event {
        match &self.fetch_error {
            Some(error) => Event::Fetched(Err(error.clone())),
            None => Event::Fetched(Ok(self.releases.clone())),
        }
    }
    fn fetching(&self) -> bool {
        self.held_fetches > 0
    }
    fn answer_fetches(&mut self) {
        self.hold_fetch = false;
        for _ in 0..std::mem::take(&mut self.held_fetches) {
            let event = self.answer();
            self.events.push(event);
        }
    }
    fn finish_download(&mut self) -> Event {
        if let Some(error) = &self.download_error {
            return Event::Downloaded(Some(error.clone()));
        }
        self.staged_versions.insert(self.downloading.clone());
        Event::Downloaded(None)
    }
    fn downloading_held(&self) -> bool {
        self.download_held
    }
    fn progress(&mut self, percent: i64) {
        self.events.push(Event::Progress(percent));
    }
    fn complete_download(&mut self) {
        self.download_held = false;
        let event = self.finish_download();
        self.events.push(event);
    }
    fn finish_install(&mut self) -> Event {
        if let Some(error) = &self.install_error {
            return Event::Installed(Some(error.clone()));
        }
        self.installed = self.installing.clone();
        Event::Installed(None)
    }
    fn installing_held(&self) -> bool {
        self.install_held
    }
    fn complete_install(&mut self) {
        self.install_held = false;
        let event = self.finish_install();
        self.events.push(event);
    }
}

impl Backend for FakeBackend {
    fn fetch(&mut self, _environment: &Environment) -> Vec<Event> {
        self.fetches += 1;
        if self.hold_fetch {
            self.held_fetches += 1;
            return Vec::new();
        }
        vec![self.answer()]
    }
    fn download(&mut self, release: &Release) -> Vec<Event> {
        self.downloads += 1;
        self.downloading = release.version.clone();
        if self.hold_download {
            self.download_held = true;
            return Vec::new();
        }
        vec![self.finish_download()]
    }
    fn staged(&self, version: &str) -> bool {
        self.staged_versions.contains(version)
    }
    fn install(&mut self, _environment: &Environment, version: &str) -> Vec<Event> {
        self.installs += 1;
        self.installing = version.to_owned();
        if self.hold_install {
            self.install_held = true;
            return Vec::new();
        }
        vec![self.finish_install()]
    }
    fn arrive(&mut self) -> Vec<Event> {
        std::mem::take(&mut self.events)
    }
}

#[derive(Default)]
struct Fake {
    backend: Rc<RefCell<FakeBackend>>,
    clock: FakeClock,
    parsed: Vec<Release>,
    downloaded_bytes: Vec<u8>,
    mc_stops: Rc<Cell<i32>>,
    mc_starts: Rc<Cell<i32>>,
    quit: Rc<Cell<bool>>,
    open_fails: Rc<Cell<bool>>,
    opened: Rc<RefCell<Vec<String>>>,
    /// What the last failure the scenario caused gave as its reason.
    reason: String,
    windows: Vec<String>,
    /// A release-notes state the scenario reads instead of the app's.
    notes: Option<State>,
    /// What each step of "the update track cannot change" was told.
    track_refusals: Vec<String>,
    track_before: String,
    /// Release notes written with markup, for the next release offered.
    markup: String,
}

impl Default for FakeClock {
    fn default() -> FakeClock {
        FakeClock::new()
    }
}

/// The scenario's fake, on its MC as the extension put it there.
#[derive(Default)]
struct SharedFake(Option<Rc<RefCell<Fake>>>);

fn fake(world: &mut World) -> Rc<RefCell<Fake>> {
    world
        .mc
        .part::<SharedFake>()
        .0
        .clone()
        .expect("the desktop update fake")
}

fn packaged() -> Environment {
    Environment {
        app_version: "1.3.0".into(),
        platform: "linux".into(),
        app_image: "/opt/hal-c2/HAL-C2.AppImage".into(),
        packaged: true,
        feed_url: "https://updates.example/releases".into(),
        host_arch: "x64".into(),
        app_arch: "x64".into(),
        ..Environment::default()
    }
}

fn environment_of() -> Environment {
    update_platform(|platform| platform.environment.get_or_insert_with(packaged).clone())
}

fn change_environment(change: impl FnOnce(&mut Environment)) {
    update_platform(|platform| {
        let environment = platform.environment.get_or_insert_with(packaged);
        change(environment);
    });
}

fn view(world: &World) -> Value {
    world.state("desktopUpdate")
}

fn shown_state(world: &World) -> Value {
    view(world)["state"].clone()
}

fn describe(world: &World) -> String {
    format!("the update stands at {}", show(&view(world)))
}

/// The shell connected and its updater running.
fn ready(world: &mut World) -> Outcome {
    if !world.running() {
        world.launch();
    }
    if !view(world).is_null() {
        return Ok(());
    }
    if !world.client_ready() {
        world.connect()?;
    }
    world.wait_for("the update button to be shown", |w| !view(w).is_null())
}

/// The app as `change` leaves this machine, from its start.
fn given(world: &mut World, change: impl FnOnce(&mut Environment)) -> Outcome {
    let started = world.running() && !view(world).is_null();
    change_environment(change);
    if started {
        world.restart()?;
        world.connect()?;
    }
    ready(world)
}

fn dispatch(world: &mut World, action: &str, payload: Value) -> Outcome {
    ready(world)?;
    world.dispatch(action, payload)?;
    world.sync()
}

fn wait_status(world: &mut World, status: &str) -> Outcome {
    let status = status.to_owned();
    world.wait_for_with(|w| view(w)["status"] == status.as_str(), describe)
}

fn release(version: &str, notes: &str) -> Release {
    Release {
        version: version.to_owned(),
        notes: notes.to_owned(),
        prerelease: version.contains('-'),
        asset: format!("https://updates.example/HAL-C2-{version}-x86_64.AppImage"),
        size: 1024,
        sha256: String::new(),
    }
}

fn backend(world: &mut World) -> Rc<RefCell<FakeBackend>> {
    fake(world).borrow().backend.clone()
}

fn check(world: &mut World) -> Outcome {
    dispatch(world, "desktopUpdate.check", json!({}))
}

fn offer(world: &mut World, version: &str) -> Outcome {
    offer_with(world, version, "")
}

fn offer_with(world: &mut World, version: &str, notes: &str) -> Outcome {
    ready(world)?;
    backend(world).borrow_mut().releases = vec![release(version, notes)];
    check(world)?;
    wait_status(world, "available")
}

fn download(world: &mut World) -> Outcome {
    dispatch(world, "desktopUpdate.press", json!({}))
}

fn downloaded(world: &mut World, version: &str) -> Outcome {
    offer(world, version)?;
    download(world)?;
    wait_status(world, "downloaded")
}

fn answer(world: &mut World, accepted: bool) -> Outcome {
    let question = world.state("confirmation");
    expect!(
        question.is_object(),
        "no question is asked; it is {}",
        show(&question)
    );
    world.dispatch(
        "confirmation.answer",
        json!({"requestId": question["requestId"], "accepted": accepted}),
    )?;
    world.sync()
}

/// Restart and install, confirmed.
fn install(world: &mut World) -> Outcome {
    dispatch(world, "desktopUpdate.press", json!({}))?;
    answer(world, true)
}

fn toasts(world: &World) -> Vec<Value> {
    world.state("toasts")["items"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn toast(world: &mut World, title: &str, description: &str) -> Outcome<Value> {
    let (title, description) = (title.to_owned(), description.to_owned());
    world.wait_for_with(
        |w| {
            toasts(w)
                .iter()
                .any(|t| t["title"] == title.as_str() && t["description"] == description.as_str())
        },
        |w| {
            format!(
                "the toast \"{title}\" saying \"{description}\"; the shell shows {}",
                show(&Value::Array(toasts(w)))
            )
        },
    )?;
    Ok(toasts(world)
        .into_iter()
        .find(|t| t["title"] == title.as_str() && t["description"] == description.as_str())
        .unwrap_or(Value::Null))
}

fn channel_named(track: &str) -> &'static str {
    if track == "Nightly" {
        logic::NIGHTLY
    } else {
        logic::STABLE
    }
}

fn switch_track(world: &mut World, track: &str) -> Outcome {
    dispatch(
        world,
        "desktopUpdate.setTrack",
        json!({"channel": channel_named(track)}),
    )
}

/// The server's requests, as the MC sends them.
fn control(world: &mut World, kind: &str, request_id: &str) -> Outcome {
    ready(world)?;
    world.wait_for("the app to take the MC's update requests", |w| {
        !w.mc.subscribers("desktopUpdateControl").is_empty()
    })?;
    for id in world.mc.subscribers("desktopUpdateControl") {
        world.mc.send(&json!({
            "t": "desktopUpdateControl",
            "id": id,
            "event": {"version": 1, "type": kind, "requestId": request_id},
        }));
    }
    world.sync()
}

fn reports(world: &World, request_id: &str) -> Vec<Value> {
    world
        .mc
        .calls
        .iter()
        .filter(|call| call.method == "server.reportDesktopUpdateStatus")
        .filter(|call| request_id.is_empty() || text(&call.payload["requestId"]) == request_id)
        .map(|call| call.payload.clone())
        .collect()
}

fn outcome(world: &World, request_id: &str) -> Option<Value> {
    reports(world, request_id)
        .into_iter()
        .find(|report| !report["outcome"].is_null())
}

fn wait_outcome(world: &mut World, request_id: &str) -> Outcome<Value> {
    let id = request_id.to_owned();
    world.wait_for_with(
        |w| outcome(w, &id).is_some(),
        |w| {
            format!(
                "an outcome for {id}; the MC heard {}",
                show(&Value::Array(reports(w, "")))
            )
        },
    )?;
    Ok(outcome(world, request_id).unwrap_or(Value::Null))
}

fn prepare(world: &mut World, request_id: &str) -> Outcome {
    backend(world).borrow_mut().releases = vec![release("1.4.0", "")];
    control(world, "requestDesktopUpdate", request_id)?;
    let report = wait_outcome(world, request_id)?;
    expect!(report["outcome"] == "ready-to-install", "{}", show(&report));
    Ok(())
}

fn popover(world: &mut World) -> Value {
    if let Some(notes) = &fake(world).borrow().notes {
        return logic::popover(notes);
    }
    view(world)["popover"].clone()
}

fn groups(world: &mut World) -> Vec<Value> {
    popover(world)["groups"]
        .as_array()
        .cloned()
        .unwrap_or_default()
}

fn items(group: &Value) -> Vec<String> {
    group["items"]
        .as_array()
        .into_iter()
        .flatten()
        .map(text)
        .collect()
}

const NIGHTLY_CURRENT: &str = "1.4.0-nightly.20260901.1";

fn nightly(day: i64) -> String {
    format!("1.4.0-nightly.202609{day:02}.1")
}

/// A nightly app finds the release that has `notes`.
fn nightly_notes(world: &mut World, releases: Vec<Release>) -> Outcome {
    given(world, |environment| {
        environment.app_version = NIGHTLY_CURRENT.into();
    })?;
    backend(world).borrow_mut().releases = releases;
    check(world)?;
    wait_status(world, "available")
}

fn bare(version: &str) -> &str {
    version.strip_prefix('v').unwrap_or(version)
}

fn extend(mc: &mut FakeMc) {
    let fake = Rc::new(RefCell::new(Fake::default()));
    let (backend_rc, clock, stops, starts, quit, open_fails, opened) = {
        let fake_ref = fake.borrow();
        (
            fake_ref.backend.clone(),
            fake_ref.clock.clone(),
            fake_ref.mc_stops.clone(),
            fake_ref.mc_starts.clone(),
            fake_ref.quit.clone(),
            fake_ref.open_fails.clone(),
            fake_ref.opened.clone(),
        )
    };
    set_platform(Platform {
        environment: Some(packaged()),
        backend: Some(backend_rc as Rc<RefCell<dyn Backend>>),
        clock: Some(Rc::new(clock) as Rc<dyn Clock>),
        stop_mc: Some(Rc::new(move || stops.set(stops.get() + 1))),
        start_mc: Some(Rc::new(move || starts.set(starts.get() + 1))),
        quit: Some(Rc::new(move || quit.set(true))),
        open_url: Some(Rc::new(move |url: &str| {
            if open_fails.get() {
                return false;
            }
            opened.borrow_mut().push(url.to_owned());
            true
        })),
        persist_track: None,
    });
    mc.part::<SharedFake>().0 = Some(fake);
    mc.on_rpc("server.reportDesktopUpdateStatus", |mc, rpc: &Rpc| {
        mc.reply(rpc, json!({}));
        Ok(())
    });
    mc.on_shape("desktopUpdateControl", |_, _, _| Ok(()));
}

/// Why something the scenario refused failed, as the toast gives it
/// (desktop-qt's `World::reason`): a step that makes something fail sets it.
#[derive(Default)]
pub struct Reason(pub String);

pub fn register(steps: &mut Steps) {
    steps.extension(extend);

    // Downloading and installing.
    steps.step(&format!("an update to {Q} is available"), |world, c, _| {
        offer(world, &c[0].clone())
    });
    steps.step("the user downloads it", |world, _, _| {
        backend(world).borrow_mut().hold_download = true;
        download(world)?;
        wait_status(world, "downloading")
    });
    steps.step("the download shows its progress", |world, _, _| {
        backend(world).borrow_mut().progress(30);
        world.wait_for_with(|w| view(w)["label"] == "Downloading update (30%)", describe)?;
        backend(world).borrow_mut().complete_download();
        world.sync()?;
        wait_status(world, "downloaded")
    });
    steps.step(
        "the user restarts to install and confirms",
        |world, _, _| {
            // A second window, to come back with the first. The headless
            // shell shows nothing for a window it opens.
            controller::set_window_opener(world.engine(), |_, _| {});
            let _ = controller::open_window(world.engine(), None);
            fake(world).borrow_mut().windows = controller::windows(world.engine());
            install(world)
        },
    );
    steps.step(
        &format!("the app relaunches on {Q} with the same windows"),
        |world, c, _| {
            let fake_rc = fake(world);
            world.wait_for("the app to quit for the new version", {
                let fake_rc = fake_rc.clone();
                move |_| fake_rc.borrow().quit.get()
            })?;
            let installed = backend(world).borrow().installed.clone();
            expect!(
                installed == c[0] && fake_rc.borrow().mc_stops.get() == 1,
                "installed \"{installed}\""
            );
            // The new build starts where this one stopped.
            let version = c[0].clone();
            change_environment(|environment| environment.app_version = version);
            world.restart()?;
            world.connect()?;
            ready(world)?;
            // The shell reopens the windows it saved as it starts; the app's
            // own window host for that is #569.
            controller::set_window_opener(world.engine(), |_, _| {});
            controller::restore_windows(world.engine());
            let windows = controller::windows(world.engine());
            let wanted = fake_rc.borrow().windows.clone();
            expect!(
                windows == wanted,
                "the windows are {}, not {}",
                windows.join(","),
                wanted.join(",")
            );
            expect!(
                view(world)["currentVersion"] == c[0].as_str(),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    steps.step("an update download failed", |world, _, _| {
        ready(world)?;
        backend(world).borrow_mut().download_error = Some("Network unreachable".into());
        offer(world, "1.4.0")?;
        download(world)?;
        world.wait_for_with(|w| shown_state(w)["errorContext"] == "download", describe)?;
        // The next try goes through.
        let backend = backend(world);
        backend.borrow_mut().download_error = None;
        backend.borrow_mut().hold_download = true;
        Ok(())
    });
    steps.step("the download starts again", |world, _, _| {
        wait_status(world, "downloading")?;
        let backend = backend(world);
        let backend = backend.borrow();
        expect!(
            backend.downloads == 2 && backend.downloading_held(),
            "{}",
            describe(world)
        );
        Ok(())
    });

    // The sidebar's update button.
    steps.step("the app is up to date", |world, _, _| {
        ready(world)?;
        check(world)?;
        wait_status(world, "up-to-date")
    });
    steps.step("the app is checking for an update", |world, _, _| {
        ready(world)?;
        backend(world).borrow_mut().hold_fetch = true;
        check(world)?;
        wait_status(world, "checking")
    });
    steps.step("update v([0-9.]+) is available", |world, c, _| {
        offer(world, &c[0].clone())
    });
    steps.step(
        "update v([0-9.]+) is downloading at (\\d+) percent",
        |world, c, _| {
            offer(world, &c[0].clone())?;
            backend(world).borrow_mut().hold_download = true;
            download(world)?;
            backend(world)
                .borrow_mut()
                .progress(c[1].parse().unwrap_or(0));
            world.sync()
        },
    );
    steps.step("update v([0-9.]+) was downloaded", |world, c, _| {
        downloaded(world, &c[0].clone())
    });
    steps.step("the download of v([0-9.]+) failed", |world, c, _| {
        ready(world)?;
        backend(world).borrow_mut().download_error = Some("Network unreachable".into());
        offer(world, &c[0].clone())?;
        download(world)?;
        world.wait_for_with(|w| shown_state(w)["errorContext"] == "download", describe)
    });
    steps.step("the install of v([0-9.]+) failed", |world, c, _| {
        downloaded(world, &c[0].clone())?;
        backend(world).borrow_mut().install_error = Some("Disk full".into());
        install(world)?;
        world.wait_for_with(|w| shown_state(w)["errorContext"] == "install", describe)
    });
    steps.step(
        "the user points at the update button in the sidebar",
        |world, _, _| {
            ready(world)?;
            expect!(
                view(world)["shown"] == json!(true),
                "the sidebar shows no update button: {}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(&format!("its tooltip says {Q}"), |world, c, _| {
        let wanted = c[0].clone();
        world.wait_for_with(|w| view(w)["label"] == wanted.as_str(), describe)
    });

    // Restarting to install.
    steps.step(&format!("update {Q} was downloaded"), |world, c, _| {
        downloaded(world, bare(&c[0].clone()))
    });
    steps.step(
        &format!("update {Q} finished downloading"),
        |world, c, _| downloaded(world, bare(&c[0].clone())),
    );
    steps.step("the user chooses to restart and install", |world, _, _| {
        dispatch(world, "desktopUpdate.press", json!({}))
    });
    steps.step(
        &format!("the user is asked {Q} and told running tasks will be interrupted"),
        |world, c, _| {
            let question = world.state("confirmation");
            expect!(
                question["title"] == c[0].as_str()
                    && question["description"] == logic::CONFIRMATION_DETAIL,
                "the user is asked {}",
                show(&question)
            );
            Ok(())
        },
    );
    steps.step("the user declines", |world, _, _| answer(world, false));
    steps.step(
        "the app keeps running on its current version",
        |world, _, _| {
            world.sync()?;
            expect!(
                !fake(world).borrow().quit.get()
                    && backend(world).borrow().installed.is_empty()
                    && world.running(),
                "the app quit for the update"
            );
            expect!(
                view(world)["currentVersion"] == environment_of().app_version.as_str(),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    // Failures.
    steps.step(
        &format!("the user checks for updates and it fails with {Q}"),
        |world, c, _| {
            ready(world)?;
            backend(world).borrow_mut().fetch_error = Some(c[0].clone());
            fake(world).borrow_mut().reason = c[0].clone();
            check(world)
        },
    );
    steps.step(
        &format!("the user downloads the update and it fails with {Q}"),
        |world, c, _| {
            offer(world, "1.4.0")?;
            backend(world).borrow_mut().download_error = Some(c[0].clone());
            fake(world).borrow_mut().reason = c[0].clone();
            download(world)
        },
    );
    steps.step(
        &format!("the user restarts to install and it fails with {Q}"),
        |world, c, _| {
            downloaded(world, "1.4.0")?;
            backend(world).borrow_mut().install_error = Some(c[0].clone());
            fake(world).borrow_mut().reason = c[0].clone();
            install(world)
        },
    );
    steps.step(
        &format!("the user is told {Q} with the reason"),
        |world, c, _| {
            // A command the MC refused (threads/settle.feature) gave its
            // reason there.
            let reason = if world.mc.refusals.len() == 1 {
                world
                    .mc
                    .refusals
                    .values()
                    .next()
                    .cloned()
                    .unwrap_or_default()
            } else if let Some(Reason(reason)) = world.peek_part::<Reason>() {
                reason.clone()
            } else {
                fake(world).borrow().reason.clone()
            };
            toast(world, &c[0], &reason)?;
            Ok(())
        },
    );
    steps.step(&format!("the user is told {Q} with {Q}"), |world, c, _| {
        let description = if c[1] == "the reason this build cannot update itself" {
            fake(world).borrow().reason.clone()
        } else {
            c[1].clone()
        };
        toast(world, &c[0], &description)?;
        Ok(())
    });
    steps.step(
        "this build has automatic updates turned off and does not say why",
        |world, _, _| given(world, |environment| environment.unexplained = true),
    );
    steps.step("the user checks for updates", |world, _, _| check(world));

    // Release notes.
    steps.step(
        "the user is on the (Nightly|Stable) track",
        |world, c, _| {
            let version = if c[0] == "Nightly" {
                NIGHTLY_CURRENT.to_owned()
            } else {
                "1.3.0".to_owned()
            };
            given(world, |environment| environment.app_version = version)?;
            expect!(view(world)["track"] == c[0].as_str(), "{}", describe(world));
            Ok(())
        },
    );
    steps.step("a nightly update has release notes", |world, _, _| {
        backend(world).borrow_mut().releases = vec![
            release(&nightly(3), "- Newest change"),
            release(&nightly(2), "- Middle change"),
            release(NIGHTLY_CURRENT, "- Installed change"),
        ];
        check(world)?;
        wait_status(world, "available")
    });
    steps.step(
        &format!("the user sees {Q} with the notes of the newest release"),
        |world, c, _| {
            let shown = groups(world);
            expect!(
                !shown.is_empty()
                    && shown[0]["title"] == c[0].as_str()
                    && shown[0]["version"] == nightly(3).as_str()
                    && items(&shown[0]) == ["Newest change"],
                "the notes are {}",
                show(&popover(world))
            );
            Ok(())
        },
    );
    steps.step(
        &format!("each older release in between is listed under {Q} its version"),
        |world, c, _| {
            let shown = groups(world);
            expect!(
                shown.len() == 2
                    && shown[1]["title"] == format!("{} {}", c[0], nightly(2)).as_str()
                    && items(&shown[1]) == ["Middle change"],
                "the notes are {}",
                show(&popover(world))
            );
            Ok(())
        },
    );
    steps.step(
        "a nightly release lists (\\d+) of (\\d+) changes and (\\d+) older releases were left out",
        |world, c, _| {
            let state = logic::initial(NIGHTLY_CURRENT, logic::NIGHTLY, true);
            let mut note = logic::ReleaseNote {
                version: nightly(3),
                items: Vec::new(),
                total_items: c[1].parse().unwrap_or(0),
            };
            for i in 0..c[0].parse::<i32>().unwrap_or(0) {
                note.items.push(format!("Change {}", i + 1));
            }
            fake(world).borrow_mut().notes = Some(logic::on_update_available(
                state,
                &nightly(3),
                "2026-09-23T10:00:00.000Z",
                vec![note],
                c[2].parse().unwrap_or(0),
            ));
            Ok(())
        },
    );
    steps.step("the user reads the release notes", |world, _, _| {
        if fake(world).borrow().notes.is_none() {
            ready(world)?;
        }
        Ok(())
    });
    steps.step(&format!("the user sees a link {Q}"), |world, c, _| {
        let shown = popover(world);
        let mut links = vec![text(&shown["footer"])];
        for group in groups(world) {
            links.push(text(&group["link"]));
        }
        expect!(links.contains(&c[0]), "the links are {}", links.join(" | "));
        Ok(())
    });
    steps.step(
        "a release's notes are written with markup, links and bold text",
        |world, _, _| {
            fake(world).borrow_mut().markup =
                "<ul><li>**Faster** threads by @maria in [#12](https://github.com/hal-c2/hal-c2/pull/12)</li></ul>\n"
                    .to_owned();
            Ok(())
        },
    );
    steps.step("one change is longer than 220 characters", |world, _, _| {
        let note = format!("{}- {}", fake(world).borrow().markup, "a".repeat(240));
        nightly_notes(world, vec![release(&nightly(2), &note)])
    });
    steps.step(
        "each change is plain text with links shown as their words",
        |world, _, _| {
            let listed = items(&groups(world).into_iter().next().unwrap_or(Value::Null));
            expect!(
                listed.contains(&"Faster threads by @maria in #12".to_owned()),
                "the changes are {}",
                listed.join("|")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("the long change is cut short with {Q}"),
        |world, c, _| {
            let listed = items(&groups(world).into_iter().next().unwrap_or(Value::Null));
            expect!(
                listed
                    .iter()
                    .any(|item| item.chars().count() == 220 && item.ends_with(&c[0])),
                "the changes are {}",
                listed.join("|")
            );
            Ok(())
        },
    );
    steps.step(
        &format!("a release's notes contain a {Q} heading, compare links, {Q} and {Q}"),
        |world, c, _| {
            nightly_notes(
                world,
                vec![release(
                    &nightly(2),
                    &format!(
                        "## {}\n* Fix the sidebar by @maria\n\nCompare: https://github.com/hal-c2/hal-c2/compare/a...b\n\n## {}\n* @maria made their first contribution\n\n**{}**: https://github.com/hal-c2/hal-c2/compare/v1...v2\n",
                        c[0], c[1], c[2]
                    ),
                )],
            )
        },
    );
    steps.step("only the changes themselves are listed", |world, _, _| {
        let shown = groups(world);
        expect!(
            shown.len() == 1 && items(&shown[0]) == ["Fix the sidebar by @maria"],
            "the notes are {}",
            show(&popover(world))
        );
        Ok(())
    });
    steps.step(
        "the notes cover a manually cut preview release as well as nightly releases",
        |world, _, _| {
            backend(world).borrow_mut().releases = vec![
                release("1.4.0-preview.1", "- Preview change"),
                release(&nightly(3), "- Third nightly"),
                release(&nightly(2), "- Second nightly"),
            ];
            check(world)?;
            wait_status(world, "available")
        },
    );
    steps.step("only the nightly releases are listed", |world, _, _| {
        let versions: Vec<String> = groups(world)
            .iter()
            .map(|group| text(&group["version"]))
            .collect();
        expect!(
            versions == [nightly(3), nightly(2)],
            "the notes list {}",
            versions.join(",")
        );
        Ok(())
    });
    steps.step(
        "a release's notes contain only a heading and a compare link",
        |world, _, _| {
            nightly_notes(
                world,
                vec![
                    release(&nightly(3), "- Third nightly"),
                    release(
                        &nightly(2),
                        "## What's Changed\nhttps://github.com/hal-c2/hal-c2/compare/a...b\n",
                    ),
                ],
            )
        },
    );
    steps.step("that release is not listed", |world, _, _| {
        let versions: Vec<String> = groups(world)
            .iter()
            .map(|group| text(&group["version"]))
            .collect();
        expect!(
            versions == [nightly(3)],
            "the notes list {}",
            versions.join(",")
        );
        Ok(())
    });
    steps.step("an update is available", |world, _, _| {
        offer_with(world, "1.4.0", "- A stable change")
    });
    steps.step(
        "the user sees only where the update stands",
        |world, _, _| {
            expect!(
                view(world)["popover"].is_null()
                    && view(world)["label"] == "Update v1.4.0 ready to download",
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    // The update track.
    steps.step(
        "the user switches the update track to (Nightly|Stable)",
        |world, c, _| {
            ready(world)?;
            if view(world)["track"] == c[0].as_str() {
                switch_track(
                    world,
                    if c[0] == "Nightly" {
                        "Stable"
                    } else {
                        "Nightly"
                    },
                )?;
            }
            fake(world).borrow_mut().reason = backend(world).borrow().fetches.to_string();
            switch_track(world, &c[0].clone())
        },
    );
    steps.step(
        "the app checks for (Nightly|Stable) releases",
        |world, c, _| {
            let before: i32 = fake(world).borrow().reason.parse().unwrap_or(0);
            expect!(
                view(world)["track"] == c[0].as_str()
                    && backend(world).borrow().fetches == before + 1,
                "{}",
                describe(world)
            );
            // This device keeps it.
            let stored = Settings::of(world.engine())
                .device_value("desktopUpdate")
                .unwrap_or(Value::Null);
            expect!(
                stored["channel"] == channel_named(&c[0]) && stored["channelChosen"] == json!(true),
                "{}",
                show(&stored)
            );
            Ok(())
        },
    );
    steps.step("the user can switch back at any time", |world, _, _| {
        let back = if view(world)["track"] == "Nightly" {
            "Stable"
        } else {
            "Nightly"
        };
        expect!(
            view(world)["canChangeTrack"] == json!(true),
            "{}",
            describe(world)
        );
        switch_track(world, back)?;
        expect!(view(world)["track"] == back, "{}", describe(world));
        Ok(())
    });
    steps.step(
        "the update track is (?:still )?(Nightly|Stable)",
        |world, c, _| {
            ready(world)?;
            if !world.checking && view(world)["track"] != c[0].as_str() {
                switch_track(world, &c[0].clone())?;
            }
            expect!(view(world)["track"] == c[0].as_str(), "{}", describe(world));
            Ok(())
        },
    );
    steps.step(
        &format!("the user switches the update track to (Nightly|Stable) and it fails with {Q}"),
        |world, c, _| {
            ready(world)?;
            let error = c[1].clone();
            update_platform(|platform| {
                let error = error.clone();
                platform.persist_track = Some(Rc::new(move |_| Some(error.clone())));
            });
            fake(world).borrow_mut().reason = c[1].clone();
            switch_track(world, &c[0].clone())
        },
    );
    steps.step(
        "the user has never chosen an update track",
        |world, _, _| {
            expect!(
                Settings::of(world.engine())
                    .device_value("desktopUpdate")
                    .is_none(),
                "a track is already chosen"
            );
            Ok(())
        },
    );
    steps.step(
        "the installed build is a (nightly build|stable release)",
        |world, c, _| {
            let version = if c[0] == "nightly build" {
                NIGHTLY_CURRENT.to_owned()
            } else {
                "1.3.0".to_owned()
            };
            change_environment(|environment| environment.app_version = version);
            let _ = world;
            Ok(())
        },
    );
    steps.step("the (?:desktop )?app starts", |world, _, _| ready(world));
    steps.step(
        "a track the user chose earlier is kept instead",
        |world, _, _| {
            let other = if view(world)["track"] == "Nightly" {
                "Stable"
            } else {
                "Nightly"
            };
            switch_track(world, other)?;
            world.restart()?;
            world.connect()?;
            ready(world)?;
            expect!(view(world)["track"] == other, "{}", describe(world));
            Ok(())
        },
    );

    // Checking by itself.
    steps.step("this build can update itself", |world, _, _| {
        ready(world)?;
        expect!(
            shown_state(world)["enabled"] == json!(true),
            "{}",
            describe(world)
        );
        Ok(())
    });
    steps.step(
        "it checks for an update about fifteen seconds after launch",
        |world, _, _| {
            let clock = fake(world).borrow().clock.clone();
            clock.advance(world.engine(), 15_000 - 1);
            world.sync()?;
            expect!(
                backend(world).borrow().fetches == 0,
                "it checked before fifteen seconds"
            );
            clock.advance(world.engine(), 1);
            world.sync()?;
            expect!(
                backend(world).borrow().fetches == 1,
                "it checked {} times",
                backend(world).borrow().fetches
            );
            Ok(())
        },
    );
    steps.step("again every four minutes while it runs", |world, _, _| {
        let clock = fake(world).borrow().clock.clone();
        for checks in 2..=3 {
            clock.advance(world.engine(), 4 * 60_000 - 1);
            world.sync()?;
            expect!(
                backend(world).borrow().fetches == checks - 1,
                "it checked {} times",
                backend(world).borrow().fetches
            );
            clock.advance(world.engine(), 1);
            world.sync()?;
            expect!(
                backend(world).borrow().fetches == checks,
                "it checked {} times",
                backend(world).borrow().fetches
            );
        }
        Ok(())
    });

    // Builds that cannot update.
    steps.step("the update source is not https", |world, _, _| {
        given(world, |environment| {
            environment.feed_url = "http://updates.example/releases".into();
        })
    });
    steps.step("no update source is configured", |world, _, _| {
        given(world, |environment| environment.feed_url.clear())
    });
    steps.step(
        "the app runs from a development or unpacked build",
        |world, _, _| given(world, |environment| environment.packaged = false),
    );
    steps.step(
        "automatic updates were turned off for this run",
        |world, _, _| given(world, |environment| environment.disabled_by_env = true),
    );
    steps.step(
        "the app on Linux is not the AppImage build",
        |world, _, _| given(world, |environment| environment.app_image.clear()),
    );

    // The command palette's Check for Updates (this app has no application menu).
    steps.step(
        &format!("the app is on version {Q} and no newer one exists"),
        |world, c, _| {
            let version = c[0].clone();
            given(world, |environment| {
                environment.app_version = version.clone()
            })?;
            backend(world).borrow_mut().releases = vec![release(&version, "")];
            Ok(())
        },
    );
    steps.step(
        "the user chooses Check for Updates from the application menu",
        |world, _, _| {
            ready(world)?;
            expect!(
                hal_c2_shell::commands::Commands::of(world.engine())
                    .run(world.engine(), "desktopUpdate.check"),
                "the palette has no Check for Updates"
            );
            world.sync()
        },
    );
    steps.step(&format!("the check fails with {Q}"), |world, c, _| {
        ready(world)?;
        backend(world).borrow_mut().fetch_error = Some(c[0].clone());
        Ok(())
    });
    steps.step("the check fails with no reason", |world, _, _| {
        ready(world)?;
        backend(world).borrow_mut().fetch_error = Some(String::new());
        Ok(())
    });
    steps.step("this build cannot update itself", |world, _, _| {
        given(world, |environment| environment.packaged = false)?;
        let reason = text(&shown_state(world)["message"]);
        fake(world).borrow_mut().reason = reason.clone();
        expect!(!reason.is_empty(), "{}", describe(world));
        Ok(())
    });

    // The track while an update step runs: each of the three in turn.
    steps.step(
        "the app is checking for, downloading or installing an update",
        |world, _, _| {
            ready(world)?;
            fake(world).borrow_mut().track_before = text(&view(world)["track"]);
            Ok(())
        },
    );
    steps.step("the user switches the update track", |world, _, _| {
        let attempt = |world: &mut World| -> Outcome {
            switch_track(world, "Nightly")?;
            for item in toasts(world) {
                if item["title"] == "Could not change update track" {
                    fake(world)
                        .borrow_mut()
                        .track_refusals
                        .push(text(&item["description"]));
                    world.dispatch("notification.dismiss", json!({"id": item["id"]}))?;
                }
            }
            Ok(())
        };
        backend(world).borrow_mut().hold_fetch = true;
        backend(world).borrow_mut().releases = vec![release("1.4.0", "")];
        check(world)?;
        wait_status(world, "checking")?;
        attempt(world)?;
        backend(world).borrow_mut().answer_fetches();
        world.sync()?;
        wait_status(world, "available")?;
        backend(world).borrow_mut().hold_download = true;
        download(world)?;
        wait_status(world, "downloading")?;
        attempt(world)?;
        backend(world).borrow_mut().complete_download();
        world.sync()?;
        wait_status(world, "downloaded")?;
        backend(world).borrow_mut().hold_install = true;
        install(world)?;
        let backend_rc = backend(world);
        world.wait_for("the install to start", move |_| {
            backend_rc.borrow().installing_held()
        })?;
        attempt(world)
    });
    steps.step(
        "the user is told the track cannot change while that update step is in progress",
        |world, _, _| {
            let wanted: Vec<String> = ["check", "download", "install"]
                .iter()
                .map(|step| {
                    format!("The update track cannot change while an update {step} is in progress.")
                })
                .collect();
            let refusals = fake(world).borrow().track_refusals.clone();
            expect!(
                refusals == wanted,
                "the user was told {}",
                refusals.join("|")
            );
            Ok(())
        },
    );
    steps.step("the update track stays as it was", |world, _, _| {
        let before = fake(world).borrow().track_before.clone();
        expect!(
            view(world)["track"] == before.as_str()
                && Settings::of(world.engine())
                    .device_value("desktopUpdate")
                    .is_none(),
            "{}",
            describe(world)
        );
        Ok(())
    });

    steps.step(
        "the app is on the Nightly track at a build newer than the latest stable release",
        |world, _, _| {
            given(world, |environment| {
                environment.app_version = "1.5.0-nightly.20260901.1".into();
            })?;
            backend(world).borrow_mut().releases = vec![
                release("1.5.0-nightly.20260901.1", ""),
                release("1.4.0", ""),
            ];
            check(world)?;
            wait_status(world, "up-to-date")
        },
    );
    steps.step(
        "the app offers the latest stable release even though it is older",
        |world, _, _| {
            wait_status(world, "available")?;
            expect!(
                shown_state(world)["availableVersion"] == "1.4.0",
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step(
        "installing it is allowed to go back in version",
        |world, _, _| {
            download(world)?;
            wait_status(world, "downloaded")?;
            install(world)?;
            let fake_rc = fake(world);
            world.wait_for("the app to quit for the older version", move |_| {
                fake_rc.borrow().quit.get()
            })?;
            let installed = backend(world).borrow().installed.clone();
            expect!(installed == "1.4.0", "{installed}");
            Ok(())
        },
    );

    steps.step(
        "the app stopped its MC to install an update",
        |world, _, _| {
            downloaded(world, "1.4.0")?;
            backend(world).borrow_mut().hold_install = true;
            install(world)?;
            let backend_rc = backend(world);
            let fake_rc = fake(world);
            world.wait_for("the install to stop the MC", move |_| {
                backend_rc.borrow().installing_held() && fake_rc.borrow().mc_stops.get() == 1
            })
        },
    );
    steps.step("the install fails", |world, _, _| {
        let error = "Could not replace /opt/hal-c2/HAL-C2.AppImage.".to_owned();
        backend(world).borrow_mut().install_error = Some(error.clone());
        fake(world).borrow_mut().reason = error;
        backend(world).borrow_mut().complete_install();
        world.sync()
    });
    steps.step("the MC is started again", |world, _, _| {
        let starts = fake(world).borrow().mc_starts.get();
        expect!(starts == 1, "the MC was started {starts} times");
        Ok(())
    });

    steps.step(
        "a later check (fails|finds nothing newer)",
        |world, c, _| {
            if c[0] == "fails" {
                backend(world).borrow_mut().fetch_error = Some("Network unreachable".into());
            } else {
                backend(world).borrow_mut().releases.clear();
            }
            let before = backend(world).borrow().fetches;
            check(world)?;
            let backend_rc = backend(world);
            world.wait_for_with(
                |w| backend_rc.borrow().fetches == before + 1 && view(w)["status"] != "checking",
                describe,
            )
        },
    );
    steps.step(
        "the update is still shown as downloaded and ready to install",
        |world, _, _| {
            expect!(
                view(world)["action"] == "install"
                    && shown_state(world)["downloadedVersion"] == "1.4.0"
                    && view(world)["label"]
                        == "Update v1.4.0 downloaded. Click to restart and install.",
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    steps.step("a check finds only a nightly release", |world, _, _| {
        backend(world).borrow_mut().releases = vec![release("1.5.0-nightly.20260901.1", "")];
        check(world)
    });
    steps.step("the app says it is up to date", |world, _, _| {
        wait_status(world, "up-to-date")
    });

    steps.step("an update is downloading", |world, _, _| {
        offer(world, "1.4.0")?;
        backend(world).borrow_mut().hold_download = true;
        download(world)?;
        wait_status(world, "downloading")
    });
    steps.step(
        "the timer for the next automatic check comes up",
        |world, _, _| {
            fake(world).borrow_mut().reason = backend(world).borrow().fetches.to_string();
            let clock = fake(world).borrow().clock.clone();
            clock.advance(world.engine(), 15_000 + 4 * 60_000);
            world.sync()
        },
    );
    steps.step("no check starts", |world, _, _| {
        let before: i32 = fake(world).borrow().reason.parse().unwrap_or(0);
        expect!(backend(world).borrow().fetches == before, "a check started");
        Ok(())
    });
    steps.step("the download goes on", |world, _, _| {
        expect!(
            backend(world).borrow().downloading_held(),
            "{}",
            describe(world)
        );
        backend(world).borrow_mut().progress(60);
        world.wait_for_with(|w| shown_state(w)["downloadPercent"] == json!(60), describe)
    });
    steps.step(
        "the download advances from (\\d+) to (\\d+) percent",
        |world, c, _| {
            let from: i64 = c[0].parse().unwrap_or(0);
            let to: i64 = c[1].parse().unwrap_or(0);
            backend(world).borrow_mut().progress(from);
            world.sync()?;
            fake(world).borrow_mut().reason = shown_state(world)["downloadPercent"].to_string();
            for percent in from + 1..=to {
                backend(world).borrow_mut().progress(percent);
            }
            world.sync()
        },
    );
    steps.step("the shown progress does not change", |world, _, _| {
        let shown = shown_state(world)["downloadPercent"].to_string();
        expect!(shown == fake(world).borrow().reason, "{}", describe(world));
        Ok(())
    });
    steps.step("the download reaches (\\d+) percent", |world, c, _| {
        backend(world)
            .borrow_mut()
            .progress(c[0].parse().unwrap_or(0));
        world.sync()
    });
    steps.step(
        "the shown progress becomes (\\d+) percent",
        |world, c, _| {
            let wanted: i64 = c[0].parse().unwrap_or(0);
            world.wait_for_with(
                |w| shown_state(w)["downloadPercent"] == json!(wanted),
                describe,
            )
        },
    );

    steps.step("the desktop app already found an update", |world, _, _| {
        offer(world, "1.4.0")
    });
    steps.step("its MC restarts and connects to the app", |world, _, _| {
        fake(world).borrow_mut().reason = backend(world).borrow().fetches.to_string();
        world.mc.calls.clear();
        world.mc.drop_connection();
        world.wait_for("the app to see its MC go", |w| !w.client_ready())?;
        world.wait_for("the MC to connect again", |w| w.client_ready())
    });
    steps.step(
        "the MC receives the current update state without another check",
        |world, _, _| {
            world.wait_for_with(
                |w| {
                    reports(w, "").iter().any(|report| {
                        report["state"]["status"] == "available"
                            && report["state"]["availableVersion"] == "1.4.0"
                    })
                },
                |_| "the MC to hear of the update".to_owned(),
            )?;
            let before: i32 = fake(world).borrow().reason.parse().unwrap_or(0);
            expect!(
                backend(world).borrow().fetches == before,
                "the app checked again"
            );
            Ok(())
        },
    );

    // The Intel build on Apple Silicon.
    steps.step(
        "the Intel build runs on an Apple Silicon Mac",
        |world, _, _| {
            given(world, |environment| {
                environment.platform = "macos".into();
                environment.app_image.clear();
                environment.host_arch = "arm64".into();
                environment.app_arch = "x64".into();
                environment.translated = true;
            })
        },
    );
    steps.step(
        "the user is warned to install the Apple Silicon build",
        |world, _, _| {
            world.wait_for_with(
                |w| at(&view(w), "warning.title") == &json!("Intel build on Apple Silicon"),
                describe,
            )?;
            expect!(
                text(at(&view(world), "warning.description")).contains("Apple Silicon build"),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );
    steps.step("an update is available to download", |world, _, _| {
        offer(world, "1.4.0")
    });
    steps.step("an update was downloaded", |world, _, _| {
        downloaded(world, "1.4.0")
    });
    steps.step("no update is available", |world, _, _| {
        check(world)?;
        wait_status(world, "up-to-date")
    });
    steps.step("the user reads the warning", |world, _, _| ready(world));
    steps.step(
        "it says (to download the update to switch to the native build|to restart to install the native build|the next app update will replace it with the native one)",
        |world, c, _| {
            let advice = if c[0].starts_with("to download") {
                "Download the available update to switch to the native Apple Silicon build."
            } else if c[0].starts_with("to restart") {
                "Restart to install the downloaded Apple Silicon build."
            } else {
                "The next app update will replace it with the native Apple Silicon build."
            };
            expect!(
                text(at(&view(world), "warning.description")).ends_with(advice),
                "{}",
                describe(world)
            );
            Ok(())
        },
    );

    // The downloaded notice.
    steps.step(
        &format!("the user is told {Q} and to restart the app from the update button"),
        |world, c, _| {
            toast(
                world,
                &c[0],
                "Restart the app from the update button to install it.",
            )?;
            Ok(())
        },
    );
    steps.step(
        &format!("the notice links to the release notes of {Q}"),
        |world, c, _| {
            let notice = toast(
                world,
                "Update downloaded",
                "Restart the app from the update button to install it.",
            )?;
            expect!(
                notice["actions"][0]["label"] == "Read more",
                "{}",
                show(&notice)
            );
            world.dispatch("notification.action", json!({"id": notice["id"]}))?;
            world.sync()?;
            let wanted = format!("https://github.com/hal-c2/hal-c2/releases/tag/v{}", c[0]);
            let opened = fake(world).borrow().opened.borrow().clone();
            expect!(
                opened == [wanted],
                "opened {}",
                opened.first().cloned().unwrap_or_default()
            );
            Ok(())
        },
    );
    steps.step(
        "the notice for the downloaded update links its release notes",
        |world, _, _| {
            downloaded(world, "1.4.0")?;
            toast(
                world,
                "Update downloaded",
                "Restart the app from the update button to install it.",
            )?;
            Ok(())
        },
    );
    steps.step(
        "the user chooses the link and the system cannot open it",
        |world, _, _| {
            fake(world).borrow().open_fails.set(true);
            let notice = toast(
                world,
                "Update downloaded",
                "Restart the app from the update button to install it.",
            )?;
            world.dispatch("notification.action", json!({"id": notice["id"]}))?;
            world.sync()
        },
    );

    // Updates a server asks for.
    steps.step(
        "the app last found no update some time ago",
        |world, _, _| {
            ready(world)?;
            check(world)?;
            wait_status(world, "up-to-date")?;
            let clock = fake(world).borrow().clock.clone();
            clock.advance(world.engine(), 10 * 60_000);
            world.sync()?;
            backend(world).borrow_mut().hold_fetch = true;
            fake(world).borrow_mut().reason = backend(world).borrow().fetches.to_string();
            Ok(())
        },
    );
    steps.step("a server asks the desktop app to update", |world, _, _| {
        control(world, "requestDesktopUpdate", "req-1")
    });
    steps.step("the app checks again before answering", |world, _, _| {
        let backend_rc = backend(world);
        world.wait_for("the app to check again", move |_| {
            backend_rc.borrow().fetching()
        })?;
        let before: i32 = fake(world).borrow().reason.parse().unwrap_or(0);
        expect!(
            backend(world).borrow().fetches == before + 1 && outcome(world, "req-1").is_none(),
            "the app answered before it checked"
        );
        backend(world).borrow_mut().answer_fetches();
        world.sync()
    });
    steps.step(
        "it answers that the app is up to date only after that check",
        |world, _, _| {
            let report = wait_outcome(world, "req-1")?;
            expect!(report["outcome"] == "up-to-date", "{}", show(&report));
            Ok(())
        },
    );
    steps.step(
        "a server asks the desktop app to update and the download fails three times",
        |world, _, _| {
            backend(world).borrow_mut().download_error = Some("Network unreachable".into());
            control(world, "requestDesktopUpdate", "req-1")
        },
    );
    steps.step(
        "the request fails with the reason the download gave",
        |world, _, _| {
            let report = wait_outcome(world, "req-1")?;
            let downloads = backend(world).borrow().downloads;
            expect!(
                report["outcome"] == "failed"
                    && report["reason"] == "Network unreachable"
                    && downloads == 3,
                "{} after {downloads} downloads",
                show(&report)
            );
            Ok(())
        },
    );
    steps.step(
        "automatic updates are disabled on this machine",
        |world, _, _| given(world, |environment| environment.unexplained = true),
    );
    steps.step(
        "the downloaded update is gone before it is ready",
        |world, _, _| {
            downloaded(world, "1.4.0")?;
            backend(world).borrow_mut().staged_versions.clear();
            Ok(())
        },
    );
    steps.step(&format!("the request fails with {Q}"), |world, c, _| {
        let report = wait_outcome(world, "req-1")?;
        expect!(
            report["outcome"] == "failed" && report["reason"] == c[0].as_str(),
            "{}",
            show(&report)
        );
        Ok(())
    });
    steps.step(
        "the desktop app prepared an update for a server's request",
        |world, _, _| prepare(world, "req-1"),
    );
    steps.step(
        "five minutes pass without the request being confirmed",
        |world, _, _| {
            let clock = fake(world).borrow().clock.clone();
            clock.advance(world.engine(), PREPARED_TTL_MS);
            world.sync()
        },
    );
    steps.step(&format!("confirming it fails with {Q}"), |world, c, _| {
        world.mc.calls.clear();
        control(world, "commitDesktopUpdate", "req-1")?;
        let report = wait_outcome(world, "req-1")?;
        expect!(
            report["outcome"] == "failed" && report["reason"] == c[0].as_str(),
            "{}",
            show(&report)
        );
        expect!(
            backend(world).borrow().installs == 0,
            "the update was installed"
        );
        Ok(())
    });
    steps.step("a new update request can start", |world, _, _| {
        prepare(world, "req-2")
    });
    steps.step(
        "a server's update is installing and its MC stopped for it",
        |world, _, _| {
            prepare(world, "req-1")?;
            backend(world).borrow_mut().hold_install = true;
            control(world, "commitDesktopUpdate", "req-1")?;
            let backend_rc = backend(world);
            let fake_rc = fake(world);
            world.wait_for("the install to stop the MC", move |_| {
                backend_rc.borrow().installing_held() && fake_rc.borrow().mc_stops.get() == 1
            })
        },
    );
    steps.step(
        "the install fails and the connection comes back",
        |world, _, _| {
            world.mc.calls.clear();
            world.mc.drop_connection();
            let error = "Could not replace /opt/hal-c2/HAL-C2.AppImage.".to_owned();
            backend(world).borrow_mut().install_error = Some(error.clone());
            fake(world).borrow_mut().reason = error;
            backend(world).borrow_mut().complete_install();
            world.sync()
        },
    );
    steps.step(
        "the MC hears that request failed with the install's reason",
        |world, _, _| {
            let report = wait_outcome(world, "req-1")?;
            let reason = fake(world).borrow().reason.clone();
            expect!(
                report["outcome"] == "failed" && report["reason"] == reason.as_str(),
                "{}",
                show(&report)
            );
            Ok(())
        },
    );
    steps.step("that install fails", |world, _, _| {
        world.sync()?;
        let error = "Could not replace /opt/hal-c2/HAL-C2.AppImage.".to_owned();
        backend(world).borrow_mut().install_error = Some(error.clone());
        fake(world).borrow_mut().reason = error;
        backend(world).borrow_mut().complete_install();
        world.sync()
    });
    steps.step(
        "the update feed lists a release whose asset (.+)",
        |world, c, _| {
            let https = c[0].contains("https");
            let mut asset = json!({
                "name": "HAL-C2.AppImage",
                "browser_download_url": format!(
                    "{}://updates.example/HAL-C2.AppImage",
                    if https { "https" } else { "http" }
                ),
            });
            if !c[0].contains("no digest") {
                asset["digest"] = json!(format!("sha256:{}", "a".repeat(64)));
            }
            let feed = json!([{"tag_name": "v1.4.0", "assets": [asset]}]);
            fake(world).borrow_mut().parsed = logic::parse_feed(
                serde_json::to_vec(&feed).unwrap_or_default().as_slice(),
                "linux",
                "x64",
            );
            Ok(())
        },
    );
    steps.step("that release is (offered|not offered)", |world, c, _| {
        let parsed = fake(world).borrow().parsed.len();
        expect!(
            (parsed == 0) == (c[0] == "not offered"),
            "{parsed} releases"
        );
        Ok(())
    });
    steps.step(
        "a download whose bytes (match|do not match) the release's digest",
        |world, c, _| {
            fake(world).borrow_mut().downloaded_bytes = if c[0] == "match" {
                b"update".to_vec()
            } else {
                b"tampered".to_vec()
            };
            Ok(())
        },
    );
    steps.step("the app (accepts|refuses) it", |world, c, _| {
        let bytes = fake(world).borrow().downloaded_bytes.clone();
        let digest = logic::digest_hex(&sha2::Sha256::new_with_prefix(b"update"));
        expect!(
            logic::matches_digest(&bytes, &digest) == (c[0] == "accepts"),
            "{}",
            c[0]
        );
        Ok(())
    });
    steps.step(
        "the desktop app is already installing the downloaded version",
        |world, _, _| {
            prepare(world, "req-1")?;
            backend(world).borrow_mut().hold_install = true;
            install(world)?;
            let backend_rc = backend(world);
            world.wait_for("the install to start", move |_| {
                backend_rc.borrow().installing_held()
            })
        },
    );
    steps.step(
        "a server confirms its prepared update of that version",
        |world, _, _| {
            world.mc.calls.clear();
            control(world, "commitDesktopUpdate", "req-1")
        },
    );
    steps.step("no second install starts", |world, _, _| {
        world.sync()?;
        let installs = backend(world).borrow().installs;
        expect!(installs == 1, "{installs} installs started");
        Ok(())
    });
    steps.step("no failure is reported", |world, _, _| {
        world.sync()?;
        let heard = outcome(world, "req-1");
        expect!(
            heard.is_none(),
            "the MC heard {}",
            show(&heard.unwrap_or(Value::Null))
        );
        Ok(())
    });
}
