//! desktop-qt's ThreadDevices: the Device tabs of a thread's right panel.
//! The picker (`device`) lists the thread's environment's simulators and
//! emulators, and a device tab (`device:<host>:<device>`, both
//! percent-encoded) streams one the thread has open. The environment's
//! DeviceServiceState is followed through the MC's `devices` shape when a
//! cluster MC serves it, and read with `device.list` otherwise (and each
//! time a Device tab shows).
//!
//! `open()` is `device.open` for the thread; once it answers, `opened` asks
//! the panel for the device's tab in place of the picker. `powerOff()` is
//! `device.close` with shutdown, then `closed` asks the panel to close the
//! tab in the thread it was asked from; closing a tab only stops its stream,
//! the device stays open. A device tab whose session ended shows the picker
//! again.
//!
//! While following, a session the thread gains (an agent's `device.open`)
//! asks for its tab with `automatic` set: the panel skips tabs the user
//! closed.
//!
//! Publishes `view` for the DevicePanel brick:
//!   {loaded, setup (the hub is off or never set up: Settings →
//!    Integrations), loading ("" or what the picker waits on: "Opening
//!    device…", "Starting device…", the hub installing, "Finding devices…"),
//!    empty ("" or why the list is empty), hostDetail, starting ("Starting
//!    <names>… This can take a minute." or ""), noAndroid (no Android virtual
//!    device and none missing), canRefresh, error ("" or why the last open or
//!    power off failed), pendingKey, groups: [{title, devices: [{key, hostId,
//!    id, name, platform, detail, action ("Open" | "Start")}]}], screen:
//!    null, or the shown tab's device {hostId, id, name, platform,
//!    description}}.
//!
//! [`Devices`] is that without the engine; [`ThreadDevices`] is the object
//! the panel hands QML, which runs what it asks for on the shell's MC and
//! its [`DeviceStream`].

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use ljos::prelude::{
    Atom, Cx, Engine, EngineError, ObjectId, QmlObject, QmlValue, Value, qml_impl,
};
use serde_json::json;

use super::percent;
use super::stream::DeviceStream;
use crate::bridge::percent_decode;
use crate::json::Json;
use crate::mc::{Mc, McError, SubId};

const PICKER: &str = "device";
const DEVICE_TAB: &str = "device:";

/// A device tab's id.
pub fn tab_id_of(host_id: &str, device_id: &str) -> String {
    format!("{DEVICE_TAB}{}:{}", percent(host_id), percent(device_id))
}

/// The host and device of a device tab; None when `tab_id` is not one (the
/// picker is not).
pub fn target_of(tab_id: &str) -> Option<(String, String)> {
    let rest = tab_id.strip_prefix(DEVICE_TAB)?;
    let parts: Vec<&str> = rest.split(':').collect();
    match parts[..] {
        [host, device] if !host.is_empty() && !device.is_empty() => {
            Some((percent_decode(host), percent_decode(device)))
        }
        _ => None,
    }
}

/// Whether `tab_id` is a Device tab: the picker or a device's.
pub fn is_device_tab(tab_id: &str) -> bool {
    tab_id == PICKER || tab_id.starts_with(DEVICE_TAB)
}

fn text(object: &Json, field: &str) -> String {
    object
        .get(field)
        .and_then(Json::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn flag(object: &Json, field: &str) -> bool {
    object.get(field).and_then(Json::as_bool).unwrap_or(false)
}

fn array<'a>(object: &'a Json, field: &str) -> &'a [Json] {
    object
        .get(field)
        .and_then(Json::as_array)
        .map_or(&[], Vec::as_slice)
}

fn key_of(host_id: &str, device_id: &str) -> String {
    format!("{host_id}\0{device_id}")
}

/// What a call's answer is for.
#[derive(Clone, Debug, PartialEq)]
pub enum Then {
    /// `device.list`, asked for the environment of `generation`.
    List { generation: u64 },
    /// `device.open` of a device for `thread`.
    Open {
        generation: u64,
        thread: String,
        host_id: String,
        device_id: String,
    },
    /// `device.close` with shutdown of `tab`, asked in `thread`.
    PowerOff {
        environment: String,
        thread: String,
        tab: String,
    },
}

