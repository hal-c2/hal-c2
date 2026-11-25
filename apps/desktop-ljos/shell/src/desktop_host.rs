//! The desktop host, in process: what desktop-qt runs as a Node
//! process (`apps/desktop-qt/host/main.ts`, its BackendProcess),
//! desktop-ljos runs on a thread of its own through
//! [`crate::mc_launcher`], so no Node process finds or starts the MC.
//! The surface is the host's: [`DesktopHost::start`] looks for the MC
//! (or pairs with the one `--attach` names), [`Event`] says where it
//! answers or why there is none, and [`DesktopHost::stop`] stops the
//! MC this shell started itself — a found one keeps running.
//!
//! What the launch learns arrives on its worker thread; `events` is
//! meant to post it to the shell's inbox, not to touch the engine.
//!
//! The lifecycle is one generation token under one lock
//! ([`Lifecycle`]): `start` and `stop` each take a new generation,
//! a worker carries the generation it was started with, and every
//! spawn, registration and publication checks that generation
//! under the same lock as the state change. A stale generation
//! spawns nothing, publishes nothing, and stops what it spawned.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use crate::mc_launcher::{self, Live, SpawnPermit, StartedMc};

/// How the host is run: the host arguments (`--attach`, `--dev`,
/// `--base-dir`, as main.cpp hands them on) and what a launch is
/// resolved against.
#[derive(Clone, Default)]
pub struct Options {
    pub arguments: Vec<String>,
    pub live: Option<Live>,
}

/// What the host told the shell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// The MC answers here, with this token.
    Ready { origin: String, token: String },
    /// The host could not give the shell an MC, or stopped giving it one.
    Failed(String),
}

type Events = Arc<dyn Fn(Event) + Send + Sync>;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum Phase {
    #[default]
    Idle,
    Starting,
    Ready,
    Stopping,
}

/// The host's whole lifecycle in one piece of state: a
/// monotonically increasing generation, the current phase, and
/// every MC this host started that is still alive — `pending`
/// (spawned, its worker has not handed it over yet, tracked by
/// process group) and `owned` (handed over, watched until it ends
/// or is stopped). Generic over the MC handle so the property
/// test can drive it with fake MCs; the host's is `StartedMc`.
struct Lifecycle<M = StartedMc> {
    generation: u64,
    phase: Phase,
    ready_generation: Option<u64>,
    watching_generation: Option<u64>,
    /// Spawns reserved and not yet registered or abandoned: a
    /// stop waits these out, so none lands after it has drained.
    inflight: usize,
    pending: BTreeSet<i32>,
    owned: Vec<M>,
}

impl<M> Default for Lifecycle<M> {
    fn default() -> Lifecycle<M> {
        Lifecycle {
            generation: 0,
            phase: Phase::Idle,
            ready_generation: None,
            watching_generation: None,
            inflight: 0,
            pending: BTreeSet::new(),
            owned: Vec::new(),
        }
    }
}

/// What handing a started MC over decided, under the lock.
enum HandOver<M> {
    /// This generation's own: publish for it and watch it. Any MC
    /// it replaced is the caller's to stop.
    Current(Vec<M>),
    /// A superseded generation's, adopted by the current one
    /// (which may be running on it as a found MC): watch it as
    /// the current generation's, publish nothing.
    Adopted(u64),
    /// Nobody's (stopped, or the current generation owns another):
    /// the caller's to stop.
    Stop(M),
}

impl<M> Lifecycle<M> {
    fn is_current(&self, generation: u64) -> bool {
        generation == self.generation && self.phase != Phase::Stopping
    }

    /// A new start: a new generation, everything before it stale.
    fn begin_start(&mut self) -> u64 {
        self.generation += 1;
        self.phase = Phase::Starting;
        self.ready_generation = None;
        self.watching_generation = None;
        self.generation
    }

    /// A stop: also a new generation, so every worker still in
    /// flight is stale from here. Hands back everything alive for
    /// the caller to stop and reap outside the lock.
    fn begin_stop(&mut self) -> (Vec<M>, Vec<i32>) {
        self.generation += 1;
        self.phase = Phase::Stopping;
        self.ready_generation = None;
        self.watching_generation = None;
        self.drain()
    }

