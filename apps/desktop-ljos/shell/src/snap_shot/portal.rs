//! Snap Shot through xdg-desktop-portal on a Wayland desktop, desktop-qt's
//! PortalSnapShot: the Screenshot portal takes the window in front where it
//! offers that target (version 3 and `AvailableTargets`' window bit), else
//! opens its picker; the GlobalShortcuts portal holds one session with the
//! capture shortcut. Nothing is asked of the bus until `probe` or `bind`.
//!
//! The protocol is a [`Machine`] that no bus is under: it takes what the
//! portal said ([`Input`]) and answers with what to ask it ([`Call`]) and
//! what the controller should hear ([`Event`]). [`Portal`] is the backend,
//! a machine on a [`Wire`]; [`System`] is the wire to the session bus, in
//! `wire.rs`, built with zbus (pure Rust, no libdbus) because its blocking
//! API is what `notifications.rs` already uses.
//!
//! A portal Request answers with a signal that may come before the method
//! reply names it, so a request is known by its `handle_token` (the last
//! segment of its handle) and only by the handle the reply names when that
//! differs. Every request has a timer ([`Event::After`]); a stale answer
//! for a session since dropped is ignored by its generation.

mod wire;

#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::path::PathBuf;

use image::imageops::{self, FilterType};
use image::{ImageFormat, RgbaImage};

use super::{Backend, Captured, Event, Mode, Platform, Session, Shortcut};

pub use wire::System;

/// The Screenshot portal's `target` for the window in front.
const WINDOW_TARGET: u32 = 8;
const PROMPT_TIMEOUT_MS: u64 = 120_000;
const TIMEOUT_MS: u64 = 5_000;
const MAX_PNG_BYTES: u64 = 32 * 1024 * 1024;
/// The largest a capture is kept: larger ones are scaled down to fit.
const MAX_WIDTH: u32 = 2560;
const MAX_HEIGHT: u32 = 1600;
const PNG_HEADER: &[u8] = b"\x89PNG\r\n\x1a\n";

/// What the machine asks of the bus (a method call, or the one thing that
/// is not: [`Call::Load`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Call {
    /// Names the app to the portal (`host.portal.Registry.Register`).
    Register {
        app_id: String,
    },
    /// `Properties.GetAll` of the Screenshot portal: [`Input::Properties`].
    Properties,
    /// `Properties.Get` of the GlobalShortcuts portal's `version`:
    /// [`Input::Version`].
    Version {
        generation: u64,
    },
    /// `Screenshot`: of the window in front, else the user's pick.
    Screenshot {
        token: String,
        window: bool,
    },
    CreateSession {
        token: String,
        session_token: String,
    },
    BindShortcuts {
        token: String,
        session: String,
        id: String,
        trigger: String,
    },
    Configure {
        session: String,
    },
    /// Closes a Request at `handle`, else the one `token` names.
    CloseRequest {
        token: String,
        handle: Option<String>,
    },
    CloseSession {
        handle: String,
    },
    /// Reads the screenshot file the portal made: [`Input::Loaded`].
    Load {
        uri: String,
    },
}

/// A shortcut as the portal lists it: `trigger_description` is what the
/// desktop calls the keys.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Bound {
    pub id: String,
    pub trigger: String,
}

/// What a Request's Response carries that the machine reads.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Results {
    pub uri: Option<String>,
    pub session_handle: Option<String>,
    pub shortcuts: Vec<Bound>,
    /// The portal never answered.
    pub timeout: bool,
}

/// What the portal said, or the wire found.
#[derive(Debug)]
pub enum Input {
    /// The Screenshot portal's `version` and `AvailableTargets`; none when
    /// it could not be asked.
    Properties(Option<(u32, u32)>),
    /// The GlobalShortcuts portal's `version` for the `generation` that
    /// asked; none when it could not be asked.
    Version {
        generation: u64,
        version: Option<u32>,
    },
    /// The method reply of a Request call: its handle, or the error.
    Replied {
        token: String,
        handle: Result<String, String>,
    },
    Response {
        handle: String,
        status: u32,
        results: Results,
    },
    SessionClosed {
        handle: String,
    },
    Activated {
        session: String,
        id: String,
    },
    ShortcutsChanged {
        session: String,
        shortcuts: Vec<Bound>,
    },
    /// The portal's bus name changed hands; `was_owned` when it had an owner.
    OwnerChanged {
        was_owned: bool,
    },
    Loaded(Result<Captured, String>),
}

