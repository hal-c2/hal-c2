//! GNOME captures through HAL-C2's own extension (native/gnome-snap-shot),
//! desktop-qt's GnomeSnapShot: the desktop portal's Screenshot shows a
//! picker there, while the extension takes the window in front. Setup
//! installs the extension bundled with the app into the user's GNOME Shell
//! extensions, then enables it.
//!
//! Everything else is the portal's: the shortcut, and the capture itself
//! when the portal can take the window in front (preferred to the
//! extension) or the extension does not answer (its picker).

use std::cell::RefCell;
use std::collections::VecDeque;
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use image::{DynamicImage, ImageFormat, RgbaImage, imageops::FilterType};
use serde_json::Value;

use super::{Backend, Captured, Check, Event, Json, Session, Setup, SetupOption, Shortcut};

/// The extension's uuid, its folder's name under gnome-shell/extensions.
pub const UUID: &str = "snap-shot@hal-c2.example";
const MAX_PNG_BYTES: usize = 32 * 1024 * 1024;
const MISSING: &str = "The extension is missing from this build. Update or reinstall HAL-C2.";

/// What GNOME Shell says of the HAL-C2 extension.
#[derive(Clone, Debug, PartialEq)]
pub struct Extension {
    /// Why GNOME could not be asked; the rest is unknown when set.
    pub failure: String,
    /// org.gnome.Shell.Extensions' ShellVersion, "47.2".
    pub shell_version: String,
    pub user_extensions_enabled: bool,
    /// GetExtensionInfo: none until GNOME has loaded the extension (at a
    /// login after it was installed). 1 is enabled, 3 and 4 failed.
    pub state: Option<i32>,
    pub version: Option<f64>,
    pub error: String,
    /// The Version the extension's capture service answers with, 0 when
    /// it does not answer.
    pub service: i32,
}

impl Default for Extension {
    fn default() -> Extension {
        Extension {
            failure: String::new(),
            shell_version: String::new(),
            user_extensions_enabled: true,
            state: None,
            version: None,
            error: String::new(),
            service: 0,
        }
    }
}

/// A window the extension captured.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Capture {
    pub png: Vec<u8>,
    /// JSON: title, appName, appIdentifier, processId, bounds.
    pub metadata: String,
    /// Why there is no capture, when there is none.
    pub error: String,
}

/// What GNOME Shell answered, in the order it was asked.
#[derive(Clone, Debug, PartialEq)]
pub enum Reply {
    Inspected(Extension),
    /// EnableExtension or DisableExtension: an error, or empty.
    Enabled(String),
    Captured(Capture),
}

/// What the backend asks GNOME Shell over the session bus: the extension's
/// state, turning it on or off, and a capture through it. Each call is
/// answered by a [`Reply`] in [`GnomeShell::replies`], in order; the real
/// one ([`system_shell`]) answers on its own thread, tests at once.
pub trait GnomeShell {
    fn inspect(&mut self);
    fn set_enabled(&mut self, on: bool);
    /// Takes `bus_name` for the call (no one else may hold it), then
    /// Capture, or CaptureWithFeedback showing the flash when `flash`.
    fn capture(&mut self, bus_name: &str, flash: bool);
    fn replies(&mut self) -> Vec<Reply>;
}

/// How a folder moves; tests make it fail.
pub type Rename = Rc<dyn Fn(&Path, &Path) -> bool>;

#[derive(Clone)]
pub struct Paths {
    /// The bundle: metadata.json, bundle.json and the files it lists.
    pub bundle: PathBuf,
    /// $XDG_DATA_HOME: the extension goes to gnome-shell/extensions/<uuid>.
    pub data_home: PathBuf,
    /// None is the filesystem's.
    pub rename: Option<Rename>,
}

impl Paths {
    fn extensions(&self) -> PathBuf {
        self.data_home.join("gnome-shell/extensions")
    }

    /// Where the extension is installed.
    pub fn target(&self) -> PathBuf {
        self.extensions().join(UUID)
    }

    fn rename(&self, from: &Path, to: &Path) -> bool {
        match &self.rename {
            Some(rename) => rename(from, to),
            None => fs::rename(from, to).is_ok(),
        }
    }
}

