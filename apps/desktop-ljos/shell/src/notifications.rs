//! The desktop's notification service (org.freedesktop.Notifications), where
//! [`AlertController`](crate::controllers::alerts::AlertController)'s system
//! notifications go; off until enabled. One notification per key: a newer
//! one replaces it, and clicking an older one still reports its own key, even
//! after newer ones were delivered.
//!
//! The port of desktop-qt's NativeNotifications. Calls go out in order on a
//! worker thread, as Qt's async calls did; the service's signals arrive on a
//! listener thread, which hands a click to `on_activated` (main.rs posts it
//! to the Engine thread). Both threads live as long as the bus connection,
//! which is the app's.

use std::collections::HashMap;
use std::sync::mpsc;
use std::sync::{Arc, Mutex, MutexGuard};

use zbus::blocking::fdo::DBusProxy;
use zbus::blocking::{Connection, MessageIterator};
use zbus::message::Type;
use zbus::names::BusName;
use zbus::zvariant::Value;
use zbus::{MatchRule, Message};

use crate::controllers::alerts::Presenter;

const SERVICE: &str = "org.freedesktop.Notifications";
const PATH: &str = "/org/freedesktop/Notifications";
const UNSUPPORTED: &str = "Native notifications require a Linux desktop notification service.";

type Activated = Arc<dyn Fn(String) + Send + Sync>;

#[derive(Default)]
struct State {
    enabled: bool,
    /// The service's unique owner, empty while there is none. A notification
    /// id belongs to one daemon, not to the reusable well-known name, so
    /// calls and the signals believed go to and from this owner.
    owner: String,
    /// Bumped whenever ids already on their way stop counting: turning off,
    /// or another daemon taking the service.
    generation: u32,
    last_error: String,
    /// Notification id to the key it was shown for.
    ids: HashMap<u32, String>,
}

enum Job {
    Notify {
        key: String,
        owner: String,
        generation: u32,
        body: Notify,
    },
    Close {
        owner: String,
        id: u32,
    },
    Flush(mpsc::SyncSender<()>),
}

/// Notify's arguments: app name, replaced id, icon, summary, body, actions,
/// hints, timeout.
type Notify = (
    &'static str,
    u32,
    &'static str,
    String,
    String,
    Vec<&'static str>,
    HashMap<&'static str, Value<'static>>,
    i32,
);

pub struct NativeNotifications {
    state: Arc<Mutex<State>>,
    jobs: Option<mpsc::Sender<Job>>,
}

impl NativeNotifications {
    /// On the session bus; unsupported without one. `on_activated` gets the
    /// key of a clicked notification, on the listener thread.
    pub fn session(on_activated: impl Fn(String) + Send + Sync + 'static) -> Self {
        Self::on(Connection::session().ok(), on_activated)
    }

    /// On `bus`, or unsupported for `None`.
    pub fn on(
        bus: Option<Connection>,
        on_activated: impl Fn(String) + Send + Sync + 'static,
    ) -> Self {
        let state = Arc::new(Mutex::new(State::default()));
        let Some(bus) = bus else {
            return Self { state, jobs: None };
        };
        let activated: Activated = Arc::new(on_activated);
        // Subscribed before the owner is read, so no change is missed.
        let signals = subscribe(&bus);
        let owner = DBusProxy::new(&bus)
            .ok()
            .and_then(|dbus| {
                let name = BusName::try_from(SERVICE).ok()?;
                dbus.get_name_owner(name).ok()
            })
            .map(|o| o.to_string())
            .unwrap_or_default();
        lock(&state).owner = owner;
        if let Some(signals) = signals {
            let state = state.clone();
            let _ = std::thread::Builder::new()
                .name("notifications-signals".into())
                .spawn(move || listen(signals, &state, &activated));
        }
        let (jobs, inbox) = mpsc::channel();
        let worker_state = state.clone();
        let _ = std::thread::Builder::new()
            .name("notifications-calls".into())
            .spawn(move || work(&bus, &inbox, &worker_state));
        Self {
            state,
            jobs: Some(jobs),
        }
    }