/// What the machine does next.
#[derive(Debug)]
pub enum Out {
    Call(Call),
    Event(Event),
}

/// How the machine reaches the bus.
pub trait Wire {
    /// Starts `call`; what comes of it arrives as [`Input`].
    fn send(&mut self, call: Call);
    /// What arrived since, in order.
    fn arrive(&mut self) -> Vec<Input>;
}

enum Kind {
    Screenshot,
    CreateSession(u64),
    Bind(u64),
}

struct Pending {
    kind: Kind,
    timer: u64,
    /// The handle the method reply named.
    handle: Option<String>,
}

/// The portal protocol, sans I/O.
pub struct Machine {
    session: Session,
    shortcut: Shortcut,
    sandboxed: bool,
    app_id: String,
    probing: bool,
    registered: bool,
    /// The GlobalShortcuts portal's version; 0 until read.
    shortcuts_version: u32,
    trigger: String,
    shortcut_id: String,
    session_handle: String,
    /// Bumped whenever the session is dropped, so a late answer for the one
    /// before is ignored.
    generation: u64,
    capturing: bool,
    /// Requests that have not answered, by `handle_token`.
    pending: HashMap<String, Pending>,
    next: u64,
}

impl Machine {
    pub fn new(platform: &Platform, app_id: &str) -> Machine {
        Machine {
            session: Session {
                mode: Mode::Portal,
                desktop: platform.desktop.clone(),
                ..Session::default()
            },
            shortcut: Shortcut::default(),
            sandboxed: platform.sandboxed,
            app_id: app_id.to_owned(),
            probing: false,
            registered: false,
            shortcuts_version: 0,
            trigger: String::new(),
            shortcut_id: String::new(),
            session_handle: String::new(),
            generation: 0,
            capturing: false,
            pending: HashMap::new(),
            next: 0,
        }
    }

    pub fn session(&self) -> Session {
        self.session.clone()
    }

    pub fn shortcut(&self) -> Shortcut {
        self.shortcut.clone()
    }

    /// An id for a token or a timer, never repeated.
    fn id(&mut self) -> u64 {
        self.next += 1;
        self.next
    }

    /// Unsandboxed apps name themselves to the portal (host registry) before
    /// anything else, so its permissions are the app's; older portals lack
    /// it.
    fn register(&mut self, out: &mut Vec<Out>) {
        if self.registered {
            return;
        }
        self.registered = true;
        if !self.sandboxed {
            out.push(Out::Call(Call::Register {
                app_id: self.app_id.clone(),
            }));
        }
    }

    /// Calls a portal method that answers through a Request, `call` given
    /// its `handle_token`; the answer is `kind`'s.
    fn request(
        &mut self,
        kind: Kind,
        ms: u64,
        call: impl FnOnce(String) -> Call,
        out: &mut Vec<Out>,
    ) {
        let token = format!("hal_c2_{}", self.id());
        let timer = self.id();
        self.pending.insert(
            token.clone(),
            Pending {
                kind,
                timer,
                handle: None,
            },
        );
        out.push(Out::Call(call(token)));
        out.push(Out::Event(Event::After { token: timer, ms }));
    }

    /// Asks the desktop what it offers; idempotent.
    pub fn probe(&mut self) -> Vec<Out> {
        if self.session.ready || self.probing {
            return Vec::new();
        }
        self.probing = true;
        let mut out = Vec::new();
        self.register(&mut out);
        out.push(Out::Call(Call::Properties));
        out
    }

