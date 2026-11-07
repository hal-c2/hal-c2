//! desktop-qt's ThreadDevices: the Device tabs of a thread's right panel.
//! The picker (`device`) lists the thread's environment's simulators and
//! emulators, and a device tab (`device:<host>:<device>`, both
//! percent-encoded) streams one the thread has open. Each device tab the
//! panel has is a [`DeviceTab`] (`tabs`, by tab id) with its own stream and
//! view choices; it streams only while shown (`set_shown`) and its device is
//! open for the thread. The environment's
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
//!    id, name, platform, detail, action ("Open" | "Start")}]}]}.
//!
//! A DeviceTab's `screen` is null, or its device while the thread has it
//! open {hostId, id, name, platform, description}.
//!
//! [`Devices`] is that without the engine; [`ThreadDevices`] is the object
//! the panel hands QML, which runs what it asks for on the shell's MC and
//! its tabs' [`DeviceStream`]s.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use ljos::prelude::{
    Atom, Cx, Engine, EngineError, ObjectId, QmlObject, QmlValue, Value, qml_impl,
};
use serde_json::json;

use super::percent;
use super::stream::DeviceStream;
use super::tools::DeviceTools;
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
    /// The setup wizard's `device.configure` (`pending` is "hub", "agent"
    /// or "complete") or its `device.list` ("check").
    Wizard { generation: u64, pending: String },
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
    /// The panel has a device tab `tab`: it gets a DeviceTab.
    AddTab(String),
    /// The device tab `tab` is gone: its stream stops and its DeviceTab goes.
    DropTab(String),
    /// `tab`'s stream shows this device (all empty: none), streaming while
    /// `active`.
    Stream {
        tab: String,
        environment: String,
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
    /// `tab`'s device (null: none open) and whether the tab is shown.
    Screen {
        tab: String,
        screen: Json,
        shown: bool,
    },
    /// A device's name became known or changed: tab titles follow.
    NamesChanged,
}

/// What a device tab was last told: its stream's target and its screen.
#[derive(Debug, Default, PartialEq)]
struct Told {
    target: (String, String, String, bool),
    screen: Json,
    shown: bool,
}

/// A thread's Device tabs, without the engine.
#[derive(Debug, Default)]
pub struct Devices {
    environment: String,
    thread: String,
    mc: String,
    /// The panel's device tabs, each with a DeviceTab, and what each was
    /// last told.
    tabs: Vec<(String, Told)>,
    /// The Device tabs shown (the picker and device tabs).
    shown: HashSet<String>,
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
    /// The machine whose start is being retried.
    retrying: String,
    /// The setup wizard's request in flight ("hub", "check", "agent",
    /// "complete"), and what the last one failed with.
    wizard_pending: String,
    wizard_error: String,
    /// The user cancelled or finished the wizard; showing a Device tab again
    /// brings it back while setup is not done.
    wizard_dismissed: bool,
    view: Json,
    view_changed: bool,
    effects: Vec<Effect>,
}

impl Devices {
    pub fn new() -> Devices {
        let mut devices = Devices {
            state: json!({}),
            ..Devices::default()
        };
        devices.publish();
        devices
    }

