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

#[cfg(all(unix, not(target_os = "macos")))]
pub mod portal;
mod sound;

use std::io::Cursor;
use std::path::PathBuf;

use image::codecs::jpeg::JpegEncoder;
use image::imageops::{self, FilterType};
use image::{ExtendedColorType, ImageFormat, RgbaImage};

use crate::json::Json;

pub use sound::play as play_sound;

/// Where capture is: through the portal, or not at all.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    Portal,
    #[default]
    Unavailable,
}

impl Mode {
    /// As the panel's state names it.
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Portal => "portal",
            Mode::Unavailable => "unavailable",
        }
    }
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
    /// Plays a capture sound: `soft-pop` (Whoosh) or `camera-shutter`
    /// (Click).
    fn play(&mut self, _sound: &str) {}
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

/// The backend this process gets: the portal where the session has one,
/// else the reason it cannot capture. `wake` runs on any thread when
/// [`Backend::arrive`] has something to do (main.rs posts a message to the
/// Engine thread, which calls [`SnapShot::arrive`](crate::controllers::snap_shot::SnapShot::arrive));
/// `cache_dir` is where the capture sounds are unpacked for the player.
pub fn system(
    cache_dir: Option<PathBuf>,
    wake: impl Fn() + Send + Sync + 'static,
) -> Box<dyn Backend> {
    let on_linux = cfg!(target_os = "linux");
    let platform = detect(&|name| std::env::var(name).ok(), on_linux);
    // TODO(port): SnapShotBackend::create: X11, macOS and Windows capture
    // through the native/ helpers; desktop-qt runs none of them either
    // (features/source-control/snap-shot.feature, @backlog-desktop).
    if !platform.portal {
        return Box::new(Unavailable::new(platform.message));
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        Box::new(portal::Portal::system(&platform, cache_dir, wake))
    }
    #[cfg(not(all(unix, not(target_os = "macos"))))]
    {
        let _ = (cache_dir, wake);
        Box::new(Unavailable::new(
            "SnapShots are not supported on this platform.",
        ))
    }
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
