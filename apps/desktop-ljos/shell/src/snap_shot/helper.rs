//! KDE Plasma and Hyprland capture through HAL-C2's own capture helper
//! (desktop-qt's HelperSnapShot and CaptureHelper): an executable this
//! build carries (native/kde-snap-shot, native/hyprland-snap-shot) that
//! setup copies into the user's data directory, where the desktop lets it
//! capture. KDE grants KWin's ScreenShot2 to an installed program named by
//! a desktop entry beside it; Hyprland asks for screen-sharing the first
//! time. The shortcut stays the portal's.
//!
//! Nothing is written until setup is asked to install or remove it, and
//! nothing that is a link, or a desktop entry this helper did not write, is
//! ever written over.

use std::cell::RefCell;
use std::fs;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::Duration;

use image::ImageFormat;
use serde_json::Value;

use super::gnome::{fit, set_mode, unique_dir};
use super::{
    Backend, Captured, Check, Event, Json, Mode, Platform, Session, Setup, SetupOption, Shortcut,
};

const DESKTOP_FILE: &str = "io.github.halc2.HalC2.KdeCapture.desktop";
const MARKER: &str = "X-HalC2-Capture-Helper=true";
const MAX_PNG_BYTES: u64 = 32 * 1024 * 1024;
const MAX_OUTPUT: usize = 128 * 1024;
/// How long the helper is waited for.
pub const TIMEOUT: Duration = Duration::from_secs(20);
const BUSY: &str = "Capture setup is still busy. Try again in a moment.";
const CONTINUE: &str = "Open Settings → SnapShots to continue setup.";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Kde,
    Hyprland,
}