    fn drain(&mut self) -> (Vec<M>, Vec<i32>) {
        (
            std::mem::take(&mut self.owned),
            std::mem::take(&mut self.pending).into_iter().collect(),
        )
    }

    fn finish_stop(&mut self, generation: u64) {
        if self.generation == generation && self.phase == Phase::Stopping {
            self.phase = Phase::Idle;
        }
    }

    /// Before a spawn: only the current generation, while it is
    /// starting, and the reservation is what a stop waits out.
    fn reserve_spawn(&mut self, generation: u64) -> bool {
        if generation == self.generation && self.phase == Phase::Starting {
            self.inflight += 1;
            true
        } else {
            false
        }
    }

    /// After a spawn: the group joins the alive set, or the
    /// generation went stale and the caller stops what it spawned.
    fn register_spawn(&mut self, generation: u64, pgid: i32) -> bool {
        self.inflight = self.inflight.saturating_sub(1);
        if self.is_current(generation) {
            self.pending.insert(pgid);
            true
        } else {
            false
        }
    }

    fn abandon_spawn(&mut self) {
        self.inflight = self.inflight.saturating_sub(1);
    }

    /// A worker's started MC, handed over: out of `pending`, then
    /// this generation's own, the current generation's by
    /// adoption, or nobody's.
    fn hand_over(&mut self, generation: u64, mc: M, pgid: i32) -> HandOver<M> {
        self.pending.remove(&pgid);
        if self.is_current(generation) && generation == self.generation {
            let replaced = std::mem::replace(&mut self.owned, vec![mc]);
            HandOver::Current(replaced)
        } else if self.phase != Phase::Stopping && self.owned.is_empty() {
            self.owned.push(mc);
            HandOver::Adopted(self.generation)
        } else {
            HandOver::Stop(mc)
        }
    }

    fn may_publish(&self, generation: u64) -> bool {
        self.is_current(generation)
    }

    /// Records a told `Ready`, only for a generation still
    /// current at the recording: a stale worker resuming after
    /// its callback must not overwrite the current one's marker.
    fn publish_ready(&mut self, generation: u64) -> bool {
        if self.is_current(generation) {
            self.ready_generation = Some(generation);
            self.phase = Phase::Ready;
            true
        } else {
            false
        }
    }

    /// An exit is reported only for the current generation, and
    /// only after its `Ready` was recorded (an adopted MC's watch
    /// starts before that `Ready`).
    fn watch_may_report(&self, generation: u64) -> bool {
        self.is_current(generation) && self.ready_generation == Some(generation)
    }

    fn note_exit(&mut self, pgid: i32) {
        self.pending.remove(&pgid);
    }
}

type Shared = Arc<(Mutex<Lifecycle>, Condvar)>;

/// The host, once [`DesktopHost::start`]ed.
pub struct DesktopHost {
    options: Options,
    events: Events,
    shared: Shared,
    /// The signal-handler slot for a started MC's group (see
    /// `mc_launcher::StartedMc::track_in`); the lifecycle's own
    /// alive set is in [`Lifecycle`].
    started_pgid: Arc<std::sync::atomic::AtomicI32>,
}

impl DesktopHost {
    pub fn new(options: Options, events: impl Fn(Event) + Send + Sync + 'static) -> DesktopHost {
        DesktopHost {
            options,
            events: Arc::new(events),
            shared: Arc::new((Mutex::new(Lifecycle::default()), Condvar::new())),
            started_pgid: Arc::default(),
        }
    }

