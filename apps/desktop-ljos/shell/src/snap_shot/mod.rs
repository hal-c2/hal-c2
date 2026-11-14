//! The platform half of Snap Shot
//! ([`SnapShot`](crate::controllers::snap_shot::SnapShot)), desktop-qt's
//! SnapShotBackend: whether this session can capture, the global capture
//! shortcut, and the capture itself.
//!
//! Linux Wayland captures through xdg-desktop-portal ([`portal`]): the
//! Screenshot portal's active-window target where the desktop offers it,
//! else its window picker, and the GlobalShortcuts portal for the shortcut.
//! X11, macOS and Windows are unavailable for now ([`Unavailable`]).
//!
//! A backend answers from what it has already found out: its session is not
//! ready until `probe` has asked the desktop, and `bind` leaves the shortcut
//! pending until the desktop answers. It lives on the Engine thread; what
//! its own threads learn waits until [`Backend::arrive`], and each call says
//! what changed as [`Event`]s.
//!
//! The native capture helpers under `native/` (the SnapShot capture helpers
//! of features/source-control/snap-shot.feature) stay `@backlog-desktop`:
//! desktop-qt does not run them either, only the portal.

pub mod config;
pub mod gnome;
pub mod helper;
pub mod mac;
pub mod niri;
#[cfg(all(unix, not(target_os = "macos")))]
pub mod portal;
mod sound;
pub mod windows;

use std::cell::RefCell;
use std::collections::HashMap;
use std::io::Cursor;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use image::codecs::jpeg::JpegEncoder;
use image::imageops::{self, FilterType};
use image::{ExtendedColorType, ImageFormat, RgbaImage};

pub use crate::json::Json;

pub use sound::play as play_sound;

/// Where capture is: through the portal, directly (macOS, Windows), or not at all.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    Portal,
    Direct,
    #[default]
    Unavailable,
}

impl Mode {
    /// As the panel's state names it.
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Portal => "portal",
            Mode::Direct => "direct",
            Mode::Unavailable => "unavailable",
        }
    }
}

/// What macOS allows this app.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Permissions {
    pub screen_recording: bool,
    pub accessibility: bool,
}

/// What this session can do, as far as the desktop has been asked.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Session {
    /// The desktop has been asked; until then nothing else here is known.
    pub ready: bool,
    pub mode: Mode,
    /// A portal's: `screenshot-portal` (the window in front) or `picker`
    /// (the user chooses a window each time); empty before it is known.
    pub backend: String,
    /// `gnome`, `kde`, `hyprland` or `niri` (XDG_CURRENT_DESKTOP), else empty.
    pub desktop: String,
    /// Why capture is unavailable or needs attention; empty when neither.
    pub message: String,
    /// The desktop can flash the captured window and animate it (never yet).
    pub feedback_available: bool,
    /// Capture needs no setup (Windows): turning it on is enough.
    pub setup_free: bool,
    /// Captures can carry the app's text and controls; otherwise only an image.
    pub app_text: bool,
    /// The desktop is being asked again (`refresh`) and has not answered.
    pub checking: bool,
    /// Where capture needs privacy permissions the user grants one at a
    /// time (macOS), what is allowed; a failed check keeps the last
    /// answer and says so in `permissions_error`.
    pub permissions: Option<Permissions>,
    pub permissions_error: String,
}

/// Whether a shortcut can be the capture shortcut, and what to tell the user.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Check {
    pub available: bool,
    pub message: String,
}

/// A desktop whose capture has to be set up first (GNOME's extension, a
/// capture helper): what the access step says and offers. The
/// controller shows it as given; only `perform` changes anything.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Setup {
    /// Capture works and setup can go on to the shortcut.
    pub access_ready: bool,
    pub heading: String,
    pub body: String,
    /// The access step's button: a `perform` action, or empty to check
    /// again (or continue, once ready) with `action_label`.
    pub action: String,
    pub action_label: String,
    /// What the desktop said, when it explains a failure.
    pub details: String,
    /// What to say after the user checked again.
    pub check_message: String,
    /// The capture row while capture is on and access is not ready.
    pub status: String,
    /// Why capture effects are off; empty to leave it to `feedback_available`.
    pub effects: String,
    /// Advanced: undoing what setup did, and the like.
    pub advanced: Vec<SetupOption>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SetupOption {
    pub action: String,
    pub label: String,
    pub note: String,
}

