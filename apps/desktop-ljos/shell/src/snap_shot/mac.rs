//! macOS capture: desktop-qt's MacSnapShot over its MacPlatform, and the
//! MacPermissionHelper panel beside System Settings.
//!
//! [`MacSnapShot`] captures directly and holds the shortcut itself, once
//! macOS allows Screen Recording (and Accessibility, when captures carry the
//! app's text). [`MacPlatform`] is what it asks of macOS; what macOS says on
//! its own (the shortcut pressed, a capture done) is posted to an [`Inbox`]
//! and handed over in [`Backend::arrive`]. Tests stand in for the platform
//! with [`set_factory`].

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use image::RgbaImage;
use image::imageops::{self, FilterType};

use super::{Backend, Captured, Check, Event, Json, Mode, Permissions, Session, Shortcut};

pub const SCREEN_RECORDING: &str = "screen-recording";
pub const ACCESSIBILITY: &str = "accessibility";

const SCREEN_MESSAGE: &str = "Allow Screen Recording in System Settings, then restart HAL-C2.";
const ACCESSIBILITY_MESSAGE: &str = "Allow Accessibility in System Settings, then restart HAL-C2.";
const BOTH_MESSAGE: &str =
    "Allow Accessibility and Screen Recording in System Settings, then restart HAL-C2.";
const CHECK_FAILED: &str = "Could not check permissions. We'll try again automatically.";

/// The largest capture attached, either way round.
pub const MAX_WIDTH: u32 = 2560;
pub const MAX_HEIGHT: u32 = 1600;

/// How often permissions are read again while setup shows them.
const POLL_MS: u64 = 1500;
const HELPER_CHECK_MS: u64 = 1000;
const HELPER_TRACK_MS: u64 = 500;
const POLL: u64 = 1;
const HELPER_CHECK: u64 = 2;
const HELPER_TRACK: u64 = 3;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl Rect {
    pub fn new(x: i32, y: i32, width: i32, height: i32) -> Rect {
        Rect {
            x,
            y,
            width,
            height,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.width <= 0 || self.height <= 0
    }
}

/// What a capture of the front window gave: the image and where it came
/// from, or the step that failed (`find-window`, `capture-window`) and how
/// (`status`: `missing`, `timed-out`, `exited` with `exit_code`).
#[derive(Debug, Default)]
pub struct Capture {
    pub image: Option<RgbaImage>,
    pub app: String,
    pub title: String,
    pub step: String,
    pub status: String,
    pub exit_code: i32,
    /// {accessibleText, accessibility} when the app's text was read.
    pub context: Json,
}

impl Capture {
    pub fn ok(&self) -> bool {
        self.step.is_empty()
    }
}

/// System Settings' window, as the helper panel follows it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SettingsWindow {
    pub open: bool,
    pub frontmost: bool,
    pub bounds: Rect,
}

/// What macOS says on its own, from any thread.
#[derive(Debug)]
pub enum Signal {
    /// The capture shortcut was pressed.
    Pressed,
    /// macOS stopped letting the shortcut's keys through.
    WatchLost,
    /// The user closed the helper panel.
    HelperDismissed,
    /// The user asked the helper panel to show the app in Finder.
    HelperRevealRequested,
    /// A capture [`MacPlatform::capture`] left for later finished.
    Captured(Capture),
    /// The user may have changed a permission: read them again.
    Refresh,
    /// The helper's own checks, as its timers run them.
    CheckHelper,
    TrackHelper,
}

/// Where a platform posts its [`Signal`]s; it wakes the Engine thread.
#[derive(Clone)]
pub struct Inbox {
    signals: Arc<Mutex<Vec<Signal>>>,
    wake: Option<Arc<dyn Fn() + Send + Sync>>,
}

impl Inbox {
    fn new() -> Inbox {
        Inbox {
            signals: Arc::default(),
            wake: super::wake(),
        }
    }