    /// Finds or starts the MC. A launch that cannot give the shell
    /// one is a failure.
    pub fn start(&self) {
        // Before anything is spawned: from here on a termination
        // signal stops the MC this shell starts, as the Node
        // host's signal handlers did.
        mc_launcher::install_mc_lifeline();
        let generation = self.shared.0.lock().unwrap().begin_start();
        let permit = spawn_permit(generation, &self.shared);
        let options = self.options.clone();
        let shared = self.shared.clone();
        let events = self.events.clone();
        let started_pgid = self.started_pgid.clone();
        std::thread::spawn(move || {
            let result = launch(&options, &started_pgid, permit);
            match result {
                Ok((access, Some(started))) => {
                    let pgid = started.pgid();
                    let over = shared
                        .0
                        .lock()
                        .unwrap()
                        .hand_over(generation, started, pgid);
                    match over {
                        HandOver::Current(replaced) => {
                            for mut replaced in replaced {
                                replaced.stop(Duration::from_millis(1_500));
                            }
                            if publish(
                                &shared,
                                &events,
                                generation,
                                Event::Ready {
                                    origin: access.origin,
                                    token: access.token,
                                },
                            ) {
                                watch_mc(generation, shared.clone(), events.clone());
                            }
                        }
                        HandOver::Adopted(current) => {
                            watch_mc(current, shared.clone(), events.clone());
                        }
                        HandOver::Stop(mut started) => {
                            started.stop(Duration::from_millis(1_500));
                        }
                    }
                }
                Ok((access, None)) => {
                    publish(
                        &shared,
                        &events,
                        generation,
                        Event::Ready {
                            origin: access.origin,
                            token: access.token,
                        },
                    );
                }
                Err(message) => {
                    publish(&shared, &events, generation, Event::Failed(message));
                }
            }
        });
    }

    /// Stops every MC this shell started: SIGTERM to each process
    /// group, and a kill after the grace, each reaped before this
    /// returns. A found MC is left alone.
    pub fn stop(&self) {
        let (lock, drained) = (&self.shared.0, &self.shared.1);
        let (mut owned, mut pending, generation) = {
            let mut state = lock.lock().unwrap();
            let (owned, pending) = state.begin_stop();
            (owned, pending, state.generation)
        };
        // A spawn reserved before the stop either registers into
        // the (now stale) alive set or is stopped by its own
        // worker; wait those out, then drain whatever landed, so
        // nothing this host started outlives the stop.
        let deadline = Instant::now() + Duration::from_secs(2);
        {
            let mut state = lock.lock().unwrap();
            while state.inflight > 0 && Instant::now() < deadline {
                let (next, _) = drained
                    .wait_timeout(state, Duration::from_millis(50))
                    .unwrap();
                state = next;
            }
            let (more_owned, more_pending) = state.drain();
            owned.extend(more_owned);
            pending.extend(more_pending);
        }
        // Owned and pending are disjoint by construction (handing
        // over moves a group from one to the other), so no group
        // is signalled twice.
        for pgid in pending {
            mc_launcher::stop_group(pgid);
        }
        for mut mc in owned {
            mc.stop(Duration::from_secs(2));
        }
        lock.lock().unwrap().finish_stop(generation);
    }
}

/// Tells the shell, if this generation may still speak: the check
/// under the lock, the callback outside it, and a `Ready`
/// recorded under the lock again (and only if still current).
/// Whether the telling stands.
fn publish(shared: &Shared, events: &Events, generation: u64, event: Event) -> bool {
    if !shared.0.lock().unwrap().may_publish(generation) {
        return false;
    }
    let ready = matches!(event, Event::Ready { .. });
    events(event);
    if ready {
        shared.0.lock().unwrap().publish_ready(generation)
    } else {
        shared.0.lock().unwrap().may_publish(generation)
    }
}

/// The launcher's spawn permission for one generation, decided
/// under the lifecycle lock.
fn spawn_permit(generation: u64, shared: &Shared) -> SpawnPermit {
    let reserve_shared = shared.clone();
    let register_shared = shared.clone();
    let abandon_shared = shared.clone();
    SpawnPermit::new(
        generation,
        Arc::new(move |generation| reserve_shared.0.lock().unwrap().reserve_spawn(generation)),
        Arc::new(move |generation, pgid| {
            let registered = register_shared
                .0
                .lock()
                .unwrap()
                .register_spawn(generation, pgid);
            register_shared.1.notify_all();
            registered
        }),
        Arc::new(move |_| {
            abandon_shared.0.lock().unwrap().abandon_spawn();
            abandon_shared.1.notify_all();
        }),
    )
}