/// The capture shortcut as the desktop holds it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Shortcut {
    pub registered: bool,
    /// Waiting on the desktop's permission prompt.
    pub pending: bool,
    /// What the desktop says the shortcut is, when it says.
    pub label: String,
    pub message: String,
    /// The desktop can be asked to show its shortcut permissions again.
    pub can_retry: bool,
}

impl Default for Shortcut {
    fn default() -> Shortcut {
        Shortcut {
            registered: false,
            pending: false,
            label: String::new(),
            message: String::new(),
            can_retry: true,
        }
    }
}

/// A window the desktop captured; the portal names neither its app nor its
/// title.
#[derive(Debug)]
pub struct Captured {
    pub image: RgbaImage,
    pub app_name: String,
    pub window_title: String,
    /// What the attachment's source says of the app's text
    /// ({accessibleText, accessibility}), when the backend could read it.
    pub context: Json,
}

/// What a backend call or arrival changed.
#[derive(Debug)]
pub enum Event {
    /// The session or the shortcut changed.
    Changed,
    /// The capture shortcut was pressed.
    Activated,
    Captured(Captured),
    Failed(String),
    /// A setup step failed; shown in setup, not as a toast.
    SetupFailed(String),
    /// A test capture finished: why it failed, or empty.
    Tested(String),
    /// A shortcut check answered (direct backends answer at once).
    Checked(Check),
    /// Call [`Backend::timeout`] with `token` in `ms`.
    After {
        token: u64,
        ms: u64,
    },
    /// The time asked for by `token` is no longer needed.
    Cancel(u64),
}