/// Where setup stands (GnomeCaptureSetup.state).
#[derive(Clone, Debug, PartialEq)]
pub struct Status {
    /// unsupported, not-installed, restart-required, update-required,
    /// extensions-disabled, enabled, error or disabled.
    pub status: String,
    pub message: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Metadata {
    pub version: f64,
    pub shell_versions: Vec<String>,
}

/// What a test makes instead of the extension's backend around `portal`.
pub type GnomeFactory = Rc<dyn Fn(Box<dyn Backend>) -> Box<dyn Backend>>;

thread_local! {
    static GNOME_FACTORY: RefCell<Option<GnomeFactory>> = const { RefCell::new(None) };
}

/// Tests stand in for the extension's backend (SnapShotBackend's
/// setGnomeFactory); `None` restores it.
pub fn set_gnome_factory(factory: Option<GnomeFactory>) {
    GNOME_FACTORY.with(|held| *held.borrow_mut() = factory);
}

/// GNOME's backend around `portal`: a test's, or the extension bundled
/// with the app on the session bus. A stand-in portal never reaches the
/// real GNOME Shell: it stays as it is.
pub fn create(portal: Box<dyn Backend>) -> Box<dyn Backend> {
    if let Some(factory) = GNOME_FACTORY.with(|held| held.borrow().clone()) {
        return factory(portal);
    }
    if super::portal_overridden() {
        return portal;
    }
    match system_shell() {
        Some(shell) => Box::new(GnomeSnapShot::new(portal, shell, default_paths())),
        None => portal,
    }
}

/// The bundle this build carries and the user's data directory: a package
/// has it in share/hal-c2/gnome-extension beside bin/, a development build
/// in the checkout.
pub fn default_paths() -> Paths {
    let packaged = std::env::current_exe()
        .ok()
        .and_then(|exe| {
            exe.parent()
                .map(|bin| bin.join("../share/hal-c2/gnome-extension"))
        })
        .filter(|bundle| bundle.join("metadata.json").is_file());
    let bundle = packaged.unwrap_or_else(|| {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../native/gnome-snap-shot")
    });
    Paths {
        bundle,
        data_home: data_home(),
        rename: None,
    }
}

/// $XDG_DATA_HOME, else ~/.local/share.
pub fn data_home() -> PathBuf {
    match super::env_var("XDG_DATA_HOME").filter(|dir| !dir.is_empty()) {
        Some(dir) => PathBuf::from(dir),
        None => PathBuf::from(super::env_var("HOME").unwrap_or_default()).join(".local/share"),
    }
}

/// A setup step that waits for GNOME's answer first.
enum Then {
    Install,
    Enable(bool),
}

pub struct GnomeSnapShot {
    portal: Box<dyn Backend>,
    shell: Box<dyn GnomeShell>,
    paths: Paths,
    extension: Option<Extension>,
    status: Option<Status>,
    /// The inspections asked, oldest first: only the newest answer counts.
    inspections: VecDeque<Option<Then>>,
    /// Enable or disable is out.
    enabling: bool,
    /// A setup step the user chose is running.
    working: bool,
    flash: bool,
    capturing: bool,
}

impl GnomeSnapShot {
    pub fn new(
        portal: Box<dyn Backend>,
        shell: Box<dyn GnomeShell>,
        paths: Paths,
    ) -> GnomeSnapShot {
        GnomeSnapShot {
            portal,
            shell,
            paths,
            extension: None,
            status: None,
            inspections: VecDeque::new(),
            enabling: false,
            working: false,
            flash: false,
            capturing: false,
        }
    }

    /// Whose setup is shown: the portal cannot take the window in front,
    /// and this GNOME can run the extension.
    fn extension_setup(&self) -> bool {
        let portal = self.portal.session();
        self.status.as_ref().is_some_and(|status| {
            portal.ready
                && portal.message.is_empty()
                && portal.backend != "screenshot-portal"
                && status.status != "unsupported"
        })
    }

    fn answering(&self) -> bool {
        self.extension
            .as_ref()
            .is_some_and(|extension| extension.service == 1 || extension.service == 2)
    }

    fn service(&self) -> i32 {
        self.extension
            .as_ref()
            .map_or(0, |extension| extension.service)
    }

    /// Asks GNOME where setup stands; `then` runs with the answer in place.
    fn inspect(&mut self, then: Option<Then>) -> Vec<Event> {
        self.inspections.push_back(then);
        self.shell.inspect();
        self.answers()
    }

    /// What the shell has answered so far.
    fn answers(&mut self) -> Vec<Event> {
        let mut events = Vec::new();
        loop {
            let replies = self.shell.replies();
            if replies.is_empty() {
                return events;
            }
            for reply in replies {
                events.extend(self.answer(reply));
            }
        }
    }

