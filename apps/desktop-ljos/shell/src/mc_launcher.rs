//! Finds or starts the desktop app's own Elixir MC, in process: what
//! desktop-qt's Node host (`apps/desktop-qt/host/main.ts` with
//! `elixirMc.ts`) does for the Qt shell, ported here so desktop-ljos
//! needs no Node process. [`crate::desktop_host`] runs this behind its
//! start/stop/event surface.
//!
//! The MC is a release `bin/hal_c2 start`, or `mix hal_c2.server` in a
//! checkout, started with `HAL_C2_BOOTSTRAP_STDIN=1` and one JSON
//! bootstrap line on stdin (port, host, `halC2Home`; read by
//! apps/server-ex/lib/hal_c2/desktop.ex). An MC already running on the
//! files this launch would use (the background service) is found
//! through its runtime record instead of starting a second one.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::{Component, Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex, Once};
use std::time::{Duration, Instant};

use hal_c2_mc::pairing;

use crate::storage::{self, Platform, Profile};

/// The MC's own default (apps/server-ex/config/config.exs); scanned
/// upward when taken.
const DEFAULT_MC_PORT: u16 = 3780;
const PORT_SCAN: u16 = 100;
const MC_HOST: &str = "127.0.0.1";
/// A checkout's first start may compile the MC.
pub const START_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// The exit status of an MC that found its files held by another MC
/// (`HalC2.HomeLock`, apps/server-ex/lib/hal_c2/application.ex).
pub const HOME_IN_USE: i32 = 73;

/// The host arguments, as the Node host takes them: `--base-dir` (the
/// MC's HAL-C2 home), `--attach` (a pairing link), `--dev`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HostArgs {
    pub base_dir: Option<PathBuf>,
    pub attach: Option<String>,
    pub dev: bool,
}

pub fn parse_host_args(args: &[String]) -> Result<HostArgs, String> {
    let mut parsed = HostArgs::default();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        index += 1;
        if arg == "--dev" {
            parsed.dev = true;
            continue;
        }
        let (name, inline) = match arg.split_once('=') {
            Some((name, value)) => (name, Some(value.to_owned())),
            None => (arg.as_str(), None),
        };
        if !matches!(name, "--base-dir" | "--attach") {
            return Err(format!("Unknown desktop host argument: {arg}"));
        }
        let value = match inline {
            Some(value) => Some(value),
            None => {
                let value = args.get(index).cloned();
                index += 1;
                value
            }
        }
        .filter(|v| !v.is_empty())
        .ok_or_else(|| format!("{name} needs a value."))?;
        match name {
            "--base-dir" => {
                let path = PathBuf::from(&value);
                parsed.base_dir = Some(if path.is_absolute() {
                    path
                } else {
                    std::env::current_dir().unwrap_or_default().join(path)
                });
            }
            _ => parsed.attach = Some(value),
        }
    }
    Ok(parsed)
}

/// Which MC to run, and how.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Launch {
    pub command: PathBuf,
    pub args: Vec<String>,
    /// The checkout's apps/server-ex for an MC run from source.
    pub cwd: Option<PathBuf>,
}

/// `HAL_C2_MC_RELEASE` (a release directory or its `bin/hal_c2`), else
/// the release bundled beside the executable, else the checkout's
/// apps/server-ex from source.
pub fn resolve_launch(
    env: &dyn Fn(&str) -> Option<String>,
    bundled: &Path,
    source: &Path,
    exists: &dyn Fn(&Path) -> bool,
) -> Result<Launch, String> {
    if let Some(configured) = env("HAL_C2_MC_RELEASE").filter(|v| !v.trim().is_empty()) {
        let release = PathBuf::from(configured.trim());
        let release = if release.is_absolute() {
            release
        } else {
            std::env::current_dir().unwrap_or_default().join(release)
        };
        let bin = release.join("bin").join("hal_c2");
        return Ok(Launch {
            command: if exists(&bin) { bin } else { release },
            args: vec!["start".into()],
            cwd: None,
        });
    }
    if exists(bundled) {
        return Ok(Launch {
            command: bundled.to_path_buf(),
            args: vec!["start".into()],
            cwd: None,
        });
    }
    if exists(&source.join("mix.exs")) {
        return Ok(Launch {
            command: "mix".into(),
            args: vec!["hal_c2.server".into()],
            cwd: Some(source.to_path_buf()),
        });
    }
    Err(
        "No MC to start: set HAL_C2_MC_RELEASE to an MC release, or run from a checkout with apps/server-ex."
            .into(),
    )
}

/// The MC's data and state directories for a launch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct McDirs {
    pub data: PathBuf,
    pub state: PathBuf,
}

/// Resolved the way `HalC2.Paths` resolves them for this launch: the
/// desktop's HAL-C2 home, `HAL_C2_MC_HOME`, else HAL-C2's XDG
/// directories, in the `hal-c2-dev` profile for an MC run from a
/// checkout (config/config.exs), which does not read `HAL_C2_HOME`
/// (config/runtime.exs). [`storage::resolve`] is that resolution.
pub fn mc_dirs(
    launch: &Launch,
    home: Option<&Path>,
    env: &dyn Fn(&str) -> Option<String>,
    user_home: &Path,
    platform: Platform,
) -> Result<McDirs, String> {
    if let Some(home) = home {
        // The MC ignores an old home as its home too
        // (`HalC2.Desktop.apply_bootstrap/1`).
        if storage::is_legacy_home(home, user_home, platform) {
            return Err(format!(
                "The HAL-C2 home ({}) must be a directory other than ~/.hal-c2 and ~/.t3.",
                home.display()
            ));
        }
        return Ok(McDirs {
            data: home.join("data").join("elixir"),
            state: home.join("state").join("elixir"),
        });
    }
    // Blank counts as set, as it does for the MC (config/runtime.exs).
    if let Some(mc_home) = env("HAL_C2_MC_HOME").filter(|v| !v.is_empty()) {
        // The MC ignores such a root and opens the installed app's
        // files instead (`HalC2.Paths.root?/4`), so the desktop app
        // does not start it there.
        let root = PathBuf::from(mc_home.trim());
        let in_old_home = [".hal-c2", ".t3"]
            .iter()
            .any(|name| is_within(&root, &user_home.join(name)));
        if !root.is_absolute() || in_old_home {
            return Err(format!(
                "HAL_C2_MC_HOME ({mc_home}) must be an absolute path outside ~/.hal-c2 and ~/.t3."
            ));
        }
        return Ok(McDirs {
            data: root.join("data"),
            state: root.join("state"),
        });
    }
    let profile = if launch.cwd.is_some() {
        Profile::Development
    } else {
        Profile::Installed
    };
    let paths = storage::resolve(None, env, user_home, platform, profile);
    Ok(McDirs {
        data: paths.data.join("elixir"),
        state: paths.state.join("elixir"),
    })
}

/// Whether `path` is `base` or under it, `.` and `..` resolved first.
fn is_within(path: &Path, base: &Path) -> bool {
    let clean = |p: &Path| {
        let mut out = PathBuf::new();
        for part in p.components() {
            match part {
                Component::CurDir => {}
                Component::ParentDir => {
                    out.pop();
                }
                other => out.push(other),
            }
        }
        out
    };
    clean(path).starts_with(clean(base))
}

/// The MC's own access token (`HalC2.Web.token/0`, written at boot),
/// which the shell's native client puts on its socket.
pub fn read_access_token(data_dir: &Path) -> Option<String> {
    let token = std::fs::read_to_string(data_dir.join("access-token")).ok()?;
    let token = token.trim();
    (!token.is_empty()).then(|| token.to_owned())
}

/// A running MC's address, from its runtime record
/// (`<state>/server-runtime.json`, HalC2.RuntimeRecord).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuntimeRecord {
    pub pid: i64,
    pub origin: String,
}

pub fn read_runtime_record(state_dir: &Path) -> Option<RuntimeRecord> {
    let text = std::fs::read_to_string(state_dir.join("server-runtime.json")).ok()?;
    let record: serde_json::Value = serde_json::from_str(&text).ok()?;
    Some(RuntimeRecord {
        pid: record.get("pid")?.as_i64()?,
        origin: record.get("origin")?.as_str()?.to_owned(),
    })
}