    pub fn view(&self) -> &Json {
        &self.view
    }
    /// The panel's device tabs.
    pub fn tabs(&self) -> Vec<String> {
        self.tabs.iter().map(|(id, _)| id.clone()).collect()
    }
    /// Whether the Device tab `tab` is shown.
    pub fn is_shown(&self, tab: &str) -> bool {
        self.shown.contains(tab)
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
            self.wizard_pending.clear();
            self.wizard_error.clear();
            self.retrying.clear();
            self.state = json!({});
            self.loaded = false;
            self.follow();
        } else {
            self.watch_sessions();
        }
        self.retarget();
        self.publish();
    }

    /// The thread's device tabs: each has a DeviceTab while it is listed.
    pub fn set_tabs(&mut self, tabs: &[String]) {
        let before = std::mem::take(&mut self.tabs);
        let mut kept = Vec::new();
        for (id, told) in before {
            if tabs.contains(&id) {
                kept.push((id, told));
            } else {
                // A closed tab's stream goes with it.
                self.effects.push(Effect::DropTab(id));
            }
        }
        self.tabs = kept;
        for id in tabs {
            if target_of(id).is_none() || self.tabs.iter().any(|(t, _)| t == id) {
                continue;
            }
            self.effects.push(Effect::AddTab(id.clone()));
            self.tabs.push((id.clone(), Told::default()));
        }
        self.retarget();
    }

    /// The Device tabs shown anywhere (`device` and device tabs): a device
    /// tab streams only while shown, and showing a Device tab lists again.
    pub fn set_shown(&mut self, tabs: &[String]) {
        let shown: HashSet<String> = tabs.iter().filter(|t| is_device_tab(t)).cloned().collect();
        if shown == self.shown {
            return;
        }
        let first = self.shown.is_empty() && !shown.is_empty();
        if first {
            self.wizard_dismissed = false;
        }
        self.shown = shown;
        if first && self.loaded && text(&self.state, "hostStatus") != "disabled" {
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
        self.retrying.clear();
        let first = !self.loaded;
        self.loaded = true;
        if first && !self.shown.is_empty() && text(&self.state, "hostStatus") != "disabled" {
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

    /// A device tab shows its device while the thread has it open, and
    /// streams it only while shown.
    fn retarget(&mut self) {
        let mut tabs = std::mem::take(&mut self.tabs);
        for (tab, told) in &mut tabs {
            let now = self.told(tab);
            if now.target != told.target {
                let (hub_base, platform, device, active) = now.target.clone();
                self.effects.push(Effect::Stream {
                    tab: tab.clone(),
                    environment: self.environment.clone(),
                    hub_base,
                    platform,
                    device,
                    active,
                });
            }
            if now.screen != told.screen || now.shown != told.shown {
                self.effects.push(Effect::Screen {
                    tab: tab.clone(),
                    screen: now.screen.clone(),
                    shown: now.shown,
                });
            }
            *told = now;
        }
        self.tabs = tabs;
    }

    /// What the device tab `tab` shows and streams now.
    fn told(&self, tab: &str) -> Told {
        let shown = self.shown.contains(tab);
        let open = target_of(tab).and_then(|(host_id, device_id)| {
            let device = self.device_of(&host_id, &device_id)?;
            self.has_session(&host_id, &device_id)
                .then_some((host_id, device_id, device))
        });
        let Some((host_id, device_id, device)) = open else {
            return Told {
                screen: Json::Null,
                shown,
                ..Told::default()
            };
        };
        let label = array(&self.state, "hosts")
            .iter()
            .find(|h| text(h, "id") == host_id)
            .map(|h| text(h, "label"))
            .unwrap_or_default();
        let label = if label.is_empty() {
            "Device host".to_owned()
        } else {
            label
        };
        let platform = text(device, "platform");
        let screen = json!({
            "description": format!("{label} · {}", text(device, "version")),
            "hostId": host_id,
            "id": device_id,
            "name": text(device, "name"),
            "platform": platform,
        });
        let target = if shown {
            (text(&self.state, "hubBasePath"), platform, device_id, true)
        } else {
            Default::default()
        };
        Told {
            target,
            screen,
            shown,
        }
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

    /// Shuts the tab's device down and closes the tab.
    pub fn power_off(&mut self, tab: &str) {
        let tab = tab.to_owned();
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

    /// Closes the device tab; the device stays open for the thread.
    pub fn close(&mut self, tab: &str) {
        if !tab.is_empty() {
            self.effects.push(Effect::Closed {
                thread_key: self.thread_key(),
                tab: tab.to_owned(),
            });
        }
    }

    pub fn refresh(&mut self) {
        self.list(json!({}));
    }

    /// Tries starting a machine's device tools again.
    pub fn retry_host(&mut self, host_id: &str) {
        if host_id.is_empty() || !self.retrying.is_empty() {
            return;
        }
        self.retrying = host_id.into();
        self.publish();
        self.list(json!({"retryHostId": host_id}));
    }

    fn configure(&mut self, pending: &str, change: Json) {
        if !self.wizard_pending.is_empty() || self.environment.is_empty() {
            return;
        }
        self.wizard_pending = pending.into();
        self.wizard_error.clear();
        self.publish();
        self.effects.push(Effect::Call {
            environment: self.environment.clone(),
            method: if pending == "check" {
                "device.list"
            } else {
                "device.configure"
            },
            payload: change,
            then: Then::Wizard {
                generation: self.generation,
                pending: pending.into(),
            },
        });
    }

    /// The wizard's "Enable device hub": off turns agent access off too.
    pub fn wizard_set_hub(&mut self, on: bool) {
        let change = if on {
            json!({"enabled": true})
        } else {
            json!({"enabled": false, "agentAccessEnabled": false})
        };
        self.configure("hub", change);
    }

    pub fn wizard_set_agent(&mut self, on: bool) {
        self.configure("agent", json!({"agentAccessEnabled": on}));
    }

    /// "Check again": the platforms are read again.
    pub fn wizard_check(&mut self) {
        self.configure("check", json!({}));
    }

    pub fn wizard_done(&mut self) {
        self.configure("complete", json!({"onboardingCompleted": true}));
    }

    pub fn wizard_cancel(&mut self) {
        self.wizard_dismissed = true;
        self.publish();
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
                match result {
                    Ok(state) => self.take(state),
                    Err(_) => {
                        self.retrying.clear();
                        self.publish();
                    }
                }
            }
            Then::Wizard {
                generation,
                pending,
            } => {
                if generation != self.generation {
                    return;
                }
                self.wizard_pending.clear();
                match result {
                    Ok(state) => {
                        self.wizard_error.clear();
                        if pending == "complete" {
                            self.wizard_dismissed = true;
                        }
                        self.take(state);
                    }
                    Err(error) => self.wizard_error = error,
                }
                self.publish();
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
                        "tab": tab_id_of(&host_id, &id),
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

        let wizard = if self.loaded
            && !self.wizard_dismissed
            && (!flag(state, "onboardingCompleted") || host_status == "disabled")
        {
            self.wizard_view()
        } else {
            Json::Null
        };
        let view = json!({
            "banners": self.banners(),
            "canRefresh": self.loaded && !host_busy,
            "empty": empty,
            "error": self.error,
            "groups": if host_ready { Json::Array(groups) } else { json!([]) },
            "hostDetail": if host_ready { host_detail } else { String::new() },
            "loaded": self.loaded,
            "loading": loading,
            "noAndroid": host_ready && !any_android && !android_missing,
            "pendingKey": self.pending,
            "setup": self.loaded && (host_status == "disabled" || !flag(state, "onboardingCompleted")),
            "starting": starting,
            "wizard": wizard,
        });
        if view != self.view {
            self.view = view;
            self.view_changed = true;
        }
    }
}

impl Devices {
    /// The machines installing, starting or failing to start their device
    /// tools, while device support is on.
    fn banners(&self) -> Json {
        let state = &self.state;
        if text(state, "hostStatus") == "disabled" {
            return json!([]);
        }
        let mut rows = Vec::new();
        for host in array(state, "hosts") {
            let id = text(host, "id");
            let status = state
                .get("hostStatuses")
                .and_then(|s| s.get(&id))
                .cloned()
                .unwrap_or(Json::Null);
            let now = text(&status, "status");
            if !matches!(now.as_str(), "installing" | "starting" | "failed") {
                continue;
            }
            let failed = now == "failed";
            let fallback = match now.as_str() {
                "failed" => "Device support could not start.",
                "installing" => "Installing device tools…",
                _ => "Starting device tools…",
            };
            let message = status
                .get("detail")
                .and_then(Json::as_str)
                .unwrap_or(fallback);
            rows.push(json!({
                "advice": if failed {
                    "Check the host connection and network access, then retry. Your device settings are saved."
                } else {
                    ""
                },
                "canRetry": failed && flag(state, "supportsHostRetry"),
                "failed": failed,
                "hostId": id,
                "label": text(host, "label"),
                "message": message,
                "retrying": self.retrying == id,
            }));
        }
        Json::Array(rows)
    }

    /// The first-use setup's state.
    fn wizard_view(&self) -> Json {
        let state = &self.state;
        let host_status = text(state, "hostStatus");
        let busy = host_status == "installing" || host_status == "starting";
        let ready = host_status == "ready";
        let pending = self.wizard_pending.as_str();

        let hub_pending = pending == "hub" || (busy && pending != "agent");
        let hub_status = if hub_pending {
            match host_status.as_str() {
                "installing" => "Installing device hub…",
                "starting" => "Starting device hub…",
                _ => "Updating device hub…",
            }
        } else if ready {
            "Device hub is ready."
        } else {
            ""
        };

        let agent_on = flag(state, "agentAccessEnabled");
        let agent_status = if pending == "agent" {
            match host_status.as_str() {
                "installing" => "Installing agent tools…",
                "starting" => "Starting agent tools…",
                _ => "Updating agent access…",
            }
        } else if agent_on
            && ready
            && array(state, "hosts")
                .iter()
                .any(|h| flag(h, "agentDeviceInstalled"))
        {
            "Agent tools are ready."
        } else {
            ""
        };

        let platform = |wanted: &str| {
            let availability = array(state, "hosts")
                .iter()
                .flat_map(|h| array(h, "platforms"))
                .find(|p| text(p, "platform") == wanted)
                .cloned()
                .unwrap_or(Json::Null);
            let name = if wanted == "ios" { "iOS" } else { "Android" };
            if !flag(&availability, "available") {
                let reason = availability
                    .get("reason")
                    .and_then(Json::as_str)
                    .map_or_else(
                        || format!("{name} support was not detected."),
                        str::to_owned,
                    );
                return json!({"message": reason, "platform": name, "ready": false});
            }
            let any = array(state, "devices")
                .iter()
                .any(|d| text(d, "platform") == wanted);
            if ready && !any {
                let message = if wanted == "ios" {
                    "Xcode is installed, but no iOS Simulator is available. Install a runtime in Xcode Settings → Components."
                } else {
                    "The Android SDK is installed, but no virtual device exists. Create one in Android Studio → Device Manager."
                };
                return json!({"message": message, "platform": name, "ready": false});
            }
            let message = if wanted == "ios" {
                "Xcode and iOS Simulator are available."
            } else {
                "The Android SDK and Emulator are available."
            };
            json!({"message": message, "platform": name, "ready": true})
        };

        let error = if !self.wizard_error.is_empty() {
            self.wizard_error.clone()
        } else if host_status == "failed" {
            text(state, "hostStatusDetail")
        } else {
            String::new()
        };
        json!({
            "agentOn": agent_on,
            "agentStatus": agent_status,
            "busy": busy,
            "canContinue": ready && pending.is_empty(),
            "error": error,
            "hubOn": host_status != "disabled",
            "hubReady": ready,
            "hubStatus": hub_status,
            "pending": pending,
            "platforms": [platform("ios"), platform("android")],
        })
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
    /// Each device tab's DeviceTab, in the order the panel has them.
    tabs: RefCell<Vec<(String, ObjectId)>>,
    /// The streams' first-picture and retry timeouts, when a test set them.
    timeouts: RefCell<Option<(i32, i32)>>,
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

impl Inner {
    fn tab(&self, tab: &str) -> Option<ObjectId> {
        self.tabs
            .borrow()
            .iter()
            .find(|(id, _)| id == tab)
            .map(|(_, obj)| *obj)
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
    /// Tab id → `DeviceTab`, for every device tab the thread's panel has.
    #[qml(readonly, notify)]
    tabs: Value,
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
        let core = Devices::new();
        let view = core.view().to_value();
        let inner = Rc::new(Inner {
            core: RefCell::new(core),
            mc,
            tabs: RefCell::default(),
            timeouts: RefCell::default(),
            subscription: RefCell::new(None),
            hooks: RefCell::default(),
        });
        let devices = ThreadDevices {
            view,
            tabs: Value::map(Vec::<(Atom, Value)>::new()),
            inner,
        };
        engine.create_native(devices, owner)
    }

    /// The thread shown, and the MC whose events carry its environment's
    /// devices (empty when none does).
    pub fn set_thread(engine: &Engine, obj: ObjectId, environment: &str, thread: &str, mc: &str) {
        Self::update(engine, obj, |d| d.set_thread(environment, thread, mc));
    }

    /// The thread's device tabs: each has a DeviceTab while listed.
    pub fn set_tabs(engine: &Engine, obj: ObjectId, tabs: &[String]) {
        Self::update(engine, obj, |d| d.set_tabs(tabs));
    }

    /// The Device tabs shown anywhere; a device tab streams only while shown.
    pub fn set_shown(engine: &Engine, obj: ObjectId, tabs: &[String]) {
        Self::update(engine, obj, |d| d.set_shown(tabs));
    }

    /// A device tab's title: its device's name, else "Device".
    pub fn title_of(engine: &Engine, obj: ObjectId, tab: &str) -> String {
        Self::read(engine, obj, |d| d.title_of(tab)).unwrap_or_else(|| "Device".into())
    }

    /// The device tab `tab`'s DeviceTab; None when the panel has no such tab.
    pub fn tab(engine: &Engine, obj: ObjectId, tab: &str) -> Option<ObjectId> {
        inner_of(engine, obj)?.tab(tab)
    }

    /// The `DeviceStream` the device tab `tab` streams on.
    pub fn stream(engine: &Engine, obj: ObjectId, tab: &str) -> Option<ObjectId> {
        DeviceTab::stream(engine, Self::tab(engine, obj, tab)?)
    }

    /// Tests: every tab's stream waits `first_frame_ms` for a first picture
    /// and `retry_ms` before connecting again, from now on.
    pub fn set_timeouts(engine: &Engine, obj: ObjectId, first_frame_ms: i32, retry_ms: i32) {
        let Some(inner) = inner_of(engine, obj) else {
            return;
        };
        *inner.timeouts.borrow_mut() = Some((first_frame_ms, retry_ms));
        let tabs = inner.tabs.borrow().clone();
        for (_, tab) in tabs {
            if let Some(stream) = DeviceTab::stream(engine, tab) {
                DeviceStream::set_timeouts(engine, stream, first_frame_ms, retry_ms);
            }
        }
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
        Effect::AddTab(tab) => {
            match DeviceTab::create(engine, obj, inner, &tab) {
                Ok(made) => inner.tabs.borrow_mut().push((tab, made)),
                Err(e) => warn(engine, Err(e)),
            }
            publish_tabs(engine, obj, inner);
        }
        Effect::DropTab(tab) => {
            let gone = {
                let mut tabs = inner.tabs.borrow_mut();
                let at = tabs.iter().position(|(id, _)| *id == tab);
                at.map(|at| tabs.remove(at).1)
            };
            if let Some(gone) = gone {
                if let Some(stream) = DeviceTab::stream(engine, gone) {
                    DeviceStream::set_active(engine, stream, false);
                }
                publish_tabs(engine, obj, inner);
                engine.destroy(gone);
            }
        }
        Effect::Stream {
            tab,
            environment,
            hub_base,
            platform,
            device,
            active,
        } => {
            let Some(shown) = inner.tab(&tab) else {
                return;
            };
            let host = target_of(&tab).map(|(host, _)| host).unwrap_or_default();
            if let Some(tools) = DeviceTab::tools(engine, shown) {
                if active {
                    DeviceTools::set_target(
                        engine,
                        tools,
                        &environment,
                        &hub_base,
                        &host,
                        &device,
                        &platform,
                    );
                } else {
                    DeviceTools::set_target(engine, tools, &environment, "", "", "", "");
                }
            }
            let Some(stream) = DeviceTab::stream(engine, shown) else {
                return;
            };
            if active {
                DeviceStream::set_target(engine, stream, &hub_base, &platform, &device);
                DeviceStream::set_active(engine, stream, true);
            } else {
                DeviceStream::set_active(engine, stream, false);
                DeviceStream::set_target(engine, stream, "", "", "");
            }
        }
        Effect::Screen { tab, screen, shown } => {
            if let Some(tab) = inner.tab(&tab) {
                warn(
                    engine,
                    engine.set_internal(tab, DeviceTab::SCREEN, screen.to_value()),
                );
                warn(engine, engine.set_internal(tab, DeviceTab::SHOWN, shown));
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

    /// Shuts the tab's device down and closes the tab.
    #[qml(invokable)]
    fn power_off(cx: &Cx, tab: Atom) {
        ThreadDevices::update(cx.engine, cx.this, |d| d.power_off(&tab));
    }

    /// Closes the device tab; the device stays open for the thread.
    #[qml(invokable)]
    fn close(cx: &Cx, tab: Atom) {
        ThreadDevices::update(cx.engine, cx.this, |d| d.close(&tab));
    }

    #[qml(invokable)]
    fn refresh(cx: &Cx) {
        ThreadDevices::update(cx.engine, cx.this, Devices::refresh);
    }

    #[qml(invokable)]
    fn dismiss_error(cx: &Cx) {
        ThreadDevices::update(cx.engine, cx.this, Devices::dismiss_error);
    }

    /// A machine banner's Retry.
    #[qml(invokable)]
    fn retry_host(cx: &Cx, host_id: Atom) {
        ThreadDevices::update(cx.engine, cx.this, |d| d.retry_host(&host_id));
    }

    /// The setup wizard's switches and buttons.
    #[qml(invokable)]
    fn wizard_set_hub(cx: &Cx, on: bool) {
        ThreadDevices::update(cx.engine, cx.this, |d| d.wizard_set_hub(on));
    }

    #[qml(invokable)]
    fn wizard_set_agent(cx: &Cx, on: bool) {
        ThreadDevices::update(cx.engine, cx.this, |d| d.wizard_set_agent(on));
    }

    #[qml(invokable)]
    fn wizard_check(cx: &Cx) {
        ThreadDevices::update(cx.engine, cx.this, Devices::wizard_check);
    }

    #[qml(invokable)]
    fn wizard_done(cx: &Cx) {
        ThreadDevices::update(cx.engine, cx.this, Devices::wizard_done);
    }

    #[qml(invokable)]
    fn wizard_cancel(cx: &Cx) {
        ThreadDevices::update(cx.engine, cx.this, Devices::wizard_cancel);
    }

    /// The device tab's Float. The Ljós panel has no floating devices yet,
    /// so the tab stays where it is.
    #[qml(invokable)]
    fn float_device(cx: &Cx, tab: Atom) {
        let _ = (cx, tab);
    }
}

/// ThreadDevices' `tabs`, after a tab came or went.
fn publish_tabs(engine: &Engine, obj: ObjectId, inner: &Inner) {
    let tabs: Vec<(Atom, Value)> = inner
        .tabs
        .borrow()
        .iter()
        .map(|(id, tab)| (Atom::new(id), Value::Object(*tab)))
        .collect();
    warn(
        engine,
        engine.set_internal(obj, ThreadDevices::TABS, Value::map(tabs)),
    );
}

/// One device tab (ThreadDevices' `tabs`): the device's stream and the
/// tab's own view choices, which survive switching views. Its body
/// (DevicePanel) binds to it, and its Tools drawer to `tools`.
/// desktop-qt's DeviceTab.
#[derive(Debug, QmlObject)]
#[qml(module = "HalC2.Shell", name = "DeviceTab", uncreatable)]
pub struct DeviceTab {
    #[qml(readonly)]
    tab_id: Atom,
    /// null, or the device while the thread has it open (see the module
    /// doc): null shows the picker.
    #[qml(readonly, notify)]
    screen: Value,
    /// Shown in the panel.
    #[qml(readonly, notify)]
    shown: bool,
    #[qml(readonly)]
    stream: Value,
    #[qml(readonly)]
    tools: Value,
    /// The 3D body view.
    #[qml(notify)]
    show3d: bool,
    /// An iPad's Magic Keyboard.
    #[qml(notify)]
    keyboard_attached: bool,
}

impl DeviceTab {
    fn create(
        engine: &Engine,
        owner: ObjectId,
        inner: &Inner,
        tab: &str,
    ) -> Result<ObjectId, EngineError> {
        let stream = DeviceStream::create(engine, None, inner.mc.clone())?;
        if let Some((first, retry)) = *inner.timeouts.borrow() {
            DeviceStream::set_timeouts(engine, stream, first, retry);
        }
        let tools = match DeviceTools::create(engine, None, inner.mc.clone()) {
            Ok(tools) => tools,
            Err(e) => {
                engine.destroy(stream);
                return Err(e);
            }
        };
        let made = engine.create_native(
            DeviceTab {
                tab_id: Atom::new(tab),
                screen: Value::Null,
                shown: false,
                stream: Value::Object(stream),
                tools: Value::Object(tools),
                show3d: false,
                keyboard_attached: false,
            },
            Some(owner),
        );
        match made {
            Ok(made) => {
                warn(engine, engine.set_owner(stream, Some(made)));
                warn(engine, engine.set_owner(tools, Some(made)));
                Ok(made)
            }
            Err(e) => {
                engine.destroy(stream);
                engine.destroy(tools);
                Err(e)
            }
        }
    }

    /// The tab's `DeviceStream`.
    pub fn stream(engine: &Engine, obj: ObjectId) -> Option<ObjectId> {
        match engine
            .with::<DeviceTab, _>(obj, |t| t.stream.clone())
            .ok()?
        {
            Value::Object(stream) => Some(stream),
            _ => None,
        }
    }

    /// The tab's `DeviceTools`, its Tools drawer.
    pub fn tools(engine: &Engine, obj: ObjectId) -> Option<ObjectId> {
        match engine.with::<DeviceTab, _>(obj, |t| t.tools.clone()).ok()? {
            Value::Object(tools) => Some(tools),
            _ => None,
        }
    }

    /// Whether the Magic Keyboard is attached.
    pub fn keyboard_attached(engine: &Engine, obj: ObjectId) -> bool {
        engine
            .with::<DeviceTab, _>(obj, |t| t.keyboard_attached)
            .unwrap_or(false)
    }
}

#[qml_impl]
impl DeviceTab {
    /// A Magic Keyboard is a landscape thing: attaching one this way turns a
    /// portrait iPad.
    #[qml(invokable)]
    fn toggle_keyboard(cx: &Cx) {
        let on = !DeviceTab::keyboard_attached(cx.engine, cx.this);
        warn(
            cx.engine,
            cx.engine
                .set_internal(cx.this, DeviceTab::KEYBOARD_ATTACHED, on),
        );
        let Some(stream) = DeviceTab::stream(cx.engine, cx.this) else {
            return;
        };
        if on {
            DeviceStream::update(cx.engine, stream, |s| {
                if s.orientation().starts_with("portrait") {
                    s.set_orientation("landscape_left");
                }
            });
        }
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