/// What the devices ask of their host.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// Follows the `devices` shape of `mc`.
    Follow(String),
    Unfollow,
    Call {
        environment: String,
        method: &'static str,
        payload: Json,
        then: Then,
    },
    /// The stream shows this device (all empty: none), streaming while
    /// `active`.
    Stream {
        hub_base: String,
        platform: String,
        device: String,
        active: bool,
    },
    /// The panel shows `tab` in place of the picker; `automatic`: an agent
    /// opened it.
    Opened {
        tab: String,
        automatic: bool,
    },
    /// `thread_key` (`<environment>:<thread>`) closes `tab`.
    Closed {
        thread_key: String,
        tab: String,
    },
    /// A device's name became known or changed: tab titles follow.
    NamesChanged,
}

/// A thread's Device tabs, without the engine.
#[derive(Debug, Default)]
pub struct Devices {
    environment: String,
    thread: String,
    mc: String,
    tab: String,
    following: bool,
    /// Replies for another environment are dropped.
    generation: u64,
    loaded: bool,
    state: Json,
    names: String,
    /// The key (`<host>\0<device>`) of the device being opened.
    pending: String,
    error: String,
    /// Each thread's sessions (with a known device) as last seen: a session
    /// missing there is new. Absent until the first state, the baseline.
    sessions_seen: HashMap<String, HashSet<String>>,
    view: Json,
    view_changed: bool,
    /// What the stream was last told.
    target: Option<(String, String, String, bool)>,
    effects: Vec<Effect>,
}

impl Devices {
    pub fn new() -> Devices {
        let mut devices = Devices {
            state: json!({}),
            ..Devices::default()
        };
        devices.retarget();
        devices.publish();
        devices
    }

    pub fn view(&self) -> &Json {
        &self.view
    }
    pub fn tab(&self) -> &str {
        &self.tab
    }
    pub fn take_effects(&mut self) -> Vec<Effect> {
        std::mem::take(&mut self.effects)
    }
    /// Whether `view` changed since this was last asked.
    pub fn take_view_changed(&mut self) -> bool {
        std::mem::take(&mut self.view_changed)
    }

    fn thread_key(&self) -> String {
        format!("{}:{}", self.environment, self.thread)
    }

    /// The thread shown, and the MC whose events carry its environment's
    /// devices (empty when none does).
    pub fn set_thread(&mut self, environment: &str, thread: &str, mc: &str) {
        if environment == self.environment && thread == self.thread && mc == self.mc {
            return;
        }
        let moved = environment != self.environment || mc != self.mc;
        self.thread = thread.into();
        self.pending.clear();
        self.error.clear();
        if moved {
            self.unfollow();
            self.environment = environment.into();
            self.mc = mc.into();
            self.generation += 1;
            self.state = json!({});
            self.loaded = false;
            self.follow();
        } else {
            self.watch_sessions();
        }
        self.retarget();
        self.publish();
    }

    /// The panel's active tab while it shows a Device tab (`device` or a
    /// device tab), else empty: a device tab streams only while shown.
    pub fn set_tab(&mut self, tab: &str) {
        if tab == self.tab {
            return;
        }
        let shown = self.tab.is_empty() && !tab.is_empty();
        self.tab = tab.into();
        // Showing the tab lists again.
        if shown && self.loaded && text(&self.state, "hostStatus") != "disabled" {
            self.list(json!({}));
        }
        self.retarget();
        self.publish();
    }

    fn follow(&mut self) {
        if self.following || self.mc.is_empty() || self.environment.is_empty() {
            return;
        }
        self.following = true;
        self.effects.push(Effect::Follow(self.mc.clone()));
    }

    fn unfollow(&mut self) {
        if std::mem::take(&mut self.following) {
            self.effects.push(Effect::Unfollow);
        }
    }