pub trait Backend {
    fn session(&self) -> Session;
    fn shortcut(&self) -> Shortcut {
        Shortcut::default()
    }
    /// Asks the desktop what it offers; idempotent.
    fn probe(&mut self) -> Vec<Event> {
        Vec::new()
    }
    /// Binds the capture shortcut to `trigger` ([`portal_trigger`]'s),
    /// replacing the one before; pending until the desktop answers.
    fn bind(&mut self, _trigger: &str) -> Vec<Event> {
        Vec::new()
    }
    /// Lets the capture shortcut go.
    fn release(&mut self) -> Vec<Event> {
        Vec::new()
    }
    /// Shows the desktop's shortcut permissions again.
    fn configure(&mut self) -> Vec<Event> {
        Vec::new()
    }
    /// Captures (or has the user pick) a window: [`Event::Captured`] or
    /// [`Event::Failed`] follows.
    fn capture(&mut self) -> Vec<Event> {
        Vec::new()
    }
    /// Asks again after the user may have changed what the desktop allows.
    fn refresh(&mut self) -> Vec<Event> {
        self.probe()
    }
    /// What `bind` takes for `shortcut`: [`portal_trigger`]'s for a
    /// portal, the shortcut's JSON in direct mode; the reason when this
    /// desktop cannot hold it.
    fn trigger(&self, shortcut: &Json) -> Result<String, String> {
        if self.session().mode == Mode::Direct {
            Ok(serde_json::to_string(shortcut).unwrap_or_default())
        } else {
            portal_trigger(shortcut)
        }
    }
    /// The capture cues the user chose (snapShotFlash, snapShotAnimations).
    fn set_cues(&mut self, _flash: bool, _animations: bool) {}
    /// Whether `shortcut` can be held here: the answer, or none while
    /// the desktop is asked ([`Event::Checked`] follows). Unavailable
    /// with no message is a check that failed; a message on an
    /// available shortcut in direct mode is shown (it may only be
    /// observed). A portal names the shortcut's keys and confirms it
    /// only when it is bound.
    fn check_shortcut(&mut self, shortcut: &Json) -> Option<Check> {
        if self.session().mode != Mode::Portal {
            return Some(Check {
                available: false,
                message: "SnapShots are not supported on this platform.".into(),
            });
        }
        match portal_trigger(shortcut) {
            Err(problem) => Some(Check {
                available: false,
                message: problem,
            }),
            Ok(_) => Some(Check {
                available: true,
                message: "Your desktop will confirm this shortcut when you save it.".into(),
            }),
        }
    }
    /// Pauses the capture shortcut while a new one is recorded, or ends
    /// the pause; the desktop's reason when it could not. The
    /// controller ignores the shortcut while it records, so a backend
    /// only acts when it must let the OS go.
    fn pause(&mut self, _paused: bool) -> Result<(), String> {
        Ok(())
    }
    /// The permissions below are for a backend whose session has them.
    /// Captures include the app's text, which needs Accessibility too.
    fn set_include_accessibility(&mut self, _include: bool) {}
    /// Checks the permissions again and again while setup shows them.
    fn watch_permissions(&mut self, _on: bool) {}
    /// One permission's Allow (screen-recording | accessibility).
    fn allow(&mut self, _permission: &str) {}
    /// Asks for what capture needs; why it still cannot, or empty.
    fn request_permissions(&mut self, _include_accessibility: bool) -> String {
        String::new()
    }
    /// A capture that is thrown away, to prove capture works.
    fn test(&mut self) -> Vec<Event> {
        vec![Event::Tested(String::new())]
    }
    /// Plays a capture sound: `soft-pop` (Whoosh) or `camera-shutter`
    /// (Click).
    fn play(&mut self, _sound: &str) {}
    /// The capture effects the user wants, for a desktop that can show them.
    fn set_effects(&mut self, _flash: bool, _animate: bool) {}
    /// The setup this desktop needs before it captures; none by default.
    fn setup(&self) -> Option<Setup> {
        None
    }
    /// Runs a setup step the user chose (install-extension,
    /// remove-kde-helper, ...). A step this desktop does not have is
    /// refused and changes nothing.
    fn perform(&mut self, action: &str) -> Vec<Event> {
        vec![Event::SetupFailed(unsupported_setup(action))]
    }
    /// What the backend's own threads left, handed over on the Engine
    /// thread ([`SnapShot::arrive`](crate::controllers::snap_shot::SnapShot::arrive)).
    fn arrive(&mut self) -> Vec<Event> {
        Vec::new()
    }
    /// The time an [`Event::After`] asked for has passed.
    fn timeout(&mut self, _token: u64) -> Vec<Event> {
        Vec::new()
    }
}

/// Where capture is not supported: only the reason.
pub struct Unavailable {
    message: String,
}

impl Unavailable {
    pub fn new(message: impl Into<String>) -> Unavailable {
        Unavailable {
            message: message.into(),
        }
    }
}

impl Backend for Unavailable {
    fn session(&self) -> Session {
        Session {
            ready: true,
            message: self.message.clone(),
            ..Session::default()
        }
    }
}

/// Where a process with environment `env` captures: through the portal, and
/// on which desktop, or not at all and why.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Platform {
    pub portal: bool,
    pub desktop: String,
    pub message: String,
    /// Flatpak or Snap: the portal knows the app already.
    pub sandboxed: bool,
}

/// The platform of a process whose environment `env` reads; `on_linux` is
/// whether it runs on Linux (a test's stand-in environment is a Linux
/// desktop's on any platform).
pub fn detect(env: &dyn Fn(&str) -> Option<String>, on_linux: bool) -> Platform {
    let refused = |message: &str| Platform {
        message: message.to_owned(),
        ..Platform::default()
    };
    if !on_linux {
        return refused("SnapShots are not supported on this platform.");
    }
    let kind = env("XDG_SESSION_TYPE").unwrap_or_default().to_lowercase();
    let wayland = match kind.as_str() {
        "x11" => false,
        "wayland" => true,
        _ => !env("WAYLAND_DISPLAY").unwrap_or_default().is_empty(),
    };
    if !wayland {
        return refused("SnapShots require a Wayland session. X11 capture is not supported.");
    }
    let mut platform = Platform {
        portal: true,
        sandboxed: env("FLATPAK_ID").is_some() || env("SNAP").is_some(),
        ..Platform::default()
    };
    // A sandbox's desktop is the portal's business.
    if !platform.sandboxed {
        let desktops = env("XDG_CURRENT_DESKTOP").unwrap_or_default();
        platform.desktop = desktops
            .split(':')
            .filter(|name| !name.is_empty())
            .map(str::to_lowercase)
            .find(|name| matches!(name.as_str(), "gnome" | "kde" | "hyprland" | "niri"))
            .unwrap_or_default();
    }
    platform
}