/// One launch: the arguments read, then found, started or attached.
fn launch(
    options: &Options,
    started_pgid: &Arc<std::sync::atomic::AtomicI32>,
    spawn_permit: SpawnPermit,
) -> Result<(mc_launcher::Access, Option<StartedMc>), String> {
    let args = mc_launcher::parse_host_args(&options.arguments)?;
    let mut live = options.live.clone().unwrap_or_else(|| {
        Live::process(
            bundled_mc(&executable_dir()),
            source_mc(),
            PathBuf::from("node"),
        )
    });
    live.started_pgid = started_pgid.clone();
    live.spawn_permit = spawn_permit;
    match &args.attach {
        Some(url) => mc_launcher::attach(url, args.base_dir.as_deref(), &live).map(|a| (a, None)),
        None => mc_launcher::standalone(&args, &live),
    }
}

/// Reports the started MC's end, unless the shell stopped it or
/// another MC holds its files (then the shell's MC is that one, with
/// the same files' token, and it carries on).
fn watch_mc(generation: u64, shared: Shared, events: Events) {
    {
        let mut state = shared.0.lock().unwrap();
        if state.watching_generation == Some(generation) {
            return;
        }
        state.watching_generation = Some(generation);
    }
    std::thread::spawn(move || {
        watch_loop(generation, &shared, &events);
        let mut state = shared.0.lock().unwrap();
        if state.watching_generation == Some(generation) {
            state.watching_generation = None;
        }
    });
}

fn watch_loop(generation: u64, shared: &Shared, events: &Events) {
    loop {
        std::thread::sleep(Duration::from_millis(200));
        let status = {
            let mut state = shared.0.lock().unwrap();
            if !state.is_current(generation) {
                return;
            }
            if !state.watch_may_report(generation) {
                continue;
            }
            let exited = state
                .owned
                .iter_mut()
                .find_map(|mc| mc.try_wait().map(|status| (mc.pgid(), status)));
            match exited {
                Some((pgid, status)) => {
                    state.owned.retain(|mc| mc.pgid() != pgid);
                    state.note_exit(pgid);
                    status
                }
                None => continue,
            }
        };
        let code = mc_launcher::exit_code(status);
        if code == mc_launcher::HOME_IN_USE {
            return;
        }
        // Still this generation's to report, checked under the
        // lock at the telling.
        if !shared.0.lock().unwrap().watch_may_report(generation) {
            return;
        }
        events(Event::Failed(format!(
            "The MC exited (code {code}, {}). Restart HAL-C2 to reconnect.",
            if status.code().is_some() {
                "normal exit"
            } else {
                "crashed"
            }
        )));
        return;
    }
}

fn executable_dir() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(Path::to_path_buf))
        .unwrap_or_default()
}

/// The installed app's files beside the executable
/// (`share/hal-c2`, or the bundle's `Resources/hal-c2` on macOS),
/// where the release stages the MC, Node and the licenses
/// (mise-tasks/release/desktop-ljos).
fn share_dir(executable_dir: &Path) -> PathBuf {
    if cfg!(target_os = "macos") {
        executable_dir.join("../Resources/hal-c2")
    } else {
        executable_dir.join("../share/hal-c2")
    }
}

/// The MC release bundled with the installed app.
pub fn bundled_mc(executable_dir: &Path) -> PathBuf {
    share_dir(executable_dir).join("hal-c2-mc/bin/hal_c2")
}

/// This checkout's MC, for a shell run from source.
pub fn source_mc() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../server-ex")
}

/// The Node the MC runs its JavaScript sidecars on: HAL_C2_NODE_BIN,
/// else the release's own beside the executable, else `node` from
/// PATH. The host itself needs no Node anymore.
pub fn default_node(executable_dir: &Path, release: bool, from_env: Option<&str>) -> PathBuf {
    if let Some(node) = from_env.filter(|n| !n.is_empty()) {
        return node.into();
    }
    if !release {
        return "node".into();
    }
    share_dir(executable_dir).join(if cfg!(windows) {
        "bin/node.exe"
    } else {
        "bin/node"
    })
}

/// The third-party license manifest: staged with the release
/// (scripts/stage-runtime.mjs), or `vp run licenses`'s in a checkout.
pub fn licenses_default(executable_dir: &Path, release: bool) -> PathBuf {
    if release {
        share_dir(executable_dir).join("licenses/third-party-licenses.json")
    } else {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../desktop-qt/licenses/third-party-licenses.json")
    }
}