    /// Captures the window in front, else has the user pick one.
    pub fn capture(&mut self) -> Vec<Out> {
        if self.capturing {
            return Vec::new();
        }
        self.capturing = true;
        let mut out = Vec::new();
        self.register(&mut out);
        let window = self.session.backend == "screenshot-portal";
        self.request(
            Kind::Screenshot,
            PROMPT_TIMEOUT_MS,
            |token| Call::Screenshot { token, window },
            &mut out,
        );
        out
    }

    // -- The capture shortcut ----------------------------------------------

    fn set_shortcut(&mut self, shortcut: Shortcut, out: &mut Vec<Out>) {
        self.shortcut = shortcut;
        out.push(Out::Event(Event::Changed));
    }

    /// Ends the session (letting the shortcut go) without saying so.
    fn close_session(&mut self, out: &mut Vec<Out>) {
        self.generation += 1;
        if self.session_handle.is_empty() {
            return;
        }
        out.push(Out::Call(Call::CloseSession {
            handle: std::mem::take(&mut self.session_handle),
        }));
    }

    fn shortcut_failed(&mut self, message: &str, out: &mut Vec<Out>) {
        self.close_session(out);
        self.set_shortcut(
            Shortcut {
                message: message.to_owned(),
                ..Shortcut::default()
            },
            out,
        );
    }

    /// Binds the capture shortcut to `trigger`, replacing the one before;
    /// pending until the desktop answers.
    pub fn bind(&mut self, trigger: &str) -> Vec<Out> {
        if trigger == self.trigger && !self.session_handle.is_empty() {
            return Vec::new();
        }
        let mut out = Vec::new();
        self.close_session(&mut out);
        self.trigger = trigger.to_owned();
        self.shortcut_id = shortcut_id(trigger);
        self.set_shortcut(
            Shortcut {
                pending: true,
                message:
                    "Waiting for shortcut permission. Approve the desktop prompt if one appears."
                        .into(),
                can_retry: self.shortcuts_version == 0 || self.shortcuts_version >= 2,
                ..Shortcut::default()
            },
            &mut out,
        );
        self.register(&mut out);
        out.push(Out::Call(Call::Version {
            generation: self.generation,
        }));
        out
    }

    /// Lets the capture shortcut go.
    pub fn release(&mut self) -> Vec<Out> {
        let mut out = Vec::new();
        self.close_session(&mut out);
        self.trigger.clear();
        self.set_shortcut(Shortcut::default(), &mut out);
        out
    }

    /// Shows the desktop's shortcut permissions again.
    pub fn configure(&mut self) -> Vec<Out> {
        if self.session_handle.is_empty() {
            // The session failed or was closed: a fresh one asks again.
            let trigger = std::mem::take(&mut self.trigger);
            return if trigger.is_empty() {
                Vec::new()
            } else {
                self.bind(&trigger)
            };
        }
        if self.shortcuts_version < 2 {
            let mut out = Vec::new();
            let shortcut = Shortcut {
                message:
                    "Open your desktop's shortcut settings and allow HAL-C2's capture shortcut."
                        .into(),
                ..self.shortcut.clone()
            };
            self.set_shortcut(shortcut, &mut out);
            return out;
        }
        vec![Out::Call(Call::Configure {
            session: self.session_handle.clone(),
        })]
    }

    /// What the desktop lists for the shortcut becomes its state.
    fn bound(&mut self, shortcuts: &[Bound], out: &mut Vec<Out>) {
        let mut label = String::new();
        let mut found = false;
        for shortcut in shortcuts.iter().filter(|s| s.id == self.shortcut_id) {
            found = true;
            label = shortcut.trigger.trim().to_owned();
        }
        let can_retry = self.shortcuts_version >= 2;
        let message = if !label.is_empty() {
            format!("Desktop shortcut: {label}")
        } else if can_retry {
            "No shortcut is assigned. Open shortcut permissions to choose one.".into()
        } else {
            "No shortcut is assigned. Choose one in your desktop's shortcut settings.".into()
        };
        self.set_shortcut(
            Shortcut {
                registered: found && !label.is_empty(),
                pending: false,
                label,
                message,
                can_retry,
            },
            out,
        );
    }