impl Kind {
    pub fn executable_name(self) -> &'static str {
        match self {
            Kind::Kde => "hal-c2-kde-snap-shot",
            Kind::Hyprland => "hal-c2-hyprland-snap-shot",
        }
    }

    fn folder(self) -> &'static str {
        match self {
            Kind::Kde => "kde-capture",
            Kind::Hyprland => "hyprland-capture",
        }
    }

    pub fn install_action(self) -> &'static str {
        match self {
            Kind::Kde => "install-kde-helper",
            Kind::Hyprland => "install-hyprland-helper",
        }
    }

    pub fn remove_action(self) -> &'static str {
        match self {
            Kind::Kde => "remove-kde-helper",
            Kind::Hyprland => "remove-hyprland-helper",
        }
    }

    fn link_error(self) -> &'static str {
        match self {
            Kind::Kde => {
                "Capture helper files must be regular files. Remove the conflicting link before trying again."
            }
            Kind::Hyprland => "The capture helper must be a regular file, not a link.",
        }
    }

    fn missing(self) -> &'static str {
        match self {
            Kind::Kde => {
                "The capture helper is missing from this build. Update or reinstall HAL-C2."
            }
            Kind::Hyprland => {
                "The Hyprland capture helper is missing from this build. Update or reinstall HAL-C2."
            }
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct State {
    /// Empty until checked; else not-installed, update-required, error or ready.
    pub status: String,
    pub message: String,
    pub feedback_available: bool,
}

impl State {
    fn new(status: &str, message: &str) -> State {
        State {
            status: status.into(),
            message: message.into(),
            feedback_available: false,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Paths {
    /// The executable this build carries; empty or missing when it carries none.
    pub bundle: PathBuf,
    /// XDG_DATA_HOME's: the helper goes under <data_home>/hal-c2, KDE's
    /// desktop entry under <data_home>/applications.
    pub data_home: PathBuf,
}

pub type PathsFor = Rc<dyn Fn(Kind) -> Paths>;

#[derive(Default)]
struct Seams {
    paths: Option<PathsFor>,
    tools: Option<Vec<PathBuf>>,
    timeout: Option<Duration>,
}

thread_local! {
    static SEAMS: RefCell<Seams> = RefCell::new(Seams::default());
}

/// Tests stand in for both paths (`None` restores them).
pub fn set_paths(paths: Option<PathsFor>) {
    SEAMS.with(|seams| seams.borrow_mut().paths = paths);
}

/// Where KDE's service tools (kbuildsycoca6, systemd-run) are found; `None` is PATH.
pub fn set_tool_path(directories: Option<Vec<PathBuf>>) {
    SEAMS.with(|seams| seams.borrow_mut().tools = directories);
}

/// How long the helper is waited for; `None` is [`TIMEOUT`].
pub fn set_timeout(timeout: Option<Duration>) {
    SEAMS.with(|seams| seams.borrow_mut().timeout = timeout);
}

/// Where this build's helper and the user's data directory are: a package
/// carries the helper in share/hal-c2/<kde|hyprland>-capture beside bin/, a
/// development build where cargo builds it (mise run desktop:helpers).
pub fn default_paths(kind: Kind) -> Paths {
    if let Some(paths) = SEAMS.with(|seams| seams.borrow().paths.clone()) {
        return paths(kind);
    }
    let packaged = std::env::current_exe().ok().and_then(|exe| {
        let bin = exe.parent()?;
        Some(bin.join(format!(
            "../share/hal-c2/{}/{}",
            kind.folder(),
            kind.executable_name()
        )))
    });
    let bundle = packaged
        .filter(|bundle| bundle.exists())
        .unwrap_or_else(|| {
            let crate_name = match kind {
                Kind::Kde => "kde-snap-shot",
                Kind::Hyprland => "hyprland-snap-shot",
            };
            Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
                "../../../native/{crate_name}/target/release/{}",
                kind.executable_name()
            ))
        });
    Paths {
        bundle,
        data_home: super::gnome::data_home(),
    }
}

/// KDE and Hyprland's backend: the helper captures, `shortcuts` (the
/// portal) holds the shortcut.
pub fn create(platform: &Platform, shortcuts: Box<dyn Backend>) -> Box<dyn Backend> {
    let kind = if platform.desktop == "kde" {
        Kind::Kde
    } else {
        Kind::Hyprland
    };
    Box::new(HelperSnapShot::new(
        platform,
        shortcuts,
        CaptureHelper::new(kind, default_paths(kind)),
    ))
}

/// A file that is not there; a regular file's bytes; or why it cannot be read.
#[derive(Default)]
struct Read {
    exists: bool,
    bytes: Vec<u8>,
    error: String,
}

fn regular_file(path: &Path, link_error: &str) -> Read {
    let Ok(info) = fs::symlink_metadata(path) else {
        return Read::default();
    };
    let failed = |error: String| Read {
        exists: true,
        bytes: Vec::new(),
        error,
    };
    if info.file_type().is_symlink() || !info.is_file() {
        return failed(link_error.into());
    }
    match fs::read(path) {
        Ok(bytes) => Read {
            exists: true,
            bytes,
            error: String::new(),
        },
        Err(error) => failed(error.to_string()),
    }
}

/// A directory that is a link or not a directory at all.
fn foreign_directory(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|info| info.file_type().is_symlink() || !info.is_dir())
}

/// Exec values are unescaped as strings and then unquoted, so escaped in reverse.
pub fn exec_argument(value: &str) -> String {
    let quoted = value
        .replace('\\', "\\\\")
        .replace('`', "\\`")
        .replace('$', "\\$")
        .replace('"', "\\\"")
        .replace('%', "%%");
    format!("\"{quoted}\"")
        .replace('\\', "\\\\")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}

/// A name nobody else picks this instant, for a staged file.
fn unique_name() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |time| time.as_nanos());
    format!("{:x}-{:x}", nanos, std::process::id())
}