    fn list(&mut self, input: Json) {
        if self.environment.is_empty() {
            return;
        }
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "device.list",
            payload: input,
            then: Then::List {
                generation: self.generation,
            },
        });
    }

    /// A `devices` frame's state.
    pub fn take(&mut self, state: Json) {
        self.state = state;
        let first = !self.loaded;
        self.loaded = true;
        if first && !self.tab.is_empty() && text(&self.state, "hostStatus") != "disabled" {
            self.list(json!({}));
        }
        self.watch_sessions();
        self.retarget();
        self.publish();
        let names: Vec<String> = array(&self.state, "devices")
            .iter()
            .map(|d| format!("{}={}", text(d, "id"), text(d, "name")))
            .collect();
        let names = names.join("\0");
        if names != self.names {
            self.names = names;
            self.effects.push(Effect::NamesChanged);
        }
    }

    fn device_of(&self, host_id: &str, device_id: &str) -> Option<&Json> {
        array(&self.state, "devices")
            .iter()
            .find(|d| text(d, "hostId") == host_id && text(d, "id") == device_id)
    }

    fn has_session(&self, host_id: &str, device_id: &str) -> bool {
        array(&self.state, "sessions").iter().any(|s| {
            text(s, "threadId") == self.thread
                && text(s, "hostId") == host_id
                && text(s, "deviceId") == device_id
        })
    }

    /// A session the thread gained since the state was last seen was opened
    /// for it elsewhere (an agent's device.open, another client): its tab
    /// opens.
    fn watch_sessions(&mut self) {
        if !self.loaded || self.thread.is_empty() {
            return;
        }
        let mut now = HashSet::new();
        let mut added = Vec::new();
        for session in array(&self.state, "sessions") {
            if text(session, "threadId") != self.thread {
                continue;
            }
            let (host_id, device_id) = (text(session, "hostId"), text(session, "deviceId"));
            if self.device_of(&host_id, &device_id).is_none() {
                continue;
            }
            now.insert(key_of(&host_id, &device_id));
            added.push((
                key_of(&host_id, &device_id),
                tab_id_of(&host_id, &device_id),
            ));
        }
        let before = self.sessions_seen.insert(self.thread_key(), now);
        let Some(before) = before else {
            return;
        };
        for (key, tab) in added {
            if !before.contains(&key) {
                self.effects.push(Effect::Opened {
                    tab,
                    automatic: true,
                });
            }
        }
    }

    /// The shown device tab streams its device while the thread has it open.
    fn retarget(&mut self) {
        let shown = target_of(&self.tab).and_then(|(host_id, device_id)| {
            let device = self.device_of(&host_id, &device_id)?;
            self.has_session(&host_id, &device_id).then(|| {
                (
                    text(&self.state, "hubBasePath"),
                    text(device, "platform"),
                    device_id.clone(),
                    true,
                )
            })
        });
        let target = shown.unwrap_or_default();
        if self.target.as_ref() == Some(&target) {
            return;
        }
        let (hub_base, platform, device, active) = target.clone();
        self.target = Some(target);
        self.effects.push(Effect::Stream {
            hub_base,
            platform,
            device,
            active,
        });
    }

    /// A device tab's title: its device's name, else "Device".
    pub fn title_of(&self, tab_id: &str) -> String {
        let name = target_of(tab_id)
            .and_then(|(host_id, device_id)| {
                self.device_of(&host_id, &device_id)
                    .map(|d| text(d, "name"))
            })
            .unwrap_or_default();
        if name.is_empty() {
            "Device".into()
        } else {
            name
        }
    }

    /// Opens a listed device for the thread.
    pub fn open(&mut self, host_id: &str, device_id: &str) {
        let Some(platform) = self
            .device_of(host_id, device_id)
            .map(|d| d.get("platform").cloned().unwrap_or(Json::Null))
        else {
            return;
        };
        if !self.pending.is_empty() || self.thread.is_empty() {
            return;
        }
        self.pending = key_of(host_id, device_id);
        self.error.clear();
        self.publish();
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "device.open",
            payload: json!({
                "deviceId": device_id,
                "hostId": host_id,
                "platform": platform,
                "threadId": self.thread,
            }),
            then: Then::Open {
                generation: self.generation,
                thread: self.thread.clone(),
                host_id: host_id.into(),
                device_id: device_id.into(),
            },
        });
    }

    /// Shuts the shown tab's device down and closes the tab.
    pub fn power_off(&mut self) {
        let tab = self.tab.clone();
        let Some((host_id, device_id)) = target_of(&tab) else {
            return;
        };
        if !self.has_session(&host_id, &device_id) {
            return;
        }
        self.error.clear();
        self.publish();
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: "device.close",
            payload: json!({
                "deviceId": device_id,
                "hostId": host_id,
                "shutdown": true,
                "threadId": self.thread,
            }),
            then: Then::PowerOff {
                environment: self.environment.clone(),
                thread: self.thread.clone(),
                tab,
            },
        });
    }

    /// Closes the shown device tab; the device stays open for the thread.
    pub fn close(&mut self) {
        if !self.tab.is_empty() {
            self.effects.push(Effect::Closed {
                thread_key: self.thread_key(),
                tab: self.tab.clone(),
            });
        }
    }

    pub fn refresh(&mut self) {
        self.list(json!({}));
    }

    pub fn dismiss_error(&mut self) {
        if !self.error.is_empty() {
            self.error.clear();
            self.publish();
        }
    }

    /// What the MC answered.
    pub fn answer(&mut self, then: Then, result: Result<Json, String>) {
        match then {
            Then::List { generation } => {
                if generation != self.generation {
                    return;
                }
                if let Ok(state) = result {
                    self.take(state);
                }
            }
            Then::Open {
                generation,
                thread,
                host_id,
                device_id,
            } => {
                if generation != self.generation || thread != self.thread {
                    return;
                }
                self.pending.clear();
                let session = match result {
                    Ok(session) => session,
                    Err(error) => {
                        self.error = error;
                        self.publish();
                        return;
                    }
                };
                // The session is the MC's; seeing it later is not an agent's
                // open.
                let or = |field: &str, fallback: String| {
                    session
                        .get(field)
                        .and_then(Json::as_str)
                        .map_or(fallback, str::to_owned)
                };
                let host = or("hostId", host_id);
                let id = or("deviceId", device_id);
                let thread_key = format!("{}:{thread}", self.environment);
                self.sessions_seen
                    .entry(thread_key)
                    .or_default()
                    .insert(key_of(&host, &id));
                self.publish();
                self.effects.push(Effect::Opened {
                    tab: tab_id_of(&host, &id),
                    automatic: false,
                });
            }
            Then::PowerOff {
                environment,
                thread,
                tab,
            } => {
                let here = self.environment == environment && self.thread == thread;
                match result {
                    Err(error) => {
                        // Only the thread that asked shows why.
                        if here {
                            self.error = error;
                            self.publish();
                        }
                    }
                    // The tab closes in the thread it was powered off from,
                    // shown or not.
                    Ok(_) => self.effects.push(Effect::Closed {
                        thread_key: format!("{environment}:{thread}"),
                        tab,
                    }),
                }
            }
        }
    }

    fn publish(&mut self) {
        let state = &self.state;
        let host_status = text(state, "hostStatus");
        let host_detail = text(state, "hostStatusDetail");
        let (mut host_ready, mut host_busy) = (false, false);
        if let Some(statuses) = state.get("hostStatuses").and_then(Json::as_object) {
            for value in statuses.values() {
                let status = text(value, "status");
                host_ready = host_ready || status == "ready";
                host_busy = host_busy || status == "installing" || status == "starting";
            }
        }
        host_busy = host_busy && !host_ready;

        let mut host_labels: HashMap<String, String> = HashMap::new();
        let mut android_missing = false;
        for host in array(state, "hosts") {
            host_labels.insert(text(host, "id"), text(host, "label"));
            for entry in array(host, "platforms") {
                if text(entry, "platform") == "android" && !flag(entry, "available") {
                    android_missing = true;
                }
            }
        }
        let host_label = |host_id: &str| {
            let label = host_labels.get(host_id).cloned().unwrap_or_default();
            if label.is_empty() {
                "Device host".to_owned()
            } else {
                label
            }
        };

        // iOS Simulators, then Android Emulators; running first, then by
        // name.
        let mut groups = Vec::new();
        let mut any_android = false;
        let pending_device = array(state, "devices")
            .iter()
            .find(|d| key_of(&text(d, "hostId"), &text(d, "id")) == self.pending);
        for platform in ["ios", "android"] {
            let mut devices: Vec<&Json> = array(state, "devices")
                .iter()
                .filter(|d| text(d, "platform") == platform)
                .collect();
            if devices.is_empty() {
                continue;
            }
            any_android = any_android || platform == "android";
            devices.sort_by(|a, b| {
                flag(b, "booted").cmp(&flag(a, "booted")).then_with(|| {
                    crate::sidebar_model::locale_compare(&text(a, "name"), &text(b, "name"))
                })
            });
            let rows: Vec<Json> = devices
                .into_iter()
                .map(|device| {
                    let booted = flag(device, "booted");
                    let (host_id, id) = (text(device, "hostId"), text(device, "id"));
                    let state = if booted { "Running" } else { "Stopped" };
                    json!({
                        "action": if booted { "Open" } else { "Start" },
                        "detail": format!("{} · {} · {state}", host_label(&host_id), text(device, "version")),
                        "hostId": host_id,
                        "id": id,
                        "key": key_of(&host_id, &id),
                        "name": text(device, "name"),
                        "platform": platform,
                    })
                })
                .collect();
            let title = if platform == "ios" {
                "iOS Simulators"
            } else {
                "Android Emulators"
            };
            groups.push(json!({"devices": rows, "title": title}));
        }

        let booting: Vec<String> = array(state, "bootingDevices")
            .iter()
            .filter(|d| text(d, "threadId") == self.thread)
            .map(|d| text(d, "name"))
            .collect();

        let screen = target_of(&self.tab)
            .and_then(|(host_id, device_id)| {
                let device = self.device_of(&host_id, &device_id)?;
                self.has_session(&host_id, &device_id).then(|| {
                    json!({
                        "description": format!("{} · {}", host_label(&host_id), text(device, "version")),
                        "hostId": host_id,
                        "id": device_id,
                        "name": text(device, "name"),
                        "platform": text(device, "platform"),
                    })
                })
            })
            .unwrap_or(Json::Null);

        let loading = if let Some(device) = pending_device {
            if flag(device, "booted") {
                "Opening device…".to_owned()
            } else {
                "Starting device…".to_owned()
            }
        } else if host_busy || !self.loaded {
            if host_status == "installing" {
                if host_detail.is_empty() {
                    "Installing device support…".to_owned()
                } else {
                    host_detail.clone()
                }
            } else {
                "Finding devices…".to_owned()
            }
        } else {
            String::new()
        };
        let empty = if !groups.is_empty() {
            String::new()
        } else if host_status == "failed" {
            if host_detail.is_empty() {
                "The device hub failed to start.".to_owned()
            } else {
                host_detail.clone()
            }
        } else {
            "No simulators or emulators were found on this environment.".to_owned()
        };
        let starting = if booting.is_empty() {
            String::new()
        } else {
            format!("Starting {}… This can take a minute.", booting.join(", "))
        };

        let view = json!({
            "canRefresh": self.loaded && !host_busy,
            "empty": empty,
            "error": self.error,
            "groups": if host_ready { Json::Array(groups) } else { json!([]) },
            "hostDetail": if host_ready { host_detail } else { String::new() },
            "loaded": self.loaded,
            "loading": loading,
            "noAndroid": host_ready && !any_android && !android_missing,
            "pendingKey": self.pending,
            "screen": screen,
            "setup": self.loaded && (host_status == "disabled" || !flag(state, "onboardingCompleted")),
            "starting": starting,
        });
        if view != self.view {
            self.view = view;
            self.view_changed = true;
        }
    }
}