    pub fn post(&self, signal: Signal) {
        if let Ok(mut signals) = self.signals.lock() {
            signals.push(signal);
        }
        if let Some(wake) = &self.wake {
            wake();
        }
    }

    fn take(&self) -> Vec<Signal> {
        self.signals
            .lock()
            .map(|mut signals| std::mem::take(&mut *signals))
            .unwrap_or_default()
    }
}

/// What MacSnapShot asks of macOS (MacPlatform.mm on a Mac).
pub trait MacPlatform {
    /// The name System Settings lists this app under.
    fn app_name(&self) -> String {
        "HAL-C2".into()
    }
    /// What macOS allows; none when it could not be asked.
    fn permissions(&mut self) -> Option<Permissions>;
    /// Asks macOS to prompt for `permission` (SCREEN_RECORDING, ACCESSIBILITY).
    fn request(&mut self, permission: &str);
    /// Opens System Settings at `permission`.
    fn open_settings(&mut self, permission: &str);
    /// Watches both keys of `modifier` (shift, control, alt, meta).
    fn watch_pair(&mut self, modifier: &str) -> bool;
    /// Holds a key chord ({key, metaKey, ...}) as a hot key.
    fn hold_chord(&mut self, shortcut: &Json) -> bool;
    /// Lets the watched pair or held chord go.
    fn let_go(&mut self);
    /// Captures the window in front: the capture now, or none when it
    /// arrives later as [`Signal::Captured`].
    fn capture(&mut self, include_text: bool) -> Option<Capture>;
    fn settings_window(&mut self) -> Option<SettingsWindow>;
    fn show_helper(&mut self, bounds: Rect, text: &str);
    fn hide_helper(&mut self);
    fn close_helper(&mut self);
    fn helper_focused(&mut self) -> bool;
    /// Shows the app in Finder, to be dragged into System Settings.
    fn reveal_app(&mut self);
    /// Brings HAL-C2 to the front.
    fn focus_app(&mut self);
    /// Plays a capture sound.
    fn play(&mut self, sound: &str) {
        super::play_sound(None, sound);
    }
}

/// What a test gives instead of macOS: the platform, posting to the inbox
/// it is handed; none once the test it stands in for is over.
pub type Factory = Rc<dyn Fn(Inbox) -> Option<Box<dyn MacPlatform>>>;

thread_local! {
    static FACTORY: RefCell<Option<Factory>> = const { RefCell::new(None) };
}

/// Tests stand in for macOS (MacPlatform::setFactory); `None` restores it.
pub fn set_factory(factory: Option<Factory>) {
    FACTORY.with(|held| *held.borrow_mut() = factory);
}

/// Whether a test stands in for macOS.
pub fn overridden() -> bool {
    FACTORY.with(|held| held.borrow().is_some())
}

/// MacSnapShot where a test stands in for a Mac, or on macOS.
pub fn create() -> Option<Box<dyn Backend>> {
    let inbox = Inbox::new();
    if let Some(factory) = FACTORY.with(|held| held.borrow().clone()) {
        let platform = factory(inbox.clone())?;
        return Some(Box::new(MacSnapShot::new(platform, inbox, false)));
    }
    let platform = native::platform(inbox.clone())?;
    Some(Box::new(MacSnapShot::new(platform, inbox, true)))
}

#[cfg(target_os = "macos")]
mod native {
    use super::{Inbox, MacPlatform};

    // TODO(port): MacPlatform.mm (TCC permissions, the CGEventTap pair
    // watch, the Carbon hot key, screencapture and the AX text read, the
    // helper NSPanel). Until then a Mac captures nothing.
    pub fn platform(_inbox: Inbox) -> Option<Box<dyn MacPlatform>> {
        None
    }
}

#[cfg(not(target_os = "macos"))]
mod native {
    use super::{Inbox, MacPlatform};

    pub fn platform(_inbox: Inbox) -> Option<Box<dyn MacPlatform>> {
        None
    }
}