    fn answer(&mut self, reply: Reply) -> Vec<Event> {
        match reply {
            Reply::Inspected(extension) => {
                let Some(then) = self.inspections.pop_front() else {
                    return Vec::new();
                };
                // A newer inspection is out: this answer is stale.
                if !self.inspections.is_empty() {
                    return Vec::new();
                }
                let bundled = metadata(&self.paths.bundle);
                self.status = Some(match &bundled {
                    Some(bundled) => {
                        status(&extension, bundled, metadata(&self.paths.target()).as_ref())
                    }
                    None => Status {
                        status: "error".into(),
                        message: MISSING.into(),
                    },
                });
                self.extension = Some(extension);
                let mut events = match then {
                    Some(then) => self.act(then),
                    None => Vec::new(),
                };
                events.push(Event::Changed);
                events
            }
            Reply::Enabled(error) => {
                if !self.enabling {
                    return Vec::new();
                }
                self.enabling = false;
                self.settled(error)
            }
            Reply::Captured(capture) => {
                self.capturing = false;
                if !capture.error.is_empty() {
                    return vec![Event::Failed(capture.error)];
                }
                let image = match decode(&capture.png) {
                    Ok(image) => image,
                    Err(error) => return vec![Event::Failed(error)],
                };
                let window: Value = serde_json::from_str(&capture.metadata).unwrap_or(Value::Null);
                let field = |key: &str| {
                    window
                        .get(key)
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned()
                };
                vec![Event::Captured(Captured {
                    image,
                    app_name: field("appName"),
                    window_title: field("title"),
                    context: Json::Null,
                })]
            }
        }
    }

    /// The step the user chose, now that GNOME has said where setup stands.
    fn act(&mut self, then: Then) -> Vec<Event> {
        let now = self
            .status
            .clone()
            .expect("an inspection's answer is in place");
        match then {
            Then::Install => {
                let mut error = install_blocked(&self.paths);
                if error.is_empty() {
                    error = if now.status == "not-installed" || now.status == "update-required" {
                        install(&self.paths)
                    } else {
                        now.message
                    };
                }
                // GNOME discovers a newly installed local extension at the next login.
                self.settled(error)
            }
            Then::Enable(true) if now.status != "disabled" => self.settled(now.message),
            Then::Enable(on) => {
                self.enabling = true;
                self.shell.set_enabled(on);
                // Its answer comes through `answers`, which is draining.
                Vec::new()
            }
        }
    }

    fn settled(&mut self, error: String) -> Vec<Event> {
        self.working = false;
        let mut events = Vec::new();
        if !error.is_empty() {
            events.push(Event::SetupFailed(error));
        }
        // Whatever it did, GNOME says where setup stands now.
        self.inspections.push_back(None);
        self.shell.inspect();
        events.push(Event::Changed);
        events
    }
}

impl Backend for GnomeSnapShot {
    fn session(&self) -> Session {
        let mut session = self.portal.session();
        session.ready = session.ready && self.status.is_some();
        session.checking = session.checking
            || self.working
            || (!self.inspections.is_empty() && self.status.is_some());
        if self.extension_setup() {
            session.backend = "gnome-extension".into();
            session.feedback_available = self.service() == 2;
        }
        session
    }

    fn shortcut(&self) -> Shortcut {
        self.portal.shortcut()
    }

    fn probe(&mut self) -> Vec<Event> {
        let mut events = self.portal.probe();
        if self.status.is_none() && self.inspections.is_empty() {
            events.extend(self.inspect(None));
        }
        events
    }

    fn refresh(&mut self) -> Vec<Event> {
        let mut events = self.portal.refresh();
        // A step under way looks again when it is done.
        if self.working {
            return events;
        }
        events.extend(self.inspect(None));
        events.push(Event::Changed);
        events
    }

    fn bind(&mut self, trigger: &str) -> Vec<Event> {
        self.portal.bind(trigger)
    }

    fn release(&mut self) -> Vec<Event> {
        self.portal.release()
    }

    fn configure(&mut self) -> Vec<Event> {
        self.portal.configure()
    }

    fn trigger(&self, shortcut: &Json) -> Result<String, String> {
        self.portal.trigger(shortcut)
    }

    fn set_cues(&mut self, flash: bool, animations: bool) {
        self.portal.set_cues(flash, animations);
    }

    fn check_shortcut(&mut self, shortcut: &Json) -> Option<Check> {
        self.portal.check_shortcut(shortcut)
    }