/// A tab the panel opens: its id, and whether an agent opened it.
pub type OnOpened = Rc<dyn Fn(&Engine, &str, bool)>;
/// A tab the panel closes: the thread's key and the tab's id.
pub type OnClosed = Rc<dyn Fn(&Engine, &str, &str)>;
pub type OnNamesChanged = Rc<dyn Fn(&Engine)>;

#[derive(Default)]
struct Hooks {
    opened: Vec<OnOpened>,
    closed: Vec<OnClosed>,
    names_changed: Vec<OnNamesChanged>,
}

struct Inner {
    core: RefCell<Devices>,
    mc: Rc<dyn Mc>,
    stream: ObjectId,
    subscription: RefCell<Option<SubId>>,
    hooks: RefCell<Hooks>,
}

impl Drop for Inner {
    fn drop(&mut self) {
        if let Some(id) = self.subscription.get_mut().take() {
            self.mc.unsubscribe(id);
        }
    }
}

impl std::fmt::Debug for Inner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ThreadDevices")
            .field("core", &self.core)
            .finish_non_exhaustive()
    }
}

/// A thread's Device tabs, as the right panel hands them to the
/// DevicePanel brick (`RightPanelController.device`).
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "ThreadDevices", uncreatable)]
pub struct ThreadDevices {
    /// See the module doc.
    #[qml(readonly, notify)]
    view: Value,
    /// The shown device tab's `DeviceStream`; set once, when made.
    #[qml(readonly, notify)]
    stream: Value,
    #[qml(skip)]
    inner: Rc<Inner>,
}