/// Writes `bytes` beside `target` and renames it over: the file is whole or absent.
fn write_executable(target: &Path, bytes: &[u8]) -> String {
    let directory = target.parent().unwrap_or(Path::new("."));
    let Some(staging) = unique_dir(directory, ".install-") else {
        return "Could not install the capture helper.".into();
    };
    let staged = staging.join(target.file_name().unwrap_or_default());
    let written = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&staged)
        .and_then(|mut file| std::io::Write::write_all(&mut file, bytes));
    let error = match written {
        Err(error) => error.to_string(),
        Ok(()) => {
            set_mode(&staged, 0o755);
            if fs::rename(&staged, target).is_ok() {
                String::new()
            } else {
                "Could not install the capture helper.".into()
            }
        }
    };
    let _ = fs::remove_dir_all(&staging);
    error
}

/// How a run ended: why it failed (the stderr it left), and what it printed.
struct Ran {
    ok: bool,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

fn find(program: &str, tools: Option<&[PathBuf]>) -> Option<PathBuf> {
    if program.contains('/') {
        return Some(PathBuf::from(program));
    }
    let path;
    let directories: Vec<PathBuf> = match tools {
        Some(tools) => tools.to_vec(),
        None => {
            path = std::env::var_os("PATH").unwrap_or_default();
            std::env::split_paths(&path).collect()
        }
    };
    directories
        .into_iter()
        .map(|dir| dir.join(program))
        .find(|candidate| executable(candidate))
}

#[cfg(unix)]
fn executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path).is_ok_and(|info| info.is_file() && info.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn executable(path: &Path) -> bool {
    path.is_file()
}

fn drain(stream: Option<impl std::io::Read + Send + 'static>) -> Option<JoinHandle<Vec<u8>>> {
    let mut stream = stream?;
    std::thread::Builder::new()
        .spawn(move || {
            let mut out = Vec::new();
            let _ = stream.read_to_end(&mut out);
            out.truncate(MAX_OUTPUT);
            out
        })
        .ok()
}

/// Runs `path` to its end, killing it after `timeout`.
fn run(path: &Path, arguments: &[&str], timeout: Duration) -> Ran {
    let failed = Ran {
        ok: false,
        stdout: Vec::new(),
        stderr: Vec::new(),
    };
    let Ok(mut child) = Command::new(path)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    else {
        return failed;
    };
    let stdout = drain(child.stdout.take());
    let stderr = drain(child.stderr.take());
    #[cfg(unix)]
    let pid = child.id();
    let (done, finished) = mpsc::channel();
    let waiter = std::thread::spawn(move || {
        let status = child.wait();
        let _ = done.send(());
        status
    });
    let timed_out = finished.recv_timeout(timeout).is_err();
    if timed_out {
        #[cfg(unix)]
        // SAFETY: the child is not reaped until `waiter` returns below, so
        // the pid is still this process's child.
        unsafe {
            libc::kill(pid as libc::pid_t, libc::SIGKILL);
        }
    }
    let status = waiter.join().ok().and_then(Result::ok);
    let collect = |handle: Option<JoinHandle<Vec<u8>>>| {
        handle.and_then(|h| h.join().ok()).unwrap_or_default()
    };
    let stdout = collect(stdout);
    let stderr = collect(stderr);
    Ran {
        ok: !timed_out && status.is_some_and(|status| status.success()),
        stdout,
        stderr,
    }
}

/// What a helper thread came back with.
enum Done {
    Checked {
        error: String,
        out: Vec<u8>,
    },
    /// kbuildsycoca6's error, or empty.
    Refreshed(String),
    Captured(Result<Captured, CaptureError>),
}

enum CaptureError {
    /// The helper's check failed: it is not ready.
    Check(String),
    /// Changed, then failed.
    Failed(String),
}

/// The setup a helper thread runs with.
#[derive(Clone)]
struct Runner {
    kind: Kind,
    tools: Option<Vec<PathBuf>>,
    timeout: Duration,
}

impl Runner {
    fn now(kind: Kind) -> Runner {
        SEAMS.with(|seams| {
            let seams = seams.borrow();
            Runner {
                kind,
                tools: seams.tools.clone(),
                timeout: seams.timeout.unwrap_or(TIMEOUT),
            }
        })
    }

    /// Runs `program` (a path, or a tool found on the tool path): empty, or
    /// the run's error the way this desktop's helper words it; and its output.
    fn run(&self, program: &str, arguments: &[&str]) -> (String, Vec<u8>) {
        let Some(path) = find(program, self.tools.as_deref()) else {
            return (self.run_error(program, b""), Vec::new());
        };
        let ran = run(&path, arguments, self.timeout);
        if ran.ok {
            (String::new(), ran.stdout)
        } else {
            (self.run_error(program, &ran.stderr), ran.stdout)
        }
    }

    fn run_error(&self, program: &str, stderr: &[u8]) -> String {
        if program == "kbuildsycoca6" {
            return "KDE couldn't register the capture helper. Make sure KDE's service tools (kbuildsycoca6) are installed, then reinstall the helper.".into();
        }
        let said = String::from_utf8_lossy(stderr).trim().to_owned();
        if self.kind == Kind::Kde && said.contains("NoAuthorized") {
            return "KDE hasn't granted capture access. Reinstall the capture helper in setup, then try again.".into();
        }
        if !said.is_empty() {
            return said;
        }
        match self.kind {
            Kind::Kde => {
                "The KDE capture helper did not respond. Reopen capture setup and check access."
                    .into()
            }
            Kind::Hyprland => {
                "Hyprland capture did not respond. Check capture setup and try again.".into()
            }
        }
    }

    /// KService must see the new desktop entry before KWin checks the
    /// executable; an AppImage's search paths and locale differ from
    /// Plasma's, so the cache is also rebuilt in the session's own
    /// environment, where failing is fine.
    fn refresh_services(&self) -> String {
        let (error, _) = self.run("kbuildsycoca6", &["--noincremental"]);
        if !error.is_empty() {
            return error;
        }
        let _ = self.run(
            "systemd-run",
            &[
                "--user",
                "--quiet",
                "--wait",
                "--collect",
                "--pipe",
                "--service-type=exec",
                "kbuildsycoca6",
                "--noincremental",
            ],
        );
        String::new()
    }

    fn capture(&self, executable: &Path) -> Result<Captured, CaptureError> {
        let exe = executable.to_string_lossy();
        let (error, _) = self.run(&exe, &["check"]);
        if !error.is_empty() {
            return Err(CaptureError::Check(error));
        }
        let Some(directory) = unique_dir(&std::env::temp_dir(), "hal-c2-capture-") else {
            return Err(CaptureError::Failed(
                "Couldn't make a place for the capture.".into(),
            ));
        };
        let result = self.read_capture(&exe, &directory);
        let _ = fs::remove_dir_all(&directory);
        result.map_err(CaptureError::Failed)
    }

    fn read_capture(&self, exe: &str, directory: &Path) -> Result<Captured, String> {
        let (error, out) = self.run(exe, &["capture", &directory.to_string_lossy()]);
        if !error.is_empty() {
            return Err(error);
        }
        let answer: Value = serde_json::from_slice(&out).unwrap_or(Value::Null);
        let window = answer.get("window").cloned().unwrap_or(Value::Null);
        let field = |key: &str| {
            window
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned()
        };
        let invalid = || "Invalid screenshot file.".to_owned();
        let mut file = fs::File::open(directory.join("capture.png")).map_err(|_| invalid())?;
        if file
            .metadata()
            .map_or(true, |info| info.len() > MAX_PNG_BYTES)
        {
            return Err(invalid());
        }
        let mut png = Vec::new();
        file.read_to_end(&mut png).map_err(|_| invalid())?;
        if !png.starts_with(b"\x89PNG\r\n\x1a\n") {
            return Err(invalid());
        }
        let image =
            image::load_from_memory_with_format(&png, ImageFormat::Png).map_err(|_| invalid())?;
        let app = field("appName");
        Ok(Captured {
            image: fit(image),
            app_name: if app.is_empty() { "Window".into() } else { app },
            window_title: field("title"),
            context: Json::Null,
        })
    }
}

/// The helper's files and the runs that ask it, one at a time: `check`
/// reads what is installed and asks a current helper whether it can
/// capture, `perform` installs or removes it, `capture` has it capture the
/// window in front. A run answers in [`CaptureHelper::arrive`].
pub struct CaptureHelper {
    kind: Kind,
    paths: Paths,
    state: State,
    busy: bool,
    job: Option<JoinHandle<Done>>,
}

impl CaptureHelper {
    pub fn new(kind: Kind, paths: Paths) -> CaptureHelper {
        CaptureHelper {
            kind,
            paths,
            state: State::default(),
            busy: false,
            job: None,
        }
    }

    pub fn kind(&self) -> Kind {
        self.kind
    }

    pub fn state(&self) -> &State {
        &self.state
    }

    pub fn busy(&self) -> bool {
        self.busy
    }

    pub fn executable(&self) -> PathBuf {
        self.paths
            .data_home
            .join("hal-c2")
            .join(self.kind.folder())
            .join(self.kind.executable_name())
    }

    fn entry_path(&self) -> PathBuf {
        self.paths.data_home.join("applications").join(DESKTOP_FILE)
    }

    fn entry_text(&self) -> String {
        [
            "[Desktop Entry]".to_owned(),
            "Type=Application".into(),
            "Name=HAL-C2 SnapShots".into(),
            "NoDisplay=true".into(),
            format!(
                "Exec={} check",
                exec_argument(&self.executable().to_string_lossy())
            ),
            // KService reads this custom property as a KConfig list, not an XDG ';' list.
            "X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2".into(),
            MARKER.into(),
            String::new(),
        ]
        .join("\n")
    }

    /// What the files say, before the helper is asked; ready means "ask it".
    fn files(&self) -> State {
        let link_error = self.kind.link_error();
        let installed = regular_file(&self.executable(), link_error);
        if !installed.error.is_empty() {
            return State::new("error", &installed.error);
        }
        let kde = self.kind == Kind::Kde;
        let mut entry = Read::default();
        if kde {
            entry = regular_file(&self.entry_path(), link_error);
            if !entry.error.is_empty() {
                return State::new("error", &entry.error);
            }
        }
        if !installed.exists || (kde && !entry.exists) {
            return State::new(
                "not-installed",
                if kde {
                    "Install the bundled helper to capture the window you're using without a picker."
                } else {
                    "Install the bundled helper to capture the window you're using."
                },
            );
        }
        let bundle = regular_file(&self.paths.bundle, link_error);
        if !bundle.error.is_empty() {
            return State::new("error", &bundle.error);
        }
        if !bundle.exists || self.paths.bundle.as_os_str().is_empty() {
            return State::new("error", self.kind.missing());
        }
        if installed.bytes != bundle.bytes
            || (kde && String::from_utf8_lossy(&entry.bytes) != self.entry_text())
        {
            return State::new(
                "update-required",
                "Update the bundled capture helper to continue.",
            );
        }
        State::new("ready", "")
    }

    fn start(&mut self, job: impl FnOnce(Runner) -> Done + Send + 'static) {
        let runner = Runner::now(self.kind);
        let wake = super::wake();
        self.job = Some(std::thread::spawn(move || {
            let done = job(runner);
            if let Some(wake) = &wake {
                wake();
            }
            done
        }));
    }

    pub fn check(&mut self) -> Vec<Event> {
        if self.busy {
            return Vec::new();
        }
        let found = self.files();
        if found.status != "ready" {
            self.state = found;
            return vec![Event::Changed];
        }
        self.busy = true;
        let exe = self.executable();
        self.start(move |runner| {
            let (error, out) = runner.run(&exe.to_string_lossy(), &["check"]);
            Done::Checked { error, out }
        });
        vec![Event::Changed]
    }

    fn performed(&mut self, error: String) -> Vec<Event> {
        let mut events = Vec::new();
        if !error.is_empty() {
            events.push(Event::SetupFailed(error));
        }
        events.extend(self.check());
        events
    }

    /// install-…-helper or remove-…-helper: a SetupFailed when it could not,
    /// then a check.
    pub fn perform(&mut self, action: &str) -> Vec<Event> {
        let removing = action == self.kind.remove_action();
        if action != self.kind.install_action() && !removing {
            return Vec::new();
        }
        if self.busy {
            return vec![Event::SetupFailed(BUSY.into())];
        }
        let kde = self.kind == Kind::Kde;
        let link_error = self.kind.link_error();
        let mut entry = Read::default();
        if kde {
            entry = regular_file(&self.entry_path(), link_error);
            if !entry.error.is_empty() {
                return self.performed(entry.error);
            }
            if entry.exists
                && !String::from_utf8_lossy(&entry.bytes)
                    .split('\n')
                    .any(|line| line == MARKER)
            {
                return self.performed(
                    "Another desktop entry uses the capture helper's name. Rename it before continuing.".into(),
                );
            }
        }
        let executable = self.executable();
        if foreign_directory(executable.parent().unwrap_or(Path::new(""))) {
            return self.performed(
                if kde {
                    "The capture helper directory is not a regular directory."
                } else {
                    "The capture helper directory must not be a link."
                }
                .into(),
            );
        }
        let installed = regular_file(&executable, link_error);
        if !installed.error.is_empty() {
            return self.performed(installed.error);
        }
        let error = if removing {
            if entry.exists {
                let _ = fs::remove_file(self.entry_path());
            }
            let _ = fs::remove_file(&executable);
            String::new()
        } else {
            let bundle = if self.paths.bundle.as_os_str().is_empty() {
                Read::default()
            } else {
                regular_file(&self.paths.bundle, link_error)
            };
            if !bundle.error.is_empty() {
                return self.performed(bundle.error);
            }
            if !bundle.exists {
                return self.performed(self.kind.missing().into());
            }
            self.install(&bundle.bytes)
        };
        if !error.is_empty() || !kde {
            return self.performed(error);
        }
        self.busy = true;
        self.start(|runner| Done::Refreshed(runner.refresh_services()));
        vec![Event::Changed]
    }

    fn install(&self, bundle: &[u8]) -> String {
        let target = self.executable();
        if fs::create_dir_all(target.parent().unwrap_or(Path::new(""))).is_err() {
            return "Could not create the capture helper directory.".into();
        }
        let error = write_executable(&target, bundle);
        if !error.is_empty() || self.kind != Kind::Kde {
            return error;
        }
        let entry = self.entry_path();
        if fs::create_dir_all(entry.parent().unwrap_or(Path::new(""))).is_err() {
            return "Could not create the applications directory.".into();
        }
        let mut staged = entry.clone().into_os_string();
        staged.push(format!(".{}.tmp", unique_name()));
        let staged = PathBuf::from(staged);
        let written = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&staged)
            .and_then(|mut file| {
                std::io::Write::write_all(&mut file, self.entry_text().as_bytes())
            });
        if let Err(error) = written {
            let _ = fs::remove_file(&staged);
            return error.to_string();
        }
        set_mode(&staged, 0o644);
        if fs::rename(&staged, &entry).is_err() {
            let _ = fs::remove_file(&staged);
            return "Could not install the capture helper's desktop entry.".into();
        }
        String::new()
    }

    /// Checks, then captures the window in front: Captured or Failed.
    pub fn capture(&mut self) -> Vec<Event> {
        if self.busy {
            return vec![Event::Failed(BUSY.into())];
        }
        let found = self.files();
        if found.status != "ready" {
            let message = format!("{} {CONTINUE}", found.message);
            self.state = found;
            return vec![Event::Changed, Event::Failed(message)];
        }
        self.busy = true;
        let exe = self.executable();
        self.start(move |runner| Done::Captured(runner.capture(&exe)));
        vec![Event::Changed]
    }

    /// What a finished run says.
    pub fn arrive(&mut self) -> Vec<Event> {
        if !self.job.as_ref().is_some_and(JoinHandle::is_finished) {
            return Vec::new();
        }
        self.finish()
    }

    /// Waits for the run under way, then says what it said.
    pub fn wait(&mut self) -> Vec<Event> {
        let mut events = Vec::new();
        while self.job.is_some() {
            events.extend(self.finish());
        }
        events
    }

    fn finish(&mut self) -> Vec<Event> {
        let Some(job) = self.job.take() else {
            return Vec::new();
        };
        let Ok(done) = job.join() else {
            self.busy = false;
            return vec![Event::Changed];
        };
        self.busy = false;
        match done {
            Done::Checked { error, out } => {
                self.state = if error.is_empty() {
                    let answer: Value = serde_json::from_slice(&out).unwrap_or(Value::Null);
                    State {
                        status: "ready".into(),
                        message: match self.kind {
                            Kind::Kde => "KDE capture access is ready. Next, choose your shortcut.",
                            Kind::Hyprland => {
                                "Helper ready. Hyprland may ask for screen-sharing permission on your first capture."
                            }
                        }
                        .into(),
                        feedback_available: answer
                            .get("feedbackAvailable")
                            .and_then(Value::as_bool)
                            .unwrap_or(false),
                    }
                } else {
                    State::new("error", &error)
                };
                vec![Event::Changed]
            }
            Done::Refreshed(error) => self.performed(error),
            Done::Captured(Err(CaptureError::Check(error))) => {
                let message = format!("{error} {CONTINUE}");
                self.state = State::new("error", &error);
                vec![Event::Changed, Event::Failed(message)]
            }
            Done::Captured(Err(CaptureError::Failed(error))) => {
                vec![Event::Changed, Event::Failed(error)]
            }
            Done::Captured(Ok(captured)) => vec![Event::Changed, Event::Captured(captured)],
        }
    }
}