    fn pause(&mut self, paused: bool) -> Result<(), String> {
        self.portal.pause(paused)
    }

    fn capture(&mut self) -> Vec<Event> {
        // The portal first, whenever it can take the window in front; and
        // its picker when the extension does not answer, which is
        // capability missing, not denied.
        if self.portal.session().backend == "screenshot-portal" || !self.answering() {
            return self.portal.capture();
        }
        if self.capturing {
            return Vec::new();
        }
        self.capturing = true;
        let flash = self.flash && self.service() == 2;
        // main.rs's APP_ID.
        self.shell.capture(bus_name("hal-c2"), flash);
        self.answers()
    }

    fn play(&mut self, sound: &str) {
        self.portal.play(sound);
    }

    fn set_effects(&mut self, flash: bool, animate: bool) {
        self.portal.set_effects(flash, animate);
        self.flash = flash;
    }

    fn setup(&self) -> Option<Setup> {
        let status = self.status.as_ref()?;
        let portal = self.portal.session();
        if !portal.ready || !portal.message.is_empty() || portal.backend == "screenshot-portal" {
            return None;
        }
        let name = status.status.as_str();
        let mut setup = Setup::default();
        // Without the extension this is the picker, whose setup is only this word.
        if name == "unsupported" {
            setup.access_ready = true;
            setup.heading = "Automatic capture isn't available".into();
            setup.body = "Use Take snapshot from the command palette to choose a window.".into();
            setup.details = status.message.clone();
            setup.check_message = "Ready. You'll choose a window each time.".into();
            return Some(setup);
        }
        let enabled = name == "enabled";
        setup.status = if enabled {
            String::new()
        } else {
            "Set up active-window snapshots".into()
        };
        setup.effects = if self.service() == 1 {
            "Update the GNOME extension, then sign out and back in to enable effects.".into()
        } else if !enabled || !self.answering() {
            "Finish extension setup to enable effects.".into()
        } else {
            String::new()
        };
        setup.action_label = "Check again".into();
        setup.check_message = "Not ready yet. Finish the step above.".into();
        let mut say = |heading: &str, body: &str| {
            setup.heading = heading.into();
            setup.body = body.into();
        };
        match name {
            "not-installed" => {
                say(
                    "Install the extension",
                    "The HAL-C2 GNOME extension lets you capture other windows and bring them into your draft. Sign out once after installing.",
                );
                setup.action = "install-extension".into();
                setup.action_label = "Install extension".into();
            }
            "restart-required" => {
                say(
                    "Extension installed",
                    "Save your work, then sign out and back in. Your setup will be waiting here.",
                );
                setup.check_message = "Still waiting for you to sign out and back in.".into();
            }
            "update-required" => {
                say(
                    "Update the extension",
                    "Install the update, then sign out and back in.",
                );
                setup.action = "install-extension".into();
                setup.action_label = "Update extension".into();
            }
            "extensions-disabled" => say(
                "Allow GNOME extensions",
                "Open GNOME Extensions and turn on Extensions, then check again.",
            ),
            "disabled" => {
                say(
                    "Enable the extension",
                    "Enable HAL-C2 SnapShots to start capturing windows.",
                );
                setup.action = "enable-extension".into();
                setup.action_label = "Enable extension".into();
            }
            "enabled" if self.answering() => {
                say("Capture is ready", "Next, choose your shortcut.");
                setup.access_ready = true;
                setup.action_label.clear();
                setup.check_message = "Ready. Continue to choose your shortcut.".into();
            }
            "enabled" => {
                say(
                    "Check capture access",
                    "The extension isn't ready yet. Try again in a moment.",
                );
                setup.action_label.clear();
            }
            _ => {
                say(
                    "Couldn't set up the extension",
                    "Check HAL-C2 SnapShots in GNOME Extensions, then try again.",
                );
                setup.details = status.message.clone();
                setup.check_message = "Still unable to check access. See Advanced for help.".into();
            }
        }
        if enabled {
            setup.advanced.push(SetupOption {
                action: "disable-extension".into(),
                label: "Disable extension".into(),
                note: "Included with HAL-C2. No download needed.".into(),
            });
        }
        Some(setup)
    }