    pub fn enabled(&self) -> bool {
        lock(&self.state).enabled
    }

    /// Off closes every notification shown, and replies still on their way
    /// close theirs.
    pub fn set_enabled(&self, enabled: bool) {
        {
            let mut s = lock(&self.state);
            if s.enabled == enabled {
                return;
            }
            s.enabled = enabled;
            s.generation = s.generation.wrapping_add(1);
        }
        if !enabled {
            self.close_all();
        }
    }

    /// Whether a notification service is there.
    pub fn supported(&self) -> bool {
        !lock(&self.state).owner.is_empty()
    }

    /// Why the last notification was not shown; empty once one was.
    pub fn last_error(&self) -> String {
        lock(&self.state).last_error.clone()
    }

    /// Shows the notification for `key`, replacing the one shown for it.
    /// `silent` asks the service for no sound; `timeout_ms` -1 is the
    /// service's own. False when off, or when there is no service.
    pub fn show(&self, key: &str, title: &str, body: &str, silent: bool, timeout_ms: i32) -> bool {
        let mut s = lock(&self.state);
        if !s.enabled || key.is_empty() {
            return false;
        }
        let Some(jobs) = self.jobs.as_ref().filter(|_| !s.owner.is_empty()) else {
            s.last_error = UNSUPPORTED.into();
            return false;
        };
        let replaces = s
            .ids
            .iter()
            .find(|(_, k)| *k == key)
            .map_or(0, |(id, _)| *id);
        let hints = HashMap::from([
            ("desktop-entry", Value::from("hal-c2")),
            ("suppress-sound", Value::from(silent)),
        ]);
        let body = (
            "HAL-C2",
            replaces,
            "hal-c2",
            title.to_owned(),
            escape_html(body),
            vec!["default", "Open thread"],
            hints,
            timeout_ms.max(-1),
        );
        let _ = jobs.send(Job::Notify {
            key: key.to_owned(),
            owner: s.owner.clone(),
            generation: s.generation,
            body,
        });
        true
    }

    /// Closes every notification shown.
    pub fn close_all(&self) {
        let mut s = lock(&self.state);
        let ids: Vec<u32> = s.ids.drain().map(|(id, _)| id).collect();
        if let Some(jobs) = &self.jobs {
            for id in ids {
                let _ = jobs.send(Job::Close {
                    owner: s.owner.clone(),
                    id,
                });
            }
        }
    }

    /// Waits until the calls made so far have their replies handled: the
    /// receipt a test waits on.
    pub fn flush(&self) {
        let Some(jobs) = &self.jobs else { return };
        let (done, wait) = mpsc::sync_channel(1);
        if jobs.send(Job::Flush(done)).is_ok() {
            let _ = wait.recv();
        }
    }
}

impl Drop for NativeNotifications {
    fn drop(&mut self) {
        self.close_all();
    }
}

impl Presenter for NativeNotifications {
    fn show(&self, key: &str, title: &str, body: &str, silent: bool) -> bool {
        NativeNotifications::show(self, key, title, body, silent, -1)
    }

    fn clear(&self) {
        self.close_all();
    }

    fn set_enabled(&self, enabled: bool) {
        NativeNotifications::set_enabled(self, enabled);
    }

    /// No audio module: the sound theme's player, where the desktop has one.
    fn play(&self, kind: &str) {
        let Some(player) = find_executable("canberra-gtk-play") else {
            return;
        };
        let event = if kind == "completion" {
            "complete"
        } else {
            "dialog-question"
        };
        if let Ok(mut child) = std::process::Command::new(player)
            .args(["-i", event])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
        {
            // Reaped where it cannot hold the caller up.
            std::thread::spawn(move || child.wait());
        }
    }

    /// Without a notification service nothing could be shown.
    fn permitted(&self) -> Option<bool> {
        Some(self.supported())
    }

    // No badge: desktop-qt sets QGuiApplication::setBadgeNumber, and Ljós
    // has no badge yet (the default does nothing).
}

fn lock(state: &Mutex<State>) -> MutexGuard<'_, State> {
    // A panic elsewhere leaves the state as consistent as any step of it.
    state.lock().unwrap_or_else(|e| e.into_inner())
}