pub struct HelperSnapShot {
    desktop: String,
    shortcuts: Box<dyn Backend>,
    helper: CaptureHelper,
    /// The user checked again; the answer says whether that changed anything.
    rechecked: bool,
}

impl HelperSnapShot {
    pub fn new(
        platform: &Platform,
        shortcuts: Box<dyn Backend>,
        helper: CaptureHelper,
    ) -> HelperSnapShot {
        HelperSnapShot {
            desktop: platform.desktop.clone(),
            shortcuts,
            helper,
            rechecked: false,
        }
    }

    pub fn helper(&self) -> &CaptureHelper {
        &self.helper
    }
}

impl Backend for HelperSnapShot {
    fn session(&self) -> Session {
        Session {
            // Known once the helper has been looked at; the portal's Screenshot is never used.
            ready: !self.helper.state.status.is_empty(),
            mode: Mode::Portal,
            backend: "helper".into(),
            desktop: self.desktop.clone(),
            checking: self.helper.busy,
            // The helper can draw effects where the desktop lets it, but nothing here asks it to yet.
            feedback_available: false,
            ..Session::default()
        }
    }

    fn shortcut(&self) -> Shortcut {
        self.shortcuts.shortcut()
    }

    fn probe(&mut self) -> Vec<Event> {
        if self.helper.state.status.is_empty() {
            return self.helper.check();
        }
        Vec::new()
    }