/// `kill(pid, 0)`: EPERM still means the process exists.
pub fn process_is_alive(pid: i64) -> bool {
    #[cfg(unix)]
    {
        let Ok(pid) = libc::pid_t::try_from(pid) else {
            return false;
        };
        // SAFETY: signal 0 only checks whether the pid may be signalled.
        if unsafe { libc::kill(pid, 0) } == 0 {
            return true;
        }
        std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        false
    }
}

/// Where the shell's own client connects, and its token.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Access {
    pub origin: String,
    pub token: String,
}

/// The MC already running on `dirs`' files, such as the background
/// service. Two MCs must not share those files, so the desktop uses
/// this one instead of starting its own, and fails when it cannot
/// read that MC's token. A record whose pid is gone is stale: no MC.
pub fn find_running(
    dirs: &McDirs,
    is_alive: &dyn Fn(i64) -> bool,
) -> Result<Option<Access>, String> {
    let Some(record) = read_runtime_record(&dirs.state).filter(|r| is_alive(r.pid)) else {
        return Ok(None);
    };
    let token = read_access_token(&dirs.data).ok_or_else(|| {
        format!(
            "An MC is already running on {} (pid {}), but its access token cannot be read.",
            dirs.data.display(),
            record.pid
        )
    })?;
    Ok(Some(Access {
        origin: record.origin,
        token,
    }))
}

/// `HAL_C2_MC_PORT` exactly, else the first free port from the MC's
/// default.
pub fn mc_port(
    env: &dyn Fn(&str) -> Option<String>,
    is_free: &dyn Fn(u16) -> bool,
) -> Result<u16, String> {
    if let Some(configured) = env("HAL_C2_MC_PORT").filter(|v| !v.trim().is_empty()) {
        let configured = configured.trim();
        let port: u16 = configured
            .parse()
            .ok()
            .filter(|p| *p > 0)
            .ok_or_else(|| format!("HAL_C2_MC_PORT is not a port: {configured}"))?;
        if !is_free(port) {
            return Err(format!(
                "Port {port} for the MC is in use by another program. Set HAL_C2_MC_PORT to a free port."
            ));
        }
        return Ok(port);
    }
    (DEFAULT_MC_PORT..DEFAULT_MC_PORT + PORT_SCAN)
        .find(|port| is_free(*port))
        .ok_or_else(|| {
            format!(
                "No free port for the MC in {}-{}. Set HAL_C2_MC_PORT.",
                DEFAULT_MC_PORT,
                DEFAULT_MC_PORT + PORT_SCAN - 1
            )
        })
}

/// Whether nothing listens on `port` on this machine's loopback.
pub fn port_is_free(port: u16) -> bool {
    TcpListener::bind((MC_HOST, port)).is_ok()
}

/// What a standalone launch does: use the MC already running on its
/// files, or start its own.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Plan {
    Found(Access),
    Start {
        launch: Launch,
        port: u16,
        dirs: McDirs,
    },
}

pub struct Resolution<'a> {
    pub bundled: &'a Path,
    pub source: &'a Path,
    pub exists: &'a dyn Fn(&Path) -> bool,
    pub is_alive: &'a dyn Fn(i64) -> bool,
    pub is_free: &'a dyn Fn(u16) -> bool,
}

/// Decides a standalone launch (no `--attach`), as the host's
/// `standalone` does before it spawns anything.
pub fn plan(
    args: &HostArgs,
    env: &dyn Fn(&str) -> Option<String>,
    user_home: &Path,
    platform: Platform,
    resolution: &Resolution<'_>,
) -> Result<Plan, String> {
    let launch = resolve_launch(
        env,
        resolution.bundled,
        resolution.source,
        resolution.exists,
    )?;
    // Only an MC run from source has a development profile: a release
    // would open the installed app's files, whatever HAL_C2_HOME or
    // HAL_C2_MC_HOME say.
    if args.dev && args.base_dir.is_none() && launch.cwd.is_none() {
        return Err(
            "A development shell (--dev) does not start an MC release on the installed app's files. Give it a home of its own with --home-dir <dir>."
                .into(),
        );
    }
    let dirs = mc_dirs(&launch, args.base_dir.as_deref(), env, user_home, platform)?;
    if let Some(found) = find_running(&dirs, resolution.is_alive)? {
        return Ok(Plan::Found(found));
    }
    Ok(Plan::Start {
        port: mc_port(env, resolution.is_free)?,
        launch,
        dirs,
    })
}

/// The MC origin and token of a pairing link such as `mix hal_c2.pair`
/// prints, token in the fragment or the query. Nothing for anything
/// that is not an http(s) URL.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairingLink {
    pub origin: String,
    pub token: Option<String>,
}

pub fn read_pairing_link(link: &str) -> Option<PairingLink> {
    let url = url::Url::parse(link).ok()?;
    if !matches!(url.scheme(), "http" | "https") {
        return None;
    }
    let token = |part: Option<&str>| {
        url::form_urlencoded::parse(part.unwrap_or_default().as_bytes())
            .find(|(name, _)| name == "token")
            .map(|(_, value)| value.trim().to_owned())
            .filter(|t| !t.is_empty())
    };
    Some(PairingLink {
        origin: url.origin().ascii_serialization(),
        token: token(url.fragment()).or_else(|| token(url.query())),
    })
}

/// The access token of the MC at `origin` when it runs on this
/// machine: the first MC directory whose runtime record names that
/// origin and a live pid. Looks where apps/tui/src/mcDiscovery.ts
/// looks: `HAL_C2_MC_HOME`, the desktop's HAL-C2 home, then the
/// `hal-c2-dev` and release XDG directories. Only reads.
pub fn find_local_token(
    origin: &str,
    home: Option<&Path>,
    env: &dyn Fn(&str) -> Option<String>,
    user_home: &Path,
    platform: Platform,
    is_alive: &dyn Fn(i64) -> bool,
) -> Option<String> {
    let mut candidates: Vec<McDirs> = Vec::new();
    if let Some(mc_home) = env("HAL_C2_MC_HOME").filter(|v| !v.trim().is_empty()) {
        let root = PathBuf::from(mc_home.trim());
        candidates.push(McDirs {
            data: root.join("data"),
            state: root.join("state"),
        });
    }
    if let Some(home) = home {
        candidates.push(McDirs {
            data: home.join("data").join("elixir"),
            state: home.join("state").join("elixir"),
        });
    }
    // HAL_C2_HOME is the desktop's own home, already a candidate above.
    let without_home = |name: &str| {
        if name == "HAL_C2_HOME" {
            None
        } else {
            env(name)
        }
    };
    for profile in [Profile::Development, Profile::Installed] {
        let paths = storage::resolve(None, &without_home, user_home, platform, profile);
        candidates.push(McDirs {
            data: paths.data.join("elixir"),
            state: paths.state.join("elixir"),
        });
    }
    let wanted = url::Url::parse(origin).ok()?;
    candidates.iter().find_map(|dirs| {
        let record = read_runtime_record(&dirs.state)?;
        let same = url::Url::parse(&record.origin).is_ok_and(|o| o.origin() == wanted.origin());
        (same && is_alive(record.pid)).then(|| read_access_token(&dirs.data))?
    })
}

/// The descriptor probes' agent: the native MC client's own TLS
/// policy (rustls with the platform verifier, as `hal_c2_mc`'s
/// HTTP side builds it), so an HTTPS MC a private CA in the
/// platform trust store serves passes this preflight exactly as it
/// passes the pairing exchange behind it. `direct` drops the
/// environment's proxy, which ureq otherwise reads by default.
fn descriptor_agent(timeout: Duration, direct: bool) -> ureq::Agent {
    use ureq::tls::{RootCerts, TlsConfig, TlsProvider};
    let mut builder = ureq::Agent::config_builder()
        .timeout_global(Some(timeout))
        .http_status_as_error(false)
        .tls_config(
            TlsConfig::builder()
                .provider(TlsProvider::Rustls)
                .root_certs(RootCerts::PlatformVerifier)
                .build(),
        );
    if direct {
        builder = builder.proxy(None);
    }
    builder.build().new_agent()
}

/// A protocol-3 MC's descriptor at `origin`, nothing for anything
/// else that answers; an error only when nothing answered at all.
pub fn fetch_descriptor(origin: &str, timeout: Duration) -> Result<Option<()>, String> {
    fetch_descriptor_with(origin, timeout, false)
}

/// [`fetch_descriptor`] for the MC this shell spawned on loopback:
/// direct, so an inherited proxy that refuses loopback cannot make
/// a healthy MC look dead until the start deadline stops it.
fn fetch_spawned_descriptor(origin: &str, timeout: Duration) -> Result<Option<()>, String> {
    fetch_descriptor_with(origin, timeout, true)
}