/// `image` within `max_width` by `max_height`, its shape kept (Qt's
/// KeepAspectRatio): as it is when it fits.
pub fn fit(image: RgbaImage, max_width: u32, max_height: u32) -> RgbaImage {
    let (width, height) = image.dimensions();
    if width <= max_width && height <= max_height || width == 0 || height == 0 {
        return image;
    }
    let (w, h) = (u64::from(width), u64::from(height));
    let by_height = u64::from(max_height) * w / h;
    let (fit_width, fit_height) = if by_height <= u64::from(max_width) {
        (by_height, u64::from(max_height))
    } else {
        (u64::from(max_width), u64::from(max_width) * h / w)
    };
    imageops::resize(
        &image,
        (fit_width as u32).max(1),
        (fit_height as u32).max(1),
        FilterType::Triangle,
    )
}

fn is_pair(shortcut: &Json) -> bool {
    shortcut.get("kind").is_some()
}

fn pair_modifier(shortcut: &Json) -> String {
    match shortcut.get("kind").and_then(Json::as_str) {
        Some("both-shift-keys") => "shift".into(),
        _ => shortcut
            .get("modifier")
            .and_then(Json::as_str)
            .unwrap_or_default()
            .to_owned(),
    }
}

fn pair_label(shortcut: &Json) -> String {
    let modifier = pair_modifier(shortcut);
    let key = match modifier.as_str() {
        "shift" => "Shift",
        "control" => "Control",
        "alt" => "Option",
        "meta" => "Command",
        other => other,
    };
    format!("{key} + {key}")
}

fn observed_message(shortcut: &Json) -> String {
    format!(
        "{} is observed and cannot be reserved exclusively.",
        pair_label(shortcut)
    )
}

fn refused_message(shortcut: &Json) -> String {
    if is_pair(shortcut) {
        format!("{} is not available on this system.", pair_label(shortcut))
    } else {
        "This shortcut is already used by the system or another app.".into()
    }
}

/// Why a test capture failed, naming the step, how it failed and the app
/// the grants belong to.
fn capture_error(capture: &Capture, app_name: &str) -> String {
    let mut summary = "Could not capture a test snapshot.".to_owned();
    if capture.status == "missing" {
        summary.push_str(" No window is available to capture.");
    }
    let task = if capture.step == "find-window" {
        "Finding the front window"
    } else {
        "Capturing the window"
    };
    let failure = if capture.status == "timed-out" {
        format!("{task} timed out.")
    } else if capture.status == "exited" && capture.exit_code >= 0 {
        format!(
            "{task} failed: screencapture exited with code {}.",
            capture.exit_code
        )
    } else {
        format!("{task} failed.")
    };
    format!(
        "{summary} {failure} macOS grants Screen Recording and Accessibility to each app \
         separately. In System Settings, open Privacy & Security and check that \"{app_name}\" \
         is allowed for both."
    )
}

fn granted(permissions: Option<Permissions>, permission: &str) -> bool {
    let p = permissions.unwrap_or_default();
    if permission == SCREEN_RECORDING {
        p.screen_recording
    } else {
        p.accessibility
    }
}

/// The panel beside System Settings that says to drag HAL-C2 into its
/// list (MacPermissionHelper): it follows System Settings, hides while
/// another app is in front, and closes once the permission is granted or
/// System Settings closes.
#[derive(Default)]
pub struct Helper {
    permission: String,
    visible: bool,
    found: bool,
    bounds: Rect,
}

impl Helper {
    pub const TEXT: &'static str = "↑ Drag HAL-C2 into the list above";

    /// Where the panel goes: below System Settings' list, right of its sidebar.
    pub fn bounds_beside(settings: Rect) -> Rect {
        let sidebar = 216;
        let inset = 16;
        let height = 140;
        let width = 560.min(settings.width - sidebar - 2 * inset);
        let x = (f64::from(settings.x)
            + f64::from(sidebar)
            + f64::from(settings.width - sidebar - width) / 2.0)
            .round() as i32;
        let y = settings.y + settings.height - height - inset;
        Rect::new(x, y, width, height)
    }