/// What a test gives instead of the portal on the session bus.
pub type PortalFactory = Rc<dyn Fn(&Platform) -> Box<dyn Backend>>;

thread_local! {
    static ENVIRONMENT: RefCell<Option<HashMap<String, String>>> = const { RefCell::new(None) };
    static WAKE: RefCell<Option<Arc<dyn Fn() + Send + Sync>>> = const { RefCell::new(None) };
    static PORTAL_FACTORY: RefCell<Option<PortalFactory>> = const { RefCell::new(None) };
}

/// Tests stand in for the portal on the session bus; `None` restores it.
/// A stand-in portal never reaches the real GNOME Shell either.
pub fn set_portal_factory(factory: Option<PortalFactory>) {
    PORTAL_FACTORY.with(|held| *held.borrow_mut() = factory);
}

/// Whether a test stands in for the portal.
pub fn portal_overridden() -> bool {
    PORTAL_FACTORY.with(|held| held.borrow().is_some())
}

/// Tests stand in for the process environment (a Linux desktop's, on any
/// platform, or Windows' when it has OS=Windows_NT); `None` restores it.
pub fn set_environment(env: Option<HashMap<String, String>>) {
    ENVIRONMENT.with(|held| *held.borrow_mut() = env);
}

/// A variable of the process environment, or of the tests' stand-in.
pub fn env_var(name: &str) -> Option<String> {
    ENVIRONMENT.with(|held| match &*held.borrow() {
        Some(env) => env.get(name).cloned(),
        None => std::env::var(name).ok(),
    })
}

/// Whether the environment is a test's stand-in.
pub fn environment_overridden() -> bool {
    ENVIRONMENT.with(|held| held.borrow().is_some())
}

/// What wakes the Engine thread for work a thread finished (main.rs's,
/// given to [`system`]); none in tests, which wait on the work instead.
pub fn wake() -> Option<Arc<dyn Fn() + Send + Sync>> {
    WAKE.with(|held| held.borrow().clone())
}

/// The backend this process gets: the portal where the session has one,
/// else the reason it cannot capture. `wake` runs on any thread when
/// [`Backend::arrive`] has something to do (main.rs posts a message to the
/// Engine thread, which calls [`SnapShot::arrive`](crate::controllers::snap_shot::SnapShot::arrive));
/// `cache_dir` is where the capture sounds are unpacked for the player.
pub fn system(
    cache_dir: Option<PathBuf>,
    wake: impl Fn() + Send + Sync + 'static,
) -> Box<dyn Backend> {
    let wake: Arc<dyn Fn() + Send + Sync> = Arc::new(wake);
    WAKE.with(|held| *held.borrow_mut() = Some(wake));
    create(cache_dir)
}