fn inner_of(engine: &Engine, obj: ObjectId) -> Option<Rc<Inner>> {
    engine
        .with::<ThreadDevices, _>(obj, |d| d.inner.clone())
        .ok()
}

fn warn(engine: &Engine, result: Result<(), EngineError>) {
    if let Err(e) = result {
        engine.log(
            ljos::prelude::LogLevel::Warning,
            "ThreadDevices",
            e.to_string(),
        );
    }
}

impl ThreadDevices {
    /// The Device tabs owned by `owner`, asking `mc` and streaming over it.
    pub fn create(
        engine: &Engine,
        owner: Option<ObjectId>,
        mc: Rc<dyn Mc>,
    ) -> Result<ObjectId, EngineError> {
        // The stream is the devices' own; it is made first so the devices
        // never point at none, and handed to them.
        let stream = DeviceStream::create(engine, None, mc.clone())?;
        let core = Devices::new();
        let view = core.view().to_value();
        let inner = Rc::new(Inner {
            core: RefCell::new(core),
            mc,
            stream,
            subscription: RefCell::new(None),
            hooks: RefCell::default(),
        });
        let devices = ThreadDevices {
            view,
            stream: Value::Object(stream),
            inner,
        };
        let obj = match engine.create_native(devices, owner) {
            Ok(obj) => obj,
            Err(e) => {
                engine.destroy(stream);
                return Err(e);
            }
        };
        warn(engine, engine.set_owner(stream, Some(obj)));
        Ok(obj)
    }