    /// The permission the panel is open for; empty when closed.
    pub fn permission(&self) -> &str {
        &self.permission
    }

    pub fn open(&self) -> bool {
        !self.permission.is_empty()
    }
}

/// desktop-qt's MacSnapShot.
pub struct MacSnapShot {
    platform: Box<dyn MacPlatform>,
    inbox: Inbox,
    /// Its own timers run: polling and the helper's checks (a test drives
    /// those itself).
    timed: bool,
    probed: bool,
    permissions: Option<Permissions>,
    permissions_error: String,
    include: bool,
    message: String,
    /// The shortcut the controller asked to hold.
    asked: Option<Json>,
    holding: bool,
    shortcut: Shortcut,
    /// A capture macOS has not answered: a test capture's or a real one's.
    capturing: Option<bool>,
    watching: bool,
    helper: Helper,
    /// What calls without events of their own left for `arrive`.
    queued: Vec<Event>,
}

fn unheld() -> Shortcut {
    Shortcut {
        can_retry: false,
        ..Shortcut::default()
    }
}

impl MacSnapShot {
    pub fn new(platform: Box<dyn MacPlatform>, inbox: Inbox, timed: bool) -> MacSnapShot {
        MacSnapShot {
            platform,
            inbox,
            timed,
            probed: false,
            permissions: None,
            permissions_error: String::new(),
            include: false,
            message: String::new(),
            asked: None,
            holding: false,
            shortcut: unheld(),
            capturing: None,
            watching: false,
            helper: Helper::default(),
            queued: Vec::new(),
        }
    }

    pub fn helper(&self) -> &Helper {
        &self.helper
    }

    /// Something for `arrive` to hand over.
    fn queue(&mut self, events: impl IntoIterator<Item = Event>) {
        let before = self.queued.len();
        self.queued.extend(events);
        if self.queued.len() > before
            && let Some(wake) = &self.inbox.wake
        {
            wake();
        }
    }

    fn read(&mut self) {
        match self.platform.permissions() {
            None => self.permissions_error = CHECK_FAILED.into(),
            Some(permissions) => {
                self.permissions_error.clear();
                self.permissions = Some(permissions);
            }
        }
    }

    fn granted(&self, permission: &str) -> bool {
        granted(self.permissions, permission)
    }