/// The `--url` link as main.cpp hands it on,
/// `QUrl::fromUserInput(link).toString(QUrl::FullyEncoded)`: trimmed,
/// `http://` added when it names no scheme (a `host:port` is a host and a
/// port, not a scheme), and percent-encoded. A link that is no URL either
/// way is passed as it is, for the host to say so.
pub fn attach_link(link: &str) -> String {
    let link = link.trim();
    let prepended = url::Url::parse(&format!("http://{link}"));
    match url::Url::parse(link) {
        Ok(url) if prepended.as_ref().map_or(true, |p| p.port().is_none()) => url.into(),
        _ => prepended.map_or_else(|_| link.to_owned(), Into::into),
    }
}

/// main.cpp's host arguments: `--attach=<link>` for `--url`, `--dev` for
/// a development shell, `--base-dir=<root>` for `--home-dir`, then what
/// the command line passed that is not a folder.
pub fn arguments(
    attach: Option<&str>,
    dev: bool,
    root: Option<&Path>,
    passed: &[String],
) -> Vec<String> {
    let mut arguments = Vec::new();
    if let Some(link) = attach {
        arguments.push(format!("--attach={}", attach_link(link)));
    }
    if dev {
        arguments.push("--dev".into());
    }
    if let Some(root) = root {
        arguments.push(format!("--base-dir={}", root.display()));
    }
    arguments.extend(passed.iter().cloned());
    arguments
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn the_arguments_are_main_cpps() {
        assert_eq!(
            arguments(
                Some("http://h/pair#token=x"),
                true,
                Some(Path::new("/scratch/home")),
                &["--verbose".into()]
            ),
            [
                "--attach=http://h/pair#token=x",
                "--dev",
                "--base-dir=/scratch/home",
                "--verbose"
            ]
        );
        assert!(arguments(None, false, None, &[]).is_empty());
    }

    #[test]
    fn the_link_is_normalized_as_qurl_from_user_input() {
        assert_eq!(
            attach_link(" http://h:3773/pair#token=x "),
            "http://h:3773/pair#token=x"
        );
        assert_eq!(
            attach_link("192.168.1.4:3773/pair#token=x"),
            "http://192.168.1.4:3773/pair#token=x"
        );
        assert_eq!(attach_link("localhost:3773"), "http://localhost:3773/");
        assert_eq!(attach_link("h.ts.net/pair"), "http://h.ts.net/pair");
        assert_eq!(
            attach_link("http://h/a b#token=x y"),
            "http://h/a%20b#token=x%20y"
        );
    }

    #[test]
    fn node_comes_from_the_environment_first() {
        let dir = Path::new("/opt/hal-c2/bin");
        assert_eq!(
            default_node(dir, true, Some("/usr/bin/node22")),
            Path::new("/usr/bin/node22")
        );
        assert_eq!(default_node(dir, false, None), Path::new("node"));
        assert_eq!(default_node(dir, false, Some("")), Path::new("node"));
    }

    fn host_with(arguments: Vec<String>, live: Live) -> (DesktopHost, mpsc::Receiver<Event>) {
        let (sent, heard) = mpsc::channel();
        let host = DesktopHost::new(
            Options {
                arguments,
                live: Some(live),
            },
            move |event| {
                let _ = sent.send(event);
            },
        );
        (host, heard)
    }

    fn live_in(temp: &tempfile::TempDir, vars: Vec<(String, String)>) -> Live {
        Live {
            env: Arc::new(move |name| vars.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone())),
            user_home: temp.path().to_path_buf(),
            platform: crate::storage::Platform::Unix,
            bundled: temp.path().join("bundled/bin/hal_c2"),
            source: temp.path().join("server-ex"),
            node: "node".into(),
            timeout: Duration::from_secs(5),
            is_alive: Arc::new(mc_launcher::process_is_alive),
            started_pgid: Arc::new(std::sync::atomic::AtomicI32::new(0)),
            spawn_permit: mc_launcher::SpawnPermit::unconditional(),
        }
    }

    #[test]
    fn a_bad_host_argument_is_the_failure() {
        let temp = tempfile::tempdir().unwrap();
        let (host, heard) = host_with(vec!["--frobnicate".into()], live_in(&temp, vec![]));
        host.start();
        assert_eq!(
            heard.recv_timeout(Duration::from_secs(5)).unwrap(),
            Event::Failed("Unknown desktop host argument: --frobnicate".into())
        );
    }

    #[test]
    fn an_mc_already_running_on_the_home_is_the_ready_one() {
        // A runtime record for this (live) process, and its token, in
        // the home the launch is given: found, nothing started.
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let state = home.join("state/elixir");
        let data = home.join("data/elixir");
        std::fs::create_dir_all(&state).unwrap();
        std::fs::create_dir_all(&data).unwrap();
        std::fs::write(
            state.join("server-runtime.json"),
            format!(
                r#"{{"origin":"http://127.0.0.1:3793","pid":{}}}"#,
                std::process::id()
            ),
        )
        .unwrap();
        std::fs::write(data.join("access-token"), "found-token\n").unwrap();
        // Where a source MC would run from, without one being started.
        let source = temp.path().join("server-ex");
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(source.join("mix.exs"), "").unwrap();
        let (host, heard) = host_with(
            vec![format!("--base-dir={}", home.display())],
            live_in(&temp, vec![]),
        );
        host.start();
        assert_eq!(
            heard.recv_timeout(Duration::from_secs(10)).unwrap(),
            Event::Ready {
                origin: "http://127.0.0.1:3793".into(),
                token: "found-token".into()
            }
        );
        // Stopping leaves a found MC (this process) alone, and says
        // nothing more.
        host.stop();
        assert!(heard.recv_timeout(Duration::from_millis(300)).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn stopping_during_the_start_stops_the_mc_it_started() {
        use std::os::unix::fs::PermissionsExt;
        // A fake release that runs a sleep of its own and never
        // answers: the start is still waiting (a first compile, in
        // miniature) when the host is stopped.
        let temp = tempfile::tempdir().unwrap();
        let pid_file = temp.path().join("sleep-pid");
        let bin = temp.path().join("mc/bin");
        std::fs::create_dir_all(&bin).unwrap();
        let script = bin.join("hal_c2");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nsleep 60 & echo $! > {}; wait\n",
                pid_file.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let port = std::net::TcpListener::bind(("127.0.0.1", 0))
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let mut live = live_in(
            &temp,
            vec![
                (
                    "HAL_C2_MC_RELEASE".into(),
                    temp.path().join("mc").to_string_lossy().into_owned(),
                ),
                ("HAL_C2_MC_PORT".into(), port.to_string()),
            ],
        );
        live.timeout = Duration::from_secs(60);
        let (host, heard) = host_with(
            vec![format!("--base-dir={}", temp.path().join("home").display())],
            live,
        );
        host.start();
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        let sleeper: i64 = loop {
            if let Ok(pid) = std::fs::read_to_string(&pid_file)
                && let Ok(pid) = pid.trim().parse()
            {
                break pid;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the fake MC never ran"
            );
            std::thread::sleep(Duration::from_millis(20));
        };
        host.stop();
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while mc_launcher::process_is_alive(sleeper) && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            !mc_launcher::process_is_alive(sleeper),
            "the started MC outlived the stop"
        );
        // And the stop is not reported as a launch failure: the
        // worker whose MC the stop killed says nothing.
        assert!(heard.recv_timeout(Duration::from_millis(500)).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn a_superseded_runs_mc_is_adopted_not_stopped() {
        // The current run may have found this MC (through its
        // runtime record) and said Ready for it: the superseded
        // run hands it over instead of stopping it underneath.
        let fake = || {
            mc_launcher::start_mc(
                &mc_launcher::Launch {
                    command: "sh".into(),
                    args: vec!["-c".into(), "sleep 60".into()],
                    cwd: None,
                },
                4123,
                None,
                Path::new("node"),
            )
            .unwrap()
        };
        let mut state = Lifecycle::default();
        state.begin_start();
        let current = state.begin_start();
        let adopted = fake();
        let adopted_pgid = adopted.pgid();
        let adopted_origin = adopted.origin.clone();
        assert!(matches!(
            state.hand_over(1, adopted, adopted_pgid),
            HandOver::Adopted(generation) if generation == current
        ));
        assert_eq!(
            state.owned.first().map(|mc| mc.origin.as_str()),
            Some(adopted_origin.as_str())
        );
        // With an MC of its own in place, the next superseded one
        // is handed back (the caller stops it; here its Drop does).
        let spare = fake();
        let spare_pgid = spare.pgid();
        assert!(matches!(
            state.hand_over(1, spare, spare_pgid),
            HandOver::Stop(_)
        ));
        // The adopted one is the host's to stop, as its own.
        let mut mc = state.owned.pop().unwrap();
        mc.stop(Duration::from_secs(2));
        assert!(mc.try_wait().is_some());
    }

    #[cfg(unix)]
    #[test]
    fn a_watch_reports_no_exit_before_its_runs_ready() {
        // An adopted MC's watch runs before the current run has
        // published Ready: even with the MC already exited, it
        // says nothing until that Ready is recorded, then it
        // reports the exit after it.
        let mc = mc_launcher::start_mc(
            &mc_launcher::Launch {
                command: "sh".into(),
                args: vec!["-c".into(), "exit 3".into()],
                cwd: None,
            },
            4123,
            None,
            Path::new("node"),
        )
        .unwrap();
        let shared: Shared = Arc::new((Mutex::new(Lifecycle::default()), Condvar::new()));
        {
            let mut state = shared.0.lock().unwrap();
            for _ in 0..7 {
                state.begin_start();
            }
            state.owned.push(mc);
        }
        let (sent, heard) = mpsc::channel();
        let events: Events = Arc::new(move |event| {
            let _ = sent.send(event);
        });
        let watching = shared.clone();
        let watch_events = events.clone();
        std::thread::spawn(move || watch_loop(7, &watching, &watch_events));
        // Several polls of an exited MC, and still nothing.
        assert!(heard.recv_timeout(Duration::from_millis(600)).is_err());
        assert!(shared.0.lock().unwrap().publish_ready(7));
        assert_eq!(
            heard.recv_timeout(Duration::from_secs(5)).unwrap(),
            Event::Failed(
                "The MC exited (code 3, normal exit). Restart HAL-C2 to reconnect.".into()
            )
        );
    }

    // The three Majors of the generation-token redesign, as plain
    // regressions (the state machine below covers their class).

    #[test]
    fn a_stale_worker_cannot_spawn_after_a_restart() {
        // r4694150733: stop cancels run A, a new start enables run
        // B, and A must not spawn through B's start.
        let mut life: Lifecycle<i32> = Lifecycle::default();
        let a = life.begin_start();
        life.begin_stop();
        let b = life.begin_start();
        assert!(!life.reserve_spawn(a));
        assert!(life.reserve_spawn(b));
    }

    #[test]
    fn a_stale_ready_does_not_overwrite_the_current_marker() {
        // r4694150740: A published Ready and paused before
        // recording it; B records its own; A resuming must not
        // replace B's marker (B's watch would skip every exit).
        let mut life: Lifecycle<i32> = Lifecycle::default();
        let a = life.begin_start();
        life.begin_stop();
        let b = life.begin_start();
        assert!(life.publish_ready(b));
        assert!(!life.publish_ready(a));
        assert_eq!(life.ready_generation, Some(b));
        assert!(life.watch_may_report(b));
        assert!(!life.watch_may_report(a));
    }

    #[test]
    fn a_stop_drains_owned_and_pending_alike() {
        // r4694150748: with an adopted MC owned and a second MC
        // pending from a newer spawn, stop hands back both.
        let mut life: Lifecycle<i32> = Lifecycle::default();
        let a = life.begin_start();
        assert!(life.reserve_spawn(a));
        assert!(life.register_spawn(a, 111));
        let b = life.begin_start();
        assert!(matches!(life.hand_over(a, 111, 111), HandOver::Adopted(_)));
        assert!(life.reserve_spawn(b));
        assert!(life.register_spawn(b, 222));
        let (owned, pending) = life.begin_stop();
        assert_eq!(owned, [111]);
        assert_eq!(pending, [222]);
        assert!(life.owned.is_empty() && life.pending.is_empty());
    }

    mod prop {
        use super::*;
        use proptest::prelude::*;
        use std::collections::BTreeSet;

        #[derive(Clone, Debug)]
        enum Action {
            Start,
            Stop,
            ReserveStale,
            SpawnCurrent,
            HandOverStale(i32),
            PublishCurrent,
            PublishStale,
            ExitOldest,
        }

        fn action() -> impl Strategy<Value = Action> {
            prop_oneof![
                Just(Action::Start),
                Just(Action::Stop),
                Just(Action::ReserveStale),
                Just(Action::SpawnCurrent),
                (1000i32..1010).prop_map(Action::HandOverStale),
                Just(Action::PublishCurrent),
                Just(Action::PublishStale),
                Just(Action::ExitOldest),
            ]
        }

        proptest! {
            #![proptest_config(ProptestConfig::with_cases(64))]
            #[test]
            fn the_generation_token_keeps_every_interleaving_sound(
                actions in proptest::collection::vec(action(), 1..40)
            ) {
                // Fake MCs are their pgids; `alive` is every fake
                // spawned and not yet stopped or exited.
                let mut life: Lifecycle<i32> = Lifecycle::default();
                let mut alive: BTreeSet<i32> = BTreeSet::new();
                let mut next_pgid = 1i32;
                let mut published: Vec<u64> = Vec::new();
                for action in actions {
                    let current = life.generation;
                    match action {
                        Action::Start => { life.begin_start(); }
                        Action::Stop => {
                            let (owned, pending) = life.begin_stop();
                            for pgid in owned.iter().chain(&pending) {
                                alive.remove(pgid);
                            }
                            // After stop returns, nothing this host
                            // started is alive or unowned: every
                            // live fake was handed back above, and
                            // the lifecycle holds none.
                            prop_assert!(life.owned.is_empty());
                            prop_assert!(life.pending.is_empty());
                            prop_assert!(alive.iter().all(|pgid| !life.pending.contains(pgid)));
                            prop_assert_eq!(life.ready_generation, None);
                        }
                        Action::ReserveStale => {
                            if current > 0 {
                                prop_assert!(!life.reserve_spawn(current - 1));
                            }
                        }
                        Action::SpawnCurrent => {
                            if life.reserve_spawn(current) {
                                let pgid = next_pgid;
                                next_pgid += 1;
                                if life.register_spawn(current, pgid) {
                                    alive.insert(pgid);
                                    match life.hand_over(current, pgid, pgid) {
                                        HandOver::Current(replaced) => {
                                            for old in replaced { alive.remove(&old); }
                                        }
                                        HandOver::Adopted(_) => {}
                                        HandOver::Stop(mc) => { alive.remove(&mc); }
                                    }
                                }
                            }
                        }
                        Action::HandOverStale(pgid) => {
                            if current > 0 && !alive.contains(&pgid) {
                                alive.insert(pgid);
                                match life.hand_over(current - 1, pgid, pgid) {
                                    HandOver::Current(_) => {
                                        prop_assert!(false, "stale hand-over became current");
                                    }
                                    HandOver::Adopted(generation) => {
                                        prop_assert_eq!(generation, life.generation);
                                    }
                                    HandOver::Stop(mc) => { alive.remove(&mc); }
                                }
                            }
                        }
                        Action::PublishCurrent => {
                            if life.publish_ready(current) {
                                prop_assert_eq!(life.ready_generation, Some(current));
                                published.push(current);
                            }
                        }
                        Action::PublishStale => {
                            if current > 0 {
                                let before = life.ready_generation;
                                prop_assert!(!life.publish_ready(current - 1));
                                prop_assert_eq!(life.ready_generation, before);
                                prop_assert!(!life.may_publish(current - 1) || life.phase == Phase::Stopping);
                            }
                        }
                        Action::ExitOldest => {
                            if let Some(pgid) = alive.iter().next().copied() {
                                alive.remove(&pgid);
                                life.note_exit(pgid);
                                life.owned.retain(|mc| *mc != pgid);
                            }
                        }
                    }
                    // After every step: the Ready marker is only
                    // ever the current generation's, at most one MC
                    // is owned, and no stale generation may speak.
                    prop_assert!(life.ready_generation.is_none_or(|g| g == life.generation));
                    prop_assert!(life.owned.len() <= 1);
                    prop_assert!(published.iter().all(|g| *g <= life.generation));
                    if life.phase == Phase::Stopping {
                        prop_assert!(!life.watch_may_report(life.generation));
                    }
                }
            }
        }
    }
}