/// The service's signals, and changes of its owner.
fn subscribe(bus: &Connection) -> Option<MessageIterator> {
    let dbus = DBusProxy::new(bus).ok()?;
    let service = MatchRule::builder()
        .msg_type(Type::Signal)
        .interface(SERVICE)
        .ok()?
        .path(PATH)
        .ok()?
        .build();
    let owner = MatchRule::builder()
        .msg_type(Type::Signal)
        .sender("org.freedesktop.DBus")
        .ok()?
        .interface("org.freedesktop.DBus")
        .ok()?
        .member("NameOwnerChanged")
        .ok()?
        .arg(0, SERVICE)
        .ok()?
        .build();
    // One stream for both, so they are handled in the order they came.
    let messages = MessageIterator::from(bus);
    dbus.add_match_rule(service).ok()?;
    dbus.add_match_rule(owner).ok()?;
    Some(messages)
}

fn listen(signals: MessageIterator, state: &Mutex<State>, activated: &Activated) {
    for message in signals {
        let Ok(message) = message else { continue };
        if let Some(key) = signal(&message, state) {
            activated(key);
        }
    }
}

/// Applies one signal; the key a click opens, if it was one.
fn signal(message: &Message, state: &Mutex<State>) -> Option<String> {
    let header = message.header();
    if header.message_type() != Type::Signal {
        return None;
    }
    let interface = header.interface()?.as_str();
    let member = header.member()?.as_str();
    let sender = header.sender().map(|s| s.as_str()).unwrap_or_default();
    let mut s = lock(state);
    match (interface, member) {
        (SERVICE, "ActionInvoked") => {
            let (id, action): (u32, String) = message.body().deserialize().ok()?;
            if sender == s.owner && s.enabled && action == "default" {
                return s.ids.get(&id).cloned();
            }
        }
        (SERVICE, "NotificationClosed") => {
            let (id, _reason): (u32, u32) = message.body().deserialize().ok()?;
            if sender == s.owner {
                s.ids.remove(&id);
            }
        }
        ("org.freedesktop.DBus", "NameOwnerChanged") => {
            let (name, _old, new): (String, String, String) = message.body().deserialize().ok()?;
            if name == SERVICE && s.owner != new {
                s.generation = s.generation.wrapping_add(1);
                s.ids.clear();
                s.owner = new;
            }
        }
        _ => {}
    }
    None
}

fn work(bus: &Connection, inbox: &mpsc::Receiver<Job>, state: &Mutex<State>) {
    let close = |owner: &str, id: u32| {
        let _ = bus.call_method(Some(owner), PATH, Some(SERVICE), "CloseNotification", &id);
    };
    for job in inbox {
        match job {
            Job::Notify {
                key,
                owner,
                generation,
                body,
            } => {
                let reply = bus
                    .call_method(Some(owner.as_str()), PATH, Some(SERVICE), "Notify", &body)
                    .and_then(|reply| reply.body().deserialize::<u32>());
                let mut s = lock(state);
                match reply {
                    Err(e) => s.last_error = error_message(&e),
                    Ok(id) if !s.enabled || generation != s.generation => {
                        drop(s);
                        close(&owner, id);
                    }
                    Ok(id) => {
                        s.ids.insert(id, key);
                        s.last_error.clear();
                    }
                }
            }
            Job::Close { owner, id } => close(&owner, id),
            Job::Flush(done) => {
                let _ = done.send(());
            }
        }
    }
}

/// The service's own words for a refusal, as Qt's QDBusError::message.
fn error_message(e: &zbus::Error) -> String {
    match e {
        zbus::Error::MethodError(_, Some(message), _) => message.clone(),
        e => e.to_string(),
    }
}

/// As QString::toHtmlEscaped: the body is markup to services that read it.
fn escape_html(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '&' => out.push_str("&amp;"),
            '"' => out.push_str("&quot;"),
            c => out.push(c),
        }
    }
    out
}

fn find_executable(name: &str) -> Option<std::path::PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(name))
        .find(|path| path.is_file())
}