    /// Why the shortcut cannot be held yet; empty when macOS allows it.
    fn permission_message(&self) -> &'static str {
        let screen = self.granted(SCREEN_RECORDING);
        let text = !self.include || self.granted(ACCESSIBILITY);
        match (screen, text) {
            (true, true) => "",
            (false, true) => SCREEN_MESSAGE,
            (true, false) => ACCESSIBILITY_MESSAGE,
            (false, false) => BOTH_MESSAGE,
        }
    }

    fn let_go(&mut self) {
        self.platform.let_go();
        self.holding = false;
    }

    /// Holds the asked shortcut when macOS allows it; `force` takes it
    /// again even when it is held.
    fn apply(&mut self, force: bool) {
        let Some(asked) = self.asked.clone() else {
            self.let_go();
            self.shortcut = unheld();
            self.message.clear();
            return;
        };
        self.message = self.permission_message().to_owned();
        if !self.message.is_empty() {
            self.let_go();
            self.shortcut = unheld();
            return;
        }
        if self.holding && !force {
            return;
        }
        self.let_go();
        let pair = is_pair(&asked);
        let held = if pair {
            self.platform.watch_pair(&pair_modifier(&asked))
        } else {
            self.platform.hold_chord(&asked)
        };
        self.holding = held;
        self.shortcut = Shortcut {
            registered: held,
            message: match (held, pair) {
                (true, true) => observed_message(&asked),
                (true, false) => String::new(),
                (false, _) => refused_message(&asked),
            },
            ..unheld()
        };
    }

    fn snapshot(&self) -> (Session, Shortcut) {
        (self.session(), self.shortcut.clone())
    }

    fn captured(&mut self, capture: Capture) -> Event {
        if !capture.ok() {
            return Event::Failed(if capture.status == "missing" {
                "No window is available to capture.".into()
            } else {
                "macOS could not capture the window.".into()
            });
        }
        let Some(image) = capture.image else {
            return Event::Failed("macOS returned an invalid snapshot.".into());
        };
        Event::Captured(Captured {
            image: fit(image, MAX_WIDTH, MAX_HEIGHT),
            app_name: capture.app,
            window_title: capture.title,
            context: capture.context,
        })
    }

    fn tested(&self, capture: &Capture) -> Event {
        // The test image is never kept.
        Event::Tested(if capture.ok() {
            String::new()
        } else {
            capture_error(capture, &self.platform.app_name())
        })
    }

    // --- The helper panel ---------------------------------------------------

    fn show_helper(&mut self, permission: &str) {
        self.close_helper();
        self.helper.permission = permission.to_owned();
        if self.granted(permission) {
            self.helper.permission.clear();
            return;
        }
        if self.timed {
            self.queue([
                Event::After {
                    token: HELPER_CHECK,
                    ms: HELPER_CHECK_MS,
                },
                Event::After {
                    token: HELPER_TRACK,
                    ms: HELPER_TRACK_MS,
                },
            ]);
        }
        self.track_helper();
    }

    fn close_helper(&mut self) {
        if self.timed && self.helper.open() {
            self.queue([Event::Cancel(HELPER_CHECK), Event::Cancel(HELPER_TRACK)]);
        }
        if self.helper.open() {
            self.platform.close_helper();
        }
        self.helper = Helper::default();
    }

    fn finish_helper(&mut self) {
        if self.helper.open() {
            self.close_helper();
            self.platform.focus_app();
        }
    }

    fn check_helper(&mut self) {
        if !self.helper.open() {
            return;
        }
        self.read();
        if self.granted(&self.helper.permission.clone()) {
            self.finish_helper();
        }
    }

    fn track_helper(&mut self) {
        if !self.helper.open() {
            return;
        }
        let Some(settings) = self.platform.settings_window() else {
            self.hide_helper();
            return;
        };
        if !settings.open {
            if self.helper.found {
                self.finish_helper();
            } else {
                self.hide_helper();
            }
            return;
        }
        self.helper.found = true;
        if !settings.frontmost && !self.platform.helper_focused() {
            self.hide_helper();
            return;
        }
        let bounds = Helper::bounds_beside(settings.bounds);
        if self.helper.visible && self.helper.bounds == bounds {
            return;
        }
        self.helper.bounds = bounds;
        self.helper.visible = true;
        self.platform.show_helper(bounds, Helper::TEXT);
    }

    fn hide_helper(&mut self) {
        if self.helper.visible {
            self.helper.visible = false;
            self.platform.hide_helper();
        }
    }

    fn signal(&mut self, signal: Signal) -> Vec<Event> {
        match signal {
            Signal::Pressed => vec![Event::Activated],
            Signal::WatchLost => {
                let Some(asked) = self.asked.clone() else {
                    return Vec::new();
                };
                self.holding = false;
                let message = refused_message(&asked);
                self.shortcut = Shortcut {
                    message: message.clone(),
                    ..unheld()
                };
                vec![Event::Failed(message), Event::Changed]
            }
            Signal::HelperDismissed => {
                self.finish_helper();
                Vec::new()
            }
            Signal::HelperRevealRequested => {
                self.platform.reveal_app();
                Vec::new()
            }
            Signal::Captured(capture) => match self.capturing.take() {
                Some(true) => vec![self.tested(&capture)],
                Some(false) => vec![self.captured(capture)],
                None => Vec::new(),
            },
            Signal::Refresh => self.refresh(),
            Signal::CheckHelper => {
                self.check_helper();
                Vec::new()
            }
            Signal::TrackHelper => {
                self.track_helper();
                Vec::new()
            }
        }
    }
}