/// SnapShotBackend::create: the backend of the environment [`env_var`]
/// reads (a test's stand-in, or the process's). Windows and macOS capture
/// directly; Niri through its own socket; KDE and Hyprland through the
/// capture helper with the portal's shortcut; GNOME through its extension
/// beside the portal; any other Wayland desktop through the portal.
pub fn create(cache_dir: Option<PathBuf>) -> Box<dyn Backend> {
    if let Some(backend) = windows::create() {
        return backend;
    }
    if let Some(backend) = mac::create() {
        return backend;
    }
    // A test's stand-in environment is a Linux desktop's.
    let on_linux = cfg!(target_os = "linux") || environment_overridden();
    let platform = detect(&|name| env_var(name), on_linux);
    if !platform.portal {
        return Box::new(Unavailable::new(platform.message));
    }
    if platform.desktop == "niri"
        && let Some(backend) = niri::create(&platform)
    {
        return backend;
    }
    let portal = || -> Option<Box<dyn Backend>> {
        if let Some(factory) = PORTAL_FACTORY.with(|held| held.borrow().clone()) {
            return Some(factory(&platform));
        }
        system_portal(&platform, cache_dir.clone())
    };
    if matches!(platform.desktop.as_str(), "kde" | "hyprland")
        && let Some(shortcuts) = portal()
    {
        return helper::create(&platform, shortcuts);
    }
    let Some(fallback) = portal() else {
        return Box::new(Unavailable::new(
            "SnapShots are not supported on this platform.",
        ));
    };
    if platform.desktop != "gnome" {
        return fallback;
    }
    gnome::create(fallback)
}

/// The portal on the session bus, where there is one.
#[cfg(all(unix, not(target_os = "macos")))]
fn system_portal(platform: &Platform, cache_dir: Option<PathBuf>) -> Option<Box<dyn Backend>> {
    let wake = wake();
    Some(Box::new(portal::Portal::system(
        platform,
        cache_dir,
        move || {
            if let Some(wake) = &wake {
                wake();
            }
        },
    )))
}

#[cfg(not(all(unix, not(target_os = "macos"))))]
fn system_portal(_platform: &Platform, _cache_dir: Option<PathBuf>) -> Option<Box<dyn Backend>> {
    None
}

/// X keysym names for the keys a chord may name.
fn keysym(key: &str) -> Option<String> {
    let named = match key {
        " " | "space" => "space",
        "escape" | "esc" => "Escape",
        "enter" => "Return",
        "tab" => "Tab",
        "backspace" => "BackSpace",
        "delete" => "Delete",
        "insert" => "Insert",
        "home" => "Home",
        "end" => "End",
        "pageup" => "Page_Up",
        "pagedown" => "Page_Down",
        "arrowup" | "up" => "Up",
        "arrowdown" | "down" => "Down",
        "arrowleft" | "left" => "Left",
        "arrowright" | "right" => "Right",
        "+" => "plus",
        "-" => "minus",
        "=" => "equal",
        "," => "comma",
        "." => "period",
        "/" => "slash",
        ";" => "semicolon",
        "'" => "apostrophe",
        "[" => "bracketleft",
        "]" => "bracketright",
        "\\" => "backslash",
        "`" => "grave",
        "!" => "exclam",
        "@" => "at",
        "#" => "numbersign",
        "$" => "dollar",
        "%" => "percent",
        "^" => "asciicircum",
        "&" => "ampersand",
        "*" => "asterisk",
        "(" => "parenleft",
        ")" => "parenright",
        "_" => "underscore",
        ":" => "colon",
        "\"" => "quotedbl",
        "{" => "braceleft",
        "}" => "braceright",
        "|" => "bar",
        "<" => "less",
        ">" => "greater",
        "?" => "question",
        "~" => "asciitilde",
        _ => "",
    };
    if !named.is_empty() {
        return Some(named.to_owned());
    }
    let plain = key.len() == 1
        && key
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    let function = key.strip_prefix('f').is_some_and(|n| {
        !n.starts_with('0')
            && n.len() <= 2
            && n.chars().all(|c| c.is_ascii_digit())
            && n.parse::<u8>().is_ok_and(|n| (1..=24).contains(&n))
    });
    (plain || function).then(|| key.to_uppercase())
}