    fn perform(&mut self, action: &str) -> Vec<Event> {
        let then = match action {
            "install-extension" => Then::Install,
            "enable-extension" => Then::Enable(true),
            "disable-extension" => Then::Enable(false),
            _ => return vec![Event::SetupFailed(super::unsupported_setup(action))],
        };
        if self.working {
            return Vec::new();
        }
        self.working = true;
        let mut events = vec![Event::Changed];
        // What was on screen may be out of date: GNOME is asked again
        // before anything changes.
        events.extend(self.inspect(Some(then)));
        events
    }

    fn arrive(&mut self) -> Vec<Event> {
        let mut events = self.portal.arrive();
        events.extend(self.answers());
        events
    }

    fn timeout(&mut self, token: u64) -> Vec<Event> {
        self.portal.timeout(token)
    }
}

/// The extension's metadata.json in `dir`, if it reads as the HAL-C2 one.
pub fn metadata(dir: &Path) -> Option<Metadata> {
    let json: Value = serde_json::from_slice(&fs::read(dir.join("metadata.json")).ok()?).ok()?;
    if json.get("uuid").and_then(Value::as_str) != Some(UUID) {
        return None;
    }
    let version = json.get("version").and_then(Value::as_f64)?;
    let shell_versions = json
        .get("shell-version")
        .and_then(Value::as_array)?
        .iter()
        .map(|version| version.as_str().unwrap_or_default().to_owned())
        .collect();
    Some(Metadata {
        version,
        shell_versions,
    })
}

pub fn status(shell: &Extension, bundled: &Metadata, installed: Option<&Metadata>) -> Status {
    let say = |status: &str, message: &str| Status {
        status: status.into(),
        message: message.into(),
    };
    if !shell.failure.is_empty() {
        return say("error", &shell.failure);
    }
    let major = shell.shell_version.split('.').next().unwrap_or_default();
    if !bundled
        .shell_versions
        .iter()
        .any(|version| version == major)
    {
        return say(
            "unsupported",
            &format!(
                "The bundled extension supports GNOME {}. This session runs GNOME {major}.",
                bundled.shell_versions.join(", ")
            ),
        );
    }
    if shell.state.is_none() && installed.is_none() {
        return say(
            "not-installed",
            "Install the bundled extension to capture the active window without a picker. No download or administrator password is needed.",
        );
    }
    if let Some(installed) = installed
        && (shell.state.is_none()
            || shell
                .version
                .is_some_and(|loaded| installed.version > loaded))
    {
        return say(
            "restart-required",
            "Installed. Save your work, sign out of GNOME and sign back in, then return here to enable the extension. Restarting HAL-C2 alone is not enough.",
        );
    }
    let have = installed.map_or(shell.version.unwrap_or(0.0), |installed| installed.version);
    if have < bundled.version {
        return say(
            "update-required",
            "A newer extension is bundled with this app. Install it, then sign out and back in to load the update.",
        );
    }
    if !shell.user_extensions_enabled {
        return say(
            "extensions-disabled",
            "GNOME has disabled user extensions. Turn on Extensions in the GNOME Extensions app, then check again. HAL-C2 will not enable your other extensions for you.",
        );
    }
    match shell.state {
        Some(1) => say(
            "enabled",
            "The HAL-C2 extension is running. Active-window snapshots are available.",
        ),
        Some(3 | 4) if !shell.error.is_empty() => say("error", &shell.error),
        Some(3 | 4) => say(
            "error",
            "GNOME could not load the extension. Check GNOME Extensions for details, or sign out and back in.",
        ),
        _ => say(
            "disabled",
            "Enable the HAL-C2 extension to allow active-window snapshots. You can disable it here at any time.",
        ),
    }
}

/// The folder itself, not what a link points to; a dangling link counts.
fn present(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

/// Why the installed extension must be left alone (a link, or newer than
/// the bundle); empty when [`install`] may replace it.
pub fn install_blocked(paths: &Paths) -> String {
    let target = paths.target();
    let Ok(existing) = fs::symlink_metadata(&target) else {
        return String::new();
    };
    if !existing.is_dir() {
        return "The extension installation is not a regular directory. Manage it in GNOME Extensions instead.".into();
    }
    let Some(installed) = metadata(&target) else {
        return "The installed extension could not be read. Manage it in GNOME Extensions instead."
            .into();
    };
    if metadata(&paths.bundle).is_some_and(|bundled| installed.version > bundled.version) {
        return "A newer extension is installed. Update HAL-C2 instead of replacing it.".into();
    }
    String::new()
}

/// A new folder `<prefix>XXXXXX` in `parent`, as QTemporaryDir names one.
pub(super) fn unique_dir(parent: &Path, prefix: &str) -> Option<PathBuf> {
    let seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |time| time.as_nanos());
    for attempt in 0..64u128 {
        let mut n =
            seed.wrapping_add(attempt.wrapping_mul(0x9e37_79b9)) ^ u128::from(std::process::id());
        let mut name = String::from(prefix);
        for _ in 0..6 {
            let c = b"abcdefghijklmnopqrstuvwxyz0123456789"[(n % 36) as usize];
            name.push(char::from(c));
            n /= 36;
        }
        let dir = parent.join(name);
        if fs::create_dir(&dir).is_ok() {
            return Some(dir);
        }
    }
    None
}

#[cfg(unix)]
pub(super) fn set_mode(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(path, fs::Permissions::from_mode(mode));
}

#[cfg(not(unix))]
pub(super) fn set_mode(_path: &Path, _mode: u32) {}

/// Puts the bundle's files in place of the installed extension, keeping
/// that one under <data_home>/hal-c2/extension-backups; empty, or why not.
pub fn install(paths: &Paths) -> String {
    if metadata(&paths.bundle).is_none() {
        return MISSING.into();
    }
    let blocked = install_blocked(paths);
    if !blocked.is_empty() {
        return blocked;
    }
    let files: Vec<String> = fs::read(paths.bundle.join("bundle.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|json| {
            json.get("files")?.as_array().map(|files| {
                files
                    .iter()
                    .map(|file| file.as_str().unwrap_or_default().to_owned())
                    .collect()
            })
        })
        .unwrap_or_default();
    if files.is_empty() {
        return MISSING.into();
    }
    let could_not = "Could not set up the GNOME extension.".to_owned();
    let parent = paths.extensions();
    if fs::create_dir_all(&parent).is_err() {
        return could_not;
    }
    // Beside the target, so it moves into place in one step.
    let Some(staged) = unique_dir(&parent, ".hal-c2-capture-install-") else {
        return could_not;
    };
    let discard = |error: String| {
        let _ = fs::remove_dir_all(&staged);
        error
    };
    for name in &files {
        let to = staged.join(name);
        if name.is_empty() || fs::copy(paths.bundle.join(name), &to).is_err() {
            return discard(MISSING.into());
        }
        set_mode(&to, 0o644);
    }
    set_mode(&staged, 0o755);

    let target = paths.target();
    let mut backup = None;
    if present(&target) {
        let backups = paths.data_home.join("hal-c2/extension-backups");
        if fs::create_dir_all(&backups).is_err() {
            return discard(could_not);
        }
        let Some(boxed) = unique_dir(&backups, "capture-") else {
            return discard(could_not);
        };
        let kept = boxed.join(UUID);
        if !paths.rename(&target, &kept) {
            let _ = fs::remove_dir(&boxed);
            return discard(could_not);
        }
        backup = Some(kept);
    }
    if !paths.rename(&staged, &target) {
        if let Some(kept) = backup {
            let _ = fs::rename(&kept, &target);
            if let Some(boxed) = kept.parent() {
                let _ = fs::remove_dir(boxed);
            }
        }
        return discard(could_not);
    }
    String::new()
}

/// The name the extension answers (captureService.js trusts these two).
pub fn bus_name(app_id: &str) -> &'static str {
    if app_id.to_lowercase().contains("dev") {
        "io.github.halc2.HalC2.Development.SnapShot"
    } else {
        "io.github.halc2.HalC2.SnapShot"
    }
}