impl Backend for MacSnapShot {
    fn session(&self) -> Session {
        Session {
            ready: self.probed,
            mode: Mode::Direct,
            app_text: true,
            message: self.message.clone(),
            permissions: self.probed.then(|| self.permissions.unwrap_or_default()),
            permissions_error: self.permissions_error.clone(),
            ..Session::default()
        }
    }

    fn shortcut(&self) -> Shortcut {
        self.shortcut.clone()
    }

    fn probe(&mut self) -> Vec<Event> {
        if self.probed {
            return Vec::new();
        }
        self.probed = true;
        self.read();
        self.apply(false);
        vec![Event::Changed]
    }

    fn refresh(&mut self) -> Vec<Event> {
        if !self.probed {
            return self.probe();
        }
        let before = self.snapshot();
        self.read();
        self.apply(false);
        if self.snapshot() != before {
            vec![Event::Changed]
        } else {
            Vec::new()
        }
    }

    fn bind(&mut self, trigger: &str) -> Vec<Event> {
        let shortcut: Json = serde_json::from_str(trigger).unwrap_or(Json::Null);
        if self.asked.as_ref() == Some(&shortcut) {
            return Vec::new();
        }
        self.asked = Some(shortcut);
        self.apply(true);
        vec![Event::Changed]
    }

    fn release(&mut self) -> Vec<Event> {
        self.asked = None;
        self.apply(false);
        vec![Event::Changed]
    }

    fn configure(&mut self) -> Vec<Event> {
        self.apply(true);
        vec![Event::Changed]
    }

    fn check_shortcut(&mut self, shortcut: &Json) -> Option<Check> {
        let was_holding = self.holding;
        self.let_go();
        let pair = is_pair(shortcut);
        let available = if pair {
            self.platform.watch_pair(&pair_modifier(shortcut))
        } else {
            self.platform.hold_chord(shortcut)
        };
        self.platform.let_go();
        if was_holding {
            self.apply(true);
        }
        Some(Check {
            available,
            message: match (available, pair) {
                (true, true) => observed_message(shortcut),
                (true, false) => String::new(),
                (false, _) => refused_message(shortcut),
            },
        })
    }

    fn set_include_accessibility(&mut self, include: bool) {
        self.include = include;
        if self.probed {
            self.apply(false);
            self.queue([Event::Changed]);
        }
    }

    fn watch_permissions(&mut self, on: bool) {
        if on == self.watching {
            return;
        }
        self.watching = on;
        if on {
            // What macOS allows now, before the first poll.
            let events = self.refresh();
            self.queue(events);
        }
        if self.timed {
            self.queue([if on {
                Event::After {
                    token: POLL,
                    ms: POLL_MS,
                }
            } else {
                Event::Cancel(POLL)
            }]);
        }
    }

    fn allow(&mut self, permission: &str) {
        if permission != SCREEN_RECORDING && permission != ACCESSIBILITY {
            return;
        }
        self.read();
        if !self.granted(permission) {
            self.platform.request(permission);
            self.read();
            if !self.granted(permission) {
                self.platform.open_settings(permission);
            }
        }
        self.show_helper(permission);
        let events = self.refresh();
        self.queue(events);
    }

    fn request_permissions(&mut self, include: bool) -> String {
        self.read();
        if include && !self.granted(ACCESSIBILITY) {
            self.platform.request(ACCESSIBILITY);
        }
        if !self.granted(SCREEN_RECORDING) {
            self.platform.request(SCREEN_RECORDING);
            self.read();
            if !self.granted(SCREEN_RECORDING) {
                self.platform.open_settings(SCREEN_RECORDING);
            }
        }
        self.read();
        let screen = self.granted(SCREEN_RECORDING);
        let text = !include || self.granted(ACCESSIBILITY);
        if !screen {
            self.show_helper(SCREEN_RECORDING);
        } else if !text {
            self.platform.open_settings(ACCESSIBILITY);
            self.show_helper(ACCESSIBILITY);
        }
        let events = self.refresh();
        self.queue(events);
        match (screen, text) {
            (true, true) => "",
            (false, true) => SCREEN_MESSAGE,
            (true, false) => ACCESSIBILITY_MESSAGE,
            (false, false) => BOTH_MESSAGE,
        }
        .to_owned()
    }