/// The portal's trigger for a key chord ({key, metaKey, ctrlKey, shiftKey,
/// altKey, modKey}), "CTRL+SHIFT+2"; the reason when the portal cannot take
/// it (a modifier pair, or a key it has no name for).
/// Why a setup step this session does not have was refused
/// (DesktopSnapShotSetupError's unsupported-session messages).
pub fn unsupported_setup(action: &str) -> String {
    match action {
        "install-kde-helper" | "remove-kde-helper" => {
            "Helper setup requires a KDE Plasma Wayland session outside a sandbox."
        }
        "install-hyprland-helper" | "remove-hyprland-helper" => {
            "Helper setup requires a Hyprland Wayland session outside a sandbox."
        }
        "test-mac-capture" => "Test capture requires macOS.",
        "allow-screen-recording" | "allow-accessibility" => "Permission setup requires macOS.",
        "preview-config" | "apply-config" => "Config setup requires a Niri or Hyprland session.",
        "install-extension" | "enable-extension" | "disable-extension" => {
            "Extension setup requires a GNOME Wayland session outside a sandbox."
        }
        _ => "This setup step is not available in this session.",
    }
    .to_owned()
}

pub fn portal_trigger(shortcut: &Json) -> Result<String, String> {
    if shortcut.get("kind").is_some() {
        return Err(
            "Modifier-pair shortcuts aren't available in this Wayland session. \
                    Choose another shortcut or use Take snapshot from the command palette."
                .into(),
        );
    }
    let key = shortcut
        .get("key")
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_lowercase();
    let Some(keysym) = keysym(&key) else {
        return Err(
            "This key isn't supported as a Wayland capture shortcut. Choose another key.".into(),
        );
    };
    let on = |name: &str| {
        shortcut
            .get(name)
            .and_then(Json::as_bool)
            .unwrap_or_default()
    };
    let mut parts = Vec::new();
    if on("ctrlKey") || on("modKey") {
        parts.push("CTRL".to_owned());
    }
    if on("altKey") {
        parts.push("ALT".to_owned());
    }
    if on("shiftKey") {
        parts.push("SHIFT".to_owned());
    }
    if on("metaKey") {
        parts.push("LOGO".to_owned());
    }
    parts.push(keysym);
    Ok(parts.join("+"))
}