    // -- What came back ----------------------------------------------------

    /// The time [`Event::After`] asked for `timer` has passed: its request
    /// is closed and answers as a timeout.
    pub fn timeout(&mut self, timer: u64) -> Vec<Out> {
        let Some((token, handle)) = self
            .pending
            .iter()
            .find(|(_, p)| p.timer == timer)
            .map(|(token, p)| (token.clone(), p.handle.clone()))
        else {
            return Vec::new();
        };
        let mut out = vec![Out::Call(Call::CloseRequest {
            token: token.clone(),
            handle,
        })];
        let results = Results {
            timeout: true,
            ..Results::default()
        };
        out.extend(self.finish(&token, 2, results));
        out
    }

    pub fn input(&mut self, input: Input) -> Vec<Out> {
        let mut out = Vec::new();
        match input {
            Input::Properties(found) => {
                self.probing = false;
                let (version, targets) = found.unwrap_or_default();
                self.session.backend = if version >= 3 && targets & WINDOW_TARGET != 0 {
                    "screenshot-portal"
                } else {
                    "picker"
                }
                .into();
                self.session.ready = true;
                out.push(Out::Event(Event::Changed));
            }
            Input::Version {
                generation,
                version,
            } => {
                if generation != self.generation {
                    return out;
                }
                let Some(version) = version else {
                    self.shortcut_failed(
                        "This desktop doesn't offer app shortcuts. Choose a shortcut in your desktop's settings instead.",
                        &mut out,
                    );
                    return out;
                };
                self.shortcuts_version = version;
                let session_token = format!("hal_c2_{}", self.id());
                let generation = self.generation;
                self.request(
                    Kind::CreateSession(generation),
                    TIMEOUT_MS,
                    |token| Call::CreateSession {
                        token,
                        session_token,
                    },
                    &mut out,
                );
            }
            Input::Replied { token, handle } => match handle {
                Ok(handle) => {
                    if let Some(pending) = self.pending.get_mut(&token) {
                        pending.handle = Some(handle);
                    }
                }
                Err(_) => return self.finish(&token, 2, Results::default()),
            },
            Input::Response {
                handle,
                status,
                results,
            } => {
                let last = handle.rsplit('/').next().unwrap_or_default();
                let token = self
                    .pending
                    .iter()
                    .find(|(token, p)| p.handle.as_deref().map_or(*token == last, |h| h == handle))
                    .map(|(token, _)| token.clone());
                if let Some(token) = token {
                    return self.finish(&token, status, results);
                }
            }
            Input::SessionClosed { handle } => {
                if !self.session_handle.is_empty() && handle == self.session_handle {
                    self.shortcut_failed(
                        "Your desktop closed the capture shortcut. Retry the shortcut request.",
                        &mut out,
                    );
                }
            }
            Input::Activated { session, id } => {
                if !self.session_handle.is_empty()
                    && session == self.session_handle
                    && id == self.shortcut_id
                    && self.shortcut.registered
                {
                    out.push(Out::Event(Event::Activated));
                }
            }
            Input::ShortcutsChanged { session, shortcuts } => {
                if !self.session_handle.is_empty() && session == self.session_handle {
                    self.bound(&shortcuts, &mut out);
                }
            }
            Input::OwnerChanged { was_owned } => {
                if was_owned && (!self.session_handle.is_empty() || self.shortcut.pending) {
                    self.shortcut_failed(
                        "The desktop shortcut service restarted. Retry the shortcut request.",
                        &mut out,
                    );
                }
            }
            Input::Loaded(Ok(captured)) => out.push(Out::Event(Event::Captured(captured))),
            Input::Loaded(Err(message)) => out.push(Out::Event(Event::Failed(message))),
        }
        out
    }