fn fetch_descriptor_with(
    origin: &str,
    timeout: Duration,
    direct: bool,
) -> Result<Option<()>, String> {
    let agent = descriptor_agent(timeout, direct);
    let mut response = agent
        .get(format!("{origin}/.well-known/hal-c2/environment"))
        .call()
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Ok(None);
    }
    let mut body = Vec::new();
    let _ = response.body_mut().as_reader().read_to_end(&mut body);
    let descriptor: serde_json::Value = serde_json::from_slice(&body).unwrap_or_default();
    let named = descriptor
        .get("environmentId")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|id| !id.is_empty());
    let protocol = descriptor
        .get("orchestrationProtocolVersion")
        .and_then(serde_json::Value::as_f64);
    Ok((named && protocol.is_some_and(|p| p >= 3.0)).then_some(()))
}

/// An MC this process started: its child, in its own process group on
/// Unix so stopping reaches the BEAM behind mix or the release script.
pub struct StartedMc {
    pub origin: String,
    child: Child,
    /// The write end of the MC's bootstrap stdin, held open for
    /// as long as the MC is this shell's: every death of the
    /// shell process, a native crash included, closes it, and
    /// the MC stops itself on that EOF (its `stdinLifeline`).
    stdin: Option<ChildStdin>,
    tail: Arc<Mutex<String>>,
    stopped: bool,
    /// A caller's own slot for this MC's process group (a
    /// [`Live`]'s), beside the process-wide one the signal handler
    /// reads: a host stopping a start still in flight stops its
    /// own MC by this slot, never another host's.
    tracked: Option<Arc<AtomicI32>>,
}

impl StartedMc {
    /// The last lines the MC wrote, for error messages.
    pub fn output(&self) -> String {
        self.tail.lock().unwrap().trim().to_owned()
    }

    /// Records this MC's process group in `slot` until it exits or
    /// is stopped, so its owner can stop it before it is handed
    /// over (see [`stop_tracked_mc`]).
    pub fn track_in(&mut self, slot: &Arc<AtomicI32>) {
        slot.store(self.child.id() as i32, Ordering::SeqCst);
        self.tracked = Some(slot.clone());
    }

    fn clear_started(&self) {
        clear_started_group(self.child.id());
        if let Some(slot) = &self.tracked {
            let _ = slot.compare_exchange(
                self.child.id() as i32,
                0,
                Ordering::SeqCst,
                Ordering::SeqCst,
            );
        }
    }

    pub fn try_wait(&mut self) -> Option<ExitStatus> {
        let status = self.child.try_wait().ok().flatten();
        if status.is_some() {
            self.clear_started();
        }
        status
    }

    pub fn wait(&mut self) -> Option<ExitStatus> {
        let status = self.child.wait().ok();
        if status.is_some() {
            self.clear_started();
        }
        status
    }

    /// Whether anything of this MC's process group still exists
    /// (the child itself counts until it is reaped).
    fn group_alive(&self) -> bool {
        #[cfg(unix)]
        {
            libc::pid_t::try_from(self.child.id()).is_ok_and(group_exists)
        }
        #[cfg(not(unix))]
        {
            false
        }
    }