    fn test(&mut self) -> Vec<Event> {
        if self.capturing.is_some() {
            return Vec::new();
        }
        match self.platform.capture(false) {
            Some(capture) => vec![self.tested(&capture)],
            None => {
                self.capturing = Some(true);
                Vec::new()
            }
        }
    }

    fn capture(&mut self) -> Vec<Event> {
        if self.capturing.is_some() {
            return Vec::new();
        }
        match self.platform.capture(self.include) {
            Some(capture) => vec![self.captured(capture)],
            None => {
                self.capturing = Some(false);
                Vec::new()
            }
        }
    }

    fn play(&mut self, sound: &str) {
        self.platform.play(sound);
    }

    fn arrive(&mut self) -> Vec<Event> {
        let mut events = std::mem::take(&mut self.queued);
        for signal in self.inbox.take() {
            events.extend(self.signal(signal));
        }
        events.append(&mut self.queued);
        events
    }

    fn timeout(&mut self, token: u64) -> Vec<Event> {
        match token {
            POLL if self.watching => {
                let mut events = self.refresh();
                events.push(Event::After {
                    token: POLL,
                    ms: POLL_MS,
                });
                events
            }
            HELPER_CHECK if self.helper.open() => {
                self.check_helper();
                let mut events = std::mem::take(&mut self.queued);
                if self.helper.open() {
                    events.push(Event::After {
                        token: HELPER_CHECK,
                        ms: HELPER_CHECK_MS,
                    });
                }
                events
            }
            HELPER_TRACK if self.helper.open() => {
                self.track_helper();
                let mut events = std::mem::take(&mut self.queued);
                if self.helper.open() {
                    events.push(Event::After {
                        token: HELPER_TRACK,
                        ms: HELPER_TRACK_MS,
                    });
                }
                events
            }
            _ => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_large_capture_shrinks_keeping_its_shape() {
        let image = fit(RgbaImage::new(4000, 3000), MAX_WIDTH, MAX_HEIGHT);
        assert_eq!(image.dimensions(), (2133, 1600));
        let image = fit(RgbaImage::new(5120, 2000), MAX_WIDTH, MAX_HEIGHT);
        assert_eq!(image.dimensions(), (2560, 1000));
        let image = fit(RgbaImage::new(320, 200), MAX_WIDTH, MAX_HEIGHT);
        assert_eq!(image.dimensions(), (320, 200));
    }

    #[test]
    fn the_helper_sits_below_the_list_right_of_the_sidebar() {
        let bounds = Helper::bounds_beside(Rect::new(100, 100, 1000, 600));
        assert_eq!(bounds, Rect::new(428, 544, 560, 140));
        // A narrow window keeps the insets beside the panel.
        let bounds = Helper::bounds_beside(Rect::new(100, 100, 800, 600));
        assert_eq!(bounds, Rect::new(332, 544, 552, 140));
    }

    #[test]
    fn a_failed_test_capture_names_the_step_and_the_app() {
        let capture = Capture {
            step: "capture-window".into(),
            status: "exited".into(),
            exit_code: 1,
            ..Capture::default()
        };
        let error = capture_error(&capture, "HAL-C2");
        assert!(error.starts_with(
            "Could not capture a test snapshot. Capturing the window failed: \
             screencapture exited with code 1."
        ));
        assert!(error.ends_with("check that \"HAL-C2\" is allowed for both."));
    }
}