/// The extension's PNG as an image no larger than 2560x1600, or why not.
pub fn decode(png: &[u8]) -> Result<RgbaImage, String> {
    let invalid = || "Invalid or oversized window screenshot.".to_owned();
    if png.len() > MAX_PNG_BYTES || !png.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err(invalid());
    }
    let image = image::load(Cursor::new(png), ImageFormat::Png).map_err(|_| invalid())?;
    Ok(fit(image))
}

/// `image` scaled down to fit 2560x1600, as captures are.
pub fn fit(image: DynamicImage) -> RgbaImage {
    if image.width() > 2560 || image.height() > 1600 {
        image.resize(2560, 1600, FilterType::Triangle).to_rgba8()
    } else {
        image.to_rgba8()
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
pub use bus::system_shell;

#[cfg(not(all(unix, not(target_os = "macos"))))]
pub fn system_shell() -> Option<Box<dyn GnomeShell>> {
    None
}

/// GNOME Shell on the session bus, asked on a thread of its own.
#[cfg(all(unix, not(target_os = "macos")))]
mod bus {
    use std::collections::HashMap;
    use std::sync::mpsc;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use zbus::blocking::Connection;
    use zbus::fdo::{RequestNameFlags, RequestNameReply};
    use zbus::zvariant::{OwnedValue, Value};

    use super::{Capture, Extension, GnomeShell, Reply, UUID};

    const SHELL: &str = "org.gnome.Shell";
    const SHELL_PATH: &str = "/org/gnome/Shell";
    const EXTENSIONS: &str = "org.gnome.Shell.Extensions";
    const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
    const SERVICE: &str = "org.gnome.Shell.Extensions.HalC2SnapShot";
    const SERVICE_PATH: &str = "/org/gnome/Shell/Extensions/HalC2SnapShot";
    const TIMEOUT: Duration = Duration::from_secs(5);
    /// How long the connection outlives a capture: the extension takes its
    /// flash away with the connection, and the flash lasts 180ms.
    const FLASH: Duration = Duration::from_millis(300);
    const SILENT: &str = "GNOME did not respond. Sign in to a GNOME Wayland session and try again.";

    enum Job {
        Inspect,
        SetEnabled(bool),
        Capture(String, bool),
    }

    struct Bus {
        jobs: mpsc::Sender<Job>,
        replies: Arc<Mutex<Vec<Reply>>>,
    }

    /// The session bus's GNOME Shell; its answers wake the Engine thread.
    pub fn system_shell() -> Option<Box<dyn GnomeShell>> {
        let (jobs, inbox) = mpsc::channel::<Job>();
        let replies = Arc::new(Mutex::new(Vec::new()));
        let out = replies.clone();
        let wake = super::super::wake();
        std::thread::Builder::new()
            .name("snap-shot-gnome".into())
            .spawn(move || {
                let bus = connect();
                for job in inbox {
                    let reply = match job {
                        Job::Inspect => Reply::Inspected(inspect(bus.as_ref())),
                        Job::SetEnabled(on) => Reply::Enabled(set_enabled(bus.as_ref(), on)),
                        Job::Capture(name, flash) => {
                            let (capture, held) = capture(&name, flash);
                            out.lock()
                                .unwrap_or_else(|e| e.into_inner())
                                .push(Reply::Captured(capture));
                            if let Some(wake) = &wake {
                                wake();
                            }
                            if held.is_some() && flash {
                                std::thread::sleep(FLASH);
                            }
                            continue;
                        }
                    };
                    out.lock().unwrap_or_else(|e| e.into_inner()).push(reply);
                    if let Some(wake) = &wake {
                        wake();
                    }
                }
            })
            .ok()?;
        Some(Box::new(Bus { jobs, replies }))
    }

    impl GnomeShell for Bus {
        fn inspect(&mut self) {
            let _ = self.jobs.send(Job::Inspect);
        }
        fn set_enabled(&mut self, on: bool) {
            let _ = self.jobs.send(Job::SetEnabled(on));
        }
        fn capture(&mut self, bus_name: &str, flash: bool) {
            let _ = self.jobs.send(Job::Capture(bus_name.to_owned(), flash));
        }
        fn replies(&mut self) -> Vec<Reply> {
            std::mem::take(&mut *self.replies.lock().unwrap_or_else(|e| e.into_inner()))
        }
    }

    fn connect() -> Option<Connection> {
        zbus::blocking::connection::Builder::session()
            .ok()?
            .method_timeout(TIMEOUT)
            .build()
            .ok()
    }

    fn failure(error: &zbus::Error) -> String {
        const ABSENT: [&str; 5] = [
            "org.freedesktop.DBus.Error.ServiceUnknown",
            "org.freedesktop.DBus.Error.NoReply",
            "org.freedesktop.DBus.Error.Timeout",
            "org.freedesktop.DBus.Error.TimedOut",
            "org.freedesktop.DBus.Error.Disconnected",
        ];
        match error {
            zbus::Error::MethodError(name, Some(message), _)
                if !ABSENT.contains(&name.as_str()) && !message.is_empty() =>
            {
                message.clone()
            }
            _ => SILENT.into(),
        }
    }

    type Map = HashMap<String, OwnedValue>;

    fn call<B>(
        bus: &Connection,
        dest: &str,
        path: &str,
        iface: &str,
        member: &str,
        body: &B,
    ) -> zbus::Result<zbus::Message>
    where
        B: serde::Serialize + zbus::zvariant::DynamicType,
    {
        bus.call_method(Some(dest), path, Some(iface), member, body)
    }

    fn properties(bus: &Connection, dest: &str, path: &str, iface: &str) -> zbus::Result<Map> {
        call(bus, dest, path, PROPERTIES, "GetAll", &(iface,))?
            .body()
            .deserialize::<Map>()
    }

    fn number(value: &Value<'_>) -> Option<f64> {
        Some(match value {
            Value::F64(n) => *n,
            Value::I32(n) => f64::from(*n),
            Value::U32(n) => f64::from(*n),
            Value::I16(n) => f64::from(*n),
            Value::U16(n) => f64::from(*n),
            Value::U8(n) => f64::from(*n),
            Value::I64(n) => *n as f64,
            Value::U64(n) => *n as f64,
            _ => return None,
        })
    }

    fn inspect(bus: Option<&Connection>) -> Extension {
        let mut extension = Extension::default();
        let Some(bus) = bus else {
            extension.failure = SILENT.into();
            return extension;
        };
        let shell = match properties(bus, SHELL, SHELL_PATH, EXTENSIONS) {
            Ok(shell) => shell,
            Err(error) => {
                extension.failure = failure(&error);
                return extension;
            }
        };
        if let Some(Value::Str(version)) = shell.get("ShellVersion").map(|v| &**v) {
            extension.shell_version = version.to_string();
        }
        extension.user_extensions_enabled = matches!(
            shell.get("UserExtensionsEnabled").map(|v| &**v),
            Some(Value::Bool(true))
        );
        let found = match call(
            bus,
            SHELL,
            SHELL_PATH,
            EXTENSIONS,
            "GetExtensionInfo",
            &(UUID,),
        )
        .and_then(|reply| reply.body().deserialize::<Map>())
        {
            Ok(found) => found,
            Err(error) => {
                extension.failure = failure(&error);
                return extension;
            }
        };
        extension.state = found.get("state").and_then(|v| number(v)).map(|n| n as i32);
        extension.version = found.get("version").and_then(|v| number(v));
        if let Some(Value::Str(error)) = found.get("error").map(|v| &**v) {
            extension.error = error.to_string();
        }
        // Not answering is an answer: the extension is not running.
        if let Ok(service) = properties(bus, SERVICE, SERVICE_PATH, SERVICE) {
            extension.service = service
                .get("Version")
                .and_then(|v| number(v))
                .map_or(0, |n| n as i32);
        }
        extension
    }

    fn set_enabled(bus: Option<&Connection>, on: bool) -> String {
        let Some(bus) = bus else {
            return SILENT.into();
        };
        let member = if on {
            "EnableExtension"
        } else {
            "DisableExtension"
        };
        match call(bus, SHELL, SHELL_PATH, EXTENSIONS, member, &(UUID,))
            .and_then(|reply| reply.body().deserialize::<bool>())
        {
            Err(error) => failure(&error),
            Ok(false) => {
                "GNOME has not loaded the extension. Sign out and back in, then try again.".into()
            }
            Ok(true) => String::new(),
        }
    }

    /// A connection of its own: the extension trusts the owner of
    /// `bus_name`, and the name goes when the connection does. The
    /// connection comes back to be held while the flash shows.
    fn capture(bus_name: &str, flash: bool) -> (Capture, Option<Connection>) {
        let mut capture = Capture::default();
        let owned = connect().filter(|bus| {
            matches!(
                bus.request_name_with_flags(bus_name, RequestNameFlags::DoNotQueue.into()),
                Ok(RequestNameReply::PrimaryOwner)
            )
        });
        let Some(bus) = owned else {
            capture.error = "Another HAL-C2 instance is capturing a window. Try again.".into();
            return (capture, None);
        };
        let reply = if flash {
            call(
                &bus,
                SERVICE,
                SERVICE_PATH,
                SERVICE,
                "CaptureWithFeedback",
                &(true, false),
            )
        } else {
            call(&bus, SERVICE, SERVICE_PATH, SERVICE, "Capture", &())
        };
        match reply.and_then(|reply| reply.body().deserialize::<(Vec<u8>, String)>()) {
            Ok((png, metadata)) => {
                capture.png = png;
                capture.metadata = metadata;
            }
            Err(zbus::Error::MethodError(_, Some(message), _)) if !message.is_empty() => {
                capture.error = message
            }
            Err(_) => capture.error = "Invalid extension screenshot.".into(),
        }
        (capture, Some(bus))
    }
}