    /// SIGTERM to the MC's process group (mix, erl, and anything they
    /// spawned); after `grace` it is killed. The grace is the
    /// group's, not the wrapper's: the wrapper may exit on the
    /// SIGTERM while a descendant that ignores it keeps running, so
    /// cleanup follows the group to its end and only then clears
    /// the tracking. The child is polled directly, not through
    /// [`StartedMc::try_wait`], which would clear that tracking at
    /// the wrapper's exit.
    pub fn stop(&mut self, grace: Duration) {
        if self.stopped {
            return;
        }
        self.stopped = true;
        // Closing the bootstrap pipe lets the MC stop itself on
        // the EOF beside the group's SIGTERM.
        drop(self.stdin.take());
        signal_group(&self.child, false);
        let deadline = Instant::now() + grace;
        let mut exited = false;
        while Instant::now() < deadline {
            if !exited {
                exited = self.child.try_wait().is_ok_and(|s| s.is_some());
            }
            if exited && !self.group_alive() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        if self.group_alive() {
            signal_group(&self.child, true);
        }
        if !exited && self.child.try_wait().is_ok_and(|s| s.is_none()) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        self.clear_started();
    }
}

/// Whether a process group still exists: signal 0 reaches it, or
/// may not be signalled (EPERM) but is there.
#[cfg(unix)]
fn group_exists(pgid: libc::pid_t) -> bool {
    if pgid <= 0 {
        return false;
    }
    // SAFETY: signal 0 only checks whether the group may be signalled.
    let reached = unsafe { libc::kill(-pgid, 0) } == 0;
    reached || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// A started MC nobody stops — a panic unwinding past it, a launch
/// failing after the spawn, a host dropped on an early return — is
/// stopped here rather than left running with no owner. One already
/// stopped, or exited with its whole group, makes this a no-op
/// (see [`StartedMc::stop`]).
impl Drop for StartedMc {
    fn drop(&mut self) {
        self.stop(Duration::from_millis(1_500));
    }
}

fn signal_group(child: &Child, kill: bool) {
    #[cfg(unix)]
    if let Ok(pid) = libc::pid_t::try_from(child.id()) {
        signal_started_group(pid, kill);
    }
    #[cfg(not(unix))]
    let _ = (child, kill);
}

/// The process group of the MC this shell started (its pid, from
/// `process_group(0)`), or 0 for none: a found MC is never
/// registered, so the lifeline below never stops one. Registered at
/// spawn, before any waiting, so a quit while the start still waits
/// on a first compile reaches it too. The Node host's single `mc`
/// global, as an atomic a signal handler may read.
static STARTED_MC_PGID: AtomicI32 = AtomicI32::new(0);

fn register_started_group(pid: u32) {
    #[cfg(unix)]
    if let Ok(pid) = libc::pid_t::try_from(pid) {
        STARTED_MC_PGID.store(pid, Ordering::SeqCst);
    }
    #[cfg(not(unix))]
    let _ = pid;
}

fn clear_started_group(pid: u32) {
    #[cfg(unix)]
    if let Ok(pid) = libc::pid_t::try_from(pid) {
        let _ = STARTED_MC_PGID.compare_exchange(pid, 0, Ordering::SeqCst, Ordering::SeqCst);
    }
    #[cfg(not(unix))]
    let _ = pid;
}

#[cfg(unix)]
fn signal_started_group(pgid: libc::pid_t, kill: bool) {
    if pgid > 0 {
        // SAFETY: the started child's own process group.
        unsafe {
            libc::kill(-pgid, if kill { libc::SIGKILL } else { libc::SIGTERM });
        }
    }
}

/// Stops a started MC's whole process group: SIGTERM, the Node
/// host's 1.5 s grace, then SIGKILL. Only `kill` and `nanosleep`, so
/// a signal handler may run it; the direct child stays a zombie
/// until its owner reaps it, which only spends the grace.
#[cfg(unix)]
fn stop_started_group(pgid: libc::pid_t) {
    if pgid <= 0 {
        return;
    }
    signal_started_group(pgid, false);
    for _ in 0..150 {
        // SAFETY: signal 0 only checks whether the group exists.
        if unsafe { libc::kill(-pgid, 0) } != 0
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
        {
            return;
        }
        let pause = libc::timespec {
            tv_sec: 0,
            tv_nsec: 10_000_000,
        };
        // SAFETY: a plain 10 ms pause; rem is not resumed on EINTR.
        unsafe { libc::nanosleep(&pause, std::ptr::null_mut()) };
    }
    signal_started_group(pgid, true);
}

/// Stops the MC tracked in `slot` (see [`StartedMc::track_in`]), if
/// any: a host whose start is still in flight stops its own MC
/// this way on quit. An empty slot — a found MC, or one already
/// exited — stops nothing.
pub fn stop_tracked_mc(slot: &AtomicI32) {
    #[cfg(unix)]
    stop_started_group(slot.load(Ordering::SeqCst));
    #[cfg(not(unix))]
    let _ = slot;
}

#[cfg(unix)]
extern "C" fn on_termination_signal(signal: libc::c_int) {
    stop_started_group(STARTED_MC_PGID.load(Ordering::SeqCst));
    // Die as the signal meant, now the MC has had its own: the
    // raised signal stays pending until this handler returns, then
    // its default action runs.
    // SAFETY: restoring the default disposition for this signal.
    unsafe {
        libc::signal(signal, libc::SIG_DFL);
        libc::raise(signal);
    }
}

/// The Node host's termination lifeline, in process: SIGINT,
/// SIGTERM and SIGHUP stop the MC this shell started before the
/// shell dies of the signal. Installed once; a no-op where there
/// are no Unix signals.
///
/// There is deliberately no panic hook. The profiles in this
/// workspace do not set `panic`, so they use Rust's default
/// unwinding, and the shell catches and recovers from some
/// panics; a hook cannot tell those from a panic that will end
/// the process, so stopping the MC there would kill live agent
/// sessions over a recoverable failure. A panic that unwinds the
/// MC's owner drops [`StartedMc`] and stops it. A panic or native
/// crash that takes the whole process down without unwinding
/// closes the bootstrap stdin [`start_mc`] holds open, and the
/// MC's own stdin lifeline stops it there (see
/// `HalC2.Desktop` in apps/server-ex).
pub fn install_mc_lifeline() {
    #[cfg(unix)]
    {
        static INSTALLED: Once = Once::new();
        INSTALLED.call_once(|| {
            for signal in [libc::SIGINT, libc::SIGTERM, libc::SIGHUP] {
                // SAFETY: a zeroed sigaction whose handler is the
                // async-signal-safe stop above.
                unsafe {
                    let mut action: libc::sigaction = std::mem::zeroed();
                    action.sa_sigaction = on_termination_signal as *const () as usize;
                    libc::sigemptyset(&mut action.sa_mask);
                    libc::sigaction(signal, &action, std::ptr::null_mut());
                }
            }
        });
    }
}

/// Spawns the MC and hands it the bootstrap line; its output is
/// logged as `[mc]` and kept as a tail. `node` is what the MC runs
/// its JavaScript sidecars on (`HAL_C2_NODE_COMMAND`).
///
/// The bootstrap asks for the stdin lifeline (`stdinLifeline`)
/// and the returned [`StartedMc`] holds the pipe's write end
/// open: the shell process dying by any means closes it, and the
/// MC stops itself on the EOF. That is the portable half of the
/// lifeline the Node host got from its own stdin closing when
/// the Qt shell died — it needs no `PR_SET_PDEATHSIG` (Linux
/// only, and tied to the spawning thread, which the launch's
/// worker outlives only sometimes), and it covers macOS the
/// same way.
pub fn start_mc(
    launch: &Launch,
    port: u16,
    home: Option<&Path>,
    node: &Path,
) -> Result<StartedMc, String> {
    let mut command = Command::new(&launch.command);
    command
        .args(&launch.args)
        .env("HAL_C2_BOOTSTRAP_STDIN", "1")
        .env("HAL_C2_DESKTOP_HOST", "1")
        .env("HAL_C2_NODE_COMMAND", node)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = &launch.cwd {
        // An MC run from source is the development one, whatever
        // MIX_ENV the desktop app inherited.
        command.current_dir(cwd).env("MIX_ENV", "dev");
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command.spawn().map_err(|e| {
        format!(
            "Could not start {} {}: {e}",
            launch.command.display(),
            launch.args.join(" ")
        )
    })?;
    // The lifeline's charge from this moment, before the caller
    // waits on it: the Node host likewise kept its `mc` from the
    // spawn, not from the answer.
    register_started_group(child.id());
    let tail = Arc::new(Mutex::new(String::new()));
    let streams: Vec<Box<dyn Read + Send>> = [
        child
            .stdout
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
        child
            .stderr
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
    ]
    .into_iter()
    .flatten()
    .collect();
    for stream in streams {
        let tail = tail.clone();
        std::thread::spawn(move || drain_output(stream, tail));
    }
    let mut bootstrap = serde_json::json!({"port": port, "host": MC_HOST, "stdinLifeline": true});
    if let Some(home) = home {
        bootstrap["halC2Home"] = home.to_string_lossy().into_owned().into();
    }
    // Kept, not closed: its EOF is the lifeline the bootstrap
    // asked for, and closing it here would stop the MC at once.
    let mut stdin = child.stdin.take();
    if let Some(stdin) = stdin.as_mut() {
        let _ = writeln!(stdin, "{bootstrap}");
    }
    Ok(StartedMc {
        origin: format!("http://{MC_HOST}:{port}"),
        child,
        stdin,
        tail,
        stopped: false,
        tracked: None,
    })
}

/// Logs one of the MC's streams as `[mc]` lines and keeps its tail
/// for error messages, as the Node host forwarded the child's
/// chunks: read as bytes and decoded lossily, so output that is
/// not UTF-8 (a release's native diagnostic) garbles its line
/// instead of ending the drain and losing every line after it.
fn drain_output(stream: impl Read, tail: Arc<Mutex<String>>) {
    let mut reader = BufReader::new(stream);
    let mut bytes = Vec::new();
    loop {
        bytes.clear();
        match reader.read_until(b'\n', &mut bytes) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let line = String::from_utf8_lossy(&bytes);
        let line = line.strip_suffix('\n').unwrap_or(&line);
        let line = line.strip_suffix('\r').unwrap_or(line);
        eprintln!("[mc] {line}");
        let mut kept = tail.lock().unwrap();
        kept.push_str(line);
        kept.push('\n');
        if kept.len() > 4_000 {
            let cut = kept.len() - 4_000;
            let cut = (cut..=kept.len())
                .find(|i| kept.is_char_boundary(*i))
                .unwrap_or(kept.len());
            kept.drain(..cut);
        }
    }
}

/// How an exit reads: its code, or its signal's number as Qt reports.
pub fn exit_code(status: ExitStatus) -> i32 {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            return signal;
        }
    }
    status.code().unwrap_or(-1)
}

/// What answers an MC's descriptor, as [`fetch_descriptor`] does.
type FetchDescriptor = dyn Fn(&str, Duration) -> Result<Option<()>, String>;

/// Waits until the MC answers its descriptor. The exit status when it
/// ends first (the caller treats [`HOME_IN_USE`]); an error when it
/// does not answer in time.
fn wait_for_mc(
    mc: &mut StartedMc,
    timeout: Duration,
    fetch: &FetchDescriptor,
) -> Result<Result<(), ExitStatus>, String> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Some(status) = mc.try_wait() {
            return Ok(Err(status));
        }
        if fetch(&mc.origin, Duration::from_secs(1)).is_ok_and(|d| d.is_some()) {
            return Ok(Ok(()));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    Err(format!(
        "The MC did not answer at {} within {} s.",
        mc.origin,
        timeout.as_secs()
    ))
}

/// The rendezvous between a launch's spawn and its owner's stop.
/// The spawn and its registration in [`Live::started_pgid`] run
/// under this gate's lock, so [`SpawnGate::cancel`] returning
/// means either nothing will spawn, or what spawned is already
/// tracked where the stop can reach it. Without it, a stop that
/// lands after planning but before the spawn returns to a worker
/// that then starts an MC nobody is left to stop — the updater
/// replaces the MC on the strength of that stop, and the shell
/// may quit before the worker's later check cleans the child up.
#[derive(Default)]
pub struct SpawnGate {
    cancelled: Mutex<bool>,
}

impl SpawnGate {
    /// No spawn after this, and none in flight untracked: an
    /// in-flight spawn holds the gate until its MC is tracked.
    pub fn cancel(&self) {
        *self.cancelled.lock().unwrap() = true;
    }

    /// A fresh start may spawn again.
    pub fn reset(&self) {
        *self.cancelled.lock().unwrap() = false;
    }