    fn refresh(&mut self) -> Vec<Event> {
        self.rechecked = true;
        self.helper.check()
    }

    fn bind(&mut self, trigger: &str) -> Vec<Event> {
        self.shortcuts.bind(trigger)
    }

    fn release(&mut self) -> Vec<Event> {
        self.shortcuts.release()
    }

    fn configure(&mut self) -> Vec<Event> {
        self.shortcuts.configure()
    }

    fn check_shortcut(&mut self, shortcut: &Json) -> Option<Check> {
        self.shortcuts.check_shortcut(shortcut)
    }

    fn pause(&mut self, paused: bool) -> Result<(), String> {
        self.shortcuts.pause(paused)
    }

    fn capture(&mut self) -> Vec<Event> {
        self.helper.capture()
    }

    fn play(&mut self, sound: &str) {
        self.shortcuts.play(sound);
    }

    /// SnapShotSetupDialog's helper copy, and the settings' capture row and
    /// effects line, for the helper's state.
    fn setup(&self) -> Option<Setup> {
        let state = &self.helper.state;
        let status = state.status.as_str();
        let ready = status == "ready";
        let error = status == "error";
        let busy = self.helper.busy;
        let kind = self.helper.kind;
        let mut setup = Setup {
            access_ready: ready,
            ..Setup::default()
        };
        if ready {
            setup.heading = "Capture is ready".into();
            setup.body = "Next, choose your shortcut.".into();
            // Hyprland's helper says it may still ask for screen-sharing on the first capture.
            if kind == Kind::Hyprland {
                setup.details = state.message.clone();
            }
        } else if error {
            setup.heading = "Let's fix capture access".into();
            setup.body = "Try reinstalling the capture helper, then check again.".into();
            setup.details = state.message.clone();
        } else {
            setup.heading = if status == "update-required" {
                "Update the capture helper"
            } else {
                "Allow snapshots"
            }
            .into();
            setup.body = "HAL-C2's capture helper lets you capture other apps and return to your draft. It's included with HAL-C2.".into();
        }
        if busy {
            setup.action_label = if status.is_empty() || error || ready {
                "Checking…"
            } else {
                "Installing…"
            }
            .into();
        } else if status == "not-installed" {
            setup.action = kind.install_action().into();
            setup.action_label = "Install helper".into();
        } else if status == "update-required" {
            setup.action = kind.install_action().into();
            setup.action_label = "Update helper".into();
        } else if !ready {
            setup.action_label = "Check again".into();
        }
        if self.rechecked && !busy && !status.is_empty() {
            setup.check_message = if error {
                "Still unable to check access. See Advanced for help."
            } else if ready {
                "Ready. Continue to choose your shortcut."
            } else {
                "Not ready yet. Finish the step above."
            }
            .into();
        }
        setup.status = if error {
            "Check capture access in setup"
        } else {
            "Install the capture helper to continue"
        }
        .into();
        setup.effects = if ready {
            "Capture effects aren't available on this desktop."
        } else {
            "Install or update the capture helper to enable effects."
        }
        .into();
        let included = "Included with HAL-C2. No download needed.";
        if error {
            setup.advanced.push(SetupOption {
                action: kind.install_action().into(),
                label: "Reinstall helper".into(),
                note: included.into(),
            });
        }
        if !status.is_empty() && status != "not-installed" {
            setup.advanced.push(SetupOption {
                action: kind.remove_action().into(),
                label: "Remove capture helper".into(),
                note: included.into(),
            });
        }
        Some(setup)
    }

    fn perform(&mut self, action: &str) -> Vec<Event> {
        let kind = self.helper.kind;
        if action != kind.install_action() && action != kind.remove_action() {
            return vec![Event::SetupFailed(super::unsupported_setup(action))];
        }
        self.rechecked = false;
        self.helper.perform(action)
    }

    fn arrive(&mut self) -> Vec<Event> {
        let mut events = self.shortcuts.arrive();
        events.extend(self.helper.arrive());
        events
    }

    fn timeout(&mut self, token: u64) -> Vec<Event> {
        self.shortcuts.timeout(token)
    }
}