/// An image within `max_bytes`: the PNG as it is, else JPEG at falling
/// quality and size; none when nothing fits. The second is the MIME type.
pub fn encode(image: &RgbaImage, max_bytes: u64) -> Option<(Vec<u8>, &'static str)> {
    let mut png = Cursor::new(Vec::new());
    if image.write_to(&mut png, ImageFormat::Png).is_ok() {
        let png = png.into_inner();
        if !png.is_empty() && png.len() as u64 <= max_bytes {
            return Some((png, "image/png"));
        }
    }
    // A data URL's budget, in bytes.
    let budget = max_bytes / 3 * 3;
    let opaque = image::DynamicImage::ImageRgba8(image.clone()).to_rgb8();
    let (width, height) = opaque.dimensions();
    let base = width.max(height);
    for scale in [1.0, 0.75, 0.55] {
        let dimension = ((f64::from(base) * scale).round() as u32).max(1);
        let scaled = if dimension >= base {
            opaque.clone()
        } else {
            let factor = f64::from(dimension) / f64::from(base);
            let fit = |side: u32| ((f64::from(side) * factor).round() as u32).max(1);
            imageops::resize(&opaque, fit(width), fit(height), FilterType::Triangle)
        };
        for quality in [92, 85, 78, 68] {
            let mut jpeg = Vec::new();
            let encoded = JpegEncoder::new_with_quality(&mut jpeg, quality).encode(
                scaled.as_raw(),
                scaled.width(),
                scaled.height(),
                ExtendedColorType::Rgb8,
            );
            if encoded.is_ok() && !jpeg.is_empty() && jpeg.len() as u64 <= budget {
                return Some((jpeg, "image/jpeg"));
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::HashMap;

    fn env<'a>(vars: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        let map: HashMap<_, _> = vars.iter().copied().collect();
        move |name| map.get(name).map(|v| (*v).to_owned())
    }

    #[test]
    fn a_wayland_session_captures_through_the_portal() {
        let vars = [
            ("XDG_SESSION_TYPE", "wayland"),
            ("XDG_CURRENT_DESKTOP", "ubuntu:GNOME"),
        ];
        let platform = detect(&env(&vars), true);
        assert!(platform.portal);
        assert_eq!(platform.desktop, "gnome");
        assert!(!platform.sandboxed);
        // Without a session type, the display decides.
        let platform = detect(&env(&[("WAYLAND_DISPLAY", "wayland-1")]), true);
        assert!(platform.portal);
        assert_eq!(platform.desktop, "");
    }

    #[test]
    fn a_sandbox_leaves_the_desktop_to_the_portal() {
        let vars = [
            ("XDG_SESSION_TYPE", "wayland"),
            ("XDG_CURRENT_DESKTOP", "KDE"),
            ("FLATPAK_ID", "app.hal_c2"),
        ];
        let platform = detect(&env(&vars), true);
        assert!(platform.sandboxed);
        assert_eq!(platform.desktop, "");
    }

    #[test]
    fn x11_and_other_systems_say_why_not() {
        let x11 = detect(&env(&[("XDG_SESSION_TYPE", "x11")]), true);
        assert!(!x11.portal);
        assert_eq!(
            x11.message,
            "SnapShots require a Wayland session. X11 capture is not supported."
        );
        let other = detect(&env(&[("XDG_SESSION_TYPE", "wayland")]), false);
        assert!(!other.portal);
        assert_eq!(
            other.message,
            "SnapShots are not supported on this platform."
        );
    }

    fn chord(key: &str, modifiers: &[&str]) -> Json {
        let on = |name: &str| modifiers.contains(&name);
        json!({"key": key, "metaKey": on("meta"), "ctrlKey": on("ctrl"),
            "shiftKey": on("shift"), "altKey": on("alt"), "modKey": on("mod")})
    }

    #[test]
    fn a_chord_becomes_the_portals_trigger() {
        assert_eq!(
            portal_trigger(&chord("2", &["mod", "shift"])).unwrap(),
            "CTRL+SHIFT+2"
        );
        assert_eq!(
            portal_trigger(&chord("F12", &["alt", "meta"])).unwrap(),
            "ALT+LOGO+F12"
        );
        assert_eq!(
            portal_trigger(&chord(" ", &["ctrl"])).unwrap(),
            "CTRL+space"
        );
        assert_eq!(
            portal_trigger(&chord("[", &["ctrl"])).unwrap(),
            "CTRL+bracketleft"
        );
        assert_eq!(portal_trigger(&chord("a", &[])).unwrap(), "A");
    }

    #[test]
    fn what_the_portal_cannot_take_is_refused_with_a_reason() {
        let pair = portal_trigger(&json!({"kind": "both-shift-keys"})).unwrap_err();
        assert!(pair.starts_with("Modifier-pair shortcuts aren't available"));
        let key = portal_trigger(&chord("é", &["ctrl"])).unwrap_err();
        assert!(key.starts_with("This key isn't supported"));
        assert!(portal_trigger(&chord("f0", &["ctrl"])).is_err());
        assert!(portal_trigger(&chord("f25", &["ctrl"])).is_err());
        assert!(portal_trigger(&json!({})).is_err());
    }

    fn picture(width: u32, height: u32) -> RgbaImage {
        // Noise, so that it does not compress away.
        let mut seed = 0x2545_f491_u32;
        RgbaImage::from_fn(width, height, |_, _| {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            image::Rgba(seed.to_le_bytes())
        })
    }

    #[test]
    fn a_small_picture_stays_a_png() {
        let (bytes, mime) = encode(&RgbaImage::new(8, 8), 10 * 1024 * 1024).unwrap();
        assert_eq!(mime, "image/png");
        assert_eq!(&bytes[1..4], b"PNG");
    }

    #[test]
    fn a_picture_over_the_limit_becomes_a_smaller_jpeg() {
        let image = picture(200, 200);
        let png = encode(&image, u64::MAX).unwrap().0.len() as u64;
        let (bytes, mime) = encode(&image, png / 2).unwrap();
        assert_eq!(mime, "image/jpeg");
        assert!(bytes.len() as u64 <= png / 2);
        assert_eq!(&bytes[..2], [0xff, 0xd8]);
    }

    #[test]
    fn a_picture_nothing_fits_is_none() {
        assert!(encode(&picture(64, 64), 16).is_none());
    }
}