    /// Runs `spawn` — the spawn itself and its tracking, as one
    /// step against [`SpawnGate::cancel`] — unless cancelled.
    fn run<T>(&self, spawn: impl FnOnce() -> Result<T, String>) -> Option<Result<T, String>> {
        let cancelled = self.cancelled.lock().unwrap();
        if *cancelled {
            return None;
        }
        let spawned = spawn();
        drop(cancelled);
        Some(spawned)
    }
}

/// How a launch reads its environment, as [`storage::resolve`] takes it.
pub type Env = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

/// Everything a launch is decided and run against: the process's own
/// environment by default ([`Live::process`]), a test's in tests.
#[derive(Clone)]
pub struct Live {
    pub env: Env,
    pub user_home: PathBuf,
    pub platform: Platform,
    pub bundled: PathBuf,
    pub source: PathBuf,
    pub node: PathBuf,
    pub timeout: Duration,
    /// Whether a runtime record's pid is a live process: the
    /// [`Resolution::is_alive`] every lookup here is decided with.
    pub is_alive: Arc<dyn Fn(i64) -> bool + Send + Sync>,
    /// The process group of an MC this launch started, from its
    /// spawn until it exits or is handed over: how a quit during
    /// the start stops it (see [`stop_tracked_mc`]).
    pub started_pgid: Arc<AtomicI32>,
    /// Whether this launch may still spawn, made one step with
    /// the tracking above against its owner's stop.
    pub spawn_gate: Arc<SpawnGate>,
}

impl Live {
    /// This process: its environment, home and platform.
    pub fn process(bundled: PathBuf, source: PathBuf, node: PathBuf) -> Live {
        Live {
            env: Arc::new(|name| std::env::var(name).ok()),
            user_home: storage::user_home(),
            platform: if cfg!(windows) {
                Platform::Windows
            } else {
                Platform::Unix
            },
            bundled,
            source,
            node,
            timeout: START_TIMEOUT,
            is_alive: Arc::new(process_is_alive),
            started_pgid: Arc::new(AtomicI32::new(0)),
            spawn_gate: Arc::default(),
        }
    }

    fn resolution(&self) -> Resolution<'_> {
        Resolution {
            bundled: &self.bundled,
            source: &self.source,
            exists: &|p: &Path| p.exists(),
            is_alive: self.is_alive.as_ref(),
            is_free: &port_is_free,
        }
    }
}

/// Finds or starts the MC of a standalone launch, as the host's
/// `standalone` does. The started MC, when there is one, is the
/// caller's to watch and stop; a found one is not its to stop.
pub fn standalone(args: &HostArgs, live: &Live) -> Result<(Access, Option<StartedMc>), String> {
    standalone_with_fetch(args, live, &fetch_spawned_descriptor)
}

/// The MC that holds `dirs`' files, once its runtime record names
/// it, as the host's `waitForRunningMc` waits: it may still be
/// booting, such as the background service starting at login beside
/// the app, when the MC this shell started gives up with
/// [`HOME_IN_USE`].
fn wait_for_running(
    dirs: &McDirs,
    timeout: Duration,
    is_alive: &dyn Fn(i64) -> bool,
) -> Result<Access, String> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(found) = find_running(dirs, is_alive)? {
            return Ok(found);
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "Another MC holds {}, but it did not start within {} s.",
                dirs.data.display(),
                timeout.as_secs()
            ));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn standalone_with_fetch(
    args: &HostArgs,
    live: &Live,
    fetch: &FetchDescriptor,
) -> Result<(Access, Option<StartedMc>), String> {
    let (launch, port, dirs) = match plan(
        args,
        live.env.as_ref(),
        &live.user_home,
        live.platform,
        &live.resolution(),
    )? {
        Plan::Found(found) => return Ok((found, None)),
        Plan::Start { launch, port, dirs } => (launch, port, dirs),
    };
    // The spawn and its tracking are one step against a stop:
    // cancelled first, nothing spawns; spawned first, the stop
    // finds it tracked (see [`SpawnGate`]). A found MC never
    // reaches this.
    let spawned = live.spawn_gate.run(|| {
        let mut started = start_mc(&launch, port, args.base_dir.as_deref(), &live.node)?;
        started.track_in(&live.started_pgid);
        Ok(started)
    });
    let mut started = match spawned {
        Some(started) => started?,
        None => return Err("The MC start was stopped before the MC spawned.".into()),
    };
    match wait_for_mc(&mut started, live.timeout, fetch) {
        Ok(Ok(())) => {}
        Ok(Err(status)) if exit_code(status) == HOME_IN_USE => {
            // Another MC took the files first, such as the background
            // service starting at login beside the app: the desktop
            // uses that one, as if it had found it above.
            return wait_for_running(&dirs, live.timeout, live.resolution().is_alive)
                .map(|found| (found, None));
        }
        Ok(Err(status)) => {
            let output = started.output();
            return Err(format!(
                "The MC failed to start (exit code {}) before it answered.{}",
                exit_code(status),
                if output.is_empty() {
                    String::new()
                } else {
                    format!("\n{output}")
                }
            ));
        }
        Err(e) => {
            started.stop(Duration::from_millis(1_500));
            return Err(e);
        }
    }
    let token = read_access_token(&dirs.data).ok_or_else(|| {
        "The MC started but wrote no access token for the desktop app.".to_owned()
    })?;
    Ok((
        Access {
            origin: started.origin.clone(),
            token,
        },
        Some(started),
    ))
}

fn not_an_mc(address: &str) -> String {
    format!(
        "{address} is not a HAL-C2 MC. Start the desktop app with an MC's pairing link to attach to it."
    )
}