    /// A Request answered (or never will): what it was for follows.
    fn finish(&mut self, token: &str, status: u32, results: Results) -> Vec<Out> {
        let Some(pending) = self.pending.remove(token) else {
            return Vec::new();
        };
        let mut out = vec![Out::Event(Event::Cancel(pending.timer))];
        match pending.kind {
            Kind::Screenshot => {
                self.capturing = false;
                let failed = |message: &str| Out::Event(Event::Failed(message.to_owned()));
                match status {
                    1 => out.push(failed("Snapshot was cancelled.")),
                    0 => out.push(Out::Call(Call::Load {
                        uri: results.uri.unwrap_or_default(),
                    })),
                    _ => out.push(failed("Your desktop did not allow the snapshot.")),
                }
            }
            Kind::CreateSession(generation) => {
                let handle = results.session_handle.unwrap_or_default();
                if generation != self.generation {
                    if status == 0 && !handle.is_empty() {
                        out.push(Out::Call(Call::CloseSession { handle }));
                    }
                    return out;
                }
                if status != 0 || handle.is_empty() {
                    let message = if results.timeout {
                        "Shortcut permission request timed out. Try again."
                    } else {
                        "Your desktop could not create a capture shortcut session."
                    };
                    self.shortcut_failed(message, &mut out);
                    return out;
                }
                self.session_handle = handle.clone();
                self.shortcut.can_retry = self.shortcuts_version >= 2;
                let (id, trigger) = (self.shortcut_id.clone(), self.trigger.clone());
                // Every session binds, even when the desktop remembers the
                // approval.
                self.request(
                    Kind::Bind(generation),
                    PROMPT_TIMEOUT_MS,
                    |token| Call::BindShortcuts {
                        token,
                        session: handle,
                        id,
                        trigger,
                    },
                    &mut out,
                );
            }
            Kind::Bind(generation) => {
                if generation != self.generation {
                    return out;
                }
                if status != 0 {
                    let can_retry = self.shortcuts_version >= 2;
                    let message = if can_retry {
                        "Shortcut permission wasn't granted. Open shortcut permissions to allow it."
                    } else {
                        "Shortcut permission wasn't granted. Allow HAL-C2 in your desktop's shortcut settings."
                    };
                    self.set_shortcut(
                        Shortcut {
                            message: message.into(),
                            can_retry,
                            ..Shortcut::default()
                        },
                        &mut out,
                    );
                    return out;
                }
                self.bound(&results.shortcuts, &mut out);
            }
        }
        out
    }
}

/// The portal's id for the capture shortcut: stable for a trigger, so the
/// desktop remembers the approval.
fn shortcut_id(trigger: &str) -> String {
    let digest = sha256(trigger.as_bytes());
    let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("hal-c2-snap-shot-{}", &hex[..16])
}

/// SHA-256 (FIPS 180-4). The one place the shell needs a hash: the
/// shortcut id above, which desktop-qt derived with QCryptographicHash and
/// the desktop has remembered approvals under.
fn sha256(message: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut state: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut padded = message.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&((message.len() as u64) * 8).to_be_bytes());
    for block in padded.as_chunks::<64>().0 {
        let mut w = [0u32; 64];
        for (slot, word) in w.iter_mut().zip(block.as_chunks::<4>().0) {
            *slot = u32::from_be_bytes(*word);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = state;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choice = (e & f) ^ (!e & g);
            let t1 = h
                .wrapping_add(s1)
                .wrapping_add(choice)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(majority);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (slot, value) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *slot = slot.wrapping_add(value);
        }
    }
    let mut digest = [0u8; 32];
    for (bytes, word) in digest.as_chunks_mut::<4>().0.iter_mut().zip(state) {
        *bytes = word.to_be_bytes();
    }
    digest
}