    /// The thread shown, and the MC whose events carry its environment's
    /// devices (empty when none does).
    pub fn set_thread(engine: &Engine, obj: ObjectId, environment: &str, thread: &str, mc: &str) {
        Self::update(engine, obj, |d| d.set_thread(environment, thread, mc));
    }

    /// The panel's active tab while it shows a Device tab, else empty.
    pub fn set_tab(engine: &Engine, obj: ObjectId, tab: &str) {
        Self::update(engine, obj, |d| d.set_tab(tab));
    }

    /// A device tab's title: its device's name, else "Device".
    pub fn title_of(engine: &Engine, obj: ObjectId, tab: &str) -> String {
        Self::read(engine, obj, |d| d.title_of(tab)).unwrap_or_else(|| "Device".into())
    }

    /// The `DeviceStream` the shown device tab streams on.
    pub fn stream(engine: &Engine, obj: ObjectId) -> Option<ObjectId> {
        Some(inner_of(engine, obj)?.stream)
    }

    /// The panel shows `tab` in place of the picker (`automatic`: an agent
    /// opened it, and a tab the user closed stays closed).
    pub fn on_opened(engine: &Engine, obj: ObjectId, f: impl Fn(&Engine, &str, bool) + 'static) {
        if let Some(inner) = inner_of(engine, obj) {
            inner.hooks.borrow_mut().opened.push(Rc::new(f));
        }
    }

    /// `thread_key` (`<environment>:<thread>`) closes `tab`: the thread it
    /// was asked in, which may no longer be the one shown.
    pub fn on_closed(engine: &Engine, obj: ObjectId, f: impl Fn(&Engine, &str, &str) + 'static) {
        if let Some(inner) = inner_of(engine, obj) {
            inner.hooks.borrow_mut().closed.push(Rc::new(f));
        }
    }

    /// A device's name became known or changed: tab titles follow.
    pub fn on_names_changed(engine: &Engine, obj: ObjectId, f: impl Fn(&Engine) + 'static) {
        if let Some(inner) = inner_of(engine, obj) {
            inner.hooks.borrow_mut().names_changed.push(Rc::new(f));
        }
    }

    /// Runs `f` on the devices of `obj`, then publishes `view` and runs what
    /// they asked for. None when `obj` is not live.
    pub fn update<R>(
        engine: &Engine,
        obj: ObjectId,
        f: impl FnOnce(&mut Devices) -> R,
    ) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let (result, changed, view, effects) = {
            let mut core = inner.core.borrow_mut();
            let result = f(&mut core);
            let changed = core.take_view_changed();
            (result, changed, core.view().clone(), core.take_effects())
        };
        if changed {
            let value = view.to_value();
            warn(engine, engine.set_internal(obj, ThreadDevices::VIEW, value));
        }
        for effect in effects {
            run(engine, obj, &inner, effect);
        }
        Some(result)
    }

    /// Reads the devices of `obj`.
    pub fn read<R>(engine: &Engine, obj: ObjectId, f: impl FnOnce(&Devices) -> R) -> Option<R> {
        let inner = inner_of(engine, obj)?;
        let core = inner.core.borrow();
        Some(f(&core))
    }
}