/// Pairs the shell with the MC a pairing link names (`--attach`), as
/// the host's `attach` does: an MC on this machine lets the shell in
/// with its own access token; any other spends the link's token,
/// through the MC crate's pairing exchange.
pub fn attach(url: &str, home: Option<&Path>, live: &Live) -> Result<Access, String> {
    let link = read_pairing_link(url).ok_or_else(|| not_an_mc(url))?;
    // The pairing exchange's own route (and the Node host's
    // fetch was direct): an inherited proxy that refuses a
    // loopback, LAN or Tailscale MC must not fail the attach
    // before the exchange can run, while a remote HTTPS MC
    // keeps the proxy that may be its only route.
    let descriptor = fetch_descriptor_with(
        &link.origin,
        Duration::from_secs(2),
        pairing::direct_route(&link.origin),
    )
    .map_err(|e| format!("Cannot reach the MC at {}: {e}", link.origin))?;
    if descriptor.is_none() {
        return Err(not_an_mc(&link.origin));
    }
    if let Some(token) = find_local_token(
        &link.origin,
        home,
        live.env.as_ref(),
        &live.user_home,
        live.platform,
        live.is_alive.as_ref(),
    ) {
        return Ok(Access {
            origin: link.origin,
            token,
        });
    }
    let Some(token) = link.token else {
        return Err(format!(
            "The link to {} has no pairing token, and no MC on this machine records that origin.",
            link.origin
        ));
    };
    let result = pairing::exchange(
        &pairing::Link {
            origins: vec![link.origin.clone()],
            token,
        },
        &pairing::Client {
            label: "HAL-C2 desktop".into(),
            device_type: "desktop".into(),
            os: String::new(),
        },
    );
    match result.outcome {
        pairing::Outcome::Paired => Ok(Access {
            origin: link.origin,
            token: result.token,
        }),
        _ => Err(format!(
            "The pairing link for {} is invalid or expired.",
            link.origin
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env_of(vars: Vec<(&str, &str)>) -> impl Fn(&str) -> Option<String> {
        let vars: Vec<(String, String)> = vars
            .into_iter()
            .map(|(k, v)| (k.into(), v.into()))
            .collect();
        move |name| vars.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone())
    }

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_host_arguments_parse_as_the_node_host() {
        let parsed = parse_host_args(&args(&[
            "--attach=http://h/?token=t",
            "--dev",
            "--base-dir",
            "/scratch/home",
        ]))
        .unwrap();
        assert_eq!(parsed.attach.as_deref(), Some("http://h/?token=t"));
        assert!(parsed.dev);
        assert_eq!(parsed.base_dir, Some(PathBuf::from("/scratch/home")));
        assert_eq!(
            parse_host_args(&args(&["--frobnicate"])),
            Err("Unknown desktop host argument: --frobnicate".into())
        );
        assert_eq!(
            parse_host_args(&args(&["--attach"])),
            Err("--attach needs a value.".into())
        );
    }

    #[test]
    fn a_configured_release_wins_then_the_bundled_one_then_source() {
        let bundled = Path::new("/app/share/hal-c2/hal-c2-mc/bin/hal_c2");
        let source = Path::new("/checkout/apps/server-ex");
        let all = |_: &Path| true;
        let env = env_of(vec![("HAL_C2_MC_RELEASE", "/opt/mc")]);
        assert_eq!(
            resolve_launch(&env, bundled, source, &all).unwrap(),
            Launch {
                command: PathBuf::from("/opt/mc/bin/hal_c2"),
                args: vec!["start".into()],
                cwd: None
            }
        );
        // A configured path that is the binary itself is run as it is.
        let env = env_of(vec![("HAL_C2_MC_RELEASE", "/opt/mc/bin/hal_c2")]);
        let only_binary = |p: &Path| p == Path::new("/opt/mc/bin/hal_c2");
        assert_eq!(
            resolve_launch(&env, bundled, source, &only_binary)
                .unwrap()
                .command,
            PathBuf::from("/opt/mc/bin/hal_c2")
        );
        let none_set = env_of(vec![]);
        assert_eq!(
            resolve_launch(&none_set, bundled, source, &all)
                .unwrap()
                .command,
            bundled
        );
        let only_source = |p: &Path| p == Path::new("/checkout/apps/server-ex/mix.exs");
        assert_eq!(
            resolve_launch(&none_set, bundled, source, &only_source).unwrap(),
            Launch {
                command: "mix".into(),
                args: vec!["hal_c2.server".into()],
                cwd: Some(source.to_path_buf())
            }
        );
        assert!(resolve_launch(&none_set, bundled, source, &|_| false).is_err());
    }

    fn release() -> Launch {
        Launch {
            command: "/mc/bin/hal_c2".into(),
            args: vec!["start".into()],
            cwd: None,
        }
    }

    fn from_source() -> Launch {
        Launch {
            command: "mix".into(),
            args: vec!["hal_c2.server".into()],
            cwd: Some("/checkout/apps/server-ex".into()),
        }
    }

    #[test]
    fn an_mc_from_source_keeps_its_token_in_the_development_profile() {
        let env = env_of(vec![
            ("XDG_DATA_HOME", "/xdg/data"),
            ("XDG_STATE_HOME", "/xdg/state"),
        ]);
        let user = Path::new("/home/me");
        assert_eq!(
            mc_dirs(&from_source(), None, &env, user, Platform::Unix).unwrap(),
            McDirs {
                data: PathBuf::from("/xdg/data/hal-c2-dev/elixir"),
                state: PathBuf::from("/xdg/state/hal-c2-dev/elixir")
            }
        );
        assert_eq!(
            mc_dirs(&release(), None, &env, user, Platform::Unix)
                .unwrap()
                .data,
            PathBuf::from("/xdg/data/hal-c2/elixir")
        );
        // A source MC does not read HAL_C2_HOME; a release does.
        let ambient = env_of(vec![
            ("XDG_DATA_HOME", "/xdg/data"),
            ("HAL_C2_HOME", "/srv/hal-c2"),
        ]);
        assert_eq!(
            mc_dirs(&from_source(), None, &ambient, user, Platform::Unix)
                .unwrap()
                .data,
            PathBuf::from("/xdg/data/hal-c2-dev/elixir")
        );
        assert_eq!(
            mc_dirs(&release(), None, &ambient, user, Platform::Unix)
                .unwrap()
                .data,
            PathBuf::from("/srv/hal-c2/data/elixir")
        );
    }

    #[test]
    fn homes_the_mc_would_not_use_stop_the_start() {
        let user = Path::new("/home/me");
        for mc_home in [
            "scratch/mc",
            " ",
            "/home/me/.t3/elixir",
            "/home/me/.t3/..scratch",
        ] {
            let env = env_of(vec![("HAL_C2_MC_HOME", mc_home)]);
            let error = mc_dirs(&release(), None, &env, user, Platform::Unix).unwrap_err();
            assert!(error.contains("HAL_C2_MC_HOME"), "{mc_home:?}: {error}");
        }
        let env = env_of(vec![("HAL_C2_MC_HOME", "/srv/mc")]);
        assert_eq!(
            mc_dirs(&from_source(), None, &env, user, Platform::Unix).unwrap(),
            McDirs {
                data: PathBuf::from("/srv/mc/data"),
                state: PathBuf::from("/srv/mc/state")
            }
        );
        for name in [".t3", ".hal-c2"] {
            let home = user.join(name);
            let error = mc_dirs(
                &release(),
                Some(&home),
                &env_of(vec![]),
                user,
                Platform::Unix,
            )
            .unwrap_err();
            assert!(error.contains("HAL-C2 home"), "{error}");
        }
        assert_eq!(
            mc_dirs(
                &release(),
                Some(Path::new("/tmp/sandbox")),
                &env_of(vec![]),
                user,
                Platform::Unix
            )
            .unwrap()
            .data,
            PathBuf::from("/tmp/sandbox/data/elixir")
        );
    }

    fn write_record(dirs: &McDirs, origin: &str, pid: i64) {
        std::fs::create_dir_all(&dirs.state).unwrap();
        std::fs::create_dir_all(&dirs.data).unwrap();
        std::fs::write(
            dirs.state.join("server-runtime.json"),
            format!(r#"{{"origin":"{origin}","pid":{pid}}}"#),
        )
        .unwrap();
    }

    fn temp_dirs() -> (tempfile::TempDir, McDirs) {
        let temp = tempfile::tempdir().unwrap();
        let dirs = McDirs {
            data: temp.path().join("data"),
            state: temp.path().join("state"),
        };
        (temp, dirs)
    }

    #[test]
    fn a_running_mc_is_found_and_a_stale_record_is_not() {
        let (_temp, dirs) = temp_dirs();
        write_record(&dirs, "http://127.0.0.1:3790", 42);
        std::fs::write(dirs.data.join("access-token"), "service-token\n").unwrap();
        assert_eq!(
            find_running(&dirs, &|pid| pid == 42).unwrap(),
            Some(Access {
                origin: "http://127.0.0.1:3790".into(),
                token: "service-token".into()
            })
        );
        // The pid is gone: the record is stale, so a start is planned.
        assert_eq!(find_running(&dirs, &|_| false).unwrap(), None);
    }

    #[test]
    fn a_running_mc_without_a_readable_token_stops_the_start() {
        let (_temp, dirs) = temp_dirs();
        write_record(&dirs, "http://127.0.0.1:3790", 42);
        let error = find_running(&dirs, &|_| true).unwrap_err();
        assert!(error.contains("its access token cannot be read"), "{error}");
    }

    #[test]
    fn the_port_is_the_configured_one_or_the_next_free() {
        assert_eq!(mc_port(&env_of(vec![]), &|p| p > 3780).unwrap(), 3781);
        assert_eq!(
            mc_port(&env_of(vec![("HAL_C2_MC_PORT", "4123")]), &|_| true).unwrap(),
            4123
        );
        let taken = mc_port(&env_of(vec![("HAL_C2_MC_PORT", "4123")]), &|_| false).unwrap_err();
        assert!(
            taken.contains("Port 4123") && taken.contains("HAL_C2_MC_PORT"),
            "{taken}"
        );
        assert!(
            mc_port(&env_of(vec![("HAL_C2_MC_PORT", "soon")]), &|_| true)
                .unwrap_err()
                .contains("is not a port")
        );
        assert!(mc_port(&env_of(vec![]), &|_| false).is_err());
    }

    #[test]
    fn a_development_shell_does_not_start_a_release_without_a_home() {
        let temp = tempfile::tempdir().unwrap();
        let live = |env: Env| Live {
            env,
            user_home: temp.path().to_path_buf(),
            platform: Platform::Unix,
            bundled: temp.path().join("bundled"),
            source: temp.path().join("server-ex"),
            node: "node".into(),
            timeout: Duration::from_secs(5),
            is_alive: Arc::new(process_is_alive),
            started_pgid: Arc::new(AtomicI32::new(0)),
            spawn_gate: Arc::default(),
        };
        let release_dir = temp.path().join("mc");
        let env: Env = {
            let vars = [(
                "HAL_C2_MC_RELEASE".to_string(),
                release_dir.to_string_lossy().into_owned(),
            )];
            Arc::new(move |name| vars.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone()))
        };
        let live = live(env);
        let resolution = live.resolution();
        let dev = HostArgs {
            dev: true,
            ..HostArgs::default()
        };
        let error = plan(
            &dev,
            live.env.as_ref(),
            &live.user_home,
            live.platform,
            &resolution,
        )
        .unwrap_err();
        assert!(error.contains("--home-dir"), "{error}");
        // With a home of its own the same launch starts.
        let homed = HostArgs {
            dev: true,
            base_dir: Some(temp.path().join("home")),
            ..HostArgs::default()
        };
        assert!(matches!(
            plan(
                &homed,
                live.env.as_ref(),
                &live.user_home,
                live.platform,
                &resolution
            ),
            Ok(Plan::Start { .. })
        ));
    }

    #[test]
    fn find_beats_start_in_a_plan() {
        // plan() over a home whose files a live MC already holds:
        // found, with that MC's token, and nothing is started.
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let dirs = McDirs {
            data: home.join("data/elixir"),
            state: home.join("state/elixir"),
        };
        write_record(&dirs, "http://127.0.0.1:3791", 7);
        std::fs::write(dirs.data.join("access-token"), "found-token").unwrap();
        let source = temp.path().join("server-ex");
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(source.join("mix.exs"), "").unwrap();
        let resolution = Resolution {
            bundled: Path::new("/nonexistent/hal_c2"),
            source: &source,
            exists: &|p: &Path| p.exists(),
            is_alive: &|pid| pid == 7,
            is_free: &|_| true,
        };
        let planned = plan(
            &HostArgs {
                base_dir: Some(home),
                ..HostArgs::default()
            },
            &env_of(vec![]),
            temp.path(),
            Platform::Unix,
            &resolution,
        )
        .unwrap();
        assert_eq!(
            planned,
            Plan::Found(Access {
                origin: "http://127.0.0.1:3791".into(),
                token: "found-token".into()
            })
        );
    }

    #[test]
    fn a_pairing_link_names_its_origin_and_token() {
        assert_eq!(
            read_pairing_link("http://127.0.0.1:3780/?token=q"),
            Some(PairingLink {
                origin: "http://127.0.0.1:3780".into(),
                token: Some("q".into())
            })
        );
        // The fragment's token wins, and a link may carry none.
        assert_eq!(
            read_pairing_link("https://h/pair?token=q#token=f")
                .unwrap()
                .token
                .as_deref(),
            Some("f")
        );
        assert_eq!(read_pairing_link("https://h/page").unwrap().token, None);
        assert_eq!(read_pairing_link("ftp://h/?token=t"), None);
        assert_eq!(read_pairing_link("not a url"), None);
    }

    #[test]
    fn a_local_mcs_own_token_is_found_by_origin() {
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().join("home");
        let dirs = McDirs {
            data: home.join("data/elixir"),
            state: home.join("state/elixir"),
        };
        write_record(&dirs, "http://127.0.0.1:3792", 7);
        std::fs::write(dirs.data.join("access-token"), "local-token\n").unwrap();
        let alive = |pid: i64| pid == 7;
        assert_eq!(
            find_local_token(
                "http://127.0.0.1:3792",
                Some(&home),
                &env_of(vec![]),
                temp.path(),
                Platform::Unix,
                &alive
            )
            .as_deref(),
            Some("local-token")
        );
        // Another origin, or a dead pid, is not this machine's MC.
        assert_eq!(
            find_local_token(
                "http://127.0.0.1:4999",
                Some(&home),
                &env_of(vec![]),
                temp.path(),
                Platform::Unix,
                &alive
            ),
            None
        );
        assert_eq!(
            find_local_token(
                "http://127.0.0.1:3792",
                Some(&home),
                &env_of(vec![]),
                temp.path(),
                Platform::Unix,
                &|_| false
            ),
            None
        );
    }

    /// A fake release (`mc/bin/hal_c2`) that reads the bootstrap
    /// line, takes `$home` from it, then runs `body`; the `Live`
    /// that starts it under `temp`, its home, and its port.
    #[cfg(unix)]
    fn fake_release_live(
        temp: &tempfile::TempDir,
        body: &str,
        timeout: Duration,
        is_alive: Arc<dyn Fn(i64) -> bool + Send + Sync>,
    ) -> (Live, PathBuf, u16) {
        use std::os::unix::fs::PermissionsExt;
        let bin = temp.path().join("mc/bin");
        std::fs::create_dir_all(&bin).unwrap();
        let script = bin.join("hal_c2");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nread line\n\
                 home=$(printf %s \"$line\" | sed -n 's/.*\"halC2Home\": *\"\\([^\"]*\\)\".*/\\1/p')\n\
                 {body}\n"
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        let port = TcpListener::bind((MC_HOST, 0))
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let vars: Vec<(String, String)> = vec![
            (
                "HAL_C2_MC_RELEASE".into(),
                temp.path().join("mc").to_string_lossy().into_owned(),
            ),
            ("HAL_C2_MC_PORT".into(), port.to_string()),
        ];
        let live = Live {
            env: Arc::new(move |name| vars.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone())),
            user_home: temp.path().to_path_buf(),
            platform: Platform::Unix,
            bundled: temp.path().join("bundled"),
            source: temp.path().join("server-ex"),
            node: "node".into(),
            timeout,
            is_alive,
            started_pgid: Arc::new(AtomicI32::new(0)),
            spawn_gate: Arc::default(),
        };
        (live, temp.path().join("home"), port)
    }

    #[cfg(unix)]
    #[test]
    fn a_started_mcs_token_is_handed_to_the_shell() {
        let temp = tempfile::tempdir().unwrap();
        // Writes its access token under the home the bootstrap
        // names, then runs until stopped.
        let (live, home, port) = fake_release_live(
            &temp,
            "mkdir -p \"$home/data/elixir\"\n\
             printf 'started-token\\n' > \"$home/data/elixir/access-token\"\n\
             echo fake mc up\nsleep 60",
            Duration::from_secs(10),
            Arc::new(process_is_alive),
        );
        // The fake serves no HTTP; its descriptor is said for it,
        // once its complete token is published (the file existing
        // is not enough: the shell creates it before printf fills
        // it), as a real MC answers only after it boots.
        let token_dir = home.join("data/elixir");
        let (access, started) = standalone_with_fetch(
            &HostArgs {
                base_dir: Some(home),
                ..HostArgs::default()
            },
            &live,
            &move |_, _| Ok(read_access_token(&token_dir).map(|_| ())),
        )
        .unwrap();
        assert_eq!(access.origin, format!("http://127.0.0.1:{port}"));
        assert_eq!(access.token, "started-token");
        let mut started = started.expect("an MC was started");
        started.stop(Duration::from_secs(2));
        assert!(started.try_wait().is_some());
    }

    #[cfg(unix)]
    #[test]
    fn an_mc_refused_its_files_hands_over_to_the_holder() {
        // main.test.ts's FAKE_MC_HELD_BY: another MC took the files
        // while this one booted, so it writes the holder's record
        // and token, then exits 73. The holder's pid is only alive
        // through the injected `is_alive`, as `plan` is faked.
        let temp = tempfile::tempdir().unwrap();
        let (live, home, _port) = fake_release_live(
            &temp,
            "mkdir -p \"$home/data/elixir\" \"$home/state/elixir\"\n\
             printf 'holder-token\\n' > \"$home/data/elixir/access-token\"\n\
             printf '{\"origin\":\"http://127.0.0.1:3799\",\"pid\":4242}' \
               > \"$home/state/elixir/server-runtime.json\"\n\
             exit 73",
            Duration::from_secs(10),
            Arc::new(|pid| pid == 4242),
        );
        let (access, started) = standalone_with_fetch(
            &HostArgs {
                base_dir: Some(home),
                ..HostArgs::default()
            },
            &live,
            &|_, _| Ok(None),
        )
        .unwrap();
        assert_eq!(
            access,
            Access {
                origin: "http://127.0.0.1:3799".into(),
                token: "holder-token".into()
            }
        );
        // The holder is not this shell's to stop.
        assert!(started.is_none());
    }

    #[test]
    fn the_spawned_mcs_probe_bypasses_the_environments_proxy() {
        // ureq's default agent reads the proxy environment; the
        // direct agent the loopback probe (and the attach
        // preflight, on the same policy as its exchange) is
        // built with must not.
        assert!(
            descriptor_agent(Duration::from_secs(1), true)
                .config()
                .proxy()
                .is_none()
        );
    }

    #[cfg(unix)]
    #[test]
    fn an_mc_that_writes_no_token_is_stopped() {
        // The descriptor answers (said for the fake at once) but
        // no access token ever appears: the start fails and the
        // MC it spawned - here running its own sleep - is stopped
        // with it, not left holding the home.
        let temp = tempfile::tempdir().unwrap();
        let (live, home, _port) = fake_release_live(
            &temp,
            "mkdir -p \"$home\"\n\
             sleep 60 & echo $! > \"$home/sleep-pid\"\nwait",
            Duration::from_secs(10),
            Arc::new(process_is_alive),
        );
        // Said to answer once its sleep is running, so the pid
        // below is the MC the failed start must have stopped.
        let pid_file = home.join("sleep-pid");
        let said = pid_file.clone();
        let error = match standalone_with_fetch(
            &HostArgs {
                base_dir: Some(home.clone()),
                ..HostArgs::default()
            },
            &live,
            &move |_, _| Ok(said.exists().then_some(())),
        ) {
            Ok(_) => panic!("no token was written, so no access"),
            Err(error) => error,
        };
        assert!(error.contains("no access token"), "{error}");
        let deadline = Instant::now() + Duration::from_secs(5);
        let sleeper: i64 = loop {
            if let Ok(pid) = std::fs::read_to_string(&pid_file)
                && let Ok(pid) = pid.trim().parse()
            {
                break pid;
            }
            assert!(Instant::now() < deadline, "the fake MC never slept");
            std::thread::sleep(Duration::from_millis(20));
        };
        assert_gone(sleeper);
    }

    #[cfg(unix)]
    #[test]
    fn a_cancelled_start_spawns_nothing() {
        // The stop landed before the spawn: the gate the host's
        // stop cancels keeps the launch from starting an MC after
        // that stop has returned.
        let temp = tempfile::tempdir().unwrap();
        let (live, home, _port) = fake_release_live(
            &temp,
            "mkdir -p \"$home\"\nprintf ran > \"$home/ran\"\nsleep 60",
            Duration::from_secs(10),
            Arc::new(process_is_alive),
        );
        live.spawn_gate.cancel();
        let error = match standalone_with_fetch(
            &HostArgs {
                base_dir: Some(home.clone()),
                ..HostArgs::default()
            },
            &live,
            &|_, _| Ok(None),
        ) {
            Ok(_) => panic!("a cancelled start gives no access"),
            Err(error) => error,
        };
        assert!(error.contains("stopped before"), "{error}");
        assert!(!home.join("ran").exists(), "the fake MC ran anyway");
    }

    #[test]
    fn output_past_invalid_utf8_is_kept() {
        // Not UTF-8 in the middle: that line garbles, the drain
        // goes on, and the lines after it still reach the tail a
        // startup failure is reported with.
        let tail = Arc::new(Mutex::new(String::new()));
        drain_output(
            std::io::Cursor::new(b"before\nbad \xff\xfe bytes\nafter\n".to_vec()),
            tail.clone(),
        );
        let kept = tail.lock().unwrap().clone();
        assert!(
            kept.contains("before") && kept.contains("after"),
            "{kept:?}"
        );
        assert!(kept.contains('\u{fffd}'), "{kept:?}");
    }

    #[cfg(unix)]
    #[test]
    fn a_holder_that_never_records_itself_times_out() {
        let temp = tempfile::tempdir().unwrap();
        let (live, home, _port) =
            fake_release_live(&temp, "exit 73", Duration::from_secs(1), Arc::new(|_| true));
        let error = match standalone_with_fetch(
            &HostArgs {
                base_dir: Some(home.clone()),
                ..HostArgs::default()
            },
            &live,
            &|_, _| Ok(None),
        ) {
            Ok(_) => panic!("the holder never recorded itself, so no access"),
            Err(error) => error,
        };
        assert!(
            error.contains("Another MC holds")
                && error.contains(&home.join("data/elixir").display().to_string())
                && error.contains("did not start within 1 s"),
            "{error}"
        );
    }

    /// A started fake MC as `sh` running a `sleep` of its own in
    /// the same process group (mix and its BEAM, in miniature); the
    /// sleep's pid, once the script has written it.
    #[cfg(unix)]
    fn sleeping_mc(temp: &tempfile::TempDir) -> (StartedMc, i64) {
        let pid_file = temp.path().join("sleep-pid");
        let launch = Launch {
            command: "sh".into(),
            args: vec![
                "-c".into(),
                format!("sleep 60 & echo $! > {}; wait", pid_file.display()),
            ],
            cwd: None,
        };
        let mc = start_mc(&launch, 4123, None, Path::new("node")).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let sleeper = loop {
            if let Ok(pid) = std::fs::read_to_string(&pid_file)
                && let Ok(pid) = pid.trim().parse()
            {
                break pid;
            }
            assert!(Instant::now() < deadline, "the fake MC never slept");
            std::thread::sleep(Duration::from_millis(20));
        };
        (mc, sleeper)
    }

    /// Gone once reaped: an orphaned group member is init's to
    /// reap, so allow it a moment.
    #[cfg(unix)]
    fn assert_gone(pid: i64) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while process_is_alive(pid) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(!process_is_alive(pid), "pid {pid} is still running");
    }

    #[cfg(unix)]
    #[test]
    fn the_signal_lifelines_stop_takes_the_whole_group() {
        // `stop_started_group` is what the SIGINT/SIGTERM/SIGHUP
        // handler runs for the registered group; running it here
        // for this fake's group is the handler's work without
        // signalling the test process itself.
        let temp = tempfile::tempdir().unwrap();
        let (mut mc, sleeper) = sleeping_mc(&temp);
        assert!(process_is_alive(sleeper));
        stop_started_group(libc::pid_t::try_from(mc.child.id()).unwrap());
        assert!(mc.wait().is_some());
        assert_gone(sleeper);
    }

    #[cfg(unix)]
    #[test]
    fn dropping_a_started_mc_stops_it() {
        // The panic-unwind and early-return path: nobody calls stop.
        let temp = tempfile::tempdir().unwrap();
        let (mc, sleeper) = sleeping_mc(&temp);
        drop(mc);
        assert_gone(sleeper);
    }

    #[cfg(unix)]
    #[test]
    fn stopping_takes_a_descendant_that_ignores_term() {
        // The wrapper (the outer sh, the group leader) dies on
        // SIGTERM; its sleep ignores SIGTERM (an ignored signal
        // stays ignored across exec) and is in the same group.
        // The stop's grace is the group's: after it, the kill
        // still reaches the descendant the wrapper left behind.
        let temp = tempfile::tempdir().unwrap();
        let pid_file = temp.path().join("ignoring-pid");
        let launch = Launch {
            command: "sh".into(),
            args: vec![
                "-c".into(),
                format!(
                    "sh -c 'trap \"\" TERM; exec sleep 60' & echo $! > {}; wait",
                    pid_file.display()
                ),
            ],
            cwd: None,
        };
        let mut mc = start_mc(&launch, 4123, None, Path::new("node")).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let ignorer: i64 = loop {
            if let Ok(pid) = std::fs::read_to_string(&pid_file)
                && let Ok(pid) = pid.trim().parse()
            {
                break pid;
            }
            assert!(Instant::now() < deadline, "the fake MC never slept");
            std::thread::sleep(Duration::from_millis(20));
        };
        assert!(process_is_alive(ignorer));
        mc.stop(Duration::from_millis(300));
        assert!(mc.try_wait().is_some());
        assert_gone(ignorer);
    }

    #[cfg(unix)]
    #[test]
    fn a_started_mc_gets_the_bootstrap_line_and_the_development_environment() {
        let temp = tempfile::tempdir().unwrap();
        let record = temp.path().join("record");
        let launch = Launch {
            command: "sh".into(),
            args: vec![
                "-c".into(),
                format!(
                    "IFS= read -r line; printf %s \"$line\" > {}; printf 'MIX_ENV=%s NODE=%s BOOT=%s' \"$MIX_ENV\" \"$HAL_C2_NODE_COMMAND\" \"$HAL_C2_BOOTSTRAP_STDIN\"",
                    record.display()
                ),
            ],
            cwd: Some(temp.path().to_path_buf()),
        };
        let mut mc = start_mc(
            &launch,
            4123,
            Some(Path::new("/scratch/home")),
            Path::new("/usr/bin/node22"),
        )
        .unwrap();
        assert!(mc.wait().is_some_and(|s| s.success()));
        let bootstrap: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&record).unwrap()).unwrap();
        assert_eq!(bootstrap["port"], 4123);
        assert_eq!(bootstrap["host"], "127.0.0.1");
        assert_eq!(bootstrap["halC2Home"], "/scratch/home");
        // Asked for, and the line arrived while the pipe stays
        // open behind it: the script exited without waiting for
        // the EOF whose closing would stop a real MC.
        assert_eq!(bootstrap["stdinLifeline"], true);
        // Its output is kept until the reader threads land.
        let deadline = Instant::now() + Duration::from_secs(5);
        while mc.output().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(mc.output(), "MIX_ENV=dev NODE=/usr/bin/node22 BOOT=1");
    }
}