/// Reads the screenshot file the portal made at `uri`, a `file:` URL: a
/// file the portal owns, read and never removed. Larger than the attachment
/// limit allows in pixels, it is scaled down to fit. The portal names
/// neither the app nor the window.
pub fn load(uri: &str) -> Result<Captured, String> {
    let invalid = || "Invalid screenshot file.".to_owned();
    let path = url::Url::parse(uri)
        .ok()
        .filter(|url| url.scheme() == "file")
        .and_then(|url| url.to_file_path().ok())
        .ok_or_else(invalid)?;
    let file = std::fs::File::open(&path).map_err(|_| invalid())?;
    if file.metadata().map_err(|_| invalid())?.len() > MAX_PNG_BYTES {
        return Err(invalid());
    }
    let png = std::fs::read(&path).map_err(|_| invalid())?;
    let oversized = || "Invalid or oversized window screenshot.".to_owned();
    if !png.starts_with(PNG_HEADER) {
        return Err(oversized());
    }
    let mut image = image::load_from_memory_with_format(&png, ImageFormat::Png)
        .map_err(|_| oversized())?
        .to_rgba8();
    if image.width() > MAX_WIDTH || image.height() > MAX_HEIGHT {
        image = fit(&image, MAX_WIDTH, MAX_HEIGHT);
    }
    Ok(Captured {
        image,
        app_name: "Window".into(),
        window_title: String::new(),
    })
}

/// `image` within `width` by `height`, its proportions kept.
fn fit(image: &RgbaImage, width: u32, height: u32) -> RgbaImage {
    let scale = (f64::from(width) / f64::from(image.width()))
        .min(f64::from(height) / f64::from(image.height()));
    let side = |length: u32| ((f64::from(length) * scale).round() as u32).max(1);
    imageops::resize(
        image,
        side(image.width()),
        side(image.height()),
        FilterType::Triangle,
    )
}

/// The backend: a machine on a wire.
pub struct Portal {
    machine: Machine,
    wire: Box<dyn Wire>,
    /// Where the capture sounds are unpacked for the player.
    cache_dir: Option<PathBuf>,
}

impl Portal {
    pub fn new(
        platform: &Platform,
        wire: Box<dyn Wire>,
        app_id: &str,
        cache_dir: Option<PathBuf>,
    ) -> Portal {
        Portal {
            machine: Machine::new(platform, app_id),
            wire,
            cache_dir,
        }
    }

    /// The portal on the session bus. `wake` runs on any thread when
    /// [`Backend::arrive`] has something to do.
    pub fn system(
        platform: &Platform,
        cache_dir: Option<PathBuf>,
        wake: impl Fn() + Send + Sync + 'static,
    ) -> Portal {
        // The desktop file's name, which the portal knows the app by.
        Portal::new(platform, Box::new(System::new(wake)), "hal-c2", cache_dir)
    }

    /// Sends the calls and hands back the events.
    fn run(&mut self, outs: Vec<Out>) -> Vec<Event> {
        let mut events = Vec::new();
        for out in outs {
            match out {
                Out::Call(call) => self.wire.send(call),
                Out::Event(event) => events.push(event),
            }
        }
        events
    }
}

impl Backend for Portal {
    fn session(&self) -> Session {
        self.machine.session()
    }

    fn shortcut(&self) -> Shortcut {
        self.machine.shortcut()
    }

    fn probe(&mut self) -> Vec<Event> {
        let outs = self.machine.probe();
        self.run(outs)
    }

    fn bind(&mut self, trigger: &str) -> Vec<Event> {
        let outs = self.machine.bind(trigger);
        self.run(outs)
    }

    fn release(&mut self) -> Vec<Event> {
        let outs = self.machine.release();
        self.run(outs)
    }

    fn configure(&mut self) -> Vec<Event> {
        let outs = self.machine.configure();
        self.run(outs)
    }

    fn capture(&mut self) -> Vec<Event> {
        let outs = self.machine.capture();
        self.run(outs)
    }

    fn play(&mut self, sound: &str) {
        super::play_sound(self.cache_dir.as_deref(), sound);
    }

    fn arrive(&mut self) -> Vec<Event> {
        let mut events = Vec::new();
        for input in self.wire.arrive() {
            let outs = self.machine.input(input);
            events.extend(self.run(outs));
        }
        events
    }

    fn timeout(&mut self, token: u64) -> Vec<Event> {
        let outs = self.machine.timeout(token);
        self.run(outs)
    }
}