fn run(engine: &Engine, obj: ObjectId, inner: &Inner, effect: Effect) {
    match effect {
        Effect::Follow(mc) => {
            let id = inner.mc.subscribe(
                json!({"mc": mc, "type": "devices"}),
                Box::new(move |engine, frame| {
                    if frame.get("t").and_then(Json::as_str) != Some("devices") {
                        return;
                    }
                    let state = frame.get("state").cloned().unwrap_or(Json::Null);
                    let state = if state.is_object() { state } else { json!({}) };
                    ThreadDevices::update(engine, obj, |d| d.take(state));
                }),
                None,
            );
            let old = inner.subscription.borrow_mut().replace(id);
            if let Some(old) = old {
                inner.mc.unsubscribe(old);
            }
        }
        Effect::Unfollow => {
            let id = inner.subscription.borrow_mut().take();
            if let Some(id) = id {
                inner.mc.unsubscribe(id);
            }
        }
        Effect::Call {
            environment,
            method,
            payload,
            then,
        } => inner.mc.call(
            &environment,
            method,
            payload,
            Box::new(move |engine, result: Result<Json, McError>| {
                let result = result.map(|r| if r.is_object() { r } else { json!({}) });
                let result = result.map_err(|e| e.message);
                ThreadDevices::update(engine, obj, |d| d.answer(then, result));
            }),
        ),
        Effect::Stream {
            hub_base,
            platform,
            device,
            active,
        } => {
            if active {
                DeviceStream::set_target(engine, inner.stream, &hub_base, &platform, &device);
                DeviceStream::set_active(engine, inner.stream, true);
            } else {
                DeviceStream::set_active(engine, inner.stream, false);
                DeviceStream::set_target(engine, inner.stream, "", "", "");
            }
        }
        Effect::Opened { tab, automatic } => {
            let hooks = inner.hooks.borrow().opened.clone();
            for hook in hooks {
                hook(engine, &tab, automatic);
            }
        }
        Effect::Closed { thread_key, tab } => {
            let hooks = inner.hooks.borrow().closed.clone();
            for hook in hooks {
                hook(engine, &thread_key, &tab);
            }
        }
        Effect::NamesChanged => {
            let hooks = inner.hooks.borrow().names_changed.clone();
            for hook in hooks {
                hook(engine);
            }
        }
    }
}

#[qml_impl]
impl ThreadDevices {
    /// Opens a listed device for the thread.
    #[qml(invokable)]
    fn open(cx: &Cx, host_id: Atom, device_id: Atom) {
        ThreadDevices::update(cx.engine, cx.this, |d| d.open(&host_id, &device_id));
    }

    /// Shuts the shown tab's device down and closes the tab.
    #[qml(invokable)]
    fn power_off(cx: &Cx) {
        ThreadDevices::update(cx.engine, cx.this, Devices::power_off);
    }

    /// Closes the shown device tab; the device stays open for the thread.
    #[qml(invokable)]
    fn close(cx: &Cx) {
        ThreadDevices::update(cx.engine, cx.this, Devices::close);
    }

    #[qml(invokable)]
    fn refresh(cx: &Cx) {
        ThreadDevices::update(cx.engine, cx.this, Devices::refresh);
    }

    #[qml(invokable)]
    fn dismiss_error(cx: &Cx) {
        ThreadDevices::update(cx.engine, cx.this, Devices::dismiss_error);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tab_ids_round_trip_through_percent_encoding() {
        let tab = tab_id_of("mc:1", "iPhone 16");
        assert_eq!(tab, "device:mc%3A1:iPhone%2016");
        assert_eq!(
            target_of(&tab),
            Some(("mc:1".to_owned(), "iPhone 16".to_owned()))
        );
        assert_eq!(target_of("device"), None);
        assert_eq!(target_of("device::x"), None);
        assert_eq!(target_of("device:a:b:c"), None);
    }
}
